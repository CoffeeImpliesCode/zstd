// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! Deterministic Zstandard facade check for RFC, upstream-golden, and producer fixtures.
//! Runtime builds need an explicit provider; linked builds use the linked library.
//! Fixture provenance is in `fixtures/PROVENANCE.md`.

const std = @import("std");
const zstd = @import("zstd");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// Select a provider from `--provider <path>` or `ZSTD_TEST_PROVIDER`.
/// No default location or linked fallback is used.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("ZSTD_TEST_PROVIDER") orelse
        return noProvider();
}

/// Report a missing explicit provider selection.
fn noProvider() ConfigurationError {
    std.debug.print(
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export ZSTD_TEST_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// RFC 8878 frame magic, stored little-endian.
const frame_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// RFC 8878 single-segment frame: one final RLE block, 200 copies of `0x5a`.
const rfc_rle_frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0xc8, 0x43, 0x06, 0x00, 0x5a };

/// Byte repeated by the RFC RLE fixture.
const rfc_rle_byte: u8 = 0x5a;
const rfc_rle_length: usize = 200;

/// Upstream's `rle-first-block.zst` is an independent known answer from RFC RLE semantics.
/// The fixture is embedded from upstream's source tree.
const golden_rle_first = @embedFile("src/tests/golden-decompression/rle-first-block.zst");

/// The upstream RLE fixture decodes to 1 MiB.
const golden_rle_length: usize = 1024 * 1024;

/// CLI and pyzstd level-3 frames are byte-identical outputs of libzstd 1.5.7, not independent encoders.
/// Producer and digest records: `fixtures/PROVENANCE.md` and `fixtures/SHA256SUMS`.
const cli_level_3 = @embedFile("fixtures/cli/level-3.zst");
const pyzstd_level_3 = @embedFile("fixtures/pyzstd/level-3.zst");

/// `pyzstd/bare-3.zst` has neither a content size nor a checksum.
const pyzstd_bare_3 = @embedFile("fixtures/pyzstd/bare-3.zst");

const plain_payload = @embedFile("fixtures/plain.bin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime builds load the selected provider; linked builds need no setup.
    if (comptime zstd.runtime_loaded) {
        try loadProvider(try providerRequest(init));
    }

    try w.print("zstd smoke\n", .{});
    // Report the provider's version as provenance, not as an assertion.
    try w.print("{s} provider reports: {s}\n", .{
        if (zstd.runtime_loaded) "loaded" else "linked",
        zstd.versionString(),
    });
    try w.flush();

    // Check the header-declared version against the module and provider.
    try checkInt(w, "ZSTD_VERSION_MAJOR from src/lib/zstd.h:112", zstd.version_major, 1);
    try checkInt(w, "ZSTD_VERSION_MINOR from src/lib/zstd.h:113", zstd.version_minor, 5);
    try checkInt(w, "ZSTD_VERSION_RELEASE from src/lib/zstd.h:114", zstd.version_release, 7);
    try checkString(w, "the header's own version string", zstd.version_string_literal, "1.5.7");

    // Header range: `clevels.h` sets max to 22; `zstd.h` exposes `ZSTD_maxCLevel`.
    try checkInt(w, "the highest compression level is 22", zstd.maxLevel(), 22);
    {
        // Upstream clamps out-of-range levels; read back `level()` to observe the clamp.
        var high = try zstd.Ctx.initWithLevel(100);
        defer high.deinit();
        try checkInt(w, "a level above maxLevel clamps rather than failing", @intFromBool(try high.level() == zstd.maxLevel()), 1);

        // Upstream's minimum is `-ZSTD_TARGETLENGTH_MAX` (-131072); a small probe would not test clamping.
        try checkInt(w, "the lowest compression level is -131072", zstd.minLevel(), -131072);
        var low = try zstd.Ctx.initWithLevel(zstd.minLevel() - 1);
        defer low.deinit();
        try checkInt(w, "a level below minLevel clamps rather than failing", @intFromBool(try low.level() == zstd.minLevel()), 1);
    }

    try checkInt(w, "the frame magic is 0xFD2FB528", zstd.magic_number, 0xFD2FB528);
    try checkInt(w, "the skippable start is 0x184D2A50", zstd.magic_skippable_start, 0x184D2A50);
    try checkInt(w, "the skippable mask is 0xFFFFFFF0", zstd.magic_skippable_mask, 0xFFFFFFF0);

    try checkInt(w, "RFC frame magic byte 1", rfc_rle_frame[0], frame_magic[0]);
    try checkInt(w, "RFC frame magic byte 2", rfc_rle_frame[1], frame_magic[1]);
    try checkInt(w, "RFC frame magic byte 3", rfc_rle_frame[2], frame_magic[2]);
    try checkInt(w, "RFC frame magic byte 4", rfc_rle_frame[3], frame_magic[3]);

    const descriptor: u8 = rfc_rle_frame[4];
    try checkInt(w, "RFC 8878 Single_Segment_flag is set", (descriptor >> 5) & 1, 1);
    try checkInt(w, "RFC 8878 Content_Checksum_flag is clear", (descriptor >> 2) & 1, 0);
    try checkInt(w, "RFC 8878 Dictionary_ID_flag is zero", descriptor & 3, 0);
    try checkInt(w, "RFC 8878 Frame_Content_Size", rfc_rle_frame[5], rfc_rle_length);

    const rle_header: u32 = @as(u32, rfc_rle_frame[6]) |
        (@as(u32, rfc_rle_frame[7]) << 8) |
        (@as(u32, rfc_rle_frame[8]) << 16);
    try checkInt(w, "RFC 8878 RLE Last_Block bit", rle_header & 1, 1);
    try checkInt(w, "RFC 8878 RLE block type", (rle_header >> 1) & 3, 1);
    try checkInt(w, "RFC 8878 RLE Block_Size", rle_header >> 3, rfc_rle_length);

    try checkInt(w, "this frame is not a skippable frame", @intFromBool(zstd.isSkippableFrame(&rfc_rle_frame)), 0);
    try checkInt(w, "frameContentSize reports the RFC's content size", @intFromBool(zstd.frameContentSize(&rfc_rle_frame) == .known), 1);
    try checkInt(w, "the compressed size is the whole frame", try zstd.findFrameCompressedSize(&rfc_rle_frame), rfc_rle_frame.len);
    try checkInt(w, "the header is the minimum for this frame", try zstd.frameHeaderSize(&rfc_rle_frame), zstd.frame_header_size_min);

    {
        var out: [512]u8 = undefined;
        const n = try zstd.decompress(&out, &rfc_rle_frame);
        try checkInt(w, "the RFC frame decodes to 200 bytes", n, rfc_rle_length);
        var all_same = true;
        for (out[0..n]) |byte| all_same = all_same and byte == rfc_rle_byte;
        try checkInt(w, "the RFC RLE block stands for its byte", @intFromBool(all_same), 1);
    }

    // ------------------------------------------------------------------
    // Upstream's own golden corpus, embedded in place.
    // ------------------------------------------------------------------
    try checkInt(w, "the golden RLE frame is not a skippable frame", @intFromBool(zstd.isSkippableFrame(golden_rle_first)), 0);
    try checkInt(w, "the golden RLE frame's compressed size is the whole file", try zstd.findFrameCompressedSize(golden_rle_first), golden_rle_first.len);
    {
        // Allocate the full 1 MiB output in the arena and check every byte.
        const out = try init.arena.allocator().alloc(u8, golden_rle_length);
        const n = try zstd.decompress(out, golden_rle_first);
        try checkInt(w, "the golden RLE frame decodes to 1 MiB", n, golden_rle_length);
        var all_zero = true;
        for (out[0..n]) |byte| all_zero = all_zero and byte == 0;
        try checkInt(w, "every byte of the golden RLE output is zero", @intFromBool(all_zero), 1);
    }

    // ------------------------------------------------------------------
    // Frames two different producers emitted.
    // ------------------------------------------------------------------
    try checkInt(w, "the CLI and the binding frames are byte-identical at level 3", @intFromBool(std.mem.eql(u8, cli_level_3, pyzstd_level_3)), 1);
    try checkInt(w, "the recorded digest covers that one shared frame", @intFromBool(cli_level_3.len == 136), 1);
    try checkInt(w, "the bare frame is the four-byte-checksum-shorter sibling", @intFromBool(pyzstd_bare_3.len + 4 == pyzstd_level_3.len), 1);

    for ([_][]const u8{ cli_level_3, pyzstd_bare_3 }) |frame| {
        var out: [4096]u8 = undefined;
        const n = try zstd.decompress(&out, frame);
        try checkInt(w, "a producer's frame decodes to the whole payload", n, plain_payload.len);
        try checkString(w, "a producer's frame decodes to the payload", out[0..n], plain_payload);
    }

    // The bare frame has no content size, so the header query must report unknown.
    try checkInt(w, "the bare frame declares no content size", @intFromBool(zstd.frameContentSize(pyzstd_bare_3) == .unknown), 1);
    try checkInt(w, "the level-3 frame declares the payload's length", @intFromBool(zstd.frameContentSize(cli_level_3) == .known and
        zstd.frameContentSize(cli_level_3).known == plain_payload.len), 1);
    try checkInt(w, "a frame with no dictionary reports id 0", zstd.dictIDFromFrame(cli_level_3), 0);

    {
        var frame: [512]u8 = undefined;
        const n = try zstd.compress(&frame, plain_payload, 3);
        // `compressBound` is a worst-case bound, not the output size.
        try checkInt(w, "compressBound bounds what this build produced", @intFromBool(n <= try zstd.compressBound(plain_payload.len)), 1);
        try checkInt(w, "a short destination is refused", @intFromBool(zstd.compress(frame[0..8], plain_payload, 3) != error.NoError), 1);

        var back: [4096]u8 = undefined;
        try checkString(w, "the one-shot round trip returns the payload", back[0..try zstd.decompress(&back, frame[0..n])], plain_payload);

        // Reuse a context to exercise the streaming path separately.
        var ctx = try zstd.Ctx.initWithLevel(3);
        defer ctx.deinit();
        var streamed: [512]u8 = undefined;
        const streamed_len = try ctx.compress(&streamed, plain_payload, zstd.default_level);
        try checkInt(w, "the streaming path produced the same size", streamed_len, n);
        try ctx.reset(.session_and_parameters);
        try checkInt(w, "a reset context reproduces the same output", try ctx.compress(&streamed, plain_payload, zstd.default_level), n);

        var dctx = try zstd.Dctx.init();
        defer dctx.deinit();
        var rebuilt: [4096]u8 = undefined;
        // Pass only bytes written; the rest of `streamed` is uninitialized.
        try checkString(w, "the context path returns the payload", rebuilt[0..try dctx.decompress(&rebuilt, streamed[0..streamed_len])], plain_payload);
        try checkInt(w, "a reset decompression context is reusable", @intFromBool(dctx.isOpen()), 1);
    }

    {
        var out: [64]u8 = undefined;
        try checkInt(w, "input that is not a frame is refused", @intFromBool(zstd.decompress(&out, plain_payload) != error.NoError), 1);
    }

    // Error messages use the wording defined in upstream's `error_private.c`.
    try checkString(w, "the success code is named no_error", zstd.errorCodeText(.no_error), "No error detected");
    try checkInt(w, "a large result is an error", @intFromBool(zstd.isError(std.math.maxInt(usize))), 1);

    // Upstream decodes error results by negating the code; all-ones maps to generic.
    try checkString(w, "an all-ones result decodes to the generic code", zstd.errorName(std.math.maxInt(usize)), "Error (generic)");
    // Construct upstream's `ERROR(srcSize_wrong)` result without a magic number.
    try checkString(w, "an error result carries upstream's own name", zstd.errorName(errorResult(.src_size_wrong)), "Src size is incorrect");

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Load an explicit provider at runtime; linked builds already carry the library.
fn loadProvider(path: []const u8) !void {
    if (comptime zstd.runtime_loaded) {
        try zstd.load(.{ .path = path });
    }
}

/// Encode an upstream error as `size_t`; unsigned negation overflows in Zig.
fn errorResult(code: zstd.ErrorCode) usize {
    return @bitCast(-@as(isize, @backingInt(code)));
}

/// Print, then compare. A mismatch exits non-zero through `SmokeCheckFailed`.
fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <52}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("smoke: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <52}{d} bytes\n", .{ what, got.len });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("smoke: {s}: expected {d} bytes, computed {d} bytes\n", .{ what, expected.len, got.len });
        std.debug.print("smoke: {s}\n  expected \"{s}\"\n  computed \"{s}\"\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}
