# WebAssembly compiler

Flatzz provides one freestanding `wasm32` compiler for browser workers, Node.js,
and other WebAssembly hosts. It uses the same FBS frontend, reflection model,
BFBS codec, JSON writer, and Zast-based Zig generator as the native tool.
No WASI, filesystem, network, JavaScript host imports, or compilation server is required.

| Input | Supported outputs |
| --- | --- |
| FBS source project | Zig source, schema JSON, BFBS |
| Ordinary BFBS bytes | Zig source, schema JSON |

JSON describes schema declarations and metadata, not message values. Zig output
is source to download or compile with Zig separately. The Wasm compiler does not
compile or execute that generated source. Application serialization and borrowed
buffer access remain the responsibility of the Flatzz runtime and its consumer.

## Build

From the Flatzz checkout with Zig **0.17.0**:

```sh
zig build wasm
```

The command installs `zig-out/wasm/flatzz-compiler.wasm`, built in ReleaseSafe.
The default `zig build` continues to install the native tool and examples.
Wasm compilation is reached through the explicit target, or enabled by a dependency.
All library build and test commands use Zig; JavaScript adapters, workers, browser
integration, and native/Wasm parity tests belong to the sibling `flatzz-site` project.

Runtime-only builds and dependencies do not enable the Wasm compiler or Zast:

```sh
zig build check test -Dschema-tools=false
```

To build only the Wasm compiler without exposing the native compiler:

```sh
zig build wasm -Dschema-tools=false -Dwasm-compiler=true
```

## Consume from another Zig project

Declare a `flatzz` dependency in the consumer's `build.zig.zon`. For a sibling
checkout, its dependency entry is `.flatzz = .{ .path = "../flatzz" }`.

This complete `build.zig` installs the reusable compiler artifact:

```zig
const std = @import("std");

pub fn build(builder: *std.Build) void {
    const flatzz = builder.dependency("flatzz", .{
        .@"schema-tools" = false,
        .@"wasm-compiler" = true,
    });
    const compiler = flatzz.artifact("flatzz-compiler-wasm");
    const install = builder.addInstallFile(
        compiler.getEmittedBin(),
        "site/assets/flatzz-compiler.wasm",
    );
    builder.getInstallStep().dependOn(&install.step);
}
```

This artifact always targets `wasm32-freestanding`, independently of the
consumer's application target. The consumer needs no imports of Flatzz's
internal source files and does not configure Zast itself. The `flatzz` and
`flatzz_compiler` modules retain their existing target-aware behavior.
The library exports Zig modules and the Wasm artifact. A host supplies its own ABI
adapter and presentation. `flatzz-site/wasm/compiler.mjs` is one browser/Node.js
consumer; it is maintained with that website rather than distributed by this package.

## Linked FBS files

The entry source and includes form a virtual project. Source-map keys and
filenames are project-relative POSIX paths; includes resolve relative to the
including file. `.`/`..` and repeated separators normalize before lookup.
Absolute paths, backslashes, NUL, empty identities, duplicate normalized names,
and paths escaping the virtual root are rejected. No URL fetching occurs.

Pass all files together for each conversion. Source and diagnostic filenames
are canonical virtual paths. Native CLI JSON/BFBS records absolute filesystem
identities instead; generated Zig is identical for equivalent supported schemas.
The resource-limited Wasm compiler supports the native frontend/backend's actual
feature subset, rather than every schema accepted by `flatc`. BFBS wire checking
does not establish that every represented feature is supported by Zig generation.

## Errors, memory, and workers

Diagnostics expose `code`, `message`, `filename`, `line`, and `column`;
operations return an explicit status. Parser positions are one-based UTF-8 byte
positions, with zero when unavailable. Diagnostic messages are truncated at a valid UTF-8 boundary after
at most 1024 bytes.

Read the JSON returned by `limitsPointer()` and `limitsLength()` for resource capacities:

| Limit | ABI v1 value |
| --- | --- |
| Input staging bytes | 1 MiB, including the filename prefix when adding a file |
| Copied FBS filenames and text combined | 1 MiB |
| Files per project | 64, including the entry file |
| Normalized filename bytes | 1024 |
| Compiler scratch workspace | 32 MiB, reset for every conversion |
| Parser include/inline-layout depth | 32 |
| BFBS depth / object visits / work | 32 / 100,000 / 16 MiB |

The Wasm stack is 1 MiB and the maximum linear memory is 64 MiB. No compiler
allocator grows linear memory. Compilation performs allocations inside its
fixed workspace; this is distinct from allocation-free application serialization.
Source-map storage survives conversions until reset. The host resets it for each
independent request. Failure clears output and the next independent request can recover.

The compiler is synchronous and non-reentrant. Instantiate it inside a worker
to keep the page responsive. Request IDs, debouncing, stale-response handling,
deadlines, worker replacement after a trap/timeout, and playground presentation
belong to the consuming application. No worker or website framework is imposed.

## Raw ABI v1

All addresses are unsigned byte offsets into exported `memory`. Scalar
parameters/results use `i32`; lengths are interpreted as unsigned `u32`.
Check `abiVersion() == 1` before using the other exports.

| Export | Contract |
| --- | --- |
| `abiVersion()` | Return `1` |
| `inputPointer()`, `inputCapacity()` | Writable staging buffer and byte capacity |
| `limitsPointer()`, `limitsLength()` | Read-only UTF-8 JSON resource limits |
| `reset()` | Discard all copied files, output, and diagnostics |
| `addFile(name_length, text_length)` | Copy UTF-8 filename followed by source text from staging; return status |
| `convert(input_format, output_format, input_length)` | Convert staging input; return status |
| `outputPointer()`, `outputLength()` | Raw output bytes, empty after failure |
| `diagnosticPointer()`, `diagnosticLength()` | UTF-8 JSON diagnostic, `{}` after success/reset |

Input format IDs: FBS `0`, BFBS `1`. Output format IDs: Zig `0`, JSON `1`, BFBS `2`.
BFBS-to-BFBS returns invalid-request status. Format identifiers are explicit ABI
values and do not depend on enum declaration order.

For FBS: reset, add the entry and included files, write the entry filename into
staging, then convert. For BFBS: reset, write the complete ordinary BFBS frame
into staging, then convert. Always check returned statuses, including `addFile`.
Adding files copies the bytes; later staging writes do not change saved sources.

| Status | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Invalid request, path, duplicate source, UTF-8, or format |
| `2` | Invalid/missing schema, malformed BFBS, or generation failure |
| `3` | Recognized unsupported feature |
| `4` | Input/source/path/file/depth/workspace/BFBS resource limit |

Raw output and diagnostic views expire on the next `reset`, `addFile`, or
`convert`, including failed calls. Consume or copy them first. Getters and writes
to staging do not invalidate results. Hosts that need results across independent
requests must copy them.

## Verification

`zig build check test fmt` checks native compiler behavior and generated-code contracts.
`zig build wasm` verifies that the freestanding artifact compiles. The sibling
`flatzz-site` project's `zig build test-wasm` runs the browser ABI and native/Wasm
parity suite, including all five conversions, linked files, malformed input,
resource limits, recovery, and real generated example tests.

The portable JSON writer is also exported as
`@import("flatzz_compiler").json.write` for non-Wasm consumers without introducing
a Zast dependency.
