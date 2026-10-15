import std/math
import math3d

type Camera* = object
  position*: Vec3

const CameraMoveSpeed = 2.5'f32

proc initCamera*(): Camera =
  result.position = Vec3(x: 0.0'f32, y: 0.0'f32, z: 3.0'f32)

proc moveCamera*(camera: var Camera, direction: Vec3, deltaTime: float32) =
  let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
  if length <= 0.0'f32:
    return

  let distance = CameraMoveSpeed * deltaTime / length
  camera.position.x += direction.x * distance
  camera.position.y += direction.y * distance
  camera.position.z += direction.z * distance

proc viewMatrix*(camera: Camera): Mat4 =
  translationMatrix(-camera.position.x, -camera.position.y, -camera.position.z)
