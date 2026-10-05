<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Upstream

Which upstream this SDK is built from, what was taken from it byte for byte,
what is deliberately *not* taken, and what the dual grant covers.

## Canonical source

| | |
|---|---|
| Project | Zstandard, by Yann Collet, Meta Platforms, Inc. and affiliates |
| Authoritative site | <https://facebook.github.io/zstd/> |
| Version | **1.5.7** |
| Release date | 2025-02 |
| Import form | release source tree, unpacked into `src/` |
| Grant | **BSD-3-Clause _or_ GPL-2.0**, at the recipient's option |

The version and the date are `SOURCE-CONFIRMED`, read out of the imported files
rather than out of a web page this repository never fetched:

* `src/lib/zstd.h:112-114` — `#define ZSTD_VERSION_MAJOR 1`,
  `#define ZSTD_VERSION_MINOR 5`, `#define ZSTD_VERSION_RELEASE 7`
* `src/lib/zstd.h:115` — `#define ZSTD_VERSION_NUMBER (…1*100*100 + …5*100 + …7)`,
  which is how the three numbers above become one number
* `src/CHANGELOG:1` — `V1.5.7 (Feb 2025)`

### What is *not* recorded here, and why

**No sha256 of the release tarball, and no commit SHA.** Neither can be read out
of anything in this repository:

* The tarball itself is not present. `src/` is the *unpacked* tree and no
  `.tar.gz` was kept, so its digest cannot be computed here even in principle.
  Only the digests of the 637 extracted files can be, and those are what
  [`UPSTREAM.sha256`](UPSTREAM.sha256) holds.
* The upstream Git repository is not part of this import. Zstandard's canonical
  source is the release tarball, not a clone, so there is no commit SHA to
  record.

That is an honest gap rather than a missing field. A digest written here would
be a number this repository could neither reproduce nor check, and one guessed
from a remembered download page would be worse than an absence.

| | |
|---|---|
| Upstream files imported | **637** |
| Aggregate digest | `f78cd4bf7e7ce2a67f4eb3ead4ede134057771f0a4754d79397112d9e433b7d7` |

`UPSTREAM.sha256` has **638** lines: the 637 upstream files, plus the digest of
`fixtures/SHA256SUMS` itself. That last entry is not upstream material and is
not counted above; it is in the manifest because a manifest cannot record its
own digest, so the manifest's digest belongs in the one file that already
records digests. See [`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md).

The aggregate is the sha256 of the digest column of `UPSTREAM.sha256`, in file
order. It is derived, not asserted:

```sh
awk '/^[0-9a-f]{64}  / { print $1 }' UPSTREAM.sha256 | sha256sum
```

It changes if any entry is added, removed, reordered or edited.
`tools/check-provenance.sh` recomputes it and compares it against the value
recorded here, so the two records cannot disagree.

**`STATUS`: `SOURCE-CONFIRMED`.** Every digest was computed by reading bytes
that are present. No build, test, smoke run or cross-target check was executed
to produce any of them; the observed runs are recorded in
[`README.md`](README.md) and are `PENDING-VERIFICATION` until the driver
observes them.

## The dual grant, and which option this package took

Upstream publishes **two** licences and lets the recipient choose. That is not
an ambiguity in the tree, it is the grant:

* `src/LICENSE` — the BSD 3-Clause text, `Copyright (c) Meta Platforms, Inc. and
  affiliates. All rights reserved.`
* `src/COPYING` — the GNU General Public License, Version 2, June 1991.
* `src/lib/libzstd.mk:2-8` states it in the build file itself: *"This source
  code is licensed under both the BSD-style license (found in the LICENSE file
  in the root directory of this source tree) and the GPLv2 (found in the COPYING
  file in the root directory of this source tree). You may select, at your
  option, one of the above-listed licenses."*
* `src/README.md:7-8` says the same in prose: a dual **BSD OR GPLv2** licensed C
  library.

**Both texts are installed, and both travel.** `build.zig`'s `licence_records`
names `src/LICENSE` and `src/COPYING` separately, and `build.zig.zon` `.paths`
carries the whole of `src`. Installing one text and dropping the other would
narrow the grant upstream published rather than report it, and a package that
described itself as "BSD" while shipping only `LICENSE` would be making a
choice on the recipient's behalf.

**For this fork's own files, the choice made is BSD-3-Clause** — see
[`FORK-LICENSE.md`](FORK-LICENSE.md). That choice is the owner's and covers only
fork-authored material. It does not remove upstream's alternative, and nothing
in this repository treats the BSD option as the only one a recipient has.

## What upstream is

A fast lossless compression algorithm, targeting real-time compression at
zlib-level speed with better ratios. The format is standardised as **RFC 8878**
and is stable; the reference implementation here is the one that specification
describes.

Beyond the library, the release ships a substantial amount that this package
**does not compile**: a command-line utility (`zstd`, `pzstd`), the
`zlibWrapper/` compatibility shim, `contrib/` with roughly two dozen
subdirectories, `tests/` including the golden-decompression corpus, `build/` with
CMake and meson build systems and Visual Studio project trees, `doc/`,
`examples/` and both licence texts. All of it is imported and all of it is
digested. See [`NOTICE.md`](NOTICE.md) for the per-file inventory and its
per-file exceptions.

There is no external dependency. Zstandard's C library needs only libc and,
where a consumer asks for it, threads.

## What is in the imported tree

637 files under `src/`, imported whole. Nothing is dropped for size, and nothing
is dropped for being uncompiled by this fork.

| Path | What it is |
|---|---|
| `lib/common/` | 8 units — errors, entropy, FSE, Huffman, memory, threading, the xxHash port, trace |
| `lib/compress/` | 14 units — the match finders and the entropy stages |
| `lib/decompress/` | 4 units, plus the AMD64 assembly decoder `zstd_decompress_amd64.S` |
| `lib/dictBuilder/` | 4 units — `zdict` plus the COVER algorithm and its two sorts |
| `lib/legacy/` | 7 units — v0.5, v0.6 and v0.7 decoders, retained but only three compiled |
| `lib/deprecated/` | 3 units — retained, never compiled by this package |
| `lib/zstd.h`, `lib/zstd_errors.h`, `lib/zdict.h` | the three public headers |
| `lib/Makefile`, `lib/libzstd.mk`, `lib/libzstd.pc.in`, `lib/module.modulemap`, `lib/BUCK` | upstream's own build, packaging and module description |
| `programs/` | the `zstd` CLI and `pzstd` |
| `zlibWrapper/` | a shim exposing the zlib API over Zstandard |
| `tests/`, `tests/golden-decompression/`, `tests/golden-decompression-errors/` | upstream's suite, including the golden corpus `tests.zig` embeds |
| `contrib/` | contributed tools, bindings, the Linux-kernel branch and the seekable-format shim |
| `build/` | CMake, meson, Visual Studio and single-file-library build trees |
| `doc/` | the format specification, the manual, the educational decoder and the errata |
| `examples/` | twelve example programs |
| `LICENSE`, `COPYING` | **both** of upstream's grants |
| `README.md`, `CHANGELOG`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `TESTING.md`, `Makefile`, `Package.swift` | upstream's own documentation and top-level build |

Per-file digests are in [`UPSTREAM.sha256`](UPSTREAM.sha256), which is the
complete set and not a selection.

## The compiled closure, as upstream lists it

`src/lib/libzstd.mk:149-153` collects four directories by wildcard:

```make
ZSTD_COMMON_FILES     := $(sort $(wildcard $(LIB_SRCDIR)/common/*.c))
ZSTD_COMPRESS_FILES   := $(sort $(wildcard $(LIB_SRCDIR)/compress/*.c))
ZSTD_DECOMPRESS_FILES := $(sort $(wildcard $(LIB_SRCDIR)/decompress/*.c))
ZSTD_DICTBUILDER_FILES:= $(sort $(wildcard $(LIB_SRCDIR)/dictBuilder/*.c))
ZSTD_DEPRECATED_FILES := $(sort $(wildcard $(LIB_SRCDIR)/deprecated/*.c))
ZSTD_LEGACY_FILES     :=
```

Expanded against this tree, those wildcards collect **8 + 14 + 4 + 4 = 30**
`.c` files. `ZSTD_LEGACY_FILES` is empty by default and is filled
conditionally; this build adds three of the seven `legacy/` units, for **33
compiled `.c` files** — the closure `build.zig` compiles, as five named arrays
rather than as a wildcard, because a wildcard would silently pick up a file
upstream adds later.

**The compiled-unit count is 34, and the two numbers are not in conflict.**
`build.zig:101` states it as `8 + 14 + 4 + 1 + 4 + 3 = 34`, and the `1` is
`src/lib/decompress/zstd_decompress_amd64.S`: it is collected by its own
wildcard at `libzstd.mk:156` rather than by the four `.c` wildcards, and
`libzstd.mk:163` appends it to `ZSTD_DECOMPRESS_FILES` unconditionally because
`ZSTD_NO_ASM` defaults to 0 (`:57`). So the closure is 33 C files plus one
assembly file, and a reader who counts only the `.c` files will be one short of
the number `build.zig` and `build.zig.zon` both use.

**`legacy/` and `deprecated/` are retained and mostly uncompiled on purpose.**
Three of the seven `legacy/` units are compiled so that a v0.5-to-v0.7 frame
decodes; the other four and all of `deprecated/` are retained because they are
part of upstream's release. Nothing was dropped.

The **AMD64 assembly decoder** is a separate case and it is worth being exact
about: `src/lib/decompress/zstd_decompress_amd64.S` is collected by its own
wildcard at `libzstd.mk:156`
(`ZSTD_DECOMPRESS_AMD64_ASM_FILES`), not by the four `.c` wildcards. `build.zig`
compiles it only on `x86_64`, which is what `decompressAssembly` at
`build.zig:489-491` decides.

## The three public headers

`src/lib/module.modulemap:2,27,32` names `zstd.h`, `zdict.h` and
`zstd_errors.h` as the three headers of the `libzstd` module, and
`zig/translate.h` includes the same three. `src/lib/module.modulemap` is
upstream's own packaging input and travels unedited.

`src/lib/zstd.h:47-51` splits the export surface: `ZSTDLIB_API` on the public
declarations and `ZSTDLIB_HIDDEN` on the internals. `build.zig`'s
`setVersionScript` exists so that a shared object exports the first set and not
the second; see `build.zig`'s module comment for where that mechanism is not
available and what the consequence is there.

## Nothing is generated at build time

Zstandard has no configure step, no generated header and no generated table.
That is not an omission in this port: there is nothing for a build step to
generate. `pkg-config` metadata is *derived*, not generated — `build.zig`'s
`add_pkg_config` reads every field out of `src/lib/libzstd.pc.in`, which is
upstream's own template and is present and digested in this tree.

Unlike zlib, there is no `zconf.h` equivalent: all three public headers are
checked in exactly as upstream ships them, and the build uses them directly.
Under `-Dsystem=true` it translates **the installed headers**, per `AGENTS.md` §4
and `WISDOM.md` W14; bundled new-release headers against an older installed
library compile and fail silently, so this package never does it.

## Upstream's test suite is here, and this package uses part of it

`src/tests/` is upstream's own suite and it is imported whole and unmodified.
Two parts of it are used by this package:

* **`src/tests/golden-decompression/`** — four frames real implementations
  produced, shipped by upstream. `tests.zig` embeds them **in place** with
  `@embedFile`, from the vendored copy, rather than copying them into
  `fixtures/`. `rle-first-block.zst` in particular is a fully independent known
  answer: its expected output follows from what RFC 8878 §3.1.1.2.2 says an
  RLE block means, not from anything derived here.
* **`src/tests/golden-decompression-errors/`** — frames upstream ships *and
  labels invalid*, so the expected answer is an error rather than an oracle.

Everything else under `src/tests/` is present and digested and is not run by
this package: upstream's CLI tests, fuzzer harness and dictionary tests belong
to upstream's own `make test`, which needs the programs this package does not
build. **No upstream test is deleted, modified or moved.**

## Nothing is vendored from a third party

There is no vendored dependency, no downloaded header and no external data
file. Every file here other than the 637 upstream files and the fixture set in
[`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) was written for this fork.

One directory is worth naming because it *looks* like a third party and is not:
`src/zlibWrapper/` is upstream's own zlib-compatibility shim, written by
upstream and shipped under the same dual grant as the rest of `src/`. It is
retained and uncompiled.

## The preserved upstream README

The tarball ships `README.md`, which is upstream's own project description and
**not** a fork README. It is preserved twice, unaltered:

* `src/README.md` — the imported original, exactly as the tarball carries it,
  11487 bytes, and digested in `UPSTREAM.sha256`.
* `README.upstream.md` — the same bytes under the name the rest of this
  repository uses for a preserved upstream README.

`tools/check-provenance.sh` fails if the two ever differ. The canonical fork
document is [`README.md`](README.md).

## Import mechanism

A release source tree, imported whole. There is no upstream Git history in this
tree, no commit SHA to record, and no patch series: the tree either matches the
import or a deviation is recorded. `UPSTREAM.sha256` plus the exact-file-set
check in `tools/check-provenance.sh` are what make that checkable rather than
asserted.

If a future wave re-syncs to another release, the correct sequence is: obtain the
new release source, replace the imported files, update `UPSTREAM.sha256` (and
the aggregate in this file), `UPSTREAM.md`, `NOTICE.md` and `README.md`, and add
a numbered `CHANGELOG.md` entry — in one change. The release digest belongs in
this table **only** once it has been read from a file someone can point at; it is
absent today because nothing in this repository carries it.