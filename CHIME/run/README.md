# CHIME two-node run: memory node vs compute node

Run CHIME's offload benchmark across your two RDMA machines and get **throughput
+ latency**, with an A/B on **offload on vs off**.

| machine | IP (default) | script | CHIME role |
|---|---|---|---|
| memory node  | `10.30.1.7` | `run_memory.sh`  | node 0 = **MN** (Directory/dir-threads; runs memcached; serves RPCs) |
| compute node | `10.30.1.6` | `run_compute.sh` | node 1 = **CN** (client; drives the workload) |

> **CHIME ≠ DART.** DART has separate `bin/memory` and `bin/compute`. CHIME runs
> the **same** `micro_test` binary on both machines; the role is decided at
> runtime by node id. Whoever registers first in **memcached** gets id 0 and,
> since `MEMORY_NODE_NUM=1`, becomes the memory node. So the two scripts run the
> identical benchmark — `run_memory.sh` just starts memcached and registers
> first. Coordination is **memcached**, not DART's TCP monitor.
>
> If `10.30.1.7`/`10.30.1.6` are swapped for you, override per run:
> `MEM_IP=10.30.1.6 CMP_IP=10.30.1.7 ./run_memory.sh` (and same on compute).

## 0. Configure the RDMA NIC (run ON each server, once, then rebuild)

CHIME picks its NIC from **4 macros in [`include/Rdma.h`](../include/Rdma.h)** —
the analogue of DART's `--nic_index` / `--ib_port` / GID:

```c
#define NET_DEV_NAME "enp202s0f0" // ethernet iface holding 10.30.1.x  (ip -br addr)
#define IB_DEV_NAME_IDX '2'       // digit of the IB dev mlx5_<X>       (ibdev2netdev)
#define MLX_PORT 1                // IB port                            (ibstat)
#define MLX_GID  1                // GID index                          (show_gids)
```

**Don't edit these by hand — run [`configure_nic.sh`](configure_nic.sh) on each
server.** It finds the interface holding `10.30.1.x` and its IB device (the same
NIC DART uses), and patches `Rdma.h` for you. `MLX_PORT`/`MLX_GID` are set to
`1`/`1` to match DART (`ib_port=1`; DART's RACE path uses GID index `1`, so it's
known-valid on your fabric):

```bash
cd ~/CHIME/run
./configure_nic.sh                 # on 10.30.1.7, then again on 10.30.1.6
# override if needed:  SUBNET=10.30.1.  PORT=1  GID=1 ./configure_nic.sh
```

Run it on **both** servers — the interface / IB-device name can differ per host,
and each patches its own copy. Then **rebuild on both** (§2). CHIME uses global
GID routing (`is_global=1`), so if a run prints `could not get gid for port ...`,
re-run with the RoCEv2 GID index for your IPv4: the script prints the `show_gids`
table; pick the row matching this server's IP and `GID=<idx> ./configure_nic.sh`.

`MEMORY_NODE_NUM 1` in [`include/Common.h`](../include/Common.h) (1 MN + 1 CN) is
already correct.

## 1. Prerequisites (both machines)

```bash
# RDMA userspace + memcached + build deps (already installed for DART/CHIME)
sudo su
echo 36864 > /proc/sys/vm/nr_hugepages     # each boot
ulimit -l unlimited
ibv_devices                                 # verbs sees the NIC
which memcached nc                          # memory node needs both
```

`sh script/installLibs.sh` installs CHIME's libs (cityhash, boost-coroutine,
tbb, libmemcached, …) if not already present.

## 2. Build (both machines, same options)

```bash
cd ~/CHIME
mkdir -p build && cd build
cmake -DENABLE_OFFLOAD=ON ..
make -j
```

Produces `build/micro_test`. `-DENABLE_OFFLOAD=ON` compiles in the RPC path;
`OFFLOAD=off` at runtime then gives the one-sided baseline in the *same* binary.
Rebuild whenever you change `Rdma.h` / `Common.h`.

## 3. Run — automatic off→on A/B

Each script runs the **full sequence by itself**: OFFLOAD **off** first, stores
those results, then OFFLOAD **on**, stores those (env `SEQUENCE`, default
`"off on"`). The two machines stay aligned because every `micro_test` round ends
on a shared `dsm->barrier("fin")`, so both exit each round together and start the
next together; the memory node resets memcached between rounds.

Same `WORKLOAD` on both machines. **Start the memory node first**, then compute
within a few seconds (the compute script waits 4 s each round to be safe):

```bash
# on 10.30.1.7 (memory)  -- start this FIRST
./run_memory.sh

# on 10.30.1.6 (compute)
./run_compute.sh
```

That's it — one command per machine gives you both the baseline and the offload
numbers. Variations:

```bash
WORKLOAD=point-zipf ./run_memory.sh     # (matching on compute)
SEQUENCE="on off"   ./run_memory.sh     # reverse order, or a subset like "on"
```

Quick smoke run: `NODES=2 THREADS=4 BULK=2 WARMUP=1 POINT_OP=2 ./run_memory.sh`
(and the same on compute).

### Where results are stored

Per sequence, on **each** machine (results are local to each host):

```
build/results/offload_ab/seq_<workload>_<timestamp>/
├── off/
│   ├── memory.log        # full micro_test output, OFFLOAD off
│   └── compute.log
├── on/
│   ├── memory.log        # OFFLOAD on
│   └── compute.log
├── summary_memory.csv    # workload,offload,role,cluster_tput_mops,p99_us,log
└── summary_compute.csv
```

The `summary_*.csv` (printed at the end too) is the quick off-vs-on comparison:
throughput from the memory node, client p99 latency from the compute node.

## 4. Knobs (env vars, defaults)

```
MEM_IP=10.30.1.7  CMP_IP=10.30.1.6  MEMC_PORT=11211  NODES=2
THREADS=24
WORKLOAD=point-uniform   # point-uniform | point-zipf | range-uniform | range-zipf
ZIPF_THETA=0.99   SCAN_RANGE=100
BULK=50 WARMUP=10 POINT_OP=50 RANGE_OP=10   # phase sizes in millions
SEQUENCE="off on"   # offload rounds to run back-to-back (order/subset)
BUILD_DIR=<repo>/build   LOG_DIR=<repo>/build/results/offload_ab
```

Four DEX-style cells: `WORKLOAD ∈ {point-uniform, point-zipf, range-uniform, range-zipf}`.

## 5. Reading the results

- **Throughput** — on the **memory node** (node 0): `epoch N: cluster throughput
  X.XXX Mops`. The memory script's SUMMARY greps these.
- **Latency** — every node prints `LATENCY BUCKETS` at `[END]`; each script's
  SUMMARY shows the `[ALL OPS] ALL` row (mean/p50/p90/p99/p99.9). The **compute
  node's** latency is the client-visible number.
- **Remote CPU load** (the offload signal) — the memory node prints `REMOTE CPU
  LOAD ... dir N: active=..%` every 2 s: high with `OFFLOAD=on`, ~idle with
  `OFFLOAD=off`. This is the metric compared head-to-head with DEX/DART.

Logs: `build/results/offload_ab/<workload>_off<rate>_<role>_<host>_<ts>.log`.

## 6. Reset / troubleshooting

- Between runs the memory script auto-restarts memcached (resets node ids). If a
  run wedges, on the memory node: `kill $(cat /tmp/memcached.pid)` and rerun.
- `connect ... memcached` on compute: memory node not up yet, or `MEM_IP`/port
  wrong, or firewall on `11211`. Start memory first; `nc -z 10.30.1.7 11211`.
- Both nodes hang at init: `NODES`/`MEMORY_NODE_NUM` mismatch, or one node's
  `NET_DEV_NAME`/IB config in `Rdma.h` is wrong → RDMA connect fails.
- CRLF line endings (edited on Windows): `dos2unix run/*.sh`.

### Note on MN purity vs DART

In `micro_test`, node 0 (the MN) **also runs `THREADS` client threads**, so it's
a co-located CN+MN, not a pure passive MN like DART's memory node. The `REMOTE
CPU LOAD` (dir-thread active %) is still measured correctly, but the MN box's
overall CPU includes client work. For a stricter DART-style split, run the MN
with fewer/no client threads (needs a small `micro_test` guard to skip
`thread_run` on `getMyNodeID() < MEMORY_NODE_NUM`) — ask and I'll add it.
