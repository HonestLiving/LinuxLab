# Linux networking lab: DHCP, DNS, routing, and NAT

Build a small network on your Ubuntu 24.04 WSL2 machine, then watch packets move through it. The lab uses Linux network namespaces, virtual Ethernet links, `dnsmasq`, and an HTTP server. You configure and inspect an existing Linux network stack; this project does not implement TCP/IP or DPDK.

## What you get

```text
 Client A                 Router                  Simulated outside
 nlab-a                  nlab-router              nlab-outside
 DHCP 10.10.10.x ---- 10.10.10.1
                             |
 Client B                    +--- 198.18.0.1 ---- 198.18.0.2:8080
 nlab-b                      |       NAT           outside.lab
 DHCP 10.10.20.x ---- 10.10.20.1
                             |
                         10.10.30.1
                             |
                         10.10.30.2
                         nlab-services
                         DHCP server + DNS
```

Each connection is a virtual link. The DHCP server is on a different subnet from both clients, so the router runs a DHCP relay. The HTTP server reports the source address it sees, making the effect of NAT visible.

| Component | Address or range | Job |
| --- | --- | --- |
| Client A | DHCP: `10.10.10.100–150/24` | First client LAN |
| Client B | DHCP: `10.10.20.100–150/24` | Second client LAN |
| Router | `10.10.10.1`, `10.10.20.1`, `10.10.30.1`, `198.18.0.1` | DHCP relay, routing, and outbound NAT |
| Services | `10.10.30.2/24` | Central DHCP and DNS |
| Outside | `198.18.0.2/24`, HTTP port `8080` | Test destination, named `outside.lab` |

The outside network is **a local simulation**. It is not the Internet. All links, forwarding, and NAT live inside the lab namespaces. Dependency installation uses your normal Ubuntu package repositories; the running lab does not require Internet access or changes to the host firewall.

## Quick start in Ubuntu / WSL2

Open your **Ubuntu terminal** and run:

```bash
cd '/mnt/c/Users/matth/Documents/Linux Lab'
sudo bash scripts/install-deps.sh
sudo bash lab.sh up
sudo bash lab.sh check
sudo bash lab.sh status
```

Run commands with `bash` as shown; executable permission bits on the Windows-mounted folder are not required. Administrative privileges are needed to create network namespaces and virtual links.

Try a request from each client:

```bash
sudo bash lab.sh exec a curl --noproxy '*' --fail --max-time 5 http://198.18.0.2:8080/
sudo bash lab.sh exec b curl --noproxy '*' --fail --max-time 5 http://198.18.0.2:8080/
```

Look for `client_ip` in the response. It should be `198.18.0.1`, the router's outside address, rather than the client's `10.10.x.x` address. That is the NAT demonstration.

This version was executed on Ubuntu 24.04 under WSL2: **23 checks passed**, along with the failure/recovery and cleanup scenarios. See the [verification record](docs/verification.md). Run `check` again after starting your own session.

## Commands

| Command | Purpose |
| --- | --- |
| `sudo bash lab.sh up` | Create the topology and start its services |
| `sudo bash lab.sh status` | Inspect the current lab state |
| `sudo bash lab.sh check` | Run the lab's verification checks |
| `sudo bash lab.sh renew a` | Request a normal renewal for client A |
| `sudo bash lab.sh renew b` | Request a normal renewal for client B |
| `sudo bash lab.sh renew all` | Request normal renewals for both clients |
| `sudo bash lab.sh reacquire a` | Release A's lease and start a fresh DHCP discovery |
| `sudo bash lab.sh reacquire b` | Release B's lease and start a fresh DHCP discovery |
| `sudo bash lab.sh reacquire all` | Release both leases and restart discovery |
| `sudo bash lab.sh exec a COMMAND ...` | Run a command inside client A |
| `sudo bash lab.sh down` | Stop the lab and remove its topology |

The `exec` targets are `a`, `b`, `router`, `services`, and `outside`. For example:

```bash
sudo bash lab.sh exec a ip -4 address
sudo bash lab.sh exec a ip -4 route
sudo bash lab.sh exec router ip -4 route
sudo bash lab.sh exec a busybox nslookup outside.lab 10.10.30.2
sudo bash lab.sh exec router iptables -t nat -S
```

Lab runtime state lives in `/run/matthew-network-lab`. Namespace names start with `nlab-`. These are network compartments within the same Linux system, not full virtual machines.

DHCP supplies the lab DNS server address, but the client hook leaves resolver files unchanged. Query lab DNS explicitly with the `nslookup` command above and use the numeric address for HTTP requests. This keeps the host's DNS configuration untouched.

Use `reacquire` for the DHCP capture exercise: it sends RELEASE, then restarts discovery so you can observe the relay and the full Discover/Offer/Request/Acknowledge exchange. A normal `renew` can send a unicast request directly to the server, bypassing the relay with `giaddr` equal to zero. Reacquisition briefly removes the client's address; allow a few seconds, then run `check` before continuing.

Implementation detail: the persistent `udhcpc` clients renew their one-hour leases automatically. They use `-B` to request broadcast DHCP replies during acquisition, allowing replies to arrive before the client owns its offered address. `reacquire` signals the running client with `USR2` to release, followed by `USR1` to restart discovery.

## If something fails

Start with `sudo bash lab.sh status` and the specific failure from `sudo bash lab.sh check`.

- **Client has no `10.10.x.x` address:** run `sudo bash lab.sh reacquire all`, allow a few seconds, then run `sudo bash lab.sh check` and inspect client addresses again. Capture UDP ports 67 and 68 inside the router to identify where the DHCP exchange stops.
- **Name lookup fails:** try `sudo bash lab.sh exec a busybox nslookup outside.lab 10.10.30.2`. The expected answer is `198.18.0.2`. The server argument is required for this lab because its DHCP hook does not change resolver files. An HTTP request to `http://198.18.0.2:8080/` tests connectivity independently of DNS.
- **DNS works but HTTP fails:** inspect the router's routes and `sudo bash lab.sh exec router sysctl net.ipv4.ip_forward`. Forwarding should be `1`. Check the HTTP server directly with `sudo bash lab.sh exec outside curl --noproxy '*' --fail --max-time 5 http://198.18.0.2:8080/`.
- **A required command is missing:** rerun the dependency installer and inspect any package installation errors.
- **Namespace creation reports “Operation not permitted”:** confirm you are in Ubuntu on WSL2 and used `sudo`. From PowerShell, `wsl --list --verbose` shows each distribution's WSL version.
- **The lab was interrupted or you want a fresh start:** run `sudo bash lab.sh down`, then `sudo bash lab.sh up` and `sudo bash lab.sh check`.

## Cleanup

When you finish:

```bash
sudo bash lab.sh down
```

Use the teardown command before closing the exercise so its background services and namespaces do not remain running. Teardown stops all processes inside `nlab-a`, `nlab-b`, `nlab-router`, `nlab-services`, and `nlab-outside`, including shells or packet captures you launched there with `exec`. Installed Ubuntu packages remain available for future labs.

## Next step

Trace DHCP, explain a route lookup, prove NAT with a capture, and deliberately break forwarding inside the router. Save your observations and a successful check output as evidence of what you ran.

For the repeatable integration test, stop the lab and run:

```bash
sudo bash lab.sh down
sudo bash tests/integration.sh
```

This test creates the lab, checks it, exercises DHCP and connectivity failures, then removes it. It refuses to start over an existing lab. It also checks that the host's forwarding setting, firewall rules, and interface names are unchanged.

References: [Linux network namespaces](https://man7.org/linux/man-pages/man8/ip-netns.8.html) and the [dnsmasq manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html).
