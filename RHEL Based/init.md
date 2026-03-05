# init.sh — Hardening Script Guide

`init.sh` automates post-installation hardening for Rocky Linux 10 or RHEL 10. Run it after your first login, before the system is put into service.

> Please note, if you read this document in plain text it might look very broken. The formatting is built for markdown editors and viewers.

## Prerequisites

- A non-root user in the `wheel` group (created during installation)
- An SSH public key already in `~/.ssh/authorized_keys` — the script disables
  password authentication, so a key must be present before it runs
- SELinux in Enforcing mode (the script will warn and offer to enable it if not)
- LUKS disk encryption active (the script will warn if not detected)
- Separate `/`, `/var`, `/tmp`, and `/home` partitions
- VM is managed under QEMU/KVM or Proxmox

## Usage

```bash
scp init.sh user@server:~/
ssh user@server
sudo bash init.sh
```

The script logs all output to `/var/log/hardening-<timestamp>.log`.

---

## What it does

### Pre-flight checks

Before making any changes, the script runs the following checks in order. Each one will prompt you to continue, fix the issue, or abort.

| Check  | What it does  |
|-----------------|------------------------------------------------------------|
| Root            | Aborts if not run as root or via sudo  |
| Accept terms    | Prompts the user to confirm they have read `init.md` before proceeding  |
| Disk encryption | Checks for LUKS or ZFS native encryption; warns if absent |
| Username        | Prompts for a valid username; rejects system accounts (UID < 1000)  |
| SELinux         | Verifies Enforcing mode; offers to enable it if Permissive or Disabled |
| OS check        | Confirms Rocky Linux 10 or RHEL 10; warns on any other OS  |
| SSH key         | Confirms `~/.ssh/authorized_keys` exists for the target user before disabling password auth |
| GRUB password   | Checks for a bootloader password; offers to set one via `grub2-setpassword` |

After checks pass, the script prompts for:

- **SSH port** — keep the default (2222), generate a random port, or enter a custom one
- **Organization name** — used in the login warning banner
- **Auto-reboot policy** — whether to reboot automatically after kernel updates
- **Container workloads** — enables container-specific sysctl tunables (`ip_forward`, `bridge-nf-call-iptables`, inotify/map limits), loads `br_netfilter`, and optionally opens firewall ports for Docker, K3s, or Kubernetes

The rest of the script is automated, and applies the following changes.

---

### Packages

Installs the following via dnf:

| Package  | Purpose  |
|----------------------------|-------------------------------------------------|
| `fail2ban`                 | Brute-force protection for SSH                                                      |
| `audit`, `audispd-plugins` | System call and file access auditing                                                |
| `aide`                     | File integrity monitoring                                                           |
| `lynis`                    | Security auditing and recommendations (installed via CISOfy repo)                  |
| `dnf-automatic`            | Automatic security updates                                                          |
| `qemu-guest-agent`         | QEMU/KVM guest agent; enables host-to-guest communication (shutdown, snapshots, IP reporting) via Proxmox/KVM |
| `git`                      | Version control; useful for pulling configs, dotfiles, or deployment manifests      |
| `zsh`                      | Alternative shell; Oh-My-ZSH is (optionally) configured on top of this post-setup  |
| `btop`                     | Interactive TUI resource monitor — CPU, memory, disk I/O, and network in one view  |
| `nmon`                     | Performance data capture; useful for logging metrics to a file over time            |
| `fastfetch`                | Prints a system info summary (OS, kernel, CPU, RAM)                                 |
| `ncdu`                     | Interactive ncurses disk usage browser; easier than `du` for finding what's eating space |

EPEL and CRB repositories are enabled to satisfy dependencies.

---

### SSH hardening

Writes `/etc/ssh/sshd_config.d/99-hardening.conf` with:

- Custom port (as configured)
- Password authentication disabled; public key only
- Root login disabled
- Login restricted to the target user (`AllowUsers`)
- Restricted ciphers, MACs, and key exchange algorithms
- `AllowTcpForwarding local` — permits `ssh -L` tunneling (e.g. to a K8s API
  server) while blocking reverse forwarding; change to `no` if not needed
- 30-second login grace time, max 3 auth attempts, 10-minute keep-alive

fail2ban is installed and enabled with an aggressive SSH jail on the configured port.

---

### System hardening

| Area  | What is configured   |
|--------------------|---------------------------------------------------------|
| PAM faillock       | Lock after 5 failures within a 15-minute window, 10-minute unlock, applies to root   |
| Password quality   | 14-character minimum, requires digit, uppercase, lowercase, symbol    |
| Kernel sysctl      | SYN cookies, ICMP hardening, ASLR, kptr/dmesg restrict, ptrace scope always applied; IP forwarding, bridge-nf-call, inotify/map limits, and panic tunables only when containers selected |
| br_netfilter       | Loaded at boot; only configured when container workloads are selected  |
| Filesystem modules | cramfs, freevxfs, jffs2, hfs, hfsplus, udf blacklisted via modprobe  |
| /dev/shm           | Remounted with `nodev,nosuid,noexec` via a systemd drop-in   |
| umask              | System-wide umask set to `027` via `/etc/profile.d/hardening.sh`   |
| Session timeout    | 15-minute idle timeout (`TMOUT=900`, readonly)   |
| Login banner       | Legal warning written to `/etc/issue.net` and `/etc/issue`   |

---

### Firewall and access control

- The SSH port is registered with SELinux (`semanage port`) and opened in firewalld; the default `ssh`, `cockpit`, and `dhcpv6-client` services are removed
- `su` is restricted to members of the `wheel` group via `pam_wheel`
- All `sudo` invocations are logged to `/var/log/sudo.log`
- Cockpit is disabled and its MOTD entry removed
- avahi-daemon is masked

---

### Auditing and monitoring

**auditd rules** (`/etc/audit/rules.d/99-hardening.rules`) cover:

- Authentication events (`/var/log/lastlog`, `/var/run/faillock`)
- Privileged command execution (sudo, su, passwd, useradd, usermod, userdel)
- SSH authorized\_keys changes
- Sensitive file writes (passwd, shadow, sudoers)
- systemctl invocations
- Time change syscalls
- Kernel module load/unload
- Login and logout events (wtmp, btmp, utmp)
- DAC permission changes (chmod, chown)
- Network config changes (hosts, hostname)
- Container socket access (`docker.sock`, `containerd.sock`)
- Rules are made immutable until reboot (`-e 2`)

**AIDE** is configured with container/K8s paths excluded, an initial database is built, and a daily integrity check is scheduled via systemd timer.

**Lynis** runs a full security audit daily via systemd timer. Results are written to `/var/log/lynis-report.dat`.

---

### Log retention

| Log store                                    | Retention                    |
|----------------------------------------------|------------------------------|
| journald                                     | 6 months, capped at 500 MiB  |
| auditd                                       | 26 rotated files (~6 months) |
| `/var/log/sudo.log`, `/var/log/fail2ban.log` | Monthly rotation, 6 copies   |

---

## After the script completes

A reference guide is written to `~/after_first_login.txt` with the following:

### Oh-My-ZSH

Completely optional. After installing Oh-My-ZSH, apply the preferred configuration:

Use "curl -fsSL" to download this script: <https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh>, then run `sh -c /path/to/install.sh`

Or just grab it from their website directly (<https://ohmyz.sh/>) with the single line install command.

My favourite setup can be mirrored with the following commands (make sure to replace "\<username\>" with your username):

```bash
sed -i 's/robbyrussell/ys/' ~/.zshrc
sed -i 's/plugins=(git)/plugins=(colored-man-pages colorize cp safe-paste git)/' ~/.zshrc
sed -i '/export ZSH="$HOME\/.oh-my-zsh"/a\export PATH=$PATH:/home/<username>/.local/bin' ~/.zshrc
source .zshrc
```

### Container workloads

> This section is only written to `after_first_login.txt` when container workloads were selected during setup.

**K3s SELinux policy** — Install before installing K3s, or SELinux will deny K3s operations at runtime:

```bash
dnf install -y container-selinux
rpm -i https://github.com/k3s-io/k3s-selinux/releases/latest/download/k3s-selinux.rpm
# or add the Rancher repo and install k3s-selinux via dnf
```

**Docker + firewalld** — Docker writes iptables rules directly and bypasses firewalld. Any port exposed with `-p` will be publicly reachable regardless of `firewall-cmd` rules. To prevent this, add to `/etc/docker/daemon.json`:

```json
{ "iptables": false }
```

Then manage all Docker traffic manually via firewalld/nftables.

**br_netfilter** — Verify it is active before starting any container workload:

```bash
lsmod | grep br_netfilter
sysctl net.bridge.bridge-nf-call-iptables   # should be 1
sysctl net.bridge.bridge-nf-call-ip6tables  # should be 1
# If missing:
modprobe br_netfilter && sysctl --system
```

**Calico CNI / rp_filter** — `rp_filter` is set to `2` (loose mode). Calico uses asymmetric routing and may require `rp_filter=0` on specific interfaces. If pod networking misbehaves:

```bash
sysctl net.ipv4.conf.all.rp_filter                    # check current value
sysctl -w net.ipv4.conf.<iface>.rp_filter=0           # loosen per-interface if needed
```

**SSH TCP forwarding** — `AllowTcpForwarding` is set to `local`, permitting `ssh -L` tunneling (e.g. to the K8s API on port 6443). If tunneling is not needed, harden further:

```bash
# /etc/ssh/sshd_config.d/99-hardening.conf
AllowTcpForwarding no
```

Then restart sshd: `systemctl restart sshd`

**umask 027** — Some container tools (Helm, K3s auto-deploy manifests, container build contexts) expect world- or group-readable files and may fail with `EACCES`. If you see unexpected permission errors from container tooling, check whether umask is the cause before loosening other controls.

**Audit log — container socket access** — `/var/run/docker.sock` and `/run/k3s containerd/containerd.sock` are audited under the key `container_socket`. These sockets grant effective root access to the host. Review regularly:

```bash
ausearch -k container_socket | aureport -f -i
```

**Automatic updates and running containers** — If automatic reboots are enabled, a kernel update will restart the host and bring down all running containers. Plan for this in your workload availability strategy, or disable auto-reboot and handle reboots manually.

---

The summary printed at the end shows the SSH port, all config files written, and the location of the run log.

> **Important:** Your next SSH session must use the new port and your SSH key.
> Test in a second terminal before closing your current session.
