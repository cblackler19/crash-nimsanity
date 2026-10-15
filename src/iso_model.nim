# ISC License
#
# Copyright (c) 2026 Caleb Blackler
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.
#
import std/sets

import iso_texture
import ps2_model

type ModelTextureLink* = object
  materialId*: uint32
  textureId*: uint32

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "Graphics item field extends beyond its range")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc findItemRange(itemTable: openArray[uint8], itemId: uint32):
    tuple[offset, byteLength: int] =
  if itemTable.len < 12:
    raise newException(IOError, "Graphics item table is shorter than its header")
  let itemCount = readU32LE(itemTable, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(itemTable.len):
    raise newException(IOError, "Graphics item table exceeds its section")
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let offset = readU32LE(itemTable, entryOffset)
    let byteLength = readU32LE(itemTable, entryOffset + 4)
    let id = readU32LE(itemTable, entryOffset + 8)
    let itemEnd = uint64(offset) + uint64(byteLength)
    if offset < tableLength or itemEnd > uint64(itemTable.len):
      raise newException(IOError, "Graphics item range exceeds its section")
    if id == itemId:
      return (int(offset), int(byteLength))
  raise newException(IOError, "Graphics item ID not found: " & $itemId)

proc findTextureForModelFromIso*(imagePath, resourcePath: string,
    modelId: uint32): ModelTextureLink =
  ## Follow model-to-rigid-model-to-material-to-texture links inside one resource.
  let rigidModels = readGraphicsSectionFromIso(imagePath, resourcePath, 3)
  let materials = readGraphicsSectionFromIso(imagePath, resourcePath, 1)
  let textures = readGraphicsSectionFromIso(imagePath, resourcePath, 0)
  let textureItemCount = readU32LE(textures, 4)
  let textureTableLength = 12'u64 + uint64(textureItemCount) * 12'u64
  if textureTableLength > uint64(textures.len):
    raise newException(IOError, "Texture item table exceeds its section")

  var textureIds = initHashSet[uint32]()
  for itemIndex in 0 ..< int(textureItemCount):
    textureIds.incl(readU32LE(textures, 12 + itemIndex * 12 + 8))

  if rigidModels.len < 12:
    raise newException(IOError, "Rigid-model table is shorter than its header")
  let rigidCount = readU32LE(rigidModels, 4)
  let rigidTableLength = 12'u64 + uint64(rigidCount) * 12'u64
  if rigidTableLength > uint64(rigidModels.len):
    raise newException(IOError, "Rigid-model table exceeds its section")

  for rigidIndex in 0 ..< int(rigidCount):
    let entryOffset = 12 + rigidIndex * 12
    let itemOffset = readU32LE(rigidModels, entryOffset)
    let itemLength = readU32LE(rigidModels, entryOffset + 4)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < rigidTableLength or itemEnd > uint64(rigidModels.len) or
        itemLength < 12:
      raise newException(IOError, "Rigid-model item range is malformed")
    let itemStart = int(itemOffset)
    let materialCount = readU32LE(rigidModels, itemStart + 4)
    let expectedLength = 12'u64 + uint64(materialCount) * 4'u64
    if expectedLength > uint64(itemLength):
      raise newException(IOError, "Rigid-model material list exceeds its item")
    let meshIdOffset = itemStart + 8 + int(materialCount) * 4
    if readU32LE(rigidModels, meshIdOffset) != modelId:
      continue

    for materialIndex in 0 ..< int(materialCount):
      let materialId = readU32LE(rigidModels, itemStart + 8 + materialIndex * 4)
      let materialRange = findItemRange(materials, materialId)
      if materialRange.byteLength < 20:
        raise newException(IOError, "Material item is shorter than its header")
      let material = materials[materialRange.offset ..<
        materialRange.offset + materialRange.byteLength]
      let nameLength = readU32LE(material, 12)
      if uint64(nameLength) + 20'u64 > uint64(materialRange.byteLength):
        raise newException(IOError, "Material name exceeds its item")
      let shaderCountOffset = 16 + int(nameLength)
      let shaderCount = readU32LE(material, shaderCountOffset)
      var shaderOffset = shaderCountOffset + 4
      for _ in 0 ..< int(shaderCount):
        let shaderType = readU32LE(material, shaderOffset)
        let parameterBytes = case shaderType
          of 23'u32: 12
          of 26'u32: 20
          of 16'u32, 17'u32: 4
          else: 0
        let shaderLength = 94 + parameterBytes
        if shaderLength > materialRange.byteLength - shaderOffset:
          raise newException(IOError, "Material shader exceeds its item")
        let textureId = readU32LE(material, shaderOffset + shaderLength - 8)
        if textureIds.contains(textureId):
          return ModelTextureLink(materialId: materialId, textureId: textureId)
        shaderOffset += shaderLength

  raise newException(IOError, "No sibling material texture resolves for model ID " &
    $modelId)

proc loadModelFromIso*(imagePath, resourcePath: string,
    modelId: uint32): DecodedModel =
  ## Decode a model item selected from an ISO resource's graphics section.
  let item = readGraphicsItemFromIso(imagePath, resourcePath, 2, modelId)
  decodeModelItem(item, 0, item.len)
