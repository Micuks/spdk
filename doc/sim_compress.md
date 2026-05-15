# NVMe-oF 压缩延时仿真（SPDK_SIM_COMPRESS）

> 基于 SPDK v23.01.1。

## 背景

SPDK 自带的 NVMe-oF target 不内置在线压缩。研究或基线对比时，常常想问"假如在
target 端加一遍透明压缩/解压，单 I/O 延时和整体 QPS 会变成什么样？" —— 没必要
真的拉一个 ISA-L / DPDK_compressdev / 加速卡进来，只要在 I/O 路径上加一段同等
代价的工作即可。

本补丁在 `lib/nvmf/ctrlr_bdev.c` 的读写路径上**注入两段动作**：

- **memcpy 整段 payload** —— 模拟"压缩/解压所需的 CPU 拷贝代价"，开销随 I/O size
  线性变化。
- **可选 busywait** —— 模拟"卸载到加速器或加密引擎的固定延时"，单位微秒，由环境
  变量控制。

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
- 模拟 DMA / 卸载的**异步**延时 —— 当前实现是同步阻塞 reactor 的 busywait，并发
  下表现的是"CPU 被占用"，而不是"I/O 等加速器返回"

## 编译期开关

`lib/nvmf/ctrlr_bdev.c` 顶部：

```c
#ifndef SPDK_SIM_COMPRESS
#define SPDK_SIM_COMPRESS 1
#endif
```

- 默认 **ON**。本分支 (`sim-compress-23.01.1`) 编出来的 `nvmf_tgt` 就带仿真。
- 关掉：构建时传 `-DSPDK_SIM_COMPRESS=0`，或把这一行的 `1` 改成 `0`。关掉之后
  整段仿真代码不会被编进二进制，运行时零开销。

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
- 取值是 **per-thread 缓存**的，每个 reactor 线程在第一个 I/O 进来时各自初始化
  一次，第一次会打一条 `NOTICELOG`，例：

      [...] ctrlr_bdev.c:NN:sim_compress_init_once: *NOTICE*:
            sim_compress: enabled write_us=200 read_us=200

## 实现要点

- **scratch 缓冲**：每个 reactor 线程通过 `spdk_zmalloc` 分配 128 KiB DMA 内存。
  memcpy 时把 `req->iov[]` 的所有片段顺序拷进这块 scratch（超过 128 KiB 的 I/O
  会分段循环重用 scratch）。`req->iov` 原数据**不动**，提交到底层 bdev 的依然
  是原指针，仅多消耗一次内存带宽。
- **busywait 阻塞 reactor**：使用 `spdk_get_ticks` 自旋。这是有意的设计 ——
  reactor 单线程，仿真"压缩 CPU 占用"必须阻塞其它待处理 I/O；要做异步等价
  物得换 `spdk_poller_register` + timeout 回调。
- **只挂 bdev 路径**：admin cmd、zcopy、compare-and-write、fused 等不动。如果
  改用 zcopy 走 `nvmf_bdev_ctrlr_zcopy_start` 路径，本补丁**不会**触发 —— 想
  覆盖到要单独再加。

## 构建

仓库提供 `.docker/Dockerfile.builder` 把所有依赖打进一个可复用镜像，避免反复
拉包；适合 macOS / OrbStack 上没法直接编 SPDK 的情况。

```bash
# 1. 构建镜像（首次，约 5–10 分钟，取决于网络）
docker build \
  --add-host=host.docker.internal:host-gateway \
  --build-arg HTTP_PROXY=http://host.docker.internal:7892 \
  --build-arg HTTPS_PROXY=http://host.docker.internal:7892 \
  -t spdk-builder:23.01.1 \
  -f .docker/Dockerfile.builder .

# 2. 进容器编 SPDK
docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -e http_proxy=http://host.docker.internal:7892 \
  -e https_proxy=http://host.docker.internal:7892 \
  -v $(pwd):/spdk -w /spdk \
  spdk-builder:23.01.1 bash

# 容器内：
git clone --depth=200 https://github.com/spdk/dpdk.git dpdk && \
    git -C dpdk fetch origin spdk-22.11.1 && \
    git -C dpdk checkout 6fb6205c214b81af08d6e82d1c634f1a5cb1a8bb
git clone --depth=50 https://github.com/spdk/isa-l.git isa-l && \
    git -C isa-l fetch origin c196241ae89b1aa4f62efeb849a937c011b3a926 && \
    git -C isa-l checkout c196241ae89b1aa4f62efeb849a937c011b3a926
git clone --depth=50 https://github.com/intel/isa-l_crypto isa-l-crypto && \
    git -C isa-l-crypto fetch origin 08297dc3e76d65e1bad83a9c9f9e49059cf806b5 && \
    git -C isa-l-crypto checkout 08297dc3e76d65e1bad83a9c9f9e49059cf806b5

bash ./configure --target-arch=native --without-crypto --without-ocf \
                 --without-xnvme --without-vfio-user --without-rdma --enable-debug
make DPDKBUILD_FLAGS='-Dplatform=generic' -j$(nproc)
```

OrbStack VM 上要给 DPDK 加 `-Dplatform=generic`（Apple Silicon CPU implementer
ID 0x61 不在 DPDK 默认识别表里）。在标准 x86 Linux 上去掉即可。

构建产物：

- `build/bin/nvmf_tgt`
- `build/examples/perf`, `build/examples/bdevperf`

## 验证

仓库附带 `.docker/verify.sh`，一键跑"启动 nvmf_tgt + malloc bdev + TCP 子系统 +
内核 nvme-tcp + fio"对比。需要的容器是 `--privileged`（fio 走 libaio + 直接
块设备需要）。

```bash
docker run -d --name spdk-run --rm \
  --privileged --shm-size=512m \
  -v $(pwd):/spdk \
  --tmpfs /dev/hugepages:rw,size=512m \
  spdk-builder:23.01.1 sleep infinity

# baseline：memcpy 在做，但 busywait=0
docker exec spdk-run bash /spdk/.docker/verify.sh baseline 0 0

# 注入 200 us 写 + 200 us 读
docker exec spdk-run bash /spdk/.docker/verify.sh sim200 200 200
```

`verify.sh` 会自动处理几个坑：

- OrbStack 内核没 hugepage 支持 → 用 `--no-huge --legacy-mem` 给 DPDK
- 容器 devtmpfs 不反映内核 hotplug → connect 之后从 `/sys/class/block/` 读
  major:minor 手动 `mknod /dev/nvmeXn1`
- 退出时 `nvme disconnect` + `pkill nvmf_tgt`

## 实测结果

OrbStack（aarch64，1 reactor core），QD=1，4K 块，5 s：

| 指标 | baseline (0/0 us) | sim200 (200/200 us) | delta |
|---|---|---|---|
| randwrite 平均延时 | 43.84 µs | 252.98 µs | **+209 µs** |
| randread 平均延时  | 40.31 µs | 254.14 µs | **+213 µs** |
| randwrite IOPS     | 22.3k    | 3.9k      | −82 % |
| randread IOPS      | 24.2k    | 3.9k      | −84 % |

延时增量与 `*_US` 配置吻合。IOPS 等比例下降（QD=1 时 1/(基线+busywait) 决定
吞吐）。

## 关掉仿真

```bash
# 方法 1：重新 configure，加 CFLAGS
CFLAGS="-DSPDK_SIM_COMPRESS=0" bash ./configure ...

# 方法 2：把 ctrlr_bdev.c 顶部的 #define SPDK_SIM_COMPRESS 1 改成 0

# 方法 3：编译时改 mk/spdk.common.mk 的 COMMON_CFLAGS，加 -DSPDK_SIM_COMPRESS=0
```

任一方式生效后整段仿真代码都不会被编进 `libspdk_nvmf.a`。

## 单元测试

`test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut.c` 增了 3 个 stub：

```c
DEFINE_STUB(spdk_get_ticks, uint64_t, (void), 0);
DEFINE_STUB(spdk_get_ticks_hz, uint64_t, (void), 1000000000ULL);
DEFINE_STUB(spdk_zmalloc, void *,
    (size_t, size_t, uint64_t *, int, uint32_t), NULL);
```

`spdk_zmalloc` 返回 NULL 触发"scratch 分配失败"分支 ——
`sim_compress_memcpy_iov` 会 early return，所以单元测试里 memcpy 不会真的跑，
原有 9/9 用例 156/156 asserts 不变。

跑测试：

```bash
./test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut
```

## 文件列表

```
lib/nvmf/ctrlr_bdev.c                           +133  仿真主体 + 2 个 hook
test/unit/lib/nvmf/ctrlr_bdev.c/ctrlr_bdev_ut.c +7    新增 3 个 stub
.docker/Dockerfile.builder                      新建  可复用构建镜像
.docker/verify.sh                               新建  端到端验证脚本
doc/sim_compress.md                             新建  本文档
```
