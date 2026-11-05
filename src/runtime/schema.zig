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
//! const bytes = try Definition.writeRoot(&storage.buffer,
//!     .{ .count = 42 }, .{ .force_defaults = true });
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
const standard_library = @import("std");
const wire = @import("wire.zig");
const sequence = @import("sequence.zig");
const views = @import("table_view.zig");
const Builder = @import("Builder.zig");
const TableBuilder = @import("table_builder.zig").TableBuilder;
const Verifier = @import("Verifier.zig");
const errors = @import("errors.zig");
const Table = views.TableView(.read_only);
const MutableTable = views.TableView(.mutable);
const StructView = @import("struct_view.zig").StructView;
const unions = @import("unions.zig");

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

/// Root writers omit values equal to their schema defaults unless requested.
pub const WriteOptions = struct {
    /// Retain default-valued fields so the resulting buffer can mutate them.
    /// Null optional scalars remain absent; present optional values are retained.
    force_defaults: bool = false,
};

/// Describe one union using adjacent physical tag/value IDs.
/// `UnionType.Value` carries completed child handles; `.none` represents absence.
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
        /// Native construction value; non-none alternatives contain completed handles.
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
    switch (@typeInfo(ValueType)) {
        .optional => if (field_default != null) @compileError(
            "optional scalars must default to null",
        ),
        else => {},
    }
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
/// built explicitly and supplied as offsets to `Schema.addFields`.
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
        /// Native construction value; table pointers describe children but are not serialized recursively.
        pub const Value = switch (kind) {
            .scalar => @compileError("use ScalarField for typed defaults"),
            .structure => @compileError("use StructField for inline values"),
            .union_value, .union_vector => @compileError(
                "use a union field descriptor",
            ),
            .string => ?[]const u8,
            .vector => |ElementCodec| switch (ElementCodec.kind) {
                .scalar, .string, .structure => ?[]const sequence.NativeValue(
                    ElementCodec,
                ),
                .table => ?[]const *const ElementCodec.Schema,
            },
            .table => |ChildSchema| ?*const ChildSchema,
        };
        /// Nullable borrowed string, sequence, or child table.
        pub const View = switch (kind) {
            .scalar, .structure, .union_value, .union_vector => unreachable,
            .string => ?[]const u8,
            .vector => |ElementCodec| ?sequence.Sequence(ElementCodec),
            .table => ?Table,
        };
    };
}

/// A heterogeneous struct of descriptor types keeps typed defaults without
/// runtime metadata, erased pointers, or allocation. @Struct derives the
/// borrowed result only; it never defines a serialized memory layout.
/// Native fields and descriptor value types must match exactly. Physical wire IDs
/// may be sparse, but duplicates and IDs beyond the vtable limit fail at compile time.
/// See the module example for storage, root writing, reading, updating, and verification.
pub fn Schema(comptime Native: type, comptime descriptors: anytype) type {
    const native_info = @typeInfo(Native).@"struct";
    const field_names = native_info.field_names;
    const descriptor_names = @typeInfo(@TypeOf(descriptors)).@"struct".field_names;
    const slot_count = comptime blk_slots: {
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
                if (occupied_ids[field_id]) @compileError(
                    "duplicate schema wire field ID",
                );
                occupied_ids[field_id] = true;
            }
        }
        break :blk_slots maximum_count;
    };
    return struct {
        const Self = @This();

        /// Native field names accepted by descriptor lookup and typed updates.
        pub const Field = standard_library.meta.FieldEnum(Native);
        /// Number of physical vtable slots, including sparse gaps and union tags.
        pub const field_count = slot_count;
        /// Compile-time descriptor record keyed by native field name.
        pub const fields = descriptors;
        /// Completed child handles indexed by physical wire ID; null means absent.
        pub const Offsets = [slot_count]?Builder.Offset;
        /// Raw per-table operations; use endTable below for schema finalization.
        pub const Context = TableBuilder(slot_count);
        /// Read result combining copied scalars with borrowed reference and inline views.
        pub const View = blk_view: {
            var field_types: [field_names.len]type = undefined;
            for (field_names, 0..) |field_name, field_index| {
                field_types[field_index] = @field(descriptors, field_name).View;
            }
            break :blk_view @Struct(
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

        /// Builds an ordinary root buffer, borrowing the aligned output storage.
        /// Uses create's child-before-parent restrictions; callers with explicit
        /// child handles or other framing use Builder and addFields directly.
        ///
        /// Generated definitions can expose this without repeating its body:
        /// `pub const write = Schema.writeRoot;`
        pub fn writeRoot(
            out: []align(wire.storage_alignment) u8,
            values: Native,
            options: WriteOptions,
        ) errors.BuildError![]u8 {
            var builder = Builder.init(out);
            builder.force_defaults = options.force_defaults;
            return builder.finish(try create(&builder, values), .ordinary);
        }

        /// Reads an ordinary root without requiring a file identifier.
        /// Vector elements remain lazy; use verifyRoot for complete traversal.
        pub fn readRoot(bytes: []const u8) errors.AccessError!View {
            return read(try Table.from(bytes, .root));
        }

        /// Updates a present root field with the same size and aliasing rules as
        /// update. Missing fields return false; null cannot remove a present one.
        pub fn updateRoot(
            bytes: []u8,
            comptime field: Field,
            value: Descriptor(field).Value,
        ) errors.MutationError!bool {
            return update(try MutableTable.from(bytes, .root), field, value);
        }

        /// Verifies every known field using the requested framing and limits.
        /// The native value type need not expose a Schema declaration.
        pub fn verifyRoot(
            bytes: []const u8,
            options: Verifier.Options,
        ) errors.VerifyError!void {
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
        ) errors.AccessError!MutableView(field) {
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
        pub fn read(table: Table) errors.AccessError!View {
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
                    .structure => |Layout| try table.readStruct(
                        Layout,
                        FieldType.wire_id,
                    ),
                    .vector => |ElementCodec| try table.readVector(
                        ElementCodec,
                        FieldType.wire_id,
                    ),
                    .table => try table.readTable(FieldType.wire_id),
                    .union_value => |UnionType| try table.readUnion(
                        UnionType,
                        FieldType.field_ids,
                    ),
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
        ) errors.MutationError!bool {
            const FieldType = Descriptor(field);
            return switch (FieldType.kind) {
                .scalar => |ValueType| table.mutateField(
                    ValueType,
                    FieldType.wire_id,
                    value,
                ),
                .string => table.mutateString(FieldType.wire_id, value),
                .structure => |Layout| table.mutateStruct(
                    Layout,
                    FieldType.wire_id,
                    value,
                ),
                .vector => |ElementCodec| table.mutateVector(
                    ElementCodec,
                    FieldType.wire_id,
                    value,
                ),
                .table => @compileError(
                    "update child fields through MutableTable.readTable",
                ),
                .union_value, .union_vector => @compileError(
                    "union replacement requires rebuilding; mutate borrowed payload fields",
                ),
            };
        }

        /// Children precede the parent context. This convenience handles current
        /// scalar/struct/sequence schemas and paired union vectors. Union values
        /// carry explicit child handles. Other tables pass handles to addFields;
        /// this function does not recursively walk native object graphs.
        pub fn create(
            builder: *Builder,
            values: Native,
        ) errors.BuildError!Builder.Offset {
            // Reject missing required values before creating any child payloads.
            // Presence is distinct from length: empty strings/vectors are valid.
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                if (FieldType.required) {
                    const present = switch (FieldType.kind) {
                        .union_value => |UnionType| UnionType.tag(
                            @field(values, field_name),
                        ) != .none,
                        else => @field(values, field_name) != null,
                    };
                    if (!present)
                        return errors.BuildError.MissingRequiredField;
                }
                switch (FieldType.kind) {
                    .union_value => |UnionType| {
                        if (UnionType.offset(@field(values, field_name))) |handle|
                            try builder.checkOffset(handle, builder.used());
                    },
                    else => {},
                }
            }
            var offsets: Offsets = @splat(null);
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                switch (FieldType.kind) {
                    .scalar, .structure, .union_value => {},
                    .union_vector => |UnionType| if (@field(values, field_name)) |value| {
                        const handles = try builder.createUnionVector(
                            UnionType,
                            value,
                        );
                        offsets[FieldType.field_ids.tag] = handles.tag;
                        offsets[FieldType.wire_id] = handles.value;
                    },
                    .string => if (@field(values, field_name)) |value| {
                        offsets[FieldType.wire_id] = try builder.createString(
                            value,
                        );
                    },
                    .vector => |ElementCodec| if (@field(
                        values,
                        field_name,
                    )) |value| {
                        offsets[FieldType.wire_id] = switch (ElementCodec.kind) {
                            .scalar => try builder.createVector(
                                ElementCodec.Value,
                                value,
                            ),
                            .string => try builder.createStringVector(value),
                            .structure => try builder.createStructVector(
                                ElementCodec.Layout,
                                value,
                            ),
                            .table => @compileError(
                                "build child tables first and use addFields",
                            ),
                        };
                    },
                    .table => @compileError(
                        "build child tables first and use addFields",
                    ),
                }
            }
            var table = try Context.init(builder);
            try addFields(&table, values, offsets);
            return endTable(&table);
        }

        /// Reuses IDs/defaults while preserving explicit child-before-parent order.
        /// offsets is indexed by physical wire ID, including gaps in older schemas.
        /// Reference handles are authoritative; native reference values need not
        /// be populated when callers build child objects explicitly.
        pub fn addFields(
            table: *Context,
            values: Native,
            offsets: Offsets,
        ) errors.BuildError!void {
            // Inline values use native presence; references use child handles.
            // Check both before writing any fields so missing-required is atomic.
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                switch (FieldType.kind) {
                    .union_value => |UnionType| {
                        // This tagged value owns its completed handle; offsets
                        // remain authoritative for ordinary references/vectors.
                        if (offsets[FieldType.wire_id] != null or
                            offsets[FieldType.field_ids.tag] != null)
                            return errors.BuildError.InvalidUnion;
                        if (UnionType.offset(@field(values, field_name))) |handle|
                            try table.builder.checkOffset(
                                handle,
                                table.table_end,
                            );
                    },
                    .union_vector => {
                        if ((offsets[FieldType.wire_id] == null) !=
                            (offsets[FieldType.field_ids.tag] == null))
                            return errors.BuildError.InvalidUnion;
                    },
                    else => {},
                }
                if (FieldType.required) {
                    const present = switch (FieldType.kind) {
                        .structure => @field(values, field_name) != null,
                        .union_value => |UnionType| UnionType.tag(
                            @field(values, field_name),
                        ) != .none,
                        else => offsets[FieldType.wire_id] != null,
                    };
                    if (!present)
                        return errors.BuildError.MissingRequiredField;
                }
            }
            inline for (field_names) |field_name| {
                const FieldType = @field(descriptors, field_name);
                switch (FieldType.kind) {
                    .scalar => |ValueType| try table.addScalar(
                        ValueType,
                        FieldType.wire_id,
                        @field(values, field_name),
                        FieldType.default,
                    ),
                    .string, .vector, .table => try table.addOffset(
                        FieldType.wire_id,
                        offsets[FieldType.wire_id],
                    ),
                    .structure => |Layout| try table.addStruct(
                        Layout,
                        FieldType.wire_id,
                        @field(values, field_name),
                    ),
                    .union_value => |UnionType| try table.addUnion(
                        UnionType,
                        FieldType.field_ids,
                        @field(values, field_name),
                    ),
                    .union_vector => try table.addUnionVector(
                        FieldType.field_ids,
                        if (offsets[FieldType.wire_id]) |handle|
                            .{
                                .tag = offsets[FieldType.field_ids.tag].?,
                                .value = handle,
                            }
                        else
                            null,
                    ),
                }
            }
        }

        /// Required-slot checks precede finalization writes. A missing untouched
        /// slot leaves the context active so incremental callers can supply it
        /// and retry. Explicit omissions also fail; raw Context.endTable bypasses
        /// schema enforcement, as does the standalone TableBuilder API.
        pub fn endTable(table: *Context) errors.BuildError!Builder.Offset {
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
        ) errors.VerifyError!void {
            const physical_count = comptime blk_count: {
                var count: usize = 0;
                for (field_names) |field_name|
                    count += wireIds(@field(descriptors, field_name)).len;
                break :blk_count count;
            };
            try verifier.charge(physical_count);
            inline for (field_names) |field_name| {
                try verifier.verifyField(
                    @field(descriptors, field_name),
                    table,
                );
            }
        }
    };
}
