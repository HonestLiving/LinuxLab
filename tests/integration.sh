#!/usr/bin/env bash
# Requires installed dependencies and a stopped lab. Leaves the lab stopped.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash tests/integration.sh' >&2; exit 1; }
[[ ! -e /run/matthew-network-lab ]] || { echo 'Stop the existing lab first: sudo bash lab.sh down' >&2; exit 1; }
for ns in nlab-a nlab-b nlab-router nlab-services nlab-outside; do
  if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
    echo "Existing namespace $ns; test will not overwrite it." >&2
    exit 1
  fi
done
scratch=$(mktemp -d /run/matthew-lab-test.XXXXXX)
host_forward=$(cat /proc/sys/net/ipv4/ip_forward)
iptables-save | sed '/^#/d' >"$scratch/firewall-before"
ip -j link show | python3 -c 'import json,sys; print(sorted(x["ifname"] for x in json.load(sys.stdin)))' >"$scratch/links-before"
capture_pid=''
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $capture_pid ]]; then kill "$capture_pid" 2>/dev/null || true; fi
  bash "$ROOT/lab.sh" down || true
  # mktemp always creates this verified directory under /run.
  if [[ $scratch == /run/matthew-lab-test.* && -d $scratch && ! -L $scratch ]]; then rm -rf -- "$scratch"; fi
  exit "$rc"
}
trap cleanup EXIT
lab() { bash "$ROOT/lab.sh" "$@"; }
http() { lab exec a curl --noproxy '*' --silent --show-error --fail --max-time 3 http://198.18.0.2:8080/; }
wait_dhcp() {
  local attempt
  for attempt in {1..100}; do
    if ip -4 -o -n nlab-a addr show dev eth0 | grep -Fq 'inet 10.10.10.' &&
       ip -4 -o -n nlab-b addr show dev eth0 | grep -Fq 'inet 10.10.20.'; then return; fi
    sleep 0.1
  done
  echo 'DHCP addresses did not return.' >&2
  return 1
}

lab up
lab check
lab up
echo 'PASS  repeated up is harmless'
lab renew all
sleep 0.5
wait_dhcp
http
echo 'PASS  DHCP renewal preserves connectivity'

ip netns exec nlab-router tcpdump -n -l -vv -i services 'udp port 67 or udp port 68' >"$scratch/dhcp-capture" 2>&1 &
capture_pid=$!
sleep 0.3
lab reacquire all
wait_dhcp
sleep 0.3
kill -INT "$capture_pid"
wait "$capture_pid" || true
capture_pid=''
grep -q 'Gateway-IP 10.10.10.1' "$scratch/dhcp-capture"
grep -q 'Gateway-IP 10.10.20.1' "$scratch/dhcp-capture"
echo 'PASS  fresh DHCP discovery crosses relay with both gateway addresses'

lab exec router sysctl -qw net.ipv4.ip_forward=0
if http >"$scratch/forwarding-off" 2>&1; then
  echo 'FAIL  HTTP unexpectedly worked with router forwarding disabled' >&2
  exit 1
fi
lab exec router sysctl -qw net.ipv4.ip_forward=1
http
echo 'PASS  disabling router forwarding breaks HTTP; restoring it recovers'

lab exec router iptables -t nat -D POSTROUTING -s 10.10.0.0/16 -o wan -j MASQUERADE
# A new connection avoids testing an existing translated conntrack entry.
if http >"$scratch/nat-off" 2>&1; then
  echo 'FAIL  HTTP unexpectedly worked without NAT or a return route' >&2
  exit 1
fi
lab exec router iptables -t nat -A POSTROUTING -s 10.10.0.0/16 -o wan -j MASQUERADE
http
echo 'PASS  removing NAT breaks new HTTP flows; restoring it recovers'
lab check

mapfile -t service_pids < <(for ns in nlab-a nlab-b nlab-router nlab-services nlab-outside; do ip netns pids "$ns"; done)
lab down
lab down
for ns in nlab-a nlab-b nlab-router nlab-services nlab-outside; do
  if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then echo "FAIL  leftover $ns"; exit 1; fi
done
[[ ! -e /run/matthew-network-lab ]]
for pid in "${service_pids[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then echo "FAIL  leftover service PID $pid"; exit 1; fi
done
echo 'PASS  teardown removes namespaces, services, state; repeated down is harmless'
[[ $(cat /proc/sys/net/ipv4/ip_forward) == "$host_forward" ]]
iptables-save | sed '/^#/d' >"$scratch/firewall-after"
diff -u "$scratch/firewall-before" "$scratch/firewall-after"
ip -j link show | python3 -c 'import json,sys; print(sorted(x["ifname"] for x in json.load(sys.stdin)))' >"$scratch/links-after"
diff -u "$scratch/links-before" "$scratch/links-after"
echo 'PASS  host forwarding, firewall rules, and interface names unchanged'
echo 'PASS  integration scenarios complete; lab stopped'
