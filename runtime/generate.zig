// SPDX-License-Identifier: MIT
//
//! Build-time generator for the runtime dispatch module.
//!
//! This program runs on the build machine, reads what `b.addTranslateC` actually
//! produced for the selected target and configuration, and writes two files:
//! the dispatch module an SDK imports in place of the translated header, and a
//! patched copy of that translation whose one prologue line now names the
//! dispatch. Nothing about the native API is written by hand. Every type,
//! constant, parameter and return type in the output is text taken from the
//! translation step's own output, so the dispatch cannot claim a symbol the
//! header does not declare.
//!
//! ## What it produces
//!
//!   * one table field per routed symbol, typed from the translated header's own
//!     declaration for that symbol, so the pointer stored at load time has
//!     exactly the C function pointer type a C compiler would have used,
//!     variadic signatures included;
//!   * one wrapper per routed function, one accessor per routed object, one
//!     forwarding wrapper per macro alias and one accessor per object alias;
//!   * the translated namespace re-exported: `pub const NAME = c_native.NAME;`
//!     for a public type, constant or value. Those are re-exports of the *same*
//!     declarations, not copies, so a type named by this module is the same
//!     nominal type the translated header declares;
//!   * the declarations that cannot be routed, copied with the references this
//!     module cannot satisfy rewritten to ones it can;
//!   * a second file: the same translated declarations with one change, the
//!     `const __root = @This();` prologue Aro writes, replaced by an import of
//!     the dispatch. That is what makes a declaration nested inside a
//!     translated type - PCRE2's per-width aliases, spglib's
//!     `SpglibDataset.spg_free_dataset`, gmp's `__gmp_randstate_struct` members
//!     - name the routed wrapper rather than the raw extern, while the type
//!     itself stays the one nominal type the header declares.
//!
//! ## What it refuses to do
//!
//! It does not guess. A translated header that does not parse, a routed function
//! whose parameter list it cannot reproduce faithfully, an `anytype` parameter on
//! a routed function, an exported object whose declaration has an initializer, an
//! alias chain that loops, a call to a routed variadic function whose argument
//! list it cannot read, a `__root` reference the dispatch could not answer: each
//! of those stops the build with a message naming the declaration, rather than
//! producing a dispatch that looks plausible.
//!
//! ## Classification
//!
//!   routed     an `extern` the provider is expected to export. Required at load
//!              time; its absence fails the load.
//!   optional   an `extern` the provider may not have. Routed into a nullable
//!              table field and resolved when the provider does export it. A call
//!              stops the program by name if it did not, rather than becoming a
//!              link-time reference to a symbol nothing links.
//!   direct     an `extern` that is really the C library's (memcpy and
//!              friends). Copied verbatim: these must stay direct, because a
//!              table lookup for a function the C library already linked would
//!              add a load and an acquire check to every string operation.
//!
//! `optional` wins over `direct`, so a build can always talk its way back to a
//! load-time requirement, and `direct` wins over routing, so a build can always
//! talk its way back to a declaration the C library already provides.
//!
//! ## What the build has to wire
//!
//!   * `--output` receives the dispatch. The dispatch module imports `rt`,
//!     `library` and `c_native` as before, plus nothing else.
//!   * `--native-output` receives the patched translation, and *that* file, not
//!     `translate.getOutput()`, is what the dispatch's `c_native` import names.
//!   * the dispatch module is then added to the patched translation as its
//!     `c_routed` import. The two modules import each other; nothing else does.
//!   * a symbol listed as `optional` needs the loader to try it: the generated
//!     `optional_symbols`, `optional(index)`, `assignOptional` and
//!     `assignMissing` are the interface for that, and until the loader calls
//!     them the field stays null and the wrapper stops the program by name.

const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const Writer = std.Io.Writer;
const Tag = std.zig.Token.Tag;

/// Upper bound on the translation step's output. A real translated header is
/// kilobytes; this exists so a wrong path cannot exhaust memory.
const max_translated_bytes = 64 * 1024 * 1024;

/// Every way this program can stop. None of them are silently recoverable: each
/// one means the dispatch would have been wrong or incomplete.
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

/// Everything this program is told, all of it from the build file.
const Options = struct {
    /// The SDK's name, used in the pre-load panic and in the file header.
    library: []const u8 = "",
    /// Path to the file the translation step produced.
    translate: []const u8 = "",
    /// Path this program writes the dispatch to.
    output: []const u8 = "",
    /// Path this program writes the patched translation to. Empty means this
    /// build does not want one, which this generator then requires no public
    /// declaration to depend on.
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

    /// What a declaration is, once the three lists have been consulted.
    ///
    /// The order of the tests is the whole policy: a build that names a symbol
    /// as excluded means it, whatever else it says about the same symbol, so a
    /// deliberate choice is never quietly undone by a broader rule.
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
        // A build file wraps long lists, and a wrapped name that kept its
        // newline would silently match nothing. Trimming here is what makes a
        // wrapped list mean what it looks like.
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) continue;
        try set.put(arena, name, {});
    }
}

/// The name the patched translation imports the dispatch under. The build adds
/// that import to the generated file.
const routed_import = "c_routed";

// ---------------------------------------------------------------------------
// Declarations
//
// Deciding and writing are separate passes because the table's fields are only
// known once every declaration has been seen. A file written in one go cannot
// be left half finished, and nothing is written until the whole plan exists.
// ---------------------------------------------------------------------------

const Class = enum {
    /// `extern fn`, routed: a required table field and a wrapper.
    routed_function,
    /// `extern var`/`extern const`, routed: a required table field and an
    /// accessor.
    routed_data,
    /// As above, but the provider may not export it: a nullable table field, and
    /// a wrapper that stops the program by name when it is absent.
    optional_function,
    optional_data,
    /// Copied, with this module's own references rewritten where needed.
    copied,
    /// The translation's `const __root = @This();` prologue. Written in neither
    /// output: the patched translation has this one line repointed at the
    /// dispatch, and the dispatch declares a `__root` of its own, so copying it
    /// here would declare the name twice in one file.
    root_prologue,
    /// Re-exported from the patched translation rather than copied.
    reexport,
    /// An alias the dispatch generates a forwarding wrapper for.
    alias_function,
    /// An alias the dispatch generates a guarded accessor for.
    alias_data,
};

const Decl = struct {
    name: []const u8,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    class: Class,

    is_pub: bool = false,
    /// Set when this declaration's own text names `__root`.
    uses_root: bool = false,
    /// Set when this declaration's own text names something this module does
    /// not declare under that name.
    needs_rewrite: bool = false,

    /// The name this declaration aliases, when its initializer is one.
    alias_of: []const u8 = "",
    /// The routed symbol an alias finally reaches, when it reaches one.
    target: []const u8 = "",
    target_class: Class = .copied,

    variadic: bool = false,
    fixed_params: usize = 0,
    params: []const u8 = "",
    tail: []const u8 = "",
    /// The table field's type: a function pointer for a function, and for an
    /// object the address the provider owns. A mutable exported object is
    /// reached through a mutable pointer, because the provider writes through
    /// that address; a `const` object is reached through a const pointer, which
    /// is what the header declares.
    field_type: []const u8 = "",
    /// An @extern pointer already denotes the object's address, not its value.
    address_value: bool = false,
    arguments: []const []const u8 = &.{},
};

const Plan = struct {
    decls: []const Decl,
    /// Every routed object name: a copied declaration reads it through its
    /// accessor, because this module declares no such value itself.
    data_names: std.StringHashMapUnmanaged(bool),
    /// Every routed variadic function name, with the number of arguments that
    /// precede the variable part.
    variadic_names: std.StringHashMapUnmanaged(usize),
    /// Every `__root.NAME` the translation uses.
    root_refs: std.StringHashMapUnmanaged(void),
    /// True when a declaration copied into the dispatch refers to `__root`, so
    /// the dispatch has to declare one of its own.
    dispatch_needs_root: bool,
    root_decl: ?Decl = null,
};

fn generate(
    io: Io,
    arena: std.mem.Allocator,
    options: Options,
) Failure!struct { dispatch: []const u8, native: []const u8 } {
    const source_z = try readSentinel(io, arena, options.translate);
    var tree = try Ast.parse(arena, source_z, .zig);
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
        // Already written by the preamble, and only when a copied declaration
        // refers to one; the translation's own prologue is repointed by the
        // patch, so writing it here too would declare the name twice.
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

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

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
            // A test declaration, a `usingnamespace`, a comptime block: none of
            // these is part of the library's interface.
            else => continue,
        };
        if (decl.name.len != 0 and !index.contains(decl.name)) {
            try index.put(arena, decl.name, decls.items.len);
        }
        try decls.append(arena, decl);
    }

    // An alias is a forwarding wrapper or an accessor only once the chain it
    // follows has been read to its end. Chains loop when a header defines `a` as
    // `b` and `b` as `a`, and that is a declaration to refuse rather than guess.
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

        // An initializer naming something the translation never declared at the
        // top level is left as written: the text is the only description of it.
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
            // A private declaration is copied into the dispatch, and so is an
            // alias onto it: the text then finds its target here.
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
            // Aro opens its output with this one declaration and the dispatch
            // declares a `__root` of its own, so it is classified rather than
            // copied. Only that prologue is repointed: any other spelling of
            // the name stays a copied declaration, and `writePatchedNative`
            // refuses a file whose prologue is not the one it expects.
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

    // An inline body, or an export, is defined here rather than imported.
    // Copying it keeps the body, its inlining behaviour and everything it
    // references exactly as the translation step wrote them.
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

/// The parameter list, the return clause and the field type, taken from the
/// translated prototype itself.
///
/// The field type keeps the parameter names and the `...` of a variadic
/// prototype verbatim, because that text is the exact C signature. The wrapper
/// renames each parameter, so a shadowing parameter in the translated header
/// cannot change what the wrapper passes through.
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
        const argument = try std.fmt.allocPrint(arena, "rt_p{d}", .{arguments.items.len});
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
    // A variadic wrapper takes its variable arguments as one tuple, which is how
    // Zig itself calls a C variadic function, so it needs no calling convention
    // of its own.
    const tail = if (variadic)
        try std.fmt.allocPrint(arena, " {s}", .{return_text})
    else
        try std.fmt.allocPrint(arena, " callconv({s}) {s}", .{ calling_convention, return_text });
    const rparen = matchingRParenToken(tree, proto.lparen);
    const native_params = tokenRangeText(tree, proto.lparen, rparen);
    decl.variadic = variadic;
    decl.fixed_params = arguments.items.len;
    decl.params = params.items;
    decl.tail = tail;
    decl.arguments = arguments.items;
    decl.field_type = try std.fmt.allocPrint(arena, "*const fn {s} callconv({s}) {s}", .{
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
    // A quoted name is a string literal token, and its spelling is not an
    // identifier this module could name in a table field. Such a declaration is
    // left exactly as the translation wrote it.
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

    // The prologue `__root` is emitted by the patched translation instead.
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
                // Evaluating @TypeOf on an @extern constant can emit its
                // address into debug information and create a direct link.
                // Copy only the declared pointer type; its named types are
                // still re-exported from the one nominal translated module.
                decl.field_type = tree.source[
                    tree.tokenStart(type_first)..tree.tokenStart(type_last) + tree.tokenSlice(type_last).len
                ];
                decl.address_value = true;
                return decl;
            }
        }
        if (initializerAlias(tree, decl.first, last)) |alias_of| decl.alias_of = alias_of;
        // A private declaration cannot be imported from another module at all,
        // so it is copied. A public one is re-exported, which is what keeps
        // `c.mpz_t` and `c_native.mpz_t` one nominal type.
        if (!decl.is_pub or decl.alias_of.len != 0) return decl;
        decl.class = .reexport;
        return decl;
    }

    // Exported data. The table holds the object's address and the accessor hands
    // that address out. A re-export would name an address this module cannot
    // have at compile time, and a copy would break any write the C side makes
    // through the symbol.
    switch (options.routeOf(name)) {
        .direct => return decl,
        .routed => decl.class = .routed_data,
        .optional => decl.class = .optional_data,
    }
    const type_text = try dataTypeText(arena, tree, var_decl, name, last);
    const is_mutable = std.mem.eql(u8, tree.tokenSlice(mut_token), "var");
    decl.field_type = if (is_mutable)
        try std.fmt.allocPrint(arena, "*{s}", .{type_text})
    else
        try std.fmt.allocPrint(arena, "*const {s}", .{type_text});
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
    const text = tree.source[
        tree.tokenStart(tree.firstToken(type_node))..tree.tokenStart(last)
    ];
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

/// The single name an initializer refers to, when it refers to one.
///
/// The translation spells an alias two ways: `pub const mpz_init = __gmpz_init;`
/// for a macro the preprocessor renamed, and
/// `pub const spg_free_dataset = __root.spg_free_dataset;` for one Aro placed
/// inside a type. Both are one identifier after at most a `__root.` prefix, and
/// neither is a computation, so the tokens between `=` and `;` say which it is.
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

/// The names a declaration introduces for itself inside its own text.
///
/// A parameter, a local, a capture and a struct field are all an identifier
/// either preceded by a keyword that introduces it or followed by a colon. Those
/// are collected so a rewritten reference never lands on one.
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

/// Whether a copied declaration names something this module cannot declare, and
/// so has to be rewritten.
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
        // A member access names a field of something else.
        if (at > 0 and tokens.tag(at - 1) == .period) continue;
        if (data_names.contains(text)) return true;
        if (variadic_names.contains(text) and at + 1 < tokens.len() and tokens.tag(at + 1) == .l_paren) return true;
    }
    return false;
}

/// The names the translation reaches through `__root`, and whether there are any.
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

/// A `__root.NAME` has to name a declaration the dispatch publishes, because the
/// patched translation resolves it there. A private declaration is not
/// published, and a routed object has no value to name at all.
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

// ---------------------------------------------------------------------------
// Writing the dispatch
// ---------------------------------------------------------------------------

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

/// A macro the header renamed, routed to the wrapper its name reaches.
///
/// A forwarding wrapper rather than `pub const NAME = TARGET;` because a routed
/// variadic function is a generic function, and a generic function has no value
/// another declaration could name. It also keeps every hop of a chain -
/// `mpz_kronecker` to `mpz_jacobi` to `__gmpz_jacobi` - inside this module.
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

/// A macro the header renamed onto an exported object.
///
/// `pub const gmp_version = __gmp_version;` names a value, and the only value
/// this module could name would be an address it cannot have at compile time.
/// The alias gets its own guarded accessor instead, returning the same live
/// address its target's accessor returns: never a snapshot of it.
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

// ---------------------------------------------------------------------------
// Writing the patched translation
//
// Aro opens its output with `const __root = @This();` and uses that name for
// every macro the preprocessor placed inside a type. Repointing that one line at
// this module is what makes those nested declarations name the routed wrappers
// while the types themselves stay the header's own nominal types. No other token
// of the translation changes.
// ---------------------------------------------------------------------------

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

/// Whether the declaration is the `const __root = @This();` Aro opens its
/// output with, which is the one line this generator repoints.
fn isThisPrologue(arena: std.mem.Allocator, tree: *const Ast, decl: Decl) bool {
    const tokens = significantTokens(arena, tree, decl.first, decl.last) catch return false;
    if (tokens.len() < 4) return false;
    const last = tokens.len() - 1;
    if (tokens.tag(last) != .semicolon) return false;
    if (tokens.tag(last - 1) != .r_paren) return false;
    if (tokens.tag(last - 2) != .l_paren) return false;
    return std.mem.eql(u8, tokens.slice(last - 3), "@This");
}

// ---------------------------------------------------------------------------
// Copied declarations
//
// A copied declaration keeps its own text, with two exceptions. A name this
// module does not declare - a routed object, which is reached through its
// accessor - becomes that accessor. A call to a routed variadic function, whose
// wrapper takes its variable arguments as a tuple, is given that tuple. Both
// are decided from the tokens and the scopes inside the declaration, so a local
// variable, a struct field, a shadowed parameter, a quoted identifier and
// anything inside a string or a comment are left exactly as written.
// ---------------------------------------------------------------------------

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
    // Where an empty tuple belongs: the closing paren of a call still owed one.
    // One call at a time, or several that never overlap, is the ordinary case
    // and is held in one index. A second call can arrive while the first has not
    // closed, and then the older close moves to the stack below. Any two closes
    // pending together are strictly nested - balanced parentheses are either
    // nested or disjoint, and a disjoint later call is only reached once the
    // earlier one has closed - so the innermost close is always on top and no
    // nesting depth is assumed or capped.
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
                // That close is paid off; the next one out is the one still
                // owed, and there is none once the stack has nothing left.
                owed_close = null;
                if (owed_nested.items.len != 0) {
                    // Read the innermost close while the stack still holds it:
                    // truncating first would leave the index equal to the new
                    // length, one past the end of what is there.
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

/// What the identifier at `at` is, when it is a call to a routed variadic
/// function.
///
/// The fixed parameters have to be there and the tuple either absent or present
/// as the last argument, because those are the two shapes Zig itself accepts for
/// a C variadic call. Anything else is a call this generator cannot reproduce.
const VariadicCall = union(enum) {
    /// Not a call to a routed variadic function: the text stands as written.
    not_a_call,
    /// The call is missing its tuple, which belongs immediately before the
    /// closing paren this index names.
    needs_tuple: usize,
    /// The tuple is already there, as the last argument.
    has_tuple,
    /// Neither shape: a declaration to refuse rather than rewrite.
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

// ---------------------------------------------------------------------------
// Token helpers
//
// Everything here works on tokens rather than on rendered text, because the
// translated source is already tokenized: a brace or a semicolon inside a string
// is part of one token, and a comment is one token too. Delimiter matching is
// then exact, where a text scan would have to guess what is quoted.
// ---------------------------------------------------------------------------

/// The tokens of a range, with doc comments left out, so an index here counts
/// only tokens that carry meaning.
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
    /// How many arguments the parenthesised list holds: commas at its own depth,
    /// and zero when it is empty.
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

/// The last token of a declaration: the `;` of a declaration without a body, or
/// the `}` that closes one at the top level.
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

/// The identifier a declaration introduces.
///
/// A constant, a type or an exported object declaration is one name deep, so
/// this walks forward from the `const`/`var` token to the first identifier. A doc
/// comment is a single token and not an identifier, so it cannot be mistaken for
/// the name.
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