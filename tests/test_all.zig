//! Runtime-only test entry point; schema compiler tests are separate.
const std = @import("std");
const runtime = @import("runtime");
const reading = @import("reading");
const sequence_tests = @import("test_sequence.zig");
const runtime_tests = @import("test_runtime.zig");
const schema_scale_tests = @import("test_schema_scale.zig");
const schema_helper_tests = @import("test_schema_helpers.zig");
const required_field_tests = @import("test_required_fields.zig");
const framing_tests = @import("test_framing.zig");
const struct_tests = @import("test_struct.zig");
const array_tests = @import("test_array.zig");
const union_tests = @import("test_union.zig");

const testing = std.testing;

test {
    testing.refAllDecls(runtime);
    testing.refAllDecls(reading);
    testing.refAllDecls(sequence_tests);
    testing.refAllDecls(runtime_tests);
    testing.refAllDecls(schema_scale_tests);
    testing.refAllDecls(schema_helper_tests);
    testing.refAllDecls(required_field_tests);
    testing.refAllDecls(framing_tests);
    testing.refAllDecls(struct_tests);
    testing.refAllDecls(array_tests);
    testing.refAllDecls(union_tests);
}

test "runtime exports no schema compiler API" {
    inline for (.{ "parser", "reflection", "bfbs" }) |name|
        try testing.expect(!@hasDecl(runtime, name));
}
