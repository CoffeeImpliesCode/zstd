# Changelog

- Restore Forgejo package verification with Zig 0.17.0 and the two upstream metadata files removed with CI configuration, preserving the complete 637-file source import and its checksum manifest.
- Restore the upstream BSD licence and copyright notice in `README.md`, removed during documentation condensation.
- Include `flake.lock` in the package paths so the existing driver lock file ships with its dependency pins.
- Restore fixture provenance citations in the tests and consumer.
- Repair native CI assertions for relocatable pkg-config paths, versioned ELF symbols and real public C APIs; initialize the C payload before use and select the runtime test provider through `ZSTD_TEST_PROVIDER`.
- Port to Zig 0.17.0.
- The cross-target consumer check uses the parent install prefix.
- Linux QEMU consumer targets install instead of running because Zig 0.17 no longer exposes `--libc-runtimes` to build scripts.
- `compressBoundConst` now evaluates `ZSTD_COMPRESSBOUND` at `u64` before converting to `usize`, fixing 32-bit builds without changing its API.
- `README.md` now carries upstream's BSD copyright notice and licence text.
- Added an external consumer package and a deterministic smoke program for the facade and upstream fixtures.
- Added a Zig package with a typed facade, static/shared builds, system-library mode, and optional runtime loading.
