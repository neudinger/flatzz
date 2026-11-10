//! Native FlatBuffers serialization, borrowed access, and known-schema verification.
//!
//! Import this module with `const flatzz = @import("flatzz");`. Generated tables
//! expose the same schema operations as the handwritten `Reading` type below.
//! Wire IDs and defaults come from descriptors, independently of native Zig layout.
//! Schema parsing, reflection, and BFBS conversion belong to `flatzz_compiler`;
//! applications using this runtime do not load BFBS metadata.
//! `serialize(target, options)` selects storage at compile time from the target's
//! type: an aligned mutable byte buffer returns a borrowed slice; a std.mem.Allocator
//! returns an owned Serialized. The target and native values remain runtime inputs.
//!
//! ## Allocating serialization
//!
//! Save this complete example as `runtime_example_test.zig` beside `build.zig`:
//!
//! ```zig
//! const std = @import("std");
//! const flatzz = @import("flatzz");
//!
//! const Reading = struct {
//!     value: u32 = 0,
//!     label: ?[]const u8 = null,
//!
//!     pub const Schema = flatzz.Schema(@This(), .{
//!         .value = flatzz.ScalarField(u32, 0, 0),
//!         .label = flatzz.ReferenceField(1, .string, .{}),
//!     });
//!     pub const serialize = Schema.serialize;
//!     pub const verify = Schema.verify;
//!     pub const read = Schema.read;
//!     pub const update = Schema.update;
//! };
//!
//! test "allocated serialization" {
//!     const allocator = std.testing.allocator;
//!     const value: Reading = .{ .value = 41, .label = "sensor" };
//!     const result = try value.serialize(allocator, .{});
//!     defer result.deinit(allocator);
//!
//!     try Reading.verify(result.bytes, .{});
//!     try std.testing.expect(try Reading.update(result.bytes, .value, 42));
//!     const reading = try Reading.read(result.bytes);
//!     try std.testing.expectEqual(@as(u32, 42), reading.value);
//!     try std.testing.expectEqualStrings("sensor", reading.label.?);
//! }
//! ```
//!
//! From the package root with Zig 0.17.0:
//!
//! ```sh
//! zig test --dep flatzz -Mroot=runtime_example_test.zig -Mflatzz=src/runtime.zig
//! ```
//!
//! Expected result: one passing test, with no application output. Serialization
//! measures the native graph, allocates one aligned buffer, and packs without a
//! final output copy. `result.bytes` and `reading.label` borrow that allocation
//! until `result.deinit(allocator)`. Never free the `bytes` suffix separately.
//!
//! ## Fixed-buffer serialization
//!
//! Append this test to the same file, reusing its imports and `Reading` type:
//!
//! ```zig
//! test "fixed-buffer serialization" {
//!     const value: Reading = .{ .value = 42, .label = "sensor" };
//!     const capacity = comptime flatzz.storage.capacityFor(Reading.Schema, value, .{});
//!     var buffer: [capacity]u8 align(flatzz.storage_alignment) = undefined;
//!     const bytes = try value.serialize(&buffer, .{});
//!     try Reading.verify(bytes, .{});
//!     const reading = try Reading.read(bytes);
//!     try std.testing.expectEqual(@as(u32, 42), reading.value);
//!     try std.testing.expectEqualStrings("sensor", reading.label.?);
//! }
//! ```
//!
//! Expected result: a passing test with no application output or heap allocation.
//! `capacityFor` requires a comptime-known native graph and returns an aligned
//! upper bound, not the frame length. `bytes` and its views borrow `buffer` until
//! reuse or the end of its lifetime; no `deinit` is needed. For runtime inputs,
//! use `Storage` with explicit maximum capacities instead of `capacityFor`.
//!
//! ## Explicit construction and sharing
//!
//! Append this alternative test to the same file:
//!
//! ```zig
//! test "explicit construction" {
//!     var storage: flatzz.Storage(Reading.Schema, .{ .label = 6 }, .{}) = .{};
//!     var builder = flatzz.Builder.init(&storage.buffer);
//!     const label = try builder.createString("sensor");
//!     const fields: Reading.Schema.Fields = .{ .value = 42, .label = label };
//!     var table = try Reading.Schema.Context.init(&builder);
//!     try Reading.Schema.addFields(&table, fields);
//!     const bytes = try builder.finish(try Reading.Schema.endTable(&table), .ordinary);
//!     try Reading.verify(bytes, .{});
//!     const reading = try Reading.read(bytes);
//!     try std.testing.expectEqual(@as(u32, 42), reading.value);
//!     try std.testing.expectEqualStrings("sensor", reading.label.?);
//! }
//! ```
//!
//! Expected result: a passing test producing the same values without allocation.
//! The frame borrows `storage.buffer`. Build referenced children before opening
//! their parent table. `Schema.Fields` holds native scalars/inline structs and
//! completed reference handles; unions use `Union.Handle`, and union vectors use
//! `Builder.UnionVector`. All handles must originate from this builder since its
//! last reset. Keep an active builder at a stable address; reset invalidates its
//! handles and views.
//!
//! Native serialization supports scalars, strings, structs and their arrays,
//! child tables, unions, and vectors. Child table inputs are pointers; native
//! union inputs use `Union.Value`. Repeated table pointers are serialized as
//! independent copies. Reuse explicit handles to preserve shared children, or
//! call `Schema.create(builder, value, options)` to pack into an existing builder.
//! Recursive packing uses one builder with bounded traversal; temporary vector
//! offsets reuse final output capacity without a separate scratch budget.
//!
//! ## Reading, mutation, and verification
//!
//! `Schema.read` accepts bytes or a checked `Table`; scalars are copied, while
//! strings and structured views borrow the complete frame. Vector elements are
//! checked lazily. Reading does not verify required-field presence or the full
//! reachable graph. Use `Schema.verify` for recursive known-field verification
//! with fresh depth, object, and work limits; unknown newer fields are not traversed.
//! Verification describes the bytes at that instant; later edits can invalidate it.
//!
//! `Schema.update` replaces a present field and returns `false` for an absent slot.
//! Strings retain their byte length, vectors retain their count, and null cannot
//! clear a present field. Table and whole-union replacement require rebuilding.
//! `Schema.borrowMutable` borrows structs, vectors, tables, or union payloads for
//! their supported edits; it performs no mutation itself. Scalars and strings use
//! `update`. Absent structured fields return null; absent unions use `.none`.
//!
//! Byte inputs to `read`, `update`, and `borrowMutable` open ordinary roots on each
//! call. Pass a checked table to reuse local metadata or select nested/custom
//! frames. Mutation needs mutable bytes or a `MutableTable`. Verification accepts
//! bytes with `Verifier.Options.frame`, or a `Table` retaining its selected frame.
//! Backing storage must outlive all borrows; structural edits invalidate cached
//! metadata. Read-only borrows can still observe edits through another alias.
//!
//! ## Serialization options and failures
//!
//! `WriteOptions` defaults omit non-optional scalars equal to their schema default.
//! Use `.{ .force_defaults = true }` to retain those slots for later mutation.
//! Native inputs must remain valid throughout serialization, including allocator
//! calls, and must not overlap fixed output storage. Depth and work limits bound
//! traversal, including cycles. Packing errors may leave partial fixed-buffer
//! contents; reset an existing builder to discard partial construction.
//! Buffer-target `serialize` returns `BuildError`; an allocator target also permits
//! `error.OutOfMemory` and frees any allocation on failure. Local access uses
//! `AccessError`, in-place replacement uses `MutationError`, and recursive
//! verification uses `VerifyError`.

const table_view = @import("runtime/table_view.zig");
const sequence = @import("runtime/sequence.zig");
const table_builder = @import("runtime/table_builder.zig");
const struct_layout = @import("runtime/struct_layout.zig");
const struct_view = @import("runtime/struct_view.zig");
const unions = @import("runtime/unions.zig");
const errors = @import("runtime/errors.zig");

/// Little-endian scalar encodings, wire sizes, alignment, and checked arithmetic.
pub const wire = @import("runtime/wire.zig");
/// Checked local ranges and scalar, string, offset, and sequence access.
/// Offsets are relative to the complete frame; these checks do not traverse a schema.
pub const buffer_access = @import("runtime/buffer_access.zig");
/// Ordinary/size-prefixed frame selection, boundaries, and optional identifiers.
/// Parsing checks framing without verifying the root table or its reachable graph.
pub const framing = @import("runtime/framing.zig");
/// Compile-time descriptors and typed serialization, access, mutation, and verification.
/// Native Zig types describe values; descriptors supply their wire interpretation.
pub const schema = @import("runtime/schema.zig");
/// Aligned capacity bounds, runtime native sizing, and owned serialization results.
/// A capacity bound may exceed the serialized frame's byte length.
pub const storage = @import("runtime/storage.zig");
/// Construct objects backward in caller-owned aligned storage without heap allocation.
/// Build children before parents; `finish` selects a root and returns a borrowed suffix.
/// Handles belong to this builder until reset. Never copy an active builder.
pub const Builder = @import("runtime/Builder.zig");
/// Traverse known schema fields with depth, object-visit, and work limits.
/// Borrows unchanged frame bytes without allocation. Failed stateful traversals can
/// consume budgets; initialize a fresh verifier to retry. Unknown fields are not traversed.
pub const Verifier = @import("runtime/Verifier.zig");

/// Select a borrowed table type by its compile-time read-only or mutable capability.
/// Opening checks local metadata; full graph verification requires a schema.
/// Retain backing bytes without structural edits; no allocation or cleanup is needed.
pub const TableView = table_view.TableView;
/// Select ordinary root access, custom framing options, or a known table position.
/// Positions are byte offsets in the complete frame, not offsets into child slices.
pub const TableSource = table_view.Source;
/// Select read-only or mutable bytes at compile time; both modes perform checked access.
/// A read-only borrow does not prevent edits through other aliases.
pub const Access = table_view.Access;
/// Read-only table metadata borrowing a complete frame; opening checks only local layout.
/// Scalars are copied and references borrow bytes. Storage reuse, reallocation, or
/// structural edits invalidate this view; use schema verification for the reachable graph.
pub const Table = TableView(.read_only);
/// Table metadata borrowing mutable bytes for checked, size-preserving replacements.
/// Updates cannot add absent slots; string lengths and vector counts must remain unchanged.
/// The backing frame must outlive the view; structural edits invalidate cached metadata.
pub const MutableTable = TableView(.mutable);
/// Construct a table with max physical field ID + 1 slots, including gaps and union tags.
/// Build children first, end the table, then finish its builder to emit a root frame.
/// This raw API does not enforce schema-required fields; use `Schema.endTable` for that.
pub const TableBuilder = table_builder.TableBuilder;
/// Derive typed native serialization, borrowed access, mutation, and verification adapters.
/// Native fields must match descriptor value types exactly. Duplicate or out-of-range
/// wire IDs fail at compile time. Read results copy scalars and borrow reference contents.
pub const Schema = schema.Schema;
/// Native packing policy: omit default-valued scalars unless `force_defaults` is true.
/// Null optional scalars remain absent; present optional values retain their slots.
/// Depth and work budgets bound native traversal, including cycles.
pub const WriteOptions = schema.WriteOptions;
/// Derive caller-owned aligned storage from schema facts and maximum capacities.
/// Strings use payload bytes; scalar/struct vectors use element counts. String/table/
/// union vectors use count/byte records, and child tables/unions use total byte budgets.
/// The buffer is undefined until written; returned frames borrow it until reuse.
pub const Storage = storage.Storage;
/// Own one aligned allocation including spare capacity; `bytes` borrows only its frame suffix.
/// Call `deinit` once with the allocator used for serialization; never free `bytes` alone.
/// Copies share the allocation. Deinitialization invalidates every borrowed view.
pub const Serialized = storage.Serialized;
/// Describe a scalar's native type, physical field ID, and schema default.
/// Optional scalars must default to null; a present zero differs from absence.
pub const ScalarField = schema.ScalarField;
/// Describe a nullable string, vector, or child-table reference, optionally required.
/// Null is absent; an empty string/vector is present. Native table values use pointers;
/// explicit `Schema.Fields` construction uses completed handles from one builder.
pub const ReferenceField = schema.ReferenceField;
/// Describe an inline struct field with a nullable native value and borrowed view.
/// Null represents absence; required presence is enforced by construction and verification.
pub const StructField = schema.StructField;
/// Describe a fixed-size wire struct independently of native Zig layout or field order.
/// Member offsets, size, alignment, and native field types are checked at compile time.
pub const StructLayout = struct_layout.StructLayout;
/// Describe a non-optional scalar at a byte offset within its containing wire struct.
/// The scalar's wire representation determines its size and alignment.
pub const ScalarMember = struct_layout.ScalarMember;
/// Describe a nested struct at a byte offset; array layouts are rejected at compile time.
pub const StructMember = struct_layout.StructMember;
/// Describe 1...65535 inline scalar or struct elements at a byte offset within a struct.
/// Fixed arrays have no count prefix; direct arrays of arrays are unsupported.
pub const ArrayMember = struct_layout.ArrayMember;
/// Select a borrowed inline struct view by layout and access capability.
/// `read` copies the native value; mutable views can update members in place.
/// Nested views share the complete frame, which must outlive every borrow.
pub const StructView = struct_view.StructView;
/// Select a borrowed fixed-array view whose element count comes from its layout.
/// Elements share the parent's storage without a vector prefix or allocation.
pub const ArrayView = struct_view.ArrayView;
/// Select a borrowed vector view by element codec and access capability.
/// Opening checks extent/alignment; `get` checks elements lazily. Mutable access exposes
/// mutable inline structs; other element results retain their codec's access rules.
pub const VectorView = sequence.SequenceView;
/// Decode copied vector elements using a supported scalar or enum wire type.
/// Unknown exhaustive-enum tags return `error.InvalidBuffer` when decoded.
pub const ScalarCodec = sequence.ScalarCodec;
/// Decode relative string offsets into borrowed UTF-8 payloads.
/// Each read checks bounds, the zero terminator, and UTF-8 without allocating.
pub const StringCodec = sequence.StringCodec;
/// Decode relative table offsets using a named child schema, resolved lazily.
/// Element reads check local table metadata; schema verification traverses its fields.
pub const TableCodec = sequence.TableCodec;
/// Interpret contiguous inline struct elements using their explicit wire layout.
/// Native values and borrowed element views are distinct; native ABI layout is not copied.
pub const StructCodec = sequence.StructCodec;
/// Derive native `Value`, explicit Builder `Handle`, and borrowed payload `View` types.
/// Tags must be an exhaustive u8 enum with `none = 0` and matching alternative names.
/// Handles belong to the originating builder; views borrow the complete input frame.
pub const Union = unions.Union;
/// Describe one union using adjacent physical discriminator and payload field IDs.
/// Native `Union.Value` uses `.none` for absence; explicit construction uses `Union.Handle`.
pub const UnionField = schema.UnionField;
/// Describe adjacent discriminator/payload vector slots for nullable native union values.
/// Null is absent; an empty slice is present. Explicit construction uses `Builder.UnionVector`.
pub const UnionVectorField = schema.UnionVectorField;
/// Borrow paired union vectors without allocating another array.
/// Opening checks matching counts/ranges; `get` checks alternatives lazily. NONE entries
/// have zero payload offsets. Retain both vectors and their complete backing frame.
pub const UnionVectorView = unions.VectorView;
/// Local bounds, framing, scalar-tag, and union validation failures.
/// Successful local access does not verify every reachable schema field.
pub const AccessError = errors.AccessError;
/// Access failures plus fixed-size replacement, UTF-8, and source-aliasing restrictions.
/// Rejected replacements leave target bytes unchanged. Field replacement returns false for absence.
pub const MutationError = errors.MutationError;
/// Construction state, capacity, required-presence, offset, input, and traversal failures.
/// `NoSpaceLeft` means supplied storage is too small; `BufferTooLarge` exceeds the runtime limit.
/// Allocating serialization can additionally return `error.OutOfMemory`.
pub const BuildError = errors.BuildError;
/// Local-access failures plus missing required fields and depth/object/work-limit failures.
/// Verification traverses only known schema fields and allocates no memory.
pub const VerifyError = errors.VerifyError;

/// Byte width of the root's relative-offset slot, excluding any size prefix.
pub const root_offset_size = wire.root_offset_size;
/// Byte width of an optional FlatBuffers file identifier.
pub const file_identifier_size = wire.file_identifier_size;
/// Byte width of a table/vector relative-reference slot.
pub const field_offset_size = wire.field_offset_size;
/// Byte width of a string byte length or vector element-count prefix.
pub const sequence_length_size = wire.sequence_length_size;
/// Bytes reserved for a string's required zero terminator, outside its payload length.
pub const string_terminator_size = wire.string_terminator_size;
/// Byte width of a table's signed vtable displacement.
pub const table_header_size = wire.table_header_size;
/// Byte width of one field offset within a vtable.
pub const vtable_entry_size = wire.vtable_entry_size;
/// Bytes occupied by the vtable length and table object-size header.
pub const vtable_header_size = wire.vtable_header_size;
/// Required byte alignment for caller-owned builder storage, not every field's alignment.
pub const storage_alignment = wire.storage_alignment;
