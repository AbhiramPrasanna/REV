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
# ONE CELL AT A TIME (preferred for a long study -- no tmux, nothing to babysit):
#     export SEQ_TS=full1 ; export CACHE_MB=512
#     ./run_leaf_cache.sh memory  point-zipf on 1      # then the same on compute
#   Cells sharing SEQ_TS accumulate into one sweep dir + one summary CSV.
#   See SINGLE-CELL MODE below for the argument form and the full 16-cell list.
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
role="${1:?usage: run_leaf_cache.sh <memory|compute> [workload] [off|on] [0|1]}"

# ---- SINGLE-CELL MODE ------------------------------------------------------
# No extra args  -> run the whole matrix (LEAF_SET x WORKLOADS x SEQUENCE).
# Extra args     -> run EXACTLY ONE cell:
#       ./run_leaf_cache.sh <role> <workload> <off|on> <0|1>
#
# This is the way to drive the study by hand. Every invocation that shares a
# SEQ_TS appends to the SAME sweep directory and the SAME summary CSV, so cells
# can be run one at a time, in any order, over as many sessions as you like, and
# the plotters still see one coherent sweep. The 16 cells of the study are:
#
#   for W in point-uniform point-zipf range-uniform range-zipf; do
#     for O in off on; do for L in 0 1; do  ./run_leaf_cache.sh <role> $W $O $L
#
# Run the memory node first for each cell, then the compute node.
if [ $# -ge 2 ]; then
  case "$2" in
    point-uniform|point-zipf|range-uniform|range-zipf) WORKLOADS="$2" ;;
    *) echo "workload must be point-uniform|point-zipf|range-uniform|range-zipf (got '$2')" >&2; exit 1 ;;
  esac
fi
if [ $# -ge 3 ]; then
  case "$3" in
    off|on) SEQUENCE="$3" ;;
    *) echo "offload must be off|on (got '$3')" >&2; exit 1 ;;
  esac
fi
if [ $# -ge 4 ]; then
  case "$4" in
    0|1) LEAF_SET="$4" ;;
    *) echo "leaf must be 0|1 (got '$4')" >&2; exit 1 ;;
  esac
fi

# Op counts default to the DART comparison contract: 50M keys loaded, 30M
# measured ops -- the same KEY_COUNT/OP_COUNT the committed DART baseline used
# (DART/cache_sweep_baseline_*.csv records them per row). Override per run if a
# scan cell is taking too long; throughput is a rate, so a shorter measured
# phase is still valid, just noisier -- keep it identical across compared cells.
case "${PROFILE:-}" in
  quick) : "${BULK:=10}"; : "${WARMUP:=2}"; : "${POINT_OP:=10}"; : "${RANGE_OP:=10}" ;;
  final|"") : "${BULK:=50}"; : "${WARMUP:=10}"; : "${POINT_OP:=30}"; : "${RANGE_OP:=30}" ;;
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
