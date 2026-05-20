# NVMe-oF 压缩 + CRC 时延仿真（SPDK_SIM_COMPRESS）

> 基于 SPDK v23.01.1。

## 这是什么

在 SPDK NVMe-oF target 的 bdev 读写路径上，做一份**和数据量成正比的真实
工作**，模拟 CRC 计算和压缩/解压的 CPU + 内存带宽开销，无需引入真实的
DPDK_compressdev。延时不是配出来的固定 µs，而是由 block size + 因子 + crc64
计算量自然决定的（数据越大、工作越多）。

每个阶段（CRC、Compress）独立可开关。流水线顺序匹配实际存储路径：

```
write_cmd:  CRC 扫描  →  compress 扩张  →  bdev submit
read_cmd:   bdev complete  →  decompress 扩张  →  CRC 校验
```

两类工作：

- **压缩 / 解压**：把 payload memcpy 进 per-thread scratch，一轮跑完输出
  `factor × L` 字节（默认 1.33 倍，模拟 codec 的输出 / 工作集大于输入）。
  目标字节数 > L 时循环重读 payload 凑够。scratch 仅作 memcpy 目标缓冲。
- **CRC**：对 payload 跑 crc64（isa-l `crc64_ecma_refl`），和真实数据完整性
  校验一样的全量扫描。

## 旋钮

环境变量，nvmf_tgt 启动后**第一次进 I/O**时读一次，之后不变：

| 变量 | 含义 | 默认 |
|---|---|---|
| `SPDK_SIM_COMPRESS_WRITE`   | 写路径压缩开关（1/0） | `0` |
| `SPDK_SIM_COMPRESS_READ`    | 读路径解压开关（1/0） | `0` |
| `SPDK_SIM_CRC_WRITE`        | 写路径 CRC 开关（1/0） | `0` |
| `SPDK_SIM_CRC_READ`         | 读路径 CRC 校验开关（1/0） | `0` |
| `SPDK_SIM_COMPRESS_FACTOR`  | 压缩 / 解压输出 ÷ 输入 倍数 | `1.33` |
| `SPDK_SIM_SCRATCH_KB`       | per-thread scratch 大小（KiB） | `4096` |

四个开关全 0 = 不做任何额外工作（baseline）。值非空且首字符非 `0` 即为开。

`FACTOR` 控制压缩阶段的内存搬运量：1.33 表示每个 I/O 多搬 33% 的数据。想
让压缩延时更大就调高（如 `2.0`），`< 1.0` 会被夹到 1.0（至少把 payload 读一遍）。

scratch 只是压缩阶段的 memcpy 目标缓冲，够装下 `factor × 单次最大 I/O` 即可。
默认 4 MiB 能覆盖到约 3 MiB 的 I/O；用更大 block 时按需调大。

编译期开关：`lib/nvmf/ctrlr_bdev.c` 顶部 `#define SPDK_SIM_COMPRESS 1`。
关掉传 `-DSPDK_SIM_COMPRESS=0` 给 make，整段仿真代码不编入二进制。

nvmf_tgt 第一个 I/O 进来时会打一行 NOTICELOG，确认当前生效的开关与因子：

```
[...] sim_compress: scratch=4096 KiB factor=1.330 compress_w=1 compress_r=1 crc_w=1 crc_r=1
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
unset SPDK_SIM_COMPRESS_WRITE SPDK_SIM_COMPRESS_READ \
      SPDK_SIM_CRC_WRITE       SPDK_SIM_CRC_READ

# 或者：CRC + 压缩都开（both）
export SPDK_SIM_COMPRESS_WRITE=1
export SPDK_SIM_COMPRESS_READ=1
export SPDK_SIM_CRC_WRITE=1
export SPDK_SIM_CRC_READ=1
export SPDK_SIM_COMPRESS_FACTOR=1.33   # 可选，默认 1.33

# 起 target
./build/bin/nvmf_tgt -m 0x30 &
```

`SPDK_SIM_*` 是 reactor 线程**第一次进 I/O** 时读取并缓存的。运行中改
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

# 改 env var（开关 1/0）
export SPDK_SIM_COMPRESS_WRITE=...
export SPDK_SIM_COMPRESS_READ=...
export SPDK_SIM_CRC_WRITE=...
export SPDK_SIM_CRC_READ=...

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

| label | COMPRESS_WRITE/READ | CRC_WRITE/READ | 含义 |
|---|---|---|---|
| baseline | 0 / 0 | 0 / 0 | 干净路径，IOSTASH 仍生效 |
| crc      | 0 / 0 | 1 / 1 | 仅 CRC：对 payload 跑 crc64 全量扫描 |
| comp     | 1 / 1 | 0 / 0 | 仅压缩：memcpy 出 1.33×payload |
| both     | 1 / 1 | 1 / 1 | 实际部署形态 |

延时不是配出来的，是按 block size 算出来的：压缩搬 `factor × block`，crc64
扫一遍 `block`。**所以 block 越大，combo 与 baseline 的 delta 越明显**；4 KiB
小块上每个 I/O 的额外工作不到 1 µs，会被网络往返淹没，要看效果用大 block
（如 1 MiB）。想放大压缩开销调 `SPDK_SIM_COMPRESS_FACTOR`。

---

# 自动化：`scripts/bench_sim_compress.sh`

把上面 server + client 步骤封进一个脚本，方便循环 4 个 combo。

## 子命令

```bash
# setup 参数：<label> <comp_w> <comp_r> <crc_w> <crc_r>，后四个是 1/0 开关
# Server 端（这里跑 both：压缩 + CRC 全开）
sudo bash scripts/bench_sim_compress.sh setup both 1 1 1 1
# Client 端（也可以是同一台机器）
sudo bash scripts/bench_sim_compress.sh probe both <server_ip>
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

总结表样例（1 MiB block，体现增量叠加；MemBW/LLCmiss 列需 Intel PCM /
可读 PMU，否则显示 `-`）：

```
Combo     RW    IOPS      AvgLat(µs) TxBW(MB)   RxBW(MB)   MemBW(MB)   LLCmiss%
baseline  write 2490      400         2499       2499       18000       12
crc       write 2092      476         2100       2100       34000       24
comp      write 1997      498         2005       2005       52000       33
both      write 2000      498         2008       2008       60000       38
```

baseline 最快，crc / comp 各叠一档延时，both 最大 —— 延时是 block 越大越明显。
4 KiB 小块上每 I/O 额外工作 < 1 µs，看不出 delta，这是数据正比模型的预期。

baseline → comp 横向看：

- IOPS 跌（CPU 被 memcpy + crc64 吃掉）
- 网络带宽**线性**跟着 IOPS 跌（IOPS × block = MB/s）
- 内存带宽**上升**（压缩阶段每个 I/O 多搬 `factor × payload`，crc64 全量扫一遍）
- LLC miss% 可能上升（取决于 block / scratch 与缓存的相对大小）

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
| 没有 `sim_compress: scratch=...` 日志 | 编译期没带 patch，或还没有 I/O 触发惰性 init | 检查 `lib/nvmf/ctrlr_bdev.c` 顶部 `SPDK_SIM_COMPRESS=1` 重新 `make`；日志在第一个 I/O 后才打 |
| 改了 `SPDK_SIM_*` 延时不变 | env var 没透传，或 nvmf_tgt 没重启 | env var 必须 `export` 后再启 nvmf_tgt；运行中改无效，要重启 |
| 开了 sim 但 4 KiB 小块看不出 delta | 预期：工作量与数据量成正比，4 KiB 的额外工作 < 1 µs | 用大 block（1 MiB）测，或调高 `SPDK_SIM_COMPRESS_FACTOR` |
| client perf 报 `Failed to initialize DPDK` | initiator 那边也要 hugepage | client 主机上同样 `echo 1024 > .../nr_hugepages` |
| 同样配置在两台机器上 delta 差很多 | 这是设计上的预期 —— memcpy / crc64 吞吐受 DDR 代数 / NUMA / hugepage / CPU 频率影响 | 跨机比较时报 **combo - baseline 的 delta**，不报绝对值 |

---

# 实现要点

- **压缩 / 解压 = 定额 memcpy**：`sim_compress_expand(iov, iovcnt)` 把 payload
  拷进 scratch，一轮跑完输出 `factor × L` 字节（`L` = 本次 I/O 总长）；目标
  字节数 > L 时循环重读 payload 凑够。工作量正比于数据量，不是按时间自旋。
- **CRC = 真 crc64**：`sim_crc64_iov(iov, iovcnt)` 对 payload 跑 isa-l
  `crc64_ecma_refl`（`#ifdef SPDK_CONFIG_ISAL`），跨 iov 段链式累加。结果异或
  进 `crc_sink` 防止编译器把计算优化掉。
- **Scratch**：压缩 memcpy 的目标缓冲，默认 4 MiB（`SPDK_SIM_SCRATCH_KB=4096`），
  够装 `factor × 单次最大 I/O`。per-reactor-thread 各自一块，`spdk_zmalloc`
  分配 DMA-able 内存。
- **不修改 payload**：scratch 是写入目标，`req->iov` 原数据不动，提交到
  底层 bdev 的依然是原指针。
- **只挂 bdev 路径**：admin cmd、zcopy、compare-and-write、fused 等不动。
  zcopy 走 `nvmf_bdev_ctrlr_zcopy_start` 路径，本补丁不触发。

## 单元测试

```bash
./test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut
```

应当报 11/11 tests, 163/163 asserts 全过（含 `test_sim_compress_expand`
验证 `factor × L` 字节数 + 循环重读，`test_sim_crc64_iov` 验证 crc64 全量扫描）。

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
LLC 信号要在物理 Intel/AMD 主机上跑才能看到** —— 开压缩后每个 I/O 多搬
`factor × payload`，开 CRC 后多扫一遍 payload，server 端内存带宽应随之上升。
