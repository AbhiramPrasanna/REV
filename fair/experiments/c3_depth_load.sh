#!/bin/bash
# ===========================================================================
# c3 -- Challenge 3: the depth of the miss      (measurement summary Fig. 3)
#
#   x  uncached inner levels m (from each cell's reads per lookup)
#   y  latency, ONE client (the model's idle latency)
#   curves  pull | push (one request from the deepest cached node)
#   model   pull = (m+1)·R grows one round trip per level; push stays nearly flat;
#           on an idle memory node push wins any miss of 1 level or more
#   fails if push never wins at any depth
#
# Caches that leave m = 0, about 1, about 2 levels uncached: DEX 128/4/1 MB,
# CHIME 100/2 MB (CHIME's tree has 4 inner levels, so m only reaches ~1).
# The loaded part of Fig. 3 (crossover vs memory-core load) comes from the c1/c2
# 40-client cells and the memory-node CPU %. One client: CHIME loads the tree
# with as many threads as clients, so each CHIME cell spends ~11 min loading.
# 10 cells, ~1.2 h.
#
#   bash fair/experiments/c3_depth_load.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=model}"
: "${C3_DEX:=1 4 128}"
: "${C3_CHIME:=2 100}"

for tree in $TREES; do
  add_block "c3_dexr_${tree}_idle" dexr "$tree" "$(count_cells "$C3_DEX" "0 1" x)" \
    "CACHES=$C3_DEX" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "@min=3"
  add_block "c3_chime_${tree}_idle_pull" chime "$tree" "$(count_cells "$C3_CHIME" 0 x)" \
    "CACHES=$C3_CHIME" "MEMTHREADS=0" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "@min=13"
  add_block "c3_chime_${tree}_idle_push" chime "$tree" "$(count_cells "$C3_CHIME" 1 x)" \
    "CACHES=$C3_CHIME" "MEMTHREADS=1" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1" \
    "${IDLE_ENV[@]}" "@min=13"
done

apply_skip; show_plan; run_plan
