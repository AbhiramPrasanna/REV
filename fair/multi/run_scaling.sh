#!/bin/bash
# ===========================================================================
# fair/multi/run_scaling.sh <cn|mn|build> <memory|compute> -- scaling tests for the
# paper's implementations only, on Lesson 3's 12-level trees (60M keys, 64 B values):
#
#   cn   compute scaling: 1 memory process, NCN = 1 2 4 compute processes,
#        CPN clients each (default 9: 9, 18, 36 clients). Every compute process
#        has its own cache of CACHES MB, as every compute server has its own DRAM.
#        Each pushed request, from any compute process, uses the one memory
#        process's workers -- the contention a single compute server never shows.
#   mn   memory scaling: MN_NCN (default 2) compute processes, 36 clients in all
#        (18 each), NMN = 1 2 4 memory processes, the tree spread over them,
#        PUSH_MT workers on EACH memory process. The largest point is 2 + 4.
#        Pushed walks and scans that reach another memory process are carried on
#        there (DEX_PUSH_CHAIN / CHIME_PUSH_CHAIN = 1); scans resume across them.
#   build  build DEX and CHIME (one CHIME binary per memory-process count) on this
#        server. Run it on BOTH servers from the same commit.
#
# Systems (SYSTEMS, default all five) -- the configurations the paper evaluates:
#   dex        DEX, pull only (0 workers)
#   dexpush    DEX+Push: lookups and scans pushed from the first miss (DEX-R,
#              DEX_PUSH_READS_DEEPEST=1); writes pushed by DEX's own rule (Sec. 8.3)
#   chime      CHIME, pull only (0 workers)
#   chimepush  CHIME+Push: lookups and scans pushed from the deepest cached node;
#              a write pushes its walk, the compute process writes the leaf (Sec. 8.3)
#   chimeleaf  CHIME+Push+LeafCache: half of each cache holds hot leaves (Sec. 7.2,
#              Fig. 14); lookups only. With more than one compute process a hit is
#              validated against the leaf's version (CHIME_LEAF_OWNER=0), at every
#              point of an axis; owner mode (no network check, the paper's runs)
#              only on an mn axis run with MN_NCN=1.
# Blocks (ONLY, default "lookups scans writes"):
#   lookups  uniform and Zipfian lookups                       (Figs. 7, 10, 14)
#   scans    100-key scans, uniform                            (Figs. 7, 12c)
#   writes   50% lookups / 25% updates / 25% inserts, uniform and Zipfian (Fig. 15)
#   lkscan   50% lookups / 50% 100-key scans, uniform          (Fig. 12d)
#
# Order: server 8 (memory) first, then server 6 (compute), with the SAME variables:
#   both:      RUN_ID=b bash fair/multi/run_scaling.sh build
#   server 8:  bash fair/multi/run_scaling.sh cn memory
#   server 6:  bash fair/multi/run_scaling.sh cn compute
#   then the same with mn. DRY_RUN=1 prints the plan and runs nothing.
#   SMOKE=1: the largest point (4 + 1 or 2 + 4; SMOKE_POINTS to change), every
#   system and block, one short uniform cell each (27 MB, 4 workers, 2M warmup +
#   3M ops) -- a check that each configuration starts, runs and answers correctly
#   before the long run. Results under <SCALE_ID>_smoke_c*m*.
#
# Variables: SCALE_ID (default sc_cn / sc_mn) CN_POINTS ("1 2 4") MN_POINTS ("1 2 4")
#   CPN (9, cn: clients per compute process) TOTAL_CLIENTS (cn: fixed total instead;
#   mn: total clients, default 36) MN_NCN (mn: compute processes, default 2)
#   CACHES ("27") PUSH_MT (workers per memory process; cn "4 16", mn "4")
#   PUSH_MT_TOTAL (mn: fixed total workers split over the memory processes instead)
#   SYSTEMS ONLY OPS_M (10) WARMUP_M (10) MN_DSM_GB (default 64 / NMN, at least 24)
#   PUSH_CHAIN (1) DEX_MN_HOST_LOCKS (mn: 1, DEX's lock tables in host memory at every point)
# Output: fair/results/<SCALE_ID>_c<NCN>m<NMN>/{dex_multi,chime_multi}/ on each
# server (the compute side writes *_multi.csv, the memory side *_mnload.csv), and
# ~/<SCALE_ID>_<role>.out. Collect: python3 fair/multi/collect_scaling.py <SCALE_ID>
# ===========================================================================
set -uo pipefail
axis="${1:?usage: run_scaling.sh <cn|mn|build> <memory|compute>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lesson 3's trees, as in run_multi_suite.sh
DEX_ENV=(TREE_SETUP=model DEX_INNER_PAGE=240)
CHIME_ENV=(TREE_SETUP=deep CHIME_BUILD_LEAF_KEYS=4 CHIME_BUILD_INNER_FANOUT=5 CHIME_HOTSPOT=0)
export KEYS_M=60 VALUE_B=64

if [ "$axis" = build ]; then
  export RUN_ID="${RUN_ID:-b}"
  env "${DEX_ENV[@]}" bash "$HERE/../build.sh" dex || exit 1
  for n in $(printf '%s\n' 1 ${MN_POINTS:-1 2 4} | sort -un); do   # cn runs on 1
    env "${CHIME_ENV[@]}" NMN="$n" NCN=1 THREADS=1 bash "$HERE/run_chime_multi.sh" build || exit 1
  done
  echo "== built DEX ($(env "${DEX_ENV[@]}" bash -c "source '$HERE/../params.sh'; echo \$DEX_BUILD")) and CHIME for ${MN_POINTS:-1 2 4} memory processes"
  exit 0
fi

role="${2:?usage: run_scaling.sh <cn|mn> <memory|compute>}"
case "$axis" in cn|mn) ;; *) echo "axis must be cn, mn or build" >&2; exit 1 ;; esac
case "$role" in memory|compute) ;; *) echo "role must be memory or compute" >&2; exit 1 ;; esac

SCALE_ID="${SCALE_ID:-sc_$axis}"
SYSTEMS="${SYSTEMS:-dex dexpush chime chimepush chimeleaf}"
ONLY="${ONLY:-lookups scans writes}"
CACHES="${CACHES:-27}"
OPS_M="${OPS_M:-10}" WARMUP_M="${WARMUP_M:-10}"
export DEX_PUSH_CHAIN="${PUSH_CHAIN:-1}" CHIME_PUSH_CHAIN="${PUSH_CHAIN:-1}"
# DEX lock tables: 4 memory processes cannot all fit theirs in the NIC's on-chip
# memory, so the mn axis keeps them in host memory at EVERY point (one setting along
# the curve); the cn axis has one memory process, on-chip as in the paper's runs.
[ "$axis" = mn ] && export DEX_MN_HOST_LOCKS="${DEX_MN_HOST_LOCKS:-1}"
if [ "$axis" = cn ]; then POINTS="${CN_POINTS:-1 2 4}"; PUSH_MT="${PUSH_MT:-4 16}"
else POINTS="${MN_POINTS:-1 2 4}"; PUSH_MT="${PUSH_MT:-4}"; fi
if [ "${SMOKE:-0}" = 1 ]; then
  # the largest point only (4 + 1 or 2 + 4)
  POINTS="${SMOKE_POINTS:-${POINTS##* }}"
  CACHES=27; PUSH_MT=4; unset PUSH_MT_TOTAL; OPS_M=3; WARMUP_M=2; SCALE_ID="${SCALE_ID}_smoke"
fi
USER_DSM_GB="${MN_DSM_GB:-}"   # set by hand: every point; else 64 / NMN, at least 24
export OPS_M WARMUP_M

# block | UPDATE_PCT | INSERT_PCT | SCAN_PCT | workloads
blocks_for() {   # system
  local pt="point-uniform point-zipf" rg="range-uniform" lk="point-uniform"
  [ "${SMOKE:-0}" = 1 ] && pt="point-uniform"
  local all=("lookups|0|0|0|$pt" "scans|0|0|0|$rg" "writes|25|25|0|$pt" "lkscan|0|0|50|$lk")
  [ "$1" = chimeleaf ] && all=("lookups|0|0|0|$pt")
  local b; for b in "${all[@]}"; do [[ " $ONLY " == *" ${b%%|*} "* ]] && echo "$b"; done
}

point_layout() {   # n -> sets NCN NMN THREADS MN_DSM_GB and the workers per memory process
  if [ "$axis" = cn ]; then
    NCN=$1; NMN=1
    if [ -n "${TOTAL_CLIENTS:-}" ]; then THREADS=$TOTAL_CLIENTS; else THREADS=$(( ${CPN:-9} * NCN )); fi
  else
    NCN=${MN_NCN:-2}; NMN=$1; THREADS=${TOTAL_CLIENTS:-36}
  fi
  local g=$(( 64 / NMN )); [ "$g" -lt 24 ] && g=24
  PT_DSM="${USER_DSM_GB:-$g}"
  if [ -n "${PUSH_MT_TOTAL:-}" ]; then
    [ $((PUSH_MT_TOTAL % NMN)) -eq 0 ] || { echo "PUSH_MT_TOTAL=$PUSH_MT_TOTAL does not split over $NMN memory processes" >&2; return 1; }
    PT_MT=$((PUSH_MT_TOTAL / NMN))
  else PT_MT="$PUSH_MT"; fi
}

count_cells() {   # system mts -> cells of one point
  local n=0 b wl c m
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    for wl in ${b##*|}; do for c in $CACHES; do for m in $2; do n=$((n + 1)); done; done; done
  done < <(blocks_for "$1")
  echo "$n"
}

log=~/"${SCALE_ID}_${role}.out"
total=0
for p in $POINTS; do
  point_layout "$p" || exit 1
  for s in $SYSTEMS; do
    case "$s" in dex|chime) m=0 ;; *) m="$PT_MT" ;; esac
    total=$((total + $(count_cells "$s" "$m")))
  done
done
{
echo "== scaling '$axis' ($role) SCALE_ID=$SCALE_ID: points [$POINTS], systems [$SYSTEMS], blocks [$ONLY], caches [$CACHES] MB, ${OPS_M}M ops after ${WARMUP_M}M warmup"
echo "   $total cells in all (about $((total * 4 / 60)) h $((total * 4 % 60)) min at ~4 min a cell) -> fair/results/${SCALE_ID}_c*m*/  log $log"
} | tee -a "$log"

for p in $POINTS; do
  point_layout "$p" || exit 1
  export NCN NMN THREADS MN_DSM_GB="$PT_DSM"
  export RUN_ID="${SCALE_ID}_c${NCN}m${NMN}"
  echo "== [$(date +%H:%M:%S)] point $NCN compute + $NMN memory processes: $THREADS clients ($((THREADS / NCN)) each), workers per memory process [$PT_MT], memory pool $PT_DSM GB each -> fair/results/$RUN_ID" | tee -a "$log"
  for s in $SYSTEMS; do
    senv=(); run=""
    case "$s" in
      dex)       senv=("${DEX_ENV[@]}" DEX_PUSH_READS_DEEPEST=0 DEX_PUSH_WRITES_LOCATE=0 MEMTHREADS=0)
                 run="$HERE/run_dex_multi.sh" ;;
      dexpush)   senv=("${DEX_ENV[@]}" DEX_PUSH_READS_DEEPEST=1 DEX_PUSH_WRITES_LOCATE=0 MEMTHREADS="$PT_MT")
                 run="$HERE/run_dex_multi.sh" ;;
      chime)     senv=("${CHIME_ENV[@]}" CHIME_PARTITION_KEYS=0 CHIME_PUSH_LOCATE=1 CHIME_CACHE_LEAF=0 MEMTHREADS=0)
                 run="$HERE/run_chime_multi.sh" ;;
      chimepush) senv=("${CHIME_ENV[@]}" CHIME_PARTITION_KEYS=0 CHIME_PUSH_LOCATE=1 CHIME_CACHE_LEAF=0 MEMTHREADS="$PT_MT")
                 run="$HERE/run_chime_multi.sh" ;;
      chimeleaf) owner=0; [ "$axis" = mn ] && [ "$NCN" = 1 ] && owner=1
                 senv=("${CHIME_ENV[@]}" CHIME_PARTITION_KEYS=0 CHIME_PUSH_LOCATE=1 MEMTHREADS="$PT_MT"
                       CHIME_CACHE_LEAF=1 CHIME_LEAF_CACHE_PCT=50 CHIME_LEAF_BY_KEY=1
                       CHIME_LEAF_OWNER=$owner CHIME_LEAF_ADMIT_PUSH=0.1)
                 run="$HERE/run_chime_multi.sh" ;;
      *) echo "unknown system '$s' (dex dexpush chime chimepush chimeleaf)" >&2; exit 1 ;;
    esac
    while IFS='|' read -r name u i sc wl; do
      [ -n "$name" ] || continue
      bl="${s}_${name}"
      echo "== [$(date +%H:%M:%S)] $RUN_ID $bl" | tee -a "$log"
      cmd=(env "${senv[@]}" MULTI_BLOCK="$bl" CACHES="$CACHES" UPDATE_PCT="$u" INSERT_PCT="$i"
           SCAN_PCT="$sc" WORKLOADS="$wl" bash "$run" "$role")
      if [ "${DRY_RUN:-0}" = 1 ]; then
        printf '   %q' "${cmd[@]}"; echo
        continue
      fi
      "${cmd[@]}" 2>&1 | tee -a "$log"
      [ "${PIPESTATUS[0]}" = 0 ] || { echo "!! $RUN_ID $bl failed; stopping (rerun with SYSTEMS / ONLY / CN_POINTS / MN_POINTS to resume)" | tee -a "$log" >&2; exit 1; }
    done < <(blocks_for "$s")
  done
done
echo "== scaling '$axis' ($role) done -> fair/results/${SCALE_ID}_c*m*/" | tee -a "$log"
