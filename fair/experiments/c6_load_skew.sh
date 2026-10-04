#!/bin/bash
# ===========================================================================
# c6 -- Challenge 6: load and skew move the crossover   (measurement summary Fig. 6)
#
#   (a) x  offered load = client threads 1, 4, 16, 40 (closed loop)
#       y  mean / p99 latency vs measured throughput
#       curves  pull | push at 1, 2, 4 memory cores
#   (b) x  Zipf theta 0.8, 0.99, 1.2 (uniform = c1)
#       y  throughput     curves  pull | push (2 cores)
#   caches  128 MB (the model's m = 1: only the bottom inner level uncached) and 8 MB
#   model   push has the lower idle latency when a level is uncached and hits its
#           knee first: with 1 core push is better only at low load; skew helps
#           pull (popular paths stay cached) and CHIME's hotspot buffer
#   fails if the better static path never changes with load or skew
#
# Known deviation: a closed loop raises load by adding clients, and each waiting
# client holds a core, so the knee is set by 40 cores, not by an arrival rate.
# 72 cells, ~3 h.
#
#   bash fair/experiments/c6_load_skew.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C6_CLIENTS:=1 4 16 40}"
: "${C6_THETAS:=0.8 0.99 1.2}"

for tree in $TREES; do
  for c in "$(size_of dexr "$tree" M1)" "$SMALL_MB"; do
    for n in $C6_CLIENTS; do
      if [ "$n" -le 4 ]; then ops=("OPS_M=2" "WARMUP_M=4"); mn=3; else ops=("OPS_M=10" "WARMUP_M=10"); mn=2.5; fi
      add_block "c6_dexr_${tree}_c${c}_t${n}" dexr "$tree" 4 \
        "THREADS=$n" "${ops[@]}" "CACHES=$c" "MEMTHREADS=0 1 2 4" "WORKLOADS=point-uniform" "@min=$mn"
      add_block "c6_chime_${tree}_c${c}_t${n}" chime "$tree" 4 \
        "THREADS=$n" "${ops[@]}" "CACHES=$c" "MEMTHREADS=0 1 2 4" "WORKLOADS=point-uniform" \
        "CHIME_OFFLOAD_MIN_LEVEL=1" "@min=$mn"
    done
    for z in $C6_THETAS; do
      add_block "c6_dexr_${tree}_c${c}_zipf${z}" dexr "$tree" 2 \
        "ZIPF_THETA=$z" "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-zipf"
      add_block "c6_chime_${tree}_c${c}_zipf${z}" chime "$tree" 2 \
        "ZIPF_THETA=$z" "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-zipf" "CHIME_OFFLOAD_MIN_LEVEL=1"
    done
  done
done

apply_skip; show_plan; run_plan
