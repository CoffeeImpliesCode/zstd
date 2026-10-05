// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over the Zstandard 1.5.7 C implementation.
//!
//! No part of the format is reimplemented here. Every value that comes back out
//! of this module was produced by the C under `src/lib/`, reached through
//! `pub const c`, the module the translation step produces from
//! `zig/translate.h`. What the facade adds is the part a C header cannot
//! express: contexts that own themselves and say what closing them means, a
//! `size_t` that is either a byte count or an error rather than both, one
//! honest Zig error tag per Zstandard error code this build can actually
//! produce, and a size query that answers "known", "not in the frame" or
//! "undecodable" as three different things.
//!
//! ## Import routes
//!
//! One Zig route is published: `dep.module("zstd")` in the dependent's
//! `build.zig`, which is `@import("zstd")` in source. The translated headers are
//! `c` on that same module and are not published as a module of their own, so
//! the declarations and the library that satisfies them arrive through one
//! route. A C consumer takes the installed headers and the installed library
//! instead; `README.zig.md` names that layout.
//!
//! ```zig
//! const zstd = @import("zstd");
//! const std = @import("std");
//!
//! pub fn main() !void {
//!     const payload = "RFC 8878 raw block payload";
//!     var frame: [zstd.compressBoundConst(payload.len)]u8 = undefined;
//!     const written = try zstd.compress(&frame, payload, 3);
//!     var plain: [64]u8 = undefined;
//!     const read = try zstd.decompress(&plain, frame[0..written]);
//!     std.debug.print("{s}\n", .{plain[0..read]});
//! }
//! ```
//!
//! ## Allocation
//!
//! This module allocates nothing and wraps nothing on the heap, with two
//! exceptions a caller can see: `trainDictionary` takes an allocator and uses it
//! for one scratch buffer, and nothing else takes one. `Ctx`, `Dctx`, `CStream`,
//! `DStream`, `CDict` and `DDict` are one optional pointer each.
//!
//! That ownership is upstream's, and it is worth stating plainly.
//! `ZSTD_createCCtx` (`src/lib/zstd.h:281`) and `ZSTD_createDStream`
//! (`src/lib/zstd.h:911`) allocate the context itself, and the memory inside it
//! comes from `ZSTD_defaultCMem`, which `src/lib/common/zstd_deps.h:64-68`
//! spells as libc's `malloc`/`calloc`/`free` behind the `ZSTD_malloc`,
//! `ZSTD_calloc` and `ZSTD_free` macros. Nothing here can bound, intercept or
//! account for those allocations, and a Zig test allocator cannot be given a
//! leak oracle for memory a third-party allocator owns. `deinit` closes the
//! context, which releases all of it; that is the whole answer this module can
//! give.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The C library is linked, `c` is the translation of
//! the three public headers, and every call below is a direct call with no
//! table and no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is
//! a dispatch generated from the same translation step's output, and all 189
//! declarations the three headers make are resolved through the platform loader
//! when the caller calls
//!
//! ```zig
//! try zstd.load(.{ .path = "/usr/lib/libzstd.so.1" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet and there is no partial state to fall back on. The load
//! itself reports a missing file, a provider that does not export what the
//! headers declare, a request that cannot be honoured because a different
//! provider already won, or a reentrant call, as errors rather than as a
//! different library being loaded instead.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other, the
//! module has no unload and no reset, and it keeps the handle and its own copy
//! of the request to the end of the process.
//!
//! `runtime/library.zig` states what a provider must be, including the
//! Zstandard 1.5 external ABI family this SDK supports, which allocator owns
//! the memory, and which of upstream's parameter values are experimental.
//!
//! ## `size_t` is two things
//!
//! Almost every Zstandard entry point returns a `size_t` that is either a byte
//! count or an error code, told apart by `ZSTD_isError` (`src/lib/zstd.h:259`).
//! That is upstream's interface and this module does not change it: `pub const c`
//! carries the raw signature, and `isError`, `errorName` and `errorCode` are the
//! escape hatch for a caller who wants to make that decision for themselves.
//!
//! What the typed wrappers change is the *default*: every one of them tests the
//! result and returns an error union instead. A caller who reads the number as a
//! length without testing it has a bug upstream's own documentation warns about
//! (`src/lib/zstd.h:159`), and the typed surface removes the opportunity rather
//! than trusting the reader not to take it.
//!
//! ## Frames, not containers
//!
//! The one-shot and streaming entry points both speak in *frames*, and a frame
//! is not the whole buffer. `ZSTD_decompress` decodes every frame in its input
//! and writes their contents back to back
//! (`src/lib/decompress/zstd_decompress.c:1087-1166`), and a skippable frame
//! inside that input is stepped over rather than decoded
//! (`:1120-1132`). `ContentSize` exists because of that: upstream's
//! `ZSTD_getFrameContentSize` answers `0` for a skippable frame
//! (`src/lib/decompress/zstd_decompress.c:580-581`), and `0` is also the size of
//! an empty frame, so the raw `unsigned long long` cannot say which it saw. This
//! module reports what the header said and lets the caller ask `ContentSize` what
//! kind of answer it is.
//!
//! `ZSTD_frameHeaderSize` is narrower still: its own comment says it "only works
//! for formats ZSTD_f_zstd1 and ZSTD_f_zstd1_magicless"
//! (`src/lib/decompress/zstd_decompress.c:413`), so on a buffer that begins with
//! a *skippable* frame it does not report the skippable header's eight bytes -
//! it decodes the fifth byte as a Frame_Header_Descriptor and returns seven. The
//! facade says so on `frameHeaderSize` and `findFrameCompressedSize` is the call
//! that answers the question a caller actually has.
//!
//! ## Errors
//!
//! `Error` is one Zig error tag per Zstandard error code *this build can
//! produce*, and it is cut deliberately narrow. The taxonomy is
//! `src/lib/zstd_errors.h:60-98`; the set is justified on `Error` itself, tag
//! by tag, including the one stable code that no compiled unit raises and the
//! reason the codes at or above 100 collapse into a single tag. A code outside
//! the whole namespace becomes `UnrecognisedCode` rather than being guessed at.
//!
//! Every one of those tags is produced by reading `ZSTD_getErrorCode`
//! (`src/lib/zstd.h:260`), which upstream documents as the supported way to use
//! the list (`src/lib/zstd_errors.h:56-57`). Where upstream also offers
//! `ZSTD_getErrorString` (`src/lib/zstd_errors.h:100`) this module uses it for
//! `errorCodeText`, because it is upstream's own text for a code rather than a
//! restatement here.
//!
//! ## Lifetime
//!
//! Every context type owns exactly one C context. `init` creates one through
//! `ZSTD_create*` and `deinit` frees that one through `ZSTD_free*`, and nothing
//! else frees it. `deinit` takes `*Self`, frees through the same `c` route that
//! opened it - the same provider in a runtime-loaded build - and then clears the
//! field, so calling it twice on the same variable is a no-op rather than a
//! double free. Zig cannot make a struct non-copyable, so the remaining rule is
//! the usual one: copy a `Ctx` before `deinit` and you have two owners of one
//! context, and only one of them should free it.
//!
//! `CDict` is worth one extra sentence. `src/lib/zstd.h:994` states that
//! "`@dictBuffer` can be released after `ZSTD_createCDict` creation, because its
//! content is copied within CDict", so a `CDict` owns its copy and the caller's
//! dictionary buffer can go immediately. That is upstream's guarantee about its
//! own copy, not about this module's lifetime bookkeeping.
//!
//! ## Threading
//!
//! A `ZSTD_CCtx` or `ZSTD_DCtx` is plain mutable state with no locking, so it
//! belongs to one thread at a time. `src/lib/zstd.h:273-276` says so for the
//! compression context in its own words - "for parallel execution in
//! multi-threaded environments, use one different context per thread" - and
//! nothing else in this module is shared, because nothing else is stateful except
//! the loader's own table, which the loader core synchronises.

const std = @import("std");

/// The translated `zstd.h`, `zdict.h` and `zstd_errors.h`, i.e. upstream's ABI
/// exactly as published, with `ZSTD_STATIC_LINKING_ONLY` in effect.
///
/// This is the escape hatch for a declaration the facade does not name
/// (`ZSTD_compress2`, `ZSTD_getFrameHeader`, `ZSTD_estimateCCtxSize`, every
/// `ZSTD_c_experimentalParamN`), and for `ZSTD_frameHeaderSize` and
/// `ZSTD_CCtx_getParameter`, which upstream spells `ZSTDLIB_STATIC_API` and which
/// the facade wraps but also exposes. It is the same module the facade calls, on
/// the same library, so importing the facade is all a dependent needs to reach
/// it; it is not published under a name of its own.
///
/// The declarations are for whichever headers this build selected: bundled mode
/// translates `src/lib/zstd.h`, `src/lib/zdict.h` and `src/lib/zstd_errors.h`,
/// system mode the installed ones. A caller that reaches past the facade gets
/// upstream behaviour and inherits every obligation upstream declares.
///
/// `ZSTD_STATIC_LINKING_ONLY` is `build.zig`'s decision, made once for the
/// library's own C compilation and for this translation alike; it is not
/// something a dependent has to repeat to use this module. It is upstream's own
/// documented switch for the experimental surface (`src/lib/zstd.h:104-109`).
///
/// In a runtime-loading build this module is a generated dispatch instead of
/// the translation step's own output. It publishes the same namespace: every
/// type and constant is re-exported from the translation rather than restated,
/// so `Ctx` is the same nominal type either way and nothing here needs a cast.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations, and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the C library is linked and `c` is the
/// translation of the three public headers. True when the build generated a
/// dispatch that resolves the same symbols through the platform loader, in
/// which case `load` is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then use
/// this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use. A
/// failed attempt publishes nothing and can be retried explicitly, by calling
/// this again: there is no automatic retry and no implicit second source.
///
/// It keeps the process handle and its own copy of the request to the end of the
/// process. There is no unload and no reset, because the table is process-global
/// state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports both
/// configurations can tell the two apart at comptime instead of meeting this at
/// run time.
pub fn load(source: LoadSource) LoadError!void {
    // `c.load` exists only in a runtime-loading build. The condition is known at
    // comptime, so the branch this build does not take is never analyzed and
    // never names it; the same gate `loadedSource` below uses, for the same
    // reason.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "zstd: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// A compression level, which is a plain `int` in Zstandard's API.
///
/// Negative levels are the "fast at any cost" family introduced in v1.4.0 and
/// are bounded below by `ZSTD_minCLevel`; positive levels are bounded above by
/// `ZSTD_maxCLevel`. `0` means "the default", which upstream fixes at
/// `ZSTD_CLEVEL_DEFAULT`.
pub const Level = c_int;

/// The default compression level, 3 (`src/lib/zstd.h:133-136`).
///
/// `ZSTD_compress` with a level of 0 gets this, and so does any streaming job
/// whose context has had no level set.
pub const default_level: Level = c.ZSTD_CLEVEL_DEFAULT;

/// The numeric release this SDK's headers describe: 1*100*100 + 5*100 + 7.
///
/// Composed by `src/lib/zstd.h:115` from the three numbers at `:112-114`, and
/// the same value `ZSTD_versionNumber` answers from a provider
/// (`src/lib/zstd.h:118-119`). `runtime/library.zig` requires a provider to
/// report exactly this.
pub const version_number: u32 = c.ZSTD_VERSION_NUMBER;

/// The major component of `version_number`, 1 (`src/lib/zstd.h:112`).
pub const version_major: u32 = c.ZSTD_VERSION_MAJOR;

/// The minor component of `version_number`, 5 (`src/lib/zstd.h:113`).
pub const version_minor: u32 = c.ZSTD_VERSION_MINOR;

/// The release component of `version_number`, 7 (`src/lib/zstd.h:114`).
pub const version_release: u32 = c.ZSTD_VERSION_RELEASE;

/// The release as the three dots upstream's `ZSTD_VERSION_STRING` spells,
/// `"1.5.7"` (`src/lib/zstd.h:122-125`).
///
/// This is a compile-time string, not a call into the library. For what the
/// *provider* says, use `versionString`, which reaches the loaded code.
///
/// It is composed here from the three macros at `src/lib/zstd.h:112-114` rather
/// than read through `c.ZSTD_VERSION_STRING`, because that spelling is built by
/// the preprocessor's `#` operator (`ZSTD_QUOTE` at `:121`) and a token
/// stringifier has no translation: `c.ZSTD_VERSION_STRING` does not resolve.
/// The three numbers it is built from do, and `1` `.` `5` `.` `7` is exactly
/// what `ZSTD_EXPAND_AND_QUOTE(ZSTD_LIB_VERSION)` at `:124` produces from them.
/// A caller that wants the provider's own answer still has `versionString`, and
/// `tests.zig` checks the two against each other.
pub const version_string_literal: [:0]const u8 = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    c.ZSTD_VERSION_MAJOR,
    c.ZSTD_VERSION_MINOR,
    c.ZSTD_VERSION_RELEASE,
});

/// The zstd frame magic number, `0xFD2FB528` (`src/lib/zstd.h:142`).
///
/// RFC 8878 §3.1.1 gives the same four bytes little-endian, which is what the
/// stored form `28 b5 2f fd` is.
pub const magic_number: u32 = c.ZSTD_MAGICNUMBER;

/// The first of the sixteen skippable-frame magic numbers, `0x184D2A50`
/// (`src/lib/zstd.h:144`).
///
/// RFC 8878 §3.1.2 says the skippable magic is `0x184D2A5?` with all sixteen
/// values valid, and `src/lib/zstd.h:145`'s mask is the nibble that hides the
/// variant.
pub const magic_skippable_start: u32 = c.ZSTD_MAGIC_SKIPPABLE_START;

/// The mask that turns any skippable magic into the family start
/// (`src/lib/zstd.h:145`).
pub const magic_skippable_mask: u32 = c.ZSTD_MAGIC_SKIPPABLE_MASK;

/// The smallest input `frameHeaderSize` and `getFrameContentSize` accept for the
/// standard format, 5 (`src/lib/zstd.h:1257`).
///
/// Four bytes of magic plus the one Frame_Header_Descriptor byte.
pub const frame_header_size_prefix: usize = c.ZSTD_FRAMEHEADERSIZE_PREFIX(c.ZSTD_f_zstd1);

/// The smallest complete standard-format frame header, 6
/// (`src/lib/zstd.h:1258`).
pub const frame_header_size_min: usize = c.ZSTD_FRAMEHEADERSIZE_MIN(c.ZSTD_f_zstd1);

/// The largest a standard-format frame header can be, 18 (`src/lib/zstd.h:1259`).
///
/// Enough for every optional field at once; a caller that wants one buffer for
/// any header sizes with this.
pub const frame_header_size_max: usize = c.ZSTD_FRAMEHEADERSIZE_MAX;

/// A skippable frame's fixed header, 8 bytes: four of magic and four of length
/// (`src/lib/zstd.h:1260`).
///
/// RFC 8878 §3.1.2 spells the same two fields and calls them the Skippable
/// Frame Header.
pub const skippable_header_size: usize = c.ZSTD_SKIPPABLEHEADERSIZE;

/// The largest a decompressed *block* can be, 131072 (`src/lib/zstd.h:147-148`,
/// where `ZSTD_BLOCKSIZELOG_MAX` is 17 and `ZSTD_BLOCKSIZE_MAX` is its `1<<`).
///
/// This is also the magnitude of `ZSTD_minCLevel`, because
/// `src/lib/zstd.h:1277` makes `ZSTD_TARGETLENGTH_MAX` equal to it.
pub const block_size_max: usize = c.ZSTD_BLOCKSIZE_MAX;

/// The value `ZSTD_getFrameContentSize` reports for a frame that carries no
/// content size (`src/lib/zstd.h:203`).
///
/// Upstream spells this `(0ULL - 1)` at `:203` and `(0ULL - 2)` at `:204`. Those
/// two expressions do not survive translation: `c.ZSTD_CONTENTSIZE_UNKNOWN`
/// renders as a `c_ulonglong` subtraction from zero, which is an overflow at
/// compile time, so neither one resolves. The two values are named here from the
/// same arithmetic on the same width, which is what the two macros are.
pub const content_size_unknown: u64 = std.math.maxInt(u64);

/// The value `ZSTD_getFrameContentSize` reports when the header could not be
/// decoded at all (`src/lib/zstd.h:204`).
pub const content_size_error: u64 = std.math.maxInt(u64) - 1;

/// What a compression parameter selects.
///
/// Every enumerator is upstream's own value, read through `c` rather than
/// restated, so a parameter that moved upstream cannot silently disagree here.
/// `src/lib/zstd.h:517-524` is upstream's own warning about this enum, and it is
/// worth repeating: the values are unstable and the `experimentalParamN` names
/// must never be used directly. The tags here are the named ones only, so a
/// caller has to name a parameter whose meaning upstream has committed to.
///
/// Setting most of these requires a context in its initial state;
/// `ZSTD_CCtx_setParameter` returns `stage_wrong` otherwise
/// (`src/lib/compress/zstd_compress.c:604-609`).
pub const CParameter = enum(c_int) {
    /// Pre-defined level table. Bounds are `ZSTD_minCLevel` to `ZSTD_maxCLevel`
    /// (`src/lib/compress/zstd_compress.c:425-428`), and an out-of-range value
    /// is *clamped* rather than refused (`:782`, through `ZSTD_cParam_clampBounds`
    /// at `:642-649`).
    compression_level = c.ZSTD_c_compressionLevel,
    /// Base two logarithm of the window. Bounds are `ZSTD_WINDOWLOG_MIN` to
    /// `ZSTD_WINDOWLOG_MAX` (`src/lib/compress/zstd_compress.c:430-433`).
    window_log = c.ZSTD_c_windowLog,
    /// Hash table logarithm (`src/lib/compress/zstd_compress.c:435-438`).
    hash_log = c.ZSTD_c_hashLog,
    /// Binary tree logarithm (`src/lib/compress/zstd_compress.c:440-443`).
    chain_log = c.ZSTD_c_chainLog,
    /// Match search logarithm (`src/lib/compress/zstd_compress.c:445-448`).
    search_log = c.ZSTD_c_searchLog,
    /// Minimum match length (`src/lib/compress/zstd_compress.c:450-453`).
    min_match = c.ZSTD_c_minMatch,
    /// Match length search cutoff (`src/lib/compress/zstd_compress.c:455-458`).
    target_length = c.ZSTD_c_targetLength,
    /// Compression strategy (`src/lib/compress/zstd_compress.c:460-463`).
    strategy = c.ZSTD_c_strategy,
    /// Target compressed block size for super-blocks
    /// (`src/lib/compress/zstd_compress.c:465-468`).
    target_cblock_size = c.ZSTD_c_targetCBlockSize,
    /// Long-distance matching switch (`src/lib/compress/zstd_compress.c:470-473`).
    enable_long_distance_matching = c.ZSTD_c_enableLongDistanceMatching,
    /// Long-distance matching hash logarithm.
    ldm_hash_log = c.ZSTD_c_ldmHashLog,
    /// Long-distance matching minimum match length.
    ldm_min_match = c.ZSTD_c_ldmMinMatch,
    /// Long-distance matching bucket size logarithm.
    ldm_bucket_size_log = c.ZSTD_c_ldmBucketSizeLog,
    /// Long-distance matching hash rate logarithm.
    ldm_hash_rate_log = c.ZSTD_c_ldmHashRateLog,
    /// Whether the frame header carries the content size
    /// (`src/lib/compress/zstd_compress.c:475-478`).
    content_size_flag = c.ZSTD_c_contentSizeFlag,
    /// Whether the frame carries a trailing content checksum
    /// (`src/lib/compress/zstd_compress.c:480-483`).
    checksum_flag = c.ZSTD_c_checksumFlag,
    /// Whether the frame header carries a dictionary ID
    /// (`src/lib/compress/zstd_compress.c:485-488`).
    dict_id_flag = c.ZSTD_c_dictIDFlag,
    /// Worker threads (`src/lib/compress/zstd_compress.c:490-493`).
    ///
    /// A value other than 0 is refused with `parameter_unsupported` unless the
    /// context was heap-allocated (`src/lib/compress/zstd_compress.c:754-757`),
    /// and this build does not compile the library with `ZSTD_MULTITHREAD`, so
    /// the worker machinery is not present at all. A dependent that wants
    /// threads asks for a multi-threaded `libzstd` and gets one from its own
    /// build; `FORK-NOTES.md` records that.
    nb_workers = c.ZSTD_c_nbWorkers,
    /// Streaming job size (`src/lib/compress/zstd_compress.c:495-498`).
    job_size = c.ZSTD_c_jobSize,
    /// Streaming overlap logarithm (`src/lib/compress/zstd_compress.c:500-503`).
    overlap_log = c.ZSTD_c_overlapLog,

    /// The upstream number, for a parameter this facade does not name.
    pub fn fromCode(code: c_int) ?CParameter {
        return switch (code) {
            c.ZSTD_c_compressionLevel => .compression_level,
            c.ZSTD_c_windowLog => .window_log,
            c.ZSTD_c_hashLog => .hash_log,
            c.ZSTD_c_chainLog => .chain_log,
            c.ZSTD_c_searchLog => .search_log,
            c.ZSTD_c_minMatch => .min_match,
            c.ZSTD_c_targetLength => .target_length,
            c.ZSTD_c_strategy => .strategy,
            c.ZSTD_c_targetCBlockSize => .target_cblock_size,
            c.ZSTD_c_enableLongDistanceMatching => .enable_long_distance_matching,
            c.ZSTD_c_ldmHashLog => .ldm_hash_log,
            c.ZSTD_c_ldmMinMatch => .ldm_min_match,
            c.ZSTD_c_ldmBucketSizeLog => .ldm_bucket_size_log,
            c.ZSTD_c_ldmHashRateLog => .ldm_hash_rate_log,
            c.ZSTD_c_contentSizeFlag => .content_size_flag,
            c.ZSTD_c_checksumFlag => .checksum_flag,
            c.ZSTD_c_dictIDFlag => .dict_id_flag,
            c.ZSTD_c_nbWorkers => .nb_workers,
            c.ZSTD_c_jobSize => .job_size,
            c.ZSTD_c_overlapLog => .overlap_log,
            else => null,
        };
    }
};

/// What a decompression parameter selects.
///
/// Only one named parameter survives in 1.5.7's stable surface
/// (`src/lib/zstd.h:640-668`); the rest of the enum is the experimental
/// `ZSTD_d_experimentalParamN` family, which `src/lib/zstd.h:654-657` says must
/// never be used by name.
pub const DParameter = enum(c_int) {
    /// Size limit, as a power of two, beyond which the streaming API refuses to
    /// allocate a buffer. 0 means "use the default maximum"
    /// (`src/lib/zstd.h:642-648`).
    window_log_max = c.ZSTD_d_windowLogMax,

    /// The upstream number, for a parameter this facade does not name.
    pub fn fromCode(code: c_int) ?DParameter {
        return switch (code) {
            c.ZSTD_d_windowLogMax => .window_log_max,
            else => null,
        };
    }
};

/// What a streaming compression step should do with the frame.
///
/// Upstream's `ZSTD_EndDirective` (`src/lib/zstd.h:783-794`), and the three
/// values are the whole of it.
pub const EndOp = enum(c_int) {
    /// Collect more data; the encoder decides when to emit a block.
    @"continue" = c.ZSTD_e_continue,
    /// Emit at least one decodable block now and keep the frame open.
    flush = c.ZSTD_e_flush,
    /// Flush and close the frame. The frame is only closed once the compressed
    /// data is fully flushed, so the caller keeps calling until the step
    /// returns 0.
    @"end" = c.ZSTD_e_end,
};

/// What a context reset should clear.
///
/// Upstream's `ZSTD_ResetDirective` (`src/lib/zstd.h:589-593`).
pub const Reset = enum(c_int) {
    /// Stop the current frame; parameters and dictionary stay.
    session_only = c.ZSTD_reset_session_only,
    /// Parameters and dictionary go back to their defaults; the session stays.
    parameters = c.ZSTD_reset_parameters,
    /// Both.
    session_and_parameters = c.ZSTD_reset_session_and_parameters,
};

/// One compression buffer, as the C API spells it.
///
/// `src` and `size` describe what the caller has; `pos` is the caller's own
/// cursor into that region and is what the C code reads. It is an ordinary
/// struct rather than an opaque handle because the C side reads through a
/// pointer the caller supplies (`src/lib/zstd.h:701-705`).
pub const InBuffer = c.ZSTD_inBuffer;

/// One decompression buffer, as the C API spells it (`src/lib/zstd.h:707-711`).
///
/// `pos` is written by the C code, and it is what says how much of this buffer
/// the decoder consumed or filled.
pub const OutBuffer = c.ZSTD_outBuffer;

/// Zstandard's own error codes, with the value each one carries.
///
/// This is the whole of `src/lib/zstd_errors.h:60-98`. Upstream's own rules
/// about it are at `:49-58`: the values have been pinned since v1.3.1, only
/// values below 100 are stable, and `ZSTD_isError` is correct whatever the
/// library version. The `unstable_*` tags are the codes at and above 100, which
/// `:90` marks as not stable; they are named rather than hidden so a caller who
/// receives one can see that it came from that group.
pub const ErrorCode = enum(c_int) {
    /// `ZSTD_error_no_error` (`src/lib/zstd_errors.h:61`). Not an error; this is
    /// what `ZSTD_getErrorCode` answers for a successful result.
    no_error = c.ZSTD_error_no_error,
    /// `ZSTD_error_GENERIC` (`:62`).
    generic = c.ZSTD_error_GENERIC,
    /// `ZSTD_error_prefix_unknown` (`:63`): the first bytes are neither a zstd
    /// magic number nor a skippable one.
    prefix_unknown = c.ZSTD_error_prefix_unknown,
    /// `ZSTD_error_version_unsupported` (`:64`).
    version_unsupported = c.ZSTD_error_version_unsupported,
    /// `ZSTD_error_frameParameter_unsupported` (`:65`).
    frame_parameter_unsupported = c.ZSTD_error_frameParameter_unsupported,
    /// `ZSTD_error_frameParameter_windowTooLarge` (`:66`).
    window_too_large = c.ZSTD_error_frameParameter_windowTooLarge,
    /// `ZSTD_error_corruption_detected` (`:67`).
    corruption_detected = c.ZSTD_error_corruption_detected,
    /// `ZSTD_error_checksum_wrong` (`:68`).
    checksum_wrong = c.ZSTD_error_checksum_wrong,
    /// `ZSTD_error_literals_headerWrong` (`:69`).
    literals_header_wrong = c.ZSTD_error_literals_headerWrong,
    /// `ZSTD_error_dictionary_corrupted` (`:70`).
    dictionary_corrupted = c.ZSTD_error_dictionary_corrupted,
    /// `ZSTD_error_dictionary_wrong` (`:71`).
    dictionary_wrong = c.ZSTD_error_dictionary_wrong,
    /// `ZSTD_error_dictionaryCreation_failed` (`:72`).
    dictionary_creation_failed = c.ZSTD_error_dictionaryCreation_failed,
    /// `ZSTD_error_parameter_unsupported` (`:73`).
    parameter_unsupported = c.ZSTD_error_parameter_unsupported,
    /// `ZSTD_error_parameter_combination_unsupported` (`:74`).
    parameter_combination_unsupported = c.ZSTD_error_parameter_combination_unsupported,
    /// `ZSTD_error_parameter_outOfBound` (`:75`).
    parameter_out_of_bound = c.ZSTD_error_parameter_outOfBound,
    /// `ZSTD_error_tableLog_tooLarge` (`:76`).
    table_log_too_large = c.ZSTD_error_tableLog_tooLarge,
    /// `ZSTD_error_maxSymbolValue_tooLarge` (`:77`).
    max_symbol_value_too_large = c.ZSTD_error_maxSymbolValue_tooLarge,
    /// `ZSTD_error_maxSymbolValue_tooSmall` (`:78`).
    max_symbol_value_too_small = c.ZSTD_error_maxSymbolValue_tooSmall,
    /// `ZSTD_error_cannotProduce_uncompressedBlock` (`:79`).
    cannot_produce_uncompressed_block = c.ZSTD_error_cannotProduce_uncompressedBlock,
    /// `ZSTD_error_stabilityCondition_notRespected` (`:80`).
    stability_condition_not_respected = c.ZSTD_error_stabilityCondition_notRespected,
    /// `ZSTD_error_stage_wrong` (`:81`): the call does not belong at this point
    /// in the context's life.
    stage_wrong = c.ZSTD_error_stage_wrong,
    /// `ZSTD_error_init_missing` (`:82`).
    init_missing = c.ZSTD_error_init_missing,
    /// `ZSTD_error_memory_allocation` (`:83`).
    memory_allocation = c.ZSTD_error_memory_allocation,
    /// `ZSTD_error_workSpace_tooSmall` (`:84`).
    work_space_too_small = c.ZSTD_error_workSpace_tooSmall,
    /// `ZSTD_error_dstSize_tooSmall` (`:85`).
    dst_size_too_small = c.ZSTD_error_dstSize_tooSmall,
    /// `ZSTD_error_srcSize_wrong` (`:86`).
    src_size_wrong = c.ZSTD_error_srcSize_wrong,
    /// `ZSTD_error_dstBuffer_null` (`:87`).
    dst_buffer_null = c.ZSTD_error_dstBuffer_null,
    /// `ZSTD_error_noForwardProgress_destFull` (`:88`).
    no_forward_progress_dest_full = c.ZSTD_error_noForwardProgress_destFull,
    /// `ZSTD_error_noForwardProgress_inputEmpty` (`:89`).
    no_forward_progress_input_empty = c.ZSTD_error_noForwardProgress_inputEmpty,
    /// `ZSTD_error_frameIndex_tooLarge` (`:91`). **Unstable**, per `:90`.
    unstable_frame_index_too_large = c.ZSTD_error_frameIndex_tooLarge,
    /// `ZSTD_error_seekableIO` (`:92`). **Unstable**, per `:90`.
    unstable_seekable_io = c.ZSTD_error_seekableIO,
    /// `ZSTD_error_dstBuffer_wrong` (`:93`). **Unstable**, per `:90`.
    unstable_dst_buffer_wrong = c.ZSTD_error_dstBuffer_wrong,
    /// `ZSTD_error_srcBuffer_wrong` (`:94`). **Unstable**, per `:90`.
    unstable_src_buffer_wrong = c.ZSTD_error_srcBuffer_wrong,
    /// `ZSTD_error_sequenceProducer_failed` (`:95`). **Unstable**, per `:90`.
    unstable_sequence_producer_failed = c.ZSTD_error_sequenceProducer_failed,
    /// `ZSTD_error_externalSequences_invalid` (`:96`). **Unstable**, per `:90`.
    unstable_external_sequences_invalid = c.ZSTD_error_externalSequences_invalid,

    /// A code `ZSTD_getErrorCode` returned that is outside this enum.
    ///
    /// Upstream reserves `ZSTD_error_maxCode` (`:97`) and says it can change, so
    /// a number between the named codes and 120 is possible from a future
    /// library. That is reported rather than guessed at.
    unrecognised,

    /// The code behind an `ErrorCode`, or null when it is not one of these.
    pub fn fromCode(code: c_int) ?ErrorCode {
        return switch (code) {
            c.ZSTD_error_no_error => .no_error,
            c.ZSTD_error_GENERIC => .generic,
            c.ZSTD_error_prefix_unknown => .prefix_unknown,
            c.ZSTD_error_version_unsupported => .version_unsupported,
            c.ZSTD_error_frameParameter_unsupported => .frame_parameter_unsupported,
            c.ZSTD_error_frameParameter_windowTooLarge => .window_too_large,
            c.ZSTD_error_corruption_detected => .corruption_detected,
            c.ZSTD_error_checksum_wrong => .checksum_wrong,
            c.ZSTD_error_literals_headerWrong => .literals_header_wrong,
            c.ZSTD_error_dictionary_corrupted => .dictionary_corrupted,
            c.ZSTD_error_dictionary_wrong => .dictionary_wrong,
            c.ZSTD_error_dictionaryCreation_failed => .dictionary_creation_failed,
            c.ZSTD_error_parameter_unsupported => .parameter_unsupported,
            c.ZSTD_error_parameter_combination_unsupported => .parameter_combination_unsupported,
            c.ZSTD_error_parameter_outOfBound => .parameter_out_of_bound,
            c.ZSTD_error_tableLog_tooLarge => .table_log_too_large,
            c.ZSTD_error_maxSymbolValue_tooLarge => .max_symbol_value_too_large,
            c.ZSTD_error_maxSymbolValue_tooSmall => .max_symbol_value_too_small,
            c.ZSTD_error_cannotProduce_uncompressedBlock => .cannot_produce_uncompressed_block,
            c.ZSTD_error_stabilityCondition_notRespected => .stability_condition_not_respected,
            c.ZSTD_error_stage_wrong => .stage_wrong,
            c.ZSTD_error_init_missing => .init_missing,
            c.ZSTD_error_memory_allocation => .memory_allocation,
            c.ZSTD_error_workSpace_tooSmall => .work_space_too_small,
            c.ZSTD_error_dstSize_tooSmall => .dst_size_too_small,
            c.ZSTD_error_srcSize_wrong => .src_size_wrong,
            c.ZSTD_error_dstBuffer_null => .dst_buffer_null,
            c.ZSTD_error_noForwardProgress_destFull => .no_forward_progress_dest_full,
            c.ZSTD_error_noForwardProgress_inputEmpty => .no_forward_progress_input_empty,
            c.ZSTD_error_frameIndex_tooLarge => .unstable_frame_index_too_large,
            c.ZSTD_error_seekableIO => .unstable_seekable_io,
            c.ZSTD_error_dstBuffer_wrong => .unstable_dst_buffer_wrong,
            c.ZSTD_error_srcBuffer_wrong => .unstable_src_buffer_wrong,
            c.ZSTD_error_sequenceProducer_failed => .unstable_sequence_producer_failed,
            c.ZSTD_error_externalSequences_invalid => .unstable_external_sequences_invalid,
            else => null,
        };
    }

    /// Whether this is one of the codes `src/lib/zstd_errors.h:90` marks as not
    /// stable.
    pub fn isUnstable(self: ErrorCode) bool {
        return switch (self) {
            .unstable_frame_index_too_large,
            .unstable_seekable_io,
            .unstable_dst_buffer_wrong,
            .unstable_src_buffer_wrong,
            .unstable_sequence_producer_failed,
            .unstable_external_sequences_invalid,
            .unrecognised,
            => true,
            else => false,
        };
    }
};

/// Every way a typed call in this module can fail.
///
/// One tag per Zstandard error code, cut to what this build's own 34 compiled
/// units can actually produce. The cut is derived by reading the sources rather
/// than by guessing, and the two ends of it are worth naming:
///
///   * **`ZSTD_error_version_unsupported` has no Zig tag.** A search of every
///     file this package compiles - the eight units of `common/`, the fourteen of
///     `compress/`, the four `decompress/*.c` plus `huf_decompress_amd64.S`, the
///     four of `dictBuilder/` and `legacy/zstd_v05.c`, `zstd_v06.c`,
///     `zstd_v07.c` - finds the name in exactly one place,
///     `src/lib/common/error_private.c:27`, which is the string table and not a
///     producer. No compiled unit raises it, so a typed call in this module
///     cannot return it. It is still reachable as `ErrorCode.version_unsupported`
///     through `errorCode`, because the enum is the taxonomy rather than a
///     promise about what this build raises.
///   * **The codes at or above 100 collapse into `UnstableCode`.** All six are
///     seekable-format, external-sequence and sequence-producer diagnostics.
///     None of the entry points this module wraps produces one - the seekable
///     format is not in the compiled closure, and the sequence producers are
///     advanced-API-only - so six tags that can never be returned would be six
///     claims this module could not keep. `ErrorCode` names them individually for
///     a caller who reaches past the facade, and `errorCodeText` still produces
///     upstream's own text for each.
///
/// Every other tag below has at least one producer in the compiled closure. The
/// dictionary-builder tags come from `dictBuilder/`, the parameter tags from
/// `compress/zstd_compress.c`'s `BOUNDCHECK` and the `default:` arm of
/// `ZSTD_CCtx_setParameter` (`:758`), and the decoding tags from
/// `decompress/`. `UnrecognisedCode` is the arm for a code outside the enum,
/// which upstream's own reservation at `src/lib/zstd_errors.h:97` makes
/// possible.
///
/// Which function reaches which tag is named on each wrapper. It is not a
/// promise that a given call *will* reach one, and it is not a promise that a
/// call cannot: upstream's own taxonomy is the shared vocabulary, and this set
/// is every code this build can produce rather than a per-call list, so that a
/// caller reading a `switch` does not have to know which code came from where.
pub const Error = error{
    /// A generic failure: `ZSTD_error_GENERIC`, `src/lib/zstd_errors.h:62`.
    Generic,
    /// The input is not a zstd or skippable frame: `ZSTD_error_prefix_unknown`,
    /// `src/lib/zstd_errors.h:63`.
    ///
    /// Raised by `src/lib/decompress/zstd_decompress.c:473` and `:493`, and by
    /// `ZSTD_decompressMultiFrame` for trailing garbage after a good frame
    /// (`:1146-1156`).
    NotAZstdFrame,
    /// The frame header is structurally unacceptable:
    /// `ZSTD_error_frameParameter_unsupported`, `src/lib/zstd_errors.h:65`.
    ///
    /// `src/lib/decompress/zstd_decompress.c:511-512` raises it for a reserved
    /// bit set, which is the case a corrupt frame most often hits.
    FrameParameterUnsupported,
    /// The frame asks for a window larger than this build allows:
    /// `ZSTD_error_frameParameter_windowTooLarge`, `src/lib/zstd_errors.h:66`.
    ///
    /// `src/lib/decompress/zstd_decompress.c:517`.
    WindowTooLarge,
    /// The frame content is not decodable: `ZSTD_error_corruption_detected`,
    /// `src/lib/zstd_errors.h:67`.
    Corruption,
    /// The trailing content checksum did not match:
    /// `ZSTD_error_checksum_wrong`, `src/lib/zstd_errors.h:68`.
    ChecksumMismatch,
    /// The literals section header breaks its own format rules:
    /// `ZSTD_error_literals_headerWrong`, `src/lib/zstd_errors.h:69`.
    ///
    /// `src/lib/decompress/zstd_decompress_block.c:188`.
    LiteralsHeaderWrong,
    /// The dictionary is not a dictionary: `ZSTD_error_dictionary_corrupted`,
    /// `src/lib/zstd_errors.h:70`.
    DictionaryCorrupted,
    /// The dictionary does not match the frame's dictionary ID:
    /// `ZSTD_error_dictionary_wrong`, `src/lib/zstd_errors.h:71`.
    DictionaryRejected,
    /// Dictionary training failed: `ZSTD_error_dictionaryCreation_failed`,
    /// `src/lib/zstd_errors.h:72`.
    DictionaryTrainingFailed,
    /// The parameter is not one this context accepts:
    /// `ZSTD_error_parameter_unsupported`, `src/lib/zstd_errors.h:73`.
    ///
    /// `src/lib/compress/zstd_compress.c:758` raises it for an unknown
    /// parameter id, and `:755` for a non-zero `ZSTD_c_nbWorkers` on a
    /// statically allocated context.
    ParameterUnsupported,
    /// Two parameters that are each legal cannot both hold:
    /// `ZSTD_error_parameter_combination_unsupported`,
    /// `src/lib/zstd_errors.h:74`.
    ParameterCombinationUnsupported,
    /// The value is outside the parameter's bounds:
    /// `ZSTD_error_parameter_outOfBound`, `src/lib/zstd_errors.h:75`.
    ///
    /// `src/lib/compress/zstd_compress.c:653-655` raises it through `BOUNDCHECK`,
    /// which every parameter except `ZSTD_c_compressionLevel` uses.
    ///
    /// **Not** what an out-of-range *level* does: `ZSTD_c_compressionLevel` is
    /// clamped (`src/lib/compress/zstd_compress.c:782`), so setting it beyond
    /// `ZSTD_maxCLevel` succeeds and the context holds the maximum. That
    /// asymmetry is upstream's and is the reason `setLevel` says it.
    ParameterOutOfBound,
    /// A table logarithm exceeds what this build supports:
    /// `ZSTD_error_tableLog_tooLarge`, `src/lib/zstd_errors.h:76`.
    TableLogTooLarge,
    /// An FSE or Huffman alphabet is larger than the bitstream allows:
    /// `ZSTD_error_maxSymbolValue_tooLarge`, `src/lib/zstd_errors.h:77`.
    MaxSymbolValueTooLarge,
    /// An FSE or Huffman alphabet is smaller than the bitstream requires:
    /// `ZSTD_error_maxSymbolValue_tooSmall`, `src/lib/zstd_errors.h:78`.
    MaxSymbolValueTooSmall,
    /// The mode asked for cannot emit a raw block:
    /// `ZSTD_error_cannotProduce_uncompressedBlock`,
    /// `src/lib/zstd_errors.h:79`.
    ///
    /// `src/lib/compress/zstd_compress.c:7550`.
    CannotProduceUncompressedBlock,
    /// A pledged stable buffer was not stable:
    /// `ZSTD_error_stabilityCondition_notRespected`, `src/lib/zstd_errors.h:80`.
    ///
    /// `src/lib/compress/zstd_compress.c:6333,6339,6468`.
    StabilityConditionNotRespected,
    /// The call does not belong at this point in the context's life:
    /// `ZSTD_error_stage_wrong`, `src/lib/zstd_errors.h:81`.
    ///
    /// `src/lib/compress/zstd_compress.c:605-609` raises it for a parameter set
    /// after compression started on a parameter that is not authorized to
    /// change mid-frame.
    WrongStage,
    /// A context was used before it was initialised:
    /// `ZSTD_error_init_missing`, `src/lib/zstd_errors.h:82`.
    ///
    /// `src/lib/compress/zstd_compress.c:6143`.
    InitMissing,
    /// Memory for the operation could not be obtained:
    /// `ZSTD_error_memory_allocation`, `src/lib/zstd_errors.h:83`.
    ///
    /// This is libc's allocator failing, reached through
    /// `src/lib/common/zstd_deps.h:64-68`. It is not something this module can
    /// bound or retry.
    OutOfMemory,
    /// The provided workspace is too small:
    /// `ZSTD_error_workSpace_tooSmall`, `src/lib/zstd_errors.h:84`.
    ///
    /// `src/lib/compress/hist.c:157,169` and `src/lib/compress/huf_compress.c:771`.
    WorkSpaceTooSmall,
    /// The destination cannot hold the result:
    /// `ZSTD_error_dstSize_tooSmall`, `src/lib/zstd_errors.h:85`.
    DstSizeTooSmall,
    /// The source is shorter than the frame claims, or longer than one frame
    /// needs: `ZSTD_error_srcSize_wrong`, `src/lib/zstd_errors.h:86`.
    SrcSizeWrong,
    /// A null destination was given where content was required:
    /// `ZSTD_error_dstBuffer_null`, `src/lib/zstd_errors.h:87`.
    ///
    /// `src/lib/decompress/zstd_decompress.c:903,916`.
    DstBufferNull,
    /// Several calls made no progress because the output was full:
    /// `ZSTD_error_noForwardProgress_destFull`, `src/lib/zstd_errors.h:88`.
    ///
    /// `src/lib/decompress/zstd_decompress.c:2359`.
    NoForwardProgressDstFull,
    /// Several calls made no progress because the input was empty:
    /// `ZSTD_error_noForwardProgress_inputEmpty`, `src/lib/zstd_errors.h:89`.
    ///
    /// `src/lib/decompress/zstd_decompress.c:2360`.
    NoForwardProgressInputEmpty,
    /// An error code at or above 100, or outside the enum entirely. See the note
    /// on the set for why those six collapse into one tag.
    UnstableCode,
};

/// The lowest compression level this build accepts, a large negative number.
///
/// `ZSTD_minCLevel` (`src/lib/zstd.h:262`) answers `-ZSTD_TARGETLENGTH_MAX`
/// (`src/lib/compress/zstd_compress.c:7674`), and `src/lib/zstd.h:1277` makes
/// `ZSTD_TARGETLENGTH_MAX` equal to `ZSTD_BLOCKSIZE_MAX`, so the bound is
/// `-131072`. A caller passing a level below this gets it clamped, not an error;
/// see `setLevel`.
pub fn minLevel() Level {
    return c.ZSTD_minCLevel();
}

/// The highest compression level this build offers, 22.
///
/// `ZSTD_maxCLevel` (`src/lib/zstd.h:263`) answers `ZSTD_MAX_CLEVEL`, which
/// `src/lib/compress/clevels.h:19` defines as 22.
pub fn maxLevel() Level {
    return c.ZSTD_maxCLevel();
}

/// The release the *loaded* library reports, as `MAJOR*10000 + MINOR*100 +
/// RELEASE`.
///
/// `ZSTD_versionNumber` (`src/lib/zstd.h:119`) takes no argument and reads a
/// constant from the loaded object, so this is a fact about the provider rather
/// than a constant compiled into this program. In a runtime-loading build it is
/// the only way to learn which object answered.
pub fn versionNumber() u32 {
    return c.ZSTD_versionNumber();
}

/// The release the *loaded* library reports, as `"1.5.7"`.
///
/// `ZSTD_versionString` (`src/lib/zstd.h:128`). The value is a NUL-terminated
/// string in the provider's own storage, so the slice borrows from it and stays
/// valid for the life of the process.
pub fn versionString() [:0]const u8 {
    return std.mem.span(c.ZSTD_versionString());
}

/// Whether a `size_t` result is an error code rather than a length.
///
/// `ZSTD_isError` (`src/lib/zstd.h:259`), reached through the raw route. Upstream
/// documents it as always correct whatever the library version
/// (`src/lib/zstd_errors.h:58`), which is why this is a direct call and not a
/// comparison against a reserved range.
pub fn isError(result: usize) bool {
    return c.ZSTD_isError(result) != 0;
}

/// The message for a `size_t` result, whether it is a length or an error.
///
/// `ZSTD_getErrorName` (`src/lib/zstd.h:261`). For a successful result it
/// returns a generic success string, which is why `errorName` documents that
/// difference rather than presenting the answer as an error message.
pub fn errorName(result: usize) [:0]const u8 {
    return std.mem.span(c.ZSTD_getErrorName(result));
}

/// The error code behind a `size_t` result.
///
/// `ZSTD_getErrorCode` (`src/lib/zstd.h:260`), which upstream calls "the only
/// supported way to use the error list"
/// (`src/lib/zstd_errors.h:56-57`). A code outside the enum becomes
/// `.unrecognised` rather than a guess.
pub fn errorCode(result: usize) ErrorCode {
    return ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised;
}

/// Upstream's own text for an error code.
///
/// `ZSTD_getErrorString` (`src/lib/zstd_errors.h:100`), described there as the
/// same as `ZSTD_getErrorName` but taking the enum rather than a raw result. The
/// text is compiled into the provider, so this is the loaded library's wording and
/// not a string written here.
pub fn errorCodeText(code: ErrorCode) [:0]const u8 {
    // `unrecognised` has no numeric value, so it cannot be handed to the C
    // function, and inventing one would put an unrelated word in the caller's
    // log. It gets its own sentence here instead.
    switch (code) {
        .unrecognised => return "an error code outside Zstandard's own taxonomy",
        else => {},
    }
    return std.mem.span(c.ZSTD_getErrorString(@intCast(@intFromEnum(code))));
}

/// The largest a frame compressing `src_len` bytes can be.
///
/// `ZSTD_compressBound` (`src/lib/zstd.h:250`) wraps the `ZSTD_COMPRESSBOUND`
/// macro at `:249`, which upstream says "ensures that bound(A) + bound(B) <=
/// bound(A+B) as long as A and B >= 128 KB". That is what makes one bound a safe
/// size for a whole batch of frames concatenated.
///
/// It returns `error.SrcSizeWrong` for a length at or above
/// `ZSTD_MAX_INPUT_SIZE` (`src/lib/zstd.h:248`), because the macro yields 0 there
/// and `src/lib/compress/zstd_compress.c` turns that into an error.
pub fn compressBound(src_len: usize) Error!usize {
    return checked(c.ZSTD_compressBound(src_len));
}

/// `compressBound`, for a caller sizing an array at comptime.
///
/// `ZSTD_COMPRESSBOUND` is a macro (`src/lib/zstd.h:249`), so the answer is
/// available without a call. This returns 0 where upstream's macro yields 0 -
/// a `src_len` at or above `ZSTD_MAX_INPUT_SIZE` - which is the same answer the
/// function gives as an error, spelled as a number a caller can read at comptime.
///
/// The macro is instantiated at `u64`, not at `usize`, and the width the caller
/// passes in is unchanged. `translate-c` emits the macro as
/// `(@as(c_int, 128) << @as(c_int, 10)) - srcSize`, and Zig will not reconcile
/// `c_int` against a 32-bit unsigned argument in that position: instantiating
/// at `usize` on a 32-bit target did not compile, and every 32-bit cell of the
/// 53-platform matrix failed on it. The emitted text is the same for every
/// target, so the argument's width is the only variable. `FORK-NOTES.md` §2.7
/// carries the run and the diagnosis.
///
/// The number does not move. On a 32-bit target `ZSTD_MAX_INPUT_SIZE`
/// (`src/lib/zstd.h:248`) is `0xFF00FF00U`, which reads as the same threshold
/// in `u64`, and every `src_len` a 32-bit caller holds is below `2^32`, so the
/// macro computes the value it computes in C. The caller still gets a `usize`,
/// so a `src_len` that large is unreachable at 32 bits and needs no check.
pub fn compressBoundConst(src_len: usize) usize {
    return @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(u64, src_len))));
}

/// An upper bound on what `src` decompresses to.
///
/// `ZSTD_decompressBound` (`src/lib/zstd.h:1502`, `ZSTDLIB_STATIC_API`). It
/// walks every frame in `src` and adds up each frame's declared size, or - for a
/// frame with no declared size - `nbBlocks * blockSizeMax`
/// (`src/lib/decompress/zstd_decompress.c:794-796`), which is why the answer is a
/// bound and not a size.
///
/// One thing this wrapper does not hide: the comment at
/// `src/lib/decompress/zstd_decompress.c:815` says "compatible with legacy mode"
/// but the body at `:825` walks the input with `ZSTD_findFrameSizeInfo(...,
/// ZSTD_f_zstd1)`, which has no legacy arm - unlike `ZSTD_getFrameContentSize` at
/// `:571-576`, which does. A v0.5-v0.7 frame therefore answers
/// `error.NotAZstdFrame` here while `ZSTD_decompress` still decodes it. That is a
/// statement about the pinned source read here, and `FORK-NOTES.md` records it.
pub fn decompressBound(src: []const u8) Error!u64 {
    const result = c.ZSTD_decompressBound(src.ptr, src.len);
    if (result == content_size_error) return error.NotAZstdFrame;
    return result;
}

/// What the frame header says about the content size.
///
/// Three answers, because upstream's `unsigned long long` has only two:
/// `ZSTD_getFrameContentSize` (`src/lib/zstd.h:205`) returns the size,
/// `ZSTD_CONTENTSIZE_UNKNOWN` (`:203`) when the frame carries none, or
/// `ZSTD_CONTENTSIZE_ERROR` (`:204`) when the header could not be decoded.
///
/// It also returns `0` for a *skippable* frame
/// (`src/lib/decompress/zstd_decompress.c:580-581`), and `0` is also the size of
/// an empty zstd frame. `ContentSize` reports that as `.known{0}`, because that
/// is what the function said; a caller that needs to tell a skippable frame from
/// an empty one reads the magic number itself, and `isSkippableFrame` does that.
///
/// It looks at the *first* frame in `src` and ignores the rest.
pub fn frameContentSize(src: []const u8) ContentSize {
    return ContentSize.of(c.ZSTD_getFrameContentSize(src.ptr, src.len));
}

/// The dictionary ID in the first frame of `src`, or 0.
///
/// `ZSTD_getDictID_fromFrame` (`src/lib/zstd.h:1071`). Zero is upstream's own
/// answer both for a frame that carries no dictionary ID and for one whose ID is
/// zero, so it is a "no usable ID" answer rather than a distinction this wrapper
/// invents.
pub fn dictIDFromFrame(src: []const u8) u32 {
    return c.ZSTD_getDictID_fromFrame(src.ptr, src.len);
}

/// How many bytes the first frame in `src` occupies, headers and checksum
/// included.
///
/// `ZSTD_findFrameCompressedSize` (`src/lib/zstd.h:227`). For a skippable frame
/// the answer is the whole skippable frame, header plus payload
/// (`src/lib/decompress/zstd_decompress.c:744-749` reads the length out of the
/// header), and a zstd frame's answer includes its trailing checksum
/// (`:786-793` advances past it before measuring).
///
/// This is the call that answers "where does the next frame start", which is
/// what `frameHeaderSize` cannot answer for a skippable frame - see that
/// function's note.
pub fn findFrameCompressedSize(src: []const u8) Error!usize {
    return checked(c.ZSTD_findFrameCompressedSize(src.ptr, src.len));
}

/// The size of the first frame's header, without decoding the rest.
///
/// `ZSTD_frameHeaderSize` (`src/lib/zstd.h:1508`, `ZSTDLIB_STATIC_API`), computed
/// by `src/lib/decompress/zstd_decompress.c:416-429` from the descriptor byte
/// alone.
///
/// **It does not answer for a skippable frame.** Its own comment says it "only
/// works for formats ZSTD_f_zstd1 and ZSTD_f_zstd1_magicless"
/// (`src/lib/decompress/zstd_decompress.c:413`), and the implementation reads
/// `src[4]` as a Frame_Header_Descriptor whether or not `src` begins with a
/// skippable magic. On a skippable frame it returns seven where
/// `skippable_header_size` is eight. Use `findFrameCompressedSize` for that.
///
/// `src` must be at least `frame_header_size_prefix` bytes
/// (`src/lib/zstd.h:1257`); shorter input is `error.SrcSizeWrong`.
pub fn frameHeaderSize(src: []const u8) Error!usize {
    return checked(c.ZSTD_frameHeaderSize(src.ptr, src.len));
}

/// Whether `src` begins with one of the sixteen skippable magic numbers.
///
/// `ZSTD_isSkippableFrame` (`src/lib/zstd.h:1747`), which masks the low nibble
/// and compares (`src/lib/decompress/zstd_decompress.c:405-407`). RFC 8878 §3.1.2
/// is the specification for the sixteen values and for the fact that a skippable
/// frame's payload is skipped rather than decoded.
pub fn isSkippableFrame(src: []const u8) bool {
    return c.ZSTD_isSkippableFrame(src.ptr, src.len) != 0;
}

/// Compress `src` into `dst` in one call.
///
/// `ZSTD_compress` (`src/lib/zstd.h:160`). `dst.len` must be at least
/// `compressBound(src.len)`; upstream says so at `:159` and a smaller destination
/// is `error.DstSizeTooSmall`.
///
/// This allocates a fresh context on every call, because `ZSTD_compress` is the
/// interface that does exactly that
/// (`src/lib/compress/zstd_compress.c:7779-7790`). A caller compressing many
/// buffers should use `Ctx.compress`, which reuses one.
pub fn compress(dst: []u8, src: []const u8, level: Level) Error!usize {
    return checked(c.ZSTD_compress(dst.ptr, dst.len, src.ptr, src.len, level));
}

/// Decompress every frame in `src` into `dst` in one call.
///
/// `ZSTD_decompress` (`src/lib/zstd.h:173`). `dst.len` must be at least
/// `decompressBound(src)`. A skippable frame inside `src` is stepped over, not
/// decoded (`src/lib/decompress/zstd_decompress.c:1120-1132`), and several frames
/// are concatenated into `dst` (`:1087-1166`).
///
/// A truncated frame leaves `dst` **untouched** when the truncation happens
/// before the first block's content: `ZSTD_decompressFrame` reads the block
/// header and checks the block's bytes are present
/// (`src/lib/decompress/zstd_decompress.c:990-994`) before any output pointer
/// moves. Once a block *has* been decoded, later failures have already written.
pub fn decompress(dst: []u8, src: []const u8) Error!usize {
    return checked(c.ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len));
}

/// A recommended input buffer size for streaming compression.
///
/// `ZSTD_CStreamInSize` (`src/lib/zstd.h:842`).
pub fn cStreamInSize() usize {
    return c.ZSTD_CStreamInSize();
}

/// A recommended output buffer size for streaming compression.
///
/// `ZSTD_CStreamOutSize` (`src/lib/zstd.h:843`), which upstream describes as
/// guaranteeing a successful flush of at least one complete compressed block.
pub fn cStreamOutSize() usize {
    return c.ZSTD_CStreamOutSize();
}

/// A recommended input buffer size for streaming decompression.
///
/// `ZSTD_DStreamInSize` (`src/lib/zstd.h:950`).
pub fn dStreamInSize() usize {
    return c.ZSTD_DStreamInSize();
}

/// A recommended output buffer size for streaming decompression.
///
/// `ZSTD_DStreamOutSize` (`src/lib/zstd.h:951`), which upstream describes as
/// guaranteeing a successful flush of at least one complete block in all
/// circumstances.
pub fn dStreamOutSize() usize {
    return c.ZSTD_DStreamOutSize();
}

/// One compression context, and the object that owns it.
///
/// A `Ctx` owns exactly one `ZSTD_CCtx`. `init` creates one through
/// `ZSTD_createCCtx` and `deinit` frees that one through `ZSTD_freeCCtx`, and
/// nothing else frees it. Copying the struct copies the ownership; see
/// "Lifetime" above.
///
/// The memory *inside* the context is upstream's and comes from libc's allocator
/// through `ZSTD_defaultCMem`; see "Allocation" above.
pub const Ctx = struct {
    /// The owned context, or null once `deinit` has run.
    raw: ?*c.ZSTD_CCtx = null,

    /// The one failure `init` can report: libc's allocator could not satisfy a
    /// context. `ZSTD_createCCtx` returns null for exactly that
    /// (`src/lib/compress/zstd_compress.c` returns null from the internal create
    /// on an allocation failure) and nothing else.
    pub const InitError = error{OutOfMemory};

    /// A fresh context with the default level and no pledged input size.
    pub fn init() InitError!Ctx {
        const raw = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// A fresh context with the default level and no pledged input size.
    ///
    /// A convenience spelling of `init` for a caller that reads the context as
    /// `try Ctx.initWithLevel(default_level)`.
    pub fn initWithLevel(new_level: Level) InitError!Ctx {
        var self = try init();
        errdefer self.deinit();
        self.setLevelNoFail(new_level);
        return self;
    }

    /// Free the context and everything it owns.
    ///
    /// The free goes through the same `c` route that opened the context, so a
    /// context created by one provider is always freed by that provider. The
    /// field is cleared afterwards, which makes a second `deinit` on the same
    /// variable a no-op instead of a second free.
    pub fn deinit(self: *Ctx) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCCtx(raw);
    }

    /// Whether this context is still open.
    pub fn isOpen(self: *const Ctx) bool {
        return self.raw != null;
    }

    /// The context itself, for anything the facade does not wrap.
    ///
    /// Stopping the program on a closed context is deliberate: a call into a
    /// freed `ZSTD_CCtx` is not a condition to recover from, and the field is
    /// null precisely so that this is caught at the call rather than inside the C
    /// library.
    pub fn handle(self: *const Ctx) *c.ZSTD_CCtx {
        return self.raw orelse @panic(
            "zstd: this Ctx was freed; deinit() clears the handle and there is " ++
                "no context left to call. Check isOpen() if the lifetime is not " ++
                "obvious.",
        );
    }

    /// Set the compression level, clamping it to the legal range.
    ///
    /// `ZSTD_CCtx_setParameter` with `ZSTD_c_compressionLevel`
    /// (`src/lib/zstd.h:570`) forwards to `ZSTD_CCtxParams_setParameter`, which
    /// clamps rather than refuses (`src/lib/compress/zstd_compress.c:781-782`
    /// through `ZSTD_cParam_clampBounds` at `:642-649`). So a level above
    /// `maxLevel` succeeds and the context ends up at `maxLevel`, and a level
    /// below `minLevel` succeeds at `minLevel`.
    ///
    /// `ZSTD_CCtx_getParameter` (`src/lib/zstd.h:2364`) is what makes the clamp
    /// observable, which is why the setter below does not return the value: a
    /// caller that needs to know what the clamp chose reads it back.
    pub fn setLevel(self: *Ctx, new_level: Level) Error!void {
        try self.setParameter(.compression_level, new_level);
    }

    /// The level this context will actually use, after any clamp.
    pub fn level(self: *Ctx) Error!Level {
        return self.getParameter(.compression_level);
    }

    /// Set one compression parameter.
    ///
    /// `ZSTD_CCtx_setParameter` (`src/lib/zstd.h:570`). It reports an error code
    /// (`src/lib/zstd.h:568`) rather than a 0 return, so this tests the result
    /// before discarding it.
    ///
    /// Two upstream behaviours a caller has to know:
    ///
    ///   * Parameters are only settable during frame initialisation, except for
    ///     the eight that `src/lib/compress/zstd_compress.c:648-661` authorises
    ///     mid-frame. Anything else after a frame has started is
    ///     `error.WrongStage` (`:605-609`).
    ///   * `ZSTD_c_compressionLevel` is clamped; every other named parameter is
    ///     refused out of bounds (`src/lib/compress/zstd_compress.c:653-655`).
    pub fn setParameter(self: *Ctx, param: CParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@intFromEnum(param)), value));
    }

    /// Read one compression parameter back.
    ///
    /// `ZSTD_CCtx_getParameter` (`src/lib/zstd.h:2364`), which returns the error
    /// in its return value and the value through the last argument. It is
    /// `ZSTDLIB_STATIC_API`, which is why `zig/translate.h` compiles the library
    /// with `ZSTD_STATIC_LINKING_ONLY`.
    pub fn getParameter(self: *Ctx, param: CParameter) Error!Level {
        var value: Level = undefined;
        try checkedVoid(c.ZSTD_CCtx_getParameter(self.handle(), @intCast(@intFromEnum(param)), &value));
        return value;
    }

    /// The level set without asking whether the call succeeded.
    ///
    /// `initWithLevel` uses this because a fresh context cannot be in the wrong
    /// stage and a level cannot be refused. Everything else should use
    /// `setLevel` and see the result.
    fn setLevelNoFail(self: *Ctx, new_level: Level) void {
        _ = c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@intFromEnum(CParameter.compression_level)), new_level);
    }

    /// Tell the encoder how large the input will be.
    ///
    /// `ZSTD_CCtx_setPledgedSrcSize` (`src/lib/zstd.h:587`). Pledging a size is
    /// what lets the encoder write the content size into the frame header
    /// (`ZSTD_c_contentSizeFlag`), which is the field RFC 8878 §3.1.1.1.1.4
    /// describes and the field a decoder reads back with `frameContentSize`.
    pub fn setPledgedSourceSize(self: *Ctx, size: u64) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setPledgedSrcSize(self.handle(), size));
    }

    /// Compress `src` into `dst` with this context.
    ///
    /// `ZSTD_compressCCtx` (`src/lib/zstd.h:293`), whose own comment at `:287-291`
    /// is explicit that it ignores every advanced parameter and compresses at the
    /// requested level only. That is the right call when a caller wants a level
    /// per buffer and no state; use `stream2` when the parameters matter.
    pub fn compress(self: *Ctx, dst: []u8, src: []const u8, new_level: Level) Error!usize {
        return checked(c.ZSTD_compressCCtx(self.handle(), dst.ptr, dst.len, src.ptr, src.len, new_level));
    }

    /// One streaming compression step: consume some of `input`, fill some of
    /// `output`.
    ///
    /// `ZSTD_compressStream2` (`src/lib/zstd.h:823`), which upstream calls the
    /// only recommended advanced compression API (`src/lib/zstd.h:812`). Both
    /// buffers are updated in place through `pos`, so a caller loops while either
    /// cursor has room left and until `endOp` is `.@"end"` with a 0 return.
    ///
    /// The context's parameters are the ones set on it, so this is the call that
    /// honours `setParameter`.
    pub fn stream2(
        self: *Ctx,
        output: *OutBuffer,
        input: *InBuffer,
        endOp: EndOp,
    ) Error!usize {
        return checked(c.ZSTD_compressStream2(
            self.handle(),
            output,
            input,
            @intCast(@intFromEnum(endOp)),
        ));
    }

    /// Return the context to a clean state.
    ///
    /// `ZSTD_CCtx_reset` (`src/lib/zstd.h:609`), whose two axes - session and
    /// parameters - are the two values `Reset` names.
    pub fn reset(self: *Ctx, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_CCtx_reset(self.handle(), @intCast(@intFromEnum(directive))));
    }

    /// Compress `src` into `dst` with a digested dictionary.
    ///
    /// `ZSTD_compress_usingCDict` (`src/lib/zstd.h:1012`). Its own comment at
    /// `:1010-1011` states the two facts a caller has to know: the compression
    /// level is decided when the dictionary is created, and the frame
    /// parameters are fixed - dictionary ID yes, content size yes, checksum no.
    /// So this takes no level, and a frame it writes will carry a dictionary ID
    /// that `dictIDFromFrame` can read back.
    pub fn compressUsingCDict(self: *Ctx, dst: []u8, src: []const u8, dict: *const CDict) Error!usize {
        return checked(c.ZSTD_compress_usingCDict(
            self.handle(),
            dst.ptr,
            dst.len,
            src.ptr,
            src.len,
            dict.handle(),
        ));
    }
};

/// One decompression context, and the object that owns it.
///
/// The counterpart of `Ctx`: it owns exactly one `ZSTD_DCtx`, created through
/// `ZSTD_createDCtx` and freed through `ZSTD_freeDCtx`. It exists so that many
/// buffers can be decoded with one allocation, which is the reason upstream
/// recommends it (`src/lib/zstd.h:22-25`).
pub const Dctx = struct {
    /// The owned context, or null once `deinit` has run.
    raw: ?*c.ZSTD_DCtx = null,

    /// The one failure `init` can report: libc's allocator could not satisfy a
    /// context.
    pub const InitError = error{OutOfMemory};

    /// A fresh decompression context.
    pub fn init() InitError!Dctx {
        const raw = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and everything it owns.
    ///
    /// Clearing the field makes a second `deinit` a no-op rather than a second
    /// free; see `Ctx.deinit` for the rest.
    pub fn deinit(self: *Dctx) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeDCtx(raw);
    }

    /// Whether this context is still open.
    pub fn isOpen(self: *const Dctx) bool {
        return self.raw != null;
    }

    /// The context itself, for anything the facade does not wrap.
    pub fn handle(self: *const Dctx) *c.ZSTD_DCtx {
        return self.raw orelse @panic(
            "zstd: this Dctx was freed; deinit() clears the handle and there is " ++
                "no context left to call. Check isOpen() if the lifetime is not " ++
                "obvious.",
        );
    }

    /// Set one decompression parameter.
    ///
    /// `ZSTD_DCtx_setParameter` (`src/lib/zstd.h:686`). Its own comment at `:683`
    /// says setting a parameter is only possible during frame initialisation,
    /// and `src/lib/compress/zstd_decompress.c` enforces that, so a call after a
    /// frame has started is `error.WrongStage`.
    pub fn setParameter(self: *Dctx, param: DParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_DCtx_setParameter(self.handle(), @intCast(@intFromEnum(param)), value));
    }

    /// Decompress every frame in `src` into `dst` with this context.
    ///
    /// `ZSTD_decompressDCtx` (`src/lib/zstd.h:1197` of
    /// `src/lib/decompress/zstd_decompress.c`), which unlike `ZSTD_decompress`
    /// does not allocate: the context is the workspace.
    pub fn decompress(self: *Dctx, dst: []u8, src: []const u8) Error!usize {
        return checked(c.ZSTD_decompressDCtx(self.handle(), dst.ptr, dst.len, src.ptr, src.len));
    }

    /// Decompress `src` into `dst` with `dict` applied.
    ///
    /// `ZSTD_decompress_usingDict` (`src/lib/zstd.h:976`). The dictionary is
    /// borrowed for this call only: upstream says the function "loads the
    /// dictionary into the context, then starts decompression"
    /// (`src/lib/zstd.h:960-963`), so `dict` can go away the moment this returns.
    pub fn decompressUsingDict(
        self: *Dctx,
        dst: []u8,
        src: []const u8,
        dict: []const u8,
    ) Error!usize {
        return checked(c.ZSTD_decompress_usingDict(
            self.handle(),
            dst.ptr,
            dst.len,
            src.ptr,
            src.len,
            dict.ptr,
            dict.len,
        ));
    }

    /// Return the context to a clean state.
    ///
    /// `ZSTD_DCtx_reset` (`src/lib/zstd.h:694`).
    pub fn reset(self: *Dctx, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_DCtx_reset(self.handle(), @intCast(@intFromEnum(directive))));
    }

    /// Decompress `src` into `dst` with a digested dictionary.
    ///
    /// `ZSTD_decompress_usingDDict` (`src/lib/zstd.h:1033`), the pair of
    /// `Ctx.compressUsingCDict` and the entry point upstream recommends when the
    /// same dictionary is used more than once. The digested state is read-only,
    /// so one `DDict` can be shared between threads.
    pub fn decompressUsingDDict(self: *Dctx, dst: []u8, src: []const u8, dict: *const DDict) Error!usize {
        return checked(c.ZSTD_decompress_usingDDict(
            self.handle(),
            dst.ptr,
            dst.len,
            src.ptr,
            src.len,
            dict.handle(),
        ));
    }
};

/// A streaming compression context, and the object that owns it.
///
/// `ZSTD_CStream` is a typedef of `ZSTD_CCtx` in upstream's own header -
/// `src/lib/zstd.h:776` spells it `typedef ZSTD_CCtx ZSTD_CStream;` and
/// `:725` says "since v1.3.0, ZSTD_CStream and ZSTD_CCtx are the same thing" -
/// so this and `Ctx` are two Zig views of one C type, not two C types. They
/// exist separately because they answer different questions: `Ctx` is "compress
/// this buffer at this level", and `CStream` is "feed me bytes over time".
pub const CStream = struct {
    /// The owned context, or null once `deinit` has run.
    raw: ?*c.ZSTD_CStream = null,

    /// The one failure `init` can report: libc's allocator could not satisfy a
    /// context.
    pub const InitError = error{OutOfMemory};

    /// A fresh streaming context with no level set.
    pub fn init() InitError!CStream {
        const raw = c.ZSTD_createCStream() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and everything it owns.
    ///
    /// Clearing the field makes a second `deinit` a no-op rather than a second
    /// free; see `Ctx.deinit` for the rest.
    pub fn deinit(self: *CStream) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCStream(raw);
    }

    /// Whether this context is still open.
    pub fn isOpen(self: *const CStream) bool {
        return self.raw != null;
    }

    /// The context itself, for anything the facade does not wrap.
    pub fn handle(self: *const CStream) *c.ZSTD_CStream {
        return self.raw orelse @panic(
            "zstd: this CStream was freed; deinit() clears the handle and there " ++
                "is no context left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }

    /// Start a frame at `level`, discarding anything the context had staged.
    ///
    /// `ZSTD_initCStream` (`src/lib/zstd.h:862`), whose comment at `:856-858`
    /// warns that it "clears any previously set dictionary". That is a real
    /// behaviour change for a caller who set a `ZSTD_CDict` on the context and
    /// then calls this.
    pub fn initLevel(self: *CStream, level: Level) Error!void {
        try checkedVoid(c.ZSTD_initCStream(self.handle(), level));
    }

    /// One streaming step.
    ///
    /// `ZSTD_compressStream2` (`src/lib/zstd.h:823`) again: upstream has one
    /// streaming entry point, and the `ZSTD_CStream` spelling above it is an
    /// alias. This method exists so a caller holding a `CStream` does not have to
    /// name the other type.
    pub fn compress(
        self: *CStream,
        output: *OutBuffer,
        input: *InBuffer,
        endOp: EndOp,
    ) Error!usize {
        return checked(c.ZSTD_compressStream2(
            self.handle(),
            output,
            input,
            @intCast(@intFromEnum(endOp)),
        ));
    }

    /// Flush without closing the frame.
    ///
    /// `ZSTD_flushStream` (`src/lib/zstd.h:871`), which is the `.flush` end
    /// operation in its own right.
    pub fn flush(self: *CStream, output: *OutBuffer) Error!usize {
        return checked(c.ZSTD_flushStream(self.handle(), output));
    }

    /// Flush and close the frame.
    ///
    /// `ZSTD_endStream` (`src/lib/zstd.h:873`), which is the `.@"end"` end
    /// operation. Upstream notes the frame is only closed once the compressed
    /// data is fully flushed, so a caller loops until this returns 0.
    pub fn end(self: *CStream, output: *OutBuffer) Error!usize {
        return checked(c.ZSTD_endStream(self.handle(), output));
    }

    /// Set one compression parameter on this streaming context.
    ///
    /// `ZSTD_CCtx_setParameter` (`src/lib/zstd.h:570`), through
    /// `src/lib/zstd.h:857` which spells the level example for a `ZSTD_CStream`.
    pub fn setParameter(self: *CStream, param: CParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@intFromEnum(param)), value));
    }

    /// This context as a plain compression context, for a call that takes a
    /// `ZSTD_CCtx*`.
    ///
    /// Safe because `src/lib/zstd.h:776` makes the two the same type; the
    /// conversion is a statement of that typedef and nothing else.
    pub fn asCtx(self: *CStream) *c.ZSTD_CCtx {
        return self.handle();
    }
};

/// A streaming decompression context, and the object that owns it.
///
/// As with `CStream`, `src/lib/zstd.h:908` spells
/// `typedef ZSTD_DCtx ZSTD_DStream;`, so this is a view of `Dctx`'s C type and
/// not a second kind of object.
pub const DStream = struct {
    /// The owned context, or null once `deinit` has run.
    raw: ?*c.ZSTD_DStream = null,

    /// The one failure `init` can report: libc's allocator could not satisfy a
    /// context.
    pub const InitError = error{OutOfMemory};

    /// A fresh streaming context.
    pub fn init() InitError!DStream {
        const raw = c.ZSTD_createDStream() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and everything it owns.
    ///
    /// Clearing the field makes a second `deinit` a no-op rather than a second
    /// free; see `Ctx.deinit` for the rest.
    pub fn deinit(self: *DStream) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeDStream(raw);
    }

    /// Whether this context is still open.
    pub fn isOpen(self: *const DStream) bool {
        return self.raw != null;
    }

    /// The context itself, for anything the facade does not wrap.
    pub fn handle(self: *const DStream) *c.ZSTD_DStream {
        return self.raw orelse @panic(
            "zstd: this DStream was freed; deinit() clears the handle and there " ++
                "is no context left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }

    /// Restart decompression on this context, as `ZSTD_initDStream` does.
    ///
    /// The value is a hint rather than an error: a number above zero is how much
    /// input to hand over again, because a caller is allowed to pass a short
    /// first chunk. Zero means the job is ready. The name is apart from `init`
    /// because that one belongs to the constructor, and a struct cannot hold both.
    pub fn initStream(self: *DStream) usize {
        return c.ZSTD_initDStream(self.handle());
    }

    /// One streaming decompression step.
    ///
    /// `ZSTD_decompressStream` (`src/lib/zstd.h:948`). The return value is 0 when
    /// a frame is completely decoded and flushed, and anything above 0 means
    /// there is more to do - the upstream contract is at `src/lib/zstd.h:943-946`.
    ///
    /// A value that is an error is returned as an error, and upstream warns that
    /// the context is then in an undefined state and must be re-initialised
    /// before use (`src/lib/zstd.h:947-948`). `reset` is that call.
    pub fn decompress(self: *DStream, output: *OutBuffer, input: *InBuffer) Error!usize {
        return checked(c.ZSTD_decompressStream(self.handle(), output, input));
    }

    /// Return the context to a clean state after a failed step.
    ///
    /// `ZSTD_DCtx_reset` (`src/lib/zstd.h:694`), which is what upstream's own
    /// warning at `src/lib/zstd.h:947-948` asks for.
    pub fn reset(self: *DStream, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_DCtx_reset(self.handle(), @intCast(@intFromEnum(directive))));
    }

    /// This context as a plain decompression context.
    ///
    /// Safe because `src/lib/zstd.h:908` makes the two the same type.
    pub fn asDctx(self: *DStream) *c.ZSTD_DCtx {
        return self.handle();
    }
};

/// A digested compression dictionary, and the object that owns it.
///
/// `ZSTD_createCDict` (`src/lib/zstd.h:999`) copies the dictionary into the
/// digested state, so `src/lib/zstd.h:994`'s guarantee - "`@dictBuffer` can be
/// released after `ZSTD_createCDict` creation" - is upstream's and this type
/// neither weakens nor extends it. The digested state is read-only and
/// `src/lib/zstd.h:993` says it can be shared between threads.
pub const CDict = struct {
    /// The owned dictionary, or null once `deinit` has run.
    raw: ?*c.ZSTD_CDict = null,

    /// The only failures `init` can report.
    ///
    /// `ZSTD_createCDict` returns null for an allocation failure, and reports
    /// everything else as an error code rather than as null - upstream's own
    /// comment at `src/lib/zstd.h:983-984` lists the parameter and dictionary
    /// errors. Both are folded into this one error.
    pub const InitError = error{OutOfMemory};

    /// Digest `dict` for use at `level`.
    ///
    /// `ZSTD_createCDict` (`src/lib/zstd.h:999`). `src/lib/zstd.h:996-998` also
    /// allows an empty `dict`, in which case the only thing carried is the level.
    pub fn init(dict: []const u8, level: Level) InitError!CDict {
        const raw = c.ZSTD_createCDict(dict.ptr, dict.len, level) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the digested state.
    ///
    /// Clearing the field makes a second `deinit` a no-op rather than a second
    /// free; see `Ctx.deinit` for the rest.
    pub fn deinit(self: *CDict) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCDict(raw);
    }

    /// Whether this dictionary is still open.
    pub fn isOpen(self: *const CDict) bool {
        return self.raw != null;
    }

    /// The digested state itself, for a call that takes a `ZSTD_CDict*`.
    pub fn handle(self: *const CDict) *c.ZSTD_CDict {
        return self.raw orelse @panic(
            "zstd: this CDict was freed; deinit() clears the handle and there is " ++
                "no dictionary left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }
};

/// A digested decompression dictionary, and the object that owns it.
///
/// `ZSTD_createDDict` (`src/lib/zstd.h:1023`). Its own comment at `:1019-1021`
/// says the content is loaded into the digested state, so `dict` may be released
/// immediately, exactly as for `CDict`.
pub const DDict = struct {
    /// The owned dictionary, or null once `deinit` has run.
    raw: ?*c.ZSTD_DDict = null,

    /// The only failure `init` can report: an allocation failure. A malformed
    /// dictionary is reported as an error code by
    /// `ZSTD_createDDict_advanced`, not as a null from this entry point.
    pub const InitError = error{OutOfMemory};

    /// Digest `dict` for decompression.
    pub fn init(dict: []const u8) InitError!DDict {
        const raw = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the digested state.
    ///
    /// Clearing the field makes a second `deinit` a no-op rather than a second
    /// free; see `Ctx.deinit` for the rest.
    pub fn deinit(self: *DDict) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeDDict(raw);
    }

    /// Whether this dictionary is still open.
    pub fn isOpen(self: *const DDict) bool {
        return self.raw != null;
    }

    /// The digested state itself, for a call that takes a `ZSTD_DDict*`.
    pub fn handle(self: *const DDict) *c.ZSTD_DDict {
        return self.raw orelse @panic(
            "zstd: this DDict was freed; deinit() clears the handle and there is " ++
                "no dictionary left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }
};

/// What a frame says about the content it holds.
///
/// `ZSTD_getFrameContentSize` (`src/lib/zstd.h:205`) answers one of three numbers
/// and this is the same three, told apart. The distinction that matters is the
/// first one: upstream returns `0` for a skippable frame
/// (`src/lib/decompress/zstd_decompress.c:580-581`) and `0` is also the size of an
/// empty frame, so the raw answer cannot say which it saw. `.known(0)` is this
/// module reporting what the function said, not resolving the ambiguity; use
/// `isSkippableFrame` for that.
pub const ContentSize = union(enum) {
    /// The frame declares a content size, and this is it. Zero means an empty
    /// frame.
    known: u64,
    /// The frame carries no content-size field
    /// (`ZSTD_CONTENTSIZE_UNKNOWN`, `src/lib/zstd.h:203`).
    unknown,
    /// The header could not be decoded at all - too few bytes, or a magic number
    /// that is neither zstd's nor skippable's (`ZSTD_CONTENTSIZE_ERROR`,
    /// `src/lib/zstd.h:204`).
    undecodable,

    /// The upstream number, as this union.
    pub fn of(value: u64) ContentSize {
        return switch (value) {
            content_size_unknown => .unknown,
            content_size_error => .undecodable,
            else => .{ .known = value },
        };
    }

    /// The size, when there is one.
    pub fn get(self: ContentSize) ?u64 {
        return switch (self) {
            .known => |size| size,
            else => null,
        };
    }
};

/// Train a dictionary from `samples` and write it into `dict`.
///
/// `ZDICT_trainFromBuffer` (`src/lib/zdict.h:210`), which upstream documents as
/// taking about 6 MB of memory for the call (`src/lib/zdict.h:204`). `dict.len`
/// must be at least `dict_size_min` (256, `src/lib/zdict.h:305`), and the answer
/// is the number of bytes written, which is the same value `dictID` reads back.
///
/// The samples are the *contents* of many small buffers, and the C API wants them
/// packed into one region with their lengths alongside. This function does that
/// packing in a scratch buffer it takes from `allocator` and frees before
/// returning, which is the only heap use in this module and the reason it is the
/// only function here that takes an allocator.
///
/// `src/lib/zdict.h:184-189` states that a dictionary's benefit comes from
/// samples being *similar* to each other, and that the first few bytes are
/// omitted from the dictionary; that is upstream's guidance about choosing
/// samples, not something this function can check.
///
/// Failures are reported through upstream's error codes: a training failure is
/// `error.DictionaryTrainingFailed` and a buffer that is too small is
/// `error.DstSizeTooSmall`, both read from the returned code rather than
/// inferred.
pub fn trainDictionary(
    allocator: std.mem.Allocator,
    dict: []u8,
    samples: []const []const u8,
) Error!usize {
    if (dict.len < dict_size_min) return error.DstSizeTooSmall;

    // One allocation for the packed contents and one for the length array,
    // both sized from the caller's own slices so neither can be wrong.
    const total = std.mem.concat(allocator, u8, samples) catch return error.OutOfMemory;
    defer allocator.free(total);
    const sizes = allocator.alloc(usize, samples.len) catch return error.OutOfMemory;
    defer allocator.free(sizes);
    for (samples, 0..) |sample, index| sizes[index] = sample.len;

    const written = c.ZDICT_trainFromBuffer(dict.ptr, dict.len, total.ptr, sizes.ptr, @intCast(samples.len));
    if (zdictIsError(written)) return errorFromCode(errorCode(written));
    return written;
}

/// The dictionary ID stored in `dict`, or 0.
///
/// `ZDICT_getDictID` (`src/lib/zdict.h:269`), whose own comment says zero is the
/// answer for anything that is not a valid dictionary. `trainDictionary` writes
/// a valid one, so a 0 from its output means something else went wrong upstream.
pub fn dictID(dict: []const u8) u32 {
    return c.ZDICT_getDictID(dict.ptr, dict.len);
}

/// Whether a `ZDICT_*` result is an error rather than a byte count.
///
/// `ZDICT_isError` (`src/lib/zdict.h:271`). The dictionary builder has its own
/// error predicate rather than reusing `ZSTD_isError`, so a caller mixing the two
/// families needs both; this module tests the right one at each boundary.
pub fn zdictIsError(result: usize) bool {
    return c.ZDICT_isError(result) != 0;
}

/// The dictionary builder's own message for a result.
///
/// `ZDICT_getErrorName` (`src/lib/zdict.h:272`).
pub fn zdictErrorName(result: usize) [:0]const u8 {
    return std.mem.span(c.ZDICT_getErrorName(result));
}

/// The smallest dictionary the builder will produce, 256
/// (`src/lib/zdict.h:305`).
pub const dict_size_min: usize = c.ZDICT_DICTSIZE_MIN;

/// One `ZSTD_ErrorCode` as one Zig error tag.
///
/// The single funnel from a raw Zstandard code to a Zig error, and the place the
/// `Error` set's cut is written down in code. Its arms are the tags of `Error`
/// minus the two this build cannot reach, and `src/lib/zstd_errors.h:90`'s "not
/// stable" marking of everything at or above 100 is why those six share one arm.
///
/// `no_error` has no tag: it is not a failure, and every caller that reaches the
/// funnel has already tested `ZSTD_isError`, so a zero code means the result was
/// a length after all. `error.UnstableCode` reports that something went wrong
/// without claiming to know what, which is the honest answer for the group
/// upstream says can change.
fn errorFromCode(code: ErrorCode) Error {
    return switch (code) {
        .no_error => error.UnstableCode,
        .generic => error.Generic,
        .prefix_unknown => error.NotAZstdFrame,
        .version_unsupported => error.UnstableCode,
        .frame_parameter_unsupported => error.FrameParameterUnsupported,
        .window_too_large => error.WindowTooLarge,
        .corruption_detected => error.Corruption,
        .checksum_wrong => error.ChecksumMismatch,
        .literals_header_wrong => error.LiteralsHeaderWrong,
        .dictionary_corrupted => error.DictionaryCorrupted,
        .dictionary_wrong => error.DictionaryRejected,
        .dictionary_creation_failed => error.DictionaryTrainingFailed,
        .parameter_unsupported => error.ParameterUnsupported,
        .parameter_combination_unsupported => error.ParameterCombinationUnsupported,
        .parameter_out_of_bound => error.ParameterOutOfBound,
        .table_log_too_large => error.TableLogTooLarge,
        .max_symbol_value_too_large => error.MaxSymbolValueTooLarge,
        .max_symbol_value_too_small => error.MaxSymbolValueTooSmall,
        .cannot_produce_uncompressed_block => error.CannotProduceUncompressedBlock,
        .stability_condition_not_respected => error.StabilityConditionNotRespected,
        .stage_wrong => error.WrongStage,
        .init_missing => error.InitMissing,
        .memory_allocation => error.OutOfMemory,
        .work_space_too_small => error.WorkSpaceTooSmall,
        .dst_size_too_small => error.DstSizeTooSmall,
        .src_size_wrong => error.SrcSizeWrong,
        .dst_buffer_null => error.DstBufferNull,
        .no_forward_progress_dest_full => error.NoForwardProgressDstFull,
        .no_forward_progress_input_empty => error.NoForwardProgressInputEmpty,
        .unstable_frame_index_too_large,
        .unstable_seekable_io,
        .unstable_dst_buffer_wrong,
        .unstable_src_buffer_wrong,
        .unstable_sequence_producer_failed,
        .unstable_external_sequences_invalid,
        .unrecognised,
        => error.UnstableCode,
    };
}

/// A `size_t` result that is a byte count, or the error it stands for.
///
/// The one place this module decides what a raw result means. Every typed wrapper
/// that returns a length comes through here, so there is a single answer to "how
/// does a Zstandard code become a Zig error" and the set on `Error` is the set
/// this function can produce.
fn checked(result: usize) Error!usize {
    if (c.ZSTD_isError(result) != 0) return errorFromCode(ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised);
    return result;
}

/// A `size_t` result that means "nothing went wrong" or is an error.
///
/// The same funnel for the entry points that report success as 0 -
/// `ZSTD_CCtx_setParameter`, `ZSTD_DCtx_setParameter`, `ZSTD_CCtx_reset` and the
/// two `ZSTD_free*` calls that can fail - rather than a count.
fn checkedVoid(result: usize) Error!void {
    if (c.ZSTD_isError(result) != 0) return errorFromCode(ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised);
}