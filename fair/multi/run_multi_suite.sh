#!/bin/bash
# ===========================================================================
# fair/multi/run_multi_suite.sh <dex|chime> <memory|compute> -- the multi-node test
# suite, one command per server: lookups, the 50/25/25 write mix, scans, and a
# 40/25/25/10 lookup/update/insert/scan mix, with uniform and Zipfian keys, on
# Lesson 3's 12-level trees (60M keys, 64-byte values, 36 clients in all).
# CHIME runs every block twice: keys shared by all compute processes (stock) and
# keys split per compute process (CHIME_PARTITION_KEYS=1, as DEX's benchmark).
# Writes with push run as in Lesson 3 (DEX's own write push; CHIME_PUSH_LOCATE=1).
#
# Order: DEX -- server 8 (memory) first, then server 6 (compute).
#        CHIME -- server 6 (compute) first, then server 8 (memory).
#
# Variables (the SAME on both servers): NCN (default 4) NMN (1) RUN_ID (mn<NCN><NMN>)
#   CACHES ("27 108") MEMTHREADS ("0 4") OPS_M (10) WARMUP_M (10)
#   SMOKE=1: a quick check -- 27 MB, 4 workers, uniform keys, 2M warmup + 3M ops.
# Output: fair/results/$RUN_ID/{dex_multi,chime_multi}/ and ~/<RUN_ID>_<system>_<role>.out
# ===========================================================================
sys="${1:?usage: run_multi_suite.sh <dex|chime> <memory|compute>}"
role="${2:?usage: run_multi_suite.sh <dex|chime> <memory|compute>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NCN="${NCN:-4}" NMN="${NMN:-1}"
export RUN_ID="${RUN_ID:-mn${NCN}${NMN}}"
export THREADS=36 KEYS_M=60 VALUE_B=64
export CACHES="${CACHES:-27 108}" MEMTHREADS="${MEMTHREADS:-0 4}"
export OPS_M="${OPS_M:-10}" WARMUP_M="${WARMUP_M:-10}"
PT="point-uniform point-zipf"; RG="range-uniform range-zipf"
if [ "${SMOKE:-0}" = 1 ]; then
  export CACHES=27 MEMTHREADS=4 OPS_M=3 WARMUP_M=2; PT="point-uniform"; RG="range-uniform"
fi
case "$sys" in
  dex)   export TREE_SETUP=model DEX_INNER_PAGE=240; RUN="$HERE/run_dex_multi.sh"; PARTS="0" ;;
  chime) export TREE_SETUP=deep CHIME_BUILD_LEAF_KEYS=4 CHIME_BUILD_INNER_FANOUT=5
         export CHIME_PUSH_LOCATE=1; RUN="$HERE/run_chime_multi.sh"; PARTS="0 1" ;;
  *) echo "system must be dex or chime" >&2; exit 1 ;;
esac
log=~/"${RUN_ID}_${sys}_${role}.out"
echo "== suite $sys ($role): $NCN compute + $NMN memory processes, RUN_ID=$RUN_ID, caches [$CACHES], workers [$MEMTHREADS] -> $log"

# block name | UPDATE_PCT | INSERT_PCT | SCAN_PCT | workloads
BLOCKS=("lookups|0|0|0|$PT" "writes|25|25|0|$PT" "scans|0|0|0|$RG" "mix|25|25|10|$PT")
for p in $PARTS; do
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r name u i s wl <<< "$b"
    block="${name}${p/1/_part}"; [ "$sys" = chime ] && [ "$p" = 0 ] && block="${name}_shared"
    echo "== [$(date +%H:%M:%S)] block $block"
    env MULTI_BLOCK="$block" CHIME_PARTITION_KEYS="$p" UPDATE_PCT="$u" INSERT_PCT="$i" SCAN_PCT="$s" \
      WORKLOADS="$wl" bash "$RUN" "$role" || { echo "!! block $block failed; stopping" >&2; exit 1; }
  done
done 2>&1 | tee -a "$log"
echo "== suite $sys ($role) done -> fair/results/$RUN_ID"
