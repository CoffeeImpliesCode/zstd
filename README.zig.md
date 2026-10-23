<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Zig facade API

## Runtime loading

| Declaration | Contract |
|---|---|
| `runtime_loaded: bool` | Compile-time indication that the facade uses runtime dispatch. |
| `LoadSource` | `.path` takes an absolute path; `.system` takes a library basename or soname. |
| `load(source) LoadError!void` | Loads one process-lifetime provider. Repeating the same request succeeds; a different provider returns `ProviderMismatch`. Failed loads publish nothing and can be retried. |
| `loadedSource() ?LoadSource` | Returns the retained request, or `null` before loading and in linked builds. |

`LoadError` includes `EmptySource`, `SourceTooLong`, `InvalidSource`, `UnsupportedTarget`, `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch`, and `ReentrantLoad`. There is no fallback between `.path` and `.system`. Calling `load` in a linked build panics. A load does not unload its provider.

## Values and errors

- `Level` is `c_int`; `default_level` is 3. `minLevel()` and `maxLevel()` return the upstream limits.
- `version_major`, `version_minor`, `version_release`, `version_number`, and `version_string_literal` describe the headers used to compile the facade. `versionNumber()` and `versionString()` query the loaded library.
- Frame constants include `magic_number`, `magic_skippable_start`, `magic_skippable_mask`, `frame_header_size_prefix`, `frame_header_size_min`, `frame_header_size_max`, `skippable_header_size`, and `block_size_max`.
- `CParameter` names compression options: `compression_level`, `window_log`, `hash_log`, `chain_log`, `search_log`, `min_match`, `target_length`, `strategy`, `target_cblock_size`, `enable_long_distance_matching`, `ldm_hash_log`, `ldm_min_match`, `ldm_bucket_size_log`, `ldm_hash_rate_log`, `content_size_flag`, `checksum_flag`, `dict_id_flag`, `nb_workers`, `job_size`, and `overlap_log`.
- `DParameter` is `window_log_max`. The bundled library is single-threaded, so nonzero `nb_workers` is unsupported. `EndOp` is `@"continue"`, `flush`, or `@"end"`; `Reset` is `session_only`, `parameters`, or `session_and_parameters`.
- `Error` is the facade error set. `ErrorCode.fromCode` maps numeric values; `isUnstable()` identifies unstable codes. `errorCode` maps unknown values to `.unrecognised`, and wrappers map unstable codes to `error.UnstableCode`.
- `isError`, `errorCode`, `errorName`, and `errorCodeText` inspect Zstandard results. The dictionary builder has separate helpers: `zdictIsError` and `zdictErrorName`.

## One-shot operations and frame inspection

| Function | Result |
|---|---|
| `compressBound(src_len) Error!usize` | Maximum compressed size; returns an error for an invalid input size. |
| `compressBoundConst(src_len) usize` | Compile-time form; returns zero for the upstream macro's invalid-size case. |
| `decompressBound(src) Error!u64` | Upper bound for the decompressed frames in `src`. |
| `compress(dst, src, level) Error!usize` | Compresses one source buffer. |
| `decompress(dst, src) Error!usize` | Decompresses frames into a caller-provided destination. |
| `frameContentSize(src) ContentSize` | Returns `.known`, `.unknown`, or `.undecodable`. |
| `frameHeaderSize(src) Error!usize` | Reads the frame header length. |
| `findFrameCompressedSize(src) Error!usize` | Returns the first frame's length. |
| `isSkippableFrame(src) bool` | Tests for a skippable frame. |
| `dictIDFromFrame(src) u32` | Reads the frame's dictionary ID, or zero. |

- `ContentSize` is `.known(u64)`, `.unknown`, or `.undecodable`; `get()` returns `?u64`, and `of(value)` converts an upstream result.
- `cStreamInSize()`, `cStreamOutSize()`, `dStreamInSize()`, and `dStreamOutSize()` return recommended streaming buffer sizes.

## Owned contexts

`Ctx`, `Dctx`, `CStream`, `DStream`, `CDict`, and `DDict` own C handles. Do not copy these values. Call `deinit` to release the handle; it clears the field, and a second call is a no-op. `isOpen()` reports whether the handle remains live; `handle()` panics after deinitialization. Context constructors report `OutOfMemory`.

| Type | Operations |
|---|---|
| `Ctx` | `init`, `initWithLevel`, `setLevel`, `level`, `setParameter`, `getParameter`, `setPledgedSourceSize`, `compress`, `stream2`, `reset`, `compressUsingCDict` |
| `Dctx` | `init`, `setParameter`, `decompress`, `decompressUsingDict`, `decompressUsingDDict`, `reset` |
| `CStream` | `init`, `initLevel`, `setParameter`, `compress`, `flush`, `end`; `compress` takes `InBuffer`, `OutBuffer`, and `EndOp`. |
| `DStream` | `init`, `initStream`, `decompress`, `reset`; `decompress` takes `OutBuffer` and `InBuffer`. |

`Ctx.setLevel` clamps to the supported range; `level()` reads the selected value. `setParameter` and `getParameter` expose the named parameter enums. `DStream.initStream()` returns an input-size hint. `DStream.decompress()` returns zero when a frame is complete and a positive hint when more work remains. Keep calling `CStream.flush()` or `CStream.end()` until they return zero. Compression with `EndOp.@"end"` continues until it returns zero. Streaming calls update buffer positions in place.

## Dictionaries and raw declarations

- `CDict.init(bytes, level)` and `DDict.init(bytes)` create reusable dictionary objects. They copy the input bytes into their own digested state.
- `trainDictionary(allocator, dict, samples) Error!usize` trains into the caller's buffer and returns the bytes written. The allocator holds temporary packed sample buffers; `dict_size_min` is 256. `dictID(dict)` reads the dictionary ID.
- `InBuffer` and `OutBuffer` are the upstream C structs, with caller-managed cursors.
- `c` exposes declarations from `zstd.h`, `zdict.h`, and `zstd_errors.h` that the facade does not wrap.
