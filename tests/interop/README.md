# Local interoperability checks

The normal `zig build test` consumes nineteen small reference fixtures in
`tests/testdata`. It needs no C/C++/Go tools or network access.

The Zig test entry point is `tests/test_all.zig`. Test helpers, compile-fail
cases, benchmarks, Graph/Packet/ArrayPacket/UnionPacket schemas, and interop tools all live
under `tests/`; `src/` contains only application and runtime code.

To regenerate them, keep the pinned `flatbuffers` and `flatcc` checkouts beside
`flatzz`, build a `flatcc` compiler, and run from the Flatzz directory:

```sh
python3 tests/interop/regenerate.py \
    --zig /path/to/zig-0.17.0 \
    --flatcc /path/to/flatcc
```

Python 3, a C11 compiler, a C++17 compiler, and Go are required. Use `--cc`,
`--cxx`, and `--go` to select executables. On macOS, `--sdk /path/to/MacOSX.sdk`
can select a compatible SDK explicitly. All compilation occurs in temporary
storage. Go uses the local package in GOPATH mode; nothing is downloaded.

Use `--output-directory /path/to/temporary/fixtures` to check both directions
without replacing `tests/testdata`. The script runs the Zig regression suite
in a temporary copy containing the new reference fixtures. Zig 0.17 cache
selection uses `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR`; the old build
cache arguments are no longer accepted.

The upgrade was checked with Zig 0.17.0 on ARM64 macOS using the installed
MacOSX26.1 SDK. The upgrade baseline passed `debug`, `safe`, `fast`, and `small`.
The 2026-10-10 struct/vector/array additions pass 63 tests in `debug`, `safe`, and
`fast`, plus compile-only `x86-linux` and `s390x-linux`. The union additions pass
81 behavior tests and 28 compile-fail contracts in the same native modes, and
the same cross-compilation checks. The shared root, storage, and borrowing helpers
pass 86 behavior tests and 35 compile-fail contracts in `debug`, `safe`, and
`fast`, with the same cross-compilation checks. Foreign execution remains unverified.
`zig build check -Dtarget=...` compiles the example, tests, benchmark, producer,
and 35 compile-fail contracts without running foreign executables.
`zig build fmt` checks source formatting and `zig build docs` generates the public
API reference in `zig-out/docs`. ZLS `0.18.0-dev.16+432aaf8e` was checked with
Zig 0.17.0 for public exports, methods, and option-field hover documentation.

The script:

1. Builds Reading, Graph, Packet, ArrayPacket, and UnionPacket with Zig's runtime.
2. Checks those buffers with the official C++ reader/verifier and builds
   equivalent buffers using its builder, including shared references and
   size-prefixed Graph frames with and without the `GRPH` identifier.
3. Generates C readers/builders/verifiers with flatcc, verifies Zig buffers,
   and reconstructs them through flatcc's independent builder. Prefixed frames use
   its size-aware verifier and the `flatcc_builder_with_size` builder flag.
4. Checks Zig buffers using the Go reader and builds equivalent Go buffers.
5. Replaces the nineteen fixture files and runs the Zig regression suite against
   them. Byte-for-byte equivalence between producers is not required.

`flatbuf/reading.fbs` covers booleans, an unknown future enum tag, optional scalar
zero, scalar/string vectors, empty strings, UTF-8, and a 12-byte inline Location
with nested Coordinates. `tests/flatbuf/structs.fbs` adds required/optional inline
structs, eight-byte alignment, internal/tail padding, nested structs, and reordered
native Zig members. Each reference implementation produces a Packet fixture.
`tests/flatbuf/arrays.fbs` adds vectors of padded structs, an empty struct vector,
fixed scalar/bool/enum arrays, arrays of nested structs, and struct-vector elements
containing arrays. Each implementation produces an ArrayPacket fixture. The
empty C++ vector deliberately exercises an unaligned unused payload address;
only its count prefix needs alignment when no elements exist. The original
thirteen fixtures are unchanged by this addition.

`tests/flatbuf/unions.fbs` adds table, padded-struct, string, and repeated-type
alternatives, paired union vectors with a NONE element, required unions, and
present empty required vectors. Zig verifies all three new reference buffers,
decodes every alternative, and mutates shared table/struct payloads. The sixteen
previous fixtures are unchanged. Flatcc union readers expose a generic string
pointer to its length prefix; the harness uses `string_cast_from_union` before
comparing text. Union construction uses explicit generated builder calls because
the pinned generated union-vector clone rejects NONE payload handles. C++ and Go
use their raw runtime primitives, including literal zero offset slots for NONE;
Go generator support for advanced unions is not asserted by this test.

Unknown union tags fail explicitly with `UnknownUnionTag`. This is stricter than
reference verifiers that accept unrecognized future alternatives. Union fields
require an absent value for NONE; vectors require a zero offset at NONE elements.
The public typed builders coordinate these pairs. Mutable borrowed payload views
support table/struct member updates; changing alternatives requires rebuilding.

The runnable Reading example also uses `history:[Location]` and a Calibration
struct containing fixed arrays. The older Reading reference fixtures omit these
new optional fields, which additionally checks backward-compatible table reads.
The same schema now also defines ReadingMessage with mixed union alternatives;
`zig build run` prints each alternative and demonstrates shared-payload mutation.
`tests/flatbuf/graph.fbs`
covers heterogeneous nested tables, a finite recursive schema, shared table references, required
fields, and arbitrary bytes. The C++ and Go adapters are handwritten test code;
the C adapters are generated from the schemas. Four additional C++/flatcc Graph
fixtures exercise prefixed framing and u64 alignment. The identifier is supplied
explicitly by the harness; the Graph schema itself is unchanged. Go framing
interoperability currently covers ordinary buffers only.

The prefix remains inside Flatzz's borrowed frame slice. Open prefixed input
with `Table.from(bytes, .{ .framed_root = .{ .format = .size_prefixed } })`;
pass the same framing options as `Verifier.Options.frame`. An expected identifier
is optional. The default `.exact` boundary rejects trailing bytes. `.first`
opens one declared frame and leaves `bytes[table.bytes.len..]` for the next call.

Reference revisions:

- FlatBuffers: `b8431fbcd7a5c71817f314e18b332c0648554efa`.
- flatcc: `e1272290b486fdd7fdc60f061036b7a18c468dc7`.

These checks preserve Flatzz's stricter UTF-8 policy and fixed-size mutation
contract. Go is checked through its reader/builder, without claiming a full
schema-verification API equivalent to C++ or flatcc.
