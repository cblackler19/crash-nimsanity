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

In record zero, words 1 and 2 are `309024` and `12812288` for `AMERICAN.MH`, and `309024` and `221464576` for `MUSIC.MH`. In both cases their sum is 224 bytes less than the length of the correspondingly named `.MB` file. This repeated relationship is a lead for checking offsets and ranges, not yet a confirmed interpretation of either word.

Later records differ between the two tables, including small values in word 0 and values that vary in words 1, 2, and 4. No field names or asset types have been assigned.

In `MUSIC.MH`, records 7 through 10 have word 0 equal to `1`. Their word 2 values are `0`, `3932160`, `8912896`, and `13631488`; for each record after the first, word 2 equals the prior record's word 2 plus its word 1. This is consistent with a cumulative range or offset field across those four records, though the address space and meaning are still unknown.

## `.BH` / `.BD` and executable clues

`CRASH.BH` begins with the little-endian word `1281` and contains readable paths such as `Startup\Fonts\Crash.psf` and language resources, interleaved with binary fields. The record boundaries and the meaning of the initial word have not been established. `CRASH.BD` begins with `03 00 00 00`; this is not enough to identify its format.

The local game executable contains strings including `.BH`, `.BD`, `%s.mb`, `Crash6\Crash`, `Crash6\Music`, `STREAM.IRX`, `CDVDSTM.IRX`, and `streaming options`. These strings are consistent with the game referencing the named files and a streaming subsystem, but do not prove the exact open/read sequence or container semantics.

## Next checks

- Compare all `.MH` records with ranges inside their `.MB` files, keeping the five words unnamed until bounds and repeated patterns support stronger claims.
- Determine `.BH` record boundaries and test candidate fields against paths and offsets in `.BD` without extracting or changing the source image.
- Check executable references around the container suffix strings before claiming how the tables are consumed at runtime.
