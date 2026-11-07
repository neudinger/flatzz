//! Native FlatBuffers runtime for generated and handwritten schemas.
//! Schema facts for buffer access belong in generated-style modules.
//! Local checked access, mutation, construction and full known-schema
//! verification have separate contracts; none loads BFBS at application runtime.
//!
//! Import this package with `const flatzz = @import("flatzz");`.
//! Schema processing now lives in `@import("flatzz_compiler")`, which exports
//! `parser`, `reflection`, and `bfbs` separately from the runtime.
//! Native structs describe values; `Schema` descriptors supply wire IDs and
//! defaults. Borrowed views retain the complete buffer, which must outlive them.
//! Builders write into caller-owned aligned storage and allocate no heap memory.
//! Every generated table exposes `serialize` for supported native fields: scalars,
//! strings, structs, child tables, unions, and their vectors. Struct arrays follow
//! their layout. Table inputs use pointers; union values contain native payloads.
//! Recursive packing uses one builder and bounded traversal. Temporary vector
//! offsets reuse final output capacity, without an additional scratch budget.
//! Repeated native pointers are encoded separately; explicit handles preserve sharing.
//! Use `Schema.create(builder, value, options)` to pack into an existing builder. For manual
//! construction, pass one named `Schema.Fields` record to `Schema.addFields`.
//! Scalars and inline structs retain native values; references contain completed
//! offsets. Union fields use `Union.Handle`; union vectors use `Builder.UnionVector`.
//! Native union inputs instead use `Union.Value`.
//! Finish the same builder; handles cannot be transferred to a fresh builder.
//!
//! Complete example inside a test with `std` and `flatzz` imported:
//! ```zig
//! const Reading = struct {
//!     value: u32 = 0,
//!     label: ?[]const u8 = null,
//!
//!     pub const Schema = flatzz.Schema(@This(), .{
//!         .value = flatzz.ScalarField(u32, 0, 0),
//!         .label = flatzz.ReferenceField(1, .string, .{}),
//!     });
//!     pub const serialize = Schema.serialize;
//! };
//! const value: Reading = .{ .value = 41, .label = "sensor" };
//! var storage: flatzz.Storage(Reading.Schema, .{ .label = 6 }, .{}) = .{};
//! const bytes = try value.serialize(&storage.buffer, .{});
//! try Reading.Schema.verifyRoot(bytes, .{});
//! try std.testing.expect(try Reading.Schema.updateRoot(bytes, .value, 42));
//! const reading = try Reading.Schema.readRoot(bytes);
//! try std.testing.expectEqual(@as(u32, 42), reading.value);
//! try std.testing.expectEqualStrings("sensor", reading.label.?);
//! ```
//! Expected result: a verified table containing `42` and `"sensor"`; no output.
//! `bytes` and `reading.label` borrow `storage.buffer`. No `deinit` is needed.
//!
//! Alternative construction in a separate test, using the same `Reading` type:
//! ```zig
//! var storage: [128]u8 align(flatzz.storage_alignment) = undefined;
//! var builder = flatzz.Builder.init(&storage);
//! const label = try builder.createString("sensor");
//! const fields: Reading.Schema.Fields = .{ .value = 42, .label = label };
//! var table = try Reading.Schema.Context.init(&builder);
//! try Reading.Schema.addFields(&table, fields);
//! const bytes = try builder.finish(try Reading.Schema.endTable(&table), .ordinary);
//! try Reading.Schema.verifyRoot(bytes, .{});
//! const view = try Reading.Schema.readRoot(bytes);
//! try std.testing.expectEqual(@as(u32, 42), view.value);
//! try std.testing.expectEqualStrings("sensor", view.label.?);
//! ```
//! Expected result: the same values using completed handles from one builder.
//! The result borrows `storage`; resetting the builder invalidates its contents.

const table_view = @import("runtime/table_view.zig");
const sequence = @import("runtime/sequence.zig");
const table_builder = @import("runtime/table_builder.zig");
const struct_layout = @import("runtime/struct_layout.zig");
const struct_view = @import("runtime/struct_view.zig");
const unions = @import("runtime/unions.zig");
const errors = @import("runtime/errors.zig");

/// Wire sizes, scalar encodings, alignment, and checked arithmetic.
pub const wire = @import("runtime/wire.zig");
/// Checked scalar, string, offset, and sequence access to complete buffers.
pub const validation = @import("runtime/validation.zig");
/// Ordinary and size-prefixed frame boundaries and optional identifiers.
pub const framing = @import("runtime/framing.zig");
/// Compile-time field descriptors and generated access/build/verify adapters.
pub const schema = @import("runtime/schema.zig");
/// Compile-time capacity calculations for caller-owned builder storage.
pub const storage = @import("runtime/storage.zig");
/// Backward builder using caller-owned aligned storage; handles expire on reset.
pub const Builder = @import("runtime/Builder.zig");
/// Recursive known-schema verification with configurable depth and work limits.
pub const Verifier = @import("runtime/Verifier.zig");

/// Select a checked borrowed table type with read-only or mutable access.
pub const TableView = table_view.TableView;
/// Select an ordinary root, custom framing options, or an absolute table position.
pub const TableSource = table_view.Source;
/// Compile-time capability used by borrowed table, struct, and vector views.
pub const Access = table_view.Access;
/// Checked read-only table metadata borrowing a complete frame.
pub const Table = TableView(.read_only);
/// Checked table metadata borrowing mutable bytes; updates retain wire sizes.
pub const MutableTable = TableView(.mutable);
/// Table construction with a compile-time number of physical field slots.
pub const TableBuilder = table_builder.TableBuilder;
/// Derive typed read, write, mutation, and verification adapters from descriptors.
pub const Schema = schema.Schema;
/// Native serialization policy and traversal limits; defaults can retain scalar slots.
pub const WriteOptions = schema.WriteOptions;
/// Derive aligned caller-owned storage from schema facts and explicit capacities.
/// String capacities count payload bytes; vectors use element counts or count/byte records.
pub const Storage = storage.Storage;
/// Describe a scalar field's native type, physical ID, and default value.
pub const ScalarField = schema.ScalarField;
/// Describe a string, vector, or table reference, optionally required.
pub const ReferenceField = schema.ReferenceField;
/// Describe an inline struct field, including its layout and presence policy.
pub const StructField = schema.StructField;
/// Describe a fixed-size FlatBuffers struct independently of native Zig layout.
pub const StructLayout = struct_layout.StructLayout;
/// Describe one scalar member at a fixed byte offset within a wire struct.
pub const ScalarMember = struct_layout.ScalarMember;
/// Describe a nested fixed-size struct member at a wire byte offset.
pub const StructMember = struct_layout.StructMember;
/// Describe a fixed-length scalar or struct array within a wire struct.
pub const ArrayMember = struct_layout.ArrayMember;
/// Select a borrowed struct view with read-only or mutable access.
pub const StructView = struct_view.StructView;
/// Select a borrowed fixed-length array view with schema-defined bounds.
pub const ArrayView = struct_view.ArrayView;
/// Select a checked vector view, including mutable inline struct elements.
pub const VectorView = sequence.SequenceView;
/// Vector encoding for a supported FlatBuffers scalar or enum type.
pub const ScalarCodec = sequence.ScalarCodec;
/// Vector encoding for UTF-8 strings referenced by relative offsets.
pub const StringCodec = sequence.StringCodec;
/// Vector encoding for referenced tables with a named schema type.
pub const TableCodec = sequence.TableCodec;
/// Vector encoding for contiguous inline structs with an explicit layout.
pub const StructCodec = sequence.StructCodec;
/// Derive native union values, explicit Builder handles, and borrowed payload views.
pub const Union = unions.Union;
/// Describe a union using adjacent discriminator and payload field IDs.
pub const UnionField = schema.UnionField;
/// Describe a union vector using paired discriminator and payload vectors.
pub const UnionVectorField = schema.UnionVectorField;
/// Borrow paired union vectors; NONE entries have zero payload offsets.
pub const UnionVectorView = unions.VectorView;
/// Malformed or unsupported wire data encountered by local checked access.
pub const AccessError = errors.AccessError;
/// Checked access errors and failures of fixed-size in-place replacement.
pub const MutationError = errors.MutationError;
/// Invalid construction, exhausted storage, and invalid scalar/string values.
pub const BuildError = errors.BuildError;
/// Checked access errors plus recursive verifier resource-limit failures.
pub const VerifyError = errors.VerifyError;

/// Copy a bounds-checked little-endian scalar at an absolute byte position.
/// Unaligned input is supported; unknown exhaustive-enum tags return InvalidBuffer.
pub const read = validation.readScalar;
/// Write a little-endian scalar after checking its byte range; no alignment is required.
/// OutOfBounds leaves bytes unchanged. This does not create an absent schema field.
pub const write = validation.writeScalar;
/// Bytes occupied by the root relative offset.
pub const root_offset_size = wire.root_offset_size;
/// Bytes in an optional FlatBuffers file identifier.
pub const file_identifier_size = wire.file_identifier_size;
/// Bytes in a table/vector relative reference.
pub const field_offset_size = wire.field_offset_size;
/// Bytes in a string or vector element-count prefix.
pub const sequence_length_size = wire.sequence_length_size;
/// Bytes reserved for a string's required zero terminator.
pub const string_terminator_size = wire.string_terminator_size;
/// Bytes in a table's signed vtable displacement.
pub const table_header_size = wire.table_header_size;
/// Bytes in one vtable field offset.
pub const vtable_entry_size = wire.vtable_entry_size;
/// Bytes in the vtable length and object-size header.
pub const vtable_header_size = wire.vtable_header_size;
/// Alignment required for caller-owned builder storage.
pub const storage_alignment = wire.storage_alignment;
