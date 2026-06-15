#!/usr/bin/env bash
#
# cache_sweep_baseline_other.sh — MEMORY side of the baseline DART cache sweep.
#                                 >>> RUN THIS ON THE MEMORY HOST: 10.30.1.6 <<<
#
# Companion to cache_sweep_baseline.sh (which runs on the compute host 10.30.1.8
# and owns the monitor + all workload flags). This script just relaunches the
# one-shot memory node once per configuration, in lockstep with the compute side.
#
#     10.30.1.8  ->  monitor + compute   ::  ./script/cache_sweep_baseline.sh
#     10.30.1.6  ->  memory              ::  ./script/cache_sweep_baseline_other.sh  (THIS)
#
# bin/memory is one-shot: it dials the monitor on 10.30.1.8, connects its RDMA
# QPs, runs ONE configuration, then exits when the monitor broadcasts end (999).
# This loop relaunches it for every configuration. Between configs the compute
# side tears the monitor down and brings up a fresh one; while the monitor is
# absent, bin/memory exits immediately with "connect to monitor error", so we
# RETRY until it connects. That makes start order across hosts irrelevant.
#
# HOW TO RUN (either order works; the monitor barrier syncs them):
#   1. on 10.30.1.6:  ./script/cache_sweep_baseline_other.sh   (THIS — can start first)
#   2. on 10.30.1.8:  ./script/cache_sweep_baseline.sh
#
# PREREQS:
#   * Build on this host (same path as 10.30.1.8): ./build.sh  (binaries in ./bin)
#   * Hugepages: sudo sysctl -w vm.nr_hugepages=16384
#   * Set MEM_NIC to this host's RDMA device index (see `ibv_devices`).
#
#   *** IMPORTANT: keep CACHE_TOTAL_MB / DISTS / OPS IDENTICAL to the compute
#       script *** so the iteration count matches and the loops stay in lockstep.
#
set -u

# ----------------------------- cluster config ------------------------------
MONITOR_DIAL="10.30.1.8:9898"   # the monitor lives on the compute host

MEM_NIC=0                       # memory-host (10.30.1.6) RDMA device index
IB_PORT=1

# Repo dir (this script lives in <repo>/script/).
DART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------- iteration count -------------------------------
# Memory does NOT take any workload/sizing flags — the monitor owns those. This
# side only needs to relaunch bin/memory the SAME number of times the compute
# side iterates. KEEP THESE ARRAYS IDENTICAL to cache_sweep_baseline.sh.
CACHE_TOTAL_MB=(64 128 256 512)
DISTS=(uniform zipf99)
OPS=(lookup scan)
NUM_CONFIGS=$(( ${#CACHE_TOTAL_MB[@]} * ${#DISTS[@]} * ${#OPS[@]} ))   # = 16

# How long (in 1s retry attempts) to wait for the monitor between/at configs
# before giving up on a configuration. Generous: covers the compute-side gap and
# a late start. A genuine, persistent RDMA error trips this instead of looping forever.
MAX_RETRY=600

STAMP="$(date +%Y%m%d_%H%M%S)"
LOGDIR="$DART_DIR/sweep_logs_baseline_memory_${STAMP}"
mkdir -p "$LOGDIR"

teardown() { killall -9 memory 2>/dev/null; }

echo "BASELINE DART cache sweep (MEMORY side, 10.30.1.6): $NUM_CONFIGS configs"
echo "dialing monitor at $MONITOR_DIAL  (logs in $LOGDIR)"
echo ">>> Make sure cache_sweep_baseline.sh is (or will be) running on 10.30.1.8 <<<"

teardown
sleep 1

for (( i = 1; i <= NUM_CONFIGS; ++i )); do
    echo "================================================================"
    echo ">>> memory: configuration $i / $NUM_CONFIGS"
    echo "================================================================"

    attempt=0
    while :; do
        attempt=$(( attempt + 1 ))
        mlog="$LOGDIR/memory_config${i}_try${attempt}.log"

        # one-shot: connect, run one config, exit on monitor's end(999)
        "$DART_DIR/bin/memory" \
            --monitor_addr="$MONITOR_DIAL" --nic_index=$MEM_NIC --ib_port=$IB_PORT \
            > "$mlog" 2>&1

        if grep -q "ready\." "$mlog"; then
            echo "    -> config $i completed (log: $mlog)"
            break          # connected + ran a full configuration
        fi

        # Did not reach "ready": monitor not up yet (inter-config gap / late start),
        # or an RDMA error. Wait and retry.
        if [ "$attempt" -ge "$MAX_RETRY" ]; then
            echo "    !! config $i: monitor never reachable / repeated failure after" \
                 "$attempt attempts. Last log: $mlog" >&2
            echo "    !! Check the compute host (10.30.1.8) and RDMA setup, then rerun." >&2
            teardown
            exit 1
        fi
        sleep 1
    done

    teardown               # ensure the one-shot is gone before the next config
    sleep 1
done

echo
echo "Memory side done: served $NUM_CONFIGS configurations. Results CSV is on 10.30.1.8."
