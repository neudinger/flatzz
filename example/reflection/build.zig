const std = @import("std");

/// Build an FBS parser example without schema generation or Zast.
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const flatzz = builder.dependency("flatzz", .{
        .target = target,
        .optimize = optimize,
        .@"schema-tools" = false,
    });

    const app = app_blk: {
        const executable = builder.addExecutable(.{
            .name = "flatzz-fbs-example",
            .root_module = builder.createModule(.{
                .root_source_file = builder.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "flatzz_compiler", .module = flatzz.module("flatzz_compiler") }},
            }),
        });
        builder.installArtifact(executable);
        const run = builder.addRunArtifact(executable);
        run.addFileArg(flatzz.path("example/flatbuf/reading.fbs"));
        break :app_blk .{ .compile = &executable.step, .run = &run.step };
    };

    inline for (.{
        .{
            .tag = .run,
            .description = "Parse FBS into reflection metadata",
            .prerequisites = .{app.run},
        },
        .{
            .tag = .check,
            .description = "Compile the reflection example",
            .prerequisites = .{app.compile},
        },
    }) |command| {
        const command_step = builder.step(@tagName(command.tag), command.description);
        inline for (command.prerequisites) |prerequisite| command_step.dependOn(prerequisite);
    }
}
