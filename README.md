# Windows Cleanup Script

## What it does
1. **Restore point**: so you can roll back if something goes wrong.
2. **Hardware report**: OS, SSD/HDD and drive health, free space, RAM and free
   slots, battery report (saved to the desktop) and a list of startup items.
   Warns about an HDD, low disk space or 8 GB RAM or less.
3. **Removes preinstalled Store apps** (News, Weather, Copilot, Widgets,
   Clipchamp, Solitaire, etc.). Shows the list first: `y` removes all, `n` removes
   nothing, or type numbers to keep some.
4. **Bloatware scan (report only)**: flags fake optimizers, adware, third-party
   antivirus, manufacturer bloat (HP, Dell, Lenovo, ASUS, Acer), trials and
   outdated software, with advice per item. Also checks which antivirus is active.
5. **Windows tweaks**: turns off tips/suggestions, Start recommendations,
   transparency, Bing in Start search, Game Bar recording, Widgets, Copilot and
   update sharing with other PCs. Turns on Storage Sense.
6. **Updates** all apps via winget.
7. **Cleanup**: temp files and old Windows update files.
8. **Done**: shows time taken and space freed, then opens the Performance
   Options window for the visual effects.

## Available options
| Option            | What it does                                            |
|-------------------|---------------------------------------------------------|
| `-Repair`         | Also runs DISM RestoreHealth + SFC (15–30 min)          |
| `-Keep A,B*`      | Never remove these apps (name or package, wildcards ok) |
| `-DisableSysMain` | Turns off SysMain; only useful on spinning hard drives  |
| `-RemoveOneDrive` | Uninstalls OneDrive (asks y/n first)                    |

## How to run
1. Download `laptop-cleanup.ps1` from the repository.

<br>

2. Open **Windows PowerShell as administrator** <br>
   (Start → type `powershell` → right-click → *Run as administrator*) and go to the folder with the script:
   ```powershell
   cd $env:USERPROFILE\Downloads
   Set-ExecutionPolicy -Scope Process Bypass -Force
   ```
<br>
   
3. In the same window, run the script:
   ```powershell
   .\laptop-cleanup.ps1
   ```
   Or with options, e.g. `.\laptop-cleanup.ps1 -Repair -Keep Weather`
