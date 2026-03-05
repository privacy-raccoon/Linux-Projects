#!/bin/bash

# This script will create an Rocky Linux 9 Cloud Init template
# Requires 'libguestfs-tools' package to be installed

# 4 vCPUs
# 4GB RAM
# 32GB storage on internal NVMe storage
# Configured for DHCP on LAN

############################################################
# Help                                                     #
############################################################
help()
{
   # Display Help
   cat << EOF
This script will create an Rocky Linux 9 virtual machine for use with Proxmox, configured via cloud-init, with the following specifications:

4 vCPUs
4GB RAM
32GB storage
Network configured for DHCP using vmbr1 interface in Proxmox

Syntax: debian.sh [-n <vm name>| -t <path to cloud-init template> | -h]

options:
h     Print this Help.
d     Specify name of Linux distro (ubuntu, rocky).
n     Specify name of Virtual Machine.
t     Specify path to cloud-init config file.
EOF
}


############################################################
# Process the input options.                               #
############################################################
custom_cloud_init_settings_path=""
vm_name=""

while getopts ":hn:t:" option; do
   case $option in
      h)
         help
         exit;;
      n)
         vm_name=$OPTARG;;
      t)
         if [ "${vm_name}" = "" || "${vm_name}" = "-t" ]
         then
            echo "No VM name was supplied. Please specify a name for the VM with \"-n your-vm-name\"".
            exit
         fi
         custom_cloud_init_settings_path=$OPTARG;;
     \?)
         echo "Invalid option. Please refer to the help section below."
         echo ""
         help
         exit;;
   esac
done

if [ $OPTIND -eq 1 ]; then 
echo "No options were passed. Please refer to the help section below."
echo ""
help
exit
fi

############################################################
# Main                                                     #
############################################################
# Set Constants
# Rename as required
id=$(pvesh get /cluster/nextid)

image_url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
image_path="/tmp/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
drive_name="WD-Black-SSD"

# Check if a VM name was supplied.
if [ "${vm_name}" = "" ]
then
    echo "No VM name was supplied. Please specify a name for the VM with \"-n your-vm-name\"".
    exit
fi

# Check if custom cloud-init config settings was supplied.
# If not, then use default values
if [ "${custom_cloud_init_settings_path}" = "" ]
then
    proxmox_cloud_init_snippet="user=local:snippets/rhel-cloud-init-settings.yml"
    cloud_init_settings_path="/var/lib/vz/snippets/rhel-cloud-init-settings.yml"
    
# If so, then use custom values
else
        # Check if the cloud-init config settings exist. Copy it to Proxmox local snippets folder. Quit the script if they do not.
    if ! [ -f ${custom_cloud_init_settings_path} ]; then
        echo "${custom_cloud_init_settings_path} does not exist. This file must exist for the script to complete successfully."
        exit
    fi
    echo $custom_cloud_init_settings_path
    cloud_init_settings_path="${custom_cloud_init_settings_path}"
    echo $cloud_init_settings_path
    /bin/cp -rf ${cloud_init_settings_path} /var/lib/vz/snippets/
    filename=$(printf "%s\n" "${cloud_init_settings_path##*/}")
    proxmox_cloud_init_snippet="user=local:snippets/${filename}"
    fi

# Remove any image that might have stuck around to make sure we're always using the latest image
rm ${image_path}

# Download new cloud-init image
wget ${image_url} -P /tmp/

# Create VM with specified options
qm create $id \
--name "$vm_name" \
--memory 4096 \
--cores 4 \
--cpu x86-64-v2-AES \
--scsihw virtio-scsi-single \
--agent enabled=1 \
--ostype l26 \
--net0 virtio,bridge=vmbr1,firewall=1

# Import the image and attach it as a SCSI drive, then resize it appropriately
qm set $id --scsi0 ${drive_name}:0,import-from=${image_path},ssd=1,iothread=1
qm resize $id scsi0 +30G

# Misc configs
qm set $id --ipconfig0 ip=dhcp
qm set $id --ide2 ${drive_name}:cloudinit
qm set $id --boot order=scsi0
qm set $id --serial0 socket --vga serial0
qm set $id --cicustom ${proxmox_cloud_init_snippet}

# Cleanup
rm ${image_path}