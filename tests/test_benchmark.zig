//! Bounded microbenchmarks for the current runtime's checked access and mutation.
const standard_library = @import("std");
const runtime = @import("runtime");
const Reading = @import("reading").Reading;

fn elapsed(io: standard_library.Io, start: standard_library.Io.Timestamp) i96 {
    return start.durationTo(
        standard_library.Io.Clock.awake.now(io),
    ).nanoseconds;
}

pub fn main(init: standard_library.process.Init) !void {
    const label: [4096]u8 = @splat('a');
    const samples: [1024]f32 = @splat(1.25);
    const tags: [32][]const u8 = @splat("original");
    const replacements: [tags.len][]const u8 = @splat("modified");
    var storage: Reading.Storage(label.len, samples.len, .{
        .count = tags.len,
        .bytes = tags.len * tags[0].len,
    }, 0) = .{};
    const bytes = try Reading.write(&storage.buffer, .{
        .sequence = 42,
        .value = 1.5,
        .active = true,
        .label = &label,
        .samples = &samples,
        .tags = &tags,
    }, .{});
    const table = try runtime.Table.from(bytes, .root);
    var started = standard_library.Io.Clock.awake.now(init.io);
    for (0..200_000) |_| {
        // The memory clobber prevents hoisting constant payload reads out of loops.
        standard_library.mem.doNotOptimizeAway(bytes.ptr);
        standard_library.mem.doNotOptimizeAway(try table.readField(u32, 0, 0));
        standard_library.mem.doNotOptimizeAway(try table.readField(f32, 1, 0));
        standard_library.mem.doNotOptimizeAway(
            try table.readField(bool, 3, false),
        );
    }
    standard_library.debug.print(
        "field_reads_ns={d}\n",
        .{elapsed(init.io, started)},
    );
    const vector = (try Reading.read(bytes)).samples.?;
    started = standard_library.Io.Clock.awake.now(init.io);
    for (0..256) |_| {
        standard_library.mem.doNotOptimizeAway(bytes.ptr);
        var total: f32 = 0;
        for (0..vector.element_count) |element_index| total += try vector.get(
            element_index,
        );
        standard_library.mem.doNotOptimizeAway(total);
    }
    standard_library.debug.print(
        "scalar_vector_ns={d}\n",
        .{elapsed(init.io, started)},
    );
    started = standard_library.Io.Clock.awake.now(init.io);
    for (0..10_000) |_| {
        standard_library.mem.doNotOptimizeAway(bytes.ptr);
        standard_library.mem.doNotOptimizeAway((try table.readString(2)).?);
    }
    standard_library.debug.print(
        "large_string_ns={d}\n",
        .{elapsed(init.io, started)},
    );
    started = standard_library.Io.Clock.awake.now(init.io);
    for (0..128) |_| {
        _ = try Reading.update(bytes, .tags, &replacements);
        standard_library.mem.doNotOptimizeAway(bytes.ptr);
    }
    standard_library.debug.print(
        "string_vector_update_ns={d}\n",
        .{elapsed(init.io, started)},
    );
}
