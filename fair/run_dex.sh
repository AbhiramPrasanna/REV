#!/bin/bash
# ===========================================================================
# fair/run_dex.sh <compute|memory> -- DEX over the fair matrix:
#     MEMTHREADS x WORKLOADS x CACHES
# memory threads 0 = no offloading (rpc_rate 0; one idle directory thread is
# still started because DEX needs one to hand out memory chunks).
# memory threads k >= 1 = offloading on (rpc_rate 1) with k directory threads.
#
# Roles: DEX node 0 is whichever process registers first, and with
# THREADS == kMaxThread node 0 is the compute node. So the COMPUTE server (6)
# hosts memcached and starts first; the MEMORY server (8) waits until the
# compute process has registered, then starts. Start both scripts in any order.
#
#   server 6:  RUN_ID=fair1 ./fair/run_dex.sh compute
#   server 8:  RUN_ID=fair1 ./fair/run_dex.sh memory
#
# Output: fair/results/$RUN_ID/dex/
#   <tag>.compute.log / <tag>.memory.log   per cell
#   dex_compute.csv   throughput, p99, reads and requests per op, tree geometry
#   dex_memory.csv    peak memory-node thread busy % per cell
# ===========================================================================
set -uo pipefail
role="${1:?usage: run_dex.sh <compute|memory>}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/params.sh"

OUT="$RESULTS_DIR/dex"; mkdir -p "$OUT"
BIN="$DEX_BUILD/newbench"
[ -x "$BIN" ] || { echo "build first: RUN_ID=$RUN_ID TREE_SETUP=$TREE_SETUP ./fair/build.sh dex" >&2; exit 1; }
want="inner_page=$DEX_INNER_PAGE leaf_page=$DEX_LEAF_PAGE placement=$DEX_PLACEMENT"
have="$(cat "$DEX_BUILD/build_stamp.txt" 2>/dev/null || echo none)"
if [ "$have" != "$want" ]; then
  echo "DEX binary in $DEX_BUILD was built for [$have], this run wants [$want]." >&2
  echo "Rebuild on BOTH servers: RUN_ID=$RUN_ID TREE_SETUP=$TREE_SETUP ./fair/build.sh dex" >&2
  exit 1
fi
pin_report
echo "DEX setup ($TREE_SETUP): inner page ${DEX_INNER_PAGE} B, leaf page ${DEX_LEAF_PAGE} B, placement ${DEX_PLACEMENT}"
echo "DEX-R (reads pushed from the deepest cached node): ${DEX_PUSH_READS_DEEPEST:-0} (DEX_PUSH_READS_DEEPEST; 0 = stock DEX)"
echo "DEX safe page table: ${DEX_SAFE_PT:-0} (DEX_SAFE_PT; 0 = stock DEX)"

# newbench reads ../memcached.conf relative to its working directory.
cd "$DEX_BUILD"
printf '%s\n%s\n' "$CMP_IP" "$MEMC_PORT" > ../memcached.conf

max_mt=0; for m in $MEMTHREADS; do [ "$m" -gt "$max_mt" ] && max_mt=$m; done
if [ "$role" = compute ]; then preflight_cores $((THREADS + max_mt + 1)); else preflight_cores $((max_mt + 1)); fi

restart_memcached() {   # compute server only
  [ -f /tmp/memcached-fair.pid ] && kill "$(cat /tmp/memcached-fair.pid)" 2>/dev/null
  pkill -f "memcached.*-p[ ]*${MEMC_PORT}" 2>/dev/null
  sleep 1
  local uopt=""; [ "$(id -u)" = 0 ] && uopt="-u root"
  memcached $uopt -l "$CMP_IP" -p "$MEMC_PORT" -c 10000 -d -P /tmp/memcached-fair.pid
  sleep 1
  memc_set_zero "$CMP_IP" "$MEMC_PORT" serverNum || return 1
  memc_set_zero "$CMP_IP" "$MEMC_PORT" clientNum || return 1
  [ "$(memc_get "$CMP_IP" "$MEMC_PORT" serverNum)" = "0" ]
}

wait_for_compute() {    # memory server only: compute has registered as node 0
  local waited=0 v
  while :; do
    v="$(memc_get "$CMP_IP" "$MEMC_PORT" serverNum)"
    [ "$v" = "1" ] && return 0
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge 1800 ]; then
      echo "memory: compute never registered (serverNum='$v') after ${waited}s" >&2
      return 1
    fi
  done
}

csv_c="$OUT/dex_compute.csv"; csv_m="$OUT/dex_memory.csv"
[ "$role" = compute ] && [ ! -f "$csv_c" ] && \
  echo "system,workload,dist,cache_mb,memthreads,offload,leaf,tput_mops,p99_us,rdma_read_per_op,rpc_per_op,tree_height,inner_entries,leaf_entries,placement,log,inner_page_b,leaf_page_b,slot_b,inner_nodes,inner_mb,leaf_nodes,leaf_mb,tree_mb,cache_slots,cache_full_before_measure" > "$csv_c"
[ "$role" = memory ] && [ ! -f "$csv_m" ] && \
  echo "system,workload,cache_mb,memthreads,mn_peak_active_pct,mn_peak_per_thread_pct,log" > "$csv_m"

cells=0
for mt in $MEMTHREADS; do for wl in $WORKLOADS; do for cache in $CACHES; do cells=$((cells+1)); done; done; done
echo "DEX fair sweep ($role): $cells cells, RUN_ID=$RUN_ID -> $OUT"

i=0
for mt in $MEMTHREADS; do
  if [ "$mt" -eq 0 ]; then rpc=0; dir=1; off=off; else rpc=1; dir=$mt; off=on; fi
  for wl in $WORKLOADS; do
    # UPDATE_PCT / INSERT_PCT (default 0): point workloads become
    # (100-U-I)% lookups + U% updates + I% inserts of fresh keys
    upd=0; ins=0
    # mixed-<dist> (for PAll): (100-MIX_SCAN_PCT)% lookups + MIX_SCAN_PCT% scans
    # in one run (default 50/50), so lookups and scans are pushed together.
    if [[ "$wl" == mixed-* ]]; then
      rg=${MIX_SCAN_PCT:-50}; r=$((100 - rg))
    elif [ "$(wl_op "$wl")" = point ]; then
      upd=${UPDATE_PCT:-0}; ins=${INSERT_PCT:-0}; r=$((100 - upd - ins)); rg=0
    else r=0; rg=100; fi
    if [ "$(wl_dist "$wl")" = uniform ]; then uni=1; else uni=0; fi
    for cache in $CACHES; do
      i=$((i+1))
      tag="dex_${wl}_mt${mt}_cache${cache}"
      log="$OUT/${tag}.${role}.log"
      echo ">>> [$(date +%H:%M:%S)] ($i/$cells) $tag"
      #  args: nodes r ins upd del range threads memthreads cache uniform theta
      #        bulkM warmupM opM check time_based early_stop index rpc admit tune kmax
      args=(2 "$r" "$ins" "$upd" 0 "$rg" "$THREADS" "$dir" "$cache" "$uni" "$ZIPF_THETA"
            "$KEYS_M" "$WARMUP_M" "$OPS_M" 0 0 1 0 "$rpc" 0.1 0 "$THREADS")

      if [ "$role" = compute ]; then
        restart_memcached || { echo "memcached restart failed" >&2; exit 1; }
        sudo env REV_DIR_CPUS="$REV_DIR_CPUS" DEX_PUSH_READS_DEEPEST="${DEX_PUSH_READS_DEEPEST:-0}" DEX_SAFE_PT="${DEX_SAFE_PT:-0}" DEX_LEVEL_STATS="${DEX_LEVEL_STATS:-0}" stdbuf -oL "$BIN" "${args[@]}" 2>&1 | tee "$log" | quiet_filter
        thr=$(awk '/Final throughput =/{v=$NF} END{print (v!=""?v:"NA")}' "$log")
        p99=$(awk '/^[[:space:]]*ALL[[:space:]]/{ if(match($0,/p99=[ ]*[0-9.]+/)){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);v=s} } END{print (v!=""?v:"NA")}' "$log")
        rr=$(awk '/Avg. rdma read \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$log")
        rp=$(awk '/Avg. rdma rpc \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$log")
        h=$(awk '/Tree height =/{v=$NF} END{print (v!=""?v:"NA")}' "$log")
        ie=$(sed -nE 's/.*\[GEOMETRY\].*inner_entries=([0-9]+).*/\1/p' "$log" | tail -1)
        le=$(sed -nE 's/.*\[GEOMETRY\].*leaf_entries=([0-9]+).*/\1/p' "$log" | tail -1)
        pl=$(sed -nE 's/.*\[GEOMETRY\].*placement=([a-z_]+).*/\1/p' "$log" | tail -1)
        # Tree shape (DEX's get_basic lines; sizes are node count x slot size,
        # i.e. what the tree occupies on the memory node and in the cache).
        ip=$(sed -nE 's/.*\[GEOMETRY\].*inner_page=([0-9]+).*/\1/p' "$log" | tail -1)
        lp=$(sed -nE 's/.*\[GEOMETRY\].*leaf_page=([0-9]+).*/\1/p' "$log" | tail -1)
        sl=$(sed -nE 's/.*\[GEOMETRY\].*slot=([0-9]+).*/\1/p' "$log" | tail -1)
        inn=$(awk -F'= ' '/^#inner nodes =/{v=$2} END{print v}' "$log")
        inmb=$(awk -F'= ' '/^inner size\(MB\) =/{v=$2} END{print v}' "$log")
        lfn=$(awk -F'= ' '/^#leaf nodes =/{v=$2} END{print v}' "$log")
        lfmb=$(awk -F'= ' '/^leaf size\(MB\) =/{v=$2} END{print v}' "$log")
        slots=$(awk -F'= ' '/^Cache capacity =/{v=$2} END{print v}' "$log")
        tot=$(awk -v a="$inmb" -v b="$lfmb" 'BEGIN{ if (a!="" && b!="") printf "%.1f", a+b; else print "NA" }')
        # DEX only offloads once its cache is full ("entering dynamic phase",
        # leanstore_cache.h state==1). The pool is reset before warmup, so the
        # cache must refill DURING warmup -- between the first "I am" line
        # (threads start) and "finish warmup" -- or the first part of an
        # offload-on measurement runs without offloading.
        iam=$(grep -n -m1 '^I am' "$log" | cut -d: -f1)
        fw=$(grep -n -m1 'finish warmup' "$log" | cut -d: -f1)
        full=$(awk -v a="$iam" -v b="$fw" '/entering dynamic phase/ && NR>a+0 && NR<b+0 {f=1}
               END{ if (a=="" || b=="") print "NA"; else print (f ? "yes" : "no") }' "$log")
        if [ "$full" = no ] && [ "$mt" -gt 0 ]; then
          echo "    !! WARNING: cache was not full when the measured phase began, so offloading" >&2
          echo "    !!          started late in this cell. Raise WARMUP_M and rerun it." >&2
        fi
        echo "dex,$wl,$(wl_dist "$wl"),$cache,$mt,$off,NA,$thr,$p99,$rr,$rp,${h:-NA},${ie:-NA},${le:-NA},${pl:-NA},$log,${ip:-NA},${lp:-NA},${sl:-NA},${inn:-NA},${inmb:-NA},${lfn:-NA},${lfmb:-NA},${tot},${slots:-NA},${full}" >> "$csv_c"
        echo "    -> ${thr} Mops  p99 ${p99} us  reads/op ${rr}  requests/op ${rp}"
        echo "    -> tree: ${h:-?} levels | inner ${inn:-?} nodes = ${inmb:-?} MB (${ie:-?} entries, ${ip:-?} B page) | leaves ${lfn:-?} = ${lfmb:-?} MB (${le:-?} entries, ${lp:-?} B page) | total ${tot} MB | cache ${cache} MB = ${slots:-?} slots of ${sl:-?} B"
        sleep 3
      else
        wait_for_compute || exit 1
        sudo env REV_DIR_CPUS="$REV_DIR_CPUS" DEX_PUSH_READS_DEEPEST="${DEX_PUSH_READS_DEEPEST:-0}" DEX_SAFE_PT="${DEX_SAFE_PT:-0}" DEX_LEVEL_STATS="${DEX_LEVEL_STATS:-0}" stdbuf -oL "$BIN" "${args[@]}" 2>&1 | tee "$log" | quiet_filter
        pk=$(sed -nE 's/.*AGGREGATE active = ([0-9.]+)%.*/\1/p' "$log" | sort -g | tail -1)
        pt=$(sed -nE 's/.*AGGREGATE active = [0-9.]+% \(of [0-9]+ dir-threads; ([0-9.]+)% per-thread.*/\1/p' "$log" | sort -g | tail -1)
        echo "dex,$wl,$cache,$mt,${pk:-NA},${pt:-NA},$log" >> "$csv_m"
        echo "    -> memory node peak busy ${pk:-NA}% (${pt:-NA}% per thread)"
        # wait for the compute side to move on (it restarts memcached per cell)
        sleep 5
      fi
    done
  done
done
echo "DEX fair sweep ($role) done."
