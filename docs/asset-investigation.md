# Asset investigation notes

These notes record observations from the local NTSC-U/C v1.00 disc image. The image and executable remain local research inputs and are not part of the repository.

## ISO layout

The ISO9660 volume label is `TWINSANITY`, with a 2048-byte logical block size. The game files are under `CRASH6`:

| File | ISO LBA | Length in bytes |
| --- | ---: | ---: |
| `AMERICAN.MB` | 469279 | 13,121,536 |
| `AMERICAN.MH` | 475686 | 2,868 |
| `CRASH.BD` | 475688 | 890,464,828 |
| `CRASH.BH` | 910486 | 27,376 |
| `MUSIC.MB` | 910500 | 221,773,824 |
| `MUSIC.MH` | 1018788 | 2,868 |

The listed extents are consecutive after rounding each file up to ISO logical blocks. This describes disc placement; it does not establish how the game relates or loads the similarly named files.

## `.MH` observations

Both `.MH` files have the same length and begin with these 8 bytes:

```text
8F 00 00 00 00 00 01 00
```

Interpreting the first two words as little-endian integers gives `143` and `65536`. The remaining 2,860 bytes divide evenly into 143 records of 20 bytes each. Each record can therefore be viewed as five little-endian 32-bit words for inspection; their meanings are not yet known.

Treating word 1 as a candidate byte length and word 2 as a candidate byte offset keeps all 143 ranges inside each corresponding `.MB` file. In record zero, those words are `309024` and `12812288` for `AMERICAN.MH`, and `309024` and `221464576` for `MUSIC.MH`; each range ends 224 bytes before the end of its `.MB` file.

All 143 `AMERICAN.MH` candidate offsets begin an `MSVp` byte sequence in `AMERICAN.MB`. The 13 records in `MUSIC.MH` with word 0 equal to `0` also begin `MSVp` sequences in `MUSIC.MB`. At these range starts, the big-endian word at byte 4 is `32`, and the big-endian word at byte 12 plus 48 equals the candidate range length for every checked entry. This links those records to bounded `MSVp` ranges; it does not identify the format's fields.

The 62 `MUSIC.MH` records with word 0 equal to `1` point to ranges that begin without `MSVp`. Sorted by offset, these ranges are contiguous from byte zero through byte `221118464`. The remaining 68 records have word 0 equal to `2` and words 1 through 4 all zero. These groupings are observed values; their meanings remain unknown.

At the `MSVp` range starts, the big-endian word at byte 16 matches `.MH` word 3 for all 13 type-0 music entries and 140 of 143 American entries. The exceptions are American records 125, 131, and 134: their `.MH` word 3 is `32000`, while the corresponding `.MB` word is `18000`, `48000`, and `48000`. Word 3 therefore should not be treated as a universal copy of that `.MB` field.

In `MUSIC.MH`, records 7 through 10 have word 0 equal to `1`. Their word 2 values are `0`, `3932160`, `8912896`, and `13631488`; for each record after the first, word 2 equals the prior record's word 2 plus its word 1. This is consistent with a cumulative range or offset field across those four records, though the address space and meaning are still unknown.

All 62 type-1 `MUSIC.MH` ranges begin with 16 zero bytes. In the first 228 bytes, 26 ranges have little-endian `0x000C` at every 16-byte step from offset `0x10` through `0xD0`; only record 7 has little-endian `0x44` at offset `0xE0`. These byte patterns do not yet identify a header or codec. `mh_inspect` reports these counts while reading each range directly from the ISO.

## `.BH` / `.BD` and executable clues

`CRASH.BH` begins with the little-endian word `1281` (`0x501`). After that word, the file parses exactly into 612 variable-length entries. Each entry contains a little-endian path byte length, that many path bytes, a little-endian data offset, and a little-endian data length. The entries consume the index to EOF. In table order, every data offset equals the prior range's end, starting at byte zero, and the final range ends at byte `890464828`, exactly the length of `CRASH.BD`.

The independent `BDArchive.cs` reader and writer in Twinsanity Editor call the leading word a magic value and write `0x501` when rebuilding an archive. Its reader likewise consumes each name-length/name/offset/size record and seeks to that offset in the paired `.BD`. This corroborates the layout found above and identifies `0x501` as the editor's archive header value; the interpretation is cross-checked against this project's own ISO data rather than copied code.

The read-only Nim utility [`bh_inspect.nim`](../tools/bh_inspect.nim) parses this layout, reports each path and range, and can check that ranges stay within a supplied `.BD` file. The data image itself was not extracted. `CRASH.BD` begins with `03 00 00 00`; this alone does not identify its internal format.

The archive index contains 135 `.RM2` resources and 134 `.SM2` resources. Matching the paths by directory and base name gives 134 pairs; `Startup\Default.rm2` is the unmatched `.RM2` entry. The MIT-licensed Twinsanity Editor describes an RM/SM pair as a complete level chunk, providing a useful lead for inspecting these resources.

The editor's `TwinsFile.cs` describes a 12-byte file header followed by a count of 12-byte section records containing offset, size, and ID, then section payloads. Three local ISO samples agree: `Levels\Earth\Cavern\cavent.rm2` and `.sm2`, and `Startup\Default.rm2`, each begin with word `0x00010001`; their section counts are 12, 7, and 12. For all three, the header's content-size word equals file length minus the header and section table, and the section ranges are contiguous from the end of the table through EOF. The section directory structure is corroborated; payload meanings still need direct validation.

The read-only Nim utility [`rm2_inspect.nim`](../tools/rm2_inspect.nim) locates an RM2 or SM2 path in the on-ISO `.BH` catalog, reads its header and section table directly from the `.BD` extent, and reports bounded section ranges. It does not extract resource payloads.

The editor maps RM2 section ID 11 and SM2 section ID 6 to graphics sections. The nested sections in both `cavent` graphics samples use the same `0x00010001` header and contain IDs 0 through 8. `TwinsSection.cs` maps those child IDs to texture, material, model, rigid model, skin, blend skin, mesh, LOD model, and skydome records. In the local samples, child ID 2 is 2,000,804 bytes in RM2 and 424,404 bytes in SM2; child ID 0 is 461,132 bytes in RM2 and 351,516 bytes in SM2. These names are the editor's classifications; the payload layouts and render semantics still need direct inspection.

The editor's `Model.Load` reader describes each ID-2 model item as a submodel count followed by records containing a vertex count, a VIF byte length and payload, and a blob byte length and payload. The on-ISO reader now walks that structure with per-item bounds checks, without interpreting the VIF instructions. In `cavent.rm2`, all 66 model items parse to the end of their declared ranges with no blob or trailing bytes; they contain 86 submodels, 45,983 declared vertices, and 1,998,704 VIF bytes. In `cavent.sm2`, all 13 model items likewise parse exactly, containing 44 submodels, 14,220 declared vertices, and 423,656 VIF bytes. These measurements confirm the editor's record boundaries for these two samples; they do not confirm the meaning of every VIF operation or vertex attribute.

The editor's `DMATag` reader takes the low 16 bits of the first word as QWC, and its VIF interpreter reads that many 16-byte units after the 16-byte tag. Applying that length check to the local VIF streams yields no overrun in either sample: 22 of 86 RM2 streams and 10 of 44 SM2 streams match `16 + QWC * 16` exactly. The rest have 12–36 bytes after that range, and every such byte is zero. For the first `cavent.rm2` stream, the QWC candidate is 973, giving 15,584 tag-plus-payload bytes inside a 15,620-byte VIF field, with 36 zero bytes following. The residual bytes are observed; their purpose is not yet established. This length check alone does not decode VIF payloads or verify the PS2's full DMA behavior.

The inspector now walks VIF command boundaries inside the tag's 8-byte command area plus its QWC-bounded payload. It accounts for command words, UNPACK payload sizes (including STCYCL cycle lengths and the packed V4-5 form), STMASK, STROW/STCOL, MPG, and DIRECT/DIRECTHL payloads. The scan uses little-endian command words and checks each payload against the bounded DMA span. Across the Cavern samples it walks 13,308 commands in 86 RM2 streams and 3,550 commands in 44 SM2 streams. It finds 7,700 and 1,700 UNPACK commands respectively; all streams finish on a command boundary, with no unsupported opcode or truncated payload encountered. This validates command boundaries for these samples only; the inspector does not reconstruct VU memory, decode vertex attributes, or establish triangle connectivity.

`rm2_inspect` accepts an optional outer section index to inspect that section's nested table, and an optional nested section index to parse the model item records. For example, `tools/rm2_inspect.exe "gamefiles/Crash Twinsanity (v1.00).iso" Levels\Earth\Cavern\cavent.rm2 0 2` selects outer table position 0 (ID 11) and nested table position 2 (ID 2). This reads the selected resource's section table and model records directly from the ISO; it does not extract payload files.

The editor maps graphics child ID 3 to rigid models and child ID 6 to meshes; both are read through its `RigidModel` parser, which expects a header word, a material-ID count and list, and a mesh ID. The on-ISO records in `cavent.rm2` (child ID 3) and `cavent.sm2` (child ID 6) fit that layout exactly: 66 RM2 items with header `0x101` and 86 material references, and 13 SM2 items with header `0x104` and 44 material references. Each has one distinct mesh reference per record. The inspector now checks those references against sibling child ID 2 model item IDs: all 66 RM2 references and all 13 SM2 references resolve. This supports a relationship between the field and model records in these samples, but does not establish how the game uses the relationship or what the differing header values mean.

The local game executable contains strings including `.BH`, `.BD`, `%s.mb`, `Crash6\Crash`, `Crash6\Music`, `STREAM.IRX`, `CDVDSTM.IRX`, and `streaming options`.

A direct MIPS reference scan finds `.BH` and `.BD` addresses materialized in adjacent calls to executable address `0x00203ED0` from the routine beginning at `0x002B46A8`. The helper reads the suffix length, updates a caller-provided buffer's length/capacity fields, and invokes copy helpers with the suffix; this supports identifying it as a string-building routine. The caller appends `.BH` to a buffer at its stack base and `.BD` to a second buffer 16 bytes later.

The caller then passes the two resulting buffer pointers in `$a1` and `$a2` to the same routine at `0x002AB688`, with a separate value `5` in `$a3`. That routine forwards its `$a2` argument to `0x002AC1B8` and uses its `$a1` argument as input to another buffer-building call for a field at offset 12 of the object passed in `$a0`. The short helper at `0x002AC1B8` stores the `$a2` buffer pointer at object offset 0 and installs a vtable pointer at offset 4. Thus, both suffix-derived strings are consumed together while initializing a stateful object; `$a3` is used to derive its flags at offset 8. The current static trace does not establish that either string is opened as a filesystem path, nor does it identify the object's later use or the meaning of flag value `5`.

The installed vtable is at `0x00306100`. Its nonzero entries include methods at `0x002AB9F8`, `0x002A8C58`, `0x002ABA78`, `0x002ABAE0`, and `0x002ABC08`. The method at `0x002A8C58` stores a value at object offset 44 and conditionally calls `0x002B6350` with the object's offset-12 string field. That routine lowercases the name, uses the `HOST0:` prefix string while building a lookup key, and calls `0x002B48E0`. The latter searches a count-and-pointer table using 20-byte record strides, builds a candidate key from each probed entry, and calls a string comparison helper against the requested key. Its result is stored in the object's offset-12 field. This supports interpreting the chain as name normalization and table lookup; it does not establish filesystem access or the role of the other stored name.

These call-site observations are consistent with the `.BH` index and `.BD` data being paired, which matches their on-disc lengths and ranges, but do not by themselves prove the exact open/read sequence or all container semantics.

## Next checks

- Inspect the `MSVp` header and music type-1 payload structure further, keeping the observed range associations separate from field semantics.
- Inspect the model and mesh payloads in the RM2/SM2 graphics sections and verify their vertex and index layouts against the actual bytes.
- Trace how the paired-name object and registry result are consumed after lookup, and determine whether that path reaches file access.

## Community references and licensing

- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/BDArchive.cs`. The repository is MIT-licensed. Its archive reader/writer is used here as an attributed format cross-check only; no source code was copied or adapted. If MIT-licensed code is reused from this project later, retain the MIT copyright and permission notice for that code when distributing the ISC-licensed project.
- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/TwinsFile.cs`. Its RM/SM pair and section-table descriptions guided the next inspection target; the header and range findings above were checked independently against our ISO. No source code was copied or adapted.
- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/TwinsSection.cs`. Its section-ID labels are recorded as editor classifications and used as research leads; no source code was copied or adapted.
- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/Items/Graphics/Model.cs`. Its `Model.Load` record layout guided the bounded inspection above; the two sample resources were parsed independently from the local ISO. No source code was copied or adapted.
- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/Items/Graphics/RigidModel.cs`. Its field layout guided the bounded check of graphics child IDs 3 and 6; the sample records were parsed independently from the local ISO. No source code was copied or adapted.
- Smartkin, Artem Yashin (NeoKesha), and BetaM, [Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor), `Twinsanity/VIF/DMATag.cs` and `Twinsanity/VIF/VIFInterpreter.cs`. Their QWC field handling guided a bounded length cross-check; no VIF interpreter code was copied or adapted.
- [PS2SDK VIF code definitions](https://ps2dev.github.io/ps2sdk/vif__codes_8h.html), maintained by the PS2SDK project. The command opcode values and bit fields informed the bounded command walk; no SDK code was copied.
- Knuxfan24, [KnuxLib](https://github.com/Knuxfan24/KnuxLib). Its MIT-licensed format list independently records `.BD`/`.BH` as a Crash Twinsanity archive pair. It is a possible comparison source for later parser work; no code was used here.
- Smartkin, [twinsanity-reversed](https://github.com/Smartkin/twinsanity-reversed), is a PAL executable decompilation project with relevant reverse-engineering material. Its repository currently lists no license file, so its code is not being incorporated into this ISC project.
