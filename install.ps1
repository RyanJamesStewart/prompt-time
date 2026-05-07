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
$PROMPTTIME_VERSION = '2.2.6'

# Pre-flight: ConstrainedLanguage mode silently kills [System.IO.File]::Replace
# and atomic JSON writes that this script depends on. Without this guard we
# would throw on line 250-ish of execution with a confusing error. Bail loudly
# and tell the user what's actually happening. Device Guard / WDAC user-mode
# enforcement triggers ConstrainedLanguage automatically, so this check covers
# both classes of org policy.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $mode = $ExecutionContext.SessionState.LanguageMode
    Write-Host ''
    Write-Host "  ERROR: PowerShell is running in $mode mode." -ForegroundColor Red
    Write-Host '  prompt-time install requires FullLanguage mode (atomic file writes + JSON parsing).' -ForegroundColor Red
    Write-Host ''
    Write-Host '  This is almost always Device Guard / WDAC user-mode enforcement, set by your' -ForegroundColor Yellow
    Write-Host '  organization. Independent confirmation:' -ForegroundColor Yellow
    Write-Host '    Get-CimInstance -ClassName Win32_DeviceGuard' -ForegroundColor DarkGray
    Write-Host '    [guid]::NewGuid()    # throws in ConstrainedLanguage' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Fix path: ask IT to allowlist this script, or run on an unmanaged machine.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
$ScriptDir   = $PSScriptRoot
# Source files (in the user's extracted-zip folder; disposable after install).
$McpSrc      = Join-Path $ScriptDir 'prompt_time.ps1'
$WatcherSrc  = Join-Path $ScriptDir 'prompt-time-watcher.ps1'
$WatcherTask = 'PROMPTTIME-Watcher'

# Resolve BOTH config paths Claude Desktop might be using:
#   Real:   %APPDATA%\Claude\claude_desktop_config.json   -- the "canonical" path
#   Shadow: %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude\claude_desktop_config.json
#           -- the per-package virtualized copy MSIX-packaged Claude Desktop
#           actually reads from once it has written to the file at least once.
# If we write only to Real and Claude has materialized the shadow, Claude never
# sees our entry. We must read shadow-first and write to both.
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
$ConfigPath  = $ConfigPaths.Real    # primary path; back-compat for legacy refs

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
# Canonical install destinations inside the data dir. Both watcher AND MCP
# server are copied here so the user can delete the extracted-zip folder
# after install. The Claude Desktop config + the Task Scheduler action both
# reference these data-dir copies, never the original $ScriptDir.
$WatcherDest = Join-Path $DataDir 'prompt-time-watcher.ps1'
$McpDest     = Join-Path $DataDir 'prompt_time.ps1'

function Write-Banner {
    if ($Silent) { return }
    Write-Host ''
    Write-Host '  prompt-time -- Claude Desktop reminder installer (v2)'
    Write-Host '  -------------------------------------------------------'
    Write-Host ''
}

# Spawn prompt_time.ps1 the way Claude Desktop will and probe with a JSON-RPC
# initialize. Catches AppLocker / WDAC / signature-required policies at install
# time so the user knows BEFORE restarting Claude Desktop. Returns @{ ok; reason; stderr }.
function Test-McpServerSpawnable {
    [CmdletBinding()]
    param([string]$ScriptPath, [int]$TimeoutMs = 6000)

    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps))         { return @{ ok=$false; reason="powershell.exe not found at $ps" } }
    if (-not (Test-Path $ScriptPath)) { return @{ ok=$false; reason="prompt_time.ps1 not found at $ScriptPath" } }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ps
    $psi.Arguments              = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ ok=$false; reason="powershell spawn failed: $($_.Exception.Message)";
                  hint='AppLocker, WDAC, or Group Policy may block powershell.exe from launching scripts in this directory.' }
    }
    try {
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"prompt-time-installer","version":"verify"}}}')
        $proc.StandardInput.Flush()
    } catch {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { Write-Verbose "Kill: $_" } }
        return @{ ok=$false; reason="stdin write failed: $($_.Exception.Message)" }
    }

    $readTask  = $proc.StandardOutput.ReadLineAsync()
    $completed = $readTask.Wait($TimeoutMs)
    $stderr = ''
    try { if ($proc.HasExited) { $stderr = $proc.StandardError.ReadToEnd() } } catch { Write-Verbose "stderr read: $_" }
    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch { Write-Verbose "Kill: $_" }
        $proc.WaitForExit(2000) | Out-Null
        if (-not $stderr) { try { $stderr = $proc.StandardError.ReadToEnd() } catch { Write-Verbose "stderr read post-kill: $_" } }
    }

    if (-not $completed) { return @{ ok=$false; reason="no JSON-RPC response within ${TimeoutMs}ms"; stderr=$stderr } }
    $line = $readTask.Result
    if ($line -and $line -match '"jsonrpc"\s*:\s*"2\.0"' -and $line -match '"id"\s*:\s*1') {
        return @{ ok=$true; reason='MCP server responded to initialize' }
    }
    return @{ ok=$false; reason="unexpected first-line output: $line"; stderr=$stderr }
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
foreach ($p in @($McpSrc, $WatcherSrc)) {
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

# 3. Copy both the watcher and the MCP server scripts into the data dir so
#    they survive after the user deletes the extracted-zip folder. Claude
#    Desktop's config + the scheduled task action will reference these copies,
#    never the original $ScriptDir.
Copy-Item -Path $WatcherSrc -Destination $WatcherDest -Force
Copy-Item -Path $McpSrc     -Destination $McpDest     -Force

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
    # Wait briefly for Task Scheduler to materialize state, then show what it
    # actually says about the running watcher. "is running (267009)" beats raw
    # 267009 if anyone reads this banner during a support call.
    Start-Sleep -Milliseconds 500
    $statusText = ''
    try {
        $info = Get-ScheduledTask -TaskName $WatcherTask -ErrorAction Stop | Get-ScheduledTaskInfo -ErrorAction Stop
        $code = [uint32]$info.LastTaskResult
        $statusText = switch ($code) {
            0          { 'success' }
            267009     { 'is running' }
            267011     { 'has not run yet' }
            267010     { 'is queued' }
            2147750687 { 'disabled' }
            2147942405 { 'access denied (0x80070005)' }
            default    {
                # 0xC0000005 etc. -- show hex when it isn't a known friendly code.
                ('exit 0x{0:X8}' -f $code)
            }
        }
    } catch {
        Write-Verbose "Watcher status read failed: $_"
    }
    if ($statusText) {
        Write-Host "  OK  watcher task registered: $WatcherTask ($statusText)" -ForegroundColor Green
    } else {
        Write-Host "  OK  watcher task registered: $WatcherTask" -ForegroundColor Green
    }
    Write-Host '      runs at logon, restart-on-failure' -ForegroundColor DarkGray
    Write-Host ''
}

# 8. Read claude_desktop_config.json from BOTH paths (when they exist) and merge.
#    The MSIX shadow trap creates a divergence: a user can have MCP servers in
#    %APPDATA% that Claude no longer sees (because the shadow was created later
#    by a Claude UI write that didn't include them). If we just pick one file
#    as source of truth, we silently delete the user's other MCP servers when
#    we write the result back. Instead: union mcpServers from both files. Shadow
#    wins on key conflict, since shadow is the file Claude has been reading and
#    therefore matches the user's recent expectation of "what's installed."
function Read-ClaudeConfigFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return [PSCustomObject]@{} }
        return $raw | ConvertFrom-Json
    } catch {
        throw "Could not parse $Path : $($_.Exception.Message)"
    }
}

try {
    $shadowCfg = Read-ClaudeConfigFile $ConfigPaths.Shadow
    $realCfg   = Read-ClaudeConfigFile $ConfigPaths.Real
} catch {
    if (-not $Silent) {
        Write-Host '  ERROR: Could not parse Claude Desktop config.' -ForegroundColor Red
        Write-Host "  $_"
    }
    exit 1
}

# Pick the base object for top-level keys (preferences etc.). Shadow first
# because that's what Claude reads; fall back to real, then to an empty object.
$config = if ($shadowCfg) { $shadowCfg } elseif ($realCfg) { $realCfg } else { [PSCustomObject]@{} }
if (-not ($config | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
    $config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
}

# Union mcpServers across both files. Loop order: real first, shadow second --
# Add-Member -Force overwrites, so shadow's value wins on conflicts.
$merged = [PSCustomObject]@{}
$realKeys   = @()
$shadowKeys = @()
if ($realCfg -and ($realCfg | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
    foreach ($prop in $realCfg.mcpServers.PSObject.Properties) {
        $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        $realKeys += $prop.Name
    }
}
if ($shadowCfg -and ($shadowCfg | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
    foreach ($prop in $shadowCfg.mcpServers.PSObject.Properties) {
        $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        $shadowKeys += $prop.Name
    }
}
$config.mcpServers = $merged

# If we recovered any %APPDATA%-only servers (which Claude was no longer seeing
# because the shadow trap had hidden them), surface that. It's a positive side
# effect of the install and explains "why did my other servers reappear?"
$rescued = @($realKeys | Where-Object { $shadowKeys -notcontains $_ -and $_ -ne 'prompt-time' })
if (-not $Silent -and $shadowCfg -and $realCfg -and $rescued.Count -gt 0) {
    Write-Host "  Merged $($rescued.Count) MCP server(s) from %APPDATA% that the MSIX shadow had hidden:" -ForegroundColor Cyan
    foreach ($k in $rescued) { Write-Host "    - $k" -ForegroundColor DarkGray }
}

$realDir = Split-Path $ConfigPaths.Real
if (-not (Test-Path $realDir)) { New-Item -ItemType Directory -Path $realDir -Force | Out-Null }

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
        '-File', $McpDest
    )
}
$config.mcpServers | Add-Member -NotePropertyName 'prompt-time' -NotePropertyValue $entry -Force

# Atomic config write. Each target file is staged via .prompt-time.tmp and
# atomically swapped with File.Replace, which preserves the previous bytes as
# .prompt-time.bak (free undo). Other MCP entries are preserved.
#
# We write to BOTH paths whenever the shadow exists: shadow is what Claude
# actually reads, Real is what diagnostics + uninstall + manual inspection
# expect. If shadow does not exist on this machine, MSIX read-through still
# resolves Real, so writing only Real is correct.
$json      = $config | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$writeTargets = @($ConfigPaths.Real)
if ($ConfigPaths.Shadow -and (Test-Path $ConfigPaths.Shadow)) { $writeTargets += $ConfigPaths.Shadow }

foreach ($target in $writeTargets) {
    $targetDir = Split-Path $target
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    $tmpPath = "$target.prompt-time.tmp"
    $bakPath = "$target.prompt-time.bak"
    [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
    if (Test-Path $target) {
        [System.IO.File]::Replace($tmpPath, $target, $bakPath)
    } else {
        [System.IO.File]::Move($tmpPath, $target)
    }
}

# Post-write self-verify. Re-read each target, parse, confirm prompt-time
# survived. Catches: AV/EDR rolling back our write, managed-config policy
# stripping it, MSIX virtualization redirecting to a different shadow than
# we computed, file-handle locks leaving an empty file. Without this check,
# install reports OK on machines where the entry never landed, and the user
# discovers the failure after restarting Claude Desktop.
$verifyFailures = @()
foreach ($target in $writeTargets) {
    try {
        $raw  = Get-Content $target -Raw -Encoding UTF8
        $obj  = $raw | ConvertFrom-Json
        $ok   = $obj.mcpServers -and ($obj.mcpServers | Get-Member -Name 'prompt-time' -ErrorAction SilentlyContinue)
        if (-not $ok) { $verifyFailures += "$target -- prompt-time entry missing after write" }
    } catch {
        $verifyFailures += "$target -- $($_.Exception.Message)"
    }
}
if ($verifyFailures.Count -gt 0) {
    if (-not $Silent) {
        Write-Host '  ERROR: post-write self-verify FAILED.' -ForegroundColor Red
        foreach ($f in $verifyFailures) { Write-Host "         $f" -ForegroundColor Red }
        Write-Host '         The install path WROTE the entry but a re-read does not see it.' -ForegroundColor Yellow
        Write-Host '         Most likely causes:' -ForegroundColor Yellow
        Write-Host '           - AV/EDR (CrowdStrike, Defender, etc.) rolled the write back' -ForegroundColor Yellow
        Write-Host '           - Managed Claude Desktop policy is overwriting the config' -ForegroundColor Yellow
        Write-Host '           - File system redirected our write to a different path than expected' -ForegroundColor Yellow
        Write-Host '         Run diagnose.bat for a full breakdown.' -ForegroundColor Yellow
    }
    exit 1
}

if (-not $Silent) {
    Write-Host '  OK  prompt-time added to Claude Desktop config (verified)' -ForegroundColor Green
    foreach ($p in $writeTargets) { Write-Host "      $p" -ForegroundColor DarkGray }
    if ($ConfigPaths.Shadow -and -not (Test-Path $ConfigPaths.Shadow)) {
        Write-Host '      (MSIX shadow not present yet -- Claude reads from %APPDATA%; single-write is correct)' -ForegroundColor DarkGray
    } elseif ($ConfigPaths.Shadow) {
        Write-Host '      (MSIX shadow detected -- wrote to both paths to defeat file virtualization)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# 10b. Verify prompt_time.ps1 will actually launch when Claude Desktop spawns it.
#      Detects AppLocker / WDAC / signature-required policies that block powershell.exe
#      from running scripts in this folder. Without this check, install reports OK,
#      Claude Desktop restarts, and the tools silently never appear.
if (-not $Silent) {
    $spawn = Test-McpServerSpawnable -ScriptPath $McpDest
    if ($spawn.ok) {
        Write-Host '  OK  MCP server responded to test initialize' -ForegroundColor Green
        Write-Host ''
    } else {
        Write-Host '  WARN MCP server did not respond to test initialize.' -ForegroundColor Yellow
        Write-Host "       reason: $($spawn.reason)" -ForegroundColor Yellow
        if ($spawn.stderr) {
            $stderrTrim = $spawn.stderr.Trim()
            if ($stderrTrim) {
                Write-Host '       stderr:' -ForegroundColor Yellow
                foreach ($line in $stderrTrim -split "`r?`n") { Write-Host "         $line" -ForegroundColor DarkGray }
            }
        }
        if ($spawn.hint) { Write-Host "       hint: $($spawn.hint)" -ForegroundColor Yellow }
        Write-Host '       The Claude Desktop restart will likely not surface the tools either.' -ForegroundColor Yellow
        Write-Host '       Run diagnose.bat after the restart for a deeper check.' -ForegroundColor Yellow
        Write-Host ''
    }
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
