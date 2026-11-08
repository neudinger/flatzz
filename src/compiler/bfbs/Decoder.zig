//! Checked BFBS traversal into caller-arena metadata with shared Object identity.

const std = @import("std");
const reflection = @import("../reflection.zig");
const runtime = @import("flatzz");
const bfbs = @import("../bfbs.zig");
const record_layout = @import("record_layout.zig");

const Decoder = @This();
const Error = bfbs.Error;
const DecodeOptions = bfbs.DecodeOptions;
const ReadError = Error || runtime.AccessError;
const Table = runtime.Table;
const buffer_access = runtime.buffer_access;
const wire = runtime.wire;
const Scalar = record_layout.Scalar;
const scalarDefault = record_layout.scalarDefault;
const isReference = record_layout.isReference;

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

/// Decode with bounded work and translate malformed wire failures at this boundary.
pub fn decode(
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

fn child(self: *Decoder, position: usize, context: buffer_access.Context) ReadError!Table {
    return .{
        .bytes = self.bytes,
        .layout = try buffer_access.referencedTable(self.bytes, context, position),
    };
}

fn reference(
    self: *Decoder,
    allocator: std.mem.Allocator,
    comptime Value: type,
    position: usize,
    context: buffer_access.Context,
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
                const layout = try buffer_access.sequenceAt(
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
                    try buffer_access.stringPayload(terminated),
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
    parent: buffer_access.Context,
) ReadError![]const Element {
    const layout = try buffer_access.sequenceAt(4, 4, 0, self.bytes, parent, position);
    const vector_size = wire.sequence_length_size +
        layout.element_count * wire.field_offset_size;
    try self.visit(vector_size);
    const values = try self.allocate(allocator, Element, layout.element_count);
    var context = parent;
    context.vector = .{
        .start = layout.payload_start - wire.sequence_length_size,
        .size = vector_size,
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
