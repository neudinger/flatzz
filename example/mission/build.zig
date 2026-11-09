//! Generate Mission on the host and build a runtime-only application.

const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const flatzz = builder.dependency("flatzz", .{
        .target = target,
        .optimize = optimize,
        .@"schema-tools" = true,
    });
    const runtime = flatzz.module("flatzz");

    // The depfile tracks common.fbs as well as the root schema.
    const generate = builder.addRunArtifact(flatzz.artifact("flatzz"));
    generate.addArgs(&.{ "--zig", "--depfile" });
    _ = generate.addDepFileOutputArg2("mission.d", .{});
    generate.addFileArg(flatzz.path("example/flatbuf/mission/mission.fbs"));
    const mission = builder.createModule(.{
        .root_source_file = generate.captureStdOut(.{ .basename = "mission.zig" }),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flatzz", .module = runtime }},
    });

    const executable = builder.addExecutable(.{
        .name = "flatzz-mission-example",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mission", .module = mission },
                .{ .name = "flatzz", .module = runtime },
            },
        }),
    });
    builder.installArtifact(executable);

    const run = builder.addRunArtifact(executable);
    run.addPassthruArgs();
    builder.step("run", "Serialize and read Mission without an allocator").dependOn(&run.step);

    const tests = builder.addTest(.{ .root_module = executable.root_module });
    builder.step("test", "Test Mission round trips").dependOn(&builder.addRunArtifact(tests).step);

    const check = builder.step("check", "Compile the application and tests");
    check.dependOn(&executable.step);
    check.dependOn(&tests.step);
}
