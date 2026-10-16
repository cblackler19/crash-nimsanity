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
# PERFORMANCE OF THE SOFTWARE.
#
import math3d

type
  SceneryModelReference* = object
    modelId*: uint32
    isLod*: bool
    transform*: Mat4

  ScenerySection* = object
    hasRoot*: bool
    modelReferences*: seq[SceneryModelReference]

const
  SceneryNoMeshes = 3'u32
  SceneryMeshes = 0x1613'u32
  SceneryNode = 0x1600'u32
  SceneryLeaf = 0x1605'u32
  SceneryRoot = 0x160A'u32
  SceneryCellTailBytes = 80
  SceneryLightReferencesBytes = 0x400

proc readU16LE(data: openArray[uint8], offset, limit: int): uint16 =
  if offset < 0 or offset > limit - 2 or limit > data.len:
    raise newException(IOError, "Scenery 16-bit field exceeds its section")
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc readU32LE(data: openArray[uint8], offset, limit: int): uint32 =
  if offset < 0 or offset > limit - 4 or limit > data.len:
    raise newException(IOError, "Scenery 32-bit field exceeds its section")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc skipBytes(cursor: var int, amount, limit: int) =
  if amount < 0 or cursor < 0 or cursor > limit - amount:
    raise newException(IOError, "Scenery record exceeds its section")
  cursor += amount

proc matrixAt(data: openArray[uint8], offset, limit: int): Mat4 =
  if offset < 0 or offset > limit - 64 or limit > data.len:
    raise newException(IOError, "Scenery matrix exceeds its section")
  for row in 0 .. 3:
    for column in 0 .. 3:
      let bits = readU32LE(data, offset + (row * 4 + column) * 4, limit)
      result[column * 4 + row] = cast[float32](bits)

proc skipSceneryLights(data: openArray[uint8], cursor: var int, limit: int) =
  skipBytes(cursor, SceneryLightReferencesBytes, limit)
  if cursor > limit - 20:
    raise newException(IOError, "Scenery light counts exceed their section")
  discard readU32LE(data, cursor, limit) # total count
  let ambientCount = readU32LE(data, cursor + 4, limit)
  let directionalCount = readU32LE(data, cursor + 8, limit)
  let pointCount = readU32LE(data, cursor + 12, limit)
  let spotCount = readU32LE(data, cursor + 16, limit)
  cursor += 20

  # These serialized record sizes follow the retail light readers.
  let lightBytes = uint64(ambientCount) * 72'u64 +
    uint64(directionalCount) * 90'u64 + uint64(pointCount) * 74'u64 +
    uint64(spotCount) * 108'u64
  if lightBytes > uint64(limit - cursor):
    raise newException(IOError, "Scenery light records exceed their section")
  cursor += int(lightBytes)

proc readSceneryCell(data: openArray[uint8], cursor: var int, limit: int,
    cellType: uint32, depth: int, references: var seq[SceneryModelReference]) =
  if depth > 64:
    raise newException(IOError, "Scenery tree exceeds the supported depth")
  if cursor > limit - 4:
    raise newException(IOError, "Scenery cell header exceeds its section")

  let meshKind = readU32LE(data, cursor, limit)
  cursor += 4
  if meshKind == SceneryMeshes:
    let meshCount = int(readU16LE(data, cursor, limit))
    let lodCount = int(readU16LE(data, cursor + 2, limit))
    cursor += 4
    let itemCount = meshCount + lodCount
    if uint64(itemCount) * 32'u64 > uint64(limit - cursor):
      raise newException(IOError, "Scenery item bounds exceed their section")
    skipBytes(cursor, itemCount * 32, limit)

    let idBytes = uint64(itemCount) * 4'u64
    let matrixBytes = uint64(itemCount) * 64'u64
    if idBytes + matrixBytes > uint64(limit - cursor):
      raise newException(IOError, "Scenery IDs and matrices exceed their section")
    var ids = newSeq[uint32](itemCount)
    for index in 0 ..< itemCount:
      ids[index] = readU32LE(data, cursor + index * 4, limit)
    cursor += int(idBytes)
    for index, modelId in ids:
      references.add(SceneryModelReference(
        modelId: modelId,
        isLod: index >= meshCount,
        transform: matrixAt(data, cursor + index * 64, limit),
      ))
    cursor += int(matrixBytes)
  elif meshKind != SceneryNoMeshes:
    raise newException(IOError, "Unknown scenery mesh-list type")

  skipBytes(cursor, SceneryCellTailBytes, limit)
  if cellType != SceneryNode and cellType != SceneryRoot:
    return

  if cursor > limit - 32:
    raise newException(IOError, "Scenery child-type list exceeds its section")
  var childTypes: array[8, uint32]
  for index in 0 .. 7:
    childTypes[index] = readU32LE(data, cursor + index * 4, limit)
  cursor += 32
  for childType in childTypes:
    case childType
    of SceneryNode:
      readSceneryCell(data, cursor, limit, SceneryNode, depth + 1, references)
    of SceneryLeaf:
      readSceneryCell(data, cursor, limit, SceneryLeaf, depth + 1, references)
    else:
      discard

proc parseScenerySection*(data: openArray[uint8]): ScenerySection =
  var cursor = 0
  let limit = data.len
  let flags = readU32LE(data, cursor, limit)
  cursor += 4
  let nameLength = readU32LE(data, cursor, limit)
  cursor += 4
  if uint64(nameLength) > uint64(limit - cursor):
    raise newException(IOError, "Scenery name exceeds its section")
  skipBytes(cursor, int(nameLength), limit)
  skipBytes(cursor, 8, limit) # palette and root type
  let rootTypeOffset = cursor - 4
  let rootType = readU32LE(data, rootTypeOffset, limit)
  skipBytes(cursor, 1, limit) # unused byte
  if (flags and 0x10000'u32) != 0:
    skipBytes(cursor, 4, limit) # sky ID
  if (flags and 0x20000'u32) != 0:
    skipSceneryLights(data, cursor, limit)

  if rootType != SceneryRoot:
    return
  result.hasRoot = true
  skipBytes(cursor, 4, limit) # root tree depth
  readSceneryCell(data, cursor, limit, SceneryRoot, 0,
    result.modelReferences)
