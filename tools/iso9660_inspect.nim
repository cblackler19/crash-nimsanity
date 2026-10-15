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
import std/[os, sets, strutils]

import iso9660

proc inspectDirectory(image: IsoImage, directoryPath: string,
    prefix: string, visited: var HashSet[uint32], depth: int) =
  if depth > 16:
    return

  for entry in image.listDirectory(directoryPath):
    let path = if prefix.len == 0: entry.name else: prefix & "/" & entry.name
    let kind = if entry.isDirectory: "dir " else: "file"
    echo kind, "  lba=", entry.extentLba, "  bytes=", entry.byteLength, "  ", path

    if entry.isDirectory and entry.extentLba notin visited:
      visited.incl(entry.extentLba)
      inspectDirectory(image, path, path, visited, depth + 1)

proc printSlice(image: IsoImage, path: string, offset: int64, count: int) =
  let entry = image.findEntry(path)
  if entry.isDirectory:
    raise newException(IOError, "Requested ISO path is a directory")
  let bytes = image.readSlice(entry, offset, count)
  var start = 0
  while start < bytes.len:
    stdout.write(toHex(offset + start, 8), "  ")
    let finish = min(start + 16, bytes.len)
    for index in start ..< finish:
      stdout.write(toHex(int(bytes[index]), 2), " ")
    stdout.writeLine("")
    start = finish

proc main() =
  if paramCount() notin [1, 4]:
    quit("Usage: iso9660_inspect <image.iso> [file-path offset byte-count]", 1)

  let imagePath = paramStr(1)
  try:
    let image = openIso(imagePath)
    defer: image.close()

    echo "ISO9660 volume: ", image.volumeName
    echo "Logical block size: ", image.logicalBlockSize
    let root = image.rootEntry()
    echo "Root directory: lba=", root.extentLba, " bytes=", root.byteLength

    if paramCount() == 4:
      let offset = parseBiggestInt(paramStr(3))
      let count = parseInt(paramStr(4))
      echo "Reading ", count, " bytes from ", paramStr(2), " at offset ", offset
      printSlice(image, paramStr(2), offset, count)
    else:
      echo "Entries:"
      var visited = initHashSet[uint32]()
      visited.incl(root.extentLba)
      inspectDirectory(image, "", "", visited, 0)
  except IOError as error:
    quit(error.msg, 1)
  except ValueError as error:
    quit("Invalid numeric argument: " & error.msg, 1)

when isMainModule:
  main()
