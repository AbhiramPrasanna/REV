#!/bin/bash
# ===========================================================================
# run_challenges.sh <memory|compute> -- the one script for both servers: runs
# every challenge experiment (c1..c6, c2b) back to back, in the same order on
# both sides. Start the memory side first or in either order:
#
#   server 8:  bash fair/experiments/run_challenges.sh memory  2>&1 | tee ~/ch_memory.out
#   server 6:  bash fair/experiments/run_challenges.sh compute 2>&1 | tee ~/ch_compute.out
#
# Both servers must use the SAME variables:
#   CHALLENGES  which, in order (default: c1 c2 c2b c3 c4 c5 c6)
#   SYSTEMS_C   systems inside each challenge (default per script: dexr chime
#               [dart]); add "dex" for stock DEX
#   TREES       stress fair (default per script)
#   DRY_RUN=1   print every plan and time estimate, run nothing
# Resume after a failure: CHALLENGES="<failed one> <the rest>" SKIP_TO=<block>
#   (SKIP_TO applies to the first challenge only).
#
#   c1   push needs memory-node CPU           (summary Fig. 1, 1b)
#   c2   cache budget flips the winner        (Fig. 2, 2b)
#   c2b  CHIME at its 70 MB cache vs keys     (Fig. 8)
#   c3   depth of the miss and load, 1 client (Fig. 3; model constants)
#   c4   query type: scan length, updates     (Fig. 4)
#   c5   same policy, different structures    (Fig. 5)
#   c6   load and skew                        (Fig. 6)
# DEX-R = DEX with reads pushed from the deepest cached node (writes keep
# DEX's rule); needs the DEX build from this commit on both servers.
# ===========================================================================
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
role="${1:?usage: run_challenges.sh <memory|compute>}"
case "$role" in compute|memory) ;; *) echo "role must be compute or memory" >&2; exit 1 ;; esac
: "${CHALLENGES:=c1 c2 c2b c3 c4 c5 c6}"
declare -A script=([c1]=c1_cores.sh [c2]=c2_cache.sh [c2b]=c2b_chime_keys.sh
                   [c3]=c3_depth_load.sh [c4]=c4_query_type.sh [c5]=c5_structure.sh
                   [c6]=c6_load_skew.sh)
for c in $CHALLENGES; do
  [ -n "${script[$c]:-}" ] || { echo "unknown challenge '$c' (use: ${!script[*]})" >&2; exit 1; }
done

echo "== challenges ($role): $CHALLENGES   started $(date '+%F %T')"
first=1
for c in $CHALLENGES; do
  echo; echo "==================== $c (${script[$c]}) ===================="
  if [ "$first" = 1 ]; then
    bash "$here/${script[$c]}" "$role"
  else
    env -u SKIP_TO bash "$here/${script[$c]}" "$role"
  fi || { echo "!! $c failed on $role. Resume on BOTH servers with" >&2
          echo "!!   CHALLENGES=\"<$c and the rest>\" SKIP_TO=<failed block>" >&2; exit 1; }
  first=0
done
echo; echo "== challenges done ($role): $CHALLENGES   $(date '+%F %T')"
