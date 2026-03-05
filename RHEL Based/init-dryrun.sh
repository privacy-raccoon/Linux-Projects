#!/bin/bash
# DRY RUN VERSION — all menus and prompts are functional.
# No system changes are made. Commands that would modify the system
# are replaced with [DRY RUN] log lines.
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
# Helpers
# -------------------------

die() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

dryrun() {
    printf "[DRY RUN] %s\n" "$*"
}

# -------------------------
# Functions
# -------------------------

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "[DRY RUN] Not running as root — skipping root check.\n"
    fi
}

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

# Relaxed for dry-run: accepts any non-empty username without checking /etc/passwd.
get_username() {
    while true; do
        printf "Please enter your username (or 'abort' to exit): "
        read -r username
        if [ -z "${username}" ]; then
            printf "Username cannot be empty.\n"
        elif [ "${username}" = "abort" ]; then
            printf "Aborting.\n"
            exit 1
        else
            dryrun "would verify that user '${username}' exists and has UID >= 1000"
            break
        fi
    done
}

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
            dryrun "sed -i 's/^SELINUX=.*/SELINUX=enforcing/' ${selinux_config}"
            if [ "${state}" = "Disabled" ]; then
                printf "[DRY RUN] SELinux was Disabled — would update config and exit for reboot.\n"
            else
                dryrun "setenforce 1"
                printf "[DRY RUN] SELinux would be set to Enforcing.\n"
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

check_os() {
    local id version_id
    # shellcheck disable=SC1091
    id=$(. /etc/os-release 2>/dev/null && printf "%s" "${ID}" || printf "unknown")
    # shellcheck disable=SC1091,SC2153
    version_id=$(. /etc/os-release 2>/dev/null && printf "%s" "${VERSION_ID}" || printf "0")
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

check_disk_encryption() {
    printf "Checking for disk encryption...\n"
    dryrun "lsblk -o TYPE | grep -q '^crypt\$'"
    dryrun "zfs list -H -o encryption (if zfs available)"
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

# Relaxed for dry-run: skips the authorized_keys file check.
check_ssh_key() {
    local auth_keys="/home/${username}/.ssh/authorized_keys"
    dryrun "would check for SSH authorized_keys at ${auth_keys}"
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
            printf "[DRY RUN] Would re-check %s — continuing.\n" "${auth_keys}"
            ;;
    esac
}

check_grub_password() {
    if bootctl is-installed &>/dev/null; then
        printf "systemd-boot detected. Bootloader passwords are not supported.\n"
        printf "Ensure UEFI Secure Boot is enabled for equivalent boot-time protection.\n"
        printf "\nPress Enter to continue...\n"
        read -r
        return 0
    fi

    local user_cfg="/boot/grub2/user.cfg"
    dryrun "would check ${user_cfg} for GRUB2_PASSWORD"
    printf "WARNING: No GRUB2 bootloader password is set.\n"
    printf "Without one, anyone with console access can edit boot entries or boot\n"
    printf "to single-user mode and get a root shell, bypassing all other hardening.\n\n"
    printf "Would you like to set a GRUB password now? (y/N): "
    read -r choice
    case "${choice}" in
        y|Y|yes|YES)
            dryrun "grub2-setpassword"
            ;;
        *)
            printf "Skipping GRUB password. Console access to this VM is not restricted.\n"
            ;;
    esac
}

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

configure_banner() {
    dryrun "would write login banner referencing '${org_name}' to /etc/issue.net and /etc/issue"
}

configure_lynis_repo() {
    dryrun "would write CISOfy Lynis repo to /etc/yum.repos.d/lynis.repo"
}

install_packages() {
    printf "Updating system.\n"
    dryrun "dnf -y update"

    printf "Installing and enabling Extra Packages for Enterprise Linux.\n"
    dryrun "dnf -y install epel-release"
    dryrun "/usr/bin/crb enable"

    printf "Updating repositories after enabling EPEL.\n"
    dryrun "dnf -y update"

    printf "Installing security packages.\n"
    printf "rkhunter and tripwire are not yet available in EPEL 10.\n"
    printf "Lynis (via CISOfy repo) and AIDE are used instead for security auditing and rootkit checks.\n"
    printf "\nPress Enter to begin package installation...\n"
    read -r
    dryrun "dnf -y install dnf-automatic fail2ban audit audispd-plugins aide lynis qemu-guest-agent"

    printf "Installing convenience packages.\n"
    dryrun "dnf -y install git nmon fastfetch zsh ncdu btop"
}

configure_auto_updates() {
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
    dryrun "would configure /etc/dnf/automatic.conf with reboot=${reboot_policy}"
}

configure_pam() {
    dryrun "would append faillock settings (deny=5, unlock_time=600, fail_interval=900, even_deny_root, audit) to /etc/security/faillock.conf"
}

configure_fail2ban() {
    dryrun "would create /etc/fail2ban/jail.local from jail.conf with backend=systemd"
    dryrun "would write ${Fail2ban_SSH_Config} with port=${SSH_Port}, mode=aggressive"
}

configure_ssh() {
    dryrun "would write hardened sshd config to ${SSH_Config} (port=${SSH_Port}, AllowUsers=${username}, key-only auth)"
}

configure_kernel_modules() {
    printf "Loading br_netfilter kernel module for container networking.\n"
    dryrun "modprobe br_netfilter"
    dryrun "would write 'br_netfilter' to ${Br_Netfilter_Conf}"
}

configure_sysctl() {
    local rp_filter=1
    if "${use_containers}"; then
        rp_filter=2
    fi
    dryrun "would write base kernel hardening tunables to ${Sysctl_Config} (rp_filter=${rp_filter})"
    if "${use_containers}"; then
        dryrun "would append container/K8s tunables to ${Sysctl_Config} (ip_forward, bridge-nf-call, inotify, vm.max_map_count, kernel.panic)"
    fi
}

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
                    printf "NOTE: Docker bypasses firewalld by writing iptables rules directly.\n"
                    printf "Ports exposed via -p will be publicly reachable regardless of firewalld rules.\n"
                    printf "See after_first_login.txt for mitigation options.\n"
                    printf "Press Enter to continue...\n"
                    read -r
                    ;;
                2)
                    dryrun "firewall-cmd --add-port=6443/tcp --permanent"
                    dryrun "firewall-cmd --add-port=10250/tcp --permanent"
                    dryrun "firewall-cmd --add-port=8472/udp --permanent"
                    dryrun "firewall-cmd --add-port=51820/udp --permanent"
                    printf "Opened K3s single-node ports (6443, 10250, 8472/udp, 51820/udp).\n"
                    ;;
                3)
                    dryrun "firewall-cmd --add-port=6443/tcp --permanent"
                    dryrun "firewall-cmd --add-port=10250/tcp --permanent"
                    dryrun "firewall-cmd --add-port=8472/udp --permanent"
                    dryrun "firewall-cmd --add-port=51820/udp --permanent"
                    dryrun "firewall-cmd --add-port=2379-2380/tcp --permanent"
                    dryrun "firewall-cmd --add-port=30000-32767/tcp --permanent"
                    printf "Opened K3s/K8s control-plane ports.\n"
                    ;;
                4)
                    dryrun "firewall-cmd --add-port=10250/tcp --permanent"
                    dryrun "firewall-cmd --add-port=8472/udp --permanent"
                    dryrun "firewall-cmd --add-port=51820/udp --permanent"
                    dryrun "firewall-cmd --add-port=30000-32767/tcp --permanent"
                    printf "Opened K3s/K8s worker node ports.\n"
                    ;;
                *)
                    printf "Unrecognised option, no container ports opened. Open them manually with firewall-cmd.\n"
                    ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

configure_firewall() {
    dryrun "semanage port -a -t ssh_port_t -p tcp ${SSH_Port}"
    dryrun "firewall-cmd --add-port=${SSH_Port}/tcp --permanent"
    dryrun "firewall-cmd --remove-service=cockpit --permanent"
    dryrun "firewall-cmd --remove-service=ssh --permanent"
    dryrun "firewall-cmd --remove-service=dhcpv6-client --permanent"
    dryrun "firewall-cmd --reload"
}

write_post_login_guide() {
    local guide="/home/${username}/after_first_login.txt"
    dryrun "would write Oh-My-ZSH setup notes to ${guide}"
    if "${use_containers}"; then
        dryrun "would append container workload notes to ${guide}"
    fi
    dryrun "chown ${username}: ${guide}"
}

configure_module_blacklist() {
    dryrun "would write filesystem module blacklist (cramfs, freevxfs, jffs2, hfs, hfsplus, udf) to ${Module_Blacklist}"
    printf "Unused filesystem modules blacklisted.\n"
}

configure_shm_hardening() {
    dryrun "would write systemd drop-in to ${Shm_Dropin} (nodev,nosuid,noexec on /dev/shm)"
    dryrun "systemctl daemon-reload"
    dryrun "systemctl restart dev-shm.mount"
    printf "/dev/shm hardened with nodev,nosuid,noexec via systemd drop-in.\n"
}

configure_sudo_log() {
    dryrun "would write ${Sudoers_Drop} (Defaults logfile=/var/log/sudo.log)"
    dryrun "chmod 0440 ${Sudoers_Drop}"
    dryrun "visudo -cf ${Sudoers_Drop}"
    printf "sudo audit log configured at /var/log/sudo.log.\n"
}

configure_su_restriction() {
    dryrun "would uncomment pam_wheel line in /etc/pam.d/su to restrict su to wheel group"
    printf "su restricted to wheel group.\n"
}

configure_auditd_conf() {
    dryrun "would configure /etc/audit/auditd.conf (space_left_action=email, admin_space_left_action=suspend, action_mail_acct=root, max_log_file_action=keep_logs)"
    printf "auditd.conf disk space actions configured.\n"
}

configure_auditd() {
    dryrun "would write audit rules to ${Audit_Rules} (auth, privileged cmds, SSH keys, identity files, time, modules, logins, DAC, network, container sockets, -e 2)"
}

configure_log_retention() {
    dryrun "would write ${Journald_Config} (MaxRetentionSec=6month, SystemMaxUse=500M, SystemKeepFree=100M)"
    dryrun "would configure /etc/audit/auditd.conf (max_log_file_action=rotate, num_logs=26)"
    dryrun "would write ${Logrotate_Config} (monthly, rotate 6 for sudo.log and fail2ban.log)"
    printf "Log retention configured: 6 months (journald, auditd, logrotate).\n"
}

configure_pwquality() {
    dryrun "would append pwquality settings (minlen=14, dcredit=-1, ucredit=-1, lcredit=-1, ocredit=-1) to /etc/security/pwquality.conf"
}

configure_umask() {
    dryrun "would write ${Umask_Profile} (umask 027, readonly TMOUT=900)"
}

configure_lynis() {
    dryrun "would write lynis-audit.service and lynis-audit.timer to /etc/systemd/system/"
}

configure_aide() {
    dryrun "would append container/K8s path exclusions to /etc/aide.conf"
    printf "Building AIDE database. This may take a few minutes...\n"
    dryrun "aide --init (on success: mv aide.db.new.gz to aide.db.gz)"
    dryrun "would write aide-check.service and aide-check.timer to /etc/systemd/system/"
}

start_services() {
    dryrun "systemctl disable --now cockpit"
    dryrun "rm -f /etc/motd.d/cockpit"
    dryrun "systemctl mask avahi-daemon"
    dryrun "sysctl --system"
    dryrun "systemctl daemon-reload"
    dryrun "systemctl enable dnf-automatic.timer --now"
    dryrun "systemctl enable chronyd.service --now"
    dryrun "systemctl enable auditd.service --now"
    dryrun "systemctl enable aide-check.timer --now"
    dryrun "systemctl enable lynis-audit.timer --now"
    dryrun "systemctl enable fail2ban.service --now"
    dryrun "systemctl enable qemu-guest-agent --now"
    dryrun "systemctl restart sshd.service"
}

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
    printf "  [DRY RUN] No run log created.\n"
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
    printf "=========================================================\n"
    printf "  DRY RUN MODE — no changes will be made to this system\n"
    printf "=========================================================\n\n"
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
