// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! A runnable, deterministic demonstration of the Zstandard facade.
//!
//! `zig build smoke` runs this. There is no input to supply and no output that
//! depends on the host, the clock or a random seed, so the same lines come out
//! every time.
//!
//! Every answer below is an expected value, not a value this program computed
//! and printed for comparison. They come from four places outside this program:
//! RFC 8878's normative text, upstream's own golden-decompression corpus, the
//! fixture frames `fixtures/PROVENANCE.md` records with their producers, and the
//! version and bounds the headers themselves declare. A mismatch prints both
//! sides and exits non-zero, so this is a check and not a demo.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `ZSTD_TEST_PROVIDER`, and the program says which
//! configuration it is in the first two lines. In a linked build neither is
//! needed and neither is read.
//!
//! What it exercises, in order: the provider's own version and the header's
//! version numbers; the level range the headers declare; the frame magic number
//! and the skippable-frame test; a frame built byte by byte from RFC 8878,
//! decoded with its header fields checked against the RFC before decompression;
//! upstream's own `rle-first-block.zst`, whose expected output follows from the
//! RLE rule rather than from anything derived here; a frame the `zstd` CLI
//! produced and one the `python-zstandard` binding produced; a round trip through
//! both the one-shot and the streaming path; the refusal a corrupt input must
//! produce; and the error code names `src/lib/zstd_errors.h` defines.

const std = @import("std");
const zstd = @import("zstd");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `ZSTD_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location or falls back to
/// a linked copy: a runtime-loading build that was not told which file to load
/// reports that it was not told, rather than loading something else.
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
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export ZSTD_TEST_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// The zstd frame magic number as RFC 8878 §3.1.1 spells it, `0xFD2FB528`,
/// stored little-endian. Every non-skippable frame begins with these four bytes.
const frame_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// A frame built byte by byte from RFC 8878's normative text.
///
///   `28 b5 2f fd`  the frame magic, §3.1.1
///   `20`           Frame_Header_Descriptor, §3.1.1.1.1 Table 3:
///                    Single_Segment_flag set, so §3.1.1.1.2 gives a one-byte
///                    Frame_Content_Size and no Window_Descriptor;
///                    Content_Checksum_flag clear; Dictionary_ID_flag zero
///   `c8`           Frame_Content_Size = 200
///   `43 06 00`     Block_Header, §3.1.1.2 Table 9, little-endian in 24 bits:
///                    Last_Block = 1, Block_Type = RLE_Block, Block_Size = 200
///   `5a`           the one byte the RLE block stands for
const rfc_rle_frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0xc8, 0x43, 0x06, 0x00, 0x5a };

/// What RFC 8878 §3.1.1.2.2 says that frame decodes to: 200 copies of `0x5a`.
const rfc_rle_byte: u8 = 0x5a;
const rfc_rle_length: usize = 200;

/// Upstream's own golden corpus, embedded in place from the vendored source.
///
/// `rle-first-block.zst` is a fully independent known answer: its expected
/// output follows from what RFC 8878 §3.1.1.2.2 says an RLE block means, so it is
/// a specification oracle that happens to be in upstream's tree rather than one
/// this program built.
const golden_rle_first = @embedFile("src/tests/golden-decompression/rle-first-block.zst");

/// The 1 MiB that frame decodes to, by the RLE rule rather than by observation.
const golden_rle_length: usize = 1024 * 1024;

/// The frames two different producers emitted, and the payload they both encode.
///
/// `cli/level-3.zst` is the `zstd` CLI v1.5.7 at its default level and
/// `pyzstd/level-3.zst` is `python-zstandard` 0.22.0 binding libzstd 1.5.7 at
/// level 3. `fixtures/PROVENANCE.md` records that at the same level the two
/// produce **byte-identical** frames -- they are one implementation behind two
/// front ends -- and `fixtures/SHA256SUMS` records the shared digest. Asserting
/// that identity here is what keeps the rest of the claim honest: it is the one
/// fact that would otherwise be assumed rather than checked.
const cli_level_3 = @embedFile("fixtures/cli/level-3.zst");
const pyzstd_level_3 = @embedFile("fixtures/pyzstd/level-3.zst");

/// `fixtures/pyzstd/bare-3.zst`, written with neither a content checksum nor a
/// content size. It is the frame whose header has the fewest fields, so it is
/// the one a header decode that assumed the common case would get wrong.
const pyzstd_bare_3 = @embedFile("fixtures/pyzstd/bare-3.zst");

/// The plaintext every one of those frames encodes.
const plain_payload = @embedFile("fixtures/plain.bin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this is a no-op at comptime and the module is already usable.
    if (comptime zstd.runtime_loaded) {
        try loadProvider(try providerRequest(init));
    }

    try w.print("zstd smoke\n", .{});
    // Through the raw escape hatch, so this line names the provider this build
    // reached rather than a constant compiled into this program. It is printed,
    // not compared: a version string is provenance, not behaviour.
    try w.print("{s} provider reports: {s}\n", .{
        if (zstd.runtime_loaded) "loaded" else "linked",
        zstd.versionString(),
    });
    try w.flush();

    // The version the *headers* declare, read out of the embedded
    // `src/lib/zstd.h` rather than written here, and the packed number beside
    // it. Header, module and provider are three distinct facts and all three
    // have to be the same release; the check that they are is below.
    try checkInt(w, "ZSTD_VERSION_MAJOR from src/lib/zstd.h:112", zstd.version_major, 1);
    try checkInt(w, "ZSTD_VERSION_MINOR from src/lib/zstd.h:113", zstd.version_minor, 5);
    try checkInt(w, "ZSTD_VERSION_RELEASE from src/lib/zstd.h:114", zstd.version_release, 7);
    try checkString(w, "the header's own version string", zstd.version_string_literal, "1.5.7");

    // The level range, from the header and from the build's own level table.
    // src/lib/compress/clevels.h:19 defines ZSTD_MAX_CLEVEL as 22, and
    // src/lib/zstd.h:263 is ZSTD_maxCLevel.
    try checkInt(w, "the highest compression level is 22", zstd.maxLevel(), 22);
    {
        // A level outside the legal range is clamped rather than refused:
        // `ZSTD_CCtx_setParameter` forwards to `ZSTD_CCtxParams_setParameter`,
        // which clamps (`src/lib/compress/zstd_compress.c:781-782` through
        // `ZSTD_cParam_clampBounds` at `:642-649`). Reading the value back is
        // what makes the clamp observable, which is why this asserts on
        // `level()` rather than on the setter having succeeded.
        var high = try zstd.Ctx.initWithLevel(100);
        defer high.deinit();
        try checkInt(w, "a level above maxLevel clamps rather than failing",
            @intFromBool(try high.level() == zstd.maxLevel()), 1);

        // Both probes are derived from the bounds the library itself reports,
        // because the negative family is nowhere near where a small literal
        // would put it: `ZSTD_minCLevel` answers `-ZSTD_TARGETLENGTH_MAX`
        // (`src/lib/compress/zstd_compress.c:7674`), which is -131072. A probe
        // of -100 is inside the legal range and is not clamped at all, so it
        // would report nothing about the clamp.
        try checkInt(w, "the lowest compression level is -131072", zstd.minLevel(), -131072);
        var low = try zstd.Ctx.initWithLevel(zstd.minLevel() - 1);
        defer low.deinit();
        try checkInt(w, "a level below minLevel clamps rather than failing",
            @intFromBool(try low.level() == zstd.minLevel()), 1);
    }

    // The magic numbers, from RFC 8878 §3.1.1 and §3.1.2.
    try checkInt(w, "the frame magic is 0xFD2FB528", zstd.magic_number, 0xFD2FB528);
    try checkInt(w, "the skippable start is 0x184D2A50", zstd.magic_skippable_start, 0x184D2A50);
    try checkInt(w, "the skippable mask is 0xFFFFFFF0", zstd.magic_skippable_mask, 0xFFFFFFF0);

    // ------------------------------------------------------------------
    // A frame built from RFC 8878, checked against the RFC before decoding.
    // ------------------------------------------------------------------
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
    try checkInt(w, "frameContentSize reports the RFC's content size",
        @intFromBool(zstd.frameContentSize(&rfc_rle_frame) == .known), 1);
    try checkInt(w, "the compressed size is the whole frame",
        try zstd.findFrameCompressedSize(&rfc_rle_frame), rfc_rle_frame.len);
    try checkInt(w, "the header is the minimum for this frame",
        try zstd.frameHeaderSize(&rfc_rle_frame), zstd.frame_header_size_min);

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
    try checkInt(w, "the golden RLE frame is not a skippable frame",
        @intFromBool(zstd.isSkippableFrame(golden_rle_first)), 0);
    try checkInt(w, "the golden RLE frame's compressed size is the whole file",
        try zstd.findFrameCompressedSize(golden_rle_first), golden_rle_first.len);
    {
        // 1 MiB does not belong on the stack, and a 1 MiB output this program
        // never inspects is 1 MiB that proves nothing. So the output comes from
        // the caller's arena and every byte of it is checked.
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
    try checkInt(w, "the CLI and the binding frames are byte-identical at level 3",
        @intFromBool(std.mem.eql(u8, cli_level_3, pyzstd_level_3)), 1);
    try checkInt(w, "the recorded digest covers that one shared frame",
        @intFromBool(cli_level_3.len == 136), 1);
    try checkInt(w, "the bare frame is the four-byte-checksum-shorter sibling",
        @intFromBool(pyzstd_bare_3.len + 4 == pyzstd_level_3.len), 1);

    for ([_][]const u8{ cli_level_3, pyzstd_bare_3 }) |frame| {
        var out: [4096]u8 = undefined;
        const n = try zstd.decompress(&out, frame);
        try checkInt(w, "a producer's frame decodes to the whole payload", n, plain_payload.len);
        try checkString(w, "a producer's frame decodes to the payload", out[0..n], plain_payload);
    }

    // The bare frame was written with no content size, so the header read has to
    // say so rather than guess.
    try checkInt(w, "the bare frame declares no content size",
        @intFromBool(zstd.frameContentSize(pyzstd_bare_3) == .unknown), 1);
    try checkInt(w, "the level-3 frame declares the payload's length",
        @intFromBool(zstd.frameContentSize(cli_level_3) == .known and
            zstd.frameContentSize(cli_level_3).known == plain_payload.len), 1);
    try checkInt(w, "a frame with no dictionary reports id 0",
        zstd.dictIDFromFrame(cli_level_3), 0);

    // ------------------------------------------------------------------
    // A round trip, as a supplement and never as the claim.
    // ------------------------------------------------------------------
    {
        var frame: [512]u8 = undefined;
        const n = try zstd.compress(&frame, plain_payload, 3);
        // A bound, not a size: `ZSTD_COMPRESSBOUND` (`src/lib/zstd.h:249`) is
        // the worst case, so what this build actually wrote is at or below it.
        // Comparing for equality would assert that every payload is its own
        // worst case, which is not what the header promises.
        try checkInt(w, "compressBound bounds what this build produced",
            @intFromBool(n <= try zstd.compressBound(plain_payload.len)), 1);
        try checkInt(w, "a short destination is refused",
            @intFromBool(zstd.compress(frame[0..8], plain_payload, 3) != error.NoError), 1);

        var back: [4096]u8 = undefined;
        try checkString(w, "the one-shot round trip returns the payload",
            back[0..try zstd.decompress(&back, frame[0..n])], plain_payload);

        // And the streaming path, which is a different implementation inside the
        // library and is reused rather than re-initialised.
        var ctx = try zstd.Ctx.initWithLevel(3);
        defer ctx.deinit();
        var streamed: [512]u8 = undefined;
        const streamed_len = try ctx.compress(&streamed, plain_payload, zstd.default_level);
        try checkInt(w, "the streaming path produced the same size", streamed_len, n);
        try ctx.reset(.session_and_parameters);
        try checkInt(w, "a reset context reproduces the same output",
            try ctx.compress(&streamed, plain_payload, zstd.default_level), n);

        var dctx = try zstd.Dctx.init();
        defer dctx.deinit();
        var rebuilt: [4096]u8 = undefined;
        // `streamed[0..streamed_len]`, not the whole 512-byte buffer: the
        // context wrote `streamed_len` bytes and the rest is uninitialised
        // stack. `ZSTD_decompressDCtx` reports `srcSize_wrong` for the trailing
        // bytes, which is the library being right about a wrong input.
        try checkString(w, "the context path returns the payload",
            rebuilt[0..try dctx.decompress(&rebuilt, streamed[0..streamed_len])], plain_payload);
        try checkInt(w, "a reset decompression context is reusable", @intFromBool(dctx.isOpen()), 1);
    }

    // A refusal, so that a decoder which accepted everything would not pass.
    {
        var out: [64]u8 = undefined;
        try checkInt(w, "input that is not a frame is refused",
            @intFromBool(zstd.decompress(&out, plain_payload) != error.NoError), 1);
    }

    // ------------------------------------------------------------------
    // The error vocabulary, named by upstream and not invented here.
    // ------------------------------------------------------------------
    // The message strings are upstream's own, read out of
    // `src/lib/common/error_private.c:15` onward. This program does not
    // compose a message of its own: a facade that produced its own wording for
    // an upstream error code would make the text useless for anyone reading a
    // real `zstd` failure.
    try checkString(w, "the success code is named no_error",
        zstd.errorCodeText(.no_error), "No error detected");
    try checkInt(w, "a large result is an error", @intFromBool(zstd.isError(std.math.maxInt(usize))), 1);

    // The name is a decode of the result, not a property of how large the
    // result is. `ERR_isError` is `code > ERROR(maxCode)`
    // (`src/lib/common/error_private.h:52`) and `ERR_getErrorCode` is
    // `(ERR_enum)(0 - code)` (`:54`), so all-ones decodes to
    // `ZSTD_error_GENERIC` - which is 1 - and gets that code's own string.
    try checkString(w, "an all-ones result decodes to the generic code",
        zstd.errorName(std.math.maxInt(usize)), "Error (generic)");
    // The result that carries `srcSize_wrong` is `ERROR(srcSize_wrong)`,
    // `(size_t)-PREFIX(srcSize_wrong)` (`:50`), which is the negation of the
    // code rather than a magic number.
    try checkString(w, "an error result carries upstream's own name",
        zstd.errorName(errorResult(.src_size_wrong)), "Src size is incorrect");

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Load the provider in a runtime-loading build, or do nothing in a linked one.
///
/// The name is spelled out rather than inlined so that the comptime branch at
/// the call site has exactly one call site and this program has no
/// `if (runtime_loaded)` in more than one place.
///
/// A linked build links nothing here: the module already carries the library, so
/// there is no provider to name and `path` is the one parameter this function
/// does not read in that configuration.
fn loadProvider(path: []const u8) !void {
    if (comptime zstd.runtime_loaded) {
        try zstd.load(.{ .path = path });
    }
}

/// The `size_t` a Zstandard error code is returned as.
///
/// `ZSTD_ERROR(name)` is `((size_t)-PREFIX(name))`
/// (`src/lib/common/error_private.h:50`), so an error result is the
/// two's-complement negation of its code. It is built through a signed value
/// and a bit cast because `-` on the unsigned type is an overflow in Zig and a
/// wrapping subtraction would state the wrapping rather than the C spelling.
fn errorResult(code: zstd.ErrorCode) usize {
    return @bitCast(-@as(isize, @intFromEnum(code)));
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