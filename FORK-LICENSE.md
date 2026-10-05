<!--
SPDX-License-Identifier: BSD-3-Clause
See NOTICE.md for what that identifier covers.
-->

# FORK-LICENSE.md — the grant for this fork's own files

[`NOTICE.md`](NOTICE.md) is the inventory: which files are upstream's, which are
this fork's, and which term covers each. This file is the grant itself, for the
second group only.

## 1. The native source is not covered by anything below

The 637 files under `src/` are Zstandard's, whole, and never edited. They are
**dual-licensed — BSD 3-Clause _or_ GPL-2.0, at the recipient's option** — under
the two texts at `src/LICENSE` and `src/COPYING`, as stated in
`src/lib/libzstd.mk:2-8`. Nothing in this file re-grants, narrows, widens or
conditions that term, and nothing here asserts that Meta Platforms, Inc., Yann
Collet or any named contributor wrote, reviewed or endorsed a line of fork code.

Three facts about that grant constrain what this fork may do, and belong here
rather than only in the inventory:

* **The grant is a choice, and both options ship.** This repository installs
  `src/LICENSE` and `src/COPYING` both, and neither is treated as the operative
  one for upstream's material. Section 2 below records which option the *fork's
  own files* take, which is a different question and does not narrow the first.
* **`src/build/LICENSE` is a zero-byte file** and grants nothing; the terms for
  everything under `src/build/` are the two texts at the top of `src/`.
* **Material under other terms is present and is inventoried.**
  `src/tests/gzip/` is GNU coreutils' `gzip` testsuite under GPL-2.0-or-later,
  and `src/contrib/linux-kernel/` ships kernel-flavoured headers.
  `NOTICE.md`, "Per-file exceptions", names them. None of it is compiled into
  any artefact this package delivers.

## 2. The fork-authored material

Everything else in this repository — the Zig build, the typed module and its
tests, the example, the consumer package, the runtime-loading route, the
packaging, the integrity script, the fixture provenance record and the
documentation — was written for this fork. The runtime-loading route is the six
files under `runtime/`: the reusable loader, this SDK's descriptor, the build
half that wires them together, the build-time generator, and the two C files
that supply the synchronization the descriptor binds. All six are fork work
under this grant; none of them is upstream material and none is derived from a
third-party source.

### Grant

**Those files are released under the BSD 3-Clause License**, which is the option
this fork took from upstream's dual grant. Its text is:

```
BSD 3-Clause License

For Zstandard software

Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The three conditions apply to these files as they apply to upstream's: keep the
notice, keep the disclaimer, and do not use a contributor's name to endorse
anything without permission. This repository endorses nothing.

### Authority for that grant

The owner of this repository authorized per-project licensing for fork-authored
additions as part of the SDK contract migration, with the term chosen per
project to match that project's primary upstream terms where that is
appropriate. Zstandard's primary upstream term is BSD-3-Clause — it is the first
of the two options named at `src/lib/libzstd.mk:5` and the one `src/LICENSE`
carries — so BSD-3-Clause is the choice for the fork's files.

**Choosing the BSD option for the fork's files does not remove upstream's GPL
alternative.** A recipient of the built library still has both options for
upstream's material, both texts are installed, and nothing in this repository
treats the BSD choice as the only one available. The authorization is recorded
here and in `NOTICE.md`; the term above is the owner's, reached by that
authorization and not by any upstream grant.

**The copyright line above is upstream's own and it is quoted, not claimed.** The
fork-authored files are covered by the permission statement in that text; the
copyright attribution in it belongs to Meta Platforms, Inc. and its contributors
and is reproduced here because the grant is Zstandard's own BSD text. This
repository asserts no authorship over that name, copyright or work. The owner of
this repository is deliberately not named as an individual holder: no individual
copyright holder is invented here.

### SPDX identifier

```
BSD-3-Clause
```

The plain registered identifier, with no `LicenseRef-` wrapper. That is a
deliberate distinction, not a shortcut, and here the boundary is sharper than
for a single-term upstream: a consumer scanning for `BSD-3-Clause` finds the
fork's files and stops reading, and would then miss that `src/` is dual-licensed
and that `src/tests/gzip/` is GPL-2.0-or-later. That is why the identifier here
describes **this file's grant only**, why `NOTICE.md` opens by saying a single
label is wrong for the tree, and why `tools/check-provenance.sh` fails if either
upstream licence text or the dual-grant statement in `src/lib/libzstd.mk` stops
being present.

`build.zig.zon`'s first line is `// SPDX-License-Identifier: BSD-3-Clause` and
says so in the next two lines: *"See FORK-LICENSE.md for what that identifier
covers, and NOTICE.md for the per-file inventory of the upstream material this
package ships."* The manifest does not present itself as a description of
`src/`.

Every fork-authored **source, build, packaging and script** file carries
`SPDX-License-Identifier: BSD-3-Clause` on its own first comment line; the file
list is in `NOTICE.md`. The documentation and digest records do not carry a tag:
they are prose and data, and `NOTICE.md` names each of them explicitly so that a
scanner finding no identifier in `README.md` reads a recorded reason rather than
an apparent gap.

### What this does not do

* It does not re-license, sublicense or add a condition to any file under
  `src/`, and it does not make `src/` BSD-only.
* It does not extend the BSD grant to `src/tests/gzip/`, which is
  GPL-2.0-or-later, nor to any other material in the tree under other terms.
* It does not assert that Meta Platforms, Inc., Yann Collet or any contributor
  authored, reviewed, endorsed or is affiliated with the fork's files.
* It does not discharge upstream's attribution obligation. A consumer who ships
  a libzstd binary, static or shared library, or the headers, still owes the
  Meta Platforms notice; see `NOTICE.md` for where it travels, beside the GPLv2
  text.
* It does not claim that BSD-3-Clause is the only term the owner could have
  chosen for independently authored work. It is the term chosen, and it is the
  first of the two options upstream itself offers.

## 3. Material carried but not authored here

**One category, and it is the fixture set.** `fixtures/` contains bytes produced
by other programs — the `zstd` CLI v1.5.7, `python-zstandard` 0.22.0 over
libzstd 1.5.7, and, for `fixtures/rfc8878/`, a byte-by-byte construction from
RFC 8878's normative text. Those bytes are not authored here and are not covered
by this grant. They remain under whatever terms their producers published them
under, and [`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) names the
producer, the version and the digest of every one of them. The only text this
repository authored in that directory is `fixtures/PROVENANCE.md` itself.

Apart from the fixture set there is **no** other carried material. This
repository vendors no third-party library, no downloaded header and no external
data file. The 637 files listed in `UPSTREAM.sha256` are the complete upstream
material, and nothing was added to them. The one directory that looks
third-party and is not — `src/zlibWrapper/` — is upstream's own zlib-compatibility
shim, written by upstream and shipped under the same dual grant as the rest of
`src/`.

The two files this build generates are not carried material either, and the
distinction is worth keeping exact rather than dropping a category to make the
sentence short. Under `-Druntime`, `runtime/generate.zig` writes the dispatch
and its patched translation through `Run.addOutputFileArg`, so both land in the
build cache rather than in this tree, and they are built from the translation of
`zig/translate.h` and upstream's own headers that this same build has just
produced for the target being built. Nothing is fetched to make them, no
third-party code is in them, and neither is installed or shipped: every file
under `runtime/` in this tree is a fork-authored file under section 2.

## 4. Why a separate file at all

`NOTICE.md` names which fork-authored files carry an `SPDX-License-Identifier`
line and which carry the same grant in prose without one. This file exists so
that the authority, the grant text and the limits of that grant live in one
place, next to the inventory — and so that the one fact a scanner is most likely
to get wrong about this package, that a `BSD-3-Clause` manifest sits on top of
a dual-licensed source tree containing a GPL test corpus, is stated in the file
that carries the grant rather than left to be inferred.