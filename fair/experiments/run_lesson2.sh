#!/bin/bash
# ===========================================================================
# run_lesson2.sh <memory|compute> -- every CHIME-2P run behind Lesson 2:
#   "Pushing and pulling should be selected by operation and index level."
#
# Five parts. Every part runs push OFF (0 memory threads) and push ON, for
# uniform AND Zipf keys, so each result has its pull and push side:
#
#   e1  where should a fixed cache go, inner nodes or leaves?      (lookups)
#       total cache x leaf share {0,25,50,75%} x push {off,on} x {uniform,zipf}
#   e2  how should a scan run?                                       (scans)
#       stock pull (one read per leaf) | batched pull, no leaf reuse |
#       batched pull + leaf cache  || push on a miss + leaf cache | push always
#   e3  one choice for every operation, or one per operation?   (50/50 mix)
#       pull all | push lookups only | push scans only | push both
#   e4  the headline: stock CHIME against CHIME-2P, every cache x threads
#       stock CHIME (inner nodes only) and CHIME-2P (leaf cache), each with
#       0 (push off), 1, 2, 4, 8 and 16 memory server threads, plus stock CHIME
#       as shipped (hotspot buffer on, push off); lookups and scans, uniform and Zipf
#   e6  the leaf cache against CHIME as shipped (hotspot buffer on), lookups:
#       leaf share {0,50%} x push {off,on} x cache {128..1024} x {uniform,zipf}
#       (run after the rest: PARTS=e6)
#   e5  how much skew does a leaf cache need?                (Zipf lookups)
#       theta {0.5,0.8,1.2} (0.99 is in e1) x leaf share {0,50%} x push {off,on}
#
# Same tree, clients and run length everywhere, so every part can be read
# against every other: TREE_SETUP=deep (bulk built, 10 levels, 1.25M inner
# nodes, about 162 MB of them in CHIME's cache), 36 clients, 50M keys, 10M
# warmup + 30M measured ops, scans of 100 keys, hotspot buffer off
# (CHIME_HOTSPOT=0, so the cache budget is exactly inner + leaf).
# The cache budget is ONE total: with the leaf cache on, LEAF_CACHE_PCT of it
# holds leaves and the rest inner nodes. Leaf caching never gets extra memory.
#
# What every cell records (the collector puts all of it in one row per cell):
#   throughput, latency mean/p50/p90/p99/p99.9                    (compute log)
#   [RDMA]   round trips, reads, writes, atomics, pushed requests and bytes per
#            operation, measured phase only               (CHIME_RDMA_STATS=1)
#   [LEVEL]  hits and misses per tree level, lookups (level 0 = leaf)
#   [KIND]   inner nodes against leaves, lookups           (CHIME_LEVEL_STATS=1)
#   [SCANLEAF] scan leaves served from the leaf cache and read; inner misses
#   [READPATH] index-cache hit rate and leaf round trips per lookup
#   OFFLOADED TASKS  lookups and scans pushed, leaves walked per pushed scan
#   memory server CPU: busy cores of the push threads    (memory log, server 8)
#   leaf cache split, hit rate, fill; tree shape; correctness lines
#   NIC bytes per second on the compute node, per cell     (nic sampler)
# L2_LEVEL_STATS=0 / L2_RDMA_STATS=0 turn the counters off.
#
# Needs the CHIME build with CHIME_PUSH_OPS, CHIME_LEVEL_STATS and
# CHIME_RDMA_STATS, and the mixed workloads (CHIME/run/bench_common.sh), on BOTH
# servers, from ~/REV:
#   git pull --no-rebase --no-edit
#   RUN_ID=chime_build TREE_SETUP=deep ./fair/build.sh chime
#   strings CHIME/build_fair/micro_test | grep -c "CHIME_PUSH_OPS\|CHIME_LEVEL_STATS\|CHIME_RDMA_STATS"   # >= 3
#
# Run (memory first, same variables on both, one terminal each, no tmux):
#   server 8:  cd ~/REV && bash fair/experiments/run_lesson2.sh memory  2>&1 | tee ~/l2_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_lesson2.sh compute 2>&1 | tee ~/l2_compute.out
#
# Useful variables (set the SAME on both servers):
#   PARTS="e1 e2 e3"     run only some parts (default: all five)
#   DRY_RUN=1            print the plan and the time estimate, run nothing
#   SKIP_TO=<block>      resume from a block after a failure
#   E4_LEAF_PCT / E4_SCAN_ALWAYS   CHIME-2P's leaf share and scan rule in e4;
#                        set them from e1 and e2 if you run e4 in a second pass
#   L2_TAG=l2smoke       block-name prefix; a smoke test with another tag never
#                        mixes with the real results (the collector reads l2_*)
#   PUSH_MTS="16"        memory server threads for push ON in e1, e2, e3, e5, e6
#                        (e4 always sweeps 1 2 4 8 16); "1 2 4 8 16" widens them
#
# After the run, push the logs of BOTH servers (the memory server's logs hold the
# CPU numbers); the collector reads memory logs next to the compute logs.
#
# Results: fair/results/l2_<part>_<arm>/chime/sweep_mt<k>/summary_<role>.csv
# and logs; fair/results/l2_manifest.csv lists every block's settings;
# fair/experiments/collect_lesson2.py merges it all into
# fair/results/lesson2_all.csv.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${L2_TAG:=l2}"                       # block-name prefix; a smoke test uses another
: "${L2_TREE:=deep}"
: "${PARTS:=e1 e2 e3 e4 e5}"
: "${L2_THREADS:=36}"                    # clients, as in Lesson 1
: "${L2_OPS_M:=30}"
: "${PUSH_MTS:=16}"                       # push ON threads in e1, e2, e3, e5
: "${E1_CACHES:=64 128 256 512 1024}"     # inner nodes ~162 MB: 64/128 never fit
: "${E1_PCTS:=25 50 75}"                  # leaf shares besides 0
: "${E2_CACHES:=32 128 512}"
: "${E3_CACHES:=32 128 512}"
: "${E3_SCAN_PCT:=50}"
: "${E4_CACHES:=16 32 64 128 256 512 1024}"
: "${E4_MEMTHREADS:=0 1 2 4 8 16}"         # 0 = push off
: "${E4_LEAF_PCT:=50}"
: "${E4_SCAN_ALWAYS:=1}"
: "${E5_CACHES:=64 256}"
: "${E5_THETAS:=0.5 0.8 1.2}"
: "${E6_CACHES:=128 256 512 1024}"
DISTS="uniform zipf"
T="$L2_TREE"

: "${L2_LEVEL_STATS:=1}"                  # per-level / inner vs leaf hit counts in every cell
: "${L2_RDMA_STATS:=1}"                   # RDMA verbs, round trips and bytes per operation
COMMON=("THREADS=$L2_THREADS" "OPS_M=$L2_OPS_M" "WARMUP_M=10" "REV_PARK_CMP_DIRS=1"
        "CHIME_HOTSPOT=0" "CHIME_PUSH_OPS=both" "LEAF_CACHE_MB=" "LEAF_ADMIT_SCAN=1.0"
        "CHIME_LEVEL_STATS=$L2_LEVEL_STATS" "CHIME_RDMA_STATS=$L2_RDMA_STATS")
wls() { local op=$1 o="" d; for d in $DISTS; do o="$o $op-$d"; done; echo "${o# }"; }

part_on() { [[ " $PARTS " == *" $1 "* ]]; }
MANIFEST=()   # "block,part,arm,leaf_pct,push,push_ops,scan_always,theta,workloads,caches,memthreads"
blk() {       # id part arm leaf_pct push_ops scan_always theta caches memthreads workloads min [VAR=..]
  local id=$1 part=$2 arm=$3 lp=$4 po=$5 sa=$6 th=$7 caches=$8 mts=$9 wl=${10} min=${11}; shift 11
  local leafset=0 leafenv=()
  case "$lp" in
    0)   leafset=0 ;;
    1mb) leafset=1; leafenv=("LEAF_CACHE_MB=1" "LEAF_ADMIT_SCAN=0") ;;   # batched path, nothing kept
    *)   leafset=1; leafenv=("LEAF_CACHE_PCT=$lp") ;;
  esac
  local n; n=$(count_cells "$caches" "$mts" "$wl")
  add_block "$id" chime "$T" "$n" "CACHES=$caches" "MEMTHREADS=$mts" "WORKLOADS=$wl" \
    "${COMMON[@]}" "CHIME_LEAF_SET=$leafset" ${leafenv[@]+"${leafenv[@]}"} \
    "CHIME_PUSH_OPS=$po" "CHIME_SCAN_OFFLOAD_ALWAYS=$sa" "ZIPF_THETA=$th" "$@" "@min=$min"
  MANIFEST+=("$id,$part,\"$arm\",$lp,$po,$sa,$th,$wl,$caches,$mts")
}

# ---- e1: inner nodes or leaves, for lookups ---------------------------------
if part_on e1; then
  blk ${L2_TAG}_e1_leaf0 e1 "leaf 0%" 0 both 0 0.99 "$E1_CACHES" "0 $PUSH_MTS" "$(wls point)" 2.6
  for p in $E1_PCTS; do
    blk "${L2_TAG}_e1_leaf$p" e1 "leaf $p%" "$p" both 0 0.99 "$E1_CACHES" "0 $PUSH_MTS" "$(wls point)" 2.6
  done
fi

# ---- e2: how a scan should run ------------------------------------------------
if part_on e2; then
  blk ${L2_TAG}_e2_stock    e2 "pull, one read per leaf"      0   both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 4
  blk ${L2_TAG}_e2_batch    e2 "pull, batched, no leaf reuse" 1mb both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 3.5
  blk ${L2_TAG}_e2_leaf     e2 "pull, batched + leaf cache"   50  both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 3.5
  blk ${L2_TAG}_e2_pushmiss e2 "push on a miss + leaf cache"  50  both 0 0.99 "$E2_CACHES" "$PUSH_MTS" "$(wls range)" 3
  blk ${L2_TAG}_e2_pushall  e2 "push every scan"              0   both 1 0.99 "$E2_CACHES" "$PUSH_MTS" "$(wls range)" 3
fi

# ---- e3: one choice per operation, 50/50 lookups and scans --------------------
if part_on e3; then
  mx="$(wls mixed)"
  blk ${L2_TAG}_e3_pull    e3 "pull everything"     0 both   0 0.99 "$E3_CACHES" 0          "$mx" 3.5 "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_lookups e3 "push lookups only"   0 lookup 0 0.99 "$E3_CACHES" "$PUSH_MTS" "$mx" 3.5 "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_scans   e3 "push scans only"     0 scan   1 0.99 "$E3_CACHES" "$PUSH_MTS" "$mx" 3   "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_both    e3 "push both"           0 both   1 0.99 "$E3_CACHES" "$PUSH_MTS" "$mx" 3   "MIX_SCAN_PCT=$E3_SCAN_PCT"
fi

# ---- e4: stock CHIME against CHIME-2P, the whole sweep ------------------------
if part_on e4; then
  all="$(wls point) $(wls range)"
  # stock CHIME: inner nodes only; with threads it pushes on a miss by its own rule
  blk ${L2_TAG}_e4_stock    e4 "stock CHIME (inner nodes only)" 0              both 0                 0.99 "$E4_CACHES" "$E4_MEMTHREADS" "$all" 2.9
  # CHIME-2P: the same budget split with the leaf cache; 0 threads = leaf cache, pull only
  blk ${L2_TAG}_e4_2p       e4 "CHIME-2P (leaf cache)"         "$E4_LEAF_PCT" both "$E4_SCAN_ALWAYS" 0.99 "$E4_CACHES" "$E4_MEMTHREADS" "$all" 2.9
  # stock CHIME as shipped: hotspot buffer on (it takes 30 MB of any cache above 50 MB)
  blk ${L2_TAG}_e4_shipped  e4 "stock CHIME as shipped (hotspot on)" 0         both 0                 0.99 "$E4_CACHES" 0                "$all" 3 "CHIME_HOTSPOT=1"
fi

# ---- e5: skew a leaf cache needs ------------------------------------------------
if part_on e5; then
  for th in $E5_THETAS; do
    tag="t$(echo "$th" | tr -d .)"
    for p in 0 50; do
      blk "${L2_TAG}_e5_${tag}_leaf$p" e5 "theta $th, leaf $p%" "$p" both 0 "$th" "$E5_CACHES" "0 $PUSH_MTS" point-zipf 2.6
    done
  done
fi

# ---- e6: the leaf cache against CHIME as shipped (hotspot buffer on) -----------
# The same split as e1, but with CHIME's hotspot buffer and speculative read ON in
# both arms, as in the August leaf-cache study (+40% for Zipf lookups there). With
# the buffer on, a lookup costs about 11 us instead of 5 at the same one round trip
# (buffer upkeep, and the buffer takes 30 MB of any cache above 50 MB). This tells
# whether a cached leaf pays against that slower baseline on this tree.
if part_on e6; then
  for p in 0 50; do
    blk "${L2_TAG}_e6_hot_leaf$p" e6 "hotspot on, leaf $p%" "$p" both 0 0.99 "$E6_CACHES" "0 $PUSH_MTS" "$(wls point)" 2.8 "CHIME_HOTSPOT=1"
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

# compute node: NIC sampler + time-stamped console copy (as in run_dxt_sweep.sh),
# so nic_bandwidth.py can give every cell its NIC bytes per second
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
  python3 "$EXP_DIR/collect_lesson2.py" || true
  echo "== merged: fair/results/lesson2_all.csv and lesson2_levels.csv"
fi
