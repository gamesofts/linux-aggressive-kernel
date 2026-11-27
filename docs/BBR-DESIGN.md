# BBRv1 aggressive probing + Pixie loss-compensation design (rev6)

## Goal

Linux Aggressive Kernel keeps BBRv1's delivery-bandwidth and min-RTT model while optimizing for **throughput-first, latency-aware** performance on high-RTT, lossy, and cross-border VPS paths:

- Eliminates periodic `PROBE_RTT` throughput collapses and tail-loss RTOs with a `0.5 * BDP` target window.
- Prevents self-inflicted congestion death spirals on shallow-buffer paths through phase-decoupled gains, `0.625x` drain symmetry, and queue-aware drain exit.
- Removes per-ACK division overhead via an O(1) cached Pixie gain inside `struct bbr`.
- Raises `sch_fq` default per-flow and global packet limits so non-TSO, tunnel, WireGuard, QUIC, and retransmit bursts do not trigger local `flows_plimit` drops that feed back into Pixie.

The congestion-control name remains `bbr`, and `fq` pacing remains the default qdisc.

## Aggressive probing and drain symmetry

```text
STARTUP growth threshold       = 1.125 (9/8)
STARTUP no-growth confirmation = 3 RTTs
ProbeBW gains                  = 1.50, 0.625, 1, 1, 1, 1, 1, 1
PROBE_RTT target cwnd          = max(0.5 * raw_BDP, 4)
PROBE_RTT min_rtt window       = 15 seconds
```

- **STARTUP**: lowers the significant-growth threshold from `1.25` to `1.125` while keeping three confirmation rounds. Pixie is **not** stacked on top of `bbr_high_gain (2.885x)`, avoiding `4.33x` cold-start queue explosions.
- **ProbeBW**: probes at `1.50x` for 1 RTT and drains at `0.625x (5/8)` for up to 1 RTT, followed by six `1.0x` cruise RTTs (cycle average `1.015625`). Critically, `0.625 * 1.50 = 0.9375 < 1.0`, guaranteeing that Drain always reduces queue occupancy even when Pixie is pinned at its `1.50x` cap.
- **PROBE_RTT**: borrows BBRv2/v3's `max(0.5 * raw_BDP, 4)` target window (without Pixie inflation on `cwnd` or `pacing_rate`) across a 15-second `min_rtt` window. Because `0.5 * BDP < 1.0 * BDP`, bottleneck queues still drain to expose true propagation delay while retaining 50% throughput and avoiding `cwnd=4` RTO stalls.

## Core loss-compensation formula and phase caps

```text
raw_loss_gain = 1 / (1 - p)    (from Q12 loss ratio across up to 4 ProbeBW RTTs)
pixie_gain    = clamp(raw_loss_gain, 1.0, 1.5)
```

Phase-decoupled actuation prevents multiplicative gain blow-ups:

| BBR Mode / Phase | Effective Pacing Gain | Effective Cwnd Gain |
| :--- | :--- | :--- |
| `BBR_STARTUP` | `2.885x` (no Pixie) | `2.885x` (no Pixie) |
| `BBR_DRAIN` | `0.347x` (no Pixie) | `2.885x` (no Pixie) |
| `BBR_PROBE_BW` Probe | `min(1.50 * pixie, 1.875x)` | `min(2.00 * pixie, 2.50x)` |
| `BBR_PROBE_BW` Drain | `0.625 * pixie` (`<= 0.9375x`) | `min(2.00 * pixie, 2.50x)` |
| `BBR_PROBE_BW` Cruise | `1.00 * pixie` (`<= 1.50x`) | `min(2.00 * pixie, 2.50x)` |
| `BBR_PROBE_RTT` | `1.00x` (no Pixie) | `max(0.5 * raw_BDP, 4)` |

## Queue-aware drain exit

`bbr_bdp()` is split into `bbr_bdp_raw()` (un-compensated model BDP) and `bbr_bdp()` (phase-capped actuation target):

- `bbr_check_drain()` always exits `BBR_DRAIN` against `bbr_inflight_raw(bw, 1.0)`.
- `bbr_is_next_cycle_phase()` during `ProbeBW` Drain inspects `srtt`:
  - When `srtt > 1.125 * min_rtt` (standing queue present), Drain must reach `bbr_inflight_raw(bw, 1.0)` (or finish 1 full `min_rtt`), preventing congestion-induced Pixie gain from exiting Drain on the first ACK.
  - When `srtt <= 1.125 * min_rtt` (clean random-loss path with empty queue), Drain exits early at the compensated `1.0 * wire_BDP` target so pure random-loss throughput is never wasted.

## Adaptive Q12 feedback window, deadband, and O(1) hot path

- **Mode isolation**: only completed `BBR_PROBE_BW` rounds update the 4-RTT history. `STARTUP`/`DRAIN` queue overflows and `PROBE_RTT` low-flight rounds cannot pollute the model.
- **Undersized-round guard**: rounds with fewer than `BBR_PIXIE_MIN_SAMPLES (32)` packets are skipped so keepalive traffic cannot evict loaded rounds.
- **Q12 precision + 0.5% deadband**: each 16-bit slot stores a valid bit and a 12-bit loss fraction (`1/4096 ≈ 0.024%` resolution). Loss ratios below `0.5%` (`lost * 200 < total`) are treated as clean (`0`), preventing single sporadic packet drops on high-BDP paths from locking compensation on.
- **Fast entry / slow exit**: enters after 1 completed `ProbeBW` round above the 0.5% deadband; exits only after 4 consecutive completed rounds remain below the deadband.
- **O(1) cached hot path**: `struct bbr` stores `pixie_gain_cached:10` inside existing unused bitfield space (zero `struct bbr` size growth, still within `ICSK_CA_PRIV_SIZE`). `pixie_gain_cached` is recomputed once per completed RTT using a single 32-bit integer division; every per-ACK call to `bbr_pixie_gain()` is an O(1) read with zero loops and zero divisions.

## High-BDP `sch_fq` defaults

`scripts/apply-fq-tuning.py` tunes `net/sched/sch_fq.c` defaults so `net.core.default_qdisc = fq` works out-of-the-box without local `flows_plimit` drops:

```text
sch->limit     = 32768  (stock: 10000)
q->flow_plimit = 2000   (stock: 100)
q->fq_trees_log = ilog2(4096) (stock: ilog2(1024))
```

Runtime `tc qdisc change` overrides continue to work normally.

## Source, toolchain, and build model

The project tracks the latest kernel.org stable release and verifies the downloaded tarball against a kernel.org maintainer signature. `scripts/apply-aggressive-bbr.py` transforms `net/ipv4/tcp_bbr.c` and `scripts/apply-fq-tuning.py` transforms `net/sched/sch_fq.c`, rejecting unexpected source layouts.

Release kernels are built on amd64 and arm64 with **Clang + ThinLTO (`LLVM=1`, `CONFIG_LTO_CLANG_THIN=y`)**, `CONFIG_PREEMPT_LAZY=y` + `CONFIG_PREEMPT_DYNAMIC=y`, `CONFIG_HZ_250=y`, Netfilter Flowtable offload, TPROXY/policy routing, kTLS, WireGuard, hardware crypto acceleration, and trimmed cloud VPS drivers. CI also compiles `tcp_bbr.o` and `sch_fq.o` with GCC to enforce dual-compiler cleanliness.

## Network experiment matrix

`tests/bench-netem.sh` provides a reproducible Linux `netns` + `veth` + `tc netem` + `tbf` + `iperf3` benchmark harness covering clean high-BDP links, random-loss cross-border links (2% / 5% / 15%), shallow-buffer congestion links (`0.5 BDP` `tbf`), and mixed evening-peak paths with competing flows.