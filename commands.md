zig build -Dschema-tools=true

# Generate BFBS.
zig-out/bin/flatzz --bfbs tests/fixtures/reading/reading.fbs > reading.bfbs

# Generate schema JSON.
zig-out/bin/flatzz --json tests/fixtures/reading/reading.fbs > reading.json

zig-out/bin/flatzz --json \
    -I flatbuf \
    -I other/schemas \
    path/to/schema.fbs > schema.json