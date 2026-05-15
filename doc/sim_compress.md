# NVMe-oF 压缩 + CRC 时延仿真（SPDK_SIM_COMPRESS）

> 基于 SPDK v23.01.1。

## 这是什么

在 SPDK NVMe-oF target 的 bdev 读写路径上注入两段动作，模拟 CRC 计算和
压缩/解压的 CPU 开销，无需引入真实的 ISA-L 或 DPDK_compressdev：

- **memcpy** 整段 payload，模拟数据扫描的 CPU bandwidth 消耗
- **busywait** 一段微秒数，模拟卸载到加速器/加密引擎的固定延时

每个阶段（CRC、Compress）独立可调。流水线顺序匹配实际存储路径：

```
write_cmd:  CRC scan + busywait  →  compress scan + busywait  →  bdev submit
read_cmd:   bdev complete  →  decompress scan + busywait  →  CRC validate + busywait
```

## 旋钮

四个环境变量，nvmf_tgt 启动时读一次，之后不变：

| 变量 | 含义 |
|---|---|
| `SPDK_SIM_COMPRESS_WRITE_US` | 写路径压缩 busywait 微秒数 |
| `SPDK_SIM_COMPRESS_READ_US`  | 读路径解压 busywait 微秒数 |
| `SPDK_SIM_CRC_WRITE_US`      | 写路径 CRC busywait 微秒数 |
| `SPDK_SIM_CRC_READ_US`       | 读路径 CRC 校验 busywait 微秒数 |

默认 0 即"该阶段只有 memcpy，不加固定延时"。memcpy 始终运行（编译期开关
ON 时），所以即使全 0 也会有两次 memcpy（CRC 一次 + Compress 一次）的
CPU 开销。

编译期开关：`lib/nvmf/ctrlr_bdev.c` 顶部 `#define SPDK_SIM_COMPRESS 1`。
关掉传 `-DSPDK_SIM_COMPRESS=0` 给 make，整段仿真代码不编入二进制。

nvmf_tgt 启动时会打一行 NOTICELOG，确认四个值的当前生效：

```
[...] sim_compress: enabled compress_w_us=200 compress_r_us=200 crc_w_us=50 crc_r_us=50
```

---

## 在物理 Linux 上从零到出图

下面以 aarch64 或 x86_64 物理机为目标，使用 RDMA transport + 物理 NVMe SSD
+ SPDK perf 当 initiator（C1/C2 标准 SOP 形状）。OrbStack / 无 RDMA / 无
物理 NVMe 的环境见附录 A。

### 1. 拉代码 + 装依赖

```bash
git clone https://github.com/Micuks/spdk.git
cd spdk
git checkout sim-compress-23.01.1
git submodule update --init
./scripts/pkgdep.sh
```

### 2. 编译

```bash
./configure --with-rdma
make -j$(nproc)
make install
```

### 3. 配 hugepage + 绑 NVMe 到 vfio/uio

```bash
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
mkdir -p /dev/hugepages
mount -t hugetlbfs nodev /dev/hugepages

# 把你要测的 NVMe 盘 BDF 列出来（lsscsi / lspci 查）
PCI_ALLOWED="0000:d6:00.0 0000:d9:00.0 0000:57:00.0" ./scripts/setup.sh
```

### 4. 配 RDMA 网络

```bash
nmcli connection add type ethernet con-name enp23s0f0np0 ifname enp23s0f0np0
nmcli connection modify enp23s0f0np0 ipv4.addresses 192.168.65.81/24 \
    ipv4.gateway 192.168.65.1 ipv4.method manual
nmcli connection up enp23s0f0np0
# 第二口同理
```

### 5. 起 target（带 sim 环境变量）

```bash
# 选一组 combo
export SPDK_SIM_COMPRESS_WRITE_US=200
export SPDK_SIM_COMPRESS_READ_US=200
export SPDK_SIM_CRC_WRITE_US=50
export SPDK_SIM_CRC_READ_US=50

./build/bin/nvmf_tgt -m 0x30 &
```

### 6. 配置 transport / bdev / subsystem / listener

```bash
./scripts/rpc.py nvmf_create_transport -t RDMA \
    -q 128 -m 127 -c 4096 -i 131072 -u 131072 -a 128 -n 2048 -b 0

./scripts/rpc.py bdev_nvme_attach_controller -b nvme3 -t PCIe -a 0000:d6:00.0
./scripts/rpc.py bdev_nvme_attach_controller -b nvme6 -t PCIe -a 0000:d9:00.0
./scripts/rpc.py bdev_nvme_attach_controller -b nvme0 -t PCIe -a 0000:57:00.0

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

### 7. Client 端测试

在另一台机器（C1 或 C2，根据测什么）上：

```bash
./build/examples/perf \
    -r 'trtype:RDMA adrfam:IPv4 traddr:192.168.65.81 trsvcid:4420' \
    -t 30 -w write -o 4096 -q 1

./build/examples/perf \
    -r 'trtype:RDMA adrfam:IPv4 traddr:192.168.65.81 trsvcid:4420' \
    -t 30 -w read -o 4096 -q 1
```

记录每次跑出来的 IOPS + 平均延时。

### 8. 切换 combo

`kill` 掉 nvmf_tgt，改 `export`，重起。`SPDK_SIM_*_US` 是 reactor 线程
第一次进 I/O 时读取并缓存的，运行中改环境变量不会重新生效。

四个推荐 combo：

| label | COMPRESS_WRITE/READ | CRC_WRITE/READ | 含义 |
|---|---|---|---|
| baseline | 0 / 0 | 0 / 0 | 只有 memcpy 开销，无固定延时 |
| crc      | 0 / 0 | 50 / 50 | 单独看 CRC 的代价 |
| comp     | 200 / 200 | 0 / 0 | 单独看压缩的代价 |
| both     | 200 / 200 | 50 / 50 | 实际部署形态 |

50 µs 和 200 µs 是占位数，实际值按你的硬件目标延时调（典型软件 CRC32 ~20-50 µs
per 4 KiB，软件 zstd-fast ~100-300 µs per 4 KiB）。

---

## 自动化 4-combo 扫描

仓库自带 `scripts/bench_sim_compress.sh`，按 SOP 形状把上面第 5–8 步串起来：

```bash
# Server 端
sudo bash scripts/bench_sim_compress.sh setup baseline 0 0 0 0
# Client 端
sudo bash scripts/bench_sim_compress.sh probe baseline <server_ip>
# Server 端
sudo bash scripts/bench_sim_compress.sh teardown
```

四个 combo + 总结表一行：

```bash
sudo bash scripts/bench_sim_compress.sh all <target_ip>
```

`all` 顺序跑 baseline / crc / comp / both，每个 combo 完整做 setup → probe →
teardown，最后打印一张总结表。结果原始 log 在 `/tmp/sim_compress_bench/`。

### Machine config

脚本顶部 `MACHINE CONFIG` 一段集中放可调项。物理机默认值（PRESET=prod）：

```bash
TRANSPORT=RDMA
NVME_BDFS="0000:d6:00.0 0000:d9:00.0 0000:57:00.0"
LISTEN_IPS="192.168.65.81 192.168.75.81"
NQN=nqn.2016-06.io.spdk:cnode1
INITIATOR=spdk_perf
PERF_TIME=30 PERF_BS=4096 PERF_QD=1
```

按你机器实际情况改这一段。所有变量都可以用 env var 覆盖，不用改源文件：

```bash
NVME_BDFS="0000:af:00.0" LISTEN_IPS="10.0.0.1" \
    sudo bash scripts/bench_sim_compress.sh all 10.0.0.2
```

---

## 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `nvmf_tgt` 启动报 `Cannot get hugepage information` | 没分配 hugepage | `echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages` 后 `mount -t hugetlbfs nodev /dev/hugepages` |
| `bind() failed at port 4420, errno = 98` | 旧的 nvmf_tgt 没退干净 | `pkill -9 -f build/bin/nvmf_tgt` 后重起 |
| `bdev_nvme_attach_controller` 报 device busy | NVMe 还在内核驱动上 | 先跑 `PCI_ALLOWED=... ./scripts/setup.sh` 绑到 vfio/uio |
| 没有 `sim_compress: enabled` 日志 | 编译期没带 patch | 检查 `lib/nvmf/ctrlr_bdev.c` 顶部 `SPDK_SIM_COMPRESS=1`，重新 `make` |
| 改了 `SPDK_SIM_*_US` 延时不变 | env var 没透传，或 nvmf_tgt 没重启 | env var 必须 `export` 后再启 nvmf_tgt；运行中改无效，要重启 |
| perf 报 `Failed to initialize DPDK` | initiator 那边也要 hugepage | 在 client 主机上同样 `echo 1024 > .../nr_hugepages` |

---

## 实现要点

- **scratch 缓冲**：每个 reactor 线程通过 `spdk_zmalloc` 分配 128 KiB DMA
  内存。memcpy 时把 `req->iov[]` 顺序拷进 scratch（超过 128 KiB 的 I/O
  分段循环重用）。`req->iov` 原数据**不动**，提交到底层 bdev 的依然是
  原指针，仅多消耗一次内存带宽。
- **busywait 阻塞 reactor**：用 `spdk_get_ticks` 自旋。SPDK 是单 reactor
  线程模型，仿真"CPU 占用"必须阻塞其它待处理 I/O；要做异步等价物得换
  `spdk_poller_register` + timeout 回调。
- **每阶段独立 memcpy**：CRC 一次 + Compress 一次，模拟两次数据扫描。
  合并成一次会低估内存带宽压力。
- **只挂 bdev 路径**：admin cmd、zcopy、compare-and-write、fused 等不动。
  zcopy 走 `nvmf_bdev_ctrlr_zcopy_start` 路径，本补丁不触发。

## 单元测试

```bash
./test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut
```

应当报 9/9 tests, 156/156 asserts 全过。

---

## 附录 A：OrbStack / 无 RDMA / 无物理 NVMe 环境

在 macOS OrbStack Ubuntu VM、或任何没 RDMA NIC + 没物理 NVMe 的 Linux 上，
用 `PRESET=orbstack` 切到 TCP + malloc bdev + 内核 nvme-tcp + fio：

```bash
# 容器/VM 共享内核没 hugepage 时，脚本自动用 DPDK --no-huge --legacy-mem
# devtmpfs 不响应内核 hotplug 时，脚本从 /sys/class/block 读 major:minor mknod

sudo modprobe nvme-tcp
sudo apt-get install -y nvme-cli fio

PRESET=orbstack sudo bash scripts/bench_sim_compress.sh all 127.0.0.1
```

输出格式同物理机路径，方便方法学和代码改动验证。**这里跑出来的绝对数值代
表不了任何 RDMA + 物理 NVMe 主机的真实性能** —— 用来确认补丁逻辑、延时
增量、脚本路径，不用来对比 AMD vs Intel。

### A.1 OrbStack aarch64 上的实测数

`PERF_TIME=15 PRESET=orbstack`，4K block size，QD=1，TCP loopback，malloc bdev：

| Combo | comp w/r | crc w/r | RW | IOPS | AvgLat |
|---|---|---|---|---|---|
| baseline | 0/0 | 0/0 | write | 25.7k | 37.93 µs |
| baseline | 0/0 | 0/0 | read  | 21.2k | 46.09 µs |
| crc | 0/0 | 50/50 | write | 10.5k | 94.19 µs |
| crc | 0/0 | 50/50 | read  | 10.6k | 93.07 µs |
| comp | 200/200 | 0/0 | write | 3.8k  | 259.10 µs |
| comp | 200/200 | 0/0 | read  | 3.3k  | 304.70 µs |
| both | 200/200 | 50/50 | write | 3.2k  | 312.23 µs |
| both | 200/200 | 50/50 | read  | 3.3k  | 300.28 µs |

延时增量与配置 us 数吻合 ±15%。
