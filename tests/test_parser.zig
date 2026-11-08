//! Native FBS parser tests through the public compiler module.
const std = @import("std");
const compiler = @import("flatzz_compiler");

const parser = compiler.parser;
const reflection = compiler.reflection;
const Allocator = std.mem.Allocator;
const BaseType = reflection.BaseType;
const Diagnostic = parser.Diagnostic;
const Source = parser.Source;
const parse = parser.parse;
const parseWithOptions = parser.parseWithOptions;

const attribute_diagnostics = [_]struct {
    source: []const u8,
    line: usize,
    column: usize,
    message: []const u8,
}{
    .{
        .source = "table Message {\n    label:string (required, required:);\n}",
        .line = 2,
        .column = 29,
        .message = "duplicate attribute 'required'",
    },
    .{
        .source = "table Message {\n    label:string (force_align:);\n}",
        .line = 2,
        .column = 31,
        .message = "expected a literal or enum value",
    },
    .{
        .source = "table Message (required:true) {}",
        .line = 1,
        .column = 16,
        .message = "'required' is a field attribute",
    },
    .{
        .source = "attribute \"force_align\"\ntable Message {}",
        .line = 1,
        .column = 1,
        .message = "cannot redeclare built-in attribute 'force_align'",
    },
    .{
        .source = "table Message {\n    label:string (custom_flag);\n}",
        .line = 2,
        .column = 19,
        .message = "attribute 'custom_flag' must be declared first",
    },
};

const frontend_diagnostics = [_]struct {
    source: []const u8,
    line: usize,
    column: usize,
    message: []const u8,
}{
    .{
        .source = "table Root {\n  value:float = 1e40;\n}",
        .line = 2,
        .column = 17,
        .message = "default is outside float32 range",
    },
    .{
        .source = "table Root {\n  value:float = \"1_0\";\n}",
        .line = 2,
        .column = 17,
        .message = "invalid floating-point default",
    },
    .{
        .source = "enum Mode:byte { One=1 }\ntable Root { value:Mode = null (key); }",
        .line = 2,
        .column = 27,
        .message = "a key cannot be an optional scalar",
    },
    .{
        .source = "enum Mode:byte { One=1 } enum Other:byte { One=1 }\n" ++
            "table Root { value:Mode = Other.Missing; }",
        .line = 2,
        .column = 27,
        .message = "default names a different enum",
    },
    .{
        .source = "enum Mode:byte { One=1 }\ntable Root { value:Mode = Missing; }",
        .line = 2,
        .column = 27,
        .message = "unknown enum value 'Missing'",
    },
    .{
        .source = "enum Mode:byte { One=1 }\ntable Root { value:Mode; }",
        .line = 2,
        .column = 14,
        .message = "enum default must be a declared enum value",
    },
    .{
        .source = "namespace Types; table Item {}\n" ++
            "union Payload { Types.Item, Types_Item:Types.Item=0 }",
        .line = 2,
        .column = 29,
        .message = "duplicate enum/union member 'Types_Item'",
    },
    .{
        .source = "union Payload { Types.Alias:string }",
        .line = 1,
        .column = 17,
        .message = "a union alias must be an unqualified identifier",
    },
    .{
        .source = "table Item {} union Payload { First:Item=3, Second:Item=2 }",
        .line = 1,
        .column = 45,
        .message = "enum values must be strictly increasing",
    },
};

const malformed_schema_sources = [_][]const u8{
    "table T { x:Missing; }",
    "struct S { self:S; }",
    "struct S { text:string; }",
    "table T { x:int (required); }",
    "table T { x:byte = 128; }",
    "table T { x:long = -9223372036854775809; }",
    "table T { x:ulong = 18446744073709551616; }",
    "table T { x:int (id:0); y:int; }",
    "table T { x:int (id:1); }",
    "table T { x:int (id:18446744073709551615); }",
    "table T { x:int (id); }",
    "table T { x:int (required:true); }",
    "table T { x:int (deprecated:false); }",
    "table T { x:int (key:true); }",
    "struct S { x:[int:0]; }",
    "struct S { x:[int:-1]; }",
    "struct S { x:[int:65536]; }",
    "table T { x:[int:3]; }",
    "struct S { x:int; } root_type S;",
    "union U { string }",
    "table Item {} union U { Item } table T { u:U; u_type:int; }",
    "enum E:byte { A=1 } table T { x:E; }",
    "table T {} file_identifier \"LONGER\";",
    "table T {} file_identifier \"ABC\";",
    "table T { x:int }",
};

// Run `zig build test` from Flatzz.
test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\namespace Demo;
        \\enum Status:ubyte { Unknown, Ready }
        \\struct Point { x:float; y:float; }
        \\struct Batch { points:[Point:2]; flags:[bool:3]; }
        \\table Event { status:Status = Ready; }
        \\union Payload { Event, Position:Point, Text:string }
        \\table Root { current:Payload; history:[Payload]; temperature:float = null; batch:Batch; }
        \\root_type Root;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqualStrings("Demo.Root", root.name);
    const batch = try testObject(schema, "Demo.Batch");
    try std.testing.expectEqual(@as(i32, 20), batch.bytesize);
    try std.testing.expectEqual(@as(i32, 4), batch.minalign);
    try std.testing.expectEqual(@as(u16, 16), (try testField(batch, "flags")).offset);
    try std.testing.expectEqual(@as(u16, 0), (try testField(root, "current_type")).id);
    try std.testing.expectEqual(@as(u16, 1), (try testField(root, "current")).id);
    try std.testing.expectEqual(@as(u16, 2), (try testField(root, "history_type")).id);
    try std.testing.expectEqual(@as(u16, 3), (try testField(root, "history")).id);
    try std.testing.expectEqual(
        BaseType.UType,
        (try testField(root, "current_type")).type.base_type,
    );
    try std.testing.expectEqual(BaseType.UType, (try testField(root, "history_type")).type.element);
    try std.testing.expect((try testField(root, "temperature")).optional);
    try std.testing.expectEqual(@as(u64, 7), @as(u64, @bitCast(schema.advanced_features)));
    try std.testing.expectEqual(
        @as(i64, 1),
        (try testField(try testObject(schema, "Demo.Event"), "status")).default_integer,
    );
}

test "nested namespace lookup retains nearest parent global and qualified references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\table Global {}
        \\namespace Parent;
        \\table Shared {}
        \\table Ancestor {}
        \\namespace Parent.Child;
        \\table Shared {}
        \\table Reading {
        \\    nearest:Shared;
        \\    parent:Ancestor;
        \\    global:Global;
        \\    qualified:Parent.Shared;
        \\}
        \\root_type Reading;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqualStrings("Parent.Child.Reading", root.name);
    const nearest = try testField(root, "nearest");
    const ancestor = try testField(root, "parent");
    const global = try testField(root, "global");
    const qualified = try testField(root, "qualified");
    try std.testing.expectEqualStrings(
        "Parent.Child.Shared",
        schema.objects[@intCast(nearest.type.index)].name,
    );
    try std.testing.expectEqualStrings(
        "Parent.Ancestor",
        schema.objects[@intCast(ancestor.type.index)].name,
    );
    try std.testing.expectEqualStrings("Global", schema.objects[@intCast(global.type.index)].name);
    try std.testing.expectEqualStrings(
        "Parent.Shared",
        schema.objects[@intCast(qualified.type.index)].name,
    );
}

test "wire padding survives sorting, explicit IDs include union discriminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\struct Padded { z:ubyte; a:ulong; m:ushort; }
        \\table Item { next:Item; }
        \\union Choice { Item }
        \\table Root { choice:Choice (id:2); value:Padded (id:0); }
        \\root_type Root;
    );
    const padded = try testObject(schema, "Padded");
    try std.testing.expectEqualStrings("a", padded.fields[0].name);
    try std.testing.expectEqual(@as(u16, 1), padded.fields[0].id);
    try std.testing.expectEqual(@as(u16, 8), padded.fields[0].offset);
    try std.testing.expectEqual(@as(u16, 7), (try testField(padded, "z")).padding);
    try std.testing.expectEqual(@as(u16, 6), (try testField(padded, "m")).padding);
    try std.testing.expectEqual(@as(i32, 24), padded.bytesize);
    const root = schema.root_table.?;
    try std.testing.expectEqual(@as(u16, 0), (try testField(root, "value")).id);
    try std.testing.expectEqual(@as(u16, 1), (try testField(root, "choice_type")).id);
    try std.testing.expectEqual(@as(u16, 8), (try testField(root, "choice")).offset);
}

test "defaults preserve signed and unsigned limits and floating literal metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\enum Wide:ulong { Zero=0, Max=18446744073709551615 }
        \\table T {
        \\    low:long = -9223372036854775808;
        \\    high:ulong = 18446744073709551615;
        \\    wide:Wide = "Wide.Max";
        \\    fraction:float = "0.1";
        \\    flag:bool = "true";
        \\    optional:int = "null";
        \\}
        \\root_type T;
    );
    const root = schema.root_table.?;
    try std.testing.expectEqual(std.math.minInt(i64), (try testField(root, "low")).default_integer);
    try std.testing.expectEqual(@as(i64, -1), (try testField(root, "high")).default_integer);
    try std.testing.expectEqual(@as(i64, -1), (try testField(root, "wide")).default_integer);
    try std.testing.expectEqual(@as(f64, 0.1), (try testField(root, "fraction")).default_real);
    try std.testing.expectEqual(@as(i64, 1), (try testField(root, "flag")).default_integer);
    try std.testing.expect((try testField(root, "optional")).optional);
}

test "optional enum and floating defaults preserve metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\namespace Sample;
        \\enum Mode:byte { Low=-1, High=1 }
        \\table Root {
        \\    optional:Mode=null;
        \\    signed:Mode=Sample.Mode.Low;
        \\    positive:float=inf;
        \\    negative:float=-inf;
        \\    nan_value:float=nan;
        \\}
        \\root_type Root;
    );
    const root = schema.root_table.?;
    try std.testing.expect((try testField(root, "optional")).optional);
    try std.testing.expect(schema.advanced_features.optional_scalars);
    try std.testing.expectEqual(@as(i64, -1), (try testField(root, "signed")).default_integer);
    try std.testing.expectEqual(std.math.inf(f64), (try testField(root, "positive")).default_real);
    try std.testing.expectEqual(-std.math.inf(f64), (try testField(root, "negative")).default_real);
    try std.testing.expect(std.math.isNan((try testField(root, "nan_value")).default_real));
}

test "union names and aliases retain payloads and sparse tag order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\namespace Types;
        \\table Item {}
        \\struct Point { value:int; }
        \\namespace Sample;
        \\union Payload { Types.Item=3, Alias:Types.Item, Position:Types.Point=7, Text:string }
    );
    const payload = schema.enums[0];
    try std.testing.expectEqualStrings("Sample.Payload", payload.name);
    try std.testing.expect(payload.is_union);
    const names = [_][]const u8{ "NONE", "Types_Item", "Alias", "Position", "Text" };
    const tags = [_]i64{ 0, 3, 4, 7, 8 };
    try std.testing.expectEqual(names.len, payload.values.len);
    for (payload.values, names, tags) |member, name, tag| {
        try std.testing.expectEqualStrings(name, member.name);
        try std.testing.expectEqual(tag, member.value);
    }
    try std.testing.expectEqual(BaseType.None, payload.values[0].union_type.?.base_type);
    const object_names = [_][]const u8{ "Types.Item", "Types.Item", "Types.Point" };
    for (payload.values[1..4], object_names) |member, name| {
        const reference = member.union_type.?;
        try std.testing.expectEqual(BaseType.Obj, reference.base_type);
        try std.testing.expectEqualStrings(name, schema.objects[@intCast(reference.index)].name);
    }
    try std.testing.expectEqual(BaseType.String, payload.values[4].union_type.?.base_type);
    try std.testing.expect(schema.advanced_features.advanced_union_features);
}

test "frontend semantics preserve diagnostic positions and validation order" {
    for (frontend_diagnostics) |expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidSchema, parseWithOptions(
            arena.allocator(),
            expected.source,
            .{ .filename = "frontend.fbs", .diagnostic = &diagnostic },
        ));
        try std.testing.expectEqualStrings("frontend.fbs", diagnostic.filename);
        try std.testing.expectEqual(expected.line, diagnostic.line);
        try std.testing.expectEqual(expected.column, diagnostic.column);
        try std.testing.expectEqualStrings(expected.message, diagnostic.message);
    }
}

test parseWithOptions {
    const loader = struct {
        fn load(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            requested: []const u8,
        ) anyerror!Source {
            if (!std.mem.endsWith(u8, requested, "shared.fbs")) return error.NotFound;
            return .{
                .name = "shared.fbs",
                .text = "namespace Shared; table Item {} root_type Item; file_identifier \"SHRD\";",
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parseWithOptions(arena.allocator(),
        \\include "shared.fbs";
        \\include "./shared.fbs";
        \\table Root { value:Shared.Item; }
        \\root_type Root;
    , .{ .include_loader = loader.load });
    try std.testing.expectEqual(@as(usize, 2), schema.objects.len);
    try std.testing.expectEqualStrings("Root", schema.root_table.?.name);
    try std.testing.expectEqual(@as(?[]const u8, null), schema.file_ident);
    const item = try testField(schema.root_table.?, "value");
    try std.testing.expectEqualStrings(
        "Shared.Item",
        schema.objects[@intCast(item.type.index)].name,
    );
}

test "source ownership and error diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = "table Owned { value:uint; } root_type Owned;".*;
    const schema = try parse(arena.allocator(), &source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("Owned", schema.root_table.?.name);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSchema, parseWithOptions(
        arena.allocator(),
        "table T {\nvalue:Missing;\n}",
        .{ .filename = "bad.fbs", .diagnostic = &diagnostic },
    ));
    try std.testing.expectEqualStrings("bad.fbs", diagnostic.filename);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expect(diagnostic.message.len != 0);
}

test "attribute classification preserves validation order and diagnostics" {
    for (attribute_diagnostics) |expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidSchema, parseWithOptions(
            arena.allocator(),
            expected.source,
            .{ .filename = "attributes.fbs", .diagnostic = &diagnostic },
        ));
        try std.testing.expectEqualStrings("attributes.fbs", diagnostic.filename);
        try std.testing.expectEqual(expected.line, diagnostic.line);
        try std.testing.expectEqual(expected.column, diagnostic.column);
        try std.testing.expectEqualStrings(expected.message, diagnostic.message);
    }
}

test "malformed schemas fail without accepting incomplete metadata" {
    for (malformed_schema_sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidSchema, parse(arena.allocator(), source));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedFeature,
        parse(arena.allocator(), "struct S (force_align:16) { x:int; }"),
    );
    try std.testing.expectError(
        error.IncludeNotFound,
        parse(arena.allocator(), "include \"missing.fbs\";"),
    );
    try std.testing.expectError(
        error.DepthLimitExceeded,
        parseWithOptions(
            arena.allocator(),
            "struct A { b:B; } struct B { x:int; }",
            .{ .max_depth = 1 },
        ),
    );
}

test "fixed arrays accept the maximum wire length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(),
        \\struct Bytes { data:[ubyte:65535]; }
        \\table Root { bytes:Bytes; }
        \\root_type Root;
        \\file_identifier "TEST";
    );
    const bytes = try testObject(schema, "Bytes");
    try std.testing.expectEqual(@as(u16, 65535), (try testField(bytes, "data")).type.fixed_length);
    try std.testing.expectEqual(@as(i32, 65535), bytes.bytesize);
    try std.testing.expectEqualStrings("TEST", schema.file_ident.?);
}

fn testObject(schema: reflection.Schema, name: []const u8) !*const reflection.Object {
    for (schema.objects) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.TestObjectNotFound;
}
fn testField(object: *const reflection.Object, name: []const u8) !*const reflection.Field {
    for (object.fields) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.TestFieldNotFound;
}
