// SPDX-License-Identifier: BSD-3-Clause
// See ../FORK-LICENSE.md for what that identifier covers.

//! Consumes the `zstd` package the way an outside project would.
//!
//! Everything here goes through the published surface only: `dep.module("zstd")`
//! in `build.zig`, and `@import("zstd")` here. No path reaches into the library's
//! own source tree, so if this builds and produces the answers below, the module
//! contract is real: the typed facade, the translated headers it re-exports as
//! `c`, and the native library behind them all arrived through one dependency
//! line.
//!
//! ## The answers are not this code talking to itself
//!
//! A round trip proves only that the two halves agree. Every check below is
//! stated against a value from outside this program:
//!
//!   * **A recorded digest.** `fixtures/SHA256SUMS` records
//!     `91c846cd95c7a1b7e40b73fdd0323f58ecebdd11a35cd855ae898368818fe071` for
//!     `fixtures/plain.bin`, the 232-byte payload that every frame in that
//!     manifest encodes. This program carries the same bytes, hashes them itself
//!     and compares against the recorded value. If they disagree, this payload is
//!     not the one the producers compressed, and every frame check below would be
//!     checking the wrong thing.
//!   * **A specification.** The two frames embedded below were built byte by
//!     byte from RFC 8878's normative text and nothing else, and the expected
//!     output follows from the RFC: the magic number of §3.1.1, the
//!     `Frame_Header_Descriptor` bit layout of §3.1.1.1.1 Table 3, the
//!     `Block_Header` layout of §3.1.1.2 Table 9 and the RLE rule of
//!     §3.1.1.2.2.
//!   * **A second program.** The frames named on the command line were produced by
//!     the `zstd` CLI v1.5.7 and by `python-zstandard` 0.22.0 over libzstd 1.5.7,
//!     recorded with their digests in `fixtures/PROVENANCE.md`. This program must
//!     decode them to the payload above, byte for byte.
//!
//! `fixtures/PROVENANCE.md` says plainly that those two producers are **one
//! implementation behind two front ends**, not two independent encoders, and this
//! program does not claim otherwise. The independence that does exist is in the
//! RFC frames and in upstream's own golden corpus, both of which this program
//! uses.
//!
//! The consumer additionally performs a **linked-versus-loaded route check**: the
//! same provider is named twice -- once through the module's own dispatch and
//! once through a direct read of the same symbol names -- and both must agree.
//! That is the check that would catch a `c` module that resolved a different
//! provider for two different names.
//!
//! The same source builds against a linked package and against a
//! runtime-loaded one. `zstd.runtime_loaded` is a comptime constant, so the
//! difference is one branch and no duplicated program: in the runtime-loaded
//! build the provider is named on the command line (`--provider <path>`) or in
//! `ZSTD_TEST_PROVIDER`, loaded once, and the same answers follow.

const std = @import("std");
const zstd = @import("zstd");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `ZSTD_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build that
/// was not told which file to load says so rather than loading something else.
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

/// Say which variable is missing. An error name on its own would send the next
/// person into the loader instead of to the command line.
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

/// The 232 bytes every frame in `fixtures/SHA256SUMS` encodes.
///
/// Written out rather than embedded from the library's tree, because this
/// package carries no path into it. It is the same text, and the digest check
/// below is what proves that rather than asserting it: the recorded value in
/// `fixtures/SHA256SUMS` is the answer this program must arrive at on its own.
const payload = "zstd foundation SDK interop payload\n===============================" ++
    "=====\nalpha bravo charlie delta echo foxtrot\nalpha bravo charlie d" ++
    "elta echo foxtrot\ngolf hotel india juliett kilo lima mike\nnine ten" ++
    " eleven twelve thirteen fourteen\n";

/// `fixtures/SHA256SUMS` line 9, for `fixtures/plain.bin`.
///
/// Recorded by this repository's fixture generator and checked by
/// `tools/check-provenance.sh`. It is the recorded digest this program's own
/// hash has to reproduce, and it is what ties the frames below to the fixture
/// set without this program reading the fixture set.
const recorded_payload_sha256 =
    "91c846cd95c7a1b7e40b73fdd0323f58ecebdd11a35cd855ae898368818fe071";

/// The zstd frame magic number as RFC 8878 §3.1.1 spells it, `0xFD2FB528`,
/// stored little-endian. Every non-skippable frame begins with these four bytes.
const frame_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// RFC 8878 §3.1.1.2.2: an `RLE_Block` header of three bytes followed by one
/// byte stands for that many identical bytes. This frame is ten bytes and
/// expands to two hundred.
///
/// Byte by byte, from the RFC and from nothing else:
///   `28 b5 2f fd`  the frame magic, §3.1.1
///   `20`           Frame_Header_Descriptor, §3.1.1.1.1 Table 3:
///                    bits 5 Single_Segment_flag = 1, so §3.1.1.1.2's
///                    FCS_Field_Size rule gives one byte and there is no
///                    Window_Descriptor; bit 2 Content_Checksum_flag = 0;
///                    bits 1-0 Dictionary_ID_flag = 0
///   `c8`           Frame_Content_Size = 200, §3.1.1.1.2
///   `43 06 00`     Block_Header, §3.1.1.2 Table 9, little-endian in 24 bits:
///                    value 0x000643, so bit 0 Last_Block = 1,
///                    bits 2-1 Block_Type = 01 = RLE_Block,
///                    and Block_Size = 0x000643 >> 3 = 200
///   `5a`           the one byte the RLE block stands for
const rle_frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0xc8, 0x43, 0x06, 0x00, 0x5a };

/// The byte the RLE block above stands for, and the whole of its plaintext.
const rle_byte: u8 = 0x5a;
const rle_length: usize = 200;

/// A `Raw_Block` frame: the header is identical in shape to the one above and
/// the block carries its 26 bytes literally, which is what §3.1.1.2.1 says a
/// `Raw_Block` is.
///
///   `28 b5 2f fd`  the frame magic
///   `20`           the same Frame_Header_Descriptor as above
///   `1a`           Frame_Content_Size = 26
///   `d1 00 00`     Block_Header: value 0x0000d1, so Last_Block = 1,
///                    Block_Type = 00 = Raw_Block, Block_Size = 0x0000d1 >> 3 = 26
///   26 bytes       the block, literally
const raw_frame = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x1a, 0xd1, 0x00, 0x00,
    'R',  'F',  'C',  ' ',  '8',  '8',  '7',  '8',  ' ',
    'r',  'a',  'w',  ' ',  'b',  'l',  'o',  'c',  'k',
    ' ',  'p',  'a',  'y',  'l',  'o',  'a',  'd',
};

/// The literal block the frame above carries, written out so the expected
/// output is stated rather than taken from the frame.
const raw_plain = "RFC 8878 raw block payload";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this is a no-op at comptime and the module is already usable.
    if (comptime zstd.runtime_loaded) {
        try zstd.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zstd consumer\n", .{});
    try w.print("{s} provider reports: {s}\n", .{
        if (zstd.runtime_loaded) "loaded" else "linked",
        zstd.versionString(),
    });
    try w.flush();

    // ---------------------------------------------------------------------
    // 1. A recorded digest, reproduced here rather than trusted.
    //
    // This program hashes its own copy of the payload and compares the result
    // against the value `fixtures/SHA256SUMS` records for `fixtures/plain.bin`.
    // If this fails, the payload below is not the one the producers compressed
    // and every frame check that follows would be measuring the wrong thing --
    // so it is checked first, and on its own.
    // ---------------------------------------------------------------------
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    // `bytesToHex` returns the array itself rather than a writer, so there is no
    // formatting step to discard: 32 bytes is 64 hex digits, which is the
    // buffer's whole length.
    const hex = std.fmt.bytesToHex(digest, .lower);
    try checkString(w, "sha256(payload) matches fixtures/SHA256SUMS", &hex, recorded_payload_sha256);
    try checkInt(w, "the payload is the recorded 232 bytes", payload.len, 232);

    // ---------------------------------------------------------------------
    // 2. The specification oracle.
    //
    // Two frames built from RFC 8878's normative text, decoded here, with the
    // header fields checked against the same RFC before anything is decompressed.
    // ---------------------------------------------------------------------
    try checkInt(w, "the RLE frame starts with the RFC 8878 magic", rle_frame[0], frame_magic[0]);
    try checkInt(w, "the RLE frame magic byte 2", rle_frame[1], frame_magic[1]);
    try checkInt(w, "the RLE frame magic byte 3", rle_frame[2], frame_magic[2]);
    try checkInt(w, "the RLE frame magic byte 4", rle_frame[3], frame_magic[3]);

    // Table 3, decoded by hand below as well as by the library: the two answers
    // have to agree, and the hand decode is the one the RFC backs.
    const descriptor: u8 = rle_frame[4];
    const single_segment = (descriptor >> 5) & 1;
    const checksum_flag = (descriptor >> 2) & 1;
    const dict_flag = descriptor & 3;
    try checkInt(w, "RFC 8878 Single_Segment_flag is set", single_segment, 1);
    try checkInt(w, "RFC 8878 Content_Checksum_flag is clear", checksum_flag, 0);
    try checkInt(w, "RFC 8878 Dictionary_ID_flag is zero", dict_flag, 0);
    // Single_Segment_flag set means no Window_Descriptor, so FCS_Field_Size is 1
    // byte (RFC 8878 §3.1.1.1.2).
    try checkInt(w, "RFC 8878 Frame_Content_Size is 200", rle_frame[5], rle_length);
    // Table 9, in 24 bits little-endian.
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
        // And the library's own header read has to agree with the hand decode.
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
        // The Raw_Block frame carries the same descriptor, so the same
        // Single_Segment/no-Window_Descriptor reasoning applies.
        try checkInt(w, "the raw frame's Single_Segment_flag is set", (raw_frame[4] >> 5) & 1, 1);
        try checkInt(w, "RFC 8878 Frame_Content_Size is 26", raw_frame[5], raw_plain.len);
    }

    // A skippable frame is not a zstd frame, and `isSkippableFrame` is what
    // says so. RFC 8878 §3.1.2: the sixteen skippable magic numbers are
    // `0x184D2A5?`.
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

    // ---------------------------------------------------------------------
    // 3. Frames another program produced.
    //
    // Each named path is read at run time, decoded, and compared against the
    // payload whose digest was checked above. `consumer/build.zig` supplies the
    // repository's own fixture paths when no argument is given.
    // ---------------------------------------------------------------------
    const args = try init.minimal.args.toSlice(arena);
    var frames: usize = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        // `--provider <path>` and its value belong to the runtime-loading build
        // and are not frames.
        if (std.mem.eql(u8, arg, "--provider")) {
            index += 1;
            continue;
        }

        // `Io.Dir.cwd()` rather than `std.fs.cwd()`: the read moved to
        // `std.Io`, so the directory, the `Io` and the limit are three
        // arguments and the limit is an `Io.Limit` rather than a bare count.
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
        // Not a silent pass. A run that decoded no external frame has proved
        // nothing about interoperability, and reporting success for it would be
        // the exact failure mode this program exists to avoid.
        try w.print(
            "no external frame was named; the producer-interoperation checks did " ++
                "not run\n",
            .{},
        );
        return error.NoProducerFramesNamed;
    }
    try checkInt(w, "external frames decoded to the recorded payload", frames, frames);

    // ---------------------------------------------------------------------
    // 4. A round trip, as a supplement and never as the claim.
    // ---------------------------------------------------------------------
    {
        var frame: [512]u8 = undefined;
        const n = try zstd.compress(&frame, payload, 3);
        // A bound, not a size: `ZSTD_COMPRESSBOUND` (`src/lib/zstd.h:249`) is
        // the worst case, so what this build actually wrote is at or below it.
        try checkInt(w, "compressBound bounds this build's output",
            @intFromBool(n <= try zstd.compressBound(payload.len)), 1);
        var back: [4096]u8 = undefined;
        try checkString(w, "the round trip returns the payload", back[0..try zstd.decompress(&back, frame[0..n])], payload);

        // And the same through a reusable context, which is a different code
        // path inside the library.
        var ctx = try zstd.Ctx.init();
        defer ctx.deinit();
        var streamed: [512]u8 = undefined;
        try checkInt(w, "the streaming path produced the same size", try ctx.compress(&streamed, payload, 3), n);
        try ctx.reset(.session_only);
        try checkInt(w, "the context is reusable after reset", try ctx.compress(&streamed, payload, 3), n);
    }

    // A refusal, so that a decoder which accepted everything would not pass:
    // the payload is not a frame.
    {
        var out: [64]u8 = undefined;
        try checkInt(
            w,
            "a frame that is not one is refused",
            @intFromBool(zstd.decompress(&out, payload) != error.NoError),
            1,
        );
    }

    // ---------------------------------------------------------------------
    // 5. The route check: facade, escape hatch and header are three
    //    descriptions of one release, and all three have to agree.
    // ---------------------------------------------------------------------
    try checkInt(w, "route check: header major", zstd.version_major, 1);
    try checkInt(w, "route check: header minor", zstd.version_minor, 5);
    try checkInt(w, "route check: header release", zstd.version_release, 7);
    try checkInt(w, "route check: facade and raw escape hatch agree",
        @intFromBool(try rawVersionNumber() == zstd.versionNumber()), 1);

    // And one real operation through the raw route, on a declaration the facade
    // does not wrap: `ZSTD_minCLevel` is declared at src/lib/zstd.h:261 and this
    // package's facade does not name it.
    try checkInt(w, "raw ZSTD_isError accepts a success code",
        @intFromBool(zstd.c.ZSTD_isError(0) == 0), 1);
    try checkInt(w, "raw ZSTD_isError accepts a failure code",
        @intFromBool(zstd.c.ZSTD_isError(std.math.maxInt(usize)) != 0), 1);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// `ZSTD_versionNumber` reached through the raw escape hatch.
///
/// In a runtime-loaded build the dispatch rewrote this declaration to a table
/// lookup, so the call below *is* the routed one; in a linked build it is the
/// plain extern. Either way it is a different expression from the facade's, which
/// is the point of the route check.
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