$ErrorActionPreference = "Stop"

# UI_VARIANT_COMPACT

# TITLEBAR_VECTOR_CONTROLS_V313

$script:uiVariant = "COMPACT"



$statePath = Join-Path $PSScriptRoot "dps_state.txt"

$commandPath = Join-Path $PSScriptRoot "dps_command.txt"

$historyPath = Join-Path $PSScriptRoot "battle_history.jsonl"

$historyIndexPath = Join-Path $PSScriptRoot "battle_history_index.tsv"

$historyIndexMarkerPath = Join-Path $PSScriptRoot "history_index_v1.ready"

$timelineArchiveRoot = Join-Path $PSScriptRoot "battle_timelines"

$errorPath = Join-Path $PSScriptRoot "window_error.txt"

$startupErrorPath = Join-Path $PSScriptRoot "startup_error.txt"

$startupDiagnosticPath = Join-Path $PSScriptRoot "startup_diagnostic.txt"

$readyPath = Join-Path $PSScriptRoot "window_ready.flag"

$showRequestPath = Join-Path $PSScriptRoot "overlay_show.request"

$iconPath = Join-Path $PSScriptRoot "Assets\TarteMeter.ico"

$portraitPath = Join-Path $PSScriptRoot "Assets\tarte.png"

$bannerPath = Join-Path $PSScriptRoot "Assets\banner.png"

$settingsPath = Join-Path $PSScriptRoot "window_settings_v14_compact.ini"

$legacySettingsPathV7 = Join-Path $PSScriptRoot "window_settings_v7.ini"

$legacySettingsPathV6 = Join-Path $PSScriptRoot "window_settings_v6.ini"

$legacySettingsPathV5 = Join-Path $PSScriptRoot "window_settings_v5.ini"

$legacySettingsPathV4 = Join-Path $PSScriptRoot "window_settings_v4.ini"

$legacySettingsPathV3 = Join-Path $PSScriptRoot "window_settings_v3.ini"

$windowBuildPath = Join-Path $PSScriptRoot "window_build.txt"

$runtimeVersionPath = Join-Path $PSScriptRoot "runtime_version.txt"



function Write-StartupDiagnostic {

    param([string]$Stage, [string]$Details = "")



    try {

        $line = "[{0}] {1}" -f [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff"), $Stage

        if (-not [string]::IsNullOrWhiteSpace($Details)) {

            $line += " | " + $Details

        }

        [IO.File]::AppendAllText(

            $startupDiagnosticPath,

            $line + [Environment]::NewLine,

            [Text.Encoding]::UTF8

        )

    }

    catch {}

}



try { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue } catch {}

Write-StartupDiagnostic "DPSWindow.ps1 entered" ("PowerShell " + $PSVersionTable.PSVersion)

Write-StartupDiagnostic "Startup architecture" "detached PowerShell; overlay mutex v313; build 3.1.3; UI COMPACT"



$createdNew = $false

$instanceMutex = New-Object System.Threading.Mutex(

    $true,

    "Local\TarteMeterOverlay_v313",

    [ref]$createdNew

)

if (-not $createdNew) {

    try {

        [IO.File]::WriteAllText(

            $showRequestPath,

            [DateTime]::Now.ToString("o"),

            [Text.Encoding]::ASCII

        )

    }

    catch {}

    Write-StartupDiagnostic "Existing overlay instance detected" "Requested the existing window to show"

    $instanceMutex.Dispose()

    return

}



Add-Type -AssemblyName PresentationFramework

Add-Type -AssemblyName PresentationCore

Add-Type -AssemblyName WindowsBase

Write-StartupDiagnostic "WPF assemblies loaded"



Add-Type @"

using System;

using System.IO;

using System.Text;

using System.Collections.Generic;

using System.Runtime.InteropServices;

public static class TarteNative

{

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]

    public static extern int SetCurrentProcessExplicitAppUserModelID(

        string appID

    );



    public const int GWL_EXSTYLE = -20;

    public const int WS_EX_TRANSPARENT = 0x20;

    public const int WS_EX_LAYERED = 0x80000;

    public const int WM_HOTKEY = 0x0312;

    public const int SW_HIDE = 0;

    public const int SW_SHOW = 5;

    public const int SW_RESTORE = 9;

    public const uint MOD_ALT = 0x0001;

    public const uint MOD_CONTROL = 0x0002;

    public const uint MOD_SHIFT = 0x0004;

    public const uint MOD_WIN = 0x0008;

    public const uint MOD_NOREPEAT = 0x4000;



    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")]

    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);



    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")]

    public static extern IntPtr SetWindowLongPtr(

        IntPtr hWnd, int nIndex, IntPtr newStyle

    );



    [DllImport("user32.dll")]

    public static extern bool RegisterHotKey(

        IntPtr hWnd, int id, uint modifiers, uint virtualKey

    );



    [DllImport("user32.dll")]

    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);



    [DllImport("user32.dll")]

    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);



    [DllImport("user32.dll")]

    public static extern bool IsWindowVisible(IntPtr hWnd);



    [DllImport("user32.dll")]

    public static extern bool SetForegroundWindow(IntPtr hWnd);



    [DllImport("user32.dll")]

    public static extern bool BringWindowToTop(IntPtr hWnd);



    [StructLayout(LayoutKind.Sequential)]

    public struct POINT

    {

        public int X;

        public int Y;

    }



    [DllImport("user32.dll")]

    public static extern bool GetCursorPos(out POINT point);



    [DllImport("user32.dll")]

    public static extern bool ReleaseCapture();



    [DllImport("user32.dll")]

    public static extern IntPtr SendMessage(

        IntPtr hWnd,

        int Msg,

        IntPtr wParam,

        IntPtr lParam

    );

}



public sealed class TarteLineSlice

{

    public long Offset { get; set; }

    public int Length { get; set; }

}



public static class TarteFileIndex

{

    private static FileStream OpenShared(string path)

    {

        return new FileStream(

            path,

            FileMode.Open,

            FileAccess.Read,

            FileShare.ReadWrite | FileShare.Delete

        );

    }



    public static TarteLineSlice[] GetLastUtf8LineSlices(

        string path,

        int maximumLines

    )

    {

        if (maximumLines <= 0 || !File.Exists(path))

            return new TarteLineSlice[0];



        using (FileStream stream = OpenShared(path))

        {

            long length = stream.Length;

            if (length <= 0) return new TarteLineSlice[0];



            List<long> newlines = new List<long>(maximumLines + 2);

            byte[] buffer = new byte[65536];

            long cursor = length;



            while (cursor > 0 && newlines.Count < maximumLines + 2)

            {

                int readSize = (int)Math.Min(buffer.Length, cursor);

                cursor -= readSize;

                stream.Position = cursor;

                int received = 0;

                while (received < readSize)

                {

                    int count = stream.Read(

                        buffer,

                        received,

                        readSize - received

                    );

                    if (count <= 0) break;

                    received += count;

                }



                for (int index = received - 1; index >= 0; index--)

                {

                    if (buffer[index] == 10)

                    {

                        newlines.Add(cursor + index);

                        if (newlines.Count >= maximumLines + 2) break;

                    }

                }

            }



            long lineEnd = length;

            if (lineEnd > 0)

            {

                stream.Position = lineEnd - 1;

                if (stream.ReadByte() == 10) lineEnd--;

            }



            List<TarteLineSlice> reversed =

                new List<TarteLineSlice>(maximumLines);



            foreach (long newline in newlines)

            {

                if (newline >= lineEnd) continue;

                long lineStart = newline + 1;

                long rawLength = lineEnd - lineStart;

                if (rawLength > 0)

                {

                    stream.Position = lineEnd - 1;

                    if (stream.ReadByte() == 13) rawLength--;

                }

                if (rawLength > 0 && rawLength <= Int32.MaxValue)

                {

                    reversed.Add(new TarteLineSlice {

                        Offset = lineStart,

                        Length = (int)rawLength

                    });

                }

                lineEnd = newline;

                if (reversed.Count >= maximumLines) break;

            }



            if (reversed.Count < maximumLines && lineEnd > 0)

            {

                long rawLength = lineEnd;

                if (rawLength > 0)

                {

                    stream.Position = rawLength - 1;

                    if (stream.ReadByte() == 13) rawLength--;

                }

                if (rawLength > 0 && rawLength <= Int32.MaxValue)

                {

                    reversed.Add(new TarteLineSlice {

                        Offset = 0,

                        Length = (int)rawLength

                    });

                }

            }



            reversed.Reverse();

            return reversed.ToArray();

        }

    }



    public static string ReadUtf8Prefix(

        string path,

        long offset,

        int length,

        int maximumBytes

    )

    {

        if (length <= 0 || maximumBytes <= 0) return String.Empty;

        int requested = Math.Min(length, maximumBytes);

        using (FileStream stream = OpenShared(path))

        {

            if (offset < 0 || offset > stream.Length)

                throw new ArgumentOutOfRangeException("offset");

            if (offset + requested > stream.Length)

                requested = (int)Math.Max(0, stream.Length - offset);



            byte[] data = new byte[requested];

            stream.Position = offset;

            int received = 0;

            while (received < requested)

            {

                int count = stream.Read(data, received, requested - received);

                if (count <= 0) break;

                received += count;

            }

            return new UTF8Encoding(false, false).GetString(data, 0, received);

        }

    }



    public static string ReadUtf8Slice(

        string path,

        long offset,

        int length

    )

    {

        if (length <= 0) return String.Empty;

        using (FileStream stream = OpenShared(path))

        {

            if (offset < 0 || offset > stream.Length)

                throw new ArgumentOutOfRangeException("offset");

            if (offset + length > stream.Length)

                throw new EndOfStreamException("History record is incomplete.");



            byte[] data = new byte[length];

            stream.Position = offset;

            int received = 0;

            while (received < length)

            {

                int count = stream.Read(data, received, length - received);

                if (count <= 0) throw new EndOfStreamException();

                received += count;

            }

            return new UTF8Encoding(false, true).GetString(data);

        }

    }

}



"@



$script:brushCache = @{}

$script:windowHandle = [IntPtr]::Zero

$script:clickThroughEnabled = $false

$script:syncingClickThroughCheck = $false

$script:syncingTopmostCheck = $false

$script:characterRowCache = @{}

$script:selectedBattle = $null

$script:lastStateStamp = ""

$script:lastHistoryStamp = ""

$script:lastHistoryDataStamp = ""

$script:historyIndexInitialized = $false

$script:lastHistoryIndexSyncSucceeded = $false

$script:historyOffsetCacheLoaded = $false

$script:indexedHistoryOffsets = @{}

$script:syncingHistorySelection = $false

$script:syncingColumnWidths = $false

$script:columnWidthHandlers = New-Object 'System.Collections.Generic.List[object]'

$script:resetUiPending = $false

$script:resetRequestTime = [datetime]::MinValue

$script:lastErrorText = ""

$script:lastErrorWrite = [datetime]::MinValue

$script:resetHotkeyId = 0x5441

$script:overlayHotkeyId = 0x5442

$script:passHotkeyId = 0x5443

$script:hotkeysRegistered = $false

$script:syncingHotkeyControls = $false

$script:overlayVisible = $true

$script:lastSettingsSaveSucceeded = $true

$script:forceClose = $false

$script:gameProcessName = "DSClient-Win64-Shipping"

$script:gameProcessId = 0

$script:gameProcessStartTime = $null

$script:gameWatchInitialized = $false

$script:maxHistoryRows = 200

$script:historyIndexPrefixBytes = 65536

$script:maxTimelineMarkers = 500

$script:maxEventRows = 2500

$script:themeNames = @(

    "MIDNIGHT GOLD",

    "OBSIDIAN VIOLET",

    "GRAPHITE TEAL"

)

$script:settings = [ordered]@{

    Opacity = 92.0

    TextScale = 100.0

    Topmost = $true

    ClickThrough = $false

    Theme = "MIDNIGHT GOLD"

    ResetHotkey = "F6"

    OverlayHotkey = "F9"

    PassHotkey = "F10"

    LogTimelineHeight = 92.0

    DamageColumnWidths = @(150, 74, 64, 96, 48, 54, 70, 70)

    HistoryColumnWidths = @(124, 160, 58, 78, 68, 82)

    LogColumnWidths = @(32, 145, 76, 66, 96, 54, 48, 70, 70)

}



function Initialize-GameProcessWatch {

    try {

        $candidates = @(

            Get-Process -Name $script:gameProcessName -ErrorAction SilentlyContinue |

                Sort-Object StartTime -Descending

        )



        if ($candidates.Count -le 0) {

            Write-StartupDiagnostic "Game process watch" (

                "No running " + $script:gameProcessName + " process was found; " +

                "automatic shutdown is disabled for this overlay instance."

            )

            $script:gameWatchInitialized = $true

            return

        }



        $gameProcess = $candidates[0]

        $script:gameProcessId = [int]$gameProcess.Id

        try { $script:gameProcessStartTime = $gameProcess.StartTime }

        catch { $script:gameProcessStartTime = $null }

        $script:gameWatchInitialized = $true



        Write-StartupDiagnostic "Game process watch" (

            "Watching PID " + $script:gameProcessId +

            " (" + $script:gameProcessName + ")"

        )

    }

    catch {

        $script:gameWatchInitialized = $true

        Write-StartupDiagnostic "Game process watch warning" $_.Exception.Message

    }

}



function Test-WatchedGameProcessAlive {

    if (-not $script:gameWatchInitialized) {

        Initialize-GameProcessWatch

    }



    if ($script:gameProcessId -le 0) {

        return $true

    }



    try {

        $process = Get-Process -Id $script:gameProcessId -ErrorAction Stop

        if ($null -ne $script:gameProcessStartTime) {

            try {

                if ($process.StartTime -ne $script:gameProcessStartTime) {

                    return $false

                }

            }

            catch {}

        }

        return (-not $process.HasExited)

    }

    catch {

        return $false

    }

}



function Close-OverlayProcess {

    param([string]$Reason)



    if ($script:forceClose) { return }

    $script:forceClose = $true

    Write-StartupDiagnostic "Overlay process closing" $Reason



    try { $window.Close() }

    catch {

        Write-StartupDiagnostic "Overlay close warning" $_.Exception.Message

        try {

            [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()

        }

        catch {}

    }

}



function Convert-ToNumber {

    param([object]$Value)



    $number = 0.0

    [void][double]::TryParse(

        [string]$Value,

        [Globalization.NumberStyles]::Float,

        [Globalization.CultureInfo]::InvariantCulture,

        [ref]$number

    )

    return $number

}



function Convert-ToBoolean {

    param([object]$Value, [bool]$Fallback)



    $parsed = $false

    if ([bool]::TryParse([string]$Value, [ref]$parsed)) {

        return $parsed

    }

    return $Fallback

}



function Convert-ToColumnWidthArray {

    param(

        [string]$Value,

        [int]$ExpectedCount,

        [double[]]$Fallback

    )



    if ([string]::IsNullOrWhiteSpace($Value)) {

        return @($Fallback)

    }



    $parts = @($Value -split ",")

    if ($parts.Count -ne $ExpectedCount) {

        return @($Fallback)

    }



    $result = New-Object 'System.Collections.Generic.List[double]'

    foreach ($part in $parts) {

        $width = Convert-ToNumber $part

        if ($width -lt 28 -or $width -gt 800) {

            return @($Fallback)

        }

        $result.Add($width)

    }

    return $result.ToArray()

}



function Convert-ToWpfColor {

    param(

        [Parameter(Mandatory = $true)]

        [string]$Hex

    )



    $key = $Hex.Trim().ToUpperInvariant()

    if ($key -notmatch '^#(?:[0-9A-F]{6}|[0-9A-F]{8})$') {

        throw "Invalid WPF color value: $Hex"

    }



    return [Windows.Media.Color](

        [Windows.Media.ColorConverter]::ConvertFromString($key)

    )

}



function New-Brush {

    param(

        [Parameter(Mandatory = $true)]

        [string]$Hex

    )



    $key = $Hex.Trim().ToUpperInvariant()



    if ($script:brushCache.ContainsKey($key)) {

        return [Windows.Media.SolidColorBrush]$script:brushCache[$key]

    }



    $color = Convert-ToWpfColor -Hex $key

    $brush = [Windows.Media.SolidColorBrush]::new($color)



    if ($brush.CanFreeze) {

        $brush.Freeze()

    }



    $script:brushCache.Add($key, $brush)

    return [Windows.Media.SolidColorBrush]$brush

}



function Write-WindowError {

    param([object]$ErrorValue)



    $text = [string]($ErrorValue | Out-String)

    $now = [datetime]::UtcNow

    if (

        $text -eq $script:lastErrorText -and

        ($now - $script:lastErrorWrite).TotalSeconds -lt 5.0

    ) {

        return

    }



    $script:lastErrorText = $text

    $script:lastErrorWrite = $now

    try {

        $text | Set-Content -LiteralPath $errorPath -Encoding UTF8

    }

    catch {}

}



function Read-AllLinesShared {

    param([string]$Path)



    $shareValue = (

        [int][IO.FileShare]::ReadWrite -bor

        [int][IO.FileShare]::Delete

    )

    $share = [IO.FileShare]$shareValue

    $stream = $null

    $reader = $null



    try {

        $stream = [IO.FileStream]::new(

            $Path,

            [IO.FileMode]::Open,

            [IO.FileAccess]::Read,

            $share

        )

        $reader = [IO.StreamReader]::new(

            $stream,

            [Text.Encoding]::UTF8,

            $true

        )

        $lines = New-Object 'System.Collections.Generic.List[string]'

        while (($line = $reader.ReadLine()) -ne $null) {

            $lines.Add($line)

        }

        return $lines.ToArray()

    }

    finally {

        if ($null -ne $reader) { $reader.Dispose() }

        elseif ($null -ne $stream) { $stream.Dispose() }

    }

}



function Write-MeterCommand {

    param([string]$Command)



    try {

        $tempPath = "$commandPath.tmp"

        [IO.File]::WriteAllText(

            $tempPath,

            $Command,

            [Text.Encoding]::ASCII

        )

        Move-Item -LiteralPath $tempPath -Destination $commandPath -Force

    }

    catch {

        try {

            Set-Content `
                -LiteralPath $commandPath `
                -Value $Command `
                -Encoding ASCII `
                -Force

        }

        catch {

            Write-WindowError $_

        }

    }

}



function Request-MeterReset {

    if ($script:resetUiPending) { return }



    $script:resetUiPending = $true

    $script:resetRequestTime = [datetime]::UtcNow

    if ($null -ne $ResetButton) {

        $ResetButton.Content = "SAVING..."

        $ResetButton.IsEnabled = $false

    }

    if ($null -ne $StatusText) {

        $StatusText.Text = "SAVING ENCOUNTER..."

    }

    Write-MeterCommand "RESET"

}



function Update-ResetUiState {

    param([string]$Status)



    if ($Status -eq "SAVING") {

        $script:resetUiPending = $true

        if ($null -ne $ResetButton) {

            $ResetButton.Content = "SAVING..."

            $ResetButton.IsEnabled = $false

        }

        return

    }



    if ($script:resetUiPending) {

        $age = ([datetime]::UtcNow - $script:resetRequestTime).TotalSeconds

        if ($Status -eq "READY" -or $age -ge 3.0) {

            $script:resetUiPending = $false

            if ($null -ne $ResetButton) {

                $ResetButton.Content = "RESET {0}" -f $script:settings.ResetHotkey

                $ResetButton.IsEnabled = $true

            }

        }

    }

}



function Import-SettingsFile {

    param([string]$Path)



    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {

        return $false

    }



    foreach ($line in [IO.File]::ReadAllLines($Path)) {

        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split "=", 2

        if ($parts.Count -ne 2) { continue }



        $key = $parts[0].Trim()

        $valueText = $parts[1].Trim()

        switch ($key) {

            "Opacity" {

                $value = Convert-ToNumber $valueText

                if ($value -ge 55 -and $value -le 100) {

                    $script:settings.Opacity = $value

                }

            }

            "TextScale" {

                $value = Convert-ToNumber $valueText

                if ($value -ge 60 -and $value -le 220) {

                    $script:settings.TextScale = $value

                }

            }

            "Topmost" {

                $script:settings.Topmost = Convert-ToBoolean `
                    -Value $valueText `
                    -Fallback $script:settings.Topmost

            }

            "ClickThrough" {

                $script:settings.ClickThrough = Convert-ToBoolean `
                    -Value $valueText `
                    -Fallback $script:settings.ClickThrough

            }

            "Theme" {

                if ($script:themeNames -contains $valueText.ToUpperInvariant()) {

                    $script:settings.Theme = $valueText.ToUpperInvariant()

                }

            }

            "ResetHotkey" {

                if (-not [string]::IsNullOrWhiteSpace($valueText)) {

                    $script:settings.ResetHotkey = $valueText

                }

            }

            "OverlayHotkey" {

                if (-not [string]::IsNullOrWhiteSpace($valueText)) {

                    $script:settings.OverlayHotkey = $valueText

                }

            }

            "PassHotkey" {

                if (-not [string]::IsNullOrWhiteSpace($valueText)) {

                    $script:settings.PassHotkey = $valueText

                }

            }

            "LogTimelineHeight" {

                $value = Convert-ToNumber $valueText

                if ($value -ge 58 -and $value -le 320) {

                    $script:settings.LogTimelineHeight = $value

                }

            }

            "DamageColumnWidths" {

                $script:settings.DamageColumnWidths =

                    Convert-ToColumnWidthArray `
                        -Value $valueText `
                        -ExpectedCount 8 `
                        -Fallback $script:settings.DamageColumnWidths

            }

            "HistoryColumnWidths" {

                $script:settings.HistoryColumnWidths =

                    Convert-ToColumnWidthArray `
                        -Value $valueText `
                        -ExpectedCount 6 `
                        -Fallback $script:settings.HistoryColumnWidths

            }

            "LogColumnWidths" {

                $script:settings.LogColumnWidths =

                    Convert-ToColumnWidthArray `
                        -Value $valueText `
                        -ExpectedCount 9 `
                        -Fallback $script:settings.LogColumnWidths

            }

        }

    }

    return $true

}





function Read-WindowSettings {

    # v2.7.8 starts with a clean per-interface settings file. Older adaptive

    # layout files are deliberately ignored because they contained broken

    # column widths and system-theme control state.

    [void](Import-SettingsFile $settingsPath)

}



function Write-WindowSettings {

    try {

        $lines = New-Object 'System.Collections.Generic.List[string]'

        $lines.Add(("Opacity={0:0}" -f $script:settings.Opacity))

        $lines.Add(("TextScale={0:0}" -f $script:settings.TextScale))

        $lines.Add(("Topmost={0}" -f $script:settings.Topmost))

        $lines.Add(("ClickThrough={0}" -f $script:settings.ClickThrough))

        $lines.Add(("Theme={0}" -f $script:settings.Theme))

        $lines.Add(("ResetHotkey={0}" -f $script:settings.ResetHotkey))

        $lines.Add(("OverlayHotkey={0}" -f $script:settings.OverlayHotkey))

        $lines.Add(("PassHotkey={0}" -f $script:settings.PassHotkey))

        $lines.Add((

            "LogTimelineHeight={0:0}" -f

            $script:settings.LogTimelineHeight

        ))

        $lines.Add((

            "DamageColumnWidths={0}" -f

            ((@($script:settings.DamageColumnWidths) |

                ForEach-Object { "{0:0.##}" -f $_ }) -join ",")

        ))

        $lines.Add((

            "HistoryColumnWidths={0}" -f

            ((@($script:settings.HistoryColumnWidths) |

                ForEach-Object { "{0:0.##}" -f $_ }) -join ",")

        ))

        $lines.Add((

            "LogColumnWidths={0}" -f

            ((@($script:settings.LogColumnWidths) |

                ForEach-Object { "{0:0.##}" -f $_ }) -join ",")

        ))



        $tempPath = "$settingsPath.tmp"

        [IO.File]::WriteAllLines(

            $tempPath,

            $lines.ToArray(),

            [Text.Encoding]::ASCII

        )

        Move-Item -LiteralPath $tempPath -Destination $settingsPath -Force



        $script:lastSettingsSaveSucceeded = $true

        Write-StartupDiagnostic "Settings saved" (

            "theme={0} overlay={1} pass={2}" -f

            $script:settings.Theme,

            $script:settings.OverlayHotkey,

            $script:settings.PassHotkey

        )

        return $true

    }

    catch {

        $script:lastSettingsSaveSucceeded = $false

        Write-WindowError $_

        return $false

    }

}



Read-WindowSettings



[void][TarteNative]::SetCurrentProcessExplicitAppUserModelID(

    "TarteMeter.DragonSword.CombatAnalyzer"

)



[xml]$xaml = @'

<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib" Title="TarteMeter Compact v3.1.3" Width="560" Height="390" MinWidth="300" MinHeight="235" WindowStyle="None" WindowStartupLocation="CenterScreen" ShowInTaskbar="True" AllowsTransparency="True" Background="Transparent" ResizeMode="CanResize" Topmost="True" UseLayoutRounding="True" SnapsToDevicePixels="True" FontFamily="Segoe UI, Arial" Foreground="{DynamicResource ThemeTextBrush}">

 <Window.Resources>

  <sys:Double x:Key="MeterTextSmall">8</sys:Double>

  <sys:Double x:Key="MeterTextNormal">9</sys:Double>

  <sys:Double x:Key="MeterTextMedium">11</sys:Double>

  <sys:Double x:Key="MeterTextTitle">12</sys:Double>

  <sys:Double x:Key="MeterTextStat">14</sys:Double>

  <sys:Double x:Key="MeterRowInnerHeight">18</sys:Double>

  <sys:Double x:Key="MeterControlHeight">26</sys:Double>

  <SolidColorBrush x:Key="ThemeWindowBrush" Color="#0C121B"/>

  <SolidColorBrush x:Key="ThemeChromeBrush" Color="#121C2A"/>

  <SolidColorBrush x:Key="ThemePanelBrush" Color="#172333"/>

  <SolidColorBrush x:Key="ThemePanelAltBrush" Color="#111B28"/>

  <SolidColorBrush x:Key="ThemeGridBrush" Color="#0B131E"/>

  <SolidColorBrush x:Key="ThemeHeaderBrush" Color="#1D2B3D"/>

  <SolidColorBrush x:Key="ThemeButtonBrush" Color="#223248"/>

  <SolidColorBrush x:Key="ThemeBadgeBrush" Color="#2A3B51"/>

  <SolidColorBrush x:Key="ThemeBorderBrush" Color="#40536B"/>

  <SolidColorBrush x:Key="ThemeGridLineBrush" Color="#26374B"/>

  <SolidColorBrush x:Key="ThemeAccentBrush" Color="#D9B35F"/>

  <SolidColorBrush x:Key="ThemeAccentTextBrush" Color="#F4D991"/>

  <SolidColorBrush x:Key="ThemeTextBrush" Color="#F1F5FA"/>

  <SolidColorBrush x:Key="ThemeMutedBrush" Color="#94A6BC"/>

  <SolidColorBrush x:Key="ThemeHoverBrush" Color="#22334A"/>

  <SolidColorBrush x:Key="ThemeSelectionBrush" Color="#2B405A"/>

  <SolidColorBrush x:Key="ThemeSelectionBorderBrush" Color="#E3BF6B"/>

  <SolidColorBrush x:Key="ThemeTrackBrush" Color="#080E16"/>



  <Style x:Key="MeterButtonStyle" TargetType="Button">

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="Background" Value="{DynamicResource ThemeButtonBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorderBrush}"/>

   <Setter Property="BorderThickness" Value="1"/>

   <Setter Property="Padding" Value="8,3"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>

   <Setter Property="FontWeight" Value="SemiBold"/>

   <Setter Property="MinHeight" Value="{DynamicResource MeterControlHeight}"/>

   <Setter Property="Cursor" Value="Hand"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="Button">

      <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3" Padding="{TemplateBinding Padding}">

       <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>

      </Border>

      <ControlTemplate.Triggers>

       <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource ThemeHoverBrush}"/><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource ThemeAccentBrush}"/></Trigger>

       <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/></Trigger>

       <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>

      </ControlTemplate.Triggers>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>

  <Style TargetType="Button" BasedOn="{StaticResource MeterButtonStyle}"/>



  <!-- Fixed-size vector-font title controls. They do not scale with meter text,

       so the hit targets and glyph alignment remain stable at every UI scale. -->

  <Style x:Key="TitleBarButtonStyle" TargetType="Button">

   <Setter Property="Width" Value="34"/>

   <Setter Property="Height" Value="32"/>

   <Setter Property="MinHeight" Value="0"/>

   <Setter Property="Padding" Value="0"/>

   <Setter Property="Margin" Value="0"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="Background" Value="Transparent"/>

   <Setter Property="BorderThickness" Value="0"/>

   <Setter Property="HorizontalContentAlignment" Value="Center"/>

   <Setter Property="VerticalContentAlignment" Value="Center"/>

   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="Button">

      <Border x:Name="TitleButtonBorder" Background="{TemplateBinding Background}" CornerRadius="2">

       <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>

      </Border>

      <ControlTemplate.Triggers>

       <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TitleButtonBorder" Property="Background" Value="{DynamicResource ThemeHoverBrush}"/><Setter Property="Foreground" Value="{DynamicResource ThemeAccentTextBrush}"/></Trigger>

       <Trigger Property="IsPressed" Value="True"><Setter TargetName="TitleButtonBorder" Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/></Trigger>

      </ControlTemplate.Triggers>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>

  <Style x:Key="TitleBarCloseButtonStyle" TargetType="Button" BasedOn="{StaticResource TitleBarButtonStyle}">

   <Setter Property="Foreground" Value="#FF8A80"/>

   <Style.Triggers>

    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#B83A32"/><Setter Property="Foreground" Value="#FFFFFFFF"/></Trigger>

   </Style.Triggers>

  </Style>



  <Style x:Key="MeterComboItemStyle" TargetType="ComboBoxItem">

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="Background" Value="{DynamicResource ThemePanelBrush}"/>

   <Setter Property="Padding" Value="8,5"/>

   <Setter Property="HorizontalContentAlignment" Value="Stretch"/>

   <Style.Triggers>

    <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeHoverBrush}"/><Setter Property="Foreground" Value="{DynamicResource ThemeAccentTextBrush}"/></Trigger>

    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/></Trigger>

   </Style.Triggers>

  </Style>

  <Style x:Key="MeterComboStyle" TargetType="ComboBox">

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="Background" Value="{DynamicResource ThemeButtonBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorderBrush}"/>

   <Setter Property="BorderThickness" Value="1"/>

   <Setter Property="Padding" Value="8,2"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>

   <Setter Property="MinHeight" Value="{DynamicResource MeterControlHeight}"/>

   <Setter Property="ItemContainerStyle" Value="{StaticResource MeterComboItemStyle}"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="ComboBox">

      <Grid>

       <ToggleButton x:Name="DropDownToggle" Focusable="False" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Foreground="{TemplateBinding Foreground}">

        <ToggleButton.Template>

         <ControlTemplate TargetType="ToggleButton">

          <Border x:Name="ComboBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">

           <Grid>

            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>

            <ContentPresenter Grid.Column="0" Margin="8,0,4,0" VerticalAlignment="Center" HorizontalAlignment="Left" RecognizesAccessKey="True" Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}" ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType=ComboBox}}" ContentStringFormat="{Binding SelectionBoxItemStringFormat, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>

            <Border Grid.Column="1" BorderBrush="{DynamicResource ThemeBorderBrush}" BorderThickness="1,0,0,0">

             <Path Width="8" Height="5" HorizontalAlignment="Center" VerticalAlignment="Center" Fill="{DynamicResource ThemeAccentTextBrush}" Data="M0,0 L8,0 L4,5 Z"/>

            </Border>

           </Grid>

          </Border>

          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource ThemeAccentBrush}"/></Trigger></ControlTemplate.Triggers>

         </ControlTemplate>

        </ToggleButton.Template>

       </ToggleButton>

       <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">

        <Border MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="260" Background="{DynamicResource ThemePanelBrush}" BorderBrush="{DynamicResource ThemeAccentBrush}" BorderThickness="1" CornerRadius="3" Margin="0,2,0,0">

         <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>

        </Border>

       </Popup>

      </Grid>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>

  <Style TargetType="ComboBox" BasedOn="{StaticResource MeterComboStyle}"/>



  <Style TargetType="CheckBox">

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>

   <Setter Property="VerticalAlignment" Value="Center"/>

  </Style>

  <Style TargetType="Slider"><Setter Property="Foreground" Value="{DynamicResource ThemeAccentBrush}"/><Setter Property="Background" Value="{DynamicResource ThemeTrackBrush}"/></Style>



  <Style x:Key="MeterTabStyle" TargetType="TabItem">

   <Setter Property="Foreground" Value="{DynamicResource ThemeMutedBrush}"/>

   <Setter Property="Background" Value="{DynamicResource ThemePanelAltBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeGridLineBrush}"/>

   <Setter Property="Padding" Value="11,4"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>

   <Setter Property="FontWeight" Value="Bold"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="TabItem">

      <Border x:Name="TabBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="0,0,1,1" Padding="{TemplateBinding Padding}">

       <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>

      </Border>

      <ControlTemplate.Triggers>

       <Trigger Property="IsSelected" Value="True"><Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource ThemeHeaderBrush}"/><Setter TargetName="TabBorder" Property="BorderBrush" Value="{DynamicResource ThemeAccentBrush}"/><Setter Property="Foreground" Value="{DynamicResource ThemeAccentTextBrush}"/></Trigger>

       <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource ThemeHoverBrush}"/></Trigger>

      </ControlTemplate.Triggers>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>

  <Style TargetType="TabItem" BasedOn="{StaticResource MeterTabStyle}"/>



  <Style x:Key="MeterDataGridStyle" TargetType="DataGrid">

   <Setter Property="Background" Value="{DynamicResource ThemeGridBrush}"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorderBrush}"/>

   <Setter Property="BorderThickness" Value="0"/>

   <Setter Property="GridLinesVisibility" Value="Horizontal"/>

   <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource ThemeGridLineBrush}"/>

   <Setter Property="VerticalGridLinesBrush" Value="{DynamicResource ThemeGridLineBrush}"/>

   <Setter Property="HeadersVisibility" Value="Column"/>

   <Setter Property="RowHeaderWidth" Value="0"/>

   <Setter Property="CanUserAddRows" Value="False"/>

   <Setter Property="CanUserDeleteRows" Value="False"/>

   <Setter Property="CanUserReorderColumns" Value="False"/>

   <Setter Property="CanUserResizeColumns" Value="True"/>

   <Setter Property="CanUserSortColumns" Value="False"/>

   <Setter Property="IsReadOnly" Value="True"/>

   <Setter Property="SelectionMode" Value="Single"/>

   <Setter Property="SelectionUnit" Value="FullRow"/>

   <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>

   <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>

   <Setter Property="EnableRowVirtualization" Value="True"/>

   <Setter Property="EnableColumnVirtualization" Value="False"/>

   <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>

   <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>

  </Style>

  <Style TargetType="DataGridColumnHeader">

   <Setter Property="Background" Value="{DynamicResource ThemeHeaderBrush}"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeAccentTextBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeGridLineBrush}"/>

   <Setter Property="BorderThickness" Value="0,0,1,1"/>

   <Setter Property="Padding" Value="6,3"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextSmall}"/>

   <Setter Property="FontWeight" Value="Bold"/>

  </Style>

  <Style TargetType="DataGridRow">

   <Setter Property="Background" Value="{DynamicResource ThemeGridBrush}"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeGridLineBrush}"/>

   <Style.Triggers>

    <Trigger Property="AlternationIndex" Value="1"><Setter Property="Background" Value="{DynamicResource ThemePanelAltBrush}"/></Trigger>

    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeHoverBrush}"/></Trigger>

    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/></Trigger>

   </Style.Triggers>

  </Style>

  <Style TargetType="DataGridCell">

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="BorderThickness" Value="0"/>

   <Setter Property="Padding" Value="6,2"/>

   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>

   <Setter Property="VerticalContentAlignment" Value="Center"/>

   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>

  </Style>



  <Style x:Key="MeterListStyle" TargetType="ListBox">

   <Setter Property="Background" Value="{DynamicResource ThemeGridBrush}"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="BorderThickness" Value="0"/>

   <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>

   <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>

   <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>

   <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>

  </Style>

  <Style x:Key="MeterListItemStyle" TargetType="ListBoxItem">

   <Setter Property="HorizontalContentAlignment" Value="Stretch"/>

   <Setter Property="VerticalContentAlignment" Value="Stretch"/>

   <Setter Property="Padding" Value="0"/>

   <Setter Property="Margin" Value="0"/>

   <Setter Property="Background" Value="Transparent"/>

   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>

   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>

   <Style.Triggers>

    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeHoverBrush}"/></Trigger>

    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/></Trigger>

   </Style.Triggers>

  </Style>



  <Style x:Key="ShareBarStyle" TargetType="ProgressBar">

   <Setter Property="Minimum" Value="0"/>

   <Setter Property="Maximum" Value="100"/>

   <Setter Property="Height" Value="14"/>

   <Setter Property="Background" Value="{DynamicResource ThemeTrackBrush}"/>

   <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorderBrush}"/>

   <Setter Property="BorderThickness" Value="1"/>

   <Setter Property="IsHitTestVisible" Value="False"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="ProgressBar">

      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3" SnapsToDevicePixels="True">

       <Grid x:Name="PART_Track" ClipToBounds="True">

        <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="2" Opacity="0.86"/>

       </Grid>

      </Border>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>



  <Style x:Key="ShareRowBarStyle" TargetType="ProgressBar">

   <Setter Property="Minimum" Value="0"/>

   <Setter Property="Maximum" Value="100"/>

   <Setter Property="Background" Value="Transparent"/>

   <Setter Property="BorderThickness" Value="0"/>

   <Setter Property="HorizontalAlignment" Value="Stretch"/>

   <Setter Property="VerticalAlignment" Value="Stretch"/>

   <Setter Property="IsHitTestVisible" Value="False"/>

   <Setter Property="Template">

    <Setter.Value>

     <ControlTemplate TargetType="ProgressBar">

      <Grid x:Name="PART_Track" ClipToBounds="True" Background="{TemplateBinding Background}">

       <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" Opacity="0.18"/>

      </Grid>

     </ControlTemplate>

    </Setter.Value>

   </Setter>

  </Style>

</Window.Resources>

 <Border CornerRadius="5" BorderThickness="1" BorderBrush="{DynamicResource ThemeAccentBrush}" Background="{DynamicResource ThemeWindowBrush}">

  <Grid>

   <Grid.RowDefinitions><RowDefinition x:Name="TitleBarRow" Height="32"/><RowDefinition x:Name="SummaryRow" Height="54"/><RowDefinition Height="*"/><RowDefinition x:Name="FooterRow" Height="28"/></Grid.RowDefinitions>

   

   <Grid x:Name="TitleBar" Grid.Row="0" Background="{DynamicResource ThemeChromeBrush}">

    <Grid.ColumnDefinitions><ColumnDefinition Width="31"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>

    <Border Width="24" Height="24" CornerRadius="12" Margin="4,3"><Image x:Name="PortraitImage" Stretch="UniformToFill"/></Border>

    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">

     <TextBlock Text="TARTE" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextTitle}"/>

     <TextBlock Text="METER" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextTitle}" Margin="3,0,0,0"/>

     <Border x:Name="VersionBadge" Background="{DynamicResource ThemeBadgeBrush}" CornerRadius="4" Padding="5,1" Margin="7,0,0,0"><TextBlock Text="v3.1.3" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}"/></Border>

     <TextBlock x:Name="EditionLabel" Text="COMPACT" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="7,1,0,0"/>

    </StackPanel>

    <StackPanel Grid.Column="2" Orientation="Horizontal">

     <Button x:Name="SettingsButton" Style="{StaticResource TitleBarButtonStyle}" ToolTip="Settings"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" Text="&#xE713;" TextOptions.TextFormattingMode="Display"/></Button>

     <Button x:Name="MinimizeButton" Style="{StaticResource TitleBarButtonStyle}" ToolTip="Minimize"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="13" Text="&#xE921;" TextOptions.TextFormattingMode="Display"/></Button>

     <Button x:Name="MaximizeButton" Style="{StaticResource TitleBarButtonStyle}" ToolTip="Maximize"><TextBlock x:Name="MaximizeGlyph" FontFamily="Segoe MDL2 Assets" FontSize="13" Text="&#xE922;" TextOptions.TextFormattingMode="Display"/></Button>

     <Button x:Name="CloseButton" Style="{StaticResource TitleBarCloseButtonStyle}" ToolTip="Close"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="13" Text="&#xE8BB;" TextOptions.TextFormattingMode="Display"/></Button>

    </StackPanel>

   </Grid>



   <Grid Grid.Row="3" Background="{DynamicResource ThemeChromeBrush}">

    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>

    <Button x:Name="ResetButton" Content="RESET F6" Margin="4,2" Padding="8,1"/>

    <TextBlock x:Name="HotkeyFooterText" Grid.Column="1" Text="F6 RESET + SAVE | F9 SHOW/HIDE | F10 PASS" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center" HorizontalAlignment="Center"/>

    <TextBlock Grid.Column="2" Text="COMPACT" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}" FontWeight="Bold" VerticalAlignment="Center" Margin="8,0"/>

   </Grid>



   

   <Grid Grid.Row="1" Margin="5,3,5,3">

    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="112"/><ColumnDefinition Width="112"/></Grid.ColumnDefinitions>

    <Image x:Name="BannerImage" Visibility="Collapsed"/>

    <Border Grid.Column="0" Background="{DynamicResource ThemePanelAltBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="1" CornerRadius="3" Padding="8,4" Margin="0,0,4,0">

     <StackPanel VerticalAlignment="Center">

      <TextBlock x:Name="StatusText" Text="READY | ACTIVE Unknown" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/>

      <TextBlock x:Name="TargetText" Text="TARGET Unknown" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextMedium}" TextTrimming="CharacterEllipsis"/>

     </StackPanel>

    </Border>

    <Border Grid.Column="1" Background="{DynamicResource ThemePanelAltBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="1" CornerRadius="3" Padding="7,4" Margin="0,0,4,0">

     <StackPanel><TextBlock Text="TOTAL DAMAGE" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}" FontWeight="Bold"/><TextBlock x:Name="TotalText" Text="0" Foreground="{DynamicResource ThemeTextBrush}" FontSize="{DynamicResource MeterTextStat}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel>

    </Border>

    <Border Grid.Column="2" Background="{DynamicResource ThemePanelAltBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="1" CornerRadius="3" Padding="7,4">

     <StackPanel><TextBlock Text="DPS / TIME" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}" FontWeight="Bold"/><TextBlock x:Name="DpsText" Text="0 / 0.0s" Foreground="{DynamicResource ThemeTextBrush}" FontSize="{DynamicResource MeterTextStat}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel>

    </Border>

   </Grid>



   

   <TabControl Grid.Row="2" Background="{DynamicResource ThemeGridBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0" Padding="0">

    <TabItem Header="DAMAGE"><Grid Background="{DynamicResource ThemeGridBrush}">

       <ListBox x:Name="DamageGrid" Style="{StaticResource MeterListStyle}" ItemContainerStyle="{StaticResource MeterListItemStyle}">

        <ListBox.ItemTemplate><DataTemplate><Border BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0,0,0,1" ToolTip="{Binding ShareTooltip}">

         <Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

          <ProgressBar Grid.RowSpan="2" Style="{StaticResource ShareRowBarStyle}" Value="{Binding ShareNumber}" Foreground="{Binding BarBrush}"/>

          <Grid Grid.Row="0" Margin="7,4,7,1" ClipToBounds="True"><Grid.ColumnDefinitions><ColumnDefinition Width="1.45*"/><ColumnDefinition Width="0.95*"/><ColumnDefinition Width="0.82*"/><ColumnDefinition Width="0.72*"/></Grid.ColumnDefinitions>

           <TextBlock Grid.Column="0" Text="{Binding Character}" Foreground="{Binding BarBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextMedium}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Character}"/>

           <TextBlock Grid.Column="1" Text="{Binding Damage}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis" ToolTip="{Binding Damage}"/>

           <TextBlock Grid.Column="2" Text="{Binding DPS}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis" ToolTip="{Binding DPS}"/>

           <TextBlock Grid.Column="3" Text="{Binding Share}" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/>

          </Grid>

          <Grid Grid.Row="1" Margin="7,1,7,4" ClipToBounds="True"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

           <TextBlock Grid.Column="0" Text="{Binding Hits, StringFormat=HITS {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/>

           <TextBlock Grid.Column="1" Text="{Binding CritRate, StringFormat=CRIT {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>

           <TextBlock Grid.Column="2" Text="{Binding Highest, StringFormat=MAX {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Center" TextTrimming="CharacterEllipsis" ToolTip="{Binding Highest}"/>

           <TextBlock Grid.Column="3" Text="{Binding Average, StringFormat=AVG {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Right" TextTrimming="CharacterEllipsis" ToolTip="{Binding Average}"/>

          </Grid>

         </Grid></Border></DataTemplate></ListBox.ItemTemplate>

       </ListBox></Grid></TabItem>

    

    <TabItem Header="HISTORY">

     <Grid Background="{DynamicResource ThemeGridBrush}">

      <Grid.RowDefinitions><RowDefinition Height="0.40*" MinHeight="80"/><RowDefinition Height="4"/><RowDefinition Height="0.60*" MinHeight="105"/><RowDefinition Height="4"/><RowDefinition x:Name="LogTimelineRow" Height="82" MinHeight="54"/></Grid.RowDefinitions>

      <Grid Grid.Row="0">

       <ListBox x:Name="HistoryGrid" Style="{StaticResource MeterListStyle}" ItemContainerStyle="{StaticResource MeterListItemStyle}"><ListBox.ItemTemplate><DataTemplate><Border BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0,0,0,1" Padding="7,4"><Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="1.15*"/><ColumnDefinition Width="1.55*"/><ColumnDefinition Width="0.72*"/><ColumnDefinition Width="0.95*"/><ColumnDefinition Width="0.78*"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="{Binding Date}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="1" Text="{Binding Target}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="2" Text="{Binding Duration}" Foreground="{DynamicResource ThemeMutedBrush}" TextAlignment="Right" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="3" Text="{Binding Damage}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="4" Text="{Binding DPS}" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Row="1" Grid.ColumnSpan="5" Text="{Binding Reason}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/></Grid></Border></DataTemplate></ListBox.ItemTemplate></ListBox></Grid>

      <GridSplitter x:Name="HistoryDetailSplitter" Grid.Row="1" Height="4" HorizontalAlignment="Stretch" Background="{DynamicResource ThemeBorderBrush}" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

      <Grid Grid.Row="2">

       <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="22"/><RowDefinition Height="*"/></Grid.RowDefinitions>

       <Border Grid.Row="0" Background="{DynamicResource ThemePanelAltBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0,0,0,1" Padding="7,5">

        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

         <Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="LogTargetText" Text="SELECT AN ENCOUNTER" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="LogMetaText" Text="Select a saved battle above" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/></StackPanel><TextBlock x:Name="LogPartySummaryText" Grid.Column="1" Text="0 MEMBERS / 0 HITS" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center" Margin="8,0,0,0"/></Grid>

         <Grid Grid.Row="1" Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0"><TextBlock Text="DAMAGE" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}"/><TextBlock x:Name="LogTotalDamageText" Text="0" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="DPS" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}"/><TextBlock x:Name="LogDpsText" Text="0" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="TIME" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}"/><TextBlock x:Name="LogDurationText" Text="0.0s" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel><StackPanel Grid.Column="3"><TextBlock Text="CRIT" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}"/><TextBlock x:Name="LogCritText" Text="0.0%" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>

        </Grid>

       </Border>

       <Grid Grid.Row="1" Background="{DynamicResource ThemeHeaderBrush}"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="PARTY DAMAGE BREAKDOWN" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center" Margin="7,0"/><TextBlock Grid.Column="1" Text="SELECT ABOVE" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center" Margin="7,0"/></Grid>

       <Grid Grid.Row="2">

       <ListBox x:Name="LogCharacterGrid" Style="{StaticResource MeterListStyle}" ItemContainerStyle="{StaticResource MeterListItemStyle}"><ListBox.ItemTemplate><DataTemplate><Border BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0,0,0,1" ToolTip="{Binding ShareTooltip}"><Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><ProgressBar Grid.RowSpan="2" Style="{StaticResource ShareRowBarStyle}" Value="{Binding ShareNumber}" Foreground="{Binding BarBrush}"/><Grid Grid.Row="0" Margin="7,4,7,1" ClipToBounds="True"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="1.35*"/><ColumnDefinition Width="0.95*"/><ColumnDefinition Width="0.82*"/><ColumnDefinition Width="0.72*"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="{Binding Rank, StringFormat=\#{0}}" Foreground="{DynamicResource ThemeMutedBrush}" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="1" Text="{Binding Character}" Foreground="{Binding BarBrush}" FontWeight="Bold" TextTrimming="CharacterEllipsis" ToolTip="{Binding Character}"/><TextBlock Grid.Column="2" Text="{Binding Damage}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="3" Text="{Binding DPS}" Foreground="{DynamicResource ThemeTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="4" Text="{Binding Share}" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" TextAlignment="Right" TextTrimming="CharacterEllipsis"/></Grid><Grid Grid.Row="1" Margin="37,1,7,4" ClipToBounds="True"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="{Binding Hits, StringFormat=HITS {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="1" Text="{Binding CritRate, StringFormat=CRIT {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Center" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="2" Text="{Binding Highest, StringFormat=MAX {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Center" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="3" Text="{Binding Average, StringFormat=AVG {0}}" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" TextAlignment="Right" TextTrimming="CharacterEllipsis"/></Grid></Grid></Border></DataTemplate></ListBox.ItemTemplate></ListBox></Grid>

      </Grid>

      <GridSplitter x:Name="LogTimelineSplitter" Grid.Row="3" Height="4" HorizontalAlignment="Stretch" Background="{DynamicResource ThemeBorderBrush}" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

      <Border Grid.Row="4" Background="{DynamicResource ThemeGridBrush}" BorderBrush="{DynamicResource ThemeGridLineBrush}" BorderThickness="0,1,0,0"><Grid><ScrollViewer x:Name="HistoryTimelineScroll" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled"><Canvas x:Name="HistoryTimelineCanvas" Height="70" MinWidth="260"/></ScrollViewer><TextBlock x:Name="HistoryTimelineLabel" Text="Select a saved encounter" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="7,4" IsHitTestVisible="False"/></Grid></Border>

     </Grid>

    </TabItem>



   </TabControl>



   

   <Grid Grid.RowSpan="4" Panel.ZIndex="9000" IsHitTestVisible="True">

    <Grid.RowDefinitions><RowDefinition Height="4"/><RowDefinition Height="*"/><RowDefinition Height="4"/></Grid.RowDefinitions>

    <Grid.ColumnDefinitions><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/></Grid.ColumnDefinitions>

    <Border x:Name="ResizeTopLeft" Grid.Row="0" Grid.Column="0" Background="#01000000" Cursor="SizeNWSE"/>

    <Border x:Name="ResizeTop" Grid.Row="0" Grid.Column="1" Background="#01000000" Cursor="SizeNS"/>

    <Border x:Name="ResizeTopRight" Grid.Row="0" Grid.Column="2" Background="#01000000" Cursor="SizeNESW"/>

    <Border x:Name="ResizeLeft" Grid.Row="1" Grid.Column="0" Background="#01000000" Cursor="SizeWE"/>

    <Border x:Name="ResizeRight" Grid.Row="1" Grid.Column="2" Background="#01000000" Cursor="SizeWE"/>

    <Border x:Name="ResizeBottomLeft" Grid.Row="2" Grid.Column="0" Background="#01000000" Cursor="SizeNESW"/>

    <Border x:Name="ResizeBottom" Grid.Row="2" Grid.Column="1" Background="#01000000" Cursor="SizeNS"/>

    <Border x:Name="ResizeBottomRight" Grid.Row="2" Grid.Column="2" Background="#01000000" Cursor="SizeNWSE"/>

   </Grid>



   

   <Border x:Name="SettingsPanel" Grid.RowSpan="4" Panel.ZIndex="10000" Width="340" HorizontalAlignment="Right" VerticalAlignment="Stretch" Margin="0,31,5,5" Background="{DynamicResource ThemePanelBrush}" BorderBrush="{DynamicResource ThemeAccentBrush}" BorderThickness="1" CornerRadius="5" Visibility="Collapsed">

    <Grid>

     <Grid.RowDefinitions><RowDefinition x:Name="SettingsHeaderRow" Height="34"/><RowDefinition Height="*"/></Grid.RowDefinitions>

     <Grid Grid.Row="0" Background="{DynamicResource ThemeChromeBrush}">

      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>

      <TextBlock Text="SETTINGS" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextMedium}" VerticalAlignment="Center" Margin="10,0,0,0"/>

      <Button x:Name="SettingsCloseButton" Grid.Column="1" Style="{StaticResource TitleBarCloseButtonStyle}" Width="32" Height="32" ToolTip="Close settings"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="13" Text="&#xE8BB;" TextOptions.TextFormattingMode="Display"/></Button>

     </Grid>

     <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10">

      <StackPanel>

       <TextBlock Text="COLOR THEME" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,4"/>

       <Grid Margin="0,0,0,5"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions>

        <ComboBox x:Name="ThemeCombo" Grid.Column="0" Margin="0,0,6,0" IsEditable="False"/>

        <Button x:Name="ApplyThemeButton" Grid.Column="1" Content="APPLY"/>

       </Grid>

       <TextBlock x:Name="ThemeStatusText" Text="Theme ready" Foreground="{DynamicResource ThemeAccentTextBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,10" TextWrapping="Wrap"/>



       <Grid Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>

        <TextBlock Text="OPACITY" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center"/>

        <Slider x:Name="OpacitySlider" Grid.Column="1" Minimum="55" Maximum="100" Value="92" TickFrequency="5" Height="20"/>

        <TextBlock x:Name="OpacityText" Grid.Column="2" Text="92%" Foreground="{DynamicResource ThemeTextBrush}" VerticalAlignment="Center" TextAlignment="Right"/>

       </Grid>

       <Grid Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>

        <TextBlock Text="TEXT" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" VerticalAlignment="Center"/>

        <Slider x:Name="TextScaleSlider" Grid.Column="1" Minimum="70" Maximum="180" Value="100" TickFrequency="5" Height="20"/>

        <TextBlock x:Name="TextScaleText" Grid.Column="2" Text="100%" Foreground="{DynamicResource ThemeTextBrush}" VerticalAlignment="Center" TextAlignment="Right"/>

       </Grid>

       <StackPanel Orientation="Horizontal" Margin="0,0,0,10">

        <CheckBox x:Name="TopmostCheck" Content="ALWAYS ON TOP" IsChecked="True" Margin="0,0,16,0"/>

        <CheckBox x:Name="ClickThroughCheck" Content="CLICK THROUGH"/>

       </StackPanel>



       <Border Height="1" Background="{DynamicResource ThemeBorderBrush}" Margin="0,0,0,9"/>

       <TextBlock Text="KEY BINDINGS" Foreground="{DynamicResource ThemeAccentTextBrush}" FontWeight="Bold" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,6"/>

       <TextBlock Text="RESET + SAVE" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,3"/>

       <ComboBox x:Name="ResetHotkeyCombo" Margin="0,0,0,7" IsEditable="False"/>

       <TextBlock Text="SHOW / HIDE" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,3"/>

       <ComboBox x:Name="OverlayHotkeyCombo" Margin="0,0,0,7" IsEditable="False"/>

       <TextBlock Text="CLICK THROUGH" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,3"/>

       <ComboBox x:Name="PassHotkeyCombo" Margin="0,0,0,7" IsEditable="False"/>

       <TextBlock x:Name="HotkeyStatusText" Text="F1-F12 and Ctrl/Shift/Alt combinations are supported." TextWrapping="Wrap" Foreground="{DynamicResource ThemeMutedBrush}" FontSize="{DynamicResource MeterTextSmall}" Margin="0,0,0,7"/>

       <Button x:Name="ApplyHotkeysButton" Content="APPLY KEY BINDINGS" Margin="0,0,0,7"/>

       <Button x:Name="ExitButton" Content="EXIT TARTEMETER" Foreground="#FF9B91"/>

      </StackPanel>

     </ScrollViewer>

    </Grid>

   </Border>



  </Grid>

 </Border>

</Window>

'@



$reader = New-Object System.Xml.XmlNodeReader($xaml)

try {

    $window = [Windows.Markup.XamlReader]::Load($reader)

    Write-StartupDiagnostic "XAML loaded successfully"

}

catch {

    $errorText = (

        "TarteMeter failed to load the WPF interface.`r`n" +

        $_.Exception.ToString()

    )

    $errorText | Set-Content -LiteralPath $startupErrorPath -Encoding UTF8

    [void][Windows.MessageBox]::Show(

        "TarteMeter could not open. See startup_error.txt in the mod folder.",

        "TarteMeter startup error",

        [Windows.MessageBoxButton]::OK,

        [Windows.MessageBoxImage]::Error

    )

    throw

}



$TitleBar = $window.FindName("TitleBar")

$VersionBadge = $window.FindName("VersionBadge")

$EditionLabel = $window.FindName("EditionLabel")

$TitleBarRow = $window.FindName("TitleBarRow")

$SummaryRow = $window.FindName("SummaryRow")

$FooterRow = $window.FindName("FooterRow")

$SettingsButton = $window.FindName("SettingsButton")

$SettingsCloseButton = $window.FindName("SettingsCloseButton")

$SettingsPanel = $window.FindName("SettingsPanel")

$SettingsHeaderRow = $window.FindName("SettingsHeaderRow")

$ResizeTopLeft = $window.FindName("ResizeTopLeft")

$ResizeTop = $window.FindName("ResizeTop")

$ResizeTopRight = $window.FindName("ResizeTopRight")

$ResizeLeft = $window.FindName("ResizeLeft")

$ResizeRight = $window.FindName("ResizeRight")

$ResizeBottomLeft = $window.FindName("ResizeBottomLeft")

$ResizeBottom = $window.FindName("ResizeBottom")

$ResizeBottomRight = $window.FindName("ResizeBottomRight")

$MinimizeButton = $window.FindName("MinimizeButton")

$MaximizeButton = $window.FindName("MaximizeButton")

$MaximizeGlyph = $window.FindName("MaximizeGlyph")

$CloseButton = $window.FindName("CloseButton")

$PortraitImage = $window.FindName("PortraitImage")

$BannerImage = $window.FindName("BannerImage")

$StatusText = $window.FindName("StatusText")

$TargetText = $window.FindName("TargetText")

$TotalText = $window.FindName("TotalText")

$DpsText = $window.FindName("DpsText")

$DamageGrid = $window.FindName("DamageGrid")

$HistoryGrid = $window.FindName("HistoryGrid")

$HistoryTimelineScroll = $window.FindName("HistoryTimelineScroll")

$HistoryTimelineCanvas = $window.FindName("HistoryTimelineCanvas")

$HistoryTimelineLabel = $window.FindName("HistoryTimelineLabel")

$LogTimelineRow = $window.FindName("LogTimelineRow")

$LogTimelineSplitter = $window.FindName("LogTimelineSplitter")

$LogCharacterGrid = $window.FindName("LogCharacterGrid")

$LogTargetText = $window.FindName("LogTargetText")

$LogMetaText = $window.FindName("LogMetaText")

$LogTotalDamageText = $window.FindName("LogTotalDamageText")

$LogDpsText = $window.FindName("LogDpsText")

$LogDurationText = $window.FindName("LogDurationText")

$LogCritText = $window.FindName("LogCritText")

$LogPartySummaryText = $window.FindName("LogPartySummaryText")

$ResetButton = $window.FindName("ResetButton")

$OpacitySlider = $window.FindName("OpacitySlider")

$OpacityText = $window.FindName("OpacityText")

$TextScaleSlider = $window.FindName("TextScaleSlider")

$TextScaleText = $window.FindName("TextScaleText")

$TopmostCheck = $window.FindName("TopmostCheck")

$ClickThroughCheck = $window.FindName("ClickThroughCheck")

$ThemeCombo = $window.FindName("ThemeCombo")

$ApplyThemeButton = $window.FindName("ApplyThemeButton")

$ThemeStatusText = $window.FindName("ThemeStatusText")

$ResetHotkeyCombo = $window.FindName("ResetHotkeyCombo")

$OverlayHotkeyCombo = $window.FindName("OverlayHotkeyCombo")

$PassHotkeyCombo = $window.FindName("PassHotkeyCombo")

$HotkeyStatusText = $window.FindName("HotkeyStatusText")

$HotkeyFooterText = $window.FindName("HotkeyFooterText")

$ApplyHotkeysButton = $window.FindName("ApplyHotkeysButton")

$ExitButton = $window.FindName("ExitButton")



if (Test-Path -LiteralPath $iconPath) {

    try {

        $iconUri = New-Object System.Uri(

            ([IO.Path]::GetFullPath($iconPath)),

            [UriKind]::Absolute

        )

        $iconBitmap = New-Object Windows.Media.Imaging.BitmapImage

        $iconBitmap.BeginInit()

        $iconBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad

        $iconBitmap.UriSource = $iconUri

        $iconBitmap.EndInit()

        $iconBitmap.Freeze()

        $window.Icon = $iconBitmap

    }

    catch {

        Write-WindowError $_

    }

}

if (Test-Path -LiteralPath $portraitPath) {

    try {

        $portraitBitmap = New-Object Windows.Media.Imaging.BitmapImage

        $portraitBitmap.BeginInit()

        $portraitBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad

        $portraitBitmap.UriSource = New-Object Uri(

            ([IO.Path]::GetFullPath($portraitPath)),

            [UriKind]::Absolute

        )

        $portraitBitmap.EndInit()

        $portraitBitmap.Freeze()

        $PortraitImage.Source = $portraitBitmap

    }

    catch {

        Write-WindowError $_

    }

}

if (Test-Path -LiteralPath $bannerPath) {

    try {

        $bannerBitmap = New-Object Windows.Media.Imaging.BitmapImage

        $bannerBitmap.BeginInit()

        $bannerBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad

        $bannerBitmap.UriSource = New-Object Uri(

            ([IO.Path]::GetFullPath($bannerPath)),

            [UriKind]::Absolute

        )

        $bannerBitmap.EndInit()

        $bannerBitmap.Freeze()

        $BannerImage.Source = $bannerBitmap

    }

    catch {

        Write-WindowError $_

    }

}



$settingsSaveTimer = New-Object Windows.Threading.DispatcherTimer

$settingsSaveTimer.Interval = [TimeSpan]::FromMilliseconds(450)

$settingsSaveTimer.Add_Tick({

    $settingsSaveTimer.Stop()

    [void](Write-WindowSettings)

})



$timelineResizeTimer = New-Object Windows.Threading.DispatcherTimer

$timelineResizeTimer.Interval = [TimeSpan]::FromMilliseconds(160)

$timelineResizeTimer.Add_Tick({

    $timelineResizeTimer.Stop()

    if ($null -ne $script:selectedBattle) {

        Draw-LogsTimeline $script:selectedBattle

    }

})



$layoutResizeTimer = New-Object Windows.Threading.DispatcherTimer

$layoutResizeTimer.Interval = [TimeSpan]::FromMilliseconds(120)

$layoutResizeTimer.Add_Tick({

    $layoutResizeTimer.Stop()

    Update-AdaptiveLayout

})



$hotkeyApplyTimer = New-Object Windows.Threading.DispatcherTimer

$hotkeyApplyTimer.Interval = [TimeSpan]::FromMilliseconds(180)

$hotkeyApplyTimer.Add_Tick({

    $hotkeyApplyTimer.Stop()

    [void](Register-MeterHotkeys $true)

})



function Queue-SettingsSave {

    $settingsSaveTimer.Stop()

    $settingsSaveTimer.Start()

}



function Apply-Theme {

    param([string]$ThemeName)



    $name = [string]$ThemeName

    if ([string]::IsNullOrWhiteSpace($name)) {

        $name = "MIDNIGHT GOLD"

    }

    $name = $name.ToUpperInvariant()

    if (-not ($script:themeNames -contains $name)) {

        $name = "MIDNIGHT GOLD"

    }



    $theme = switch ($name) {

        "OBSIDIAN VIOLET" {

            @{

                ThemeWindowBrush = "#100F16"

                ThemeChromeBrush = "#17131F"

                ThemePanelBrush = "#20182A"

                ThemePanelAltBrush = "#191420"

                ThemeGridBrush = "#0D0B12"

                ThemeHeaderBrush = "#281D34"

                ThemeButtonBrush = "#30233D"

                ThemeBadgeBrush = "#3A2948"

                ThemeBorderBrush = "#5B456B"

                ThemeGridLineBrush = "#30253A"

                ThemeAccentBrush = "#B987E8"

                ThemeAccentTextBrush = "#E3C8FF"

                ThemeTextBrush = "#F2EDF7"

                ThemeMutedBrush = "#A797B5"

                ThemeHoverBrush = "#2B2036"

                ThemeSelectionBrush = "#3B2850"

                ThemeSelectionBorderBrush = "#D3A5FF"

                ThemeTrackBrush = "#09070D"

            }

        }

        "GRAPHITE TEAL" {

            @{

                ThemeWindowBrush = "#101516"

                ThemeChromeBrush = "#151D1E"

                ThemePanelBrush = "#192526"

                ThemePanelAltBrush = "#151F20"

                ThemeGridBrush = "#0C1213"

                ThemeHeaderBrush = "#203031"

                ThemeButtonBrush = "#263738"

                ThemeBadgeBrush = "#2E4243"

                ThemeBorderBrush = "#466263"

                ThemeGridLineBrush = "#263637"

                ThemeAccentBrush = "#57C9BF"

                ThemeAccentTextBrush = "#A9F0E8"

                ThemeTextBrush = "#ECF4F3"

                ThemeMutedBrush = "#91AAA8"

                ThemeHoverBrush = "#213031"

                ThemeSelectionBrush = "#284344"

                ThemeSelectionBorderBrush = "#7DE5DB"

                ThemeTrackBrush = "#080D0E"

            }

        }

        default {

            @{

                ThemeWindowBrush = "#101722"

                ThemeChromeBrush = "#151F2D"

                ThemePanelBrush = "#172332"

                ThemePanelAltBrush = "#121C28"

                ThemeGridBrush = "#0F1722"

                ThemeHeaderBrush = "#202D3D"

                ThemeButtonBrush = "#223044"

                ThemeBadgeBrush = "#2B3A4D"

                ThemeBorderBrush = "#3A4B60"

                ThemeGridLineBrush = "#263648"

                ThemeAccentBrush = "#D8B15D"

                ThemeAccentTextBrush = "#F0D59B"

                ThemeTextBrush = "#E9EEF5"

                ThemeMutedBrush = "#8FA0B4"

                ThemeHoverBrush = "#1E2D3E"

                ThemeSelectionBrush = "#263A50"

                ThemeSelectionBorderBrush = "#D5B56D"

                ThemeTrackBrush = "#0A111A"

            }

        }

    }



    foreach ($entry in $theme.GetEnumerator()) {

        $resourceKey = [string]$entry.Key

        $newColor = Convert-ToWpfColor -Hex ([string]$entry.Value)

        $existing = $window.Resources[$resourceKey]



        if (

            $existing -is [Windows.Media.SolidColorBrush] -and

            -not $existing.IsFrozen

        ) {

            $existing.Color = $newColor

        }

        else {

            $newBrush = [Windows.Media.SolidColorBrush]::new($newColor)

            if ($window.Resources.Contains($resourceKey)) {

                [void]$window.Resources.Remove($resourceKey)

            }

            $window.Resources.Add($resourceKey, $newBrush)

        }

    }



    $script:settings.Theme = $name



    try {

        $window.InvalidateVisual()

        $DamageGrid.InvalidateVisual()

        $HistoryGrid.InvalidateVisual()

        $LogCharacterGrid.InvalidateVisual()

        $SettingsPanel.InvalidateVisual()

    }

    catch {}



    Write-StartupDiagnostic "Theme applied" $name

}



function Get-HotkeyOptions {

    $values = New-Object 'System.Collections.Generic.List[string]'

    foreach ($prefix in @("", "Ctrl+", "Shift+", "Alt+")) {

        for ($number = 1; $number -le 12; $number++) {

            $values.Add(("{0}F{1}" -f $prefix, $number))

        }

    }

    foreach ($code in 65..90) {

        $values.Add("Ctrl+{0}" -f ([char]$code))

    }

    for ($number = 0; $number -le 9; $number++) {

        $values.Add("Ctrl+{0}" -f $number)

    }

    foreach ($value in @(

        "Insert", "Delete", "Home", "End", "PageUp", "PageDown",

        "Ctrl+Insert", "Ctrl+Delete", "Ctrl+Home", "Ctrl+End"

    )) {

        $values.Add($value)

    }

    return $values.ToArray()

}



function Convert-HotkeyDefinition {

    param([string]$Definition)



    $text = [string]$Definition

    if ([string]::IsNullOrWhiteSpace($text)) {

        throw "Hotkey cannot be empty."

    }



    $parts = @($text.Trim() -split "\+")

    $modifiers = [uint32][TarteNative]::MOD_NOREPEAT

    $keyName = $null



    foreach ($part in $parts) {

        $token = $part.Trim()

        switch ($token.ToUpperInvariant()) {

            "CTRL" { $modifiers = $modifiers -bor [TarteNative]::MOD_CONTROL }

            "CONTROL" { $modifiers = $modifiers -bor [TarteNative]::MOD_CONTROL }

            "SHIFT" { $modifiers = $modifiers -bor [TarteNative]::MOD_SHIFT }

            "ALT" { $modifiers = $modifiers -bor [TarteNative]::MOD_ALT }

            "WIN" { $modifiers = $modifiers -bor [TarteNative]::MOD_WIN }

            default {

                if ($null -ne $keyName) {

                    throw "Hotkey contains more than one main key: $text"

                }

                $keyName = $token

            }

        }

    }



    if ([string]::IsNullOrWhiteSpace($keyName)) {

        throw "Hotkey has no main key: $text"

    }



    $upper = $keyName.ToUpperInvariant()

    [uint32]$virtualKey = 0

    if ($upper -match '^F([1-9]|1[0-2])$') {

        $virtualKey = [uint32](0x70 + ([int]$Matches[1] - 1))

    }

    elseif ($upper -match '^[A-Z]$') {

        $virtualKey = [uint32][char]$upper

    }

    elseif ($upper -match '^[0-9]$') {

        $virtualKey = [uint32][char]$upper

    }

    else {

        $named = @{

            "INSERT" = 0x2D

            "DELETE" = 0x2E

            "HOME" = 0x24

            "END" = 0x23

            "PAGEUP" = 0x21

            "PAGEDOWN" = 0x22

            "NUMPAD0" = 0x60

            "NUMPAD1" = 0x61

            "NUMPAD2" = 0x62

            "NUMPAD3" = 0x63

            "NUMPAD4" = 0x64

            "NUMPAD5" = 0x65

            "NUMPAD6" = 0x66

            "NUMPAD7" = 0x67

            "NUMPAD8" = 0x68

            "NUMPAD9" = 0x69

        }

        if (-not $named.ContainsKey($upper)) {

            throw "Unsupported key '$keyName'. Use F1-F12, A-Z, 0-9, Insert, Delete, Home, End, PageUp, PageDown, or NumPad0-9."

        }

        $virtualKey = [uint32]$named[$upper]

    }



    $normalizedParts = New-Object 'System.Collections.Generic.List[string]'

    if (($modifiers -band [TarteNative]::MOD_CONTROL) -ne 0) { $normalizedParts.Add("Ctrl") }

    if (($modifiers -band [TarteNative]::MOD_SHIFT) -ne 0) { $normalizedParts.Add("Shift") }

    if (($modifiers -band [TarteNative]::MOD_ALT) -ne 0) { $normalizedParts.Add("Alt") }

    if (($modifiers -band [TarteNative]::MOD_WIN) -ne 0) { $normalizedParts.Add("Win") }

    $normalizedParts.Add($upper.Substring(0,1) + $upper.Substring(1).ToLowerInvariant())

    if ($upper -match '^F\d+$') { $normalizedParts[$normalizedParts.Count - 1] = $upper }

    if ($upper -match '^[A-Z0-9]$') { $normalizedParts[$normalizedParts.Count - 1] = $upper }

    if ($upper -eq "PAGEUP") { $normalizedParts[$normalizedParts.Count - 1] = "PageUp" }

    if ($upper -eq "PAGEDOWN") { $normalizedParts[$normalizedParts.Count - 1] = "PageDown" }

    if ($upper -match '^NUMPAD\d$') { $normalizedParts[$normalizedParts.Count - 1] = "NumPad" + $upper.Substring(6) }



    return [pscustomobject]@{

        Text = ($normalizedParts -join "+")

        Modifiers = $modifiers

        VirtualKey = $virtualKey

        Signature = "{0}:{1}" -f $modifiers, $virtualKey

    }

}



function Unregister-MeterHotkeys {

    if ($script:windowHandle -eq [IntPtr]::Zero) { return }

    foreach ($id in @(

        $script:resetHotkeyId,

        $script:overlayHotkeyId,

        $script:passHotkeyId

    )) {

        [void][TarteNative]::UnregisterHotKey($script:windowHandle, $id)

    }

    $script:hotkeysRegistered = $false

}



function Update-HotkeyLabels {

    if (-not $script:resetUiPending) {

        $ResetButton.Content = "RESET {0}" -f $script:settings.ResetHotkey

    }

    $HotkeyFooterText.Text = (

        "RESET SAVES LOG  |  {0} SHOW/HIDE  |  {1} PASS" -f

        $script:settings.OverlayHotkey,

        $script:settings.PassHotkey

    )

}



function Set-HotkeyComboValue {

    param(

        [Windows.Controls.ComboBox]$Combo,

        [string]$Value

    )



    $Combo.SelectedItem = $Value

    if ($null -eq $Combo.SelectedItem) {

        $Combo.Text = $Value

    }

}



function Get-HotkeyComboValue {

    param([Windows.Controls.ComboBox]$Combo)



    if ($null -ne $Combo.SelectedItem) {

        return [string]$Combo.SelectedItem

    }

    return [string]$Combo.Text

}



function Sync-HotkeyControls {

    $script:syncingHotkeyControls = $true

    try {

        Set-HotkeyComboValue -Combo $ResetHotkeyCombo `
            -Value ([string]$script:settings.ResetHotkey)

        Set-HotkeyComboValue -Combo $OverlayHotkeyCombo `
            -Value ([string]$script:settings.OverlayHotkey)

        Set-HotkeyComboValue -Combo $PassHotkeyCombo `
            -Value ([string]$script:settings.PassHotkey)

    }

    finally {

        $script:syncingHotkeyControls = $false

    }

}



function Register-MeterHotkeys {

    param([bool]$ShowStatus = $true)



    if ($script:windowHandle -eq [IntPtr]::Zero) {

        return $false

    }



    $previousReset = [string]$script:settings.ResetHotkey

    $previousOverlay = [string]$script:settings.OverlayHotkey

    $previousPass = [string]$script:settings.PassHotkey



    try {

        $reset = Convert-HotkeyDefinition -Definition (

            Get-HotkeyComboValue -Combo $ResetHotkeyCombo

        )

        $overlay = Convert-HotkeyDefinition -Definition (

            Get-HotkeyComboValue -Combo $OverlayHotkeyCombo

        )

        $pass = Convert-HotkeyDefinition -Definition (

            Get-HotkeyComboValue -Combo $PassHotkeyCombo

        )



        $signatures = @(

            $reset.Signature,

            $overlay.Signature,

            $pass.Signature

        )

        if (@($signatures | Select-Object -Unique).Count -ne 3) {

            throw "Each action must use a different hotkey."

        }



        Unregister-MeterHotkeys

        $registeredIds = New-Object 'System.Collections.Generic.List[int]'



        foreach ($item in @(

            [pscustomobject]@{

                Id = $script:resetHotkeyId

                Definition = $reset

            },

            [pscustomobject]@{

                Id = $script:overlayHotkeyId

                Definition = $overlay

            },

            [pscustomobject]@{

                Id = $script:passHotkeyId

                Definition = $pass

            }

        )) {

            $ok = [TarteNative]::RegisterHotKey(

                $script:windowHandle,

                [int]$item.Id,

                [uint32]$item.Definition.Modifiers,

                [uint32]$item.Definition.VirtualKey

            )



            if (-not $ok) {

                foreach ($registeredId in $registeredIds) {

                    [void][TarteNative]::UnregisterHotKey(

                        $script:windowHandle,

                        $registeredId

                    )

                }



                throw (

                    ("Windows could not register {0}. " +

                    "It may already be used by another application.") -f

                    $item.Definition.Text

                )

            }



            $registeredIds.Add([int]$item.Id)

        }



        $script:hotkeysRegistered = $true

        $script:settings.ResetHotkey = $reset.Text

        $script:settings.OverlayHotkey = $overlay.Text

        $script:settings.PassHotkey = $pass.Text



        Sync-HotkeyControls

        Update-HotkeyLabels



        if (-not (Write-WindowSettings)) {

            throw (

                "The hotkeys were registered, but the settings file " +

                "could not be saved."

            )

        }



        if ($ShowStatus) {

            $HotkeyStatusText.Foreground = $window.Resources[

                "ThemeAccentTextBrush"

            ]

            $HotkeyStatusText.Text = (

                "Saved: Reset {0}, Show/Hide {1}, Click Through {2}." -f

                $reset.Text,

                $overlay.Text,

                $pass.Text

            )

        }



        Write-StartupDiagnostic "Hotkeys registered" (

            "reset={0} overlay={1} pass={2}" -f

            $reset.Text,

            $overlay.Text,

            $pass.Text

        )

        return $true

    }

    catch {

        $registrationError = $_

        Unregister-MeterHotkeys



        $script:settings.ResetHotkey = $previousReset

        $script:settings.OverlayHotkey = $previousOverlay

        $script:settings.PassHotkey = $previousPass

        Sync-HotkeyControls

        Update-HotkeyLabels



        if ($ShowStatus) {

            $HotkeyStatusText.Foreground = New-Brush "#F08A82"

            $HotkeyStatusText.Text = $registrationError.Exception.Message

        }



        try {

            $reset = Convert-HotkeyDefinition -Definition $previousReset

            $overlay = Convert-HotkeyDefinition -Definition $previousOverlay

            $pass = Convert-HotkeyDefinition -Definition $previousPass



            $resetOk = [TarteNative]::RegisterHotKey(

                $script:windowHandle,

                $script:resetHotkeyId,

                [uint32]$reset.Modifiers,

                [uint32]$reset.VirtualKey

            )

            $overlayOk = [TarteNative]::RegisterHotKey(

                $script:windowHandle,

                $script:overlayHotkeyId,

                [uint32]$overlay.Modifiers,

                [uint32]$overlay.VirtualKey

            )

            $passOk = [TarteNative]::RegisterHotKey(

                $script:windowHandle,

                $script:passHotkeyId,

                [uint32]$pass.Modifiers,

                [uint32]$pass.VirtualKey

            )



            $script:hotkeysRegistered = (

                $resetOk -and $overlayOk -and $passOk

            )

        }

        catch {

            $script:hotkeysRegistered = $false

        }



        Write-WindowError $registrationError

        return $false

    }

}



function Show-OverlayWindow {

    if ($script:windowHandle -eq [IntPtr]::Zero) {

        $window.Visibility = [Windows.Visibility]::Visible

        $window.Show()

        [void]$window.Activate()

        $script:overlayVisible = $true

        return

    }



    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {

        $window.WindowState = [Windows.WindowState]::Normal

        [void][TarteNative]::ShowWindow(

            $script:windowHandle,

            [TarteNative]::SW_RESTORE

        )

    }

    else {

        [void][TarteNative]::ShowWindow(

            $script:windowHandle,

            [TarteNative]::SW_SHOW

        )

    }



    $window.ShowInTaskbar = $true

    $script:overlayVisible = $true

    [void][TarteNative]::BringWindowToTop($script:windowHandle)

    [void][TarteNative]::SetForegroundWindow($script:windowHandle)

    [void]$window.Activate()

}



function Hide-OverlayWindow {

    if ($script:windowHandle -eq [IntPtr]::Zero) {

        $window.Hide()

    }

    else {

        [void][TarteNative]::ShowWindow(

            $script:windowHandle,

            [TarteNative]::SW_HIDE

        )

    }



    $script:overlayVisible = $false

}



function Toggle-OverlayVisibility {

    $visible = $script:overlayVisible

    if ($script:windowHandle -ne [IntPtr]::Zero) {

        $visible = [TarteNative]::IsWindowVisible(

            $script:windowHandle

        )

    }



    if ($visible) {

        Hide-OverlayWindow

        Write-StartupDiagnostic "Overlay hotkey" "hidden"

    }

    else {

        Show-OverlayWindow

        Write-StartupDiagnostic "Overlay hotkey" "shown"

    }

}



function Process-OverlayShowRequest {

    if (-not (Test-Path -LiteralPath $showRequestPath -PathType Leaf)) {

        return

    }



    try {

        Remove-Item -LiteralPath $showRequestPath -Force -ErrorAction SilentlyContinue

        Show-OverlayWindow

        [IO.File]::WriteAllText(

            $readyPath,

            ("TarteMeter v3.1.3 ready | " + [DateTime]::Now.ToString("o")),

            [Text.Encoding]::UTF8

        )

        Write-StartupDiagnostic "Existing window shown by request"

    }

    catch {

        Write-WindowError $_

    }

}





function Test-IsDataGrid {

    param([object]$Grid)

    return ($null -ne $Grid -and $Grid -is [Windows.Controls.DataGrid])

}



function Set-GridColumnWidths {

    param([object]$Grid, [double[]]$Widths)

    if (-not (Test-IsDataGrid $Grid) -or $null -eq $Widths) { return }

    $script:syncingColumnWidths = $true

    try {

        $count = [Math]::Min($Grid.Columns.Count, $Widths.Count)

        for ($index = 0; $index -lt $count; $index++) {

            $width = [Math]::Max(34.0, [Math]::Min(800.0, $Widths[$index]))

            $Grid.Columns[$index].Visibility = [Windows.Visibility]::Visible

            $Grid.Columns[$index].Width = [Windows.Controls.DataGridLength]::new($width)

        }

    }

    finally { $script:syncingColumnWidths = $false }

}



function Get-GridColumnWidths {

    param([object]$Grid)

    $widths = New-Object 'System.Collections.Generic.List[double]'

    if (-not (Test-IsDataGrid $Grid)) { return $widths.ToArray() }

    foreach ($column in $Grid.Columns) {

        $width = [double]$column.ActualWidth

        if ([double]::IsNaN($width) -or [double]::IsInfinity($width) -or $width -le 0) { $width = [double]$column.Width.Value }

        $widths.Add([Math]::Max(34.0, [Math]::Min(800.0, $width)))

    }

    return $widths.ToArray()

}



function Capture-ColumnWidths {

    if ($script:syncingColumnWidths) { return }

    if (Test-IsDataGrid $DamageGrid) { $script:settings.DamageColumnWidths = Get-GridColumnWidths $DamageGrid }

    if (Test-IsDataGrid $HistoryGrid) { $script:settings.HistoryColumnWidths = Get-GridColumnWidths $HistoryGrid }

    if (Test-IsDataGrid $LogCharacterGrid) { $script:settings.LogColumnWidths = Get-GridColumnWidths $LogCharacterGrid }

}



function Apply-SavedColumnWidths {

    Set-GridColumnWidths $DamageGrid $script:settings.DamageColumnWidths

    Set-GridColumnWidths $HistoryGrid $script:settings.HistoryColumnWidths

    Set-GridColumnWidths $LogCharacterGrid $script:settings.LogColumnWidths

}



function Register-ColumnWidthPersistence {

    # Widths are intentionally captured only when the window closes. WPF can

    # temporarily report different widths while the whole window is resizing;

    # saving those transient values caused columns to reset and drift.

}



function Unregister-ColumnWidthPersistence {

    $script:columnWidthHandlers.Clear()

}





function Update-AdaptiveLayout {

    $actualWidth = [double]$window.ActualWidth

    if ([double]::IsNaN($actualWidth) -or [double]::IsInfinity($actualWidth) -or $actualWidth -le 0) { $actualWidth = [double]$window.Width }

    $SettingsPanel.Width = [Math]::Max(270.0, [Math]::Min(340.0, $actualWidth - 10.0))

    if ($actualWidth -lt 470.0) { $HotkeyFooterText.Visibility = [Windows.Visibility]::Collapsed }

    else { $HotkeyFooterText.Visibility = [Windows.Visibility]::Visible }

    if ($actualWidth -lt 430.0) { $EditionLabel.Visibility = [Windows.Visibility]::Collapsed }

    else { $EditionLabel.Visibility = [Windows.Visibility]::Visible }

    if ($actualWidth -lt 350.0) { $VersionBadge.Visibility = [Windows.Visibility]::Collapsed }

    else { $VersionBadge.Visibility = [Windows.Visibility]::Visible }

    $BannerImage.Visibility = [Windows.Visibility]::Collapsed

}





function Set-TextScale {

    param([double]$Percent)

    $Percent = [Math]::Max(70.0, [Math]::Min(180.0, $Percent))

    $scale = $Percent / 100.0

    $script:settings.TextScale = $Percent

    $window.Resources["MeterTextSmall"] = [double][Math]::Max(7.0, 8.0 * $scale)

    $window.Resources["MeterTextNormal"] = [double][Math]::Max(8.0, 9.0 * $scale)

    $window.Resources["MeterTextMedium"] = [double][Math]::Max(9.0, 11.0 * $scale)

    $window.Resources["MeterTextTitle"] = [double][Math]::Max(10.0, 12.0 * $scale)

    $window.Resources["MeterTextStat"] = [double][Math]::Max(11.0, 14.0 * $scale)

    $window.Resources["MeterRowInnerHeight"] = [double][Math]::Max(16.0, 18.0 * $scale)

    $window.Resources["MeterControlHeight"] = [double][Math]::Max(24.0, 26.0 * $scale)

    foreach ($grid in @($DamageGrid, $HistoryGrid, $LogCharacterGrid)) {

        if (Test-IsDataGrid $grid) {

            $grid.RowHeight = [Math]::Max(23.0, 27.0 * $scale)

            $grid.ColumnHeaderHeight = [Math]::Max(23.0, 26.0 * $scale)

        }

    }

    $TitleBarRow.Height = [Windows.GridLength]::new(32.0)

    $SummaryRow.Height = [Windows.GridLength]::new([Math]::Max(54.0, 54.0 * $scale))

    $FooterRow.Height = [Windows.GridLength]::new([Math]::Max(28.0, 28.0 * $scale))

    $SettingsHeaderRow.Height = [Windows.GridLength]::new([Math]::Max(34.0, 34.0 * $scale))

    $TextScaleText.Text = "{0:0}%" -f $Percent

    Update-AdaptiveLayout

}



function Toggle-SettingsPanel {

    if ($SettingsPanel.Visibility -eq [Windows.Visibility]::Visible) {

        $SettingsPanel.Visibility = [Windows.Visibility]::Collapsed

    }

    else {

        $SettingsPanel.Visibility = [Windows.Visibility]::Visible

    }

}



function Update-MaximizeGlyph {

    if ($null -eq $MaximizeGlyph) { return }

    if ($window.WindowState -eq [Windows.WindowState]::Maximized) {

        $MaximizeGlyph.Text = [string][char]0xE923

        $MaximizeButton.ToolTip = "Restore"

    }

    else {

        $MaximizeGlyph.Text = [string][char]0xE922

        $MaximizeButton.ToolTip = "Maximize"

    }

}



function Toggle-MaximizeRestore {

    if ($window.WindowState -eq [Windows.WindowState]::Maximized) {

        $window.WindowState = [Windows.WindowState]::Normal

    }

    else {

        $window.WindowState = [Windows.WindowState]::Maximized

    }

    Update-MaximizeGlyph

}



function Start-WindowResize {

    param([int]$HitTestCode)



    if ($script:clickThroughEnabled) { return }

    if ($window.WindowState -eq [Windows.WindowState]::Maximized) { return }



    $source = [Windows.Interop.HwndSource]::FromVisual($window)

    if ($null -eq $source) { return }



    [void][TarteNative]::ReleaseCapture()

    [void][TarteNative]::SendMessage(

        $source.Handle,

        0x00A1,

        [IntPtr]$HitTestCode,

        [IntPtr]::Zero

    )

}



function Start-WindowDrag {

    if ($script:clickThroughEnabled) { return }



    if ($window.WindowState -eq [Windows.WindowState]::Maximized) {

        $point = New-Object TarteNative+POINT

        [void][TarteNative]::GetCursorPos([ref]$point)



        $screen = [Windows.SystemParameters]::WorkArea

        $restoreWidth = if ($window.RestoreBounds.Width -gt 0) {

            $window.RestoreBounds.Width

        }

        else { 640.0 }

        $restoreHeight = if ($window.RestoreBounds.Height -gt 0) {

            $window.RestoreBounds.Height

        }

        else { 360.0 }



        $relativeX = ($point.X - $screen.Left) / [Math]::Max(1.0, $screen.Width)

        $relativeX = [Math]::Max(0.05, [Math]::Min(0.95, $relativeX))



        $window.WindowState = [Windows.WindowState]::Normal

        $window.Width = $restoreWidth

        $window.Height = $restoreHeight

        $window.Left = $point.X - ($restoreWidth * $relativeX)

        $window.Top = [Math]::Max($screen.Top, $point.Y - 18.0)

        $window.UpdateLayout()

    }



    $window.DragMove()

}



function Set-ClickThrough {

    param(

        [bool]$Enabled,

        [bool]$Persist = $true

    )



    if ($script:windowHandle -ne [IntPtr]::Zero) {

        $style = [TarteNative]::GetWindowLongPtr(

            $script:windowHandle,

            [TarteNative]::GWL_EXSTYLE

        ).ToInt64()

        $style = $style -bor [TarteNative]::WS_EX_LAYERED



        if ($Enabled) {

            $style = $style -bor [TarteNative]::WS_EX_TRANSPARENT

        }

        else {

            $style = $style -band (-bnot [TarteNative]::WS_EX_TRANSPARENT)

        }



        [void][TarteNative]::SetWindowLongPtr(

            $script:windowHandle,

            [TarteNative]::GWL_EXSTYLE,

            [IntPtr]$style

        )

    }



    $script:clickThroughEnabled = $Enabled

    $script:settings.ClickThrough = $Enabled



    $script:syncingClickThroughCheck = $true

    try {

        $ClickThroughCheck.IsChecked = $Enabled

    }

    finally {

        $script:syncingClickThroughCheck = $false

    }

    if ($Persist) {

        Queue-SettingsSave

    }

}



function Get-CharacterBarBrush {

    param([string]$Name)



    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Unknown" }



    $known = @{

        "Tarte" = "#FFE06B"

        "Castella" = "#76D0FF"

        "Eileen" = "#8BE6A4"

        "Theresa" = "#FF8FB8"

        "Theresia" = "#FF8FB8"

        "Roxy" = "#6FCBFF"

        "Dana" = "#7FD6A5"

        "Chako" = "#C8A46A"

        "Ornette" = "#B9A5FF"

        "Kalsion" = "#FFAA7A"

        "Unknown" = "#8A99A8"

    }

    if ($known.ContainsKey($Name)) {

        return New-Brush $known[$Name]

    }



    $palette = @(

        "#FFE06B", "#76D0FF", "#8BE6A4", "#FF9CBD",

        "#C0AEFF", "#FFAA7A", "#7BE7E1", "#E8BA86",

        "#9FC5FF", "#D4A5FF", "#A8E68B", "#FFB3A7"

    )

    [long]$hash = 17

    foreach ($character in $Name.ToCharArray()) {

        $hash = (($hash * 31) + [int]$character) % 2147483647

    }

    return New-Brush $palette[[int]($hash % $palette.Count)]

}



function Read-MeterState {

    if (-not (Test-Path -LiteralPath $statePath)) { return }



    try {

        $lines = @(Read-AllLinesShared $statePath)

        if ($lines.Count -eq 0) { return }



        $status = "READY"

        $active = "Unknown"

        $enemy = "Unknown"

        $total = 0.0

        $overallDps = 0.0

        $elapsed = 0.0

        $snapshotRows = @{}



        foreach ($line in $lines) {

            if ($line -like "status=*") {

                $status = $line.Substring(7)

            }

            elseif ($line -like "active=*") {

                $active = $line.Substring(7)

            }

            elseif ($line -like "enemy=*") {

                $enemy = $line.Substring(6)

            }

            elseif ($line -like "total=*") {

                $total = Convert-ToNumber $line.Substring(6)

            }

            elseif ($line -like "overall_dps=*") {

                $overallDps = Convert-ToNumber $line.Substring(12)

            }

            elseif ($line -like "elapsed=*") {

                $elapsed = Convert-ToNumber $line.Substring(8)

            }

            elseif ($line -like "character=*") {

                $parts = $line.Substring(10) -split "\|"

                if ($parts.Length -lt 6) { continue }



                $name = [string]$parts[0]

                $damage = Convert-ToNumber $parts[1]

                if ([string]::IsNullOrWhiteSpace($name) -or $damage -le 0) {

                    continue

                }



                $snapshotRows[$name] = [pscustomobject]@{

                    Character = $name

                    DamageNumber = $damage

                    DpsNumber = Convert-ToNumber $parts[2]

                    ShareNumber = Convert-ToNumber $parts[3]

                    HitsNumber = [int](Convert-ToNumber $parts[4])

                    CritsNumber = [int](Convert-ToNumber $parts[5])

                    HighestNumber = if ($parts.Length -gt 6) {

                        Convert-ToNumber $parts[6]

                    }

                    else { 0.0 }

                    AverageNumber = if ($parts.Length -gt 7) {

                        Convert-ToNumber $parts[7]

                    }

                    else { 0.0 }

                }

            }

        }



        $isCleanReset = (

            $status -eq "READY" -and

            $total -le 0.0 -and

            $snapshotRows.Count -eq 0

        )



        if ($isCleanReset) {

            $script:characterRowCache = @{}

        }

        else {

            foreach ($name in $snapshotRows.Keys) {

                $script:characterRowCache[$name] = $snapshotRows[$name]

            }

        }



        $rawRows = @($script:characterRowCache.Values)

        $rows = New-Object 'System.Collections.Generic.List[object]'

        foreach ($row in ($rawRows | Sort-Object DamageNumber -Descending)) {

            $critRate = if ($row.HitsNumber -gt 0) {

                100.0 * $row.CritsNumber / $row.HitsNumber

            }

            else { 0.0 }



            $shareNumber = [Math]::Max(

                0.0,

                [Math]::Min(100.0, [double]$row.ShareNumber)

            )

            $barBrush = Get-CharacterBarBrush $row.Character



            $rows.Add([pscustomobject]@{

                Character = $row.Character

                Damage = "{0:N0}" -f $row.DamageNumber

                DPS = "{0:N0}" -f $row.DpsNumber

                Share = "{0:0.00}%" -f $shareNumber

                ShareNumber = $shareNumber

                ShareTooltip = (

                    "{0}  |  {1:0.00}% of total damage" -f

                    $row.Character,

                    $shareNumber

                )

                Hits = $row.HitsNumber

                CritRate = "{0:0.0}%" -f $critRate

                Highest = "{0:N0}" -f $row.HighestNumber

                Average = "{0:N0}" -f $row.AverageNumber

                BarBrush = $barBrush

            })

        }



        Update-ResetUiState $status

        $StatusText.Text = "$status | ACTIVE $active"

        $TargetText.Text = "TARGET  $enemy"

        $TotalText.Text = "{0:N0}" -f $total

        $DpsText.Text = "{0:N0} / {1:0.0}s" -f $overallDps, $elapsed

        $DamageGrid.ItemsSource = $rows

    }

    catch {

        Write-WindowError $_

    }

}



function Update-MeterIfChanged {

    param([bool]$Force = $false)



    try {

        if (-not (Test-Path -LiteralPath $statePath)) { return }

        $item = Get-Item -LiteralPath $statePath

        $stamp = "{0}:{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length

        if ($Force -or $stamp -ne $script:lastStateStamp) {

            $script:lastStateStamp = $stamp

            Read-MeterState

        }

    }

    catch {

        Write-WindowError $_

    }

}



function Get-JsonStringField {

    param([string]$Json, [string]$Field)



    $pattern = '"' + [regex]::Escape($Field) + '":"((?:\\.|[^"])*)"'

    $match = [regex]::Match($Json, $pattern)

    if (-not $match.Success) { return "" }



    try {

        return ('"' + $match.Groups[1].Value + '"') | ConvertFrom-Json

    }

    catch {

        return $match.Groups[1].Value

    }

}



function Get-JsonNumberField {

    param([string]$Json, [string]$Field)



    $pattern = '"' + [regex]::Escape($Field) + '":(-?\d+(?:\.\d+)?)'

    $match = [regex]::Match($Json, $pattern)

    if (-not $match.Success) { return 0.0 }

    return Convert-ToNumber $match.Groups[1].Value

}



function Get-HistoryIndexLine {

    param(

        [object]$Slice,

        [string]$RawJson

    )



    $timestamp = Get-JsonStringField $RawJson "timestamp"

    $reason = Get-JsonStringField $RawJson "reason"

    $target = Get-JsonStringField $RawJson "target"

    $timelineFile = Get-JsonStringField $RawJson "timeline_file"

    $battleId = Get-JsonStringField $RawJson "battle_id"

    if ([string]::IsNullOrWhiteSpace($battleId)) {

        $battleId = "legacy_{0}" -f $Slice.Offset

    }



    $duration = Get-JsonNumberField $RawJson "duration"

    $damage = Get-JsonNumberField $RawJson "total_damage"

    $dps = Get-JsonNumberField $RawJson "dps"

    $eventCount = [int](Get-JsonNumberField $RawJson "event_count")

    $truncated = Get-JsonBooleanField $RawJson "events_truncated"



    $fields = @(

        "v1",

        ([string]$battleId -replace "[\t\r\n]", " "),

        ([string]$timestamp -replace "[\t\r\n]", " "),

        ([string]$reason -replace "[\t\r\n]", " "),

        ([string]$target -replace "[\t\r\n]", " "),

        ("{0:0.000}" -f $duration),

        ("{0:0.0}" -f $damage),

        ("{0:0.0}" -f $dps),

        ([string]$timelineFile -replace "[\t\r\n]", " "),

        [string]$Slice.Offset,

        [string]$Slice.Length,

        [string]$eventCount,

        $(if ($truncated) { "1" } else { "0" })

    )

    return ($fields -join "`t")

}



function Load-HistoryOffsetCache {

    if ($script:historyOffsetCacheLoaded) { return }

    $script:historyOffsetCacheLoaded = $true

    $script:indexedHistoryOffsets = @{}



    if (-not (Test-Path -LiteralPath $historyIndexPath -PathType Leaf)) {

        return

    }



    foreach ($line in Get-Content -LiteralPath $historyIndexPath -Encoding UTF8) {

        $parts = @([string]$line -split "`t", 13)

        if ($parts.Count -lt 11) { continue }

        $offset = 0L

        if ([long]::TryParse($parts[9], [ref]$offset)) {

            $script:indexedHistoryOffsets[[string]$offset] = $true

        }

    }

}



function Refresh-HistoryOffsetCacheTail {

    if (-not (Test-Path -LiteralPath $historyIndexPath -PathType Leaf)) {

        return

    }



    foreach ($line in Get-Content -LiteralPath $historyIndexPath -Tail 8 -Encoding UTF8) {

        $parts = @([string]$line -split "`t", 13)

        if ($parts.Count -lt 11) { continue }

        $offset = 0L

        if ([long]::TryParse($parts[9], [ref]$offset)) {

            $script:indexedHistoryOffsets[[string]$offset] = $true

        }

    }

}



function Sync-HistoryIndexTail {

    param(

        [int]$MaximumLines = 4,

        [bool]$RewriteIndex = $false

    )



    $script:lastHistoryIndexSyncSucceeded = $false

    if (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) {

        $script:lastHistoryIndexSyncSucceeded = $true

        return

    }



    try {

        Load-HistoryOffsetCache

        Refresh-HistoryOffsetCacheTail

        $newRecords = New-Object 'System.Collections.Generic.List[object]'

        $slices = [TarteFileIndex]::GetLastUtf8LineSlices(

            $historyPath,

            [Math]::Max(1, $MaximumLines)

        )

        foreach ($slice in $slices) {

            $key = [string]$slice.Offset

            if ($script:indexedHistoryOffsets.ContainsKey($key)) { continue }



            # Indexing needs only the metadata prefix. Never decode a legacy

            # multi-megabyte events array just to refresh the History list.

            $raw = [TarteFileIndex]::ReadUtf8Prefix(

                $historyPath,

                $slice.Offset,

                $slice.Length,

                $script:historyIndexPrefixBytes

            )

            if ([string]::IsNullOrWhiteSpace($raw)) { continue }

            $line = Get-HistoryIndexLine -Slice $slice -RawJson $raw

            $newRecords.Add([pscustomobject]@{

                Offset = [long]$slice.Offset

                Line = $line

            })

        }



        if ($newRecords.Count -le 0) {

            $script:lastHistoryIndexSyncSucceeded = $true

            return

        }



        if ($RewriteIndex) {

            $allRecords = New-Object 'System.Collections.Generic.List[object]'

            if (Test-Path -LiteralPath $historyIndexPath -PathType Leaf) {

                foreach ($line in Get-Content -LiteralPath $historyIndexPath -Encoding UTF8) {

                    $parts = @([string]$line -split "`t", 13)

                    if ($parts.Count -lt 11) { continue }

                    $offset = 0L

                    if ([long]::TryParse($parts[9], [ref]$offset)) {

                        $allRecords.Add([pscustomobject]@{

                            Offset = $offset

                            Line = [string]$line

                        })

                    }

                }

            }

            foreach ($record in $newRecords) { $allRecords.Add($record) }

            $ordered = @(

                $allRecords |

                    Sort-Object Offset -Unique |

                    ForEach-Object { [string]$_.Line }

            )

            $temp = "$historyIndexPath.tmp"

            [IO.File]::WriteAllLines(

                $temp,

                $ordered,

                [Text.UTF8Encoding]::new($false)

            )

            Move-Item -LiteralPath $temp -Destination $historyIndexPath -Force

        }

        else {

            $orderedNew = @(

                $newRecords |

                    Sort-Object Offset |

                    ForEach-Object { [string]$_.Line }

            )

            [IO.File]::AppendAllLines(

                $historyIndexPath,

                $orderedNew,

                [Text.UTF8Encoding]::new($false)

            )

        }



        # Update the in-memory cache only after the index write commits. This

        # keeps a temporary file lock retryable instead of hiding missing rows.

        foreach ($record in $newRecords) {

            $script:indexedHistoryOffsets[[string]$record.Offset] = $true

        }

        $script:lastHistoryIndexSyncSucceeded = $true

    }

    catch {

        $script:lastHistoryIndexSyncSucceeded = $false

        Write-WindowError $_

    }

}



function Initialize-HistoryIndex {

    if ($script:historyIndexInitialized) { return }



    try {

        if (-not (Test-Path -LiteralPath $timelineArchiveRoot)) {

            [void](New-Item -ItemType Directory -Path $timelineArchiveRoot -Force)

        }



        if (

            -not (Test-Path -LiteralPath $historyIndexMarkerPath) -or

            -not (Test-Path -LiteralPath $historyIndexPath -PathType Leaf)

        ) {

            Write-StartupDiagnostic "History index migration started" (

                "Legacy tail up to " + $script:maxHistoryRows + " records"

            )

            Sync-HistoryIndexTail $script:maxHistoryRows $true

            if (-not $script:lastHistoryIndexSyncSucceeded) {

                throw "History index migration was interrupted."

            }



            # Do not mark a failed migration as complete. A later timer tick can

            # retry after a temporary file lock or incomplete history append.

            $historyHasData = (

                (Test-Path -LiteralPath $historyPath -PathType Leaf) -and

                (Get-Item -LiteralPath $historyPath).Length -gt 0

            )

            if (

                $historyHasData -and

                -not (Test-Path -LiteralPath $historyIndexPath -PathType Leaf)

            ) {

                throw "History index migration did not produce an index file."

            }



            [IO.File]::WriteAllText(

                $historyIndexMarkerPath,

                ("v1 " + [DateTime]::Now.ToString("o")),

                [Text.Encoding]::ASCII

            )

            Write-StartupDiagnostic "History index migration finished"

        }

        else {

            Sync-HistoryIndexTail 4

            if (-not $script:lastHistoryIndexSyncSucceeded) {

                throw "History index refresh was interrupted."

            }

        }



        $script:historyIndexInitialized = $true

    }

    catch {

        $script:historyIndexInitialized = $false

        Write-WindowError $_

    }

}



function Convert-HistoryIndexLine {

    param([string]$Line)



    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $parts = @($Line -split "`t", 13)

    if ($parts.Count -lt 13 -or $parts[0] -ne "v1") { return $null }



    $timestamp = [string]$parts[2]

    $date = $timestamp

    try {

        $date = ([datetime]$timestamp).ToLocalTime().ToString(

            "yyyy-MM-dd HH:mm"

        )

    }

    catch {}



    $offset = 0L

    $length = 0

    [void][long]::TryParse($parts[9], [ref]$offset)

    [void][int]::TryParse($parts[10], [ref]$length)



    return [pscustomobject]@{

        BattleId = [string]$parts[1]

        Date = $date

        Target = [string]$parts[4]

        Duration = "{0:0.0}s" -f (Convert-ToNumber $parts[5])

        Damage = "{0:N0}" -f (Convert-ToNumber $parts[6])

        DPS = "{0:N0}" -f (Convert-ToNumber $parts[7])

        Reason = [string]$parts[3]

        TimelineFile = [string]$parts[8]

        HistoryOffset = $offset

        HistoryLength = $length

        EventCount = [int](Convert-ToNumber $parts[11])

        EventsTruncated = ([string]$parts[12] -eq "1")

    }

}



function Read-BattleHistory {

    Initialize-HistoryIndex

    if (-not (Test-Path -LiteralPath $historyIndexPath)) {

        $HistoryGrid.ItemsSource = $null

        return

    }



    try {

        $selectedId = ""

        if ($null -ne $HistoryGrid.SelectedItem) {

            $selectedId = [string]$HistoryGrid.SelectedItem.BattleId

        }



        $lines = @(

            Get-Content `
                -LiteralPath $historyIndexPath `
                -Tail $script:maxHistoryRows `
                -Encoding UTF8 `
                -ErrorAction Stop

        )

        $rows = New-Object 'System.Collections.Generic.List[object]'

        for ($index = $lines.Count - 1; $index -ge 0; $index--) {

            $row = Convert-HistoryIndexLine ([string]$lines[$index])

            if ($null -ne $row) { $rows.Add($row) }

        }



        $script:syncingHistorySelection = $true

        try {

            $HistoryGrid.ItemsSource = $rows

            $HistoryGrid.SelectedIndex = -1

            if (-not [string]::IsNullOrWhiteSpace($selectedId)) {

                foreach ($row in $rows) {

                    if ([string]$row.BattleId -eq $selectedId) {

                        $HistoryGrid.SelectedItem = $row

                        break

                    }

                }

            }

        }

        finally {

            $script:syncingHistorySelection = $false

        }

    }

    catch {

        Write-WindowError $_

    }

}



function Update-HistoryIfChanged {

    param([bool]$Force = $false)



    try {

        Initialize-HistoryIndex



        $historyDataStamp = "missing"

        if (Test-Path -LiteralPath $historyPath) {

            $historyItem = Get-Item -LiteralPath $historyPath

            $historyDataStamp = "{0}:{1}" -f (

                $historyItem.LastWriteTimeUtc.Ticks,

                $historyItem.Length

            )

        }

        if ($Force -or $historyDataStamp -ne $script:lastHistoryDataStamp) {

            $script:lastHistoryDataStamp = $historyDataStamp

            Sync-HistoryIndexTail 4

        }



        if (-not (Test-Path -LiteralPath $historyIndexPath)) { return }

        $item = Get-Item -LiteralPath $historyIndexPath

        $stamp = "{0}:{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length

        if ($Force -or $stamp -ne $script:lastHistoryStamp) {

            $script:lastHistoryStamp = $stamp

            Read-BattleHistory

        }

    }

    catch {

        Write-WindowError $_

    }

}



function Get-JsonBooleanField {

    param([string]$Json, [string]$Field)



    $pattern = '"' + [regex]::Escape($Field) + '":(true|false)'

    $match = [regex]::Match(

        $Json,

        $pattern,

        [Text.RegularExpressions.RegexOptions]::IgnoreCase

    )

    if (-not $match.Success) { return $false }

    return $match.Groups[1].Value -ieq "true"

}



function Resolve-TimelineArchivePath {

    param([string]$RelativePath)



    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }

    if ([IO.Path]::IsPathRooted($RelativePath)) { return $null }

    if ($RelativePath.Contains("..")) { return $null }



    $normalized = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)

    $candidate = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $normalized))

    $root = [IO.Path]::GetFullPath($PSScriptRoot + [IO.Path]::DirectorySeparatorChar)

    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {

        return $null

    }

    return $candidate

}



function Convert-TimelineCsvLine {

    param([string]$Line)



    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $first = $Line.IndexOf(',')

    $last = $Line.LastIndexOf(',')

    if ($first -le 0 -or $last -le $first) { return $null }

    $secondLast = $Line.LastIndexOf(',', $last - 1)

    if ($secondLast -le $first) { return $null }



    $character = $Line.Substring(

        $first + 1,

        $secondLast - $first - 1

    )

    if ($character.Length -ge 2 -and $character[0] -eq '"' -and

        $character[$character.Length - 1] -eq '"') {

        $character = $character.Substring(1, $character.Length - 2)

        $character = $character.Replace('""', '"')

    }



    return [pscustomobject]@{

        time = Convert-ToNumber $Line.Substring(0, $first)

        character = $character

        damage = Convert-ToNumber $Line.Substring(

            $secondLast + 1,

            $last - $secondLast - 1

        )

        critical = ($Line.Substring($last + 1).Trim() -eq "1")

    }

}



function Open-SharedTextReader {

    param([string]$Path)



    $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor

        [int][IO.FileShare]::Delete)

    $stream = [IO.FileStream]::new(

        $Path,

        [IO.FileMode]::Open,

        [IO.FileAccess]::Read,

        $share

    )

    return [IO.StreamReader]::new(

        $stream,

        [Text.Encoding]::UTF8,

        $true

    )

}



function Read-TimelineArchive {

    param([string]$RelativePath)



    $path = Resolve-TimelineArchivePath $RelativePath

    if ($null -eq $path -or -not (Test-Path -LiteralPath $path)) {

        return $null

    }



    $count = 0

    $maxTime = 0.0

    $maxDamage = 0.0

    $reader = $null

    try {

        $reader = Open-SharedTextReader $path

        $header = $reader.ReadLine()

        while (($line = $reader.ReadLine()) -ne $null) {

            $event = Convert-TimelineCsvLine $line

            if ($null -eq $event) { continue }

            $count++

            if ($event.time -gt $maxTime) { $maxTime = $event.time }

            if ($event.damage -gt $maxDamage) { $maxDamage = $event.damage }

        }

    }

    finally {

        if ($null -ne $reader) { $reader.Dispose() }

    }



    if ($count -le 0) {

        return [pscustomobject]@{

            events = @()

            event_count = 0

            max_event_time = 0.0

            max_event_damage = 0.0

        }

    }



    $step = if ($count -gt $script:maxTimelineMarkers) {

        [int][Math]::Ceiling($count / [double]$script:maxTimelineMarkers)

    }

    else { 1 }



    $events = New-Object 'System.Collections.Generic.List[object]'

    $reader = $null

    $eventIndex = 0

    $lastEvent = $null

    try {

        $reader = Open-SharedTextReader $path

        $header = $reader.ReadLine()

        while (($line = $reader.ReadLine()) -ne $null) {

            $event = Convert-TimelineCsvLine $line

            if ($null -eq $event) { continue }

            $lastEvent = $event

            if (($eventIndex % $step) -eq 0) { $events.Add($event) }

            $eventIndex++

        }

    }

    finally {

        if ($null -ne $reader) { $reader.Dispose() }

    }



    if ($null -ne $lastEvent) {

        if ($events.Count -eq 0 -or

            $events[$events.Count - 1].time -ne $lastEvent.time -or

            $events[$events.Count - 1].damage -ne $lastEvent.damage) {

            $events.Add($lastEvent)

        }

    }



    return [pscustomobject]@{

        events = $events.ToArray()

        event_count = $count

        max_event_time = $maxTime

        max_event_damage = $maxDamage

    }

}



function Get-HistoryRecordJson {

    param([object]$Row)



    if ($null -eq $Row) { return "" }

    $offset = [long]$Row.HistoryOffset

    $length = [int]$Row.HistoryLength

    return [TarteFileIndex]::ReadUtf8Slice(

        $historyPath,

        $offset,

        $length

    )

}



function Convert-BattleRecord {

    param([string]$Json)



    if ([string]::IsNullOrWhiteSpace($Json)) {

        throw "The selected history line is empty."

    }



    # History entries can contain tens of thousands of events on one line.

    # Windows PowerShell 5.1 ConvertFrom-Json can fail on very large strings,

    # so parse the fixed TarteMeter JSONL schema without loading the full event

    # array into a JavaScriptSerializer instance.

    $clean = $Json.Trim()

    $clean = $clean.TrimStart(

        [char[]]@([char]0xFEFF, [char]0)

    )

    $clean = $clean.TrimEnd([char[]]@([char]0))

    if (-not $clean.StartsWith("{")) {

        throw "The selected history line does not start with a JSON object."

    }



    $battleId = Get-JsonStringField $clean "battle_id"

    $timestamp = Get-JsonStringField $clean "timestamp"

    $reason = Get-JsonStringField $clean "reason"

    $target = Get-JsonStringField $clean "target"

    $timelineFile = Get-JsonStringField $clean "timeline_file"

    $declaredEventCount = [int](Get-JsonNumberField $clean "event_count")

    $timelineLinesDropped = [int](Get-JsonNumberField $clean "timeline_lines_dropped")

    $duration = Get-JsonNumberField $clean "duration"

    $totalDamage = Get-JsonNumberField $clean "total_damage"

    $battleDps = Get-JsonNumberField $clean "dps"

    $eventsTruncated = Get-JsonBooleanField $clean "events_truncated"



    $characters = New-Object 'System.Collections.Generic.List[object]'

    $timelineEvents = New-Object 'System.Collections.Generic.List[object]'



    $charactersMarker = '"characters":['

    $eventsMarker = '],"events":['

    $charactersStart = $clean.IndexOf(

        $charactersMarker,

        [StringComparison]::Ordinal

    )

    $eventsStart = -1



    if ($charactersStart -ge 0) {

        $eventsStart = $clean.IndexOf(

            $eventsMarker,

            $charactersStart,

            [StringComparison]::Ordinal

        )

    }



    if ($charactersStart -ge 0 -and $eventsStart -gt $charactersStart) {

        $bodyStart = $charactersStart + $charactersMarker.Length

        $characterBody = $clean.Substring(

            $bodyStart,

            $eventsStart - $bodyStart

        )



        foreach ($match in [regex]::Matches($characterBody, '\{[^{}]*\}')) {

            $entryJson = $match.Value

            $name = Get-JsonStringField $entryJson "name"

            if ([string]::IsNullOrWhiteSpace($name)) { continue }



            $characters.Add([pscustomobject]@{

                name = $name

                damage = Get-JsonNumberField $entryJson "damage"

                dps = Get-JsonNumberField $entryJson "dps"

                share = Get-JsonNumberField $entryJson "share"

                hits = [int](Get-JsonNumberField $entryJson "hits")

                crits = [int](Get-JsonNumberField $entryJson "crits")

                crit_rate = Get-JsonNumberField $entryJson "crit_rate"

                highest_hit = Get-JsonNumberField $entryJson "highest_hit"

                average_hit = Get-JsonNumberField $entryJson "average_hit"

            })

        }

    }



    $eventBody = ""

    if ($eventsStart -ge 0) {

        $eventBodyStart = $eventsStart + $eventsMarker.Length

        $eventBodyEnd = $clean.LastIndexOf(

            ']}',

            [StringComparison]::Ordinal

        )

        if ($eventBodyEnd -lt $eventBodyStart) {

            $eventBodyEnd = $clean.Length

        }

        $eventBody = $clean.Substring(

            $eventBodyStart,

            $eventBodyEnd - $eventBodyStart

        )

    }

    else {

        # Compatibility with older entries that may not contain a characters

        # summary but do contain a detailed events array.

        $legacyEventsMarker = '"events":['

        $legacyStart = $clean.IndexOf(

            $legacyEventsMarker,

            [StringComparison]::Ordinal

        )

        if ($legacyStart -ge 0) {

            $eventBodyStart = $legacyStart + $legacyEventsMarker.Length

            $eventBodyEnd = $clean.LastIndexOf(

                ']}',

                [StringComparison]::Ordinal

            )

            if ($eventBodyEnd -lt $eventBodyStart) {

                $eventBodyEnd = $clean.Length

            }

            $eventBody = $clean.Substring(

                $eventBodyStart,

                $eventBodyEnd - $eventBodyStart

            )

        }

    }



    $eventMatches = @()

    if (-not [string]::IsNullOrWhiteSpace($eventBody)) {

        $eventMatches = @([regex]::Matches($eventBody, '\{[^{}]*\}'))

    }



    $eventCount = $eventMatches.Count

    $sampleLimit = [Math]::Max(1, $script:maxTimelineMarkers)

    $sampleStep = if ($eventCount -gt $sampleLimit) {

        [int][Math]::Ceiling($eventCount / [double]$sampleLimit)

    }

    else { 1 }



    $maxEventTime = 0.0

    $maxEventDamage = 0.0

    $aggregates = @{}

    $reconstructCharacters = $characters.Count -eq 0



    for ($eventIndex = 0; $eventIndex -lt $eventCount; $eventIndex++) {

        $eventJson = $eventMatches[$eventIndex].Value

        $eventTime = Get-JsonNumberField $eventJson "time"

        $eventCharacter = Get-JsonStringField $eventJson "character"

        if ([string]::IsNullOrWhiteSpace($eventCharacter)) {

            $eventCharacter = "Unknown"

        }

        $eventDamage = Get-JsonNumberField $eventJson "damage"

        $eventCritical = Get-JsonBooleanField $eventJson "critical"



        if ($eventTime -gt $maxEventTime) {

            $maxEventTime = $eventTime

        }

        if ($eventDamage -gt $maxEventDamage) {

            $maxEventDamage = $eventDamage

        }



        if (

            ($eventIndex % $sampleStep) -eq 0 -or

            $eventIndex -eq ($eventCount - 1)

        ) {

            $timelineEvents.Add([pscustomobject]@{

                time = $eventTime

                character = $eventCharacter

                damage = $eventDamage

                critical = $eventCritical

            })

        }



        if ($reconstructCharacters) {

            if (-not $aggregates.ContainsKey($eventCharacter)) {

                $aggregates[$eventCharacter] = [pscustomobject]@{

                    name = $eventCharacter

                    damage = 0.0

                    hits = 0

                    crits = 0

                    highest_hit = 0.0

                }

            }



            $aggregate = $aggregates[$eventCharacter]

            $aggregate.damage += $eventDamage

            $aggregate.hits += 1

            if ($eventCritical) { $aggregate.crits += 1 }

            if ($eventDamage -gt $aggregate.highest_hit) {

                $aggregate.highest_hit = $eventDamage

            }

        }

    }



    if ($reconstructCharacters -and $aggregates.Count -gt 0) {

        foreach ($aggregate in $aggregates.Values) {

            $characters.Add([pscustomobject]@{

                name = $aggregate.name

                damage = $aggregate.damage

                dps = if ($duration -gt 0) {

                    $aggregate.damage / $duration

                }

                else { 0.0 }

                share = if ($totalDamage -gt 0) {

                    100.0 * $aggregate.damage / $totalDamage

                }

                else { 0.0 }

                hits = $aggregate.hits

                crits = $aggregate.crits

                crit_rate = if ($aggregate.hits -gt 0) {

                    100.0 * $aggregate.crits / $aggregate.hits

                }

                else { 0.0 }

                highest_hit = $aggregate.highest_hit

                average_hit = if ($aggregate.hits -gt 0) {

                    $aggregate.damage / $aggregate.hits

                }

                else { 0.0 }

            })

        }

    }



    if (

        [string]::IsNullOrWhiteSpace($timestamp) -and

        $totalDamage -le 0 -and

        $characters.Count -eq 0

    ) {

        throw "The selected line is not a supported TarteMeter battle record."

    }



    if (-not [string]::IsNullOrWhiteSpace($timelineFile)) {

        $archive = Read-TimelineArchive $timelineFile

        if ($null -ne $archive -and $archive.event_count -gt 0) {

            $timelineEvents.Clear()

            foreach ($event in $archive.events) { $timelineEvents.Add($event) }

            $eventCount = [int]$archive.event_count

            $maxEventTime = Convert-ToNumber $archive.max_event_time

            $maxEventDamage = Convert-ToNumber $archive.max_event_damage

        }

        elseif ($declaredEventCount -gt $eventCount) {

            $eventCount = $declaredEventCount

        }

    }

    elseif ($declaredEventCount -gt $eventCount) {

        $eventCount = $declaredEventCount

    }



    return [pscustomobject]@{

        battle_id = $battleId

        timestamp = $timestamp

        reason = $reason

        target = $target

        duration = $duration

        total_damage = $totalDamage

        dps = $battleDps

        events_truncated = $eventsTruncated

        timeline_file = $timelineFile

        timeline_lines_dropped = $timelineLinesDropped

        characters = $characters.ToArray()

        events = $timelineEvents.ToArray()

        event_count = $eventCount

        max_event_time = $maxEventTime

        max_event_damage = $maxEventDamage

    }

}



function Get-LogCharacterEntries {

    param([object]$Battle)



    if ($null -eq $Battle -or $null -eq $Battle.characters) {

        return @()

    }



    return @($Battle.characters)

}



function Populate-LogCharacterGrid {

    param([object]$Battle)



    if ($null -eq $Battle) {

        $LogCharacterGrid.ItemsSource = $null

        $LogTargetText.Text = "SELECT AN ENCOUNTER"

        $LogMetaText.Text = "Saved encounters appear above"

        $LogTotalDamageText.Text = "0"

        $LogDpsText.Text = "0"

        $LogDurationText.Text = "0.0s"

        $LogCritText.Text = "0.0%"

        $LogPartySummaryText.Text = "0 MEMBERS / 0 HITS"

        return

    }



    $characters = @(

        Get-LogCharacterEntries $Battle |

            Sort-Object damage -Descending

    )



    $rows = New-Object 'System.Collections.Generic.List[object]'

    $rank = 1

    $totalHits = 0

    $totalCrits = 0

    $duration = Convert-ToNumber $Battle.duration

    $totalDamage = Convert-ToNumber $Battle.total_damage

    $battleDps = Convert-ToNumber $Battle.dps

    if ($battleDps -le 0 -and $duration -gt 0 -and $totalDamage -gt 0) {

        $battleDps = $totalDamage / $duration

    }



    foreach ($character in $characters) {

        $name = [string]$character.name

        $damage = Convert-ToNumber $character.damage

        $dps = Convert-ToNumber $character.dps

        $share = [Math]::Max(

            0.0,

            [Math]::Min(100.0, (Convert-ToNumber $character.share))

        )

        if ($share -le 0 -and $damage -gt 0 -and $totalDamage -gt 0) {

            $share = 100.0 * $damage / $totalDamage

        }

        if ($dps -le 0 -and $damage -gt 0 -and $duration -gt 0) {

            $dps = $damage / $duration

        }

        $hits = [int](Convert-ToNumber $character.hits)

        $crits = [int](Convert-ToNumber $character.crits)

        $critRate = Convert-ToNumber $character.crit_rate

        $highest = Convert-ToNumber $character.highest_hit

        $average = Convert-ToNumber $character.average_hit



        $totalHits += $hits

        $totalCrits += $crits



        $barBrush = Get-CharacterBarBrush $name



        $rows.Add([pscustomobject]@{

            Rank = $rank

            Character = $name

            Damage = "{0:N0}" -f $damage

            DPS = "{0:N0}" -f $dps

            Share = "{0:0.00}%" -f $share

            ShareNumber = $share

            CritRate = "{0:0.0}%" -f $critRate

            Hits = $hits

            Highest = "{0:N0}" -f $highest

            Average = "{0:N0}" -f $average

            BarBrush = $barBrush

            ShareTooltip = (

                "#{0} {1}`n{2:0.00}% of party damage`n{3:N0} damage / {4:N0} DPS" -f

                $rank,

                $name,

                $share,

                $damage,

                $dps

            )

        })

        $rank++

    }



    $partyCritRate = if ($totalHits -gt 0) {

        100.0 * $totalCrits / $totalHits

    }

    else { 0.0 }



    $timestamp = [string]$Battle.timestamp

    $localDate = $timestamp

    try {

        $localDate = ([datetime]$timestamp).ToLocalTime().ToString(

            "yyyy-MM-dd HH:mm:ss"

        )

    }

    catch {}



    $reason = [string]$Battle.reason

    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "saved" }



    $target = [string]$Battle.target

    if ([string]::IsNullOrWhiteSpace($target)) { $target = "Unknown target" }



    $LogTargetText.Text = $target.ToUpperInvariant()

    $LogMetaText.Text = "{0} / {1}" -f $localDate, $reason

    $LogTotalDamageText.Text = "{0:N0}" -f $totalDamage

    $LogDpsText.Text = "{0:N0}" -f $battleDps

    $LogDurationText.Text = "{0:0.0}s" -f $duration

    $LogCritText.Text = "{0:0.0}%" -f $partyCritRate

    $LogPartySummaryText.Text = (

        "{0} MEMBERS / {1:N0} HITS" -f

        $characters.Count,

        $totalHits

    )

    $LogCharacterGrid.ItemsSource = $rows

}



function Draw-LogsTimeline {

    param([object]$Battle)



    $HistoryTimelineCanvas.Children.Clear()

    if ($null -eq $Battle) {

        $HistoryTimelineLabel.Text = (

            "Select a saved encounter to view damage and critical hits over time"

        )

        return

    }



    $events = @($Battle.events)

    $totalEventCount = [int](Convert-ToNumber $Battle.event_count)

    if ($totalEventCount -le 0) {

        $totalEventCount = $events.Count

    }



    if ($events.Count -eq 0) {

        $HistoryTimelineLabel.Text = (

            "This entry has no detailed timeline data"

        )

        return

    }



    $height = [Math]::Max(

        40.0,

        $HistoryTimelineScroll.ViewportHeight

    )

    if ($height -le 40.0) {

        $height = [Math]::Max(

            40.0,

            $LogTimelineRow.ActualHeight - 18.0

        )

    }



    $maxTime = Convert-ToNumber $Battle.max_event_time

    $maxDamage = Convert-ToNumber $Battle.max_event_damage



    if ($maxTime -le 0) {

        foreach ($event in $events) {

            $eventTime = Convert-ToNumber $event.time

            if ($eventTime -gt $maxTime) { $maxTime = $eventTime }

        }

    }

    if ($maxDamage -le 0) {

        foreach ($event in $events) {

            $eventDamage = Convert-ToNumber $event.damage

            if ($eventDamage -gt $maxDamage) { $maxDamage = $eventDamage }

        }

    }



    if ($maxTime -le 0) { $maxTime = 1.0 }

    if ($maxDamage -le 0) { $maxDamage = 1.0 }



    # Fixed content scale: resizing the window never compresses or stretches

    # the encounter. The existing horizontal scrollbar moves through the canvas.

    $pixelsPerSecond = 96.0

    $pixelsPerEvent = 9.0

    $minimumContentWidth = 1400.0

    $maximumContentWidth = 24000.0



    $timeWidth = 52.0 + ($maxTime * $pixelsPerSecond)

    $densityWidth = 52.0 + ($events.Count * $pixelsPerEvent)

    $timelineWidth = [Math]::Min(

        $maximumContentWidth,

        [Math]::Max(

            $minimumContentWidth,

            [Math]::Max($timeWidth, $densityWidth)

        )

    )



    $HistoryTimelineCanvas.Width = $timelineWidth

    $HistoryTimelineCanvas.Height = $height



    $axis = New-Object Windows.Shapes.Line

    $axis.X1 = 34

    $axis.Y1 = $height - 18

    $axis.X2 = $timelineWidth - 12

    $axis.Y2 = $height - 18

    $axis.Stroke = New-Brush "#52667B"

    [void]$HistoryTimelineCanvas.Children.Add($axis)



    foreach ($event in $events) {

        $eventTime = Convert-ToNumber $event.time

        $eventDamage = Convert-ToNumber $event.damage

        $isCritical = [bool]$event.critical



        $x = 34 + ($eventTime / $maxTime) * ($timelineWidth - 52)

        $barHeight = [Math]::Max(

            3.0,

            ($eventDamage / $maxDamage) * ($height - 34)

        )

        $barTop = $height - $barHeight - 18



        $bar = New-Object Windows.Shapes.Rectangle

        $bar.Width = 5

        $bar.Height = $barHeight

        $bar.RadiusX = 2

        $bar.RadiusY = 2

        $bar.Fill = if ($isCritical) {

            New-Brush "#D89C28"

        }

        else {

            Get-CharacterBarBrush ([string]$event.character)

        }



        $tooltip = (

            "{0:0.000}s  |  {1}`n{2:N0} damage{3}" -f

            $eventTime,

            [string]$event.character,

            $eventDamage,

            $(if ($isCritical) { "  |  CRITICAL" } else { "" })

        )

        $bar.ToolTip = $tooltip

        [Windows.Controls.ToolTipService]::SetInitialShowDelay($bar, 80)

        [Windows.Controls.ToolTipService]::SetBetweenShowDelay($bar, 0)

        [Windows.Controls.ToolTipService]::SetShowDuration($bar, 12000)



        [Windows.Controls.Canvas]::SetLeft($bar, $x)

        [Windows.Controls.Canvas]::SetTop($bar, $barTop)

        [void]$HistoryTimelineCanvas.Children.Add($bar)

    }



    $markerText = if ($events.Count -lt $totalEventCount) {

        "{0}/{1} sampled hits" -f $events.Count, $totalEventCount

    }

    else {

        "{0} hits" -f $totalEventCount

    }

    $detailNotes = New-Object 'System.Collections.Generic.List[string]'

    if ([bool]$Battle.events_truncated) {

        $detailNotes.Add("detailed JSON preview capped")

    }

    $droppedTimelineLines = [int](

        Convert-ToNumber $Battle.timeline_lines_dropped

    )

    if ($droppedTimelineLines -gt 0) {

        $detailNotes.Add(("{0:N0} timeline rows dropped" -f $droppedTimelineLines))

    }

    $detailNote = if ($detailNotes.Count -gt 0) {

        " | " + ($detailNotes -join " | ")

    }

    else { "" }



    $HistoryTimelineLabel.Text = (

        "{0} | {1} | {2:0.0}s | gold = critical{3}" -f

        $Battle.target,

        $markerText,

        (Convert-ToNumber $Battle.duration),

        $detailNote

    )

}



function Select-HistoryEntry {

    if ($script:syncingHistorySelection) { return }

    $selected = $HistoryGrid.SelectedItem

    if ($null -eq $selected) { return }



    $battle = $null

    try {

        $rawJson = Get-HistoryRecordJson $selected

        $battle = Convert-BattleRecord $rawJson

    }

    catch {

        $script:selectedBattle = $null

        Populate-LogCharacterGrid $null

        $LogTargetText.Text = "LOG ENTRY READ ERROR"

        $LogMetaText.Text = "The saved line is incomplete or unsupported"

        $HistoryTimelineCanvas.Children.Clear()

        $HistoryTimelineLabel.Text = "The selected encounter could not be read"

        Write-WindowError (

            "LOG PARSE ERROR`r`n" +

            ($_ | Out-String)

        )

        return

    }



    try {

        $script:selectedBattle = $battle

        Populate-LogCharacterGrid $battle

        Draw-LogsTimeline $battle

    }

    catch {

        $script:selectedBattle = $null

        Populate-LogCharacterGrid $null

        $LogTargetText.Text = "LOG DISPLAY ERROR"

        $LogMetaText.Text = "The encounter was read, but the view failed"

        $HistoryTimelineCanvas.Children.Clear()

        $HistoryTimelineLabel.Text = "The selected encounter could not be displayed"

        Write-WindowError (

            "LOG DISPLAY ERROR`r`n" +

            ($_ | Out-String)

        )

    }

}



Write-StartupDiagnostic "Controls resolved" "UI_VARIANT_COMPACT"

Apply-SavedColumnWidths

Register-ColumnWidthPersistence

Write-StartupDiagnostic "Persistent column widths initialized"



foreach ($themeName in $script:themeNames) {

    [void]$ThemeCombo.Items.Add($themeName)

}



try {

    Apply-Theme ([string]$script:settings.Theme)

}

catch {

    Write-WindowError $_

    $script:settings.Theme = "MIDNIGHT GOLD"

    Write-StartupDiagnostic "Theme fallback" (

        "Using XAML default Midnight Gold resources"

    )

}



$ThemeCombo.SelectedItem = [string]$script:settings.Theme

$ThemeStatusText.Text = "Applied: " + [string]$script:settings.Theme



$hotkeyOptions = Get-HotkeyOptions

foreach ($combo in @($ResetHotkeyCombo, $OverlayHotkeyCombo, $PassHotkeyCombo)) {

    foreach ($option in $hotkeyOptions) {

        [void]$combo.Items.Add($option)

    }

}

Sync-HotkeyControls

Update-HotkeyLabels

Write-StartupDiagnostic "Theme and hotkey controls initialized"



try {

    if (Test-Path -LiteralPath $runtimeVersionPath) {

        $runtimeVersion = (Get-Content -LiteralPath $runtimeVersionPath -TotalCount 1 -ErrorAction Stop).Trim()

        if ($runtimeVersion -ne "TarteMeter v3.1.3") {

            Write-StartupDiagnostic "Runtime version mismatch" ("expected=TarteMeter v3.1.3 actual=" + $runtimeVersion)

        }

        else {

            Write-StartupDiagnostic "Runtime version" $runtimeVersion

        }

    }

}

catch {

    Write-StartupDiagnostic "Runtime version check failed" $_.Exception.Message

}



$OpacitySlider.Value = $script:settings.Opacity

$OpacityText.Text = "{0:0}%" -f $script:settings.Opacity

$window.Opacity = [Math]::Max(

    0.55,

    [Math]::Min(1.0, $script:settings.Opacity / 100.0)

)

$TextScaleSlider.Value = $script:settings.TextScale

Set-TextScale $script:settings.TextScale

$LogTimelineRow.Height = [Windows.GridLength]::new(

    [Math]::Max(

        58.0,

        [Math]::Min(

            320.0,

            [double]$script:settings.LogTimelineHeight

        )

    )

)

$window.Topmost = [bool]$script:settings.Topmost

$script:syncingTopmostCheck = $true

$TopmostCheck.IsChecked = [bool]$script:settings.Topmost

$script:syncingTopmostCheck = $false

$script:clickThroughEnabled = [bool]$script:settings.ClickThrough

$script:syncingClickThroughCheck = $true

$ClickThroughCheck.IsChecked = [bool]$script:settings.ClickThrough

$script:syncingClickThroughCheck = $false



$ResetButton.Add_Click({ Request-MeterReset })

$SettingsButton.Add_Click({ Toggle-SettingsPanel })

$SettingsCloseButton.Add_Click({

    $SettingsPanel.Visibility = [Windows.Visibility]::Collapsed

})

$ExitButton.Add_Click({

    Close-OverlayProcess "settings exit button"

})

$applyThemeChange = {

    if ($null -eq $ThemeCombo.SelectedItem) { return }

    if ($script:loadingSettings) { return }



    $previousTheme = [string]$script:settings.Theme

    try {

        $selectedTheme = [string]$ThemeCombo.SelectedItem

        Write-StartupDiagnostic "Theme requested" $selectedTheme

        Apply-Theme $selectedTheme



        if (-not (Write-WindowSettings)) {

            throw (

                "The theme was applied, but window_settings_v14_compact.ini " +

                "could not be saved."

            )

        }



        $ThemeStatusText.Text = "Applied and saved: " + $selectedTheme

    }

    catch {

        $themeError = $_

        Write-WindowError $themeError

        $ThemeStatusText.Text = "Theme error - see window_error.txt"

        $script:loadingSettings = $true

        try { $ThemeCombo.SelectedItem = $previousTheme }

        finally { $script:loadingSettings = $false }

    }

}



$ThemeCombo.Add_SelectionChanged($applyThemeChange)

$ApplyThemeButton.Add_Click($applyThemeChange)



$applyHotkeyChange = {

    if ($script:syncingHotkeyControls) { return }

    if ($script:windowHandle -eq [IntPtr]::Zero) { return }



    $hotkeyApplyTimer.Stop()

    $hotkeyApplyTimer.Start()

}



foreach ($combo in @(

    $ResetHotkeyCombo,

    $OverlayHotkeyCombo,

    $PassHotkeyCombo

)) {

    $combo.Add_SelectionChanged($applyHotkeyChange)

}



$ApplyHotkeysButton.Add_Click({

    $hotkeyApplyTimer.Stop()

    [void](Register-MeterHotkeys $true)

})

$window.Add_StateChanged({ Update-MaximizeGlyph })

Update-MaximizeGlyph



$MinimizeButton.Add_Click({

    $window.WindowState = [Windows.WindowState]::Minimized

})

$MaximizeButton.Add_Click({ Toggle-MaximizeRestore })

$CloseButton.Add_Click({ Close-OverlayProcess "title-bar close button" })



$TitleBar.Add_MouseLeftButtonDown({

    param($sender, $eventArgs)



    if ($eventArgs.OriginalSource -is [Windows.Controls.Button]) { return }

    if ($eventArgs.ClickCount -eq 2) {

        Toggle-MaximizeRestore

        return

    }

    Start-WindowDrag

})



$ResizeTopLeft.Add_MouseLeftButtonDown({ Start-WindowResize 13 })

$ResizeTop.Add_MouseLeftButtonDown({ Start-WindowResize 12 })

$ResizeTopRight.Add_MouseLeftButtonDown({ Start-WindowResize 14 })

$ResizeLeft.Add_MouseLeftButtonDown({ Start-WindowResize 10 })

$ResizeRight.Add_MouseLeftButtonDown({ Start-WindowResize 11 })

$ResizeBottomLeft.Add_MouseLeftButtonDown({ Start-WindowResize 16 })

$ResizeBottom.Add_MouseLeftButtonDown({ Start-WindowResize 15 })

$ResizeBottomRight.Add_MouseLeftButtonDown({ Start-WindowResize 17 })



$HistoryGrid.Add_SelectionChanged({ Select-HistoryEntry })



$LogTimelineSplitter.Add_DragCompleted({

    $script:settings.LogTimelineHeight = [Math]::Max(

        58.0,

        [Math]::Min(320.0, $LogTimelineRow.ActualHeight)

    )

    Queue-SettingsSave



    if ($null -ne $script:selectedBattle) {

        $timelineResizeTimer.Stop()

        $timelineResizeTimer.Start()

    }

})



$window.Add_SizeChanged({

    $layoutResizeTimer.Stop()

    $layoutResizeTimer.Start()



    if ($null -ne $script:selectedBattle) {

        $timelineResizeTimer.Stop()

        $timelineResizeTimer.Start()

    }

})



$OpacitySlider.Add_ValueChanged({

    $percent = [Math]::Round($OpacitySlider.Value)

    $script:settings.Opacity = $percent

    $window.Opacity = [Math]::Max(

        0.55,

        [Math]::Min(1.0, $percent / 100.0)

    )

    $OpacityText.Text = "{0:0}%" -f $percent

    Queue-SettingsSave

})



$TextScaleSlider.Add_ValueChanged({

    $percent = [Math]::Round($TextScaleSlider.Value)

    Set-TextScale $percent

    Queue-SettingsSave

})



$TopmostCheck.Add_Checked({

    if (-not $script:syncingTopmostCheck) {

        $window.Topmost = $true

        $script:settings.Topmost = $true

        Queue-SettingsSave

    }

})

$TopmostCheck.Add_Unchecked({

    if (-not $script:syncingTopmostCheck) {

        $window.Topmost = $false

        $script:settings.Topmost = $false

        Queue-SettingsSave

    }

})

$ClickThroughCheck.Add_Checked({

    if (-not $script:syncingClickThroughCheck) {

        Set-ClickThrough $true

    }

})

$ClickThroughCheck.Add_Unchecked({

    if (-not $script:syncingClickThroughCheck) {

        Set-ClickThrough $false

    }

})





$window.Add_SourceInitialized({

    $helper = New-Object Windows.Interop.WindowInteropHelper($window)

    $script:windowHandle = $helper.Handle

    $source = [Windows.Interop.HwndSource]::FromHwnd($script:windowHandle)



    $hook = [Windows.Interop.HwndSourceHook]{

        param(

            [IntPtr]$hwnd,

            [int]$message,

            [IntPtr]$wParam,

            [IntPtr]$lParam,

            [ref]$handled

        )



        if ($message -eq [TarteNative]::WM_HOTKEY) {

            $hotkeyId = $wParam.ToInt32()

            if ($hotkeyId -eq $script:resetHotkeyId) {

                Request-MeterReset

                $handled.Value = $true

            }

            elseif ($hotkeyId -eq $script:overlayHotkeyId) {

                Toggle-OverlayVisibility

                $handled.Value = $true

            }

            elseif ($hotkeyId -eq $script:passHotkeyId) {

                Set-ClickThrough (-not $script:clickThroughEnabled)

                $handled.Value = $true

            }

        }

        return [IntPtr]::Zero

    }



    $source.AddHook($hook)

    [void](Register-MeterHotkeys $false)

    Set-ClickThrough ([bool]$script:settings.ClickThrough) $false

})



$timer = New-Object Windows.Threading.DispatcherTimer

$timer.Interval = [TimeSpan]::FromMilliseconds(750)

$timer.Add_Tick({

    if (-not (Test-WatchedGameProcessAlive)) {

        $timer.Stop()

        Close-OverlayProcess "DragonSword process exited"

        return

    }



    Process-OverlayShowRequest

    Update-MeterIfChanged

    Update-HistoryIfChanged

})



$window.Add_Loaded({

    Write-StartupDiagnostic "Window Loaded event"

    Initialize-GameProcessWatch



    try {

        [IO.File]::WriteAllText(

            $windowBuildPath,

            "TarteMeter v3.1.3 | mutex v313 | UI COMPACT",

            [Text.Encoding]::ASCII

        )

        [void](Write-WindowSettings)

    }

    catch {

        Write-WindowError $_

    }



    try {

        Show-OverlayWindow

    }

    catch {

        Write-StartupDiagnostic "Visibility recovery warning" $_.Exception.Message

    }



    try {

        [IO.File]::WriteAllText(

            $readyPath,

            ("TarteMeter v3.1.3 ready | " + [DateTime]::Now.ToString("o")),

            [Text.Encoding]::UTF8

        )

    }

    catch {}

    Update-MeterIfChanged $true

    Update-HistoryIfChanged $true

    $timer.Start()

    Write-StartupDiagnostic "Overlay ready and timer started"

})



$window.Add_Closed({

    $timer.Stop()

    $settingsSaveTimer.Stop()

    $timelineResizeTimer.Stop()

    $layoutResizeTimer.Stop()

    $hotkeyApplyTimer.Stop()

    try { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue } catch {}

    Capture-ColumnWidths

    Unregister-ColumnWidthPersistence

    [void](Write-WindowSettings)



    Unregister-MeterHotkeys



    if ($null -ne $instanceMutex) {

        try { $instanceMutex.ReleaseMutex() } catch {}

        $instanceMutex.Dispose()

        $instanceMutex = $null

    }



    try {

        if ($null -ne [Windows.Application]::Current) {

            [Windows.Application]::Current.Shutdown()

        }

    }

    catch {}

})



try {

    [void]$window.ShowDialog()

}

catch {

    Write-WindowError $_

    throw

}

finally {

    try { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue } catch {}

    if ($null -ne $instanceMutex) {

        try { $instanceMutex.ReleaseMutex() } catch {}

        $instanceMutex.Dispose()

    }

}

