const runtime = @import("runtime");
comptime {
    _ = runtime.ScalarField(?u32, 0, 1);
}
