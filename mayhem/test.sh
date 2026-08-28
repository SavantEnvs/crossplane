#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for crossplane's package dependency DAG.
# Runs the dynamically-linked KAT probe (/mayhem/crossplane_dag_kat, built by
# build.sh) that drives fixed graphs through the REAL MapDag algorithm and
# asserts EXACT behavioral values:
#   - a total-order chain (one->two->three) topological-sorts to "three,two,one",
#   - TraceNode("one") returns exactly the transitive neighbour set {three,two},
#   - a cyclic graph (a<->b) makes Sort() report "detected cycle".
# These are documented properties of the algorithm and match internal/dag's own
# dag_test.go semantics.
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing (the cosign/notary false-green). The KAT probe
# is cgo-linked (dynamic), so when the program is neutered to _exit(0) it prints
# nothing, every assertion below misses, and test.sh FAILS — which is the point.
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

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

PROBE=/mayhem/crossplane_dag_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "crossplane-dag-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Exact-line assertions (grep -qxF: whole-line, fixed-string).
assert_line() { # <desc> <expected-exact-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}
# Substring assertion (for the cycle error, whose named node may vary).
assert_sub() { # <desc> <substring>
  if printf '%s\n' "$OUT" | grep -qF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected substring: $2)"; failed=$((failed+1))
  fi
}

assert_line "chain one->two->three sorts to three,two,one" "KAT_CHAIN_SORT=three,two,one"
assert_line "TraceNode(one) has 2 transitive neighbours"   "KAT_TRACE_COUNT=2"
assert_line "TraceNode(one) transitive set == {three,two}" "KAT_TRACE_KEYS=three,two"
assert_sub  "cyclic graph a<->b -> Sort detects a cycle"   "KAT_CYCLE_ERR=detected cycle on:"

emit_ctrf "crossplane-dag-kat" "$passed" "$failed"
