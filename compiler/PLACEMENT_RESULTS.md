# XPU compiler placement experiment

> Synthetic DAG experiment only. It demonstrates the effect of placement policy; it is not application performance evidence.

Nodes: **8,192**, chiplets: **4**, target parents/node: **4**, allowed static load imbalance: **15%**.

| Hidden cross-edge rate | Round-robin remote | Refined locality remote | Remote-edge reduction | Refined imbalance |
|---:|---:|---:|---:|---:|
| 2% | 74.68% | 6.84% | 90.8% | 1.150x |
| 5% | 75.45% | 11.27% | 85.1% | 1.150x |
| 10% | 74.87% | 13.20% | 82.4% | 1.150x |
| 20% | 75.03% | 15.46% | 79.4% | 1.150x |

## Interpretation

- Round-robin destroys semantic locality and leaves about three quarters of edges remote on four chiplets.
- Greedy parent affinity plus bounded local refinement cuts remote traffic by roughly an order of magnitude in strongly clustered graphs.
- On this synthetic model, the **5-10% remote-edge target is reachable for low-cross-edge fused graphs**, but doing so may consume roughly 15% static placement imbalance.
- Runtime work stealing and lane gating should correct utilization imbalance without throwing away compile-time data locality.
- The next benchmark must use real EML DAGs emitted by the compiler, not synthetic communities.
