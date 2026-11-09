//! Descriptor-selected results and reads from already checked tables.
//! Views borrow the input frame; callers choose framing and input capabilities.
//! Internal adapter shared by schema.read and schema.borrowMutable. It allocates
//! nothing and never opens a root or performs recursive schema verification.

const sequence = @import("../sequence.zig");
const table_view = @import("../table_view.zig");
const struct_view = @import("../struct_view.zig");
const unions = @import("../unions.zig");
const errors = @import("../errors.zig");

const AccessError = errors.AccessError;
const StructView = struct_view.StructView;

/// Select a field result without resolving native child schemas.
/// Scalars are copied; optional references and structured views borrow the frame.
/// The access capability reaches table/struct payloads; strings stay read-only.
pub fn View(comptime field_kind: anytype, comptime access: table_view.Access) type {
    return switch (field_kind) {
        .scalar => |ValueType| ValueType,
        .string => ?[]const u8,
        .structure => |Layout| ?StructView(Layout, access),
        .vector => |ElementCodec| ?sequence.SequenceView(ElementCodec, access),
        .table => ?table_view.TableView(access),
        .union_value => |UnionType| UnionType.View(access),
        .union_vector => |UnionType| ?unions.VectorView(UnionType, access),
    };
}

/// Read one descriptor using the caller's already checked table and selected frame.
/// Absence uses scalar defaults, null references, or the union's none alternative.
/// Required presence is a verifier/builder rule; vector elements are checked lazily.
pub fn read(
    comptime FieldType: type,
    comptime access: table_view.Access,
    table: table_view.TableView(access),
) AccessError!View(FieldType.kind, access) {
    return switch (FieldType.kind) {
        .scalar => |ValueType| table.readField(ValueType, FieldType.wire_id, FieldType.default),
        .string => table.readString(FieldType.wire_id),
        .structure => |Layout| table.readStruct(Layout, FieldType.wire_id),
        .vector => |ElementCodec| table.readVector(ElementCodec, FieldType.wire_id),
        .table => table.readTable(FieldType.wire_id),
        .union_value => |UnionType| table.readUnion(UnionType, FieldType.field_ids),
        .union_vector => |UnionType| table.readUnionVector(UnionType, FieldType.field_ids),
    };
}
