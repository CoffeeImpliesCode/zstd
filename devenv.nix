# Development environment and tasks for the Zstandard SDK.
#
# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md for what that identifier covers.

{ pkgs, ... }:

let
  # Use one Zig package value for both the shell and version assertion.
  zig = pkgs.zig_0_16;

  zstd = linkage: pkgs.callPackage ./package.nix {
    inherit linkage;
    zig = zig;
  };

  # Pass tasks the checkout path without copying it into the Nix store.
  sdk_root = builtins.toString ./.;

  # Put Zig caches outside the checkout, respecting caller-provided paths.
  zig_caches = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/zstd/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zstd/zig-local-cache"
      fi
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/zstd/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zstd/zig-global-cache"
      fi
    fi
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
  '';

  # Stop tasks if no external cache directory is available.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "zstd devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # Run task bodies from the SDK checkout regardless of the caller's directory.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  # Pass job count, summary, cache, and caller arguments to native builds.
  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  # Keep the consumer package's cache separate.
  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';

  # Runtime tasks load the shared object from this external path.
  provider = "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic/lib/libzstd.so";
in
{
  packages = [
    zig
    pkgs.gnumake
    pkgs.pkg-config
  ];

  assertions = [
    {
      assertion = zig.version == "0.16.0";
      message = "The Zstandard SDK requires Zig 0.16.0; nixpkgs resolved zig_0_16 to ${zig.version}";
    }
  ];

  # Interactive shells use the same external cache paths as tasks.
  enterShell = ''
    ${zig_caches}
  '';

  # Output attributes are lazy; builds run only when requested.
  outputs.static = zstd "static";
  outputs.shared = zstd "dynamic";
  outputs.default = zstd "static";

  # Use namespace:name task names for devenv compatibility.
  tasks = {
    # Install prefixes stay outside the checkout.
    "sdk:build" = {
      description = ''
        Compile the native library and install the delivery tree (library, all
        three public headers, zstd.pc and both of upstream's licence texts with
        this fork's records) under the external cache rather than in this
        checkout.
      '';
      exec = ''
        ${in_sdk}
        zig build --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/static" ${native_flags}
      '';
    };

    "sdk:build:shared" = {
      description = ''
        Compile the native library as a shared object -- libzstd.so with the
        libzstd.so.1 soname src/lib/Makefile:87 names -- and install it under its
        own external prefix.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic" ${native_flags}
      '';
    };

    # Test and check tasks use the external cache without installing.
    "sdk:test" = {
      description = "Run the behavioural tests";
      exec = ''
        ${in_sdk}
        zig build test ${native_flags}
      '';
    };

    "sdk:test:release-safe" = {
      description = "Run the behavioural tests in ReleaseSafe";
      exec = ''
        ${in_sdk}
        zig build test -Doptimize=ReleaseSafe ${native_flags}
      '';
    };

    "sdk:smoke" = {
      description = "Run the deterministic example";
      exec = ''
        ${in_sdk}
        zig build smoke ${native_flags}
      '';
    };

    # The default check matrix omits WASI; the dedicated task checks static WASI.
    "sdk:check" = {
      description = ''
        Compile the 34-unit closure, the facade, the tests and the example for
        each of the five workspace check targets without running any of them
      '';
      exec = ''
        ${in_sdk}
        zig build check ${native_flags}
      '';
    };

    "sdk:check:shared" = {
      description = "The same five-target compile check against the shared object";
      exec = ''
        ${in_sdk}
        zig build check -Dlinkage=dynamic ${native_flags}
      '';
    };

    "sdk:check:wasm32-wasi" = {
      description = ''
        Compile the whole package for wasm32-wasi in the one linkage that
        target supports, without running anything
      '';
      exec = ''
        ${in_sdk}
        zig build check -Dtarget=wasm32-wasi -Dlinkage=static ${native_flags}
      '';
    };

    # Exercise the published package from a separate consumer.
    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd consumer
        zig build run ${consumer_flags}
      '';
    };

    "sdk:provenance" = {
      description = ''
        Check the 637 recorded upstream digests, the exact native file set, the 19
        data entries of fixtures/SHA256SUMS, both of upstream's licence texts and
        every path build.zig.zon .paths names. This is a source-integrity check,
        not a build gate.
      '';
      exec = ''
        ${in_sdk}
        bash tools/check-provenance.sh
      '';
    };

    "sdk:runtime:shared-provider" = {
      description = ''
        Build the shared object and keep it at a known path under the external
        cache, for the two runtime-loading tasks below to load. Run this first.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic" ${native_flags}
      '';
    };

    "sdk:runtime:test" = {
      description = ''
        Run the behavioural tests through the runtime dispatch, loading the
        provider built by sdk:runtime:shared-provider
      '';
      exec = ''
        ${in_sdk}
        zig build test -Druntime=true ${native_flags} -- --provider "${provider}"
      '';
    };

    "sdk:runtime:smoke" = {
      description = "Run the deterministic example through the runtime dispatch";
      exec = ''
        ${in_sdk}
        zig build smoke -Druntime=true ${native_flags} -- --provider "${provider}"
      '';
    };

    "sdk:runtime:no-provider" = {
      description = ''
        Assert that the runtime build refuses to run with no provider named, and
        says which variable would supply one
      '';
      exec = ''
        ${in_sdk}
        unset ZSTD_TEST_PROVIDER
        if zig build smoke -Druntime=true ${native_flags} >/dev/null 2>"$ZIG_LOCAL_CACHE_DIR/no-provider.log"; then
          echo "FAIL: the smoke run succeeded with no provider named" >&2
          exit 1
        fi
        grep -q 'ZSTD_TEST_PROVIDER' "$ZIG_LOCAL_CACHE_DIR/no-provider.log"
        echo "the run refused and named ZSTD_TEST_PROVIDER"
      '';
    };

    # Package tasks run from the caller's project; outputs go to the Nix store.
    "sdk:package:static" = {
      description = ''
        Build the static Nix variant through devenv's own lazy output. No lock
        is needed by this path; `devenv build outputs.static` resolves the
        pinned input from devenv.lock, which the driver owns.
      '';
      exec = "devenv build outputs.static";
    };

    "sdk:package:shared" = {
      description = "Build the shared Nix variant through devenv's own lazy output";
      exec = "devenv build outputs.shared";
    };
  };
}