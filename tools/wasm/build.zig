//! Build the reusable compiler with no entry point, WASI, or JavaScript host imports.
const std = @import("std");
const CompilerModules = @import("../CompilerModules.zig");

/// Root builds expose an explicit wasm step; opted-in dependencies export the artifact.
/// JavaScript adapters and browser parity tests belong to the consuming site.
pub fn add(builder: *std.Build) void {
    const target = builder.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const modules = CompilerModules.init(builder, target, .ReleaseSafe) orelse return;
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/wasm/compiler.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "flatzz_compiler", .module = modules.compiler },
            .{ .name = "codegen", .module = modules.codegen },
        },
    });
    module.export_symbol_names = &.{
        "abiVersion",   "inputPointer",      "inputCapacity",    "outputPointer",
        "outputLength", "diagnosticPointer", "diagnosticLength", "limitsPointer",
        "limitsLength", "reset",             "addFile",          "convert",
    };
    const executable = builder.addExecutable(.{
        .name = "flatzz-compiler-wasm",
        .root_module = module,
    });
    executable.entry = .disabled;
    executable.export_memory = true;
    executable.stack_size = 1024 * 1024;
    executable.max_memory = 64 * 1024 * 1024;
    const install = builder.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
        .dest_sub_path = "flatzz-compiler.wasm",
    });
    // Dependency.artifact discovers installed artifacts. Root builds install Wasm
    // only through the explicit command; their default native install is unchanged.
    if (!builder.isRoot()) builder.getInstallStep().dependOn(&install.step);
    builder.step("wasm", "Install the freestanding Wasm compiler")
        .dependOn(&install.step);
}
