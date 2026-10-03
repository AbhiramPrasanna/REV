#!/bin/bash
# ===========================================================================
# c4 -- Challenge 4: lookups, scans and writes want different paths
#       (measurement summary Fig. 4)
#
#   (a, b) x  scan length 1, 10, 100, 1000 keys (log)
#          y  (a) latency, 1 client   (b) throughput, 36 clients
#   (c)    x  update fraction 0, 25, 50, 75, 100 %    y  throughput
#   curves  pull and push for each structure: page B+tree (dex, dexr), hashed-leaf
#           B+tree (chime), one-key-leaf radix tree (dart; pull only)
#   model   warm cache: a page B+tree's pulled scan wins at every length (a few
#           leaves, read together); a one-key leaf's pulled scan needs one read
#           per key, so push wins long scans. Writes favour push on latency.
#   fails if the same path wins for every operation
#
# Cache: inner nodes fit (warm). Push: 2 memory threads.
# Where we expect to deviate: DEX's PULLED scan reads one leaf at a time and
# restarts from the root per leaf, so push wins DEX scans more often than the
# model says; CHIME (leaves read together) is the fair test of this lesson.
# Writes: updates only (no splits), keyed by UPDATE_PCT; DEX and DEX-R push
# updates only inside DEX's bottom 4 levels (writes keep DEX's rule).
#
#   bash fair/experiments/c4_query_type.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dex dexr chime dart}"
: "${TREES:=fair}"
: "${C4_LENGTHS:=1 10 100 1000}"
: "${C4_UPDATES:=0 25 50 75 100}"

for L in $C4_LENGTHS; do
  for cl in 36 1; do
    if [ "$cl" = 1 ]; then ops=("${IDLE_ENV[@]}"); mn=5
    elif [ "$L" -ge 1000 ]; then ops=("OPS_M=2" "WARMUP_M=4"); mn=3
    else ops=("OPS_M=30" "WARMUP_M=10"); mn=3; fi
    for sys in $SYSTEMS_C; do
      if [ "$sys" = dart ]; then
        [ "$cl" = 1 ] && continue                 # DART loads with THREADS threads
        add_block "c4_dart_L${L}_c${cl}" dart stress 1 "SCAN_LEN=$L" "${ops[@]}" \
          "CACHES=128" "WORKLOADS=range-uniform"
        continue
      fi
      for tree in $TREES; do
        c=$(size_of "$sys" "$tree" INNER)
        add_block "c4_${sys}_${tree}_L${L}_c${cl}" "$sys" "$tree" 2 "SCAN_LEN=$L" "${ops[@]}" \
          "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=range-uniform" "@min=$mn"
      done
    done
  done
done

for U in $C4_UPDATES; do
  for sys in $SYSTEMS_C; do
    if [ "$sys" = dart ]; then
      add_block "c4_dart_upd${U}" dart stress 1 "UPDATE_PCT=$U" "CACHES=128" "WORKLOADS=point-uniform"
      continue
    fi
    for tree in $TREES; do
      c=$(size_of "$sys" "$tree" INNER)
      add_block "c4_${sys}_${tree}_upd${U}" "$sys" "$tree" 2 "UPDATE_PCT=$U" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-uniform"
    done
  done
done

apply_skip; show_plan; run_plan
