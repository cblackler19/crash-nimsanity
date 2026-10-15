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

import ps2_texture

type Texture2D* = object
  handle: GLuint

proc uploadLevel(level, width, height: int, pixels: openArray[uint8]) =
  if pixels.len != width * height * 4:
    raise newException(ValueError, "RGBA mip data does not match its dimensions")
  glTexImage2D(
    GL_TEXTURE_2D,
    GLint(level),
    GLint(GL_RGBA8),
    GLsizei(width),
    GLsizei(height),
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    unsafeAddr pixels[0]
  )

proc uploadTexture2D*(decoded: DecodedTexture): Texture2D =
  if decoded.width <= 0 or decoded.height <= 0 or decoded.rgba.len == 0:
    raise newException(ValueError, "Decoded texture has no base image")

  glGenTextures(1, result.handle.addr)
  glBindTexture(GL_TEXTURE_2D, result.handle)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_REPEAT))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_REPEAT))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
    GLint(GL_LINEAR_MIPMAP_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL,
    GLint(decoded.mipLevels.len))

  uploadLevel(0, decoded.width, decoded.height, decoded.rgba)
  for level, mip in decoded.mipLevels:
    uploadLevel(level + 1, mip.width, mip.height, mip.rgba)
  glBindTexture(GL_TEXTURE_2D, 0)

proc bindTexture*(texture: Texture2D) =
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, texture.handle)

proc destroy*(texture: var Texture2D) =
  if texture.handle != 0:
    glDeleteTextures(1, texture.handle.addr)
    texture.handle = 0
