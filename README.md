# Linux Aggressive Kernel

[![Build Linux Aggressive Kernel](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml/badge.svg)](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml)

Linux Aggressive Kernel 是一个面向高延迟、丢包和跨境链路的实验性 Linux 内核，基于 Linux BBRv1，目标很直接：**在吞吐优先的前提下兼顾延迟，把链路可用容量更稳、更高效地榨出来。**

支持 amd64/x86_64 和 arm64/aarch64，使用 **Clang + ThinLTO** 构建，提供 DEB / RPM 安装包。

## 核心优化（rev6）

### 1. 激进探测与对称排空

```text
STARTUP：带宽还能增长 12.5% 时继续扩张（不叠加 Pixie，避免冷启动打爆浅队列）
ProbeBW：1.50, 0.625, 1, 1, 1, 1, 1, 1（周期均速 1.015625）
PROBE_RTT：窗口降至 max(0.5 * raw_BDP, 4)，周期 15s（保留 50% 吞吐并消除 cwnd=4 RTO）
```

- **STARTUP**：显著增长门槛设为 **12.5%**，且不叠加 Pixie 倍速，避免建连瞬间以 `4.33x` 冲垮浅缓冲 VPS/限速器。
- **ProbeBW**：保持 **1.50x** 主动探测，同时将 Drain 相调整为 **0.625x（5/8）**——即便 Pixie 触发上限 `1.50x`，Drain 实际线速仍为 `0.625 × 1.50 = 0.9375 < 1.0`，从数学上杜绝队列“越排越满”；配合队列感知退出机制，纯随机丢包且无排队时立即回到巡航不损吞吐，存在常驻排队时则真正排空队列压低延迟。
- **PROBE_RTT**：借鉴 BBRv2/v3，将探测窗口从硬砍 `4` 包升级为 **`max(0.5 * BDP, 4)`** 并适度放宽至 `15s` 周期，消除每 10 秒一次的吞吐归零暴跌与尾部丢包 RTO 卡顿。

### 2. 分阶段解耦、零除法的 Pixie 激进补偿

借鉴 [Pixie](https://github.com/marywangran/pixie) 思路，根据最近 4 个完整 `ProbeBW` RTT 的高精度 Q12 丢包率计算补偿：

```text
补偿系数 = clamp(1 / (1 - p), 1.0, 1.5)   （< 0.5% 死区不触发）

Probe 相线速 = min(1.50 × 补偿系数, 1.875) × BBR_bw
Cruise 相线速 = 1.00 × 补偿系数 × BBR_bw   （最高 1.50x）
Drain 相线速  = 0.625 × 补偿系数 × BBR_bw  （最高 0.9375x）
ProbeBW 窗口  = min(2.00 × 补偿系数, 2.50) × BBR_BDP
```

- **抗污染反馈**：仅在稳态 `ProbeBW` 且回合样本 `>= 32` 包时写入 4-RTT 历史；`STARTUP`/`DRAIN` 队列溢出与 `PROBE_RTT` 低速回合不再污染补偿模型。
- **0.5% 死区 + Q12 精度（0.024%）**：避免高 BDP 链路偶发 1 个丢包被 20~65 倍放大导致补偿长期误锁。
- **ACK 热路径 O(1) 零除法**：在 `struct bbr` 原有空闲位域缓存 `pixie_gain_cached`（零结构体膨胀），每 RTT 仅计算一次，热路径零循环、零 64 位除法。

### 3. 高 BDP `sch_fq` 默认值调优

微调 `net/sched/sch_fq.c` 默认参数（`limit=32768`、`flow_plimit=2000`、`buckets=4096`），消除非 TSO / WireGuard / TUN / QUIC / 高丢包重传场景下默认 `flow_limit=100` 引发的本地 `flows_plimit` 丢包与 Pixie 正反馈死循环。

### 4. Clang ThinLTO 与云 VPS 高吞吐数据面

- **Clang + ThinLTO (`LLVM=1`, `CONFIG_LTO_CLANG_THIN=y`)**：跨文件内联优化 socket ↔ TCP ↔ BBR ↔ `fq` ↔ Netfilter ↔ `virtio_net` 热路径。
- **调度与时钟统一**：`CONFIG_PREEMPT_LAZY=y` + `CONFIG_PREEMPT_DYNAMIC=y` + `CONFIG_HZ_250=y` + `NO_HZ_IDLE`，减少 KVM VM-exit 与持锁抢占开销，兼顾高吞吐与低调度尾延迟。
- **转发与加密加速**：内置 Netfilter Flowtable 快速转发（`NF_FLOW_TABLE` / `NFT_FLOW_OFFLOAD`）、透明代理与策略路由（`NFT_TPROXY` / `NFT_SOCKET` / `IP_MULTIPLE_TABLES`）、模块化 kTLS / WireGuard 与 x86_64/arm64 硬件密码指令加速，以及 BPF JIT、MGLRU、THP `madvise`、`KVM_GUEST` + `PARAVIRT_SPINLOCKS`。

## 适合什么网络

- 中国大陆与海外之间的长距离高 RTT 跨境链路
- 存在随机丢包或浅队列波动的 VPS / 云服务器线路
- 移动网络、无线网络、卫星网络
- NAT 转发、WireGuard / TLS 加密代理与高并发中转节点

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

## 云 VPS 精简配置

针对云 VPS 使用场景，精简 Linux 默认内核配置：

- 禁用 Intel i915/Xe、AMD Radeon/AMDGPU、Nouveau 等显卡驱动。
- 禁用音频、多媒体设备相关子系统。
- 禁用蓝牙、Wi-Fi、NFC、CAN、IEEE 802.15.4、业余无线电等无线及专用通信子系统。
- 禁用 FireWire、PCMCIA、并口、Thunderbolt、USB Gadget、游戏控制器、红外遥控等外设支持。
- 将 Realtek PHY、tg3、e100、r8169 等需要固件的有线网卡驱动调整为模块，减少安装时无关的固件缺失告警。

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

## 量化基准验证

仓库提供基于 `netns` + `veth` + `tc netem` + `tbf` + `iperf3` 的自动化测试脚本 [tests/bench-netem.sh](tests/bench-netem.sh)，可在安装目标内核的 Linux 主机（root）上复现高 BDP、随机丢包、浅缓冲拥塞及晚高峰混合场景测试。

## 注意

这是实验性内核。相比标准 BBR，它会更主动地进行带宽探测与丢包补偿，在极度拥塞链路下仍可能比保守算法更具攻击性。建议先在可回滚的 VPS / 测试环境中使用，并保留一个可启动的发行版原生内核。

更详细的算法说明见 [BBR-DESIGN.md](docs/BBR-DESIGN.md)。
