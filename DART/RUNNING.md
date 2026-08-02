# Running DART — execution & cache-sweep guide

A complete, step-by-step guide to building DART, configuring the RDMA NICs
(device index, IB port, GID, TCP ports), running a single in-memory microbench,
and running the full **directory-cache sweep** across two servers.

> **DART has no memcached.** Coordination is done by a TCP `monitor` process. The
> monitor/memory/compute binaries are *one-shot*: they connect, run once, report,
> and exit. "Restarting between configurations" simply means relaunching them —
> which [`script/cache_sweep.sh`](script/cache_sweep.sh) does for you.

---

## Table of contents

1. [Cluster topology](#1-cluster-topology)
2. [Prerequisites](#2-prerequisites)
3. [Build (on both servers)](#3-build-on-both-servers)
4. [Find your RDMA NIC, port, and GID](#4-find-your-rdma-nic-port-and-gid)
5. [Configure NIC index / IB port / GID / TCP ports](#5-configure-nic-index--ib-port--gid--tcp-ports)
6. [Configure the cluster IPs](#6-configure-the-cluster-ips)
7. [Run a single microbench (manual)](#7-run-a-single-microbench-manual)
8. [Run the full cache sweep](#8-run-the-full-cache-sweep)
9. [Read the results](#9-read-the-results)
10. [Troubleshooting](#10-troubleshooting)
11. [Command reference](#11-command-reference)

---

## 1. Cluster topology

Two servers, each with an RDMA NIC:

| server      | roles                                | notes |
|-------------|--------------------------------------|-------|
| `10.30.1.6` | `monitor` + `memory` (memory node 0) | run the sweep script **here** |
| `10.30.1.7` | `compute` (compute node 0)           | launched by the script over SSH |

Two independent TCP control channels are used at startup (RDMA data itself is
one-sided after setup):

- **`9898`** — the monitor's rendezvous/barrier port (`--monitor_addr`).
- **`10001`** — the RACE skip-table's QP-exchange port (compute → memory).

---

## 2. Prerequisites

On **both** servers:

```bash
# RDMA userspace + verbs tools (Debian/Ubuntu names; adjust for your distro)
sudo apt install -y libibverbs1 ibverbs-utils librdmacm1 rdma-core \
                    libboost-context-dev libboost-coroutine-dev \
                    cmake g++ git

# Confirm the verbs stack sees your NIC (should print at least one device)
ibv_devices
```

You also need:

- **Passwordless SSH** from `10.30.1.6` to `10.30.1.7` (the sweep script SSHes in
  to launch `compute`). Test: `ssh 10.30.1.7 hostname`.
- The repo checked out at the **same absolute path** on both servers (the script
  does `cd "$DART_DIR"` remotely, where `$DART_DIR` is derived from its own
  location on the local host).
- Hugepages reserved on both (RDMA buffers are pinned in hugepages):

  ```bash
  sudo sysctl -w vm.nr_hugepages=16384      # 16384 * 2 MiB = 32 GiB
  grep -i hugepages /proc/meminfo           # verify HugePages_Total
  ```

  Rule of thumb: hugepages must comfortably exceed `--mem_mb` on the memory node
  and the compute node's buffers (RACE temp pool + per-thread cache + records).

---

## 3. Build (on both servers)

```bash
git submodule update --init --recursive    # pulls gflags + magic_enum
./build.sh                                  # cmake -B build && cmake --build build
# or, for a clean rebuild + submodules + hugepage hint:
./init-build.sh
```

Binaries land in **`bin/`**: `bin/monitor`, `bin/memory`, `bin/compute`.

> If you edit any `src/main/*.cc` or `include/**` (e.g. to change the RACE port or
> the `ips[]` list — see §5/§6) you must **rebuild on the affected host**.

---

## 4. Find your RDMA NIC, port, and GID

The two knobs that vary per machine are the **device index** (`--nic_index`) and
the **IB port** (`--ib_port`); on RoCE (RDMA over Ethernet) you may also need a
**GID index**. Discover them:

```bash
# 1) List RDMA devices. nic_index is the 0-based position in this list.
ibv_devices
#   device                 node GUID
#   mlx5_0            248a0703...     <- nic_index 0
#   mlx5_1            248a0703...     <- nic_index 1

# 2) Which RDMA device maps to which Ethernet/IP (so you pick the one on 10.30.1.x)
ibdev2netdev
#   mlx5_0 port 1 ==> enp1s0f0 (Up)

# 3) Port state + link layer (InfiniBand vs Ethernet=RoCE) + which port number
ibstat
ibstat mlx5_0          # look for "State: Active", "Physical state: LinkUp",
                       # "Link layer: Ethernet" (RoCE) or "InfiniBand", and the Port #

# 4) RoCE only: list GID indices -> pick the one matching your IPv4 + RoCEv2
show_gids              # Mellanox helper; otherwise: ibv_devinfo -v | grep -i gid
#   DEV    PORT  INDEX  GID                     IPv4         VER
#   mlx5_0 1     3      ::ffff:10.30.1.6        10.30.1.6    v2    <- gid_idx 3
```

Write down, per server: the **nic_index**, the **IB port** (usually `1`), the
**link layer**, and (if RoCE) the **gid_idx** whose IPv4 matches that server.

---

## 5. Configure NIC index / IB port / GID / TCP ports

DART has **two** RDMA stacks, configured separately. Most setups only need to set
the two flags in §5.1; the source edits in §5.2–§5.4 are only if your port isn't
`1`, you're on RoCE, or a TCP port is taken.

### 5.1 NIC index & IB port — command-line flags (no rebuild)

The **main RDMA path** reads these from flags. Pass them to `memory` and
`compute` (defaults differ — `memory` defaults `nic_index=1`, `compute` defaults
`0` — so always set them explicitly):

```bash
bin/memory  --monitor_addr=10.30.1.6:9898 --nic_index=<MEM_NIC> --ib_port=<PORT>
bin/compute --monitor_addr=10.30.1.6:9898 --nic_index=<CMP_NIC> --ib_port=<PORT>
```

In the sweep script, set these at the top:

```bash
MEM_NIC=0     # memory host RDMA device index (ibv_devices)
CMP_NIC=0     # compute host RDMA device index
IB_PORT=1     # physical IB port on the card
```

### 5.2 IB port for the RACE skip-table — source edit (rebuild required)

The RACE skip-table layer (used for the shortcut index) **hard-codes IB port = 1
and GID index = 1**. The `--ib_port` flag does **not** reach it. If your port is
not `1`, edit both sides and rebuild:

- **Compute (client)** — [`src/main/compute.cc`](src/main/compute.cc) (~line 650):
  ```cpp
  RACE::rdma_dev dev(FLAGS_nic_index, 1, 1);
  //                               ^ib_port  ^gid_idx   <- change the first 1
  ```
- **Memory (server)** — [`src/race/race.cc`](src/race/race.cc) (~line 59):
  ```cpp
  Server::Server(int dev_index, Config &config) : dev(dev_index, 1, 1), ser(dev)
  //                                                            ^ib_port ^gid_idx
  ```

### 5.3 GID index (RoCE) — source edit (rebuild required)

- **RACE path:** set the 3rd argument (`gid_idx`) in the two `dev(...)` calls
  above to the `gid_idx` you found in §4 step 4.
- **Main path:** the main RDMA region is created with **GID disabled** (`gid_idx
  = -1`, i.e. LID/InfiniBand addressing). On RoCE you must pass a real GID index.
  Edit the two `create(...)` calls to add it:
  - [`src/main/compute.cc`](src/main/compute.cc) (~line 741):
    ```cpp
    result = mrs[i].create(thread_size_byte, FLAGS_nic_index, FLAGS_ib_port, <GID_IDX>);
    ```
  - [`src/main/memory.cc`](src/main/memory.cc) (~line 78):
    ```cpp
    result = mr.create(memory_size_mb * 1_MiB, FLAGS_nic_index, FLAGS_ib_port, <GID_IDX>);
    ```
  (`RDMAMemoryRegion::create(size, ib_dev, ib_port, gid_idx = -1)` already accepts
  the 4th parameter — see [`include/rdma/rdma-connection.hpp`](include/rdma/rdma-connection.hpp).)

> Pure-InfiniBand fabrics: leave the main path at `-1` (LID mode) and RACE at the
> default GID — no edit needed.

### 5.4 TCP ports — if `9898` or `10001` is taken

- **Monitor port `9898`:** change it everywhere via the flag, no rebuild. Use the
  same value on all three binaries (monitor binds `0.0.0.0:<port>`; memory/compute
  dial `10.30.1.6:<port>`). In the sweep script edit `MONITOR_BIND` / `MONITOR_DIAL`.
- **RACE port `10001`:** edit [`include/race/aiordma.h`](include/race/aiordma.h)
  (~line 31) `const int rdma_default_port = 10001;` and rebuild **both** hosts.

---

## 6. Configure the cluster IPs

Two places encode "which machine is which":

1. **`--monitor_addr`** — already wired into the commands/script
   (`0.0.0.0:9898` to bind on the monitor host; `10.30.1.6:9898` to dial).
2. **`ips[]`** in [`src/main/compute.cc`](src/main/compute.cc) (~line 33) — the
   **memory-node IPs** the RACE client dials on port `10001`. Already set:
   ```cpp
   const char* ips[] = {"10.30.1.6", "10.30.1.7"};  // ips[0] = memory node 0
   ```
   For 1 memory node only `ips[0]` is used. **If you change this, rebuild `compute`.**

---

## 7. Run a single microbench (manual)

Useful to validate the cluster before launching the 24-run sweep. The in-memory
microbench (`--test_func=1`) generates the working set at startup, so the op-mix,
distribution, and size are all flags — no YCSB files needed.

Start the three processes **in this order** (monitor first; it blocks until all
nodes connect). Example: 30M 100% point lookups, zipfian-0.99, 256 MB total cache
over 56 threads (`--th_b = 256·1MiB/56 ≈ 4793490`):

```bash
# --- on 10.30.1.6, terminal 1: monitor (owns all workload/sizing flags) ---
bin/monitor \
  --monitor_addr=0.0.0.0:9898 \
  --memory_num=1 --compute_num=1 \
  --load_thread_num=56 --run_thread_num=56 --coro_num=1 \
  --mem_mb=8192 --th_b=4793490 \
  --test_func=1 --bucket=256 \
  --run_max_request=30000000 --payload_byte=16 \
  --mb_read_pct=100 --mb_scan_pct=0 \
  --mb_insert_pct=0 --mb_update_pct=0 --mb_remove_pct=0 \
  --mb_uniform=0 --mb_theta_x100=99 \
  --mb_key_count=30000000 --mb_scan_len=100

# --- on 10.30.1.6, terminal 2: memory node ---
bin/memory  --monitor_addr=10.30.1.6:9898 --nic_index=0 --ib_port=1

# --- on 10.30.1.7: compute node ---
bin/compute --monitor_addr=10.30.1.6:9898 --nic_index=0 --ib_port=1 \
            --numa_node_total_num=2 --numa_node_group=0
```

The monitor prints, at the end:

```
Total throughput = <X> MOps
Average latency  = <Y> us
```

**100% range scans:** swap `--mb_read_pct=0 --mb_scan_pct=100`.
**Uniform instead of zipfian:** `--mb_uniform=1` (theta is then ignored).

### Microbench flag reference

| flag | meaning |
|------|---------|
| `--test_func` | `0` = YCSB workload files, `1` = in-memory microbench |
| `--mb_read_pct` / `--mb_insert_pct` / `--mb_update_pct` / `--mb_scan_pct` / `--mb_remove_pct` | op mix, **must sum to 100** |
| `--mb_uniform` | `1` = uniform keys, `0` = zipfian |
| `--mb_theta_x100` | zipf θ × 100 (`99` ⇒ 0.99); ignored if uniform |
| `--mb_key_count` | distinct keys = working-set size |
| `--mb_scan_len` | keys returned per range scan |
| `--run_max_request` | measured op count (= op_count) |
| `--payload_byte` | value length for insert/update |
| `--th_b` / `--th_kb` / `--th_mb` | **per-thread** compute cache (the "directory cache") |
| `--mem_mb` | memory-node RDMA region (the disaggregated heap) |
| `--load_thread_num` / `--run_thread_num` | worker threads (pinned to `tid*numa_total + numa_group`) |
| `--bucket` | RACE hash-bucket count |

---

## 8. Run the full cache sweep

[`script/cache_sweep.sh`](script/cache_sweep.sh) runs the matrix:

```
cache ∈ {32, 64, 128, 256, 512, 1024} MiB   (TOTAL; --th_b = size·1MiB / threads)
   ×  distribution ∈ {uniform, zipf-0.99}
   ×  op mix ∈ {100% lookup, 100% scan}
   =  24 runs, 30M ops each
```

It relaunches monitor+memory (local) and compute (over SSH) **fresh for each
configuration** — the "restart between tests" — kills stragglers between runs,
parses each monitor log, and appends a row to a CSV.

### 8.1 Configure (edit the top of the script)

```bash
MONITOR_BIND="0.0.0.0:9898"     # monitor binds here (this host)
MONITOR_DIAL="10.30.1.6:9898"   # memory/compute dial this
COMPUTE_HOST="10.30.1.7"        # SSH target for compute ("" = run compute locally)
SSH="ssh"

MEM_NIC=0; CMP_NIC=0; IB_PORT=1 # from §4 (per server)

THREADS=56                      # load_thread_num == run_thread_num
MEM_MB=8192                     # memory-node region
BUCKET=256
KEY_COUNT=30000000              # working set
OP_COUNT=30000000               # 30M measured ops
VALUE_LEN=16
SCAN_LEN=100

CACHE_TOTAL_MB=(32 64 128 256 512 1024)
DISTS=(uniform zipf99)
OPS=(lookup scan)
```

### 8.2 Run

```bash
# on 10.30.1.6
./script/cache_sweep.sh
```

Outputs (next to the repo root):

- `cache_sweep_<timestamp>.csv` — one row per configuration.
- `sweep_logs_<timestamp>/` — full `monitor_*.log`, `memory_*.log`,
  `compute_*.log` for every run (your audit trail / for debugging a failed run).

### 8.3 Single-machine smoke test

To dry-run the plumbing on one box (no second server), set `COMPUTE_HOST=""` —
the script then launches `compute` locally instead of over SSH. (Real numbers
need the two-server RDMA fabric.)

---

## 9. Read the results

`cache_sweep_<timestamp>.csv` columns:

| column | meaning |
|--------|---------|
| `dist` | `uniform` or `zipf99` |
| `op` | `lookup` (100% point read) or `scan` (100% range scan) |
| `cache_total_mb` | the sweep point (total compute cache) |
| `th_bytes_per_thread` | what was actually passed (`cache·1MiB / threads`) |
| `threads` | worker threads |
| `key_count` / `op_count` | working set / measured ops |
| `throughput_mops` | **headline**: total throughput in M ops/s (summed over compute nodes) |
| `latency_us` | average op latency in microseconds |

Expected shape: throughput **rises with cache size** (more of the working set /
inner path stays local, fewer RDMA round trips), and the effect is **stronger
under zipfian** (hot keys fit in a small cache) than uniform. Scans are heavier
per op than lookups, so their throughput is lower and more cache-sensitive.

---

## 10. Troubleshooting

| symptom | likely cause / fix |
|---------|--------------------|
| `connect to monitor error` | monitor not up yet, wrong `--monitor_addr`, or `9898` blocked. Start monitor first; check `./net.sh` (`netstat | grep 9898`) and firewall. |
| compute/memory hang at "ready" | the monitor waits for **all** `--memory_num + --compute_num` nodes. Counts must match what you actually launch. |
| `could not get gid for ib_port ...` | wrong/absent GID on RoCE. Set the GID index per §5.3, or `--ib_port` is wrong. |
| `server create mr error` / RDMA connect fails | wrong `--nic_index`/`--ib_port`, link down (`ibstat`), or RACE port (`10001`) hard-coded port ≠ flag port (§5.2). |
| not enough hugepages / `mmap` fails | raise `vm.nr_hugepages`; ensure it exceeds `--mem_mb` + compute buffers. |
| threads collide / bad pinning | each thread pins to core `tid*numa_total + numa_group`; 56 threads needs ~112 logical cores. Lower `THREADS` or adjust `--numa_node_*`. |
| tree allocation fails with big `KEY_COUNT` | the 30M-key tree must fit in `--mem_mb`; raise `MEM_MB`. The compute side also holds ~3–4 GB of generated records in RAM. |
| `cache_sweep.sh` parses `NA` for throughput | the run failed — open the matching `sweep_logs_*/monitor_<tag>.log` and `compute_<tag>.log`. |
| script edits break on Linux (`$'\r'`) | a `.sh` got CRLF line endings. `dos2unix script/cache_sweep.sh`. (This repo is otherwise CRLF; the committed `cache_sweep.sh` is LF.) |
| SSH prompts for a password | set up key-based SSH from the monitor host to `COMPUTE_HOST`, or set `COMPUTE_HOST=""` for local. |

### Restart / clean slate

```bash
./kill.sh                       # sudo killall -9 monitor memory compute (this host)
ssh 10.30.1.7 './DART/kill.sh'  # and on the compute host
```

---

## 11. Command reference

```bash
./build.sh                      # build -> bin/{monitor,memory,compute}
./init-build.sh                 # clean rebuild + submodules + hugepage hint
./kill.sh                       # kill monitor/memory/compute on this host
./net.sh                        # show who's on port 9898
./script/cache_sweep.sh         # the full 24-run directory-cache sweep
```

See also: [`readme.md`](readme.md) (build + workload-gen), [`test/skills.md`](test/skills.md)
(microbench design), [`test/dart_microbench/`](test/dart_microbench/) (generator + stats).
