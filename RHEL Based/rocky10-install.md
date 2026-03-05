# Rocky Linux 10 — Secure Installation Guide

This guide covers the disk layout and encryption decisions that must be made
at install time via the Anaconda graphical installer. These cannot be
configured safely post-boot. After installation, run `init.sh` to complete
hardening.

---

## Prerequisites

- Rocky Linux 10 installation media (ISO verified against official checksums)
- UEFI firmware with Secure Boot available (recommended)
- A clean disk — all existing data will be destroyed
- 64 GiB disk assumed for the layouts below

---

## 1. Boot and initial screens

1. Boot from installation media and select **Install Rocky Linux 10**
2. Choose language and keyboard layout
3. On the **Installation Summary** screen, configure the sections below
   before clicking **Begin Installation**

---

## 2. Installation Destination — disk layout

This is the most critical step. All partition and encryption decisions are
made here.

1. Click **Installation Destination**
2. Select your target disk
3. Under **Storage Configuration**, choose **Custom**
4. Click **Done** to open the manual partitioning screen

### Partition scheme

When prompted for a partition scheme, select **LVM**. This places all
logical volumes inside a single LUKS-encrypted container — one passphrase
unlocks the entire system at boot.

Check **Encrypt my data** and set a strong passphrase when prompted. This
passphrase is required at every boot. Store it securely.

### Recommended layout

Use **ext4** for all partitions unless noted otherwise. Two layouts are
provided below based on intended workload — choose one before installing.

#### Option A — Kubernetes / K3s workload (no swap)

Kubernetes requires swap to be disabled. The space saved is redistributed
to `/var`, which holds container images, kubelet state, and runtime data.

| Mount point | Filesystem  | Size     | Notes |
|-------------|-------------|----------|-------|
| `/boot/efi` | EFI (FAT32) | 600 MiB  | UEFI only; not encrypted |
| `/boot`     | ext4        | 1 GiB    | Not encrypted; required for GRUB |
| `/`         | ext4        | 20 GiB   | Encrypted via LVM container |
| `/var`      | ext4        | 25 GiB   | Encrypted; sized for container images and logs |
| `/home`     | ext4        | 12 GiB   | Encrypted |
| `/tmp`      | ext4        | 5 GiB    | Encrypted |

> After installation, disable swap permanently if the installer created one:
> `swapoff -a` and remove any swap entries from `/etc/fstab`.

#### Option B — General purpose workload (with swap)

| Mount point | Filesystem  | Size     | Notes |
|-------------|-------------|----------|-------|
| `/boot/efi` | EFI (FAT32) | 600 MiB  | UEFI only; not encrypted |
| `/boot`     | ext4        | 1 GiB    | Not encrypted; required for GRUB |
| `/`         | ext4        | 15 GiB   | Encrypted via LVM container |
| `/var`      | ext4        | 15 GiB   | Encrypted |
| `/home`     | ext4        | 15 GiB   | Encrypted |
| `/tmp`      | ext4        | 5 GiB    | Encrypted |
| `swap`      | swap        | 8 GiB    | Encrypted |

> `/boot` and `/boot/efi` sit outside the LUKS container and cannot be
> encrypted — GRUB must read `/boot` before the encryption layer is unlocked.
> All other volumes are inside the encrypted LVM container.

### Mount options

For each volume, click **Modify** to set mount options. Apply the following:

| Mount point | Mount options |
|-------------|---------------|
| `/var`      | `defaults,nodev,nosuid` |
| `/home`     | `defaults,nodev,nosuid` |
| `/tmp`      | `defaults,nodev,nosuid,noexec` |

> `noexec` is intentionally omitted from `/home` — scripts executed from
> home directories (Python virtualenvs, shell scripts, etc.) would break.
> Apply it if your threat model warrants it.

Click **Done**, review the change summary, and click **Accept Changes**.

---

## 3. Network and hostname

1. Click **Network & Host Name**
2. Set the hostname in the field at the bottom of the screen
3. Toggle the network interface on if you need it during installation
4. Click **Done**

---

## 4. Root account and user creation

1. Click **Root Account** and select **Disable root account**
   The `init.sh` hardening script requires a non-root wheel user; its SSH
   config blocks root login entirely.

2. Click **User Creation** and create your primary user:
   - Check **Make this user administrator** (adds to `wheel`)
   - Set a strong password — SSH will be restricted to key-only auth
     after `init.sh` runs

---

## 5. Software selection

Select **Server** as the base environment and add no additional package
groups. The Server selection includes the tooling that `init.sh` depends on
(SELinux utilities, audit, policycoreutils, etc.) without pulling in
unnecessary services.

---

## 6. Complete installation

Click **Begin Installation**, wait for it to finish, then remove the
installation media and reboot.

At boot you will be prompted for the LUKS passphrase before the system
continues loading.

---

## 7. Post-install verification

After first login, verify the partition layout and encryption before running
`init.sh`:

```bash
# Confirm separate mount points exist
lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE

# Confirm LUKS is active on the expected devices
lsblk -o NAME,TYPE | grep crypt

# Confirm mount options match what was configured
findmnt -o TARGET,OPTIONS /var /home /tmp

# Kubernetes: confirm swap is off
swapon --show
```

Expected output from `lsblk` should show `crypt` type entries mapped to
`/`, `/var`, `/home`, `/tmp`, and (if applicable) `swap`.

---

## 8. Run init.sh

Transfer `init.sh` to the server and run it as your first post-boot step:

```bash
scp init.sh user@server:~/
ssh user@server
sudo bash init.sh
```

The script will detect the LUKS volumes and pass the disk encryption check
automatically.
