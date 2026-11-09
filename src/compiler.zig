//! FlatBuffers schema parsing, reflection metadata, and BFBS conversion.
//!
//! Import this module with `const compiler = @import("flatzz_compiler");`.
//! `parser` produces `reflection.Schema` from FBS text; `bfbs` encodes and decodes
//! the same metadata model. These APIs run in applications or build tools without
//! Zast. Zig source generation uses a separate host backend with that dependency.
//!
//! ## Parse an FBS schema
//!
//! Save this complete example as `compiler_example_test.zig` beside `build.zig`:
//!
//! ```zig
//! const std = @import("std");
//! const compiler = @import("flatzz_compiler");
//!
//! test "parse a schema" {
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!     const schema: compiler.reflection.Schema = try compiler.parser.parse(
//!         arena.allocator(),
//!         "table Reading { value:uint = 42; } root_type Reading;",
//!     );
//!     const root = schema.root_table.?;
//!     try std.testing.expectEqualStrings("Reading", root.name);
//!     try std.testing.expectEqual(.UInt, root.fields[0].type.base_type);
//!     try std.testing.expectEqual(@as(u16, 0), root.fields[0].id);
//!     try std.testing.expectEqual(@as(i64, 42), root.fields[0].default_integer);
//! }
//! ```
//!
//! From the package root with Zig 0.17.0:
//!
//! ```sh
//! zig test --dep flatzz_compiler -Mroot=compiler_example_test.zig \
//!     --dep flatzz -Mflatzz_compiler=src/compiler.zig -Mflatzz=src/runtime.zig
//! ```
//!
//! Expected result: one passing test with no application output. The root is
//! `Reading`; `value` has physical field ID zero, type `.UInt`, and default `42`.
//! Input text and filenames are copied. Schema slices, referenced records, diagnostic
//! strings, and parsing temporaries use the supplied arena; retain it for every schema
//! consumer and release it after success or failure. Schemas without `root_type`
//! have a null `root_table`.
//!
//! ## Encode and decode BFBS
//!
//! Append this test to the same file, reusing its imports:
//!
//! ```zig
//! test "schema binary round trip" {
//!     const allocator = std.testing.allocator;
//!     var source_arena = std.heap.ArenaAllocator.init(allocator);
//!     defer source_arena.deinit();
//!     const schema = try compiler.parser.parse(
//!         source_arena.allocator(),
//!         "table Reading { value:uint = 42; } root_type Reading;",
//!     );
//!     const bytes = try compiler.bfbs.encode(allocator, schema);
//!     defer allocator.free(bytes);
//!
//!     var decoded_arena = std.heap.ArenaAllocator.init(allocator);
//!     defer decoded_arena.deinit();
//!     const decoded = try compiler.bfbs.decode(decoded_arena.allocator(), bytes);
//!     try std.testing.expectEqualStrings("BFBS", bytes[4..8]);
//!     try std.testing.expectEqualStrings("Reading", decoded.root_table.?.name);
//!     try std.testing.expectEqual(@as(i64, 42), decoded.root_table.?.fields[0].default_integer);
//!     try std.testing.expect(decoded.root_table.? == &decoded.objects[0]);
//! }
//! ```
//!
//! Expected result: a passing test with no application output. Encoding returns
//! an owned aligned allocation containing an ordinary frame with the `BFBS`
//! identifier. Free the returned slice once with the same allocator; its first
//! byte is the allocation base. Input metadata must remain valid throughout encoding.
//! Decoding copies metadata into its arena and preserves shared Object references;
//! the decoded schema borrows neither the encoded bytes nor the source schema.
//! Release the decoding arena on success or failure, after its consumers finish.
//!
//! ## Diagnostics and validation limits
//!
//! Append this test to the same file:
//!
//! ```zig
//! test "schema diagnostic" {
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!     var diagnostic: compiler.parser.Diagnostic = .{};
//!     try std.testing.expectError(error.InvalidSchema, compiler.parser.parseWithOptions(
//!         arena.allocator(),
//!         "table Reading { value:Missing; }",
//!         .{ .filename = "bad.fbs", .diagnostic = &diagnostic },
//!     ));
//!     try std.testing.expectEqualStrings("bad.fbs", diagnostic.filename);
//!     try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
//!     try std.testing.expect(diagnostic.message.len > 0);
//! }
//! ```
//!
//! Expected result: a passing test observing `error.InvalidSchema` and a line-one
//! diagnostic for `bad.fbs`; no application output. `parseWithOptions` clears the
//! diagnostic before parsing. Its strings remain valid until arena cleanup;
//! an error does not roll back arena allocations.
//!
//! `parser.parseWithOptions` also accepts an include-loader callback and a depth
//! limit for includes and unresolved inline struct layouts. Includes are loaded
//! only through that callback; missing loaders and non-allocation loader failures
//! return `error.IncludeNotFound`. Exhausted nesting returns `error.DepthLimitExceeded`.
//! Unsupported recognized constructs return `error.UnsupportedFeature`; allocation
//! failure returns `error.OutOfMemory`.
//!
//! `bfbs.decode` uses ordinary framing and default traversal limits. Select size
//! prefixes and depth, object, or work budgets with `bfbs.decodeWithOptions`.
//! Malformed wire data returns `error.InvalidBfbs`; exhausted budgets return
//! `error.DepthLimit`, `error.ObjectLimit`, or `error.WorkLimit`. Wire validation
//! does not establish FBS semantic validity. Constructing reflection records also
//! performs no semantic validation; manual producers must preserve wire IDs, type
//! indices, and Object-pointer relationships. Unknown appended BFBS fields are
//! ignored and cannot be reproduced by encoding this metadata model; unknown
//! type codes and feature bits are retained.

/// Parse FBS text into reflection metadata using caller-owned arena storage.
/// Input text and filenames are copied. Metadata references, diagnostic strings, and
/// temporaries share the arena lifetime. Retain it for all consumers, then release it
/// after success or failure. Use `parser.parseWithOptions` for includes, diagnostics,
/// and nesting limits. Includes
/// require a caller callback; the parser does not load files automatically.
pub const parser = @import("compiler/parser.zig");
/// Schema records shared by FBS parsing, BFBS conversion, and source generation.
/// Slices and pointers borrow their producer's storage. Copying a record preserves
/// those borrows; keep the backing storage alive for every consumer. Constructing
/// records performs no validation. BFBS root, RPC, and legacy Object references
/// must point into `reflection.Schema.objects`.
pub const reflection = @import("compiler/reflection.zig");
/// Encode reflection metadata as BFBS, or decode BFBS into independent arena storage.
/// `bfbs.encode` returns an aligned allocation; free the returned slice with its allocator.
/// `bfbs.decode` copies strings and preserves shared Object references. Retain its arena
/// until consumers finish and release it on success or failure. `bfbs.decodeWithOptions` selects
/// framing and resource limits; checked wire data is not necessarily a valid FBS schema.
pub const bfbs = @import("compiler/bfbs.zig");
