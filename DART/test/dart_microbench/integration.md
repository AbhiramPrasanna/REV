# Wiring the in-memory generator into DART

The generator emits the **same record type** the YCSB engine already consumes
(`YCSB::FileLoader::records`), so the change is small and surgical. There are two
ways in; pick one.

---

## Option A — feed records straight to `YCSB::Benchmark` (recommended)

`YCSB::Benchmark::prepare_workload_file()` is the only thing that touches a
`FileLoader`, and internally it only sets three private iterators. Add one
generic overload next to it.

**`include/ycsb/ycsb-timecounter.hpp`** — in `class Benchmark`, public section:

```cpp
// existing:
void prepare_workload_file(FileLoader& file_loader, uint64_t part = 1, uint64_t all_parts = 1);
// add:
void prepare_workload(FileLoader::records::iterator begin,
                      FileLoader::records::iterator end);
```

**`src/ycsb/ycsb-timecounter.cc`**:

```cpp
void Benchmark::prepare_workload(FileLoader::records::iterator begin,
                                 FileLoader::records::iterator end) {
    this->start_record = this->now_record = begin;
    this->end_record   = end;
}
```

Then in **`src/main/compute.cc`**, inside `test_ycsb_load`, replace the
`ycsb.prepare_workload_file(file_loader_load, thread_index, used_thread_num);`
call with a slice of the generated records. Build the generator once on the main
thread (so the spans live for the whole run) and pass it in, then per thread:

```cpp
auto& recs = is_run_phase ? gen.run_records() : gen.load_records();
uint64_t per   = (recs.size() + used_thread_num - 1) / used_thread_num;
auto begin = recs.begin() + std::min<uint64_t>(per * thread_index, recs.size());
auto end   = recs.begin() + std::min<uint64_t>(per * (thread_index + 1), recs.size());
ycsb.prepare_workload(begin, end);
```

The `FileLoader file_loader_load/run` objects and the
`file_loader_*.load_from_file(...)` calls in `main()` can then be dropped for the
microbench path.

> Per-thread sharding here matches `FileLoader::get_part_*`: contiguous slices of
> the record vector, one per worker thread.

---

## Option B — add a dedicated `test_func` (keeps YCSB path intact)

Leave the YCSB file path untouched and add a parallel microbench function so you
can switch with `--test_func`.

1. Build the generator once in `main()` (after flags), guard it by
   `if (test_func_num == 1)`.
2. Add `test_microbench_run` to `test_func_list[]` so `--test_func=1` selects it.
3. Map the existing monitor gflags onto `WorkloadSpec` (no monitor.cc change):

   | gflag                | WorkloadSpec field        |
   |----------------------|---------------------------|
   | `--run_max_request`  | `op_count`                |
   | `--payload_byte`     | `value_len`               |
   | `--percent`          | `read_pct` (rest split by convention) |
   | `--epoch`            | `theta * 100` (0 ⇒ uniform) |
   | `--bucket`           | `bucket` (tree hash bucket, unchanged) |

   `key_count` needs one new knob; reuse a spare gflag or add
   `DEFINE_uint64(key_count, ...)` to **both** `monitor.cc` (forward it like the
   others) and `compute.cc`.

Option A is less code and keeps the load/run two-phase structure DART already
has; Option B is better if you want YCSB and the microbench to coexist in one
binary.

---

## Adding the latency instrumentation (`bench_stats.h`)

Optional, mirrors the DEX harness. In `compute.cc`:

1. `#include "dart_microbench/bench_stats.h"` (add `test/` to the include path,
   or use a relative include).
2. Give each worker a `thread_local dart_bench::ThreadStats ts;` and
   `dart_bench::registry().enroll(&ts);` once.
3. Wrap each op in the registered lambdas:

   ```cpp
   auto search_it = [&](span key, str& result) {
       dart_bench::ScopedOp _t(ts, dart_bench::OP_READ);
       prheart_tree.search(key);
   };
   ```
   (and `OP_INSERT/OP_UPDATE/OP_SCAN/OP_REMOVE` for the others).
4. After the run loop joins, on the main thread call
   `dart_bench::Reporter::print(com_ind);`.

The `LOCAL/REMOTE` split comes for free from the tree's thread-local `rtt`
counter — no new tree code. Reset `rtt = 0` at the start of the measured phase
(it is already reset to 0 at the top of `test_ycsb_load`).
