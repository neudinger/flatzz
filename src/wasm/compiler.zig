//! Freestanding compiler ABI v1. See docs/wasm.md for format and status identifiers.
//! Inputs live in the exported staging buffer. FBS conversion selects an entry filename
//! from the copied source map; BFBS conversion consumes raw binary input instead.
//! Output and diagnostics borrow Wasm memory until reset, addFile, or convert is called.
//! Compilation uses bounded scratch allocation; it does not serialize application values.
const std = @import("std");
const compiler = @import("flatzz_compiler");
const codegen = @import("codegen");
const Sources = @import("Sources.zig");
const limits = @import("limits.zig");

const Input = enum(u32) { fbs = 0, bfbs = 1 };
const Output = enum(u32) { zig = 0, json = 1, bfbs = 2 };
const Status = enum(u32) {
    success = 0,
    invalid_request = 1,
    invalid_schema = 2,
    unsupported_feature = 3,
    resource_limit = 4,
};

const limits_json = std.fmt.comptimePrint(
    "{{\"input_bytes\":{d},\"source_bytes\":{d},\"workspace_bytes\":{d}," ++
        "\"files\":{d},\"path_bytes\":{d},\"depth\":{d},\"objects\":{d},\"work_bytes\":{d}}}",
    .{
        limits.input_capacity, limits.source_capacity, limits.workspace_capacity,
        limits.max_files,      limits.max_path,        limits.max_depth,
        limits.max_objects,    limits.max_work,
    },
);

var input_buffer: [limits.input_capacity]u8 = undefined;
var workspace: [limits.workspace_capacity]u8 align(16) = undefined;
var sources: Sources = .{};
var diagnostic_buffer: [16 * 1024]u8 = undefined;
var output: []const u8 = "";
var diagnostic_output: []const u8 = "{}";

export fn abiVersion() u32 {
    return 1;
}

export fn inputPointer() usize {
    return @intFromPtr(&input_buffer);
}

export fn inputCapacity() usize {
    return input_buffer.len;
}

export fn outputPointer() usize {
    return @intFromPtr(output.ptr);
}

export fn outputLength() usize {
    return output.len;
}

export fn diagnosticPointer() usize {
    return @intFromPtr(diagnostic_output.ptr);
}

export fn diagnosticLength() usize {
    return diagnostic_output.len;
}

export fn limitsPointer() usize {
    return @intFromPtr(limits_json.ptr);
}

export fn limitsLength() usize {
    return limits_json.len;
}

/// Discard all files and borrowed results before starting an independent request.
export fn reset() void {
    sources.reset();
    clearResult();
}

/// Copy a filename followed by UTF-8 FBS text from input into the request's source map.
/// Names are normalized; duplicates and paths escaping the virtual project are rejected.
export fn addFile(name_length: usize, text_length: usize) u32 {
    clearResult();
    if (name_length > input_buffer.len or text_length > input_buffer.len - name_length)
        return report(error.InputTooLarge, .{});
    sources.add(
        input_buffer[0..name_length],
        input_buffer[name_length..][0..text_length],
    ) catch |failure| return report(failure, .{});
    return @backingInt(Status.success);
}

/// FBS input is a UTF-8 entry filename; BFBS input is the complete ordinary BFBS frame.
/// Output is raw Zig, schema JSON, or BFBS. BFBS-to-BFBS is not a conversion.
/// Every attempt clears previous results and starts fresh compiler scratch storage.
export fn convert(input_format: u32, output_format: u32, input_length: usize) u32 {
    clearResult();
    if (input_length > input_buffer.len) return report(error.InputTooLarge, .{});
    const input_kind = std.enums.fromInt(Input, input_format) orelse
        return report(error.InvalidFormat, .{});
    const output_kind = std.enums.fromInt(Output, output_format) orelse
        return report(error.InvalidFormat, .{});
    if (input_kind == .bfbs and output_kind == .bfbs)
        return report(error.InvalidFormat, .{});
    var scratch = std.heap.FixedBufferAllocator.init(&workspace);
    const allocator = scratch.allocator();
    var diagnostic: compiler.parser.Diagnostic = .{};
    compile(
        allocator,
        input_kind,
        output_kind,
        input_buffer[0..input_length],
        &diagnostic,
    ) catch |failure| return report(failure, diagnostic);
    return @backingInt(Status.success);
}

fn compile(
    allocator: std.mem.Allocator,
    input_kind: Input,
    output_kind: Output,
    input: []const u8,
    diagnostic: *compiler.parser.Diagnostic,
) !void {
    const schema = switch (input_kind) {
        .fbs => fbs_blk: {
            const entry = try sources.get(input);
            break :fbs_blk try compiler.parser.parseWithOptions(allocator, entry.text, .{
                .filename = entry.name,
                .include_loader = Sources.load,
                .include_context = &sources,
                .diagnostic = diagnostic,
                .max_depth = limits.max_depth,
            });
        },
        .bfbs => try compiler.bfbs.decodeWithOptions(allocator, input, .{
            .max_depth = limits.max_depth,
            .max_objects = limits.max_objects,
            .max_work = limits.max_work,
        }),
    };
    output = switch (output_kind) {
        .zig => try codegen.generate(allocator, schema),
        .bfbs => try compiler.bfbs.encode(allocator, schema),
        .json => json_blk: {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            var json: std.json.Stringify = .{
                .writer = &writer.writer,
                .options = .{ .whitespace = .indent_2 },
            };
            // This writer fails only when its bounded allocator cannot grow.
            compiler.json.write(schema, &json) catch return error.OutOfMemory;
            writer.writer.writeByte('\n') catch return error.OutOfMemory;
            break :json_blk writer.written();
        },
    };
}

fn clearResult() void {
    output = "";
    diagnostic_output = "{}";
}

fn report(failure: anyerror, diagnostic: compiler.parser.Diagnostic) u32 {
    output = "";
    const status: Status = switch (failure) {
        error.InputTooLarge,
        error.SourceLimitExceeded,
        error.TooManySources,
        error.PathTooLong,
        error.OutOfMemory,
        error.DepthLimitExceeded,
        error.DepthLimit,
        error.ObjectLimit,
        error.WorkLimit,
        => .resource_limit,
        error.InvalidFormat,
        error.InvalidPath,
        error.InvalidUtf8,
        error.DuplicateSource,
        => .invalid_request,
        error.UnsupportedFeature => .unsupported_feature,
        else => .invalid_schema,
    };
    const message = if (diagnostic.message.len != 0) diagnostic.message else @errorName(failure);
    var writer = std.Io.Writer.fixed(&diagnostic_buffer);
    std.json.Stringify.value(.{
        .status = @backingInt(status),
        .code = @errorName(failure),
        .message = boundedMessage(message),
        .filename = diagnostic.filename,
        .line = diagnostic.line,
        .column = diagnostic.column,
    }, .{}, &writer) catch {
        diagnostic_output =
            "{\"status\":4,\"code\":\"DiagnosticTooLarge\",\"message\":\"DiagnosticTooLarge\"," ++
            "\"filename\":\"\",\"line\":0,\"column\":0}";
        return @backingInt(Status.resource_limit);
    };
    diagnostic_output = writer.buffered();
    return @backingInt(status);
}

fn boundedMessage(message: []const u8) []const u8 {
    var length = @min(message.len, 1024);
    while (length < message.len and length != 0 and message[length] & 0xc0 == 0x80)
        length -= 1;
    return message[0..length];
}
