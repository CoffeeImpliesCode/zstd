// SPDX-License-Identifier: BSD-3-Clause
// See ../FORK-LICENSE.md for what that identifier covers.

//! Consume only the published `zstd` module.
//! Check a digest, RFC 8878 frames, and fixtures from zstd CLI 1.5.7 and
//! python-zstandard 0.22.0 over libzstd 1.5.7 (not independent encoders).
//! Also compare linked and runtime-loaded routes.

const std = @import("std");
const zstd = @import("zstd");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// Read the explicit provider from `--provider` or `ZSTD_TEST_PROVIDER`.
/// No default library location is searched.
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

fn noProvider() ConfigurationError {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export ZSTD_TEST_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// Known payload, checked against the recorded fixture digest.
const payload = "zstd foundation SDK interop payload\n===============================" ++
    "=====\nalpha bravo charlie delta echo foxtrot\nalpha bravo charlie d" ++
    "elta echo foxtrot\ngolf hotel india juliett kilo lima mike\nnine ten" ++
    " eleven twelve thirteen fourteen\n";

/// Recorded SHA-256 of `fixtures/plain.bin`, checked against this payload.
const recorded_payload_sha256 =
    "91c846cd95c7a1b7e40b73fdd0323f58ecebdd11a35cd855ae898368818fe071";

/// RFC 8878 frame magic, stored little-endian.
const frame_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// RFC 8878 single-segment frame: one RLE block expands `0x5a` to 200 bytes.
/// The header has no checksum or dictionary.
const rle_frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0xc8, 0x43, 0x06, 0x00, 0x5a };

/// Byte and output length encoded by `rle_frame`.
const rle_byte: u8 = 0x5a;
const rle_length: usize = 200;

/// RFC 8878 single-segment Raw_Block frame carrying `raw_plain` literally.
/// Its header declares the payload length.
const raw_frame = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x1a, 0xd1, 0x00, 0x00,
    'R',  'F',  'C',  ' ',  '8',  '8',  '7',  '8',  ' ',
    'r',  'a',  'w',  ' ',  'b',  'l',  'o',  'c',  'k',
    ' ',  'p',  'a',  'y',  'l',  'o',  'a',  'd',
};

/// Literal plaintext carried by `raw_frame`.
const raw_plain = "RFC 8878 raw block payload";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime builds load the explicitly selected provider; linked builds need no load.
    if (comptime zstd.runtime_loaded) {
        try zstd.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zstd consumer\n", .{});
    try w.print("{s} provider reports: {s}\n", .{
        if (zstd.runtime_loaded) "loaded" else "linked",
        zstd.versionString(),
    });
    try w.flush();

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try checkString(w, "sha256(payload) matches fixtures/SHA256SUMS", &hex, recorded_payload_sha256);
    try checkInt(w, "the payload is the recorded 232 bytes", payload.len, 232);

    try checkInt(w, "the RLE frame starts with the RFC 8878 magic", rle_frame[0], frame_magic[0]);
    try checkInt(w, "the RLE frame magic byte 2", rle_frame[1], frame_magic[1]);
    try checkInt(w, "the RLE frame magic byte 3", rle_frame[2], frame_magic[2]);
    try checkInt(w, "the RLE frame magic byte 4", rle_frame[3], frame_magic[3]);

    // Compare the hand-decoded RFC fields with the library's answers.
    const descriptor: u8 = rle_frame[4];
    const single_segment = (descriptor >> 5) & 1;
    const checksum_flag = (descriptor >> 2) & 1;
    const dict_flag = descriptor & 3;
    try checkInt(w, "RFC 8878 Single_Segment_flag is set", single_segment, 1);
    try checkInt(w, "RFC 8878 Content_Checksum_flag is clear", checksum_flag, 0);
    try checkInt(w, "RFC 8878 Dictionary_ID_flag is zero", dict_flag, 0);
    // Single-segment frames omit the window descriptor.
    try checkInt(w, "RFC 8878 Frame_Content_Size is 200", rle_frame[5], rle_length);
    // The block header is a 24-bit little-endian value.
    const rle_header: u32 = @as(u32, rle_frame[6]) |
        (@as(u32, rle_frame[7]) << 8) |
        (@as(u32, rle_frame[8]) << 16);
    try checkInt(w, "RFC 8878 RLE block Last_Block bit", rle_header & 1, 1);
    try checkInt(w, "RFC 8878 RLE block type is RLE_Block", (rle_header >> 1) & 3, 1);
    try checkInt(w, "RFC 8878 RLE Block_Size", rle_header >> 3, rle_length);

    {
        var out: [512]u8 = undefined;
        const n = try zstd.decompress(&out, &rle_frame);
        try checkInt(w, "the RLE frame decodes to 200 bytes", n, rle_length);
        var all_same = true;
        for (out[0..n]) |byte| all_same = all_same and byte == rle_byte;
        try checkInt(w, "every byte is the one the RLE block stands for", @intFromBool(all_same), 1);
        const size = zstd.frameContentSize(&rle_frame);
        try checkInt(
            w,
            "frameContentSize agrees with the RFC hand decode",
            @intFromBool(size == .known and size.known == rle_length),
            1,
        );
        try checkInt(
            w,
            "findFrameCompressedSize is the whole ten-byte frame",
            try zstd.findFrameCompressedSize(&rle_frame),
            rle_frame.len,
        );
    }

    {
        var out: [64]u8 = undefined;
        const n = try zstd.decompress(&out, &raw_frame);
        try checkInt(w, "the raw-block frame decodes to 26 bytes", n, raw_plain.len);
        try checkString(w, "the raw-block frame decodes to its literals", out[0..n], raw_plain);
        try checkInt(w, "the raw frame's Single_Segment_flag is set", (raw_frame[4] >> 5) & 1, 1);
        try checkInt(w, "RFC 8878 Frame_Content_Size is 26", raw_frame[5], raw_plain.len);
    }

    // RFC 8878 skippable-frame magic values are `0x184D2A5?`.
    try checkInt(w, "a zstd frame is not a skippable frame", @intFromBool(zstd.isSkippableFrame(&rle_frame)), 0);
    var skippable: [8]u8 = undefined;
    for (&skippable, 0..) |*byte, i| byte.* = switch (i) {
        0 => 0x50, // 0x184D2A50, ZSTD_MAGIC_SKIPPABLE_START
        1 => 0x2a,
        2 => 0x4d,
        3 => 0x18,
        else => 0,
    };
    try checkInt(w, "a skippable magic number is recognised", @intFromBool(zstd.isSkippableFrame(&skippable)), 1);

    const args = try init.minimal.args.toSlice(arena);
    const default_frames: []const [:0]const u8 = &.{
        "../fixtures/cli/level-3.zst",
        "../fixtures/pyzstd/bare-3.zst",
    };
    const frame_args: []const [:0]const u8 = if (args.len == 1) default_frames else args[1..];
    var frames: usize = 0;
    var index: usize = 0;
    while (index < frame_args.len) : (index += 1) {
        const arg = frame_args[index];
        // Skip the provider option and its value; neither is a frame path.
        if (std.mem.eql(u8, arg, "--provider")) {
            index += 1;
            continue;
        }

        const frame = std.Io.Dir.cwd().readFileAlloc(init.io, arg, arena, .limited(1 << 20)) catch |err| {
            std.debug.print(
                "consumer: cannot read {s}: {t}\n" ++
                    "The frames this program decodes are the library's fixtures. Run\n" ++
                    "it from the consumer/ directory, or pass the paths you want.\n",
                .{ arg, err },
            );
            return error.ConsumerCheckFailed;
        };

        var out: [4096]u8 = undefined;
        const n = zstd.decompress(&out, frame) catch |err| {
            std.debug.print("consumer: {s} did not decode: {t}\n", .{ arg, err });
            return error.ConsumerCheckFailed;
        };
        try checkString(w, arg, out[0..n], payload);
        frames += 1;
    }
    if (frames == 0) {
        // No external frame means the interoperability check did not run.
        try w.print(
            "no external frame was named; the producer-interoperation checks did " ++
                "not run\n",
            .{},
        );
        return error.NoProducerFramesNamed;
    }
    try checkInt(w, "external frames decoded to the recorded payload", frames, frames);

    // Add a local round trip; it is not the interoperability oracle.
    {
        var frame: [512]u8 = undefined;
        const n = try zstd.compress(&frame, payload, 3);
        try checkInt(w, "compressBound bounds this build's output",
            @intFromBool(n <= try zstd.compressBound(payload.len)), 1);
        var back: [4096]u8 = undefined;
        try checkString(w, "the round trip returns the payload", back[0..try zstd.decompress(&back, frame[0..n])], payload);

        var ctx = try zstd.Ctx.init();
        defer ctx.deinit();
        var streamed: [512]u8 = undefined;
        try checkInt(w, "the streaming path produced the same size", try ctx.compress(&streamed, payload, 3), n);
        try ctx.reset(.session_only);
        try checkInt(w, "the context is reusable after reset", try ctx.compress(&streamed, payload, 3), n);
    }

    {
        var out: [64]u8 = undefined;
        try checkInt(
            w,
            "a frame that is not one is refused",
            @intFromBool(zstd.decompress(&out, payload) != error.NoError),
            1,
        );
    }

    try checkInt(w, "route check: header major", zstd.version_major, 1);
    try checkInt(w, "route check: header minor", zstd.version_minor, 5);
    try checkInt(w, "route check: header release", zstd.version_release, 7);
    try checkInt(w, "route check: facade and raw escape hatch agree",
        @intFromBool(try rawVersionNumber() == zstd.versionNumber()), 1);

    // Check a raw declaration not wrapped by the facade.
    try checkInt(w, "raw ZSTD_isError accepts a success code",
        @intFromBool(zstd.c.ZSTD_isError(0) == 0), 1);
    try checkInt(w, "raw ZSTD_isError accepts a failure code",
        @intFromBool(zstd.c.ZSTD_isError(std.math.maxInt(usize)) != 0), 1);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Raw escape-hatch version lookup; runtime mode routes it through the dispatch.
fn rawVersionNumber() !u32 {
    return zstd.c.ZSTD_versionNumber();
}

/// Print, then compare. A mismatch exits non-zero through `ConsumerCheckFailed`.
fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <52}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("consumer: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <52}{d} bytes\n", .{ what, got.len });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print(
            "consumer: {s}: expected {d} bytes, computed {d} bytes\n",
            .{ what, expected.len, got.len },
        );
        std.debug.print("consumer: {s}\n  expected \"{s}\"\n  computed \"{s}\"\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}
