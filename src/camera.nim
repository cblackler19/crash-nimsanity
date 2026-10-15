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
import math3d

type Camera* = object
  position*: Vec3
  yaw*: float32
  pitch*: float32

const CameraMoveSpeed = 2.5'f32

proc initCamera*(): Camera =
  result.position = Vec3(x: 0.0'f32, y: 0.0'f32, z: 3.0'f32)

proc moveCamera*(camera: var Camera, direction: Vec3, deltaTime: float32) =
  # Horizontal input follows camera yaw while vertical input stays world-aligned.
  let cosine = cos(camera.yaw)
  let sine = sin(camera.yaw)
  let relativeDirection = Vec3(
    x: direction.x * cosine + direction.z * sine,
    y: direction.y,
    z: -direction.x * sine + direction.z * cosine
  )
  let length = sqrt(relativeDirection.x * relativeDirection.x +
    relativeDirection.y * relativeDirection.y +
    relativeDirection.z * relativeDirection.z)
  if length <= 0.0'f32:
    return

  # Scale by the input length so diagonal movement is no faster than straight movement.
  let distance = CameraMoveSpeed * deltaTime / length
  camera.position.x += relativeDirection.x * distance
  camera.position.y += relativeDirection.y * distance
  camera.position.z += relativeDirection.z * distance

proc rotateCamera*(camera: var Camera, yawDelta, pitchDelta: float32) =
  camera.yaw += yawDelta
  let pitchLimit = PI.float32 * 0.5'f32 - 0.05'f32
  camera.pitch = max(-pitchLimit, min(pitchLimit, camera.pitch + pitchDelta))

proc viewMatrix*(camera: Camera): Mat4 =
  let orientation = multiply(rotationMatrixX(-camera.pitch),
    rotationMatrixY(-camera.yaw))
  let translation = translationMatrix(-camera.position.x,
    -camera.position.y, -camera.position.z)
  multiply(orientation, translation)
