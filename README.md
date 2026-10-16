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

The renderer opens an 800 × 600 window, draws a rotating colored cube, and supports camera movement and mouse look. It can read textures and models directly from a user-supplied ISO, preview placed objects, and draw model items from paired `.SM2` resources. The experimental chunk-link mode loads neighboring `.SM2` resources and their paired `.RM2` placement groups, keeping repeated resource paths when their composed transforms differ beyond a small tolerance. For each placed object, it draws the first loadable geometry model reached through the object's graphics-info links, falling back to decoded vertex colors when a texture link does not resolve. Other OGI candidates are not overlaid because their relationship to one object transform is unknown. The preview culls mesh bounds fully outside the camera frustum using bounds calculated from decoded vertices. The serialized row-vector `ObjectMatrix` is converted for OpenGL column-vector transforms; this has been visually confirmed for a tunnel mesh and save-box placement in the Cavent→Tunnel01 link. Camera culling does not implement the game's octree, LOD, or portal visibility, and repeated-resource placements remain candidates rather than confirmed retail visibility. Transform selection for other links, level completeness, and game-accurate rendering, collision, and gameplay remain unresolved.

The research tools can inspect an ISO image directly. Current format work covers ISO9660 filesystems, `.BH`/`.BD` archive indexes, `.MH`/`.MB` tables, and `.RM2`/`.SM2` sections, texture and material links, bounded VIF commands, and decoded model positions, normals, UV/color attributes, emissive-color candidates, and triangle strips. The `scene_bounds` tool also compares stored scenery boxes with decoded geometry; some Doc Amok boxes do not enclose their meshes, so those records remain diagnostic-only. Music record 7 now decodes using the 64 KiB two-track interleave and end offset inferred from `MUSIC.MH`; the user confirmed that the generated WAV sounds identical to the retail game. The relevant playback setup was cross-referenced with Smartkin's `twinsanity-reversed` decompilation, with attribution and licensing limits documented below. In the Cavern samples, all parsed shader texture IDs and rigid-model material links resolve to sibling records. A Nim PSMT8 decoder converts all 75 Cavern textures and their mip levels into RGBA in memory, and the renderer can preview selected textures and model items directly from the ISO. The model inspector lists every resolving material/texture pair and reports normal/emissive attribute coverage for an item. The default model preview uses the first pair; an explicitly experimental mode applies material links to submodels in list order when their counts match. The initial Crash model preview was recognized by the user as the spinning Crash model, a useful visual check that does not establish the mapping for all models. One decoded base texture has also been visually reviewed. Findings and open questions are tracked in [the asset investigation notes](docs/asset-investigation.md). Format labels taken from community tools are identified as their authors' classifications; observed facts and unresolved interpretations are kept separate.

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

- `W`, `A`, `S`, `D`: move relative to the camera's horizontal look direction.
- `R`, `F`: move up and down.
- Mouse movement: look left/right and up/down. The cursor is captured while the window is open.
- Camera movement speed: 12 world units per second.
- `Esc`: close the window and release the cursor.

## ISO research tools

The inspectors below open the ISO and read file ranges in place. They do not extract or write game resources. Compile a tool from the repository root with Nim; for example:

```sh
nim c --path:src --out:tools/rm2_inspect tools/rm2_inspect.nim
```

On Windows, Nim adds the `.exe` extension to the output. Substitute the tool name to build another inspector.

To create a candidate WAV from type-1 record 7 in `MUSIC.MH`, build and run the audio diagnostic:

```sh
nim c --path:src --out:tools/mh_audio_export tools/mh_audio_export.nim
tools/mh_audio_export /path/to/Crash-Twinsanity.iso 7 candidate.wav
```

The exporter reads the two-track interleave size from the second `MUSIC.MH` header word (65,536 bytes per track chunk in the inspected disc) and uses each record's rate and final-track end offset. It writes track 0 to the left channel and track 1 to the right. The user confirmed that record 7's generated WAV sounds identical to the retail game; see the research notes for the `twinsanity-reversed` attribution and earlier rejected hypotheses. An optional track-chunk size in bytes and sample-rate override are available for diagnosis. For example, override the chunk size with 32,768 bytes and the rate with 16 kHz:

```sh
tools/mh_audio_export /path/to/Crash-Twinsanity.iso 7 candidate-16k.wav 32768 16000
```

The two-track layout and end offset match the user's retail-game listening comparison for record 7. Other music records have not yet been individually compared.

The repository includes these utilities:

| Tool | Purpose |
| --- | --- |
| `iso9660_inspect` | List ISO9660 directories or print a bounded hexadecimal file range. |
| `bh_inspect` | Parse a `.BH` archive index and optionally check its ranges against the paired `.BD`. |
| `mh_inspect` | Compare `.MH` records with candidate ranges in the paired `.MB`, including type-1 track-pair and end-offset checks. |
| `mh_audio_export` | Decode candidate two-track interleaved type-1 `MUSIC.MH` ranges, writing WAV directly from ISO data. |
| `rm2_inspect` | Inspect `.RM2`/`.SM2` section tables, decode PSMT8 textures and mip levels, check model-item VIF decoding coverage and linked material/submodel count agreement, inspect material/rigid-model and placed-object records, and dump bounded hexadecimal ranges. |
| `texture_inspect` | Load one PSMT8 texture and its mip levels through an ISO's `.BH`/`.BD` archive without extracting the resource. |
| `model_inspect` | Decode one model's bounded VIF position, UV/color, and strip records, report per-submodel vertex/triangle counts, and list all resolving material/texture pairs. |
| `scene_bounds` | Report decoded triangle-vertex bounds for each static model and placed object in a linked-scene candidate. |
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

To preview the first 32 object placements from a resource instance group, pass the outer and nested section-table indices. This mode reads resources directly from the ISO and does not extract them:

```powershell
.\main.exe --placements ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.rm2" 4 6
```

Add a final integer to change the record limit. For each placement, the preview draws the first loadable geometry model reached through the object's graphics-info links at the stored position and rotation, and centers the camera on the selected positions. Other candidates are omitted until their relationship to the object transform is established. Candidates without a resolving texture are rendered with their decoded vertex colors. Primary 16-bit rotation words are treated as turns with 65,536 units per revolution and composed in XYZ Euler order; the companion `COMRot` words are ignored. Instance relationships and game-accurate transforms are not applied.

To draw a chunk's static scenery from its SM2 section-0 draw list, use the experimental chunk-geometry view:

```powershell
.\main.exe --chunk ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2"
```

This mode reads the section-0 scenery hierarchy, resolves its rigid-model references through the ISO's graphics tables, and applies each mesh's stored 4×4 transform with the Twinsanity Editor's X-axis conversion. It skips LOD entries and does not yet use the stored bounds for visibility culling. The linked-scene preview composes these per-mesh transforms with its selected experimental chunk-link transform; linked-chunk visibility and portal rules are not implemented.

To include linked chunks, run `--chunk-links` with the same resource path. The optional depth defaults to one link level and accepts values from 0 through 2:

```powershell
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2"
```

The preview follows the paths in SM2 root section 5, appends `.sm2`, and applies each link's `ObjectMatrix` by default to static scenery meshes and RM2 placements. It converts the serialized row-vector matrix to the OpenGL column-vector convention before composition. The matrix can be switched to `ChunkMatrix`; an optional zero-based root-link index follows only one neighbor. Static geometry and placements can be shown separately, and a final zero-based index isolates one static mesh or placement. For a depth-0 root-only preview, omit the root-link index before the scene mode:

```powershell
# Show only static model candidates from root and root link 0
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 1 object 0 static

# Isolate static mesh 0 in the root chunk without loading links
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 0 object static 0

# Isolate static model index 3 in the same linked view
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 1 object 0 static 3

# Show the placed objects only, or isolate placement index 4
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 1 object 0 placements
.\main.exe --chunk-links ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 1 object 0 placements 4
```

To inspect the per-model and per-placement bounds used by a linked-scene candidate, build and run the read-only bounds tool. The optional matrix mode selects the same `ObjectMatrix` or `ChunkMatrix` interpretation as `--chunk-links`; an optional root-link index isolates one neighbor:

```powershell
nim c --path:src --out:tools/scene_bounds tools/scene_bounds.nim
.\tools\scene_bounds.exe ".\gamefiles\Crash Twinsanity (v1.00).iso" "Levels\Earth\Cavern\cavent.sm2" 1 object 0
```

The report measures decoded triangle vertices after the preview's candidate transforms. These bounds help identify large geometry contributors; they do not determine which models are visible together or validate the decoded triangle topology.

The preview reads every nonempty RM2 instance group in each linked resource and draws the first loadable geometry model reached from each object's graphics-info links. In separated modes, the camera fit is recalculated from the geometry being displayed. Static meshes now come from the SM2 section-0 scenery draw list with their stored per-item transforms. The user confirmed that the single-chunk `cavent.sm2` and `antfight.sm2` previews render coherent geometry without the earlier fan, and that the linked-scene mesh selector isolates root meshes correctly. The combined view remains a diagnostic candidate set rather than a reconstructed level: cell culling, LOD selection, linked-chunk visibility, and exact placement comparison against the Editor are still incomplete. Models without a resolving texture are kept and drawn using their decoded vertex colors. To build a white silhouette diagnostic that overrides texture and vertex colors, run:

```powershell
nim c --path:src --nimcache:nimcache/white --out:main-white.exe -d:release -d:PreviewSolidWhite src/main.nim
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

To inspect an RM2 instance group's object placements, select an outer instance-group section and its nested object-instance section. For the Cavern resource, outer index `4` has section ID `0`, and nested index `6` has section ID `6`:

```sh
tools/rm2_inspect /path/to/Crash-Twinsanity.iso "Levels\Earth\Cavern\cavent.rm2" 4 6
```

The inspector reports bounded position and rotation fields, linked IDs, and whether each placed object's ID appears in the sibling Code/Object table. It checks candidate graphics-info links against Code/OGI records, then follows model-bearing OGI links through rigid-model records to geometry Model IDs across RM2/SM2 resources indexed from the ISO. It also reports unresolved OGI IDs with their frequency; in the three current samples, every unresolved value is `0xFFFF`, a likely empty-reference sentinel. The tool can dump ranges directly from either a selected outer section or nested section with `--hex`. All non-sentinel links in the sampled chunks resolve through this chain. Rotation values are shown as raw 16-bit fields, not converted to angles or matrices.

`elf_mips_refs` currently accepts a standalone ELF file path rather than an ISO path:

```sh
tools/elf_mips_refs /path/to/game.elf ".BH" ".BD"
```

## Game data and legal notes

Game images, executables, and extracted assets are not part of this repository. The `gamefiles/` directory is ignored by Git for local research inputs. Use only game data you are legally entitled to access. This project distributes its own source code and research notes, not copyrighted game content.

*Crash Twinsanity* and its names, characters, and assets belong to their respective rights holders. This project is an independent, non-official effort; no endorsement or affiliation is implied.

## Credits and research references

- [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), by Smartkin, Artem Yashin (NeoKesha), and BetaM, is MIT licensed. Its archive, section, object-instance, GameObject, graphics-info, chunk-link, model, rigid-model, and VIF/DMA readers informed format cross-checks; its PSMT8 mapping and model attribute/strip interpretation were adapted for the Nim implementation. The local ISO samples were parsed independently. Required MIT notices are retained in [third-party notices](docs/THIRD_PARTY_LICENSES.md).
- [KnuxLib](https://github.com/Knuxfan24/KnuxLib), by Knuxfan24, is MIT licensed and independently recognizes the `.BH`/`.BD` archive pairing. It was used as a format reference; no code was copied.
- [vgmstream](https://github.com/vgmstream/vgmstream), by its contributors and licensed under ISC, provided a reference interpretation for the `MSVp` music headers; no code was copied.
- [FFmpeg](https://github.com/FFmpeg/FFmpeg) provided references for the PSX ADPCM block-header scan and diagnostic decoder; no code was copied.
- Smartkin, [twinsanity-reversed](https://github.com/Smartkin/twinsanity-reversed), especially `src/game/sound.cpp`, `src/platform/ps2/audio.cpp`, and `src/platform/ps2/multistream/commands.cpp`, informed the music interleave, track setup, pitch, and end-offset analysis. The user confirmed the resulting record-7 WAV against retail gameplay. No source was copied; the repository's visible root has no license file, so it is credited as a research reference only.
- The full source list, attributions, and research limitations are maintained in [the asset investigation notes](docs/asset-investigation.md).

## License

Project code is provided under the ISC License. See [LICENSE](LICENSE).
