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
import std/[os, sets, strutils]

const SectorSize = 2048

type DirectoryEntry = object
  name: string
  extentLba: uint32
  byteLength: uint32
  isDirectory: bool

proc readBytes(file: File, offset: int64, count: int): seq[uint8] =
  setFilePos(file, offset)
  result = newSeq[uint8](count)
  if count > 0 and readBuffer(file, result[0].addr, count) != count:
    raise newException(IOError, "Unexpected end of ISO image")

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc parseDirectoryEntry(data: openArray[uint8], offset, recordLength: int): DirectoryEntry =
  let nameLength = int(data[offset + 32])
  if recordLength < 33 + nameLength:
    raise newException(IOError, "Malformed ISO directory record")

  # ISO9660 stores many numeric fields twice (little- and big-endian); use the LE copy.
  result.extentLba = readU32LE(data, offset + 2)
  result.byteLength = readU32LE(data, offset + 10)
  result.isDirectory = (data[offset + 25] and 0x02) != 0

  if nameLength == 1 and data[offset + 33] <= 1:
    result.name = ""
  else:
    result.name = newString(nameLength)
    for i in 0 ..< nameLength:
      result.name[i] = char(data[offset + 33 + i])
    let versionSeparator = result.name.find(';')
    if versionSeparator >= 0:
      result.name = result.name[0 ..< versionSeparator]

proc inspectDirectory(file: File, directory: DirectoryEntry, prefix: string,
    visited: var HashSet[uint32], depth: int) =
  if depth > 16 or directory.extentLba in visited:
    return
  visited.incl(directory.extentLba)

  let contents = readBytes(
    file,
    int64(directory.extentLba) * SectorSize,
    int(directory.byteLength)
  )

  var offset = 0
  while offset < contents.len:
    let recordLength = int(contents[offset])
    if recordLength == 0:
      # Directory records do not cross sectors; zero padding advances to the next one.
      offset = ((offset div SectorSize) + 1) * SectorSize
      continue
    if recordLength < 34 or offset + recordLength > contents.len:
      raise newException(IOError, "Malformed ISO directory record")

    let entry = parseDirectoryEntry(contents, offset, recordLength)
    offset += recordLength
    if entry.name.len == 0:
      continue

    let path = if prefix.len == 0: entry.name else: prefix & "/" & entry.name
    let kind = if entry.isDirectory: "dir " else: "file"
    echo kind, "  lba=", entry.extentLba, "  bytes=", entry.byteLength, "  ", path

    if entry.isDirectory:
      inspectDirectory(file, entry, path, visited, depth + 1)

proc main() =
  if paramCount() != 1:
    quit("Usage: iso9660_inspect <image.iso>", 1)

  let imagePath = paramStr(1)
  var image: File
  if not open(image, imagePath, fmRead):
    quit("Could not open ISO image: " & imagePath, 1)
  defer: close(image)

  let descriptor = readBytes(image, int64(16 * SectorSize), SectorSize)
  # ISO9660 places its primary volume descriptor at logical block 16.
  if descriptor[0] != 1 or descriptor[1 .. 5] != @[uint8('C'), uint8('D'), uint8('0'), uint8('0'), uint8('1')] or descriptor[6] != 1:
    quit("No ISO9660 primary volume descriptor at sector 16", 1)

  var volumeName = newString(32)
  for i in 0 ..< volumeName.len:
    volumeName[i] = char(descriptor[40 + i])
  volumeName = volumeName.strip()

  let rootRecordLength = int(descriptor[156])
  let root = parseDirectoryEntry(descriptor, 156, rootRecordLength)
  let blockSize = int(descriptor[128]) or (int(descriptor[129]) shl 8)
  echo "ISO9660 volume: ", volumeName
  echo "Logical block size: ", blockSize
  echo "Root directory: lba=", root.extentLba, " bytes=", root.byteLength
  echo "Entries:"

  var visited = initHashSet[uint32]()
  inspectDirectory(image, root, "", visited, 0)

when isMainModule:
  main()
