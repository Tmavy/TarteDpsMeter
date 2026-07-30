param([string]$GameExe = "")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

if ([string]::IsNullOrWhiteSpace($GameExe)) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = "Select DSClient-Win64-Shipping.exe"
    $d.Filter = "DragonSword executable|DSClient-Win64-Shipping.exe"
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $GameExe = $d.FileName
}

$gameDir = Split-Path -Parent $GameExe
$sourceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Recovery_Game_Files"

foreach ($name in @(
    "amd_fidelityfx_framegeneration_dx12.dll",
    "amd_fidelityfx_upscaler_dx12.dll"
)) {
    $source = Join-Path $sourceDir $name
    if (-not (Test-Path $source)) { throw "Recovery file missing: $name" }
    Copy-Item $source (Join-Path $gameDir $name) -Force
}

[System.Windows.MessageBox]::Show(
    "DragonSword FidelityFX files were restored.`n`nTry launching the game. If it still crashes, verify/repair the game files in the launcher.",
    "TarteMeter Recovery"
) | Out-Null
