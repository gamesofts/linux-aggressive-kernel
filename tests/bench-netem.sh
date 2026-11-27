#!/usr/bin/env bash
# Reproducible netns + veth + tc netem/tbf + iperf3 benchmark suite for
# comparing stock BBRv1, rev5 aggressive BBR, and rev6 aggressive BBR + fq.
#
# Usage (as root on a host booted into the target kernel):
#   sudo bash tests/bench-netem.sh [DURATION_SEC] [CONGESTION_CONTROL]
set -euo pipefail

DURATION="${1:-30}"
CC="${2:-bbr}"
NS_SRV="lak-srv-$$"
NS_RTR="lak-rtr-$$"
NS_CLI="lak-cli-$$"
SRV_PID=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'bench-netem: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

cleanup() {
  if [[ -n "$SRV_PID" ]]; then
    kill "$SRV_PID" >/dev/null 2>&1 || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  ip netns del "$NS_CLI" >/dev/null 2>&1 || true
  ip netns del "$NS_RTR" >/dev/null 2>&1 || true
  ip netns del "$NS_SRV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  printf 'bench-netem: run as root (requires netns and tc privileges)\n' >&2
  exit 1
}

for cmd in ip tc iperf3 ss jq python3; do
  require_cmd "$cmd"
done

setup_topology() {
  ip netns add "$NS_SRV"
  ip netns add "$NS_RTR"
  ip netns add "$NS_CLI"

  ip link add veth-srv type veth peer name veth-rtr-s
  ip link add veth-cli type veth peer name veth-rtr-c

  ip link set veth-srv netns "$NS_SRV"
  ip link set veth-rtr-s netns "$NS_RTR"
  ip link set veth-rtr-c netns "$NS_RTR"
  ip link set veth-cli netns "$NS_CLI"

  ip -n "$NS_SRV" link set lo up
  ip -n "$NS_RTR" link set lo up
  ip -n "$NS_CLI" link set lo up

  ip -n "$NS_SRV" addr add 10.200.1.2/24 dev veth-srv
  ip -n "$NS_SRV" link set veth-srv up
  ip -n "$NS_SRV" route add default via 10.200.1.1

  ip -n "$NS_RTR" addr add 10.200.1.1/24 dev veth-rtr-s
  ip -n "$NS_RTR" addr add 10.200.2.1/24 dev veth-rtr-c
  ip -n "$NS_RTR" link set veth-rtr-s up
  ip -n "$NS_RTR" link set veth-rtr-c up
  ip netns exec "$NS_RTR" sysctl -qw net.ipv4.ip_forward=1

  ip -n "$NS_CLI" addr add 10.200.2.2/24 dev veth-cli
  ip -n "$NS_CLI" link set veth-cli up
  ip -n "$NS_CLI" route add default via 10.200.2.1

  for ns in "$NS_SRV" "$NS_CLI"; do
    ip netns exec "$ns" sysctl -qw \
      net.core.default_qdisc=fq \
      "net.ipv4.tcp_congestion_control=$CC" \
      net.ipv4.tcp_no_metrics_save=1
  done
  ip netns exec "$NS_CLI" tc qdisc replace dev veth-cli root fq
  ip netns exec "$NS_SRV" tc qdisc replace dev veth-srv root fq

  ip netns exec "$NS_SRV" iperf3 -s -D -p 5201
  SRV_PID="$(pgrep -n -f 'iperf3 -s -D -p 5201' || true)"
}

apply_link_profile() {
  local rate_mbps="$1" one_way_ms="$2" loss_pct="$3" tbf_limit_kb="$4"
  ip netns exec "$NS_RTR" tc qdisc del dev veth-rtr-s root 2>/dev/null || true
  ip netns exec "$NS_RTR" tc qdisc del dev veth-rtr-c root 2>/dev/null || true

  # Forward direction (client -> server) shaped on router egress veth-rtr-s.
  if [[ "$loss_pct" == "0" ]]; then
    ip netns exec "$NS_RTR" tc qdisc add dev veth-rtr-s root handle 1: \
      netem delay "${one_way_ms}ms" limit 100000
  else
    ip netns exec "$NS_RTR" tc qdisc add dev veth-rtr-s root handle 1: \
      netem delay "${one_way_ms}ms" loss random "${loss_pct}%" limit 100000
  fi
  ip netns exec "$NS_RTR" tc qdisc add dev veth-rtr-s parent 1: handle 2: \
    tbf rate "${rate_mbps}mbit" burst 64kb limit "${tbf_limit_kb}kb"

  # Reverse direction delay (server -> client) on router egress veth-rtr-c.
  ip netns exec "$NS_RTR" tc qdisc add dev veth-rtr-c root \
    netem delay "${one_way_ms}ms" limit 100000
}

run_case() {
  local name="$1" rate_mbps="$2" rtt_ms="$3" loss_pct="$4" buf_kb="$5" streams="$6"
  local one_way_ms=$((rtt_ms / 2))
  local out_json

  apply_link_profile "$rate_mbps" "$one_way_ms" "$loss_pct" "$buf_kb"
  out_json="$(mktemp "${TMPDIR:-/tmp}/bench-iperf.XXXXXX.json")"

  ip netns exec "$NS_CLI" iperf3 -c 10.200.1.2 -p 5201 -t "$DURATION" \
    -P "$streams" -C "$CC" -J > "$out_json"

  local fq_drops
  fq_drops="$(ip netns exec "$NS_CLI" tc -s qdisc show dev veth-cli \
    | awk '/flows_plimit/ { for (i=1; i<=NF; i++) if ($i == "flows_plimit") print $(i+1) }' \
    | tail -n1)"
  fq_drops="${fq_drops:-0}"

  python3 - "$name" "$out_json" "$fq_drops" <<'PY'
import json, sys
name, path, fq_drops = sys.argv[1:]
data = json.loads(open(path, encoding="utf-8").read())
end = data["end"]
sent = end["sum_sent"]
recv = end["sum_received"]
mbps = recv["bits_per_second"] / 1e6
retrans = sent.get("retransmits", 0)
rtts = [
    s["sender"].get("mean_rtt", 0) / 1000.0
    for s in end.get("streams", [])
    if "sender" in s
]
mean_rtt = sum(rtts) / len(rtts) if rtts else 0.0
max_rtts = [
    s["sender"].get("max_rtt", 0) / 1000.0
    for s in end.get("streams", [])
    if "sender" in s
]
max_rtt = max(max_rtts) if max_rtts else 0.0
print(
    f"| {name:<26} | {mbps:7.2f} Mbps | {retrans:7d} | "
    f"{mean_rtt:6.1f} ms | {max_rtt:6.1f} ms | {fq_drops:>8} |"
)
PY
  rm -f "$out_json"
}

setup_topology
printf 'Kernel: %s | CC: %s | Duration: %ss per case\n\n' "$(uname -r)" "$CC" "$DURATION"
printf '| %-26s | %12s | %7s | %9s | %9s | %8s |\n' \
  'Scenario' 'Goodput' 'Retrans' 'Mean RTT' 'Max RTT' 'fq_plim'
printf '|%s|%s|%s|%s|%s|%s|\n' \
  '----------------------------' '--------------' '---------' '-----------' '-----------' '----------'

# 1. Clean high-BDP (200ms, 200Mbps, 2.0 BDP = 10000KB buffer, 0% loss)
run_case "clean-200ms-200m-0%" 200 200 0 10000 1
# 2. Cross-border random loss (200ms, 100Mbps, 2.0 BDP = 5000KB, 2%/5%/15%)
run_case "loss-200ms-100m-2%" 100 200 2 5000 1
run_case "loss-200ms-100m-5%" 100 200 5 5000 1
run_case "loss-200ms-100m-15%" 100 200 15 5000 1
# 3. Shallow-buffer congestion (100ms, 100Mbps, 0.5 BDP = 625KB, 0% random loss)
run_case "shallow-100ms-100m-0.5bdp" 100 100 0 625 1
# 4. Mixed evening-peak (200ms, 100Mbps, 1.5 BDP = 3750KB, 3% random loss, 4 flows)
run_case "mixed-200ms-100m-3%-4flow" 100 200 3 3750 4
