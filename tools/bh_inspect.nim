import std/os

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

proc inspectCatalog(indexPath: string, dataPath: string) =
  let data = readFile(indexPath)
  if data.len < 4:
    raise newException(IOError, "Index file is shorter than its header")

  let headerWord = readU32LE(data, 0)
  let dataLength = if dataPath.len > 0: getFileSize(dataPath) else: -1'i64
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

proc main() =
  if paramCount() notin 1 .. 2:
    quit("Usage: bh_inspect <index.bh> [data.bd]", 1)

  let dataPath = if paramCount() == 2: paramStr(2) else: ""
  inspectCatalog(paramStr(1), dataPath)

when isMainModule:
  main()
