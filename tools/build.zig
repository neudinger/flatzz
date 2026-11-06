//! Native host-only schema tool, enabled by default for root package builds.
//! The runtime does not link the executable or require external dependencies.

const std = @import("std");

/// Dependencies returned to the package's command declaration list.
pub const Steps = struct {
    executable: *std.Build.Step.Compile,
    check: [4]*std.Build.Step,
    tests: [3]*std.Build.Step,
    generate_reading: *std.Build.Step,
};

/// Export the host tool and return its compile, test, and source-update steps.
/// Only the explicit generation command depends on the source update.
pub fn add(builder: *std.Build) ?Steps {
    const zast = builder.lazyDependency("zast", .{ .target = builder.graph.host, .optimize = .ReleaseSafe }) orelse return null;
    const host_runtime = builder.createModule(.{
        .root_source_file = builder.path("src/runtime.zig"),
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
    });
    const host_compiler = builder.createModule(.{
        .root_source_file = builder.path("src/compiler.zig"),
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "flatzz", .module = host_runtime }},
    });
    const codegen = builder.createModule(.{
        .root_source_file = builder.path("src/compiler/codegen.zig"),
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "flatzz", .module = host_runtime },
            .{ .name = "flatzz_compiler", .module = host_compiler },
            .{ .name = "zast", .module = zast.module("zast") },
        },
    });

    const schema_tool = schema_tool_blk: {
        const executable = builder.addExecutable(.{
            .name = "flatzz-schema",
            .root_module = builder.createModule(.{
                .root_source_file = builder.path("tools/schema.zig"),
                .target = builder.graph.host,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "flatzz_compiler", .module = host_compiler },
                    .{ .name = "codegen", .module = codegen },
                },
            }),
        });
        builder.installArtifact(executable);
        break :schema_tool_blk executable;
    };

    const command_tests = command_tests_blk: {
        const tests = builder.addTest(.{ .root_module = schema_tool.root_module });
        break :command_tests_blk .{ .compile = &tests.step, .run = &builder.addRunArtifact(tests).step };
    };

    const reading = reading_blk: {
        const module = generatedModule(builder, schema_tool, host_runtime, "tests/fixtures/reading/reading.fbs");
        const update = builder.addUpdateSourceFiles();
        update.addCopyFileToSource(module.root_source_file.?, "tests/fixtures/reading/reading.zig");
        const current = builder.addCheckFile(module.root_source_file.?, .{ .expected_exact = @embedFile("../tests/fixtures/reading/reading.zig") });
        current.setName("tests/fixtures/reading/reading.zig matches the FBS generator");
        break :reading_blk .{ .module = module, .update = &update.step, .check = &current.step };
    };

    const generated_tests = generated_tests_blk: {
        const cases = generatedModule(builder, schema_tool, host_runtime, "tests/flatbuf/codegen.fbs");
        const names = generatedModule(builder, schema_tool, host_runtime, "tests/flatbuf/codegen_names.fbs");
        const tests = builder.addTest(.{ .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_codegen.zig"),
            .target = builder.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "flatzz", .module = host_runtime },
                .{ .name = "flatzz_compiler", .module = host_compiler },
                .{ .name = "codegen", .module = codegen },
                .{ .name = "generated", .module = reading.module },
                .{ .name = "cases", .module = cases },
                .{ .name = "names", .module = names },
            },
        }) });
        break :generated_tests_blk .{ .compile = &tests.step, .run = &builder.addRunArtifact(tests).step };
    };

    return .{
        .executable = schema_tool,
        .check = .{ &schema_tool.step, command_tests.compile, reading.check, generated_tests.compile },
        .tests = .{ command_tests.run, reading.check, generated_tests.run },
        .generate_reading = reading.update,
    };
}

/// Track root and transitive includes; compile the actual stdout as its own module.
fn generatedModule(builder: *std.Build, tool: *std.Build.Step.Compile, runtime: *std.Build.Module, source_path: []const u8) *std.Build.Module {
    const run = builder.addRunArtifact(tool);
    run.addArgs(&.{ "--zig", "--depfile" });
    _ = run.addDepFileOutputArg2("schema.d", .{});
    run.addFileArg(builder.path(source_path));
    return builder.createModule(.{
        .root_source_file = run.captureStdOut(.{ .basename = builder.fmt("{s}.zig", .{std.fs.path.stem(source_path)}) }),
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "flatzz", .module = runtime }},
    });
}
