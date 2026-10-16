#!/bin/bash
# ===========================================================================
# fair/multi/run_multi_suite.sh <dex|dexr|chime|all> <memory|compute> -- the multi-node
# test suite, one command per server: lookups, the 50/25/25 write mix, scans, and a
# 40/25/25/10 lookup/update/insert/scan mix ("mix"), with uniform and Zipfian keys,
# on Lesson 3's 12-level trees (60M keys, 64-byte values, 36 clients in all), with
# NCN compute processes on server 6 and NMN memory processes on server 8 (4 + 2).
#   dex    stock DEX (its own push rule, within megaLevel)
#   dexr   DEX-R, our miss-gated push (DEX_PUSH_READS_DEEPEST=1, as in Lesson 3): reads
#          pushed from the deepest cached node; a pushed lookup that reaches the other
#          memory node is retried with DEX's own rule. Writes keep DEX's rule.
#   chime  CHIME with push: lookups pushed, writes with CHIME_PUSH_LOCATE=1 (the walk
#          pushed, the leaf written by the compute process, as in Lesson 3); scans are
#          pulled with NMN > 1. Every block twice: keys shared by all compute processes
#          (stock) and keys split per compute process (CHIME_PARTITION_KEYS=1, as DEX).
#   all    dex, then dexr, then chime, in one command per server.
#
# Order: server 8 (memory) first, then server 6 (compute), within a few minutes.
#
# Variables (the SAME on both servers): NCN (default 4) NMN (2) RUN_ID (mn<NCN><NMN>)
#   ONLY ("lookups writes scans mix": the blocks to run, e.g. ONLY=mix)
#   CACHES ("27 108") MEMTHREADS ("0 4"; dexr: "4", since 0 workers = pull = stock DEX)
#   CHIME_PARTS ("0 1": shared keys, split keys) OPS_M (10) WARMUP_M (10)
#   SMOKE=1: a quick check -- 27 MB, 4 workers, uniform keys, 2M warmup + 3M ops.
# Output: fair/results/$RUN_ID/{dex_multi,chime_multi}/ and ~/<RUN_ID>_<system>_<role>.out
# ===========================================================================
sys="${1:?usage: run_multi_suite.sh <dex|dexr|chime|all> <memory|compute>}"
role="${2:?usage: run_multi_suite.sh <dex|dexr|chime|all> <memory|compute>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$role" in memory|compute) ;; *) echo "role must be memory or compute" >&2; exit 1 ;; esac

if [ "$sys" = all ]; then
  for s in dex dexr chime; do
    bash "$HERE/run_multi_suite.sh" "$s" "$role" || { echo "!! suite $s failed; stopping" >&2; exit 1; }
  done
  exit 0
fi

export NCN="${NCN:-4}" NMN="${NMN:-2}"
export RUN_ID="${RUN_ID:-mn${NCN}${NMN}}"
export THREADS=36 KEYS_M=60 VALUE_B=64
export CACHES="${CACHES:-27 108}" MEMTHREADS="${MEMTHREADS:-0 4}"
export OPS_M="${OPS_M:-10}" WARMUP_M="${WARMUP_M:-10}"
ONLY="${ONLY:-lookups writes scans mix}"
PT="point-uniform point-zipf"; RG="range-uniform range-zipf"
case "$sys" in
  dex)   export TREE_SETUP=model DEX_INNER_PAGE=240 DEX_PUSH_READS_DEEPEST=0
         RUN="$HERE/run_dex_multi.sh"; PARTS="0" ;;
  dexr)  export TREE_SETUP=model DEX_INNER_PAGE=240 DEX_PUSH_READS_DEEPEST=1
         [ "$MEMTHREADS" = "0 4" ] && export MEMTHREADS=4
         RUN="$HERE/run_dex_multi.sh"; PARTS="0" ;;
  chime) export TREE_SETUP=deep CHIME_BUILD_LEAF_KEYS=4 CHIME_BUILD_INNER_FANOUT=5
         export CHIME_PUSH_LOCATE=1; RUN="$HERE/run_chime_multi.sh"; PARTS="${CHIME_PARTS:-0 1}" ;;
  *) echo "system must be dex, dexr, chime or all" >&2; exit 1 ;;
esac
if [ "${SMOKE:-0}" = 1 ]; then
  export CACHES=27 MEMTHREADS=4 OPS_M=3 WARMUP_M=2; PT="point-uniform"; RG="range-uniform"
fi
log=~/"${RUN_ID}_${sys}_${role}.out"
echo "== suite $sys ($role): $NCN compute + $NMN memory processes, RUN_ID=$RUN_ID, blocks [$ONLY], caches [$CACHES], workers [$MEMTHREADS] -> $log"

# block name | UPDATE_PCT | INSERT_PCT | SCAN_PCT | workloads
BLOCKS=("lookups|0|0|0|$PT" "writes|25|25|0|$PT" "scans|0|0|0|$RG" "mix|25|25|10|$PT")
for p in $PARTS; do
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r name u i s wl <<< "$b"
    [[ " $ONLY " == *" $name "* ]] || continue
    block="$name"
    [ "$sys" = chime ] && { [ "$p" = 1 ] && block="${name}_part" || block="${name}_shared"; }
    echo "== [$(date +%H:%M:%S)] $sys block $block"
    # the cell key carries the system and block, so stock DEX and DEX-R (the same
    # memcached) never take each other's cells
    env MULTI_BLOCK="${sys}_${block}" CHIME_PARTITION_KEYS="$p" UPDATE_PCT="$u" INSERT_PCT="$i" SCAN_PCT="$s" \
      WORKLOADS="$wl" bash "$RUN" "$role" || { echo "!! block $block failed; stopping" >&2; exit 1; }
  done
done 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}
echo "== suite $sys ($role) done (exit $rc) -> fair/results/$RUN_ID"
exit "$rc"
