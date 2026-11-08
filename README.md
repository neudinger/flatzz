# Flatzz

Run from this directory with Zig 0.17.0. Zig fetches the pinned Zast package for schema tooling.

| Command | Action |
| --- | --- |
| `zig build` | Install both apps, generated Reading, and the schema tool |
| `zig build run` | Generate Reading; serialize with buffers sized at comptime |
| `zig build run-builder` | Run construction, mutation, and unions with Builder |
| `zig build check` | Compile examples, tests, and contracts |
| `zig build test` | Test native runtime, FBS parsing, generated Zig, and contracts |
| `zig build fmt` | Check Zig formatting |
| `zig build docs` | Generate runtime API docs in `zig-out/docs` |
| `zig build check test -Dschema-tools=false` | Check and test runtime/compiler APIs without Zast |
| `zig build generate-reading` | Regenerate `tests/fixtures/reading/reading.zig` |
| `zig build --help` | List targets and options |

Independent examples, each with its own build: [example/README.md](example/README.md).

## Implementation layout

The public entry points are [runtime.zig](src/runtime.zig) (`flatzz`) and
[compiler.zig](src/compiler.zig) (`flatzz_compiler`). Applications can use the
runtime, FBS parser, reflection model, and BFBS codec without Zast. Zig source
generation uses a separate host backend; generated modules import only `flatzz`.

| Responsibility | Implementation |
| --- | --- |
| Descriptors, schema composition, and public adapters | [schema.zig](src/runtime/schema.zig) |
| Native graph preflight and packing | [native_graph.zig](src/runtime/schema/native_graph.zig) |
| Checked local buffer access, ranges, and scalar reads/writes | [buffer_access.zig](src/runtime/buffer_access.zig) |
| Result types and field reads from checked tables | [field_access.zig](src/runtime/schema/field_access.zig) |
| Storage bounds, native sizing, and owned serialized buffers | [storage.zig](src/runtime/storage.zig) |
| Buffer construction and table state | [Builder.zig](src/runtime/Builder.zig), [table_builder.zig](src/runtime/table_builder.zig) |
| Known-schema wire traversal and resource limits | [Verifier.zig](src/runtime/Verifier.zig) |
| Public FBS API, diagnostics, and options | [parser.zig](src/compiler/parser.zig) |
| Compiler and parser tests | [test_compiler.zig](tests/test_compiler.zig), [test_parser.zig](tests/test_parser.zig) |
| Sources, symbols, semantic resolution, defaults, and layout | [Compilation.zig](src/compiler/fbs/Compilation.zig) |
| Source cursor and declaration grammar | [Parser.zig](src/compiler/fbs/Parser.zig) |
| Shared unresolved declarations and spelling helpers | [model.zig](src/compiler/fbs/model.zig) |
| Reflection records and primitive facts | [reflection.zig](src/compiler/reflection.zig) |
| Public BFBS API, encoding, decoding, and shared record layout | [bfbs.zig](src/compiler/bfbs.zig), [Encoder.zig](src/compiler/bfbs/Encoder.zig), [Decoder.zig](src/compiler/bfbs/Decoder.zig), [record_layout.zig](src/compiler/bfbs/record_layout.zig) |
| Source generation lifetime, lowering, and scratch expression construction | [codegen.zig](src/compiler/codegen.zig), [Generator.zig](src/compiler/codegen/Generator.zig), [Syntax.zig](src/compiler/codegen/Syntax.zig) |

Descriptor factories remain in `schema.zig`, preserving their type names and lazy
recursive references. `native_graph` owns preflight and packing, recursing through
the existing descriptor and table-construction contract without adding public schema
methods. It shares presence and work-accounting policy with `schema.zig` through
lazy imports. Field access accepts already checked tables; its callers select framing
and read-only or mutable access.
Storage sizing, native alias preflight, packing, and wire verification retain their
separate validation contracts.

FBS parsing uses the caller's arena for copied sources, unresolved declarations,
metadata, and diagnostics. Keep that arena alive until all consumers finish.
Includes follow `Compilation.load -> Parser -> Compilation.load` directly.
Public types stay in the parser facade; internal modules use the same identities.
BFBS encoding owns its growing buffer and completed handles; decoding copies
metadata into the caller's arena and retains its own traversal limits and object
identity cache. The documented BFBS facade retains the public errors and options.
Code generation borrows its input schema and owns one temporary scratch arena
through AST finalization. `Generator` and `Syntax` borrow that allocator; `Syntax`
copies temporary child lists into the arena. The returned formatted source is separately owned by
the caller and freed with its allocator.

Builders use caller-owned buffers. `serializeAlloc` returns a `Serialized` owner
that must be released once with the same allocator. Borrowed views expire when
their backing storage is reused or released; structural edits invalidate checked
table metadata. Use explicit Builder handles when table sharing is required.

Further Scanner, name-handling, Builder, and storage splits remain deferred.
The current boundaries follow ownership and validation responsibilities rather
than a maximum file size.
