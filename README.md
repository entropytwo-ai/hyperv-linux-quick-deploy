# hyperv-linux-quick-deploy

A ready-to-login **Ubuntu, Fedora or NixOS** VM on **Hyper-V** with one command.
It works on a standalone host or a **Failover Cluster**.

This is the PowerShell / Hyper-V port of
[proxmox-linux-quick-deploy](https://github.com/entropytwo-ai/proxmox-linux-quick-deploy) and
[unraid-linux-quick-deploy](https://github.com/entropytwo-ai/unraid-linux-quick-deploy).
It works the same way: it picks the newest release live from the official mirror, verifies the
checksum, and you log in with your own key or password.

```powershell
# elevated PowerShell on the Hyper-V host (or any cluster node)
irm https://raw.githubusercontent.com/entropytwo-ai/hyperv-linux-quick-deploy/main/New-QuickLinuxVM.ps1 -OutFile New-QuickLinuxVM.ps1
.\New-QuickLinuxVM.ps1
```

If the execution policy blocks it, run
`powershell -ExecutionPolicy Bypass -File .\New-QuickLinuxVM.ps1` (or `Unblock-File .\New-QuickLinuxVM.ps1`).

---

## Table of Contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Check first (changes nothing)](#check-first-changes-nothing)
- [Examples](#examples)
  - [Parameters](#parameters)
- [Failover Cluster](#failover-cluster)
- [Secure Boot per distro](#secure-boot-per-distro)
- [How NixOS works](#how-nixos-works)
- [Safety](#safety)
- [What it changes on the host](#what-it-changes-on-the-host)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
  - [What has been verified](#what-has-been-verified)
- [License](#license)

---

## What it does

1. **Detects the host.** You get a standalone Hyper-V host, or a cluster-aware run when the host is an Up
   Failover Cluster node.
2. **Shows a menu:**

   | # | Id | What you get |
   |---|----|--------------|
   | 1 | `ubuntu-lts` | Newest Ubuntu LTS cloud image |
   | 2 | `ubuntu-latest` | Newest Ubuntu release, including interim releases |
   | 3 | `ubuntu-dev` | Daily build of the next Ubuntu release |
   | 4 | `fedora` | Newest Fedora Cloud Base (Generic) |
   | 5 | `nixos` | NixOS unstable, unattended install |
   | 6 | `nixos-stable` | Newest NixOS stable channel, unattended install |

3. **Looks up the newest build live.** No versions are hard-coded:

   | Distro | Source |
   |--------|--------|
   | Ubuntu | `changelogs.ubuntu.com/meta-release[-development]`, then the newest dated build in `cloud-images.ubuntu.com/<codename>/` (`SHA256SUMS`) |
   | Fedora | The release list on `dl.fedoraproject.org`, newest first, skipping releases with no Cloud image (`*-CHECKSUM`) |
   | NixOS  | The `channels.nixos.org/<channel>/latest-nixos-minimal-x86_64-linux.iso` redirect (`.sha256`) |

4. **Prints a plan** (paths, free space, image, VM settings, login) and waits for your confirmation.
5. **Downloads the image once** into a cache, verifies **SHA256/SHA512** against the published checksum
   file, and converts cloud images to a dynamic VHDX. The converted VHDX is cached per release, so the
   next VM is created in seconds.
6. **Creates a Generation 2 VM:** thin-provisioned disk grown to your size, Secure Boot set per distro,
   guest services enabled, automatic checkpoints off.
7. **Personalises the guest:**
   * **Ubuntu / Fedora:** a cloud-init **NoCloud** seed (`CIDATA`) sets the hostname, your user, the
     password *hash* and/or SSH keys, and installs the Hyper-V KVP/VSS daemons. Those daemons are what
     make the IP show up in Hyper-V Manager.
   * **NixOS:** see [How NixOS works](#how-nixos-works).
8. **Clusters only:** adds the VM as a **clustered role**, places it on the node with the most free
   memory, and starts it. It then waits for the IP and prints `ssh user@ip`.

If any step fails, everything this run created is **rolled back**: the clustered role, the VM and its
folder. Verified downloads stay in the cache.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Windows Server 2019 / 2022 / 2025 (or Windows 10/11 Pro) with the Hyper-V role | `Install-WindowsFeature Hyper-V -IncludeManagementTools -Restart` |
| Windows PowerShell 5.1 or PowerShell 7+ | 5.1 (`powershell.exe`) is recommended on clusters |
| Run as **Administrator** | Checked by preflight |
| A virtual switch | An External switch gives the guest internet access (needed for package installs and NixOS) |
| Internet access from the host | Image lookup and download |
| **qemu-img** (Ubuntu/Fedora only) | Converts qcow2 to VHDX. If it's missing, the script **asks** before installing QEMU for Windows (winget `SoftwareFreedomConservancy.QEMU`, or the qemu.weilnetz.de installer verified against its `.sha512`). Or pass `-QemuImgPath`. |
| Clusters: the FailoverClusters module and at least one CSV | `Install-WindowsFeature RSAT-Clustering-PowerShell` |

For the seed media, nothing extra is needed. The ISO is built with the IMAPI2 COM API that ships with
Windows. If that is unavailable, the script uses `oscdimg.exe` from the Windows ADK, and as a last
resort a small FAT32 VHDX labelled `CIDATA`. cloud-init accepts both.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Check first (changes nothing)

```powershell
.\New-QuickLinuxVM.ps1 -Check   # full preflight report, exit 0 = ready
.\New-QuickLinuxVM.ps1 -List    # newest image per menu entry, right now
```

`-Check` doesn't just look for commands. It **runs** each tool:

* **qemu-img:** runs `--version`, creates a qcow2, converts it to VHDX with the exact production
  options, then checks the VHDX signature and runs `Test-VHD`.
* **Seed builder:** builds a real test seed and validates the ISO9660 volume label and the Joliet
  descriptor.
* **Templates:** renders every template (user-data, meta-data, configuration.nix, install.sh) and
  rejects any unfilled placeholder.
* **Images:** resolves every image, downloads and parses its checksum file, and checks the image URL
  is reachable.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Examples

```powershell
# Interactive (menu, then prompts with sensible defaults)
.\New-QuickLinuxVM.ps1

# Unattended Ubuntu LTS with SSH-key login
.\New-QuickLinuxVM.ps1 -Distro ubuntu-lts -SshPublicKeyPath $HOME\.ssh\id_ed25519.pub -Force

# Fedora with a password (SecureString, never on the command line in clear text)
$pw = Read-Host -AsSecureString 'Password'
.\New-QuickLinuxVM.ps1 -Distro fedora -Name web01 -CpuCount 4 -MemoryMB 4096 -DiskSizeGB 40 -Password $pw -Force

# Or use a credential (user name + password)
.\New-QuickLinuxVM.ps1 -Distro ubuntu-lts -Credential (Get-Credential) -Force

# Preview exactly what would happen, without doing it
.\New-QuickLinuxVM.ps1 -Distro nixos -SshPublicKeyPath $HOME\.ssh\id_ed25519.pub -WhatIf

# Confirm every individual change
.\New-QuickLinuxVM.ps1 -Distro fedora -Password $pw -Confirm

# Cluster: choose the CSV folder and node yourself
.\New-QuickLinuxVM.ps1 -Distro ubuntu-lts -VMPath C:\ClusterStorage\Volume2\VMs -TargetNode HV02 -SshPublicKeyPath .\id.pub -Force

# Your own image (checksum required unless you explicitly accept an unverified one)
.\New-QuickLinuxVM.ps1 -Distro ubuntu-lts -ImageUrl https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img -ImageChecksum <sha256> -SshPublicKeyPath .\id.pub
```

### Parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Distro` | menu | `ubuntu-lts`, `ubuntu-latest`, `ubuntu-dev`, `fedora`, `nixos`, `nixos-stable` |
| `-Name` | `<family>-N` (first free) | VM name and hostname |
| `-CpuCount` / `-MemoryMB` / `-DiskSizeGB` | 2 / 2048 / 20 | Resources. The disk is a dynamic VHDX. |
| `-DynamicMemory` | off | Dynamic memory with min 512 MiB and max `-MemoryMB` |
| `-SwitchName` / `-VlanId` | first External switch / none | Network |
| `-VMPath` / `-CachePath` | host default or largest CSV `\Hyper-V` / `<VMPath>\QuickDeploy-Cache` | Locations |
| `-UserName` | `admin` | Linux user (root login is never enabled) |
| `-Password` (SecureString), `-Credential` | none | Password login. Stored in the guest only as a SHA-512 crypt hash. |
| `-SshPublicKey`, `-SshPublicKeyPath` | `~\.ssh\id_*.pub` offered interactively | SSH keys. Private keys are refused. |
| `-EnableSshPasswordAuth` | off when a key is given | Allow SSH password login in addition to keys |
| `-SetRootPassword` | off | Also set the root console password (same password) |
| `-SecureBoot` | `Auto` | `Auto` = On with the *Microsoft UEFI Certificate Authority* template for Ubuntu/Fedora, Off for NixOS |
| `-ImageUrl`, `-ImageChecksum`, `-AllowUnverifiedImage` | | Custom image |
| `-QemuImgPath` | auto-detected | Use a specific qemu-img.exe |
| `-Mode` | `Auto` | `Auto`, `Standalone` (ignore the cluster) or `Cluster` (fail if the cluster isn't usable) |
| `-TargetNode` | node with the most free RAM | Cluster node to run on |
| `-AllowNonCsvPath` | off | Allow a non-CSV path on a cluster (the VM won't be highly available) |
| `-ProcessorCompatibility` | `Auto` | `Auto` = On when cluster nodes have different CPU models (keeps live migration working) |
| `-NixOSInstall` / `-NixOSInstallTimeoutMin` | `Auto` / 60 | `Manual` boots the installer and prints the single command to type |
| `-NoStart`, `-NoWait`, `-WaitTimeoutSec` | | Start / IP-wait behaviour |
| `-Force` | | No questions (required for non-interactive use). Never skips a safety check. |
| `-WhatIf`, `-Confirm` | | Standard PowerShell preview / per-step confirmation |
| `-Check`, `-List` | | Read-only reports |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Failover Cluster

When the host is an Up node of a Failover Cluster (or with `-Mode Cluster`), the script does the
following:

* Puts the VM folder, disk, seed media and image cache on a **Cluster Shared Volume** (the one with the
  most free space, by default). A non-CSV path is refused unless you pass `-AllowNonCsvPath`.
* Checks that the virtual switch exists **on every Up node**, so live migration and failover work. A
  missing switch fails preflight.
* Checks that the VM name is free as a VM on every node, as a cluster group, and as a folder.
* Creates the VM, then runs `Add-ClusterVirtualMachineRole`. It sets automatic start to *Nothing*,
  because the cluster owns the VM's start.
* Places the VM on the node with the most free memory (or `-TargetNode`) using a quick move while it is
  still off, then starts it with `Start-ClusterGroup`.
* Turns on processor compatibility automatically when the nodes report different CPU models.

On rollback it removes the clustered role first, then the VM, then the folder.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Secure Boot per distro

| Distro | Secure Boot | Why |
|--------|-------------|-----|
| Ubuntu | **On**, template `MicrosoftUEFICertificateAuthority` | shim is signed by the Microsoft 3rd-party UEFI CA |
| Fedora | **On**, template `MicrosoftUEFICertificateAuthority` | Same. Fedora's shim is signed by the 3rd-party UEFI CA. |
| NixOS  | **Off** | The NixOS ISO and systemd-boot are not signed. `-SecureBoot On` with NixOS is refused. To use Secure Boot later, set up e.g. lanzaboote in the guest. |

The Windows template (`MicrosoftWindows`) is never used, because it does not boot Linux.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## How NixOS works

NixOS publishes no cloud image with cloud-init, so the script automates the official installer, the
same way the Proxmox version does:

1. The VM boots the official **minimal installer ISO**. A second, small medium labelled `QDNIXOS`
   carries the generated `configuration.nix` (your user, SSH keys, password hash, hostname,
   `virtualisation.hypervGuest.enable = true`, OpenSSH) and `install.sh`.
2. The installer logs in automatically as `nixos`. Once the live system's heartbeat appears, the script
   **types one command** into the VM console through the Hyper-V keyboard API (`Msvm_Keyboard`):
   `sudo bash -c 'mkdir -p /qd && mount -o ro /dev/disk/by-label/QDNIXOS /qd && bash /qd/install.sh'`
3. `install.sh` **only touches an empty disk.** It refuses to run if it finds no disk without
   partitions. It partitions the disk (GPT: 512 MiB ESP + ext4) and runs `nixos-generate-config`. It
   takes `system.stateVersion` from the installer, runs `nixos-install`, and powers off.
4. The script removes the installer media, sets the disk as the first boot device, and starts the VM.

This takes about 5-15 minutes and needs internet access in the guest. You can watch it with
`vmconnect`. With `-NixOSInstall Manual`, or if the timeout is hit, the script prints the exact command
and the three follow-up cmdlets so you can finish by hand. The command is typed using a US keyboard
layout, which is what the NixOS installer uses by default.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Safety

* **Nothing changes before you confirm the plan.** `-WhatIf` and `-Confirm` work for every step.
  `-Force` only skips questions, never checks.
* **Preflight** checks:
  * administrator rights, the Hyper-V module, and that the vmms service is running
  * the switch exists (on all nodes, on a cluster), the paths are on a CSV, and the paths are writable
  * free space on the VM and cache volumes, CPU count vs. host, and name collisions
  * qemu-img, the seed builder and the templates, each by actually running it
* **Downloads are verified.** Each download is saved as `*.part`, its SHA256/SHA512 is checked
  against the distro's published checksum file, and only then is it moved into the cache. On a
  mismatch the file is deleted. Custom images need `-ImageChecksum`, or the explicit
  `-AllowUnverifiedImage`.
* **Nothing is overwritten.** Existing VMs, cluster groups or folders with the same name stop the run.
* **Rollback:** everything a failed run created is removed in reverse order. Once a VM is running it is
  never auto-deleted.
* **No secrets in the repo or on disk.** Passwords are accepted only as SecureString or PSCredential.
  They are hashed in-process (SHA-512 crypt, random salt) and only the hash is written to the seed or
  config media. There are no default passwords: you must supply a password or an SSH key. Root login
  over SSH is disabled, and SSH password login is off whenever a key is provided.
* **Logs** are written to `%ProgramData%\hyperv-linux-quick-deploy\logs` (they never contain passwords).

<sub>[↑ Back to contents](#table-of-contents)</sub>

## What it changes on the host

* `<VMPath>\QuickDeploy-Cache\`: downloaded images and converted VHDX files. Delete them whenever you
  like.
* `<VMPath>\<vm-name>\`: VM configuration, `Virtual Hard Disks\<vm-name>.vhdx`, and the seed media
  (`cidata.iso` / `nixos-config.iso`).
* QEMU for Windows, but only if qemu-img was missing and you agreed to install it.
* Logs under `%ProgramData%\hyperv-linux-quick-deploy\logs`.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| *No IP reported yet* | cloud-init needs about 1-2 minutes on first boot to install the KVP daemon. Run `Get-VMNetworkAdapter -VMName <name>` again, or log in via `vmconnect`. |
| Fedora/Ubuntu VM won't boot ("no compatible bootloader") | Secure Boot template must be *Microsoft UEFI Certificate Authority*: `Set-VMFirmware <name> -SecureBootTemplate MicrosoftUEFICertificateAuthority` |
| *Switch missing on node(s)* | Create the switch with the same name on every node |
| *not on a Cluster Shared Volume* | Use `-VMPath C:\ClusterStorage\VolumeX\...` |
| A mirror is unreachable | `-List` shows which one. Try again later, or use `-ImageUrl` with `-ImageChecksum`. |
| NixOS install did not start | Open `vmconnect`, type the command printed in the summary, then run the follow-up cmdlets |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Development

```powershell
./tools/Invoke-StaticAnalysis.ps1        # PSScriptAnalyzer (incl. PS 5.1 syntax rules) + Pester (offline)
./tools/Invoke-StaticAnalysis.ps1 -Live  # also resolves every image on the real mirrors
```

CI (`ci/github-actions-ci.yml`; to enable it, move it to `.github/workflows/ci.yml`) runs the same checks under Windows PowerShell 5.1 and PowerShell 7 on
Windows, and PowerShell 7 on Linux. On Windows it also builds a real seed ISO with IMAPI2. See
[CONTRIBUTING.md](CONTRIBUTING.md).

### What has been verified

* PSScriptAnalyzer is clean, including PowerShell 5.1 syntax compatibility.
* The Pester suite passes, including:
  * SHA-512 crypt reference vectors
  * checksum parsing
  * template rendering
  * input validation
* Live lookups of all six images resolve, with checksums parsed and image URLs reachable.

The CI workflow covers PowerShell 5.1 and Windows-only code paths such as IMAPI2. End-to-end VM
creation still needs a real Hyper-V host or cluster, so please report your results.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## License

GPL-3.0. See [LICENSE](LICENSE).

<sub>[↑ Back to contents](#table-of-contents)</sub>
