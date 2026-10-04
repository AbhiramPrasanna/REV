#!/bin/bash
# ===========================================================================
# c5 -- Challenge 5: the same policy helps one structure and hurts another
#       (measurement summary Fig. 5)
#
#   bars  structure (DEX page B+tree, CHIME hashed-leaf B+tree) x operation
#         (lookup, 100-key scan, insert)
#   y     (a) latency gain of push = pull latency / push latency, 1 client
#         (b) push throughput / pull throughput, 2 memory cores, 40 clients
#   model   at 1 GB and 2 cores, bars fall on both sides of 1: on the B+trees push
#           is slower for lookups and scans, faster (on latency) for inserts
#   fails if every bar is on the same side of 1
#
# Caches: the model's 1 GB point (warm) and 8 MB. Most bars reuse cells from
# other challenges, so this script runs only the INSERT cells:
#   lookup, 40 clients      c1_<sys>_deep_c<cache>(_pull|_push)   (mt 0 / 2)
#   lookup, 1 client        c3_<sys>_deep_idle                    (1024 and 8 MB)
#   100-key scan, 40 / 1    c4_<sys>_deep_c<cache>_L100(_1client)
#   insert, 40 / 1          this script (INSERT_PCT=100: fresh keys, real splits)
# CHIME has no write push, so its insert bars are pull only. 12 cells, ~40 min.
#
#   bash fair/experiments/c5_structure.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"

for tree in $TREES; do
  for c in $(two_caches dexr "$tree"); do
    add_block "c5_dexr_${tree}_c${c}_ins" dexr "$tree" 2 "INSERT_PCT=100" \
      "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-uniform"
    add_block "c5_dexr_${tree}_c${c}_ins_1client" dexr "$tree" 2 "INSERT_PCT=100" "${IDLE_ENV[@]}" \
      "CACHES=$c" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "@min=3"
    add_block "c5_chime_${tree}_c${c}_ins" chime "$tree" 1 "INSERT_PCT=100" \
      "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform"
    add_block "c5_chime_${tree}_c${c}_ins_1client" chime "$tree" 1 "INSERT_PCT=100" "${IDLE_ENV[@]}" \
      "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform" "@min=3"
  done
done

apply_skip; show_plan; run_plan
