# Source-only package derivation for the Zstandard SDK.
#
# One file, consumed by both flake.nix and devenv.nix, so the two entry points
# cannot describe different packages. It builds nothing but this repository: the
# native source is upstream's `src/`, which is the complete Zstandard 1.5.7
# release tree imported whole from the release tarball, and build.zig owns every
# compile flag and the whole installed layout. Nothing here restates a C flag,
# fetches a tarball, reaches into a sibling checkout, or installs an artifact of
# its own. The one edit it makes is the rpath of the ELF files the build
# installed: Zig records its own build cache there, and that directory does not
# exist once a binary is installed.
#
# Zstandard's own build systems are not used. `src/lib/Makefile`,
# `src/lib/libzstd.mk`, the CMake and meson trees under `src/build/`, the Visual
# Studio project trees and `src/Package.swift` all travel in the source closure
# and none of them is invoked: this is a source-only derivation over `build.zig`.
#
# Nothing under `src/programs/` is built. The `zstd` CLI and `pzstd` are
# upstream's programs, not this package's deliverable, and upstream's own library
# install rule does not install them.
#
# No lock file is written here. `flake.lock` and `devenv.lock` belong to the
# driver.
#
# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# Meta Platforms terms that cover the BSD option in src/LICENSE and the
# GPLv2 text in src/COPYING.

{ lib
, stdenv
, zig
, patchelf
  # Zig's own `std.builtin.LinkMode` spelling, passed straight through as
  # `-Dlinkage`. "static" and "dynamic" are two variants of one derivation, and
  # `""` passes nothing at all so the SDK's own default policy runs unchanged.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Everything except build outputs, version control and developer-tool state.
# Filtering by directory name rather than by an allow list means a file added
# here later is packaged without editing this file, while `.zig-cache/`,
# `zig-out/`, `.devenv/`, `.direnv/` and `result` stay out of a published output
# at any depth, including under consumer/. The format specification, upstream's
# golden-decompression corpus, the GNU coreutils gzip testsuite vendored under
# `src/tests/`, both licence texts and every upstream build system are
# deliberately kept: they are upstream material with digests in
# UPSTREAM.sha256, and the audit surface is the whole upstream tree.
src = lib.cleanSourceWith {
  src = ./.;
  filter = path: _type:
    let name = builtins.baseNameOf (toString path); in
    !(lib.elem name [
      ".git"
      ".direnv"
      ".devenv"
      ".zig-cache"
      "zig-cache"
      "zig-pkg"
      "zig-out"
      "result"
    ]);
};

# patchelf rewrites ELF rpaths and does not read Mach-O, so the rpath
# normalisation in the install phase exists for ELF targets only, and the tool is
# a build input exactly where that code runs.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# These packages build for the compiler's own native target. A cross build here
# would mean hand-building a libc-suffixed triple that has to track nixpkgs, so
# this derivation refuses one instead of silently producing a host-architecture
# library under a foreign name. The comparison is against stdenv's own
# platforms, which are pure values; `builtins.currentSystem` is not evaluable
# in a sandbox and is not used. A remote builder is unaffected: this compares
# build against host, not against any particular machine.
#
# Cross-compilation is not thereby unclaimed: `zig build check` covers the five
# workspace targets and `cross-test` covers the published 53-platform matrix,
# both without Nix. See README.md, "Native-build deviations".
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "zstd";
  version = "1.5.7";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # The real work is one `zig build install` in installPhase below. Disabling
  # configure and build phases keeps the Zig setup hook from running a first,
  # differently-flagged build of its own; `dontInstall` is deliberately NOT set,
  # because that is what would disable the real install phase.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # Zstandard's library needs libc and, where a consumer asks for multithreading,
  # threads. This build compiles `common/pool.c` and `common/threading.c`
  # unconditionally -- pool.c because
  # `dictBuilder/cover.c:1213` and `dictBuilder/fastcover.c:672` call
  # `POOL_create` from the dictionary trainer whenever nbThreads > 1, so the
  # archive does not link without it -- but defines `ZSTD_MULTITHREAD` nowhere,
  # so `threading.c` contributes one symbol and no thread is started. This is the
  # whole of the native dependency closure; nothing else is propagated.
  propagatedBuildInputs = [ stdenv.cc.libc ];

  # The driver owns every gate for this SDK, and a Nix build is not a
  # verification receipt. No check phase is declared here rather than a check
  # phase that runs something smaller than the real gates; the commands that do
  # verify this package are in README.md and CHANGELOG.md.
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Both caches go under the Nix-provided TMPDIR, outside the unpacked source
    # tree, so a build cannot write into $src and so two parallel derivations
    # cannot share state. Any caller-supplied cache variables are left alone:
    # they are the caller's scratch, not this file's to clear.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # build.zig owns the source list (the four libzstd.mk wildcards expanded
    # into five named arrays, so a file upstream adds later is not picked up by
    # accident), the C flags, the AMD64-assembly decision, the pkg-config file
    # and every installed path. Declaring any of them here as well would create
    # a second place where they can disagree with the build graph.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Zig records the build cache in the rpath of anything that links a dynamic
    # artifact it has just built (lib/std/Build/Step/Compile.zig:1192-1199), so
    # an installed binary names a directory that is gone, and Nix rejects an
    # installed file that names its build directory at all. Both Zig caches above
    # are under $TMPDIR, so dropping those entries and no other removes it: the
    # $ORIGIN/../lib build.zig adds, and every store path a real dependency
    # needs, stay. Symlinks are resolved first so a soname link is rewritten
    # through to the object and never replaced by a copy of it.
    ${lib.optionalString isElfTarget ''
      for elf in "$out"/bin/* "$out"/lib/*.so*; do
        [ -f "$elf" ] || continue
        elf=$(readlink -f "$elf")
        rpath=$(patchelf --print-rpath "$elf") || rpath=""
        kept=""
        rest=$rpath
        while [ -n "$rest" ]; do
          entry="''${rest%%:*}"
          case "$entry" in
            "$TMPDIR"/*) ;;
            *) if [ -z "$kept" ]; then kept=$entry; else kept=$kept:$entry; fi ;;
          esac
          if [ "$entry" = "$rest" ]; then rest=""; else rest="''${rest#*:}"; fi
        done
        [ "$kept" = "$rpath" ] || patchelf --set-rpath "$kept" "$elf"
      done
    ''}

    runHook postInstall
  '';

  # The layout this derivation produces is the build graph's, not this file's:
  # $out/lib/libzstd.a (or libzstd.so with the libzstd.so.1 soname,
  # `src/lib/Makefile:87`),
  # $out/include/{zstd.h,zstd_errors.h,zdict.h}, $out/lib/pkgconfig/zstd.pc and
  # $out/share/licenses/zstd/ with **both** upstream licence texts and this
  # fork's records. Both variants keep it; only the artifact kind differs. No
  # executable is installed: `src/programs/` is upstream's CLI, this package does
  # not compile it, and upstream's own library install rule does not install it
  # either. Nothing is copied or generated by hand here, so
  # `zig build install --prefix $out` and `nix build` produce one layout by
  # construction rather than two that have to be kept in agreement.

  enableParallelBuilding = true;

  meta = {
    description = "Zstandard 1.5.7, the fast lossless compression algorithm, built from the official release sources";
    longDescription = ''
      The complete Zstandard 1.5.7 release source -- the library, the dictionary
      builder, the legacy v0.5-to-v0.7 decoders and the AMD64 assembly decoder,
      plus the specification documents, upstream's golden-decompression corpus
      and every retained contributed tree -- compiled from the tarball's own src/
      directory with Zig, with no CMake, no meson, no Visual Studio and no
      build-time download. Ships the library, all three public headers, a
      pkg-config file, and both of upstream's licence texts.
    '';

    # Upstream's grant is a choice between two licences:
    # `src/lib/libzstd.mk:2-8` says "You may select, at your option, one of the
    # above-listed licenses", with the BSD text at src/LICENSE and the GPLv2 text
    # at src/COPYING. nixpkgs has no operator for an OR over two licences, so
    # one is named here and both texts are installed regardless -- this
    # derivation runs `zig build install`, and build.zig's `licence_records`
    # names `src/LICENSE` *and* `src/COPYING`.
    #
    # Naming BSD-3-Clause does not remove the GPL alternative from a recipient:
    # it records which text this metadata describes. `NOTICE.md` and
    # `UPSTREAM.md` say so in full, and `tools/check-provenance.sh` fails if
    # either text or the dual-grant statement in `src/lib/libzstd.mk` stops
    # being present.
    license = lib.licenses.bsd3;

    # Both texts are installed either way: `zig build install` writes
    # `share/licenses/zstd/` from build.zig's `licence_records`, which names
    # `src/LICENSE` and `src/COPYING` separately. This line only tells nixpkgs
    # which of them to show as the file for the metadata above.
    licenseFile = "LICENSE";

    platforms = lib.platforms.unix;
  };
}