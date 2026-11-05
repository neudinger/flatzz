# Flatzz

FlatBuffers runtime for Zig. Build frames in caller-owned storage, borrow checked
views, and update fields in place.

| Command | Action |
| --- | --- |
| `zig build` | Build the runtime's Reading example |
| `zig build run` | Serialize, verify, read, and update a Reading frame |
| `zig build test` | Check wire compatibility and runtime contracts |
| `zig build docs` | Generate the runtime API reference |

The build uses Zig 0.17.0. See [the runtime API](src/runtime.zig) for a complete
schema example.
