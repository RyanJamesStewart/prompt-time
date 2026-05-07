# prompt_time.ps1 -- MCP server for Windows reminders.
# No dependencies. Requires only Windows 10/11 + Claude Desktop + PowerShell 5.1+.

# Architecture: this MCP server only enqueues reminders. A separate watcher
# daemon (prompt-time-watcher.ps1, registered as a single Task Scheduler task at
# install time) polls the queue and renders the popup in-process.
# Why a daemon? Claude Desktop is MSIX-packaged; writes from this server's
# context get silently redirected into the package's LocalCache shadow tree,
# while Task Scheduler runs anything it spawns *outside* the package -- so a
# per-reminder schtasks task can never reliably find files this server wrote.
# Keeping rendering inside the watcher (which runs in user context, not packaged)
# avoids the entire boundary-crossing class of bugs.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {
    # Best-effort. Some hosts (e.g. ISE) refuse to set Console encodings; the
    # MCP loop still works because ConvertTo-Json emits ASCII-safe output.
    $null = $_
}

# Resolve the data directory to a path that's identical from inside Claude
# Desktop (the MSIX-packaged MCP server) and outside (the watcher). For MSIX
# Claude Desktop, that's the package's LocalCache writable storage. For a
# legacy non-MSIX Claude Desktop, it's just %APPDATA%\prompt-time. Both server
# and watcher run this same discovery, end up at the same physical file.
function Get-PromptTimeDataDir {
    # Test override: when set, every component (server/watcher/installer) uses
    # this path instead of probing for Claude. Lets the Pester suite point at
    # a temp dir without touching real user state.
    if ($env:PROMPTTIME_DATA_DIR) { return $env:PROMPTTIME_DATA_DIR }
    try {
        $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            return Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\prompt-time" -f $pkg.PackageFamilyName)
        }
    } catch {
        # Get-AppxPackage can fail on Windows Server SKUs without the AppX
        # PowerShell module. Fall through to the legacy path.
        $null = $_
    }
    return Join-Path $env:USERPROFILE 'AppData\Roaming\prompt-time'
}

$DATA_DIR    = Get-PromptTimeDataDir
$QUEUE_FILE  = Join-Path $DATA_DIR 'queue.jsonl'
$LOCK_FILE   = Join-Path $DATA_DIR 'queue.lock'
$DEBUG_LOG   = Join-Path $DATA_DIR 'prompt-time.debug.log'
$VERSION_FILE = Join-Path $DATA_DIR 'VERSION'
$TASK_PREFIX = 'PROMPTTIME'
$PROMPTTIME_VERSION = '2.2.2'
$QUEUE_SCHEMA_V  = 1

# Reminder validation limits -- enforced at schedule time so they're consistent
# regardless of where in the pipeline content lands.
$MAX_TITLE_LEN   = 500
$MAX_MESSAGE_LEN = 4000
$VALID_RECURRENCE = @('once', 'daily', 'weekly', 'weekdays')

# Hard cap on a single JSON-RPC message (line of stdin). MCP messages are tiny;
# anything beyond this is either a runaway client or a DoS attempt. Reject
# before ConvertFrom-Json which has no built-in depth/length limit on PS 5.1.
$MAX_RPC_LINE_BYTES = 65536

function Test-DataDir {
    if (-not (Test-Path $DATA_DIR)) {
        try {
            New-Item -ItemType Directory -Path $DATA_DIR -Force -ErrorAction Stop | Out-Null
        } catch {
            # We are likely inside Claude Desktop's MSIX package and the install
            # step never ran, so the canonical real path doesn't exist yet. The
            # watcher won't see writes that land in our LocalCache shadow.
            Write-DebugLog "data dir create failed: $_"
        }
    }
}

function Write-DebugLog([string]$msg) {
    try {
        if (-not (Test-Path $DATA_DIR)) {
            New-Item -ItemType Directory -Path $DATA_DIR -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $DEBUG_LOG -Value "[$stamp] [server] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging must never throw -- callers depend on it being safe in any
        # context, including catch blocks that already hold an exception.
        $null = $_
    }
}

# --- Date parser -------------------------------------------------------------
function ConvertFrom-TimeOfDay($s) {
    $s = $s.Trim()
    if ($s -match '^(\d{1,2}):(\d{2})\s*(am|pm)?$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]; $ap = $Matches[3]
        if ($ap -eq 'pm' -and $h -ne 12) { $h += 12 }
        elseif ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
        return [pscustomobject]@{ h = $h; m = $m }
    }
    if ($s -match '^(\d{1,2})\s*(am|pm)$') {
        $h = [int]$Matches[1]; $ap = $Matches[2]
        if ($ap -eq 'pm' -and $h -ne 12) { $h += 12 }
        elseif ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
        return [pscustomobject]@{ h = $h; m = 0 }
    }
    return $null
}

# Parse an ISO-8601 datetime string preserving the original DateTimeKind/offset.
# Used on the read path so timezone-aware comparisons against Get-Date (Local)
# don't silently drift across DST boundaries or VM clock changes.
function ConvertFrom-IsoDateString([string]$s) {
    return [datetime]::Parse(
        $s,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
}

function ConvertFrom-NLDate($text) {
    $now = Get-Date
    $t   = ($text.Trim().ToLowerInvariant() -replace '\s+', ' ')
    if ($t -match '^in\s+(\d+)\s+(min(?:utes?)?|hrs?|hours?)$') {
        # Guard against [int] overflow on huge inputs ("in 999999999999 minutes").
        $raw = $Matches[1]
        if ($raw.Length -gt 9) {
            throw "Number too large in '$text'. Try 'in 30 minutes' or a clearer date."
        }
        $n = [int]$raw
        return $(if ($Matches[2] -match '^min') { $now.AddMinutes($n) } else { $now.AddHours($n) })
    }
    if ($t -match '^today\s+(?:at\s+)?(.+)$') {
        $pt = ConvertFrom-TimeOfDay $Matches[1]
        if ($pt) { return $now.Date.AddHours($pt.h).AddMinutes($pt.m) }
    }
    if ($t -match '^tomorrow\s+(?:at\s+)?(.+)$') {
        $pt = ConvertFrom-TimeOfDay $Matches[1]
        if ($pt) { return $now.Date.AddDays(1).AddHours($pt.h).AddMinutes($pt.m) }
    }
    $dow = @{ sunday=0; monday=1; tuesday=2; wednesday=3; thursday=4; friday=5; saturday=6 }
    foreach ($day in $dow.Keys) {
        if ($t -match "^(?:next\s+)?$day\s+(?:at\s+)?(.+)$") {
            $pt = ConvertFrom-TimeOfDay $Matches[1]
            if ($pt) {
                $diff = ($dow[$day] - [int]$now.DayOfWeek + 7) % 7
                if ($diff -eq 0) { $diff = 7 }
                return $now.Date.AddDays($diff).AddHours($pt.h).AddMinutes($pt.m)
            }
        }
    }
    # Final fallback: .NET datetime parser, pinned to invariant culture so
    # behavior is identical across English/German/French/etc. Windows. Pass
    # RoundtripKind so an ISO-8601 with offset retains its zone information.
    try {
        # Reject inputs that don't look like a datetime to avoid the Parse
        # quirk where bare "5" becomes 12:05 AM today, etc.
        if ($text.Trim().Length -lt 4) {
            Write-DebugLog "ConvertFrom-NLDate: input too short to be a datetime: '$text'"
            return $null
        }
        return [datetime]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        Write-DebugLog "ConvertFrom-NLDate: invariant Parse failed for '$text': $($_.Exception.Message)"
    }
    return $null
}

# --- Queue helpers -----------------------------------------------------------
# Concurrency model: a sentinel lock file (queue.lock) decouples the lock
# primitive from the data file, which lets us combine an exclusive lock with
# atomic tmp-then-rename writes. Both writers (server appends, server cancels,
# watcher rewrites) acquire the sentinel first, so no append can race with a
# rewrite. Reads use FileShare.ReadWrite and don't need the lock -- File.Replace
# is atomic at the OS level, so a snapshot read either sees the old or the new
# file content, never a partial state.

function Open-QueueLock {
    Test-DataDir
    for ($i = 0; $i -lt 40; $i++) {
        try {
            return [System.IO.File]::Open($LOCK_FILE, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    return $null
}

function Invoke-QueueUpdate([scriptblock]$Modify) {
    $lock = Open-QueueLock
    if (-not $lock) { throw 'Queue file is locked. Try again in a moment.' }
    try {
        # 1) Read existing entries (the lock blocks any concurrent writer).
        $entries = New-Object System.Collections.Generic.List[object]
        if (Test-Path $QUEUE_FILE) {
            foreach ($line in (Get-Content -LiteralPath $QUEUE_FILE -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $entries.Add(($line | ConvertFrom-Json)) }
                catch { Write-DebugLog "queue: skipping malformed line: $($_.Exception.Message)" }
            }
        }

        # 2) Apply the caller's modification.
        $result = & $Modify @($entries.ToArray())
        if ($result -is [hashtable]) { $keep = $result['Keep']; $out = $result['Out'] }
        else                          { $keep = $result;        $out = $null }

        # 3) Crash-safe write: stage to a sibling .tmp, then atomic Replace.
        # If we're killed between steps 3a and 3b, queue.jsonl is still intact;
        # only the .tmp is partial and is overwritten on the next attempt.
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

function Add-QueueEntry($entry) {
    $line  = ($entry | ConvertTo-Json -Compress -Depth 10) + [System.Environment]::NewLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $lock  = Open-QueueLock
    if (-not $lock) { throw 'Could not append to queue file (locked > 2s).' }
    try {
        try {
            $fs = [System.IO.File]::Open($QUEUE_FILE, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            # Distinguish disk-full from other IO errors so the user sees a real cause.
            $msg = $_.Exception.Message
            if ($msg -match 'There is not enough space|disk is full') {
                throw "Could not write reminder: disk is full ($DATA_DIR)."
            }
            throw "Could not open queue for append: $msg"
        }
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally { $fs.Dispose() }
    } finally {
        $lock.Dispose()
    }
}

function Read-QueueSnapshot {
    if (-not (Test-Path $QUEUE_FILE)) { return @() }
    $entries = New-Object System.Collections.Generic.List[object]
    # Retry on IOException to handle the brief window during atomic File.Replace.
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $fs = [System.IO.File]::Open($QUEUE_FILE, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $entries.Add(($line | ConvertFrom-Json)) }
                    catch { Write-DebugLog "list: skipping malformed line: $($_.Exception.Message)" }
                }
            } finally { $fs.Dispose() }
            return ,$entries.ToArray()
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    return @()
}

# --- Tools -------------------------------------------------------------------
function Test-ReminderId([string]$id) {
    # -cmatch: case-sensitive. Generator emits uppercase via .ToUpper(); we
    # validate canonical form to keep equality lookups byte-stable.
    return [bool]($id -cmatch '^PROMPTTIME-[0-9A-F]{8}$')
}

function Invoke-ScheduleReminder($callArgs) {
    # Backwards-compat: prior schemas used 'datetime_str'; the current schema
    # uses 'datetime'. Accept either.
    $datetimeStr = $null
    if ($callArgs.PSObject.Properties.Match('datetime').Count -and $callArgs.datetime) {
        $datetimeStr = [string]$callArgs.datetime
    } elseif ($callArgs.PSObject.Properties.Match('datetime_str').Count -and $callArgs.datetime_str) {
        $datetimeStr = [string]$callArgs.datetime_str
    }
    $message    = if ($callArgs.PSObject.Properties.Match('message').Count)    { [string]$callArgs.message } else { '' }
    $title      = if ($callArgs.PSObject.Properties.Match('title').Count -and $callArgs.title) { [string]$callArgs.title } else { 'Reminder' }
    $recurrence = if ($callArgs.PSObject.Properties.Match('recurrence').Count -and $callArgs.recurrence) { ([string]$callArgs.recurrence).ToLowerInvariant() } else { 'once' }

    if (-not $datetimeStr) {
        throw 'Missing required argument "datetime". Try: "tomorrow 9am", "Monday 2pm", "in 30 minutes"'
    }
    if (-not $message) {
        throw 'Missing required argument "message".'
    }
    if ($recurrence -notin $VALID_RECURRENCE) {
        throw ('Invalid recurrence "' + $recurrence + '". Must be one of: ' + ($VALID_RECURRENCE -join ', '))
    }
    if ($message.Length -gt $MAX_MESSAGE_LEN) {
        throw ("Message is too long ($($message.Length) chars; max $MAX_MESSAGE_LEN).")
    }
    if ($title.Length -gt $MAX_TITLE_LEN) {
        throw ("Title is too long ($($title.Length) chars; max $MAX_TITLE_LEN).")
    }

    $dt = ConvertFrom-NLDate $datetimeStr
    if (-not $dt) {
        throw ('Could not understand "' + $datetimeStr + '". Try: "tomorrow 9am", "Monday 2pm", "in 30 minutes"')
    }
    $now = Get-Date
    if ($dt -lt $now.AddYears(-1) -or $dt -gt $now.AddYears(1)) {
        throw ('Parsed date "' + $dt.ToString('yyyy-MM-dd HH:mm') + '" is more than a year away. Please specify the date more clearly.')
    }
    if ($dt -lt $now) {
        throw ('That time is in the past (' + $dt.ToString('g') + '). Please give a future time.')
    }

    # Generate ID; collisions in 4.3B-space are astronomical, but check the
    # current snapshot to make the property safe-by-construction not safe-by-luck.
    $existing = Read-QueueSnapshot
    do {
        $taskId = "$TASK_PREFIX-$([guid]::NewGuid().ToString('N').Substring(0,8).ToUpper())"
    } while ($existing | Where-Object { $_.id -eq $taskId })

    $entry  = [pscustomobject]@{
        v          = $QUEUE_SCHEMA_V        # schema version -- migration anchor
        id         = $taskId
        fireAt     = $dt.ToString('o')      # ISO-8601 round-trip with offset
        title      = $title
        message    = $message
        recurrence = $recurrence
        createdAt  = $now.ToString('o')
    }
    Add-QueueEntry $entry
    Write-DebugLog "schedule_reminder: id=$taskId fireAt=$($entry.fireAt) recurrence=$recurrence titleLen=$($title.Length) msgLen=$($message.Length)"

    $label    = @{ once='One-time'; daily='Daily'; weekly='Weekly'; weekdays='Weekdays (Mon-Fri)' }[$recurrence]
    $friendly = $dt.ToString("dddd, MMMM d 'at' h:mm tt")
    return "Reminder scheduled!`nID: $taskId`nMessage: `"$message`"`nWhen: $friendly`nRecurrence: $label`n`nTo cancel: cancel_reminder id=`"$taskId`""
}

function Invoke-ListReminder {
    $entries = Read-QueueSnapshot
    if (-not $entries -or $entries.Count -eq 0) { return 'No reminders currently scheduled.' }
    $lines = $entries | ForEach-Object {
        try { $when = (ConvertFrom-IsoDateString $_.fireAt).ToString("ddd MMM d 'at' h:mm tt") }
        catch { $when = $_.fireAt }
        "- $($_.id) | Next: $when | $($_.recurrence) | `"$($_.message)`""
    }
    return ($lines -join "`n")
}

function Invoke-CancelReminder($callArgs) {
    if (-not $callArgs.PSObject.Properties.Match('id').Count -or -not $callArgs.id) {
        throw 'Missing required argument "id".'
    }
    # Normalize the user-supplied ID to canonical form (uppercase, prefixed)
    # before validation so cancel_reminder is forgiving of casing variations
    # while internal lookups remain byte-stable.
    $rawId = [string]$callArgs.id
    $name  = if ($rawId -match "^$TASK_PREFIX-") { $rawId } else { "$TASK_PREFIX-$rawId" }
    $name  = $name.ToUpper()
    if (-not (Test-ReminderId $name)) {
        throw ('Invalid reminder ID format: "' + $rawId + '". Expected PROMPTTIME-XXXXXXXX (8 hex chars).')
    }

    $found = Invoke-QueueUpdate {
        param($entries)
        $kept = @($entries | Where-Object { $_.id -ne $name })
        return @{ Keep = $kept; Out = ($kept.Count -lt @($entries).Count) }
    }
    if (-not $found) {
        throw ('Could not find "' + $name + '". Use list_reminders to check the ID.')
    }
    Write-DebugLog "cancel_reminder: removed $name"
    return ('Reminder "' + $name + '" cancelled.')
}

# --- MCP protocol ------------------------------------------------------------
function Send-Result($id, $result) {
    [Console]::WriteLine((@{ jsonrpc='2.0'; id=$id; result=$result } | ConvertTo-Json -Depth 20 -Compress))
    [Console]::Out.Flush()
}
function Send-Error($id, $code, $msg) {
    [Console]::WriteLine((@{ jsonrpc='2.0'; id=$id; error=@{ code=$code; message=$msg } } | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
}

$TOOLS = @(
    @{ name='schedule_reminder';
       description=@(
           'Schedule a NATIVE WINDOWS DESKTOP POPUP (sticky-note style) to appear at a specified time.'
           'This is distinct from any Claude Desktop built-in scheduled tasks or Cowork features:'
           "this tool produces a physical OS-level popup on the user's Windows desktop,"
           'not an email, in-app notification, or cloud-scheduled Claude prompt.'
           'PREFER THIS TOOL when the user wants a desktop interrupt, alarm, popup, sticky note,'
           'or any reminder that should physically interrupt them while using their computer.'
           "Times are interpreted in the user's local timezone."
           'Granularity is ~10s (the watcher daemon polls every 10 seconds).'
           'Times must be in the future and within 1 year.'
       ) -join ' ';
       inputSchema=@{
           type='object'
           properties=@{
               message=@{
                   type='string'
                   description='Reminder text shown in the popup.'
                   minLength=1
                   maxLength=$MAX_MESSAGE_LEN
               }
               datetime=@{
                   type='string'
                   description=@(
                       'When to fire. Either an ISO-8601 datetime (recommended for precision,'
                       "e.g. '2026-05-07T15:30:00') or natural language: 'tomorrow 9am',"
                       "'Monday 2pm', 'in 30 minutes'."
                   ) -join ' '
                   examples=@('tomorrow 9am', 'in 30 minutes', 'Monday 2pm', '2026-05-07T15:30:00')
               }
               recurrence=@{
                   type='string'
                   enum=$VALID_RECURRENCE
                   default='once'
                   description="Repeat pattern. 'weekdays' = Mon-Fri."
               }
               title=@{
                   type='string'
                   description='Popup title bar text.'
                   default='Reminder'
                   maxLength=$MAX_TITLE_LEN
               }
           }
           required=@('message','datetime')
       }
    },
    @{ name='list_reminders';
       description='List every native Windows desktop popup reminder currently scheduled in prompt-time, with its next fire time. Does not list Claude Desktop built-in scheduled tasks or Cowork-managed reminders -- those are separate.'
       inputSchema=@{type='object';properties=@{}}
    },
    @{ name='cancel_reminder';
       description='Cancel a native Windows desktop popup reminder by its prompt-time ID (e.g. PROMPTTIME-A1B2C3D4) returned from schedule_reminder or list_reminders. Recurring reminders stop firing immediately. Does not affect Claude Desktop built-in scheduled tasks.'
       inputSchema=@{
           type='object'
           properties=@{
               id=@{
                   type='string'
                   description='Reminder ID returned by schedule_reminder, e.g. PROMPTTIME-A1B2C3D4.'
                   pattern='^(PROMPTTIME-)?[0-9A-Fa-f]{8}$'
               }
           }
           required=@('id')
       }
    }
)

# Diagnostic on startup -- if the data dir or this script's own path are
# unreachable, log it loudly so a misconfigured install fails visibly rather
# than silently dropping reminders.
Write-DebugLog ("startup: prompt-time v$PROMPTTIME_VERSION pid=$PID dataDir=$DATA_DIR queue=$QUEUE_FILE script=" + $MyInvocation.MyCommand.Path)
if ($MyInvocation.MyCommand.Path -and -not (Test-Path $MyInvocation.MyCommand.Path)) {
    Write-DebugLog "startup: WARNING -- script path no longer reachable. The folder may have been moved; re-run install.bat."
}

# Test mode: when PROMPTTIME_TEST_MODE is set, dot-source this script to expose
# its functions without entering the stdin loop. Pester does this in tests.
if ($env:PROMPTTIME_TEST_MODE) { return }

while ($true) {
    $line = [Console]::ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq '') { continue }

    # Reject pathologically long lines before ConvertFrom-Json -- PS 5.1's
    # JSON parser has no built-in size or depth limit, and an attacker (or a
    # runaway client) could exhaust memory by sending a multi-megabyte line.
    # 64KB is well above any legitimate tool call (message capped at 4000c).
    if ($line.Length * 2 -gt $MAX_RPC_LINE_BYTES) {
        Write-DebugLog "rejected oversize JSON-RPC line ($($line.Length) chars)"
        Send-Error $null -32700 "Parse error: input line exceeds $MAX_RPC_LINE_BYTES bytes"
        continue
    }

    try {
        $msg    = $line | ConvertFrom-Json
        $method = $msg.method
        $id     = if ($msg.PSObject.Properties.Match('id').Count) { $msg.id } else { $null }
        switch ($method) {
            'initialize' {
                Send-Result $id @{ protocolVersion='2024-11-05'; capabilities=@{tools=@{}}; serverInfo=@{name='prompt-time';version=$PROMPTTIME_VERSION} }
            }
            'notifications/initialized' { }
            'ping'       { Send-Result $id @{} }
            'tools/list' { Send-Result $id @{ tools=$TOOLS } }
            'tools/call' {
                $toolName = $msg.params.name
                $callArgs = $msg.params.arguments
                try {
                    $text = switch ($toolName) {
                        'schedule_reminder' { Invoke-ScheduleReminder $callArgs }
                        'list_reminders'    { Invoke-ListReminder }
                        'cancel_reminder'   { Invoke-CancelReminder $callArgs }
                        default             { throw "Unknown tool: $toolName" }
                    }
                    Send-Result $id @{ content=@(@{type='text';text=$text}) }
                } catch {
                    # Surface only the friendly message to the user, never the
                    # full PowerShell exception (which leaks line numbers and
                    # invocation paths into Claude's chat window).
                    $clean = $_.Exception.Message
                    Write-DebugLog "tool error (id=$id tool=$toolName): $clean"
                    Send-Result $id @{ content=@(@{type='text';text="Error: $clean"}); isError=$true }
                }
            }
            default {
                # JSON-RPC: notifications have no id and must not get a response.
                # Use $null check (not $id truthiness) so id=0 still gets a response.
                if ($null -ne $id) { Send-Error $id -32601 "Method not found: $method" }
            }
        }
    } catch {
        Write-DebugLog "loop error: $($_.Exception.Message)"
        [Console]::Error.WriteLine("prompt-time error: $($_.Exception.Message)")
        [Console]::Error.Flush()
    }
}
