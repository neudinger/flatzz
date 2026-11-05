const runtime = @import("runtime");
comptime {
    _ = runtime.Vector(runtime.ScalarCodec(u128));
}
