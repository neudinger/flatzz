//! Build the runtime package, generated examples, host schema tool, and test contracts.
//! Website preparation and browser tests belong to the consuming site project.

const std = @import("std");
const schema_build = @import("tools/build.zig");
const wasm_build = @import("tools/wasm/build.zig");
const compile_fail = @import("tests/compile_fail.zig");
const Build = std.Build;
const Module = Build.Module;
const Step = Build.Step;

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

/// Reuse target and optimization options for source paths and generated files.
fn module(builder: *Build, source: anytype, options: Module.CreateOptions) *Module {
    const path = if (@TypeOf(source) == Build.LazyPath) source else builder.path(source);
    var configuration = options;
    configuration.root_source_file = path;
    return builder.createModule(configuration);
}

/// Generate a schema on the host; the output path belongs to the build.
fn compileSchema(builder: *Build, schema_tool: *Step.Compile, source: []const u8) Build.LazyPath {
    const generate = builder.addRunArtifact(schema_tool);
    generate.addArgs(&.{ "--zig", "--depfile" });
    _ = generate.addDepFileOutputArg2("schema.d", .{});
    generate.addFileArg(builder.path(source));
    return generate.captureStdOut(.{
        .basename = builder.fmt("{s}.zig", .{std.fs.path.stem(source)}),
    });
}

/// Configure target-aware runtime artifacts, native schema tooling, and optional Wasm tooling.
pub fn build(builder: *Build) void {
    const options: Module.CreateOptions = .{
        .root_source_file = builder.path("src/runtime.zig"),
        .target = builder.standardTargetOptions(.{}),
        .optimize = builder.standardOptimizeOption(.{}),
    };
    // Compile-only commands also support targets that cannot run on this host.
    const check = builder.step("check", "Compile all tools and test contracts");
    const tests = builder.step(
        "test",
        "Test runtime, native schema conversion, and compile-time contracts",
    );
    const examples = builder.step("examples", "Compile the native Zig examples and their tests");
    const runtime_module = builder.addModule("flatzz", options);
    var runtime_options = options;
    runtime_options.imports = &.{.{ .name = "flatzz", .module = runtime_module }};
    var compiler_options = runtime_options;
    compiler_options.root_source_file = builder.path("src/compiler.zig");
    const compiler_module = builder.addModule("flatzz_compiler", compiler_options);

    // Emit the standard Zig viewers; website preparation belongs to flatzz-site.
    const docs = builder.step("docs", "Generate runtime and compiler API documentation");
    inline for (.{
        .{ "runtime", runtime_module, "docs" },
        .{ "compiler", compiler_module, "docs/compiler" },
    }) |reference| {
        const object = builder.addObject(.{ .name = reference[0], .root_module = reference[1] });
        const install = builder.addInstallDirectory(.{
            .source_dir = object.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = reference[2],
        });
        docs.dependOn(&install.step);
    }

    const reading_module = module(builder, "tests/fixtures/reading/reading.zig", runtime_options);
    var test_options = options;
    test_options.imports = &.{
        .{ .name = "runtime", .module = runtime_module },
        .{ .name = "reading", .module = reading_module },
    };
    const builder_example = builder.addExecutable(.{
        .name = "flatzz-builder-example",
        .root_module = module(builder, "example/builder/main.zig", test_options),
    });
    builder.installArtifact(builder_example);
    check.dependOn(&builder_example.step);
    examples.dependOn(&builder_example.step);
    const run_builder = builder.addRunArtifact(builder_example);
    run_builder.addPassthruArgs();

    const schema_tools_enabled = builder.option(
        bool,
        "schema-tools",
        "Build host schema tooling (defaults on for root builds)",
    ) orelse builder.isRoot();
    const schema_tools = if (schema_tools_enabled) schema_build.add(builder) else null;
    const wasm_compiler_enabled = builder.option(
        bool,
        "wasm-compiler",
        "Expose the Wasm compiler (defaults on with root schema tooling)",
    ) orelse (builder.isRoot() and schema_tools_enabled);
    if (wasm_compiler_enabled) wasm_build.add(builder);

    if (schema_tools) |tools| {
        const source = compileSchema(builder, tools.executable, "example/flatbuf/reading.fbs");
        const install = builder.addInstallFile(source, "schema/reading.zig");
        builder.getInstallStep().dependOn(&install.step);
        const reading = module(builder, source, runtime_options);
        // The generator runs on the host; the app imports only its output and runtime.
        const app_module = module(builder, "example/generated/main.zig", runtime_options);
        app_module.addImport("reading", reading);
        const generated_example = builder.addExecutable(.{
            .name = "flatzz-example",
            .root_module = app_module,
        });
        builder.installArtifact(generated_example);
        check.dependOn(&generated_example.step);
        examples.dependOn(&generated_example.step);
        const run = builder.addRunArtifact(generated_example);
        run.addPassthruArgs();
        const update = tools.generate_reading;
        inline for (.{
            .{ .run, "Generate Reading, then build, verify, read, and mutate it", &run.step },
            .{ .compiler, "Build and install only flatzz", tools.install },
            .{ .@"generate-reading", "Regenerate the checked-in Reading fixture", update },
        }) |command| builder.step(@tagName(command[0]), command[1]).dependOn(command[2]);
        for (tools.check) |prerequisite| check.dependOn(prerequisite);
        for (tools.tests) |prerequisite| tests.dependOn(prerequisite);

        for (schema_examples) |example| {
            const schema = module(
                builder,
                compileSchema(builder, tools.executable, example.schema_path),
                runtime_options,
            );
            const app_source = builder.fmt("example/{s}/main.zig", .{example.name});
            const example_module = module(builder, app_source, runtime_options);
            example_module.addImport(std.fs.path.stem(example.schema_path), schema);
            const executable = builder.addExecutable(.{
                .name = builder.fmt("flatzz-{s}-example", .{example.name}),
                .root_module = example_module,
            });
            const example_tests = builder.addTest(.{ .root_module = example_module });
            for ([_]*Step{ check, examples }) |command| {
                command.dependOn(&executable.step);
                command.dependOn(&example_tests.step);
            }
            tests.dependOn(&builder.addRunArtifact(example_tests).step);
            builder.step(builder.fmt("run-{s}", .{example.name}), example.description)
                .dependOn(&builder.addRunArtifact(executable).step);
        }
    }

    var compiler_test_options = options;
    compiler_test_options.imports = &.{.{ .name = "flatzz_compiler", .module = compiler_module }};
    inline for (.{
        .{ "tests/test_all.zig", test_options },
        .{ "tests/test_compiler.zig", compiler_test_options },
        .{ "tests/test_parser.zig", compiler_test_options },
    }) |suite| {
        const executable = builder.addTest(.{ .root_module = module(builder, suite[0], suite[1]) });
        check.dependOn(&executable.step);
        tests.dependOn(&builder.addRunArtifact(executable).step);
    }

    var case_options = options;
    case_options.imports = &.{.{ .name = "runtime", .module = runtime_module }};
    const sources = builder.addWriteFiles();
    for (compile_fail.cases) |failure| {
        const source = sources.add(builder.fmt("test_{s}.zig", .{failure.name}), failure.source);
        const rejected = builder.addTest(.{ .root_module = module(builder, source, case_options) });
        rejected.expect_errors = .{ .contains = failure.expected_error };
        check.dependOn(&rejected.step);
        tests.dependOn(&rejected.step);
    }

    const format = builder.addFmt(.{ .paths = builder.pathList(&format_paths), .check = true });
    inline for (.{
        .{ .@"run-builder", "Run the Builder example", &run_builder.step },
        .{ .fmt, "Check Zig source formatting", &format.step },
    }) |command| builder.step(@tagName(command[0]), command[1]).dependOn(command[2]);
}
