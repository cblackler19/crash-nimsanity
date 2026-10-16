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
import std/[math, os, strutils]
import nimgl/[glfw, opengl]

import camera
import frustum
import iso_model
import iso_scene
import iso_texture
import math3d
import mesh
import ps2_model
import ps2_texture
import texture2d

const vertexShaderSource = """
#version 330 core

layout (location = 0) in vec3 aPosition;
layout (location = 1) in vec3 aColor;
layout (location = 2) in vec2 aTexCoord;
uniform mat4 uModel;
uniform mat4 uView;
uniform mat4 uProjection;

out vec3 vertexColor;
out vec2 textureCoord;

void main() {
    gl_Position = uProjection * uView * uModel * vec4(aPosition, 1.0);
    vertexColor = aColor;
    textureCoord = aTexCoord;
}
"""

const fragmentShaderSource = """
#version 330 core

in vec3 vertexColor;
in vec2 textureCoord;
uniform sampler2D uTexture;
uniform int uUseTexture;
uniform int uPreviewWhite;

out vec4 fragColor;

void main() {
    if (uPreviewWhite != 0) {
        fragColor = vec4(1.0);
    } else if (uUseTexture != 0) {
        fragColor = texture(uTexture, textureCoord) * vec4(vertexColor, 1.0);
    } else {
        fragColor = vec4(vertexColor, 1.0);
    }
}
"""

const MouseLookSensitivity = 0.0025'f32
const PreviewWhiteUniformValue = when defined(PreviewSolidWhite): 1 else: 0
var pendingScroll: float64

type PreviewAssets = object
  showTexture: bool
  showModel: bool
  useCandidateMaterialOrder: bool
  showStaticGeometry: bool
  selectedSubmodelIndex: int
  selectedGeometryIndex: int
  modelId: uint32
  materialId: uint32
  textureId: uint32
  texture: DecodedTexture
  candidateTextures: seq[DecodedTexture]
  model: DecodedModel
  showPlacements: bool
  scene: ScenePreview

proc parseId(argument, label: string): uint32 =
  try:
    let parsed = parseBiggestUInt(argument)
    if parsed > uint64(high(uint32)):
      quit(label & " must fit in 32 bits", 1)
    result = uint32(parsed)
  except ValueError:
    quit(label & " must be an unsigned integer", 1)

proc parseIndex(argument, label: string): int =
  try:
    result = parseInt(argument)
    if result < 0:
      quit(label & " must be zero or greater", 1)
  except ValueError:
    quit(label & " must be an integer", 1)

proc loadPreviewAssets(): PreviewAssets =
  result.selectedGeometryIndex = -1
  if paramCount() == 0:
    return
  if paramStr(1) == "--placements":
    if paramCount() notin [5, 6]:
      quit("Usage: main --placements image.iso resource-path " &
        "outer-section-index nested-section-index [record-limit]", 1)
    let maxRecords = if paramCount() == 6:
      parseIndex(paramStr(6), "Record limit") else: 32
    try:
      result.scene = loadPlacementModelsFromIso(paramStr(2), paramStr(3),
        parseIndex(paramStr(4), "Outer section index"),
        parseIndex(paramStr(5), "Nested section index"), maxRecords)
      result.showPlacements = true
      echo "Loaded ", result.scene.placements.len,
        " placements with ", result.scene.models.len, " distinct models"
      echo "Experimental rotations: primary 16-bit fields map one full turn; " &
        "COM rotation fields are ignored"
    except CatchableError as error:
      quit("Could not load ISO placement preview: " & error.msg, 1)
    return
  if paramStr(1) == "--chunk":
    if paramCount() != 3:
      quit("Usage: main --chunk image.iso sm2-resource-path", 1)
    try:
      result.scene = loadStaticGeometryFromIso(paramStr(2), paramStr(3))
      result.showStaticGeometry = true
      echo "Loaded ", result.scene.models.len,
        " SM2 scenery mesh entries with section-0 transforms"
      echo "LOD entries and per-cell visibility culling are not implemented yet"
    except CatchableError as error:
      quit("Could not load ISO static-geometry preview: " & error.msg, 1)
    return
  if paramStr(1) == "--chunk-links":
    if paramCount() notin [3, 4, 5, 6, 7, 8]:
      quit("Usage: main --chunk-links image.iso sm2-resource-path " &
        "[depth [object|chunk [root-link-index]] " &
        "[all|static|placements [geometry-index]]]", 1)
    let maxDepth = if paramCount() >= 4:
      parseIndex(paramStr(4), "Chunk-link depth") else: 1
    if paramCount() == 5 and paramStr(5) notin ["object", "chunk"]:
      quit("Chunk-link matrix must be 'object' or 'chunk'", 1)
    if paramCount() >= 6 and paramStr(5) notin ["object", "chunk"]:
      quit("Chunk-link matrix must be 'object' or 'chunk'", 1)
    var selectedRootLink = -1
    var sceneMode = "all"
    if paramCount() == 6:
      if paramStr(6) in ["all", "static", "placements"]:
        sceneMode = paramStr(6)
      else:
        selectedRootLink = parseIndex(paramStr(6), "Root chunk-link index")
    elif paramCount() == 7:
      if paramStr(6) in ["all", "static", "placements"]:
        sceneMode = paramStr(6)
        result.selectedGeometryIndex = parseIndex(paramStr(7),
          "Scene geometry index")
      else:
        selectedRootLink = parseIndex(paramStr(6), "Root chunk-link index")
        sceneMode = paramStr(7)
    elif paramCount() == 8:
      selectedRootLink = parseIndex(paramStr(6), "Root chunk-link index")
      sceneMode = paramStr(7)
      result.selectedGeometryIndex = parseIndex(paramStr(8),
        "Scene geometry index")
    if sceneMode notin ["all", "static", "placements"]:
      quit("Chunk-link scene mode must be 'all', 'static', or 'placements'", 1)
    let matrixMode = if paramCount() >= 5: paramStr(5) else: "object"
    let useChunkMatrix = matrixMode == "chunk"
    try:
      result.scene = loadLinkedChunkGeometryFromIso(paramStr(2), paramStr(3),
        maxDepth, useChunkMatrix, selectedRootLink)
      result.showStaticGeometry = sceneMode != "placements"
      result.showPlacements = sceneMode != "static" and
        result.scene.placements.len > 0
      if sceneMode == "placements" and not result.showPlacements:
        raise newException(IOError, "Selected linked chunks have no placements")
      if result.selectedGeometryIndex >= 0 and sceneMode == "all":
        raise newException(ValueError,
          "Selecting scene geometry requires static or placements mode")
      var staticModelCount = 0
      for sceneModel in result.scene.models:
        if sceneModel.isStaticGeometry:
          inc staticModelCount
      if sceneMode == "placements" and
          result.selectedGeometryIndex >= result.scene.placements.len:
        raise newException(ValueError, "Placement index is out of range")
      if sceneMode == "static" and
          result.selectedGeometryIndex >= staticModelCount:
        raise newException(ValueError, "Static model index is out of range")
      if sceneMode != "all":
        fitSceneBounds(result.scene, result.showStaticGeometry,
          result.showPlacements,
          (if sceneMode == "static": result.selectedGeometryIndex else: -1),
          (if sceneMode == "placements": result.selectedGeometryIndex else: -1))
      echo "Loaded ", staticModelCount,
        " linked SM2 model items across up to ", maxDepth, " link levels"
      echo "Loaded ", result.scene.models.len - staticModelCount,
        " RM2 placement-model variants (deduplicated per resource)"
      echo "Loaded ", result.scene.placements.len,
        " linked RM2 object model instances"
      echo "Neighbor transforms use the experimental ",
        (if useChunkMatrix: "ChunkMatrix" else: "ObjectMatrix"),
        " interpretation"
      if selectedRootLink >= 0:
        echo "Following only root link ", selectedRootLink
      echo "Drawing linked-scene mode: ", sceneMode
      if result.selectedGeometryIndex >= 0:
        if sceneMode == "static":
          var staticModelIndex = 0
          for sceneModel in result.scene.models:
            if sceneModel.isStaticGeometry:
              if staticModelIndex == result.selectedGeometryIndex:
                echo "Selected static model ", staticModelIndex, ": ",
                  sceneModel.modelId, " from ", sceneModel.modelPath
                break
              inc staticModelIndex
        else:
          let placement = result.scene.placements[result.selectedGeometryIndex]
          let sceneModel = result.scene.models[placement.modelIndex]
          echo "Selected placement ", result.selectedGeometryIndex,
            ": instance ", placement.instanceId, ", object ",
            placement.objectId, ", model ", sceneModel.modelId, " from ",
            sceneModel.modelPath, " at ", placement.position
    except CatchableError as error:
      quit("Could not load ISO chunk-link preview: " & error.msg, 1)
    return
  if paramCount() == 3:
    let textureId = parseId(paramStr(3), "Texture ID")
    try:
      result.texture = loadTextureFromIso(paramStr(1), paramStr(2), textureId)
      result.showTexture = true
    except CatchableError as error:
      quit("Could not load ISO texture: " & error.msg, 1)
    return
  let useCandidateMaterialOrder = paramCount() in [5, 7] and
    paramStr(5) == "--candidate-material-order"
  let useSelectedSubmodel = (paramCount() == 6 and paramStr(5) == "--submodel") or
    (paramCount() == 7 and paramStr(6) == "--submodel")
  if (paramCount() notin [4, 5, 6, 7] or
      (paramCount() == 6 and not useSelectedSubmodel) or
      (paramCount() == 7 and not useSelectedSubmodel)) or
      paramStr(1) != "--model":
    quit("Usage: main [image.iso resource-path texture-id] | " &
      "main --model image.iso resource-path model-id [texture-id | " &
      "--candidate-material-order] [--submodel index] | " &
      "main --placements image.iso " &
      "resource-path outer-index nested-index [record-limit] | " &
      "main --chunk image.iso sm2-resource-path | " &
      "main --chunk-links image.iso sm2-resource-path " &
      "[depth [object|chunk [root-link-index]] " &
      "[all|static|placements [geometry-index]]]", 1)

  let modelId = parseId(paramStr(4), "Model ID")
  let selectedSubmodelIndex = if useSelectedSubmodel:
    parseIndex(paramStr(if paramCount() == 7: 7 else: 6), "Submodel index")
    else: -1
  try:
    result.model = loadModelFromIso(paramStr(2), paramStr(3), modelId)
    if selectedSubmodelIndex >= result.model.submodelCount:
      raise newException(ValueError, "Submodel index is out of range")
    result.selectedSubmodelIndex = selectedSubmodelIndex
    if useCandidateMaterialOrder:
      # The format reference does not confirm parallel list ordering; keep this
      # path opt-in so the candidate mapping can be inspected without assuming it.
      let links = findTexturesForModelFromIso(paramStr(2), paramStr(3), modelId)
      if links.len != result.model.submodelCount:
        raise newException(ValueError,
          "Experimental material-order preview requires one resolved " &
          "texture link per submodel")
      for submodelIndex, link in links:
        result.candidateTextures.add(loadTextureFromIso(paramStr(2),
          paramStr(3), link.textureId))
        echo "Experimental candidate: submodel ", submodelIndex,
          " -> material ", link.materialId, " -> texture ", link.textureId
      result.useCandidateMaterialOrder = true
      result.modelId = modelId
      result.showModel = true
      result.showTexture = true
      return

    var textureId: uint32
    if paramCount() in [5, 7] and not useCandidateMaterialOrder:
      textureId = parseId(paramStr(5), "Texture ID")
    else:
      let link = findTextureForModelFromIso(paramStr(2), paramStr(3), modelId)
      result.materialId = link.materialId
      textureId = link.textureId
      echo "Linked material ", link.materialId, " to texture ", link.textureId
    result.texture = loadTextureFromIso(paramStr(2), paramStr(3), textureId)
    result.modelId = modelId
    result.textureId = textureId
    result.showModel = true
    result.showTexture = true
  except CatchableError as error:
    quit("Could not load ISO model preview: " & error.msg, 1)

proc makeModelVertices(model: DecodedModel): seq[Vertex] =
  if model.vertices.len == 0:
    raise newException(ValueError, "Model has no decoded triangle vertices")

  var minimum = model.vertices[0].position
  var maximum = minimum
  for vertex in model.vertices:
    for axis in 0 .. 2:
      minimum[axis] = min(minimum[axis], vertex.position[axis])
      maximum[axis] = max(maximum[axis], vertex.position[axis])

  let center = [
    (minimum[0] + maximum[0]) * 0.5'f32,
    (minimum[1] + maximum[1]) * 0.5'f32,
    (minimum[2] + maximum[2]) * 0.5'f32
  ]
  let largestExtent = max(maximum[0] - minimum[0],
    max(maximum[1] - minimum[1], maximum[2] - minimum[2]))
  if largestExtent <= 0.0'f32:
    raise newException(ValueError, "Model has no spatial extent")
  let scale = 1.8'f32 / largestExtent

  result = newSeqOfCap[Vertex](model.vertices.len)
  for source in model.vertices:
    result.add(Vertex(
      position: [
        (source.position[0] - center[0]) * scale,
        (source.position[1] - center[1]) * scale,
        (source.position[2] - center[2]) * scale
      ],
      color: [
        float32(source.color[0]) / 255.0'f32,
        float32(source.color[1]) / 255.0'f32,
        float32(source.color[2]) / 255.0'f32
      ],
      texCoord: source.uv
    ))

proc makeSceneVertices(model: DecodedModel): seq[Vertex] =
  result = newSeqOfCap[Vertex](model.vertices.len)
  for source in model.vertices:
    result.add(Vertex(
      position: source.position,
      color: [
        float32(source.color[0]) / 255.0'f32,
        float32(source.color[1]) / 255.0'f32,
        float32(source.color[2]) / 255.0'f32
      ],
      texCoord: source.uv
    ))

proc modelBounds(model: DecodedModel): Bounds3 =
  var positions = newSeqOfCap[array[3, float32]](model.vertices.len)
  for vertex in model.vertices:
    positions.add(vertex.position)
  boundsOf(positions)

proc previewAngle(raw: uint16): float32 =
  float32(raw) * (2.0'f32 * PI.float32 / 65536.0'f32)

proc placementMatrix(placement: ScenePlacement,
    scene: ScenePreview): Mat4 =
  let rotateX = rotationMatrixX(previewAngle(placement.rotations[0]))
  let rotateY = rotationMatrixY(previewAngle(placement.rotations[2]))
  let rotateZ = rotationMatrixZ(previewAngle(placement.rotations[4]))
  let rotation = multiply(rotateZ, multiply(rotateY, rotateX))
  let localTransform = multiply(translationMatrix(
    placement.position[0], placement.position[1], placement.position[2]),
    rotation)
  let regionTransform = multiply(placement.chunkTransform, localTransform)
  let centerTransform = translationMatrix(-scene.center[0],
    -scene.center[1], -scene.center[2])
  multiply(centerTransform, regionTransform)

proc sceneFarPlane(camera: Camera, scene: ScenePreview): float32 =
  let halfX = (scene.maximum[0] - scene.minimum[0]) * 0.5'f32
  let halfY = (scene.maximum[1] - scene.minimum[1]) * 0.5'f32
  let halfZ = (scene.maximum[2] - scene.minimum[2]) * 0.5'f32
  let sceneRadius = sqrt(halfX * halfX + halfY * halfY + halfZ * halfZ)
  let cameraDistance = sqrt(camera.position.x * camera.position.x +
    camera.position.y * camera.position.y +
    camera.position.z * camera.position.z)
  # The scene is centered at the origin; this sphere encloses it from any view.
  max(100.0'f32, cameraDistance + sceneRadius + 1.0'f32)

proc compileShader(kind: GLenum, source: string): GLuint =
  result = glCreateShader(kind)

  var sourcePtr = source.cstring
  glShaderSource(result, 1, sourcePtr.addr, nil)
  glCompileShader(result)

  var success: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, success.addr)

  if success == 0:
    var log: array[1024, char]
    glGetShaderInfoLog(result, GLsizei(log.len), nil, cast[ptr GLchar](log.addr))
    echo "Shader compilation failed: ", cast[cstring](log.addr)
    glDeleteShader(result)
    system.quit(1)

proc keyDown(window: GLFWWindow, key: GLFWKey): bool =
  window.getKey(key) == GLFWPress

proc onScroll(window: GLFWWindow, xOffset, yOffset: float64) {.cdecl.} =
  discard window
  discard xOffset
  pendingScroll += yOffset

proc main() =
  let preview = loadPreviewAssets()
  if not glfwInit():
    system.quit("Failed to initialize GLFW", 1)

  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)

  let windowTitle = if preview.showStaticGeometry and preview.showPlacements:
    "crash-nimsanity - experimental linked chunk region"
  elif preview.showPlacements:
    "crash-nimsanity - experimental placement preview"
  elif preview.showStaticGeometry:
    "crash-nimsanity - experimental SM2 geometry preview"
  elif preview.showModel and preview.useCandidateMaterialOrder:
    "crash-nimsanity - candidate material preview"
  elif preview.showModel and preview.selectedSubmodelIndex >= 0:
    "crash-nimsanity - ISO submodel preview"
  elif preview.showModel:
    "crash-nimsanity - ISO model preview"
  elif preview.showTexture:
    "crash-nimsanity - ISO texture preview"
  else:
    "crash-nimsanity"
  let window = glfwCreateWindow(800, 600, windowTitle.cstring)
  if window == nil:
    glfwTerminate()
    system.quit("Failed to create window", 1)

  window.makeContextCurrent()
  if not glInit():
    window.destroyWindow()
    glfwTerminate()
    system.quit("Failed to initialize OpenGL", 1)

  echo "OpenGL version: ", $cast[cstring](glGetString(GL_VERSION))
  echo "GPU renderer: ", $cast[cstring](glGetString(GL_RENDERER))
  echo "GLSL version: ", $cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

  let vertexShader = compileShader(GL_VERTEX_SHADER, vertexShaderSource)
  let fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSource)
  let shaderProgram = glCreateProgram()
  glAttachShader(shaderProgram, vertexShader)
  glAttachShader(shaderProgram, fragmentShader)
  glLinkProgram(shaderProgram)

  var linked: GLint
  glGetProgramiv(shaderProgram, GL_LINK_STATUS, linked.addr)
  if linked == 0:
    var log: array[1024, char]
    glGetProgramInfoLog(shaderProgram, 1024, nil, cast[ptr GLchar](log.addr))
    echo "Shader linking failed: ", cast[cstring](log.addr)
    system.quit(1)

  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)

  let modelLocation = glGetUniformLocation(shaderProgram, "uModel")
  let viewLocation = glGetUniformLocation(shaderProgram, "uView")
  let projectionLocation = glGetUniformLocation(shaderProgram, "uProjection")
  let textureLocation = glGetUniformLocation(shaderProgram, "uTexture")
  let useTextureLocation = glGetUniformLocation(shaderProgram, "uUseTexture")
  let previewWhiteLocation = glGetUniformLocation(shaderProgram, "uPreviewWhite")
  var previewMesh: Mesh
  var sceneMeshes: seq[Mesh]
  var sceneTextures: seq[Texture2D]
  var sceneBounds: seq[Bounds3]
  if preview.showPlacements or preview.showStaticGeometry:
    for sceneModel in preview.scene.models:
      sceneMeshes.add(uploadMesh(makeSceneVertices(sceneModel.model)))
      sceneBounds.add(modelBounds(sceneModel.model))
      if sceneModel.hasTexture:
        sceneTextures.add(uploadTexture2D(sceneModel.texture))
      else:
        sceneTextures.add(Texture2D())
  elif preview.showModel:
    previewMesh = uploadMesh(makeModelVertices(preview.model))
  elif preview.showTexture:
    previewMesh = createTexturedQuadMesh()
  else:
    previewMesh = createCubeMesh()
  var previewTexture: Texture2D
  var candidateTextures: seq[Texture2D]
  if preview.useCandidateMaterialOrder:
    for decoded in preview.candidateTextures:
      candidateTextures.add(uploadTexture2D(decoded))
  elif preview.showTexture:
    previewTexture = uploadTexture2D(preview.texture)
  var camera = initCamera()
  if preview.showPlacements or preview.showStaticGeometry:
    let spanX = preview.scene.maximum[0] - preview.scene.minimum[0]
    let spanY = preview.scene.maximum[1] - preview.scene.minimum[1]
    let spanZ = preview.scene.maximum[2] - preview.scene.minimum[2]
    let centerX = (preview.scene.minimum[0] + preview.scene.maximum[0]) * 0.5'f32
    let centerY = (preview.scene.minimum[1] + preview.scene.maximum[1]) * 0.5'f32
    let centerZ = (preview.scene.minimum[2] + preview.scene.maximum[2]) * 0.5'f32
    let aspect = 800.0'f32 / 600.0'f32
    let halfHeight = max(spanY, spanX / aspect) * 0.5'f32
    let fitDistance = max(halfHeight / tan(22.5'f32 * PI.float32 / 180.0'f32),
      8.0'f32)
    camera.position = Vec3(x: centerX, y: centerY,
      z: centerZ + spanZ * 0.5'f32 + fitDistance + 2.0'f32)
  let fittedCamera = camera

  glEnable(GL_DEPTH_TEST)
  glfwSwapInterval(1)
  # Disabled mode hides and captures the cursor while the preview is active.
  window.setInputMode(GLFWCursorSpecial, GLFWCursorDisabled)
  discard window.setScrollCallback(onScroll)
  var previousCursorX, previousCursorY: float64
  window.getCursorPos(previousCursorX.addr, previousCursorY.addr)

  var lastWidth, lastHeight: int32 = -1
  var lastFrameTime = glfwGetTime()

  while not window.windowShouldClose:
    glfwPollEvents()

    if window.keyDown(GLFWKey.ESCAPE):
      window.setWindowShouldClose(true)
    if window.keyDown(GLFWKey.Home):
      camera = fittedCamera

    var width, height: int32
    # GLFW window dimensions can differ from framebuffer pixels on high-DPI displays.
    window.getFramebufferSize(width.addr, height.addr)
    if width != lastWidth or height != lastHeight:
      glViewport(0, 0, width, height)
      lastWidth = width
      lastHeight = height

    let currentTime = glfwGetTime()
    # Time-based movement keeps camera speed independent of the frame rate.
    let deltaTime = float32(currentTime - lastFrameTime)
    lastFrameTime = currentTime

    # WASD moves horizontally; R and F move vertically.
    var movement: Vec3
    if window.keyDown(GLFWKey.W): movement.z -= 1.0'f32
    if window.keyDown(GLFWKey.S): movement.z += 1.0'f32
    if window.keyDown(GLFWKey.A): movement.x -= 1.0'f32
    if window.keyDown(GLFWKey.D): movement.x += 1.0'f32
    if window.keyDown(GLFWKey.R): movement.y += 1.0'f32
    if window.keyDown(GLFWKey.F): movement.y -= 1.0'f32
    let speedMultiplier = if window.keyDown(GLFWKey.LeftShift) or
        window.keyDown(GLFWKey.RightShift): 5.0'f32 else: 1.0'f32
    camera.moveCamera(movement, deltaTime, speedMultiplier)
    camera.dollyCamera(float32(pendingScroll), speedMultiplier)
    pendingScroll = 0.0
    var cursorX, cursorY: float64
    window.getCursorPos(cursorX.addr, cursorY.addr)
    let mouseDeltaX = float32(cursorX - previousCursorX)
    let mouseDeltaY = float32(cursorY - previousCursorY)
    camera.rotateCamera(-mouseDeltaX * MouseLookSensitivity,
      -mouseDeltaY * MouseLookSensitivity)
    previousCursorX = cursorX
    previousCursorY = cursorY

    glClearColor(0.12'f32, 0.14'f32, 0.18'f32, 1.0'f32)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    glUseProgram(shaderProgram)
    glUniform1i(previewWhiteLocation, GLint(PreviewWhiteUniformValue))
    let time = float32(currentTime)
    # The shader applies transforms in model, view, then projection order.
    let model = if preview.showTexture and not preview.showModel:
      identityMatrix()
    else:
      multiply(rotationMatrixY(time * 0.7'f32), rotationMatrixX(time * 0.5'f32))
    let view = camera.viewMatrix()
    let aspect = if width > 0 and height > 0: float32(width) / float32(height) else: 1.0'f32
    let projectionFar = if preview.showPlacements or preview.showStaticGeometry:
      sceneFarPlane(camera, preview.scene)
    else:
      100.0'f32
    let projection = perspectiveMatrix(45.0'f32 * PI.float32 / 180.0'f32,
      aspect, 0.1'f32, projectionFar)
    let viewProjection = multiply(projection, view)

    glUniformMatrix4fv(viewLocation, 1, GLboolean(0), view[0].addr)
    glUniformMatrix4fv(projectionLocation, 1, GLboolean(0), projection[0].addr)
    let useTexture = preview.showTexture or preview.showPlacements or
      preview.showStaticGeometry
    glUniform1i(useTextureLocation, GLint(if useTexture: 1 else: 0))
    if useTexture:
      glUniform1i(textureLocation, 0)
    if preview.showPlacements:
      for placementIndex, placement in preview.scene.placements:
        if not preview.showStaticGeometry and preview.selectedGeometryIndex >= 0 and
            placementIndex != preview.selectedGeometryIndex:
          continue
        let transform = placementMatrix(placement, preview.scene)
        if outsideClipFrustum(multiply(viewProjection, transform),
            sceneBounds[placement.modelIndex]):
          continue
        glUniformMatrix4fv(modelLocation, 1, GLboolean(0), transform[0].addr)
        let sceneModel = preview.scene.models[placement.modelIndex]
        glUniform1i(useTextureLocation,
          GLint(if sceneModel.hasTexture: 1 else: 0))
        if sceneModel.hasTexture:
          sceneTextures[placement.modelIndex].bindTexture()
        sceneMeshes[placement.modelIndex].draw()
    if preview.showStaticGeometry:
      let centerTransform = translationMatrix(-preview.scene.center[0],
        -preview.scene.center[1], -preview.scene.center[2])
      var staticModelIndex = 0
      for modelIndex in 0 ..< preview.scene.models.len:
        let sceneModel = preview.scene.models[modelIndex]
        if not sceneModel.isStaticGeometry:
          continue
        if preview.selectedGeometryIndex >= 0 and
            staticModelIndex != preview.selectedGeometryIndex:
          inc staticModelIndex
          continue
        inc staticModelIndex
        let transform = multiply(centerTransform,
          sceneModel.modelTransform)
        if outsideClipFrustum(multiply(viewProjection, transform),
            sceneBounds[modelIndex]):
          continue
        glUniformMatrix4fv(modelLocation, 1, GLboolean(0), transform[0].addr)
        glUniform1i(useTextureLocation,
          GLint(if sceneModel.hasTexture: 1 else: 0))
        if sceneModel.hasTexture:
          sceneTextures[modelIndex].bindTexture()
        sceneMeshes[modelIndex].draw()
    else:
      glUniformMatrix4fv(modelLocation, 1, GLboolean(0), model[0].addr)
    if not preview.showPlacements and not preview.showStaticGeometry and
        preview.showTexture:
      glUniform1i(textureLocation, 0)
      if preview.useCandidateMaterialOrder:
        if preview.selectedSubmodelIndex >= 0:
          let submodelIndex = preview.selectedSubmodelIndex
          candidateTextures[submodelIndex].bindTexture()
          previewMesh.drawRange(
            preview.model.submodelTriangleVertexOffsets[submodelIndex],
            preview.model.submodelTriangleCounts[submodelIndex] * 3
          )
        else:
          for submodelIndex, texture in candidateTextures:
            texture.bindTexture()
            previewMesh.drawRange(
              preview.model.submodelTriangleVertexOffsets[submodelIndex],
              preview.model.submodelTriangleCounts[submodelIndex] * 3
            )
      else:
        previewTexture.bindTexture()
        if preview.selectedSubmodelIndex >= 0:
          let submodelIndex = preview.selectedSubmodelIndex
          previewMesh.drawRange(
            preview.model.submodelTriangleVertexOffsets[submodelIndex],
            preview.model.submodelTriangleCounts[submodelIndex] * 3
          )
        else:
          previewMesh.draw()
    elif not preview.showPlacements and not preview.showStaticGeometry:
      previewMesh.draw()

    window.swapBuffers()

  # Restore normal cursor behavior before destroying the GLFW window.
  window.setInputMode(GLFWCursorSpecial, GLFWCursorNormal)

  if not preview.showPlacements and not preview.showStaticGeometry:
    previewMesh.destroy()
  previewTexture.destroy()
  for texture in candidateTextures.mitems:
    texture.destroy()
  for mesh in sceneMeshes.mitems:
    mesh.destroy()
  for texture in sceneTextures.mitems:
    texture.destroy()
  glDeleteProgram(shaderProgram)
  window.destroyWindow()
  glfwTerminate()

when isMainModule:
  main()
