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
# The GS address tables follow the PSMT8 mapping described by Twinsanity Editor's
# MIT-licensed EzSwizzle.cs. Its copyright and license are in docs/THIRD_PARTY_LICENSES.md.
type
  DecodedTexture* = object
    width*: int
    height*: int
    rgba*: seq[uint8]

const
  gsMemoryBytes = 4 * 1024 * 1024
  block32 = [
    0, 1, 4, 5, 16, 17, 20, 21,
    2, 3, 6, 7, 18, 19, 22, 23,
    8, 9, 12, 13, 24, 25, 28, 29,
    10, 11, 14, 15, 26, 27, 30, 31
  ]
  columnWord32 = [0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15]
  block8 = [
    0, 1, 4, 5, 16, 17, 20, 21,
    2, 3, 6, 7, 18, 19, 22, 23,
    8, 9, 12, 13, 24, 25, 28, 29,
    10, 11, 14, 15, 26, 27, 30, 31
  ]
  columnWord8: array[2, array[64, int]] = [
    [
      0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
      2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15,
      8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
      10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7
    ],
    [
      8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
      10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7,
      0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
      2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15
    ]
  ]
  columnByte8 = [
    0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 3, 3,
    1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 3, 3
  ]

proc readU16LE(data: openArray[uint8], offset: int): uint16 =
  if offset < 0 or offset > data.len - 2:
    raise newException(ValueError, "Texture header is truncated")
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(ValueError, "Texture header is truncated")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc psmct32Address(x, y, bufferWidthPages: int): int =
  let page = x div 64 + (y div 32) * bufferWidthPages
  let pixelX = x mod 64
  let pixelY = y mod 32
  let blockX = pixelX div 8
  let blockY = pixelY div 8
  let blockIndex = block32[blockX + blockY * 8]
  let inBlockX = pixelX mod 8
  let inBlockY = pixelY mod 8
  let column = inBlockY div 2
  let columnWord = columnWord32[inBlockX + (inBlockY mod 2) * 8]
  (page * 2048 + blockIndex * 64 + column * 16 + columnWord) * 4

proc psmT8Address(x, y, bufferWidthPages: int): int =
  let page = x div 128 + (y div 64) * bufferWidthPages
  let pixelX = x mod 128
  let pixelY = y mod 64
  let blockX = pixelX div 16
  let blockY = pixelY div 16
  let blockIndex = block8[blockX + blockY * 8]
  let inBlockX = pixelX mod 16
  let inBlockY = pixelY mod 16
  let column = inBlockY div 4
  let columnIndex = inBlockX + (inBlockY mod 4) * 16
  let columnWord = columnWord8[column and 1][columnIndex]
  let columnByte = columnByte8[columnIndex]
  page * 8192 + blockIndex * 256 + column * 64 + columnWord * 4 + columnByte

proc decodePsmT8*(item: openArray[uint8]): DecodedTexture =
  if item.len < 228:
    raise newException(ValueError, "Texture item is shorter than its header")

  let textureSize = readU32LE(item, 0)
  if uint64(textureSize) + 4'u64 != uint64(item.len) or textureSize < 224:
    raise newException(ValueError, "Texture item size does not match its range")

  let widthExponent = int(int16(readU16LE(item, 8)))
  let heightExponent = int(int16(readU16LE(item, 10)))
  if widthExponent notin 0 .. 10 or heightExponent notin 0 .. 10:
    raise newException(ValueError, "Texture dimensions are outside supported bounds")
  if item[13] != 0x13:
    raise newException(ValueError, "Texture is not PSMT8")

  let width = 1 shl widthExponent
  let height = 1 shl heightExponent
  let textureBufferWidth = int(readU32LE(item, 48))
  let clutBasePointer = int(readU32LE(item, 76))
  let transferWidth = int(readU32LE(item, 180))
  let transferHeight = int(readU32LE(item, 184))
  let imageByteCount = int(textureSize - 224'u32)
  if textureBufferWidth < 1 or transferWidth <= 0 or transferHeight <= 0:
    raise newException(ValueError, "Texture has invalid GS buffer dimensions")
  if uint64(transferWidth) * uint64(transferHeight) * 4'u64 !=
      uint64(imageByteCount):
    raise newException(ValueError, "Texture payload does not fill its transfer rectangle")
  if width > high(int) div height:
    raise newException(ValueError, "Texture pixel count overflows host limits")

  var gsMemory = newSeq[uint8](gsMemoryBytes)
  let imageOffset = 228
  for y in 0 ..< transferHeight:
    for x in 0 ..< transferWidth:
      let sourceOffset = imageOffset + (y * transferWidth + x) * 4
      let destinationOffset = psmct32Address(x, y, 1)
      if destinationOffset < 0 or destinationOffset > gsMemory.len - 4:
        raise newException(ValueError, "Texture transfer exceeds GS memory")
      for channel in 0 ..< 4:
        gsMemory[destinationOffset + channel] = item[sourceOffset + channel]

  let clutOffset = clutBasePointer * 256
  var palette = newSeq[array[4, uint8]](256)
  for y in 0 ..< 16:
    for x in 0 ..< 16:
      let sourceOffset = clutOffset + psmct32Address(x, y, 1)
      if sourceOffset < 0 or sourceOffset > gsMemory.len - 4:
        raise newException(ValueError, "Texture CLUT exceeds GS memory")
      let colorIndex = y * 16 + x
      for channel in 0 ..< 4:
        palette[colorIndex][channel] = gsMemory[sourceOffset + channel]

  for group in 0 ..< 8:
    for index in 8 + group * 32 ..< 16 + group * 32:
      swap(palette[index], palette[index + 8])

  result.width = width
  result.height = height
  result.rgba = newSeq[uint8](width * height * 4)
  let textureBufferPages = textureBufferWidth div 2
  for y in 0 ..< height:
    for x in 0 ..< width:
      let sourceOffset = psmT8Address(x, y, textureBufferPages)
      if sourceOffset < 0 or sourceOffset >= gsMemory.len:
        raise newException(ValueError, "Texture texel exceeds GS memory")
      let color = palette[int(gsMemory[sourceOffset])]
      let destinationPixel = (height - y - 1) * width + x
      let destinationOffset = destinationPixel * 4
      for channel in 0 ..< 3:
        result.rgba[destinationOffset + channel] = color[channel]
      result.rgba[destinationOffset + 3] = uint8((int(color[3]) shl 1) and 0xFF)
