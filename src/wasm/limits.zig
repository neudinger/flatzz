//! ABI version 1 resource bounds. No allocator can grow WebAssembly memory.
pub const input_capacity = 1024 * 1024;
pub const source_capacity = 1024 * 1024;
pub const workspace_capacity = 32 * 1024 * 1024;
pub const max_files = 64;
pub const max_path = 1024;
pub const max_depth = 32;
pub const max_objects = 100_000;
pub const max_work = 16 * 1024 * 1024;
