#!/bin/bash

printf "This script will help you create a VM in Proxmox\n"
printf "with easy to navigate menus."

########################################
# Configuration — edit to match your environment
########################################
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MEMORY=4096
DEFAULT_CORES=4
DEFAULT_CPU="x86-64-v2-AES"
DEFAULT_DISK_SIZE="32G"

########################################
# Supported distros
# Add entries here to support additional images.
# Verify URLs against official distribution sources before use.
########################################
declare -A DISTRO_URL DISTRO_FILE DISTRO_SNIPPET

DISTRO_URL[rocky9]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
DISTRO_FILE[rocky9]="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
DISTRO_SNIPPET[rocky9]="rhel-cloud-init-settings.yml"

DISTRO_URL[rocky10]="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
DISTRO_FILE[rocky10]="Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
DISTRO_SNIPPET[rocky10]="rhel-cloud-init-settings.yml"

DISTRO_URL[debian12]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
DISTRO_FILE[debian12]="debian-12-genericcloud-amd64.qcow2"
DISTRO_SNIPPET[debian12]="debian-cloud-init-settings.yml"

DISTRO_URL[debian13]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DISTRO_FILE[debian13]="debian-13-genericcloud-amd64.qcow2"
DISTRO_SNIPPET[debian13]="debian-cloud-init-settings.yml"

DISTRO_URL[ubuntu2404]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
DISTRO_FILE[ubuntu2404]="noble-server-cloudimg-amd64.img"
DISTRO_SNIPPET[ubuntu2404]="debian-cloud-init-settings.yml"

########################################
# Help
########################################
help() {
    cat << EOF
Creates a Proxmox VM from a cloud image, configured via cloud-init.

Default specs: ${DEFAULT_CORES} vCPUs | ${DEFAULT_MEMORY} MiB RAM | ${DEFAULT_DISK_SIZE} disk

Syntax: $(basename "$0") -d <distro> -n <vm name> [-t <cloud-init config>] [-s <storage>] [-b <bridge>] [-h]

Options:
  -d    Distro to use. Supported values:
            rocky9       Rocky Linux 9
            rocky10      Rocky Linux 10
            debian12     Debian 12 (Bookworm)
            debian13     Debian 13 (Trixie)
            ubuntu2404   Ubuntu 24.04 LTS (Noble)
  -n    Name for the VM.
  -t    Path to a cloud-init config file. Defaults to the distro's built-in snippet.
  -s    Proxmox storage target. Default: ${DEFAULT_STORAGE}
  -b    Network bridge. Default: ${DEFAULT_BRIDGE}
  -h    Print this help.
EOF
}

########################################
# Parse options
########################################
distro=""
vm_name=""
custom_cloud_init_path=""
storage="${DEFAULT_STORAGE}"
bridge="${DEFAULT_BRIDGE}"

while getopts ":hd:n:t:s:b:" option; do
    case $option in
        h)
            help
            exit 0;;
        d)
            distro=$OPTARG;;
        n)
            vm_name=$OPTARG;;
        t)
            custom_cloud_init_path=$OPTARG;;
        s)
            storage=$OPTARG;;
        b)
            bridge=$OPTARG;;
        :)
            echo "Error: Option -${OPTARG} requires an argument. See -h for usage."
            exit 1;;
        \?)
            echo "Error: Invalid option -${OPTARG}. See -h for usage."
            exit 1;;
    esac
done

if [ $OPTIND -eq 1 ]; then
    echo "No options provided. See -h for usage."
    exit 1
fi

########################################
# Validate inputs
########################################
if [ -z "${vm_name}" ]; then
    echo "Error: VM name is required. Use -n to specify one."
    exit 1
fi

if [ -z "${distro}" ]; then
    echo "Error: Distro is required. Use -d to specify one."
    exit 1
fi

if [ -z "${DISTRO_URL[$distro]+_}" ]; then
    echo "Error: Unsupported distro '${distro}'. Supported values: ${!DISTRO_URL[@]}"
    exit 1
fi

########################################
# Resolve cloud-init snippet
########################################
if [ -n "${custom_cloud_init_path}" ]; then
    if [ ! -f "${custom_cloud_init_path}" ]; then
        echo "Error: Cloud-init config not found: ${custom_cloud_init_path}"
        exit 1
    fi
    cp -f "${custom_cloud_init_path}" /var/lib/vz/snippets/
    snippet_file=$(basename "${custom_cloud_init_path}")
else
    snippet_file="${DISTRO_SNIPPET[$distro]}"
    if [ ! -f "/var/lib/vz/snippets/${snippet_file}" ]; then
        echo "Error: Default cloud-init snippet not found: /var/lib/vz/snippets/${snippet_file}"
        exit 1
    fi
fi

proxmox_cicustom="user=local:snippets/${snippet_file}"

########################################
# Main
########################################
id=$(pvesh get /cluster/nextid)
image_url="${DISTRO_URL[$distro]}"
image_file="${DISTRO_FILE[$distro]}"
image_path="/tmp/${image_file}"

# Download fresh image
rm -f "${image_path}"
wget "${image_url}" -P /tmp/

# Create VM
qm create "$id" \
    --name "${vm_name}" \
    --memory ${DEFAULT_MEMORY} \
    --cores ${DEFAULT_CORES} \
    --cpu ${DEFAULT_CPU} \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --ostype l26 \
    --net0 virtio,bridge=${bridge},firewall=0

# Import disk and resize
qm set "$id" --scsi0 ${storage}:0,import-from=${image_path},ssd=1,iothread=1
qm resize "$id" scsi0 ${DEFAULT_DISK_SIZE}

# Apply remaining config
qm set "$id" --ipconfig0 ip=dhcp
qm set "$id" --ide2 ${storage}:cloudinit
qm set "$id" --boot order=scsi0
qm set "$id" --serial0 socket --vga serial0
qm set "$id" --cicustom "${proxmox_cicustom}"

# Cleanup
rm -f "${image_path}"
