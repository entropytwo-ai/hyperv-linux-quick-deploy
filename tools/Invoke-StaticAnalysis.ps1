<#
.SYNOPSIS
    PSScriptAnalyzer (incl. PowerShell 5.1 syntax compatibility) + Pester.
.EXAMPLE
    ./tools/Invoke-StaticAnalysis.ps1            # analyzer + offline tests
    ./tools/Invoke-StaticAnalysis.ps1 -Live      # also resolve all images on the real mirrors
#>
[CmdletBinding()]
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($m in @(@{ Name = 'PSScriptAnalyzer'; Min = '1.21.0' }, @{ Name = 'Pester'; Min = '5.3.0' })) {
    if (-not (Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -ge [version]$m.Min })) {
        Write-Host "Installing $($m.Name) >= $($m.Min) (CurrentUser)..."
        Install-Module -Name $m.Name -MinimumVersion $m.Min -Scope CurrentUser -Force -SkipPublisherCheck
    }
}
Import-Module PSScriptAnalyzer
Import-Module Pester -MinimumVersion 5.3.0

$findings = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
$findings | Format-Table -AutoSize ScriptName, Line, Severity, RuleName, Message | Out-String -Width 200 | Write-Host
Write-Host "PSScriptAnalyzer findings: $($findings.Count)"

$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
if (-not $Live) { $cfg.Filter.ExcludeTag = 'Live' }
$result = Invoke-Pester -Configuration $cfg

if ($findings.Count -or $result.FailedCount) { Write-Host 'FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
