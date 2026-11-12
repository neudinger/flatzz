//! Refresh the Zast package pin from GitHub main using an exact commit URL.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 2) return error.ExpectedZigExecutable;

    const repository = "https://github.com/neudinger/zast";
    const branch = "refs/heads/main";
    const resolved = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-remote", "--exit-code", repository, branch },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    if (!resolved.term.success()) {
        std.debug.print("{s}", .{resolved.stderr});
        return error.ZastRefLookupFailed;
    }

    const line = std.mem.trimEnd(u8, resolved.stdout, "\r\n");
    const commit, const ref = std.mem.cutScalar(u8, line, '\t') orelse return error.InvalidZastRef;
    if (commit.len != 40 or !std.mem.eql(u8, ref, branch)) return error.InvalidZastRef;
    for (commit) |digit| if (!std.ascii.isHex(digit)) return error.InvalidZastRef;

    const url = try std.fmt.allocPrint(allocator, "git+{s}#{s}", .{ repository, commit });
    var fetch = try std.process.spawn(io, .{
        .argv = &.{ arguments[1], "fetch", "--save-exact=zast", url },
    });
    defer fetch.kill(io);
    if (!(try fetch.wait(io)).success()) return error.ZastFetchFailed;
}
