//! `zig build run` supplies each generated JSON path followed by its BFBS path.
//! Print the installed output paths.

const std = @import("std");

/// Print JSON/BFBS path pairs to stdout.
/// An unmatched path returns ExpectedJsonAndBfbsPaths; allocation and stdout errors propagate.
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if ((arguments.len - 1) % 2 != 0) return error.ExpectedJsonAndBfbsPaths;

    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    var argument_index: usize = 1;
    while (argument_index < arguments.len) : (argument_index += 2) {
        const json_path = arguments[argument_index];
        const binary_path = arguments[argument_index + 1];
        try output.writer.print("JSON: {s}\nBFBS: {s}\n", .{ json_path, binary_path });
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}
