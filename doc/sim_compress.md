# NVMe-oF 压缩 + CRC 时延仿真（SPDK_SIM_COMPRESS）

> 基于 SPDK v23.01.1。

## 这是什么

在 SPDK NVMe-oF target 的 bdev 读写路径上，运行一段**时间受限的 memcpy
循环**，模拟 CRC 计算和压缩/解压的 CPU + 内存带宽开销，无需引入真实的
ISA-L 或 DPDK_compressdev。

每个阶段（CRC、Compress）独立可调。流水线顺序匹配实际存储路径：

```
write_cmd:  CRC memcpy-for-us  →  compress memcpy-for-us  →  bdev submit
read_cmd:   bdev complete  →  decompress memcpy-for-us  →  CRC validate memcpy-for-us
```

仿真的关键性质：**memcpy 在 per-thread scratch 上用移动指针走，每次循环
都打到新的 cache line / DRAM 行**。scratch 默认 4 MiB（大于典型 L2），所以
循环会真正消耗 L3 / 内存带宽，把 IOSTASH 写进 L3 的内容冲掉 —— 这正是
要测的开启 CRC/压缩后内存子系统压力。

## 旋钮

五个环境变量，nvmf_tgt 启动时读一次，之后不变：

| 变量 | 含义 | 默认 |
|---|---|---|
| `SPDK_SIM_COMPRESS_WRITE_US` | 写路径压缩 memcpy 目标耗时（µs） | `0` |
| `SPDK_SIM_COMPRESS_READ_US`  | 读路径解压 memcpy 目标耗时（µs） | `0` |
| `SPDK_SIM_CRC_WRITE_US`      | 写路径 CRC memcpy 目标耗时（µs） | `0` |
| `SPDK_SIM_CRC_READ_US`       | 读路径 CRC 校验 memcpy 目标耗时（µs） | `0` |
| `SPDK_SIM_SCRATCH_KB`        | per-thread scratch 大小（KiB） | `4096` |

全 0 = 不做任何 memcpy（`target_tsc == 0` 直接 return）。

scratch 默认 4 MiB 够冲掉典型 L2。要冲掉 LLC（典型 32–64 MiB）建议设到
`65536`（64 MiB）：

```bash
export SPDK_SIM_SCRATCH_KB=65536
```

编译期开关：`lib/nvmf/ctrlr_bdev.c` 顶部 `#define SPDK_SIM_COMPRESS 1`。
关掉传 `-DSPDK_SIM_COMPRESS=0` 给 make，整段仿真代码不编入二进制。

nvmf_tgt 启动时会打一行 NOTICELOG，确认五个值的当前生效：

```
[...] sim_compress: enabled scratch=4096 KiB compress_w_us=200 compress_r_us=200 crc_w_us=50 crc_r_us=50
```

---

# Server 端

下面以物理 Linux + RDMA NIC + 物理 NVMe SSD 为目标。OrbStack / 无 RDMA /
无物理 NVMe 见附录 A。

## 1. 拉代码 + 装依赖

```bash
git clone https://github.com/Micuks/spdk.git
cd spdk
git checkout sim-compress-23.01.1
git submodule update --init
./scripts/pkgdep.sh
```

## 2. 编译

```bash
./configure --with-rdma
make -j$(nproc)
make install
```

## 3. 配 hugepage + 绑 NVMe 到 vfio/uio

```bash
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
mkdir -p /dev/hugepages
mount -t hugetlbfs nodev /dev/hugepages
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages   # 确认

# 列出要测的 NVMe BDF
lsscsi | grep HWE72P
./scripts/setup.sh status

# 绑到 vfio/uio
PCI_ALLOWED="0000:d6:00.0 0000:d9:00.0 0000:57:00.0" ./scripts/setup.sh
```

## 4. 配 RDMA 网络

```bash
nmcli connection add type ethernet con-name enp23s0f0np0 ifname enp23s0f0np0
nmcli connection add type ethernet con-name enp23s0f1np1 ifname enp23s0f1np1
nmcli connection modify enp23s0f0np0 ipv4.addresses 192.168.65.81/24 \
    ipv4.gateway 192.168.65.1 ipv4.method manual
nmcli connection modify enp23s0f1np1 ipv4.addresses 192.168.75.81/24 \
    ipv4.gateway 192.168.75.1 ipv4.method manual
nmcli connection up enp23s0f0np0
nmcli connection up enp23s0f1np1
```

## 5. 选 combo，设环境变量，起 target

```bash
# baseline 不加任何 sim
unset SPDK_SIM_COMPRESS_WRITE_US SPDK_SIM_COMPRESS_READ_US \
      SPDK_SIM_CRC_WRITE_US     SPDK_SIM_CRC_READ_US

# 或者：CRC + 压缩都开
export SPDK_SIM_COMPRESS_WRITE_US=200
export SPDK_SIM_COMPRESS_READ_US=200
export SPDK_SIM_CRC_WRITE_US=50
export SPDK_SIM_CRC_READ_US=50

# 起 target
./build/bin/nvmf_tgt -m 0x30 &
```

`SPDK_SIM_*_US` 是 reactor 线程**第一次进 I/O** 时读取并缓存的。运行中改
环境变量不会重新生效，**必须 kill nvmf_tgt 后重起**。

## 6. 配 transport / bdev / subsystem / listener

```bash
./scripts/rpc.py nvmf_create_transport -t RDMA \
    -q 128 -m 127 -c 4096 -i 131072 -u 131072 -a 128 -n 2048 -b 0

./scripts/rpc.py bdev_nvme_attach_controller -b nvme3 -t PCIe -a 0000:d6:00.0
./scripts/rpc.py bdev_nvme_attach_controller -b nvme6 -t PCIe -a 0000:d9:00.0
./scripts/rpc.py bdev_nvme_attach_controller -b nvme0 -t PCIe -a 0000:57:00.0

# 检查子系统是否已存在
./scripts/rpc.py nvmf_get_subsystems
# 不存在则创建
./scripts/rpc.py nvmf_create_subsystem nqn.2016-06.io.spdk:cnode1 \
    -a -s SPDK00000000000001 -m 8

./scripts/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 nvme3n1
./scripts/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 nvme6n1
./scripts/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 nvme0n1

./scripts/rpc.py nvmf_subsystem_add_listener nqn.2016-06.io.spdk:cnode1 \
    -t RDMA -a 192.168.65.81 -s 4420
./scripts/rpc.py nvmf_subsystem_add_listener nqn.2016-06.io.spdk:cnode1 \
    -t RDMA -a 192.168.75.81 -s 4420
```

## 7. 切换 combo

```bash
pkill -9 -f build/bin/nvmf_tgt
sleep 1

# 改 env var
export SPDK_SIM_COMPRESS_WRITE_US=...
export SPDK_SIM_COMPRESS_READ_US=...
export SPDK_SIM_CRC_WRITE_US=...
export SPDK_SIM_CRC_READ_US=...

# 重起 + 重做第 6 步的 RPC 配置
./build/bin/nvmf_tgt -m 0x30 &
# ... rpc.py 命令
```

---

# Client 端

Client 跑 SPDK 自带 perf 当 initiator，指向 server 的某个 listener IP：

```bash
# 写
./build/examples/perf \
    -r 'trtype:RDMA adrfam:IPv4 traddr:192.168.65.81 trsvcid:4420' \
    -t 30 -w write -o 4096 -q 1

# 读
./build/examples/perf \
    -r 'trtype:RDMA adrfam:IPv4 traddr:192.168.65.81 trsvcid:4420' \
    -t 30 -w read -o 4096 -q 1
```

`traddr` 填的是 server 的 listener IP（第 4 步 nmcli 配的那两个 IP 之一）。

记录 perf 输出末尾 `Total` 行的 IOPS + Average latency。

## 四个推荐 combo

每个 combo = server 重起一次（带不同 env var）+ client 跑一对 read/write：

| label | SPDK_SIM_COMPRESS_WRITE/READ_US | SPDK_SIM_CRC_WRITE/READ_US | 含义 |
|---|---|---|---|
| baseline | 0 / 0 | 0 / 0 | 干净路径，IOSTASH 仍生效 |
| crc      | 0 / 0 | 50 / 50 | 仅 CRC 路径上的 memcpy + 内存带宽消耗 |
| comp     | 200 / 200 | 0 / 0 | 仅压缩路径 |
| both     | 200 / 200 | 50 / 50 | 实际部署形态 |

50 µs 和 200 µs 是占位数。实际值按你的目标硬件（或目标加速卡）延时调，
典型软件 CRC32 per 4 KiB ≈ 20–50 µs，软件 zstd-fast per 4 KiB ≈
100–300 µs。

---

# 自动化：`scripts/bench_sim_compress.sh`

把上面 server + client 步骤封进一个脚本，方便循环 4 个 combo。

## 子命令

```bash
# Server 端
sudo bash scripts/bench_sim_compress.sh setup baseline 0 0 0 0
# Client 端（也可以是同一台机器）
sudo bash scripts/bench_sim_compress.sh probe baseline <server_ip>
# Server 端
sudo bash scripts/bench_sim_compress.sh teardown
```

四个 combo 一键扫，单机本地（server=client 同台）跑：

```bash
sudo bash scripts/bench_sim_compress.sh all <target_ip>
```

`all` 顺序跑 baseline → crc → comp → both，每个 combo 完整做 setup → probe
→ teardown，最后打总结表。结果原始 log 在 `/tmp/sim_compress_bench/`。

## Machine config

脚本顶部 `MACHINE CONFIG` 一段集中放可调项。物理机默认（`PRESET=prod`）：

```bash
TRANSPORT=RDMA
NVME_BDFS="0000:d6:00.0 0000:d9:00.0 0000:57:00.0"
LISTEN_IPS="192.168.65.81 192.168.75.81"
NQN=nqn.2016-06.io.spdk:cnode1
INITIATOR=spdk_perf
PERF_TIME=30 PERF_BS=4096 PERF_QD=1
```

按你机器实际情况改这一段，或者用 env var 覆盖，不动源文件：

```bash
NVME_BDFS="0000:af:00.0" LISTEN_IPS="10.0.0.1" \
    sudo bash scripts/bench_sim_compress.sh all 10.0.0.2
```

---

# 带宽统计

每次 `probe` 跑 fio/perf 时，脚本会同时采集三类带宽计数器，输出到
`/tmp/sim_compress_bench/measure-<combo>-<rw>.log`，并汇总进总结表的新列。

| 列 | 含义 | 数据源 |
|---|---|---|
| `TxBW(MB)` / `RxBW(MB)` | per-second 网络带宽 (MB/s) | RDMA: `/sys/class/infiniband/<dev>/ports/<port>/counters/port_{xmit,rcv}_data`；TCP: `/sys/class/net/<iface>/statistics/{tx,rx}_bytes` |
| `MemBW(MB)` | per-second 系统内存带宽 (MB/s) | Intel CPU 上 `pcm-memory` 后台采样取平均 |
| `LLCmiss%` | LLC load miss 比 | `perf stat -a -e LLC-loads,LLC-load-misses`，包住整个 probe 时长 |

不可用的列显 `-`（工具没装 / CPU 不支持 / PMU 不可读 / 在 VM 里）。

## 装依赖

```bash
# perf stat（标配）
apt install linux-tools-common linux-tools-generic
echo 0 > /proc/sys/kernel/perf_event_paranoid   # 允许 system-wide 采样

# Intel PCM（Intel 主机才有，AMD/ARM 没有）
apt install intel-cmt-cat   # Ubuntu 23.04+；早期版本从 https://github.com/intel/pcm 源码编
modprobe msr                # pcm-memory 需要 /dev/cpu/N/msr

# Mellanox RDMA 计数器走 sysfs，无需额外工具
# 仅需确认接口名和端口号：
ls /sys/class/infiniband/    # → mlx5_0 mlx5_1 ...
```

`IB_DEVICE`, `IB_PORT`, `NET_IFACE` 可以用 env var 覆盖默认值：

```bash
IB_DEVICE=mlx5_2 IB_PORT=1 sudo bash scripts/bench_sim_compress.sh all <client_ip>
```

需要单独关掉某一类采集：

```bash
DISABLE_PCM=1 DISABLE_LLC=1 sudo bash scripts/bench_sim_compress.sh all <client_ip>
```

## 单机 (server = client) 用法

`bench_sim_compress.sh all` 已经把所有采集嵌进去，跑完直接看总结表：

```bash
sudo bash scripts/bench_sim_compress.sh all 127.0.0.1
```

总结表样例（物理机 + Intel PCM 装好时）：

```
Combo     RW    IOPS      AvgLat(µs) TxBW(MB)   RxBW(MB)   MemBW(MB)   LLCmiss%
baseline  write 850k      35          3300       3300       18000       12
crc       write 320k      85          1250       1250       42000       28
comp      write 180k      180         700        700        65000       38
both      write 145k      225         565        565        82000       45
```

baseline → comp 横向看：

- IOPS 跌（CPU 被 memcpy 吃掉）
- 网络带宽**线性**跟着 IOPS 跌（IOPS × 4K = MB/s）
- 内存带宽**飙升**（baseline 18 GB/s → both 82 GB/s，是 IOSTASH 失效后 DMA 写得绕道 DRAM 的直接证据）
- LLC miss% **上升**（scratch 走多了把 L3 内容冲掉）

## Server / Client 分离用法

物理 NoF 测试通常 client 在另一台机器上。client 端的 perf/fio 跑在 client 上，
但**很多关键计数器只在 server 端有意义**（server 的内存子系统才是被 CRC/
压缩仿真冲击的对象；server 端 NIC 计数器反映出口带宽；client 的 NIC 计数器
反映入口带宽，对称看）。

### Server 端：先 setup，然后另开一个会话做 server 侧采集

```bash
# Session 1（保持开着）：起 target
sudo bash scripts/bench_sim_compress.sh setup baseline 0 0 0 0

# Session 2（在 client 那边的 perf 跑起来之前几秒启动）：
sudo bash scripts/bench_sim_compress.sh server-measure baseline 30
# → 后台跑 pcm-memory + perf stat 30 秒 + NIC 计数器 diff
#   结果写到 /tmp/sim_compress_bench/measure-server-baseline.log
```

`server-measure` 子命令存在的意义就是：当 `probe` 跑在远程 client 上的时候，
server 这边没人触发采集，需要用这个命令在 server 侧并行采集。`duration_s`
最好等于 client 那边 `PERF_TIME`。

### Client 端：跑 probe

```bash
sudo bash scripts/bench_sim_compress.sh probe baseline <server_ip>
# 在 client 自己的 /tmp/sim_compress_bench/measure-baseline-{write,read}.log
# 里有 client 侧 NIC 计数器 + （如果 client 也装了 pcm）client 内存带宽
```

### Server 端：teardown，切下一个 combo

```bash
sudo bash scripts/bench_sim_compress.sh teardown

# 改 env var，重起，重做 server-measure：
sudo bash scripts/bench_sim_compress.sh setup crc 0 0 50 50
sudo bash scripts/bench_sim_compress.sh server-measure crc 30
# ...
```

### 把 server 侧 measure log 拉回 client 合并

server-measure 的输出是单个 KV 文件，scp 回来跟 client 的 measure log 放在
同一个 `RESULTS_DIR` 下就行：

```bash
# 在 client 端
scp server:/tmp/sim_compress_bench/measure-server-*.log /tmp/sim_compress_bench/
```

然后 client 端跑 `bench_sim_compress.sh summary`（如果想自己加一列 server-side
mem_mbps / llc_miss_pct，复制 summarize 函数改一下 `_mread` 取 server log 即可，
这里不展开）。

---

# 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `nvmf_tgt` 启动报 `Cannot get hugepage information` | 没分配 hugepage | `echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages` 后 `mount -t hugetlbfs nodev /dev/hugepages` |
| `bind() failed at port 4420, errno = 98` | 旧的 nvmf_tgt 没退干净 | `pkill -9 -f build/bin/nvmf_tgt` 后重起 |
| `bdev_nvme_attach_controller` 报 device busy | NVMe 还在内核驱动上 | 先跑 `PCI_ALLOWED=... ./scripts/setup.sh` 绑到 vfio/uio |
| 没有 `sim_compress: enabled` 日志 | 编译期没带 patch | 检查 `lib/nvmf/ctrlr_bdev.c` 顶部 `SPDK_SIM_COMPRESS=1`，重新 `make` |
| 改了 `SPDK_SIM_*_US` 延时不变 | env var 没透传，或 nvmf_tgt 没重启 | env var 必须 `export` 后再启 nvmf_tgt；运行中改无效，要重启 |
| client perf 报 `Failed to initialize DPDK` | initiator 那边也要 hugepage | client 主机上同样 `echo 1024 > .../nr_hugepages` |
| 同样 us 配置在两台机器上延时差很多 | 这是设计上的预期 —— memcpy 吞吐受 DDR 代数 / NUMA / hugepage / CPU 频率影响 | 跨机比较时报 **combo - baseline 的 delta**，不报绝对值 |

---

# 实现要点

- **memcpy-for-us 循环**：`sim_compress_memcpy_for_us(iov, iovcnt, target_tsc)`
  在 scratch 上用**移动指针**重复拷贝 payload，直到 `spdk_get_ticks() -
  start >= target_tsc`。每次循环写到 scratch 的不同偏移，避免每次都打到
  同一条 L1/L2 cache line。
- **Scratch 大小**：默认 4 MiB（`SPDK_SIM_SCRATCH_KB=4096`），大于任何
  现代 CPU 单核 L2。要超过 LLC 强制 DRAM 流量，设到 `65536` (64 MiB)。
  per-reactor-thread 各自一块，`spdk_zmalloc` 分配 DMA-able 内存。
- **每阶段独立循环**：CRC 一次 + Compress 一次，模拟两次独立数据扫描。
- **不修改 payload**：scratch 是写入目标，`req->iov` 原数据不动，提交到
  底层 bdev 的依然是原指针。
- **只挂 bdev 路径**：admin cmd、zcopy、compare-and-write、fused 等不动。
  zcopy 走 `nvmf_bdev_ctrlr_zcopy_start` 路径，本补丁不触发。

## 单元测试

```bash
./test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut
```

应当报 9/9 tests, 156/156 asserts 全过。

---

# 附录 A：OrbStack / 无 RDMA / 无物理 NVMe

在 macOS OrbStack Ubuntu VM、或任何没 RDMA NIC + 没物理 NVMe 的 Linux 上，
用 `PRESET=orbstack` 切到 TCP + malloc bdev + 内核 nvme-tcp + fio：

```bash
sudo modprobe nvme-tcp
sudo apt-get install -y nvme-cli fio

PRESET=orbstack sudo bash scripts/bench_sim_compress.sh all 127.0.0.1
```

脚本会自动：

- 容器/VM 共享内核没 hugepage 时切到 DPDK `--no-huge --legacy-mem`
- devtmpfs 不响应内核 hotplug 时从 `/sys/class/block` 读 major:minor mknod

输出格式同物理机路径。**这里跑出来的绝对数值代表不了任何 RDMA + 物理 NVMe
主机的真实性能** —— 用来确认补丁逻辑、scratch 在动、延时增量大致符合
配置，不用来对比不同 x86 平台。

## A.1 OrbStack aarch64 实测

`PERF_TIME=15 PRESET=orbstack`，TCP loopback，3×malloc bdev：

```
Combo     RW    IOPS      AvgLat(µs) TxBW(MB)   RxBW(MB)   MemBW(MB)   LLCmiss%
baseline  write 23.1k     42.16       94         94         -           -
baseline  read  25.5k     38.16       104        104        -           -
crc       write 7760      127.49      31         31         -           -
crc       read  10.1k     97.38       41         41         -           -
comp      write 3751      265.02      15         15         -           -
comp      read  3872      256.76      15         15         -           -
both      write 3213      309.63      13         13         -           -
both      read  2919      340.97      11         11         -           -
```

OrbStack VM 上：

- **网络带宽**正常采集（`lo` 接口 byte 计数）；TxBW 和 RxBW 完全相同因为
  loopback 每个发送字节也算 receive
- **内存带宽** `-`：pcm-memory 只在 Intel CPU 上有，Apple Silicon ARM 没有
- **LLCmiss%** `-`：OrbStack 共享 macOS kernel 没暴露 PMU，`perf stat
  LLC-loads` 报 `<not supported>`

延时和带宽都跟 IOPS 同比走，证明补丁逻辑通了。**真正的内存带宽 / DDIO /
LLC 信号要在物理 Intel/AMD 主机上跑才能看到** —— 那里 baseline 和 comp
的内存带宽差距应在 5–10× 之间（IOSTASH 失效的硬证据）。
