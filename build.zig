//! Build the runtime package, generated examples, host schema tool, and test contracts.
//! `zig build docs` installs the public API reference under `zig-out/docs`.

const std = @import("std");
const schema_build = @import("tools/build.zig");
const compile_fail = @import("tests/compile_fail.zig");

const Step = std.Build.Step;

const format_paths = [_][]const u8{
    "build.zig", "build.zig.zon", "src", "tests", "tools", "example",
};

const schema_examples = [_]struct {
    name: []const u8,
    schema_path: []const u8,
    description: []const u8,
}{
    .{
        .name = "readme",
        .schema_path = "example/readme/rocket.fbs",
        .description = "Generate Rocket and run the README round trip and mutation example",
    },
    .{
        .name = "mission",
        .schema_path = "example/flatbuf/mission/mission.fbs",
        .description = "Generate Mission from two FBS files, then serialize and read it",
    },
    .{
        .name = "monster",
        .schema_path = "example/flatbuf/monster.fbs",
        .description = "Generate Monster, then serialize and read it",
    },
};

/// Generate a schema on the host; the output path belongs to the build.
fn compileSchema(
    builder: *std.Build,
    schema_tool: *Step.Compile,
    source_path: []const u8,
) std.Build.LazyPath {
    return zig_schema_blk: {
        const generate = builder.addRunArtifact(schema_tool);
        generate.addArgs(&.{ "--zig", "--depfile" });
        _ = generate.addDepFileOutputArg2("schema.d", .{});
        generate.addFileArg(builder.path(source_path));
        break :zig_schema_blk generate.captureStdOut(.{
            .basename = builder.fmt("{s}.zig", .{std.fs.path.stem(source_path)}),
        });
    };
}

/// Configure target-aware runtime artifacts and host-only schema tooling.
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    const runtime_module = builder.addModule("flatzz", .{
        .root_source_file = builder.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compiler_module = builder.addModule("flatzz_compiler", .{
        .root_source_file = builder.path("src/compiler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flatzz", .module = runtime_module }},
    });

    const docs = docs_blk: {
        // Zig's doc renderer recognizes the module root by its matching filename.
        const documentation = builder.addObject(.{
            .name = "runtime",
            .root_module = runtime_module,
        });
        const install_docs = builder.addInstallDirectory(.{
            .source_dir = documentation.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });
        break :docs_blk &install_docs.step;
    };

    const reading_module = builder.createModule(.{
        .root_source_file = builder.path("tests/fixtures/reading/reading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flatzz", .module = runtime_module }},
    });
    const test_imports: []const std.Build.Module.Import = &.{
        .{ .name = "runtime", .module = runtime_module },
        .{ .name = "reading", .module = reading_module },
    };

    const builder_example = builder_example_blk: {
        const module = builder.createModule(.{
            .root_source_file = builder.path("example/builder/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = test_imports,
        });

        const executable = builder.addExecutable(.{
            .name = "flatzz-builder-example",
            .root_module = module,
        });
        builder.installArtifact(executable);
        const run = builder.addRunArtifact(executable);
        run.addPassthruArgs();
        break :builder_example_blk .{ .compile = &executable.step, .run = &run.step };
    };

    const schema_tools = if (builder.option(
        bool,
        "schema-tools",
        "Build host schema tooling (defaults on for root builds)",
    ) orelse builder.isRoot())
        schema_build.add(builder)
    else
        null;

    const generated_reading = if (schema_tools) |tools| reading_module_blk: {
        const source = compileSchema(builder, tools.executable, "example/flatbuf/reading.fbs");
        builder.getInstallStep().dependOn(
            &builder.addInstallFile(source, "schema/reading.zig").step,
        );
        break :reading_module_blk builder.createModule(.{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flatzz", .module = runtime_module }},
        });
    } else null;

    const generated = if (generated_reading) |reading| app_blk: {
        // The generator runs on the host; the app imports only its output and runtime.
        const executable = builder.addExecutable(.{
            .name = "flatzz-example",
            .root_module = builder.createModule(.{
                .root_source_file = builder.path("example/generated/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "reading", .module = reading },
                    .{ .name = "flatzz", .module = runtime_module },
                },
            }),
        });
        builder.installArtifact(executable);
        const run = builder.addRunArtifact(executable);
        run.addPassthruArgs();
        break :app_blk .{ .compile = &executable.step, .run = &run.step };
    } else null;

    const examples = if (schema_tools) |tools| examples_blk: {
        var checks: [schema_examples.len * 2]*Step = undefined;
        var tests: [schema_examples.len]*Step = undefined;
        for (schema_examples, 0..) |example, index| {
            const schema_name = std.fs.path.stem(example.schema_path);
            const schema = builder.createModule(.{
                .root_source_file = compileSchema(builder, tools.executable, example.schema_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "flatzz", .module = runtime_module }},
            });
            const module = builder.createModule(.{
                .root_source_file = builder.path(
                    builder.fmt("example/{s}/main.zig", .{example.name}),
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = schema_name, .module = schema },
                    .{ .name = "flatzz", .module = runtime_module },
                },
            });
            const executable = builder.addExecutable(.{
                .name = builder.fmt("flatzz-{s}-example", .{example.name}),
                .root_module = module,
            });
            const example_tests = builder.addTest(.{ .root_module = module });
            checks[index * 2] = &executable.step;
            checks[index * 2 + 1] = &example_tests.step;
            tests[index] = &builder.addRunArtifact(example_tests).step;
            const run = builder.step(
                builder.fmt("run-{s}", .{example.name}),
                example.description,
            );
            run.dependOn(&builder.addRunArtifact(executable).step);
        }
        break :examples_blk .{ .check = checks, .tests = tests };
    } else null;

    const suites = suites_blk: {
        const tests = builder.addTest(.{ .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = test_imports,
        }) });
        const compiler_tests = builder.addTest(.{ .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_compiler.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flatzz_compiler", .module = compiler_module }},
        }) });
        const parser_tests = builder.addTest(.{ .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flatzz_compiler", .module = compiler_module }},
        }) });
        break :suites_blk .{
            .check = [_]*Step{ &tests.step, &compiler_tests.step, &parser_tests.step },
            .tests = [_]*Step{
                &builder.addRunArtifact(tests).step,
                &builder.addRunArtifact(compiler_tests).step,
                &builder.addRunArtifact(parser_tests).step,
            },
        };
    };

    const contracts = contracts_blk: {
        const failures = compile_fail.cases;
        const sources = builder.addWriteFiles();
        var steps: [failures.len]*Step = undefined;
        for (failures, 0..) |failure, failure_index| {
            const rejected = builder.addTest(.{ .root_module = builder.createModule(.{
                .root_source_file = sources.add(
                    builder.fmt("test_{s}.zig", .{failure.name}),
                    failure.source,
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "runtime", .module = runtime_module }},
            }) });
            rejected.expect_errors = .{ .contains = failure.expected_error };
            steps[failure_index] = &rejected.step;
        }
        break :contracts_blk steps;
    };

    const format = format_blk: {
        const check_format = builder.addFmt(.{
            .paths = builder.pathList(&format_paths),
            .check = true,
        });
        break :format_blk &check_format.step;
    };

    const checks = std.mem.concat(builder.allocator, *Step, &.{
        &.{builder_example.compile},
        if (generated) |app| &.{app.compile} else &.{},
        &suites.check,
        &contracts,
        if (schema_tools) |*tools| &tools.check else &.{},
        if (examples) |*apps| &apps.check else &.{},
    }) catch @panic("OOM");
    const test_steps = std.mem.concat(builder.allocator, *Step, &.{
        &suites.tests,
        &contracts,
        if (schema_tools) |*tools| &tools.tests else &.{},
        if (examples) |*apps| &apps.tests else &.{},
    }) catch @panic("OOM");

    inline for (.{
        .{
            .tag = .compiler,
            .description = "Build and install only flatzz",
            .prerequisites = if (schema_tools) |tools|
                @as([]const *Step, &.{tools.install})
            else
                &.{},
        },
        .{
            .tag = .docs,
            .description = "Build the public API reference",
            .prerequisites = @as([]const *Step, &.{docs}),
        },
        .{
            .tag = .run,
            .description = "Generate Reading, then build, verify, read, and mutate it",
            .prerequisites = if (generated) |app| @as([]const *Step, &.{app.run}) else &.{},
        },
        .{
            .tag = .@"run-builder",
            .description = "Run the Builder example",
            .prerequisites = @as([]const *Step, &.{builder_example.run}),
        },
        // Compile-only coverage also supports targets that cannot run on this host.
        .{
            .tag = .check,
            .description = "Compile all tools and test contracts",
            .prerequisites = checks,
        },
        .{
            .tag = .@"test",
            .description = "Test runtime, native schema conversion, and compile-time contracts",
            .prerequisites = test_steps,
        },
        .{
            .tag = .@"generate-reading",
            .description = "Regenerate the checked-in Reading fixture",
            .prerequisites = if (schema_tools) |tools|
                @as([]const *Step, &.{tools.generate_reading})
            else
                &.{},
        },
        .{
            .tag = .fmt,
            .description = "Check Zig source formatting",
            .prerequisites = @as([]const *Step, &.{format}),
        },
    }) |command| {
        // Optional schema targets are absent when their tools are disabled.
        if (command.prerequisites.len != 0) {
            const command_step = builder.step(@tagName(command.tag), command.description);
            for (command.prerequisites) |prerequisite| command_step.dependOn(prerequisite);
        }
    }
}
