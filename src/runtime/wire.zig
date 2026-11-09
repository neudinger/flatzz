//! Scalar wire representations and physical FlatBuffers sizes, independent of Zig ABI.
//! Fixed-width encode/decode operate on caller-selected ranges.
//! Use `flatzz.buffer_access.readScalar` and `flatzz.buffer_access.writeScalar` for checked access.
//! These low-level encoders copy scalar values, never native aggregate layouts.
//! Fixed-size pointers select the accessed width; frame containment and alignment
//! remain the caller's responsibility. No allocation or cleanup is required.
//!
//! Example test body with `std` and `runtime = @import("flatzz")` imported:
//! ```zig
//! var bytes: [4]u8 = undefined;
//! runtime.wire.encode(u32, &bytes, 0x12345678);
//! try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, &bytes);
//! try std.testing.expectEqual(@as(u32, 0x12345678), try runtime.wire.decode(u32, &bytes));
//! ```
//! Expected result: the four little-endian bytes round-trip without allocation or output.
//! The `flatzz` module overview provides complete imports and a Zig 0.17.0 test command.
const std = @import("std");
const errors = @import("errors.zig");

const DecodeError = errors.DecodeError;

/// The buffer begins with a u32 offset to its root table.
/// https://flatbuffers.dev/internals/#offsets
pub const root_offset_size = @sizeOf(u32);

/// Size prefix counts following bytes, excluding the prefix itself.
/// https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/flatbuffer_builder.h
pub const size_prefix_size = @sizeOf(u32);

/// Optional four-byte file identifier follows the ordinary root offset.
/// https://flatbuffers.dev/schema/#file-identification-and-extension
pub const file_identifier_size = 4;
/// Identifier byte position in an ordinary frame, immediately after its root slot.
pub const file_identifier_start = root_offset_size;
/// Ordinary root-offset and identifier bytes protected from object storage.
pub const identified_header_size = file_identifier_start + file_identifier_size;

/// Reference fields hold a forward u32 offset, measured from the field itself.
/// https://flatbuffers.dev/internals/#offsets
pub const field_offset_size = @sizeOf(u32);

/// Strings and vectors have a u32 element count before their payload.
/// String counts exclude the zero terminator. The prefix has u32 alignment.
/// https://flatbuffers.dev/internals/#strings-and-vectors
pub const sequence_length_size = @sizeOf(u32);
/// Number of bytes following a string's payload as its zero terminator.
pub const string_terminator_size = @sizeOf(u8);
/// Required byte value after a string's counted payload.
pub const string_terminator: u8 = 0;

/// Every table starts with an i32 distance to its vtable.
/// https://flatbuffers.dev/internals/#tables
pub const table_header_size = @sizeOf(i32);

/// Vtable sizes and field offsets are all u16 values.
/// https://flatbuffers.dev/internals/#tables
pub const vtable_entry_size = @sizeOf(u16);

/// The table-size entry follows the vtable-size entry.
/// https://flatbuffers.dev/internals/#tables
pub const vtable_table_size_offset = vtable_entry_size;

/// The header contains the vtable-size and table-size entries.
/// https://flatbuffers.dev/internals/#tables
pub const vtable_header_size = vtable_table_size_offset + vtable_entry_size;

/// The complete vtable size must fit in its u16 size entry.
/// https://flatbuffers.dev/internals/#tables
pub const max_field_count =
    (std.math.maxInt(u16) - vtable_header_size) / vtable_entry_size;

/// A zero vtable field offset denotes an absent field.
/// https://flatbuffers.dev/internals/#tables
pub const absent_field_offset = 0;

/// Scalars use wire alignment equal to their size, independent of host ABI.
/// This runtime supports scalars up to u64/f64; this is its storage requirement.
/// https://flatbuffers.dev/internals/#format-components
pub const storage_alignment = @sizeOf(u64);

/// Fixed array counts are positive u16 schema metadata, not buffer prefixes.
/// https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/src/idl_parser.cpp#L874
pub const max_array_length = std.math.maxInt(u16);

/// Unions use an unsigned byte tag; zero means no selected payload.
/// https://flatbuffers.dev/internals/#unions
pub const UnionTag = u8;
/// Tag byte representing no selected union payload.
pub const union_none: UnionTag = 0;

/// Explicit whitelist of FlatBuffers scalar representations. Native Zig layout
/// is never the wire layout, including optional and enum representations.
pub fn Bits(comptime ScalarType: type) type {
    return switch (ScalarType) {
        bool, u8, i8 => u8,
        u16, i16 => u16,
        u32, i32, f32 => u32,
        u64, i64, f64 => u64,
        else => switch (@typeInfo(ScalarType)) {
            .@"enum" => |enum_info| Bits(enum_info.tag_type),
            else => @compileError("unsupported FlatBuffers scalar type"),
        },
    };
}

/// Unwrap one optional scalar layer and reject unsupported wire types at compile time.
/// Presence is represented by the enclosing table slot, never by native optional layout.
pub fn Scalar(comptime ValueType: type) type {
    const ScalarType = switch (@typeInfo(ValueType)) {
        .optional => |optional_info| optional_info.child,
        else => ValueType,
    };
    _ = Bits(ScalarType);
    return ScalarType;
}

/// Range selection is the caller's responsibility. The fixed-width argument
/// makes encoding infallible without repeating a dynamic bounds check.
/// Writes little-endian bytes; bool encodings are normalized to zero or one.
/// https://ziglang.org/documentation/0.17.0/std/#std.mem.writeInt
pub fn encode(
    comptime ScalarType: type,
    destination_bytes: *[@sizeOf(Bits(ScalarType))]u8,
    value: ScalarType,
) void {
    const WireType = Bits(ScalarType);
    const scalar_bits: WireType = switch (@typeInfo(ScalarType)) {
        .bool => @intFromBool(value),
        .@"enum" => @bitCast(@backingInt(value)),
        else => @bitCast(value),
    };
    std.mem.writeInt(WireType, destination_bytes, scalar_bits, .little);
}

/// Unaligned input is supported. Wire alignment belongs to object validation.
/// Exhaustive enums reject unknown tags; non-exhaustive enums retain them.
/// Bool follows Go GetBool: any nonzero byte reads as true; writes normalize it.
/// https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/go/encode.go
pub fn decode(
    comptime ScalarType: type,
    source_bytes: *const [@sizeOf(Bits(ScalarType))]u8,
) DecodeError!ScalarType {
    const scalar_bits = std.mem.readInt(Bits(ScalarType), source_bytes, .little);
    return switch (@typeInfo(ScalarType)) {
        .bool => scalar_bits != 0,
        .@"enum" => |enum_info| std.enums.fromInt(
            ScalarType,
            @as(enum_info.tag_type, @bitCast(scalar_bits)),
        ) orelse DecodeError.InvalidBuffer,
        else => @bitCast(scalar_bits),
    };
}

/// Power-of-two wire alignment, independent of host ABI alignment.
/// `alignment` must be nonzero and a power of two; this low-level helper does not validate it.
/// Go Prep; C++ PaddingBytes in include/flatbuffers/base.h.
pub fn paddingFor(byte_count: usize, alignment: usize) usize {
    return (0 -% byte_count) & (alignment - 1);
}

/// Caller validates capacity first. Directional element copies preserve memmove
/// semantics while encoding native values rather than copying native layouts.
/// Destination length must equal `values.len * @sizeOf(Bits(ElementType))`.
/// No frame metadata or construction state is checked; overlapping scalar input is allowed.
pub fn encodeSlice(
    comptime ElementType: type,
    destination_bytes: []u8,
    values: []const ElementType,
) void {
    if (ElementType == u8) {
        @memmove(destination_bytes, values);
        return;
    }
    const element_size = @sizeOf(Bits(ElementType));
    if (@intFromPtr(destination_bytes.ptr) > @intFromPtr(values.ptr)) {
        var element_index = values.len;
        while (element_index != 0) {
            element_index -= 1;
            encode(
                ElementType,
                destination_bytes[element_index * element_size ..][0..element_size],
                values[element_index],
            );
        }
    } else {
        for (values, 0..) |value, element_index| {
            encode(
                ElementType,
                destination_bytes[element_index * element_size ..][0..element_size],
                value,
            );
        }
    }
}
