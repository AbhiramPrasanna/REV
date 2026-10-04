#!/bin/bash
# ===========================================================================
# c7 -- Challenge 7: coherence of mixed paths    (measurement summary, Challenge 7)
#
#   x  insert fraction 0 (= c1), 10, 25, 50 %   (the rest lookups)
#   y  extra round trips per op caused by stale cached nodes (validation +
#      invalidation), and the compute-side cache hit rate
#   curves  pull | push (2 memory cores); caches 8 MB and warm (1 GB)
#   model   none (the closed-form model has no coherence); expected: the cost of
#           keeping cached inner nodes valid grows with the write fraction,
#           because splits change inner nodes that clients have cached
#   fails if the extra cost is below 0.01 round trips per op at 50% writes
#
# Inserts use fresh keys (both benchmarks reserve them), so they split leaves and
# then inner nodes. Read from the logs: DEX reads/op, requests/op and its
# PATH-AWARE CACHE MISS RATE block; CHIME's [READPATH] line (retries, invalid,
# sibling reads) and index-cache hit %. CHIME pushes lookups only; its inserts
# are pulled. 24 cells, ~1 h.
#
#   bash fair/experiments/c7_coherence.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C7_INSERTS:=10 25 50}"

for tree in $TREES; do
  for c in $(two_caches dexr "$tree"); do
    for I in $C7_INSERTS; do
      add_block "c7_dexr_${tree}_c${c}_ins${I}" dexr "$tree" 2 "INSERT_PCT=$I" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-uniform"
      add_block "c7_chime_${tree}_c${c}_ins${I}" chime "$tree" 2 "INSERT_PCT=$I" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "CHIME_OFFLOAD_MIN_LEVEL=1"
    done
  done
done

apply_skip; show_plan; run_plan
