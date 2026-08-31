# XPU ready-node scheduler model

> Synthetic deterministic DAG + latency model. Not RTL timing, silicon evidence or application performance.

Nodes: **8,192**, chiplets: **4**, target dependencies/node: **4**, remote-token latency: **12 cycles**.

| Hidden cross rate | Lanes/chiplet | RR remote | Locality remote | RR cycles | Locality cycles | Speedup | RR util | Locality util |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2% | 8 | 74.68% | 6.84% | 1902 | 991 | 1.92x | 13.46% | 25.83% |
| 2% | 32 | 74.68% | 6.84% | 1714 | 631 | 2.72x | 3.73% | 10.14% |
| 2% | 64 | 74.68% | 6.84% | 1714 | 593 | 2.89x | 1.87% | 5.40% |
| 5% | 8 | 75.45% | 11.27% | 2125 | 1164 | 1.83x | 12.05% | 21.99% |
| 5% | 32 | 75.45% | 11.27% | 1996 | 833 | 2.40x | 3.21% | 7.68% |
| 5% | 64 | 75.45% | 11.27% | 1996 | 808 | 2.47x | 1.60% | 3.96% |
| 10% | 8 | 74.87% | 13.20% | 2401 | 1411 | 1.70x | 10.66% | 18.14% |
| 10% | 32 | 74.87% | 13.20% | 2287 | 956 | 2.39x | 2.80% | 6.69% |
| 10% | 64 | 74.87% | 13.20% | 2287 | 920 | 2.49x | 1.40% | 3.48% |
| 20% | 8 | 75.03% | 15.46% | 2800 | 1767 | 1.58x | 9.14% | 14.49% |
| 20% | 32 | 75.03% | 15.46% | 2628 | 1338 | 1.96x | 2.44% | 4.78% |
| 20% | 64 | 75.03% | 15.46% | 2628 | 1317 | 2.00x | 1.22% | 2.43% |

## Main result

Locality is not merely a bandwidth optimization. When a remote dependency costs 12 cycles, placement directly shortens the critical dependency path. At 32 lanes/chiplet the modeled speedup ranges from roughly **2.0x to 2.7x** across the tested graph families.

## Architectural consequence

The XPU compiler should optimize at least three objectives together: **remote-edge bytes, remote dependency depth, and chiplet load balance**. A placement with the same cut size can still be worse if its remote edges lie on the critical path.

The next scheduler version should add bounded NoC injection queues, packet serialization, lane classes, graph priorities and runtime work stealing.
