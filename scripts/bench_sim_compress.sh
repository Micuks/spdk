#!/bin/bash
# NVMe-oF sim_compress benchmark — drive nvmf_tgt through 4 sim combos.
#
# Subcommands:
#   setup    <label> <comp_w_us> <comp_r_us> <crc_w_us> <crc_r_us>
#       start nvmf_tgt with given env vars, configure transport / bdev /
#       subsystem / listener per MACHINE CONFIG below
#   probe    <label> [target_ip]
#       run the initiator (SPDK perf for PRESET=prod, kernel nvme-tcp+fio
#       for PRESET=orbstack) read+write, save logs under $RESULTS_DIR
#   teardown
#       kill nvmf_tgt and clean up
#   all      [target_ip]
#       cycle through 4 combos (baseline / crc / comp / both), print a
#       summary table at the end
#
# PRESET=prod (default)   RDMA + physical NVMe + SPDK perf (production C1/C2)
# PRESET=orbstack         TCP  + malloc bdev    + kernel nvme-tcp + fio
#
# Anything in the MACHINE CONFIG block can be overridden via env vars:
#   TRANSPORT=RDMA|TCP   NVME_BDFS="bdf1 bdf2"   LISTEN_IPS="ip1 ip2"
#   NQN=...              REACTOR_MASK=0x30        PERF_TIME=30  PERF_BS=4096
#   PERF_QD=1            INITIATOR=spdk_perf|fio  SPDK_DIR=/root/spdk
#
set -euo pipefail

# ========================== MACHINE CONFIG ==========================
PRESET="${PRESET:-prod}"

case "$PRESET" in
    prod)
        TRANSPORT="${TRANSPORT:-RDMA}"
        NVME_BDFS="${NVME_BDFS:-0000:d6:00.0 0000:d9:00.0 0000:57:00.0}"
        LISTEN_IPS="${LISTEN_IPS:-192.168.65.81 192.168.75.81}"
        INITIATOR="${INITIATOR:-spdk_perf}"
        ;;
    orbstack)
        TRANSPORT="${TRANSPORT:-TCP}"
        NVME_BDFS="${NVME_BDFS:-}"
        LISTEN_IPS="${LISTEN_IPS:-127.0.0.1}"
        INITIATOR="${INITIATOR:-fio}"
        ;;
    *)
        echo "unknown PRESET=$PRESET (expected prod or orbstack)" >&2
        exit 1
        ;;
esac

NQN="${NQN:-nqn.2016-06.io.spdk:cnode1}"
REACTOR_MASK="${REACTOR_MASK:-0x30}"

# Transport options (match the production SOP for RDMA)
RDMA_OPTS="-q 128 -m 127 -c 4096 -i 131072 -u 131072 -a 128 -n 2048 -b 0"
TCP_OPTS="-u 8192 -m 2 -c 4096 -b 8 -n 64"

# perf parameters
PERF_TIME="${PERF_TIME:-30}"
PERF_BS="${PERF_BS:-4096}"
PERF_QD="${PERF_QD:-1}"

SPDK_DIR="${SPDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# ==================================================================

RPC="$SPDK_DIR/scripts/rpc.py"
TGT="$SPDK_DIR/build/bin/nvmf_tgt"
PERF="$SPDK_DIR/build/examples/perf"
SETUP="$SPDK_DIR/scripts/setup.sh"
SOCK=/tmp/spdk_bench.sock
TGT_LOG="${TGT_LOG:-/tmp/nvmf_tgt-bench.log}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/sim_compress_bench}"
mkdir -p "$RESULTS_DIR"

# ---------- helpers ----------

die() { echo "FAIL: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }

have_hugepage() {
    [ -w /proc/sys/vm/nr_hugepages ] && [ -d /sys/kernel/mm/hugepages ]
}

read -r -a _NVME_BDFS_ARR <<< "$NVME_BDFS"
read -r -a _LISTEN_IPS_ARR <<< "$LISTEN_IPS"

start_tgt() {
    local label="$1" comp_w="$2" comp_r="$3" crc_w="$4" crc_r="$5"
    export SPDK_SIM_COMPRESS_WRITE_US="$comp_w"
    export SPDK_SIM_COMPRESS_READ_US="$comp_r"
    export SPDK_SIM_CRC_WRITE_US="$crc_w"
    export SPDK_SIM_CRC_READ_US="$crc_r"

    rm -f "$SOCK"
    if have_hugepage; then
        "$TGT" -m "$REACTOR_MASK" -r "$SOCK" > "$TGT_LOG" 2>&1 &
    else
        "$TGT" -m "$REACTOR_MASK" --env-context='--no-huge -m 2048 --legacy-mem' \
               -s 2048 --no-pci -r "$SOCK" > "$TGT_LOG" 2>&1 &
    fi

    for _ in $(seq 1 50); do
        [ -S "$SOCK" ] && break
        sleep 0.2
    done
    [ -S "$SOCK" ] || { tail -30 "$TGT_LOG"; die "nvmf_tgt socket not up"; }
    echo "==> [$label] nvmf_tgt up (comp=${comp_w}/${comp_r} crc=${crc_w}/${crc_r} µs)"
}

create_transport() {
    if [ "$TRANSPORT" = "RDMA" ]; then
        # shellcheck disable=SC2086
        "$RPC" -s "$SOCK" nvmf_create_transport -t RDMA $RDMA_OPTS >/dev/null
    else
        # shellcheck disable=SC2086
        "$RPC" -s "$SOCK" nvmf_create_transport -t TCP $TCP_OPTS >/dev/null
    fi
}

attach_bdevs_and_ns() {
    local ns_names=()
    if [ "${#_NVME_BDFS_ARR[@]}" -gt 0 ]; then
        local i=0
        for bdf in "${_NVME_BDFS_ARR[@]}"; do
            "$RPC" -s "$SOCK" bdev_nvme_attach_controller -b "nvme${i}" -t PCIe -a "$bdf" >/dev/null
            ns_names+=("nvme${i}n1")
            ((i++))
        done
    else
        for i in 0 1 2; do
            "$RPC" -s "$SOCK" bdev_malloc_create -b "Malloc${i}" 64 4096 >/dev/null
            ns_names+=("Malloc${i}")
        done
    fi

    "$RPC" -s "$SOCK" nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 -m 8 >/dev/null
    for ns in "${ns_names[@]}"; do
        "$RPC" -s "$SOCK" nvmf_subsystem_add_ns "$NQN" "$ns" >/dev/null
    done
    echo "==> namespaces: ${ns_names[*]}"
}

add_listeners() {
    for ip in "${_LISTEN_IPS_ARR[@]}"; do
        "$RPC" -s "$SOCK" nvmf_subsystem_add_listener "$NQN" -t "$TRANSPORT" -a "$ip" -s 4420 >/dev/null
        echo "==> listener: $TRANSPORT $ip:4420"
    done
}

# ---------- subcommands ----------

cmd_setup() {
    local label="$1" comp_w="$2" comp_r="$3" crc_w="$4" crc_r="$5"
    need_root
    [ -x "$TGT" ] || die "$TGT not built"

    pkill -f 'build/bin/nvmf_tgt' 2>/dev/null || true
    sleep 1

    if [ "${#_NVME_BDFS_ARR[@]}" -gt 0 ] && have_hugepage; then
        PCI_ALLOWED="$NVME_BDFS" "$SETUP" >/dev/null
    elif have_hugepage; then
        # alloc hugepages without binding any PCI device
        local nr; nr=$(cat /proc/sys/vm/nr_hugepages)
        [ "$nr" -ge 512 ] || echo 1024 > /proc/sys/vm/nr_hugepages
        mountpoint -q /dev/hugepages || mount -t hugetlbfs nodev /dev/hugepages
    fi

    start_tgt "$label" "$comp_w" "$comp_r" "$crc_w" "$crc_r"
    create_transport
    attach_bdevs_and_ns
    add_listeners
    echo "==> [$label] setup complete; subsystem $NQN ready"
}

probe_spdk_perf() {
    local label="$1" target_ip="$2"
    [ -x "$PERF" ] || die "$PERF not built"
    local trid="trtype:$TRANSPORT adrfam:IPv4 traddr:$target_ip trsvcid:4420 subnqn:$NQN"
    for rw in write read; do
        local out="$RESULTS_DIR/perf-$rw-$label.log"
        echo "==> [$label] $rw via SPDK perf → $target_ip"
        "$PERF" -r "$trid" -t "$PERF_TIME" -w "$rw" -o "$PERF_BS" -q "$PERF_QD" \
            2>&1 | tee "$out" | grep -E "^Total" || true
    done
}

probe_fio() {
    local label="$1" target_ip="$2"
    command -v nvme >/dev/null || die "nvme-cli not installed"
    command -v fio  >/dev/null || die "fio not installed"

    if [ ! -e /sys/module/nvme_tcp ]; then
        modprobe nvme-tcp 2>/dev/null || true
    fi

    local lc_xport; lc_xport="$(echo "$TRANSPORT" | tr '[:upper:]' '[:lower:]')"
    local connect_out
    connect_out=$(nvme connect -t "$lc_xport" -a "$target_ip" -s 4420 -n "$NQN")
    echo "$connect_out"
    local ctrl; ctrl=$(echo "$connect_out" | awk -F'device: ' '/connecting to device/ {print $2; exit}')
    sleep 1

    # devtmpfs hotplug fallback
    for sysblk in /sys/class/block/${ctrl}n*; do
        [ -e "$sysblk/dev" ] || continue
        local n; n=$(basename "$sysblk")
        local mm; mm=$(cat "$sysblk/dev")
        [ -b "/dev/$n" ] || mknod "/dev/$n" b "${mm%:*}" "${mm#*:}"
    done

    local dev="/dev/${ctrl}n1"
    [ -b "$dev" ] || die "no nvme device at $dev"

    for rw in randwrite randread; do
        local out="$RESULTS_DIR/perf-${rw#rand}-$label.log"
        echo "==> [$label] $rw via fio → $target_ip"
        fio --name="$rw" --filename="$dev" --ioengine=libaio --direct=1 \
            --rw="$rw" --bs="$PERF_BS" --iodepth="$PERF_QD" --time_based=1 \
            --runtime="$PERF_TIME" --numjobs=1 --group_reporting \
            --output-format=normal 2>&1 | tee "$out" \
            | grep -E "IOPS=|lat \(usec\): *min" || true
    done

    nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
}

cmd_probe() {
    local label="$1" target_ip="${2:-${_LISTEN_IPS_ARR[0]}}"
    case "$INITIATOR" in
        spdk_perf) probe_spdk_perf "$label" "$target_ip" ;;
        fio)       probe_fio       "$label" "$target_ip" ;;
        *) die "unknown INITIATOR=$INITIATOR" ;;
    esac
}

cmd_teardown() {
    nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
    pkill -f 'build/bin/nvmf_tgt' 2>/dev/null || true
    sleep 1
    rm -f "$SOCK"
    echo "==> teardown complete"
}

summarize() {
    echo
    echo "==================== SUMMARY ===================="
    printf "%-10s %-6s %-12s %-12s\n" "Combo" "RW" "IOPS" "AvgLat(µs)"
    printf "%s\n" "------------------------------------------------"
    for label in baseline crc comp both; do
        for rw in write read; do
            local log="$RESULTS_DIR/perf-$rw-$label.log"
            [ -f "$log" ] || continue
            local iops="-" avg="-"
            if [ "$INITIATOR" = "spdk_perf" ]; then
                # "Total ...    IOPS    MiB/s   AvgLat   Min   Max"
                read -r iops avg < <(awk '/^Total/ {print $3, $5; exit}' "$log")
            else
                iops=$(awk '/IOPS=/ {match($0, /IOPS=[0-9.]+k?/); print substr($0, RSTART+5, RLENGTH-5); exit}' "$log")
                avg=$(awk '/^[ \t]*lat \(usec\):.*avg=/ {match($0, /avg=[0-9.]+/); print substr($0, RSTART+4, RLENGTH-4); exit}' "$log")
            fi
            printf "%-10s %-6s %-12s %-12s\n" "$label" "$rw" "${iops:--}" "${avg:--}"
        done
    done
    echo "================================================="
    echo "Raw logs: $RESULTS_DIR/perf-{write,read}-<combo>.log"
}

cmd_all() {
    local target_ip="${1:-${_LISTEN_IPS_ARR[0]}}"
    local combos=(
        "baseline 0   0   0  0"
        "crc      0   0   50 50"
        "comp     200 200 0  0"
        "both     200 200 50 50"
    )
    for combo in "${combos[@]}"; do
        # shellcheck disable=SC2086
        cmd_setup $combo
        # shellcheck disable=SC2086
        cmd_probe $(echo "$combo" | awk '{print $1}') "$target_ip"
        cmd_teardown
        sleep 2
    done
    summarize
}

# ---------- main ----------

CMD="${1:-help}"; shift || true
case "$CMD" in
    setup)    cmd_setup    "$@" ;;
    probe)    cmd_probe    "$@" ;;
    teardown) cmd_teardown ;;
    all)      cmd_all      "$@" ;;
    summary)  summarize ;;
    help|*)
        sed -n '2,32p' "$0"
        ;;
esac
