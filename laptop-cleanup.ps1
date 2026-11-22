#Requires -RunAsAdministrator
<#
    Laptop cleanup / speed-up script

    Run in an elevated Windows PowerShell (5.1, the built-in one):
        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\laptop-cleanup.ps1                      # safe defaults
        .\laptop-cleanup.ps1 -Repair              # extras, see params below
        .\laptop-cleanup.ps1 -Keep Weather,Teams* # never remove these apps

    Notes
    - Per-user settings (HKCU) apply to the account running the script.
      If the daily user is a separate account, run it while logged in as them.
    - A restore point is made first. Reboot when it's done.
    - A full log is saved to the desktop (laptop-cleanup-log.txt).
#>
param(
    [switch]$Repair,          # run DISM + SFC (slow, 15-30 min)
    [switch]$DisableSysMain,  # only useful on laptops with a spinning HDD
    [switch]$RemoveOneDrive,  # uninstall OneDrive (check nothing is cloud-only first!)
    [string[]]$Keep           # apps never to remove, e.g. -Keep Weather,Copilot (name or package, wildcards ok)
)

$ErrorActionPreference = 'Continue'
$startTime = Get-Date
$log = "$env:USERPROFILE\Desktop\laptop-cleanup-log.txt"
Start-Transcript -Path $log -Force | Out-Null

# ---------------------------------------------------------------- Output helpers
$script:stepNo = 0
$totalSteps = 8
function Section($t) {
    $script:stepNo++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $script:stepNo, $totalSteps, $t) -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}
function Step($t)  { Write-Host ("  {0}  {1} ... " -f (Get-Date -Format 'HH:mm:ss'), $t) -NoNewline }
function Ok($t = 'done')    { Write-Host $t -ForegroundColor Green }
function Skip($t = 'skipped') { Write-Host $t -ForegroundColor DarkGray }
function Fail($t)  { Write-Host "FAILED: $t" -ForegroundColor Red }
function Info($t)  { Write-Host "    $t" -ForegroundColor Gray }
function Note($t)  { Write-Host "    ! $t" -ForegroundColor Yellow }

function Set-Reg {
    param($Path, $Name, $Value, $Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Tweak($label, [scriptblock]$action) {
    Step $label
    try { $ErrorActionPreference = 'Stop'; & $action; Ok } catch { Fail $_.Exception.Message }
}

Write-Host 'Laptop cleanup started' -ForegroundColor White
Info "Log file: $log"
Info ("Options: Repair={0}  DisableSysMain={1}  RemoveOneDrive={2}" -f [bool]$Repair, [bool]$DisableSysMain, [bool]$RemoveOneDrive)
if ($Keep) { Info "Keep: $($Keep -join ', ')" }

# ---------------------------------------------------------------- 1. Restore point
Section 'Restore point'
Step 'Enabling System Protection on system drive'
try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; Ok } catch { Ok 'already on' }
Step 'Creating restore point (can take a minute)'
try {
    Checkpoint-Computer -Description 'Before laptop cleanup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable w -WarningAction SilentlyContinue
    if ($w) { Skip 'skipped (Windows allows one per 24h, an earlier one exists)' } else { Ok }
} catch { Fail $_.Exception.Message }

# ---------------------------------------------------------------- 2. Hardware report
Section 'Hardware report'
Info (Get-CimInstance Win32_OperatingSystem).Caption

Get-PhysicalDisk | Format-Table FriendlyName, MediaType, HealthStatus,
    @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } } -AutoSize | Out-Host
if (Get-PhysicalDisk | Where-Object MediaType -eq 'HDD') { Note 'Spinning hard drive found: an SSD upgrade will help more than anything else' }
if (Get-PhysicalDisk | Where-Object HealthStatus -ne 'Healthy') { Note 'A drive does not report Healthy: check it with CrystalDiskInfo' }

$c = Get-PSDrive ($env:SystemDrive.TrimEnd(':'))
$freeBefore = $c.Free
Info ('System drive free: {0} GB of {1} GB' -f [math]::Round($c.Free / 1GB), [math]::Round(($c.Used + $c.Free) / 1GB))
if ($c.Free / ($c.Used + $c.Free) -lt 0.15) { Note 'Less than 15% free space' }

$mods  = @(Get-CimInstance Win32_PhysicalMemory)
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
$ramGB = [math]::Round(($mods | Measure-Object Capacity -Sum).Sum / 1GB)
Info ('RAM: {0} GB in {1} of {2} slots' -f $ramGB, $mods.Count, $slots)
if ($ramGB -le 8) { Note "Only $ramGB GB RAM: an upgrade is worth considering" }

if (Get-CimInstance Win32_Battery) {
    Step 'Creating battery report'
    $report = "$env:USERPROFILE\Desktop\battery-report.html"
    powercfg /batteryreport /output $report | Out-Null
    Ok "saved to desktop"
}

Write-Host ''
Info 'Startup items (disable unneeded ones in Task Manager > Startup apps):'
Get-CimInstance Win32_StartupCommand | Format-Table Name, Location -AutoSize | Out-Host

# ---------------------------------------------------------------- 3. Bloat
Section 'Removing preinstalled Store apps'
# Edit this list as needed: package name = friendly name shown in the list
$appx = [ordered]@{
    'Microsoft.BingNews'                     = 'Microsoft News'
    'Microsoft.BingWeather'                  = 'Weather'
    'Microsoft.GetHelp'                      = 'Get Help'
    'Microsoft.Getstarted'                   = 'Tips'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire Collection'
    'Microsoft.WindowsFeedbackHub'           = 'Feedback Hub'
    'Microsoft.Copilot'                      = 'Copilot'
    'MicrosoftWindows.Client.WebExperience'  = 'Widgets'
    'Clipchamp.Clipchamp'                    = 'Clipchamp'
    'Microsoft.549981C3F5F10'                = 'Cortana'
    'MicrosoftTeams'                         = 'Teams (personal)'
    'Microsoft.MicrosoftOfficeHub'           = 'Microsoft 365 / Office hub'
}

Step 'Checking which of these are installed'
$provisioned = Get-AppxProvisionedPackage -Online
$toRemove = @(foreach ($a in $appx.Keys) {
    $pkg  = Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue
    $prov = $provisioned | Where-Object DisplayName -eq $a
    if ($pkg -or $prov) { [pscustomobject]@{ Name = $appx[$a]; Package = $a; Pkg = $pkg; Prov = $prov } }
})
Ok "$($toRemove.Count) of $($appx.Count) installed"

# Apps excluded with -Keep (matches friendly name or package name, wildcards allowed)
if ($Keep) {
    $kept = @($toRemove | Where-Object { $t = $_; $Keep | Where-Object { $t.Name -like $_ -or $t.Package -like $_ } })
    foreach ($k in $kept) { Info "Keeping $($k.Name) (excluded with -Keep)" }
    $toRemove = @($toRemove | Where-Object { $kept -notcontains $_ })
}

function Show-List($items) {
    $i = 0
    foreach ($t in $items) { $i++; Write-Host ("    {0,2}. {1,-28} ({2})" -f $i, $t.Name, $t.Package) }
}

# Turns "2, 4-6" into 2,4,5,6. Returns $null if the input is invalid.
function Parse-Numbers($text, $max) {
    $nums = @()
    foreach ($part in ($text -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { $nums += [int]$matches[1]..[int]$matches[2] }
        elseif ($part -match '^\d+$')     { $nums += [int]$part }
        else { return $null }
    }
    if ($nums | Where-Object { $_ -lt 1 -or $_ -gt $max }) { return $null }
    return ($nums | Sort-Object -Unique)
}

if ($toRemove.Count -eq 0) {
    Info 'Nothing to remove'
} else {
    while ($true) {
        Write-Host ''
        Write-Host '  The following apps will be removed:' -ForegroundColor White
        Show-List $toRemove
        Write-Host ''
        Write-Host '  y = remove all   n = remove nothing   or type numbers to KEEP (e.g. 2,5 or 3-4)' -ForegroundColor Gray
        $answer = (Read-Host '  Choice').Trim().ToLower()

        if ($answer -in 'y', 'yes', 'n', 'no') { break }

        $keepNums = Parse-Numbers $answer $toRemove.Count
        if ($null -eq $keepNums) { Note "Didn't understand '$answer', try again"; continue }

        foreach ($n in $keepNums) { Info "Keeping $($toRemove[$n - 1].Name)" }
        $toRemove = @(for ($i = 0; $i -lt $toRemove.Count; $i++) { if (($i + 1) -notin $keepNums) { $toRemove[$i] } })
        if ($toRemove.Count -eq 0) { $answer = 'n'; break }
        # loop shows the updated list and asks again
    }

    if ($answer -like 'y*') {
        $removed = 0
        foreach ($t in $toRemove) {
            Step "Removing $($t.Name)"
            try {
                if ($t.Pkg)  { $t.Pkg  | Remove-AppxPackage -AllUsers -ErrorAction Stop }
                if ($t.Prov) { $t.Prov | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null }
                Ok 'removed'; $removed++
            } catch { Fail $_.Exception.Message }
        }
        Info "$removed app(s) removed"
    } else {
        Info 'Skipped, nothing removed'
    }
}

# ---------------------------------------------------------------- 4. Bloat scan
Section 'Scanning for known bloatware (report only, nothing is removed)'

# Category -> advice
$advice = @{
    'Fake optimizer'    = 'Remove: "cleaners"/driver updaters slow the PC and nag'
    'Adware'            = 'Remove, then check browser extensions + search engine'
    'Antivirus'         = 'Remove unless paid for on purpose; Defender takes over'
    'OEM bloat'         = 'Remove'
    'OEM support tool'  = 'Optional: keep if used (driver/BIOS updates, hotkeys, printer)'
    'Trial / promo'     = 'Remove if not used'
    'Outdated'          = 'Remove: unsupported + security risk (Java: unless needed)'
    'Preinstalled app'  = 'Remove if not used'
}

# Desktop programs: wildcard pattern -> category. First match wins, so specific ones go first.
$programRules = [ordered]@{
    # Lenovo - never flag these, they run the Fn keys / drivers
    'Lenovo System Interface Foundation*' = ''; 'Lenovo Hotkeys*' = ''; 'Lenovo Power Management*' = ''
    'Lenovo Pen Settings*' = ''; 'Lenovo Utility*' = ''
    # Lenovo - bloat
    'Lenovo Now*' = 'OEM bloat'; 'Lenovo Welcome*' = 'OEM bloat'; 'Lenovo Migration Assistant*' = 'OEM bloat'
    'Lenovo App Explorer*' = 'OEM bloat'; 'Lenovo Service Bridge*' = 'OEM bloat'; 'Lenovo Photo Master*' = 'OEM bloat'
    'Lenovo Voice*' = 'OEM bloat'; 'Lenovo Legion Arena*' = 'OEM bloat'; 'Lenovo Smart Meeting*' = 'OEM bloat'
    'Lenovo Smart Noise Cancellation*' = 'OEM bloat'; 'Lenovo Quick Clean*' = 'OEM bloat'; 'Lenovo Universal Device Client*' = 'OEM bloat'
    'Lenovo Hotkey Features Integration*' = ''   # Fn key OSD on older models
    # Lenovo - outdated (end of life, known security issues)
    'Lenovo Solution Center*' = 'Outdated'; 'Lenovo Companion*' = 'Outdated'; 'Lenovo Settings Dependency*' = 'Outdated'
    'Lenovo Messenger*' = 'Outdated'; 'Lenovo Accelerator Application*' = 'Outdated'
    # Lenovo - support tools (Vantage = battery conservation, Fn lock, driver updates)
    'Lenovo Vantage*' = 'OEM support tool'; 'Lenovo Commercial Vantage*' = 'OEM support tool'
    'Lenovo System Update*' = 'OEM support tool'; 'Lenovo Legion Zone*' = 'OEM support tool'
    'Legion Space*' = 'OEM support tool'; 'Lenovo Smart Appearance*' = 'OEM support tool'
    # Fake optimizers / cleaners / driver updaters
    'CCleaner*' = 'Fake optimizer'; 'Driver Booster*' = 'Fake optimizer'; 'Advanced SystemCare*' = 'Fake optimizer'
    'IObit*' = 'Fake optimizer'; 'Driver Easy*' = 'Fake optimizer'; 'DriverPack*' = 'Fake optimizer'
    'Glary Utilities*' = 'Fake optimizer'; 'Wise Care 365*' = 'Fake optimizer'; 'Wise Disk Cleaner*' = 'Fake optimizer'
    'Reimage*' = 'Fake optimizer'; 'Restoro*' = 'Fake optimizer'; 'Fortect*' = 'Fake optimizer'
    'PC Accelerate*' = 'Fake optimizer'; 'Auslogics*' = 'Fake optimizer'; 'Avast Cleanup*' = 'Fake optimizer'
    'AVG TuneUp*' = 'Fake optimizer'; 'Norton Utilities*' = 'Fake optimizer'; 'Systweak*' = 'Fake optimizer'
    'Advanced System Optimizer*' = 'Fake optimizer'; 'Advanced Driver Updater*' = 'Fake optimizer'
    'SlimCleaner*' = 'Fake optimizer'; '*PC Cleaner*' = 'Fake optimizer'; '*PC Optimizer*' = 'Fake optimizer'
    'Outbyte*' = 'Fake optimizer'; 'Driver Support*' = 'Fake optimizer'; 'WinZip System Utilities*' = 'Fake optimizer'
    'Smart Driver*' = 'Fake optimizer'; 'Driver Updater*' = 'Fake optimizer'; 'Registry Reviver*' = 'Fake optimizer'
    # Adware / browser hijackers / bundleware
    '*Web Companion*' = 'Adware'; 'WebDiscover*' = 'Adware'; 'Wave Browser*' = 'Adware'; 'WaveBrowser*' = 'Adware'
    'OneLaunch*' = 'Adware'; '*Search Protect*' = 'Adware'; 'Conduit*' = 'Adware'; '*Ask Toolbar*' = 'Adware'
    'MyWay*' = 'Adware'; 'Segurazo*' = 'Adware'; 'SAntivirus*' = 'Adware'; 'ByteFence*' = 'Adware'
    'Hola*' = 'Adware'; 'Amazon Assistant*' = 'Adware'; 'PC App Store*' = 'Adware'; 'Clario*' = 'Adware'
    'Yandex*' = 'Adware'; 'Baidu*' = 'Adware'; 'Opera GX*' = 'Trial / promo'
    # Third-party antivirus
    'McAfee*' = 'Antivirus'; '*Norton*' = 'Antivirus'; 'Avast*' = 'Antivirus'; 'AVG *' = 'Antivirus'
    'Avira*' = 'Antivirus'; 'TotalAV*' = 'Antivirus'; 'Total AV*' = 'Antivirus'; 'Kaspersky*' = 'Antivirus'
    'Bitdefender*' = 'Antivirus'; 'ESET*' = 'Antivirus'; 'Panda *' = 'Antivirus'; 'Trend Micro*' = 'Antivirus'
    'Webroot*' = 'Antivirus'; 'Sophos Home*' = 'Antivirus'; 'PC Matic*' = 'Antivirus'; 'Surfshark Antivirus*' = 'Antivirus'
    # Manufacturer support tools (useful for drivers, otherwise optional)
    'HP Support Assistant*' = 'OEM support tool'; '*SupportAssist*' = 'OEM support tool'; 'Dell Update*' = 'OEM support tool'
    'Dell Command*Update*' = 'OEM support tool'
    'MyASUS*' = 'OEM support tool'; 'Armoury Crate*' = 'OEM support tool'; 'Acer Care Center*' = 'OEM support tool'
    'MSI Center*' = 'OEM support tool'
    # Manufacturer bloat
    'HP JumpStart*' = 'OEM bloat'; 'HP Wolf Security*' = 'OEM bloat'; 'HP Sure Click*' = 'OEM bloat'; 'HP Sure Sense*' = 'OEM bloat'
    'HP Documentation*' = 'OEM bloat'; 'HP Connection Optimizer*' = 'OEM bloat'; 'HP Privacy Settings*' = 'OEM bloat'
    'HP Registration*' = 'OEM bloat'; 'HP Client Security Manager*' = 'OEM bloat'; 'HP Security Update Service*' = 'OEM bloat'
    'Dell Digital Delivery*' = 'OEM bloat'; 'Dell Customer Connect*' = 'OEM bloat'; 'Dell Mobile Connect*' = 'OEM bloat'
    'Dell Optimizer*' = 'OEM bloat'
    'ASUS GiftBox*' = 'OEM bloat'; 'Acer Jumpstart*' = 'OEM bloat'; 'Acer Collection*' = 'OEM bloat'
    'Acer Portal*' = 'OEM bloat'; 'Acer Product Registration*' = 'OEM bloat'
    # Trials / promos
    'WildTangent*' = 'Trial / promo'; 'Booking.com*' = 'Trial / promo'; 'ExpressVPN*' = 'Trial / promo'
    'CyberLink*' = 'Trial / promo'; '*Dropbox*Promotion*' = 'Trial / promo'; 'Dropbox 25 GB*' = 'Trial / promo'
    # Outdated / unsupported
    'Java(TM)*' = 'Outdated'; 'Java 8*' = 'Outdated'; 'Java *Update*' = 'Outdated'; 'Adobe Flash*' = 'Outdated'
    'Adobe Shockwave*' = 'Outdated'; 'Microsoft Silverlight*' = 'Outdated'; 'QuickTime*' = 'Outdated'; 'Adobe AIR*' = 'Outdated'
}

# Store apps: package name pattern -> category
$appxRules = [ordered]@{
    'king.com.*' = 'Preinstalled app'; '*Disney*' = 'Preinstalled app'; '*TikTok*' = 'Preinstalled app'
    'Facebook.*' = 'Preinstalled app'; '*Instagram*' = 'Preinstalled app'; 'AmazonVideo.*' = 'Preinstalled app'
    '*Netflix*' = 'Preinstalled app'; '*Spotify*' = 'Preinstalled app'; '*LinkedIn*' = 'Preinstalled app'
    '*PicsArt*' = 'Preinstalled app'; '*Booking*' = 'Trial / promo'; '*ExpressVPN*' = 'Trial / promo'
    '*McAfee*' = 'Antivirus'; '*Norton*' = 'Antivirus'; '*CyberLink*' = 'Trial / promo'
    'E0469640.LenovoUtility*' = ''                       # Lenovo hotkeys/Fn keys: never flag
    'E046963F.LenovoCompanion*' = 'OEM support tool'     # Lenovo Vantage
    'E046963F.LenovoSettingsforEnterprise*' = 'OEM support tool'   # Lenovo Commercial Vantage
    'E046963F.*' = 'OEM support tool'; 'E0469640.*' = 'OEM support tool'   # other Lenovo apps
    'DellInc.*' = 'OEM support tool'; 'B9ECED6F.*' = 'OEM support tool'    # ASUS apps
    'AcerIncorporated.*' = 'OEM support tool'; 'AD2F1837.*' = 'OEM support tool'   # Acer / HP apps
}

function Get-Category($name, $rules) {
    foreach ($k in $rules.Keys) { if ($name -like $k) { return $rules[$k] } }
}

Step 'Scanning installed programs'
$uninstallKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$found = @(Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
    Sort-Object DisplayName -Unique |
    ForEach-Object {
        $cat = Get-Category $_.DisplayName $programRules
        if ($cat) { [pscustomobject]@{ Name = $_.DisplayName; Type = 'Program'; Category = $cat; Advice = $advice[$cat] } }
    })
Ok "$($found.Count) found"

Step 'Scanning Store apps'
$foundAppx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Sort-Object Name -Unique |
    ForEach-Object {
        $cat = Get-Category $_.Name $appxRules
        if ($cat) { [pscustomobject]@{ Name = $_.Name; Type = 'Store app'; Category = $cat; Advice = $advice[$cat] } }
    })
Ok "$($foundAppx.Count) found"

$all = @($found) + @($foundAppx)
if ($all.Count) {
    $all | Sort-Object Category, Name | Format-Table Name, Type, Category, Advice -AutoSize -Wrap | Out-Host
    Info 'Uninstall via Settings > Apps > Installed apps, or: winget uninstall --name "<Name>"'
    if ($all.Name -match 'McAfee') { Note 'McAfee often needs its removal tool (MCPR) to fully go away' }
    if ($all.Name -match 'Norton') { Note 'Norton may need the Norton Remove and Reinstall tool' }
    if ($all.Name -match 'Lenovo|E04696') {
        Note 'Lenovo: do NOT remove Lenovo System Interface Foundation, Hotkeys or Utility (Fn keys stop working)'
        Note 'Lenovo Vantage: set Battery Conservation Mode / Fn lock first; these stay set after removing it'
    }
} else { Info 'No known bloatware found' }

Step 'Checking registered antivirus'
try {
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
        Select-Object -ExpandProperty displayName -Unique)
    Ok ($av -join ', ')
    $thirdParty = $av | Where-Object { $_ -notmatch 'Windows Defender|Microsoft Defender' }
    if ($thirdParty) { Note "Third-party antivirus active: $($thirdParty -join ', '). Defender is enough for most people" }
    if (@($thirdParty).Count -gt 1) { Note 'Multiple antivirus products registered: they fight each other and slow the PC down' }
} catch { Skip 'could not read Security Center' }

# ---------------------------------------------------------------- 5. Windows tweaks
Section 'Windows tweaks'
Tweak 'Turning off tips, suggestions and welcome screens' {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled',
                   'SubscribedContent-338387Enabled', 'SubscribedContent-353698Enabled',
                   'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                   'RotatingLockScreenOverlayEnabled', 'SilentInstalledAppsEnabled') {
        Set-Reg $cdm $v 0
    }
}
Tweak 'Turning off Start menu recommendations' {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
}
Tweak 'Turning off transparency effects' {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
}
Tweak 'Turning off Bing web results in Start search' {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
}
Tweak 'Turning off Game Bar background recording' {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
}
Tweak 'Turning off Widgets' {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
}
Tweak 'Turning off Copilot' {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
}
Tweak 'Turning off sharing updates with other PCs' {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
}
Tweak 'Turning on Storage Sense' {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 1
}

Step 'SysMain (Superfetch)'
if ($DisableSysMain) {
    try {
        Stop-Service SysMain -Force -ErrorAction SilentlyContinue
        Set-Service SysMain -StartupType Disabled -ErrorAction Stop
        Ok 'disabled'
    } catch { Fail $_.Exception.Message }
} else { Skip 'left on (use -DisableSysMain to turn off)' }

Step 'OneDrive'
if ($RemoveOneDrive) {
    Write-Host ''
    Note 'OneDrive will be uninstalled. Files that are only in the cloud stay online, not on this PC.'
    do { $answer = (Read-Host '  Uninstall OneDrive? (y/n)').Trim().ToLower() } until ($answer -in 'y', 'n', 'yes', 'no')
}
if ($RemoveOneDrive -and $answer -like 'y*') {
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    winget uninstall --id Microsoft.OneDrive --silent --accept-source-agreements
    Info 'OneDrive uninstall finished'
} elseif ($RemoveOneDrive) { Info 'OneDrive kept' }
else { Skip 'kept (use -RemoveOneDrive to uninstall)' }

# ---------------------------------------------------------------- 6. Updates
Section 'Updating apps via winget'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info 'This can take a while; winget shows its own progress below'
    winget upgrade --all --silent --accept-source-agreements --accept-package-agreements
    Info 'winget finished'
} else {
    Note 'winget not found: update "App Installer" from the Microsoft Store and run again'
}

# ---------------------------------------------------------------- 7. Cleanup
Section 'Cleanup'
Step 'Deleting temp files (files in use are skipped)'
Remove-Item "$env:TEMP\*", "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Ok
Info 'Cleaning old Windows update files (DISM, can take 5-15 min, shows its own progress):'
DISM /Online /Cleanup-Image /StartComponentCleanup

if ($Repair) {
    Info 'Repairing Windows image (DISM RestoreHealth, 10-20 min):'
    DISM /Online /Cleanup-Image /RestoreHealth
    Info 'Checking system files (SFC, 5-15 min):'
    sfc /scannow
} else {
    Info 'Repair skipped (use -Repair to run DISM RestoreHealth + SFC)'
}

# ---------------------------------------------------------------- 8. Done
Section 'Done'
$freeAfter = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
$freed = [math]::Round(($freeAfter - $freeBefore) / 1GB, 1)
$mins  = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Info "Finished in $mins min, disk space freed: $freed GB"
Info "Full log: $log"
Write-Host ''
Write-Host 'Still to do by hand:' -ForegroundColor White
Info '- Visual effects: the window that opens now > "Adjust for best performance" > re-tick font smoothing'
Info '- Task Manager > Startup apps: disable what is not needed'
Info '- Settings > System > Power: "Best performance" when plugged in'
Info '- Uninstall anything flagged in the bloatware scan (step 4)'
Write-Host ''
Write-Host 'Then reboot.' -ForegroundColor Yellow

Stop-Transcript | Out-Null
Start-Process SystemPropertiesPerformance
