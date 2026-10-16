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

import std/[math, os, strutils]

import iso_scene
import math3d

type Bounds = object
  minimum: array[3, float32]
  maximum: array[3, float32]
  vertexCount: int

proc transformPoint(matrix: Mat4, position: array[3, float32]): array[3, float32] =
  for row in 0 .. 2:
    result[row] = matrix[row] * position[0] + matrix[4 + row] * position[1] +
      matrix[8 + row] * position[2] + matrix[12 + row]

proc placementTransform(placement: ScenePlacement): Mat4 =
  let angleScale = 2.0'f32 * PI.float32 / 65536.0'f32
  let rotateX = rotationMatrixX(float32(placement.rotations[0]) * angleScale)
  let rotateY = rotationMatrixY(float32(placement.rotations[2]) * angleScale)
  let rotateZ = rotationMatrixZ(float32(placement.rotations[4]) * angleScale)
  let rotation = multiply(rotateZ, multiply(rotateY, rotateX))
  let translation = translationMatrix(placement.position[0],
    placement.position[1], placement.position[2])
  multiply(placement.chunkTransform, multiply(translation, rotation))

proc measure(model: SceneModel, transform: Mat4): Bounds =
  for vertex in model.model.vertices:
    let point = transformPoint(transform, vertex.position)
    if result.vertexCount == 0:
      result.minimum = point
      result.maximum = point
    else:
      for axis in 0 .. 2:
        result.minimum[axis] = min(result.minimum[axis], point[axis])
        result.maximum[axis] = max(result.maximum[axis], point[axis])
    inc result.vertexCount

proc transformBounds(minimum, maximum: array[3, float32],
    transform: Mat4): Bounds =
  for corner in 0 .. 7:
    let point = transformPoint(transform, [
      if (corner and 1) == 0: minimum[0] else: maximum[0],
      if (corner and 2) == 0: minimum[1] else: maximum[1],
      if (corner and 4) == 0: minimum[2] else: maximum[2],
    ])
    if result.vertexCount == 0:
      result.minimum = point
      result.maximum = point
    else:
      for axis in 0 .. 2:
        result.minimum[axis] = min(result.minimum[axis], point[axis])
        result.maximum[axis] = max(result.maximum[axis], point[axis])
    inc result.vertexCount

proc encloses(outer, inner: Bounds, tolerance = 0.01'f32): bool =
  for axis in 0 .. 2:
    if outer.minimum[axis] > inner.minimum[axis] + tolerance or
        outer.maximum[axis] < inner.maximum[axis] - tolerance:
      return false
  true

proc formatBounds(bounds: Bounds): string =
  if bounds.vertexCount == 0:
    return "no triangle vertices"
  let span = [bounds.maximum[0] - bounds.minimum[0],
    bounds.maximum[1] - bounds.minimum[1],
    bounds.maximum[2] - bounds.minimum[2]]
  "vertices=" & $bounds.vertexCount &
    " min=" & $bounds.minimum & " max=" & $bounds.maximum &
    " span=" & $span

proc parseIndex(value, label: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, label & " must be an integer")
  if result < 0:
    raise newException(ValueError, label & " cannot be negative")

proc main() =
  if paramCount() notin [2, 3, 4, 5]:
    quit("Usage: scene_bounds image.iso sm2-resource-path " &
      "[depth [object|chunk [root-link-index]]]", 1)

  try:
    let depth = if paramCount() >= 3: parseIndex(paramStr(3), "Depth") else: 1
    if paramCount() >= 4 and paramStr(4) notin ["object", "chunk"]:
      raise newException(ValueError, "Matrix must be 'object' or 'chunk'")
    let useChunkMatrix = paramCount() >= 4 and paramStr(4) == "chunk"
    let selectedRootLink = if paramCount() == 5:
      parseIndex(paramStr(5), "Root link index") else: -1
    let scene = loadLinkedChunkGeometryFromIso(paramStr(1), paramStr(2), depth,
      useChunkMatrix, selectedRootLink)
    echo "Bounds include decoded triangle vertices only. Link matrix: ",
      (if useChunkMatrix: "ChunkMatrix" else: "ObjectMatrix")

    var staticIndex = 0
    for model in scene.models:
      if not model.isStaticGeometry:
        continue
      let bounds = measure(model, model.modelTransform)
      echo "static[", staticIndex, "] model=", model.modelId,
        " resource=", model.modelPath, " ", formatBounds(bounds)
      if model.hasSceneryBounds:
        let storedBounds = transformBounds(model.sceneryBoundsMinimum,
          model.sceneryBoundsMaximum, model.modelTransform)
        echo "  record bounds ", formatBounds(storedBounds),
          "; encloses decoded vertices: ", encloses(storedBounds, bounds)
      inc staticIndex

    for placementIndex, placement in scene.placements:
      var partIndex = 0
      for modelIndex in placement.placementModelIndices():
        if modelIndex < 0 or modelIndex >= scene.models.len:
          raise newException(IOError, "Placement model index is out of range")
        let model = scene.models[modelIndex]
        let bounds = measure(model, placementTransform(placement))
        echo "placement[", placementIndex, "] part=", partIndex,
          " instance=", placement.instanceId, " object=", placement.objectId,
          " model=", model.modelId, " resource=", model.modelPath, " ",
          formatBounds(bounds)
        inc partIndex
  except CatchableError as error:
    quit("Could not inspect linked scene bounds: " & error.msg, 1)

when isMainModule:
  main()
