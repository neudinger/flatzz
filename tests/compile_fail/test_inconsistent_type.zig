const runtime = @import("runtime");
const Values = struct { number: u32 };
comptime {
    _ = runtime.Schema(Values, .{
        .number = runtime.ScalarField(u64, 0, 0),
    }).View;
}
