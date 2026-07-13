#!/bin/bash
# ===========================================================================
# run_memory.sh  --  run this ON THE MEMORY NODE (default 10.30.1.8)
#
# Restarts memcached locally, then launches test/micro_test. Because it
# registers first, this machine gets CHIME node id 0 and (MEMORY_NODE_NUM=1)
# becomes the MEMORY NODE: it starts the Directory / dir-threads and, with
# OFFLOAD=on, serves lookup/scan RPCs -- printing "REMOTE CPU LOAD ... active=%".
# Node 0 also prints the per-epoch CLUSTER THROUGHPUT.
#
# Runs the full DEX/DART-style matrix automatically:
#   WORKLOADS = point-uniform, point-zipf(0.99), range-uniform, range-zipf(0.99)
#   x OFFLOAD = off then on          (4 cells x 2 = 8 rounds), 50M ops each.
# Each round resets memcached and stores results under
#   build/results/offload_ab/sweep_<ts>/<workload>/<off|on>/memory.log
#
# Start THIS first, then run_compute.sh on the compute node.
#
#   ./run_memory.sh                                   # full matrix
#   WORKLOADS="point-uniform range-uniform" ./run_memory.sh   # subset
#   SEQUENCE=on ./run_memory.sh                       # offload-only
#
# Must use the SAME WORKLOADS + SEQUENCE as run_compute.sh (they run in lockstep).
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence memory
