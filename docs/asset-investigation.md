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

## `.BH` / `.BD` and executable clues

`CRASH.BH` begins with the little-endian word `1281`; its meaning is not identified. After that word, the file parses exactly into 612 variable-length entries. Each entry contains a little-endian path byte length, that many path bytes, a little-endian data offset, and a little-endian data length. The entries consume the index to EOF. In table order, every data offset equals the prior range's end, starting at byte zero, and the final range ends at byte `890464828`, exactly the length of `CRASH.BD`.

The read-only Nim utility [`bh_inspect.nim`](../tools/bh_inspect.nim) parses this layout, reports each path and range, and can check that ranges stay within a supplied `.BD` file. The data image itself was not extracted. `CRASH.BD` begins with `03 00 00 00`; this alone does not identify its internal format.

The local game executable contains strings including `.BH`, `.BD`, `%s.mb`, `Crash6\Crash`, `Crash6\Music`, `STREAM.IRX`, `CDVDSTM.IRX`, and `streaming options`. These strings are consistent with the game referencing the named files and a streaming subsystem, but do not prove the exact open/read sequence or container semantics.

## Next checks

- Inspect the `MSVp` header and music type-1 payload structure further, keeping the observed range associations separate from field semantics.
- Check executable references around the container suffix strings before claiming how the tables are consumed at runtime.
