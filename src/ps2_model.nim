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
# The VIF attribute and strip interpretation follows Twinsanity Editor's MIT-licensed
# VIFInterpreter.cs and Model.cs; notices are in docs/THIRD_PARTY_LICENSES.md.
type
  ModelVertex* = object
    position*: array[3, float32]
    uv*: array[2, float32]
    color*: array[4, uint8]
    connected*: bool

  DecodedModel* = object
    vertices*: seq[ModelVertex]
    submodelCount*: int
    triangleCount*: int
    submodelVertexCounts*: seq[int]
    submodelTriangleCounts*: seq[int]

proc readU16LE(data: openArray[uint8], offset: int): uint16 =
  if offset < 0 or offset > data.len - 2:
    raise newException(ValueError, "Model VIF halfword extends beyond its range")
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(ValueError, "Model VIF word extends beyond its range")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc unpackVectorCount(amount, cycleLength, writeLength: int): int =
  if writeLength > cycleLength and writeLength > 0:
    cycleLength * (amount div writeLength) +
      min(amount mod writeLength, cycleLength)
  else:
    amount

proc finite(value: float32): bool =
  value == value and abs(value) < 1.0e20'f32

proc decodeSubmodel(data: openArray[uint8], vifStart, vifLength: int,
    vertexCount: int): seq[ModelVertex] =
  if vifLength < 16 or vifStart < 0 or vifStart > data.len - vifLength:
    raise newException(ValueError, "Model VIF range is too short or out of bounds")

  let qwc = int(readU16LE(data, vifStart))
  let transferLength = 16 + qwc * 16
  if transferLength > vifLength:
    raise newException(ValueError, "Model VIF QWC exceeds its bounded range")

  var positions: seq[array[3, float32]]
  var attributes: seq[array[4, uint32]]
  var cursor = vifStart + 8
  let limit = vifStart + transferLength
  var cycleLength = 0
  var writeLength = 0
  var mode = 0
  var maskApplied = false

  while cursor < limit:
    if limit - cursor < 4:
      raise newException(ValueError, "Model VIF ends between command words")
    let command = readU32LE(data, cursor)
    cursor += 4
    let opcode = int((command shr 24) and 0x7F)
    let amountField = int((command shr 16) and 0xFF)
    let amount = if amountField == 0: 256 else: amountField
    let immediate = int(command and 0xFFFF)
    var payloadBytes = 0

    if (opcode and 0x60) == 0x60:
      let components = ((opcode shr 2) and 3) + 1
      let componentBits = 32 shr (opcode and 3)
      let outputCount = unpackVectorCount(amount, cycleLength, writeLength)
      let packedBits = if components == 4 and componentBits == 4:
        outputCount * 16
      else:
        outputCount * components * componentBits
      payloadBytes = ((packedBits + 31) div 32) * 4

      let address = immediate and 0x3FF
      let format = opcode and 0x1F
      # The reference reader groups attributes by the low address bits and does
      # not apply TOPS relocation; this parser follows that observed grouping.
      if address in [3, 4] and (mode != 0 or maskApplied):
        raise newException(ValueError,
          "Masked or offset-mode VIF attributes are not supported")

      if address == 3 and format == 0x08:
        if outputCount * 12 > payloadBytes:
          raise newException(ValueError, "Position UNPACK payload is truncated")
        for index in 0 ..< outputCount:
          var position: array[3, float32]
          for component in 0 .. 2:
            position[component] = cast[float32](
              readU32LE(data, cursor + index * 12 + component * 4)
            )
            if not finite(position[component]):
              raise newException(ValueError, "Model contains a non-finite position")
          positions.add(position)
      elif address == 4 and format == 0x0C:
        if outputCount * 16 > payloadBytes:
          raise newException(ValueError, "UV UNPACK payload is truncated")
        for index in 0 ..< outputCount:
          var vector: array[4, uint32]
          for component in 0 .. 3:
            vector[component] = readU32LE(data,
              cursor + index * 16 + component * 4)
          attributes.add(vector)
    else:
      case opcode
      of 0x01:
        cycleLength = immediate and 0xFF
        writeLength = (immediate shr 8) and 0xFF
      of 0x05:
        mode = immediate and 3
      of 0x20:
        payloadBytes = 4
      of 0x30, 0x31:
        payloadBytes = 16
      of 0x4A:
        payloadBytes = amount * 8
      of 0x50, 0x51:
        payloadBytes = (if immediate == 0: 65536 else: immediate) * 16
      of 0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x10, 0x11, 0x13, 0x14, 0x15, 0x17:
        discard
      else:
        raise newException(ValueError, "Unsupported VIF command in model stream")

    if payloadBytes < 0 or payloadBytes > limit - cursor:
      raise newException(ValueError, "VIF command payload exceeds its QWC range")
    if opcode == 0x20:
      maskApplied = readU32LE(data, cursor) != 0
    cursor += payloadBytes

  if positions.len != vertexCount or attributes.len != vertexCount:
    raise newException(ValueError, "Model position/UV counts do not match vertices")

  for index in 0 ..< vertexCount:
    let packed = attributes[index]
    let u = cast[float32](packed[0] and 0xFFFFFF00'u32)
    let rawV = cast[float32](packed[1] and 0xFFFFFF00'u32)
    let v = 1.0'f32 - rawV
    if not finite(u) or not finite(v):
      raise newException(ValueError, "Model contains non-finite texture coordinates")
    result.add(ModelVertex(
      position: positions[index],
      uv: [u, v],
      color: [
        uint8(packed[0] and 0xFF),
        uint8(packed[1] and 0xFF),
        uint8(packed[2] and 0xFF),
        uint8((packed[3] shl 1) and 0xFF)
      ],
      connected: ((packed[3] shr 8) and 0xFF) != 128
    ))

proc decodeModelItem*(sectionData: openArray[uint8], itemOffset,
    itemLength: int): DecodedModel =
  if itemOffset < 0 or itemLength < 4 or itemOffset > sectionData.len - itemLength:
    raise newException(ValueError, "Model item range is out of bounds")
  let itemLimit = itemOffset + itemLength
  let submodelCount = int(readU32LE(sectionData, itemOffset))
  var cursor = itemOffset + 4
  if submodelCount > (itemLimit - cursor) div 12:
    raise newException(ValueError, "Submodel count exceeds model item bounds")

  for _ in 0 ..< submodelCount:
    let vertexCount = int(readU32LE(sectionData, cursor))
    let vifLength = int(readU32LE(sectionData, cursor + 4))
    cursor += 8
    if vifLength > itemLimit - cursor - 4:
      raise newException(ValueError, "VIF data exceeds model item bounds")
    let vertices = decodeSubmodel(sectionData, cursor, vifLength, vertexCount)
    let expandedVertexStart = result.vertices.len
    cursor += vifLength
    let blobLength = int(readU32LE(sectionData, cursor))
    cursor += 4
    if blobLength > itemLimit - cursor:
      raise newException(ValueError, "Model blob exceeds item bounds")
    cursor += blobLength

    for index in 2 ..< vertices.len:
      if vertices[index].connected:
        if (index and 1) == 0:
          result.vertices.add(vertices[index - 2])
          result.vertices.add(vertices[index - 1])
        else:
          result.vertices.add(vertices[index - 1])
          result.vertices.add(vertices[index - 2])
        result.vertices.add(vertices[index])
        inc result.triangleCount

    inc result.submodelCount
    result.submodelVertexCounts.add(vertices.len)
    result.submodelTriangleCounts.add(
      (result.vertices.len - expandedVertexStart) div 3
    )

  if cursor != itemLimit:
    raise newException(ValueError, "Model item contains unparsed trailing bytes")
