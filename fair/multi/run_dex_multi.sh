#!/bin/bash
# ===========================================================================
# fair/multi/run_dex_multi.sh <compute|memory> -- DEX with NCN compute and NMN
# memory processes (default 4 + 2): the compute processes on server 6, the
# memory processes on server 8, over the same CACHES x MEMTHREADS x WORKLOADS
# sweep as fair/run_dex.sh.
#
# DEX names its nodes in the order they register with memcached, and nodes
# 0..NCN-1 are the compute nodes (newbench: computeNR = THREADS / kMaxThread).
# So the compute side restarts memcached, starts its processes one at a time
# (each after the previous one registered), and writes "mcell"; the memory side
# waits for mcell and for all NCN compute processes, then starts its own, one at a
# time. Node 0 (a compute process) holds the root pointer and bulk-loads; with
# MN_ONLY placement every tree node lives on the memory processes, each subtree
# below megaLevel on one of them, so DEX's own push rule stays on one memory node.
# DEX_PUSH_READS_DEEPEST=1 (DEX-R, our miss-gated push: reads pushed from the deepest
# cached node, as in Lesson 3); writes keep DEX's own rule. Cells _dexr, system dex-r.
# DEX_PUSH_WRITES_LOCATE=1 as well (DEX-C, CHIME's write rule in DEX): a write that
# misses pushes only its walk and the compute process writes the leaf. Cells _dexc,
# system dex-c.
# DEX_PUSH_CHAIN (default 1): a pushed walk -- lookup, scan or write walk -- that
# reaches a node on the other memory node is carried on there (one more push);
# counted in chained_*; lookups_crossed = pushed lookups that were not carried on
# and fell back to DEX's own rule. DEX_PUSH_CHAIN=0: cells tagged _nochain.
#
#   server 8:  RUN_ID=m1 TREE_SETUP=model DEX_INNER_PAGE=240 VALUE_B=64 KEYS_M=60 \
#                bash fair/multi/run_dex_multi.sh memory  2>&1 | tee ~/dexm_memory.out
#   server 6:  (the same variables) bash fair/multi/run_dex_multi.sh compute 2>&1 | tee ~/dexm_compute.out
#
# Variables (the SAME on both servers): NCN NMN THREADS (total clients, a multiple
# of NCN) CACHES MEMTHREADS WORKLOADS UPDATE_PCT INSERT_PCT OPS_M WARMUP_M KEYS_M
# VALUE_B TREE_SETUP DEX_INNER_PAGE DEX_SAFE_PT DEX_PUSH_READS_DEEPEST DEX_PUSH_WRITES_LOCATE
# DEX_PUSH_CHAIN; CN_DSM_GB / MN_DSM_GB (memory pool
# per compute / memory process, default 2 / 30 GB).
# DEX_MN_HOST_LOCKS=1: the memory processes keep their lock table in host memory
# too. The NIC's on-chip memory fits only two tables, so it defaults to 1 when
# NMN > 2 (else 0, on-chip as in every single-node run).
# SCAN_PCT: share of 100-key scans in point-* workloads (default 0); range-* = scans only.
# DEX's benchmark gives each compute process its own key range (newbench sharding).
# Needs the DEX build with REV_CPU_BASE / DEX_DSM_GB (newbench.cpp) on both servers:
#   RUN_ID=b TREE_SETUP=model DEX_INNER_PAGE=240 VALUE_B=64 ./fair/build.sh dex
# Output: fair/results/$RUN_ID/dex_multi/ -- one log per process per cell and
# dex_multi.csv (compute side): cluster throughput = the sum of the compute
# processes' throughput, p99 = the worst compute process.
# ===========================================================================
role="${1:?usage: run_dex_multi.sh <compute|memory>}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/multi_common.sh"

DEXR="${DEX_PUSH_READS_DEEPEST:-0}" DEXC="${DEX_PUSH_WRITES_LOCATE:-0}" CHAIN="${DEX_PUSH_CHAIN:-1}"
MN_HOST_LOCKS="${DEX_MN_HOST_LOCKS:-$([ "$NMN" -gt 2 ] && echo 1 || echo 0)}"
if [ "$NMN" -gt 2 ] && [ "$MN_HOST_LOCKS" != 1 ]; then
  echo "NMN=$NMN memory processes need DEX_MN_HOST_LOCKS=1 (the NIC's on-chip memory fits two lock tables)" >&2; exit 1
fi
if [ "$DEXC" = 1 ]; then sysname=dex-c; dtag=_dexc
elif [ "$DEXR" = 1 ]; then sysname=dex-r; dtag=_dexr
else sysname=dex; dtag=""; fi
[ "$CHAIN" = 0 ] && dtag="${dtag}_nochain"
OUT="$RESULTS_DIR/dex_multi"; mkdir -p "$OUT"
BIN="$DEX_BUILD/newbench"
[ -x "$BIN" ] || { echo "build first: RUN_ID=b TREE_SETUP=$TREE_SETUP DEX_INNER_PAGE=$DEX_INNER_PAGE VALUE_B=$VALUE_B ./fair/build.sh dex" >&2; exit 1; }
grep -q "DEX_DSM_GB" "$REV_DIR/dex/test/newbench.cpp" || { echo "this checkout's newbench has no DEX_DSM_GB: git pull, then rebuild" >&2; exit 1; }
max_mt=1; for m in $MEMTHREADS; do [ "$m" -gt "$max_mt" ] && max_mt=$m; done
check_layout "$max_mt" || exit 1
hugepage_note "$role" 3
echo "DEX multi ($sysname, DEX_PUSH_READS_DEEPEST=$DEXR DEX_PUSH_WRITES_LOCATE=$DEXC DEX_PUSH_CHAIN=$CHAIN): $NCN compute + $NMN memory processes, $T clients each ($THREADS in all), tree $TREE_SETUP (inner page $DEX_INNER_PAGE B), memory pool ${CN_DSM_GB} / ${MN_DSM_GB} GB, memory-process locks $([ "$MN_HOST_LOCKS" = 1 ] && echo "in host memory" || echo on-chip)"

cd "$DEX_BUILD"
printf '%s\n%s\n' "$CMP_IP" "$MEMC_PORT" > ../memcached.conf
csv="$OUT/dex_multi.csv"
hdr="system,workload,cache_mb,memthreads,ncn,nmn,threads,update_pct,insert_pct,scan_pct,push_reads_deepest,push_writes_locate,push_chain,tput_mops,cn0_final_mops,p99_us,rdma_read_per_op,rpc_per_op,lookups_crossed,chained_lookups,chained_scans,chained_walks,writes_located,tree_height,ops_ok_pct_min,rows_per_scan,cn_tputs,log_prefix"
if [ "$role" = compute ]; then
  # a CSV written by the older script (other columns) is kept aside, not appended to
  [ -f "$csv" ] && [ "$(head -1 "$csv")" != "$hdr" ] && mv "$csv" "$csv.old-$(date +%s)"
  [ -f "$csv" ] || echo "$hdr" > "$csv"
fi

restart_memcached() {   # compute side
  [ -f /tmp/memcached-fair.pid ] && kill "$(cat /tmp/memcached-fair.pid)" 2>/dev/null
  pkill -f "memcached.*-p[ ]*${MEMC_PORT}" 2>/dev/null
  sleep 1
  local uopt=""; [ "$(id -u)" = 0 ] && uopt="-u root"
  memcached $uopt -l "$CMP_IP" -p "$MEMC_PORT" -c 10000 -d -P /tmp/memcached-fair.pid
  sleep 1
  memc_set_zero "$CMP_IP" "$MEMC_PORT" serverNum && memc_set_zero "$CMP_IP" "$MEMC_PORT" clientNum
}

[ "$role" = memory ] && note_stale_cell "$CMP_IP" "$MEMC_PORT"
cells=0; for mt in $MEMTHREADS; do for wl in $WORKLOADS; do for c in $CACHES; do cells=$((cells+1)); done; done; done
i=0
for mt in $MEMTHREADS; do
  if [ "$mt" -eq 0 ]; then rpc=0; dir=1; else rpc=1; dir=$mt; fi
  for wl in $WORKLOADS; do
    # point-*: (100-U-I-S)% lookups + U% updates + I% inserts + S% 100-key scans
    # (UPDATE_PCT, INSERT_PCT, SCAN_PCT); range-*: scans only
    upd=${UPDATE_PCT:-0}; ins=${INSERT_PCT:-0}; rg=${SCAN_PCT:-0}; r=$((100 - upd - ins - rg))
    [ "$(wl_op "$wl")" = point ] || { r=0; upd=0; ins=0; rg=100; }
    [ "$r" -ge 0 ] || { echo "UPDATE_PCT + INSERT_PCT + SCAN_PCT must be at most 100" >&2; exit 1; }
    if [ "$(wl_dist "$wl")" = uniform ]; then uni=1; else uni=0; fi
    for cache in $CACHES; do
      i=$((i+1))
      mix=""; [ "$upd" != 0 ] && mix="${mix}_u$upd"; [ "$ins" != 0 ] && mix="${mix}_i$ins"
      [ "$(wl_op "$wl")" = point ] && [ "$rg" != 0 ] && mix="${mix}_s$rg"
      tag="dexm_${wl}${mix}${dtag}_mt${mt}_cache${cache}"
      echo ">>> [$(date +%H:%M:%S)] ($i/$cells) $tag  ($role)"
      #  args: nodes r ins upd del range threads(total) memthreads cache uniform theta
      #        bulkM warmupM opM check time_based early_stop index rpc admit tune kmax(per process)
      args=("$NODES" "$r" "$ins" "$upd" 0 "$rg" "$THREADS" "$dir" "$cache" "$uni" "$ZIPF_THETA"
            "$KEYS_M" "$WARMUP_M" "$OPS_M" 0 0 1 0 "$rpc" 0.1 0 "$T")
      envs=(DEX_PUSH_READS_DEEPEST="$DEXR" DEX_PUSH_WRITES_LOCATE="$DEXC" DEX_PUSH_CHAIN="$CHAIN" DEX_SAFE_PT="${DEX_SAFE_PT:-1}" DEX_LEVEL_STATS="${DEX_LEVEL_STATS:-0}")
      sudo -n pkill -9 -x newbench 2>/dev/null; sleep 1
      pids=()
      if [ "$role" = compute ]; then
        restart_memcached || { echo "memcached restart failed" >&2; exit 1; }
        set_cell "$CMP_IP" "$MEMC_PORT" "$i"
        for ((c = 0; c < NCN; c++)); do
          sudo env "${envs[@]}" DEX_HOST_LOCKS=1 REV_CPU_BASE="$(cn_cpu_base $c)" REV_DIR_CPUS="$(cn_dir_cpus $c)" \
            DEX_DSM_GB="$CN_DSM_GB" stdbuf -oL "$BIN" "${args[@]}" > "$OUT/${tag}.cn$c.log" 2>&1 &
          pids+=($!)
          wait_count "$CMP_IP" "$MEMC_PORT" serverNum $((c + 1)) "compute process $c to register" || exit 1
        done
        echo "    compute processes 0..$((NCN - 1)) registered; waiting for the memory side"
      else
        wait_cell "$CMP_IP" "$MEMC_PORT" "$i" || exit 1
        wait_count "$CMP_IP" "$MEMC_PORT" serverNum "$NCN" "the $NCN compute processes" || exit 1
        for ((m = 0; m < NMN; m++)); do
          sudo env "${envs[@]}" DEX_HOST_LOCKS="$MN_HOST_LOCKS" REV_CPU_BASE="$m" REV_DIR_CPUS="$(mn_dir_cpus $m "$dir")" \
            DEX_DSM_GB="$MN_DSM_GB" stdbuf -oL "$BIN" "${args[@]}" > "$OUT/${tag}.mn$m.log" 2>&1 &
          pids+=($!)
          wait_count "$CMP_IP" "$MEMC_PORT" serverNum $((NCN + m + 1)) "memory process $m to register" || exit 1
        done
      fi
      for p in "${pids[@]}"; do wait "$p"; done
      if [ "$role" = compute ]; then
        logs=(); for ((c = 0; c < NCN; c++)); do logs+=("$OUT/${tag}.cn$c.log"); done
        tput=$(sum_over 'total throughput =' "${logs[@]}")
        per=$(for f in "${logs[@]}"; do awk '/total throughput =/{v=$NF} END{printf "%s ", (v!=""?v:"NA")}' "$f"; done)
        fin=$(awk '/Final throughput =/{v=$NF} END{print (v!=""?v:"NA")}' "${logs[0]}")
        p99=$(max_p99 "${logs[@]}")
        rr=$(awk '/Avg. rdma read \/ op =/{s+=$NF; n++} END{if(n) printf "%.4f", s/n; else print "NA"}' "${logs[@]}")
        rp=$(awk '/Avg. rdma rpc \/ op =/{s+=$NF; n++} END{if(n) printf "%.4f", s/n; else print "NA"}' "${logs[@]}")
        # DEX-R: pushed lookups not carried on to the other memory node (summed);
        # pushes carried on there ([DEX-CHAIN]) and DEX-C's pushed write walks ([DEX-C])
        crossed=NA; [ "$DEXR" = 1 ] && crossed=$(sum_over 'not carried on to another memory node' "${logs[@]}")
        chain_of() { for f in "${logs[@]}"; do sed -nE "s/.*\[DEX-CHAIN\] pushes carried on.* $1=([0-9]+).*/\1/p" "$f" | tail -1; done |
                     awk '{s += $1} END {print s + 0}'; }
        cl=$(chain_of lookups); cs=$(chain_of scans); cw=$(chain_of walks)
        located=$(for f in "${logs[@]}"; do sed -nE 's/.*\[DEX-C\] writes whose walk was pushed=([0-9]+).*/\1/p' "$f" | tail -1; done |
                  awk '{s += $1} END {print s + 0}')
        h=$(awk '/Tree height =/{v=$NF} END{print (v!=""?v:"NA")}' "${logs[0]}")
        # correctness across compute processes: worst "ops ok" share, mean rows per scan
        ok=$(sed -nE 's/.*\[CORRECTNESS node [0-9]+\] ops ok [0-9]+ \/ [0-9]+ = ([0-9.]+)%.*/\1/p' "${logs[@]}" |
             awk 'NR==1||$1<m{m=$1} END{if (NR) print m; else print "NA"}')
        rows=$(sed -nE 's/.*\(([0-9.]+) per scan\).*/\1/p' "${logs[@]}" |
               awk '{s+=$1; n++} END{if (n) printf "%.2f", s/n; else print "NA"}')
        echo "$sysname,$wl,$cache,$mt,$NCN,$NMN,$THREADS,$upd,$ins,$rg,$DEXR,$DEXC,$CHAIN,$tput,$fin,$p99,$rr,$rp,$crossed,$cl,$cs,$cw,$located,$h,$ok,$rows,${per% },$OUT/$tag" >> "$csv"
        echo "    -> $sysname cluster $tput Mops (compute processes: ${per% })  p99 $p99 us  reads/op $rr  rpc/op $rp  not carried on $crossed  carried on: lookups $cl scans $cs walks $cw  walks pushed $located  height $h  ops ok (worst) $ok%  rows/scan $rows"
      else
        mlogs=(); for ((m = 0; m < NMN; m++)); do mlogs+=("$OUT/${tag}.mn$m.log"); done
        mn_load_row "$OUT/dex_multi_mnload.csv" "$sysname" "$OUT/$tag" "$mt" "${mlogs[@]}"
      fi
      sleep 3
    done
  done
done
echo "DEX multi ($role) done -> $OUT"
