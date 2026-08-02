#!/bin/bash
# ===========================================================================
# run_stress_sweep.sh  --  CHIME inner-node STRESS test (fat nodes x cache)
#
# Purpose: push CHIME's B+-tree until it breaks. Sweep the inner-node size
# (internalSpanSize -- "how fat can the inner nodes get") across several cache
# configurations, for BOTH point queries and range scans, WITH and WITHOUT
# offloading, and record -- per cell -- whether it survived and at what rate.
# The result shows the operating envelope: how much fatter offloading lets CHIME
# go before it falls over, versus caching-only (original CHIME).
#
# THIS IS A STRESS TEST: some cells are EXPECTED to fail (that's the point --
# we're finding the breaking point). The driver is built so that a failing cell
# NEVER hangs or aborts the sweep. Each cell is:
#   * time-bounded            (CELL_TIMEOUT -- a hang can't stall the run),
#   * flood-detected          (killed the moment it spews "Failed status ..."),
#   * straggler-killed + settled between cells, and
#   * re-synchronized         (fresh memcached + PINNED roles via CHIME_NODE_ID),
# so after any failure both nodes cleanly line up on the next cell. Every cell's
# outcome (ok / failed-rdma / timeout / failed-noresult / build-failed) lands in
# a summary CSV, and a survival matrix is printed at the end.
#
# Inner-node size is a COMPILE-TIME constant, so we rebuild one binary per span
# up front (build_span_<S>/), then run the cache x workload x offload matrix per
# span. We sweep LEAN -> FAT (small -> large internalSpanSize) to find the
# breaking point on BOTH ends: lean nodes make a deep tree (many splits), fat
# nodes make each cache-missed read huge. Concurrent bulk-load used to corrupt
# the lean end; with the DEX-style single-threaded sorted load (default now,
# micro_test LOADER_NUM=1 + std::sort) lean trees build too, so the whole range
# is fair game. A span whose binary won't build (extreme fanout) is recorded
# build-failed and skipped -- that is itself a data point.
#
# RUN THE MEMORY NODE FIRST, THEN THE COMPUTE NODE WITH THE SAME ARGS:
#   ./run_stress_sweep.sh memory      # on 10.30.1.7 (hosts memcached)
#   ./run_stress_sweep.sh compute     # on 10.30.1.6
# Both machines MUST pass the SAME SPANS / CACHE_MB_LIST / WORKLOADS / SEQUENCE.
#
# Knobs (env, all overridable):
#   SPANS           inner-node sizes to rebuild+test   (default 8 16 32 64 128 256 512)
#   CACHE_MB_LIST   cache configs, runtime, no rebuild (default 16 64)
#   WORKLOADS       point + range, both distributions  (default all four)
#   SEQUENCE        offload modes                       (default "off on")
#   CELL_TIMEOUT    hard cap per cell, seconds          (default 600)
#   FLOOD_LINES     kill a cell after this many "Failed status" lines (default 15)
#   SETTLE          quiet seconds between cells         (default 8)
#   BULK/WARMUP/POINT_OP/RANGE_OP  op counts (M)        (defaults 50/10/50/50)
#   REBUILD         1 rebuild all spans, 0 reuse build_span_*  (default 1)
#
# Quick logic check on a laptop (tiny + fast): BULK=1 WARMUP=0 POINT_OP=1 ...
# ===========================================================================
role="${1:?usage: run_stress_sweep.sh <memory|compute>}"

# An explicit CHIME_LOADERS pins the loader count for ALL spans; otherwise it
# AUTO-SCALES per span (lean/deep trees need fewer -- see loaders_for_span).
# Capture the override before anything else touches it.
USER_LOADERS="${CHIME_LOADERS:-}"

# PROFILE presets (optional). quick = fast 10M-key iteration; final = 50M-key
# publication numbers. Any individual knob you set still overrides the preset.
case "${PROFILE:-}" in
  quick) : "${BULK:=10}"; : "${WARMUP:=2}"; : "${POINT_OP:=10}"; : "${RANGE_OP:=10}" ;;
  final) : "${BULK:=50}"; : "${WARMUP:=10}"; : "${POINT_OP:=50}"; : "${RANGE_OP:=50}" ;;
  "")    ;;
  *)     echo "unknown PROFILE=$PROFILE (use quick|final)" >&2; exit 1 ;;
esac

export SPANS="${SPANS:-8 16 32 64 128 256 512}"   # lean -> fat (rebuild per span)
export CACHE_MB_LIST="${CACHE_MB_LIST:-16 64}"    # small & mid: index >> and ~ cache
export WORKLOADS="${WORKLOADS:-point-uniform point-zipf range-uniform range-zipf}"
export SEQUENCE="${SEQUENCE:-off on}"
export DIR_THREADS="${DIR_THREADS:-4}"
export BULK="${BULK:-50}"; export WARMUP="${WARMUP:-10}"
export POINT_OP="${POINT_OP:-50}"; export RANGE_OP="${RANGE_OP:-50}"
export ZIPF_THETA="${ZIPF_THETA:-0.99}"; export SCAN_RANGE="${SCAN_RANGE:-100}"

CELL_TIMEOUT="${CELL_TIMEOUT:-600}"
FLOOD_LINES="${FLOOD_LINES:-15}"
SETTLE="${SETTLE:-8}"
REBUILD="${REBUILD:-1}"
CMAKE_FLAGS="${CMAKE_FLAGS:--DENABLE_OFFLOAD=ON}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc 2>/dev/null || echo 8)}"

# Pull in shared config + helpers (MEM_IP/CMP_IP/MEMC_PORT, NODES, THREADS,
# workload_args, needs_scan_range, mode_to_rate, start_memcached_local, ...).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
# bench_common enables `set -euo pipefail`; take MANUAL control so a single bad
# cell (nonzero exit, empty grep, killed process) can NEVER abort the sweep.
set +e +o pipefail

kill_stragglers() { pkill -9 -f "micro_test" 2>/dev/null; }

# Per-span bulk-load parallelism. Split masked-CAS is EMULATED (non-atomic) on the
# rdma-core port, so many concurrent loaders wedge a lean/deep tree -- fanout 8
# does far more internal-node splits than fanout 64+. Scale loaders UP with fanout:
# lean = few (safe, confirmed S=8 needs 1), fat = 8 (fast). CHIME_LOADERS overrides.
loaders_for_span() {
  [ -n "$USER_LOADERS" ] && { echo "$USER_LOADERS"; return; }
  local s="$1"
  if   [ "$s" -le 8 ];  then echo 1
  elif [ "$s" -le 16 ]; then echo 2
  elif [ "$s" -le 32 ]; then echo 4
  else                       echo 8
  fi
}

wait_for_memcached() {   # compute side: block until the memory node's memcached is up
  local waited=0
  until nc -z "$MEM_IP" "$MEMC_PORT" 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
    [ "$waited" -ge "$CELL_TIMEOUT" ] && { echo ">> [compute] memcached never came up (${waited}s)"; return 1; }
  done
  return 0
}

# ---------------------------------------------------------------------------
# Phase 1: build one binary per span. A build failure marks that span so its
# cells are skipped -- it does NOT stop the sweep.
# ---------------------------------------------------------------------------
declare -A SPAN_OK
build_all_spans() {
  local S bdir
  for S in $SPANS; do
    bdir="$CHIME_DIR/build_span_${S}"
    if [ "$REBUILD" = "0" ] && [ -x "$bdir/micro_test" ]; then
      echo ">> [build] reuse $bdir/micro_test"; SPAN_OK[$S]=1; continue
    fi
    echo; echo ">> [build] internalSpanSize=$S -> $bdir"
    mkdir -p "$bdir"
    if ( cd "$bdir" && cmake $CMAKE_FLAGS -DCHIME_INTERNAL_SPAN="$S" "$CHIME_DIR" \
           && make -j"$MAKE_JOBS" micro_test ) && [ -x "$bdir/micro_test" ]; then
      SPAN_OK[$S]=1
    else
      echo "!! [build] FAILED for span $S -- its cells will be skipped"
      SPAN_OK[$S]=0
    fi
  done
}

# ---------------------------------------------------------------------------
# run_cell: run ONE (span,cache,workload,mode) cell robustly. Always returns 0;
# the outcome is recorded via the global CELL_STATUS/CELL_TPUT/... and appended
# to the summary CSV by the caller.
# ---------------------------------------------------------------------------
run_cell() {
  local S="$1" cache="$2" wl="$3" mode="$4" outdir="$5"
  WORKLOAD="$wl"                                   # workload_args reads this global
  local dir="$outdir/$wl/$mode"; mkdir -p "$dir"
  local log="$dir/${role}.log"
  local rate; rate="$(mode_to_rate "$mode")"
  local args; args="$(workload_args)"
  local cmd=("$CHIME_DIR/build_span_${S}/micro_test" "$NODES" "$THREADS" $args "$rate")
  needs_scan_range && cmd+=("$SCAN_RANGE")
  local nid; [ "$role" = "memory" ] && nid=0 || nid=1

  # reset per-cell outputs FIRST so an early return can never emit stale numbers
  # from the previous cell into the CSV.
  CELL_STATUS="pending"; CELL_TPUT="NA"; CELL_P99="NA"; CELL_IDX="NA"
  CELL_ELAPSED=0; CELL_FLOODS=0

  # keep the on-disk memcached.conf pointing at the memory node
  printf '%s\n%s\n' "$MEM_IP" "$MEMC_PORT" > "$CHIME_DIR/memcached.conf"

  # per-cell resync: memory restarts memcached fresh (resets node-id counters);
  # compute waits until it is reachable. Combined with CHIME_NODE_ID pinning this
  # realigns the two nodes even if the PREVIOUS cell failed/was killed.
  if [ "$role" = "memory" ]; then
    start_memcached_local
  else
    wait_for_memcached || { CELL_STATUS="no-memcached"; return 0; }
    sleep 2
  fi

  local ld; ld="$(loaders_for_span "$S")"
  echo; echo "#### span=$S cache=${cache}MB wl=$wl offload=$mode loaders=$ld role=$role"
  echo "#### ${cmd[*]}"

  SECONDS=0
  ( cd "$CHIME_DIR/build_span_${S}" \
      && CHIME_NODE_ID="$nid" CHIME_LOADERS="$ld" CHIME_CACHE_MB="$cache" \
         CHIME_DIR_THREADS="$DIR_THREADS" \
         stdbuf -oL -eL "${cmd[@]}" ) > "$log" 2>&1 &
  local pid=$!

  CELL_STATUS=""; local floods=0
  while kill -0 "$pid" 2>/dev/null; do
    # grep -c prints "0" and exits 1 on no match -- capture the number only, never
    # let the nonzero exit append a second token (that broke the -ge test).
    floods="$(grep -c 'Failed status' "$log" 2>/dev/null)"
    [[ "$floods" =~ ^[0-9]+$ ]] || floods=0
    if [ "$floods" -ge "$FLOOD_LINES" ]; then CELL_STATUS="failed-rdma"; break; fi
    if [ "$SECONDS" -ge "$CELL_TIMEOUT" ]; then CELL_STATUS="timeout"; break; fi
    sleep 2
  done
  # stop the binary (and its subshell) for good, whatever happened
  kill_stragglers; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  local elapsed="$SECONDS"

  # classify a naturally-exited process
  if [ -z "$CELL_STATUS" ]; then
    if grep -q '^\[RESULT' "$log" 2>/dev/null; then CELL_STATUS="ok"
    elif [ "$elapsed" -ge "$CELL_TIMEOUT" ]; then CELL_STATUS="timeout"
    else CELL_STATUS="failed-noresult"; fi
  fi

  # pull numbers (best-effort) from a successful log
  CELL_TPUT="NA"; CELL_P99="NA"; CELL_IDX="NA"
  if [ "$CELL_STATUS" = "ok" ]; then
    CELL_TPUT="$(grep -E '^\[RESULT node' "$log" | tail -1 | sed -nE 's/.*throughput=([0-9.]+) Mops.*/\1/p')"
    CELL_P99="$(awk '/^\[ALL OPS\]/{f=1} f&&/^  ALL /{print;f=0}' "$log" | sed -nE 's/.*p99=[[:space:]]*([0-9.]+)us.*/\1/p' | head -1)"
    CELL_IDX="$(grep -E '^consumed cache size' "$log" | tail -1 | sed -nE 's/.*= ([0-9.]+) MB.*/\1/p')"
  fi
  CELL_ELAPSED="$elapsed"; CELL_FLOODS="$floods"
  echo ">> RESULT span=$S cache=${cache} wl=$wl $mode -> ${CELL_STATUS} (tput=${CELL_TPUT:-NA}, ${elapsed}s, floods=${floods})"

  sleep "$SETTLE"                                  # quiet gap so QPs/memcached settle
  return 0
}

# ---------------------------------------------------------------------------
# main: nested sweep + summary. Nothing here can abort on a cell failure.
# ---------------------------------------------------------------------------
main() {
  build_all_spans

  local ts base csv
  ts="${SEQ_TS:-$(date +%Y%m%d_%H%M%S)}"
  base="$LOG_DIR/stress_${ts}"
  mkdir -p "$base"
  csv="$base/summary_${role}.csv"
  echo "span,cache_mb,dir_threads,workload,offload,role,status,node_tput_mops,p99_us,index_mb,elapsed_s,failed_lines,log" > "$csv"

  echo ">> STRESS SWEEP  role=$role"
  echo ">>   spans=[$SPANS]  caches=[$CACHE_MB_LIST]MB  workloads=[$WORKLOADS]  offload=[$SEQUENCE]"
  echo ">>   cell_timeout=${CELL_TIMEOUT}s  flood_lines=${FLOOD_LINES}  settle=${SETTLE}s"
  echo ">>   results -> $base"

  local S cache wl mode outdir
  for S in $SPANS; do
    if [ "${SPAN_OK[$S]:-0}" != "1" ]; then
      echo ">> span $S NOT BUILT -- recording build-failed cells"
      for cache in $CACHE_MB_LIST; do for wl in $WORKLOADS; do for mode in $SEQUENCE; do
        echo "$S,$cache,$DIR_THREADS,$wl,$mode,$role,build-failed,NA,NA,NA,0,0," >> "$csv"
      done; done; done
      continue
    fi
    for cache in $CACHE_MB_LIST; do
      for wl in $WORKLOADS; do
        for mode in $SEQUENCE; do
          outdir="$base/span_${S}/cache_${cache}MB"
          run_cell "$S" "$cache" "$wl" "$mode" "$outdir"
          echo "$S,$cache,$DIR_THREADS,$wl,$mode,$role,${CELL_STATUS},${CELL_TPUT:-NA},${CELL_P99:-NA},${CELL_IDX:-NA},${CELL_ELAPSED:-0},${CELL_FLOODS:-0},$outdir/$wl/$mode/${role}.log" >> "$csv"
        done
      done
    done
  done

  echo; echo "==================== STRESS SWEEP DONE ($role) ===================="
  echo "summary CSV: $csv"
  echo
  echo "---- survival matrix (status per span x cache, one grid per workload/offload) ----"
  awk -F, 'NR>1 {k=$4" "$5; key=k SUBSEP $1 SUBSEP $2; st[key]=$7;
                 sp[$1]=1; ca[$2]=1; grp[k]=1}
       END{ for(g in grp){ printf "\n[%s]\n        ", g;
              n=asorti(ca,cs,"@ind_num_asc"); for(i=1;i<=n;i++) printf "c%-6s", cs[i];
              printf "\n"; m=asorti(sp,ss,"@ind_num_asc");
              for(i=1;i<=m;i++){ printf "S%-6s", ss[i];
                for(j=1;j<=n;j++){ v=st[g SUBSEP ss[i] SUBSEP cs[j]]; if(v=="")v="-";
                  printf "%-7s", substr(v,1,6) } printf "\n" } } }' "$csv" 2>/dev/null \
    || echo "(install gawk for the matrix; the CSV has every cell)"
  echo
  echo "summary CSV columns: span,cache_mb,dir_threads,workload,offload,role,status,"
  echo "  node_tput_mops,p99_us,index_mb,elapsed_s,failed_lines,log"
  echo "index/cache ratio per cell = index_mb / cache_mb (how many x the inner-node"
  echo "  index is vs the cache); status=ok cells carry throughput + p99."
  echo "=================================================================="
}

main
