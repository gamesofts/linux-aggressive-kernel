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
- floor 建立后，在同一次活跃传输中只允许向下修正，不允许因为后来 loss 变高而上调；
- application-limited idle restart 会清空 floor 并重新学习路径。

这样可以避免：

```text
拥塞 -> 丢包升高 -> floor 升高 -> 补偿更猛 -> 更拥塞
```

## 拥塞保护

当最近 RTT 的 loss 明显高于 trusted floor，或者 excess loss 同时伴随 RTT 相对 min-RTT 明显膨胀时，会进入 overload hold-down：

- 暂停 Pixie 增益；
- pacing/cwnd 回到未补偿状态；
- 恢复原生 BBRv1 的 loss cwnd response；
- 恢复 packet conservation；
- 默认保持 3 个有效完整 RTT。

RTO 也会直接触发该保护。

这意味着现在的原则是：

```text
稳定随机丢包 -> 补偿
超出基础丢包的异常 loss / 排队 -> 退让
```

## 主要设计

- **8 RTT 稳健 floor**：不用单个最小值，降低偶发低丢包样本的影响。
- **lower-envelope trust**：可信 floor 在活跃期间不能被高 loss 抬升。
- **STARTUP 防误判**：不在 BBR STARTUP 阶段建立 erasure floor。
- **RTT + excess loss 过载判断**：既看额外丢包，也看排队延迟。
- **原生 recovery 回退**：检测到 overload 后重新启用 BBRv1 loss recovery 和 packet conservation。
- **速率与窗口协调调整**：pacing rate 和 cwnd/BDP 使用同一个补偿系数。
- **1.5x 上限**：继续保留保守的最大线速补偿限制。
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
