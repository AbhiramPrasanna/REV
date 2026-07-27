# sweep_20260724_112322 (memory) — INCOMPLETE paste

This `summary_memory.csv` was reconstructed from a terminal scrollback after the
SSH session to `cs-dis-srv01s` dropped mid-print (`Connection timed out` /
`Broken pipe`). **20 of 24 rows survived intact.** These 4 rows were corrupted by
interleaved disconnect messages and are **omitted rather than guessed**:

| cache_mb | workload      | offload |
|----------|---------------|---------|
| 32       | range-uniform | off     |
| 32       | range-uniform | on      |
| 16       | point-uniform | off     |
| 16       | range-zipf    | on      |

The **compute** summary (`sweep_20260724_112339/summary_compute.csv`) is complete
(24/24) and carries the client-side throughput + p99, so the primary result is
intact. Only the memory-side view (its own p99 and the `index_mb` consumed-cache
column) is missing for those 4 cells.

## To complete it

The authoritative file is on the node. When you reconnect:

```bash
scp apa222@cs-dis-srv01s.cmpt.sfu.ca:/home/apa222/REV/CHIME/build/results/cache_stress/sweep_20260724_112322/summary_memory.csv \
    CHIME/results/memory/sweep_20260724_112322/summary_memory.csv
git add CHIME/results/memory/sweep_20260724_112322/summary_memory.csv && \
git commit -m "results: complete memory summary for sweep_20260724_112322" && git rm CHIME/results/memory/sweep_20260724_112322/README_INCOMPLETE.md
```
