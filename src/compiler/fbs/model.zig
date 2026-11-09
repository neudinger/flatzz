//! Unresolved FBS declarations and shared spelling operations.
//! Records borrow copied source text or caller-arena storage; retain that arena
//! until compilation and all reflection-metadata consumers finish.
//! These are internal declarations awaiting name/default/layout resolution, not
//! complete reflection records. Compilation.finish establishes final indices and layout.

const std = @import("std");
const reflection = @import("../reflection.zig");
const frontend = @import("../parser.zig");

const Allocator = std.mem.Allocator;
const Source = frontend.Source;

/// Recognized FBS spellings, including attributes rejected as unsupported.
/// Only id, required, deprecated, and key are implemented by this frontend.
/// Enum values are internal selectors with no wire meaning.
pub const BuiltinAttribute = enum {
    /// Explicit physical field ID; every field must use it when any does.
    id,
    /// Require a present reference or inline struct field.
    required,
    /// Retain metadata while omitting the field from generated native adapters.
    deprecated,
    /// Select the table's single scalar/string lookup key.
    key,
    /// Recognized alignment attribute; unsupported by this frontend.
    force_align,
    /// Recognized bit-flag attribute; unsupported by this frontend.
    bit_flags,
    /// Recognized nested-buffer attribute; unsupported by this frontend.
    nested_flatbuffer,
    /// Recognized FlexBuffers attribute; unsupported by this frontend.
    flexbuffer,
    /// Recognized hashing attribute; unsupported by this frontend.
    hash,
    /// Recognized 64-bit offset attribute; unsupported by this frontend.
    offset64,
    /// Recognized 64-bit vector attribute; unsupported by this frontend.
    vector64,
    /// Recognized declaration-order attribute; unsupported by this frontend.
    original_order,
    /// Recognized sharing attribute; unsupported by this frontend.
    shared,
    /// Recognized native inlining attribute; unsupported by this frontend.
    native_inline,
    /// Recognized native allocator attribute; unsupported by this frontend.
    native_custom_alloc,
    /// Recognized native type attribute; unsupported by this frontend.
    native_type,
    /// Recognized native packing-name attribute; unsupported by this frontend.
    native_type_pack_name,
    /// Recognized native default attribute; unsupported by this frontend.
    native_default,
    /// Recognized native include attribute; unsupported by this frontend.
    native_include,
    /// Recognized native C++ type attribute; unsupported by this frontend.
    native_cpp_type,
    /// Recognized C++ type attribute; unsupported by this frontend.
    cpp_type,
    /// Recognized C++ pointer attribute; unsupported by this frontend.
    cpp_ptr_type,
    /// Recognized C++ string attribute; unsupported by this frontend.
    cpp_str_type,
    /// Recognized C++ string-constructor attribute; unsupported by this frontend.
    cpp_str_flex_ctor,
    /// Recognized C++ include attribute; unsupported by this frontend.
    cpp_include,
    /// Recognized RPC streaming attribute; unsupported by this frontend.
    streaming,
    /// Recognized RPC idempotency attribute; unsupported by this frontend.
    idempotent,
    /// Recognized visibility attribute; unsupported by this frontend.
    private,
    /// Recognized empty-value attribute; unsupported by this frontend.
    force_empty,
    /// Recognized empty-vector attribute; unsupported by this frontend.
    force_empty_vector,
    /// Recognized C++ reflection attribute; unsupported by this frontend.
    cpp_static_reflection,
};

/// Source identity and byte location retained for deferred semantic diagnostics.
pub const Location = struct {
    /// Source name and text copied into the compilation's arena.
    source: Source,
    /// Zero-based byte offset; diagnostics convert it to a one-based line/column.
    offset: usize,
};
/// Lexical category; numeric and string contents are validated by later parsing.
pub const TokenKind = enum {
    /// ASCII identifier; qualified names combine several tokens.
    identifier,
    /// Numeric spelling retained for later integer/float validation.
    number,
    /// Quoted spelling, including quotes and escapes, before string decoding.
    string,
    /// One grammar delimiter or separator.
    punctuation,
    /// End of source; the token's offset equals the source byte length.
    eof,
};
/// One token borrowing the compilation's copied source text.
pub const Token = struct {
    /// Lexical interpretation of text, without semantic validation.
    kind: TokenKind,
    /// Raw source slice, including quotes for strings; empty at EOF.
    text: []const u8,
    /// Zero-based byte offset within the source.
    offset: usize,
};
/// Literal or qualified name retained for attribute/default resolution.
pub const Atom = struct {
    /// Original category, distinguishing quoted strings from identifiers/numbers.
    kind: TokenKind,
    /// Decoded string, qualified name, or numeric spelling with arena lifetime.
    text: []const u8,
    /// Original token location for later validation failures.
    location: Location,
};
/// Attribute entries borrowing compilation storage; null values represent bare flags.
pub const Attributes = []const reflection.KeyValue;
/// Mutable reflection type plus an optional unresolved declaration name.
pub const TypeRef = struct {
    /// Arena-owned type record completed in place during name resolution.
    value: *reflection.Type,
    /// Unresolved object/enum spelling; null for an already known primitive type.
    name: ?[]const u8 = null,
    /// Source position used for resolution/layout failures.
    location: Location,
};
/// Parsed table field or struct member before IDs, defaults, and layout are finalized.
pub const FieldDef = struct {
    /// Initial reflection properties; type points at type_ref.value.
    value: reflection.Field,
    /// Type spelling and record awaiting resolution in the object's namespace.
    type_ref: TypeRef,
    /// Explicit default expression; null means no default was written.
    default: ?Atom = null,
    /// Field declaration position for semantic diagnostics.
    location: Location,
};
/// Unresolved object with declaration-order fields and mutable output-layout state.
pub const ObjectDef = struct {
    /// Reflection properties whose fields/layout are completed during finish.
    value: reflection.Object,
    /// Namespace in which relative type/default names are resolved.
    namespace: []const u8,
    /// Parsed logical fields in source order, before synthetic union tags.
    fields: []FieldDef,
    /// Object declaration position for layout and key errors.
    location: Location,
    /// Mutable layout/sorting storage; value.fields exposes this same array as const.
    output_fields: []reflection.Field = &.{},
    /// Inline-layout DFS state; visiting detects recursive structs, done reuses layout.
    state: enum {
        /// Wire layout has not been computed yet.
        unseen,
        /// Layout is on the active recursion path; revisiting it is an inline cycle.
        visiting,
        /// Size, alignment, member offsets, and padding are ready for reuse.
        done,
    } = .unseen,
};
/// Parsed enum member name or union alias with its unresolved payload type.
pub const EnumMember = struct {
    /// Final member spelling; qualified unaliased union names replace dots with underscores.
    name: []const u8,
    /// Union payload type, or the empty type for an ordinary enum member.
    type_ref: TypeRef,
};
/// Numeric enum value or union alternative awaiting payload-name resolution.
pub const EnumValueDef = struct {
    /// Reflection value; union_type borrows the type_ref record.
    value: reflection.EnumVal,
    /// Payload metadata completed during semantic resolution.
    type_ref: TypeRef,
};
/// Parsed enum/union whose output member array is installed during finish.
pub const EnumDef = struct {
    /// Initial enum properties and borrowed backing-type metadata.
    value: reflection.Enum,
    /// Namespace used to resolve union payload names.
    namespace: []const u8,
    /// Source-order values, including the synthetic NONE alternative for unions.
    values: []EnumValueDef,
    /// Enum declaration position for later semantic diagnostics.
    location: Location,
};
/// Index into a compilation declaration array; rebuilt after final name sorting.
pub const Symbol = union(enum) {
    /// Current index in Compilation.objects.
    object: usize,
    /// Current index in Compilation.enums.
    enumeration: usize,
};
/// Deferred root_type declaration; included roots are validated but do not select output.
pub const Root = struct {
    /// Unresolved table name.
    name: []const u8,
    /// Namespace active at the declaration.
    namespace: []const u8,
    /// Source position used when the root cannot resolve to a table.
    location: Location,
    /// Only a root from the main source selects Schema.root_table.
    main: bool,
};

/// Find a builtin attribute by its exact FBS spelling; return null for absence.
/// A returned record still borrows its key/value strings; no allocation occurs.
pub fn attribute(attributes: ?Attributes, comptime key: BuiltinAttribute) ?reflection.KeyValue {
    for (attributes orelse &.{}) |item| if (std.mem.eql(u8, item.key, @tagName(key))) return item;
    return null;
}
/// Join a nonempty namespace and name with a dot, allocating the resulting spelling.
/// An empty namespace returns the original borrowed name without allocation. Internal
/// arena callers retain either result for the compilation's lifetime.
pub fn qualify(
    allocator: Allocator,
    namespace: []const u8,
    name: []const u8,
) Allocator.Error![]const u8 {
    return if (namespace.len == 0) name else allocator.print("{s}.{s}", .{ namespace, name });
}
