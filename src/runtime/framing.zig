//! Frame positions retain the prefix: alignment is relative to slice index zero.
const wire = @import("wire.zig");
const buffer_access = @import("buffer_access.zig");
const errors = @import("errors.zig");

const AccessError = errors.AccessError;

/// Whether a u32 byte count precedes the root-offset slot.
pub const Format = enum {
    /// Root-offset slot begins at byte zero.
    ordinary,
    /// Byte count begins at zero; the root-offset slot follows it.
    size_prefixed,
};
/// Treatment of bytes after a size-prefixed message.
pub const Boundary = enum {
    /// Reject bytes following the declared prefixed frame.
    exact,
    /// Consume one prefixed frame; the caller retains the remainder.
    first,
};
/// Runtime frame selection, independent of the schema's object descriptors.
pub const Options = struct {
    /// Ordinary framing is the default; prefixes must be selected explicitly.
    format: Format = .ordinary,
    /// Null skips the identifier check; a value requires exactly these four bytes.
    identifier: ?[wire.file_identifier_size]u8 = null,
    /// Applies to prefixed frames. Ordinary buffers have no declared boundary.
    boundary: Boundary = .exact,
};

/// Byte positions relative to the original frame, retaining any size prefix.
pub const Layout = struct {
    /// Consumed bytes, including the size prefix when present.
    frame_size: usize,
    /// Byte position of the root's forward-offset slot.
    root_offset_start: usize = 0,
    /// Prefix, root-offset, and checked identifier bytes protected from objects.
    header_size: usize = wire.root_offset_size,
};

/// Parse one frame. For .first, bytes[layout.frame_size..] is the remainder.
/// Keep bytes[0..layout.frame_size], including the prefix, for all object access.
/// This checks framing only, not root-table metadata or the reachable graph.
/// Truncation returns OutOfBounds; an unexpected identifier returns
/// IdentifierMismatch, and an exact-boundary mismatch returns InvalidBuffer.
/// No allocation or copying occurs; the returned record contains only positions.
pub fn parse(bytes: []const u8, options: Options) AccessError!Layout {
    var layout: Layout = .{ .frame_size = bytes.len };
    if (options.format == .size_prefixed) {
        const declared_size: usize = try buffer_access.readScalar(u32, bytes, 0);
        // Subtraction-based range checking proves the addition cannot wrap.
        try buffer_access.checkRange(bytes.len, wire.size_prefix_size, declared_size);
        layout.frame_size = wire.size_prefix_size + declared_size;
        layout.root_offset_start = wire.size_prefix_size;
        layout.header_size += wire.size_prefix_size;
        if (options.boundary == .exact and layout.frame_size != bytes.len)
            return AccessError.InvalidBuffer;
    }
    try buffer_access.checkRange(
        layout.frame_size,
        layout.root_offset_start,
        wire.root_offset_size,
    );
    if (options.identifier) |identifier| {
        // Identifier lookup has no alignment checks; object access retains
        // the full frame instead of rebasing its positions onto this subslice.
        try buffer_access.checkIdentifier(
            bytes[layout.root_offset_start..layout.frame_size],
            identifier,
        );
        layout.header_size += wire.file_identifier_size;
    }
    return layout;
}
