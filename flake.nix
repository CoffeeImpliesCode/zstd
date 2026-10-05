# Flake interface for the Zstandard SDK.
#
# Portable counterpart to devenv.nix. Both call ./package.nix, so the package a
# flake builds and the package devenv builds are the same derivation; this file
# only decides which systems are exposed and which variants of that derivation
# they get.
#
# Canonical development is `devenv shell` (see devenv.nix and .envrc). This
# flake exists so the SDK can be built and consumed off this host. `nix develop`
# here is parity, not the canonical entry point, and it deliberately does not
# build the SDK: entering a shell must not require building a library.
#
# flake.lock is not written here: the driver owns locks, and `build.zig.zon`
# `.paths` does not name `flake.lock` because `zig fetch` hashes the paths it
# names and would fail on a name with no file behind it.
#
# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md for what that identifier covers.

{
  description = "Zstandard 1.5.7, the fast lossless compression algorithm, packaged for Zig 0.16";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs = { self, nixpkgs }:
    let
      # These are Unix systems only, which is the same boundary package.nix
      # asserts: it builds for the compiler's native target rather than
      # hand-building a cross triple. Documented in README.md, not worked around
      # here.
      #
      # `wasm32-wasi` is absent on purpose and for a specific reason, which
      # `build.zig:1498-1505` states: nothing refuses it, this is a plain-C
      # library with no thread, no signal and no `dlopen` in this configuration,
      # so a static WASI cell is expected to compile. It is missing from
      # `check_targets` only because that list is walked for *both* linkages and
      # `deliveredLinkage` refuses a shared object on a target whose OS has no
      # dynamic linker. The one-target form is
      # `zig build check -Dtarget=wasm32-wasi -Dlinkage=static`, and there is no
      # native Nix target for it that this derivation could be evaluated against
      # without hand-building a triple that has to track nixpkgs.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "x86_64-freebsd"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          mk = linkage: pkgs.callPackage ./package.nix {
            inherit linkage;
            zig = pkgs.zig_0_16;
          };
        in
        {
          static = mk "static";

          # A separate variant of the same derivation, not a second SDK.
          # "shared" names the artefact; the flag it passes is Zig's own
          # `-Dlinkage=dynamic`, and what it produces is `libzstd.so` carrying the
          # `libzstd.so.1` soname that `src/lib/Makefile:87` names (and that
          # `:82` spells as a Darwin `-install_name`).
          shared = mk "dynamic";

          default = mk "static";
        });

      # Parity only. The canonical development environment is devenv.nix.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_16 pkgs.gnumake pkgs.pkg-config ];
        };
      });
    };
}