param([string]$GameExe = "")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

function Show-Message([string]$Text, [string]$Title = "TarteMeter Uninstaller",
    [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information) {
    [System.Windows.MessageBox]::Show($Text, $Title,
        [System.Windows.MessageBoxButton]::OK, $Icon) | Out-Null
}

function Select-GameExe {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select DSClient-Win64-Shipping.exe"
    $dialog.Filter = "DragonSword executable|DSClient-Win64-Shipping.exe"
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dialog.FileName
}

try {
    if ([string]::IsNullOrWhiteSpace($GameExe)) { $GameExe = Select-GameExe }
    if ([string]::IsNullOrWhiteSpace($GameExe)) { exit 0 }
    if ([IO.Path]::GetFileName($GameExe) -ne "DSClient-Win64-Shipping.exe") {
        throw "Please select DSClient-Win64-Shipping.exe."
    }

    $gameDir = Split-Path -Parent $GameExe
    $backupDir = Join-Path $gameDir "TarteMeter_Backup"
    $filesBackup = Join-Path $backupDir "OriginalFiles"
    $installedState = Join-Path $backupDir "InstalledFiles.txt"

    foreach ($folder in @(
        (Join-Path $gameDir "Mods\TarteMeter"),
        (Join-Path $gameDir "Mods\DragonSwordDPSMeter")
    )) {
        if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    }

    $modsTxt = Join-Path $gameDir "Mods\mods.txt"
    $modsBackup = Join-Path $backupDir "mods.txt.original"
    # Remove only this mod's entries from the current file so mods installed
    # after TarteMeter are not lost. Use the original backup only if mods.txt
    # itself is missing.
    if (Test-Path $modsTxt) {
        $lines = @(Get-Content $modsTxt | Where-Object {
            $_ -notmatch '^\s*(TarteMeter|DragonSwordDPSMeter)\s*:'
        })
        Set-Content $modsTxt $lines -Encoding UTF8
    }
    elseif (Test-Path $modsBackup) {
        Copy-Item $modsBackup $modsTxt -Force
    }

    if (Test-Path $installedState) {
        foreach ($entry in Get-Content $installedState) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $parts = $entry -split '\|', 2
            if ($parts.Count -ne 2) { continue }
            $mode, $relative = $parts
            if ($relative -match '(?i)^amd_fidelityfx_') { continue }

            $target = Join-Path $gameDir ($relative.Replace("/", "\"))
            $backup = Join-Path $filesBackup ($relative.Replace("/", "\"))

            if ($mode -eq "REPLACED" -and (Test-Path $backup)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item $backup $target -Force
            } elseif ($mode -eq "CREATED" -and (Test-Path $target -PathType Leaf)) {
                Remove-Item $target -Force
            }
        }
    } else {
        # Legacy install fallback: remove only known UE4SS loader files.
        # Never remove native game FidelityFX DLLs.
        foreach ($name in @(
            "UE4SS.dll", "dwmapi.dll", "UE4SS-settings.ini",
            "tbb.dll", "tbb12.dll", "tbbmalloc.dll",
            "OpenImageDenoise.dll", "API.txt", "Changelog.md",
            "README.md", "imgui.ini"
        )) {
            $target = Join-Path $gameDir $name
            if (Test-Path $target -PathType Leaf) { Remove-Item $target -Force }
        }
    }

    if (Test-Path $backupDir) { Remove-Item $backupDir -Recurse -Force }
    Show-Message "TarteMeter was removed safely.`n`nNative DragonSword FidelityFX DLLs were not removed."
} catch {
    Show-Message ("Uninstallation failed:`n`n" + $_.Exception.Message) "TarteMeter Uninstaller" `
        ([System.Windows.MessageBoxImage]::Error)
    exit 1
}
