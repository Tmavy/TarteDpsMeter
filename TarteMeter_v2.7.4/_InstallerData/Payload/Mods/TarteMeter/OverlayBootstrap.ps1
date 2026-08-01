$ErrorActionPreference = "Stop"

$modDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowScript = Join-Path $modDir "DPSWindow.ps1"
$readyPath = Join-Path $modDir "window_ready.flag"
$errorPath = Join-Path $modDir "startup_error.txt"
$diagnosticPath = Join-Path $modDir "startup_diagnostic.txt"
$launcherErrorPath = Join-Path $modDir "window_launcher_error.txt"
$windowErrorPath = Join-Path $modDir "window_error.txt"
$windowBuildPath = Join-Path $modDir "window_build.txt"
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function Write-BootstrapDiagnostic {
    param([string]$Stage, [string]$Details = "")

    try {
        $line = "[{0}] {1}" -f (
            [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff")
        ), $Stage
        if (-not [string]::IsNullOrWhiteSpace($Details)) {
            $line += " | " + $Details
        }
        [IO.File]::AppendAllText(
            $diagnosticPath,
            $line + [Environment]::NewLine,
            $utf8NoBom
        )
    }
    catch {}
}

try {
    foreach ($path in @(
        $readyPath,
        $errorPath,
        $launcherErrorPath,
        $windowErrorPath,
        $windowBuildPath,
        $diagnosticPath
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    Write-BootstrapDiagnostic "Bootstrap started" (
        "PowerShell " + $PSVersionTable.PSVersion
    )
    Write-BootstrapDiagnostic "Mod directory" $modDir

    if (-not [IO.File]::Exists($windowScript)) {
        throw "DPSWindow.ps1 is missing: $windowScript"
    }

    Write-BootstrapDiagnostic "Starting DPSWindow.ps1"
    . $windowScript
    Write-BootstrapDiagnostic "DPSWindow.ps1 returned normally"
    exit 0
}
catch {
    $details = (
        "TarteMeter failed to start." + [Environment]::NewLine +
        "Time: " + [DateTime]::Now.ToString("o") + [Environment]::NewLine +
        "PowerShell: " + $PSVersionTable.PSVersion + [Environment]::NewLine +
        "Mod folder: " + $modDir + [Environment]::NewLine +
        [Environment]::NewLine +
        ($_ | Out-String)
    )

    try {
        [IO.File]::WriteAllText($errorPath, $details, $utf8NoBom)
    }
    catch {}

    Write-BootstrapDiagnostic "FATAL STARTUP ERROR" $_.Exception.Message

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][Windows.MessageBox]::Show(
            "TarteMeter could not open." + [Environment]::NewLine +
            "See startup_error.txt in Mods\\TarteMeter.",
            "TarteMeter startup error",
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
    }
    catch {}

    exit 1
}
