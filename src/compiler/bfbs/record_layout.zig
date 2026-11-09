//! Reflected field representation shared by BFBS encoding and decoding.
//! Internal policy for reflection records: declaration order supplies physical field
//! IDs, optional pointers/slices supply presence, and native defaults supply wire defaults.
//! This module performs no allocation, byte access, or FBS semantic validation.

const reflection = @import("../reflection.zig");

/// Map the packed feature record to its u64 wire scalar; preserve other scalar types.
/// Callers select non-reference reflection fields before resolving this representation.
pub fn Scalar(comptime Value: type) type {
    return if (Value == reflection.AdvancedFeatures) u64 else Value;
}

/// Read one scalar field's declared default, bit-casting feature flags to their wire bits.
/// The compile-time index must select a defaulted scalar field of a reflection record.
pub fn scalarDefault(comptime Record: type, comptime field_index: usize) Scalar(
    @typeInfo(Record).@"struct".field_types[field_index],
) {
    const structure = @typeInfo(Record).@"struct";
    const Value = structure.field_types[field_index];
    const default = structure.field_attrs[field_index].defaultValue(Value).?;
    return if (Value == reflection.AdvancedFeatures) @bitCast(default) else default;
}

/// Classify pointers and optional pointers as references, including slices.
/// This describes reflection record fields, not arbitrary Zig serialization layouts.
pub fn isReference(comptime Value: type) bool {
    return switch (@typeInfo(Value)) {
        .pointer => true,
        .optional => |optional| isReference(optional.child),
        else => false,
    };
}
