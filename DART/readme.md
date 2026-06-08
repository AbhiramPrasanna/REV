# DART

[SIGMOD'26]: DART: A Lock-free Two-layer Hashed ART Index for Disaggregated Memory

## Compile

### Clone

```shell
git clone <this repo>
git submodule update --init --recursive
```

### Build


```shell
sudo apt install libboost-context-dev libboost-coroutine-dev
cmake -B build
cmake --build build
```



## Workload Generation


```shell
./script/workload_download.py
./script/workload_gen.sh
```

```shell
./script/split_and_send_workload.py --inputs a_load a_run --outputs a_load_split a_run_split --ips 70 72 74
```

## Run

> **DART has no memcached.** Coordination is done by the `monitor` process over
> TCP. The whole cluster config is just two things:
> 1. `--monitor_addr` — host:port every binary uses to reach the monitor.
> 2. the `ips[]` array in [`src/main/compute.cc`](src/main/compute.cc) — the
>    memory-node IPs the RACE skip-table dials directly on TCP `:10001`.
>    It is already set to `{"10.30.1.6", "10.30.1.9"}` (ips[0] = memory node 0).
>    **If you edit it, rebuild `compute`.**

### Cluster layout (2 servers, 1 memory + 1 compute)

| server      | roles                                  |
|-------------|----------------------------------------|
| `10.30.1.6` | `monitor` + `memory` (memory node 0)   |
| `10.30.1.9` | `compute` (compute node 0)             |

### 0. One-time prep on **both** servers

```shell
# Reserve hugepages (back the RDMA buffers). 16384 * 2 MiB = 32 GiB; must be
# >= --mem_mb on the memory node and big enough for the compute buffers.
sudo sysctl -w vm.nr_hugepages=16384

# Find which RDMA device index to pass as --nic_index (the order ibv_devices
# lists; index 0 = first device). Also confirm the GID/port are up.
ibv_devices        # list RDMA NICs -> pick the index of your NIC
ibstat             # confirm State: ACTIVE, and the port number (--ib_port)
```

The compute node reads the **workload files** from disk (the monitor only sends
their *names*). Make sure `c_load` / `c_run` exist on `10.30.1.9` under
`./workload/split/` (the default `--workload_prefix`); generate them with the
steps in *Workload Generation* above, or point `--workload_prefix` elsewhere.

### 1. On `10.30.1.6` — start the monitor (terminal 1)

```shell
bin/monitor \
  --monitor_addr=0.0.0.0:9898 \
  --memory_num=1 --compute_num=1 \
  --load_thread_num=56 --run_thread_num=56 --coro_num=1 \
  --mem_mb=8192 --th_mb=10 \
  --test_func=0 --bucket=256 \
  --workload_load=c_load --workload_run=c_run \
  --run_max_request=6000000
```

What each flag does:

- `--monitor_addr=0.0.0.0:9898` — the monitor **binds** here and listens on all
  interfaces; memory/compute dial `10.30.1.6:9898`.
- `--memory_num` / `--compute_num` — how many memory and compute nodes the
  monitor waits to connect before it proceeds (1 + 1 here).
- `--load_thread_num` / `--run_thread_num` — worker threads per compute node for
  the load phase and the measured run phase. **Set to your core budget**: each
  thread is pinned to core `thread_index * 2 + numa_group`, so 56 threads needs
  ~112 logical cores; lower it (e.g. `16`) if you have fewer.
- `--coro_num` — coroutines per thread (request batching depth). `1` = no
  batching.
- `--mem_mb` — size (MiB) of the RDMA memory region the memory node registers
  (the disaggregated heap). Must fit in hugepages.
- `--th_mb` — per-thread scratch buffer on the compute side (MiB).
- `--test_func=0` — selects the YCSB load+run benchmark (the only entry in
  `compute.cc`'s `test_func_list`). It loads, builds the skip table, then runs.
- `--bucket=256` — RACE hash-bucket count for the two-layer hashed ART.
- `--workload_load` / `--workload_run` — file names (appended to
  `--workload_prefix`, default `./workload/split/`) the compute node loads.
- `--run_max_request=6000000` — cap on measured run operations (truncates
  `c_run`). This is the working-set op count.

> These workload/sizing flags only matter on the **monitor** — it relays them to
> the compute nodes. `memory` and `compute` take only the connection/hardware
> flags below.

### 2. On `10.30.1.6` — start the memory node (terminal 2)

```shell
bin/memory --monitor_addr=10.30.1.6:9898 --nic_index=0 --ib_port=1
```

- `--monitor_addr` — where to reach the monitor.
- `--nic_index` — which RDMA device (from `ibv_devices`) to register memory on.
  **Set to your NIC's index** (default for `memory` is `1`).
- `--ib_port` — IB port on that device (from `ibstat`, usually `1`).

The memory node registers its RDMA region and also starts the RACE skip-table
**Server** listening on TCP `:10001` (that's what compute's `ips[]` connects to).

### 3. On `10.30.1.9` — start the compute node

```shell
bin/compute --monitor_addr=10.30.1.6:9898 --nic_index=0 --ib_port=1 \
            --numa_node_total_num=2 --numa_node_group=0
```

- `--monitor_addr` — the monitor on `10.30.1.6`.
- `--nic_index` / `--ib_port` — this server's RDMA device/port (default
  `nic_index` for `compute` is `0`).
- `--numa_node_total_num` / `--numa_node_group` — core-pinning stride and offset
  (`core = thread_index * total + group`). Keep `total` = NUMA nodes, `group` =
  which NUMA node to run on.

### Order & what you'll see

Start **monitor first**, then **memory**, then **compute** (the monitor blocks
until all nodes connect). The compute node loads the data, builds the skip table,
runs the measured phase, and sends its `(throughput, latency)` back; the monitor
then prints:

```
Total throughput = <X> MOps
Average latency  = <Y> us
```

> **Want the YCSB-free in-memory working set instead of `c_load`/`c_run`?**
> See [test/skills.md](test/skills.md) and [test/dart_microbench/](test/dart_microbench/):
> apply the small `compute.cc` edit from `integration.md`, and the same commands
> above run the generated working set (size/skew/mix become run-time knobs
> instead of files).

## Note

The RACE hashing part of this code is based on the implementation from:
https://github.com/minxinhao/SepHash

You are welcome to substitute this component with a more efficient hash table if one is available.



