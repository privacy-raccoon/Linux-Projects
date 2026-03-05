#!/bin/bash
set -euo pipefail

# -------------------------
# Global Variables
# -------------------------

username=""
org_name=""
SSH_Port=2222
use_containers=false

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

# Require the user to confirm they have read the documentation before proceeding.
accept_terms() {
    printf "Please review init.md before running this script.\n"
    printf "It contains a full description of every change this script makes.\n\n"
    printf "Have you read the documentation and do you wish to continue? (y/N): "
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

# Prompt for the target username.
# Loops until a valid, existing username is provided or the user aborts.
get_username() {
    while true; do
        printf "Please enter your username (or 'abort' to exit): "
        read -r username
        if [ -z "${username}" ]; then
            printf "Username cannot be empty.\n"
        elif [ "${username}" = "abort" ]; then
            printf "Aborting.\n"
            exit 1
        elif ! id "${username}" &>/dev/null; then
            printf "User '%s' does not exist on this system.\n" "${username}"
        elif [ "$(id -u "${username}")" -lt 1000 ]; then
            printf "User '%s' is a system account and cannot be used.\n" "${username}"
        else
            break
        fi
    done
}

# Warn and prompt to continue if AppArmor is not active.
# Debian uses AppArmor for mandatory access control instead of SELinux.
check_apparmor() {
    if systemctl is-active apparmor &>/dev/null; then
        printf "AppArmor is active.\n"
        return 0
    fi
    printf "WARNING: AppArmor is not active. It should be running on a hardened system.\n"
    printf "AppArmor provides mandatory access control to confine processes to minimum required access.\n\n"
    printf "Options:\n"
    printf "  enable   Enable and start AppArmor\n"
    printf "  skip     Continue without AppArmor (not recommended)\n"
    printf "  abort    Exit the script\n"
    printf "> "
    read -r choice
    case "${choice}" in
        enable)
            systemctl enable apparmor --now
            printf "AppArmor enabled.\n"
            ;;
        skip)
            printf "Continuing without AppArmor...\n"
            ;;
        *)
            printf "Aborting.\n"
            exit 1
            ;;
    esac
}

# Confirm Debian 13. Warn and prompt to continue on any other OS.
check_os() {
    local id version_id
    # shellcheck disable=SC1091
    id=$(. /etc/os-release 2>/dev/null && printf "%s" "${ID}")
    # shellcheck disable=SC1091,SC2153
    version_id=$(. /etc/os-release 2>/dev/null && printf "%s" "${VERSION_ID}")
    if [ "${id}" = "debian" ] && [ "${version_id}" = "13" ]; then
        printf "Welcome %s, thanks for running this neat script.\n" "${username}"
    else
        printf "WARNING: This operating system is NOT Debian 13 (Trixie).\n"
        printf "This script was designed specifically for Debian 13.\n"
        printf "It may work on other Debian-based systems, but there are no guarantees.\n"
        printf "Do not attempt to run this script on non-Debian based systems.\n\n"

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
# On Debian, uses grub-mkpasswd-pbkdf2 + /etc/grub.d/40_custom instead of grub2-setpassword.
check_grub_password() {
    if bootctl is-installed &>/dev/null; then
        printf "systemd-boot detected. Bootloader passwords are not supported.\n"
        printf "Ensure UEFI Secure Boot is enabled for equivalent boot-time protection.\n"
        printf "\nPress Enter to continue...\n"
        read -r
        return 0
    fi

    if grep -q "password_pbkdf2" /etc/grub.d/40_custom 2>/dev/null || \
       grep -q "password_pbkdf2" /boot/grub/grub.cfg 2>/dev/null; then
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
            printf "You will be prompted to enter and confirm your GRUB password.\n"
            local tmpfile
            tmpfile=$(mktemp)
            grub-mkpasswd-pbkdf2 | tee "${tmpfile}"
            local grub_hash
            grub_hash=$(awk '/PBKDF2 hash/ {print $NF}' "${tmpfile}")
            rm -f "${tmpfile}"
            if [ -n "${grub_hash}" ]; then
                printf "\nset superusers=\"root\"\npassword_pbkdf2 root %s\n" "${grub_hash}" \
                    >> /etc/grub.d/40_custom
                chmod 0700 /etc/grub.d/40_custom
                update-grub
                printf "GRUB password configured and grub.cfg updated.\n"
            else
                printf "WARNING: Could not capture the GRUB hash.\n"
                printf "Run 'grub-mkpasswd-pbkdf2' manually and add the result to /etc/grub.d/40_custom.\n"
            fi
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

# Lynis is available in the Debian 13 main repository; no additional repository required.
configure_lynis_repo() {
    printf "Lynis is available in the Debian 13 main repository; no additional repository required.\n"
}

# Update the system and install security and convenience packages.
install_packages() {
    printf "Updating system.\n"
    apt-get -y update
    apt-get -y upgrade

    printf "Installing security packages.\n"
    printf "rkhunter and tripwire have limited availability on Debian 13.\n"
    printf "Lynis and AIDE are used instead for security auditing and integrity monitoring.\n"
    printf "\nPress Enter to begin package installation...\n"
    read -r
    apt-get -y install \
        unattended-upgrades apt-listchanges \
        fail2ban \
        auditd audispd-plugins \
        aide aide-common \
        lynis \
        qemu-guest-agent \
        ufw \
        apparmor apparmor-utils \
        libpam-pwquality

    printf "Installing convenience packages.\n"
    apt-get -y install \
        git nmon fastfetch zsh ncdu btop
}

# Configure unattended-upgrades to apply security updates automatically.
# Replaces dnf-automatic on RHEL.
configure_auto_updates() {
    if grep -q "# Hardening configured" /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
        printf "unattended-upgrades already configured, skipping.\n"
        return 0
    fi
    local reboot_policy
    printf "Should the system automatically reboot after security updates that require it? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            reboot_policy="true"
            printf "Automatic reboots enabled when required by updates.\n"
            ;;
        *)
            reboot_policy="false"
            printf "Automatic reboots disabled. You will need to reboot manually after kernel updates.\n"
            ;;
    esac

    printf "Configuring automatic security updates.\n"
    cp /etc/apt/apt.conf.d/50unattended-upgrades \
       /etc/apt/apt.conf.d/50unattended-upgrades.bak 2>/dev/null || true
    cat <<EOF > /etc/apt/apt.conf.d/50unattended-upgrades
// Hardening configured
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${reboot_policy}";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
    cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# Harden faillock and enable it in the Debian PAM stack.
# Appends settings to faillock.conf and inserts pam_faillock into common-auth/common-account.
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

    # Insert pam_faillock into the Debian common-auth PAM stack.
    # Preauth goes before pam_unix.so; authfail goes immediately after.
    local common_auth="/etc/pam.d/common-auth"
    cp "${common_auth}" "${common_auth}.bak"
    if ! grep -q "pam_faillock.so preauth" "${common_auth}"; then
        sed -i '/pam_unix\.so/i auth\trequired\t\t\t\tpam_faillock.so preauth' "${common_auth}"
        sed -i '/pam_unix\.so/a auth\t[default=die]\t\t\t\tpam_faillock.so authfail' "${common_auth}"
    fi

    # Add the pam_faillock account rule to common-account.
    local common_account="/etc/pam.d/common-account"
    cp "${common_account}" "${common_account}.bak"
    if ! grep -q "pam_faillock.so" "${common_account}"; then
        echo "account required    pam_faillock.so" >> "${common_account}"
    fi

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
    mkdir -p "$(dirname "${SSH_Config}")"
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

# Write kernel hardening tunables to a sysctl drop-in.
# Container/Kubernetes tunables are appended only if use_containers is true.
configure_sysctl() {
    local rp_filter=1
    if "${use_containers}"; then
        rp_filter=2
    fi

    cat <<EOF > "${Sysctl_Config}"
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

# rp_filter=1 (strict) for standalone servers. Set to 2 (loose) on container hosts
# because some CNI plugins (e.g. Calico) use asymmetric routing. Set automatically
# based on whether container workloads were selected.
net.ipv4.conf.all.rp_filter = ${rp_filter}
net.ipv4.conf.default.rp_filter = ${rp_filter}

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_messages = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
fs.suid_dumpable = 0
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
# Prevent unprivileged processes from attaching a debugger to processes they don't own.
kernel.yama.ptrace_scope = 1
EOF

    if "${use_containers}"; then
        cat <<'EOF' >> "${Sysctl_Config}"
# Required for container networking (Docker, K3s, K8s)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Required for Kubernetes CNI networking (all CNI plugins depend on this)
# br_netfilter module must be loaded before these take effect (see configure_kernel_modules)
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

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
    fi
}

# Optionally open firewall ports for Docker, K3s single-node, or K3s/K8s multi-node.
# Uses ufw instead of firewalld (Debian default).
configure_container_firewall() {
    printf "Will this server run containerized workloads? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            use_containers=true
            printf "Select workload type:\n"
            printf "  1) Docker standalone\n"
            printf "  2) K3s single-node\n"
            printf "  3) K3s/K8s multi-node (server/control-plane)\n"
            printf "  4) K3s/K8s multi-node (agent/worker)\n"
            printf "> "
            read -r workload
            case "${workload}" in
                1)
                    printf "NOTE: Docker bypasses ufw by writing iptables rules directly.\n"
                    printf "Ports exposed via -p will be publicly reachable regardless of ufw rules.\n"
                    printf "See after_first_login.txt for mitigation options.\n"
                    printf "Press Enter to continue...\n"
                    read -r
                    ;;
                2)
                    ufw allow 6443/tcp comment 'K8s API server'
                    ufw allow 10250/tcp comment 'Kubelet'
                    ufw allow 8472/udp comment 'Flannel VXLAN'
                    ufw allow 51820/udp comment 'WireGuard (K3s default)'
                    printf "Opened K3s single-node ports (6443, 10250, 8472/udp, 51820/udp).\n"
                    ;;
                3)
                    ufw allow 6443/tcp comment 'K8s API server'
                    ufw allow 10250/tcp comment 'Kubelet'
                    ufw allow 8472/udp comment 'Flannel VXLAN'
                    ufw allow 51820/udp comment 'WireGuard'
                    ufw allow 2379:2380/tcp comment 'etcd (HA)'
                    ufw allow 30000:32767/tcp comment 'NodePort range'
                    printf "Opened K3s/K8s control-plane ports.\n"
                    ;;
                4)
                    ufw allow 10250/tcp comment 'Kubelet'
                    ufw allow 8472/udp comment 'Flannel VXLAN'
                    ufw allow 51820/udp comment 'WireGuard'
                    ufw allow 30000:32767/tcp comment 'NodePort range'
                    printf "Opened K3s/K8s worker node ports.\n"
                    ;;
                *)
                    printf "Unrecognised option, no container ports opened. Open them manually with ufw.\n"
                    ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

# Configure ufw: default deny incoming, open SSH port.
# Replaces semanage + firewalld on RHEL. No SELinux port registration needed on Debian.
configure_firewall() {
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_Port}/tcp" comment 'SSH'
    ufw --force enable
    printf "ufw enabled: default deny incoming, SSH port %s opened.\n" "${SSH_Port}"
}

# Write a post-login reference guide to the user's home directory.
write_post_login_guide() {
    local guide="/home/${username}/after_first_login.txt"

    cat <<EOF > "${guide}"
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
EOF

    if "${use_containers}"; then
        cat <<'EOF' >> "${guide}"

# -------------------------
# Container Workloads
# -------------------------

# Docker + ufw WARNING:
#   Docker writes iptables rules directly and BYPASSES ufw.
#   Any port exposed with -p will be publicly reachable regardless of ufw rules.
#   To prevent this, add the following to /etc/docker/daemon.json:
#     { "iptables": false }
#   Then manage all Docker traffic routing manually via ufw/nftables.
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
#   then restart sshd: systemctl restart ssh

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
#   unattended-upgrades is configured to apply security updates automatically.
#   If automatic reboots are enabled, a kernel update will restart the host
#   and bring down all running containers. Plan for this in your workload
#   availability strategy, or disable auto-reboot and handle reboots manually.
EOF
    fi

    chown "${username}:" "${guide}"
}

# Blacklist uncommon filesystems.
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
    visudo -cf "${Sudoers_Drop}" || { rm -f "${Sudoers_Drop}"; die "sudo drop-in failed visudo check."; }
    printf "sudo audit log configured at /var/log/sudo.log.\n"
}

# Restrict su to members of the wheel group via pam_wheel.
# On Debian, the relevant group is 'sudo' but pam_wheel.so use_uid still works with 'wheel'.
# Debian ships the pam_wheel line commented out — uncomment it.
configure_su_restriction() {
    local su_pam="/etc/pam.d/su"
    if grep -qE "^auth\s+required\s+pam_wheel" "${su_pam}"; then
        printf "su wheel restriction already active, skipping.\n"
        return 0
    fi
    cp "${su_pam}" "${su_pam}.bak"
    sed -i 's/^#\(auth\s\+required\s\+pam_wheel\.so\)/\1/' "${su_pam}"
    if ! grep -qE "^auth\s+required\s+pam_wheel" "${su_pam}"; then
        echo "auth    required    pam_wheel.so" >> "${su_pam}"
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
    mkdir -p "$(dirname "${Journald_Config}")"
    cat <<EOF > "${Journald_Config}"
[Journal]
MaxRetentionSec=6month
SystemMaxUse=500M
SystemKeepFree=100M
EOF

    local auditd_conf="/etc/audit/auditd.conf"
    sed -i 's/^max_log_file_action.*/max_log_file_action = rotate/' "${auditd_conf}"
    if grep -q "^num_logs" "${auditd_conf}"; then
        sed -i 's/^num_logs.*/num_logs = 26/' "${auditd_conf}"
    else
        echo "num_logs = 26" >> "${auditd_conf}"
    fi

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
# On Debian, aide.conf lives at /etc/aide/aide.conf; falls back to /etc/aide.conf.
configure_aide() {
    local aide_conf
    if [ -f /etc/aide/aide.conf ]; then
        aide_conf="/etc/aide/aide.conf"
    elif [ -f /etc/aide.conf ]; then
        aide_conf="/etc/aide.conf"
    else
        die "Cannot find AIDE configuration file."
    fi

    if ! grep -q "k3s / Kubernetes dynamic paths" "${aide_conf}"; then
        cat <<EOF >> "${aide_conf}"

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

    printf "Building AIDE database. This may take a few minutes...\n"
    if aide --init; then
        # Debian may produce aide.db.new (no .gz) or aide.db.new.gz depending on config.
        if [ -f /var/lib/aide/aide.db.new.gz ]; then
            mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
        elif [ -f /var/lib/aide/aide.db.new ]; then
            mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        fi
        printf "AIDE database built successfully.\n"
    else
        printf "WARNING: AIDE database initialisation failed. Run 'aide --init' manually.\n"
    fi

    cat <<EOF > /etc/systemd/system/aide-check.service
[Unit]
Description=AIDE integrity check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check
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

# Enable and start all configured services; mask avahi.
# Uses Debian service names: ssh (not sshd), apt-daily timers (not dnf-automatic),
# systemd-timesyncd (not chronyd), apparmor and ufw added.
start_services() {
    systemctl disable --now cockpit 2>/dev/null || true
    rm -f /etc/motd.d/cockpit 2>/dev/null || true
    systemctl mask avahi-daemon 2>/dev/null || true
    sysctl --system
    systemctl daemon-reload
    systemctl enable apt-daily.timer --now
    systemctl enable apt-daily-upgrade.timer --now
    systemctl enable systemd-timesyncd --now
    systemctl enable auditd --now
    systemctl enable aide-check.timer --now
    systemctl enable lynis-audit.timer --now
    systemctl enable fail2ban --now
    systemctl enable qemu-guest-agent --now
    systemctl enable apparmor --now
    systemctl enable ufw --now
    systemctl restart ssh
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
    if "${use_containers}"; then
        printf "    %s\n" "${Br_Netfilter_Conf}"
    fi
    printf "    %s\n" "${Shm_Dropin}"
    printf "    %s\n" "${Journald_Config}"
    printf "    %s\n" "${Logrotate_Config}"
    printf "\n"
    printf "  Backups created with .bak suffix for all modified files.\n"
    printf "  Run log saved to /var/log/hardening-*.log\n"
    printf "\n"
    printf "  Next steps: /home/%s/after_first_login.txt\n" "${username}"
    printf "=========================================================\n"
    printf "\nPress Enter to exit...\n"
    read -r
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
    check_apparmor
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
    configure_container_firewall
    if "${use_containers}"; then
        configure_kernel_modules
    fi
    configure_sysctl
    configure_auditd_conf
    configure_auditd
    configure_log_retention
    configure_umask
    configure_lynis
    configure_firewall
    configure_shm_hardening
    configure_sudo_log
    configure_su_restriction
    configure_aide
    write_post_login_guide
    start_services
    print_summary
}

main
