#!/bin/bash
# ===========================================================================
# c1 -- Challenge 1: push needs memory-node CPU      (measurement summary Fig. 1)
#
#   x  memory-node cores 1, 2, 4, 8     y  throughput (+ memory-node CPU % from the memory logs)
#   curves  pull (warm cache, 0 memory cores) | push (every lookup one request)
#   model   push needs ~9 cores to match a warm pull (page B+tree); never for CHIME
#   fails if push matches warm pull with 1-2 cores
#
# Warm cache (all inner nodes cached), lookups, 40 clients. "Push" = one request
# from the deepest cached node for every lookup: DEX-R pushes every leaf miss
# (96% of lookups at this cache); CHIME with CHIME_OFFLOAD_MIN_LEVEL=1. Stock
# CHIME (hotspot buffer on) plus one pull cell without the buffer
# (CHIME_HOTSPOT=0), to separate the buffer's cost from the leaf structure.
# 11 cells, ~40 min.
#
#   bash fair/experiments/c1_cores.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=model}"
: "${C1_CORES:=1 2 4 8}"

for tree in $TREES; do
  c=$(size_of dexr "$tree" INNER)
  add_block "c1_dexr_${tree}_warm" dexr "$tree" 5 \
    "CACHES=$c" "MEMTHREADS=0 $C1_CORES" "WORKLOADS=point-uniform"
  c=$(size_of chime "$tree" INNER)
  add_block "c1_chime_${tree}_pull" chime "$tree" 1 \
    "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform"
  add_block "c1_chime_${tree}_push" chime "$tree" 4 \
    "CACHES=$c" "MEMTHREADS=$C1_CORES" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1"
  add_block "c1_chime_${tree}_pull_nohot" chime "$tree" 1 \
    "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform" "CHIME_HOTSPOT=0"
done

apply_skip; show_plan; run_plan
