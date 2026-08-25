#!/bin/bash
# ===========================================================================
# run_leaf_cache.sh  --  CHIME LEAF-CACHE study (Experiment C)
#
# THE QUESTION
#   Stock CHIME caches INTERNAL nodes only. Even on a perfect index-cache hit the
#   descent ends in one remote read of the leaf -- hopscotch hashing makes that
#   read SMALL (one hop segment, no read amplification) but it is still a round
#   trip, and it is why CHIME cannot reach DART's flat-fast profile under skew no
#   matter how large the index cache gets.
#
#   Does caching LEAVES on the compute node remove that last round trip, and is
#   the win big enough to pass DART?
#
# THE SWEEP
#     leaf     = 0 (inner nodes only) then 1 (inner nodes AND leaves)  <-- the axis
#     cache    = 64, 128, 256, 512 MB -- the TOTAL compute-side budget, the
#                SAME points DART is swept at. It is SPLIT, never grown:
#                  CACHE_LEAF=0 -> all of it is the inner-node cache
#                  CACHE_LEAF=1 -> LEAF_CACHE_PCT% leaves, the rest inner nodes
#                so at 256 MB the two arms are 256/0 and 128/128. Both arms occupy
#                the same compute-side memory as DART at that point, which is the
#                only way the overall comparison stays honest -- otherwise a win
#                just says "CHIME was given more RAM".
#     offload  = off then on
#     workload = point x {uniform, zipf-0.99}, range x {uniform, zipf-0.99}
#   4 caches x 2 leaf x 2 offload x 4 workloads = 64 cells per node. All of it is
#   runtime configuration -- ONE build, no rebuilds.
#
# COHERENCE is not a knob. A cached leaf is ALWAYS validated with one 16-byte
# [lock, stamp] probe before it is served, so the cache is correct under concurrent
# writers from any node -- there is no configuration that can silently return stale
# data. What it buys: a point lookup still costs one round trip but a 16-byte one
# instead of a segment read; a range scan validates the covered leaves it holds
# instead of reading each one in full. Expect a LARGE scan win, a modest point win.
#
# RUN THE MEMORY NODE FIRST, THEN THE COMPUTE NODE, SAME ARGS:
#     ./run_leaf_cache.sh memory      # on 10.30.1.8 (hosts memcached)
#     ./run_leaf_cache.sh compute     # on 10.30.1.6
#   Both machines MUST pass identical knobs (lockstep) -- CACHE_LEAF changes only
#   compute-node behaviour, but the run structure has to line up cell for cell.
#
# BUILD FIRST (leaf caching is ON by default; it adds an 8-byte coherence stamp
# per leaf allocation, so BOTH nodes must run a binary built the same way):
#     cd .. && mkdir -p build && cd build \
#       && cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON .. && make -j
#
# PLOT:
#     python3 ../results/plot_leaf_cache.py        # auto-finds the newest sweep
#
# Knobs (env, all overridable):
#     LEAF_SET        "0 1"        the leaf axis
#     LEAF_CACHE_PCT  50           leaf share of the TOTAL, in percent
#     LEAF_CACHE_MB   -            absolute leaf budget (overrides the %)
#     CACHE_MB    "512 256 128 64"      TOTAL compute-side cache points, MB
#     SEQUENCE        "off on"     offload modes
#     WORKLOADS       all four
#     DIR_THREADS     4
#     BULK/WARMUP/POINT_OP/RANGE_OP  50/10/50/50 (M)   (PROFILE=quick for 10M)
#
# To find the best SPLIT rather than the best total, pin the total and sweep the
# share -- the inner/leaf trade-off at fixed memory:
#     CACHE_MB=256 LEAF_SET=1 LEAF_CACHE_PCT=25 ./run_leaf_cache.sh memory
#   (repeat for 50 / 75; each run's summary CSV records inner_cache_mb and
#    leaf_cache_mb, which must sum to total_cache_mb.)
# ===========================================================================
role="${1:?usage: run_leaf_cache.sh <memory|compute>}"

case "${PROFILE:-}" in
  quick) : "${BULK:=10}"; : "${WARMUP:=2}"; : "${POINT_OP:=10}"; : "${RANGE_OP:=10}" ;;
  final|"") : "${BULK:=50}"; : "${WARMUP:=10}"; : "${POINT_OP:=50}"; : "${RANGE_OP:=50}" ;;
  *) echo "unknown PROFILE=$PROFILE (use quick|final)" >&2; exit 1 ;;
esac

# leaf OFF first so every plot reads "inner nodes only, then inner + leaves".
export LEAF_SET="${LEAF_SET:-0 1}"
export LEAF_CACHE_PCT="${LEAF_CACHE_PCT:-50}"
export LEAF_CACHE_MB="${LEAF_CACHE_MB:-}"

# The DART cache points, high -> low, so the plots read "as the cache shrinks".
# These are TOTALS: inner + leaf, matching what DART is given at the same point.
export CACHE_MB="${CACHE_MB:-512 256 128 64}"
export WORKLOADS="${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf}"
export SEQUENCE="${SEQUENCE:-off on}"
export DIR_THREADS="${DIR_THREADS:-4}"
export BULK WARMUP POINT_OP RANGE_OP
export ZIPF_THETA="${ZIPF_THETA:-0.99}"
export SCAN_RANGE="${SCAN_RANGE:-100}"
export LOG_DIR="${LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/results/leaf_cache}"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence "$role"
