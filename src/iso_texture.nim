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
import std/strutils

import iso9660
import ps2_texture

type
  SectionRange = object
    offset: uint32
    byteLength: uint32
    id: uint32

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "Unexpected end of resource header")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc normalizeArchivePath(path: string): string =
  path.replace('\\', '/').toLowerAscii()

proc findArchiveRange(indexData: openArray[uint8], requestedPath: string):
    tuple[offset, byteLength: uint32] =
  if indexData.len < 4:
    raise newException(IOError, "CRASH.BH is shorter than its header")

  let target = normalizeArchivePath(requestedPath)
  var cursor = 4
  while cursor < indexData.len:
    if indexData.len - cursor < 4:
      raise newException(IOError, "Truncated path length in CRASH.BH")
    let pathLength = readU32LE(indexData, cursor)
    let remaining = indexData.len - cursor - 4
    if remaining < 8 or pathLength == 0 or
        uint64(pathLength) > uint64(remaining - 8):
      raise newException(IOError, "Invalid path length in CRASH.BH entry")

    let pathStart = cursor + 4
    let pathEnd = pathStart + int(pathLength)
    var path = newString(int(pathLength))
    for index in 0 ..< path.len:
      path[index] = char(indexData[pathStart + index])
    let dataOffset = readU32LE(indexData, pathEnd)
    let byteLength = readU32LE(indexData, pathEnd + 4)
    if normalizeArchivePath(path) == target:
      return (dataOffset, byteLength)
    cursor = pathEnd + 8

  raise newException(IOError, "Path not found in CRASH.BH: " & requestedPath)

proc readSections(image: IsoImage, dataFile: IsoEntry, resourceOffset: int64,
    resourceLength: uint32): seq[SectionRange] =
  if resourceLength < 12:
    raise newException(IOError, "Resource is shorter than its section header")
  let fixedHeader = image.readSlice(dataFile, resourceOffset, 12)
  let sectionCount = readU32LE(fixedHeader, 4)
  let headerLength = 12'u64 + uint64(sectionCount) * 12'u64
  if headerLength > uint64(resourceLength) or headerLength > uint64(high(int)):
    raise newException(IOError, "Section table extends beyond its resource")
  let table = image.readSlice(dataFile, resourceOffset, int(headerLength))

  for index in 0 ..< int(sectionCount):
    let entryOffset = 12 + index * 12
    let section = SectionRange(
      offset: readU32LE(table, entryOffset),
      byteLength: readU32LE(table, entryOffset + 4),
      id: readU32LE(table, entryOffset + 8)
    )
    if uint64(section.offset) + uint64(section.byteLength) >
        uint64(resourceLength):
      raise newException(IOError, "Section range extends beyond its resource")
    result.add(section)

proc readGraphicsItemFromIso*(imagePath, resourcePath: string,
    childSectionId, itemId: uint32): seq[uint8] =
  ## Read one bounded graphics item from the ISO without extracting it.
  let image = openIso(imagePath)
  defer: image.close()

  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let archiveRange = findArchiveRange(indexData, resourcePath)
  if uint64(archiveRange.offset) + uint64(archiveRange.byteLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Archive resource extends beyond CRASH.BD")

  let resourceOffset = int64(archiveRange.offset)
  let resourceSections = readSections(image, dataFile, resourceOffset,
    archiveRange.byteLength)
  for graphicsSection in resourceSections:
    if graphicsSection.id notin [6'u32, 11'u32]:
      continue

    let graphicsOffset = resourceOffset + int64(graphicsSection.offset)
    let childSections = readSections(image, dataFile, graphicsOffset,
      graphicsSection.byteLength)
    for childSection in childSections:
      if childSection.id != childSectionId:
        continue

      let textureTableOffset = graphicsOffset + int64(childSection.offset)
      let textureTable = image.readSlice(dataFile, textureTableOffset,
        int(childSection.byteLength))
      if textureTable.len < 12:
        raise newException(IOError, "Graphics item table is shorter than its header")
      let itemCount = readU32LE(textureTable, 4)
      let itemTableLength = 12'u64 + uint64(itemCount) * 12'u64
      if itemTableLength > uint64(textureTable.len) or
          itemTableLength > uint64(childSection.byteLength):
        raise newException(IOError, "Graphics item table exceeds its section")

      for itemIndex in 0 ..< int(itemCount):
        let entryOffset = 12 + itemIndex * 12
        let itemOffset = readU32LE(textureTable, entryOffset)
        let itemLength = readU32LE(textureTable, entryOffset + 4)
        let foundItemId = readU32LE(textureTable, entryOffset + 8)
        if foundItemId != itemId:
          continue
        let itemEnd = uint64(itemOffset) + uint64(itemLength)
        if itemOffset < itemTableLength or itemEnd > uint64(textureTable.len) or
            itemEnd > uint64(childSection.byteLength):
          raise newException(IOError, "Graphics item range exceeds its section")
        return textureTable[int(itemOffset) ..< int(itemEnd)]

  raise newException(IOError, "Graphics item ID not found in resource: " & $itemId)

proc loadTextureFromIso*(imagePath, resourcePath: string,
    textureId: uint32): DecodedTexture =
  decodePsmT8(readGraphicsItemFromIso(imagePath, resourcePath, 0, textureId))
