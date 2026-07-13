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

# --- cluster (edit to match your machines; memory hosts memcached) ---------
MEM_IP="${MEM_IP:-10.30.1.8}"   # memory node  -> CHIME node 0 (MN); runs memcached
CMP_IP="${CMP_IP:-10.30.1.6}"   # compute node -> CHIME node 1 (CN)
MEMC_PORT="${MEMC_PORT:-11211}"
NODES="${NODES:-2}"             # total machines (1 MN + 1 CN)

# --- workload knobs (MUST match on both machines) --------------------------
THREADS="${THREADS:-24}"        # app threads per node
WORKLOAD="${WORKLOAD:-point-uniform}"  # point-uniform|point-zipf|range-uniform|range-zipf
ZIPF_THETA="${ZIPF_THETA:-0.99}"
SCAN_RANGE="${SCAN_RANGE:-100}"
BULK="${BULK:-50}"; WARMUP="${WARMUP:-10}"
POINT_OP="${POINT_OP:-50}"; RANGE_OP="${RANGE_OP:-50}"   # 50M ops per cell (DEX/DART-scale)

# --- offload A/B: OFFLOAD=on -> rate 100 ; OFFLOAD=off -> rate 0 ------------
OFFLOAD="${OFFLOAD:-on}"
if [[ -z "${OFFLOAD_RATE:-}" ]]; then
  case "$OFFLOAD" in
    on|ON|1|100) OFFLOAD_RATE=100 ;;
    off|OFF|0)   OFFLOAD_RATE=0 ;;
    *) echo "OFFLOAD must be on|off (got '$OFFLOAD')" >&2; exit 1 ;;
  esac
fi

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

# start memcached locally on the memory node and reset the node counters
start_memcached_local() {
  echo ">> [memory] (re)starting memcached on ${MEM_IP}:${MEMC_PORT}"
  [[ -f /tmp/memcached.pid ]] && xargs kill < /tmp/memcached.pid 2>/dev/null || true
  sleep 1
  memcached -u root -l "$MEM_IP" -p "$MEMC_PORT" -c 10000 -d -P /tmp/memcached.pid
  sleep 1
  printf 'set serverNum 0 0 1\r\n0\r\nquit\r\n' | nc "$MEM_IP" "$MEMC_PORT" >/dev/null || true
  printf 'set clientNum 0 0 1\r\n0\r\nquit\r\n' | nc "$MEM_IP" "$MEMC_PORT" >/dev/null || true
}

mode_to_rate() { case "$1" in on) echo 100 ;; off) echo 0 ;; *) echo "$1" ;; esac; }

# One benchmark run of a single offload mode.
#   $1 = role (memory|compute)   $2 = offload mode (off|on)   $3 = output dir
# Writes:  $3/<mode>/<role>.log   and appends a row to  $3/summary_<role>.csv
run_one() {
  local role="$1" mode="$2" outdir="$3"
  local rate; rate="$(mode_to_rate "$mode")"

  # keep the on-disk memcached.conf in sync so the binary dials the right host
  printf '%s\n%s\n' "$MEM_IP" "$MEMC_PORT" > "$CHIME_DIR/memcached.conf"

  if [[ "$role" == "memory" ]]; then
    start_memcached_local          # fresh node-id counters for THIS round
  else
    echo ">> [compute] waiting 4s so the memory node registers as node 0 first"
    sleep 4
  fi

  local dir="$outdir/$WORKLOAD/$mode"; mkdir -p "$dir"
  local log="$dir/${role}.log"
  local args; args="$(workload_args)"
  local cmd=("$BIN" "$NODES" "$THREADS" $args "$rate")
  needs_scan_range && cmd+=("$SCAN_RANGE")

  echo; echo "############################################################"
  echo "## OFFLOAD=$mode (rate=$rate)  role=$role  WORKLOAD=$WORKLOAD"
  echo "## ${cmd[*]}"
  echo "## log: $log"
  echo "############################################################"; echo
  ( cd "$BUILD_DIR" && "${cmd[@]}" ) 2>&1 | tee "$log"

  # ---- extract headline numbers into a CSV row -------------------------
  # NOTE: the trailing "|| true" is essential -- these greps legitimately match
  # nothing on the COMPUTE node ("cluster throughput" only prints on node 0), and
  # under `set -euo pipefail` a failing pipeline would abort the whole sequence
  # after the first round (that's the "only ran OFFLOAD=off" bug).
  local tput lat
  tput="$( { grep -E 'cluster throughput' "$log" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1; } 2>/dev/null || true)"
  lat="$( { awk '/^\[ALL OPS\]/{f=1} f&&/^  ALL /{print; f=0}' "$log" \
           | sed -nE 's/.*p99=[[:space:]]*([0-9.]+)us.*/\1/p' | head -1; } 2>/dev/null || true)"
  local csv="$outdir/summary_${role}.csv"
  [[ -f "$csv" ]] || echo "workload,offload,role,cluster_tput_mops,p99_us,log" > "$csv"
  echo "${WORKLOAD},${mode},${role},${tput:-NA},${lat:-NA},${log}" >> "$csv"
}

# Run the full matrix back-to-back, DEX/DART-style:
#   WORKLOADS (default all 4 cells) x SEQUENCE (default off then on).
# Both machines MUST use the same WORKLOADS + SEQUENCE so they stay in lockstep
# (each micro_test round ends on a shared barrier).
#   $1 = role (memory|compute)
run_sequence() {
  local role="$1"
  local wls=(${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf})
  local seq=(${SEQUENCE:-off on})

  if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN not found -- build first:" >&2
    echo "  cd $CHIME_DIR && mkdir -p build && cd build && cmake -DENABLE_OFFLOAD=ON .. && make -j" >&2
    exit 1
  fi

  local ts host outdir
  ts="${SEQ_TS:-$(date +%Y%m%d_%H%M%S)}"
  host="$(hostname -s 2>/dev/null || hostname)"
  outdir="$LOG_DIR/sweep_${ts}"
  mkdir -p "$outdir"

  echo ">> SWEEP: workloads=[${wls[*]}]  offload=[${seq[*]}]  role=$role"
  echo ">>        point op=${POINT_OP}M  range op=${RANGE_OP}M scan_range=${SCAN_RANGE}  zipf theta=${ZIPF_THETA}"
  echo ">>        results -> $outdir"
  local m
  for WORKLOAD in "${wls[@]}"; do        # global: workload_args()/run_one read it
    for m in "${seq[@]}"; do
      run_one "$role" "$m" "$outdir"
      sleep 3           # let memcached / QPs settle before the next round
    done
  done

  echo; echo "==================== SWEEP SUMMARY ($role) ===================="
  cat "$outdir/summary_${role}.csv" 2>/dev/null || true
  echo
  echo "all logs + summary CSV under: $outdir"
  echo "  layout: $outdir/<workload>/<off|on>/${role}.log"
  echo "=============================================================="
}
