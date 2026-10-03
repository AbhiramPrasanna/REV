#!/bin/bash
# ===========================================================================
# c6 -- Challenge 6: load and skew move the crossover   (measurement summary Fig. 6)
#
#   (a) x  offered load = client threads 1, 2, 4, 8, 16, 24, 36 (closed loop)
#       y  p50 / p99 latency vs measured throughput
#       curves  pull | push at 1, 2, 4 memory cores
#   (b) x  Zipf theta 0.5, 0.8, 0.99, 1.2 (uniform = theta 0, from c2)
#       y  throughput     curves  pull | push on a miss (2 cores)
#   model   (one uncached level, m = 1) push has the lower idle latency and hits
#           its knee first; with 1 core push wins only at low load; skew favours
#           pull (popular paths stay cached)
#   fails if the better static path never changes with load or skew
#
# Cache with about one uncached inner level (*_M1 in common.sh).
# Where we expect to deviate: a closed loop raises load by adding clients, not by
# an independent arrival stream, so the knees are approximate.
# Zipf theta 1.2: check one cell first that DEX's and CHIME's generators accept it.
#
#   bash fair/experiments/c6_load_skew.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dexr dex chime}"
: "${TREES:=stress}"
: "${C6_CLIENTS:=1 2 4 8 16 24 36}"
: "${C6_THETAS:=0.5 0.8 0.99 1.2}"

for sys in $SYSTEMS_C; do
  for tree in $TREES; do
    c=$(size_of "$sys" "$tree" M1)
    for n in $C6_CLIENTS; do
      if [ "$n" -le 2 ]; then ops=("OPS_M=2" "WARMUP_M=10"); mn=4; else ops=("OPS_M=10" "WARMUP_M=10"); mn=2.5; fi
      add_block "c6_${sys}_${tree}_load_t${n}" "$sys" "$tree" 4 \
        "THREADS=$n" "${ops[@]}" "CACHES=$c" "MEMTHREADS=0 1 2 4" "WORKLOADS=point-uniform" "@min=$mn"
    done
    for z in $C6_THETAS; do
      add_block "c6_${sys}_${tree}_zipf${z}" "$sys" "$tree" 4 \
        "ZIPF_THETA=$z" "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-zipf range-zipf"
    done
  done
done
for z in $C6_THETAS; do
  add_block "c6_dart_zipf${z}" dart stress 2 "ZIPF_THETA=$z" "CACHES=128" "WORKLOADS=point-zipf range-zipf"
done

apply_skip; show_plan; run_plan
