# System Notes

## Hardware

| Component | Details |
|-----------|---------|
| **CPU** | AMD Ryzen 9 9900X — 12 cores / 24 threads (Zen 5 / Granite Ridge) |
| **RAM** | ~32 GB DDR5 |
| **GPU 0** | NVIDIA GeForce RTX 4090 — 24 GB VRAM (PCIe 01:00.0) |
| **GPU 1** | NVIDIA GeForce RTX 4090 — 24 GB VRAM (PCIe 03:00.0) |
| **Storage** | Samsung SSD 990 PRO 2TB (NVMe, `nvme0n1`) |
| **Motherboard** | Gigabyte AORUS 870E (AMD X870E) |
| **NIC 1** | Realtek RTL8127 — 10 GbE |
| **NIC 2** | Realtek RTL8126 — 5 GbE |
| **WiFi** | MediaTek MT7927 — WiFi 7 (802.11be) |
| **USB** | ASMedia ASM4242 — USB 4 / Thunderbolt 3 |

GPUs are compute-only — no display connected.

## OS

- Ubuntu 26.04 LTS "Resolute"
- Kernel: `7.0.0-15-generic`

## Storage Layout

```
nvme0n1 (1.8 TB)
├── nvme0n1p1   1 GB    EFI
├── nvme0n1p2   2 GB    /boot
└── nvme0n1p3   1.8 TB  LVM
    └── ubuntu--vg-ubuntu--lv  100 GB  /
```

Note: LVM volume group has ~1.7 TB unallocated — expand or add LVs as needed.

## NVIDIA Setup

Compute-only (headless) driver stack — no display driver needed.

```
nvidia-headless-no-dkms-595-server-open
nvidia-compute-utils-595-server
nvidia-utils-595-server
```

Driver: 595.58.03 | CUDA: 13.2

## Fan / Temperature Monitoring

The AORUS 870E exposes fan/temp sensors via an ITE IT8696 SuperIO chip. The stock
`it87` kernel module fails due to a resource conflict. Fix: out-of-tree driver.

### Setup

```bash
git clone https://github.com/frankcrawford/it87
cd it87
make && sudo make install
```

Config files:
- `/etc/modprobe.d/it87.conf` — `options it87 ignore_resource_conflict=1`
- `/etc/modules-load.d/it87.conf` — `it87`

### Sensors at idle

| Sensor | Reading |
|--------|---------|
| CPU Tctl | ~43°C |
| GPU 0 | ~37°C |
| GPU 1 | ~38°C |
| NVMe | ~36°C |
| 10 GbE NIC | ~51°C (warm but within spec) |
| fan1 | ~1247 RPM |
| fan2–4 | ~680–720 RPM |
| fan5 | ~1032 RPM |

Note: `temp6` showing -55°C and `intrusion0 ALARM` are normal — disconnected
sensor header and open chassis detect, respectively. `in5`/`in6` ALARM flags
are unconfigured voltage thresholds, not real alerts.

### Sensor channel mapping

Identified by cross-referencing `sensors` readings against `k10temp` under load (2026-05-17).

**it8696-isa-0a40**

| Channel | Maps to |
|---------|---------|
| temp1 | Motherboard zone (ambient ~39°C) |
| temp2 | Motherboard zone (ambient ~36°C) |
| temp3 | CPU — tracks k10temp Tctl within 1°C |
| temp4 | Motherboard zone (~42°C) |
| temp5 | Motherboard zone (~46°C) |
| temp6 | Disconnected — always -55°C, ignore |

**it87952-isa-0a60**

| Channel | Maps to |
|---------|---------|
| temp1 | Chassis probe (~35°C) |
| temp2 | Disconnected — always -55°C, ignore |
| temp3 | Chassis probe (~34°C) |

`it8696 temp3` is a duplicate CPU reading — use `k10temp Tctl` as the authoritative CPU temp.

### ITE 5711 USB device (048d:5711)

This is the Gigabyte RGB Fusion 2.0 controller — not related to fan/temp sensors.
