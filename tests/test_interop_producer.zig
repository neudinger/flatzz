//! Run from the interoperability scratch directory; does not belong to runtime.
const standard_library = @import("std");
const Reading = @import("reading").Reading;
const runtime = @import("runtime");
const fixtures = @import("test_schema.zig");
const structs = @import("test_struct_schema.zig");
const arrays = @import("test_array_schema.zig");
const unions = @import("test_union_schema.zig");

pub fn main(init: standard_library.process.Init) !void {
    var reading_storage: Reading.Storage(
        6,
        3,
        .{
            .count = 4,
            .bytes = 8,
        },
        0,
    ) = .{};
    const reading = try Reading.write(&reading_storage.buffer, .{
        .sequence = 42,
        .value = 1.5,
        .label = "sensor",
        .active = true,
        .status = @fromBackingInt(@intCast(200)),
        .samples = &.{ -1.5, 0, 2.5 },
        .temperature = 0,
        .tags = &.{ "one", "", "é", "one" },
        .location = .{
            .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
            .altitude = 35,
        },
    }, .{});
    try Reading.verify(reading, .{});
    try standard_library.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "zig-reading.bin",
        .data = reading,
    });
    var struct_storage: [structs.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const struct_bytes = try structs.build(&struct_storage, .ordinary);
    try runtime.Verifier.verify(structs.Packet, struct_bytes, .{});
    try standard_library.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "zig-structs.bin",
        .data = struct_bytes,
    });
    var array_storage: [arrays.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const array_bytes = try arrays.build(&array_storage, .ordinary);
    try runtime.Verifier.verify(arrays.Packet, array_bytes, .{});
    try standard_library.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "zig-arrays.bin",
        .data = array_bytes,
    });
    var graph_storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    var union_storage: [unions.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const union_bytes = try unions.build(&union_storage, .ordinary);
    try runtime.Verifier.verify(unions.Packet, union_bytes, .{});
    try standard_library.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "zig-unions.bin",
        .data = union_bytes,
    });
    inline for (.{
        .{
            "graph",
            runtime.Builder.FinishOptions.ordinary,
            runtime.framing.Options{},
        },
        .{
            "graph-prefixed",
            runtime.Builder.FinishOptions.size_prefixed,
            runtime.framing.Options{ .format = .size_prefixed },
        },
        .{
            "graph-prefixed-id",
            runtime.Builder.FinishOptions{
                .size_prefixed_identifier = "GRPH".*,
            },
            runtime.framing.Options{
                .format = .size_prefixed,
                .identifier = "GRPH".*,
            },
        },
    }) |example| {
        const graph = try fixtures.build(&graph_storage, example[1]);
        try runtime.Verifier.verify(
            fixtures.Graph,
            graph,
            .{ .frame = example[2] },
        );
        try standard_library.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = "zig-" ++ example[0] ++ ".bin",
            .data = graph,
        });
    }
}
