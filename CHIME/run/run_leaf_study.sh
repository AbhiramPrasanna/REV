#!/bin/bash
# ===========================================================================
# run_leaf_study.sh  --  the whole leaf-cache study, one invocation per node
#
#   ./run_leaf_study.sh memory      # on 10.30.1.8  -- START THIS FIRST
#   ./run_leaf_study.sh compute     # on 10.30.1.6  -- then this
#
# Runs all 16 cells back to back, in A/B order so each comparison sits next to
# its control:
#
#     {100% lookup, 100% scan} x {uniform, zipf-0.99} x {offload off, on}
#                              x {leaf cache off, on}
#
# at 50M keys / 30M measured ops / scan length 100 -- the DART baseline's own
# contract (KEY_COUNT and OP_COUNT are recorded in DART/cache_sweep_baseline_*.csv).
#
# RESUMABLE. Before each cell it checks whether that exact row is already in the
# summary CSV and skips it if so. A cell that dies, a dropped SSH session, or a
# machine you had to reboot costs you that one cell, not the study -- just run the
# same command again. Set FORCE=1 to re-run cells that already have a row.
#
# STOPS ON FAILURE by default, because a half-finished cell leaves the two nodes
# talking past each other. Set KEEP_GOING=1 to push through and collect the rest.
#
# Knobs (env):
#   SEQ_TS      leafstudy    sweep name; both nodes MUST use the same one
#   CACHE_MB    512          TOTAL compute-side cache, MB. A list ("512 256 128
#                            64") runs the 16 cells at each point -- 64 cells.
#   THREADS     34           app threads per node
#   LEAF_PCT    50           leaf share of the total (rest -> inner nodes)
#   SETTLE      5            seconds between cells
#   FORCE       -            re-run cells that already have a row
#   KEEP_GOING  -            continue past a failed cell
#   BULK/POINT_OP/RANGE_OP   50 / 30 / 30 (M) -- override to shorten scan cells
#
# Results accumulate into ONE sweep directory and ONE summary CSV per node:
#   build/results/leaf_cache/sweep_$SEQ_TS/summary_{memory,compute}.csv
# ===========================================================================
set -uo pipefail    # NOT -e: cell failures are handled explicitly below

ROLE="${1:-}"
case "$ROLE" in
  memory|compute) ;;
  *) echo "usage: $0 <memory|compute>" >&2; exit 1 ;;
esac

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIME_DIR="$(cd "$RUN_DIR/.." && pwd)"
CELL_RUNNER="$RUN_DIR/run_leaf_cache.sh"
[[ -x "$CELL_RUNNER" ]] || { echo "ERROR: $CELL_RUNNER not found/executable" >&2; exit 1; }

: "${SEQ_TS:=leafstudy}"
: "${CACHE_MB:=512}"
: "${THREADS:=34}"
: "${LEAF_PCT:=50}"
: "${SETTLE:=5}"
: "${BULK:=50}"
: "${WARMUP:=10}"
: "${POINT_OP:=30}"
: "${RANGE_OP:=30}"
: "${SCAN_RANGE:=100}"
: "${DIR_THREADS:=4}"
LOG_DIR="${LOG_DIR:-$CHIME_DIR/build/results/leaf_cache}"
export SEQ_TS THREADS BULK WARMUP POINT_OP RANGE_OP SCAN_RANGE DIR_THREADS LOG_DIR
export LEAF_CACHE_PCT="$LEAF_PCT"

BASE="$LOG_DIR/sweep_$SEQ_TS"
CSV="$BASE/summary_${ROLE}.csv"

# The 16 cells, ordered so the leaf-cache A/B pairs are adjacent: for each
# workload, for each offload setting, leaf off then leaf on.
CELLS="
point-uniform off 0
point-uniform off 1
point-uniform on  0
point-uniform on  1
point-zipf    off 0
point-zipf    off 1
point-zipf    on  0
point-zipf    on  1
range-uniform off 0
range-uniform off 1
range-uniform on  0
range-uniform on  1
range-zipf    off 0
range-zipf    off 1
range-zipf    on  0
range-zipf    on  1
"

# Has this exact cell already produced a row? Columns are
# cache_mb,dir_threads,workload,offload,role,...,cache_leaf(10),...
already_done() {   # cache workload offload leaf
  [[ -f "$CSV" ]] || return 1
  awk -F, -v c="$1" -v w="$2" -v o="$3" -v l="$4" -v r="$ROLE" \
    'NR>1 && $1==c && $3==w && $4==o && $5==r && $10==l { hit=1 }
     END { exit !hit }' "$CSV"
}

CACHES=($CACHE_MB)
NCELL=$(echo "$CELLS" | grep -c '[^[:space:]]')
TOTAL=$(( NCELL * ${#CACHES[@]} ))

echo "=============================================================="
echo " CHIME leaf-cache study -- role=$ROLE"
echo "   sweep      : $BASE"
echo "   cells      : $TOTAL  ($NCELL per cache point)"
echo "   cache (MB) : ${CACHES[*]}   split ${LEAF_PCT}% leaf / $((100-LEAF_PCT))% inner when leaf=1"
echo "   workload   : ${BULK}M keys, point ${POINT_OP}M ops, scan ${RANGE_OP}M ops x ${SCAN_RANGE} keys"
echo "   threads    : $THREADS   dir threads: $DIR_THREADS"
if [[ "$ROLE" == "memory" ]]; then
  echo "   >> this is the MEMORY node: start it BEFORE the compute node"
else
  echo "   >> this is the COMPUTE node: the memory node must already be running"
fi
echo "=============================================================="

# Restart memcached and zero the counters -- memory node only; the compute node
# has no business restarting the coordination service the other node owns.
# Non-fatal: the next cell restarts it again anyway and aborts loudly if it
# cannot, so a hiccup here should not end the study.
restart_memc_if_memory() {
  [[ "$ROLE" == "memory" ]] || return 0
  if bash "$CHIME_DIR/script/restartMemc.sh" >/dev/null 2>&1; then
    echo ">>> memcached restarted + counters zeroed ($1)"
  else
    echo ">>> warning: memcached restart failed ($1) -- the next cell will retry" >&2
  fi
}

n=0; ran=0; skipped=0; failed=0
FAILED_LIST=""
STARTED=$(date +%s)

for cache in "${CACHES[@]}"; do
  while read -r wl off leaf; do
    [[ -z "$wl" ]] && continue
    n=$(( n + 1 ))
    tag="cache=${cache}MB $wl offload=$off leaf=$leaf"

    if [[ -z "${FORCE:-}" ]] && already_done "$cache" "$wl" "$off" "$leaf"; then
      echo ">>> [$n/$TOTAL] SKIP (already have a row): $tag"
      skipped=$(( skipped + 1 ))
      continue
    fi

    echo
    echo "##############################################################"
    echo "### [$n/$TOTAL] $tag"
    echo "###   elapsed so far: $(( ($(date +%s) - STARTED) / 60 )) min"
    echo "##############################################################"

    CACHE_MB="$cache" "$CELL_RUNNER" "$ROLE" "$wl" "$off" "$leaf"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      failed=$(( failed + 1 ))
      FAILED_LIST="${FAILED_LIST}    [$n/$TOTAL] $tag (exit $rc)\n"
      echo "!!! CELL FAILED (exit $rc): $tag" >&2
      if [[ -z "${KEEP_GOING:-}" ]]; then
        echo "!!! Stopping. A half-finished cell leaves the two nodes out of step;" >&2
        echo "!!! fix the cause, then re-run this same command -- finished cells are" >&2
        echo "!!! skipped automatically. KEEP_GOING=1 to push on instead." >&2
        break 2
      fi
    else
      ran=$(( ran + 1 ))
    fi

    sleep "$SETTLE"
    # Leave memcached clean AFTER every cell too, not only before the next one.
    # A cell that died leaves serverNum and barrier keys behind, and the next
    # cell's own restart is the only thing that clears them -- which is no help
    # if you stop here, or inspect state in between.
    #
    # Deliberately after the settle sleep, never before: both nodes must clear
    # dsm->barrier("fin") before either exits, and wiping memcached while the
    # peer is still polling that barrier would strand it forever. SETTLE seconds
    # is the peer's margin to finish exiting.
    restart_memc_if_memory "after cell $n"
  done <<< "$CELLS"
done

# Leave the machine in a clean state whether we finished or bailed out.
restart_memc_if_memory "end of study"

echo
echo "=============================================================="
echo " DONE ($ROLE)  ran=$ran skipped=$skipped failed=$failed  of $TOTAL"
echo "   wall time: $(( ($(date +%s) - STARTED) / 60 )) min"
[[ -n "$FAILED_LIST" ]] && { echo "   failed cells:"; printf "$FAILED_LIST"; }
echo "   summary  : $CSV"
echo "=============================================================="
if [[ -f "$CSV" ]]; then
  column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
fi
echo
echo "When BOTH nodes are done, on the compute node:"
echo "  scp <memory-host>:$BASE/summary_memory.csv $BASE/"
echo "  python3 $CHIME_DIR/results/plot_leaf_cache.py $BASE"
[[ $failed -gt 0 ]] && exit 1
exit 0
