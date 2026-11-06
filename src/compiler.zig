//! FlatBuffers schema parsing, reflection metadata, and BFBS conversion.
//! Import this module with `const compiler = @import("flatzz_compiler");`.
//! Parsing and decoding use a caller-owned arena; retain it while consuming the
//! returned metadata and release it after success or failure. BFBS encoding returns
//! a separate aligned byte slice that the caller frees with its allocator.
//! These APIs can run in applications as well as build tools.
//! Zig source generation uses a separate host backend with an optional Zast
//! dependency; applications using only the runtime do not import this module.

/// Native FBS parsing, include loading, and diagnostics in caller-arena storage.
pub const parser = @import("compiler/parser.zig");
/// Borrowed schema metadata shared by parsing, BFBS conversion, and source generation.
pub const reflection = @import("compiler/reflection.zig");
/// Owned BFBS encoding and checked decoding into independent caller-arena metadata.
pub const bfbs = @import("compiler/bfbs.zig");
