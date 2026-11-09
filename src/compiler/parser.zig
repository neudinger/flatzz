//! Native FBS frontend for Flatzz reflection metadata (Zig 0.17.0).
//!
//! Use a caller-owned arena for referenced metadata, diagnostic strings, and parsing
//! temporaries. Retain it for all schema consumers and destroy it on success or
//! failure. The parser copies input text, so the original source may be released.
//! Parser/compiler state stores no allocator: allocating operations receive it
//! explicitly. Use the same allocator throughout a parse, including callbacks.
//!
//! Supports namespaces, includes through a callback, tables, naturally aligned
//! structs, scalar aliases, enums, unions/aliases, vectors, fixed arrays, scalar
//! defaults/null, explicit IDs, required/deprecated/key, custom attributes,
//! root_type and file_identifier/file_extension. No C, libc or BFBS is involved.
//! Unsupported built-in attributes and RPC declarations return UnsupportedFeature.
//! Comments are accepted but documentation comments are not retained.
//! Inline enum members may omit a zero variant, as the existing Flatzz fixtures
//! do. This is more permissive than flatc's enum-default validation for structs.
//!
//! Reflection arrays are sorted as flatc sorts them; IDs/layout retain declaration
//! semantics. See https://flatbuffers.dev/schema/ and reflection/reflection.fbs.
//! Includes do not trigger automatic filesystem access: the caller's loader supplies
//! canonical names and text. Parsing validates the supported FBS subset; it does not
//! generate Zig source or serialize application message values.
//!
//! From Flatzz, run `zig build test`.
//! Import `const compiler = @import("flatzz_compiler");`, then `const parser = compiler.parser;`.
//! Example inside a function with `std` and `parser` imported:
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//! defer arena.deinit();
//! const schema = try parser.parse(
//!     arena.allocator(),
//!     "table Reading { value:uint = 42; } root_type Reading;",
//! );
//! std.debug.print("{s}\n", .{schema.root_table.?.name});
//! ```
//! Expected output: `Reading` followed by a newline. The arena owns the schema.
//! The `flatzz_compiler` module overview provides a complete Zig 0.17.0 test runner.

const std = @import("std");
const reflection = @import("reflection.zig");
const Compiler = @import("fbs/Compilation.zig");

const Allocator = std.mem.Allocator;

/// Allocation, validation, supported-feature, include, and nesting failures.
pub const Error = error{
    /// The supplied allocator failed, including while formatting a diagnostic.
    OutOfMemory,
    /// Invalid syntax, unresolved names, or inconsistent schema metadata.
    InvalidSchema,
    /// A recognized declaration or attribute is outside this frontend's subset.
    UnsupportedFeature,
    /// No include loader was supplied, or the loader failed for a non-allocation reason.
    IncludeNotFound,
    /// Include or unresolved inline-struct nesting reached `Options.max_depth`.
    DepthLimitExceeded,
};

/// Borrowed include-loader output; the parser copies it before parsing a new source.
pub const Source = struct {
    /// Canonical source identity used for include deduplication and diagnostics.
    name: []const u8,
    /// Complete FBS text, valid until the parser has copied this source.
    text: []const u8,
};

/// First reported failure, cleared by `parseWithOptions` before parsing starts.
pub const Diagnostic = struct {
    /// Copied source name, with the supplied allocator's lifetime.
    filename: []const u8 = "",
    /// One-based source line; zero means no diagnostic was emitted.
    line: usize = 0,
    /// One-based byte column, rather than a Unicode character count.
    column: usize = 0,
    /// Allocated failure description; empty when no diagnostic was produced.
    message: []const u8 = "",
};

/// Resolve `requested` relative to the including source `from` and caller search paths.
/// Return a canonical `Source` using the supplied allocator or other stable storage.
/// OutOfMemory propagates; every other callback error becomes IncludeNotFound.
pub const IncludeLoader = *const fn (
    context: ?*anyopaque,
    allocator: Allocator,
    from: []const u8,
    requested: []const u8,
) anyerror!Source;

/// Source identity, caller-controlled include loading, diagnostics, and depth limits.
pub const Options = struct {
    /// Main source name, copied before parsing; also passed to include loaders as `from`.
    filename: []const u8 = "schema.fbs",
    /// Resolve relative to `from`, then your include paths. Return a canonical
    /// name for deduplication, and text valid until the parser copies it.
    include_loader: ?IncludeLoader = null,
    /// Opaque borrowed callback state; the parser neither owns nor interprets it.
    include_context: ?*anyopaque = null,
    /// Diagnostic strings have the same arena lifetime as the returned schema.
    diagnostic: ?*Diagnostic = null,
    /// Depth threshold for includes and unresolved inline layouts; zero rejects the main source.
    max_depth: usize = 64,
};

/// Parse an FBS schema using caller-owned storage. Use an arena or equivalent
/// bulk-lifetime allocator for output and temporaries; keep it alive until all
/// schema consumers finish, and release it after success or failure.
/// Syntax/name/layout failures return `InvalidSchema`; unsupported recognized
/// constructs return `UnsupportedFeature`. Includes require `parseWithOptions`
/// and a loader. See the module example for the complete allocation lifecycle.
pub fn parse(allocator: Allocator, source: []const u8) Error!reflection.Schema {
    return parseWithOptions(allocator, source, .{});
}

/// Like `parse`, with include loading, diagnostics and depth limits.
/// Returned schema data and diagnostic strings share the supplied allocator
/// lifetime. Input text and filenames are copied into that storage.
/// Diagnostics are cleared first and may describe the failure after an error;
/// there is no rollback of arena allocations. Loader `OutOfMemory` propagates,
/// while other loader errors become `IncludeNotFound`.
///
/// Inside a test with `std`, `compiler = @import("flatzz_compiler")`,
/// and `parser = compiler.parser` declared:
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
/// defer arena.deinit();
/// var diagnostic: parser.Diagnostic = .{};
/// try std.testing.expectError(error.InvalidSchema, parser.parseWithOptions(
///     arena.allocator(),
///     "table Reading { value:Missing; }",
///     .{ .filename = "bad.fbs", .diagnostic = &diagnostic },
/// ));
/// try std.testing.expectEqualStrings("bad.fbs", diagnostic.filename);
/// try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
/// ```
/// Expected result: `InvalidSchema` with a line-one diagnostic for `bad.fbs`;
/// no text is printed. The diagnostic strings remain valid until arena cleanup.
pub fn parseWithOptions(
    allocator: Allocator,
    source: []const u8,
    options: Options,
) Error!reflection.Schema {
    if (options.diagnostic) |diagnostic| diagnostic.* = .{};
    var compiler: Compiler = .{ .options = options };
    try compiler.load(allocator, .{ .name = options.filename, .text = source }, 0, true);
    return compiler.finish(allocator);
}
