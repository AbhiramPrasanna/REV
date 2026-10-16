#!/bin/bash
# ===========================================================================
# fair/multi/run_chime_multi.sh <build|memory|compute> -- CHIME with NMN memory
# and NCN compute processes (default 2 + 4): the memory processes on server 8,
# the compute processes on server 6, over CACHES x MEMTHREADS x WORKLOADS.
#
# CHIME's nodes 0..NMN-1 are its memory nodes, a build constant
# (-DCHIME_MEMORY_NODES); `build` makes that binary in CHIME/build_<setup>_mn<NMN>.
# Every process gets its node id from CHIME_NODE_ID: memory processes 0..NMN-1,
# compute processes NMN..NMN+NCN-1. The memory side coordinates, as in
# fair/run_chime.sh: it restarts memcached (on MEM_IP), writes "mcell" and starts
# its processes; the compute side waits for that cell and for the memory processes,
# then starts its own. The tree is bulk-built by the last node (a compute process)
# and spread over the memory nodes. Pushed lookups that reach the other memory node
# are finished by the compute node ([PUSHX]); scans are pulled with NMN > 1;
# CHIME_PUSH_LOCATE (a write's walk pushed) works; CHIME_PUSH_WRITES=2 does not
# (it needs one memory node).
#
#   both servers, once:  RUN_ID=b TREE_SETUP=deep VALUE_B=64 bash fair/multi/run_chime_multi.sh build
#   server 8:  RUN_ID=m1 TREE_SETUP=deep VALUE_B=64 KEYS_M=60 CHIME_BUILD_LEAF_KEYS=4 \
#                CHIME_BUILD_INNER_FANOUT=5 CHIME_HOTSPOT=0 \
#                bash fair/multi/run_chime_multi.sh memory  2>&1 | tee ~/chimem_memory.out
#   server 6:  (the same variables) bash fair/multi/run_chime_multi.sh compute 2>&1 | tee ~/chimem_compute.out
#
# Variables (the SAME on both servers): NCN NMN THREADS (total clients, a multiple
# of NCN) CACHES MEMTHREADS WORKLOADS UPDATE_PCT INSERT_PCT OPS_M WARMUP_M KEYS_M
# VALUE_B TREE_SETUP CHIME_* switches (CHIME_PUSH_LOCATE, CHIME_HOTSPOT, ...);
# CN_DSM_GB / MN_DSM_GB (memory pool per compute / memory process, 2 / 30 GB).
# Output: fair/results/$RUN_ID/chime_multi/ -- one log per process per cell and
# chime_multi.csv (compute side): cluster throughput = the sum of the compute
# processes' [RESULT] lines, p99 = the worst compute process.
# ===========================================================================
role="${1:?usage: run_chime_multi.sh <build|memory|compute>}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/multi_common.sh"

MBUILD="$CHIME_BUILD"; [ "$NMN" -gt 1 ] && MBUILD="${CHIME_BUILD}_mn${NMN}"
BIN="$MBUILD/micro_test"

if [ "$role" = build ]; then
  pad=0; [ "$VALUE_B" -gt 8 ] && pad=$((VALUE_B - 8))
  echo "== CHIME for $NMN memory nodes ($TREE_SETUP: spans ${CHIME_INTERNAL_SPAN}/${CHIME_LEAF_SPAN}, value ${VALUE_B} B) -> $MBUILD"
  rm -rf "$MBUILD" && mkdir -p "$MBUILD" && cd "$MBUILD" || exit 1
  cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_MEMORY_NODES="$NMN" \
        -DCHIME_VALUE_LEN="$VALUE_B" -DCHIME_INTERNAL_SPAN="$CHIME_INTERNAL_SPAN" \
        -DCHIME_LEAF_SPAN="$CHIME_LEAF_SPAN" -DCHIME_RPC_VALUE_PAD="$pad" .. || exit 1
  make -j"$(nproc)" micro_test || exit 1
  grep -q "MEMORY_NODE_NUM=$NMN" CMakeFiles/micro_test.dir/flags.make || [ "$NMN" = 1 ] || { echo "build has no MEMORY_NODE_NUM=$NMN" >&2; exit 1; }
  echo "   ok: $BIN"
  exit 0
fi

[ -x "$BIN" ] || { echo "build first, on both servers: RUN_ID=b TREE_SETUP=$TREE_SETUP VALUE_B=$VALUE_B NMN=$NMN bash fair/multi/run_chime_multi.sh build" >&2; exit 1; }
if [ "${CHIME_PUSH_WRITES:-0}" = 2 ] && [ "$NMN" -gt 1 ]; then
  echo "CHIME_PUSH_WRITES=2 needs one memory node" >&2; exit 1
fi
OUT="$RESULTS_DIR/chime_multi"; mkdir -p "$OUT"
max_mt=1; for m in $MEMTHREADS; do [ "$m" -gt "$max_mt" ] && max_mt=$m; done
check_layout "$max_mt" || exit 1
hugepage_note "$role" 5
echo "CHIME multi: $NMN memory + $NCN compute processes, $T clients each ($THREADS in all), tree $TREE_SETUP, memory pool ${MN_DSM_GB} / ${CN_DSM_GB} GB, binary $BIN"

# the switches fair/run_chime.sh exports, same defaults
export CHIME_MN_CLIENTS=0 CHIME_CACHE_LEAF=0
export CHIME_SCAN_FROM_CACHE="${CHIME_SCAN_FROM_CACHE:-1}"
export CHIME_SCAN_OFFLOAD_ALWAYS="${CHIME_SCAN_OFFLOAD_ALWAYS:-1}"
export CHIME_HOTSPOT="${CHIME_HOTSPOT:-1}"
export CHIME_SORTED_LOAD CHIME_BULK_BUILD CHIME_BUILD_LEAF_KEYS CHIME_BUILD_INNER_FANOUT
CHIME_DIR="$REV_DIR/CHIME"
printf '%s\n%s\n' "$MEM_IP" "$MEMC_PORT" > "$CHIME_DIR/memcached.conf"
csv="$OUT/chime_multi.csv"
[ "$role" = compute ] && [ ! -f "$csv" ] && \
  echo "system,workload,cache_mb,memthreads,ncn,nmn,threads,update_pct,insert_pct,tput_mops,p99_us,round_trips_per_op,lookups_crossed,writes_located,cn_tputs,log_prefix" > "$csv"

[ "$role" = compute ] && note_stale_cell "$MEM_IP" "$MEMC_PORT"
cells=0; for mt in $MEMTHREADS; do for wl in $WORKLOADS; do for c in $CACHES; do cells=$((cells+1)); done; done; done
i=0
for mt in $MEMTHREADS; do
  if [ "$mt" -eq 0 ]; then rate=0; dir=1; else rate=100; dir=$mt; fi
  for wl in $WORKLOADS; do
    upd=${UPDATE_PCT:-0}; ins=${INSERT_PCT:-0}; r=$((100 - upd - ins))
    [ "$(wl_op "$wl")" = point ] || { echo "run_chime_multi.sh runs point workloads only (got $wl)" >&2; exit 1; }
    if [ "$(wl_dist "$wl")" = uniform ]; then dist="1 0"; else dist="0 $ZIPF_THETA"; fi
    for cache in $CACHES; do
      i=$((i+1))
      mix=""; [ "$upd" != 0 ] && mix="${mix}_u$upd"; [ "$ins" != 0 ] && mix="${mix}_i$ins"
      tag="chimem_${wl}${mix}_mt${mt}_cache${cache}"
      echo ">>> [$(date +%H:%M:%S)] ($i/$cells) $tag  ($role)"
      #  args: nodes threads(per process) read insert update range uniform theta bulkM warmupM opM rate
      args=("$NODES" "$T" "$r" "$ins" "$upd" 0 $dist "$KEYS_M" "$WARMUP_M" "$OPS_M" "$rate")
      envs=(CHIME_DIR_THREADS="$dir" CHIME_CACHE_MB="$cache")
      pkill -9 -u "$(id -u)" -x micro_test 2>/dev/null; sleep 1
      pids=()
      if [ "$role" = memory ]; then
        MEMC_CONF="$CHIME_DIR/memcached.conf" bash "$CHIME_DIR/script/restartMemc.sh" >/dev/null || {
          echo "memcached restart failed (CHIME/script/restartMemc.sh)" >&2; exit 1; }
        set_cell "$MEM_IP" "$MEMC_PORT" "$i"
        for ((m = 0; m < NMN; m++)); do
          ( cd "$MBUILD" && env "${envs[@]}" CHIME_NODE_ID="$m" REV_CPU_BASE="$m" \
              REV_DIR_CPUS="$(mn_dir_cpus $m "$dir")" CHIME_DSM_GB="$MN_DSM_GB" \
              stdbuf -oL -eL "$BIN" "${args[@]}" ) > "$OUT/${tag}.mn$m.log" 2>&1 &
          pids+=($!)
        done
        wait_count "$MEM_IP" "$MEMC_PORT" serverNum "$NMN" "the memory processes to register" || exit 1
      else
        wait_cell "$MEM_IP" "$MEMC_PORT" "$i" || exit 1
        wait_count "$MEM_IP" "$MEMC_PORT" serverNum "$NMN" "the $NMN memory processes" || exit 1
        for ((c = 0; c < NCN; c++)); do
          ( cd "$MBUILD" && env "${envs[@]}" CHIME_NODE_ID=$((NMN + c)) REV_CPU_BASE="$(cn_cpu_base $c)" \
              REV_DIR_CPUS="$(cn_dir_cpus $c)" CHIME_DSM_GB="$CN_DSM_GB" \
              stdbuf -oL -eL "$BIN" "${args[@]}" ) > "$OUT/${tag}.cn$c.log" 2>&1 &
          pids+=($!)
        done
      fi
      for p in "${pids[@]}"; do wait "$p"; done
      if [ "$role" = compute ]; then
        logs=(); for ((c = 0; c < NCN; c++)); do logs+=("$OUT/${tag}.cn$c.log"); done
        per=$(for f in "${logs[@]}"; do sed -nE 's/^\[RESULT node [0-9]+\].*throughput=([0-9.]+) Mops.*/\1/p' "$f" | tail -1 | tr '\n' ' '; done)
        tput=$(echo "$per" | awk '{for (j = 1; j <= NF; j++) s += $j} END {if (NF) printf "%.4f", s; else print "NA"}')
        p99=$(max_p99 "${logs[@]}")
        rt=$(for f in "${logs[@]}"; do sed -nE 's/.*\[RDMA node [0-9]+\] per_op: round_trips=([0-9.]+).*/\1/p' "$f" | tail -1; done |
             awk '{s += $1; n++} END {if (n) printf "%.4f", s / n; else print "NA"}')
        crossed=$(for f in "${logs[@]}"; do sed -nE 's/.*\[PUSHX\].*finished here=([0-9]+).*/\1/p' "$f" | tail -1; done | awk '{s += $1} END {print s + 0}')
        located=$(for f in "${logs[@]}"; do sed -nE 's/.*\[PUSHLOC\].*pushed=([0-9]+).*/\1/p' "$f" | tail -1; done | awk '{s += $1} END {print s + 0}')
        echo "chime,$wl,$cache,$mt,$NCN,$NMN,$THREADS,$upd,$ins,$tput,$p99,$rt,$crossed,$located,${per% },$OUT/$tag" >> "$csv"
        echo "    -> cluster $tput Mops (compute processes: ${per% })  p99 $p99 us  round trips/op $rt  lookups finished here $crossed  write walks pushed $located"
      else
        echo "    -> memory processes done"
      fi
      sleep 3
    done
  done
done
echo "CHIME multi ($role) done -> $OUT"
