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

proc exportRecord(imagePath: string, recordIndex: int, outputPath: string,
    trackChunkBytesOverride: int, sampleRateOverride: uint32) =
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
  let tableSampleRate = readU32LE(headerData, recordBase + 12)
  let trackEndOffset = int(readU32LE(headerData, recordBase + 16))
  let tableTrackChunkBytes = int(readU32LE(headerData, 4))
  let sampleRate = if sampleRateOverride > 0: sampleRateOverride else: tableSampleRate
  let trackChunkBytes = if trackChunkBytesOverride > 0:
    trackChunkBytesOverride
  else:
    tableTrackChunkBytes
  if trackChunkBytes <= 0 or trackChunkBytes mod BlockSize != 0:
    raise newException(IOError, "Track chunk size must be a positive multiple of 16 bytes")
  if byteLength <= 0:
    raise newException(IOError, "Type-1 range must contain at least one track pair")
  if byteLength mod (trackChunkBytes * 2) != 0:
    raise newException(IOError, "Type-1 range is not a whole number of paired track chunks")
  if trackEndOffset <= 0 or trackEndOffset > trackChunkBytes or
      trackEndOffset mod BlockSize != 0:
    raise newException(IOError,
      "MUSIC.MH track end offset must be a positive, block-aligned size within the track chunk")
  if sampleRate < 8000 or sampleRate > 96000:
    raise newException(IOError, "Candidate sample rate must be between 8 kHz and 96 kHz")

  let encoded = image.readSlice(payload, int64(byteOffset), byteLength)
  let trackPairCount = byteLength div (trackChunkBytes * 2)
  let samplesPerChannel = ((trackPairCount - 1) * trackChunkBytes +
    trackEndOffset) div BlockSize * SamplesPerBlock
  var leftSamples = newSeqOfCap[int16](samplesPerChannel)
  var rightSamples = newSeqOfCap[int16](samplesPerChannel)
  var leftPreviousOne = 0
  var leftPreviousTwo = 0
  var rightPreviousOne = 0
  var rightPreviousTwo = 0
  let stereoChunkBytes = trackChunkBytes * 2
  for pairOffset in countup(0, encoded.len - stereoChunkBytes, stereoChunkBytes):
    let isFinalPair = pairOffset == encoded.len - stereoChunkBytes
    let validTrackBytes = if isFinalPair: trackEndOffset else: trackChunkBytes
    for blockOffset in countup(pairOffset,
        pairOffset + validTrackBytes - BlockSize, BlockSize):
      let leftBlock = decodeBlock(encoded.toOpenArray(blockOffset,
        blockOffset + BlockSize - 1), leftPreviousOne, leftPreviousTwo)
      for sample in leftBlock:
        leftSamples.add(sample)
    for blockOffset in countup(pairOffset + trackChunkBytes,
        pairOffset + trackChunkBytes + validTrackBytes - BlockSize, BlockSize):
      let rightBlock = decodeBlock(encoded.toOpenArray(blockOffset,
        blockOffset + BlockSize - 1), rightPreviousOne, rightPreviousTwo)
      for sample in rightBlock:
        rightSamples.add(sample)

  let wav = makeWav(leftSamples, rightSamples, sampleRate)
  writeFile(outputPath, cast[string](wav))
  echo "Record ", recordIndex, ": ", byteLength, " encoded bytes, ",
    leftSamples.len, " stereo sample frames at ", sampleRate, " Hz"
  echo "Wrote candidate two-track interleaved PSX ADPCM decode to ", outputPath
  echo "Track chunk size: ", trackChunkBytes, " bytes",
    if trackChunkBytesOverride > 0: " (override)" else: " (from MUSIC.MH header)"
  echo "Final track chunk: ", trackEndOffset, " valid bytes per track (from MUSIC.MH +16)."
  echo "Track 0 is left; track 1 is right. Predictor history resets at the record boundary."

proc main() =
  if paramCount() notin 2 .. 5:
    quit("Usage: mh_audio_export <image.iso> <type-1-record-index> [output.wav] [track-chunk-bytes] [sample-rate]", 1)

  let outputPath = if paramCount() >= 3: paramStr(3) else:
    "music-record-" & paramStr(2) & ".wav"
  let trackChunkBytesOverride = if paramCount() >= 4: parseInt(paramStr(4)) else: 0
  let sampleRateOverride = if paramCount() == 5:
    uint32(parseInt(paramStr(5)))
  else:
    0'u32
  try:
    exportRecord(paramStr(1), parseInt(paramStr(2)), outputPath,
      trackChunkBytesOverride, sampleRateOverride)
  except CatchableError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
