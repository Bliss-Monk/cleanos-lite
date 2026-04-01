<#
.SYNOPSIS
CleanOS Lite v1.3.0

.DESCRIPTION

TL;DR:
CleanOS Lite is a fully local, self-updating privacy hardening tool for Windows 11 laptops.
No external DNS required. Safe for Office and Outlook. The Sentry runs on every login,
fetches updated privacy rules AND an updated script version from your GitHub repository,
and installs everything automatically — no USB, no manual redeployment ever needed.

Install from GitHub (one command, run as Administrator):
  $s = "$env:TEMP\CleanOS_Lite.ps1"
  Invoke-WebRequest "https://raw.githubusercontent.com/YourName/cleanos-lite-rules/main/CleanOS_Lite.ps1" -OutFile $s
  powershell -ExecutionPolicy Bypass -File $s

How the living Sentry works on every login:
  1. Fetches version.json from GitHub to check if a new script version is available.
  2. If a newer script exists: downloads it, validates it, replaces itself, logs the upgrade.
     The next login runs the new version automatically.
  3. Fetches ruleset.json — saves to local cache if newer than cached copy.
  4. Detects if a Windows Update ran since last scan — if so runs a full cleanup pass.
  5. Verifies the hosts file hash — re-injects sinkhole entries if modified.
  6. Applies all registry, hosts, and task rules from the loaded ruleset.
  7. Sends a toast — green if all clear, yellow if anything was fixed.
  Falls back to cached ruleset if no internet. Falls back to baked-in baseline if no cache.
  You never need to touch installed machines again. Push to GitHub → all machines update.

CHANGELOG:

v1.3.0 (March 2026):
  - ADDED: Script self-update engine — Sentry checks version.json on GitHub and
           downloads + installs a new CleanOS_Lite.ps1 automatically when available.
  - ADDED: GitHub install support — script can be installed with a single
           Invoke-WebRequest command, no USB drive required.
  - ADDED: version.json manifest in repo — separates script versioning from
           ruleset versioning so they can be updated independently.
  - ADDED: Script validation before self-update (checks for version string) to
           prevent a bad download from corrupting the installed script.

v1.2.0 (March 2026):
  - ADDED: Remote ruleset (ruleset.json on GitHub) with local cache and offline fallback.
  - ADDED: Windows Update detection — triggers full cleanup pass after any update.
  - ADDED: Hosts file hash integrity check and auto-remediation.
  - ADDED: Windows Update deferral, startup cleanup, power plan prompt, disk cleanup.

v1.1.0 (March 2026):
  - ADDED: Post-run advisory, clean login toast, HiberbootEnabled, Lock Screen,
           Diagnostic Data Viewer, Cortana, Print Spooler, Edge telemetry,
           Already Optimized explanation.

v1.0.0 (March 2026):
  - Initial release.

.NOTES
Built for: Windows 11 (22H2 - 26H1+)
Version: 1.3.0
Author: Eon Smuts
#>

param(
    [switch]$NoCopy,
    [switch]$AuditorOnly
)

$Version = "1.3.0"

# =============================================================================
# CONFIGURATION
# =============================================================================
$ScriptUrl   = "https://raw.githubusercontent.com/Bliss-Monk/CleanOS-Lite/refs/heads/main/CleanOS_Lite.ps1"
$VersionUrl  = "https://raw.githubusercontent.com/Bliss-Monk/CleanOS-Lite/refs/heads/main/version.json"
$RulesetUrl  = "https://raw.githubusercontent.com/Bliss-Monk/CleanOS-Lite/refs/heads/main/ruleset.json"
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# -----------------------------------------------------------------------------
# 1. ADMIN PRIVILEGES & ENVIRONMENT INITIALIZATION
# -----------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host '⚠ ACTION REQUIRED: Please right-click this script and "Run as Administrator".' -ForegroundColor Red
    pause ; exit
}

$ProgramDataPath   = Join-Path $env:ProgramData 'CleanOS'
$BackupPath        = Join-Path $ProgramDataPath 'Backup'
$LocalScriptPath   = Join-Path $ProgramDataPath 'CleanOS_Lite.ps1'
$LogFile           = Join-Path $ProgramDataPath 'CleanOS_Lite_Activity.log'
$MarkerFile        = Join-Path $BackupPath 'CleanOS-Lite-backup.marker'
$RulesetCacheFile  = Join-Path $ProgramDataPath 'CleanOS_Ruleset.json'
$HostsHashFile     = Join-Path $ProgramDataPath 'CleanOS_HostsHash.txt'
$LastUpdateFile    = Join-Path $ProgramDataPath 'CleanOS_LastUpdate.txt'
$PrefsFile         = Join-Path $ProgramDataPath 'CleanOS_Prefs.xml'
$CurrentScriptPath = $MyInvocation.MyCommand.Path
$HostsPath         = "$env:SystemRoot\System32\drivers\etc\hosts"

foreach ($path in @($ProgramDataPath, $BackupPath)) {
    if (-not (Test-Path $path)) { New-Item $path -ItemType Directory -Force | Out-Null }
}

# -----------------------------------------------------------------------------
# USB / GITHUB DEPLOYMENT & DESKTOP SHORTCUT
# When the script is run from anywhere other than LocalScriptPath (USB, temp
# folder from GitHub download, etc.) it copies itself into ProgramData,
# creates the Desktop shortcut, and relaunches from the permanent location.
# -----------------------------------------------------------------------------
if ($CurrentScriptPath -ne $LocalScriptPath -and -not $NoCopy) {
    Copy-Item $CurrentScriptPath $LocalScriptPath -Force
    try {
        $WshShell              = New-Object -ComObject WScript.Shell
        $Shortcut              = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\CleanOS Lite.lnk")
        $Shortcut.TargetPath   = "powershell.exe"
        $Shortcut.Arguments    = "-ExecutionPolicy Bypass -File `"$LocalScriptPath`" -NoCopy"
        $Shortcut.IconLocation = "powershell.exe,0"
        $Shortcut.Save()
    } catch {}
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$LocalScriptPath`" -NoCopy" -WindowStyle Normal
    exit
}

# -----------------------------------------------------------------------------
# 2. HELPERS (UI, AUDIT & NOTIFICATIONS)
# -----------------------------------------------------------------------------
function Update-Status($Message, $Status = "INFO") {
    if ($AuditorOnly -and $Status -eq "INFO") { return }
    $Color  = switch ($Status) { "SUCCESS" { "Green" }; "ERROR" { "Yellow" }; "SIM" { "Cyan" }; Default { "White" } }
    $Prefix = switch ($Status) { "SUCCESS" { "  [✔]" }; "ERROR" { "  [!]" }; "SIM" { "  [?]" }; Default { "  [•]" } }
    Write-Host "$Prefix $Message" -ForegroundColor $Color
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Status] $Message" | Out-File $LogFile -Append
}

function Show-CleanOSToast($Title, $Message) {
    try {
        $AppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $Template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $RawXml   = [xml]$Template.GetXml()
        $RawXml.SelectSingleNode('//text[@id="1"]').InnerText = $Title
        $RawXml.SelectSingleNode('//text[@id="2"]').InnerText = $Message
        $ToastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $ToastXml.LoadXml($RawXml.OuterXml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($ToastXml)
    } catch {}
}

function Set-RegistrySafe($Path, $Name, $Value, $Type = "DWORD") {
    if ($Global:DryRun) {
        if (Test-Path $Path) {
            $val = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            if ($val -and $val.$Name -eq $Value) { throw "Already Optimized" }
        }
        return
    }
    if (-not (Test-Path $Path)) { New-Item $Path -Force | Out-Null }
    $current = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($current -and $current.$Name -eq $Value) { throw "Already Optimized" }
    try {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        $Account = [System.Security.Principal.NTAccount]"Administrators"
        $ACL     = Get-Acl $Path ; $ACL.SetOwner($Account) ; Set-Acl $Path $ACL
        $Rule    = New-Object System.Security.AccessControl.RegistryAccessRule($Account, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $ACL.SetAccessRule($Rule) ; Set-Acl $Path $ACL
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    }
}

function Disable-AndDeadlock($ServiceName) {
    $Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $Svc) { return $true }
    $props        = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue
    $isDeadlocked = $props.DependOnService -contains "NullSvc"
    if ($Svc.StartType -eq 'Disabled' -and $isDeadlocked) { return $true }
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    Set-Service  $ServiceName -StartupType Disabled
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name "DependOnService" -Value "NullSvc" -Type MultiString
    & sc.exe triggerinfo $ServiceName delete | Out-Null
    return $false
}

function Run-Task($probeName, $successName, [scriptblock]$action) {
    try {
        if ($Global:DryRun) {
            Update-Status "$probeName..." "SIM"
            & $action
            $Global:TasksFound++
        } else {
            & $action
            Update-Status "$successName" "SUCCESS"
        }
    } catch {
        if ($Global:DryRun) { $Global:TasksBlocked++ }
        else { Update-Status "Skipped $probeName (Already Optimized)" "INFO" }
    }
}

# -----------------------------------------------------------------------------
# 3. LIVING SENTRY — SELF-UPDATE, RULESET & SELF-HEALING FUNCTIONS
# -----------------------------------------------------------------------------

# Baked-in baseline ruleset — used when there is no internet AND no cached copy.
$Global:BaselineRuleset = @{
    version  = "2026.03.31-baseline"
    registry = @(
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";name="AllowTelemetry";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";name="LimitDiagnosticLogCollection";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";name="DisableOneSettingsDownloads";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";name="DoNotShowFeedbackNotifications";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";name="DisableDiagnosticDataViewer";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Recall";name="DisableRecall";value=1;type="DWORD"},
        @{path="HKCU:\Software\Policies\Microsoft\Windows\WindowsAI";name="DisableAIDataAnalysis";value=1;type="DWORD"},
        @{path="HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot";name="TurnOffWindowsCopilot";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";name="AllowCortana";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";name="EnableActivityFeed";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";name="PublishUserActivities";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";name="UploadUserActivities";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization";name="DODownloadMode";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting";name="Disabled";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";name="DisableWindowsConsumerFeatures";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";name="DisableCloudOptimizedContent";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator";name="NoActiveProbe";value=1;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";name="RotatingLockScreenEnabled";value=0;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";name="SubscribedContent-338388Enabled";value=0;type="DWORD"},
        @{path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power";name="HiberbootEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers";name="DisableHTTPPrinting";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers";name="DisableWebPnPDownload";value=1;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy";name="TailoredExperiencesWithDiagnosticDataEnabled";value=0;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo";name="Enabled";value=0;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";name="BingSearchEnabled";value=0;type="DWORD"},
        @{path="HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings";name="IsDynamicSearchBoxEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";name="MetricsReportingEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";name="PersonalizationReportingEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";name="UserFeedbackAllowed";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";name="StartupBoostEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";name="BackgroundModeEnabled";value=0;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";name="AUOptions";value=2;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";name="DeferFeatureUpdates";value=1;type="DWORD"},
        @{path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";name="DeferFeatureUpdatesPeriodInDays";value=30;type="DWORD"}
    )
    hosts = @(
        "vortex.data.microsoft.com","v10.events.data.microsoft.com","v20.events.data.microsoft.com",
        "self.events.data.microsoft.com","telemetry.microsoft.com","settings-win.data.microsoft.com",
        "diagnostic.data.microsoft.com","watson.telemetry.microsoft.com","oca.telemetry.microsoft.com",
        "sqm.telemetry.microsoft.com","browser.pipe.aria.microsoft.com","mobile.pipe.aria.microsoft.com",
        "statsfe2.ws.microsoft.com"
    )
    tasks = @(
        @{path="\Microsoft\Windows\Application Experience\";name="ProgramDataUpdater"},
        @{path="\Microsoft\Windows\Application Experience\";name="Microsoft Compatibility Appraiser"},
        @{path="\Microsoft\Windows\Application Experience\";name="StartupAppTask"},
        @{path="\Microsoft\Windows\Customer Experience Improvement Program\";name="Consolidator"},
        @{path="\Microsoft\Windows\Customer Experience Improvement Program\";name="UsbCeip"},
        @{path="\Microsoft\Windows\Windows Error Reporting\";name="QueueReporting"},
        @{path="\Microsoft\Windows\DiskDiagnostic\";name="Microsoft-Windows-DiskDiagnosticDataCollector"}
    )
}

# Check GitHub version.json for a newer script version.
# Returns a hashtable: @{ NeedsUpdate=$bool; RemoteVersion="x.x.x" }
function Get-RemoteScriptVersion {
    try {
        if ($VersionUrl -match "YourName") { return @{ NeedsUpdate=$false; RemoteVersion=$Version } }
        $response = Invoke-WebRequest -Uri $VersionUrl -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        $manifest = $response.Content | ConvertFrom-Json
        $remote   = [version]$manifest.scriptVersion
        $local    = [version]$Version
        return @{ NeedsUpdate=($remote -gt $local); RemoteVersion=$manifest.scriptVersion }
    } catch {
        return @{ NeedsUpdate=$false; RemoteVersion=$Version }
    }
}

# Download the new script from GitHub, validate it, and replace the installed copy.
# Logs the upgrade and exits — the next Sentry login runs the new version.
function Invoke-ScriptSelfUpdate($remoteVersion) {
    try {
        $tmpPath = Join-Path $env:TEMP "CleanOS_Lite_update.ps1"
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $tmpPath -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop

        # Basic sanity check — confirm the download contains a version string
        $content = Get-Content $tmpPath -Raw
        if ($content -notmatch '\$Version\s*=\s*"[\d.]+"') {
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            Update-Status "Script update aborted — downloaded file failed validation" "ERROR"
            return $false
        }

        # Replace the installed script with the new version
        Copy-Item $tmpPath $LocalScriptPath -Force
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Update-Status "Script updated from v$Version to v$remoteVersion — new version runs on next login" "SUCCESS"
        Show-CleanOSToast "CleanOS Lite — Updated" "Script updated to v$remoteVersion. Changes take effect on next login."
        return $true
    } catch {
        Update-Status "Script self-update failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Fetch the latest ruleset from GitHub with local cache and offline fallback.
function Get-SentryRuleset {
    try {
        if ($RulesetUrl -notmatch "YourName") {
            $response = Invoke-WebRequest -Uri $RulesetUrl -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
            $remote   = $response.Content | ConvertFrom-Json
            $updateCache = $true
            if (Test-Path $RulesetCacheFile) {
                try {
                    $cached = Get-Content $RulesetCacheFile | ConvertFrom-Json
                    if ($cached.version -ge $remote.version) { $updateCache = $false }
                } catch {}
            }
            if ($updateCache) {
                $response.Content | Out-File $RulesetCacheFile -Encoding UTF8 -Force
                Update-Status "Ruleset updated to $($remote.version)" "SUCCESS"
            }
            Update-Status "Running ruleset $($remote.version)" "INFO"
            return $remote
        }
    } catch {
        Update-Status "Remote ruleset unavailable — using cache or baseline" "INFO"
    }
    if (Test-Path $RulesetCacheFile) {
        try {
            $cached = Get-Content $RulesetCacheFile | ConvertFrom-Json
            Update-Status "Running cached ruleset ($($cached.version))" "INFO"
            return $cached
        } catch {}
    }
    Update-Status "Running baked-in baseline ruleset" "INFO"
    return $Global:BaselineRuleset
}

# Apply every registry rule from the loaded ruleset. Returns count fixed.
function Invoke-RulesetAudit($ruleset) {
    $fixed = 0
    foreach ($rule in $ruleset.registry) {
        try {
            $current = Get-ItemProperty -Path $rule.path -Name $rule.name -ErrorAction SilentlyContinue
            if ($null -eq $current -or $current.($rule.name) -ne $rule.value) {
                if (-not (Test-Path $rule.path)) { New-Item $rule.path -Force | Out-Null }
                Set-ItemProperty -Path $rule.path -Name $rule.name -Value $rule.value -Type $rule.type -ErrorAction Stop
                $fixed++
            }
        } catch {
            try {
                $Account = [System.Security.Principal.NTAccount]"Administrators"
                $ACL     = Get-Acl $rule.path ; $ACL.SetOwner($Account) ; Set-Acl $rule.path $ACL
                $Rl      = New-Object System.Security.AccessControl.RegistryAccessRule($Account,"FullControl","ContainerInherit,ObjectInherit","None","Allow")
                $ACL.SetAccessRule($Rl) ; Set-Acl $rule.path $ACL
                Set-ItemProperty -Path $rule.path -Name $rule.name -Value $rule.value -Type $rule.type -ErrorAction SilentlyContinue
                $fixed++
            } catch { continue }
        }
    }
    return $fixed
}

# Verify the hosts file hash. If changed, re-inject missing sinkhole entries.
function Invoke-HostsIntegrityCheck($ruleset) {
    $currentHash = (Get-FileHash $HostsPath -Algorithm SHA256).Hash
    $storedHash  = Get-Content $HostsHashFile -ErrorAction SilentlyContinue
    $remediated  = $false
    if ($currentHash -ne $storedHash) {
        $existing = Get-Content $HostsPath
        foreach ($d in $ruleset.hosts) {
            if (-not ($existing | Select-String -Pattern $d -SimpleMatch -Quiet)) {
                Add-Content $HostsPath "`n0.0.0.0 $d"
                $remediated = $true
            }
        }
        (Get-FileHash $HostsPath -Algorithm SHA256).Hash | Out-File $HostsHashFile -Force
    }
    return $remediated
}

# Returns $true if a Windows Update installed since the last Sentry scan.
function Test-WindowsUpdateOccurred {
    try {
        $latest = (Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First 1).InstalledOn
        if (-not $latest) { return $false }
        $stored = Get-Content $LastUpdateFile -ErrorAction SilentlyContinue
        if ($latest.ToString() -ne $stored) {
            $latest.ToString() | Out-File $LastUpdateFile -Force
            return $true
        }
    } catch {}
    return $false
}

# Core AI/telemetry auditor — scans high-priority watch paths on every login.
function Invoke-ActiveAuditor {
    $WatchPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Recall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AI",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    )
    $Intercepted = $false
    foreach ($Path in $WatchPaths) {
        try {
            if (Test-Path $Path) {
                $Keys = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
                foreach ($Prop in $Keys.PSObject.Properties) {
                    $TargetValue = -1
                    if ($Prop.Name -match "Allow|Enable")                                  { $TargetValue = 0 }
                    elseif ($Prop.Name -match "Disable|Recall|Snapshot|Capture|Tailored")  { $TargetValue = 1 }
                    if ($TargetValue -ne -1 -and $Prop.Value -ne $TargetValue) {
                        Set-RegistrySafe $Path $Prop.Name $TargetValue
                        $Intercepted = $true
                    }
                }
            }
        } catch { continue }
    }
    return $Intercepted
}

# -----------------------------------------------------------------------------
# 4. OPTIONAL FEATURES
# -----------------------------------------------------------------------------

# Ask once about power plan preference and persist it.
function Invoke-PowerPlanSetup {
    $prefs = $null
    if (Test-Path $PrefsFile) { try { $prefs = Import-Clixml $PrefsFile } catch {} }
    if ($prefs -and $null -ne $prefs.HighPerformance) { return }
    Write-Host "`n  Power Plan" -ForegroundColor Cyan
    $ans = (Read-Host "  Is this laptop mostly plugged in? Applies High Performance plan. (Y/N)").Trim()
    $hp  = ($ans -eq 'Y' -or $ans -eq 'y')
    if (-not $prefs) { $prefs = [PSCustomObject]@{ HighPerformance = $hp } }
    else             { $prefs.HighPerformance = $hp }
    $prefs | Export-Clixml $PrefsFile -Force
    if (-not $Global:DryRun) {
        if ($hp) { powercfg /setactive SCHEME_MIN | Out-Null ; Update-Status "High Performance power plan applied" "SUCCESS" }
        else     { powercfg /setactive SCHEME_BALANCED | Out-Null ; Update-Status "Balanced power plan confirmed" "SUCCESS" }
    }
}

# Remove known Microsoft startup nuisances from the Run key.
function Invoke-StartupCleanup {
    Run-Task "Startup Optimisation" "Removed Edge and Teams background startup entries" {
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        $changed = $false
        foreach ($name in @("MicrosoftTeams","OneDrive","MicrosoftEdge")) {
            if (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue) {
                if (-not $Global:DryRun) { Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue }
                $changed = $true
            }
        }
        if (-not $changed) { throw "Already Optimized" }
    }
}

# Phase 6: Disk cleanup — DISM component store + cleanmgr silent run.
function Invoke-DiskCleanup {
    if ($Global:DryRun) {
        Update-Status "Disk Cleanup (DISM + cleanmgr)..." "SIM"
        $Global:TasksFound++
        return
    }
    Write-Host "`n[6] Disk Cleanup" -ForegroundColor Cyan
    Update-Status "Running DISM component store cleanup..." "INFO"
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
    Update-Status "Running Windows disk cleanup (silent)..." "INFO"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty $_.PSPath -Name "StateFlags0064" -Value 2 -Type DWORD -ErrorAction SilentlyContinue
    }
    & cleanmgr.exe /sagerun:64 | Out-Null
    Update-Status "Disk cleanup complete" "SUCCESS"
}

# -----------------------------------------------------------------------------
# 5. CORE CLEANUP & PRIVACY PHASES
# -----------------------------------------------------------------------------
function Start-Cleanup {
    $StartTime = Get-Date
    if ($Global:DryRun) { $Global:TasksFound = 0; $Global:TasksBlocked = 0 }

    # --- SAFETY VAULT ---
    if (-not $Global:DryRun -and -not (Test-Path $MarkerFile)) {
        Update-Status "Creating Safety Vault (Restore Point)..." "INFO"
        try { Enable-ComputerRestore -Drive "C:\"; Checkpoint-Computer -Description "CleanOS Lite Backup" -RestorePointType "MODIFY_SETTINGS" } catch {}
        $TempBackup = Join-Path $BackupPath "temp_vault"
        New-Item $TempBackup -ItemType Directory -Force | Out-Null
        reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "$TempBackup\Priv.reg" /y 2>$null
        Copy-Item $HostsPath "$TempBackup\hosts.bak" -Force
        $TargetSvcs = @('DiagTrack','dmwappushservice','WaaSMedicSvc')
        Get-Service -Name $TargetSvcs -ErrorAction SilentlyContinue | Select-Object Name,StartType | Export-Clixml "$TempBackup\Services.xml"
        $ZipPath = Join-Path $BackupPath "Original_Settings.zip"
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
        Compress-Archive -Path "$TempBackup\*" -DestinationPath $ZipPath -Force
        Remove-Item $TempBackup -Recurse -Force
        New-Item $MarkerFile -ItemType File | Out-Null
        (Get-FileHash $HostsPath -Algorithm SHA256).Hash | Out-File $HostsHashFile -Force
    }

    # =========================================================================
    # PHASE 1: PRIVACY SHIELD
    # =========================================================================
    if (-not $Global:DryRun -and -not $AuditorOnly) { Write-Host "`n[1] Privacy Shield" -ForegroundColor Cyan }

    Run-Task "Kernel Telemetry" "Locked telemetry to Security-Only level with Home/Pro fallback" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' "AllowTelemetry"                  0
        Set-RegistrySafe 'HKLM:\SOFTWARE\CurrentControlSet\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener' "Start" 0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' "LimitDiagnosticLogCollection"    1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' "DisableOneSettingsDownloads"      1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' "DoNotShowFeedbackNotifications"   1
    }
    Run-Task "Recall, AI, Copilot & Cortana" "Disabled Recall, AI Data Analysis, Copilot and Cortana policy keys" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Recall'         "DisableRecall"         1
        Set-RegistrySafe 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'      "DisableAIDataAnalysis" 1
        Set-RegistrySafe 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' "TurnOffWindowsCopilot" 1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' "AllowCortana"          0
    }
    Run-Task "Activity History" "Disabled Activity History logging and cloud upload" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' "EnableActivityFeed"    0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' "PublishUserActivities" 0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' "UploadUserActivities"  0
    }
    Run-Task "Delivery Optimization"    "Disabled P2P Windows Update bandwidth sharing"             { Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' "DODownloadMode" 0 }
    Run-Task "Error Reporting"          "Disabled Windows Error Reporting crash dump upload"         { Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' "Disabled" 1 }
    Run-Task "Cloud Content"            "Blocked consumer spotlight ads and cloud-pushed app installs" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' "DisableWindowsConsumerFeatures" 1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' "DisableCloudOptimizedContent"   1
    }
    Run-Task "NCSI Probe"               "Disabled network connectivity phone-home probe"             { Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' "NoActiveProbe" 1 }
    Run-Task "Lock Screen & Tips"       "Disabled Microsoft Spotlight lock screen and Windows tips"  {
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' "RotatingLockScreenEnabled"       0
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' "SubscribedContent-338388Enabled" 0
    }
    Run-Task "Diagnostic Data Viewer"   "Disabled access to Diagnostic Data Viewer"                  { Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' "DisableDiagnosticDataViewer" 1 }
    Run-Task "Fast Startup"             "Disabled Fast Startup and Hibernate boot telemetry capture"  { Set-RegistrySafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' "HiberbootEnabled" 0 }
    Run-Task "Print Spooler Telemetry"  "Disabled print spooler HTTP telemetry"                       {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' "DisableHTTPPrinting"   1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' "DisableWebPnPDownload" 1
    }
    Run-Task "Windows Update Deferral"  "Deferred feature updates 30 days — security patches unaffected" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' "NoAutoUpdate"                    0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' "AUOptions"                       2
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    "DeferFeatureUpdates"             1
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    "DeferFeatureUpdatesPeriodInDays" 30
    }
    Run-Task "Telemetry Services" "Hard-stopped and deadlocked DiagTrack and WAP push services" {
        $done = 0
        foreach ($n in @('DiagTrack','dmwappushservice')) { if (Disable-AndDeadlock $n) { $done++ } }
        if ($done -eq 2) { throw "Already Optimized" }
    }
    Run-Task "LLMNR & WPAD" "Disabled LLMNR multicast and WPAD proxy auto-detection attack vectors" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'            "EnableMulticast"    0
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' "AutoDetect"         0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main'          "DisableProxyUpdate" 1
    }
    Run-Task "NetBIOS Hardening" "Disabled NetBIOS over TCP/IP on all network adapters" {
        $NetBTPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
        if (-not (Test-Path $NetBTPath)) { throw "Already Optimized" }
        $adapters    = Get-ChildItem $NetBTPath
        $needsUpdate = $adapters | Where-Object { (Get-ItemProperty $_.PSPath -Name "NetbiosOptions" -ErrorAction SilentlyContinue).NetbiosOptions -ne 2 }
        if (-not $needsUpdate) { throw "Already Optimized" }
        if (-not $Global:DryRun) { $adapters | ForEach-Object { Set-ItemProperty $_.PSPath -Name "NetbiosOptions" -Value 2 -Type DWORD -ErrorAction SilentlyContinue } }
    }

    # =========================================================================
    # PHASE 2: INTERFACE & PERSONALIZATION
    # =========================================================================
    if (-not $Global:DryRun -and -not $AuditorOnly) { Write-Host "`n[2] Interface & Personalization" -ForegroundColor Cyan }

    Run-Task "Typing & Ad Privacy" "Disabled Advertising ID and Keystroke Personalization" {
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'         "TailoredExperiencesWithDiagnosticDataEnabled" 0
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' "Enabled"       0
        Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\TabletPC'                        "UserDictionary" 0
    }
    Run-Task "Search UI"         "Neutralized Bing Search in Start Menu"                    { Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' "BingSearchEnabled" 0 }
    Run-Task "Search Highlights" "Disabled taskbar search Fun Facts and dynamic icons"      { Set-RegistrySafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' "IsDynamicSearchBoxEnabled" 0 }
    Run-Task "Edge Telemetry"    "Disabled Microsoft Edge usage reporting and background processes" {
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' "MetricsReportingEnabled"        0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' "PersonalizationReportingEnabled" 0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' "UserFeedbackAllowed"             0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' "StartupBoostEnabled"             0
        Set-RegistrySafe 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' "BackgroundModeEnabled"           0
    }

    # =========================================================================
    # PHASE 3: LOCAL NETWORK HARDENING
    # =========================================================================
    if (-not $Global:DryRun -and -not $AuditorOnly) { Write-Host "`n[3] Local Network Hardening" -ForegroundColor Cyan }

    Run-Task "Telemetry Hosts Sinkhole" "Sinkholed all known Microsoft telemetry endpoints locally" {
        $Existing    = Get-Content $HostsPath
        $NeedsUpdate = $false
        foreach ($d in $Global:BaselineRuleset.hosts) {
            if (-not ($Existing | Select-String -Pattern $d -SimpleMatch -Quiet)) { $NeedsUpdate = $true }
        }
        if (-not $NeedsUpdate) { throw "Already Optimized" }
        if (-not $Global:DryRun) {
            foreach ($d in $Global:BaselineRuleset.hosts) {
                if (-not (Select-String -Path $HostsPath -Pattern $d -SimpleMatch -Quiet)) { Add-Content $HostsPath "`n0.0.0.0 $d" }
            }
            (Get-FileHash $HostsPath -Algorithm SHA256).Hash | Out-File $HostsHashFile -Force
        }
    }

    # =========================================================================
    # PHASE 4: BLOATWARE REMOVAL (skipped in AuditorOnly)
    # =========================================================================
    if (-not $AuditorOnly) {
        if (-not $Global:DryRun) { Write-Host "`n[4] Uninstalling Bloatware" -ForegroundColor Cyan }
        $apps = @(
            '*Copilot*','*549981C3F5F10*','*PowerAutomate*','*Clipchamp*',
            '*MicrosoftTeams*','*WindowsFeedbackHub*','*XboxIdentityProvider*',
            '*3DViewer*','*MixedReality.Portal*','*MSPaint*',
            '*MicrosoftSolitaireCollection*','*XboxGamingOverlay*',
            '*ZuneMusic*','*ZuneVideo*','*GrooveMusic*',
            '*SkypeApp*','*YourPhone*','*News*','*Maps*',
            '*GetHelp*','*Getstarted*','*OfficeHub*','*People*'
        )
        foreach ($app in $apps) {
            $cleanName = $app.Replace('*','')
            Run-Task "$cleanName" "Removed $cleanName and purged provisioned installer" {
                $pkg     = Get-AppxPackage -Name $app -AllUsers
                $provPkg = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $app }
                if (-not $pkg -and -not $provPkg) { throw "Already Optimized" }
                if (-not $Global:DryRun) {
                    Get-Process | Where-Object { $_.Name -like "*$cleanName*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                    if ($pkg) {
                        $pkg | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                        foreach ($loc in $pkg.InstallLocation) {
                            if ($loc -and (Test-Path $loc)) { Remove-Item $loc -Recurse -Force -ErrorAction SilentlyContinue }
                        }
                    }
                    if ($provPkg) { $provPkg | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue }
                }
            }
        }
        Invoke-StartupCleanup
    }

    # =========================================================================
    # PHASE 5: PERSISTENCE & HARDENING
    # =========================================================================
    if (-not $Global:DryRun -and -not $AuditorOnly) { Write-Host "`n[5] Persistence & Hardening" -ForegroundColor Cyan }

    Run-Task "Telemetry Tasks" "Deactivated all Microsoft telemetry and diagnostics scheduled tasks" {
        $DoneCount = 0
        foreach ($t in $Global:BaselineRuleset.tasks) {
            $task = Get-ScheduledTask -TaskPath $t.path -TaskName $t.name -ErrorAction SilentlyContinue
            if (-not $task -or $task.State -eq 'Disabled') { $DoneCount++ }
            elseif (-not $Global:DryRun) { Disable-ScheduledTask -TaskPath $t.path -TaskName $t.name -ErrorAction SilentlyContinue }
        }
        if ($DoneCount -eq $Global:BaselineRuleset.tasks.Count) { throw "Already Optimized" }
    }
    Run-Task "WaaSMedic Guard" "Disabled WaaSMedic Self-Healing Telemetry repair service" { Set-RegistrySafe 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' "Start" 4 }
    Run-Task "Living Sentry & Self-Update Engine" "Sentry installed — fetches rules and script updates on every login" {
        $taskExists = Get-ScheduledTask -TaskName 'CleanOS_Lite_Maintenance' -ErrorAction SilentlyContinue
        if ($taskExists) { throw "Already Optimized" }
        if (-not $Global:DryRun) {
            $a = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
                -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -NoCopy -AuditorOnly"
            Register-ScheduledTask -TaskName 'CleanOS_Lite_Maintenance' -Action $a `
                -Trigger (New-ScheduledTaskTrigger -AtLogOn) -User SYSTEM -RunLevel Highest -Force | Out-Null
        }
    }

    if (-not $Global:DryRun -and -not $AuditorOnly) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue ; Start-Process explorer.exe
        $elapsed = [Math]::Round((New-TimeSpan -Start $StartTime -End (Get-Date)).TotalSeconds, 2)
        Write-Host "`n✔ Optimized in ${elapsed}s." -ForegroundColor Cyan
        Write-Host @"

  ─────────────────────────────────────────────────────────────
 
  ✔  Your laptop is now optimised. The Sentry runs on every
     login, fetches the latest privacy rules and script updates
     from GitHub automatically. No further action needed.

  ℹ  Your lock screen may now show a plain background instead
     of the rotating Microsoft images. To set your own photo:
     Settings → Personalisation → Lock screen → Picture
     → Browse photos. A local slideshow also works fine.

  ⚠  After a major Windows feature update: the Sentry will
     detect it automatically and run a full repair pass on
     your next login. You can also re-run CleanOS Lite from
     your Desktop shortcut at any time.
     
  ─────────────────────────────────────────────────────────────
"@ -ForegroundColor Cyan
        if ((Read-Host "`n  Run disk cleanup now? Frees several GB. (Y/N)") -eq 'y') { Invoke-DiskCleanup }
        if ((Read-Host "  Restart now to finalise? (Y/N)") -eq 'y') { Restart-Computer }
    }
}

# -----------------------------------------------------------------------------
# 6. RESTORATION & UNINSTALL
# -----------------------------------------------------------------------------
function Restore-Uninstall {
    Write-Host "`nStarting System Reset" -ForegroundColor Gray
    Write-Host "`n[Restoring Original Settings...]" -ForegroundColor Cyan
    $zip         = Join-Path $BackupPath "Original_Settings.zip"
    $tempRestore = Join-Path $BackupPath "restore"
    if (Test-Path $zip) {
        Expand-Archive $zip -DestinationPath $tempRestore -Force
        Get-ChildItem $tempRestore -Filter "*.reg" | ForEach-Object { reg import $_.FullName | Out-Null }
        if (Test-Path "$tempRestore\hosts.bak") { Copy-Item "$tempRestore\hosts.bak" $HostsPath -Force }
        if (Test-Path "$tempRestore\Services.xml") {
            $OrigSvcs = Import-Clixml "$tempRestore\Services.xml"
            foreach ($s in $OrigSvcs) {
                Set-Service -Name $s.Name -StartupType $s.StartType -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" `
                    -Name "DependOnService" -Value @() -Type MultiString -ErrorAction SilentlyContinue
            }
        }
        Unregister-ScheduledTask -TaskName 'CleanOS_Lite_Maintenance' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $tempRestore -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✔ System restored. CleanOS Lite will now remove itself." -ForegroundColor Green
        Start-Sleep -Seconds 1
        $SelfDestructCmd = "ping 127.0.0.1 -n 3 > nul & rmdir /s /q `"$ProgramDataPath`""
        Start-Process cmd.exe -ArgumentList "/c $SelfDestructCmd" -WindowStyle Hidden
        Stop-Process -Id $PID
    } else {
        Write-Host "  [!] Backup archive not found. Nothing to restore." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# VERSION CHECK & SENTRY ENTRY POINT
# -----------------------------------------------------------------------------
if (Test-Path $LocalScriptPath) {
    $raw = (Get-Content $LocalScriptPath | Select-String '\$Version = "(.*)"').Matches.Groups[1].Value
    if ($raw -and $raw -ne $Version) { Update-Status "CleanOS Lite updated to v$Version" "INFO" }
}

if ($AuditorOnly) {
    $Global:DryRun = $false

    # 1. Check for a new script version — update and exit if found
    $vCheck = Get-RemoteScriptVersion
    if ($vCheck.NeedsUpdate) {
        Update-Status "New script version $($vCheck.RemoteVersion) available — updating..." "INFO"
        $updated = Invoke-ScriptSelfUpdate $vCheck.RemoteVersion
        if ($updated) { exit }  # Next login runs the new version
    }

    # 2. Load latest ruleset (remote → cache → baseline)
    $ruleset = Get-SentryRuleset

    # 3. Check for Windows Update — run full pass if detected
    if (Test-WindowsUpdateOccurred) {
        Update-Status "Windows Update detected — running full repair pass" "INFO"
        Start-Cleanup
        Show-CleanOSToast "CleanOS Lite — Post-Update Repair" "Windows Update detected. All privacy settings re-applied."
        exit
    }

    # 4. Standard Sentry scan
    $rulesetFixed  = Invoke-RulesetAudit $ruleset
    $hostsFixed    = Invoke-HostsIntegrityCheck $ruleset
    $aiIntercepted = Invoke-ActiveAuditor
    $anythingFixed = $rulesetFixed -gt 0 -or $hostsFixed -or $aiIntercepted

    if ($anythingFixed) {
        $detail = @()
        if ($rulesetFixed  -gt 0) { $detail += "$rulesetFixed registry key(s)" }
        if ($hostsFixed)           { $detail += "hosts file" }
        if ($aiIntercepted)        { $detail += "AI policy keys" }
        $msg = "Repaired: $($detail -join ', ')."
        Update-Status "Sentry repaired: $($detail -join ', ')." "SUCCESS"
        Show-CleanOSToast "CleanOS Lite — Sentry Alert" $msg
    } else {
        Update-Status "Sentry scan complete — all settings secure. Ruleset: $($ruleset.version)" "SUCCESS"
        Show-CleanOSToast "CleanOS Lite — System Secure" "All settings verified. Ruleset: $($ruleset.version)"
    }
    exit
}

# -----------------------------------------------------------------------------
# 7. UI MENU
# -----------------------------------------------------------------------------
$Banner = @"
   █████████  ████                                   ███████     █████████
  ███░░░░░███░░███            Welcome to           ███░░░░░███  ███░░░░░███
 ███     ░░░  ░███   ██████   ██████   ████████   ███     ░░███░███    ░░░ 
░███          ░███  ███░░███ ░░░░░███ ░░███░░███ ░███      ░███░░█████████ 
░███          ░███ ░███████   ███████  ░███ ░███ ░███      ░███ ░░░░░░░░███
░░███     ███ ░███ ░███░░░   ███░░███  ░███ ░███ ░░███     ███  ███    ░███
 ░░█████████  █████░░██████ ░░████████ ████ █████ ░░░███████░  ░░█████████ 
  ░░░░░░░░░  ░░░░░  ░░░░░░   ░░░░░░░░ ░░░░ ░░░░░    ░░░░░░░     ░░░░░░░░░  
    Lite v$Version                Your Hardware. Your Data. Your Choice.
"@

do {
    Clear-Host ; Write-Host $Banner -ForegroundColor Cyan
    Write-Host "`n 1. Start CleanOS Lite`n 2. View Logs`n 3. Restore & Uninstall`n Q. Quit"
    $choice = Read-Host "`n Selection"
    switch ($choice) {
        '1' {
            Invoke-PowerPlanSetup
            Write-Host "`nStarting Preflight Check`n" -ForegroundColor Gray
            $Global:DryRun = $true
            Start-Cleanup
            Write-Host "-----------------------------------------------------------"
            Write-Host " • Possible Changes Found : $($Global:TasksFound)"   -ForegroundColor Green
            Write-Host " • Already Optimized      : $($Global:TasksBlocked)" -ForegroundColor White
            Write-Host "  (Already Optimized = that setting is correctly applied.)" -ForegroundColor Gray
            Write-Host "-----------------------------------------------------------"
            if ((Read-Host "Review the changes above. Apply them now? (Y/N)") -eq 'y') {
                $Global:DryRun = $false
                Write-Host "`nApplying Changes`n" -ForegroundColor Gray
                Start-Cleanup
            }
        }
        '2' {
            Write-Host "`nViewing Logs`n" -ForegroundColor Gray
            if (Test-Path $LogFile) { Clear-Host; Get-Content $LogFile -Tail 50; Read-Host "`nPress Enter" }
            else { Write-Host "  [!] No log file found yet." -ForegroundColor Yellow ; Start-Sleep 2 }
        }
        '3' {
            Write-Host @"

  ⚠  IMPORTANT — Please read before confirming:
     • Removed apps CANNOT be restored automatically.
       They must be re-downloaded from the Microsoft Store if needed.
     • Registry, hosts file, and service startup types will be restored
       from the Safety Vault to their original pre-CleanOS state.
     • All CleanOS Lite data (logs, ruleset cache, backup) will be deleted.

"@ -ForegroundColor Yellow
            if ((Read-Host "  Are you sure you want to revert all changes and uninstall CleanOS Lite? (Y/N)") -eq 'y') {
                Restore-Uninstall
            }
        }
    }
} while ($choice -ne 'Q')
