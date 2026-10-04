#!/bin/bash
# ===========================================================================
# c1 -- Challenge 1: push needs memory-node CPU      (measurement summary Fig. 1, 1b)
#
#   x  memory-node cores 1, 2, 4, 8     y  lookup throughput (+ memory-node CPU %)
#   curves  pull (0 memory cores) | push (every lookup one request)
#   caches  8 MB (top ~5 of 9 inner levels cached) and the warm cache (1 GB,
#           all inner nodes cached)
#   model   push-only needs ~9 cores to match a warm pull (page B+tree); for CHIME
#           never (its pull exceeds push's NIC message cap). At 8 MB pull needs
#           ~5 dependent reads, so push should beat pull there with few cores.
#   fails if push matches warm pull with 1-2 cores
#
# Push = one request from the deepest cached node for every lookup: DEX-R, and
# CHIME with CHIME_OFFLOAD_MIN_LEVEL=1. CHIME runs stock (hotspot buffer on).
# Known deviations (model tree, 40 clients, measured 2026-10-03): push costs
# 0.70 us (DEX) / 0.98 us (CHIME) of memory CPU per request, levels off after
# ~4 cores because 40 clients each hold a core for the whole round trip; CHIME's
# warm pull is CPU-bound on the compute node (3.5 Mops), not NIC-bound.
# 20 cells, ~50 min.
#
#   bash fair/experiments/c1_cores.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C1_CORES:=1 2 4 8}"

for tree in $TREES; do
  for c in $(two_caches dexr "$tree"); do
    add_block "c1_dexr_${tree}_c${c}" dexr "$tree" 5 \
      "CACHES=$c" "MEMTHREADS=0 $C1_CORES" "WORKLOADS=point-uniform"
  done
  for c in $(two_caches chime "$tree"); do
    add_block "c1_chime_${tree}_c${c}_pull" chime "$tree" 1 \
      "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform"
    add_block "c1_chime_${tree}_c${c}_push" chime "$tree" 4 \
      "CACHES=$c" "MEMTHREADS=$C1_CORES" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1"
  done
done

apply_skip; show_plan; run_plan
