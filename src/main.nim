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
import iso_model
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

out vec4 fragColor;

void main() {
    if (uUseTexture != 0) {
        fragColor = texture(uTexture, textureCoord) * vec4(vertexColor, 1.0);
    } else {
        fragColor = vec4(vertexColor, 1.0);
    }
}
"""

type PreviewAssets = object
  showTexture: bool
  showModel: bool
  modelId: uint32
  materialId: uint32
  textureId: uint32
  texture: DecodedTexture
  model: DecodedModel

proc parseId(argument, label: string): uint32 =
  try:
    let parsed = parseBiggestUInt(argument)
    if parsed > uint64(high(uint32)):
      quit(label & " must fit in 32 bits", 1)
    result = uint32(parsed)
  except ValueError:
    quit(label & " must be an unsigned integer", 1)

proc loadPreviewAssets(): PreviewAssets =
  if paramCount() == 0:
    return
  if paramCount() == 3:
    let textureId = parseId(paramStr(3), "Texture ID")
    try:
      result.texture = loadTextureFromIso(paramStr(1), paramStr(2), textureId)
      result.showTexture = true
    except CatchableError as error:
      quit("Could not load ISO texture: " & error.msg, 1)
    return
  if paramCount() notin [4, 5] or paramStr(1) != "--model":
    quit("Usage: main [image.iso resource-path texture-id] | " &
      "main --model image.iso resource-path model-id [texture-id]", 1)

  let modelId = parseId(paramStr(4), "Model ID")
  try:
    result.model = loadModelFromIso(paramStr(2), paramStr(3), modelId)
    var textureId: uint32
    if paramCount() == 5:
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

proc main() =
  let preview = loadPreviewAssets()
  if not glfwInit():
    system.quit("Failed to initialize GLFW", 1)

  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)

  let windowTitle = if preview.showModel:
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
  var previewMesh: Mesh
  if preview.showModel:
    previewMesh = uploadMesh(makeModelVertices(preview.model))
  elif preview.showTexture:
    previewMesh = createTexturedQuadMesh()
  else:
    previewMesh = createCubeMesh()
  var previewTexture: Texture2D
  if preview.showTexture:
    previewTexture = uploadTexture2D(preview.texture)
  var camera = initCamera()

  glEnable(GL_DEPTH_TEST)
  glfwSwapInterval(1)

  var lastWidth, lastHeight: int32 = -1
  var lastFrameTime = glfwGetTime()

  while not window.windowShouldClose:
    glfwPollEvents()

    if window.keyDown(GLFWKey.ESCAPE):
      window.setWindowShouldClose(true)

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
    camera.moveCamera(movement, deltaTime)

    glClearColor(0.12'f32, 0.14'f32, 0.18'f32, 1.0'f32)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    glUseProgram(shaderProgram)
    let time = float32(currentTime)
    # The shader applies transforms in model, view, then projection order.
    let model = if preview.showTexture and not preview.showModel:
      identityMatrix()
    else:
      multiply(rotationMatrixY(time * 0.7'f32), rotationMatrixX(time * 0.5'f32))
    let view = camera.viewMatrix()
    let aspect = if width > 0 and height > 0: float32(width) / float32(height) else: 1.0'f32
    let projection = perspectiveMatrix(45.0'f32 * PI.float32 / 180.0'f32, aspect, 0.1'f32, 100.0'f32)

    glUniformMatrix4fv(modelLocation, 1, GLboolean(0), model[0].addr)
    glUniformMatrix4fv(viewLocation, 1, GLboolean(0), view[0].addr)
    glUniformMatrix4fv(projectionLocation, 1, GLboolean(0), projection[0].addr)
    glUniform1i(useTextureLocation, GLint(if preview.showTexture: 1 else: 0))
    if preview.showTexture:
      glUniform1i(textureLocation, 0)
      previewTexture.bindTexture()
    previewMesh.draw()

    window.swapBuffers()

  previewMesh.destroy()
  previewTexture.destroy()
  glDeleteProgram(shaderProgram)
  window.destroyWindow()
  glfwTerminate()

when isMainModule:
  main()
