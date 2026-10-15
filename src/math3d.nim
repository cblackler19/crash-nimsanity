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
import std/math

type
  Vec3* = object
    x*, y*, z*: float32

  Mat4* = array[16, float32]

proc multiply*(a, b: Mat4): Mat4 =
  # Matrices use OpenGL's column-major storage convention.
  # Each output cell is the dot product of a row from `a` and a column from `b`.
  for column in 0 .. 3:
    for row in 0 .. 3:
      for i in 0 .. 3:
        result[column * 4 + row] += a[i * 4 + row] * b[column * 4 + i]

proc rotationMatrixX*(angle: float32): Mat4 =
  let c = cos(angle)
  let s = sin(angle)

  result = [
    1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
    0.0'f32, c,        s,        0.0'f32,
    0.0'f32, -s,       c,        0.0'f32,
    0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32
  ]

proc rotationMatrixY*(angle: float32): Mat4 =
  let c = cos(angle)
  let s = sin(angle)

  result = [
    c,        0.0'f32, -s,       0.0'f32,
    0.0'f32, 1.0'f32, 0.0'f32, 0.0'f32,
    s,        0.0'f32, c,        0.0'f32,
    0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32
  ]

proc translationMatrix*(x, y, z: float32): Mat4 =
  result = [
    1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
    0.0'f32, 1.0'f32, 0.0'f32, 0.0'f32,
    0.0'f32, 0.0'f32, 1.0'f32, 0.0'f32,
    x,        y,        z,        1.0'f32
  ]

proc perspectiveMatrix*(fovRadians, aspect, nearPlane, farPlane: float32): Mat4 =
  let f = 1.0'f32 / tan(fovRadians / 2.0'f32)

  # This projection maps the near/far planes into OpenGL's -1..1 clip-space depth.
  result = [
    f / aspect, 0.0'f32, 0.0'f32, 0.0'f32,
    0.0'f32, f, 0.0'f32, 0.0'f32,
    0.0'f32, 0.0'f32,
    (farPlane + nearPlane) / (nearPlane - farPlane), -1.0'f32,
    0.0'f32, 0.0'f32,
    (2.0'f32 * farPlane * nearPlane) / (nearPlane - farPlane), 0.0'f32
  ]
