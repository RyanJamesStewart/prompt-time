# prompt-time

[![CI](https://github.com/RyanJamesStewart/prompt-time/actions/workflows/ci.yml/badge.svg)](https://github.com/RyanJamesStewart/prompt-time/actions/workflows/ci.yml)

**Schedule Windows desktop reminders directly from Claude Desktop.** Zero dependencies — just PowerShell + Windows Task Scheduler.

## What it does

Adds three tools to Claude Desktop:

| Tool | What it does |
|---|---|
| `schedule_reminder` | Set a one-time or recurring desktop reminder |
| `list_reminders`    | Show every reminder currently scheduled |
| `cancel_reminder`   | Cancel a reminder by ID |

Reminders persist across reboots and Claude restarts. There is no cloud surface — everything runs locally.

## Install in 60 seconds

1. Download `prompt-time-v2.2.0.zip` from the [latest release](https://github.com/RyanJamesStewart/prompt-time/releases/latest).
2. **Right-click the zip → Extract All.** Windows must extract — running `install.bat` from inside the zip preview window will not work.
3. Open the extracted folder, double-click **`install.bat`**.
4. Done. Claude Desktop restarts automatically and the tools are live.

No Node, no npm, no admin rights, no internet required.

## Usage examples

Just talk to Claude:

> "Remind me to send the weekly update at 4pm today"
> "Set a reminder every weekday at 9am to check my inbox"
> "Remind me about the board call next Monday at 2pm"
> "What reminders do I have set?"
> "Cancel reminder PROMPTTIME-A1B2C3D4"

Recurrence: `once`, `daily`, `weekly`, `weekdays`. Granularity is ~10 seconds (the watcher's poll interval).

## How it works

Two pieces:

1. **MCP server** (`prompt_time.ps1`) — runs inside Claude Desktop's process tree. Validates and enqueues reminders to a JSONL file on disk.
2. **Watcher daemon** (`prompt-time-watcher.ps1`) — registered once at install as a Task Scheduler `At LogOn` task. Polls the queue, renders the toast popup in-process, and advances recurring entries.

The MCP server never talks to Task Scheduler at runtime, never spawns a process, and never displays UI. It only writes one JSONL line per reminder. Everything else is the watcher's job.

### Why two processes — the MSIX boundary

Claude Desktop ships as an [MSIX-packaged app](https://learn.microsoft.com/en-us/windows/msix/). MSIX containers transparently virtualize file writes: a server running inside the package that calls `Add-Content $env:APPDATA\prompt-time\queue.jsonl` does not write to `%APPDATA%\Roaming\prompt-time\queue.jsonl` — it writes to a per-package shadow tree under `%LOCALAPPDATA%\Packages\<package-family>\LocalCache\…`.

Anything Task Scheduler spawns runs *outside* the package, so a per-reminder `schtasks` task would look for files at the real path and find nothing.

prompt-time resolves this once: at startup, every component (`prompt_time.ps1`, `prompt-time-watcher.ps1`, `install.ps1`, `uninstall.ps1`) discovers the Claude AppX package and computes the same canonical data directory inside its `LocalCache`. Server writes and watcher reads land at the same physical file. The watcher renders the popup itself rather than asking Task Scheduler to do it, which keeps every state-bearing operation on the same side of the boundary.

The installer also pre-creates the queue file at the canonical path before the MCP server's first write — without that, MSIX file-virtualization redirects new file creation into the package shadow even though existing files at the real path are written through.

## Troubleshooting

**Notifications muted by Focus Assist.** Windows Focus Assist (Settings → System → Focus) silences toasts. Either turn it off or add `powershell.exe` to the Priority list.

**Tools don't appear in Claude Desktop.**
1. Fully quit Claude Desktop (right-click tray icon → Quit) and reopen it.
2. Confirm `prompt-time` is in `%APPDATA%\Claude\claude_desktop_config.json` under `mcpServers`.
3. Confirm the path in that entry still points to `prompt_time.ps1`. Moving the folder after install breaks it — re-run `install.bat` from the new location.

**`install.bat` closes immediately.** Run it from a `cmd` prompt instead so you can read the error: `install.bat` from inside the unzipped folder. The installer also writes a debug log at `%APPDATA%\prompt-time\prompt-time.debug.log` (or the MSIX `LocalCache` equivalent) — check there.

**Reminders not firing.** Check the watcher task is running:

```powershell
Get-ScheduledTask -TaskName PROMPTTIME-Watcher | Get-ScheduledTaskInfo
```

`LastTaskResult` should be `267009` (running) or `0` (success).

## Uninstall

Double-click **`uninstall.bat`**. It removes the prompt-time entry from Claude Desktop's config, deletes the `PROMPTTIME-Watcher` scheduled task, and clears the data directory. Other MCP servers in your config are untouched.

## Tests

```powershell
.\tests\run.ps1
```

Installs Pester 5 if missing, runs the Pester suite, and emits NUnit XML at `tests/pester-results.xml`. CI runs the same harness plus `Invoke-ScriptAnalyzer` on every push.

## Security

See [SECURITY.md](SECURITY.md) for the trust model, supply-chain story, and how to report a vulnerability. Short version: the trust boundary is your local Windows user; reminder titles and messages are stored on disk in cleartext (don't put secrets in them); prompt-time registers a logon-time scheduled task as a standard persistence primitive.

## License

MIT — see [LICENSE](LICENSE).

---

Built by Ryan Stewart
