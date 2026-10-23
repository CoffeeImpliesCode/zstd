// SPDX-License-Identifier: MIT
//
//! Process-global dynamic loader for one configured C API.
//! The caller names a file path or system library; there is no fallback, unload,
//! or automatic retry. The table publishes only after symbol resolution and
//! validation; failures close the candidate and leave the table unpublished.
//! A provider constructor that waits on another thread calling `load` can deadlock.

const std = @import("std");
const builtin = @import("builtin");

/// Choose a file path or system library; there is no fallback between them.
pub const LoadSource = union(enum) {
    /// Absolute file path; relative paths are invalid.
    path: []const u8,
    /// Basename or SONAME; separators and embedded NUL bytes are invalid.
    system: []const u8,
};

/// Every way `load` can decline.
pub const LoadError = error{
    /// Empty path or system name; rejected before the platform call.
    EmptySource,
    /// Request exceeds `max_source_len`; it is refused, never truncated.
    SourceTooLong,
    /// Invalid path/name or embedded NUL; no platform call was made.
    InvalidSource,
    /// Target has no dynamic loader; no fallback is attempted.
    UnsupportedTarget,
    /// Platform loader refused the request.
    OpenFailed,
    /// Required export is missing; the candidate is closed without publication.
    MissingSymbol,
    /// Provider validation failed; the candidate is closed without publication.
    ValidationFailed,
    /// A different request already succeeded or is in flight.
    ProviderMismatch,
    /// The attempt's own thread called `load` again.
    ReentrantLoad,
};

/// The longest request the loader will remember, in bytes.
pub const max_source_len = 32768;

/// Retained source tag and bytes, without allocation.
/// The copy lets later idempotence checks outlive the caller's buffer.
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

    /// Return the remembered request, valid for this record's lifetime.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Compare request kind and bytes exactly; paths are not normalized.
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
    /// No successful load; explicit retry is possible after failure.
    not_loaded = 0,
    /// A load attempt is filling the table.
    loading = 1,
    /// The table is published and routed calls are usable.
    ready = 2,
};

/// Release/acquire flag for publishing the table.
/// Readers that observe `ready` also observe the table writes.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.not_loaded)),

    /// Acquire-load readiness before a routed call accesses the table.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @intFromEnum(Phase.ready);
    }

    /// Current state for loader decisions under its lock.
    pub fn state(self: *const Ready) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    /// Publish the phase with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@intFromEnum(value), .release);
    }
};

/// Required export kind; the table stores a function pointer or object address.
pub const SymbolKind = enum {
    /// Function address with the translated header's exact pointer type.
    function,
    /// Live object address; copying it would break writes through the symbol.
    data,
};

/// One required export: the name to look up and what kind of thing it is.
pub const Symbol = struct {
    /// The exported name, exactly as the C header spells it.
    name: [:0]const u8,
    /// What the table field holds for this symbol.
    kind: SymbolKind,
};

/// Panic in every optimization mode if a routed call occurs before load.
/// The diagnostic names the library and symbol.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// Whether this target supports dynamic loading; WASI, Emscripten, and freestanding do not.
pub const supported_target: bool = switch (builtin.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// Process-global loader; publishes only after resolution and validation.
/// Failures close; retries are explicit after waiters drain.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// Table type supplied by the dispatch configuration.
        pub const table_type = Config.table;

        /// Current or undrained attempt; one per configured module.
        attempt: ?Attempt = null,

        /// Request copy; immutable after publication and lock-protected before it.
        request: SourceRecord = .{},

        /// Load from any thread; same-source calls share the attempt.
        /// Failed attempts can be retried; mismatched and reentrant calls fail.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            // An identical loaded request needs one acquire and no lock.
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
                        // Join the existing same-source attempt.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        // Keep the attempt until every waiter reads its result.
                        Config.sync.broadcast();
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // Wait for prior waiters to drain before retrying.
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

            // Run the platform call unlocked; other callers wait on the attempt.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Wake all waiters; retries wait until they have drained.
            Config.sync.broadcast();
            // Keep the record until every waiter has taken its result.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Wake threads waiting to start a retry.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// Return the successful request, or null before any load succeeds.
        /// The retained request stays valid for the process lifetime.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

        /// Check a new request against the published one.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            // The readiness acquire precedes this call.
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Open, resolve, and validate without the lock.
        /// Close the candidate on every failure path.
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
                    // Include the validation reason in the diagnostic.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Retain the handle while the published table points into it.
            retain = true;
        }
    };
}

/// Current or undrained load attempt.
const Attempt = struct {
    /// Thread running the attempt, for reentrancy detection.
    owner: u64,
    /// Result, published before readiness changes from `loading`.
    result: LoadError!void = error.OpenFailed,
    /// Waiters that must read this result before the record is cleared.
    waiters: usize = 0,
};

/// Windows path limit in UTF-16 code units; UTF-8 byte length is an upper bound.
const windows_path_units = 32768;

const platform = if (builtin.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// Refuses all requests on targets without a dynamic loader.
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

/// Unix dynamic loader bindings.
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
        // Resolve dependencies now and keep symbols local to avoid cross-SDK lookups.
        return std.c.dlopen(
            // `dlopen` requires a sentinel-terminated pointer.
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

/// Minimal direct bindings to the Windows dynamic loader.
const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// Windows dynamic loader.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// Search standard directories for bare names; paths are loaded as named.
    /// The default directories exclude the current directory.
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
