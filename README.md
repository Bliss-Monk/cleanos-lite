   █████████  ████                                   ███████     █████████
  ███░░░░░███░░███                                 ███░░░░░███  ███░░░░░███
 ███     ░░░  ░███   ██████   ██████   ████████   ███     ░░███░███    ░░░ 
░███          ░███  ███░░███ ░░░░░███ ░░███░░███ ░███      ░███░░█████████ 
░███          ░███ ░███████   ███████  ░███ ░███ ░███      ░███ ░░░░░░░░███
░░███     ███ ░███ ░███░░░   ███░░███  ░███ ░███ ░░███     ███  ███    ░███
 ░░█████████  █████░░██████ ░░████████ ████ █████ ░░░███████░  ░░█████████ 
  ░░░░░░░░░  ░░░░░  ░░░░░░   ░░░░░░░░ ░░░░ ░░░░░    ░░░░░░░     ░░░░░░░░░  
                 Your hardware. Your data. Your choice.

CleanOS Lite is a fully local, self-updating privacy hardening tool for Windows 11 laptops.
No external DNS required. Safe for Office and Outlook. The Sentry checks on every login,
detects Windows Updates, heals any drift automatically, and stays current by downloading
an updated ruleset from a hosted JSON file — without ever needing the script to be redeployed.

How the living Sentry works:
  1. On every login it fetches ruleset.json from your GitHub repository.
  2. If the remote ruleset is newer than the cached copy it saves the update locally.
  3. It checks if a Windows Update ran since the last scan — if so it runs a full
     all-phases cleanup pass to catch re-provisioned apps and restored services.
  4. It verifies the hosts file hasn't been modified — if it has it re-injects the
     telemetry sinkhole automatically.
  5. It applies every registry, hosts, and scheduled task rule from the ruleset.
  6. It sends you a toast — green if everything is clean, yellow if it fixed something.
  7. If there's no internet it falls back to the locally cached ruleset.
     If there's no cache it falls back to a baked-in baseline inside the script.

What it does:
  - Kills all telemetry services and deadlocks them
  - Blocks known telemetry endpoints at the hosts file level
  - Disables AI features (Recall, Copilot, Cortana) via policy keys
  - Hardens LLMNR, WPAD, NetBIOS
  - Disables lock screen Spotlight, Fast Startup, Edge and print spooler telemetry
  - Defers Windows feature updates 30 days (security patches still auto-install)
  - Cleans startup entries and removes Edge background processes
  - Optional: applies High Performance power plan on plugged-in laptops
  - Optional: runs disk cleanup (DISM + cleanmgr) on request
  - Self-updating Sentry: fetches new telemetry rules on every login

What it does NOT do:
  - Change DNS servers
  - Enforce DoH
  - Remove OneDrive, OneNote, Mail, Calendar, BingWeather, Photos, Camera
  - Disable CDPSvc / OneSyncSvc (Outlook sync)

CHANGELOG:

v1.2.0 (March 2026):
  - ADDED: Remote ruleset (ruleset.json on GitHub) — Sentry stays current without
           redeploying the script. Edit the JSON to push new coverage to all machines.
  - ADDED: Local ruleset cache with offline fallback — works with no internet.
  - ADDED: Windows Update detection — triggers a full cleanup pass after any update.
  - ADDED: Hosts file hash integrity check — auto-remediates if hosts was modified.
  - ADDED: Ruleset version logged on every Sentry login for audit trail.
  - ADDED: Windows Update deferral — feature updates deferred 30 days; security
           patches still install immediately.
  - ADDED: Startup optimisation — removes Edge and Teams background processes.
  - ADDED: Power plan prompt — applies High Performance if laptop is mostly plugged in.
  - ADDED: Phase 6 disk cleanup — DISM image cleanup + cleanmgr on request.

v1.1.0 (March 2026):
  - ADDED: Post-run advisory, clean login toast, HiberbootEnabled, Lock Screen,
           Diagnostic Data Viewer, Cortana, Print Spooler, Edge telemetry,
           Already Optimized explanation.

v1.0.0 (March 2026):
  - Initial release.
