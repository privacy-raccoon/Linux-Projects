#!/bin/bash

# Please note, this is a personal banner that I'm find with being available publicly. Pangolin and Netbird are two reverse procxies that I am evaluating. 

# --- Gather dynamic info ---
USER=$(whoami)
HOSTNAME=$(uname -n)
IP=$(ip -4 addr show enp0s18 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "INACTIVE")
PANGOLIN_STATUS=$(systemctl is-active newt 2>/dev/null)
UPTIME=$(uptime -p)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
MEM=$(free -h | awk '/^Mem/ {print $3 "/" $2}')
DISK=$(df -h | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|udev|none|overlay|shm)/ {printf "  %-30fs %-8s %-8s %-8s %s\n", $6, $2, $3, $4, $5}')
SSH_SESSIONS=$(who | wc -l)
K3S_PODS=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/k3s kubectl get pods -A --no-headers 2>/dev/null | awk '{printf "  %-20s %-45s %-10s %s\n", $1, $2, $4, $3}' || echo "  k3s unavailable")
K3S_PODS=${K3S_PODS:-  "(no pods running)"}
K3S_NODES=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null | awk '{printf "  %-25s %-10s %s\n", $1, $2, $5}' || echo "  k3s unavailable")
K3S_NODES=${K3S_NODES:-  "(no nodes found)"}
LAST_LOGIN=$(last -2 "$USER" 2>/dev/null | awk 'NR==2 {print $3, $4, $5, $6, $7}')
LAST_LOGIN=${LAST_LOGIN:-  "no previous login found"}
LAST_REBOOT=$(who -b | awk '{print $3, $4}')
PUBLIC_IP=$(curl -sf --max-time 3 https://api.ipify.org || echo "unavailable")

# --- Colors ---
R=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
CYAN=$'\e[36m'
YELLOW=$'\e[33m'
GREEN=$'\e[32m'
RED=$'\e[31m'
WHITE=$'\e[97m'

SEP="${DIM}----------------------------------------------------------------${R}"

# Colorize service statuses
if [ "$PANGOLIN_STATUS" = "active" ]; then
    PANGOLIN_DISPLAY="${GREEN}${PANGOLIN_STATUS}${R}"
else
    PANGOLIN_DISPLAY="${RED}${PANGOLIN_STATUS}${R}"
fi

if [ "$NETBIRD_IP" = "INACTIVE" ]; then
    NETBIRD_DISPLAY="${RED}${NETBIRD_IP}${R}"
else
    NETBIRD_DISPLAY="${GREEN}${NETBIRD_IP}${R}"
fi

# --- Print Banner ---
cat <<EOF

${SEP}
  ${BOLD}${CYAN}SYSTEM${R}
${SEP}
  ${YELLOW}User:${R}        ${WHITE}$USER${R}
  ${YELLOW}Host:${R}        ${WHITE}$HOSTNAME${R}
  ${YELLOW}LAN IP:${R}      ${WHITE}$IP${R}
  ${YELLOW}Public IP:${R}   ${WHITE}$PUBLIC_IP${R}
  ${YELLOW}Uptime:${R}      ${WHITE}$UPTIME${R}
  ${YELLOW}Last Reboot:${R} ${WHITE}$LAST_REBOOT${R}
  ${YELLOW}Last Login:${R}  ${WHITE}$LAST_LOGIN${R}
  ${YELLOW}Sessions:${R}    ${WHITE}$SSH_SESSIONS active${R}

  ${YELLOW}CPU Load:${R}    ${WHITE}$LOAD1  $LOAD5  $LOAD15${R}  ${DIM}(1 / 5 / 15 min)${R}
  ${YELLOW}Memory:${R}      ${WHITE}$MEM${R}

${SEP}
  ${BOLD}${CYAN}SERVICES${R}
${SEP}
  ${YELLOW}NetBird IP:      ${R}$NETBIRD_DISPLAY
  ${YELLOW}Pangolin (Newt): ${R}$PANGOLIN_DISPLAY

${SEP}
  ${BOLD}${CYAN}DISK SPACE${R}
${SEP}
  ${DIM}MOUNT                          SIZE     USED     AVAIL    USE%${R}
$DISK
${SEP}
  ${BOLD}${CYAN}K3S NODES${R}
${SEP}
  ${DIM}NAME                      STATUS     VERSION${R}
$K3S_NODES
${SEP}
  ${BOLD}${CYAN}K3S PODS${R}
${SEP}
  ${DIM}NAMESPACE            NAME                                          STATUS     READY${R}
$K3S_PODS
${SEP}

EOF