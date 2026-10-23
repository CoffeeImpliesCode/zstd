<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Notice

## Upstream work

Zstandard's source in `src/` is licensed under BSD-3-Clause or GPL-2.0, at the recipient's option. The copyright line in `src/LICENSE` is `Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.` The full texts are `src/LICENSE` and `src/COPYING`; both are shipped and installed. `src/lib/libzstd.mk` and `src/README.md` state the dual grant.

> This source code is licensed under both the BSD-style license (found in the
> LICENSE file in the root directory of this source tree) and the GPLv2 (found
> in the COPYING file in the root directory of this source tree). You may select,
> at your option, one of the above-listed licenses.

| Path | Terms and scope |
|---|---|
| `src/**`, except paths below | BSD-3-Clause or GPL-2.0, at the recipient's option. |
| `src/tests/gzip/` | 23 files under GPL-2.0-or-later, © Free Software Foundation. These are GNU coreutils gzip tests, not Zstandard code, and are not built or installed. |
| `src/contrib/linux-kernel/` | Upstream's kernel-targeted branch under the dual grant. `linux_zstd.h` has a kernel-specific SPDX header; `src/contrib/linux-kernel/test/include/linux/xxhash.h` carries the kernel's GPL-2.0 text. The package does not compile this directory. |
| `src/build/LICENSE` | Zero bytes; grants nothing. Other files under `src/build/` use the upstream dual grant. |

The gzip test notice states:

> Copyright (C) 2011-2015 Free Software Foundation, Inc.
>
> This program is free software; you can redistribute it and/or modify it under
> the terms of the GNU General Public License as published by the Free Software
> Foundation; either version 2, or (at your option) any later version.

`src/build/LICENSE` has SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, the digest of an empty file. No LGPL, Apache-2.0, or public-domain dedication is recorded for the imported tree.

`src/README.md` is upstream's README. `README.upstream.md` is its byte-identical fork-side copy and remains under the upstream dual grant, not the fork grant. The BSD text copied into `README.md` also remains upstream-licensed.

## Fork-authored files

The project owner's BSD-3-Clause grant in `FORK-LICENSE.md` covers only fork-authored files. It does not cover `src/`, the upstream licence texts, or external fixture data.

| File group | Fork-authored paths |
|---|---|
| Build | `build.zig`, `build.zig.zon`, `.gitignore`, `cross-test.profile.sh` |
| Facade | `zig/root.zig`, `zig/translate.h` |
| Tests and consumer | `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` |
| Runtime | `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.h`, `runtime/sync.c` |
| Packaging and tools | `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`, `tools/check-provenance.sh` |
| Fixture record | `fixtures/PROVENANCE.md` |
| Package records | `NOTICE.md`, `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-LICENSE.md`, `CHANGELOG.md`, `FORK-NOTES.md` |

Every byte under `fixtures/` other than `PROVENANCE.md` was produced by the `zstd` CLI 1.5.7, `python-zstandard` 0.22.0 over libzstd 1.5.7, or written from RFC 8878. Those bytes remain under their producers' terms; the fork grant does not cover them.

The build installs these notice records in `share/licenses/zstd/`: `src/LICENSE`, `src/COPYING`, `src/README.md`, `README.upstream.md`, `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-NOTES.md`, and `CHANGELOG.md`.
