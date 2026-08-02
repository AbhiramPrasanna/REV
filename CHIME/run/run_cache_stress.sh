#!/bin/bash
# ===========================================================================
# run_cache_stress.sh  --  CHIME cache-STRESS x offload study
#
# THE QUESTION
#   CHIME's compute-side index cache holds INTERNAL nodes only. The internal-node
#   index for this build is ~55 MB (measure it -- see CALIBRATE below). We shrink
#   the cache from "fits the whole index" down to "badly stressed" and ask:
#
#     With offloading ON, can a STRESSED cache (32 MB, 16 MB) deliver throughput
#     and tail latency >= the comfortable 64 MB cache (which ~holds the index)?
#
#   i.e. does pushing the cache-missed descent down to the memory node (RPC)
#   compensate for a cache too small to resolve the tree locally.
#
# THE SWEEP  (this is just run_sequence with the knobs pinned for THIS study):
#     cache      = 64, 32, 16 MB              (fits -> stressed -> very stressed)
#     offload    = off (one-sided only) then on (DEX-style pushdown)
#     workload   = point x {uniform, zipf-0.99}  and  range x {uniform, zipf-0.99}
#   3 caches x 2 offload x 4 workloads = 24 cells per node, 50M ops each.
#   Cache size is applied at RUNTIME (CHIME_CACHE_MB) -- ONE build, no rebuilds.
#
# RUN THE MEMORY NODE FIRST, THEN THE COMPUTE NODE, SAME ARGS:
#     ./run_cache_stress.sh memory      # on 10.30.1.7 (hosts memcached)
#     ./run_cache_stress.sh compute     # on 10.30.1.6
#   Both machines MUST pass identical CACHE_MB / WORKLOADS / SEQUENCE (lockstep).
#
# BUILD FIRST (offload must be compiled in for the ON half to exist):
#     cd .. && mkdir -p build && cd build && cmake -DENABLE_OFFLOAD=ON .. && make -j
#
# CALIBRATE the index once so you KNOW where 64/32/16 sit relative to it:
#     CACHE_MB=1024 POINT_OP=1 WORKLOADS=point-uniform SEQUENCE=off \
#         ./run_cache_stress.sh memory
#     grep "consumed cache size" build/results/.../memory.log   # = true index MB
#   Every result row also records index_mb, so each cell states its index/cache %.
#
# PLOT (throughput + MEAN + p99 across cache x offload, per workload):
#     python3 ../results/plot_offload.py            # auto-finds newest sweep
#
# Knobs (env, all overridable):
#     CACHE_MB    "64 32 16"                     cache points, MB, runtime
#     WORKLOADS   all four                       point/range x uniform/zipf
#     SEQUENCE    "off on"                       offload modes (order matters)
#     DIR_THREADS 4                              MN RPC cores = offload's ceiling
#     BULK/WARMUP/POINT_OP/RANGE_OP  50/10/50/50 op counts (M)  (PROFILE=quick for 10M)
# ===========================================================================
role="${1:?usage: run_cache_stress.sh <memory|compute>}"

case "${PROFILE:-}" in
  quick) : "${BULK:=10}"; : "${WARMUP:=2}"; : "${POINT_OP:=10}"; : "${RANGE_OP:=10}" ;;
  final|"") : "${BULK:=50}"; : "${WARMUP:=10}"; : "${POINT_OP:=50}"; : "${RANGE_OP:=50}" ;;
  *) echo "unknown PROFILE=$PROFILE (use quick|final)" >&2; exit 1 ;;
esac

# Cache axis pinned high->low so the plot reads "as the cache shrinks ...".
export CACHE_MB="${CACHE_MB:-64 32 16}"
export WORKLOADS="${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf}"
export SEQUENCE="${SEQUENCE:-off on}"
export DIR_THREADS="${DIR_THREADS:-4}"
export BULK WARMUP POINT_OP RANGE_OP
export ZIPF_THETA="${ZIPF_THETA:-0.99}"
export SCAN_RANGE="${SCAN_RANGE:-100}"
# Land these results in their own folder so they don't mix with other sweeps.
export LOG_DIR="${LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/results/cache_stress}"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence "$role"
