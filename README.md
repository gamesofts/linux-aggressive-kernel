# Linux Aggressive Kernel

[![Build Linux Aggressive Kernel](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml/badge.svg)](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml)

Linux Aggressive Kernel 为 amd64/x86_64 和 arm64/aarch64 主机构建实验性 Linux 内核，并将 Pixie 的丢包补偿思路移植到 Linux BBRv1。

它主要面向高延迟、随机丢包明显的网络，例如跨境线路、移动网络、卫星网络和其他长距离劣质链路。

## 工作原理

当前版本不再把“所有丢包”都直接拿来做补偿，而是先估计 **rate-independent erasure floor（与发送速率无关的基础丢包）**：

```text
到达率 = 1 - erasure floor
发送补偿 = min(1 / 到达率, 1.5)
发送速率 = BBR 发送速率 × 发送补偿
窗口目标 = BBR 窗口目标 × 发送补偿
```

BBR 的 delivered-bandwidth 模型仍然只记录成功交付的数据；补偿只作用于 pacing rate 和 cwnd/BDP，不会污染带宽 max filter。

## Erasure floor 如何计算

为了避免简单 `min()` 被某一个“特别幸运”的低丢包 RTT 拉低，内核保留最近最多 8 个有效完整 RTT 的丢包比例：

- 每个 RTT 至少观察 32 个 ACKed+lost 包才有效；
- 4-5 个有效 RTT 时使用中位数；
- 6-8 个有效 RTT 时，对排序后的低半部分再取中位数，相当于稳健的低四分位基线；
- candidate 低于当前 trusted floor 时立即下调，避免路径变干净后继续过度补偿；
- candidate 高于 trusted floor 时允许上调，但只在 BBR 非 STARTUP、`pacing_gain <= 1.0` 且 RTT 没有明显膨胀的完整 RTT 中累计证据；
- 连续 2 个这样的低压力 RTT 都支持更高 candidate 后，直接把 trusted floor 提高到新的 robust candidate，并立即恢复按新 floor 补偿；
- application-limited idle restart 会清空 floor 并重新学习路径。

因此 floor 是 **fast-down / confirmed-up**，而不是永久只能下降。目标是在网络基础丢包恶化时仍能尽快提高 wire rate，同时避免把一次拥塞尖峰直接学进 floor。

## 拥塞保护

当最近 RTT 的 loss 明显高于 trusted floor，或者 excess loss 同时伴随 RTT 相对 min-RTT 明显膨胀时，会进入 overload hold-down：

- 暂停 Pixie 增益；
- pacing/cwnd 回到未补偿状态；
- 恢复原生 BBRv1 的 loss cwnd response；
- 恢复 packet conservation；
- 默认保持 3 个有效完整 RTT。

RTO 也会直接触发该保护。

这里的 hold-down 同时充当一次主动“降压测试”：如果 sender 已经退让、`pacing_gain <= 1.0`、RTT 也没有排队膨胀，但 robust loss floor 仍持续更高，就把它视为基础 erasure 上升，而不是继续按拥塞处理。

这意味着现在的原则是：

```text
稳定随机丢包 -> 补偿
异常 excess loss / 排队 -> 先退让
退让后 loss 仍稳定偏高且无排队 -> 提高 floor，恢复更强补偿
```

## 主要设计

- **8 RTT 稳健 floor**：不用单个最小值，降低偶发低丢包样本的影响。
- **fast-down / confirmed-up**：floor 可以双向适应；上升需要低压力 RTT 连续确认。
- **STARTUP 防误判**：不在 BBR STARTUP 阶段建立或上调 erasure floor。
- **主动降压判别**：用 `pacing_gain <= 1.0` 且无 RTT inflation 的回合确认更高 loss 是否仍然存在。
- **RTT + excess loss 过载判断**：既看额外丢包，也看排队延迟。
- **原生 recovery 回退**：检测到 overload 后重新启用 BBRv1 loss recovery 和 packet conservation。
- **速率与窗口协调调整**：pacing rate 和 cwnd/BDP 使用同一个补偿系数。
- **1.5x 上限**：继续保留最大线速补偿限制。
- **不污染带宽估计**：补偿不会写回 delivered-bandwidth max filter。

## 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/gamesofts/linux-aggressive-kernel/main/kernel.sh
bash kernel.sh
reboot
```

## 默认网络参数

安装器写入 `/etc/sysctl.d/99-sysctl.conf`：

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
```

更详细的算法实现见 [BBR-DESIGN.md](docs/BBR-DESIGN.md)。
