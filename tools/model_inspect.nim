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
import std/[os, strutils]

import iso_model
import ps2_model

proc main() =
  if paramCount() != 3:
    quit("Usage: model_inspect <image.iso> <path-inside-CRASH.BD> <model-id>", 1)

  var modelId: uint32
  try:
    let parsedId = parseBiggestUInt(paramStr(3))
    if parsedId > uint64(high(uint32)):
      quit("Model ID must fit in 32 bits", 1)
    modelId = uint32(parsedId)
  except ValueError:
    quit("Model ID must be an unsigned integer", 1)

  try:
    let model = loadModelFromIso(paramStr(1), paramStr(2), modelId)
    echo "Model ID: ", modelId
    echo "Submodels: ", model.submodelCount
    echo "Decoded triangles: ", model.triangleCount
    echo "Expanded triangle vertices: ", model.vertices.len
    if model.vertices.len > 0:
      var minimum = model.vertices[0].position
      var maximum = minimum
      for vertex in model.vertices:
        for axis in 0 .. 2:
          minimum[axis] = min(minimum[axis], vertex.position[axis])
          maximum[axis] = max(maximum[axis], vertex.position[axis])
      echo "Position bounds: ", minimum, " .. ", maximum
  except CatchableError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
