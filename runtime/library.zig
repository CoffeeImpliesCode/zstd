// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zstandard's side of the runtime loader: the names its synchronization binding
//! has, what it requires of a provider beyond resolving its symbols, and what
//! the external ABI boundary for this provider actually is.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! Zstandard's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! All 189 declarations `zig/translate.h` names: every function declared by
//! `src/lib/zstd.h`, `src/lib/zdict.h` and `src/lib/zstd_errors.h`, and nothing
//! else. There is no config-gated entry point in this configuration: `build.zig`
//! compiles the library with the same `ZSTD_STATIC_LINKING_ONLY` it puts on the
//! translation, so the names that macro exposes are present in both, and the
//! other macros this build sets - `XXH_NAMESPACE`, `DEBUGLEVEL`,
//! `ZSTD_LEGACY_SUPPORT`, `DYNAMIC_BMI2` - select branches inside upstream's
//! `.c` units rather than declarations in a header. So
//! `provider_optional` and `provider_excluded` in `runtime/graph.zig` are both
//! empty, and a provider that does not export the whole set is refused rather
//! than half used.
//!
//! ## The ABI boundary, stated honestly
//!
//! The supported external ABI family is **Zstandard 1.5**, `ZSTD_VERSION_NUMBER`
//! 10507, composed by `src/lib/zstd.h:115` as
//! `ZSTD_VERSION_MAJOR * 100 * 100 + ZSTD_VERSION_MINOR * 100 + ZSTD_VERSION_RELEASE`
//! from the three numbers at `src/lib/zstd.h:112-114`. That is a narrower claim
//! than "a shared object that exports these names", and the difference is real:
//!
//!   * The frame format is the contract, not the ABI. A provider built with
//!     `ZSTD_STATIC_LINKING_ONLY` and one built without it export the same
//!     189 names; what differs is which of them the header declares. This build
//!     defines the macro on the translation line, so a provider that was built
//!     without it still exports every name the loader looks for, and the
//!     functions this SDK calls are the stable ones.
//!   * `ZSTD_compressionParameters` and every `ZSTD_*Parameter` enum value are
//!     *experimental* by upstream's own statement (`src/lib/zstd.h:104-109`:
//!     "Advanced experimental functions can be accessed using `#define
//!     ZSTD_STATIC_LINKING_ONLY` before including zstd.h"), and
//!     `src/lib/zstd.h:517-524` says of the compression-parameter enum values
//!     themselves that they "can still change". A provider built from another
//!     1.5.x can therefore accept the same numbers with different meanings, and
//!     no version check catches that.
//!   * The allocator is the provider's. `ZSTD_createCCtx`
//!     (`src/lib/zstd.h:281`) and `ZSTD_createCDict` (`src/lib/zstd.h:999`) both
//!     allocate through `ZSTD_defaultCMem`, and
//!     `src/lib/common/zstd_deps.h:64-68` spells that allocator as libc's
//!     `malloc`/`calloc`/`free` behind the `ZSTD_malloc`/`ZSTD_calloc`/
//!     `ZSTD_free` macros. Nothing in this SDK can observe, bound or account for
//!     those allocations: a Zig allocator is not in the path, and a test
//!     framework cannot supply a leak oracle for memory a third-party allocator
//!     owns.
//!   * `ZSTD_inBuffer`, `ZSTD_outBuffer` (`src/lib/zstd.h:701-711`) and
//!     `ZSTD_FrameHeader` (`src/lib/zstd.h:1507-1520`) are fixed-layout structs
//!     whose members the streaming entry points read through a pointer the
//!     provider dereferences, so a provider whose `size_t` is not the same width
//!     as this header's disagrees about every field in them.
//!   * `ZSTD_customMem`'s `ZSTD_freeFunction` member is a function-pointer type
//!     crossing the boundary in both directions, and a caller that hands
//!     `ZSTD_createCCtx_advanced` its own allocator is responsible for the
//!     matching free on the far side.
//!
//! **A different 1.x is refused.** The version check below is what separates
//! Zstandard 1.5 from 1.4, from 1.3 and from the pre-1.0 libraries, whose
//! `ZSTD_versionNumber` did not exist and whose `ZSTD_CCtx` layout differed.
//! `ZSTD_decompressBound` is a place where the difference shows: the comment at
//! `src/lib/decompress/zstd_decompress.c:814-815` labels it "compatible with
//! legacy mode" while the body at `:825` walks the input with
//! `ZSTD_findFrameSizeInfo(..., ZSTD_f_zstd1)` and has no legacy arm, unlike
//! `ZSTD_getFrameContentSize` at `:571-576`, which has one. A consumer relying
//! on a bound for a v0.5-v0.7 frame is relying on behaviour this SDK's own
//! pinned source does not provide - which is a statement about the code read
//! here, not about any run, and is recorded as an open item in
//! [`FORK-NOTES.md`](FORK-NOTES.md).
//!
//! **An unrelated shared object with the right names would still pass the four
//! checks below.** Resolving the symbols and translating the header is the
//! boundary. They are not proof that a provider is a correct Zstandard, and
//! this file does not pretend to add more than it checks. What is checked at
//! load time, before anything is published:
//!
//!   * `ZSTD_versionNumber` answers with this header's `ZSTD_VERSION_NUMBER`.
//!     That is the ABI *family* check, and it is the whole of what
//!     `src/lib/zstd.h:118-119` promises the function's answer means.
//!   * A deliberately-bad parameter is refused, and the refusal is legible.
//!     `ZSTD_CCtx_setParameter` with `ZSTD_c_targetLength` and a value past its
//!     bound goes through `BOUNDCHECK`
//!     (`src/lib/compress/zstd_compress.c:653-655`) and returns
//!     `ZSTD_error_parameter_outOfBound` (`src/lib/zstd_errors.h:75`). This is
//!     checked because it is the one call that touches all four of the provider's
//!     error machinery at once: the context allocator, the parameter bounds table,
//!     the error-code space and the error strings. A provider whose
//!     `ZSTD_isError` and `ZSTD_getErrorCode` disagree, or whose
//!     `ZSTD_getErrorName` returns the success string for a failure, fails here.
//!     It also creates and frees a `ZSTD_CCtx`, so the provider's own allocator
//!     and teardown path are exercised and released before `validate` returns.
//!
//!   * A `ZSTD_compress`/`ZSTD_decompress` round trip through *this* table
//!     succeeds and returns the bytes it was given. That exercises the
//!     provider's own compressor and decompressor, its frame writer and its
//!     frame reader, through the same table entries the facade will use, and it
//!     is the shortest end-to-end statement that a provider can decode what it
//!     encoded.
//!   * `ZSTD_compressBound` of that same input is at least that input's length.
//!     `src/lib/zstd.h:249` gives the bound as `srcSize + (srcSize>>8) + margin`,
//!     which is never below `srcSize` for any `srcSize` below
//!     `ZSTD_MAX_INPUT_SIZE` (`src/lib/zstd.h:248`), and `src/lib/zstd.h:250`
//!     is the function wrapping that macro. A provider whose bound came back
//!     smaller than its input would make every allocation this SDK makes from it
//!
//! **What is deliberately not checked, and why.** `ZSTD_maxCLevel` is *not*
//! compared against anything. A provider built with `ZSTD_LIB_MINIFY=1`
//! (`src/lib/libzstd.mk:29`) or with the high compressors excluded
//! (`:194-200`) legitimately reports a *lower* maximum than a stock provider, and
//! that is a configuration difference rather than an ABI break: the frame format
//! either provider writes is the same, and a caller that asks for level 22 and
//! gets level 19 is being clamped by upstream's own
//! `ZSTD_cParam_clampBounds` (`src/lib/compress/zstd_compress.c:642-649`), not
//! broken. Refusing such a provider would turn a working library into a load
//! failure. The level range is documented in `zig/root.zig` and left to the
//! caller.
//!
//! What is deliberately *not* checked here is anything about arbitrary input:
//! this SDK does not claim to be a validator for bytes it did not produce, only
//! to establish that a provider is the library these headers describe.

const std = @import("std");
const rt = @import("rt");

/// The translated headers for the target and configuration this build selected.
///
/// `runtime/graph.zig` gives this module that translation as `c`, which is the
/// same one the dispatch's own declarations were generated from. A constant
/// read here and a declaration there therefore cannot describe two different
/// libraries. It cannot be the dispatch's `c_native`: the dispatch imports this
/// module, so that would be an import cycle.
const c = @import("c");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with `RT_SYNC_PREFIX=zstd_rt`,
/// which is what `runtime/graph.zig` passes. Two spellings of that prefix have
/// to agree: this file names the symbols, and `graph.zig` defines the macro. A
/// build where they disagree does not link, and that is the whole error report:
/// there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn zstd_rt_lock() void;
    extern fn zstd_rt_unlock() void;
    extern fn zstd_rt_wait() void;
    extern fn zstd_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn zstd_rt_thread_self() u64;

    pub fn lock() void {
        zstd_rt_lock();
    }
    pub fn unlock() void {
        zstd_rt_unlock();
    }
    pub fn wait() void {
        zstd_rt_wait();
    }
    pub fn broadcast() void {
        zstd_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return zstd_rt_thread_self();
    }
};

/// The bytes the round trip below compresses and decompresses.
///
/// A literal, not a value the provider computed: a round trip whose input the
/// provider produced would agree with a provider that compresses nothing at
/// all. Twenty-one bytes that are not one repeated character, so a provider
/// that returned its input without decoding anything would still be caught by
/// the frame-size checks above it.
const probe = "zstd runtime probe payload";

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "zstd";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated headers, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The library-specific checks, run after every symbol resolved and
        /// before anything is published.
        ///
        /// A non-null answer is `ValidationFailed` and the candidate is closed
        /// without being published. Every check here is one whose failure this
        /// code can observe; see the module comment for the four and for what
        /// is deliberately not checked.
        pub fn validate(dst: *const table) ?[]const u8 {
            // 1. The ABI family. `ZSTD_versionNumber` takes no argument
            // (`src/lib/zstd.h:119`) and answers `MAJOR*100*100 + MINOR*100 +
            // RELEASE` (`src/lib/zstd.h:118-119`, composed at `:115` from the
            // three numbers at `:112-114`). Comparing it with the same macro
            // this header expands is what separates Zstandard 1.5 from every
            // other family.
            const family: c_uint = dst.ZSTD_versionNumber();
            const expected: c_uint = @intCast(dispatch.ZSTD_VERSION_NUMBER);
            if (family != expected) {
                // The numbers go to the diagnostic stream rather than into the
                // returned text: `validate` has no allocator and the loader
                // reports whatever string it is given.
                std.debug.print(
                    "zstd: provider reports ZSTD_versionNumber {d}, this SDK's " ++
                        "headers describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different Zstandard release " ++
                    "than the one this SDK's headers describe";
            }

            // 2. The error machinery, on a call that is meant to fail. A fresh
            // context, a parameter value past `ZSTD_TARGETLENGTH_MAX`, and then
            // the three functions that turn the refusal into something a caller
            // can read. This is also the provider's allocator and teardown path,
            // and the context is freed here rather than leaked if a later check
            // fails.
            const cctx = dst.ZSTD_createCCtx();
            if (cctx == null) {
                return "ZSTD_createCCtx returned null, so this provider's " ++
                    "allocator could not satisfy a compression context";
            }
            defer _ = dst.ZSTD_freeCCtx(cctx);

            const refused = dst.ZSTD_CCtx_setParameter(
                cctx,
                dispatch.ZSTD_c_targetLength,
                1 << 20,
            );
            if (dst.ZSTD_isError(refused) == 0) {
                return "ZSTD_CCtx_setParameter accepted a target length past " ++
                    "ZSTD_TARGETLENGTH_MAX, so this provider does not enforce " ++
                    "the parameter bounds these headers describe";
            }
            // `ZSTD_isError` said failure; `ZSTD_getErrorCode` has to agree, or
            // every caller that switches on the code is switching on noise.
            if (dst.ZSTD_getErrorCode(refused) != dispatch.ZSTD_error_parameter_outOfBound) {
                return "ZSTD_getErrorCode disagreed with ZSTD_isError about an " ++
                    "out-of-bounds parameter, so this provider's error codes " ++
                    "are not the ones these headers describe";
            }
            // And the name has to be the failure's name, not the success string
            // `ZSTD_getErrorName` returns for a successful result.
            {
                const name = std.mem.span(dst.ZSTD_getErrorName(refused));
                const ok_name = std.mem.span(dst.ZSTD_getErrorName(0));
                if (name.len == 0 or std.mem.eql(u8, name, ok_name)) {
                    return "ZSTD_getErrorName did not distinguish this failure " ++
                        "from success, so this provider's error strings are not " ++
                        "the ones these headers describe";
                }
            }

            // 3 and 4, in one sequence: the bound, then the round trip that has
            // to fit inside it. `probe` is a comptime-known length, so the
            // destination is a fixed array and `validate` allocates nothing -
            // it has no allocator, which is why the return type is a string
            // literal or null and never a formatted message.
            var round_trip: [probe.len]u8 = undefined;
            const bound = dst.ZSTD_compressBound(probe.len);
            if (dst.ZSTD_isError(bound) != 0 or bound < probe.len) {
                return "ZSTD_compressBound did not return a bound at least as " ++
                    "large as the input, so no allocation made from it could " ++
                    "hold this library's own output";
            }
            // Two fixed arrays, because `validate` has no allocator. The frame
            // side is `probe.len + 64`: a frame is at least 4 bytes for the
            // magic number and at most `ZSTD_compressBound(probe.len)`, which
            // is the check that just ran and is a number this code cannot turn
            // into an array length at comptime.
            var frame: [probe.len + 64]u8 = undefined;
            // `ZSTD_compress` takes the level as its fifth argument
            // (`src/lib/zstd.h:134`), and `ZSTD_CLEVEL_DEFAULT` is upstream's
            // own answer for it (`:133-136`) rather than a literal here.
            const written = dst.ZSTD_compress(
                &frame,
                frame.len,
                probe,
                probe.len,
                c.ZSTD_CLEVEL_DEFAULT,
            );
            if (dst.ZSTD_isError(written) != 0) {
                return "ZSTD_compress through this provider failed on a small " ++
                    "known input, so it is not a working compressor";
            }
            const read = dst.ZSTD_decompress(&round_trip, round_trip.len, &frame, written);
            if (dst.ZSTD_isError(read) != 0) {
                return "ZSTD_decompress through this provider failed on a frame " ++
                    "that provider had just written, so it is not a working " ++
                    "decompressor";
            }
            // `written` is `size_t` on the way out of the C call and this is
            // the same nominal type on the way back in, so there is no cast:
            // the frame the provider wrote is the frame the provider is given.
            if (read != probe.len or !std.mem.eql(u8, round_trip[0..read], probe)) {
                return "a compress/decompress round trip through this provider " ++
                    "did not return the bytes it was given";
            }

            return null;
        }
    };
}