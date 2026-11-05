const runtime = @import("runtime");
test "mutable constructors require writable bytes" {
    const bytes: []const u8 = &.{};
    _ = try runtime.MutableTable.from(bytes, .root);
}
