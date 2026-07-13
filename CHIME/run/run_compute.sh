#!/bin/bash
# ===========================================================================
# run_compute.sh  --  run this ON THE COMPUTE NODE (default 10.30.1.6)
#
# Launches the SAME test/micro_test binary. It dials memcached on the memory
# node, registers second, gets CHIME node id 1 and acts as the COMPUTE NODE
# (client): it drives the workload over one-sided RDMA (OFFLOAD=off) or via
# lookup/scan RPC pushdowns to the MN (OFFLOAD=on), and prints its own latency.
#
# Runs the full DEX/DART-style matrix (point/range x uniform/zipf-0.99 x
# off/on, 50M ops each) in lockstep with the memory node -- both processes end
# each round on a shared barrier, so they stay aligned across all 8 rounds.
# Stores its latency results under
#   build/results/offload_ab/sweep_<ts>/<workload>/<off|on>/compute.log
#
# Start run_memory.sh FIRST, then this within a few seconds.
#
#   ./run_compute.sh
#   WORKLOADS="point-uniform range-uniform" ./run_compute.sh   # subset
#
# Must use the SAME WORKLOADS + SEQUENCE as run_memory.sh (they run in lockstep).
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence compute
