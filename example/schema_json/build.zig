//! Generate tracked BFBS/JSON outputs and build their path printer.

const std = @import("std");

/// A generated schema file and its path beneath the installation prefix.
const SchemaOutput = struct {
    source: std.Build.LazyPath,
    destination: []const u8,
};

/// Register host-only FBS to BFBS/JSON conversion with include tracking.
/// Outputs are ordered as JSON/BFBS pairs; paths and storage belong to the build.
fn compileSchemas(builder: *std.Build) ![]const SchemaOutput {
    const flatzz = builder.dependency("flatzz", .{
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
        .@"schema-tools" = true,
    });
    const schema_tool = flatzz.artifact("flatzz-schema");
    const schema_directory = flatzz.path("example/flatbuf");
    builder.dependOnDirectoryContents(schema_directory);

    const build_io = builder.graph.io;
    var schemas = try flatzz.builder.root.openDir(
        build_io,
        "example/flatbuf",
        .{ .iterate = true },
    );
    defer schemas.close(build_io);
    var walker = try schemas.walk(builder.allocator);
    defer walker.deinit();
    var outputs: std.ArrayList(SchemaOutput) = .empty;

    while (try walker.next(build_io)) |entry| {
        const source_path = schema_directory.path(builder, entry.path);
        if (entry.kind == .directory) {
            builder.dependOnDirectoryContents(source_path);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".fbs")) continue;
        const basename = std.fs.path.stem(entry.basename);
        const relative_stem = entry.path[0 .. entry.path.len - ".fbs".len];

        const binary_schema = binary_schema_blk: {
            const compile_schema = builder.addRunArtifact(schema_tool);
            compile_schema.step.name = builder.fmt("compile {s}", .{entry.path});
            compile_schema.addArgs(&.{ "--bfbs", "-I" });
            compile_schema.addDirectoryArg(schema_directory);
            compile_schema.addArg("--depfile");
            _ = compile_schema.addDepFileOutputArg2("schema.d", .{});
            compile_schema.addFileArg(source_path);
            break :binary_schema_blk compile_schema.captureStdOut(
                .{ .basename = builder.fmt("{s}.bfbs", .{basename}) },
            );
        };

        const json_schema = json_schema_blk: {
            const print_json = builder.addRunArtifact(schema_tool);
            print_json.step.name = builder.fmt("decode {s}", .{entry.path});
            print_json.addArg("--json");
            print_json.addFileArg(binary_schema);
            break :json_schema_blk print_json.captureStdOut(
                .{ .basename = builder.fmt("{s}.json", .{basename}) },
            );
        };

        try outputs.appendSlice(builder.allocator, &.{
            .{
                .source = json_schema,
                .destination = builder.fmt("schema/{s}.json", .{relative_stem}),
            },
            .{
                .source = binary_schema,
                .destination = builder.fmt("schema/{s}.bfbs", .{relative_stem}),
            },
        });
    }
    return outputs.items;
}

/// Build the path printer and connect generated schema files to its targets.
pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const schema_files = try compileSchemas(builder);

    const app = app_blk: {
        const executable = builder.addExecutable(.{
            .name = "flatzz-schema-example",
            .root_module = builder.createModule(.{
                .root_source_file = builder.path("main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        builder.installArtifact(executable);
        const run = builder.addRunArtifact(executable);
        for (schema_files) |schema_file| {
            const install = builder.addInstallFile(schema_file.source, schema_file.destination);
            builder.getInstallStep().dependOn(&install.step);
            run.step.dependOn(&install.step);
            run.addFileArg2(
                builder.graph.path(.install_prefix, schema_file.destination),
                .{ .make_absolute = true },
            );
        }
        break :app_blk .{ .compile = &executable.step, .run = &run.step };
    };

    inline for (.{
        .{
            .tag = .run,
            .description = "Print generated JSON/BFBS paths",
            .prerequisites = .{app.run},
        },
        .{
            .tag = .check,
            .description = "Compile the app and convert the schemas",
            .prerequisites = .{app.compile},
        },
    }) |command| {
        const command_step = builder.step(@tagName(command.tag), command.description);
        inline for (command.prerequisites) |prerequisite| command_step.dependOn(prerequisite);
        for (schema_files) |schema_file| schema_file.source.addStepDependencies(command_step);
    }
}
