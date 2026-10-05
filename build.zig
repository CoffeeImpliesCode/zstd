// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zig 0.16 build for Zstandard 1.5.7.
//!
//! The library is upstream's own C, byte for byte: the 34 units that
//! `src/lib/Makefile:33-49` collects from `src/lib/libzstd.mk`'s wildcards with
//! upstream's own module switches, and nothing else. No program is built, no
//! test is fetched, nothing is downloaded, and no make, CMake or meson script is
//! executed. The default mode compiles everything from this repository rather
//! than linking an installed copy.
//!
//! Upstream reference: the official `zstd-1.5.7.tar.gz` release,
//! `src/lib/zstd.h:112-114` (`ZSTD_VERSION_MAJOR 1`, `ZSTD_VERSION_MINOR 5`,
//! `ZSTD_VERSION_RELEASE 7`). The release digest belongs in `UPSTREAM.md`, which
//! the fork's provenance owner writes; this script does not restate one.
//!
//! There is an upstream test suite and it is **not** carried as a gate:
//! `src/tests/Makefile` exists, `src/tests/playTests.sh:525` decodes
//! `src/tests/golden-decompression/rle-first-block.zst` with the CLI, and
//! `src/tests/decodecorpus.c` is the CLI's own decoder conformance driver. All
//! of that needs `zstd` and `zstdgrep` *programs*, which this package does not
//! build, so no step pretends to run it. What this build does instead is embed
//! four of upstream's golden frames from `src/tests/golden-decompression/` and
//! decode them through the library; `tests.zig` says which of them are
//! independent known answers and which are upstream's own.
//!
//! ## Entry points
//! -----------
//!   zig build           install the library, the three public headers, the
//!                        relocatable `zstd.pc`, and the licence and provenance
//!                        records; and compile the example
//!   zig build test      run the behavioural tests for the selected target
//!                        (`-Dtarget`; the host when it is absent)
//!   zig build smoke     run the example program
//!   zig build consumer  build the separate `consumer/` package, and run it when
//!                        this host can execute the selected target
//!   zig build check     compile the native library, the facade, the tests and
//!                        the example for the five check targets, running
//!                        nothing
//!
//!   cross-test       the same `test` step, for the published 53-platform
//!                   Zig 0.16.0 Tier 1/2 table rather than the host alone.
//!                   `cross-test` discovers `cross-test.profile.sh` from the
//!                   package root, runs `zig build test -Dtarget=TARGET` for
//!                   each of them, and executes the binary where a runner exists
//!                   and records explicit `build_only` coverage where one does
//!                   not. `test` is what the harness reaches for, and it builds
//!                   the same graph and the same test binary for whatever
//!                   `-Dtarget` says: nothing in `build()` narrows the graph to
//!                   the host.
//!
//! ## Options
//! -------
//!   -Dlinkage=static   a static archive, `libzstd.a`. This is the default:
//!                      `src/lib/Makefile:99` says the archive target "must be
//!                      run every time", and the whole of `src/lib/Makefile`
//!                      builds an archive unless `-fPIC` is asked for.
//!   -Dlinkage=dynamic  a real shared object, `libzstd.so.1.5.7` with
//!                      `libzstd.so.1` beside it, PIC on every constituent, and
//!                      an export surface of exactly the header-declared API.
//!   -Druntime=true     resolve the native entry points at run time instead of
//!                      linking them. Orthogonal to `-Dlinkage`, which still
//!                      decides which artifact this build delivers and installs.
//!                      Default off; a linked build is unchanged. The dispatch
//!                      itself is `runtime/graph.zig`, which the API role owns;
//!                      `add_graph` names the exact seam.
//!   -Dsystem=true      link an installed `libzstd` instead of compiling `src/lib/`.
//!                      Supplies the default of
//!                      `b.systemIntegrationOption("zstd", ...)`; a build runner
//!                      that decides the mode itself (`-fsys=zstd`) overrides it.
//!   -Dtarget=<triple>  build for one target; `zig build check` then checks that
//!                      target only instead of the whole matrix.
//!   -Doptimize=<mode>  the caller's mode, passed to every graph below.
//!
//! ## The core closure, read out of upstream
//! -----------------------------------------
//! `src/lib/Makefile:15-18` sets the four module switches and `:31` includes
//! `src/lib/libzstd.mk`, which is where the file lists come from:
//!
//!   * `libzstd.mk:149` collects `$(sort $(wildcard $(LIB_SRCDIR)/common/*.c))`
//!     - eight units.
//!   * `libzstd.mk:150` collects `compress/*.c` - fourteen units. They are
//!     included because `Makefile:35-37` appends `$(ZSTD_COMPRESS_FILES)` while
//!     `ZSTD_LIB_COMPRESSION` is 1 (`Makefile:15`).
//!   * `libzstd.mk:151` collects `decompress/*.c` - four units, appended by
//!     `Makefile:39-41` while `ZSTD_LIB_DECOMPRESSION` is 1 (`Makefile:16`).
//!   * `libzstd.mk:156` collects `decompress/*_amd64.S` and `:163` appends it to
//!     `ZSTD_DECOMPRESS_FILES` unconditionally, because `ZSTD_NO_ASM` defaults
//!     to 0 (`:57`). One unit, and `decompressAssembly` below is where the
//!     per-target decision lives.
//!   * `libzstd.mk:152` collects `dictBuilder/*.c` - four units, appended by
//!     `Makefile:47-49` while `ZSTD_LIB_DICTBUILDER` is 1 (`Makefile:17`).
//!     `Makefile:21-24` would have forced it to 0 if compression were off.
//!   * `libzstd.mk:154` starts `ZSTD_LEGACY_FILES` empty and `:202-206` fills it
//!     from `ls legacy/*.c | grep 'v0[$(ZSTD_LEGACY_SUPPORT)-7]'`.
//!     `ZSTD_LEGACY_SUPPORT` defaults to 5 (`:35`), so the bracket is `v0[5-7]`
//!     and the three units are `legacy/zstd_v05.c`, `zstd_v06.c`, `zstd_v07.c`.
//!     `Makefile:33` adds them unconditionally, unlike the other four groups.
//!
//! That is 8 + 14 + 4 + 1 + 4 + 3 = **34 translation units**, and the lists
//! below are those wildcards expanded, in the order `$(sort)` produces.
//!
//! ### What `deprecated/` costs
//!
//! `libzstd.mk:153` collects `ZSTD_DEPRECATED_FILES` - the three `zbuff_*`
//! units - and `Makefile:43-45` appends them only while `ZSTD_LIB_DEPRECATED` is
//! non-zero. `Makefile:18` sets it to **0**. So upstream's own default excludes
//! them, this build does not override it, and `src/lib/deprecated/` travels
//! uncompiled. What that costs a consumer is the entire `ZBUFF_*` API:
//! `ZBUFF_createCCtx`/`ZBUFF_compressInit`/`ZBUFF_compressContinue`/
//! `ZBUFF_compressFlush`/`ZBUFF_compressEnd` and the whole decompression half
//! (`src/lib/deprecated/zbuff_compress.c:54-167`,
//! `src/lib/deprecated/zbuff_decompress.c:22-77`), plus `ZBUFF_isError` and
//! `ZBUFF_getErrorName` (`src/lib/deprecated/zbuff_common.c:23-26`). Those
//! functions are thin wrappers over `ZSTD_CStream`/`ZSTD_DStream` - the two
//! files say so in their own right, `src/lib/deprecated/zbuff_decompress.c:22-25`
//! is `return ZSTD_createDStream()` - and they were deprecated because they were
//! a worse spelling of what this SDK already wraps.
//!
//! The second thing their absence touches is `ZSTD_decompressBound`, and there
//! the story is a discrepancy in upstream's own source rather than a removed
//! feature: the comment at `src/lib/decompress/zstd_decompress.c:815` says the
//! function is "compatible with legacy mode", but the body at `:825` walks the
//! input with `ZSTD_findFrameSizeInfo(src, srcSize, ZSTD_f_zstd1)` and that
//! function has no legacy arm, unlike `ZSTD_getFrameContentSize` at `:571-576`
//! which does. Since `ZSTD_LIB_DEPRECATED` is 0 regardless of
//! `ZSTD_LEGACY_SUPPORT`, a consumer of *this* build gets a `ZSTD_decompressBound`
//! that reports `ZSTD_CONTENTSIZE_ERROR` for a v0.5-v0.7 frame while
//! `ZSTD_decompress` still decodes it. `UPSTREAM.md` and `FORK-NOTES.md` both
//! record this; nothing here papers over it.
//!
//! ## `common/threading.c` and `common/pool.c`
//! ------------------------------------------
//! Both are in upstream's wildcard at `libzstd.mk:149` and both are compiled
//! here, because both are load-bearing even though this build does not define
//! `ZSTD_MULTITHREAD`:
//!
//!   * `pool.c` is **required**. `src/lib/dictBuilder/cover.c:1213` and
//!     `src/lib/dictBuilder/fastcover.c:672` both call `POOL_create(nbThreads, 1)`
//! from `ZDICT_optimizeTrainFromBuffer_*` whenever `nbThreads > 1`, and
//!     `POOL_create_advanced`, `POOL_free`, `POOL_add` and `POOL_tryAdd` are
//!     referenced unconditionally in those units. Without the file the archive
//!     does not link. And the single-threaded arm at `src/lib/common/pool.c:313-371`
//! is a complete implementation - it runs each job inline through `POOL_add`
//! (`:354-357`) - which is why a consumer asking for `nbThreads > 1` still gets a
//!     correct answer from a single-threaded build.
//!   * `threading.c` is **in the closure but contributes one symbol**. Its
//!     Windows implementation is behind `#if defined(ZSTD_MULTITHREAD) &&
//!     defined(_WIN32)` (`:23-133`) and its non-Windows one behind
//!     `#if defined(ZSTD_MULTITHREAD) && DEBUGLEVEL >= 1 && !defined(_WIN32)`
//!     (`:135-182`), and this build defines neither `ZSTD_MULTITHREAD`
//!     (`src/lib/Makefile:64` leaves `CPPFLAGS_STATICLIB` empty, so the static
//!     build is single-threaded by upstream's own default) nor `DEBUGLEVEL >= 1`
//!     (`libzstd.mk:108` sets `DEBUGLEVEL ?= 0` and `:109` puts that on the
//!     compile line). What survives is `:21`'s
//!     `int g_ZSTD_threading_useless_symbol;`, whose own comment says it exists
//!     "to avoid empty translation unit warning". It is compiled because upstream
//!     compiles it, and saying so is more useful than dropping a unit to make
//!     the number smaller.
//!
//! ## The x86-64 assembly, decided per target
//! ------------------------------------------
//! `src/lib/decompress/huf_decompress_amd64.S` is guarded by macros inside the
//! file itself and produces nothing on most targets, so the decision is made per
//! target and not globally.
//!
//! `src/lib/common/portability_macros.h:143-150` defines
//! `ZSTD_ENABLE_ASM_X86_64_BMI2` as 1 only when `ZSTD_DISABLE_ASM` is absent,
//! `ZSTD_ASM_SUPPORTED` is 1, `__x86_64__` is defined, and either `DYNAMIC_BMI2`
//! or `__BMI2__` is. `:116-130` makes `ZSTD_ASM_SUPPORTED` 1 only for a GNU
//! compiler on Linux, macOS or Win32. `:93-103` makes `DYNAMIC_BMI2` 1 for clang
//! or GCC 4.8+ on x86 when `__BMI2__` is not already defined, which is the case
//! for this toolchain's clang at a baseline CPU. The file's own body is behind
//! `#if ZSTD_ENABLE_ASM_X86_64_BMI2` (`:41`), and the C side that would call it
//! is behind the same macro (`src/lib/decompress/huf_decompress.c:714,906,916,
//! 1517,1728,1738`).
//!
//! So: **the assembly is compiled exactly when `cpu.arch` is `x86_64`**, and on
//! every other architecture it is left out rather than assembled to nothing.
//! That is the same answer the macro reaches, decided from the resolved target
//! instead of from a probe, and it means an aarch64 or riscv64 matrix cell does
//! not carry a build step whose output would be an empty object.
//!
//! ## Compile line
//! ---------------
//! Three macros come from upstream and are given to every C translation unit and
//! to the translation alike, so the declarations the facade was typed against
//! and the code that implements them cannot be built for two different
//! configurations:
//!
//!   * `-DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0`, `src/lib/libzstd.mk:109` exactly.
//!     The namespace keeps the library's vendored xxHash from colliding with a
//!     consumer's own xxHash, which is the whole point of the macro.
//!   * `-DZSTD_LEGACY_SUPPORT=5`, `src/lib/libzstd.mk:207`, with the value from
//!     `:35`. That is what makes `legacy/zstd_v05.c`, `v06.c` and `v07.c` worth
//!     compiling at all.
//!   * `-DZSTD_STATIC_LINKING_ONLY=1`, on the **translation only** and not on the
//!     library's own C lines. It is upstream's own switch for the experimental
//!     surface (`src/lib/zstd.h:104-109`), and the facade needs it because
//!     `ZSTD_frameHeaderSize` (`src/lib/zstd.h:1508`) and `ZSTD_CCtx_getParameter`
//!     (`src/lib/zstd.h:2364`) are `ZSTDLIB_STATIC_API`. It is deliberately not
//!     on the library's line: seven upstream headers define it themselves
//!     (`src/lib/zstd.h`, `src/lib/common/zstd_internal.h`,
//!     `src/lib/common/allocations.h`, `src/lib/common/pool.h`,
//!     `src/lib/compress/clevels.h`, `src/lib/compress/zstdmt_compress.h`,
//!     `src/lib/deprecated/zbuff.h`), so a command-line definition would be
//!     redefined by `src/lib/compress/clevels.h:14` and every other one that
//!     spells it. A dependent is never asked to repeat it: it reaches the
//!     declarations through `dep.module("zstd").c`, not through a header.
//!   * `-D__USE_MINGW_ANSI_STDIO` on Windows, `src/lib/libzstd.mk:110-112`
//!     exactly, for the `%zu` formatting upstream's MinGW target needs.
//!   * `-DZSTD_DLL_EXPORT=1` on a Windows shared build, and `ZSTD_DLL_IMPORT=1` on
//!     the translation for that case. `src/lib/zstd.h:47-51` turns
//!     `ZSTDLIB_API` into `__declspec(dllexport)` or `__declspec(dllimport)` on
//!     them, and `:1238-1244` does the same for `ZSTDLIB_STATIC_API`. Nothing is
//!     defined on ELF or Darwin, where `ZSTDLIB_API` is `ZSTDLIB_VISIBLE`
//!     (`:38-45`).
//!
//! The language level is pinned to `-std=c99`. `libzstd.mk` passes no `-std` at
//! all (`:105` is `CFLAGS ?= -O3`), so the dialect would otherwise be a fact
//! about whatever compiler ran; `src/Makefile:443` is upstream's own C99 CI row
//! (`CFLAGS="-std=c99 -Werror -O0" $(MAKE) allmost`), and `src/Makefile:435`
//! shows the project also builds as C89. C99 is the widest dialect the tree is
//! tested under and it is what the pinned flag says.
//!
//! Nothing else is defined. In particular `ZSTD_MULTITHREAD` is **not**, because
//! `src/lib/Makefile:64` leaves `CPPFLAGS_STATICLIB` empty and this package's
//! default delivery is the static archive; `ZSTD_NO_ASM` is not, because
//! `libzstd.mk:57` defaults it to 0 and the per-target rule above is how that
//! decision is expressed here; and none of the size-reduction switches
//! (`libzstd.mk:39-54`) is, because they all default to 0 and `ZSTD_LIB_MINIFY`
//! is 0 (`:29`).
//!
//! ## What this package does not link
//! ---------------------------------
//! No `-lm` and no `-lpthread`, and that is a finding rather than an omission.
//! The only `log2`, `floor` and `log` occurrences in the 34 units are inside
//! comments and inside a comment-derived constant table
//! (`src/lib/compress/zstd_compress_sequences.c:17-21` is the caption of
//! `kInverseProbabilityLog256`; `src/lib/dictBuilder/divsufsort.c:79` is a
//! comment explaining `log(SS_BLOCKSIZE) / log(3)`). No compiled expression calls
//! the C math library. `-pthread` appears at `src/lib/Makefile:63` in
//! `LDFLAGS_DYNLIB`, which is the *dynamic* library's flags; the static one at
//! `:64` is empty, and the shared object this package builds does not define
//! `ZSTD_MULTITHREAD` either, so it needs no thread library either.
//!
//! ## Static and shared delivery
//! -----------------------------
//! `-Dlinkage` selects which artifact this package produces. Nothing about the
//! compiled C changes between the two: the same 34 units, the same compile line,
//! the same numeric configuration.
//!
//! The soname is upstream's. `src/lib/Makefile:87` is
//! `-Wl,-soname=libzstd.$(SHARED_EXT).$(LIBVER_MAJOR)` and `:90-91` makes
//! `SHARED_EXT_MAJOR = so.$(LIBVER_MAJOR)`, where `LIBVER_MAJOR` is read out of
//! `zstd.h` by `libzstd.mk:83,87`. So the soname is `libzstd.so.1` and
//! `abi_version` takes 1 for its major. The full file name
//! `libzstd.so.1.5.7` is upstream's `SHARED_EXT_VER` (`:91`), which distinguishes
//! a 1.5.7 build from a 1.5.6 one that the bare `.so.1` cannot. macOS takes
//! `src/lib/Makefile:78-82`'s spelling instead - `-install_name`, `.dylib` and a
//! `compatibility_version` of 1 - and AIX takes `:84-86`'s no-soname answer.
//!
//! ELF shared libraries export the public `ZSTD_*` and `ZDICT_*` namespaces and
//! nothing else, which is what `setVersionScript` states. That keeps
//! `POOL_create`, `HUF_decompress4X1_usingDTable_internal_fast_asm_loop` and the
//! rest of upstream's internal surface out of the dynamic symbol table, where a
//! consumer could otherwise bind to them and depend on them.
//!
//! Mach-O has no version script that GNU ld or lld reads the same way, so this
//! does nothing for Darwin: a `libzstd.1.dylib` from this build exports
//! Zstandard's internals as well as its API. That is a real difference from the
//! ELF object and it is reported by `build` rather than hidden.
//!
//! ## Installed closure
//! -----------------
//! `zig build` installs, in bundled mode:
//!
//!   * the native library, through `b.installArtifact`, and the three public
//!     headers through the `installHeader` calls in `add_c_library`; installing
//!     a header also puts it on the include path of anything that links this
//!     artifact, so an installed C consumer needs nothing from this tree. The
//!     three are upstream's own list: `src/lib/zstd.h`, `src/lib/zdict.h`,
//!     `src/lib/zstd_errors.h`, which is exactly the set `src/lib/module.modulemap`
//!     names as its three headers (`module.modulemap:2,27,32`).
//!   * `lib/pkgconfig/zstd.pc`, generated by `add_pkg_config` from upstream's own
//!     template `src/lib/libzstd.pc.in` - every field in that file is upstream's,
//!     and `add_pkg_config` says which placeholder each substitution fills.
//!     `prefix` is `${pcfiledir}/../..` rather than an absolute path, so the
//!     installed file is correct wherever `--prefix` put it.
//!   * `share/licenses/zstd/` with the licence and provenance records, through
//!     `install_licence_records`. A private repository removes no licence
//!     obligation, and a package that ships a binary without them is the failure
//!     this prevents. `src/LICENSE` and `src/COPYING` are both in that directory
//!     because both are part of the grant: see `NOTICE.md`.
//!
//! System mode installs none of that and builds nothing: no source was compiled
//! from this tree, so there is no artifact to describe, no header this build is
//! the source of, and nothing for a `.pc` to point at. `zig build` in that mode
//! says so on stdout.
//!
//! ## Published routes
//! ----------------
//!   * `dep.module("zstd")`: the Zig facade, `zig/root.zig`. This is the one
//!     registered module. It carries `link_libc`, the translated headers as
//!     `c`, and the library behind it.
//!   * `c` on that same module: the translated headers themselves, for a caller
//!     that needs a declaration the facade does not name. It is deliberately
//!     *not* registered as a module of its own: `addModule("c")` would make
//!     `dep.module("c")` resolve and hand a dependent the same declarations
//!     without the library that satisfies them, which is a reachability a
//!     dependent cannot tell from support.
//!   * `dep.artifact("zstd")`: the compiled native library, in bundled mode
//!     only, in whichever `-Dlinkage` selected. `libzstd.a` and `libzstd.so` are
//!     the names a C consumer's `-lzstd` needs, and `src/lib/libzstd.pc.in:14`
//!     spells `Libs: -L${libdir} -lzstd`.
//!   * the installed headers, library and `zstd.pc`, for a C consumer.
//!
//! `README.zig.md` states the same routes for a reader deciding what to import.

const std = @import("std");

/// The runtime-loading build half, owned by the API role.
///
/// `createModule` builds the generated dispatch that replaces
/// `translate.createModule()` under `-Druntime`; it makes the loader-core
/// module itself and re-exports `LoadSource`/`LoadError` from it.
/// `createCoreModule` builds that same core module for the *linked* branch,
/// where there is no dispatch to carry the types and the facade's `rt` import
/// is where they come from.
///
/// The two branches must not both call `createCoreModule`. `LoadSource` and
/// `LoadError` are this SDK's public types, so they have to be the *same* types
/// in one build: a second core instance would be a second, nominally distinct
/// `LoadSource`, and `zstd.load(source)` would be handing the facade's type to a
/// function expecting the dispatch's. `addGraph` is the only place that calls
/// either of them.
const graph = @import("runtime/graph.zig");

/// `build.zig.zon` itself. `@import` of the manifest is how a build script reads
/// `.version` without a second copy of it.
const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed. The parse is the loud part: a manifest whose
/// `.version` is not a semantic version fails to configure here rather than being
/// silently compared as something else.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package id, the name a dependent writes in its dependency map, the one
/// registered module and the C artifact. They are one name on purpose:
/// `dep.module("zstd")` and `dep.artifact("zstd")` describe the same library,
/// and `libzstd.a` is what Zig emits for an artifact called `zstd` because
/// `std.zig.system` prepends the platform's `lib` prefix. It is also the `-lzstd`
/// `src/lib/libzstd.pc.in:14` names.
const lib_name = "zstd";

/// The Zig facade. It re-exports the translated module as `c`.
const facade_source = "zig/root.zig";

/// The one header this package translates. It is a fork-authored wrapper whose
/// whole job is to name the three public headers upstream's C consumers include;
/// see the file for why it is a wrapper and not a copy.
const translate_header = "zig/translate.h";

/// Test root, owned by the API role.
const test_source = "tests.zig";

/// The deterministic example program, owned by the API role.
const example_source = "smoke.zig";

/// Where the native source lives. Every internal include in this tree is quoted
/// and relative to its own directory, so one include path given to every C
/// compilation, to the translation and to the module a dependent imports is what
/// keeps all of `src/lib/` resolvable - and it is the directory the three public
/// headers are in, which is what `zig/translate.h` includes by bare name.
const source_dir = "src/lib";

/// Upstream's own release, read out of `src/lib/zstd.h:112-114`.
/// `build.zig.zon .version` carries the same string; `build` refuses to
/// configure when the two drift apart, so this string, the pkg-config `Version:`
/// field, the shared object's file name and the package manifest cannot describe
/// two different releases.
const upstream_version: std.SemanticVersion = .{ .major = 1, .minor = 5, .patch = 7 };

/// The shared object's ABI version. See "Static and shared delivery" above: the
/// major is upstream's own `SHARED_EXT_MAJOR` (`src/lib/Makefile:90`), and the
/// minor and patch are the release this build compiles, which is what
/// `SHARED_EXT_VER` at `:91` uses.
const abi_version: std.SemanticVersion = .{ .major = 1, .minor = 5, .patch = 7 };

/// The eight units of `common/`, in `$(sort)` order.
///
/// `src/lib/libzstd.mk:149`, appended unconditionally by
/// `src/lib/Makefile:33`.
const common_sources = [_][]const u8{
    "src/lib/common/debug.c",
    "src/lib/common/entropy_common.c",
    "src/lib/common/error_private.c",
    "src/lib/common/fse_decompress.c",
    "src/lib/common/pool.c",
    "src/lib/common/threading.c",
    "src/lib/common/xxhash.c",
    "src/lib/common/zstd_common.c",
};

/// The fourteen units of `compress/`, in `$(sort)` order.
///
/// `src/lib/libzstd.mk:150`, appended by `src/lib/Makefile:35-37` while
/// `ZSTD_LIB_COMPRESSION` is 1.
///
/// `zstdmt_compress.c` is here because the wildcard is a wildcard: the
/// multithreaded compressor's whole body sits behind `ZSTD_MULTITHREAD`
/// (`src/lib/compress/zstdmt_compress.c:994` is the outer guard on the context
/// creation), and this build does not define that macro, so it contributes
/// almost nothing. It is not dropped: upstream compiles it, and dropping it would
/// make this list a statement about what is convenient rather than about what
/// upstream builds.
const compress_sources = [_][]const u8{
    "src/lib/compress/fse_compress.c",
    "src/lib/compress/hist.c",
    "src/lib/compress/huf_compress.c",
    "src/lib/compress/zstd_compress.c",
    "src/lib/compress/zstd_compress_literals.c",
    "src/lib/compress/zstd_compress_sequences.c",
    "src/lib/compress/zstd_compress_superblock.c",
    "src/lib/compress/zstd_double_fast.c",
    "src/lib/compress/zstd_fast.c",
    "src/lib/compress/zstd_lazy.c",
    "src/lib/compress/zstd_ldm.c",
    "src/lib/compress/zstd_opt.c",
    "src/lib/compress/zstd_preSplit.c",
    "src/lib/compress/zstdmt_compress.c",
};

/// The four C units of `decompress/`, in `$(sort)` order.
///
/// `src/lib/libzstd.mk:151`, appended by `src/lib/Makefile:39-41` while
/// `ZSTD_LIB_DECOMPRESSION` is 1.
const decompress_sources = [_][]const u8{
    "src/lib/decompress/huf_decompress.c",
    "src/lib/decompress/zstd_ddict.c",
    "src/lib/decompress/zstd_decompress.c",
    "src/lib/decompress/zstd_decompress_block.c",
};

/// The x86-64 assembly unit, collected by `src/lib/libzstd.mk:156`.
///
/// Whether it is compiled is `decompressAssembly`'s decision, per target; see
/// "The x86-64 assembly, decided per target" above.
const amd64_asm_source = "src/lib/decompress/huf_decompress_amd64.S";

/// The four units of `dictBuilder/`, in `$(sort)` order.
///
/// `src/lib/libzstd.mk:152`, appended by `src/lib/Makefile:47-49` while
/// `ZSTD_LIB_DICTBUILDER` is 1.
///
/// `divsufsort.c` is the one compiled unit that is not Meta's own work: it is
/// Yuta Mori's libdivsufsort-lite under the MIT licence
/// (`src/lib/dictBuilder/divsufsort.c:1-25`), and `NOTICE.md` inventories it
/// separately from the other thirty-three.
const dictbuilder_sources = [_][]const u8{
    "src/lib/dictBuilder/cover.c",
    "src/lib/dictBuilder/divsufsort.c",
    "src/lib/dictBuilder/fastcover.c",
    "src/lib/dictBuilder/zdict.c",
};

/// The three legacy decoders `ZSTD_LEGACY_SUPPORT=5` selects.
///
/// `src/lib/libzstd.mk:202-206` fills `ZSTD_LEGACY_FILES` from
/// `ls legacy/*.c | grep 'v0[5-7]'` because `:35` defaults
/// `ZSTD_LEGACY_SUPPORT` to 5, and `src/lib/Makefile:33` adds them
/// unconditionally. `legacy/zstd_v01.c` through `zstd_v04.c` exist in the
/// tarball and are not in this list, which is exactly what the default selects.
const legacy_sources = [_][]const u8{
    "src/lib/legacy/zstd_v05.c",
    "src/lib/legacy/zstd_v06.c",
    "src/lib/legacy/zstd_v07.c",
};

/// Whether this target gets the x86-64 assembly unit.
///
/// The rule and its evidence are in "The x86-64 assembly, decided per target"
/// above: `src/lib/common/portability_macros.h:145` requires `__x86_64__`, and
/// the file's whole body is behind the macro that condition feeds
/// (`:41`). On any other architecture the unit assembles to nothing, so it is
/// left out rather than added as a build step whose output is an empty object.
fn decompressAssembly(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch == .x86_64;
}

/// The three public headers, installed and translated.
///
/// `src/lib/module.modulemap:2,27,32` names `zstd.h`, `zdict.h` and
/// `zstd_errors.h` as the three headers of the `libzstd` module, and
/// `zig/translate.h` includes the same three. `src/lib/module.modulemap` is
/// upstream's own packaging input and travels with the tree unedited.
const public_headers = [_][]const u8{
    "src/lib/zstd.h",
    "src/lib/zstd_errors.h",
    "src/lib/zdict.h",
};

/// The licence and provenance records `zig build` installs under
/// `share/licenses/zstd/`.
///
/// Both of Zstandard's own texts are here, not one of them. `src/LICENSE` is the
/// BSD-3-Clause text and `src/COPYING` is the GPL-2.0 text, and the grant is
/// "either, at your option" (`src/lib/libzstd.mk:8`), so a package that installs
/// only the BSD text and calls the tree BSD has dropped half of what upstream
/// published. `FORK-LICENSE.md` records that this fork took the BSD-3-Clause
/// option for its own files; it does not remove upstream's alternative.
/// `README.upstream.md` is upstream's own README, byte for byte.
const licence_records = [_][]const u8{
    "src/LICENSE",
    "src/COPYING",
    "src/README.md",
    "README.upstream.md",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "FORK-NOTES.md",
    "CHANGELOG.md",
};

/// Language level for every C translation unit, pinned.
///
/// See "Compile line" above for why a level is pinned at all and why C99: the
/// pinned tree is tested at C89 (`src/Makefile:435`) and C99
/// (`src/Makefile:443`), `libzstd.mk` passes none, and a build that inherits its
/// dialect from the host compiler is not reproducible.
const c_flags = [_][]const u8{"-std=c99"};

/// Which `libzstd` the package links.
const Library = enum {
    /// Compiled from the pinned upstream C in `src/lib/`.
    bundled,
    /// The installed library `systemIntegrationOption("zstd")` selected.
    system,
};

/// The cross-compilation matrix `check` walks when no target is named.
///
/// The order is the one this workspace uses everywhere; nothing is skipped, and
/// nothing here is pre-judged: if a target cannot be satisfied on the machine
/// running the gate, that is for the gate to report.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
};

/// The name one artifact carries in this build graph.
///
/// The published graph installs `libzstd.a` / `libzstd.so`, the names
/// `src/lib/libzstd.pc.in:14`'s `-lzstd` resolves. A check graph installs
/// nothing, so its artifacts carry the target triple instead: five targets share
/// one build graph, and five steps all called "zstd" make `--summary all`
/// impossible to read.
fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// One target's platform configuration.
///
/// Resolved from the target being built, never from the build host, and read by
/// the library, the translation and the pkg-config file so that one fact is in
/// one place.
const Platform = struct {
    /// The macros this target's compile line carries beyond the ones every
    /// target gets.
    macros: []const [2][]const u8,
    /// Whether this target needs the MinGW `%zu` compatibility macro.
    ///
    /// `src/lib/libzstd.mk:110-112` adds `__USE_MINGW_ANSI_STDIO` for
    /// `TARGET_SYSTEM=Windows_NT`, and nothing else in the tree adds it.
    mingw_stdio: bool,
    /// Whether `__declspec` exists on this target, which is the only place
    /// `src/lib/zstd.h:47-51`'s export/import split means anything.
    dll: bool,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        if (target.result.os.tag == .windows) {
            // Upstream's MinGW target adds the stdio macro and nothing else
            // platform-specific, and `TARGET_SYSTEM` is documented at
            // `src/lib/libzstd.mk:75-79` as the way a cross-build says
            // "Windows".
            return .{
                .macros = &.{.{ "__USE_MINGW_ANSI_STDIO", "1" }},
                .mingw_stdio = true,
                .dll = true,
            };
        }
        // Everything else: no platform macro at all. Zstandard's own
        // configuration is entirely in its preprocessor conditionals -
        // `src/lib/common/portability_macros.h` for the assembly,
        // `src/lib/common/zstd_deps.h` for the allocator, `src/lib/common/threading.h`
        // for the thread backend - and none of them has a fork-authored
        // answer to give it. A macro here would be this package changing what
        // upstream's C does, not configuring where it runs.
        return .{ .macros = &.{}, .mingw_stdio = false, .dll = false };
    }

    /// One line naming this platform configuration, for the configure-time
    /// output. It reads what `forTarget` resolved rather than deciding anything
    /// of its own, so the printed line cannot disagree with what was compiled.
    fn kind(platform: Platform) []const u8 {
        if (platform.mingw_stdio) return "__USE_MINGW_ANSI_STDIO (upstream's MinGW recipe)";
        return "no platform macro; upstream's own preprocessor conditionals decide";
    }
};

/// One target's library and facade.
const Graph = struct {
    /// The compiled C library, or null in system mode, where nothing is
    /// compiled from this tree.
    c_lib: ?*std.Build.Step.Compile,
    /// The facade module, with `c` bound to the translated headers for the
    /// library this graph compiled or selected.
    module: *std.Build.Module,
    /// The platform this graph compiled for, so a caller that adds a program
    /// does not resolve the target a second time and risk disagreeing.
    platform: Platform,
};

/// Builds one target's library and facade.
///
/// `public` chooses between the package module set, which is what a dependent
/// reaches through `dep.module("zstd")`, and a private module. A cross-target
/// check needs the private form: modules are registered by name against the
/// whole build, so registering `zstd` once per matrix target would leave only
/// the last of them reachable and silently stop checking the rest. The
/// translated headers are imported rather than registered in both forms; the
/// published routes are named above.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    // Every route into this file passes through here: `build` for the published
    // graph and for `-Dtarget=`, and `add_target_check` for each matrix cell.
    // `runConsumer` reaches it too, one process later: it shells out to a nested
    // `zig build` in `consumer/` that resolves this package as a dependency, and
    // that nested build runs this `build()`.
    const platform = Platform.forTarget(target);
    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, artifactName(b, target, public))
    else
        null;

    // The linkage this target can actually carry, resolved here so the
    // translation and the library cannot disagree about it. `add_c_library`
    // resolves the same value for the same reason.
    const delivered = deliveredLinkage(target, linkage);

    // System mode contributes nothing to the translation's include path, for the
    // reason that comment gives: there the installed headers are the ones the
    // translation describes.
    const no_macros: []const [2][]const u8 = &.{};
    const translate_macros = if (library == .bundled) platform.macros else no_macros;
    const translate_include: ?std.Build.LazyPath =
        if (library == .bundled) b.path(source_dir) else null;
    const translate_dll = library == .bundled and delivered == .dynamic and platform.dll;

    const translate = b.addTranslateC(.{
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (translate_include) |dir| {
        // `zig/translate.h` includes `<zstd.h>`, `<zdict.h>` and
        // `<zstd_errors.h>`, and this is the only header search path the
        // translation has. Without it the translation would bind to whatever
        // libzstd happens to be installed on the build machine and describe that
        // library's declarations rather than the ones this graph compiles.
        // System mode deliberately does not add it: there the same three lines
        // are reached through the installed prefix `zstd.pc` names, never
        // through this tree.
        translate.addIncludePath(dir);
    }

    // Upstream's own macro from `src/lib/libzstd.mk:109`, verbatim. It
    // namespaces the vendored xxHash so a consumer's own xxHash cannot collide
    // with it; the translation has to agree with the compiled C or the constant
    // it names is a different one.
    translate.defineCMacro("XXH_NAMESPACE", "ZSTD_");

    // Upstream's switch for the experimental surface, `src/lib/zstd.h:104-109`.
    // The facade wraps `ZSTD_frameHeaderSize` (`src/lib/zstd.h:1508`) and
    // `ZSTD_CCtx_getParameter` (`:2364`), both `ZSTDLIB_STATIC_API` and both
    // invisible without it. It goes on the translation and *not* on the
    // library's C lines; see "Compile line" above for why the library's own
    // headers already define it seven times and a command-line definition would
    // collide with them.
    translate.defineCMacro("ZSTD_STATIC_LINKING_ONLY", "1");

    // Upstream's own switch for the dictionary builder's experimental
    // surface, `src/lib/zdict.h:280`, and the exact parallel of the macro
    // above. The facade publishes `ZDICT_DICTSIZE_MIN`
    // (`src/lib/zdict.h:305`) and `ZDICT_CONTENTSIZE_MIN` (`:307`), both
    // inside the block that guard opens and both invisible without it. It goes
    // on the translation only, for the same reason, and it changes no
    // declaration the facade already had: `zdict.h:481` closes the block
    // again and the stable `ZDICTLIB_API` half at `:20-277` is untouched.
    translate.defineCMacro("ZDICT_STATIC_LINKING_ONLY", "1");

    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    if (translate_dll) {
        // The declaration half of upstream's DLL split. `src/lib/zstd.h:47-51`
        // turns `ZSTDLIB_API` into `__declspec(dllimport)` on
        // `ZSTD_DLL_IMPORT`, which is what a consumer of the DLL needs, and
        // `:1238-1244` does the same for `ZSTDLIB_STATIC_API`, which is where
        // `ZSTD_frameHeaderSize` sits. `add_c_library` gives the definitions the
        // `ZSTD_DLL_EXPORT` half.
        translate.defineCMacro("ZSTD_DLL_IMPORT", "1");
    }

    // System mode: the installed `zstd.pc` names the include directory this
    // translation needs and the library the module binds, and this one query
    // gives both to both. `createModule` carries the entry onto the `c` module
    // below, so a dependent compiles and links against the same prefix the
    // declarations were read from.
    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    // Where the runtime-loading seam is
    // ---------------------------------
    // `runtime/graph.zig`, which the API role owns, exposes
    //
    //     pub fn createModule(
    //         b: *std.Build,
    //         translate: *std.Build.Step.TranslateC,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    //     pub fn createCoreModule(
    //         b: *std.Build,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    // and `-Druntime` substitutes the first for `translate.createModule()`. It
    // takes the `TranslateC` step this function has already built, so the
    // generated dispatch keeps the exact translated type and constant namespace
    // rather than compiling a second copy of the native extern declarations and
    // casting between two nominally distinct Zig modules: `c.ZSTD_CCtx` in the
    // facade and the declaration behind the table are one type.
    //
    // `-Dlinkage` is orthogonal and keeps meaning what it means: it selects
    // which artifact this build *delivers* and installs, never which one the
    // module dispatches through.
    //
    // The `rt` import is for the linked branch only, and the reason is the
    // nominal type rather than the code: `graph.createModule` creates the one
    // core-module instance the generated dispatch uses and re-exports
    // `LoadSource`/`LoadError` from it; a second instance created here for the
    // facade would be a *different* `LoadSource`, and `zstd.load(source)` would
    // be handing the facade's type to a function expecting the dispatch's. One
    // instance per build, no more. In a linked build there is no dispatch, so
    // the facade's own `rt` import is where those two public types come from;
    // `zig/root.zig` picks between the two with a comptime branch on
    // `runtime_loaded`, so the module a configuration does not need is never
    // resolved and never compiled.
    if (runtime_loaded) {
        // A loaded provider must arrive through the platform loader, so the link
        // line names nothing. Linking the archive as well would make the linker
        // resolve the same symbols statically and the runtime route would quietly
        // be a linked one. The artifact itself is still built and installed,
        // because delivery and dispatch are separate questions: the whole point
        // of the mode is that a caller may name a provider this tree did not
        // build.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // The translated headers are imported, never registered.
        // `addModule("c")` would make `dep.module("c")` resolve and hand a
        // dependent the same declarations without the library that satisfies
        // them; `zstd.c` on the facade is the supported way in and carries the
        // facade's own linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        // System mode names the installed library through the translation above,
        // so this module already carries it.
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // The same include path as the archive's own module, on the module a
    // dependent actually imports, so a dependent that compiles its own C
    // against this package finds the same headers the core was compiled with.
    // System mode does not add it: the installed include directory reaches the
    // dependent through the same `zstd.pc` entry.
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compiles the C library for one target: the 34 units above, and nothing else.
///
/// `requested` is the linkage the caller asked for. What it selects is the
/// artifact and nothing else about the compilation. What a shared artifact adds
/// is its own requirements - the soname, PIC, the export surface and the DLL
/// macro split - and `delivered` is what this target can actually carry.
///
/// `name` is the artifact name this graph installs or reports; see
/// `artifactName`.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    requested: std.builtin.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // See "Static and shared delivery" for where `abi_version` comes from.
        // `version` is null for a static archive, which has no soname and no
        // versioned file name.
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("zstd.def", "EXPORTS\n")
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // libc, because every translation unit reaches the C library for its
            // own vocabulary: `src/lib/common/zstd_deps.h:39-41` opens
            // `<limits.h>`, `<stddef.h>` and `<string.h>`, `:64` opens
            // `<stdlib.h>`, `:94` opens `<assert.h>`, and `:106` opens
            // `<stdio.h>`. That is the whole of it.
            .link_libc = true,
            // A shared library is position-independent whether or not this says
            // so; naming it makes the requirement explicit.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // For the sources' own quoted includes: every file in `src/lib/` reaches its
    // neighbours by bare name, and `src/lib/decompress/huf_decompress_amd64.S:11`
    // reaches `../common/portability_macros.h` by path.
    c_mod.addIncludePath(b.path(source_dir));

    // The platform configuration for the target being built, not for the host.
    // `addGraph` gives the translation the same list.
    for (platform.macros) |macro| {
        c_mod.addCMacro(macro[0], macro[1]);
    }

    // Upstream's own two macros, exactly as `src/lib/libzstd.mk:109` spells
    // them. `XXH_NAMESPACE=ZSTD_` namespaces the vendored xxHash so a consumer's
    // own xxHash cannot collide with it; `DEBUGLEVEL=0` is upstream's own
    // default from `:108` and selects the quiet error path.
    //
    // `ZSTD_LEGACY_SUPPORT=5` is the third, and its value comes from
    // `src/lib/libzstd.mk:35`; `:207` puts it on the compile line. It is what
    // makes the three `legacy/` units worth compiling and what tells
    // `ZSTD_getFrameContentSize` to look at a legacy frame at all
    // (`src/lib/decompress/zstd_decompress.c:571-576`).
    c_mod.addCMacro("XXH_NAMESPACE", "ZSTD_");
    c_mod.addCMacro("DEBUGLEVEL", "0");
    c_mod.addCMacro("ZSTD_LEGACY_SUPPORT", "5");

    // The DLL macros, on the line that compiles the *definitions*. Only where
    // `__declspec` exists: `src/lib/zstd.h:47-51` turns `ZSTDLIB_API` into
    // `__declspec(dllexport)` on `ZSTD_DLL_EXPORT`, and on an ELF or Darwin
    // build defining it would be inert noise on a default-visibility symbol.
    // `addGraph` gives the translation the `ZSTD_DLL_IMPORT` half.
    //
    // Both halves are defined once for the whole library rather than once per
    // unit, which is what a module-level macro is: all 34 units are compiled
    // into one image, so one set of macros is what one image can have.
    if (platform.dll and linkage == .dynamic) {
        c_mod.addCMacro("ZSTD_DLL_EXPORT", "1");
    }

    for (common_sources) |source| addCUnit(c_mod, b, source);
    for (compress_sources) |source| addCUnit(c_mod, b, source);
    for (decompress_sources) |source| addCUnit(c_mod, b, source);
    for (dictbuilder_sources) |source| addCUnit(c_mod, b, source);
    for (legacy_sources) |source| addCUnit(c_mod, b, source);

    // The one unit whose inclusion is a per-target decision. See
    // "The x86-64 assembly, decided per target" above: `ZSTD_ENABLE_ASM_X86_64_BMI2`
    // (`src/lib/common/portability_macros.h:143-150`) requires `__x86_64__`, so
    // on every other architecture the file assembles to an empty object and is
    // left out instead of costing a build step.
    if (decompressAssembly(target)) addCUnit(c_mod, b, amd64_asm_source);

    // Nothing is linked beyond libc. See "What this package does not link" above
    // for the search that established it: no compiled expression in these 34
    // units calls the C math library, and the thread library appears only in
    // `src/lib/Makefile:63`'s dynamic-library flags, which this build's shared
    // object does not need because `ZSTD_MULTITHREAD` is not defined here
    // either.
    //
    // `linkSystemLibrary` takes its `LinkSystemLibraryOptions` explicitly and
    // has no defaults for the call, so the empty options struct is the shape
    // that would be used: `needed`, `weak`, `use_pkg_config`,
    // `preferred_link_mode` and `search_strategy` all keep the values
    // `LinkSystemLibraryOptions` declares. Nothing is named here, which is the
    // finding rather than an omission.

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    // Installing the headers also puts them on the include path of anything
    // that links this artifact, so a C consumer needs nothing from this tree to
    // call it. These three are the whole of the installed header list, and they
    // are the three `src/lib/module.modulemap` names.
    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.fs.path.basename(header));
    }

    return c_lib;
}

/// Adds one upstream C unit, with the pinned language level.
///
/// One place, so that the 34 units cannot disagree about their flags: the
/// `.c`/`.S` distinction is taken from the extension, and `.S` is
/// preprocessed assembly - which is what `huf_decompress_amd64.S:11` needs, since
/// it opens `../common/portability_macros.h` for its macros.
fn addCUnit(
    c_mod: *std.Build.Module,
    b: *std.Build,
    source: []const u8,
) void {
    c_mod.addCSourceFile(.{
        .file = b.path(source),
        .flags = &c_flags,
    });
}

/// Gives an ELF shared library the export surface the installed headers declare.
///
/// Export the two public namespaces and nothing else. Upstream marks its
/// internals `ZSTDLIB_HIDDEN` (`src/lib/zstd.h:38-45`), so on a build with
/// hidden visibility they would not appear anyway; naming the two namespaces is
/// what keeps `POOL_create`, `HUF_decompress4X1_..._asm_loop` and the rest out
/// of the dynamic symbol table on a build that does not hide them.
///
/// Mach-O has no version script that GNU ld or lld reads the same way, so this
/// does nothing for Darwin: a `libzstd.1.dylib` from this build exports
/// Zstandard's internals as well as its API. That is a real difference from the
/// ELF object and it is reported by `build` rather than hidden.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;

    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("zstd.map",
        \\ZSTD_1 {
        \\  global:
        \\    ZSTD_*;
        \\    ZDICT_*;
        \\  local:
        \\    *;
        \\};
        \\
    ));
}

/// Compiles the full graph, the tests and the example for one matrix target and
/// attaches all of them to `step`.
///
/// Building the test binary and the example is what makes this a check of the
/// facade rather than of an unreferenced archive: Zig analyzes a function body
/// only when something calls it, and `tests.zig` and `smoke.zig` call the
/// facade. The full 34-unit C closure is compiled by the same graph, so a target
/// that cannot build Zstandard fails here rather than at the first install.
/// Nothing is run here, so every result this step produces is compile evidence
/// and not a claim that a cross-built binary executed.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // The triple names the cross artifacts. Five targets in one build graph
    // otherwise produce five steps called "zstd", which makes `--summary all`
    // useless for telling them apart.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("zstd-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("zstd-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which only writes `b.dependency("zstd", ...)` and `dep.module("zstd")`
/// gets a working, correctly linked library, with the archive and libc arriving
/// through the module and nothing else.
///
/// Everything this build resolved travels with it: the target and CPU, the
/// optimize mode, the library mode, the linkage and dispatch shapes, the
/// executor switches, both cache directories, the install prefix, the job width
/// and the summary. An argument left behind would be a proof of a configuration
/// nobody asked for.
///
/// Run when this host can execute the selected target, and install otherwise:
/// `hostCanExecute` asks exactly what `std.Build.Step.Run` asks of a foreign
/// binary, so the decision here and the nested run cannot disagree.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // The same query's other half. The triple above names the architecture, the
    // OS and the ABI; it carries no CPU model and no feature set, and `cpu` is a
    // separate option of its own. `serializeCpu` writes `native` for a query that
    // named no CPU and `baseline` for a cross query that named none, and
    // `Target.Query.parseCpu` recognises both spellings, so the nested
    // `standardTargetOptions` resolves this build's selection rather than one of
    // its own. `addArg` copies each argument, so these temporaries can go right
    // after.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the
    // nested build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // The model and its feature set, for the reason the serialization above
    // gives. Without it the nested build would compile the consumer at a
    // baseline CPU on a host that built the library for something else, and the
    // step would prove a configuration nobody asked for.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The delivery and dispatch options have to reach the nested build or the
    // consumer would silently check the default graph and say nothing about the
    // configuration that was asked for.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Both spellings go, not only the true one, so a cell's configuration is
    // stated rather than inferred from a default and the flag cannot be dropped
    // on the way down. `consumer/build.zig` reads the option and hands it to
    // `b.dependency("zstd", ...)`, and that value is what
    // `consumer/src/main.zig` branches on at comptime.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // The mode *this* build resolved, which is a different question from which
    // option asked for it. `b.systemIntegrationOption` is fed by the build
    // runner's `-fsys=`/`-fno-sys=` flags and is never an entry in the `-D`
    // map, so forwarding `-Dsystem` would set the nested graph's *default* and
    // leave the answer to that graph's own runner instead of this build's. A
    // dependency shares its parent's `Graph`, so the runner flag reaches the
    // dependency's own `systemIntegrationOption` call unchanged.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // Forward the selected executor and its dynamic-linker support.
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The nested build carries this workspace's job count and summary in its own
    // command line. Nothing can append a `-j` to a `Run` step's command, so a
    // nested build left to derive its own width takes `cpu_count - 1` instead,
    // and the consumer this step proves then compiles at a different width from
    // the build that asked for it - and at a different width again on whichever
    // machine runs the gate. `--summary all` is for the same reader: the nested
    // build is a separate graph whose steps are named after the consumer
    // package, and a failure inside it is otherwise one unnamed line.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // A null `path` means "the current directory", and the working directory is
    // already the consumer package, so the default is right.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache is inherited whole rather than subdirectoryed: it is one
    // shared store of packages and hashes, so a nested build left to resolve its
    // own would fetch again what this one already holds, and would write outside
    // the root this workspace approved.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // The install prefix this invocation resolved, handed on when the caller named
    // one. A nested `zig build` left to resolve its own installs into
    // `consumer/zig-out` - a build artefact inside a source package - rather than
    // into the directory the caller asked for. A relative `--prefix` would
    // resolve against the working directory set above, `consumer/`, and not
    // against this build's root, so it is made absolute before it is handed on.
    // `DESTDIR` needs no forwarding, because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`: `--` is where the build
    // runner stops parsing options and keeps the rest as `b.args`, so this `--`
    // has to follow every argument above. `consumer/src/main.zig` documents
    // `--provider <path>` as a command-line input, and this is the only place
    // those words can enter the nested graph at all.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` is the predicate `std.Build.Step.Run`
/// applies to the artifact it is about to spawn, and `allow_*` carries this
/// build's own executor switches, so the two cannot disagree. `link_libc` holds
/// in every mode this package builds; the `.qemu` arm carries `Run`'s own second
/// gate.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `consumer/` builds its executable with `b.addExecutable` and no
        // linkage, so `Run`'s musl half of `need_cross_libc` never holds here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Not a yes on its own: `Run` fails a cross GNU libc target given no
        // `--libc-runtimes`, so this step installs it instead. Every other QEMU
        // case still runs.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Same OS and CPU with no dynamic linker to load, or an architecture and
        // system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Writes `lib/pkgconfig/zstd.pc` and installs it.
///
/// Every field of the output is upstream's: `src/lib/libzstd.pc.in` is
/// upstream's own template and this function only fills in its placeholders.
/// That is worth more than writing a fresh `.pc` here, because the template
/// already states the field values upstream intends:
///
///   * `Name`, `Description`, `URL` and `Version` - `:10-13`, with the version
///     read out of `zstd.h` by `libzstd.mk:82-90` in upstream's own build and
///     out of `build.zig.zon` in this one.
///   * `prefix` is `${pcfiledir}/../..` rather than a substituted absolute path.
///     This graph does not know where `--prefix` will point when it writes the
///   file, and pkg-config resolves `${pcfiledir}` against the `.pc` it found, so
///   the installed file is correct wherever the prefix landed - including a Nix
///   store path that is only known at build time. `exec_prefix`, `includedir` and
///   `libdir` are upstream's own `@EXEC_PREFIX@`, `@INCLUDEDIR@` and `@LIBDIR@`
///   (`:5-8`) and become `${prefix}/...`.
///   * `Libs` is `-L${libdir} -lzstd @LIBS_MT@` (`:14`). The library name does
///     not change with linkage: a C consumer asks for `-lzstd` and the linker
///     resolves it to `libzstd.a` or, through the `libzstd.so` symlink, to the
///     shared object.
///   * `Libs.private` and the `Cflags` suffix are both `@LIBS_MT@`
///     (`:15-16`). Upstream fills that placeholder from `LDFLAGS_DYNLIB`, which
///     `src/lib/Makefile:62-63` makes `-DZSTD_MULTITHREAD -pthread` - but this
///     package's shared object is *not* built with `ZSTD_MULTITHREAD` (see
///     "Compile line" above), so a `-pthread` here would name a link-time
///     dependency this build does not have. Both placeholders are therefore
///     empty, and that is the honest answer for this configuration rather than a
///     divergence from the template.
fn add_pkg_config(b: *std.Build) void {
    const files = b.addWriteFiles();
    // The returned step is bound to the install step. `addInstallFileWithDir`
    // *creates* a `Step.InstallFile` and nothing more - dropping the return value
    // builds nothing and installs nothing, and the omission is silent: the step
    // exists, it is simply never in the graph, so an install that was missing its
    // `.pc` file would still report success.
    const install_pc = b.addInstallFileWithDir(
        files.add("zstd.pc", b.fmt(
            \\# zstd.pc for the Zstandard 1.5.7 SDK.
            \\#
            \\# Generated from upstream's own template, src/lib/libzstd.pc.in, with
            \\# the placeholders it declares filled in. `prefix` is pcfiledir-relative
            \\# so the installed file is correct wherever --prefix put it. @LIBS_MT@
            \\# appears twice in the template, in Libs.private and in Cflags, and is
            \\# empty here because this build does not define ZSTD_MULTITHREAD.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: zstd
            \\Description: fast lossless compression algorithm library
            \\URL: https://facebook.github.io/zstd/
            \\Version: {f}
            \\Libs: -L"${{libdir}}" -lzstd
            \\Libs.private:
            \\Cflags: -I"${{includedir}}"
            \\
        , .{upstream_version})),
        .prefix,
        "lib/pkgconfig/zstd.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs the carried licence texts and provenance records under
/// `share/licenses/zstd/`.
///
/// A private repository removes no upstream obligation. Zstandard's grant has
/// two texts and both are installed, because upstream publishes both and says so
/// per file: `src/lib/libzstd.mk:5-8` points at `LICENSE` for the BSD-style
/// license and at `COPYING` for the GPLv2 and lets the recipient choose. A
/// package that installed one and dropped the other would not be narrower than
/// upstream, it would be misreporting it. `src/lib/libzstd.pc.in:3` carries a
/// third, weaker statement - "BSD 2-Clause License" - that does not match the
/// three-clause text in `src/LICENSE`; `NOTICE.md` records the discrepancy
/// rather than resolving it silently.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        // Bound, for the reason `add_pkg_config` says.
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/zstd/{s}", .{std.fs.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Link an installed libzstd instead of compiling src/lib/, and translate " ++
            "the installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"zstd\"); a build runner that " ++
            "decides the mode itself (-fsys=zstd) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and what " ++
            "upstream's own lib/Makefile builds) or as a real shared object with " ++
            "upstream's ZSTD_1 soname. This selects the delivery and never the " ++
            "dispatch: the same 34 C units are compiled either way. In system " ++
            "mode this graph builds no artifact at all, so there the option names " ++
            "the kind of installed library to bind to instead, and it defaults " ++
            "to dynamic.",
    );

    // Two defaults, because the two modes had two. The bundled graph compiled a
    // static archive before this option existed and must keep doing so, because
    // that is what `src/lib/Makefile` produces; `linkSystemLibrary`'s own default
    // is `.dynamic`, and system mode must keep that too. Deriving one from the
    // other would silently change a consumer's linkage in the mode that option
    // was not written for.
    const linkage: std.builtin.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // `-Druntime` selects the *dispatch*, and it is orthogonal to `-Dlinkage`:
    // the option says which artifact this build delivers and installs, this one
    // says whether the Zig facade calls it through a link line or through a
    // table an explicit `load` fills. Under `-Druntime` nothing is linked into
    // the facade module at all, so a caller may name a provider this tree did
    // not build - and the artifact is still built and installed, so a caller may
    // equally name the one it did.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated headers and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    // `build.zig.zon .version` and the version this build stamps into
    // `zstd.pc`, names into the shared object's file name and documents in four
    // other places are one fact. `std.SemanticVersion.parse` fails loudly rather
    // than wrapping a non-version, and the comparison catches a manifest edited
    // without the source it describes.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/lib/zstd.h:112-114; see UPSTREAM.md");
    }

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    // In system mode there is no artifact from this tree to install, and
    // installing an empty stand-in would be a claim this build cannot make.
    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b);
        install_licence_records(b);
    }

    // `zig build` also compiles the example. The example is the cheapest thing
    // that proves the facade, the translated headers and the C archive agree on
    // types, symbols and link-time dependencies. It is compiled, not installed:
    // it is a proof, not a deliverable.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = "zstd-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // A run artifact already depends on building the executable, which depends
    // on compiling the C and linking the facade. `zig build smoke` deliberately
    // does not depend on the install step: installing is `zig build`'s job and
    // conflating the two would make a smoke run depend on the install layout.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // The test root is `tests.zig`, which names the test blocks; a root that
    // only re-exported them would discover no tests and still exit zero.
    // `addRunArtifact` is used rather than a plain compile so that this is a real
    // runnable test step for whatever `-Dtarget` names: a foreign target is left
    // to whichever executor the cross-test harness detects, and this build does
    // not decide that.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = "zstd-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    // The separate consumer package, built as its own `zig build`. It runs when
    // this host can execute the selected target and installs when it cannot,
    // which is `hostCanExecute` rather than a query predicate: a cross-compiled
    // consumer binary cannot run here, and a native one can run under an enabled
    // executor. An install is compile evidence and nothing more.
    //
    // `library` is the mode `build` resolved, not the option a caller typed, so
    // the nested build is asked for the configuration this build is actually in.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // The cross target gate. Compiling the tests, the example and the whole
    // 34-unit C closure for each target is what makes this a check of the facade
    // rather than of an unreferenced archive. Nothing runs here.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "the five check targets without running any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        // One matrix, whatever the delivery. `-Dlinkage` selects the artifact
        // rather than the set of targets, and a caller who names a target with no
        // dynamic linker by hand is refused by `deliveredLinkage`.
        //
        // `[0..]`, not `.*`: `.*` is for dereferencing a single optional or
        // error-union payload, so the pointer-to-array has to become a slice
        // before it can be iterated.
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    // Which platform macros this configuration compiled, which artifact it hands
    // back and how many units went into it are facts worth reading out of the
    // build rather than inferring from a cache directory. These are
    // configure-time lines, not gate results: nothing has been compiled when they
    // print.
    if (published.c_lib != null) {
        // The assembly unit is a per-target decision (`decompressAssembly`), so
        // the count is read from that rule rather than asserted. Printing a
        // hard 1 here would claim an x86-64 build unit for an aarch64 one.
        const asm_units: usize = if (decompressAssembly(target)) 1 else 0;
        std.debug.print("zstd: {d} C units ({d} common, {d} compress, {d} decompress, {d} dictBuilder, {d} legacy, {d} x86-64 asm on this target), C99\n", .{
            common_sources.len + compress_sources.len + decompress_sources.len +
                dictbuilder_sources.len + legacy_sources.len + asm_units,
            common_sources.len,
            compress_sources.len,
            decompress_sources.len,
            dictbuilder_sources.len,
            legacy_sources.len,
            asm_units,
        });
        std.debug.print("zstd: {s}; ZSTD_LEGACY_SUPPORT=5, XXH_NAMESPACE=ZSTD_, DEBUGLEVEL=0, ZSTD_MULTITHREAD undefined\n", .{
            published.platform.kind(),
        });
        std.debug.print("zstd: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive libzstd.a (default, and what upstream's src/lib/Makefile builds)",
            .dynamic => b.fmt("shared object libzstd.so.{d}.{d}.{d}, soname libzstd.so.{d}", .{
                abi_version.major,
                abi_version.minor,
                abi_version.patch,
                abi_version.major,
            }),
        }});
        if (runtime_loaded) {
            // Dispatch is a separate fact from delivery, and a runtime-loaded
            // build links nothing into the facade module: the caller names a
            // provider with an explicit `load(source)` and the symbols arrive
            // through the platform loader. Printing it here is what keeps "the
            // library is still built and installed" from reading as "the module
            // links it".
            std.debug.print(
                "zstd: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // `wasm32-wasi` is not in `check_targets`. Nothing refuses it: this is a
        // plain-C library with no thread, no signal and no `dlopen` in this
        // configuration, so a static WASI cell is expected to compile. It is
        // absent because `deliveredLinkage` refuses a *shared* object on a target
        // whose OS has no dynamic linker and the matrix is walked for both
        // linkages; `zig build check -Dtarget=wasm32-wasi -Dlinkage=static` is
        // the one-target form. Said here rather than left to be inferred from
        // the list.
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            // See `setVersionScript`. A Mach-O or COFF shared object gets
            // upstream's `__declspec` split only where `__declspec` exists, so a
            // Darwin shared object from this build exports Zstandard's internal
            // symbols as well as its API. Said here rather than left to be
            // discovered by `nm -D`.
            std.debug.print(
                "zstd: {s} has no version-script mechanism here, so the shared " ++
                    "object exports Zstandard's internal symbols as well as its API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print("zstd: system libzstd (-lzstd) and the installed headers; this package installs nothing\n", .{});
        if (runtime_loaded) {
            std.debug.print(
                "zstd: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path. Other shared
/// targets need a dynamic linker. WASI has neither.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// The linkage this build delivers, or a refusal when the target cannot carry
/// what was asked for.
///
/// There is no substitution here, deliberately. Upstream's `src/lib/Makefile`
/// builds an archive and never a shared object unless it is asked to, so "deliver
/// a shared object" is this fork's addition and a caller who asks for it has
/// asked for a real shared object; handing back an archive under that name would
/// be a result the caller did not request and cannot tell from support. So a
/// shared request on a target whose OS has no dynamic linker stops here, with a
/// message naming the target, the reason and the way out.
///
/// `add_c_library`, `addGraph` and `build` all resolve through this one function,
/// so the artifact, the declarations it is paired with and the installed
/// `zstd.pc` cannot describe different linkages.
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.builtin.LinkMode,
) std.builtin.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // `std.debug.panic` with a format string, not `@panic` on a concatenated
        // string: `@tagName` of a run-time tag is not comptime known, and `++` on
        // a slice being concatenated has to be, so the message is formatted at
        // run time.
        std.debug.panic(
            "zstd: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it " ++
                "cannot carry a shared object at all. This build does not " ++
                "substitute a static archive for a requested shared object. Build " ++
                "that target with the default -Dlinkage=static, which is also what " ++
                "upstream's src/lib/Makefile produces there.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}