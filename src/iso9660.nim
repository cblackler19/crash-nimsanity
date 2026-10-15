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

type
  IsoEntry* = object
    name*: string
    extentLba*: uint32
    byteLength*: uint32
    isDirectory*: bool

  IsoImage* = ref object
    file: File
    logicalBlockSize*: int
    volumeName*: string
    root: IsoEntry

proc readBytes(file: File, offset: int64, count: int): seq[uint8] =
  if offset < 0 or count < 0:
    raise newException(IOError, "Invalid ISO read range")
  setFilePos(file, offset)
  result = newSeq[uint8](count)
  if count > 0 and readBuffer(file, result[0].addr, count) != count:
    raise newException(IOError, "Unexpected end of ISO image")

proc readU16LE(data: openArray[uint8], offset: int): int =
  int(data[offset]) or (int(data[offset + 1]) shl 8)

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc parseDirectoryEntry(data: openArray[uint8], offset, recordLength: int): IsoEntry =
  if recordLength < 34 or offset < 0 or offset + recordLength > data.len:
    raise newException(IOError, "Malformed ISO directory record")

  let nameLength = int(data[offset + 32])
  if recordLength < 33 + nameLength:
    raise newException(IOError, "Malformed ISO directory record name")

  # ISO9660 duplicates numeric fields in both byte orders; this reader uses the LE copies.
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

proc readSlice*(image: IsoImage, entry: IsoEntry, offset: int64,
    count: int): seq[uint8] =
  ## Read a bounded section of a file directly from the ISO image.
  if image.isNil or image.file == nil:
    raise newException(IOError, "ISO image is closed")
  if entry.isDirectory:
    raise newException(IOError, "Cannot read file data from a directory entry")
  if offset < 0 or count < 0 or offset > int64(entry.byteLength) or
      int64(count) > int64(entry.byteLength) - offset:
    raise newException(IOError, "Requested range exceeds ISO file entry")

  let imageOffset = int64(entry.extentLba) * int64(image.logicalBlockSize) + offset
  readBytes(image.file, imageOffset, count)

proc readDirectory(image: IsoImage, directory: IsoEntry): seq[IsoEntry] =
  if not directory.isDirectory:
    raise newException(IOError, "ISO path is not a directory")
  let contents = readBytes(
    image.file,
    int64(directory.extentLba) * int64(image.logicalBlockSize),
    int(directory.byteLength)
  )

  var offset = 0
  while offset < contents.len:
    let recordLength = int(contents[offset])
    if recordLength == 0:
      # Directory records cannot cross logical blocks; zero padding skips to the next block.
      offset = ((offset div image.logicalBlockSize) + 1) * image.logicalBlockSize
      continue

    let entry = parseDirectoryEntry(contents, offset, recordLength)
    offset += recordLength
    if entry.name.len > 0:
      result.add(entry)

proc openIso*(imagePath: string): IsoImage =
  ## Open a plain ISO9660 image for read-only, on-demand file access.
  new(result)
  if not open(result.file, imagePath, fmRead):
    raise newException(IOError, "Could not open ISO image: " & imagePath)

  try:
    let descriptor = readBytes(result.file, 16'i64 * 2048, 2048)
    if descriptor[0] != 1 or
        descriptor[1 .. 5] != @[uint8('C'), uint8('D'), uint8('0'), uint8('0'), uint8('1')] or
        descriptor[6] != 1:
      raise newException(IOError, "No ISO9660 primary volume descriptor at sector 16")

    result.logicalBlockSize = readU16LE(descriptor, 128)
    if result.logicalBlockSize <= 0:
      raise newException(IOError, "Invalid ISO logical block size")

    result.volumeName = newString(32)
    for i in 0 ..< result.volumeName.len:
      result.volumeName[i] = char(descriptor[40 + i])
    result.volumeName = result.volumeName.strip()

    let rootRecordLength = int(descriptor[156])
    result.root = parseDirectoryEntry(descriptor, 156, rootRecordLength)
    if not result.root.isDirectory:
      raise newException(IOError, "ISO root record is not a directory")
  except:
    close(result.file)
    result.file = nil
    raise

proc close*(image: IsoImage) =
  if not image.isNil and image.file != nil:
    close(image.file)
    image.file = nil

proc rootEntry*(image: IsoImage): IsoEntry =
  if image.isNil or image.file == nil:
    raise newException(IOError, "ISO image is closed")
  image.root

proc listDirectory*(image: IsoImage, path = ""): seq[IsoEntry] =
  if image.isNil or image.file == nil:
    raise newException(IOError, "ISO image is closed")

  var directory = image.root
  let normalizedPath = path.replace('\\', '/')
  for component in normalizedPath.split('/'):
    if component.len == 0 or component == ".":
      continue
    if component == "..":
      raise newException(IOError, "Parent traversal is not supported in ISO paths")

    var found = false
    for entry in readDirectory(image, directory):
      if entry.isDirectory and cmpIgnoreCase(entry.name, component) == 0:
        directory = entry
        found = true
        break
    if not found:
      raise newException(IOError, "ISO directory not found: " & path)

  readDirectory(image, directory)

proc findEntry*(image: IsoImage, path: string): IsoEntry =
  if image.isNil or image.file == nil:
    raise newException(IOError, "ISO image is closed")

  var components: seq[string]
  for component in path.replace('\\', '/').split('/'):
    if component.len == 0 or component == ".":
      continue
    if component == "..":
      raise newException(IOError, "Parent traversal is not supported in ISO paths")
    components.add(component)

  if components.len == 0:
    return image.root

  var directory = image.root
  for index, component in components:
    var found = false
    for entry in readDirectory(image, directory):
      if cmpIgnoreCase(entry.name, component) == 0:
        if index < components.high and not entry.isDirectory:
          break
        result = entry
        found = true
        break
    if not found:
      raise newException(IOError, "ISO file or directory not found: " & path)
    if index < components.high:
      directory = result
