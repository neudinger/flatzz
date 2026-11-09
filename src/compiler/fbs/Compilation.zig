//! Resolve arena-backed FBS declarations into sorted metadata with stable indices.
//! Owns source copies, symbols and unresolved declarations in the caller arena.
//! Loading a source creates a Parser; includes return directly to load.
//! Internal lifecycle: initialize options, load the main source and its includes,
//! then finish once. All allocating operations share the caller's arena, which
//! owns partial state on failure and the referenced output storage on success.

const std = @import("std");
const flatzz = @import("flatzz");
const reflection = @import("../reflection.zig");
const frontend = @import("../parser.zig");
const model = @import("model.zig");
const Parser = @import("Parser.zig");

const Compiler = @This();
const wire = flatzz.wire;
const Allocator = std.mem.Allocator;
const BaseType = reflection.BaseType;
const Error = frontend.Error;
const Options = frontend.Options;
const Source = frontend.Source;
const Location = model.Location;
const Atom = model.Atom;
const TypeRef = model.TypeRef;
const FieldDef = model.FieldDef;
const ObjectDef = model.ObjectDef;
const EnumDef = model.EnumDef;
const Symbol = model.Symbol;
const Root = model.Root;
const attribute = model.attribute;
const qualify = model.qualify;

/// Borrowed loader/diagnostic settings shared with every source parser.
options: Options,
/// Arena-backed objects in parse order; finish sorts them and rebuilds symbols.
objects: std.ArrayList(ObjectDef) = .empty,
/// Arena-backed enum/union declarations; final order determines type indices.
enums: std.ArrayList(EnumDef) = .empty,
/// Deferred roots, including included declarations that must still name valid tables.
roots: std.ArrayList(Root) = .empty,
/// Source identities and direct include lists, sorted by filename at finish.
files: std.ArrayList(reflection.SchemaFile) = .empty,
/// Borrowed qualified names mapped to the current declaration-array indices.
symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
/// Canonical source identities marked before parsing to suppress include cycles.
loaded: std.StringHashMapUnmanaged(void) = .empty,
/// Custom attribute names available to all sources in this compilation.
custom_attributes: std.StringHashMapUnmanaged(void) = .empty,
/// Main-source application identifier; copied source metadata outlives the parser cursor.
file_ident: ?[]const u8 = null,
/// Main-source application extension, or null when absent.
file_ext: ?[]const u8 = null,
/// Requirements accumulated while resolving optional scalars, arrays, and unions.
features: reflection.AdvancedFeatures = .{},

/// Return a failure and, when requested, store its source location and formatted message.
/// Formatting uses the shared arena; its allocation failure replaces the original error
/// with OutOfMemory. This does not roll back compiler state or earlier allocations.
pub fn fail(
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

/// Return InvalidSchema through the same optional diagnostic path as fail.
pub fn invalid(
    self: *Compiler,
    allocator: Allocator,
    location: Location,
    comptime message: []const u8,
) Error {
    return self.fail(allocator, location, error.InvalidSchema, message, .{});
}

/// Deduplicate a canonical source name, copy its name/text, and parse its declarations.
/// New sources consume include depth and are marked before parsing to break cycles.
/// Includes recurse into this same state. Errors retain partial arena-backed state;
/// public callers discard the compilation and release their arena rather than retrying it.
pub fn load(
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

/// Borrow a qualified name as a symbol key; duplicate declarations return InvalidSchema.
/// Indices identify the current object/enum arrays and are rebuilt after final sorting.
pub fn register(
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
    field_type.base_size = field_type.base_type.byteSize();
    field_type.element_size = field_type.element.byteSize();
}

/// Sort declarations, resolve names/defaults, lay out structs, and emit borrowed metadata.
/// Call after all sources load. Output arrays and referenced records use the same arena;
/// no ownership is transferred away from it. Errors can leave sorting and resolution
/// partly applied, so retain diagnostics and discard the failed compilation.
pub fn finish(self: *Compiler, allocator: Allocator) Error!reflection.Schema {
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
    const scalar = field_type.base_type.isScalar();
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
            field.value.default_real = try self.floatDefault(
                allocator,
                field_type.base_type,
                value,
            );
        } else {
            field.value.default_integer = try self.integerDefault(
                allocator,
                field_type,
                object.namespace,
                value,
            );
        }
    }
    try self.checkEnumDefault(allocator, field);
}

fn floatDefault(
    self: *Compiler,
    allocator: Allocator,
    base: BaseType,
    value: Atom,
) Error!f64 {
    if (std.mem.indexOfScalar(u8, value.text, '_') != null)
        return self.invalid(allocator, value.location, "invalid floating-point default");
    const number = std.fmt.parseFloat(f64, value.text) catch
        return self.invalid(allocator, value.location, "invalid floating-point default");
    if (base == .Float) {
        const narrowed: f32 = @floatCast(number);
        if (std.math.isFinite(number) and !std.math.isFinite(narrowed))
            return self.invalid(allocator, value.location, "default is outside float32 range");
    }
    // Reflection carries the f64 parsing of the literal even for
    // float32 fields. The generated field type performs narrowing.
    return number;
}

fn integerDefault(
    self: *Compiler,
    allocator: Allocator,
    field_type: *const reflection.Type,
    namespace: []const u8,
    value: Atom,
) Error!i64 {
    if (field_type.base_type == .Bool) {
        if (std.mem.eql(u8, value.text, "true")) return 1;
        if (std.mem.eql(u8, value.text, "false")) return 0;
        return self.integerBits(
            allocator,
            try self.integer(allocator, value.text, value.location),
            .Bool,
            value.location,
        );
    }
    const named_default = value.text.len != 0 and
        (std.ascii.isAlphabetic(value.text[0]) or value.text[0] == '_');
    const number: i128 = if (named_default and field_type.index >= 0) enum_value_blk: {
        const enumeration = &self.enums.items[@intCast(field_type.index)];
        var member = value.text;
        if (std.mem.lastIndexOfScalar(u8, member, '.')) |dot| {
            const symbol = try self.lookup(
                allocator,
                namespace,
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
        for (enumeration.values) |item| {
            if (std.mem.eql(u8, item.value.name, member))
                break :enum_value_blk if (field_type.base_type.isUnsigned()) @as(
                    u64,
                    @bitCast(item.value.value),
                ) else item.value.value;
        }
        return self.fail(
            allocator,
            value.location,
            error.InvalidSchema,
            "unknown enum value '{s}'",
            .{member},
        );
    } else try self.integer(allocator, value.text, value.location);
    return self.integerBits(allocator, number, field_type.base_type, value.location);
}

fn checkEnumDefault(self: *Compiler, allocator: Allocator, field: *const FieldDef) Error!void {
    const enum_index = field.type_ref.value.index;
    if (enum_index < 0) return;
    const enumeration = self.enums.items[@intCast(enum_index)];
    for (enumeration.values) |item|
        if (item.value.value == field.value.default_integer) return;
    return self.invalid(
        allocator,
        field.location,
        "enum default must be a declared enum value",
    );
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
    if (base.isScalar() or
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
        var member_size: u64 = base.byteSize();
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

/// Parse a signed decimal or hexadecimal spelling into an i128 intermediate.
/// Accepts a leading sign and case-insensitive 0x prefix; separators and invalid digits
/// return InvalidSchema with a diagnostic. The magnitude must fit the signed intermediate.
pub fn integer(
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
    const hexadecimal = std.ascii.startsWithIgnoreCase(digits, "0x");
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

/// Range-check an integer against a scalar wire type and retain its bits in i64 metadata.
/// Callers supply an integer/bool BaseType. Unsigned 64-bit values preserve their bit
/// pattern through bit-casting; out-of-range values return InvalidSchema.
pub fn integerBits(
    self: *Compiler,
    allocator: Allocator,
    value: i128,
    base: BaseType,
    location: Location,
) Error!i64 {
    const bits: u7 = @intCast(base.byteSize() * 8);
    const unsigned = base.isUnsigned();
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

fn lessField(_: void, left: reflection.Field, right: reflection.Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn lessFile(_: void, left: reflection.SchemaFile, right: reflection.SchemaFile) bool {
    return std.mem.lessThan(u8, left.filename, right.filename);
}
