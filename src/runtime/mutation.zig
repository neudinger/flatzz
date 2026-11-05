//! Size-preserving replacement. Each fallible operation preflights before writes.
//! These helpers allocate nothing and operate on already located, present values.
//! The caller retains the complete mutable frame and checks schema presence/counts.
const standard_library = @import("std");
const wire = @import("wire.zig");
const validation = @import("validation.zig");
const sequence = @import("sequence.zig");
const MutationError = @import("errors.zig").MutationError;

/// Replace one present scalar after checking its byte range.
/// Optional null returns CannotClearField; use rebuilding to remove a stored field.
pub fn scalar(
    comptime ValueType: type,
    bytes: []u8,
    field_start: usize,
    value: ValueType,
) MutationError!void {
    const replacement = switch (@typeInfo(ValueType)) {
        .optional => value orelse return MutationError.CannotClearField,
        else => value,
    };
    try validation.writeScalar(
        wire.Scalar(ValueType),
        bytes,
        field_start,
        replacement,
    );
}

/// Preflight the whole inline value before encoding any members or padding.
/// Input aggregates must not borrow any frame bytes; aliasing returns AliasedInput.
pub fn inlineValue(
    comptime Layout: type,
    bytes: []u8,
    value_start: usize,
    value: Layout.Value,
) MutationError!void {
    try validation.inlineRange(
        bytes,
        value_start,
        Layout.wire_size,
        Layout.wire_alignment,
    );
    // Zig may pass aggregates by reference. Reject borrowing the target so
    // clearing padding cannot overwrite yet-to-be-encoded members.
    if (validation.overlaps(
        bytes,
        standard_library.mem.asBytes(&value),
    )) return MutationError.AliasedInput;
    Layout.encode(bytes[value_start..][0..Layout.wire_size], value);
}

/// Replace a complete validated vector payload; its count cannot change.
/// The caller ensures `values.len` equals the stored count. Reject misalignment,
/// insufficient bytes, or input aggregates borrowing the destination frame.
pub fn structVector(
    comptime Layout: type,
    bytes: []u8,
    payload_start: usize,
    values: []const Layout.Value,
) MutationError!void {
    // Divide first: no count or payload-size multiplication may overflow.
    try validation.checkRange(bytes.len, payload_start, 0);
    if (values.len > (bytes.len - payload_start) / Layout.wire_size)
        return MutationError.OutOfBounds;
    // No payload alignment is required when replacing a present empty vector.
    if (values.len != 0 and payload_start % Layout.wire_alignment != 0)
        return MutationError.InvalidBuffer;
    if (validation.overlaps(
        bytes,
        standard_library.mem.sliceAsBytes(values),
    )) return MutationError.AliasedInput;
    Layout.encodeSlice(
        bytes[payload_start..][0 .. values.len * Layout.wire_size],
        values,
    );
}

/// Replace a validated string with equal-length UTF-8 bytes; overlapping input is allowed.
/// `current` must be a live payload slice in `bytes`. Null, length, and UTF-8
/// failures occur before writes; the count and terminator remain unchanged.
pub fn string(
    bytes: []u8,
    current: []const u8,
    value: ?[]const u8,
) MutationError!void {
    const replacement = value orelse return MutationError.CannotClearField;
    if (replacement.len != current.len) return MutationError.LengthMismatch;
    if (!standard_library.unicode.utf8ValidateSlice(
        replacement,
    )) return MutationError.InvalidUtf8;
    const payload_start = @intFromPtr(current.ptr) - @intFromPtr(bytes.ptr);
    @memmove(bytes[payload_start..][0..current.len], replacement);
}

/// Pairwise checks preserve the existing allocation-free, atomic bulk contract.
/// Sources cannot borrow bytes or descriptor storage. Equal shared targets must
/// receive equal replacements. This is intentionally O(element_count squared).
/// `vector` must use this frame and `replacement.len` must equal its checked count.
pub fn stringVector(
    bytes: []u8,
    vector: sequence.Sequence(sequence.StringCodec),
    replacement: []const []const u8,
) MutationError!void {
    // Validate the complete update before writing, including aliasing.
    // Writing a target must not corrupt the replacement slice descriptors.
    if (validation.overlaps(
        bytes,
        standard_library.mem.sliceAsBytes(replacement),
    )) return MutationError.AliasedInput;
    for (replacement, 0..) |value_bytes, element_index| {
        const target = try vector.get(element_index);
        // Equal vector counts do not guarantee that each string fits its existing slot.
        if (target.len != value_bytes.len) return MutationError.LengthMismatch;
        if (!standard_library.unicode.utf8ValidateSlice(
            value_bytes,
        )) return MutationError.InvalidUtf8;
        // Earlier writes must not change input bytes needed by later replacements.
        if (validation.overlaps(bytes, value_bytes))
            return MutationError.AliasedInput;
        const target_start = @intFromPtr(
            target.ptr,
        ) - @intFromPtr(bytes.ptr);
        const target_object = bytes[target_start - wire.sequence_length_size .. target_start + target.len + wire.string_terminator_size];
        for (
            replacement[0..element_index],
            0..,
        ) |previous_value, previous_index| {
            const previous = try vector.get(previous_index);
            if (target.ptr == previous.ptr) {
                // Shared offsets name one string, which cannot receive two different values.
                if (!standard_library.mem.eql(
                    u8,
                    value_bytes,
                    previous_value,
                )) return MutationError.ConflictingAlias;
            } else {
                const previous_start = @intFromPtr(
                    previous.ptr,
                ) - @intFromPtr(bytes.ptr);
                const previous_object = bytes[previous_start - wire.sequence_length_size .. previous_start + previous.len + wire.string_terminator_size];
                // Distinct objects cannot overlap: one write could corrupt the other's header.
                if (validation.overlaps(
                    target_object,
                    previous_object,
                )) return MutationError.InvalidBuffer;
            }
        }
    }
    for (replacement, 0..) |value_bytes, element_index| {
        // Preflight checked every target and proved writes cannot change metadata
        // or later inputs. Only payload bytes have changed during this commit.
        const target = vector.get(element_index) catch unreachable;
        const payload_start = @intFromPtr(
            target.ptr,
        ) - @intFromPtr(bytes.ptr);
        @memcpy(bytes[payload_start..][0..target.len], value_bytes);
    }
}
