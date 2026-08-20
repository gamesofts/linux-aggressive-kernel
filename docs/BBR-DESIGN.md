# BBRv1 erasure-aware Pixie design

## Goal

Linux Aggressive Kernel keeps BBRv1's delivery-bandwidth and min-RTT model, but no longer assumes that every observed loss should be compensated equally.

The controller separates two regimes:

- **rate-independent erasure**: loss that persists below the bottleneck and should not cause the sender to give up usable capacity;
- **overload / congestion loss**: loss above the trusted erasure floor, especially when accompanied by RTT inflation, which must not be amplified.

The primary objective is useful throughput on difficult long-haul links. Safety logic exists to avoid self-inflicted overload, but it must not permanently trap a long-lived flow at a stale low erasure floor.

The congestion-control name remains `bbr`, fq pacing remains the expected qdisc, and the maximum Pixie compensation remains 1.5x.

## Core model

BBR measures successfully delivered bandwidth. On an erasure channel, the wire rate needed to preserve that delivered rate is larger:

```text
arrival_rate = 1 - erasure_floor
wire_rate = delivered_rate / arrival_rate
```

The same bounded multiplier is applied to pacing and BDP/cwnd:

```text
gain = min(1 / (1 - erasure_floor), 1.5)
pacing_rate = BBR_pacing_rate * gain
cwnd_target = BBR_cwnd_target * gain
```

The erasure gain is never written back into BBR's delivery-rate max filter. BBR continues to estimate useful delivered bandwidth rather than the additional wire traffic required to survive loss.

## Why the floor is not a simple minimum

A rolling minimum is attractive because congestion can only push observed loss upward. It is also too sensitive to a single unusually clean RTT. One lucky sample can make a real 10-20% erasure path look almost clean and leave it under-compensated.

The estimator therefore keeps **eight valid completed RTT loss ratios** in the same fixed private-state budget previously used by BBRv1's long-term policer fields.

Each RTT must contain at least 32 ACKed+lost packets. The stored value is a one-byte quantized loss ratio on a 0..254 scale.

The floor candidate is robust rather than a raw minimum:

- with 4-5 valid RTTs, use the median;
- with 6-8 valid RTTs, take the lower half of the sorted samples and use that half's median.

For eight RTTs this is effectively a lower-quartile estimate built from the second and third-lowest observations. A single very low outlier cannot drag the result down, while high-loss congestion rounds naturally remain in the upper half.

Example:

```text
RTT loss: 14 15 15 16 17 31 34 38 (%)
sorted:   14 15 15 16 17 31 34 38
lower half: 14 15 15 16
floor candidate ~= 15%
```

## Adaptive trusted floor: fast down, confirmed up

The trusted floor is deliberately asymmetric, but it is **not** permanently a lower envelope.

### Downward update

If the robust candidate falls below the trusted floor, the floor moves down immediately.

This is safe because congestion cannot explain why the low quantile became cleaner. It also prevents a stale high floor from continuing to over-compensate after the path improves.

### Upward update

A higher candidate is essential for throughput: if the physical path's non-congestive loss rises from, for example, 10% to 20%, keeping the old floor would cause BBR to under-send indefinitely.

However, blindly moving the floor upward would recreate the dangerous positive-feedback loop:

```text
queue overload -> more loss -> higher floor
               -> more compensation -> still more overload
```

The controller therefore treats BBR's own lower-pressure phases as a small active experiment.

A higher robust candidate counts as upward evidence only when all of the following are true:

1. BBR is no longer in STARTUP;
2. current `pacing_gain <= 1.0`, so the sender is not in the 1.25x ProbeBW probing phase;
3. sampled RTT is no more than 125% of BBR min-RTT;
4. the robust candidate remains above the current trusted floor.

Two consecutive qualifying completed RTTs are required. The confirmation count is intentionally short because the candidate itself already represents multiple RTTs and a lower quantile rather than one raw sample.

After confirmation:

```text
trusted_floor = robust_candidate
overload_hold_down = 0
```

The sender immediately resumes compensation from the new floor instead of sacrificing several more WAN RTTs.

This makes the adaptation policy:

```text
lower candidate  -> fast decrease
higher candidate -> require low-pressure confirmation -> direct increase
```

## Why upward confirmation may run during overload hold-down

This is intentional and important.

Suppose the true erasure floor rises sharply. The old floor will initially classify the additional loss as overload and switch Pixie compensation off. That native BBR recovery period provides exactly the rate perturbation needed to distinguish the two hypotheses:

```text
if loss falls when sender backs off:
    likely congestion

if loss remains high while pacing <= 1.0 and RTT is near min_rtt:
    likely a higher rate-independent erasure floor
```

Therefore `pixie_raise_rounds` is allowed to accumulate during overload hold-down, but only in qualifying low-pressure rounds. Once the higher floor is confirmed, the stale overload state is cleared and compensation resumes immediately.

An RTO clears any pending upward evidence and starts overload hold-down again.

## Floor activation

The controller does not compensate from the first lossy RTT.

A trusted floor requires:

1. at least four valid completed RTT samples;
2. a non-zero robust floor candidate;
3. BBR must no longer be in STARTUP;
4. pacing must be at or below 1.0x;
5. the current RTT sample must not show obvious queue inflation.

Avoiding STARTUP is important because STARTUP deliberately probes aggressively and may itself create queue loss. Learning an erasure baseline from that phase would be unsafe.

## Overload detection

After a trusted floor exists, each completed valid RTT is compared with it.

```text
excess_loss = recent_loss - trusted_floor
```

Two thresholds are used on the quantized 0..254 scale:

```text
moderate_excess = max(~3.1%, floor / 4)
severe_excess   = max(~7.9%, floor / 2)
```

Overload is declared when either:

- excess loss reaches the severe threshold; or
- excess loss reaches the moderate threshold and sampled RTT exceeds 125% of BBR min-RTT.

This deliberately treats large unexplained loss as suspicious even with a shallow queue where RTT inflation may be small.

## Overload hold-down and native recovery

When overload is detected, Pixie compensation is disabled for three valid completed RTTs.

During this hold-down:

- `bbr_pixie_gain()` returns 1.0;
- pacing and cwnd are no longer erasure-boosted;
- the stock BBRv1 loss recovery path is restored;
- loss may reduce cwnd;
- BBR packet conservation is allowed to operate;
- higher-floor confirmation may still proceed in qualifying low-pressure rounds.

An RTO immediately starts the overload hold-down and resets floor-rise confirmation.

If overload evidence disappears, compensation resumes from the current floor. If the higher erasure floor is confirmed first, the floor is raised and hold-down is cleared immediately.

## Private-state budget

The implementation does not increase the BBR private-state footprint beyond the space formerly occupied by the long-term policer state.

The previous four u32 policer words are repurposed as:

```text
pixie_rounds[2]       8 x one-byte RTT loss samples
pixie_round_acked     current RTT ACK count
pixie_round_lost      current RTT loss count
```

Additional state fits in the existing 32-bit flag word:

```text
pixie_active             1 bit
pixie_round_head         3 bits
pixie_round_count        4 bits
pixie_floor              8 bits
pixie_overload_rounds    3 bits
pixie_raise_rounds       3 bits
```

## Loss recovery

TCP SACK/RACK/TLP/RTO and retransmission machinery remain untouched.

Behavior differs by regime:

```text
trusted erasure, no overload:
    mask BBR's direct cwnd loss response
    keep retransmission machinery
    compensate pacing + cwnd from trusted floor

overload / unknown regime:
    no Pixie gain
    use native BBRv1 cwnd loss response
    use native packet conservation

higher floor confirmed under low pressure:
    raise trusted floor
    clear overload hold-down
    resume compensated pacing + cwnd
```

This is the main safety change from the first Pixie version, which effectively let Pixie own the response to every observed loss.

## BBR modes and bandwidth model

The implementation retains STARTUP, DRAIN, ProbeBW, ProbeRTT, min-RTT measurement, ACK aggregation, TSO/GSO quantization, fq/socket pacing limits, and the ten-round delivery-bandwidth max filter.

The BBRv1 long-term policer estimator is not used. `bbr_bw()` always returns the windowed delivered-bandwidth maximum.

## Operational expectations

The design is intended for high-latency links with a measurable rate-independent loss floor, such as difficult cross-border, mobile, wireless, satellite, or otherwise lossy long-haul paths.

Expected behavior:

- clean path: behaves close to ordinary BBRv1;
- stable random loss: learns a floor after several completed RTTs and compensates it;
- path erasure becomes worse: briefly backs off, verifies the higher loss under low pressure, then raises the floor and restores stronger compensation;
- transient queue loss: enters native recovery but does not immediately raise the floor;
- strong excess loss or RTT inflation: temporarily falls back to native BBR recovery;
- idle restart: discards stale path assumptions and learns again.

The 1.5x cap remains intentionally bounded. Within that cap, the design favors recovering useful throughput after a real increase in the path's erasure floor rather than leaving a long-lived connection permanently under-compensated.
