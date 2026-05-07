# Security policy — prompt-time

This document explains what prompt-time protects against, what it doesn't, and how to report a vulnerability. It applies to every file in this repository.

## Trust model

prompt-time runs entirely on a single Windows machine in the context of a single Windows user. There is no network listener, no remote API, no telemetry, no auto-update.

The trust boundary is **the local user account.** Anything that already runs as the same user can:

- Read every reminder title and message body in `queue.jsonl` and the debug log.
- Modify `prompt-time-watcher.ps1` in the data directory, which the watcher executes at every logon.
- Submit arbitrary JSON-RPC to the running MCP server's stdin (via Claude Desktop, but also via direct injection if the user is compromised).

prompt-time does **not** attempt to defend against malware running as the same user. It defends against:

- Bad input from a tool call (whether from a user prompt, an LLM hallucination, or a malicious prompt-injection payload). Tool arguments are validated server-side: title/message length caps, recurrence enum whitelist, ID format regex, datetime sanity bounds.
- Code execution via popup rendering. Reminder titles and messages reach the popup process as **environment variables**, never interpolated into a PowerShell script body, so quote characters / `$()` / backticks / newlines in a reminder cannot break out into code at fire time.
- Concurrent corruption of the queue file. All writes are serialized through an exclusive sentinel lock and committed atomically (tmp file + `File.Replace`) so a crash mid-write cannot leave the queue empty or partial.
- Greedy uninstall that nukes unrelated tasks. prompt-time identifies its own scheduled tasks by action-path (the script that runs) rather than name prefix.

## Reminder content is stored cleartext

`queue.jsonl` contains the title and body of every pending reminder in plaintext on disk. The debug log records reminder IDs, lengths, and timing — never bodies — but the queue itself is the source of truth and is not encrypted.

**Do not put secrets in reminder messages.** Treat reminder bodies the way you would a sticky note on your desk: useful prose, never a 2FA code or password.

## Persistence surface

prompt-time registers one Windows scheduled task (`PROMPTTIME-Watcher`) that runs `prompt-time-watcher.ps1` from `%APPDATA%\prompt-time\` (or the MSIX equivalent) at every logon. This is a standard Windows startup hook. EDR products may flag scheduled-task creation; that is expected behavior.

If you do not trust the watcher script, do not install. If you have already installed and want it gone, run `uninstall.bat` — it removes the task, the data directory (which contains the watcher copy), and the prompt-time entry from `claude_desktop_config.json` while preserving any other MCP servers you have configured.

## Supply chain

This repo is distributed as raw PowerShell scripts under MIT license. There is no signed installer and no published release artifact at this time. Verify what you run:

1. `git clone` from the canonical repository, or download a tagged release zip.
2. Compare the SHA-256 of `prompt_time.ps1`, `prompt-time-watcher.ps1`, `install.ps1`, and `uninstall.ps1` against the values published in the release notes.
3. Read the four scripts. They total ~1,300 lines. A coffee's worth of reading is enough to verify there are no surprises.

If you are deploying this to multiple machines (lab, classroom, household), pin a specific commit SHA and host the scripts on a path your users trust.

## Known limitations

- **No file-integrity check on the watcher.** A future version should verify `prompt-time-watcher.ps1` against a hash baseline written at install time, so a same-user attacker who modifies the script can't pivot the persistence into their own code. Tracked.
- **No ACL hardening on the data directory.** Default Windows ACLs grant the owning user full control. On a shared/multi-user machine this is sufficient (other users can't read it); on a single-user machine that's compromised at the user level, see "trust model" above.
- **MSIX package-name lookup is brittle.** If Anthropic ships Claude Desktop under a different package family name in the future, the data-dir discovery falls through to a legacy path and reminders silently stop working. Re-running `install.bat` re-binds it.

## Reporting a vulnerability

Email the maintainer (see [README](README.md) for contact). Do not open a public issue for security reports until a fix is available. Expected response time: 72 hours for acknowledgement.
