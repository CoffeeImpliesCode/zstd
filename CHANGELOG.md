# Changelog

All notable changes to the **Zig package** in this repository are recorded
here. Upstream's own release notes are in [`src/CHANGELOG`](src/CHANGELOG) and
are not duplicated; this file records what the *packaging and the facade* did,
never what Zstandard did.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package uses its own numbering: entries are integers, and an entry is
added in the same change as the thing it describes.

## Status vocabulary

Every entry below is `SOURCE-CONFIRMED` or `PENDING-VERIFICATION`. **No entry
in this file records a passing gate.** An entry moves from
`PENDING-VERIFICATION` to `VERIFIED` only by a driver edit beside an observed
run, recording the command, the optimize mode, the target, the exit code, the
date and the receipt path. No such edit has been made: the gates named in
entry `[5]` were run by a worker, not by the driver, and only the driver moves
them.

Two entries are exceptions and say so in their own text: entries `[3]` and
`[5]` record **observed** `cross-test` runs with their run ids and their
receipt paths. They claim no cell as verified, and they move nothing to
`VERIFIED`.

---

## [5] — 2026-10-05 — One macro width fixed, and the 53-platform matrix re-run

### Fixed

* **`zig/root.zig:994`** now instantiates the translated `ZSTD_COMPRESSBOUND`
  (`src/lib/zstd.h:249`) at `u64` and casts the result back, instead of
  instantiating it at `usize`:

  ```zig
  return @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(u64, src_len))));
  ```

  `translate-c` emits that macro as `(@as(c_int, 128) << @as(c_int, 10)) -
  srcSize`, and Zig will not reconcile `c_int` with a 32-bit unsigned argument
  in that position. The public signature `compressBoundConst(src_len: usize)
  usize`, the number it returns and `tests.zig` are all unchanged.
  `PENDING-VERIFICATION`

* **`zig/root.zig`** — the doc comment of `compressBoundConst`, and nothing
  else: the diagnosis it carries is written in the past tense now that the line
  compiles on every target. `README.md` §3, `FORK-NOTES.md` §2.7 and §3 record
  the same run.

### Observed, not verified

* From the package root, with Zig 0.16.0 from the approved global cache, `-j8`
  and `--cache-dir` on approved scratch: `zig build`, `zig build test` (Debug),
  `zig build test -Doptimize=ReleaseSafe`, `zig build smoke` and `zig build
  check` each exited **0**, and both test modes printed `6/6 steps succeeded;
  22/22 tests passed`.
* `tools/check-provenance.sh` exited **0**.
* **`cross-test` over all 53 cells exited 0**: `status=partial pass=20 fail=0
  build_only=33 partial=0`. Entry `[3]` recorded `pass 10 / build_only 20 /
  build_failed 23`. All 23 red cells are the cells this entry fixes; 10 of
  them gained an executor and ran 22/22 tests, and the other 13 are
  `build_only` because this host has no runner for them. `build_only` is
  coverage and is never counted as a pass. Run `20261005-195932-14976-9053` at
  `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd2/`. The same 53 cells
  were run once more after the documentation edits — run
  `20261005-201302-53233-31199` at
  `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd3/` — and it exited 0
  with the same `pass=20 fail=0 build_only=33 partial=0`, so that receipt
  covers the tree as it now stands.

### Not proved

  Entry `[3]`'s record is kept whole as history and nothing here rewrites it.
  No file under `src/` changed, no test was weakened or removed, and no cell
  count is rounded into another class.

---


## [4] — 2026-10-05 — `README.md` carries upstream's BSD copyright notice

### Changed

* **`README.md:168-207` now quotes `src/LICENSE:1-30` verbatim.** The front page
  named the licence choice and installed both of upstream's texts but never
  carried the copyright line, so a reader of the README alone saw a licence
  identifier with no holder. `tools/check-provenance.sh:174-178` asserts
  `Meta Platforms, Inc.` in `NOTICE.md`, `README.md` and `FORK-LICENSE.md`; the
  README was the one of the three without it.

  The quoted block is the whole of `src/LICENSE` — `BSD License`, `For
  Zstandard software`, `Copyright (c) Meta Platforms, Inc. and affiliates. All
  rights reserved.`, the three conditions and the disclaimer — copied out of the
  vendored file. No holder was paraphrased, no year invented, and no byte under
  `src/` was touched. The GPLv2 alternative is named as `src/COPYING`,
  unmodified.

  `SOURCE-CONFIRMED`

### Not proved

  Nothing about the build. No `zig build`, no test, no smoke, no consumer run and
  no cell of entry `[3]`'s matrix is moved by this entry, and it moves nothing to
  `VERIFIED`.

---

## [3] — 2026-10-05 — The published 53-platform matrix, run once and recorded

### Changed

* **`README.md` §3 and `FORK-NOTES.md` §2.7 carry the outcome of one full
  53-platform `cross-test` run**: the command, the exit code, the receipt path,
  the per-cell classification, and the cause of the red cells. No source, no
  header, no build graph, no test and no example changed in this entry.

### Known gaps, recorded rather than hidden

* **The matrix is red. 23 of 53 cells fail to build, and the cause is one line
  of this package.** `cross-test` exited 1 over `target_count: 53`: 10 `pass`
  with 22/22 tests each, 20 `build_only` because this host has no runner for
  them, and 23 `build_failed` with one compilation error apiece. The 23 are
  exactly the cells whose pointer width is 32 bits, and each fails at column 314
  of the translated `ZSTD_COMPRESSBOUND`, reached from `zig/root.zig:979` by
  `tests.zig:774`. The one-line change and its receipt are in `FORK-NOTES.md`
  §2.7. **That change is not applied here.** No 32-bit cell is claimed as
  refused, as build-only, or as passing, and no cell count here is rounded into
  another.

  *Superseded by entry `[5]`.* That entry applied the one line at
  `zig/root.zig:994` and re-ran the same 53 cells: exit 0, 20 `pass`, 33
  `build_only`, 0 `build_failed`. Everything above is the first run's record
  and is kept unedited.

---

## [2] — 2026-10-05 — Completion of the template set, and three defects closed

### Added

* **`smoke.zig`**, the deterministic example. Its expected values are stated
  literals from four places outside the program: RFC 8878's normative text,
  upstream's own `golden-decompression/` corpus, the fixture frames
  `fixtures/PROVENANCE.md` records with their producers, and the version, level
  range and header-size constants the headers themselves declare. It exits
  non-zero on a mismatch.

  `PENDING-VERIFICATION`

* **`consumer/`**, as a complete separate package: `build.zig`, `build.zig.zon`
  and `src/main.zig`. It is reached through a relative path rather than a fetch,
  and it proves interoperability from outside this package three ways — a
  **recorded digest** it reproduces (the SHA-256 of its own copy of the payload
  against the value `fixtures/SHA256SUMS` records), a **specification** (two
  frames built byte by byte from RFC 8878, with the header fields checked against
  the RFC by hand before decompression), and **two other programs' output**
  (frames the `zstd` CLI v1.5.7 and `python-zstandard` 0.22.0 produced, read at
  run time from the repository's fixture paths). A run that decoded no external
  frame exits non-zero rather than reporting success for a check that did not
  run.

  `PENDING-VERIFICATION`

* **`UPSTREAM.md`**, **`tools/check-provenance.sh`**, **`NOTICE.md`**,
  **`FORK-LICENSE.md`**, **`README.md`**, **`README.zig.md`**,
  **`package.nix`**, **`flake.nix`**, **`devenv.nix`**, **`devenv.yaml`**,
  **`.envrc`**, **`.gitignore`**, **`cross-test.profile.sh`** and
  **`.github/workflows/verify.yml`**.

  `SOURCE-CONFIRMED` for the records; `PENDING-VERIFICATION` for the packaging
  and the workflow.

* **`fixtures/PROVENANCE.md`**, the record that gives every fixture its
  producer, its version and its digest — and that states plainly that the CLI
  and the Python binding are **one implementation behind two producers**, not
  two independent encoders, with the three byte-identity groups laid out so a
  reader can see the duplication rather than infer it.

  `SOURCE-CONFIRMED`

### Changed

* **`build.zig.zon` `.paths` no longer names `flake.lock`.** It named a file that
  is not in this tree, and `zig fetch` hashes every named path — so the manifest
  would have failed a fetch instead of recording an absence. The comment now says
  the lock belongs to the driver and is absent until the driver writes one.
  `tools/check-provenance.sh` checks both directions from now on: every named
  path must exist, and a lock that now exists but is not named is an error.

  `SOURCE-CONFIRMED`

* **`.gitignore` keeps upstream's list and re-anchors five entries.**
  `src/.gitignore` ships in the tarball and is reproduced here, because upstream's
  conventions are upstream's business. Four entries in it — `/zstd`, `zstdmt`,
  `bin/` and the `contrib/linux-kernel/linux/`, `projects/` forms — are written
  as if the file lived at the repository root, and at *this* repository root
  `/zstd` is this package's own source directory. They are re-anchored to `src/`,
  which keeps each convention and fixes what it points at. Nothing is removed.

* **`.gitignore` adds a fork re-inclusion block, and it is not optional.**
  Upstream's list contains `*.zst`, and eleven of this package's fixtures are
  `.zst` files under `fixtures/` — the RFC 8878 frames and the frames the CLI
  and the binding produced. A fork-owned `!fixtures/**` block appears at the end.
  An ignored fixture is a missing fixture, and `@embedFile` on a missing file is
  a build failure that looks like a bug in the build graph.

### Fixed

* **`fixtures/SHA256SUMS` cannot be verified as a whole, and the gate now says
  so.** Its line 1 is
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  fixtures/SHA256SUMS`,
  and `e3b0c442…b855` is the SHA-256 of zero bytes, not of that file. A manifest
  cannot contain its own digest — writing the digest into the file changes the
  file — so that entry is unsatisfiable by construction and
  `sha256sum -c fixtures/SHA256SUMS` reports it as a mismatch on every run.

  `tools/check-provenance.sh` now **names line 1 in its output and prints why it
  is excluded**, before checking anything else; it verifies the other 19 data
  entries; it compares the manifest's file set against the directory so an
  unrecorded addition is caught; and it never reports the manifest as a whole as
  checked. Nothing inside the manifest is edited: the honest fix is to drop the
  self-reference and record the manifest's own digest in `UPSTREAM.sha256`, and
  that is the owner's call.

* **`fixtures/PROVENANCE.md` was cited by `tests.zig` and did not exist.**
  `tests.zig:59` names it as the record that proves the CLI and the binding
  produced byte-identical frames. It is written by this change, and the
  provenance gate now fails if it is deleted or if any citing file stops citing
  it.

### Known gaps, recorded rather than hidden

* **No release-tarball digest and no commit SHA**, because neither can be read
  out of anything in this tree. What is recorded and checked is the import
  aggregate over all 637 files.
* **The compiled-unit count is 34, not 33.** A reader who counts only the `.c`
  files reaches 33 and concludes the manifest is wrong; the thirty-fourth is
  `decompress/zstd_decompress_amd64.S`, collected by its own wildcard at
  `libzstd.mk:156`. `UPSTREAM.md` states both numbers and where the extra unit
  comes from.
* **`fixtures/SHA256SUMS` keeps its unsatisfiable self-reference.** Excluded and
  explained by the gate, not silently dropped and not rewritten.
* **The 53-platform matrix is not in CI**, and neither is system-library mode.
  Both need a host-local tool or a machine the stock runner does not have.
* **`src/build/LICENSE` is a zero-byte placeholder** with the SHA-256 of the
  empty file. It grants nothing, and `NOTICE.md` says so rather than letting a
  scanner report it as licensed.

---

## [1] — 2026-10-05 — First recorded state of the package

Recorded here for completeness; the source, build graph, facade, tests and
runtime route that entry describes were landed by an earlier change in this
wave. **No gate was run for that change either, and none is claimed here.**

| Piece | What it is | Status |
|---|---|---|
| `build.zig` | compiles the 34-unit closure (33 `.c` plus `decompress/zstd_decompress_amd64.S`) through Zig 0.16.0 with `-std=c99` pinned, and assembles that one `.S` on `x86_64` only | `PENDING-VERIFICATION` |
| `zig/root.zig` | the typed module over the translation of `zig/translate.h` | `PENDING-VERIFICATION` |
| `runtime/` | the load-at-runtime route, six files | `PENDING-VERIFICATION` |
| `tests.zig` | the behavioural suite, grouped by the oracle each group rests on | `PENDING-VERIFICATION` |
| `UPSTREAM.sha256` | all 637 imported files, one line each | `SOURCE-CONFIRMED` |

**Why `pool.c` is compiled without `ZSTD_MULTITHREAD`.** `dictBuilder/cover.c`
and `dictBuilder/fastcover.c` both call `POOL_create` from
`ZDICT_optimizeTrainFromBuffer_*` whenever `nbThreads > 1`, and the four pool
entry points are referenced unconditionally in those units, so the archive does
not link without the file. Its single-threaded arm is a complete
implementation, which is why a consumer asking for `nbThreads > 1` still gets a
correct answer from a single-threaded build.

**Why there is no generated header here, unlike the zlib SDK.** Zstandard has no
configure step and no `zconf.h` equivalent: all three public headers ship exactly
as upstream wrote them, and the build compiles them directly. The only generated
artefact is the runtime dispatch, which lands in the build cache.