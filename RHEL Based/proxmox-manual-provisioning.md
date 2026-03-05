# Proxmox — Manual VM Provisioning

This guide covers Proxmox VM settings for a general use workload using the web GUI. After creating the VM, follow the appropriate guide for initial setup.

---

## General

- Provide a descriptive name. My suggestion for a naming convention:
  - [public/private]-[OS/Architecture abbreviation]-[VM Name]
  - For example: `pf-l-webhost`
    - pf = public
    - l = Linux
    - webhost = concise, descriptive name for a web server
  - Another example: `pv-w-dc01`
    - pv = private
    - w = Windows
    - dc01 = concise, descriptive name for a domain controller
- Enable `Start at boot`
- If available, assign to a resource pool.
- Add descriptive tags if managing a large environment.

## OS

- Choose an appropriate ISO image that has already been uploaded to Proxmox. This guide recommends **RHEL/Rocky Linux 9** or later, **Debian 12** or later, or **Ubuntu 24.04.4 LTS** for Linux based servers at time of writing. 
- **RHEL/Rocky Linux 10**, **Debian 13**, and **Ubuntu 25.10** are still new enough at the time of writing that they may have unresolved quirks (such as EPEL 10 not having full parity with EPEL 9).

## System

- **Graphic Card:** If setting up a VM expected to have a graphical environment, choose `SPICE` and thank me later.
  - Otherwise, leave as `Default`.
- **Machine:** Unless you have specific needs with hardware passthrough, leave the option to `Default (i440fx)`.
- **BIOS:** Select `OVMF (UEFI)` unless otherwise unable to support UEFI.
  - Choose an appropriate storage pool for the EFI storage. Ensure it is using `Raw disk image (raw)` for the format.
- **QEMU Guest Agent:** Enabled
- **ADD TPM:** Do not enable the `Add TPM` option unless otherwise necessary. TPM on a VM doesn't really do much as it's virtual anyway.

## Disks

- **Bus/Device:** SCSI with default options, unless otherwise needed.
- **Controller:** `VirtIO SCSI Single` should be the default and only option.
- **IO Thread:** Enabled.
- **Discard:** Enabled — passes TRIM through to the underlying storage if using SSD for storage.
- **Cache:** `Default (No cache)` if the underlying storage has its own cache or write-back
  (ZFS, Ceph)
  - `writeback` for raw LVM on spinning disk
- **Size:** This guide recommends 64 GiB minimum if you expect to support prod services.

## CPU

- **Type: `host`** — passes through host CPU flags for best performance. Use `x86-64-v3` if you need live migration portability between hosts.
- **Cores: 2 minimum**, 4 recommended for any real workload
- **Enable NUMA** if your host has multiple NUMA nodes

## Memory

- **2 GiB (2048 MiB) minimum**, 4 GiB (4096 MiB) recommended. 8 GiB (8192 MiB) for heavy workloads.
- **Disable memory ballooning** — most server workloads benefit from predictable memory availability.

## Network

- **Model: VirtIO** — required for decent throughput
- Assign to a dedicated bridge or VLAN if you want to isolate VM traffic from host management traffic
- Disable Proxmox firewall unless there's a specific need otherwise.

---

## Summary

| Section | Setting | Value |
|---|---|---|
| General | Start at boot | enabled |
| System | Graphic card | Default |
| System | Machine | Default (i440fx) |
| System | BIOS | OVMF (UEFI) |
| System | TPM | disabled |
| System | Guest Agent | enabled |
| Disks | Bus/Device | SCSI |
| Disks | Controller | VirtIO SCSI single |
| Disks | IO Thread | enabled |
| Disks | Discard | enabled |
| Disks | Cache | Default (No cache) |
| Disks | Size | 64 GiB minimum |
| CPU | Type | host |
| CPU | Cores | 2–4 |
| Memory | RAM | 2 GiB min, 4 GiB recommended, ballooning off |
| Network | Model | VirtIO |
| Network | Firewall | disabled |
