#!/bin/bash
# ===========================================================================
# fair/run_all.sh <compute|memory> -- run the fair sweep for several systems
# back to back, with a clean slate before each one.
#
#   server 8:  RUN_ID=fair3 bash fair/run_all.sh memory
#   server 6:  RUN_ID=fair3 bash fair/run_all.sh compute
#
# Default systems: DEX then CHIME (SYSTEMS="dex chime"). Add DART with
# SYSTEMS="dart dex chime". Before each system and at the end, this server's
# leftover benchmark processes and memcached are cleared (cleanup_node in
# params.sh); inside each system, memcached is also reset before every cell.
# The two servers stay in step through each system's own handshake, so start
# both commands in either order.
#
# PROFILE=quick  a ~30 minute check before the long run: 2 memory-thread
#                settings (0 = off, 4) x 1 cache (128 MB) x point-uniform and
#                range-uniform, leaf cache off -- 4 DEX cells, 4 CHIME cells.
#                It exercises both new paths: DEX memory-node-only placement
#                and the CHIME scan path.
# PROFILE=full   (default) everything in params.sh: 9 memory-thread settings x
#                6 caches x 4 workloads; DEX ~11 h, CHIME ~40 h.
# ===========================================================================
set -uo pipefail
role="${1:?usage: run_all.sh <compute|memory>}"
case "$role" in compute|memory) ;; *) echo "role must be compute or memory" >&2; exit 1 ;; esac

if [ "${PROFILE:-full}" = quick ]; then
  export MEMTHREADS="${MEMTHREADS:-0 4}"
  export CACHES="${CACHES:-128}"
  export WORKLOADS="${WORKLOADS:-point-uniform range-uniform}"
  export CHIME_LEAF_SET="${CHIME_LEAF_SET:-0}"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/params.sh"
ulimit -l unlimited 2>/dev/null || echo "note: could not raise the locked-memory limit (DART needs it)" >&2

systems=(${SYSTEMS:-dex chime})
echo "== fair run: RUN_ID=$RUN_ID role=$role systems=[${systems[*]}] profile=${PROFILE:-full}"
echo "   memory threads=[$MEMTHREADS] caches=[$CACHES] workloads=[$WORKLOADS]"

for s in "${systems[@]}"; do
  cleanup_node
  echo
  echo "######################## $s ($role) ########################"
  if ! "$here/run_${s}.sh" "$role"; then
    echo "!! $s failed on $role -- stopping. Stop the other server too (Ctrl-C)," >&2
    echo "!! then rerun both with a new RUN_ID, or SYSTEMS=<remaining systems>." >&2
    cleanup_node
    exit 1
  fi
  echo "== $s finished on $role"
  sleep 10          # let the other server finish its last cell of this system
done
cleanup_node

if [ "$role" = compute ]; then
  echo
  echo "== results"
  for f in "$RESULTS_DIR/dex/dex_compute.csv" "$RESULTS_DIR"/chime/sweep_mt*/summary_compute.csv; do
    [ -f "$f" ] || continue
    echo "-- $f"
    column -s, -t < "$f" 2>/dev/null | cut -c1-160 || cat "$f"
  done
  python3 "$here/collect.py" "$RESULTS_DIR" || echo "collect.py failed; run it by hand" >&2
fi
echo "== fair run done ($role)"
