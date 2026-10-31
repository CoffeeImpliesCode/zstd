// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioural tests for the Zstandard facade.
//! Oracles come from RFC 8878, upstream golden frames, and recorded producer output.
//! Producer versions and fixture digests are recorded in `fixtures/PROVENANCE.md`.
//! Test-owned buffers use `testing.allocator`; libzstd owns its internal allocations.

const std = @import("std");
const zstd = @import("zstd");
const testing = std.testing;

/// Provider path environment variable for runtime-loading tests.
const provider_variable = "ZSTD_TEST_PROVIDER";

/// RFC 8878 frame magic, stored little-endian.
const rfc_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

/// A valid skippable-frame magic from RFC 8878 §3.1.2, stored little-endian.
const rfc_skippable_magic = [_]u8{ 0x53, 0x2a, 0x4d, 0x18 };

/// Load the runtime provider once; linked builds need no setup.
/// Missing or invalid `ZSTD_TEST_PROVIDER` aborts the suite instead of skipping tests.
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

/// Frame_Header_Descriptor fields decoded from RFC 8878 Table 3.
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

/// RFC 8878 FCS_Field_Size; flag 0 is one byte only for single-segment frames.
fn fcsFieldSize(d: Descriptor) usize {
    return switch (d.fcs_flag) {
        0 => if (d.single_segment) 1 else 0,
        1 => 2,
        2 => 4,
        3 => 8,
    };
}

/// RFC 8878 DID_Field_Size for the four Dictionary_ID_flag values.
fn didFieldSize(d: Descriptor) usize {
    return switch (d.dict_id_flag) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
    };
}

/// Compute the RFC frame-header size from its descriptor and optional fields.
fn frameHeaderSizeFromRfc(frame: []const u8) usize {
    const d = decodeDescriptor(frame[4]);
    // Explicit `usize` avoids mixing runtime and comptime values in the sum.
    const window_descriptor: usize = if (d.single_segment) 0 else 1;
    return 4 + 1 + window_descriptor + didFieldSize(d) + fcsFieldSize(d);
}

/// Block_Header fields decoded from RFC 8878 Table 9.
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

/// Decompress a known-size frame into a test-owned buffer.
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

const raw_block_frame: []const u8 = @embedFile("fixtures/rfc8878/raw-block.zst");
const raw_block_plain: []const u8 = @embedFile("fixtures/rfc8878/raw-block.plain");
const rle_block_frame: []const u8 = @embedFile("fixtures/rfc8878/rle-block.zst");
const rle_block_plain: []const u8 = @embedFile("fixtures/rfc8878/rle-block.plain");
const skippable_frame: []const u8 = @embedFile("fixtures/rfc8878/skippable-plus-frame.zst");
const skippable_plain: []const u8 = @embedFile("fixtures/rfc8878/skippable-plus-frame.plain");

const golden_rle_first: []const u8 = @embedFile("src/tests/golden-decompression/rle-first-block.zst");
const golden_empty: []const u8 = @embedFile("src/tests/golden-decompression/empty-block.zst");
const golden_zero_seq: []const u8 = @embedFile("src/tests/golden-decompression/zeroSeq_2B.zst");
const golden_block_128k: []const u8 = @embedFile("src/tests/golden-decompression/block-128k.zst");

/// Upstream-invalid frame; extra Sequences bytes trigger corruption.
/// `src/lib/decompress/zstd_decompress_block.c:723-724` checks this.
const golden_error_extraneous: []const u8 =
    @embedFile("src/tests/golden-decompression-errors/zeroSeq_extraneous.zst");

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

    try testing.expectEqualSlices(u8, &rfc_magic, raw_block_frame[0..4]);

    // RFC Table 3: 0x20 is single-segment, with checksum and dictionary ID clear.
    try testing.expectEqual(@as(u8, 0x20), raw_block_frame[4]);
    const descriptor = decodeDescriptor(raw_block_frame[4]);
    try testing.expectEqual(@as(u2, 0), descriptor.fcs_flag);
    try testing.expect(descriptor.single_segment);
    try testing.expect(!descriptor.unused);
    try testing.expect(!descriptor.reserved);
    try testing.expect(!descriptor.checksum);
    try testing.expectEqual(@as(u2, 0), descriptor.dict_id_flag);

    // Single-segment FCS flag 0 means one size byte; the header is six bytes.
    try testing.expectEqual(@as(usize, 1), fcsFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 0), didFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(raw_block_frame));
    try testing.expectEqual(@as(u8, 26), raw_block_frame[5]);

    // Table 9: final raw block with 26 bytes.
    const block = decodeBlockHeader(raw_block_frame, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 0), block.block_type);
    try testing.expectEqual(@as(u21, 26), block.size);

    // The library derives the same header size from the descriptor.
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(raw_block_frame));
    try testing.expectEqual(zstd.ContentSize{ .known = 26 }, zstd.frameContentSize(raw_block_frame));
    try testing.expectEqual(@as(usize, 35), try zstd.findFrameCompressedSize(raw_block_frame));
    // No dictionary-ID field means upstream returns 0.
    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(raw_block_frame));
    try testing.expect(!zstd.isSkippableFrame(raw_block_frame));

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
    // The one-byte FCS declares 200 bytes.
    try testing.expectEqual(@as(u8, 200), rle_block_frame[5]);

    // Table 9: final RLE block with a size of 200.
    const block = decodeBlockHeader(rle_block_frame, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 1), block.block_type);
    try testing.expectEqual(@as(u21, 200), block.size);

    // RFC 8878 §3.1.1.2.2 defines an RLE block as one repeated byte.
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

    // RFC 8878 §3.1.2: four-byte magic and four-byte payload length.
    try testing.expectEqualSlices(u8, &rfc_skippable_magic, skippable_frame[0..4]);
    try testing.expectEqual(zstd.magic_skippable_start + 3, std.mem.readInt(u32, skippable_frame[0..4], .little));
    const payload_len = std.mem.readInt(u32, skippable_frame[4..8], .little);
    try testing.expectEqual(@as(u32, 45), payload_len);
    const skippable_total = 8 + payload_len;
    try testing.expectEqual(@as(usize, 53), skippable_total);
    try testing.expectEqualSlices(u8, "zlib-foundation-sdk interop provenance marker", skippable_frame[8..53]);

    // Upstream counts the full skippable frame, including its payload.
    try testing.expect(zstd.isSkippableFrame(skippable_frame));
    try testing.expectEqual(@as(usize, 53), try zstd.findFrameCompressedSize(skippable_frame));

    // The size query returns 0 for skippable frames, as for empty frames.
    try testing.expectEqual(@as(u64, 0), zstd.frameContentSize(skippable_frame).get().?);

    // Upstream's header-size query handles standard formats only and returns 7 here.
    // Use `findFrameCompressedSize` for the skippable frame's actual size.
    try testing.expectEqual(@as(usize, 7), try zstd.frameHeaderSize(skippable_frame));
    try testing.expectEqual(@as(usize, 8), zstd.skippable_header_size);

    // The fixture appends a raw-block frame after the skippable payload.
    try testing.expectEqualSlices(u8, raw_block_frame, skippable_frame[skippable_total..]);
    try testing.expectEqual(@as(usize, 88), skippable_frame.len);

    // The skippable payload contributes no output.
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
    // A standalone skippable frame decodes to zero bytes (upstream skips it).
    try testing.expectEqual(@as(usize, 0), read);
}

test "upstream golden: rle-first-block decodes to the 1 MiB of zeros the RFC implies" {
    nativeReady();

    // FHD 0xa4 carries a four-byte FCS; this single-segment header is 9 bytes.
    try testing.expectEqual(@as(u8, 0xa4), golden_rle_first[4]);
    const descriptor = decodeDescriptor(golden_rle_first[4]);
    try testing.expectEqual(@as(u2, 2), descriptor.fcs_flag);
    try testing.expect(descriptor.single_segment);
    try testing.expect(descriptor.checksum);
    try testing.expectEqual(@as(usize, 4), fcsFieldSize(descriptor));
    try testing.expectEqual(@as(usize, 9), frameHeaderSizeFromRfc(golden_rle_first));
    try testing.expectEqual(@as(u32, 1048576), std.mem.readInt(u32, golden_rle_first[5..9], .little));

    // Eight four-byte RLE blocks and a checksum account for the full fixture.
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
    // RFC 8878 §3.1.1.2.2 defines each RLE block as one repeated byte.
    try testing.expectEqual(@as(usize, 1048576), 8 * 131072);

    try testing.expectEqual(@as(usize, 9), try zstd.frameHeaderSize(golden_rle_first));
    try testing.expectEqual(
        zstd.ContentSize{ .known = 1048576 },
        zstd.frameContentSize(golden_rle_first),
    );
    // Frame size includes its trailing checksum.
    try testing.expectEqual(@as(usize, 45), try zstd.findFrameCompressedSize(golden_rle_first));

    const decoded = try decodeExactly(golden_rle_first, 1048576);
    defer testing.allocator.free(decoded);
    for (decoded) |byte| try testing.expectEqual(@as(u8, 0x00), byte);
}

test "upstream golden: empty-block carries no content size and decodes to nothing" {
    nativeReady();

    // FHD 0 has no FCS field and includes a Window_Descriptor.
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
    // FHD 0 also indicates no content-size field.
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_zero_seq));

    // One compressed block holds 16 bytes; RFC 8878 marks its literals as raw.
    const block = decodeBlockHeader(golden_zero_seq, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    try testing.expectEqual(@as(u21, 16), block.size);
    try testing.expectEqual(@as(usize, 25), golden_zero_seq.len);
    try testing.expectEqual(@as(usize, 6 + 3 + 16), golden_zero_seq.len);

    // RFC 8878 §3.1.1.3.1.1: 0x68 marks 13 raw literal bytes at offset 9.
    const literals_header = golden_zero_seq[9];
    try testing.expectEqual(@as(u2, 0), @as(u2, @truncate(literals_header & 0x03)));
    try testing.expectEqual(@as(u2, 2), @as(u2, @truncate(literals_header >> 2)));
    const regenerated = @as(usize, literals_header >> 3);
    try testing.expectEqual(@as(usize, 13), regenerated);

    // Expected bytes come from system `zstd` CLI v1.5.7, not RFC decoding.
    // Compare every byte; a length-only check would miss corrupt output.
    const expected = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0a };
    try testing.expectEqualSlices(u8, &expected, golden_zero_seq[10..23]);
    try testing.expectEqualSlices(u8, "Hello World!\n", &expected);

    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_zero_seq));
    try testing.expectEqual(@as(usize, 25), try zstd.findFrameCompressedSize(golden_zero_seq));
    const decoded = try decodeExactly(golden_zero_seq, expected.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &expected, decoded);

    // Upstream errata lists v1.5.2 as the last affected release for this zero-sequence form.
    try testing.expectEqual(@as(u32, 10507), zstd.version_number);
}

test "upstream golden: a compressed block of exactly 128 KiB is accepted" {
    nativeReady();

    try testing.expectEqual(@as(u8, 0x00), golden_block_128k[4]);
    try testing.expectEqual(@as(usize, 6), frameHeaderSizeFromRfc(golden_block_128k));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_block_128k));

    // RFC Window_Descriptor 0x38 represents a 131072-byte window.
    const window_byte = golden_block_128k[5];
    try testing.expectEqual(@as(u8, 0x38), window_byte);
    const exponent = @as(u5, @truncate(window_byte >> 3));
    const mantissa = @as(u3, @truncate(window_byte & 0x07));
    try testing.expectEqual(@as(u5, 7), exponent);
    try testing.expectEqual(@as(u3, 0), mantissa);
    const window_size = @as(usize, 1) << @intCast(10 + exponent);
    try testing.expectEqual(@as(usize, 131072), window_size);
    try testing.expectEqual(zstd.block_size_max, window_size);

    // Upstream errata records this block size as rejected through v1.5.2.
    const block = decodeBlockHeader(golden_block_128k, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    try testing.expectEqual(@as(u21, 131072), block.size);
    try testing.expectEqual(@as(usize, 131081), golden_block_128k.len);
    try testing.expectEqual(@as(usize, 6 + 3 + 131072), golden_block_128k.len);

    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_block_128k));
    try testing.expectEqual(@as(usize, 131081), try zstd.findFrameCompressedSize(golden_block_128k));

    // Assert the RFC output bound only; this test does not decode compressed blocks.
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

    // Upstream rejects this fixture because its Sequences section has extra bytes.
    try testing.expectEqual(@as(u8, 0x00), golden_error_extraneous[4]);
    const block = decodeBlockHeader(golden_error_extraneous, 6);
    try testing.expect(block.last);
    try testing.expectEqual(@as(u2, 2), block.block_type);
    // The block carries 18 bytes, two more than the valid fixture.
    try testing.expectEqual(@as(u21, 18), block.size);
    try testing.expectEqual(@as(usize, 27), golden_error_extraneous.len);

    // The frame header is readable; the content is what fails.
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(golden_error_extraneous));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(golden_error_extraneous));

    var dst: [4096]u8 = undefined;
    try testing.expectError(error.Corruption, zstd.decompress(&dst, golden_error_extraneous));

    // Use the raw route to assert the upstream code and message.
    const raw = zstd.c.ZSTD_decompress(&dst, dst.len, golden_error_extraneous.ptr, golden_error_extraneous.len);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.corruption_detected, zstd.errorCode(raw));
    // Upstream's message for `corruption_detected`.
    try testing.expectEqualStrings("Data corruption detected", zstd.errorName(raw));
    try testing.expectEqualStrings(
        "Data corruption detected",
        zstd.errorCodeText(zstd.ErrorCode.corruption_detected),
    );
}

test "upstream-interop frames decode to the recorded plaintext" {
    nativeReady();

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

        // Each fixture must contain exactly one complete frame.
        try testing.expectEqual(entry.frame.len, try zstd.findFrameCompressedSize(entry.frame));
    }
}

test "a windowed frame and a single-segment frame differ only in the descriptor" {
    nativeReady();

    // CLI FHD 0x24 carries a one-byte FCS and checksum; bare FHD 0x00 has neither.
    // Both headers are six bytes but use different optional fields.
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

    // Both headers are six bytes, but they use different optional fields.
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(cli_level_3));
    try testing.expectEqual(@as(usize, 6), try zstd.frameHeaderSize(pyzstd_bare_3));

    // The single-segment frame declares 232 bytes; the bare frame's size is unknown.
    try testing.expectEqual(@as(u8, 0xe8), cli_level_3[5]);
    try testing.expectEqual(zstd.ContentSize{ .known = 232 }, zstd.frameContentSize(cli_level_3));
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.frameContentSize(pyzstd_bare_3));

    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(cli_level_3));
    try testing.expectEqual(@as(u32, 0), zstd.dictIDFromFrame(pyzstd_bare_3));
}

test "the CLI and the binding are one implementation behind two producers" {
    nativeReady();

    // CLI and Python-binding fixtures are byte-identical at each level, not independent encoders.
    try testing.expectEqualSlices(u8, cli_level_1, pyzstd_level_1);
    try testing.expectEqualSlices(u8, cli_level_3, pyzstd_level_3);
    try testing.expectEqualSlices(u8, cli_level_19, pyzstd_level_19);

    // The single-threaded CLI fixture matches its default level-3 output.
    try testing.expectEqualSlices(u8, cli_level_3, cli_single_thread_3);

    // The `-22` fixture matches level 19 after upstream clamps to 22.
    try testing.expectEqualSlices(u8, cli_ultra_22, pyzstd_level_19);

    // `--no-check` removes the checksum and shortens the frame by four bytes.
    try testing.expectEqual(@as(usize, 136), cli_level_3.len);
    try testing.expectEqual(@as(usize, 132), cli_no_check_3.len);
    try testing.expectEqual(@as(usize, cli_level_3.len - 4), cli_no_check_3.len);
    try testing.expect(decodeDescriptor(cli_level_3[4]).checksum);
    try testing.expect(!decodeDescriptor(cli_no_check_3[4]).checksum);
}

test "compressBound is a bound, and it grows the way the macro says it must" {
    nativeReady();

    // Upstream's compression bound is never below the input size.
    const sizes = [_]usize{ 0, 1, 13, 26, 200, 232, 4096, 131071, 131072, 262144 };
    for (sizes) |size| {
        const bound = try zstd.compressBound(size);
        try testing.expect(bound >= size);
        // The comptime macro and runtime function must agree.
        try testing.expectEqual(bound, zstd.compressBoundConst(size));
    }
    try testing.expect(zstd.compressBoundConst(0) > 0);

    // Upstream guarantees bound subadditivity for inputs of at least 128 KiB.
    const a: usize = 131072;
    const b: usize = 262144;
    try testing.expectEqual(@as(usize, 131072), a);
    try testing.expectEqual(@as(usize, 262144), b);
    try testing.expect(
        (try zstd.compressBound(a)) + (try zstd.compressBound(b)) <=
            try zstd.compressBound(a + b),
    );

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

    // Upstream checks the block length before writing, so this truncation leaves `dst` untouched.
    var truncated: [9]u8 = undefined;
    @memcpy(&truncated, cli_level_3[0..9]);
    const block = decodeBlockHeader(cli_level_3, 6);
    try testing.expectEqual(@as(u21, 123), block.size);

    var dst: [256]u8 = @splat(0xa5);
    try testing.expectError(error.SrcSizeWrong, zstd.decompress(&dst, &truncated));
    for (dst) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // The raw route exposes the upstream source-size error name.
    const raw = zstd.c.ZSTD_decompress(&dst, dst.len, &truncated, truncated.len);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.src_size_wrong, zstd.errorCode(raw));
    try testing.expectEqualStrings("Src size is incorrect", zstd.errorName(raw));
    // An error result has a different name from the success result.
    try testing.expect(!std.mem.eql(u8, zstd.errorName(raw), zstd.errorName(0)));
    for (dst) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    const whole = try decodeExactly(cli_level_3, plain_payload.len);
    defer testing.allocator.free(whole);
    try testing.expectEqualSlices(u8, plain_payload, whole);
}

test "an out-of-range level is clamped and an out-of-range parameter is refused" {
    nativeReady();

    var ctx = try zstd.Ctx.init();
    defer ctx.deinit();

    // Upstream defines the maximum compression level as 22.
    try testing.expectEqual(@as(zstd.Level, 22), zstd.maxLevel());
    try testing.expect(zstd.maxLevel() >= zstd.default_level);
    // The minimum level is `-ZSTD_TARGETLENGTH_MAX`, or -131072 in this build.
    try testing.expectEqual(@as(zstd.Level, -131072), zstd.minLevel());
    try testing.expectEqual(@as(usize, 131072), zstd.block_size_max);

    // Compression levels clamp to bounds; other named parameters are refused out of bounds.
    // Read the clamped level back through `ZSTD_CCtx_getParameter`.
    try ctx.setLevel(zstd.maxLevel() + 1000);
    try testing.expectEqual(zstd.maxLevel(), try ctx.level());
    try ctx.setLevel(zstd.minLevel() - 1000);
    try testing.expectEqual(zstd.minLevel(), try ctx.level());
    try ctx.setLevel(7);
    try testing.expectEqual(@as(zstd.Level, 7), try ctx.level());

    // `targetLength` is bounded by `ZSTD_BLOCKSIZE_MAX` (131072).
    try testing.expectError(
        error.ParameterOutOfBound,
        ctx.setParameter(.target_length, 1 << 20),
    );

    // Refusal leaves the previous level and context usable.
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

    // Use `c` for an unknown ID because `CParameter` is a closed Zig enum.
    // `translate-c` represents upstream's C enum as an integer.
    const raw = zstd.c.ZSTD_CCtx_setParameter(ctx.handle(), @intCast(12345), 1);
    try testing.expect(zstd.isError(raw));
    try testing.expectEqual(zstd.ErrorCode.parameter_unsupported, zstd.errorCode(raw));
    try testing.expectEqualStrings(
        "Unsupported parameter",
        zstd.errorCodeText(zstd.ErrorCode.parameter_unsupported),
    );

    // Non-update parameters fail after a frame starts; one-shot compression closes it first.
    // Streaming leaves this frame open, while the eight authorized parameters remain settable.
    const bound = try zstd.compressBound(plain_payload.len);
    var frame = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame);
    const pledged = try ctx.compress(frame, plain_payload, 3);
    try testing.expect(pledged > 0);

    var stream_out = zstd.OutBuffer{ .dst = frame.ptr, .size = frame.len, .pos = 0 };
    var stream_in = zstd.InBuffer{ .src = plain_payload.ptr, .size = plain_payload.len, .pos = 0 };
    // The refusal proves the frame stays open; `stream2` returns buffered bytes, not status.
    // `.@"continue"` consumes input; `.@"end"` completes the frame when it returns 0.
    _ = try ctx.stream2(&stream_out, &stream_in, .@"continue");
    try testing.expectEqual(plain_payload.len, stream_in.pos);
    try testing.expectError(error.WrongStage, ctx.setParameter(.window_log, 10));
    // Update-authorized parameters remain settable mid-frame.
    try ctx.setParameter(.search_log, 3);
    try testing.expectEqual(@as(usize, 0), try ctx.stream2(&stream_out, &stream_in, .end));
    try testing.expect(stream_out.pos > 0);

    const again = try ctx.compress(frame, plain_payload, 3);
    const decoded = try decodeExactly(frame[0..again], plain_payload.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, plain_payload, decoded);

    // A pledged source size becomes the frame content-size field.
    try ctx.setPledgedSourceSize(@intCast(plain_payload.len));
    const with_size = try ctx.compress(frame, plain_payload, 3);
    try testing.expectEqual(
        zstd.ContentSize{ .known = @intCast(plain_payload.len) },
        zstd.frameContentSize(frame[0..with_size]),
    );
}

test "a trained dictionary carries an ID and round-trips through CDict and DDict" {
    nativeReady();

    // Dictionary samples need shared structure and at least eight bytes (`zdict.h:184-202`).
    // Each buffer reserves a NUL byte beyond its records; the trainer receives only records.
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
                // Avoid an aliased copy: `bufPrint` returns a slice into its output buffer.
                var digits: [number_len]u8 = undefined;
                const number = std.fmt.bufPrint(&digits, "{d:0>4}", .{index * 10 + record}) catch unreachable;
                @memcpy(sample[cursor..][0..number.len], number);
                cursor += number.len;
                sample[cursor] = '\n';
                cursor += 1;
            }
            // The terminator follows the records and is not part of the sample size.
            sample[cursor] = 0;
            out[index] = sample[0..cursor];
        }
        break :blk out;
    };
    // The longest word fills the last sample buffer; shorter samples use the same bound.
    try testing.expect(samples.len >= 8);
    try testing.expectEqual(sample_len, sample_ptrs[samples.len - 1].len);
    // All samples meet the 8-byte minimum and fit their buffers.
    for (sample_ptrs) |sample| {
        try testing.expect(sample.len >= 8);
        try testing.expect(sample.len <= sample_len);
    }

    var dict: [8192]u8 = undefined;
    const dict_len = try zstd.trainDictionary(testing.allocator, &dict, &sample_ptrs);
    try testing.expect(dict_len >= zstd.dict_size_min);
    try testing.expect(dict_len <= dict.len);
    const trained = dict[0..dict_len];

    // A trained dictionary has a nonzero ID.
    const id = zstd.dictID(trained);
    try testing.expect(id != 0);

    // The digested-compression path writes the dictionary ID into the frame.
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

    // Exercise both digested and raw dictionary paths.
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

    // Without the matching dictionary, the frame's dictionary ID is rejected.
    var plain_ctx = try zstd.Dctx.init();
    defer plain_ctx.deinit();
    try testing.expectError(
        error.DictionaryRejected,
        plain_ctx.decompress(via_dict, frame[0..written]),
    );
}

test "a context size smaller than the dictionary floor is refused" {
    nativeReady();

    // Upstream and the facade reject dictionary destinations below 256 bytes.
    var too_small: [16]u8 = undefined;
    const samples = [_][]const u8{"alpha bravo charlie delta echo foxtrot"};
    try testing.expectError(
        error.DstSizeTooSmall,
        zstd.trainDictionary(testing.allocator, &too_small, &samples),
    );
}

test "version, level and frame queries report the provider" {
    nativeReady();

    // Both version queries read the loaded provider.
    try testing.expectEqual(zstd.version_number, zstd.versionNumber());
    try testing.expectEqual(@as(u32, 10507), zstd.versionNumber());
    try testing.expectEqual(@as(u32, 1), zstd.version_major);
    try testing.expectEqual(@as(u32, 5), zstd.version_minor);
    try testing.expectEqual(@as(u32, 7), zstd.version_release);
    try testing.expectEqualStrings("1.5.7", zstd.versionString());
    try testing.expectEqualStrings(zstd.version_string_literal, zstd.versionString());
    try testing.expectEqual(zstd.default_level, @as(zstd.Level, 3));

    try testing.expectEqual(@as(u32, 0xFD2FB528), zstd.magic_number);
    try testing.expectEqual(@as(u32, 0x184D2A50), zstd.magic_skippable_start);
    try testing.expectEqual(@as(u32, 0xFFFFFFF0), zstd.magic_skippable_mask);
    try testing.expectEqual(@as(usize, 5), zstd.frame_header_size_prefix);
    try testing.expectEqual(@as(usize, 6), zstd.frame_header_size_min);
    try testing.expectEqual(@as(usize, 18), zstd.frame_header_size_max);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), zstd.content_size_unknown);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), zstd.content_size_error);

    // Successful results are not errors; unknown codes are not guessed at.
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
    // Upstream reserves the maximum error code rather than assigning a tag.
    try testing.expect(zstd.ErrorCode.fromCode(120) == null);
    try testing.expect(zstd.CParameter.fromCode(zstd.c.ZSTD_c_nbWorkers) == .nb_workers);
    try testing.expect(zstd.DParameter.fromCode(zstd.c.ZSTD_d_windowLogMax) == .window_log_max);
}

test "streaming compression and decompression carry the same bytes" {
    nativeReady();

    // Exercise both streaming wrappers in addition to the external oracles.
    var cstream = try zstd.CStream.init();
    defer cstream.deinit();
    try cstream.initLevel(3);

    var out_buf: [1024]u8 = undefined;
    var written: usize = 0;
    var fed: usize = 0;
    while (fed < plain_payload.len) {
        const take = @min(@as(usize, 64), plain_payload.len - fed);
        const end: zstd.EndOp = if (fed + take == plain_payload.len) .end else .@"continue";
        var input = zstd.InBuffer{
            .src = plain_payload[fed..].ptr,
            .size = take,
            .pos = 0,
        };
        var output = zstd.OutBuffer{ .dst = out_buf[written..].ptr, .size = out_buf.len - written, .pos = 0 };
        const hint = try cstream.compress(&output, &input, end);
        written += output.pos;
        fed += input.pos;
        // A finished frame has a zero hint.
        if (end == .end) try testing.expectEqual(@as(usize, 0), hint);
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

    // Recommended buffer sizes are guidance, not payload-specific guarantees.
    try testing.expect(zstd.cStreamInSize() > 0);
    try testing.expect(zstd.cStreamOutSize() > 0);
    try testing.expect(zstd.dStreamInSize() > 0);
    try testing.expect(zstd.dStreamOutSize() > 0);
}

test "each context frees exactly once and two contexts are independent" {
    nativeReady();

    var ctx = try zstd.Ctx.init();
    try testing.expect(ctx.isOpen());
    // A live handle permits raw C queries; a closed handle panics.
    var raw_level: zstd.Level = undefined;
    const raw_read = zstd.c.ZSTD_CCtx_getParameter(
        ctx.handle(),
        @intCast(@backingInt(zstd.CParameter.compression_level)),
        &raw_level,
    );
    try testing.expect(!zstd.isError(raw_read));
    try testing.expectEqual(zstd.default_level, raw_level);
    ctx.deinit();
    try testing.expect(!ctx.isOpen());
    // `deinit` clears the field, so repeating it does not free twice.
    ctx.deinit();
    try testing.expect(!ctx.isOpen());

    var dctx = try zstd.Dctx.init();
    defer dctx.deinit();
    var cstream = try zstd.CStream.init();
    defer cstream.deinit();
    var dstream = try zstd.DStream.init();
    defer dstream.deinit();

    // Separate contexts keep independent parameters, as upstream recommends per thread.
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

    // The five-byte minimum prefix means shorter input fails the length check.
    try testing.expectEqual(@as(usize, 5), zstd.frame_header_size_prefix);
    const short = rfc_magic[0..4];
    try testing.expectError(error.SrcSizeWrong, zstd.frameHeaderSize(short));
    try testing.expectError(error.SrcSizeWrong, zstd.findFrameCompressedSize(short));

    // A 16-byte input passes the length gate and reaches the invalid-magic check.
    // Eight bytes fail earlier with `SrcSizeWrong`, before upstream reads the magic.
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

    // Below nine bytes, upstream reports `srcSize_wrong` before checking magic.
    try testing.expectError(error.SrcSizeWrong, zstd.decompress(&dst, garbage[0..8]));
}
