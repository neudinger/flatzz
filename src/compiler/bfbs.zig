//! Native BFBS encoding and checked decoding for `reflection.zig` metadata.
//!
//! Wire IDs follow FlatBuffers v25.2.10, commit
//! 1c514626e83c20fffa8557e75641848e1e15cd5e, reflection/reflection.fbs.
//! Declaration order includes the reserved legacy EnumVal.object slot at ID 2.
//! Encoding preserves vector order and type indices, except attributes are sorted
//! by key for official LookupByKey consumers. Input metadata is never modified.
//!
//! `encode` returns an owned, aligned byte slice; free it with the same allocator.
//! Decoding uses a caller-owned arena for metadata and temporaries, copies strings,
//! and preserves shared Object references. Keep the arena alive for all consumers.
//! Wire validation does not replace FBS semantic validation. Unknown appended
//! fields are ignored; unknown BaseType values and feature bits are retained.
//!
//! ## Complete example
//!
//! Save this as `bfbs_example_test.zig` beside Flatzz's build file and run
//! ```sh
//! zig test --dep flatzz_compiler -Mroot=bfbs_example_test.zig \
//!     --dep flatzz -Mflatzz_compiler=src/compiler.zig -Mflatzz=src/runtime.zig
//! ```
//! ```zig
//! const std = @import("std");
//! const compiler = @import("flatzz_compiler");
//!
//! test "schema binary round trip" {
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!     const schema = try compiler.parser.parse(arena.allocator(),
//!         "table Reading { value:uint = 42; } root_type Reading;");
//!     const bytes = try compiler.bfbs.encode(std.testing.allocator, schema);
//!     defer std.testing.allocator.free(bytes);
//!     const decoded = try compiler.bfbs.decode(arena.allocator(), bytes);
//!     try std.testing.expectEqualStrings("BFBS", bytes[4..8]);
//!     try std.testing.expectEqualStrings("Reading", decoded.root_table.?.name);
//!     try std.testing.expectEqual(@as(i64, 42), decoded.root_table.?.fields[0].default_integer);
//! }
//! ```
//! Expected result: a passing round-trip test; the codec itself prints nothing.
//! Encoded bytes are separately owned, and the arena retains both metadata graphs.

const std = @import("std");
const reflection = @import("reflection.zig");
const runtime = @import("flatzz");
const Encoder = @import("bfbs/Encoder.zig");
const Decoder = @import("bfbs/Decoder.zig");

const wire = runtime.wire;
const Builder = runtime.Builder;
const framing = runtime.framing;

/// Allocation, construction, invalid-wire, or configured resource-limit failures.
pub const Error = std.mem.Allocator.Error || Builder.Error || error{
    /// Invalid framing, missing required metadata, invalid UTF-8, or malformed wire data.
    InvalidBfbs,
    /// Encoding found invalid UTF-8 or an Object pointer outside `Schema.objects`.
    InvalidSchema,
    /// A decoded table subtree would exceed `DecodeOptions.max_depth`.
    DepthLimit,
    /// Table/vector/string visits would exceed `DecodeOptions.max_objects`.
    ObjectLimit,
    /// Traversal or decoded allocation work would exceed `DecodeOptions.max_work`.
    WorkLimit,
};

/// Decoder work bounds apply before payload allocation or string scanning.
pub const DecodeOptions = struct {
    /// Ordinary BFBS by default; prefixed input retains its original alignment origin.
    format: framing.Format = .ordinary,
    /// Maximum nested table depth; zero rejects every schema.
    max_depth: usize = 64,
    /// Table, vector, and string visits, including shared-object references.
    max_objects: usize = 1_000_000,
    /// Wire traversal and decoded allocation bytes; includes repeated shared-object work
    /// but excludes allocator overhead and temporary lookup-table storage.
    max_work: usize = 64 * 1024 * 1024,
};

/// Decode ordinary BFBS with default resource limits into caller-arena storage.
/// Returned strings do not borrow `bytes`; release the arena on success or failure.
/// Errors are `InvalidBfbs`, resource-limit failures, or `OutOfMemory`; allocation
/// already performed before an error is retained in the caller's arena.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!reflection.Schema {
    return decodeWithOptions(allocator, bytes, .{});
}

/// Decode known reflection fields with explicit framing and resource limits.
/// Missing required references, invalid offsets, alignment, or UTF-8 return InvalidBfbs.
/// Empty required strings/vectors remain valid, and omitted scalars use schema defaults.
/// Use an arena for returned metadata and temporaries; release it on success or
/// failure. The result no longer borrows `bytes`. Limits return `DepthLimit`,
/// `ObjectLimit`, or `WorkLimit`, independently of allocation failure.
pub fn decodeWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) Error!reflection.Schema {
    return Decoder.decode(allocator, bytes, options);
}

/// Allocate a complete BFBS frame. The returned slice starts at its allocation
/// base and must be freed with the same allocator.
/// Input records and their borrowed buffers must remain valid throughout the call.
/// Attribute vectors are canonicalized by key without mutating caller storage.
/// Root, RPC, and legacy Object pointers must reference elements of schema.objects;
/// external Object copies or invalid UTF-8 return InvalidSchema. Semantic ordering
/// and Type indices remain the caller's responsibility.
/// Returns ordinary framing with the BFBS identifier. Allocation and construction
/// errors propagate; all internal allocations are released when encoding fails.
/// This encodes reflection metadata, not application message values.
/// Unknown appended BFBS fields cannot be reproduced from this metadata model.
pub fn encode(
    allocator: std.mem.Allocator,
    schema: reflection.Schema,
) Error![]align(wire.storage_alignment) u8 {
    return Encoder.encode(allocator, schema);
}
