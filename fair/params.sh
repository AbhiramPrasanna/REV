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
#   same clients   40 client threads (one per physical core), all on the compute node
#   tree           see TREE_SETUP below: "stress" (default) gives each system the
#                  tree that exposes its weak spot; "fair" gives both the same tree
#   same cache     the TOTAL compute-side cache is the swept value in all three
#                  (DART keeps no node cache, so for DART it has no effect)
#   same run       10M warmup ops (DEX, CHIME; DART has no warmup phase) then
#                  30M measured ops; p99 from 0.5 us histograms in all three
# ===========================================================================

: "${RUN_ID:?set RUN_ID to the same name on both servers, e.g. RUN_ID=fair1}"

: "${MEM_IP:=10.30.1.8}"        # memory node (server 8)
: "${CMP_IP:=10.30.1.6}"        # compute node (server 6)
: "${MEMC_PORT:=11211}"

: "${THREADS:=40}"              # client threads, compute node only (40 physical cores)
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

# ---------------------------------------------------------------------------
# Tree setup. TREE_SETUP picks how each system's tree is shaped:
#
#   stress (default)  each system in the setup that exposes its weak spot; the
#                     two trees are NOT the same, and are not meant to be.
#     DEX   old DEX geometry: 160 B inner pages (5 entries), 512 B leaf pages
#           (26 entries), every node in a 512 B slot. DEX's sorted load leaves
#           inner nodes with ~2 children, so the tree is 22 levels with as many
#           inner nodes as leaves: ~3.85M inner (1,878 MB) + ~3.85M leaves
#           (1,878 MB) = ~3.7 GB. The inner nodes alone exceed every cache size,
#           so a lookup with offloading off still misses several levels and the
#           leaf; one request to the memory node replaces all of those reads.
#           (Measured in dex/build/results/*.log: height 22, 4.5 reads/lookup at
#           256 MB.) Tree kept on the memory node only (DEX_PLACEMENT=mn_only);
#           DEX_PLACEMENT=both is the original placement over both machines.
#     CHIME stock CHIME tree: 16-entry nodes, keys inserted in shuffled order
#           (~69% full): ~7 levels, inner nodes ~90-100 MB. They do not fit at 32
#           and 64 MB, which is where offloading and the leaf cache should help.
#
#   fair              both trees the same shape (fair3/shape runs): DEX 336/352 B
#                     pages (16 entries), CHIME bulk-built with DEX's fill
#                     (8 keys per leaf, 7 children per inner node), 9 levels each.
#
#   model             each system's ORIGINAL node format, the one the analytical
#                     model and measurement-summary-with-plots.pdf assume:
#     DEX   1 KB inner and leaf pages (stock DEX pageSize = 1024), sorted bulk
#           load. 50M keys: ~5 inner levels, inner ~60 MB, leaves ~1.7 GB.
#     CHIME stock 64-entry inner and leaf nodes, 8 B values, keys inserted
#           shuffled (CHIME's own load). 50M keys: ~4 inner levels, inner
#           ~25-30 MB; CHIME's shipped cache is 100 MB (70 MB tree cache +
#           30 MB hotspot buffer).
#     Sizes are estimates until the first cell prints the tree.
#
# Every cell prints the tree it ran on (height, inner and leaf node counts and
# MB, total MB) and writes it into the CSV.
# ---------------------------------------------------------------------------
: "${TREE_SETUP:=stress}"
case "$TREE_SETUP" in
  stress)
    : "${DEX_INNER_PAGE:=160}" "${DEX_LEAF_PAGE:=512}"
    : "${CHIME_BULK_BUILD:=0}"
    # Scans go to the memory node only when the cache cannot place them (CHIME's
    # own miss-gated rule), so cached inner nodes and the leaf cache still serve
    # scans where they can -- the regime this setup is meant to show.
    : "${CHIME_SCAN_OFFLOAD_ALWAYS:=0}" ;;
  fair)
    : "${DEX_INNER_PAGE:=336}" "${DEX_LEAF_PAGE:=352}"
    : "${CHIME_BULK_BUILD:=1}"
    : "${CHIME_SCAN_OFFLOAD_ALWAYS:=1}" ;;   # every scan to the memory node, like DEX+
  model)
    : "${DEX_INNER_PAGE:=1024}" "${DEX_LEAF_PAGE:=1024}"
    : "${CHIME_BULK_BUILD:=0}"
    : "${CHIME_SCAN_OFFLOAD_ALWAYS:=0}"      # CHIME's own rule: push a scan on a miss
    CHIME_INTERNAL_SPAN=64 CHIME_LEAF_SPAN=64 ;;
  deep)
    # Height 10 for both (the model's "deeper tree", lesson 7: smaller nodes,
    # 8 B keys). DEX: 288 B inner pages = 13 entries (~6 children after DEX's
    # sorted load), 352 B leaves = 16 entries (~8 keys): 6.25M leaves, 9 inner
    # levels. CHIME: 16-entry nodes bulk-built to the same shape (8 keys per
    # leaf, 6 children per inner node). Inner nodes ~1.25M each (~440 MB DEX).
    : "${DEX_INNER_PAGE:=288}" "${DEX_LEAF_PAGE:=352}"
    : "${CHIME_BULK_BUILD:=1}"
    : "${CHIME_BUILD_LEAF_KEYS:=8}" "${CHIME_BUILD_INNER_FANOUT:=6}"
    : "${CHIME_SCAN_OFFLOAD_ALWAYS:=0}"
    CHIME_INTERNAL_SPAN=16 CHIME_LEAF_SPAN=16 ;;
  *) echo "TREE_SETUP must be stress, fair, model or deep (got '$TREE_SETUP')" >&2; return 1 2>/dev/null || exit 1 ;;
esac
: "${DEX_PLACEMENT:=mn_only}"          # mn_only | both
: "${CHIME_INTERNAL_SPAN:=16}" "${CHIME_LEAF_SPAN:=16}"   # stress / fair: 16-entry nodes
: "${CHIME_BUILD_LEAF_KEYS:=8}"        # bulk build only (fair)
: "${CHIME_BUILD_INNER_FANOUT:=7}"
: "${CHIME_SORTED_LOAD:=0}"            # insert load order when not bulk-building; 0 = shuffled

# Paths (same layout on both servers).
REV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIR_DIR="$REV_DIR/fair"
RESULTS_DIR="$FAIR_DIR/results/$RUN_ID"
# one DEX build per geometry/placement, so switching TREE_SETUP never runs a
# binary built for the other geometry (run_dex.sh also checks [GEOMETRY]).
DEX_BUILD="$REV_DIR/dex/build_${DEX_INNER_PAGE}_${DEX_LEAF_PAGE}_${DEX_PLACEMENT}"
# one CHIME build per node format (build_fair = the 16/16 builds used so far);
# run_chime.sh checks the stamp.
if [ "$CHIME_INTERNAL_SPAN:$CHIME_LEAF_SPAN" = 16:16 ]; then
  CHIME_BUILD="$REV_DIR/CHIME/build_fair"
else
  CHIME_BUILD="$REV_DIR/CHIME/build_span${CHIME_INTERNAL_SPAN}_${CHIME_LEAF_SPAN}"
fi
DART_DIR="$REV_DIR/DART"

# ---------------------------------------------------------------------------
# small helpers shared by the run scripts
# ---------------------------------------------------------------------------
wl_dist()  { case "$1" in *-uniform) echo uniform ;; *) echo zipf ;; esac; }
wl_op()    { case "$1" in point-*) echo point ;; *) echo range ;; esac; }

# memcached text protocol over /dev/tcp (no nc needed).
# The open is wrapped in { ...; } 2>/dev/null on purpose: `exec 3<>X 2>/dev/null`
# makes BOTH redirections permanent, so the first successful call silently sent
# the calling script's stderr (all its warnings) to /dev/null for the rest of the
# run, while a failed call (memcached not up yet) still printed "Connection
# refused". The group limits the 2>/dev/null to the open itself.
memc_get() {   # host port key -> value (empty if missing/unreachable)
  local host=$1 port=$2 key=$3 line val=""
  { exec 3<>"/dev/tcp/${host}/${port}"; } 2>/dev/null || { echo ""; return 1; }
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
  { exec 3<>"/dev/tcp/$1/$2"; } 2>/dev/null || return 1
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

# ---------------------------------------------------------------------------
# CPU pinning, the same rule for DEX and CHIME on every server:
#   client thread i -> CPU i (CPUs 0..THREADS-1, one physical core each on the
#                      6/8 servers: CPU c and c+40 are the two hyperthreads of
#                      core c);
#   directory threads -> REV_DIR_CPUS, the CPUs whose PHYSICAL core no client
#                      uses, one per free core first, then their second
#                      hyperthreads. On server 6: 79,78,77,76,39,38,37,36.
# Before this, DEX's compute-node dir threads (which busy-poll even when idle)
# sat on the hyperthreads of clients 32..35 once memory threads >= 5, and CHIME's
# clients (pinned 2*id+1, i.e. odd CPUs) were packed two per core on 16 of the 20
# cores of one socket. Both binaries read REV_DIR_CPUS; CHIME also reads
# REV_CLIENT_PIN=linear.
# ---------------------------------------------------------------------------
dir_cpu_list() {   # -> comma list of CPUs free of client cores (needs lscpu)
  command -v lscpu >/dev/null || return 0
  # The memory node runs no client threads (DEX: THREADS == kMaxThread puts all
  # clients on the compute node; CHIME: CHIME_MN_CLIENTS=0), so reserving the
  # client cores there left directory threads only 4 physical cores and put
  # threads 5-8 on hyperthread siblings (stress1). On the memory node reserve
  # nothing: 8 threads get 8 physical cores, and threads 1-4 keep the same CPUs
  # as before (highest first: 79, 78, 77, 76, ...).
  local T="$THREADS"
  [ "${role:-}" = memory ] && T=0
  lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | awk -F, -v T="$T" '
    { cpu[NR]=$1; key[$1]=$3 ":" $2; n=NR }
    END {
      for (c = 0; c < T; c++) used[key[c]] = 1
      m = 0
      for (i = n; i >= 1; i--) { c = cpu[i]; if (!(key[c] in used)) free_[++m] = c }   # highest first
      out = ""
      for (i = 1; i <= m; i++) { c = free_[i]; if (!(key[c] in seen)) { seen[key[c]] = 1; out = out (out ? "," : "") c; taken[c] = 1 } }
      for (i = 1; i <= m; i++) { c = free_[i]; if (!(c in taken)) { out = out (out ? "," : "") c; taken[c] = 1 } }
      # No physical core left (40 clients on 40 cores): use the clients second
      # hyperthreads, highest first (79, 78, ... on the 6/8 servers).
      for (i = n; i >= 1; i--) { c = cpu[i]; if (c >= T && !(c in taken)) { out = out (out ? "," : "") c; taken[c] = 1 } }
      print out
    }'
}
pin_report() {   # print the plan and warn if two clients share a physical core
  command -v lscpu >/dev/null || { echo "pinning: lscpu missing, binaries fall back to their own rule"; return 0; }
  local shared
  shared=$(lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | awk -F, -v T="$THREADS" '$1 < T { k = $3 ":" $2; if (k in s) d++; s[k] = 1 } END { print d + 0 }')
  echo "pinning ($(hostname -s)): clients -> CPUs 0..$((THREADS - 1)); directory threads -> ${REV_DIR_CPUS:-<binary default>}"
  [ "$shared" -gt 0 ] && echo "WARNING: $shared client CPUs share a physical core with another client" >&2
  return 0
}
: "${REV_DIR_CPUS:=$(dir_cpu_list)}"   # set REV_DIR_CPUS by hand to override
# REV_PARK_CMP_DIRS=1: on the compute node, put every directory thread on ONE CPU
# (the first in the list, 79 on the 6/8 servers). DEX and CHIME start as many
# directory threads there as on the memory node, and they spin in pollWithCQ, but
# they have no work: the whole tree lives on the memory node (DEX MN_ONLY_PLACEMENT,
# CHIME MEMORY_NODE_NUM=1). With 40 clients on 40 cores, k spread-out directory
# threads would share the cores of k clients; parked, only client 39 shares one.
if [ "${role:-}" = compute ] && [ "${REV_PARK_CMP_DIRS:-0}" = 1 ] && [ -n "$REV_DIR_CPUS" ]; then
  REV_DIR_CPUS="${REV_DIR_CPUS%%,*}"
fi
REV_CLIENT_PIN=linear
export REV_DIR_CPUS REV_CLIENT_PIN

preflight_cores() {   # warn if client + memory threads cannot each get a core
  local need=$1 have
  have=$(nproc 2>/dev/null || echo 0)
  if [ "$have" -lt "$need" ]; then
    echo "WARNING: $(hostname -s) has $have logical CPUs; this run pins ~$need threads." >&2
    echo "         Threads will share cores and results will understate every system." >&2
  fi
}
