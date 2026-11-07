//! Handwritten generated-style adapters for a recursive graph schema.
//! Native order deliberately differs from wire IDs; recursive references stay
//! named types. This is a second schema, independent of Reading.
const runtime = @import("runtime");

/// A recursive child table with a required name and optional next link.
pub const Node = struct {
    /// Required string; null is rejected by schema construction and verification.
    name: ?[]const u8 = null,
    /// Optional native recursive link; wire fixtures use explicit child handles.
    next: ?*const Node = null,
    /// Scalar payload used to check shared child mutations.
    number: u64 = 0,

    /// Physical IDs intentionally differ from the native field order.
    pub const fields = .{
        .number = runtime.ScalarField(u64, 0, 0),
        .name = runtime.ReferenceField(1, .string, .{ .required = true }),
        .next = runtime.ReferenceField(2, .{ .table = Node }, .{}),
    };
    /// Runtime adapters derived from this table's explicit field IDs.
    pub const Schema = runtime.Schema(@This(), fields);
};

/// Root table combining a required child, shared child vector, and raw bytes.
pub const Graph = struct {
    /// Optional byte vector; arbitrary non-UTF-8 bytes are valid.
    payload: ?[]const u8 = null,
    /// Optional child vector that can reference the same node more than once.
    children: ?[]const *const Node = null,
    /// Required child reference, supplied through an explicit builder handle.
    child: ?*const Node = null,
    /// Root scalar used to verify schema defaults and fixed-size mutation.
    revision: u16 = 0,

    /// Physical IDs intentionally differ from the native field order.
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
    /// Runtime adapters derived from this table's explicit field IDs.
    pub const Schema = runtime.Schema(@This(), fields);
};

/// Independent wide scalar fixture for the shared leaf.
pub const leaf_number: u64 = 0x0102030405060708;
/// Initial scalar payload of the parent node.
pub const parent_number: u64 = 99;
/// Root revision with distinct little-endian bytes.
pub const revision: u16 = 0x0201;
/// Binary vector fixture, deliberately including invalid UTF-8.
pub const payload = [_]u8{ 0, 0xff, 0x80, 7 };
/// Aligned builder capacity in bytes, sufficient for this fixed graph.
pub const storage_capacity = 256;

/// Build a recursive graph sharing one leaf across a link and vector entries.
/// The result borrows caller storage; construction errors may leave partial bytes.
pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime finish_options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const leaf_name = try builder.createString("leaf");
    var leaf = try Node.Schema.Context.init(&builder);
    try Node.Schema.addFields(&leaf, .{ .number = leaf_number, .name = leaf_name });
    const leaf_handle = try Node.Schema.endTable(&leaf);
    const children = try builder.createReferenceVector(&.{ leaf_handle, leaf_handle }, .{});
    const parent_name = try builder.createString("parent");
    var parent = try Node.Schema.Context.init(&builder);
    try Node.Schema.addFields(&parent, .{
        .number = parent_number,
        .name = parent_name,
        .next = leaf_handle,
    });
    const parent_handle = try Node.Schema.endTable(&parent);
    const payload_handle = try builder.createVector(u8, &payload);
    var graph = try Graph.Schema.Context.init(&builder);
    try Graph.Schema.addFields(&graph, .{
        .revision = revision,
        .child = parent_handle,
        .children = children,
        .payload = payload_handle,
    });
    return builder.finish(try Graph.Schema.endTable(&graph), finish_options);
}
