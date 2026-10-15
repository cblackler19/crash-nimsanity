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
import std/[os, strutils]

import iso9660

type
  ArchiveEntry = object
    path: string
    dataOffset: uint32
    dataLength: uint32

  SectionEntry = object
    offset: uint32
    byteLength: uint32
    id: uint32

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "Unexpected end of file while reading a word")

  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc parseArchiveEntry(data: openArray[uint8], cursor: var int): ArchiveEntry =
  let pathLength = readU32LE(data, cursor)
  let remaining = data.len - cursor - 4
  if pathLength == 0 or uint64(pathLength) > uint64(remaining - 8):
    raise newException(IOError, "Invalid path length in CRASH.BH entry")

  let pathStart = cursor + 4
  let pathEnd = pathStart + int(pathLength)
  result.path = newString(int(pathLength))
  for i in 0 ..< result.path.len:
    result.path[i] = char(data[pathStart + i])

  result.dataOffset = readU32LE(data, pathEnd)
  result.dataLength = readU32LE(data, pathEnd + 4)
  cursor = pathEnd + 8

proc normalizedPath(path: string): string =
  path.replace('\\', '/').toLowerAscii()

proc findArchiveEntry(indexData: openArray[uint8], requestedPath: string): ArchiveEntry =
  if indexData.len < 4:
    raise newException(IOError, "CRASH.BH is shorter than its header")

  var cursor = 4
  let targetPath = normalizedPath(requestedPath)
  while cursor < indexData.len:
    let entry = parseArchiveEntry(indexData, cursor)
    if normalizedPath(entry.path) == targetPath:
      return entry

  raise newException(IOError, "Path not found in CRASH.BH: " & requestedPath)

proc inspectResource(resourceData: openArray[uint8], resourceLength: uint32) =
  if resourceLength < 12 or resourceData.len < 12:
    raise newException(IOError, "RM2/SM2 resource is shorter than its header")

  let magic = readU32LE(resourceData, 0)
  let sectionCount = readU32LE(resourceData, 4)
  let contentLength = readU32LE(resourceData, 8)
  if uint64(sectionCount) > uint64((resourceData.len - 12) div 12):
    raise newException(IOError, "Section table extends beyond the ISO read")

  let headerLength = 12'u64 + uint64(sectionCount) * 12'u64
  if headerLength > uint64(resourceLength):
    raise newException(IOError, "Section table extends beyond the resource")

  echo "Header word: 0x", toHex(magic, 8)
  echo "Sections: ", sectionCount
  echo "Content bytes: ", contentLength

  var sections: seq[SectionEntry]
  for index in 0 ..< int(sectionCount):
    let offset = 12 + index * 12
    sections.add(SectionEntry(
      offset: readU32LE(resourceData, offset),
      byteLength: readU32LE(resourceData, offset + 4),
      id: readU32LE(resourceData, offset + 8)
    ))

  var rangesAreContiguous = true
  var expectedOffset = headerLength
  for index, section in sections:
    let rangeEnd = uint64(section.offset) + uint64(section.byteLength)
    if uint64(section.offset) != expectedOffset:
      rangesAreContiguous = false
    if rangeEnd > uint64(resourceLength):
      raise newException(IOError, "Section range extends beyond the resource")

    echo "Section ", index, "  id=", section.id,
      "  offset=", section.offset, "  bytes=", section.byteLength
    expectedOffset = rangeEnd

  let measuredContentLength = uint64(resourceLength) - headerLength
  if uint64(contentLength) != measuredContentLength:
    echo "Header content size differs from resource length minus table: ",
      measuredContentLength
  if rangesAreContiguous and expectedOffset == uint64(resourceLength):
    echo "Section ranges are contiguous and cover the resource payload."

proc inspectIsoResource(imagePath, requestedPath: string) =
  let image = openIso(imagePath)
  defer: image.close()

  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let archiveEntry = findArchiveEntry(indexData, requestedPath)
  if uint64(archiveEntry.dataOffset) + uint64(archiveEntry.dataLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Archive entry extends beyond CRASH.BD")

  let resourceOffset = int64(archiveEntry.dataOffset)
  let fixedHeaderLength = int(min(archiveEntry.dataLength, 12'u32))
  let fixedHeader = image.readSlice(dataFile, resourceOffset, fixedHeaderLength)
  if fixedHeader.len < 12:
    raise newException(IOError, "RM2/SM2 resource is shorter than its header")

  let sectionCount = readU32LE(fixedHeader, 4)
  let headerLength = 12'u64 + uint64(sectionCount) * 12'u64
  if headerLength > uint64(archiveEntry.dataLength) or
      headerLength > uint64(high(int)):
    raise newException(IOError, "Section table extends beyond the resource")
  let resourceHeader = image.readSlice(dataFile, resourceOffset, int(headerLength))

  echo "ISO volume: ", image.volumeName
  echo "Resource: ", archiveEntry.path
  echo "Bytes: ", archiveEntry.dataLength
  inspectResource(resourceHeader, archiveEntry.dataLength)

proc main() =
  if paramCount() != 2:
    quit("Usage: rm2_inspect <image.iso> <path-inside-CRASH.BD>", 1)

  try:
    inspectIsoResource(paramStr(1), paramStr(2))
  except IOError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
