#!/usr/bin/env bash
#
# mayhem/build.sh — build crossplane's package dependency DAG (internal/dag) as a
# sanitized libFuzzer binary (OSS-Fuzz Go path: go-118-fuzz-build -libfuzzer
# archive + clang++ ASan link), plus a dynamically-linked KAT oracle probe for
# mayhem/test.sh to run.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get of the /testing shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS STAGING (netnew §6 Go / port-go): crossplane's real module pins
# go 1.25.11 and drags the entire Kubernetes closure (api-machinery,
# controller-runtime, client-go, go-containerregistry, grpc…) through go.mod.
# internal/dag's MapDag graph algorithm needs only stdlib + two symbols
# (errors.New/Errorf) from crossplane-runtime's errors helper. So we copy JUST
# dag.go into a fresh STANDALONE Go mini-module at _mayhem_harness/dag, repoint
# its one non-stdlib import at a tiny local `errors` shim, and build there. The
# module's only downloaded dep is the go-118-fuzz-build /testing shim (which
# transitively provides go-fuzz-headers) — crossplane's giant graph is never
# touched. The staging dir is leading-underscore so `go build/test ./...`
# wildcards skip it and it can never disturb the upstream suite.
set -euo pipefail

: "${SRC:=/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

TARGET="fuzz_dag"
STAGE="$SRC/_mayhem_harness/dag"
MODPATH="crossplane.local/mayhemdag"

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached. A raw commit hash
# forces a proxy.golang.org round trip to resolve it — fatal on the air-gapped
# PATCH re-run; the pseudo-version resolves straight from the file cache.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

# ── Stage a standalone mini-module: dag.go (verbatim) + shim + harness + KAT ───
rm -rf "$STAGE"
mkdir -p "$STAGE/errors" "$STAGE/kat"

# dag.go copied verbatim; repoint ONLY its crossplane-runtime errors import at
# the local shim (same package name `errors`, so New/Errorf calls are untouched).
sed 's#github.com/crossplane/crossplane-runtime/v2/pkg/errors#'"$MODPATH"'/errors#' \
  "$SRC/internal/dag/dag.go" > "$STAGE/dag.go"
grep -q "$MODPATH/errors" "$STAGE/dag.go" \
  || { echo "FATAL: errors import rewrite failed in staged dag.go"; exit 1; }

cp "$SRC/mayhem/errors_shim.go.src" "$STAGE/errors/errors.go"
cp "$SRC/mayhem/harness_dag.go.src" "$STAGE/harness_dag.go"
cp "$SRC/mayhem/kat_export.go.src"  "$STAGE/kat_export.go"
cp "$SRC/mayhem/kat/main.go"        "$STAGE/kat/main.go"

# ── Module graph: init, add the /testing shim, then tidy ───────────────────────
(
  cd "$STAGE"
  go mod init "$MODPATH"
  # The /testing shim pulls go-fuzz-headers transitively; both resolve from the
  # file-proxy cache offline on the PATCH re-run.
  go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"
  go mod tidy
)

# ── Build the libFuzzer archive from the staged mini-module ────────────────────
mkdir -p "$SRC/mayhem-build"
echo "=== go-118-fuzz-build $TARGET (func FuzzDag) ==="
(
  cd "$STAGE"
  go-118-fuzz-build -func FuzzDag -o "$SRC/mayhem-build/$TARGET.a" .
)

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$SRC/mayhem-build/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem-build/anchor.c" -o "$SRC/mayhem-build/anchor.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$SRC/mayhem-build/anchor.o" "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
(
  cd "$STAGE"
  go build -o /mayhem/crossplane_dag_kat ./kat
)
file /mayhem/crossplane_dag_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/crossplane_dag_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/crossplane_dag_kat (dynamically linked)"

echo "build.sh complete"
