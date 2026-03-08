# Management Lab

The management topology in `topology.mgmt.yaml` is separate from the VXLAN/EVPN fabric and uses the shared management network `clab-mgmt`.

## Components

| Service | Function |
| --- | --- |
| `gnmic` | subscribes to EOS gNMI telemetry and exposes Prometheus-format metrics |
| `mimir` | metrics backend |
| `grafana` | dashboards and queries |
| `alloy` | syslog collector and metrics/log pipeline component |
| `loki` | log backend |
| `redis` | state backend for traffic-analysis tooling and related services |

## Telemetry Flow

The current telemetry flow is:

`EOS gNMI -> gnmic -> Prometheus-format endpoint -> downstream scrape/ingest path -> Grafana`

The most important operational point is that `gnmic` is the collector talking to the devices. If you are missing metrics, start by checking the subscription set in `configs/gnmic/gnmic-config.yml`.

## Logging Flow

The EOS devices send RFC5424 syslog toward Alloy using their management interfaces. Alloy then forwards logs into Loki for Grafana queries.

## What This Lab Focuses On

The management topology is useful, but it is secondary to the core purpose of the repository. The technical center of gravity here is still the VXLAN/EVPN fabric, not the observability stack.
