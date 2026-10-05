# Fair sweep: DEX and CHIME against DART

Results: `/home/apa222/REV/fair/results/dxtr_range_uniform`. Each cell is throughput / DART's throughput at the same
workload and cache size. Above 1.00 = faster than DART. Memory threads 0 = no
offloading. CHIME+ = the better leaf-cache arm. DART scans return one key, so
scan ratios understate the B+trees.

## DEX

### point-uniform

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### point-zipf

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### range-uniform

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### range-zipf

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

## CHIME+

### point-uniform

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### point-zipf

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### range-uniform

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

### range-zipf

| memory threads | 8 MB | 32 MB | 64 MB | 128 MB | 256 MB | 512 MB | 1024 MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | - | - | - | - | - | - | - |
| 2 | - | - | - | - | - | - | - |
| 4 | - | - | - | - | - | - | - |
| 8 | - | - | - | - | - | - | - |
| 16 | - | - | - | - | - | - | - |

Reaches DART first at: not reached

