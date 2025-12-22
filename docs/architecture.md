# Architecture Overview

## Network Topology (conceptual)
```
            Internet (WAN)
                 |
           [ISP modem/ONT]
                 |
            WAN iface (eth0)
           +----------------+
           | Raspberry Pi    |
           |  - Host: routing, NAT, DHCP, firewall
           |  - Containers: Pi-hole, Suricata, ntopng, Telegraf, InfluxDB, Grafana
           +----------------+
            LAN iface (eth1)
                 |
         [Switch / Wi-Fi AP]
                 |
            Home clients
```

## Packet Flow (WAN → LAN)
1. Packet arrives on WAN (eth0), filtered by nftables input/prerouting chains.
2. NAT (masquerade) applied on egress to WAN.
3. Forwarding rules enforce LAN→WAN policy and optional IDS mirroring/tap.
4. Suricata observes traffic (passive by default; inline optional with NFQUEUE).
5. ntopng ingests mirrored/span traffic for flow visibility.
6. LAN clients receive DHCP from host, DNS from Pi-hole; Pi-hole forwards/blocks and logs to Influx via Telegraf exporter.
7. Metrics: Telegraf scrapes system stats + Pi-hole exporter → InfluxDB → Grafana dashboards.

## Host vs Containers
- Host: interface config, IP forwarding, NAT, firewall (nftables), DHCP server, time sync, SSH hardening.
- Containers: Pi-hole (DNS filter), Suricata (IDS/IPS), ntopng (flow), Telegraf (metrics + Pi-hole exporter), InfluxDB (TSDB), Grafana (dashboards).

## Suricata placement
- Passive: sniff LAN/WAN via AF_PACKET on interfaces or span port; minimal risk, no inline drops.
- Inline (optional): NFQUEUE on forward chain; higher CPU, can drop malicious flows; ensure fail-open strategy and backup console access.

## Metrics Flow
- Telegraf agents: system input plugins + Pi-hole exporter → outputs.influxdb_v2 → InfluxDB bucket.
- Grafana uses InfluxDB datasource; dashboards for system, Pi-hole, Suricata/ntopng (future), and traffic KPIs.

## Pi considerations
- Prefer 64-bit Raspberry Pi OS Lite, disable GUI packages.
- Use USB3 LAN adapter if onboard NIC is WAN (or vice versa) for balanced throughput.
- Avoid swap-heavy workloads; tune `vm.swappiness`, `net.core` buffers, and IRQ affinity per interfaces once hardware is known.
