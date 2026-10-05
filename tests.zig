// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioural tests for the Zstandard facade.
//!
//! Nothing here pins a version, an export list or a default, and no test's
//! expected value was produced by the code under test. Every expectation is one
//! of three things, and the tests are grouped so that a reader can tell which is
//! which without being told:
//!
//! ## 1. RFC 8878, derived from the specification
//!
//! The frames under `fixtures/rfc8878/` were built byte by byte from RFC 8878's
//! normative text and nothing else: the magic number of §3.1.1, the
//! Frame_Header_Descriptor bit layout of §3.1.1.1.1 Table 3, the Window_Descriptor
//! rule of §3.1.1.1.2, the Block_Header layout of §3.1.1.2 Table 9, the RLE_Block
//! rule of §3.1.1.2.2 and the skippable-frame layout of §3.1.2. The expected
//! plaintext is therefore derived from the standard rather than from libzstd.
//!
//! So that the derivation is visible and not merely asserted, the first group
//! below carries this file's **own** decoder for those fields -
//! `decodeDescriptor`, `frameHeaderSizeFromRfc`, `fcsFieldSize`, `didFieldSize`
//! and `decodeBlockHeader` - and checks it against inline literals. Those
//! functions read the specification's rules and nothing else: no zstd function
//! is involved. The library is then asked the same questions through
//! `frameHeaderSize`, `frameContentSize` and `findFrameCompressedSize`, and the
//! two answers have to agree.
//!
//! ## 2. Upstream's own golden corpus
//!
//! The frames under `src/tests/golden-decompression/` are embedded in place,
//! from this repository's own vendored copy, and are not copied anywhere. They
//! are real frames produced by other implementations and shipped by upstream.
//!
//! `rle-first-block.zst` is a fully independent known answer: its expected
//! output - 1 MiB of `0x00` - follows from eight RLE blocks of 131072 bytes
//! each, which is what RFC 8878 §3.1.1.2.2 says an RLE block means, and the
//! header fields it is checked against follow from Tables 3 and 9 in the same
//! way the RFC 8878 fixtures do.
//!
//! The other three carry two different kinds of expectation and are labelled:
//! their **header** fields are derived from the specification the same way, and
//! their **decoded output** is an inline byte array that this file states is the
//! output recorded from the system `zstd` CLI v1.5.7, not something derived here.
//! A reader who wants the distinction can see it in the comments.
//!
//! `src/tests/golden-decompression-errors/` is the third kind: frames upstream
//! ships and labels invalid, so the expected answer is an error rather than an
//! oracle. `zeroSeq_extraneous.zst` is the one with a code this file can predict
//! from the source, and `zstd_decompress_block.c:723-724` is what it predicts it
//! from.
//!
//! ## 3. Upstream-interop frames, and what they are honestly worth
//!
//! `fixtures/cli/*.zst` and `fixtures/pyzstd/*.zst` decode to
//! `fixtures/plain.bin`. **These are one implementation behind two producers,
//! not two independent encoders**: at the same level the CLI and the
//! python-`zstandard` binding emit byte-identical frames, and
//! `fixtures/PROVENANCE.md` records the digests that prove it. One test here
//! asserts that byte-identity directly, because it is the fact that keeps the
//! rest of the claim honest.
//!
//! ## 4. Behavioural boundaries
//!
//! Bounds, refusal, truncation, clamping, and the ownership transition this
//! module owns. Round trips appear throughout, and they supplement the oracles
//! above rather than replacing them: no test below exists only to show that
//! something this SDK compressed can be decompressed again.
//!
//! ## The allocator
//!
//! Zstandard allocates through libc's `malloc`, `calloc` and `free`, reached
//! through `ZSTD_defaultCMem` (`src/lib/common/zstd_deps.h:64-68`), not through
//! `std.testing.allocator`. So `testing.allocator` cannot be a leak oracle for
//! anything Zstandard allocates, and no test here claims it is. What a test can
//! check is the ownership transition this module owns: that `deinit` frees the
//! context, that a second `deinit` on the same variable is not a second free,
//! and that two contexts are independent. Every buffer a test allocates itself
//! is still freed, so the suite leaks nothing of its own.

const std = @import("std");
const zstd = @import("zstd");
const testing = std.testing;

/// A shared object exporting the 189 declarations of `zig/translate.h`, named by
/// the environment in a runtime-loading build.
const provider_variable = "ZSTD_TEST_PROVIDER";

/// The zstd frame magic number as RFC 8878 §3.1.1 spells it, `0xFD2FB528`,
/// stored little-endian. These four bytes are the start of every frame the first
/// group reads.
const rfc_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// The sixteen skippable magic numbers of RFC 8878 §3.1.2 are `0x184D2A5?`; the
/// one `fixtures/rfc8878/skippable-plus-frame.zst` uses is `0x184D2A53`, which
/// is `ZSTD_MAGIC_SKIPPABLE_START` plus 3 (`src/lib/zstd.h:144`), stored
/// little-endian.
const rfc_skippable_magic = [_]u8{ 0x53, 0x2a, 0x4d, 0x18 };

/// Make the native library usable, once, before a test calls the facade.
///
/// In a linked build the facade is usable already and this is a no-op at comptime.
/// In a runtime-loading build every call into the module goes through a table that
/// `load` fills, so this is where the one explicit load happens. It is safe to
/// call from every test: the contract makes the same request idempotent, and the
/// loader keeps the handle to the end of the process.
///
/// A build that was not told which file to load stops here with the variable's
/// name, rather than reporting a test failure that says nothing about the reason.
/// A suite that quietly stopped testing because a variable was unset would report
/// success for nothing.
fn nativeReady() void {
    if (comptime !zstd.runtime_loaded) return;
    if (zstd.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(testing.allocator, provider_variable) catch
        missingProvider();
    defer testing.allocator.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    zstd.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared object exporting the 189 " ++
            "declarations of zig/translate.h, for example the one `zig build " ++
            "-Dlinkage=dynamic` installs, and export it for the whole `zig build` " ++
            "invocation: the build cannot inject a path into a run step's " ++
            "environment.",
    );
}

// ---------------------------------------------------------------------------
// RFC 8878, read out of this file rather than out of any zstd function.
// ---------------------------------------------------------------------------

/// Frame_Header_Descriptor, decoded from the bit layout of RFC 8878
/// §3.1.1.1.1 Table 3.
///
/// The table's note at :290 is the one that makes this unambiguous: "In Table 3,
/// bit 7 is the highest bit, while bit 0 is the lowest one."
const Descriptor = struct {
    /// Bits 7-6, the Frame_Content_Size flag.
    fcs_flag: u2,
    /// Bit 5.
    single_segment: bool,
    /// Bit 4, which the RFC calls "(unused)".
    unused: bool,
    /// Bit 3, which the RFC calls Reserved and requires to be zero.
    reserved: bool,
    /// Bit 2.
    checksum: bool,
    /// Bits 1-0.
    dict_id_flag: u2,
};

fn decodeDescriptor(byte: u8) Descriptor {
    return .{
        .fcs_flag = @truncate(byte >> 6),
        .single_segment = (byte & 0x20) != 0,
        .unused = (byte & 0x10) != 0,
        .reserved = (byte & 0x08) != 0,
        .checksum = (byte & 0x04) != 0,
        .dict_id_flag = @truncate(byte & 0x03),
    };
}

/// `FCS_Field_Size` per RFC 8878 §3.1.1.1.1 Table 3 and the note at :309-312: a
/// flag of 0 means zero bytes *unless* Single_Segment_Flag is set, in which case
/// one. The other three flags are 2, 4 and 8 regardless.
fn fcsFieldSize(d: Descriptor) usize {
    return switch (d.fcs_flag) {
        0 => if (d.single_segment) 1 else 0,
        1 => 2,
        2 => 4,
        3 => 8,
    };
}

/// `DID_Field_Size` per RFC 8878 §3.1.1.1.1 Table 3: 0, 1, 2 and 4 bytes for the
/// four Dictionary_ID_flag values.
fn didFieldSize(d: Descriptor) usize {
    return switch (d.dict_id_flag) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
    };
}

/// The whole Frame_Header size per RFC 8878 §3.1.1.1: four bytes of magic, one
/// Frame_Header_Descriptor, then - only when Single_Segment_Flag is clear, by
/// §3.1.1.1.2 - a Window_Descriptor, then the dictionary ID and the content
/// size.
fn frameHeaderSizeFromRfc(frame: []const u8) usize {
    const d = decodeDescriptor(frame[4]);
    // Named rather than inlined: a bare `if` in the sum is a `comptime_int` in
    // one arm and a run-time `usize` in the other, and the mixed sum has no
    // type to resolve to.
    const window_descriptor: usize = if (d.single_segment) 0 else 1;
    return 4 + 1 + window_descriptor + didFieldSize(d) + fcsFieldSize(d);
}

/// Block_Header, decoded from the layout of RFC 8878 §3.1.1.2 Table 9: three
/// bytes little-endian holding Last_Block in bit 0, Block_Type in bits 2-1 and
/// Block_Size in bits 23-3.
const BlockHeader = struct {
    last: bool,
    /// 0 Raw_Block, 1 RLE_Block, 2 Compressed_Block, 3 Reserved.
    block_type: u2,
    size: u21,
};

fn decodeBlockHeader(frame: []const u8, offset: usize) BlockHeader {
    const raw = std.mem.readInt(u24, frame[offset..][0..3], .little);
    return .{
        .last = (raw & 1) != 0,
        .block_type = @truncate(raw >> 1),
        .size = @truncate(raw >> 3),
    };
}

/// Decompress `src` into a fresh buffer and return it, for the frames whose
/// length this file knows.
fn decodeExactly(src: []const u8, expected_len: usize) ![]u8 {
    const dst = try testing.allocator.alloc(u8, expected_len);
    errdefer testing.allocator.free(dst);
    const read = try zstd.decompress(dst, src);
    if (read != expected_len) {
        std.debug.print(
            "tests.zig: expected {d} bytes decoded, got {d}\n",
            .{ expected_len, read },
        );
        return error.UnexpectedLength;
    }
    return dst;
}

// ---------------------------------------------------------------------------
// The RFC 8878 frames, embedded in place.
// ---------------------------------------------------------------------------

const raw_block_frame: []const u8 = @embedFile("fixtures/rfc8878/raw-block.zst");
const raw_block_plain: []const u8 = @embedFile("fixtures/rfc8878/raw-block.plain");
const rle_block_frame: []const u8 = @embedFile("fixtures/rfc8878/rle-block.zst");
const rle_block_plain: []const u8 = @embedFile("fixtures/rfc8878/rle-block.plain");
const skippable_frame: []const u8 = @embedFile("fixtures/rfc8878/skippable-plus-frame.zst");
const skippable_plain: []const u8 = @embedFile("fixtures/rfc8878/skippable-plus-frame.plain");

// ---------------------------------------------------------------------------
// Upstream's golden corpus, embedded in place from src/tests/golden-decompression/.
// ---------------------------------------------------------------------------

const golden_rle_first: []const u8 = @embedFile("src/tests/golden-decompression/rle-first-block.zst");
const golden_empty: []const u8 = @embedFile("src/tests/golden-decompression/empty-block.zst");
const golden_zero_seq: []const u8 = @embedFile("src/tests/golden-decompression/zeroSeq_2B.zst");
const golden_block_128k: []const u8 = @embedFile("src/tests/golden-decompression/block-128k.zst");

/// A frame upstream ships and labels invalid: `zeroSeq_extraneous.zst` carries
/// three bytes where RFC 8878 §3.1.1.3.2.1.2 says the Sequences section ends
/// after Number_of_Sequences, and `src/lib/decompress/zstd_decompress_block.c:723-724`
/// is the check that catches it.
const golden_error_extraneous: []const u8 =
    @embedFile("src/tests/golden-decompression-errors/zeroSeq_extraneous.zst");

// ---------------------------------------------------------------------------
// Upstream-interop frames.
// ---------------------------------------------------------------------------

const plain_payload: []const u8 = @embedFile("fixtures/plain.bin");
const cli_level_1: []const u8 = @embedFile("fixtures/cli/level-1.zst");
const cli_level_3: []const u8 = @embedFile("fixtures/cli/level-3.zst");
const cli_level_19: []const u8 = @embedFile("fixtures/cli/level-19.zst");
const cli_ultra_22: []const u8 = @embedFile("fixtures/cli/ultra-22.zst");
const cli_no_check_3: []const u8 = @embedFile("fixtures/cli/no-check-3.zst");
const cli_single_thread_3: []const u8 = @embedFile("fixtures/cli/single-thread-3.zst");
const pyzstd_level_1: []const u8 = @embedFile("fixtures/pyzstd/level-1.zst");
const pyzstd_level_3: []const u8 = @embedFile("fixtures/pyzstd/level-3.zst");
const pyzstd_level_19: []const u8 = @embedFile("fixtures/pyzstd/level-19.zst");
const pyzstd_bare_3: []const u8 = @embedFile("fixtures/pyzstd/bare-3.zst");

test "RFC 8878: a raw-block frame decodes to the plaintext the specification predicts" {
    nativeReady();

    // The magic number, §3.1.1: 0xFD2FB528, little-endian.
    try testing.expectEqualSlices(u8, &rfc_magic, raw_block_frame[0..4]);

    // The descriptor byte, read out of the file and checked against the literal
    // the specification gives for this frame. 0x20 is 0b0010_0000: Frame_Content_Size
    // flag 0, Single_Segment_Flag set, unused and reserved bits clear, no
    // checksum, no dictionary ID.
    try testing.expectEqual(@as(u8, 0x20), raw_block_frame[4]);
    const descriptor = decodeDescriptor(raw_block_frame[4]);
    try testing.expectEqual(@as(u2, 0), descriptor.fcs_flag);
    try testing.expect(descriptor.single_segment);
    try testing.expect(!descriptor.unused);
    try testing.expect(!descriptor.reserved);
    try testing.expect(!descriptor.checksum);
    try testing.expectEqual(@as(u2, 0), descriptor.dict_id_flag);

    // §3.1.1.1.1.2: Single_Segment_Flag set means no Window_Descriptor byte, and
    // §3.1.1.1.1.1 gives FCS_Field_Size 1 for a flag of 0 in that case. So the
    // header is 4 + 1 + 1 = 6 bytes and the content size is the single byte
    // 0x1a.
    try testing.expectEqual(@as(usize, 1), fcsFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 0), didFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(raw_block_frame));
    try testing.expectEqual(@as(u8, 26), raw_block_frame[5]);

    // §3.1.1.2 Table 9: bytes 6,7,8 read little-endian are 0xd1 0x00 0x00, so
    // Last_Block is set, Block_Type is 0 (Raw_Block) and Block_Size is 26.
    const block = decodeBlockHeader(raw_block_frame, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 0), block.block_type);
    try testing.expectEqual(@as(u21, 26), block.size);

    // Now ask the library the same questions. `frameHeaderSize` computes from the
    // descriptor alone (`src/lib/decompress/zstd_decompress.c:416-429`).
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(raw_block_frame));
    try testing.expectEqual(zstd.ContentSize{ .known = 26 }, zstd.frameContentSize(raw_block_frame));
    try testing.expectEqual(@as(usize, 35), try zstd.findFrameCompressedSize(raw_block_frame));
    // Dictionary_ID_flag is 0, so there is no dictionary ID field and the
    // answer is zero (`src/lib/zstd.h:1071`).
    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(raw_block_frame));
    try testing.expect(!zstd.isSkippableFrame(raw_block_frame));

    // And the content. The plaintext file is the prediction; 26 bytes of it.
    try testing.expectEqual(@as(usize, 26), raw_block_plain.len);
    const decoded = try decodeExactly(raw_block_frame, raw_block_plain.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, raw_block_plain, decoded);
}

test "RFC 8878: an RLE block decodes to Block_Size repetitions of one byte" {
    nativeReady();

    try testing.expectEqualSlices(u8, &rfc_magic, rle_block_frame[0..4]);
    try testing.expectEqual(@as(u8, 0x20), rle_block_frame[4]);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(rle_block_frame));
    // 0xc8 = 200, the declared content size, in the one FCS byte.
    try testing.expectEqual(@as(u8, 200), rle_block_frame[5]);

    // §3.1.1.2 Table 9 on bytes 6,7,8: 0x43 0x06 0x00 is 0x000643 little-endian,
    // so Last_Block is set, Block_Type is 1 (RLE_Block) and Block_Size is 200.
    const block = decodeBlockHeader(rle_block_frame, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 1), block.block_type);
    try testing.expectEqual(@as(u21, 200), block.size);

    // §3.1.1.2.2: "RLE_Block: This is a single byte, repeated Block_Size times."
    // The single byte is 0x5a, and the prediction is 200 of them - which is what
    // makes this an independent known answer rather than a round trip.
    try testing.expectEqual(@as(u8, 0x5a), rle_block_frame[9]);
    try testing.expectEqual(@as(usize, 10), rle_block_frame.len);
    try testing.expectEqual(@as(usize, 4 + 1 + 1 + 3 + 1), rle_block_frame.len);

    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(rle_block_frame));
    try testing.expectEqual(zstd.ContentSize{ .known = 200 }, zstd.frameContentSize(rle_block_frame));
    try testing.expectEqual(@as(usize, 10), try zstd.findFrameCompressedSize(rle_block_frame));

    const decoded = try decodeExactly(rle_block_frame, 200);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, rle_block_plain, decoded);
    try testing.expectEqual(@as(usize, 200), rle_block_plain.len);
    for (decoded) |byte| try testing.expectEqual(@as(u8, 0x5a), byte);
}

test "RFC 8878: a skippable frame is stepped over and the frame after it decoded" {
    nativeReady();

    // §3.1.2: the magic is 0x184D2A5? and the second field is a 4-byte
    // little-endian frame size. 0x184D2A53 is ZSTD_MAGIC_SKIPPABLE_START + 3,
    // which `src/lib/zstd.h:144` says is one of the sixteen valid values.
    try testing.expectEqualSlices(u8, &rfc_skippable_magic, skippable_frame[0..4]);
    try testing.expectEqual(zstd.magic_skippable_start + 3, std.mem.readInt(u32, skippable_frame[0..4], .little));
    const payload_len = std.mem.readInt(u32, skippable_frame[4..8], .little);
    try testing.expectEqual(@as(u32, 45), payload_len);
    // 4 of magic + 4 of length + 45 of payload.
    const skippable_total = 8 + payload_len;
    try testing.expectEqual(@as(usize, 53), skippable_total);
    try testing.expectEqualSlices(u8, "zlib-foundation-sdk interop provenance marker", skippable_frame[8..53]);

    // The library agrees, and it agrees through the skippable arm of
    // `ZSTD_findFrameCompressedSize` (`src/lib/decompress/zstd_decompress.c:744-749`).
    try testing.expect(zstd.isSkippableFrame(skippable_frame));
    try testing.expectEqual(@as(usize, 53), try zstd.findFrameCompressedSize(skippable_frame));

    // `ZSTD_getFrameContentSize` answers 0 for a skippable frame
    // (`src/lib/decompress/zstd_decompress.c:580-581`) and 0 is also the size of
    // an empty zstd frame, which is why `ContentSize` exists. Reported, not
    // resolved.
    try testing.expectEqual(@as(u64, 0), zstd.frameContentSize(skippable_frame).get().?);

    // `ZSTD_frameHeaderSize` is *not* a skippable-header size: its own comment
    // says it only works for the zstd1 formats
    // (`src/lib/decompress/zstd_decompress.c:413`) and the implementation reads
    // byte 4 as a Frame_Header_Descriptor regardless. On this buffer byte 4 is
    // 0x2d, so the descriptor decodes to dictID 1, singleSegment 1, fcsId 0 and
    // the answer is 5 + 0 + 1 + 0 + 1 = 7, not the 8 of `skippable_header_size`.
    // Asserted so that the divergence is recorded rather than discovered.
    try testing.expectEqual(@as(usize, 7), try zstd.frameHeaderSize(skippable_frame));
    try testing.expectEqual(@as(usize, 8), zstd.skippable_header_size);

    // What follows the skippable frame is the raw-block frame again, byte for
    // byte. That is a property of how this fixture was assembled and is checked
    // here rather than assumed.
    try testing.expectEqualSlices(u8, raw_block_frame, skippable_frame[skippable_total..]);
    try testing.expectEqual(@as(usize, 88), skippable_frame.len);

    // And the whole buffer decodes to the plaintext of the second frame alone:
    // the skippable payload contributes nothing.
    const decoded = try decodeExactly(skippable_frame, skippable_plain.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, skippable_plain, decoded);
    try testing.expectEqualSlices(u8, raw_block_plain, decoded);
}

test "a skippable frame on its own decodes to nothing rather than failing" {
    nativeReady();

    const only = skippable_frame[0..53];
    var dst: [64]u8 = undefined;
    const read = try zstd.decompress(&dst, only);
    // Skipped, not rejected: zero bytes out and no error
    // (`src/lib/decompress/zstd_decompress.c:1120-1132` steps over it).
    try testing.expectEqual(@as(usize, 0), read);
}

test "upstream golden: rle-first-block decodes to the 1 MiB of zeros the RFC implies" {
    nativeReady();

    // FHD 0xa4: Frame_Content_Size flag 2, so FCS_Field_Size is 4; Single_Segment_Flag
    // set; content checksum present; no dictionary ID. Header is 4 + 1 + 4 = 9.
    try testing.expectEqual(@as(u8, 0xa4), golden_rle_first[4]);
    const descriptor = decodeDescriptor(golden_rle_first[4]);
    try testing.expectEqual(@as(u2, 2), descriptor.fcs_flag);
    try testing.expect(descriptor.single_segment);
    try testing.expect(descriptor.checksum);
    try testing.expectEqual(@as(usize, 4), fcsFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 9), frameHeaderSizeFromRfc(golden_rle_first));
    try testing.expectEqual(@as(u32, 1048576), std.mem.readInt(u32, golden_rle_first[5..9], .little));

    // Eight consecutive RLE blocks of 131072 each, three header bytes plus one
    // content byte apiece, then a four-byte content checksum. Each block header
    // reads little-endian; the first seven are 0x100002 and the last is 0x100003,
    // which differs only in the Last_Block bit.
    try testing.expectEqual(@as(usize, 45), golden_rle_first.len);
    try testing.expectEqual(@as(usize, 9 + 8 * 4 + 4), golden_rle_first.len);
    var offset: usize = 9;
    var block_index: usize = 0;
    while (block_index < 8) : (block_index += 1) {
        const block = decodeBlockHeader(golden_rle_first, offset);
        try testing.expectEqual(@as(u2, 1), block.block_type);
        try testing.expectEqual(@as(u21, 131072), block.size);
        try testing.expectEqual(block_index == 7, block.last);
        try testing.expectEqual(@as(u8, 0x00), golden_rle_first[offset + 3]);
        offset += 4;
    }
    // RFC 8878 §3.1.1.2.2: one byte, repeated Block_Size times. Eight of them.
    try testing.expectEqual(@as(usize, 1048576), 8 * 131072);

    try testing.expectEqual(@as(usize, 9), try zstd.frameHeaderSize(golden_rle_first));
    try testing.expectEqual(
        zstd.ContentSize{ .known = 1048576 },
        zstd.frameContentSize(golden_rle_first),
    );
    // The answer includes the trailing checksum
    // (`src/lib/decompress/zstd_decompress.c:786-793` steps over it before
    // measuring).
    try testing.expectEqual(@as(usize, 45), try zstd.findFrameCompressedSize(golden_rle_first));

    const decoded = try decodeExactly(golden_rle_first, 1048576);
    defer testing.allocator.free(decoded);
    for (decoded) |byte| try testing.expectEqual(@as(u8, 0x00), byte);
}

test "upstream golden: empty-block carries no content size and decodes to nothing" {
    nativeReady();

    // FHD 0x00: Frame_Content_Size flag 0 *and* Single_Segment_Flag clear, so by
    // RFC 8878 §3.1.1.1.1 the FCS field is absent - and because the flag is clear,
    // §3.1.1.1.2 puts a Window_Descriptor byte at offset 5. Header is 4 + 1 + 1 = 6.
    try testing.expectEqual(@as(u8, 0x00), golden_empty[4]);
    const descriptor = decodeDescriptor(golden_empty[4]);
    try testing.expect(!descriptor.single_segment);
    try testing.expectEqual(@as(usize, 0), fcsFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(golden_empty));
    try testing.expectEqual(@as(u8, 0x00), golden_empty[5]);

    const block = decodeBlockHeader(golden_empty, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    try testing.expectEqual(@as(u21, 2), block.size);

    // The point of this golden file: a frame with genuinely no content size must
    // answer the unknown constant, not 0.
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_empty));
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_empty));
    try testing.expectEqual(@as(usize, 11), try zstd.findFrameCompressedSize(golden_empty));

    var dst: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try zstd.decompress(&dst, golden_empty));
}

test "upstream golden: zeroSeq_2B decodes to the raw literals it carries" {
    nativeReady();

    try testing.expectEqual(@as(u8, 0x00), golden_zero_seq[4]);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(golden_zero_seq));
    // FHD 0x00 with Single_Segment_Flag clear again: no content size.
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_zero_seq));

    // One Compressed_Block of 16 bytes, header-derived.
    const block = decodeBlockHeader(golden_zero_seq, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    try testing.expectEqual(@as(u21, 16), block.size);
    try testing.expectEqual(@as(usize, 25), golden_zero_seq.len);
    try testing.expectEqual(@as(usize, 6 + 3 + 16), golden_zero_seq.len);

    // RFC 8878 §3.1.1.3.1.1 on the literals section, which starts at offset 9:
    // 0x68 is Raw_Literals_Block (bits 1-0 = 00) with Size_Format 2 (bits 3-2 =
    // 10), which for a raw block is a one-byte size in the remaining five bits.
    // 0x68 >> 3 is 13, and the next 13 bytes are the text.
    const literals_header = golden_zero_seq[9];
    try testing.expectEqual(@as(u2, 0), @as(u2, @truncate(literals_header & 0x03)));
    try testing.expectEqual(@as(u2, 2), @as(u2, @truncate(literals_header >> 2)));
    const regenerated = @as(usize, literals_header >> 3);
    try testing.expectEqual(@as(usize, 13), regenerated);

    // The expected output below is an inline byte array. **It is the output
    // recorded from the system `zstd` CLI v1.5.7, not something derived from the
    // specification**: deriving it would mean running a Huffman decoder, which
    // this file does not do. It is compared byte for byte, not by length, because
    // the length alone would not catch a decoder that emitted the right number of
    // wrong bytes.
    const expected = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0a };
    try testing.expectEqualSlices(u8, &expected, golden_zero_seq[10..23]);
    try testing.expectEqualSlices(u8, "Hello World!\n", &expected);

    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_zero_seq));
    try testing.expectEqual(@as(usize, 25), try zstd.findFrameCompressedSize(golden_zero_seq));
    const decoded = try decodeExactly(golden_zero_seq, expected.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &expected, decoded);

    // Upstream's own note on this frame: `src/doc/decompressor_errata.md:15-32`
    // records that a decoder expecting FSE tables when there are zero sequences
    // encoded in the two-byte form wrongly rejects it. 1.5.7 is past the
    // "last affected version" it names.
    try testing.expectEqual(@as(u32, 10507), zstd.version_number);
}

test "upstream golden: a compressed block of exactly 128 KiB is accepted" {
    nativeReady();

    try testing.expectEqual(@as(u8, 0x00), golden_block_128k[4]);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(golden_block_128k));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_block_128k));

    // Window_Descriptor 0x38: exponent is the top five bits, 0x38 >> 3 = 7, and
    // RFC 8878 §3.1.1.1.2 defines Window_Size as 2^(10 + exponent) plus a
    // mantissa, so 2^17 = 131072 with a zero mantissa. That is exactly
    // ZSTD_BLOCKSIZE_MAX (`src/lib/zstd.h:147-148`).
    const window_byte = golden_block_128k[5];
    try testing.expectEqual(@as(u8, 0x38), window_byte);
    const exponent = @as(u5, @truncate(window_byte >> 3));
    const mantissa = @as(u3, @truncate(window_byte & 0x07));
    try testing.expectEqual(@as(u5, 7), exponent);
    try testing.expectEqual(@as(u3, 0), mantissa);
    const window_size = @as(usize, 1) << @intCast(10 + exponent);
    try testing.expectEqual(@as(usize, 131072), window_size);
    try testing.expectEqual(zstd.block_size_max, window_size);

    // One Compressed_Block whose Block_Size is exactly 128 KiB, which
    // `src/doc/decompressor_errata.md:35-51` records as rejected up to v1.5.2.
    const block = decodeBlockHeader(golden_block_128k, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    try testing.expectEqual(@as(u21, 131072), block.size);
    try testing.expectEqual(@as(usize, 131081), golden_block_128k.len);
    try testing.expectEqual(@as(usize, 6 + 3 + 131072), golden_block_128k.len);

    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_block_128k));
    try testing.expectEqual(@as(usize, 131081), try zstd.findFrameCompressedSize(golden_block_128k));

    // The exact decompressed length is **not** asserted: deriving it would mean
    // decoding the block, which this file does not do. RFC 8878 §3.1.1.2.3 caps
    // a block's regenerated size at the smaller of Window_Size and 128 KB, and
    // this frame's Window_Size is 131072, so the length this test asserts is the
    // specification's bound and the assertion that it is non-zero.
    const bound = try zstd.decompressBound(golden_block_128k);
    try testing.expect(bound >= zstd.block_size_max);
    const dst = try testing.allocator.alloc(u8, @intCast(bound));
    defer testing.allocator.free(dst);
    const read = try zstd.decompress(dst, golden_block_128k);
    try testing.expect(read > 0);
    try testing.expect(read <= zstd.block_size_max);
}

test "upstream golden: a frame upstream labels invalid is refused with corruption" {
    nativeReady();

    // `src/tests/playTests.sh:534` requires the CLI to *fail* on this file, and
    // `src/lib/decompress/zstd_decompress_block.c:723-724` is the check that
    // makes it fail: `RETURN_ERROR_IF(ip != iend, corruption_detected,
    // "extraneous data present in the Sequences section")`.
    try testing.expectEqual(@as(u8, 0x00), golden_error_extraneous[4]);
    const block = decodeBlockHeader(golden_error_extraneous, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    // 18 content bytes where the valid frame has 16: the two extra are the
    // "extraneous data present in the Sequences section".
    try testing.expectEqual(@as(u21, 18), block.size);
    try testing.expectEqual(@as(usize, 27), golden_error_extraneous.len);

    // The frame header is readable - it is the *content* that is refused - so the
    // unknown-size answer is still produced.
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_error_extraneous));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_error_extraneous));

    var dst: [4096]u8 = undefined;
    try testing.expectError(error.Corruption, zstd.decompress(&dst, golden_error_extraneous));

    // The same frame through the raw route, so that the code and the message can
    // both be named.
    const raw = zstd.c.ZSTD_decompress(&dst, dst.len, golden_error_extraneous.ptr, golden_error_extraneous.len);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.corruption_detected, zstd.errorCode(raw));
    // Upstream's own text for that code (`src/lib/common/error_private.c:29`).
    try testing.expectEqualStrings("Data corruption detected", zstd.errorName(raw));
    try testing.expectEqualStrings(
        "Data corruption detected",
        zstd.errorCodeText(zstd.ErrorCode.corruption_detected),
    );
}

test "upstream-interop frames decode to the recorded plaintext" {
    nativeReady();

    // 232 bytes, the payload every fixture in cli/ and pyzstd/ compresses.
    try testing.expectEqual(@as(usize, 232), plain_payload.len);
    const first_line_end = std.mem.indexOfScalar(u8, plain_payload, '\n').? + 1;
    try testing.expectEqualStrings(
        "zstd foundation SDK interop payload\n",
        plain_payload[0..first_line_end],
    );

    const frames = [_]struct { name: []const u8, frame: []const u8 }{
        .{ .name = "cli/level-1.zst", .frame = cli_level_1 },
        .{ .name = "cli/level-3.zst", .frame = cli_level_3 },
        .{ .name = "cli/level-19.zst", .frame = cli_level_19 },
        .{ .name = "cli/ultra-22.zst", .frame = cli_ultra_22 },
        .{ .name = "cli/no-check-3.zst", .frame = cli_no_check_3 },
        .{ .name = "cli/single-thread-3.zst", .frame = cli_single_thread_3 },
        .{ .name = "pyzstd/level-1.zst", .frame = pyzstd_level_1 },
        .{ .name = "pyzstd/level-3.zst", .frame = pyzstd_level_3 },
        .{ .name = "pyzstd/level-19.zst", .frame = pyzstd_level_19 },
        .{ .name = "pyzstd/bare-3.zst", .frame = pyzstd_bare_3 },
    };
    for (frames) |entry| {
        const decoded = decodeExactly(entry.frame, plain_payload.len) catch |err| {
            std.debug.print("tests.zig: {s} did not decode: {t}\n", .{ entry.name, err });
            return err;
        };
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, plain_payload, decoded);

        // Each of these files is exactly one complete frame, so the frame's own
        // size is the file's size. That is a consistency check on the fixture
        // set rather than an oracle about the format, and it is here so that a
        // fixture that was truncated in transit fails loudly.
        try testing.expectEqual(entry.frame.len, try zstd.findFrameCompressedSize(entry.frame));
    }
}

test "a windowed frame and a single-segment frame differ only in the descriptor" {
    nativeReady();

    // `fixtures/cli/level-3.zst` has FHD 0x24: Single_Segment_Flag set, the
    // Content_Checksum_flag set, no dictionary ID, Frame_Content_Size flag 0 -
    // so with the single-segment flag set the one-byte FCS is present and no
    // Window_Descriptor is. The checksum is the four bytes that make this file
    // 136 bytes where `fixtures/pyzstd/bare-3.zst` is 132.
    // `fixtures/pyzstd/bare-3.zst` has FHD 0x00: both flags are clear, so a
    // Window_Descriptor is present and the FCS field is absent.
    try testing.expectEqual(@as(u8, 0x24), cli_level_3[4]);
    try testing.expectEqual(@as(u8, 0x00), pyzstd_bare_3[4]);

    const single = decodeDescriptor(cli_level_3[4]);
    try testing.expect(single.single_segment);
    try testing.expect(single.checksum);
    try testing.expectEqual(@as(u2, 0), single.fcs_flag);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(cli_level_3));

    const windowed = decodeDescriptor(pyzstd_bare_3[4]);
    try testing.expect(!windowed.single_segment);
    try testing.expectEqual(@as(u2, 0), windowed.fcs_flag);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(pyzstd_bare_3));

    // Both headers are six bytes, and they get there by different field
    // combinations: one by skipping the Window_Descriptor and carrying a
    // one-byte content size, the other by carrying the Window_Descriptor and no
    // content size at all. Asserted together because that is the point.
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(cli_level_3));
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(pyzstd_bare_3));

    // The single-segment frame declares 232 bytes; the windowed one declares
    // nothing, which is what `ZSTD_getFrameContentSize` reports as the unknown
    // constant (`src/lib/zstd.h:203`).
    try testing.expectEqual(@as(u8, 0xe8), cli_level_3[5]);
    try testing.expectEqual(zstd.ContentSize{ .known = 232 }, zstd.frameContentSize(cli_level_3));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(pyzstd_bare_3));

    // Neither frame carries a dictionary ID, so both answer 0.
    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(cli_level_3));
    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(pyzstd_bare_3));
}

test "the CLI and the binding are one implementation behind two producers" {
    nativeReady();

    // The digests `fixtures/PROVENANCE.md` records are the same for these pairs,
    // and this is the assertion that keeps the rest of that file honest: at the
    // same level the system `zstd` CLI v1.5.7 and the python-`zstandard` 0.22.0
    // binding emit byte-identical frames. They are upstream-interop fixtures, not
    // two independent encoders, and a reader who assumes otherwise would be
    // reading more evidence into them than they carry.
    try testing.expectEqualSlices(u8, cli_level_1, pyzstd_level_1);
    try testing.expectEqualSlices(u8, cli_level_3, pyzstd_level_3);
    try testing.expectEqualSlices(u8, cli_level_19, pyzstd_level_19);

    // `--single-thread` at level 3 is the same frame as plain level 3: a
    // single-threaded build and the default agree here, because this build's
    // libzstd is single-threaded too.
    try testing.expectEqualSlices(u8, cli_level_3, cli_single_thread_3);

    // `--ultra -22` is the same frame as level 19, which is what a clamp at
    // ZSTD_MAX_CLEVEL (22, `src/lib/compress/clevels.h:19`) beyond the highest
    // *tunable* level produces. Recorded here because it is a fact about the
    // fixtures, not a claim about what the CLI's `-22` does on every input.
    try testing.expectEqualSlices(u8, cli_ultra_22, pyzstd_level_19);

    // `--no-check` removes the trailing content checksum, so its FHD differs in
    // bit 2 and its file is four bytes shorter.
    try testing.expectEqual(@as(usize, 136), cli_level_3.len);
    try testing.expectEqual(@as(usize, 132), cli_no_check_3.len);
    try testing.expectEqual(@as(usize, cli_level_3.len - 4), cli_no_check_3.len);
    try testing.expect(decodeDescriptor(cli_level_3[4]).checksum);
    try testing.expect(!decodeDescriptor(cli_no_check_3[4]).checksum);
}

test "compressBound is a bound, and it grows the way the macro says it must" {
    nativeReady();

    // `src/lib/zstd.h:249` gives the bound as
    // `srcSize + (srcSize>>8) + margin`, which is never below `srcSize`.
    const sizes = [_]usize{ 0, 1, 13, 26, 200, 232, 4096, 131071, 131072, 262144 };
    for (sizes) |size| {
        const bound = try zstd.compressBound(size);
        try testing.expect(bound >= size);
        // The macro and the function must agree, or a caller sizing an array at
        // comptime and a caller sizing it at run time get two different answers.
        try testing.expectEqual(bound, zstd.compressBoundConst(size));
    }
    try testing.expect(zstd.compressBoundConst(0) > 0);

    // The same macro's own comment states the subadditivity it guarantees: "this
    // formula ensures that bound(A) + bound(B) <= bound(A+B) as long as A and B
    // >= 128 KB". Both sides here are at least the 128 KB the comment names.
    const a: usize = 131072;
    const b: usize = 262144;
    // The sizes themselves are the 128 KB the macro's comment names.
    try testing.expectEqual(@as(usize, 131072), a);
    try testing.expectEqual(@as(usize, 262144), b);
    try testing.expect(
        (try zstd.compressBound(a)) + (try zstd.compressBound(b)) <=
            try zstd.compressBound(a + b),
    );

    // A frame written into exactly `compressBound` bytes fits, which is the only
    // statement about a bound that matters.
    const payload = plain_payload;
    const bound = try zstd.compressBound(payload.len);
    var frame = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame);
    const written = try zstd.compress(frame, payload, 3);
    try testing.expect(written <= bound);
    try testing.expectEqual(@as(u64, @intCast(payload.len)), try zstd.decompressBound(frame[0..written]));
}

test "a truncated frame is an error and leaves the destination untouched" {
    nativeReady();

    // `fixtures/cli/level-3.zst` is a 136-byte frame whose header is 6 bytes and
    // whose first block header is 3, so the first 9 bytes are a complete header
    // and a block header claiming 123 content bytes that are not there.
    // `ZSTD_decompressFrame` reads the block header and checks the block's bytes
    // are present (`src/lib/decompress/zstd_decompress.c:990-994`) before any
    // output pointer moves, so this truncation writes nothing at all.
    var truncated: [9]u8 = undefined;
    @memcpy(&truncated, cli_level_3[0..9]);
    const block = decodeBlockHeader(cli_level_3, 6);
    try testing.expectEqual(@as(u21, 123), block.size);

    var dst: [256]u8 = [_]u8{0xa5} ** 256;
    try testing.expectError(error.SrcSizeWrong, zstd.decompress(&dst, &truncated));
    for (dst) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // And the same truncation through the raw route, so the code is named rather
    // than only the mapping. `src/lib/common/error_private.c:49` is where that
    // string lives.
    const raw = zstd.c.ZSTD_decompress(&dst, dst.len, &truncated, truncated.len);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.src_size_wrong, zstd.errorCode(raw));
    try testing.expectEqualStrings("Src size is incorrect", zstd.errorName(raw));
    // ...and it is not the success string, which is what "isError and getErrorName
    // agree with each other" has to mean for a caller that only has the two.
    try testing.expect(!std.mem.eql(u8, zstd.errorName(raw), zstd.errorName(0)));
    for (dst) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // The untruncated frame from the same bytes decodes, so the assertion above
    // is about the truncation rather than about this fixture being unusable.
    const whole = try decodeExactly(cli_level_3, plain_payload.len);
    defer testing.allocator.free(whole);
    try testing.expectEqualSlices(u8, plain_payload, whole);
}

test "an out-of-range level is clamped and an out-of-range parameter is refused" {
    nativeReady();

    var ctx = try zstd.Ctx.init();
    defer ctx.deinit();

    // `ZSTD_maxCLevel` is `ZSTD_MAX_CLEVEL`, which `src/lib/compress/clevels.h:19`
    // defines as 22.
    try testing.expectEqual(@as(zstd.Level, 22), zstd.maxLevel());
    try testing.expect(zstd.maxLevel() >= zstd.default_level);
    // `ZSTD_minCLevel` answers `-ZSTD_TARGETLENGTH_MAX`
    // (`src/lib/compress/zstd_compress.c:7674`) and `src/lib/zstd.h:1277` makes
    // that `ZSTD_BLOCKSIZE_MAX`, so the floor is -131072.
    try testing.expectEqual(@as(zstd.Level, -131072), zstd.minLevel());
    try testing.expectEqual(@as(usize, 131072), zstd.block_size_max);

    // A level beyond the maximum is **clamped**, not refused:
    // `ZSTD_CCtxParams_setParameter` calls `ZSTD_cParam_clampBounds` for
    // `ZSTD_c_compressionLevel` (`src/lib/compress/zstd_compress.c:782`, and
    // `:642-649` is the clamp), where every other parameter uses `BOUNDCHECK`
    // (`:653-655`) and is refused. So the call succeeds and the context holds the
    // maximum - which is only observable through `ZSTD_CCtx_getParameter`.
    try ctx.setLevel(zstd.maxLevel() + 1000);
    try testing.expectEqual(zstd.maxLevel(), try ctx.level());
    try ctx.setLevel(zstd.minLevel() - 1000);
    try testing.expectEqual(zstd.minLevel(), try ctx.level());
    // A level inside the range is kept exactly.
    try ctx.setLevel(7);
    try testing.expectEqual(@as(zstd.Level, 7), try ctx.level());

    // `ZSTD_c_targetLength` bounds are `ZSTD_TARGETLENGTH_MIN` to
    // `ZSTD_TARGETLENGTH_MAX` (`src/lib/compress/zstd_compress.c` reads both from
    // the same case arm), and `ZSTD_TARGETLENGTH_MAX` is `ZSTD_BLOCKSIZE_MAX`, so
    // anything above 131072 is out of bounds and refused.
    try testing.expectError(
        error.ParameterOutOfBound,
        ctx.setParameter(.target_length, 1 << 20),
    );

    // ...and the context is still usable after the refusal. The refusal returns
    // before `ZSTD_CCtxParams_setParameter` writes the field
    // (`src/lib/compress/zstd_compress.c:653-655`), so the level it already holds
    // is unchanged and a frame written through it round-trips.
    try testing.expectEqual(@as(zstd.Level, 7), try ctx.level());
    const bound = try zstd.compressBound(plain_payload.len);
    var frame = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame);
    const written = try ctx.compress(frame, plain_payload, 7);
    const decoded = try decodeExactly(frame[0..written], plain_payload.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, plain_payload, decoded);
}

test "a context refuses an unknown parameter and is still usable" {
    nativeReady();

    var ctx = try zstd.Ctx.init();
    defer ctx.deinit();

    // The `default:` arm of `ZSTD_CCtx_setParameter`
    // (`src/lib/compress/zstd_compress.c:758`) raises `parameter_unsupported` for
    // an id it does not know. Reached through `c` because `CParameter` is a
    // closed Zig enum and 12345 is deliberately not one of its tags.
    // `ZSTD_cParameter` translates to a `c_uint` rather than to a Zig enum -
    // upstream spells it `typedef enum`, which translate-c renders as the
    // integer the C compiler would pick - so the raw id goes in as an integer
    // cast to the parameter type.
    const raw = zstd.c.ZSTD_CCtx_setParameter(ctx.handle(), @intCast(12345), 1);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.parameter_unsupported, zstd.errorCode(raw));
    try testing.expectEqualStrings(
        "Unsupported parameter",
        zstd.errorCodeText(zstd.ErrorCode.parameter_unsupported),
    );

    // A parameter that must be set before a frame starts is refused with
    // `stage_wrong` once one has (`src/lib/compress/zstd_compress.c:709-716`):
    // the window log is not one of the eight `ZSTD_isUpdateAuthorized`
    // parameters at `:658-671`, and the guard fires on `streamStage != zcss_init`.
    //
    // The frame has to be *open*, which is what makes that guard fire. The
    // one-shot `ZSTD_compressCCtx` above cannot do it: it drives a whole frame
    // to its end and leaves the context back in the init stage, so setting the
    // parameter there succeeds. The streaming call below is what leaves a frame
    // open - `endOp = .@"continue"` at `:801-806` returns with the frame live.
    const bound = try zstd.compressBound(plain_payload.len);
    var frame = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame);
    const pledged = try ctx.compress(frame, plain_payload, 3);
    try testing.expect(pledged > 0);

    var stream_out = zstd.OutBuffer{ .dst = frame.ptr, .size = frame.len, .pos = 0 };
    var stream_in = zstd.InBuffer{ .src = plain_payload.ptr, .size = plain_payload.len, .pos = 0 };
    // What proves the frame is open is the refusal below, not the return: the
    // return is how much is still buffered, and with a 512-byte destination and
    // a 232-byte payload `.@"continue"` legitimately has nothing left over.
    // What it must have done is consume the input, and `.@"end"` must then
    // close the frame and return 0 - the loop's termination condition at
    // `src/lib/zstd.h:806`. The frame header and its block reach the
    // destination across those two calls rather than in the first.
    _ = try ctx.stream2(&stream_out, &stream_in, .@"continue");
    try testing.expectEqual(plain_payload.len, stream_in.pos);
    try testing.expectError(error.WrongStage, ctx.setParameter(.window_log, 10));
    // The eight authorized parameters are still settable mid-frame, which is
    // the other half of `ZSTD_isUpdateAuthorized`.
    try ctx.setParameter(.search_log, 3);
    try testing.expectEqual(@as(usize, 0), try ctx.stream2(&stream_out, &stream_in, .@"end"));
    try testing.expect(stream_out.pos > 0);

    // Still usable after both refusals.
    const again = try ctx.compress(frame, plain_payload, 3);
    const decoded = try decodeExactly(frame[0..again], plain_payload.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, plain_payload, decoded);

    // A pledged source size is what puts the content size into the frame header,
    // which is the field `frameContentSize` reads back.
    try ctx.setPledgedSourceSize(@intCast(plain_payload.len));
    const with_size = try ctx.compress(frame, plain_payload, 3);
    try testing.expectEqual(
        zstd.ContentSize{ .known = @intCast(plain_payload.len) },
        zstd.frameContentSize(frame[0..with_size]),
    );
}

test "a trained dictionary carries an ID and round-trips through CDict and DDict" {
    nativeReady();

    // Samples that share structure, which is what a dictionary is for
    // (`src/lib/zdict.h:184-189`). Each is the same shape with the numbers
    // changed, and each is well over the 8-byte floor `src/lib/zdict.h:200-202`
    // names.
    //
    // The sample is sized from what the loop below writes, not chosen: the
    // four sample words are different lengths, so the record size comes from the
    // longest of them, and a shorter buffer is an out-of-bounds write rather
    // than a small sample. One byte more than the records need, because the
    // NUL terminator goes just past the last one and the sample the trainer
    // sees excludes it.
    const record_count = 6;
    const number_len = 4;
    const text_len: usize = @max(
        "alpha bravo charlie delta echo foxtrot golf ".len,
        @max(
            "alpha bravo charlie delta echo foxtrot hotel ".len,
            @max(
                "alpha bravo charlie delta echo foxtrot india ".len,
                "alpha bravo charlie delta echo foxtrot juliet ".len,
            ),
        ),
    );
    const record_len = text_len + number_len + 1;
    const sample_len = record_count * record_len;
    var samples: [64][sample_len + 1]u8 = undefined;
    const sample_ptrs = blk: {
        var out: [64][]const u8 = undefined;
        for (&samples, 0..) |*sample, index| {
            var cursor: usize = 0;
            for (0..record_count) |record| {
                const text = switch (index) {
                    0...15 => "alpha bravo charlie delta echo foxtrot golf ",
                    16...31 => "alpha bravo charlie delta echo foxtrot hotel ",
                    32...47 => "alpha bravo charlie delta echo foxtrot india ",
                    else => "alpha bravo charlie delta echo foxtrot juliet ",
                };
                @memcpy(sample[cursor..][0..text.len], text);
                cursor += text.len;
                // Printed into a local, not into the sample: the slice
                // `bufPrint` returns points into the buffer it was handed, so
                // copying from it into that same buffer is an aliased memcpy.
                var digits: [number_len]u8 = undefined;
                const number = std.fmt.bufPrint(&digits, "{d:0>4}", .{ index * 10 + record }) catch unreachable;
                @memcpy(sample[cursor..][0..number.len], number);
                cursor += number.len;
                sample[cursor] = '\n';
                cursor += 1;
            }
            // A NUL just past the last record, so the terminator follows the
            // content rather than a byte count written separately.
            sample[cursor] = 0;
            out[index] = sample[0..cursor];
        }
        break :blk out;
    };
    // 64 samples, each well past the "a few dozen" the coverage search in the
    // fastcover trainer needs to find a match. The four sample words are
    // `golf`, `hotel`, `india` and `juliet`, and `juliet` is the longest, so it
    // is the group from index 48 that fills the buffer exactly; the shorter
    // words are asserted against the same ceiling below.
    try testing.expect(samples.len >= 8);
    try testing.expectEqual(sample_len, sample_ptrs[samples.len - 1].len);
    // Every sample is at least the 8-byte floor `src/lib/zdict.h:200-202` names
    // and none runs past the buffer it was written into.
    for (sample_ptrs) |sample| {
        try testing.expect(sample.len >= 8);
        try testing.expect(sample.len <= sample_len);
    }

    var dict: [8192]u8 = undefined;
    const dict_len = try zstd.trainDictionary(testing.allocator, &dict, &sample_ptrs);
    try testing.expect(dict_len >= zstd.dict_size_min);
    try testing.expect(dict_len <= dict.len);
    const trained = dict[0..dict_len];

    // A trained dictionary carries a non-zero ID: `ZDICT_getDictID`
    // (`src/lib/zdict.h:269`) answers zero for anything that is not a valid
    // dictionary, so a zero here would mean training did not produce one.
    const id = zstd.dictID(trained);
    try testing.expect(id != 0);

    // Compressing through a digested dictionary. The frame it writes carries
    // that ID in its header, which `src/lib/zstd.h:1010-1011` says is fixed for
    // this path.
    var cdict = try zstd.CDict.init(trained, 3);
    defer cdict.deinit();
    var ctx = try zstd.Ctx.init();
    defer ctx.deinit();
    const bound = try zstd.compressBound(plain_payload.len);
    var frame = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame);
    const written = try ctx.compressUsingCDict(frame, plain_payload, &cdict);
    try testing.expect(written > 0);
    try testing.expectEqual(id, zstd.dictIDFromFrame(frame[0..written]));

    // Decompressing through a digested dictionary, and through the raw
    // dictionary the simpler way.
    var ddict = try zstd.DDict.init(trained);
    defer ddict.deinit();
    var dctx = try zstd.Dctx.init();
    defer dctx.deinit();
    const via_ddict = try testing.allocator.alloc(u8, plain_payload.len);
    defer testing.allocator.free(via_ddict);
    try testing.expectEqual(
        @as(usize, plain_payload.len),
        try dctx.decompressUsingDDict(via_ddict, frame[0..written], &ddict),
    );
    try testing.expectEqualSlices(u8, plain_payload, via_ddict);

    const via_dict = try testing.allocator.alloc(u8, plain_payload.len);
    defer testing.allocator.free(via_dict);
    try testing.expectEqual(
        @as(usize, plain_payload.len),
        try dctx.decompressUsingDict(via_dict, frame[0..written], trained),
    );
    try testing.expectEqualSlices(u8, plain_payload, via_dict);

    // Without the dictionary the same frame is refused rather than decoded into
    // something plausible: `ZSTD_error_dictionary_wrong`, because the frame's
    // dictionary ID does not match an absent dictionary.
    var plain_ctx = try zstd.Dctx.init();
    defer plain_ctx.deinit();
    try testing.expectError(
        error.DictionaryRejected,
        plain_ctx.decompress(via_dict, frame[0..written]),
    );
}

test "a context size smaller than the dictionary floor is refused" {
    nativeReady();

    // `ZDICT_DICTSIZE_MIN` is 256 (`src/lib/zdict.h:305`) and the C trainer
    // returns `dstSize_tooSmall` for anything under it
    // (`src/lib/dictBuilder/fastcover.c:666-670`). The facade checks the same
    // floor before it packs anything, so the answer is the same tag either way.
    var too_small: [16]u8 = undefined;
    const samples = [_][]const u8{"alpha bravo charlie delta echo foxtrot"};
    try testing.expectError(
        error.DstSizeTooSmall,
        zstd.trainDictionary(testing.allocator, &too_small, &samples),
    );
}

test "version, level and frame queries report the provider" {
    nativeReady();

    // `ZSTD_versionNumber` (`src/lib/zstd.h:119`) answers the composed number and
    // `ZSTD_versionString` (`src/lib/zstd.h:128`) the dotted form, both read from
    // the loaded object.
    try testing.expectEqual(zstd.version_number, zstd.versionNumber());
    try testing.expectEqual(@as(u32, 10507), zstd.versionNumber());
    try testing.expectEqual(@as(u32, 1), zstd.version_major);
    try testing.expectEqual(@as(u32, 5), zstd.version_minor);
    try testing.expectEqual(@as(u32, 7), zstd.version_release);
    try testing.expectEqualStrings("1.5.7", zstd.versionString());
    try testing.expectEqualStrings(zstd.version_string_literal, zstd.versionString());
    try testing.expectEqual(zstd.default_level, @as(zstd.Level, 3));

    // The magic numbers the fixtures' first four bytes are compared against.
    try testing.expectEqual(@as(u32, 0xFD2FB528), zstd.magic_number);
    try testing.expectEqual(@as(u32, 0x184D2A50), zstd.magic_skippable_start);
    try testing.expectEqual(@as(u32, 0xFFFFFFF0), zstd.magic_skippable_mask);
    try testing.expectEqual(@as(usize, 5), zstd.frame_header_size_prefix);
    try testing.expectEqual(@as(usize, 6), zstd.frame_header_size_min);
    try testing.expectEqual(@as(usize, 18), zstd.frame_header_size_max);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), zstd.content_size_unknown);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), zstd.content_size_error);

    // A successful result is not an error, and a code outside the taxonomy is
    // reported as one rather than guessed at.
    try testing.expect(!zstd.isError(0));
    try testing.expect(!zstd.isError(42));
    try testing.expectEqual(zstd.ErrorCode.no_error, zstd.errorCode(0));
    try testing.expectEqualStrings("No error detected", zstd.errorCodeText(zstd.ErrorCode.no_error));
    try testing.expectEqualStrings(
        "an error code outside Zstandard's own taxonomy",
        zstd.errorCodeText(zstd.ErrorCode.unrecognised),
    );
    try testing.expect(zstd.ErrorCode.unrecognised.isUnstable());
    try testing.expect(!zstd.ErrorCode.corruption_detected.isUnstable());
    // The reserved maximum is never used directly by upstream
    // (`src/lib/zstd_errors.h:97`) and has no tag of its own.
    try testing.expect(zstd.ErrorCode.fromCode(120) == null);
    try testing.expect(zstd.CParameter.fromCode(zstd.c.ZSTD_c_nbWorkers) == .nb_workers);
    try testing.expect(zstd.DParameter.fromCode(zstd.c.ZSTD_d_windowLogMax) == .window_log_max);
}

test "streaming compression and decompression carry the same bytes" {
    nativeReady();

    // A supplement to the oracles above, not one of them: it checks that the
    // `CStream`/`DStream` wrappers drive the same engine the one-shot route does.
    var cstream = try zstd.CStream.init();
    defer cstream.deinit();
    try cstream.initLevel(3);

    var out_buf: [1024]u8 = undefined;
    var written: usize = 0;
    var fed: usize = 0;
    // Feed the payload in pieces and ask for the frame to end on the last call.
    while (fed < plain_payload.len) {
        const take = @min(@as(usize, 64), plain_payload.len - fed);
        const end: zstd.EndOp = if (fed + take == plain_payload.len) .@"end" else .@"continue";
        var input = zstd.InBuffer{
            .src = plain_payload[fed..].ptr,
            .size = take,
            .pos = 0,
        };
        var output = zstd.OutBuffer{ .dst = out_buf[written..].ptr, .size = out_buf.len - written, .pos = 0 };
        const hint = try cstream.compress(&output, &input, end);
        written += output.pos;
        fed += input.pos;
        // `.@"end"` is complete only when the hint reaches 0, which is what
        // `src/lib/zstd.h:790-792` says upstream's own note means.
        if (end == .@"end") try testing.expectEqual(@as(usize, 0), hint);
    }
    try testing.expect(written > 0);

    var dstream = try zstd.DStream.init();
    defer dstream.deinit();
    _ = dstream.initStream();
    var plain: [512]u8 = undefined;
    var read: usize = 0;
    fed = 0;
    var finished = false;
    while (!finished) {
        const take = @min(@as(usize, 64), written - fed);
        var input = zstd.InBuffer{ .src = out_buf[fed..].ptr, .size = take, .pos = 0 };
        var output = zstd.OutBuffer{ .dst = plain[read..].ptr, .size = plain.len - read, .pos = 0 };
        const remaining = try dstream.decompress(&output, &input);
        read += output.pos;
        fed += input.pos;
        if (remaining == 0 and input.pos == input.size) finished = true;
    }
    try testing.expectEqual(plain_payload.len, read);
    try testing.expectEqualSlices(u8, plain_payload, plain[0..read]);

    // The two recommended buffer sizes are upstream's own advice, not a
    // guarantee of anything about a particular payload.
    try testing.expect(zstd.cStreamInSize() > 0);
    try testing.expect(zstd.cStreamOutSize() > 0);
    try testing.expect(zstd.dStreamInSize() > 0);
    try testing.expect(zstd.dStreamOutSize() > 0);
}

test "each context frees exactly once and two contexts are independent" {
    nativeReady();

    var ctx = try zstd.Ctx.init();
    try testing.expect(ctx.isOpen());
    // `handle()` returns a non-optional pointer and panics once the context is
    // closed, so there is nothing there to compare against null. What a live
    // handle buys is a raw read through the `c` route, and that is what this
    // asserts: the context is open, and its level reads back as the default.
    var raw_level: zstd.Level = undefined;
    const raw_read = zstd.c.ZSTD_CCtx_getParameter(
        ctx.handle(),
        @intCast(@intFromEnum(zstd.CParameter.compression_level)),
        &raw_level,
    );
    try testing.expect(!zstd.isError(raw_read));
    try testing.expectEqual(zstd.default_level, raw_level);
    ctx.deinit();
    try testing.expect(!ctx.isOpen());
    // A second `deinit` on the same variable is a no-op rather than a second
    // free: `deinit` clears the field before it calls `ZSTD_freeCCtx`.
    ctx.deinit();
    try testing.expect(!ctx.isOpen());

    var dctx = try zstd.Dctx.init();
    defer dctx.deinit();
    var cstream = try zstd.CStream.init();
    defer cstream.deinit();
    var dstream = try zstd.DStream.init();
    defer dstream.deinit();

    // Two contexts do not share state: setting a parameter on one leaves the
    // other alone, which is the reason upstream says to use one per thread
    // (`src/lib/zstd.h:273-276`). `ctx` was freed above and its handle is gone,
    // so this is `other` that takes the setting and a second live context that
    // proves the two do not read each other.
    var other = try zstd.Ctx.init();
    defer other.deinit();
    var peer = try zstd.Ctx.init();
    defer peer.deinit();
    try other.setLevel(1);
    try testing.expectEqual(@as(zstd.Level, 1), try other.level());
    try testing.expectEqual(zstd.default_level, try peer.level());
}

test "a frame header of fewer than five bytes cannot be read" {
    nativeReady();

    // `ZSTD_FRAMEHEADERSIZE_PREFIX` is 5 (`src/lib/zstd.h:1257`): four of magic
    // plus the descriptor. Anything shorter is `srcSize_wrong`, from
    // `src/lib/decompress/zstd_decompress.c:419`.
    try testing.expectEqual(@as(usize, 5), zstd.frame_header_size_prefix);
    const short = rfc_magic[0..4];
    try testing.expectError(error.SrcSizeWrong, zstd.frameHeaderSize(short));
    try testing.expectError(error.SrcSizeWrong, zstd.findFrameCompressedSize(short));

    // Bytes that are neither a zstd magic nor a skippable one are refused with
    // `prefix_unknown`, which `src/lib/decompress/zstd_decompress.c:473` and
    // `:493` raise.
    //
    // Sixteen bytes, not eight: `ZSTD_decompressFrame` checks its length before
    // it reads the magic, and the floor is `ZSTD_FRAMEHEADERSIZE_MIN +
    // ZSTD_blockHeaderSize` - 6 + 3 = 9 (`:967-969`). Below that the refusal is
    // `srcSize_wrong`, whatever the bytes are, so a short buffer would report
    // the length gate rather than the prefix gate.
    const garbage = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    try testing.expect(!zstd.isSkippableFrame(&garbage));
    try testing.expectEqual(zstd.ContentSize.undecodable, zstd.frameContentSize(&garbage));
    try testing.expectEqual(
        zstd.ErrorCode.prefix_unknown,
        zstd.errorCode(zstd.c.ZSTD_findFrameCompressedSize(&garbage, garbage.len)),
    );
    var dst: [64]u8 = undefined;
    try testing.expectError(error.NotAZstdFrame, zstd.decompress(&dst, &garbage));

    // And below that floor the same bytes are refused for their length, which
    // is the gate the five-byte prefix answers above and a different one from
    // the prefix gate.
    try testing.expectError(error.SrcSizeWrong, zstd.decompress(&dst, garbage[0..8]));
}