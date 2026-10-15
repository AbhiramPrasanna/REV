# Fair sweep: DEX and CHIME against DART

Results: `/home/apa222/REV/fair/results/l3_w_dart`. Each cell is throughput / DART's throughput at the same
workload and cache size. Above 1.00 = faster than DART. Memory threads 0 = no
offloading. CHIME+ = the better leaf-cache arm. DART scans return one key, so
scan ratios understate the B+trees.

## DEX

### point-uniform

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### point-zipf

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### range-uniform

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### range-zipf

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

## CHIME+

### point-uniform

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### point-zipf

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### range-uniform

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

### range-zipf

| memory threads | 27 MB | 108 MB | 433 MB |
|---|---:|---:|---:|

Reaches DART first at: not reached

