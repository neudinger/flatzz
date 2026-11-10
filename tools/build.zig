//! Native host-only schema tool, enabled by default for root package builds.
//! The runtime does not link the executable or require external dependencies.

const std = @import("std");
const CompilerModules = @import("CompilerModules.zig");

/// Dependencies returned to the package's command declaration list.
pub const Steps = struct {
    /// Host executable installed as flatzz.
    executable: *std.Build.Step.Compile,
    /// Install only the host schema compiler.
    install: *std.Build.Step,
    /// Tool compilation, CLI tests, fixture consistency, and generated-code checks.
    check: [4]*std.Build.Step,
    /// CLI tests, fixture consistency, and generated-code test execution.
    tests: [3]*std.Build.Step,
    /// Explicit source-update step for the checked-in Reading fixture.
    generate_reading: *std.Build.Step,
};

/// Track root and transitive includes; compile the actual stdout as its own module.
fn generatedModule(
    builder: *std.Build,
    tool: *std.Build.Step.Compile,
    runtime: *std.Build.Module,
    source_path: []const u8,
) *std.Build.Module {
    const run = builder.addRunArtifact(tool);
    run.addArgs(&.{ "--zig", "--depfile" });
    _ = run.addDepFileOutputArg2("schema.d", .{});
    run.addFileArg(builder.path(source_path));
    return builder.createModule(.{
        .root_source_file = run.captureStdOut(
            .{ .basename = builder.fmt("{s}.zig", .{std.fs.path.stem(source_path)}) },
        ),
        .target = builder.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "flatzz", .module = runtime }},
    });
}

/// Export the host tool and return its compile, test, and source-update steps.
/// Only the explicit generation command depends on the source update.
pub fn add(builder: *std.Build) ?Steps {
    const modules = CompilerModules.init(
        builder,
        builder.graph.host,
        .ReleaseSafe,
    ) orelse return null;
    const host_runtime = modules.runtime;
    const host_compiler = modules.compiler;
    const codegen = modules.codegen;

    const schema_tool = schema_tool_blk: {
        const executable = builder.addExecutable(.{
            .name = "flatzz",
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
        break :schema_tool_blk executable;
    };
    const install = builder.addInstallArtifact(schema_tool, .{});
    builder.getInstallStep().dependOn(&install.step);

    const command_tests = command_tests_blk: {
        const tests = builder.addTest(.{ .root_module = schema_tool.root_module });
        break :command_tests_blk .{
            .compile = &tests.step,
            .run = &builder.addRunArtifact(tests).step,
        };
    };

    const reading = reading_blk: {
        const module = generatedModule(
            builder,
            schema_tool,
            host_runtime,
            "tests/fixtures/reading/reading.fbs",
        );
        const update = builder.addUpdateSourceFiles();
        update.addCopyFileToSource(module.root_source_file.?, "tests/fixtures/reading/reading.zig");
        const current = builder.addCheckFile(module.root_source_file.?, .{
            .expected_exact = @embedFile("../tests/fixtures/reading/reading.zig"),
        });
        current.setName("tests/fixtures/reading/reading.zig matches the FBS generator");
        break :reading_blk .{ .module = module, .update = &update.step, .check = &current.step };
    };

    const generated_tests = generated_tests_blk: {
        const cases = generatedModule(
            builder,
            schema_tool,
            host_runtime,
            "tests/flatbuf/codegen.fbs",
        );
        const names = generatedModule(
            builder,
            schema_tool,
            host_runtime,
            "tests/flatbuf/codegen_names.fbs",
        );
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
        break :generated_tests_blk .{
            .compile = &tests.step,
            .run = &builder.addRunArtifact(tests).step,
        };
    };

    return .{
        .executable = schema_tool,
        .install = &install.step,
        .check = .{
            &schema_tool.step, command_tests.compile, reading.check, generated_tests.compile,
        },
        .tests = .{ command_tests.run, reading.check, generated_tests.run },
        .generate_reading = reading.update,
    };
}
