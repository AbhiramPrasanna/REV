#!/bin/bash
# ===========================================================================
# c1 -- Challenge 1: push needs memory-node CPU      (measurement summary Fig. 1, 1b)
#
#   x  memory-node cores 1, 2, 4, 8     y  (a) throughput   (b) memory-node CPU %
#   curves  pull (warm cache, no memory CPU) | push only | push on a miss
#   model   push-only needs ~9 cores to match a warm pull (page B+tree)
#   fails if push only matches warm pull with 1-2 cores
#
#   warm     cache that holds the inner nodes: pull (0) and push on a miss
#   pushall  CHIME only, same cache, CHIME_OFFLOAD_MIN_LEVEL=1: every lookup
#            pushed, cache hits included = the model's push-only
#   cold     8 MB: push on a miss is nearly every lookup (near push-only)
# Systems: dex (stock: pushes inside its bottom 4 levels only), dexr (reads pushed
# from the deepest cached node, = the model's push), chime.
# Where we expect to deviate: stock DEX stays flat with cores (it still pulls the
# levels above its bottom 4); closed loop (36 clients) instead of open load.
#
#   bash fair/experiments/c1_cores.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dex dexr chime}"
: "${TREES:=stress fair}"
: "${C1_CORES:=1 2 4 8}"
: "${C1_WORKLOADS:=point-uniform}"

for sys in $SYSTEMS_C; do
  for tree in $TREES; do
    warm=$(size_of "$sys" "$tree" INNER)
    add_block "c1_${sys}_${tree}_warm" "$sys" "$tree" \
      "$(count_cells "$warm" "0 $C1_CORES" "$C1_WORKLOADS")" \
      "CACHES=$warm" "MEMTHREADS=0 $C1_CORES" "WORKLOADS=$C1_WORKLOADS"
    if [ "$sys" = chime ]; then
      add_block "c1_chime_${tree}_pushall" chime "$tree" \
        "$(count_cells "$warm" "$C1_CORES" "$C1_WORKLOADS")" \
        "CACHES=$warm" "MEMTHREADS=$C1_CORES" "WORKLOADS=$C1_WORKLOADS" "CHIME_OFFLOAD_MIN_LEVEL=1"
    fi
    add_block "c1_${sys}_${tree}_cold" "$sys" "$tree" \
      "$(count_cells 8 "0 $C1_CORES" "$C1_WORKLOADS")" \
      "CACHES=8" "MEMTHREADS=0 $C1_CORES" "WORKLOADS=$C1_WORKLOADS"
  done
done

apply_skip; show_plan; run_plan
