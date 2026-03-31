# CleanOS Lite

**Windows 11 privacy hardening — local, Office-safe, self-updating.**

Stops Microsoft data harvesting and AI features without touching Office, Outlook, or OneDrive.
Installs a silent Sentry that checks your settings on every login, fetches updated privacy
rules automatically, and repairs any drift caused by Windows Updates.

---

## Install

Open PowerShell **as Administrator** and paste:

```powershell
$s = "$env:TEMP\CleanOS_Lite.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/YourName/cleanos-lite-rules/main/CleanOS_Lite.ps1" -OutFile $s
powershell -ExecutionPolicy Bypass -File $s
```

That's it. The script:
1. Downloads itself to a temp file
2. Copies to `C:\ProgramData\CleanOS\CleanOS_Lite.ps1`
3. Creates a **CleanOS Lite** shortcut on your Desktop
4. Installs the Sentry scheduled task (runs silently on every login)
5. Opens the menu — run option 1 to harden your system

---

## What it does

| Area | Action |
|------|--------|
| Telemetry services | Disabled and deadlocked (cannot self-restart) |
| AI / Recall / Copilot / Cortana | Blocked via policy keys |
| Activity History | Disabled |
| Advertising ID | Disabled |
| Delivery Optimization | P2P sharing off |
| Error Reporting | Disabled |
| Lock screen Spotlight | Disabled |
| Edge telemetry | Disabled |
| Print spooler telemetry | Disabled |
| LLMNR / WPAD / NetBIOS | Hardened |
| Windows feature updates | Deferred 30 days (security patches unaffected) |
| Bloatware | Removed (23 apps) |
| Startup entries | Cleaned |

## What it does NOT touch

- Office, Outlook, OneDrive, Teams (enterprise), OneNote, Mail, Calendar
- DNS servers (your existing DNS / VPN / corporate resolver is unchanged)
- Windows Defender (left fully active)
- BingWeather, Photos, Camera

---

## How the Sentry works

On every login (silently, in under 1 second):

1. Fetches the latest `ruleset.json` from this repo
2. If a new script version is available, downloads and installs it automatically
3. Checks if a Windows Update ran since last scan — if so runs a full repair pass
4. Verifies the hosts file hasn't been modified — re-injects sinkhole if needed
5. Applies all registry rules from the ruleset
6. Sends you a desktop toast — green if all clear, yellow if something was fixed

---

## Files in this repo

| File | Purpose |
|------|---------|
| `CleanOS_Lite.ps1` | The script — auto-deployed to all installs when updated |
| `ruleset.json` | Privacy rules — checked every login |
| `version.json` | Version manifest — tells installs when to pull a new script |
| `README.md` | This file |

---

## Keeping it current

**To push new privacy rules** (new telemetry endpoints, AI keys, etc.):
1. Edit `ruleset.json` — add entries to `registry`, `hosts`, or `tasks`
2. Bump the `version` date (e.g. `"2026.04.15"`)
3. Commit — every install picks it up on the next login

**To push a new script version**:
1. Update `CleanOS_Lite.ps1`
2. Bump `$Version` inside the script (e.g. `"1.4.0"`)
3. Update `version.json` — set `scriptVersion` to match
4. Commit both files — Sentry installs the new script on the next login of each machine

---

## Restore

Open **CleanOS Lite** from your Desktop shortcut → option **3. Restore & Uninstall**.
Restores registry, hosts file, and service startup types from the Safety Vault created
on first run. All CleanOS data is permanently deleted.
