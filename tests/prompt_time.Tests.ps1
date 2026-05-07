# Pester tests for prompt_time.ps1.
# Run via tests/run.ps1 (which installs Pester 5 if missing) or:
#   Invoke-Pester -Path tests/prompt_time.Tests.ps1
#
# Tests dot-source the server script with $env:PROMPTTIME_TEST_MODE=1 so its
# stdin loop doesn't run, and with $env:PROMPTTIME_DATA_DIR pointed at a
# per-test temp directory so we never touch real user state.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ServerPath = Join-Path $script:RepoRoot 'prompt_time.ps1'
    $script:TempDir    = Join-Path ([System.IO.Path]::GetTempPath()) "prompt-time-test-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    $env:PROMPTTIME_DATA_DIR  = $script:TempDir
    $env:PROMPTTIME_TEST_MODE = '1'
    . $script:ServerPath
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:PROMPTTIME_DATA_DIR  = $null
    $env:PROMPTTIME_TEST_MODE = $null
}

Describe 'ConvertFrom-NLDate' {
    It 'parses "in 30 minutes" within ~1s of expected' {
        $r = ConvertFrom-NLDate 'in 30 minutes'
        $r | Should -BeOfType ([datetime])
        $delta = ($r - (Get-Date).AddMinutes(30)).TotalSeconds
        [math]::Abs($delta) | Should -BeLessThan 2
    }

    It 'parses "tomorrow 9am"' {
        $r = ConvertFrom-NLDate 'tomorrow 9am'
        $r.Hour | Should -Be 9
        $r.Minute | Should -Be 0
        $r.Date | Should -Be (Get-Date).Date.AddDays(1)
    }

    It 'parses ISO-8601 with offset' {
        $r = ConvertFrom-NLDate '2026-12-25T15:30:00-08:00'
        $r.Year  | Should -Be 2026
        $r.Month | Should -Be 12
        $r.Day   | Should -Be 25
    }

    It 'returns null on garbage' {
        ConvertFrom-NLDate 'asdf' | Should -BeNullOrEmpty
    }

    It 'returns null on too-short input (no bare-number ambiguity)' {
        ConvertFrom-NLDate '5' | Should -BeNullOrEmpty
    }

    It 'rejects "in 999999999999 minutes" with a friendly error' {
        { ConvertFrom-NLDate 'in 999999999999 minutes' } | Should -Throw '*Number too large*'
    }
}

Describe 'Test-ReminderId' {
    It 'accepts canonical hex IDs'           { Test-ReminderId 'PROMPTTIME-A1B2C3D4'         | Should -BeTrue  }
    It 'rejects lowercase hex'               { Test-ReminderId 'PROMPTTIME-a1b2c3d4'         | Should -BeFalse }
    It 'rejects too short'                   { Test-ReminderId 'PROMPTTIME-A1B2C3D'          | Should -BeFalse }
    It 'rejects too long'                    { Test-ReminderId 'PROMPTTIME-A1B2C3D4E'        | Should -BeFalse }
    It 'rejects non-hex chars'               { Test-ReminderId 'PROMPTTIME-XXXXXXXX'         | Should -BeFalse }
    It 'rejects missing prefix'              { Test-ReminderId 'A1B2C3D4'                    | Should -BeFalse }
    It 'rejects SQL-injection-shaped string' { Test-ReminderId "PROMPTTIME-A1B2C3D4'; DROP--" | Should -BeFalse }
}

Describe 'Queue: Add-QueueEntry + Read-QueueSnapshot round-trip' {
    BeforeEach {
        $q = Join-Path $script:TempDir 'queue.jsonl'
        $l = Join-Path $script:TempDir 'queue.lock'
        if (Test-Path $q) { Remove-Item $q -Force }
        if (Test-Path $l) { Remove-Item $l -Force }
        Set-Content -Path $q -Value '' -Encoding UTF8
    }

    It 'appends one entry and reads it back' {
        $entry = [pscustomobject]@{
            v          = 1
            id         = 'PROMPTTIME-AAAAAAAA'
            fireAt     = (Get-Date).AddMinutes(60).ToString('o')
            title      = 't'
            message    = 'm'
            recurrence = 'once'
            createdAt  = (Get-Date).ToString('o')
        }
        Add-QueueEntry $entry
        $snap = Read-QueueSnapshot
        @($snap).Count | Should -Be 1
        $snap[0].id | Should -Be 'PROMPTTIME-AAAAAAAA'
        $snap[0].message | Should -Be 'm'
    }

    It 'preserves quotes/backticks/dollar-paren in title and message verbatim' {
        # The popup-spawn fix means user content reaches the popup as env vars,
        # never interpolated as code. Verify the queue itself preserves bytes.
        $tricky = "don't ` $(get-date) ; calc"
        $entry = [pscustomobject]@{
            v=1; id='PROMPTTIME-BBBBBBBB'
            fireAt=(Get-Date).AddMinutes(1).ToString('o')
            title=$tricky; message=$tricky
            recurrence='once'; createdAt=(Get-Date).ToString('o')
        }
        Add-QueueEntry $entry
        $snap = Read-QueueSnapshot
        $snap[0].title   | Should -Be $tricky
        $snap[0].message | Should -Be $tricky
    }
}

Describe 'Queue: Invoke-QueueUpdate atomicity' {
    BeforeEach {
        $q = Join-Path $script:TempDir 'queue.jsonl'
        $l = Join-Path $script:TempDir 'queue.lock'
        if (Test-Path $q) { Remove-Item $q -Force }
        if (Test-Path $l) { Remove-Item $l -Force }
        Set-Content -Path $q -Value '' -Encoding UTF8
    }

    It 'keeps requested entries and drops the rest' {
        Add-QueueEntry @{ v=1; id='PROMPTTIME-11111111'; fireAt='2099-01-01T00:00:00'; title='a'; message='1'; recurrence='once'; createdAt=(Get-Date).ToString('o') }
        Add-QueueEntry @{ v=1; id='PROMPTTIME-22222222'; fireAt='2099-01-02T00:00:00'; title='b'; message='2'; recurrence='once'; createdAt=(Get-Date).ToString('o') }
        Add-QueueEntry @{ v=1; id='PROMPTTIME-33333333'; fireAt='2099-01-03T00:00:00'; title='c'; message='3'; recurrence='once'; createdAt=(Get-Date).ToString('o') }

        $kept = Invoke-QueueUpdate {
            param($entries)
            return @{ Keep = ($entries | Where-Object { $_.id -ne 'PROMPTTIME-22222222' }); Out = 'dropped one' }
        }

        $kept | Should -Be 'dropped one'
        $snap = Read-QueueSnapshot
        @($snap).Count | Should -Be 2
        ($snap.id) | Should -Not -Contain 'PROMPTTIME-22222222'
    }

    It 'leaves no orphan .tmp file on success' {
        Add-QueueEntry @{ v=1; id='PROMPTTIME-44444444'; fireAt='2099-01-04T00:00:00'; title='x'; message='x'; recurrence='once'; createdAt=(Get-Date).ToString('o') }
        Invoke-QueueUpdate { param($entries) return $entries } | Out-Null
        $tmp = Join-Path $script:TempDir 'queue.jsonl.tmp'
        Test-Path $tmp | Should -BeFalse
    }
}

Describe 'Queue: concurrent appends do not race' {
    BeforeEach {
        $q = Join-Path $script:TempDir 'queue.jsonl'
        $l = Join-Path $script:TempDir 'queue.lock'
        if (Test-Path $q) { Remove-Item $q -Force }
        if (Test-Path $l) { Remove-Item $l -Force }
        Set-Content -Path $q -Value '' -Encoding UTF8
    }

    It '4 jobs x 10 appends each = 40 entries, no losses' {
        # Capture into local-scoped variables so $using: can resolve them
        # in each Start-Job ScriptBlock. Using $using: instead of
        # `-ArgumentList` + `param()` is the pattern PSScriptAnalyzer
        # recommends for cross-runspace variable access.
        $serverPath = $script:ServerPath
        $tempDir    = $script:TempDir
        $jobs = 1..4 | ForEach-Object {
            $jobNum = $_
            Start-Job -ScriptBlock {
                $env:PROMPTTIME_DATA_DIR  = $using:tempDir
                $env:PROMPTTIME_TEST_MODE = '1'
                . $using:serverPath
                $jn = $using:jobNum
                for ($i = 1; $i -le 10; $i++) {
                    $entry = @{
                        v          = 1
                        id         = ("PROMPTTIME-J{0:D2}{1:D6}" -f $jn, $i)
                        fireAt     = (Get-Date).AddMinutes(60).ToString('o')
                        title      = "j$jn"
                        message    = "msg-$i"
                        recurrence = 'once'
                        createdAt  = (Get-Date).ToString('o')
                    }
                    Add-QueueEntry $entry
                }
            }
        }
        $jobs | Wait-Job -Timeout 60 | Out-Null
        $jobs | Receive-Job -ErrorAction SilentlyContinue | Out-Null
        $jobs | Remove-Job -Force

        $snap = Read-QueueSnapshot
        @($snap).Count | Should -Be 40
    }
}
