//! Per-table bookkeeping. Storage/alignment/finalization belong to Builder.
//! Open one context after constructing referenced children, add each physical
//! field at most once, then finalize through its generated schema or `endTable`.
//! The context borrows a stable builder address and requires no allocation/deinit.
const standard_library = @import("std");
const wire = @import("wire.zig");
const Builder = @import("Builder.zig");
const BuildError = @import("errors.zig").BuildError;
const unions = @import("unions.zig");
const validation = @import("validation.zig");

/// field_count is max physical wire ID + 1, including deprecated/synthetic slots.
/// It must fit the u16 vtable-size limit; invalid counts fail at compile time.
/// Go StartObject/EndObject and C++ StartTable/EndTable are the references.
/// https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/go/builder.go
pub fn TableBuilder(comptime field_count: usize) type {
    if (field_count > wire.max_field_count) @compileError(
        "vtable size must fit in u16",
    );
    return struct {
        const Self = @This();
        const vtable_size = wire.vtable_header_size + wire.vtable_entry_size * field_count;

        /// Borrowed stable builder address. Do not copy an active context.
        builder: *Builder,
        /// Completed-child boundary captured before this table begins.
        table_end: usize,
        /// Builder generation captured at init; stale contexts return InvalidState.
        context_generation: u64,
        /// null: untouched; zero: explicitly omitted. Both emit absent slots,
        /// but recording omissions lets duplicate additions fail consistently.
        field_offsets: [field_count]?u32 = @splat(null),

        /// Enter table construction from a ready builder without writing storage.
        /// InvalidState rejects nested tables and finished builders. This context
        /// borrows the builder until endTable or reset invalidates its generation.
        pub fn init(builder: *Builder) BuildError!Self {
            if (builder.state != .ready) return BuildError.InvalidState;
            builder.context_generation +%= 1;
            builder.state = .table;
            return .{
                .builder = builder,
                .table_end = builder.used(),
                .context_generation = builder.context_generation,
            };
        }

        fn checkActive(self: *const Self) BuildError!void {
            if (self.builder.state != .table or self.context_generation != self.builder.context_generation)
                return BuildError.InvalidState;
        }

        fn checkField(
            self: *const Self,
            comptime field_id: usize,
        ) BuildError!void {
            if (field_id >= field_count) @compileError(
                "field ID is outside this table",
            );
            try self.checkActive();
            if (self.field_offsets[field_id] != null)
                return BuildError.DuplicateField;
        }

        /// Scalar defaults may be omitted. Optional null is always omitted and
        /// optional zero/false always stored, independently of force_defaults.
        /// Omitting a value still records the slot for duplicate-field checks.
        pub fn addScalar(
            self: *Self,
            comptime ValueType: type,
            comptime field_id: usize,
            value: ValueType,
            comptime default: ValueType,
        ) BuildError!void {
            const ScalarType = wire.Scalar(ValueType);
            if (@typeInfo(ValueType) == .optional and default != null)
                @compileError("optional scalars must default to null");
            try self.checkField(field_id);
            const scalar_value = switch (@typeInfo(ValueType)) {
                .optional => value orelse {
                    self.field_offsets[field_id] = wire.absent_field_offset;
                    return;
                },
                else => scalar_value_blk: {
                    if (!self.builder.force_defaults and value == default) {
                        self.field_offsets[field_id] = wire.absent_field_offset;
                        return;
                    }
                    break :scalar_value_blk value;
                },
            };
            self.field_offsets[field_id] = try self.builder.prependScalar(
                ScalarType,
                scalar_value,
            );
        }

        /// Structs are inline values: encode inside the active table, without a
        /// separate child handle or a forward-reference slot. Null omits the
        /// field; present zero-valued structs are retained regardless of defaults.
        /// Present input must not alias builder storage. Capacity and alias failures
        /// leave the field unrecorded, so the caller may retry the addition.
        pub fn addStruct(
            self: *Self,
            comptime Layout: type,
            comptime field_id: usize,
            value: ?Layout.Value,
        ) BuildError!void {
            try self.checkField(field_id);
            const present = value orelse {
                self.field_offsets[field_id] = wire.absent_field_offset;
                return;
            };
            self.field_offsets[field_id] = try self.builder.prependStruct(
                Layout,
                present,
            );
        }

        /// Converts a child handle to the forward offset at its eventual slot.
        /// The child must have been completed by this builder before the context opened.
        /// Null records absence. Invalid handles and capacity failures leave the
        /// field unrecorded; the numeric handle cannot prove builder ownership.
        pub fn addOffset(
            self: *Self,
            comptime field_id: usize,
            offset: ?Builder.Offset,
        ) BuildError!void {
            try self.checkField(field_id);
            const child_offset = offset orelse {
                self.field_offsets[field_id] = wire.absent_field_offset;
                return;
            };
            try self.builder.checkOffset(child_offset, self.table_end);
            const required_bytes = wire.paddingFor(
                self.builder.used(),
                wire.field_offset_size,
            ) + wire.field_offset_size;
            try self.builder.ensureSpace(required_bytes);
            const relative_offset: u32 = @intCast(
                self.builder.used() + required_bytes - @backingInt(
                    child_offset,
                ),
            );
            self.field_offsets[field_id] = try self.builder.prependScalar(
                u32,
                relative_offset,
            );
        }

        /// Add a union after preflighting both slots, so failures write neither.
        /// Payload handles must precede this table. `none` omits its payload;
        /// `force_defaults` can retain its zero tag.
        pub fn addUnion(
            self: *Self,
            comptime UnionType: type,
            comptime field_ids: unions.FieldIds,
            value: UnionType.Value,
        ) BuildError!void {
            if (field_ids.tag == field_ids.value) @compileError(
                "union wire IDs must differ",
            );
            try self.checkField(field_ids.tag);
            try self.checkField(field_ids.value);
            const selected = UnionType.tag(value);
            const handle = UnionType.offset(value);
            var required_bytes: usize = 0;
            if (handle) |present| {
                try self.builder.checkOffset(present, self.table_end);
                required_bytes = wire.paddingFor(
                    self.builder.used(),
                    wire.field_offset_size,
                ) + wire.field_offset_size;
            }
            if (selected != .none or self.builder.force_defaults)
                required_bytes += @sizeOf(wire.UnionTag);
            try self.builder.ensureSpace(required_bytes);
            self.addOffset(field_ids.value, handle) catch unreachable;
            self.addScalar(
                UnionType.Tag,
                field_ids.tag,
                selected,
                .none,
            ) catch unreachable;
        }

        /// Atomically add parallel tag/value vector handles, or omit both with null.
        /// Handles must precede this table. State, duplicate-slot, offset, and
        /// capacity failures occur before either slot is written.
        pub fn addUnionVector(
            self: *Self,
            comptime field_ids: unions.FieldIds,
            handles: ?Builder.UnionVector,
        ) BuildError!void {
            if (field_ids.tag == field_ids.value) @compileError(
                "union wire IDs must differ",
            );
            try self.checkField(field_ids.tag);
            try self.checkField(field_ids.value);
            if (handles) |present| {
                try self.builder.checkOffset(present.tag, self.table_end);
                try self.builder.checkOffset(present.value, self.table_end);
                try self.builder.ensureSpace(wire.paddingFor(
                    self.builder.used(),
                    wire.field_offset_size,
                ) + wire.field_offset_size + wire.field_offset_size);
            }
            self.addOffset(
                field_ids.value,
                if (handles) |present| present.value else null,
            ) catch unreachable;
            self.addOffset(
                field_ids.tag,
                if (handles) |present| present.tag else null,
            ) catch unreachable;
        }

        /// Schema finalization checks pairs even when raw incremental operations
        /// supplied the slots. Invalid pairs return InvalidUnion; absent required
        /// values return MissingRequiredField. Full payload verification is separate.
        pub fn requireUnion(
            self: *const Self,
            comptime UnionType: type,
            comptime field_ids: unions.FieldIds,
            comptime required: bool,
            comptime vector: bool,
        ) BuildError!void {
            try self.checkActive();
            const tag_offset = self.field_offsets[field_ids.tag] orelse 0;
            const value_offset = self.field_offsets[field_ids.value] orelse 0;
            if (vector) {
                if ((tag_offset == 0) != (value_offset == 0))
                    return BuildError.InvalidUnion;
                if (tag_offset != 0) {
                    _ = unions.VectorView(UnionType, .read_only).fromReferences(
                        self.builder.buffer,
                        .{ .header_size = 0 },
                        self.builder.buffer.len - tag_offset,
                        self.builder.buffer.len - value_offset,
                    ) catch return BuildError.InvalidUnion;
                }
            } else {
                const raw_tag = if (tag_offset == 0)
                    wire.union_none
                else
                    self.builder.buffer[self.builder.buffer.len - tag_offset];
                const selected = UnionType.parseTag(raw_tag) catch
                    return BuildError.InvalidUnion;
                if ((selected == .none) != (value_offset == 0))
                    return BuildError.InvalidUnion;
                if (value_offset != 0) {
                    _ = validation.referenceTarget(
                        self.builder.buffer,
                        self.builder.buffer.len - value_offset,
                    ) catch return BuildError.InvalidUnion;
                }
            }
            if (required and value_offset == 0)
                return BuildError.MissingRequiredField;
        }

        /// Checks presence without writing. Schema finalizers supply required
        /// IDs; the raw context has no schema metadata. Null and explicit zero
        /// both describe an absent slot, rather than an empty referenced object.
        pub fn requireField(
            self: *const Self,
            comptime field_id: usize,
        ) BuildError!void {
            if (field_id >= field_count) @compileError(
                "field ID is outside this table",
            );
            try self.checkActive();
            if ((self.field_offsets[field_id] orelse wire.absent_field_offset) == wire.absent_field_offset)
                return BuildError.MissingRequiredField;
        }

        /// C++ EndTable / Go WriteVtable. Every check precedes writes. Vtable
        /// deduplication is deferred; retaining all physical slots is intentional.
        /// This raw finalizer does not check schema-required fields; generated
        /// and incremental schema users finalize through Schema.endTable.
        pub fn endTable(self: *Self) BuildError!Builder.Offset {
            try self.checkActive();
            const builder = self.builder;
            const padding = wire.paddingFor(
                builder.used(),
                wire.table_header_size,
            );
            const required_bytes = padding + wire.table_header_size + vtable_size;
            try builder.ensureSpace(required_bytes);
            const table_offset = builder.used() + padding + wire.table_header_size;
            const table_size = table_offset - self.table_end;
            // Table sizes and field positions are serialized in u16 vtable entries.
            if (table_size > standard_library.math.maxInt(
                u16,
            )) return BuildError.TableTooLarge;
            const table_start = builder.buffer.len - table_offset;
            const vtable_start = table_start - vtable_size;
            @memset(
                builder.buffer[table_start + wire.table_header_size .. builder.write_cursor],
                0,
            );
            wire.encode(
                i32,
                builder.buffer[table_start..][0..wire.table_header_size],
                @intCast(vtable_size),
            );
            wire.encode(
                u16,
                builder.buffer[vtable_start..][0..wire.vtable_entry_size],
                @intCast(vtable_size),
            );
            wire.encode(
                u16,
                builder.buffer[vtable_start + wire.vtable_table_size_offset ..][0..wire.vtable_entry_size],
                @intCast(table_size),
            );
            for (self.field_offsets, 0..) |field_offset, field_id| {
                const field_end_offset = field_offset orelse wire.absent_field_offset;
                const relative_offset: u16 = if (field_end_offset == wire.absent_field_offset)
                    wire.absent_field_offset
                else
                    @intCast(table_offset - field_end_offset);
                const entry_start = vtable_start + wire.vtable_header_size + field_id * wire.vtable_entry_size;
                wire.encode(
                    u16,
                    builder.buffer[entry_start..][0..wire.vtable_entry_size],
                    relative_offset,
                );
            }
            builder.write_cursor = vtable_start;
            builder.state = .ready;
            builder.completed_tables += 1;
            return @fromBackingInt(@intCast(table_offset));
        }
    };
}
