//! Build the runtime package, Reading example, and test contracts.
//! `zig build docs` installs the public API reference under `zig-out/docs`.

const std = @import("std");

/// Configure target-aware runtime artifacts and tests.
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    const runtime_module = builder.addModule("flatzz", .{
        .root_source_file = builder.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Zig's doc renderer recognizes the module root by its matching filename.
    const documentation = builder.addObject(.{ .name = "runtime", .root_module = runtime_module });
    const install_docs = builder.addInstallDirectory(.{
        .source_dir = documentation.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    builder.step("docs", "Build the public API reference").dependOn(&install_docs.step);
    const reading_module = builder.createModule(.{
        .root_source_file = builder.path("src/reading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flatzz", .module = runtime_module }},
    });
    const test_imports: []const std.Build.Module.Import = &.{
        .{ .name = "runtime", .module = runtime_module },
        .{ .name = "reading", .module = reading_module },
    };

    const mod = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = test_imports,
    });

    const exe = builder.addExecutable(.{ .name = "flatzz", .root_module = mod });
    builder.installArtifact(exe);
    const run = builder.addRunArtifact(exe);
    run.addPassthruArgs();
    builder.step("run", "Run the Builder example").dependOn(&run.step);

    const benchmark = builder.addExecutable(.{
        .name = "flatzz-benchmark",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = test_imports,
        }),
    });
    const run_benchmark = builder.addRunArtifact(benchmark);
    builder.step(
        "benchmark",
        "Measure bounded runtime workloads",
    ).dependOn(&run_benchmark.step);

    const tests = builder.addTest(.{ .root_module = builder.createModule(.{
        .root_source_file = builder.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = test_imports,
    }) });
    // Compile-only coverage also supports targets that cannot run on this host.
    const check_step = builder.step("check", "Compile all tools and test contracts");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&benchmark.step);
    const test_step = builder.step(
        "test",
        "Test runtime behavior and compile-time contracts",
    );
    check_step.dependOn(&tests.step);
    test_step.dependOn(&builder.addRunArtifact(tests).step);

    const producer = builder.addExecutable(.{
        .name = "flatzz-test-producer",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("tests/test_interop_producer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = test_imports,
        }),
    });
    const run_producer = builder.addRunArtifact(producer);
    check_step.dependOn(&producer.step);
    const fixture_output = builder.option(
        []const u8,
        "fixture-output",
        "Output directory for interoperability fixtures",
    ) orelse "tests";
    run_producer.setCwd(.{ .cwd_relative = fixture_output });
    builder.step(
        "test-produce-fixtures",
        "Generate Zig buffers for the interoperability harness",
    ).dependOn(&run_producer.step);
    const failures = .{
        .{ "read_only", "mutation requires a MutableTable" },
        .{ "immutable_input", "expected type '[]u8', found '[]const u8'" },
        .{ "unsupported_scalar", "unsupported FlatBuffers scalar type" },
        .{ "duplicate_ids", "duplicate schema wire field ID" },
        .{ "inconsistent_type", "schema descriptor value type mismatch" },
        .{ "optional_default", "optional scalars must default to null" },
        .{ "invalid_codec", "invalid sequence element layout" },
        .{ "struct_offset", "invalid FlatBuffers struct member offset" },
        .{ "struct_layout", "invalid FlatBuffers struct size or alignment" },
        .{ "struct_type", "struct descriptor value type mismatch" },
        .{ "struct_optional", "unsupported FlatBuffers scalar type" },
        .{ "struct_read_only", "mutation requires a mutable struct" },
        .{ "array_length", "array length must be positive and fit in u16" },
        .{ "array_overflow", "array length must be positive and fit in u16" },
        .{ "array_type", "struct descriptor value type mismatch" },
        .{ "array_read_only", "mutation requires a mutable array" },
        .{ "struct_vector_read_only", "mutation requires a mutable struct" },
        .{ "array_vector", "struct vectors require a struct layout" },
        .{ "array_nested", "direct nested arrays are unsupported" },
        .{ "array_table", "table struct fields require a struct layout" },
        .{ "union_duplicate_ids", "duplicate schema wire field ID" },
        .{ "union_adjacent_ids", "union value ID must immediately follow tag ID" },
        .{ "union_tag_width", "union tags require an exhaustive u8 enum" },
        .{ "union_none_tag", "union tags require none = 0" },
        .{ "union_none_payload", "only the none tag may omit a payload" },
        .{ "union_read_only", "mutation requires a MutableTable" },
        .{ "union_vector_read_only", "mutation requires a mutable struct" },
        .{ "union_replacement", "union replacement requires rebuilding; mutate borrowed payload fields" },
        .{ "storage_unknown", "unknown storage capacity field: missing" },
        .{ "storage_fixed", "fixed-size fields do not accept storage capacities: value" },
        .{ "storage_overflow", "storage capacity exceeds Builder.max_buffer_size" },
        .{ "storage_count", "storage element count must fit in u32" },
        .{ "borrow_scalar", "borrowMutable requires a structured field; use update for scalars and strings" },
        .{ "borrow_string", "borrowMutable requires a structured field; use update for scalars and strings" },
        .{ "borrow_read_only", "expected type 'runtime.table_view.TableView(.mutable)', found 'runtime.table_view.TableView(.read_only)'" },
    };
    inline for (failures) |failure| {
        const rejected = builder.addTest(.{ .root_module = builder.createModule(.{
            .root_source_file = builder.path(
                "tests/compile_fail/test_" ++ failure[0] ++ ".zig",
            ),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime", .module = runtime_module }},
        }) });
        rejected.expect_errors = .{ .contains = failure[1] };
        test_step.dependOn(&rejected.step);
        check_step.dependOn(&rejected.step);
    }

    const format = builder.addFmt(.{
        .paths = builder.pathList(&.{ "build.zig", "build.zig.zon", "src", "tests" }),
        .check = true,
    });
    builder.step("fmt", "Check Zig source formatting").dependOn(&format.step);
}
