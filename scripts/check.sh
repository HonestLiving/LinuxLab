#!/usr/bin/env bash
# Inspect this lab and send test traffic. Never alter addresses, routes, or rules.
set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'ERROR: run this check as root (sudo bash lab.sh check).\n' >&2
    exit 2
fi

missing=0
for command in ip ping python3 busybox; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'ERROR: required command is missing: %s\n' "$command" >&2
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    exit 2
fi

exec python3 - <<'PY'
"""Read lab state, probe connectivity, and report every independent check."""
import ipaddress
import json
import re
import subprocess
import sys
import time
from pathlib import Path

STATE = Path("/run/matthew-network-lab")
CLIENTS = {
    "nlab-a": ("10.10.10.0/24", "10.10.10.1"),
    "nlab-b": ("10.10.20.0/24", "10.10.20.1"),
}
NAMESPACES = (*CLIENTS, "nlab-router", "nlab-services", "nlab-outside")
passed = 0
failed = 0
addresses = {}
macs = {}


def run(argv, namespace=None, timeout=8):
    if namespace:
        argv = ["ip", "netns", "exec", namespace, *argv]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip()
                  or f"command exited {result.returncode}")
        raise RuntimeError(detail)
    return result.stdout


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check(label, operation):
    global passed, failed
    try:
        detail = operation()
    except Exception as exc:
        failed += 1
        # Keep one readable line per result, even for a multiline tool error.
        detail = " ".join(str(exc).split())
        print(f"FAIL  {label}: {detail}", flush=True)
    else:
        passed += 1
        print(f"PASS  {label}" + (f": {detail}" if detail else ""), flush=True)


def namespace_exists(namespace):
    run(["true"], namespace)


def client_address(namespace):
    network = ipaddress.ip_network(CLIENTS[namespace][0])
    interfaces = json.loads(run(
        ["ip", "-j", "-4", "address", "show", "dev", "eth0"], namespace))
    require(len(interfaces) == 1, "expected one eth0 interface")
    entries = [entry for entry in interfaces[0].get("addr_info", [])
               if entry.get("family") == "inet"]
    require(len(entries) == 1, f"expected one IPv4 address on eth0, got {entries}")
    entry = entries[0]
    address = ipaddress.ip_address(entry["local"])
    require(address in network, f"{address} is outside {network}")
    require(entry["prefixlen"] == 24, f"expected /24, got /{entry['prefixlen']}")
    host = int(address) - int(network.network_address)
    require(100 <= host <= 150, f"{address} is outside the DHCP pool (.100-.150)")
    addresses[namespace] = str(address)
    link = json.loads(run(["ip", "-j", "link", "show", "dev", "eth0"], namespace))
    macs[namespace] = link[0]["address"].lower()
    return f"{address}/24 on eth0"


def client_default(namespace):
    expected = CLIENTS[namespace][1]
    routes = json.loads(run(["ip", "-j", "-4", "route", "show", "default"], namespace))
    require(len(routes) == 1, f"expected exactly one default route, got {routes}")
    require(routes[0].get("gateway") == expected and routes[0].get("dev") == "eth0",
            f"expected default via {expected} dev eth0, got {routes[0]}")
    return f"via {expected}"


def client_lease(namespace):
    require(namespace in addresses and namespace in macs,
            "cannot match a lease because the client address check failed")
    records = []
    for line in (STATE / "dnsmasq.leases").read_text().splitlines():
        fields = line.split()
        # dnsmasq DHCPv4 records: expiry, MAC, IPv4, hostname, client ID.
        if len(fields) >= 5 and fields[1].lower() == macs[namespace] and fields[2] == addresses[namespace]:
            records.append(fields)
    require(records, f"no DHCP lease matching {macs[namespace]} and {addresses[namespace]}")
    valid = any(int(record[0]) == 0 or int(record[0]) > time.time() for record in records)
    require(valid, "matching DHCP lease has expired")
    return f"server lease matches {addresses[namespace]} and client MAC"


def ping(namespace, destination):
    run(["ping", "-n", "-c", "2", "-W", "2", destination], namespace, timeout=7)
    return destination


def ping_client(source, target):
    require(target in addresses, f"{target} did not pass its address check")
    return ping(source, addresses[target])


def dns(namespace):
    # Explicitly query the lab server: never depend on the host's resolv.conf.
    output = run(["busybox", "nslookup", "outside.lab", "10.10.30.2"],
                 namespace, timeout=12)
    require(re.search(r"(?<![\d.])198\.18\.0\.2(?![\d.])", output),
            f"outside.lab did not resolve to 198.18.0.2: {' '.join(output.split())}")
    return "outside.lab -> 198.18.0.2 via 10.10.30.2"


HTTP_PROBE = '''
import http.client
import json
connection = http.client.HTTPConnection("198.18.0.2", 8080, timeout=4)
connection.request("GET", "/", headers={"Connection": "close"})
response = connection.getresponse()
if response.status != 200:
    raise RuntimeError("HTTP status " + str(response.status))
print(json.dumps(json.loads(response.read(65536))))
connection.close()
'''


def http_nat(namespace):
    # http.client ignores proxy environment variables; traffic stays in the lab.
    result = json.loads(run(["python3", "-c", HTTP_PROBE], namespace))
    require(isinstance(result, dict), f"expected an HTTP JSON object, got {result!r}")
    require(result.get("server") == "outside", f"unexpected server response: {result}")
    require(result.get("client_ip") == "198.18.0.1",
            f"outside saw {result.get('client_ip')!r}; expected router WAN 198.18.0.1")
    return "HTTP 200; outside observed translated source 198.18.0.1"


def outside_default():
    routes = json.loads(run(["ip", "-j", "-4", "route", "show", "default"], "nlab-outside"))
    require(not routes, f"outside must have no default route, got {routes}")


def outside_no_internal_route(destination):
    # First validate that the namespace/interface really exists so a broken
    # namespace cannot turn a failed route command into a false PASS.
    run(["ip", "-j", "link", "show", "dev", "eth0"], "nlab-outside")
    result = subprocess.run(
        ["ip", "netns", "exec", "nlab-outside", "ip", "-4", "route", "get", destination],
        capture_output=True, text=True, timeout=8)
    require(result.returncode != 0,
            f"unexpected route to {destination}: {result.stdout.strip()}")
    require("unreachable" in result.stderr.lower(),
            f"route lookup failed for another reason: {result.stderr.strip()}")
    return f"no route to {destination} (NAT is needed for return traffic)"


print("Linux network lab verification (read-only state checks and test traffic)\n", flush=True)
for namespace in NAMESPACES:
    check(f"namespace {namespace} exists", lambda ns=namespace: namespace_exists(ns))

for namespace in CLIENTS:
    check(f"{namespace} DHCP-range address", lambda ns=namespace: client_address(ns))
    check(f"{namespace} default route", lambda ns=namespace: client_default(ns))
    check(f"{namespace} actual server DHCP lease", lambda ns=namespace: client_lease(ns))

check("client A -> client B routing", lambda: ping_client("nlab-a", "nlab-b"))
check("client B -> client A routing", lambda: ping_client("nlab-b", "nlab-a"))
for namespace in CLIENTS:
    check(f"{namespace} -> services", lambda ns=namespace: ping(ns, "10.10.30.2"))
    check(f"{namespace} lab DNS", lambda ns=namespace: dns(ns))
    check(f"{namespace} HTTP and source NAT", lambda ns=namespace: http_nat(ns))

check("outside has no default route", outside_default)
for namespace, fallback in (("nlab-a", "10.10.10.100"), ("nlab-b", "10.10.20.100")):
    target = addresses.get(namespace, fallback)
    check(f"outside has no route to {namespace}", lambda dst=target: outside_no_internal_route(dst))
check("outside has no route to services", lambda: outside_no_internal_route("10.10.30.2"))

print(f"\nResults: {passed} PASS, {failed} FAIL ({passed + failed} checks)", flush=True)
if failed:
    print("Inspect lab status and logs in /run/matthew-network-lab/.", flush=True)
sys.exit(1 if failed else 0)
PY
