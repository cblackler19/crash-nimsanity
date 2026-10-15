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

import iso9660

type
  ArchiveEntry = object
    path: string
    dataOffset: uint32
    dataLength: uint32

  SectionEntry = object
    offset: uint32
    byteLength: uint32
    id: uint32

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

proc inspectModelItems(sectionData: openArray[uint8], sectionLength: uint32) =
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

proc inspectRigidModels(sectionData: openArray[uint8], sectionLength: uint32) =
  if sectionData.len < 12:
    raise newException(IOError, "Rigid-model section is shorter than its header")

  let sectionCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(sectionCount) * 12'u64
  if tableLength > uint64(sectionData.len) or tableLength > uint64(sectionLength):
    raise newException(IOError, "Rigid-model item table extends beyond its section")

  var totalMaterialLinks = 0'u64
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
      materials.add(readU32LE(sectionData, cursor))
      cursor += 4
    let meshId = readU32LE(sectionData, cursor)
    cursor += 4

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
  echo "Distinct referenced mesh IDs: ", uniqueMeshIds.len
  echo "Header values: ", headerValues
  echo "Records with trailing bytes: ", recordsWithTrailingBytes

proc readSectionTable(image: IsoImage, dataFile: IsoEntry, offset: int64,
    sectionLength: uint32): seq[uint8] =
  let fixedLength = int(min(sectionLength, 12'u32))
  let fixedHeader = image.readSlice(dataFile, offset, fixedLength)
  if fixedHeader.len < 12:
    raise newException(IOError, "Section is shorter than its header")

  let sectionCount = readU32LE(fixedHeader, 4)
  let tableLength = 12'u64 + uint64(sectionCount) * 12'u64
  if tableLength > uint64(sectionLength) or tableLength > uint64(high(int)):
    raise newException(IOError, "Section table extends beyond its section")

  image.readSlice(dataFile, offset, int(tableLength))

proc inspectIsoResource(imagePath, requestedPath: string, nestedIndex,
    modelIndex: int) =
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

  if nestedIndex >= 0:
    if nestedIndex >= sections.len:
      raise newException(IOError, "Outer section index is out of range")
    let section = sections[nestedIndex]
    let sectionOffset = resourceOffset + int64(section.offset)
    let nestedHeader = readSectionTable(
      image, dataFile, sectionOffset, section.byteLength
    )
    echo "Nested table for outer section index ", nestedIndex,
      " (id=", section.id, ", bytes=", section.byteLength, ")"
    let nestedSections = inspectResource(nestedHeader, section.byteLength)

    if modelIndex >= 0:
      if modelIndex >= nestedSections.len:
        raise newException(IOError, "Nested section index is out of range")
      let modelSection = nestedSections[modelIndex]
      let modelOffset = sectionOffset + int64(modelSection.offset)
      let modelData = image.readSlice(dataFile, modelOffset,
        int(modelSection.byteLength))
      echo "Item table for nested section index ", modelIndex,
        " (id=", modelSection.id, ", bytes=", modelSection.byteLength, ")"
      if modelSection.id == 2:
        inspectModelItems(modelData, modelSection.byteLength)
      elif modelSection.id in [3'u32, 6'u32]:
        inspectRigidModels(modelData, modelSection.byteLength)
      else:
        echo "No specialized item parser for nested section ID ",
          modelSection.id

proc main() =
  if paramCount() notin [2, 3, 4]:
    quit("Usage: rm2_inspect <image.iso> <path-inside-CRASH.BD> [outer-section-index [item-section-index]]", 1)

  var nestedIndex = -1
  var modelIndex = -1
  if paramCount() >= 3:
    try:
      nestedIndex = parseInt(paramStr(3))
    except ValueError:
      quit("Outer section index must be an integer", 1)
  if paramCount() == 4:
    try:
      modelIndex = parseInt(paramStr(4))
    except ValueError:
      quit("Item section index must be an integer", 1)

  try:
    inspectIsoResource(paramStr(1), paramStr(2), nestedIndex, modelIndex)
  except IOError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
