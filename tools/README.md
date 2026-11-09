# Flatzz schema compiler

Run from the Flatzz root with Zig 0.17.0.

| Command | Action |
| --- | --- |
| `zig build` | Build and install apps and `zig-out/bin/flatzz` |
| `zig build compiler` | Build and install only `zig-out/bin/flatzz` |
| `zig build check test` | Check and test schema tooling and generated code |
| `zig build generate-reading` | Regenerate the checked-in Reading fixture |
| `zig-out/bin/flatzz --zig tests/fixtures/reading/reading.fbs > reading.zig` | Generate Zig from FBS |
| `zig-out/bin/flatzz --bfbs tests/fixtures/reading/reading.fbs > reading.bfbs` | Generate a binary schema |
| `zig-out/bin/flatzz --json tests/fixtures/reading/reading.fbs > reading.json` | Generate schema JSON from FBS |
| `zig-out/bin/flatzz --zig reading.bfbs > reading.zig` | Generate Zig from a binary schema |
| `zig-out/bin/flatzz --json reading.bfbs > reading.json` | Decode a binary schema as JSON |
| `zig-out/bin/flatzz --zig --depfile reading.d --deptarget reading.zig -I tests/fixtures/reading tests/fixtures/reading/reading.fbs > reading.zig` | Generate Zig and track included schemas |
| `zig-out/bin/flatzz --help` | Show tool options |
