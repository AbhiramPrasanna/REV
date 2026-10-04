#!/bin/bash
# ===========================================================================
# c2 -- Challenge 2: the cache budget flips the winner   (measurement summary Fig. 2)
#
#   x  compute-side cache 8, 32, 128, 512, 1024 MB (inner footprint ~440 MB)
#   y  lookup throughput (+ reads and requests per lookup)
#   curves  pull | push from the deepest cached node, 2 and 8 memory cores
#   model   pull loses one round trip per uncached level and collapses once the
#           bottom inner level stops fitting (below ~440 MB here); push stays
#           nearly flat; the curves cross at a budget that depends on the
#           structure and on the core count
#   fails if the curves never cross
#
# Lookups, 40 clients. Push: DEX-R; CHIME_OFFLOAD_MIN_LEVEL=1. The 1-client
# latency panel (Fig. 2b) comes from c3. 30 cells, ~1.3 h.
#
#   bash fair/experiments/c2_cache.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C2_MEMTHREADS:=0 2 8}"
: "${C2_CACHES:=8 32 128 512 1024}"

for tree in $TREES; do
  add_block "c2_dexr_${tree}" dexr "$tree" "$(count_cells "$C2_CACHES" "$C2_MEMTHREADS" x)" \
    "CACHES=$C2_CACHES" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=point-uniform"
  add_block "c2_chime_${tree}" chime "$tree" "$(count_cells "$C2_CACHES" "$C2_MEMTHREADS" x)" \
    "CACHES=$C2_CACHES" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1"
done

apply_skip; show_plan; run_plan
