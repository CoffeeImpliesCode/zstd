# FORK-NOTES.md

## Source deviations

The upstream `src/` tree is unchanged. Fork-authored files and adaptations:

| File | Change and reason |
|---|---|
| `zig/translate.h` | Translates `zstd.h`, `zdict.h`, and `zstd_errors.h` together so Zig sees the library's public declarations. |
| `zig/root.zig` | Adds the typed facade and widens `ZSTD_COMPRESSBOUND` input to `u64` to avoid a 32-bit `translate-c` type mismatch. |
| `runtime/generate.zig` | Generates the symbol dispatch and patched translation, rejecting unsupported declarations instead of guessing. |
| `runtime/graph.zig` | Connects the generated dispatch to the loader core without linking the C archive in runtime mode. |
| `runtime/library.zig` | Validates provider version, error reporting, bounds, and a compression round trip before publication. |
| `runtime/loader.zig` | Loads one explicit path or system library and publishes symbols only after resolution and validation. |
| `runtime/sync.h` | Defines the prefixed lock, wait, broadcast, and thread-identity interface used by the loader. |
| `runtime/sync.c` | Implements that interface for Windows, POSIX, WASI, and Emscripten. |

Upstream behavior retained: with `ZSTD_LEGACY_SUPPORT=5`, `ZSTD_decompress` can decode v0.5–v0.7 frames, but `src/lib/zstd.h`'s `ZSTD_decompressBound` does not provide a bound for them.

## Build graph deviations

- `build.zig` replaces upstream build frontends with five explicit C source groups. They select 33 C units; `huf_decompress_amd64.S` is added only for `x86_64`.
- `common/pool.c` is included because dictionary trainers call its API even with `ZSTD_MULTITHREAD` undefined. Its single-thread path runs jobs inline; `common/threading.c` remains in the selected source closure.
- The C library and header translation share target macros. The build uses C99, `XXH_NAMESPACE=ZSTD_`, `DEBUGLEVEL=0`, and `ZSTD_LEGACY_SUPPORT=5`; it does not define `ZSTD_MULTITHREAD`.
- System mode uses installed `libzstd` and headers instead of compiling or installing a bundled artifact. Runtime mode routes translated symbols through an explicitly loaded provider and does not link the archive; it is independent of static or shared delivery.

## Platform boundaries

- The AMD64 Huffman decoder assembly is available only on `x86_64`.
- WASI builds are static-only. Dynamic linkage is refused when the target has no dynamic loader.
- ELF shared libraries use a version script to restrict exports. Mach-O and COFF have no equivalent here; shared builds warn that upstream internal symbols are exported too.
- The WASI and Emscripten synchronization backend is single-threaded and uses no-op lock and condition operations.
