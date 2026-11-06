# Flatzz examples

Use Zig 0.17.0. Zig fetches the pinned Zast package for examples that use schema tooling.
Run these commands from the Flatzz root:

| Command | Action |
| --- | --- |
| `(cd example/generated && zig build run)` | Generate Reading and run the runtime-only app |
| `(cd example/builder && zig build run)` | Generate Reading and run construction, mutation, and union examples |
| `(cd example/reflection && zig build run)` | Parse FBS into reflection metadata without Zast |
| `(cd example/schema_json && zig build run)` | Generate BFBS/JSON and print output paths |

From any example directory:

| Command | Action |
| --- | --- |
| `zig build` | Install this example and its generated files in `zig-out/` |
| `zig build check` | Compile this example without running it |
| `zig build check -Dtarget=x86_64-linux-musl` | Check cross-compilation |
| `zig build --help` | List targets and options |
