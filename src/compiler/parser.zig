//! Native FBS frontend for Flatzz reflection metadata (Zig 0.17.0).
//!
//! Use a caller-owned arena: ALL returned data AND parsing temporaries use the
//! supplied allocator. Destroy the arena after code generation, including on
//! failure. The parser copies input text, so the original source may be released.
//! Parser/compiler state stores no allocator: allocating operations receive it
//! explicitly. Use the same allocator throughout a parse, including callbacks.
//!
//! Supports namespaces, includes through a callback, tables, naturally aligned
//! structs, scalar aliases, enums, unions/aliases, vectors, fixed arrays, scalar
//! defaults/null, explicit IDs, required/deprecated/key, custom attributes,
//! root_type and file_identifier/file_extension. No C, libc or BFBS is involved.
//! Unsupported built-in attributes and RPC declarations return UnsupportedFeature.
//! Comments are accepted but documentation comments are not retained.
//! Inline enum members may omit a zero variant, as the existing Flatzz fixtures
//! do. This is more permissive than flatc's enum-default validation for structs.
//!
//! Reflection arrays are sorted as flatc sorts them; IDs/layout retain declaration
//! semantics. See https://flatbuffers.dev/schema/ and reflection/reflection.fbs.
//!
//! From Flatzz, run `zig build test`.
//! Import `const compiler = @import("flatzz_compiler");`, then `const parser = compiler.parser;`.
//! Example inside a function with `std` and `parser` imported:
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//! defer arena.deinit();
//! const schema = try parser.parse(arena.allocator(),
//!     "table Reading { value:uint = 42; } root_type Reading;");
//! std.debug.print("{s}\n", .{schema.root_table.?.name});
//! ```
//! Expected output: `Reading` followed by a newline. The arena owns the schema.

const std = @import("std");
const reflection = @import("reflection.zig");
const flatzz = @import("flatzz");

const wire = flatzz.wire;
const Allocator = std.mem.Allocator;
const BaseType = reflection.BaseType;

const scalar_types = std.StaticStringMap(BaseType).initComptime(.{
    .{ "bool", .Bool },     .{ "byte", .Byte },     .{ "int8", .Byte },
    .{ "ubyte", .UByte },   .{ "uint8", .UByte },   .{ "short", .Short },
    .{ "int16", .Short },   .{ "ushort", .UShort }, .{ "uint16", .UShort },
    .{ "int", .Int },       .{ "int32", .Int },     .{ "uint", .UInt },
    .{ "uint32", .UInt },   .{ "long", .Long },     .{ "int64", .Long },
    .{ "ulong", .ULong },   .{ "uint64", .ULong },  .{ "float", .Float },
    .{ "float32", .Float }, .{ "double", .Double }, .{ "float64", .Double },
    .{ "string", .String },
});

// FBS attribute spellings are external names; numeric tags have no wire meaning.
const BuiltinAttribute = enum {
    id,
    required,
    deprecated,
    key,
    force_align,
    bit_flags,
    nested_flatbuffer,
    flexbuffer,
    hash,
    offset64,
    vector64,
    original_order,
    shared,
    native_inline,
    native_custom_alloc,
    native_type,
    native_type_pack_name,
    native_default,
    native_include,
    native_cpp_type,
    cpp_type,
    cpp_ptr_type,
    cpp_str_type,
    cpp_str_flex_ctor,
    cpp_include,
    streaming,
    idempotent,
    private,
    force_empty,
    force_empty_vector,
    cpp_static_reflection,
};

/// Allocation, validation, supported-feature, include, and nesting failures.
pub const Error = error{
    /// The supplied allocator failed, including while formatting a diagnostic.
    OutOfMemory,
    /// Invalid syntax, unresolved names, or inconsistent schema metadata.
    InvalidSchema,
    /// A recognized declaration or attribute is outside this frontend's subset.
    UnsupportedFeature,
    /// No include loader was supplied, or the loader failed for a non-allocation reason.
    IncludeNotFound,
    /// Include or unresolved inline-struct nesting reached `Options.max_depth`.
    DepthLimitExceeded,
};

/// Borrowed include-loader output; the parser copies it before parsing a new source.
pub const Source = struct {
    /// Canonical source identity used for include deduplication and diagnostics.
    name: []const u8,
    /// Complete FBS text, valid until the parser has copied this source.
    text: []const u8,
};

/// First reported failure, cleared by `parseWithOptions` before parsing starts.
pub const Diagnostic = struct {
    /// Copied source name, with the supplied allocator's lifetime.
    filename: []const u8 = "",
    /// One-based source line; zero means no diagnostic was emitted.
    line: usize = 0,
    /// One-based byte column, rather than a Unicode character count.
    column: usize = 0,
    /// Allocated failure description; empty when no diagnostic was produced.
    message: []const u8 = "",
};

/// Resolve `requested` relative to the including source `from` and caller search paths.
/// Return a canonical `Source` using the supplied allocator or other stable storage.
/// OutOfMemory propagates; every other callback error becomes IncludeNotFound.
pub const IncludeLoader = *const fn (
    context: ?*anyopaque,
    allocator: Allocator,
    from: []const u8,
    requested: []const u8,
) anyerror!Source;

/// Source identity, caller-controlled include loading, diagnostics, and depth limits.
pub const Options = struct {
    /// Main source name, copied before parsing; also passed to include loaders as `from`.
    filename: []const u8 = "schema.fbs",
    /// Resolve relative to `from`, then your include paths. Return a canonical
    /// name for deduplication, and text valid until the parser copies it.
    include_loader: ?IncludeLoader = null,
    /// Opaque borrowed callback state; the parser neither owns nor interprets it.
    include_context: ?*anyopaque = null,
    /// Diagnostic strings have the same arena lifetime as the returned schema.
    diagnostic: ?*Diagnostic = null,
    /// Depth threshold for includes and unresolved inline layouts; zero rejects the main source.
    max_depth: usize = 64,
};

/// Parse an FBS schema using caller-owned storage. Use an arena or equivalent
/// bulk-lifetime allocator for output and temporaries; keep it alive until all
/// schema consumers finish, and release it after success or failure.
/// Syntax/name/layout failures return `InvalidSchema`; unsupported recognized
/// constructs return `UnsupportedFeature`. Includes require `parseWithOptions`
/// and a loader. See the module example for the complete allocation lifecycle.
pub fn parse(allocator: Allocator, source: []const u8) Error!reflection.Schema {
    return parseWithOptions(allocator, source, .{});
}

/// Like `parse`, with include loading, diagnostics and depth limits.
/// Returned schema data and diagnostic strings share the supplied allocator
/// lifetime. Input text and filenames are copied into that storage.
/// Diagnostics are cleared first and may describe the failure after an error;
/// there is no rollback of arena allocations. Loader `OutOfMemory` propagates,
/// while other loader errors become `IncludeNotFound`.
///
/// Inside a function with `std`, `compiler = @import("flatzz_compiler")`,
/// and `parser = compiler.parser` declared:
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
/// defer arena.deinit();
/// var diagnostic: parser.Diagnostic = .{};
/// const result = parser.parseWithOptions(arena.allocator(), "table T { value:Missing; }", .{
///     .filename = "bad.fbs",
///     .diagnostic = &diagnostic,
/// });
/// if (result) |_| unreachable else |failure| {
///     std.debug.assert(failure == error.InvalidSchema);
///     std.debug.assert(std.mem.eql(u8, diagnostic.filename, "bad.fbs"));
///     std.debug.assert(diagnostic.line == 1);
/// }
/// ```
/// Expected result: `InvalidSchema` with a line-one diagnostic for `bad.fbs`;
/// no text is printed. The diagnostic strings remain valid until arena cleanup.
pub fn parseWithOptions(
    allocator: Allocator,
    source: []const u8,
    options: Options,
) Error!reflection.Schema {
    if (options.diagnostic) |diagnostic| diagnostic.* = .{};
    var compiler: Compiler = .{ .options = options };
    try compiler.load(allocator, .{ .name = options.filename, .text = source }, 0, true);
    return compiler.finish(allocator);
}

const Location = struct { source: Source, offset: usize };
const TokenKind = enum { identifier, number, string, punctuation, eof };
const Token = struct {
    kind: TokenKind,
    text: []const u8,
    offset: usize,
};
const Atom = struct { kind: TokenKind, text: []const u8, location: Location };
const Attributes = []const reflection.KeyValue;
const TypeRef = struct {
    value: *reflection.Type,
    name: ?[]const u8 = null,
    location: Location,
};
const FieldDef = struct {
    value: reflection.Field,
    type_ref: TypeRef,
    default: ?Atom = null,
    location: Location,
};
const ObjectDef = struct {
    value: reflection.Object,
    namespace: []const u8,
    fields: []FieldDef,
    location: Location,
    // Mutable view for layout and sorting; value.fields exposes the same storage as const.
    output_fields: []reflection.Field = &.{},
    state: enum { unseen, visiting, done } = .unseen,
};
const EnumValueDef = struct { value: reflection.EnumVal, type_ref: TypeRef };
const EnumDef = struct {
    value: reflection.Enum,
    namespace: []const u8,
    values: []EnumValueDef,
    location: Location,
};
const Symbol = union(enum) { object: usize, enumeration: usize };
const Root = struct { name: []const u8, namespace: []const u8, location: Location, main: bool };

// Resolve arena-backed declarations into sorted metadata with stable indices.
const Compiler = struct {
    options: Options,
    objects: std.ArrayList(ObjectDef) = .empty,
    enums: std.ArrayList(EnumDef) = .empty,
    roots: std.ArrayList(Root) = .empty,
    files: std.ArrayList(reflection.SchemaFile) = .empty,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
    loaded: std.StringHashMapUnmanaged(void) = .empty,
    custom_attributes: std.StringHashMapUnmanaged(void) = .empty,
    file_ident: ?[]const u8 = null,
    file_ext: ?[]const u8 = null,
    features: reflection.AdvancedFeatures = .{},

    fn fail(
        self: *Compiler,
        allocator: Allocator,
        location: Location,
        failure: Error,
        comptime format: []const u8,
        arguments: anytype,
    ) Error {
        if (self.options.diagnostic) |diagnostic| {
            const prefix = location.source.text[0..@min(location.offset, location.source.text.len)];
            const position = std.zig.findLineColumn(prefix, prefix.len);
            diagnostic.* = .{
                .filename = location.source.name,
                .line = position.line + 1,
                .column = position.column + 1,
                .message = allocator.print(format, arguments) catch return error.OutOfMemory,
            };
        }
        return failure;
    }

    fn invalid(
        self: *Compiler,
        allocator: Allocator,
        location: Location,
        comptime message: []const u8,
    ) Error {
        return self.fail(allocator, location, error.InvalidSchema, message, .{});
    }

    fn load(
        self: *Compiler,
        allocator: Allocator,
        input: Source,
        depth: usize,
        main: bool,
    ) Error!void {
        if (self.loaded.contains(input.name)) return;
        const source: Source = .{
            .name = try allocator.dupe(u8, input.name),
            .text = try allocator.dupe(u8, input.text),
        };
        const location: Location = .{ .source = source, .offset = 0 };
        if (depth >= self.options.max_depth)
            return self.fail(
                allocator,
                location,
                error.DepthLimitExceeded,
                "include depth limit exceeded",
                .{},
            );
        try self.loaded.put(allocator, source.name, {});
        var parser: Parser = .{ .compiler = self, .source = source, .depth = depth, .main = main };
        try parser.advance(allocator);
        try parser.declarations(allocator);
    }

    fn register(
        self: *Compiler,
        allocator: Allocator,
        name: []const u8,
        symbol: Symbol,
        location: Location,
    ) Error!void {
        const entry = try self.symbols.getOrPut(allocator, name);
        if (entry.found_existing)
            return self.fail(
                allocator,
                location,
                error.InvalidSchema,
                "duplicate type '{s}'",
                .{name},
            );
        entry.value_ptr.* = symbol;
    }

    fn lookup(
        self: *Compiler,
        allocator: Allocator,
        namespace: []const u8,
        name: []const u8,
        location: Location,
    ) Error!Symbol {
        var scope = namespace;
        while (scope.len != 0) {
            const qualified = try qualify(allocator, scope, name);
            // Nonempty scope makes this an owned key; lookup does not retain it.
            defer allocator.free(qualified);
            if (self.symbols.get(qualified)) |symbol| return symbol;
            scope = scope[0 .. std.mem.lastIndexOfScalar(u8, scope, '.') orelse 0];
        }
        return self.symbols.get(name) orelse
            self.fail(allocator, location, error.InvalidSchema, "unknown type '{s}'", .{name});
    }

    fn resolveType(
        self: *Compiler,
        allocator: Allocator,
        reference: TypeRef,
        namespace: []const u8,
    ) Error!void {
        const field_type = reference.value;
        if (reference.name) |name| {
            const symbol = try self.lookup(allocator, namespace, name, reference.location);
            field_type.index = std.math.cast(i32, switch (symbol) {
                .object, .enumeration => |index| index,
            }) orelse return error.InvalidSchema;
            const base: BaseType = switch (symbol) {
                .object => .Obj,
                .enumeration => |index| enum_base_blk: {
                    const enumeration = self.enums.items[index].value;
                    break :enum_base_blk if (enumeration.is_union)
                        .Union
                    else
                        enumeration.underlying_type.base_type;
                },
            };
            if (field_type.base_type == .Vector or field_type.base_type == .Array)
                field_type.element = base
            else
                field_type.base_type = base;
        }
        field_type.base_size = baseSize(field_type.base_type);
        field_type.element_size = baseSize(field_type.element);
    }

    fn finish(self: *Compiler, allocator: Allocator) Error!reflection.Schema {
        // Resolve indices only after sorting the final type lists.
        inline for (.{
            .{ ObjectDef, self.objects.items, .object },
            .{ EnumDef, self.enums.items, .enumeration },
        }) |definition| {
            const Definition = definition[0];
            std.mem.sort(Definition, definition[1], {}, struct {
                fn less(_: void, left: Definition, right: Definition) bool {
                    return std.mem.lessThan(u8, left.value.name, right.value.name);
                }
            }.less);
            for (definition[1], 0..) |item, index|
                try self.symbols.put(
                    allocator,
                    item.value.name,
                    @unionInit(Symbol, @tagName(definition[2]), index),
                );
        }

        const objects = try allocator.alloc(reflection.Object, self.objects.items.len);
        const enums = try allocator.alloc(reflection.Enum, self.enums.items.len);
        for (self.enums.items, 0..) |*enumeration, index| {
            const underlying = try allocator.create(reflection.Type);
            underlying.* = enumeration.value.underlying_type.*;
            underlying.index = std.math.cast(i32, index) orelse return error.InvalidSchema;
            enumeration.value.underlying_type = underlying;
            const values = try allocator.alloc(reflection.EnumVal, enumeration.values.len);
            for (enumeration.values, 0..) |*item, value_index| {
                try self.resolveType(allocator, item.type_ref, enumeration.namespace);
                const field_type = item.type_ref.value;
                if (enumeration.value.is_union and value_index != 0) {
                    if (field_type.base_type != .Obj and field_type.base_type != .String)
                        return self.invalid(
                            allocator,
                            item.type_ref.location,
                            "union alternatives must be tables, structs or strings",
                        );
                    if (field_type.base_type == .String or
                        self.objects.items[@intCast(field_type.index)].value.is_struct)
                        self.features.advanced_union_features = true;
                }
                values[value_index] = item.value;
            }
            enumeration.value.values = values;
            enums[index] = enumeration.value;
        }
        for (0..self.objects.items.len) |index| try self.prepareObject(allocator, index);
        for (0..self.objects.items.len) |index| try self.layoutObject(allocator, index, 0);

        for (self.objects.items, 0..) |*object, index| {
            for (object.fields) |field| {
                const field_type = field.type_ref.value;
                if (field_type.base_type == .Vector and field_type.element == .Obj) {
                    const element = self.objects.items[@intCast(field_type.index)].value;
                    if (element.is_struct) field_type.element_size = @intCast(element.bytesize);
                }
            }
            std.mem.sort(reflection.Field, object.output_fields, {}, lessField);
            objects[index] = object.value;
        }
        var root_table: ?*const reflection.Object = null;
        for (self.roots.items) |root| {
            const symbol = try self.lookup(allocator, root.namespace, root.name, root.location);
            if (symbol != .object or objects[symbol.object].is_struct)
                return self.invalid(allocator, root.location, "root_type must name a table");
            if (root.main) root_table = &objects[symbol.object];
        }
        std.mem.sort(reflection.SchemaFile, self.files.items, {}, lessFile);
        return .{
            .objects = objects,
            .enums = enums,
            .root_table = root_table,
            .file_ident = self.file_ident,
            .file_ext = self.file_ext,
            .advanced_features = self.features,
            .fbs_files = self.files.items,
        };
    }

    fn prepareObject(self: *Compiler, allocator: Allocator, index: usize) Error!void {
        const object = &self.objects.items[index];
        var count = object.fields.len;
        var explicit_ids = false;
        var key_count: usize = 0;
        for (object.fields) |*field| {
            try self.resolveType(allocator, field.type_ref, object.namespace);
            const field_type = field.type_ref.value;
            if (field_type.base_type == .Union or
                (field_type.base_type == .Vector and field_type.element == .Union)) count += 1;
            explicit_ids = explicit_ids or attribute(field.value.attributes, .id) != null;
            try self.finishField(allocator, field, object);
            if (field.value.key) key_count += 1;
        }
        if (key_count > 1) return self.invalid(
            allocator,
            object.location,
            "a table may have only one key",
        );
        if (count > wire.max_field_count)
            return self.invalid(
                allocator,
                object.location,
                "too many fields for reflection/vtable metadata",
            );
        const fields = try allocator.alloc(reflection.Field, count);
        const used = try allocator.alloc(bool, count);
        @memset(used, false);
        var names: std.StringHashMapUnmanaged(void) = .empty;
        var next: usize = 0;
        for (object.fields) |field| {
            var value = field.value;
            const union_field = value.type.base_type == .Union or
                (value.type.base_type == .Vector and value.type.element == .Union);
            const id_attribute = attribute(value.attributes, .id);
            if (explicit_ids and id_attribute == null)
                return self.invalid(
                    allocator,
                    field.location,
                    "use explicit IDs on every field or none",
                );
            const field_id: usize = if (id_attribute) |item|
                std.math.cast(
                    usize,
                    try self.integer(allocator, item.value.?, field.location),
                ) orelse
                    return self.invalid(allocator, field.location, "field ID must be nonnegative")
            else
                next + @intFromBool(union_field);
            value.id = std.math.cast(u16, field_id) orelse
                return self.invalid(allocator, field.location, "field ID exceeds u16 range");
            value.offset = if (object.value.is_struct) 0 else std.math.cast(
                u16,
                wire.vtable_header_size + wire.vtable_entry_size * field_id,
            ) orelse
                return self.invalid(allocator, field.location, "field ID exceeds vtable range");
            if (union_field) {
                if (field_id == 0) return self.invalid(
                    allocator,
                    field.location,
                    "union value ID must leave room for its type field",
                );
                const vector = value.type.base_type == .Vector;
                const tag_type = try allocator.create(reflection.Type);
                tag_type.* = .{
                    .base_type = if (vector) .Vector else .UType,
                    .element = if (vector) .UType else .None,
                    .index = value.type.index,
                    .base_size = if (vector) wire.field_offset_size else @sizeOf(wire.UnionTag),
                    .element_size = @sizeOf(wire.UnionTag),
                };
                const tag: reflection.Field = .{
                    .name = try allocator.print("{s}_type", .{value.name}),
                    .type = tag_type,
                    .id = @intCast(field_id - 1),
                    .offset = value.offset - wire.vtable_entry_size,
                    .deprecated = value.deprecated,
                    .required = vector and value.required,
                    .optional = vector and value.optional,
                };
                try self.checkField(allocator, tag, &names, used, field.location);
                fields[next] = tag;
                next += 1;
            }
            try self.checkField(allocator, value, &names, used, field.location);
            fields[next] = value;
            next += 1;
        }
        object.output_fields = fields;
        object.value.fields = fields;
    }

    fn checkField(
        self: *Compiler,
        allocator: Allocator,
        field: reflection.Field,
        names: *std.StringHashMapUnmanaged(void),
        used: []bool,
        location: Location,
    ) Error!void {
        if (field.id >= used.len or used[field.id])
            return self.invalid(
                allocator,
                location,
                "field IDs must be unique and contiguous from zero",
            );
        used[field.id] = true;
        if ((try names.getOrPut(allocator, field.name)).found_existing)
            return self.fail(
                allocator,
                location,
                error.InvalidSchema,
                "duplicate field '{s}' (including union type fields)",
                .{field.name},
            );
    }

    fn finishField(
        self: *Compiler,
        allocator: Allocator,
        field: *FieldDef,
        object: *const ObjectDef,
    ) Error!void {
        const field_type = field.type_ref.value;
        const scalar = isScalar(field_type.base_type);
        if (object.value.is_struct) {
            if (field.default != null or attribute(field.value.attributes, .id) != null or
                field.value.required or field.value.deprecated or field.value.key)
                return self.invalid(
                    allocator,
                    field.location,
                    "struct members cannot have defaults or table-field attributes",
                );
            try self.checkInlineType(allocator, field_type, field.location);
            // Preserve the existing Flatzz schemas: inline enums have no
            // omitted-field default and need not declare a zero variant.
            return;
        }
        if (field_type.base_type == .Array)
            return self.invalid(
                allocator,
                field.location,
                "fixed arrays are only allowed in structs",
            );
        if (field.value.required and scalar)
            return self.invalid(
                allocator,
                field.location,
                "required is only valid on reference/struct fields",
            );
        if (field.value.key and !scalar and field_type.base_type != .String)
            return self.invalid(allocator, field.location, "key requires a scalar or string");
        if (field.value.key and field_type.base_type == .String) field.value.required = true;
        field.value.optional = !scalar and !field.value.required;
        if (field_type.base_type == .Vector and field_type.element == .Union)
            self.features.advanced_union_features = true;
        if (!scalar) {
            if (field.default != null)
                return self.fail(
                    allocator,
                    field.location,
                    error.UnsupportedFeature,
                    "non-scalar defaults are not supported",
                    .{},
                );
            return;
        }
        if (field.default) |value| {
            if (std.mem.eql(u8, value.text, "null")) {
                if (field.value.key)
                    return self.invalid(
                        allocator,
                        value.location,
                        "a key cannot be an optional scalar",
                    );
                field.value.optional = true;
                self.features.optional_scalars = true;
                return;
            }
            if (field_type.base_type == .Float or field_type.base_type == .Double) {
                if (std.mem.indexOfScalar(u8, value.text, '_') != null)
                    return self.invalid(
                        allocator,
                        value.location,
                        "invalid floating-point default",
                    );
                const number = std.fmt.parseFloat(f64, value.text) catch
                    return self.invalid(
                        allocator,
                        value.location,
                        "invalid floating-point default",
                    );
                if (field_type.base_type == .Float) {
                    const narrowed: f32 = @floatCast(number);
                    if (std.math.isFinite(number) and !std.math.isFinite(narrowed))
                        return self.invalid(
                            allocator,
                            value.location,
                            "default is outside float32 range",
                        );
                }
                // Reflection carries the f64 parsing of the literal even for
                // float32 fields. The generated field type performs narrowing.
                field.value.default_real = number;
            } else if (field_type.base_type == .Bool) {
                field.value.default_integer = if (std.mem.eql(u8, value.text, "true"))
                    1
                else if (std.mem.eql(u8, value.text, "false"))
                    0
                else
                    try self.integerBits(
                        allocator,
                        try self.integer(allocator, value.text, value.location),
                        .Bool,
                        value.location,
                    );
            } else {
                var number: i128 = undefined;
                const named_default = value.text.len != 0 and
                    (std.ascii.isAlphabetic(value.text[0]) or value.text[0] == '_');
                if (named_default and field_type.index >= 0) {
                    const enumeration = &self.enums.items[@intCast(field_type.index)];
                    var member = value.text;
                    if (std.mem.lastIndexOfScalar(u8, member, '.')) |dot| {
                        const symbol = try self.lookup(
                            allocator,
                            object.namespace,
                            member[0..dot],
                            value.location,
                        );
                        if (symbol != .enumeration or symbol.enumeration != @as(
                            usize,
                            @intCast(field_type.index),
                        ))
                            return self.invalid(
                                allocator,
                                value.location,
                                "default names a different enum",
                            );
                        member = member[dot + 1 ..];
                    }
                    const bits = enum_value_blk: {
                        for (enumeration.values) |item|
                            if (std.mem.eql(
                                u8,
                                item.value.name,
                                member,
                            )) break :enum_value_blk item.value.value;
                        return self.fail(
                            allocator,
                            value.location,
                            error.InvalidSchema,
                            "unknown enum value '{s}'",
                            .{member},
                        );
                    };
                    number = if (isUnsigned(field_type.base_type)) @as(
                        u64,
                        @bitCast(bits),
                    ) else bits;
                } else number = try self.integer(allocator, value.text, value.location);
                field.value.default_integer = try self.integerBits(
                    allocator,
                    number,
                    field_type.base_type,
                    value.location,
                );
            }
        }
        if (field_type.index >= 0) {
            const enumeration = self.enums.items[@intCast(field_type.index)];
            for (enumeration.values) |item|
                if (item.value.value == field.value.default_integer) return;
            return self.invalid(
                allocator,
                field.location,
                "enum default must be a declared enum value",
            );
        }
    }

    fn checkInlineType(
        self: *Compiler,
        allocator: Allocator,
        field_type: *const reflection.Type,
        location: Location,
    ) Error!void {
        const base = if (field_type.base_type == .Array)
            field_type.element
        else
            field_type.base_type;
        if (field_type.base_type == .Array) self.features.advanced_array_features = true;
        if (isScalar(base) or
            (base == .Obj and self.objects.items[@intCast(field_type.index)].value.is_struct))
            return;
        return self.invalid(
            allocator,
            location,
            "struct members must be scalars, structs or fixed arrays of them",
        );
    }

    fn layoutObject(self: *Compiler, allocator: Allocator, index: usize, depth: usize) Error!void {
        const object = &self.objects.items[index];
        if (!object.value.is_struct or object.state == .done) return;
        if (object.state == .visiting)
            return self.invalid(allocator, object.location, "recursive inline struct");
        if (depth >= self.options.max_depth)
            return self.fail(
                allocator,
                object.location,
                error.DepthLimitExceeded,
                "struct nesting depth limit exceeded",
                .{},
            );
        object.state = .visiting;
        var size: u64 = 0;
        var alignment: u32 = 1;
        for (object.output_fields, 0..) |*field, field_index| {
            const field_type = field.type;
            const base = if (field_type.base_type == .Array)
                field_type.element
            else
                field_type.base_type;
            var member_size: u64 = baseSize(base);
            var member_alignment: u32 = @intCast(member_size);
            if (base == .Obj) {
                const member_index: usize = @intCast(field_type.index);
                try self.layoutObject(allocator, member_index, depth + 1);
                const nested = self.objects.items[member_index].value;
                member_size = @intCast(nested.bytesize);
                member_alignment = @intCast(nested.minalign);
            }
            if (field_type.base_type == .Array) member_size *= field_type.fixed_length;
            const offset = std.mem.alignForward(u64, size, member_alignment);
            if (field_index > 0)
                object.output_fields[field_index - 1].padding = @intCast(offset - size);
            field.offset = std.math.cast(u16, offset) orelse
                return self.invalid(
                    allocator,
                    object.location,
                    "struct field offset exceeds reflection's u16 range",
                );
            size = offset + member_size;
            alignment = @max(alignment, member_alignment);
            if (size > std.math.maxInt(i32))
                return self.invalid(
                    allocator,
                    object.location,
                    "struct size exceeds reflection's i32 range",
                );
        }
        const final_size = std.mem.alignForward(u64, size, alignment);
        object.output_fields[object.output_fields.len - 1].padding = @intCast(final_size - size);
        object.value.bytesize = std.math.cast(i32, final_size) orelse return error.InvalidSchema;
        object.value.minalign = @intCast(alignment);
        object.state = .done;
    }

    fn integer(
        self: *Compiler,
        allocator: Allocator,
        text: []const u8,
        location: Location,
    ) Error!i128 {
        var digits = text;
        var negative = false;
        if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) {
            negative = digits[0] == '-';
            digits = digits[1..];
        }
        const hexadecimal = std.mem.startsWith(
            u8,
            digits,
            "0x",
        ) or std.mem.startsWith(u8, digits, "0X");
        if (hexadecimal) digits = digits[2..];
        if (digits.len == 0) return self.invalid(allocator, location, "expected integer");
        for (digits) |byte| {
            if (!(if (hexadecimal) std.ascii.isHex(byte) else std.ascii.isDigit(byte)))
                return self.fail(
                    allocator,
                    location,
                    error.InvalidSchema,
                    "invalid integer '{s}'",
                    .{text},
                );
        }
        const magnitude = std.fmt.parseInt(i128, digits, if (hexadecimal) 16 else 10) catch
            return self.invalid(allocator, location, "integer is too large");
        return if (negative) -magnitude else magnitude;
    }

    fn integerBits(
        self: *Compiler,
        allocator: Allocator,
        value: i128,
        base: BaseType,
        location: Location,
    ) Error!i64 {
        const bits: u7 = @intCast(baseSize(base) * 8);
        const unsigned = isUnsigned(base);
        const limit = @as(i128, 1) << (if (unsigned) bits else bits - 1);
        const minimum: i128 = if (unsigned) 0 else -limit;
        const maximum: i128 = if (base == .Bool) 1 else limit - 1;
        if (value < minimum or value > maximum)
            return self.fail(
                allocator,
                location,
                error.InvalidSchema,
                "integer is outside {s} range",
                .{@tagName(base)},
            );
        return if (unsigned) @bitCast(@as(u64, @intCast(value))) else @intCast(value);
    }
};

// One source cursor; include recursion shares the enclosing compiler state.
const Parser = struct {
    compiler: *Compiler,
    source: Source,
    depth: usize,
    main: bool,
    position: usize = 0,
    token: Token = .{ .kind = .eof, .text = "", .offset = 0 },
    namespace: []const u8 = "",

    fn location(self: *const Parser) Location {
        return .{ .source = self.source, .offset = self.token.offset };
    }
    fn matchesToken(self: *const Parser, text: []const u8) bool {
        return std.mem.eql(u8, self.token.text, text);
    }
    fn take(self: *Parser, allocator: Allocator, text: []const u8) Error!bool {
        if (!self.matchesToken(text)) return false;
        try self.advance(allocator);
        return true;
    }
    fn expect(self: *Parser, allocator: Allocator, text: []const u8) Error!void {
        if (!try self.take(allocator, text)) return self.compiler.fail(
            allocator,
            self.location(),
            error.InvalidSchema,
            "expected '{s}', found '{s}'",
            .{ text, self.token.text },
        );
    }
    fn identifier(self: *Parser, allocator: Allocator) Error![]const u8 {
        if (self.token.kind != .identifier)
            return self.compiler.invalid(allocator, self.location(), "expected identifier");
        const spelling = self.token.text;
        try self.advance(allocator);
        return spelling;
    }
    fn name(self: *Parser, allocator: Allocator) Error![]const u8 {
        var result = try self.identifier(allocator);
        while (try self.take(allocator, ".")) result = try qualify(
            allocator,
            result,
            try self.identifier(allocator),
        );
        return result;
    }
    fn string(self: *Parser, allocator: Allocator) Error![]const u8 {
        if (self.token.kind != .string)
            return self.compiler.invalid(allocator, self.location(), "expected quoted string");
        const result = std.json.parseFromSliceLeaky(
            []const u8,
            allocator,
            self.token.text,
            .{ .allocate = .alloc_always },
        ) catch |failure| {
            if (failure == error.OutOfMemory) return error.OutOfMemory;
            return self.compiler.invalid(
                allocator,
                self.location(),
                "invalid string or escape sequence",
            );
        };
        try self.advance(allocator);
        return result;
    }
    fn atom(self: *Parser, allocator: Allocator) Error!Atom {
        const token = self.token;
        const token_location = self.location();
        const text = switch (token.kind) {
            .identifier => try self.name(allocator),
            .string => try self.string(allocator),
            .number => number_text_blk: {
                try self.advance(allocator);
                break :number_text_blk token.text;
            },
            else => return self.compiler.invalid(
                allocator,
                token_location,
                "expected a literal or enum value",
            ),
        };
        return .{ .kind = token.kind, .text = text, .location = token_location };
    }

    fn declarations(self: *Parser, allocator: Allocator) Error!void {
        const compiler = self.compiler;
        var includes: std.ArrayList([]const u8) = .empty;
        var saw_declaration = false;
        var saw_root = false;
        var saw_identifier = false;
        var saw_extension = false;
        while (self.token.kind != .eof) {
            const token_location = self.location();
            if (try self.take(allocator, "include")) {
                if (saw_declaration) return compiler.invalid(
                    allocator,
                    token_location,
                    "includes must precede declarations",
                );
                const requested = try self.string(allocator);
                try self.expect(allocator, ";");
                const loader = compiler.options.include_loader orelse
                    return compiler.fail(
                        allocator,
                        token_location,
                        error.IncludeNotFound,
                        "no include loader for '{s}'",
                        .{requested},
                    );
                const included = loader(
                    compiler.options.include_context,
                    allocator,
                    self.source.name,
                    requested,
                ) catch |failure| {
                    if (failure == error.OutOfMemory) return error.OutOfMemory;
                    return compiler.fail(
                        allocator,
                        token_location,
                        error.IncludeNotFound,
                        "cannot include '{s}': {s}",
                        .{ requested, @errorName(failure) },
                    );
                };
                try includes.append(allocator, try allocator.dupe(u8, included.name));
                try compiler.load(allocator, included, self.depth + 1, false);
                continue;
            }
            saw_declaration = true;
            if (try self.take(allocator, "namespace")) {
                self.namespace = if (self.matchesToken(";")) "" else try self.name(allocator);
                try self.expect(allocator, ";");
            } else if (self.matchesToken("table") or self.matchesToken("struct")) {
                try self.object(allocator);
            } else if (self.matchesToken("enum") or self.matchesToken("union")) {
                try self.enumeration(allocator);
            } else if (try self.take(allocator, "root_type")) {
                if (saw_root) return compiler.invalid(
                    allocator,
                    token_location,
                    "duplicate root_type",
                );
                saw_root = true;
                try compiler.roots.append(
                    allocator,
                    .{
                        .name = try self.name(allocator),
                        .namespace = self.namespace,
                        .location = token_location,
                        .main = self.main,
                    },
                );
                try self.expect(allocator, ";");
            } else if (try self.take(allocator, "file_identifier")) {
                if (saw_identifier) return compiler.invalid(
                    allocator,
                    token_location,
                    "duplicate file_identifier",
                );
                saw_identifier = true;
                const value = try self.string(allocator);
                if (value.len != wire.file_identifier_size)
                    return compiler.invalid(
                        allocator,
                        token_location,
                        "file_identifier must contain exactly four bytes",
                    );
                if (self.main) compiler.file_ident = value;
                try self.expect(allocator, ";");
            } else if (try self.take(allocator, "file_extension")) {
                if (saw_extension) return compiler.invalid(
                    allocator,
                    token_location,
                    "duplicate file_extension",
                );
                saw_extension = true;
                const value = try self.string(allocator);
                if (self.main) compiler.file_ext = value;
                try self.expect(allocator, ";");
            } else if (try self.take(allocator, "attribute")) {
                const value = if (self.token.kind == .string)
                    try self.string(allocator)
                else
                    try self.identifier(allocator);
                if (std.meta.stringToEnum(BuiltinAttribute, value) != null) return compiler.fail(
                    allocator,
                    token_location,
                    error.InvalidSchema,
                    "cannot redeclare built-in attribute '{s}'",
                    .{value},
                );
                try compiler.custom_attributes.put(allocator, value, {});
                try self.expect(allocator, ";");
            } else {
                const failure: Error = if (self.matchesToken("rpc_service"))
                    error.UnsupportedFeature
                else
                    error.InvalidSchema;
                return compiler.fail(
                    allocator,
                    token_location,
                    failure,
                    "unsupported declaration '{s}'",
                    .{self.token.text},
                );
            }
        }
        try compiler.files.append(
            allocator,
            .{ .filename = self.source.name, .included_filenames = includes.items },
        );
    }

    fn object(self: *Parser, allocator: Allocator) Error!void {
        const compiler = self.compiler;
        const token_location = self.location();
        const structure = self.matchesToken("struct");
        try self.advance(allocator);
        const object_name = try qualify(allocator, self.namespace, try self.identifier(allocator));
        try compiler.register(
            allocator,
            object_name,
            .{ .object = compiler.objects.items.len },
            token_location,
        );
        const declaration_attributes = try self.attributes(allocator, false);
        try self.expect(allocator, "{");
        var fields: std.ArrayList(FieldDef) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        while (!try self.take(allocator, "}")) {
            const field_location = self.location();
            const field_name = try self.identifier(allocator);
            if ((try names.getOrPut(allocator, field_name)).found_existing)
                return compiler.fail(
                    allocator,
                    field_location,
                    error.InvalidSchema,
                    "duplicate field '{s}'",
                    .{field_name},
                );
            try self.expect(allocator, ":");
            const reference = try self.typeReference(allocator);
            const default = if (try self.take(allocator, "=")) try self.atom(allocator) else null;
            const field_attributes = try self.attributes(allocator, true);
            try self.expect(allocator, ";");
            try fields.append(allocator, .{
                .value = .{
                    .name = field_name,
                    .type = reference.value,
                    .attributes = field_attributes,
                    .required = attribute(field_attributes, .required) != null,
                    .deprecated = attribute(field_attributes, .deprecated) != null,
                    .key = attribute(field_attributes, .key) != null,
                },
                .type_ref = reference,
                .default = default,
                .location = field_location,
            });
        }
        _ = try self.take(allocator, ";");
        if (structure and fields.items.len == 0) return compiler.invalid(
            allocator,
            token_location,
            "structs must have at least one member",
        );
        try compiler.objects.append(allocator, .{
            .value = .{
                .name = object_name,
                .fields = &.{},
                .is_struct = structure,
                .minalign = 1,
                .attributes = declaration_attributes,
                .declaration_file = self.source.name,
            },
            .namespace = self.namespace,
            .fields = fields.items,
            .location = token_location,
        });
    }

    fn enumeration(self: *Parser, allocator: Allocator) Error!void {
        const compiler = self.compiler;
        const token_location = self.location();
        const union_type = self.matchesToken("union");
        try self.advance(allocator);
        const enum_name = try qualify(allocator, self.namespace, try self.identifier(allocator));
        try compiler.register(
            allocator,
            enum_name,
            .{ .enumeration = compiler.enums.items.len },
            token_location,
        );
        var underlying_base: BaseType = .UType;
        if (!union_type) {
            try self.expect(allocator, ":");
            underlying_base = scalarType(try self.identifier(allocator)) orelse .None;
            if (!isScalar(underlying_base) or underlying_base == .Bool or
                underlying_base == .Float or underlying_base == .Double)
                return compiler.invalid(
                    allocator,
                    token_location,
                    "enum underlying type must be an integer",
                );
        } else if (self.matchesToken(":")) return compiler.fail(
            allocator,
            token_location,
            error.UnsupportedFeature,
            "custom union tag types are not supported",
            .{},
        );
        const underlying = try allocator.create(reflection.Type);
        underlying.* = .{
            .base_type = underlying_base,
            .base_size = baseSize(underlying_base),
            .element_size = 1,
        };
        const declaration_attributes = try self.attributes(allocator, false);
        try self.expect(allocator, "{");
        var values: std.ArrayList(EnumValueDef) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        var next_value: i128 = 0;
        if (union_type) {
            const none = try emptyType(allocator, token_location);
            try values.append(
                allocator,
                .{ .value = .{ .name = "NONE", .union_type = none.value }, .type_ref = none },
            );
            try names.put(allocator, "NONE", {});
            next_value = 1;
        }
        while (!try self.take(allocator, "}")) {
            const member_location = self.location();
            var member_name = if (union_type)
                try self.name(allocator)
            else
                try self.identifier(allocator);
            var reference = try emptyType(allocator, member_location);
            if (union_type) {
                var target = member_name;
                const aliased = try self.take(allocator, ":");
                if (aliased) {
                    if (std.mem.indexOfScalar(u8, member_name, '.') != null)
                        return compiler.invalid(
                            allocator,
                            member_location,
                            "a union alias must be an unqualified identifier",
                        );
                    target = try self.name(allocator);
                } else if (std.mem.indexOfScalar(u8, member_name, '.') != null) {
                    const renamed = try allocator.dupe(u8, member_name);
                    for (renamed) |*byte| if (byte.* == '.') {
                        byte.* = '_';
                    };
                    member_name = renamed;
                }
                if (scalarType(target)) |base| {
                    if (!aliased) return compiler.invalid(
                        allocator,
                        member_location,
                        "built-in union alternatives require an alias, for example Text:string",
                    );
                    reference.value.base_type = base;
                } else reference.name = target;
            }
            if ((try names.getOrPut(allocator, member_name)).found_existing)
                return compiler.fail(
                    allocator,
                    member_location,
                    error.InvalidSchema,
                    "duplicate enum/union member '{s}'",
                    .{member_name},
                );
            var numeric_value = next_value;
            if (try self.take(allocator, "=")) {
                const number = try self.atom(allocator);
                if (number.kind != .number) return compiler.invalid(
                    allocator,
                    number.location,
                    "enum values must be integer literals",
                );
                numeric_value = try compiler.integer(allocator, number.text, number.location);
                if (numeric_value < next_value and values.items.len != 0)
                    return compiler.invalid(
                        allocator,
                        member_location,
                        "enum values must be strictly increasing",
                    );
            }
            const bits = try compiler.integerBits(
                allocator,
                numeric_value,
                underlying_base,
                member_location,
            );
            const member_attributes = try self.attributes(allocator, false);
            try values.append(allocator, .{
                .value = .{
                    .name = member_name,
                    .value = bits,
                    .union_type = reference.value,
                    .attributes = member_attributes,
                },
                .type_ref = reference,
            });
            next_value = numeric_value + 1;
            if (try self.take(allocator, ",")) continue;
            try self.expect(allocator, "}");
            break;
        }
        _ = try self.take(allocator, ";");
        if (values.items.len == 0) return compiler.invalid(
            allocator,
            token_location,
            "enum must contain at least one value",
        );
        try compiler.enums.append(allocator, .{
            .value = .{
                .name = enum_name,
                .values = &.{},
                .is_union = union_type,
                .underlying_type = underlying,
                .attributes = declaration_attributes,
                .declaration_file = self.source.name,
            },
            .namespace = self.namespace,
            .values = values.items,
            .location = token_location,
        });
    }

    fn emptyType(allocator: Allocator, token_location: Location) Error!TypeRef {
        const value = try allocator.create(reflection.Type);
        value.* = .{ .base_size = 1, .element_size = 1 };
        return .{ .value = value, .location = token_location };
    }

    fn typeReference(self: *Parser, allocator: Allocator) Error!TypeRef {
        const compiler = self.compiler;
        var reference = try emptyType(allocator, self.location());
        const sequence = try self.take(allocator, "[");
        const type_name = try self.name(allocator);
        const base = scalarType(type_name) orelse .None;
        if (base == .None) reference.name = type_name;
        reference.value.base_type = if (sequence) .Vector else base;
        reference.value.element = if (sequence) base else .None;
        if (sequence) {
            if (try self.take(allocator, ":")) {
                const count = try self.atom(allocator);
                if (count.kind != .number) return compiler.invalid(
                    allocator,
                    count.location,
                    "array length must be an integer",
                );
                const length = try compiler.integer(allocator, count.text, count.location);
                if (length < 0 or length > wire.max_array_length)
                    return compiler.invalid(
                        allocator,
                        count.location,
                        "array length must fit in u16",
                    );
                if (length == 0) return compiler.invalid(
                    allocator,
                    count.location,
                    "array length must be positive",
                );
                reference.value.base_type = .Array;
                reference.value.fixed_length = @intCast(length);
            }
            try self.expect(allocator, "]");
        }
        return reference;
    }

    fn attributes(self: *Parser, allocator: Allocator, field: bool) Error!Attributes {
        if (!try self.take(allocator, "(")) return &.{};
        const compiler = self.compiler;
        var result: std.ArrayList(reflection.KeyValue) = .empty;
        while (true) {
            const token_location = self.location();
            const key = try self.identifier(allocator);
            for (result.items) |item| if (std.mem.eql(u8, item.key, key))
                return compiler.fail(
                    allocator,
                    token_location,
                    error.InvalidSchema,
                    "duplicate attribute '{s}'",
                    .{key},
                );
            const value: ?[]const u8 = if (try self.take(
                allocator,
                ":",
            )) (try self.atom(allocator)).text else null;
            if (std.meta.stringToEnum(BuiltinAttribute, key)) |kind| {
                switch (kind) {
                    .id, .required, .deprecated, .key => {
                        if (!field) return compiler.fail(
                            allocator,
                            token_location,
                            error.InvalidSchema,
                            "'{s}' is a field attribute",
                            .{key},
                        );
                        if ((kind == .id) != (value != null))
                            return compiler.fail(
                                allocator,
                                token_location,
                                error.InvalidSchema,
                                "invalid value for attribute '{s}'",
                                .{key},
                            );
                    },
                    else => return compiler.fail(
                        allocator,
                        token_location,
                        error.UnsupportedFeature,
                        "attribute '{s}' is not supported",
                        .{key},
                    ),
                }
            } else if (!compiler.custom_attributes.contains(key)) {
                return compiler.fail(
                    allocator,
                    token_location,
                    error.InvalidSchema,
                    "attribute '{s}' must be declared first",
                    .{key},
                );
            }
            try result.append(allocator, .{ .key = key, .value = value });
            if (!try self.take(allocator, ",")) break;
        }
        try self.expect(allocator, ")");
        return result.items;
    }

    fn advance(self: *Parser, allocator: Allocator) Error!void {
        const bytes = self.source.text;
        while (self.position < bytes.len) {
            const start = self.position;
            const byte = bytes[start];
            if (std.ascii.isWhitespace(byte)) {
                self.position += 1;
                continue;
            }
            if (byte == '/' and start + 1 < bytes.len) {
                if (bytes[start + 1] == '/') {
                    self.position += 2;
                    while (self.position < bytes.len and bytes[self.position] != '\n')
                        self.position += 1;
                    continue;
                }
                if (bytes[start + 1] == '*') {
                    const tail = std.mem.indexOf(u8, bytes[start + 2 ..], "*/") orelse
                        return self.compiler.invalid(
                            allocator,
                            .{ .source = self.source, .offset = start },
                            "unterminated block comment",
                        );
                    self.position = start + 2 + tail + 2;
                    continue;
                }
            }
            self.position += 1;
            const kind: TokenKind = if (std.ascii.isAlphabetic(byte) or
                byte == '_')
            identifier_token_blk: {
                while (self.position < bytes.len and
                    (std.ascii.isAlphanumeric(bytes[self.position]) or bytes[self.position] == '_'))
                    self.position += 1;
                break :identifier_token_blk .identifier;
            } else if (std.ascii.isDigit(byte) or byte == '+' or byte == '-' or
                (byte == '.' and self.position < bytes.len and
                    std.ascii.isDigit(bytes[self.position])))
            number_token_blk: {
                while (self.position < bytes.len) {
                    const next = bytes[self.position];
                    if (!std.ascii.isAlphanumeric(next) and std.mem.indexOfScalar(
                        u8,
                        ".+-_",
                        next,
                    ) == null) break;
                    self.position += 1;
                }
                break :number_token_blk .number;
            } else if (byte == '"') string_token_blk: {
                while (self.position < bytes.len) {
                    const next = bytes[self.position];
                    self.position += 1;
                    if (next == '"') break :string_token_blk .string;
                    if (next == '\\' and self.position < bytes.len) self.position += 1;
                }
                return self.compiler.invalid(
                    allocator,
                    .{ .source = self.source, .offset = start },
                    "unterminated string",
                );
            } else if (std.mem.indexOfScalar(
                u8,
                "{}[]():;,.=",
                byte,
            ) != null) .punctuation else return self.compiler.invalid(
                allocator,
                .{ .source = self.source, .offset = start },
                "unexpected character",
            );
            self.token = .{ .kind = kind, .text = bytes[start..self.position], .offset = start };
            return;
        }
        self.token = .{ .kind = .eof, .text = "", .offset = bytes.len };
    }
};

fn attribute(attributes: ?Attributes, comptime key: BuiltinAttribute) ?reflection.KeyValue {
    for (attributes orelse &.{}) |item| if (std.mem.eql(u8, item.key, @tagName(key))) return item;
    return null;
}
fn qualify(
    allocator: Allocator,
    namespace: []const u8,
    name: []const u8,
) Allocator.Error![]const u8 {
    return if (namespace.len == 0) name else allocator.print("{s}.{s}", .{ namespace, name });
}
fn scalarType(name: []const u8) ?BaseType {
    return scalar_types.get(name);
}
fn isScalar(base: BaseType) bool {
    return switch (base) {
        .UType,
        .Bool,
        .Byte,
        .UByte,
        .Short,
        .UShort,
        .Int,
        .UInt,
        .Long,
        .ULong,
        .Float,
        .Double,
        => true,
        else => false,
    };
}
fn isUnsigned(base: BaseType) bool {
    return switch (base) {
        .UType, .Bool, .UByte, .UShort, .UInt, .ULong => true,
        else => false,
    };
}
fn baseSize(base: BaseType) u32 {
    return switch (base) {
        .None, .UType, .Bool, .Byte, .UByte => 1,
        .Short, .UShort => 2,
        .Long, .ULong, .Double, .Vector64 => 8,
        else => 4,
    };
}
fn lessField(_: void, left: reflection.Field, right: reflection.Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn lessFile(_: void, left: reflection.SchemaFile, right: reflection.SchemaFile) bool {
    return std.mem.lessThan(u8, left.filename, right.filename);
}

const attribute_diagnostics = [_]struct {
    source: []const u8,
    line: usize,
    column: usize,
    message: []const u8,
}{
    .{
        .source = "table Message {\n    label:string (required, required:);\n}",
        .line = 2,
        .column = 29,
        .message = "duplicate attribute 'required'",
    },
    .{
        .source = "table Message {\n    label:string (force_align:);\n}",
        .line = 2,
        .column = 31,
        .message = "expected a literal or enum value",
    },
    .{
        .source = "table Message (required:true) {}",
        .line = 1,
        .column = 16,
        .message = "'required' is a field attribute",
    },
    .{
        .source = "attribute \"force_align\"\ntable Message {}",
        .line = 1,
        .column = 1,
        .message = "cannot redeclare built-in attribute 'force_align'",
    },
    .{
        .source = "table Message {\n    label:string (custom_flag);\n}",
        .line = 2,
        .column = 19,
        .message = "attribute 'custom_flag' must be declared first",
    },
};

const malformed_schema_sources = [_][]const u8{
    "table T { x:Missing; }",
    "struct S { self:S; }",
    "struct S { text:string; }",
    "table T { x:int (required); }",
    "table T { x:byte = 128; }",
    "table T { x:long = -9223372036854775809; }",
    "table T { x:ulong = 18446744073709551616; }",
    "table T { x:int (id:0); y:int; }",
    "table T { x:int (id:1); }",
    "table T { x:int (id:18446744073709551615); }",
    "table T { x:int (id); }",
    "table T { x:int (required:true); }",
    "table T { x:int (deprecated:false); }",
    "table T { x:int (key:true); }",
    "struct S { x:[int:0]; }",
    "struct S { x:[int:-1]; }",
    "struct S { x:[int:65536]; }",
    "table T { x:[int:3]; }",
    "struct S { x:int; } root_type S;",
    "union U { string }",
    "table Item {} union U { Item } table T { u:U; u_type:int; }",
    "enum E:byte { A=1 } table T { x:E; }",
    "table T {} file_identifier \"LONGER\";",
    "table T {} file_identifier \"ABC\";",
    "table T { x:int }",
};

// Keep parser tests in this file; run `zig build test` from Flatzz.
test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\namespace Demo;
        \\enum Status:ubyte { Unknown, Ready }
        \\struct Point { x:float; y:float; }
        \\struct Batch { points:[Point:2]; flags:[bool:3]; }
        \\table Event { status:Status = Ready; }
        \\union Payload { Event, Position:Point, Text:string }
        \\table Root { current:Payload; history:[Payload]; temperature:float = null; batch:Batch; }
        \\root_type Root;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqualStrings("Demo.Root", root.name);
    const batch = try testObject(schema, "Demo.Batch");
    try std.testing.expectEqual(@as(i32, 20), batch.bytesize);
    try std.testing.expectEqual(@as(i32, 4), batch.minalign);
    try std.testing.expectEqual(@as(u16, 16), (try testField(batch, "flags")).offset);
    try std.testing.expectEqual(@as(u16, 0), (try testField(root, "current_type")).id);
    try std.testing.expectEqual(@as(u16, 1), (try testField(root, "current")).id);
    try std.testing.expectEqual(@as(u16, 2), (try testField(root, "history_type")).id);
    try std.testing.expectEqual(@as(u16, 3), (try testField(root, "history")).id);
    try std.testing.expectEqual(
        BaseType.UType,
        (try testField(root, "current_type")).type.base_type,
    );
    try std.testing.expectEqual(BaseType.UType, (try testField(root, "history_type")).type.element);
    try std.testing.expect((try testField(root, "temperature")).optional);
    try std.testing.expectEqual(@as(u64, 7), @as(u64, @bitCast(schema.advanced_features)));
    try std.testing.expectEqual(
        @as(i64, 1),
        (try testField(try testObject(schema, "Demo.Event"), "status")).default_integer,
    );
}

test "nested namespace lookup retains nearest parent global and qualified references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\table Global {}
        \\namespace Parent;
        \\table Shared {}
        \\table Ancestor {}
        \\namespace Parent.Child;
        \\table Shared {}
        \\table Reading {
        \\    nearest:Shared;
        \\    parent:Ancestor;
        \\    global:Global;
        \\    qualified:Parent.Shared;
        \\}
        \\root_type Reading;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqualStrings("Parent.Child.Reading", root.name);
    const nearest = try testField(root, "nearest");
    const ancestor = try testField(root, "parent");
    const global = try testField(root, "global");
    const qualified = try testField(root, "qualified");
    try std.testing.expectEqualStrings(
        "Parent.Child.Shared",
        schema.objects[@intCast(nearest.type.index)].name,
    );
    try std.testing.expectEqualStrings(
        "Parent.Ancestor",
        schema.objects[@intCast(ancestor.type.index)].name,
    );
    try std.testing.expectEqualStrings("Global", schema.objects[@intCast(global.type.index)].name);
    try std.testing.expectEqualStrings(
        "Parent.Shared",
        schema.objects[@intCast(qualified.type.index)].name,
    );
}

test "wire padding survives sorting, explicit IDs include union discriminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\struct Padded { z:ubyte; a:ulong; m:ushort; }
        \\table Item { next:Item; }
        \\union Choice { Item }
        \\table Root { choice:Choice (id:2); value:Padded (id:0); }
        \\root_type Root;
    );
    const padded = try testObject(schema, "Padded");
    try std.testing.expectEqualStrings("a", padded.fields[0].name);
    try std.testing.expectEqual(@as(u16, 1), padded.fields[0].id);
    try std.testing.expectEqual(@as(u16, 8), padded.fields[0].offset);
    try std.testing.expectEqual(@as(u16, 7), (try testField(padded, "z")).padding);
    try std.testing.expectEqual(@as(u16, 6), (try testField(padded, "m")).padding);
    try std.testing.expectEqual(@as(i32, 24), padded.bytesize);
    const root = schema.root_table.?;
    try std.testing.expectEqual(@as(u16, 0), (try testField(root, "value")).id);
    try std.testing.expectEqual(@as(u16, 1), (try testField(root, "choice_type")).id);
    try std.testing.expectEqual(@as(u16, 8), (try testField(root, "choice")).offset);
}

test "defaults preserve signed and unsigned limits and floating literal metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\enum Wide:ulong { Zero=0, Max=18446744073709551615 }
        \\table T {
        \\    low:long = -9223372036854775808;
        \\    high:ulong = 18446744073709551615;
        \\    wide:Wide = "Wide.Max";
        \\    fraction:float = "0.1";
        \\    flag:bool = "true";
        \\    optional:int = "null";
        \\}
        \\root_type T;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqual(std.math.minInt(i64), (try testField(root, "low")).default_integer);
    try std.testing.expectEqual(@as(i64, -1), (try testField(root, "high")).default_integer);
    try std.testing.expectEqual(@as(i64, -1), (try testField(root, "wide")).default_integer);
    try std.testing.expectEqual(@as(f64, 0.1), (try testField(root, "fraction")).default_real);
    try std.testing.expectEqual(@as(i64, 1), (try testField(root, "flag")).default_integer);
    try std.testing.expect((try testField(root, "optional")).optional);
}

test parseWithOptions {
    const loader = struct {
        fn load(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            requested: []const u8,
        ) anyerror!Source {
            if (!std.mem.endsWith(u8, requested, "shared.fbs")) return error.NotFound;
            return .{
                .name = "shared.fbs",
                .text = "namespace Shared; table Item {} root_type Item; file_identifier \"SHRD\";",
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parseWithOptions(arena.allocator(),
        \\include "shared.fbs";
        \\include "./shared.fbs";
        \\table Root { value:Shared.Item; }
        \\root_type Root;
    , .{ .include_loader = loader.load });
    try std.testing.expectEqual(@as(usize, 2), schema.objects.len);
    try std.testing.expectEqualStrings("Root", schema.root_table.?.name);
    try std.testing.expectEqual(@as(?[]const u8, null), schema.file_ident);
    const item = try testField(schema.root_table.?, "value");
    try std.testing.expectEqualStrings(
        "Shared.Item",
        schema.objects[@intCast(item.type.index)].name,
    );
}

test "source ownership and error diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = "table Owned { value:uint; } root_type Owned;".*;
    const schema = try parse(arena.allocator(), &source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("Owned", schema.root_table.?.name);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSchema, parseWithOptions(
        arena.allocator(),
        "table T {\nvalue:Missing;\n}",
        .{ .filename = "bad.fbs", .diagnostic = &diagnostic },
    ));
    try std.testing.expectEqualStrings("bad.fbs", diagnostic.filename);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expect(diagnostic.message.len != 0);
}

test "attribute classification preserves validation order and diagnostics" {
    for (attribute_diagnostics) |expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidSchema, parseWithOptions(
            arena.allocator(),
            expected.source,
            .{ .filename = "attributes.fbs", .diagnostic = &diagnostic },
        ));
        try std.testing.expectEqualStrings("attributes.fbs", diagnostic.filename);
        try std.testing.expectEqual(expected.line, diagnostic.line);
        try std.testing.expectEqual(expected.column, diagnostic.column);
        try std.testing.expectEqualStrings(expected.message, diagnostic.message);
    }
}

test "malformed schemas fail without accepting incomplete metadata" {
    for (malformed_schema_sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidSchema, parse(arena.allocator(), source));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedFeature,
        parse(arena.allocator(), "struct S (force_align:16) { x:int; }"),
    );
    try std.testing.expectError(
        error.IncludeNotFound,
        parse(arena.allocator(), "include \"missing.fbs\";"),
    );
    try std.testing.expectError(
        error.DepthLimitExceeded,
        parseWithOptions(
            arena.allocator(),
            "struct A { b:B; } struct B { x:int; }",
            .{ .max_depth = 1 },
        ),
    );
}

test "fixed arrays accept the maximum wire length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\struct Bytes { data:[ubyte:65535]; }
        \\table Root { bytes:Bytes; }
        \\root_type Root;
        \\file_identifier "TEST";
    );
    const bytes = try testObject(schema, "Bytes");
    try std.testing.expectEqual(@as(u16, 65535), (try testField(bytes, "data")).type.fixed_length);
    try std.testing.expectEqual(@as(i32, 65535), bytes.bytesize);
    try std.testing.expectEqualStrings("TEST", schema.file_ident.?);
}

fn testObject(schema: reflection.Schema, name: []const u8) !*const reflection.Object {
    for (schema.objects) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.TestObjectNotFound;
}
fn testField(object: *const reflection.Object, name: []const u8) !*const reflection.Field {
    for (object.fields) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.TestFieldNotFound;
}
