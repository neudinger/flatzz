//! Handwritten generated-style adapters for a recursive graph schema.
//! Native order deliberately differs from wire IDs; recursive references stay
//! named types. This is a second schema, independent of Reading.
const runtime = @import("runtime");

pub const Node = struct {
    name: ?[]const u8 = null,
    next: ?*const Node = null,
    number: u64 = 0,

    pub const fields = .{
        .number = runtime.ScalarField(u64, 0, 0),
        .name = runtime.ReferenceField(1, .string, .{ .required = true }),
        .next = runtime.ReferenceField(2, .{ .table = Node }, .{}),
    };
    pub const Schema = runtime.Schema(@This(), fields);
};

pub const Graph = struct {
    payload: ?[]const u8 = null,
    children: ?[]const *const Node = null,
    child: ?*const Node = null,
    revision: u16 = 0,

    pub const fields = .{
        .revision = runtime.ScalarField(u16, 0, 0),
        .child = runtime.ReferenceField(
            1,
            .{ .table = Node },
            .{ .required = true },
        ),
        .children = runtime.ReferenceField(
            2,
            .{ .vector = runtime.TableCodec(Node) },
            .{},
        ),
        .payload = runtime.ReferenceField(
            3,
            .{ .vector = runtime.ScalarCodec(u8) },
            .{},
        ),
    };
    pub const Schema = runtime.Schema(@This(), fields);
};

pub const leaf_number: u64 = 0x0102030405060708;
pub const parent_number: u64 = 99;
pub const revision: u16 = 0x0201;
pub const payload = [_]u8{ 0, 0xff, 0x80, 7 };
pub const storage_capacity = 256;

pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime finish_options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const leaf_name = try builder.createString("leaf");
    var leaf = try Node.Schema.Context.init(&builder);
    try Node.Schema.addFields(
        &leaf,
        .{ .number = leaf_number },
        .{ null, leaf_name, null },
    );
    const leaf_handle = try Node.Schema.endTable(&leaf);
    const children = try builder.createOffsetVector(
        &.{ leaf_handle, leaf_handle },
    );
    const parent_name = try builder.createString("parent");
    var parent = try Node.Schema.Context.init(&builder);
    try Node.Schema.addFields(
        &parent,
        .{ .number = parent_number },
        .{ null, parent_name, leaf_handle },
    );
    const parent_handle = try Node.Schema.endTable(&parent);
    const payload_handle = try builder.createVector(u8, &payload);
    var graph = try Graph.Schema.Context.init(&builder);
    try Graph.Schema.addFields(
        &graph,
        .{ .revision = revision },
        .{ null, parent_handle, children, payload_handle },
    );
    return builder.finish(try Graph.Schema.endTable(&graph), finish_options);
}
