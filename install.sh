#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi OS Lite
# WiFi AP + NAT gateway
# Pi-hole FTL (Docker, host network) provides DNS + DHCP

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"

if [[ "$EUID" -ne 0 ]]; then
  echo "[!] Run as root" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[!] Missing .env file" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

log() { echo "[+] $*"; }

########################################
# Base packages
########################################
APT_PKGS=(
  curl ca-certificates gnupg lsb-release
  nftables iproute2 net-tools
  dhcpcd5 hostapd
)

########################################
# Disable conflicting services
########################################
disable_conflicting_services() {
  log "Disabling conflicting services"
  systemctl stop systemd-resolved || true
  systemctl disable systemd-resolved || true
  systemctl stop dnsmasq || true
  systemctl disable dnsmasq || true
  systemctl stop wpa_supplicant@wlan0 || true
  systemctl disable wpa_supplicant@wlan0 || true
}

########################################
# Install packages
########################################
install_packages() {
  log "Installing system packages"
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y "${APT_PKGS[@]}"
}

########################################
# Docker
########################################
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  apt-get install -y docker-compose-plugin
  systemctl enable docker
  systemctl restart docker
}

########################################
# Kernel routing
########################################
enable_ip_forwarding() {
  log "Enabling IPv4 forwarding"
  cat >/etc/sysctl.d/99-router.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=0
EOF
  sysctl --system
}

########################################
# dhcpcd (static IP for AP)
########################################
configure_dhcpcd() {
  log "Configuring static IP for ${LAN_IFACE}"

  sed -i "/^interface ${LAN_IFACE}/,/^$/d" /etc/dhcpcd.conf

  cat >> /etc/dhcpcd.conf <<EOF

interface ${LAN_IFACE}
static ip_address=${LAN_GW_IP}
static domain_name_servers=1.1.1.1 1.0.0.1
nohook wpa_supplicant
EOF

  systemctl enable dhcpcd
  systemctl restart dhcpcd
}

########################################
# RF-kill Unblocking with Retry
########################################
unblock_rfkill() {
  log "Checking and unblocking RF-kill if necessary"

  # Check if the wireless interface is soft blocked
  if rfkill list | grep -q "Soft blocked: yes"; then
    log "Unblocking wireless interface via RF-kill"
    rfkill unblock wifi
  fi

  # Retry bringing the wireless interface up
  local retries=3
  while [[ $retries -gt 0 ]]; do
    if ip link set "${LAN_IFACE}" up; then
      log "Wireless interface ${LAN_IFACE} is up"
      return
    else
      log "Failed to bring up ${LAN_IFACE}, retrying..."
      ((retries--))
      sleep 2
    fi
  done

  log "ERROR: Unable to bring up ${LAN_IFACE} after multiple attempts"
  exit 1
}

########################################
# hostapd
########################################
configure_hostapd() {
  log "Configuring hostapd"

  unblock_rfkill  # Ensure RF-kill does not block the interface

  systemctl unmask hostapd || true

  cat >/etc/hostapd/hostapd.conf <<EOF
country_code=${WIFI_COUNTRY}
interface=${LAN_IFACE}
driver=nl80211
ssid=${WIFI_SSID}
hw_mode=g
channel=${WIFI_CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0

wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd

  mkdir -p /etc/systemd/system/hostapd.service.d
  cat >/etc/systemd/system/hostapd.service.d/override.conf <<EOF
[Unit]
After=dhcpcd.service
Requires=dhcpcd.service
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable hostapd
  systemctl restart hostapd
}

########################################
# nftables (NAT + firewall)
########################################
configure_nftables() {
  log "Configuring nftables"

  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept
    ip protocol icmp accept

    iif "${LAN_IFACE}" udp dport { 53, 67 } accept
    iif "${LAN_IFACE}" tcp dport 53 accept
    iif "${LAN_IFACE}" tcp dport 22 accept

    counter drop
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;

    ct state established,related accept
    iif "${LAN_IFACE}" oif "${WAN_IFACE}" accept

    counter drop
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oif "${WAN_IFACE}" masquerade
  }
}
EOF

  systemctl enable nftables
  systemctl restart nftables
}

########################################
# Docker iptables Configuration
########################################
configure_docker_iptables() {
  log "Configuring Docker iptables settings"

  # Ensure Docker daemon.json exists and has iptables enabled
  DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
  if [[ ! -f "$DOCKER_DAEMON_CONFIG" ]]; then
    log "Creating Docker daemon.json with iptables enabled"
    cat > "$DOCKER_DAEMON_CONFIG" <<EOF
{
  "iptables": true
}
EOF
  else
    log "Ensuring iptables is enabled in Docker daemon.json"
    if ! grep -q '"iptables": true' "$DOCKER_DAEMON_CONFIG"; then
      sed -i 's/}/,\n  "iptables": true\n}/' "$DOCKER_DAEMON_CONFIG"
    fi
  fi

  # Ensure iptables is in legacy mode
  log "Setting iptables to legacy mode"
  update-alternatives --set iptables /usr/sbin/iptables-legacy
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

  # Create DOCKER-FORWARD chain if missing
  log "Ensuring DOCKER-FORWARD chain exists"
  iptables -C FORWARD -o docker0 -j DOCKER-FORWARD 2>/dev/null || {
    iptables -N DOCKER-FORWARD 2>/dev/null || log "DOCKER-FORWARD chain already exists, continuing..."
  }
  iptables -C FORWARD -o docker0 -j DOCKER-FORWARD 2>/dev/null || iptables -A FORWARD -o docker0 -j DOCKER-FORWARD
  iptables -C FORWARD -i docker0 -j DOCKER-FORWARD 2>/dev/null || iptables -A FORWARD -i docker0 -j DOCKER-FORWARD

  # Restart Docker to apply changes
  log "Restarting Docker"
  systemctl restart docker
}

########################################
# Docker stack
########################################
deploy_stack() {
  log "Deploying Docker stack"
  cd "$REPO_DIR"
  docker compose pull
  docker compose up -d
}

########################################
# Pi-hole FTL
########################################
restart_pihole() {
  log "Reloading Pi-hole DNS"

  # Wait for the Pi-hole container to be healthy
  local retries=12
  while [[ $retries -gt 0 ]]; do
    if docker inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null | grep -q "healthy"; then
      log "Pi-hole container is healthy"
      break
    else
      log "Waiting for Pi-hole container to become healthy..."
      ((retries--))
      sleep 10
    fi
  done

  if [[ $retries -eq 0 ]]; then
    log "ERROR: Pi-hole container did not become healthy"
    exit 1
  fi

  # Reload DNS inside the Pi-hole container
  if ! docker exec pihole pihole enable; then
    log "ERROR: Failed to enable Pi-hole"
    exit 1
  fi
  if ! docker exec pihole pihole reloaddns; then
    log "ERROR: Failed to reload Pi-hole DNS"
    exit 1
  fi
}

########################################
# Main
########################################
main() {
  install_packages
  disable_conflicting_services
  install_docker
  enable_ip_forwarding
  configure_dhcpcd
  configure_hostapd
  configure_nftables
  configure_docker_iptables  # Added this step
  deploy_stack
  restart_pihole

  log "Setup complete. Reboot recommended."
}

main "$@"
