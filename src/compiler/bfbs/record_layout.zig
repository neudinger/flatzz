//! Reflected field representation shared by BFBS encoding and decoding.

const reflection = @import("../reflection.zig");

pub fn Scalar(comptime Value: type) type {
    return if (Value == reflection.AdvancedFeatures) u64 else Value;
}

pub fn scalarDefault(comptime Record: type, comptime field_index: usize) Scalar(
    @typeInfo(Record).@"struct".field_types[field_index],
) {
    const structure = @typeInfo(Record).@"struct";
    const Value = structure.field_types[field_index];
    const default = structure.field_attrs[field_index].defaultValue(Value).?;
    return if (Value == reflection.AdvancedFeatures) @bitCast(default) else default;
}

pub fn isReference(comptime Value: type) bool {
    return switch (@typeInfo(Value)) {
        .pointer => true,
        .optional => |optional| isReference(optional.child),
        else => false,
    };
}
