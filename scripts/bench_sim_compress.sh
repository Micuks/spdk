#!/bin/bash
# NVMe-oF sim_compress benchmark — drive nvmf_tgt through 4 sim combos.
#
# Subcommands:
#   setup    <label> <comp_w> <comp_r> <crc_w> <crc_r>   (each 1/0 enable)
#       start nvmf_tgt with given env vars, configure transport / bdev /
#       subsystem / listener per MACHINE CONFIG below
#   probe    <label> [target_ip]
#       run the initiator (SPDK perf for PRESET=prod, kernel nvme-tcp+fio
#       for PRESET=orbstack) read+write, snap bandwidth counters around it,
#       save logs under $RESULTS_DIR
#   teardown
#       kill nvmf_tgt and clean up
#   all      [target_ip]
#       cycle through 4 combos (baseline / crc / comp / both), print a
#       summary table at the end
#   server-measure <label> <duration_s>
#       (server-side, run alongside a remote client's probe) start
#       pcm-memory / perf stat / NIC counter snapshot for duration_s,
#       write to $RESULTS_DIR/measure-server-<label>.log
#
# PRESET=prod (default)   RDMA + physical NVMe + SPDK perf (production C1/C2)
# PRESET=orbstack         TCP  + malloc bdev    + kernel nvme-tcp + fio
#
# Overrides (all via env var):
#   TRANSPORT=RDMA|TCP   NVME_BDFS="bdf1 bdf2"   LISTEN_IPS="ip1 ip2"
#   NQN=...              REACTOR_MASK=0x30        PERF_TIME=30  PERF_BS=4096
#   PERF_QD=1            INITIATOR=spdk_perf|fio  SPDK_DIR=/root/spdk
#   NET_IFACE=enp23...   IB_DEVICE=mlx5_0         IB_PORT=1
#   DISABLE_PCM=1        DISABLE_LLC=1            DISABLE_NET=1
#   SPDK_SIM_COMPRESS_FACTOR=1.33  (codec output/input size ratio, global)
#   SPDK_SIM_SCRATCH_KB=4096       (per-thread scratch buffer, global)
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

# Network counter source: explicit NET_IFACE for TCP, IB_DEVICE/IB_PORT for RDMA
NET_IFACE="${NET_IFACE:-}"
IB_DEVICE="${IB_DEVICE:-mlx5_0}"
IB_PORT="${IB_PORT:-1}"

# Optional bandwidth measurement toggles (default on, auto-skip if tool missing)
DISABLE_PCM="${DISABLE_PCM:-0}"
DISABLE_LLC="${DISABLE_LLC:-0}"
DISABLE_NET="${DISABLE_NET:-0}"

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

# ---------- generic helpers ----------

die() { echo "FAIL: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }

have_hugepage() {
    [ -w /proc/sys/vm/nr_hugepages ] && [ -d /sys/kernel/mm/hugepages ]
}

read -r -a _NVME_BDFS_ARR <<< "$NVME_BDFS"
read -r -a _LISTEN_IPS_ARR <<< "$LISTEN_IPS"

# ---------- bandwidth measurement helpers ----------

# pick_net_iface <optional target_ip>: best-effort auto-detect.
#   NET_IFACE env > route to target_ip > first non-lo
pick_net_iface() {
    local target="${1:-1.1.1.1}"
    [ -n "$NET_IFACE" ] && { echo "$NET_IFACE"; return; }
    local iface
    iface=$(ip -o route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -n "$iface" ] && { echo "$iface"; return; }
    ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -1
}

# snap_net_bytes <out_tx_var> <out_rx_var> [target_ip]
# Reads relevant byte counters for current TRANSPORT into named vars.
# target_ip steers TCP iface auto-detection (use 127.0.0.1 → lo).
snap_net_bytes() {
    [ "$DISABLE_NET" = "1" ] && return
    local _tx_var="$1" _rx_var="$2" _target="${3:-}"
    local _tx _rx
    if [ "$TRANSPORT" = "RDMA" ]; then
        local p="/sys/class/infiniband/$IB_DEVICE/ports/$IB_PORT/counters"
        if [ -r "$p/port_xmit_data" ] && [ -r "$p/port_rcv_data" ]; then
            _tx=$(( $(cat "$p/port_xmit_data") * 4 ))
            _rx=$(( $(cat "$p/port_rcv_data") * 4 ))
        fi
    else
        local iface; iface=$(pick_net_iface "$_target")
        if [ -n "$iface" ] && [ -r "/sys/class/net/$iface/statistics/tx_bytes" ]; then
            _tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
            _rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes")
        fi
    fi
    eval "$_tx_var=\"${_tx:-}\""
    eval "$_rx_var=\"${_rx:-}\""
}

# start_pcm_memory <log_path>
# Spawns pcm-memory in background; sets PCM_PID. Caller calls stop_pcm_memory.
start_pcm_memory() {
    PCM_PID=
    [ "$DISABLE_PCM" = "1" ] && return
    command -v pcm-memory >/dev/null 2>&1 || return 0
    pcm-memory 1 -nc > "$1" 2>&1 &
    PCM_PID=$!
}
stop_pcm_memory() {
    if [ -n "${PCM_PID:-}" ]; then
        kill "$PCM_PID" 2>/dev/null || true
        wait "$PCM_PID" 2>/dev/null || true
        PCM_PID=
    fi
}

# start_llc_perf <log_path>
# Spawns system-wide `perf stat` in background; sets LLC_PID.
# Send SIGINT on stop to get printed results.
start_llc_perf() {
    LLC_PID=
    [ "$DISABLE_LLC" = "1" ] && return
    command -v perf >/dev/null 2>&1 || return 0
    [ -r /proc/sys/kernel/perf_event_paranoid ] || return 0
    perf stat -a -e LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses \
        -o "$1" -- sleep "$PERF_TIME" >/dev/null 2>&1 &
    LLC_PID=$!
}
stop_llc_perf() {
    if [ -n "${LLC_PID:-}" ]; then
        wait "$LLC_PID" 2>/dev/null || true
        LLC_PID=
    fi
}

# measure_around <label> <rw> <target_ip> <cmd...>
# Snap NIC + start pcm-memory + start perf-stat, run cmd, stop captures,
# write per-(label,rw) measurement log.
measure_around() {
    local label="$1" rw="$2" target_ip="$3"; shift 3
    local tx0='' rx0='' tx1='' rx1='' rc=0
    local pcm_log="$RESULTS_DIR/pcm-memory-$label-$rw.log"
    local llc_log="$RESULTS_DIR/llc-$label-$rw.log"
    local measure_log="$RESULTS_DIR/measure-$label-$rw.log"

    snap_net_bytes tx0 rx0 "$target_ip"
    start_pcm_memory "$pcm_log"
    start_llc_perf   "$llc_log"

    "$@" || rc=$?

    stop_pcm_memory
    stop_llc_perf
    snap_net_bytes tx1 rx1 "$target_ip"

    {
        echo "label=$label rw=$rw duration_s=$PERF_TIME transport=$TRANSPORT"
        if [ -n "$tx0" ] && [ -n "$tx1" ]; then
            local txd=$(( tx1 - tx0 )) rxd=$(( rx1 - rx0 ))
            echo "tx_bytes=$txd"
            echo "rx_bytes=$rxd"
            if [ "$PERF_TIME" -gt 0 ]; then
                # MB/s = bytes / sec / 1MiB
                echo "tx_mbps=$(( txd / PERF_TIME / 1048576 ))"
                echo "rx_mbps=$(( rxd / PERF_TIME / 1048576 ))"
            fi
        else
            echo "tx_bytes= rx_bytes=  # no NIC counter for this transport/iface"
        fi
        # pcm-memory: extract avg System Memory Throughput
        if [ -s "$pcm_log" ]; then
            local pcm_avg
            pcm_avg=$(awk '/System Memory Throughput/ {gsub(/[^0-9.]/,"",$NF); sum+=$NF; n++}
                          END {if (n) printf "%.1f", sum/n}' "$pcm_log")
            [ -n "$pcm_avg" ] && echo "mem_mbps=$pcm_avg"
        fi
        # LLC perf-stat: parse counts, tolerate <not supported>
        if [ -s "$llc_log" ] && ! grep -q '<not supported>' "$llc_log"; then
            local llc_loads llc_load_miss
            llc_loads=$(awk '/LLC-loads/{gsub(",","",$1); print $1; exit}' "$llc_log")
            llc_load_miss=$(awk '/LLC-load-misses/{gsub(",","",$1); print $1; exit}' "$llc_log")
            if [ -n "$llc_loads" ] && [ -n "$llc_load_miss" ] && [ "$llc_loads" -gt 0 ] 2>/dev/null; then
                echo "llc_loads=$llc_loads llc_load_miss=$llc_load_miss"
                echo "llc_miss_pct=$(( llc_load_miss * 100 / llc_loads ))"
            fi
        fi
    } > "$measure_log"

    return $rc
}

# ---------- nvmf_tgt setup helpers ----------

start_tgt() {
    local label="$1" comp_w="$2" comp_r="$3" crc_w="$4" crc_r="$5"
    export SPDK_SIM_COMPRESS_WRITE="$comp_w"
    export SPDK_SIM_COMPRESS_READ="$comp_r"
    export SPDK_SIM_CRC_WRITE="$crc_w"
    export SPDK_SIM_CRC_READ="$crc_r"
    export SPDK_SIM_COMPRESS_FACTOR="${SPDK_SIM_COMPRESS_FACTOR:-1.33}"

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
    echo "==> [$label] nvmf_tgt up (comp_w/r=${comp_w}/${comp_r} crc_w/r=${crc_w}/${crc_r} factor=${SPDK_SIM_COMPRESS_FACTOR})"
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
        measure_around "$label" "$rw" "$target_ip" \
            bash -c "'$PERF' -r '$trid' -t '$PERF_TIME' -w '$rw' -o '$PERF_BS' -q '$PERF_QD' 2>&1 | tee '$out' | grep -E '^Total' || true"
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

    for sysblk in /sys/class/block/${ctrl}n*; do
        [ -e "$sysblk/dev" ] || continue
        local n; n=$(basename "$sysblk")
        local mm; mm=$(cat "$sysblk/dev")
        [ -b "/dev/$n" ] || mknod "/dev/$n" b "${mm%:*}" "${mm#*:}"
    done

    local dev="/dev/${ctrl}n1"
    [ -b "$dev" ] || die "no nvme device at $dev"

    for rw in randwrite randread; do
        local rw_short="${rw#rand}"
        local out="$RESULTS_DIR/perf-${rw_short}-$label.log"
        echo "==> [$label] $rw via fio → $target_ip"
        measure_around "$label" "$rw_short" "$target_ip" \
            bash -c "fio --name='$rw' --filename='$dev' --ioengine=libaio --direct=1 --rw='$rw' --bs='$PERF_BS' --iodepth='$PERF_QD' --time_based=1 --runtime='$PERF_TIME' --numjobs=1 --group_reporting --output-format=normal 2>&1 | tee '$out' | grep -E 'IOPS=|lat \\(usec\\): *min' || true"
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

# Server-side bandwidth snapshot, for split-host runs.
# Run on the server while a remote client is doing the perf load.
cmd_server_measure() {
    local label="$1" duration="${2:-$PERF_TIME}"
    local tx0='' rx0='' tx1='' rx1=''
    local pcm_log="$RESULTS_DIR/pcm-memory-server-$label.log"
    local llc_log="$RESULTS_DIR/llc-server-$label.log"
    local out="$RESULTS_DIR/measure-server-$label.log"

    PERF_TIME="$duration"  # so start_llc_perf uses the right duration
    snap_net_bytes tx0 rx0
    start_pcm_memory "$pcm_log"
    start_llc_perf   "$llc_log"
    echo "==> server-measure [$label] capturing for ${duration}s..."
    sleep "$duration"
    stop_pcm_memory
    stop_llc_perf
    snap_net_bytes tx1 rx1

    {
        echo "label=$label side=server duration_s=$duration transport=$TRANSPORT"
        if [ -n "$tx0" ] && [ -n "$tx1" ]; then
            local txd=$(( tx1 - tx0 )) rxd=$(( rx1 - rx0 ))
            echo "tx_bytes=$txd rx_bytes=$rxd"
            echo "tx_mbps=$(( txd / duration / 1048576 ))"
            echo "rx_mbps=$(( rxd / duration / 1048576 ))"
        fi
        if [ -s "$pcm_log" ]; then
            local pcm_avg
            pcm_avg=$(awk '/System Memory Throughput/ {gsub(/[^0-9.]/,"",$NF); sum+=$NF; n++}
                          END {if (n) printf "%.1f", sum/n}' "$pcm_log")
            [ -n "$pcm_avg" ] && echo "mem_mbps=$pcm_avg"
        fi
        if [ -s "$llc_log" ]; then
            local llc_loads llc_load_miss
            llc_loads=$(awk '/LLC-loads/{gsub(",","",$1); print $1; exit}' "$llc_log")
            llc_load_miss=$(awk '/LLC-load-misses/{gsub(",","",$1); print $1; exit}' "$llc_log")
            if [ -n "$llc_loads" ] && [ -n "$llc_load_miss" ] && [ "$llc_loads" -gt 0 ] 2>/dev/null; then
                echo "llc_miss_pct=$(( llc_load_miss * 100 / llc_loads ))"
            fi
        fi
    } > "$out"
    echo "==> server-measure [$label] written to $out"
    cat "$out"
}

# Read a key=value pair from a measurement log; print value or "-"
_mread() {
    local file="$1" key="$2"
    [ -f "$file" ] || { echo "-"; return; }
    local v; v=$(awk -F= -v k="$key" '{for(i=1;i<NF;i++) if($i ~ k) {gsub(/^[ \t]+/,"",$(i+1)); split($(i+1),a," "); print a[1]; exit}}' "$file")
    echo "${v:--}"
}

summarize() {
    echo
    echo "===================================== SUMMARY ====================================="
    printf "%-9s %-5s %-9s %-11s %-10s %-10s %-11s %-9s\n" \
        "Combo" "RW" "IOPS" "AvgLat(µs)" "TxBW(MB)" "RxBW(MB)" "MemBW(MB)" "LLCmiss%"
    printf "%s\n" "------------------------------------------------------------------------------------"
    for label in baseline crc comp both; do
        for rw in write read; do
            local plog="$RESULTS_DIR/perf-$rw-$label.log"
            local mlog="$RESULTS_DIR/measure-$label-$rw.log"
            [ -f "$plog" ] || continue
            local iops="-" avg="-"
            if [ "$INITIATOR" = "spdk_perf" ]; then
                read -r iops avg < <(awk '/^Total/ {print $3, $5; exit}' "$plog")
            else
                iops=$(awk '/IOPS=/ {match($0, /IOPS=[0-9.]+k?/); print substr($0, RSTART+5, RLENGTH-5); exit}' "$plog")
                avg=$(awk '/^[ \t]*lat \(usec\):.*avg=/ {match($0, /avg=[0-9.]+/); print substr($0, RSTART+4, RLENGTH-4); exit}' "$plog")
            fi
            local tx rx mem llc
            tx=$(_mread "$mlog" tx_mbps)
            rx=$(_mread "$mlog" rx_mbps)
            mem=$(_mread "$mlog" mem_mbps)
            llc=$(_mread "$mlog" llc_miss_pct)
            printf "%-9s %-5s %-9s %-11s %-10s %-10s %-11s %-9s\n" \
                "$label" "$rw" "${iops:--}" "${avg:--}" "$tx" "$rx" "$mem" "$llc"
        done
    done
    echo "===================================================================================="
    echo "Raw logs:   $RESULTS_DIR/perf-{write,read}-<combo>.log"
    echo "Bandwidth:  $RESULTS_DIR/measure-<combo>-<rw>.log"
    echo "Mem detail: $RESULTS_DIR/pcm-memory-<combo>-<rw>.log (if Intel PCM installed)"
    echo "LLC detail: $RESULTS_DIR/llc-<combo>-<rw>.log (if perf installed and PMU readable)"
}

cmd_all() {
    local target_ip="${1:-${_LISTEN_IPS_ARR[0]}}"
    # label  comp_w comp_r crc_w crc_r  (each 1/0 enable)
    local combos=(
        "baseline 0 0 0 0"
        "crc      0 0 1 1"
        "comp     1 1 0 0"
        "both     1 1 1 1"
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
    setup)           cmd_setup    "$@" ;;
    probe)           cmd_probe    "$@" ;;
    teardown)        cmd_teardown ;;
    all)             cmd_all      "$@" ;;
    summary)         summarize ;;
    server-measure)  cmd_server_measure "$@" ;;
    help|*)
        sed -n '2,33p' "$0"
        ;;
esac
