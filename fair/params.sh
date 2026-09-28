# ===========================================================================
# fair/params.sh -- ONE set of settings for the fair DEX / CHIME / DART sweep.
# Sourced by every fair/*.sh on BOTH servers. Anything here can be overridden
# from the environment, but both servers must see the SAME values (in particular
# RUN_ID, CACHES, MEMTHREADS, WORKLOADS), because the two sides walk the same
# list of cells in the same order.
#
#   server 8 (10.30.1.8) = memory node   server 6 (10.30.1.6) = compute node
#
# What "fair" fixes (see ARCHITECTURE.md §7):
#   same data      50M keys, 8 B keys, 8 B values, in all three systems
#   same clients   36 client threads, all on the compute node
#   same tree      DEX and CHIME both use 16-entry inner nodes and 16-entry leaves,
#                  AND the same fill: CHIME is built with DEX's measured 8 keys per
#                  leaf and 7 children per inner node, so height (9), leaf count and
#                  inner-node count match. Same node size alone is not enough.
#   same cache     the TOTAL compute-side cache is the swept value in all three
#                  (DART keeps no node cache, so for DART it has no effect)
#   same run       10M warmup ops (DEX, CHIME; DART has no warmup phase) then
#                  30M measured ops; p99 from 0.5 us histograms in all three
# ===========================================================================

: "${RUN_ID:?set RUN_ID to the same name on both servers, e.g. RUN_ID=fair1}"

: "${MEM_IP:=10.30.1.8}"        # memory node (server 8)
: "${CMP_IP:=10.30.1.6}"        # compute node (server 6)
: "${MEMC_PORT:=11211}"

: "${THREADS:=36}"              # client threads, compute node only
: "${KEYS_M:=50}"               # keys loaded, millions
: "${VALUE_B:=8}"               # value bytes
: "${WARMUP_M:=10}"             # warmup ops, millions (DEX, CHIME)
: "${OPS_M:=30}"                # measured ops, millions
: "${SCAN_LEN:=100}"            # keys per range scan
: "${ZIPF_THETA:=0.99}"

# Swept axes.
: "${CACHES:=32 64 128 256 512 1024}"       # total compute-side cache, MB
: "${MEMTHREADS:=0 1 2 3 4 5 6 7 8}"         # memory node threads; 0 = no offloading
: "${WORKLOADS:=point-uniform point-zipf range-uniform range-zipf}"

# CHIME leaf cache arms run at every cell ("0 1"); CHIME+ is the better of the two.
: "${CHIME_LEAF_SET:=0 1}"

# Fair tree geometry (bytes). DEX: 64 B node header, 16 B per entry.
#   inner 336 -> (336-8-64)/16 = 16 entries   leaf 352 -> (352-32-64)/16 = 16 entries
# CHIME: leafSpanSize = 16 (fixed in Common.h); internalSpanSize set below.
#
# Matching the TREE, not just the node capacity:
#   DEX (fair3, measured): sorted inserts leave nodes half full -- 9 levels,
#     6,249,999 leaves (8 keys each), 1,041,652 inner nodes (7 children each).
#   CHIME inserting the same sorted keys got 8 levels and 772,006 inner nodes
#     (its inner split keeps 9 children, not 7) and took 43 min to load.
#   So CHIME is BUILT bottom-up from the sorted keys with DEX's fill
#     (CHIME_BULK_BUILD=1, 8 keys per leaf, 7 children per inner node), same
#     16-entry nodes as DEX: expected 9 levels, 6,250,000 leaves, ~1,041,667
#     inner nodes (~333 MB at 335 B, against DEX's 350 MB at 352 B). Takes
#     seconds. The workloads are read-only, so how the tree was built does not
#     change what is measured.
DEX_INNER_PAGE=336
DEX_LEAF_PAGE=352
CHIME_INTERNAL_SPAN=16
: "${CHIME_BULK_BUILD:=1}"
: "${CHIME_BUILD_LEAF_KEYS:=8}"
: "${CHIME_BUILD_INNER_FANOUT:=7}"
# Insert-based loads, only used with CHIME_BULK_BUILD=0:
# CHIME_SORTED_LOAD=1 inserts in sorted order (slow, see above); 0 = stock shuffled.
: "${CHIME_SORTED_LOAD:=0}"

# Paths (same layout on both servers).
REV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIR_DIR="$REV_DIR/fair"
RESULTS_DIR="$FAIR_DIR/results/$RUN_ID"
DEX_BUILD="$REV_DIR/dex/build_fair"
CHIME_BUILD="$REV_DIR/CHIME/build_fair"
DART_DIR="$REV_DIR/DART"

# ---------------------------------------------------------------------------
# small helpers shared by the run scripts
# ---------------------------------------------------------------------------
wl_dist()  { case "$1" in *-uniform) echo uniform ;; *) echo zipf ;; esac; }
wl_op()    { case "$1" in point-*) echo point ;; *) echo range ;; esac; }

# memcached text protocol over /dev/tcp (no nc needed).
memc_get() {   # host port key -> value (empty if missing/unreachable)
  local host=$1 port=$2 key=$3 line val=""
  exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null || { echo ""; return 1; }
  printf 'get %s\r\n' "$key" >&3
  while IFS= read -r -t 2 line <&3; do
    line=${line%$'\r'}
    case "$line" in
      VALUE*) IFS= read -r -t 2 val <&3; val=${val%$'\r'} ;;
      END|ERROR*|"") break ;;
    esac
  done
  exec 3>&- 3<&-
  echo "$val"
}
memc_set_zero() {   # host port key
  exec 3<>"/dev/tcp/$1/$2" 2>/dev/null || return 1
  printf 'set %s 0 0 1\r\n0\r\n' "$3" >&3
  IFS= read -r -t 2 _ <&3
  exec 3>&- 3<&-
}

# Terminal filter: hide the every-2-second load reports (REMOTE CPU LOAD / dir /
# AGGREGATE / [CPU ...] lines) so the per-cell results stay readable. The log
# files written by `tee` still contain everything (the scripts parse them).
# SHOW_LOAD=1 shows them on the terminal too.
quiet_filter() {
  if [ "${SHOW_LOAD:-0}" = 1 ]; then cat; return; fi
  grep --line-buffered -vE '^[[:space:]]*$|REMOTE CPU LOAD|^[[:space:]]*dir [0-9]+: active|AGGREGATE active|^\[CPU (compute|memory) *\]' || true
}

# Clear everything a previous run could have left on THIS server: benchmark
# processes of all three systems and this user's memcached. Each system's
# script also resets memcached before every cell; this is the between-systems
# (and after-a-crash) reset. Safe to run when nothing is left.
cleanup_node() {
  echo ">> [$(hostname -s)] cleanup: stopping leftover newbench / micro_test / DART processes and memcached"
  sudo -n pkill -9 -x newbench 2>/dev/null   # -n: never stop for a password
  pkill -9 -u "$(id -u)" -x micro_test 2>/dev/null
  sudo -n pkill -9 -f "$DART_DIR/bin/(monitor|compute|memory)" 2>/dev/null
  pkill -u "$(id -u)" -x memcached 2>/dev/null   # only ours: server 8 is shared
  rm -f /tmp/memcached-fair.pid
  sleep 3
  if pgrep -x newbench >/dev/null || pgrep -u "$(id -u)" -x micro_test >/dev/null; then
    echo ">> cleanup: WARNING, benchmark processes still running:" >&2
    pgrep -af "newbench|micro_test" >&2
  fi
}

preflight_cores() {   # warn if client + memory threads cannot each get a core
  local need=$1 have
  have=$(nproc 2>/dev/null || echo 0)
  if [ "$have" -lt "$need" ]; then
    echo "WARNING: $(hostname -s) has $have logical CPUs; this run pins ~$need threads." >&2
    echo "         Threads will share cores and results will understate every system." >&2
  fi
}
