<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Zstandard — 1.5.7, packaged for Zig 0.16

This repository is Zstandard 1.5.7 with a Zig build graph, a typed Zig module,
a runtime-loading route, a consumer package and a provenance gate around it.

Upstream's own project description is preserved byte for byte as
[`README.upstream.md`](README.upstream.md); it is upstream's text, not this
project's. Which upstream release this is, and **which of its two licences this
package ships**, is [`UPSTREAM.md`](UPSTREAM.md). What this fork changed is
[`CHANGELOG.md`](CHANGELOG.md).

**Status of every gate in this repository: `PENDING-VERIFICATION`.** No gate in
this repository has been verified by the driver. On 2026-10-05 a worker ran
`zig build`, `zig build test` in Debug and in `-Doptimize=ReleaseSafe`,
`zig build smoke`, `zig build check`, `tools/check-provenance.sh` and the full
53-platform `cross-test` matrix; each exited 0 and the receipts are named at the
gate they belong to. **No consumer run and no `wasm32-wasi` static cell has
been executed.** Every digest, size, line number and file count below is
`SOURCE-CONFIRMED`, read out of files in this tree.

---

## 1. Native-source deviations

**None.** No file under `src/` has been edited, re-entered, reformatted or
patched. All 637 files are upstream's, byte for byte, and every one is digested
in [`UPSTREAM.sha256`](UPSTREAM.sha256).

`UPSTREAM.sha256` records the digest of every file in `src/` and nothing else,
and `tools/check-provenance.sh` checks the digests, the exact file set (so an
addition is caught, which a checksum run alone cannot do), the import aggregate
recorded in `UPSTREAM.md`, and the fixture manifest.

Retained but **not** compiled, deliberately:

| Tree | Files | Why it is kept |
|---|---:|---|
| `src/programs/` | 40 | the `zstd` CLI and `pzstd`. They are upstream's programs, and this package's deliverable is the library |
| `src/zlibWrapper/` | 18 | upstream's own zlib-compatibility shim, written by upstream under the same dual grant. It looks like a third party and is not |
| `src/contrib/` | 120 | contributed tools, bindings, the Linux-kernel branch and the seekable-format shim |
| `src/build/` | 77 | CMake, meson, Visual Studio and single-file-library trees. `src/build/LICENSE` is a **zero-byte placeholder** — see [`NOTICE.md`](NOTICE.md) |
| `src/tests/` | 220 | upstream's own suite. Its `golden-decompression/` and `golden-decompression-errors/` subdirectories **are** used by `tests.zig`, embedded in place from the vendored copy |
| `src/.github/` | 11 | upstream's own CI definitions. Retained and never run: a fork does not push another maintainer's pipeline |
| `src/doc/` | 20 | the format specification, the manual, the educational decoder and the errata |

### Nothing is generated

Unlike zlib there is **no generated header** in this package's build. All three
public headers — `zstd.h`, `zdict.h`, `zstd_errors.h` — are checked in exactly
as upstream ships them and are compiled directly.

`pkg-config` metadata is *derived*, not generated: `build.zig`'s
`add_pkg_config` reads every field out of upstream's own
`src/lib/libzstd.pc.in`, which ships in the tarball and is digested. The output
lands in the build cache, never in this tree.

### One generated file under `-Druntime`

Under `-Druntime`, `runtime/generate.zig` writes the dispatch and its patched
translation through `Run.addOutputFileArg`, so both land in the build cache and
`runtime/` holds no generated source in this tree. That is the same as in every
other SDK in this workspace and is fork work, not an upstream edit.

---

## 2. Native-build deviations

Upstream ships several build systems and this repository uses **none** of them:

| Upstream's system | Where | Used here |
|---|---|---|
| Make | `src/Makefile`, `src/lib/Makefile`, `src/lib/libzstd.mk` | no |
| CMake | `src/build/cmake/` | no |
| meson | `src/build/meson/` | no |
| Visual Studio | `src/build/VS2008/`, `VS2010/`, `src/contrib/VS2005/` | no |
| Buck | `src/.buckconfig`, `src/lib/BUCK`, `src/zlibWrapper/BUCK` | no |
| SwiftPM | `src/Package.swift` | no |

`build.zig` compiles the same source list, read out of upstream rather than
derived.

### The compiled closure

`src/lib/libzstd.mk:149-153` collects four directories by wildcard:

```make
ZSTD_COMMON_FILES      := $(sort $(wildcard $(LIB_SRCDIR)/common/*.c))
ZSTD_COMPRESS_FILES    := $(sort $(wildcard $(LIB_SRCDIR)/compress/*.c))
ZSTD_DECOMPRESS_FILES  := $(sort $(wildcard $(LIB_SRCDIR)/decompress/*.c))
ZSTD_DICTBUILDER_FILES := $(sort $(wildcard $(LIB_SRCDIR)/dictBuilder/*.c))
```

Expanded against this tree: **8 + 14 + 4 + 4 = 30 `.c` files**.
`ZSTD_LEGACY_FILES` is empty by default; this build adds three of the seven
`legacy/` units, for **33 compiled `.c` files**. A fifth wildcard at
`libzstd.mk:156` collects `decompress/*_amd64.S`, and `build.zig` appends it
unconditionally on `x86_64` — so **34 compiled units in total**, which is the
count `build.zig`'s module comment states as `8 + 14 + 4 + 1 + 4 + 3`.

`build.zig` names the five arrays rather than expanding a wildcard, because a
wildcard would silently pick up a file upstream adds in a later release.

| Array | Count |
|---|---:|
| `common_sources` | 8 |
| `compress_sources` | 14 |
| `decompress_sources` | 4 |
| `dictbuilder_sources` | 4 |
| `legacy_sources` | 3 |
| `.c` subtotal | **33** |
| `decompress/zstd_decompress_amd64.S` | 1 |
| **total compiled units** | **34** |

**`common/pool.c` is compiled even though this build defines
`ZSTD_MULTITHREAD` nowhere**, because it is load-bearing: `dictBuilder/cover.c`
and `dictBuilder/fastcover.c` both call `POOL_create` from
`ZDICT_optimizeTrainFromBuffer_*` whenever `nbThreads > 1`, and `POOL_create`,
`POOL_free`, `POOL_add` and `POOL_tryAdd` are referenced unconditionally in
those units. Without the file the archive does not link.

**The AMD64 assembly decoder** is collected by its own wildcard
(`libzstd.mk:156`) and is compiled only on `x86_64`, which is what
`decompressAssembly` at `build.zig:489-491` decides.

### Deviations worth naming

| Deviation | What | Why |
|---|---|---|
| **C dialect pinned** | `-std=c99` | Upstream passes none. The pinned tree is tested at C89 (`src/Makefile:435`) and C99 (`:443`) and `libzstd.mk` passes neither, so a build that inherits its dialect from the host compiler is not reproducible |
| **No `make`** | the source list is five named arrays | one build graph, one place where a flag can disagree |
| **No `programs/`** | the CLI is not compiled | it is a separate program, not the library, and upstream's own library install rule does not install it |
| **No `deprecated/`** | retained, uncompiled | part of upstream's release; nothing was dropped |
| **Export surface** | a version script gives the shared object `src/lib/zstd.h:47-51`'s split | `ZSTDLIB_API` on the public declarations, `ZSTDLIB_HIDDEN` on the internals. On Mach-O and COFF there is no version-script mechanism, and `build.zig` **prints a warning at configure time** saying the shared object will export internal symbols as well as its API — rather than leaving that to be discovered by `nm -D` |

### Artifact names are upstream's

`src/lib/Makefile:87` — `-Wl,-soname=libzstd.$(SHARED_EXT).$(LIBVER_MAJOR)` —
gives `libzstd.so.1`, and `:82` gives the Darwin `-install_name` spelling.
`src/lib/libzstd.pc.in:14` is `Libs: -L${libdir} -lzstd`. `build.zig` reproduces
those names, which is also what makes Zig emit `libzstd.a` from
`dep.artifact("zstd")`.

### Installed layout

`zig build install --prefix PREFIX` produces, and `nix build` produces the same
tree by construction because it runs that same step:

```
PREFIX/lib/libzstd.a                        (or libzstd.so with the .so.1 soname)
PREFIX/include/zstd.h
PREFIX/include/zstd_errors.h
PREFIX/include/zdict.h
PREFIX/lib/pkgconfig/zstd.pc
PREFIX/share/licenses/zstd/                 10 files, see below
```

`PREFIX/share/licenses/zstd/` holds `src/LICENSE`, `src/COPYING`,
`src/README.md`, `README.upstream.md`, `NOTICE.md`, `FORK-LICENSE.md`,
`UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-NOTES.md` and `CHANGELOG.md` — exactly
`licence_records` in `build.zig:515-526`.

**Both of upstream's licence texts are installed.** That is not redundancy:
`src/lib/libzstd.mk:8` says *"You may select, at your option, one of the
above-listed licenses"*, and installing only one text would make the package's
choice for the recipient.

The BSD option's copyright line is upstream's, not this fork's, and it travels
with the source and with every installed artifact. `src/LICENSE:1-30`,
verbatim:

```
BSD License

For Zstandard software

Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook, nor Meta, nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

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

The GPLv2 alternative is `src/COPYING`, unmodified. [`NOTICE.md`](NOTICE.md) is
the per-file inventory and [`FORK-LICENSE.md`](FORK-LICENSE.md) the grant for
this fork's own files.

---

## 3. Support matrix

### Build configurations

| Option | Values | Default | What it selects |
|---|---|---|---|
| `-Dlinkage` | `static`, `dynamic` | `static` | **which artifact this build delivers and installs** |
| `-Druntime` | `true`, `false` | `false` | **how the Zig facade reaches it**: a link line, or one process-lifetime table an explicit `load` fills |
| `-Dsystem` | `true`, `false` | `false` | bind an installed `libzstd` instead of compiling `src/lib/` |

`-Dlinkage` and `-Druntime` are **orthogonal**, exactly as in the zlib SDK.

### Steps

| Step | What it does | Status | Worker run, 2026-10-05 |
|---|---|---|---|
| `zig build` | build and install the delivery tree | `PENDING-VERIFICATION` | exit 0 |
| `zig build test` | run `tests.zig` | `PENDING-VERIFICATION` | exit 0, 22/22, Debug and ReleaseSafe |
| `zig build smoke` | run `smoke.zig`, the deterministic example | `PENDING-VERIFICATION` | exit 0 |
| `zig build check` | compile the library, facade, tests and example for **five** targets, running nothing | `PENDING-VERIFICATION` | exit 0 |
| `zig build consumer` | build or run `consumer/` as its own package | `PENDING-VERIFICATION` | **not run** |

### Cross-target matrix

`zig build check` walks these **five** when no `-Dtarget` is named:

| Target | Static | Shared |
|---|:--:|:--:|
| `x86_64-linux-gnu` | yes | yes |
| `aarch64-linux-gnu` | yes | yes |
| `aarch64-macos-none` | yes | yes |
| `x86_64-windows-gnu` | yes | yes |
| `riscv64-linux-gnu` | yes | yes |

**`wasm32-wasi` is the sixth workspace target and is absent from that list for
one stated reason**, which `build.zig:1498-1505` gives: nothing refuses it, this
is a plain-C library with no thread, no signal and no `dlopen` in this
configuration, so a static WASI cell is expected to compile. It is missing
because the list is walked for *both* linkages and `deliveredLinkage` refuses a
shared object on a target whose OS has no dynamic linker.

The one-target form is:

```sh
zig build check -Dtarget=wasm32-wasi -Dlinkage=static
```

`devenv tasks run sdk:check:wasm32-wasi` wraps it, as a named task rather than a
row nobody remembers.

### The published 53-platform matrix

`cross-test`, run from the package root, builds **and runs** `tests.zig` for
every platform in Zig 0.16.0's published Tier 1/2 table, using this repository's
own build graph and `cross-test.profile.sh`.

It is **not** a CI job here and this repository does not pretend otherwise. A
foreign target with no executor is recorded as `build_only` coverage — compiled,
never executed, **never counted as a pass**.

#### The first run of 2026-10-05: exit code 1, 10 of 53 executed

*Historical. This run is kept whole. The re-run after the one-line fix is
recorded under "The re-run after the fix" below and supersedes it.*

One full-matrix run was executed from the package root with:

```sh
. "$HOME/.local/lib/host-scratch.sh" || exit 1
ZIG="$ZIG_GLOBAL_CACHE_DIR/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig"
export ZIG
cross-test --output "$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd" \
  --jobs 8 --build-jobs 8
```

`cross-test` is `~/.local/bin/cross-test`, and its summary names the compiler it
selected: `zig_version: 0.16.0`, at the path above and not through a shim. It
took the profile `cross-test.profile.sh`, whose `CROSS_BUILD_STEP=test`,
`CROSS_BUILD_TIMEOUT=3600` and `CROSS_TIMEOUT=1800` were kept, and whose
`CROSS_BUILD_JOBS=4` was overridden on the command line. Each cell ran
`zig build test -Dtarget=TARGET -ODebug -j8` with a fresh cache, and each logged
`Build Summary: N/6 steps`.

The harness **exited 1** over `target_count: 53`. The cells classify as:

| Outcome | Cells | Evidence in each log |
|---|--:|---|
| `pass` | 10 | `6/6 steps succeeded; 22/22 tests passed`, exit 0 |
| `build_only` | 20 | `5/6 steps succeeded (1 skipped)`, exit 0, `runtime_unavailable`: nothing ran |
| `build_failed` | 23 | `3/6 steps succeeded (1 failed)`, exit 1, one compilation error each |
| refused | 0 | no cell was refused by the build graph |
| runtime fail | 0 | no executed cell failed a test |

The 10 executed cells are `x86_64-linux` (native), `aarch64-linux`,
`aarch64_be-linux`, `loongarch64-linux`, `mips64-linux`, `mips64el-linux`,
`powerpc64-linux`, `powerpc64le-linux`, `riscv64-linux` and `s390x-linux`. The
last nine ran under QEMU user mode.

The 20 `build_only` cells compiled and were never executed, and each name below
is a missing executor on this host, not a result:

| Reason | Cells |
|---|---|
| `no_local_runner_freebsd` | `aarch64-freebsd`, `powerpc64-freebsd`, `powerpc64le-freebsd`, `riscv64-freebsd`, `x86_64-freebsd` |
| `no_local_runner_netbsd` | `aarch64-netbsd`, `aarch64_be-netbsd`, `x86_64-netbsd` |
| `no_local_runner_openbsd` | `aarch64-openbsd`, `mips64-openbsd`, `mips64el-openbsd`, `powerpc64-openbsd`, `riscv64-openbsd`, `x86_64-openbsd` |
| `no_local_runner_macos` | `aarch64-macos`, `x86_64-macos` |
| `no_local_runner_maccatalyst` | `aarch64-maccatalyst`, `x86_64-maccatalyst` |
| `unsupported_windows_arch` | `aarch64-windows` |
| `missing_wine64` | `x86_64-windows` |

Receipts: `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd/cross-test-summary.json`,
run `20261005-191611-72330-19239`, with one `build-TARGET.log` per cell in the
same `runs/` directory. The run's own cache lived under `$ZIG_GLOBAL_CACHE_DIR`
and the harness removed it.

#### Why every 32-bit cell failed to build

The 23 failures are one error, at the same column of the same generated
function, and they split exactly on pointer width: **every** cell whose pointer
width is 32 bits failed, and all 30 cells whose pointer width is 64 bits
compiled. The failing cells are `arm-freebsd`, `arm-linux`, `armeb-linux`,
`arm-netbsd`, `armeb-netbsd`, `arm-openbsd`, `hexagon-linux`, `mips-linux`,
`mipsel-linux`, `mips-netbsd`, `mipsel-netbsd`, `powerpc-linux`,
`powerpc-netbsd`, `powerpc-openbsd`, `riscv32-linux`, `thumb-linux`,
`thumbeb-linux`, `thumb-windows`, `wasm32-wasi`, `x86-linux`, `x86-netbsd`,
`x86-openbsd` and `x86-windows`.

In each of those logs the C library compiled and the translation succeeded. The
only failing step is `compile test zstd-tests`, and its single error is:

```
translate.zig:1184:314: error: expected type 'c_int', found 'usize'
note: signed 32-bit int cannot represent all possible unsigned 32-bit values
```

`zig/root.zig:979` instantiates `c.ZSTD_COMPRESSBOUND(src_len)` with a `usize`.
That macro (`src/lib/zstd.h:249`) reaches Zig as
`(@as(c_int, 128) << @as(c_int, 10)) - srcSize`, and Zig will not reconcile
`c_int` with a 32-bit unsigned argument there. The generated text is identical
for `x86-linux` and `x86_64-linux`; only the width of the argument differs. Read
out of one generated file on an `x86_64-linux` host, the same function compiles
when instantiated at `u64` or `u16` and fails when instantiated at `u32`.

**This is a defect in this package's facade, not a platform boundary.** No
runner, host or toolchain option stands between the 23 cells and a build, and
the upstream C is well defined at 32 bits. The record is in `FORK-NOTES.md`
§2.7. The one-line change that record names is now in `zig/root.zig:994`. The
public signature, the returned number and `tests.zig` are unchanged, and the
re-run below is its receipt.

#### The re-run after the fix: exit code 0, 20 of 53 executed

The change is one line, `zig/root.zig:994`:

```zig
return @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(u64, src_len))));
```

`cross-test` was run again from the package root with the same command and the
same profile:

```sh
. "$HOME/.local/lib/host-scratch.sh" || exit 1
ZIG="$ZIG_GLOBAL_CACHE_DIR/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig"
export ZIG
cross-test --output "$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd2" \
  --jobs 8 --build-jobs 8
```

It **exited 0** over `target_count: 53` and reported
`status=partial pass=20 fail=0 build_only=33 partial=0`. No cell is
`build_failed`, none is refused, and no executed cell failed a test. The whole
53-cell summary carries exactly two reason strings: `tests_complete` on the 20
and `runtime_unavailable` on the 33.

| Outcome | First run | Re-run |
|---|--:|--:|
| `pass` | 10 | **20** |
| `build_only` | 20 | **33** |
| `build_failed` | **23** | **0** |
| refused | 0 | 0 |
| runtime fail | 0 | 0 |

Every one of the 23 cells that failed to build **now builds**. Ten of them
also found an executor and ran 22/22 tests each: `arm-linux`, `armeb-linux`,
`hexagon-linux`, `mips-linux`, `mipsel-linux`, `powerpc-linux`,
`riscv32-linux`, `thumb-linux`, `thumbeb-linux` and `x86-linux`. The other 13
compile and are `build_only` on this host's missing executors, which is
coverage and never a pass: `arm-freebsd`, `arm-netbsd`, `armeb-netbsd`,
`arm-openbsd`, `mips-netbsd`, `mipsel-netbsd`, `powerpc-netbsd`,
`powerpc-openbsd`, `thumb-windows`, `wasm32-wasi`, `x86-netbsd`, `x86-openbsd`
and `x86-windows`. They join the 20 cells that were already build-only, so
`build_only` rises by exactly those 13 and nothing else moves.

Receipts, two runs, identical classification and identical exit code:

| Run | id | Summary |
|---|---|---|
| first re-run | `20261005-195932-14976-9053` | `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd2/cross-test-summary.json` |
| final re-run, over the tree as committed | `20261005-201302-53233-31199` | `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd3/cross-test-summary.json` |

Each has one `build-TARGET.log` per cell under its own `runs/` directory. The
second run was made after the doc edits, so its receipt covers the tree exactly
as it now stands; only Markdown and a doc comment changed between the two, and
both runs report the same 20 `pass`, 33 `build_only` and 0 `build_failed`.


### System-library mode

`-Dsystem=true` (or a runner's own `-fsys=zstd`) binds an installed `libzstd`
through `b.systemIntegrationOption("zstd", …)` and translates **the installed
headers**. Bundled new-release headers against an older installed library
compile and fail silently (`WISDOM.md` W14), so this package never does it.
System mode is **not** part of this wave's gates and no system result may
substitute for a source-package result.

---

## 4. Consumption

### As a Zig dependency

```zig
const zstd_dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("zstd", zstd_dep.module("zstd"));

const exe = b.addExecutable(.{ .name = "consumer", .root_module = exe_mod });
exe.linkLibrary(zstd_dep.artifact("zstd"));
b.installArtifact(exe);
```

[`README.zig.md`](README.zig.md) is the module's own reference.

### As a C library

```c
#include <zstd.h>
#include <assert.h>

static const char text[] = "hello, world";
unsigned char  frame[256];
size_t         frame_size = ZSTD_compress(frame, sizeof frame,
                                          text, sizeof text - 1, 3);
unsigned char  back[256];
size_t         back_size  = ZSTD_decompress(back, sizeof back,
                                            frame, frame_size);
assert(back_size == sizeof text - 1);
```

```sh
cc app.c $(pkg-config --cflags --libs zstd)
```

### The consumer package in this repository

`consumer/` is a **separate package with its own manifest**, reached through a
relative path rather than a fetch.

It is also the **second** place the interoperation claim is made, and it proves
it three ways from outside this package:

1. It carries its own copy of the 232-byte payload and checks that its SHA-256
   is the value `fixtures/SHA256SUMS` records — a **recorded digest** it
   reproduces rather than trusts.
2. It embeds two frames **built byte by byte from RFC 8878** and checks their
   decoded output against the RFC, after checking the header fields against the
   same RFC by hand.
3. It decodes frames the `zstd` CLI v1.5.7 and `python-zstandard` 0.22.0
   produced, read at run time from the repository's fixture paths.

A run that decoded **no** external frame exits non-zero rather than reporting
success for a check that did not run.

```sh
cd consumer && zig build run
```

### Running the gates

```sh
zig build
zig build test                              # Debug
zig build test -Doptimize=ReleaseSafe
zig build smoke
zig build check
tools/check-provenance.sh
cd consumer && zig build run
```

Or, with the canonical development environment:

```sh
devenv shell
devenv tasks run sdk:test
devenv tasks run sdk:consumer
devenv tasks run sdk:provenance
```

### Scratch, not `/tmp`

```sh
. "$HOME/.local/lib/host-scratch.sh" || exit 1
zig build --cache-dir "$HOST_SCRATCH_ROOT/cache/foundation-libs/zstd"
```

---

## 5. What this repository does not claim

* **No upstream test suite is claimed as run.** `src/tests/` is imported whole
  and unmodified, and `tests.zig` embeds two of its corpora **in place**; the
  CLI tests, fuzzer harness and dictionary tests belong to upstream's own
  `make test`, which needs the programs this package does not build. No upstream
  test is deleted, modified or moved.
* **Two producers, one encoder.** The `cli/` and `pyzstd/` fixtures are the
  `zstd` CLI and a Python binding over the *same* libzstd 1.5.7, and they are
  byte-identical at each level. `fixtures/PROVENANCE.md` says so, `tests.zig`
  asserts it, and neither claims two independent encoders. The independence that
  does exist is in the RFC 8878 frames and in upstream's golden corpus.
* **No committed SHA.** There is no release-tarball digest and no commit SHA in
  `UPSTREAM.md`, because neither can be read out of anything in this tree.
* **No licence narrowing.** `src/LICENSE` and `src/COPYING` both install.
  `src/tests/gzip/` is GPL-2.0-or-later, © FSF, and is inventoried.
* **No gate result.** Nothing here has been verified by the driver. A worker
  ran the gates listed in §2 and §3 on 2026-10-05 and every one exited 0; each
  is still `PENDING-VERIFICATION` until the driver moves it, and the consumer
  run and the `wasm32-wasi` static cell were never executed at all.