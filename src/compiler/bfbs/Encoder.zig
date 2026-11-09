//! BFBS construction and ownership of its growable backward buffer.
//! Internal one-shot encoder used by bfbs.encode. Input records remain borrowed;
//! only the returned complete allocation survives. Temporary handle/cache storage
//! and the growing output buffer are released if encoding fails.

const std = @import("std");
const reflection = @import("../reflection.zig");
const runtime = @import("flatzz");
const bfbs = @import("../bfbs.zig");
const record_layout = @import("record_layout.zig");

const Encoder = @This();
const Error = bfbs.Error;
const Builder = runtime.Builder;
const TableBuilder = runtime.TableBuilder;
const wire = runtime.wire;
const Scalar = record_layout.Scalar;
const scalarDefault = record_layout.scalarDefault;
const isReference = record_layout.isReference;

// Distinguish equal addresses used by different reflection record types.
const Key = struct {
    /// Internal reflection declaration selector, never a serialized type code.
    kind: u8,
    /// Borrowed native record address, stable throughout this encode call.
    address: usize,
};

/// Owns the growing aligned buffer; backward handle distances survive reallocation.
builder: Builder,
/// Borrowed canonical Object array; referenced Object pointers must identify its elements.
objects: []const reflection.Object,
/// Completed table handles by native record identity; keys never become wire type tags.
tables: std.AutoHashMapUnmanaged(Key, Builder.Offset) = .empty,

/// Encode a complete owned frame; release intermediate storage on failure.
/// The result begins at its allocation base and is freed with the same allocator.
/// Input metadata must survive all allocator calls. Invalid UTF-8/Object references
/// return InvalidSchema; attribute sorting does not mutate the input graph.
pub fn encode(
    allocator: std.mem.Allocator,
    schema: reflection.Schema,
) Error![]align(wire.storage_alignment) u8 {
    const storage = try allocator.alignedAlloc(
        u8,
        comptime .fromByteUnits(wire.storage_alignment),
        256,
    );
    var encoder: Encoder = .{ .builder = Builder.init(storage), .objects = schema.objects };
    defer encoder.tables.deinit(allocator);
    errdefer allocator.free(encoder.builder.buffer);
    // All scalar bits, including negative-zero defaults, remain observable.
    encoder.builder.force_defaults = true;
    const root = try encoder.table(allocator, &schema);
    try encoder.reserve(allocator, wire.identified_header_size + wire.storage_alignment - 1);
    const frame = try encoder.builder.finish(root, .{ .identifier = reflection.file_identifier.* });
    @memmove(encoder.builder.buffer[0..frame.len], frame);
    return allocator.realloc(encoder.builder.buffer, frame.len);
}

/// Backward handles measure distances from the end, so moving the complete
/// used suffix preserves every completed object and active table context.
fn reserve(self: *Encoder, allocator: std.mem.Allocator, required: usize) Error!void {
    const maximum = std.mem.alignBackward(
        usize,
        Builder.max_buffer_size,
        wire.storage_alignment,
    );
    const used = self.builder.used();
    if (required > maximum - used) return error.BufferTooLarge;
    if (required <= self.builder.write_cursor) return;
    const old_capacity = self.builder.buffer.len;
    var capacity = old_capacity;
    while (capacity < used + required)
        capacity = if (capacity > maximum / 2) maximum else capacity * 2;
    const storage = try allocator.realloc(self.builder.buffer, capacity);
    @memmove(storage[capacity - used ..], storage[old_capacity - used .. old_capacity]);
    self.builder.buffer = storage;
    self.builder.write_cursor = capacity - used;
}

fn sequenceSpace(count: usize, width: usize, overhead: usize) Error!usize {
    if (count > (Builder.max_buffer_size - overhead) / width) return error.BufferTooLarge;
    return count * width + overhead;
}

fn stringSpace(value: []const u8) Error!usize {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSchema;
    return sequenceSpace(
        value.len,
        1,
        wire.sequence_length_size + wire.string_terminator_size +
            wire.sequence_length_size - 1,
    );
}

fn string(
    self: *Encoder,
    allocator: std.mem.Allocator,
    value: []const u8,
) Error!Builder.Offset {
    try self.reserve(allocator, try stringSpace(value));
    return self.builder.createString(value);
}

fn strings(
    self: *Encoder,
    allocator: std.mem.Allocator,
    values: []const []const u8,
) Error!Builder.Offset {
    var required = try sequenceSpace(
        values.len,
        wire.field_offset_size,
        wire.sequence_length_size + wire.field_offset_size - 1,
    );
    for (values) |value| {
        const size = try stringSpace(value);
        if (size > Builder.max_buffer_size - required) return error.BufferTooLarge;
        required += size;
    }
    try self.reserve(allocator, required);
    return self.builder.createStringVector(values);
}

fn tableSpace(comptime Record: type) usize {
    const structure = @typeInfo(Record).@"struct";
    var required = wire.table_header_size + wire.table_header_size - 1 +
        wire.vtable_header_size + wire.vtable_entry_size * structure.field_names.len;
    for (structure.field_types) |Field| {
        const width = if (isReference(Field))
            wire.field_offset_size
        else
            @sizeOf(Scalar(Field));
        required += width + width - 1;
    }
    return required;
}

fn table(self: *Encoder, allocator: std.mem.Allocator, record: anytype) Error!Builder.Offset {
    const Record = std.meta.Child(@TypeOf(record));
    const structure = @typeInfo(Record).@"struct";
    if (Record == reflection.Object) {
        const start = @intFromPtr(self.objects.ptr);
        const address = @intFromPtr(record);
        if (address < start or (address - start) % @sizeOf(Record) != 0 or
            (address - start) / @sizeOf(Record) >= self.objects.len) return error.InvalidSchema;
    }
    const key: Key = .{ .kind = tableKind(Record), .address = @intFromPtr(record) };
    if (self.tables.get(key)) |handle| return handle;
    var children: [structure.field_names.len]?Builder.Offset = @splat(null);
    // Schema.objects is visited before enums, root_table, and RPC metadata,
    // so their shared Object pointers reuse the already-completed handles.
    inline for (structure.field_names, structure.field_types, 0..) |name, Field, index| {
        if (comptime isReference(Field)) children[index] = try self.reference(
            allocator,
            @field(record.*, name),
        );
    }
    try self.reserve(allocator, comptime tableSpace(Record));
    var context = try TableBuilder(structure.field_names.len).init(&self.builder);
    inline for (structure.field_names, structure.field_types, 0..) |name, Field, index| {
        if (comptime !isReference(Field)) {
            const value: Scalar(Field) = if (Field == reflection.AdvancedFeatures)
                @bitCast(@field(record.*, name))
            else
                @field(record.*, name);
            try context.addScalar(
                Scalar(Field),
                index,
                value,
                comptime scalarDefault(Record, index),
            );
        } else {
            try context.addOffset(index, children[index]);
            if (@typeInfo(Field) != .optional) try context.requireField(index);
        }
    }
    const handle = try context.endTable();
    try self.tables.put(allocator, key, handle);
    return handle;
}

fn reference(
    self: *Encoder,
    allocator: std.mem.Allocator,
    value: anytype,
) Error!?Builder.Offset {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |present| try self.reference(allocator, present) else null,
        .pointer => |pointer| switch (pointer.size) {
            .one => try self.table(allocator, value),
            .slice => if (pointer.child == u8)
                try self.string(allocator, value)
            else if (pointer.child == []const u8)
                try self.strings(allocator, value)
            else offset_vector_blk: {
                const required = try sequenceSpace(
                    value.len,
                    wire.field_offset_size,
                    wire.sequence_length_size + wire.field_offset_size - 1,
                );
                const handles = try allocator.alloc(Builder.Offset, value.len);
                defer allocator.free(handles);
                if (pointer.child == reflection.KeyValue) {
                    const sorted = try allocator.alloc(*const reflection.KeyValue, value.len);
                    defer allocator.free(sorted);
                    for (value, sorted) |*record, *destination| destination.* = record;
                    std.mem.sort(*const reflection.KeyValue, sorted, {}, struct {
                        fn less(
                            _: void,
                            left: *const reflection.KeyValue,
                            right: *const reflection.KeyValue,
                        ) bool {
                            return std.mem.lessThan(u8, left.key, right.key);
                        }
                    }.less);
                    for (sorted, handles) |record, *handle| handle.* = try self.table(
                        allocator,
                        record,
                    );
                } else {
                    for (value, handles) |*record, *handle| handle.* = try self.table(
                        allocator,
                        record,
                    );
                }
                try self.reserve(allocator, required);
                break :offset_vector_blk try self.builder.createReferenceVector(handles, .{});
            },
            else => @compileError("BFBS references require single pointers or slices"),
        },
        else => @compileError("unsupported BFBS reference type"),
    };
}

fn tableKind(comptime Record: type) u8 {
    // Reflection's public auto-layout structs are BFBS table records.
    // Declaration indices identify cache entries, never serialized wire types.
    inline for (@typeInfo(reflection).@"struct".decl_names, 0..) |name, index| {
        const Declaration = @field(reflection, name);
        if (@TypeOf(Declaration) == type and Declaration == Record) {
            const information = @typeInfo(Declaration);
            if (information == .@"struct" and information.@"struct".layout == .auto) {
                if (index > std.math.maxInt(u8))
                    @compileError("reflection table kind exceeds u8");
                return @intCast(index);
            }
        }
    }
    @compileError("unsupported reflection table");
}
