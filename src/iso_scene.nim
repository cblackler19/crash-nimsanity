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
import std/[math, sets, strutils, tables]

import math3d
import iso9660
import iso_model
import iso_texture
import ps2_model
import ps2_texture
import scenery_section

type
  SectionRange = object
    offset: uint32
    byteLength: uint32
    id: uint32

  ArchiveEntry = object
    path: string
    dataOffset: uint32
    dataLength: uint32

  RigidModelLocation = object
    resourcePath: string
    geometryModelId: uint32

  ChunkLink = object
    path: string
    linkType: uint32
    objectMatrix: Mat4
    chunkMatrix: Mat4

  ChunkTraversalEntry = object
    path: string
    transform: Mat4
    depth: int

  SceneModel* = object
    modelId*: uint32
    modelPath*: string
    materialPath*: string
    textureId*: uint32
    hasTexture*: bool
    isStaticGeometry*: bool
    modelTransform*: Mat4
    hasSceneryBounds*: bool
    sceneryBoundsMinimum*: array[3, float32]
    sceneryBoundsMaximum*: array[3, float32]
    model*: DecodedModel
    texture*: DecodedTexture

  ScenePlacement* = object
    instanceId*: uint32
    objectId*: uint16
    modelIndex*: int
    chunkTransform*: Mat4
    position*: array[3, float32]
    rotations*: array[6, uint16]

  ScenePreview* = object
    models*: seq[SceneModel]
    placements*: seq[ScenePlacement]
    staticGeometry*: bool
    center*: array[3, float32]
    minimum*: array[3, float32]
    maximum*: array[3, float32]

proc readU16LE(data: openArray[uint8], offset: int): uint16 =
  if offset < 0 or offset > data.len - 2:
    raise newException(IOError, "16-bit field exceeds its bounded record")
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc readU32LE(data: openArray[uint8], offset: int): uint32 =
  if offset < 0 or offset > data.len - 4:
    raise newException(IOError, "32-bit field exceeds its bounded record")
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc readF32LE(data: openArray[uint8], offset: int): float32 =
  cast[float32](readU32LE(data, offset))

proc readMatrixRows(data: openArray[uint8], offset, limit: int): Mat4 =
  if offset < 0 or offset > limit - 64 or limit > data.len:
    raise newException(IOError, "Chunk-link matrix exceeds its section")
  # Link matrices serialize row vectors; OpenGL transforms column vectors.
  for index in 0 .. 15:
    result[index] = readF32LE(data, offset + index * 4)

proc skipChunkLinkTree(data: openArray[uint8], cursor: var int, limit: int,
    nodeType: uint32, depth = 0) =
  if (nodeType and 1'u32) == 0:
    return
  if depth >= 64 or cursor > limit - 30:
    raise newException(IOError, "Chunk-link tree header exceeds its section")
  let nextType = readU32LE(data, cursor)
  cursor += 26
  let blobSize = readU32LE(data, cursor)
  cursor += 4
  if blobSize < 320 or uint64(blobSize) > uint64(limit - cursor):
    raise newException(IOError, "Chunk-link tree payload exceeds its section")
  cursor += int(blobSize)
  skipChunkLinkTree(data, cursor, limit, nextType, depth + 1)

proc parseArchiveEntry(data: openArray[uint8], cursor: var int): ArchiveEntry =
  if cursor < 4 or cursor > data.len - 4:
    raise newException(IOError, "Truncated archive path length")
  let pathLength = readU32LE(data, cursor)
  let remaining = data.len - cursor - 4
  if pathLength == 0 or remaining < 8 or
      uint64(pathLength) > uint64(remaining - 8):
    raise newException(IOError, "Invalid archive path length")

  let pathStart = cursor + 4
  let pathEnd = pathStart + int(pathLength)
  result.path = newString(int(pathLength))
  for index in 0 ..< result.path.len:
    result.path[index] = char(data[pathStart + index])
  result.dataOffset = readU32LE(data, pathEnd)
  result.dataLength = readU32LE(data, pathEnd + 4)
  cursor = pathEnd + 8

proc readSectionTable(image: IsoImage, dataFile: IsoEntry, offset: int64,
    sectionLength: uint32): seq[SectionRange] =
  if sectionLength < 12:
    raise newException(IOError, "Section is shorter than its table header")
  let header = image.readSlice(dataFile, offset, 12)
  let itemCount = readU32LE(header, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionLength) or tableLength > uint64(high(int)):
    raise newException(IOError, "Section table exceeds its bounded range")
  let table = image.readSlice(dataFile, offset, int(tableLength))

  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let item = SectionRange(
      offset: readU32LE(table, entryOffset),
      byteLength: readU32LE(table, entryOffset + 4),
      id: readU32LE(table, entryOffset + 8)
    )
    if item.offset < tableLength or
        uint64(item.offset) + uint64(item.byteLength) > uint64(sectionLength):
      raise newException(IOError, "Section child exceeds its parent range")
    result.add(item)

proc readSection(image: IsoImage, dataFile: IsoEntry, baseOffset: int64,
    section: SectionRange): seq[uint8] =
  image.readSlice(dataFile, baseOffset + int64(section.offset),
    int(section.byteLength))

proc parseItemIds(sectionData: openArray[uint8]): seq[uint32] =
  let count = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(count) * 12'u64
  if tableLength > uint64(sectionData.len):
    raise newException(IOError, "Item table exceeds its section")
  for itemIndex in 0 ..< int(count):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Item payload exceeds its section")
    result.add(readU32LE(sectionData, entryOffset + 8))

proc readChunkLinksFromIso(imagePath, resourcePath: string): seq[ChunkLink] =
  let image = openIso(imagePath)
  defer: image.close()

  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let requested = resourcePath.replace('/', '\\').toLowerAscii()
  var archiveCursor = 4
  var resourceEntry: ArchiveEntry
  var foundResource = false
  while archiveCursor < indexData.len:
    let entry = parseArchiveEntry(indexData, archiveCursor)
    if entry.path.replace('/', '\\').toLowerAscii() == requested:
      resourceEntry = entry
      foundResource = true
      break
  if not foundResource:
    raise newException(IOError, "Resource path was not found in CRASH.BH")
  if uint64(resourceEntry.dataOffset) + uint64(resourceEntry.dataLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Resource range exceeds CRASH.BD")

  let resourceOffset = int64(resourceEntry.dataOffset)
  let rootSections = readSectionTable(image, dataFile, resourceOffset,
    resourceEntry.dataLength)
  for rootSection in rootSections:
    if rootSection.id != 5:
      continue
    let sectionData = readSection(image, dataFile, resourceOffset, rootSection)
    if sectionData.len < 4:
      raise newException(IOError, "SM2 chunk-link section is truncated")
    let linkCount = readU32LE(sectionData, 0)
    if uint64(linkCount) > uint64(sectionData.len div 140):
      raise newException(IOError, "SM2 chunk-link count exceeds its section")
    var cursor = 4
    for _ in 0 ..< int(linkCount):
      if cursor > sectionData.len - 8:
        raise newException(IOError, "SM2 chunk-link header is truncated")
      let linkType = readU32LE(sectionData, cursor)
      let pathLength = readU32LE(sectionData, cursor + 4)
      cursor += 8
      if uint64(pathLength) > uint64(sectionData.len - cursor - 4):
        raise newException(IOError, "SM2 chunk-link path exceeds its section")
      var path = newString(int(pathLength))
      for pathIndex in 0 ..< path.len:
        path[pathIndex] = char(sectionData[cursor + pathIndex])
      cursor += path.len
      let flags = readU32LE(sectionData, cursor)
      cursor += 4
      let objectMatrix = readMatrixRows(sectionData, cursor, sectionData.len)
      cursor += 64
      let chunkMatrix = readMatrixRows(sectionData, cursor, sectionData.len)
      cursor += 64
      if (flags and 0x80000'u32) != 0:
        discard readMatrixRows(sectionData, cursor, sectionData.len)
        cursor += 64
      skipChunkLinkTree(sectionData, cursor, sectionData.len, linkType)
      result.add(ChunkLink(path: path, linkType: linkType,
        objectMatrix: objectMatrix, chunkMatrix: chunkMatrix))
    break

proc parseObjectOgiLinks(sectionData: openArray[uint8]): Table[uint32, seq[uint16]] =
  result = initTable[uint32, seq[uint16]]()
  if sectionData.len < 12:
    raise newException(IOError, "Object table is shorter than its header")
  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len):
    raise newException(IOError, "Object table exceeds its section")

  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionData.len):
      raise newException(IOError, "Object record exceeds its section")

    let limit = int(itemEnd)
    var cursor = int(itemOffset) + 12
    if cursor > limit - 4:
      raise newException(IOError, "Object name length is truncated")
    let nameLength = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(nameLength) > uint64(limit - cursor):
      raise newException(IOError, "Object name exceeds its record")
    cursor += int(nameLength)
    if cursor > limit - 4:
      raise newException(IOError, "Object script count is truncated")
    let scriptCount = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(scriptCount) > uint64((limit - cursor) div 4):
      raise newException(IOError, "Object script list exceeds its record")
    cursor += int(scriptCount) * 4
    if cursor > limit - 4:
      raise newException(IOError, "Object OGI count is truncated")
    let ogiCount = readU32LE(sectionData, cursor)
    cursor += 4
    if uint64(ogiCount) > uint64((limit - cursor) div 2):
      raise newException(IOError, "Object OGI list exceeds its record")
    for linkIndex in 0 ..< int(ogiCount):
      result.mgetOrPut(itemId, @[]).add(
        readU16LE(sectionData, cursor + linkIndex * 2))

proc parseOgiModels(sectionData: openArray[uint8]): Table[uint32, seq[uint32]] =
  result = initTable[uint32, seq[uint32]]()
  if sectionData.len < 12:
    raise newException(IOError, "OGI table is shorter than its header")
  let itemCount = readU32LE(sectionData, 4)
  let tableLength = 12'u64 + uint64(itemCount) * 12'u64
  if tableLength > uint64(sectionData.len):
    raise newException(IOError, "OGI table exceeds its section")

  for itemIndex in 0 ..< int(itemCount):
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(sectionData, entryOffset)
    let itemLength = readU32LE(sectionData, entryOffset + 4)
    let itemId = readU32LE(sectionData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < tableLength or itemEnd > uint64(sectionData.len) or
        itemLength < 56:
      raise newException(IOError, "OGI record exceeds its section")

    let start = int(itemOffset)
    let limit = int(itemEnd)
    let jointCount = int(sectionData[start])
    let exitPointCount = int(sectionData[start + 1])
    let modelCount = int(sectionData[start + 5])
    var cursor = start + 48
    let transformBytes = uint64(jointCount) * 100'u64 +
      uint64(exitPointCount) * 72'u64
    if transformBytes > uint64(limit - cursor):
      raise newException(IOError, "OGI transform data exceeds its record")
    cursor += int(transformBytes)
    if modelCount > limit - cursor:
      raise newException(IOError, "OGI joint indices exceed its record")
    cursor += modelCount
    if uint64(modelCount) * 4'u64 > uint64(limit - cursor):
      raise newException(IOError, "OGI model IDs exceed its record")
    for modelIndex in 0 ..< modelCount:
      result.mgetOrPut(itemId, @[]).add(
        readU32LE(sectionData, cursor + modelIndex * 4))

proc collectArchiveModels(image: IsoImage, dataFile: IsoEntry,
    indexData: openArray[uint8]): tuple[modelPaths: Table[uint32, string],
    resourceModelIds: Table[string, HashSet[uint32]],
    rigidModels: Table[uint32, RigidModelLocation]] =
  result.modelPaths = initTable[uint32, string]()
  result.resourceModelIds = initTable[string, HashSet[uint32]]()
  result.rigidModels = initTable[uint32, RigidModelLocation]()
  var cursor = 4
  while cursor < indexData.len:
    let entry = parseArchiveEntry(indexData, cursor)
    let lowerPath = entry.path.toLowerAscii()
    let isRm2 = lowerPath.endsWith(".rm2")
    let isSm2 = lowerPath.endsWith(".sm2")
    if not (isRm2 or isSm2) or
        uint64(entry.dataOffset) + uint64(entry.dataLength) >
          uint64(dataFile.byteLength):
      continue

    try:
      let resourceOffset = int64(entry.dataOffset)
      let rootSections = readSectionTable(image, dataFile, resourceOffset,
        entry.dataLength)
      let graphicsId = if isRm2: 11'u32 else: 6'u32
      var localModelIds = initHashSet[uint32]()
      for rootSection in rootSections:
        if rootSection.id != graphicsId:
          continue
        let graphicsOffset = resourceOffset + int64(rootSection.offset)
        let graphicsSections = readSectionTable(image, dataFile,
          graphicsOffset, rootSection.byteLength)
        for graphicsSection in graphicsSections:
          if graphicsSection.id == 2:
            let modelTable = image.readSlice(dataFile,
              graphicsOffset + int64(graphicsSection.offset),
              int(graphicsSection.byteLength))
            for modelId in parseItemIds(modelTable):
              localModelIds.incl(modelId)
              if modelId notin result.modelPaths:
                result.modelPaths[modelId] = entry.path
          elif graphicsSection.id == (if isSm2: 6'u32 else: 3'u32):
            let rigidData = image.readSlice(dataFile,
              graphicsOffset + int64(graphicsSection.offset),
              int(graphicsSection.byteLength))
            let rigidCount = readU32LE(rigidData, 4)
            let rigidTableLength = 12'u64 + uint64(rigidCount) * 12'u64
            if rigidTableLength > uint64(rigidData.len):
              raise newException(IOError, "Rigid-model table exceeds its section")
            for rigidIndex in 0 ..< int(rigidCount):
              let entryOffset = 12 + rigidIndex * 12
              let itemOffset = readU32LE(rigidData, entryOffset)
              let itemLength = readU32LE(rigidData, entryOffset + 4)
              let rigidId = readU32LE(rigidData, entryOffset + 8)
              let itemEnd = uint64(itemOffset) + uint64(itemLength)
              if itemOffset < rigidTableLength or itemEnd > uint64(rigidData.len) or
                  itemLength < 12:
                raise newException(IOError, "Rigid-model record is malformed")
              let materialCount = readU32LE(rigidData, int(itemOffset) + 4)
              let geometryOffset = uint64(itemOffset) + 8'u64 +
                uint64(materialCount) * 4'u64
              if geometryOffset + 4'u64 > itemEnd:
                raise newException(IOError, "Rigid-model geometry link is truncated")
              if rigidId notin result.rigidModels:
                result.rigidModels[rigidId] = RigidModelLocation(
                  resourcePath: entry.path,
                  geometryModelId: readU32LE(rigidData, int(geometryOffset))
                )
        break
      if localModelIds.len > 0:
        result.resourceModelIds[entry.path] = localModelIds
    except CatchableError:
      discard

proc readCodeTables(image: IsoImage, dataFile: IsoEntry, resourceOffset: int64,
    sections: openArray[SectionRange]): tuple[
    objectOgis: Table[uint32, seq[uint16]],
    ogiModels: Table[uint32, seq[uint32]]] =
  result.objectOgis = initTable[uint32, seq[uint16]]()
  result.ogiModels = initTable[uint32, seq[uint32]]()
  for rootSection in sections:
    if rootSection.id != 10:
      continue
    let codeOffset = resourceOffset + int64(rootSection.offset)
    let codeSections = readSectionTable(image, dataFile, codeOffset,
      rootSection.byteLength)
    for codeSection in codeSections:
      if codeSection.id == 0:
        result.objectOgis = parseObjectOgiLinks(readSection(image,
          dataFile, codeOffset, codeSection))
      elif codeSection.id == 3:
        result.ogiModels = parseOgiModels(readSection(image, dataFile,
          codeOffset, codeSection))
    break

proc skipReferenceList(data: openArray[uint8], cursor: var int, limit: int) =
  if cursor < 0 or cursor > limit - 12:
    raise newException(IOError, "Instance reference-list header is truncated")
  let declaredCount = readU32LE(data, cursor)
  let storedCount = readU32LE(data, cursor + 4)
  cursor += 12
  if declaredCount != storedCount or
      uint64(storedCount) > uint64((limit - cursor) div 2):
    raise newException(IOError, "Instance reference list is malformed")
  cursor += int(storedCount) * 2

proc loadPlacementModelsFromIso*(imagePath, resourcePath: string,
    outerSectionIndex, nestedSectionIndex, maxRecords: int): ScenePreview =
  if maxRecords <= 0:
    raise newException(ValueError, "Placement record limit must be positive")
  let image = openIso(imagePath)
  defer: image.close()

  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let requested = resourcePath.replace('/', '\\').toLowerAscii()
  var archiveCursor = 4
  var resourceEntry: ArchiveEntry
  var foundResource = false
  while archiveCursor < indexData.len:
    let entry = parseArchiveEntry(indexData, archiveCursor)
    if entry.path.replace('/', '\\').toLowerAscii() == requested:
      resourceEntry = entry
      foundResource = true
      break
  if not foundResource:
    raise newException(IOError, "Resource path was not found in CRASH.BH")
  if uint64(resourceEntry.dataOffset) + uint64(resourceEntry.dataLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Resource range exceeds CRASH.BD")

  let resourceOffset = int64(resourceEntry.dataOffset)
  let rootSections = readSectionTable(image, dataFile, resourceOffset,
    resourceEntry.dataLength)
  if outerSectionIndex < 0 or outerSectionIndex >= rootSections.len:
    raise newException(ValueError, "Outer section index is out of range")
  let group = rootSections[outerSectionIndex]
  let groupOffset = resourceOffset + int64(group.offset)
  let nestedSections = readSectionTable(image, dataFile, groupOffset,
    group.byteLength)
  if nestedSectionIndex < 0 or nestedSectionIndex >= nestedSections.len:
    raise newException(ValueError, "Nested section index is out of range")
  let instanceSection = nestedSections[nestedSectionIndex]
  let instanceData = readSection(image, dataFile, groupOffset, instanceSection)
  let codeTables = readCodeTables(image, dataFile, resourceOffset, rootSections)
  let archiveModels = collectArchiveModels(image, dataFile, indexData)

  var loadedModels = initTable[string, int]()
  if instanceData.len < 12:
    raise newException(IOError, "Instance table is shorter than its header")
  let instanceCount = readU32LE(instanceData, 4)
  let instanceTableLength = 12'u64 + uint64(instanceCount) * 12'u64
  if instanceTableLength > uint64(instanceData.len):
    raise newException(IOError, "Instance item table exceeds its section")
  let recordsToRead = min(int(instanceCount), maxRecords)

  for itemIndex in 0 ..< recordsToRead:
    let entryOffset = 12 + itemIndex * 12
    let itemOffset = readU32LE(instanceData, entryOffset)
    let itemLength = readU32LE(instanceData, entryOffset + 4)
    let instanceId = readU32LE(instanceData, entryOffset + 8)
    let itemEnd = uint64(itemOffset) + uint64(itemLength)
    if itemOffset < instanceTableLength or itemEnd > uint64(instanceData.len) or
        itemLength < 28:
      raise newException(IOError, "Object-instance record is malformed")

    let start = int(itemOffset)
    let limit = int(itemEnd)
    var position: array[3, float32]
    for axis in 0 .. 2:
      position[axis] = readF32LE(instanceData, start + axis * 4)
    if position[0] != position[0] or position[1] != position[1] or
        position[2] != position[2]:
      continue
    var rotations: array[6, uint16]
    for axis in 0 .. 5:
      rotations[axis] = readU16LE(instanceData, start + 16 + axis * 2)

    var cursor = start + 28
    skipReferenceList(instanceData, cursor, limit)
    skipReferenceList(instanceData, cursor, limit)
    skipReferenceList(instanceData, cursor, limit)
    if cursor > limit - 10:
      raise newException(IOError, "Object-instance identity fields are truncated")
    let objectId = readU16LE(instanceData, cursor)
    let linkedOgis = codeTables.objectOgis.getOrDefault(uint32(objectId), @[])
    var selectedModelIndex = -1

    for ogiId in linkedOgis:
      if ogiId == high(uint16):
        continue
      for rigidId in codeTables.ogiModels.getOrDefault(uint32(ogiId), @[]):
        if rigidId notin archiveModels.rigidModels:
          continue
        let rigidLocation = archiveModels.rigidModels[rigidId]
        let geometryId = rigidLocation.geometryModelId
        if geometryId notin archiveModels.modelPaths:
          continue
        let localModelIds = archiveModels.resourceModelIds.getOrDefault(
          rigidLocation.resourcePath, initHashSet[uint32]())
        let modelPath = if geometryId in localModelIds:
          rigidLocation.resourcePath
        else:
          archiveModels.modelPaths[geometryId]
        let modelKey = modelPath.toLowerAscii() & ":" & $geometryId & ":" &
          rigidLocation.resourcePath.toLowerAscii() & ":" & $rigidId
        if modelKey in loadedModels:
          selectedModelIndex = loadedModels[modelKey]
          break
        try:
          var sceneModel = SceneModel(
            modelId: geometryId,
            modelPath: modelPath,
            materialPath: rigidLocation.resourcePath,
            model: loadModelFromIso(imagePath, modelPath, geometryId)
          )
          try:
            let textureLink = findTextureForModelFromIso(imagePath,
              rigidLocation.resourcePath, geometryId)
            sceneModel.textureId = textureLink.textureId
            sceneModel.texture = loadTextureFromIso(imagePath,
              rigidLocation.resourcePath, textureLink.textureId)
            sceneModel.hasTexture = true
          except CatchableError as error:
            echo "Placement model ", geometryId,
              " has no resolving texture; drawing decoded vertex colors: ",
              error.msg

          selectedModelIndex = result.models.len
          result.models.add(sceneModel)
          loadedModels[modelKey] = selectedModelIndex
          if sceneModel.hasTexture:
            echo "Placement model ", geometryId, " from ", modelPath,
              " using texture ", sceneModel.textureId, " in ",
              rigidLocation.resourcePath
          break
        except CatchableError as error:
          echo "Skipping model candidate ", geometryId, ": ", error.msg
      if selectedModelIndex >= 0:
        break

    if selectedModelIndex < 0:
      echo "Placement record ", instanceId, " (object ", objectId,
        ") has no loadable model candidate"
      continue

    result.placements.add(ScenePlacement(
      instanceId: instanceId,
      objectId: objectId,
      modelIndex: selectedModelIndex,
      chunkTransform: identityMatrix(),
      position: position,
      rotations: rotations
    ))

  if result.placements.len == 0:
    raise newException(IOError, "No loadable placed models found in this group")

  for axis in 0 .. 2:
    result.minimum[axis] = result.placements[0].position[axis]
    result.maximum[axis] = result.placements[0].position[axis]
  for placement in result.placements:
    for axis in 0 .. 2:
      result.minimum[axis] = min(result.minimum[axis], placement.position[axis])
      result.maximum[axis] = max(result.maximum[axis], placement.position[axis])
  for axis in 0 .. 2:
    result.center[axis] = (result.minimum[axis] + result.maximum[axis]) * 0.5'f32

proc loadPlacementGroupsFromIso(imagePath, resourcePath: string,
    maxRecords: int): ScenePreview =
  if maxRecords <= 0:
    raise newException(ValueError, "Placement record limit must be positive")
  if not resourcePath.toLowerAscii().endsWith(".rm2"):
    raise newException(ValueError, "Placement groups require an RM2 resource")

  let image = openIso(imagePath)
  defer: image.close()
  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let requested = resourcePath.replace('/', '\\').toLowerAscii()
  var archiveCursor = 4
  var resourceEntry: ArchiveEntry
  var foundResource = false
  while archiveCursor < indexData.len:
    let entry = parseArchiveEntry(indexData, archiveCursor)
    if entry.path.replace('/', '\\').toLowerAscii() == requested:
      resourceEntry = entry
      foundResource = true
      break
  if not foundResource:
    raise newException(IOError, "Resource path was not found in CRASH.BH")
  if uint64(resourceEntry.dataOffset) + uint64(resourceEntry.dataLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Resource range exceeds CRASH.BD")

  let resourceOffset = int64(resourceEntry.dataOffset)
  let rootSections = readSectionTable(image, dataFile, resourceOffset,
    resourceEntry.dataLength)
  var groups: seq[tuple[outerIndex, nestedIndex: int]]
  for outerIndex, groupSection in rootSections:
    if groupSection.id > 7 or groupSection.byteLength < 12:
      continue
    let groupOffset = resourceOffset + int64(groupSection.offset)
    try:
      let nestedSections = readSectionTable(image, dataFile, groupOffset,
        groupSection.byteLength)
      for nestedIndex, nestedSection in nestedSections:
        if nestedSection.id != 6 or nestedSection.byteLength < 12:
          continue
        let instanceData = readSection(image, dataFile, groupOffset,
          nestedSection)
        if instanceData.len >= 12 and readU32LE(instanceData, 4) > 0:
          groups.add((outerIndex, nestedIndex))
    except CatchableError:
      continue

  var loadedModels = initTable[string, int]()
  for group in groups:
    try:
      let groupScene = loadPlacementModelsFromIso(imagePath, resourcePath,
        group.outerIndex, group.nestedIndex, maxRecords)
      var modelRemap = newSeq[int](groupScene.models.len)
      for groupModelIndex, sceneModel in groupScene.models:
        let modelKey = sceneModel.modelPath.toLowerAscii() & ":" &
          $sceneModel.modelId & ":" & sceneModel.materialPath.toLowerAscii() &
          ":" & $sceneModel.textureId
        if modelKey in loadedModels:
          modelRemap[groupModelIndex] = loadedModels[modelKey]
        else:
          modelRemap[groupModelIndex] = result.models.len
          loadedModels[modelKey] = result.models.len
          result.models.add(sceneModel)
      for placement in groupScene.placements:
        var merged = placement
        merged.modelIndex = modelRemap[placement.modelIndex]
        result.placements.add(merged)
      echo "Loaded placement group ", group.outerIndex, "/",
        group.nestedIndex, ": ", groupScene.placements.len,
        " object model instances"
    except CatchableError as error:
      echo "Skipping placement group ", group.outerIndex, "/",
        group.nestedIndex, ": ", error.msg

  if result.placements.len == 0:
    raise newException(IOError, "No loadable placements found in RM2 groups")
  for axis in 0 .. 2:
    result.minimum[axis] = result.placements[0].position[axis]
    result.maximum[axis] = result.placements[0].position[axis]
  for placement in result.placements:
    for axis in 0 .. 2:
      result.minimum[axis] = min(result.minimum[axis], placement.position[axis])
      result.maximum[axis] = max(result.maximum[axis], placement.position[axis])
  for axis in 0 .. 2:
    result.center[axis] = (result.minimum[axis] + result.maximum[axis]) * 0.5'f32

proc transformPoint(matrix: Mat4, position: array[3, float32]): array[3, float32] =
  for row in 0 .. 2:
    result[row] = matrix[row] * position[0] + matrix[4 + row] * position[1] +
      matrix[8 + row] * position[2] + matrix[12 + row]

proc sameChunkInstance(a, b: ChunkTraversalEntry): bool =
  if a.path.replace('/', '\\').toLowerAscii() !=
      b.path.replace('/', '\\').toLowerAscii():
    return false
  for index in 0 .. 15:
    if abs(a.transform[index] - b.transform[index]) > 1.0e-3'f32:
      return false
  true

proc containsChunkInstance(entries: openArray[ChunkTraversalEntry],
    candidate: ChunkTraversalEntry): bool =
  for entry in entries:
    if sameChunkInstance(entry, candidate):
      return true

proc loadStaticGeometryFromIso*(imagePath, resourcePath: string): ScenePreview =
  ## Load the SM2 scenery draw list and apply each stored per-item transform.
  if not resourcePath.toLowerAscii().endsWith(".sm2"):
    raise newException(ValueError, "Static geometry preview expects an SM2 resource")
  let image = openIso(imagePath)
  defer: image.close()

  let indexFile = image.findEntry("CRASH6/CRASH.BH")
  let dataFile = image.findEntry("CRASH6/CRASH.BD")
  let indexData = image.readSlice(indexFile, 0, int(indexFile.byteLength))
  let requested = resourcePath.replace('/', '\\').toLowerAscii()
  var archiveCursor = 4
  var resourceEntry: ArchiveEntry
  var foundResource = false
  while archiveCursor < indexData.len:
    let entry = parseArchiveEntry(indexData, archiveCursor)
    if entry.path.replace('/', '\\').toLowerAscii() == requested:
      resourceEntry = entry
      foundResource = true
      break
  if not foundResource:
    raise newException(IOError, "Resource path was not found in CRASH.BH")
  if uint64(resourceEntry.dataOffset) + uint64(resourceEntry.dataLength) >
      uint64(dataFile.byteLength):
    raise newException(IOError, "Resource range exceeds CRASH.BD")

  let resourceOffset = int64(resourceEntry.dataOffset)
  let rootSections = readSectionTable(image, dataFile, resourceOffset,
    resourceEntry.dataLength)
  var sceneryBytes: seq[uint8]
  var foundScenery = false
  var graphicsSection: SectionRange
  var foundGraphics = false
  for section in rootSections:
    if section.id == 0:
      sceneryBytes = readSection(image, dataFile, resourceOffset, section)
      foundScenery = true
    elif section.id == 6:
      graphicsSection = section
      foundGraphics = true
  if not foundScenery:
    raise newException(IOError, "SM2 scenery section (ID 0) was not found")
  if not foundGraphics:
    raise newException(IOError, "SM2 graphics section (ID 6) was not found")

  let graphicsOffset = resourceOffset + int64(graphicsSection.offset)
  let graphicsSections = readSectionTable(image, dataFile, graphicsOffset,
    graphicsSection.byteLength)
  var modelTable: seq[uint8]
  var foundModelTable = false
  for section in graphicsSections:
    if section.id == 2:
      modelTable = readSection(image, dataFile, graphicsOffset, section)
      foundModelTable = true
      break
  if not foundModelTable:
    raise newException(IOError, "SM2 model table (child ID 2) was not found")

  let modelIds = parseItemIds(modelTable)
  if modelIds.len == 0:
    raise newException(IOError, "SM2 contains no model items")

  let scenery = parseScenerySection(sceneryBytes)
  let archiveModels = collectArchiveModels(image, dataFile, indexData)

  var references: seq[SceneryModelReference]
  if scenery.hasRoot:
    references = scenery.modelReferences
    echo "SM2 scenery tree: ", references.len,
      " mesh/LOD references, ", modelIds.len, " graphics-table models"
  else:
    echo "SM2 has no scenery root; previewing its graphics-table models"
    for modelId in modelIds:
      references.add(SceneryModelReference(
        modelId: modelId,
        isLod: false,
        transform: identityMatrix(),
      ))

  result.staticGeometry = true
  var loadedModels = initTable[uint32, SceneModel]()
  var failedModels = initHashSet[uint32]()
  var skippedLods = 0
  var unresolvedModels = 0
  for reference in references:
    if reference.isLod:
      inc skippedLods
      continue
    let rigidModelId = reference.modelId
    var geometryModelId = rigidModelId
    var modelPath = resourcePath
    if scenery.hasRoot:
      if rigidModelId notin archiveModels.rigidModels:
        inc unresolvedModels
        echo "Scenery rigid-model ID ", rigidModelId,
          " is absent from the archive rigid-model tables"
        continue
      let rigidLocation = archiveModels.rigidModels[rigidModelId]
      geometryModelId = rigidLocation.geometryModelId
      modelPath = rigidLocation.resourcePath

    if geometryModelId in failedModels:
      continue
    if geometryModelId notin loadedModels:
      try:
        let model = loadModelFromIso(imagePath, modelPath, geometryModelId)
        var sceneModel = SceneModel(
          modelId: geometryModelId,
          modelPath: modelPath,
          materialPath: modelPath,
          isStaticGeometry: true,
          modelTransform: identityMatrix(),
          model: model,
        )
        try:
          let textureLink = findTextureForModelFromIso(imagePath, modelPath,
            geometryModelId)
          sceneModel.textureId = textureLink.textureId
          sceneModel.texture = loadTextureFromIso(imagePath, modelPath,
            textureLink.textureId)
          sceneModel.hasTexture = true
          echo "SM2 scenery rigid model ", rigidModelId, " -> geometry ",
            geometryModelId, ": ", model.submodelCount,
            " submodels, ", model.triangleCount,
            " candidate triangles, texture ", textureLink.textureId
        except CatchableError as error:
          echo "SM2 geometry model ", geometryModelId,
            " has no resolving texture; drawing decoded vertex colors: ",
            error.msg
        loadedModels[geometryModelId] = sceneModel
      except CatchableError as error:
        failedModels.incl(geometryModelId)
        echo "Skipping SM2 geometry model ", geometryModelId, ": ", error.msg

    if geometryModelId in loadedModels:
      var sceneModel = loadedModels[geometryModelId]
      sceneModel.modelTransform = reference.transform
      sceneModel.hasSceneryBounds = reference.hasBounds
      sceneModel.sceneryBoundsMinimum = reference.boundsMinimum
      sceneModel.sceneryBoundsMaximum = reference.boundsMaximum
      result.models.add(sceneModel)

  echo "SM2 scenery instances: ", result.models.len,
    " drawable meshes, ", skippedLods, " LOD entries skipped, ",
    unresolvedModels, " unresolved mesh IDs"

  if result.models.len == 0:
    raise newException(IOError, "No SM2 scenery meshes could be loaded")

  var hasBounds = false
  for sceneModel in result.models:
    for vertex in sceneModel.model.vertices:
      let worldPosition = transformPoint(sceneModel.modelTransform,
        vertex.position)
      if not hasBounds:
        for axis in 0 .. 2:
          result.minimum[axis] = worldPosition[axis]
          result.maximum[axis] = worldPosition[axis]
        hasBounds = true
      else:
        for axis in 0 .. 2:
          result.minimum[axis] = min(result.minimum[axis], worldPosition[axis])
          result.maximum[axis] = max(result.maximum[axis], worldPosition[axis])
  if not hasBounds:
    raise newException(IOError, "Loaded SM2 scenery has no triangle vertices")
  for axis in 0 .. 2:
    result.center[axis] = (result.minimum[axis] + result.maximum[axis]) * 0.5'f32

proc placementLocalTransform(placement: ScenePlacement): Mat4 =
  let angleScale = 2.0'f32 * PI.float32 / 65536.0'f32
  let rotateX = rotationMatrixX(float32(placement.rotations[0]) * angleScale)
  let rotateY = rotationMatrixY(float32(placement.rotations[2]) * angleScale)
  let rotateZ = rotationMatrixZ(float32(placement.rotations[4]) * angleScale)
  let rotation = multiply(rotateZ, multiply(rotateY, rotateX))
  multiply(translationMatrix(placement.position[0], placement.position[1],
    placement.position[2]), rotation)

proc fitSceneBounds*(scene: var ScenePreview, includeStaticGeometry,
    includePlacements: bool, selectedStaticModelIndex = -1,
    selectedPlacementIndex = -1) =
  ## Fit the preview to the geometry that its current draw mode will show.
  var hasBounds = false
  if includeStaticGeometry:
    var staticModelIndex = 0
    for sceneModel in scene.models:
      if not sceneModel.isStaticGeometry:
        continue
      if selectedStaticModelIndex >= 0 and
          staticModelIndex != selectedStaticModelIndex:
        inc staticModelIndex
        continue
      for vertex in sceneModel.model.vertices:
        let worldPosition = transformPoint(sceneModel.modelTransform,
          vertex.position)
        if not hasBounds:
          scene.minimum = worldPosition
          scene.maximum = worldPosition
          hasBounds = true
        else:
          for axis in 0 .. 2:
            scene.minimum[axis] = min(scene.minimum[axis], worldPosition[axis])
            scene.maximum[axis] = max(scene.maximum[axis], worldPosition[axis])
      inc staticModelIndex
    if selectedStaticModelIndex >= staticModelIndex:
      raise newException(ValueError, "Static model index is out of range")

  if includePlacements:
    if selectedPlacementIndex >= scene.placements.len:
      raise newException(ValueError, "Placement index is out of range")
    for placementIndex, placement in scene.placements:
      if selectedPlacementIndex >= 0 and
          placementIndex != selectedPlacementIndex:
        continue
      if placement.modelIndex < 0 or placement.modelIndex >= scene.models.len:
        raise newException(IOError, "Placement model index is out of range")
      let modelTransform = multiply(placement.chunkTransform,
        placementLocalTransform(placement))
      let placedModel = scene.models[placement.modelIndex].model
      for vertex in placedModel.vertices:
        let worldPosition = transformPoint(modelTransform, vertex.position)
        if not hasBounds:
          scene.minimum = worldPosition
          scene.maximum = worldPosition
          hasBounds = true
        else:
          for axis in 0 .. 2:
            scene.minimum[axis] = min(scene.minimum[axis], worldPosition[axis])
            scene.maximum[axis] = max(scene.maximum[axis], worldPosition[axis])

  if not hasBounds:
    raise newException(IOError, "Selected preview mode has no geometry bounds")
  for axis in 0 .. 2:
    scene.center[axis] = (scene.minimum[axis] + scene.maximum[axis]) * 0.5'f32

proc loadLinkedChunkGeometryFromIso*(imagePath, resourcePath: string,
    maxDepth: int, useChunkMatrix = false,
    selectedRootLink = -1): ScenePreview =
  ## Load linked SM2 chunks using one explicitly selected link-matrix candidate.
  if maxDepth < 0 or maxDepth > 2:
    raise newException(ValueError, "Chunk-link depth must be between 0 and 2")
  if selectedRootLink >= 0 and maxDepth == 0:
    raise newException(ValueError,
      "Selecting a root link requires a positive chunk-link depth")

  var pending = @[ChunkTraversalEntry(path: resourcePath,
    transform: identityMatrix(), depth: 0)]
  var visited: seq[ChunkTraversalEntry]
  var hasBounds = false
  result.staticGeometry = true

  var pendingIndex = 0
  while pendingIndex < pending.len:
    if pending.len > 64:
      raise newException(IOError, "Chunk-link traversal exceeds 64 resources")
    let current = pending[pendingIndex]
    inc pendingIndex
    if visited.containsChunkInstance(current):
      continue
    visited.add(current)

    var chunk: ScenePreview
    try:
      chunk = loadStaticGeometryFromIso(imagePath, current.path)
    except CatchableError as error:
      echo "Skipping linked SM2 resource ", current.path, ": ", error.msg
      continue

    echo "Loaded linked SM2 resource ", current.path,
      " at link depth ", current.depth
    for sceneModel in chunk.models:
      var placedModel = sceneModel
      placedModel.modelTransform = multiply(current.transform,
        sceneModel.modelTransform)
      for vertex in placedModel.model.vertices:
        let worldPosition = transformPoint(placedModel.modelTransform,
          vertex.position)
        if not hasBounds:
          for axis in 0 .. 2:
            result.minimum[axis] = worldPosition[axis]
            result.maximum[axis] = worldPosition[axis]
          hasBounds = true
        else:
          for axis in 0 .. 2:
            result.minimum[axis] = min(result.minimum[axis], worldPosition[axis])
            result.maximum[axis] = max(result.maximum[axis], worldPosition[axis])
      result.models.add(placedModel)

    var rm2Path = current.path
    if rm2Path.toLowerAscii().endsWith(".sm2"):
      rm2Path = rm2Path[0 ..< rm2Path.len - 4] & ".rm2"
    try:
      let placementScene = loadPlacementGroupsFromIso(imagePath, rm2Path, 10000)
      let modelOffset = result.models.len
      for sceneModel in placementScene.models:
        result.models.add(sceneModel)
      for placement in placementScene.placements:
        var placedInstance = placement
        placedInstance.modelIndex += modelOffset
        placedInstance.chunkTransform = current.transform
        result.placements.add(placedInstance)
        # Fit the camera around the rotated mesh, not just its placement origin.
        let modelTransform = multiply(current.transform,
          placementLocalTransform(placement))
        let placedModel = placementScene.models[placement.modelIndex].model
        for vertex in placedModel.vertices:
          let worldPosition = transformPoint(modelTransform, vertex.position)
          if not hasBounds:
            for axis in 0 .. 2:
              result.minimum[axis] = worldPosition[axis]
              result.maximum[axis] = worldPosition[axis]
            hasBounds = true
          else:
            for axis in 0 .. 2:
              result.minimum[axis] = min(result.minimum[axis], worldPosition[axis])
              result.maximum[axis] = max(result.maximum[axis], worldPosition[axis])
      echo "Loaded ", placementScene.placements.len,
        " RM2 object model instances from ", rm2Path
    except CatchableError as error:
      echo "No loadable RM2 placements in ", rm2Path, ": ", error.msg

    if current.depth >= maxDepth:
      continue
    let links = readChunkLinksFromIso(imagePath, current.path)
    if current.depth == 0 and selectedRootLink >= links.len:
      raise newException(ValueError, "Root chunk-link index is out of range")
    for linkIndex, link in links:
      if current.depth == 0 and selectedRootLink >= 0 and
          linkIndex != selectedRootLink:
        continue
      var targetPath = link.path
      if not targetPath.toLowerAscii().endsWith(".sm2"):
        targetPath.add(".sm2")
      let linkTransform = if useChunkMatrix: link.chunkMatrix else: link.objectMatrix
      let target = ChunkTraversalEntry(path: targetPath,
        transform: multiply(current.transform, linkTransform),
        depth: current.depth + 1)
      if not visited.containsChunkInstance(target) and
          not pending.containsChunkInstance(target):
        pending.add(target)

  if result.models.len == 0 or not hasBounds:
    raise newException(IOError, "No linked SM2 geometry could be loaded")
  for axis in 0 .. 2:
    result.center[axis] = (result.minimum[axis] + result.maximum[axis]) * 0.5'f32
