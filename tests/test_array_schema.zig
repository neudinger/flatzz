//! Handwritten array adapter, independent of native struct ordering.
const runtime = @import("runtime");
const structs = @import("test_struct_schema.zig");

/// Fixed arrays combine scalar, enum, boolean, and nested struct encodings.
pub const Matrix = struct {
    /// Two inline structs with their own internal and tail padding.
    envelopes: [2]structs.Envelope,
    /// Three double-precision wire scalars.
    values: [3]f64,
    /// Open enum array preserving unknown raw values.
    states: [2]structs.State,
    /// Three individually validated boolean bytes.
    flags: [3]bool,

    // Five scalar bytes, three padding bytes, doubles, then padded structs.
    /// Fixed 112-byte wire layout with explicit member offsets.
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

/// Root table covering required struct vectors and inline arrays.
pub const Packet = struct {
    /// Required contiguous vector of Envelope structs.
    entries: ?[]const structs.Envelope = null,
    /// Required inline Matrix; omission is rejected.
    matrix: ?Matrix = null,
    /// Optional vector used to distinguish an empty payload from absence.
    empty: ?[]const structs.Sample = null,
    /// Optional vector of array-containing structs.
    blocks: ?[]const Matrix = null,

    /// Table descriptors preserving required-field and vector element semantics.
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

/// Two distinct parent struct fixtures in vector order.
pub const envelopes = [_]structs.Envelope{
    structs.envelope,
    .{
        .leading = 9,
        .sample = structs.sample,
        .measure = 2.5,
        .trailing = 7,
    },
};
/// Matrix fixture containing unknown enum bits and mixed scalar values.
pub const matrix: Matrix = .{
    .flags = .{ true, false, true },
    .states = .{ @fromBackingInt(@as(u8, 200)), .ready },
    .values = .{ 1.5, -2.5, 3.75 },
    .envelopes = envelopes,
};
/// Builder capacity in bytes for this fixed array fixture.
pub const storage_capacity = 768;

/// Build the array fixture in caller-owned aligned storage using the selected framing.
/// The result borrows storage; construction errors propagate and may leave partial bytes.
pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const root = try Packet.Schema.create(
        &builder,
        .{
            .entries = &envelopes,
            .matrix = matrix,
            .empty = &.{},
            .blocks = &.{matrix},
        },
        .{},
    );
    return builder.finish(root, options);
}
