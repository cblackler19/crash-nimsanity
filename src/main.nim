import std/math
import nimgl/[glfw, opengl]

import camera
import math3d
import mesh

const vertexShaderSource = """
#version 330 core

layout (location = 0) in vec3 aPosition;
layout (location = 1) in vec3 aColor;
uniform mat4 uModel;
uniform mat4 uView;
uniform mat4 uProjection;

out vec3 vertexColor;

void main() {
    gl_Position = uProjection * uView * uModel * vec4(aPosition, 1.0);
    vertexColor = aColor;
}
"""

const fragmentShaderSource = """
#version 330 core

in vec3 vertexColor;

out vec4 fragColor;

void main() {
    fragColor = vec4(vertexColor, 1.0);
}
"""

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
  if not glfwInit():
    system.quit("Failed to initialize GLFW", 1)

  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)

  let window = glfwCreateWindow(800, 600, "crash-nimsanity")
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
  var cube = createCubeMesh()
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
    let model = multiply(rotationMatrixY(time * 0.7'f32), rotationMatrixX(time * 0.5'f32))
    let view = camera.viewMatrix()
    let aspect = if width > 0 and height > 0: float32(width) / float32(height) else: 1.0'f32
    let projection = perspectiveMatrix(45.0'f32 * PI.float32 / 180.0'f32, aspect, 0.1'f32, 100.0'f32)

    glUniformMatrix4fv(modelLocation, 1, GLboolean(0), model[0].addr)
    glUniformMatrix4fv(viewLocation, 1, GLboolean(0), view[0].addr)
    glUniformMatrix4fv(projectionLocation, 1, GLboolean(0), projection[0].addr)
    cube.draw()

    window.swapBuffers()

  cube.destroy()
  glDeleteProgram(shaderProgram)
  window.destroyWindow()
  glfwTerminate()

when isMainModule:
  main()
