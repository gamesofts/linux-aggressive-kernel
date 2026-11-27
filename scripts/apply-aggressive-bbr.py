#!/usr/bin/env python3
"""Port Pixie's loss compensation and throughput-first BBRv1 tuning into Linux."""

import hashlib
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"apply-stock-bbr-tuning: {message}")


def require_once(source: str, text: str, label: str) -> None:
    count = source.count(text)
    if count != 1:
        fail(f"expected exactly one {label}, found {count}")


def replace_once(source: str, old: str, new: str, label: str) -> str:
    require_once(source, old, label)
    return source.replace(old, new, 1)


def replace_span(source: str, start: str, end: str, new: str, label: str) -> str:
    require_once(source, start, f"{label} start marker")
    require_once(source, end, f"{label} end marker")
    start_at = source.index(start)
    end_at = source.index(end, start_at)
    if end_at <= start_at:
        fail(f"invalid {label} marker order")
    return source[:start_at] + new + source[end_at:]


def replace_bbr_private_state(source: str, new: str) -> str:
    """Replace the legacy LT state without depending on comment alignment."""
    pattern = re.compile(
        r"\tu32\s+mode:3,.*?\n\tu32\s+lt_last_lost;[^\n]*\n",
        re.S,
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        fail(f"expected exactly one BBRv1 private-state block, found {len(matches)}")
    block = matches[0].group(0)
    for required in [
        "prev_ca_state:3",
        "packet_conservation:1",
        "round_start:1",
        "idle_restart:1",
        "probe_rtt_round_done:1",
        "lt_is_sampling:1",
        "lt_rtt_cnt:7",
        "lt_use_bw:1",
        "lt_bw;",
        "lt_last_delivered;",
        "lt_last_stamp;",
        "lt_last_lost;",
    ]:
        if required not in block:
            fail(f"BBRv1 private-state block is missing expected field: {required}")
    return source[:matches[0].start()] + new + source[matches[0].end():]


def replace_check_drain(source: str) -> str:
    """Use un-compensated raw BDP for STARTUP->DRAIN->ProbeBW exit checks."""
    pattern = re.compile(
        r"static void bbr_check_drain\(struct sock \*sk, const struct rate_sample \*rs\)\n\{.*?\n\}\n",
        re.S,
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        fail(f"expected exactly one bbr_check_drain definition, found {len(matches)}")
    block = matches[0].group(0)
    if block.count("bbr_inflight(sk, bbr_max_bw(sk), BBR_UNIT)") != 2:
        fail("unexpected bbr_check_drain body layout")
    updated = block.replace(
        "bbr_inflight(sk, bbr_max_bw(sk), BBR_UNIT)",
        "bbr_inflight_raw(sk, bbr_max_bw(sk), BBR_UNIT)",
    )
    return source[:matches[0].start()] + updated + source[matches[0].end():]


if len(sys.argv) not in {2, 3}:
    fail("usage: apply-stock-bbr-tuning.py TCP_BBR_C [PROVENANCE_ENV]")

source_path = Path(sys.argv[1]).resolve()
provenance_path = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else None
if not source_path.is_file() or source_path.name != "tcp_bbr.c":
    fail(f"not a stock BBR source file: {source_path}")

source = source_path.read_text()
stock_sha256 = hashlib.sha256(source.encode()).hexdigest()

# Keep the mainline ten-round bandwidth max filter. Pixie compensates at the
# pacing/cwnd actuation layer, so a second extended bandwidth memory is not
# needed.
require_once(
    source,
    "static const int bbr_bw_rtts = CYCLE_LEN + 2;",
    "stock bandwidth-filter initializer",
)
source = replace_once(
    source,
    "static const u32 bbr_min_rtt_win_sec = 10;",
    "static const u32 bbr_min_rtt_win_sec = 15;",
    "stock min_rtt window duration",
)
source = replace_once(
    source,
    '/* If lost/delivered ratio > 20%, interval is "lossy" and we may be policed: */',
    '/* Legacy build anchor; Pixie compensation replaces BBRv1 policer use. */',
    "stock policer threshold comment",
)
source = replace_once(
    source,
    "static const u32 bbr_lt_loss_thresh = 50;",
    "static const u32 bbr_lt_loss_thresh __maybe_unused = 96;",
    "stock policer loss threshold",
)
source = replace_once(
    source,
    "static const u32 bbr_lt_bw_max_rtts = 48;",
    "static const u32 bbr_lt_bw_max_rtts __maybe_unused = 24;",
    "stock policer duration",
)
for legacy_const in (
    "static const u32 bbr_lt_intvl_min_rtts = 4;",
    "static const u32 bbr_lt_bw_ratio = BBR_UNIT / 8;",
    "static const u32 bbr_lt_bw_diff = 4000 / 8;",
):
    if legacy_const in source:
        source = replace_once(
            source,
            legacy_const,
            legacy_const.replace(" = ", " __maybe_unused = ", 1),
            f"legacy policer constant {legacy_const}",
        )
source = replace_once(
    source,
    "static const int bbr_pacing_margin_percent = 1;",
    "static const int bbr_pacing_margin_percent = 0;",
    "stock pacing margin",
)

# Keep probing simple and throughput-first while ensuring drain stability:
# STARTUP uses a 12.5% growth threshold with three flat confirmation rounds.
# ProbeBW probes at 1.50x and drains at 0.625x (5/8), guaranteeing that even
# at the 1.50x Pixie cap the drain wire gain stays strictly below 1.0 (0.9375x).
source = replace_once(
    source,
    "static const u32 bbr_full_bw_thresh = BBR_UNIT * 5 / 4;",
    "static const u32 bbr_full_bw_thresh = BBR_UNIT * 9 / 8;",
    "BBRv1 STARTUP growth threshold",
)
require_once(
    source,
    "static const u32 bbr_full_bw_cnt = 3;",
    "BBRv1 STARTUP no-growth rounds",
)
source = replace_once(
    source,
    "\tBBR_UNIT * 5 / 4,\t/* probe for more available bw */",
    "\tBBR_UNIT * 3 / 2,\t/* aggressively probe for more available bw */",
    "BBRv1 ProbeBW probe gain",
)
source = replace_once(
    source,
    "\tBBR_UNIT * 3 / 4,\t/* drain queue and/or yield bw to other flows */",
    "\tBBR_UNIT * 5 / 8,\t/* drain queue symmetrically even under Pixie cap */",
    "BBRv1 ProbeBW drain gain",
)
source = replace_once(
    source,
    "static const u32 bbr_cwnd_min_target = 4;",
    "static const u32 bbr_cwnd_min_target = 4;\n"
    "/* Target half-BDP cwnd during PROBE_RTT (BBRv2/v3 style) to drain queues\n"
    " * without collapsing throughput or triggering tail-loss RTOs.\n"
    " */\n"
    "static const int bbr_probe_rtt_cwnd_gain = BBR_UNIT / 2;",
    "BBRv1 PROBE_RTT cwnd gain",
)

new_state = '''\tu32     mode:3,\t\t     /* current bbr_mode in state machine */
\t\tprev_ca_state:3,     /* CA state on previous ACK */
\t\tpacket_conservation:1,  /* retained ABI bit; forced off */
\t\tround_start:1,\t     /* start of packet-timed tx->ack round? */
\t\tidle_restart:1,\t     /* restarting after idle? */
\t\tprobe_rtt_round_done:1,  /* a BBR_PROBE_RTT round done? */
\t\tpixie_active:1,\t     /* loss compensation is active */
\t\tpixie_round_head:2,  /* newest completed feedback round */
\t\tpixie_round_count:3, /* valid completed feedback rounds */
\t\tpixie_gain_cached:10,/* cached Pixie gain in [256..384] */
\t\tunused:6;
\tu32\tpixie_rounds[2];  /* four packed completed feedback rounds */
\tu32\tpixie_round_acked;   /* ACKed packets in current round */
\tu32\tpixie_round_lost;    /* lost packets in current round */
'''
source = replace_bbr_private_state(source, new_state)

old_bw = '''/* Return the estimated bandwidth of the path, in pkts/uS << BW_SCALE. */
static u32 bbr_bw(const struct sock *sk)
{
\tstruct bbr *bbr = inet_csk_ca(sk);

\treturn bbr->lt_use_bw ? bbr->lt_bw : bbr_max_bw(sk);
}
'''
new_bw = '''/* Return the estimated delivered bandwidth of the path. */
static u32 bbr_bw(const struct sock *sk)
{
\treturn bbr_max_bw(sk);
}

static u32 bbr_u32_add_sat(u32 value, u32 delta)
{
\treturn min_t(u64, (u64)value + delta, U32_MAX);
}

#define BBR_PIXIE_MAX_RTTS 4
#define BBR_PIXIE_MIN_SAMPLES 32
#define BBR_PIXIE_LOSS_SCALE 12
#define BBR_PIXIE_LOSS_UNIT (1U << BBR_PIXIE_LOSS_SCALE)
#define BBR_PIXIE_LOSS_MASK (BBR_PIXIE_LOSS_UNIT - 1)
#define BBR_PIXIE_ROUND_VALID (1U << 15)
#define BBR_PIXIE_DEADBAND_DENOM 200

static const u32 bbr_pixie_max_gain = (BBR_UNIT * 3) / 2;
static const u32 bbr_pixie_probe_max_gain = (BBR_UNIT * 15) / 8;
static const u32 bbr_pixie_cwnd_max_gain = (BBR_UNIT * 5) / 2;

static u16 bbr_pixie_get_round(const struct bbr *bbr, u32 index)
{
\tu32 shift = (index & 1) * 16;

\treturn (bbr->pixie_rounds[index >> 1] >> shift) & U16_MAX;
}

static void bbr_pixie_set_round(struct bbr *bbr, u32 index, u16 value)
{
\tu32 shift = (index & 1) * 16;
\tu32 mask = (u32)U16_MAX << shift;
\tu32 *word = &bbr->pixie_rounds[index >> 1];

\t*word = (*word & ~mask) | ((u32)value << shift);
}

static void bbr_reset_pixie_feedback(struct sock *sk)
{
\tstruct bbr *bbr = inet_csk_ca(sk);

\tbbr->pixie_rounds[0] = 0;
\tbbr->pixie_rounds[1] = 0;
\tbbr->pixie_active = 0;
\tbbr->pixie_round_head = 0;
\tbbr->pixie_round_count = 0;
\tbbr->pixie_gain_cached = BBR_UNIT;
\tbbr->pixie_round_acked = 0;
\tbbr->pixie_round_lost = 0;
}

/* Encode one completed ProbeBW RTT in a 16-bit Q12 loss-ratio bucket.
 * Undersized rounds (< BBR_PIXIE_MIN_SAMPLES) are ignored so keepalive or
 * sparse interactive traffic cannot evict loaded rounds. Losses below the
 * 0.5% deadband are treated as clean to prevent single-packet noise on
 * high-BDP paths from locking compensation on.
 */
static u16 bbr_pixie_pack_round(u32 acked, u32 lost)
{
\tu64 total = (u64)acked + lost;
\tu32 loss_q12;

\tif (total < BBR_PIXIE_MIN_SAMPLES)
\t\treturn 0;
\tif (!lost || (u64)lost * BBR_PIXIE_DEADBAND_DENOM < total)
\t\treturn BBR_PIXIE_ROUND_VALID;
\tloss_q12 = div64_u64((u64)lost * BBR_PIXIE_LOSS_UNIT + total / 2, total);
\tif (!loss_q12)
\t\tloss_q12 = 1;
\tif (loss_q12 >= BBR_PIXIE_LOSS_UNIT)
\t\tloss_q12 = BBR_PIXIE_LOSS_UNIT - 1;
\treturn (u16)(BBR_PIXIE_ROUND_VALID | loss_q12);
}

static void bbr_pixie_collect_rounds(const struct bbr *bbr, u32 rounds,
\t\t\t\t     u32 *valid_rounds, u32 *loss_sum)
{
\tu32 i;

\t*valid_rounds = 0;
\t*loss_sum = 0;
\trounds = min(rounds, (u32)bbr->pixie_round_count);
\tfor (i = 0; i < rounds; i++) {
\t\tu32 index = (bbr->pixie_round_head - i) &
\t\t\t    (BBR_PIXIE_MAX_RTTS - 1);
\t\tu16 packed = bbr_pixie_get_round(bbr, index);

\t\tif (!(packed & BBR_PIXIE_ROUND_VALID))
\t\t\tcontinue;
\t\t(*valid_rounds)++;
\t\t*loss_sum += packed & BBR_PIXIE_LOSS_MASK;
\t}
}

/* Recompute and cache the bounded Pixie multiplier once per completed RTT so
 * the per-ACK pacing/cwnd hot path performs zero loops and zero divisions.
 */
static void bbr_pixie_recompute_gain(struct bbr *bbr)
{
\tu32 valid_rounds, loss_sum, denom, gain;

\tif (!bbr->pixie_active || !bbr->pixie_round_count) {
\t\tbbr->pixie_gain_cached = BBR_UNIT;
\t\treturn;
\t}
\tbbr_pixie_collect_rounds(bbr, BBR_PIXIE_MAX_RTTS,
\t\t\t\t &valid_rounds, &loss_sum);
\tif (!valid_rounds || !loss_sum) {
\t\tbbr->pixie_gain_cached = BBR_UNIT;
\t\treturn;
\t}
\tdenom = valid_rounds * BBR_PIXIE_LOSS_UNIT;
\tif (loss_sum >= denom) {
\t\tbbr->pixie_gain_cached = bbr_pixie_max_gain;
\t\treturn;
\t}
\tgain = (denom * BBR_UNIT) / (denom - loss_sum);
\tbbr->pixie_gain_cached = clamp_t(u32, gain, BBR_UNIT,
\t\t\t\t\t bbr_pixie_max_gain);
}

static void bbr_pixie_update_active(struct bbr *bbr)
{
\tu32 valid_rounds, loss_sum;

\tif (!bbr->pixie_round_count) {
\t\tbbr->pixie_active = 0;
\t\tbbr->pixie_gain_cached = BBR_UNIT;
\t\treturn;
\t}
\tif (!bbr->pixie_active) {
\t\t/* Enter quickly from the newest complete ProbeBW RTT. */
\t\tbbr_pixie_collect_rounds(bbr, 1, &valid_rounds, &loss_sum);
\t\tif (valid_rounds && loss_sum)
\t\t\tbbr->pixie_active = 1;
\t\tbbr_pixie_recompute_gain(bbr);
\t\treturn;
\t}

\t/* Exit only after four complete RTTs remain below the deadband. */
\tif (bbr->pixie_round_count >= BBR_PIXIE_MAX_RTTS) {
\t\tbbr_pixie_collect_rounds(bbr, BBR_PIXIE_MAX_RTTS,
\t\t\t\t\t &valid_rounds, &loss_sum);
\t\tif (valid_rounds >= BBR_PIXIE_MAX_RTTS && !loss_sum)
\t\t\tbbr->pixie_active = 0;
\t}
\tbbr_pixie_recompute_gain(bbr);
}

static void bbr_pixie_store_completed_round(struct bbr *bbr)
{
\tu16 packed = bbr_pixie_pack_round(bbr->pixie_round_acked,
\t\t\t\t\tbbr->pixie_round_lost);

\tif (!packed)
\t\treturn;
\tif (bbr->pixie_round_count)
\t\tbbr->pixie_round_head = (bbr->pixie_round_head + 1) &
\t\t\t\t\t(BBR_PIXIE_MAX_RTTS - 1);
\tbbr_pixie_set_round(bbr, bbr->pixie_round_head, packed);
\tif (bbr->pixie_round_count < BBR_PIXIE_MAX_RTTS)
\t\tbbr->pixie_round_count++;
\tbbr_pixie_update_active(bbr);
}

/* O(1) hot-path read of the cached Pixie loss-compensation multiplier. */
static u32 bbr_pixie_gain(const struct sock *sk)
{
\tconst struct bbr *bbr = inet_csk_ca(sk);

\treturn bbr->pixie_active ? bbr->pixie_gain_cached : BBR_UNIT;
}

/* Apply phase-aware Pixie pacing compensation:
 * - STARTUP, DRAIN, and PROBE_RTT never stack Pixie (prevents 4.33x startup
 *   overflows and min_rtt measurement distortion).
 * - ProbeBW Probe caps combined gain at 1.875x instead of 2.25x.
 * - ProbeBW Drain (0.625x) stays <= 0.9375x even at the 1.5x Pixie cap.
 * - ProbeBW Cruise applies the full bounded Pixie multiplier (up to 1.5x).
 */
static int bbr_effective_pacing_gain(const struct sock *sk, int gain)
{
\tconst struct bbr *bbr = inet_csk_ca(sk);
\tu32 pixie = bbr_pixie_gain(sk);
\tu64 combined;

\tif (pixie <= BBR_UNIT || bbr->mode != BBR_PROBE_BW)
\t\treturn gain;
\tcombined = ((u64)gain * pixie) >> BBR_SCALE;
\tif (gain > BBR_UNIT)
\t\tcombined = min_t(u64, combined, bbr_pixie_probe_max_gain);
\treturn (int)combined;
}

static int bbr_effective_cwnd_gain(const struct sock *sk, int gain)
{
\tconst struct bbr *bbr = inet_csk_ca(sk);
\tu32 pixie = bbr_pixie_gain(sk);
\tu64 combined;

\tif (pixie <= BBR_UNIT || bbr->mode != BBR_PROBE_BW)
\t\treturn gain;
\tcombined = ((u64)gain * pixie) >> BBR_SCALE;
\treturn (int)min_t(u64, combined, bbr_pixie_cwnd_max_gain);
}
'''
source = replace_once(source, old_bw, new_bw, "BBRv1 bandwidth selector")

old_pacing = '''static unsigned long bbr_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain)
{
\tu64 rate = bw;

\trate = bbr_rate_bytes_per_sec(sk, rate, gain);
\trate = min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate));
\treturn rate;
}
'''
new_pacing = '''static unsigned long bbr_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain)
{
\tu64 rate = bw;

\tgain = bbr_effective_pacing_gain(sk, gain);
\trate = bbr_rate_bytes_per_sec(sk, rate, gain);
\trate = min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate));
\treturn rate;
}
'''
source = replace_once(source, old_pacing, new_pacing, "BBRv1 pacing conversion")

source = replace_once(
    source,
    '''\tif (tp->app_limited) {
\t\tbbr->idle_restart = 1;
\t\tbbr->ack_epoch_mstamp = tp->tcp_mstamp;
\t\tbbr->ack_epoch_acked = 0;
''',
    '''\tif (tp->app_limited) {
\t\tbbr->idle_restart = 1;
\t\tbbr->ack_epoch_mstamp = tp->tcp_mstamp;
\t\tbbr->ack_epoch_acked = 0;
\t\tbbr_reset_pixie_feedback(sk);
''',
    "BBRv1 idle restart feedback reset",
)

old_bdp_fn = '''static u32 bbr_bdp(struct sock *sk, u32 bw, int gain)
{
\tstruct bbr *bbr = inet_csk_ca(sk);
\tu32 bdp;
\tu64 w;

\t/* If we've never had a valid RTT sample, cap cwnd at the initial
\t * default. This should only happen when the connection is not using TCP
\t * timestamps and has retransmitted all of the SYN/SYNACK/data packets
\t * ACKed so far. In this case, an RTO can cut cwnd to 1, in which
\t * case we need to slow-start up toward something safe: TCP_INIT_CWND.
\t */
\tif (unlikely(bbr->min_rtt_us == ~0U))	 /* no valid RTT samples yet? */
\t\treturn TCP_INIT_CWND;  /* be safe: cap at default initial cwnd*/

\tw = (u64)bw * bbr->min_rtt_us;

\t/* Apply a gain to the given value, remove the BW_SCALE shift, and
\t * round the value up to avoid a negative feedback loop.
\t */
\tbdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;

\treturn bdp;
}
'''
new_bdp_fn = '''static u32 bbr_bdp_raw(struct sock *sk, u32 bw, int gain)
{
\tstruct bbr *bbr = inet_csk_ca(sk);
\tu64 w, bdp;

\t/* If we've never had a valid RTT sample, cap cwnd at the initial
\t * default. This should only happen when the connection is not using TCP
\t * timestamps and has retransmitted all of the SYN/SYNACK/data packets
\t * ACKed so far. In this case, an RTO can cut cwnd to 1, in which
\t * case we need to slow-start up toward something safe: TCP_INIT_CWND.
\t */
\tif (unlikely(bbr->min_rtt_us == ~0U))\t /* no valid RTT samples yet? */
\t\treturn TCP_INIT_CWND;  /* be safe: cap at default initial cwnd*/

\tw = (u64)bw * bbr->min_rtt_us;

\t/* Apply a gain to the given value, remove the BW_SCALE shift, and
\t * round the value up to avoid a negative feedback loop.
\t */
\tbdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;

\treturn min_t(u64, bdp, U32_MAX);
}

static u32 bbr_bdp(struct sock *sk, u32 bw, int gain)
{
\treturn bbr_bdp_raw(sk, bw, bbr_effective_cwnd_gain(sk, gain));
}

static u32 bbr_probe_rtt_cwnd(struct sock *sk)
{
\treturn max(bbr_bdp_raw(sk, bbr_bw(sk), bbr_probe_rtt_cwnd_gain),
\t\t   bbr_cwnd_min_target);
}
'''
source = replace_once(source, old_bdp_fn, new_bdp_fn, "BBRv1 BDP calculation")

source = replace_once(
    source,
    '''\t/* Allow enough full-sized skbs in flight to utilize end systems. */
\tcwnd += 3 * bbr_tso_segs_goal(sk);

\t/* Reduce delayed ACKs by rounding up cwnd to the next even number. */
\tcwnd = (cwnd + 1) & ~1U;

\t/* Ensure gain cycling gets inflight above BDP even for small BDPs. */
\tif (bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == 0)
\t\tcwnd += 2;
''',
    '''\t/* Allow enough full-sized skbs in flight to utilize end systems. */
\tcwnd = bbr_u32_add_sat(cwnd, 3 * bbr_tso_segs_goal(sk));

\t/* Reduce delayed ACKs by rounding up cwnd to the next even number. */
\tif (cwnd == U32_MAX)
\t\tcwnd = U32_MAX - 1;
\telse
\t\tcwnd = (cwnd + 1) & ~1U;

\t/* Ensure gain cycling gets inflight above BDP even for small BDPs. */
\tif (bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == 0)
\t\tcwnd = bbr_u32_add_sat(cwnd, 2);
''',
    "BBRv1 quantization cwnd additions",
)

old_inflight = '''/* Find inflight based on min RTT and the estimated bottleneck bandwidth. */
static u32 bbr_inflight(struct sock *sk, u32 bw, int gain)
{
\tu32 inflight;

\tinflight = bbr_bdp(sk, bw, gain);
\tinflight = bbr_quantization_budget(sk, inflight);

\treturn inflight;
}
'''
new_inflight = '''/* Find un-compensated inflight based on min RTT and bottleneck bandwidth. */
static u32 bbr_inflight_raw(struct sock *sk, u32 bw, int gain)
{
\tu32 inflight;

\tinflight = bbr_bdp_raw(sk, bw, gain);
\tinflight = bbr_quantization_budget(sk, inflight);

\treturn inflight;
}
'''
source = replace_once(source, old_inflight, new_inflight, "BBRv1 inflight helper")

source = replace_once(
    source,
    '''\tif (bbr->pacing_gain > BBR_UNIT)              /* increasing inflight */
\t\tinflight_at_edt += bbr_tso_segs_goal(sk);  /* include EDT skb */
''',
    '''\tif (bbr->pacing_gain > BBR_UNIT)              /* increasing inflight */
\t\tinflight_at_edt = bbr_u32_add_sat(         /* include EDT skb */
\t\t\tinflight_at_edt, bbr_tso_segs_goal(sk));
''',
    "BBRv1 EDT inflight addition",
)
source = replace_once(
    source,
    '''\t\tmax_aggr_cwnd = ((u64)bbr_bw(sk) * bbr_extra_acked_max_us)
\t\t\t\t/ BW_UNIT;
''',
    '''\t\tmax_aggr_cwnd = min_t(u64,
\t\t\t((u64)bbr_bw(sk) * bbr_extra_acked_max_us) / BW_UNIT,
\t\t\tU32_MAX);
''',
    "BBRv1 ACK aggregation maximum",
)

pixie_feedback = '''/* Update adaptive completed-round Pixie feedback during steady-state ProbeBW. */
static void bbr_update_pixie_feedback(struct sock *sk,
\t\t\t\t      const struct rate_sample *rs)
{
\tstruct bbr *bbr = inet_csk_ca(sk);

\t/* Ignore STARTUP/DRAIN queue-overflow losses and PROBE_RTT low-flight
\t * rounds so self-inflicted overshoot or min-RTT dips cannot poison the
\t * four-RTT loss-compensation history.
\t */
\tif (bbr->mode != BBR_PROBE_BW) {
\t\tbbr->pixie_round_acked = 0;
\t\tbbr->pixie_round_lost = 0;
\t\treturn;
\t}
\t/* The ACK that starts a new BBR round belongs to the new round. */
\tif (bbr->round_start) {
\t\tbbr_pixie_store_completed_round(bbr);
\t\tbbr->pixie_round_acked = 0;
\t\tbbr->pixie_round_lost = 0;
\t}
\tif (rs->acked_sacked > 0)
\t\tbbr->pixie_round_acked = bbr_u32_add_sat(
\t\t\tbbr->pixie_round_acked, rs->acked_sacked);
\tif (rs->losses > 0)
\t\tbbr->pixie_round_lost = bbr_u32_add_sat(
\t\t\tbbr->pixie_round_lost, rs->losses);
}

'''
source = replace_span(
    source,
    "/* Start a new long-term sampling interval. */",
    "/* Estimate the bandwidth based on how fast packets are delivered */",
    pixie_feedback,
    "BBRv1 long-term policer implementation",
)
source = replace_once(
    source,
    "\tbbr_lt_bw_sampling(sk, rs);",
    "\tbbr_update_pixie_feedback(sk, rs);",
    "BBRv1 policer sampling call",
)

new_recovery = '''static bool bbr_set_cwnd_to_recover_or_restore(
\tstruct sock *sk, const struct rate_sample *rs, u32 acked, u32 *new_cwnd)
{
\tstruct tcp_sock *tp = tcp_sk(sk);
\tstruct bbr *bbr = inet_csk_ca(sk);
\tu8 prev_state = bbr->prev_ca_state, state = inet_csk(sk)->icsk_ca_state;
\tu32 cwnd = tcp_snd_cwnd(tp);

\t/* Pixie compensation owns the loss response. Keep TCP recovery and
\t * retransmission machinery, but do not subtract losses or enter BBR's
\t * packet-conservation cwnd path.
\t */
\tif (prev_state >= TCP_CA_Recovery && state < TCP_CA_Recovery)
\t\tcwnd = max(cwnd, bbr->prior_cwnd);
\tbbr->prev_ca_state = state;
\tbbr->packet_conservation = 0;
\t*new_cwnd = cwnd;
\treturn false;
}

'''
source = replace_span(
    source,
    "static bool bbr_set_cwnd_to_recover_or_restore(",
    "/* Slow-start up toward target cwnd",
    new_recovery,
    "BBRv1 recovery cwnd function",
)
source = replace_once(
    source,
    "\ttarget_cwnd += bbr_ack_aggregation_cwnd(sk);",
    "\ttarget_cwnd = bbr_u32_add_sat(\n"
    "\t\ttarget_cwnd, bbr_ack_aggregation_cwnd(sk));",
    "BBRv1 ACK aggregation target addition",
)
source = replace_once(
    source,
    '''\tif (bbr_full_bw_reached(sk))  /* only cut cwnd if we filled the pipe */
\t\tcwnd = min(cwnd + acked, target_cwnd);
\telse if (cwnd < target_cwnd || tp->delivered < TCP_INIT_CWND)
\t\tcwnd = cwnd + acked;
''',
    '''\tif (bbr_full_bw_reached(sk))  /* only cut cwnd if we filled the pipe */
\t\tcwnd = min(bbr_u32_add_sat(cwnd, acked), target_cwnd);
\telse if (cwnd < target_cwnd || tp->delivered < TCP_INIT_CWND)
\t\tcwnd = bbr_u32_add_sat(cwnd, acked);
''',
    "BBRv1 gradual cwnd growth",
)
source = replace_once(
    source,
    '''\tif (bbr->mode == BBR_PROBE_RTT)  /* drain queue, refresh min_rtt */
\t\ttcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), bbr_cwnd_min_target));
''',
    '''\tif (bbr->mode == BBR_PROBE_RTT)  /* drain queue, refresh min_rtt */
\t\ttcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), bbr_probe_rtt_cwnd(sk)));
''',
    "BBRv1 PROBE_RTT cwnd cap",
)

old_cycle_phase = '''\tif (bbr->pacing_gain > BBR_UNIT)
\t\treturn is_full_length &&
\t\t\t(rs->losses ||  /* perhaps pacing_gain*BDP won't fit */
\t\t\t inflight >= bbr_inflight(sk, bw, bbr->pacing_gain));

\t/* A pacing_gain < 1.0 tries to drain extra queue we added if bw
\t * probing didn't find more bw. If inflight falls to match BDP then we
\t * estimate queue is drained; persisting would underutilize the pipe.
\t */
\treturn is_full_length ||
\t\tinflight <= bbr_inflight(sk, bw, BBR_UNIT);
'''
new_cycle_phase = '''\tif (bbr->pacing_gain > BBR_UNIT)
\t\treturn is_full_length &&
\t\t\t(rs->losses ||  /* perhaps pacing_gain*BDP won't fit */
\t\t\t inflight >= bbr_inflight_raw(
\t\t\t\tsk, bw,
\t\t\t\tbbr_effective_pacing_gain(sk, bbr->pacing_gain)));

\t/* A pacing_gain < 1.0 tries to drain extra queue we added if bw
\t * probing didn't find more bw. When RTT shows standing queue buildup
\t * (> 1.125 * min_rtt), drain toward raw BDP so congestion-triggered
\t * Pixie gain cannot exit Drain immediately. On clean random-loss paths
\t * with no standing queue, exit at the compensated BDP target to keep
\t * throughput high.
\t */
\tif (tp->srtt_us && bbr->min_rtt_us != ~0U &&
\t    (tp->srtt_us >> 3) > bbr->min_rtt_us + (bbr->min_rtt_us >> 3))
\t\treturn is_full_length ||
\t\t\tinflight <= bbr_inflight_raw(sk, bw, BBR_UNIT);
\treturn is_full_length ||
\t\tinflight <= bbr_inflight_raw(
\t\t\tsk, bw, bbr_effective_pacing_gain(sk, BBR_UNIT));
'''
source = replace_once(source, old_cycle_phase, new_cycle_phase, "BBRv1 cycle phase exit")
source = replace_check_drain(source)

source = replace_once(
    source,
    '''\t\tif (!bbr->probe_rtt_done_stamp &&
\t\t    tcp_packets_in_flight(tp) <= bbr_cwnd_min_target) {
''',
    '''\t\tif (!bbr->probe_rtt_done_stamp &&
\t\t    tcp_packets_in_flight(tp) <= bbr_probe_rtt_cwnd(sk)) {
''',
    "BBRv1 PROBE_RTT inflight trigger",
)

source = replace_once(
    source,
    '''\tcase BBR_PROBE_BW:
\t\tbbr->pacing_gain = (bbr->lt_use_bw ?
\t\t\t\t    BBR_UNIT :
\t\t\t\t    bbr_pacing_gain[bbr->cycle_idx]);
\t\tbbr->cwnd_gain\t = bbr_cwnd_gain;
\t\tbreak;
''',
    '''\tcase BBR_PROBE_BW:
\t\tbbr->pacing_gain = bbr_pacing_gain[bbr->cycle_idx];
\t\tbbr->cwnd_gain\t = bbr_cwnd_gain;
\t\tbreak;
''',
    "BBRv1 ProbeBW policer gain selection",
)
source = replace_once(
    source,
    '''\tminmax_reset(&bbr->bw, bbr->rtt_cnt, 0);  /* init max bw to 0 */

\tbbr->has_seen_rtt = 0;
''',
    '''\tminmax_reset(&bbr->bw, bbr->rtt_cnt, 0);  /* init max bw to 0 */
\tbbr_reset_pixie_feedback(sk);

\tbbr->has_seen_rtt = 0;
''',
    "BBRv1 early Pixie initialization",
)
source = replace_once(
    source,
    "\tbbr->cycle_idx = 0;\n\tbbr_reset_lt_bw_sampling(sk);\n\tbbr_reset_startup_mode(sk);",
    "\tbbr->cycle_idx = 0;\n\tbbr_reset_startup_mode(sk);",
    "BBRv1 policer initialization removal",
)
source = replace_once(
    source,
    "\tbbr->full_bw_cnt = 0;\n\tbbr_reset_lt_bw_sampling(sk);\n"
    "\treturn tcp_snd_cwnd(tcp_sk(sk));",
    "\tbbr->full_bw_cnt = 0;\n\treturn tcp_snd_cwnd(tcp_sk(sk));",
    "BBRv1 undo policer reset",
)
source = replace_once(
    source,
    '''\tif (new_state == TCP_CA_Loss) {
\t\tstruct rate_sample rs = { .losses = 1 };

\t\tbbr->prev_ca_state = TCP_CA_Loss;
\t\tbbr->full_bw = 0;
\t\tbbr->round_start = 1;\t/* treat RTO like end of a round */
\t\tbbr_lt_bw_sampling(sk, &rs);
\t}
''',
    '''\tif (new_state == TCP_CA_Loss) {
\t\tbbr->prev_ca_state = TCP_CA_Loss;
\t\tbbr->full_bw = 0;
\t\tbbr->round_start = 1;\t/* treat RTO like end of a round */
\t}
''',
    "BBRv1 loss-state policer hook",
)
source = replace_once(
    source,
    'MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)");',
    'MODULE_DESCRIPTION("TCP BBR with aggressive probing and Pixie loss compensation");',
    "BBR module description",
)

for forbidden in [
    "lt_use_bw",
    "lt_is_sampling",
    "bbr_lt_bw_sampling(",
    "bbr_reset_lt_bw_sampling(",
    "bbr_reset_lt_bw_sampling_interval(",
    "cwnd = target_cwnd;",
    "pixie_acked -=",
    "pixie_lost -=",
    "prev_total > curr_total",
    "bbr_inflight(",
]:
    if forbidden in source:
        fail(f"stale or unsafe BBRv1 state remains: {forbidden}")
for required in [
    "static const int bbr_bw_rtts = CYCLE_LEN + 2;",
    "static const u32 bbr_min_rtt_win_sec = 15;",
    "static const u32 bbr_full_bw_thresh = BBR_UNIT * 9 / 8;",
    "static const u32 bbr_full_bw_cnt = 3;",
    "static const int bbr_probe_rtt_cwnd_gain = BBR_UNIT / 2;",
    "BBR_UNIT * 3 / 2,\t/* aggressively probe for more available bw */",
    "BBR_UNIT * 5 / 8,\t/* drain queue symmetrically even under Pixie cap */",
    "pixie_gain_cached:10",
    "bbr_pixie_gain",
    "bbr_pixie_recompute_gain",
    "bbr_effective_pacing_gain",
    "bbr_effective_cwnd_gain",
    "bbr_bdp_raw",
    "bbr_inflight_raw",
    "bbr_probe_rtt_cwnd",
    "bbr_reset_pixie_feedback",
    "bbr_update_pixie_feedback",
    "bbr_u32_add_sat",
    "bbr_pixie_max_gain",
    "bbr_pixie_probe_max_gain",
    "bbr_pixie_cwnd_max_gain",
    "BBR_PIXIE_MAX_RTTS",
    "BBR_PIXIE_MIN_SAMPLES",
    "BBR_PIXIE_DEADBAND_DENOM",
    "bbr_pixie_pack_round",
    "bbr_pixie_store_completed_round",
    "bbr_pixie_update_active",
    "bbr_pixie_collect_rounds",
    "bbr->pixie_active",
    "min(bbr_u32_add_sat(cwnd, acked), target_cwnd)",
]:
    if source.count(required) < 1:
        fail(f"missing aggressive BBR output marker: {required}")

source_path.write_text(source)
tuned_sha256 = hashlib.sha256(source.encode()).hexdigest()

if provenance_path:
    provenance_path.write_text(
        f"BBR_STOCK_SOURCE_SHA256={stock_sha256}\n"
        f"BBR_TUNED_SOURCE_SHA256={tuned_sha256}\n"
        "BBR_BW_RTTS=10\n"
        "BBR_MIN_RTT_WIN_SEC=15\n"
        "BBR_PROBE_RTT_CWND_GAIN_PERCENT=50\n"
        "BBR_STARTUP_GROWTH_NUMERATOR=9\n"
        "BBR_STARTUP_GROWTH_DENOMINATOR=8\n"
        "BBR_STARTUP_NO_GROWTH_RTTS=3\n"
        "BBR_PROBE_BW_GAIN_PERCENT=150\n"
        "BBR_PROBE_BW_DRAIN_PERCENT=62\n"
        "BBR_LT_LOSS_THRESH=96\n"
        "BBR_LT_BW_MAX_RTTS=24\n"
        "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1\n"
        "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4\n"
        "BBR_PIXIE_MIN_SAMPLES=32\n"
        "BBR_PIXIE_DEADBAND_BPS=50\n"
        "BBR_PIXIE_FEEDBACK_WINDOW=adaptive_hysteresis_q12_probe_bw_rounds\n"
        "BBR_PIXIE_MAX_GAIN_PERCENT=150\n"
        "BBR_PIXIE_PROBE_MAX_GAIN_PERCENT=187\n"
        "BBR_PIXIE_CWND_MAX_GAIN_PERCENT=250\n"
        "BBR_PIXIE_HOTPATH_CACHED=1\n"
        "BBR_PIXIE_IDLE_RESET=1\n"
        "BBR_PIXIE_PACING_COMPENSATION=1\n"
        "BBR_PIXIE_CWND_COMPENSATION=1\n"
        "BBR_PIXIE_CWND_SATURATING_ARITHMETIC=1\n"
        "BBR_PIXIE_CWND_GRADUAL_GROWTH=1\n"
        "BBR_PIXIE_POLICER_MODEL=0\n"
        "BBR_PIXIE_PACKET_CONSERVATION=0\n"
        "BBR_PACING_MARGIN_PERCENT=0\n"
    )

print(
    "Applied aggressive BBRv1 tuning (rev6): 0.5*BDP PROBE_RTT (15s), "
    "12.5% STARTUP growth, 1.50x/0.625x ProbeBW, phase-decoupled cached "
    "Q12 Pixie compensation (0.5% deadband, 1.50x cap), and queue-aware drain."
)
