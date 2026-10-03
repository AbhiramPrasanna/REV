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
    chime:model)    echo 4 ;;
    dart:*)         echo 2 ;;
    *)              echo 3 ;;
  esac
}

# ---------------------------------------------------------------------------
# Cache sizes shared by the challenge scripts (MB, in each system's own units).
# Measured trees: DEX stress inner 1,878 MiB / whole 3,756 MiB; DEX fair inner
# 350 MB / whole 2,448 MB; CHIME stress inner 129 MB / whole 1,627 MB; CHIME fair:
# estimate (set from the fair3 [TREE] line).
#   *_INNER  the inner nodes fit (no inner miss; a lookup = cached path + 1 leaf)
#   *_M1     about one inner level left uncached (the model's m = 1 case)
# Every DEX cell prints reads/op, so a size that misses its target shows up.
# ---------------------------------------------------------------------------
: "${DEX_STRESS_INNER:=2600}"  ; : "${DEX_STRESS_M1:=1024}"   # 1024 MB: ~2.2 reads/lookup (1 inner + leaf)
: "${DEX_FAIR_INNER:=640}"     ; : "${DEX_FAIR_M1:=64}"       # bottom inner level (~300 MB) not cached
: "${CHIME_STRESS_INNER:=192}" ; : "${CHIME_STRESS_M1:=32}"   # bottom inner level (~110 MB) not cached
: "${CHIME_FAIR_INNER:=640}"   ; : "${CHIME_FAIR_M1:=64}"     # estimates: verify from fair3
# model = each system's original node format (TREE_SETUP=model in params.sh).
# Estimates for 50M keys until the first cells print the tree:
#   DEX 1 KB pages: inner ~60 MB (bottom inner level ~97% of it), whole ~1.8 GB
#   CHIME 64-entry nodes: inner ~25-30 MB. 100 MB = CHIME's shipped cache
#   (70 MB tree cache + 30 MB hotspot buffer; CHIME adds the hotspot buffer only
#   above 50 MB, so a total of 64 MB is a 34 MB tree cache + 30 MB buffer).
: "${DEX_MODEL_INNER:=128}"    ; : "${DEX_MODEL_M1:=4}"       # M1: only levels above the bottom one fit
: "${CHIME_MODEL_INNER:=100}"  ; : "${CHIME_MODEL_M1:=2}"
: "${DEX_MODEL_WHOLE:=2600}"
# CHIME cache sweeps (MB) per tree, used by c2 and c3. (DEX's sweeps differ
# between c2, which adds a whole-tree point, and c3, so each script sets its own.)
: "${C2_CHIME_STRESS:=8 16 32 64 128 192}"
: "${C2_CHIME_FAIR:=8 32 64 128 256 640}"
: "${C2_CHIME_MODEL:=2 4 8 16 32 64 100}"
size_of() {   # system tree INNER|M1 -> MB   (dexr uses DEX's sizes)
  local s=$1; [ "$s" = dexr ] && s=dex
  local v; v="$(echo "${s}_${2}_${3}" | tr a-z A-Z)"; echo "${!v}"
}

# "dexr" = DEX with reads pushed from the deepest cached node (DEX-R,
# DEX_PUSH_READS_DEEPEST=1); it runs the DEX binary. Writes keep DEX's rule.
real_sys() { [ "$1" = dexr ] && echo dex || echo "$1"; }
sys_env()  { [ "$1" = dexr ] && echo "DEX_PUSH_READS_DEEPEST=1" || echo "DEX_PUSH_READS_DEEPEST=0"; }

# add_block id system tree cells VAR=value...  (handles dexr; CHIME leaf cache off
# and scans pushed only on a miss unless the caller overrides)
add_block() {
  local id=$1 sys=$2 tree=$3 cells=$4; shift 4
  plan_block "$id" "$(real_sys "$sys")" "$tree" "$cells" "$(sys_env "$sys")" \
    "CHIME_LEAF_SET=0" "CHIME_SCAN_OFFLOAD_ALWAYS=0" "$@"
}

# One-client ("idle") cells, the closest a closed loop gets to the model's idle
# latency. One client is slow, so fewer ops; warmup still has to fill the cache.
IDLE_ENV=("THREADS=1" "OPS_M=1" "WARMUP_M=10")

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
    # a block may carry "@min=<minutes per cell>" to override the estimate
    case ";$extra;" in *";@min="*) min=$(sed -nE 's/.*(^|;)@min=([0-9.]+).*/\2/p' <<< "$extra") ;; esac
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
    local kv=() all=() t
    [ -n "$extra" ] && IFS=';' read -ra all <<< "$extra"
    for t in ${all[@]+"${all[@]}"}; do [ "${t#@}" = "$t" ] && kv+=("$t"); done   # drop @-notes
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
