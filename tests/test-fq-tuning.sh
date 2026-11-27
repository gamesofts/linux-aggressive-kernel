#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fq-tuning-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

source_file="$tmp_dir/sch_fq.c"
provenance_file="$tmp_dir/fq-provenance.env"
cat > "$source_file" <<'EOF'
static int fq_init(struct Qdisc *sch, struct nlattr *opt,
		   struct netlink_ext_ack *extack)
{
	struct fq_sched_data *q = qdisc_priv(sch);

	sch->limit		= 10000;
	q->flow_plimit		= 100;
	q->fq_trees_log		= ilog2(1024);
	return 0;
}
MODULE_DESCRIPTION("Fair Queue Packet Scheduler");
EOF

python3 "$repo_root/scripts/apply-fq-tuning.py" \
  "$source_file" "$provenance_file" >/dev/null

grep -Fq $'\tsch->limit\t\t= 32768;' "$source_file"
grep -Fq $'\tq->flow_plimit\t\t= 2000;' "$source_file"
grep -Fq $'\tq->fq_trees_log\t\t= ilog2(4096);' "$source_file"
grep -Fq 'MODULE_DESCRIPTION("Fair Queue Packet Scheduler (high-BDP tuned defaults)");' "$source_file"
! grep -Fq $'\tsch->limit\t\t= 10000;' "$source_file"
! grep -Fq $'\tq->flow_plimit\t\t= 100;' "$source_file"

grep -Fqx 'FQ_DEFAULT_PLIMIT=32768' "$provenance_file"
grep -Fqx 'FQ_DEFAULT_FLOW_PLIMIT=2000' "$provenance_file"
grep -Fqx 'FQ_DEFAULT_BUCKETS=4096' "$provenance_file"
grep -Eq '^FQ_STOCK_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"
grep -Eq '^FQ_TUNED_SOURCE_SHA256=[0-9a-f]{64}$' "$provenance_file"

if python3 "$repo_root/scripts/apply-fq-tuning.py" "$source_file" \
  >/dev/null 2>&1; then
  printf 'FQ tuning accepted an already modified source.\n' >&2
  exit 1
fi

printf 'sch_fq high-BDP default tuning: ok\n'
