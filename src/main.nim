import std/math
import nimgl/[glfw, opengl]

const GlFloatEnum = GLenum(0x1406)

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

type Mat4 = array[16, float32]

proc multiply(a, b: Mat4): Mat4 =
    # Matrices use OpenGL's column-major storage convention.
    for column in 0 .. 3:
        for row in 0 .. 3:
            for i in 0 .. 3:
                result[column * 4 + row] += a[i * 4 + row] * b[column * 4 + i]

proc rotationMatrixX(angle: float32): Mat4 =
    let c = cos(angle)
    let s = sin(angle)

    result = [
        1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
        0.0'f32, c,        s,        0.0'f32,
        0.0'f32, -s,       c,        0.0'f32,
        0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32
    ]

proc rotationMatrixY(angle: float32): Mat4 =
    let c = cos(angle)
    let s = sin(angle)

    result = [
        c,        0.0'f32, -s,       0.0'f32,
        0.0'f32, 1.0'f32, 0.0'f32, 0.0'f32,
        s,        0.0'f32, c,        0.0'f32,
        0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32
    ]

proc translationMatrix(x, y, z: float32): Mat4 =
    result = [
        1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
        0.0'f32, 1.0'f32, 0.0'f32, 0.0'f32,
        0.0'f32, 0.0'f32, 1.0'f32, 0.0'f32,
        x,        y,        z,        1.0'f32
    ]

proc perspectiveMatrix(fovRadians, aspect, nearPlane, farPlane: float32): Mat4 =
    let f = 1.0'f32 / tan(fovRadians / 2.0'f32)

    result = [
        f / aspect, 0.0'f32, 0.0'f32, 0.0'f32,
        0.0'f32, f, 0.0'f32, 0.0'f32,
        0.0'f32, 0.0'f32,
        (farPlane + nearPlane) / (nearPlane - farPlane), -1.0'f32,
        0.0'f32, 0.0'f32,
        (2.0'f32 * farPlane * nearPlane) / (nearPlane - farPlane), 0.0'f32
    ]

proc addVertex(vertices: var seq[float32], position, color: array[3, float32]) =
    for value in position:
        vertices.add(value)
    for value in color:
        vertices.add(value)

proc addTriangle(vertices: var seq[float32], a, b, c: array[3, float32], color: array[3, float32]) =
    vertices.addVertex(a, color)
    vertices.addVertex(b, color)
    vertices.addVertex(c, color)

proc addFace(vertices: var seq[float32], a, b, c, d: array[3, float32], color: array[3, float32]) =
    vertices.addTriangle(a, b, c, color)
    vertices.addTriangle(a, c, d, color)

proc cubeVertices(): seq[float32] =
    const p = 0.5'f32

    result = newSeqOfCap[float32](36 * 6)

    result.addFace([-p, -p, p], [p, -p, p], [p, p, p], [-p, p, p], [1.0'f32, 0.3'f32, 0.2'f32])
    result.addFace([p, -p, -p], [-p, -p, -p], [-p, p, -p], [p, p, -p], [0.2'f32, 0.4'f32, 1.0'f32])
    result.addFace([-p, -p, -p], [-p, -p, p], [-p, p, p], [-p, p, -p], [0.3'f32, 1.0'f32, 0.4'f32])
    result.addFace([p, -p, p], [p, -p, -p], [p, p, -p], [p, p, p], [1.0'f32, 0.8'f32, 0.2'f32])
    result.addFace([-p, p, p], [p, p, p], [p, p, -p], [-p, p, -p], [0.8'f32, 0.3'f32, 1.0'f32])
    result.addFace([-p, -p, -p], [p, -p, -p], [p, -p, p], [-p, -p, p], [0.2'f32, 0.9'f32, 1.0'f32])

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
        echo "Shader compiation failed: ", cast[cstring](log.addr)
        glDeleteShader(result)
        system.quit(1)

proc main() =
    # init glfw
    if not glfwInit():
        system.quit("Failed to initialize GLFW", 1)

    # request gl 3.3 core
    glfwWindowHint(GLFWContextVersionMajor, 3)
    glfwWindowHint(GLFWContextVersionMinor, 3)
    glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
    glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)

    # create window
    let window = glfwCreateWindow(800, 600, "crash-nimsanity")

    if window == nil:
        glfwTerminate()
        system.quit("Failed to create window", 1)

    window.makeContextCurrent()

    # init opengl
    if not glInit():
        window.destroyWindow()
        glfwTerminate()
        system.quit("Failed to initialize OpenGL", 1)

    echo "OpenGL version: ", $cast[cstring](glGetString(GL_VERSION))
    echo "GPU renderer: ", $cast[cstring](glGetString(GL_RENDERER))
    echo "GLSL version: ", $cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

    # compile shaders
    let vertexShader = compileShader(GL_VERTEX_SHADER, vertexShaderSource)
    let fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSource)

    # create shader program
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

    # delete individual shaders after linking
    glDeleteShader(vertexShader)
    glDeleteShader(fragmentShader)

    let modelLocation = glGetUniformLocation(shaderProgram, "uModel")
    let viewLocation = glGetUniformLocation(shaderProgram, "uView")
    let projectionLocation = glGetUniformLocation(shaderProgram, "uProjection")

    # Enable depth testing so nearer cube faces cover farther faces.
    glEnable(GL_DEPTH_TEST)

    let vertices = cubeVertices()

    # create vertex array and buffer
    var vao, vbo: GLuint

    glGenVertexArrays(1, vao.addr)
    glGenBuffers(1, vbo.addr)

    glBindVertexArray(vao)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)

    glBufferData(
        GL_ARRAY_BUFFER,
        vertices.len * sizeof(float32),
        vertices[0].addr,
        GL_STATIC_DRAW
    )

    # describe the vertex layout
    glVertexAttribPointer(
        0, 3, GlFloatEnum, GLboolean(0),
        6 * sizeof(float32), nil
    )
    glEnableVertexAttribArray(0)

    glVertexAttribPointer(
        1, 3, GlFloatEnum, GLboolean(0),
        6 * sizeof(float32), cast[pointer](3 * sizeof(float32))
    )
    glEnableVertexAttribArray(1)

    glBindBuffer(GL_ARRAY_BUFFER, 0)
    glBindVertexArray(0)

    # enable vsync
    glfwSwapInterval(1)

    var lastWidth, lastHeight: int32 = -1

    # main loop
    while not window.windowShouldClose:
        glfwPollEvents()

        # close when esc is pressed
        if window.getKey(GLFWKey.ESCAPE) == GLFWPress:
            window.setWindowShouldClose(true)


        # update the viewport when framebuffer dimensions change
        var width, height: int32
        window.getFramebufferSize(width.addr, height.addr)

        if width != lastWidth or height != lastHeight:
            glViewport(0, 0, width, height)
            lastWidth = width
            lastHeight = height


        # clear the framebuffer
        glClearColor(0.12'f32, 0.14'f32, 0.18'f32, 1.0'f32)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

        # Render a rotating cube through model, view, and perspective matrices.
        glUseProgram(shaderProgram)
        let time = float32(glfwGetTime())
        let model = multiply(rotationMatrixY(time * 0.7'f32), rotationMatrixX(time * 0.5'f32))
        let view = translationMatrix(0.0'f32, 0.0'f32, -3.0'f32)
        let aspect = if width > 0 and height > 0: float32(width) / float32(height) else: 1.0'f32
        let projection = perspectiveMatrix(45.0'f32 * PI.float32 / 180.0'f32, aspect, 0.1'f32, 100.0'f32)

        glUniformMatrix4fv(modelLocation, 1, GLboolean(0), model[0].addr)
        glUniformMatrix4fv(viewLocation, 1, GLboolean(0), view[0].addr)
        glUniformMatrix4fv(projectionLocation, 1, GLboolean(0), projection[0].addr)
        glBindVertexArray(vao)

        glDrawArrays(GL_TRIANGLES, 0, 36)

        window.swapBuffers()

    # release opengl resources
    glDeleteVertexArrays(1, vao.addr)
    glDeleteBuffers(1, vbo.addr)
    glDeleteProgram(shaderProgram)

    # cleanup
    window.destroyWindow()
    glfwTerminate()

when isMainModule:
    main()
