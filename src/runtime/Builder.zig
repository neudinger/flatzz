//! Fixed-capacity backward storage shared by all table layouts.
//! C++ FlatBufferBuilder/vector_downward; Go Builder; flatcc builder operations.
//! Children precede parents; handles are distances from the usable storage end.
//! The caller owns the aligned storage; construction performs no allocation.
//! Keep the builder at a stable address while a TableBuilder borrows it. Reset
//! invalidates every handle and view, and later writes can overwrite old bytes.
//!
//! Example inside a test with `std = @import("std")` and
//! `flatzz = @import("flatzz")` imported:
//! ```zig
//! var storage: [128]u8 align(flatzz.storage_alignment) = undefined;
//! var builder = flatzz.Builder.init(&storage);
//! const label = try builder.createString("sensor");
//! var table = try flatzz.TableBuilder(1).init(&builder);
//! try table.addOffset(0, label);
//! const root = try table.endTable();
//! const bytes = try builder.finish(root, .ordinary);
//! const view = try flatzz.Table.from(bytes, .root);
//! const name = try view.readString(0);
//! try std.testing.expectEqualStrings("sensor", name.?);
//! ```
//! Expected result: `name` is the borrowed string `"sensor"`; nothing is printed.
//! https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/flatbuffer_builder.h
//! https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/go/builder.go
//! https://github.com/dvidelabs/flatcc/blob/e1272290b486fdd7fdc60f061036b7a18c468dc7/include/flatcc/flatcc_builder.h
const standard_library = @import("std");
const wire = @import("wire.zig");
const validation = @import("validation.zig");
const Self = @This();
/// Construction failures; capacity and input checks precede writes.
pub const Error = @import("errors.zig").BuildError;
const sequence_length_size = wire.sequence_length_size;
const string_terminator_size = wire.string_terminator_size;
const field_offset_size = wire.field_offset_size;

/// Conservative implementation limit, not a limit of every FlatBuffers variant.
pub const max_buffer_size = standard_library.math.maxInt(i32);
/// Handles must originate from this builder since its last reset. Like Go
/// UOffsetT/C++ Offset, the representation does not encode ownership or type.
pub const Offset = enum(u32) { _ };
/// Construction phase; begin another table or sequence only in `ready`.
pub const State = enum {
    /// Completed children can be followed by more objects or root finalization.
    ready,
    /// One TableBuilder owns the active table.
    table,
    /// A root frame was emitted; reset before constructing more objects.
    finished,
};

/// 32-bit framing, optionally with a schema's file identifier.
/// Selected at compile time; object construction is independent of framing.
pub const FinishOptions = union(enum) {
    /// Root offset followed by the completed objects.
    ordinary,
    /// Ordinary framing with the schema's four-byte file identifier.
    identifier: [wire.file_identifier_size]u8,
    /// Prefix the ordinary frame with its following byte count.
    size_prefixed,
    /// Prefix an identified frame with its following byte count.
    size_prefixed_identifier: [wire.file_identifier_size]u8,
};

/// Borrowed storage: no hidden allocation or deinit. Never copy an active builder.
buffer: []align(wire.storage_alignment) u8,
/// Free prefix ends here; the suffix contains completed and active objects.
write_cursor: usize,
/// Strongest wire alignment used so far; finish preserves it in the root frame.
min_alignment: usize = wire.root_offset_size,
/// Current construction phase; transitions are managed by the builder APIs.
state: State = .ready,
/// Invalidates stale per-table contexts across end/start and reset transitions.
context_generation: u64 = 0,
/// Number of completed tables since reset; finalization requires at least one.
completed_tables: usize = 0,
/// Like C++ ForceDefaults; absent/null values never gain storage implicitly.
force_defaults: bool = false,

/// Borrow storage, rounding usable capacity down to `storage_alignment` bytes.
/// Storage must outlive this builder and every returned frame; no deinit is needed.
pub fn init(storage: []align(wire.storage_alignment) u8) Self {
    const usable_capacity = standard_library.mem.alignBackward(
        usize,
        storage.len,
        wire.storage_alignment,
    );
    return .{
        .buffer = storage[0..usable_capacity],
        .write_cursor = usable_capacity,
    };
}

/// Go Reset / C++ Clear: reuse storage and invalidate every handle and view.
/// Preserve `force_defaults` and return to `ready` without clearing storage.
pub fn reset(self: *Self) void {
    const force_defaults = self.force_defaults;
    const next_generation = self.context_generation +% 1;
    self.* = init(self.buffer);
    self.force_defaults = force_defaults;
    self.context_generation = next_generation;
}

/// Copy UTF-8 bytes into a present string object, including for an empty value.
/// Reject an active/finished builder, invalid UTF-8, or insufficient capacity.
/// Input may borrow builder storage; directional copying preserves overlap.
pub fn createString(self: *Self, value: []const u8) Error!Offset {
    return self.createSequence(u8, .string, value);
}

/// Union structs are independent referenced objects, not inline table fields.
/// Copy the value into storage; reject storage-aliasing aggregates before writes.
pub fn createStruct(
    self: *Self,
    comptime Layout: type,
    value: Layout.Value,
) Error!Offset {
    if (self.state != .ready) return Error.InvalidState;
    return @fromBackingInt(try self.prependStruct(Layout, value));
}

/// Parallel tag and payload-offset vectors produced by `createUnionVector`.
pub const UnionVector = struct {
    /// Handle of the byte-tag vector.
    tag: Offset,
    /// Handle of the payload-offset vector, including zero slots for `none`.
    value: Offset,
};

/// Two vectors, one atomic preflight. NONE emits a literal zero offset; normal
/// offset vectors continue to reject null handles. No scratch allocation.
/// Input must not alias builder storage, and payload handles must be completed
/// children of this builder. Input/state/capacity failures leave construction intact.
pub fn createUnionVector(
    self: *Self,
    comptime UnionType: type,
    values: []const UnionType.Value,
) Error!UnionVector {
    if (self.state != .ready) return Error.InvalidState;
    const pair_size = field_offset_size + @sizeOf(wire.UnionTag);
    const prefixes = sequence_length_size + sequence_length_size;
    const maximum_padding = (field_offset_size - 1) + (sequence_length_size - 1);
    if (values.len > (max_buffer_size - prefixes - maximum_padding) / pair_size)
        return Error.BufferTooLarge;
    const payload_size = values.len * field_offset_size;
    const value_padding = wire.paddingFor(
        self.used() + payload_size,
        field_offset_size,
    );
    const value_size = sequence_length_size + payload_size + value_padding;
    const tag_padding = wire.paddingFor(
        self.used() + value_size + values.len,
        sequence_length_size,
    );
    const tag_size = sequence_length_size + values.len + tag_padding;
    const required_bytes = value_size + tag_size;
    if (self.used() > max_buffer_size - required_bytes)
        return Error.BufferTooLarge;
    try self.ensureSpace(required_bytes);
    if (validation.overlaps(
        self.buffer,
        standard_library.mem.sliceAsBytes(values),
    ))
        return Error.AliasedInput;
    for (values) |value| {
        if (UnionType.offset(value)) |handle|
            try self.checkOffset(handle, self.used());
    }
    const values_start = self.write_cursor - value_size;
    const values_payload = values_start + sequence_length_size;
    const tags_start = values_start - tag_size;
    const tags_payload = tags_start + sequence_length_size;
    for (values, 0..) |value, element_index| {
        const reference_start = values_payload + element_index * field_offset_size;
        self.encodeOffset(reference_start, UnionType.offset(value));
    }
    const value_handle = self.finishSequence(
        values_start,
        values_payload + payload_size,
        values.len,
        field_offset_size,
    );
    for (values, 0..) |value, element_index| {
        self.buffer[tags_payload + element_index] = @backingInt(UnionType.tag(
            value,
        ));
    }
    const tag_handle = self.finishSequence(
        tags_start,
        tags_payload + values.len,
        values.len,
        sequence_length_size,
    );
    return .{ .tag = tag_handle, .value = value_handle };
}

/// Copy scalar values into a present vector; an empty slice remains present.
/// Supported element types follow `wire.Bits`. Input may borrow builder storage.
/// State, count, and capacity failures leave construction unchanged.
pub fn createVector(
    self: *Self,
    comptime ElementType: type,
    values: []const ElementType,
) Error!Offset {
    return self.createSequence(ElementType, .vector, values);
}

/// Contiguous inline structs, each including its wire padding. This returns a
/// vector handle; individual elements are never built as referenced objects.
/// The builder must be ready, and input must not alias its storage. Count,
/// capacity, and alias failures leave construction unchanged.
pub fn createStructVector(
    self: *Self,
    comptime Layout: type,
    values: []const Layout.Value,
) Error!Offset {
    if (Layout.layout_kind != .structure)
        @compileError("struct vectors require a struct layout");
    return self.createSequence(Layout, .structure, values);
}

/// Shared string, scalar-vector, and struct-vector placement.
/// Empty values are present. No table may be active during construction.
/// The handle belongs to this builder until reset. Children are built first.
/// Go CreateString/StartVector/EndVector; C++ CreateString/CreateVector.
/// Both count and element alignment matter: for u64/f64 the payload is
/// aligned to eight bytes, with the four-byte count immediately before it.
/// UTF-8/terminator checks apply only to strings. No allocation is needed.
/// https://flatbuffers.dev/internals/#strings-and-vectors
fn createSequence(
    self: *Self,
    comptime Element: type,
    comptime kind: enum { string, vector, structure },
    values: []const switch (kind) {
        .structure => Element.Value,
        else => Element,
    },
) Error!Offset {
    if (self.state != .ready) return Error.InvalidState;
    const element_size = comptime switch (kind) {
        .structure => Element.wire_size,
        else => @sizeOf(wire.Bits(Element)),
    };
    const element_alignment = comptime switch (kind) {
        .structure => Element.wire_alignment,
        else => element_size,
    };
    if (element_alignment > wire.storage_alignment)
        @compileError("vector alignment exceeds builder storage alignment");
    const trailer_size = comptime switch (kind) {
        .string => string_terminator_size,
        .vector, .structure => 0,
    };
    const overhead = sequence_length_size + trailer_size;
    // Bound the count before multiplication so payload-size arithmetic cannot overflow.
    if (values.len > (max_buffer_size - overhead) / element_size)
        return Error.BufferTooLarge;
    const payload_size = values.len * element_size;
    const size = overhead + payload_size;
    // Include previously built objects without overflowing the addition.
    if (self.used() > max_buffer_size - size) return Error.BufferTooLarge;
    const alignment = @max(sequence_length_size, element_alignment);
    const padding = wire.paddingFor(
        self.used() + payload_size + trailer_size,
        alignment,
    );
    const required_bytes = size + padding;
    try self.ensureSpace(required_bytes);
    switch (kind) {
        .string => if (!standard_library.unicode.utf8ValidateSlice(
            values,
        )) return Error.InvalidUtf8,
        .vector => {},
        .structure => if (validation.overlaps(
            self.buffer,
            standard_library.mem.sliceAsBytes(values),
        )) return Error.AliasedInput,
    }

    const next_cursor = self.write_cursor - required_bytes;
    const payload_start = next_cursor + sequence_length_size;
    // Scalars/strings permit borrowed input; structs rejected aliasing above.
    // Encode before writing the prefix or trailing padding.
    const destination = self.buffer[payload_start..][0..payload_size];
    switch (kind) {
        .string, .vector => wire.encodeSlice(Element, destination, values),
        .structure => Element.encodeSlice(destination, values),
    }
    return self.finishSequence(
        next_cursor,
        payload_start + payload_size,
        values.len,
        alignment,
    );
}

/// Like C++ CreateVectorOfStrings, create children before their offsets.
/// Preflight the complete size and input before writing. Reserve the final
/// vector location mathematically so no temporary array of handles is needed.
/// https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/flatbuffer_builder.h
pub fn createStringVector(
    self: *Self,
    values: []const []const u8,
) Error!Offset {
    if (self.state != .ready) return Error.InvalidState;
    // Reserve room for the count and every u32 offset before multiplying.
    if (values.len > (max_buffer_size - sequence_length_size) / field_offset_size)
        return Error.BufferTooLarge;
    // Child writes must not overwrite the descriptors used to build later children.
    if (validation.overlaps(
        self.buffer,
        standard_library.mem.sliceAsBytes(values),
    )) return Error.AliasedInput;
    var strings_size: usize = 0;
    for (values) |value| {
        const overhead = sequence_length_size + string_terminator_size;
        // Include the count and terminator before computing the string's total size.
        if (value.len > max_buffer_size - overhead) return Error.BufferTooLarge;
        const size = overhead + value.len;
        const projected_used = self.used() + strings_size;
        // Every child must fit together with existing data and earlier planned children.
        if (size > max_buffer_size - projected_used)
            return Error.BufferTooLarge;
        const padding = wire.paddingFor(
            projected_used + value.len + string_terminator_size,
            sequence_length_size,
        );
        try self.ensureSpace(strings_size + size + padding);
        if (!standard_library.unicode.utf8ValidateSlice(
            value,
        )) return Error.InvalidUtf8;
        // Building one child must not overwrite another child's source bytes.
        if (validation.overlaps(self.buffer, value)) return Error.AliasedInput;
        strings_size += size + padding;
    }
    const payload_size = values.len * field_offset_size;
    const vector_size = sequence_length_size + payload_size;
    // The offset array must also fit after accounting for every padded string.
    if (vector_size > max_buffer_size - self.used() - strings_size)
        return Error.BufferTooLarge;
    const padding = wire.paddingFor(
        self.used() + strings_size + payload_size,
        field_offset_size,
    );
    const required_bytes = strings_size + vector_size + padding;
    try self.ensureSpace(required_bytes);
    const next_cursor = self.write_cursor - required_bytes;
    const payload_start = next_cursor + sequence_length_size;
    for (values, 0..) |value, element_index| {
        // Whole-operation preflight proved capacity, UTF-8, and non-aliasing.
        const string = self.createString(value) catch unreachable;
        const reference_start = payload_start + element_index * field_offset_size;
        self.encodeOffset(reference_start, string);
    }
    return self.finishSequence(
        next_cursor,
        payload_start + payload_size,
        values.len,
        field_offset_size,
    );
}

/// Builds a vector of already completed object handles. Sources cannot borrow
/// storage: writing relative offsets must not destroy handles yet to be read.
/// Empty input is present. State, alias, handle, and capacity checks precede writes;
/// numeric handles cannot prove their originating builder or object type.
pub fn createOffsetVector(self: *Self, values: []const Offset) Error!Offset {
    if (self.state != .ready) return Error.InvalidState;
    if (values.len > (max_buffer_size - sequence_length_size) / field_offset_size)
        return Error.BufferTooLarge;
    if (validation.overlaps(
        self.buffer,
        standard_library.mem.sliceAsBytes(values),
    )) return Error.AliasedInput;
    for (values) |value| try self.checkOffset(value, self.used());
    const payload_size = values.len * field_offset_size;
    const padding = wire.paddingFor(
        self.used() + payload_size,
        field_offset_size,
    );
    const required_bytes = sequence_length_size + payload_size + padding;
    try self.ensureSpace(required_bytes);
    const next_cursor = self.write_cursor - required_bytes;
    const payload_start = next_cursor + sequence_length_size;
    for (values, 0..) |value, element_index| {
        const reference_start = payload_start + element_index * field_offset_size;
        self.encodeOffset(reference_start, value);
    }
    return self.finishSequence(
        next_cursor,
        payload_start + payload_size,
        values.len,
        field_offset_size,
    );
}

// All callers preflight handles, capacity, and aliases before encoding slots.
// Null denotes the literal zero used only for an unselected union payload.
fn encodeOffset(self: *Self, reference_start: usize, handle: ?Offset) void {
    const relative_offset: u32 = if (handle) |present|
        @intCast(self.buffer.len - @backingInt(present) - reference_start)
    else
        0;
    wire.encode(
        u32,
        self.buffer[reference_start..][0..field_offset_size],
        relative_offset,
    );
}

/// Commits preflighted metadata after copying the payload. Scalar, string, and
/// offset vectors share copy-before-metadata ordering, padding, and alignment.
fn finishSequence(
    self: *Self,
    sequence_start: usize,
    payload_end: usize,
    element_count: usize,
    alignment: usize,
) Offset {
    @memset(self.buffer[payload_end..self.write_cursor], 0);
    wire.encode(
        u32,
        self.buffer[sequence_start..][0..sequence_length_size],
        @intCast(element_count),
    );
    self.write_cursor = sequence_start;
    self.min_alignment = @max(self.min_alignment, alignment);
    return @fromBackingInt(@intCast(self.used()));
}

/// Only finalization selects a root. Any completed table can be the root, and
/// multiple heterogeneous tables/sequences can be created before this call.
/// The result borrows storage until reset/reuse, including any size prefix.
/// C++ Finish / FinishSizePrefixed; Go FinishSizePrefixedWithFileIdentifier.
/// Framing and identifier bytes are compile-time schema facts. State, capacity,
/// and handle validation remain runtime checks before any writes.
pub fn finish(
    self: *Self,
    root_handle: Offset,
    comptime options: FinishOptions,
) Error![]u8 {
    if (self.state != .ready or self.completed_tables == 0)
        return Error.InvalidState;
    try self.checkOffset(root_handle, self.used());
    const root_offset = @backingInt(root_handle);
    const table_start = self.buffer.len - root_offset;
    // A numerical handle alone does not prove it points to a completed table.
    const layout = validation.tableAt(
        self.buffer,
        table_start,
    ) catch return Error.InvalidOffset;
    if (layout.vtable_start < self.write_cursor) return Error.InvalidOffset;
    const prefix_size = comptime switch (options) {
        .ordinary, .identifier => 0,
        .size_prefixed, .size_prefixed_identifier => wire.size_prefix_size,
    };
    const header_size = prefix_size + comptime switch (options) {
        .ordinary, .size_prefixed => wire.root_offset_size,
        .identifier, .size_prefixed_identifier => wire.identified_header_size,
    };
    const padding = wire.paddingFor(
        self.used() + header_size,
        self.min_alignment,
    );
    const required_bytes = padding + header_size;
    try self.ensureSpace(required_bytes);
    const next_cursor = self.write_cursor - required_bytes;
    const root_offset_start = next_cursor + prefix_size;
    // The root displacement starts at its slot, after any size prefix.
    const relative_offset: u32 = @intCast(
        self.used() + required_bytes - root_offset - prefix_size,
    );
    @memset(
        self.buffer[next_cursor..self.write_cursor],
        0,
    );
    switch (options) {
        .ordinary, .size_prefixed => {},
        .identifier, .size_prefixed_identifier => |identifier| {
            const identifier_start = root_offset_start + wire.file_identifier_start;
            @memcpy(
                self.buffer[identifier_start..][0..wire.file_identifier_size],
                &identifier,
            );
        },
    }
    wire.encode(
        u32,
        self.buffer[root_offset_start..][0..wire.root_offset_size],
        relative_offset,
    );
    switch (options) {
        .ordinary, .identifier => {},
        .size_prefixed, .size_prefixed_identifier => wire.encode(
            u32,
            self.buffer[next_cursor..][0..wire.size_prefix_size],
            @intCast(self.used() + required_bytes - wire.size_prefix_size),
        ),
    }
    self.write_cursor = next_cursor;
    self.state = .finished;
    return self.buffer[next_cursor..];
}

/// Go Offset / C++ GetSize. Derive the size rather than maintaining two cursors.
pub fn used(self: *const Self) usize {
    return self.buffer.len - self.write_cursor;
}

/// Shared by TableBuilder. These low-level operations require an active context
/// or a caller that has checked its own construction state.
pub fn ensureSpace(self: *const Self, required_bytes: usize) Error!void {
    // Backward writes can consume only the free prefix below write_cursor.
    if (required_bytes > self.write_cursor) return Error.NoSpaceLeft;
    // Subtract before adding to enforce the signed-distance limit without overflow.
    if (required_bytes > max_buffer_size or self.used() > max_buffer_size - required_bytes)
        return Error.BufferTooLarge;
}

/// Reject zero handles or distances beyond already completed child storage.
/// This numerical check cannot establish the originating builder or object type.
pub fn checkOffset(
    self: *const Self,
    offset: Offset,
    maximum_offset: usize,
) Error!void {
    _ = self;
    const target_offset = @backingInt(offset);
    // Zero is not an object, and a parent cannot reference unfinished storage.
    if (target_offset == 0 or target_offset > maximum_offset)
        return Error.InvalidOffset;
}

/// Go Prepend* / C++ PushElement: checked placement followed by fixed encoding.
/// This low-level operation checks capacity, not construction state; TableBuilder
/// supplies the active-context check. Return the stored scalar's distance from the end.
pub fn prependScalar(
    self: *Self,
    comptime ScalarType: type,
    value: ScalarType,
) Error!u32 {
    const scalar_size = @sizeOf(wire.Bits(ScalarType));
    const padding = wire.paddingFor(self.used(), scalar_size);
    const required_bytes = padding + scalar_size;
    try self.ensureSpace(required_bytes);
    const next_cursor = self.write_cursor - required_bytes;
    @memset(self.buffer[next_cursor + scalar_size .. self.write_cursor], 0);
    wire.encode(ScalarType, self.buffer[next_cursor..][0..scalar_size], value);
    self.write_cursor = next_cursor;
    self.min_alignment = @max(self.min_alignment, scalar_size);
    return @intCast(self.used());
}

/// C++ AddStruct placement, with member encoding instead of native ABI copies.
/// TableBuilder records the returned distance immediately; it is not a handle
/// to a reusable referenced object. Capacity/alias failures leave state intact.
pub fn prependStruct(
    self: *Self,
    comptime Layout: type,
    value: Layout.Value,
) Error!u32 {
    comptime {
        if (Layout.layout_kind != .structure)
            @compileError("table struct fields require a struct layout");
        if (Layout.wire_alignment > wire.storage_alignment)
            @compileError("struct alignment exceeds builder storage alignment");
    }
    const padding = wire.paddingFor(self.used(), Layout.wire_alignment);
    const required_bytes = padding + Layout.wire_size;
    try self.ensureSpace(required_bytes);
    // Native aggregates may be passed by reference, even with value syntax.
    if (validation.overlaps(
        self.buffer,
        standard_library.mem.asBytes(&value),
    )) return Error.AliasedInput;
    const next_cursor = self.write_cursor - required_bytes;
    Layout.encode(self.buffer[next_cursor..][0..Layout.wire_size], value);
    @memset(self.buffer[next_cursor + Layout.wire_size .. self.write_cursor], 0);
    self.write_cursor = next_cursor;
    self.min_alignment = @max(self.min_alignment, Layout.wire_alignment);
    return @intCast(self.used());
}
