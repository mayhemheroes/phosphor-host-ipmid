#!/usr/bin/env bash
#
# phosphor-host-ipmid/mayhem/test.sh — RUN the repo's OWN gtest suite over the exact code the
# fuzzers exercise, and emit a CTRF (ctrf.io) summary. exit 0 iff no test failed.
#
# PATCH-grade behavioral oracle: runs binaries DIRECTLY (not via meson) and asserts that
# specific gtest output markers appear in stdout — so a no-op/"exit(0)" patch FAILS because
# the sabotaged binary produces no gtest output at all.
#
# Suites:
#   * message            — test/message/{pack,payload,unpack}.cpp: the ipmi::message::Payload
#                          pack/unpack marshaller that fuzz_payload_unpack drives. Asserts
#                          concrete decoded/encoded byte values, bit-field alignment, string/
#                          vector/optional round-trips — a no-op patch cannot pass.
#   * session_closesession — exercises the session-close command handler (self-contained).
#
# These suites are self-contained: they construct Payload objects over in-memory buffers and never
# open a live openbmc *system* D-Bus connection. The binaries are built by mayhem/build.sh
# (-Dtests=enabled); this script only RUNS them — it never compiles.
#
# Suites that construct sdbusplus::bus::new_default() (a live system bus) in a fixture ctor — e.g.
# entitymap_json — are intentionally excluded: they throw in any sandbox without a system bus.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

BUILDDIR="${SRC:-/mayhem}/mayhem-build"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
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
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "gtest" 0 1 0; exit 2
fi

# Locate test binaries (meson installs them under test/).
MSG_BIN="$BUILDDIR/test/message"
SESS_BIN="$BUILDDIR/test/session_closesession"

if [ ! -x "$MSG_BIN" ] || [ ! -x "$SESS_BIN" ]; then
  echo "missing test binaries in $BUILDDIR/test/ — did build.sh succeed?" >&2
  ls "$BUILDDIR/test/" 2>&1 || true
  emit_ctrf "gtest" 0 1 0; exit 2
fi

TOTAL_PASS=0
TOTAL_FAIL=0

# run_suite <name> <binary> <required_marker>
# Runs the binary, checks that <required_marker> appears in stdout (proves real gtest ran —
# an exit(0)-sabotaged binary produces nothing), then counts [  PASSED  ] / [  FAILED  ] lines.
run_suite() {
  local name="$1" bin="$2" marker="$3"
  echo "=== running $name ==="
  local out
  out="$(env ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
         "$bin" 2>&1)" || true
  echo "$out"

  # BEHAVIORAL check: the gtest RUN marker MUST appear. An exit(0)-sabotaged binary
  # produces empty stdout — this grep will fail, marking the suite as failed.
  if ! printf '%s\n' "$out" | grep -qF "$marker"; then
    echo "FAIL: $name — expected gtest marker '$marker' not found in output (binary produced no gtest output)" >&2
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    return
  fi

  # Count individual test results from gtest's [ PASSED ]/[  FAILED  ] per-test lines.
  local pass fail
  pass=$(printf '%s\n' "$out" | grep -c '^\[  PASSED  \]' || true)
  fail=$(printf '%s\n' "$out" | grep -c '^\[  FAILED  \]' || true)

  # Also require the named test cases we know must appear (further guards against partial output).
  if ! printf '%s\n' "$out" | grep -qF 'PackBasics' && [ "$name" = "message" ]; then
    echo "FAIL: $name — expected 'PackBasics' test class not found in output" >&2
    TOTAL_FAIL=$(( TOTAL_FAIL + fail + 1 ))
    TOTAL_PASS=$(( TOTAL_PASS + pass ))
    return
  fi

  echo "  $name: passed=$pass failed=$fail"
  TOTAL_PASS=$(( TOTAL_PASS + pass ))
  TOTAL_FAIL=$(( TOTAL_FAIL + fail ))
}

run_suite "message"             "$MSG_BIN"  "[==========] Running"
run_suite "session/closesession" "$SESS_BIN" "[==========] Running"

emit_ctrf "gtest" "$TOTAL_PASS" "$TOTAL_FAIL" 0
