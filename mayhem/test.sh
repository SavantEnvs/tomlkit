#!/usr/bin/env bash
#
# mayhem/test.sh — RUN tomlkit's own functional suite (pytest) and emit a CTRF summary.
#
# tomlkit ships a real, behavioral pytest suite under tests/ (known-answer TOML<->JSON round-trips from
# the BurntSushi toml-test corpus, parser/writer/items assertions, golden-output checks). This script
# only RUNS it — build.sh already installed pytest + tomlkit (it never compiles).
#
# Anti-reward-hacking (SPEC §6.3): the suite is driven through a PROJECT-OWNED interpreter copy at
# $SRC/bin/python3 (a real CPython binary copied by build.sh), NOT the system /usr/bin/python3. The
# verify-repo sabotage check LD_PRELOADs a shim that _exit(0)s every NON-system executable; the copied
# interpreter is one, so under sabotage it dies before any tomlkit code runs, pytest produces no
# results, and this script reports 0 passing tests + exits non-zero — i.e. a neutered program FAILS the
# oracle, exactly as required. A real PATCH that no-ops tomlkit would likewise break the known-answer
# assertions in tests/ (toml-test 1.1.0 round-trips, parser/writer/items checks).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# tomlkit is imported straight from the source tree (not pip-installed) — see mayhem/Dockerfile's
# PYTHONPATH ENV. Re-assert it here so the suite works even when the env is not inherited.
case ":${PYTHONPATH:-}:" in *":$SRC:"*) ;; *) export PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}" ;; esac

PYBIN="$SRC/bin/python3"
[ -x "$PYBIN" ] || { echo "FATAL: $PYBIN missing — build.sh must create the project interpreter copy" >&2; PYBIN="$(command -v python3)"; }

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ] && [ "$tests" -gt 0 ]
}

# Run tomlkit's pytest suite through the project interpreter. -p no:cacheprefix keeps it offline/quiet.
LOG="$(mktemp)"
"$PYBIN" -m pytest tests/ -q -p no:cacheprovider --no-header >"$LOG" 2>&1
RC=$?
cat "$LOG"

# Parse pytest's summary line, e.g. "123 passed, 4 skipped in 1.23s" / "2 failed, 100 passed in ...".
SUMMARY_LINE="$(grep -E '^(=+ )?[0-9]+ (passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$SUMMARY_LINE" | grep -oE "[0-9]+ $1" | grep -oE '[0-9]+' | head -1; }
PASSED="$(get passed)"; FAILED="$(get failed)"; SKIPPED="$(get skipped)"
ERRORS="$(get error)"; ERRORS2="$(get errors)"
PASSED="${PASSED:-0}"; FAILED="${FAILED:-0}"; SKIPPED="${SKIPPED:-0}"
ERRORS="${ERRORS:-0}"; ERRORS2="${ERRORS2:-0}"
# Collection/errors count as failures (so a neutered interpreter that produces no summary -> 0 tests -> fail).
FAILED=$(( FAILED + ERRORS + ERRORS2 ))
# If pytest itself did not run to completion (e.g. interpreter neutered under sabotage), there's no
# summary line -> treat as a hard failure with zero tests.
if [ -z "$SUMMARY_LINE" ]; then PASSED=0; FAILED=0; SKIPPED=0; fi

emit_ctrf "pytest" "$PASSED" "$FAILED" "$SKIPPED"
