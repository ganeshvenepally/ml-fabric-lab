# Troubleshooting

This page is organized by failure domain so you can isolate problems quickly.

## Method

Always classify the failure first:

1. physical or interface problem
2. underlay routing problem
3. EVPN control-plane problem
4. VXLAN/VNI problem
5. host or gateway problem
6. observability-stack problem

If you skip classification, you waste time.

## Interfaces Down

### Symptoms

- BGP neighbors never leave `Idle` or `Active`
- `show interfaces status` shows uplinks down
- hosts cannot even ARP locally

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show interfaces status"
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show ip interface brief"
docker exec clab-arista-evpn-vxlan-fabric-host1 ip link show eth1
```

### Typical Causes

- wrong interface numbering in the topology file
- access port not enabled
- host-side interface not brought up

## Underlay BGP Fails

### Symptoms

- EVPN never converges
- remote loopbacks missing from the routing table
- `show ip bgp summary` shows neighbors stuck or absent

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show ip bgp summary"
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show ip route 10.0.1.14"
docker exec clab-arista-evpn-vxlan-fabric-spine1 Cli -c "show ip bgp"
```

### Typical Causes

- point-to-point IP mismatch on a /31
- ASN mismatch
- routed interface accidentally left as switchport
- loopback not advertised in IPv4 unicast

## EVPN Sessions Down

### Symptoms

- `show ip bgp summary` is healthy but `show bgp evpn summary` is not
- deployment script waits until timeout

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show bgp evpn summary"
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show running-config section router bgp"
```

### Typical Causes

- missing `address-family evpn`
- missing `neighbor OVERLAY activate`
- missing `send-community extended`
- loopback reachability issue even though physical links are up
- wrong overlay neighbor IPs

## VNI Exists But Remote Endpoints Do Not Learn

### Symptoms

- EVPN sessions are up
- IMET routes are present
- host-to-host traffic still fails

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show bgp evpn route-type imet"
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show bgp evpn route-type mac-ip"
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show mac address-table dynamic"
```

### Typical Causes

- no local host traffic yet, so no MAC/IP route has been originated
- VLAN-to-VNI mapping mismatch
- missing `redistribute learned` under the VLAN EVPN stanza
- host connected to the wrong VLAN

## Anycast Gateway Problems

### Symptoms

- hosts can talk only within the same leaf or not at all
- default gateway resolution is inconsistent
- ARP for `192.168.10.1` fails

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-host1 ip neigh
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show ip virtual-router"
docker exec clab-arista-evpn-vxlan-fabric-leaf4 Cli -c "show ip virtual-router"
```

### Typical Causes

- `Vlan10` missing or shut
- VARP MAC mismatch between access leafs
- host port not in VLAN 10

## MTU Problems

### Symptoms

- BGP and ARP work, but larger packets fail
- `iperf3` is unstable while ping with tiny payload works

### Checks

```bash
docker exec clab-arista-evpn-vxlan-fabric-host1 ping -M do -s 1472 -c 3 192.168.10.102
docker exec clab-arista-evpn-vxlan-fabric-leaf1 Cli -c "show interfaces ethernet 1"
docker exec clab-arista-evpn-vxlan-fabric-leaf4 Cli -c "show interfaces ethernet 1"
```

### Typical Causes

- inconsistent MTU between routed fabric links
- host-side assumptions about end-to-end payload size

## Management Stack Problems

### Symptoms

- Grafana opens but dashboards are empty
- metrics endpoint is empty
- logs do not appear in Loki

### Checks

```bash
curl -s http://localhost:9804/metrics | head
curl -s http://localhost:9009/ready
curl -s http://localhost:3100/ready
docker ps --format '{{.Names}}'
```

### Typical Causes

- management topology not deployed
- datasource drift between dashboards and the current stack
- `gnmic` subscription paths not matching the dashboards you expect

## Repository Drift To Be Aware Of

This repository contains evidence of multiple iterations of the lab:

- split topologies
- a combined topology
- older docs that referenced Prometheus and ntopng differently

If behavior looks inconsistent, verify the exact file you deployed before assuming the network is wrong. For staged deployment, start from:

- `topology.fabric.yaml`
- `topology.mgmt.yaml`
- `stage_deploy.sh`
