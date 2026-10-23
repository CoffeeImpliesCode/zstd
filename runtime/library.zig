// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zstandard-specific loader descriptor and provider validation.
//! The translation exposes 189 functions via `ZSTD_STATIC_LINKING_ONLY`.
//! The version check requires 1.5.7 (`ZSTD_VERSION_NUMBER` 10507).
//! Experimental parameter meanings can vary across 1.5.x; provider allocations,
//! layouts, and callbacks must match the ABI.
//! Validation checks version, error reporting, bounds, and a round trip; it
//! neither authenticates providers nor validates arbitrary input.
//! `ZSTD_maxCLevel` may vary by build and is unchecked. The pinned upstream
//! implementation does not provide the legacy-frame bound described in its comment.

const std = @import("std");
const rt = @import("rt");

/// The same target/configuration translation used to generate the dispatch.
const c = @import("c");

/// Synchronization symbols bound to the graph's `zstd_rt` prefix.
/// Each independent SDK instance needs distinct symbols and loader state.
pub const Sync = struct {
    extern fn zstd_rt_lock() void;
    extern fn zstd_rt_unlock() void;
    extern fn zstd_rt_wait() void;
    extern fn zstd_rt_broadcast() void;
    // `unsigned long long` is 64 bits on every supported target.
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

/// Nonuniform fixed input for the provider validation round trip.
const probe = "zstd runtime probe payload";

/// Loader configuration for a dispatch type, without importing that module.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// SDK name used in pre-load diagnostics.
        pub const library_name = "zstd";

        /// Table and symbols generated from the translated headers.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// This SDK's namespaced synchronization binding.
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

        /// Validate the provider after symbol resolution and before publishing.
        /// Returns a static error message on failure.
        pub fn validate(dst: *const table) ?[]const u8 {
            // Reject providers whose version differs from the translated headers.
            const family: c_uint = dst.ZSTD_versionNumber();
            const expected: c_uint = @intCast(dispatch.ZSTD_VERSION_NUMBER);
            if (family != expected) {
                // Print numbers; validation cannot allocate a formatted message.
                std.debug.print(
                    "zstd: provider reports ZSTD_versionNumber {d}, this SDK's " ++
                        "headers describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different Zstandard release " ++
                    "than the one this SDK's headers describe";
            }

            // Exercise error reporting with an out-of-bounds parameter.
            // Free the context before returning on later failures.
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
            // Error-code lookup must agree with `ZSTD_isError`.
            if (dst.ZSTD_getErrorCode(refused) != dispatch.ZSTD_error_parameter_outOfBound) {
                return "ZSTD_getErrorCode disagreed with ZSTD_isError about an " ++
                    "out-of-bounds parameter, so this provider's error codes " ++
                    "are not the ones these headers describe";
            }
            // Error names must distinguish failure from success.
            {
                const name = std.mem.span(dst.ZSTD_getErrorName(refused));
                const ok_name = std.mem.span(dst.ZSTD_getErrorName(0));
                if (name.len == 0 or std.mem.eql(u8, name, ok_name)) {
                    return "ZSTD_getErrorName did not distinguish this failure " ++
                        "from success, so this provider's error strings are not " ++
                        "the ones these headers describe";
                }
            }

            // Check the bound and round trip with fixed buffers; validation has no allocator.
            var round_trip: [probe.len]u8 = undefined;
            const bound = dst.ZSTD_compressBound(probe.len);
            if (dst.ZSTD_isError(bound) != 0 or bound < probe.len) {
                return "ZSTD_compressBound did not return a bound at least as " ++
                    "large as the input, so no allocation made from it could " ++
                    "hold this library's own output";
            }
            // Bound the frame buffer; the checked worst-case size is not comptime.
            var frame: [probe.len + 64]u8 = undefined;
            // Use the compression level from the translated header.
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
            // Preserve the provider's `size_t` result as the decompression capacity.
            if (read != probe.len or !std.mem.eql(u8, round_trip[0..read], probe)) {
                return "a compress/decompress round trip through this provider " ++
                    "did not return the bytes it was given";
            }

            return null;
        }
    };
}
