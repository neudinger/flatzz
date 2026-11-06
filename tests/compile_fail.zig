//! Negative runtime API contracts. Each source is compiled separately by build.zig.
//! Keep diagnostics beside their sources so test names and expectations stay aligned.

pub const Case = struct {
    name: []const u8,
    source: []const u8,
    expected_error: []const u8,
};

pub const cases = [_]Case{
    .{
        .name = "read_only",
        .source =
        \\const runtime = @import("runtime");
        \\test "read-only views reject mutation" {
        \\    const table: runtime.Table = undefined;
        \\    _ = try table.mutateField(u32, 0, 1);
        \\}
        \\
        ,
        .expected_error = "mutation requires a MutableTable",
    },
    .{
        .name = "immutable_input",
        .source =
        \\const runtime = @import("runtime");
        \\test "mutable constructors require writable bytes" {
        \\    const bytes: []const u8 = &.{};
        \\    _ = try runtime.MutableTable.from(bytes, .root);
        \\}
        \\
        ,
        .expected_error = "expected type '[]u8', found '[]const u8'",
    },
    .{
        .name = "unsupported_scalar",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    _ = runtime.Vector(runtime.ScalarCodec(u128));
        \\}
        \\
        ,
        .expected_error = "unsupported FlatBuffers scalar type",
    },
    .{
        .name = "duplicate_ids",
        .source =
        \\const runtime = @import("runtime");
        \\const Values = struct { first: u32, second: u32 };
        \\comptime {
        \\    _ = runtime.Schema(Values, .{
        \\        .first = runtime.ScalarField(u32, 0, 0),
        \\        .second = runtime.ScalarField(u32, 0, 0),
        \\    }).View;
        \\}
        \\
        ,
        .expected_error = "duplicate schema wire field ID",
    },
    .{
        .name = "inconsistent_type",
        .source =
        \\const runtime = @import("runtime");
        \\const Values = struct { number: u32 };
        \\comptime {
        \\    _ = runtime.Schema(Values, .{
        \\        .number = runtime.ScalarField(u64, 0, 0),
        \\    }).View;
        \\}
        \\
        ,
        .expected_error = "schema descriptor value type mismatch",
    },
    .{
        .name = "optional_default",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    _ = runtime.ScalarField(?u32, 0, 1);
        \\}
        \\
        ,
        .expected_error = "optional scalars must default to null",
    },
    .{
        .name = "optional_default_builder",
        .source =
        \\const runtime = @import("runtime");
        \\test "table builders reject non-null optional defaults" {
        \\    var table: runtime.TableBuilder(1) = undefined;
        \\    try table.addScalar(?u32, 0, 1, 1);
        \\}
        \\
        ,
        .expected_error = "optional scalars must default to null",
    },
    .{
        .name = "optional_default_read",
        .source =
        \\const runtime = @import("runtime");
        \\test "table views reject non-null optional defaults" {
        \\    const table: runtime.Table = undefined;
        \\    _ = try table.readField(?u32, 0, 1);
        \\}
        \\
        ,
        .expected_error = "optional scalars must default to null",
    },
    .{
        .name = "invalid_codec",
        .source =
        \\const runtime = @import("runtime");
        \\const Codec = struct {
        \\    pub const Value = u32;
        \\    pub const slot_size = 4;
        \\    pub const slot_alignment = 3;
        \\};
        \\comptime {
        \\    _ = runtime.Vector(Codec);
        \\}
        \\
        ,
        .expected_error = "invalid sequence element layout",
    },
    .{
        .name = "struct_offset",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "overlapping struct members are rejected" {
        \\    const Native = struct { first: u32, second: u32 };
        \\    const Layout = runtime.StructLayout(Native, .{
        \\        .size = 8,
        \\        .alignment = 4,
        \\    }, .{
        \\        .first = runtime.ScalarMember(u32, 0),
        \\        .second = runtime.ScalarMember(u32, 0),
        \\    });
        \\    _ = Layout.wire_size;
        \\}
        \\
        ,
        .expected_error = "invalid FlatBuffers struct member offset",
    },
    .{
        .name = "struct_layout",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "struct size cannot substitute for alignment" {
        \\    const Native = struct { first: u32, second: u32, third: u32 };
        \\    const Layout = runtime.StructLayout(Native, .{
        \\        .size = 12,
        \\        .alignment = 12,
        \\    }, .{
        \\        .first = runtime.ScalarMember(u32, 0),
        \\        .second = runtime.ScalarMember(u32, 4),
        \\        .third = runtime.ScalarMember(u32, 8),
        \\    });
        \\    _ = Layout.wire_size;
        \\}
        \\
        ,
        .expected_error = "invalid FlatBuffers struct size or alignment",
    },
    .{
        .name = "struct_type",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "struct native and wire member types must agree" {
        \\    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        \\        .size = 8,
        \\        .alignment = 8,
        \\    }, .{ .number = runtime.ScalarMember(u64, 0) });
        \\    _ = Layout.wire_size;
        \\}
        \\
        ,
        .expected_error = "struct descriptor value type mismatch",
    },
    .{
        .name = "struct_optional",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "struct members cannot be optional scalars" {
        \\    const Layout = runtime.StructLayout(struct { number: ?u32 }, .{
        \\        .size = 4,
        \\        .alignment = 4,
        \\    }, .{ .number = runtime.ScalarMember(?u32, 0) });
        \\    _ = Layout.wire_size;
        \\}
        \\
        ,
        .expected_error = "unsupported FlatBuffers scalar type",
    },
    .{
        .name = "struct_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "nested struct views preserve read-only access" {
        \\    const Child = struct {
        \\        number: u32,
        \\        pub const Layout = runtime.StructLayout(@This(), .{
        \\            .size = 4,
        \\            .alignment = 4,
        \\        }, .{ .number = runtime.ScalarMember(u32, 0) });
        \\    };
        \\    const Parent = runtime.StructLayout(struct { child: Child }, .{
        \\        .size = 4,
        \\        .alignment = 4,
        \\    }, .{ .child = runtime.StructMember(Child.Layout, 0) });
        \\    const view: runtime.StructView(Parent, .read_only) = undefined;
        \\    const child = try view.get(.child);
        \\    try child.update(.number, 42);
        \\}
        \\
        ,
        .expected_error = "mutation requires a mutable struct",
    },
    .{
        .name = "array_length",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "zero array length is not an FBS type" {
        \\    _ = runtime.ArrayMember(.{ .scalar = u8 }, 0, 0);
        \\}
        \\
        ,
        .expected_error = "array length must be positive and fit in u16",
    },
    .{
        .name = "array_overflow",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "array lengths must fit schema metadata" {
        \\    _ = runtime.ArrayMember(.{ .scalar = u8 }, 65536, 0);
        \\}
        \\
        ,
        .expected_error = "array length must be positive and fit in u16",
    },
    .{
        .name = "array_type",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "native array lengths must match the schema" {
        \\    const Layout = runtime.StructLayout(struct { values: [3]u32 }, .{
        \\        .size = 8,
        \\        .alignment = 4,
        \\    }, .{ .values = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0) });
        \\    _ = Layout.wire_size;
        \\}
        \\
        ,
        .expected_error = "struct descriptor value type mismatch",
    },
    .{
        .name = "array_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "borrowed array preserves read-only access" {
        \\    const Layout = runtime.StructLayout(struct { values: [2]u32 }, .{
        \\        .size = 8,
        \\        .alignment = 4,
        \\    }, .{ .values = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0) });
        \\    const view: runtime.StructView(Layout, .read_only) = undefined;
        \\    const values = try view.get(.values);
        \\    try values.update(0, 42);
        \\}
        \\
        ,
        .expected_error = "mutation requires a mutable array",
    },
    .{
        .name = "struct_vector_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "borrowed struct vector preserves read-only access" {
        \\    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        \\        .size = 4,
        \\        .alignment = 4,
        \\    }, .{ .number = runtime.ScalarMember(u32, 0) });
        \\    const vector: runtime.Vector(runtime.StructCodec(Layout)) = undefined;
        \\    const value = try vector.get(0);
        \\    try value.update(.number, 42);
        \\}
        \\
        ,
        .expected_error = "mutation requires a mutable struct",
    },
    .{
        .name = "array_vector",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "raw fixed arrays are not vector elements" {
        \\    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
        \\    _ = runtime.StructCodec(Member.kind.array);
        \\}
        \\
        ,
        .expected_error = "struct vectors require a struct layout",
    },
    .{
        .name = "array_nested",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "direct nested arrays are not an FBS type" {
        \\    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
        \\    _ = runtime.ArrayMember(Member.kind, 2, 0);
        \\}
        \\
        ,
        .expected_error = "direct nested arrays are unsupported",
    },
    .{
        .name = "array_table",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\test "raw fixed arrays cannot be table fields" {
        \\    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
        \\    _ = runtime.StructField(Member.kind.array, 0, .{});
        \\}
        \\
        ,
        .expected_error = "table struct fields require a struct layout",
    },
    .{
        .name = "union_duplicate_ids",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\const Payload = runtime.Union(enum(u8) { none, text }, .{
        \\    .none = .none,
        \\    .text = .string,
        \\});
        \\
        \\const Packet = struct {
        \\    payload: Payload.Value,
        \\    marker: u8,
        \\    const Schema = runtime.Schema(@This(), .{
        \\        .payload = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
        \\        .marker = runtime.ScalarField(u8, 0, 0),
        \\    });
        \\};
        \\test "synthetic discriminator IDs cannot overlap another field" {
        \\    _ = Packet.Schema.field_count;
        \\}
        \\
        ,
        .expected_error = "duplicate schema wire field ID",
    },
    .{
        .name = "union_adjacent_ids",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\const Payload = runtime.Union(enum(u8) { none, text }, .{
        \\    .none = .none,
        \\    .text = .string,
        \\});
        \\
        \\test "union physical IDs must be adjacent" {
        \\    _ = runtime.UnionField(Payload, .{ .tag = 0, .value = 2 }, .{});
        \\}
        \\
        ,
        .expected_error = "union value ID must immediately follow tag ID",
    },
    .{
        .name = "union_tag_width",
        .source =
        \\const runtime = @import("runtime");
        \\test "union tags have the fixed wire width" {
        \\    _ = runtime.Union(enum(u16) { none, text }, .{
        \\        .none = .none,
        \\        .text = .string,
        \\    });
        \\}
        \\
        ,
        .expected_error = "union tags require an exhaustive u8 enum",
    },
    .{
        .name = "union_none_tag",
        .source =
        \\const runtime = @import("runtime");
        \\test "union NONE must be tag zero" {
        \\    _ = runtime.Union(enum(u8) { none = 2, text = 3 }, .{
        \\        .none = .none,
        \\        .text = .string,
        \\    });
        \\}
        \\
        ,
        .expected_error = "union tags require none = 0",
    },
    .{
        .name = "union_none_payload",
        .source =
        \\const runtime = @import("runtime");
        \\test "only NONE lacks a payload" {
        \\    _ = runtime.Union(enum(u8) { none, text }, .{
        \\        .none = .none,
        \\        .text = .none,
        \\    });
        \\}
        \\
        ,
        .expected_error = "only the none tag may omit a payload",
    },
    .{
        .name = "union_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\test "union table borrowing preserves read-only capability" {
        \\    const Child = struct {};
        \\    const Payload = runtime.Union(enum(u8) { none, child }, .{
        \\        .none = .none,
        \\        .child = .{ .table = Child },
        \\    });
        \\    const table: runtime.Table = undefined;
        \\    const value = try table.readUnion(Payload, .{ .tag = 0, .value = 1 });
        \\    _ = try value.child.mutateField(u32, 0, 42);
        \\}
        \\
        ,
        .expected_error = "mutation requires a MutableTable",
    },
    .{
        .name = "union_vector_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\test "union vector struct borrowing preserves read-only capability" {
        \\    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        \\        .size = 4,
        \\        .alignment = 4,
        \\    }, .{ .number = runtime.ScalarMember(u32, 0) });
        \\    const Payload = runtime.Union(enum(u8) { none, child }, .{
        \\        .none = .none,
        \\        .child = .{ .structure = Layout },
        \\    });
        \\    const vector: runtime.UnionVectorView(Payload, .read_only) = undefined;
        \\    const value = try vector.get(0);
        \\    try value.child.update(.number, 42);
        \\}
        \\
        ,
        .expected_error = "mutation requires a mutable struct",
    },
    .{
        .name = "union_replacement",
        .source =
        \\const runtime = @import("runtime");
        \\
        \\const Payload = runtime.Union(enum(u8) { none, text }, .{
        \\    .none = .none,
        \\    .text = .string,
        \\});
        \\
        \\const Packet = struct {
        \\    payload: Payload.Value,
        \\    const Schema = runtime.Schema(@This(), .{
        \\        .payload = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
        \\    });
        \\};
        \\test "union replacement is not a size-preserving field update" {
        \\    const table: runtime.MutableTable = undefined;
        \\    _ = try Packet.Schema.update(table, .payload, .none);
        \\}
        \\
        ,
        .expected_error = "union replacement requires rebuilding; mutate borrowed payload fields",
    },
    .{
        .name = "storage_unknown",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    const Definition = runtime.Schema(struct {}, .{});
        \\    _ = @sizeOf(runtime.Storage(Definition, .{ .missing = 1 }, .{}));
        \\}
        \\
        ,
        .expected_error = "unknown storage capacity field: missing",
    },
    .{
        .name = "storage_fixed",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    const Definition = runtime.Schema(struct { value: u32 }, .{
        \\        .value = runtime.ScalarField(u32, 0, 0),
        \\    });
        \\    _ = @sizeOf(runtime.Storage(Definition, .{ .value = 1 }, .{}));
        \\}
        \\
        ,
        .expected_error = "fixed-size fields do not accept storage capacities: value",
    },
    .{
        .name = "storage_overflow",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    const Definition = runtime.Schema(struct { values: ?[]const u64 }, .{
        \\        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u64) }, .{}),
        \\    });
        \\    _ = @sizeOf(runtime.Storage(Definition, .{ .values = runtime.Builder.max_buffer_size }, .{}));
        \\}
        \\
        ,
        .expected_error = "storage capacity exceeds Builder.max_buffer_size",
    },
    .{
        .name = "storage_count",
        .source =
        \\const runtime = @import("runtime");
        \\comptime {
        \\    const Definition = runtime.Schema(struct { values: ?[]const u8 }, .{
        \\        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u8) }, .{}),
        \\    });
        \\    _ = @sizeOf(runtime.Storage(Definition, .{ .values = 0x1_0000_0000 }, .{}));
        \\}
        \\
        ,
        .expected_error = "storage element count must fit in u32",
    },
    .{
        .name = "borrow_scalar",
        .source =
        \\const runtime = @import("runtime");
        \\test "scalar fields have no mutable borrowed view" {
        \\    const Definition = runtime.Schema(struct { value: u32 }, .{
        \\        .value = runtime.ScalarField(u32, 0, 0),
        \\    });
        \\    const table: runtime.MutableTable = undefined;
        \\    _ = try Definition.borrowMutable(table, .value);
        \\}
        \\
        ,
        .expected_error = "borrowMutable requires a structured field; use update for scalars and strings",
    },
    .{
        .name = "borrow_string",
        .source =
        \\const runtime = @import("runtime");
        \\test "strings retain checked replacement semantics" {
        \\    const Definition = runtime.Schema(struct { value: ?[]const u8 }, .{
        \\        .value = runtime.ReferenceField(0, .string, .{}),
        \\    });
        \\    const table: runtime.MutableTable = undefined;
        \\    _ = try Definition.borrowMutable(table, .value);
        \\}
        \\
        ,
        .expected_error = "borrowMutable requires a structured field; use update for scalars and strings",
    },
    .{
        .name = "borrow_read_only",
        .source =
        \\const runtime = @import("runtime");
        \\test "mutable borrowing requires a mutable table" {
        \\    const Definition = runtime.Schema(struct { values: ?[]const u32 }, .{
        \\        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u32) }, .{}),
        \\    });
        \\    const table: runtime.Table = undefined;
        \\    _ = try Definition.borrowMutable(table, .values);
        \\}
        \\
        ,
        .expected_error = "expected type 'runtime.table_view.TableView(.mutable)', found 'runtime.table_view.TableView(.read_only)'",
    },
};
