const runtime = @import("runtime");
const Values = struct { first: u32, second: u32 };
comptime {
    _ = runtime.Schema(Values, .{
        .first = runtime.ScalarField(u32, 0, 0),
        .second = runtime.ScalarField(u32, 0, 0),
    }).View;
}
