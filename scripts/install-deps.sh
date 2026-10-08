#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo 'Run with sudo bash scripts/install-deps.sh' >&2
  exit 1
fi
if ! command -v apt-get >/dev/null; then
  echo 'This installer supports Ubuntu/Debian. Install iproute2, iptables, dnsmasq, BusyBox with udhcpc/nslookup, python3, curl, ping, and tcpdump on other distributions.' >&2
  exit 1
fi
# dnsmasq-base provides the executable without installing a host DNS/DHCP service.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends iproute2 iptables dnsmasq-base busybox-static python3 curl iputils-ping tcpdump
if ! busybox --list | grep -qx udhcpc; then
  echo 'The BusyBox build is missing the udhcpc applet.' >&2
  exit 1
fi
echo 'Dependencies installed. Next: sudo bash lab.sh up'
