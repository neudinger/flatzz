//! Conservative fixed storage derived from schema wire descriptors.
//! Counts and budgets are compile-time inputs; no allocation or graph traversal.
const std = @import("std");
const wire = @import("wire.zig");
const Builder = @import("Builder.zig");

const BudgetPart = enum { count, bytes };

/// Match the framing passed to Builder.finish.
pub const Options = struct {
    /// Frame kind included in the bound; identifiers reserve their four bytes.
    finish: Builder.FinishOptions = .ordinary,
};

/// Aligned storage for one root and its budgeted children. The buffer is
/// undefined until written by a Builder or a schema's serialize operation.
///
/// Capacities use schema field names:
/// - Strings: maximum payload bytes, excluding prefix and terminator.
/// - Scalar/struct vectors: maximum element count.
/// - String vectors: .{ .count = maximum_strings, .bytes = total_payload_bytes }.
/// - Tables/single unions: explicit total child-construction byte budget.
/// - Table/union vectors: .{ .count = maximum_elements, .bytes = child_budget }.
///
/// Missing names, count, and bytes default to zero. String/vector fields still
/// reserve an empty present value; null/omitted values consume no child space.
/// Fixed scalar/inline-struct fields are always budgeted and reject capacities.
/// External child budgets must include all descendant objects, vtables, and
/// padding. Native table/union vectors reuse their final wire storage for
/// temporary handles; no separate scratch capacity or allocator is required.
///
/// Example, given a schema with label:string and samples:[float]:
/// `var storage: runtime.Storage(Schema, .{ .label = 64, .samples = 16 }, .{}) = .{};`
/// `storage.buffer` can hold those bounds, including all fixed fields and framing.
pub fn Storage(
    comptime SchemaType: type,
    comptime capacities: anytype,
    comptime options: Options,
) type {
    return struct {
        /// Caller-owned aligned output; constructing this wrapper does not initialize its bytes.
        buffer: [capacity(SchemaType, capacities, options)]u8 align(wire.storage_alignment) =
            undefined,
    };
}

/// Upper bound for Storage.buffer, rounded to Builder's usable alignment.
/// Includes sparse physical vtable IDs, both slots/vectors of unions, all
/// default-valued scalars and worst-case padding.
/// Capacities must be nonnegative integers; counts must fit u32, and the complete
/// bound must fit Builder.max_buffer_size. Unknown names and invalid budget records
/// are rejected at compile time.
/// This is a capacity bound, not a prediction of the serialized frame length.
pub fn capacity(
    comptime SchemaType: type,
    comptime capacities: anytype,
    comptime options: Options,
) usize {
    return comptime capacity_blk: {
        const fields = SchemaType.fields;
        const capacity_info = @typeInfo(@TypeOf(capacities));
        if (capacity_info != .@"struct")
            @compileError("storage capacities must be a record of schema field names");
        for (capacity_info.@"struct".field_names) |field_name| {
            if (!@hasField(@TypeOf(fields), field_name))
                @compileError("unknown storage capacity field: " ++ field_name);
        }
        const framing_size = switch (options.finish) {
            .ordinary => wire.root_offset_size,
            .identifier => wire.identified_header_size,
            .size_prefixed => wire.size_prefix_size + wire.root_offset_size,
            .size_prefixed_identifier => wire.size_prefix_size + wire.identified_header_size,
        };
        // Arbitrary-precision intermediates keep overflow checks independent
        // of the target usize width and report our capacity diagnostic.
        var total: comptime_int = framing_size + wire.storage_alignment - 1 +
            wire.vtable_header_size + wire.vtable_entry_size * SchemaType.field_count +
            wire.table_header_size + wire.table_header_size - 1;
        for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field_name| {
            const FieldType = @field(fields, field_name);
            const has_budget = @hasField(@TypeOf(capacities), field_name);
            const budget = if (has_budget)
                @field(capacities, field_name)
            else switch (FieldType.kind) {
                .union_vector => .{},
                .vector => |Codec| switch (Codec.kind) {
                    .string, .table => .{},
                    else => 0,
                },
                else => 0,
            };
            total += switch (FieldType.kind) {
                .scalar => |ValueType| 2 * @sizeOf(wire.Bits(wire.Scalar(ValueType))) - 1,
                .structure => |Layout| Layout.wire_size + Layout.wire_alignment - 1,
                .union_value => 2 * wire.field_offset_size - 1 + @sizeOf(wire.UnionTag),
                .union_vector => 2 * (2 * wire.field_offset_size - 1),
                else => 2 * wire.field_offset_size - 1,
            };
            total += switch (FieldType.kind) {
                .scalar, .structure => if (has_budget)
                    @compileError(
                        "fixed-size fields do not accept storage capacities: " ++ field_name,
                    )
                else
                    0,
                .string => sequenceSize(count(budget), 1, 1) + wire.string_terminator_size,
                .table, .union_value => unsigned(budget),
                .union_vector => sequenceSize(
                    part(budget, .count),
                    wire.field_offset_size,
                    wire.field_offset_size,
                ) + sequenceSize(
                    part(budget, .count),
                    @sizeOf(wire.UnionTag),
                    @alignOf(wire.UnionTag),
                ) + part(budget, .bytes),
                .vector => |Codec| switch (Codec.kind) {
                    .scalar, .structure => sequenceSize(
                        count(budget),
                        Codec.slot_size,
                        Codec.slot_alignment,
                    ),
                    .string => sequenceSize(
                        part(budget, .count),
                        Codec.slot_size,
                        Codec.slot_alignment,
                    ) + part(budget, .count) *
                        (wire.sequence_length_size + wire.string_terminator_size +
                            wire.sequence_length_size - 1) + part(budget, .bytes),
                    .table => sequenceSize(
                        part(budget, .count),
                        Codec.slot_size,
                        Codec.slot_alignment,
                    ) + part(budget, .bytes),
                },
            };
        }
        total += @mod(-total, @as(comptime_int, wire.storage_alignment));
        if (total > Builder.max_buffer_size)
            @compileError("storage capacity exceeds Builder.max_buffer_size");
        break :capacity_blk @intCast(total);
    };
}

fn sequenceSize(
    comptime elements: comptime_int,
    comptime size: usize,
    comptime alignment: usize,
) comptime_int {
    const element_size: comptime_int = size;
    const padding: comptime_int = @max(wire.sequence_length_size, alignment) - 1;
    return wire.sequence_length_size + elements * element_size + padding;
}

fn unsigned(comptime value: anytype) comptime_int {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => @compileError("storage capacities must be nonnegative integers"),
    }
    if (value < 0) @compileError("storage capacities must be nonnegative integers");
    return value;
}

fn count(comptime value: anytype) comptime_int {
    const result = unsigned(value);
    if (result > std.math.maxInt(u32))
        @compileError("storage element count must fit in u32");
    return result;
}

fn part(comptime budget: anytype, comptime field: BudgetPart) comptime_int {
    const budget_info = @typeInfo(@TypeOf(budget));
    if (budget_info != .@"struct")
        @compileError("storage vector capacity must be a count/bytes record");
    for (budget_info.@"struct".field_names) |field_name| {
        if (std.meta.stringToEnum(BudgetPart, field_name) == null)
            @compileError("unknown storage vector capacity field: " ++ field_name);
    }
    const name = @tagName(field);
    const value = if (@hasField(@TypeOf(budget), name)) unsigned(@field(budget, name)) else 0;
    return switch (field) {
        .count => count(value),
        .bytes => value,
    };
}
