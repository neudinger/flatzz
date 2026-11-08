//! Unresolved FBS declarations and shared spelling operations.
//! Records borrow copied source text or caller-arena storage; retain that arena
//! until compilation and all reflection-metadata consumers finish.

const std = @import("std");
const reflection = @import("../reflection.zig");
const frontend = @import("../parser.zig");

const Allocator = std.mem.Allocator;
const Source = frontend.Source;

// FBS attribute spellings are external names; numeric tags have no wire meaning.
pub const BuiltinAttribute = enum {
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

pub const Location = struct { source: Source, offset: usize };
pub const TokenKind = enum { identifier, number, string, punctuation, eof };
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    offset: usize,
};
pub const Atom = struct { kind: TokenKind, text: []const u8, location: Location };
pub const Attributes = []const reflection.KeyValue;
pub const TypeRef = struct {
    value: *reflection.Type,
    name: ?[]const u8 = null,
    location: Location,
};
pub const FieldDef = struct {
    value: reflection.Field,
    type_ref: TypeRef,
    default: ?Atom = null,
    location: Location,
};
pub const ObjectDef = struct {
    value: reflection.Object,
    namespace: []const u8,
    fields: []FieldDef,
    location: Location,
    // Mutable view for layout and sorting; value.fields exposes the same storage as const.
    output_fields: []reflection.Field = &.{},
    state: enum { unseen, visiting, done } = .unseen,
};
pub const EnumMember = struct { name: []const u8, type_ref: TypeRef };
pub const EnumValueDef = struct { value: reflection.EnumVal, type_ref: TypeRef };
pub const EnumDef = struct {
    value: reflection.Enum,
    namespace: []const u8,
    values: []EnumValueDef,
    location: Location,
};
pub const Symbol = union(enum) { object: usize, enumeration: usize };
pub const Root = struct { name: []const u8, namespace: []const u8, location: Location, main: bool };

pub fn attribute(attributes: ?Attributes, comptime key: BuiltinAttribute) ?reflection.KeyValue {
    for (attributes orelse &.{}) |item| if (std.mem.eql(u8, item.key, @tagName(key))) return item;
    return null;
}
pub fn qualify(
    allocator: Allocator,
    namespace: []const u8,
    name: []const u8,
) Allocator.Error![]const u8 {
    return if (namespace.len == 0) name else allocator.print("{s}.{s}", .{ namespace, name });
}
