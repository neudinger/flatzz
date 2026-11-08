//! Compile-time FlatBuffers struct layouts, independent of the native Zig ABI.
//! Members follow schema order, with natural alignment and explicit padding.
//! https://flatbuffers.dev/internals/#structs
//!
//! Example inside a test with `std = @import("std")` and
//! `runtime = @import("flatzz")` imported:
//! ```zig
//! const Point = struct { horizontal: i16, vertical: i16 };
//! const Layout = runtime.StructLayout(Point, .{ .size = 4, .alignment = 2 }, .{
//!     .horizontal = runtime.ScalarMember(i16, 0),
//!     .vertical = runtime.ScalarMember(i16, 2),
//! });
//! var bytes: [Layout.wire_size]u8 = undefined;
//! Layout.encode(&bytes, .{ .horizontal = 1, .vertical = -2 });
//! const point = try Layout.decode(&bytes);
//! try std.testing.expectEqualSlices(u8, &.{ 1, 0, 254, 255 }, &bytes);
//! try std.testing.expectEqual(@as(i16, 1), point.horizontal);
//! try std.testing.expectEqual(@as(i16, -2), point.vertical);
//! ```
//! Expected result: `bytes == .{ 1, 0, 254, 255 }`, `point.horizontal == 1`,
//! and `point.vertical == -2`.
//! No output is printed; all storage belongs to the caller.
const std = @import("std");
const wire = @import("wire.zig");
const errors = @import("errors.zig");

const DecodeError = errors.DecodeError;

/// Interpretation of one inline member, independent of the native Zig ABI.
pub const Kind = union(enum) {
    /// Fixed-width scalar or enum type.
    scalar: type,
    /// Nested struct layout.
    structure: type,
    /// Fixed inline array layout.
    array: type,
};
/// Distinguishes struct layouts from inline fixed-array layouts.
pub const LayoutKind = enum {
    /// Named FBS struct, with naturally aligned members and padding.
    structure,
    /// Fixed sequence of scalars or structs, without a length prefix.
    array,
};
/// Expected wire size and natural alignment, checked against the descriptors.
pub const Options = struct {
    /// Complete byte size, including final alignment padding.
    size: usize,
    /// Maximum member alignment, in bytes.
    alignment: usize,
};

/// Describe one non-optional scalar at its byte offset within an inline struct.
/// Unsupported scalar types are rejected when their wire representation is resolved.
pub fn ScalarMember(
    comptime ScalarType: type,
    comptime member_offset: usize,
) type {
    return struct {
        /// Native member value; serialization copies its wire representation.
        pub const Value = ScalarType;
        /// Scalar type used for checked decoding and little-endian encoding.
        pub const kind: Kind = .{ .scalar = ScalarType };
        /// Byte offset relative to the containing struct.
        pub const offset = member_offset;
        /// Serialized scalar width, in bytes.
        pub const wire_size = @sizeOf(wire.Bits(ScalarType));
        /// Natural scalar alignment, in bytes.
        pub const wire_alignment = wire_size;
    };
}

/// Describe a nested struct at a byte offset; array layouts are rejected at compile time.
pub fn StructMember(
    comptime Layout: type,
    comptime member_offset: usize,
) type {
    if (Layout.layout_kind != .structure)
        @compileError("StructMember requires a struct layout");
    return LayoutMember(Layout, member_offset);
}

/// Arrays are inline struct members, containing scalars or structs only.
/// A struct element may itself contain arrays; direct arrays of arrays are not
/// an FBS type. Counts and all size arithmetic are evaluated at compile time.
pub fn ArrayMember(
    comptime element: Kind,
    comptime element_count: usize,
    comptime member_offset: usize,
) type {
    return LayoutMember(ArrayLayout(element, element_count), member_offset);
}

fn LayoutMember(comptime Layout: type, comptime member_offset: usize) type {
    return struct {
        /// Native nested value accepted by encoding and returned by decoding.
        pub const Value = Layout.Value;
        /// Nested struct or fixed-array layout used for encoding and validation.
        pub const kind: Kind = if (Layout.layout_kind == .structure)
            .{ .structure = Layout }
        else
            .{ .array = Layout };
        /// Byte offset relative to the containing struct.
        pub const offset = member_offset;
        /// Complete inline byte size, including layout padding.
        pub const wire_size = Layout.wire_size;
        /// Required wire alignment, in bytes.
        pub const wire_alignment = Layout.wire_alignment;
    };
}

/// Describe a fixed array of 1...65535 scalar or struct elements.
/// No allocation or length prefix is used; direct nested arrays fail at compile time.
pub fn ArrayLayout(comptime element: Kind, comptime count: usize) type {
    if (count == 0 or count > wire.max_array_length)
        @compileError("array length must be positive and fit in u16");
    const ElementType = switch (element) {
        .scalar => |ScalarType| ScalarMember(ScalarType, 0),
        .structure => |Layout| StructMember(Layout, 0),
        .array => @compileError("direct nested arrays are unsupported"),
    };
    return struct {
        /// Identifies a fixed array rather than a named struct layout.
        pub const layout_kind: LayoutKind = .array;
        /// Descriptor of one scalar or struct element, relative to offset zero.
        pub const Element = ElementType;
        /// Schema-defined number of inline elements.
        pub const element_count = count;
        /// Native array value; its ABI layout is not copied onto the wire.
        pub const Value = [count]Element.Value;
        /// Complete array extent in bytes, without a count prefix.
        pub const wire_size = count * Element.wire_size;
        /// Element alignment required for the array start.
        pub const wire_alignment = Element.wire_alignment;
        /// Scalar leaf visits required for complete array validation.
        pub const work_size = count * switch (Element.kind) {
            .scalar => @as(usize, 1),
            .structure => |Layout| Layout.work_size,
            .array => unreachable,
        };

        /// Encode every element without a count prefix; structs include wire padding.
        /// Input must not alias the destination: aggregate values may be passed by reference.
        pub fn encode(destination: *[wire_size]u8, value: Value) void {
            for (value, 0..) |item, element_index| {
                const element_start = element_index * Element.wire_size;
                const element_bytes = destination[element_start..][0..Element.wire_size];
                switch (Element.kind) {
                    .scalar => |ScalarType| wire.encode(ScalarType, element_bytes, item),
                    .structure => |Layout| Layout.encode(element_bytes, item),
                    .array => unreachable,
                }
            }
        }

        /// Copy all elements from checked-size wire storage; invalid scalar encodings fail.
        /// The returned native array owns its values and does not borrow `source`.
        pub fn decode(source: *const [wire_size]u8) DecodeError!Value {
            var result: Value = undefined;
            for (&result, 0..) |*item, element_index| {
                const element_start = element_index * Element.wire_size;
                const element_bytes = source[element_start..][0..Element.wire_size];
                item.* = switch (Element.kind) {
                    .scalar => |ScalarType| try wire.decode(ScalarType, element_bytes),
                    .structure => |Layout| try Layout.decode(element_bytes),
                    .array => unreachable,
                };
            }
            return result;
        }

        /// Verification never materializes the possibly large native array.
        pub fn verify(source: *const [wire_size]u8) DecodeError!void {
            for (0..count) |element_index| {
                const element_start = element_index * Element.wire_size;
                const element_bytes = source[element_start..][0..Element.wire_size];
                switch (Element.kind) {
                    .scalar => |ScalarType| _ = try wire.decode(ScalarType, element_bytes),
                    .structure => |Layout| try Layout.verify(element_bytes),
                    .array => unreachable,
                }
            }
        }
    };
}

/// Generated metadata gives the wire layout; native declaration order is free.
/// Reject layouts inconsistent with normal FlatBuffers packing at compile time.
/// Explicit force_align needs its own policy in a later feature.
pub fn StructLayout(
    comptime Native: type,
    comptime options: Options,
    comptime descriptors: anytype,
) type {
    const native_info = @typeInfo(Native).@"struct";
    const member_names = @typeInfo(@TypeOf(descriptors)).@"struct".field_names;
    comptime {
        if (member_names.len == 0 or
            member_names.len != native_info.field_names.len)
            @compileError("struct descriptors must match nonempty native fields");
        var member_end: usize = 0;
        var maximum_alignment: usize = @sizeOf(u8);
        for (member_names) |member_name| {
            if (!@hasField(Native, member_name))
                @compileError("missing native struct member");
            const MemberType = @field(descriptors, member_name);
            if (MemberType.Value != @FieldType(Native, member_name))
                @compileError("struct descriptor value type mismatch");
            const expected_offset = std.mem.alignForward(
                usize,
                member_end,
                MemberType.wire_alignment,
            );
            if (MemberType.offset != expected_offset)
                @compileError("invalid FlatBuffers struct member offset");
            member_end = expected_offset + MemberType.wire_size;
            maximum_alignment = @max(maximum_alignment, MemberType.wire_alignment);
        }
        if (options.alignment != maximum_alignment or
            options.size != std.mem.alignForward(
                usize,
                member_end,
                maximum_alignment,
            )) @compileError("invalid FlatBuffers struct size or alignment");
    }
    return struct {
        /// Identifies a named inline struct layout.
        pub const layout_kind: LayoutKind = .structure;
        /// Native copied value; its declaration order and padding are independent of the wire.
        pub const Value = Native;
        /// Native member names accepted by `Member` and borrowed views.
        pub const Field = std.meta.FieldEnum(Native);
        /// Member descriptors in schema wire order.
        pub const members = descriptors;
        /// Complete padded wire extent, in bytes.
        pub const wire_size = options.size;
        /// Natural wire alignment, in bytes.
        pub const wire_alignment = options.alignment;
        /// Scalar leaves visited by decode, including all nested members.
        pub const work_size = decode_work_blk: {
            var total: usize = 0;
            for (member_names) |member_name| {
                total += switch (@field(descriptors, member_name).kind) {
                    .scalar => 1,
                    .structure, .array => |Layout| Layout.work_size,
                };
            }
            break :decode_work_blk total;
        };

        /// Resolve a native field name to its compile-time member descriptor.
        pub fn Member(comptime field: Field) type {
            return @field(descriptors, @tagName(field));
        }

        /// Caller checks the destination range and rules out input aliasing.
        /// Encode values member by member; native padding is never serialized.
        pub fn encode(destination: *[wire_size]u8, value: Value) void {
            @memset(destination, 0);
            inline for (member_names) |member_name| {
                const MemberType = @field(descriptors, member_name);
                const member_bytes = destination[MemberType.offset..][0..MemberType.wire_size];
                const member_value = @field(value, member_name);
                switch (MemberType.kind) {
                    .scalar => |ScalarType| wire.encode(ScalarType, member_bytes, member_value),
                    .structure, .array => |Layout| Layout.encode(member_bytes, member_value),
                }
            }
        }

        /// Copies native values; borrowed member access belongs to StructView.
        /// Padding is ignored on read, matching the reference implementations.
        /// Invalid scalar encodings return a decoding error.
        pub fn decode(source: *const [wire_size]u8) DecodeError!Value {
            var result: Value = undefined;
            inline for (member_names) |member_name| {
                const MemberType = @field(descriptors, member_name);
                const member_bytes = source[MemberType.offset..][0..MemberType.wire_size];
                @field(result, member_name) = switch (MemberType.kind) {
                    .scalar => |ScalarType| try wire.decode(ScalarType, member_bytes),
                    .structure, .array => |Layout| try Layout.decode(member_bytes),
                };
            }
            return result;
        }

        /// Validate all scalar leaves without materializing a native struct; ignore padding.
        pub fn verify(source: *const [wire_size]u8) DecodeError!void {
            inline for (member_names) |member_name| {
                const MemberType = @field(descriptors, member_name);
                const member_bytes = source[MemberType.offset..][0..MemberType.wire_size];
                switch (MemberType.kind) {
                    .scalar => |ScalarType| _ = try wire.decode(ScalarType, member_bytes),
                    .structure, .array => |Layout| try Layout.verify(member_bytes),
                }
            }
        }

        /// Encode complete padded structs into at least `values.len * wire_size` bytes.
        /// The caller checks that bound and excludes input aliasing before any write.
        pub fn encodeSlice(destination: []u8, values: []const Value) void {
            for (values, 0..) |value, element_index| {
                const element_start = element_index * wire_size;
                encode(destination[element_start..][0..wire_size], value);
            }
        }
    };
}
