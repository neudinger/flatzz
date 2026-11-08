//! Size-preserving replacement. Each fallible operation preflights before writes.
//! These helpers allocate nothing and operate on already located, present values.
//! The caller retains the complete mutable frame and checks schema presence/counts.
const std = @import("std");
const wire = @import("wire.zig");
const buffer_access = @import("buffer_access.zig");
const sequence = @import("sequence.zig");
const errors = @import("errors.zig");

const MutationError = errors.MutationError;
const StringVector = sequence.SequenceView(sequence.StringCodec, .read_only);

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
    try buffer_access.writeScalar(wire.Scalar(ValueType), bytes, field_start, replacement);
}

/// Preflight the whole inline value before encoding any members or padding.
/// Input aggregates must not borrow any frame bytes; aliasing returns AliasedInput.
pub fn inlineValue(
    comptime Layout: type,
    bytes: []u8,
    value_start: usize,
    value: Layout.Value,
) MutationError!void {
    try buffer_access.inlineRange(bytes, value_start, Layout.wire_size, Layout.wire_alignment);
    // Zig may pass aggregates by reference. Reject borrowing the target so
    // clearing padding cannot overwrite yet-to-be-encoded members.
    if (buffer_access.overlaps(
        bytes,
        std.mem.asBytes(&value),
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
    try buffer_access.checkRange(bytes.len, payload_start, 0);
    if (values.len > (bytes.len - payload_start) / Layout.wire_size)
        return MutationError.OutOfBounds;
    // No payload alignment is required when replacing a present empty vector.
    if (values.len != 0 and payload_start % Layout.wire_alignment != 0)
        return MutationError.InvalidBuffer;
    if (buffer_access.overlaps(
        bytes,
        std.mem.sliceAsBytes(values),
    )) return MutationError.AliasedInput;
    Layout.encodeSlice(bytes[payload_start..][0 .. values.len * Layout.wire_size], values);
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
    if (!std.unicode.utf8ValidateSlice(replacement)) return MutationError.InvalidUtf8;
    const payload_start = @intFromPtr(current.ptr) - @intFromPtr(bytes.ptr);
    @memmove(bytes[payload_start..][0..current.len], replacement);
}

/// Pairwise checks preserve the existing allocation-free, atomic bulk contract.
/// Sources cannot borrow bytes or descriptor storage. Equal shared targets must
/// receive equal replacements. Each target is validated once; pairwise object
/// overlap checks remain O(element_count squared), with constant scratch space.
/// `vector` must use this frame and `replacement.len` must equal its checked count.
pub fn stringVector(
    bytes: []u8,
    vector: StringVector,
    replacement: []const []const u8,
) MutationError!void {
    // Validate the complete update before writing, including aliasing.
    // Writing a target must not corrupt the replacement slice descriptors.
    if (buffer_access.overlaps(
        bytes,
        std.mem.sliceAsBytes(replacement),
    )) return MutationError.AliasedInput;
    for (replacement, 0..) |value_bytes, element_index| {
        const target = try vector.get(element_index);
        // Equal vector counts do not guarantee that each string fits its existing slot.
        if (target.len != value_bytes.len) return MutationError.LengthMismatch;
        if (!std.unicode.utf8ValidateSlice(
            value_bytes,
        )) return MutationError.InvalidUtf8;
        // Earlier writes must not change input bytes needed by later replacements.
        if (buffer_access.overlaps(bytes, value_bytes))
            return MutationError.AliasedInput;
        const target_start = @intFromPtr(target.ptr) - @intFromPtr(bytes.ptr);
        const target_end = target_start + target.len + wire.string_terminator_size;
        const target_object = bytes[target_start - wire.sequence_length_size .. target_end];
        for (
            replacement[0..element_index],
            0..,
        ) |previous_value, previous_index| {
            // Earlier iterations validated this slot and its replacement length.
            // Preflight writes nothing, so its offset and object extent are unchanged.
            const previous_start = stringPayloadStart(vector, previous_index);
            if (target_start == previous_start) {
                // Shared offsets name one string, which cannot receive two different values.
                if (!std.mem.eql(
                    u8,
                    value_bytes,
                    previous_value,
                )) return MutationError.ConflictingAlias;
            } else {
                const previous_end = previous_start + previous_value.len +
                    wire.string_terminator_size;
                const previous_object =
                    bytes[previous_start - wire.sequence_length_size .. previous_end];
                // Distinct objects cannot overlap: one write could corrupt the other's header.
                if (buffer_access.overlaps(
                    target_object,
                    previous_object,
                )) return MutationError.InvalidBuffer;
            }
        }
    }
    for (replacement, 0..) |value_bytes, element_index| {
        // Preflight checked every target and proved writes cannot change metadata
        // or later inputs. Only payload bytes have changed during this commit.
        const payload_start = stringPayloadStart(vector, element_index);
        @memcpy(bytes[payload_start..][0..value_bytes.len], value_bytes);
    }
}

// Only use after this slot passed get and no metadata has changed. Preflight
// protects the complete offset array and each string's prefix/terminator from writes.
fn stringPayloadStart(vector: StringVector, element_index: usize) usize {
    const element_start = vector.payload_start + element_index * wire.field_offset_size;
    const relative_offset = std.mem.readInt(
        u32,
        vector.bytes[element_start..][0..wire.field_offset_size],
        .little,
    );
    return element_start + relative_offset + wire.sequence_length_size;
}
