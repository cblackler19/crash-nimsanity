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
import nimgl/opengl

const GlFloatEnum = GLenum(0x1406)

type
  # Position and RGB color are stored consecutively for one interleaved GPU buffer.
  Vertex* = object
    position*: array[3, float32]
    color*: array[3, float32]
    texCoord*: array[2, float32]

  Mesh* = object
    vao: GLuint
    vbo: GLuint
    vertexCount: GLsizei

proc addTriangle(vertices: var seq[Vertex], a, b, c: array[3, float32], color: array[3, float32]) =
  vertices.add(Vertex(position: a, color: color))
  vertices.add(Vertex(position: b, color: color))
  vertices.add(Vertex(position: c, color: color))

proc addFace(vertices: var seq[Vertex], a, b, c, d: array[3, float32], color: array[3, float32]) =
  vertices.addTriangle(a, b, c, color)
  vertices.addTriangle(a, c, d, color)

proc cubeVertices(): seq[Vertex] =
  const p = 0.5'f32

  # Expand each square face into two triangles; this keeps per-face colors independent.
  result = newSeqOfCap[Vertex](36)
  result.addFace([-p, -p, p], [p, -p, p], [p, p, p], [-p, p, p], [1.0'f32, 0.3'f32, 0.2'f32])
  result.addFace([p, -p, -p], [-p, -p, -p], [-p, p, -p], [p, p, -p], [0.2'f32, 0.4'f32, 1.0'f32])
  result.addFace([-p, -p, -p], [-p, -p, p], [-p, p, p], [-p, p, -p], [0.3'f32, 1.0'f32, 0.4'f32])
  result.addFace([p, -p, p], [p, -p, -p], [p, p, -p], [p, p, p], [1.0'f32, 0.8'f32, 0.2'f32])
  result.addFace([-p, p, p], [p, p, p], [p, p, -p], [-p, p, -p], [0.8'f32, 0.3'f32, 1.0'f32])
  result.addFace([-p, -p, -p], [p, -p, -p], [p, -p, p], [-p, -p, p], [0.2'f32, 0.9'f32, 1.0'f32])

proc uploadMesh*(vertices: openArray[Vertex]): Mesh =
  if vertices.len == 0:
    return

  result.vertexCount = GLsizei(vertices.len)
  glGenVertexArrays(1, result.vao.addr)
  glGenBuffers(1, result.vbo.addr)

  glBindVertexArray(result.vao)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(
    GL_ARRAY_BUFFER,
    vertices.len * sizeof(Vertex),
    unsafeAddr vertices[0],
    GL_STATIC_DRAW
  )

  # Both attributes share the Vertex stride; color begins after three position floats.
  glVertexAttribPointer(0, 3, GlFloatEnum, GLboolean(0), GLsizei(sizeof(Vertex)), nil)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(
    1, 3, GlFloatEnum, GLboolean(0), GLsizei(sizeof(Vertex)),
    cast[pointer](3 * sizeof(float32))
  )
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(
    2, 2, GlFloatEnum, GLboolean(0), GLsizei(sizeof(Vertex)),
    cast[pointer](6 * sizeof(float32))
  )
  glEnableVertexAttribArray(2)

  glBindBuffer(GL_ARRAY_BUFFER, 0)
  glBindVertexArray(0)

proc createCubeMesh*(): Mesh =
  let vertices = cubeVertices()
  result = uploadMesh(vertices)

proc createTexturedQuadMesh*(): Mesh =
  let white = [1.0'f32, 1.0'f32, 1.0'f32]
  let lowerLeft = Vertex(position: [-1.0'f32, -1.0'f32, 0.0'f32],
    color: white, texCoord: [0.0'f32, 0.0'f32])
  let lowerRight = Vertex(position: [1.0'f32, -1.0'f32, 0.0'f32],
    color: white, texCoord: [1.0'f32, 0.0'f32])
  let upperRight = Vertex(position: [1.0'f32, 1.0'f32, 0.0'f32],
    color: white, texCoord: [1.0'f32, 1.0'f32])
  let upperLeft = Vertex(position: [-1.0'f32, 1.0'f32, 0.0'f32],
    color: white, texCoord: [0.0'f32, 1.0'f32])
  result = uploadMesh([lowerLeft, lowerRight, upperRight,
    lowerLeft, upperRight, upperLeft])

proc draw*(mesh: Mesh) =
  if mesh.vertexCount == 0:
    return

  glBindVertexArray(mesh.vao)
  glDrawArrays(GL_TRIANGLES, 0, mesh.vertexCount)

proc destroy*(mesh: var Mesh) =
  # Release the GPU objects owned by this mesh while its OpenGL context is alive.
  glDeleteVertexArrays(1, mesh.vao.addr)
  glDeleteBuffers(1, mesh.vbo.addr)
