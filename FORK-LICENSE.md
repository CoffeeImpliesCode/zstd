<!--
SPDX-License-Identifier: BSD-3-Clause
See NOTICE.md for what that identifier covers.
-->

# Fork licence

This grant covers only fork-authored files; `NOTICE.md` is the per-file inventory.

## Exclusions

The 637 files under `src/` are upstream Zstandard files, unedited and dual-licensed **BSD 3-Clause or GPL-2.0**, at the recipient's choice, under `src/LICENSE` and `src/COPYING`. This grant does not re-license, narrow, widen or condition those terms; both texts are installed. `src/build/LICENSE` is zero bytes and grants nothing; files under `src/build/` retain the two upstream terms.

`src/tests/gzip/` is GNU coreutils' gzip testsuite under GPL-2.0-or-later. `src/contrib/linux-kernel/` carries kernel-flavoured headers. Neither is covered by this grant or compiled into a delivered artefact; `NOTICE.md` lists them. `src/zlibWrapper/` is upstream's zlib-compatibility shim, under the same dual grant as the rest of `src/`.

`fixtures/` contains output from other programs, not fork-authored material: the `zstd` CLI v1.5.7, `python-zstandard` 0.22.0 over libzstd 1.5.7, and bytes constructed from RFC 8878 for `fixtures/rfc8878/`. Those bytes are not covered by this grant; their producers' terms apply. `fixtures/PROVENANCE.md` identifies each producer, version and digest; it is the only text in that directory authored here. Outside the fixture set, the repository vendors no third-party library, downloaded header or external data file. `UPSTREAM.sha256` records the complete set of 637 upstream files.

Runtime mode generates a dispatch and patched translation in the build cache, not carried or installed. `runtime/generate.zig` builds them from this build's `zig/translate.h` and upstream headers. No third-party code is fetched or included.

## Fork-authored material and grant

The Zig build/module and tests, example, consumer, runtime, packaging, integrity script, provenance records and docs are fork-authored under this grant except for the exclusions above. The six runtime files are `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.c` and `runtime/sync.h`; none is upstream or third-party source.

### Grant

**Those files are released under the BSD 3-Clause License**, which is the option this fork took from upstream's dual grant. Its text is:

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

### Authority and attribution

The repository owner authorized BSD-3-Clause for fork-authored additions, matching this project's primary upstream term. Choosing it for the fork's files does not remove the recipient's BSD-or-GPL choice for upstream `src/`; this grant does not make that source BSD-only.

The quoted copyright line is upstream's, not claimed by this fork. Its attribution belongs to Meta Platforms, Inc. and its contributors. This repository does not assert that Meta Platforms, Inc., Yann Collet or any upstream contributor authored, reviewed, endorsed or is affiliated with fork files, and it does not invent an individual copyright holder for the fork.

Recipients of libzstd binaries (static or shared) or headers still owe Meta Platforms' notice; `NOTICE.md` locates it beside the GPLv2 text.

`BSD-3-Clause` identifies this grant only, not the whole tree: `src/` remains dual-licensed and `src/tests/gzip/` remains GPL-2.0-or-later. Upstream `src/base.h` has no SPDX identifier; `NOTICE.md` records that exception. Fork-authored source, build, packaging and script files carry `SPDX-License-Identifier: BSD-3-Clause`; the documentation and digest records do not carry a tag and are listed in `NOTICE.md`.
