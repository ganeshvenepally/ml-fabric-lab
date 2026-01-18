# Arista EVPN / VXLAN Containerlab Lab

This repository provides a **split fabric + management Containerlab lab** for
testing **Arista EVPN/VXLAN (eBGP underlay, EVPN overlay)** with:

- Real data-plane traffic
- Traffic mirroring (SPAN → ntopng)
- Full telemetry, metrics, and logging stack
- Deterministic staged deployment

The design is optimized for **local labs (macOS + OrbStack)** while remaining
portable to Linux.

---

## 🧱 Lab Overview

### Fabric
- 2× Arista spines (EVPN route servers)
- 4× Arista leafs (VXLAN VTEPs)
- eBGP underlay, EVPN overlay
- Anycast gateway using VARP
- Linux hosts generating continuous traffic

### Management / Observability
- gNMI telemetry (gnmic)
- Metrics (Prometheus)
- Dashboards (Grafana)
- Logs (Alloy + Loki)
- Traffic analysis (ntopng via SPAN tap)

Fabric and management are deployed as **separate Containerlab topologies**
attached to the same management network.

---

## 🚀 Quick Start

### Requirements
- Docker
- containerlab
- OrbStack (macOS) or Linux
- Git

### Deploy the full lab
```bash
bash stage_deploy.sh
```

This will:
1. Deploy the **fabric lab**
2. Wait for EVPN BGP convergence
3. Deploy **hosts + management stack**

### Destroy the lab
```bash
bash stage_deploy.sh destroy
```

---

## 📖 Documentation

Full documentation (topology, operations, EVPN deep dives, troubleshooting)
is published via **MkDocs**:

👉 **https://laitm.github.io/ml-fabric-lab/**

Key sections:
- Fabric topology and design
- Management stack architecture
- EVPN/VXLAN control-plane walkthroughs
- ntopng traffic visibility
- Common failure modes and fixes

> The `README.md` is intentionally concise.
> All detailed documentation lives in `/docs` and on the site above.

---

## 🗂 Repository Structure

```text
.
├── topology.fabric.yaml      # Fabric-only containerlab topology
├── topology.mgmt.yaml        # Management / observability topology
├── stage_deploy.sh           # Staged deploy & destroy script
├── docs/                     # MkDocs documentation source
├── mkdocs.yml                # MkDocs configuration
├── requirements-docs.txt     # Docs build dependencies
└── configs/                  # cEOS, telemetry, and dashboard configs
```

---

## 🧠 Design Principles

- **Deterministic startup** (fabric first, then management)
- **Real traffic** (not synthetic demos)
- **No duplication** between README and docs
- **CI-published documentation**
- **Safe to break and debug**

---

## ⚠️ Notes

- The `site/` directory is intentionally **not tracked**
- Documentation output is published from GitHub Actions to `gh-pages`
- GitHub Pages is configured to use **Actions**, not Jekyll

---

## 📜 License

This project is provided for lab, testing, and educational use.
See individual component licenses for third-party tools.

## Things I Need To Fix 

- Change out Prometheus for Mirmir 
- Fix bridge logic between fabrics for SPAN/TAP 
- Update docker images and .yaml reference for ARM/INTEL cEOS images. So I can run the lab on either my Macbook(Intel) or Mac Mini (Arm)