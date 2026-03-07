# Tailscale App Connector DNS Gateway

A Tailscale App Connector that actually works as a domain-based router.

## The Problem

Tailscale markets App Connectors as domain-based routing — configure a domain, and traffic to it exits through your connector node. In practice, the implementation is an IP-based router with a DNS discovery layer on top: the connector watches DNS responses for your configured domains, collects the IPs that come back, and routes those IPs through itself.

This breaks in the real world because **CDN and SaaS IPs are shared**. When `your-app.example.com` resolves to `104.x.x.x`, that same IP is serving thousands of other customers on the same CDN. Tailscale has no way to route `your-app.example.com` through the connector without also capturing unintended traffic to that shared IP — or Tailscale may skip it entirely because the IP is considered "publicly reachable." The same problem applies to any large network that doesn't assign dedicated IPs per domain.

The abstraction leaks. What you get is either over-routing (catching unintended traffic on shared IPs) or under-routing (missing traffic when IPs rotate before the connector re-observes DNS).

## How This Fixes It

This project implements what App Connector claims to be at a conceptual level: a true domain-based router.

It pairs three containers in a shared network namespace:

- **`appc-gateway`** runs [Xray](https://github.com/XTLS/Xray-core) as the DNS and traffic gateway. Every domain resolved through it gets assigned a unique virtual IP from a private pool you own (default: `10.250.0.0/16`). The gateway maintains the domain-to-virtual-IP mapping, and when traffic arrives for a virtual IP it looks up the original domain and opens a real connection to the actual destination.

- **`appc-dns`** runs [dnsproxy](https://github.com/AdguardTeam/dnsproxy) as a DNS forwarder sidecar. Gateway forwards all non-FakeDNS queries to it on `127.0.0.1:5335`. dnsproxy resolves them against the configured upstreams (`DNS_UPSTREAM`) using its own bootstrap DNS — breaking the circular dependency that would otherwise occur if Gateway tried to resolve upstream hostnames through itself.

- **`appc-ts`** runs Tailscale as an App Connector in the same network namespace. It advertises the entire virtual IP CIDR as a route to your tailnet.

Traffic flow:
1. A tailnet client resolves `example.com`. Tailscale delivers the DNS query to the connector node via the peer API.
2. The connector node queries the gateway for DNS. Gateway checks FakeDNS: if the domain has a mapping it returns the existing virtual IP; otherwise it assigns a new one (e.g. `10.250.0.1`). Tailscale's own domains are forwarded to dnsproxy directly and resolved to real IPs.
3. The client connects to `10.250.0.1`. The connector node advertises the entire virtual IP range as a subnet route, so Tailscale forwards the traffic through it.
4. The gateway receives the packet on its TUN interface, maps the virtual IP back to `example.com`, connects to the real destination, and proxies the traffic.

Because every domain gets its own unique virtual IP that belongs to nobody else, routing decisions are genuinely per-domain. The IP routing substrate is used as a transport mechanism, not as the routing logic itself.

## Prerequisites

- Docker Engine 27+ with Compose
- A Tailscale account with App Connectors enabled
- A way to authenticate: an auth key, OAuth credentials, or an interactive login (see `.env.example`)

## Quick Start

```sh
git clone https://github.com/quiniapiezoelectricity/ts-appc-dns-gateway.git
cd ts-appc-dns-gateway
cp .env.example .env
# edit .env with at least TS_AUTHKEY or OAuth credentials
docker compose up -d
```

Watch the Tailscale container logs for an authentication URL:

```sh
docker logs appc-ts
```

Open the URL in a browser to authorise the node. Once authenticated, complete the Tailscale ACL setup below.

For non-interactive deployments (CI, unattended servers), set `TS_AUTHKEY` or OAuth credentials in a `.env` file instead — see `.env.example` for all options.

For production deployments, pin container images to immutable tags or digests in `.env` (`CONFIG_IMAGE`, `GATEWAY_IMAGE`, `DNS_IMAGE`, `TS_IMAGE`) before rollout.

## Tailscale ACL Setup

### 1. Tag the node

Assign a tag to the auth key used for `TS_AUTHKEY` so the connector can be referenced in policy:

```json
"tagOwners": {
  "tag:appc": ["autogroup:admin"]
}
```

### 2. Auto-approve the route

Without auto-approval, the advertised virtual IP subnet sits pending in the admin console. Add an `autoApprovers` entry so the route is accepted automatically when the connector comes up:

```json
"autoApprovers": {
  "routes": {
    "10.250.0.0/16": ["tag:appc"]
  }
}
```

The range here can be a supernet covering multiple connectors (e.g. `10.248.0.0/13`) if you're running more than one gateway and want to avoid updating the ACL for each.

### 3. Grant DNS access

Clients need to be able to send DNS queries to the connector node. Without this, the peer API call for DNS resolution will be blocked:

```json
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["tag:appc"],
    "ip": ["tcp:53", "udp:53"]
  }
]
```

### 4. Grant traffic via the connector

This tells Tailscale to route traffic destined for the virtual IP pool through the connector node. The `dst` must be the virtual IP CIDR explicitly — `autogroup:internet` only covers public IPs, and the virtual IP pool is a private range that falls entirely outside it:

```json
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["10.250.0.0/16"],
    "via": ["tag:appc"]
  }
]
```

Same as above, `dst` can be a supernet if you're running multiple gateways. Update it to match your `PRIVATEIP_CIDR` if using exact ranges.

For dual-stack setups, add an entry for each CIDR (or a supernet for each address family) in both `autoApprovers` and the via grant.

## Choosing a CIDR

**Every gateway on the same tailnet must have a unique, non-overlapping `PRIVATEIP_CIDR`.** Each gateway maintains its own independent virtual IP mapping table. If two gateways share the same CIDR, Tailscale will route connections to whichever gateway wins the subnet route — which may not be the one that answered the DNS query. That gateway has no record of the virtual IP and the connection silently fails. This is the kind of breakage that produces no useful error message.

Each resolved domain occupies one address in the pool for as long as the mapping is active. Wildcard domains and subdomains each count separately.

### IPv4

A `/20` (4095 addresses) is the practical minimum — `/24` fills up quickly with wildcard usage. The default `/16` (65535 addresses) is a safe starting point. If any device on your LAN or tailnet already uses part of the CIDR, traffic to those real addresses gets silently captured by the gateway instead.

| Range | Avoid because |
|---|---|
| `192.168.0.0/16` | Home routers, most consumer LAN defaults |
| `10.0.0.0/8` | Corporate networks, VMs, containers |
| `172.16.0.0/12` | Docker default bridge networks, some corporate nets |
| `100.64.0.0/10` | Tailscale itself |

The default `10.250.0.0/16` is chosen to avoid common allocations, but verify against your own LAN and tailnet subnet routes before deploying.

### IPv6

Pick a **`/112` out of `2001:db8::/32`** (e.g. `2001:0db8:3333:4444:5555:6666:7777::/112`). The gateway caps pool size at 65535 regardless of CIDR, so a `/112` (65536 addresses) is the exact fit with no waste. The `2001:db8::/32` range is reserved exclusively for documentation and examples by [RFC 3849](https://datatracker.ietf.org/doc/html/rfc3849) — never routed on the real internet, cannot conflict with real addresses, and falls under Global Unicast so Chrome's [Private Network Access](https://developer.chrome.com/blog/private-network-access-update) restrictions do not apply.

```env
PRIVATEIP_CIDR=10.250.0.0/16,2001:0db8:3333:4444:5555:6666:7777::/112
```

The uniqueness requirement is the same as IPv4 — pick a different `/112` for each gateway on the same tailnet.

| Range | Avoid because |
|---|---|
| `fc00::/7` (includes all `fd00::/8`) | ULA — Chrome v141+ blocks connections and shows a permission popup |
| `fe80::/10` | Link-local — not routable |
| `fd7a:115c:a1e0::/48` | Tailscale's own address range |
| Any range in use on your LAN or tailnet | Silent capture problem, same as IPv4 |

## Configuration

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | — | Tailscale auth key. One of `TS_AUTHKEY`, OAuth credentials, or interactive auth (see `.env.example`) is required. |
| `TS_CLIENT_ID` | — | OAuth client ID. Alternative to `TS_AUTHKEY`. |
| `TS_CLIENT_SECRET` | — | OAuth client secret. Alternative to `TS_AUTHKEY`. |
| `TS_HOSTNAME` | — | Hostname for this node as it appears in the tailnet. |
| `CONFIG_IMAGE` | `alpine:3.22` | Image used by the config renderer sidecar. Pin this for reproducible builds. |
| `GATEWAY_IMAGE` | `teddysun/xray:latest` | Gateway image. For production, replace `latest` with a fixed tag or digest. |
| `DNS_IMAGE` | `adguard/dnsproxy:latest` | DNS sidecar image. For production, replace `latest` with a fixed tag or digest. |
| `TS_IMAGE` | `tailscale/tailscale:stable` | Tailscale image. `stable` is safer than `latest`; pin to a fixed tag/digest for fully reproducible rollouts. |
| `PRIVATEIP_CIDR` | `10.250.0.0/16` | Virtual IP pool CIDR(s). Must not overlap with real routes in your tailnet. Comma-separate multiple CIDRs for dual-stack or multi-pool setups — strategy (`UseIPv4` / `UseIPv6` / `UseIP`) is auto-detected from the address families present. |
| `DNS_UPSTREAM` | Cloudflare + Google DoH | Upstream DNS resolvers passed to the DNS sidecar, comma-separated. Accepts plain IPs (UDP/53), `udp://`, `tcp://` (plain DNS over TCP), `tls://` (DoT), `https://` (DoH), `h3://` (DoH over HTTP/3), `quic://` (DoQ), or `sdns://` (DNSCrypt stamps). Hostname-based DoH works — the DNS sidecar resolves server hostnames via `DNS_BOOTSTRAP`, independent of the gateway's DNS. |
| `DNS_BOOTSTRAP` | Cloudflare + Google (IPv4 + IPv6) | Plain UDP resolvers (`ip:port`) used by the DNS sidecar to resolve upstream hostnames (e.g. the DoH server address). Bypasses the gateway's DNS entirely. Default covers two operators across both address families — override if any are blocked in your network. Not used when `DNS_UPSTREAM` contains only plain IPs. |
| `DNS_CUSTOM` | — | If set to any non-empty value and `./config/dns.yaml` already exists, the config renderer leaves it untouched. Use this to persist hand-edited DNS sidecar settings across restarts. If the file is missing it is still generated from `DNS_UPSTREAM` as a starting point. |
| `GATEWAY_CUSTOM` | — | Same preserve-existing behaviour for `./config/gateway.json` (the rendered Gateway config). If set and the file exists, the renderer skips the `jq` render step. If the file is missing it is still rendered from the template. |
| `DOMAIN_STRATEGY` | `UseIPv4` | Outbound domain resolution strategy for the gateway. The default matches the default IPv4-only pool — change this alongside `PRIVATEIP_CIDR`. The pool constrains what this can do; see the address families table. Accepts: `UseIP`, `UseIPv4`, `UseIPv6`, `UseIPv4v6`, `UseIPv6v4`, `ForceIP`, `ForceIPv4`, `ForceIPv6`, `ForceIPv4v6`, `ForceIPv6v4`. (`AsIs` is rejected — the container DNS points to the gateway itself, causing a routing loop.) |
| `LOGLEVEL` | `warning` | Log verbosity for the gateway and DNS sidecar. Gateway accepts `debug`, `info`, `warning`, `error`, and `none` — `info` logs every connection and DNS lookup. The DNS sidecar has no intermediate levels: only `debug` enables verbose output; all other values leave it quiet. For Tailscale verbosity, use `TS_TAILSCALED_EXTRA_ARGS=--verbose=1`. |
| `TUN_IF` | `gateway0` | Name of the TUN interface created by the gateway. |
| `GATEWAY_VARIANT` | `default` | Variant directory to mount. Use `default` or create your own for custom configs. |
| `TS_TAILSCALED_EXTRA_ARGS` | — | Extra arguments passed directly to `tailscaled`. |
| `TS_ENABLE_HEALTH_CHECK` | `false` | Expose an unauthenticated `/healthz` endpoint for container health checks. |
| `TS_ENABLE_METRICS` | `false` | Expose an unauthenticated `/metrics` endpoint for Prometheus scraping. |

The `config/` directory holds the rendered gateway config (`gateway.json`) and the generated DNS sidecar config (`dns.yaml`) at runtime and is gitignored. The `state/` directory holds Tailscale state and is also gitignored — preserve it across restarts to avoid re-authentication.

## Operational hardening defaults

- Containers run with `no-new-privileges`.
- The runtime services (`appc-gateway`, `appc-dns`, `appc-ts`) use `init: true` for cleaner signal handling.
- `appc-dns` and `appc-gateway` mount rendered config as read-only.
- Startup health checks gate service ordering (`appc-config` -> `appc-gateway` -> `appc-dns`/`appc-ts`).
- Config rendering is strict and fails fast on invalid `LOGLEVEL`, invalid `DOMAIN_STRATEGY`, malformed CIDR lists, or empty DNS list entries.

## Address families

Out of the box the stack is **IPv4-only**: the default `PRIVATEIP_CIDR` is an IPv4 range, the gateway only assigns IPv4 virtual IPs, and outbound connections to real destinations are IPv4.

There are two IPv6 planes:

**IPv6 virtual pool** — controlled by `PRIVATEIP_CIDR`. Adding an IPv6 CIDR (e.g. `2001:0db8::/112`) causes the gateway to assign IPv6 virtual IPs and return AAAA records to clients alongside IPv4. This lives on the TUN interface — no dependency on Docker networking or host IPv6 setup.

**IPv6 egress** — whether the gateway connects to real destinations over IPv6. This uses the container's network interface and requires the host to have IPv6 internet connectivity. The compose file already has `enable_ipv6: true`; Docker Engine 27+ (the minimum requirement) allocates an IPv6 subnet automatically, with no daemon configuration needed.

These two planes are coupled: the address families in `PRIVATEIP_CIDR` determine what the gateway's DNS resolves for outbound destination lookups. `DOMAIN_STRATEGY` can only further restrict egress within what the pool allows — it cannot expand it.

| `PRIVATEIP_CIDR` | Host network | `DOMAIN_STRATEGY` | Gateway egress |
|---|---|---|---|
| IPv4 only *(default)* | any | any | IPv4 only — host IPv6 capability irrelevant |
| IPv6 only | IPv4 only | any | ✗ fails — pool constrains DNS to IPv6, host has no IPv6 route |
| IPv6 only | dual-stack | any | IPv6 only |
| Dual-stack | dual-stack | `UseIPv4` *(default)* | IPv4 only |
| Dual-stack | dual-stack | `UseIP` | Both |
| Dual-stack | IPv4 only | `UseIPv4` *(default)* | IPv4 only |
| Dual-stack | IPv4 only | `UseIP` | △ intermittent — random IPv6 attempts fail fast |

## Variants

The `default` variant is the only built-in option. Set `GATEWAY_VARIANT=default` or omit the variable entirely. To use a custom config, create a directory alongside `default/` containing `entrypoint.sh`, `render.sh`, and `gateway.template.json`, then set `GATEWAY_VARIANT` to its name.
