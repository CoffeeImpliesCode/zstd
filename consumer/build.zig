// SPDX-License-Identifier: BSD-3-Clause
// See ../FORK-LICENSE.md for what that identifier covers.

//! Standalone consumer verifying that `dep.module("zstd")` delivers the facade,
//! translated headers, and native artifact.
//! Default fixture paths are read at runtime; explicit arguments select frames.
//! Parent builds forward target, linkage, and dispatch mode to this package.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward linkage and dispatch options instead of silently using defaults.
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

    // Read the runner's system-integration flag; it is not a `-D` option.
    // Dependencies share the graph and see the same `-fsys`/`-fno-sys` flags.

    // Do not add libc here; that would hide a missing library dependency.
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

    if (b.args) |args| {
        run_exe.addArgs(args);
    } else {
        // Default fixture paths are relative to `consumer/` in both build modes.
        // Include a frame without a checksum or content size.
        run_exe.addArgs(&.{
            "../fixtures/cli/level-3.zst",
            "../fixtures/pyzstd/bare-3.zst",
        });
    }

    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}
