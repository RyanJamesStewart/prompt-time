# prompt-time diagnostic
# Run AFTER restarting Claude Desktop if prompt-time tools don't appear.
# Prints a checklist of the things that commonly silently break and an
# actionable hint for each failure.
#
# Usage:
#   diagnose.bat                # human-readable
#   diagnose.bat -Json          # machine-readable for bug reports
#
# Exits 0 if everything looks healthy, 1 if any fixable check fails.
[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$ScriptDir   = $PSScriptRoot
$McpScript   = Join-Path $ScriptDir 'prompt_time.ps1'
$ConfigPath  = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
$WatcherTask = 'PROMPTTIME-Watcher'
$ClaudeLogs  = Join-Path $env:APPDATA 'Claude\logs'

# Resolve MSIX shadow config path -- the file Claude actually reads from once
# Claude Desktop has written to its own config at least once. If our entry is
# in $ConfigPath but missing from the shadow, Claude can't see it.
$ShadowConfigPath = $null
try {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $ShadowConfigPath = Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\Claude\claude_desktop_config.json" -f $pkg.PackageFamilyName)
    }
} catch { Write-Verbose "AppX lookup failed: $_" }

# Resolve data dir the same way prompt_time.ps1 does so we can find VERSION
# and the watcher debug log (MSIX-aware).
function Get-PromptTimeDataDir {
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            return Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\prompt-time" -f $pkg.PackageFamilyName)
        }
    } catch { Write-Verbose "AppX lookup failed: $_" }
    return Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'
}
$DataDir = Get-PromptTimeDataDir

$installedVersion = 'unknown'
$verPath = Join-Path $DataDir 'VERSION'
if (Test-Path $verPath) { $installedVersion = (Get-Content $verPath -Raw).Trim() }

$report = [ordered]@{
    timestamp        = (Get-Date).ToString('o')
    installedVersion = $installedVersion
    scriptDir        = $ScriptDir
    dataDir          = $DataDir
    checks           = [ordered]@{}
}

function Add-Check([string]$Name, [string]$Status, [string]$Detail = '', [string]$Hint = '') {
    # Status: PASS | FAIL | WARN | INFO
    $report.checks[$Name] = [ordered]@{
        status = $Status
        detail = $Detail
        hint   = $Hint
    }
}

# ---------------------------------------------------------------
# 1. claude_desktop_config.json present + parseable + has prompt-time
# ---------------------------------------------------------------
$config = $null
if (-not (Test-Path $ConfigPath)) {
    Add-Check 'config_exists' 'FAIL' "Not found: $ConfigPath" `
        'Claude Desktop has never run on this account, OR it stores config elsewhere on this build. Open Claude Desktop once, then re-run install.bat.'
} else {
    Add-Check 'config_exists' 'PASS' $ConfigPath
    try {
        $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json }
        Add-Check 'config_parseable' 'PASS'
    } catch {
        Add-Check 'config_parseable' 'FAIL' "Parse error: $($_.Exception.Message)" `
            'Open the file and fix the JSON syntax. Another tool may have appended invalid content.'
    }
}

if ($config) {
    $hasMcp = ($config | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue) -as [bool]
    if (-not $hasMcp) {
        Add-Check 'config_has_entry' 'FAIL' 'No "mcpServers" key in config' `
            'A managed policy or sync tool may have replaced the config. Re-run install.bat. If it disappears again, your org is overwriting the file.'
    } else {
        $hasEntry = ($config.mcpServers | Get-Member -Name 'prompt-time' -ErrorAction SilentlyContinue) -as [bool]
        if (-not $hasEntry) {
            Add-Check 'config_has_entry' 'FAIL' 'mcpServers.prompt-time missing' `
                'Re-run install.bat. If the entry is missing again afterwards, your org has a managed Claude Desktop config that overrides user changes.'
        } else {
            $entry = $config.mcpServers.'prompt-time'
            $entryArgsArr = @($entry.args)
            $entryArgsStr = $entryArgsArr -join ' '
            Add-Check 'config_has_entry' 'PASS' "command=$($entry.command); args=$entryArgsStr"

            $pathFromConfig = $null
            for ($i = 0; $i -lt $entryArgsArr.Count - 1; $i++) {
                if ($entryArgsArr[$i] -eq '-File') { $pathFromConfig = $entryArgsArr[$i + 1]; break }
            }
            if (-not $pathFromConfig) {
                Add-Check 'config_script_path_valid' 'FAIL' 'No -File argument found in config entry' `
                    'Re-run install.bat to rewrite the config entry.'
            } elseif (-not (Test-Path $pathFromConfig)) {
                Add-Check 'config_script_path_valid' 'FAIL' "Path in config does not exist: $pathFromConfig" `
                    'You moved or deleted the prompt-time folder after install. Re-run install.bat from its current location.'
            } else {
                Add-Check 'config_script_path_valid' 'PASS' $pathFromConfig
            }
        }
    }

    # List other MCP servers - if there are zero AND prompt-time is the only one and tools still don't appear,
    # the user may have Developer Mode disabled.
    $otherServers = @()
    if ($hasMcp) {
        $otherServers = @($config.mcpServers.PSObject.Properties.Name | Where-Object { $_ -ne 'prompt-time' })
    }
    Add-Check 'other_mcp_servers' 'INFO' "Other servers in config: $(if ($otherServers.Count) { $otherServers -join ', ' } else { '(none)' })"
}

# 1b. MSIX shadow vs Real divergence.
#     The fingerprint failure mode: MSIX-packaged Claude has written to
#     claude_desktop_config.json (creating a per-package shadow), so it now reads
#     from the shadow -- but our installer wrote to %APPDATA%. Two files, neither
#     aware of the other, tools never appear.
if ($ShadowConfigPath) {
    $shadowExists = Test-Path $ShadowConfigPath
    $realHasEntry   = $false
    $shadowHasEntry = $false
    if ($config -and ($config | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
        $realHasEntry = ($config.mcpServers | Get-Member -Name 'prompt-time' -ErrorAction SilentlyContinue) -as [bool]
    }
    if ($shadowExists) {
        try {
            $shadowRaw  = Get-Content $ShadowConfigPath -Raw -Encoding UTF8
            $shadowJson = if ($shadowRaw.Trim()) { $shadowRaw | ConvertFrom-Json } else { $null }
            if ($shadowJson -and ($shadowJson | Get-Member -Name 'mcpServers' -ErrorAction SilentlyContinue)) {
                $shadowHasEntry = ($shadowJson.mcpServers | Get-Member -Name 'prompt-time' -ErrorAction SilentlyContinue) -as [bool]
            }
        } catch { Write-Verbose "Shadow parse failed: $_" }
    }

    if (-not $shadowExists) {
        Add-Check 'msix_shadow_config' 'PASS' "No shadow at $ShadowConfigPath -- Claude reads from %APPDATA% directly. Single-write installs work."
    } elseif ($shadowHasEntry -and $realHasEntry) {
        Add-Check 'msix_shadow_config' 'PASS' "Shadow + Real both have prompt-time entry. Path: $ShadowConfigPath"
    } elseif ($shadowHasEntry -and -not $realHasEntry) {
        Add-Check 'msix_shadow_config' 'WARN' "Shadow has the entry but Real does not. Claude will load it; uninstall may leave stale shadow." `
            'Re-run install.bat to sync both paths, or run uninstall.bat to remove cleanly from both.'
    } elseif (-not $shadowHasEntry -and $realHasEntry) {
        Add-Check 'msix_shadow_config' 'FAIL' "Shadow exists but is missing prompt-time. Claude reads shadow, NOT %APPDATA%, so the entry is invisible to Claude.`nShadow: $ShadowConfigPath" `
            'This is the classic MSIX file-virtualization trap. Re-run install.bat (v2.2.3+) which writes to both shadow and %APPDATA%.'
    } else {
        Add-Check 'msix_shadow_config' 'FAIL' "Shadow exists but has no prompt-time, and Real also has no prompt-time. Install never wrote it." `
            'Re-run install.bat.'
    }
}

# ---------------------------------------------------------------
# 2. Watcher scheduled task
# ---------------------------------------------------------------
$watcher = Get-ScheduledTask -TaskName $WatcherTask -ErrorAction SilentlyContinue
if (-not $watcher) {
    Add-Check 'watcher_task' 'FAIL' "$WatcherTask not registered" 'Re-run install.bat.'
} else {
    $info = $watcher | Get-ScheduledTaskInfo
    $running = ($watcher.State -eq 'Running') -or ($info.LastTaskResult -in 0, 267009)
    if ($running) {
        Add-Check 'watcher_task' 'PASS' "State=$($watcher.State); LastResult=$($info.LastTaskResult); LastRun=$($info.LastRunTime)"
    } else {
        Add-Check 'watcher_task' 'WARN' "State=$($watcher.State); LastResult=$($info.LastTaskResult)" `
            'Start it: Start-ScheduledTask -TaskName PROMPTTIME-Watcher'
    }
}

# ---------------------------------------------------------------
# 3. Spawn prompt_time.ps1 the way Claude Desktop will and probe with JSON-RPC initialize.
#    Catches: AppLocker / Constrained Language Mode / SmartScreen / signature-required policies
#    that block PowerShell from running scripts in this folder.
# ---------------------------------------------------------------
function Test-McpServerSpawnable {
    [CmdletBinding()]
    param([string]$ScriptPath, [int]$TimeoutMs = 6000)

    if (-not (Test-Path $ScriptPath)) {
        return @{ ok=$false; reason="prompt_time.ps1 not found at $ScriptPath" }
    }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps)) {
        return @{ ok=$false; reason="powershell.exe not found at $ps" }
    }

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
        return @{
            ok     = $false
            reason = "powershell.exe spawn failed: $($_.Exception.Message)"
            hint   = 'AppLocker, WDAC, or Group Policy may block powershell.exe from launching scripts in this directory.'
        }
    }

    $initMsg = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"prompt-time-diagnose","version":"1.0"}}}'
    try {
        $proc.StandardInput.WriteLine($initMsg)
        $proc.StandardInput.Flush()
    } catch {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { Write-Verbose "Kill: $_" } }
        return @{ ok=$false; reason="stdin write failed: $($_.Exception.Message)" }
    }

    $readTask  = $proc.StandardOutput.ReadLineAsync()
    $completed = $readTask.Wait($TimeoutMs)

    $stderr = ''
    try {
        if ($proc.HasExited) { $stderr = $proc.StandardError.ReadToEnd() }
    } catch { Write-Verbose "stderr read: $_" }

    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch { Write-Verbose "Kill: $_" }
        $proc.WaitForExit(2000) | Out-Null
        if (-not $stderr) {
            try { $stderr = $proc.StandardError.ReadToEnd() } catch { Write-Verbose "stderr read post-kill: $_" }
        }
    }

    if (-not $completed) {
        return @{
            ok     = $false
            reason = "MCP server did not respond within ${TimeoutMs}ms"
            stderr = $stderr
            hint   = 'Server is launching but never writes to stdout. Likely a script error before the request loop starts -- check stderr above.'
        }
    }

    $line = $readTask.Result
    if ($line -and $line -match '"jsonrpc"\s*:\s*"2\.0"' -and $line -match '"id"\s*:\s*1') {
        return @{ ok=$true; reason='MCP server responded to initialize'; response=$line }
    }
    return @{
        ok     = $false
        reason = "Unexpected output: $line"
        stderr = $stderr
        hint   = 'Server printed something other than a JSON-RPC response on first line. Stderr above usually contains the real error.'
    }
}

$spawn = Test-McpServerSpawnable -ScriptPath $McpScript
if ($spawn.ok) {
    Add-Check 'mcp_server_spawnable' 'PASS' $spawn.reason
} else {
    $detail = $spawn.reason
    if ($spawn.stderr) { $detail += "`n--- stderr ---`n$($spawn.stderr.Trim())" }
    Add-Check 'mcp_server_spawnable' 'FAIL' $detail $spawn.hint
}

# ---------------------------------------------------------------
# 4. Claude Desktop's MCP log - did it actually try to load prompt-time?
# ---------------------------------------------------------------
$serverLog = Join-Path $ClaudeLogs 'mcp-server-prompt-time.log'
$globalLog = Join-Path $ClaudeLogs 'mcp.log'

if (-not (Test-Path $ClaudeLogs)) {
    Add-Check 'claude_log_dir' 'WARN' "$ClaudeLogs not found" `
        'Claude Desktop has not written logs to this account yet. Restart Claude Desktop fully (right-click tray -> Quit) and re-run diagnose.'
} elseif (-not (Test-Path $serverLog)) {
    # Server log not present -- Claude Desktop never tried to start prompt-time.
    # Look for a clue in the global log (e.g. config not loaded, parse error).
    $hint = 'Claude Desktop never attempted to launch prompt-time. Either it has not been restarted since install, OR it is reading a different config file (managed policy / non-default profile). Fully quit Claude Desktop (tray icon -> Quit) and reopen.'
    if (Test-Path $globalLog) {
        $recent = Get-Content $globalLog -Tail 200 -ErrorAction SilentlyContinue
        $relevant = $recent | Where-Object { $_ -match 'prompt-time|mcpServers|config' } | Select-Object -Last 10
        $detail = "No mcp-server-prompt-time.log written.`nRecent matching lines from mcp.log:`n$($relevant -join "`n")"
        Add-Check 'claude_started_server' 'FAIL' $detail $hint
    } else {
        Add-Check 'claude_started_server' 'FAIL' 'No mcp-server-prompt-time.log AND no mcp.log' $hint
    }
} else {
    $tail = Get-Content $serverLog -Tail 30 -ErrorAction SilentlyContinue
    $started   = $tail -match 'Server started and connected successfully'
    $errLines  = $tail | Where-Object { $_ -match 'error|Error|ERROR|fail|Fail|FAIL|exited|Exited' }
    if ($started -and -not $errLines) {
        Add-Check 'claude_started_server' 'PASS' "Last log line shows successful start.`nLog: $serverLog"
    } elseif ($started -and $errLines) {
        Add-Check 'claude_started_server' 'WARN' "Started, but errors logged:`n$($errLines -join "`n")" `
            'Server started but later errors may have stopped it. Check log for full context.'
    } else {
        Add-Check 'claude_started_server' 'FAIL' "Server log present but no successful start.`n$($tail -join "`n")" `
            'Claude Desktop tried to launch prompt-time but the spawn failed. Most common cause: AppLocker / WDAC blocks powershell.exe from being launched as a child of the Claude Desktop MSIX package.'
    }
}

# ---------------------------------------------------------------
# 5. Cowork / built-in scheduled tasks (informational only)
#    If Cowork is enabled, generic "remind me" prompts may route there
#    instead of prompt-time. v2.2.2 strengthened our tool descriptions
#    to disambiguate, but it's worth knowing.
# ---------------------------------------------------------------
$claudeAppCfg = Join-Path $env:APPDATA 'Claude\config.json'
if (Test-Path $claudeAppCfg) {
    try {
        $appcfg = Get-Content $claudeAppCfg -Raw | ConvertFrom-Json
        $cowork = if ($appcfg.PSObject.Properties.Match('coworkScheduledTasksEnabled').Count) { $appcfg.coworkScheduledTasksEnabled } else { $null }
        if ($cowork -eq $true) {
            Add-Check 'cowork_enabled' 'INFO' 'Cowork scheduled tasks enabled in Claude Desktop' `
                'Generic "remind me" prompts may route to Cowork instead of prompt-time. Say "desktop popup" or "Windows reminder" to disambiguate.'
        }
    } catch { Write-Verbose "Could not parse Claude app config: $_" }
}

# ---------------------------------------------------------------
# 6. Managed-policy registry keys
# ---------------------------------------------------------------
$policyHits = @()
foreach ($p in @('HKLM:\Software\Policies\Anthropic', 'HKLM:\Software\Policies\Claude',
                 'HKCU:\Software\Policies\Anthropic', 'HKCU:\Software\Policies\Claude')) {
    if (Test-Path $p) { $policyHits += $p }
}
if ($policyHits.Count -gt 0) {
    Add-Check 'managed_policy' 'WARN' "Found policy keys: $($policyHits -join '; ')" `
        'Your org may push a managed Claude Desktop config that overrides user changes. If config keeps getting reverted, this is why.'
} else {
    Add-Check 'managed_policy' 'PASS' 'No Anthropic/Claude managed policies in registry'
}

# ---------------------------------------------------------------
# 7. PowerShell execution policy snapshot (informational)
# ---------------------------------------------------------------
try {
    $polChain = Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }
    Add-Check 'powershell_policy' 'INFO' ($polChain -join '; ')
} catch { Write-Verbose "Get-ExecutionPolicy failed: $_" }

# ---------------------------------------------------------------
# Output
# ---------------------------------------------------------------
if ($Json) {
    $report | ConvertTo-Json -Depth 8
    if ($report.checks.Values | Where-Object { $_.status -eq 'FAIL' }) { exit 1 } else { exit 0 }
}

Write-Host ''
Write-Host "  prompt-time diagnostic ($installedVersion)" -ForegroundColor Cyan
Write-Host '  -------------------------------------------'
Write-Host ''

foreach ($k in $report.checks.Keys) {
    $c = $report.checks[$k]
    switch ($c.status) {
        'PASS' { $color = 'Green';  $tag = 'PASS' }
        'FAIL' { $color = 'Red';    $tag = 'FAIL' }
        'WARN' { $color = 'Yellow'; $tag = 'WARN' }
        default { $color = 'DarkGray'; $tag = 'INFO' }
    }
    Write-Host ("  [{0}] {1}" -f $tag, $k) -ForegroundColor $color
    if ($c.detail) {
        $indented = ($c.detail -replace "`r?`n", "`n         ")
        Write-Host "         $indented" -ForegroundColor DarkGray
    }
    if ($c.hint -and $c.status -in 'FAIL','WARN') {
        Write-Host "         hint: $($c.hint)" -ForegroundColor Yellow
    }
}

Write-Host ''
$failed = @($report.checks.GetEnumerator() | Where-Object { $_.Value.status -eq 'FAIL' })
$warned = @($report.checks.GetEnumerator() | Where-Object { $_.Value.status -eq 'WARN' })
if ($failed.Count -eq 0 -and $warned.Count -eq 0) {
    Write-Host '  All checks passed. If tools still do not appear:' -ForegroundColor Green
    Write-Host '    1. Right-click Claude Desktop tray icon -> Quit (do not just close the window).' -ForegroundColor Green
    Write-Host '    2. Reopen Claude Desktop. Tools appear after first model response.' -ForegroundColor Green
} else {
    Write-Host "  $($failed.Count) failed, $($warned.Count) warning(s). Address the hints above in order." -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  For a copyable bug report:' -ForegroundColor DarkGray
Write-Host '    diagnose.bat -Json' -ForegroundColor DarkGray
Write-Host ''

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
