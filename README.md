# Synapse

A fast, censorship-resistant reverse tunnel for Linux servers. One static binary, an
interactive menu, and a single install command.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/D-7J/synapse/main/install.sh | sudo sh
```

Detects your CPU architecture, verifies the release checksum, installs
`/usr/local/bin/synapse`, and opens the menu. Re-running it upgrades in place and restarts
any running tunnel.

```sh
synapse menu      # configure, manage, check status, or remove a tunnel
synapse -v        # version
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/D-7J/synapse/main/install.sh | sudo sh -s uninstall
```

Stops and deletes every `synapse-*` service, the binary, and `/etc/synapse`. To remove a
single tunnel instead of everything, use **`synapse menu`**.

## Supported systems

One static binary **per CPU architecture**, not per distribution — it is built CGO-free, so
there is no libc to mismatch and the same artefact runs everywhere:

| | |
|---|---|
| **Distributions** | Ubuntu · Debian · CentOS · AlmaLinux · Rocky · Fedora · Arch · openSUSE · Alpine — any modern Linux |
| **Architectures** | `amd64` (x86-64) · `arm64` (aarch64) |
| **Kernel** | 3.2 or newer; glibc and musl both fine |

Optional host tools, needed only for specific features (a plain tcp/ws/tls tunnel needs
none of them):

| tool | needed for |
|---|---|
| `iptables` (or `iptables-nft`) | the RST-drop firewall option and the tun-mode forwarder |
| `iproute2` (`ip`) | `tun` transport |
| systemd | running tunnels as a service (without it the menu still writes the config and shows you how to start it) |

Tool locations are resolved at runtime, so it works whether your distro keeps `iptables`
in `/usr/sbin` (Debian, RHEL) or `/usr/bin` (Arch).

## Transports

| transport | what it is |
|---|---|
| `tcp` / `tcpmux` / `xtcpmux` | plain and multiplexed TCP — highest throughput |
| `ws` / `wss` / `wsmux` / `wssmux` / `xwsmux` | WebSocket, optionally over TLS and behind a CDN |
| `anytls` | uTLS browser-ClientHello mimicry with a real SNI |
| `httpmimic` (alias `xhttp`) | the stream carried inside a chunked HTTP request/response |
| `tun` + `ipx` | raw IP-protocol carrier (icmp/ipip/udp/tcp/gre) with AEAD encryption |

Extra anti-censorship layers, per tunnel: **`[obfuscation]`** (adaptive padding + timing
jitter, off automatically under load) and **`[fragment]`** (splits the TLS ClientHello so
the SNI never lands in one packet).
