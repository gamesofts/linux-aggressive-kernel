#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aggressive-bbr-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

source_file="$tmp_dir/tcp_bbr.c"
provenance_file="$tmp_dir/provenance.env"
cat > "$source_file" <<'EOF'
#define BBR_SCALE 8
#define BBR_UNIT (1 << BBR_SCALE)
#define BW_UNIT 1
#define CYCLE_LEN 8
struct bbr {
	u32     mode:3,		     /* current bbr_mode in state machine */
		prev_ca_state:3,     /* CA state on previous ACK */
		packet_conservation:1,  /* use packet conservation? */
		round_start:1,	     /* start of packet-timed tx->ack round? */
		idle_restart:1,	     /* restarting after idle? */
		probe_rtt_round_done:1,  /* a BBR_PROBE_RTT round at 4 pkts? */
		unused:13,
		lt_is_sampling:1,    /* taking long-term ("LT") samples now? */
		lt_rtt_cnt:7,	     /* round trips in long-term interval */
		lt_use_bw:1;	     /* use lt_bw as our bw estimate? */
	u32	lt_bw;		     /* LT est delivery rate in pkts/uS << 24 */
	u32	lt_last_delivered;   /* LT intvl start: tp->delivered */
	u32	lt_last_stamp;	     /* LT intvl start: tp->delivered_mstamp */
	u32	lt_last_lost;     /* LT intvl start: tp->lost */
};
static const int bbr_bw_rtts = CYCLE_LEN + 2;
static const int bbr_pacing_margin_percent = 1;
static const u32 bbr_full_bw_thresh = BBR_UNIT * 5 / 4;
static const u32 bbr_full_bw_cnt = 3;
static const int bbr_pacing_gain[] = {
	BBR_UNIT * 5 / 4,	/* probe for more available bw */
	BBR_UNIT * 3 / 4,	/* drain queue and/or yield bw to other flows */
	BBR_UNIT, BBR_UNIT, BBR_UNIT,
	BBR_UNIT, BBR_UNIT, BBR_UNIT
};
/* If lost/delivered ratio > 20%, interval is "lossy" and we may be policed: */
static const u32 bbr_lt_loss_thresh = 50;
static const u32 bbr_lt_bw_max_rtts = 48;

static u32 bbr_max_bw(const struct sock *sk) { return 1; }
/* Return the estimated bandwidth of the path, in pkts/uS << BW_SCALE. */
static u32 bbr_bw(const struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return bbr->lt_use_bw ? bbr->lt_bw : bbr_max_bw(sk);
}

static u64 bbr_rate_bytes_per_sec(struct sock *sk, u64 rate, int gain)
{
	return rate;
}
static unsigned long bbr_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	u64 rate = bw;

	rate = bbr_rate_bytes_per_sec(sk, rate, gain);
	rate = min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate));
	return rate;
}

static void bbr_cwnd_event_tx_start(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (tp->app_limited) {
		bbr->idle_restart = 1;
		bbr->ack_epoch_mstamp = tp->tcp_mstamp;
		bbr->ack_epoch_acked = 0;
	}
}

static u32 bbr_bdp(struct sock *sk, u32 bw, int gain)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 bdp;
	u64 w = bw;
	bdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;

	return bdp;
}

static u32 bbr_quantization_budget(struct sock *sk, u32 cwnd)
{
	struct bbr *bbr = inet_csk_ca(sk);

	/* Allow enough full-sized skbs in flight to utilize end systems. */
	cwnd += 3 * bbr_tso_segs_goal(sk);

	/* Reduce delayed ACKs by rounding up cwnd to the next even number. */
	cwnd = (cwnd + 1) & ~1U;

	/* Ensure gain cycling gets inflight above BDP even for small BDPs. */
	if (bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == 0)
		cwnd += 2;
	return cwnd;
}

static u32 bbr_packets_in_net_at_edt(struct sock *sk, u32 inflight_now)
{
	u32 inflight_at_edt = inflight_now;
	if (bbr->pacing_gain > BBR_UNIT)              /* increasing inflight */
		inflight_at_edt += bbr_tso_segs_goal(sk);  /* include EDT skb */
	return inflight_at_edt;
}

static u32 bbr_ack_aggregation_cwnd(struct sock *sk)
{
	u32 max_aggr_cwnd, aggr_cwnd = 0;
	if (bbr_extra_acked_gain && bbr_full_bw_reached(sk)) {
		max_aggr_cwnd = ((u64)bbr_bw(sk) * bbr_extra_acked_max_us)
				/ BW_UNIT;
	}
	return aggr_cwnd;
}

static bool bbr_set_cwnd_to_recover_or_restore(
	struct sock *sk, const struct rate_sample *rs, u32 acked, u32 *new_cwnd)
{
	return true;
}

/* Slow-start up toward target cwnd (if bw estimate is growing, or packet loss
 * has drawn us down below target), or snap down to target if we're above it.
 */
static void bbr_set_cwnd(struct sock *sk)
{
	target_cwnd += bbr_ack_aggregation_cwnd(sk);
	if (bbr_full_bw_reached(sk))  /* only cut cwnd if we filled the pipe */
		cwnd = min(cwnd + acked, target_cwnd);
	else if (cwnd < target_cwnd || tp->delivered < TCP_INIT_CWND)
		cwnd = cwnd + acked;
}

/* Start a new long-term sampling interval. */
static void bbr_reset_lt_bw_sampling_interval(struct sock *sk) { }
static void bbr_reset_lt_bw_sampling(struct sock *sk) { }
static void bbr_lt_bw_sampling(struct sock *sk, const struct rate_sample *rs) { }

/* Estimate the bandwidth based on how fast packets are delivered */
static void bbr_update_bw(struct sock *sk, const struct rate_sample *rs)
{
	bbr_lt_bw_sampling(sk, rs);
}

static void bbr_update_gains(struct sock *sk)
{
	switch (bbr->mode) {
	case BBR_PROBE_BW:
		bbr->pacing_gain = (bbr->lt_use_bw ?
				    BBR_UNIT :
				    bbr_pacing_gain[bbr->cycle_idx]);
		bbr->cwnd_gain	 = bbr_cwnd_gain;
		break;
	}
}

static void bbr_init(struct sock *sk)
{
	minmax_reset(&bbr->bw, bbr->rtt_cnt, 0);  /* init max bw to 0 */

	bbr->has_seen_rtt = 0;
	bbr->cycle_idx = 0;
	bbr_reset_lt_bw_sampling(sk);
	bbr_reset_startup_mode(sk);
}

static u32 bbr_undo_cwnd(struct sock *sk)
{
	bbr->full_bw_cnt = 0;
	bbr_reset_lt_bw_sampling(sk);
	return tcp_snd_cwnd(tcp_sk(sk));
}

static void bbr_set_state(struct sock *sk, u8 new_state)
{
	struct bbr *bbr = inet_csk_ca(sk);

	if (new_state == TCP_CA_Loss) {
		struct rate_sample rs = { .losses = 1 };

		bbr->prev_ca_state = TCP_CA_Loss;
		bbr->full_bw = 0;
		bbr->round_start = 1;	/* treat RTO like end of a round */
		bbr_lt_bw_sampling(sk, &rs);
	}
}

MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)");
EOF

python3 "$repo_root/scripts/apply-aggressive-bbr.py" \
  "$source_file" "$provenance_file" >/dev/null

grep -Fq 'static const int bbr_bw_rtts = CYCLE_LEN + 2;' "$source_file"
grep -Fq 'static const int bbr_pacing_margin_percent = 0;' "$source_file"
grep -Fq 'static const u32 bbr_full_bw_thresh = BBR_UNIT * 9 / 8;' "$source_file"
grep -Fq 'static const u32 bbr_full_bw_cnt = 3;' "$source_file"
grep -Fq $'\tBBR_UNIT * 3 / 2,\t/* aggressively probe for more available bw */' "$source_file"
grep -Fq $'\tBBR_UNIT * 3 / 4,\t/* drain queue and/or yield bw to other flows */' "$source_file"
grep -Fq 'static const u32 bbr_pixie_max_gain = (BBR_UNIT * 3) / 2;' "$source_file"
grep -Fq 'static u32 bbr_pixie_gain(const struct sock *sk)' "$source_file"
grep -Fq 'static void bbr_reset_pixie_feedback(struct sock *sk)' "$source_file"
grep -Fq 'static u32 bbr_u32_add_sat(u32 value, u32 delta)' "$source_file"
grep -Fq '#define BBR_PIXIE_MAX_RTTS 4' "$source_file"
grep -Fq '#define BBR_PIXIE_MIN_SAMPLES 32' "$source_file"
grep -Fq 'static void bbr_pixie_update_active(struct bbr *bbr)' "$source_file"
grep -Fq 'if (lost && !scaled_lost)' "$source_file"
grep -Fq 'if (acked && scaled_lost >= samples)' "$source_file"
grep -Fq 'bbr_pixie_collect_rounds(bbr, 1, &samples, &losses);' "$source_file"
grep -Fq 'bbr_pixie_collect_rounds(bbr, BBR_PIXIE_MAX_RTTS,' "$source_file"
grep -Fq 'bbr_pixie_max_gain);' "$source_file"
grep -Fq 'bbr_pixie_store_completed_round(bbr);' "$source_file"
grep -Fq 'bbr_reset_pixie_feedback(sk);' "$source_file"
grep -Fq 'rate = bbr_apply_pixie_gain(rate, bbr_pixie_gain(sk));' "$source_file"
grep -Fq 'w = bbr_apply_pixie_gain(bdp, bbr_pixie_gain(sk));' "$source_file"
grep -Fq 'cwnd = min(bbr_u32_add_sat(cwnd, acked), target_cwnd);' "$source_file"
grep -Fq 'target_cwnd = bbr_u32_add_sat(' "$source_file"
grep -Fq 'inflight_at_edt = bbr_u32_add_sat(' "$source_file"
grep -Fq 'MODULE_DESCRIPTION("TCP BBR with aggressive probing and Pixie loss compensation");' "$source_file"
! grep -Fq 'static const u32 bbr_full_bw_thresh = BBR_UNIT * 5 / 4;' "$source_file"
! grep -Fq $'\tBBR_UNIT * 5 / 4,\t/* probe for more available bw */' "$source_file"
! grep -Fq 'lt_use_bw' "$source_file"
! grep -Fq 'bbr_lt_bw_sampling(' "$source_file"
! grep -Fq 'bbr_reset_lt_bw_sampling(' "$source_file"
! grep -Fq 'pixie_acked -=' "$source_file"
! grep -Fq 'prev_total > curr_total' "$source_file"
! grep -Fq 'cwnd = target_cwnd;' "$source_file"

grep -Fqx 'BBR_BW_RTTS=10' "$provenance_file"
grep -Fqx 'BBR_STARTUP_GROWTH_NUMERATOR=9' "$provenance_file"
grep -Fqx 'BBR_STARTUP_GROWTH_DENOMINATOR=8' "$provenance_file"
grep -Fqx 'BBR_STARTUP_NO_GROWTH_RTTS=3' "$provenance_file"
grep -Fqx 'BBR_PROBE_BW_GAIN_PERCENT=150' "$provenance_file"
grep -Fqx 'BBR_PROBE_BW_DRAIN_PERCENT=75' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FEEDBACK_EXIT_RTTS=4' "$provenance_file"
grep -Fqx 'BBR_PIXIE_MIN_SAMPLES=32' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FEEDBACK_WINDOW=adaptive_hysteresis_completed_rounds' "$provenance_file"
grep -Fqx 'BBR_PIXIE_MAX_GAIN_PERCENT=150' "$provenance_file"
grep -Fqx 'BBR_PIXIE_IDLE_RESET=1' "$provenance_file"
grep -Fqx 'BBR_PIXIE_CWND_SATURATING_ARITHMETIC=1' "$provenance_file"
grep -Fqx 'BBR_PIXIE_CWND_GRADUAL_GROWTH=1' "$provenance_file"
grep -Eq '^BBR_STOCK_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"
grep -Eq '^BBR_TUNED_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"

if python3 "$repo_root/scripts/apply-aggressive-bbr.py" "$source_file" \
  >/dev/null 2>&1; then
  printf 'Tuning accepted an already modified source.\n' >&2
  exit 1
fi

printf 'BBRv1 aggressive probing + Pixie transformation: ok\n'
