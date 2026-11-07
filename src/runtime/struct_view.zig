//! Borrowed inline values; nested views retain the complete frame and access.
//! Go Struct{Bytes, Pos} and C++ GetStruct are the reference access patterns.
//! https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/go/struct.go
const validation = @import("validation.zig");
const mutation = @import("mutation.zig");
const errors = @import("errors.zig");
const table_view = @import("table_view.zig");

const AccessError = errors.AccessError;
const MutationError = errors.MutationError;

const Access = table_view.Access;

/// Borrow a named inline struct without copying; nested views preserve access capability.
/// The complete frame must outlive every view. No allocation or cleanup is required.
/// See `struct_layout.zig` for a complete layout and encoding example.
pub fn StructView(comptime Layout: type, comptime access: Access) type {
    if (Layout.layout_kind != .structure)
        @compileError("StructView requires a struct layout");
    return struct {
        const Self = @This();
        const Bytes = switch (access) {
            .read_only => []const u8,
            .mutable => []u8,
        };

        /// Complete input frame retained for nested member views.
        bytes: Bytes,
        /// Inline struct byte offset relative to `bytes`.
        struct_start: usize,

        /// Local range/alignment checks only; read/verification decode members.
        /// Table access checks containment before opening this inline view.
        pub fn from(bytes: Bytes, struct_start: usize) AccessError!Self {
            const result: Self = .{ .bytes = bytes, .struct_start = struct_start };
            try result.checkRange();
            return result;
        }

        /// Scalar value or nested borrowed view selected by a native member name.
        pub fn MemberView(comptime field: Layout.Field) type {
            return switch (Layout.Member(field).kind) {
                .scalar => |ScalarType| ScalarType,
                .structure => |ChildLayout| StructView(ChildLayout, access),
                .array => |ArrayLayout| ArrayView(ArrayLayout, access),
            };
        }

        /// Scalars are copied; nested structs and arrays borrow the same bytes.
        pub fn get(
            self: Self,
            comptime field: Layout.Field,
        ) AccessError!MemberView(field) {
            try self.checkRange();
            const MemberType = Layout.Member(field);
            const member_start = self.struct_start + MemberType.offset;
            return switch (MemberType.kind) {
                .scalar => |ScalarType| validation.readScalar(ScalarType, self.bytes, member_start),
                .structure => |ChildLayout| StructView(
                    ChildLayout,
                    access,
                ).from(self.bytes, member_start),
                .array => |ArrayLayout| ArrayView(ArrayLayout, access).from(
                    self.bytes,
                    member_start,
                ),
            };
        }

        /// Copy all members, including nested ones, into a native value that borrows no bytes.
        pub fn read(self: Self) AccessError!Layout.Value {
            try self.checkRange();
            return Layout.decode(self.bytes[self.struct_start..][0..Layout.wire_size]);
        }

        /// Validate all scalar leaves without constructing the native value; padding is ignored.
        pub fn verify(self: Self) AccessError!void {
            try self.checkRange();
            try Layout.verify(self.bytes[self.struct_start..][0..Layout.wire_size]);
        }

        /// Struct members always exist. Failure never partially updates bytes.
        pub fn update(
            self: Self,
            comptime field: Layout.Field,
            value: Layout.Member(field).Value,
        ) MutationError!void {
            comptime requireMutable();
            try self.checkRange();
            const MemberType = Layout.Member(field);
            const member_start = self.struct_start + MemberType.offset;
            switch (MemberType.kind) {
                .scalar => |ScalarType| try validation.writeScalar(
                    ScalarType,
                    self.bytes,
                    member_start,
                    value,
                ),
                .structure, .array => |ChildLayout| try mutation.inlineValue(
                    ChildLayout,
                    self.bytes,
                    member_start,
                    value,
                ),
            }
        }

        /// Replaces a present fixed-size value, including its zeroed padding.
        pub fn replace(
            self: Self,
            value: Layout.Value,
        ) MutationError!void {
            comptime requireMutable();
            try mutation.inlineValue(Layout, self.bytes, self.struct_start, value);
        }

        fn checkRange(self: Self) AccessError!void {
            try validation.inlineRange(
                self.bytes,
                self.struct_start,
                Layout.wire_size,
                Layout.wire_alignment,
            );
        }

        fn requireMutable() void {
            if (access != .mutable) @compileError("mutation requires a mutable struct");
        }
    };
}

/// Fixed arrays share the parent's storage; their count comes from the schema.
/// No vector prefix or reference context is synthesized for these inline bytes.
/// The complete frame must outlive the view; storage reuse invalidates its borrows.
pub fn ArrayView(comptime Layout: type, comptime access: Access) type {
    if (Layout.layout_kind != .array)
        @compileError("ArrayView requires an array layout");
    return struct {
        const Self = @This();
        const Element = Layout.Element;
        const Bytes = switch (access) {
            .read_only => []const u8,
            .mutable => []u8,
        };
        /// Fixed schema count; no prefix is read from the frame.
        pub const element_count = Layout.element_count;
        /// Copied scalar or borrowed struct result, retaining this view's capability.
        pub const ElementView = switch (Element.kind) {
            .scalar => |ScalarType| ScalarType,
            .structure => |ChildLayout| StructView(ChildLayout, access),
            .array => unreachable,
        };

        /// Complete input frame borrowed by this fixed array and nested element views.
        bytes: Bytes,
        /// Byte offset of the first inline element.
        array_start: usize,

        /// Borrow an inline array after checking its complete wire extent and alignment.
        pub fn from(bytes: Bytes, array_start: usize) AccessError!Self {
            try validation.inlineRange(bytes, array_start, Layout.wire_size, Layout.wire_alignment);
            return .{ .bytes = bytes, .array_start = array_start };
        }

        /// Read one bounds-checked scalar or borrow one inline struct element.
        pub fn get(
            self: Self,
            element_index: usize,
        ) AccessError!ElementView {
            const element_start = try self.elementStart(element_index);
            return switch (Element.kind) {
                .scalar => |ScalarType| validation.readScalar(
                    ScalarType,
                    self.bytes,
                    element_start,
                ),
                .structure => |ChildLayout| StructView(
                    ChildLayout,
                    access,
                ).from(self.bytes, element_start),
                .array => unreachable,
            };
        }

        /// Replace one existing element; requires mutable access.
        /// Failures leave the bytes unchanged.
        pub fn update(
            self: Self,
            element_index: usize,
            value: Element.Value,
        ) MutationError!void {
            if (access != .mutable) @compileError("mutation requires a mutable array");
            const element_start = try self.elementStart(element_index);
            switch (Element.kind) {
                .scalar => |ScalarType| try mutation.scalar(
                    ScalarType,
                    self.bytes,
                    element_start,
                    value,
                ),
                .structure => |ChildLayout| try mutation.inlineValue(
                    ChildLayout,
                    self.bytes,
                    element_start,
                    value,
                ),
                .array => unreachable,
            }
        }

        fn elementStart(
            self: Self,
            element_index: usize,
        ) AccessError!usize {
            // Check the complete inline extent before multiplying an index.
            try validation.inlineRange(
                self.bytes,
                self.array_start,
                Layout.wire_size,
                Layout.wire_alignment,
            );
            if (element_index >= element_count)
                return AccessError.OutOfBounds;
            return self.array_start + element_index * Element.wire_size;
        }
    };
}
