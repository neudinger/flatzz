//! Scratch-backed construction of borrowed Zast expressions.
//! The caller owns the allocator and retains its storage through AST finalization.
//! Child descriptions and temporary argument/initializer lists are copied into that storage.
const std = @import("std");
const zast = @import("zast");

const Self = @This();
const Expression = zast.Expression;

allocator: std.mem.Allocator,

pub fn store(self: Self, value: anytype) !*@TypeOf(value) {
    const result = try self.allocator.create(@TypeOf(value));
    result.* = value;
    return result;
}

pub fn identifier(name: []const u8) Expression {
    return .{ .identifier = name };
}

pub fn access(self: Self, base: Expression, name: []const u8) !Expression {
    return .{ .field_access = .{ .base = try self.store(base), .name = name } };
}

pub fn call(self: Self, callee: Expression, arguments: []const Expression) !Expression {
    return .{
        .call = .{
            .callee = try self.store(callee),
            .arguments = try self.allocator.dupe(Expression, arguments),
        },
    };
}

pub fn builtin(self: Self, name: []const u8, arguments: []const Expression) !Expression {
    return .{
        .builtin_call = .{
            .name = name,
            .arguments = try self.allocator.dupe(Expression, arguments),
        },
    };
}

pub fn record(self: Self, fields: []const Expression.InitializerField) !Expression {
    return .{
        .struct_init = .{
            .fields = try self.allocator.dupe(Expression.InitializerField, fields),
            .trailing_comma = true,
        },
    };
}

pub fn optional(self: Self, child: Expression) !Expression {
    return .{ .optional_type = try self.store(child) };
}

pub fn slice(self: Self, child: Expression) !Expression {
    return .{ .slice_type = .{ .child_type = try self.store(child), .is_const = true } };
}

pub fn number(self: Self, value: anytype) !Expression {
    return .{ .integer_literal = try self.allocator.print("{d}", .{value}) };
}
