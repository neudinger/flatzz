const runtime = @import("runtime");
const Codec = struct {
    pub const Value = u32;
    pub const slot_size = 4;
    pub const slot_alignment = 3;
};
comptime {
    _ = runtime.Vector(Codec);
}
