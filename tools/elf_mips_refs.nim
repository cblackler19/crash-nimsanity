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

type
  ElfSection = object
    name: string
    address: uint32
    fileOffset: int
    byteLength: int
    flags: uint32
    sectionType: uint32

  StringAddress = object
    address: uint32
    sectionName: string

proc readU16LE(data: string, offset: int): uint16 =
  if offset < 0 or offset + 2 > data.len:
    raise newException(IOError, "Unexpected end of ELF file")
  uint16(ord(data[offset])) or (uint16(ord(data[offset + 1])) shl 8)

proc readU32LE(data: string, offset: int): uint32 =
  if offset < 0 or offset + 4 > data.len:
    raise newException(IOError, "Unexpected end of ELF file")
  uint32(ord(data[offset])) or
    (uint32(ord(data[offset + 1])) shl 8) or
    (uint32(ord(data[offset + 2])) shl 16) or
    (uint32(ord(data[offset + 3])) shl 24)

proc cStringAt(data: string, offset: int): string =
  if offset < 0 or offset >= data.len:
    return ""
  var finish = offset
  while finish < data.len and data[finish] != '\0':
    inc finish
  data[offset ..< finish]

proc parseSections(data: string): seq[ElfSection] =
  if data.len < 52 or data[0 .. 3] != "\x7fELF" or
      ord(data[4]) != 1 or ord(data[5]) != 1:
    raise newException(IOError, "Expected a 32-bit little-endian ELF file")
  if readU16LE(data, 18) != 8:
    raise newException(IOError, "Expected an ELF file with MIPS machine type")

  let tableOffset = int(readU32LE(data, 32))
  let entrySize = int(readU16LE(data, 46))
  let entryCount = int(readU16LE(data, 48))
  let namesIndex = int(readU16LE(data, 50))
  if entrySize < 40 or namesIndex >= entryCount or tableOffset < 0 or
      tableOffset + entrySize * entryCount > data.len:
    raise newException(IOError, "Invalid ELF section header table")

  let namesHeader = tableOffset + namesIndex * entrySize
  let namesOffset = int(readU32LE(data, namesHeader + 16))
  let namesLength = int(readU32LE(data, namesHeader + 20))
  if namesOffset + namesLength > data.len:
    raise newException(IOError, "Invalid ELF section name table")
  let names = data[namesOffset ..< namesOffset + namesLength]

  for index in 0 ..< entryCount:
    let entry = tableOffset + index * entrySize
    let sectionType = readU32LE(data, entry + 4)
    let fileOffset = int(readU32LE(data, entry + 16))
    let byteLength = int(readU32LE(data, entry + 20))
    if sectionType != 8 and (fileOffset < 0 or fileOffset + byteLength > data.len):
      raise newException(IOError, "ELF section extends beyond the file")
    result.add(ElfSection(
      name: cStringAt(names, int(readU32LE(data, entry))),
      address: readU32LE(data, entry + 12),
      fileOffset: fileOffset,
      byteLength: byteLength,
      flags: readU32LE(data, entry + 8),
      sectionType: sectionType
    ))

proc findStringAddresses(data: string, sections: openArray[ElfSection],
    needle: string): seq[StringAddress] =
  for section in sections:
    if section.sectionType == 8 or (section.flags and 0x4) != 0 or
        section.byteLength < needle.len:
      continue

    let contents = data[section.fileOffset ..< section.fileOffset + section.byteLength]
    var position = contents.find(needle)
    while position >= 0:
      result.add(StringAddress(
        address: section.address + uint32(position),
        sectionName: section.name
      ))
      position = contents.find(needle, position + 1)

proc findImmediatePairs(data: string, sections: openArray[ElfSection],
    target: uint32): int =
  # This catches common direct address construction, not indirect pointer-table references.
  for section in sections:
    if section.sectionType == 8 or (section.flags and 0x4) == 0:
      continue

    let instructionCount = section.byteLength div 4
    for index in 0 ..< instructionCount:
      let firstOffset = section.fileOffset + index * 4
      let first = readU32LE(data, firstOffset)
      if first shr 26 != 0x0f:
        continue

      let register = (first shr 16) and 0x1f
      let upper = first and 0xffff
      let lastIndex = min(instructionCount - 1, index + 6)
      for nextIndex in index + 1 .. lastIndex:
        let nextOffset = section.fileOffset + nextIndex * 4
        let next = readU32LE(data, nextOffset)
        let opcode = next shr 26
        let sourceRegister = (next shr 21) and 0x1f
        let destinationRegister = (next shr 16) and 0x1f
        if sourceRegister != register or destinationRegister != register or
            opcode notin [0x09'u32, 0x0d'u32]:
          continue

        let lower = next and 0xffff
        var candidate: uint32
        if opcode == 0x0d:
          candidate = (upper shl 16) or lower
        else:
          let signedLower = int64(cast[int16](uint16(lower)))
          candidate = uint32(((int64(upper) shl 16) + signedLower) and 0xffff_ffff)

        if candidate == target:
          let pairAddress = section.address + uint32(index * 4)
          let completionAddress = section.address + uint32(nextIndex * 4)
          let operation = if opcode == 0x0d: "ori" else: "addiu"
          echo "  candidate in ", section.name, " at 0x", toHex(pairAddress, 8),
            " + 0x", toHex(completionAddress, 8), " (", operation,
            ", register ", register, ")"
          if nextIndex > 0:
            let callIndex = nextIndex - 1
            let callWord = readU32LE(data, section.fileOffset + callIndex * 4)
            if callWord shr 26 == 3:
              let callAddress = section.address + uint32(callIndex * 4)
              let callTarget = ((callAddress + 4) and 0xf000_0000'u32) or
                ((callWord and 0x03ff_ffff'u32) shl 2)
              echo "    completion is the delay instruction for JAL 0x",
                toHex(callTarget, 8)
          if nextIndex + 1 < instructionCount:
            let callIndex = nextIndex + 1
            let callWord = readU32LE(data, section.fileOffset + callIndex * 4)
            if callWord shr 26 == 3:
              let callAddress = section.address + uint32(callIndex * 4)
              let callTarget = ((callAddress + 4) and 0xf000_0000'u32) or
                ((callWord and 0x03ff_ffff'u32) shl 2)
              echo "    following instruction is JAL 0x", toHex(callTarget, 8)
          inc result

proc main() =
  if paramCount() < 2:
    quit("Usage: elf_mips_refs <game.elf> <string> [string ...]", 1)

  try:
    let data = readFile(paramStr(1))
    let sections = parseSections(data)
    for argumentIndex in 2 .. paramCount():
      let needle = paramStr(argumentIndex)
      echo "String: ", needle
      let addresses = findStringAddresses(data, sections, needle)
      if addresses.len == 0:
        echo "  No matching string found in non-executable sections."
      for location in addresses:
        echo "  ", location.sectionName, " address=0x", toHex(location.address, 8)
        if findImmediatePairs(data, sections, location.address) == 0:
          echo "  No direct LUI plus ADDIU/ORI pair found; indirect references are not checked."
  except IOError as error:
    quit(error.msg, 1)

when isMainModule:
  main()
