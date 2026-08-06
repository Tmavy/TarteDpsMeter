$ErrorActionPreference = "Stop"



$script:DataDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:PayloadDir = [IO.Path]::Combine($script:DataDir, "Payload")

$script:ModPayload = [IO.Path]::Combine($script:PayloadDir, "Mods", "TarteMeter")

$script:UE4SSPayload = [IO.Path]::Combine($script:PayloadDir, "UE4SS")

$script:Version = "3.1.3"

$script:FatalLog = [IO.Path]::Combine($script:DataDir, "InstallerError.log")

$script:LogBox = $null

$script:StatusLabel = $null

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false



trap {

    try {

        [IO.File]::WriteAllText(

            $script:FatalLog,

            ($_ | Out-String),

            $script:Utf8NoBom

        )

    }

    catch {}



    try {

        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        [void][Windows.Forms.MessageBox]::Show(

            "TarteMeter Setup encountered an unexpected error.`r`n`r`n" +

            "Details were saved to:`r`n$script:FatalLog",

            "TarteMeter Setup",

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Error

        )

    }

    catch {}

    exit 1

}



Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

[Windows.Forms.Application]::EnableVisualStyles()



function Join-NativePath {

    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)



    $valid = @($Parts | Where-Object {

        -not [string]::IsNullOrWhiteSpace($_)

    })

    if ($valid.Count -eq 0) { return "" }



    $result = $valid[0]

    for ($index = 1; $index -lt $valid.Count; $index++) {

        $result = [IO.Path]::Combine($result, $valid[$index])

    }

    return $result

}



function Test-NativePathRoot {

    param([string]$Path)



    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {

        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())

        $root = [IO.Path]::GetPathRoot($expanded)

        return (

            -not [string]::IsNullOrWhiteSpace($root) -and

            [IO.Directory]::Exists($root)

        )

    }

    catch {

        return $false

    }

}



function Write-SetupLog {

    param([string]$Text)



    $line = "[{0}] {1}" -f [DateTime]::Now.ToString("HH:mm:ss"), $Text

    try {

        [IO.File]::AppendAllText(

            [IO.Path]::Combine($script:DataDir, "Installer.log"),

            $line + [Environment]::NewLine,

            $script:Utf8NoBom

        )

    }

    catch {}



    if ($null -ne $script:LogBox) {

        $script:LogBox.AppendText($line + "`r`n")

        $script:LogBox.SelectionStart = $script:LogBox.TextLength

        $script:LogBox.ScrollToCaret()

        [Windows.Forms.Application]::DoEvents()

    }

}



function Set-Status {

    param(

        [string]$Text,

        [Drawing.Color]$Color = [Drawing.Color]::FromArgb(174, 190, 207)

    )



    if ($null -ne $script:StatusLabel) {

        $script:StatusLabel.Text = $Text

        $script:StatusLabel.ForeColor = $Color

        [Windows.Forms.Application]::DoEvents()

    }

}



function Get-SteamLibraries {

    $libraries = New-Object 'System.Collections.Generic.List[string]'



    foreach ($keyPath in @(

        'HKCU:\Software\Valve\Steam',

        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',

        'HKLM:\SOFTWARE\Valve\Steam'

    )) {

        try {

            $item = Get-ItemProperty -Path $keyPath -ErrorAction Stop

            foreach ($propertyName in @('SteamPath', 'InstallPath')) {

                $value = [string]$item.$propertyName

                if (-not [string]::IsNullOrWhiteSpace($value)) {

                    $libraries.Add($value)

                }

            }

        }

        catch {}

    }



    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {

        $libraries.Add((Join-NativePath ${env:ProgramFiles(x86)} 'Steam'))

    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {

        $libraries.Add((Join-NativePath $env:ProgramFiles 'Steam'))

    }



    foreach ($candidate in @(

        'C:\Steam',

        'D:\SteamLibrary',

        'E:\SteamLibrary',

        'F:\SteamLibrary'

    )) {

        $libraries.Add($candidate)

    }



    $expandedLibraries = New-Object 'System.Collections.Generic.List[string]'

    foreach ($library in @($libraries | Select-Object -Unique)) {

        if ([string]::IsNullOrWhiteSpace($library)) { continue }



        $normalized = [Environment]::ExpandEnvironmentVariables(

            $library.Replace('/', '\').Trim()

        )

        if (-not (Test-NativePathRoot $normalized)) { continue }

        $expandedLibraries.Add($normalized)



        $vdf = Join-NativePath $normalized 'steamapps' 'libraryfolders.vdf'

        if (-not [IO.File]::Exists($vdf)) { continue }



        try {

            $text = [IO.File]::ReadAllText($vdf)

            foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {

                $path = $match.Groups[1].Value.Replace('\\', '\')

                if (

                    -not [string]::IsNullOrWhiteSpace($path) -and

                    (Test-NativePathRoot $path)

                ) {

                    $expandedLibraries.Add($path)

                }

            }

        }

        catch {}

    }



    return @($expandedLibraries | Select-Object -Unique)

}



function Find-DragonSwordExe {

    $relative = @(

        'DS',

        'Binaries',

        'Win64',

        'DSClient-Win64-Shipping.exe'

    )



    foreach ($library in Get-SteamLibraries) {

        $common = Join-NativePath $library 'steamapps' 'common'

        if (-not [IO.Directory]::Exists($common)) { continue }



        foreach ($folderName in @(

            'DragonSword  Awakening',

            'DragonSword Awakening'

        )) {

            $candidate = Join-NativePath $common $folderName @relative

            if ([IO.File]::Exists($candidate)) { return $candidate }

        }



        try {

            foreach ($folder in [IO.Directory]::EnumerateDirectories($common)) {

                $name = [IO.Path]::GetFileName($folder)

                if ($name -notlike 'DragonSword*Awakening*') { continue }

                $candidate = Join-NativePath $folder @relative

                if ([IO.File]::Exists($candidate)) { return $candidate }

            }

        }

        catch {}

    }



    return $null

}



function Normalize-GameExePath {

    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $candidate = $Path.Trim().Trim('"')
    try {
        return [IO.Path]::GetFullPath($candidate)
    }
    catch {
        return $candidate
    }
}

function Test-GameExe {

    param([string]$Path)

    $candidate = Normalize-GameExePath $Path
    return (
        -not [string]::IsNullOrWhiteSpace($candidate) -and
        [IO.File]::Exists($candidate) -and
        [IO.Path]::GetFileName($candidate) -ieq 'DSClient-Win64-Shipping.exe' -and
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($candidate)) -ieq 'Win64' -and
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($candidate))) -ieq 'Binaries'
    )
}



function Get-RelativeFiles {

    param([string]$Root)



    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')

    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse) {

        [pscustomobject]@{

            Source = $file.FullName

            Relative = $file.FullName.Substring($rootFull.Length).TrimStart('\')

        }

    }

}



function Merge-ModsTxt {

    param([string]$ModsDirectory)



    New-Item -ItemType Directory -Path $ModsDirectory -Force | Out-Null

    $modsTxt = Join-NativePath $ModsDirectory 'mods.txt'

    $lines = @()

    if ([IO.File]::Exists($modsTxt)) {

        $lines = @([IO.File]::ReadAllLines($modsTxt) | Where-Object {

            $_ -notmatch '^\s*(DragonSwordDPSMeter|DragonswordDPSMeter|TarteDPSMeter|TarteDpsMeter|TarteMeter)\s*:'

        })

    }

    $lines += 'TarteMeter : 1'

    [IO.File]::WriteAllLines(

        $modsTxt,

        $lines,

        $script:Utf8NoBom

    )

}



function Get-FileSha256 {

    param([string]$Path)



    if (-not [IO.File]::Exists($Path)) { return $null }

    $sha = [Security.Cryptography.SHA256]::Create()

    try {

        $stream = [IO.File]::OpenRead($Path)

        try {

            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()

        }

        finally { $stream.Dispose() }

    }

    finally { $sha.Dispose() }

}



function Disable-LegacyCombatMods {

    param([string]$ModsDirectory)



    foreach ($folderName in @(

        'DragonSwordDPSMeter',

        'DragonswordDPSMeter',

        'TarteDPSMeter',

        'TarteDpsMeter'

    )) {

        $legacyFolder = Join-NativePath $ModsDirectory $folderName

        $legacyEnabled = Join-NativePath $legacyFolder 'enabled.txt'

        if ([IO.File]::Exists($legacyEnabled)) {

            $disabledPath = Join-NativePath $legacyFolder 'enabled.txt.disabled-by-tartemeter-v275'

            Move-Item -LiteralPath $legacyEnabled -Destination $disabledPath -Force

            Write-SetupLog ("Disabled legacy combat mod enable marker: {0}" -f $legacyEnabled)

        }

    }

}



function Install-TarteMeter {

    param(

        [string]$GameExe,

        [bool]$RepairUE4SS

    )



    $GameExe = Normalize-GameExePath $GameExe

    if (-not (Test-GameExe $GameExe)) {

        throw 'Select DSClient-Win64-Shipping.exe from DS\Binaries\Win64.'

    }



    $gameDir = [IO.Path]::GetDirectoryName($GameExe)

    $modsDir = Join-NativePath $gameDir 'Mods'

    $modTarget = Join-NativePath $modsDir 'TarteMeter'

    $backupDir = Join-NativePath $gameDir 'TarteMeter_Backup'

    $originalDir = Join-NativePath $backupDir 'OriginalFiles'

    $statePath = Join-NativePath $backupDir 'InstallState.txt'



    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    New-Item -ItemType Directory -Path $originalDir -Force | Out-Null



    $priorState = @{}

    if ([IO.File]::Exists($statePath)) {

        foreach ($line in [IO.File]::ReadAllLines($statePath)) {

            $parts = $line -split '\|', 2

            if ($parts.Count -eq 2) { $priorState[$parts[1]] = $parts[0] }

        }

    }



    $state = @{}

    foreach ($entry in $priorState.GetEnumerator()) {

        $state[$entry.Key] = $entry.Value

    }



    $hasUE4SS = (

        [IO.File]::Exists((Join-NativePath $gameDir 'UE4SS.dll')) -and

        [IO.File]::Exists((Join-NativePath $gameDir 'dwmapi.dll'))

    )



    if (-not $hasUE4SS -or $RepairUE4SS) {

        Write-SetupLog ($(if ($RepairUE4SS) {

            'Repairing the bundled UE4SS files...'

        } else {

            'Installing the bundled UE4SS files...'

        }))



        foreach ($file in Get-RelativeFiles $script:UE4SSPayload) {

            $target = Join-NativePath $gameDir $file.Relative

            $targetDir = [IO.Path]::GetDirectoryName($target)

            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null



            if (-not $state.ContainsKey($file.Relative)) {

                if ([IO.File]::Exists($target)) {

                    $state[$file.Relative] = 'REPLACED'

                    $backup = Join-NativePath $originalDir $file.Relative

                    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backup)) -Force | Out-Null

                    if (-not [IO.File]::Exists($backup)) {

                        [IO.File]::Copy($target, $backup, $false)

                    }

                }

                else {

                    $state[$file.Relative] = 'CREATED'

                }

            }



            if (

                $file.Relative -ieq 'UE4SS-settings.ini' -and

                [IO.File]::Exists($target) -and

                -not $RepairUE4SS

            ) {

                continue

            }

            [IO.File]::Copy($file.Source, $target, $true)

        }

    }

    else {

        Write-SetupLog 'A working UE4SS installation was detected and preserved.'

    }



    Stop-TarteMeterOverlay $GameExe

    Disable-LegacyCombatMods $modsDir



    # mods.txt is the only enable mechanism. Keeping both mods.txt and a local

    # enabled.txt can load the same Lua runtime twice on some UE4SS builds.

    $ownEnabled = Join-NativePath $modTarget 'enabled.txt'

    if ([IO.File]::Exists($ownEnabled)) {

        Remove-Item -LiteralPath $ownEnabled -Force

    }



    Write-SetupLog 'Installing TarteMeter files...'

    New-Item -ItemType Directory -Path $modTarget -Force | Out-Null

    New-Item -ItemType Directory -Path (Join-NativePath $modTarget 'battle_timelines') -Force | Out-Null

    foreach ($file in Get-RelativeFiles $script:ModPayload) {

        $target = Join-NativePath $modTarget $file.Relative

        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null

        [IO.File]::Copy($file.Source, $target, $true)

    }



    # Volatile live-session files are version-specific and must not be mixed
    # with a newly installed attribution engine. History and archived timelines
    # are intentionally preserved.
    foreach ($volatileName in @(
        'dps_state.txt',
        'dps_state.tmp',
        'dps_command.txt',
        'dps_meter.txt',
        'current_timeline.csv'
    )) {
        $volatilePath = Join-NativePath $modTarget $volatileName
        if ([IO.File]::Exists($volatilePath)) {
            Remove-Item -LiteralPath $volatilePath -Force
        }
    }
    Write-SetupLog 'Cleared stale live-session state; preserved battle history and archived timelines.'



    $ownEnabled = Join-NativePath $modTarget 'enabled.txt'

    if ([IO.File]::Exists($ownEnabled)) {

        Remove-Item -LiteralPath $ownEnabled -Force

    }

    [IO.File]::WriteAllText(

        (Join-NativePath $modTarget 'installed_version.txt'),

        ('TarteMeter v' + $script:Version + [Environment]::NewLine),

        $script:Utf8NoBom

    )

    [IO.File]::WriteAllText(

        (Join-NativePath $modTarget 'installed_ui_variant.txt'),

        ('Compact' + [Environment]::NewLine),

        $script:Utf8NoBom

    )



    Merge-ModsTxt $modsDir



    foreach ($requiredFile in @(

        (Join-NativePath $modTarget 'Scripts' 'main.lua'),

        (Join-NativePath $modTarget 'DPSWindow.ps1'),

        (Join-NativePath $modTarget 'OverlayBootstrap.ps1'),

        (Join-NativePath $modTarget 'LaunchOverlay.vbs')

    )) {

        if (-not [IO.File]::Exists($requiredFile)) {

            throw ("Required TarteMeter file was not installed: {0}" -f $requiredFile)

        }

    }



    $installedWindowScript = Join-NativePath $modTarget 'DPSWindow.ps1'

    $installedWindowText = [IO.File]::ReadAllText($installedWindowScript)

    if (

        $installedWindowText.IndexOf(

            'TarteMeter v3.1.3',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'TarteMeterOverlay_v313',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'window_settings_v14_compact.ini',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'UI_VARIANT_COMPACT',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'TITLEBAR_VECTOR_CONTROLS_V313',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'battle_history_index.tsv',

            [StringComparison]::Ordinal

        ) -lt 0 -or

        $installedWindowText.IndexOf(

            'ReadUtf8Prefix',

            [StringComparison]::Ordinal

        ) -lt 0

    ) {

        throw (

            'The v3.1.3 Compact overlay script was not installed correctly. ' +

            'Close every old TarteMeter PowerShell process and run setup again.'

        )

    }

    $installedMain = Join-NativePath $modTarget 'Scripts' 'main.lua'

    $payloadMain = Join-NativePath $script:ModPayload 'Scripts' 'main.lua'

    $installedMainText = [IO.File]::ReadAllText($installedMain)

    if (

        $installedMainText.IndexOf('TarteMeter v3.1.3', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('runtime_singleton_guard=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('source_owner_protection=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('multi_target_aoe_owner=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('late_source_target_binding=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('stale_source_cannot_override_target_owner=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('no_unattributed=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('compact_history_v2=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('archived_timeline=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('low_memory_event_preview=true', [StringComparison]::Ordinal) -lt 0 -or

        $installedMainText.IndexOf('AUTO_RESET_AFTER_SAVE', [StringComparison]::Ordinal) -ge 0

    ) {

        throw 'The installed combat runtime is stale or invalid. Close the game and run Install / Update again.'

    }



    $payloadMainHash = Get-FileSha256 $payloadMain

    $installedMainHash = Get-FileSha256 $installedMain

    $payloadWindowHash = Get-FileSha256 (Join-NativePath $script:ModPayload 'DPSWindow.ps1')

    $installedWindowHash = Get-FileSha256 $installedWindowScript

    if (

        [string]::IsNullOrWhiteSpace($payloadMainHash) -or

        $payloadMainHash -ne $installedMainHash -or

        [string]::IsNullOrWhiteSpace($payloadWindowHash) -or

        $payloadWindowHash -ne $installedWindowHash

    ) {

        throw 'Installed TarteMeter program files did not match the v3.1.3 Compact payload.'

    }



    Write-SetupLog 'Verified v3.1.3 Compact UI, combat runtime, hashes, reset guard, and single-instance identifiers.'





    # Remove the obsolete visible CMD helper from older releases. The meter

    # launches its hidden PowerShell window directly from Lua.

    $legacyLauncher = Join-NativePath $modTarget 'Launch_TarteMeter.cmd'

    if ([IO.File]::Exists($legacyLauncher)) {

        [IO.File]::Delete($legacyLauncher)

    }



    $stateLines = @()

    foreach ($key in @($state.Keys | Sort-Object)) {

        $stateLines += ('{0}|{1}' -f $state[$key], $key)

    }

    [IO.File]::WriteAllLines(

        $statePath,

        $stateLines,

        $script:Utf8NoBom

    )



    Write-SetupLog 'TarteMeter installation completed successfully.'

    Write-SetupLog 'Existing battle history, exports, settings, key bindings, and unrelated mods.txt entries were preserved.'

}



function Remove-UE4SSInstalledBySetup {

    param(

        [string]$GameDirectory,

        [string]$BackupDirectory,

        [string]$OriginalDirectory,

        [string]$StateFile

    )



    if (-not [IO.File]::Exists($StateFile)) {

        Write-SetupLog 'No UE4SS ownership record was found. Existing UE4SS files were left untouched.'

        return

    }



    Write-SetupLog 'Removing UE4SS files recorded as installed by TarteMeter Installer...'

    foreach ($line in [IO.File]::ReadAllLines($StateFile)) {

        $parts = $line -split '\|', 2

        if ($parts.Count -ne 2) { continue }



        $mode = $parts[0]

        $relative = $parts[1]

        $target = Join-NativePath $GameDirectory $relative

        $backup = Join-NativePath $OriginalDirectory $relative



        if ($mode -eq 'CREATED') {

            if ([IO.File]::Exists($target)) {

                [IO.File]::Delete($target)

                Write-SetupLog ("Removed UE4SS file: {0}" -f $relative)

            }

        }

        elseif ($mode -eq 'REPLACED') {

            if ([IO.File]::Exists($backup)) {

                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null

                [IO.File]::Copy($backup, $target, $true)

                Write-SetupLog ("Restored the original file: {0}" -f $relative)

            }

            else {

                Write-SetupLog ("Skipped {0}: its original backup is unavailable." -f $relative)

            }

        }

    }



    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue



    foreach ($directory in @($OriginalDirectory, $BackupDirectory)) {

        if (-not [IO.Directory]::Exists($directory)) { continue }

        try {

            if (@(Get-ChildItem -LiteralPath $directory -Force -Recurse).Count -eq 0) {

                Remove-Item -LiteralPath $directory -Force -Recurse

            }

        }

        catch {}

    }

}



function Uninstall-TarteMeter {

    param(

        [string]$GameExe,

        [bool]$RemoveUE4SS

    )



    $GameExe = Normalize-GameExePath $GameExe

    if (-not (Test-GameExe $GameExe)) {

        throw 'Select DSClient-Win64-Shipping.exe from DS\Binaries\Win64.'

    }



    $gameDir = [IO.Path]::GetDirectoryName($GameExe)

    $modsDir = Join-NativePath $gameDir 'Mods'

    $modTarget = Join-NativePath $modsDir 'TarteMeter'

    $backupDir = Join-NativePath $gameDir 'TarteMeter_Backup'

    $originalDir = Join-NativePath $backupDir 'OriginalFiles'

    $statePath = Join-NativePath $backupDir 'InstallState.txt'



    Write-SetupLog 'Removing TarteMeter program files...'

    if ([IO.Directory]::Exists($modTarget)) {

        foreach ($file in Get-RelativeFiles $script:ModPayload) {

            $target = Join-NativePath $modTarget $file.Relative

            if ([IO.File]::Exists($target)) {

                [IO.File]::Delete($target)

            }

        }



        $legacyLauncher = Join-NativePath $modTarget 'Launch_TarteMeter.cmd'

        if ([IO.File]::Exists($legacyLauncher)) {

            [IO.File]::Delete($legacyLauncher)

        }



        foreach ($directory in @(

            (Join-NativePath $modTarget 'Scripts'),

            (Join-NativePath $modTarget 'Assets')

        )) {

            if (

                [IO.Directory]::Exists($directory) -and

                @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0

            ) {

                Remove-Item -LiteralPath $directory -Force

            }

        }

    }



    $modsTxt = Join-NativePath $modsDir 'mods.txt'

    if ([IO.File]::Exists($modsTxt)) {

        $lines = @([IO.File]::ReadAllLines($modsTxt) | Where-Object {

            $_ -notmatch '^\s*(DragonSwordDPSMeter|DragonswordDPSMeter|TarteDPSMeter|TarteDpsMeter|TarteMeter)\s*:'

        })

        [IO.File]::WriteAllLines(

            $modsTxt,

            $lines,

            $script:Utf8NoBom

        )

    }



    if ($RemoveUE4SS) {

        $removeOwnedArgs = @{
            GameDirectory = $gameDir
            BackupDirectory = $backupDir
            OriginalDirectory = $originalDir
            StateFile = $statePath
        }
        Remove-UE4SSInstalledBySetup @removeOwnedArgs

    }

    else {

        Write-SetupLog 'UE4SS was preserved.'

    }



    Write-SetupLog 'Removal completed. Battle history, exports, themes, key bindings, and window settings remain in Mods\TarteMeter.'

}



function Get-InstallStateText {

    param([string]$GameExe)



    if (-not (Test-GameExe $GameExe)) {

        return [pscustomobject]@{

            Text = 'Select the game executable to continue.'

            Color = [Drawing.Color]::FromArgb(224, 172, 112)

            Valid = $false

        }

    }



    $gameDir = [IO.Path]::GetDirectoryName($GameExe)

    $modInstalled = [IO.File]::Exists((Join-NativePath $gameDir 'Mods' 'TarteMeter' 'Scripts' 'main.lua'))

    $ue4ssInstalled = (

        [IO.File]::Exists((Join-NativePath $gameDir 'UE4SS.dll')) -and

        [IO.File]::Exists((Join-NativePath $gameDir 'dwmapi.dll'))

    )



    $state = if ($modInstalled) { 'TarteMeter is installed' } else { 'TarteMeter is not installed' }

    $ue4ss = if ($ue4ssInstalled) { 'UE4SS detected' } else { 'UE4SS will be installed' }

    return [pscustomobject]@{

        Text = "$state  |  $ue4ss"

        Color = [Drawing.Color]::FromArgb(111, 201, 160)

        Valid = $true

    }

}



function Set-FlatButton {

    param(

        [Windows.Forms.Button]$Button,

        [Drawing.Color]$BackColor,

        [Drawing.Color]$ForeColor

    )



    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat

    $Button.FlatAppearance.BorderSize = 0

    $Button.BackColor = $BackColor

    $Button.ForeColor = $ForeColor

    $Button.Cursor = [Windows.Forms.Cursors]::Hand

    $Button.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)

}





function Load-BitmapUnlocked {

    param([string]$Path)



    if (-not [IO.File]::Exists($Path)) { return $null }

    $stream = $null

    $source = $null

    try {

        $bytes = [IO.File]::ReadAllBytes($Path)

        $stream = New-Object IO.MemoryStream(,$bytes)

        $source = [Drawing.Image]::FromStream($stream)

        return New-Object Drawing.Bitmap -ArgumentList $source

    }

    catch {

        Write-SetupLog ("Could not load installer image: " + $_.Exception.Message)

        return $null

    }

    finally {

        if ($null -ne $source) { $source.Dispose() }

        if ($null -ne $stream) { $stream.Dispose() }

    }

}



function Stop-TarteMeterOverlay {

    param([string]$GameExe)



    if (-not (Test-GameExe $GameExe)) { return }

    $gameDir = [IO.Path]::GetDirectoryName($GameExe)

    $scriptPath = Join-NativePath $gameDir 'Mods' 'TarteMeter' 'DPSWindow.ps1'



    try {

        foreach ($process in Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @("powershell.exe", "pwsh.exe") }) {

            $commandLine = [string]$process.CommandLine

            if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }

            if (

                $commandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or

                (

                    ($commandLine.IndexOf('DPSWindow.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $commandLine.IndexOf('OverlayBootstrap.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and

                    $commandLine.IndexOf('TarteMeter', [StringComparison]::OrdinalIgnoreCase) -ge 0

                )

            ) {

                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue

                Write-SetupLog ("Stopped the previous TarteMeter overlay process (PID {0})." -f $process.ProcessId)

            }

        }

        Start-Sleep -Milliseconds 250

    }

    catch {

        Write-SetupLog ("Overlay process cleanup was skipped: " + $_.Exception.Message)

    }

}



function Start-TarteMeterOverlay {

    param(

        [string]$GameExe,

        [bool]$WaitForReady = $true

    )



    $GameExe = Normalize-GameExePath $GameExe

    if (-not (Test-GameExe $GameExe)) { return $false }



    $gameDir = [IO.Path]::GetDirectoryName($GameExe)

    $modDir = Join-NativePath $gameDir 'Mods' 'TarteMeter'

    $bootstrapPath = Join-NativePath $modDir 'OverlayBootstrap.ps1'

    $readyPath = Join-NativePath $modDir 'window_ready.flag'

    $startupError = Join-NativePath $modDir 'startup_error.txt'

    $diagnosticPath = Join-NativePath $modDir 'startup_diagnostic.txt'

    $launcherError = Join-NativePath $modDir 'window_launcher_error.txt'



    if (-not [IO.File]::Exists($bootstrapPath)) {

        throw 'OverlayBootstrap.ps1 was not installed.'

    }



    Stop-TarteMeterOverlay $GameExe

    foreach ($path in @(

        $readyPath,

        $startupError,

        $diagnosticPath,

        $launcherError

    )) {

        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue

    }



    $powershellPath = Join-NativePath `
        $env:SystemRoot `
        'System32' `
        'WindowsPowerShell' `
        'v1.0' `
        'powershell.exe'

    if (-not [IO.File]::Exists($powershellPath)) {

        $powershellPath = 'powershell.exe'

    }



    $startInfo = New-Object Diagnostics.ProcessStartInfo

    $startInfo.FileName = $powershellPath

    $startInfo.Arguments = (

        '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA ' +

        '-WindowStyle Hidden -File "' +

        $bootstrapPath.Replace('"', '""') +

        '"'

    )

    $startInfo.WorkingDirectory = $modDir

    $startInfo.UseShellExecute = $false

    $startInfo.CreateNoWindow = $true

    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden



    $process = New-Object Diagnostics.Process

    $process.StartInfo = $startInfo

    if (-not $process.Start()) {

        throw 'Windows did not start the TarteMeter overlay process.'

    }



    Write-SetupLog (

        "Started TarteMeter overlay process (PID {0})." -f

        $process.Id

    )



    if (-not $WaitForReady) { return $true }



    for ($attempt = 0; $attempt -lt 200; $attempt++) {

        if ([IO.File]::Exists($readyPath)) {

            Write-SetupLog 'TarteMeter confirmed that its window is ready.'

            return $true

        }



        if ([IO.File]::Exists($startupError)) {

            $details = [IO.File]::ReadAllText($startupError)

            throw (

                "TarteMeter could not open.`r`n`r`n" +

                $details

            )

        }



        if ([IO.File]::Exists($launcherError)) {

            $details = [IO.File]::ReadAllText($launcherError)

            throw (

                "The TarteMeter launcher failed.`r`n`r`n" +

                $details

            )

        }



        if ($process.HasExited) {

            $diagnostic = if ([IO.File]::Exists($diagnosticPath)) {

                [IO.File]::ReadAllText($diagnosticPath)

            }

            else {

                'No startup diagnostic was produced.'

            }



            $failureText = (

                "TarteMeter exited before its window became ready.`r`n" +

                "Exit code: " + $process.ExitCode + "`r`n`r`n" +

                $diagnostic

            )

            [IO.File]::WriteAllText(

                $startupError,

                $failureText,

                $script:Utf8NoBom

            )

            throw $failureText

        }



        Start-Sleep -Milliseconds 100

        [Windows.Forms.Application]::DoEvents()

    }



    $diagnostic = if ([IO.File]::Exists($diagnosticPath)) {

        [IO.File]::ReadAllText($diagnosticPath)

    }

    else {

        'The bootstrap did not create a diagnostic file.'

    }



    $timeoutText = (

        "TarteMeter did not report a visible window within 20 seconds.`r`n" +

        "Process ID: " + $process.Id + "`r`n`r`n" +

        $diagnostic

    )

    [IO.File]::WriteAllText(

        $startupError,

        $timeoutText,

        $script:Utf8NoBom

    )

    Write-SetupLog 'TarteMeter did not report ready within 20 seconds.'

    return $false

}



# ---------------------------- USER INTERFACE ----------------------------

$form = New-Object Windows.Forms.Form

$form.Text = "TarteMeter $script:Version Setup"

$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen

$form.ClientSize = New-Object Drawing.Size(780, 534)

$form.MinimumSize = New-Object Drawing.Size(796, 573)

$form.MaximizeBox = $false

$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle

$form.BackColor = [Drawing.Color]::FromArgb(16, 23, 34)

$form.ForeColor = [Drawing.Color]::FromArgb(235, 241, 247)

$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi



$iconPath = Join-NativePath $script:ModPayload 'Assets' 'TarteMeter.ico'

$logoPath = Join-NativePath $script:ModPayload 'Assets' 'tarte.png'

$setupIcon = $null

if ([IO.File]::Exists($iconPath)) {

    try {

        $setupIcon = New-Object Drawing.Icon -ArgumentList $iconPath

        $form.Icon = $setupIcon

    }

    catch {}

}



$header = New-Object Windows.Forms.Panel

$header.Location = New-Object Drawing.Point(0, 0)

$header.Size = New-Object Drawing.Size(780, 78)

$header.BackColor = [Drawing.Color]::FromArgb(22, 32, 46)

$form.Controls.Add($header)



$iconBox = New-Object Windows.Forms.PictureBox

$iconBox.Location = New-Object Drawing.Point(20, 13)

$iconBox.Size = New-Object Drawing.Size(52, 52)

$iconBox.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom

$setupLogo = Load-BitmapUnlocked $logoPath

if ($null -ne $setupLogo) { $iconBox.Image = $setupLogo }

$header.Controls.Add($iconBox)



$title = New-Object Windows.Forms.Label

$title.Text = 'TarteMeter Setup'

$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 19)

$title.ForeColor = [Drawing.Color]::FromArgb(235, 201, 129)

$title.Location = New-Object Drawing.Point(86, 12)

$title.AutoSize = $true

$header.Controls.Add($title)



$versionLabel = New-Object Windows.Forms.Label

$versionLabel.Text = "Version $script:Version  |  DragonSword: Awakening DPS meter"

$versionLabel.ForeColor = [Drawing.Color]::FromArgb(145, 164, 185)

$versionLabel.Location = New-Object Drawing.Point(89, 49)

$versionLabel.AutoSize = $true

$header.Controls.Add($versionLabel)



$pathPanel = New-Object Windows.Forms.Panel

$pathPanel.Location = New-Object Drawing.Point(18, 92)

$pathPanel.Size = New-Object Drawing.Size(744, 102)

$pathPanel.BackColor = [Drawing.Color]::FromArgb(23, 34, 48)

$form.Controls.Add($pathPanel)



$pathTitle = New-Object Windows.Forms.Label

$pathTitle.Text = 'DRAGONSWORD INSTALLATION'

$pathTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)

$pathTitle.ForeColor = [Drawing.Color]::FromArgb(235, 201, 129)

$pathTitle.Location = New-Object Drawing.Point(14, 10)

$pathTitle.AutoSize = $true

$pathPanel.Controls.Add($pathTitle)



$pathBox = New-Object Windows.Forms.TextBox

$pathBox.Location = New-Object Drawing.Point(16, 31)

$pathBox.Size = New-Object Drawing.Size(598, 24)

$pathBox.BackColor = [Drawing.Color]::FromArgb(11, 18, 28)

$pathBox.ForeColor = [Drawing.Color]::White

$pathBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle

$pathPanel.Controls.Add($pathBox)



$browseButton = New-Object Windows.Forms.Button

$browseButton.Text = 'Browse...'

$browseButton.Location = New-Object Drawing.Point(625, 29)

$browseButton.Size = New-Object Drawing.Size(102, 28)

Set-FlatButton $browseButton ([Drawing.Color]::FromArgb(46, 67, 89)) ([Drawing.Color]::White)

$pathPanel.Controls.Add($browseButton)



$pathState = New-Object Windows.Forms.Label

$pathState.Text = 'Searching for DragonSword: Awakening...'

$pathState.Location = New-Object Drawing.Point(16, 62)

$pathState.Size = New-Object Drawing.Size(710, 18)

$pathState.ForeColor = [Drawing.Color]::FromArgb(154, 174, 195)

$pathPanel.Controls.Add($pathState)



$closeGameHint = New-Object Windows.Forms.Label

$closeGameHint.Text = 'Close DragonSword before installing, updating, removing, or repairing files.'

$closeGameHint.Location = New-Object Drawing.Point(16, 80)

$closeGameHint.Size = New-Object Drawing.Size(710, 18)

$closeGameHint.ForeColor = [Drawing.Color]::FromArgb(229, 174, 103)

$pathPanel.Controls.Add($closeGameHint)



$installPanel = New-Object Windows.Forms.Panel

$installPanel.Location = New-Object Drawing.Point(18, 207)

$installPanel.Size = New-Object Drawing.Size(363, 218)

$installPanel.BackColor = [Drawing.Color]::FromArgb(23, 34, 48)

$form.Controls.Add($installPanel)



$installTitle = New-Object Windows.Forms.Label

$installTitle.Text = 'INSTALL / UPDATE'

$installTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)

$installTitle.ForeColor = [Drawing.Color]::FromArgb(235, 201, 129)

$installTitle.Location = New-Object Drawing.Point(16, 14)

$installTitle.AutoSize = $true

$installPanel.Controls.Add($installTitle)



$installInfo = New-Object Windows.Forms.Label

$installInfo.Text = "Installs or updates TarteMeter. UE4SS is added only when required.`r`nBattle history, settings, hotkeys, themes, and unrelated mods are preserved."

$installInfo.Location = New-Object Drawing.Point(16, 43)

$installInfo.Size = New-Object Drawing.Size(330, 48)

$installInfo.ForeColor = [Drawing.Color]::FromArgb(183, 197, 212)

$installPanel.Controls.Add($installInfo)



$repairCheck = New-Object Windows.Forms.CheckBox

$repairCheck.Text = 'Repair UE4SS files (advanced)'

$repairCheck.Location = New-Object Drawing.Point(17, 103)

$repairCheck.Size = New-Object Drawing.Size(324, 22)

$repairCheck.ForeColor = [Drawing.Color]::FromArgb(218, 226, 235)

$repairCheck.BackColor = $installPanel.BackColor

$installPanel.Controls.Add($repairCheck)



$repairHint = New-Object Windows.Forms.Label

$repairHint.Text = 'Use only when UE4SS is damaged or no longer starts.'

$repairHint.Location = New-Object Drawing.Point(36, 126)

$repairHint.Size = New-Object Drawing.Size(306, 34)

$repairHint.ForeColor = [Drawing.Color]::FromArgb(126, 145, 166)

$installPanel.Controls.Add($repairHint)



$installButton = New-Object Windows.Forms.Button

$installButton.Text = 'Install or Update TarteMeter'

$installButton.Location = New-Object Drawing.Point(16, 166)

$installButton.Size = New-Object Drawing.Size(331, 32)

Set-FlatButton $installButton ([Drawing.Color]::FromArgb(52, 93, 124)) ([Drawing.Color]::White)

$installPanel.Controls.Add($installButton)



$removePanel = New-Object Windows.Forms.Panel

$removePanel.Location = New-Object Drawing.Point(399, 207)

$removePanel.Size = New-Object Drawing.Size(363, 218)

$removePanel.BackColor = [Drawing.Color]::FromArgb(23, 34, 48)

$form.Controls.Add($removePanel)



$removeTitle = New-Object Windows.Forms.Label

$removeTitle.Text = 'REMOVE'

$removeTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)

$removeTitle.ForeColor = [Drawing.Color]::FromArgb(225, 144, 132)

$removeTitle.Location = New-Object Drawing.Point(16, 14)

$removeTitle.AutoSize = $true

$removePanel.Controls.Add($removeTitle)



$removeInfo = New-Object Windows.Forms.Label

$removeInfo.Text = "Removes TarteMeter from the selected game folder.`r`nBattle history, exports, themes, hotkeys, and window settings are preserved."

$removeInfo.Location = New-Object Drawing.Point(16, 43)

$removeInfo.Size = New-Object Drawing.Size(330, 48)

$removeInfo.ForeColor = [Drawing.Color]::FromArgb(183, 197, 212)

$removePanel.Controls.Add($removeInfo)



$removeUE4SSCheck = New-Object Windows.Forms.CheckBox

$removeUE4SSCheck.Text = 'Also remove UE4SS files installed by this setup'

$removeUE4SSCheck.Location = New-Object Drawing.Point(17, 103)

$removeUE4SSCheck.Size = New-Object Drawing.Size(330, 22)

$removeUE4SSCheck.ForeColor = [Drawing.Color]::FromArgb(239, 190, 126)

$removeUE4SSCheck.BackColor = $removePanel.BackColor

$removePanel.Controls.Add($removeUE4SSCheck)



$removeHint = New-Object Windows.Forms.Label

$removeHint.Text = 'This may disable other UE4SS mods. Backed-up files will be restored.'

$removeHint.Location = New-Object Drawing.Point(36, 126)

$removeHint.Size = New-Object Drawing.Size(306, 36)

$removeHint.ForeColor = [Drawing.Color]::FromArgb(150, 157, 168)

$removePanel.Controls.Add($removeHint)



$removeButton = New-Object Windows.Forms.Button

$removeButton.Text = 'Remove TarteMeter'

$removeButton.Location = New-Object Drawing.Point(16, 171)

$removeButton.Size = New-Object Drawing.Size(331, 34)

Set-FlatButton $removeButton ([Drawing.Color]::FromArgb(112, 55, 57)) ([Drawing.Color]::White)

$removePanel.Controls.Add($removeButton)



$statusPanel = New-Object Windows.Forms.Panel

$statusPanel.Location = New-Object Drawing.Point(18, 438)

$statusPanel.Size = New-Object Drawing.Size(744, 50)

$statusPanel.BackColor = [Drawing.Color]::FromArgb(12, 19, 29)

$form.Controls.Add($statusPanel)



$statusCaption = New-Object Windows.Forms.Label

$statusCaption.Text = 'STATUS'

$statusCaption.Font = New-Object Drawing.Font('Segoe UI Semibold', 8)

$statusCaption.ForeColor = [Drawing.Color]::FromArgb(126, 145, 166)

$statusCaption.Location = New-Object Drawing.Point(14, 8)

$statusCaption.AutoSize = $true

$statusPanel.Controls.Add($statusCaption)



$statusLabel = New-Object Windows.Forms.Label

$statusLabel.Text = 'Ready.'

$statusLabel.Location = New-Object Drawing.Point(14, 25)

$statusLabel.Size = New-Object Drawing.Size(710, 18)

$statusLabel.ForeColor = [Drawing.Color]::FromArgb(174, 190, 207)

$statusPanel.Controls.Add($statusLabel)

$script:StatusLabel = $statusLabel



$detailsButton = New-Object Windows.Forms.Button

$detailsButton.Text = 'Show details'

$detailsButton.Location = New-Object Drawing.Point(18, 486)

$detailsButton.Size = New-Object Drawing.Size(112, 27)

Set-FlatButton $detailsButton ([Drawing.Color]::FromArgb(37, 51, 69)) ([Drawing.Color]::FromArgb(218, 226, 235))

$form.Controls.Add($detailsButton)



$launchButton = New-Object Windows.Forms.Button

$launchButton.Text = 'Launch TarteMeter'

$launchButton.Location = New-Object Drawing.Point(142, 486)

$launchButton.Size = New-Object Drawing.Size(146, 27)

Set-FlatButton $launchButton ([Drawing.Color]::FromArgb(45, 86, 106)) ([Drawing.Color]::White)

$form.Controls.Add($launchButton)



$closeButton = New-Object Windows.Forms.Button

$closeButton.Text = 'Close'

$closeButton.Location = New-Object Drawing.Point(650, 486)

$closeButton.Size = New-Object Drawing.Size(112, 27)

Set-FlatButton $closeButton ([Drawing.Color]::FromArgb(46, 57, 70)) ([Drawing.Color]::White)

$form.Controls.Add($closeButton)



$detailsBox = New-Object Windows.Forms.RichTextBox

$detailsBox.Location = New-Object Drawing.Point(18, 528)

$detailsBox.Size = New-Object Drawing.Size(744, 150)

$detailsBox.ReadOnly = $true

$detailsBox.BackColor = [Drawing.Color]::FromArgb(8, 13, 21)

$detailsBox.ForeColor = [Drawing.Color]::FromArgb(206, 218, 231)

$detailsBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle

$detailsBox.Font = New-Object Drawing.Font('Consolas', 8.5)

$detailsBox.Visible = $false

$form.Controls.Add($detailsBox)

$script:LogBox = $detailsBox



function Update-PathState {

    $state = Get-InstallStateText $pathBox.Text

    $pathState.Text = $state.Text

    $pathState.ForeColor = $state.Color

    $installButton.Enabled = $state.Valid

    $removeButton.Enabled = $state.Valid

}



function Set-ActionsEnabled {

    param([bool]$Enabled)

    $installButton.Enabled = $Enabled

    $removeButton.Enabled = $Enabled

    $browseButton.Enabled = $Enabled

    $pathBox.Enabled = $Enabled

    $repairCheck.Enabled = $Enabled

    $removeUE4SSCheck.Enabled = $Enabled

}



$browseButton.Add_Click({

    $dialog = New-Object Windows.Forms.OpenFileDialog

    $dialog.Title = 'Select DSClient-Win64-Shipping.exe'

    $dialog.Filter = 'DragonSword executable|DSClient-Win64-Shipping.exe'

    $dialog.CheckFileExists = $true

    $dialog.Multiselect = $false

    $dialog.RestoreDirectory = $true
    if (Test-GameExe $pathBox.Text) {
        $dialog.InitialDirectory = [IO.Path]::GetDirectoryName((Normalize-GameExePath $pathBox.Text))
    }
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = Normalize-GameExePath $dialog.FileName
        $pathBox.SelectionStart = 0
        $pathBox.SelectionLength = 0
    }

})



$pathBox.Add_TextChanged({ Update-PathState })



$detailsButton.Add_Click({

    if ($detailsBox.Visible) {

        $detailsBox.Visible = $false

        $form.ClientSize = New-Object Drawing.Size(780, 534)

        $detailsButton.Text = 'Show details'

    }

    else {

        $detailsBox.Visible = $true

        $form.ClientSize = New-Object Drawing.Size(780, 709)

        $detailsButton.Text = 'Hide details'

    }

})



$launchButton.Add_Click({

    $selectedGameExe = Normalize-GameExePath $pathBox.Text
    if (-not (Test-GameExe $selectedGameExe)) {

        [void][Windows.Forms.MessageBox]::Show(

            "Select DSClient-Win64-Shipping.exe first.",

            "TarteMeter Setup",

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Warning

        )

        return

    }



    try {

        Set-Status 'Launching TarteMeter...' ([Drawing.Color]::FromArgb(235, 201, 129))

        $ready = Start-TarteMeterOverlay -GameExe $selectedGameExe -WaitForReady $true

        if ($ready) {

            Set-Status 'TarteMeter is running.' ([Drawing.Color]::FromArgb(111, 201, 160))

        }

        else {

            Set-Status 'TarteMeter did not become ready.' ([Drawing.Color]::FromArgb(224, 172, 112))

        }

    }

    catch {

        Write-SetupLog ($_ | Out-String)

        Set-Status 'TarteMeter could not start.' ([Drawing.Color]::FromArgb(230, 125, 116))

        [void][Windows.Forms.MessageBox]::Show(

            $_.Exception.Message,

            "TarteMeter startup error",

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Error

        )

    }

})



$closeButton.Add_Click({ $form.Close() })



$installButton.Add_Click({

    $selectedGameExe = Normalize-GameExePath $pathBox.Text
    if (-not (Test-GameExe $selectedGameExe)) {
        [void][Windows.Forms.MessageBox]::Show(
            "Select DSClient-Win64-Shipping.exe from DS\Binaries\Win64.",
            'TarteMeter Setup',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $pathBox.Text = $selectedGameExe
    Set-ActionsEnabled $false

    Set-Status 'Installing or updating TarteMeter...' ([Drawing.Color]::FromArgb(235, 201, 129))

    try {

        $installArgs = @{
            GameExe = $selectedGameExe
            RepairUE4SS = [bool]$repairCheck.Checked
        }
        Install-TarteMeter @installArgs



        Set-Status 'Setup completed successfully.' ([Drawing.Color]::FromArgb(111, 201, 160))

        $message = (

            "TarteMeter was installed successfully.`r`n`r`n" +

            "Use the Launch TarteMeter button for an optional overlay check, " +

            "then start or restart DragonSword through Steam."

        )



        Update-PathState

        [void][Windows.Forms.MessageBox]::Show(

            $message,

            'TarteMeter Setup',

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Information

        )

    }

    catch {

        Write-SetupLog ('ERROR: ' + $_.Exception.Message)

        Set-Status 'Installation failed. Open details for more information.' ([Drawing.Color]::FromArgb(238, 126, 118))

        [void][Windows.Forms.MessageBox]::Show(

            "Installation failed.`r`n`r`n$($_.Exception.Message)`r`n`r`n" +

            "Close the game and retry. If Windows blocks access to the Steam folder, launch the installer from an administrator account.",

            'TarteMeter Setup',

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Error

        )

    }

    finally {

        Set-ActionsEnabled $true

        Update-PathState

    }

})



$removeButton.Add_Click({

    $selectedGameExe = Normalize-GameExePath $pathBox.Text
    if (-not (Test-GameExe $selectedGameExe)) {
        [void][Windows.Forms.MessageBox]::Show(
            "Select DSClient-Win64-Shipping.exe from DS\Binaries\Win64.",
            'TarteMeter Setup',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    $pathBox.Text = $selectedGameExe

    $message = "Remove TarteMeter program files?`r`n`r`n" +

        "Battle history, exports, themes, key bindings, and window settings will be preserved."

    if ($removeUE4SSCheck.Checked) {

        $message += "`r`n`r`nUE4SS files recorded as installed by this setup will also be removed or restored. This may disable other UE4SS mods."

    }



    $answer = [Windows.Forms.MessageBox]::Show(

        $message,

        'Uninstall',

        [Windows.Forms.MessageBoxButtons]::YesNo,

        [Windows.Forms.MessageBoxIcon]::Warning

    )

    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }



    Set-ActionsEnabled $false

    Set-Status 'Removing TarteMeter...' ([Drawing.Color]::FromArgb(235, 201, 129))

    try {

        $removeArgs = @{
            GameExe = $selectedGameExe
            RemoveUE4SS = [bool]$removeUE4SSCheck.Checked
        }
        Uninstall-TarteMeter @removeArgs



        Set-Status 'Removal completed successfully.' ([Drawing.Color]::FromArgb(111, 201, 160))

        Update-PathState

        $result = 'TarteMeter program files were removed. User history and settings were preserved.'

        if ($removeUE4SSCheck.Checked) {

            $result += "`r`n`r`nUE4SS files owned by this setup were removed or restored."

        }

        [void][Windows.Forms.MessageBox]::Show(

            $result,

            'TarteMeter Setup',

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Information

        )

    }

    catch {

        Write-SetupLog ('ERROR: ' + $_.Exception.Message)

        Set-Status 'Removal failed. Open details for more information.' ([Drawing.Color]::FromArgb(238, 126, 118))

        [void][Windows.Forms.MessageBox]::Show(

            "Removal failed.`r`n`r`n$($_.Exception.Message)",

            'TarteMeter Setup',

            [Windows.Forms.MessageBoxButtons]::OK,

            [Windows.Forms.MessageBoxIcon]::Error

        )

    }

    finally {

        Set-ActionsEnabled $true

        Update-PathState

    }

})



try {

    $detected = Find-DragonSwordExe

    if ($null -ne $detected) {

        $pathBox.Text = $detected

        Write-SetupLog 'DragonSword installation was detected automatically.'

    }

    else {

        Write-SetupLog 'Automatic detection did not find the game. Use Browse and select DSClient-Win64-Shipping.exe.'

        Update-PathState

    }

}

catch {

    Write-SetupLog ('Automatic detection was skipped: ' + $_.Exception.Message)

    Write-SetupLog 'Use Browse and select DSClient-Win64-Shipping.exe manually.'

    Update-PathState

}



$form.Add_FormClosed({

    if ($null -ne $setupLogo) { $setupLogo.Dispose() }

    if ($null -ne $setupIcon) { $setupIcon.Dispose() }

})



Set-Status 'Ready.'

[void]$form.ShowDialog()

exit 0

