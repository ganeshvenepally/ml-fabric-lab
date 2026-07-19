# Arista BGP VRF SNMP Lab

This Containerlab topology builds two Arista cEOS routers with one eBGP session in
VRF `BLUE` and a second eBGP session in VRF `GREEN`.

SNMPv2c is enabled in `MGMT`, `BLUE`, and `GREEN`. The included poller has
interfaces in both tenant VRFs, so plain `-c lab` polling can reach the SNMP
agent inside each VRF.

For Arista per-VRF BGP MIB data, EOS still requires an SNMP context. With
SNMPv2c, that context is encoded in the community as `lab@BLUE` or `lab@GREEN`.

## Files

- `arista-bgp-vrf-snmp.clab.yml` - Containerlab topology
- `configs/r1.cfg` - r1 startup configuration
- `configs/r2.cfg` - r2 startup configuration

## Deploy

```bash
cd /Users/gunny/Projects/network/clabs/ml-fabric-lab/arista-bgp-vrf-snmp-lab
containerlab deploy -t arista-bgp-vrf-snmp.clab.yml
```

## Validate BGP

```bash
docker exec clab-arista-bgp-vrf-snmp-r1 Cli -c "show ip bgp summary vrf BLUE"
docker exec clab-arista-bgp-vrf-snmp-r1 Cli -c "show ip bgp summary vrf GREEN"
docker exec clab-arista-bgp-vrf-snmp-r2 Cli -c "show ip bgp summary vrf BLUE"
docker exec clab-arista-bgp-vrf-snmp-r2 Cli -c "show ip bgp summary vrf GREEN"
```

## Plain SNMPv2c Reachability

The poller container installs `snmpwalk` at deploy time. These examples use the
plain community `lab` and target the router IP inside the tenant VRF:

```bash
docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab 10.10.101.1 1.3.6.1.2.1.1.1.0

docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab 10.20.101.1 1.3.6.1.2.1.1.1.0
```

## Poll BGP State With SNMPv2c Context

Poll the Arista enterprise BGP4-V2 peer state object with the VRF context in the
community:

```bash
docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab@BLUE 10.10.101.1 1.3.6.1.4.1.30065.4.1.1.2.1.13

docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab@GREEN 10.20.101.1 1.3.6.1.4.1.30065.4.1.1.2.1.13
```

Expected peer state value is `6`, which means `established`.

Useful BGP OIDs:

- `1.3.6.1.4.1.30065.4.1.1.2.1.12` - aristaBgp4V2PeerAdminStatus
- `1.3.6.1.4.1.30065.4.1.1.2.1.13` - aristaBgp4V2PeerState
- `1.3.6.1.4.1.30065.4.1.1.2.1.14` - aristaBgp4V2PeerDescription

Poll `r2` the same way:

```bash
docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab@BLUE 10.10.102.1 1.3.6.1.4.1.30065.4.1.1.2.1.13

docker exec clab-arista-bgp-vrf-snmp-poller snmpwalk \
  -v2c -c lab@GREEN 10.20.102.1 1.3.6.1.4.1.30065.4.1.1.2.1.13
```

## Destroy

```bash
containerlab destroy -t arista-bgp-vrf-snmp.clab.yml
```
