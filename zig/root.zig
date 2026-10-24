// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over Zstandard 1.5.7, backed by its C implementation.
//! Linked by default; runtime-loaded mode retains one provider for the process.
//! Contexts own upstream objects; `trainDictionary` uses the supplied allocator for scratch storage.

const std = @import("std");

/// Translated upstream C declarations, including experimental APIs.
/// Calls use the same library as the facade and retain upstream contracts.
pub const c = @import("c");

/// Loader types used by the linked configuration.
const rt = @import("rt");

/// Whether calls use a runtime-loaded provider rather than a linked library.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Select the runtime provider by explicit path or platform loader name.
/// The request is used as given; no fallback source is tried.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned by `load`.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load and retain a runtime provider; repeated identical requests are idempotent.
/// Different or reentrant requests fail; same-request callers wait; linked builds panic.
pub fn load(source: LoadSource) LoadError!void {
    // `c.load` exists only in runtime mode; comptime removes this branch for linked builds.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "zstd: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// Return the successful provider request, or null before loading and in linked builds.
/// The retained request remains valid for the process lifetime.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// Zstandard compression level; 0 selects `default_level`, and bounds are `minLevel`/`maxLevel`.
pub const Level = c_int;

/// Default compression level from the selected headers.
pub const default_level: Level = c.ZSTD_CLEVEL_DEFAULT;

/// Numeric release advertised by the selected headers and required of runtime providers.
pub const version_number: u32 = c.ZSTD_VERSION_NUMBER;

/// The major component of `version_number`, 1 (`src/lib/zstd.h:112`).
pub const version_major: u32 = c.ZSTD_VERSION_MAJOR;

/// The minor component of `version_number`, 5 (`src/lib/zstd.h:113`).
pub const version_minor: u32 = c.ZSTD_VERSION_MINOR;

/// The release component of `version_number`, 7 (`src/lib/zstd.h:114`).
pub const version_release: u32 = c.ZSTD_VERSION_RELEASE;

/// Compile-time version string from the selected headers; it does not query the library.
/// Use `versionString` for the linked or runtime provider's own report.
pub const version_string_literal: [:0]const u8 = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    c.ZSTD_VERSION_MAJOR,
    c.ZSTD_VERSION_MINOR,
    c.ZSTD_VERSION_RELEASE,
});

/// Standard Zstandard frame magic (`0xFD2FB528`), stored as `28 b5 2f fd` on wire.
pub const magic_number: u32 = c.ZSTD_MAGICNUMBER;

/// First of the sixteen skippable-frame magic numbers.
pub const magic_skippable_start: u32 = c.ZSTD_MAGIC_SKIPPABLE_START;

/// Mask that identifies the skippable-frame magic family.
pub const magic_skippable_mask: u32 = c.ZSTD_MAGIC_SKIPPABLE_MASK;

/// Minimum input length for standard-format header queries: five bytes.
pub const frame_header_size_prefix: usize = c.ZSTD_FRAMEHEADERSIZE_PREFIX(c.ZSTD_f_zstd1);

/// Minimum complete standard-format frame header: six bytes.
pub const frame_header_size_min: usize = c.ZSTD_FRAMEHEADERSIZE_MIN(c.ZSTD_f_zstd1);

/// Maximum standard-format frame header size: 18 bytes.
pub const frame_header_size_max: usize = c.ZSTD_FRAMEHEADERSIZE_MAX;

/// Fixed skippable-frame header size: four magic bytes and four length bytes.
pub const skippable_header_size: usize = c.ZSTD_SKIPPABLEHEADERSIZE;

/// Maximum decompressed block size: 131072 bytes.
pub const block_size_max: usize = c.ZSTD_BLOCKSIZE_MAX;

/// Sentinel for a frame with no declared content size; computed as upstream's 64-bit value.
pub const content_size_unknown: u64 = std.math.maxInt(u64);

/// Sentinel for a frame whose header cannot be decoded.
pub const content_size_error: u64 = std.math.maxInt(u64) - 1;

/// Stable named compression parameters exposed by upstream's headers.
/// Most require an initial context stage; compression levels clamp to their bounds.
pub const CParameter = enum(c_int) {
    /// Predefined level table; out-of-range levels clamp instead of erroring.
    /// Bounds are upstream's `ZSTD_minCLevel` to `ZSTD_maxCLevel`.
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
    /// Target compressed super-block size.
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
    /// Whether the frame header carries the content size (`zstd_compress.c:475-478`).
    content_size_flag = c.ZSTD_c_contentSizeFlag,
    /// Whether the frame carries a trailing content checksum (`zstd_compress.c:480-483`).
    checksum_flag = c.ZSTD_c_checksumFlag,
    /// Whether the frame header carries a dictionary ID (`zstd_compress.c:485-488`).
    dict_id_flag = c.ZSTD_c_dictIDFlag,
    /// Worker count; nonzero values are unsupported because this build omits multithreading.
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

/// Stable named decompression parameter; experimental IDs are not exposed.
pub const DParameter = enum(c_int) {
    /// Maximum decompression window log; 0 selects upstream's default.
    window_log_max = c.ZSTD_d_windowLogMax,

    /// The upstream number, for a parameter this facade does not name.
    pub fn fromCode(code: c_int) ?DParameter {
        return switch (code) {
            c.ZSTD_d_windowLogMax => .window_log_max,
            else => null,
        };
    }
};

/// Streaming compression operation.
pub const EndOp = enum(c_int) {
    /// Collect more data; the encoder decides when to emit a block.
    @"continue" = c.ZSTD_e_continue,
    /// Emit at least one decodable block now and keep the frame open.
    flush = c.ZSTD_e_flush,
    /// Flush and close the frame; continue until the call returns 0.
    end = c.ZSTD_e_end,
};

/// Select whether a reset clears the session, parameters, or both.
pub const Reset = enum(c_int) {
    /// Stop the current frame; parameters and dictionary stay.
    session_only = c.ZSTD_reset_session_only,
    /// Parameters and dictionary go back to their defaults; the session stays.
    parameters = c.ZSTD_reset_parameters,
    /// Both.
    session_and_parameters = c.ZSTD_reset_session_and_parameters,
};

/// C-compatible streaming input buffer.
/// `pos` is the caller's cursor; the C API reads through this struct.
pub const InBuffer = c.ZSTD_inBuffer;

/// C-compatible streaming output buffer; the C API updates `pos`.
pub const OutBuffer = c.ZSTD_outBuffer;

/// Numeric upstream error codes, including codes not produced by this build.
/// Values marked unstable by upstream remain identifiable through `unstable_*` tags.
pub const ErrorCode = enum(c_int) {
    /// Successful result; not an error.
    no_error = c.ZSTD_error_no_error,
    /// `ZSTD_error_GENERIC` (`:62`).
    generic = c.ZSTD_error_GENERIC,
    /// Input is neither a Zstandard nor a skippable frame.
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
    /// The call is invalid in the context's current stage.
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

    /// Code outside this enum; future upstream values remain unclassified.
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

    /// Whether upstream marks this code as unstable.
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

/// Errors returned by typed wrappers in this build.
/// Unstable or unrecognized codes map to `UnstableCode`.
pub const Error = error{
    /// A generic failure: `ZSTD_error_GENERIC`, `src/lib/zstd_errors.h:62`.
    Generic,
    /// Input is neither a Zstandard nor a skippable frame.
    NotAZstdFrame,
    /// Frame header contains an unsupported parameter or reserved bit.
    FrameParameterUnsupported,
    /// Frame window exceeds the configured limit.
    WindowTooLarge,
    /// Frame content is invalid.
    Corruption,
    /// Trailing content checksum did not match.
    ChecksumMismatch,
    /// Literals-section header is malformed.
    LiteralsHeaderWrong,
    /// Dictionary data is corrupted.
    DictionaryCorrupted,
    /// Dictionary ID does not match the frame.
    DictionaryRejected,
    /// Dictionary training failed.
    DictionaryTrainingFailed,
    /// Parameter is unknown or unsupported.
    ParameterUnsupported,
    /// Parameter combination is unsupported.
    ParameterCombinationUnsupported,
    /// Parameter value is out of bounds; compression levels clamp instead.
    ParameterOutOfBound,
    /// Table logarithm exceeds the supported range.
    TableLogTooLarge,
    /// FSE or Huffman alphabet exceeds the bitstream limit.
    MaxSymbolValueTooLarge,
    /// FSE or Huffman alphabet is below the bitstream minimum.
    MaxSymbolValueTooSmall,
    /// Requested mode cannot emit an uncompressed block.
    CannotProduceUncompressedBlock,
    /// Pledged input buffer changed before compression completed.
    StabilityConditionNotRespected,
    /// Call is invalid at the context's current stage.
    WrongStage,
    /// Context was used before initialization.
    InitMissing,
    /// Upstream allocation failed.
    OutOfMemory,
    /// Workspace is too small for the operation.
    WorkSpaceTooSmall,
    /// Destination cannot hold the output.
    DstSizeTooSmall,
    /// Source length does not match the frame.
    SrcSizeWrong,
    /// Required destination buffer is null.
    DstBufferNull,
    /// Repeated calls made no progress because output was full.
    NoForwardProgressDstFull,
    /// Repeated calls made no progress because input was empty.
    NoForwardProgressInputEmpty,
    /// Experimental or unrecognized error code.
    UnstableCode,
};

/// Lowest supported compression level; values below it clamp rather than fail.
pub fn minLevel() Level {
    return c.ZSTD_minCLevel();
}

/// Highest supported compression level.
pub fn maxLevel() Level {
    return c.ZSTD_maxCLevel();
}

/// Numeric release reported by the loaded libzstd provider.
pub fn versionNumber() u32 {
    return c.ZSTD_versionNumber();
}

/// NUL-terminated release string reported by the provider.
/// The returned slice borrows provider-owned memory for the process lifetime.
pub fn versionString() [:0]const u8 {
    return std.mem.span(c.ZSTD_versionString());
}

/// Test a `size_t` result with upstream's version-independent error predicate.
pub fn isError(result: usize) bool {
    return c.ZSTD_isError(result) != 0;
}

/// Return upstream's message for a result, including its success message.
pub fn errorName(result: usize) [:0]const u8 {
    return std.mem.span(c.ZSTD_getErrorName(result));
}

/// Return the upstream code for a result; unknown codes map to `.unrecognised`.
pub fn errorCode(result: usize) ErrorCode {
    return ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised;
}

/// Return upstream's text for an error code, or a local description if unknown.
pub fn errorCodeText(code: ErrorCode) [:0]const u8 {
    // `.unrecognised` has no upstream numeric code.
    switch (code) {
        .unrecognised => return "an error code outside Zstandard's own taxonomy",
        else => {},
    }
    return std.mem.span(c.ZSTD_getErrorString(@intCast(@backingInt(code))));
}

/// Return the maximum compressed size for `src_len` bytes.
/// Oversized input returns `error.SrcSizeWrong`.
pub fn compressBound(src_len: usize) Error!usize {
    return checked(c.ZSTD_compressBound(src_len));
}

/// Comptime macro variant of `compressBound`; oversized input returns 0.
/// It casts to `u64` before expansion so the macro also works on 32-bit targets.
pub fn compressBoundConst(src_len: usize) usize {
    return @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(u64, src_len))));
}

/// Return an upper bound for decompression output across all frames.
/// Upstream rejects legacy v0.5-v0.7 frames here, though `decompress` accepts them.
pub fn decompressBound(src: []const u8) Error!u64 {
    const result = c.ZSTD_decompressBound(src.ptr, src.len);
    if (result == content_size_error) return error.NotAZstdFrame;
    return result;
}

/// Classify the first frame's declared size as known, unknown or undecodable.
/// Skippable frames report `.known(0)`; use `isSkippableFrame` to distinguish them.
pub fn frameContentSize(src: []const u8) ContentSize {
    return ContentSize.of(c.ZSTD_getFrameContentSize(src.ptr, src.len));
}

/// Return the first frame's dictionary ID, or 0 when no usable ID is available.
pub fn dictIDFromFrame(src: []const u8) u32 {
    return c.ZSTD_getDictID_fromFrame(src.ptr, src.len);
}

/// Return the first frame's full size, including checksum or skippable payload.
/// Use this to locate the next frame; `frameHeaderSize` does not handle skippable frames.
pub fn findFrameCompressedSize(src: []const u8) Error!usize {
    return checked(c.ZSTD_findFrameCompressedSize(src.ptr, src.len));
}

/// Return the first standard-format header size without decoding its payload.
/// Short input errors; skippable frames are not supported, so use `findFrameCompressedSize`.
pub fn frameHeaderSize(src: []const u8) Error!usize {
    return checked(c.ZSTD_frameHeaderSize(src.ptr, src.len));
}

/// Whether `src` starts with one of the sixteen skippable-frame magic numbers.
pub fn isSkippableFrame(src: []const u8) bool {
    return c.ZSTD_isSkippableFrame(src.ptr, src.len) != 0;
}

/// Compress `src` into `dst`; `dst` must fit `compressBound(src.len)`.
/// This allocates a fresh context; use `Ctx.compress` to reuse one.
pub fn compress(dst: []u8, src: []const u8, level: Level) Error!usize {
    return checked(c.ZSTD_compress(dst.ptr, dst.len, src.ptr, src.len, level));
}

/// Decompress all frames in `src` into `dst`; size the destination with `decompressBound`.
/// Skippable frames are skipped; errors can leave output from earlier blocks.
pub fn decompress(dst: []u8, src: []const u8) Error!usize {
    return checked(c.ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len));
}

/// Recommended input buffer size for streaming compression.
pub fn cStreamInSize() usize {
    return c.ZSTD_CStreamInSize();
}

/// Recommended output buffer size for streaming compression.
pub fn cStreamOutSize() usize {
    return c.ZSTD_CStreamOutSize();
}

/// Recommended input buffer size for streaming decompression.
pub fn dStreamInSize() usize {
    return c.ZSTD_DStreamInSize();
}

/// Recommended output buffer size for streaming decompression.
pub fn dStreamOutSize() usize {
    return c.ZSTD_DStreamOutSize();
}

/// Owns one upstream compression context, freed by `deinit`.
/// Copying the struct copies ownership; do not free multiple copies.
pub const Ctx = struct {
    /// The owned context, or null after `deinit`.
    raw: ?*c.ZSTD_CCtx = null,

    /// `init` can fail only when upstream cannot allocate a context.
    pub const InitError = error{OutOfMemory};

    /// Create a context with the default level and no pledged source size.
    pub fn init() InitError!Ctx {
        const raw = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Create a context with the given compression level.
    pub fn initWithLevel(new_level: Level) InitError!Ctx {
        var self = try init();
        errdefer self.deinit();
        self.setLevelNoFail(new_level);
        return self;
    }

    /// Free the context through the provider that created it, then clear the field.
    /// Repeated calls on the same variable are safe.
    pub fn deinit(self: *Ctx) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCCtx(raw);
    }

    /// Whether the context is still open.
    pub fn isOpen(self: *const Ctx) bool {
        return self.raw != null;
    }

    /// Return the raw context for unwrapped C calls; panics after `deinit`.
    pub fn handle(self: *const Ctx) *c.ZSTD_CCtx {
        return self.raw orelse @panic(
            "zstd: this Ctx was freed; deinit() clears the handle and there is " ++
                "no context left to call. Check isOpen() if the lifetime is not " ++
                "obvious.",
        );
    }

    /// Set the compression level; out-of-range values clamp to `minLevel`/`maxLevel`.
    /// Read back with `level` if the clamped value matters.
    pub fn setLevel(self: *Ctx, new_level: Level) Error!void {
        try self.setParameter(.compression_level, new_level);
    }

    /// Return the level currently set on this context.
    pub fn level(self: *Ctx) Error!Level {
        return self.getParameter(.compression_level);
    }

    /// Set a named compression parameter.
    /// Most changes require an initial frame stage; out-of-range values error except levels.
    pub fn setParameter(self: *Ctx, param: CParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@backingInt(param)), value));
    }

    /// Read a compression parameter from the context.
    /// Upstream marks this query `ZSTDLIB_STATIC_API`.
    pub fn getParameter(self: *Ctx, param: CParameter) Error!Level {
        var value: Level = undefined;
        try checkedVoid(c.ZSTD_CCtx_getParameter(self.handle(), @intCast(@backingInt(param)), &value));
        return value;
    }

    /// Set a level during initialization without checking the result.
    fn setLevelNoFail(self: *Ctx, new_level: Level) void {
        _ = c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@backingInt(CParameter.compression_level)), new_level);
    }

    /// Tell the encoder the input size; this enables the frame content-size field.
    pub fn setPledgedSourceSize(self: *Ctx, size: u64) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setPledgedSrcSize(self.handle(), size));
    }

    /// Compress one buffer with this context; advanced parameters are ignored.
    /// Use `stream2` when context parameters must apply.
    pub fn compress(self: *Ctx, dst: []u8, src: []const u8, new_level: Level) Error!usize {
        return checked(c.ZSTD_compressCCtx(self.handle(), dst.ptr, dst.len, src.ptr, src.len, new_level));
    }

    /// Compress one streaming step, updating both buffers' `pos` fields.
    /// Continue until `.@"end"` returns 0; context parameters apply.
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
            @intCast(@backingInt(endOp)),
        ));
    }

    /// Reset the session, parameters, or both.
    pub fn reset(self: *Ctx, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_CCtx_reset(self.handle(), @intCast(@backingInt(directive))));
    }

    /// Compress with a digested dictionary; its level and frame parameters are fixed at creation.
    /// The resulting frame carries the dictionary ID.
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

/// Owns one upstream decompression context, freed by `deinit`.
/// Reuse it to decode multiple buffers without allocating a context each time.
pub const Dctx = struct {
    /// The owned context, or null after `deinit`.
    raw: ?*c.ZSTD_DCtx = null,

    /// `init` can fail only when upstream cannot allocate a context.
    pub const InitError = error{OutOfMemory};

    /// Create a decompression context.
    pub fn init() InitError!Dctx {
        const raw = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and clear the field; repeated calls on the same variable are safe.
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

    /// Set a decompression parameter before frame decoding; later changes return `error.WrongStage`.
    /// Upstream restricts this to frame initialization (`src/lib/zstd.h:683-686`).
    pub fn setParameter(self: *Dctx, param: DParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_DCtx_setParameter(self.handle(), @intCast(@backingInt(param)), value));
    }

    /// Decompress all frames into `dst`, using this context as the workspace.
    /// Unlike `ZSTD_decompress`, `ZSTD_decompressDCtx` does not allocate (`src/lib/zstd.h:1197`).
    pub fn decompress(self: *Dctx, dst: []u8, src: []const u8) Error!usize {
        return checked(c.ZSTD_decompressDCtx(self.handle(), dst.ptr, dst.len, src.ptr, src.len));
    }

    /// Decompress with a dictionary borrowed only for this call.
    /// Upstream loads it into the context before decompression (`src/lib/zstd.h:960-976`).
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

    /// Reset the context according to the requested directive.
    pub fn reset(self: *Dctx, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_DCtx_reset(self.handle(), @intCast(@backingInt(directive))));
    }

    /// Decompress with a read-only digested dictionary that can be shared between threads.
    /// Upstream recommends this for repeated use (`src/lib/zstd.h:1033`).
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

/// Owns a streaming compression context, an upstream alias of `ZSTD_CCtx`.
/// Use it for incremental input; `deinit` frees the context.
pub const CStream = struct {
    /// The owned context, or null after `deinit`.
    raw: ?*c.ZSTD_CStream = null,

    /// `init` can fail only when upstream cannot allocate a context.
    pub const InitError = error{OutOfMemory};

    /// Create a streaming compression context.
    pub fn init() InitError!CStream {
        const raw = c.ZSTD_createCStream() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and clear the field; repeated calls on the same variable are safe.
    pub fn deinit(self: *CStream) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCStream(raw);
    }

    /// Whether the context is still open.
    pub fn isOpen(self: *const CStream) bool {
        return self.raw != null;
    }

    /// Return the raw context for unwrapped C calls; panics after `deinit`.
    pub fn handle(self: *const CStream) *c.ZSTD_CStream {
        return self.raw orelse @panic(
            "zstd: this CStream was freed; deinit() clears the handle and there " ++
                "is no context left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }

    /// Start a frame at `level`, clearing staged state and any dictionary.
    pub fn initLevel(self: *CStream, level: Level) Error!void {
        try checkedVoid(c.ZSTD_initCStream(self.handle(), level));
    }

    /// Run one streaming compression step.
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
            @intCast(@backingInt(endOp)),
        ));
    }

    /// Flush buffered data without closing the frame.
    pub fn flush(self: *CStream, output: *OutBuffer) Error!usize {
        return checked(c.ZSTD_flushStream(self.handle(), output));
    }

    /// Flush and close the frame; keep calling until all compressed data is written.
    pub fn end(self: *CStream, output: *OutBuffer) Error!usize {
        return checked(c.ZSTD_endStream(self.handle(), output));
    }

    /// Set a named compression parameter on this context.
    pub fn setParameter(self: *CStream, param: CParameter, value: Level) Error!void {
        try checkedVoid(c.ZSTD_CCtx_setParameter(self.handle(), @intCast(@backingInt(param)), value));
    }

    /// Return this handle as `ZSTD_CCtx*`; upstream defines `CStream` as that alias.
    pub fn asCtx(self: *CStream) *c.ZSTD_CCtx {
        return self.handle();
    }
};

/// Owns a streaming decompression context, an upstream alias of `ZSTD_DCtx`.
/// Use it for incremental input; `deinit` frees the context.
pub const DStream = struct {
    /// The owned context, or null after `deinit`.
    raw: ?*c.ZSTD_DStream = null,

    /// `init` can fail only when upstream cannot allocate a context.
    pub const InitError = error{OutOfMemory};

    /// Create a streaming decompression context.
    pub fn init() InitError!DStream {
        const raw = c.ZSTD_createDStream() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the context and clear the field; repeated calls on the same variable are safe.
    pub fn deinit(self: *DStream) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeDStream(raw);
    }

    /// Whether the context is still open.
    pub fn isOpen(self: *const DStream) bool {
        return self.raw != null;
    }

    /// Return the raw context for unwrapped C calls; panics after `deinit`.
    pub fn handle(self: *const DStream) *c.ZSTD_DStream {
        return self.raw orelse @panic(
            "zstd: this DStream was freed; deinit() clears the handle and there " ++
                "is no context left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }

    /// Restart decoding; the return value is an input-size hint, with 0 meaning ready.
    pub fn initStream(self: *DStream) usize {
        return c.ZSTD_initDStream(self.handle());
    }

    /// Decode one streaming step; 0 means the frame is complete.
    /// After an error the context is undefined until reset.
    pub fn decompress(self: *DStream, output: *OutBuffer, input: *InBuffer) Error!usize {
        return checked(c.ZSTD_decompressStream(self.handle(), output, input));
    }

    /// Reset the context after an error or to begin a new session.
    pub fn reset(self: *DStream, directive: Reset) Error!void {
        try checkedVoid(c.ZSTD_DCtx_reset(self.handle(), @intCast(@backingInt(directive))));
    }

    /// Return this handle as `ZSTD_DCtx*`; upstream defines `DStream` as that alias.
    pub fn asDctx(self: *DStream) *c.ZSTD_DCtx {
        return self.handle();
    }
};

/// Owns an immutable digested compression dictionary.
/// The dictionary bytes are copied at creation, and the result can be shared between threads.
pub const CDict = struct {
    /// The owned dictionary, or null after `deinit`.
    raw: ?*c.ZSTD_CDict = null,

    /// `init` reports `OutOfMemory` if upstream cannot allocate the digested state.
    pub const InitError = error{OutOfMemory};

    /// Digest a dictionary for compression at `level`; empty input is valid.
    pub fn init(dict: []const u8, level: Level) InitError!CDict {
        const raw = c.ZSTD_createCDict(dict.ptr, dict.len, level) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the digested state and clear the field; repeated calls are safe.
    pub fn deinit(self: *CDict) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeCDict(raw);
    }

    /// Whether the dictionary is still open.
    pub fn isOpen(self: *const CDict) bool {
        return self.raw != null;
    }

    /// Return the digested state for unwrapped C calls; panics after `deinit`.
    pub fn handle(self: *const CDict) *c.ZSTD_CDict {
        return self.raw orelse @panic(
            "zstd: this CDict was freed; deinit() clears the handle and there is " ++
                "no dictionary left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }
};

/// Owns an immutable digested decompression dictionary.
/// The dictionary bytes are copied at creation and may then be released.
pub const DDict = struct {
    /// The owned dictionary, or null after `deinit`.
    raw: ?*c.ZSTD_DDict = null,

    /// `init` reports `OutOfMemory` if upstream cannot allocate the digested state.
    pub const InitError = error{OutOfMemory};

    /// Digest a dictionary for decompression.
    pub fn init(dict: []const u8) InitError!DDict {
        const raw = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Free the digested state and clear the field; repeated calls are safe.
    pub fn deinit(self: *DDict) void {
        const raw = self.raw orelse return;
        self.raw = null;
        _ = c.ZSTD_freeDDict(raw);
    }

    /// Whether the dictionary is still open.
    pub fn isOpen(self: *const DDict) bool {
        return self.raw != null;
    }

    /// Return the digested state for unwrapped C calls; panics after `deinit`.
    pub fn handle(self: *const DDict) *c.ZSTD_DDict {
        return self.raw orelse @panic(
            "zstd: this DDict was freed; deinit() clears the handle and there is " ++
                "no dictionary left to call. Check isOpen() if the lifetime is " ++
                "not obvious.",
        );
    }
};

/// Classify the first frame's content-size field.
/// Skippable frames report `.known(0)`; use `isSkippableFrame` to identify them.
pub const ContentSize = union(enum) {
    /// A declared content size; zero means an empty frame.
    known: u64,
    /// The frame has no content-size field.
    unknown,
    /// The header is too short or has an invalid magic number.
    undecodable,

    /// Convert an upstream content-size sentinel to this union.
    pub fn of(value: u64) ContentSize {
        return switch (value) {
            content_size_unknown => .unknown,
            content_size_error => .undecodable,
            else => .{ .known = value },
        };
    }

    /// Return the declared size, or null when it is unknown or undecodable.
    pub fn get(self: ContentSize) ?u64 {
        return switch (self) {
            .known => |size| size,
            else => null,
        };
    }
};

/// Train a dictionary into caller-owned `dict`; capacity must meet `dict_size_min`.
/// `allocator` supplies scratch; upstream uses about 6 MiB internally, and failures return `Error` tags.
pub fn trainDictionary(
    allocator: std.mem.Allocator,
    dict: []u8,
    samples: []const []const u8,
) Error!usize {
    if (dict.len < dict_size_min) return error.DstSizeTooSmall;

    const total = std.mem.concat(allocator, u8, samples) catch return error.OutOfMemory;
    defer allocator.free(total);
    const sizes = allocator.alloc(usize, samples.len) catch return error.OutOfMemory;
    defer allocator.free(sizes);
    for (samples, 0..) |sample, index| sizes[index] = sample.len;

    const written = c.ZDICT_trainFromBuffer(dict.ptr, dict.len, total.ptr, sizes.ptr, @intCast(samples.len));
    if (zdictIsError(written)) return errorFromCode(errorCode(written));
    return written;
}

/// Return a dictionary ID, or 0 when `dict` is not valid.
pub fn dictID(dict: []const u8) u32 {
    return c.ZDICT_getDictID(dict.ptr, dict.len);
}

/// Test a dictionary-builder result with its own error predicate.
/// This is distinct from `isError`, which handles compression/decompression results.
pub fn zdictIsError(result: usize) bool {
    return c.ZDICT_isError(result) != 0;
}

/// Return upstream's message for a dictionary-builder result.
pub fn zdictErrorName(result: usize) [:0]const u8 {
    return std.mem.span(c.ZDICT_getErrorName(result));
}

/// Minimum output size accepted by the dictionary trainer: 256 bytes.
pub const dict_size_min: usize = c.ZDICT_DICTSIZE_MIN;

/// Map an upstream error code to a facade error; callers test `isError` first.
/// Unstable and unrecognized codes collapse into `UnstableCode`.
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

/// Convert a raw `size_t` result into a byte count or a facade error.
fn checked(result: usize) Error!usize {
    if (c.ZSTD_isError(result) != 0) return errorFromCode(ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised);
    return result;
}

/// Convert a raw status result into `void` or a facade error.
fn checkedVoid(result: usize) Error!void {
    if (c.ZSTD_isError(result) != 0) return errorFromCode(ErrorCode.fromCode(@intCast(c.ZSTD_getErrorCode(result))) orelse .unrecognised);
}
