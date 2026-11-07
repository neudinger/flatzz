//! Read FBS text directly into `flatzz_compiler.reflection.Schema` at runtime.
//! Run `zig build run` from this directory; no BFBS or JSON conversion is involved.

const std = @import("std");
const compiler = @import("flatzz_compiler");

/// Parse one standalone FBS path and print its root, counts, and sorted fields.
/// Requires a root table and accepts no include loader; the arena owns all metadata.
/// Argument, file, parse, missing-root, and stdout failures propagate.
pub fn main(init: std.process.Init) !void {
    // The arena owns the source, parsed schema, and parser temporaries.
    // Keep it alive until every schema consumer has finished.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 2) return error.ExpectedSchemaPath;

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], allocator, .unlimited);
    const schema: compiler.reflection.Schema = try compiler.parser.parseWithOptions(
        allocator,
        source,
        .{ .filename = arguments[1] },
    );
    const root_table = schema.root_table orelse return error.MissingRootTable;

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    try output.interface.print("Root: {s}\nObjects: {d}\nEnums: {d}\nFields: {d}\n", .{
        root_table.name, schema.objects.len, schema.enums.len, root_table.fields.len,
    });
    // Reflection sorts fields by name; IDs retain their declaration order.
    for (root_table.fields) |field| {
        try output.interface.print("  {s}: {s} (id={d})\n", .{
            field.name, @tagName(field.type.base_type), field.id,
        });
    }
    try output.interface.flush();
}
