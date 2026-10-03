#!/bin/bash
# ===========================================================================
# run_challenges.sh <memory|compute> -- run c1..c6 back to back on this server.
# Run the same command (same variables) on both servers. CHALLENGES picks a
# subset, e.g. CHALLENGES="c1 c2". DRY_RUN=1 prints every plan and the total.
#   server 8:  bash fair/experiments/run_challenges.sh memory
#   server 6:  bash fair/experiments/run_challenges.sh compute
# ===========================================================================
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
role="${1:?usage: run_challenges.sh <memory|compute>}"
: "${CHALLENGES:=c1 c2 c2b c3 c4 c5 c6}"
declare -A script=([c1]=c1_cores.sh [c2]=c2_cache.sh [c2b]=c2b_chime_keys.sh
                   [c3]=c3_depth_load.sh [c4]=c4_query_type.sh [c5]=c5_structure.sh
                   [c6]=c6_load_skew.sh)
for c in $CHALLENGES; do
  [ -n "${script[$c]:-}" ] || { echo "unknown challenge $c" >&2; exit 1; }
  echo; echo "==================== $c (${script[$c]}) ===================="
  bash "$here/${script[$c]}" "$role" || { echo "!! $c failed on $role; resume with CHALLENGES and SKIP_TO" >&2; exit 1; }
done
echo "== challenges done: $CHALLENGES"
