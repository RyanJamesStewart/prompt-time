# prompt-time uninstaller.
# Removes the prompt-time entry from Claude Desktop config (preserves other MCP
# servers), unregisters prompt-time scheduled tasks (matched by action path,
# not by name prefix, so unrelated tasks are never touched), kills any live
# watcher process, and removes the data directory.
#
# Flags:
#   -Silent          run unattended; no prompts, no countdown
#   -KeepData        keep the data dir (otherwise removed)
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'

# Match install.ps1's dual-path resolution. Claude Desktop's MSIX file
# virtualization makes the shadow path the file actually read -- we must
# remove our entry from BOTH paths or a stray copy will resurrect it.
function Get-ClaudeConfigPath {
    $real = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    $shadow = $null
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            $shadow = Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\Claude\claude_desktop_config.json" -f $pkg.PackageFamilyName)
        }
    } catch { Write-Verbose "AppX lookup failed: $_" }
    return @{ Real = $real; Shadow = $shadow }
}
$ConfigPaths = Get-ClaudeConfigPath
# Match the canonical-data-dir discovery used by prompt_time.ps1 / watcher / install.
function Get-PromptTimeDataDir {
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            return Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\prompt-time" -f $pkg.PackageFamilyName)
        }
    } catch {
        if (-not $Silent) { Write-Verbose "AppX lookup failed: $_" }
    }
    return Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'
}
$DataDir     = Get-PromptTimeDataDir
$RealDataDir = Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'
$LegacyDir   = Join-Path $env:USERPROFILE 'AppData\Roaming\cron-mcp'
$LegacyDir2  = Join-Path $env:USERPROFILE 'AppData\Roaming\remind-me'
$WatcherTask = 'PROMPTTIME-Watcher'

function Write-Banner {
    if ($Silent) { return }
    Write-Host ''
    Write-Host '  prompt-time -- uninstaller'
    Write-Host '  --------------------------'
    Write-Host ''
}

function Exit-WithCountdown([int]$code) {
    if ($Silent) { exit $code }
    Write-Host ''
    for ($i = 5; $i -ge 1; $i--) {
        Write-Host -NoNewline "`r  Closing in $i... "
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    exit $code
}

Write-Banner

# 1. Remove prompt-time (and any legacy cron-mcp / remind-me) entry from Claude
#    Desktop config -- BOTH the canonical %APPDATA% path AND the MSIX shadow,
#    if either exists. install.ps1 may have written to both; uninstall must
#    remove from both or a stale copy in the shadow will resurrect the entry
#    the next time Claude Desktop boots.
$configChanged = $false
$configTargets = @($ConfigPaths.Real, $ConfigPaths.Shadow) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

foreach ($target in $configTargets) {
    try {
        $raw    = Get-Content $target -Raw -Encoding UTF8
        $config = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { $null }
        if ($config -and ($config | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
            $localChanged = $false
            foreach ($key in @('prompt-time', 'cron-mcp', 'remind-me')) {
                if ($config.mcpServers | Get-Member -Name $key -ErrorAction SilentlyContinue) {
                    $config.mcpServers.PSObject.Properties.Remove($key)
                    $localChanged = $true
                    if (-not $Silent) { Write-Host "  Removed '$key' from $target" -ForegroundColor Green }
                }
            }
            if ($localChanged) {
                $configChanged = $true
                $json      = $config | ConvertTo-Json -Depth 10
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                $tmpPath   = "$target.prompt-time.tmp"
                $bakPath   = "$target.prompt-time.bak"
                [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
                [System.IO.File]::Replace($tmpPath, $target, $bakPath)
            }
        }
    } catch {
        if (-not $Silent) {
            Write-Host "  WARN: could not edit $target : $_" -ForegroundColor Yellow
        }
    }
}
if (-not $configChanged -and -not $Silent) {
    Write-Host '  No prompt-time entry found in Claude Desktop config.' -ForegroundColor DarkGray
}

# 2. Unregister prompt-time scheduled tasks. We identify tasks two ways:
#    (a) the canonical name "PROMPTTIME-Watcher" (current install vintage), and
#    (b) any task whose action invokes a watcher script by name (catches earlier
#        vintages and dev installs without nuking unrelated tasks).
function Test-PromptTimeTask($task) {
    if ($task.TaskName -eq $WatcherTask) { return $true }
    foreach ($action in @($task.Actions)) {
        # Avoid shadowing the automatic $args variable which PSScriptAnalyzer flags.
        $argText = if ($action.PSObject.Properties.Match('Arguments').Count) { [string]$action.Arguments } else { '' }
        $exeText = if ($action.PSObject.Properties.Match('Execute').Count)   { [string]$action.Execute   } else { '' }
        if ($argText -match '(cron[-_]mcp|prompt[-_]time)(-watcher)?\.ps1') { return $true }
        if ($exeText -match '(cron[-_]mcp|prompt[-_]time)(-watcher)?\.ps1') { return $true }
    }
    return $false
}

try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { Test-PromptTimeTask $_ } | ForEach-Object {
        $name = $_.TaskName
        try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } catch {
            if (-not $Silent) { Write-Host "  WARN: could not stop $name : $_" -ForegroundColor Yellow }
        }
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            if (-not $Silent) { Write-Host "  Removed task: $name" -ForegroundColor Green }
        } catch {
            if (-not $Silent) { Write-Host "  WARN: could not remove $name : $_" -ForegroundColor Yellow }
        }
    }
} catch {
    if (-not $Silent) { Write-Host "  WARN: could not enumerate scheduled tasks: $_" -ForegroundColor Yellow }
}

# 3. Kill any live watcher process. Get-Process does not expose CommandLine on
#    the .NET Process object, so we go through CIM/WMI.
try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match '(cron-mcp-watcher|prompt-time-watcher)\.ps1' } |
        ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                if (-not $Silent) { Write-Host "  Stopped watcher process PID $($_.ProcessId)" -ForegroundColor Green }
            } catch {
                if (-not $Silent) { Write-Host "  WARN: could not stop watcher PID $($_.ProcessId): $_" -ForegroundColor Yellow }
            }
        }
} catch {
    if (-not $Silent) { Write-Host "  WARN: could not enumerate watcher processes: $_" -ForegroundColor Yellow }
}

# 4. Remove data directories unless -KeepData. Clean up the canonical location,
#    the legacy non-MSIX real-path dir, the old cron-mcp dir, and the remind-me dir.
if (-not $KeepData) {
    foreach ($dir in @($DataDir, $RealDataDir, $LegacyDir, $LegacyDir2) | Select-Object -Unique) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
                if (-not $Silent) { Write-Host "  Removed data dir: $dir" -ForegroundColor Green }
            } catch {
                if (-not $Silent) { Write-Host "  WARN: could not remove $dir : $_" -ForegroundColor Yellow }
            }
        }
    }
}

if (-not $Silent) {
    Write-Host ''
    Write-Host '  prompt-time uninstalled. Restart Claude Desktop to drop the tools.' -ForegroundColor Cyan
}

Exit-WithCountdown 0
