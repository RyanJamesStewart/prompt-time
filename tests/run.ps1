# Test runner for prompt-time.
#
# Installs Pester 5.x to the current user scope if not present, then runs the
# Pester suite under tests/. Exits non-zero on any failure (suitable for CI).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1

[CmdletBinding()]
param(
    [string]$TestPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $TestPath) {
    # $PSScriptRoot can be empty when this script is invoked via certain shells;
    # fall back to the script's actual file location.
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $TestPath = Join-Path $here 'prompt_time.Tests.ps1'
}

# Ensure Pester 5+ is available. Skip the install if anything 5.x or newer is present.
$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Installing Pester 5.x to CurrentUser scope...' -ForegroundColor Cyan
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = (Join-Path $PSScriptRoot 'pester-results.xml')
$config.TestResult.OutputFormat = 'NUnitXml'

Invoke-Pester -Configuration $config
