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
import std/[os, tables, strutils]

import iso9660

const
  TableHeaderSize = 8
  RecordSize = 20

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc readU16LE(data: openArray[uint8], offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc readU32BE(data: openArray[uint8], offset: int): uint32 =
  (uint32(data[offset]) shl 24) or
    (uint32(data[offset + 1]) shl 16) or
    (uint32(data[offset + 2]) shl 8) or
    uint32(data[offset + 3])

proc hexBytes(data: openArray[uint8]): string =
  for index, value in data:
    if index > 0:
      result.add(' ')
    result.add(toHex(int(value), 2))

proc inspectTables(imagePath, headerPath, dataPath: string) =
  let image = openIso(imagePath)
  defer: image.close()

  let headerEntry = image.findEntry(headerPath)
  let dataEntry = image.findEntry(dataPath)
  if headerEntry.isDirectory or dataEntry.isDirectory:
    raise newException(IOError, "MH and MB paths must refer to files")

  let headerData = image.readSlice(headerEntry, 0, int(headerEntry.byteLength))
  if headerData.len < TableHeaderSize:
    raise newException(IOError, "MH file is shorter than its table header")

  let declaredCount = readU32LE(headerData, 0)
  let headerChunkBytes = readU32LE(headerData, 4)
  if uint64(declaredCount) > uint64((headerData.len - TableHeaderSize) div RecordSize):
    raise newException(IOError, "MH record count exceeds the table data")

  let actualCount = (headerData.len - TableHeaderSize) div RecordSize
  echo "ISO volume: ", image.volumeName
  echo "MH path: ", headerPath, " (", headerEntry.byteLength, " bytes)"
  echo "MB path: ", dataPath, " (", dataEntry.byteLength, " bytes)"
  echo "Header words: ", declaredCount, ", ", headerChunkBytes
  echo "Records described by first word: ", declaredCount
  echo "20-byte records available after header: ", actualCount
  if actualCount * RecordSize + TableHeaderSize != headerData.len:
    echo "Trailing bytes after complete records: ",
      headerData.len - (actualCount * RecordSize + TableHeaderSize)

  var typeCounts = initTable[uint32, int]()
  var inBoundsCount = 0
  var alignedTypeOneCount = 0
  var alignedTypeOneOffsetCount = 0
  var typeOnePairedTrackRanges = 0
  var typeOneValidEndOffsets = 0
  var typeOneCount = 0
  var typeZeroCount = 0
  var typeZeroRanges = initTable[string, int]()
  var typeZeroMagicCount = 0
  var typeZeroLengthCheckCount = 0
  var typeZeroWordCheckCount = 0
  var sampleCount = 0
  var typeOneZeroPrefixCount = 0
  var typeOneStridePatternCount = 0
  var typeOneEndMarkerCount = 0
  var typeOneStridePatternRecords: seq[int]
  var typeOneEndMarkerRecords: seq[int]
  var typeOneFrameCount = 0
  var typeOnePlausibleFrameCount = 0
  var typeOneInvalidFrameHeaders = 0
  var typeOneFrameHeaderBytes: array[256, int]
  var typeOneFrameFlagBytes: array[256, int]
  var typeOneWord3Counts = initTable[uint32, int]()
  var typeOneWord4Counts = initTable[uint32, int]()
  var typeOneWord4AlignedCount = 0
  var typeOneWord4Minimum = high(uint32)
  var typeOneWord4Maximum = 0'u32

  for recordIndex in 0 ..< int(declaredCount):
    let base = TableHeaderSize + recordIndex * RecordSize
    let kind = readU32LE(headerData, base)
    let byteLength = readU32LE(headerData, base + 4)
    let byteOffset = readU32LE(headerData, base + 8)
    typeCounts.mgetOrPut(kind, 0).inc

    let rangeEnd = uint64(byteOffset) + uint64(byteLength)
    if rangeEnd > uint64(dataEntry.byteLength):
      echo "Out-of-bounds record ", recordIndex, ": offset=", byteOffset,
        " bytes=", byteLength
      continue
    inc inBoundsCount

    if kind == 1:
      inc typeOneCount
      let word3 = readU32LE(headerData, base + 12)
      let word4 = readU32LE(headerData, base + 16)
      if headerChunkBytes > 0 and
          uint64(byteLength) mod (uint64(headerChunkBytes) * 2) == 0:
        inc typeOnePairedTrackRanges
      if word4 > 0 and word4 <= headerChunkBytes and word4 mod 16 == 0:
        inc typeOneValidEndOffsets
      typeOneWord3Counts.mgetOrPut(word3, 0).inc
      typeOneWord4Counts.mgetOrPut(word4, 0).inc
      if word4 mod 16 == 0:
        inc typeOneWord4AlignedCount
      typeOneWord4Minimum = min(typeOneWord4Minimum, word4)
      typeOneWord4Maximum = max(typeOneWord4Maximum, word4)
      echo "Type-1 table record ", recordIndex, ": length=", byteLength,
        " offset=", byteOffset,
        " word3=", word3,
        " word4=", word4
      if byteLength mod 16 == 0:
        inc alignedTypeOneCount
      if byteOffset mod 16 == 0:
        inc alignedTypeOneOffsetCount

      if byteLength >= 16:
        let prefix = image.readSlice(dataEntry, int64(byteOffset),
          min(228, int(byteLength)))
        var zeroPrefix = true
        for index in 0 ..< 16:
          if prefix[index] != 0:
            zeroPrefix = false
            break
        if zeroPrefix:
          inc typeOneZeroPrefixCount

        if prefix.len >= 228:
          var stridePattern = true
          for offset in countup(16, 208, 16):
            if readU16LE(prefix, offset) != 12:
              stridePattern = false
              break
          if stridePattern:
            inc typeOneStridePatternCount
            typeOneStridePatternRecords.add(recordIndex)
          if readU32LE(prefix, 224) == 0x44:
            inc typeOneEndMarkerCount
            typeOneEndMarkerRecords.add(recordIndex)

        # Check each aligned 16-byte block against the PSX ADPCM header shape.
        let payload = image.readSlice(dataEntry, int64(byteOffset),
          int(byteLength))
        for frameOffset in countup(0, payload.len - 16, 16):
          let header = payload[frameOffset]
          let flags = payload[frameOffset + 1]
          let filter = header shr 4
          inc typeOneFrameCount
          inc typeOneFrameHeaderBytes[int(header)]
          inc typeOneFrameFlagBytes[int(flags)]
          if filter <= 4 and flags < 7:
            inc typeOnePlausibleFrameCount
          else:
            inc typeOneInvalidFrameHeaders

      if sampleCount < 4:
        let sample = image.readSlice(dataEntry, int64(byteOffset),
          min(32, int(byteLength)))
        echo "Type-1 record ", recordIndex, ": offset=", byteOffset,
          " bytes=", byteLength, " offset-mod-16=", byteOffset mod 16,
          " length-mod-16=", byteLength mod 16,
          " first-bytes=", hexBytes(sample)
        inc sampleCount
    elif kind == 0:
      inc typeZeroCount
      typeZeroRanges.mgetOrPut($byteOffset & ":" & $byteLength, 0).inc
      if byteLength >= 20:
        let prefix = image.readSlice(dataEntry, int64(byteOffset),
          min(48, int(byteLength)))
        if prefix[0 .. 3] == @[uint8('M'), uint8('S'), uint8('V'), uint8('p')]:
          inc typeZeroMagicCount
          let fieldAtFour = readU32BE(prefix, 4)
          let fieldAtTwelve = readU32BE(prefix, 12)
          let fieldAtSixteen = readU32BE(prefix, 16)
          var streamName = ""
          if prefix.len > 32:
            for nameOffset in 32 ..< prefix.len:
              if prefix[nameOffset] == 0:
                break
              streamName.add(char(prefix[nameOffset]))
          if uint64(fieldAtTwelve) + 48 == uint64(byteLength):
            inc typeZeroLengthCheckCount
          if fieldAtSixteen == readU32LE(headerData, base + 12):
            inc typeZeroWordCheckCount
          echo "Type-0 MSVp record ", recordIndex, ": offset=", byteOffset,
            " bytes=", byteLength, " header word=", fieldAtFour,
            " channel data bytes=", fieldAtTwelve,
            " sample rate=", fieldAtSixteen,
            " name candidate=\"", streamName, "\"",
            " payload+48 matches record=", uint64(fieldAtTwelve) + 48 == uint64(byteLength),
            " prefix=", hexBytes(prefix)
        else:
          echo "Type-0 record ", recordIndex,
            " does not begin with MSVp: ", hexBytes(prefix[0 .. 3])

  echo "Type counts:"
  for kind, count in typeCounts:
    echo "  ", kind, ": ", count
  echo "Ranges within MB bounds: ", inBoundsCount, " / ", declaredCount
  echo "Type-0 ranges beginning MSVp: ", typeZeroMagicCount, " / ", typeZeroCount
  echo "Distinct type-0 offset/length ranges: ", typeZeroRanges.len,
    " (", typeZeroCount - typeZeroRanges.len, " repeated table entries)"
  echo "Type-0 MSVp ranges where BE32@+12 + 48 equals MH length: ",
    typeZeroLengthCheckCount, " / ", typeZeroMagicCount
  echo "Type-0 MSVp ranges where BE32@+16 equals MH word 3: ",
    typeZeroWordCheckCount, " / ", typeZeroMagicCount
  echo "Type-1 lengths divisible by 16: ", alignedTypeOneCount,
    " / ", typeOneCount
  echo "Type-1 offsets divisible by 16: ", alignedTypeOneOffsetCount,
    " / ", typeOneCount
  echo "Type-1 ranges containing whole pairs of header-sized track chunks: ",
    typeOnePairedTrackRanges, " / ", typeOneCount
  echo "Type-1 end offsets within a track chunk and aligned to 16 bytes: ",
    typeOneValidEndOffsets, " / ", typeOneCount
  echo "Type-1 raw word3 value frequencies (possible sample-rate field):"
  for value, count in typeOneWord3Counts:
    echo "  ", value, ": ", count
  echo "Type-1 raw word4: min=", typeOneWord4Minimum,
    " max=", typeOneWord4Maximum,
    " distinct values=", typeOneWord4Counts.len,
    " divisible by 16=", typeOneWord4AlignedCount, " / ", typeOneCount
  echo "Type-1 ranges with a 16-byte zero prefix: ", typeOneZeroPrefixCount,
    " / ", typeOneCount
  echo "Type-1 ranges with 0x000C words at +0x10..+0xD0: ",
    typeOneStridePatternCount, " / ", typeOneCount
  echo "  Matching record indices: ", typeOneStridePatternRecords
  echo "Type-1 ranges with 0x44 at +0xE0: ", typeOneEndMarkerCount,
    " / ", typeOneCount
  echo "  Matching record indices: ", typeOneEndMarkerRecords
  echo "Type-1 aligned 16-byte blocks: ", typeOneFrameCount
  echo "  PSX ADPCM-like header candidates (filter<=4, flags<7): ",
    typeOnePlausibleFrameCount, " / ", typeOneFrameCount
  echo "  Blocks outside those PSX ADPCM-like limits: ",
    typeOneInvalidFrameHeaders
  echo "  Most common first-byte headers:"
  var shownHeaderValues: array[256, bool]
  for _ in 0 ..< 12:
    var bestValue = -1
    var bestCount = 0
    for value in 0 .. 255:
      if not shownHeaderValues[value] and
          typeOneFrameHeaderBytes[value] > bestCount:
        bestValue = value
        bestCount = typeOneFrameHeaderBytes[value]
    if bestValue < 0:
      break
    shownHeaderValues[bestValue] = true
    echo "    0x", toHex(bestValue, 2), ": ", bestCount
  echo "  Common second-byte flag values (0..7):"
  for value in 0 .. 7:
    echo "    0x", toHex(value, 2), ": ", typeOneFrameFlagBytes[value]

proc main() =
  if paramCount() notin [1, 3]:
    quit("Usage: mh_inspect <image.iso> [mh-path mb-path]", 1)

  let headerPath = if paramCount() == 3: paramStr(2) else: "CRASH6/MUSIC.MH"
  let dataPath = if paramCount() == 3: paramStr(3) else: "CRASH6/MUSIC.MB"
  try:
    inspectTables(paramStr(1), headerPath, dataPath)
  except IOError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
