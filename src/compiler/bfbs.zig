//! Native BFBS encoding and checked decoding for `reflection.zig` metadata.
//!
//! Wire IDs follow FlatBuffers v25.2.10, commit
//! 1c514626e83c20fffa8557e75641848e1e15cd5e, reflection/reflection.fbs.
//! Declaration order includes the reserved legacy EnumVal.object slot at ID 2.
//! Encoding preserves vector order and type indices, except attributes are sorted
//! by key for official LookupByKey consumers. Input metadata is never modified.
//!
//! `encode` returns an owned, aligned byte slice; free it with the same allocator.
//! Decoding uses a caller-owned arena for metadata and temporaries, copies strings,
//! and preserves shared Object references. Keep the arena alive for all consumers.
//! Wire validation does not replace FBS semantic validation. Unknown appended
//! fields are ignored; unknown BaseType values and feature bits are retained.
//!
//! ## Complete example
//!
//! Save this as `bfbs_example_test.zig` beside Flatzz's build file and run
//! ```sh
//! zig test --dep flatzz_compiler -Mroot=bfbs_example_test.zig \
//!     --dep flatzz -Mflatzz_compiler=src/compiler.zig -Mflatzz=src/runtime.zig
//! ```
//! ```zig
//! const std = @import("std");
//! const compiler = @import("flatzz_compiler");
//!
//! test "schema binary round trip" {
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!     const schema = try compiler.parser.parse(arena.allocator(),
//!         "table Reading { value:uint = 42; } root_type Reading;");
//!     const bytes = try compiler.bfbs.encode(std.testing.allocator, schema);
//!     defer std.testing.allocator.free(bytes);
//!     const decoded = try compiler.bfbs.decode(arena.allocator(), bytes);
//!     try std.testing.expectEqualStrings("BFBS", bytes[4..8]);
//!     try std.testing.expectEqualStrings("Reading", decoded.root_table.?.name);
//!     try std.testing.expectEqual(@as(i64, 42), decoded.root_table.?.fields[0].default_integer);
//! }
//! ```
//! Expected result: a passing round-trip test; the codec itself prints nothing.
//! Encoded bytes are separately owned, and the arena retains both metadata graphs.

const std = @import("std");
const reflection = @import("reflection.zig");
const runtime = @import("flatzz");

const wire = runtime.wire;
const Builder = runtime.Builder;
const TableBuilder = runtime.TableBuilder;
const Table = runtime.Table;
const validation = runtime.validation;
const framing = runtime.framing;

/// Allocation, construction, invalid-wire, or configured resource-limit failures.
pub const Error = std.mem.Allocator.Error || Builder.Error || error{
    /// Invalid framing, missing required metadata, invalid UTF-8, or malformed wire data.
    InvalidBfbs,
    /// Encoding found invalid UTF-8 or an Object pointer outside `Schema.objects`.
    InvalidSchema,
    /// A decoded table subtree would exceed `DecodeOptions.max_depth`.
    DepthLimit,
    /// Table/vector/string visits would exceed `DecodeOptions.max_objects`.
    ObjectLimit,
    /// Traversal or decoded allocation work would exceed `DecodeOptions.max_work`.
    WorkLimit,
};
const ReadError = Error || runtime.AccessError;

/// Decoder work bounds apply before payload allocation or string scanning.
pub const DecodeOptions = struct {
    /// Ordinary BFBS by default; prefixed input retains its original alignment origin.
    format: framing.Format = .ordinary,
    /// Maximum nested table depth; zero rejects every schema.
    max_depth: usize = 64,
    /// Table, vector, and string visits, including shared-object references.
    max_objects: usize = 1_000_000,
    /// Wire traversal and decoded allocation bytes; includes repeated shared-object work
    /// but excludes allocator overhead and temporary lookup-table storage.
    max_work: usize = 64 * 1024 * 1024,
};

/// Decode ordinary BFBS with default resource limits into caller-arena storage.
/// Returned strings do not borrow `bytes`; release the arena on success or failure.
/// Errors are `InvalidBfbs`, resource-limit failures, or `OutOfMemory`; allocation
/// already performed before an error is retained in the caller's arena.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!reflection.Schema {
    return decodeWithOptions(allocator, bytes, .{});
}

/// Decode known reflection fields with explicit framing and resource limits.
/// Missing required references, invalid offsets, alignment, or UTF-8 return InvalidBfbs.
/// Empty required strings/vectors remain valid, and omitted scalars use schema defaults.
/// Use an arena for returned metadata and temporaries; release it on success or
/// failure. The result no longer borrows `bytes`. Limits return `DepthLimit`,
/// `ObjectLimit`, or `WorkLimit`, independently of allocation failure.
pub fn decodeWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) Error!reflection.Schema {
    var decoder: Decoder = .{ .bytes = bytes, .options = options };
    defer decoder.objects.deinit(allocator);
    return decoder.read(allocator) catch |failure| switch (failure) {
        error.OutOfBounds,
        error.InvalidBuffer,
        error.IdentifierMismatch,
        error.InvalidUnion,
        error.UnknownUnionTag,
        => error.InvalidBfbs,
        else => |other| return other,
    };
}

fn Scalar(comptime Value: type) type {
    return if (Value == reflection.AdvancedFeatures) u64 else Value;
}

fn scalarDefault(comptime Record: type, comptime field_index: usize) Scalar(
    @typeInfo(Record).@"struct".field_types[field_index],
) {
    const structure = @typeInfo(Record).@"struct";
    const Value = structure.field_types[field_index];
    const default = structure.field_attrs[field_index].defaultValue(Value).?;
    return if (Value == reflection.AdvancedFeatures) @bitCast(default) else default;
}

fn isReference(comptime Value: type) bool {
    return switch (@typeInfo(Value)) {
        .pointer => true,
        .optional => |optional| isReference(optional.child),
        else => false,
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

/// Allocate a complete BFBS frame. The returned slice starts at its allocation
/// base and must be freed with the same allocator.
/// Input records and their borrowed buffers must remain valid throughout the call.
/// Attribute vectors are canonicalized by key without mutating caller storage.
/// Root, RPC, and legacy Object pointers must reference elements of schema.objects;
/// external Object copies or invalid UTF-8 return InvalidSchema. Semantic ordering
/// and Type indices remain the caller's responsibility.
/// Returns ordinary framing with the BFBS identifier. Allocation and construction
/// errors propagate; all internal allocations are released when encoding fails.
/// This encodes reflection metadata, not application message values.
/// Unknown appended BFBS fields cannot be reproduced from this metadata model.
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

const Encoder = struct {
    const Key = struct { kind: u8, address: usize };

    builder: Builder,
    objects: []const reflection.Object,
    tables: std.AutoHashMapUnmanaged(Key, Builder.Offset) = .empty,

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

    fn string(
        self: *Encoder,
        allocator: std.mem.Allocator,
        value: []const u8,
    ) Error!Builder.Offset {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSchema;
        try self.reserve(
            allocator,
            try sequenceSpace(
                value.len,
                1,
                wire.sequence_length_size + wire.string_terminator_size +
                    wire.sequence_length_size - 1,
            ),
        );
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
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSchema;
            const size = try sequenceSpace(
                value.len,
                1,
                wire.sequence_length_size + wire.string_terminator_size +
                    wire.sequence_length_size - 1,
            );
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
                        for (value, 0..) |*record, index| sorted[index] = record;
                        std.mem.sort(*const reflection.KeyValue, sorted, {}, struct {
                            fn less(
                                _: void,
                                left: *const reflection.KeyValue,
                                right: *const reflection.KeyValue,
                            ) bool {
                                return std.mem.lessThan(u8, left.key, right.key);
                            }
                        }.less);
                        for (sorted, 0..) |record, index| handles[index] = try self.table(
                            allocator,
                            record,
                        );
                    } else {
                        for (value, 0..) |*record, index| handles[index] = try self.table(
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
};

const Decoder = struct {
    bytes: []const u8,
    options: DecodeOptions,
    depth: usize = 0,
    deepest: usize = 0,
    object_count: usize = 0,
    work: usize = 0,
    // Fixed Object-vector storage must be registered before root/RPC/legacy refs.
    objects: std.AutoHashMapUnmanaged(usize, struct {
        value: *reflection.Object,
        work: usize = 0,
        height: usize = 0,
    }) = .empty,

    fn charge(self: *Decoder, amount: usize) Error!void {
        if (amount > self.options.max_work - self.work) return error.WorkLimit;
        self.work += amount;
    }

    fn visit(self: *Decoder, amount: usize) Error!void {
        if (self.object_count >= self.options.max_objects) return error.ObjectLimit;
        self.object_count += 1;
        try self.charge(amount);
    }

    fn allocate(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Value: type,
        count: usize,
    ) Error![]Value {
        if (count > (self.options.max_work - self.work) / @sizeOf(Value)) return error.WorkLimit;
        try self.charge(count * @sizeOf(Value));
        return allocator.alloc(Value, count);
    }

    fn read(self: *Decoder, allocator: std.mem.Allocator) ReadError!reflection.Schema {
        const root = try Table.from(self.bytes, .{ .options = .{
            .format = self.options.format,
            .identifier = reflection.file_identifier.*,
        } });
        self.bytes = root.bytes;
        return self.table(allocator, reflection.Schema, root);
    }

    fn table(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Record: type,
        view: Table,
    ) ReadError!Record {
        if (self.depth >= self.options.max_depth) return error.DepthLimit;
        try self.visit(view.layout.table_size + view.layout.vtable_size);
        self.depth += 1;
        self.deepest = @max(self.deepest, self.depth);
        defer self.depth -= 1;
        var result: Record = undefined;
        const structure = @typeInfo(Record).@"struct";
        inline for (structure.field_names, structure.field_types, 0..) |name, Value, field_id| {
            @field(result, name) = if (comptime isReference(Value)) reference_field_blk: {
                const position = try view.fieldPosition(u32, field_id) orelse {
                    if (@typeInfo(Value) == .optional) break :reference_field_blk null;
                    return error.InvalidBfbs;
                };
                break :reference_field_blk try self.reference(
                    allocator,
                    Value,
                    position,
                    view.context(),
                );
            } else scalar_field_blk: {
                const value = try view.readField(
                    Scalar(Value),
                    field_id,
                    scalarDefault(Record, field_id),
                );
                break :scalar_field_blk if (Value == reflection.AdvancedFeatures)
                    @bitCast(value)
                else
                    value;
            };
        }
        return result;
    }

    // Cached Object visits must retain the work and depth of their entire subtree.
    fn measuredTable(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Record: type,
        view: Table,
    ) ReadError!struct {
        value: Record,
        work: usize,
        height: usize,
    } {
        const before = self.work;
        const previous_deepest = self.deepest;
        self.deepest = self.depth;
        defer self.deepest = @max(previous_deepest, self.deepest);
        const value = try self.table(allocator, Record, view);
        return .{ .value = value, .work = self.work - before, .height = self.deepest - self.depth };
    }

    fn child(self: *Decoder, position: usize, context: validation.Context) ReadError!Table {
        return .{
            .bytes = self.bytes,
            .layout = try validation.referencedTable(self.bytes, context, position),
        };
    }

    fn reference(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Value: type,
        position: usize,
        context: validation.Context,
    ) ReadError!Value {
        return switch (@typeInfo(Value)) {
            .optional => |optional| try self.reference(
                allocator,
                optional.child,
                position,
                context,
            ),
            .pointer => |pointer_info| switch (pointer_info.size) {
                .one => try self.pointer(
                    allocator,
                    pointer_info.child,
                    try self.child(position, context),
                ),
                .slice => if (pointer_info.child == u8) string_value_blk: {
                    const layout = try validation.sequenceAt(
                        1,
                        1,
                        1,
                        self.bytes,
                        context,
                        position,
                    );
                    const string_size = layout.element_count + wire.string_terminator_size;
                    try self.visit(wire.sequence_length_size + string_size);
                    try self.charge(layout.element_count);
                    const terminated = self.bytes[layout.payload_start..][0..string_size];
                    break :string_value_blk try allocator.dupe(
                        u8,
                        try validation.stringPayload(terminated),
                    );
                } else try self.vector(allocator, pointer_info.child, position, context),
                else => @compileError("reflection references require single pointers or slices"),
            },
            else => @compileError("unsupported reflection reference"),
        };
    }

    fn pointer(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Record: type,
        view: Table,
    ) ReadError!*const Record {
        if (Record == reflection.Object) if (self.objects.get(view.layout.table_start)) |cached| {
            if (cached.height > self.options.max_depth - self.depth) return error.DepthLimit;
            self.deepest = @max(self.deepest, self.depth + cached.height);
            try self.visit(cached.work);
            return cached.value;
        };
        const measured = try self.measuredTable(allocator, Record, view);
        const storage = try self.allocate(allocator, Record, 1);
        storage[0] = measured.value;
        if (Record == reflection.Object) try self.objects.put(allocator, view.layout.table_start, .{
            .value = &storage[0],
            .work = measured.work,
            .height = measured.height,
        });
        return &storage[0];
    }

    fn vector(
        self: *Decoder,
        allocator: std.mem.Allocator,
        comptime Element: type,
        position: usize,
        parent: validation.Context,
    ) ReadError![]const Element {
        const layout = try validation.sequenceAt(4, 4, 0, self.bytes, parent, position);
        try self.visit(wire.sequence_length_size + layout.element_count * wire.field_offset_size);
        const values = try self.allocate(allocator, Element, layout.element_count);
        var context = parent;
        context.vector = .{
            .start = layout.payload_start - wire.sequence_length_size,
            .size = wire.sequence_length_size + layout.element_count * wire.field_offset_size,
        };
        if (Element == reflection.Object) for (values, 0..) |*value, index| {
            const view = try self.child(
                layout.payload_start + index * wire.field_offset_size,
                context,
            );
            try self.objects.put(allocator, view.layout.table_start, .{ .value = value });
        };
        for (values, 0..) |*value, index| {
            const slot = layout.payload_start + index * wire.field_offset_size;
            if (@typeInfo(Element) == .@"struct") {
                const view = try self.child(slot, context);
                const measured = try self.measuredTable(allocator, Element, view);
                value.* = measured.value;
                if (Element == reflection.Object) {
                    const cached = self.objects.getPtr(view.layout.table_start).?;
                    cached.work = measured.work;
                    cached.height = measured.height;
                }
            } else value.* = try self.reference(allocator, Element, slot, context);
        }
        return values;
    }
};
