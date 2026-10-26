#Requires -Version 5.1
# Pester 5+ tests. Offline by default; live mirror checks run with: -TagFilter Live
#   Invoke-Pester ./tests                       # unit tests (no network, no Hyper-V)
#   Invoke-Pester ./tests -TagFilter Live       # also resolve every image on the real mirrors

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'New-QuickLinuxVM.ps1'
    # Dot-sourcing only loads the functions (the script returns before running main).
    . $script:ScriptPath
    $script:SampleKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq2YrX0xqvJ2oV0vP4m3l9cXr9ZlYQyqW1F0sJ0aBcD user@host'
    $script:Auth = @{
        Hash = (Get-QdSha512Crypt -PlainText 'correct horse' -Salt 'testsalt'); RootHash = $null
        Keys = @($script:SampleKey); SshPwAuth = $false
    }
}

Describe 'Script file' {
    It 'parses without errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:ScriptPath).ProviderPath, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'is pure ASCII (safe for Windows PowerShell 5.1 without BOM)' {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path $script:ScriptPath).ProviderPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'contains no hard-coded password or secret' {
        $text = Get-Content -Raw $script:ScriptPath
        $text | Should -Not -Match '(?i)password\s*=\s*[''"][^''"]+[''"]'
        $text | Should -Not -Match '(?i)ConvertTo-SecureString\s+-String\s+[''"]'
    }
    It 'supports -WhatIf / -Confirm' {
        $cmd = Get-Command $script:ScriptPath
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
    }
}

Describe 'Parameter validation' {
    BeforeAll { $script:Params = (Get-Command $script:ScriptPath).Parameters }
    It 'offers only Ubuntu, Fedora and NixOS distros' {
        $set = $script:Params['Distro'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $set.ValidValues | Sort-Object | Should -Be (@('fedora', 'nixos', 'nixos-stable', 'ubuntu-dev', 'ubuntu-latest', 'ubuntu-lts') | Sort-Object)
    }
    It 'rejects an unknown distro' {
        { & $script:ScriptPath -Distro debian -WhatIf } | Should -Throw
    }
    It 'rejects an invalid VM name' {
        { & $script:ScriptPath -Distro fedora -Name 'bad name!' -WhatIf } | Should -Throw
    }
    It 'rejects a malformed -ImageChecksum' {
        { & $script:ScriptPath -Distro fedora -ImageChecksum 'abc' -WhatIf } | Should -Throw
    }
    It 'rejects an invalid Linux user name' {
        { & $script:ScriptPath -Distro fedora -UserName 'Admin User' -WhatIf } | Should -Throw
    }
    It 'takes the password only as SecureString' {
        $script:Params['Password'].ParameterType | Should -Be ([securestring])
    }
}

Describe 'Menu' {
    It 'has 6 entries, all ubuntu/fedora/nixos' {
        $script:QdMenu.Count | Should -Be 6
        foreach ($l in $script:QdMenu) { ($l -split '\|')[2] | Should -BeIn @('ubuntu', 'fedora', 'nixos') }
    }
    It 'resolves by number and by id' {
        (Get-QdMenuEntry '4').Id | Should -Be 'fedora'
        (Get-QdMenuEntry 'nixos-stable').Kind | Should -Be 'iso'
        Get-QdMenuEntry '99' | Should -BeNullOrEmpty
    }
}

Describe 'SHA-512 crypt ($6$)' {
    It 'matches the reference vector from the spec (default rounds)' {
        Get-QdSha512Crypt -PlainText 'Hello world!' -Salt 'saltstring' -Rounds 5000 |
            Should -BeExactly '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1'
    }
    It 'matches the reference vector from the spec (rounds=10000, long salt truncated)' {
        Get-QdSha512Crypt -PlainText 'Hello world!' -Salt 'saltstringsaltstring' -Rounds 10000 |
            Should -BeExactly '$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.'
    }
    It 'matches openssl passwd -6 -salt saltsalt password' {
        Get-QdSha512Crypt -PlainText 'password' -Salt 'saltsalt' |
            Should -BeExactly '$6$saltsalt$qFmFH.bQmmtXzyBY0s9v7Oicd2z4XSIecDzlB5KiA2/jctKu9YterLp8wwnSq.qc.eoxqOmSuNp2xS0ktL3nh/'
    }
    It 'uses a random salt when none is given' {
        $a = Get-QdSha512Crypt -PlainText 'x'
        $b = Get-QdSha512Crypt -PlainText 'x'
        $a | Should -Match '^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$'
        $a | Should -Not -Be $b
    }
    It 'round-trips a SecureString' {
        $s = New-Object securestring
        'p@ss'.ToCharArray() | ForEach-Object { $s.AppendChar($_) }
        ConvertFrom-QdSecureString $s | Should -BeExactly 'p@ss'
    }
}

Describe 'Checksum parsing' {
    BeforeAll { $script:H256 = 'a' * 64; $script:H512 = 'B' * 128 }
    It 'reads GNU format' {
        Get-QdExpectedHash "$($script:H256) *noble.img`n$('c' * 64)  other.img" 'noble.img' | Should -Be $script:H256
    }
    It 'reads BSD format (Fedora CHECKSUM)' {
        $sums = "# Fedora-Cloud-44-1.7-x86_64-CHECKSUM`nSHA256 (Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2) = $($script:H256)"
        Get-QdExpectedHash $sums 'Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2' | Should -Be $script:H256
    }
    It 'reads a bare hash file (NixOS .sha256) and SHA-512 lower-cased' {
        Get-QdExpectedHash "$($script:H512)`n" 'whatever.iso' | Should -Be $script:H512.ToLowerInvariant()
    }
    It 'does not match a different file name' {
        Get-QdExpectedHash "$($script:H256)  a.img`n$('d' * 64)  b.img" 'c.img' | Should -BeNullOrEmpty
    }
    It 'does not match a file name that is only a prefix' {
        Get-QdExpectedHash "$($script:H256)  noble.img.zsync" 'noble.img' | Should -BeNullOrEmpty
    }
}

Describe 'Discovery helpers' {
    It 'parses Ubuntu meta-release' {
        $text = "Dist: noble`nName: Noble Numbat`nVersion: 24.04.3 LTS`nSupported: 1`n`nDist: plucky`nVersion: 25.04`n`nDist: resolute`nVersion: 26.04.1 LTS`n"
        $r = ConvertFrom-QdUbuntuMetaRelease $text
        $r.Count | Should -Be 3
        $r[0].Codename | Should -Be 'noble'
        $r[0].Lts | Should -BeTrue
        $r[1].Lts | Should -BeFalse
        $r[2].Version | Should -Be '26.04'
    }
    It 'sorts versions naturally' {
        Select-QdNewest @('20240101', '20241002', '20240930.1') | Should -Be '20241002'
        Select-QdNewest @('Fedora-44-1.10', 'Fedora-44-1.9') | Should -Be 'Fedora-44-1.10'
    }
    It 'extracts hrefs' {
        Get-QdHrefs '<a href="20250101/">x</a><a href="20250102/">y</a><a href="../">up</a>' '\d{8}/' | Sort-Object | Should -Be @('20250101/', '20250102/')
    }
    It 'sends a non-browser User-Agent (Fedora mirror anti-bot)' {
        $script:QdUserAgent | Should -Not -Match 'Mozilla'
    }
}

Describe 'Input validation' {
    It 'accepts valid public keys' {
        Test-QdSshKey $script:SampleKey | Should -BeTrue
        Test-QdSshKey 'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= me' | Should -BeTrue
    }
    It 'rejects garbage and injection attempts' {
        Test-QdSshKey '' | Should -BeFalse
        Test-QdSshKey 'hello world' | Should -BeFalse
        Test-QdSshKey 'ssh-ed25519 AAAA" ; rm -rf / ; "' | Should -BeFalse
        Test-QdSshKey 'ssh-ed25519 AAAA ${builtins.exec}' | Should -BeFalse
        Test-QdSshKey "ssh-ed25519 AAAA x`nruncmd: [reboot]" | Should -BeFalse
    }
    It 'refuses a private key file' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "qd-test-$([guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath $f -Value "-----BEGIN OPENSSH PRIVATE KEY-----`nabc`n-----END OPENSSH PRIVATE KEY-----"
        try { { Get-QdSshKeys -Path $f } | Should -Throw '*PRIVATE*' } finally { Remove-Item -LiteralPath $f }
    }
    It 'reads a .pub file, skipping comments' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "qd-test-$([guid]::NewGuid().ToString('N')).pub"
        Set-Content -LiteralPath $f -Value "# my key`n$($script:SampleKey)`n"
        try { @(Get-QdSshKeys -Path $f).Count | Should -Be 1 } finally { Remove-Item -LiteralPath $f }
    }
    It 'derives a valid hostname' {
        ConvertTo-QdHostname 'Web_Server-01' | Should -Be 'web-server-01'
        ConvertTo-QdHostname '---' | Should -Be 'linux'
        (ConvertTo-QdHostname ('a' * 80)).Length | Should -BeLessOrEqual 63
    }
    It 'quotes YAML strings safely' {
        ConvertTo-QdYamlString "it's: #x" | Should -BeExactly "'it''s: #x'"
    }
}

Describe 'Templates' {
    It 'pass the same check preflight runs' {
        $problems = Test-QdTemplates   # same call as Invoke-QdPreflight
        $problems.Count | Should -Be 0
    }
    It 'throw on unfilled placeholders' {
        { Expand-QdTemplate 'meta-data' @{ INSTANCE_ID = 'x' } } | Should -Throw '*HOSTNAME*'
    }
    It 'throw on a missing template' {
        { Expand-QdTemplate 'nope' @{} } | Should -Throw
    }
    Context 'cloud-init (<_>)' -ForEach @('ubuntu', 'fedora') {
        BeforeAll {
            $script:Ci = New-QdCloudInit -Family $_ -VmHostname 'vm1' -User 'admin' -Auth $script:Auth -InstanceId 'iid-1'
        }
        It 'renders LF-only, no placeholders' {
            $script:Ci['user-data'] | Should -Not -Match "`r"
            $script:Ci['user-data'] | Should -Not -Match '\{\{'
            $script:Ci['meta-data'] | Should -Match 'instance-id: iid-1'
        }
        It 'stores only the password hash' {
            $script:Ci['user-data'] | Should -Match ([regex]::Escape($script:Auth.Hash))
            $script:Ci['user-data'] | Should -Not -Match 'correct horse'
        }
        It 'keeps SSH password auth off when a key is given, root disabled' {
            $script:Ci['user-data'] | Should -Match 'ssh_pwauth: false'
            $script:Ci['user-data'] | Should -Match 'disable_root: true'
            $script:Ci['user-data'] | Should -Match 'ssh_authorized_keys:'
        }
        It 'installs the Hyper-V KVP daemon' {
            if ($_ -eq 'fedora') { $script:Ci['user-data'] | Should -Match 'hyperv-daemons' }
            else { $script:Ci['user-data'] | Should -Match 'linux-cloud-tools' }
        }
        It 'is valid YAML structure (top-level keys)' {
            foreach ($k in 'hostname:', 'users:', 'runcmd:', 'package_update:') { $script:Ci['user-data'] | Should -Match "(?m)^$k" }
        }
    }
    It 'NixOS config has the stateVersion marker, user, keys, hash' {
        $n = New-QdNixosConfig -VmHostname 'nix1' -User 'admin' -Auth $script:Auth
        $n['configuration.nix'] | Should -Match '@STATE_VERSION@'
        $n['configuration.nix'] | Should -Match 'virtualisation.hypervGuest.enable = true'
        $n['configuration.nix'] | Should -Match ([regex]::Escape($script:SampleKey))
        $n['configuration.nix'] | Should -Match ([regex]::Escape($script:Auth.Hash))
        $n['configuration.nix'] | Should -Match 'PermitRootLogin = "no"'
        $n['install.sh'] | Should -Match 'No empty disk found - refusing'
        $n['install.sh'] | Should -Not -Match "`r"
    }
    It 'sudo needs no password when there is only an SSH key' {
        $a = @{ Hash = $null; RootHash = $null; Keys = @($script:SampleKey); SshPwAuth = $false }
        (New-QdCloudInit -Family ubuntu -VmHostname 'v' -User 'u' -Auth $a -InstanceId 'i')['user-data'] | Should -Match 'NOPASSWD'
        (New-QdNixosConfig -VmHostname 'v' -User 'u' -Auth $a)['configuration.nix'] | Should -Match 'wheelNeedsPassword = false'
    }
}

Describe 'File helpers' {
    It 'writes LF-only UTF-8 without BOM' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "qd-test-$([guid]::NewGuid().ToString('N'))"
        try {
            Write-QdUnixFile $f "a`r`nb`r`n"
            $b = [IO.File]::ReadAllBytes($f)
            $b[0] | Should -Be ([byte][char]'a')
            @($b | Where-Object { $_ -eq 13 }).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
    It 'recognizes the VHDX signature' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "qd-test-$([guid]::NewGuid().ToString('N'))"
        try {
            [IO.File]::WriteAllText($f, 'vhdxfile' + ('x' * 100))
            Test-QdVhdxSignature $f | Should -BeTrue
            [IO.File]::WriteAllText($f, 'QFI' + ('x' * 100))
            Test-QdVhdxSignature $f | Should -BeFalse
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
    It 'reports a missing qemu-img as not OK (never assumes it works)' {
        (Test-QdQemuImg $null).Ok | Should -BeFalse
    }
    It 'rolls back registered undo actions in reverse order' {
        $script:Order = New-Object System.Collections.ArrayList
        Register-QdUndo -Description 'first' -Data @{ N = 1 } -Script { param($d) [void]$script:Order.Add($d.N) }
        Register-QdUndo -Description 'second' -Data @{ N = 2 } -Script { param($d) [void]$script:Order.Add($d.N) }
        Invoke-QdRollback 6>$null
        @($script:Order) | Should -Be @(2, 1)
        $script:QdUndo.Count | Should -Be 0
    }
}

Describe 'Live mirrors' -Tag 'Live' {
    It 'resolves <_>: reachable URL and a parsed checksum' -ForEach @('ubuntu-lts', 'ubuntu-latest', 'ubuntu-dev', 'fedora', 'nixos', 'nixos-stable') {
        Initialize-QdNetwork
        $img = Resolve-QdImage -Id $_
        $img.Url | Should -Match '^https://'
        $img.ExpectedHash | Should -Match '^([0-9a-f]{64}|[0-9a-f]{128})$'
        Test-QdUrl $img.Url | Should -BeTrue
    }
}

BeforeDiscovery {
    $script:OnWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

# Runs on Windows (e.g. the CI windows runner): really builds media, no Hyper-V needed.
Describe 'Windows seed media builders' -Tag 'Windows' -Skip:(-not $script:OnWindows) {
    It 'IMAPI2 builds a CIDATA ISO with Joliet that passes validation' {
        $dir = New-QdTempDir
        try {
            $src = Join-Path $dir 'src'
            $null = New-Item -ItemType Directory -Path $src
            $files = New-QdCloudInit -Family ubuntu -VmHostname 'ci' -User 'admin' -Auth $script:Auth -InstanceId 'ci'
            foreach ($k in $files.Keys) { Write-QdUnixFile (Join-Path $src $k) $files[$k] }
            $iso = Join-Path $dir 'seed.iso'
            New-QdIsoImapi $src $iso 'CIDATA'
            Test-QdIsoFile $iso 'CIDATA' | Should -BeTrue
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'Get-QdSeedMethod finds a working builder by building a test image' {
        $script:QdSeedMethod = $null
        $m = Get-QdSeedMethod
        $m.Method | Should -Not -BeNullOrEmpty -Because ($m.Tried -join '; ')
    }
}
