#!/bin/bash
# ===========================================================================
# c2 -- Challenge 2: the cache budget flips the winner   (measurement summary Fig. 2)
#
#   x  cache budget (log), marked at the inner footprint    y  throughput (+ reads/op)
#   curves  pull | push from the deepest cached node, 2 and 8 cores
#   model   pull falls once the bottom inner level stops fitting; push stays nearly
#           flat; the crossover budget differs by structure
#   fails if the curves never cross
#
# Lookups, 40 clients. Four budgets from "almost nothing cached" to "all inner
# nodes cached": DEX 2/8/32/128 MB (inner 60 MB), CHIME 2/8/32/100 MB (tree cache
# holds the inner nodes in 23 MB; 100 MB = CHIME's shipped 70 MB tree cache + 30 MB
# hotspot buffer). Push = every lookup one request (DEX-R; CHIME min level 1).
# 24 cells, ~1.3 h.
#
#   bash fair/experiments/c2_cache.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=model}"
: "${C2_MEMTHREADS:=0 2 8}"
: "${C2_DEX:=2 8 32 128}"
: "${C2_CHIME:=2 8 32 100}"

for tree in $TREES; do
  add_block "c2_dexr_${tree}" dexr "$tree" "$(count_cells "$C2_DEX" "$C2_MEMTHREADS" x)" \
    "CACHES=$C2_DEX" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=point-uniform"
  add_block "c2_chime_${tree}" chime "$tree" "$(count_cells "$C2_CHIME" "$C2_MEMTHREADS" x)" \
    "CACHES=$C2_CHIME" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1"
done

apply_skip; show_plan; run_plan
