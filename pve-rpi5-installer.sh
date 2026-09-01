#!/usr/bin/env bash
#
# Proxmox VE on Raspberry Pi 5 (NVMe + Onboard NIC)
# Includes Kernel (4K), Cgroups, Cloud-Init Jinja, Root Password check, 
# vmbr0 Bridge, Enterprise Repo, log2ram, and volatile journald setup
#

set -euo pipefail

# 1. Root check
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script with root privileges (sudo ./install-pve-rpi5.sh)"
  exit 1
fi

echo "=========================================================="
echo "  Proxmox VE Setup for Raspberry Pi 5 (NVMe + Cgroups)"
echo "=========================================================="

# 2. System base update & full-upgrade
echo "[INFO] Updating package lists and performing full-upgrade..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y

# 3. Determine network configuration and hostname
HOSTNAME=$(hostname)
DETECTED_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n 1 || true)
DETECTED_IFACE="${DETECTED_IFACE:-eth0}"

DETECTED_IP_CIDR=$(ip -4 addr show "$DETECTED_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n 1 || true)
if [ -z "$DETECTED_IP_CIDR" ]; then
    DETECTED_IP_PLAIN=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    DETECTED_IP_CIDR="${DETECTED_IP_PLAIN:-192.168.1.100}/24"
fi

DETECTED_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -n 1 || true)
DETECTED_GW="${DETECTED_GW:-192.168.1.1}"

read -rp "Node Hostname [$HOSTNAME]: " INPUT_HOST
HOSTNAME="${INPUT_HOST:-$HOSTNAME}"

read -rp "Network Interface [$DETECTED_IFACE]: " INPUT_IFACE
NET_IFACE="${INPUT_IFACE:-$DETECTED_IFACE}"

read -rp "Static IP Address with CIDR [$DETECTED_IP_CIDR]: " INPUT_IP
NODE_IP_CIDR="${INPUT_IP:-$DETECTED_IP_CIDR}"

# Strip CIDR prefix for /etc/hosts resolution
NODE_IP="${NODE_IP_CIDR%/*}"

read -rp "Gateway IP Address [$DETECTED_GW]: " INPUT_GW
NODE_GW="${INPUT_GW:-$DETECTED_GW}"

echo "[INFO] Configuring for Hostname: $HOSTNAME | Interface: $NET_IFACE | IP: $NODE_IP_CIDR | Gateway: $NODE_GW"

# 4. Check and set root password (required for Proxmox Web GUI PAM login)
ROOT_PW_STATUS=$(passwd -S root 2>/dev/null | awk '{print $2}' || true)

if [ "$ROOT_PW_STATUS" = "P" ]; then
    echo "[INFO] Root password is already configured. Skipping password prompt."
else
    echo "----------------------------------------------------------"
    echo "[INFO] Root password is not set or locked."
    echo "[INFO] Set a password for the 'root' user (Proxmox Web GUI login):"
    until passwd root; do
        echo "[WARNING] Password update failed, please try again."
    done
    echo "----------------------------------------------------------"
fi

# 5. FIX 1: Boot firmware parameters in config.txt (PCIe + kernel8.img)
CONFIG_TXT="/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ]; then
    echo "[INFO] Configuring $CONFIG_TXT..."
    grep -q "^dtparam=pciex1" "$CONFIG_TXT" || echo "dtparam=pciex1" >> "$CONFIG_TXT"
    grep -q "^dtparam=pciex1_gen=2" "$CONFIG_TXT" || echo "dtparam=pciex1_gen=2" >> "$CONFIG_TXT"
    grep -q "^kernel=kernel8.img" "$CONFIG_TXT" || echo "kernel=kernel8.img" >> "$CONFIG_TXT"
else
    echo "[WARNING] $CONFIG_TXT not found."
fi

# 6. FIX 2: Append cgroups to cmdline.txt
CMDLINE_TXT="/boot/firmware/cmdline.txt"
CGROUP_PARAMS="cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1"

if [ -f "$CMDLINE_TXT" ]; then
    echo "[INFO] Configuring cgroups in $CMDLINE_TXT..."
    if ! grep -q "cgroup_enable=cpuset" "$CMDLINE_TXT"; then
        sed -i "s/$/ ${CGROUP_PARAMS}/" "$CMDLINE_TXT"
    fi
else
    echo "[WARNING] $CMDLINE_TXT not found."
fi

# 7. Configure systemd-journald to volatile (RAM only to reduce disk wear)
JOURNALD_CONF="/etc/systemd/journald.conf"
echo "[INFO] Configuring systemd-journald storage to volatile..."
if [ -f "$JOURNALD_CONF" ]; then
    if grep -q "^#\?Storage=" "$JOURNALD_CONF"; then
        sed -i "s/^#\?Storage=.*/Storage=volatile/" "$JOURNALD_CONF"
    else
        echo "Storage=volatile" >> "$JOURNALD_CONF"
    fi
    systemctl restart systemd-journald || true
fi

# 8. Disable Raspberry Pi Swap (reduce NVMe/SD wear & optimize memory management)
echo "[INFO] Disabling Raspberry Pi swap..."
mkdir -p /etc/rpi/swap.conf.d/
cat << 'EOF' > /etc/rpi/swap.conf.d/90-disable-swap.conf
[Main]
Mechanism=none
EOF
swapoff -a 2>/dev/null || true

# 9. Configure hostname resolution & clean Cloud-Init Jinja template
echo "[INFO] Adjusting hostname resolution and cloud-init template..."
sed -i "/127\.0\.1\.1/d" /etc/hosts

if grep -q "$HOSTNAME" /etc/hosts; then
    sed -i "s/.*$HOSTNAME.*/$NODE_IP $HOSTNAME.local $HOSTNAME/" /etc/hosts
else
    echo "$NODE_IP $HOSTNAME.local $HOSTNAME" >> /etc/hosts
fi

CLOUD_TMPL_DIR="/etc/cloud/templates"
if [ -d "$CLOUD_TMPL_DIR" ]; then
    echo "[INFO] Writing clean Jinja template to $CLOUD_TMPL_DIR/hosts.debian.tmpl..."
    cat << TEMPLATE_EOF > "${CLOUD_TMPL_DIR}/hosts.debian.tmpl"
## template:jinja
{#
This file (/etc/cloud/templates/hosts.debian.tmpl) is only utilized
if enabled in cloud-config.  Specifically, in order to enable it
you need to add the following to config:
   manage_etc_hosts: True
-#}
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
{# The value '{{hostname}}' will be replaced with the local-hostname -#}
${NODE_IP} {{fqdn}} {{hostname}}
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
TEMPLATE_EOF

    cloud-init single --name update_etc_hosts --frequency always || true
fi

# 10. Set up prerequisites & repositories (Proxmox + Azlux / log2ram)
echo "[INFO] Installing prerequisites & GPG keys..."
apt-get update
apt-get install -y wget ca-certificates gnupg debconf-utils

# Proxmox GPG Key & Repositories
PVE_KEY="/usr/share/keyrings/proxmox-archive-keyring.gpg"
wget -qO "$PVE_KEY" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg

# Active No-Subscription Repository
cat << 'SOURCES' > /etc/apt/sources.list.d/proxmox.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SOURCES

# Azlux Repository for log2ram
AZLUX_KEY="/usr/share/keyrings/azlux-archive-keyring.gpg"
wget -qO "$AZLUX_KEY" https://azlux.fr/repo.gpg
echo "deb [signed-by=${AZLUX_KEY}] http://packages.azlux.fr/debian/ trixie main" > /etc/apt/sources.list.d/azlux.list

# 11. Preconfigure Postfix (Headless / Non-interactive)
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $HOSTNAME.local" | debconf-set-selections

# 12. Update package index
apt-get update

# 13. Install ifupdown2, log2ram & configure Proxmox Linux Bridge (vmbr0)
echo "[INFO] Disabling NetworkManager if present..."
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true

echo "[INFO] Installing ifupdown2 and log2ram..."
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y ifupdown2 log2ram
rm -f /etc/network/interfaces.new

echo "[INFO] Configuring Proxmox Linux Bridge (vmbr0) in /etc/network/interfaces..."
cat << INTERFACES_EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

iface ${NET_IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${NODE_IP_CIDR}
    gateway ${NODE_GW}
    bridge-ports ${NET_IFACE}
    bridge-stp off
    bridge-fd 0
INTERFACES_EOF

# 14. Install Proxmox packages without default/x86 kernel
echo "[INFO] Installing Proxmox VE core packages..."
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y --no-install-recommends     pve-manager     pve-qemu-kvm     qemu-server     pve-container     pve-cluster     pve-firewall     pve-ha-manager     lxc-pve

# 15. Disable Enterprise Repository post-install
echo "[INFO] Disabling PVE Enterprise repository..."
if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
    cat << 'SOURCES_ENT' > /etc/apt/sources.list.d/pve-enterprise.sources
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: no
SOURCES_ENT
fi

# 16. Place apt-hold on metapackages and stock kernels
echo "[INFO] Holding PVE kernel metapackages..."
apt-mark hold proxmox-ve proxmox-default-kernel proxmox-kernel-* || true

# 17. Restart Proxmox services
echo "[INFO] Restarting Proxmox services..."
systemctl reset-failed pve-cluster pvestatd || true
systemctl restart pve-cluster
systemctl restart pvedaemon
systemctl restart pveproxy
systemctl restart pvestatd

echo "=========================================================="
echo "  Installation completed successfully!"
echo "  Web interface: https://$NODE_IP:8006"
echo "  Login User   : root"
echo "  Bridge Config: vmbr0 active on ${NET_IFACE}"
echo "  log2ram      : Installed (reduces disk writes)"
echo "  journald     : Set to volatile (RAM-buffered logs)"
echo "  NOTE: Please run 'sudo reboot' now to load the 4K kernel"
echo "  (kernel8.img), cgroups, and apply the bridge networking."
echo "=========================================================="
