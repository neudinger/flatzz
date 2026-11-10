# Flatzz examples

Use Zig 0.17.0. Zig fetches the pinned Zast package for examples that use schema tooling.
Serialization storage is either allocator-owned or sized with
`comptime flatzz.storage.capacityFor(Schema, value, .{})`. Text output uses
allocator-owned writers. No example chooses an arbitrary byte-buffer capacity.

`zig build examples` compiles the native Zig examples and their tests.
The sibling `flatzz-site` project discovers these sources automatically and prepares
its own website catalogue, generated schemas, and copyable source pages.

Run these commands from the Flatzz root:

| Command | Action |
| --- | --- |
| `zig build run-readme` | Generate Rocket; allocate, serialize, read, and edit the README example |
| `zig build run-mission` | Generate Mission from two linked FBS files; serialize and read its name and position |
| `zig build run-monster` | Generate Monster; serialize and read its struct, defaults, vector, enum, and union |
| `(cd example/mission && zig build run)` | Build Mission as an independent project with comptime-sized storage |
| `(cd example/monster && zig build run)` | Build Monster as an independent project with comptime-sized storage |
| `(cd example/generated && zig build run)` | Generate Reading; serialize with buffers sized at comptime |
| `(cd example/builder && zig build run)` | Generate Reading; run construction, mutation, and unions with Builder |
| `(cd example/reflection && zig build run)` | Parse FBS into reflection metadata without Zast |
| `(cd example/schema_json && zig build run)` | Generate BFBS/JSON and print output paths |

The README, Mission, and Monster examples run from the root. Their tests are included
in `zig build test`, and `zig build check` compiles their executables and tests.
Mission and Monster also have their own `build.zig` and `build.zig.zon`.
See [Copyable examples](../docs/examples.md) for the README example's complete source and schema.

From an example directory with its own `build.zig`:

| Command | Action |
| --- | --- |
| `zig build` | Install the executable in `zig-out/` (some examples also install generated files) |
| `zig build run` | Generate the schema, build, and run the example |
| `zig build test` | Run the Mission or Monster tests |
| `zig build check` | Compile this example without running it |
| `zig build check -Dtarget=x86_64-linux-musl` | Check cross-compilation |
| `zig build --help` | List targets and options |
