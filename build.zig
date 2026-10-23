// SPDX-License-Identifier: BSD-3-Clause
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zig 0.16 build for Zstandard 1.5.7.

const std = @import("std");

/// Runtime graph; each build creates one loader core module.
const graph = @import("runtime/graph.zig");

const manifest = @import("build.zig.zon");

const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

const lib_name = "zstd";

const facade_source = "zig/root.zig";

const translate_header = "zig/translate.h";

const test_source = "tests.zig";

const example_source = "smoke.zig";

/// Include root for upstream C sources and the translation header.
const source_dir = "src/lib";

/// Upstream release; checked against the manifest version.
const upstream_version: std.SemanticVersion = .{ .major = 1, .minor = 5, .patch = 7 };

/// Shared-library ABI version for this release.
const abi_version: std.SemanticVersion = .{ .major = 1, .minor = 5, .patch = 7 };

const common_sources = [_][]const u8{
    "src/lib/common/debug.c",
    "src/lib/common/entropy_common.c",
    "src/lib/common/error_private.c",
    "src/lib/common/fse_decompress.c",
    "src/lib/common/pool.c",
    "src/lib/common/threading.c",
    "src/lib/common/xxhash.c",
    "src/lib/common/zstd_common.c",
};

/// Includes upstream's guarded multithreaded compressor source.
const compress_sources = [_][]const u8{
    "src/lib/compress/fse_compress.c",
    "src/lib/compress/hist.c",
    "src/lib/compress/huf_compress.c",
    "src/lib/compress/zstd_compress.c",
    "src/lib/compress/zstd_compress_literals.c",
    "src/lib/compress/zstd_compress_sequences.c",
    "src/lib/compress/zstd_compress_superblock.c",
    "src/lib/compress/zstd_double_fast.c",
    "src/lib/compress/zstd_fast.c",
    "src/lib/compress/zstd_lazy.c",
    "src/lib/compress/zstd_ldm.c",
    "src/lib/compress/zstd_opt.c",
    "src/lib/compress/zstd_preSplit.c",
    "src/lib/compress/zstdmt_compress.c",
};

const decompress_sources = [_][]const u8{
    "src/lib/decompress/huf_decompress.c",
    "src/lib/decompress/zstd_ddict.c",
    "src/lib/decompress/zstd_decompress.c",
    "src/lib/decompress/zstd_decompress_block.c",
};

const amd64_asm_source = "src/lib/decompress/huf_decompress_amd64.S";

const dictbuilder_sources = [_][]const u8{
    "src/lib/dictBuilder/cover.c",
    "src/lib/dictBuilder/divsufsort.c",
    "src/lib/dictBuilder/fastcover.c",
    "src/lib/dictBuilder/zdict.c",
};

/// Upstream's legacy v0.5-v0.7 decoders selected by ZSTD_LEGACY_SUPPORT=5.
const legacy_sources = [_][]const u8{
    "src/lib/legacy/zstd_v05.c",
    "src/lib/legacy/zstd_v06.c",
    "src/lib/legacy/zstd_v07.c",
};

/// Includes the assembly unit only for x86_64 targets.
fn decompressAssembly(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch == .x86_64;
}

const public_headers = [_][]const u8{
    "src/lib/zstd.h",
    "src/lib/zstd_errors.h",
    "src/lib/zdict.h",
};

const licence_records = [_][]const u8{
    "src/LICENSE",
    "src/COPYING",
    "src/README.md",
    "README.upstream.md",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "FORK-NOTES.md",
    "CHANGELOG.md",
};

const c_flags = [_][]const u8{"-std=c99"};

const Library = enum {
    bundled,
    system,
};

const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
};

fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Target-specific definitions for the C library and header translation.
const Platform = struct {
    macros: []const [2][]const u8,
    /// Whether to define upstream's MinGW `%zu` compatibility macro.
    mingw_stdio: bool,
    /// Whether Windows DLL import/export macros apply.
    dll: bool,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        if (target.result.os.tag == .windows) {
            // Match upstream's MinGW macro on Windows.
            return .{
                .macros = &.{.{ "__USE_MINGW_ANSI_STDIO", "1" }},
                .mingw_stdio = true,
                .dll = true,
            };
        }
        // No additional platform macros are needed outside Windows.
        return .{ .macros = &.{}, .mingw_stdio = false, .dll = false };
    }

    fn kind(platform: Platform) []const u8 {
        if (platform.mingw_stdio) return "__USE_MINGW_ANSI_STDIO (upstream's MinGW recipe)";
        return "no platform macro; upstream's own preprocessor conditionals decide";
    }
};

const Graph = struct {
    c_lib: ?*std.Build.Step.Compile,
    module: *std.Build.Module,
    platform: Platform,
};

/// Builds one target's library and facade.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    const platform = Platform.forTarget(target);
    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, artifactName(b, target, public))
    else
        null;

    // Resolve linkage once for the target.
    const delivered = deliveredLinkage(target, linkage);

    const no_macros: []const [2][]const u8 = &.{};
    const translate_macros = if (library == .bundled) platform.macros else no_macros;
    const translate_include: ?std.Build.LazyPath =
        if (library == .bundled) b.path(source_dir) else null;
    const translate_dll = library == .bundled and delivered == .dynamic and platform.dll;

    const translate = b.addTranslateC(.{
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (translate_include) |dir| {
        // Use bundled headers here; system mode resolves installed headers through zstd.pc.
        translate.addIncludePath(dir);
    }

    // Match upstream's namespace macro for vendored xxHash symbols.
    translate.defineCMacro("XXH_NAMESPACE", "ZSTD_");

    // Enable experimental declarations on the translation only.
    translate.defineCMacro("ZSTD_STATIC_LINKING_ONLY", "1");

    // Enable experimental dictionary-builder declarations for the facade.
    translate.defineCMacro("ZDICT_STATIC_LINKING_ONLY", "1");

    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    if (translate_dll) {
        // Match upstream's DLL import declarations in the translation.
        translate.defineCMacro("ZSTD_DLL_IMPORT", "1");
    }

    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    // Runtime dispatch and linked mode must share the loader-core types.
    if (runtime_loaded) {
        // Runtime mode resolves symbols from the loaded provider, not a linked archive.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // Keep translated headers private to the facade.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // Expose bundled headers to dependents through the facade module.
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compiles the upstream C units and configures target linkage.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    requested: std.builtin.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("zstd.def", "EXPORTS\n")
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // The upstream C library uses libc.
            .link_libc = true,
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    c_mod.addIncludePath(b.path(source_dir));

    // Use the same target macros as the header translation.
    for (platform.macros) |macro| {
        c_mod.addCMacro(macro[0], macro[1]);
    }

    // Match upstream's XXH_NAMESPACE, DEBUGLEVEL, and ZSTD_LEGACY_SUPPORT settings.
    c_mod.addCMacro("XXH_NAMESPACE", "ZSTD_");
    c_mod.addCMacro("DEBUGLEVEL", "0");
    c_mod.addCMacro("ZSTD_LEGACY_SUPPORT", "5");

    if (platform.dll and linkage == .dynamic) {
        c_mod.addCMacro("ZSTD_DLL_EXPORT", "1");
    }

    for (common_sources) |source| addCUnit(c_mod, b, source);
    for (compress_sources) |source| addCUnit(c_mod, b, source);
    for (decompress_sources) |source| addCUnit(c_mod, b, source);
    for (dictbuilder_sources) |source| addCUnit(c_mod, b, source);
    for (legacy_sources) |source| addCUnit(c_mod, b, source);

    if (decompressAssembly(target)) addCUnit(c_mod, b, amd64_asm_source);

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    // Installing the headers exposes them to artifact consumers.
    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.fs.path.basename(header));
    }

    return c_lib;
}

/// Adds a C source file with the pinned compiler flags.
fn addCUnit(
    c_mod: *std.Build.Module,
    b: *std.Build,
    source: []const u8,
) void {
    c_mod.addCSourceFile(.{
        .file = b.path(source),
        .flags = &c_flags,
    });
}

/// Restricts ELF shared-library exports; Mach-O has no equivalent version script.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;

    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("zstd.map",
        \\ZSTD_1 {
        \\  global:
        \\    ZSTD_*;
        \\    ZDICT_*;
        \\  local:
        \\    *;
        \\};
        \\
    ));
}

/// Compiles the library, facade, tests, and example for one check target.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // Name cross-target artifacts with their target triple.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("zstd-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("zstd-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);
}

/// Builds the separate consumer package with this build's options.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // Forward CPU separately because the target triple does not include it.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Use the Zig executable running this build for the nested build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward the requested linkage to the consumer.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Forward the resolved runtime mode to the consumer.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // Forward the resolved system-integration mode through build-runner flags.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // Forward enabled executors to the consumer build.
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // Reuse this build's global cache in the consumer build.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // Forward a nondefault prefix as an absolute path, avoiding consumer/zig-out.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // Forward caller arguments to the consumer after its options.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.has_side_effects = true;
    return run;
}

/// Reports whether this host can run binaries for the selected target.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // The consumer executable has no explicit linkage, so the musl runtime gate does not apply.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        .wine, .wasmtime, .darling => true,
        // GNU libc QEMU targets need an explicit libc runtime directory.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Generates pkg-config metadata from upstream's `src/lib/libzstd.pc.in`.
fn add_pkg_config(b: *std.Build) void {
    const files = b.addWriteFiles();
    // Retain this step so the generated .pc file is installed.
    const install_pc = b.addInstallFileWithDir(
        files.add("zstd.pc", b.fmt(
            \\# zstd.pc for the Zstandard 1.5.7 SDK.
            \\#
            \\# Generated from upstream's own template, src/lib/libzstd.pc.in, with
            \\# the placeholders it declares filled in. `prefix` is pcfiledir-relative
            \\# so the installed file is correct wherever --prefix put it. @LIBS_MT@
            \\# appears twice in the template, in Libs.private and in Cflags, and is
            \\# empty here because this build does not define ZSTD_MULTITHREAD.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: zstd
            \\Description: fast lossless compression algorithm library
            \\URL: https://facebook.github.io/zstd/
            \\Version: {f}
            \\Libs: -L"${{libdir}}" -lzstd
            \\Libs.private:
            \\Cflags: -I"${{includedir}}"
            \\
        , .{upstream_version})),
        .prefix,
        "lib/pkgconfig/zstd.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs upstream licence texts and package records.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        // Retain each install step in the build graph.
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/zstd/{s}", .{std.fs.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Link an installed libzstd instead of compiling src/lib/, and translate " ++
            "the installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"zstd\"); a build runner that " ++
            "decides the mode itself (-fsys=zstd) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and what " ++
            "upstream's own lib/Makefile builds) or as a real shared object with " ++
            "upstream's ZSTD_1 soname. This selects the delivery and never the " ++
            "dispatch: the same 34 C units are compiled either way. In system " ++
            "mode this graph builds no artifact at all, so there the option names " ++
            "the kind of installed library to bind to instead, and it defaults " ++
            "to dynamic.",
    );

    // Preserve static bundled linkage and Zig's dynamic system-library default.
    const linkage: std.builtin.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // Runtime dispatch is independent of artifact linkage.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated headers and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/lib/zstd.h:112-114; see UPSTREAM.md");
    }

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b);
        install_licence_records(b);
    }

    // The default build compiles the example but does not install it.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = "zstd-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // The smoke step runs the example without depending on installation.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // Use tests.zig as the root so its test declarations are discovered.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = "zstd-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    // Run the consumer when this host can execute it; otherwise compile it with install.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // The check step compiles each target without running its binaries.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "the five check targets without running any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    if (published.c_lib != null) {
        const asm_units: usize = if (decompressAssembly(target)) 1 else 0;
        std.debug.print("zstd: {d} C units ({d} common, {d} compress, {d} decompress, {d} dictBuilder, {d} legacy, {d} x86-64 asm on this target), C99\n", .{
            common_sources.len + compress_sources.len + decompress_sources.len +
                dictbuilder_sources.len + legacy_sources.len + asm_units,
            common_sources.len,
            compress_sources.len,
            decompress_sources.len,
            dictbuilder_sources.len,
            legacy_sources.len,
            asm_units,
        });
        std.debug.print("zstd: {s}; ZSTD_LEGACY_SUPPORT=5, XXH_NAMESPACE=ZSTD_, DEBUGLEVEL=0, ZSTD_MULTITHREAD undefined\n", .{
            published.platform.kind(),
        });
        std.debug.print("zstd: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive libzstd.a (default, and what upstream's src/lib/Makefile builds)",
            .dynamic => b.fmt("shared object libzstd.so.{d}.{d}.{d}, soname libzstd.so.{d}", .{
                abi_version.major,
                abi_version.minor,
                abi_version.patch,
                abi_version.major,
            }),
        }});
        if (runtime_loaded) {
            std.debug.print(
                "zstd: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // WASI needs a static one-target check because it has no dynamic linker.
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            std.debug.print(
                "zstd: {s} has no version-script mechanism here, so the shared " ++
                    "object exports Zstandard's internal symbols as well as its API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print("zstd: system libzstd (-lzstd) and the installed headers; this package installs nothing\n", .{});
        if (runtime_loaded) {
            std.debug.print(
                "zstd: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}

/// Returns whether the target OS can load shared libraries.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Resolves linkage; dynamic linkage requires a target dynamic linker.
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.builtin.LinkMode,
) std.builtin.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        std.debug.panic(
            "zstd: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it " ++
                "cannot carry a shared object at all. This build does not " ++
                "substitute a static archive for a requested shared object. Build " ++
                "that target with the default -Dlinkage=static, which is also what " ++
                "upstream's src/lib/Makefile produces there.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}
