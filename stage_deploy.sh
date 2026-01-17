#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# stage_deploy.sh
#
# Deploy:
#   ./stage_deploy.sh [fabric_topology.yaml] [mgmt_topology.yaml]
# Destroy:
#   ./stage_deploy.sh destroy [fabric_topology.yaml] [mgmt_topology.yaml]
#
# Notes:
# - Assumes both labs attach to the same external mgmt network: clab-mgmt
# - If using a shared host bridge for tap traffic (e.g. br-fabric-tap), this script
#   can create it inside the environment where Docker runs (OrbStack Linux machine),
#   unless you set SKIP_TAP_BRIDGE=1.
# ------------------------------------------------------------------------------

ACTION="${1:-deploy}"

FABRIC_TOPO_DEFAULT="topology.fabric.yaml"
MGMT_TOPO_DEFAULT="topology.mgmt.yaml"

if [[ "${ACTION}" == "destroy" ]]; then
  FABRIC_TOPO="${2:-$FABRIC_TOPO_DEFAULT}"
  MGMT_TOPO="${3:-$MGMT_TOPO_DEFAULT}"
else
  FABRIC_TOPO="${1:-$FABRIC_TOPO_DEFAULT}"
  MGMT_TOPO="${2:-$MGMT_TOPO_DEFAULT}"
  ACTION="deploy"
fi

FABRIC_LAB_NAME="${FABRIC_LAB_NAME:-arista-evpn-vxlan-fabric}"
MGMT_LAB_NAME="${MGMT_LAB_NAME:-arista-evpn-vxlan-mgmt}"

FABRIC_NODES="${FABRIC_NODES:-spine1,spine2,leaf1,leaf2,leaf3,leaf4,host1,host2}"
MGMT_NODES="${MGMT_NODES:-gnmic,prometheus,grafana,alloy,loki,redis,ntopng}"

EVPN_CHECK_CONTAINERS=(
  "clab-${FABRIC_LAB_NAME}-spine1"
  "clab-${FABRIC_LAB_NAME}-spine2"
  "clab-${FABRIC_LAB_NAME}-leaf1"
  "clab-${FABRIC_LAB_NAME}-leaf2"
  "clab-${FABRIC_LAB_NAME}-leaf3"
  "clab-${FABRIC_LAB_NAME}-leaf4"
)

MAX_WAIT="${MAX_WAIT:-300}"
POLL_INT="${POLL_INT:-10}"

TAP_BRIDGE="${TAP_BRIDGE:-br-fabric-tap}"
SKIP_TAP_BRIDGE="${SKIP_TAP_BRIDGE:-0}"

# ---- Colors ----
if [[ "${NO_COLOR:-0}" == "1" ]] || [[ ! -t 1 ]]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_DIM=""; C_BOLD=""
else
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
fi

ts() { date +"%Y-%m-%d %H:%M:%S"; }

status_tag() {
  case "$1" in
    READY) printf "%sREADY%s" "${C_GREEN}${C_BOLD}" "${C_RESET}" ;;
    WAIT)  printf "%sWAIT%s"  "${C_YELLOW}${C_BOLD}" "${C_RESET}" ;;
    *)     printf "%s" "$1" ;;
  esac
}

# ------------------------------------------------------------------------------
# FIXED EVPN PARSER
# Handles both EOS formats and avoids docker exec hangs
# ------------------------------------------------------------------------------
evpn_totals() {
  local c="$1"
  timeout 5 docker exec "$c" Cli -c "show bgp evpn summary" 2>/dev/null | awk '
    function is_ip(x) { return x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
    {
      ipcol = statecol = 0

      # Format without Description column
      if (is_ip($1)) { ipcol=1; statecol=9 }

      # Format with Description column
      else if (is_ip($2)) { ipcol=2; statecol=10 }

      if (ipcol) {
        total++
        s = $(statecol)
        if (s != "Estab" && s != "Established" && s !~ /^[0-9]+$/)
          bad++
      }
    }
    END { printf "%d %d\n", total+0, bad+0 }
  '
}

render_bar() {
  local ready="$1" total="$2" elapsed="$3" maxwait="$4"
  local width=36 pct=0

  (( total > 0 )) && pct=$(( ready * 100 / total ))

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))

  printf "%s[%*s%*s]%s %s%3d%%%s  %s%d/%d READY%s  %s(elapsed %ss / timeout %ss)%s" \
    "${C_CYAN}${C_BOLD}" \
    "$filled" "$(printf '#%.0s' $(seq 1 $filled))" \
    "$empty"  "$(printf '-%.0s' $(seq 1 $empty))" \
    "${C_RESET}" \
    "${C_BOLD}" "$pct" "${C_RESET}" \
    "${C_BOLD}" "$ready" "$total" "${C_RESET}" \
    "${C_DIM}" "$elapsed" "$maxwait" "${C_RESET}"
}

print_status_line() {
  printf "\r\033[2K%s" "$1"
}

spinner_wait() {
  local seconds="$1" ready="$2" total="$3" start_elapsed="$4" maxwait="$5"
  local frames=( "|" "/" "-" "\\" ) i=0
  set +e
  for ((s=seconds; s>0; s--)); do
    local shown_elapsed=$(( start_elapsed + (seconds - s) ))
    print_status_line "$(render_bar "$ready" "$total" "$shown_elapsed" "$maxwait")  ${C_DIM}${frames[i++ % 4]} next poll in ${s}s${C_RESET}"
    sleep 1
  done
  print_status_line ""
  echo
  set -e
}

ensure_network() {
  local net="clab-mgmt"
  docker network ls --format '{{.Name}}' | grep -qx "$net" || \
    docker network create --subnet 172.20.20.0/24 "$net" >/dev/null
}

ensure_tap_bridge() {
  [[ "$SKIP_TAP_BRIDGE" == "1" ]] && return 0
  command -v ip >/dev/null || return 0
  ip link show "$TAP_BRIDGE" >/dev/null 2>&1 || {
    sudo ip link add "$TAP_BRIDGE" type bridge
    sudo ip link set "$TAP_BRIDGE" up
  }
}

destroy_labs() {
  clab destroy -t "$MGMT_TOPO" --cleanup || true
  clab destroy -t "$FABRIC_TOPO" --cleanup || true
}

deploy_labs() {
  ensure_network
  ensure_tap_bridge

  clab deploy -t "$FABRIC_TOPO"

  START_TS=$(date +%s)
  ITER=1
  TOTAL_DEVICES="${#EVPN_CHECK_CONTAINERS[@]}"

  while true; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TS ))

    READY_DEVICES=0
    ALL_READY=true

    for c in "${EVPN_CHECK_CONTAINERS[@]}"; do
      read -r TOTAL BAD < <(evpn_totals "$c" || echo "0 999")
      if [[ "$TOTAL" -lt 1 || "$BAD" -gt 0 ]]; then
        ALL_READY=false
      else
        ((READY_DEVICES++))
      fi
    done

    $ALL_READY && break
    (( ELAPSED >= MAX_WAIT )) && break

    spinner_wait "$POLL_INT" "$READY_DEVICES" "$TOTAL_DEVICES" "$ELAPSED" "$MAX_WAIT"
    ((ITER++))
  done

  clab deploy -t "$MGMT_TOPO"
}

case "$ACTION" in
  deploy)  deploy_labs ;;
  destroy) destroy_labs ;;
  *) echo "Usage: $0 [fabric.yaml] [mgmt.yaml] | destroy"; exit 1 ;;
esac
