#!/bin/bash
# ===========================================================================
# run_lesson2.sh <memory|compute> -- the Lesson 2 sweep, end to end:
#   "Execution placement should depend on the operation and the index level.
#    Pushing uncached traversal can free cache space for hot leaves, while
#    batching scan work reduces dependent network round trips."
#
# Three systems, each with push OFF (0 memory server threads) and push ON with
# 1, 2, 4, 8 and 16 memory server threads, uniform and Zipf 0.99 keys, a cache
# sweep from 8 MB up past the size where all inner nodes fit (~162 MB on this
# tree), and the same 36 client threads on the compute server everywhere:
#
#   shipped  stock CHIME as shipped: hotspot buffer + speculative read ON (CHIME
#            turns the buffer on by itself above 50 MB and gives it 30 MB of the
#            cache), inner nodes only, no leaf cache. Run from 64 MB: at 8-32 MB
#            it is the same system as "stock".
#   stock    stock CHIME, hotspot buffer OFF, inner nodes only.
#   2p       CHIME-2P: hotspot buffer OFF (never both: the leaf cache and the
#            buffer answer the same question), inner cache cut to the top levels
#            (min(32 MB, half the cache)), the rest of the budget holds hot leaves.
#            Cached leaves are found by key before any inner node
#            (CHIME_LEAF_BY_KEY), served with no network check because the
#            compute server is the only writer (CHIME_LEAF_OWNER, as DEX's key
#            ownership), and a pushed lookup brings its leaf's address back so
#            10% of them cache that leaf (CHIME_LEAF_ADMIT_PUSH). Push off shows
#            the same split without push, i.e. what freeing the space costs if
#            the uncached levels are pulled instead.
#
# Parts (PARTS="a b c d e", all by default):
#   a  lookups: shipped | stock | 2p, threads 0..16, caches 8..1024     (252 cells)
#   b  ablation, lookups, 16 threads: 2p with the network check kept (owner
#      off) and 2p found by address only (by key off): what each piece adds (12)
#   c  scans of 100 keys: stock pull vs every scan pushed, threads 0..16,
#      caches 8 32 128 512; shipped at 128 and 512 as the reference      (52)
#   d  one choice per operation, 50/50 lookups and scans, 16 threads: pull
#      all | push lookups | push scans | push both | 2p + push both      (30)
#   e  tree shapes: the bulk-built tree at 14 children per inner node (about 7
#      levels) and 3 (about 15 levels); the 6-children tree (10 levels) is part
#      a. shipped | stock pull | stock push | 2p push, caches 32 128 512  (44)
#
# Tree: TREE_SETUP=deep (bulk built, 6.25M leaves, 10 levels at 6 children,
# 1.25M inner nodes, ~162 MB of them in CHIME's cache), 50M keys, 10M warmup +
# 30M measured ops. The cache budget is ONE total: inner + leaf (+ the hotspot
# buffer in "shipped") always equals the sweep point.
#
# Every cell records (collect_lesson2.py puts it in one row per cell):
#   throughput, latency mean/p50/p90/p99/p99.9; [RDMA] round trips, reads,
#   writes, atomics, pushed requests and bytes per operation; [LEVEL]/[KIND]
#   cache hits per tree level and inner against leaf; [SCANLEAF]; [LEAFCACHE]
#   and [LEAFKEY] leaf hits, hits by key, leaves cached after a push; pushed work;
#   memory server CPU (memory log, server 8); tree shape; NIC bytes per second.
#
# Build on BOTH servers first (the leaf-cache switches are new), from ~/REV:
#   git stash push CHIME/include/Rdma.h; git pull --no-rebase --no-edit; git stash pop
#   RUN_ID=chime_build TREE_SETUP=deep ./fair/build.sh chime
#   strings CHIME/build_fair/micro_test | grep -c "CHIME_LEAF_BY_KEY\|CHIME_LEAF_OWNER\|CHIME_LEAF_ADMIT_PUSH"   # 3
#
# Run (memory first, same variables on both, one terminal each, no tmux):
#   server 8:  cd ~/REV && bash fair/experiments/run_lesson2.sh memory  2>&1 | tee ~/l2_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_lesson2.sh compute 2>&1 | tee ~/l2_compute.out
#
# Useful variables (set the SAME on both servers):
#   PARTS="a"           run only some parts
#   DRY_RUN=1           print the plan and the time estimate, run nothing
#   SKIP_TO=<block>     resume from a block after a failure
#   L2_TAG=l2smoke      block-name prefix; a smoke test with another tag never
#                       mixes with the real results (the collector reads $L2_TAG_*)
#   SMOKE=1             2M warmup + 3M measured ops, two caches, threads 0 and 16:
#                       a 20-minute check that every arm starts and finishes
#
# Results: fair/results/<tag>_<part>_<arm>/chime/sweep_mt<k>/summary_<role>.csv
# and logs; fair/results/<tag>_manifest.csv lists every block's settings;
# fair/experiments/collect_lesson2.py merges it all into
# fair/results/lesson2_all.csv and lesson2_levels.csv.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${L2_TAG:=l2b}"                       # l2_ = the earlier plan's runs (other build)
: "${L2_TREE:=deep}"
: "${PARTS:=a b c d e}"
: "${L2_THREADS:=36}"                    # client threads on the compute server, everywhere
: "${L2_OPS_M:=30}"
: "${L2_WARMUP_M:=10}"
: "${MTS:=0 1 2 4 8 16}"                 # memory server threads; 0 = push off
: "${PUSH_MT:=16}"                       # the push-on point of parts b, d, e
: "${CACHES:=8 16 32 64 128 256 512 1024}"
: "${SHIP_CACHES:=64 128 256 512 1024}"  # hotspot buffer exists only above 50 MB
: "${SCAN_CACHES:=8 32 128 512}"
: "${MIX_CACHES:=32 128 512}"
: "${SHAPE_CACHES:=32 128 512}"
: "${SHAPE_FANOUTS:=14 3}"
: "${ABL_CACHES:=64 256 1024}"
: "${INNER_MAX_MB:=32}"                  # 2p: inner cache = min(this, cache / 2)
: "${ADMIT_PUSH:=0.1}"
if [ "${SMOKE:-0}" = 1 ]; then
  L2_OPS_M=3; L2_WARMUP_M=2; MTS="0 16"; CACHES="32 256"; SHIP_CACHES="256"
  SCAN_CACHES="32"; MIX_CACHES="128"; SHAPE_CACHES="128"; SHAPE_FANOUTS="14"; ABL_CACHES="256"
fi
DISTS="uniform zipf"
T="$L2_TREE"

: "${L2_LEVEL_STATS:=1}"
: "${L2_RDMA_STATS:=1}"
COMMON=("THREADS=$L2_THREADS" "OPS_M=$L2_OPS_M" "WARMUP_M=$L2_WARMUP_M" "REV_PARK_CMP_DIRS=1"
        "CHIME_HOTSPOT=0" "CHIME_PUSH_OPS=both" "LEAF_CACHE_MB=" "LEAF_ADMIT_SCAN=1.0"
        "CHIME_LEAF_BY_KEY=0" "CHIME_LEAF_OWNER=0" "CHIME_LEAF_ADMIT_PUSH=0"
        "CHIME_LEVEL_STATS=$L2_LEVEL_STATS" "CHIME_RDMA_STATS=$L2_RDMA_STATS")
wls() { local op=$1 o="" d; for d in $DISTS; do o="$o $op-$d"; done; echo "${o# }"; }
part_on() { [[ " $PARTS " == *" $1 "* ]]; }

MANIFEST=()   # "block,part,arm,leaf_pct,push_ops,scan_always,theta,workloads,caches,memthreads"
blk() {       # id part arm leaf push_ops scan_always caches memthreads workloads min [VAR=..]
  local id=$1 part=$2 arm=$3 lp=$4 po=$5 sa=$6 caches=$7 mts=$8 wl=$9 min=${10}; shift 10
  local leafset=1
  [ "$lp" = 0 ] && leafset=0
  local n; n=$(count_cells "$caches" "$mts" "$wl")
  add_block "$id" chime "$T" "$n" "CACHES=$caches" "MEMTHREADS=$mts" "WORKLOADS=$wl" \
    "${COMMON[@]}" "CHIME_LEAF_SET=$leafset" "CHIME_PUSH_OPS=$po" \
    "CHIME_SCAN_OFFLOAD_ALWAYS=$sa" "ZIPF_THETA=0.99" "$@" "@min=$min"
  MANIFEST+=("$id,$part,\"$arm\",$lp,$po,$sa,0.99,$wl,$caches,$mts")
}
SHIPPED=("CHIME_HOTSPOT=1")
# CHIME-2P at one cache size: the leaf share is absolute, so one block per size
two_p() {     # id part arm caches memthreads workloads min po sa [VAR=..]
  local id=$1 part=$2 arm=$3 cs=$4 mts=$5 wl=$6 min=$7 po=$8 sa=$9; shift 9
  local c inner lmb
  for c in $cs; do
    inner=$(( c / 2 < INNER_MAX_MB ? c / 2 : INNER_MAX_MB )); lmb=$(( c - inner ))
    blk "${id}_c$c" "$part" "$arm" "${lmb}mb" "$po" "$sa" "$c" "$mts" "$wl" "$min" \
      "LEAF_CACHE_MB=$lmb" "CHIME_LEAF_BY_KEY=1" "CHIME_LEAF_OWNER=1" \
      "CHIME_LEAF_ADMIT_PUSH=$ADMIT_PUSH" "$@"
  done
}

# ---- a: lookups, the three systems -------------------------------------------
if part_on a; then
  blk ${L2_TAG}_a_shipped a "CHIME as shipped (hotspot on)" 0 both 0 "$SHIP_CACHES" "$MTS" "$(wls point)" 2.8 "${SHIPPED[@]}"
  blk ${L2_TAG}_a_stock   a "stock CHIME (hotspot off)"     0 both 0 "$CACHES"      "$MTS" "$(wls point)" 2.6
  two_p ${L2_TAG}_a_2p    a "CHIME-2P (hot leaves by key)" "$CACHES" "$MTS" "$(wls point)" 2.6 both 0
fi

# ---- b: what each piece of CHIME-2P adds (lookups, push on) --------------------
if part_on b; then
  two_p ${L2_TAG}_b_checked b "CHIME-2P, cached leaf checked over the network" \
    "$ABL_CACHES" "$PUSH_MT" "$(wls point)" 2.6 both 0 "CHIME_LEAF_OWNER=0"
  two_p ${L2_TAG}_b_byaddr  b "CHIME-2P, leaves found by address only" \
    "$ABL_CACHES" "$PUSH_MT" "$(wls point)" 2.6 both 0 "CHIME_LEAF_BY_KEY=0"
fi

# ---- c: scans -----------------------------------------------------------------
if part_on c; then
  blk ${L2_TAG}_c_stock   c "stock CHIME, every scan pushed when push is on" 0 both 1 "$SCAN_CACHES" "$MTS" "$(wls range)" 3
  blk ${L2_TAG}_c_shipped c "CHIME as shipped (hotspot on), pull" 0 both 0 "128 512" 0 "$(wls range)" 3.5 "${SHIPPED[@]}"
fi

# ---- d: one choice per operation (50/50 lookups and scans) ---------------------
if part_on d; then
  mx="$(wls mixed)"
  blk ${L2_TAG}_d_pull    d "pull everything" 0 both   0 "$MIX_CACHES" 0          "$mx" 3.5 "MIX_SCAN_PCT=50"
  blk ${L2_TAG}_d_lookups d "push lookups"    0 lookup 0 "$MIX_CACHES" "$PUSH_MT" "$mx" 3   "MIX_SCAN_PCT=50"
  blk ${L2_TAG}_d_scans   d "push scans"      0 scan   1 "$MIX_CACHES" "$PUSH_MT" "$mx" 3   "MIX_SCAN_PCT=50"
  blk ${L2_TAG}_d_both    d "push both"       0 both   1 "$MIX_CACHES" "$PUSH_MT" "$mx" 3   "MIX_SCAN_PCT=50"
  two_p ${L2_TAG}_d_2p    d "CHIME-2P + push both" "$MIX_CACHES" "$PUSH_MT" "$mx" 3 both 1 "MIX_SCAN_PCT=50"
fi

# ---- e: tree shapes (the 6-children, 10-level tree is part a) -------------------
if part_on e; then
  for f in $SHAPE_FANOUTS; do
    fo=("CHIME_BUILD_INNER_FANOUT=$f")
    ship_cs=""; for c in $SHAPE_CACHES; do [ "$c" -gt 50 ] && ship_cs="$ship_cs $c"; done
    [ -n "$ship_cs" ] && blk ${L2_TAG}_e_f${f}_shipped e "fanout $f: CHIME as shipped" 0 both 0 "${ship_cs# }" 0 "$(wls point)" 2.8 "${SHIPPED[@]}" "${fo[@]}"
    blk ${L2_TAG}_e_f${f}_stock   e "fanout $f: stock CHIME" 0 both 0 "$SHAPE_CACHES" "0 $PUSH_MT" "$(wls point)" 2.6 "${fo[@]}"
    two_p ${L2_TAG}_e_f${f}_2p    e "fanout $f: CHIME-2P" "$SHAPE_CACHES" "$PUSH_MT" "$(wls point)" 2.6 both 0 "${fo[@]}"
  done
fi

apply_skip; show_plan

# The manifest says what every block ran; the collector joins on it.
if [ "$ROLE" = compute ] && [ "${DRY_RUN:-0}" != 1 ]; then
  mf="$FAIR/results/${L2_TAG}_manifest.csv"; mkdir -p "$FAIR/results"
  [ -f "$mf" ] || echo "block,part,arm,leaf_pct,push_ops,scan_always,theta,workloads,caches,memthreads" > "$mf"
  for m in "${MANIFEST[@]}"; do grep -q "^${m%%,*}," "$mf" || echo "$m" >> "$mf"; done
fi

[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# compute node: NIC sampler + time-stamped console copy, so nic_bandwidth.py can
# give every cell its NIC bytes per second
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="${L2_TAG}_$(date +%Y%m%d_%H%M%S)"
  NIC_CSV="$NIC_DIR/${STAMP}_nic.csv"; export TSLOG="$NIC_DIR/${STAMP}_ts.log"
  bash "$EXP_DIR/nic_sampler.sh" "$NIC_CSV" 0.5 & SAMPLER=$!
  trap 'kill $SAMPLER 2>/dev/null' EXIT
  if command -v perl >/dev/null; then
    exec > >(perl -MTime::HiRes=time -ne 'BEGIN{$|=1; open(F, ">>", $ENV{TSLOG}) or die; select((select(F), $|=1)[0])} print; printf F "%.3f %s", time, $_') 2>&1
  else
    exec > >(while IFS= read -r l; do printf '%s\n' "$l"; printf '%s %s\n' "$(date +%s.%N)" "$l" >> "$TSLOG"; done) 2>&1
  fi
fi

run_plan
if [ "$ROLE" = compute ]; then
  python3 "$EXP_DIR/nic_bandwidth.py" "$TSLOG" "$NIC_CSV" || true
  L2_TAG="$L2_TAG" python3 "$EXP_DIR/collect_lesson2.py" || true
  echo "== merged: fair/results/lesson2_all.csv and lesson2_levels.csv"
fi
