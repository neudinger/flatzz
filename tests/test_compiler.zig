//! Native FBS parsing and reflection metadata tests.
const std = @import("std");
const compiler = @import("flatzz_compiler");

test {
    std.testing.refAllDecls(compiler);
}

test "native FBS parsing returns the exported reflection model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema: compiler.reflection.Schema = try compiler.parser.parse(
        arena.allocator(),
        "table Reading { value:uint = 42; } root_type Reading;",
    );
    try std.testing.expectEqualStrings("Reading", schema.root_table.?.name);
    try std.testing.expectEqual(@as(i64, 42), schema.root_table.?.fields[0].default_integer);
}
