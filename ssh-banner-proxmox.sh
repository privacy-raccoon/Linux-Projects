#!/bin/bash

# Please note, this is a personal banner that I'm find with being available publicly. Pangolin and Netbird are two reverse procxies that I am evaluating. 

# --- Gather dynamic info ---
USER=$(whoami)
HOSTNAME=$(uname -n)
IP=$(ip -4 addr show vmbr0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "INACTIVE")
PANGOLIN_STATUS=$(systemctl is-active newt 2>/dev/null || echo "unknown")
UPTIME=$(uptime -p)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
MEM=$(free -h | awk '/^Mem/ {print $3 "/" $2}')
DISK=$(df -h | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|udev|none|overlay|shm)/ {printf "  %-30s %-8s %-8s %-8s %s\n", $6, $2, $3, $4, $5}')
SSH_SESSIONS=$(who | wc -l)
LAST_LOGIN=$(last -2 "$USER" 2>/dev/null | awk 'NR==2 {print $3, $4, $5, $6, $7}')
LAST_LOGIN=${LAST_LOGIN:-"no previous login found"}
LAST_REBOOT=$(who -b | awk '{print $3, $4}')
PUBLIC_IP=$(curl -sf --max-time 3 https://api.ipify.org || echo "unavailable")
UPDATES=$(dnf check-update -q 2>/dev/null | grep -c '^[[:alnum:]]')
UPDATES=${UPDATES:-0}

QEMU_VMS=$(qm list 2>/dev/null | awk 'NR>1 {printf "  %-8s %-25s %-10s %s MB\n", $1, $2, $3, $4}')
QEMU_VMS=${QEMU_VMS:-  "(no VMs found)"}

LXC_CONTAINERS=$(pct list 2>/dev/null | awk 'NR>1 {printf "  %-8s %-10s %s\n", $1, $2, $3}')
LXC_CONTAINERS=${LXC_CONTAINERS:-  "(no containers found)"}

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

# Colorize VM/CT rows by status
QEMU_VMS_DISPLAY=$(echo "$QEMU_VMS" | sed \
    "s/\(.*running.*\)/${GREEN}\1${R}/" | sed \
    "s/\(.*stopped.*\)/${RED}\1${R}/")

LXC_DISPLAY=$(echo "$LXC_CONTAINERS" | sed \
    "s/\(.*running.*\)/${GREEN}\1${R}/" | sed \
    "s/\(.*stopped.*\)/${RED}\1${R}/")

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
  ${YELLOW}Updates:${R}     ${WHITE}$UPDATES pending${R}

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
  ${BOLD}${CYAN}QEMU VIRTUAL MACHINES${R}
${SEP}
  ${DIM}VMID     NAME                      STATUS     MEMORY${R}
$QEMU_VMS_DISPLAY
${SEP}
  ${BOLD}${CYAN}LXC CONTAINERS${R}
${SEP}
  ${DIM}VMID     STATUS     NAME${R}
$LXC_DISPLAY
${SEP}

EOF
