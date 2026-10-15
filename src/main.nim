import nimgl/[glfw, opengl]

const GlFloatEnum = GLenum(0x1406)

const vertexShaderSource = """
#version 330 core

layout (location = 0) in vec3 aPosition;
layout (location = 1) in vec3 aColor;

out vec3 vertexColor;

void main() {
    gl_Position = vec4(aPosition, 1.0);
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

    # Each vertex stores its position followed by its RGB color.
    var vertices: array[18, float32] = [
         0.0'f32,  0.5'f32, 0.0'f32, 1.0'f32, 0.2'f32, 0.2'f32,
        -0.5'f32, -0.5'f32, 0.0'f32, 0.2'f32, 1.0'f32, 0.2'f32,
         0.5'f32, -0.5'f32, 0.0'f32, 0.2'f32, 0.2'f32, 1.0'f32
    ]

    # create vertex array and buffer
    var vao, vbo: GLuint

    glGenVertexArrays(1, vao.addr)
    glGenBuffers(1, vbo.addr)

    glBindVertexArray(vao)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)

    glBufferData(
        GL_ARRAY_BUFFER,
        sizeof(vertices),
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
        glClear(GL_COLOR_BUFFER_BIT)

        # render triangle
        glUseProgram(shaderProgram)
        glBindVertexArray(vao)

        glDrawArrays(GL_TRIANGLES, 0, 3)

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
