//! Union metadata and checked borrowed alternatives, not native wire layouts.
//! Each logical field owns a tag and a payload slot. Union vectors pair two
//! arrays; only NONE elements may contain a zero offset.
//! https://github.com/dvidelabs/flatcc/blob/e1272290b486fdd7fdc60f061036b7a18c468dc7/doc/binary-format.md#unions
//!
//! Example inside a test with `std = @import("std")` and
//! `runtime = @import("flatzz")` imported:
//! ```zig
//! const Payload = runtime.Union(enum(u8) { none, text }, .{
//!     .none = .none,
//!     .text = .string,
//! });
//! var storage: [128]u8 align(runtime.storage_alignment) = undefined;
//! var builder = runtime.Builder.init(&storage);
//! const text = try builder.createString("hello");
//! const value: Payload.Value = .{ .text = text };
//! const selected = Payload.tag(value);
//! const handle = Payload.offset(value);
//! try std.testing.expectEqual(Payload.Tag.text, selected);
//! try std.testing.expectEqual(text, handle.?);
//! ```
//! Expected result: `selected == .text` and `handle.? == text`; nothing is printed.
//! `value` is a construction handle, not serialized bytes or a decoded view.
//! The builder and its storage must remain valid until the enclosing table is finished.
const standard_library = @import("std");
const wire = @import("wire.zig");
const validation = @import("validation.zig");
const sequence = @import("sequence.zig");
const tables = @import("table_view.zig");
const StructView = @import("struct_view.zig").StructView;
const Builder = @import("Builder.zig");
const errors = @import("errors.zig");

/// Interpretation of a named union alternative; the native Zig union is not a wire layout.
pub const Kind = union(enum) {
    /// No payload; permitted only for the zero-valued `none` tag.
    none,
    /// Referenced child table, with a named schema for verification.
    table: type,
    /// Referenced inline struct layout.
    structure: type,
    /// Referenced UTF-8 string.
    string,
};
/// Adjacent physical vtable IDs representing one logical union field.
pub const FieldIds = struct {
    /// Discriminator slot; vector fields store an offset to tags instead.
    tag: usize,
    /// Payload slot immediately following `tag`; vector fields store an offset to values.
    value: usize,
};
/// Checked-location input shared by scalar union access and union-vector elements.
pub const Location = struct {
    /// Raw wire discriminator, validated against the union's enum before use.
    tag: wire.UnionTag,
    /// Payload offset slot relative to the complete frame; null means an absent field slot.
    reference_start: ?usize,
    /// Parent ranges that payloads may not reinterpret as objects.
    context: validation.Context,
};

/// Handles are explicit, like C++ Offset<void> / flatcc union references.
/// Build the selected child first. Names/tags carry the schema alternative;
/// a handle does not prove the object's kind or ownership (as for all offsets).
/// Tags must be an exhaustive u8 enum with `none = 0`, and alternatives must
/// match its field names. Invalid declarations fail at compile time.
/// Borrowed views allocate nothing and remain valid only while frame storage is retained.
pub fn Union(
    comptime TagType: type,
    comptime alternatives: Alternatives(TagType),
) type {
    const tag_info = @typeInfo(TagType).@"enum";
    const names = tag_info.field_names;
    comptime {
        if (tag_info.tag_type != wire.UnionTag or tag_info.mode != .exhaustive)
            @compileError("union tags require an exhaustive u8 enum");
        if (!@hasField(TagType, "none") or
            @backingInt(@field(TagType, "none")) != wire.union_none)
            @compileError("union tags require none = 0");
        for (names) |name| {
            const kind: Kind = @field(alternatives, name);
            const is_none = @field(TagType, name) == .none;
            if ((kind == .none) != is_none)
                @compileError("only the none tag may omit a payload");
            switch (kind) {
                .structure => |Layout| {
                    if (Layout.layout_kind != .structure)
                        @compileError(
                            "union struct alternatives need a struct layout",
                        );
                },
                else => {},
            }
        }
    }
    return struct {
        /// Exhaustive wire discriminator enum, including the zero-valued `none` member.
        pub const Tag = TagType;
        /// Compile-time payload interpretation keyed by tag name.
        pub const variants = alternatives;
        /// Construction union: non-none cases carry completed Builder offsets.
        pub const Value = blk_value: {
            var types: [names.len]type = undefined;
            for (names, 0..) |name, field_index| {
                types[field_index] = switch (@field(alternatives, name)) {
                    .none => void,
                    else => Builder.Offset,
                };
            }
            break :blk_value @Union(.auto, Tag, names, &types, &@splat(.{}));
        };

        /// Decoded union of borrowed alternatives; table and struct payloads retain access capability.
        pub fn View(comptime access: tables.Access) type {
            var types: [names.len]type = undefined;
            for (names, 0..) |name, field_index| {
                types[field_index] = switch (@field(alternatives, name)) {
                    .none => void,
                    .table => tables.TableView(access),
                    .structure => |Layout| StructView(Layout, access),
                    .string => []const u8,
                };
            }
            return @Union(.auto, Tag, names, &types, &@splat(.{}));
        }

        /// Convert a raw wire discriminator; return UnknownUnionTag for unrecognized values.
        pub fn parseTag(raw_tag: wire.UnionTag) errors.AccessError!Tag {
            return standard_library.enums.fromInt(Tag, raw_tag) orelse
                errors.AccessError.UnknownUnionTag;
        }

        /// Extract the discriminator from a native construction value.
        pub fn tag(value: Value) Tag {
            return standard_library.meta.activeTag(value);
        }

        /// Extract a completed payload handle; return null for `.none`.
        pub fn offset(value: Value) ?Builder.Offset {
            return switch (value) {
                .none => null,
                inline else => |handle| handle,
            };
        }

        /// Tag/offset pairing is checked before interpreting any payload.
        /// Field NONE requires absence; vector NONE requires a zero slot.
        pub fn check(
            bytes: []const u8,
            location: Location,
        ) errors.AccessError!Tag {
            const selected = try parseTag(location.tag);
            const reference_start = location.reference_start orelse {
                if (selected != .none) return errors.AccessError.InvalidUnion;
                return selected;
            };
            const relative_offset = try validation.readScalar(
                u32,
                bytes,
                reference_start,
            );
            if ((selected == .none) != (relative_offset == 0))
                return errors.AccessError.InvalidUnion;
            return selected;
        }

        /// Validate pairing, then borrow the selected payload using local wire checks.
        /// Table payload fields are not traversed; full verification belongs to the schema verifier.
        pub fn read(
            comptime access: tables.Access,
            bytes: switch (access) {
                .read_only => []const u8,
                .mutable => []u8,
            },
            location: Location,
        ) errors.AccessError!View(access) {
            const selected = try check(bytes, location);
            return switch (selected) {
                .none => .none,
                inline else => |choice| blk_alternative: {
                    const reference_start = location.reference_start.?;
                    const value = switch (@field(
                        alternatives,
                        @tagName(choice),
                    )) {
                        .none => unreachable,
                        .table => tables.TableView(access){
                            .bytes = bytes,
                            .layout = try validation.referencedTable(
                                bytes,
                                location.context,
                                reference_start,
                            ),
                        },
                        .string => try validation.stringAt(
                            bytes,
                            location.context,
                            reference_start,
                        ),
                        .structure => |Layout| blk_struct: {
                            const target = try validation.referenceTarget(
                                bytes,
                                reference_start,
                            );
                            try location.context.checkObject(.{
                                .start = target,
                                .size = Layout.wire_size,
                            });
                            break :blk_struct try StructView(Layout, access).from(
                                bytes,
                                target,
                            );
                        },
                    };
                    break :blk_alternative @unionInit(
                        View(access),
                        @tagName(choice),
                        value,
                    );
                },
            };
        }
    };
}

fn Alternatives(comptime Tag: type) type {
    const names = @typeInfo(Tag).@"enum".field_names;
    const types: [names.len]type = @splat(Kind);
    return @Struct(.auto, null, names, &types, &@splat(.{}));
}

/// The tag defaults to NONE, but a present value slot always needs a real tag.
pub fn field(
    table: anytype,
    comptime field_ids: FieldIds,
) errors.AccessError!Location {
    const raw_tag = try table.readField(
        wire.UnionTag,
        field_ids.tag,
        wire.union_none,
    );
    const reference_start = try table.fieldPosition(u32, field_ids.value);
    if ((raw_tag == wire.union_none) != (reference_start == null))
        return errors.AccessError.InvalidUnion;
    return .{
        .tag = raw_tag,
        .reference_start = reference_start,
        .context = table.context(),
    };
}

/// Borrow paired discriminator/payload vectors without allocating a second array.
/// Both vectors must remain intact; opening checks layout and count, while `get`
/// checks each selected alternative lazily. Storage reuse invalidates all borrowed views.
pub fn VectorView(
    comptime UnionType: type,
    comptime access: tables.Access,
) type {
    return struct {
        const Self = @This();
        /// Borrowed alternative returned by `get`, with the selected capability.
        pub const Value = UnionType.View(access);
        const Bytes = switch (access) {
            .read_only => []const u8,
            .mutable => []u8,
        };
        /// Complete frame retained for shared referenced payloads.
        bytes: Bytes,
        /// Byte offset of the first discriminator, after its vector prefix.
        tags_start: usize,
        /// Byte offset of the first payload offset, after its vector prefix.
        values_start: usize,
        /// Equal element count of both paired vectors.
        element_count: usize,
        /// Parent ranges protected while following payload references.
        context: validation.Context,

        /// Open both vectors from their offset slots and reject unequal counts or overlap.
        /// A shared empty vector is permitted; element tags/payloads remain lazily checked.
        pub fn fromReferences(
            bytes: Bytes,
            context: validation.Context,
            tags_reference: usize,
            values_reference: usize,
        ) errors.AccessError!Self {
            const tags = try validation.sequenceAt(
                @sizeOf(wire.UnionTag),
                @sizeOf(wire.UnionTag),
                0,
                bytes,
                context,
                tags_reference,
            );
            const values = try validation.sequenceAt(
                wire.field_offset_size,
                wire.field_offset_size,
                0,
                bytes,
                context,
                values_reference,
            );
            if (tags.element_count != values.element_count)
                return errors.AccessError.InvalidUnion;
            const result: Self = .{
                .bytes = bytes,
                .tags_start = tags.payload_start,
                .values_start = values.payload_start,
                .element_count = tags.element_count,
                .context = context,
            };
            // Sharing one empty vector is harmless. Any other metadata/payload
            // overlap would let offsets reinterpret discriminator bytes.
            if (validation.rangesOverlap(
                result.tagsRange(),
                result.valuesRange(),
            ) and
                !(result.element_count == 0 and
                    result.tags_start == result.values_start))
                return errors.AccessError.InvalidUnion;
            return result;
        }

        /// Bounds-check one index and borrow its checked union alternative.
        pub fn get(
            self: Self,
            element_index: usize,
        ) errors.AccessError!Value {
            return UnionType.read(
                access,
                self.bytes,
                try self.element(element_index),
            );
        }

        /// Checked slot locations for budgeted verifier traversal.
        pub fn element(
            self: Self,
            element_index: usize,
        ) errors.AccessError!Location {
            const tags: sequence.Sequence(sequence.ScalarCodec(
                wire.UnionTag,
            )) = .{
                .bytes = self.bytes,
                .payload_start = self.tags_start,
                .element_count = self.element_count,
            };
            const values: sequence.Sequence(sequence.ScalarCodec(u32)) = .{
                .bytes = self.bytes,
                .payload_start = self.values_start,
                .element_count = self.element_count,
            };
            // Check both complete payloads before size multiplication/context.
            const tags_slot = try tags.elementStart(element_index);
            const values_slot = try values.elementStart(element_index);
            if (self.tags_start < wire.sequence_length_size or
                self.values_start < wire.sequence_length_size)
                return errors.AccessError.InvalidBuffer;
            var context = self.context;
            context.vector = self.valuesRange();
            context.protected = self.tagsRange();
            return .{
                .tag = try validation.readScalar(
                    wire.UnionTag,
                    self.bytes,
                    tags_slot,
                ),
                .reference_start = values_slot,
                .context = context,
            };
        }

        fn tagsRange(self: Self) validation.Range {
            return .{
                .start = self.tags_start - wire.sequence_length_size,
                .size = wire.sequence_length_size + self.element_count,
            };
        }

        fn valuesRange(self: Self) validation.Range {
            return .{
                .start = self.values_start - wire.sequence_length_size,
                .size = wire.sequence_length_size +
                    self.element_count * wire.field_offset_size,
            };
        }
    };
}
