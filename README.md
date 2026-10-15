<!-- # ISC License -->
<!-- # -->
<!-- # Copyright (c) 2026 Caleb Blackler -->
<!-- # -->
<!-- # Permission to use, copy, modify, and/or distribute this software for any -->
<!-- # purpose with or without fee is hereby granted, provided that the above -->
<!-- # copyright notice and this permission notice appear in all copies. -->
<!-- # -->
<!-- # THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH -->
<!-- # REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY -->
<!-- # AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, -->
<!-- # INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM -->
<!-- # LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR -->
<!-- # OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR -->
<!-- # PERFORMANCE OF THIS SOFTWARE. -->

# crash-nimsanity

An experimental native reimplementation of *Crash Twinsanity* in Nim. The project combines a small OpenGL renderer with read-only tools for examining the game's on-disc formats. It is an independent fan project and is not affiliated with the game's rights holders.

## Current status

The renderer opens an 800 × 600 window, draws a rotating colored cube, and supports basic camera translation. It can also read a PSMT8 texture and its mip levels directly from a user-supplied ISO, then preview either that texture or a selected model item on a rotating textured mesh. Full level geometry, game-accurate material assignment and shader behavior, and game rendering are not integrated yet.

The research tools can inspect an ISO image directly. Current format work covers ISO9660 filesystems, `.BH`/`.BD` archive indexes, `.MH`/`.MB` tables, and `.RM2`/`.SM2` sections, texture and material links, bounded VIF commands, and decoded model positions, UV/color attributes, and candidate triangle strips. In the Cavern samples, all parsed shader texture IDs and rigid-model material links resolve to sibling records. A Nim PSMT8 decoder converts all 75 Cavern textures and their mip levels into RGBA in memory, and the renderer can preview selected textures and model items directly from the ISO. The model inspector lists every resolving material/texture pair for an item. The default model preview uses the first pair; an explicitly experimental mode applies material links to submodels in list order when their counts match, so that hypothesis can be visually checked. One decoded base texture has been visually reviewed. Findings and open questions are tracked in [the asset investigation notes](docs/asset-investigation.md). Format labels taken from community tools are identified as their authors' classifications; observed facts and unresolved interpretations are kept separate.

## Requirements

- Nim 2.2.0 or newer, with Nimble.
- The `nimgl` Nim package, declared by the Nimble project file.
- A system with GLFW support and an OpenGL 3.3-capable graphics driver.
- For asset research, a user-supplied Crash Twinsanity ISO image. The game itself is not included.

## Build and run

From the repository root:

```sh
nimble build
nimble run
```

Controls in the current renderer:

- `W`, `A`, `S`, `D`: move horizontally.
- `R`, `F`: move up and down.
- `Esc`: close the window.

## ISO research tools

The inspectors below open the ISO and read file ranges in place. They do not extract or write game resources. Compile a tool from the repository root with Nim; for example:

```sh
nim c --path:src --out:tools/rm2_inspect tools/rm2_inspect.nim
```

On Windows, Nim adds the `.exe` extension to the output. Substitute the tool name to build another inspector.

The repository includes these utilities:

| Tool | Purpose |
| --- | --- |
| `iso9660_inspect` | List ISO9660 directories or print a bounded hexadecimal file range. |
| `bh_inspect` | Parse a `.BH` archive index and optionally check its ranges against the paired `.BD`. |
| `mh_inspect` | Compare `.MH` records with candidate ranges in the paired `.MB`. |
| `rm2_inspect` | Inspect `.RM2`/`.SM2` section tables, decode PSMT8 textures and mip levels, check model-item VIF decoding coverage and linked material/submodel count agreement, inspect material/rigid-model records, and scan VIF blocks. |
| `texture_inspect` | Load one PSMT8 texture and its mip levels through an ISO's `.BH`/`.BD` archive without extracting the resource. |
| `model_inspect` | Decode one model's bounded VIF position, UV/color, and strip records, report per-submodel vertex/triangle counts, and list all resolving material/texture pairs. |
| `elf_mips_refs` | Find direct MIPS immediate references to strings in a supplied ELF executable. |

To preview a texture in the OpenGL window, run the main executable with an ISO path, a resource path inside `CRASH.BD`, and a decimal texture ID. For example:

```sh
main /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 3879915471
```

The preview reads the required ranges directly from the ISO and uploads the decoded base image and mip levels to OpenGL. It does not extract the resource to disk.

To preview a model item, pass `--model`, the ISO path, resource path, and model ID. The app follows the model's rigid-model and material references to choose a texture. Add a texture ID at the end to override that choice:

```sh
main --model /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 4263539267
```

For models where the number of resolved material links matches the number of submodels, the renderer can try assigning those links to submodels in list order. This is an unverified format hypothesis and is enabled only by the explicit flag:

```sh
main --model /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 4022622118 --candidate-material-order
```

The app prints each candidate pairing as it loads it. This preview mode is intended to help inspect the hypothesis; it does not establish that the game uses the same order.

The current VIF reader handles the observed Cavern position and UV/color UNPACK streams and expands their candidate strip markers into triangles. It does not yet resolve the PS2's full VU memory/TOPS behavior or reproduce all material shader settings.

The examples below use POSIX shell syntax. In PowerShell, prefix local tools with `.` (for example, `.\tools\rm2_inspect.exe`) and use the `.exe` suffix.

Examples:

```sh
# List the ISO9660 directory tree
tools/iso9660_inspect /path/to/Crash-Twinsanity.iso

# Inspect the Crash archive catalog directly in the ISO
tools/bh_inspect --iso /path/to/Crash-Twinsanity.iso

# Inspect the default music metadata and its paired data in the ISO
tools/mh_inspect /path/to/Crash-Twinsanity.iso

# Inspect the Cavern RM2 model table directly in the ISO
tools/rm2_inspect /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 0 2

# Load one texture and its mip levels directly from the ISO
tools/texture_inspect /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 3879915471

# Decode one model item from the ISO and report its triangle bounds
tools/model_inspect /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 4263539267
```

Select child section `0` to inspect the texture table and summarize dimensions, pixel formats, and transfer-buffer bounds:

```sh
tools/rm2_inspect /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 0 0
```

The optional numeric arguments to `rm2_inspect` select section-table positions: `0` selects the outer graphics section in this sample, and `2` selects its model section. The tool prints the section IDs alongside those positions. Consult each tool's usage message for its other modes.

`elf_mips_refs` currently accepts a standalone ELF file path rather than an ISO path:

```sh
tools/elf_mips_refs /path/to/game.elf ".BH" ".BD"
```

## Game data and legal notes

Game images, executables, and extracted assets are not part of this repository. The `gamefiles/` directory is ignored by Git for local research inputs. Use only game data you are legally entitled to access. This project distributes its own source code and research notes, not copyrighted game content.

*Crash Twinsanity* and its names, characters, and assets belong to their respective rights holders. This project is an independent, non-official effort; no endorsement or affiliation is implied.

## Credits and research references

- [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), by Smartkin, Artem Yashin (NeoKesha), and BetaM, is MIT licensed. Its archive, section, model, rigid-model, and VIF/DMA readers informed format cross-checks; its PSMT8 mapping and model attribute/strip interpretation were adapted for the Nim implementation. The local ISO samples were parsed independently. Required MIT notices are retained in [third-party notices](docs/THIRD_PARTY_LICENSES.md).
- [KnuxLib](https://github.com/Knuxfan24/KnuxLib), by Knuxfan24, is MIT licensed and independently recognizes the `.BH`/`.BD` archive pairing. It was used as a format reference; no code was copied.
- [vgmstream](https://github.com/vgmstream/vgmstream), by its contributors and licensed under ISC, provided a reference interpretation for the `MSVp` music headers; no code was copied.
- [FFmpeg](https://github.com/FFmpeg/FFmpeg) provided a reference for the PSX ADPCM block-header scan in the music research tool; no code was copied.
- The full source list, attributions, and research limitations are maintained in [the asset investigation notes](docs/asset-investigation.md).

## License

Project code is provided under the ISC License. See [LICENSE](LICENSE).
