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
import std/os

import iso9660

type CatalogEntry = object
  path: string
  dataOffset: uint32
  dataLength: uint32

proc readU32LE(data: string, offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "Unexpected end of index file")

  uint32(ord(data[offset])) or
    (uint32(ord(data[offset + 1])) shl 8) or
    (uint32(ord(data[offset + 2])) shl 16) or
    (uint32(ord(data[offset + 3])) shl 24)

proc parseEntry(data: string, offset: var int): CatalogEntry =
  let pathLength = readU32LE(data, offset)
  let remaining = data.len - offset - 4
  if remaining < 8 or pathLength == 0 or uint64(pathLength) > uint64(remaining - 8):
    raise newException(IOError, "Invalid path length in index entry")

  let pathStart = offset + 4
  let pathEnd = pathStart + int(pathLength)
  result.path = data[pathStart ..< pathEnd]

  # The fixed fields following each path point into the paired data file.
  result.dataOffset = readU32LE(data, pathEnd)
  result.dataLength = readU32LE(data, pathEnd + 4)
  offset = pathEnd + 8

proc inspectCatalog(data: string, dataLength: int64) =
  if data.len < 4:
    raise newException(IOError, "Index file is shorter than its header")

  let headerWord = readU32LE(data, 0)
  var offset = 4
  var entryCount = 0
  var expectedDataOffset = 0'u64
  var rangesAreContiguous = true

  echo "Index header word: ", headerWord, " (meaning not yet identified)"

  # Parse to EOF because the header word has not been confirmed as an entry count.
  while offset < data.len:
    let entry = parseEntry(data, offset)
    let rangeEnd = uint64(entry.dataOffset) + uint64(entry.dataLength)

    # The observed entries partition the paired data file in table order.
    if uint64(entry.dataOffset) != expectedDataOffset:
      rangesAreContiguous = false
      echo "Range gap or overlap before entry ", entryCount
    if dataLength >= 0 and rangeEnd > uint64(dataLength):
      raise newException(IOError, "Index entry extends beyond paired data file: " & entry.path)

    echo entry.path, "  offset=", entry.dataOffset, "  bytes=", entry.dataLength
    expectedDataOffset = rangeEnd
    inc entryCount

  echo "Entries parsed: ", entryCount
  echo "Indexed data ends at byte: ", expectedDataOffset

  if rangesAreContiguous:
    echo "Ranges are contiguous from byte zero."
  if dataLength >= 0:
    echo "Paired data file bytes: ", dataLength
    if expectedDataOffset == uint64(dataLength) and rangesAreContiguous:
      echo "Index covers the complete paired data file."

proc inspectIsoCatalog(imagePath, indexPath, dataPath: string) =
  let image = openIso(imagePath)
  defer: image.close()

  let indexEntry = image.findEntry(indexPath)
  let dataEntry = image.findEntry(dataPath)
  if indexEntry.isDirectory or dataEntry.isDirectory:
    raise newException(IOError, "Index and paired data paths must refer to files")

  let indexBytes = image.readSlice(indexEntry, 0, int(indexEntry.byteLength))
  var indexData = newString(indexBytes.len)
  for i, value in indexBytes:
    indexData[i] = char(value)

  echo "ISO volume: ", image.volumeName
  echo "Index path: ", indexPath, " (", indexEntry.byteLength, " bytes)"
  echo "Paired data path: ", dataPath, " (", dataEntry.byteLength, " bytes)"
  inspectCatalog(indexData, int64(dataEntry.byteLength))

proc main() =
  if paramCount() > 0 and paramStr(1) == "--iso":
    if paramCount() notin [2, 4]:
      quit("Usage: bh_inspect --iso <image.iso> [index-path data-path]", 1)
    let indexPath = if paramCount() == 4: paramStr(3) else: "CRASH6/CRASH.BH"
    let dataPath = if paramCount() == 4: paramStr(4) else: "CRASH6/CRASH.BD"
    try:
      inspectIsoCatalog(paramStr(2), indexPath, dataPath)
    except IOError as error:
      quit(error.msg, 1)
  else:
    if paramCount() notin 1 .. 2:
      quit("Usage: bh_inspect <index.bh> [data.bd]", 1)
    let indexData = readFile(paramStr(1))
    let dataLength = if paramCount() == 2: getFileSize(paramStr(2)) else: -1'i64
    try:
      inspectCatalog(indexData, dataLength)
    except IOError as error:
      quit(error.msg, 1)

when isMainModule:
  main()
