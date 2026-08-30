# Proxmox VE 9 on Raspberry Pi 5 (Native NVMe Boot & Onboard NIC)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![Architecture](https://img.shields.io/badge/Arch-ARM64%20%2F%20aarch64-blue.svg)](https://arm.com)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-9%20(Trixie)-orange.svg)](https://proxmox.com)
[![Kernel](https://img.shields.io/badge/Kernel-Broadcom%204K%20(kernel8.img)-green.svg)](https://github.com/raspberrypi/linux)

A production-ready automated deployment script and comprehensive guide for running official **Proxmox VE 9 (Debian Trixie) ARM64** on a **Raspberry Pi 5**. This setup boots directly from an M.2 NVMe SSD over PCIe Gen 2, preserves the native Broadcom kernel for onboard Gigabit Ethernet functionality, enforces 4K page-size compatibility for QEMU/KVM, and includes flash-wear mitigations out of the box.

---

## Table of Contents

1. [Architecture & Why This Approach Works](#architecture--why-this-approach-works)
2. [Automated Optimizations & Fixes](#automated-optimizations--fixes)
3. [Hardware & Software Requirements](#hardware--software-requirements)
4. [Pre-Installation: EEPROM Boot Order](#pre-installation-eeprom-boot-order)
5. [Quick Installation](#quick-installation)
6. [Detailed Script Breakdown](#detailed-script-breakdown)
7. [Post-Installation Configuration](#post-installation-configuration)
   - [Proxmox Web GUI Access](#proxmox-web-gui-access)
   - [Network Bridge Topology (`vmbr0`)](#network-bridge-topology-vmbr0)
   - [Configuring Local Storage Pools](#configuring-local-storage-pools)
8. [Maintenance & Package Upgrades](#maintenance--package-upgrades)
9. [Troubleshooting & Known Behaviors](#troubleshooting--known-behaviors)
10. [References & Acknowledgments](#references--acknowledgments)
11. [License](#license)

---

## Architecture & Why This Approach Works

Attempting to install generic Proxmox VE ARM64 ISOs directly on the Raspberry Pi 5 via standard UEFI environments typically fails due to two major hardware-support gaps:
- **Onboard NIC Failure:** The Raspberry Pi 5 onboard Gigabit Ethernet controller requires Broadcom-specific kernel drivers and device-tree overlays not present in generic distribution kernels.
- **NVMe Detection Issues:** Native PCIe initialization on the BCM2712 SoC requires explicit device-tree parameters (`dtparam=pciex1`).

```
+--------------------------------------------------------------------------+
|                        Proxmox VE 9 Web GUI & APIs                       |
|   (pve-manager, pve-cluster, pve-firewall, pve-ha-manager, qemu-server)  |
+--------------------------------------------------------------------------+
|                  Virtualization & Container Runtimes                     |
|           KVM / QEMU (ARM64)        |        LXC Containers (ARM64)      |
+-------------------------------------+------------------------------------+
|               System Layer & Write Protection Optimizations              |
|   ifupdown2 (vmbr0)  |  log2ram (RAM Logs)  |  systemd-journald volatile |
+--------------------------------------------------------------------------+
|                  Raspberry Pi OS Lite 64-Bit Base                        |
|   - 4K Page-Size Kernel (kernel8.img)                                    |
|   - Cgroup v2 Subsystems (cpuset, memory)                                |
|   - Broadcom Hardware Drivers & Firmware                                 |
+--------------------------------------------------------------------------+
|                         Raspberry Pi 5 Hardware                          |
|   Broadcom BCM2712 SoC  |  Onboard Gigabit NIC  |  PCIe Gen 2 NVMe HAT   |
+--------------------------------------------------------------------------+
```

By using **Raspberry Pi OS Lite (64-bit)** as the host foundation and overlaying official Proxmox VE ARM64 repositories with `--no-install-recommends`, the system keeps the native Broadcom drivers while running the complete Proxmox management stack.

---

## Automated Optimizations & Fixes

The installation script (`install-pve-rpi5.sh`) handles all configuration adjustments automatically:

| Component | Target File | Action Taken | Why It Is Needed |
| :--- | :--- | :--- | :--- |
| **PCIe Interface** | `/boot/firmware/config.txt` | `dtparam=pciex1`<br>`dtparam=pciex1_gen=2` | Activates external PCIe bus at 5.0 GT/s (Gen 2) link rate. |
| **4K Memory Pages** | `/boot/firmware/config.txt` | `kernel=kernel8.img` | The Pi 5 defaults to a 16KB kernel. QEMU/KVM and standard Linux containers require 4KB page sizes. |
| **Cgroup Subsystems**| `/boot/firmware/cmdline.txt` | `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` | Enables resource limits, memory tracking, and CPU pinning for LXC/QEMU. |
| **Volatile Logs** | `/etc/systemd/journald.conf` | `Storage=volatile` | Buffers system logs in RAM to minimize NVMe write cycles and prevent flash degradation. |
| **Log to RAM** | `/etc/apt/sources.list.d/azlux.list` | Installs `log2ram` | Mounts `/var/log` into a virtual RAM disk, flushing periodically to disk. |
| **Cluster Resolution**| `/etc/hosts` & Cloud-Init | Maps static IP to hostname | Proxmox cluster engines fail when the node hostname resolves to `127.0.1.1`. |
| **Jinja Template** | `/etc/cloud/templates/hosts.debian.tmpl` | Recreates valid Jinja template | Prevents Cloud-Init from reverting `/etc/hosts` to `127.0.1.1` upon reboot. |
| **Network Manager** | Systemd Services | Disables `NetworkManager` | Prevents conflicts with Debian's standard interface engine. |
| **Interface Bridge** | `/etc/network/interfaces` | Configures `vmbr0` via `ifupdown2` | Creates the standard Proxmox Linux Bridge attached to physical `eth0`. |
| **PVE Repositories** | `/etc/apt/sources.list.d/` | Configures `pve-no-subscription`<br>Disables `pve-enterprise` | Gives access to ARM64 packages without requiring a paid subscription key. |
| **Kernel Pinning** | `dpkg` / `apt-mark` | `apt-mark hold proxmox-ve proxmox-default-kernel` | Protects the Broadcom bootloader from being overwritten by `apt upgrade`. |

---

## Hardware & Software Requirements

### Hardware Requirements
- **Raspberry Pi 5** (8GB or 16GB RAM recommended; 4GB supported).
- **Storage (Choose one):**
  - **NVMe Setup (Recommended):** M.2 NVMe HAT board (e.g., Raspberry Pi official HAT+, Pineberry HatDrive, Pimoroni NVMe Base, Geekworm, Electrocookie) + PCIe Gen 2/Gen 3 M.2 NVMe SSD (128GB to 2TB).
  - **MicroSD Setup:** High-endurance microSD card (A2 / Class 10, 32GB+ minimum).
- **Power Supply:** Official Raspberry Pi 27W USB-C PD Power Supply (5.1V / 5.0A required for stable PCIe rail power delivery).
- **Cooling:** Active Cooler or heavy aluminum passive heatsink case.

### Software Requirements
- **Raspberry Pi OS Lite (64-bit)** (Debian Trixie or Bookworm base) flashed directly to your NVMe SSD or microSD card.

---

## Pre-Installation: EEPROM Boot Order

> ⚠️ **Prerequisite Check:** Configure this setting only if booting from an NVMe drive. MicroSD-only setups can safely proceed to the next step.

Before running the installer, ensure the Raspberry Pi 5 EEPROM is configured to boot directly from NVMe:

1. Open the EEPROM boot configuration editor:
   ```bash
   sudo rpi-eeprom-config --edit
   ```
2. Update the `BOOT_ORDER` variable (Raspberry Pi reads boot priority right to left: `1` = SD card, `6` = NVMe, `4` = USB):
   ```ini
   [all]
   BOOT_ORDER=0xf461
   ```
3. Save the file (`Ctrl+O`, `Enter`, `Ctrl+X`) and reboot.
4. Verify that the NVMe drive is mounted as the root filesystem:
   ```bash
   findmnt /
   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
   ```

---

## Quick Installation

```bash
# 1. Clone this repository
git clone https://github.com/<YOUR-USERNAME>/proxmox-rpi5-installer.git
cd proxmox-rpi5-installer

# 2. Make the script executable
chmod +x install-pve-rpi5.sh

# 3. Run the installer with administrative privileges
sudo ./install-pve-rpi5.sh

# 4. Reboot after script completion
sudo reboot
```

During execution, the script will prompt for:
- **Node Hostname** (Press Enter to keep current hostname)
- **Network Interface** (Defaults to active Ethernet interface, e.g. `eth0`)
- **Static IP with CIDR** (e.g. `192.168.1.150/24`)
- **Gateway IP** (e.g. `192.168.1.1`)
- **Root Password** (Only requested if the `root` account does not yet have a password configured)

---

## Detailed Script Breakdown

The deployment script executes the following sequential tasks:

1. **Privilege & Environment Validation:** Asserts running as root (`EUID 0`) and verifies Bash environment.
2. **Network Parameter Discovery:** Uses `ip route` and `hostname -I` to auto-detect interface names, subnet CIDRs, and default gateways.
3. **Root Authentication Setup:** Inspects `passwd -S root`. If the root password is empty or locked (`L`), prompts for interactive creation.
4. **Boot Configuration Updates:**
   - Appends `dtparam=pciex1`, `dtparam=pciex1_gen=2`, and `kernel=kernel8.img` to `/boot/firmware/config.txt`.
   - Injects `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` into `/boot/firmware/cmdline.txt`.
5. **Flash Wear Mitigation:**
   - Modifies `/etc/systemd/journald.conf` to set `Storage=volatile`.
   - Adds the Azlux repository and installs `log2ram`.
6. **Network & Hostname Resolution:**
   - Removes `127.0.1.1` mappings from `/etc/hosts` and binds the static LAN IP directly to the hostname.
   - Replaces `/etc/cloud/templates/hosts.debian.tmpl` with valid Jinja syntax.
7. **Repository & Key Provisioning:**
   - Downloads the Proxmox Trixie GPG archive key (`proxmox-archive-keyring-trixie.gpg`).
   - Configures `/etc/apt/sources.list.d/proxmox.sources` (active `pve-no-subscription`).
   - Configures `/etc/apt/sources.list.d/pve-enterprise.sources` (`Enabled: no`).
8. **Bridge Networking Setup:**
   - Disables and stops `NetworkManager`.
   - Installs `ifupdown2` and writes the `vmbr0` Linux Bridge definition to `/etc/network/interfaces`.
9. **Selective Core Package Installation:**
   - Pre-seeds Postfix `main_mailer_type` to `Local only`.
   - Installs `pve-manager`, `pve-qemu-kvm`, `qemu-server`, `pve-container`, `pve-cluster`, `pve-firewall`, `pve-ha-manager`, and `lxc-pve` without recommended packages (`--no-install-recommends`).
10. **Metapackage Hold:**
    - Flags `proxmox-ve`, `proxmox-default-kernel`, and `proxmox-kernel-*` with `apt-mark hold`.
11. **Service Initialization:**
    - Resets failed service states and restarts `pve-cluster`, `pvedaemon`, `pveproxy`, and `pvestatd`.

---

## Post-Installation Configuration

### Proxmox Web GUI Access

Once the Raspberry Pi has finished rebooting:

1. Open your browser and go to:
   ```text
   https://<YOUR-PI-IP>:8006
   ```
2. Log in with the following credentials:
   - **User name:** `root`
   - **Password:** The password set during the installation
   - **Realm:** `Linux PAM Standard Authentication`

---

### Network Bridge Topology (`vmbr0`)

The installer provisions `/etc/network/interfaces` with standard Proxmox bridge networking:

```ini
auto lo
iface lo inet loopback

iface eth0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.150/24
    gateway 192.168.1.1
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
```

When creating Virtual Machines or LXC Containers in the GUI, assign them to network bridge `vmbr0` to place them directly onto your physical LAN subnet.

---

### Configuring Local Storage Pools

Because the installation is layered on an existing Raspberry Pi OS filesystem:
1. In the Web GUI, navigate to **Datacenter -> Storage -> Add -> Directory**.
2. Set **ID** to `local-data` (or your preferred name).
3. Set **Directory** to `/var/lib/vz`.
4. Select all content types: **ISO image, Container template, VZDump backup, Disk image, Container**.

---

## Maintenance & Package Upgrades

Because all generic x86 and default PVE kernel metapackages are protected via `apt-mark hold`, you can safely update the host system via standard Debian tooling:

```bash
# Update package repositories and upgrade packages
sudo apt update
sudo apt dist-upgrade -y
```

### Checking Package Holds
To verify that kernel protection remains active:
```bash
apt-mark showhold
```
*Expected output:*
```text
proxmox-default-kernel
proxmox-ve
```

> **Warning:** Never run `apt install proxmox-ve` or unhold the kernel packages. Doing so will replace the Raspberry Pi boot chain with standard x86/ARM generic kernels and break hardware initialization.

---

## Troubleshooting & Known Behaviors

### 1. `proxmox-ve: not correctly installed` warning in `pveversion -v`
```text
# pveversion -v
proxmox-ve: not correctly installed (running kernel: 6.18.xx+rpt-rpi-2712)
pve-manager: 9.x.x
...
```
- **Cause:** Proxmox expects its own packaged kernel (`proxmox-kernel-*`). On Raspberry Pi 5, the Broadcom kernel (`kernel8.img`) is used instead to retain hardware support.
- **Action:** None. This warning is cosmetic and does not impact hypervisor stability.

### 2. Node Status shows a Question Mark (`?`) in the Web GUI
- **Cause:** The cluster statistics collector (`pvestatd`) occasionally desynchronizes after an initial cold boot.
- **Resolution:**
  ```bash
  sudo systemctl restart pvestatd
  ```

### 3. Verifying PCIe Link Speed
To confirm that the NVMe HAT is running at full PCIe Gen 2 (5.0 GT/s) speeds:
```bash
dmesg | grep -i pcie
```
*Expected output:*
```text
brcm-pcie 1000110000.pcie: link up, 5.0 GT/s PCIe x1
```

### 4. Verifying 4K Page-Size Kernel
To confirm that the 4K kernel is actively running:
```bash
getconf PAGESIZE
```
*Expected output:* `4096` *(If output shows `16384`, verify `kernel=kernel8.img` in `/boot/firmware/config.txt` and reboot).*

---

## References & Acknowledgments

- **Technical Analysis & Core Procedure:** [Virtualization Howto by Brandon Lee](https://www.virtualizationhowto.com/2026/08/i-got-proxmox-ve-9-working-on-raspberry-pi-5-with-nvme-boot-and-the-onboard-nic/)
- **ARM64 Virtualization Workarounds:** [Pxvirt Documentation](https://docs.pxvirt.lierfang.com/en/case/issue/raspberrypi.html)
- **Log RAM Storage Engine:** [Azlux log2ram](https://github.com/azlux/log2ram)
- **Official Proxmox VE Project:** [Proxmox Server Solutions GmbH](https://www.proxmox.com)

---

## License

This project is open-source and released under the terms of the [MIT License](LICENSE).
