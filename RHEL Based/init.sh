#!/bin/bash
set -euo pipefail

# -------------------------
# Global Variables
# -------------------------

username=""
org_name=""
SSH_Port=2222

# -------------------------
# Global Constants
# -------------------------

readonly Sysctl_Config="/etc/sysctl.d/99-hardening.conf"
readonly SSH_Config="/etc/ssh/sshd_config.d/99-hardening.conf"
readonly Fail2ban_SSH_Config="/etc/fail2ban/jail.d/sshd.conf"
readonly Audit_Rules="/etc/audit/rules.d/99-hardening.rules"
readonly Shm_Dropin="/etc/systemd/system/dev-shm.mount.d/hardening.conf"
readonly Module_Blacklist="/etc/modprobe.d/99-hardening.conf"
readonly Sudoers_Drop="/etc/sudoers.d/99-hardening"
readonly Umask_Profile="/etc/profile.d/hardening.sh"
readonly Br_Netfilter_Conf="/etc/modules-load.d/br_netfilter.conf"
readonly Journald_Config="/etc/systemd/journald.conf.d/99-hardening.conf"
readonly Logrotate_Config="/etc/logrotate.d/hardening"

# -------------------------
# Functions
# -------------------------

# Print an error message to stderr and exit.
die() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

# Abort if not running as root.
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "This script must be run with sudo or as root.\n"
        exit 1
    fi
}

# Display a summary of changes and require explicit acceptance before proceeding.
accept_terms() {
    printf "This script will make the following changes to this system:\n\n"
    printf "  Packages\n"
    printf "    Install fail2ban, auditd, AIDE, Lynis, and convenience utilities\n"
    printf "    Enable automatic security updates via dnf-automatic\n\n"
    printf "  SSH\n"
    printf "    Disable password auth, restrict to key-only on a custom port\n"
    printf "    Restrict ciphers, MACs, and key exchange algorithms\n\n"
    printf "  System hardening\n"
    printf "    Harden PAM faillock and password quality requirements\n"
    printf "    Apply kernel sysctl hardening and container networking tunables\n"
    printf "    Blacklist unused filesystem modules; harden /dev/shm\n"
    printf "    Set umask 027 and enforce a 15-minute idle session timeout\n\n"
    printf "  Firewall and access control\n"
    printf "    Configure firewalld; register SSH port with SELinux\n"
    printf "    Restrict su to wheel group; log all sudo invocations\n\n"
    printf "  Auditing and monitoring\n"
    printf "    Write auditd rules covering auth, privileges, identity, and containers\n"
    printf "    Schedule daily AIDE integrity checks and Lynis security audits\n"
    printf "    Set a 6 month default data retention for logs and audit files\n\n"
    printf "These changes are intended for a fresh system. Running this script on a\n"
    printf "production system without a prior snapshot or backup is not recommended.\n\n"
    printf "Do you accept and wish to continue? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            printf "Proceeding with hardening.\n"
            ;;
        *)
            printf "Aborting.\n"
            exit 1
            ;;
    esac
}

# Resolve the target username from $SUDO_USER or prompt if run directly as root.
# Loops until a valid, existing username is provided or the user aborts.
get_username() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        username="${SUDO_USER}"
        return 0
    fi
    while true; do
        printf "Please enter your username (or 'abort' to exit): "
        read -r username
        if [ -z "${username}" ]; then
            printf "Username cannot be empty.\n"
        elif [ "${username}" = "abort" ]; then
            printf "Aborting.\n"
            exit 1
        elif id "${username}" &>/dev/null; then
            break
        else
            printf "User '%s' does not exist on this system.\n" "${username}"
        fi
    done
}

# Warn and prompt to continue if SELinux is not in Enforcing mode.
# Offers to enable Enforcing immediately (Permissive) or via config + reboot (Disabled).
check_selinux() {
    local state selinux_config
    state=$(getenforce 2>/dev/null || printf "Unknown")
    selinux_config="/etc/selinux/config"

    if [ "${state}" = "Enforcing" ]; then
        printf "SELinux is enforcing.\n"
        return 0
    fi
    printf "WARNING: SELinux is %s. It should be Enforcing for a hardened system.\n" "${state}"
    printf "Continuing without SELinux enforcing significantly reduces system security.\n\n"
    printf "Options:\n"
    printf "  enable   Set SELinux to Enforcing\n"
    printf "  skip     Continue without enabling SELinux Enforcing (not recommended)\n"
    printf "  abort    Exit the script\n"
    printf "> "
    read -r choice
    case "${choice}" in
        enable)
            sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "${selinux_config}"
            if [ "${state}" = "Disabled" ]; then
                printf "SELinux was Disabled. Config updated to Enforcing — a reboot is required.\n"
                printf "Reboot and re-run this script to continue.\n"
                exit 0
            else
                setenforce 1
                printf "SELinux set to Enforcing.\n"
            fi
            ;;
        skip)
            printf "Continuing with SELinux %s...\n" "${state}"
            ;;
        *)
            printf "Aborting.\n"
            exit 1
            ;;
    esac
}

# Confirm Rocky Linux 10 or RHEL 10. Warn and prompt to continue on any other OS.
check_os() {
    local id version_id
    # shellcheck disable=SC1091
    id=$(. /etc/os-release 2>/dev/null && printf "%s" "${ID}")
    # shellcheck disable=SC1091,SC2153
    version_id=$(. /etc/os-release 2>/dev/null && printf "%s" "${VERSION_ID}")
    if [[ "${id}" =~ ^(rocky|rhel)$ ]] && [[ "${version_id}" == 10* ]]; then
        printf "Welcome %s, thanks for running this neat script.\n" "${username}"
    else
        printf "WARNING: This operating system is NOT Rocky Linux 10 or RHEL 10.\n"
        printf "This script was designed specifically for Rocky Linux 10 or RHEL 10.\n"
        printf "It may work on other RHEL based systems, but there are no guarantees.\n"
        printf "Do not attempt to run this script on non-RHEL based systems.\n\n"

        printf "Would you like to continue anyway? (y/N): "
        read -r choice

        case "${choice}" in
            y|Y|yes|YES)
                printf "Continuing despite OS mismatch...\n"
                ;;
            *)
                printf "Aborting.\n"
                exit 1
                ;;
        esac
    fi
}

# Warn and prompt to continue if no supported disk encryption is detected.
# Checks for LUKS (dm-crypt) and ZFS native encryption.
check_disk_encryption() {
    printf "Checking for disk encryption...\n"
    if lsblk -o TYPE 2>/dev/null | grep -q "^crypt$"; then
        printf "Disk encryption detected (LUKS).\n"
        return 0
    fi
    if command -v zfs &>/dev/null && zfs list -H -o encryption 2>/dev/null | grep -qEv "^(off|-)$"; then
        printf "Disk encryption detected (ZFS native encryption).\n"
        return 0
    fi
    printf "WARNING: No disk encryption detected.\n"
    printf "Running this hardening script without disk encryption leaves data at rest unprotected.\n\n"
    printf "Would you like to continue anyway? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            printf "Continuing without disk encryption...\n"
            ;;
        *)
            printf "Aborting.\n"
            exit 1
            ;;
    esac
}

# Verify an authorized_keys entry exists for the user before disabling password auth.
# Loops until a key is found, or the user explicitly skips or aborts.
check_ssh_key() {
    local auth_keys="/home/${username}/.ssh/authorized_keys"
    while true; do
        if [ -s "${auth_keys}" ]; then
            printf "SSH authorized_keys found for %s.\n" "${username}"
            return 0
        fi
        printf "WARNING: No SSH authorized_keys found for %s at %s.\n" "${username}" "${auth_keys}"
        printf "Disabling password authentication without a key will lock you out.\n\n"
        printf "Options:\n"
        printf "  [Enter]  Add your key now, then press Enter to check again\n"
        printf "  skip     Continue without a confirmed key (dangerous)\n"
        printf "  abort    Exit the script\n"
        printf "> "
        read -r choice
        case "${choice}" in
            skip)
                printf "Continuing without confirmed SSH key...\n"
                return 0
                ;;
            abort)
                printf "Aborting.\n"
                exit 1
                ;;
            *)
                printf "Checking again...\n"
                ;;
        esac
    done
}

# Check for a bootloader password and offer to set one if absent.
# systemd-boot has no password mechanism; UEFI Secure Boot is the equivalent control.
check_grub_password() {
    # systemd-boot doesn't support bootloader passwords.
    if bootctl is-installed &>/dev/null; then
        printf "systemd-boot detected. Bootloader passwords are not supported.\n"
        printf "Ensure UEFI Secure Boot is enabled for equivalent boot-time protection.\n"
        return 0
    fi

    local user_cfg="/boot/grub2/user.cfg"
    if [ -f "${user_cfg}" ] && grep -q "GRUB2_PASSWORD" "${user_cfg}"; then
        printf "GRUB2 bootloader password is set.\n"
        return 0
    fi
    printf "WARNING: No GRUB2 bootloader password is set.\n"
    printf "Without one, anyone with console access can edit boot entries or boot\n"
    printf "to single-user mode and get a root shell, bypassing all other hardening.\n\n"
    printf "Would you like to set a GRUB password now? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            grub2-setpassword
            ;;
        *)
            printf "Skipping GRUB password. Console access to this VM is not restricted.\n"
            ;;
    esac
}

# Optionally override the default SSH port; validates the chosen port is outside the well-known range (0-1023).
configure_ssh_port() {
    printf "This script configures SSH on an alternative port as a basic security option. By default it is %s.\n" "${SSH_Port}"
    printf "The default option is fine, but still a well known alternative port.\n\n"
    printf "Options:\n"
    printf "  [Enter]  Keep default (%s)\n" "${SSH_Port}"
    printf "  random   Generate a random port\n"
    printf "  custom   Enter a custom port\n"
    printf "> "
    read -r choice
    case "${choice}" in
        random)
            SSH_Port=$(shuf -i 1024-65535 -n 1)
            printf "Random port selected: %s\n" "${SSH_Port}"
            ;;
        custom)
            while true; do
                printf "Please enter your preferred SSH port (1024-65535): "
                read -r SSH_Port
                if ! [[ "${SSH_Port}" =~ ^[0-9]+$ ]] || [ "${SSH_Port}" -gt 65535 ]; then
                    printf "Invalid port number. Must be between 1024 and 65535.\n"
                elif [ "${SSH_Port}" -le 1023 ]; then
                    printf "Well-known ports (0-1023) are not allowed. Please choose a port between 1024 and 65535.\n"
                else
                    break
                fi
            done
            ;;
        *)
            printf "Keeping default port.\n"
            ;;
    esac
    printf "Continuing with SSH port %s.\n" "${SSH_Port}"
}

# Prompt for the organization name used in the login banner.
get_org_name() {
    while true; do
        printf "Please enter the name of the organization or person that owns this server: "
        read -r org_name
        if [ -z "${org_name}" ]; then
            printf "Organization name cannot be empty.\n"
        else
            break
        fi
    done
}

# Write the legal warning banner to /etc/issue.net (SSH) and /etc/issue (console).
configure_banner() {
    cat <<EOF > /etc/issue.net

*******************************************************************************
                          AUTHORIZED ACCESS ONLY

  This system is the property of ${org_name}. Access is restricted to
  authorized users only. All activity on this system is monitored and
  logged. Unauthorized access is strictly prohibited and may be subject
  to civil and criminal penalties.

  By continuing, you consent to this monitoring.
*******************************************************************************

EOF
    cp /etc/issue.net /etc/issue
}

# Add the CISOfy repository so Lynis can be installed via dnf.
configure_lynis_repo() {
    cat <<EOF > /etc/yum.repos.d/lynis.repo
[lynis]
name=CISOfy Software - Lynis package
baseurl=https://packages.cisofy.com/community/lynis/rpm/
enabled=1
gpgkey=https://packages.cisofy.com/keys/cisofy-software-rpms-public.key
gpgcheck=1
priority=2
EOF
}

# Update the system, enable EPEL/CRB, and install security and convenience packages.
install_packages() {
    printf "Updating system.\n"
    dnf -y update

    printf "Installing and enabling Extra Packages for Enterprise Linux.\n"
    dnf -y install epel-release
    /usr/bin/crb enable

    printf "Updating repositories after enabling EPEL.\n"
    dnf -y update

    printf "Installing security packages.\n"
    printf "rkhunter and tripwire are not yet available in EPEL 10."
    printf "Lynis (via CISOfy repo) and AIDE are used instead for security auditing and rootkit checks."
    dnf -y install \
        kernel-headers qemu-guest-agent util-linux-user dnf-automatic \
        fail2ban \
        audit audispd-plugins aide lynis \
        container-selinux

    printf "Installing personal/convenience packages.\n"
    dnf -y install \
        python3 python3-pip \
        git nmon fastfetch zsh ncdu wget nano btop
}

# Configure dnf-automatic to apply security updates, with optional automatic reboots.
configure_auto_updates() {
    local config_file="/etc/dnf/automatic.conf"
    if grep -q "# Hardening configured" "${config_file}" 2>/dev/null; then
        printf "dnf-automatic already configured, skipping.\n"
        return 0
    fi
    local reboot_policy
    printf "Should the system automatically reboot after security updates that require it? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            reboot_policy="when-needed"
            printf "Automatic reboots enabled when required by updates.\n"
            ;;
        *)
            reboot_policy="never"
            printf "Automatic reboots disabled. You will need to reboot manually after kernel updates.\n"
            ;;
    esac

    printf "Configuring automatic security updates.\n"
    cp "${config_file}" "${config_file}.bak"
    sed -i \
        -e 's/upgrade_type = default/upgrade_type = security/g' \
        -e 's/apply_updates = no/apply_updates = yes/g' \
        -e "s/reboot = never/reboot = ${reboot_policy}/g" \
        "${config_file}"
    echo "# Hardening configured" >> "${config_file}"
}

# Harden faillock: lock accounts after 5 failures, 10-minute unlock, applies to root.
configure_pam() {
    if grep -q "# Hardening overrides" /etc/security/faillock.conf; then
        printf "PAM faillock already configured, skipping.\n"
        return 0
    fi
    cp /etc/security/faillock.conf /etc/security/faillock.conf.bak
    cat <<EOF >> /etc/security/faillock.conf

# Hardening overrides
deny = 5
unlock_time = 600
fail_interval = 900
even_deny_root
audit
EOF
    grep -q "# Hardening overrides" /etc/security/faillock.conf || die "Failed to apply PAM faillock settings."
}

# Set up fail2ban with systemd backend and an aggressive SSH jail on the configured port.
configure_fail2ban() {
    if [ ! -f /etc/fail2ban/jail.local ]; then
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        sed -i 's/backend = auto/backend = systemd/g' /etc/fail2ban/jail.local
    fi
    cat <<EOF > "${Fail2ban_SSH_Config}"
[sshd]
enabled = true
port = ${SSH_Port}
mode = aggressive
EOF
}

# Write a hardened sshd drop-in: key-only auth, no root login, restricted ciphers/MACs.
configure_ssh() {
    cat <<EOF > "${SSH_Config}"
Port ${SSH_Port}
Banner /etc/issue.net
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
HostbasedAuthentication no
IgnoreRhosts yes
PasswordAuthentication no
PermitEmptyPasswords no
PermitUserEnvironment no
UsePAM yes
LogLevel VERBOSE
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
AllowUsers ${username}
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
# "local" permits ssh -L tunneling (e.g. tunneling kubectl to port 6443) while
# blocking reverse forwarding (ssh -R). Set to "no" if this server is not managed
# remotely via SSH tunnels.
AllowTcpForwarding local
Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOF
}

# Load br_netfilter and persist it so bridge traffic is visible to iptables at boot.
configure_kernel_modules() {
    printf "Loading br_netfilter kernel module for container networking.\n"
    modprobe br_netfilter
    echo "br_netfilter" > "${Br_Netfilter_Conf}"
}

# Write kernel hardening and container networking tunables to a sysctl drop-in.
configure_sysctl() {
    cat <<EOF > "${Sysctl_Config}"
# Required for container networking (Docker, K3s, K8s)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Required for Kubernetes CNI networking (all CNI plugins depend on this)
# br_netfilter module must be loaded before these take effect (see configure_kernel_modules)
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# rp_filter=2 (loose mode). Some CNI plugins (e.g. Calico) use asymmetric routing
# and may require rp_filter=0 on specific interfaces. If pod networking misbehaves,
# check this setting first.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_messages = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
# Disable acceptance of IPv6 router advertisements — a rogue RA can silently
# reroute all traffic on the local network segment
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
fs.suid_dumpable = 0
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
# Prevent unprivileged processes from attaching a debugger to processes they
# don't own. Critical on a container host where many UIDs share the same kernel.
kernel.yama.ptrace_scope = 1

# Container and Kubernetes operational tunables
# K8s watches many files per pod; defaults are too low on busy nodes
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
# Required by Elasticsearch and similar JVM-based containers
vm.max_map_count = 262144
# Reboot automatically 10s after a kernel panic (common K8s recommendation)
kernel.panic = 10
kernel.panic_on_oops = 1
EOF
}

# Optionally open firewall ports for Docker, K3s single-node, or K3s/K8s multi-node.
configure_container_firewall() {
    printf "Will this server run containerized workloads? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES) ;;
        *) return 0 ;;
    esac

    printf "Select workload type:\n"
    printf "  1) Docker standalone\n"
    printf "  2) K3s single-node\n"
    printf "  3) K3s/K8s multi-node (server/control-plane)\n"
    printf "  4) K3s/K8s multi-node (agent/worker)\n"
    printf "> "
    read -r workload

    case "${workload}" in
        1)
            printf "NOTE: Docker bypasses firewalld by writing iptables rules directly.\n"
            printf "Ports exposed via -p will be publicly reachable regardless of firewalld rules.\n"
            printf "See after_first_login.txt for mitigation options.\n"
            ;;
        2)
            firewall-cmd --add-port=6443/tcp --permanent   # K8s API server
            firewall-cmd --add-port=10250/tcp --permanent  # Kubelet
            firewall-cmd --add-port=8472/udp --permanent   # Flannel VXLAN
            firewall-cmd --add-port=51820/udp --permanent  # WireGuard (K3s default)
            printf "Opened K3s single-node ports (6443, 10250, 8472/udp, 51820/udp).\n"
            ;;
        3)
            firewall-cmd --add-port=6443/tcp --permanent   # K8s API server
            firewall-cmd --add-port=10250/tcp --permanent  # Kubelet
            firewall-cmd --add-port=8472/udp --permanent   # Flannel VXLAN
            firewall-cmd --add-port=51820/udp --permanent  # WireGuard
            firewall-cmd --add-port=2379-2380/tcp --permanent  # etcd (HA)
            firewall-cmd --add-port=30000-32767/tcp --permanent  # NodePort range
            printf "Opened K3s/K8s control-plane ports.\n"
            ;;
        4)
            firewall-cmd --add-port=10250/tcp --permanent  # Kubelet
            firewall-cmd --add-port=8472/udp --permanent   # Flannel VXLAN
            firewall-cmd --add-port=51820/udp --permanent  # WireGuard
            firewall-cmd --add-port=30000-32767/tcp --permanent  # NodePort range
            printf "Opened K3s/K8s worker node ports.\n"
            ;;
        *)
            printf "Unrecognised option, no container ports opened. Open them manually with firewall-cmd.\n"
            ;;
    esac
}

# Register the SSH port with SELinux, open it in firewalld, and remove default services.
configure_firewall() {
    semanage port -a -t ssh_port_t -p tcp "${SSH_Port}" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "${SSH_Port}"
    firewall-cmd --add-port="${SSH_Port}/tcp" --permanent
    firewall-cmd --remove-service=cockpit --permanent 2>/dev/null || true
    firewall-cmd --remove-service=ssh --permanent 2>/dev/null || true
    firewall-cmd --remove-service=dhcpv6-client --permanent 2>/dev/null || true
    firewall-cmd --reload
}

# Write a post-login reference guide to the user's home directory.
write_post_login_guide() {
    cat <<EOF > "/home/${username}/after_first_login.txt"
# -------------------------
# Oh-My-ZSH
# -------------------------
# Completely optional, but it's my personal favorite config.

# Use "curl -fsSL" to download this script: https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
# Or just grab it from their website directly
# Then run "sh -c /path/to/install.sh" and the following commands:
sed -i 's/robbyrussell/ys/' ~/.zshrc
sed -i 's/plugins=(git)/plugins=(colored-man-pages colorize cp safe-paste git)/' ~/.zshrc
sed -i '/export ZSH="\$HOME\/.oh-my-zsh"/a\export PATH=\$PATH:/home/${username}/.local/bin' ~/.zshrc

# -------------------------
# Container Workloads
# -------------------------

# K3s SELinux policy (requires Rancher repo — install BEFORE installing K3s):
#   dnf install -y container-selinux
#   rpm -i https://github.com/k3s-io/k3s-selinux/releases/latest/download/k3s-selinux.rpm
#   (or add the Rancher repo and install k3s-selinux via dnf)
#   Without this, SELinux will deny K3s operations at runtime.

# Docker + firewalld WARNING:
#   Docker writes iptables rules directly and BYPASSES firewalld.
#   Any port exposed with -p will be publicly reachable regardless of firewall-cmd rules.
#   To prevent this, add the following to /etc/docker/daemon.json:
#     { "iptables": false }
#   Then manage all Docker traffic routing manually via firewalld/nftables.
#   This requires more effort but keeps all port control in one place.

# br_netfilter — verify it is active before starting any container workload:
#   lsmod | grep br_netfilter
#   sysctl net.bridge.bridge-nf-call-iptables   # should be 1
#   sysctl net.bridge.bridge-nf-call-ip6tables  # should be 1
#   If missing, run: modprobe br_netfilter && sysctl --system

# Calico CNI / rp_filter:
#   rp_filter is set to 2 (loose mode). Calico uses asymmetric routing and may
#   require rp_filter=0 on specific interfaces. If pod networking misbehaves:
#     sysctl net.ipv4.conf.all.rp_filter        # check current value
#     sysctl -w net.ipv4.conf.<iface>.rp_filter=0   # loosen per-interface if needed

# SSH TCP forwarding:
#   AllowTcpForwarding is set to "local", which permits ssh -L tunneling
#   (e.g. tunneling kubectl to the K8s API on port 6443). If you do not need
#   remote SSH tunneling, harden further by changing it to "no" in:
#     /etc/ssh/sshd_config.d/99-hardening.conf
#   then restart sshd: systemctl restart sshd

# umask 027 and container tooling:
#   The system-wide umask is set to 027. Some container tools (Helm, K3s
#   auto-deploy manifests at /var/lib/rancher/k3s/server/manifests/, container
#   build contexts) expect world- or group-readable files and may fail with
#   EACCES. If you see unexpected permission errors from container tooling,
#   check whether umask is the cause before loosening other controls.

# Audit log — container socket access:
#   Access to /var/run/docker.sock and /run/k3s/containerd/containerd.sock is
#   logged under the key "container_socket". These sockets grant effective root
#   access to the host. Review regularly:
#     ausearch -k container_socket | aureport -f -i

# Automatic security updates and running containers:
#   dnf-automatic is configured to apply security updates automatically.
#   If automatic reboots are enabled, a kernel update will restart the host
#   and bring down all running containers. Plan for this in your workload
#   availability strategy, or disable auto-reboot and handle reboots manually.
EOF
    chown "${username}:" "/home/${username}/after_first_login.txt"
}

# Blacklist uncommon filesystems
configure_module_blacklist() {
    cat <<EOF > "${Module_Blacklist}"
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install udf /bin/false
EOF
    printf "Unused filesystem modules blacklisted.\n"
}

# Mount /dev/shm with nodev, nosuid, noexec via a systemd drop-in override.
configure_shm_hardening() {
    # Rocky Linux 10 uses systemd to manage /dev/shm via dev-shm.mount.
    # An fstab entry is overridden by the systemd unit at boot, so we use a
    # drop-in override instead.
    mkdir -p "$(dirname "$Shm_Dropin")"
    cat <<EOF > "${Shm_Dropin}"
[Mount]
Options=defaults,nodev,nosuid,noexec
EOF
    systemctl daemon-reload
    if systemctl restart dev-shm.mount 2>/dev/null; then
        printf "/dev/shm hardened with nodev,nosuid,noexec via systemd drop-in.\n"
    else
        mount -o remount,nodev,nosuid,noexec /dev/shm
        printf "/dev/shm hardened with nodev,nosuid,noexec (remounted directly; drop-in takes effect on next boot).\n"
    fi
}

# Add a sudoers drop-in that logs all sudo invocations to /var/log/sudo.log.
configure_sudo_log() {
    if [ -f "$Sudoers_Drop" ]; then
        printf "sudo hardening drop-in already exists, skipping.\n"
        return 0
    fi
    cat <<EOF > "${Sudoers_Drop}"
Defaults logfile=/var/log/sudo.log
EOF
    chmod 0440 "${Sudoers_Drop}"
    # Validate before leaving it in place
    visudo -cf "${Sudoers_Drop}" || { rm -f "${Sudoers_Drop}"; die "sudo drop-in failed visudo check."; }
    printf "sudo audit log configured at /var/log/sudo.log.\n"
}

# Restrict su to members of the wheel group via pam_wheel.
configure_su_restriction() {
    local su_pam="/etc/pam.d/su"
    # Rocky Linux ships the pam_wheel line commented out — uncomment it.
    # If it's already active, do nothing.
    if grep -qE "^auth\s+required\s+pam_wheel" "${su_pam}"; then
        printf "su wheel restriction already active, skipping.\n"
        return 0
    fi
    cp "${su_pam}" "${su_pam}.bak"
    sed -i 's/^#\(auth\s\+required\s\+pam_wheel\.so use_uid\)/\1/' "${su_pam}"
    # If the sed didn't match (non-standard file), append it explicitly
    if ! grep -qE "^auth\s+required\s+pam_wheel" "${su_pam}"; then
        echo "auth    required    pam_wheel.so use_uid" >> "${su_pam}"
    fi
    printf "su restricted to wheel group.\n"
}

# Configure auditd disk-space actions: email on low space, suspend on critical, keep logs.
configure_auditd_conf() {
    local conf="/etc/audit/auditd.conf"
    if grep -q "^space_left_action = email" "${conf}" 2>/dev/null; then
        printf "auditd.conf already configured, skipping.\n"
        return 0
    fi
    cp "${conf}" "${conf}.bak"
    sed -i \
        -e 's/^space_left_action.*/space_left_action = email/' \
        -e 's/^admin_space_left_action.*/admin_space_left_action = suspend/' \
        -e 's/^action_mail_acct.*/action_mail_acct = root/' \
        -e 's/^max_log_file_action.*/max_log_file_action = keep_logs/' \
        "${conf}"
    printf "auditd.conf disk space actions configured.\n"
}

# Write audit rules covering auth, privilege use, identity files, time, modules, and containers.
configure_auditd() {
    cat <<EOF > "${Audit_Rules}"
# Auth events
-w /var/log/lastlog -p wa -k auth
-w /var/run/faillock -p wa -k auth

# Privileged commands
-a always,exit -F path=/usr/bin/sudo -F perm=x -k privileged
-a always,exit -F path=/usr/bin/su -F perm=x -k privileged
-a always,exit -F path=/usr/bin/passwd -F perm=x -k privileged
-a always,exit -F path=/usr/sbin/useradd -F perm=x -k privileged
-a always,exit -F path=/usr/sbin/usermod -F perm=x -k privileged
-a always,exit -F path=/usr/sbin/userdel -F perm=x -k privileged

# SSH key file changes
-w /home/${username}/.ssh/authorized_keys -p wa -k ssh_keys

# Sensitive file access
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d -p wa -k identity

# Systemctl invocations
-a always,exit -F path=/usr/bin/systemctl -F perm=x -k systemctl

# Time change events
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-a always,exit -F arch=b32 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# Kernel module loading and unloading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

# Login and logout events
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins
-w /var/run/utmp -p wa -k session

# Discretionary access control changes
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod

# Network environment changes
-w /etc/hosts -p wa -k network
-w /etc/hostname -p wa -k network

# Container runtime socket access (grants effective root — treat as high privilege)
-w /var/run/docker.sock -p rwxa -k container_socket
-w /run/k3s/containerd/containerd.sock -p rwxa -k container_socket

# Make rules immutable until reboot
-e 2
EOF
}

# Configure log retention to keep 6 months of logs across journald, auditd, and logrotate.
configure_log_retention() {
    # journald: retain logs for up to 6 months, cap total disk usage
    mkdir -p "$(dirname "${Journald_Config}")"
    cat <<EOF > "${Journald_Config}"
[Journal]
MaxRetentionSec=6month
SystemMaxUse=500M
SystemKeepFree=100M
EOF

    # auditd: rotate logs and keep 26 files (~6 months at the default biweekly rotation rate)
    # Override keep_logs (set in configure_auditd_conf) with rotate to enforce deletion.
    local auditd_conf="/etc/audit/auditd.conf"
    sed -i 's/^max_log_file_action.*/max_log_file_action = rotate/' "${auditd_conf}"
    if grep -q "^num_logs" "${auditd_conf}"; then
        sed -i 's/^num_logs.*/num_logs = 26/' "${auditd_conf}"
    else
        echo "num_logs = 26" >> "${auditd_conf}"
    fi

    # logrotate: 6-month retention for script-managed logs not covered by journald
    cat <<EOF > "${Logrotate_Config}"
/var/log/sudo.log
/var/log/fail2ban.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
    printf "Log retention configured: 6 months (journald, auditd, logrotate).\n"
}

# Enforce a 14-character minimum password length with digit, upper, lower, and symbol requirements.
configure_pwquality() {
    if grep -q "# Hardening overrides" /etc/security/pwquality.conf; then
        printf "pwquality already configured, skipping.\n"
        return 0
    fi
    cp /etc/security/pwquality.conf /etc/security/pwquality.conf.bak
    cat <<EOF >> /etc/security/pwquality.conf

# Hardening overrides
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
EOF
    grep -q "# Hardening overrides" /etc/security/pwquality.conf || die "Failed to apply pwquality settings."
}

# Set system-wide umask to 027 and enforce a 15-minute idle session timeout.
configure_umask() {
    cat <<EOF > "${Umask_Profile}"
# Set restrictive default umask: owner rwx, group rx, others none.
# NOTE: umask 027 can cause permission failures in container tooling (Helm,
# K3s auto-deploy manifests, container build contexts) that expect world- or
# group-readable files. If you see unexpected EACCES errors from container
# tools, check whether umask is the cause before loosening other controls.
umask 027

# Terminate idle interactive sessions after 15 minutes.
# readonly prevents users from unsetting this in their own shell.
readonly TMOUT=900
export TMOUT
EOF
}

# Install a systemd timer that runs a full Lynis security audit daily.
configure_lynis() {
    cat <<EOF > /etc/systemd/system/lynis-audit.service
[Unit]
Description=Lynis security audit
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/lynis audit system --cronjob
EOF

    cat <<EOF > /etc/systemd/system/lynis-audit.timer
[Unit]
Description=Daily Lynis security audit

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Exclude container/K8s paths from AIDE, build the initial database, and schedule daily checks.
configure_aide() {
    # Exclude k3s/Kubernetes dynamic paths to prevent false positives
    if ! grep -q "k3s / Kubernetes dynamic paths" /etc/aide.conf; then
        cat <<EOF >> /etc/aide.conf

# k3s / Kubernetes and Docker dynamic paths
!/var/lib/rancher
!/var/lib/kubelet
!/run/k3s
!/var/lib/containers
!/var/lib/docker
!/run/containerd
!/var/lib/cni
!/var/lib/calico
!/tmp
EOF
    fi

    # Build initial database (may take a few minutes).
    # Failure here is non-fatal — run 'aide --init' manually if needed.
    printf "Building AIDE database. This may take a few minutes...\n"
    if aide --init; then
        mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
        printf "AIDE database built successfully.\n"
    else
        printf "WARNING: AIDE database initialisation failed. Run 'aide --init' manually.\n"
    fi

    # Systemd service for daily integrity checks
    cat <<EOF > /etc/systemd/system/aide-check.service
[Unit]
Description=AIDE integrity check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/aide --check
EOF

    cat <<EOF > /etc/systemd/system/aide-check.timer
[Unit]
Description=Daily AIDE integrity check

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Enable and start all configured services; disable cockpit and mask avahi.
start_services() {
    systemctl disable --now cockpit 2>/dev/null || true
    rm -f /etc/motd.d/cockpit
    systemctl mask avahi-daemon 2>/dev/null || true
    sysctl --system
    systemctl daemon-reload
    systemctl enable dnf-automatic.timer --now
    systemctl enable chronyd.service --now
    systemctl enable auditd.service --now
    systemctl enable aide-check.timer --now
    systemctl enable lynis-audit.timer --now
    systemctl enable fail2ban.service --now
    systemctl enable qemu-guest-agent --now
    systemctl restart sshd.service
}

# Print a summary of what was configured and where the key files were written.
print_summary() {
    printf "\n"
    printf "=========================================================\n"
    printf "  Hardening complete\n"
    printf "=========================================================\n"
    printf "  User:          %s\n" "${username}"
    printf "  Organization:  %s\n" "${org_name}"
    printf "  SSH port:      %s\n" "${SSH_Port}"
    printf "\n"
    printf "  Key config files written:\n"
    printf "    %s\n" "${SSH_Config}"
    printf "    %s\n" "${Sysctl_Config}"
    printf "    %s\n" "${Audit_Rules}"
    printf "    %s\n" "${Fail2ban_SSH_Config}"
    printf "    %s\n" "${Module_Blacklist}"
    printf "    %s\n" "${Sudoers_Drop}"
    printf "    %s\n" "${Umask_Profile}"
    printf "    %s\n" "${Br_Netfilter_Conf}"
    printf "    %s\n" "${Shm_Dropin}"
    printf "    %s\n" "${Journald_Config}"
    printf "    %s\n" "${Logrotate_Config}"
    printf "\n"
    printf "  Backups created with .bak suffix for all modified files.\n"
    printf "  Run log saved to /var/log/hardening-*.log\n"
    printf "\n"
    printf "  Next steps: /home/%s/after_first_login.txt\n" "${username}"
    printf "=========================================================\n"
}

# -------------------------
# Main
# -------------------------

main() {
    exec > >(tee "/var/log/hardening-$(date +%Y%m%d-%H%M%S).log") 2>&1
    check_root
    accept_terms
    check_disk_encryption
    get_username
    check_selinux
    check_os
    check_ssh_key
    check_grub_password
    configure_ssh_port
    get_org_name
    configure_banner
    configure_lynis_repo
    install_packages
    configure_auto_updates
    configure_pam
    configure_pwquality
    configure_fail2ban
    configure_ssh
    configure_module_blacklist
    configure_kernel_modules
    configure_sysctl
    configure_auditd_conf
    configure_auditd
    configure_log_retention
    configure_umask
    configure_lynis
    configure_firewall
    configure_container_firewall
    configure_shm_hardening
    configure_sudo_log
    configure_su_restriction
    configure_aide
    write_post_login_guide
    start_services
    print_summary
}

main
