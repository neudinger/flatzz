//! Generate the Reading schema on the host and build its runtime-only consumer.

const std = @import("std");

/// Register host-side Reading generation; the output path belongs to the build.
fn compileReading(builder: *std.Build, flatzz: *std.Build.Dependency) std.Build.LazyPath {
    return zig_schema_blk: {
        const generate = builder.addRunArtifact(flatzz.artifact("flatzz"));
        generate.addArgs(&.{ "--zig", "--depfile" });
        _ = generate.addDepFileOutputArg2("reading.d", .{});
        generate.addFileArg(flatzz.path("example/flatbuf/reading.fbs"));
        break :zig_schema_blk generate.captureStdOut(.{ .basename = "reading.zig" });
    };
}

/// Generate Reading on the host and compile the application with only the runtime.
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const flatzz = builder.dependency("flatzz", .{
        .target = target,
        .optimize = optimize,
        .@"schema-tools" = true,
    });
    const runtime = flatzz.module("flatzz");

    const reading = reading_module_blk: {
        const source = compileReading(builder, flatzz);
        builder.getInstallStep().dependOn(
            &builder.addInstallFile(source, "schema/reading.zig").step,
        );
        break :reading_module_blk builder.createModule(.{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flatzz", .module = runtime }},
        });
    };

    const app = app_blk: {
        const executable = builder.addExecutable(.{
            .name = "flatzz-generated-example",
            .root_module = builder.createModule(.{
                .root_source_file = builder.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "reading", .module = reading },
                    .{ .name = "flatzz", .module = runtime },
                },
            }),
        });
        builder.installArtifact(executable);
        const run = builder.addRunArtifact(executable);
        break :app_blk .{ .compile = &executable.step, .run = &run.step };
    };

    inline for (.{
        .{
            .tag = .run,
            .description = "Generate Reading, then build, verify, read, and mutate it",
            .prerequisites = .{app.run},
        },
        .{
            .tag = .check,
            .description = "Compile the application with generated Reading",
            .prerequisites = .{app.compile},
        },
    }) |command| {
        const command_step = builder.step(@tagName(command.tag), command.description);
        inline for (command.prerequisites) |prerequisite| command_step.dependOn(prerequisite);
    }
}
