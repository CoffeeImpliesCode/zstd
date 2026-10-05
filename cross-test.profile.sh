# cross-test settings profile for the Zstandard SDK.
#
# `cross-test` looks for this file at the root of the project it is run from
# (or names it with --profile; --no-profile ignores it). It is trusted Bash that
# the harness `source`s, so this file is *settings only*: ordinary variable
# assignments and nothing else. No command runs, no compiler is probed, and no
# path in here names a host.
#
# There is deliberately no CROSS_MATRIX. The published 53-platform Zig 0.16
# Tier 1/2 table is the matrix this package is checked against, and a matrix
# named here would replace it. There is no TARGETS array either, for the same
# reason: a subset selected here would narrow the run rather than add to it.
# Both belong on the command line, where --targets selects from the active
# matrix and never adds to it.
#
# CROSS_BUILD_STEP stays the standard `test` step, which is what this profile
# states explicitly. There are no `cross_build_command` / `cross_artifact`
# hooks here, so the harness keeps its standard Zig-build mode and runs
# `zig build test -Dtarget=TARGET` per target with a fresh cache. What that
# means for a given target is the harness's decision, not this package's: a
# host target runs, a foreign target runs under whatever executor the harness
# detects (QEMU user mode, Wine, wasmtime), and a foreign target with no
# executor is reported as build-only coverage -- compiled, never executed, and
# never counted as a pass. `build.zig` gives the test binary a Run step for
# every target, which is what leaves that choice open.
#
# A target graph compiles the whole 34-unit closure of `src/lib/libzstd.mk` -- 33
# `.c` files plus the one assembly unit -- translates `zstd.h`, `zdict.h` and
# `zstd_errors.h`, and links the facade and the test root. The
# `decompress/zstd_decompress_amd64.S` unit is inside that 34 and is assembled
# only on `x86_64`, so a non-x86 cell compiles 33 and an x86 cell compiles 34;
# two jobs are kept free rather than filling the machine, because a 53-platform
# run is 53 such graphs.
#
# Nothing here narrows the gate to what is expected to work. Which platforms
# Zstandard itself supports is decided by `src/lib/common/portability_macros.h`
# and `src/lib/common/compiler.h` -- POSIX, Windows with `__declspec` split per
# `src/lib/zstd.h:47-51`, and no `dlopen` anywhere -- and `build.zig` resolves
# those macros from the target being built. A cell that fails is a fact to
# record and diagnose; it is not a reason to drop the cell, sample the tests or
# remap Debug to an optimized mode to make it pass.
#
# `wasm32-wasi` is **not** named here and **not** excluded by anything in this
# file. It is absent from `build.zig`'s `check_targets` for one stated reason --
# that list is walked for both linkages and a shared object is refused on a
# target whose OS has no dynamic linker -- and nothing refuses a *static* WASI
# cell. See `build.zig:1498-1505`. If a gate ever needs it, the one-target form
# is `-Dtarget=wasm32-wasi -Dlinkage=static` on the command line, which is where
# a selection belongs.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=4
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800