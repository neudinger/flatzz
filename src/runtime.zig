//! Native FlatBuffers runtime for borrowed access, construction, and verification.
//! Schema facts for buffer access belong in generated-style modules.
//! Local checked access, mutation, construction and full known-schema
//! verification have separate contracts; none loads BFBS at application runtime.
//!
//! Import this package with `const flatzz = @import("flatzz");`.
//! Native structs describe values; `Schema` descriptors supply wire IDs and
//! defaults. Borrowed views retain the complete buffer, which must outlive them.
//! Builders write into caller-owned aligned storage and allocate no heap memory.
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
//! };
//! const label = "sensor";
//! var storage: flatzz.Storage(Reading.Schema, .{ .label = label.len }, .{}) = .{};
//! const bytes = try Reading.Schema.writeRoot(&storage.buffer, .{
//!     .value = 41,
//!     .label = label,
//! }, .{});
//! try Reading.Schema.verifyRoot(bytes, .{});
//! try std.testing.expect(try Reading.Schema.updateRoot(bytes, .value, 42));
//! const reading = try Reading.Schema.readRoot(bytes);
//! try std.testing.expectEqual(@as(u32, 42), reading.value);
//! try std.testing.expectEqualStrings("sensor", reading.label.?);
//! ```
//! Expected result: a verified table containing `42` and `"sensor"`; no output.
//! `bytes` and `reading.label` borrow `storage`. No `deinit` is needed.

const views = @import("runtime/table_view.zig");
const sequences = @import("runtime/sequence.zig");
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
/// Select a checked borrowed table type with read-only or mutable access.
pub const TableView = views.TableView;
/// Select a root frame or an absolute table position within a complete buffer.
pub const TableSource = views.Source;
/// Compile-time capability used by borrowed table, struct, and vector views.
pub const Access = views.Access;
/// Checked read-only table metadata borrowing a complete frame.
pub const Table = TableView(.read_only);
/// Checked table metadata borrowing mutable bytes; updates retain wire sizes.
pub const MutableTable = TableView(.mutable);
/// Backward builder using caller-owned aligned storage; handles expire on reset.
pub const Builder = @import("runtime/Builder.zig");
/// Table construction with a compile-time number of physical field slots.
pub const TableBuilder = @import("runtime/table_builder.zig").TableBuilder;
/// Recursive known-schema verification with configurable depth and work limits.
pub const Verifier = @import("runtime/Verifier.zig");
/// Derive typed read, write, mutation, and verification adapters from descriptors.
pub const Schema = schema.Schema;
/// Root-writing policy; `force_defaults` retains default-valued scalar slots.
pub const WriteOptions = schema.WriteOptions;
/// Derive aligned storage from schema facts and explicit sequence capacities.
pub const Storage = storage.Storage;
/// Describe a scalar field's native type, physical ID, and default value.
pub const ScalarField = schema.ScalarField;
/// Describe a string, vector, or table reference, optionally required.
pub const ReferenceField = schema.ReferenceField;
/// Describe an inline struct field, including its layout and presence policy.
pub const StructField = schema.StructField;
/// Describe a fixed-size FlatBuffers struct independently of native Zig layout.
pub const StructLayout = @import("runtime/struct_layout.zig").StructLayout;
/// Describe one scalar member at a fixed byte offset within a wire struct.
pub const ScalarMember = @import("runtime/struct_layout.zig").ScalarMember;
/// Describe a nested fixed-size struct member at a wire byte offset.
pub const StructMember = @import("runtime/struct_layout.zig").StructMember;
/// Describe a fixed-length scalar or struct array within a wire struct.
pub const ArrayMember = @import("runtime/struct_layout.zig").ArrayMember;
/// Select a borrowed struct view with read-only or mutable access.
pub const StructView = @import("runtime/struct_view.zig").StructView;
/// Select a borrowed fixed-length array view with schema-defined bounds.
pub const ArrayView = @import("runtime/struct_view.zig").ArrayView;
/// Read-only checked vector view; elements are decoded lazily by its codec.
pub const Vector = sequences.Sequence;
/// Select a checked vector view, including mutable inline struct elements.
pub const VectorView = sequences.SequenceView;
/// Vector encoding for a supported FlatBuffers scalar or enum type.
pub const ScalarCodec = sequences.ScalarCodec;
/// Vector encoding for UTF-8 strings referenced by relative offsets.
pub const StringCodec = sequences.StringCodec;
/// Vector encoding for referenced tables with a named schema type.
pub const TableCodec = sequences.TableCodec;
/// Vector encoding for contiguous inline structs with an explicit layout.
pub const StructCodec = sequences.StructCodec;
/// Derive tagged native handles and borrowed views for supported union members.
pub const Union = @import("runtime/unions.zig").Union;
/// Describe a union using adjacent discriminator and payload field IDs.
pub const UnionField = schema.UnionField;
/// Describe a union vector using paired discriminator and payload vectors.
pub const UnionVectorField = schema.UnionVectorField;
/// Borrow paired union vectors; NONE entries have zero payload offsets.
pub const UnionVectorView = @import("runtime/unions.zig").VectorView;
/// Malformed or unsupported wire data encountered by local checked access.
pub const AccessError = errors.AccessError;
/// Checked access errors and failures of fixed-size in-place replacement.
pub const MutationError = errors.MutationError;
/// Invalid construction, exhausted storage, and invalid scalar/string values.
pub const BuildError = errors.BuildError;
/// Checked access errors plus recursive verifier resource-limit failures.
pub const VerifyError = errors.VerifyError;

/// Read a little-endian scalar at an absolute buffer position with bounds checks.
pub const read = validation.readScalar;
/// Write a scalar at an absolute buffer position after checking its bounds.
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
