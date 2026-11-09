//! Checked local buffer access; opening one object does not verify its reachable graph.
//! Positions are relative to the complete frame, including any size prefix.
//! Helpers allocate nothing; returned payload slices borrow the supplied bytes.
//! Access this namespace as `flatzz.buffer_access`. Scalar range checks do not
//! enforce object alignment or schema presence; table/sequence helpers add their
//! local wire constraints. Full known-schema verification is a separate traversal.
//!
//! Example test body with `std` and `runtime = @import("flatzz")` imported:
//! ```zig
//! var bytes = [_]u8{ 0, 0, 0, 0 };
//! try runtime.buffer_access.writeScalar(u16, &bytes, 1, 513);
//! try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 0 }, &bytes);
//! try std.testing.expectEqual(
//!     @as(u16, 513),
//!     try runtime.buffer_access.readScalar(u16, &bytes, 1),
//! );
//! try std.testing.expectError(
//!     error.OutOfBounds,
//!     runtime.buffer_access.readScalar(u16, &bytes, 3),
//! );
//! ```
//! Expected result: an unaligned scalar round trip and a rejected truncated read; no output.
//! See the `flatzz` module overview for complete imports and a Zig 0.17.0 test command.
const std = @import("std");
const wire = @import("wire.zig");
const errors = @import("errors.zig");

const AccessError = errors.AccessError;

/// Byte interval described without computing a potentially overflowing end.
pub const Range = struct {
    /// Position relative to the frame, or an address for memory-overlap checks.
    start: usize,
    /// Number of bytes; zero-length intervals overlap nothing.
    size: usize,
};
/// Validated local table and vtable positions; no reachable fields are cached.
/// Obtain these through tableAt/referencedTable; structural edits invalidate cached positions.
pub const TableLayout = struct {
    /// Signed vtable-displacement slot relative to the complete frame.
    table_start: usize,
    /// Inline table body length, including its displacement slot.
    table_size: usize,
    /// Vtable-size slot relative to the complete frame.
    vtable_start: usize,
    /// Complete vtable length, including its two u16 header entries.
    vtable_size: usize,
    /// Inherited by child tables, including those read through offset vectors.
    header_size: usize = wire.root_offset_size,
};
/// Checked sequence payload positions, excluding its count and any terminator.
pub const SequenceLayout = struct {
    /// First payload byte relative to the complete frame.
    payload_start: usize,
    /// Declared number of values; string counts are UTF-8 byte counts.
    element_count: usize,
};

/// Protects the enclosing table and, when following a vector slot, its array.
/// This is local metadata protection, not graph-wide alias verification.
pub const Context = struct {
    /// Enclosing table whose inline body and vtable cannot contain child objects.
    table: ?TableLayout = null,
    /// Enclosing offset array; referenced payloads must follow its complete range.
    vector: ?Range = null,
    /// A union's parallel tag vector is protected without imposing ordering.
    /// Payloads must follow offset slots, but may precede the tag vector.
    protected: ?Range = null,
    /// Leading frame bytes that cannot be reused as object storage.
    header_size: usize = wire.root_offset_size,

    /// Reject overlap with this context's metadata and frame header.
    /// The caller separately checks the object's range against the byte slice.
    pub fn checkObject(self: Context, object: Range) AccessError!void {
        // Objects cannot reuse the root, prefix, or identifier bytes.
        if (object.start < self.header_size) return AccessError.InvalidBuffer;
        if (self.protected) |protected| {
            if (rangesOverlap(object, protected))
                return AccessError.InvalidBuffer;
        }
        if (self.table) |table| {
            if (rangesOverlap(
                object,
                .{ .start = table.table_start, .size = table.table_size },
            ) or
                rangesOverlap(
                    object,
                    .{ .start = table.vtable_start, .size = table.vtable_size },
                ))
                return AccessError.InvalidBuffer;
        }
        if (self.vector) |vector| {
            // Referenced objects must follow the whole offset array, not merely
            // their own slot. Range validation proved the addition safe.
            if (object.start < vector.start or object.start - vector.start < vector.size)
                return AccessError.InvalidBuffer;
        }
    }
};

/// Subtract before comparing so hostile sizes cannot overflow an end position.
/// Returns OutOfBounds for a range outside the buffer; an empty range at its end is valid.
pub fn checkRange(
    buffer_length: usize,
    range_start: usize,
    range_size: usize,
) AccessError!void {
    if (range_start > buffer_length or range_size > buffer_length - range_start)
        return AccessError.OutOfBounds;
}

/// Compare intervals without adding their ends; empty intervals never overlap.
pub fn rangesOverlap(first: Range, second: Range) bool {
    if (first.size == 0 or second.size == 0) return false;
    return if (first.start <= second.start)
        second.start - first.start < first.size
    else
        first.start - second.start < second.size;
}

/// Test actual memory overlap, including when slices use different frame bases.
pub fn overlaps(first_bytes: []const u8, second_bytes: []const u8) bool {
    return rangesOverlap(
        .{ .start = @intFromPtr(first_bytes.ptr), .size = first_bytes.len },
        .{ .start = @intFromPtr(second_bytes.ptr), .size = second_bytes.len },
    );
}

/// Decode a little-endian scalar after checking its byte range; no alignment required.
/// Unknown exhaustive-enum tags return InvalidBuffer. Schema presence is unchecked.
pub fn readScalar(
    comptime ScalarType: type,
    bytes: []const u8,
    scalar_start: usize,
) AccessError!ScalarType {
    const scalar_size = @sizeOf(wire.Bits(ScalarType));
    try checkRange(bytes.len, scalar_start, scalar_size);
    return wire.decode(ScalarType, bytes[scalar_start..][0..scalar_size]);
}

/// Encode a little-endian scalar after checking its byte range; no alignment required.
/// OutOfBounds leaves bytes unchanged. This does not create an absent schema field.
pub fn writeScalar(
    comptime ScalarType: type,
    bytes: []u8,
    scalar_start: usize,
    value: ScalarType,
) AccessError!void {
    const scalar_size = @sizeOf(wire.Bits(ScalarType));
    try checkRange(bytes.len, scalar_start, scalar_size);
    wire.encode(ScalarType, bytes[scalar_start..][0..scalar_size], value);
}

/// Checks only the marker, not schema validity. No size prefix is accepted.
/// A missing identifier has no separate wire flag: compare the expected bytes.
pub fn checkIdentifier(
    bytes: []const u8,
    expected_identifier: [wire.file_identifier_size]u8,
) AccessError!void {
    try checkRange(bytes.len, wire.file_identifier_start, wire.file_identifier_size);
    if (!std.mem.eql(
        u8,
        bytes[wire.file_identifier_start..wire.identified_header_size],
        &expected_identifier,
    )) return AccessError.IdentifierMismatch;
}

/// Validate one table's bounds, alignment, and disjoint vtable metadata.
/// Shared vtables may lie before or after their table. Fields and children remain
/// unchecked; callers opening an identified/prefixed frame protect its header.
pub fn tableAt(bytes: []const u8, table_start: usize) AccessError!TableLayout {
    // Every position is relative to the complete frame, even for nested tables.
    if (table_start < wire.root_offset_size or table_start % wire.table_header_size != 0)
        return AccessError.InvalidBuffer;
    const distance = try readScalar(i32, bytes, table_start);
    if (distance == 0) return AccessError.InvalidBuffer;
    // Avoid signed conversion of usize: a shared vtable may be before or after
    // its table, and even the most negative i32 displacement must be safe.
    const vtable_start = if (distance > 0) preceding_vtable_blk: {
        const magnitude: usize = @intCast(distance);
        if (magnitude > table_start) return AccessError.InvalidBuffer;
        break :preceding_vtable_blk table_start - magnitude;
    } else following_vtable_blk: {
        const magnitude: usize = @intCast(-@as(i64, distance));
        try checkRange(bytes.len, table_start, magnitude);
        break :following_vtable_blk table_start + magnitude;
    };
    if (vtable_start < wire.root_offset_size or vtable_start % wire.vtable_entry_size != 0)
        return AccessError.InvalidBuffer;
    const vtable_size = try readScalar(u16, bytes, vtable_start);
    const table_size = try readScalar(u16, bytes, vtable_start + wire.vtable_table_size_offset);
    // Complete headers and complete u16 entries are required before field lookup.
    if (vtable_size < wire.vtable_header_size or
        vtable_size % wire.vtable_entry_size != 0 or
        table_size < wire.table_header_size)
        return AccessError.InvalidBuffer;
    try checkRange(bytes.len, vtable_start, vtable_size);
    try checkRange(bytes.len, table_start, table_size);
    if (rangesOverlap(
        .{ .start = table_start, .size = table_size },
        .{ .start = vtable_start, .size = vtable_size },
    )) return AccessError.InvalidBuffer;
    return .{
        .table_start = table_start,
        .table_size = table_size,
        .vtable_start = vtable_start,
        .vtable_size = vtable_size,
    };
}

/// Expected inline size and alignment for one physical vtable field slot.
pub const FieldLayout = struct {
    /// Number of bytes required in the enclosing table body.
    size: usize,
    /// Null selects size, matching scalar and reference-slot wire alignment.
    alignment: ?usize = null,
};

/// Struct size and alignment differ; scalars and offset slots use equal values.
/// The complete inline value must remain within its enclosing table body.
/// Returns null for an absent/trimmed slot. Supply checked, current table metadata;
/// this lookup does not rerun all table/vtable validation performed by tableAt.
pub fn fieldPosition(
    bytes: []const u8,
    table: TableLayout,
    comptime field_id: usize,
    comptime layout: FieldLayout,
) AccessError!?usize {
    const field_alignment = comptime layout.alignment orelse layout.size;
    if (field_id >= wire.max_field_count) @compileError("field ID exceeds the maximum vtable size");
    const vtable_entry_offset = wire.vtable_header_size + wire.vtable_entry_size * field_id;
    // Older schemas and trimmed vtables legitimately lack later slots.
    if (vtable_entry_offset + wire.vtable_entry_size > table.vtable_size)
        return null;
    try checkRange(bytes.len, table.vtable_start, table.vtable_size);
    const field_offset = try readScalar(u16, bytes, table.vtable_start + vtable_entry_offset);
    if (field_offset == wire.absent_field_offset) return null;
    // A present field cannot overwrite the table's signed vtable displacement.
    if (field_offset < wire.table_header_size) return AccessError.InvalidBuffer;
    try checkRange(table.table_size, field_offset, layout.size);
    try checkRange(bytes.len, table.table_start, table.table_size);
    const field_start = table.table_start + field_offset;
    try inlineRange(bytes, field_start, layout.size, field_alignment);
    return field_start;
}

/// Validate before adding member offsets, including when views are constructed
/// directly. Alignment is measured relative to the complete FlatBuffer frame.
pub fn inlineRange(
    bytes: []const u8,
    value_start: usize,
    comptime value_size: usize,
    comptime value_alignment: usize,
) AccessError!void {
    comptime {
        if (value_size == 0 or !std.math.isPowerOfTwo(
            value_alignment,
        )) @compileError("invalid inline size or alignment");
    }
    try checkRange(bytes.len, value_start, value_size);
    if (value_start % value_alignment != 0) return AccessError.InvalidBuffer;
}

/// Follow an aligned forward u32 offset after checking its slot and displacement.
/// The target may be at the buffer end; the receiving object parser checks its size.
pub fn referenceTarget(
    bytes: []const u8,
    reference_start: usize,
) AccessError!usize {
    if (reference_start % wire.field_offset_size != 0)
        return AccessError.InvalidBuffer;
    const relative_offset = try readScalar(u32, bytes, reference_start);
    // A forward reference cannot point into its own offset slot.
    if (relative_offset < wire.field_offset_size)
        return AccessError.InvalidBuffer;
    try checkRange(bytes.len, reference_start, relative_offset);
    return reference_start + relative_offset;
}

/// Follow a reference and validate a sequence's count, payload, trailer, and context.
/// Element size/alignment must describe a supported nonzero wire layout. Empty
/// payloads need no element alignment. The trailer's contents are checked by callers.
/// This low-level helper does not validate its compile-time layout parameters.
pub fn sequenceAt(
    comptime element_size: usize,
    comptime element_alignment: usize,
    comptime trailer_size: usize,
    bytes: []const u8,
    context: Context,
    reference_start: usize,
) AccessError!SequenceLayout {
    const sequence_start = try referenceTarget(bytes, reference_start);
    if (sequence_start % wire.sequence_length_size != 0)
        return AccessError.InvalidBuffer;
    const element_count = try readScalar(u32, bytes, sequence_start);
    const payload_start = sequence_start + wire.sequence_length_size;
    // Empty vectors have no elements to align. C++ PreAlign skips zero-sized
    // payloads, so the unused payload address need not match element alignment.
    if (element_count != 0 and payload_start % element_alignment != 0)
        return AccessError.InvalidBuffer;
    // Divide before multiplying: counts are untrusted, also on 32-bit targets.
    if (element_count > (bytes.len - payload_start) / element_size)
        return AccessError.OutOfBounds;
    const payload_size = element_count * element_size;
    const payload_end = payload_start + payload_size;
    try checkRange(bytes.len, payload_end, trailer_size);
    try context.checkObject(.{
        .start = sequence_start,
        .size = wire.sequence_length_size + payload_size + trailer_size,
    });
    return .{ .payload_start = payload_start, .element_count = element_count };
}

/// Return borrowed UTF-8 payload bytes after checking its count and zero terminator.
/// Invalid offsets, metadata overlap, or malformed text return checked access errors.
pub fn stringAt(
    bytes: []const u8,
    context: Context,
    reference_start: usize,
) AccessError![]const u8 {
    const layout = try sequenceAt(
        @sizeOf(u8),
        @sizeOf(u8),
        wire.string_terminator_size,
        bytes,
        context,
        reference_start,
    );
    const string_size = layout.element_count + wire.string_terminator_size;
    return stringPayload(bytes[layout.payload_start..][0..string_size]);
}

/// Validate a bounded string including its zero terminator; return borrowed UTF-8 without it.
/// Empty input returns OutOfBounds; a nonzero terminator or invalid text returns InvalidBuffer.
/// Wire callers validate metadata separately; budgeted traversals charge before this scan.
pub fn stringPayload(terminated: []const u8) AccessError![]const u8 {
    if (terminated.len < wire.string_terminator_size) return AccessError.OutOfBounds;
    const payload = terminated[0 .. terminated.len - wire.string_terminator_size];
    if (terminated[payload.len] != wire.string_terminator)
        return AccessError.InvalidBuffer;
    // This runtime's preserved UTF-8 policy is stricter than C++ VerifyString.
    if (!std.unicode.utf8ValidateSlice(payload)) return AccessError.InvalidBuffer;
    return payload;
}

/// Follow a child table, retaining frame protections and allowing identical shared vtables.
/// Reject overlap with parent inline data, offset vectors, and partially shared metadata.
pub fn referencedTable(
    bytes: []const u8,
    context: Context,
    reference_start: usize,
) AccessError!TableLayout {
    const table_start = try referenceTarget(bytes, reference_start);
    var table = try tableAt(bytes, table_start);
    // Child vtables may precede their table, but cannot enter the frame header.
    if (table.vtable_start < context.header_size)
        return AccessError.InvalidBuffer;
    table.header_size = context.header_size;
    try context.checkObject(
        .{ .start = table.table_start, .size = table.table_size },
    );
    const vtable_range: Range = .{
        .start = table.vtable_start,
        .size = table.vtable_size,
    };
    if (context.table) |parent| {
        if (rangesOverlap(
            vtable_range,
            .{ .start = parent.table_start, .size = parent.table_size },
        ))
            return AccessError.InvalidBuffer;
        // Identical shared vtables are legal; partial metadata overlap is not.
        const shared_vtable = table.vtable_start == parent.vtable_start and
            table.vtable_size == parent.vtable_size;
        if (!shared_vtable and rangesOverlap(
            vtable_range,
            .{ .start = parent.vtable_start, .size = parent.vtable_size },
        ))
            return AccessError.InvalidBuffer;
    }
    if (context.vector) |vector| {
        if (rangesOverlap(vtable_range, vector))
            return AccessError.InvalidBuffer;
    }
    if (context.protected) |protected| {
        if (rangesOverlap(vtable_range, protected))
            return AccessError.InvalidBuffer;
    }
    return table;
}
