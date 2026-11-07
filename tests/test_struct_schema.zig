//! Handwritten struct adapter with reordered native fields.
const runtime = @import("runtime");

/// Open wire enum; unknown u8 values must round-trip unchanged.
pub const State = enum(u8) { ready = 1, _ };

/// Native field order intentionally differs from the padded wire layout.
pub const Sample = struct {
    /// Wide scalar placed at aligned wire offset eight.
    number: u64,
    /// Two-byte scalar placed before the wide scalar on the wire.
    count: u16,
    /// Open enum retaining unknown raw values.
    state: State,
    /// Boolean encoded in the first wire byte.
    flag: bool,

    // Four scalar bytes, four padding bytes, then an aligned u64.
    /// Explicit padded wire layout, independent of native Zig field order.
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

/// Padded parent struct embedding a separately aligned Sample.
pub const Envelope = struct {
    /// Floating payload whose wire bits are verified independently.
    measure: f64,
    /// Nested Sample stored inline at wire offset eight.
    sample: Sample,
    /// Final scalar followed by tail padding.
    trailing: u16,
    /// First wire scalar followed by seven padding bytes.
    leading: u8,

    // Seven bytes pad leading; six tail bytes round the struct to alignment 8.
    /// Explicit padded wire layout, independent of native Zig field order.
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

/// Root table exercising required and optional inline struct fields.
pub const Packet = struct {
    /// Optional inline struct; null differs from a present zero value.
    extra: ?Sample = null,
    /// Required inline struct, rejected when omitted.
    envelope: ?Envelope = null,
    /// Root scalar with a schema default of zero.
    marker: u32 = 0,

    /// Table adapters enforcing the explicit wire IDs and required envelope.
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

/// Sample fixture containing an unknown enum value and distinct scalar bytes.
pub const sample: Sample = .{
    .flag = true,
    .state = @fromBackingInt(@as(u8, 200)),
    .count = 0x2345,
    .number = 0x0102030405060708,
};
/// Parent fixture used with independently specified padding and wire bytes.
pub const envelope: Envelope = .{
    .leading = 0x7f,
    .sample = sample,
    .measure = -12.5,
    .trailing = 0x1234,
};
/// Initial table marker used by access and mutation checks.
pub const marker: u32 = 42;
/// Builder capacity in bytes for this fixed struct/table fixture.
pub const storage_capacity = 256;

/// Build the struct fixture in caller-owned aligned storage using the selected framing.
/// The result borrows storage; construction errors propagate and may leave partial bytes.
pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const root = try Packet.Schema.create(
        &builder,
        .{
            .marker = marker,
            .envelope = envelope,
            .extra = sample,
        },
        .{},
    );
    return builder.finish(root, options);
}
