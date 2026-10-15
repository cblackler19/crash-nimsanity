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

import iso_texture

proc main() =
  if paramCount() != 3:
    quit("Usage: texture_inspect <image.iso> <path-inside-CRASH.BD> <texture-id>", 1)

  var textureId: uint32
  try:
    let parsedId = parseBiggestUInt(paramStr(3))
    if parsedId > uint64(high(uint32)):
      quit("Texture ID must fit in 32 bits", 1)
    textureId = uint32(parsedId)
  except ValueError:
    quit("Texture ID must be an unsigned integer", 1)

  try:
    let texture = loadTextureFromIso(paramStr(1), paramStr(2), textureId)
    echo "Texture ID: ", textureId
    echo "Dimensions: ", texture.width, "x", texture.height
    echo "Base RGBA bytes: ", texture.rgba.len
    echo "Mip levels: ", texture.mipLevels.len
    for index, mip in texture.mipLevels:
      echo "  ", index + 1, ": ", mip.width, "x", mip.height
  except CatchableError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
