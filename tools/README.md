# Flatzz schema tool

Run from the Flatzz root with Zig 0.17.0.

| Command | Action |
| --- | --- |
| `zig build` | Build and install apps and `zig-out/bin/flatzz-schema` |
| `zig build check test` | Check and test schema tooling and generated code |
| `zig build generate-reading` | Regenerate the checked-in Reading fixture |
| `zig-out/bin/flatzz-schema --zig tests/fixtures/reading/reading.fbs > reading.zig` | Generate Zig from FBS |
| `zig-out/bin/flatzz-schema --bfbs tests/fixtures/reading/reading.fbs > reading.bfbs` | Generate a binary schema |
| `zig-out/bin/flatzz-schema --json tests/fixtures/reading/reading.fbs > reading.json` | Generate schema JSON from FBS |
| `zig-out/bin/flatzz-schema --zig reading.bfbs > reading.zig` | Generate Zig from a binary schema |
| `zig-out/bin/flatzz-schema --json reading.bfbs > reading.json` | Decode a binary schema as JSON |
| `zig-out/bin/flatzz-schema --zig --depfile reading.d --deptarget reading.zig -I tests/fixtures/reading tests/fixtures/reading/reading.fbs > reading.zig` | Generate Zig and track included schemas |
| `zig-out/bin/flatzz-schema --help` | Show tool options |
