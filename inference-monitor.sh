#!/bin/bash
# Logs GPU/CPU/system metrics every invocation. Run via systemd timer.
LOG=/var/log/inference/metrics.csv

mkdir -p /var/log/inference

# Write header if file is new
if [ ! -s "$LOG" ]; then
    echo "timestamp,gpu0_temp,gpu0_power_w,gpu0_mem_mib,gpu0_util_pct,gpu1_temp,gpu1_power_w,gpu1_mem_mib,gpu1_util_pct,cpu_temp,nvme_temp,load1,mem_used_mib,ollama_status,it8696_t1,it8696_t2,it8696_t3,it8696_t4,it8696_t5,it87952_t1,it87952_t3" >> "$LOG"
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# GPU metrics (temp, power, memory used, utilization)
read GPU0_TEMP GPU0_POW GPU0_MEM GPU0_UTIL < <(
    nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu \
        --format=csv,noheader,nounits -i 0 2>/dev/null | tr -d ' ' | tr ',' ' '
)
read GPU1_TEMP GPU1_POW GPU1_MEM GPU1_UTIL < <(
    nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu \
        --format=csv,noheader,nounits -i 1 2>/dev/null | tr -d ' ' | tr ',' ' '
)

# CPU temp (Tctl)
CPU_TEMP=$(sensors k10temp-pci-00c3 2>/dev/null | awk '/Tctl/ {gsub(/[^0-9.]/,"",$2); print $2}')

# NVMe temp
NVME_TEMP=$(sensors nvme-pci-0200 2>/dev/null | awk '/Composite/ {gsub(/[^0-9.]/,"",$2); print $2}')

# Load average (1 min)
LOAD1=$(cut -d' ' -f1 /proc/loadavg)

# Memory used (MiB)
MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')

# Ollama status
systemctl is-active --quiet ollama && OLLAMA_STATUS="running" || OLLAMA_STATUS="stopped"

# Chassis temps from it8696 (temp1-5; temp6 is disconnected/-55C)
_it8696=$(sensors it8696-isa-0a40 2>/dev/null)
IT8696_T1=$(awk '/^temp1:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
IT8696_T2=$(awk '/^temp2:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
IT8696_T3=$(awk '/^temp3:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
IT8696_T4=$(awk '/^temp4:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")
IT8696_T5=$(awk '/^temp5:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it8696")

# Chassis temps from it87952 (temp1, temp3; temp2 is disconnected/-55C)
_it87952=$(sensors it87952-isa-0a60 2>/dev/null)
IT87952_T1=$(awk '/^temp1:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it87952")
IT87952_T3=$(awk '/^temp3:/ {gsub(/[^0-9.]/,"",$2); print $2}' <<< "$_it87952")

echo "${TS},${GPU0_TEMP},${GPU0_POW},${GPU0_MEM},${GPU0_UTIL},${GPU1_TEMP},${GPU1_POW},${GPU1_MEM},${GPU1_UTIL},${CPU_TEMP},${NVME_TEMP},${LOAD1},${MEM_USED},${OLLAMA_STATUS},${IT8696_T1},${IT8696_T2},${IT8696_T3},${IT8696_T4},${IT8696_T5},${IT87952_T1},${IT87952_T3}" >> "$LOG"
