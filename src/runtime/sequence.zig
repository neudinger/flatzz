//! FlatBuffers vectors are borrowed sequences with compile-time element codecs.
//! Strings use the same local layout validation and expose their UTF-8 bytes.
//! Views allocate nothing and borrow their complete input frame; reset, growth,
//! or structural mutation of that storage invalidates existing views.
//!
//! Example inside a test with `std = @import("std")` and
//! `runtime = @import("flatzz")` imported:
//! ```zig
//! const values: runtime.VectorView(runtime.ScalarCodec(u16), .read_only) = .{
//!     .bytes = &.{ 42, 0, 7, 0 },
//!     .payload_start = 0,
//!     .element_count = 2,
//! };
//! const second = try values.get(1);
//! try std.testing.expectEqual(@as(u16, 7), second);
//! ```
//! Expected result: `second == 7`; nothing is printed. This manually assembled
//! scalar payload has no vector count prefix; use `fromReference` for wire vectors.
const wire = @import("wire.zig");
const buffer_access = @import("buffer_access.zig");
const errors = @import("errors.zig");
const table_view = @import("table_view.zig");
const struct_view = @import("struct_view.zig");

const AccessError = errors.AccessError;
const TableView = table_view.TableView;
const Access = table_view.Access;
const StructView = struct_view.StructView;

/// Encoding of one vector slot; strings and tables contain forward offsets.
pub const ElementKind = enum {
    /// Copied fixed-width scalar value.
    scalar,
    /// Borrowed inline struct.
    structure,
    /// Offset to a checked UTF-8 string.
    string,
    /// Offset to a child table with locally checked metadata.
    table,
};

/// The native replacement type differs from the borrowed struct element view.
pub fn NativeValue(comptime ElementCodec: type) type {
    return switch (ElementCodec.kind) {
        .structure => ElementCodec.Layout.Value,
        else => ElementCodec.Value,
    };
}

/// Inline struct vector codec; rejects non-struct layouts at compile time.
pub fn StructCodec(comptime StructLayout: type) type {
    if (StructLayout.layout_kind != .structure)
        @compileError("struct vectors require a struct layout");
    return struct {
        /// Borrowed read-only element returned by the codec directly.
        pub const Value = StructView(StructLayout, .read_only);
        /// Inline wire layout shared by element access, construction, and verification.
        pub const Layout = StructLayout;
        /// Selects inline struct handling instead of following a reference.
        pub const kind: ElementKind = .structure;
        /// Bytes occupied by one complete padded inline struct.
        pub const slot_size = Layout.wire_size;
        /// Required alignment of the first element, in bytes.
        pub const slot_alignment = Layout.wire_alignment;

        /// Borrow one range-checked inline element; vector containment is checked by the caller.
        pub fn read(
            bytes: []const u8,
            _: buffer_access.Context,
            element_start: usize,
        ) AccessError!Value {
            // The vector already contains the element; do not follow an offset
            // or reject its intentional overlap with the vector payload.
            return Value.from(bytes, element_start);
        }
    };
}

/// Minimal codec contract: Value, slot_size, slot_alignment, and checked read.
/// Like std.crypto.auth.hmac.Hmac(Hash), composition specializes the algorithm;
/// it does not require codecs to own mutation, allocation, or graph traversal.
pub fn ScalarCodec(comptime ScalarType: type) type {
    return struct {
        /// Copied native scalar result.
        pub const Value = ScalarType;
        /// Selects fixed-width little-endian scalar handling.
        pub const kind: ElementKind = .scalar;
        /// Serialized width of one scalar element, in bytes.
        pub const slot_size = @sizeOf(wire.Bits(ScalarType));
        /// Natural alignment of an element slot, in bytes.
        pub const slot_alignment = slot_size;

        /// Copy one bounds-checked scalar; the caller enforces slot alignment.
        /// Unknown exhaustive-enum tags return InvalidBuffer.
        pub fn read(
            bytes: []const u8,
            _: buffer_access.Context,
            element_start: usize,
        ) AccessError!Value {
            return buffer_access.readScalar(ScalarType, bytes, element_start);
        }
    };
}

/// Codec for forward string offsets with bounds, terminator, and UTF-8 validation.
pub const StringCodec = struct {
    /// Borrowed UTF-8 payload excluding the count prefix and zero terminator.
    pub const Value = []const u8;
    /// Selects referenced string validation.
    pub const kind: ElementKind = .string;
    /// Width of one forward-offset slot, in bytes.
    pub const slot_size = wire.field_offset_size;
    /// Offset slot alignment, in bytes.
    pub const slot_alignment = slot_size;

    /// Follow a checked slot and borrow its UTF-8 payload within the supplied context.
    pub fn read(
        bytes: []const u8,
        context: buffer_access.Context,
        element_start: usize,
    ) AccessError!Value {
        return buffer_access.stringAt(bytes, context, element_start);
    }
};

/// ChildSchema is kept as a named type; its fields are resolved only when a
/// verifier traverses an actual child. Recursive schemas stay finite at comptime.
pub fn TableCodec(comptime ChildSchema: type) type {
    return struct {
        /// Child table view borrowing the complete input frame.
        pub const Value = TableView(.read_only);
        /// Named child adapter resolved lazily during full schema verification.
        pub const Schema = ChildSchema;
        /// Selects forward table-offset handling.
        pub const kind: ElementKind = .table;
        /// Width of one child table offset, in bytes.
        pub const slot_size = wire.field_offset_size;
        /// Natural alignment of an element slot, in bytes.
        pub const slot_alignment = slot_size;

        /// Follow one child offset and check local table metadata; does not traverse its fields.
        pub fn read(
            bytes: []const u8,
            context: buffer_access.Context,
            element_start: usize,
        ) AccessError!Value {
            return .{
                .bytes = bytes,
                .layout = try buffer_access.referencedTable(bytes, context, element_start),
            };
        }
    };
}

/// Create a borrowed vector type; invalid codec size/alignment fails at compile time.
/// Mutable vector storage permits borrowed mutable struct elements; other codecs
/// retain their existing result types and reference-mutation contracts.
pub fn SequenceView(
    comptime ElementCodec: type,
    comptime access: Access,
) type {
    comptime {
        if (ElementCodec.slot_size == 0 or ElementCodec.slot_alignment == 0 or
            ElementCodec.slot_alignment & (ElementCodec.slot_alignment - 1) != 0 or
            ElementCodec.slot_size % ElementCodec.slot_alignment != 0)
            @compileError("invalid sequence element layout");
    }
    return struct {
        const Self = @This();
        /// Compile-time slot decoder and wire layout used by this sequence.
        pub const Codec = ElementCodec;
        const Bytes = table_view.ByteSlice(access);
        /// Element result; inline structs inherit this sequence's access capability.
        pub const ElementView = switch (ElementCodec.kind) {
            .structure => StructView(ElementCodec.Layout, access),
            else => ElementCodec.Value,
        };

        /// The full frame is retained for shared objects and signed vtables.
        /// Storage reuse, reallocation, or structural edits invalidate this view.
        bytes: Bytes,
        /// Byte offset of the first element, relative to the complete frame.
        payload_start: usize,
        /// Element count, not a byte length.
        element_count: usize,
        /// Parent ranges protected while following element references.
        context: buffer_access.Context = .{},

        /// Follow a vector offset and validate its prefix, extent, and alignment.
        /// Element references are checked lazily by `get`; no allocation occurs.
        pub fn fromReference(
            bytes: Bytes,
            context: buffer_access.Context,
            reference_start: usize,
        ) AccessError!Self {
            const layout = try buffer_access.sequenceAt(
                ElementCodec.slot_size,
                ElementCodec.slot_alignment,
                0,
                bytes,
                context,
                reference_start,
            );
            return .{
                .bytes = bytes,
                .payload_start = layout.payload_start,
                .element_count = layout.element_count,
                .context = context,
            };
        }

        /// Drop mutation capability while continuing to borrow the same frame and context.
        pub fn asReadOnly(self: Self) SequenceView(ElementCodec, .read_only) {
            return .{
                .bytes = self.bytes,
                .payload_start = self.payload_start,
                .element_count = self.element_count,
                .context = self.context,
            };
        }

        /// Checks even manually assembled/truncated views before arithmetic.
        pub fn elementStart(
            self: Self,
            element_index: usize,
        ) AccessError!usize {
            if (self.payload_start > self.bytes.len or
                self.element_count >
                    (self.bytes.len - self.payload_start) / ElementCodec.slot_size or
                element_index >= self.element_count)
                return AccessError.OutOfBounds;
            if (self.payload_start % ElementCodec.slot_alignment != 0)
                return AccessError.InvalidBuffer;
            return self.payload_start + element_index * ElementCodec.slot_size;
        }

        /// Call after elementStart has checked the full payload. Include the
        /// count prefix so a child vtable cannot reinterpret vector metadata.
        pub fn elementContext(self: Self) buffer_access.Context {
            var context = self.context;
            const prefix_size = @min(self.payload_start, wire.sequence_length_size);
            context.vector = .{
                .start = self.payload_start - prefix_size,
                .size = prefix_size + self.element_count * ElementCodec.slot_size,
            };
            return context;
        }

        /// Reference elements are checked lazily. Opening a vector alone is not
        /// verification of its elements; use a schema verifier for that contract.
        pub fn get(
            self: Self,
            element_index: usize,
        ) AccessError!ElementView {
            const element_start = try self.elementStart(element_index);
            return switch (ElementCodec.kind) {
                .structure => ElementView.from(self.bytes, element_start),
                else => ElementCodec.read(self.bytes, self.elementContext(), element_start),
            };
        }
    };
}
