<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# The `zstd` Zig module

The typed surface over Zstandard 1.5.7. `dep.module("zstd")` is this module;
`dep.artifact("zstd")` is the C library it talks to.

It is a **facade, not a binding generator**. Every public type here is a Zig
shape over a real C declaration in `zig/translate.h`, which includes
`zstd.h`, `zdict.h` and `zstd_errors.h` whole. Nothing is invented, nothing is
copied out of a header at comptime and re-derived, and no sentinel is
reconstructed.

`STATUS`: `SOURCE-CONFIRMED` throughout. Nothing here was executed.

---

## 1. Getting the module

```zig
const zstd_dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("zstd", zstd_dep.module("zstd"));
```

```zig
const zstd = @import("zstd");
```

## 2. The three modes, and what compiles in each

| Build | The module | Reaching the library |
|---|---|---|
| default | `@import("zstd")` | a link line against `libzstd.a` or `libzstd.so` |
| `-Dlinkage=dynamic` | identical | a link line against the shared object |
| `-Druntime=true` | identical API and identical types | `zstd.load(.{ .path = … })` fills one process-lifetime table |

`zstd.runtime_loaded` is a `comptime bool`, so a caller writes

```zig
if (comptime zstd.runtime_loaded) {
    try zstd.load(.{ .path = provider_path });
}
```

and it disappears entirely in a linked build. The API surface does not fork.

**Runtime-loading rules.** One process-lifetime table per configured module;
explicit path or named-system selection with **no fallback**; atomic
publication; explicit retry after failure. A build that was not told which file
to load says so and stops — there is no linked copy to fall back to. A failed
load with no provider configured **panics in every optimization mode**,
`ReleaseFast` included: a programming error is not a runtime condition to be
optimized away.

---

## 3. Errors

Zstandard returns a `size_t` and reserves `(size_t)-1` for failure, with the
reason carried in the low bits rather than in an out-parameter.

```zig
pub const ErrorCode = enum(c_int) { no_error, generic, /* … */ };
pub const Error = error{ /* … */ };

pub fn isError(result: usize) bool;
pub fn errorName(result: usize) [:0]const u8;
pub fn errorCode(result: usize) ErrorCode;
pub fn errorCodeText(code: ErrorCode) [:0]const u8;
```

* `isError` is upstream's `ZSTD_isError`, not a re-derivation of "did the value
  come back negative". **It is correct whatever the library version**, which is
  upstream's own rule at `src/lib/zstd_errors.h:49-58`.
* `errorName` and `errorCodeText` return **upstream's own strings**, read out of
  `src/lib/common/error_private.c`. A facade that composed its own wording for an
  upstream code would make the text useless to anyone reading a real failure.
* `ErrorCode` is the whole of `src/lib/zstd_errors.h:60-98`, and the codes at and
  above 100 are named with their `unstable_` prefix rather than hidden, so a
  caller who receives one can see that it came from the group upstream marks as
  not stable.
* The `Error` set is cut at what this package's own code checked. It is not a
  transcription of every name in the header.

---

## 4. One-shot compression

```zig
const frame = try std.heap.page_allocator.alloc(u8, try zstd.compressBound(src.len));
const n = try zstd.compress(frame, src, 3);
```

| Function | Upstream |
|---|---|
| `compress(dst, src, level) Error!usize` | `ZSTD_compress` |
| `decompress(dst, src) Error!usize` | `ZSTD_decompress` |
| `compressBound(src_len) Error!usize` | `ZSTD_compressBound` |
| `compressBoundConst(src_len) usize` | the same, with the failure case already handled |

`compressBound` is fallible because `ZSTD_compressBound` is: it has no failure
case of its own but the declaration is an ordinary `size_t` function, and this
module does not invent a "cannot fail" for a C function whose contract it has
not read. `compressBoundConst` exists for the caller who wants the constant, and
it is documented as such.

`decompress` needs a destination large enough. `decompressBound(src)` gives the
bound; where a frame declares no content size it returns
`content_size_unknown`'s answer rather than a guess, and the error says which
case it was.

---

## 5. Frame inspection

These take a slice and answer from the bytes, without allocating a context and
without decompressing anything.

```zig
switch (zstd.frameContentSize(frame)) {
    .known => |n| ...,       // the frame declares it
    .unknown => ...,          // no content-size field (src/lib/zstd.h:203)
    .undecodable => ...,      // too few bytes, or a magic that is neither
}
```

| Function | Upstream | Returns |
|---|---|---|
| `frameContentSize(src) ContentSize` | `ZSTD_getFrameContentSize` | a union: known / unknown / undecodable |
| `frameHeaderSize(src) Error!usize` | `ZSTD_frameHeaderSize` | header length in bytes |
| `findFrameCompressedSize(src) Error!usize` | `ZSTD_findFrameCompressedSize` | where this frame ends |
| `isSkippableFrame(src) bool` | `ZSTD_isSkippableFrame` | RFC 8878 §3.1.2 |
| `dictIDFromFrame(src) u32` | `ZSTD_getDictID_fromFrame` | 0 when there is none |

`ContentSize` is a union rather than the raw `u64` because the raw number has
**two** distinguished values upstream defines —
`ZSTD_CONTENTSIZE_UNKNOWN` and `ZSTD_CONTENTSIZE_ERROR`
(`src/lib/zstd.h:203-204`) — and a caller who treats either as a length gets a
very large number and an allocation. `ContentSize.of` maps the raw value back,
so the upstream constant is passed through unchanged rather than reconstructed.

---

## 6. Contexts: `Ctx` and `Dctx`

```zig
var ctx = try zstd.Ctx.initWithLevel(3);
defer ctx.deinit();
const n = try ctx.compress(&frame, src, zstd.default_level);
```

Both are owned handles that clear themselves on `deinit`.

* `init` has exactly **one** failure, `error.OutOfMemory`:
  `ZSTD_createCCtx` returns null for that and nothing else.
* **`deinit` is idempotent.** It reads the handle, nulls the field, then frees.
  A second `deinit` on the same variable is a no-op, not a second free. That is
  what makes a `defer` plus an explicit early end both safe, and it is the
  ownership transition the tests assert.
* `isOpen()` answers whether the handle is still live; `handle()` returns the raw
  `*c.ZSTD_CCtx` and **panics with an explanation** on a closed context, because
  a call into a freed context is not a condition to recover from.
* The free goes through the same `c` route that opened the context, so a context
  created by one provider is always freed by that provider.

### Levels are clamped, not refused

```zig
try ctx.setLevel(100);          // succeeds
try testing.expectEqual(zstd.maxLevel(), try ctx.level());  // and clamps
```

`ZSTD_CCtx_setParameter` forwards to `ZSTD_CCtxParams_setParameter`, which
clamps (`src/lib/compress/zstd_compress.c:781-782` through
`ZSTD_cParam_clampBounds` at `:642-649`). So `setLevel` returning `void` is
honest: it did not fail, and the *value* it settled on is read back with
`level()`. `setParameter` / `getParameter` are there for the other `CParameter`s,
which do have real error cases.

`minLevel()` and `maxLevel()` are `ZSTD_minCLevel` and `ZSTD_maxCLevel`;
`maxLevel()` is 22 because `src/lib/compress/clevels.h:19` says so.

---

## 7. Dictionaries

```zig
var dict = try zstd.trainDictionary(allocator, samples, dict_buffer, samples_len);
const id = zstd.dictID(dict);
```

`CDict` and `DDict` are the compiled and decompressed forms, reusable across
many frames — which is the entire reason to build a dictionary rather than
prepend its bytes. `dict_size_min` is `ZDICT_DICTSIZE_MIN`, and `zdictIsError`
/ `zdictErrorName` are the `zdict.h` pair, which have their **own** error
convention from the `zstd.h` one.

---

## 8. Buffers

```zig
pub const InBuffer  = c.ZSTD_inBuffer;
pub const OutBuffer = c.ZSTD_outBuffer;
```

Both are the C structs, not wrappers, because the C side reads and writes them
through a pointer the caller supplies (`src/lib/zstd.h:701-711`). `pos` is the
caller's cursor and is what says how much of the buffer was consumed or filled.

`Ctx.stream2` and the matching decompression path take these directly. The
module does not hide the cursor behind a slice: the streaming API's contract
*is* the cursor, and a wrapper that recomputed it would be re-deriving a value
upstream defines.

---

## 9. Reset directives

```zig
try ctx.reset(.session_only);            // stop the frame; parameters stay
try ctx.reset(.parameters);              // parameters go back; session stays
try ctx.reset(.session_and_parameters);
```

Each names upstream's own `ZSTD_reset_*` value. Three directives, three names —
not one `reset()` that guesses, because choosing wrong here is silent: a
dictionary that was supposed to survive gets dropped and the output changes size
without anything failing.

---

## 10. Version and magic numbers

```zig
zstd.version_major / version_minor / version_release  // from the header
zstd.version_string_literal                            // "1.5.7", from the header
zstd.versionNumber()    // what the *loaded* library reports
zstd.versionString()    // the same, as a string
zstd.magic_number, magic_skippable_start, magic_skippable_mask
zstd.frame_header_size_prefix / _min / _max, skippable_header_size, block_size_max
```

**Header and provider are different facts and this module keeps them apart.**
The `version_*` values come from the translated header, so they describe what
this package was compiled against. `versionNumber()` takes no argument and reads
a constant from the loaded object, so in a runtime-loading build it is the only
way to learn which file answered. A build that compared them would be asserting
the provider is the one it was built against — true by default, and exactly what
breaks when someone names a different `.so`.

`ZSTD_FRAMEHEADERSIZE_MIN` is 6 for `ZSTD_f_zstd1` and
`ZSTD_FRAMEHEADERSIZE_MAX` is 18 (`src/lib/zstd.h:1257-1259`); the prefix is the
5 bytes a header query needs. Those three are stated, not derived.

---

## 11. The escape hatch

```zig
pub const c = @import("c");
```

Everything reachable from `zig/translate.h` is reachable through `c`: the whole
of `zstd.h`, `zdict.h` and `zstd_errors.h`, including the declarations the
facade does not wrap — `ZSTD_compressSequences`, the dictionary *trainer*
entry points, the experimental surface behind `ZSTD_STATIC_LINKING_ONLY`. That
is deliberate: the facade is a *convenience* layer, and a declaration it does not
wrap must still be callable without forking the package.

Use it when there is no wrapper. Prefer the wrapper when there is one: it is the
one that owns the error mapping and the ownership transition.

---

## 12. What the tests are, and what they are not

Grouped by what they rest on:

| Group | Oracle |
|---|---|
| RFC 8878 | frames under `fixtures/rfc8878/`, built byte by byte from the RFC. `tests.zig` carries its **own** decoder for those header fields and checks it against inline literals first, so the derivation is visible rather than asserted |
| upstream's golden corpus | `src/tests/golden-decompression/`, embedded **in place** from the vendored source. `rle-first-block.zst` is a fully independent known answer: 1 MiB of `0x00` follows from what the RLE rule means |
| upstream's invalid corpus | `src/tests/golden-decompression-errors/`, frames upstream ships *and labels invalid* — so the expected answer is an error rather than an oracle |
| producer interop | `fixtures/cli/*.zst` and `fixtures/pyzstd/*.zst`. **One implementation behind two producers**, and one test asserts the byte-identity directly, because that is the fact that keeps the rest of the claim honest |
| behavioural boundaries | bounds, refusal, truncation, clamping, and the ownership transitions this module owns |

**No test pins a version string, asserts a decl exists, compares a forwarder
with its parts, or checks that a round trip returns non-zero.**

### The allocator

Zstandard allocates through libc's `malloc`, `calloc` and `free`, reached
through `ZSTD_defaultCMem` (`src/lib/common/zstd_deps.h:64-68`), **not** through
`std.testing.allocator`. So `testing.allocator` cannot be a leak oracle for
anything Zstandard allocates, and no test here claims it is. What a test can
check is the ownership transition this module owns: that `deinit` releases the
context, that a second `deinit` is not a second free, and that two contexts are
independent. Every buffer a test allocates itself is still freed.

### One upstream inconsistency, recorded rather than smoothed

`ZSTD_decompressBound` returns `ZSTD_CONTENTSIZE_ERROR` for a v0.5-to-v0.7
frame while `ZSTD_decompress` still decodes it, because the bound function has
no legacy arm while the decompressor does (`src/lib/zstd.h:571-576` against
`:203-204`), and `ZSTD_LIB_DEPRECATED` is 0 regardless of `ZSTD_LEGACY_SUPPORT`.
Nothing here papers over it; `build.zig`'s module comment, `UPSTREAM.md` and
`FORK-NOTES.md` all record it.