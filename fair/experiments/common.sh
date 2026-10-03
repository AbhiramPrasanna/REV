# ===========================================================================
# fair/experiments/common.sh -- shared by the "measurements for intro and
# motivation" scripts (e1..e6). Each script is a thin wrapper around
# fair/run_all.sh: it walks a fixed list of blocks (system x tree x settings),
# and both servers walk the SAME list in the SAME order, so run the same script
# with the same variables on both:
#
#   server 8:  bash fair/experiments/e1_pull_push.sh memory
#   server 6:  bash fair/experiments/e1_pull_push.sh compute
#
# Nothing here changes any system's code or the fair/ harness. "Push" is each
# system's existing push-on-miss (memory threads >= 1); at the smallest cache
# (8 MB) almost every operation misses, so that cell is the near-push-only end.
# Pull only = memory threads 0.
#
# Every block can be trimmed from the environment, e.g.
#   SYSTEMS=dex TREES=stress bash fair/experiments/e1_pull_push.sh compute
# Results: fair/results/<RUN_ID>/<system>/..., one RUN_ID per block (printed).
# ===========================================================================
set -uo pipefail
EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIR="$(cd "$EXP_DIR/.." && pwd)"

ROLE="${1:-}"
case "$ROLE" in compute|memory) ;; *) echo "usage: $0 <compute|memory>" >&2; exit 1 ;; esac

# Rough minutes per cell, measured: DEX stress1 (memory-node 2 s reports: 110 s
# process time + script pauses), CHIME fair3 (145 s), CHIME stress cells are
# slower (shuffled load; pulled scans at small caches run at 0.04-0.06 M/s).
min_per_cell() {   # system tree
  case "$1:$2" in
    dex:*)          echo 2.3 ;;
    chime:stress)   echo 6 ;;
    chime:fair)     echo 2.5 ;;
    dart:*)         echo 2 ;;
    *)              echo 3 ;;
  esac
}

PLAN=()        # "run_id|system|tree|cells|VAR=value;VAR=value;..."
plan_block() { # run_id system tree cells [VAR=value ...]  (values may contain spaces)
  local id=$1 sys=$2 tree=$3 cells=$4; shift 4
  local IFS=';'
  PLAN+=("$id|$sys|$tree|$cells|$*")
}
count_cells() { # caches memthreads workloads -> number of cells
  local n=0 c m w
  for c in $1; do for m in $2; do for w in $3; do n=$((n + 1)); done; done; done
  echo "$n"
}

show_plan() {
  local total=0 line id sys tree cells extra min h
  echo "== plan ($ROLE): ${#PLAN[@]} blocks"
  for line in "${PLAN[@]}"; do
    IFS='|' read -r id sys tree cells extra <<< "$line"
    min=$(min_per_cell "$sys" "$tree")
    h=$(awk -v n="$cells" -v m="$min" 'BEGIN{printf "%.1f", n*m/60}')
    total=$(awk -v t="$total" -v n="$cells" -v m="$min" 'BEGIN{printf "%.2f", t + n*m/60}')
    printf "   %-28s %-6s %-6s %4d cells  ~%5s h   %s\n" "$id" "$sys" "$tree" "$cells" "$h" "$extra"
  done
  echo "== estimated total: ~$(awk -v t="$total" 'BEGIN{printf "%.1f", t}') h (DEX ~2.3, CHIME ~2.5-6, DART ~2 min/cell)"
}

run_plan() {
  local line id sys tree cells extra
  [ "${DRY_RUN:-0}" = 1 ] && { echo "DRY_RUN=1: not running"; return 0; }
  for line in "${PLAN[@]}"; do
    IFS='|' read -r id sys tree cells extra <<< "$line"
    echo
    echo "######## $(date '+%F %T')  block $id  ($sys, tree=$tree, $cells cells)  $extra"
    local kv=()
    [ -n "$extra" ] && IFS=';' read -ra kv <<< "$extra"
    if ! env RUN_ID="$id" SYSTEMS="$sys" TREE_SETUP="$tree" ${kv[@]+"${kv[@]}"} \
         bash "$FAIR/run_all.sh" "$ROLE"; then
      echo "!! block $id failed on $ROLE. Fix it, then rerun this script with" >&2
      echo "!! SKIP_TO=$id to resume from this block (on both servers)." >&2
      exit 1
    fi
  done
  echo "== all blocks done ($ROLE) $(date '+%F %T')"
}

# SKIP_TO=<run_id>: drop the blocks before it (resume after a failure).
apply_skip() {
  [ -z "${SKIP_TO:-}" ] && return 0
  local keep=() on=0 line
  for line in "${PLAN[@]}"; do
    [ "${line%%|*}" = "$SKIP_TO" ] && on=1
    [ "$on" = 1 ] && keep+=("$line")
  done
  [ "${#keep[@]}" -eq 0 ] && { echo "SKIP_TO=$SKIP_TO matches no block" >&2; exit 1; }
  PLAN=("${keep[@]}")
}
