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

The renderer is at the foundation stage: it opens an 800 × 600 window, draws a rotating colored cube, and supports basic camera translation. It does not yet load Crash Twinsanity levels, models, textures, or other game assets.

The research tools can inspect an ISO image directly. Current format work covers ISO9660 filesystems, `.BH`/`.BD` archive indexes, `.MH`/`.MB` tables, and `.RM2`/`.SM2` section, model, rigid-model reference, and bounded VIF command records, including per-address UNPACK count comparisons with declared vertices. Findings and open questions are tracked in [the asset investigation notes](docs/asset-investigation.md). Format labels taken from community tools are identified as their authors' classifications; observed facts and unresolved interpretations are kept separate.

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
| `rm2_inspect` | Inspect `.RM2`/`.SM2` section tables, bounded model/rigid-model records, and VIF block lengths. |
| `elf_mips_refs` | Find direct MIPS immediate references to strings in a supplied ELF executable. |

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

- [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), by Smartkin, Artem Yashin (NeoKesha), and BetaM, is MIT licensed. Its archive, section, model, rigid-model, and VIF/DMA readers informed format cross-checks. No source code was copied or adapted; the local ISO samples were parsed independently. If MIT-licensed code is incorporated in the future, its required copyright and permission notices must be retained.
- [KnuxLib](https://github.com/Knuxfan24/KnuxLib), by Knuxfan24, is MIT licensed and independently recognizes the `.BH`/`.BD` archive pairing. It was used as a format reference; no code was copied.
- The full source list, attributions, and research limitations are maintained in [the asset investigation notes](docs/asset-investigation.md).

## License

Project code is provided under the ISC License. See [LICENSE](LICENSE).
