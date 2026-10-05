// SPDX-License-Identifier: BSD-3-Clause
// See ../FORK-LICENSE.md for what that identifier covers.

//
//! Build wiring for the separate `consumer/` package.
//!
//! This package exists to prove one thing: that a dependent needs only
//! `dep.module("zstd")` and gets a working, correctly linked library. If the
//! facade module stopped carrying its C artifact, or the translated headers
//! stopped matching the C source, or the `zstd` module stopped resolving by
//! name, this would stop building or stop producing the answers its program
//! checks - and nothing inside the library would notice.
//!
//! `src/main.zig` is the API role's file. This file is only the graph that builds
//! it, and it deliberately repeats almost nothing: the library decides which
//! artifact is delivered, which linkage is used and which headers describe it,
//! and this package learns all of that through the dependency rather than by
//! restating it.
//!
//! `zig build run` runs it. The parent package's `zig build consumer` runs or
//! installs this package as a nested build for the selected target, linkage and
//! dispatch mode -- it installs when this host cannot execute that target -- so
//! `zig build consumer -Dlinkage=dynamic` really does check the shared object
//! and not the default archive.
//!
//! One default argument, and it is the reason this file is not four lines. The
//! consumer's interoperation checks decode frames that *other programs*
//! produced: the `zstd` CLI v1.5.7 and the `python-zstandard` 0.22.0 binding,
//! recorded in `fixtures/PROVENANCE.md`. Those frames are the library's
//! fixtures, not this package's, so they are read at run time from a path
//! rather than embedded: a copy embedded here would be a second copy that could
//! drift from the first, and it would put bytes in a package this manifest's
//! `.paths` does not carry. The default is the repository's own `fixtures/`
//! relative to this directory, so a plain `zig build run` does the full check and
//! a caller can point it anywhere with an argument.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The delivery and dispatch options are declared here rather than ignored,
    // so `zig build run -Dlinkage=dynamic` checks the shared object instead of
    // silently checking the default archive, and so the parent package's
    // `zig build consumer` can pass a configuration through to the dependency
    // instead of dropping it on the floor.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Which delivery of libzstd to check. Forwarded to the dependency; it " ++
            "decides the artifact, never anything in this package.",
    ) orelse .static;
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's.",
    ) orelse false;

    const dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
    });

    // The system mode is deliberately *not* a `-D` option here, and that is not
    // an omission. The dependency resolves it through
    // `b.systemIntegrationOption`, which is fed by the build runner's
    // `-fsys=`/`-fno-sys=` flags and is never an entry in the `-D` map, so a
    // `b.option` declared here would have to be threaded down as a dependency
    // option to reach the same answer. It does not need to be: a dependency
    // shares its parent's `Graph` and `system_library_options` is a field of it,
    // so the flag the runner was given reaches the dependency's own
    // `systemIntegrationOption` call unchanged.
    //
    // That is what the parent package's `zig build consumer` forwards, as the
    // mode it resolved, and it is also why `zig build run -fsys=zstd` in this
    // directory is the same check stated directly. Both spellings reach the one
    // switch; neither is a second code path.

    // No `link_libc` here on purpose. The C requirement belongs to the library
    // module, which carries it; a dependent states its own, and this program
    // needs nothing beyond what the library already brings. Adding it here would
    // hide a library that forgot to declare it.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zstd", dep.module("zstd"));

    const exe = b.addExecutable(.{
        .name = "zstd-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;

    // A caller's own arguments win, so `zig build run -- --provider <path>` and
    // `zig build run -- ../fixtures/cli/level-3.zst` both reach `src/main.zig`.
    if (b.args) |args| {
        run_exe.addArgs(args);
    } else {
        // The repository's own fixture set, reached from this package's working
        // directory. `zig build run` is documented to be run from `consumer/`,
        // and `zig build consumer` in the parent runs this same package with the
        // same working directory, so one relative path serves both routes.
        //
        // `../fixtures/pyzstd/bare-3.zst` is the frame whose producer settings
        // differ most from the others -- no content checksum and no content
        // size -- so it is the one whose decode would fail first if the header
        // decode and the frame body had drifted apart.
        run_exe.addArgs(&.{
            "../fixtures/cli/level-3.zst",
            "../fixtures/pyzstd/bare-3.zst",
        });
    }

    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}