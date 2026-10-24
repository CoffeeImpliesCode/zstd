// SPDX-License-Identifier: MIT
//
//! Build-time generator for a runtime dispatch from Aro's translated header.
//! Emits a typed dispatch and a translation with `__root` redirected to it.
//! Required symbols fail at load; optional symbols stay nullable; direct symbols
//! remain linked. Unsupported declarations are rejected instead of guessed.

const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const Writer = std.Io.Writer;
const Tag = std.zig.Token.Tag;

/// Maximum accepted translation size, to bound memory use.
const max_translated_bytes = 64 * 1024 * 1024;

const Failure = error{
    TranslateUnreadable,
    TranslateDoesNotParse,
    MissingLibrary,
    MissingTranslate,
    MissingOutput,
    UnknownArgument,
    NothingRouted,
    UnsupportedDeclaration,
} || std.mem.Allocator.Error || Writer.Error;

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const options = Options.parse(arena, args) catch |err| {
        usage();
        return err;
    };

    const generated = try generate(init.io, arena, options);
    try Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = options.output,
        .data = generated.dispatch,
    });
    if (options.native_output.len != 0) {
        try Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = options.native_output,
            .data = generated.native,
        });
    }
}

fn usage() void {
    std.debug.print(
        \\usage: generate --library <name> --translate <translated.zig> --output <dispatch.zig>
        \\                  [--native-output <patched.zig>] [--noise a,b]
        \\                  [--optional a,b] [--exclude a,b]
        \\
    , .{});
}

const Options = struct {
    library: []const u8 = "",
    translate: []const u8 = "",
    output: []const u8 = "",
    /// Patched translation output; empty disables patching.
    native_output: []const u8 = "",
    /// `extern` declarations to keep direct because the C library provides them.
    noise: std.StringHashMapUnmanaged(void) = .empty,
    /// `extern` declarations the provider may legitimately not have.
    optional: std.StringHashMapUnmanaged(void) = .empty,
    /// `extern` declarations this build deliberately does not require.
    exclude: std.StringHashMapUnmanaged(void) = .empty,

    fn parse(arena: std.mem.Allocator, args: []const [:0]const u8) Failure!Options {
        var self: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--library")) {
                self.library = take(args, &index);
            } else if (std.mem.eql(u8, flag, "--translate")) {
                self.translate = take(args, &index);
            } else if (std.mem.eql(u8, flag, "--output")) {
                self.output = take(args, &index);
            } else if (std.mem.eql(u8, flag, "--native-output")) {
                self.native_output = take(args, &index);
            } else if (std.mem.eql(u8, flag, "--noise")) {
                try addNames(arena, &self.noise, take(args, &index));
            } else if (std.mem.eql(u8, flag, "--optional")) {
                try addNames(arena, &self.optional, take(args, &index));
            } else if (std.mem.eql(u8, flag, "--exclude")) {
                try addNames(arena, &self.exclude, take(args, &index));
            } else {
                std.debug.print("runtime/generate.zig: unknown argument '{s}'\n", .{flag});
                return error.UnknownArgument;
            }
        }
        if (self.library.len == 0) return error.MissingLibrary;
        if (self.translate.len == 0) return error.MissingTranslate;
        if (self.output.len == 0) return error.MissingOutput;
        return self;
    }

    /// How an extern is handled after the build lists are checked.
    /// Exclusions become optional; then optional, direct, and routed apply.
    const Route = enum { routed, optional, direct };

    fn routeOf(self: Options, name: []const u8) Route {
        if (self.exclude.contains(name)) return .optional;
        if (self.optional.contains(name)) return .optional;
        if (self.noise.contains(name)) return .direct;
        return .routed;
    }
};

fn take(args: []const [:0]const u8, index: *usize) []const u8 {
    if (index.* + 1 >= args.len) return "";
    index.* += 1;
    return args[index.*];
}

fn addNames(
    arena: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    list: []const u8,
) std.mem.Allocator.Error!void {
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        // Trim wrapped list entries so their names still match.
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) continue;
        try set.put(arena, name, {});
    }
}

const routed_import = "c_routed";

const Class = enum {
    /// Required extern function routed through the table.
    routed_function,
    /// Required extern object routed through an accessor.
    routed_data,
    /// Optional function; calls fail if the provider lacks it.
    optional_function,
    optional_data,
    /// Copied declaration, with dispatch references rewritten.
    copied,
    /// The translation's root prologue; patched separately.
    root_prologue,
    /// Re-exported from the patched translation.
    reexport,
    /// Forwarding wrapper for an alias.
    alias_function,
    /// Guarded accessor for an alias.
    alias_data,
};

const Decl = struct {
    name: []const u8,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    class: Class,

    is_pub: bool = false,
    uses_root: bool = false,
    needs_rewrite: bool = false,

    alias_of: []const u8 = "",
    target: []const u8 = "",
    target_class: Class = .copied,

    variadic: bool = false,
    fixed_params: usize = 0,
    params: []const u8 = "",
    tail: []const u8 = "",
    /// Function-pointer or object-address type, copied from the header.
    field_type: []const u8 = "",
    /// The extern pointer already denotes the object's address.
    address_value: bool = false,
    arguments: []const []const u8 = &.{},
};

const Plan = struct {
    decls: []const Decl,
    /// Routed object names that copied declarations access through wrappers.
    data_names: std.StringHashMapUnmanaged(bool),
    /// Routed variadic function names and their fixed parameter counts.
    variadic_names: std.StringHashMapUnmanaged(usize),
    root_refs: std.StringHashMapUnmanaged(void),
    dispatch_needs_root: bool,
    root_decl: ?Decl = null,
};

fn generate(
    io: Io,
    arena: std.mem.Allocator,
    options: Options,
) Failure!struct { dispatch: []const u8, native: []const u8 } {
    const source_z = try readSentinel(io, arena, options.translate);
    var tree = try Ast.parse(arena, source_z, .{ .mode = .zig });
    defer tree.deinit(arena);

    if (tree.errors.len != 0) {
        const first = tree.errors[0];
        std.debug.print(
            "runtime/generate.zig: the translated source '{s}' does not parse: {s} " ++
                "at line {d}\n",
            .{
                options.translate,
                @tagName(first.tag),
                tree.tokenLocation(0, first.token).line + 1,
            },
        );
        return error.TranslateDoesNotParse;
    }

    const plan = try planDeclarations(arena, options, &tree);
    try checkRootReferences(options, &plan);

    var dispatch: Writer.Allocating = .init(arena);
    const w = &dispatch.writer;
    try writePreamble(w, options, plan.dispatch_needs_root);
    try writeTableOpen(w);
    try writeTableClose(w, &plan);
    for (plan.decls) |decl| switch (decl.class) {
        .copied => try writeCopied(w, arena, &tree, decl, &plan),
        // The patched translation emits this prologue.
        .root_prologue => {},
        .reexport => try w.print("pub const {s} = c_native.{s};\n", .{ decl.name, decl.name }),
        .routed_function, .optional_function => try writeFunction(w, decl),
        .alias_function => try writeAliasFunction(w, decl),
        .routed_data, .optional_data => try writeDataAccessor(w, decl),
        .alias_data => try writeAliasDataAccessor(w, decl),
    };

    var native: []const u8 = "";
    if (options.native_output.len != 0) {
        native = try writePatchedNative(arena, &tree, plan.root_decl);
    }

    return .{ .dispatch = try dispatch.toOwnedSlice(), .native = native };
}

fn readSentinel(io: Io, arena: std.mem.Allocator, path: []const u8) Failure![:0]const u8 {
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(max_translated_bytes),
        .of(u8),
        0,
    ) catch |err| {
        std.debug.print(
            "runtime/generate.zig: cannot read the translated source '{s}': {t}\n",
            .{ path, err },
        );
        return error.TranslateUnreadable;
    };
}

fn planDeclarations(
    arena: std.mem.Allocator,
    options: Options,
    tree: *const Ast,
) Failure!Plan {
    var decls: std.ArrayList(Decl) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;

    for (tree.rootDecls()) |node| {
        const decl = switch (tree.nodeTag(node)) {
            .fn_decl, .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => try planFunction(arena, options, tree, node),
            .simple_var_decl, .aligned_var_decl, .global_var_decl => try planVariable(arena, options, tree, node),
            // Ignore non-interface declarations.
            else => continue,
        };
        if (decl.name.len != 0 and !index.contains(decl.name)) {
            try index.put(arena, decl.name, decls.items.len);
        }
        try decls.append(arena, decl);
    }

    // Resolve aliases before writing; reject cycles rather than guessing.
    for (decls.items) |*decl| {
        if (decl.alias_of.len == 0) continue;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var current = decl.alias_of;
        while (true) {
            const at = index.get(current) orelse break;
            const next = decls.items[at];
            if (next.alias_of.len == 0) break;
            if (seen.contains(current)) {
                std.debug.print(
                    "runtime/generate.zig: '{s}' aliases '{s}', whose chain returns to a " ++
                        "name it already visited; an alias loop has no declaration to copy.\n",
                    .{ decl.name, current },
                );
                return error.UnsupportedDeclaration;
            }
            try seen.put(arena, current, {});
            current = next.alias_of;
        }

        // Leave initializer references without a top-level declaration unchanged.
        const terminal = index.get(current) orelse continue;
        decl.target = current;
        const reached = decls.items[terminal];
        decl.target_class = reached.class;
        switch (reached.class) {
            .routed_function, .optional_function => {
                decl.class = .alias_function;
                decl.variadic = reached.variadic;
                decl.fixed_params = reached.fixed_params;
                decl.params = reached.params;
                decl.tail = reached.tail;
                decl.field_type = reached.field_type;
                decl.arguments = reached.arguments;
            },
            .routed_data, .optional_data => {
                decl.class = .alias_data;
                decl.field_type = reached.field_type;
                decl.address_value = reached.address_value;
            },
            // Copy aliases of private declarations with their target.
            else => decl.class = .copied,
        }
    }

    var data_names: std.StringHashMapUnmanaged(bool) = .empty;
    var variadic_names: std.StringHashMapUnmanaged(usize) = .empty;
    for (decls.items) |decl| switch (decl.class) {
        .routed_data, .optional_data, .alias_data => try data_names.put(arena, decl.name, decl.address_value),
        .routed_function, .optional_function, .alias_function => {
            if (decl.variadic) try variadic_names.put(arena, decl.name, decl.fixed_params);
        },
        else => {},
    };

    var root_refs: std.StringHashMapUnmanaged(void) = .empty;
    var dispatch_needs_root = false;
    var root_decl: ?Decl = null;
    for (decls.items) |*decl| {
        if (std.mem.eql(u8, decl.name, "__root")) {
            root_decl = decl.*;
            // Only Aro's recognized `__root = @This()` prologue can be patched.
            if (isThisPrologue(arena, tree, decl.*)) decl.class = .root_prologue;
            continue;
        }
        const tokens = try significantTokens(arena, tree, decl.first, decl.last);
        decl.uses_root = try collectRootReferences(arena, tokens, &root_refs);
        if (decl.class == .copied) {
            if (try usesDispatchName(arena, tokens, data_names, variadic_names)) {
                decl.needs_rewrite = true;
            }
            if (decl.uses_root) dispatch_needs_root = true;
        }
    }

    if (countRouted(decls.items) == 0) {
        std.debug.print(
            "runtime/generate.zig: no native symbol is required at load time for '{s}'. " ++
                "Every extern declaration in the translated header is libc noise or an " ++
                "optional symbol this build does not require, so there would be nothing " ++
                "to resolve at load time.\n",
            .{options.library},
        );
        return error.NothingRouted;
    }

    return .{
        .decls = decls.items,
        .data_names = data_names,
        .variadic_names = variadic_names,
        .root_refs = root_refs,
        .dispatch_needs_root = dispatch_needs_root,
        .root_decl = root_decl,
    };
}

fn countRouted(decls: []const Decl) usize {
    var count: usize = 0;
    for (decls) |decl| switch (decl.class) {
        .routed_function, .routed_data, .optional_function, .optional_data => count += 1,
        else => {},
    };
    return count;
}

fn planFunction(
    arena: std.mem.Allocator,
    options: Options,
    tree: *const Ast,
    node: Ast.Node.Index,
) Failure!Decl {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node) orelse return unnamedDecl(tree, node);
    const name_token = proto.name_token orelse return unnamedDecl(tree, node);
    const name = tree.tokenSlice(name_token);

    var decl = Decl{
        .name = name,
        .first = proto.firstToken(),
        .last = declarationEndToken(tree, node),
        .class = .copied,
        .is_pub = proto.visib_token != null,
    };

    const keyword: []const u8 = if (proto.extern_export_inline_token) |token|
        tree.tokenSlice(token)
    else
        "";

    // Copy definitions; route only extern declarations.
    if (!std.mem.eql(u8, keyword, "extern")) return decl;

    switch (options.routeOf(name)) {
        .direct => return decl,
        .routed => decl.class = .routed_function,
        .optional => decl.class = .optional_function,
    }
    try planSignature(arena, tree, &proto, &decl);
    return decl;
}

fn unnamedDecl(tree: *const Ast, node: Ast.Node.Index) Decl {
    const last = declarationEndToken(tree, node);
    return .{ .name = "", .first = last, .last = last, .class = .copied };
}

/// Extract the translated prototype for the table and wrapper.
/// Preserve its signature and rename wrapper parameters to avoid shadowing.
fn planSignature(
    arena: std.mem.Allocator,
    tree: *const Ast,
    proto: *const Ast.full.FnProto,
    decl: *Decl,
) Failure!void {
    var params: std.ArrayList(u8) = .empty;
    var arguments: std.ArrayList([]const u8) = .empty;
    var variadic = false;
    var iterator = proto.iterate(tree);
    while (iterator.next()) |param| {
        if (params.items.len != 0) try params.appendSlice(arena, ", ");
        if (param.anytype_ellipsis3) |token| {
            if (!std.mem.eql(u8, tree.tokenSlice(token), "...")) return error.UnsupportedDeclaration;
            try params.appendSlice(arena, "rt_args: anytype");
            variadic = true;
            continue;
        }
        const type_node = param.type_expr orelse return error.UnsupportedDeclaration;
        if (param.comptime_noalias) |token| {
            if (!std.mem.eql(u8, tree.tokenSlice(token), "noalias")) return error.UnsupportedDeclaration;
            try params.appendSlice(arena, "noalias ");
        }
        const argument = try arena.print("rt_p{d}", .{arguments.items.len});
        try params.appendSlice(arena, argument);
        try params.appendSlice(arena, ": ");
        try params.appendSlice(arena, tokenRangeText(tree, tree.firstToken(type_node), tree.lastToken(type_node)));
        try arguments.append(arena, argument);
    }
    const return_node = proto.ast.return_type.unwrap() orelse return error.UnsupportedDeclaration;
    const return_text = tokenRangeText(tree, tree.firstToken(return_node), tree.lastToken(return_node));
    const calling_convention = if (proto.ast.callconv_expr.unwrap()) |conv|
        tokenRangeText(tree, tree.firstToken(conv), tree.lastToken(conv))
    else
        ".c";
    if (variadic and !std.mem.eql(u8, calling_convention, ".c")) {
        std.debug.print(
            "runtime/generate.zig: '{s}' is variadic with calling convention {s}; a " ++
                "variadic call is only expressible with .c.\n",
            .{ decl.name, calling_convention },
        );
        return error.UnsupportedDeclaration;
    }
    // Pass variadic arguments as the tuple Zig expects.
    const tail = if (variadic)
        try arena.print(" {s}", .{return_text})
    else
        try arena.print(" callconv({s}) {s}", .{ calling_convention, return_text });
    const rparen = matchingRParenToken(tree, proto.lparen);
    const native_params = tokenRangeText(tree, proto.lparen, rparen);
    decl.variadic = variadic;
    decl.fixed_params = arguments.items.len;
    decl.params = params.items;
    decl.tail = tail;
    decl.arguments = arguments.items;
    decl.field_type = try arena.print("*const fn {s} callconv({s}) {s}", .{
        native_params, calling_convention, return_text,
    });
}

fn planVariable(
    arena: std.mem.Allocator,
    options: Options,
    tree: *const Ast,
    node: Ast.Node.Index,
) Failure!Decl {
    const var_decl = tree.fullVarDecl(node) orelse return unnamedDecl(tree, node);
    const last = declarationEndToken(tree, node);
    const mut_token = var_decl.ast.mut_token;
    // Quoted names are not identifiers the dispatch can name.
    const name = switch (tree.tokenTag(mut_token + 1)) {
        .identifier => declarationName(tree, mut_token + 1, last) orelse "",
        else => "",
    };
    const is_extern = if (var_decl.extern_export_token) |token|
        std.mem.eql(u8, tree.tokenSlice(token), "extern")
    else
        false;

    var decl = Decl{
        .name = name,
        .first = var_decl.firstToken(),
        .last = last,
        .class = .copied,
        .is_pub = var_decl.visib_token != null,
    };

    // The patched translation emits this prologue.
    if (std.mem.eql(u8, name, "__root")) return decl;
    if (name.len == 0) return decl;

    if (!is_extern) {
        if (var_decl.ast.init_node.unwrap()) |initializer| {
            const first = tree.firstToken(initializer);
            if (tree.tokenTag(first) == .builtin and std.mem.eql(u8, tree.tokenSlice(first), "@extern")) {
                switch (options.routeOf(name)) {
                    .direct => return decl,
                    .routed => decl.class = .routed_data,
                    .optional => decl.class = .optional_data,
                }
                const type_node = var_decl.ast.type_node.unwrap() orelse {
                    std.debug.print("runtime/generate.zig: @extern address '{s}' has no explicit type.\n", .{name});
                    return error.UnsupportedDeclaration;
                };
                const type_first = tree.firstToken(type_node);
                const type_last = tree.lastToken(type_node);
                // @TypeOf on an extern constant can force a direct link.
                // Copy only its pointer type; the translated module owns named types.
                decl.field_type = tree.source[tree.tokenStart(type_first) .. tree.tokenStart(type_last) + tree.tokenSlice(type_last).len];
                decl.address_value = true;
                return decl;
            }
        }
        if (initializerAlias(tree, decl.first, last)) |alias_of| decl.alias_of = alias_of;
        // Copy private declarations; re-export public declarations to preserve type identity.
        if (!decl.is_pub or decl.alias_of.len != 0) return decl;
        decl.class = .reexport;
        return decl;
    }

    // Exported objects need live addresses; copying or re-exporting is invalid.
    switch (options.routeOf(name)) {
        .direct => return decl,
        .routed => decl.class = .routed_data,
        .optional => decl.class = .optional_data,
    }
    const type_text = try dataTypeText(arena, tree, var_decl, name, last);
    const is_mutable = std.mem.eql(u8, tree.tokenSlice(mut_token), "var");
    decl.field_type = if (is_mutable)
        try arena.print("*{s}", .{type_text})
    else
        try arena.print("*const {s}", .{type_text});
    return decl;
}

fn dataTypeText(
    arena: std.mem.Allocator,
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    name: []const u8,
    last: Ast.TokenIndex,
) Failure![]const u8 {
    const type_node = var_decl.ast.type_node.unwrap() orelse {
        std.debug.print(
            "runtime/generate.zig: extern '{s}' has no type; the translation step " ++
                "produced something this generator cannot route.\n",
            .{name},
        );
        return error.UnsupportedDeclaration;
    };
    const text = tree.source[tree.tokenStart(tree.firstToken(type_node))..tree.tokenStart(last)];
    if (std.mem.indexOfScalar(u8, text, '=') != null) {
        std.debug.print(
            "runtime/generate.zig: extern '{s}' is initialized; an exported object " ++
                "with an initializer is not a plain extern declaration.\n",
            .{name},
        );
        return error.UnsupportedDeclaration;
    }
    return arena.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
}

/// Return a simple alias target, including Aro's optional `__root.` prefix.
fn initializerAlias(
    tree: *const Ast,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
) ?[]const u8 {
    var depth: u32 = 0;
    var equal: ?Ast.TokenIndex = null;
    var index = first;
    while (index <= last) : (index += 1) switch (tree.tokenTag(index)) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .equal => if (depth == 0) {
            equal = index;
        },
        else => {},
    };
    const equal_token = equal orelse return null;

    var name: ?[]const u8 = null;
    index = equal_token + 1;
    while (index <= last) : (index += 1) {
        switch (tree.tokenTag(index)) {
            .identifier => {
                const text = tree.tokenSlice(index);
                if (std.mem.eql(u8, text, "__root")) continue;
                if (name != null) return null;
                name = text;
            },
            .period => {},
            .semicolon => break,
            else => return null,
        }
    }
    return name;
}

/// Collect declaration-local names so rewrites respect shadowing.
fn localNames(
    arena: std.mem.Allocator,
    tokens: Tokens,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (0..tokens.len()) |at| {
        if (tokens.tag(at) != .identifier) continue;
        const introduces = if (at == 0) false else switch (tokens.tag(at - 1)) {
            .keyword_var, .keyword_const, .keyword_fn, .keyword_comptime, .pipe, .pipe_pipe => true,
            else => false,
        };
        const labelled = at + 1 < tokens.len() and tokens.tag(at + 1) == .colon;
        if (!introduces and !labelled) continue;
        try names.put(arena, tokens.slice(at), {});
    }
    return names;
}

/// Whether a copied declaration references a name supplied by the dispatch.
fn usesDispatchName(
    arena: std.mem.Allocator,
    tokens: Tokens,
    data_names: std.StringHashMapUnmanaged(bool),
    variadic_names: std.StringHashMapUnmanaged(usize),
) std.mem.Allocator.Error!bool {
    const locals = try localNames(arena, tokens);
    for (0..tokens.len()) |at| {
        if (tokens.tag(at) != .identifier) continue;
        const text = tokens.slice(at);
        if (locals.contains(text)) continue;
        // Member names do not reference top-level declarations.
        if (at > 0 and tokens.tag(at - 1) == .period) continue;
        if (data_names.contains(text)) return true;
        if (variadic_names.contains(text) and at + 1 < tokens.len() and tokens.tag(at + 1) == .l_paren) return true;
    }
    return false;
}

/// Names referenced through the translated module's `__root`.
fn collectRootReferences(
    arena: std.mem.Allocator,
    tokens: Tokens,
    refs: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!bool {
    var found = false;
    for (0..tokens.len()) |at| {
        if (tokens.tag(at) != .identifier) continue;
        if (!std.mem.eql(u8, tokens.slice(at), "__root")) continue;
        if (at + 2 >= tokens.len()) continue;
        if (tokens.tag(at + 1) != .period or tokens.tag(at + 2) != .identifier) continue;
        try refs.put(arena, tokens.slice(at + 2), {});
        found = true;
    }
    return found;
}

/// Reject `__root.NAME` references that the dispatch cannot publish.
fn checkRootReferences(options: Options, plan: *const Plan) Failure!void {
    if (options.native_output.len == 0) {
        for (plan.decls) |decl| {
            if (!decl.uses_root) continue;
            std.debug.print(
                "runtime/generate.zig: '{s}' resolves names through __root, which this " ++
                    "build did not ask to be patched, so the translation would resolve " ++
                    "them against the raw externs instead of this dispatch.\n",
                .{decl.name},
            );
            return error.UnsupportedDeclaration;
        }
    }
    var names = plan.root_refs.keyIterator();
    while (names.next()) |name_ptr| {
        const name = name_ptr.*;
        var published = false;
        var target: Class = .copied;
        for (plan.decls) |decl| {
            if (!std.mem.eql(u8, decl.name, name)) continue;
            target = decl.class;
            published = decl.is_pub;
            break;
        }
        if (!published) {
            std.debug.print(
                "runtime/generate.zig: the translation refers to __root.{s}, which it " ++
                    "does not publish at the top level. The dispatch publishes no " ++
                    "private name, so the patched translation could not resolve it.\n",
                .{name},
            );
            return error.UnsupportedDeclaration;
        }
        switch (target) {
            .routed_data, .optional_data, .alias_data => {
                std.debug.print(
                    "runtime/generate.zig: the translation refers to __root.{s}, an " ++
                        "exported object. A live address cannot be named by a `const`, " ++
                        "so a declaration nested in a translated type cannot alias one.\n",
                    .{name},
                );
                return error.UnsupportedDeclaration;
            },
            else => {},
        }
    }
}

fn writePreamble(w: *Writer, options: Options, needs_root: bool) !void {
    try w.writeAll(
        \\// Generated by runtime/generate.zig. Do not edit: the build rewrites this
        \\// file, and every name in it comes from the translation step for this
        \\// target and configuration.
        \\
        \\// `c_native` is the patched translation. Its declarations are re-exported
        \\// here, never copied, so a type named by this module is the same type the
        \\// translated header declares; its `__root` resolves here, so a declaration
        \\// nested inside a translated type names the routed wrapper.
        \\
        \\const std = @import("std");
        \\const rt = @import("rt");
        \\const c_native = @import("c_native");
        \\
        \\/// Declared only by this generated dispatch. A module that imports the
        \\/// translated header directly does not have it, which is how a facade
        \\/// tells the two configurations apart at comptime.
        \\pub const rt_runtime_loaded = true;
        \\
        \\/// The SDK this dispatch belongs to, for diagnostics.
        \\
    );
    try w.print("pub const library_name = \"{s}\";\n\n", .{options.library});
    try w.writeAll(
        \\const library = @import("library");
        \\
        \\/// The loader's configuration, from this SDK's own descriptor. It is
        \\/// given the dispatch as a type, so the descriptor never imports this
        \\/// module and the two can never hold different tables.
        \\const Config = library.Config(@This());
        \\
        \\/// The one loader for this configured module. Process-global by
        \\/// construction: one instance, for the life of the process.
        \\var loader: rt.Loader(Config) = .{};
        \\
        \\/// Which native library `load` opens. See `rt.LoadSource`.
        \\pub const LoadSource = rt.LoadSource;
        \\
        \\/// Every way `load` can decline. See `rt.LoadError`.
        \\pub const LoadError = rt.LoadError;
        \\
        \\/// True in this configuration: the symbols arrive at run time.
        \\pub const runtime_loaded = true;
        \\
        \\/// Fill the table from `source`, or explain why not. Safe to call from
        \\/// any thread and any number of times: the same request twice succeeds,
        \\/// a different one is refused, and a failure is retried only when the
        \\/// caller asks for it.
        \\pub fn load(source: rt.LoadSource) rt.LoadError!void {
        \\    return loader.load(source);
        \\}
        \\
        \\/// The request that succeeded, or null when nothing has loaded. The
        \\/// slice is the loader's own retained copy and stays valid for the life
        \\/// of the process.
        \\pub fn loadedSource() ?rt.LoadSource {
        \\    return loader.loadedSource();
        \\}
        \\
        \\/// Readiness of this table. Written once with release ordering when a
        \\/// load succeeds, and read with acquire ordering by every routed call.
        \\/// It lives here rather than inside the loader so a routed call reads one
        \\/// global instead of chasing a pointer to find one.
        \\pub var ready: rt.Ready = .{};
        \\
        \\/// The readiness check every routed call makes before touching the
        \\/// table. An ordinary panic in every optimization mode: a call before a
        \\/// successful load is a programming error, not a recoverable condition.
        \\inline fn requireReady(comptime symbol: []const u8) void {
        \\    if (!ready.isReady()) rt.panicNotReady(library_name, symbol);
        \\}
        \\
        \\/// The provider did not export an optional symbol. The load succeeded,
        \\/// because this build does not require it; the call cannot be served,
        \\/// because there is nothing to call. An ordinary panic naming the symbol
        \\/// the provider lacks, next to the spelling the caller used.
        \\inline fn requireAvailable(symbol: []const u8, comptime provided: []const u8) noreturn {
        \\    std.debug.panic(
        \\        "{s}: the loaded provider does not export {s}, which {s} needs; this " ++
        \\            "provider is not the library this build describes",
        \\        .{ library_name, provided, symbol },
        \\    );
        \\}
        \\
    );
    if (needs_root) try w.writeAll("const __root = @This();\n\n");
}

fn writeTableOpen(w: *Writer) !void {
    try w.writeAll(
        \\/// The resolved table: one field per routed symbol, each typed from the
        \\/// translated header's own declaration of that symbol. A field for a
        \\/// symbol the provider may not export is nullable and starts null.
        \\pub const Table = struct {
        \\
    );
}

fn writeFunction(w: *Writer, decl: Decl) !void {
    const optional = decl.class == .optional_function;
    try w.print("pub fn {s}({s}){s} {{\n", .{ decl.name, decl.params, decl.tail });
    try w.print("    requireReady(\"{s}\");\n", .{decl.name});
    if (optional) {
        try w.print(
            "    const target = table.{s} orelse requireAvailable(\"{s}\", \"{s}\");\n",
            .{ decl.name, decl.name, decl.name },
        );
    } else {
        try w.print("    const target = table.{s};\n", .{decl.name});
    }
    if (decl.variadic) {
        try w.writeAll("    return @call(.auto, target, .{");
        try writeArgumentList(w, decl.arguments);
        try w.writeAll("} ++ rt_args);\n");
    } else {
        try w.writeAll("    return target(");
        try writeArgumentList(w, decl.arguments);
        try w.writeAll(");\n");
    }
    try w.writeAll("}\n\n");
}

/// Emit a forwarding wrapper for a routed function alias.
/// This supports variadic functions, which have no function value.
fn writeAliasFunction(w: *Writer, decl: Decl) !void {
    try w.print("pub fn {s}({s}){s} {{\n", .{ decl.name, decl.params, decl.tail });
    try w.print("    requireReady(\"{s}\");\n", .{decl.name});
    try w.print("    return {s}(", .{decl.target});
    try writeArgumentList(w, decl.arguments);
    if (decl.variadic) {
        if (decl.arguments.len != 0) try w.writeAll(", ");
        try w.writeAll("rt_args");
    }
    try w.writeAll(");\n");
    try w.writeAll("}\n\n");
}

fn writeDataAccessor(w: *Writer, decl: Decl) !void {
    const optional = decl.class == .optional_data;
    try w.print("pub fn {s}Addr() {s} {{\n", .{ decl.name, decl.field_type });
    try w.print("    requireReady(\"{s}\");\n", .{decl.name});
    if (optional) {
        try w.print(
            "    return table.{s} orelse requireAvailable(\"{s}\", \"{s}\");\n",
            .{ decl.name, decl.name, decl.name },
        );
    } else {
        try w.print("    return table.{s};\n", .{decl.name});
    }
    try w.writeAll("}\n\n");
}

/// Emit a guarded address accessor for an exported-object alias.
fn writeAliasDataAccessor(w: *Writer, decl: Decl) !void {
    try w.print("pub fn {s}Addr() {s} {{\n", .{ decl.name, decl.field_type });
    try w.print("    requireReady(\"{s}\");\n", .{decl.name});
    if (decl.target_class == .optional_data) {
        try w.print(
            "    return table.{s} orelse requireAvailable(\"{s}\", \"{s}\");\n",
            .{ decl.target, decl.name, decl.target },
        );
    } else {
        try w.print("    return table.{s};\n", .{decl.target});
    }
    try w.writeAll("}\n\n");
}

fn writeArgumentList(w: *Writer, arguments: []const []const u8) !void {
    for (arguments, 0..) |argument, index| {
        if (index != 0) try w.writeAll(", ");
        try w.writeAll(argument);
    }
}

fn writeTableClose(w: *Writer, plan: *const Plan) !void {
    const has_optional = for (plan.decls) |decl| {
        if (decl.class == .optional_function or decl.class == .optional_data) break true;
    } else false;
    for (plan.decls) |decl| switch (decl.class) {
        .routed_function, .routed_data => try w.print("    {s}: {s},\n", .{ decl.name, decl.field_type }),
        .optional_function, .optional_data => try w.print("    {s}: ?{s},\n", .{ decl.name, decl.field_type }),
        else => {},
    };
    try w.writeAll("};\n\n");
    try w.writeAll(
        \\
        \\/// Where the table lives, for the loader and for validation.
        \\pub fn tablePtr() *Table {
        \\    return &table;
        \\}
        \\
        \\/// The table itself. Nothing reads it except a routed call that has
        \\/// already checked readiness. A field for an optional symbol starts
        \\/// null, so a provider that does not export it can never be mistaken
        \\/// for one that did.
        \\pub var table: Table = .{
        \\
    );
    for (plan.decls) |decl| switch (decl.class) {
        .routed_function, .routed_data => try w.print("    .{s} = undefined,\n", .{decl.name}),
        .optional_function, .optional_data => try w.print("    .{s} = null,\n", .{decl.name}),
        else => {},
    };
    try w.writeAll(
        \\};
        \\
        \\/// Every symbol this dispatch requires at load time, in the order
        \\/// `assign` expects. A provider that does not export all of them is
        \\/// refused before anything is published.
        \\pub const symbols: []const rt.Symbol = &.{
        \\
    );
    for (plan.decls) |decl| switch (decl.class) {
        .routed_function => try w.print(
            "    .{{ .name = \"{s}\", .kind = rt.SymbolKind.function }},\n",
            .{decl.name},
        ),
        .routed_data => try w.print(
            "    .{{ .name = \"{s}\", .kind = rt.SymbolKind.data }},\n",
            .{decl.name},
        ),
        else => {},
    };
    try w.writeAll(
        \\};
        \\
        \\/// Symbols the provider may not export, in the order `assignOptional`
        \\/// and `assignMissing` expect. They are not in `symbols`, so their
        \\/// absence does not fail a load.
        \\pub const optional_symbols: []const rt.Symbol = &.{
        \\
    );
    for (plan.decls) |decl| switch (decl.class) {
        .optional_function => try w.print(
            "    .{{ .name = \"{s}\", .kind = rt.SymbolKind.function }},\n",
            .{decl.name},
        ),
        .optional_data => try w.print(
            "    .{{ .name = \"{s}\", .kind = rt.SymbolKind.data }},\n",
            .{decl.name},
        ),
        else => {},
    };
    try w.writeAll(
        \\};
        \\
        \\/// Whether the provider exported the optional symbol at `index`.
        \\pub inline fn optional(comptime __rt_symbol_index: usize) bool {
        \\    return switch (__rt_symbol_index) {
        \\
    );
    try writeIndexArms(w, plan, .optional_function, .optional_data, .present);
    try w.writeAll(
        \\        else => unreachable,
        \\    };
        \\}
        \\
        \\/// Write one resolved address into one table field.
        \\
        \\/// The cast is the one the platform loader makes anyway: it hands back
        \\/// an address, and the field wants the exact type the header declares.
        \\/// `@constCast` is there because a mutable exported object is reached
        \\/// through a mutable pointer, and `@ptrCast` may not remove a
        \\/// qualifier. `std` does the same in its own dynamic library lookup.
        \\pub inline fn assign(comptime __rt_symbol_index: usize, dst: *Table, address: *const anyopaque) void {
        \\    switch (__rt_symbol_index) {
        \\
    );
    try writeIndexArms(w, plan, .routed_function, .routed_data, .assign);
    try w.writeAll(
        \\        else => unreachable,
        \\    }
        \\}
        \\
        \\/// Write one resolved address into one optional table field.
        \\pub inline fn assignOptional(comptime __rt_symbol_index: usize, dst: *Table, address: *const anyopaque) void {
        \\
    );
    if (!has_optional) try w.writeAll("    _ = dst;\n    _ = address;\n");
    try w.writeAll("    switch (__rt_symbol_index) {\n");
    try writeIndexArms(w, plan, .optional_function, .optional_data, .assign);
    try w.writeAll(
        \\        else => unreachable,
        \\    }
        \\}
        \\
        \\/// Record that the provider does not export the optional symbol at
        \\/// `index`. The loader runs this for every optional symbol before each
        \\/// attempt, so a retry against a provider that lacks one cannot leave
        \\/// the previous provider's address behind.
        \\pub inline fn assignMissing(comptime __rt_symbol_index: usize, dst: *Table) void {
        \\
    );
    if (!has_optional) try w.writeAll("    _ = dst;\n");
    try w.writeAll("    switch (__rt_symbol_index) {\n");
    try writeIndexArms(w, plan, .optional_function, .optional_data, .missing);
    try w.writeAll(
        \\        else => unreachable,
        \\    }
        \\}
        \\
        \\
    );
}

const ArmKind = enum { present, assign, missing };

fn writeIndexArms(
    w: *Writer,
    plan: *const Plan,
    function_class: Class,
    data_class: Class,
    kind: ArmKind,
) !void {
    var index: usize = 0;
    for (plan.decls) |decl| {
        if (decl.class != function_class and decl.class != data_class) continue;
        switch (kind) {
            .present => try w.print("        {d} => table.{s} != null,\n", .{ index, decl.name }),
            .assign => try w.print("        {d} => dst.{s} = @ptrCast(@alignCast(@constCast(address))),\n", .{
                index, decl.name,
            }),
            .missing => try w.print("        {d} => dst.{s} = null,\n", .{ index, decl.name }),
        }
        index += 1;
    }
}

// Patch only Aro's `__root` prologue so nested aliases resolve through dispatch.

fn writePatchedNative(arena: std.mem.Allocator, tree: *const Ast, root: ?Decl) Failure![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    const decl = root orelse {
        try w.writeAll(tree.source);
        return out.toOwnedSlice();
    };
    if (!isThisPrologue(arena, tree, decl)) {
        std.debug.print(
            "runtime/generate.zig: '__root' is not declared as `@This()`. This generator " ++
                "repoints that one prologue line and will not guess at another " ++
                "spelling.\n",
            .{},
        );
        return error.UnsupportedDeclaration;
    }
    try w.writeAll(tree.source[0..tree.tokenStart(decl.first)]);
    try w.print("const __root = @import(\"{s}\");", .{routed_import});
    const suffix_start = tree.tokenStart(decl.last) + tree.tokenSlice(decl.last).len;
    try w.writeAll(tree.source[suffix_start..]);
    return out.toOwnedSlice();
}

/// Whether a declaration is Aro's expected `__root = @This()` prologue.
fn isThisPrologue(arena: std.mem.Allocator, tree: *const Ast, decl: Decl) bool {
    const tokens = significantTokens(arena, tree, decl.first, decl.last) catch return false;
    if (tokens.len() < 4) return false;
    const last = tokens.len() - 1;
    if (tokens.tag(last) != .semicolon) return false;
    if (tokens.tag(last - 1) != .r_paren) return false;
    if (tokens.tag(last - 2) != .l_paren) return false;
    return std.mem.eql(u8, tokens.slice(last - 3), "@This");
}

// Rewrite routed objects and variadic calls in copied declarations.
// Token scopes preserve locals, fields, strings, comments, and shadowed names.

fn writeCopied(
    w: *Writer,
    arena: std.mem.Allocator,
    tree: *const Ast,
    decl: Decl,
    plan: *const Plan,
) Failure!void {
    if (!decl.needs_rewrite) {
        try w.writeAll(tokenRangeText(tree, decl.first, decl.last));
        try w.writeAll("\n");
        return;
    }

    const tokens = try significantTokens(arena, tree, decl.first, decl.last);
    const locals = try localNames(arena, tokens);
    // Insert missing tuples at call closes; pending closes are nested in LIFO order.
    // The stack has no configured depth cap.
    var owed_close: ?usize = null;
    var owed_nested: std.ArrayList(usize) = .empty;
    var source_cursor: usize = tree.tokenStart(decl.first);

    for (0..tokens.len()) |at| {
        const token = tokens.items[at];
        const token_start: usize = tree.tokenStart(token);
        try w.writeAll(tree.source[source_cursor..token_start]);
        source_cursor = token_start + tree.tokenSlice(token).len;

        if (owed_close) |close| {
            if (close == at) {
                // Resume at the enclosing call's close.
                owed_close = null;
                if (owed_nested.items.len != 0) {
                    // Restore the outer close before truncating the stack.
                    const outer = owed_nested.items.len - 1;
                    owed_close = owed_nested.items[outer];
                    owed_nested.items.len = outer;
                }
                try w.writeAll(", .{}");
            }
        }
        if (tokens.tag(at) != .identifier) {
            try w.writeAll(tokenText(tree, tokens.items[at]));
            continue;
        }
        const text = tokens.slice(at);
        const shadowed = locals.contains(text);
        const member = at > 0 and tokens.tag(at - 1) == .period;
        if (!shadowed and !member) {
            switch (variadicCall(plan, tokens, at)) {
                .needs_tuple => |close| {
                    if (owed_close) |pending| try owed_nested.append(arena, pending);
                    owed_close = close;
                },
                .unsupported => return error.UnsupportedDeclaration,
                .not_a_call, .has_tuple => {},
            }
            if (plan.data_names.get(text)) |address_value| {
                try w.print("{s}Addr(){s}", .{ text, if (address_value) "" else ".*" });
                continue;
            }
        }
        try w.writeAll(tokenText(tree, tokens.items[at]));
    }

    const source_end = tree.tokenStart(decl.last) + tree.tokenSlice(decl.last).len;
    try w.writeAll(tree.source[source_cursor..source_end]);
    try w.writeAll("\n");
}

/// Classify a call to a routed variadic function.
/// Only fixed arguments with an optional final tuple are supported.
const VariadicCall = union(enum) {
    /// Not a routed variadic call.
    not_a_call,
    /// Needs a tuple before this closing parenthesis.
    needs_tuple: usize,
    /// Tuple already supplied as the last argument.
    has_tuple,
    /// Unsupported argument shape.
    unsupported,
};

fn variadicCall(plan: *const Plan, tokens: Tokens, at: usize) VariadicCall {
    if (at + 1 >= tokens.len() or tokens.tag(at + 1) != .l_paren) return .not_a_call;
    const fixed = plan.variadic_names.get(tokens.slice(at)) orelse return .not_a_call;
    const close = tokens.matchingRParen(at + 1) orelse return .unsupported;
    const given = tokens.argumentCount(at + 1, close);
    if (given == fixed) return .{ .needs_tuple = close };
    if (given == fixed + 1) return .has_tuple;
    std.debug.print(
        "runtime/generate.zig: the call to '{s}' has {d} arguments for {d} fixed " ++
            "parameters and one variadic tuple; neither shape can be routed.\n",
        .{ tokens.slice(at), given, fixed },
    );
    return .unsupported;
}

fn tokenText(tree: *const Ast, token: Ast.TokenIndex) []const u8 {
    const start = tree.tokenStart(token);
    return tree.source[start..][0..tree.tokenSlice(token).len];
}

// Token scanning avoids interpreting delimiters inside strings and comments.

/// Tokens in a declaration, excluding doc comments.
const Tokens = struct {
    tree: *const Ast,
    items: []const Ast.TokenIndex,

    fn len(self: Tokens) usize {
        return self.items.len;
    }
    fn tag(self: Tokens, at: usize) Tag {
        return self.tree.tokenTag(self.items[at]);
    }
    fn slice(self: Tokens, at: usize) []const u8 {
        return self.tree.tokenSlice(self.items[at]);
    }
    fn matchingRParen(self: Tokens, open: usize) ?usize {
        var depth: u32 = 0;
        for (open..self.items.len) |at| switch (self.tag(at)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return at;
            },
            else => {},
        };
        return null;
    }
    /// Count commas at this list's depth; empty lists have zero arguments.
    fn argumentCount(self: Tokens, open: usize, close: usize) usize {
        if (open + 1 >= close) return 0;
        var depth: u32 = 0;
        var count: usize = 1;
        for (open..close + 1) |at| switch (self.tag(at)) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -= 1,
            .comma => {
                if (depth == 1) count += 1;
            },
            else => {},
        };
        return count;
    }
};

fn significantTokens(
    arena: std.mem.Allocator,
    tree: *const Ast,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
) std.mem.Allocator.Error!Tokens {
    var items: std.ArrayList(Ast.TokenIndex) = .empty;
    var index = first;
    while (index <= last) : (index += 1) switch (tree.tokenTag(index)) {
        .doc_comment, .container_doc_comment => {},
        else => try items.append(arena, index),
    };
    return .{ .tree = tree, .items = items.items };
}

fn tokenRangeText(tree: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) []const u8 {
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// Return the semicolon or top-level closing brace of a declaration.
fn declarationEndToken(tree: *const Ast, decl: Ast.Node.Index) Ast.TokenIndex {
    const last = tree.lastToken(decl);
    return if (last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .semicolon)
        last + 1
    else
        last;
}

fn matchingRParenToken(tree: *const Ast, lparen: Ast.TokenIndex) Ast.TokenIndex {
    var depth: u32 = 0;
    var index = lparen;
    while (index < tree.tokens.len) : (index += 1) {
        switch (tree.tokenTag(index)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    @panic("parsed function prototype has no closing parenthesis");
}

/// Return the first identifier in the declaration's token range.
fn declarationName(
    tree: *const Ast,
    from: Ast.TokenIndex,
    end_token: Ast.TokenIndex,
) ?[]const u8 {
    var index = from;
    while (index <= end_token) : (index += 1) {
        if (tree.tokenTag(index) == .identifier) return tree.tokenSlice(index);
    }
    return null;
}
