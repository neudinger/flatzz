//! Shared module wiring for the native tool and freestanding Wasm compiler.
const std = @import("std");

const CompilerModules = @This();

runtime: *std.Build.Module,
compiler: *std.Build.Module,
codegen: *std.Build.Module,

pub fn init(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?CompilerModules {
    const zast = builder.lazyDependency("zast", .{
        .target = target,
        .optimize = optimize,
    }) orelse return null;
    const runtime = builder.createModule(.{
        .root_source_file = builder.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compiler = builder.createModule(.{
        .root_source_file = builder.path("src/compiler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flatzz", .module = runtime }},
    });
    const codegen = builder.createModule(.{
        .root_source_file = builder.path("src/compiler/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flatzz", .module = runtime },
            .{ .name = "flatzz_compiler", .module = compiler },
            .{ .name = "zast", .module = zast.module("zast") },
        },
    });
    return .{ .runtime = runtime, .compiler = compiler, .codegen = codegen };
}
