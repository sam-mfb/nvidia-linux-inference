# System Notes

Both machines run Ubuntu 26.04 LTS "Resolute", kernel `7.0.0-15-generic`, AMD Ryzen 9 9900X (12c/24t, Zen 5).

---

## `nvidia6000` — ASUS ProArt X870E / RTX PRO 6000 Blackwell

| Component | Details |
|-----------|---------|
| **CPU** | AMD Ryzen 9 9900X — 12 cores / 24 threads (Zen 5 / Granite Ridge) |
| **RAM** | ~30 GB DDR5 |
| **GPU** | NVIDIA RTX PRO 6000 Blackwell — 96 GB GDDR7 VRAM (PCIe 01:00.0, GB202GL) |
| **iGPU** | AMD Radeon Graphics (Granite Ridge, integrated — not used for compute) |
| **Storage** | NVMe SSD 1.8 TB (`nvme0n1`, PCIe 02:00.0) |
| **Motherboard** | ASUSTeK ProArt X870E-CREATOR WIFI (AMD X870E) |
| **NIC 1** | Aquantia AQC113 — 10 GbE (PCIe 0b:00.0) |
| **NIC 2** | Intel I226-V — 2.5 GbE (PCIe 0a:00.0) |
| **WiFi** | Qualcomm WCN785x — WiFi 7 (802.11be) |

GPU is compute-only — no display connected.

### NVIDIA Setup

Same compute-only driver stack as `4090x2`:

```
nvidia-headless-no-dkms-595-server-open
nvidia-compute-utils-595-server
nvidia-utils-595-server
```

Driver: 595.71.05 | CUDA: 13.2

### Fan / Temperature Monitoring

The ProArt X870E uses the in-kernel `asus-ec-sensors` driver (`asusec` hwmon device).
No out-of-tree driver needed — this is the key difference from the Gigabyte AORUS 870E.

`asusec` is not in the lm-sensors chip database; read via sysfs directly
(`/sys/class/hwmon/hwmon<N>/temp*_input` where `hwmon<N>/name == "asusec"`).

The monitor script does this lookup automatically at runtime.

#### `asusec` sensor channel mapping

| temp | Label | Notes |
|------|-------|-------|
| temp1 | CPU | ~27°C idle |
| temp2 | CPU Package | ~33°C idle |
| temp3 | Motherboard | ~24°C idle |
| temp4 | T_Sensor | Disconnected header — always −60°C, skip |
| temp5 | VRM | ~36°C idle |
| fan1 | Chassis fan | ~1433 RPM idle |

`k10temp Tctl` (~33°C) is the authoritative CPU temperature.

#### Other sensors

| hwmon name | Sensor | Notes |
|------------|--------|-------|
| `k10temp` | CPU Tctl/Tccd1/Tccd2 | Via `k10temp-pci-00c3` |
| `nvme` | NVMe Composite | Via `nvme-pci-0200` |
| `enp11s0` | NIC PHY/MAC | AQC113 10 GbE — ~31°C idle |
| `spd5118` ×2 | DDR5 DIMM temps | ~29–30°C idle |
| `amdgpu` | iGPU edge | ~32°C idle (not relevant) |

---

## `4090x2` — Gigabyte AORUS 870E / dual RTX 4090

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

### NVIDIA Setup

```
nvidia-headless-no-dkms-595-server-open
nvidia-compute-utils-595-server
nvidia-utils-595-server
```

Driver: 595.58.03 | CUDA: 13.2

### Fan / Temperature Monitoring

The AORUS 870E exposes fan/temp sensors via an ITE IT8696 SuperIO chip. The stock
`it87` kernel module fails due to a resource conflict. Fix: out-of-tree driver.

```bash
git clone https://github.com/frankcrawford/it87
cd it87
make && sudo make install
```

Config files:
- `/etc/modprobe.d/it87.conf` — `options it87 ignore_resource_conflict=1`
- `/etc/modules-load.d/it87.conf` — `it87`

#### `it8696` sensor channel mapping

**it8696-isa-0a40**

| Channel | Maps to |
|---------|---------|
| temp1 | Motherboard zone (~39°C) |
| temp2 | Motherboard zone (~36°C) |
| temp3 | CPU — tracks k10temp Tctl within 1°C |
| temp4 | Motherboard zone (~42°C) |
| temp5 | Motherboard zone (~46°C) |
| temp6 | Disconnected — always −55°C, ignore |

**it87952-isa-0a60**

| Channel | Maps to |
|---------|---------|
| temp1 | Chassis probe (~35°C) |
| temp2 | Disconnected — always −55°C, ignore |
| temp3 | Chassis probe (~34°C) |

`it8696 temp3` is a duplicate CPU reading — use `k10temp Tctl` as authoritative.

Note: `temp6` showing −55°C and `intrusion0 ALARM` are normal (disconnected sensor
header and open chassis detect). `in5`/`in6` ALARM flags are unconfigured voltage
thresholds, not real alerts.

#### ITE 5711 USB device (048d:5711)

This is the Gigabyte RGB Fusion 2.0 controller — not related to fan/temp sensors.

---

## Shared Storage Layout

Both machines have the same partition structure:

```
nvme0n1 (1.8 TB)
├── nvme0n1p1   1 GB    EFI
├── nvme0n1p2   2 GB    /boot
└── nvme0n1p3   1.8 TB  LVM
    └── ubuntu--vg-ubuntu--lv  100 GB  /
```

LVM volume group has ~1.7 TB unallocated — expand or add LVs as needed.
