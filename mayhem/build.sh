#!/usr/bin/env bash
#
# mayhem/build.sh — build tomlkit's Atheris fuzz targets (Python / OSS-Fuzz adaptation).
#
# tomlkit is a PURE-PYTHON project, so we fuzz it with Atheris (libFuzzer-backed). Mayhem requires
# every target's `cmd:` to be an ELF binary, so each Atheris harness gets a tiny compiled ELF shim
# (mayhem/launcher.c) that exec()s `python3 <harness>.py` and forwards argv. The exec'd Python
# process IS the libFuzzer target (Atheris ships its own libFuzzer).
#
# NOTE — do NOT go back to PyInstaller `--onefile` here. A frozen onefile ELF must unpack CPython +
# atheris' native .so into a writable temp dir at every start; Mayhem mounts the image READ-ONLY
# during coverage collection, so it dies with exit 255 ("Could not create temporary directory!")
# before libFuzzer starts -> a 0-edge "Run Failed" on EVERY target, while docker build and
# fuzz-smoke still pass locally. Redirecting TMPDIR to /dev/shm does not help (64 MB tmpfs, the
# bundle does not fit). The exec shim writes nothing at runtime and is read-only clean.
# Reproduce with:  docker run --read-only <image> /mayhem/fuzz-toml <seed>
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image exports
# the build contract ENV (CC/CXX/SANITIZER_FLAGS/DEBUG_FLAGS/LIB_FUZZING_ENGINE/SRC).
#
# AIR-GAPPED + IDEMPOTENT RE-RUN (SPEC §6.2 item 9 / §6.5): this script never touches the network
# and never pip-installs. Every Python dependency (atheris, dictgen, pytest, pyyaml) is installed
# into the image's SYSTEM interpreter by mayhem/Dockerfile from an in-image wheelhouse at
# $PY_WHEELHOUSE (a fixed, $HOME-independent path under /opt/toolchains). tomlkit itself is NOT
# installed — it is imported straight from the source tree via PYTHONPATH=/mayhem (set as ENV in
# the Dockerfile), so a PATCH-tier agent's edits under /mayhem/tomlkit take effect immediately and
# nothing depends on $HOME. All this script does is compile ELF shims + copy an interpreter, so
# re-running it offline on an already-built tree succeeds.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build contract from the env, with parameter-expansion fallbacks (no if-plumbing).
# SANITIZER_FLAGS uses `=` (kept when explicitly empty); the rest use `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info, version < 4 (Mayhem triage can't read DWARF >= 4; clang-19's
# plain `-g` emits DWARF-5, so -gdwarf-3 is explicit) — SPEC §6.2 item 10.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# tomlkit has no native code: $SANITIZER_FLAGS would only instrument the exec shim, never the fuzzed
# Python. The fuzzed code is instrumented at import time by atheris.instrument_imports() inside each
# harness, which is where coverage and findings actually come from. Echoed for parity / visibility of
# an override.
echo "SANITIZER_FLAGS=${SANITIZER_FLAGS:-<unset>} (pure-Python project; not applied to the exec shims)"
echo "DEBUG_FLAGS=$DEBUG_FLAGS"

# Sanity: the deps the harnesses need must already be in the image (installed by the Dockerfile).
python3 -c 'import atheris, dictgen' >/dev/null
PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import tomlkit, tomlkit.parser, tomlkit.api' >/dev/null

# ── 0) DWARF-3 marker + injector ───────────────────────────────────────────────────────────────
# PyInstaller ships a PREBUILT, stripped bootloader, so a frozen target carries no debug info at
# all. Mayhem's triage needs DWARF < 4 (SPEC §6.2 item 10), so we compile a tiny -gdwarf-3 object
# and graft its debug sections onto each frozen ELF. (The compiled launcher shims below get real
# DWARF-3 from clang directly and need no grafting.)
MARKER_DIR="$(mktemp -d)"
printf 'int _mayhem_triage_marker(int x){ return x + 1; }\n' > "$MARKER_DIR/marker.c"
# shellcheck disable=SC2086
$CC $DEBUG_FLAGS -O0 -c "$MARKER_DIR/marker.c" -o "$MARKER_DIR/marker.o"
for s in info abbrev str line; do
  objcopy --dump-section ".debug_$s=$MARKER_DIR/d_$s.bin" "$MARKER_DIR/marker.o" 2>/dev/null || : > "$MARKER_DIR/d_$s.bin"
done
inject_dwarf() {
  local bin="$1"
  objcopy \
    --add-section .debug_info="$MARKER_DIR/d_info.bin"     --set-section-flags .debug_info=readonly,debug \
    --add-section .debug_abbrev="$MARKER_DIR/d_abbrev.bin" --set-section-flags .debug_abbrev=readonly,debug \
    --add-section .debug_str="$MARKER_DIR/d_str.bin"       --set-section-flags .debug_str=readonly,debug \
    --add-section .debug_line="$MARKER_DIR/d_line.bin"     --set-section-flags .debug_line=readonly,debug \
    "$bin" "$bin.dbg"
  mv "$bin.dbg" "$bin"
}

# ── 1) ELF launcher shims: one per Mayhem target, named after the target slug ──────────────────
# Dynamically linked (default) so the verify-repo sabotage oracle's LD_PRELOAD can reach them.
build_launcher() {
  local out="$1" script="$2"
  echo "--- compiling launcher /mayhem/$out -> $script ---"
  # shellcheck disable=SC2086
  "$CC" $DEBUG_FLAGS -O1 -DPY_SCRIPT="\"$script\"" -o "$SRC/$out" mayhem/launcher.c
  chmod +x "$SRC/$out"
}

# target slug        harness
build_launcher fuzz-toml   "$SRC/mayhem/fuzz_toml.py"
build_launcher fuzz-parser "$SRC/mayhem/fuzz_parser.py"
build_launcher fuzz-dumps  "$SRC/mayhem/fuzz_dumps.py"

# ── 2) Standalone (non-fuzzer) reproducers ─────────────────────────────────────────────────────
# Atheris runs a single input once when handed a file path, so the same shim doubles as the
# run-once reproducer; ship it under the canonical `-standalone` name so the repro artifact is
# discoverable (SPEC §6.3). Not a Mayhem target.
for t in fuzz-toml fuzz-parser fuzz-dumps; do
  cp "$SRC/$t" "$SRC/$t-standalone"
  chmod +x "$SRC/$t-standalone"
done

# ── 2b) FROZEN (PyInstaller --onedir) target binaries — the ones Mayhem actually fuzzes ─────────
# WHY frozen, and why --onedir specifically:
#   * Mayhem only records `edges_covered` for this repo when the target is a FROZEN interpreter
#     image: every historical run of the exec-shim/`python3 harness.py` form fuzzed fine (millions
#     of execs) but reported edges=0, while the PyInstaller-frozen fuzz-toml reported 447-1286.
#   * `--onefile` MUST NOT be used: its bootloader unpacks CPython + atheris' native .so into a
#     writable temp dir at every start, and Mayhem mounts the image READ-ONLY for coverage
#     collection -> "Could not create temporary directory!" / exit 255 before libFuzzer starts
#     (that is exactly what broke runs 3/3/13). `--onedir` unpacks NOTHING at runtime: the
#     bootloader loads its `_internal/` directory in place, so it is read-only clean.
# Reproduce the read-only behaviour with:
#   docker run --read-only <image> /mayhem/frozen/fuzz-toml/fuzz-toml <seed>
FROZEN_DIR="$SRC/frozen"
PYI_WORK="$(mktemp -d)"
freeze() {
  local name="$1" script="$2"
  echo "--- freezing $script -> $FROZEN_DIR/$name/$name (PyInstaller --onedir) ---"
  pyinstaller --noconfirm --clean \
    --distpath "$FROZEN_DIR" --workpath "$PYI_WORK/$name" --specpath "$PYI_WORK" \
    --name "$name" \
    --paths "$SRC/mayhem" --paths "$SRC" \
    --hidden-import tomlkit --hidden-import tomlkit.api --hidden-import tomlkit.parser \
    --hidden-import tomlkit.exceptions --hidden-import dictgen --hidden-import fuzz_helpers \
    "$script"
  inject_dwarf "$FROZEN_DIR/$name/$name"
  chmod +x "$FROZEN_DIR/$name/$name"
  # Run-once reproducer: same frozen binary, kept INSIDE its dist dir so it still finds _internal/.
  cp "$FROZEN_DIR/$name/$name" "$FROZEN_DIR/$name/$name-standalone"
  chmod +x "$FROZEN_DIR/$name/$name-standalone"
}
freeze fuzz-toml   "$SRC/mayhem/fuzz_toml.py"
freeze fuzz-parser "$SRC/mayhem/fuzz_parser.py"
freeze fuzz-dumps  "$SRC/mayhem/fuzz_dumps.py"

# ── 3) Project-owned interpreter for test.sh's functional oracle ───────────────────────────────
# We COPY the real CPython binary (not a symlink) to a fixed path under $SRC. This matters for the
# anti-reward-hack sabotage check (SPEC §6.3): the verify-repo neuter LD_PRELOADs a shim that
# _exit(0)s every NON-system executable. The system /usr/bin/python3 is a SPARED path, so driving
# the suite through it would let a neutered program still "pass" (a blind oracle). A COPIED
# interpreter at $SRC/bin/python3 IS a non-system path -> the neuter kills it before any tomlkit
# code runs -> pytest produces no results -> test.sh fails, proving the oracle asserts behavior.
# (A bare binary copy keeps sys.prefix=/usr and reuses the system site-packages.)
PYREAL="$(readlink -f "$(command -v python3)")"
mkdir -p "$SRC/bin"
cp "$PYREAL" "$SRC/bin/python3"
chmod +x "$SRC/bin/python3"
PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}" "$SRC/bin/python3" -c 'import tomlkit, pytest' >/dev/null

# ── 4) Tests: tomlkit's suite is pure-Python pytest (nothing to compile) ───────────────────────
# pytest + pyyaml are installed by the Dockerfile and the toml-test known-answer corpus is baked
# into /mayhem/tests/toml-test, so mayhem/test.sh only RUNS pytest.

echo ">> build.sh complete:"
ls -la "$SRC"/fuzz-toml "$SRC"/fuzz-parser "$SRC"/fuzz-dumps "$SRC"/fuzz-*-standalone
