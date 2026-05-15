# NVMe-oF 压缩延时仿真（SPDK_SIM_COMPRESS）

> 基于 SPDK v23.01.1。
> 目标平台：aarch64 Linux（x86_64 也兼容，本文以 aarch64 为主）。
> 附录给出 macOS / OrbStack 在没有 Linux 物理机时的替代流程。

## 背景

SPDK 自带的 NVMe-oF target 不内置在线压缩。研究或基线对比时，常想问"假如在
target 端加一遍透明压缩/解压，单 I/O 延时和整体 QPS 会变成什么样？"——没必要
真的拉一个 ISA-L / DPDK_compressdev / 加速卡进来，只要在 I/O 路径上加一段同等
代价的工作即可。

本补丁在 `lib/nvmf/ctrlr_bdev.c` 的读写路径上**注入两段动作**：

- **memcpy 整段 payload** —— 模拟"压缩/解压所需的 CPU 拷贝代价"，开销随 I/O
  size 线性变化。
- **可选 busywait** —— 模拟"卸载到加速器或加密引擎的固定延时"，单位微秒，由
  环境变量控制。

写路径的注入点在 `spdk_bdev_writev_blocks` 提交之前（仿真"压缩后再下发"），读
路径在 `nvmf_bdev_ctrlr_complete_cmd` 完成回调里（仿真"先解压再上报"）。

## 适用与不适用

适用：

- 端到端延时/带宽对比："加上压缩开销之后" vs "干净 SPDK NVMe-oF"
- 在没有真实压缩硬件的环境里做"如果有"的可行性预演
- 通过调 busywait us 数，扫一遍"压缩需要多快才不亏"

不适用：

- 真要做实际压缩 —— 用 SPDK 自带的 `bdev_compress`（基于 reduce）或 vbdev
  passthrough 改造
- 模拟 DMA / 卸载的**异步**延时 —— 当前实现是同步阻塞 reactor 的 busywait，
  并发下表现的是"CPU 被占用"，而不是"I/O 等加速器返回"

## 编译期开关

`lib/nvmf/ctrlr_bdev.c` 顶部：

```c
#ifndef SPDK_SIM_COMPRESS
#define SPDK_SIM_COMPRESS 1
#endif
```

- 默认 **ON**。本分支 (`sim-compress-23.01.1`) 编出来的 `nvmf_tgt` 就带仿真。
- 关掉：构建时给 `make` 传 `EXTRA_CFLAGS=-DSPDK_SIM_COMPRESS=0`，或把这一行的
  `1` 改成 `0`。关掉之后整段仿真代码不会被编进二进制，运行时零开销。

## 运行时旋钮（环境变量）

两个值在 reactor 线程**首次进入仿真路径**时一次性读取，之后不再变化：

| 变量 | 含义 | 默认 |
|---|---|---|
| `SPDK_SIM_COMPRESS_WRITE_US` | 每次写在 `spdk_bdev_writev_blocks` 之前额外 busywait 的微秒数 | `0` |
| `SPDK_SIM_COMPRESS_READ_US`  | 每次读在完成回调返回前额外 busywait 的微秒数 | `0` |

注意：

- **memcpy 始终会做**（只要编译期开关是 ON），不管环境变量是否设置。0 表示
  "只算 memcpy 的 CPU 成本，不额外加固定延时"。
- 环境变量只在 `nvmf_tgt` 启动时生效；中途改了要重启 target。
- 取值是 **per-thread 缓存**的，每个 reactor 线程在第一个 I/O 进来时各自
  初始化一次，第一次会打一条 `NOTICELOG`，例：

      [...] ctrlr_bdev.c:NN:sim_compress_init_once: *NOTICE*:
            sim_compress: enabled write_us=200 read_us=200

---

## 在 aarch64 Linux 上构建并验证（主线）

### 1. 主机准备

aarch64 Linux 主机（Ubuntu 22.04/24.04，或同等发行版），需要：

- 内核版本 ≥ 5.15，已编译/可加载 `nvme-tcp` 模块
- 至少 2 GiB 空闲内存可分配给 hugepage（1024 个 2 MiB）
- root 权限（hugepage 分配、`nvme connect`、modprobe）

```bash
sudo modprobe nvme-tcp
ls /dev/nvme-fabrics            # 确认 fabric driver 加载
```

### 2. 拉代码 + 装依赖

```bash
git clone https://github.com/Micuks/spdk.git
cd spdk
git checkout sim-compress-23.01.1
git submodule update --init --recursive
sudo scripts/pkgdep.sh
sudo apt-get install -y nvme-cli fio    # 验证脚本依赖
```

> `pkgdep.sh` 会装 SPDK 编译时所有依赖（meson, ninja, libcunit1-dev,
> libaio-dev, libssl-dev, libnuma-dev, isa-l 相关 autotools 等）。

### 3. 构建

```bash
./configure --target-arch=native --enable-debug
make -j$(nproc)
```

主要产物：

- `build/bin/nvmf_tgt`
- `build/examples/perf`, `build/examples/bdevperf`

### 4. 配置 hugepage

```bash
sudo scripts/setup.sh                    # SPDK 自带，把 1024 个 2 MiB hugepage
                                          # 挂到 /dev/hugepages
cat /proc/sys/vm/nr_hugepages            # 应 ≥ 1024
```

`setup.sh` 也会把内核里的 NVMe 设备绑到 vfio/uio —— 仅在你打算用 SPDK 自己
驱动物理 NVMe 时需要；本验证用 malloc bdev，所以这一步**可以跳过**，自己
分配 hugepage 即可：

```bash
echo 1024 | sudo tee /proc/sys/vm/nr_hugepages
```

### 5. 跑验证脚本

```bash
sudo scripts/sim_compress_verify.sh baseline 0 0      # 不加固定延时
sudo scripts/sim_compress_verify.sh sim200   200 200  # 注入 200 µs 读/写
```

`sim_compress_verify.sh` 做的事：

1. 启动 `nvmf_tgt`（hugepage 路径），创建 64 MiB `Malloc0` bdev
2. 起 TCP transport，subsystem `nqn.2026-05.io.spdk:sim` listen 127.0.0.1:4420
3. `nvme connect -t tcp` 把内核 nvme-tcp 接上来
4. 等 udev 在 `/dev/nvmeXn1` 创建块设备
5. `fio` `randwrite` / `randread`，4K，QD=1，5 s，提取关键延时分位

输出关键行：

```
==> [baseline] hugepage mode: nr_hugepages=1024
...
--- [baseline] randwrite ---
  write: IOPS=XXk, BW=XX MiB/s ...
     lat (usec): min=X, max=X, avg=NN.NN ...
```

对比两次跑的 `avg lat`，差值应接近你配置的 `WRITE_US` / `READ_US`。

### 预期结果

实测时 baseline 延时主要由"TCP socket + bdev 提交回路"决定，单核 ~30–50 µs
是健康范围。加 200 µs busywait 后延时增幅应**接近线性**（±10% 抖动），IOPS
按 `1 / (baseline + busywait)` 比例下降，因为 QD=1。

---

## 调优 / 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `nvmf_tgt` 启动报 `Cannot get hugepage information` | 没分配 hugepage | `echo 1024 \| sudo tee /proc/sys/vm/nr_hugepages` |
| `nvme connect` 报 `Connection refused` | nvmf_tgt 没起来 / 端口没 listen | 看 `/tmp/nvmf_tgt-<label>.log` 末尾 |
| `/dev/nvme0n1` 出不来 | nvme-tcp 内核模块没加载 | `sudo modprobe nvme-tcp` |
| 没有 `sim_compress: enabled` 日志 | 编译没带补丁 | 检查 `lib/nvmf/ctrlr_bdev.c` 头部 `SPDK_SIM_COMPRESS=1`，重新 `make` |
| 加 us 数延时不变 | env var 没透传给 `nvmf_tgt` | 验证脚本里是 `export` 给子进程；手动启动时也要 `export` 后再 `./nvmf_tgt` |

---

## 实现要点

- **scratch 缓冲**：每个 reactor 线程通过 `spdk_zmalloc` 分配 128 KiB DMA
  内存。memcpy 时把 `req->iov[]` 的所有片段顺序拷进这块 scratch（超过 128
  KiB 的 I/O 会分段循环重用 scratch）。`req->iov` 原数据**不动**，提交到底层
  bdev 的依然是原指针，仅多消耗一次内存带宽。
- **busywait 阻塞 reactor**：使用 `spdk_get_ticks` 自旋。这是有意的设计 ——
  reactor 单线程，仿真"压缩 CPU 占用"必须阻塞其它待处理 I/O；要做异步等价
  物得换 `spdk_poller_register` + timeout 回调。
- **只挂 bdev 路径**：admin cmd、zcopy、compare-and-write、fused 等不动。
  如果改用 zcopy 走 `nvmf_bdev_ctrlr_zcopy_start` 路径，本补丁**不会**触发
  —— 想覆盖到要单独再加。

## 单元测试

`test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut.c` 增了 3 个 stub：

```c
DEFINE_STUB(spdk_get_ticks,    uint64_t, (void), 0);
DEFINE_STUB(spdk_get_ticks_hz, uint64_t, (void), 1000000000ULL);
DEFINE_STUB(spdk_zmalloc,      void *,
    (size_t, size_t, uint64_t *, int, uint32_t), NULL);
```

`spdk_zmalloc` 返回 NULL 触发"scratch 分配失败"分支 ——
`sim_compress_memcpy_iov` 会 early return，所以单元测试里 memcpy 不会真的
跑，原有 9/9 用例 156/156 asserts 不变。

跑测试：

```bash
./test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut
```

## 文件改动

```
lib/nvmf/ctrlr_bdev.c                           +133  仿真主体 + 2 个 hook
test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut.c +7    新增 3 个 stub
scripts/sim_compress_verify.sh                  新建  端到端验证脚本
.docker/Dockerfile.builder                      新建  附录：macOS/Docker 构建镜像
doc/sim_compress.md                             新建  本文档
```

---

## 附录 A：macOS + OrbStack 上的替代流程（没有 Linux 物理机时）

OrbStack VM 内核**没启用 explicit hugepage**，且容器 devtmpfs 不会响应内核
hotplug。`sim_compress_verify.sh` 已经自动检测这两点并切到对应 fallback：

- **hugepage 不可用** → 用 DPDK `--no-huge --legacy-mem` 起 `nvmf_tgt`
- **`/dev/nvmeXn1` 没出现** → 从 `/sys/class/block/` 读 `major:minor` 手动
  `mknod`

因此**同一份脚本**在容器里也能跑，无需改动。区别只有：性能不代表真实硬件，
但 sim_compress 的延时差仍然成立（用来验证补丁逻辑足够）。

### A.1 构建可复用镜像

`.docker/Dockerfile.builder` 把 SPDK 全部依赖打进一个本地镜像，后续跑验证不
再依赖网络。

```bash
# host.docker.internal 用 host-gateway 别名挂到 OrbStack 网关，间接到达宿主
# mihomo 的 HTTP 代理 7892（你的实际端口请自己替换）。
docker build \
  --add-host=host.docker.internal:host-gateway \
  --build-arg HTTP_PROXY=http://host.docker.internal:7892 \
  --build-arg HTTPS_PROXY=http://host.docker.internal:7892 \
  -t spdk-builder:23.01.1 \
  -f .docker/Dockerfile.builder .
```

### A.2 容器里编 SPDK

submodule 仓库的 `git submodule update --init` 在容器里需要走代理；为了避免
`git worktree` 反向引用 `.git/worktrees/...` 解析失败，建议直接 clone 单个
submodule 仓库到对应路径（commit 信息可以从 `git ls-tree HEAD <path>` 查
到）：

```bash
docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -e http_proxy=http://host.docker.internal:7892 \
  -e https_proxy=http://host.docker.internal:7892 \
  -v $(pwd):/spdk -w /spdk \
  spdk-builder:23.01.1 bash

# 容器内
git clone --depth=200 https://github.com/spdk/dpdk.git dpdk
git -C dpdk fetch origin spdk-22.11.1
git -C dpdk checkout 6fb6205c214b81af08d6e82d1c634f1a5cb1a8bb

git clone --depth=50 https://github.com/spdk/isa-l.git isa-l
git -C isa-l fetch origin c196241ae89b1aa4f62efeb849a937c011b3a926
git -C isa-l checkout c196241ae89b1aa4f62efeb849a937c011b3a926

git clone --depth=50 https://github.com/intel/isa-l_crypto isa-l-crypto
git -C isa-l-crypto fetch origin 08297dc3e76d65e1bad83a9c9f9e49059cf806b5
git -C isa-l-crypto checkout 08297dc3e76d65e1bad83a9c9f9e49059cf806b5

bash ./configure --target-arch=native --without-crypto --without-ocf \
                 --without-xnvme --without-vfio-user --without-rdma --enable-debug
make DPDKBUILD_FLAGS='-Dplatform=generic' -j$(nproc)
```

Apple Silicon CPU implementer ID 0x61 不在 DPDK 默认识别表里，所以加
`-Dplatform=generic`。x86 Linux 不用。

### A.3 起验证容器并执行

```bash
docker run -d --name spdk-run --rm \
  --privileged --shm-size=512m \
  -v $(pwd):/spdk \
  --tmpfs /dev/hugepages:rw,size=512m \
  spdk-builder:23.01.1 sleep infinity

docker exec spdk-run bash /spdk/scripts/sim_compress_verify.sh baseline 0 0
docker exec spdk-run bash /spdk/scripts/sim_compress_verify.sh sim200   200 200
```

### A.4 实测结果（参考，OrbStack aarch64 / 1 reactor / QD=1 / 4K）

| 指标 | baseline (0/0 µs) | sim200 (200/200 µs) | delta |
|---|---|---|---|
| randwrite 平均延时 | 41.79 µs | 283.33 µs | **+242 µs** |
| randread 平均延时  | 40.07 µs | 263.65 µs | **+224 µs** |
| randwrite IOPS     | 23.4k    | 3.5k      | −85 % |
| randread IOPS      | 24.4k    | 3.8k      | −85 % |

延时增量与 `*_US` 配置吻合（busywait 含 memcpy 自身耗时）。IOPS 等比例
下降（QD=1 时 `1/(基线+busywait)` 决定吞吐）。同一脚本同一二进制在 bare
aarch64 Linux 上跑数值会更干净（hugepage + 物理 TCP loopback 比容器化路径少
一层开销），但**延时增量的形状不变**。

## 附录 B：mihomo / Clash 之类 TUN 代理引起的容器 DNS 故障

若宿主在跑 mihomo 等 TUN 模式代理且 `dns:` block 配置缺失，容器、宿主一切
DNS 查询会 SERVFAIL。`.docker/Dockerfile.builder` 用 `--add-host=
host.docker.internal:host-gateway` 把容器请求经 OrbStack gateway 转回宿主
HTTP 代理（绕开 DNS），是这种环境下的常规救场办法。
