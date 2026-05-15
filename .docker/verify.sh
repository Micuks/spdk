#!/bin/bash
# Verify SPDK_SIM_COMPRESS latency injection.
# Target: SPDK nvmf_tgt with malloc bdev, NVMe-oF over TCP.
# Initiator: kernel nvme-tcp + fio.
#
# Usage:  verify.sh "<label>" [write_us] [read_us]
set -eu

LABEL="${1:-baseline}"
WRITE_US="${2:-0}"
READ_US="${3:-0}"

SOCK=/tmp/spdk.sock
RPC=/spdk/scripts/rpc.py
TGT=/spdk/build/bin/nvmf_tgt
NQN=nqn.2026-05.io.spdk:sim

cleanup() {
    nvme disconnect -n $NQN >/dev/null 2>&1 || true
    if [ -n "${TGT_PID:-}" ]; then
        kill $TGT_PID 2>/dev/null || true
        wait $TGT_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

pkill -f nvmf_tgt 2>/dev/null || true
nvme disconnect -n $NQN >/dev/null 2>&1 || true
rm -f $SOCK
sleep 1

export SPDK_SIM_COMPRESS_WRITE_US="$WRITE_US"
export SPDK_SIM_COMPRESS_READ_US="$READ_US"

echo "==> [$LABEL] starting nvmf_tgt (WRITE_US=$WRITE_US READ_US=$READ_US)"
$TGT --env-context='--no-huge -m 2048 --legacy-mem' -s 2048 --no-pci -r $SOCK > /tmp/nvmf_tgt.log 2>&1 &
TGT_PID=$!
for i in $(seq 1 30); do
    [ -S $SOCK ] && break
    sleep 0.2
done
[ -S $SOCK ] || { echo "FAIL: socket not up"; tail -30 /tmp/nvmf_tgt.log; exit 1; }

$RPC -s $SOCK bdev_malloc_create -b Malloc0 64 4096 >/dev/null
$RPC -s $SOCK nvmf_create_transport -t TCP -u 8192 -m 2 -c 4096 -b 8 -n 64 >/dev/null
$RPC -s $SOCK nvmf_create_subsystem $NQN -a -s SPDKSIM01 -d Controller1 >/dev/null
$RPC -s $SOCK nvmf_subsystem_add_ns $NQN Malloc0 >/dev/null
$RPC -s $SOCK nvmf_subsystem_add_listener $NQN -t TCP -a 127.0.0.1 -s 4420 >/dev/null

echo "==> [$LABEL] connecting initiator..."
CONNECT_OUT=$(nvme connect -t tcp -a 127.0.0.1 -s 4420 -n $NQN)
echo "$CONNECT_OUT"
CTRL=$(echo "$CONNECT_OUT" | awk -F'device: ' '/connecting to device/ {print $2; exit}')
sleep 1
# OrbStack container /dev doesn't auto-populate from kernel hotplug; mknod manually.
for sysblk in /sys/class/block/${CTRL}n*; do
    [ -e $sysblk/dev ] || continue
    name=$(basename $sysblk)
    majmin=$(cat $sysblk/dev)
    [ -b /dev/$name ] || mknod /dev/$name b ${majmin%:*} ${majmin#*:}
done
DEV="/dev/${CTRL}n1"
[ -b "$DEV" ] || { echo "FAIL: no nvme device at $DEV after mknod"; ls /sys/class/block/; exit 1; }
echo "==> [$LABEL] device: $DEV"

run_fio() {
    local rw=$1
    fio --name=$rw --filename=$DEV --ioengine=libaio --direct=1 \
        --rw=$rw --bs=4k --iodepth=1 --time_based=1 --runtime=5 \
        --numjobs=1 --group_reporting --output-format=normal 2>&1 \
        | grep -E "IOPS=|lat \(usec\): *min|99\.00th|99\.95th"
}

echo "--- [$LABEL] randwrite ---"
run_fio randwrite | tee /tmp/fio-write-$LABEL.log
echo "--- [$LABEL] randread ---"
run_fio randread | tee /tmp/fio-read-$LABEL.log

echo "--- [$LABEL] nvmf_tgt log relevant lines ---"
grep -E "sim_compress|sim_decompress|NOTICE" /tmp/nvmf_tgt.log | head -5

echo "==> [$LABEL] done."
