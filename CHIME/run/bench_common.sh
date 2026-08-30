#!/bin/bash
# ===========================================================================
# bench_common.sh  --  shared config + helpers for CHIME two-node offload runs
#
# Sourced by:
#   run_memory.sh   -> run ON the memory node  (becomes CHIME node 0 = MN)
#   run_compute.sh  -> run ON the compute node (becomes CHIME node 1 = CN)
#
# IMPORTANT: unlike DART (separate bin/memory + bin/compute), CHIME runs the
# SAME binary (test/micro_test) on every machine. Role is decided at RUNTIME by
# node id: the node that registers first in memcached gets id 0 and, because
# MEMORY_NODE_NUM=1, becomes the memory node (starts the Directory/dir-threads).
# So the two scripts run the identical benchmark; they differ only in
#   (a) the memory node also (re)starts memcached and registers FIRST, and
#   (b) the log tag.
# Both machines MUST use the same WORKLOAD + OFFLOAD for a valid run.
#
# Coordination is memcached (memcached.conf), NOT DART's TCP monitor.
# ===========================================================================
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIME_DIR="$(cd "$RUN_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$CHIME_DIR/build}"
BIN="$BUILD_DIR/micro_test"
COMMON_H="$CHIME_DIR/include/Common.h"   # holds kIndexCacheSize (cache-sweep knob)

# --- cluster (edit to match your machines; memory hosts memcached) ---------
MEM_IP="${MEM_IP:-10.30.1.8}"   # memory node  -> CHIME node 0 (MN); runs memcached
CMP_IP="${CMP_IP:-10.30.1.6}"   # compute node -> CHIME node 1 (CN)
MEMC_PORT="${MEMC_PORT:-11211}"
# Pid file for the memcached this script manages. Per-user by default: a shared
# /tmp/memcached.pid owned by root (from a sudo run) cannot be removed or its pid
# killed by an ordinary user, and the failure used to pass unnoticed.
MEMC_PID="${MEMC_PID:-/tmp/memcached-$(id -un).pid}"
NODES="${NODES:-2}"             # total machines (1 MN + 1 CN)

# --- workload knobs (MUST match on both machines) --------------------------
THREADS="${THREADS:-24}"        # app threads per node
WORKLOAD="${WORKLOAD:-point-uniform}"  # point-uniform|point-zipf|range-uniform|range-zipf
ZIPF_THETA="${ZIPF_THETA:-0.99}"
SCAN_RANGE="${SCAN_RANGE:-100}"
BULK="${BULK:-50}"; WARMUP="${WARMUP:-10}"
POINT_OP="${POINT_OP:-50}"; RANGE_OP="${RANGE_OP:-50}"   # 50M ops per cell (DEX/DART-scale)

# Memory-node dir (RPC-serving) threads -- the DEX "memory threads" equivalent.
# MUST be identical on both machines: the MN spawns this many, the CN shards RPCs
# over this many. Mismatch => RPCs to a dir nobody polls => hangs reported as a
# lock "Deadlock". Offload's ceiling is this number of MN cores, so it is the knob
# that decides whether offload can compete with NIC-served one-sided reads at all.
DIR_THREADS="${DIR_THREADS:-4}"

# --- offload A/B: OFFLOAD=on -> rate 100 ; OFFLOAD=off -> rate 0 ------------
OFFLOAD="${OFFLOAD:-on}"
if [[ -z "${OFFLOAD_RATE:-}" ]]; then
  case "$OFFLOAD" in
    on|ON|1|100) OFFLOAD_RATE=100 ;;
    off|OFF|0)   OFFLOAD_RATE=0 ;;
    *) echo "OFFLOAD must be on|off (got '$OFFLOAD')" >&2; exit 1 ;;
  esac
fi

# --- leaf-node caching A/B (CACHE_LEAF=0|1) ---------------------------------
# Stock CHIME caches INTERNAL nodes only, so every point lookup pays one remote
# read for the leaf even on a full index-cache hit. CACHE_LEAF=1 turns on the
# compute-side LEAF cache (include/LeafCache.h) so the compute node caches BOTH
# node types: a cached leaf answers a lookup with one 16-byte validation read
# instead of a segment read, and a range scan validates the leaves it holds
# instead of reading each covered leaf in full.
#
# !! CHIME_CACHE_MB IS THE TOTAL !!  index + leaf ALWAYS sums to the sweep point,
# in both arms. DART is compared at a fixed total compute-side budget, so the leaf
# cache must NOT be extra memory on top -- otherwise a win only says "CHIME was
# given more RAM". At 256 MB: CACHE_LEAF=0 is 256 index / 0 leaf, CACHE_LEAF=1 is
# 128 / 128. Caching leaves has to earn its share against the inner nodes it
# displaces, and that trade-off is the experiment.
#
#   CACHE_LEAF      0|1   runtime switch -- ONE binary serves both arms, exactly
#                         like OFFLOAD. Must match on both machines.
#   LEAF_CACHE_PCT  50    leaf share of the TOTAL, in percent (rest -> inner nodes).
#                         Sweep it at a fixed total to find where memory pays best.
#   LEAF_CACHE_MB   -     absolute leaf budget; overrides LEAF_CACHE_PCT if set.
#   LEAF_SET        -     if set (e.g. "0 1"), CACHE_LEAF becomes a swept axis and
#                         a leaf_<v>/ level is added to the results tree. Unset =>
#                         single CACHE_LEAF value and the original layout.
#
# Coherence is not a knob: a cached leaf is ALWAYS validated with a [lock, stamp]
# probe before it is served, so the cache is correct under concurrent writers.
CACHE_LEAF="${CACHE_LEAF:-0}"
LEAF_CACHE_PCT="${LEAF_CACHE_PCT:-50}"
LEAF_CACHE_MB="${LEAF_CACHE_MB:-}"

LOG_DIR="${LOG_DIR:-$CHIME_DIR/build/results/offload_ab}"

# micro_test args: readR insertR updateR rangeR uniform(1|0) theta bulkM warmM opM
workload_args() {
  case "$WORKLOAD" in
    point-uniform) echo "100 0 0 0   1 0            $BULK $WARMUP $POINT_OP" ;;
    point-zipf)    echo "100 0 0 0   0 $ZIPF_THETA  $BULK $WARMUP $POINT_OP" ;;
    range-uniform) echo "0 0 0 100   1 0            $BULK $WARMUP $RANGE_OP" ;;
    range-zipf)    echo "0 0 0 100   0 $ZIPF_THETA  $BULK $WARMUP $RANGE_OP" ;;
    *) echo "unknown WORKLOAD=$WORKLOAD" >&2; exit 1 ;;
  esac
}
needs_scan_range() { [[ "$WORKLOAD" == range-* ]]; }

# Kill anything this user left running from a previous cell, on THIS node.
#
# A micro_test can outlive its cell: dsm->barrier() is a memcached spin with no
# timeout, so if the peer crashes the survivor waits forever, holding its queue
# pairs and its memcached registration. The next cell then registers behind it,
# is handed the wrong node id, builds queue pairs against a process that is not
# its peer, and dies with "transport retry counter exceeded" -- which reads as an
# RDMA fault and is nothing of the sort. One stale process poisons every cell
# after it, so clear the ground before each one.
#
# Safe to do unconditionally: run_one is sequential, so by the time it is called
# the previous cell's process has already exited normally. Anything still alive
# IS stale. Scoped to this uid so a co-tenant's run on a shared machine is never
# touched. Set NO_KILL_STALE=1 to skip (e.g. if you are deliberately running a
# second CHIME experiment side by side).
kill_stale_local() {
  local role="$1"
  [[ -n "${NO_KILL_STALE:-}" ]] && return 0
  local stale
  stale="$(pgrep -u "$(id -u)" -f micro_test 2>/dev/null | tr '\n' ' ' || true)"
  [[ -z "${stale// /}" ]] && return 0
  echo ">> [$role] killing stale micro_test from a previous cell: $stale"
  pkill -u "$(id -u)" -f micro_test 2>/dev/null || true
  sleep 2
  pkill -9 -u "$(id -u)" -f micro_test 2>/dev/null || true
  sleep 1
  stale="$(pgrep -u "$(id -u)" -f micro_test 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "${stale// /}" ]]; then
    echo "ERROR: could not kill stale micro_test ($stale) -- another user's?" >&2
    echo "       Clear it before continuing; leaving it running corrupts this cell." >&2
    exit 1
  fi
}

# start memcached locally on the memory node and reset the node counters
#
# EVERY failure here used to be silent -- the kill was `2>/dev/null || true`, the
# start was unchecked, and the counter resets were `|| true`. If a memcached from
# an earlier run (possibly owned by ANOTHER USER, e.g. one started under sudo) was
# still bound to the port, the kill no-opped, the restart failed, and the whole
# sweep then ran against a stale instance carrying leftover serverNum / barrier
# keys. That hands out wrong node ids, so the two nodes build mismatched QPs and
# the run dies with "transport retry counter exceeded" -- a failure that looks
# like an RDMA problem and is nothing of the sort. Fail loudly instead.
start_memcached_local() {
  # One implementation, in script/restartMemc.sh, so the thing you can run by
  # hand to unstick a machine is the same thing the sweep runs per cell.
  MEMC_PID="$MEMC_PID" MEMC_CONF="$CHIME_DIR/memcached.conf" \
    bash "$CHIME_DIR/script/restartMemc.sh" || {
      echo "ERROR: could not restart memcached -- see above. Aborting the sweep" >&2
      echo "       rather than running cells against stale coordination state." >&2
      exit 1
    }
}

# Compute side: wait for the memory node to have registered, instead of guessing.
#
# The old `sleep 4` was a blind race, and losing it is how cells died. Keeper's
# serverEnter INCREMENTS serverNum, and the memory node's freshly restarted
# memcached starts it at 0 -- so serverNum becomes exactly 1 when node 0 has
# registered and nobody else has. Waiting for that value is precise:
#   <no answer>  memcached not up yet (memory node still restarting it)
#   0            memcached fresh, memory node's micro_test not registered yet
#   1            READY -- this is our cue
#   >=2          a STALE instance from a previous cell that was never reset; the
#                memory node is about to restart it, so keep waiting rather than
#                registering into it and being handed the wrong node id.
wait_for_memory_node() {
  local deadline=$(( $(date +%s) + ${MEMC_WAIT:-600} ))
  local v last=""
  echo ">> [compute] waiting for the memory node to register (serverNum -> 1)"
  while :; do
    v="$( { printf 'get serverNum\r\nquit\r\n' | nc -w 3 "$MEM_IP" "$MEMC_PORT" 2>/dev/null \
            | tr -d '\r' | sed -n '2p'; } || true)"
    [[ "$v" == "1" ]] && { echo ">> [compute] memory node is up (serverNum=1)"; sleep 1; return 0; }
    if [[ "$v" != "$last" ]]; then
      echo ">> [compute]   serverNum='${v:-<no answer>}' ..."
      last="$v"
    fi
    if (( $(date +%s) > deadline )); then
      echo "ERROR: memory node never registered within ${MEMC_WAIT:-600}s." >&2
      echo "       Last serverNum='${v:-<no answer>}' at ${MEM_IP}:${MEMC_PORT}." >&2
      echo "       Check that the memory node is running this same cell." >&2
      exit 1
    fi
    sleep 1
  done
}

mode_to_rate() { case "$1" in on) echo 100 ;; off) echo 0 ;; *) echo "$1" ;; esac; }

# One benchmark run of a single offload mode.
#   $1 = role (memory|compute)   $2 = offload mode (off|on)   $3 = output dir
# Writes:  $3/<mode>/<role>.log   and appends a row to  $3/summary_<role>.csv
run_one() {
  local role="$1" mode="$2" outdir="$3"
  local rate; rate="$(mode_to_rate "$mode")"

  # keep the on-disk memcached.conf in sync so the binary dials the right host.
  # Also read by script/restartMemc.sh below, so it must precede the restart.
  printf '%s\n%s\n' "$MEM_IP" "$MEMC_PORT" > "$CHIME_DIR/memcached.conf"

  kill_stale_local "$role"         # clear survivors of a previous cell FIRST

  if [[ "$role" == "memory" ]]; then
    start_memcached_local          # fresh node-id counters for THIS round
  else
    wait_for_memory_node           # handshake, not a blind sleep
  fi

  local dir="$outdir/$WORKLOAD/$mode"; mkdir -p "$dir"
  local log="$dir/${role}.log"
  local args; args="$(workload_args)"
  local cmd=("$BIN" "$NODES" "$THREADS" $args "$rate")
  needs_scan_range && cmd+=("$SCAN_RANGE")

  # Deterministic role pinning (read by Keeper::serverEnter). The memory node is
  # ALWAYS CHIME node 0 (MN); the compute node is ALWAYS node 1 (CN). Without
  # this the id is assigned by memcached registration order, a race that can swap
  # the two roles between rounds and corrupt every RDMA completion. MUST be 0 for
  # memory / 1 for compute -- and both nodes must run a binary built AFTER this
  # change (grep CHIME_NODE_ID in the source to confirm).
  local node_id; [[ "$role" == "memory" ]] && node_id=0 || node_id=1

  # All runtime knobs travel as env, so one build covers every cell of the sweep.
  local envs=(CHIME_NODE_ID="$node_id" CHIME_DIR_THREADS="$DIR_THREADS")
  [[ "${CACHE_CUR:-}" =~ ^[0-9]+$ ]] && envs+=(CHIME_CACHE_MB="$CACHE_CUR")
  local leaf="${LEAF_CUR:-$CACHE_LEAF}"
  envs+=(CHIME_CACHE_LEAF="$leaf")
  if [[ "$leaf" != "0" ]]; then
    envs+=(CHIME_LEAF_CACHE_PCT="$LEAF_CACHE_PCT")
    [[ -n "$LEAF_CACHE_MB" ]] && envs+=(CHIME_LEAF_CACHE_MB="$LEAF_CACHE_MB")
  fi

  echo; echo "############################################################"
  echo "## OFFLOAD=$mode (rate=$rate)  role=$role  WORKLOAD=$WORKLOAD"
  echo "## TOTAL cache=${CACHE_CUR:-build}MB  CACHE_LEAF=$leaf  leaf share=${LEAF_CACHE_MB:-${LEAF_CACHE_PCT}%}"
  echo "## ${cmd[*]}"
  echo "## log: $log"
  echo "############################################################"; echo
  # stdbuf -oL: line-buffer through the `| tee` pipe, otherwise progress prints
  # sit in a 4KB buffer during the (slow) bulk load and the run looks hung.
  ( cd "$BUILD_DIR" && env "${envs[@]}" stdbuf -oL -eL "${cmd[@]}" ) 2>&1 | tee "$log"

  # ---- extract headline numbers into a CSV row -------------------------
  # Throughput now comes from micro_test's [RESULT] line: this node's exact
  # total ops / wall time over the whole measured phase. Each node reports its
  # OWN rate (the old "cluster throughput" line used a dsm->sum collective that
  # only node 0 saw and that read stale values once the nodes desynced) -- the
  # cluster total is the SUM of the two nodes' values, done in post-processing.
  # The trailing "|| true" keeps a non-matching grep from aborting the sweep
  # under `set -euo pipefail`.
  local tput lat ops
  tput="$( { grep -E '^\[RESULT node' "$log" | tail -1 | sed -nE 's/.*throughput=([0-9.]+) Mops.*/\1/p'; } 2>/dev/null || true)"
  ops="$( { grep -E '^\[RESULT node' "$log" | tail -1 | sed -nE 's/.*ops=([0-9]+).*/\1/p'; } 2>/dev/null || true)"
  lat="$( { awk '/^\[ALL OPS\]/{f=1} f&&/^  ALL /{print; f=0}' "$log" \
           | sed -nE 's/.*p99=[[:space:]]*([0-9.]+)us.*/\1/p' | head -1; } 2>/dev/null || true)"
  # index_mb = the TRUE index working set, measured (not estimated) from
  # TreeCache's post-bulk-load occupancy. Recorded per row so every cell says
  # whether its cache was above or below the index -- i.e. whether eviction ran.
  local idx
  idx="$( { grep -E '^consumed cache size' "$log" | tail -1 \
           | sed -nE 's/.*= ([0-9.]+) MB.*/\1/p'; } 2>/dev/null || true)"
  # The ACTUAL split this cell ran, from micro_test's [CACHE node N] line, and the
  # leaf hit rate from the last [LEAFCACHE] line (printed after the measured
  # phase). Recording the split rather than the knob is the point: every row can
  # be checked for inner_mb + leaf_mb == total_mb, so a mis-set env var shows up as
  # a number instead of an unexplained result. hit_pct says whether leaf caching
  # had anything to work with -- expect near 0 under a uniform distribution and
  # high under zipf, since a leaf is only worth caching when its keys are re-read.
  local ltotal linner lleaf lhit
  ltotal="$( { grep -E '^\[CACHE node' "$log" | tail -1 \
              | sed -nE 's/.*total=([0-9]+) MB.*/\1/p'; } 2>/dev/null || true)"
  linner="$( { grep -E '^\[CACHE node' "$log" | tail -1 \
              | sed -nE 's/.*index=([0-9]+) MB.*/\1/p'; } 2>/dev/null || true)"
  lleaf="$( { grep -E '^\[CACHE node' "$log" | tail -1 \
             | sed -nE 's/.*leaf=([0-9]+) MB.*/\1/p'; } 2>/dev/null || true)"
  lhit="$( { grep -E '^\[LEAFCACHE\] hit=' "$log" | tail -1 \
            | sed -nE 's/.*hit_pct=([0-9.]+).*/\1/p'; } 2>/dev/null || true)"
  local csv="${SWEEP_CSV:-$outdir/summary_${role}.csv}"
  [[ -f "$csv" ]] || echo "cache_mb,dir_threads,workload,offload,role,node_tput_mops,ops,p99_us,index_mb,cache_leaf,total_cache_mb,inner_cache_mb,leaf_cache_mb,leaf_hit_pct,log" > "$csv"
  echo "${CACHE_CUR:-NA},${DIR_THREADS},${WORKLOAD},${mode},${role},${tput:-NA},${ops:-NA},${lat:-NA},${idx:-NA},${leaf},${ltotal:-NA},${linner:-NA},${lleaf:-NA},${lhit:-NA},${log}" >> "$csv"
}

# One WORKLOADS x SEQUENCE matrix into $2.  $1 = role, $2 = outdir
_run_cells() {
  local role="$1" outdir="$2"
  local wls=(${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf})
  local seq=(${SEQUENCE:-off on})
  local m
  for WORKLOAD in "${wls[@]}"; do        # global: workload_args()/run_one read it
    for m in "${seq[@]}"; do
      run_one "$role" "$m" "$outdir"
      sleep 3           # let memcached / QPs settle before the next round
    done
  done
}

# [LEAF_SET x] WORKLOADS x SEQUENCE.  $1 = role, $2 = outdir
# LEAF_SET unset keeps the historical layout byte-for-byte (<wl>/<off|on>/), so
# the existing plotters and committed sweeps still parse. Set it (e.g. "0 1") and
# a leaf_<v>/ level appears above it, giving a 3-way axis: cache x offload x leaf.
_run_matrix() {
  local role="$1" outdir="$2"
  local leaves=(${LEAF_SET:-})
  local l
  if [[ ${#leaves[@]} -eq 0 ]]; then
    LEAF_CUR="$CACHE_LEAF"
    _run_cells "$role" "$outdir"
  else
    for l in "${leaves[@]}"; do
      LEAF_CUR="$l"                      # read by run_one (env + CSV column)
      _run_cells "$role" "$outdir/leaf_${l}"
    done
  fi
}

# Run the full matrix, DEX/DART-style, optionally sweeping the cache size:
#   [CACHE_MB sizes x] WORKLOADS x SEQUENCE (off then on).
# If CACHE_MB is set (e.g. "4 8 16 32 64 128"), kIndexCacheSize is set + rebuilt
# for each size (both machines must pass the SAME list). If unset, the current
# build's cache is used. Both machines MUST use the same knobs -> lockstep.
#   $1 = role (memory|compute)
run_sequence() {
  local role="$1"
  local caches=(${CACHE_MB:-})

  if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN not found -- build first:" >&2
    echo "  cd $CHIME_DIR && mkdir -p build && cd build && cmake -DENABLE_OFFLOAD=ON .. && make -j" >&2
    exit 1
  fi

  local ts host base
  ts="${SEQ_TS:-$(date +%Y%m%d_%H%M%S)}"
  host="$(hostname -s 2>/dev/null || hostname)"
  base="$LOG_DIR/sweep_${ts}"
  mkdir -p "$base"
  SWEEP_CSV="$base/summary_${role}.csv"     # all rows (all cache points) land here

  echo ">> SWEEP: workloads=[${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf}]  offload=[${SEQUENCE:-off on}]  role=$role"
  echo ">>        point op=${POINT_OP}M  range op=${RANGE_OP}M scan_range=${SCAN_RANGE}  zipf theta=${ZIPF_THETA}"
  if [[ -n "${LEAF_SET:-}" ]]; then
    echo ">>        LEAF CACHE axis CACHE_LEAF=[${LEAF_SET}], leaf share=${LEAF_CACHE_MB:-${LEAF_CACHE_PCT}%} of the TOTAL cache (inner+leaf = the sweep point)"
  else
    echo ">>        leaf cache: CACHE_LEAF=${CACHE_LEAF}, leaf share=${LEAF_CACHE_MB:-${LEAF_CACHE_PCT}%} of the TOTAL"
  fi
  echo ">>        results -> $base"

  if [[ ${#caches[@]} -eq 0 ]]; then
    echo ">>        cache: current build (kIndexCacheSize unchanged)"
    CACHE_CUR="build"
    _run_matrix "$role" "$base"
  else
    echo ">>        CACHE SWEEP CHIME_CACHE_MB=[${caches[*]}] (runtime, no rebuild)"
    local cmb
    for cmb in "${caches[@]}"; do
      CACHE_CUR="$cmb"                     # passed to micro_test as CHIME_CACHE_MB
      _run_matrix "$role" "$base/cache_${cmb}MB"
    done
  fi

  echo; echo "==================== SWEEP SUMMARY ($role) ===================="
  cat "$SWEEP_CSV" 2>/dev/null || true
  echo
  echo "all logs + summary CSV under: $base"
  echo "  layout: $base/[cache_<MB>/][leaf_<0|1>/]<workload>/<off|on>/${role}.log"
  echo "=============================================================="
}
