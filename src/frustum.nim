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
import math3d

type Bounds3* = object
  minimum*: array[3, float32]
  maximum*: array[3, float32]

proc boundsOf*(positions: openArray[array[3, float32]]): Bounds3 =
  if positions.len == 0:
    return
  result.minimum = positions[0]
  result.maximum = positions[0]
  for position in positions:
    for axis in 0 .. 2:
      result.minimum[axis] = min(result.minimum[axis], position[axis])
      result.maximum[axis] = max(result.maximum[axis], position[axis])

proc outsideClipFrustum*(transform: Mat4, bounds: Bounds3): bool =
  var outside = [true, true, true, true, true, true]
  for corner in 0 .. 7:
    let x = if (corner and 1) == 0: bounds.minimum[0] else: bounds.maximum[0]
    let y = if (corner and 2) == 0: bounds.minimum[1] else: bounds.maximum[1]
    let z = if (corner and 4) == 0: bounds.minimum[2] else: bounds.maximum[2]
    let clipX = transform[0] * x + transform[4] * y +
      transform[8] * z + transform[12]
    let clipY = transform[1] * x + transform[5] * y +
      transform[9] * z + transform[13]
    let clipZ = transform[2] * x + transform[6] * y +
      transform[10] * z + transform[14]
    let clipW = transform[3] * x + transform[7] * y +
      transform[11] * z + transform[15]

    # Keep an item if its box reaches any part of all six clip-space planes.
    if clipX >= -clipW: outside[0] = false
    if clipX <= clipW: outside[1] = false
    if clipY >= -clipW: outside[2] = false
    if clipY <= clipW: outside[3] = false
    if clipZ >= -clipW: outside[4] = false
    if clipZ <= clipW: outside[5] = false
  for planeOutside in outside:
    if planeOutside:
      return true
