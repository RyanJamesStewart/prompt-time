# prompt-time-watcher.ps1 -- the polling daemon.
#
# Registered ONCE at install time as a Task Scheduler task with an "At LogOn"
# trigger and restart-on-failure. Polls the queue file every 10s; for any due
# reminder, renders the popup in-process. No IPC, no MSIX-boundary crossing.
#
# This script runs in the user's normal context (NOT inside any MSIX package),
# so $env:USERPROFILE etc. resolve to the real paths.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $null = $_ }

# Resolve the data dir the SAME way prompt_time.ps1 does -- discover Claude
# Desktop's MSIX package and use its LocalCache writable storage; fall back
# to %APPDATA%\prompt-time for legacy non-MSIX Claude Desktop installs.
function Get-PromptTimeDataDir {
    if ($env:PROMPTTIME_DATA_DIR) { return $env:PROMPTTIME_DATA_DIR }
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            return Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\prompt-time" -f $pkg.PackageFamilyName)
        }
    } catch {
        # Server SKUs without AppX module fall through to the legacy path.
        $null = $_
    }
    return Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'
}

$DATA_DIR        = Get-PromptTimeDataDir
$QUEUE_FILE      = Join-Path $DATA_DIR 'queue.jsonl'
$LOCK_FILE       = Join-Path $DATA_DIR 'queue.lock'
$QUARANTINE_FILE = Join-Path $DATA_DIR 'queue.jsonl.quarantine'
$DEBUG_LOG       = Join-Path $DATA_DIR 'prompt-time.debug.log'
$POLL_SECONDS    = 10
$WATCHER_VERSION = '2.2.6'

# Operational caps.
$MAX_LOG_BYTES        = 1MB     # rotate when exceeded; keep one rolled file
$MAX_CONCURRENT_POPUPS = 10     # bound the spawn-storm if N reminders fire at once
$MAX_RECURRENCE_SKIP  = 10000   # cap forward-jumps for a 5-year-stale daily reminder

if (-not (Test-Path $DATA_DIR)) {
    New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null
}

# Log rotation runs once at startup. With a 10s poll we don't need
# per-tick rotation; once-per-process-restart is sufficient under realistic
# load and avoids the file-handle dance during a busy fire cycle.
if (Test-Path $DEBUG_LOG) {
    try {
        $sz = (Get-Item $DEBUG_LOG).Length
        if ($sz -gt $MAX_LOG_BYTES) {
            $rolled = "$DEBUG_LOG.1"
            if (Test-Path $rolled) { Remove-Item $rolled -Force -ErrorAction SilentlyContinue }
            Move-Item $DEBUG_LOG $rolled -Force -ErrorAction SilentlyContinue
        }
    } catch { $null = $_ }
}

# WinForms one-time process init. Critical: SetCompatibleTextRenderingDefault and
# EnableVisualStyles MUST be called before the first IWin32Window is created in
# the process, AND can only be called once. The watcher is long-running, so we
# do this exactly once here at the top, NOT inside Show-StickyNote.
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing      -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
} catch {
    # Forms still work without these; they just look slightly older.
    # Don't crash the watcher.
    $null = $_
}

function Write-Log([string]$msg) {
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $DEBUG_LOG -Value "[$stamp] [watcher] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging must never throw -- it's called from finally / catch blocks.
        $null = $_
    }
}

# Render a sticky-note popup in a SEPARATE PowerShell process so the watcher
# loop returns immediately and can fire the next reminder without waiting for
# the user to dismiss this one. Each popup is fully independent: its own
# WinForms message pump, its own state, its own lifecycle.
#
# User-supplied title and message are passed via environment variables on the
# child ProcessStartInfo, NOT interpolated into the script body. PowerShell
# never parses env-var contents as code, so this is the safe boundary --
# regardless of what characters (quotes, backticks, $(), ;, newlines) appear in
# a reminder message, the child only ever reads them as literal strings.
$POPUP_TEMPLATE = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$titleText = if ([string]::IsNullOrWhiteSpace($env:PROMPTTIME_TITLE))   { 'Reminder' }       else { $env:PROMPTTIME_TITLE }
$bodyText  = if ([string]::IsNullOrWhiteSpace($env:PROMPTTIME_MESSAGE)) { '(empty reminder)' } else { $env:PROMPTTIME_MESSAGE }
$Slot      = 0
[int]::TryParse($env:PROMPTTIME_SLOT, [ref]$Slot) | Out-Null

# Cascade offset: each subsequent popup steps up + left by 28px so they don't
# stack directly on top of each other. Wraps after 6 slots.
$cascadeStep = 28
$cascadeIdx  = $Slot % 6
$offsetX     = $cascadeIdx * $cascadeStep
$offsetY     = $cascadeIdx * $cascadeStep

$form = New-Object System.Windows.Forms.Form
$form.Text            = $titleText
$form.StartPosition   = 'Manual'
$screen               = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size            = New-Object System.Drawing.Size(400, 210)
$form.Location        = New-Object System.Drawing.Point(($screen.Right - 420 - $offsetX), ($screen.Bottom - 230 - $offsetY))
$form.TopMost         = $true
$form.BackColor       = [System.Drawing.Color]::FromArgb(255, 252, 209)
$form.FormBorderStyle = 'FixedDialog'
$form.ControlBox      = $false
$form.ShowInTaskbar   = $true
$form.MinimizeBox     = $false
$form.MaximizeBox     = $false
$form.KeyPreview      = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

$msgLbl = New-Object System.Windows.Forms.Label
$msgLbl.Text         = $bodyText
$msgLbl.Font         = New-Object System.Drawing.Font('Segoe UI', 13)
$msgLbl.AutoSize     = $true
$msgLbl.MaximumSize  = New-Object System.Drawing.Size(370, 0)
$msgLbl.Location     = New-Object System.Drawing.Point(14, 14)
$msgLbl.TextAlign    = [System.Drawing.ContentAlignment]::TopLeft
$form.Controls.Add($msgLbl)

$btn = New-Object System.Windows.Forms.Button
$btn.Text     = 'Dismiss'
$btn.Size     = New-Object System.Drawing.Size(86, 30)
$btn.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
$btn.Add_Click({ $form.Close() })
$form.Controls.Add($btn)
$form.AcceptButton = $btn

$form.Add_Shown({
    $msgLbl.PerformLayout()
    $gap          = 12
    $bottomMargin = 14
    $btnX         = [int](($form.ClientSize.Width - $btn.Width) / 2)
    $btnY         = $msgLbl.Bottom + $gap
    $btn.Location = New-Object System.Drawing.Point($btnX, $btnY)
    $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, ($btn.Bottom + $bottomMargin))
    $form.Activate()
    $form.BringToFront()
})

try { (New-Object Media.SoundPlayer "$env:WINDIR\Media\Windows Notify Calendar.wav").PlaySync() | Out-Null } catch { }
[void]$form.ShowDialog()
'@

# Track active popup process IDs so we can assign cascading slot offsets.
# Each new popup gets the count of currently-alive prior popups as its slot,
# and the popup template uses that to step its position up-and-left.
$script:ActivePopupPids = New-Object System.Collections.Generic.List[int]

function Get-NextPopupSlot {
    $alive = New-Object System.Collections.Generic.List[int]
    foreach ($p in $script:ActivePopupPids) {
        if (Get-Process -Id $p -ErrorAction SilentlyContinue) { $alive.Add($p) }
    }
    $script:ActivePopupPids = $alive
    return $alive.Count
}

function Show-StickyNote([string]$t, [string]$m) {
    $slot = Get-NextPopupSlot
    if ($null -eq $t) { $t = '' }
    if ($null -eq $m) { $m = '' }
    if ($t.Length -gt 500)  { $t = $t.Substring(0, 500) }
    if ($m.Length -gt 4000) { $m = $m.Substring(0, 4000) }
    Write-Log "show: spawning popup process (titleLen=$($t.Length), msgLen=$($m.Length), slot=$slot)"

    # Encode the popup template by itself -- no user content is interpolated
    # into the script. Title/message reach the child as environment variables.
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($POPUP_TEMPLATE)
    $encoded = [Convert]::ToBase64String($bytes)

    $psPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $psPath
        $psi.Arguments       = "-NoProfile -STA -WindowStyle Hidden -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        # Pass user-controlled strings as env vars. PowerShell never parses these
        # as code; the child reads them with $env:PROMPTTIME_* and treats them as
        # literal text in the WinForms labels.
        $psi.EnvironmentVariables['PROMPTTIME_TITLE']   = $t
        $psi.EnvironmentVariables['PROMPTTIME_MESSAGE'] = $m
        $psi.EnvironmentVariables['PROMPTTIME_SLOT']    = $slot.ToString()
        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:ActivePopupPids.Add($proc.Id)
        Write-Log "show: popup PID $($proc.Id) started, watcher continues"
    } catch {
        Write-Log "show: failed to spawn popup process: $_"
    }
}

function Step-Recurrence([datetime]$dt, [string]$rec) {
    switch ($rec) {
        'daily'    { return $dt.AddDays(1) }
        'weekly'   { return $dt.AddDays(7) }
        'weekdays' {
            $next = $dt.AddDays(1)
            while ($next.DayOfWeek -eq 'Saturday' -or $next.DayOfWeek -eq 'Sunday') {
                $next = $next.AddDays(1)
            }
            return $next
        }
        default    { return $null }
    }
}

# Parse the stored ISO-8601 fireAt preserving offset. Without RoundtripKind a
# string like '2026-05-07T15:30:00-07:00' silently converts to local time and
# loses its zone information, which then drifts on DST transitions.
function ConvertFrom-IsoDateString([string]$s) {
    return [datetime]::Parse(
        $s,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
}

# Quarantine a malformed queue line: append it to a sibling file and never
# look at it again. Without this, a single bad line gets logged every poll
# tick (~8,640 times/day) and accumulates GBs of debug log over a year.
function Add-Quarantine([string]$rawLine, [string]$reason) {
    try {
        $stamp  = (Get-Date).ToString('o')
        $record = "[$stamp] [$reason] $rawLine"
        Add-Content -LiteralPath $QUARANTINE_FILE -Value $record -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        Write-Log "quarantine write failed: $($_.Exception.Message)"
    }
}

# Sentinel-lock primitive shared with prompt_time.ps1. Decouples the lock from
# the data file so we can combine exclusive access with atomic tmp+rename writes.
function Open-QueueLock {
    for ($i = 0; $i -lt 40; $i++) {
        try {
            return [System.IO.File]::Open($LOCK_FILE, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    return $null
}

# Atomic read-modify-write on the queue file. Bad lines are quarantined (not
# kept in the live queue) so they don't accumulate log spam. Writes go to a
# sibling .tmp first and atomic-rename, so a process kill mid-write cannot
# leave the queue empty or partial -- the worst case is an orphaned .tmp.
function Invoke-QueueUpdate([scriptblock]$Modify) {
    $lock = Open-QueueLock
    if (-not $lock) {
        Write-Log 'lock: could not acquire queue lock within 2s; will retry next tick'
        return $null
    }
    try {
        $entries = New-Object System.Collections.Generic.List[object]
        if (Test-Path $QUEUE_FILE) {
            foreach ($line in (Get-Content -LiteralPath $QUEUE_FILE -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $entries.Add(($line | ConvertFrom-Json)) }
                catch {
                    Write-Log "queue: quarantining malformed line: $($_.Exception.Message)"
                    Add-Quarantine $line "parse:$($_.Exception.Message)"
                }
            }
        }

        $result = & $Modify @($entries.ToArray())
        if ($result -is [hashtable]) { $keep = $result['Keep']; $out = $result['Out'] }
        else                          { $keep = $result;        $out = $null }

        $tmp  = "$QUEUE_FILE.tmp"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $sw   = New-Object System.IO.StreamWriter($tmp, $false, $utf8)
        try {
            if ($keep) {
                foreach ($k in $keep) { $sw.WriteLine(($k | ConvertTo-Json -Compress -Depth 10)) }
            }
            $sw.Flush()
        } finally { $sw.Dispose() }

        if (Test-Path $QUEUE_FILE) {
            # NullString::Value, not $null -- PS 5.1 coerces $null to "" for
            # this overload, which File.Replace then rejects as a bad path.
            [System.IO.File]::Replace($tmp, $QUEUE_FILE, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tmp, $QUEUE_FILE)
        }
        return $out
    } finally {
        $lock.Dispose()
    }
}

Write-Log "watcher started (prompt-time v$WATCHER_VERSION pid=$PID poll=${POLL_SECONDS}s queue=$QUEUE_FILE)"

while ($true) {
    try {
        $due = Invoke-QueueUpdate {
            param($entries)
            if (-not $entries -or @($entries).Count -eq 0) { return @{ Keep = @(); Out = @() } }
            $now  = Get-Date
            $keep = New-Object System.Collections.Generic.List[object]
            $fire = New-Object System.Collections.Generic.List[object]
            foreach ($e in $entries) {
                $when = $null
                try { $when = ConvertFrom-IsoDateString $e.fireAt }
                catch {
                    Write-Log "skip: id=$($e.id) has unparseable fireAt='$($e.fireAt)'; quarantining"
                    Add-Quarantine ($e | ConvertTo-Json -Compress -Depth 10) 'unparseable_fireAt'
                    continue
                }
                if ($when -le $now) {
                    # Clock-rewind dedupe: if the entry was created AFTER the
                    # nominal fire time, the user (or DST/manual) moved the
                    # clock backward. Don't re-fire what already fired.
                    $created = $null
                    try { if ($e.PSObject.Properties.Match('createdAt').Count) { $created = ConvertFrom-IsoDateString $e.createdAt } } catch { $null = $_ }
                    if ($created -and $created -gt $when) {
                        Write-Log "skip: id=$($e.id) already fired (clock rewound); advancing without re-firing"
                        if ($e.recurrence -ne 'once') {
                            $next = Step-Recurrence $when $e.recurrence
                            if ($next) {
                                $iters = 0
                                while ($next -le $now -and $iters -lt $MAX_RECURRENCE_SKIP) {
                                    $next = Step-Recurrence $next $e.recurrence
                                    $iters++
                                }
                                $e.fireAt = $next.ToString('o')
                                $keep.Add($e)
                            }
                        }
                        continue
                    }

                    $fire.Add($e)
                    if ($e.recurrence -ne 'once') {
                        $next = Step-Recurrence $when $e.recurrence
                        if ($next) {
                            # Skip past missed iterations (machine asleep, etc.) but
                            # cap to avoid an unbounded loop on a stale entry from years ago.
                            $iters = 0
                            while ($next -le $now -and $iters -lt $MAX_RECURRENCE_SKIP) {
                                $next = Step-Recurrence $next $e.recurrence
                                $iters++
                            }
                            if ($iters -ge $MAX_RECURRENCE_SKIP) {
                                Write-Log "warn: id=$($e.id) hit recurrence skip cap ($MAX_RECURRENCE_SKIP); entry was severely stale"
                            }
                            $e.fireAt = $next.ToString('o')
                            $keep.Add($e)
                        }
                    }
                } else {
                    $keep.Add($e)
                }
            }
            return @{ Keep = $keep.ToArray(); Out = $fire.ToArray() }
        }

        # Spawn popups OUTSIDE the locked section so a slow Process.Start does
        # not block server appends. Cap the spawn-storm so a flood of
        # simultaneous reminders can't exhaust memory or CPU.
        if ($due) {
            $alreadyAlive = $null
            try { $alreadyAlive = (Get-NextPopupSlot) } catch { $alreadyAlive = 0 }
            $remainingBudget = $MAX_CONCURRENT_POPUPS - $alreadyAlive
            $renderedThisTick = 0
            foreach ($e in $due) {
                if ($renderedThisTick -ge $remainingBudget) {
                    Write-Log "rate-limit: id=$($e.id) deferred (already $($alreadyAlive + $renderedThisTick) live popups; cap=$MAX_CONCURRENT_POPUPS)"
                    continue
                }
                Write-Log "fire: id=$($e.id) titleLen=$($e.title.Length) msgLen=$($e.message.Length)"
                try {
                    Show-StickyNote $e.title $e.message
                    $renderedThisTick++
                } catch {
                    Write-Log "render failed for $($e.id): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "loop error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $POLL_SECONDS
}
