//! Unified host tool: compile FBS/BFBS metadata to Zig, BFBS, or schema JSON.
//! `flatzz --zig input.fbs > output.zig`
//! `flatzz --bfbs input.fbs > output.bfbs`
//! `flatzz --json input.fbs > output.json`
//! `flatzz --json input.bfbs > output.json`
//! Native parsing and BFBS conversion share reflection metadata with the Zast backend.
//! Options borrow the argument strings; metadata and temporary storage use the
//! caller's arena. Encoded BFBS is owned by its supplied Zig allocator.

const std = @import("std");
const compiler = @import("flatzz_compiler");
const codegen = @import("codegen");

const Format = enum { bfbs, json, zig };

const usage =
    \\usage: flatzz (--bfbs|--json|--zig) [-I directory]... [--depfile file] [--deptarget target] schema.fbs
    \\       flatzz (--json|--zig) schema.bfbs
    \\Writes the selected schema format to stdout. Redirect it to save a file.
    \\
;

/// Parsed arguments borrow the argument strings; the include-path slice uses the
/// caller's arena. Invalid arguments return null; allocation failures propagate.
const Options = struct {
    format: Format,
    input_path: []const u8,
    include_paths: []const []const u8,
    depfile: ?[]const u8 = null,
    deptarget: ?[]const u8 = null,

    fn parse(allocator: std.mem.Allocator, arguments: []const []const u8) !?Options {
        if (arguments.len < 2) return null;
        const format_name = std.mem.cutPrefix(u8, arguments[0], "--") orelse return null;
        const format = std.meta.stringToEnum(Format, format_name) orelse return null;

        var include_paths: std.ArrayList([]const u8) = .empty;
        var input_path: ?[]const u8 = null;
        var depfile: ?[]const u8 = null;
        var deptarget: ?[]const u8 = null;
        var argument_index: usize = 1;
        while (argument_index < arguments.len) : (argument_index += 1) {
            const argument = arguments[argument_index];
            if (std.meta.stringToEnum(
                enum { @"-I", @"--depfile", @"--deptarget" },
                argument,
            )) |flag| {
                argument_index += 1;
                if (argument_index == arguments.len) return null;
                const value = arguments[argument_index];
                switch (flag) {
                    .@"-I" => try include_paths.append(allocator, value),
                    .@"--depfile" => depfile = value,
                    .@"--deptarget" => deptarget = value,
                }
            } else {
                if (std.mem.startsWith(u8, argument, "-") or input_path != null) return null;
                input_path = argument;
            }
        }
        const path = input_path orelse return null;
        if (deptarget != null and depfile == null) return null;
        if (std.mem.endsWith(u8, path, ".bfbs") and
            (format == .bfbs or include_paths.items.len != 0 or depfile != null)) return null;
        return .{
            .format = format,
            .input_path = path,
            .include_paths = include_paths.items,
            .depfile = depfile,
            .deptarget = deptarget,
        };
    }
};

/// Cache lexically normalized source names in load order. Aliases containing
/// `.` or `..` deduplicate; symlink paths retain their own include directories.
/// Buffers belong to the caller's arena, and no allocator is stored.
const Sources = struct {
    file_io: std.Io,
    working_directory: []const u8,
    include_paths: []const []const u8,
    loaded: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn read(
        self: *Sources,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !compiler.parser.Source {
        const name = try std.fs.path.resolve(allocator, &.{ self.working_directory, path });
        if (self.loaded.get(name)) |text| return .{ .name = name, .text = text };
        const text = try std.Io.Dir.cwd().readFileAlloc(self.file_io, name, allocator, .unlimited);
        try self.loaded.put(allocator, name, text);
        return .{ .name = name, .text = text };
    }

    fn load(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        from: []const u8,
        requested: []const u8,
    ) anyerror!compiler.parser.Source {
        const self: *Sources = @ptrCast(@alignCast(context.?));
        if (std.fs.path.isAbsolute(requested)) return self.read(allocator, requested);
        for (self.include_paths) |directory| {
            const path = try std.fs.path.resolve(allocator, &.{ directory, requested });
            return self.read(allocator, path) catch |failure| switch (failure) {
                error.FileNotFound, error.NotDir => continue,
                else => return failure,
            };
        }
        return self.read(allocator, try std.fs.path.resolve(allocator, &.{
            std.fs.path.dirname(from) orelse ".", requested,
        }));
    }
};

/// Complete parsing and Zig/BFBS generation before writing the depfile or stdout.
/// Metadata uses the caller's arena; JSON streams through bounded output buffering.
fn printSource(allocator: std.mem.Allocator, file_io: std.Io, options: Options) !void {
    var sources: Sources = .{
        .file_io = file_io,
        .working_directory = try std.process.currentPathAlloc(file_io, allocator),
        .include_paths = options.include_paths,
    };
    const source = try sources.read(allocator, options.input_path);
    var diagnostic: compiler.parser.Diagnostic = .{};
    const schema = compiler.parser.parseWithOptions(allocator, source.text, .{
        .filename = source.name,
        .include_loader = Sources.load,
        .include_context = &sources,
        .diagnostic = &diagnostic,
    }) catch |failure| {
        if (diagnostic.message.len == 0) return failure;
        std.debug.print("{s}:{d}:{d}: {s}\n", .{
            diagnostic.filename, diagnostic.line, diagnostic.column, diagnostic.message,
        });
        return error.SchemaParseFailed;
    };
    // Finish both allocating backends before replacing a depfile or writing stdout.
    const generated = if (options.format == .zig) try codegen.generate(allocator, schema) else null;
    defer if (generated) |bytes| allocator.free(bytes);
    const encoded = if (options.format == .bfbs) try compiler.bfbs.encode(
        allocator,
        schema,
    ) else null;
    defer if (encoded) |bytes| allocator.free(bytes);
    if (options.depfile) |path| {
        const target: []const u8 = options.deptarget orelse try allocator.print(
            "{s}.{s}",
            .{
                std.fs.path.stem(options.input_path),
                if (options.format == .zig) "zig" else "bfbs",
            },
        );
        try writeDepfile(file_io, path, target, sources.loaded.keys()[1..]);
    }
    if (encoded orelse generated) |bytes| {
        try std.Io.File.stdout().writeStreamingAll(file_io, bytes);
    } else {
        try printJson(file_io, schema);
    }
}

fn printJson(file_io: std.Io, schema: compiler.reflection.Schema) !void {
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), file_io, &buffer);
    var json: std.json.Stringify = .{
        .writer = &output.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try compiler.json.write(schema, &json);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

/// Replace a Make-style depfile only after every path was written successfully.
/// Paths exclude the root input, which build consumers track separately.
fn writeDepfile(
    file_io: std.Io,
    path: []const u8,
    target: []const u8,
    dependencies: []const []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(file_io, path, .{ .replace = true });
    defer file.deinit(file_io);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(file.file, file_io, &buffer);
    try writeDependency(&output.interface, target);
    try output.interface.writeByte(':');
    for (dependencies) |dependency| {
        try output.interface.writeByte(' ');
        try writeDependency(&output.interface, dependency);
    }
    try output.interface.writeByte('\n');
    try output.interface.flush();
    try file.replace(file_io);
}

fn writeDependency(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        switch (byte) {
            ' ' => try writer.writeByte('\\'),
            '\n', '\r' => return error.InvalidDependencyPath,
            else => {},
        }
        try writer.writeByte(byte);
    }
}

/// Convert one FBS/BFBS input to stdout using the process arena for metadata.
/// `--help` returns zero; invalid arguments or diagnosed FBS errors return one.
/// File, codec, allocation, dependency-file, and stdout failures propagate.
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    const options = (try Options.parse(allocator, arguments[1..])) orelse {
        std.debug.print("{s}", .{usage});
        return 1;
    };
    if (std.mem.endsWith(u8, options.input_path, ".bfbs")) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            options.input_path,
            allocator,
            .unlimited,
        );
        const schema = try compiler.bfbs.decode(allocator, bytes);
        if (options.format == .zig) {
            const source = try codegen.generate(allocator, schema);
            defer allocator.free(source);
            try std.Io.File.stdout().writeStreamingAll(init.io, source);
        } else try printJson(init.io, schema);
    } else {
        printSource(allocator, init.io, options) catch |failure| switch (failure) {
            error.SchemaParseFailed => return 1,
            else => return failure,
        };
    }
    return 0;
}

const include_dependency_arguments = [_][]const u8{
    "--json",    "main.fbs", "-I",        "first", "-I",          "second",
    "--depfile", "old.d",    "--depfile", "new.d", "--deptarget", "result.json",
};
const invalid_cli_arguments = [_][]const []const u8{
    &.{},
    &.{"--json"},
    &.{ "--json", "--deptarget", "out", "main.fbs" },
    &.{ "--json", "main.fbs", "-I" },
    &.{ "--json", "main.fbs", "other.fbs" },
    &.{ "--bfbs", "main.bfbs" },
    &.{ "--json", "-I", ".", "main.bfbs" },
    &.{ "json", "main.fbs" },
    &.{ "-json", "main.fbs" },
    &.{ "---json", "main.fbs" },
    &.{ "--JSON", "main.fbs" },
    &.{ "--json=1", "main.fbs" },
    &.{ "--", "main.fbs" },
};

test "CLI options share include and dependency settings across formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const options = (try Options.parse(arena.allocator(), &include_dependency_arguments)).?;
    try std.testing.expectEqual(Format.json, options.format);
    try std.testing.expectEqualStrings("main.fbs", options.input_path);
    try std.testing.expectEqualStrings("first", options.include_paths[0]);
    try std.testing.expectEqualStrings("second", options.include_paths[1]);
    try std.testing.expectEqualStrings("new.d", options.depfile.?);
    try std.testing.expectEqualStrings("result.json", options.deptarget.?);
    for (invalid_cli_arguments) |arguments|
        try std.testing.expect((try Options.parse(arena.allocator(), arguments)) == null);
}

test "native include search respects explicit paths and normalized identities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file_io = std.testing.io;
    try temporary.dir.createDir(file_io, "inc", .default_dir);
    try temporary.dir.writeFile(file_io, .{
        .sub_path = "main.fbs",
        .data = "include \"choice.fbs\"; include \"./choice.fbs\"; table Root { value:Choice; } root_type Root;",
    });
    try temporary.dir.writeFile(
        file_io,
        .{ .sub_path = "choice.fbs", .data = "table Choice { selected:int = 1; }" },
    );
    try temporary.dir.writeFile(
        file_io,
        .{ .sub_path = "inc/choice.fbs", .data = "table Choice { selected:int = 3; }" },
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sources: Sources = .{
        .file_io = file_io,
        .working_directory = try temporary.dir.realPathFileAlloc(file_io, ".", allocator),
        .include_paths = &.{try temporary.dir.realPathFileAlloc(file_io, "inc", allocator)},
    };
    const source = try sources.read(allocator, "main.fbs");
    const schema = try compiler.parser.parseWithOptions(allocator, source.text, .{
        .filename = source.name,
        .include_loader = Sources.load,
        .include_context = &sources,
    });
    try std.testing.expectEqual(@as(i64, 3), schema.objects[0].fields[0].default_integer);
    try std.testing.expectEqual(@as(usize, 2), sources.loaded.count());
    for (sources.loaded.keys()) |path| try std.testing.expect(std.fs.path.isAbsolute(path));
}

test "native depfiles retain space escaping and preserve previous output on failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file_io = std.testing.io;
    const directory = try temporary.dir.realPathFileAlloc(file_io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ directory, "schema.d" });
    try writeDepfile(file_io, path, "target name#$", &.{ "first path.fbs", "other#$.fbs" });
    const expected = "target\\ name#$: first\\ path.fbs other#$.fbs\n";
    try std.testing.expectEqualStrings(
        expected,
        try temporary.dir.readFileAlloc(file_io, "schema.d", allocator, .unlimited),
    );
    try std.testing.expectError(
        error.InvalidDependencyPath,
        writeDepfile(file_io, path, "bad\nname", &.{}),
    );
    try std.testing.expectEqualStrings(
        expected,
        try temporary.dir.readFileAlloc(file_io, "schema.d", allocator, .unlimited),
    );
}

test "Zig generation accepts FBS includes depfiles and existing BFBS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fbs = (try Options.parse(
        allocator,
        &.{ "--zig", "-I", "inc", "--depfile", "result.d", "input.fbs" },
    )).?;
    try std.testing.expectEqual(Format.zig, fbs.format);
    try std.testing.expectEqualStrings("inc", fbs.include_paths[0]);
    try std.testing.expectEqualStrings("result.d", fbs.depfile.?);
    try std.testing.expectEqual(
        Format.zig,
        (try Options.parse(allocator, &.{ "--zig", "input.bfbs" })).?.format,
    );
    try std.testing.expect(
        (try Options.parse(allocator, &.{ "--zig", "-I", "inc", "input.bfbs" })) == null,
    );
}
