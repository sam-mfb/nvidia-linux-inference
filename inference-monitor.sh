#!/bin/bash
# Logs GPU/CPU/system metrics every invocation. Run via systemd timer.
LOG=/var/log/inference/metrics.csv
MACHINE=$(hostname)

mkdir -p /var/log/inference

# Write header if file is new
if [ ! -s "$LOG" ]; then
    if [ "$MACHINE" = "nvidia6000" ]; then
        echo "timestamp,gpu0_temp,gpu0_power_w,gpu0_mem_mib,gpu0_util_pct,cpu_temp,nvme_temp,load1,mem_used_mib,ollama_status,asusec_cpu,asusec_pkg,asusec_mb,asusec_vrm,fan_rpm" >> "$LOG"
    else
        # 4090x2: dual GPU + ITE IT8696 board sensors
        echo "timestamp,gpu0_temp,gpu0_power_w,gpu0_mem_mib,gpu0_util_pct,gpu1_temp,gpu1_power_w,gpu1_mem_mib,gpu1_util_pct,cpu_temp,nvme_temp,load1,mem_used_mib,ollama_status,it8696_t1,it8696_t2,it8696_t3,it8696_t4,it8696_t5,it87952_t1,it87952_t3" >> "$LOG"
    fi
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# GPU 0 metrics (all machines)
read GPU0_TEMP GPU0_POW GPU0_MEM GPU0_UTIL < <(
    nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu \
        --format=csv,noheader,nounits -i 0 2>/dev/null | tr -d ' ' | tr ',' ' '
)

# CPU temp (Tctl) — same k10temp address on both machines (Ryzen 9900X at 00:18.3)
CPU_TEMP=$(sensors k10temp-pci-00c3 2>/dev/null | awk '/Tctl/ {gsub(/[^0-9.]/,"",$2); print $2}')

# NVMe temp — same PCI address on both machines (02:00.0)
NVME_TEMP=$(sensors nvme-pci-0200 2>/dev/null | awk '/Composite/ {gsub(/[^0-9.]/,"",$2); print $2}')

# Load average (1 min)
LOAD1=$(cut -d' ' -f1 /proc/loadavg)

# Memory used (MiB)
MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')

# Ollama status
systemctl is-active --quiet ollama && OLLAMA_STATUS="running" || OLLAMA_STATUS="stopped"

if [ "$MACHINE" = "nvidia6000" ]; then
    # ASUS ProArt X870E-CREATOR WIFI: single RTX PRO 6000, in-kernel asusec driver.
    # asusec is not in the lm-sensors chip database — read via sysfs.
    # temp4 (T_Sensor header) is disconnected and reads -60°C; skip it.
    HW=$(grep -rl '^asusec$' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    ASUSEC_CPU=$(awk '{printf "%.1f", $1/1000}' "${HW}/temp1_input" 2>/dev/null)
    ASUSEC_PKG=$(awk '{printf "%.1f", $1/1000}' "${HW}/temp2_input" 2>/dev/null)
    ASUSEC_MB=$(awk '{printf "%.1f", $1/1000}' "${HW}/temp3_input" 2>/dev/null)
    ASUSEC_VRM=$(awk '{printf "%.1f", $1/1000}' "${HW}/temp5_input" 2>/dev/null)
    FAN_RPM=$(cat "${HW}/fan1_input" 2>/dev/null)

    echo "${TS},${GPU0_TEMP},${GPU0_POW},${GPU0_MEM},${GPU0_UTIL},${CPU_TEMP},${NVME_TEMP},${LOAD1},${MEM_USED},${OLLAMA_STATUS},${ASUSEC_CPU},${ASUSEC_PKG},${ASUSEC_MB},${ASUSEC_VRM},${FAN_RPM}" >> "$LOG"
else
    # 4090x2: Gigabyte AORUS 870E, dual RTX 4090, ITE IT8696 via out-of-tree it87 module
    read GPU1_TEMP GPU1_POW GPU1_MEM GPU1_UTIL < <(
        nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu \
            --format=csv,noheader,nounits -i 1 2>/dev/null | tr -d ' ' | tr ',' ' '
    )

    _it8696=$(sensors it8696-isa-0a40 2>/dev/null)
    IT8696_T1=$(awk '/^temp1:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
    IT8696_T2=$(awk '/^temp2:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
    IT8696_T3=$(awk '/^temp3:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
    IT8696_T4=$(awk '/^temp4:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
    IT8696_T5=$(awk '/^temp5:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")

    _it87952=$(sensors it87952-isa-0a60 2>/dev/null)
    IT87952_T1=$(awk '/^temp1:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it87952")
    IT87952_T3=$(awk '/^temp3:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it87952")

    echo "${TS},${GPU0_TEMP},${GPU0_POW},${GPU0_MEM},${GPU0_UTIL},${GPU1_TEMP},${GPU1_POW},${GPU1_MEM},${GPU1_UTIL},${CPU_TEMP},${NVME_TEMP},${LOAD1},${MEM_USED},${OLLAMA_STATUS},${IT8696_T1},${IT8696_T2},${IT8696_T3},${IT8696_T4},${IT8696_T5},${IT87952_T1},${IT87952_T3}" >> "$LOG"
fi
