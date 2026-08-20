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
	u32	lt_last_lost;	     /* LT intvl start: tp->lost */
};
static const int bbr_bw_rtts = CYCLE_LEN + 2;
static const int bbr_pacing_margin_percent = 1;
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
static u64 bbr_rate_bytes_per_sec(struct sock *sk, u64 rate, int gain) { return rate; }
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
	struct bbr *bbr = inet_csk_ca(sk);
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
grep -Fq '#define BBR_PIXIE_MAX_RTTS 8' "$source_file"
grep -Fq '#define BBR_PIXIE_MIN_FLOOR_RTTS 4' "$source_file"
grep -Fq '#define BBR_PIXIE_OVERLOAD_HOLD_RTTS 3' "$source_file"
grep -Fq '#define BBR_PIXIE_RAISE_CONFIRM_RTTS 2' "$source_file"
grep -Fq 'static bool bbr_pixie_floor_candidate(const struct bbr *bbr, u8 *floor)' "$source_file"
grep -Fq 'static bool bbr_pixie_low_pressure(const struct sock *sk,' "$source_file"
grep -Fq 'static bool bbr_pixie_overloaded(const struct sock *sk,' "$source_file"
grep -Fq 'static bool bbr_pixie_should_mask_loss(const struct sock *sk)' "$source_file"
grep -Fq 'pixie_floor:8' "$source_file"
grep -Fq 'pixie_overload_rounds:3' "$source_file"
grep -Fq 'pixie_raise_rounds:3' "$source_file"
grep -Fq 'candidate < bbr->pixie_floor' "$source_file"
grep -Fq 'bbr->pacing_gain <= BBR_UNIT' "$source_file"
grep -Fq 'bbr->pixie_floor = candidate;' "$source_file"
grep -Fq 'bbr->pixie_overload_rounds = 0;' "$source_file"
grep -Fq 'bbr->packet_conservation = 1;' "$source_file"
grep -Fq 'cwnd = max_t(s32, cwnd - rs->losses, 1);' "$source_file"
grep -Fq 'rate = bbr_apply_pixie_gain(rate, bbr_pixie_gain(sk));' "$source_file"
grep -Fq 'w = bbr_apply_pixie_gain(bdp, bbr_pixie_gain(sk));' "$source_file"
grep -Fq 'MODULE_DESCRIPTION("TCP BBR with erasure-aware Pixie compensation");' "$source_file"
! grep -Fq 'lt_use_bw' "$source_file"
! grep -Fq 'bbr_lt_bw_sampling(' "$source_file"
! grep -Fq 'bbr_reset_lt_bw_sampling(' "$source_file"

grep -Fqx 'BBR_BW_RTTS=10' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FEEDBACK_RTTS=8' "$provenance_file"
grep -Fqx 'BBR_PIXIE_MIN_FLOOR_RTTS=4' "$provenance_file"
grep -Fqx 'BBR_PIXIE_MIN_SAMPLES=32' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FLOOR_ESTIMATOR=median_then_lower_half_median' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FLOOR_UPDATE=fast_down_confirmed_up' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FLOOR_RAISE_CONFIRM_RTTS=2' "$provenance_file"
grep -Fqx 'BBR_PIXIE_FLOOR_RAISE_GATE=pacing_le_1x_no_rtt_inflation' "$provenance_file"
grep -Fqx 'BBR_PIXIE_OVERLOAD_HOLD_RTTS=3' "$provenance_file"
grep -Fqx 'BBR_PIXIE_NATIVE_RECOVERY_ON_OVERLOAD=1' "$provenance_file"
grep -Fqx 'BBR_PIXIE_MAX_GAIN_PERCENT=150' "$provenance_file"
grep -Eq '^BBR_STOCK_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"
grep -Eq '^BBR_TUNED_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"

if python3 "$repo_root/scripts/apply-aggressive-bbr.py" "$source_file" \
  >/dev/null 2>&1; then
  printf 'Tuning accepted an already modified source.\n' >&2
  exit 1
fi

printf 'BBRv1 erasure-aware Pixie transformation: ok\n'
