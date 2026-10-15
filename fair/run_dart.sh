#!/bin/bash
# ===========================================================================
# fair/run_dart.sh <compute|memory> -- DART, unchanged, over WORKLOADS x CACHES.
#
# DART has no memory-node execution and no compute-side node cache, so it is
# run once per workload and cache size with its own binaries and flags. The
# cache value is passed exactly as DART's own sweep passes it (--th_b = total /
# threads); in this DART code that buffer is scratch space, so the cache size is
# expected to have no effect -- the flat line is the reference.
# Memory threads do not apply: DART's memory node never runs index work.
#
# Launch order is DART's own: the monitor (compute server) first, then the
# memory server dials in, then the compute process. Start either script first;
# the memory side retries until the monitor is listening.
#
#   server 6:  RUN_ID=fair1 ./fair/run_dart.sh compute
#   server 8:  RUN_ID=fair1 ./fair/run_dart.sh memory
#
# DART_INIT_DEPTH=<d> (default 15 = as released) runs the DART/bin_d<d> build,
# whose shortcut table is 2^d segments (see fair/params.sh).
# Needs: DART/src/main/compute.cc ips[0] = the memory server address ($MEM_IP),
# hugepages and `ulimit -l unlimited` on both servers (DART/RUNNING.md).
# Output: fair/results/$RUN_ID/dart/dart.csv + logs
# ===========================================================================
set -uo pipefail
role="${1:?usage: run_dart.sh <compute|memory>}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/params.sh"

OUT="$RESULTS_DIR/dart"; mkdir -p "$OUT"
: "${DART_MEM_MB:=8192}" "${DART_CMP_NIC:=0}" "${DART_MEM_NIC:=0}" "${DART_IB_PORT:=1}"
MON_PORT=9898
strip_ansi() { sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g'; }

cells=0; for wl in $WORKLOADS; do for cache in $CACHES; do cells=$((cells+1)); done; done

if [ "$role" = compute ]; then
  for b in monitor compute; do [ -x "$DART_BIN/$b" ] || { echo "missing $DART_BIN/$b; run DART_INIT_DEPTH=$DART_INIT_DEPTH ./fair/build.sh dart" >&2; exit 1; }; done
  grep -q "\"$MEM_IP\"" "$DART_DIR/src/main/compute.cc" || \
    echo "WARNING: DART compute.cc ips[0] is not $MEM_IP; the shortcut-table connection will fail." >&2
  # DART_EST_CACHE=1: also cache hot Express Skip Table entries in the part of the
  # cache budget the EST directory does not need (cache - DART_DIR_MB), as DART's
  # paper does above its 1 MB default (DART/include/prheart/est_cache.hpp). 0 (the
  # default) runs DART as released. DART_WARMUP_M: millions of fresh operations run
  # before the measured phase, as DEX and CHIME warm up (0 = as released).
  : "${DART_EST_CACHE:=0}" "${DART_DIR_MB:=1}" "${DART_WARMUP_M:=0}"
  echo "DART: shortcut table depth $DART_INIT_DEPTH ($DART_BIN)"
  echo "DART: EST entry cache $( [ "$DART_EST_CACHE" = 1 ] && echo "on (cache - ${DART_DIR_MB} MB)" || echo off), warmup ${DART_WARMUP_M}M ops"
  csv="$OUT/dart.csv"
  [ -f "$csv" ] || echo "system,workload,dist,cache_mb,memthreads,offload,leaf,tput_mops,p99_us,mean_us,rtt_per_op,log,est_cache_mb,warmup_m,est_hit_pct,init_depth,table_mib,shortcuts_dropped_pct,update_pct,insert_pct" > "$csv"
  echo "DART fair sweep (compute): $cells cells -> $OUT"
  i=0
  for wl in $WORKLOADS; do
    # UPDATE_PCT / INSERT_PCT (default 0): point workloads become (100-U-I)% lookups
    # + U% updates + I% inserts (DART's microbench inserts fresh keys)
    upd=0; ins=0
    if [ "$(wl_op "$wl")" = point ]; then
      upd=${UPDATE_PCT:-0}; ins=${INSERT_PCT:-0}; read=$((100 - upd - ins)); scan=0
      [ "$read" -ge 0 ] || { echo "UPDATE_PCT + INSERT_PCT exceeds 100" >&2; exit 1; }
    else read=0; scan=100; fi
    mix=""; [ "$upd" != 0 ] && mix="${mix}_u$upd"; [ "$ins" != 0 ] && mix="${mix}_i$ins"
    if [ "$(wl_dist "$wl")" = uniform ]; then uni=1; else uni=0; fi
    theta=$(awk -v t="$ZIPF_THETA" 'BEGIN{printf "%d", t*100 + 0.5}')
    for cache in $CACHES; do
      i=$((i+1)); tag="dart_${wl}${mix}_cache${cache}"
      mlog="$OUT/${tag}.monitor.log"; clog="$OUT/${tag}.compute.log"
      th_b=$(( cache * 1048576 / THREADS ))
      est_mb=0
      if [ "$DART_EST_CACHE" = 1 ] && [ "$cache" -gt "$DART_DIR_MB" ]; then est_mb=$(( cache - DART_DIR_MB )); fi
      echo ">>> [$(date +%H:%M:%S)] ($i/$cells) $tag  (EST entry cache ${est_mb} MB)"
      sudo killall -9 monitor compute 2>/dev/null; sleep 1
      sudo "$DART_BIN/monitor" \
        --monitor_addr="0.0.0.0:$MON_PORT" --memory_num=1 --compute_num=1 \
        --load_thread_num="$THREADS" --run_thread_num="$THREADS" --coro_num=1 \
        --mem_mb="$DART_MEM_MB" --th_b="$th_b" --test_func=1 --bucket=256 \
        --run_max_request=$(( (OPS_M + DART_WARMUP_M) * 1000000 )) --payload_byte="$VALUE_B" \
        --mb_read_pct=$read --mb_scan_pct=$scan \
        --mb_insert_pct="$ins" --mb_update_pct="$upd" --mb_remove_pct=0 \
        --mb_uniform=$uni --mb_theta_x100="$theta" \
        --mb_key_count=$((KEYS_M * 1000000)) --mb_scan_len="$SCAN_LEN" \
        > "$mlog" 2>&1 &
      mon=$!
      sleep 2
      sudo env DART_EST_CACHE_MB="$est_mb" DART_WARMUP_M="$DART_WARMUP_M" "$DART_BIN/compute" \
        --monitor_addr="$CMP_IP:$MON_PORT" --nic_index="$DART_CMP_NIC" --ib_port="$DART_IB_PORT" \
        --numa_node_total_num=2 --numa_node_group=0 > "$clog" 2>&1
      wait "$mon" 2>/dev/null
      thp=$(strip_ansi < "$mlog" | grep -oE 'Total throughput = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
      mean=$(strip_ansi < "$mlog" | grep -oE 'Average latency = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
      p99=$(strip_ansi < "$clog" | awk '/\[ALL OPS\]/{f=1; next} f && match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s; exit}')
      rtt=$(strip_ansi < "$clog" | sed -nE 's/.*rtt \/ op[^0-9]*([0-9.]+).*/\1/p' | tail -1)
      hit=$(strip_ansi < "$clog" | sed -nE 's/.*\[ESTCACHE\] mb=.* hit_pct=([0-9.]+).*/\1/p' | tail -1)
      tmib=$(strip_ansi < "$clog" | sed -nE 's/.*\[SHORTCUT\] .*table_mib=([0-9.]+).*/\1/p' | tail -1)
      drop=$(strip_ansi < "$clog" | sed -nE 's/.*\[SHORTCUT\] .*dropped_pct=([0-9.]+).*/\1/p' | tail -1)
      echo "dart,$wl,$(wl_dist "$wl"),$cache,NA,off,NA,${thp:-NA},${p99:-NA},${mean:-NA},${rtt:-NA},$mlog,$est_mb,$DART_WARMUP_M,${hit:-NA},$DART_INIT_DEPTH,${tmib:-NA},${drop:-NA},$upd,$ins" >> "$csv"
      echo "    -> ${thp:-NA} Mops  p99 ${p99:-NA} us  EST entry hits ${hit:-NA}%  shortcut table ${tmib:-NA} MiB (depth $DART_INIT_DEPTH), dropped ${drop:-NA}%"
      sudo killall -9 monitor compute 2>/dev/null
      sleep 3
    done
  done
  echo "DART fair sweep (compute) done."
else
  [ -x "$DART_BIN/memory" ] || { echo "missing $DART_BIN/memory; run DART_INIT_DEPTH=$DART_INIT_DEPTH ./fair/build.sh dart" >&2; exit 1; }
  echo "DART fair sweep (memory): $cells cells, dialing $CMP_IP:$MON_PORT"
  killall -9 memory 2>/dev/null; sleep 1
  for (( i = 1; i <= cells; ++i )); do
    attempt=0
    while :; do
      attempt=$((attempt + 1))
      mlog="$OUT/memory_cell${i}_try${attempt}.log"
      "$DART_BIN/memory" --monitor_addr="$CMP_IP:$MON_PORT" \
        --nic_index="$DART_MEM_NIC" --ib_port="$DART_IB_PORT" > "$mlog" 2>&1
      if grep -q "ready\." "$mlog"; then echo "    -> cell $i done"; rm -f "$OUT"/memory_cell${i}_try[0-9]*.log.fail; break; fi
      mv "$mlog" "$mlog.fail"
      if [ "$attempt" -ge 900 ]; then echo "memory: monitor unreachable for cell $i" >&2; exit 1; fi
      sleep 1
    done
    killall -9 memory 2>/dev/null; sleep 1
  done
  echo "DART fair sweep (memory) done."
fi
