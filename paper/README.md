# DEX vs. DART paper

`dex_vs_dart.tex` — a PVLDB/SIGMOD-style (acmart `sigconf`) head-to-head of DEX
and DART on RDMA disaggregated memory. Every number and figure comes from the
committed sweep data; nothing is invented.

## Sources of truth
- **DEX data:** [`../dex/build/results/summary_full.csv`](../dex/build/results/summary_full.csv)
  (main sweep, p50/mean/p99, rdma_read/op, rpc/op) and
  `summary_memthreads.csv` (the `memThreadCount` sweep).
- **DART data:** the latest `../DART/cache_sweep_baseline_summary_*.csv`.
- **Figures:** `../compare_plots/*.png`, emitted by
  [`../compare_dex_dart.py`](../compare_dex_dart.py). The `.tex` pulls them via
  `\graphicspath{{../compare_plots/}}`.
- **Narrative basis:** [`../COMPARISON.md`](../COMPARISON.md).

## Regenerate the figures
```bash
python ../compare_dex_dart.py   # needs matplotlib; writes ../compare_plots/*.png
```

## Build the PDF
No local TeX toolchain is installed on the dev box. Either:
- **Overleaf:** upload `dex_vs_dart.tex` plus the `compare_plots/` PNGs (keep the
  relative path, or change `\graphicspath` to `{{./figures/}}` and drop the PNGs
  in `figures/`), then compile with pdfLaTeX.
- **Local:** install TeX Live / MiKTeX, then
  ```bash
  pdflatex dex_vs_dart && pdflatex dex_vs_dart
  ```
  (bibliography is inline `thebibliography`, so no bibtex pass needed).

## Figure inventory used (22)
throughput_vs_cache, latency_p99_vs_cache, dex_catches_dart, tail_latency,
memthreads (lookup), memthreads_cache — each × {lookup,scan} × {uniform,zipf}.
Radar plots are intentionally omitted for now.
