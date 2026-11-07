//! Compile-time schema facts shared by generated access/build/verify adapters.
//! Field names select metadata; explicit wire IDs determine physical slots.
//! References are named types, so recursive schemas are resolved lazily.
//!
//! Example inside a test with `std = @import("std")` and
//! `runtime = @import("flatzz")` imported:
//! ```zig
//! const Values = struct { count: u32 = 0 };
//! const Definition = runtime.Schema(Values, .{
//!     .count = runtime.ScalarField(u32, 0, 0),
//! });
//! var storage: runtime.Storage(Definition, .{}, .{}) = .{};
//! const value: Values = .{ .count = 42 };
//! const bytes = try Definition.serialize(value, &storage.buffer, .{ .force_defaults = true });
//! const before = try Definition.readRoot(bytes);
//! const changed = try Definition.updateRoot(bytes, .count, 7);
//! const after = try Definition.readRoot(bytes);
//! try Definition.verifyRoot(bytes, .{});
//! try std.testing.expectEqual(@as(u32, 42), before.count);
//! try std.testing.expect(changed);
//! try std.testing.expectEqual(@as(u32, 7), after.count);
//! ```
//! Expected result: `before.count == 42`, `changed == true`, `after.count == 7`.
//! No output is printed. `bytes` borrows `storage.buffer`; reusing that storage
//! invalidates views. Writing may leave partial builder data on failure.
const std = @import("std");
const wire = @import("wire.zig");
const sequence = @import("sequence.zig");
const validation = @import("validation.zig");
const table_view = @import("table_view.zig");
const Builder = @import("Builder.zig");
const table_builder = @import("table_builder.zig");
const Verifier = @import("Verifier.zig");
const errors = @import("errors.zig");
const struct_view = @import("struct_view.zig");
const unions = @import("unions.zig");

const AccessError = errors.AccessError;
const MutationError = errors.MutationError;
const BuildError = errors.BuildError;
const VerifyError = errors.VerifyError;

const TableBuilder = table_builder.TableBuilder;
const Table = table_view.TableView(.read_only);
const MutableTable = table_view.TableView(.mutable);
const StructView = struct_view.StructView;

/// Wire interpretation carried by a field descriptor; native types alone are insufficient.
pub const Kind = union(enum) {
    /// Fixed-width scalar or optional scalar type.
    scalar: type,
    /// Inline struct layout, without a reference offset.
    structure: type,
    /// Offset to length-prefixed, terminated UTF-8 bytes.
    string,
    /// Offset to a vector interpreted by an element codec.
    vector: type,
    /// Offset to a child table described by a named schema type.
    table: type,
    /// Paired discriminator and payload slots for one union.
    union_value: type,
    /// Paired discriminator and payload vectors for a union sequence.
    union_vector: type,
};

/// Presence policy used by reference and union descriptors.
pub const ReferenceOptions = struct {
    /// Builders and full verification reject absence; empty present values are valid.
    required: bool = false,
};

/// Serialization omits values equal to their schema defaults unless requested.
pub const WriteOptions = struct {
    /// Retain default-valued fields so the resulting buffer can mutate them.
    /// Null optional scalars remain absent; present optional values are retained.
    force_defaults: bool = false,
    /// Maximum active native table depth; zero rejects the root. Cycles hit this limit.
    max_depth: usize = 64,
    /// Bound table/field visits and native payload bytes before packing or scanning strings.
    max_work: usize = 64 * 1024 * 1024,
};

/// Describe one union using adjacent physical tag/value IDs.
/// `UnionType.Value` carries native payloads; `.none` represents absence.
/// Invalid IDs fail at compile time. Use `UnionVectorField` for paired vectors.
pub fn UnionField(
    comptime UnionType: type,
    comptime field_ids: unions.FieldIds,
    comptime options: ReferenceOptions,
) type {
    return UnionDescriptor(UnionType, field_ids, options, false);
}

/// Describe paired union vectors using adjacent physical tag/value IDs.
/// Native values are nullable slices of `UnionType.Value`; null is absent,
/// while an empty slice is present. Invalid IDs fail at compile time.
pub fn UnionVectorField(
    comptime UnionType: type,
    comptime field_ids: unions.FieldIds,
    comptime options: ReferenceOptions,
) type {
    return UnionDescriptor(UnionType, field_ids, options, true);
}

fn UnionDescriptor(
    comptime UnionType: type,
    comptime wire_ids: unions.FieldIds,
    comptime options: ReferenceOptions,
    comptime vector: bool,
) type {
    if (wire_ids.tag >= wire.max_field_count or wire_ids.value >= wire.max_field_count)
        @compileError("field ID exceeds the maximum vtable size");
    if (wire_ids.value != wire_ids.tag + 1)
        @compileError("union value ID must immediately follow tag ID");
    return struct {
        /// Native construction value; non-none alternatives contain borrowed native payloads.
        pub const Value = if (vector)
            ?[]const UnionType.Value
        else
            UnionType.Value;
        /// Borrowed read result; payload access retains the input frame.
        pub const View = if (vector)
            ?unions.VectorView(UnionType, .read_only)
        else
            UnionType.View(.read_only);
        /// Selects single-union versus paired-vector handling.
        pub const kind: Kind = if (vector)
            .{ .union_vector = UnionType }
        else
            .{ .union_value = UnionType };
        /// Physical payload slot; the discriminator occupies the preceding ID.
        pub const wire_id = wire_ids.value;
        /// Physical discriminator and payload IDs consumed together.
        pub const field_ids = wire_ids;
        /// Whether building and verification require a present value.
        pub const required = options.required;
    };
}

/// Physical slots include synthetic union discriminators. Native reflection
/// still describes one logical field, independent of declaration order.
pub fn wireIds(comptime FieldType: type) []const usize {
    return switch (FieldType.kind) {
        .union_value, .union_vector => &.{
            FieldType.field_ids.tag, FieldType.wire_id,
        },
        else => &.{FieldType.wire_id},
    };
}

/// An inline table field with a nullable native value representing presence.
pub fn StructField(
    comptime Layout: type,
    comptime field_id: usize,
    comptime options: struct {
        /// Require a present inline struct during building and full verification.
        required: bool = false,
    },
) type {
    if (Layout.layout_kind != .structure)
        @compileError("table struct fields require a struct layout");
    return struct {
        /// Native struct value; null represents an absent table field.
        pub const Value = ?Layout.Value;
        /// Borrowed inline struct; null represents absence.
        pub const View = ?StructView(Layout, .read_only);
        /// Inline wire layout used by accessors, builders, and verification.
        pub const kind: Kind = .{ .structure = Layout };
        /// Physical vtable field ID, independent of the native field order.
        pub const wire_id = field_id;
        /// Whether building and verification require a present value.
        pub const required = options.required;
    };
}

/// Describe a fixed-width FlatBuffers scalar and its typed schema default.
/// Optional scalars must default to null; a present zero remains distinct from absence.
/// Unsupported scalar types and non-null optional defaults fail at compile time.
pub fn ScalarField(
    comptime ValueType: type,
    comptime field_id: usize,
    comptime field_default: ValueType,
) type {
    _ = wire.Scalar(ValueType);
    if (@typeInfo(ValueType) == .optional and field_default != null)
        @compileError("optional scalars must default to null");
    return struct {
        /// Native scalar type, including optional presence when requested.
        pub const Value = ValueType;
        /// Copied scalar read result, independent of the buffer lifetime.
        pub const View = ValueType;
        /// Scalar interpretation, including optional native presence.
        pub const kind: Kind = .{ .scalar = ValueType };
        /// Physical vtable field ID, independent of the native field order.
        pub const wire_id = field_id;
        /// Value returned for an absent slot and normally omitted during building.
        pub const default = field_default;
        /// Scalar absence uses the schema default rather than required-field validation.
        pub const required = false;
    };
}

/// Strings, byte vectors, and references are distinct wire kinds even when
/// their native values use the same Zig pointer/slice representation.
/// Null denotes absence; empty slices denote present values. Child tables are
/// packed recursively by create/serialize or supplied as offsets to `Schema.addFields`.
pub fn ReferenceField(
    comptime field_id: usize,
    comptime field_kind: Kind,
    comptime options: ReferenceOptions,
) type {
    return struct {
        /// Wire interpretation; scalar, struct, and union kinds use dedicated factories.
        pub const kind = field_kind;
        /// Physical vtable field ID, independent of the native field order.
        pub const wire_id = field_id;
        /// Whether building and verification require a present value.
        pub const required = options.required;
        /// Native construction value; table pointers describe children.
        /// Recursive packing borrows these children for the duration of the call.
        pub const Value = switch (kind) {
            .scalar => @compileError("use ScalarField for typed defaults"),
            .structure => @compileError("use StructField for inline values"),
            .union_value, .union_vector => @compileError("use a union field descriptor"),
            .string => ?[]const u8,
            .vector => |ElementCodec| switch (ElementCodec.kind) {
                .scalar, .string, .structure => ?[]const sequence.NativeValue(ElementCodec),
                .table => ?[]const *const ElementCodec.Schema,
            },
            .table => |ChildSchema| ?*const ChildSchema,
        };
        /// Nullable borrowed string, sequence, or child table.
        pub const View = switch (kind) {
            .scalar, .structure, .union_value, .union_vector => unreachable,
            .string => ?[]const u8,
            .vector => |ElementCodec| ?sequence.SequenceView(ElementCodec, .read_only),
            .table => ?Table,
        };
    };
}

/// A heterogeneous struct of descriptor types keeps typed defaults without
/// runtime metadata, erased pointers, or allocation. @Struct derives the
/// borrowed result only; it never defines a serialized memory layout.
/// Native fields and descriptor value types must match exactly. Physical wire IDs
/// may be sparse, but duplicates and IDs beyond the vtable limit fail at compile time.
/// See the module example for storage, serialization, reading, updating, and verification.
pub fn Schema(comptime Native: type, comptime descriptors: anytype) type {
    const native_info = @typeInfo(Native).@"struct";
    const field_names = native_info.field_names;
    const descriptor_names = @typeInfo(@TypeOf(descriptors)).@"struct".field_names;
    const slot_count = comptime field_slots_blk: {
        if (field_names.len != descriptor_names.len) @compileError(
            "schema descriptor fields must match native fields",
        );
        var maximum_count: usize = 0;
        for (field_names, native_info.field_types) |field_name, ValueType| {
            if (!@hasField(@TypeOf(descriptors), field_name)) @compileError(
                "missing schema field descriptor",
            );
            const DescriptorType = @field(descriptors, field_name);
            if (DescriptorType.Value != ValueType) @compileError(
                "schema descriptor value type mismatch",
            );
            for (wireIds(DescriptorType)) |field_id| {
                if (field_id >= wire.max_field_count) @compileError(
                    "field ID exceeds the maximum vtable size",
                );
                maximum_count = @max(maximum_count, field_id + 1);
            }
        }
        // Physical IDs are bounded by the wire format. A comptime-only array
        // avoids quadratic scans and adds no runtime metadata or allocation.
        var occupied_ids: [maximum_count]bool = @splat(false);
        for (field_names) |field_name| {
            for (wireIds(@field(descriptors, field_name))) |field_id| {
                if (occupied_ids[field_id]) @compileError("duplicate schema wire field ID");
                occupied_ids[field_id] = true;
            }
        }
        break :field_slots_blk maximum_count;
    };
    return struct {
        const Self = @This();

        /// Native field names accepted by descriptor lookup and typed updates.
        pub const Field = std.meta.FieldEnum(Native);
        /// Number of physical vtable slots, including sparse gaps and union tags.
        pub const field_count = slot_count;
        /// Compile-time descriptor record keyed by native field name.
        pub const fields = descriptors;
        /// Named inputs for explicit construction with this builder's completed handles.
        /// Scalars and inline structs retain native types/defaults. References use
        /// nullable Offset values; unions use Handle and nullable UnionVector values.
        /// Null references/vectors and none unions are absent; empty built vectors
        /// remain present. Handles must belong to the builder since its last reset.
        pub const Fields = fields_type_blk: {
            var field_types: [field_names.len]type = undefined;
            var attributes: [field_names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
            for (field_names, 0..) |field_name, field_index| {
                const FieldType = @field(descriptors, field_name);
                const Value = switch (FieldType.kind) {
                    .scalar, .structure => FieldType.Value,
                    .union_value => |UnionType| UnionType.Handle,
                    .union_vector => ?Builder.UnionVector,
                    else => ?Builder.Offset,
                };
                field_types[field_index] = Value;
                attributes[field_index] = switch (FieldType.kind) {
                    .scalar, .structure => native_info.field_attrs[field_index],
                    else => default_value_blk: {
                        const absent: Value = if (FieldType.kind == .union_value) .none else null;
                        break :default_value_blk .{ .default_value_ptr = &absent };
                    },
                };
            }
            break :fields_type_blk @Struct(.auto, null, field_names, &field_types, &attributes);
        };
        /// Raw per-table operations; use endTable below for schema finalization.
        pub const Context = TableBuilder(slot_count);
        /// Read result combining copied scalars with borrowed reference and inline views.
        pub const View = view_type_blk: {
            var field_types: [field_names.len]type = undefined;
            for (field_names, 0..) |field_name, field_index| {
                field_types[field_index] = @field(descriptors, field_name).View;
            }
            break :view_type_blk @Struct(
                .auto,
                null,
                field_names,
                &field_types,
                &@splat(.{}),
            );
        };

        /// Resolve a native field name to its compile-time descriptor type.
        pub fn Descriptor(comptime field: Field) type {
            return @field(descriptors, @tagName(field));
        }

        /// Serialize a native graph as an ordinary root without heap allocation.
        /// Every supported field kind is packed, including child tables and unions.
        /// Preflight bounds traversal, checks required values, and rejects any input
        /// overlapping usable output storage before writes. UTF-8 is checked while packing.
        /// Table/union vectors reuse output capacity for temporary u32 offsets;
        /// no separate vector scratch budget is needed.
        /// Repeated table pointers produce independent copies; use explicit Builder
        /// handles with addFields to preserve sharing. Traversal limits bound cycles.
        /// The mutable result borrows a suffix of the alignment-trimmed storage.
        /// Storage reuse invalidates it and its views. Packing errors can leave
        /// partial bytes; preflight errors leave storage unchanged.
        pub fn serialize(
            values: Native,
            output_storage: []align(wire.storage_alignment) u8,
            options: WriteOptions,
        ) BuildError![]u8 {
            var builder = Builder.init(output_storage);
            return builder.finish(try create(&builder, values, options), .ordinary);
        }

        /// Read an ordinary root without requiring a file identifier; references borrow `bytes`.
        /// Vector elements remain lazy; use verifyRoot for complete traversal.
        pub fn readRoot(bytes: []const u8) AccessError!View {
            return read(try Table.from(bytes, .root));
        }

        /// Updates a present root field with the same size and aliasing rules as
        /// update. Missing fields return false; null cannot remove a present one.
        pub fn updateRoot(
            bytes: []u8,
            comptime field: Field,
            value: Descriptor(field).Value,
        ) MutationError!bool {
            return update(try MutableTable.from(bytes, .root), field, value);
        }

        /// Verifies every known field using the requested framing and limits.
        /// The native value type need not expose a Schema declaration.
        pub fn verifyRoot(
            bytes: []const u8,
            options: Verifier.Options,
        ) VerifyError!void {
            return Verifier.verify(struct {
                pub const Schema = Self;
            }, bytes, options);
        }

        /// The descriptor-selected borrowed view for a structured field.
        /// Absent structs, vectors, and tables return null; union values use
        /// their .none variant. Scalars and strings use update instead.
        pub fn MutableView(comptime field: Field) type {
            return switch (Descriptor(field).kind) {
                .structure => |Layout| ?StructView(Layout, .mutable),
                .vector => |ElementCodec| ?sequence.SequenceView(ElementCodec, .mutable),
                .table => ?MutableTable,
                .union_value => |UnionType| UnionType.View(.mutable),
                .union_vector => |UnionType| ?unions.VectorView(UnionType, .mutable),
                .scalar, .string => @compileError(
                    "borrowMutable requires a structured field; use update for scalars and strings",
                ),
            };
        }

        /// Borrows a field from an already checked mutable table without copying.
        /// Generated tables expose this as `Reading.borrowMutable(table, .field)`.
        /// Open the table once with the required framing and reuse it for fields.
        /// Struct and union payloads retain mutation capabilities; vector elements
        /// retain their codec's access rules. Storage reuse invalidates all views.
        ///
        /// Fragment inside a function with `runtime = @import("flatzz")`, a matching
        /// `Schema`, and mutable root `bytes`. For a `.location` StructField whose
        /// layout has an `.altitude` member:
        /// ```zig
        /// const table = try runtime.MutableTable.from(bytes, .root);
        /// if (try Schema.borrowMutable(table, .location)) |location|
        ///     try location.update(.altitude, 12);
        /// ```
        /// Subsequent reads observe altitude = 12; an absent location stays absent.
        pub fn borrowMutable(
            table: MutableTable,
            comptime field: Field,
        ) AccessError!MutableView(field) {
            const FieldType = Descriptor(field);
            return switch (FieldType.kind) {
                .structure => |Layout| table.readStruct(Layout, FieldType.wire_id),
                .vector => |ElementCodec| table.readVector(ElementCodec, FieldType.wire_id),
                .table => table.readTable(FieldType.wire_id),
                .union_value => |UnionType| table.readUnion(UnionType, FieldType.field_ids),
                .union_vector => |UnionType| table.readUnionVector(UnionType, FieldType.field_ids),
                .scalar, .string => unreachable,
            };
        }

        /// Read every known field from a checked table; absent slots use defaults.
        /// Reference contents remain borrowed and vector elements are checked lazily.
        /// Required-field completeness belongs to `verifyRoot`, not this accessor.
        pub fn read(table: Table) AccessError!View {
            var result: View = undefined;
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                @field(result, field_name) = switch (FieldType.kind) {
                    .scalar => |ValueType| try table.readField(
                        ValueType,
                        FieldType.wire_id,
                        FieldType.default,
                    ),
                    .string => try table.readString(FieldType.wire_id),
                    .structure => |Layout| try table.readStruct(Layout, FieldType.wire_id),
                    .vector => |ElementCodec| try table.readVector(ElementCodec, FieldType.wire_id),
                    .table => try table.readTable(FieldType.wire_id),
                    .union_value => |UnionType| try table.readUnion(UnionType, FieldType.field_ids),
                    .union_vector => |UnionType| try table.readUnionVector(
                        UnionType,
                        FieldType.field_ids,
                    ),
                };
            }
            return result;
        }

        /// Replace one present field without growing the buffer; return false for absence.
        /// Null cannot clear a present value, and sequence lengths must match.
        /// Read-only views, child table replacement, and whole-union replacement
        /// are rejected at compile time. Errors leave the target bytes unchanged.
        pub fn update(
            table: MutableTable,
            comptime field: Field,
            value: Descriptor(field).Value,
        ) MutationError!bool {
            const FieldType = Descriptor(field);
            return switch (FieldType.kind) {
                .scalar => |ValueType| table.mutateField(ValueType, FieldType.wire_id, value),
                .string => table.mutateString(FieldType.wire_id, value),
                .structure => |Layout| table.mutateStruct(Layout, FieldType.wire_id, value),
                .vector => |ElementCodec| table.mutateVector(
                    ElementCodec,
                    FieldType.wire_id,
                    value,
                ),
                .table => @compileError("update child fields through MutableTable.readTable"),
                .union_value, .union_vector => @compileError(
                    "union replacement requires rebuilding; mutate borrowed payload fields",
                ),
            };
        }

        /// Pack a native graph into an existing ready builder, returning its table handle.
        /// Options bound traversal and select default-field retention. After preflight,
        /// force_defaults becomes the builder's policy, including after packing errors.
        /// All inputs must remain valid and must not borrow builder storage.
        /// Preflight failures leave storage unchanged; packing failures may retain
        /// partial children. Reset the builder to discard partial construction.
        /// Use addFields with completed handles in Fields for explicit sharing.
        pub fn create(
            builder: *Builder,
            values: Native,
            options: WriteOptions,
        ) BuildError!Builder.Offset {
            if (builder.state != .ready) return BuildError.InvalidState;
            var traversal: NativeTraversal = .{ .options = options };
            try validateNative(builder, &values, &traversal);
            builder.force_defaults = options.force_defaults;
            return packNative(builder, &values);
        }

        /// Add named Fields after building their referenced children with this builder.
        /// Scalars/inline structs are native values; other fields hold completed handles.
        /// Required presence and single-union handles are checked before any additions.
        /// Later state, capacity, or handle errors can leave earlier fields written and
        /// the context active. Numeric handles cannot establish ownership or object type.
        pub fn addFields(table: *Context, values: Fields) BuildError!void {
            // Check required presence before writing any fields. Union vector pairs
            // are one optional value, so a half-present pair cannot be supplied.
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                const value = @field(values, field_name);
                switch (FieldType.kind) {
                    .union_value => |UnionType| if (UnionType.offset(value)) |handle| {
                        try table.builder.checkOffset(handle, table.table_end);
                    },
                    else => {},
                }
                if (FieldType.required) {
                    const present = switch (FieldType.kind) {
                        .union_value => std.meta.activeTag(value) != .none,
                        else => value != null,
                    };
                    if (!present) return BuildError.MissingRequiredField;
                }
            }
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                const value = @field(values, field_name);
                switch (FieldType.kind) {
                    .scalar => |ValueType| try table.addScalar(
                        ValueType,
                        FieldType.wire_id,
                        value,
                        FieldType.default,
                    ),
                    .string, .vector, .table => try table.addOffset(FieldType.wire_id, value),
                    .structure => |Layout| try table.addStruct(Layout, FieldType.wire_id, value),
                    .union_value => |UnionType| try table.addUnion(
                        UnionType,
                        FieldType.field_ids,
                        value,
                    ),
                    .union_vector => try table.addUnionVector(FieldType.field_ids, value),
                }
            }
        }

        /// Required-slot checks precede finalization writes. A missing untouched
        /// slot leaves the context active so incremental callers can supply it
        /// and retry. Explicit omissions also fail; raw Context.endTable bypasses
        /// schema enforcement, as does the standalone TableBuilder API.
        pub fn endTable(table: *Context) BuildError!Builder.Offset {
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                switch (FieldType.kind) {
                    .union_value, .union_vector => |UnionType| try table.requireUnion(
                        UnionType,
                        FieldType.field_ids,
                        FieldType.required,
                        FieldType.kind == .union_vector,
                    ),
                    else => if (FieldType.required)
                        try table.requireField(FieldType.wire_id),
                }
            }
            return table.endTable();
        }

        /// Generated traversal specializes field facts; resource accounting stays
        /// in Verifier. Unknown newer fields are deliberately not traversed.
        pub fn verifyFields(
            verifier: *Verifier,
            table: Table,
        ) VerifyError!void {
            const physical_count = comptime physical_field_count_blk: {
                var count: usize = 0;
                for (field_names) |field_name|
                    count += wireIds(@field(descriptors, field_name)).len;
                break :physical_field_count_blk count;
            };
            try verifier.charge(physical_count);
            inline for (field_names) |field_name| {
                try verifier.verifyField(@field(descriptors, field_name), table);
            }
        }

        // Inspect the complete graph before writes, so an earlier child cannot
        // corrupt a later child's native descriptors. Packing then visits it once
        // more without repeating graph validation or traversal accounting.
        fn validateNative(
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
                    const present = switch (FieldType.kind) {
                        .union_value => std.meta.activeTag(value) != .none,
                        else => value != null,
                    };
                    if (!present) return BuildError.MissingRequiredField;
                }
                switch (FieldType.kind) {
                    .scalar => {},
                    .structure => |Layout| if (value != null) {
                        try traversal.charge(1, Layout.wire_size);
                    },
                    .string => if (value) |text| try validateNativeSlice(builder, text, traversal),
                    .table => |Child| if (value) |child| {
                        try checkNativeInput(builder, std.mem.asBytes(child));
                        try Child.Schema.validateNative(builder, child, traversal);
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
                                try Codec.Schema.Schema.validateNative(builder, child, traversal);
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

        fn packNative(builder: *Builder, values: *const Native) BuildError!Builder.Offset {
            var built: Fields = undefined;
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
                        try Child.Schema.packNative(builder, child)
                    else
                        null,
                    .vector => |Codec| if (value) |elements| switch (Codec.kind) {
                        .scalar => try builder.createVector(Codec.Value, elements),
                        .string => try builder.createStringVector(elements),
                        .structure => try builder.createStructVector(Codec.Layout, elements),
                        .table => try builder.createReferenceVector(elements, .{
                            .create = Codec.Schema.Schema.packNative,
                        }),
                    } else null,
                };
            }
            var table = try Context.init(builder);
            try addFields(&table, built);
            return endTable(&table);
        }
    };
}

// Each successful charge proves multiplication and addition fit usize. Budget
// native descriptors before reading them, including zero-length sequences.
const NativeTraversal = struct {
    options: WriteOptions,
    depth: usize = 0,
    work: usize = 0,

    fn charge(self: *NativeTraversal, count: usize, comptime width: usize) BuildError!void {
        if (width != 0 and count > (self.options.max_work - self.work) / width)
            return BuildError.WorkLimit;
        self.work += count * width;
    }
};

fn checkNativeInput(builder: *const Builder, bytes: []const u8) BuildError!void {
    if (validation.overlaps(builder.buffer, bytes)) return BuildError.AliasedInput;
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
                try Child.Schema.validateNative(builder, payload, traversal);
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
                .table => |Child| try Child.Schema.packNative(builder, payload),
                .structure => |Layout| try builder.createStruct(Layout, payload),
                .string => try builder.createString(payload),
                .none => unreachable,
            },
        ),
    };
}
