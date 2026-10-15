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
import std/[sets, strutils, tables]

import iso9660
import iso_model
import iso_texture
import ps2_model
import ps2_texture

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

  SceneModel* = object
    modelId*: uint32
    modelPath*: string
    materialPath*: string
    textureId*: uint32
    model*: DecodedModel
    texture*: DecodedTexture

  ScenePlacement* = object
    instanceId*: uint32
    objectId*: uint16
    modelIndex*: int
    position*: array[3, float32]
    rotations*: array[6, uint16]

  ScenePreview* = object
    models*: seq[SceneModel]
    placements*: seq[ScenePlacement]
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
          elif graphicsSection.id == 3:
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
          let textureLink = findTextureForModelFromIso(imagePath,
            rigidLocation.resourcePath, geometryId)
          var sceneModel = SceneModel(
            modelId: geometryId,
            modelPath: modelPath,
            materialPath: rigidLocation.resourcePath,
            textureId: textureLink.textureId,
            model: loadModelFromIso(imagePath, modelPath, geometryId),
            texture: loadTextureFromIso(imagePath,
              rigidLocation.resourcePath, textureLink.textureId)
          )
          selectedModelIndex = result.models.len
          result.models.add(sceneModel)
          loadedModels[modelKey] = selectedModelIndex
          echo "Placement model ", geometryId, " from ", modelPath,
            " using texture ", textureLink.textureId, " in ",
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
