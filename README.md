# Linux Aggressive Kernel

[![Build Linux Aggressive Kernel](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml/badge.svg)](https://github.com/gamesofts/linux-aggressive-kernel/actions/workflows/build-aggressive-kernel.yml)

Linux Aggressive Kernel 为 amd64/x86_64 和 arm64/aarch64 主机构建实验性 Linux 内核，并将 [Pixie](https://github.com/marywangran/pixie) 的丢包补偿思路移植到 Linux BBRv1。

它主要面向高延迟、随机丢包明显的网络，例如跨境线路、移动网络、卫星网络和人工丢包测试环境。目标是在链路仍有可用容量时，通过适当增加实际发送量，减少丢包对有效下载或上传速度的影响。

## 工作原理

算法根据最近完整 RTT 的成功包和丢失包计算补偿，并同时调整发送速率和拥塞窗口目标：

```text
补偿系数 = min（（成功包 + 丢失包）/ 成功包，1.5）
发送速率 = BBR 计算的发送速率 × 补偿系数
窗口目标 = BBR 计算的窗口目标 × 补偿系数
```

| 丢包率 | 理论补偿系数 | 实际补偿系数 |
| ---: | ---: | ---: |
| 10% | 约 1.11 倍 | 约 1.11 倍 |
| 20% | 1.25 倍 | 1.25 倍 |
| 25% | 约 1.33 倍 | 约 1.33 倍 |
| 50% | 2 倍 | 1.5 倍（封顶） |

## 主要设计

- **滞回式自适应窗口**：观测最近一个完整 RTT，至少观察到 32 个包且出现丢包，即启动补偿。启动后使用最多 4 个完整 RTT 的全部统计结果计算补偿，不会因为某一个 RTT 短暂恢复就立即退出。

- **正反馈自激控制**：补偿作用于 pacing rate 和 cwnd/inflight 目标，最高限制为 BBR 基础结果的 1.5 倍；补偿结果不会写回 delivered-bandwidth 估计或带宽 max filter，不会形成自激链路。

- **速率与窗口协调调整**：发送速率和拥塞窗口目标使用同一个补偿系数，避免只提高发送速度却被窗口限制。拥塞窗口随 ACK 到达逐步增长，以减少突发流量和瞬时振荡。

- **不进入长期低速锁定**：高丢包不会触发 BBRv1 的长期低带宽模式，避免随机丢包被当作固定限速器后长期压低发送速率。

## 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/gamesofts/linux-aggressive-kernel/main/kernel.sh
bash kernel.sh
reboot
```

## 默认网络参数

安装器直接写入 `/etc/sysctl.d/99-sysctl.conf`：

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
