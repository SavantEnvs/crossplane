// mayhem/kat/main.go — dynamically-linked known-answer probe for crossplane's
// package dependency DAG. `import "C"` (cgo) forces a DYNAMICALLY LINKED binary
// so the gate's LD_PRELOAD sabotage shim can neuter it (a statically-linked Go
// binary would be immune, giving a false-green oracle — the trap netnew §4 warns
// about with `go test` alone).
//
// It imports the build-time-staged dag mini-module (created by mayhem/build.sh
// at _mayhem_harness/dag) and runs KATRun(), which drives fixed graphs through
// the REAL NewMapDag/Init/Sort/TraceNode code, then prints each result in a
// fixed, greppable format for mayhem/test.sh to assert.
package main

// #include <stdint.h>
import "C"

import (
	"fmt"

	dag "crossplane.local/mayhemdag"
)

func main() {
	r := dag.KATRun()
	fmt.Printf("KAT_CHAIN_SORT=%s\n", r.ChainSort)
	fmt.Printf("KAT_TRACE_COUNT=%d\n", r.TraceCount)
	fmt.Printf("KAT_TRACE_KEYS=%s\n", r.TraceKeys)
	fmt.Printf("KAT_CYCLE_ERR=%s\n", r.CycleErr)
}
