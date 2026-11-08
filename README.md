# Linux Aggressive Kernel

[![Build Linux Aggressive Kernel](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml/badge.svg)](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml)

Linux Aggressive Kernel 是一个面向高延迟、丢包和跨境链路的实验性 Linux 内核，基于 Linux BBRv1，目标很直接：**在链路还有可用容量时，更积极地把吞吐榨出来。**

支持 amd64/x86_64 和 arm64/aarch64，提供 DEB / RPM 构建与安装。

## 核心思路

项目主要做两件事：**激进探测**和**激进补偿**。

### 1. 激进探测

BBR 依靠实际交付速率持续估计链路带宽，并在 STARTUP 和 ProbeBW 中主动尝试更高的发送速率。本项目增强这两个阶段的探测力度：

```text
STARTUP：带宽还能增长 12.5% 时继续扩张
ProbeBW：1.50, 0.75, 1, 1, 1, 1, 1, 1
```

STARTUP 将“仍有显著带宽增长”的门槛设为 **12.5%**，让高 RTT、抖动明显的链路有更多机会继续向上发现容量。

进入稳定阶段后，ProbeBW 每个 8 RTT 周期会用 1 个 RTT 以 **1.5 倍当前带宽估计**主动探测更多容量，随后以 0.75 倍排掉探测产生的额外队列，再回到正常巡航。

如果更高的发送量确实带来了更高的 ACK 交付速率，新的 delivery-rate sample 会自然进入 BBR 原有的带宽 max filter；如果额外流量只是变成排队或丢包，则不会凭空抬高 BBR 的带宽估计。

### 2. 激进补偿

对于随机丢包，项目借鉴 [Pixie](https://github.com/marywangran/pixie) 的思路：根据最近完整 RTT 的成功包与丢失包计算补偿，丢掉多少，就适当多发送多少，尽量维持有效吞吐。

```text
补偿系数 = min((成功包 + 丢失包) / 成功包, 1.5)

发送速率 = BBR 发送速率 × 补偿系数
窗口目标 = BBR 窗口目标 × 补偿系数
```

| 丢包率 | 补偿系数 |
| ---: | ---: |
| 10% | 约 1.11 倍 |
| 20% | 1.25 倍 |
| 25% | 约 1.33 倍 |
| 33% 及以上 | 最高 1.5 倍 |

补偿同时作用于 pacing rate 和 cwnd/inflight，避免只提高发送速率却被窗口限制。补偿只作用在实际发送层，不会直接写回 BBR 的 delivered-bandwidth 估计；只有真正成功交付的数据才能把 BBR 的基础带宽估计抬高。

## 适合什么网络

比较适合：

- 中国大陆与海外之间的长距离链路
- 高 RTT、随机丢包明显的 VPS / 云服务器线路
- 移动网络、无线网络、卫星网络
- 标准 BBR 吞吐明显低于链路实际能力的场景

它的目标不是最低延迟或最公平的带宽共享，而是更偏向**吞吐优先**。激进探测和激进补偿都可能带来更高的瞬时排队延迟和更多线速流量，这是预期行为。

## 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/gamesofts/linux-aggressive-kernel/main/kernel.sh
bash kernel.sh
reboot
```

重启后检查：

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

正常情况下应看到 `-aggressive` 内核、`bbr` 和 `fq`。

## 默认网络参数

安装器会写入 `/etc/sysctl.d/99-sysctl.conf`：

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

## 设计要点

- 保留 BBRv1 的 delivery-bandwidth、min-RTT、STARTUP、DRAIN、ProbeBW 和 ProbeRTT 基础框架。
- STARTUP 的显著带宽增长门槛调整为 12.5%。
- ProbeBW 的主动探测增益提高到 1.5 倍。
- 丢包补偿最高 1.5 倍，并同时放大 pacing 和 inflight 目标。
- 探测和补偿都不会直接写回 BBR 的 delivered-bandwidth 估计，带宽模型仍由实际成功交付的数据更新。
- 不使用 BBRv1 的长期 policer 低速模式，避免高随机丢包把连接长期锁在低速状态。
- TCP 的 SACK、RACK、TLP、RTO 和重传机制仍然正常工作。

## 注意

这是实验性内核。相比标准 BBR，它会更主动地制造探测和补偿流量，因此可能出现：

- 满载时延迟更高
- 短时间队列增加
- 丢包线路上实际发送流量高于有效吞吐
- 与其他流竞争时更具攻击性

建议先在可回滚的 VPS / 测试环境中使用，并保留一个可启动的发行版原生内核。

更详细的算法说明见 [BBR-DESIGN.md](docs/BBR-DESIGN.md)。
