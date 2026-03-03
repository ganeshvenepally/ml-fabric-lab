#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# stage_deploy.sh
#
# Deploy:
#   ./stage_deploy.sh [fabric_topology.yaml] [mgmt_topology.yaml]
#   ./stage_deploy.sh -r|-rf|-rm [fabric_topology.yaml] [mgmt_topology.yaml]
#
# Destroy:
#   ./stage_deploy.sh destroy [fabric_topology.yaml] [mgmt_topology.yaml]
#
# Flags:
#   -r,  --reconfigure         reconfigure BOTH labs (standard staged flow + wait)
#   -rf, --reconfigure-fabric  reconfigure ONLY fabric lab (FAST: no wait, no mgmt)
#   -rm, --reconfigure-mgmt    reconfigure ONLY mgmt lab   (FAST: no fabric, no wait)
# ------------------------------------------------------------------------------

ACTION="deploy"
RECONF_FABRIC=0
RECONF_MGMT=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORIG_PWD="$(pwd)"

# Default topology files (override by args)
FABRIC_TOPO_DEFAULT="topology.fabric.yaml"
MGMT_TOPO_DEFAULT="topology.mgmt.yaml"

usage() {
  echo "Usage:"
  echo "  $0 [fabric_topology.yaml] [mgmt_topology.yaml]"
  echo "  $0 -r|-rf|-rm [fabric_topology.yaml] [mgmt_topology.yaml]"
  echo "  $0 destroy [fabric_topology.yaml] [mgmt_topology.yaml]"
}

resolve_user_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf "%s\n" "$path"
  else
    printf "%s/%s\n" "$ORIG_PWD" "$path"
  fi
}

# -----------------------------
# Parse args (order-independent)
# -----------------------------
POSITIONALS=()

while (( "$#" )); do
  case "$1" in
    destroy)
      ACTION="destroy"
      shift
      ;;
    --reconfigure|-r)
      RECONF_FABRIC=1
      RECONF_MGMT=1
      shift
      ;;
    --reconfigure-fabric|-rf)
      RECONF_FABRIC=1
      shift
      ;;
    --reconfigure-mgmt|-rm)
      RECONF_MGMT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      POSITIONALS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONALS[@]} -ge 1 ]]; then
  FABRIC_TOPO="$(resolve_user_path "${POSITIONALS[0]}")"
else
  FABRIC_TOPO="${SCRIPT_DIR}/${FABRIC_TOPO_DEFAULT}"
fi

if [[ ${#POSITIONALS[@]} -ge 2 ]]; then
  MGMT_TOPO="$(resolve_user_path "${POSITIONALS[1]}")"
else
  MGMT_TOPO="${SCRIPT_DIR}/${MGMT_TOPO_DEFAULT}"
fi

cd "${SCRIPT_DIR}"

# Lab names must match the 'name:' field in each topology
FABRIC_LAB_NAME="${FABRIC_LAB_NAME:-arista-evpn-vxlan-fabric}"
MGMT_LAB_NAME="${MGMT_LAB_NAME:-arista-evpn-vxlan-mgmt}"

# Node filters (only used for logging)
FABRIC_NODES="${FABRIC_NODES:-spine1,spine2,leaf1,leaf2,leaf3,leaf4,host1,host2}"
MGMT_NODES="${MGMT_NODES:-gnmic,prometheus,grafana,alloy,loki,redis,ntopng}"

# EVPN check containers (fabric lab)
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

# Tap bridge (left here in case you still use it elsewhere; not called)
TAP_BRIDGE="${TAP_BRIDGE:-br-fabric-tap}"
SKIP_TAP_BRIDGE="${SKIP_TAP_BRIDGE:-1}"

# ---- Colors (disable with NO_COLOR=1) ----
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
  local s="$1"
  case "$s" in
    READY) printf "%sREADY%s" "${C_GREEN}${C_BOLD}" "${C_RESET}" ;;
    WAIT)  printf "%sWAIT%s"  "${C_YELLOW}${C_BOLD}" "${C_RESET}" ;;
    *)     printf "%s" "$s" ;;
  esac
}

# ------------------------------------------------------------------------------
# EVPN totals:
# - Works with EOS summary with OR without "Description" column
# - Optional timeout wrapper to avoid a stuck docker exec hanging the loop
# ------------------------------------------------------------------------------
evpn_totals() {
  local c="$1"
  local cmd=(docker exec "$c" Cli -c "show bgp evpn summary")

  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "${cmd[@]}" 2>/dev/null | awk '
      function is_ip(x) { return x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
      {
        ipcol = statecol = 0
        if (is_ip($1)) { ipcol=1; statecol=9 }
        else if (is_ip($2)) { ipcol=2; statecol=10 }

        if (ipcol) {
          total++
          s = $(statecol)
          if (s != "Estab" && s != "Established" && s !~ /^[0-9]+$/) bad++
        }
      }
      END { printf "%d %d\n", total+0, bad+0 }
    '
  else
    "${cmd[@]}" 2>/dev/null | awk '
      function is_ip(x) { return x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
      {
        ipcol = statecol = 0
        if (is_ip($1)) { ipcol=1; statecol=9 }
        else if (is_ip($2)) { ipcol=2; statecol=10 }

        if (ipcol) {
          total++
          s = $(statecol)
          if (s != "Estab" && s != "Established" && s !~ /^[0-9]+$/) bad++
        }
      }
      END { printf "%d %d\n", total+0, bad+0 }
    '
  fi
}

# Make totals read non-fatal under `set -e` and always set TOTAL_NEI/BAD_NEI
safe_read_totals() {
  local c="$1"
  TOTAL_NEI=0
  BAD_NEI=999

  if ! read -r TOTAL_NEI BAD_NEI < <(evpn_totals "$c" 2>/dev/null || printf "0 999\n"); then
    TOTAL_NEI=0
    BAD_NEI=999
  fi

  [[ "${TOTAL_NEI}" =~ ^[0-9]+$ ]] || TOTAL_NEI=0
  [[ "${BAD_NEI}"   =~ ^[0-9]+$ ]] || BAD_NEI=999
}

# Build ASCII progress bar
render_bar() {
  local ready="$1" total="$2" elapsed="$3" maxwait="$4"
  local width=36
  local pct=0

  if (( total > 0 )); then
    pct=$(( ready * 100 / total ))
  fi

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))

  local bar="" i
  for ((i=0; i<filled; i++)); do bar+="#"; done
  for ((i=0; i<empty;  i++)); do bar+="-"; done

  printf "%s[%s]%s %s%3d%%%s  %s%d/%d READY%s  %s(elapsed %ss / timeout %ss)%s" \
    "${C_CYAN}${C_BOLD}" "$bar" "${C_RESET}" \
    "${C_BOLD}" "$pct" "${C_RESET}" \
    "${C_BOLD}" "$ready" "$total" "${C_RESET}" \
    "${C_DIM}" "$elapsed" "$maxwait" "${C_RESET}"
}

print_status_line() {
  printf "\r\033[2K%s" "$1"
}

spinner_wait() {
  local seconds="$1" ready="$2" total="$3" start_elapsed="$4" maxwait="$5"
  local frames=( "|" "/" "-" "\\" )
  local i=0

  set +e
  for ((s=seconds; s>0; s--)); do
    local shown_elapsed=$(( start_elapsed + (seconds - s) ))
    local bar
    bar="$(render_bar "$ready" "$total" "$shown_elapsed" "$maxwait" 2>/dev/null)"
    local spin="${frames[i % 4]}"
    print_status_line "${bar}  ${C_DIM}${spin} next poll in ${s}s${C_RESET}"
    ((i++))
    sleep 1
  done
  print_status_line ""
  echo
  set -e
}

ensure_network() {
  local net="clab-mgmt"
  if ! docker network ls --format '{{.Name}}' | grep -qx "$net"; then
    echo "${C_YELLOW}${C_BOLD}[$(ts)] ⚠ Docker network '${net}' not found. Creating it...${C_RESET}"
    docker network create --subnet 172.20.20.0/24 "$net" >/dev/null
    echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ Created network '${net}'${C_RESET}"
  fi
}

ensure_persist_dirs() {
  local persist_dirs=(
    "${SCRIPT_DIR}/persist/ntopng"
    "${SCRIPT_DIR}/persist/mimir"
    "${SCRIPT_DIR}/persist/grafana"
    "${SCRIPT_DIR}/persist/loki"
    "${SCRIPT_DIR}/persist/redis"
  )

  mkdir -p "${persist_dirs[@]}"
}

# (Unused now, left for reference)
ensure_tap_bridge() {
  if [[ "$SKIP_TAP_BRIDGE" == "1" ]]; then
    echo "${C_DIM}[$(ts)] SKIP_TAP_BRIDGE=1 set; not creating ${TAP_BRIDGE}${C_RESET}"
    return 0
  fi

  if command -v ip >/dev/null 2>&1; then
    if ip link show "$TAP_BRIDGE" >/dev/null 2>&1; then
      echo "${C_DIM}[$(ts)] Tap bridge ${TAP_BRIDGE} already exists${C_RESET}"
    else
      echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Creating tap bridge ${TAP_BRIDGE}${C_RESET}"
      sudo ip link add "$TAP_BRIDGE" type bridge
      sudo ip link set "$TAP_BRIDGE" up
      echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ Tap bridge ${TAP_BRIDGE} created${C_RESET}"
    fi
  else
    echo "${C_YELLOW}${C_BOLD}[$(ts)] ⚠ 'ip' not found; cannot ensure tap bridge. Create ${TAP_BRIDGE} manually.${C_RESET}"
  fi
}

destroy_labs() {
  echo
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo "${C_CYAN}${C_BOLD}[$(ts)] DESTROY CONTAINERLAB LABS${C_RESET}"
  echo "${C_DIM}[$(ts)] Fabric topo : ${FABRIC_TOPO}${C_RESET}"
  echo "${C_DIM}[$(ts)] Mgmt topo   : ${MGMT_TOPO}${C_RESET}"
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo

  echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Destroying mgmt lab (${MGMT_LAB_NAME})${C_RESET}"
  clab destroy -t "${MGMT_TOPO}" --cleanup || true

  echo
  echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Destroying fabric lab (${FABRIC_LAB_NAME})${C_RESET}"
  clab destroy -t "${FABRIC_TOPO}" --cleanup || true

  echo
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ DESTROY COMPLETE${C_RESET}"
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo
}

deploy_labs() {
  ensure_persist_dirs
  ensure_network

  local FABRIC_ARGS=()
  local MGMT_ARGS=()
  [[ "$RECONF_FABRIC" == "1" ]] && FABRIC_ARGS+=(--reconfigure)
  [[ "$RECONF_MGMT"   == "1" ]] && MGMT_ARGS+=(--reconfigure)

  # -------------------------
  # FAST PATHS (no EVPN wait)
  # -------------------------
  if [[ "$RECONF_FABRIC" == "1" && "$RECONF_MGMT" == "0" ]]; then
    echo
    echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Reconfigure ONLY fabric lab (skipping EVPN wait + mgmt deploy)${C_RESET}"
    echo "${C_DIM}[$(ts)] Fabric topo : ${FABRIC_TOPO}${C_RESET}"
    clab deploy -t "${FABRIC_TOPO}" "${FABRIC_ARGS[@]}"
    echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ Fabric reconfigure complete${C_RESET}"
    return 0
  fi

  if [[ "$RECONF_FABRIC" == "0" && "$RECONF_MGMT" == "1" ]]; then
    echo
    echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Reconfigure ONLY mgmt lab (skipping fabric deploy + EVPN wait)${C_RESET}"
    echo "${C_DIM}[$(ts)] Mgmt topo : ${MGMT_TOPO}${C_RESET}"
    clab deploy -t "${MGMT_TOPO}" "${MGMT_ARGS[@]}"
    echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ Mgmt reconfigure complete${C_RESET}"
    return 0
  fi

  # -------------------------
  # Normal staged deploy flow
  # -------------------------
  echo
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo "${C_CYAN}${C_BOLD}[$(ts)] STAGED CONTAINERLAB DEPLOY (2 labs)${C_RESET}"
  echo "${C_DIM}[$(ts)] Fabric topo : ${FABRIC_TOPO}${C_RESET}"
  echo "${C_DIM}[$(ts)] Mgmt topo   : ${MGMT_TOPO}${C_RESET}"
  echo "${C_DIM}[$(ts)] Fabric name : ${FABRIC_LAB_NAME}${C_RESET}"
  echo "${C_DIM}[$(ts)] Mgmt name   : ${MGMT_LAB_NAME}${C_RESET}"
  echo "${C_DIM}[$(ts)] Reconf      : fabric=${RECONF_FABRIC} mgmt=${RECONF_MGMT}${C_RESET}"
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo

  echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Stage 1: Deploying fabric lab${C_RESET}"
  echo "${C_DIM}[$(ts)]   (Nodes include: ${FABRIC_NODES})${C_RESET}"
  clab deploy -t "${FABRIC_TOPO}" "${FABRIC_ARGS[@]}"

  echo
  echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Waiting for EVPN BGP to establish${C_RESET}"
  echo "${C_DIM}[$(ts)]   Condition: all EVPN neighbors in state 'Estab'${C_RESET}"
  echo "${C_DIM}[$(ts)]   Poll every: ${POLL_INT}s | Timeout: ${MAX_WAIT}s${C_RESET}"
  echo

  local START_TS NOW ELAPSED ITER READY_DEVICES TOTAL_DEVICES
  START_TS=$(date +%s)
  ITER=1
  TOTAL_DEVICES="${#EVPN_CHECK_CONTAINERS[@]}"

  while true; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TS ))

    READY_DEVICES=0
    local ALL_READY=true

    echo "${C_CYAN}${C_BOLD}[$(ts)] ── Poll #${ITER}${C_RESET}"
    printf "    %-45s %-10s %-20s\n" "NODE" "STATUS" "DETAILS"
    printf "    %-45s %-10s %-20s\n" "----" "------" "-------"

    for c in "${EVPN_CHECK_CONTAINERS[@]}"; do
      if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
        printf "    %-45s %-10b %-20s\n" "$c" "$(status_tag WAIT)" "container not running"
        ALL_READY=false
        continue
      fi

      safe_read_totals "$c"

      if [[ "$TOTAL_NEI" -lt 1 ]]; then
        printf "    %-45s %-10b %-20s\n" "$c" "$(status_tag WAIT)" "no EVPN neighbors"
        ALL_READY=false
      elif [[ "$BAD_NEI" -gt 0 ]]; then
        printf "    %-45s %-10b %-20s\n" "$c" "$(status_tag WAIT)" "$BAD_NEI/$TOTAL_NEI not Estab"
        ALL_READY=false
      else
        printf "    %-45s %-10b %-20s\n" "$c" "$(status_tag READY)" "$TOTAL_NEI neighbors"
        ((++READY_DEVICES))   # prefix increment avoids `set -e` surprises
      fi
    done

    echo
    echo "    $(render_bar "$READY_DEVICES" "$TOTAL_DEVICES" "$ELAPSED" "$MAX_WAIT")"
    echo

    if $ALL_READY; then
      echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ EVPN BGP established across all fabric nodes${C_RESET}"
      break
    fi

    if (( ELAPSED >= MAX_WAIT )); then
      echo "${C_RED}${C_BOLD}[$(ts)] ⚠ TIMEOUT reached (${MAX_WAIT}s)${C_RESET}"
      echo "${C_YELLOW}${C_BOLD}[$(ts)]   Proceeding with management lab deploy anyway${C_RESET}"
      break
    fi

    spinner_wait "$POLL_INT" "$READY_DEVICES" "$TOTAL_DEVICES" "$ELAPSED" "$MAX_WAIT"
    ((++ITER))
  done

  echo
  echo "${C_CYAN}${C_BOLD}[$(ts)] ▶ Stage 2: Deploying management lab${C_RESET}"
  echo "${C_DIM}[$(ts)]   (Nodes include: ${MGMT_NODES})${C_RESET}"
  clab deploy -t "${MGMT_TOPO}" "${MGMT_ARGS[@]}"

  echo
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo "${C_GREEN}${C_BOLD}[$(ts)] ✔ STAGED DEPLOY COMPLETE${C_RESET}"
  echo "${C_CYAN}${C_BOLD}============================================================${C_RESET}"
  echo
}

case "${ACTION}" in
  deploy)
    deploy_labs
    ;;
  destroy)
    destroy_labs
    ;;
  *)
    usage
    exit 1
    ;;
esac
