#!/usr/bin/env python3
"""Regenerate small reference fixtures using local checkouts, without downloads."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--zig", default="zig")
parser.add_argument("--flatcc", required=True)
parser.add_argument("--cc", default="clang")
parser.add_argument("--cxx", default="clang++")
parser.add_argument("--go", default="go")
parser.add_argument("--sdk", help="optional macOS SDK path for C/C++ compilers")
parser.add_argument("--output-directory", type=Path,
                    help="write and test fixtures here instead of replacing testdata")
options = parser.parse_args()
project = Path(__file__).resolve().parents[2]
flatbuffers = project.parent / "flatbuffers"
flatcc = project.parent / "flatcc"
compiler = str(Path(options.flatcc).resolve())
cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR",
                           str(Path(tempfile.gettempdir()) / "flatzz-zig-cache")))
zig_environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(cache))
sdk = ["-isysroot", options.sdk] if options.sdk else []

def run(arguments, directory, environment=None):
    subprocess.run([str(value) for value in arguments], cwd=directory,
                   env=environment, check=True)

with tempfile.TemporaryDirectory(prefix="flatzz-interop-") as temporary:
    scratch = Path(temporary).resolve()
    generated = scratch / "generated"
    generated.mkdir()
    run([options.zig, "build", "test-produce-fixtures",
         "-Dfixture-output=" + str(scratch)],
        project, zig_environment)
    run([options.cxx, "-std=c++17", "-O2", *sdk,
         "-I", flatbuffers / "include", project / "tests/interop/roundtrip.cpp",
         "-o", scratch / "cpp-check"], scratch)
    run([scratch / "cpp-check"], scratch)
    run([compiler, "-a", "-o", generated, project / "flatbuf/reading.fbs",
         project / "tests/flatbuf/graph.fbs",
         project / "tests/flatbuf/structs.fbs",
         project / "tests/flatbuf/arrays.fbs",
         project / "tests/flatbuf/unions.fbs"], scratch)
    runtime_sources = [flatcc / "src/runtime" / (name + ".c")
                       for name in ("builder", "emitter", "refmap", "verifier")]
    run([options.cc, "-std=c11", "-O2", *sdk, "-I", flatcc / "include",
         "-I", generated, project / "tests/interop/roundtrip.c",
         *runtime_sources, "-o", scratch / "c-check"], scratch)
    run([scratch / "c-check"], scratch)
    # GOPATH mode uses only the pinned local package; no module downloads.
    go_path = scratch / "gopath"
    shutil.copytree(flatbuffers / "go", go_path / "src/flatbuffers")
    environment = dict(os.environ, GO111MODULE="off", GOPATH=str(go_path),
                       GOCACHE=str(scratch / "go-cache"), GOTOOLCHAIN="local")
    run([options.go, "run", project / "tests/interop/roundtrip.go"], scratch, environment)
    # Isolate the regression suite when checking without replacing testdata.
    verification_project = project
    destination = project / "tests/testdata"
    if options.output_directory is not None:
        destination = options.output_directory.resolve()
        destination.mkdir(parents=True, exist_ok=True)
        verification_project = scratch / "verification"
        verification_project.mkdir()
        for name in ("src", "tests"):
            shutil.copytree(project / name, verification_project / name)
        for name in ("build.zig", "build.zig.zon"):
            shutil.copyfile(project / name, verification_project / name)
    # Install only after all three reference implementations accept Zig output.
    fixture_names = [f"{language}-{schema}.bin"
                     for language in ("cpp", "c", "go")
                     for schema in ("reading", "graph", "structs", "arrays", "unions")]
    fixture_names += [f"{language}-graph-prefixed{suffix}.bin"
                      for language in ("cpp", "c") for suffix in ("", "-id")]
    for name in fixture_names:
        shutil.copyfile(scratch / name, destination / name)
        if verification_project != project:
            shutil.copyfile(scratch / name,
                            verification_project / "tests/testdata" / name)
    run([options.zig, "build", "test"],
        verification_project, zig_environment)
print(f"C++, C and Go accepted Zig output; {len(fixture_names)} fixtures verified in {destination}.")
