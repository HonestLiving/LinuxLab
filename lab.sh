#!/usr/bin/env bash
# Five network namespaces; no host interfaces, routes, firewall rules, or sysctls.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/run/matthew-network-lab
OWNER='matthew-network-lab-v1'
NAMES=(nlab-a nlab-b nlab-router nlab-services nlab-outside)

fail() { echo "Error: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || fail 'Run this command with sudo bash lab.sh'; }
ns_exists() { ip netns list | awk '{print $1}' | grep -Fxq -- "$1"; }
owned_state() {
  [[ ! -L $STATE && -d $STATE && -f $STATE/owner && ! -L $STATE/owner ]] &&
    [[ $(stat -c %u "$STATE") == 0 && $(cat "$STATE/owner") == "$OWNER" ]]
}
require_running() {
  owned_state || fail 'No lab state found. Run: sudo bash lab.sh up'
  local ns
  for ns in "${NAMES[@]}"; do
    ns_exists "$ns" || fail "Missing namespace $ns. Run down, then up."
  done
  [[ -f $STATE/ready ]] || fail 'Setup is incomplete. Run down, then up.'
}
resolve_ns() {
  case "${1:-}" in
    a|b|router|services|outside) printf 'nlab-%s\n' "$1" ;;
    *) fail 'Namespace must be a, b, router, services, or outside.' ;;
  esac
}
preflight() {
  local tool
  for tool in ip iptables dnsmasq busybox python3 curl ping tcpdump sysctl flock; do
    command -v "$tool" >/dev/null || fail "Missing $tool; run sudo bash scripts/install-deps.sh"
  done
  busybox --list | grep -qx udhcpc || fail 'BusyBox needs the udhcpc applet.'
  busybox --list | grep -qx nslookup || fail 'BusyBox needs the nslookup applet.'
}
down() {
  if [[ ! -e $STATE && ! -L $STATE ]]; then
    echo 'Lab is already down.'
    return
  fi
  owned_state || fail "Refusing to remove unrecognized state at $STATE"
  local ns pid
  local -a pids=()
  for ns in "${NAMES[@]}"; do
    if ns_exists "$ns"; then
      mapfile -t pids < <(ip netns pids "$ns")
      for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    fi
  done
  sleep 0.2
  for ns in "${NAMES[@]}"; do
    if ns_exists "$ns"; then
      mapfile -t pids < <(ip netns pids "$ns")
      for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
      ip netns del "$ns"
    fi
  done
  # STATE is a fixed path, validated above; this never targets the checkout.
  rm -rf -- "$STATE"
  echo 'Removed lab namespaces, processes, and runtime files.'
}
link_to_router() {
  local remote=$1 router_if=$2 router_ip=$3 remote_ip=${4:-}
  ip -n nlab-router link add "$router_if" type veth peer name eth0 netns "$remote"
  ip -n nlab-router addr add "$router_ip/24" dev "$router_if"
  ip -n nlab-router link set "$router_if" up
  ip -n "$remote" link set eth0 up
  if [[ -n $remote_ip ]]; then ip -n "$remote" addr add "$remote_ip/24" dev eth0; fi
}
start_process() {
  local ns=$1 label=$2
  shift 2
  ip netns exec "$ns" "$@" >"$STATE/$label.log" 2>&1 9>&- &
  echo "$!" >"$STATE/$label.pid"
}
wait_address() {
  local ns=$1 prefix=$2 attempt
  for attempt in {1..200}; do
    if ip -4 -o -n "$ns" addr show dev eth0 | grep -Fq "inet $prefix"; then return; fi
    sleep 0.1
  done
  echo "DHCP failed in $ns; service logs:" >&2
  tail -n 20 "$STATE"/*.log >&2
  return 1
}
up() {
  preflight
  if owned_state; then
    require_running
    echo 'Lab is already up. Run sudo bash lab.sh check to verify it.'
    return
  fi
  [[ ! -e $STATE && ! -L $STATE ]] || fail "State path already exists: $STATE"
  local ns
  for ns in "${NAMES[@]}"; do
    if ns_exists "$ns"; then fail "Namespace $ns already exists; refusing to overwrite it."; fi
  done
  umask 077
  mkdir -- "$STATE"
  printf '%s\n' "$OWNER" >"$STATE/owner"
  # Tear down partially constructed labs if any setup command fails.
  trap 'rc=$?; trap - ERR INT TERM; echo "Setup failed; removing partial lab." >&2; down; exit "$rc"' ERR
  trap 'trap - ERR INT TERM; down; exit 130' INT TERM
  for ns in "${NAMES[@]}"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
  done
  link_to_router nlab-a lan-a 10.10.10.1
  link_to_router nlab-b lan-b 10.10.20.1
  link_to_router nlab-services services 10.10.30.1 10.10.30.2
  link_to_router nlab-outside wan 198.18.0.1 198.18.0.2
  ip -n nlab-a link set eth0 address 02:00:00:00:00:0a
  ip -n nlab-b link set eth0 address 02:00:00:00:00:0b
  ip -n nlab-services route add default via 10.10.30.1
  # Outside intentionally has no route back to the private subnets.
  ip netns exec nlab-router sysctl -qw net.ipv4.ip_forward=1
  ip netns exec nlab-router iptables -P FORWARD DROP
  ip netns exec nlab-router iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip netns exec nlab-router iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT
  ip netns exec nlab-router iptables -A FORWARD -s 10.10.20.0/24 -j ACCEPT
  ip netns exec nlab-router iptables -A FORWARD -s 10.10.30.0/24 -j ACCEPT
  ip netns exec nlab-router iptables -t nat -A POSTROUTING -s 10.10.0.0/16 -o wan -j MASQUERADE
  cat >"$STATE/server.conf" <<EOF
port=53
interface=eth0
bind-interfaces
user=root
group=root
no-resolv
no-hosts
local=/lab/
host-record=outside.lab,198.18.0.2
dhcp-authoritative
dhcp-range=set:lan_a,10.10.10.100,10.10.10.150,255.255.255.0,1h
dhcp-range=set:lan_b,10.10.20.100,10.10.20.150,255.255.255.0,1h
dhcp-option=tag:lan_a,option:router,10.10.10.1
dhcp-option=tag:lan_b,option:router,10.10.20.1
dhcp-option=option:dns-server,10.10.30.2
dhcp-leasefile=$STATE/dnsmasq.leases
log-dhcp
log-facility=-
EOF
  cat >"$STATE/relay.conf" <<EOF
port=0
interface=lan-a
interface=lan-b
interface=services
bind-interfaces
user=root
group=root
dhcp-relay=10.10.10.1,10.10.30.2,services
dhcp-relay=10.10.20.1,10.10.30.2,services
log-dhcp
log-facility=-
EOF
  cp -- "$ROOT/scripts/dhcp-hook.sh" "$STATE/dhcp-hook.sh"
  chmod 700 "$STATE/dhcp-hook.sh"
  dnsmasq --test --conf-file="$STATE/server.conf"
  dnsmasq --test --conf-file="$STATE/relay.conf"
  start_process nlab-services dhcp-server dnsmasq --keep-in-foreground --conf-file="$STATE/server.conf" --pid-file="$STATE/server-daemon.pid"
  start_process nlab-router dhcp-relay dnsmasq --keep-in-foreground --conf-file="$STATE/relay.conf" --pid-file="$STATE/relay-daemon.pid"
  start_process nlab-outside outside-http python3 "$ROOT/scripts/outside-server.py"
  sleep 0.3
  # Broadcast replies reach clients before they own their offered address.
  start_process nlab-a client-a busybox udhcpc -f -B -i eth0 -s "$STATE/dhcp-hook.sh" -p "$STATE/udhcpc-a.pid" -x hostname:client-a -t 5 -T 2 -n
  start_process nlab-b client-b busybox udhcpc -f -B -i eth0 -s "$STATE/dhcp-hook.sh" -p "$STATE/udhcpc-b.pid" -x hostname:client-b -t 5 -T 2 -n
  wait_address nlab-a 10.10.10.
  wait_address nlab-b 10.10.20.
  touch "$STATE/ready"
  trap - ERR INT TERM
  echo 'Lab is up. Next: sudo bash lab.sh check'
  status
}
status() {
  require_running
  local ns
  for ns in "${NAMES[@]}"; do
    printf '\n%s\n' "$ns"
    ip -br -4 -n "$ns" addr show
    ip -4 -n "$ns" route show
  done
  printf '\nDHCP leases (expiry, MAC, address, hostname, client ID):\n'
  cat "$STATE/dnsmasq.leases"
  printf '\nRouter NAT rules:\n'
  ip netns exec nlab-router iptables -t nat -L POSTROUTING -n -v
  printf '\nRuntime files: %s\n' "$STATE"
}
renew() {
  require_running
  local choice=${1:-all} mode=${2:-renew} client pid
  case "$choice" in a|b|all) ;; *) fail 'renew expects a, b, or all' ;; esac
  for client in a b; do
    [[ $choice == all || $choice == "$client" ]] || continue
    pid=$(cat "$STATE/udhcpc-$client.pid")
    ip netns pids "nlab-$client" | grep -Fxq "$pid" || fail "DHCP client $client is not running. Run down, then up."
    if [[ $mode == reacquire ]]; then
      kill -USR2 "$pid"
      sleep 0.2
    fi
    kill -USR1 "$pid"
    echo "Requested DHCP $mode for client $client. See $STATE/client-$client.log"
  done
}
usage() {
  cat <<'EOF'
Usage: sudo bash lab.sh COMMAND
  up                       Create the lab and obtain DHCP leases
  check                    Verify leases, routing, DNS, and source NAT
  status                   Show addresses, routes, leases, and NAT rules
  renew [a|b|all]           Ask a running client to renew its DHCP lease
  reacquire [a|b|all]       Release leases, then restart DHCP discovery
  exec NAME COMMAND ...    Run in a, b, router, services, or outside
  down                     Remove lab namespaces/processes/runtime files
  help                     Show this help
EOF
}

command=${1:-help}
[[ $# -eq 0 ]] || shift
case "$command" in help|-h|--help) usage; exit 0 ;; esac
require_root
command -v ip >/dev/null || fail 'iproute2 is required.'
# Serialize lifecycle changes. Background services explicitly close FD 9.
if [[ $command == up || $command == down ]]; then
  exec 9>/run/lock/matthew-network-lab.lock
  flock -n 9 || fail 'Another lab setup/cleanup is running.'
fi
case "$command" in
  up) up ;;
  down) down ;;
  status) status ;;
  check) require_running; bash "$ROOT/scripts/check.sh" ;;
  renew) renew "${1:-all}" ;;
  reacquire) renew "${1:-all}" reacquire ;;
  exec)
    require_running
    [[ $# -ge 2 ]] || fail 'Usage: sudo bash lab.sh exec NAME COMMAND [ARG ...]'
    namespace=$(resolve_ns "$1")
    shift
    exec ip netns exec "$namespace" "$@"
    ;;
  *) usage; exit 1 ;;
esac
