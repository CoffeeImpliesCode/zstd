// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
//
//! Build graph for Zstandard's runtime-loaded API; do not link the C archive.
//! Generates the dispatch and patched translation, and wires the loader core
//! with a namespaced synchronization binding.
//! The translated API exposes 189 Zstandard functions; only the thread-pool
//! creation pair is optional. `libc_noise` is empty based on header analysis,
//! not translation; recheck if translated headers or their includes change.

const std = @import("std");

/// Sync prefix used by `runtime/sync.c` and `runtime/library.zig`.
/// Change both declarations and provide separate copies for another instance.
const sync_prefix = "zstd_rt";

/// C-library externs kept direct. Empty based on header analysis, not translation.
/// Recheck when translated headers or their include closure changes.
const libc_noise = "";

/// Optional provider symbols: this build omits `ZSTD_MULTITHREAD`, so it does
/// not define `ZSTD_createThreadPool` or `ZSTD_freeThreadPool`.
const provider_optional = "ZSTD_createThreadPool,ZSTD_freeThreadPool";

const provider_excluded = "";

/// Build the loader core for linked mode so both modes share `LoadSource` and
/// `LoadError`; runtime mode creates its own single core in the dispatch.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // Unix dynamic loading uses libc.
        .link_libc = true,
    });
}

/// Build the runtime-loaded `c` module from this target's translation.
/// The generator consumes that same translation output.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);
    // Use the same translation for validation; importing the dispatch here creates a cycle.
    library.addImport("c", translate.createModule());

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);
    // Re-export types from the patched translation to preserve nominal identity.
    // Its `__root` import routes nested aliases through the dispatch.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Generate a dispatch from the target's configured C translation.
/// Host generator output is rebuilt for each target and configuration.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("zstd-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("zstd");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
