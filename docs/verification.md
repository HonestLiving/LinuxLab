# Verification record

Verified on October 8, 2026 in the local Ubuntu 24.04 WSL2 distribution.

## Executed checks

`sudo bash lab.sh check` completed with **23 PASS, 0 FAIL**. It checks:

- All five namespaces exist.
- Both clients have an address in their DHCP pool, a /24 mask, and the correct default gateway.
- Each client address and MAC matches a current lease in the DHCP server's lease file.
- Both clients can reach each other and the services subnet.
- Both clients can explicitly resolve `outside.lab` through `10.10.30.2`.
- Both clients receive HTTP 200 from the outside server, which reports their translated source as `198.18.0.1`.
- The outside namespace has neither a default route nor routes to the internal subnets.

Observed leases on this run: client A `10.10.10.103/24`; client B `10.10.20.104/24`. These are observations, not hardcoded client addresses.

## Lifecycle and failure tests

`sudo bash tests/integration.sh` exited successfully after verifying:

1. Calling `up` twice preserves the running lab.
2. Renewing both DHCP leases preserves HTTP connectivity.
3. Reacquiring both leases produces captured DHCP relay packets with `Gateway-IP 10.10.10.1` and `Gateway-IP 10.10.20.1`.
4. Disabling forwarding inside the router makes HTTP fail. Re-enabling it restores access.
5. Removing the router's MASQUERADE rule makes new HTTP connections fail. Restoring the rule restores access.
6. The full 23-check suite passes again after these exercises.
7. Teardown removes all five namespaces, their service processes, and lab runtime state. Repeating teardown is harmless.
8. Host IPv4 forwarding, firewall rules, and interface names match their pre-test values.

Shell syntax checks and Python compilation also passed. The first failed DHCP setup exercised automatic partial-setup cleanup before the client configuration was corrected.

## Fixes found during execution

- The initial DHCP client settings did not reliably receive offers/acknowledgments. The working version requests broadcast replies with `udhcpc -B` and allows a longer retry interval. Fresh discovery through both relay interfaces was then verified with packet capture.
- BusyBox `nslookup` asks for both IPv4 and IPv6 records. An address-only DNS rule answered IPv4 but returned an error for IPv6. Using a local `host-record` gives a known IPv4-only name and the combined lookup now succeeds.

## Scope

This validates a small IPv4 lab, not a production router or a throughput benchmark. The outside server is an isolated namespace, not the public Internet. Dependencies were installed in Ubuntu; no Windows network configuration was changed. The lab was left **stopped** after testing. A zero-length lifecycle lock file may remain under `/run/lock`; it holds no lock after the command exits.
