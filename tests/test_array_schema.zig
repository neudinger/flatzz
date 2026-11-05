//! Handwritten adapter for arrays.fbs, independent of native struct ordering.
const runtime = @import("runtime");
const structs = @import("test_struct_schema.zig");

pub const Matrix = struct {
    envelopes: [2]structs.Envelope,
    values: [3]f64,
    states: [2]structs.State,
    flags: [3]bool,

    // Five scalar bytes, three padding bytes, doubles, then padded structs.
    pub const Layout = runtime.StructLayout(@This(), .{
        .size = 112,
        .alignment = 8,
    }, .{
        .flags = runtime.ArrayMember(.{ .scalar = bool }, 3, 0),
        .states = runtime.ArrayMember(.{ .scalar = structs.State }, 2, 3),
        .values = runtime.ArrayMember(.{ .scalar = f64 }, 3, 8),
        .envelopes = runtime.ArrayMember(
            .{ .structure = structs.Envelope.Layout },
            2,
            32,
        ),
    });
};

pub const Packet = struct {
    entries: ?[]const structs.Envelope = null,
    matrix: ?Matrix = null,
    empty: ?[]const structs.Sample = null,
    blocks: ?[]const Matrix = null,

    pub const Schema = runtime.Schema(@This(), .{
        .entries = runtime.ReferenceField(
            0,
            .{ .vector = runtime.StructCodec(structs.Envelope.Layout) },
            .{ .required = true },
        ),
        .matrix = runtime.StructField(Matrix.Layout, 1, .{ .required = true }),
        .empty = runtime.ReferenceField(
            2,
            .{ .vector = runtime.StructCodec(structs.Sample.Layout) },
            .{},
        ),
        .blocks = runtime.ReferenceField(
            3,
            .{ .vector = runtime.StructCodec(Matrix.Layout) },
            .{},
        ),
    });
};

pub const envelopes = [_]structs.Envelope{
    structs.envelope,
    .{
        .leading = 9,
        .sample = structs.sample,
        .measure = 2.5,
        .trailing = 7,
    },
};
pub const matrix: Matrix = .{
    .flags = .{ true, false, true },
    .states = .{ @fromBackingInt(@as(u8, 200)), .ready },
    .values = .{ 1.5, -2.5, 3.75 },
    .envelopes = envelopes,
};
pub const storage_capacity = 768;

pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const root = try Packet.Schema.create(&builder, .{
        .entries = &envelopes,
        .matrix = matrix,
        .empty = &.{},
        .blocks = &.{matrix},
    });
    return builder.finish(root, options);
}
