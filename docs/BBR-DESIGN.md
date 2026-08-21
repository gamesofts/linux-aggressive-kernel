# BBRv1 aggressive probing + Pixie loss-compensation design

## Goal

Linux Aggressive Kernel keeps BBRv1's delivery-bandwidth and min-RTT model, makes STARTUP and ProbeBW more aggressive with fixed constants, and uses a bounded loss multiplier to determine the wire rate and inflight budget required to preserve delivered goodput on lossy paths.

The design deliberately avoids dynamic path classification for bandwidth probing. The congestion-control name remains `bbr`, and fq pacing remains the expected qdisc.

## Aggressive probing

The bandwidth-probing changes are intentionally simple:

```text
STARTUP growth threshold = 1.125
STARTUP no-growth confirmation = 4 RTTs
ProbeBW gains = 1.50, 0.75, 1, 1, 1, 1, 1, 1
```

Stock BBRv1 considers bandwidth growth significant only when the current maximum reaches about 1.25 times the previous full-bandwidth estimate, and declares the pipe full after three non-growing rounds. Linux Aggressive Kernel lowers that growth threshold to 1.125 and requires four non-growing rounds before leaving STARTUP.

ProbeBW keeps the original eight-RTT cycle shape but changes only the first probe gain from 1.25 to 1.50. The following 0.75 drain RTT and six 1.0 cruise RTTs remain unchanged. The average gain over a complete cycle is therefore 1.03125.

These probe gains affect the BBR actuation path but do not create a second bandwidth estimator. Successfully delivered traffic still determines BBR's delivery-bandwidth samples and max filter.

## Core loss-compensation formula

```text
raw_loss_gain = (acked + lost) / acked
loss_gain = min(raw_loss_gain, 1.5)
pacing_rate = BBR_pacing_rate * loss_gain
cwnd_target = BBR_cwnd_target * loss_gain
```

With `p = lost / (acked + lost)`, the uncapped multiplier is `1 / (1 - p)` whenever at least one packet has been ACKed. A window with no valid ACK feedback uses a gain of 1.0.

The same 1.5 gain cap applies to pacing and compensated cwnd/inflight. It limits the requested wire rate and inflight budget to 150% of BBR's base output.

## Adaptive feedback window

The feedback controller uses completed packet-timed RTTs and deliberately has different entry and exit behavior.

### Entry

While compensation is inactive, only the newest completed RTT is examined. Compensation becomes active when that RTT contains at least 32 packet observations and at least one observed loss. This allows a real loss signal to affect the next round without waiting for a long history.

### Maintenance

Once active, the gain uses every available completed RTT in the most recent four-RTT history:

```text
window_samples = sum(samples from up to 4 completed RTTs)
window_lost = sum(losses from up to 4 completed RTTs)
window_acked = window_samples - window_lost
```

The 32-sample threshold is only an activation guard. Reaching it does not stop accumulation; all retained rounds continue to contribute to the active gain.

### Exit

Compensation does not exit after one clean RTT. It exits only when four completed RTTs are available and the complete four-RTT history contains no observed loss. This hysteresis makes entry fast while preventing short clean intervals from repeatedly disabling and re-enabling compensation.

The fixed BBR private-state area stores four completed RTT buckets plus full current-round ACK/loss counters. Completed rounds are ratio-preserving normalized buckets so the four-RTT history fits without increasing `struct bbr` beyond `ICSK_CA_PRIV_SIZE`.

## Idle restart

When BBR detects an application-limited transmit restart, the completed-round history, current counters, and active state are cleared. New traffic starts with a gain of 1.0 and must satisfy the one-RTT entry rule again.

## Bandwidth model

The delivery-rate max filter uses `CYCLE_LEN + 2`. Neither the fixed aggressive probe gain nor the bounded loss gain is written into delivery-rate samples or the max filter. BBR continues to model successfully delivered bandwidth, while the gains determine how aggressively that model is tested and how much extra wire traffic is used to compensate for loss.

## Pacing

```text
base_rate = bbr_rate_bytes_per_sec(bw, pacing_gain)
wire_rate = base_rate * loss_gain
pacing_rate = min(wire_rate, sk_max_pacing_rate)
```

During ProbeBW's first phase, `pacing_gain` is 1.5. During STARTUP the normal BBR high gain is retained. The pacing margin is 0%, so the base output is not reduced before compensation.

## Cwnd and inflight

`bbr_bdp()` applies the same bounded loss multiplier to the BDP target. Cwnd growth remains ACK-paced:

```text
cwnd = min(saturating_add(cwnd, acked), target_cwnd)
```

Before full bandwidth is reached, STARTUP growth also uses saturated addition. The final cwnd remains capped by `snd_cwnd_clamp`.

## Loss recovery

TCP loss detection, SACK, RACK, TLP, RTO, retransmission queues, and recovery state remain active. The BBR loss-response path does not subtract newly marked losses from cwnd and does not enable BBR packet conservation. ACK/loss feedback continues to determine the bounded pacing and target-cwnd multiplier during recovery.

## BBR modes

The implementation retains STARTUP, DRAIN, ProbeBW, ProbeRTT, min-RTT measurement, ACK aggregation, TSO/GSO quantization, and fq/socket pacing limits. STARTUP uses the 12.5% growth threshold with four-round confirmation, and ProbeBW uses the fixed `1.50, 0.75, 1, 1, 1, 1, 1, 1` gain cycle. The BBRv1 long-term policer estimator is not used. `bbr_bw()` always returns the windowed delivery-bandwidth maximum.

## Source and build model

The project tracks the latest kernel.org stable release and verifies the downloaded source against a kernel.org maintainer signature. `scripts/apply-aggressive-bbr.py` transforms only `net/ipv4/tcp_bbr.c` and rejects unexpected source layouts.

The kernel configuration starts from the upstream architecture defconfig and enables the networking, storage, filesystems and virtualization features needed by mainstream VPS/cloud environments. CI validates the transformation with GCC and Clang on amd64 and arm64, then builds and validates both DEB and RPM packages plus a signed-source provenance manifest.

## Network experiment matrix

Recommended tests cover RTTs of 20, 100, 250, and 600 ms; random and burst loss; forward, reverse, and bidirectional loss; capacity changes; post-bottleneck corruption; queue drops; policers; shallow queues; and competing BBR/CUBIC flows. Record delivered goodput, wire throughput, retransmitted bytes, RTO/TLP counts, p50/p95/p99 RTT, pacing rate, cwnd, delivery-bandwidth estimate, and recovery time after path changes.
