//! Handwritten struct adapter with reordered native fields.
const runtime = @import("runtime");

pub const State = enum(u8) { ready = 1, _ };

pub const Sample = struct {
    number: u64,
    count: u16,
    state: State,
    flag: bool,

    // Four scalar bytes, four padding bytes, then an aligned u64.
    pub const Layout = runtime.StructLayout(@This(), .{
        .size = 16,
        .alignment = 8,
    }, .{
        .flag = runtime.ScalarMember(bool, 0),
        .state = runtime.ScalarMember(State, 1),
        .count = runtime.ScalarMember(u16, 2),
        .number = runtime.ScalarMember(u64, 8),
    });
};

pub const Envelope = struct {
    measure: f64,
    sample: Sample,
    trailing: u16,
    leading: u8,

    // Seven bytes pad leading; six tail bytes round the struct to alignment 8.
    pub const Layout = runtime.StructLayout(@This(), .{
        .size = 40,
        .alignment = 8,
    }, .{
        .leading = runtime.ScalarMember(u8, 0),
        .sample = runtime.StructMember(Sample.Layout, 8),
        .measure = runtime.ScalarMember(f64, 24),
        .trailing = runtime.ScalarMember(u16, 32),
    });
};

pub const Packet = struct {
    extra: ?Sample = null,
    envelope: ?Envelope = null,
    marker: u32 = 0,

    pub const Schema = runtime.Schema(@This(), .{
        .marker = runtime.ScalarField(u32, 0, 0),
        .envelope = runtime.StructField(
            Envelope.Layout,
            1,
            .{ .required = true },
        ),
        .extra = runtime.StructField(Sample.Layout, 2, .{}),
    });
};

pub const sample: Sample = .{
    .flag = true,
    .state = @fromBackingInt(@as(u8, 200)),
    .count = 0x2345,
    .number = 0x0102030405060708,
};
pub const envelope: Envelope = .{
    .leading = 0x7f,
    .sample = sample,
    .measure = -12.5,
    .trailing = 0x1234,
};
pub const marker: u32 = 42;
pub const storage_capacity = 256;

pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const root = try Packet.Schema.create(&builder, .{
        .marker = marker,
        .envelope = envelope,
        .extra = sample,
    });
    return builder.finish(root, options);
}
