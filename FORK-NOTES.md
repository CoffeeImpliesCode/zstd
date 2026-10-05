# FORK-NOTES.md

Decisions taken while building this package, the reasoning behind them, and the
issues met along the way. Entries are written in the horizon-learning shape —
**condition, symptom, resolution, targets bound** — so a later wave in another
directory, another library or another toolchain version can apply one without
re-deriving it.

Nothing here is a verification result. Every statement is `SOURCE-CONFIRMED`
(read out of a file) or `CONSTRAINT` (a binding design rule with no observation
behind it). The driver's runs live in the workspace ledger.

---

## 1. Decisions

### 1.1 Both licence texts install; the fork's own files take the BSD option

**Decision.** `build.zig`'s `licence_records` names `src/LICENSE` **and**
`src/COPYING`, and `FORK-LICENSE.md` grants the fork-authored files under
BSD-3-Clause.

**Why.** `src/lib/libzstd.mk:8` says *"You may select, at your option, one of the
above-listed licenses"* and `src/README.md:7-8` says the same in prose. That is
the grant: two options, recipient's choice. A package that installed only the
BSD text and described the tree as BSD would have made the recipient's choice for
them and narrowed what upstream published.

Choosing BSD for the *fork's* files is a separate question with a separate
answer: it is the owner's, made under the owner's per-project licence
authorization, it matches the first of upstream's two named options, and it
covers only material written here. `NOTICE.md` opens by saying a single label is
wrong for this tree, and `tools/check-provenance.sh` fails if either upstream
text or the dual-grant statement in `libzstd.mk` stops being present.

**Targets bound.** None — a licensing fact about this repository.

### 1.2 `common/pool.c` is compiled without `ZSTD_MULTITHREAD`

**Decision.** `pool.c` and `threading.c` are compiled even though this build
defines `ZSTD_MULTITHREAD` nowhere.

**Why.** `pool.c` is **required**: `dictBuilder/cover.c:1213` and
`dictBuilder/fastcover.c:672` both call `POOL_create(nbThreads, 1)` from
`ZDICT_optimizeTrainFromBuffer_*` whenever `nbThreads > 1`, and `POOL_create`,
`POOL_create_advanced`, `POOL_free`, `POOL_add` and `POOL_tryAdd` are referenced
unconditionally in those units. Without the file the archive does not link.

`threading.c` is different: it is in the closure and contributes one symbol.
Its Windows implementation is behind `#if defined(ZSTD_MULTITHREAD) &&
defined(_WIN32)` and its non-Windows one likewise, so with the macro undefined
neither arm compiles. It is compiled because it is inside upstream's wildcard at
`libzstd.mk:149`, not because anything this build does needs it.

The single-threaded arm at `common/pool.c:313-371` is a **complete**
implementation — it runs each job inline through `POOL_add` (`:354-357`) — which
is why a consumer asking for `nbThreads > 1` still gets a correct answer from a
single-threaded build.

**Lesson shape.** Condition: a wildcard-collected file that no define activates.
Symptom: the archive does not link, from an unreferenced symbol in a different
unit. Fix: compile the closure, not the reachable subset. Targets bound: Zig
0.16.0, and any future release where `cover.c` or `fastcover.c` keeps calling the
pool.

### 1.3 Five named arrays, not an expanded wildcard

**Decision.** `build.zig` lists `common_sources`, `compress_sources`,
`decompress_sources`, `dictbuilder_sources` and `legacy_sources` explicitly.

**Why.** `libzstd.mk:149-153` collects by wildcard, and reproducing that as a
wildcard would mean a file upstream adds in a later release is silently compiled
into this package with no record of it in `UPSTREAM.sha256`'s description of
what is built. Naming the arrays is what makes the compiled closure a stated
fact rather than a property of a directory listing.

**The count.** 8 + 14 + 4 + 4 = 30 `.c` files from the wildcards, plus three of
the seven `legacy/` units, for **33 `.c` files**; plus the one assembly unit
`libzstd.mk:156` collects, for **34 compiled units**. See §2.3.

**Targets bound.** Zig 0.16.0.

### 1.4 The AMD64 assembly decoder is gated on the architecture

**Decision.** `src/lib/decompress/zstd_decompress_amd64.S` is collected by its
own wildcard (`libzstd.mk:156`), not by the four `.c` wildcards, and is compiled
only on `x86_64`.

**Why.** `decompressAssembly` at `build.zig:489-491` decides it on
`target.result.cpu.arch == .x86_64`. Handing an `.S` file to a non-x86 target is
not a link error the build recovers from; it is a compile error at a layer that
has nothing to do with this package.

### 1.5 The export surface, and where the mechanism does not exist

**Decision.** A version script gives the shared object `src/lib/zstd.h:47-51`'s
split on ELF. On Mach-O and COFF, where there is no version-script mechanism,
`build.zig` **prints a warning at configure time** saying the shared object will
export Zstandard's internals as well as its API.

**Why.** `src/lib/zstd.h:38-45` marks the internals `ZSTDLIB_HIDDEN` and
`:47-51` marks the public surface `ZSTDLIB_API`; a build that ignored the
difference would leak `ZSTD_compressSequences` and the `CTable_*` family out of
a shared object. Where the mechanism is available it is used; where it is not,
the consequence is **stated** rather than left to be discovered by `nm -D` after
a release. The CI checks the ELF case and compiles the Mach-O and COFF ones.

**Targets bound.** ELF, Mach-O and COFF.

### 1.6 The interoperation oracle is stated at the strength it has

**Decision.** The fixture set is two producer *front ends* over one encoder, and
`fixtures/PROVENANCE.md`, `tests.zig` and the consumer all say so.

**Why.** At each level the `zstd` CLI and `python-zstandard` emit **byte-identical**
frames — the CLI is a front end over libzstd and the binding links it directly —
and `fixtures/SHA256SUMS` records the shared digest for all three groups. Writing
"two independent implementations" would be false, and false in the direction that
matters: a reader who believed it would rate the evidence higher than it
deserves.

`tests.zig` asserts the byte-identity **directly**, and `smoke.zig` does too.
That is what keeps the rest of the claim honest: if a regeneration ever made the
two producers diverge, those checks fail and the prose has to change with them.

The independence that does exist is elsewhere and is named: the RFC 8878 frames
built byte by byte from the specification, and upstream's own
`golden-decompression/` corpus of real frames from other implementations.

### 1.7 One upstream inconsistency, recorded rather than smoothed

**Condition.** `ZSTD_decompressBound` has no legacy arm while `ZSTD_decompress`
does.

**Symptom.** A consumer of this build gets a `decompressBound` that reports
`ZSTD_CONTENTSIZE_ERROR` for a v0.5-to-v0.7 frame, while `decompress` still
decodes that frame — because `ZSTD_LIB_DEPRECATED` is 0 regardless of
`ZSTD_LEGACY_SUPPORT` (`src/lib/zstd.h:571-576` against `:203-204`).

**Resolution.** Nothing in this package papers over it. `build.zig`'s module
comment, `UPSTREAM.md` and this file all record it. The honest behaviour is to
tell a caller what upstream's own code does, not to add an arm upstream does not
have and present it as Zstandard's behaviour.

**Targets bound.** Any Zstandard build with `ZSTD_LIB_DEPRECATED` 0, which is
this one.

---

## 2. Issues met, and what was done

### 2.1 `fixtures/SHA256SUMS` cannot be verified as a whole

**Condition.** `build.zig.zon` names `fixtures/SHA256SUMS` and
`tools/check-provenance.sh` as what proves the fixture set did not change.

**Symptom.** `sha256sum -c fixtures/SHA256SUMS` reports
`fixtures/SHA256SUMS: FEHLSCHLAG` and exits non-zero **on every run**, whatever
the bytes are. Line 1 is

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  fixtures/SHA256SUMS
```

and `e3b0c442…b855` is the SHA-256 of zero bytes. A manifest cannot contain its
own digest: writing the digest into the file changes the file. The entry is
unsatisfiable by construction.

**Resolution.** Three things, and the order matters:

1. The gate **names line 1 in its output and prints why it is excluded**, before
   checking anything else. It verifies the other 19 data entries, it fails on any
   of them, and it never reports the manifest as a whole as checked. Nothing is
   skipped silently.
2. The gate additionally **compares the manifest's file set against the
   directory**, so a fixture added with no manifest line is caught even though
   its bytes match nothing.
3. **Nothing inside the manifest is edited.** Removing the self-reference or
   writing the file's real digest into it would both be changes to a file this
   slice did not author, and the second would be equally wrong. The correct fix
   is to drop the self-reference and record the manifest's own digest in
   `UPSTREAM.sha256` alongside the rest of the audit surface. That is the owner's
   call and it is recorded in `fixtures/PROVENANCE.md`.

**Targets bound.** Any `sha256sum -c` over a self-referential manifest.

### 2.2 `fixtures/PROVENANCE.md` was cited and did not exist

**Condition.** `tests.zig:59` names the record as the thing that proves the CLI
and the binding frames are byte-identical.

**Symptom.** The record was absent, so the one fact keeping the
producer-interoperation claim honest was asserted in prose and checked nowhere.
The consumer package cites it too.

**Resolution.** The record is written, with the three byte-identity groups laid
out as a table so the duplication is visible rather than something a reader has
to notice, and with an explicit statement of what this repository does **not**
claim. The gate checks the 19 data digests, both producer version strings, the
three byte-identity pairs, and that every citing file still cites the record.

**Targets bound.** None.

### 2.3 `WITHDRAWN` — "the manifest's 34 compiled units is wrong"

**Condition.** The manifest comment describing `src/` said "the 34 compiled
units of `src/lib/libzstd.mk`'s wildcards".

**Symptom as first read.** The five arrays in `build.zig` were counted and
totalled 33 — `common_sources` 8, `compress_sources` 14,
`decompress_sources` 4, `dictbuilder_sources` 4, `legacy_sources` 3 — which
appeared to make the manifest one too high. The finding was reported to the
driver as a defect.

**Refutation.** The count of 33 is right for `.c` files and the manifest's 34
is right for compiled units; the two are not in conflict. `build.zig:101`
already stated the arithmetic as `8 + 14 + 4 + 1 + 4 + 3 = 34`, and the `1` is
`src/lib/decompress/zstd_decompress_amd64.S`. That file is collected by its own
wildcard at `libzstd.mk:156` rather than by the four `.c` wildcards, and
`libzstd.mk:163` appends it to `ZSTD_DECOMPRESS_FILES` unconditionally because
`ZSTD_NO_ASM` defaults to 0 (`:57`). Reading only the five `.c` arrays cannot
see it.

**Resolution.** The manifest comment is now explicit rather than merely correct:
it names 34, states that they are 33 `.c` files plus the one assembly unit, and
gives the arithmetic. `build.zig` was not edited — it already carried the right
number and the right derivation. `UPSTREAM.md`, `README.md` and `CHANGELOG.md`
now state both numbers and where the extra unit comes from, so a reader who
counts `.c` files is not left to conclude the manifest is wrong.

**Lesson shape.** Condition: counting compiled units by file extension when a
build also assembles sources. Symptom: an off-by-one that reads as a defect in
an unrelated file. Fix: read the build graph's own arithmetic before reporting a
count mismatch, and check whether the wildcard the file came from is one of the
ones you enumerated. Targets bound: any C library build that also assembles
hand-written or generated assembly.

**Targets bound.** None.

### 2.4 `flake.lock` was named in `.paths` and did not exist

**Condition.** `.paths` named `flake.lock` with the comment "named here because it
is present in this tree".

**Symptom.** It is not present. `zig fetch` hashes every path `.paths` names, so
this names a missing entry: the manifest would have failed a fetch rather than
recording an absence.

**Resolution.** The line is removed and the comment now says the lock belongs to
the driver and is absent until the driver writes one. The gate checks **both**
directions, so the manifest cannot drift again in either direction: every path it
names must exist, and a lock that now exists but is not named is an error.

**Targets bound.** Zig 0.16.0 — `zig fetch` is what hashes the named paths.

### 2.5 Upstream's `.gitignore` would have swallowed the fixture set

**Condition.** `src/.gitignore` ships in the release tarball and is reproduced at
this repository's root.

**Symptom.** Two problems, one of them fatal to the oracle.

1. **`*.zst` matches the fixtures.** Eleven files under `fixtures/` are `.zst`
   frames: the three RFC 8878 pairs, the six CLI frames and the four binding
   frames. An ignored fixture is a *missing* fixture, and `@embedFile` on a
   missing file is a build failure that reads as a bug in the build graph rather
   than a mistake in an ignore file.
2. **Four entries are written for a repository root that is not this one.**
   `/zstd`, `zstdmt`, `bin/` and the `contrib/linux-kernel/linux/`, `projects/`
   forms sit at the root of upstream's tree, where `/zstd` means upstream's
   built CLI. At *this* root, `/zstd` is this package's own source directory —
   the one path in the tree that must never be ignored.

**Resolution.** Upstream's file is reproduced, because upstream's conventions are
upstream's business and none of them is removed to make room. Then:

* the four entries are **re-anchored to `src/`**, which keeps each convention and
  fixes what it points at — a scoping change, not a deletion;
* a fork **re-inclusion block** is appended, so `fixtures/` and everything under
  it wins over `*.zst`.

**Lesson shape.** Condition: an upstream ignore file lifted to a different root.
Symptom: either a pattern that means something else, or one broad enough to
swallow fork data. Fix: re-anchor what moved, re-include what was swallowed, and
say which is which in the file. Targets bound: any fork that vendors an upstream
tree with an ignore file and adds its own data files.

### 2.6 Upstream's CI was not copied

**Condition.** `src/.github/workflows/` holds seven upstream workflow files.

**Symptom.** Copying them would put another maintainer's pipeline into a fork's
CI. They build with upstream's own Make and CMake paths, run upstream's test and
fuzzer harnesses against the CLI this package does not build, and publish
upstream's release artefacts. Every one of those would fail here for a reason
that has nothing to do with this package.

**Resolution.** `.github/workflows/verify.yml` is written from scratch for this
package and states at the top why upstream's are not used. They stay in `src/`,
digested and unmodified — retained, never run.

**Targets bound.** None.

### 2.7 Every 32-bit cell failed on one macro instantiation

**Condition.** `zig/root.zig:979`, in `compressBoundConst`, calls the upstream
macro through the translation: `c.ZSTD_COMPRESSBOUND(src_len)`, with `src_len`
of type `usize`. The macro is `src/lib/zstd.h:249`. A 53-platform `cross-test`
run on 2026-10-05 exercised every cell of Zig 0.16.0's published Tier 1/2
table.

**Symptom.** Exit code 1, `target_count: 53`, and 23 cells with
`build_failed`, `zig build test` exit 1 and `3/6 steps succeeded (1 failed)`.
The 23 are exactly the cells whose pointer width is 32 bits; all 30 cells with
a 64-bit pointer width compiled, and the 10 with an executor ran 22/22 tests.
Every failing log carries one error and it is the same one, at column 314 of
the same generated function:

```
translate.zig:1184:314: error: expected type 'c_int', found 'usize'
note: signed 32-bit int cannot represent all possible unsigned 32-bit values
note: generic function instantiated here
    return c.ZSTD_COMPRESSBOUND(src_len);   (zig/root.zig:979)
referenced by:
    test.compressBound … (tests.zig:774)
```

The C library and the translation both succeed in every failing cell, so the
33-unit closure and the header translation are not the problem. The line is the
only failing step: `compile test zstd-tests`.

**Cause, read out of the toolchain's own output.** `translate-c` emits
`ZSTD_COMPRESSBOUND` as an `anytype` function whose body is
`(@as(c_int, 128) << @as(c_int, 10)) - srcSize` and whose return type is the
`@TypeOf` of that expression. Zig cannot coerce `c_int` against a 32-bit
unsigned argument in that position. `translate-c` was run by hand on
`zig/translate.h` for `x86-linux` and `x86_64-linux`; the emitted text is
byte-identical, so the target is not the variable. Instantiating that one
generated function from an `x86_64-linux` host at `u64` and at `u16` compiles,
and at `u32` fails with the mirrored message `expected type 'u32', found
'c_int'`. The width of the argument is the variable.

**Resolution — applied.** This is **not** a toolchain or platform limit.
The upstream C is well defined at 32 bits, the translated text is unchanged by
the target, and no runner or host option stands in the way. The one line is
this package's own. `zig/root.zig:994` now instantiates the macro at a width
Zig can check, and the public signature is unchanged:

```zig
return @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(u64, src_len))));
```

The value does not move. On a 32-bit target `ZSTD_MAX_INPUT_SIZE`
(`src/lib/zstd.h:248`) is `0xFF00FF00U`, which reads as the same threshold in
`u64`, and every `src_len` a 32-bit caller holds is below `2^32`, so the macro
returns the same number it returns in C.

That one line was applied first to a **copy** of this tree on approved scratch,
and `cross-test --targets x86-linux` was run there: `build=pass`, `run=pass`,
22 tests, exit 0, where the same cell in this tree was `build_failed`. The same
line is now in this tree at `zig/root.zig:994`; the public signature, the
returned number and `tests.zig` are unchanged.
`tests.zig:774` compares the macro against the real
Receipts: run `20261005-195336-1639-24820` at
`$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd-diag/tree-out/`, whose
cell log reads `6/6 steps succeeded; 22/22 tests passed`, and the two generated
translations `x86-linux.zig` and `x86_64-linux.zig` beside it.

**Lesson shape.** Condition: a C macro that mixes `int` constants with an
unsigned operand, translated by `translate-c` and instantiated at a fixed-width
argument. Symptom: `expected type 'c_int', found 'usize'` on every 32-bit cell
and on no 64-bit cell. Fix: instantiate the macro at a width the emitted `c_int`
arithmetic can check, or state the 32-bit cells as refused. Targets bound: any
facade that calls a translated integer macro of this shape at `usize`.

---

## 3. Open items for the driver

1. **Every gate is still `PENDING-VERIFICATION`**, and only the driver moves it.
   These were executed on 2026-10-05 from the package root with Zig 0.16.0 from
   the approved global cache, `-j8` and `--cache-dir` on approved scratch, and
   each exited **0**: `zig build`; `zig build test` in Debug and in
   `-Doptimize=ReleaseSafe`, both `6/6 steps succeeded; 22/22 tests passed`;
   `zig build smoke`; `zig build check` for all five targets and both linkages;
   `tools/check-provenance.sh`. Not executed here and still open:
   `zig build check -Dtarget=wasm32-wasi -Dlinkage=static` (item 5) and
   `zig build run` in `consumer/`.
2. **`.fingerprint` is absent from both manifests** — this one and the consumer's
   — and the observed `zig build` has still not printed one, so the value stays
   absent rather than guessed. `.version = "1.5.7"` is likewise worth
   confirming against the toolchain's own reading of the manifest.
3. **The 33-versus-34 count** in §2.3 needs a decision on which file carries it.
4. **`fixtures/SHA256SUMS`'s self-reference** needs the owner's decision
   (§2.1). Until it is made, `sha256sum -c fixtures/SHA256SUMS` fails on line 1
   and the gate's exclusion is the only thing making the fixture set checkable.
5. **`wasm32-wasi`** is one static cell, asserted by name in CI and as its own
   devenv task. Until that step runs, "a static WASI cell compiles" is
   `CONSTRAINT`, not a result.
6. **The 53-platform matrix has run three times**, all on 2026-10-05. The first
   exited 1 over 53 cells: 10 `pass` with 22 tests each, 20 `build_only` with
   no executor on this host, and 23 `build_failed` — every 32-bit cell, on
   `zig/root.zig:979` alone (§2.7). That one line is now applied at
   `zig/root.zig:994`, and the re-run **exited 0**: 20 `pass` with 22 tests
   each, 33 `build_only`, 0 `build_failed`, 0 refused, 0 runtime fail. Ten of
   the 23 gained an executor and ran; the other 13 compile and are
   `build_only` because this host has no runner for them. Receipt run
   `20261005-195932-14976-9053` at
   `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd2/`, and the same 53
   cells again after the documentation edits as run `20261005-201302-53233-31199`
   at `$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/zstd3/`: exit 0, the
   same 20 `pass`, 33 `build_only` and 0 `build_failed`. A platform with
   no runner stays `build_only` coverage, never a pass, and neither class may
   be rounded into the other.
7. **System-library mode is `PENDING-VERIFICATION`** and needs a machine with an
   installed `libzstd` and its own headers. No system result may substitute for a
   source-package result.