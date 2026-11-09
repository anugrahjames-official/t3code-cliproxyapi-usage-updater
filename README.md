# T3 Code CLIProxyAPI Hub Usage Updater

An unofficial Windows workaround for displaying pooled **Grok (xAI)** and **Antigravity** account usage in T3 Code's Usage Limits view when those accounts are accessed through CLIProxyAPI.

## Why this exists

In the author's setup, Hub-backed model requests worked through separate harness/provider profiles, but the pooled Hub providers beyond the native Codex and Claude usage paths were absent from T3 Code's Usage Limits report. Model access and usage reporting are separate: a harness can successfully send requests through CLIProxyAPI while T3 has no adapter to query and render the Hub accounts' upstream quota data.

This workaround modifies the installed T3 server bundle to query supported Hub accounts and normalize their quota data into T3's existing usage-window format. It adds local reporting for Grok and Antigravity. It does **not** implement Kimi usage reporting or provide usage data for providers without a usable account-level usage endpoint. The patcher also includes a narrow Antigravity (Hub) model allowlist adjustment used by the reference setup.

## Status and tested environment

- **Tested reference:** Windows 11 x64, T3 Code Nightly `0.1.8-nightly.20261109.4399`.
- **Status:** personal, machine-local workaround; not a feature shipped or supported by T3 Code.
- **Platform:** Windows-specific installer detection, PowerShell, and Task Scheduler controls. macOS/Linux are not implemented or verified.
- **Compatibility:** tied to the structure of the installed T3 bundle. A different T3 version or release channel may not match the patch anchors.

The user found the reporting gap. These files document and share the local workaround; they are not a T3 Code pull request.

## Important risks

This tool edits T3 Code's installed `resources/server.asar`. That is outside the supported application update path and may be overwritten by an update. A malformed or incompatible patch could prevent T3 from starting. The updater uses expected bundle anchors, hash checks, backup/rollback, and defers while T3 is running, but those safeguards do not make the patch officially supported or compatible with future builds.

Review the code and verify the target installation before running it. Keep a recoverable backup. Do not transplant a patched archive between machines, app versions, channels, or operating systems. Scheduled modes create or remove a per-user Windows scheduled task; they are opt-in and can be managed with the scripts below.

The source contains no Hub keys or OAuth credentials. Runtime Hub credentials and account data remain the operator's responsibility. Never publish auth files, tokens, account identifiers, or logs containing them.

## What is included

- `patcher.mjs` — inspects a T3 `server.asar`, checks patch anchors, builds the patched archive, and verifies archive contents.
- `Update-T3HubUsage.ps1` — Windows updater, guarded installation, and hash-checked rollback.
- `Set-T3HubUsageAutoUpdater.ps1` — manage or inspect the optional scheduled updater.
- `Manual-T3HubUsage.vbs` — launch a manual updater check.
- `Enable-Automatic-T3HubUsage.vbs` — enable logon plus periodic checks.
- `Enable-Startup-T3HubUsage.vbs` — enable logon-only checks.
- `Disable-T3HubUsageAutomation.vbs` — remove the updater scheduled task.
- `Scheduled-T3HubUsage.vbs` — hidden task runner used by the scheduled task.
- `fragments/` — Grok and Antigravity adapter and normalized usage fragments inserted by the patcher.

## Requirements

- Windows 11 (the reference environment; other Windows versions are not verified).
- Node.js **22.12.0 or newer** and npm, for the patcher.
- PowerShell 5.1 or newer.
- T3 Code installed with an Electron `resources/server.asar` bundle matching the expected anchors.
- A CLIProxyAPI Hub configured in T3's Usage Limits source, with its management API reachable and provider OAuth accounts available.

Install the sole direct Node dependency from this repository:

```powershell
npm install
```

## Inspect before applying

First identify the exact T3 installation and inspect its bundle. Inspection does not apply the patch:

```powershell
node .\patcher.mjs inspect "C:\path\to\T3 Code\resources\server.asar"
```

The updater script also performs its own checks and normally discovers the installed T3 path. Run it manually only after reviewing the script and the current target build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-T3HubUsage.ps1
```

Reopen T3 Code and confirm the labeled Grok and Antigravity Hub rows show fresh data. If the target is unknown, an anchor is missing, or verification fails, stop; do not force a patch against a new bundle.

## Roll back or manage automation

Rollback is hash-guarded and only restores the backup when the installed archive still matches the updater's expected patched state:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-T3HubUsage.ps1 -Rollback
```

The VBS launchers provide manual, automatic, startup-only, and disable controls. The automatic mode uses a per-user scheduled task and periodically checks for a T3 update so it can reapply the patch when recognized. It does not close T3; if T3 is running, the updater defers.

## Known limitations

- Only the Grok/xAI and Antigravity branches are added by this workaround.
- Kimi is not implemented; generic OpenAI-compatible providers without account-level quota APIs cannot be reported by this adapter.
- Usage data comes from provider-specific upstream endpoints and can change independently of T3 and CLIProxyAPI.
- A pool does not have one shared quota. The visible account rows are per-account snapshots; a pool average cannot predict which account CLIProxyAPI will route to next.
- T3 updates may replace the modified bundle. Future bundle changes may make the updater safely refuse to patch until its anchors are reviewed.
- No automated test suite or compatibility promise is included here.

## Relationship to the T3 Code discussion

This repository is the focused implementation reference for the report that pooled CLIProxyAPI providers accessed through separate harness profiles were missing from T3 Code's Usage Limits report. The discussion should link this repository and the companion setup report. The larger remote-host runbook is not needed to understand this issue.

## Attribution and licensing

The user identified the issue and created the local workaround. This repository was prepared for public review with documentation assistance from DeepSeek V4.1 Flash and GPT-6 Luna. No license is included; do not assume permission to redistribute or reuse the code without the author's permission.
