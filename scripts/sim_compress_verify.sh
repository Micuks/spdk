#!/bin/bash
# Verify SPDK_SIM_COMPRESS latency injection.
# Target: SPDK nvmf_tgt with malloc bdev, NVMe-oF over TCP loopback.
# Initiator: kernel nvme-tcp + fio.
#
# Auto-detects:
#   - hugepage availability  → falls back to DPDK --no-huge if missing
#   - devtmpfs hotplug       → mknod fallback if /dev/nvmeXn1 doesn't appear
#
# Requires (Linux host):
#   - root (nvme connect, modprobe, /dev/nvme-fabrics, hugepage tuning)
#   - kernel module nvme-tcp (built-in or loadable)
#   - nvme-cli, fio
#   - built SPDK with this branch's patch
#
# Usage:  sim_compress_verify.sh "<label>" [comp_w_us] [comp_r_us] [crc_w_us] [crc_r_us]
#   comp_w_us / comp_r_us — busywait microseconds for the compression stage
#   crc_w_us  / crc_r_us  — busywait microseconds for the CRC stage
# memcpy always runs (one pass per stage when compiled with SPDK_SIM_COMPRESS=1).
set -eu

LABEL="${1:-baseline}"
COMP_W_US="${2:-0}"
COMP_R_US="${3:-0}"
CRC_W_US="${4:-0}"
CRC_R_US="${5:-0}"

# Resolve SPDK root from script location (scripts/ is sibling of build/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPDK_DIR="${SPDK_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SOCK=/tmp/spdk_sim.sock
RPC="$SPDK_DIR/scripts/rpc.py"
TGT="$SPDK_DIR/build/bin/nvmf_tgt"
NQN=nqn.2026-05.io.spdk:sim
LOG_DIR="${LOG_DIR:-/tmp}"
TGT_LOG="$LOG_DIR/nvmf_tgt-$LABEL.log"

[ -x "$TGT" ] || { echo "FAIL: nvmf_tgt not built at $TGT"; exit 1; }
[ -f "$RPC" ] || { echo "FAIL: rpc.py not found at $RPC"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "FAIL: must run as root"; exit 1; }
command -v nvme >/dev/null || { echo "FAIL: nvme-cli not installed"; exit 1; }
command -v fio  >/dev/null || { echo "FAIL: fio not installed"; exit 1; }

cleanup() {
    nvme disconnect -n $NQN >/dev/null 2>&1 || true
    if [ -n "${TGT_PID:-}" ]; then
        kill $TGT_PID 2>/dev/null || true
        wait $TGT_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

pkill -f "$TGT" 2>/dev/null || true
nvme disconnect -n $NQN >/dev/null 2>&1 || true
rm -f $SOCK
sleep 1

# nvme-tcp kernel module
if [ ! -e /sys/module/nvme_tcp ] && [ ! -e /sys/module/nvme-tcp ]; then
    modprobe nvme-tcp 2>/dev/null || true
fi
[ -e /dev/nvme-fabrics ] || { echo "FAIL: /dev/nvme-fabrics missing (nvme-tcp not loaded)"; exit 1; }

# --- Environment detection -------------------------------------------------
# Real Linux: writable nr_hugepages → allocate, use default DPDK path.
# Otherwise (OrbStack VM, locked-down container): --no-huge --legacy-mem.
EAL_EXTRA=""
if [ -w /proc/sys/vm/nr_hugepages ] && [ -d /sys/kernel/mm/hugepages ]; then
    CUR=$(cat /proc/sys/vm/nr_hugepages)
    if [ "$CUR" -lt 512 ]; then
        echo "==> [$LABEL] allocating 512 x 2 MiB hugepages (was $CUR)"
        echo 512 > /proc/sys/vm/nr_hugepages
    fi
    MEM_SIZE_MB=1024
    echo "==> [$LABEL] hugepage mode: nr_hugepages=$(cat /proc/sys/vm/nr_hugepages)"
else
    EAL_EXTRA="--env-context=--no-huge -m 2048 --legacy-mem"
    MEM_SIZE_MB=2048
    echo "==> [$LABEL] no-hugepage fallback (legacy-mem 2048 MiB)"
fi
# ----------------------------------------------------------------------------

export SPDK_SIM_COMPRESS_WRITE_US="$COMP_W_US"
export SPDK_SIM_COMPRESS_READ_US="$COMP_R_US"
export SPDK_SIM_CRC_WRITE_US="$CRC_W_US"
export SPDK_SIM_CRC_READ_US="$CRC_R_US"

echo "==> [$LABEL] starting nvmf_tgt (comp=${COMP_W_US}/${COMP_R_US} crc=${CRC_W_US}/${CRC_R_US} µs)"
# shellcheck disable=SC2086
if [ -n "$EAL_EXTRA" ]; then
    EAL_CTX="${EAL_EXTRA#--env-context=}"
    "$TGT" --env-context="$EAL_CTX" -s $MEM_SIZE_MB --no-pci -r $SOCK > "$TGT_LOG" 2>&1 &
else
    "$TGT" -s $MEM_SIZE_MB --no-pci -r $SOCK > "$TGT_LOG" 2>&1 &
fi
TGT_PID=$!
for _ in $(seq 1 50); do
    [ -S $SOCK ] && break
    sleep 0.2
done
[ -S $SOCK ] || { echo "FAIL: nvmf_tgt socket not up"; tail -30 "$TGT_LOG"; exit 1; }

"$RPC" -s $SOCK bdev_malloc_create -b Malloc0 64 4096 >/dev/null
"$RPC" -s $SOCK nvmf_create_transport -t TCP -u 8192 -m 2 -c 4096 -b 8 -n 64 >/dev/null
"$RPC" -s $SOCK nvmf_create_subsystem $NQN -a -s SPDKSIM01 -d Controller1 >/dev/null
"$RPC" -s $SOCK nvmf_subsystem_add_ns $NQN Malloc0 >/dev/null
"$RPC" -s $SOCK nvmf_subsystem_add_listener $NQN -t TCP -a 127.0.0.1 -s 4420 >/dev/null

echo "==> [$LABEL] connecting initiator..."
CONNECT_OUT=$(nvme connect -t tcp -a 127.0.0.1 -s 4420 -n $NQN)
echo "$CONNECT_OUT"
CTRL=$(echo "$CONNECT_OUT" | awk -F'device: ' '/connecting to device/ {print $2; exit}')
DEV="/dev/${CTRL}n1"

# Wait for udev. If devtmpfs hotplug is broken (some containers), mknod from sysfs.
for _ in $(seq 1 30); do
    [ -b "$DEV" ] && break
    sleep 0.2
done
if [ ! -b "$DEV" ]; then
    echo "==> [$LABEL] devtmpfs didn't populate $DEV, mknod from /sys"
    for sysblk in /sys/class/block/${CTRL}n*; do
        [ -e "$sysblk/dev" ] || continue
        name=$(basename "$sysblk")
        majmin=$(cat "$sysblk/dev")
        [ -b "/dev/$name" ] || mknod "/dev/$name" b "${majmin%:*}" "${majmin#*:}"
    done
fi
[ -b "$DEV" ] || { echo "FAIL: no nvme device at $DEV"; ls /sys/class/block/; exit 1; }
echo "==> [$LABEL] device: $DEV"

run_fio() {
    local rw=$1
    fio --name="$rw" --filename="$DEV" --ioengine=libaio --direct=1 \
        --rw="$rw" --bs=4k --iodepth=1 --time_based=1 --runtime=5 \
        --numjobs=1 --group_reporting --output-format=normal 2>&1 \
        | grep -E "IOPS=|lat \(usec\): *min|99\.00th|99\.95th"
}

echo "--- [$LABEL] randwrite ---"
run_fio randwrite | tee "$LOG_DIR/fio-write-$LABEL.log"
echo "--- [$LABEL] randread ---"
run_fio randread | tee "$LOG_DIR/fio-read-$LABEL.log"

echo "--- [$LABEL] nvmf_tgt sim log lines ---"
grep -E "sim_compress|sim_decompress" "$TGT_LOG" | head -5 || echo "(no sim_compress notice — check SPDK_SIM_COMPRESS build flag)"

echo "==> [$LABEL] done."
