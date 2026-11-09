//! One source cursor and FBS grammar; includes share the enclosing compilation.
//! Source slices and unresolved declarations retain the caller arena lifetime.
//! Allocation and diagnostics go through the same compiler state during recursion.
//! Compilation.load initializes this cursor and advances once before declarations.
//! This internal grammar records unresolved types/defaults; Compilation.finish
//! later resolves names, validates semantics, and computes wire layout.

const std = @import("std");
const flatzz = @import("flatzz");
const reflection = @import("../reflection.zig");
const frontend = @import("../parser.zig");
const model = @import("model.zig");
const Compiler = @import("Compilation.zig");

const Parser = @This();
const wire = flatzz.wire;
const Allocator = std.mem.Allocator;
const BaseType = reflection.BaseType;
const Error = frontend.Error;
const Source = frontend.Source;
const Location = model.Location;
const TokenKind = model.TokenKind;
const Token = model.Token;
const Atom = model.Atom;
const Attributes = model.Attributes;
const TypeRef = model.TypeRef;
const FieldDef = model.FieldDef;
const EnumMember = model.EnumMember;
const EnumValueDef = model.EnumValueDef;
const BuiltinAttribute = model.BuiltinAttribute;
const attribute = model.attribute;
const qualify = model.qualify;

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

/// Stable enclosing compilation; include parsers append into this same state.
compiler: *Compiler,
/// Source identity and complete text copied by Compilation.load.
source: Source,
/// Include depth, with zero identifying the main source load.
depth: usize,
/// Whether root/identifier/extension declarations select the compilation's output metadata.
main: bool,
/// Byte cursor immediately after the current raw token or skipped trivia.
position: usize = 0,
/// Current token borrowing source.text; declarations requires an initial advance.
token: Token = .{ .kind = .eof, .text = "", .offset = 0 },
/// Namespace active in this source; included parsers have their own namespace state.
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

/// Consume this source to EOF, loading includes and appending unresolved declarations.
/// Requires an initial advance and the same arena as the enclosing compilation.
/// Includes must precede declarations. Errors leave partial compiler state and arena
/// allocations; public parsing discards that state and retains the optional diagnostic.
pub fn declarations(self: *Parser, allocator: Allocator) Error!void {
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
        underlying_base = scalar_types.get(try self.identifier(allocator)) orelse .None;
        if (!underlying_base.isScalar() or underlying_base == .Bool or
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
        .base_size = underlying_base.byteSize(),
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
        const member: EnumMember = if (union_type)
            try self.unionAlternative(allocator)
        else
            .{
                .name = try self.identifier(allocator),
                .type_ref = try emptyType(allocator, member_location),
            };
        if ((try names.getOrPut(allocator, member.name)).found_existing)
            return compiler.fail(
                allocator,
                member_location,
                error.InvalidSchema,
                "duplicate enum/union member '{s}'",
                .{member.name},
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
                .name = member.name,
                .value = bits,
                .union_type = member.type_ref.value,
                .attributes = member_attributes,
            },
            .type_ref = member.type_ref,
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

fn unionAlternative(self: *Parser, allocator: Allocator) Error!EnumMember {
    const member_location = self.location();
    var member_name = try self.name(allocator);
    var reference = try emptyType(allocator, member_location);
    var target = member_name;
    const aliased = try self.take(allocator, ":");
    if (aliased) {
        if (std.mem.indexOfScalar(u8, member_name, '.') != null)
            return self.compiler.invalid(
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
    if (scalar_types.get(target)) |base| {
        if (!aliased) return self.compiler.invalid(
            allocator,
            member_location,
            "built-in union alternatives require an alias, for example Text:string",
        );
        reference.value.base_type = base;
    } else reference.name = target;
    return .{ .name = member_name, .type_ref = reference };
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
    const base = scalar_types.get(type_name) orelse .None;
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

/// Skip whitespace/comments and replace token with the next raw source slice.
/// String decoding and numeric validation happen later. Unterminated comments/strings
/// or unsupported characters return InvalidSchema; diagnostics can return OutOfMemory.
/// EOF has empty text and an offset equal to source.text.len.
pub fn advance(self: *Parser, allocator: Allocator) Error!void {
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
