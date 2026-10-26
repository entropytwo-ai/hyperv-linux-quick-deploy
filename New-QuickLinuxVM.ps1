<#
.SYNOPSIS
    Instantly deploy a ready-to-login Ubuntu, Fedora or NixOS VM on Hyper-V
    (standalone host or Failover Cluster).

.DESCRIPTION
    New-QuickLinuxVM.ps1 is the Hyper-V / PowerShell port of
    proxmox-linux-quick-deploy and unraid-linux-quick-deploy.

    It looks up the NEWEST release of the distro you pick on the official
    mirror (no hard-coded versions), downloads it once, verifies the published
    SHA256/SHA512 checksum, converts cloud images to VHDX (cached), and creates
    a Generation 2 VM that boots straight into a working system:

      * Ubuntu / Fedora : official cloud image + cloud-init NoCloud seed ISO
                          (user, password hash and/or SSH keys, Hyper-V KVP daemons).
      * NixOS           : official minimal installer ISO + a small config ISO.
                          The script types one command into the VM console
                          (Hyper-V keyboard API), NixOS installs itself
                          unattended, powers off, and is booted from disk.

    Safety: nothing is installed, downloaded or created before you have seen
    the plan and confirmed it. Supports -WhatIf / -Confirm. Every change made
    by a run is rolled back automatically if a later step fails (cached,
    checksum-verified downloads are kept). No default passwords: you supply a
    SecureString password and/or SSH public keys.

    Cluster aware: on a Failover Cluster node the VM files go to a Cluster
    Shared Volume, the VM is added as a clustered role, the switch is checked
    on every node and the VM is placed on the node with the most free memory.

.PARAMETER Distro
    ubuntu-lts | ubuntu-latest | ubuntu-dev | fedora | nixos | nixos-stable.
    Omit it to get the interactive menu.

.PARAMETER Check
    Dry run: checks admin rights, Hyper-V, cluster, switch, paths, free space,
    qemu-img, the seed-ISO builder and the templates (all by actually running
    them), and that the newest images and their checksum files are reachable.
    Changes nothing. Exit code 0 = ready, 1 = action needed.

.PARAMETER List
    Show the newest image every menu entry resolves to right now. Read-only.

.PARAMETER Force
    Do not ask questions (plan confirmation, qemu-img install). Required for
    non-interactive use. Does NOT bypass any safety check.

.EXAMPLE
    .\New-QuickLinuxVM.ps1
    Interactive menu.

.EXAMPLE
    .\New-QuickLinuxVM.ps1 -Check
    Pre-flight report, changes nothing.

.EXAMPLE
    .\New-QuickLinuxVM.ps1 -Distro ubuntu-lts -SshPublicKeyPath $HOME\.ssh\id_ed25519.pub -Force
    Unattended Ubuntu LTS VM with SSH-key login.

.EXAMPLE
    $pw = Read-Host -AsSecureString 'Password'
    .\New-QuickLinuxVM.ps1 -Distro fedora -Name web01 -CpuCount 4 -MemoryMB 4096 -DiskSizeGB 40 -Password $pw -WhatIf
    Show exactly what would happen, without doing it.

.LINK
    https://github.com/entropytwo-ai/hyperv-linux-quick-deploy
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console tool; colored status output is intended.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are read by the functions below (script scope).')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Internal helper names.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-QdStep forwards to the script-level $PSCmdlet.ShouldProcess.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'All state changes go through Invoke-QdStep which calls the script-level ShouldProcess.')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('ubuntu-lts', 'ubuntu-latest', 'ubuntu-dev', 'fedora', 'nixos', 'nixos-stable')]
    [string]$Distro,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')]
    [string]$Name,

    [ValidateRange(1, 240)]
    [int]$CpuCount = 2,

    [ValidateRange(512, 1048576)]
    [int]$MemoryMB = 2048,

    [switch]$DynamicMemory,

    [ValidateRange(8, 65536)]
    [int]$DiskSizeGB = 20,

    [string]$SwitchName,

    [ValidateRange(1, 4094)]
    [int]$VlanId,

    [string]$VMPath,

    [string]$CachePath,

    [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')]
    [string]$UserName = 'admin',

    [securestring]$Password,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$SshPublicKey,

    [string]$SshPublicKeyPath,

    [switch]$SetRootPassword,

    [switch]$EnableSshPasswordAuth,

    [ValidateSet('Auto', 'On', 'Off')]
    [string]$SecureBoot = 'Auto',

    [string]$ImageUrl,

    [ValidatePattern('^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})$')]
    [string]$ImageChecksum,

    [switch]$AllowUnverifiedImage,

    [string]$QemuImgPath,

    [ValidateSet('Auto', 'Standalone', 'Cluster')]
    [string]$Mode = 'Auto',

    [string]$TargetNode,

    [switch]$AllowNonCsvPath,

    [ValidateSet('Auto', 'On', 'Off')]
    [string]$ProcessorCompatibility = 'Auto',

    [ValidateSet('Auto', 'Manual')]
    [string]$NixOSInstall = 'Auto',

    [ValidateRange(10, 240)]
    [int]$NixOSInstallTimeoutMin = 60,

    [switch]$NoStart,

    [switch]$NoWait,

    [ValidateRange(0, 3600)]
    [int]$WaitTimeoutSec = 600,

    [switch]$Force,

    [switch]$Check,

    [switch]$List
)

# =============================================================================
# 0. Constants
# =============================================================================
$script:QdVersion = '1.0.0'
$script:QdCmdlet = $PSCmdlet
$script:QdUndo = New-Object System.Collections.ArrayList
$script:QdLogFile = $null
$script:QdSeedMethod = $null
# Plain tool User-Agent: some mirrors (Anubis anti-bot on dl.fedoraproject.org)
# challenge browser-like 'Mozilla/...' agents, which PowerShell sends by default.
$script:QdUserAgent = "hyperv-linux-quick-deploy/$($script:QdVersion) (+https://github.com/entropytwo-ai/hyperv-linux-quick-deploy)"

# "id|menu label|family|kind" - menu number = position + 1. Append new entries
# at the end so existing numbers keep working.
$script:QdMenu = @(
    'ubuntu-lts|Ubuntu LTS (newest)|ubuntu|cloud'
    'ubuntu-latest|Ubuntu newest release (incl. interim)|ubuntu|cloud'
    'ubuntu-dev|Ubuntu development daily (next release)|ubuntu|cloud'
    'fedora|Fedora Cloud (newest)|fedora|cloud'
    'nixos|NixOS unstable (unattended install)|nixos|iso'
    'nixos-stable|NixOS stable (newest, unattended install)|nixos|iso'
)

# Hyper-V integration service ids (names are localized, ids are not).
$script:QdIcGuestService = '6C09BB55-D683-4DA0-8931-C9BF705F6480'

# Volume labels the guests look for.
$script:QdSeedLabel = 'CIDATA'
$script:QdNixLabel = 'QDNIXOS'

# Minimum free space (bytes) required on the VM volume and the cache volume.
$script:QdMinFreeVm = 10GB
$script:QdMinFreeCache = 8GB

# =============================================================================
# 1. Templates (rendered with {{PLACEHOLDER}} tokens, verified by preflight)
# =============================================================================
$script:QdTemplates = @{}

$script:QdTemplates['user-data'] = @'
#cloud-config
# Generated by hyperv-linux-quick-deploy {{VERSION}}
hostname: {{HOSTNAME}}
manage_etc_hosts: true
ssh_pwauth: {{SSH_PWAUTH}}
disable_root: true
users:
  - name: {{USERNAME}}
    gecos: Quick Deploy user
    shell: /bin/bash
    groups: [{{GROUPS}}]
    sudo: {{SUDO_RULE}}
    lock_passwd: {{LOCK_PASSWD}}
{{PASSWD_LINE}}{{SSH_KEYS_BLOCK}}{{ROOT_BLOCK}}package_update: true
{{PACKAGES_BLOCK}}runcmd:
{{RUNCMD}}final_message: "hyperv-linux-quick-deploy: cloud-init finished after $UPTIME seconds"
'@

$script:QdTemplates['meta-data'] = @'
instance-id: {{INSTANCE_ID}}
local-hostname: {{HOSTNAME}}
'@

$script:QdTemplates['configuration.nix'] = @'
# Generated by hyperv-linux-quick-deploy {{VERSION}}
# Edit freely, then run: sudo nixos-rebuild switch
{ config, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hyper-V integration: KVP (IP shown in Hyper-V Manager), VSS, video, ...
  virtualisation.hypervGuest.enable = true;

  networking.hostName = "{{HOSTNAME}}";
  networking.useDHCP = true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = {{SSH_PWAUTH}};
    settings.PermitRootLogin = "no";
  };

  users.users."{{USERNAME}}" = {
    isNormalUser = true;
    description = "Quick Deploy user";
    extraGroups = [ "wheel" ];
{{NIX_PASSWORD_LINE}}    openssh.authorizedKeys.keys = [ {{NIX_SSH_KEYS}} ];
  };
{{NIX_ROOT_LINE}}
  security.sudo.wheelNeedsPassword = {{SUDO_NEEDS_PASSWORD}};

  environment.systemPackages = with pkgs; [ curl git vim ];

  # Filled in by install.sh from nixos-generate-config. Do not change later.
  system.stateVersion = "@STATE_VERSION@";
}
'@

$script:QdTemplates['install.sh'] = @'
#!/usr/bin/env bash
# Generated by hyperv-linux-quick-deploy {{VERSION}}
# Unattended NixOS install for a fresh Hyper-V Gen2 VM. Only touches an EMPTY disk.
set -euo pipefail
exec > >(tee -a /tmp/qd-install.log) 2>&1
echo "=== hyperv-linux-quick-deploy: installing NixOS on {{HOSTNAME}} ==="
SRC="$(cd "$(dirname "$0")" && pwd)"

# Pick the first writable disk that has no partitions and no filesystem.
DISK=""
for d in $(lsblk -dpno NAME,TYPE,RO | awk '$2=="disk" && $3=="0" {print $1}'); do
    if [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] && [ -z "$(blkid -o value -s TYPE "$d" 2>/dev/null || true)" ]; then
        DISK="$d"; break
    fi
done
if [ -z "$DISK" ]; then
    echo "[!] No empty disk found - refusing to touch anything."; exit 1
fi
echo "[*] Target disk: $DISK"

parted -s "$DISK" -- mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB set 1 esp on \
    mkpart nixos ext4 513MiB 100%
udevadm settle
PART_ESP="$(lsblk -lpno NAME "$DISK" | sed -n 2p)"
PART_ROOT="$(lsblk -lpno NAME "$DISK" | sed -n 3p)"
mkfs.fat -F 32 -n BOOT "$PART_ESP"
mkfs.ext4 -F -L nixos "$PART_ROOT"
udevadm settle
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount -o umask=077 "$PART_ESP" /mnt/boot

nixos-generate-config --root /mnt
SV="$(sed -n 's/.*system\.stateVersion = "\([^"]*\)".*/\1/p' /mnt/etc/nixos/configuration.nix | head -n 1)"
if [ -z "$SV" ]; then echo "[!] Could not read system.stateVersion"; exit 1; fi
sed "s/@STATE_VERSION@/$SV/" "$SRC/configuration.nix" > /mnt/etc/nixos/configuration.nix
echo "[*] stateVersion $SV - running nixos-install (downloads from cache.nixos.org)..."
nixos-install --no-root-passwd --no-channel-copy || nixos-install --no-root-passwd
mkdir -p /mnt/var/log
cp /tmp/qd-install.log /mnt/var/log/qd-install.log || true
sync
echo "=== Install finished - powering off ==="
sleep 3
poweroff
'@

# =============================================================================
# 2. Output, logging and small helpers
# =============================================================================
function Write-QdLog {
    param([string]$Level, [string]$Message)
    if ($script:QdLogFile) {
        $line = '{0} [{1,-5}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message, [Environment]::NewLine
        try { [IO.File]::AppendAllText($script:QdLogFile, $line) } catch { $script:QdLogFile = $null }
    }
}
function Write-QdInfo { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan; Write-QdLog INFO $Message }
function Write-QdOk { param([string]$Message) Write-Host "[ok] $Message" -ForegroundColor Green; Write-QdLog OK $Message }
function Write-QdWarn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow; Write-QdLog WARN $Message }
function Write-QdErr { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red; Write-QdLog ERROR $Message }
function Write-QdLine { param([string]$Message = '') Write-Host $Message; Write-QdLog TEXT $Message }

function Test-QdWindows {
    if ($PSVersionTable.PSVersion.Major -le 5) { return $true }
    return [bool]$IsWindows
}

function Test-QdInteractive {
    if ($Force) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) { if ($a -match '^-NonI') { return $false } }
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { return $false }
    return $true
}

function Test-QdAdmin {
    if (-not (Test-QdWindows)) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-QdBytes {
    param([double]$Bytes)
    $units = 'B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function Read-QdYesNo {
    param([string]$Prompt, [ValidateSet('y', 'n')][string]$Default = 'n')
    $hint = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $reply = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($reply)) { $reply = $Default }
    return ($reply -match '^(y|yes)$')
}

function Read-QdValue {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$Hint = 'invalid value')
    while ($true) {
        $reply = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($reply)) { $reply = $Default }
        if (-not $Validate -or (& $Validate $reply)) { return $reply }
        Write-QdWarn "$Hint - try again."
    }
}

# Run a state-changing step through ShouldProcess (-WhatIf / -Confirm).
function Invoke-QdStep {
    param([string]$Target, [string]$Action, [scriptblock]$Script)
    Write-QdLog STEP "$Action -> $Target"
    if ($script:QdCmdlet.ShouldProcess($Target, $Action)) {
        return (& $Script)
    }
}

# Remember how to undo something this run created (rolled back on failure).
# The undo script receives -Data as its only argument, so it never depends on
# variables of the (by then finished) function that registered it.
function Register-QdUndo {
    param([string]$Description, [hashtable]$Data, [scriptblock]$Script)
    [void]$script:QdUndo.Add([pscustomobject]@{ Description = $Description; Data = $Data; Script = $Script })
    Write-QdLog MADE $Description
}

function Invoke-QdRollback {
    if ($script:QdUndo.Count -eq 0) { return }
    Write-QdWarn 'Rolling back what this run created:'
    for ($i = $script:QdUndo.Count - 1; $i -ge 0; $i--) {
        $u = $script:QdUndo[$i]
        try {
            & $u.Script $u.Data
            Write-QdOk "  removed: $($u.Description)"
        } catch {
            Write-QdErr "  could not remove: $($u.Description) - $($_.Exception.Message)"
        }
    }
    $script:QdUndo.Clear()
}

# Run a native executable without letting stderr text become a terminating error.
function Invoke-QdNative {
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$PassThruOutput)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PassThruOutput) {
            & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host "    $_" }
            $out = @()
        } else {
            $out = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}

# Write a text file with LF line endings and UTF-8 without BOM (Linux guests).
function Write-QdUnixFile {
    param([string]$Path, [string]$Content)
    $text = $Content -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function New-QdTempDir {
    $base = [IO.Path]::GetTempPath()
    $dir = Join-Path $base ('qd-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}

# Free bytes on the volume that holds $Path (handles CSV / mount points).
function Get-QdFreeSpace {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.EndsWith('\')) { $full += '\' }
    try {
        $vols = Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object { $_.Name -and $full.StartsWith($_.Name, [StringComparison]::OrdinalIgnoreCase) }
        $best = $vols | Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
        if ($best) { return [uint64]$best.FreeSpace }
    } catch { Write-QdLog WARN "Win32_Volume query failed: $($_.Exception.Message)" }
    try { return [uint64](New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))).AvailableFreeSpace } catch { return [uint64]0 }
}

# Real write test (not affected by -WhatIf): can we create and delete a file?
function Test-QdWritable {
    param([string]$Path)
    $p = $Path
    while ($p -and -not [IO.Directory]::Exists($p)) { $p = [IO.Path]::GetDirectoryName($p) }
    if (-not $p) { return $false }
    $probe = Join-Path $p ('.qd-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, 'ok')
        [IO.File]::Delete($probe)
        return $true
    } catch { return $false }
}

# =============================================================================
# 3. Crypto: SHA-512 crypt ($6$) - password hashes for cloud-init and NixOS,
#    so no plain-text password is ever written to a seed/config disk.
# =============================================================================
$script:QdB64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

function New-QdSalt {
    param([int]$Length = 16)
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($script:QdB64[$b % 64]) }
    return $sb.ToString()
}

function Get-QdSha512 {
    param([byte[][]]$Parts)
    $ms = New-Object IO.MemoryStream
    foreach ($p in $Parts) { if ($p.Length) { $ms.Write($p, 0, $p.Length) } }
    $sha = [Security.Cryptography.SHA512]::Create()
    try { return $sha.ComputeHash($ms.ToArray()) } finally { $sha.Dispose(); $ms.Dispose() }
}

function Get-QdRepeated {
    param([byte[]]$Block, [int]$Length)
    $out = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i++) { $out[$i] = $Block[$i % $Block.Length] }
    return , $out
}

# Implements the SHA-crypt specification (Ulrich Drepper), SHA-512 variant.
function Get-QdSha512Crypt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlainText,
        [string]$Salt = (New-QdSalt),
        [ValidateRange(1000, 999999999)][int]$Rounds = 5000,
        [switch]$ExplicitRounds
    )
    $enc = [Text.Encoding]::UTF8
    if ($Salt.Length -gt 16) { $Salt = $Salt.Substring(0, 16) }
    [byte[]]$P = $enc.GetBytes($PlainText)
    [byte[]]$S = $enc.GetBytes($Salt)
    $pl = $P.Length

    $B = Get-QdSha512 @($P, $S, $P)

    $ms = New-Object IO.MemoryStream
    $ms.Write($P, 0, $pl); $ms.Write($S, 0, $S.Length)
    $cnt = $pl
    while ($cnt -gt 64) { $ms.Write($B, 0, 64); $cnt -= 64 }
    $ms.Write($B, 0, $cnt)
    $cnt = $pl
    while ($cnt -gt 0) {
        if ($cnt -band 1) { $ms.Write($B, 0, 64) } else { $ms.Write($P, 0, $pl) }
        $cnt = $cnt -shr 1
    }
    $A = Get-QdSha512 @(, $ms.ToArray())
    $ms.Dispose()

    $dpParts = New-Object 'byte[][]' ([Math]::Max($pl, 1))
    for ($i = 0; $i -lt $pl; $i++) { $dpParts[$i] = $P }
    if ($pl -eq 0) { $dpParts[0] = New-Object byte[] 0 }
    $DP = Get-QdSha512 $dpParts
    $Pseq = Get-QdRepeated $DP $pl

    $n = 16 + [int]$A[0]
    $dsParts = New-Object 'byte[][]' $n
    for ($i = 0; $i -lt $n; $i++) { $dsParts[$i] = $S }
    $DS = Get-QdSha512 $dsParts
    $Sseq = Get-QdRepeated $DS $S.Length

    $C = $A
    $sha = [Security.Cryptography.SHA512]::Create()
    try {
        for ($r = 0; $r -lt $Rounds; $r++) {
            $m = New-Object IO.MemoryStream
            if ($r -band 1) { $m.Write($Pseq, 0, $pl) } else { $m.Write($C, 0, 64) }
            if ($r % 3) { $m.Write($Sseq, 0, $Sseq.Length) }
            if ($r % 7) { $m.Write($Pseq, 0, $pl) }
            if ($r -band 1) { $m.Write($C, 0, 64) } else { $m.Write($Pseq, 0, $pl) }
            $C = $sha.ComputeHash($m.ToArray())
            $m.Dispose()
        }
    } finally { $sha.Dispose() }

    $order = @(
        @(0, 21, 42), @(22, 43, 1), @(44, 2, 23), @(3, 24, 45), @(25, 46, 4), @(47, 5, 26), @(6, 27, 48),
        @(28, 49, 7), @(50, 8, 29), @(9, 30, 51), @(31, 52, 10), @(53, 11, 32), @(12, 33, 54), @(34, 55, 13),
        @(56, 14, 35), @(15, 36, 57), @(37, 58, 16), @(59, 17, 38), @(18, 39, 60), @(40, 61, 19), @(62, 20, 41)
    )
    $sb = New-Object Text.StringBuilder
    foreach ($t in $order) {
        $w = ([int]$C[$t[0]] -shl 16) -bor ([int]$C[$t[1]] -shl 8) -bor [int]$C[$t[2]]
        for ($k = 0; $k -lt 4; $k++) { [void]$sb.Append($script:QdB64[$w -band 63]); $w = $w -shr 6 }
    }
    $w = [int]$C[63]
    for ($k = 0; $k -lt 2; $k++) { [void]$sb.Append($script:QdB64[$w -band 63]); $w = $w -shr 6 }

    $prefix = '$6$'
    if ($ExplicitRounds -or $Rounds -ne 5000) { $prefix += "rounds=$Rounds`$" }
    return "$prefix$Salt`$$($sb.ToString())"
}

function ConvertFrom-QdSecureString {
    param([securestring]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# =============================================================================
# 4. Input validation helpers
# =============================================================================
function Test-QdSshKey {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    if ($Key -match '["\\`]' -or $Key.Contains('${') -or $Key -match "[\r\n]") { return $false }
    return ($Key -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$')
}

function Get-QdSshKeys {
    param([string[]]$Keys, [string]$Path)
    $all = New-Object System.Collections.ArrayList
    foreach ($k in @($Keys)) { if ($k) { [void]$all.Add($k.Trim()) } }
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SSH public key file not found: $Path" }
        foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).ProviderPath)) {
            $l = $line.Trim()
            if ($l -and -not $l.StartsWith('#')) { [void]$all.Add($l) }
        }
    }
    foreach ($k in $all) {
        if ($k -match 'PRIVATE KEY') { throw 'That is a PRIVATE key. Pass the .pub file (public key) only.' }
        if (-not (Test-QdSshKey $k)) { throw "Not a valid OpenSSH public key line: '$($k.Substring(0, [Math]::Min(40, $k.Length)))...'" }
    }
    return , ([string[]]$all.ToArray())
}

function ConvertTo-QdHostname {
    param([string]$VmName)
    $h = ($VmName.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if ($h.Length -gt 63) { $h = $h.Substring(0, 63).Trim('-') }
    if (-not $h) { $h = 'linux' }
    return $h
}

function ConvertTo-QdYamlString {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# =============================================================================
# 5. Web, checksums and image discovery (newest release, looked up live)
# =============================================================================
function Initialize-QdNetwork {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { Write-QdLog WARN 'Could not enable TLS 1.2' }
}

function Get-QdWebText {
    param([string]$Url)
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $script:QdUserAgent -TimeoutSec 60 -ErrorAction Stop
        if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
        return [string]$r.Content
    } finally { $ProgressPreference = $old }
}

# Returns the Location of a redirect (or $null) without following it.
function Get-QdRedirect {
    param([string]$Url)
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.UserAgent = $script:QdUserAgent
    $req.AllowAutoRedirect = $false
    $req.Timeout = 30000
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
    }
    if (-not $resp) { return $null }
    try {
        $code = [int]$resp.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $loc = $resp.Headers['Location']
            if ($loc -and -not $loc.StartsWith('http')) { $loc = (New-Object Uri((New-Object Uri($Url)), $loc)).AbsoluteUri }
            return $loc
        }
        return $null
    } finally { $resp.Close() }
}

# True if the URL answers 2xx (HEAD, then a 1-byte ranged GET as fallback).
function Test-QdUrl {
    param([string]$Url)
    foreach ($method in 'HEAD', 'GET') {
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = $method
            $req.UserAgent = $script:QdUserAgent
            $req.AllowAutoRedirect = $true
            $req.Timeout = 30000
            if ($method -eq 'GET') { $req.AddRange(0, 0) }
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            if ($code -ge 200 -and $code -lt 300) { return $true }
        } catch { Write-QdLog INFO "URL check $method $Url failed: $($_.Exception.Message)" }
    }
    return $false
}

function Get-QdHrefs {
    param([string]$Html, [string]$Pattern)
    $set = @{}
    foreach ($m in [regex]::Matches($Html, "href=""($Pattern)""")) { $set[$m.Groups[1].Value] = $true }
    return @($set.Keys)
}

# Natural/version sort key: every digit run is zero padded.
function Get-QdSortKey {
    param([string]$Text)
    return [regex]::Replace($Text, '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Select-QdNewest {
    param([string[]]$Items)
    return ($Items | Where-Object { $_ } | Sort-Object { Get-QdSortKey $_ } | Select-Object -Last 1)
}

# Expected hash for $Name from a checksum file in GNU ("hash  name"),
# BSD ("SHA256 (name) = hash") or bare-hash format. Lower case, or $null.
function Get-QdExpectedHash {
    param([string]$Sums, [string]$Name)
    foreach ($line in ($Sums -split "`r?`n")) {
        $tokens = $line.Trim() -split '\s+'
        $hasName = $false
        foreach ($t in $tokens) {
            $clean = $t.TrimStart('*', '(').TrimEnd(')')
            if ($clean -eq $Name) { $hasName = $true }
        }
        if (-not $hasName) { continue }
        foreach ($t in $tokens) {
            if ($t -match '^[0-9a-fA-F]+$' -and ($t.Length -eq 64 -or $t.Length -eq 128)) { return $t.ToLowerInvariant() }
        }
    }
    $trim = $Sums.Trim()
    if ($trim -match '^[0-9a-fA-F]{64}([0-9a-fA-F]{64})?$') { return $trim.ToLowerInvariant() }
    return $null
}

function New-QdImage {
    param([string]$Id, [string]$Family, [string]$Kind)
    return [pscustomobject]@{
        Id = $Id; Family = $Family; Kind = $Kind; Label = ''; Url = ''; FileName = ''
        SumUrl = ''; ExpectedHash = $null
    }
}

# Parse Canonical's meta-release file into objects (codename, version, lts).
function ConvertFrom-QdUbuntuMetaRelease {
    param([string]$Text)
    $list = New-Object System.Collections.ArrayList
    $dist = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^Dist:\s*(\S+)') { $dist = $Matches[1] }
        elseif ($line -match '^Version:\s*(\d+)\.(\d+)' -and $dist) {
            [void]$list.Add([pscustomobject]@{ Codename = $dist; Version = "$($Matches[1]).$($Matches[2])"; Lts = ($line -match 'LTS') })
            $dist = $null
        }
    }
    return , $list.ToArray()
}

function Resolve-QdUbuntu {
    param([ValidateSet('lts', 'latest', 'dev')][string]$Kind, [string]$Id)
    $meta = 'https://changelogs.ubuntu.com/meta-release'
    if ($Kind -eq 'dev') { $meta += '-development' }
    $rel = ConvertFrom-QdUbuntuMetaRelease (Get-QdWebText $meta)
    if ($Kind -eq 'lts') { $rel = @($rel | Where-Object { $_.Lts }) }
    if ($Kind -eq 'dev') { $rel = @($rel | Select-Object -Last 1) }
    [array]::Reverse($rel)
    foreach ($r in ($rel | Select-Object -First 4)) {
        $c = $r.Codename
        try { $html = Get-QdWebText "https://cloud-images.ubuntu.com/$c/" } catch { continue }
        $serial = Select-QdNewest (Get-QdHrefs $html '\d{8}(?:\.\d+)?/' | ForEach-Object { $_.TrimEnd('/') })
        if (-not $serial) { continue }
        $img = New-QdImage -Id $Id -Family 'ubuntu' -Kind 'cloud'
        $img.Url = "https://cloud-images.ubuntu.com/$c/$serial/$c-server-cloudimg-amd64.img"
        if (-not (Test-QdUrl $img.Url)) { continue }
        $img.SumUrl = "https://cloud-images.ubuntu.com/$c/$serial/SHA256SUMS"
        $img.FileName = "ubuntu-$($r.Version)-$c-$serial.qcow2"
        $cap = $c.Substring(0, 1).ToUpperInvariant() + $c.Substring(1)
        $img.Label = "Ubuntu $($r.Version)$(if ($r.Lts) { ' LTS' }) ($cap, build $serial)"
        if ($Kind -eq 'dev') { $img.Label += ' - development daily' }
        return $img
    }
    throw "No Ubuntu cloud image found for channel '$Kind'."
}

function Resolve-QdFedora {
    $base = 'https://dl.fedoraproject.org/pub/fedora/linux/releases/'
    $nums = Get-QdHrefs (Get-QdWebText $base) '\d+/' | ForEach-Object { [int]$_.TrimEnd('/') } | Sort-Object -Descending | Select-Object -First 4
    foreach ($n in $nums) {
        $dir = "$base$n/Cloud/x86_64/images/"
        try { $html = Get-QdWebText $dir } catch { continue }
        $files = [regex]::Matches($html, "Fedora-Cloud-Base-Generic-$n-[0-9.]+\.x86_64\.qcow2") | ForEach-Object { $_.Value }
        $file = Select-QdNewest $files
        if (-not $file) { continue }
        $build = $file.Substring("Fedora-Cloud-Base-Generic-$n-".Length) -replace '\.x86_64\.qcow2$', ''
        $img = New-QdImage -Id 'fedora' -Family 'fedora' -Kind 'cloud'
        $img.Url = "https://download.fedoraproject.org/pub/fedora/linux/releases/$n/Cloud/x86_64/images/$file"
        if (-not (Test-QdUrl $img.Url)) { $img.Url = "$dir$file" }
        $img.SumUrl = "${dir}Fedora-Cloud-$n-$build-x86_64-CHECKSUM"
        $img.FileName = "fedora-$n-$build.qcow2"
        $img.Label = "Fedora $n Cloud (build $build)"
        return $img
    }
    throw 'No Fedora Cloud image found.'
}

function Resolve-QdNixos {
    param([ValidateSet('unstable', 'stable')][string]$Channel, [string]$Id)
    $candidates = @()
    if ($Channel -eq 'unstable') {
        $candidates = @('nixos-unstable')
    } else {
        $yy = [int](Get-Date -Format 'yy')
        foreach ($y in $yy, ($yy - 1), ($yy - 2)) { $candidates += "nixos-$y.11"; $candidates += "nixos-$y.05" }
    }
    foreach ($ch in $candidates) {
        $alias = "https://channels.nixos.org/$ch/latest-nixos-minimal-x86_64-linux.iso"
        $loc = Get-QdRedirect $alias
        if (-not $loc -or $loc -notmatch '\.iso$') { continue }
        $file = [IO.Path]::GetFileName((New-Object Uri($loc)).AbsolutePath)
        $img = New-QdImage -Id $Id -Family 'nixos' -Kind 'iso'
        $img.Url = $loc
        $img.SumUrl = "$loc.sha256"
        $img.FileName = $file
        $ver = ($file -replace '^nixos-minimal-', '' -replace '-x86_64-linux\.iso$', '')
        $img.Label = "NixOS $ver ($ch)"
        return $img
    }
    throw "No NixOS installer ISO found for channel '$Channel'."
}

function Get-QdMenuEntry {
    param([string]$Choice)
    for ($i = 0; $i -lt $script:QdMenu.Count; $i++) {
        $f = $script:QdMenu[$i] -split '\|'
        if ($Choice -eq "$($i + 1)" -or $Choice -eq $f[0]) {
            return [pscustomobject]@{ Number = $i + 1; Id = $f[0]; Label = $f[1]; Family = $f[2]; Kind = $f[3] }
        }
    }
    return $null
}

# Resolve the newest image for a menu id and fetch + parse its checksum file.
function Resolve-QdImage {
    param([string]$Id, [switch]$SkipChecksum)
    switch ($Id) {
        'ubuntu-lts' { $img = Resolve-QdUbuntu -Kind lts -Id $Id }
        'ubuntu-latest' { $img = Resolve-QdUbuntu -Kind latest -Id $Id }
        'ubuntu-dev' { $img = Resolve-QdUbuntu -Kind dev -Id $Id }
        'fedora' { $img = Resolve-QdFedora }
        'nixos' { $img = Resolve-QdNixos -Channel unstable -Id $Id }
        'nixos-stable' { $img = Resolve-QdNixos -Channel stable -Id $Id }
        default { throw "Unknown distro id '$Id'." }
    }
    if (-not $SkipChecksum) {
        $sums = Get-QdWebText $img.SumUrl
        $img.ExpectedHash = Get-QdExpectedHash $sums ([IO.Path]::GetFileName((New-Object Uri($img.Url)).AbsolutePath))
        if (-not $img.ExpectedHash) { throw "Checksum for $($img.Url) not found in $($img.SumUrl)." }
    }
    return $img
}

# Custom image from -ImageUrl: discovery skipped, -Distro decides customization.
function Get-QdCustomImage {
    param([string]$Url, [pscustomobject]$Entry, [string]$Checksum)
    $file = [IO.Path]::GetFileName((New-Object Uri($Url)).AbsolutePath)
    if (-not $file) { throw "Cannot derive a file name from -ImageUrl '$Url'." }
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($Entry.Family -eq 'nixos' -and $ext -ne '.iso') { throw 'For NixOS, -ImageUrl must point to a NixOS installer .iso.' }
    if ($Entry.Family -ne 'nixos' -and $ext -notin '.img', '.qcow2', '.vhd', '.vhdx') { throw "For $($Entry.Family), -ImageUrl must be a cloud image (.img, .qcow2, .vhd, .vhdx)." }
    $img = New-QdImage -Id $Entry.Id -Family $Entry.Family -Kind $Entry.Kind
    $img.Url = $Url
    $img.FileName = "custom-$file"
    $img.Label = "Custom image $file ($($Entry.Family) customization)"
    if ($Checksum) { $img.ExpectedHash = $Checksum.ToLowerInvariant() }
    return $img
}

# Download to *.part, verify the checksum, then promote into the cache.
function Save-QdDownload {
    param([string]$Url, [string]$Destination, [string]$ExpectedHash)
    $part = "$Destination.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    Write-QdInfo "Downloading $Url"
    Write-QdLine "    -> $Destination"
    $done = $false
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                Start-BitsTransfer -Source $Url -Destination $part -Description 'hyperv-linux-quick-deploy' -ErrorAction Stop -WhatIf:$false
                $done = $true
            } catch {
                Write-QdWarn "BITS download failed ($($_.Exception.Message)); retrying with WebClient."
                if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -WhatIf:$false }
            }
        }
        if (-not $done) {
            $wc = New-Object Net.WebClient
            $wc.Headers['User-Agent'] = $script:QdUserAgent
            try { $wc.DownloadFile($Url, $part) } finally { $wc.Dispose() }
        }
        $size = (Get-Item -LiteralPath $part).Length
        Write-QdOk "Downloaded $(Format-QdBytes $size)"
        if ($ExpectedHash) {
            $algo = if ($ExpectedHash.Length -eq 128) { 'SHA512' } else { 'SHA256' }
            $actual = (Get-FileHash -LiteralPath $part -Algorithm $algo).Hash.ToLowerInvariant()
            if ($actual -ne $ExpectedHash) {
                throw "CHECKSUM MISMATCH for $Url`n    expected $ExpectedHash`n    got      $actual`n    The file was deleted. Try again later."
            }
            Write-QdOk "$algo checksum verified"
        } else {
            Write-QdWarn 'No checksum available - download NOT verified (allowed by -AllowUnverifiedImage).'
        }
        Move-Item -LiteralPath $part -Destination $Destination -Force -WhatIf:$false
    } finally {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

# =============================================================================
# 6. Host tools: qemu-img (qcow2 -> VHDX) and the seed-media builder.
#    Both are proven by actually running them, not just by locating them.
# =============================================================================
function Find-QdQemuImg {
    $candidates = New-Object System.Collections.ArrayList
    if ($QemuImgPath) { [void]$candidates.Add($QemuImgPath) }
    $cmd = Get-Command qemu-img.exe, qemu-img -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData\chocolatey\bin")) {
        if ($root) {
            [void]$candidates.Add((Join-Path $root 'qemu\qemu-img.exe'))
            [void]$candidates.Add((Join-Path $root 'qemu-img.exe'))
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).ProviderPath }
    }
    if ($QemuImgPath) { throw "-QemuImgPath '$QemuImgPath' does not exist." }
    return $null
}

# Proves qemu-img works end-to-end: --version, create a qcow2, convert it to
# a dynamic VHDX with the exact options used for real images, check the VHDX
# signature (and Test-VHD when Hyper-V is present).
function Test-QdQemuImg {
    param([string]$Exe)
    $r = [pscustomobject]@{ Ok = $false; Version = ''; Detail = '' }
    if (-not $Exe) { $r.Detail = 'qemu-img not found'; return $r }
    $v = Invoke-QdNative $Exe @('--version')
    if ($v.ExitCode -ne 0) { $r.Detail = "qemu-img --version failed: $($v.Output)"; return $r }
    $r.Version = ($v.Output -split "`n")[0]
    $tmp = New-QdTempDir
    try {
        $q = Join-Path $tmp 'probe.qcow2'
        $x = Join-Path $tmp 'probe.vhdx'
        $c = Invoke-QdNative $Exe @('create', '-q', '-f', 'qcow2', $q, '64M')
        if ($c.ExitCode -ne 0) { $r.Detail = "qemu-img create failed: $($c.Output)"; return $r }
        $k = Invoke-QdNative $Exe @('convert', '-q', '-f', 'qcow2', '-O', 'vhdx', '-o', 'subformat=dynamic,block_state_zero=off', $q, $x)
        if ($k.ExitCode -ne 0) { $r.Detail = "qemu-img convert to vhdx failed: $($k.Output)"; return $r }
        if (-not (Test-QdVhdxSignature $x)) { $r.Detail = 'converted file is not a valid VHDX (bad signature)'; return $r }
        if (Get-Command Test-VHD -ErrorAction SilentlyContinue) {
            if (-not (Test-VHD -Path $x -ErrorAction SilentlyContinue)) { $r.Detail = 'Hyper-V Test-VHD rejected the converted VHDX'; return $r }
        }
        $r.Ok = $true
        $r.Detail = 'create + convert to VHDX verified'
        return $r
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}

function Test-QdVhdxSignature {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 8
        if ($fs.Read($buf, 0, 8) -ne 8) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buf) -eq 'vhdxfile')
    } finally { $fs.Dispose() }
}

# Ask, then install QEMU for Windows (provides qemu-img.exe).
function Install-QdQemuImg {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    Write-QdLine '=================================================================='
    Write-QdWarn 'qemu-img.exe is needed to convert the distro cloud image (qcow2) to VHDX.'
    if ($winget) {
        Write-QdLine '  It will run:'
        Write-QdLine '    winget install --id SoftwareFreedomConservancy.QEMU -e --silent'
        Write-QdLine "  (installs QEMU for Windows to $env:ProgramFiles\qemu)"
    } else {
        $listing = Get-QdWebText 'https://qemu.weilnetz.de/w64/'
        $exe = Select-QdNewest ([regex]::Matches($listing, 'qemu-w64-setup-\d{8}\.exe') | ForEach-Object { $_.Value })
        if (-not $exe) { throw 'Could not find the QEMU for Windows installer on qemu.weilnetz.de. Install qemu-img manually and pass -QemuImgPath.' }
        $url = "https://qemu.weilnetz.de/w64/$exe"
        $sumUrl = $url -replace '\.exe$', '.sha512'
        Write-QdLine '  It will download and silently install QEMU for Windows:'
        Write-QdLine "    $url"
        Write-QdLine "    verified against $sumUrl"
        Write-QdLine "    installer run as: $exe /S   (installs to $env:ProgramFiles\qemu)"
    }
    Write-QdLine '  Alternative: install any qemu-img.exe yourself and pass -QemuImgPath <path>.'
    Write-QdLine '=================================================================='
    if (-not (Test-QdInteractive) -and -not $Force) { throw 'qemu-img is missing and no terminal is available to ask. Re-run with -Force to allow the install, or pass -QemuImgPath.' }
    if (-not $Force -and -not (Read-QdYesNo 'Install QEMU for Windows on this host now?' 'n')) {
        throw 'qemu-img is required for Ubuntu/Fedora cloud images. Nothing was installed.'
    }
    Invoke-QdStep -Target 'this host' -Action 'Install QEMU for Windows (qemu-img)' -Script {
        if ($winget) {
            $res = Invoke-QdNative $winget.Source @('install', '--id', 'SoftwareFreedomConservancy.QEMU', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -PassThruOutput
            if ($res.ExitCode -ne 0) { throw "winget failed with exit code $($res.ExitCode)." }
        } else {
            $tmp = New-QdTempDir
            try {
                $inst = Join-Path $tmp $exe
                $sha = Get-QdExpectedHash (Get-QdWebText $sumUrl) $exe
                if (-not $sha) { throw "Could not read the checksum for $exe." }
                Save-QdDownload -Url $url -Destination $inst -ExpectedHash $sha
                $sig = Get-AuthenticodeSignature -FilePath $inst
                Write-QdInfo "Installer signature: $($sig.Status) $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject })"
                $p = Start-Process -FilePath $inst -ArgumentList '/S' -Wait -PassThru
                if ($p.ExitCode -ne 0) { throw "QEMU installer exited with code $($p.ExitCode)." }
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ---- Seed media: ISO via IMAPI2 (built into Windows) -> oscdimg -> FAT VHDX ----
$script:QdIsoWriterCode = @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class QdIsoWriter {
    public static void Write(string path, object stream, int blockSize, int totalBlocks) {
        IStream src = (IStream)stream;
        byte[] buf = new byte[blockSize];
        using (FileStream fs = File.Create(path)) {
            for (int i = 0; i < totalBlocks; i++) {
                src.Read(buf, blockSize, IntPtr.Zero);
                fs.Write(buf, 0, blockSize);
            }
        }
    }
}
'@

function New-QdIsoImapi {
    param([string]$SourceDir, [string]$IsoPath, [string]$Label)
    if (-not ('QdIsoWriter' -as [type])) { Add-Type -TypeDefinition $script:QdIsoWriterCode -Language CSharp }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet (keeps 'user-data' names)
    $fsi.VolumeName = $Label
    $fsi.Root.AddTree($SourceDir, $false)
    $res = $fsi.CreateResultImage()
    [QdIsoWriter]::Write($IsoPath, $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
}

function Find-QdOscdimg {
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $adk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (${env:ProgramFiles(x86)} -and (Test-Path -LiteralPath $adk)) { return $adk }
    return $null
}

function New-QdIsoOscdimg {
    param([string]$SourceDir, [string]$IsoPath, [string]$Label)
    $exe = Find-QdOscdimg
    if (-not $exe) { throw 'oscdimg.exe not found' }
    $r = Invoke-QdNative $exe @('-j2', "-l$Label", $SourceDir, $IsoPath)
    if ($r.ExitCode -ne 0) { throw "oscdimg failed: $($r.Output)" }
}

# Small FAT32 VHDX labelled $Label (cloud-init NoCloud also accepts vfat).
function New-QdFatVhdx {
    param([string]$SourceDir, [string]$VhdxPath, [string]$Label)
    $null = New-VHD -Path $VhdxPath -SizeBytes 64MB -Dynamic -ErrorAction Stop
    $mountDir = New-QdTempDir
    $mounted = $false
    try {
        $disk = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop | Get-Disk
        $mounted = $true
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -ErrorAction Stop
        $null = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $mountDir -ErrorAction Stop
        Copy-Item -Path (Join-Path $SourceDir '*') -Destination $mountDir -Recurse -Force
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $mountDir -ErrorAction SilentlyContinue
    } finally {
        if ($mounted) { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Validate an ISO9660 image: primary volume descriptor, volume label and a
# Joliet supplementary descriptor (needed for lower-case 'user-data').
function Test-QdIsoFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 20 * 2048) { return $false }
        $buf = New-Object byte[] 2048
        $null = $fs.Seek(16 * 2048, 'Begin')
        $null = $fs.Read($buf, 0, 2048)
        if ($buf[0] -ne 1 -or [Text.Encoding]::ASCII.GetString($buf, 1, 5) -ne 'CD001') { return $false }
        $vol = [Text.Encoding]::ASCII.GetString($buf, 40, 32).Trim()
        if ($Label -and $vol -ne $Label.ToUpperInvariant()) { return $false }
        for ($s = 17; $s -lt 32; $s++) {
            $null = $fs.Seek($s * 2048, 'Begin')
            if ($fs.Read($buf, 0, 2048) -ne 2048) { break }
            if ([Text.Encoding]::ASCII.GetString($buf, 1, 5) -ne 'CD001') { break }
            if ($buf[0] -eq 2) { return $true }   # Joliet SVD
            if ($buf[0] -eq 255) { break }
        }
        return $false
    } finally { $fs.Dispose() }
}

# Find the first seed-media method that really works on this host by building
# a test image with it. Result is cached for the run.
function Get-QdSeedMethod {
    param([switch]$Refresh)
    if ($script:QdSeedMethod -and -not $Refresh) { return $script:QdSeedMethod }
    $tried = New-Object System.Collections.ArrayList
    $tmp = New-QdTempDir
    try {
        $src = Join-Path $tmp 'src'
        [void][IO.Directory]::CreateDirectory($src)
        Write-QdUnixFile (Join-Path $src 'user-data') "#cloud-config`n"
        Write-QdUnixFile (Join-Path $src 'meta-data') "instance-id: probe`n"
        foreach ($m in 'imapi', 'oscdimg', 'fatvhdx') {
            try {
                switch ($m) {
                    'imapi' {
                        $iso = Join-Path $tmp 'imapi.iso'
                        New-QdIsoImapi $src $iso $script:QdSeedLabel
                        if (-not (Test-QdIsoFile $iso $script:QdSeedLabel)) { throw 'built ISO failed validation' }
                    }
                    'oscdimg' {
                        if (-not (Find-QdOscdimg)) { throw 'not installed' }
                        $iso = Join-Path $tmp 'oscdimg.iso'
                        New-QdIsoOscdimg $src $iso $script:QdSeedLabel
                        if (-not (Test-QdIsoFile $iso $script:QdSeedLabel)) { throw 'built ISO failed validation' }
                    }
                    'fatvhdx' {
                        if (-not (Get-Command New-VHD -ErrorAction SilentlyContinue) -or -not (Get-Command Format-Volume -ErrorAction SilentlyContinue)) { throw 'Hyper-V/Storage cmdlets missing' }
                        $vhd = Join-Path $tmp 'seed.vhdx'
                        New-QdFatVhdx $src $vhd $script:QdSeedLabel
                        if (-not (Test-QdVhdxSignature $vhd)) { throw 'built VHDX failed validation' }
                    }
                }
                $script:QdSeedMethod = [pscustomobject]@{ Method = $m; Tried = @($tried) }
                return $script:QdSeedMethod
            } catch {
                [void]$tried.Add("${m}: $($_.Exception.Message)")
            }
        }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    return [pscustomobject]@{ Method = $null; Tried = @($tried) }
}

# Build seed media from $SourceDir. Returns @{ Path; Kind = 'iso'|'vhdx' }.
function New-QdSeedMedia {
    param([string]$SourceDir, [string]$DestinationNoExt, [string]$Label)
    $m = (Get-QdSeedMethod).Method
    switch ($m) {
        'imapi' { $p = "$DestinationNoExt.iso"; New-QdIsoImapi $SourceDir $p $Label; if (-not (Test-QdIsoFile $p $Label)) { throw "Seed ISO $p failed validation." }; return [pscustomobject]@{ Path = $p; Kind = 'iso' } }
        'oscdimg' { $p = "$DestinationNoExt.iso"; New-QdIsoOscdimg $SourceDir $p $Label; if (-not (Test-QdIsoFile $p $Label)) { throw "Seed ISO $p failed validation." }; return [pscustomobject]@{ Path = $p; Kind = 'iso' } }
        'fatvhdx' { $p = "$DestinationNoExt.vhdx"; New-QdFatVhdx $SourceDir $p $Label; return [pscustomobject]@{ Path = $p; Kind = 'vhdx' } }
        default { throw 'No working seed-media builder (IMAPI2, oscdimg or FAT VHDX) on this host.' }
    }
}

# =============================================================================
# 7. Rendering guest configuration
# =============================================================================
function Expand-QdTemplate {
    param([string]$Name, [hashtable]$Values)
    if (-not $script:QdTemplates.ContainsKey($Name)) { throw "Template '$Name' is missing." }
    $text = $script:QdTemplates[$Name]
    foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
    $left = [regex]::Matches($text, '\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if ($left) { throw "Template '$Name' has unfilled placeholders: $($left -join ', ')" }
    return ($text -replace "`r`n", "`n")
}

# $Auth: Hash (or $null), RootHash (or $null), Keys (string[]), SshPwAuth (bool)
function New-QdCloudInit {
    param([string]$Family, [string]$VmHostname, [string]$User, [hashtable]$Auth, [string]$InstanceId)
    $keysBlock = ''
    if ($Auth.Keys.Count) {
        $keysBlock = "    ssh_authorized_keys:`n" + (($Auth.Keys | ForEach-Object { "      - $(ConvertTo-QdYamlString $_)" }) -join "`n") + "`n"
    }
    $passwdLine = ''
    if ($Auth.Hash) { $passwdLine = "    passwd: $(ConvertTo-QdYamlString $Auth.Hash)`n" }
    $rootBlock = ''
    if ($Auth.RootHash) {
        $rootBlock = "chpasswd:`n  expire: false`n  users:`n    - {name: root, password: $(ConvertTo-QdYamlString $Auth.RootHash), type: hash}`n"
    }
    if ($Family -eq 'fedora') {
        $groups = 'wheel'
        $packages = "packages:`n  - hyperv-daemons`n"
        $runcmd = @(
            "  - [sh, -c, 'systemctl enable --now hypervkvpd.service hypervvssd.service 2>/dev/null || true']"
        )
    } else {
        $groups = 'adm, sudo'
        $packages = ''
        $runcmd = @(
            "  - [sh, -c, 'apt-get install -y ""linux-cloud-tools-`$(uname -r)"" || apt-get install -y linux-cloud-tools-virtual || true']"
            "  - [sh, -c, 'systemctl enable --now hv-kvp-daemon.service 2>/dev/null || true']"
        )
    }
    $sudo = if ($Auth.Hash) { '"ALL=(ALL) ALL"' } else { '"ALL=(ALL) NOPASSWD:ALL"' }
    $userData = Expand-QdTemplate 'user-data' @{
        VERSION = $script:QdVersion; HOSTNAME = $VmHostname; USERNAME = $User
        SSH_PWAUTH = $(if ($Auth.SshPwAuth) { 'true' } else { 'false' })
        GROUPS = $groups; SUDO_RULE = $sudo
        LOCK_PASSWD = $(if ($Auth.Hash) { 'false' } else { 'true' })
        PASSWD_LINE = $passwdLine; SSH_KEYS_BLOCK = $keysBlock; ROOT_BLOCK = $rootBlock
        PACKAGES_BLOCK = $packages; RUNCMD = (($runcmd -join "`n") + "`n")
    }
    $metaData = Expand-QdTemplate 'meta-data' @{ INSTANCE_ID = $InstanceId; HOSTNAME = $VmHostname }
    return @{ 'user-data' = $userData; 'meta-data' = $metaData }
}

function New-QdNixosConfig {
    param([string]$VmHostname, [string]$User, [hashtable]$Auth)
    $pwLine = ''
    if ($Auth.Hash) { $pwLine = "    hashedPassword = ""$($Auth.Hash)"";`n" }
    $rootLine = ''
    if ($Auth.RootHash) { $rootLine = "  users.users.root.hashedPassword = ""$($Auth.RootHash)"";`n" }
    $keys = ($Auth.Keys | ForEach-Object { """$_""" }) -join ' '
    $cfg = Expand-QdTemplate 'configuration.nix' @{
        VERSION = $script:QdVersion; HOSTNAME = $VmHostname; USERNAME = $User
        SSH_PWAUTH = $(if ($Auth.SshPwAuth) { 'true' } else { 'false' })
        NIX_PASSWORD_LINE = $pwLine; NIX_ROOT_LINE = $rootLine; NIX_SSH_KEYS = $keys
        SUDO_NEEDS_PASSWORD = $(if ($Auth.Hash) { 'true' } else { 'false' })
    }
    $sh = Expand-QdTemplate 'install.sh' @{ VERSION = $script:QdVersion; HOSTNAME = $VmHostname }
    return @{ 'configuration.nix' = $cfg; 'install.sh' = $sh }
}

# Preflight: every template must render completely with representative values.
function Test-QdTemplates {
    $problems = New-Object System.Collections.ArrayList
    $auth = @{ Hash = (Get-QdSha512Crypt -PlainText 'probe' -Salt 'probesalt'); RootHash = $null; Keys = @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIProbeKeyProbeKeyProbeKeyProbeKeyProbeKey probe@host'); SshPwAuth = $false }
    try {
        foreach ($fam in 'ubuntu', 'fedora') {
            $ci = New-QdCloudInit -Family $fam -VmHostname 'probe' -User 'admin' -Auth $auth -InstanceId 'probe'
            if (-not $ci['user-data'].StartsWith('#cloud-config')) { [void]$problems.Add("$fam user-data does not start with #cloud-config") }
            if ($ci['user-data'] -match "`r") { [void]$problems.Add("$fam user-data contains CR characters") }
        }
        $nx = New-QdNixosConfig -VmHostname 'probe' -User 'admin' -Auth $auth
        if ($nx['configuration.nix'] -notmatch '@STATE_VERSION@') { [void]$problems.Add('configuration.nix lacks the @STATE_VERSION@ marker') }
        if (-not $nx['install.sh'].StartsWith('#!/usr/bin/env bash')) { [void]$problems.Add('install.sh has no shebang') }
        $open = ([regex]::Matches($nx['configuration.nix'], '\{')).Count
        $close = ([regex]::Matches($nx['configuration.nix'], '\}')).Count
        if ($open -ne $close) { [void]$problems.Add("configuration.nix braces unbalanced ($open vs $close)") }
    } catch { [void]$problems.Add($_.Exception.Message) }
    return , $problems.ToArray()
}

# =============================================================================
# 8. Hyper-V host / cluster discovery
# =============================================================================
function Get-QdHostInfo {
    $info = [pscustomobject]@{
        IsWindows = (Test-QdWindows); IsAdmin = $false; HyperV = $false; HyperVDetail = ''
        VmmsRunning = $false; VMHost = $null; LogicalProcessors = 0; ComputerName = $env:COMPUTERNAME
    }
    if (-not $info.IsWindows) { $info.HyperVDetail = 'not Windows'; return $info }
    $info.IsAdmin = Test-QdAdmin
    if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
        $info.HyperVDetail = 'Hyper-V PowerShell module not installed (Install-WindowsFeature Hyper-V-PowerShell)'
        return $info
    }
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    $info.VmmsRunning = [bool]($svc -and $svc.Status -eq 'Running')
    if (-not $info.VmmsRunning) { $info.HyperVDetail = 'Hyper-V Virtual Machine Management service (vmms) is not running'; return $info }
    try {
        $info.VMHost = Get-VMHost -ErrorAction Stop
        $info.LogicalProcessors = [int]$info.VMHost.LogicalProcessorCount
        $info.HyperV = $true
        $info.HyperVDetail = "Hyper-V host $($info.ComputerName)"
    } catch { $info.HyperVDetail = "Get-VMHost failed: $($_.Exception.Message)" }
    return $info
}

function Get-QdClusterInfo {
    param([string]$Mode)
    if ($Mode -eq 'Standalone') { return $null }
    $ci = $null
    if (Get-Command Get-Cluster -ErrorAction SilentlyContinue) {
        try {
            $cl = Get-Cluster -ErrorAction Stop
            $nodes = @(Get-ClusterNode -Cluster $cl.Name -ErrorAction Stop)
            $me = $nodes | Where-Object { $_.Name -ieq $env:COMPUTERNAME }
            if (-not $me) { throw "this computer is not a node of cluster $($cl.Name)" }
            if ("$($me.State)" -ne 'Up') { throw "this node is '$($me.State)', not Up" }
            $csv = @()
            foreach ($v in @(Get-ClusterSharedVolume -Cluster $cl.Name -ErrorAction Stop)) {
                foreach ($si in @($v.SharedVolumeInfo)) {
                    $csv += [pscustomobject]@{
                        Name = $v.Name; State = "$($v.State)"; Path = $si.FriendlyVolumeName
                        Free = [uint64]$si.Partition.FreeSpace; Size = [uint64]$si.Partition.Size
                    }
                }
            }
            $ci = [pscustomobject]@{
                Name = $cl.Name
                Nodes = @($nodes | Where-Object { "$($_.State)" -eq 'Up' } | ForEach-Object { $_.Name })
                AllNodes = @($nodes | ForEach-Object { $_.Name })
                Csv = @($csv | Where-Object { $_.State -eq 'Online' })
            }
        } catch {
            if ($Mode -eq 'Cluster') { throw "Cluster mode requested but the cluster is not usable: $($_.Exception.Message)" }
            Write-QdLog INFO "No usable cluster: $($_.Exception.Message)"
        }
    } elseif ($Mode -eq 'Cluster') {
        throw 'Cluster mode requested but the FailoverClusters module is not installed (Install-WindowsFeature RSAT-Clustering-PowerShell).'
    }
    return $ci
}

function Test-QdPathOnCsv {
    param([string]$Path, [object]$Cluster)
    if (-not $Cluster) { return $true }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    foreach ($c in $Cluster.Csv) {
        if ($full.StartsWith($c.Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-QdDefaultSwitch {
    param([object]$Cluster)
    $sw = @(Get-VMSwitch -ErrorAction SilentlyContinue)
    if (-not $sw.Count) { return $null }
    $ext = @($sw | Where-Object { "$($_.SwitchType)" -eq 'External' })
    if ($Cluster) {
        foreach ($s in ($ext + $sw)) {
            if ((Test-QdSwitchOnNodes -Name $s.Name -Cluster $Cluster).Count -eq 0) { return $s.Name }
        }
        return $null
    }
    if ($ext.Count) { return $ext[0].Name }
    return $sw[0].Name
}

# Returns the list of Up nodes that do NOT have a switch named $Name.
function Test-QdSwitchOnNodes {
    param([string]$Name, [object]$Cluster)
    $missing = @()
    foreach ($n in $Cluster.Nodes) {
        try {
            if ($n -ieq $env:COMPUTERNAME) { $null = Get-VMSwitch -Name $Name -ErrorAction Stop }
            else { $null = Get-VMSwitch -ComputerName $n -Name $Name -ErrorAction Stop }
        } catch { $missing += $n }
    }
    return , $missing
}

function Test-QdVmNameFree {
    param([string]$VmName, [object]$Cluster, [string]$BasePath)
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { return $false }
    if ($BasePath -and (Test-Path -LiteralPath (Join-Path $BasePath $VmName))) { return $false }
    if ($Cluster) {
        if (Get-ClusterGroup -Cluster $Cluster.Name -Name $VmName -ErrorAction SilentlyContinue) { return $false }
        foreach ($n in $Cluster.Nodes) {
            if ($n -ieq $env:COMPUTERNAME) { continue }
            try { if (Get-VM -ComputerName $n -Name $VmName -ErrorAction Stop) { return $false } } catch { Write-QdLog INFO "Get-VM on $n : $($_.Exception.Message)" }
        }
    }
    return $true
}

function Get-QdNextVmName {
    param([string]$Base, [object]$Cluster, [string]$BasePath)
    for ($i = 1; $i -lt 1000; $i++) {
        $n = "$Base-$i"
        if (Test-QdVmNameFree -VmName $n -Cluster $Cluster -BasePath $BasePath) { return $n }
    }
    throw "Could not find a free VM name for '$Base'."
}

# Pick the Up node with the most free physical memory.
function Select-QdNode {
    param([object]$Cluster, [int]$NeedMB)
    $best = $null
    foreach ($n in $Cluster.Nodes) {
        try {
            $os = if ($n -ieq $env:COMPUTERNAME) { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } else { Get-CimInstance Win32_OperatingSystem -ComputerName $n -ErrorAction Stop }
            $freeMB = [int]($os.FreePhysicalMemory / 1024)
            Write-QdLog INFO "Node $n free memory: $freeMB MiB"
            if (-not $best -or $freeMB -gt $best.FreeMB) { $best = [pscustomobject]@{ Name = $n; FreeMB = $freeMB } }
        } catch { Write-QdLog WARN "Cannot query memory on ${n}: $($_.Exception.Message)" }
    }
    if (-not $best) { return [pscustomobject]@{ Name = $env:COMPUTERNAME; FreeMB = 0 } }
    if ($best.FreeMB -lt $NeedMB) { Write-QdWarn "The best node ($($best.Name)) has only $($best.FreeMB) MiB free (VM needs $NeedMB MiB)." }
    return $best
}

function Test-QdMixedCpus {
    param([object]$Cluster)
    $names = @()
    foreach ($n in $Cluster.Nodes) {
        try {
            $p = if ($n -ieq $env:COMPUTERNAME) { Get-CimInstance Win32_Processor -ErrorAction Stop } else { Get-CimInstance Win32_Processor -ComputerName $n -ErrorAction Stop }
            $names += @($p | ForEach-Object { $_.Name.Trim() })
        } catch { Write-QdLog WARN "Cannot query CPU on ${n}" }
    }
    return (@($names | Select-Object -Unique).Count -gt 1)
}

# =============================================================================
# 9. Main workflow
# =============================================================================
function Show-QdImageSources {
    param([switch]$WithReachability)
    $ok = $true
    foreach ($line in $script:QdMenu) {
        $e = Get-QdMenuEntry (($line -split '\|')[0])
        try {
            $img = Resolve-QdImage -Id $e.Id
            Write-QdLine ('  [{0}] {1,-14} {2}' -f $e.Number, $e.Id, $img.Label)
            Write-QdLine "       $($img.Url)"
            if ($WithReachability) {
                if (Test-QdUrl $img.Url) { Write-QdLine "       [ok] reachable, checksum ($($img.ExpectedHash.Length * 4)-bit) read from $($img.SumUrl)" }
                else { Write-QdLine '       [!] image URL not reachable right now'; $ok = $false }
            }
        } catch {
            Write-QdLine ('  [{0}] {1,-14} [!] could not determine the newest image: {2}' -f $e.Number, $e.Id, $_.Exception.Message)
            $ok = $false
        }
    }
    return $ok
}

function Get-QdLocations {
    param([object]$HostInfo, [object]$Cluster)
    $loc = [pscustomobject]@{ VMPath = $VMPath; VMPathSource = 'set via -VMPath'; CachePath = $CachePath; CacheSource = 'set via -CachePath' }
    if (-not $loc.VMPath) {
        if ($Cluster -and $Cluster.Csv.Count) {
            $csv = $Cluster.Csv | Sort-Object Free -Descending | Select-Object -First 1
            $loc.VMPath = Join-Path $csv.Path 'Hyper-V'
            $loc.VMPathSource = "Cluster Shared Volume with the most free space ($($csv.Name))"
        } elseif ($HostInfo.VMHost) {
            $loc.VMPath = $HostInfo.VMHost.VirtualMachinePath
            $loc.VMPathSource = 'Hyper-V host default (Get-VMHost).VirtualMachinePath'
        }
    }
    if (-not $loc.CachePath -and $loc.VMPath) {
        $loc.CachePath = Join-Path $loc.VMPath 'QuickDeploy-Cache'
        $loc.CacheSource = if ($Cluster) { 'inside the VM path (on the CSV, shared by all nodes)' } else { 'inside the VM path' }
    }
    return $loc
}

function Show-QdLocations {
    param([object]$Loc, [object]$Cluster)
    Write-QdLine 'Where things will go:'
    Write-QdLine '  Image cache (downloads + converted VHDX):'
    Write-QdLine "    $($Loc.CachePath)"
    Write-QdLine "    ($($Loc.CacheSource))"
    if ($Loc.CachePath) {
        $state = if (Test-Path -LiteralPath $Loc.CachePath) { 'exists' } else { 'does NOT exist yet - will be created' }
        Write-QdLine "    $state, $(Format-QdBytes (Get-QdFreeSpace $Loc.CachePath)) free"
    }
    Write-QdLine '  VM configuration, disk and seed media:'
    Write-QdLine "    $($Loc.VMPath)\<vm-name>\"
    Write-QdLine "    ($($Loc.VMPathSource))"
    if ($Loc.VMPath) { Write-QdLine "    $(Format-QdBytes (Get-QdFreeSpace $Loc.VMPath)) free" }
    if ($Cluster) { Write-QdLine "  Cluster: $($Cluster.Name) - nodes up: $($Cluster.Nodes -join ', ')" }
}

# Collects every preflight problem. Returns @{ Errors; Warnings; ... }.
function Invoke-QdPreflight {
    param([object]$HostInfo, [object]$Cluster, [object]$Loc, [string]$Switch, [string]$Family, [switch]$Quiet)
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if (-not $HostInfo.IsWindows) { [void]$errors.Add('This script must run on Windows Server / Windows with Hyper-V.') }
    elseif (-not $HostInfo.IsAdmin) { [void]$errors.Add('Not running as Administrator (right-click PowerShell -> Run as administrator).') }
    if ($HostInfo.IsWindows -and -not $HostInfo.HyperV) { [void]$errors.Add("Hyper-V not usable: $($HostInfo.HyperVDetail)") }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $Cluster) {
        [void]$warnings.Add('PowerShell 7 uses an implicit-remoting shim for FailoverClusters; Windows PowerShell 5.1 (powershell.exe) is recommended on clusters.')
    }
    if ($HostInfo.HyperV) {
        if (-not $Switch) { [void]$errors.Add('No Hyper-V virtual switch found. Create one (New-VMSwitch) or pass -SwitchName.') }
        else {
            $sw = Get-VMSwitch -Name $Switch -ErrorAction SilentlyContinue
            if (-not $sw) { [void]$errors.Add("Virtual switch '$Switch' does not exist on this host.") }
            elseif ("$($sw.SwitchType)" -ne 'External') { [void]$warnings.Add("Switch '$Switch' is $($sw.SwitchType): the VM may have no internet (needed for package installs / NixOS install).") }
            if ($Cluster) {
                $miss = Test-QdSwitchOnNodes -Name $Switch -Cluster $Cluster
                if ($miss.Count) { [void]$errors.Add("Switch '$Switch' is missing on cluster node(s): $($miss -join ', '). Live migration would fail.") }
            }
        }
        if ($CpuCount -gt $HostInfo.LogicalProcessors -and $HostInfo.LogicalProcessors -gt 0) { [void]$errors.Add("-CpuCount $CpuCount exceeds the host's $($HostInfo.LogicalProcessors) logical processors.") }
    }
    if ($Cluster) {
        if (-not $Cluster.Csv.Count) { [void]$errors.Add("Cluster $($Cluster.Name) has no online Cluster Shared Volume.") }
        foreach ($p in @($Loc.VMPath, $Loc.CachePath)) {
            if ($p -and -not (Test-QdPathOnCsv $p $Cluster)) {
                if ($AllowNonCsvPath) { [void]$warnings.Add("'$p' is not on a Cluster Shared Volume (allowed by -AllowNonCsvPath); the VM will not be highly available.") }
                else { [void]$errors.Add("'$p' is not on a Cluster Shared Volume. Use a C:\ClusterStorage\... path, or -AllowNonCsvPath.") }
            }
        }
        if ($TargetNode -and ($Cluster.Nodes -notcontains $TargetNode)) { [void]$errors.Add("-TargetNode '$TargetNode' is not an Up node of $($Cluster.Name).") }
    } elseif ($TargetNode) { [void]$errors.Add('-TargetNode only applies to Failover Cluster mode.') }
    foreach ($pair in @(@($Loc.VMPath, $script:QdMinFreeVm, 'VM path'), @($Loc.CachePath, $script:QdMinFreeCache, 'cache'))) {
        if (-not $pair[0]) { [void]$errors.Add("No $($pair[2]) could be determined. Pass -VMPath / -CachePath."); continue }
        if (-not $HostInfo.IsWindows) { continue }
        if (-not (Test-QdWritable $pair[0])) { [void]$errors.Add("$($pair[2]) '$($pair[0])' is not writable.") }
        $free = Get-QdFreeSpace $pair[0]
        if ($free -lt $pair[1]) { [void]$errors.Add("Only $(Format-QdBytes $free) free for the $($pair[2]) '$($pair[0])' (need $(Format-QdBytes $pair[1])).") }
    }
    if ($HostInfo.IsWindows -and $Loc.VMPath) {
        $free = Get-QdFreeSpace $Loc.VMPath
        if ($free -lt [uint64]$DiskSizeGB * 1GB) { [void]$warnings.Add("The ${DiskSizeGB} GB disk is thin (dynamic) but only $(Format-QdBytes $free) is free on that volume.") }
    }
    $tpl = Test-QdTemplates
    foreach ($t in $tpl) { [void]$errors.Add("Template check: $t") }
    if ($HostInfo.IsWindows) {
        $seed = Get-QdSeedMethod
        if (-not $seed.Method) { [void]$errors.Add("No working seed-media builder: $($seed.Tried -join '; ')") }
    }
    return [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings) }
}

function Invoke-QdCheck {
    $rc = 0
    Write-QdLine '=== Pre-flight check (dry run - nothing will be changed) ==='
    $hi = Get-QdHostInfo
    Write-QdLine 'Environment:'
    Write-QdLine "  PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"
    Write-QdLine "  $(if ($hi.IsAdmin) { '[ok]' } else { '[!] ' })   Administrator"
    Write-QdLine "  $(if ($hi.HyperV) { '[ok]' } else { '[!] ' })   $($hi.HyperVDetail)"
    $cl = $null
    try { $cl = Get-QdClusterInfo -Mode $Mode } catch { Write-QdLine "  [!]    $($_.Exception.Message)"; $rc = 1 }
    if ($cl) {
        Write-QdLine "  [ok]   Failover Cluster '$($cl.Name)': up nodes $($cl.Nodes -join ', ')"
        foreach ($c in $cl.Csv) { Write-QdLine "         CSV $($c.Path)  $(Format-QdBytes $c.Free) free of $(Format-QdBytes $c.Size)" }
    } else { Write-QdLine '  [ok]   Standalone Hyper-V host mode' }
    $loc = Get-QdLocations -HostInfo $hi -Cluster $cl
    $sw = $SwitchName
    if (-not $sw -and $hi.HyperV) { $sw = Get-QdDefaultSwitch -Cluster $cl }
    Write-QdLine "  Virtual switch: $(if ($sw) { $sw } else { '(none found)' })"
    $pf = Invoke-QdPreflight -HostInfo $hi -Cluster $cl -Loc $loc -Switch $sw -Family 'ubuntu'
    Write-QdLine 'Tools (each one is actually run):'
    if ($hi.IsWindows) {
        $q = Find-QdQemuImg
        $qt = Test-QdQemuImg $q
        if ($qt.Ok) { Write-QdLine "  [ok]   qemu-img: $q ($($qt.Version)) - $($qt.Detail)" }
        else { Write-QdLine "  [!]    qemu-img: $($qt.Detail). Needed for Ubuntu/Fedora; the script offers to install QEMU for Windows."; $rc = 1 }
        $sm = Get-QdSeedMethod
        if ($sm.Method) { Write-QdLine "  [ok]   seed media builder: $($sm.Method) (test image built and validated)" }
        else { Write-QdLine "  [!]    seed media builder: none works ($($sm.Tried -join '; '))" }
    } else { Write-QdLine '  (skipped - not Windows)' }
    $tpl = Test-QdTemplates
    if ($tpl.Count -eq 0) { Write-QdLine '  [ok]   templates: user-data, meta-data, configuration.nix, install.sh render completely' }
    Write-QdLine ''
    Show-QdLocations -Loc $loc -Cluster $cl
    Write-QdLine ''
    Write-QdLine 'Image sources (newest releases, looked up live; checksum files fetched and parsed):'
    if (-not (Show-QdImageSources -WithReachability)) { Write-QdLine '  Some lookups failed; those entries fail until the mirror is reachable.'; $rc = 1 }
    if ($loc.CachePath -and (Test-Path -LiteralPath $loc.CachePath)) {
        Write-QdLine ''
        Write-QdLine "Already cached in $($loc.CachePath):"
        $files = @(Get-ChildItem -LiteralPath $loc.CachePath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.qcow2', '.img', '.vhdx', '.vhd', '.iso' })
        if ($files.Count) { foreach ($f in $files) { Write-QdLine ('  {0,10}  {1}' -f (Format-QdBytes $f.Length), $f.Name) } } else { Write-QdLine '  (none)' }
    }
    Write-QdLine ''
    foreach ($w in $pf.Warnings) { Write-QdWarn $w }
    foreach ($e in $pf.Errors) { Write-QdErr $e; $rc = 1 }
    if ($rc -eq 0) { Write-QdOk 'Ready. Run without -Check to create a VM.' }
    else { Write-QdWarn 'Action needed (see above). The script asks before installing anything.' }
    return $rc
}

function Get-QdAuth {
    param([pscustomobject]$Entry, [switch]$Interactive)
    $user = $UserName
    $pw = $Password
    if ($Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $user = $Credential.UserName.TrimStart('\')
        if ($user -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "Credential user name '$user' is not a valid Linux user name (lower case, a-z 0-9 _ -)." }
        $pw = $Credential.Password
    }
    if ($user -eq 'root') { throw 'Use a normal user name; root SSH login is never enabled.' }
    $keys = Get-QdSshKeys -Keys $SshPublicKey -Path $SshPublicKeyPath
    if ($Interactive) {
        $user = Read-QdValue -Prompt 'Linux user name' -Default $user -Validate { param($v) $v -match '^[a-z_][a-z0-9_-]{0,31}$' -and $v -ne 'root' } -Hint 'lower case letters, digits, _ or -'
        if (-not $keys.Count) {
            $found = @('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub') | ForEach-Object { Join-Path $HOME ".ssh\$_" } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($found -and (Read-QdYesNo "Add your SSH public key $found for login?" 'y')) { $keys = Get-QdSshKeys -Path $found }
        }
        if (-not $pw) {
            $need = ($keys.Count -eq 0)
            $msg = if ($need) { "Password for '$user' (min 8 characters)" } else { "Password for '$user' (console + sudo; Enter = SSH key only)" }
            while ($true) {
                $p1 = Read-Host -AsSecureString $msg
                if ($p1.Length -eq 0 -and -not $need) { $pw = $null; break }
                if ($p1.Length -lt 8) { Write-QdWarn 'At least 8 characters, please.'; continue }
                $p2 = Read-Host -AsSecureString 'Repeat password'
                if ((ConvertFrom-QdSecureString $p1) -cne (ConvertFrom-QdSecureString $p2)) { Write-QdWarn 'Passwords do not match.'; continue }
                $pw = $p1; break
            }
        }
    }
    if (-not $pw -and -not $keys.Count) { throw 'No login method: pass -Password (SecureString), -Credential, -SshPublicKey or -SshPublicKeyPath.' }
    if ($pw -and $pw.Length -lt 8) { throw 'The password must have at least 8 characters.' }
    $hash = $null
    if ($pw) { $hash = Get-QdSha512Crypt -PlainText (ConvertFrom-QdSecureString $pw) }
    $rootHash = $null
    if ($SetRootPassword) {
        if (-not $pw) { throw '-SetRootPassword needs a password.' }
        $rootHash = Get-QdSha512Crypt -PlainText (ConvertFrom-QdSecureString $pw)
    }
    $sshPw = [bool]($pw -and ($keys.Count -eq 0 -or $EnableSshPasswordAuth))
    return @{ User = $user; Hash = $hash; RootHash = $rootHash; Keys = $keys; SshPwAuth = $sshPw }
}

function Show-QdPlan {
    param($Ctx)
    Write-QdLine ''
    Write-QdLine '=================================================================='
    Write-QdLine " Deployment plan: $($Ctx.Image.Label)"
    Write-QdLine '=================================================================='
    Show-QdLocations -Loc $Ctx.Loc -Cluster $Ctx.Cluster
    Write-QdLine ''
    Write-QdLine 'Image:'
    if (Test-Path -LiteralPath $Ctx.RawPath) { Write-QdLine "  [cached]   $($Ctx.RawPath)" }
    else {
        Write-QdLine "  [download] $($Ctx.Image.Url)"
        Write-QdLine "          -> $($Ctx.RawPath)"
        if ($Ctx.Image.ExpectedHash) { Write-QdLine "             verified against $(if ($Ctx.Image.SumUrl) { $Ctx.Image.SumUrl } else { '-ImageChecksum' })" }
        else { Write-QdLine '             [!] NOT verified (no checksum)' }
    }
    if ($Ctx.Image.Kind -eq 'cloud') {
        if (Test-Path -LiteralPath $Ctx.ReadyPath) { Write-QdLine "  [cached]   VHDX: $($Ctx.ReadyPath)" }
        else { Write-QdLine "  [create]   VHDX: $($Ctx.ReadyPath)  (qemu-img convert, once per release)" }
    }
    Write-QdLine ''
    Write-QdLine 'New VM:'
    Write-QdLine "  Name       : $($Ctx.VmName)  (hostname $($Ctx.Hostname))"
    Write-QdLine "  Resources  : $CpuCount vCPU, $MemoryMB MiB RAM$(if ($DynamicMemory) { ' (dynamic)' }), $DiskSizeGB GB dynamic VHDX"
    Write-QdLine "  Firmware   : Generation 2, Secure Boot $($Ctx.SecureBootText)"
    Write-QdLine "  Network    : switch '$($Ctx.Switch)'$(if ($VlanId) { ", VLAN $VlanId" }), DHCP"
    if ($Ctx.Image.Kind -eq 'cloud') { Write-QdLine "  Setup      : cloud-init NoCloud seed ($((Get-QdSeedMethod).Method))" }
    else { Write-QdLine "  Setup      : NixOS installer ISO + config media, install mode $NixOSInstall (needs internet, ~5-15 min)" }
    $login = @()
    if ($Ctx.Auth.Hash) { $login += 'password (stored only as SHA-512 hash)' }
    if ($Ctx.Auth.Keys.Count) { $login += "$($Ctx.Auth.Keys.Count) SSH key(s)" }
    Write-QdLine "  Login      : $($Ctx.Auth.User) - $($login -join ' + '); SSH password auth $(if ($Ctx.Auth.SshPwAuth) { 'on' } else { 'off' }); root SSH off"
    if ($Ctx.Cluster) {
        Write-QdLine "  Cluster    : add as clustered role, place on node $($Ctx.TargetNode)$(if ($Ctx.ProcCompat) { ', processor compatibility ON' })"
    }
    Write-QdLine "  Start      : $(if ($NoStart) { 'no (-NoStart)' } else { 'yes' })"
    Write-QdLine '=================================================================='
}

function Add-QdVmHardware {
    param($Ctx, [string]$VmDir)
    $vm = New-VM -Name $Ctx.VmName -Generation 2 -MemoryStartupBytes ([int64]$MemoryMB * 1MB) -Path $Ctx.Loc.VMPath -NoVHD -SwitchName $Ctx.Switch -ErrorAction Stop
    $vmName = $Ctx.VmName
    Register-QdUndo -Description "VM $vmName" -Data @{ Name = $vmName } -Script { param($d) Stop-VM -Name $d.Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-VM -Name $d.Name -Force -ErrorAction Stop }
    Set-VMProcessor -VM $vm -Count $CpuCount -ErrorAction Stop
    if ($Ctx.ProcCompat) { Set-VMProcessor -VM $vm -CompatibilityForMigrationEnabled $true -ErrorAction Stop }
    if ($DynamicMemory) {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes ([int64][Math]::Min(512, $MemoryMB) * 1MB) -StartupBytes ([int64]$MemoryMB * 1MB) -MaximumBytes ([int64]$MemoryMB * 1MB) -ErrorAction Stop
    } else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -ErrorAction Stop
    }
    $notes = "Created by hyperv-linux-quick-deploy $($script:QdVersion) on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). OS: $($Ctx.Image.Label). User: $($Ctx.Auth.User)."
    $setVm = @{ VM = $vm; Notes = $notes; AutomaticStopAction = 'ShutDown'; ErrorAction = 'Stop' }
    if ($Ctx.Cluster) { $setVm.AutomaticStartAction = 'Nothing' } else { $setVm.AutomaticStartAction = 'StartIfRunning' }
    if ((Get-Command Set-VM).Parameters.ContainsKey('AutomaticCheckpointsEnabled')) { $setVm.AutomaticCheckpointsEnabled = $false }
    Set-VM @setVm
    if ($Ctx.SecureBootOn) { Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -ErrorAction Stop }
    else { Set-VMFirmware -VM $vm -EnableSecureBoot Off -ErrorAction Stop }
    if ($VlanId) { Set-VMNetworkAdapterVlan -VM $vm -Access -VlanId $VlanId -ErrorAction Stop }
    Get-VMIntegrationService -VM $vm | Where-Object { "$($_.Id)" -match $script:QdIcGuestService } | Enable-VMIntegrationService -ErrorAction SilentlyContinue
    return $vm
}

function Add-QdSeedToVm {
    param($Vm, [object]$Seed)
    if ($Seed.Kind -eq 'iso') { Add-VMDvdDrive -VM $Vm -Path $Seed.Path -ErrorAction Stop }
    else { Add-VMHardDiskDrive -VM $Vm -Path $Seed.Path -ErrorAction Stop }
}

function Wait-QdVmIp {
    param([string]$VmName, [string]$ComputerName, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-QdInfo "Waiting up to $TimeoutSec s for the VM to report its IP (Hyper-V KVP)..."
    while ((Get-Date) -lt $deadline) {
        $p = @{ VMName = $VmName; ErrorAction = 'SilentlyContinue' }
        if ($ComputerName -and $ComputerName -ine $env:COMPUTERNAME) { $p.ComputerName = $ComputerName }
        $ips = @(Get-VMNetworkAdapter @p | ForEach-Object { $_.IPAddresses } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' })
        if ($ips.Count) { return $ips[0] }
        Start-Sleep -Seconds 10
    }
    return $null
}

# Hyper-V keyboard API (Msvm_Keyboard) - types into the VM console.
function Send-QdVmKeys {
    param([object]$Vm, [string]$Text)
    $cs = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "Name='$($Vm.VMId.ToString().ToUpperInvariant())'" -ErrorAction Stop
    $kb = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard -ErrorAction Stop
    $r1 = Invoke-CimMethod -InputObject $kb -MethodName TypeText -Arguments @{ asciiText = $Text } -ErrorAction Stop
    $r2 = Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } -ErrorAction Stop
    if ($r1.ReturnValue -ne 0 -or $r2.ReturnValue -ne 0) { throw "Msvm_Keyboard returned $($r1.ReturnValue)/$($r2.ReturnValue)" }
}

function Invoke-QdNixosAutoInstall {
    param($Ctx, $Vm)
    $cmd = "sudo bash -c 'mkdir -p /qd && mount -o ro /dev/disk/by-label/$($script:QdNixLabel) /qd && bash /qd/install.sh'"
    Write-QdInfo 'Waiting for the NixOS live system to boot (heartbeat)...'
    $deadline = (Get-Date).AddSeconds(420)
    while ((Get-Date) -lt $deadline) {
        $v = Get-VM -Name $Ctx.VmName
        if ("$($v.Heartbeat)" -like 'Ok*') { break }
        Start-Sleep -Seconds 5
    }
    if ("$((Get-VM -Name $Ctx.VmName).Heartbeat)" -notlike 'Ok*') {
        Write-QdWarn 'No heartbeat from the live system after 7 minutes; typing the install command anyway.'
    }
    Start-Sleep -Seconds 20   # let getty auto-login as 'nixos' finish
    Send-QdVmKeys -Vm $Vm -Text $cmd
    Write-QdOk 'Install command typed into the VM console. NixOS is installing (watch it with vmconnect).'
    $deadline = (Get-Date).AddMinutes($NixOSInstallTimeoutMin)
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if ("$((Get-VM -Name $Ctx.VmName).State)" -eq 'Off') { return $true }
        Start-Sleep -Seconds 15
        $tick++
        if ($tick % 8 -eq 0) { Write-QdInfo "  still installing... ($([int]($tick / 4)) min)" }
    }
    return $false
}

function Complete-QdNixosInstall {
    param($Ctx)
    $vmName = $Ctx.VmName
    Get-VMDvdDrive -VMName $vmName | Remove-VMDvdDrive -ErrorAction Stop
    if ($Ctx.Seed.Kind -eq 'vhdx') {
        Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -ieq $Ctx.Seed.Path } | Remove-VMHardDiskDrive -ErrorAction Stop
    }
    Set-VMFirmware -VMName $vmName -FirstBootDevice (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -ieq $Ctx.DiskPath }) -ErrorAction Stop
}

function Invoke-QdDeploy {
    param($Ctx)
    $vmName = $Ctx.VmName
    $vmDir = Join-Path $Ctx.Loc.VMPath $vmName
    $Ctx.DiskPath = Join-Path $vmDir "Virtual Hard Disks\$vmName.vhdx"

    Invoke-QdStep -Target $Ctx.Loc.CachePath -Action 'Create image cache directory' -Script {
        if (-not (Test-Path -LiteralPath $Ctx.Loc.CachePath)) { $null = New-Item -ItemType Directory -Path $Ctx.Loc.CachePath -Force -ErrorAction Stop }
    }
    if (-not (Test-Path -LiteralPath $Ctx.RawPath)) {
        Invoke-QdStep -Target $Ctx.RawPath -Action "Download $($Ctx.Image.Url) and verify checksum" -Script {
            Save-QdDownload -Url $Ctx.Image.Url -Destination $Ctx.RawPath -ExpectedHash $Ctx.Image.ExpectedHash
        }
    }
    if ($Ctx.Image.Kind -eq 'cloud' -and -not (Test-Path -LiteralPath $Ctx.ReadyPath)) {
        Invoke-QdStep -Target $Ctx.ReadyPath -Action 'Convert cloud image to dynamic VHDX (cached)' -Script {
            $tmp = $Ctx.ReadyPath -replace '\.vhdx$', '.tmp.vhdx'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            try {
                $ext = [IO.Path]::GetExtension($Ctx.RawPath).ToLowerInvariant()
                if ($ext -eq '.vhdx') { Copy-Item -LiteralPath $Ctx.RawPath -Destination $tmp }
                elseif ($ext -eq '.vhd') { Convert-VHD -Path $Ctx.RawPath -DestinationPath $tmp -VHDType Dynamic -ErrorAction Stop }
                else {
                    Write-QdInfo "Converting with qemu-img (once per release)..."
                    $r = Invoke-QdNative $Ctx.QemuImg @('convert', '-p', '-O', 'vhdx', '-o', 'subformat=dynamic,block_state_zero=off', $Ctx.RawPath, $tmp) -PassThruOutput
                    if ($r.ExitCode -ne 0) { throw "qemu-img convert failed (exit $($r.ExitCode))." }
                }
                if (-not (Test-QdVhdxSignature $tmp)) { throw 'Converted file is not a VHDX.' }
                if (-not (Test-VHD -Path $tmp)) { throw 'Hyper-V rejected the converted VHDX (Test-VHD).' }
                Move-Item -LiteralPath $tmp -Destination $Ctx.ReadyPath -Force
                Write-QdOk "Cached VHDX: $($Ctx.ReadyPath)"
            } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
        }
    }

    Invoke-QdStep -Target $vmDir -Action 'Create VM folder' -Script {
        $null = New-Item -ItemType Directory -Path (Join-Path $vmDir 'Virtual Hard Disks') -Force -ErrorAction Stop
        Register-QdUndo -Description "folder $vmDir" -Data @{ Path = $vmDir } -Script { param($d) Remove-Item -LiteralPath $d.Path -Recurse -Force -ErrorAction Stop }
    }
    Invoke-QdStep -Target $Ctx.DiskPath -Action "Create $DiskSizeGB GB system disk" -Script {
        if ($Ctx.Image.Kind -eq 'cloud') {
            Copy-Item -LiteralPath $Ctx.ReadyPath -Destination $Ctx.DiskPath -ErrorAction Stop
            $size = (Get-VHD -Path $Ctx.DiskPath).Size
            $want = [uint64]$DiskSizeGB * 1GB
            if ($want -lt $size) { throw "-DiskSizeGB $DiskSizeGB is smaller than the image ($(Format-QdBytes $size))." }
            if ($want -gt $size) { Resize-VHD -Path $Ctx.DiskPath -SizeBytes $want -ErrorAction Stop }
        } else {
            $null = New-VHD -Path $Ctx.DiskPath -SizeBytes ([uint64]$DiskSizeGB * 1GB) -Dynamic -ErrorAction Stop
        }
    }
    Invoke-QdStep -Target $vmDir -Action 'Build guest configuration media' -Script {
        $work = New-QdTempDir
        try {
            if ($Ctx.Image.Kind -eq 'cloud') {
                $files = New-QdCloudInit -Family $Ctx.Image.Family -VmHostname $Ctx.Hostname -User $Ctx.Auth.User -Auth $Ctx.Auth -InstanceId ([guid]::NewGuid().ToString())
                $label = $script:QdSeedLabel; $base = Join-Path $vmDir 'cidata'
            } else {
                $files = New-QdNixosConfig -VmHostname $Ctx.Hostname -User $Ctx.Auth.User -Auth $Ctx.Auth
                $label = $script:QdNixLabel; $base = Join-Path $vmDir 'nixos-config'
            }
            foreach ($k in $files.Keys) { Write-QdUnixFile (Join-Path $work $k) $files[$k] }
            $Ctx.Seed = New-QdSeedMedia -SourceDir $work -DestinationNoExt $base -Label $label
            Write-QdOk "Configuration media: $($Ctx.Seed.Path)"
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Invoke-QdStep -Target $vmName -Action 'Create and configure Generation 2 VM' -Script {
        $vm = Add-QdVmHardware -Ctx $Ctx -VmDir $vmDir
        if ($Ctx.Image.Kind -eq 'cloud') {
            $hdd = Add-VMHardDiskDrive -VM $vm -Path $Ctx.DiskPath -Passthru -ErrorAction Stop
            Add-QdSeedToVm -Vm $vm -Seed $Ctx.Seed
            Set-VMFirmware -VM $vm -FirstBootDevice $hdd -ErrorAction Stop
        } else {
            $dvd = Add-VMDvdDrive -VM $vm -Path $Ctx.RawPath -Passthru -ErrorAction Stop
            Add-QdSeedToVm -Vm $vm -Seed $Ctx.Seed
            $null = Add-VMHardDiskDrive -VM $vm -Path $Ctx.DiskPath -Passthru -ErrorAction Stop
            Set-VMFirmware -VM $vm -FirstBootDevice $dvd -ErrorAction Stop
        }
        $Ctx.Vm = $vm
        Write-QdOk "VM $vmName created"
    }
    if ($Ctx.Cluster) {
        Invoke-QdStep -Target $vmName -Action "Add VM as clustered role in $($Ctx.Cluster.Name)" -Script {
            $null = Add-ClusterVirtualMachineRole -Cluster $Ctx.Cluster.Name -VMName $vmName -Name $vmName -ErrorAction Stop
            Register-QdUndo -Description "cluster role $vmName" -Data @{ Cluster = $Ctx.Cluster.Name; Name = $vmName } -Script { param($d) Remove-ClusterGroup -Cluster $d.Cluster -Name $d.Name -RemoveResources -Force -ErrorAction Stop }
            Write-QdOk 'Clustered role added (highly available)'
        }
    }

    $Ctx.Owner = $env:COMPUTERNAME
    if ($Ctx.Image.Kind -eq 'iso') {
        if ($NoStart) {
            Write-QdWarn 'NixOS with -NoStart: start the VM yourself and run the install command shown below at the console.'
            $script:QdUndo.Clear()
            $Ctx.NixosPending = $true
            return
        }
        Invoke-QdStep -Target $vmName -Action 'Boot the NixOS installer' -Script { Start-VM -Name $vmName -ErrorAction Stop }
        $script:QdUndo.Clear()   # VM exists and runs: from here on, never auto-delete it
        if ($NixOSInstall -eq 'Manual') { $Ctx.NixosPending = $true; return }
        $finished = [bool](Invoke-QdStep -Target $vmName -Action 'Run the unattended NixOS install' -Script {
                Invoke-QdNixosAutoInstall -Ctx $Ctx -Vm $Ctx.Vm
            })
        if (-not $finished) { $Ctx.NixosPending = $true; return }
        Invoke-QdStep -Target $vmName -Action 'Remove installer media and boot from disk' -Script { Complete-QdNixosInstall -Ctx $Ctx }
    }
    if ($Ctx.Cluster -and $Ctx.TargetNode -and $Ctx.TargetNode -ine $env:COMPUTERNAME) {
        Invoke-QdStep -Target $vmName -Action "Move clustered role to node $($Ctx.TargetNode)" -Script {
            $null = Move-ClusterVirtualMachineRole -Cluster $Ctx.Cluster.Name -Name $vmName -Node $Ctx.TargetNode -MigrationType Quick -ErrorAction Stop
            $Ctx.Owner = $Ctx.TargetNode
            Write-QdOk "Role moved to $($Ctx.TargetNode)"
        }
    }
    if (-not $NoStart) {
        Invoke-QdStep -Target $vmName -Action 'Start VM' -Script {
            if ($Ctx.Cluster) { $null = Start-ClusterGroup -Cluster $Ctx.Cluster.Name -Name $vmName -ErrorAction Stop }
            else { Start-VM -Name $vmName -ErrorAction Stop }
            Write-QdOk "$vmName is booting"
        }
    }
    $script:QdUndo.Clear()
}

function Show-QdSummary {
    param($Ctx, [string]$Ip)
    $vmName = $Ctx.VmName
    Write-QdLine ''
    Write-QdLine '===================================================='
    if ($Ctx.NixosPending) { Write-QdLine "VM $vmName created - NixOS install still needs to finish" }
    else { Write-QdLine "Success! $vmName ($($Ctx.Image.Label)) is $(if ($NoStart) { 'ready (not started)' } else { 'running' })." }
    Write-QdLine "  Host/node : $($Ctx.Owner)$(if ($Ctx.Cluster) { " (cluster $($Ctx.Cluster.Name), clustered role '$vmName')" })"
    Write-QdLine "  Disk      : $($Ctx.DiskPath)"
    Write-QdLine "  Login     : $($Ctx.Auth.User)$(if ($Ctx.Auth.Keys.Count) { ' (SSH key)' })$(if ($Ctx.Auth.Hash) { ' / your password' })"
    if ($Ip) { Write-QdLine "  IP        : $Ip   ->   ssh $($Ctx.Auth.User)@$Ip" }
    else { Write-QdLine "  IP        : Get-VMNetworkAdapter -VMName '$vmName'$(if ($Ctx.Owner -ine $env:COMPUTERNAME) { " -ComputerName $($Ctx.Owner)" }) | Select-Object -ExpandProperty IPAddresses" }
    Write-QdLine "  Console   : vmconnect.exe $($Ctx.Owner) '$vmName'"
    if ($Ctx.NixosPending) {
        Write-QdLine ''
        Write-QdLine '  To finish the NixOS install:'
        Write-QdLine "   1. Open the console (vmconnect) and type:"
        Write-QdLine "      sudo bash -c 'mkdir -p /qd && mount -o ro /dev/disk/by-label/$($script:QdNixLabel) /qd && bash /qd/install.sh'"
        Write-QdLine '   2. When the VM has powered off, run:'
        Write-QdLine "      Get-VMDvdDrive -VMName '$vmName' | Remove-VMDvdDrive"
        Write-QdLine "      Set-VMFirmware -VMName '$vmName' -FirstBootDevice (Get-VMHardDiskDrive -VMName '$vmName' | Where-Object Path -like '*\$vmName.vhdx')"
        Write-QdLine "      Start-VM -Name '$vmName'"
    } elseif ($Ctx.Image.Kind -eq 'cloud') {
        Write-QdLine '  Note      : cloud-init needs ~1-2 min on first boot (installs the Hyper-V KVP daemon).'
    }
    if ($script:QdLogFile) { Write-QdLine "  Log       : $($script:QdLogFile)" }
    Write-QdLine '===================================================='
}

function Invoke-QdMain {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    Initialize-QdNetwork

    if ($Check -and $List) { throw '-Check and -List cannot be combined.' }
    if ($List) {
        Write-QdLine 'Newest images available right now (looked up live):'
        if (Show-QdImageSources) { return 0 } else { return 1 }
    }
    if ($Check) { return (Invoke-QdCheck) }

    $interactive = Test-QdInteractive
    if (-not $interactive -and -not $Force -and -not $WhatIfPreference) {
        throw 'No interactive console available. Re-run with -Force (and all required parameters), or use -WhatIf to preview.'
    }

    $hi = Get-QdHostInfo
    if (-not $hi.IsWindows -or -not $hi.IsAdmin -or -not $hi.HyperV) {
        if (-not $hi.IsWindows) { throw 'This script must run on Windows with Hyper-V.' }
        if (-not $hi.IsAdmin) { throw 'Run PowerShell as Administrator.' }
        throw "Hyper-V not usable: $($hi.HyperVDetail)"
    }
    if (-not $WhatIfPreference) {
        $logDir = Join-Path $env:ProgramData 'hyperv-linux-quick-deploy\logs'
        try {
            [void][IO.Directory]::CreateDirectory($logDir)
            $script:QdLogFile = Join-Path $logDir ("deploy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        } catch { $script:QdLogFile = $null }
    }
    Write-QdLine "=== Hyper-V Linux Quick Deploy $($script:QdVersion) ==="
    $cluster = Get-QdClusterInfo -Mode $Mode
    if ($cluster) { Write-QdOk "Failover Cluster '$($cluster.Name)' detected - cluster-aware mode (nodes up: $($cluster.Nodes -join ', '))" }
    else { Write-QdOk "Standalone Hyper-V host $($hi.ComputerName)" }

    # --- distro ---
    $choice = $Distro
    if (-not $choice) {
        if (-not $interactive) { throw '-Distro is required in non-interactive mode.' }
        Write-QdLine 'Select an OS (the newest version is looked up live):'
        for ($i = 0; $i -lt $script:QdMenu.Count; $i++) { Write-QdLine ('  [{0}] {1}' -f ($i + 1), ($script:QdMenu[$i] -split '\|')[1]) }
        $choice = Read-QdValue -Prompt "Select OS (1-$($script:QdMenu.Count))" -Default '1' -Validate { param($v) [bool](Get-QdMenuEntry $v) } -Hint 'unknown choice'
    }
    $entry = Get-QdMenuEntry $choice
    if (-not $entry) { throw "Invalid distro '$choice'." }

    if ($ImageUrl) {
        $img = Get-QdCustomImage -Url $ImageUrl -Entry $entry -Checksum $ImageChecksum
        if (-not $img.ExpectedHash -and -not $AllowUnverifiedImage) { throw '-ImageUrl needs -ImageChecksum (SHA256/SHA512), or -AllowUnverifiedImage to accept an unverified download.' }
    } else {
        Write-QdInfo "Looking up the newest '$($entry.Id)' image and its checksum..."
        $img = Resolve-QdImage -Id $entry.Id
        if (-not (Test-QdUrl $img.Url)) { throw "Image URL is not reachable: $($img.Url)" }
        Write-QdOk "Found: $($img.Label)"
    }

    # --- secure boot ---
    if ($entry.Family -eq 'nixos' -and $SecureBoot -eq 'On') { throw 'NixOS installer/boot loader is not signed for Secure Boot. Use -SecureBoot Off or Auto.' }
    $sbOn = ($SecureBoot -eq 'On') -or ($SecureBoot -eq 'Auto' -and $entry.Family -ne 'nixos')
    $sbText = if ($sbOn) { 'On (Microsoft UEFI Certificate Authority template)' } else { 'Off' + $(if ($entry.Family -eq 'nixos') { ' (NixOS boot loader is unsigned)' }) }

    # --- locations / switch / name ---
    $loc = Get-QdLocations -HostInfo $hi -Cluster $cluster
    $sw = $SwitchName
    if (-not $sw) { $sw = Get-QdDefaultSwitch -Cluster $cluster }
    $vmName = $Name
    if ($interactive) {
        $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($($_.SwitchType))" })
        if ($switches.Count) { Write-QdLine "Virtual switches: $($switches -join ', ')" }
        $sw = Read-QdValue -Prompt 'Virtual switch' -Default $sw -Validate { param($v) [bool](Get-VMSwitch -Name $v -ErrorAction SilentlyContinue) } -Hint 'no such switch'
        if (-not $vmName) { $vmName = Get-QdNextVmName -Base $entry.Family -Cluster $cluster -BasePath $loc.VMPath }
        $vmName = Read-QdValue -Prompt 'VM name' -Default $vmName -Validate { param($v) $v -match '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' } -Hint 'letters, digits and -, max 63'
        $script:CpuCount = [int](Read-QdValue -Prompt 'vCPUs' -Default "$CpuCount" -Validate { param($v) $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le [Math]::Max(1, $hi.LogicalProcessors) } -Hint "1-$($hi.LogicalProcessors)")
        $script:MemoryMB = [int](Read-QdValue -Prompt 'Memory (MiB)' -Default "$MemoryMB" -Validate { param($v) $v -match '^\d+$' -and [int]$v -ge 512 } -Hint 'at least 512')
        $script:DiskSizeGB = [int](Read-QdValue -Prompt 'Disk size (GB)' -Default "$DiskSizeGB" -Validate { param($v) $v -match '^\d+$' -and [int]$v -ge 8 -and [int]$v -le 65536 } -Hint '8-65536')
    } elseif (-not $vmName) {
        $vmName = Get-QdNextVmName -Base $entry.Family -Cluster $cluster -BasePath $loc.VMPath
    }
    if (-not (Test-QdVmNameFree -VmName $vmName -Cluster $cluster -BasePath $loc.VMPath)) { throw "A VM, cluster role or folder named '$vmName' already exists. Nothing is ever overwritten - pick another -Name." }

    # --- preflight ---
    $pf = Invoke-QdPreflight -HostInfo $hi -Cluster $cluster -Loc $loc -Switch $sw -Family $entry.Family
    foreach ($w in $pf.Warnings) { Write-QdWarn $w }
    if ($pf.Errors.Count) {
        foreach ($e in $pf.Errors) { Write-QdErr $e }
        throw 'Pre-flight checks failed (see above). Nothing was changed. Run with -Check for a full report.'
    }
    Write-QdOk "Pre-flight passed (seed media: $((Get-QdSeedMethod).Method))"

    $ctx = @{
        Image = $img; Entry = $entry; Loc = $loc; Cluster = $cluster; Switch = $sw; VmName = $vmName
        Hostname = (ConvertTo-QdHostname $vmName); SecureBootOn = $sbOn; SecureBootText = $sbText
        RawPath = (Join-Path $loc.CachePath $img.FileName); ReadyPath = $null; QemuImg = $null
        TargetNode = $null; ProcCompat = $false; Seed = $null; Vm = $null; DiskPath = $null; Owner = $env:COMPUTERNAME
        NixosPending = $false; Auth = $null
    }
    if ($img.Kind -eq 'cloud') { $ctx.ReadyPath = Join-Path $loc.CachePath ('ready-' + [IO.Path]::GetFileNameWithoutExtension($img.FileName) + '.vhdx') }

    # --- qemu-img (only needed when a qcow2 must still be converted) ---
    $needQemu = $img.Kind -eq 'cloud' -and -not (Test-Path -LiteralPath $ctx.ReadyPath) -and ([IO.Path]::GetExtension($img.FileName) -notin '.vhd', '.vhdx')
    if ($needQemu) {
        $q = Find-QdQemuImg
        $qt = Test-QdQemuImg $q
        if (-not $qt.Ok) {
            if ($WhatIfPreference) { Write-QdWarn "qemu-img not usable ($($qt.Detail)); a real run would offer to install QEMU for Windows." }
            else {
                Install-QdQemuImg
                $q = Find-QdQemuImg
                $qt = Test-QdQemuImg $q
                if (-not $qt.Ok) { throw "qemu-img is still not functional after installation: $($qt.Detail)" }
            }
        }
        if ($qt.Ok) { Write-QdOk "qemu-img: $q ($($qt.Version)) - $($qt.Detail)" }
        $ctx.QemuImg = $q
    }

    # --- credentials ---
    $ctx.Auth = Get-QdAuth -Entry $entry -Interactive:$interactive

    # --- cluster placement ---
    if ($cluster) {
        if ($TargetNode) { $ctx.TargetNode = $TargetNode } else { $ctx.TargetNode = (Select-QdNode -Cluster $cluster -NeedMB $MemoryMB).Name }
        $ctx.ProcCompat = switch ($ProcessorCompatibility) { 'On' { $true } 'Off' { $false } default { Test-QdMixedCpus -Cluster $cluster } }
    } elseif ($ProcessorCompatibility -eq 'On') { $ctx.ProcCompat = $true }

    Show-QdPlan -Ctx $ctx
    if (-not $WhatIfPreference -and -not $Force) {
        if (-not (Read-QdYesNo 'Proceed with this plan?' 'y')) { Write-QdInfo 'Aborted. Nothing was downloaded or created.'; return 0 }
    }

    $completed = $false
    try {
        Invoke-QdDeploy -Ctx $ctx
        $completed = $true
    } catch {
        Write-QdErr "Deployment failed: $($_.Exception.Message)"
        Write-QdLog ERROR ($_ | Out-String)
        throw
    } finally {
        if (-not $completed) { Invoke-QdRollback }
    }
    if ($WhatIfPreference) { Write-QdInfo 'WhatIf: nothing was changed.'; return 0 }

    $ip = $null
    if (-not $NoStart -and -not $NoWait -and -not $ctx.NixosPending -and $WaitTimeoutSec -gt 0) {
        $ip = Wait-QdVmIp -VmName $vmName -ComputerName $ctx.Owner -TimeoutSec $WaitTimeoutSec
        if (-not $ip) { Write-QdWarn 'No IP reported yet (KVP daemon may still be installing). The VM keeps booting.' }
    }
    Show-QdSummary -Ctx $ctx -Ip $ip
    return 0
}

# Dot-sourcing (e.g. from Pester) only loads the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

$qdExit = 1
try {
    $qdExit = Invoke-QdMain
} catch {
    Write-QdErr $_.Exception.Message
    $qdExit = 1
}
if ($PSCommandPath) { exit $qdExit } else { $global:LASTEXITCODE = $qdExit }
