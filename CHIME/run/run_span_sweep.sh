#!/bin/bash
# ===========================================================================
# run_span_sweep.sh  --  CHIME INNER-NODE-SIZE sweep (internalSpanSize / fanout)
#
# Companion to run_dex_cache_sweep.sh. That script sweeps the *cache* (a runtime
# env knob, one build). This one sweeps the *inner-node size* -- internalSpanSize
# in include/Common.h -- which is a compile-time constexpr, so it needs ONE
# REBUILD PER POINT. It answers the "breadth" question: over how wide a range of
# inner-node configurations does the system still run at a good rate, and how far
# does offloading widen that range beyond the single proposed geometry (S=16)?
#
#   Bigger S  -> bigger inner nodes (43 + 17*S bytes) AND a shallower tree.
#   One-sided (offload off) has a sweet spot near the proposed S and degrades at
#   both ends (small S: deep tree, many hops per miss; large S: read-amplified,
#   internal node eventually bigger than a leaf). Offload on collapses the whole
#   walk into ONE RPC regardless of S, so it stays flat -- covering a much wider
#   base of node sizes. Cache is held FIXED so node size is the only variable.
#
# WHY A TWO-PHASE DESIGN
#   Phase 1 (BUILD): each node independently rebuilds one binary per span into
#     its own build_span_<S>/ dir -- no inter-node coordination while compiling.
#   Phase 2 (RUN): loop the spans in lockstep exactly like the cache sweep --
#     per-round memcached restart on the memory node, the compute node waits --
#     just swapping in the pre-built binary for each span. Reuses the proven
#     coordination in bench_common.sh (run_one/_run_matrix), no timed rebuilds.
#
# RUN THE MEMORY NODE FIRST, THEN THE COMPUTE NODE WITH THE SAME ARGS:
#   ./run_span_sweep.sh memory      # on 10.30.1.7 (hosts memcached)
#   ./run_span_sweep.sh compute     # on 10.30.1.6
# Both machines MUST pass the SAME SPANS / WORKLOADS / SEQUENCE / CACHE_MB.
#
# Every knob is overridable, e.g.:
#   SPANS="8 16 32 64" WORKLOADS="point-uniform range-uniform" ./run_span_sweep.sh memory
#   CACHE_MB=32 SPANS="16 64" ./run_span_sweep.sh compute
#   REBUILD=0 ./run_span_sweep.sh memory      # reuse existing build_span_* dirs
# ===========================================================================
role="${1:?usage: run_span_sweep.sh <memory|compute>}"

# --- sweep axes ------------------------------------------------------------
# Inner-node fanout points. 16 is the committed geometry ("proposed"); 32/64/128
# are progressively bigger inner nodes (the "larger base" side of the story).
# NOTE: S=8 is intentionally EXCLUDED -- fanout 8 builds a ~9-level tree for 50M
# keys, which trips a tree-DEPTH limit in the traversal/buffer path (point runs
# squeak through at level 8, but scans flood with "Failed status" RDMA errors at
# level 9). S=16 and up stay <=6 levels and are safe for point AND scan. Add 8
# back only if you first raise that depth limit.
export SPANS="${SPANS:-16 32 64 128}"

# Cache is FIXED for this sweep (node size is the only variable). Default 64MB --
# below the ~88MB index so one-sided caching is genuinely stressed and the
# offload win is visible. Applied at runtime (CHIME_CACHE_MB), no rebuild.
export CACHE_MB="${CACHE_MB:-64}"

# Include range scans by default (point + range, uniform + zipf).
export WORKLOADS="${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf}"
export SEQUENCE="${SEQUENCE:-off on}"
export DIR_THREADS="${DIR_THREADS:-4}"

export BULK="${BULK:-50}"; export WARMUP="${WARMUP:-10}"
export POINT_OP="${POINT_OP:-50}"; export RANGE_OP="${RANGE_OP:-50}"
export ZIPF_THETA="${ZIPF_THETA:-0.99}"; export SCAN_RANGE="${SCAN_RANGE:-100}"

REBUILD="${REBUILD:-1}"                 # 0 = reuse existing build_span_<S> dirs
CMAKE_FLAGS="${CMAKE_FLAGS:--DENABLE_OFFLOAD=ON}"   # matches the offload build
MAKE_JOBS="${MAKE_JOBS:-$(nproc 2>/dev/null || echo 8)}"

# Pull in the shared helpers (run_one, _run_matrix, workload_args,
# start_memcached_local, MEM_IP/CMP_IP/MEMC_PORT, ...). We deliberately do NOT
# call run_sequence -- we drive our own span loop below.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"

# --------------------------------------------------------------------------
# Phase 1: build one binary per span (independent per node).
#   build_span_<S>/micro_test  <- cmake -DCHIME_INTERNAL_SPAN=<S>
# Each build_span_<S> sits directly under CHIME_DIR, so micro_test's relative
# ../memcached.conf still resolves exactly as it does from build/.
# --------------------------------------------------------------------------
build_all_spans() {
  local S bdir
  for S in $SPANS; do
    bdir="$CHIME_DIR/build_span_${S}"
    if [[ "$REBUILD" == "0" && -x "$bdir/micro_test" ]]; then
      echo ">> [build] reuse $bdir/micro_test (REBUILD=0)"
      continue
    fi
    echo; echo ">> [build] internalSpanSize=$S -> $bdir"
    mkdir -p "$bdir"
    ( cd "$bdir" && cmake $CMAKE_FLAGS -DCHIME_INTERNAL_SPAN="$S" "$CHIME_DIR" \
        && make -j"$MAKE_JOBS" micro_test )
    [[ -x "$bdir/micro_test" ]] || { echo "ERROR: build failed for span $S" >&2; exit 1; }
  done
}

# compute node: block until the memory node's memcached is up before round 1, so
# the first micro_test doesn't race an in-progress build on the memory side.
wait_for_memcached() {
  echo ">> [compute] waiting for memcached on ${MEM_IP}:${MEMC_PORT} (memory node finishing its builds)"
  until nc -z "$MEM_IP" "$MEMC_PORT" 2>/dev/null; do sleep 2; done
  echo ">> [compute] memcached is up"
}

# --------------------------------------------------------------------------
# Phase 2: run the WORKLOADS x SEQUENCE matrix once per span, lockstep.
# Layout:  span_sweep_<ts>/span_<S>/<workload>/<off|on>/<role>.log
# --------------------------------------------------------------------------
main() {
  build_all_spans

  local ts base S bdir
  ts="${SEQ_TS:-$(date +%Y%m%d_%H%M%S)}"
  base="$LOG_DIR/span_sweep_${ts}"
  mkdir -p "$base"

  echo ">> SPAN SWEEP  role=$role  spans=[$SPANS]  cache=${CACHE_MB}MB (fixed)"
  echo ">>   workloads=[$WORKLOADS]  offload=[$SEQUENCE]  dir_threads=$DIR_THREADS"
  echo ">>   results -> $base"
  echo ">>   layout: $base/span_<S>/<workload>/<off|on>/${role}.log"

  [[ "$role" == "compute" ]] && wait_for_memcached

  CACHE_CUR="$CACHE_MB"                 # fixed cache passed as CHIME_CACHE_MB
  for S in $SPANS; do
    bdir="$CHIME_DIR/build_span_${S}"
    BUILD_DIR="$bdir"; BIN="$bdir/micro_test"   # run_one reads these globals
    SWEEP_CSV="$base/span_${S}/summary_${role}.csv"
    mkdir -p "$base/span_${S}"
    echo; echo "########## internalSpanSize = $S  (bin: $BIN) ##########"
    _run_matrix "$role" "$base/span_${S}"
  done

  echo; echo "==================== SPAN SWEEP DONE ($role) ===================="
  echo "logs + per-span summary CSVs under: $base"
  echo "plot with:  python3 results/plot_span_sweep.py \"$base\""
  echo "================================================================"
}

main
