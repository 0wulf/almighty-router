# Almighty Router (Raspberry Pi)

Production-minded Raspberry Pi router stack with host-managed routing/firewall/DHCP and containerized security + observability services (Pi-hole, Suricata, ntopng, Telegraf, InfluxDB, Grafana).

## What this repo provides
- Architecture reference for a Pi-based home gateway with IDS and traffic analytics.
- Idempotent bootstrap (`install.sh`) to prep Raspberry Pi OS Lite, enable routing/firewalling, install Docker, and deploy services.
- Docker Compose stack with hardened defaults and config templates for each service.
- Host-side networking guidance for WAN/LAN interfaces, NAT, firewall, and DHCP.

## Quick start (dev workstation)
1) Read `docs/architecture.md` to understand topology and packet flow.
2) Copy `example.env` to `.env` and adjust WAN/LAN interface names, subnets, and credentials.
3) Review `install.sh` and `docker-compose.yml` for your environment; adjust config under `config/` as needed.
4) On the Raspberry Pi (after flashing Raspberry Pi OS Lite), copy this repo and run `chmod +x install.sh && sudo ./install.sh`.

## Status
- Base scaffolding and configs are templated. Validate all interface names, subnets, and passwords before first boot on the Pi.

## Services
 Docker Compose stack with hardened defaults and config templates for each service (InfluxDB 1.8 + InfluxQL).
## Roadmap
 Add Grafana dashboards and Influx retention policies (InfluxQL).
