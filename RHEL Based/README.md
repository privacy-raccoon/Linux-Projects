# Rocky Linux 10 — Secure Installation Guide

This guide covers the disk layout and encryption decisions that must be made at install time via the graphical installer. These cannot be
configured post-boot. After installation, run `init.sh` to complete
hardening.

> Please note, if you read this document in plain text it might look very broken. The formatting is built for markdown editors and viewers.


---

## Prerequisites

- Rocky Linux 10 installation media (ISO verified against official checksums)
- A clean disk — all existing data will be destroyed
- 64 GiB disk assumed for the layouts below

---

## 1. Boot and initial screens

1. Boot from installation media and select **Install Rocky Linux 10**
2. Choose language and keyboard layout
3. On the **Installation Summary** screen, configure the sections below before clicking **Begin Installation**

---

## 2. Installation Destination — disk layout

This is the most important step. All partition and encryption decisions are made here.

1. Click **Installation Destination**
2. Select your target disk
3. Under **Storage Configuration**, choose **Custom**
4. Click **Done** to open the manual partitioning screen

### Partition scheme

When prompted for a partition scheme, select **LVM**.

Check **Encrypt my data** and set a strong passphrase when prompted. This passphrase is required at every boot. Store it securely.

### Recommended layout

Use **xfs** for all partitions unless noted otherwise. Two layouts are provided below based on intended workload — choose one before installing.

#### Option A — Kubernetes / K3s workload (no swap)

Kubernetes requires swap to be disabled. The space saved is redistributed to `var`, which holds container images, kubelet state, and runtime data. Be aware that you will see a warning during the configuration if you don't have swap space configured. You can safely ignore this warning and move forward.

| Mount point | Filesystem  | Size     | Notes                                          |
|-------------|-------------|----------|------------------------------------------------|
| `/boot/efi` | EFI (FAT32) | 600 MiB  | UEFI only; not encrypted                       |
| `/boot`     | xfs         | 1 GiB    | Not encrypted; required for GRUB               |
| `/`         | xfs         | 20 GiB   | Encrypted via LVM container                    |
| `/var`      | xfs         | 25 GiB   | Encrypted; sized for container images and logs |
| `/home`     | xfs         | 12 GiB   | Encrypted                                      |
| `/tmp`      | xfs         | 5 GiB    | Encrypted                                      |

> After installation, disable swap permanently if the installer created one:
> `swapoff -a` and remove any swap entries from `/etc/fstab`.

#### Option B — General purpose workload (with swap)

| Mount point | Filesystem  | Size     | Notes                            |
|-------------|-------------|----------|----------------------------------|
| `/boot/efi` | EFI (FAT32) | 600 MiB  | UEFI only; not encrypted         |
| `/boot`     | xfs         | 1 GiB    | Not encrypted; required for GRUB |
| `/`         | xfs         | 15 GiB   | Encrypted via LVM container      |
| `/var`      | xfs         | 15 GiB   | Encrypted                        |
| `/home`     | xfs         | 15 GiB   | Encrypted                        |
| `/tmp`      | xfs         | 5 GiB    | Encrypted                        |
| `swap`      | swap        | 8 GiB    | Encrypted                        |

> `/boot` and `/boot/efi` sit outside the LUKS container and cannot be encrypted — GRUB must read `/boot` before the encryption layer is unlocked.
> All other volumes are inside the encrypted LVM container.

### Mount options

The Rocky Linux graphical installer does not expose a mount options field in the partitioning screen. Set these options post-installation by editing `/etc/fstab` (see **Section 9**).

Click **Done**, review the change summary, and click **Accept Changes**.

---

## 3. KDUMP

Unless otherwise needed, enable kdump and select "Automatic" for the `Kdump Memory Reservation` option.

---

## 4. Network and hostname

1. Click **Network & Host Name**
2. Set the hostname in the field at the bottom of the screen
3. Configure a static IP here if you need it.
4. Click **Done**

---

## 5. Installation Source

If you are using the full DVD ISO installer, feel free to stick with it. Personally, I recommend to use `On the network` as the installation source in order to ensure the system installs with updated software.

---

## 6. Root account and user creation

1. (optional) Click **Root Account** and select **Disable root account**.
   - It may be beneficial to have access to the root user via console or `su` in the future. Use your best judgement for this decision.
   - If you do enable the root account, **do not** enable SSH login with a password for the root user.

2. Click **User Creation** and create your primary user:
   - Check **Make this user administrator** (adds to `wheel`)
   - Set a strong password — SSH will be restricted to key-only auth after `init.sh` runs

---

## 7. Software selection

Select **Server** as the base environment and add no additional package groups. The Server selection includes the tooling that `init.sh` depends on (SELinux utilities, audit, policycoreutils, etc.) without pulling in unnecessary services.

---

## 8. Complete installation

Click **Begin Installation**, wait for it to finish, then remove the
installation media and reboot.

At boot you will be prompted for the LUKS passphrase before the system continues loading.

---

## 9. Post-install verification & next steps

### Set mount options in /etc/fstab

Edit `/etc/fstab` and add the security options to the `/var`, `/home`, and `/tmp` entries. The lines should look like this after editing:

```bash
UUID=<uuid>  /home  xfs  defaults,nodev,nosuid,x-systemd.device-timeout=0  0 0
UUID=<uuid>  /tmp   xfs  defaults,nodev,nosuid,noexec,x-systemd.device-timeout=0  0 0
UUID=<uuid>  /var   xfs  defaults,nodev,nosuid,x-systemd.device-timeout=0  0 0
```

> `noexec` is intentionally omitted from `/home` — scripts executed from
> home directories (Python virtualenvs, shell scripts, etc.) would break.
> Apply it if your threat model warrants it.

Apply without rebooting:

```bash
sudo mount -o remount /var
sudo mount -o remount /home
sudo mount -o remount /tmp
```

### Verify partition layout and encryption

After first login, verify the partition layout and encryption before running `init.sh`:

```bash
# Confirm separate mount points exist
lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE

# Confirm LUKS is active on the expected devices
lsblk -o NAME,TYPE | grep crypt

# Confirm mount options were applied
findmnt -o TARGET,OPTIONS /var /home /tmp

# Kubernetes: confirm swap is off
swapon --show
```

Expected output from `lsblk` should show `crypt` type entries mapped to `/`, `/var`, `/home`, `/tmp`, and (if applicable) `swap`.

### Transfer your SSH public key to the server

Before continuing, copy your SSH public key to the server. Once
`init.sh` runs, password-based SSH login will be disabled.

```bash
ssh-copy-id user@server
```

This copies `~/.ssh/id_*.pub` to the server's `~/.ssh/authorized_keys`.

If you have multiple keys or a non-default key path, specify it explicitly:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server
```

If you have not yet generated a key pair, do so first:

```bash
ssh-keygen -t ed25519
```

---

## 10. Run init.sh

Transfer `init.sh` to the server and run it as your first post-boot step:

```bash
scp init.sh user@server:~/
ssh user@server
sudo bash init.sh
```

The script will detect the LUKS volumes and pass the disk encryption check automatically.
