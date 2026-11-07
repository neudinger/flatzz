//! FlatBuffers reflection metadata produced by the native FBS parser or a decoder.
//! Slices and pointers borrow caller-owned storage; retain its allocator or arena
//! until all schema consumers finish. These are declarations, not a BFBS decoder.
//! Wire schema: FlatBuffers v25.2.10, commit 1c514626e83c20fffa8557e75641848e1e15cd5e.
//! https://github.com/google/flatbuffers/blob/1c514626e83c20fffa8557e75641848e1e15cd5e/reflection/reflection.fbs
//!
//! Import `const compiler = @import("flatzz_compiler");`, then alias `compiler.reflection`.
//! Records preserve reflection.fbs names, defaults, and field order: the BFBS
//! codec derives wire field IDs from that order. `null` optional metadata differs
//! from a present empty string or slice. Constructing these records does not
//! validate schema semantics or generate native Zig types.
//!
//! Example inside a test with `std = @import("std")` and `reflection` imported:
//! ```zig
//! const integer_type: reflection.Type = .{ .base_type = .UInt, .base_size = 4 };
//! const objects: []const reflection.Object = &.{.{
//!     .name = "Reading",
//!     .fields = &.{.{ .name = "value", .type = &integer_type, .offset = 4 }},
//! }};
//! const schema: reflection.Schema = .{
//!     .objects = objects,
//!     .enums = &.{},
//!     .root_table = &objects[0],
//! };
//! try std.testing.expectEqualStrings("Reading", schema.root_table.?.name);
//! ```
//! Expected result: `schema.root_table.?.name` is `"Reading"` and its first field
//! describes a `uint` at table wire ID zero. No allocation or output occurs.
//! Keep the local records alive while using `schema`, including during BFBS encoding.

/// Four-byte identifier stored in a reflection binary schema frame.
pub const file_identifier = "BFBS";
/// Conventional extension for binary schema files, without a leading dot.
pub const file_extension = "bfbs";

/// Reflection wire type codes; unknown appended codes survive BFBS decoding.
pub const BaseType = enum(i8) {
    /// No value type, including the payload of a union's NONE alternative.
    None = 0,
    /// Union discriminator, separate from the associated union payload field.
    UType = 1,
    /// Boolean scalar encoded in one byte.
    Bool = 2,
    /// Signed 8-bit scalar.
    Byte = 3,
    /// Unsigned 8-bit scalar.
    UByte = 4,
    /// Signed 16-bit scalar.
    Short = 5,
    /// Unsigned 16-bit scalar.
    UShort = 6,
    /// Signed 32-bit scalar.
    Int = 7,
    /// Unsigned 32-bit scalar.
    UInt = 8,
    /// Signed 64-bit scalar.
    Long = 9,
    /// Unsigned 64-bit scalar.
    ULong = 10,
    /// IEEE 754 binary32 scalar.
    Float = 11,
    /// IEEE 754 binary64 scalar.
    Double = 12,
    /// Reference to a length-prefixed, zero-terminated UTF-8 string.
    String = 13,
    /// Reference to a sequence described by `Type.element`.
    Vector = 14,
    /// Table or inline struct selected by `Type.index` in `Schema.objects`.
    Obj = 15,
    /// Union payload selected by its discriminator and `Schema.enums` entry.
    Union = 16,
    /// Fixed-length inline sequence described by `Type.element` and `fixed_length`.
    Array = 17,
    /// Vector with 64-bit length metadata; represented even if a consumer lacks support.
    Vector64 = 18,
    /// Upstream sentinel after the known type codes; not a field value type.
    MaxBaseType = 19,
    _,
};

// Bit positions correspond to masks 1, 2, 4, and 8.
/// Feature mask carried by BFBS; flags describe schema requirements, not runtime support.
pub const AdvancedFeatures = packed struct(u64) {
    /// Fixed-length inline array features are present.
    advanced_array_features: bool = false,
    /// Advanced union forms, such as struct/string payloads or union vectors, are present.
    advanced_union_features: bool = false,
    /// Scalar fields can distinguish null from a present scalar value.
    optional_scalars: bool = false,
    /// Vector or string defaults are present.
    default_vectors_and_strings: bool = false,
    /// Unrecognized high feature bits retained verbatim by the BFBS codec.
    unknown_bits: u60 = 0,
};

/// Field or element type metadata; pointers to this record borrow its storage.
pub const Type = struct {
    /// Outermost type, such as `.UInt`, `.Obj`, `.Vector`, or `.Array`.
    base_type: BaseType = .None,
    /// Vector/array element type; `.None` when no element type is described.
    element: BaseType = .None,
    /// Referenced object/enum index; -1 means no referenced declaration.
    index: i32 = -1,
    /// Number of inline elements for `.Array`; zero otherwise.
    fixed_length: u16 = 0,
    /// Encoded base width in bytes; the reflection wire default is 4, including old BFBS.
    base_size: u32 = 4,
    /// Encoded element width in bytes; zero is the reflection wire default.
    element_size: u32 = 0,
};

/// Borrowed attribute name and optional text value; null represents no value.
pub const KeyValue = struct {
    /// Attribute name; BFBS encoding sorts attribute vectors by this key.
    key: []const u8,
    /// Attribute text, with null distinct from an explicitly empty value.
    value: ?[]const u8 = null,
};

/// Named enum value or union alternative, with optional descriptive metadata.
pub const EnumVal = struct {
    /// Unqualified member name.
    name: []const u8,
    /// Integer value; unsigned 64-bit values retain their bit pattern in this i64.
    value: i64 = 0,

    // Deprecated in reflection.fbs; retained for legacy metadata.
    /// Legacy union object reference; when encoding, point into `Schema.objects`.
    object: ?*const Object = null,

    /// Union payload type; null when absent from the metadata.
    union_type: ?*const Type = null,
    /// Borrowed documentation lines, without requiring a joined allocation.
    documentation: ?[]const []const u8 = null,
    /// Optional member attributes; null and a present empty vector remain distinct.
    attributes: ?[]const KeyValue = null,
};

/// Integer enumeration or union discriminator declaration.
pub const Enum = struct {
    /// Fully qualified declaration name, including its namespace.
    name: []const u8,
    /// Required member vector; its existing order is preserved by BFBS encoding.
    values: []const EnumVal,
    /// True for a union discriminator and its associated payload alternatives.
    is_union: bool = false,
    /// Required integer backing-type metadata, borrowed for this record's lifetime.
    underlying_type: *const Type,
    /// Optional declaration attributes.
    attributes: ?[]const KeyValue = null,
    /// Optional borrowed documentation lines.
    documentation: ?[]const []const u8 = null,
    /// Source identity, usually matching a `SchemaFile.filename` entry.
    declaration_file: ?[]const u8 = null,
};

/// Table field or inline struct member; physical placement is independent of name sorting.
pub const Field = struct {
    /// Unqualified field name.
    name: []const u8,
    /// Required borrowed type metadata.
    type: *const Type,
    /// Wire field ID, including synthesized union discriminator fields.
    id: u16 = 0,
    /// Byte offset into the vtable for tables, or into the inline object for structs.
    offset: u16 = 0,
    /// Integral default bits; reinterpret as u64 for an unsigned 64-bit default.
    default_integer: i64 = 0,
    /// Floating default retained as f64 metadata, even for float32 fields.
    default_real: f64 = 0.0,
    /// Field is retained in metadata but deprecated for generated accessors.
    deprecated: bool = false,
    /// A serialized table must contain this reference or struct field.
    required: bool = false,
    /// Field participates as the table's lookup key.
    key: bool = false,
    /// Optional field attributes.
    attributes: ?[]const KeyValue = null,
    /// Optional borrowed documentation lines.
    documentation: ?[]const []const u8 = null,
    /// Field may be absent/null, including a nullable scalar when supported.
    optional: bool = false,
    /// Padding bytes after an inline struct member.
    padding: u16 = 0,
    /// Field uses 64-bit offset metadata; representation does not imply runtime support.
    offset64: bool = false,
};

/// Table or fixed-layout struct declaration; fields may be sorted independently of IDs.
pub const Object = struct {
    /// Fully qualified declaration name.
    name: []const u8,
    /// Required field vector; preserve `id` and `offset` when traversing by name.
    fields: []const Field,
    /// True for an inline fixed-layout struct, false for a table.
    is_struct: bool = false,
    /// Inline struct minimum alignment in bytes; retained verbatim for tables/legacy BFBS.
    minalign: i32 = 0,
    /// Inline struct total byte size, including padding; zero is the wire default.
    bytesize: i32 = 0,
    /// Optional declaration attributes.
    attributes: ?[]const KeyValue = null,
    /// Optional borrowed documentation lines.
    documentation: ?[]const []const u8 = null,
    /// Source identity, usually matching a `SchemaFile.filename` entry.
    declaration_file: ?[]const u8 = null,
};

/// Service operation retained by BFBS decoding; the native FBS parser rejects RPC declarations.
pub const RPCCall = struct {
    /// Unqualified operation name.
    name: []const u8,
    /// Required request declaration; when encoding, point into `Schema.objects`.
    request: *const Object,
    /// Required response declaration; when encoding, point into `Schema.objects`.
    response: *const Object,
    /// Optional operation attributes.
    attributes: ?[]const KeyValue = null,
    /// Optional borrowed documentation lines.
    documentation: ?[]const []const u8 = null,
};

/// RPC service metadata, independent of any generated transport implementation.
pub const Service = struct {
    /// Fully qualified service name.
    name: []const u8,
    /// Optional operations, whose Object pointers share the schema's object storage.
    calls: ?[]const RPCCall = null,
    /// Optional service attributes.
    attributes: ?[]const KeyValue = null,
    /// Optional borrowed documentation lines.
    documentation: ?[]const []const u8 = null,
    /// Source identity, usually matching a `SchemaFile.filename` entry.
    declaration_file: ?[]const u8 = null,
};

/// Source identity and its direct include dependencies.
pub const SchemaFile = struct {
    /// Borrowed source identity; exact normalization is chosen by the producer.
    filename: []const u8,
    /// Optional direct include identities, without recursively flattened dependencies.
    included_filenames: ?[]const []const u8 = null,
};

/// Complete borrowed schema description; keep all referenced storage alive while consuming it.
/// The native parser/decoder use caller-arena storage, while manual records may use
/// static or local storage. `bfbs.encode` reads this graph without taking ownership.
pub const Schema = struct {
    /// Required table/struct vector; indices in `Type` refer to this order.
    objects: []const Object,
    /// Required enum/union vector; indices in `Type` refer to this order.
    enums: []const Enum,
    /// Optional four-byte identifier for application buffers, distinct from BFBS's own identifier.
    file_ident: ?[]const u8 = null,
    /// Optional extension for application buffers, without a leading dot.
    file_ext: ?[]const u8 = null,
    /// Optional root table; for encoding, this must point into `objects`.
    root_table: ?*const Object = null,
    /// Optional RPC descriptions; the native FBS parser does not construct them.
    services: ?[]const Service = null,
    /// Required consumer capabilities, including unknown feature bits.
    advanced_features: AdvancedFeatures = .{},
    /// Optional source-file and direct-include metadata.
    fbs_files: ?[]const SchemaFile = null,
};
