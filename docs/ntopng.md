# Traffic Visibility Notes

This repository includes packet-visibility ideas, but the exact ntopng placement depends on which topology variant you use.

## Current State

- The staged split deployment uses `topology.fabric.yaml` and `topology.mgmt.yaml`.
- The older combined topology `ml-clab-topo.yml` contains a fuller inline packet-visibility design.

## Fabric-Side SPAN

`leaf1` is the only leaf with explicit SPAN configuration in the EOS config:

```eos
monitor session SPAN source Ethernet1
monitor session SPAN source Ethernet2
monitor session SPAN source Ethernet10
monitor session SPAN destination Ethernet5
```

That means the mirrored packet stream consists of:

- uplink traffic to/from `spine1`
- uplink traffic to/from `spine2`
- access traffic to/from `host1`

## Why This Matters

It gives you a packet-level view of:

- ARP resolution
- host onboarding
- VXLAN-bearing traffic on the fabric edge
- throughput tests from `host1` to `host2`

For the VXLAN/EVPN documentation set, SPAN is best treated as an adjunct troubleshooting aid rather than part of the control-plane design itself.
