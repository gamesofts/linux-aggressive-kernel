#!/usr/bin/env python3
"""Port Pixie's loss compensation into Linux BBRv1."""

import hashlib
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
source = replace_once(
    source,
    "static const int bbr_pacing_margin_percent = 1;",
    "static const int bbr_pacing_margin_percent = 0;",
    "stock pacing margin",
)

old_state = '''\tu32     mode:3,\t\t     /* current bbr_mode in state machine */
\t\tprev_ca_state:3,     /* CA state on previous ACK */
\t\tpacket_conservation:1,  /* use packet conservation? */
\t\tround_start:1,\t     /* start of packet-timed tx->ack round? */
\t\tidle_restart:1,\t     /* restarting after idle? */
\t\tprobe_rtt_round_done:1,  /* a BBR_PROBE_RTT round at 4 pkts? */
\t\tunused:13,
\t\tlt_is_sampling:1,    /* taking long-term ("LT") samples now? */
\t\tlt_rtt_cnt:7,\t     /* round trips in long-term interval */
\t\tlt_use_bw:1;\t     /* use lt_bw as our bw estimate? */
\tu32\tlt_bw;\t\t     /* LT est delivery rate in pkts/uS << 24 */
\tu32\tlt_last_delivered;   /* LT intvl start: tp->delivered */
\tu32\tlt_last_stamp;\t     /* LT intvl start: tp->delivered_mstamp */
\tu32\tlt_last_lost;\t     /* LT intvl start: tp->lost */
'''
new_state = '''\tu32     mode:3,\t\t     /* current bbr_mode in state machine */
\t\tprev_ca_state:3,     /* CA state on previous ACK */
\t\tpacket_conservation:1,  /* retained ABI bit; forced off */
\t\tround_start:1,\t     /* start of packet-timed tx->ack round? */
\t\tidle_restart:1,\t     /* restarting after idle? */
\t\tprobe_rtt_round_done:1,  /* a BBR_PROBE_RTT round at 4 pkts? */
\t\tpixie_active:1,\t     /* loss compensation is active */
\t\tpixie_round_head:2,  /* newest completed feedback round */
\t\tpixie_round_count:3, /* valid completed feedback rounds */
\t\tunused:16;
\tu32\tpixie_rounds[2];  /* four packed completed feedback rounds */
\tu32\tpixie_round_acked;   /* ACKed packets in current round */
\tu32\tpixie_round_lost;    /* lost packets in current round */
'''
source = replace_once(source, old_state, new_state, "BBRv1 private-state block")

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
#define BBR_PIXIE_ROUND_SHIFT 8
#define BBR_PIXIE_ROUND_MASK U8_MAX

static const u32 bbr_pixie_max_gain = (BBR_UNIT * 3) / 2;

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
\tbbr->pixie_round_acked = 0;
\tbbr->pixie_round_lost = 0;
}

/* Store one completed RTT in a compact ratio-preserving bucket. The sample
 * guard uses the true count up to U8_MAX; larger rounds are normalized so all
 * four RTTs can remain in BBR's fixed private-state budget.
 */
static u16 bbr_pixie_pack_round(u32 acked, u32 lost)
{
\tu64 total = (u64)acked + lost;
\tu32 samples, scaled_lost;

\tif (!total)
\t\treturn 0;
\tsamples = min_t(u64, total, U8_MAX);
\tscaled_lost = div64_u64((u64)lost * samples + total / 2, total);
\t/* Preserve whether each completed RTT observed any loss. */
\tif (lost && !scaled_lost)
\t\tscaled_lost = 1;
\tif (acked && scaled_lost >= samples)
\t\tscaled_lost = samples - 1;
\treturn (samples << BBR_PIXIE_ROUND_SHIFT) | scaled_lost;
}

static void bbr_pixie_collect_rounds(const struct bbr *bbr, u32 rounds,
\t\t\t\t     u64 *samples, u64 *losses)
{
\tu32 i;

\t*samples = 0;
\t*losses = 0;
\trounds = min(rounds, (u32)bbr->pixie_round_count);
\tfor (i = 0; i < rounds; i++) {
\t\tu32 index = (bbr->pixie_round_head - i) &
\t\t\t    (BBR_PIXIE_MAX_RTTS - 1);
\t\tu16 packed = bbr_pixie_get_round(bbr, index);

\t\t*samples += packed >> BBR_PIXIE_ROUND_SHIFT;
\t\t*losses += packed & BBR_PIXIE_ROUND_MASK;
\t}
}

static void bbr_pixie_update_active(struct bbr *bbr)
{
\tu64 samples, losses;

\tif (!bbr->pixie_round_count) {
\t\tbbr->pixie_active = 0;
\t\treturn;
\t}
\tif (!bbr->pixie_active) {
\t\t/* Enter quickly from the newest complete RTT. */
\t\tbbr_pixie_collect_rounds(bbr, 1, &samples, &losses);
\t\tif (samples >= BBR_PIXIE_MIN_SAMPLES && losses)
\t\t\tbbr->pixie_active = 1;
\t\treturn;
\t}

\t/* Exit only after four complete RTTs contain no observed loss. */
\tif (bbr->pixie_round_count < BBR_PIXIE_MAX_RTTS)
\t\treturn;
\tbbr_pixie_collect_rounds(bbr, BBR_PIXIE_MAX_RTTS,
\t\t\t\t &samples, &losses);
\tif (samples >= BBR_PIXIE_MIN_SAMPLES && !losses)
\t\tbbr->pixie_active = 0;
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

/* Compensate delivered goodput by the observed wire-loss ratio:
 *
 *   compensation = min((acked + lost) / acked, 1.5)
 *
 * Entry uses one complete packet-timed RTT with at least 32 observations.
 * Once active, every available completed RTT in the four-RTT history is used,
 * and compensation exits only after four completed RTTs show no loss.
 */
static u32 bbr_pixie_gain(const struct sock *sk)
{
\tconst struct bbr *bbr = inet_csk_ca(sk);
\tu64 samples, lost, acked, gain;

\tif (!bbr->pixie_active)
\t\treturn BBR_UNIT;
\tbbr_pixie_collect_rounds(bbr, BBR_PIXIE_MAX_RTTS,
\t\t\t\t &samples, &lost);
\tif (samples < BBR_PIXIE_MIN_SAMPLES || lost >= samples)
\t\treturn BBR_UNIT;
\tacked = samples - lost;
\tgain = div64_u64(samples << BBR_SCALE, acked);
\treturn min_t(u64, max_t(u64, gain, BBR_UNIT),
\t\t     bbr_pixie_max_gain);
}

static u64 bbr_apply_pixie_gain(u64 value, u32 gain)
{
\tif (gain <= BBR_UNIT)
\t\treturn value;
\tif (value > U64_MAX / gain)
\t\treturn U64_MAX;
\treturn (value * gain) >> BBR_SCALE;
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

\trate = bbr_rate_bytes_per_sec(sk, rate, gain);
\trate = bbr_apply_pixie_gain(rate, bbr_pixie_gain(sk));
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

old_bdp_tail = '''\tbdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;

\treturn bdp;
}
'''
new_bdp_tail = '''\tbdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;
\tw = bbr_apply_pixie_gain(bdp, bbr_pixie_gain(sk));

\treturn min_t(u64, w, U32_MAX);
}
'''
source = replace_once(source, old_bdp_tail, new_bdp_tail, "BBRv1 BDP return")

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

pixie_feedback = '''/* Update adaptive completed-round Pixie feedback. */
static void bbr_update_pixie_feedback(struct sock *sk,
\t\t\t\t      const struct rate_sample *rs)
{
\tstruct bbr *bbr = inet_csk_ca(sk);

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
    'MODULE_DESCRIPTION("TCP BBR with Pixie loss compensation");',
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
]:
    if forbidden in source:
        fail(f"stale or unsafe BBRv1 state remains: {forbidden}")
for required in [
    "static const int bbr_bw_rtts = CYCLE_LEN + 2;",
    "bbr_pixie_gain",
    "bbr_apply_pixie_gain",
    "bbr_reset_pixie_feedback",
    "bbr_update_pixie_feedback",
    "bbr_u32_add_sat",
    "bbr_pixie_max_gain",
    "BBR_PIXIE_MAX_RTTS",
    "BBR_PIXIE_MIN_SAMPLES",
    "bbr_pixie_pack_round",
    "bbr_pixie_store_completed_round",
    "bbr_pixie_update_active",
    "bbr_pixie_collect_rounds",
    "bbr->pixie_active",
    "min(bbr_u32_add_sat(cwnd, acked), target_cwnd)",
]:
    if source.count(required) < 1:
        fail(f"missing Pixie output marker: {required}")

source_path.write_text(source)
tuned_sha256 = hashlib.sha256(source.encode()).hexdigest()

if provenance_path:
    provenance_path.write_text(
        f"BBR_STOCK_SOURCE_SHA256={stock_sha256}\n"
        f"BBR_TUNED_SOURCE_SHA256={tuned_sha256}\n"
        "BBR_BW_RTTS=10\n"
        "BBR_LT_LOSS_THRESH=96\n"
        "BBR_LT_BW_MAX_RTTS=24\n"
        "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1\n"
        "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4\n"
        "BBR_PIXIE_MIN_SAMPLES=32\n"
        "BBR_PIXIE_FEEDBACK_WINDOW=adaptive_hysteresis_completed_rounds\n"
        "BBR_PIXIE_MAX_GAIN_PERCENT=150\n"
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
    "Applied BBRv1 Pixie compensation: one-RTT entry, four-RTT exit, "
    "32-sample guard, 1.5x gain cap, idle reset, gradual cwnd growth, "
    "and saturating cwnd arithmetic."
)
