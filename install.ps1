# prompt-time installer
# Sets up:
#   1. The data directory at the canonical path that Claude Desktop's MSIX
#      package (or a legacy non-MSIX install) will read and write through.
#   2. A single watcher Task Scheduler task (PROMPTTIME-Watcher) that runs at
#      logon and polls the queue file.
#   3. The MCP server entry in claude_desktop_config.json.
#
# Flags:
#   -Silent     run fully unattended; no prompts, no countdown
#   -NoRestart  do not restart Claude Desktop or start the watcher
#   -SelfTest   after install, schedule a fire-immediately reminder and verify
#               the watcher actually rendered it. Exits 0 on success, 1 on
#               failure with a clear reason.
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$NoRestart,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$PROMPTTIME_VERSION = '2.2.2'
$ScriptDir   = $PSScriptRoot
$McpScript   = Join-Path $ScriptDir 'prompt_time.ps1'
$WatcherSrc  = Join-Path $ScriptDir 'prompt-time-watcher.ps1'
$ConfigPath  = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
$WatcherTask = 'PROMPTTIME-Watcher'

# Resolve the data dir the SAME way prompt_time.ps1 and prompt-time-watcher.ps1 do:
# discover Claude Desktop's MSIX package and use its LocalCache writable storage
# (so the MSIX-packaged MCP server's writes and the watcher's reads land at the
# same physical file). Fall back to %APPDATA% for legacy non-MSIX Claude Desktop.
function Get-PromptTimeDataDir {
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            return @{ Path = (Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\prompt-time" -f $pkg.PackageFamilyName)); IsMsix = $true }
        }
    } catch {
        Write-Verbose "AppX lookup failed: $_"
    }
    return @{ Path = (Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'); IsMsix = $false }
}
$dataInfo    = Get-PromptTimeDataDir
$DataDir     = $dataInfo.Path
$IsMsix      = $dataInfo.IsMsix
$WatcherDest = Join-Path $DataDir 'prompt-time-watcher.ps1'

function Write-Banner {
    if ($Silent) { return }
    Write-Host ''
    Write-Host '  prompt-time -- Claude Desktop reminder installer (v2)'
    Write-Host '  -------------------------------------------------------'
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

# 1. Verify required script files exist alongside this installer
foreach ($p in @($McpScript, $WatcherSrc)) {
    if (-not (Test-Path $p)) {
        if (-not $Silent) {
            Write-Host "  ERROR: $(Split-Path $p -Leaf) not found at $p" -ForegroundColor Red
        }
        exit 1
    }
}

# 1b. Warn if Claude Desktop is not installed.
#     A Claude install AFTER this point may show up as MSIX, in which case the
#     data dir we picked here (the legacy %APPDATA% path) won't be the one the
#     MCP server inside Claude actually reads from. The user would have to
#     re-run install.bat after Claude shows up.
if (-not $IsMsix -and -not $Silent) {
    $hasClaude = (Test-Path "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe") -or
                 (Test-Path "$env:LOCALAPPDATA\Programs\claude-desktop\Claude.exe") -or
                 (Test-Path "$env:LOCALAPPDATA\Programs\Claude\Claude.exe")
    if (-not $hasClaude) {
        Write-Host '  NOTE: Claude Desktop does not appear to be installed.' -ForegroundColor Yellow
        Write-Host '  The watcher will run, but reminders will only fire after you install Claude' -ForegroundColor Yellow
        Write-Host "  Desktop AND re-run install.bat (so the data dir is rebound to Claude's path)." -ForegroundColor Yellow
        Write-Host ''
    }
}

# 2. Pre-create the data directory AND its files at the canonical path.
#    MSIX package isolation: the MCP server runs inside Claude Desktop's package
#    container; its writes get redirected to a package-local shadow tree UNLESS
#    the destination file ALREADY EXISTS at the canonical path. Pre-creating
#    the directory only is not sufficient -- we must pre-create empty placeholder
#    files so subsequent appends modify the real file in place.
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    if (-not $Silent) { Write-Host "  Created $DataDir" -ForegroundColor DarkGray }
}
foreach ($f in @('queue.jsonl', 'prompt-time.debug.log')) {
    $path = Join-Path $DataDir $f
    if (-not (Test-Path $path)) {
        # Write a single newline so the file is non-zero-bytes -- belt-and-
        # suspenders against MSIX file virtualization quirks where some hosts
        # treat zero-byte placeholders as not-actually-present and shadow the
        # first append into the package's LocalCache.
        Set-Content -Path $path -Value '' -Encoding UTF8
        if (-not $Silent) { Write-Host "  Pre-created $f" -ForegroundColor DarkGray }
    }
}

# Write VERSION file -- source of truth for "what version is installed here?"
# included in bug reports and read by the watcher on startup.
$VersionPath = Join-Path $DataDir 'VERSION'
Set-Content -Path $VersionPath -Value $PROMPTTIME_VERSION -Encoding UTF8

# 3. Copy the watcher script into the data dir so it survives even if the
#    install dir is later moved/removed.
Copy-Item -Path $WatcherSrc -Destination $WatcherDest -Force

# 4. Stop and remove any existing PROMPTTIME-Watcher task (idempotent re-install).
try {
    $existing = Get-ScheduledTask -TaskName $WatcherTask -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-ScheduledTask -TaskName $WatcherTask -ErrorAction SilentlyContinue } catch {
            Write-Verbose "Stop-ScheduledTask $WatcherTask failed: $_"
        }
        try { Unregister-ScheduledTask -TaskName $WatcherTask -Confirm:$false -ErrorAction Stop } catch {
            if (-not $Silent) { Write-Host "  WARN: could not remove existing $WatcherTask : $_" -ForegroundColor Yellow }
        }
    }
} catch {
    if (-not $Silent) { Write-Host "  WARN: could not query existing $WatcherTask : $_" -ForegroundColor Yellow }
}

# 5. Migrate-away from any prior prompt-time or cron-mcp tasks. We identify them
#    by action path (the script that runs) rather than by name prefix, so we
#    never delete an unrelated task that happens to start with PROMPTTIME- or CRONMCP-.
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.TaskName -eq $WatcherTask) { return }
        $isOurs = $false
        foreach ($action in @($_.Actions)) {
            $argText = if ($action.PSObject.Properties.Match('Arguments').Count) { [string]$action.Arguments } else { '' }
            $exeText = if ($action.PSObject.Properties.Match('Execute').Count)   { [string]$action.Execute   } else { '' }
            if ($argText -match '(cron[-_]mcp|prompt[-_]time)(-watcher)?\.ps1' -or $exeText -match '(cron[-_]mcp|prompt[-_]time)(-watcher)?\.ps1') {
                $isOurs = $true; break
            }
        }
        if ($isOurs) {
            try {
                Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop
                if (-not $Silent) { Write-Host "  Removed legacy task: $($_.TaskName)" -ForegroundColor DarkGray }
            } catch {
                if (-not $Silent) { Write-Host "  WARN: could not remove legacy $($_.TaskName): $_" -ForegroundColor Yellow }
            }
        }
    }
} catch {
    if (-not $Silent) { Write-Host "  WARN: could not enumerate scheduled tasks: $_" -ForegroundColor Yellow }
}

# 6. Register the watcher task: at-logon trigger, restart-on-failure.
#    -STA: required for WinForms.
$action = New-ScheduledTaskAction `
    -Execute (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherDest`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $WatcherTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# 7. Start the watcher right now (so the user doesn't have to log out/in).
if (-not $NoRestart) {
    try { Start-ScheduledTask -TaskName $WatcherTask -ErrorAction Stop } catch {
        if (-not $Silent) { Write-Host "  WARN: could not start $WatcherTask : $_" -ForegroundColor Yellow }
    }
}

if (-not $Silent) {
    Write-Host "  OK  watcher task registered: $WatcherTask" -ForegroundColor Green
    Write-Host '      runs at logon, restart-on-failure' -ForegroundColor DarkGray
    Write-Host ''
}

# 8. Read or create claude_desktop_config.json.
$config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
if (Test-Path $ConfigPath) {
    try {
        $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json }
        if (-not ($config | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
            $config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
        }
    } catch {
        if (-not $Silent) {
            Write-Host '  ERROR: Could not parse Claude Desktop config.' -ForegroundColor Red
            Write-Host "  File: $ConfigPath"
            Write-Host "  $_"
        }
        exit 1
    }
} else {
    $configDir = Split-Path $ConfigPath
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
}

# 9. Drop legacy 'remind-me' and 'cron-mcp' entries if present.
foreach ($legacyKey in @('remind-me', 'cron-mcp')) {
    if ($config.mcpServers | Get-Member -Name $legacyKey -ErrorAction SilentlyContinue) {
        $config.mcpServers.PSObject.Properties.Remove($legacyKey)
    }
}

# 10. Inject/refresh the prompt-time entry.
$entry = [PSCustomObject]@{
    command = 'powershell.exe'
    args    = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $McpScript
    )
}
$config.mcpServers | Add-Member -NotePropertyName 'prompt-time' -NotePropertyValue $entry -Force

# Atomic config write. The README promises "other MCP servers untouched" --
# that promise is only safe if a power loss between truncate and write can't
# happen. Stage the new content to .tmp, then File.Replace which atomically
# swaps the file AND keeps the previous bytes as $ConfigPath.prompt-time.bak --
# free undo for any user who reports "install ate my Claude config."
$json      = $config | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$tmpPath   = "$ConfigPath.prompt-time.tmp"
$bakPath   = "$ConfigPath.prompt-time.bak"
[System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
if (Test-Path $ConfigPath) {
    [System.IO.File]::Replace($tmpPath, $ConfigPath, $bakPath)
} else {
    [System.IO.File]::Move($tmpPath, $ConfigPath)
}

if (-not $Silent) {
    Write-Host '  OK  prompt-time added to Claude Desktop config' -ForegroundColor Green
    Write-Host "      $ConfigPath" -ForegroundColor DarkGray
    Write-Host ''
}

# 11. Restart Claude Desktop if running.
#     Interactive: confirm before terminating (open conversations would be lost).
#     -Silent:     no prompt, restart immediately.
#     -NoRestart:  skip entirely.
if (-not $NoRestart) {
    $claude = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
    if ($claude) {
        $proceed = $true
        if (-not $Silent) {
            Write-Host '  Claude Desktop is running. To activate prompt-time it must be restarted.' -ForegroundColor Yellow
            Write-Host '  Any open conversation will be ended.' -ForegroundColor Yellow
            $resp = Read-Host '  Restart Claude Desktop now? [Y/n]'
            if ($resp -and $resp.Trim().ToLower() -notin @('', 'y', 'yes')) {
                $proceed = $false
                Write-Host '  Skipped. Restart Claude Desktop yourself when ready -- the tools will appear after.' -ForegroundColor Yellow
            }
        }
        if ($proceed) {
            try {
                $claude | Stop-Process -Force
                Start-Sleep -Seconds 2

                # Try MSIX-packaged launch first (current Claude Desktop ships as MSIX).
                # Fallback to legacy Squirrel exe paths for older installs.
                $launched = $false
                try {
                    $msix = Get-StartApps | Where-Object { $_.Name -eq 'Claude' } | Select-Object -First 1
                    if ($msix -and $msix.AppID) {
                        Start-Process "shell:AppsFolder\$($msix.AppID)"
                        $launched = $true
                    }
                } catch {
                    Write-Verbose "MSIX launch failed: $_"
                }
                if (-not $launched) {
                    $exePaths = @(
                        "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
                        "$env:LOCALAPPDATA\Programs\claude-desktop\Claude.exe",
                        "$env:LOCALAPPDATA\Programs\Claude\Claude.exe"
                    )
                    $exe = $exePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if ($exe) { Start-Process $exe; $launched = $true }
                }
                if ($launched -and -not $Silent) {
                    Write-Host '  OK  Claude Desktop restarted' -ForegroundColor Green
                } elseif (-not $Silent) {
                    Write-Host "  Please open Claude Desktop manually (Start menu -> type 'Claude')." -ForegroundColor Yellow
                }
            } catch {
                if (-not $Silent) {
                    Write-Host "  Could not restart Claude Desktop automatically: $_" -ForegroundColor Yellow
                }
            }
        }
    } elseif (-not $Silent) {
        Write-Host '  Open Claude Desktop to activate prompt-time.' -ForegroundColor Yellow
    }
}

if (-not $Silent) {
    Write-Host ''
    Write-Host '  All done! Try asking Claude:' -ForegroundColor Cyan
    Write-Host '  Remind me to check email in 10 minutes' -ForegroundColor White
}

# -SelfTest: enqueue a reminder for ~3 seconds from now and verify the
# watcher renders it within 25 seconds. Useful for unattended verification
# (CI / fresh-machine smoke). Exits non-zero on failure with a specific reason.
if ($SelfTest) {
    if (-not $Silent) { Write-Host ''; Write-Host '  Self-test: scheduling a fire-immediately reminder...' -ForegroundColor Cyan }
    $QueueFile = Join-Path $DataDir 'queue.jsonl'
    $DebugLog  = Join-Path $DataDir 'prompt-time.debug.log'
    $TestId    = "PROMPTTIME-$([guid]::NewGuid().ToString('N').Substring(0,8).ToUpper())"
    $fireAt    = (Get-Date).AddSeconds(3).ToString('o')
    $createdAt = (Get-Date).ToString('o')
    $entry = [ordered]@{
        v          = 1
        id         = $TestId
        fireAt     = $fireAt
        title      = 'prompt-time self-test'
        message    = 'If you can read this popup, install verified.'
        recurrence = 'once'
        createdAt  = $createdAt
    }
    Add-Content -LiteralPath $QueueFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8

    $deadline = (Get-Date).AddSeconds(25)
    $rendered = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $DebugLog) {
            $hit = Select-String -Path $DebugLog -Pattern "fire: id=$TestId" -SimpleMatch -ErrorAction SilentlyContinue
            if ($hit) { $rendered = $true; break }
        }
    }

    if ($rendered) {
        if (-not $Silent) { Write-Host '  PASS  watcher rendered the test reminder' -ForegroundColor Green }
        exit 0
    } else {
        if (-not $Silent) {
            Write-Host '  FAIL  test reminder did not fire within 25s' -ForegroundColor Red
            Write-Host "        debug log: $DebugLog" -ForegroundColor DarkGray
            Write-Host "        check: Get-ScheduledTask -TaskName $WatcherTask | Get-ScheduledTaskInfo" -ForegroundColor DarkGray
        }
        exit 1
    }
}

Exit-WithCountdown 0
