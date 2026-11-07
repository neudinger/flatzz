# Flatzz

Run from this directory with Zig 0.17.0. Zig fetches the pinned Zast package for schema tooling.

| Command | Action |
| --- | --- |
| `zig build` | Install both apps, generated Reading, and the schema tool |
| `zig build run` | Generate Reading; serialize native values and unions using only the runtime |
| `zig build run-builder` | Run construction, mutation, and unions with Builder |
| `zig build check` | Compile examples, tests, and contracts |
| `zig build test` | Test native runtime, FBS parsing, generated Zig, and contracts |
| `zig build fmt` | Check Zig formatting |
| `zig build docs` | Generate runtime API docs in `zig-out/docs` |
| `zig build check test -Dschema-tools=false` | Check and test runtime/compiler APIs without Zast |
| `zig build generate-reading` | Regenerate `tests/fixtures/reading/reading.zig` |
| `zig build --help` | List targets and options |

Independent examples, each with its own build: [example/README.md](example/README.md).
