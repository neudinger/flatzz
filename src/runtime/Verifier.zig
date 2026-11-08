//! Explicit verification of all known schema fields, distinct from local views.
//! Shared references are counted on each visit; there is no position-only cache.
//! Verification borrows immutable bytes and allocates nothing. Initialize fresh
//! counters for a new traversal; failed traversals consume their work/object budget.
//! Do not mutate bytes or counters while a traversal is active.
//! C++ Verifier and flatcc generated traversal supply the architectural model.
//! https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/verifier.h
const wire = @import("wire.zig");
const buffer_access = @import("buffer_access.zig");
const sequence = @import("sequence.zig");
const framing = @import("framing.zig");
const unions = @import("unions.zig");
const table_view = @import("table_view.zig");
const errors = @import("errors.zig");

const Table = table_view.TableView(.read_only);
const VerifyError = errors.VerifyError;
const Self = @This();

/// Framing and traversal budgets, checked before recursive work or scans.
pub const Options = struct {
    /// Byte-input roots and stateful verifyRoot only; .first bounds one complete frame.
    /// Checked Table inputs retain the framing selected when they were opened.
    frame: framing.Options = .{},
    /// Limit active table depth; zero rejects the starting table, including nested inputs.
    max_depth: usize = 64,
    /// Tables, vectors and strings each consume one visit, including sharing.
    max_objects: usize = 1_000_000,
    /// Field visits plus declared object/payload bytes. Charge before scanning
    /// UTF-8 or iterating vectors, so huge counts cannot evade the work budget.
    max_work: usize = 64 * 1024 * 1024,
};

/// Borrowed complete frame; `verifyRoot` narrows it for `.first` framing.
bytes: []const u8,
/// Traversal configuration; keep unchanged after initialization.
options: Options,
/// Active recursive table depth, restored when a table visit returns.
depth: usize = 0,
/// Object visits already consumed, including repeated visits to shared data.
object_count: usize = 0,
/// Work budget already consumed; maintained at or below `options.max_work`.
work_count: usize = 0,

/// Borrow bytes and start with empty counters; traverse with verifyRoot or verifyTable.
/// No allocation or deinit is required. Bytes must remain valid and unchanged.
pub fn init(bytes: []const u8, options: Options) Self {
    return .{ .bytes = bytes, .options = options };
}

/// Verify a root from bytes or the reachable graph of a checked Table with fresh counters.
/// Byte inputs use options.frame; Table inputs retain their complete selected frame
/// and reuse local metadata without revalidation. Nested tables start at depth zero
/// and do not verify their parents. No allocation or deinit is required.
/// Success describes the known schema at this instant. Storage reuse or edits
/// through any alias invalidate it; checked access remains the public API.
/// SchemaType must expose `Schema.verifyFields`; malformed data, missing required
/// fields, and configured depth/object/work limits return the corresponding error.
pub fn verify(
    comptime SchemaType: type,
    source: anytype,
    options: Options,
) VerifyError!void {
    const table: Table = if (@TypeOf(source) == Table)
        source
    else
        try Table.from(source, .{ .options = options.frame });
    var verifier = init(table.bytes, options);
    try verifier.verifyTable(SchemaType, table);
}

/// Parse the selected frame and traverse its root using the existing counters.
/// `.first` narrows `bytes` to one frame. Errors may leave consumed budgets;
/// initialize a fresh verifier to retry rather than reusing partial traversal state.
pub fn verifyRoot(self: *Self, comptime SchemaType: type) VerifyError!void {
    const table = try Table.from(
        self.bytes,
        .{ .options = self.options.frame },
    );
    // Every recursive check must see only this frame, never trailing messages.
    self.bytes = table.bytes;
    try self.verifyTable(SchemaType, table);
}

/// Reserve work before scanning payloads; `WorkLimit` leaves this counter unchanged.
/// Schema callbacks use this for field visits. Counters must remain API-managed.
pub fn charge(self: *Self, work_size: usize) VerifyError!void {
    if (work_size > self.options.max_work - self.work_count)
        return VerifyError.WorkLimit;
    self.work_count += work_size;
}

fn visitObject(self: *Self) VerifyError!void {
    if (self.object_count >= self.options.max_objects)
        return VerifyError.ObjectLimit;
    self.object_count += 1;
}

/// Visit a table belonging to this exact byte slice, preserving the recursion depth.
/// Reject a different frame and check depth/object/work limits before its fields.
/// Use a checked table view; this does not revalidate a manually forged cached layout.
pub fn verifyTable(
    self: *Self,
    comptime SchemaType: type,
    table: Table,
) VerifyError!void {
    // Views from a different frame must never be mixed into this traversal.
    if (table.bytes.ptr != self.bytes.ptr or table.bytes.len != self.bytes.len)
        return VerifyError.InvalidBuffer;
    if (self.depth >= self.options.max_depth) return VerifyError.DepthLimit;
    try self.visitObject();
    try self.charge(table.layout.table_size + table.layout.vtable_size);
    self.depth += 1;
    defer self.depth -= 1;
    try SchemaType.Schema.verifyFields(self, table);
}

fn verifyString(
    self: *Self,
    context: buffer_access.Context,
    reference_start: usize,
) VerifyError!void {
    try self.visitObject();
    const layout = try buffer_access.sequenceAt(
        @sizeOf(u8),
        @sizeOf(u8),
        wire.string_terminator_size,
        self.bytes,
        context,
        reference_start,
    );
    const string_size = layout.element_count + wire.string_terminator_size;
    try self.charge(wire.sequence_length_size + string_size);
    _ = try buffer_access.stringPayload(self.bytes[layout.payload_start..][0..string_size]);
}

fn verifyUnion(
    self: *Self,
    comptime UnionType: type,
    location: unions.Location,
) VerifyError!void {
    const selected = try UnionType.check(self.bytes, location);
    switch (selected) {
        .none => {},
        inline else => |choice| switch (@field(UnionType.variants, @tagName(choice))) {
            .none => unreachable,
            .table => |Child| try self.verifyTable(Child, .{
                .bytes = self.bytes,
                .layout = try buffer_access.referencedTable(
                    self.bytes,
                    location.context,
                    location.reference_start.?,
                ),
            }),
            .string => try self.verifyString(location.context, location.reference_start.?),
            .structure => |Layout| {
                try self.visitObject();
                try self.charge(Layout.wire_size);
                try self.charge(Layout.work_size);
                const view = try UnionType.read(.read_only, self.bytes, location);
                try @field(view, @tagName(choice)).verify();
            },
        },
    }
}

/// Validate one schema descriptor's value and recursively visit referenced objects.
/// Schema callbacks charge the field visit separately. Missing required references,
/// malformed payloads, and traversal-budget failures propagate without rollback.
/// The table must retain this verifier's complete frame and a checked local layout.
pub fn verifyField(
    self: *Self,
    comptime FieldType: type,
    table: Table,
) VerifyError!void {
    switch (FieldType.kind) {
        .union_value => |UnionType| {
            const location = try unions.field(table, FieldType.field_ids);
            if (FieldType.required and location.tag == wire.union_none)
                return VerifyError.MissingRequiredField;
            try self.verifyUnion(UnionType, location);
        },
        .union_vector => |UnionType| {
            const vector = try table.readUnionVector(UnionType, FieldType.field_ids) orelse {
                if (FieldType.required) return VerifyError.MissingRequiredField;
                return;
            };
            try self.visitObject();
            try self.visitObject();
            // Charge separately: adding sizes of shared/hostile vectors could
            // overflow usize on a 32-bit target before the budget check.
            try self.charge(wire.sequence_length_size + vector.element_count);
            try self.charge(wire.sequence_length_size +
                vector.element_count * wire.field_offset_size);
            for (0..vector.element_count) |element_index|
                try self.verifyUnion(UnionType, try vector.element(element_index));
        },
        .scalar => |ValueType| {
            _ = try table.readField(ValueType, FieldType.wire_id, FieldType.default);
        },
        .structure => |Layout| {
            const structure = try table.readStruct(Layout, FieldType.wire_id) orelse {
                if (FieldType.required) return VerifyError.MissingRequiredField;
                return;
            };
            // Inline bytes are already charged with the parent table. Charge
            // scalar visits before recursive decoding; no referenced object or
            // table depth is added by a finite, compile-time struct layout.
            try self.charge(Layout.work_size);
            try structure.verify();
        },
        .string, .vector, .table => {
            const field_start = try table.fieldPosition(u32, FieldType.wire_id) orelse {
                if (FieldType.required) return VerifyError.MissingRequiredField;
                return;
            };
            switch (FieldType.kind) {
                .scalar, .structure, .union_value, .union_vector => unreachable,
                .string => try self.verifyString(table.context(), field_start),
                .table => |ChildSchema| {
                    const child: Table = .{
                        .bytes = self.bytes,
                        .layout = try buffer_access.referencedTable(
                            self.bytes,
                            table.context(),
                            field_start,
                        ),
                    };
                    try self.verifyTable(ChildSchema, child);
                },
                .vector => |ElementCodec| {
                    try self.visitObject();
                    const vector = try sequence.SequenceView(
                        ElementCodec,
                        .read_only,
                    ).fromReference(self.bytes, table.context(), field_start);
                    try self.charge(
                        wire.sequence_length_size + vector.element_count * ElementCodec.slot_size,
                    );
                    for (0..vector.element_count) |element_index| {
                        switch (ElementCodec.kind) {
                            .scalar => _ = try vector.get(element_index),
                            .structure => {
                                // Charge scalar/array member visits before
                                // scanning, including nested fixed arrays.
                                try self.charge(ElementCodec.Layout.work_size);
                                const structure = try vector.get(element_index);
                                try structure.verify();
                            },
                            .string => try self.verifyString(
                                vector.elementContext(),
                                try vector.elementStart(element_index),
                            ),
                            .table => try self.verifyTable(
                                ElementCodec.Schema,
                                try vector.get(element_index),
                            ),
                        }
                    }
                },
            }
        },
    }
}
