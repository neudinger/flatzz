//! One implementation for borrowed read-only and mutable table capabilities.
//! C++ Table / Go Table{Bytes, Pos}, with checked local metadata cached once.
//! https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/table.h
const wire = @import("wire.zig");
const validation = @import("validation.zig");
const sequence = @import("sequence.zig");
const mutation = @import("mutation.zig");
const errors = @import("errors.zig");
const framing = @import("framing.zig");
const StructView = @import("struct_view.zig").StructView;
const unions = @import("unions.zig");

/// Compile-time capability of a borrowed view; mutable views still perform checked access.
pub const Access = enum {
    /// Read operations accept immutable storage; mutation methods reject this mode at compile time.
    read_only,
    /// Read operations accept mutable storage and permit supported in-place updates.
    mutable,
};

/// Positions are runtime offsets relative to the complete frame, not child slices.
pub const Source = union(enum) {
    /// Follows the root offset without checking a file identifier.
    root,
    /// Follow an ordinary root and require these four identifier bytes.
    identified_root: [wire.file_identifier_size]u8,
    /// Parse the selected framing, identifier, and exact/first-frame policy.
    framed_root: framing.Options,
    /// Opens an ordinary frame at a known position; children inherit framing.
    position: usize,
};

/// Create a capability-specific table view borrowing one complete input frame.
/// Opening a table validates local metadata; use a schema verifier to traverse fields.
/// No allocator or cleanup is required; retain the backing bytes without structural edits.
pub fn TableView(comptime access: Access) type {
    return struct {
        const Self = @This();
        const Bytes = switch (access) {
            .read_only => []const u8,
            .mutable => []u8,
        };

        /// Complete selected frame, including its header; child offsets share this base.
        bytes: Bytes,
        /// Checked local table/vtable layout; structural edits invalidate cached offsets.
        layout: validation.TableLayout,

        /// Borrows one complete FlatBuffer frame, retaining any size prefix.
        /// With .first, input[self.bytes.len..] is the remaining input.
        /// Metadata validation is local, not schema verification. Aliases must
        /// not change structure; storage reset/reallocation invalidates the view.
        /// Source is not comptime: positions may come from decoded offsets.
        pub fn from(bytes: Bytes, source: Source) errors.AccessError!Self {
            const frame = switch (source) {
                .root => try framing.parse(bytes, .{}),
                .identified_root => |identifier| try framing.parse(
                    bytes,
                    .{ .identifier = identifier },
                ),
                .framed_root => |options| try framing.parse(bytes, options),
                .position => framing.Layout{ .frame_size = bytes.len },
            };
            const frame_bytes = bytes[0..frame.frame_size];
            const table_start = switch (source) {
                .position => |table_position| table_position,
                else => try validation.referenceTarget(
                    frame_bytes,
                    frame.root_offset_start,
                ),
            };
            // Neither the table nor its vtable may overlap the selected header.
            if (table_start < frame.header_size)
                return errors.AccessError.InvalidBuffer;
            var layout = try validation.tableAt(frame_bytes, table_start);
            if (layout.vtable_start < frame.header_size)
                return errors.AccessError.InvalidBuffer;
            layout.header_size = frame.header_size;
            return .{ .bytes = frame_bytes, .layout = layout };
        }

        /// Parent metadata ranges that child references must not reinterpret.
        pub fn context(self: Self) validation.Context {
            return .{
                .table = self.layout,
                .header_size = self.layout.header_size,
            };
        }

        /// Returns null for absent/trimmed slots. Type determines width/alignment.
        pub fn fieldPosition(
            self: Self,
            comptime ScalarType: type,
            comptime field_id: usize,
        ) errors.AccessError!?usize {
            return validation.fieldPosition(
                self.bytes,
                self.layout,
                field_id,
                .{ .size = @sizeOf(wire.Bits(ScalarType)) },
            );
        }

        /// Copy a present scalar or return its schema default when the slot is absent.
        /// Optional scalar defaults must be null; invalid encodings return an access error.
        pub fn readField(
            self: Self,
            comptime ValueType: type,
            comptime field_id: usize,
            comptime default: ValueType,
        ) errors.AccessError!ValueType {
            const ScalarType = wire.Scalar(ValueType);
            switch (@typeInfo(ValueType)) {
                .optional => if (default != null) @compileError(
                    "optional scalars must default to null",
                ),
                else => {},
            }
            const field_start = try self.fieldPosition(
                ScalarType,
                field_id,
            ) orelse return default;
            return try validation.readScalar(
                ScalarType,
                self.bytes,
                field_start,
            );
        }

        /// Borrow a present UTF-8 string without its prefix/terminator; return null for absence.
        /// Empty strings remain present. Bounds, terminator, and UTF-8 are checked.
        pub fn readString(
            self: Self,
            comptime field_id: usize,
        ) errors.AccessError!?[]const u8 {
            const field_start = try self.fieldPosition(
                u32,
                field_id,
            ) orelse return null;
            return try validation.stringAt(
                self.bytes,
                self.context(),
                field_start,
            );
        }

        /// Borrow a present vector with this table's access capability; return null for absence.
        /// Extent and alignment are checked now; reference elements are checked lazily.
        pub fn readVector(
            self: Self,
            comptime ElementCodec: type,
            comptime field_id: usize,
        ) errors.AccessError!?sequence.SequenceView(ElementCodec, access) {
            const field_start = try self.fieldPosition(
                u32,
                field_id,
            ) orelse return null;
            return try sequence.SequenceView(ElementCodec, access).fromReference(
                self.bytes,
                self.context(),
                field_start,
            );
        }

        /// Read paired union slots, checking tag/payload agreement before borrowing the alternative.
        /// Unknown tags fail; absent optional values produce the `.none` variant.
        pub fn readUnion(
            self: Self,
            comptime UnionType: type,
            comptime field_ids: unions.FieldIds,
        ) errors.AccessError!UnionType.View(access) {
            return UnionType.read(
                access,
                self.bytes,
                try unions.field(self, field_ids),
            );
        }

        /// Borrow paired tag/payload vectors; either both slots are absent or both are present.
        /// Counts and ranges are checked now; alternatives are checked lazily on `get`.
        pub fn readUnionVector(
            self: Self,
            comptime UnionType: type,
            comptime field_ids: unions.FieldIds,
        ) errors.AccessError!?unions.VectorView(UnionType, access) {
            const tag_start = try self.fieldPosition(u32, field_ids.tag);
            const value_start = try self.fieldPosition(u32, field_ids.value);
            if ((tag_start == null) != (value_start == null))
                return errors.AccessError.InvalidUnion;
            if (tag_start == null) return null;
            return try unions.VectorView(UnionType, access).fromReferences(
                self.bytes,
                self.context(),
                tag_start.?,
                value_start.?,
            );
        }

        /// Structs occupy the field itself, without following a u32 reference.
        /// Nested struct views preserve this table's mutable/read-only access.
        pub fn readStruct(
            self: Self,
            comptime Layout: type,
            comptime field_id: usize,
        ) errors.AccessError!?StructView(Layout, access) {
            const struct_start = try validation.fieldPosition(
                self.bytes,
                self.layout,
                field_id,
                .{
                    .size = Layout.wire_size,
                    .alignment = Layout.wire_alignment,
                },
            ) orelse return null;
            return try StructView(Layout, access).from(self.bytes, struct_start);
        }

        /// Replace a present inline struct; return false for absence and reject clearing with null.
        /// Requires mutable access at compile time; failures leave bytes unchanged.
        pub fn mutateStruct(
            self: Self,
            comptime Layout: type,
            comptime field_id: usize,
            value: ?Layout.Value,
        ) errors.MutationError!bool {
            comptime requireMutable();
            const current = try self.readStruct(Layout, field_id) orelse
                return false;
            try current.replace(value orelse
                return errors.MutationError.CannotClearField);
            return true;
        }

        /// Mutable parents retain the capability when accessing a child table.
        pub fn readTable(
            self: Self,
            comptime field_id: usize,
        ) errors.AccessError!?Self {
            const field_start = try self.fieldPosition(
                u32,
                field_id,
            ) orelse return null;
            return .{
                .bytes = self.bytes,
                .layout = try validation.referencedTable(
                    self.bytes,
                    self.context(),
                    field_start,
                ),
            };
        }

        /// All mutations preserve storage size and return false for absence.
        /// They provide local checks and failure atomicity, not proof that every
        /// cross-typed alias in a malicious graph remains schema-valid.
        pub fn mutateField(
            self: Self,
            comptime ValueType: type,
            comptime field_id: usize,
            value: ValueType,
        ) errors.MutationError!bool {
            comptime requireMutable();
            const field_start = try self.fieldPosition(
                wire.Scalar(ValueType),
                field_id,
            ) orelse return false;
            try mutation.scalar(ValueType, self.bytes, field_start, value);
            return true;
        }

        /// Replace a present string with equal-length UTF-8 bytes; return false for absence.
        /// Requires mutable access, rejects clearing, and allows overlapping source bytes.
        /// Failures leave bytes unchanged.
        pub fn mutateString(
            self: Self,
            comptime field_id: usize,
            value: ?[]const u8,
        ) errors.MutationError!bool {
            comptime requireMutable();
            const current = try self.readString(field_id) orelse return false;
            try mutation.string(self.bytes, current, value);
            return true;
        }

        /// Replace a present vector without changing its element count; return false for absence.
        /// Null cannot clear it; string lengths must also match. Mutable access is required,
        /// table replacement fails at compile time, and failed preflight leaves bytes unchanged.
        pub fn mutateVector(
            self: Self,
            comptime ElementCodec: type,
            comptime field_id: usize,
            value: ?[]const sequence.NativeValue(ElementCodec),
        ) errors.MutationError!bool {
            comptime requireMutable();
            const current = try self.readVector(
                ElementCodec,
                field_id,
            ) orelse return false;
            const replacement = value orelse
                return errors.MutationError.CannotClearField;
            if (replacement.len != current.element_count)
                return errors.MutationError.LengthMismatch;
            switch (ElementCodec.kind) {
                .scalar => wire.encodeSlice(
                    ElementCodec.Value,
                    self.bytes[current.payload_start..][0 .. current.element_count * ElementCodec.slot_size],
                    replacement,
                ),
                .string => try mutation.stringVector(
                    self.bytes,
                    current.asReadOnly(),
                    replacement,
                ),
                .structure => try mutation.structVector(
                    ElementCodec.Layout,
                    self.bytes,
                    current.payload_start,
                    replacement,
                ),
                .table => @compileError(
                    "table vector replacement requires rebuilding",
                ),
            }
            return true;
        }

        fn requireMutable() void {
            switch (access) {
                .read_only => @compileError("mutation requires a MutableTable"),
                .mutable => {},
            }
        }
    };
}
