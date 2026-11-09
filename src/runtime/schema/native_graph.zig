//! Bounded native graph preflight and packing for schema adapters.
//! Preflight rejects output aliases before writes; packing may retain partial construction.
//! Inputs remain borrowed for both passes. No allocator is used, repeated pointers
//! produce independent copies, and traversal budgets bound cycles during preflight.
//! The schema facade selects ordinary framing and owns allocating serialization.
const std = @import("std");
const schema = @import("../schema.zig");
const buffer_access = @import("../buffer_access.zig");
const Builder = @import("../Builder.zig");
const errors = @import("../errors.zig");

const BuildError = errors.BuildError;

/// Specialize construction without exposing traversal methods on generated schemas.
/// Native must be the definition's nominal input type; a mismatch fails at compile time.
pub fn Packer(comptime Native: type, comptime Definition: type) type {
    // The public constructor retains the schema's nominal native type; structurally
    // identical child types must not silently use one another's schema.
    if (@typeInfo(@TypeOf(Definition.create)).@"fn".param_types[1].? != Native)
        @compileError("schema native type must match its referenced type");
    const field_names = @typeInfo(Native).@"struct".field_names;
    const descriptors = Definition.fields;
    return struct {
        /// Validate the complete graph before changing a ready builder, then pack its root.
        /// Preflight checks required values, depth/work, and output aliases; UTF-8 and
        /// capacity checks occur while packing. Packing can leave completed children.
        /// After successful preflight, force_defaults remains set even if packing fails.
        pub fn create(
            builder: *Builder,
            values: *const Native,
            options: schema.WriteOptions,
        ) BuildError!Builder.Offset {
            if (builder.state != .ready) return BuildError.InvalidState;
            var traversal: NativeTraversal = .{ .options = options };
            try validate(builder, values, &traversal);
            builder.force_defaults = options.force_defaults;
            return pack(builder, values);
        }

        // Inspect the complete graph before writes, so an earlier child cannot
        // corrupt a later child's native descriptors. Packing then visits it once
        // more without repeating graph validation or traversal accounting.
        fn validate(
            builder: *const Builder,
            values: *const Native,
            traversal: *NativeTraversal,
        ) BuildError!void {
            if (traversal.depth >= traversal.options.max_depth) return BuildError.DepthLimit;
            traversal.depth += 1;
            defer traversal.depth -= 1;
            try traversal.charge(field_names.len + 1, 1);
            try checkNativeInput(builder, std.mem.asBytes(values));
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                const value = @field(values.*, field_name);
                if (FieldType.required) {
                    if (!schema.isPresent(FieldType, value)) return BuildError.MissingRequiredField;
                }
                switch (FieldType.kind) {
                    .scalar => {},
                    .structure => |Layout| if (value != null) {
                        try traversal.charge(1, Layout.wire_size);
                    },
                    .string => if (value) |text| try validateNativeSlice(builder, text, traversal),
                    .table => |Child| if (value) |child| {
                        try checkNativeInput(builder, std.mem.asBytes(child));
                        try Packer(Child, Child.Schema).validate(builder, child, traversal);
                    },
                    .vector => |Codec| if (value) |elements| {
                        try validateNativeSlice(builder, elements, traversal);
                        switch (Codec.kind) {
                            .scalar, .structure => {},
                            .string => for (elements) |text| {
                                try validateNativeSlice(builder, text, traversal);
                            },
                            .table => for (elements) |child| {
                                try checkNativeInput(builder, std.mem.asBytes(child));
                                try Packer(Codec.Schema, Codec.Schema.Schema).validate(
                                    builder,
                                    child,
                                    traversal,
                                );
                            },
                        }
                    },
                    .union_value => |UnionType| try validateNativeUnion(
                        UnionType,
                        builder,
                        value,
                        traversal,
                    ),
                    .union_vector => |UnionType| if (value) |elements| {
                        try validateNativeSlice(builder, elements, traversal);
                        for (elements) |element|
                            try validateNativeUnion(UnionType, builder, element, traversal);
                    },
                }
            }
        }

        /// Pack after presence/traversal preflight into output disjoint from native inputs.
        /// create checks aliases; allocating serialization measures inputs and supplies
        /// fresh output. This entry point repeats neither graph budgets nor alias checks.
        /// Errors can retain partial children.
        pub fn pack(builder: *Builder, values: *const Native) BuildError!Builder.Offset {
            var built: Definition.Fields = undefined;
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                const value = @field(values.*, field_name);
                @field(built, field_name) = switch (FieldType.kind) {
                    .scalar, .structure => value,
                    .union_value => |UnionType| try packNativeUnion(UnionType, builder, value),
                    .union_vector => |UnionType| if (value) |elements|
                        try builder.createReferenceVector(elements, .{
                            .union_type = UnionType,
                            .create = packNativeUnion,
                        })
                    else
                        null,
                    .string => if (value) |text| try builder.createString(text) else null,
                    .table => |Child| if (value) |child|
                        try Packer(Child, Child.Schema).pack(builder, child)
                    else
                        null,
                    .vector => |Codec| if (value) |elements| switch (Codec.kind) {
                        .scalar => try builder.createVector(Codec.Value, elements),
                        .string => try builder.createStringVector(elements),
                        .structure => try builder.createStructVector(Codec.Layout, elements),
                        .table => try builder.createReferenceVector(elements, .{
                            .create = Packer(Codec.Schema, Codec.Schema.Schema).pack,
                        }),
                    } else null,
                };
            }
            var table = try Definition.Context.init(builder);
            try Definition.addFields(&table, built);
            return Definition.endTable(&table);
        }
    };
}

// Each successful charge proves multiplication and addition fit usize. Budget
// native descriptors before reading them, including zero-length sequences.
const NativeTraversal = struct {
    /// Native depth/work limits and default-retention policy for this preflight.
    options: schema.WriteOptions,
    /// Active native table depth; restored after each recursive visit.
    depth: usize = 0,
    /// Native visits/payload bytes charged so far, at or below options.max_work.
    work: usize = 0,

    fn charge(self: *NativeTraversal, count: usize, comptime width: usize) BuildError!void {
        return schema.chargeNativeWork(&self.work, self.options.max_work, count, width);
    }
};

fn checkNativeInput(builder: *const Builder, bytes: []const u8) BuildError!void {
    if (buffer_access.overlaps(builder.buffer, bytes)) return BuildError.AliasedInput;
}

fn validateNativeSlice(
    builder: *const Builder,
    values: anytype,
    traversal: *NativeTraversal,
) BuildError!void {
    if (values.len > Builder.max_buffer_size) return BuildError.BufferTooLarge;
    const Element = @typeInfo(@TypeOf(values)).pointer.child;
    try traversal.charge(values.len, @sizeOf(Element));
    try checkNativeInput(builder, std.mem.sliceAsBytes(values));
}

fn validateNativeUnion(
    comptime UnionType: type,
    builder: *const Builder,
    value: UnionType.Value,
    traversal: *NativeTraversal,
) BuildError!void {
    switch (value) {
        .none => {},
        inline else => |payload, selected| switch (@field(UnionType.variants, @tagName(selected))) {
            .table => |Child| {
                try checkNativeInput(builder, std.mem.asBytes(payload));
                try Packer(Child, Child.Schema).validate(builder, payload, traversal);
            },
            .structure => |Layout| try traversal.charge(1, Layout.wire_size),
            .string => try validateNativeSlice(builder, payload, traversal),
            .none => unreachable,
        },
    }
}

fn packNativeUnion(
    comptime UnionType: type,
    builder: *Builder,
    value: UnionType.Value,
) BuildError!UnionType.Handle {
    return switch (value) {
        .none => .none,
        inline else => |payload, selected| @unionInit(
            UnionType.Handle,
            @tagName(selected),
            switch (@field(UnionType.variants, @tagName(selected))) {
                .table => |Child| try Packer(Child, Child.Schema).pack(builder, payload),
                .structure => |Layout| try builder.createStruct(Layout, payload),
                .string => try builder.createString(payload),
                .none => unreachable,
            },
        ),
    };
}
