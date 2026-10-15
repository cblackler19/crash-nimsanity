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
import std/[math, os, sets, strutils, tables]

import iso9660
import ps2_model
import ps2_texture

type
  ArchiveEntry = object
    path: string
    dataOffset: uint32
    dataLength: uint32

  SectionEntry = object
    offset: uint32
    byteLength: uint32
    id: uint32

  ModelLocation = object
    resourcePath: string
    modelId: uint32

  ArchiveModelIndex = object
    modelIds: Table[uint32, string]
    rigidModels: Table[uint32, ModelLocation]

  UvSample = object
    u, v: float32
    color: array[4, uint8]
    connected: bool

  VifScanSummary = object
    commands: int
    unpacks: int
    unsupported: bool
    malformed: bool
    vectorsByAddress: array[1024, uint64]
    attributeFormats: array[4, array[32, uint64]]
    positionVectorCount: uint64
    invalidPositionVectors: uint64
    positionMin: array[3, float32]
    positionMax: array[3, float32]
    positionSamples: seq[array[3, float32]]
    positionVectors: seq[array[3, float32]]
    uvCount: uint64
    invalidUvCount: uint64
    uvMin: array[2, float32]
    uvMax: array[2, float32]
    connectedVertices: uint64
    disconnectedVertices: uint64
    uvSamples: seq[UvSample]
    connectionFlags: seq[bool]
    normalCount: uint64
    invalidNormalCount: uint64
    normalMin: array[3, float32]
    normalMax: array[3, float32]
    minNormalLength: float32
    maxNormalLength: float32
    emissiveColorCount: uint64
    emissiveColorMin: array[4, uint8]
    emissiveColorMax: array[4, uint8]

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "Unexpected end of file while reading a word")

  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc readU16LE(data: openArray[uint8], offset: int): uint16 =
  if offset < 0 or offset > data.len - 2:
    raise newException(IOError, "Unexpected end of file while reading a halfword")

  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc dumpHexRange(data: openArray[uint8], offset, byteCount: int) =
  if offset < 0 or byteCount < 0 or offset > data.len - byteCount:
    raise newException(IOError, "Hex range extends beyond the selected section")
  let limit = offset + byteCount
  var cursor = offset
  while cursor < limit:
    stdout.write(toHex(cursor, 8), "  ")
    let rowEnd = min(cursor + 16, limit)
    for index in cursor ..< rowEnd:
      stdout.write(toHex(int(data[index]), 2), " ")
    stdout.writeLine("")
    cursor = rowEnd

proc alignUp(value, alignment: int): int =
  ((value + alignment - 1) div alignment) * alignment

proc scanVifCommands(data: openArray[uint8], start,
    length: int): VifScanSummary =
  var cursor = start
  let limit = start + length
  var cycleLength = 0
  var writeLength = 0

  while cursor < limit:
    if limit - cursor < 4:
      result.malformed = true
      break

    let command = readU32LE(data, cursor)
    let opcode = int((command shr 24) and 0x7F)
    let amountField = int((command shr 16) and 0xFF)
    let amount = if amountField == 0: 256 else: amountField
    let immediate = int(command and 0xFFFF)
    var payloadBytes = 0
    inc result.commands

    if (opcode and 0x60) == 0x60:
      let vectorComponents = ((opcode shr 2) and 3) + 1
      let componentBits = 32 shr (opcode and 3)
      var suppliedVectors = amount
      if writeLength > cycleLength and writeLength > 0:
        suppliedVectors = cycleLength * (amount div writeLength) +
          min(amount mod writeLength, cycleLength)

      # V4-5 has a packed 16-bit representation rather than 4-bit components.
      let dataBits = if vectorComponents == 4 and componentBits == 4:
        suppliedVectors * 16
      else:
        suppliedVectors * vectorComponents * componentBits
      payloadBytes = alignUp((dataBits + 7) div 8, 4)
      inc result.unpacks
      let address = immediate and 0x3FF
      result.vectorsByAddress[address] += uint64(amount)
      if address in 3 .. 6:
        result.attributeFormats[address - 3][opcode and 0x1F] += 1
      if address == 3 and (opcode and 0x1F) == 0x08:
        let payloadStart = cursor + 4
        for vectorIndex in 0 ..< suppliedVectors:
          var position: array[3, float32]
          var positionIsFinite = true
          for component in 0 .. 2:
            let bits = readU32LE(data,
              payloadStart + vectorIndex * 12 + component * 4)
            position[component] = cast[float32](bits)
            if position[component] != position[component] or
                abs(position[component]) >= 1.0e20'f32:
              positionIsFinite = false

          if positionIsFinite:
            if result.positionVectorCount == 0:
              result.positionMin = position
              result.positionMax = position
            else:
              for component in 0 .. 2:
                result.positionMin[component] = min(
                  result.positionMin[component], position[component]
                )
                result.positionMax[component] = max(
                  result.positionMax[component], position[component]
                )
            inc result.positionVectorCount
            result.positionVectors.add(position)
            if result.positionSamples.len < 3:
              result.positionSamples.add(position)
          else:
            inc result.invalidPositionVectors
      elif address == 4 and (opcode and 0x1F) == 0x0C:
        let payloadStart = cursor + 4
        for vectorIndex in 0 ..< suppliedVectors:
          let vectorStart = payloadStart + vectorIndex * 16
          let xWord = readU32LE(data, vectorStart)
          let yWord = readU32LE(data, vectorStart + 4)
          let zWord = readU32LE(data, vectorStart + 8)
          let wWord = readU32LE(data, vectorStart + 12)
          let rawU = cast[float32](xWord and 0xFFFFFF00'u32)
          let rawV = cast[float32](yWord and 0xFFFFFF00'u32)
          let u = rawU
          let v = 1.0'f32 - rawV

          if u == u and v == v and abs(u) < 1.0e20'f32 and
              abs(v) < 1.0e20'f32:
            if result.uvCount == 0:
              result.uvMin = [u, v]
              result.uvMax = [u, v]
            else:
              result.uvMin[0] = min(result.uvMin[0], u)
              result.uvMin[1] = min(result.uvMin[1], v)
              result.uvMax[0] = max(result.uvMax[0], u)
              result.uvMax[1] = max(result.uvMax[1], v)
            inc result.uvCount
          else:
            inc result.invalidUvCount

          let connected = ((wWord shr 8) and 0xFF) != 128
          if connected:
            inc result.connectedVertices
          else:
            inc result.disconnectedVertices
          result.connectionFlags.add(connected)

          if result.uvSamples.len < 3:
            result.uvSamples.add(UvSample(
              u: u,
              v: v,
              color: [uint8(xWord and 0xFF), uint8(yWord and 0xFF),
                uint8(zWord and 0xFF), uint8((wWord shl 1) and 0xFF)],
              connected: connected
            ))
      elif address == 5 and (opcode and 0x1F) == 0x08:
        let payloadStart = cursor + 4
        for vectorIndex in 0 ..< suppliedVectors:
          var normal: array[3, float32]
          var normalIsFinite = true
          for component in 0 .. 2:
            let bits = readU32LE(data,
              payloadStart + vectorIndex * 12 + component * 4)
            normal[component] = cast[float32](bits)
            if normal[component] != normal[component] or
                abs(normal[component]) >= 1.0e20'f32:
              normalIsFinite = false

          if normalIsFinite:
            let normalLength = float32(sqrt(
              float64(normal[0]) * float64(normal[0]) +
                float64(normal[1]) * float64(normal[1]) +
                float64(normal[2]) * float64(normal[2])
            ))
            if result.normalCount == 0:
              result.normalMin = normal
              result.normalMax = normal
              result.minNormalLength = normalLength
              result.maxNormalLength = normalLength
            else:
              for component in 0 .. 2:
                result.normalMin[component] = min(
                  result.normalMin[component], normal[component]
                )
                result.normalMax[component] = max(
                  result.normalMax[component], normal[component]
                )
              result.minNormalLength = min(result.minNormalLength, normalLength)
              result.maxNormalLength = max(result.maxNormalLength, normalLength)
            inc result.normalCount
          else:
            inc result.invalidNormalCount
      elif address == 6 and (opcode and 0x1F) == 0x0E:
        let payloadStart = cursor + 4
        for vectorIndex in 0 ..< suppliedVectors:
          if result.emissiveColorCount == 0:
            for channel in 0 .. 3:
              let value = data[payloadStart + vectorIndex * 4 + channel]
              result.emissiveColorMin[channel] = value
              result.emissiveColorMax[channel] = value
          else:
            for channel in 0 .. 3:
              let value = data[payloadStart + vectorIndex * 4 + channel]
              result.emissiveColorMin[channel] = min(
                result.emissiveColorMin[channel], value
              )
              result.emissiveColorMax[channel] = max(
                result.emissiveColorMax[channel], value
              )
          inc result.emissiveColorCount
    else:
      case opcode
      of 0x01: # STCYCL
        cycleLength = immediate and 0xFF
        writeLength = (immediate shr 8) and 0xFF
      of 0x20: # STMASK
        payloadBytes = 4
      of 0x30, 0x31: # STROW / STCOL
        payloadBytes = 16
      of 0x4A: # MPG loads 64-bit micro-instructions
        payloadBytes = amount * 8
      of 0x50, 0x51: # DIRECT / DIRECTHL transfer qwords to GIF
        payloadBytes = (if immediate == 0: 65536 else: immediate) * 16
      of 0x00, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
          0x10, 0x11, 0x13, 0x14, 0x15, 0x17:
        discard
      else:
        result.unsupported = true
        break

    cursor += 4
    if payloadBytes > limit - cursor:
      result.malformed = true
      break
    cursor += payloadBytes

  if cursor != limit and not result.unsupported:
    result.malformed = true

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

proc inspectResource(resourceData: openArray[uint8], resourceLength: uint32): seq[SectionEntry] =
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

  for index in 0 ..< int(sectionCount):
    let offset = 12 + index * 12
    result.add(SectionEntry(
      offset: readU32LE(resourceData, offset),
      byteLength: readU32LE(resourceData, offset + 4),
      id: readU32LE(resourceData, offset + 8)
    ))

  var rangesAreContiguous = true
  var expectedOffset = headerLength
  for index, section in result:
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

proc inspectModelItems(sectionData: openArray[uint8], sectionLength: uint32,
    rigidMaterialCounts: Table[uint32, uint32]) =
  if sectionData.len < 12:
    raise newException(IOError, "Model section is shorter than its header")

  let sectionCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(sectionCount) * 12'u64
  if tableLength > uint64(sectionData.len) or tableLength > uint64(sectionLength):
    raise newException(IOError, "Model item table extends beyond its section")

  var totalSubmodels = 0'u64
  var totalVertices = 0'u64
  var totalVifBytes = 0'u64
  var totalBlobBytes = 0'u64
  var recordsWithTrailingBytes = 0'u64
  var sampledVif = false
  var vifStreamsWithQwc = 0'u64
  var vifStreamsMatchingQwcLength = 0'u64
  var vifStreamsWithZeroQwcTail = 0'u64
  var vifStreamsWithNonzeroQwcTail = 0'u64
  var minQwcLengthDifference = high(int64)
  var maxQwcLengthDifference = low(int64)
  var minPositiveQwcLengthDifference = high(int64)
  var vifCommandCount = 0'u64
  var vifUnpackCount = 0'u64
  var vifScanned = 0'u64
  var vifUnsupported = 0'u64
  var vifMalformed = 0'u64
  var vifStreamsWithAddress = newSeq[uint64](1024)
  var vifStreamsMatchingVertexCount = newSeq[uint64](1024)
  var vifAttributeFormats: array[4, array[32, uint64]]
  var positionVectorCount = 0'u64
  var invalidPositionVectors = 0'u64
  var positionMin: array[3, float32]
  var positionMax: array[3, float32]
  var positionSamples: seq[array[3, float32]]
  var uvCount = 0'u64
  var invalidUvCount = 0'u64
  var uvMin: array[2, float32]
  var uvMax: array[2, float32]
  var connectedVertices = 0'u64
  var disconnectedVertices = 0'u64
  var uvSamples: seq[UvSample]
  var streamsWithUv = 0'u64
  var streamsWithTrianglePrefix = 0'u64
  var candidateTriangleMarkers = 0'u64
  var topologyStreamsWithAlignedVertices = 0'u64
  var candidateTrianglesWithArea = 0'u64
  var nearDegenerateCandidateTriangles = 0'u64
  var firstConnectionFlags: seq[bool]
  var normalCount = 0'u64
  var invalidNormalCount = 0'u64
  var normalMin, normalMax: array[3, float32]
  var minNormalLength, maxNormalLength: float32
  var emissiveColorCount = 0'u64
  var emissiveColorMin, emissiveColorMax: array[4, uint8]
  var reconstructedModelCount = 0'u64
  var reconstructedSubmodelCount = 0'u64
  var reconstructedTriangleCount = 0'u64
  var modelDecodeFailures = 0'u64
  var modelsWithRigidLinks = 0'u64
  var modelsMatchingMaterialCount = 0'u64

  for itemIndex in 0 ..< int(sectionCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Model item range extends beyond its section")
    if itemLength < 4:
      raise newException(IOError, "Model item is shorter than its count field")

    let itemStart = int(itemOffset)
    let itemLimit = itemStart + int(itemLength)
    let submodelCount = readU32LE(sectionData, itemStart)
    if itemId in rigidMaterialCounts:
      inc modelsWithRigidLinks
      if rigidMaterialCounts[itemId] == submodelCount:
        inc modelsMatchingMaterialCount
    try:
      let decoded = decodeModelItem(sectionData, itemStart, int(itemLength))
      inc reconstructedModelCount
      reconstructedSubmodelCount += uint64(decoded.submodelCount)
      reconstructedTriangleCount += uint64(decoded.triangleCount)
    except ValueError as error:
      inc modelDecodeFailures
      if modelDecodeFailures <= 3:
        echo "Model decoder rejected item ", itemId, ": ", error.msg
    var cursor = itemStart + 4
    var itemVertices = 0'u64
    var itemVifBytes = 0'u64
    var itemBlobBytes = 0'u64
    if uint64(submodelCount) > uint64((itemLimit - cursor) div 12):
      raise newException(IOError, "Model submodel count exceeds item bounds")

    for _ in 0 ..< int(submodelCount):
      let vertexCount = readU32LE(sectionData, cursor)
      let vifLength = readU32LE(sectionData, cursor + 4)
      cursor += 8
      if uint64(vifLength) > uint64(itemLimit - cursor - 4):
        raise newException(IOError, "VIF payload extends beyond model item")
      # Compare the DMA tag's QWC span with the bounded VIF field and inspect any tail.
      if vifLength >= 16:
        let qwc = readU16LE(sectionData, cursor)
        let tagAndPayloadBytes = 16'u64 + uint64(qwc) * 16'u64
        let difference = int64(vifLength) - int64(tagAndPayloadBytes)
        inc vifStreamsWithQwc
        if difference == 0:
          inc vifStreamsMatchingQwcLength
        elif difference > 0:
          minPositiveQwcLengthDifference = min(
            minPositiveQwcLengthDifference, difference
          )
          let tailStart = cursor + int(tagAndPayloadBytes)
          var tailIsZero = true
          for tailIndex in tailStart ..< tailStart + int(difference):
            if sectionData[tailIndex] != 0:
              tailIsZero = false
              break
          if tailIsZero:
            inc vifStreamsWithZeroQwcTail
          else:
            inc vifStreamsWithNonzeroQwcTail
        minQwcLengthDifference = min(minQwcLengthDifference, difference)
        maxQwcLengthDifference = max(maxQwcLengthDifference, difference)
        if tagAndPayloadBytes <= uint64(vifLength):
          let scan = scanVifCommands(sectionData, cursor + 8,
            int(tagAndPayloadBytes) - 8)
          inc vifScanned
          vifCommandCount += uint64(scan.commands)
          vifUnpackCount += uint64(scan.unpacks)
          for address, vectorCount in scan.vectorsByAddress:
            if vectorCount > 0:
              inc vifStreamsWithAddress[address]
              if vectorCount == uint64(vertexCount):
                inc vifStreamsMatchingVertexCount[address]
          for address in 0 ..< vifAttributeFormats.len:
            for format in 0 ..< vifAttributeFormats[address].len:
              vifAttributeFormats[address][format] +=
                scan.attributeFormats[address][format]
          if scan.positionVectorCount > 0:
            if positionVectorCount == 0:
              positionMin = scan.positionMin
              positionMax = scan.positionMax
            else:
              for component in 0 .. 2:
                positionMin[component] = min(positionMin[component],
                  scan.positionMin[component])
                positionMax[component] = max(positionMax[component],
                  scan.positionMax[component])
            positionVectorCount += scan.positionVectorCount
            for sample in scan.positionSamples:
              if positionSamples.len < 3:
                positionSamples.add(sample)
          invalidPositionVectors += scan.invalidPositionVectors
          if scan.uvCount > 0:
            if uvCount == 0:
              uvMin = scan.uvMin
              uvMax = scan.uvMax
            else:
              uvMin[0] = min(uvMin[0], scan.uvMin[0])
              uvMin[1] = min(uvMin[1], scan.uvMin[1])
              uvMax[0] = max(uvMax[0], scan.uvMax[0])
              uvMax[1] = max(uvMax[1], scan.uvMax[1])
            uvCount += scan.uvCount
            connectedVertices += scan.connectedVertices
            disconnectedVertices += scan.disconnectedVertices
            for sample in scan.uvSamples:
              if uvSamples.len < 3:
                uvSamples.add(sample)
          if scan.connectionFlags.len > 0:
            inc streamsWithUv
            if firstConnectionFlags.len == 0:
              for flagIndex in 0 ..< min(6, scan.connectionFlags.len):
                firstConnectionFlags.add(scan.connectionFlags[flagIndex])
            if scan.connectionFlags.len >= 3:
              if not scan.connectionFlags[0] and
                  not scan.connectionFlags[1] and scan.connectionFlags[2]:
                inc streamsWithTrianglePrefix
              if scan.connectionFlags.len == scan.positionVectors.len:
                inc topologyStreamsWithAlignedVertices
              let vertexCount = min(scan.connectionFlags.len,
                scan.positionVectors.len)
              for endIndex in 2 ..< vertexCount:
                if scan.connectionFlags[endIndex]:
                  inc candidateTriangleMarkers
                  let a = scan.positionVectors[endIndex - 2]
                  let b = scan.positionVectors[endIndex - 1]
                  let c = scan.positionVectors[endIndex]
                  let abx = float64(b[0]) - float64(a[0])
                  let aby = float64(b[1]) - float64(a[1])
                  let abz = float64(b[2]) - float64(a[2])
                  let acx = float64(c[0]) - float64(a[0])
                  let acy = float64(c[1]) - float64(a[1])
                  let acz = float64(c[2]) - float64(a[2])
                  let crossX = aby * acz - abz * acy
                  let crossY = abz * acx - abx * acz
                  let crossZ = abx * acy - aby * acx
                  let doubledAreaSquared = crossX * crossX +
                    crossY * crossY + crossZ * crossZ
                  if doubledAreaSquared <= 1.0e-12:
                    inc nearDegenerateCandidateTriangles
                  else:
                    inc candidateTrianglesWithArea
          invalidUvCount += scan.invalidUvCount
          if scan.normalCount > 0:
            if normalCount == 0:
              normalMin = scan.normalMin
              normalMax = scan.normalMax
              minNormalLength = scan.minNormalLength
              maxNormalLength = scan.maxNormalLength
            else:
              for component in 0 .. 2:
                normalMin[component] = min(normalMin[component],
                  scan.normalMin[component])
                normalMax[component] = max(normalMax[component],
                  scan.normalMax[component])
              minNormalLength = min(minNormalLength, scan.minNormalLength)
              maxNormalLength = max(maxNormalLength, scan.maxNormalLength)
            normalCount += scan.normalCount
          invalidNormalCount += scan.invalidNormalCount
          if scan.emissiveColorCount > 0:
            if emissiveColorCount == 0:
              emissiveColorMin = scan.emissiveColorMin
              emissiveColorMax = scan.emissiveColorMax
            else:
              for channel in 0 .. 3:
                emissiveColorMin[channel] = min(emissiveColorMin[channel],
                  scan.emissiveColorMin[channel])
                emissiveColorMax[channel] = max(emissiveColorMax[channel],
                  scan.emissiveColorMax[channel])
            emissiveColorCount += scan.emissiveColorCount
          if scan.unsupported:
            inc vifUnsupported
          if scan.malformed:
            inc vifMalformed
      if not sampledVif:
        let sampleLength = min(32, int(vifLength))
        var sample = ""
        for byteIndex in 0 ..< sampleLength:
          if byteIndex > 0:
            sample.add(' ')
          sample.add(toHex(int(sectionData[cursor + byteIndex]), 2))
        echo "First VIF stream prefix: ", sample
        if vifLength >= 16:
          let qwc = readU16LE(sectionData, cursor)
          let qwcPayloadBytes = uint64(qwc) * 16'u64
          let dmaTagAndPayloadBytes = 16'u64 + qwcPayloadBytes
          echo "Low-word QWC candidate: ", qwc,
            " (payload bytes=", qwcPayloadBytes,
            ", tag+payload bytes=", dmaTagAndPayloadBytes,
            ", declared VIF bytes=", vifLength,
            ", difference=", int64(vifLength) - int64(dmaTagAndPayloadBytes), ")"
          if uint64(vifLength) > dmaTagAndPayloadBytes:
            let extraStart = cursor + int(dmaTagAndPayloadBytes)
            let extraLength = int(uint64(vifLength) - dmaTagAndPayloadBytes)
            var extra = ""
            for byteIndex in 0 ..< extraLength:
              if byteIndex > 0:
                extra.add(' ')
              extra.add(toHex(int(sectionData[extraStart + byteIndex]), 2))
            echo "Bytes after tag+QWC range: ", extra
        sampledVif = true
      cursor += int(vifLength)
      let blobLength = readU32LE(sectionData, cursor)
      cursor += 4
      if uint64(blobLength) > uint64(itemLimit - cursor):
        raise newException(IOError, "Model blob extends beyond model item")
      cursor += int(blobLength)

      itemVertices += uint64(vertexCount)
      itemVifBytes += uint64(vifLength)
      itemBlobBytes += uint64(blobLength)

    if cursor != itemLimit:
      inc recordsWithTrailingBytes
    totalSubmodels += uint64(submodelCount)
    totalVertices += itemVertices
    totalVifBytes += itemVifBytes
    totalBlobBytes += itemBlobBytes

    if itemIndex < 8:
      echo "Model item id=", itemId, " bytes=", itemLength,
        " submodels=", submodelCount, " vertices=", itemVertices,
        " VIF bytes=", itemVifBytes, " blob bytes=", itemBlobBytes,
        " trailing bytes=", itemLimit - cursor

  echo "Model items: ", sectionCount
  echo "Total submodels: ", totalSubmodels
  echo "Declared vertices: ", totalVertices
  echo "VIF bytes: ", totalVifBytes
  echo "Blob bytes: ", totalBlobBytes
  echo "Records with trailing bytes: ", recordsWithTrailingBytes
  echo "Models decoded to triangle vertices: ", reconstructedModelCount,
    " / ", sectionCount
  echo "Decoded submodels and triangle count: ", reconstructedSubmodelCount,
    " / ", reconstructedTriangleCount
  echo "Model decode failures: ", modelDecodeFailures
  echo "Models linked by rigid-model records: ", modelsWithRigidLinks
  echo "Linked model submodel counts matching material counts: ",
    modelsMatchingMaterialCount, " / ", modelsWithRigidLinks
  echo "VIF streams where tag+QWC matches declared length: ",
    vifStreamsMatchingQwcLength, " / ", vifStreamsWithQwc
  echo "Streams with zero bytes after tag+QWC: ", vifStreamsWithZeroQwcTail
  echo "Streams with nonzero bytes after tag+QWC: ",
    vifStreamsWithNonzeroQwcTail
  if vifStreamsWithQwc > 0:
    echo "VIF declared-length minus tag+QWC range: ",
      minQwcLengthDifference, " to ", maxQwcLengthDifference, " bytes"
  if minPositiveQwcLengthDifference != high(int64):
    echo "Smallest positive VIF tail: ", minPositiveQwcLengthDifference, " bytes"
  echo "VIF command walk: ", vifScanned, " streams, ", vifCommandCount,
    " commands, ", vifUnpackCount, " UNPACK commands"
  echo "VIF streams with unsupported commands: ", vifUnsupported
  echo "VIF streams with truncated or misaligned command data: ", vifMalformed
  echo "UNPACK immediate addresses matching each stream's declared vertices:"
  for address in 0 ..< vifStreamsWithAddress.len:
    if vifStreamsWithAddress[address] > 0:
      echo "  address ", address, ": ", vifStreamsMatchingVertexCount[address],
        " / ", vifStreamsWithAddress[address], " streams"
  echo "UNPACK formats at attribute addresses:"
  for address in 0 ..< vifAttributeFormats.len:
    var formatSummary = ""
    for format in 0 ..< vifAttributeFormats[address].len:
      let count = vifAttributeFormats[address][format]
      if count > 0:
        if formatSummary.len > 0:
          formatSummary.add(", ")
        formatSummary.add("0x")
        formatSummary.add(toHex(0x60 or format, 2))
        formatSummary.add("=")
        formatSummary.add($count)
    if formatSummary.len > 0:
      echo "  address ", address + 3, ": ", formatSummary
  echo "Address 3 V3_32 values viewed as binary32: ", positionVectorCount,
    " finite vectors, ", invalidPositionVectors, " non-finite vectors"
  if positionVectorCount > 0:
    echo "  bounds: x=", positionMin[0], "..", positionMax[0],
      " y=", positionMin[1], "..", positionMax[1],
      " z=", positionMin[2], "..", positionMax[2]
    echo "  first vectors: ", positionSamples
  echo "Address 4 V4_32 UV candidates: ", uvCount, " finite, ",
    invalidUvCount, " non-finite"
  if uvCount > 0:
    echo "  bounds: U=", uvMin[0], "..", uvMax[0],
      " V=", uvMin[1], "..", uvMax[1]
    echo "  editor connectivity flag: ", connectedVertices,
      " connected, ", disconnectedVertices, " disconnected"
    echo "  candidate triangle markers after the first two vertices: ",
      candidateTriangleMarkers
    echo "  streams beginning false,false,true: ", streamsWithTrianglePrefix,
      " / ", streamsWithUv
    echo "  streams with aligned position/connectivity vectors: ",
      topologyStreamsWithAlignedVertices, " / ", streamsWithUv
    echo "  candidate triangles with nonzero area: ",
      candidateTrianglesWithArea, "; near-degenerate: ",
      nearDegenerateCandidateTriangles
    echo "  first connectivity flags: ", firstConnectionFlags
    for sample in uvSamples:
      echo "  sample: UV=", sample.u, ",", sample.v,
        " RGBA=", sample.color, " connected=", sample.connected
  echo "Address 5 V3_32 normals: ", normalCount, " finite, ",
    invalidNormalCount, " non-finite"
  if normalCount > 0:
    echo "  component bounds: x=", normalMin[0], "..", normalMax[0],
      " y=", normalMin[1], "..", normalMax[1],
      " z=", normalMin[2], "..", normalMax[2]
    echo "  vector length: ", minNormalLength, "..", maxNormalLength
  echo "Address 6 V4_8 emissive bytes: ", emissiveColorCount
  if emissiveColorCount > 0:
    echo "  RGBA channel bounds: ", emissiveColorMin, "..", emissiveColorMax

proc collectSectionItemIds(sectionData: openArray[uint8],
    sectionLength: uint32): HashSet[uint32] =
  if sectionData.len < 12:
    raise newException(IOError, "Model section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Model item table extends beyond its section")

  result = initHashSet[uint32]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Model item range extends beyond its section")
    result.incl(itemId)

proc collectSectionTableIds(sectionTable: openArray[uint8],
    sectionLength: uint32): HashSet[uint32] =
  if sectionTable.len < 12:
    raise newException(IOError, "Section table is shorter than its header")

  let itemCount = readU32LE(sectionTable, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionTable.len) or tableLength > uint64(sectionLength):
    raise newException(IOError, "Section item table extends beyond its section")

  result = initHashSet[uint32]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionTable, entryOffset)
    let itemLength = readU32LE(sectionTable, entryOffset + 4)
    let itemId = readU32LE(sectionTable, entryOffset + 8)
    if itemOffset < tableLength or
        uint64(itemOffset) + uint64(itemLength) > uint64(sectionLength):
      raise newException(IOError, "Section item range extends beyond its section")
    result.incl(itemId)

proc collectRigidModelLinks(sectionData: openArray[uint8],
    sectionLength: uint32): Table[uint32, uint32] =
  if sectionData.len < 12:
    raise newException(IOError, "Rigid-model section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Rigid-model table extends beyond its section")

  result = initTable[uint32, uint32]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len) or itemLength < 12:
      raise newException(IOError, "Rigid-model record range is malformed")

    let materialCount = readU32LE(sectionData, int(itemOffset) + 4)
    let meshOffset = uint64(itemOffset) + 8'u64 +
      uint64(materialCount) * 4'u64
    if meshOffset + 4'u64 > itemEnd:
      raise newException(IOError, "Rigid-model mesh reference exceeds its record")
    result[itemId] = readU32LE(sectionData, int(meshOffset))

proc collectGameObjectGraphicsInfoIds(sectionData: openArray[uint8],
    sectionLength: uint32): Table[uint32, seq[uint16]] =
  if sectionData.len < 12:
    raise newException(IOError, "Game-object section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Game-object table extends beyond its section")

  result = initTable[uint32, seq[uint16]]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len) or itemLength < 20:
      raise newException(IOError, "Game-object record range is malformed")

    let limit = int(itemEnd)
    var cursor = int(itemOffset) + 12
    if cursor > limit - 4:
      raise newException(IOError, "Game-object name length is truncated")
    let nameLength = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(nameLength) > uint64(limit - cursor):
      raise newException(IOError, "Game-object name exceeds its record")
    cursor += int(nameLength)

    if cursor > limit - 4:
      raise newException(IOError, "Game-object integer-list count is truncated")
    let scriptValueCount = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(scriptValueCount) > uint64((limit - cursor) div 4):
      raise newException(IOError, "Game-object integer list exceeds its record")
    cursor += int(scriptValueCount) * 4
    if cursor > limit - 4:
      raise newException(IOError, "Game-object graphics list is truncated")
    let graphicsInfoCount = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(graphicsInfoCount) > uint64((limit - cursor) div 2):
      raise newException(IOError, "Game-object graphics list exceeds its record")

    var graphicsInfoIds: seq[uint16]
    for linkIndex in 0 ..< int(graphicsInfoCount):
      graphicsInfoIds.add(readU16LE(sectionData, cursor + linkIndex * 2))
    result[itemId] = graphicsInfoIds

proc collectGraphicsInfoModelIds(sectionData: openArray[uint8],
    sectionLength: uint32): Table[uint32, seq[uint32]] =
  if sectionData.len < 12:
    raise newException(IOError, "Graphics-info section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Graphics-info table extends beyond its section")

  result = initTable[uint32, seq[uint32]]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len) or itemLength < 56:
      raise newException(IOError, "Graphics-info record range is malformed")

    let start = int(itemOffset)
    let limit = int(itemEnd)
    let jointCount = int(sectionData[start])
    let exitPointCount = int(sectionData[start + 1])
    let modelCount = int(sectionData[start + 5])
    var cursor = start + 48

    let jointBytes = uint64(jointCount) * 100'u64
    let exitPointBytes = uint64(exitPointCount) * 72'u64
    if jointBytes + exitPointBytes > uint64(limit - cursor):
      raise newException(IOError, "Graphics-info transforms exceed their record")
    cursor += int(jointBytes + exitPointBytes)

    if modelCount > limit - cursor:
      raise newException(IOError, "Graphics-info joint links exceed their record")
    cursor += modelCount
    if uint64(modelCount) * 4'u64 > uint64(limit - cursor):
      raise newException(IOError, "Graphics-info model links exceed their record")

    var modelIds: seq[uint32]
    for modelIndex in 0 ..< modelCount:
      modelIds.add(readU32LE(sectionData, cursor + modelIndex * 4))
    result[itemId] = modelIds

proc collectRigidMaterialCounts(sectionData: openArray[uint8],
    sectionLength: uint32): Table[uint32, uint32] =
  if sectionData.len < 12:
    raise newException(IOError, "Rigid-model section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Rigid-model item table extends beyond its section")

  result = initTable[uint32, uint32]()
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len) or itemLength < 12:
      raise newException(IOError, "Rigid-model item range is malformed")

    let itemStart = int(itemOffset)
    let materialCount = readU32LE(sectionData, itemStart + 4)
    let meshOffset = uint64(itemOffset) + 8'u64 + uint64(materialCount) * 4'u64
    if meshOffset + 4'u64 > itemEnd:
      raise newException(IOError, "Rigid-model material list exceeds its item")
    let modelId = readU32LE(sectionData, int(meshOffset))
    result[modelId] = materialCount

proc inspectRigidModels(sectionData: openArray[uint8], sectionLength: uint32,
    modelIds, materialIds: HashSet[uint32]) =
  if sectionData.len < 12:
    raise newException(IOError, "Rigid-model section is shorter than its header")

  let sectionCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(sectionCount) * 12'u64
  if tableLength > uint64(sectionData.len) or tableLength > uint64(sectionLength):
    raise newException(IOError, "Rigid-model item table extends beyond its section")

  var totalMaterialLinks = 0'u64
  var materialLinksMatchingIds = 0'u64
  var meshReferencesMatchingModels = 0'u64
  var uniqueMeshIds = initHashSet[uint32]()
  var recordsWithTrailingBytes = 0'u64
  var headerValues = initHashSet[uint32]()

  for itemIndex in 0 ..< int(sectionCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Rigid-model item range extends beyond its section")
    if itemLength < 12:
      raise newException(IOError, "Rigid-model item is shorter than its fixed fields")

    let itemStart = int(itemOffset)
    let itemLimit = itemStart + int(itemLength)
    let header = readU32LE(sectionData, itemStart)
    let materialCount = readU32LE(sectionData, itemStart + 4)
    let expectedLength = 12'u64 + uint64(materialCount) * 4'u64
    if expectedLength > uint64(itemLength):
      raise newException(IOError, "Rigid-model material list exceeds item bounds")

    var cursor = itemStart + 8
    var materials: seq[uint32]
    for _ in 0 ..< int(materialCount):
      let materialId = readU32LE(sectionData, cursor)
      materials.add(materialId)
      if materialIds.contains(materialId):
        inc materialLinksMatchingIds
      cursor += 4
    let meshId = readU32LE(sectionData, cursor)
    cursor += 4
    if modelIds.contains(meshId):
      inc meshReferencesMatchingModels

    totalMaterialLinks += uint64(materialCount)
    uniqueMeshIds.incl(meshId)
    headerValues.incl(header)
    if cursor != itemLimit:
      inc recordsWithTrailingBytes

    if itemIndex < 8:
      echo "Rigid-model item id=", itemId, " bytes=", itemLength,
        " header=0x", toHex(header, 8), " materials=", materials,
        " mesh id=", meshId, " trailing bytes=", itemLimit - cursor

  echo "Rigid-model items: ", sectionCount
  echo "Material links: ", totalMaterialLinks
  echo "Material links matching sibling material IDs: ",
    materialLinksMatchingIds, " / ", totalMaterialLinks
  echo "Distinct referenced mesh IDs: ", uniqueMeshIds.len
  echo "Mesh references matching sibling model IDs: ",
    meshReferencesMatchingModels, " / ", sectionCount
  echo "Header values: ", headerValues
  echo "Records with trailing bytes: ", recordsWithTrailingBytes

proc inspectTextureItems(sectionData: openArray[uint8], sectionLength: uint32) =
  if sectionData.len < 12:
    raise newException(IOError, "Texture section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Texture item table extends beyond its section")

  var formatCounts: array[64, uint64]
  var sizeMatches = 0'u64
  var validDimensions = 0'u64
  var pixelPayloadMatches = 0'u64
  var transferPayloadMatches = 0'u64
  var decodedTextureCount = 0'u64
  var decodedPixelCount = 0'u64
  var decodedMipCount = 0'u64
  var decodedMipPixelCount = 0'u64
  var decodedColors = initHashSet[uint32]()
  var totalImageBytes = 0'u64
  var dimensionSamples: seq[string]

  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Texture item range extends beyond its section")
    if itemLength < 224:
      raise newException(IOError, "Texture item is shorter than its fixed header")

    let itemStart = int(itemOffset)
    let textureSize = readU32LE(sectionData, itemStart)
    if textureSize < 224:
      raise newException(IOError, "Texture payload size is shorter than its metadata")
    let widthExponent = int(int16(uint16(readU16LE(sectionData, itemStart + 8))))
    let heightExponent = int(int16(uint16(readU16LE(sectionData, itemStart + 10))))
    let mipCount = int(sectionData[itemStart + 12])
    let pixelFormat = int(sectionData[itemStart + 13])
    let destinationFormat = int(sectionData[itemStart + 14])
    let colorComponent = int(sectionData[itemStart + 15])
    let imageBytes = uint64(textureSize - 224'u32)
    # The image payload is staged through a 32-bit GS transfer rectangle.
    let transferWidth = readU32LE(sectionData, itemStart + 180)
    let transferHeight = readU32LE(sectionData, itemStart + 184)

    if uint64(textureSize) + 4'u64 == uint64(itemLength):
      inc sizeMatches
    if widthExponent in 0 .. 10 and heightExponent in 0 .. 10:
      inc validDimensions
      if dimensionSamples.len < 8:
        dimensionSamples.add($itemId & ":" &
          $(1 shl widthExponent) & "x" & $(1 shl heightExponent))
      if pixelFormat == 0 and imageBytes ==
          uint64(1 shl widthExponent) * uint64(1 shl heightExponent) * 4'u64:
        inc pixelPayloadMatches
      if pixelFormat in [0, 19] and imageBytes ==
          uint64(transferWidth) * uint64(transferHeight) * 4'u64:
        inc transferPayloadMatches
    if pixelFormat < formatCounts.len:
      inc formatCounts[pixelFormat]
    totalImageBytes += imageBytes
    if pixelFormat == 19:
      let decoded = decodePsmT8(sectionData[itemStart ..< int(itemEnd)])
      inc decodedTextureCount
      decodedPixelCount += uint64(decoded.width) * uint64(decoded.height)
      decodedMipCount += uint64(decoded.mipLevels.len)
      for mip in decoded.mipLevels:
        decodedMipPixelCount += uint64(mip.width) * uint64(mip.height)
      for pixel in 0 ..< decoded.width * decoded.height:
        let colorOffset = pixel * 4
        let packedColor = uint32(decoded.rgba[colorOffset]) or
          (uint32(decoded.rgba[colorOffset + 1]) shl 8) or
          (uint32(decoded.rgba[colorOffset + 2]) shl 16) or
          (uint32(decoded.rgba[colorOffset + 3]) shl 24)
        decodedColors.incl(packedColor)
    if itemIndex < 8:
      echo "Texture item id=", itemId, " bytes=", itemLength,
        " size=", textureSize, " dimensions=2^", widthExponent, "x2^",
        heightExponent, " format=0x", toHex(pixelFormat, 2),
        " destination=0x", toHex(destinationFormat, 2),
        " components=", colorComponent, " mip-count=", mipCount,
        " transfer=", transferWidth, "x", transferHeight,
        " image-bytes=", imageBytes

  echo "Texture items: ", itemCount
  echo "Texture sizes matching item length (size + 4): ",
    sizeMatches, " / ", itemCount
  echo "Valid dimension exponents (0..10): ", validDimensions, " / ", itemCount
  echo "PSMCT32 payloads matching width * height * 4: ", pixelPayloadMatches
  echo "PSMCT32/PSMT8 payloads matching 32-bit transfer rectangle: ",
    transferPayloadMatches, " / ", itemCount
  echo "PSMT8 textures decoded in memory: ", decodedTextureCount
  echo "Decoded base-image pixels: ", decodedPixelCount
  echo "Decoded mip levels and pixels: ", decodedMipCount, " / ",
    decodedMipPixelCount
  echo "Distinct decoded RGBA colors across sample: ", decodedColors.len
  echo "Image payload bytes: ", totalImageBytes
  echo "Pixel format counts:"
  for format, count in formatCounts:
    if count > 0:
      echo "  0x", toHex(format, 2), ": ", count
  echo "Sample texture dimensions (itemId:width x height): ",
    dimensionSamples.join(", ")

proc inspectMaterialItems(sectionData: openArray[uint8], sectionLength: uint32,
    textureIds: HashSet[uint32]): HashSet[uint32] =
  if sectionData.len < 12:
    raise newException(IOError, "Material section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Material item table extends beyond its section")

  result = initHashSet[uint32]()
  var shaderTypeCounts: array[256, uint64]
  var shaderCountTotal = 0'u64
  var textureReferencesMatchingIds = 0'u64
  var materialsEndingAtBoundary = 0'u64

  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Material item range extends beyond its section")
    if itemLength < 20:
      raise newException(IOError, "Material item is shorter than its fixed fields")

    let itemStart = int(itemOffset)
    let nameLength = readU32LE(sectionData, itemStart + 12)
    let nameStart = itemStart + 16
    if uint64(nameLength) + 20'u64 > uint64(itemLength):
      raise newException(IOError, "Material name extends beyond its item")
    let shaderCountOffset = nameStart + int(nameLength)
    let shaderCount = readU32LE(sectionData, shaderCountOffset)
    var cursor = shaderCountOffset + 4
    let itemLimit = int(itemEnd)
    var name = newString(int(nameLength))
    for nameIndex in 0 ..< int(nameLength):
      name[nameIndex] = char(sectionData[nameStart + nameIndex])

    if uint64(shaderCount) > uint64((itemLimit - cursor) div 94):
      raise newException(IOError, "Material shader count exceeds item bounds")

    for _ in 0 ..< int(shaderCount):
      if cursor > itemLimit - 4:
        raise newException(IOError, "Material shader header extends beyond item")
      let shaderType = readU32LE(sectionData, cursor)
      # These parameter sizes follow the reference reader's type-specific fields.
      let parameterBytes = case shaderType
        of 23'u32: 12
        of 26'u32: 20
        of 16'u32, 17'u32: 4
        else: 0
      let shaderLength = 94 + parameterBytes
      if shaderLength > itemLimit - cursor:
        raise newException(IOError, "Material shader record extends beyond item")

      let textureId = readU32LE(sectionData, cursor + shaderLength - 8)
      shaderTypeCounts[int(shaderType and 0xFF)] += 1
      inc shaderCountTotal
      if textureIds.contains(textureId):
        inc textureReferencesMatchingIds
      cursor += shaderLength

    if cursor == itemLimit:
      inc materialsEndingAtBoundary
    result.incl(itemId)
    if itemIndex < 8:
      echo "Material item id=", itemId, " bytes=", itemLength,
        " header=0x", toHex(readU32LE(sectionData, itemStart + 4), 8),
        toHex(readU32LE(sectionData, itemStart), 8), " name=\"", name,
        "\" shaders=", shaderCount, " trailing bytes=", itemLimit - cursor

  echo "Material items: ", itemCount
  echo "Distinct material IDs: ", result.len
  echo "Shader records: ", shaderCountTotal
  echo "Shader texture references matching sibling texture IDs: ",
    textureReferencesMatchingIds, " / ", shaderCountTotal
  echo "Materials ending at declared item boundaries: ",
    materialsEndingAtBoundary, " / ", itemCount
  echo "Shader type counts by low byte:"
  for shaderType, count in shaderTypeCounts:
    if count > 0:
      echo "  ", shaderType, ": ", count

proc skipInstanceReferenceList(data: openArray[uint8], cursor: var int,
    limit: int): int =
  if cursor < 0 or cursor > limit - 12:
    raise newException(IOError, "Instance reference-list header is truncated")

  let declaredCount = readU32LE(data, cursor)
  let storedCount = readU32LE(data, cursor + 4)
  cursor += 12
  if declaredCount != storedCount:
    raise newException(IOError, "Instance reference-list counts disagree")
  if uint64(storedCount) > uint64((limit - cursor) div 2):
    raise newException(IOError, "Instance reference list exceeds its record")

  result = int(storedCount)
  cursor += result * 2

proc skipInstanceWordList(data: openArray[uint8], cursor: var int,
    limit: int): int =
  if cursor < 0 or cursor > limit - 4:
    raise newException(IOError, "Instance property-list header is truncated")
  let count = readU32LE(data, cursor)
  cursor += 4
  if uint64(count) > uint64((limit - cursor) div 4):
    raise newException(IOError, "Instance property list exceeds its record")
  result = int(count)
  cursor += result * 4

proc inspectObjectInstances(sectionData: openArray[uint8],
    sectionLength: uint32, objectDefinitionIds: HashSet[uint32],
    objectGraphicsInfoIds: Table[uint32, seq[uint16]],
    graphicsInfoIds: HashSet[uint32],
    graphicsInfoModelIds: Table[uint32, seq[uint32]],
    graphicsModelLocations: ArchiveModelIndex) =
  if sectionData.len < 12:
    raise newException(IOError, "Object-instance section is shorter than its header")

  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len) or
      tableLength > uint64(sectionLength):
    raise newException(IOError, "Object-instance table extends beyond its section")

  var totalReferences = 0'u64
  var recordsEndingAtBoundary = 0'u64
  var invalidPositions = 0'u64
  var resolvedObjectIds = 0'u64
  var totalGraphicsInfoLinks = 0'u64
  var resolvedGraphicsInfoLinks = 0'u64
  var totalModelLinks = 0'u64
  var resolvedRigidModelLinks = 0'u64
  var resolvedMeshLinks = 0'u64
  var directModelLinks = 0'u64
  var distinctPlacedModelIds = initHashSet[uint32]()
  var distinctPlacedMeshIds = initHashSet[uint32]()
  var candidateModelSamples: seq[uint32]
  var linkedResourceSamples = initHashSet[string]()
  var linkedResourceList: seq[string]
  echo "Object-instance records: ", itemCount
  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionLength) or
        itemEnd > uint64(sectionData.len) or itemLength < 28:
      raise newException(IOError, "Object-instance record range is malformed")

    let start = int(itemOffset)
    let limit = start + int(itemLength)
    var position: array[4, float32]
    for component in 0 .. 3:
      position[component] = cast[float32](readU32LE(sectionData,
        start + component * 4))
    var rotations: array[6, uint16]
    for component in 0 .. 5:
      rotations[component] = readU16LE(sectionData, start + 16 + component * 2)

    var cursor = start + 28
    let instanceReferences = skipInstanceReferenceList(sectionData, cursor, limit)
    let positionReferences = skipInstanceReferenceList(sectionData, cursor, limit)
    let pathReferences = skipInstanceReferenceList(sectionData, cursor, limit)
    if cursor > limit - 10:
      raise newException(IOError, "Object-instance identity fields are truncated")
    let objectId = readU16LE(sectionData, cursor)
    let objectDefinitionResolves = objectId in objectDefinitionIds
    if objectDefinitionResolves:
      inc resolvedObjectIds
    let linkedGraphicsInfoIds = objectGraphicsInfoIds.getOrDefault(objectId,
      @[])
    var allGraphicsInfoLinksResolve = true
    for graphicsInfoId in linkedGraphicsInfoIds:
      inc totalGraphicsInfoLinks
      if graphicsInfoId in graphicsInfoIds:
        inc resolvedGraphicsInfoLinks
      else:
        allGraphicsInfoLinksResolve = false
    var placedModelIds = initHashSet[uint32]()
    for graphicsInfoId in linkedGraphicsInfoIds:
      if uint32(graphicsInfoId) in graphicsInfoModelIds:
        for modelId in graphicsInfoModelIds[uint32(graphicsInfoId)]:
          inc totalModelLinks
          placedModelIds.incl(modelId)
          distinctPlacedModelIds.incl(modelId)
          if candidateModelSamples.len < 12:
            candidateModelSamples.add(modelId)
          if modelId in graphicsModelLocations.rigidModels:
            inc resolvedRigidModelLinks
            let rigidLocation = graphicsModelLocations.rigidModels[modelId]
            if rigidLocation.resourcePath notin linkedResourceSamples:
              linkedResourceSamples.incl(rigidLocation.resourcePath)
              if linkedResourceList.len < 8:
                linkedResourceList.add(rigidLocation.resourcePath)
            distinctPlacedMeshIds.incl(rigidLocation.modelId)
            if rigidLocation.modelId in graphicsModelLocations.modelIds:
              inc resolvedMeshLinks
              let modelPath = graphicsModelLocations.modelIds[
                rigidLocation.modelId]
              if modelPath notin linkedResourceSamples:
                linkedResourceSamples.incl(modelPath)
                if linkedResourceList.len < 8:
                  linkedResourceList.add(modelPath)
          elif modelId in graphicsModelLocations.modelIds:
            inc directModelLinks
    cursor += 6
    cursor += 4
    let flags = readU32LE(sectionData, cursor)
    cursor += 4

    let integerProperties = skipInstanceWordList(sectionData, cursor, limit)
    let floatProperties = skipInstanceWordList(sectionData, cursor, limit)
    let extraProperties = skipInstanceWordList(sectionData, cursor, limit)
    if cursor == limit:
      inc recordsEndingAtBoundary

    if position[0] != position[0] or position[1] != position[1] or
        position[2] != position[2] or position[3] != position[3]:
      inc invalidPositions
    totalReferences += uint64(instanceReferences + positionReferences +
      pathReferences)
    echo "  record ", itemIndex, " id=", itemId, " object=", objectId,
      " definition-resolves=", objectDefinitionResolves,
      " ogi-count=", linkedGraphicsInfoIds.len,
      " ogis-resolve=", allGraphicsInfoLinksResolve,
      " candidate-models=", placedModelIds.len,
      " position=", position[0 .. 2], " rotations=", rotations,
      " ref-lists=", instanceReferences, "/", positionReferences, "/",
      pathReferences, " flags=0x", toHex(flags, 8), " properties=",
      integerProperties, "/", floatProperties, "/", extraProperties

  echo "Records decoded through declared fields: ", recordsEndingAtBoundary,
    " / ", itemCount
  echo "Position vectors with NaN components: ", invalidPositions
  echo "Linked IDs across the three reference lists: ", totalReferences
  if objectDefinitionIds.len > 0:
    echo "Object IDs resolving in the sibling Code/Object table: ",
      resolvedObjectIds, " / ", itemCount
  else:
    echo "Sibling Code/Object table was unavailable for this resource."
  echo "Object graphics-info links resolving in sibling Code/OGI table: ",
    resolvedGraphicsInfoLinks, " / ", totalGraphicsInfoLinks
  echo "Distinct candidate rigid-model IDs referenced by these placements: ",
    distinctPlacedModelIds.len
  echo "First candidate rigid-model IDs: ", candidateModelSamples
  echo "OGI model links resolving to RM2/SM2 rigid-model records: ",
    resolvedRigidModelLinks, " / ", totalModelLinks
  echo "Those rigid-model links resolving to graphics Model IDs: ",
    resolvedMeshLinks, " / ", resolvedRigidModelLinks
  echo "OGI links resolving directly to graphics Model IDs: ",
    directModelLinks
  echo "Distinct geometry Model IDs reached through rigid-model links: ",
    distinctPlacedMeshIds.len
  echo "Sample resources in resolved placement chains: ", linkedResourceList

proc readSectionTable(image: IsoImage, dataFile: IsoEntry, offset: int64,
    sectionLength: uint32): seq[uint8] =
  let fixedLength = int(min(sectionLength, 12'u32))
  let fixedHeader = image.readSlice(dataFile, offset, fixedLength)
  if fixedHeader.len < 12:
    raise newException(IOError, "Section is shorter than its header")

  let magic = readU32LE(fixedHeader, 0)
  if magic notin [0x00010001'u32, 0x00010003'u32]:
    raise newException(IOError,
      "Selected payload is not a recognized RM2/SM2 section table")

  let sectionCount = readU32LE(fixedHeader, 4)
  let tableLength = 12'u64 + uint64(sectionCount) * 12'u64
  if tableLength > uint64(sectionLength) or tableLength > uint64(high(int)):
    raise newException(IOError, "Section table extends beyond its section")

  image.readSlice(dataFile, offset, int(tableLength))

proc collectArchiveModelLocations(image: IsoImage, dataFile: IsoEntry,
    indexData: openArray[uint8]): ArchiveModelIndex =
  result.modelIds = initTable[uint32, string]()
  result.rigidModels = initTable[uint32, ModelLocation]()
  var indexCursor = 4
  while indexCursor < indexData.len:
    let archiveEntry = parseArchiveEntry(indexData, indexCursor)
    let lowerPath = archiveEntry.path.toLowerAscii()
    let isRm2 = lowerPath.endsWith(".rm2")
    let isSm2 = lowerPath.endsWith(".sm2")
    if not (isRm2 or isSm2) or
        uint64(archiveEntry.dataOffset) + uint64(archiveEntry.dataLength) >
          uint64(dataFile.byteLength):
      continue

    try:
      let resourceOffset = int64(archiveEntry.dataOffset)
      let rootTable = readSectionTable(image, dataFile, resourceOffset,
        archiveEntry.dataLength)
      let rootCount = readU32LE(rootTable, 4)
      for rootIndex in 0 ..< int(rootCount):
        let rootEntryOffset = 12 + rootIndex * 12
        let rootOffset = readU32LE(rootTable, rootEntryOffset)
        let rootLength = readU32LE(rootTable, rootEntryOffset + 4)
        let rootId = readU32LE(rootTable, rootEntryOffset + 8)
        if rootId != (if isRm2: 11'u32 else: 6'u32):
          continue

        let graphicsTable = readSectionTable(image, dataFile,
          resourceOffset + int64(rootOffset), rootLength)
        let graphicsCount = readU32LE(graphicsTable, 4)
        for graphicsIndex in 0 ..< int(graphicsCount):
          let graphicsEntryOffset = 12 + graphicsIndex * 12
          let graphicsOffset = readU32LE(graphicsTable, graphicsEntryOffset)
          let graphicsLength = readU32LE(graphicsTable,
            graphicsEntryOffset + 4)
          let graphicsChildId = readU32LE(graphicsTable,
            graphicsEntryOffset + 8)
          if graphicsChildId notin [2'u32, 3'u32]:
            continue
          let modelOffset = resourceOffset + int64(rootOffset) +
            int64(graphicsOffset)
          if graphicsChildId == 2:
            let modelTable = readSectionTable(image, dataFile, modelOffset,
              graphicsLength)
            for modelId in collectSectionTableIds(modelTable, graphicsLength):
              if modelId notin result.modelIds:
                result.modelIds[modelId] = archiveEntry.path
          else:
            let rigidModelData = image.readSlice(dataFile, modelOffset,
              int(graphicsLength))
            for rigidModelId, modelId in collectRigidModelLinks(
                rigidModelData, graphicsLength):
              if rigidModelId notin result.rigidModels:
                result.rigidModels[rigidModelId] = ModelLocation(
                  resourcePath: archiveEntry.path,
                  modelId: modelId
                )
        break
    except IOError:
      discard

proc inspectIsoResource(imagePath, requestedPath: string, outerSectionIndex,
    nestedSectionIndex: int) =
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
  let resourceHeader = readSectionTable(
    image, dataFile, resourceOffset, archiveEntry.dataLength
  )

  echo "ISO volume: ", image.volumeName
  echo "Resource: ", archiveEntry.path
  echo "Bytes: ", archiveEntry.dataLength
  let sections = inspectResource(resourceHeader, archiveEntry.dataLength)

  if outerSectionIndex >= 0:
    if outerSectionIndex >= sections.len:
      raise newException(IOError, "Outer section index is out of range")
    let section = sections[outerSectionIndex]
    let sectionOffset = resourceOffset + int64(section.offset)
    if paramCount() == 6:
      if paramStr(4) != "--hex":
        raise newException(IOError, "Expected --hex before the requested byte range")
      var hexOffset, hexByteCount: int
      try:
        hexOffset = parseInt(paramStr(5))
        hexByteCount = parseInt(paramStr(6))
      except ValueError:
        raise newException(IOError, "Hex range offset and size must be integers")
      let sectionData = image.readSlice(dataFile, sectionOffset,
        int(section.byteLength))
      echo "Payload for outer section index ", outerSectionIndex,
        " (id=", section.id, ", bytes=", section.byteLength, ")"
      dumpHexRange(sectionData, hexOffset, hexByteCount)
      return

    let nestedHeader = readSectionTable(
      image, dataFile, sectionOffset, section.byteLength
    )
    echo "Nested table for outer section index ", outerSectionIndex,
      " (id=", section.id, ", bytes=", section.byteLength, ")"
    let nestedSections = inspectResource(nestedHeader, section.byteLength)

    if nestedSectionIndex >= 0:
      if nestedSectionIndex >= nestedSections.len:
        raise newException(IOError, "Nested section index is out of range")
      let childSection = nestedSections[nestedSectionIndex]
      let childOffset = sectionOffset + int64(childSection.offset)
      let childData = image.readSlice(dataFile, childOffset,
        int(childSection.byteLength))
      echo "Payload for nested section index ", nestedSectionIndex,
        " (id=", childSection.id, ", bytes=", childSection.byteLength, ")"
      if paramCount() == 7:
        if paramStr(5) != "--hex":
          raise newException(IOError, "Expected --hex before the requested byte range")
        var hexOffset, hexByteCount: int
        try:
          hexOffset = parseInt(paramStr(6))
          hexByteCount = parseInt(paramStr(7))
        except ValueError:
          raise newException(IOError, "Hex range offset and size must be integers")
        dumpHexRange(childData, hexOffset, hexByteCount)
      elif section.id == 11 and childSection.id == 2:
        var rigidMaterialCounts = initTable[uint32, uint32]()
        for sibling in nestedSections:
          if sibling.id in [3'u32, 6'u32]:
            let siblingOffset = sectionOffset + int64(sibling.offset)
            let siblingData = image.readSlice(dataFile, siblingOffset,
              int(sibling.byteLength))
            rigidMaterialCounts = collectRigidMaterialCounts(siblingData,
              sibling.byteLength)
            if rigidMaterialCounts.len > 0:
              break
        inspectModelItems(childData, childSection.byteLength,
          rigidMaterialCounts)
      elif section.id == 11 and childSection.id in [3'u32, 6'u32]:
        var modelIds = initHashSet[uint32]()
        var materialIds = initHashSet[uint32]()
        for sibling in nestedSections:
          if sibling.id in [1'u32, 2'u32]:
            let siblingOffset = sectionOffset + int64(sibling.offset)
            let siblingData = image.readSlice(dataFile, siblingOffset,
              int(sibling.byteLength))
            let siblingIds = collectSectionItemIds(siblingData,
              sibling.byteLength)
            if sibling.id == 1:
              materialIds = siblingIds
            else:
              modelIds = siblingIds
        inspectRigidModels(childData, childSection.byteLength, modelIds,
          materialIds)
      elif section.id == 11 and childSection.id == 0:
        inspectTextureItems(childData, childSection.byteLength)
      elif section.id == 11 and childSection.id == 1:
        var textureIds = initHashSet[uint32]()
        for sibling in nestedSections:
          if sibling.id == 0:
            let siblingOffset = sectionOffset + int64(sibling.offset)
            let siblingData = image.readSlice(dataFile, siblingOffset,
              int(sibling.byteLength))
            textureIds = collectSectionItemIds(siblingData, sibling.byteLength)
            break
        discard inspectMaterialItems(childData, childSection.byteLength,
          textureIds)
      elif section.id <= 7 and childSection.id == 6:
        var objectDefinitionIds = initHashSet[uint32]()
        var objectGraphicsInfoIds = initTable[uint32, seq[uint16]]()
        var graphicsInfoIds = initHashSet[uint32]()
        var graphicsInfoModelIds = initTable[uint32, seq[uint32]]()
        let graphicsModelLocations = collectArchiveModelLocations(image,
          dataFile, indexData)
        echo "Model/rigid-model record IDs indexed across RM2 and SM2: ",
          graphicsModelLocations.modelIds.len, "/",
          graphicsModelLocations.rigidModels.len
        for codeSection in sections:
          if codeSection.id == 10:
            let codeOffset = resourceOffset + int64(codeSection.offset)
            let codeHeader = readSectionTable(image, dataFile, codeOffset,
              codeSection.byteLength)
            let codeCount = readU32LE(codeHeader, 4)
            for codeIndex in 0 ..< int(codeCount):
              let entryOffset = 12 + codeIndex * 12
              let codeChildOffset = readU32LE(codeHeader, entryOffset)
              let codeChildLength = readU32LE(codeHeader, entryOffset + 4)
              let codeChildId = readU32LE(codeHeader, entryOffset + 8)
              if codeChildId in [0'u32, 3'u32]:
                let objectData = image.readSlice(dataFile,
                  codeOffset + int64(codeChildOffset), int(codeChildLength))
                if codeChildId == 0:
                  objectGraphicsInfoIds = collectGameObjectGraphicsInfoIds(
                    objectData, codeChildLength)
                  for objectId in objectGraphicsInfoIds.keys:
                    objectDefinitionIds.incl(objectId)
                else:
                  graphicsInfoIds = collectSectionItemIds(objectData,
                    codeChildLength)
            break
        if graphicsInfoIds.len > 0:
          for codeSection in sections:
            if codeSection.id == 10:
              let codeOffset = resourceOffset + int64(codeSection.offset)
              let codeHeader = readSectionTable(image, dataFile, codeOffset,
                codeSection.byteLength)
              let codeCount = readU32LE(codeHeader, 4)
              for codeIndex in 0 ..< int(codeCount):
                let entryOffset = 12 + codeIndex * 12
                let codeChildOffset = readU32LE(codeHeader, entryOffset)
                let codeChildLength = readU32LE(codeHeader, entryOffset + 4)
                let codeChildId = readU32LE(codeHeader, entryOffset + 8)
                if codeChildId == 3:
                  let graphicsInfoData = image.readSlice(dataFile,
                    codeOffset + int64(codeChildOffset), int(codeChildLength))
                  graphicsInfoModelIds = collectGraphicsInfoModelIds(
                    graphicsInfoData, codeChildLength)
                  break
              break
        inspectObjectInstances(childData, childSection.byteLength,
          objectDefinitionIds, objectGraphicsInfoIds, graphicsInfoIds,
          graphicsInfoModelIds, graphicsModelLocations)
      else:
        echo "No specialized parser for outer section ID ", section.id,
          " and nested section ID ", childSection.id

proc main() =
  if paramCount() notin [2, 3, 4, 6, 7]:
    quit("Usage: rm2_inspect <image.iso> <path-inside-CRASH.BD> [outer-section-index [nested-section-index [--hex offset byte-count]] | outer-section-index --hex offset byte-count]", 1)

  var outerSectionIndex = -1
  var nestedSectionIndex = -1
  if paramCount() >= 3:
    try:
      outerSectionIndex = parseInt(paramStr(3))
    except ValueError:
      quit("Outer section index must be an integer", 1)
  if paramCount() in [4, 7]:
    try:
      nestedSectionIndex = parseInt(paramStr(4))
    except ValueError:
      quit("Nested section index must be an integer", 1)

  try:
    inspectIsoResource(paramStr(1), paramStr(2), outerSectionIndex,
      nestedSectionIndex)
  except IOError as error:
    quit(error.msg, 1)
  except ValueError as error:
    quit("Could not decode resource: " & error.msg, 1)

when isMainModule:
  main()
