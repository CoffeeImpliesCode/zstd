# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md and NOTICE.md for licence scope and attribution.

{ lib
, stdenv
, zig
, patchelf
  # Empty linkage keeps build.zig's default.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Preserve upstream sources, fixtures and licences; exclude local build outputs.
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

# Apply ELF rpath normalization with patchelf.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# Nix builds are native-only; Zig check and cross-test cover cross targets.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "zstd";
  version = "1.5.7";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # installPhase owns the only Zig build and install.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # The bundled library needs libc; this build does not enable ZSTD_MULTITHREAD.
  propagatedBuildInputs = [ stdenv.cc.libc ];

  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches under TMPDIR, outside the source tree.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # build.zig owns source selection, flags, and pkg-config generation.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Remove temporary cache paths from ELF rpaths; keep all other entries.
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

  # build.zig defines the installed layout; no CLI executable is packaged.

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

    # Upstream permits BSD or GPL; both licence texts are installed.
    license = lib.licenses.bsd3;

    licenseFile = "LICENSE";

    platforms = lib.platforms.unix;
  };
}