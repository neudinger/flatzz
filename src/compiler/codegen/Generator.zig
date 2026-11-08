//! Reflection-to-Zig declaration lowering with borrowed scratch storage.
//! Dynamic descriptions and escaped names share scratch storage until AST finalization.

const std = @import("std");
const flatzz = @import("flatzz");
const zast = @import("zast");
const compiler = @import("flatzz_compiler");
const Syntax = @import("Syntax.zig");

const reflection = compiler.reflection;
const BaseType = reflection.BaseType;
const Expression = zast.Expression;
const Member = zast.StructDeclaration.Member;
const Allocator = std.mem.Allocator;
const Generator = @This();

const KindField = enum { scalar, structure, table, vector };

const reserved_module_names = [_][]const u8{
    "runtime", "types", "file_identifier", "file_extension",
};

const reserved_member_names = [_][]const u8{
    "runtime", "types", "fields", "Schema", "Layout", "WriteOptions",
};

const schema_aliases = [_][]const u8{
    "Field", "View",   "serialize",     "serializeAlloc",
    "read",  "update", "borrowMutable", "verify",
};

syntax: Syntax,
schema: reflection.Schema,
object_names: []const []const u8 = &.{},
enum_names: []const []const u8 = &.{},

fn identifier(self: *Generator, name: []const u8) ![]const u8 {
    if (name.len == 0) return error.InvalidSchema;
    return self.syntax.allocator.print("{f}", .{std.zig.fmtId(name)});
}

fn runtimeCall(
    self: *Generator,
    comptime name: std.meta.DeclEnum(flatzz),
    arguments: []const Expression,
) !Expression {
    return self.syntax.call(
        try self.syntax.access(Syntax.identifier("runtime"), @tagName(name)),
        arguments,
    );
}

fn kind(self: *Generator, selected: KindField, value: Expression) !Expression {
    return self.syntax.record(&.{.{ .name = @tagName(selected), .value = value }});
}

fn appendBinding(
    self: *Generator,
    members: *std.ArrayList(Member),
    name: []const u8,
    value: Expression,
) !void {
    return members.append(self.syntax.allocator, .{
        .declaration = .{
            .name = name,
            .declaration = .{ .value = value },
            .visibility = .public,
        },
    });
}

pub fn prepareNames(self: *Generator) !void {
    var common: ?[]const u8 = null;
    for (self.schema.objects) |object_value| common = commonNamespace(
        common,
        object_value.name,
    );
    for (self.schema.enums) |enum_value| common = commonNamespace(common, enum_value.name);
    const prefix = common orelse "";
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (reserved_module_names) |name| try names.put(self.syntax.allocator, name, {});
    const objects = try self.syntax.allocator.alloc([]const u8, self.schema.objects.len);
    const enums = try self.syntax.allocator.alloc([]const u8, self.schema.enums.len);
    inline for (.{ .{ self.schema.objects, objects }, .{ self.schema.enums, enums } }) |group| {
        for (group[0], group[1]) |declaration, *name| {
            const raw_name = declaration.name[if (prefix.len == 0) 0 else prefix.len + 1..];
            if ((try names.getOrPut(
                self.syntax.allocator,
                raw_name,
            )).found_existing) return error.NameCollision;
            name.* = try self.identifier(raw_name);
        }
    }
    self.object_names = objects;
    self.enum_names = enums;
}

fn objectIndex(self: *Generator, index: i32) !usize {
    const result = std.math.cast(usize, index) orelse return error.InvalidSchema;
    if (result >= self.schema.objects.len) return error.InvalidSchema;
    return result;
}

fn enumIndex(self: *Generator, index: i32, is_union: bool) !usize {
    const result = std.math.cast(usize, index) orelse return error.InvalidSchema;
    if (result >= self.schema.enums.len or self.schema.enums[result].is_union != is_union)
        return error.InvalidSchema;
    return result;
}

fn named(self: *Generator, name: []const u8) !Expression {
    return self.syntax.access(Syntax.identifier("types"), name);
}

fn layout(self: *Generator, index: i32) !Expression {
    const object_index = try self.objectIndex(index);
    if (!self.schema.objects[object_index].is_struct) return error.InvalidSchema;
    return self.syntax.access(try self.named(self.object_names[object_index]), "Layout");
}

fn scalarType(self: *Generator, field_type: reflection.Type) !Expression {
    const primitive = scalarName(field_type.base_type) orelse return error.UnsupportedFeature;
    if (field_type.index == -1) return Syntax.identifier(primitive);
    const index = try self.enumIndex(field_type.index, false);
    if (self.schema.enums[index].underlying_type.base_type != field_type.base_type)
        return error.InvalidSchema;
    return self.named(self.enum_names[index]);
}

fn integer(self: *Generator, value: i64, base: BaseType) !Expression {
    const syntax = self.syntax;
    const name = scalarName(base) orelse return error.UnsupportedFeature;
    if (name[0] != 'i' and name[0] != 'u') return error.InvalidSchema;
    const bits: u7 = @intCast(base.byteSize() * 8);
    const unsigned = base.isUnsigned();
    const integer_value: i128 = if (base == .ULong) @as(u64, @bitCast(value)) else value;
    const bound = @as(i128, 1) << @intCast(bits - @intFromBool(!unsigned));
    const minimum: i128 = if (unsigned) 0 else -bound;
    if (integer_value < minimum or integer_value >= bound) return error.InvalidSchema;
    return if (integer_value < 0) .{
        .negate = try syntax.store(try syntax.number(-integer_value)),
    } else syntax.number(integer_value);
}

fn defaultValue(self: *Generator, field: reflection.Field) !Expression {
    const syntax = self.syntax;
    if (field.optional) return Syntax.identifier("null");
    const field_type = field.type.*;
    if (field_type.index >= 0) {
        _ = try self.enumIndex(field_type.index, false);
        return syntax.builtin(
            "@fromBackingInt",
            &.{try self.integer(field.default_integer, field_type.base_type)},
        );
    }
    return switch (field_type.base_type) {
        .Bool => if (field.default_integer == 0 or field.default_integer == 1)
            Syntax.identifier(if (field.default_integer == 1) "true" else "false")
        else
            error.InvalidSchema,
        .Float, .Double => float_default_blk: {
            const bits: u64 = if (field_type.base_type == .Float)
                @as(u32, @bitCast(@as(f32, @floatCast(field.default_real))))
            else
                @bitCast(field.default_real);
            if (bits == 0) break :float_default_blk try syntax.number(@as(u8, 0));
            // Bit patterns preserve negative zero, infinities and NaNs without
            // requiring a float-literal extension to Zast's expression API.
            break :float_default_blk try syntax.builtin("@bitCast", &.{
                try syntax.builtin("@as", &.{
                    Syntax.identifier(if (field_type.base_type == .Float) "u32" else "u64"),
                    try syntax.number(bits),
                }),
            });
        },
        else => self.integer(field.default_integer, field_type.base_type),
    };
}

pub fn enumeration(self: *Generator, value: reflection.Enum) !Expression {
    const syntax = self.syntax;
    const backing = if (value.is_union) "u8" else scalarName(
        value.underlying_type.base_type,
    ) orelse return error.UnsupportedFeature;
    if (value.is_union and value.underlying_type.base_type != .UType and
        value.underlying_type.base_type != .UByte) return error.UnsupportedFeature;
    if (backing[0] != 'i' and backing[0] != 'u') return error.UnsupportedFeature;
    const width: u7 = @intCast(value.underlying_type.base_type.byteSize() * 8);
    const fields = try syntax.allocator.alloc(zast.Field, value.values.len);
    const variants = try syntax.allocator.alloc(
        Expression.InitializerField,
        if (value.is_union) value.values.len else 0,
    );
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var numbers: std.AutoHashMapUnmanaged(i64, void) = .empty;
    var has_none = false;
    for (value.values, fields, 0..) |item, *field, index| {
        const tag = try snakeCase(syntax.allocator, item.name);
        if (std.mem.eql(u8, tag, "_") or (try names.getOrPut(
            syntax.allocator,
            tag,
        )).found_existing) return error.NameCollision;
        if ((try numbers.getOrPut(
            syntax.allocator,
            item.value,
        )).found_existing) return error.UnsupportedFeature;
        const name = try self.identifier(tag);
        field.* = .{
            .name = name,
            .value = try self.integer(
                item.value,
                if (value.is_union) .UByte else value.underlying_type.base_type,
            ),
        };
        if (value.is_union) {
            const payload = item.union_type orelse return error.InvalidSchema;
            if (payload.base_type == .None) {
                if (item.value != 0 or !std.mem.eql(u8, tag, "none"))
                    return error.InvalidSchema;
                has_none = true;
            }
            variants[index] = .{ .name = name, .value = try self.unionPayload(payload) };
        }
    }
    const description = try syntax.store(zast.EnumDeclaration{
        .backing_type = backing,
        .fields = fields,
        .non_exhaustive = !value.is_union and @as(
            u128,
            value.values.len,
        ) < (@as(u128, 1) << width),
    });
    if (!value.is_union) return Expression.fromType(description);
    if (!has_none) return error.InvalidSchema;
    return self.runtimeCall(
        .Union,
        &.{ Expression.fromType(description), try syntax.record(variants) },
    );
}

fn unionPayload(self: *Generator, payload: *const reflection.Type) !Expression {
    return switch (payload.base_type) {
        .None => .{ .enum_literal = "none" },
        .String => .{ .enum_literal = "string" },
        .Obj => union_payload_blk: {
            const object_index = try self.objectIndex(payload.index);
            break :union_payload_blk if (self.schema.objects[object_index].is_struct)
                try self.kind(.structure, try self.layout(payload.index))
            else
                try self.kind(.table, try self.named(self.object_names[object_index]));
        },
        else => error.UnsupportedFeature,
    };
}

fn nativeType(self: *Generator, field_type: reflection.Type) anyerror!Expression {
    const syntax = self.syntax;
    return switch (field_type.base_type) {
        .String => syntax.slice(Syntax.identifier("u8")),
        .Obj => native_object_blk: {
            const object_index = try self.objectIndex(field_type.index);
            const child = try self.named(self.object_names[object_index]);
            break :native_object_blk if (self.schema.objects[object_index].is_struct)
                child
            else
                .{ .pointer_type = .{
                    .child_type = try syntax.store(child),
                    .is_const = true,
                } };
        },
        .Union => syntax.access(
            try self.named(self.enum_names[try self.enumIndex(field_type.index, true)]),
            "Value",
        ),
        .Vector, .Array => native_sequence_blk: {
            if (scalarName(field_type.element) == null and field_type.element != .Obj and
                !(field_type.base_type == .Vector and
                    (field_type.element == .String or field_type.element == .Union)))
                return error.UnsupportedFeature;
            if (field_type.base_type == .Array and field_type.fixed_length == 0)
                return error.InvalidSchema;
            var element = field_type;
            element.base_type = field_type.element;
            const child = try self.nativeType(element);
            break :native_sequence_blk if (field_type.base_type == .Vector)
                try syntax.slice(child)
            else
                .{ .array_type = .{
                    .child_type = try syntax.store(child),
                    .length = try syntax.store(try syntax.number(field_type.fixed_length)),
                } };
        },
        else => self.scalarType(field_type),
    };
}

fn descriptor(self: *Generator, field: reflection.Field, structure: bool) !Expression {
    const syntax = self.syntax;
    const field_type = field.type.*;
    const position = try syntax.number(if (structure) field.offset else field.id);
    if (structure) return switch (field_type.base_type) {
        .Obj => self.runtimeCall(
            .StructMember,
            &.{ try self.layout(field_type.index), position },
        ),
        .Array => self.runtimeCall(.ArrayMember, &.{
            try self.kind(
                if (field_type.element == .Obj) .structure else .scalar,
                if (field_type.element == .Obj)
                    try self.layout(field_type.index)
                else
                    try self.scalarType(
                        .{ .base_type = field_type.element, .index = field_type.index },
                    ),
            ),
            try syntax.number(field_type.fixed_length),
            position,
        }),
        else => self.runtimeCall(
            .ScalarMember,
            &.{ try self.scalarType(field_type), position },
        ),
    };
    const options = try syntax.record(
        if (field.required) &.{
            .{ .name = "required", .value = Syntax.identifier("true") },
        } else &.{},
    );
    return switch (field_type.base_type) {
        .Union => self.runtimeCall(.UnionField, &.{
            try self.named(self.enum_names[try self.enumIndex(field_type.index, true)]),
            try self.unionIds(field),
            options,
        }),
        .Vector => if (field_type.element == .Union) self.runtimeCall(.UnionVectorField, &.{
            try self.named(self.enum_names[try self.enumIndex(field_type.index, true)]),
            try self.unionIds(field),
            options,
        }) else self.runtimeCall(
            .ReferenceField,
            &.{ position, try self.kind(.vector, try self.codec(field_type)), options },
        ),
        .String => self.runtimeCall(
            .ReferenceField,
            &.{ position, .{ .enum_literal = "string" }, options },
        ),
        .Obj => object_descriptor_blk: {
            const object_index = try self.objectIndex(field_type.index);
            break :object_descriptor_blk if (self.schema.objects[object_index].is_struct)
                self.runtimeCall(
                    .StructField,
                    &.{ try self.layout(field_type.index), position, options },
                )
            else
                self.runtimeCall(
                    .ReferenceField,
                    &.{
                        position,
                        try self.kind(.table, try self.named(self.object_names[object_index])),
                        options,
                    },
                );
        },
        else => self.runtimeCall(.ScalarField, &.{
            if (field.optional) try syntax.optional(
                try self.scalarType(field_type),
            ) else try self.scalarType(field_type),
            position,
            try self.defaultValue(field),
        }),
    };
}

fn unionIds(self: *Generator, field: reflection.Field) !Expression {
    const syntax = self.syntax;
    if (field.id == 0) return error.InvalidSchema;
    return syntax.record(&.{
        .{ .name = "tag", .value = try syntax.number(field.id - 1) },
        .{ .name = "value", .value = try syntax.number(field.id) },
    });
}

fn codec(self: *Generator, field_type: reflection.Type) !Expression {
    return switch (field_type.element) {
        .String => self.syntax.access(Syntax.identifier("runtime"), "StringCodec"),
        .Obj => object_codec_blk: {
            const object_index = try self.objectIndex(field_type.index);
            break :object_codec_blk if (self.schema.objects[object_index].is_struct)
                self.runtimeCall(.StructCodec, &.{try self.layout(field_type.index)})
            else
                self.runtimeCall(
                    .TableCodec,
                    &.{try self.named(self.object_names[object_index])},
                );
        },
        else => self.runtimeCall(
            .ScalarCodec,
            &.{
                try self.scalarType(
                    .{ .base_type = field_type.element, .index = field_type.index },
                ),
            },
        ),
    };
}

// Append the native member before constructing the descriptor returned to the caller.
fn appendField(
    self: *Generator,
    field: *const reflection.Field,
    structure: bool,
    members: *std.ArrayList(Member),
) !Expression.InitializerField {
    const syntax = self.syntax;
    const field_type = field.type;
    const name = try self.identifier(field.name);
    const fixed = scalarName(field_type.base_type) != null;
    var native = try self.nativeType(field_type.*);
    if (!structure and field_type.base_type != .Union and (!fixed or field.optional))
        native = try syntax.optional(native);
    try members.append(syntax.allocator, .{ .field = .{
        .name = name,
        .type_expression = native,
        .value = if (structure) null else if (fixed)
            try syntax.access(
                try syntax.access(Syntax.identifier("fields"), name),
                "default",
            )
        else if (field_type.base_type == .Union) .{
            .enum_literal = "none",
        } else Syntax.identifier("null"),
    } });
    return .{ .name = name, .value = try self.descriptor(field.*, structure) };
}

pub fn object(self: *Generator, value: reflection.Object) !zast.StructDeclaration {
    const syntax = self.syntax;
    // Order borrowed records without copying or mutating the caller's field metadata.
    const ordered = try syntax.allocator.alloc(*const reflection.Field, value.fields.len);
    for (value.fields, ordered) |*field, *destination| destination.* = field;
    std.mem.sort(*const reflection.Field, ordered, {}, struct {
        fn less(_: void, left: *const reflection.Field, right: *const reflection.Field) bool {
            return left.id < right.id;
        }
    }.less);
    var members: std.ArrayList(Member) = .empty;
    var descriptors: std.ArrayList(Expression.InitializerField) = .empty;
    var member_names: std.StringHashMapUnmanaged(void) = .empty;
    for (ordered, 0..) |field, field_index| {
        if (field_index != 0 and ordered[field_index - 1].id == field.id)
            return error.InvalidSchema;
        if (field.offset64 or field.type.base_type == .Vector64)
            return error.UnsupportedFeature;
        const field_type = field.type;
        if (isTag(field.*)) {
            if (value.is_struct or field_index + 1 >= ordered.len) return error.InvalidSchema;
            const payload = ordered[field_index + 1];
            if (!isUnion(payload.*) or payload.id == 0 or payload.id - 1 != field.id or
                payload.type.index != field_type.index or
                payload.deprecated != field.deprecated or
                (payload.type.base_type == .Vector) != (field_type.base_type == .Vector))
                return error.InvalidSchema;
            continue;
        }
        if (isUnion(field.*) and (field_index == 0 or !isTag(
            ordered[field_index - 1].*,
        ))) return error.InvalidSchema;
        if (field.deprecated) continue;
        for (reserved_member_names ++ schema_aliases) |reserved| {
            if (std.mem.eql(u8, field.name, reserved)) return error.NameCollision;
        }
        if ((try member_names.getOrPut(
            syntax.allocator,
            field.name,
        )).found_existing) return error.NameCollision;
        try descriptors.append(
            syntax.allocator,
            try self.appendField(field, value.is_struct, &members),
        );
    }
    if (value.is_struct) {
        if (value.bytesize <= 0 or value.minalign <= 0) return error.InvalidSchema;
        try self.appendBinding(&members, "Layout", try self.runtimeCall(
            .StructLayout,
            &.{
                try syntax.builtin("@This", &.{}),
                try syntax.record(&.{
                    .{ .name = "size", .value = try syntax.number(value.bytesize) },
                    .{ .name = "alignment", .value = try syntax.number(value.minalign) },
                }),
                try syntax.record(descriptors.items),
            },
        ));
    } else {
        try self.appendBinding(&members, "fields", try syntax.record(descriptors.items));
        try self.appendBinding(&members, "Schema", try self.runtimeCall(
            .Schema,
            &.{ try syntax.builtin("@This", &.{}), Syntax.identifier("fields") },
        ));
        for (schema_aliases) |alias| {
            try self.appendBinding(
                &members,
                alias,
                try syntax.access(Syntax.identifier("Schema"), alias),
            );
        }
        try self.appendBinding(
            &members,
            "WriteOptions",
            try syntax.access(Syntax.identifier("runtime"), "WriteOptions"),
        );
    }
    return .{ .members = members.items };
}

fn commonNamespace(existing: ?[]const u8, name: []const u8) []const u8 {
    const namespace = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse 0];
    var result = existing orelse return namespace;
    while (result.len != 0 and !(std.mem.eql(u8, result, namespace) or
        (std.mem.startsWith(
            u8,
            namespace,
            result,
        ) and namespace.len > result.len and namespace[result.len] == '.')))
        result = result[0 .. std.mem.lastIndexOfScalar(u8, result, '.') orelse 0];
    return result;
}

fn snakeCase(allocator: Allocator, name: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (name, 0..) |byte, index| {
        if (std.ascii.isUpper(byte) and index > 0 and name[index - 1] != '_' and
            (std.ascii.isLower(name[index - 1]) or std.ascii.isDigit(name[index - 1]) or
                (index + 1 < name.len and std.ascii.isLower(name[index + 1])))) try result.append(
            allocator,
            '_',
        );
        try result.append(allocator, std.ascii.toLower(byte));
    }
    return result.items;
}

fn isTag(field: reflection.Field) bool {
    return field.type.base_type == .UType or
        (field.type.base_type == .Vector and field.type.element == .UType);
}

fn isUnion(field: reflection.Field) bool {
    return field.type.base_type == .Union or
        (field.type.base_type == .Vector and field.type.element == .Union);
}

fn scalarName(base: BaseType) ?[]const u8 {
    return switch (base) {
        .Bool => "bool",
        .Byte => "i8",
        .UByte => "u8",
        .Short => "i16",
        .UShort => "u16",
        .Int => "i32",
        .UInt => "u32",
        .Long => "i64",
        .ULong => "u64",
        .Float => "f32",
        .Double => "f64",
        else => null,
    };
}
