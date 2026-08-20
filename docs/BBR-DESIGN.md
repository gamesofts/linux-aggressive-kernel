# BBRv1 erasure-aware Pixie design

## Goal

Linux Aggressive Kernel keeps BBRv1's delivery-bandwidth and min-RTT model, but no longer assumes that every observed loss should be compensated equally.

The controller now separates two regimes:

- **rate-independent erasure**: loss that persists below the bottleneck and should not cause the sender to give up usable capacity;
- **overload / congestion loss**: loss above the trusted erasure floor, especially when accompanied by RTT inflation, which must not be amplified.

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

A rolling minimum is attractive because congestion can only push observed loss upward. It is also too sensitive to a single unusually clean RTT. One lucky sample can make a real 10-20% erasure path look almost clean and keep it under-compensated for the lifetime of the window.

The v2 estimator therefore keeps **eight valid completed RTT loss ratios** in the same fixed private-state budget previously used by BBRv1's long-term policer fields.

Each RTT must contain at least 32 ACKed+lost packets. The stored value is a one-byte quantized loss ratio on a 0..254 scale.

The floor candidate is robust rather than a raw minimum:

- with 4-5 valid RTTs, use the median;
- with 6-8 valid RTTs, take the lower half of the sorted samples and use that half's median.

For eight RTTs this is effectively a lower-quartile estimate built from the second and third-lowest observations. A single very low outlier cannot drag the result down, while high-loss congestion rounds naturally remain in the upper half and do not raise the baseline.

Example:

```text
RTT loss: 14 15 15 16 17 31 34 38 (%)
sorted:   14 15 15 16 17 31 34 38
lower half: 14 15 15 16
floor candidate ~= 15%
```

## Trusted lower envelope

Once a floor is established, it is deliberately asymmetric:

- a lower robust candidate may reduce the trusted floor immediately;
- a higher candidate never raises the trusted floor during the same active period.

This prevents the dangerous loop:

```text
queue overload -> more loss -> higher estimated floor
               -> more compensation -> still more overload
```

A genuine path change is relearned after BBR's application-limited idle restart, which clears the Pixie floor and feedback history.

This is intentionally conservative. If the real non-congestive erasure rate suddenly rises during one continuously active TCP flow, the controller may temporarily under-compensate rather than risk misclassifying congestion as erasure.

## Floor activation

The controller does not compensate from the first lossy RTT.

A trusted floor requires:

1. at least four valid completed RTT samples;
2. a non-zero robust floor candidate;
3. BBR must no longer be in STARTUP;
4. the current RTT sample must not show obvious queue inflation.

Avoiding STARTUP is important because STARTUP deliberately probes aggressively and may itself create queue loss. Learning a permanent erasure baseline from that phase would be unsafe.

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
- BBR packet conservation is allowed to operate.

An RTO also immediately starts the overload hold-down.

When the hold-down expires without renewed overload evidence, compensation resumes using the unchanged trusted floor.

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
- transient queue loss: does not raise the floor;
- strong excess loss or RTT inflation: temporarily falls back to native BBR recovery;
- idle restart: discards stale path assumptions and learns again.

The 1.5x cap remains intentionally conservative. The current design favors avoiding self-inflicted overload over fully compensating extreme erasure rates.
