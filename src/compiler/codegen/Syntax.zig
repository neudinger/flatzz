//! Scratch-backed construction of borrowed Zast expressions.
//! The caller owns the allocator and retains its storage through AST finalization.
//! Child descriptions and temporary argument/initializer lists are copied into that storage.
//! Copies are shallow: referenced names, literal spellings, and nested descriptions
//! must also survive finalization. This internal helper does not own or reset the arena.
const std = @import("std");
const zast = @import("zast");

const Self = @This();
const Expression = zast.Expression;

/// Borrowed scratch allocator shared with the enclosing Generator.
allocator: std.mem.Allocator,

/// Allocate a shallow copy of one description; referenced storage remains borrowed.
/// Allocation failure propagates; the caller's arena owns the resulting pointer.
pub fn store(self: Self, value: anytype) !*@TypeOf(value) {
    const result = try self.allocator.create(@TypeOf(value));
    result.* = value;
    return result;
}

/// Borrow a Zig identifier spelling without allocating, escaping, or validating it.
pub fn identifier(name: []const u8) Expression {
    return .{ .identifier = name };
}

/// Copy the base description into scratch storage and borrow the member spelling.
pub fn access(self: Self, base: Expression, name: []const u8) !Expression {
    return .{ .field_access = .{ .base = try self.store(base), .name = name } };
}

/// Copy the callee and argument list into scratch storage; nested payloads stay borrowed.
pub fn call(self: Self, callee: Expression, arguments: []const Expression) !Expression {
    return .{
        .call = .{
            .callee = try self.store(callee),
            .arguments = try self.allocator.dupe(Expression, arguments),
        },
    };
}

/// Copy an argument list and borrow a builtin spelling, including its leading `@`.
pub fn builtin(self: Self, name: []const u8, arguments: []const Expression) !Expression {
    return .{
        .builtin_call = .{
            .name = name,
            .arguments = try self.allocator.dupe(Expression, arguments),
        },
    };
}

/// Copy initializer fields into scratch storage and request a trailing comma.
/// Field names and referenced expression payloads remain borrowed.
pub fn record(self: Self, fields: []const Expression.InitializerField) !Expression {
    return .{
        .struct_init = .{
            .fields = try self.allocator.dupe(Expression.InitializerField, fields),
            .trailing_comma = true,
        },
    };
}

/// Store the child description for an optional type; no value is constructed.
pub fn optional(self: Self, child: Expression) !Expression {
    return .{ .optional_type = try self.store(child) };
}

/// Store the child description for a const slice type; no slice storage is allocated.
pub fn slice(self: Self, child: Expression) !Expression {
    return .{ .slice_type = .{ .child_type = try self.store(child), .is_const = true } };
}

/// Allocate decimal integer-literal text in scratch storage.
/// Callers supply integer values; generated-program validation belongs to the compiler.
pub fn number(self: Self, value: anytype) !Expression {
    return .{ .integer_literal = try self.allocator.print("{d}", .{value}) };
}
