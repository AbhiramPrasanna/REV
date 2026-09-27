#!/bin/bash
# ===========================================================================
# fair/run_all.sh <compute|memory> -- the whole fair sweep, one command per
# server: DART, then DEX, then CHIME, then (compute server) the comparison.
#
#   server 8:  RUN_ID=fair1 ./fair/run_all.sh memory
#   server 6:  RUN_ID=fair1 ./fair/run_all.sh compute
#
# Both servers walk the same systems in the same order, and each system's
# script synchronises its own cells, so they stay in step.
#
# Full matrix with the defaults (9 memory-thread counts x 6 caches x 4 workloads):
#   DART    24 cells   (~1 h)
#   DEX    216 cells   (~11 h at ~3 min a cell)
#   CHIME  432 cells   (~40 h at ~5-6 min a cell; x2 for the leaf cache arms)
# For a first pass:  MEMTHREADS="0 1 2 4 8" CACHES="32 128 512 1024"
# ===========================================================================
set -uo pipefail
role="${1:?usage: run_all.sh <compute|memory>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/params.sh"

systems=(${SYSTEMS:-dart dex chime})
for s in "${systems[@]}"; do
  echo "######## $s ($role) ########"
  "$here/run_${s}.sh" "$role" || { echo "$s failed on $role" >&2; exit 1; }
  sleep 10
done

if [ "$role" = compute ]; then
  python3 "$here/collect.py" "$RESULTS_DIR" || echo "collect.py failed; run it by hand" >&2
fi
