//! Request-owned UTF-8 sources addressed by canonical, project-relative POSIX paths.
//! Paths cannot escape the project. No filesystem, fetch, or host callbacks are used.
const std = @import("std");
const compiler = @import("flatzz_compiler");
const limits = @import("limits.zig");

const Sources = @This();

entries: [limits.max_files]compiler.parser.Source = undefined,
storage: [limits.source_capacity]u8 = undefined,
count: usize = 0,
used: usize = 0,

pub fn reset(self: *Sources) void {
    self.count = 0;
    self.used = 0;
}

pub fn add(self: *Sources, name: []const u8, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(text))
        return error.InvalidUtf8;
    var path_buffer: [limits.max_path]u8 = undefined;
    const path = try canonicalize(&path_buffer, "", name);
    if (self.find(path) != null) return error.DuplicateSource;
    if (self.count == self.entries.len) return error.TooManySources;
    if (path.len > self.storage.len - self.used or
        text.len > self.storage.len - self.used - path.len) return error.SourceLimitExceeded;
    const owned_name = self.storage[self.used..][0..path.len];
    @memcpy(owned_name, path);
    self.used += path.len;
    const owned_text = self.storage[self.used..][0..text.len];
    @memcpy(owned_text, text);
    self.used += text.len;
    self.entries[self.count] = .{ .name = owned_name, .text = owned_text };
    self.count += 1;
}

pub fn get(self: *const Sources, name: []const u8) !compiler.parser.Source {
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    var path_buffer: [limits.max_path]u8 = undefined;
    return self.find(try canonicalize(&path_buffer, "", name)) orelse error.IncludeNotFound;
}

pub fn load(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    from: []const u8,
    requested: []const u8,
) anyerror!compiler.parser.Source {
    _ = allocator;
    const self: *const Sources = @ptrCast(@alignCast(context.?));
    const directory = if (std.mem.lastIndexOfScalar(u8, from, '/')) |index| from[0..index] else "";
    var path_buffer: [limits.max_path]u8 = undefined;
    const path = try canonicalize(&path_buffer, directory, requested);
    return self.find(path) orelse error.IncludeNotFound;
}

fn find(self: *const Sources, name: []const u8) ?compiler.parser.Source {
    for (self.entries[0..self.count]) |source| {
        if (std.mem.eql(u8, source.name, name)) return source;
    }
    return null;
}

fn canonicalize(buffer: []u8, directory: []const u8, requested: []const u8) ![]const u8 {
    if (requested.len == 0 or requested[0] == '/' or
        std.mem.indexOfAny(u8, requested, "\\\x00") != null) return error.InvalidPath;
    var used: usize = 0;
    for ([_][]const u8{ directory, requested }) |part| {
        var segments = std.mem.tokenizeScalar(u8, part, '/');
        while (segments.next()) |segment| {
            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (used == 0) return error.InvalidPath;
                used = std.mem.lastIndexOfScalar(u8, buffer[0..used], '/') orelse 0;
                continue;
            }
            const separator: usize = if (used == 0) 0 else 1;
            if (separator > buffer.len - used or
                segment.len > buffer.len - used - separator) return error.PathTooLong;
            if (separator != 0) {
                buffer[used] = '/';
                used += 1;
            }
            @memcpy(buffer[used..][0..segment.len], segment);
            used += segment.len;
        }
    }
    if (used == 0) return error.InvalidPath;
    return buffer[0..used];
}
