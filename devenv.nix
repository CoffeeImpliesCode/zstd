# Canonical development environment for the Zstandard SDK.
#
# This is the environment a contributor should be in. It installs tools and
# nothing else: `packages` deliberately does not contain the SDK's own package,
# because entering a shell must not require building a library to have it.
#
# The package itself is defined once, in ./package.nix, and shared with
# flake.nix, so the two entry points cannot describe different builds. `outputs`
# below name that same derivation lazily -- they are attributes, not builds, so
# nothing is realised until `devenv build outputs.static` or
# `devenv build outputs.shared` is actually run.
#
# devenv.lock is not written here: the driver owns locks.
#
# Two facts about the environment a task actually runs in are handled once, in
# the `let` below, and every task uses them: devenv materialises a task as a
# generated shell program that inherits the caller's working directory, and
# `zig build` defaults both its local cache and its install prefix to
# directories inside the working tree. Neither is visible from a task body, and
# both decide whether a task can find this checkout or must write into it.
#
# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md for what that identifier covers.

{ pkgs, ... }:

let
  # Kept as a value rather than inlined, so the version assertion below and the
  # package list cannot disagree about which compiler is meant.
  zig = pkgs.zig_0_16;

  zstd = linkage: pkgs.callPackage ./package.nix {
    inherit linkage;
    zig = zig;
  };

  # The directory this module was evaluated against. `./.` is a path literal
  # resolved relative to the file that names it, so it is this checkout and
  # never the directory `devenv` was started from. `builtins.toString`
  # converts that path instead of interpolating it into a string, so what the
  # tasks below receive is this working tree: a plain `${./.}` would carry the
  # path's store context and copy this whole SDK into the read-only store, and
  # that copy is not the tree `build.zig` and `UPSTREAM.sha256` describe. No
  # host path is written in this file -- the value is read out of the module's
  # own location, so it tracks wherever this checkout is.
  sdk_root = builtins.toString ./.;

  # Where a task's build output goes. `zig build` keeps its local cache in
  # `.zig-cache/` and installs into `zig-out/`, both relative to the working
  # directory, and this checkout is a working tree on a volume mount that has to
  # stay byte-identical. A directory the caller exported always wins and is
  # never overwritten; otherwise it comes from `XDG_CACHE_HOME`, then `TMPDIR`,
  # and this file names no location of its own.
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

  # The same rule with the one extra requirement a task has: it must be able to
  # name that directory. An environment with nowhere outside the checkout to
  # write stops here, with the reason, instead of filling the tree.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "zstd devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # What every task below starts with. devenv materialises a task as a
  # generated shell program that inherits the caller's working directory, so
  # `devenv --from path:<sdk>` entered from a scratch project directory would
  # otherwise run each of these bodies where there is no `build.zig` and no
  # `UPSTREAM.sha256`. A per-task `cwd` would not reach that generated
  # program, and `$DEVENV_ROOT` is the scratch project itself -- exactly what
  # these bodies must not build in.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  # The flags every native build here shares: this workspace's eight jobs,
  # fixed, then the printed step list and a local cache outside the checkout.
  # `"''$@"` stays after them, so whatever a caller appended is still passed
  # on and still comes later; `devenv tasks run` forwards no argument of its
  # own, so it is the empty list on that route.
  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  # The consumer package is a second build graph with its own manifest, so it
  # gets its own cache directory rather than sharing one with the library.
  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';

  # The file a runtime-loading task loads. It is the shared object this same
  # tree builds, named by path, never discovered: a runtime-loading build that
  # was not told which file to load must say so rather than loading something
  # else. `sdk:runtime:shared-provider` puts it here first.
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

  # The shell hook exports the same two directories the tasks use, by the same
  # rule, so an ordinary `devenv shell` session also leaves this checkout alone.
  # A value the caller exported is kept exactly as it is, and with nothing to
  # choose from the hook chooses nothing: only a task, which has to name the
  # directory, refuses to run.
  enterShell = ''
    ${zig_caches}
  '';

  # Lazy on purpose: naming a derivation realises nothing, and entering the
  # shell does not build either variant. `devenv build outputs.<name>` is the
  # real packaging route; the task names below print the equivalent flake
  # command, which needs the driver-owned lock.
  outputs.static = zstd "static";
  outputs.shared = zstd "dynamic";
  outputs.default = zstd "static";

  # Every task name here is `namespace:name` and nothing else. devenv 2.4.1
  # accepts alphanumerics, `:`, `-` and `_` in a task name and rejects anything
  # else before any shell runs, so a name written with a `.` after the namespace
  # would be refused at parse time. The two names the driver runs --
  # `sdk:consumer` and `sdk:provenance` -- are spelled that way for that reason.
  tasks = {
    # Delivery output goes outside the checkout. The default step installs, and
    # `zig-out/` is a directory in the working tree, so the install prefix is
    # named here; the pkg-config file and the rpath the build normalises are
    # prefix-relative, so the installed tree is the same shape wherever it lands.
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

    # These five run or compile; none of them installs, so each needs only the
    # external cache directory.
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

    # Five targets, not six. `wasm32-wasi` is absent from `check_targets` for
    # one stated reason -- that list is walked for both linkages and a shared
    # object is refused on a target with no dynamic linker -- and nothing
    # refuses a *static* WASI cell. The one-target form belongs on the command
    # line: `zig build check -Dtarget=wasm32-wasi -Dlinkage=static`.
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

    # The one WASI cell, named explicitly rather than smuggled into the matrix.
    # It is a separate task because it is a separate fact: the five-target check
    # above does not cover it, and pretending otherwise would leave the platform
    # with no gate at all and no record that it had none.
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

    # The dependent package in `consumer/`, built and run as itself. It reaches
    # the library through the relative path dependency in its own manifest, so
    # this is the proof that `dep.module("zstd")` works from outside this
    # package. It is also the second place the interoperation claim is made:
    # consumer/src/main.zig decodes frames built from RFC 8878 and frames the
    # `zstd` CLI and the `python-zstandard` binding produced, from a package that
    # did not write the facade.
    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd consumer
        zig build run ${consumer_flags}
      '';
    };

    # The checker runs against this checkout's own bytes and file set, which is
    # what `UPSTREAM.sha256` describes, so it is entered here rather than in the
    # directory the task happened to start in.
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

    # The runtime-loading builds. They are separate tasks because they are
    # separate configurations, not tuning: the facade module links no archive at
    # all under -Druntime and a provider is named by an explicit load(source),
    # so the tests and the example need a path to one.
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

    # The other half of the contract: a runtime-loading build that was not told
    # which provider to use stops and names ZSTD_TEST_PROVIDER, rather than
    # falling back to a linked copy or to some default path.
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

    # These two are the only bodies that do not enter this checkout, and that is
    # deliberate. They run a nested `devenv build`, which reads the project the
    # caller entered -- under `--from path:<sdk>` that is the scratch project
    # holding `.devenv/` and `devenv.lock` -- and its delivery output is a store
    # path, never a directory in this tree. Changing directory here would point
    # the nested command at a directory with no devenv state at all.
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