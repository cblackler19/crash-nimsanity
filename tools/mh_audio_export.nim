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
# LOSS OF USE, DATA, OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE,
# OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.
#
import std/[os, strutils]

import iso9660

const
  TableHeaderSize = 8
  RecordSize = 20
  BlockSize = 16
  SamplesPerBlock = 28
  PredictorCoefficients: array[5, array[2, int]] = [
    [0, 0], [60, 0], [115, -52], [98, -55], [122, -60]]

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc appendU16LE(data: var seq[uint8], value: uint16) =
  data.add(uint8(value and 0xFF))
  data.add(uint8(value shr 8))

proc appendU32LE(data: var seq[uint8], value: uint32) =
  data.add(uint8(value and 0xFF))
  data.add(uint8((value shr 8) and 0xFF))
  data.add(uint8((value shr 16) and 0xFF))
  data.add(uint8(value shr 24))

proc decodeBlock(blockData: openArray[uint8], previousOne,
    previousTwo: var int): array[SamplesPerBlock, int16] =
  let shift = int(blockData[0] and 0x0F)
  let filter = int(blockData[0] shr 4)
  if filter >= PredictorCoefficients.len:
    raise newException(IOError, "Unsupported ADPCM predictor in block")

  for sampleIndex in 0 ..< SamplesPerBlock:
    let packed = blockData[2 + sampleIndex div 2]
    let nibble = if sampleIndex mod 2 == 0:
      int(packed and 0x0F)
    else:
      int(packed shr 4)
    let signedNibble = if nibble >= 8: nibble - 16 else: nibble
    let residual = (signedNibble * 4096) shr shift
    let coefficients = PredictorCoefficients[filter]
    let predicted = (previousOne * coefficients[0] +
      previousTwo * coefficients[1]) div 64
    let decoded = max(-32768, min(32767, residual + predicted))
    result[sampleIndex] = int16(decoded)
    previousTwo = previousOne
    previousOne = decoded

proc makeWav(left, right: openArray[int16], sampleRate: uint32): seq[uint8] =
  if left.len != right.len:
    raise newException(IOError, "Stereo channels have different sample counts")
  let dataBytes = uint32(left.len * 4)
  result = @[
    uint8('R'), uint8('I'), uint8('F'), uint8('F')]
  result.appendU32LE(36'u32 + dataBytes)
  result.add([uint8('W'), uint8('A'), uint8('V'), uint8('E'),
    uint8('f'), uint8('m'), uint8('t'), uint8(' ')])
  result.appendU32LE(16)
  result.appendU16LE(1)
  result.appendU16LE(2)
  result.appendU32LE(sampleRate)
  result.appendU32LE(sampleRate * 4)
  result.appendU16LE(4)
  result.appendU16LE(16)
  result.add([uint8('d'), uint8('a'), uint8('t'), uint8('a')])
  result.appendU32LE(dataBytes)
  for index in 0 ..< left.len:
    result.appendU16LE(cast[uint16](left[index]))
    result.appendU16LE(cast[uint16](right[index]))

proc exportRecord(imagePath: string, recordIndex: int, outputPath: string) =
  let image = openIso(imagePath)
  defer: image.close()

  let header = image.findEntry("CRASH6/MUSIC.MH")
  let payload = image.findEntry("CRASH6/MUSIC.MB")
  let headerData = image.readSlice(header, 0, int(header.byteLength))
  let recordCount = int(readU32LE(headerData, 0))
  if recordIndex < 0 or recordIndex >= recordCount:
    raise newException(IOError, "Record index is outside the MUSIC.MH table")

  let recordBase = TableHeaderSize + recordIndex * RecordSize
  let kind = readU32LE(headerData, recordBase)
  if kind != 1:
    raise newException(IOError, "Selected record is not a type-1 range")
  let byteLength = int(readU32LE(headerData, recordBase + 4))
  let byteOffset = readU32LE(headerData, recordBase + 8)
  let sampleRate = readU32LE(headerData, recordBase + 12)
  if byteLength mod (BlockSize * 2) != 0:
    raise newException(IOError, "Type-1 range is not a whole number of stereo block pairs")
  if sampleRate notin [32000'u32, 48000'u32]:
    raise newException(IOError, "Unrecognized candidate sample rate")

  let encoded = image.readSlice(payload, int64(byteOffset), byteLength)
  let samplesPerChannel = byteLength div (BlockSize * 2) * SamplesPerBlock
  var leftSamples = newSeqOfCap[int16](samplesPerChannel)
  var rightSamples = newSeqOfCap[int16](samplesPerChannel)
  var leftPreviousOne = 0
  var leftPreviousTwo = 0
  var rightPreviousOne = 0
  var rightPreviousTwo = 0
  for pairOffset in countup(0, encoded.len - BlockSize * 2, BlockSize * 2):
    let leftBlock = decodeBlock(encoded.toOpenArray(pairOffset,
      pairOffset + BlockSize - 1), leftPreviousOne, leftPreviousTwo)
    let rightBlock = decodeBlock(encoded.toOpenArray(pairOffset + BlockSize,
      pairOffset + BlockSize * 2 - 1), rightPreviousOne, rightPreviousTwo)
    for sample in leftBlock:
      leftSamples.add(sample)
    for sample in rightBlock:
      rightSamples.add(sample)

  let wav = makeWav(leftSamples, rightSamples, sampleRate)
  writeFile(outputPath, cast[string](wav))
  echo "Record ", recordIndex, ": ", byteLength, " encoded bytes, ",
    leftSamples.len, " stereo sample frames at ", sampleRate, " Hz"
  echo "Wrote candidate stereo PSX ADPCM decode to ", outputPath
  echo "This diagnostic assumes alternating 16-byte channel blocks and resets each channel's predictor at the record boundary."

proc main() =
  if paramCount() notin [2, 3]:
    quit("Usage: mh_audio_export <image.iso> <type-1-record-index> [output.wav]", 1)

  let outputPath = if paramCount() == 3: paramStr(3) else:
    "music-record-" & paramStr(2) & ".wav"
  try:
    exportRecord(paramStr(1), parseInt(paramStr(2)), outputPath)
  except CatchableError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
