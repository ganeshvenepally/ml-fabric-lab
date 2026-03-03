# ML Fabric Lab Quick Use Guide

This guide explains how the lab works as a complete system and how to use it as a network engineer.

It assumes you already understand EVPN/VXLAN, BGP, Linux hosts, and basic containerlab operations, but want a practical explanation of the observability stack:

- `gnmic`
- `Alloy`
- `Grafana`
- `Loki`
- `Mimir`
- `Redis`
- `ntopng`

It is written against the current split-topology deployment:

- [topology.fabric.yaml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/topology.fabric.yaml)
- [topology.mgmt.yaml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/topology.mgmt.yaml)

The older combined file [ml-clab-topo.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/ml-clab-topo.yml) is useful as a reference, but the active deployment flow uses the split files above.

## 1. What This Lab Is

This is a two-part containerlab environment:

- A fabric lab that carries real forwarding and routing state
- A management lab that collects telemetry, metrics, and logs from that fabric

The fabric lab gives you:

- 2 spines
- 4 leafs
- EVPN/VXLAN control plane using BGP
- Linux endpoints for real traffic testing
- `ntopng` attached to `leaf1` for mirrored traffic visibility

The management lab gives you:

- `gnmic` for gNMI collection
- `Alloy` as the central collector/forwarder
- `Mimir` for metrics storage
- `Loki` for logs
- `Grafana` for dashboards and queries
- `Redis` as a backend for `ntopng`

The two labs share the same Docker management network (`clab-mgmt`), so the management containers can talk to the network devices over their management interfaces.

## 2. Why It Is Split Into Two Labs

The deployment is intentionally staged:

1. Deploy the fabric first
2. Wait for EVPN BGP to converge
3. Deploy the management stack

This keeps the management tools from starting too early and collecting partial or misleading startup noise.

Operationally, it also means:

- You can break and redeploy the management stack without tearing down the fabric
- You can troubleshoot the network separately from the observability tooling
- You can validate convergence first, then validate telemetry

The deployment script is [stage_deploy.sh](/Users/gunny/Projects/network/clabs/ml-fabric-lab/stage_deploy.sh).

## 3. End-to-End Data Flows

There are three main data flows in this lab.

### 3.1 Routing and Data Plane

- `host1` is attached to `leaf1`
- `host2` is attached to `leaf4`
- Both hosts live in VLAN 10 / VNI 10010
- The anycast gateway is `192.168.10.1`

The EVPN/VXLAN fabric carries:

- Underlay reachability over eBGP IPv4 unicast
- Overlay MAC/IP reachability over EVPN
- Encapsulated user traffic over VXLAN

This is the actual network under test.

### 3.2 Telemetry and Metrics

The metrics path is:

`cEOS -> gNMI -> gnmic -> Prometheus-format exporter -> Alloy scrape -> Mimir -> Grafana`

What that means in practice:

- The cEOS devices expose gNMI on their management VRF
- `gnmic` connects to them as a client
- `gnmic` subscribes to selected OpenConfig paths
- `gnmic` exposes those values as Prometheus metrics on port `9804`
- `Alloy` scrapes `gnmic:9804`
- `Alloy` remote-writes those metrics into `Mimir`
- `Grafana` queries `Mimir`

Important detail:

- In this current split topology, `Alloy` is the component that pushes metrics into `Mimir`
- `gnmic` does not write directly to `Mimir`

### 3.3 Syslog and Logs

The log path is:

`cEOS syslog -> Alloy -> Loki -> Grafana`

What that means in practice:

- The EOS nodes send syslog to `Alloy`
- `Alloy` listens on UDP/TCP `1514` (RFC5424) and UDP `1515` (RFC3164)
- `Alloy` relabels the incoming log metadata
- `Alloy` forwards the logs to `Loki`
- `Grafana` queries `Loki`

This lets you search logs from the same UI where you view metrics.

### 3.4 Traffic Visibility

The packet visibility path is:

`leaf1 SPAN source -> leaf1:Ethernet5 -> ntopng:eth1 -> ntopng UI`

What that means in practice:

- `leaf1` mirrors selected interfaces into a monitor session
- That mirrored traffic is sent directly to the `ntopng` container
- `ntopng` analyzes flows and traffic behavior
- `Redis` is used by `ntopng` as its state/cache store

This is not sampled telemetry. This is packet/flow visibility of real lab traffic.

## 4. What Each Observability Component Does

### 4.1 gNMI

gNMI is the protocol used to retrieve telemetry from the EOS devices.

In this lab:

- It runs over the management VRF of each cEOS node
- The device-side gNMI server is enabled in the EOS configs
- `gnmic` is the client that connects to those gNMI servers

Think of gNMI as the transport/API used to read structured operational state from the switches.

### 4.2 gnmic

`gnmic` is the telemetry collector.

In this lab it:

- Connects to the devices listed in [gnmic-config.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/gnmic/gnmic-config.yml)
- Authenticates with `admin/admin`
- Uses `json_ietf` encoding
- Subscribes to configured OpenConfig paths
- Exposes the collected values on `http://localhost:9804/metrics`

Today, the active config is focused on BGP:

- BGP neighbor state
- BGP neighbor counters
- BGP global prefix counters

So the first dashboards that populate reliably are BGP-focused dashboards and BGP-related panels.

If a dashboard expects interface, CPU, or memory metrics, those panels may be empty until you add those subscriptions to [gnmic-config.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/gnmic/gnmic-config.yml).

### 4.3 Alloy

`Alloy` is the central collector and router.

In this lab it does two jobs:

- Scrapes metrics from `gnmic`
- Receives syslog from the network devices

Then it forwards data onward:

- Metrics to `Mimir`
- Logs to `Loki`

This makes `Alloy` the glue layer between raw collection and storage.

From a network engineer perspective, treat `Alloy` as the equivalent of a message broker plus light processing stage:

- It receives
- It normalizes labels
- It forwards

Its active config is [config.alloy](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/alloy/config.alloy).

### 4.4 Mimir

`Mimir` is the metrics database.

In this lab it stores time-series metrics that originate from `gnmic`.

You can think of it as:

- The long-lived backend for numeric telemetry
- The place Grafana queries for metrics

Examples of data it stores:

- BGP neighbor transitions
- BGP session state
- Prefix counters

It is serving a Prometheus-compatible query endpoint to Grafana, which is why Grafana can use a Prometheus datasource even though the backend is `Mimir`.

### 4.5 Grafana

`Grafana` is the operator UI.

It is where you:

- Open dashboards
- Query metrics
- Query logs
- Correlate events visually

It has two provisioned datasources:

- A Prometheus-compatible datasource backed by `Mimir`
- A `Loki` datasource for logs

So Grafana is the place you should spend most of your time once the lab is running.

### 4.6 Loki

`Loki` is the log store.

It stores syslog messages sent from the EOS devices and forwarded by `Alloy`.

You use it when you want to answer questions like:

- Did a BGP neighbor flap?
- Did an interface go down?
- Did EOS emit any warnings during convergence?

Unlike metrics, logs are text events. `Loki` stores and indexes them efficiently enough for Grafana log search.

### 4.7 Redis

`Redis` in this lab is not used for routing or telemetry pipelines.

It exists to support `ntopng`.

For your purposes:

- `Redis` is an internal dependency of `ntopng`
- You usually do not interact with it directly unless you are troubleshooting `ntopng`

### 4.8 ntopng

`ntopng` is the traffic analysis UI.

It gives you:

- Top talkers
- Protocol breakdowns
- Host conversations
- Flow visibility

This complements the telemetry stack:

- `gnmic/Mimir/Grafana` tell you structured control-plane and operational state
- `ntopng` shows what traffic is actually moving

Use `ntopng` when you want traffic context, not just routing state.

## 5. Access Points

When the lab is running, these are the main services you use from your laptop:

- Grafana: `http://localhost:3000`
- gNMIc exporter: `http://localhost:9804/metrics`
- Mimir HTTP: `http://localhost:9009`
- Loki HTTP: `http://localhost:3100`
- Alloy UI/debug: `http://localhost:12345`
- ntopng: `http://localhost:3001`

Grafana credentials:

- Username: `admin`
- Password: `admin`

## 6. Quick Operator Workflow

If you want to use the lab efficiently, use it in this order.

### 6.1 Validate the Network First

Check that the fabric is healthy before looking at telemetry.

Examples:

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c 'show bgp evpn summary'
docker exec clab-arista-evpn-vxlan-fabric-spine1 Cli -c 'show bgp evpn summary'
docker exec clab-arista-evpn-vxlan-fabric-host1 ping -c 3 192.168.10.102
```

If the network is not converged, the telemetry will reflect the failure, but it will not fix it for you.

### 6.2 Confirm gNMI Collection

Check that `gnmic` is exporting metrics:

```bash
curl -s http://localhost:9804/metrics | head -40
```

If you see `gnmic_*` metrics, the collector is working.

Useful spot checks:

```bash
curl -s http://localhost:9804/metrics | rg 'session_state'
curl -s http://localhost:9804/metrics | rg 'established_transitions'
curl -s http://localhost:9804/metrics | rg 'source=\"leaf1\"'
```

### 6.3 Use Grafana for Graphical Visibility

Open Grafana and use one of the preloaded dashboards.

Start with:

- `Arista cEOS - Fabric Health`
- `Arista cEOS - Device Overview`
- `Arista cEOS – Engineer View`

If a panel is blank:

- Check the query behind the panel
- Compare it to the metrics currently exposed by `gnmic`
- If the metric family is missing, the subscription probably is not configured in `gnmic`

### 6.4 Use Grafana Explore for Metrics

In Grafana:

1. Open `Explore`
2. Select the `Prometheus` datasource
3. Run focused queries

Good starter queries:

```promql
gnmic_bgp_neighbors_network_instances_network_instance_protocols_protocol_bgp_neighbors_neighbor_state_established_transitions
```

```promql
gnmic_bgp_neighbors_network_instances_network_instance_protocols_protocol_bgp_neighbors_neighbor_state_session_state{source="leaf1"}
```

```promql
gnmic_bgp_global_network_instances_network_instance_protocols_protocol_bgp_global_state_total_prefixes
```

These are the fastest way to prove the telemetry pipeline is alive.

### 6.5 Use Grafana Explore for Logs

In Grafana:

1. Open `Explore`
2. Switch to the `Loki` datasource
3. Run a simple query

Examples:

```logql
{job="ceos-syslog"}
```

```logql
{job="ceos-syslog", host="leaf1"}
```

```logql
{job="ceos-syslog", severity_name="err"}
```

Use this when you want to correlate control-plane changes with EOS log messages.

### 6.6 Use ntopng for Traffic Visibility

Open `http://localhost:3001` and look for:

- Top hosts
- Top applications/protocols
- Active flows
- Traffic rate and conversations

Use this when you want to answer:

- Is traffic actually crossing the fabric?
- Which endpoints are talking?
- Is there visible load when I run a test?

## 7. How To Generate Useful Test Events

### 7.1 BGP Flaps

Flap one neighbor to create control-plane changes that show up in telemetry and logs.

Example on `leaf1`:

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 bash -lc "printf 'enable\nconfigure terminal\nrouter bgp 65101\nneighbor 10.0.0.1 shutdown\nend\n' | Cli"
sleep 10
docker exec clab-arista-evpn-vxlan-fabric-leaf1 bash -lc "printf 'enable\nconfigure terminal\nrouter bgp 65101\nno neighbor 10.0.0.1 shutdown\nend\n' | Cli"
```

Then verify:

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c 'show bgp evpn summary'
curl -s http://localhost:9804/metrics | rg 'neighbor_neighbor_address=\"10.0.0.1\"'
```

What you should see:

- The EOS CLI shows `Idle(Admin)` during the shutdown
- `established_transitions` increases after recovery
- `last_established` updates
- Logs appear in `Loki`/Grafana

Important behavior:

- `gnmic` keeps old label series for up to 10 minutes because the Prometheus output uses `expiration: 10m`
- That means you may temporarily see both `session_state="IDLE"` and `session_state="ESTABLISHED"` for the same neighbor

That is expected in this design.

### 7.2 Traffic Tests

Run pings or `iperf3` between the hosts.

Examples:

```bash
docker exec clab-arista-evpn-vxlan-fabric-host1 ping -c 5 192.168.10.102
docker exec clab-arista-evpn-vxlan-fabric-host1 iperf3 -c 192.168.10.102 -t 15
```

What you can observe:

- Reachability and throughput in the network
- Traffic/flow visibility in `ntopng`
- Related logs if there are control-plane issues

## 8. How To Work With gnmic

The active collector config is [gnmic-config.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/gnmic/gnmic-config.yml).

Use `gnmic` in two ways.

### 8.1 Passive Collector Mode

This is the default lab behavior:

- The `gnmic` container starts automatically
- It launches a `subscribe` process
- It exports metrics on port `9804`

This is what feeds the dashboards.

### 8.2 Interactive Troubleshooting Mode

Exec into the container and run `gnmic` commands manually:

```bash
docker exec -it clab-arista-evpn-vxlan-mgmt-gnmic sh
```

Examples:

```bash
gnmic --config /gnmic-config.yml targets
gnmic --config /gnmic-config.yml capabilities --target leaf1
gnmic --config /gnmic-config.yml get --target leaf1 --path /system/state/hostname
```

Use this when you want to verify:

- Device reachability over gNMI
- Supported models and encodings
- Whether a specific OpenConfig path returns the data you expect

### 8.3 Extending Telemetry

If you want more than BGP telemetry, add new subscriptions in [gnmic-config.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/gnmic/gnmic-config.yml).

Typical next additions:

- Interface counters
- Interface operational state
- CPU
- Memory
- System uptime
- LLDP neighbors

After editing the config, restart the `gnmic` container or redeploy the management lab.

## 9. How To Work With Grafana

Grafana is the main UI for daily use.

Practical uses:

- Watch BGP sessions during topology changes
- Confirm a failure shows up in telemetry
- Search logs during a fault
- Correlate metrics and logs in one place

The useful distinction is:

- Dashboards are for prebuilt views
- Explore is for targeted troubleshooting

When learning the lab, spend more time in `Explore` than on dashboards. Dashboards are useful, but `Explore` teaches you what data is actually present.

## 10. How To Work With Loki and Logs

Use `Loki` via Grafana Explore.

Think of it as your event timeline.

Metrics tell you:

- A value changed
- A counter increased
- A state moved

Logs tell you:

- Why the device says it changed
- What software component emitted the event
- Whether there were warnings or errors around the same time

A good operator habit in this lab is:

1. Find the metric change in Grafana
2. Open `Loki` Explore for the same time range
3. Filter on the device hostname
4. Confirm the event in syslog

That gives you both symptom and evidence.

## 11. Common Troubleshooting Checks

### 11.1 Grafana Is Up But Panels Are Empty

Check these in order:

1. Is `gnmic` exporting anything on `:9804`?
2. Does the panel query reference a metric family that your current `gnmic` config actually collects?
3. Is `Alloy` scraping and forwarding?
4. Is the time range wide enough?

In this repo, blank panels are often caused by a dashboard expecting metrics that are not currently subscribed in `gnmic`.

### 11.2 Telemetry Exists on :9804 But Not in Grafana

That usually points to the path between `gnmic` and `Mimir`:

- `Alloy` scraping failure
- `Alloy` relabeling issue
- `Mimir` ingest issue

Check:

```bash
docker logs clab-arista-evpn-vxlan-mgmt-alloy
docker logs clab-arista-evpn-vxlan-mgmt-mimir
```

### 11.3 Logs Are Missing

Check:

- EOS logging destination
- `Alloy` syslog listeners
- `Loki` container health

Useful commands:

```bash
docker logs clab-arista-evpn-vxlan-mgmt-alloy
docker logs clab-arista-evpn-vxlan-mgmt-loki
```

### 11.4 ntopng Shows Little or No Traffic

Check:

- The EOS SPAN source config on `leaf1`
- That `ntopng` is running
- That you are generating actual traffic

Useful commands:

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c 'show monitor session SPAN'
docker exec clab-arista-evpn-vxlan-fabric-host1 ping -c 5 192.168.10.102
```

## 12. Mental Model: Which Tool To Use For What

Use this simple rule set:

- Use EOS CLI when you want the ground truth on the device
- Use `gnmic` when you want structured operational state exported from the device
- Use `Grafana + Mimir` when you want numeric telemetry over time
- Use `Grafana + Loki` when you want event evidence and message history
- Use `ntopng` when you want flow and packet-level visibility

A practical workflow looks like this:

1. Confirm the issue on EOS CLI
2. Check whether the same event is visible in metrics
3. Check whether syslog explains it
4. Check whether real traffic was affected

That is the full value of this lab: it lets you correlate control plane, telemetry, logs, and traffic in one place.

## 13. Suggested First Exercises

If you want to learn the lab quickly, do these three exercises.

### Exercise 1: Baseline

1. Open Grafana
2. Run a BGP session-state query in Explore
3. Check `show bgp evpn summary` on a leaf
4. Confirm the metrics match the CLI

### Exercise 2: Controlled Failure

1. Shut one BGP neighbor
2. Watch the session change in EOS CLI
3. Watch `established_transitions` change in Grafana
4. Check `Loki` for the related log entries
5. Restore the neighbor

### Exercise 3: Traffic Validation

1. Generate ping or `iperf3` between `host1` and `host2`
2. Confirm forwarding is working
3. Open `ntopng`
4. Observe traffic and conversations

These three exercises cover almost the whole lab value chain.

## 14. Current Design Notes

There are a few design details worth keeping in mind:

- The active split management lab uses `Mimir`, not a standalone `Prometheus` container
- Some older docs and the legacy combined topology still reference `Prometheus`
- The active `gnmic` config is BGP-heavy, so not every prebuilt dashboard panel will necessarily populate yet

Treat the current implementation as:

- A working BGP telemetry and logging lab
- With room to expand into broader interface and system telemetry

## 15. Fast Command Reference

Deploy:

```bash
bash stage_deploy.sh
```

Destroy:

```bash
bash stage_deploy.sh destroy
```

Check fabric BGP:

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c 'show bgp evpn summary'
```

Check exporter:

```bash
curl -s http://localhost:9804/metrics | head -40
```

Check a specific neighbor:

```bash
curl -s http://localhost:9804/metrics | rg 'neighbor_neighbor_address=\"10.0.0.1\"'
```

Open Grafana:

```text
http://localhost:3000
```

Open ntopng:

```text
http://localhost:3001
```

Check management container logs:

```bash
docker logs clab-arista-evpn-vxlan-mgmt-gnmic
docker logs clab-arista-evpn-vxlan-mgmt-alloy
docker logs clab-arista-evpn-vxlan-mgmt-mimir
docker logs clab-arista-evpn-vxlan-mgmt-loki
docker logs clab-arista-evpn-vxlan-mgmt-grafana
```

---

If you expand only one thing first, expand [gnmic-config.yml](/Users/gunny/Projects/network/clabs/ml-fabric-lab/configs/gnmic/gnmic-config.yml) with interface and system telemetry. That will make the dashboards much more useful and will turn this from a BGP-focused observability lab into a broader operations lab.
