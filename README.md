<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Zstandard

Zstandard 1.5.7 packaged with a Zig 0.17.0 build graph and typed facade.
The package builds and installs the native library, public headers, and `zstd.pc`.

## Source deviations

| Path | Change |
|---|---|
| `src/` | All 637 upstream files remain unmodified. |
| `zig/` | Adds the C header translation and typed facade for `zstd.h`, `zdict.h`, and `zstd_errors.h`. |
| `zig/root.zig` | Instantiates `ZSTD_COMPRESSBOUND` at `u64` before returning `usize`, avoiding a 32-bit `translate-c` type mismatch. |
| `runtime/` | Adds optional runtime symbol dispatch through an explicitly loaded, process-lifetime provider. |

## Build deviations

- `build.zig` replaces upstream's Make, CMake, meson, Visual Studio, Buck, and SwiftPM builds.
- The build names its C sources explicitly: 33 C units and the AMD64 assembly decoder on `x86_64`. It pins C to C99.
- The CLI and upstream helper programs are not built. The build derives `zstd.pc` from upstream's `src/lib/libzstd.pc.in`.
- Dynamic builds use an export map on ELF. Mach-O and COFF lack that mechanism, so the build warns that internal symbols are exported too.

## Support matrix

The `check` step names five targets; WASI is listed as an additional static-only target:

| Target | Static | Shared |
|---|:---:|:---:|
| `x86_64-linux-gnu` | yes | yes |
| `aarch64-linux-gnu` | yes | yes |
| `aarch64-macos-none` | yes | yes |
| `x86_64-windows-gnu` | yes | yes |
| `riscv64-linux-gnu` | yes | yes |
| `wasm32-wasi` | yes | no |

The WASI target is static-only. Dynamic linkage is refused when the target has no dynamic linker. Other Zig targets can be selected with `-Dtarget`; assembly is enabled only on `x86_64`.

## Consumption

Fetch this package from GitHub into the consumer's `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/CoffeeImpliesCode/zstd#v1.5.7
```

In the consumer build script, import the module and link the artifact:

```zig
const dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });
module.addImport("zstd", dep.module("zstd"));
executable.linkLibrary(dep.artifact("zstd"));
```

The module and artifact are both named `zstd`. The artifacts are `libzstd.a` by default or a shared library; on ELF, the shared file is `libzstd.so.1.5.7` with soname `libzstd.so.1`. C consumers use `-lzstd` with the installed headers or `pkg-config` file.

| Option | Default | Effect |
|---|---|---|
| `-Dlinkage=static\|dynamic` | `static` for bundled builds; `dynamic` for system builds | Selects the delivered library. |
| `-Druntime=true\|false` | `false` | Uses explicit runtime loading for the Zig facade; independent of linkage. |
| `-Dsystem=true\|false` | `false` | Binds the installed library and its headers instead of building bundled sources. `-fsys=zstd` also selects system integration. |
| `-Dtarget=<triple>` | host target | Selects the build target. |
| `-Doptimize=<mode>` | Zig default | Selects the optimization mode. |

## Licence

Upstream `src/` remains BSD-3-Clause or GPL-2.0, at the recipient's option.
Both `src/LICENSE` and `src/COPYING` are shipped and installed.
`NOTICE.md` records per-file terms; `FORK-LICENSE.md` covers fork-authored files.
The upstream BSD text from `src/LICENSE` is:

```
BSD License

For Zstandard software

Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook, nor Meta, nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
