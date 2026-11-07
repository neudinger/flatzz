//! A larger schema regression for compile-time metadata and specialization.
const std = @import("std");
const runtime = @import("runtime");

const fields = .{
    .value_000 = runtime.ScalarField(u32, 0, 0),
    .value_001 = runtime.ScalarField(u32, 1, 0),
    .value_002 = runtime.ScalarField(u32, 2, 0),
    .value_003 = runtime.ScalarField(u32, 3, 0),
    .value_004 = runtime.ScalarField(u32, 4, 0),
    .value_005 = runtime.ScalarField(u32, 5, 0),
    .value_006 = runtime.ScalarField(u32, 6, 0),
    .value_007 = runtime.ScalarField(u32, 7, 0),
    .value_008 = runtime.ScalarField(u32, 8, 0),
    .value_009 = runtime.ScalarField(u32, 9, 0),
    .value_010 = runtime.ScalarField(u32, 10, 0),
    .value_011 = runtime.ScalarField(u32, 11, 0),
    .value_012 = runtime.ScalarField(u32, 12, 0),
    .value_013 = runtime.ScalarField(u32, 13, 0),
    .value_014 = runtime.ScalarField(u32, 14, 0),
    .value_015 = runtime.ScalarField(u32, 15, 0),
    .value_016 = runtime.ScalarField(u32, 16, 0),
    .value_017 = runtime.ScalarField(u32, 17, 0),
    .value_018 = runtime.ScalarField(u32, 18, 0),
    .value_019 = runtime.ScalarField(u32, 19, 0),
    .value_020 = runtime.ScalarField(u32, 20, 0),
    .value_021 = runtime.ScalarField(u32, 21, 0),
    .value_022 = runtime.ScalarField(u32, 22, 0),
    .value_023 = runtime.ScalarField(u32, 23, 0),
    .value_024 = runtime.ScalarField(u32, 24, 0),
    .value_025 = runtime.ScalarField(u32, 25, 0),
    .value_026 = runtime.ScalarField(u32, 26, 0),
    .value_027 = runtime.ScalarField(u32, 27, 0),
    .value_028 = runtime.ScalarField(u32, 28, 0),
    .value_029 = runtime.ScalarField(u32, 29, 0),
    .value_030 = runtime.ScalarField(u32, 30, 0),
    .value_031 = runtime.ScalarField(u32, 31, 0),
    .value_032 = runtime.ScalarField(u32, 32, 0),
    .value_033 = runtime.ScalarField(u32, 33, 0),
    .value_034 = runtime.ScalarField(u32, 34, 0),
    .value_035 = runtime.ScalarField(u32, 35, 0),
    .value_036 = runtime.ScalarField(u32, 36, 0),
    .value_037 = runtime.ScalarField(u32, 37, 0),
    .value_038 = runtime.ScalarField(u32, 38, 0),
    .value_039 = runtime.ScalarField(u32, 39, 0),
    .value_040 = runtime.ScalarField(u32, 40, 0),
    .value_041 = runtime.ScalarField(u32, 41, 0),
    .value_042 = runtime.ScalarField(u32, 42, 0),
    .value_043 = runtime.ScalarField(u32, 43, 0),
    .value_044 = runtime.ScalarField(u32, 44, 0),
    .value_045 = runtime.ScalarField(u32, 45, 0),
    .value_046 = runtime.ScalarField(u32, 46, 0),
    .value_047 = runtime.ScalarField(u32, 47, 0),
    .value_048 = runtime.ScalarField(u32, 48, 0),
    .value_049 = runtime.ScalarField(u32, 49, 0),
    .value_050 = runtime.ScalarField(u32, 50, 0),
    .value_051 = runtime.ScalarField(u32, 51, 0),
    .value_052 = runtime.ScalarField(u32, 52, 0),
    .value_053 = runtime.ScalarField(u32, 53, 0),
    .value_054 = runtime.ScalarField(u32, 54, 0),
    .value_055 = runtime.ScalarField(u32, 55, 0),
    .value_056 = runtime.ScalarField(u32, 56, 0),
    .value_057 = runtime.ScalarField(u32, 57, 0),
    .value_058 = runtime.ScalarField(u32, 58, 0),
    .value_059 = runtime.ScalarField(u32, 59, 0),
    .value_060 = runtime.ScalarField(u32, 60, 0),
    .value_061 = runtime.ScalarField(u32, 61, 0),
    .value_062 = runtime.ScalarField(u32, 62, 0),
    .value_063 = runtime.ScalarField(u32, 63, 0),
};
const field_names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
const Values = @Struct(.auto, null, field_names, &@splat(u32), &@splat(.{}));
const Definition = struct {
    pub const Schema = runtime.Schema(Values, fields);
};

test "64 field metadata builds reads updates and verifies within comptime limits" {
    var values: Values = undefined;
    inline for (field_names, 0..) |field_name, field_index| {
        @field(values, field_name) = @intCast(field_index + 1);
    }
    const storage_capacity = 1024;
    var storage: [storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try Definition.Schema.create(
        &builder,
        values,
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(Definition, bytes, .{});
    const decoded = try Definition.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    inline for (field_names) |field_name| {
        try std.testing.expectEqual(
            @field(values, field_name),
            @field(
                decoded,
                field_name,
            ),
        );
    }
    try std.testing.expect(
        try Definition.Schema.update(
            try runtime.MutableTable.from(bytes, .root),
            .value_063,
            99,
        ),
    );
    try runtime.Verifier.verify(Definition, bytes, .{});
    try std.testing.expectEqual(
        @as(u32, 99),
        (try Definition.Schema.read(
            try runtime.Table.from(bytes, .root),
        )).value_063,
    );
}
