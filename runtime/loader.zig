// SPDX-License-Identifier: MIT
//
//! The reusable half of the runtime loader. One copy of this file is what makes
//! a translated C API callable without being linked into the binary.
//!
//! What this file owns
//! -------------------
//!   * `LoadSource` and `LoadError`, the two types a caller names;
//!   * the readiness flag and the panic a call before readiness triggers;
//!   * the process-global attempt state machine, including retry, idempotence,
//!     provider change, reentrancy and the waiter drain;
//!   * the platform layer: `dlopen`/`dlsym`/`dlclose`, or
//!     `LoadLibraryExW`/`GetProcAddress`/`FreeLibrary`.
//!
//! What this file deliberately does not own
//! -----------------------------------------
//! Any symbol name, any table field, any type. Those come from the library's own
//! configuration (see `Loader` below), which is the only per-library file: it
//! spells the namespaced synchronization symbols and describes the table. That
//! split is what lets this file be copied verbatim into a different SDK: nothing
//! in it names a BLAKE3 symbol, or any other library's, and nothing in it
//! assumes two of them are not loaded into one process.
//!
//! ## The lifecycle
//!
//! A configured module has exactly one table for the life of the process, and
//! `load` is the only way to fill it:
//!
//!   1. Before anything, a call through the table is a programming error. Every
//!      routed function checks the readiness flag with acquire ordering and, if
//!      it is not ready, stops the program with an ordinary panic naming the
//!      function. This is not a debug-only assertion: it happens in ReleaseFast
//!      and ReleaseSmall too, because a call into an uninitialized table is not
//!      something to discover later.
//!   2. `load` opens exactly what the caller named. `.path` is a file path and
//!      `.system` is a name for the platform loader; there is no fallback from
//!      one to the other, no search path of our own, and no retry that nobody
//!      asked for.
//!   3. Only when every required symbol has resolved and the library's own
//!      validation has passed is the table published, with a single release
//!      store. A candidate that fails at any step is closed and leaves nothing
//!      behind, so a partial table is never reachable.
//!   4. After that the process keeps the handle and its copy of the request.
//!      There is no unload and no reset: the table is process-global state and
//!      the code that filled it may already have been called from anywhere.
//!
//! ## The errors
//!
//! Every one of them is a condition this code checked. `EmptySource` and
//! `SourceTooLong` are rejected before the platform is touched;
//! `UnsupportedTarget` means the target has no dynamic loader to call;
//! `OpenFailed` is the platform refusing the request; `MissingSymbol` is the
//! file opening but not exporting everything the header declares;
//! `ValidationFailed` is the library's own post-resolution check declining the
//! provider; `ProviderMismatch` is a request that cannot be honoured because a
//! different provider already won; `ReentrantLoad` is a call from a thread that
//! is already inside a load attempt.

const std = @import("std");
const builtin = @import("builtin");

/// Which native library `load` should open.
///
/// The two cases are separate on purpose. There is no path-to-system fallback:
/// a request either names a file or names a library for the platform loader to
/// find, and a request that names the wrong kind fails instead of quietly
/// becoming the other kind.
pub const LoadSource = union(enum) {
    /// An absolute file path. Relative paths are InvalidSource, never searches.
    path: []const u8,
    /// A basename or SONAME searched by the platform loader. Path separators
    /// and embedded NUL bytes are InvalidSource. No path-to-name fallback.
    system: []const u8,
};

/// Every way `load` can decline.
pub const LoadError = error{
    /// The request named nothing: `.path` with an empty path, or `.system` with
    /// an empty name. Checked before the platform is called, because an empty
    /// name is a caller mistake rather than a missing file.
    EmptySource,
    /// The request is longer than `max_source_len` bytes. The loader keeps its
    /// own copy of the request for the life of the process rather than
    /// allocating one, and a request that does not fit is refused rather than
    /// truncated: a truncated path is a different path, and loading a different
    /// file than the one that was asked for is the one outcome this loader must
    /// never produce.
    SourceTooLong,
    /// A path is not absolute, a system name contains a path component, or the
    /// request contains a NUL byte. No platform loader call was made.
    InvalidSource,
    /// This target has no dynamic library loader, so there is nothing to call.
    /// It is an honest refusal, not a fallback to a linked copy: no provider was
    /// opened and nothing was published.
    UnsupportedTarget,
    /// The platform loader refused the request: the file is not there, is not a
    /// loadable object, or has an unresolved dependency. The platform's own
    /// diagnosis is not second-guessed here.
    OpenFailed,
    /// The file opened but does not export a symbol the translated header
    /// declares. The candidate is closed and nothing is published. A file that
    /// opens and then fails this way is not an error in this code: it is a
    /// library that is not the one the header describes.
    MissingSymbol,
    /// Every required symbol resolved and the library's own validation then
    /// declined the provider. The candidate is closed and nothing is published.
    ValidationFailed,
    /// A load has already succeeded, from a different request, or one is in
    /// flight for a different request. The provider already chosen stays
    /// chosen; this call changed nothing.
    ProviderMismatch,
    /// `load` was called from a thread that is already inside a load attempt.
    /// The inner call returns this instead of waiting for the outer one, which
    /// is the only answer that is not a deadlock.
    ReentrantLoad,
};

/// The longest request the loader will remember, in bytes.
pub const max_source_len = 32768;

/// What a source request becomes once it is remembered: a tag and a copy of the
/// bytes, with no allocation and nothing to free.
///
/// The copy is not an optimization. The request the caller passed is read during
/// the call and is not retained by this loader, so keeping a copy is what makes
/// "the same request is idempotent" answerable later, long after the caller's
/// buffer may have gone away.
const SourceRecord = struct {
    tag: enum(u8) { none = 0, path, system } = .none,
    len: u32 = 0,
    bytes: [max_source_len]u8 = undefined,

    /// Called under the loader lock after checking the request length.
    fn set(self: *SourceRecord, request: LoadSource) void {
        const text = switch (request) {
            .path => |p| p,
            .system => |s| s,
        };
        @memcpy(self.bytes[0..text.len], text);
        self.len = @intCast(text.len);
        self.tag = switch (request) {
            .path => .path,
            .system => .system,
        };
    }

    /// The remembered request, or null when nothing has been remembered.
    ///
    /// The slice points into this record, so it is valid for as long as the
    /// record is, which is the life of the process.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Two requests are the same request when they name the same kind of thing and
/// the same bytes. A comparison, not a normalization: `"./libx.so"` and
/// `"libx.so"` are different requests, and the second one is refused.
pub fn eqlSource(a: LoadSource, b: LoadSource) bool {
    return switch (a) {
        .path => |pa| switch (b) {
            .path => |pb| std.mem.eql(u8, pa, pb),
            .system => false,
        },
        .system => |sa| switch (b) {
            .system => |sb| std.mem.eql(u8, sa, sb),
            .path => false,
        },
    };
}

fn validateSource(source: LoadSource) LoadError!void {
    const text = switch (source) {
        .path => |p| p,
        .system => |s| s,
    };
    if (text.len == 0) return error.EmptySource;
    if (text.len > max_source_len) return error.SourceTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
    switch (source) {
        .path => {
            const absolute = if (builtin.os.tag == .windows)
                switch (std.fs.path.getWin32PathType(u8, text)) {
                    .drive_absolute, .unc_absolute, .local_device, .root_local_device => true,
                    .relative, .rooted, .drive_relative => false,
                }
            else
                std.fs.path.isAbsolutePosix(text);
            if (!absolute) return error.InvalidSource;
        },
        .system => {
            for (text) |byte| {
                if (std.fs.path.isSep(byte)) return error.InvalidSource;
                if (builtin.os.tag == .windows and byte == ':') return error.InvalidSource;
            }
        },
    }
}

/// The three states of a configured module's table.
pub const Phase = enum(u8) {
    /// Nothing has been loaded. Also the state after a failed attempt, which is
    /// what makes an explicit retry the only way forward.
    not_loaded = 0,
    /// One thread is filling the table. No reader can see it.
    loading = 1,
    /// The table is published and every routed call is usable.
    ready = 2,
};

/// The readiness flag: the one word that says whether the table may be read.
///
/// It is written with release ordering once, at publication, and read with
/// acquire ordering by every call. That pairing is the whole publication
/// protocol: the table writes happen before the release store, so a reader that
/// sees `ready` also sees every field the table holds.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.not_loaded)),

    /// True once a load has succeeded. One acquire load, which is what a routed
    /// call pays before it is allowed to touch the table.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @intFromEnum(Phase.ready);
    }

    /// The current state, for the loader's own decisions under its lock.
    pub fn state(self: *const Ready) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    /// Publish or withdraw the table, with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@intFromEnum(value), .release);
    }
};

/// What kind of exported thing a symbol is. Both kinds are required at load
/// time; they differ only in what is stored in the table field.
pub const SymbolKind = enum {
    /// A function. The table holds its address as the exact function pointer
    /// type the translated header declares, so a call goes out through a
    /// pointer of the same type the C compiler would have used.
    function,
    /// Exported data. The table holds the address of the object, never a copy
    /// of it: a loaded object has no address this module could have named at
    /// compile time, and copying would silently break any write the C side does
    /// through the symbol.
    data,
};

/// One required export: the name to look up and what kind of thing it is.
pub const Symbol = struct {
    /// The exported name, exactly as the C header spells it.
    name: [:0]const u8,
    /// What the table field holds for this symbol.
    kind: SymbolKind,
};

/// Stop the program because a routed call arrived before a successful load.
///
/// This is an ordinary panic in every optimization mode, including ReleaseFast
/// and ReleaseSmall: the alternative is a call through whatever bytes happen to
/// be in the table, and a library that cannot be used yet is a programming
/// error worth a loud, named stop rather than a silent read of uninitialized
/// memory. The message names the library and the function that was reached for,
/// because that is the information a caller needs and cannot otherwise get.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// Whether this target has a dynamic library loader at all.
///
/// Windows has `LoadLibraryExW` and the Unix family has `dlopen`. wasm32-wasi
/// and Emscripten have neither: saying so is better than compiling a reference
/// to a function that does not exist on the target.
pub const supported_target: bool = switch (builtin.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// The process-global loader for one configured module.
///
/// ## The configuration it is given
///
/// `Config` is a *type*, not a value, because the table type and the assignment
/// function are generic over it. A configuration must provide:
///
///   * `library_name: []const u8` — the name used in the pre-load panic;
///   * `table: type` — the dispatch table type the generated dispatch declares;
///   * `symbols: []const Symbol` — every symbol resolved at load time, in the
///     order `assign` expects;
///   * `tablePtr() *table` — where the table lives;
///   * `ready() *Ready` — the readiness flag the routed calls read;
///   * `assign(comptime index: usize, table: *table, address: *const anyopaque)
///     void` — writes one resolved address into one table field, cast to the
///     exact type the translated header declares;
///   * `optional_symbols`, `assignOptional` and `assignMissing` — optional
///     symbols use nullable table fields, cleared before every attempt;
///   * `sync: type` — the project's namespaced synchronization binding, with
///     `lock`, `unlock`, `wait`, `broadcast` and `threadSelf`;
///   * `validate(table: *const table) ?[]const u8` — optional; when present, its
///     result decides `ValidationFailed` before anything is published.
///
/// Anything else the loader needs to know is the loader's business, and anything
/// else the library knows is the configuration's. Neither reaches into the
/// other.
///
/// ## What it guarantees
///
///   * A successful attempt publishes exactly once, with a release store, and
///     the handle and the request copy outlive every later call.
///   * A failed attempt closes its candidate, publishes nothing, and leaves the
///     module in `not_loaded`, so a later `load` starts a fresh attempt. There
///     is no automatic retry.
///   * The same request after success succeeds immediately and changes nothing.
///     A different request after success is `ProviderMismatch`.
///   * A call that arrives while an attempt is in flight for the *same* request
///     becomes a waiter on that attempt and returns that attempt's result,
///     whatever it was. It never starts a competing attempt and never returns a
///     later attempt's result.
///   * A call that arrives while an attempt is in flight for a *different*
///     request is `ProviderMismatch`: that attempt is committed to its provider,
///     so there is nothing to wait for.
///   * A call from the thread running the attempt is `ReentrantLoad`.
///   * A finished attempt is not discarded while waiters are still attached to
///     it, so a failed attempt's waiters drain before a retry can begin.
///
/// ## The constraint that remains
///
/// Mutual exclusion here covers the loader, not the library. A provider whose
/// constructor calls back into this process and blocks waiting for another
/// thread that is calling `load` will deadlock that other thread, because it
/// waits for the attempt it is part of. Nothing here can see that cycle: it is a
/// property of the provider, not of the request.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// The table type this loader fills, for the configuration's own use.
        pub const table_type = Config.table;

        /// The one in-flight or undrained attempt, or null when there is none.
        ///
        /// One per configured module instance, so two SDKs in one process each
        /// have their own, and each has its own table.
        attempt: ?Attempt = null,

        /// Copied once per attempt. Immutable after the READY release store.
        /// Before readiness it is accessed only under the loader lock.
        request: SourceRecord = .{},

        /// Fill the table, or explain why not.
        ///
        /// Safe to call from any thread and any number of times. The rules are
        /// the ones above; this is the only entry point that fills the table.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            // The common case is already loaded, and the common case of that is
            // being asked for the same thing again: one acquire load, no lock.
            if (Config.ready().isReady()) return self.accept(source);


            Config.sync.lock();
            while (true) {
                switch (Config.ready().state()) {
                    .ready => {
                        Config.sync.unlock();
                        return self.accept(source);
                    },
                    .loading => {
                        const attempt = &self.attempt.?;
                        if (attempt.owner == Config.sync.threadSelf()) {
                            Config.sync.unlock();
                            return error.ReentrantLoad;
                        }
                        if (!eqlSource(self.request.source().?, source)) {
                            Config.sync.unlock();
                            return error.ProviderMismatch;
                        }
                        // Attach to this attempt and wait for it rather than
                        // starting one: the outcome this caller needs is decided
                        // by an attempt that already exists.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        // The record cannot be cleared until every waiter has
                        // taken its result, and clearing it is what lets a retry
                        // start.
                        Config.sync.broadcast();
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // A finished attempt that still has waiters on it is
                        // still in the record. Wait for the drain; the thread
                        // doing the draining clears it and wakes us.
                        if (self.attempt != null) {
                            Config.sync.wait();
                            continue;
                        }
                        break;
                    },
                }
            }

            self.request.set(source);
            self.attempt = .{ .owner = Config.sync.threadSelf() };
            Config.ready().set(.loading);
            Config.sync.unlock();

            // The platform call runs with no lock held: it takes as long as the
            // provider's constructors take, and every other thread calling
            // `load` waits on the attempt rather than on the lock.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Waiters attached to this attempt: here is its result. A broadcast
            // rather than a signal, because every one of them has to leave
            // before the drain below can finish, and the count is not known
            // here.
            Config.sync.broadcast();
            // The record stays until every waiter has taken its result. This
            // loop releases the lock while it waits, so those waiters can run.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Anyone waiting to start a retry was waiting for exactly this.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// The request that succeeded, or null when nothing has loaded.
        ///
        /// Valid at any time: null means nothing has succeeded, and a non-null
        /// answer is the retained request, valid for the life of the process.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

        /// The request already in use, checked against a new one.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            // The acquire load precedes every call to accept.
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Open, resolve, validate. Runs with no lock held.
        ///
        /// Nothing here touches the readiness flag, so nothing here can publish.
        /// The candidate is closed on every path that does not succeed.
        fn runAttempt(source: LoadSource) LoadError!void {
            const handle = platform.open(source) catch |err| return err;

            var retain = false;
            defer if (!retain) platform.close(handle);

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |_, index| {
                    Config.assignMissing(index, Config.tablePtr());
                }
            }

            inline for (Config.symbols, 0..) |symbol, index| {
                const address = platform.lookup(handle, symbol.name) orelse
                    return error.MissingSymbol;
                Config.assign(index, Config.tablePtr(), address);
            }

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |symbol, index| {
                    if (platform.lookup(handle, symbol.name)) |address| {
                        Config.assignOptional(index, Config.tablePtr(), address);
                    }
                }
            }

            if (@hasDecl(Config, "validate")) {
                if (Config.validate(Config.tablePtr())) |refusal| {
                    // The refusal is the whole point of the check; returning the
                    // error name alone would spend the answer on nothing.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Success. The handle is not closed: the table points into it for
            // the rest of the process.
            retain = true;
        }
    };
}

// ---------------------------------------------------------------------------
// Platform layer
//
// dlopen/dlsym/dlclose, or the Windows equivalents. A target with no dynamic
// loader fails every request rather than pretending to have one.
// ---------------------------------------------------------------------------

/// One in-flight or undrained load attempt.
const Attempt = struct {
    /// Identity of the thread running the attempt, for the reentrancy check.
    owner: u64,
    /// This attempt's result. Written once, while the loader holds its lock and
    /// before the readiness flag leaves `loading`, which is what every waiter
    /// waits for. Meaningful only after that, and read only after that.
    result: LoadError!void = error.OpenFailed,
    /// Waiters that have attached and not yet taken their result. The record
    /// outlives the attempt itself until this reaches zero.
    waiters: usize = 0,
};

/// Longest path this loader converts for the Windows loader, in UTF-16 code
/// units. Windows documents 32767 as the longest possible path, and UTF-8 needs
/// at most one code unit per byte, so a byte length at or below this always
/// fits the buffer.
const windows_path_units = 32768;

const platform = if (builtin.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// A target with no dynamic loader. Every request is refused by name.
const NoLoader = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        _ = source;
        return error.UnsupportedTarget;
    }
    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        _ = handle;
        _ = name;
        return null;
    }
    fn close(handle: *anyopaque) void {
        _ = handle;
    }
};

/// The Unix dynamic loader.
const Unix = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        var buffer: [max_source_len + 1]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        // RTLD_NOW, so a provider whose own dependencies are missing fails
        // here, where the failure can be reported, instead of at the first call
        // into it. RTLD_LOCAL, so loading a provider does not add its symbols
        // to the global namespace, where a second SDK's lookup could find them.
        return std.c.dlopen(
            // A sentinel-terminated pointer, which the loader needs and a plain
            // slice cannot be.
            buffer[0..text.len :0].ptr,
            .{ .NOW = true, .GLOBAL = false },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return std.c.dlsym(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
};

/// The Windows dynamic loader, declared here rather than taken from std, so the
/// binding is one short block with no platform conditionals spread around it.
const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// The Windows dynamic loader.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS`: search the standard directories for
    /// a bare name, and use a path containing separators exactly as written. It
    /// does not add the current directory, which is why it is chosen here: what
    /// gets loaded is what was named.
    const load_library_search_default_dirs: u32 = 0x0000_1000;
    const load_library_search_dll_load_dir: u32 = 0x0000_0100;

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        if (text.len > windows_path_units) return error.SourceTooLong;
        var buffer: [windows_path_units + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(buffer[0..text.len], text) catch
            return error.OpenFailed;
        buffer[units] = 0;
        return kernel32.LoadLibraryExW(
            buffer[0..units :0],
            null,
            load_library_search_default_dirs | switch (source) {
                .path => load_library_search_dll_load_dir,
                .system => @as(u32, 0),
            },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return kernel32.GetProcAddress(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = kernel32.FreeLibrary(handle);
    }
};