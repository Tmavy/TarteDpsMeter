param([string]$GameExe = "")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

function Show-Message([string]$Text, [string]$Title = "TarteMeter Installer",
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
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $payload = Join-Path $scriptDir "Payload"
    $manifestPath = Join-Path $scriptDir "UE4SS_FILE_MANIFEST.txt"
    $backupDir = Join-Path $gameDir "TarteMeter_Backup"
    $filesBackup = Join-Path $backupDir "OriginalFiles"
    $installedState = Join-Path $backupDir "InstalledFiles.txt"

    New-Item -ItemType Directory -Path $filesBackup -Force | Out-Null

    $manifest = @(Get-Content -LiteralPath $manifestPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })

    # Preserve the original CREATED/REPLACED classification across upgrades.
    # Without this, a file created by the first install could be misclassified as
    # REPLACED on the next update and then incorrectly restored by the uninstaller.
    $priorModes = @{}
    if (Test-Path -LiteralPath $installedState -PathType Leaf) {
        foreach ($entry in Get-Content -LiteralPath $installedState) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $parts = $entry -split '\|', 2
            if ($parts.Count -eq 2) {
                $priorModes[$parts[1]] = $parts[0]
            }
        }
    }

    $installed = @()
    foreach ($relative in $manifest) {
        $source = Join-Path $payload ($relative.Replace("/", "\"))
        $target = Join-Path $gameDir ($relative.Replace("/", "\"))
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Installer payload is incomplete: $relative"
        }

        if ($priorModes.ContainsKey($relative)) {
            $mode = [string]$priorModes[$relative]
        }
        elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            $mode = "REPLACED"
            $backupTarget = Join-Path $filesBackup ($relative.Replace("/", "\"))
            New-Item -ItemType Directory `
                -Path (Split-Path -Parent $backupTarget) `
                -Force | Out-Null
            if (-not (Test-Path -LiteralPath $backupTarget -PathType Leaf)) {
                Copy-Item -LiteralPath $target -Destination $backupTarget -Force
            }
        }
        else {
            $mode = "CREATED"
        }

        $installed += "$mode|$relative"
    }

    # Copy only manifest-listed UE4SS files. Do not copy Payload\Mods\mods.txt:
    # overwriting it before backup would erase entries for the user's other mods.
    foreach ($relative in $manifest) {
        $source = Join-Path $payload ($relative.Replace("/", "\"))
        $target = Join-Path $gameDir ($relative.Replace("/", "\"))
        New-Item -ItemType Directory `
            -Path (Split-Path -Parent $target) `
            -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }

    $modsDir = Join-Path $gameDir "Mods"
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    $modsTxt = Join-Path $modsDir "mods.txt"
    $modsBackup = Join-Path $backupDir "mods.txt.original"

    if ((Test-Path $modsTxt) -and -not (Test-Path $modsBackup)) {
        Copy-Item $modsTxt $modsBackup -Force
    }

    # Merge the mod program files while preserving generated battle history,
    # settings, and logs that are not present in the installer payload.
    $modSource = Join-Path $payload "Mods\TarteMeter"
    $modTarget = Join-Path $modsDir "TarteMeter"
    New-Item -ItemType Directory -Path $modTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $modSource "*") `
        -Destination $modTarget `
        -Recurse `
        -Force

    $lines = @()
    if (Test-Path $modsTxt) {
        $lines = @(Get-Content $modsTxt | Where-Object {
            $_ -notmatch '^\s*(DragonSwordDPSMeter|TarteMeter)\s*:'
        })
    }
    $lines += "TarteMeter : 1"
    Set-Content -LiteralPath $modsTxt -Value $lines -Encoding UTF8

    Set-Content -LiteralPath $installedState -Value $installed -Encoding UTF8
    Show-Message "TarteMeter v2.2.0 installed.`n`nExisting logs, settings, and other mods.txt entries were preserved."
} catch {
    Show-Message ("Installation failed:`n`n" + $_.Exception.Message) "TarteMeter Installer" `
        ([System.Windows.MessageBoxImage]::Error)
    exit 1
}
