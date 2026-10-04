#!/bin/bash
# ===========================================================================
# c3 -- Challenge 3: the depth of the miss, and load    (measurement summary Fig. 3, 7)
#
#   (a) x  uncached inner levels m (measured reads per lookup - 1)
#       y  latency, ONE client (the model's idle latency)
#       curves  pull | push (one request from the deepest cached node)
#   (b) heatmap: winner over (m, memory-core load) -- the load comes from the
#       40-client cells of c1/c2/c6 (memory-node CPU % on server 8)
#   model   pull = (m+1)·R grows one round trip per level; push stays nearly flat
#           until the memory core is busy, so on an idle memory node push wins any
#           miss of 1 level or more, and the crossover m* runs away with load
#   fails if m* is the same at every load
#
# Caches chosen to leave m = 0 .. ~4 uncached inner levels on the height-10 tree:
# 1024 (m=0), 128 (m=1), 16 (m~2), 8 (m~3), 2 (m~4). Both trees are bulk-built,
# so 1-client cells load fast. 20 cells, ~1 h.
#
#   bash fair/experiments/c3_depth_load.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C3_CACHES:=1024 128 16 8 2}"

for tree in $TREES; do
  n=$(count_cells "$C3_CACHES" "0 1" x)
  add_block "c3_dexr_${tree}_idle" dexr "$tree" "$n" \
    "CACHES=$C3_CACHES" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "@min=3"
  add_block "c3_chime_${tree}_idle" chime "$tree" "$n" \
    "CACHES=$C3_CACHES" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1" \
    "${IDLE_ENV[@]}" "@min=3"
done

apply_skip; show_plan; run_plan
