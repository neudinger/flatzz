//! Runtime-only test entry point; schema compiler tests are separate.
const std = @import("std");

test {
    std.testing.refAllDecls(@import("runtime"));
    std.testing.refAllDecls(@import("reading"));
    std.testing.refAllDecls(@import("test_sequence.zig"));
    std.testing.refAllDecls(@import("test_runtime.zig"));
    std.testing.refAllDecls(@import("test_schema_scale.zig"));
    std.testing.refAllDecls(@import("test_schema_helpers.zig"));
    std.testing.refAllDecls(@import("test_required_fields.zig"));
    std.testing.refAllDecls(@import("test_framing.zig"));
    std.testing.refAllDecls(@import("test_struct.zig"));
    std.testing.refAllDecls(@import("test_array.zig"));
    std.testing.refAllDecls(@import("test_union.zig"));
}

test "runtime exports no schema compiler API" {
    inline for (.{ "parser", "reflection", "bfbs" }) |name|
        try std.testing.expect(!@hasDecl(@import("runtime"), name));
}
