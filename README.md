# Proxmox VE on Raspberry Pi 5 Installer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![Architecture](https://img.shields.io/badge/Arch-ARM64%20%2F%20aarch64-blue.svg)](https://arm.com)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-9%20(Trixie)-orange.svg)](https://proxmox.com)
[![Kernel](https://img.shields.io/badge/Kernel-Broadcom%204K%20(kernel8.img)-green.svg)](https://github.com/raspberrypi/linux)

An automated, non-interactive friendly Bash installation script to configure and install **Proxmox Virtual Environment (PVE)** on the **Raspberry Pi 5** (ARM64 architecture) running Debian / Raspberry Pi OS.

This installer prepares your system for hypervisor duty by setting up PCIe & 4K kernel configs, enabling cgroups, configuring bridge networking (`vmbr0`), applying RAM-based logging optimizations, setting up PVE Trixie repositories, and preventing architecture conflicts.

---

## Key Features & Optimizations

* **ARM64 Kernel & Boot Configurations:**
  * Enforces the 4KB page-size kernel (`kernel=kernel8.img`) required for broad ARM64 container and virtualization compatibility.
  * Enables PCIe Gen2 support (`dtparam=pciex1`, `dtparam=pciex1_gen=2`) in `/boot/firmware/config.txt` (ideal for NVMe HATs).
* **Cgroup Optimization for LXC/QEMU:**
  * Appends `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt`.
* **Storage Protection & Wear Reduction:**
  * Installs and configures **`log2ram`** from the Azlux repository to buffer repetitive disk writes to memory.
  * Configures `systemd-journald` to `Storage=volatile` to protect flash/NVMe media.
* **Network & Proxmox Bridge Setup:**
  * Replaces `NetworkManager` with `ifupdown2`.
  * Configures `/etc/network/interfaces` with a dedicated `vmbr0` Linux Bridge mapped to your active interface.
* **Proxmox Repositories & Package Management:**
  * Configures official Proxmox archive keys and adds the `pve-no-subscription` (Trixie) repository.
  * Installs core PVE packages (`pve-manager`, `pve-qemu-kvm`, `qemu-server`, `pve-container`, `pve-cluster`, `pve-firewall`, `pve-ha-manager`, `lxc-pve`) without pulling unwanted x86 recommended packages.
  * Disables the PVE Enterprise repository automatically.
  * Holds x86 metapackages (`proxmox-ve`, `proxmox-default-kernel`, `proxmox-kernel-*`) via `apt-mark hold` to protect your ARM64 kernel.
* **Cloud-Init & Hostname Persistence:**
  * Fixes `/etc/hosts` and generates a clean Cloud-Init Jinja template (`/etc/cloud/templates/hosts.debian.tmpl`) to prevent PVE cluster resolution errors.
* **Headless Mail Pre-Configuration:**
  * Pre-seeds `postfix` for local-only delivery without interactive blocking prompts.
* **PAM Root Password Check:**
  * Validates the `root` account status and guides password setup for PVE Web GUI PAM login.

---

## Prerequisites

* **Hardware:** Raspberry Pi 5 (NVMe SSD HAT or high-speed MicroSD).
* **Operating System:** 64-bit Debian 13 (Trixie) or compatible Raspberry Pi OS ARM64.
* **Privileges:** Root access (`sudo`).
* **Connection:** Active network/internet connection during installation.

---

## Installation & Usage

### 1. Clone the Repository
```bash
git clone https://github.com/Karesyk/pve-rpi5-installer.git
cd pve-rpi5-installer
```

### 2. Make the Script Executable
```bash
sudo chmod +x pve-rpi5-installer.sh
```

### 3. Run the Installer
```bash
sudo ./pve-rpi5-installer.sh
```

### 4. Interactive Configuration
The script will prompt you for the following network parameters (auto-detected defaults are suggested):
* **Node Hostname** (e.g., `pve-rpi5`)
* **Network Interface** (e.g., `eth0`)
* **Static IP Address with CIDR** (e.g., `192.168.1.100/24`)
* **Gateway IP Address** (e.g., `192.168.1.1`)
* **Root Password** (prompted only if locked or unset)

### 5. Reboot System
After the script completes, reboot the Raspberry Pi to boot the 4K kernel (`kernel8.img`), activate cgroups, and initialize `vmbr0`:
```bash
sudo reboot
```

---

## Proxmox Web GUI Access

Once the Raspberry Pi has rebooted, access the Proxmox administration web interface at:

```text
https://<YOUR-STATIC-IP>:8006
```

* **User:** `root`
* **Password:** The configured root password
* **Realm:** `Linux PAM standard authentication`

---

## Repository Structure

```text
├── pve-rpi5-installer.sh    # Main setup and provisioning script
├── LICENSE                  # License file (e.g., MIT)
└── README.md                # Project documentation
```

---

## License

This project is licensed under the [MIT License](LICENSE).
