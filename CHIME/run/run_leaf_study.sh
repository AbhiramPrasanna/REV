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
#   PROFILE     coarse       which cache points to run (see below)
#   CACHE_MB    per PROFILE  TOTAL compute-side cache, MB. A list runs the 16
#                            cells at each point.
#   DIR_SET     4            memory-node (dir) thread counts to sweep, e.g.
#                            "2 4 6 8 16". Values above 4 need NR_DIRECTORY
#                            raised and BOTH nodes rebuilt.
#   THREADS     34           app threads per node
#   LEAF_PCT    50           leaf share of the total (rest -> inner nodes)
#   SETTLE      5            seconds between cells
#   FORCE       -            re-run cells that already have a row
#   KEEP_GOING  -            continue past a failed cell
#   BULK/POINT_OP/RANGE_OP   50 / 30 / 30 (M) -- override to shorten scan cells
#
# The two axes do NOT need to be crossed in full: PROFILE=fine with DIR_SET=4 is
# 208 cells, and crossing it with five dir values would be 624. Run them as two
# sweeps instead, which answers both questions in about half the time:
#   cache axis:  PROFILE=fine  DIR_SET=4                    ./run_leaf_study.sh <role>
#   thread axis: PROFILE=coarse CACHE_MB="256 64" DIR_SET="2 4 6 8 16"
# The second one only needs one cache point where the inner nodes fit and one
# where they do not, because that is the whole claim being tested.
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

# CHIME's cache knob is NOT one number, which is why the points below are not
# just octaves. CHIME_CACHE_MB is a TOTAL that three things draw from:
#   - the hotspot buffer, a fixed 30 MB carve-off (define::kHotspotBufSize),
#   - the inner-node cache, which is what decides whether a descent stays local,
#   - the leaf cache, when CACHE_LEAF=1 (LEAF_PCT of the total).
# So the inner nodes get (total - 30) MB with leaf caching off, and about
# (total/2 - 30) MB with it on. The inner nodes need roughly 90 to 100 MB at
# these settings, which puts the fit boundary near 128 MB nominal with leaf
# caching off, and near 256 MB with it on. Octave spacing steps straight over
# that boundary, so the drop looks like one jump between 64 and 128 with nothing
# to say where it happens or how sharp it is.
#
#   PROFILE=coarse  the old octave axis, extended at both ends. Fast.
#   PROFILE=fine    adds points either side of the fit boundary so the drop is
#                   resolved rather than inferred. This is the one to run for
#                   the cache figure.
#   PROFILE=full    everything, for an overnight run.
# Any explicit CACHE_MB overrides the profile.
: "${PROFILE:=coarse}"
if [[ -z "${CACHE_MB:-}" ]]; then
  case "$PROFILE" in
    coarse) CACHE_MB="1024 512 256 128 64 32" ;;
    fine)   CACHE_MB="1024 512 288 256 224 192 160 144 128 112 96 64 32" ;;
    full)   CACHE_MB="1024 768 512 384 288 256 224 192 160 144 128 112 96 80 64 48 32" ;;
    *) echo "PROFILE must be coarse|fine|full (got '$PROFILE')" >&2; exit 1 ;;
  esac
fi
: "${DIR_SET:=4}"
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
already_done() {   # cache dir workload offload leaf
  [[ -f "$CSV" ]] || return 1
  awk -F, -v c="$1" -v d="$2" -v w="$3" -v o="$4" -v l="$5" -v r="$ROLE" \
    'NR>1 && $1==c && $2==d && $3==w && $4==o && $5==r && $10==l { hit=1 }
     END { exit !hit }' "$CSV"
}

CACHES=($CACHE_MB)
DIRS=($DIR_SET)
NCELL=$(echo "$CELLS" | grep -c '[^[:space:]]')

# Offload-off cells do not touch the memory node, so they are run once, at the
# first dir value, and not repeated for every other one. Each extra dir value
# therefore adds only the 8 offload-on cells per cache point.
NCELL_ON=$(echo "$CELLS" | grep -c ' on ')
TOTAL=$(( NCELL * ${#CACHES[@]} + (${#DIRS[@]} - 1) * NCELL_ON * ${#CACHES[@]} ))

# ---- preflight: the two ways a big dir-thread count goes wrong -------------
# 1. CHIME_DIR_THREADS is clamped to NR_DIRECTORY at runtime, so asking for more
#    than the build allows silently runs fewer threads than the CSV will claim.
# 2. App threads take odd cores 1..2T-1 and dir threads take even cores from the
#    top, so the two ranges meet when 2*THREADS + 2*dirs exceeds the core count.
MAX_DIR=0
for d in "${DIRS[@]}"; do (( d > MAX_DIR )) && MAX_DIR=$d; done
NRDIR=$(grep -oP '^\s*#define\s+NR_DIRECTORY\s+\K[0-9]+' "$CHIME_DIR/include/Common.h" 2>/dev/null | tail -1)
if [[ -n "$NRDIR" && "$MAX_DIR" -gt "$NRDIR" ]]; then
  echo "ERROR: DIR_SET reaches $MAX_DIR but NR_DIRECTORY is $NRDIR." >&2
  echo "       Raise it in include/Common.h and rebuild BOTH nodes." >&2
  exit 1
fi
CORES=$(nproc 2>/dev/null || echo 0)
if [[ "$CORES" -gt 0 && $(( 2 * THREADS + 2 * MAX_DIR )) -gt "$CORES" ]]; then
  echo "WARNING: $THREADS app threads (odd cores up to $(( 2 * THREADS - 1 )))" >&2
  echo "         and $MAX_DIR dir threads (even cores down to $(( CORES - 2 * MAX_DIR )))" >&2
  echo "         do not both fit in $CORES cores. Threads will share cores and the" >&2
  echo "         memory-thread axis will partly measure contention." >&2
  [[ "${FORCE_CORES:-0}" == 1 ]] || { echo "         Set FORCE_CORES=1 to run anyway." >&2; exit 1; }
fi

# More than one dir value means the per-cell log paths need a dir_<n>/ level,
# or each pass overwrites the previous one. The CSV stays a single file.
if [[ ${#DIRS[@]} -gt 1 ]]; then export DIR_SUBDIR=1; fi

echo "=============================================================="
echo " CHIME leaf-cache study -- role=$ROLE"
echo "   sweep      : $BASE"
echo "   cells      : $TOTAL  ($NCELL per cache point, +$NCELL_ON per extra dir value)"
echo "                at ~6 min/cell that is about $(( TOTAL * 6 / 60 )) h"
echo "   profile    : $PROFILE"
echo "   cache (MB) : ${CACHES[*]}   split ${LEAF_PCT}% leaf / $((100-LEAF_PCT))% inner when leaf=1"
echo "                inner nodes get (total - 30) MB with leaf=0: the hotspot buffer takes 30 MB"
echo "   workload   : ${BULK}M keys, point ${POINT_OP}M ops, scan ${RANGE_OP}M ops x ${SCAN_RANGE} keys"
echo "   threads    : $THREADS app/node   dir threads: ${DIRS[*]} (cores: ${CORES:-unknown})"
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

for dir in "${DIRS[@]}"; do
 export DIR_THREADS="$dir"
 for cache in "${CACHES[@]}"; do
  while read -r wl off leaf; do
    [[ -z "$wl" ]] && continue
    # The offload-off control does not use the memory node, so it is measured
    # once rather than once per dir value.
    if [[ "$off" == "off" && "$dir" != "${DIRS[0]}" ]]; then continue; fi
    n=$(( n + 1 ))
    tag="cache=${cache}MB dir=$dir $wl offload=$off leaf=$leaf"

    if [[ -z "${FORCE:-}" ]] && already_done "$cache" "$dir" "$wl" "$off" "$leaf"; then
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
        break 3   # out of cells, cache points and dir values
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
