//! Conservative fixed storage derived from schema wire descriptors.
//! Explicit budgets or native values supply compile-time bounds without allocation.
const std = @import("std");
const wire = @import("wire.zig");
const schema = @import("schema.zig");
const Builder = @import("Builder.zig");
const errors = @import("errors.zig");

const BuildError = errors.BuildError;

const BudgetPart = enum { count, bytes };
const Purpose = enum { capacity, serialize };
const default_write_options: schema.WriteOptions = .{};

/// One allocator-owned buffer and its serialized frame, without a final output copy.
/// Free once with deinit; the bytes slice and every borrowed view expire together.
pub const Serialized = struct {
    /// Complete allocation, including spare capacity. Only deinit frees this slice.
    storage: []align(wire.storage_alignment) u8,
    /// Serialized suffix borrowing storage; use this slice for reading and writing.
    bytes: []u8,

    /// Release the complete allocation with the allocator supplied to serializeAlloc.
    pub fn deinit(self: Serialized, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }
};

/// Match the framing passed to Builder.finish.
pub const Options = struct {
    /// Frame kind included in the bound; identifiers reserve their four bytes.
    finish: Builder.FinishOptions = .ordinary,
};

/// Framing and bounded native traversal for capacityFor and measure.
pub const ValueOptions = struct {
    /// Match the framing passed to Builder.finish; serialize uses ordinary framing.
    finish: Builder.FinishOptions = .ordinary,
    /// Maximum active table depth, including the root. Cycles exceed this limit.
    max_depth: usize = default_write_options.max_depth,
    /// Maximum table/field visits and native payload bytes, as in WriteOptions.
    max_work: usize = default_write_options.max_work,
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
        // Arbitrary-precision intermediates preserve diagnostics on every target.
        var total: comptime_int = tableSize(SchemaType);
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
            switch (FieldType.kind) {
                .scalar, .structure => if (has_budget)
                    @compileError(
                        "fixed-size fields do not accept storage capacities: " ++ field_name,
                    ),
                else => {},
            }
            total += childSize(FieldType.kind, budget);
        }
        break :capacity_blk framedCapacity(total, options.finish);
    };
}

/// Derive a conservative aligned capacity from one complete compile-time native graph.
/// Value fields must match the schema's descriptor value types. Strings, vectors,
/// child tables and selected union payloads supply their own lengths and child budgets.
/// Repeated table pointers are counted separately, matching recursive serialization.
///
/// Includes every scalar slot, so either force_defaults setting fits. This is not
/// an exact frame length, and does not validate UTF-8 or required-field presence.
/// Runtime-dependent values are rejected; retain Storage budgets for runtime bounds.
/// Depth/work limits and Builder.max_buffer_size are checked at compile time.
/// Large graphs may require the caller to raise the comptime evaluation branch quota.
/// The calculation allocates no runtime memory and adds no runtime sizing pass.
///
/// Given a compile-time value and its Schema:
/// `const size = comptime runtime.storage.capacityFor(Schema, value, .{});`
/// `var buffer: [size]u8 align(runtime.storage_alignment) = undefined;`
/// `const bytes = try Schema.serialize(value, &buffer, .{});`
/// The result borrows buffer until reuse; no deinit is needed.
pub fn capacityFor(
    comptime SchemaType: type,
    comptime value: anytype,
    comptime options: ValueOptions,
) usize {
    return comptime capacity_blk: {
        @setEvalBranchQuota(100_000);
        var sizing: NativeSizer(.capacity) = .{ .options = options };
        const size = sizing.table(SchemaType, value) catch |failure| switch (failure) {
            error.DepthLimit => @compileError("native storage depth limit exceeded"),
            error.WorkLimit => @compileError("native storage work limit exceeded"),
            error.BufferTooLarge => @compileError(
                "storage capacity exceeds Builder.max_buffer_size",
            ),
            else => @compileError(@errorName(failure)),
        };
        break :capacity_blk framedCapacity(size, options.finish);
    };
}

/// Measure a runtime native graph without allocating or writing output.
/// Checks required presence and the same depth/work limits as native construction;
/// UTF-8 and table-body limits are checked during packing. Counts repeated child
/// pointers separately. The aligned bound retains every scalar slot and can
/// exceed the actual frame length. Oversized bounds return BufferTooLarge.
/// Inputs must remain valid throughout the call; this does not retain any borrows.
pub fn measure(
    comptime SchemaType: type,
    value: anytype,
    options: ValueOptions,
) BuildError!usize {
    var sizing: NativeSizer(.serialize) = .{ .options = options };
    const total = (try sizing.table(SchemaType, value)) +|
        framingSize(options.finish) +| (wire.storage_alignment - 1);
    // Saturation cannot produce an accepted bound: usize's maximum is greater
    // than Builder's signed-distance limit on supported 32/64-bit targets.
    const mask: usize = wire.storage_alignment - 1;
    const aligned = (total +| mask) & ~mask;
    if (aligned > Builder.max_buffer_size) return BuildError.BufferTooLarge;
    return aligned;
}

fn tableSize(comptime SchemaType: type) comptime_int {
    var total: comptime_int = wire.vtable_header_size +
        wire.vtable_entry_size * SchemaType.field_count +
        wire.table_header_size + wire.table_header_size - 1;
    const fields = SchemaType.fields;
    for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field_name| {
        total += switch (@field(fields, field_name).kind) {
            .scalar => |ValueType| 2 * @sizeOf(wire.Bits(wire.Scalar(ValueType))) - 1,
            .structure => |Layout| Layout.wire_size + Layout.wire_alignment - 1,
            .union_value => 2 * wire.field_offset_size - 1 + @sizeOf(wire.UnionTag),
            .union_vector => 2 * (2 * wire.field_offset_size - 1),
            else => 2 * wire.field_offset_size - 1,
        };
    }
    return total;
}

fn childSize(comptime kind: schema.Kind, comptime budget: anytype) comptime_int {
    return switch (kind) {
        .scalar, .structure => 0,
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

fn framedCapacity(
    comptime object_size: comptime_int,
    comptime finish: Builder.FinishOptions,
) usize {
    const framing_size: comptime_int = framingSize(finish);
    var total: comptime_int = object_size + framing_size + wire.storage_alignment - 1;
    total += @mod(-total, @as(comptime_int, wire.storage_alignment));
    if (total > Builder.max_buffer_size)
        @compileError("storage capacity exceeds Builder.max_buffer_size");
    return @intCast(total);
}

fn framingSize(finish: Builder.FinishOptions) usize {
    return switch (finish) {
        .ordinary => wire.root_offset_size,
        .identifier => wire.identified_header_size,
        .size_prefixed => wire.size_prefix_size + wire.root_offset_size,
        .size_prefixed_identifier => wire.size_prefix_size + wire.identified_header_size,
    };
}

fn NativeSizer(comptime purpose: Purpose) type {
    return struct {
        const Self = @This();
        options: ValueOptions,
        depth: usize = 0,
        work: usize = 0,

        fn table(self: *Self, comptime SchemaType: type, value: anytype) BuildError!usize {
            const fields = SchemaType.fields;
            const names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
            const value_info = @typeInfo(@TypeOf(value));
            if (value_info != .@"struct" or value_info.@"struct".field_names.len != names.len)
                @compileError("native storage value must match the schema");
            if (self.depth >= self.options.max_depth) return BuildError.DepthLimit;
            self.depth += 1;
            defer self.depth -= 1;
            try self.charge(names.len + 1, 1);
            const fixed_size = comptime tableSize(SchemaType);
            if (fixed_size > Builder.max_buffer_size) return BuildError.BufferTooLarge;
            var total: usize = fixed_size;
            inline for (names) |field_name| {
                const FieldType = @field(fields, field_name);
                if (!@hasField(@TypeOf(value), field_name))
                    @compileError("native storage value must match the schema");
                const current = @field(value, field_name);
                if (@TypeOf(current) != FieldType.Value)
                    @compileError("native storage value must match the schema");
                if (purpose == .serialize and FieldType.required) {
                    if (!schema.isPresent(FieldType, current))
                        return BuildError.MissingRequiredField;
                }
                total +|= switch (FieldType.kind) {
                    .scalar => 0,
                    .structure => |Layout| structure_size_blk: {
                        if (current != null) try self.charge(1, Layout.wire_size);
                        break :structure_size_blk 0;
                    },
                    .string => if (current) |value_slice|
                        try self.string(value_slice)
                    else
                        0,
                    .table => |Child| if (current) |child|
                        try self.table(Child.Schema, child.*)
                    else
                        0,
                    .union_value => |UnionType| try self.payload(UnionType, current),
                    .union_vector => if (current) |values|
                        try self.references(FieldType.kind, values)
                    else
                        0,
                    .vector => |Codec| if (current) |values| switch (Codec.kind) {
                        .scalar, .structure => vector_size_blk: {
                            try self.slice(values);
                            break :vector_size_blk sequenceSize(
                                values.len,
                                Codec.slot_size,
                                Codec.slot_alignment,
                            );
                        },
                        .string, .table => try self.references(FieldType.kind, values),
                    } else 0,
                };
            }
            if (total > Builder.max_buffer_size) return BuildError.BufferTooLarge;
            return total;
        }

        fn references(self: *Self, comptime kind: schema.Kind, values: anytype) BuildError!usize {
            try self.slice(values);
            var bytes = sequenceSize(values.len, wire.field_offset_size, wire.field_offset_size);
            for (values) |value| {
                bytes +|= switch (kind) {
                    .union_vector => |UnionType| try self.payload(UnionType, value),
                    .vector => |Codec| switch (Codec.kind) {
                        .string => try self.string(value),
                        .table => try self.table(Codec.Schema.Schema, value.*),
                        else => unreachable,
                    },
                    else => unreachable,
                };
            }
            if (kind == .union_vector)
                bytes +|= sequenceSize(values.len, @sizeOf(wire.UnionTag), @alignOf(wire.UnionTag));
            return bytes;
        }

        fn payload(self: *Self, comptime UnionType: type, value: UnionType.Value) BuildError!usize {
            const variants = UnionType.variants;
            return switch (value) {
                .none => 0,
                inline else => |current, selected| switch (@field(variants, @tagName(selected))) {
                    .table => |Child| try self.table(Child.Schema, current.*),
                    .structure => |Layout| structure_size_blk: {
                        try self.charge(1, Layout.wire_size);
                        break :structure_size_blk Layout.wire_size +| (Layout.wire_alignment - 1);
                    },
                    .string => try self.string(current),
                    .none => unreachable,
                },
            };
        }

        fn string(self: *Self, value: []const u8) BuildError!usize {
            try self.slice(value);
            return sequenceSize(value.len, 1, 1) +| wire.string_terminator_size;
        }

        fn slice(self: *Self, values: anytype) BuildError!void {
            if (values.len > Builder.max_buffer_size) return BuildError.BufferTooLarge;
            try self.charge(values.len, @sizeOf(std.meta.Elem(@TypeOf(values))));
        }

        fn charge(self: *Self, count_value: usize, comptime width: usize) BuildError!void {
            return schema.chargeNativeWork(&self.work, self.options.max_work, count_value, width);
        }
    };
}

fn sequenceSize(
    elements: anytype,
    comptime size: usize,
    comptime alignment: usize,
) @TypeOf(elements) {
    const Size = @TypeOf(elements);
    const element_size: Size = size;
    const length_size: Size = wire.sequence_length_size;
    const padding: Size = @max(wire.sequence_length_size, alignment) - 1;
    const overhead = length_size + padding;
    return if (Size == comptime_int)
        overhead + elements * element_size
    else
        overhead +| elements *| element_size;
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
