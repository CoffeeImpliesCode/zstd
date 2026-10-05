<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Notice

Two separate things are recorded here: what the canonical native source is and
which grant covers each of its files, and what this fork wrote on top of it.
[`FORK-LICENSE.md`](FORK-LICENSE.md) carries the grant for the second group.

**A single label is wrong for this tree, and saying so at the top is the point.**
Upstream publishes two licences and lets the recipient choose; this tree also
carries material under a *third* term, vendored from GNU coreutils. The
inventory below is per file and per directory for that reason.

## The upstream term: BSD-3-Clause **or** GPL-2.0, at the recipient's option

| | |
|---|---|
| `src/LICENSE` | **BSD 3-Clause**, `Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.` |
| `src/COPYING` | **GNU General Public License, Version 2, June 1991** |
| `src/lib/libzstd.mk:2-8` | the statement of the dual grant |
| `src/README.md:7-8` | the same, in prose |

The build file says it in so many words:

> This source code is licensed under both the BSD-style license (found in the
> LICENSE file in the root directory of this source tree) and the GPLv2 (found
> in the COPYING file in the root directory of this source tree). You may select,
> at your option, one of the above-listed licenses.

**Both texts ship, both are installed, and both are digested.** `build.zig`'s
`licence_records` names `src/LICENSE` and `src/COPYING` separately and
`build.zig.zon` `.paths` carries the whole of `src`. A package that installed
only the BSD text and described the tree as BSD would have made the recipient's
choice for them and narrowed what upstream published; that is the failure mode
this inventory exists to prevent.

**For this fork's own files the BSD-3-Clause option was taken** — see
[`FORK-LICENSE.md`](FORK-LICENSE.md). That is the owner's choice, made under the
owner's per-project licence authorization, and it covers **only** fork-authored
material. It does not remove upstream's GPL alternative from `src/`.

### The BSD conditions, and what this repository does about each

* **Retain the copyright notice.** Carried in `src/LICENSE`, in
  `src/lib/libzstd.mk:2`, in the header block of `src/lib/zstd.h` and
  `src/lib/zdict.h`, and in every record here that names an upstream copyright.
* **Include the disclaimer.** Carried in `src/LICENSE` verbatim.
* **No endorsement.** This repository asserts no endorsement by Meta Platforms,
  Inc. or by any contributor. `build.zig` builds the library; it does not
  represent as an official build of anything.

## Inventory of the upstream files

637 files, every one digested in [`UPSTREAM.sha256`](UPSTREAM.sha256) and
included in the import aggregate recorded in [`UPSTREAM.md`](UPSTREAM.md).

| Path | Files | Term | Notice in the file |
|---|---:|---|---|
| `src/lib/` | 102 | **BSD-3-Clause OR GPL-2.0** | the dual grant block, `src/lib/libzstd.mk:1-9` and the headers |
| `src/programs/` | 40 | **BSD-3-Clause OR GPL-2.0** | the dual grant block |
| `src/zlibWrapper/` | 18 | **BSD-3-Clause OR GPL-2.0** | the dual grant block — upstream's own zlib-compatibility shim, not a copy of zlib |
| `src/contrib/` | 120 | **mixed — see "Per-file exceptions"** | mostly the dual grant block; `linux-kernel/` is its own thing |
| `src/doc/` | 20 | **BSD-3-Clause OR GPL-2.0** | prose; the dual grant is the file-level rule |
| `src/examples/` | 14 | **BSD-3-Clause OR GPL-2.0** | the dual grant block |
| `src/build/` | 77 | **BSD-3-Clause OR GPL-2.0** | `src/build/LICENSE` is a **zero-byte file** — see below |
| `src/.github/` | 11 | **BSD-3-Clause OR GPL-2.0** | upstream's own CI definitions, retained and never run |
| `src/tests/` | 220 | **mixed — see "Per-file exceptions"** | `src/tests/gzip/` is **GPL-2.0-or-later, © FSF**, vendored from GNU coreutils |
| the 15 files in the root of `src/` | 15 | **BSD-3-Clause OR GPL-2.0** | `src/LICENSE` and `src/COPYING` *are* the grants; the rest are covered by them |

The counts are the whole of `src/` and they add up to 637.

`README.upstream.md` is a fork-side copy of `src/README.md`, byte-identical to
it and deliberately **not** a 638th digested file: `UPSTREAM.sha256` records
`src/README.md` alone, and `tools/check-provenance.sh` is what proves the copy
has not drifted.

## Per-file exceptions

**This tree does not reduce to "BSD-3-Clause", and there are three places where
that is true.**

### 1. `src/tests/gzip/` — 23 files, **GPL-2.0-or-later, © Free Software Foundation**

This is GNU coreutils' `gzip` testsuite, vendored into Zstandard's test tree so
that upstream can check its `.gz` interoperability. It is not Zstandard's code
and it is not under the dual grant. Every one of its shell scripts carries the
FSF's own notice, at `src/tests/gzip/test-driver.sh:5-13`:

> Copyright (C) 2011-2015 Free Software Foundation, Inc.
>
> This program is free software; you can redistribute it and/or modify it under
> the terms of the GNU General Public License as published by the Free Software
> Foundation; either version 2, or (at your option) any later version.

Sixteen of the files in that directory carry the GNU General Public License
marker; `hufts-segv.gz` is a compressed test input.

**The practical rule: none of it reaches a shipped binary.** `build.zig`
compiles nothing under `src/tests/`, and nothing under `src/tests/` is
installed. A consumer who builds or runs upstream's `.gz` interoperation tests
from this tree is using GPL-2.0-or-later material, and that is their choice to
make with their own hands visible.

### 2. `src/build/LICENSE` — **a zero-byte file**

`src/build/LICENSE` is **0 bytes**. Its digest in `UPSTREAM.sha256` is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, which is
the SHA-256 of zero bytes — the digest is a fact about the file's emptiness, and
the file grants nothing by itself.

This is a placeholder in upstream's tree for the per-build-system licence
position of the CMake and meson packaging. It is recorded here rather than
passed over because a zero-byte file with a licence name is exactly the kind of
thing a scanner reports as "licensed" when it is not. **The terms that govern
everything under `src/build/` are the two texts at `src/LICENSE` and
`src/COPYING`**, carried by the files themselves.

### 3. `src/contrib/linux-kernel/` — a kernel-targeted branch with its own notes

`src/contrib/linux-kernel/` is upstream's branch for the Linux kernel. Its
`linux_zstd.h` carries a kernel-flavoured SPDX header, and
`src/contrib/linux-kernel/test/include/linux/xxhash.h` is a vendored copy of
the kernel's `xxhash.h` carrying the kernel's GPL-2.0 text. The directory ships
its own `README.md` and `Makefile` and is not compiled by `build.zig`.

Under the dual grant this is upstream's own work, and it is listed here because
its licence *headers* are deliberately not the dual-grant block — a consumer
grepping for the standard header will not find it, and a consumer who intends to
submit it upstream is working under a different regime entirely.

### Everything else

Every other file under `src/` is under the dual grant as stated at
`src/lib/libzstd.mk:2-8`, and most of them say so in their own header. Upstream's
own `src/tests/test-license.py` is the script that checks exactly that — its
`RELDIRS` list at `:21-25` names `doc`, `examples`, `lib`, `programs` and more,
and it greps the source files for the grant block. This repository does not run
it (it is upstream's CI script, not a gate here), but it is the record of
upstream's own convention and it is retained and digested.

**There is no LGPL component, no Apache-2.0 component and no public-domain
dedication** anywhere in this tree.

## What this fork changed in upstream files

**Nothing.** No file under `src/` has been edited, re-entered or reformatted,
and `src/README.md` is byte-identical to the tarball's copy of itself in
`README.upstream.md`. `UPSTREAM.sha256` plus the exact-file-set check in
`tools/check-provenance.sh` are what make that checkable rather than asserted,
and any future native change has to move those digests in the same change, with
a numbered entry in [`CHANGELOG.md`](CHANGELOG.md).

Unlike zlib there is no generated header in this package's build, so there is
nothing that could be mistaken for an upstream edit. `pkg-config` metadata is
derived from upstream's own `src/lib/libzstd.pc.in` template at build time and
lands in the build cache, never in this tree.

**`STATUS`: `SOURCE-CONFIRMED`** from the recorded digests — a claim about
bytes and about what this file asserts about them, not about a build. No build
result is recorded here. [`README.md`](README.md) carries the observed runs,
each row naming what was run and what came out, and marks every gate it does
not cover `PENDING-VERIFICATION`. Those are that file's observations; this
inventory does not restate or extend them.

## Fork-specific notice

Every file below was written for this fork. None of it carries an upstream
copyright, no upstream permission is claimed over it, and it is released under
the **BSD-3-Clause** terms recorded in [`FORK-LICENSE.md`](FORK-LICENSE.md):

* `build.zig`, `build.zig.zon`, `.gitignore`, `cross-test.profile.sh`,
  `.github/workflows/verify.yml`
* `zig/root.zig`, the typed facade, and `zig/translate.h`, the aggregate
  translation header this build runs `translate-c` over
* `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`,
  `consumer/src/main.zig`
* `runtime/` — the load-at-runtime route, as the six files it holds today.
  `loader.zig` is the reusable state machine and platform layer, holding no
  per-SDK name; `library.zig` is this SDK's descriptor, the namespaced
  synchronization binding and the one load-time check; `graph.zig` is the build
  half that wires them together and substitutes `createModule` for the
  translation's own; `generate.zig` is the build-time generator that writes the
  dispatch from the real translation output for the target being built, through
  `Run.addOutputFileArg`, so the generated file lands in the build cache and
  this directory holds no generated source. `sync.h` and `sync.c` are the two C
  files that give the loader its process-global mutex, condition variable and
  thread identity under an `RT_SYNC_PREFIX` this SDK sets; `sync.c` is compiled
  into the dispatch and `sync.h` is the only header the route compiles C
  against. All six are fork work under this grant.
* `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`
* `tools/check-provenance.sh`
* `fixtures/` — the interoperation fixture set and its provenance record. Every
  byte under `fixtures/` other than `PROVENANCE.md` was **produced by another
  program**, not authored here: by the `zstd` CLI v1.5.7, by `python-zstandard`
  0.22.0 over libzstd 1.5.7, and — for `fixtures/rfc8878/` — written byte by
  byte from RFC 8878's normative text and nothing else.
  [`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) names the producer, the
  version and the digest of each file, and states plainly that the CLI and the
  binding are **one implementation behind two producers**, not two independent
  encoders. Those frames remain under their producers' terms, which are not
  this repository's to grant.
* this file, `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
  `FORK-LICENSE.md`, `CHANGELOG.md`, `FORK-NOTES.md`

`flake.lock` is **absent** from this tree and `build.zig.zon` `.paths` does not
name it — the driver owns locks, and `zig fetch` hashes the named paths, so
naming an absent file would fail the fetch rather than record an absence.
`devenv.lock` is absent for the same reason: `devenv.yaml` pins its nixpkgs
revision in source. `tools/check-provenance.sh` checks both directions — every
path `.paths` names must exist, and a lock that now exists but is not named is
an error.

### Which of those files carry the SPDX tag, and which do not

The fork-authored files that carry `SPDX-License-Identifier: BSD-3-Clause` on
their own first comment line: `build.zig`, `build.zig.zon`, `zig/root.zig`,
`zig/translate.h`, `tests.zig`, `smoke.zig`, `consumer/build.zig`,
`consumer/build.zig.zon`, `consumer/src/main.zig`, all six files of `runtime/`,
`tools/check-provenance.sh`, `package.nix`, `flake.nix`, `devenv.nix`,
`devenv.yaml`, `.envrc`, this file, `UPSTREAM.md` and
`fixtures/PROVENANCE.md`. That set was read out of the files rather than
assumed.

The rest carry the same grant without a tag, and are named here rather than left
for a scanner to read as unlicensed. Three are comment-capable text whose grant
is this inventory and [`FORK-LICENSE.md`](FORK-LICENSE.md):
`cross-test.profile.sh`, `.github/workflows/verify.yml` and `.gitignore`. The
five documentation and digest records — `README.md`, `README.zig.md`,
`UPSTREAM.sha256`, `CHANGELOG.md` and `FORK-NOTES.md` — are prose and data with
no comment position a tag is expected in.

**Note on the identifier.** The package-level tag is `BSD-3-Clause`, which is
what this fork took for its own files and what `build.zig.zon` declares. It does
**not** describe `src/`, which is dual, and a consumer reading only
`build.zig.zon`'s header would otherwise conclude that the whole package is
BSD-3-Clause. `UPSTREAM.md`, "The dual grant, and which option this package
took", and this inventory are where that is corrected, and `tools/
check-provenance.sh` fails if either upstream licence text stops being present.

Upstream's attribution obligation is unaffected by any of this: a consumer who
receives a libzstd binary, static or shared library, or the headers, still owes
the Meta Platforms notice, and the installed tree carries it alongside the
GPLv2 text. `share/licenses/zstd/` holds `src/LICENSE`, `src/COPYING`,
`src/README.md` and `README.upstream.md` — both upstream grants and upstream's
own README — together with `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`,
`UPSTREAM.sha256`, `FORK-NOTES.md` and `CHANGELOG.md`: ten files, exactly
`licence_records` in `build.zig:515-526`, which is also what `package.nix`
installs because it runs the same `zig build install`.