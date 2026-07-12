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
# Runs the full A/B SEQUENCE automatically: OFFLOAD off first, then on (env
# SEQUENCE, default "off on"). Each round resets memcached and stores its
# results under build/results/offload_ab/seq_<workload>_<ts>/{off,on}/.
#
# Start THIS first, then run_compute.sh on the compute node.
#
#   ./run_memory.sh                        # off then on, point-uniform
#   WORKLOAD=point-zipf ./run_memory.sh    # different workload
#   SEQUENCE="on off"   ./run_memory.sh    # change order / subset
#
# Must use the SAME WORKLOAD + SEQUENCE as run_compute.sh.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence memory
