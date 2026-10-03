#!/bin/bash
# ===========================================================================
# c5 -- Challenge 5: the same policy helps one structure and hurts another
#       (measurement summary Fig. 5)
#
#   bars  structure x operation (lookup, 100-key scan, update)
#   y     (a) latency gain of push = pull latency / push latency, 1 client
#         (b) push throughput / pull throughput, 40 clients    (log, line at 1)
#   model   at 1 GB and 2 memory cores, bars fall on both sides of 1; on the
#           B+trees push is slower for lookups and scans, faster for inserts
#   fails if every bar is on the same side of 1
#
# The model's own point: 1024 MB cache, 2 memory threads, pull (0) vs push.
# Systems: dex, dexr, chime in both trees; dart (no push) gives the radix-tree
# pull reference. Updates use UPDATE_PCT=100 (the model's insert bar; updates
# change no tree shape).
#
#   bash fair/experiments/c5_structure.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dexr chime dart}"       # add "dex" for stock DEX
: "${TREES:=model}"                   # original node formats (stress / fair also work)
: "${THREADS_C:=40}"                    # label only: the many-client cells use THREADS (params.sh)
: "${C5_CACHE:=1024}"
: "${C5_WORKLOADS:=point-uniform range-uniform}"

for sys in $SYSTEMS_C; do
  if [ "$sys" = dart ]; then
    add_block "c5_dart" dart stress 2 "CACHES=$C5_CACHE" "WORKLOADS=$C5_WORKLOADS"
    add_block "c5_dart_upd" dart stress 1 "CACHES=$C5_CACHE" "WORKLOADS=point-uniform" "UPDATE_PCT=100"
    continue
  fi
  for tree in $TREES; do
    for cl in "$THREADS_C" 1; do
      extra=(); [ "$cl" = 1 ] && extra=("${IDLE_ENV[@]}" "@min=5")
      add_block "c5_${sys}_${tree}_c${cl}" "$sys" "$tree" \
        "$(count_cells "$C5_CACHE" "0 2" "$C5_WORKLOADS")" \
        "CACHES=$C5_CACHE" "MEMTHREADS=0 2" "WORKLOADS=$C5_WORKLOADS" ${extra[@]+"${extra[@]}"}
      add_block "c5_${sys}_${tree}_c${cl}_upd" "$sys" "$tree" 2 \
        "CACHES=$C5_CACHE" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "UPDATE_PCT=100" \
        ${extra[@]+"${extra[@]}"}
    done
  done
done

apply_skip; show_plan; run_plan
