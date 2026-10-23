# Changelog

- Port to Zig 0.17.0.
- The cross-target consumer check uses the parent install prefix.
- Linux QEMU consumer targets install instead of running because Zig 0.17 no longer exposes `--libc-runtimes` to build scripts.
- `compressBoundConst` now evaluates `ZSTD_COMPRESSBOUND` at `u64` before converting to `usize`, fixing 32-bit builds without changing its API.
- `README.md` now carries upstream's BSD copyright notice and licence text.
- Added an external consumer package and a deterministic smoke program for the facade and upstream fixtures.
- Added a Zig package with a typed facade, static/shared builds, system-library mode, and optional runtime loading.
