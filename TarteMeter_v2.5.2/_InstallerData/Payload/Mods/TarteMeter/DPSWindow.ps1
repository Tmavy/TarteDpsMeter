$ErrorActionPreference = "Stop"

$statePath = Join-Path $PSScriptRoot "dps_state.txt"
$commandPath = Join-Path $PSScriptRoot "dps_command.txt"
$historyPath = Join-Path $PSScriptRoot "battle_history.jsonl"
$errorPath = Join-Path $PSScriptRoot "window_error.txt"
$startupErrorPath = Join-Path $PSScriptRoot "startup_error.txt"
$startupDiagnosticPath = Join-Path $PSScriptRoot "startup_diagnostic.txt"
$readyPath = Join-Path $PSScriptRoot "window_ready.flag"
$showRequestPath = Join-Path $PSScriptRoot "overlay_show.request"
$iconPath = Join-Path $PSScriptRoot "Assets\TarteMeter.ico"
$portraitPath = Join-Path $PSScriptRoot "Assets\tarte.png"
$bannerPath = Join-Path $PSScriptRoot "Assets\banner.png"
$settingsPath = Join-Path $PSScriptRoot "window_settings_v5.ini"
$legacySettingsPathV4 = Join-Path $PSScriptRoot "window_settings_v4.ini"
$legacySettingsPathV3 = Join-Path $PSScriptRoot "window_settings_v3.ini"

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
Write-StartupDiagnostic "Startup architecture" "detached PowerShell; overlay mutex v250"

$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex(
    $true,
    "Local\TarteMeterOverlay_v250",
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
$script:lastErrorText = ""
$script:lastErrorWrite = [datetime]::MinValue
$script:resetHotkeyId = 0x5441
$script:overlayHotkeyId = 0x5442
$script:passHotkeyId = 0x5443
$script:hotkeysRegistered = $false
$script:syncingHotkeyControls = $false
$script:forceClose = $false
$script:maxHistoryRows = 200
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
                if ($value -ge 80 -and $value -le 140) {
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
        }
    }
    return $true
}

function Read-WindowSettings {
    try {
        if (Import-SettingsFile $settingsPath) { return }
        if (Import-SettingsFile $legacySettingsPathV4) { return }

        # One-time migration from the older opacity-only settings file.
        if (Test-Path -LiteralPath $legacySettingsPathV3) {
            $legacyValue = Convert-ToNumber(
                [IO.File]::ReadAllText($legacySettingsPathV3).Trim()
            )
            if ($legacyValue -ge 55 -and $legacyValue -le 100) {
                $script:settings.Opacity = $legacyValue
            }
        }
    }
    catch {
        Write-WindowError $_
    }
}

function Write-WindowSettings {
    try {
        $lines = @(
            "Opacity={0:0}" -f $script:settings.Opacity,
            "TextScale={0:0}" -f $script:settings.TextScale,
            "Topmost={0}" -f $script:settings.Topmost,
            "ClickThrough={0}" -f $script:settings.ClickThrough,
            "Theme={0}" -f $script:settings.Theme,
            "ResetHotkey={0}" -f $script:settings.ResetHotkey,
            "OverlayHotkey={0}" -f $script:settings.OverlayHotkey,
            "PassHotkey={0}" -f $script:settings.PassHotkey
        )
        $tempPath = "$settingsPath.tmp"
        [IO.File]::WriteAllLines(
            $tempPath,
            $lines,
            [Text.Encoding]::ASCII
        )
        Move-Item -LiteralPath $tempPath -Destination $settingsPath -Force
    }
    catch {
        Write-WindowError $_
    }
}

Read-WindowSettings

[void][TarteNative]::SetCurrentProcessExplicitAppUserModelID(
    "TarteMeter.DragonSword.CombatAnalyzer"
)

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="TarteMeter v2.5.2"
        Width="690"
        Height="410"
        MinWidth="560"
        MinHeight="340"
        WindowStyle="None"
        WindowStartupLocation="CenterScreen"
        ShowInTaskbar="True"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="CanResize"
        Topmost="True"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        FontFamily="Bahnschrift, Segoe UI Variable, Segoe UI"
        Foreground="{DynamicResource ThemeTextBrush}">
 <Window.Resources>
  <sys:Double x:Key="MeterTextSmall">8</sys:Double>
  <sys:Double x:Key="MeterTextNormal">9</sys:Double>
  <sys:Double x:Key="MeterTextMedium">11</sys:Double>
  <sys:Double x:Key="MeterTextTitle">12</sys:Double>
  <sys:Double x:Key="MeterTextStat">13</sys:Double>
  <SolidColorBrush x:Key="ThemeWindowBrush" Color="#101722"/>
  <SolidColorBrush x:Key="ThemeChromeBrush" Color="#151F2D"/>
  <SolidColorBrush x:Key="ThemePanelBrush" Color="#172332"/>
  <SolidColorBrush x:Key="ThemePanelAltBrush" Color="#121C28"/>
  <SolidColorBrush x:Key="ThemeGridBrush" Color="#0F1722"/>
  <SolidColorBrush x:Key="ThemeHeaderBrush" Color="#202D3D"/>
  <SolidColorBrush x:Key="ThemeButtonBrush" Color="#223044"/>
  <SolidColorBrush x:Key="ThemeBadgeBrush" Color="#2B3A4D"/>
  <SolidColorBrush x:Key="ThemeBorderBrush" Color="#3A4B60"/>
  <SolidColorBrush x:Key="ThemeGridLineBrush" Color="#263648"/>
  <SolidColorBrush x:Key="ThemeAccentBrush" Color="#D8B15D"/>
  <SolidColorBrush x:Key="ThemeAccentTextBrush" Color="#F0D59B"/>
  <SolidColorBrush x:Key="ThemeTextBrush" Color="#E9EEF5"/>
  <SolidColorBrush x:Key="ThemeMutedBrush" Color="#8FA0B4"/>
  <SolidColorBrush x:Key="ThemeHoverBrush" Color="#1E2D3E"/>
  <SolidColorBrush x:Key="ThemeSelectionBrush" Color="#263A50"/>
  <SolidColorBrush x:Key="ThemeSelectionBorderBrush" Color="#D5B56D"/>
  <SolidColorBrush x:Key="ThemeTrackBrush" Color="#0A111A"/>
  <Style TargetType="Button">
   <Setter Property="Foreground" Value="#E9EEF5"/>
   <Setter Property="Background" Value="#223044"/>
   <Setter Property="BorderBrush" Value="#40536A"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="7,2"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style TargetType="CheckBox">
   <Setter Property="Foreground" Value="#E9EEF5"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <Style TargetType="ComboBox">
   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>
   <Setter Property="Background" Value="{DynamicResource ThemeButtonBrush}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorderBrush}"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="Padding" Value="5,1"/>
  </Style>
  <Style TargetType="ComboBoxItem">
   <Setter Property="Foreground" Value="{DynamicResource ThemeTextBrush}"/>
   <Setter Property="Background" Value="{DynamicResource ThemePanelBrush}"/>
   <Setter Property="Padding" Value="5,2"/>
   <Style.Triggers>
    <Trigger Property="IsHighlighted" Value="True">
     <Setter Property="Background" Value="{DynamicResource ThemeSelectionBrush}"/>
     <Setter Property="Foreground" Value="#FFFFFF"/>
    </Trigger>
   </Style.Triggers>
  </Style>
  <Style TargetType="TabItem">
   <Setter Property="Foreground" Value="#DDE6EF"/>
   <Setter Property="Background" Value="#172332"/>
   <Setter Property="BorderBrush" Value="#33465A"/>
   <Setter Property="Padding" Value="7,2"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="MeterHeaderStyle" TargetType="DataGridColumnHeader">
   <Setter Property="Background" Value="#202D3D"/>
   <Setter Property="Foreground" Value="#F0D59B"/>
   <Setter Property="FontWeight" Value="Bold"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="BorderBrush" Value="#3A4B60"/>
   <Setter Property="BorderThickness" Value="0,0,1,1"/>
   <Setter Property="Padding" Value="5,2"/>
  </Style>
  <Style x:Key="MeterCellStyle" TargetType="DataGridCell">
   <Setter Property="Foreground" Value="#E8EEF5"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderBrush" Value="#253547"/>
   <Setter Property="BorderThickness" Value="0,0,1,0"/>
   <Setter Property="Padding" Value="4,0"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Style.Triggers>
    <Trigger Property="IsSelected" Value="True">
     <Setter Property="Foreground" Value="#FFFFFF"/>
     <Setter Property="Background" Value="Transparent"/>
    </Trigger>
   </Style.Triggers>
  </Style>
  <Style x:Key="MeterRowStyle" TargetType="DataGridRow">
   <Setter Property="Foreground" Value="#F2F5F8"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="1,0,1,0"/>
   <Setter Property="SnapsToDevicePixels" Value="True"/>
   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
     <Setter Property="Background" Value="#1E2D3E"/>
     <Setter Property="BorderBrush" Value="#60758C"/>
    </Trigger>
    <Trigger Property="IsSelected" Value="True">
     <Setter Property="Foreground" Value="#FFFFFF"/>
     <Setter Property="Background" Value="#263A50"/>
     <Setter Property="BorderBrush" Value="#D5B56D"/>
     <Setter Property="BorderThickness" Value="1"/>
    </Trigger>
   </Style.Triggers>
  </Style>
  <Style x:Key="DamageRowStyle"
         TargetType="DataGridRow"
         BasedOn="{StaticResource MeterRowStyle}">
   <Setter Property="ToolTip" Value="{Binding ShareTooltip}"/>
  </Style>
  <Style x:Key="ShareBarStyle" TargetType="ProgressBar">
   <Setter Property="Minimum" Value="0"/>
   <Setter Property="Maximum" Value="100"/>
   <Setter Property="Height" Value="14"/>
   <Setter Property="Background" Value="#0A111A"/>
   <Setter Property="BorderBrush" Value="#3A4B5E"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="ProgressBar">
      <Border Background="{TemplateBinding Background}"
              BorderBrush="{TemplateBinding BorderBrush}"
              BorderThickness="{TemplateBinding BorderThickness}"
              CornerRadius="3"
              SnapsToDevicePixels="True">
       <Grid x:Name="PART_Track"
             ClipToBounds="True">
        <Border x:Name="PART_Indicator"
                HorizontalAlignment="Left"
                Background="{TemplateBinding Foreground}"
                CornerRadius="2"
                Opacity="0.82"/>
       </Grid>
      </Border>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="MeterGridStyle" TargetType="DataGrid">
   <Setter Property="AutoGenerateColumns" Value="False"/>
   <Setter Property="IsReadOnly" Value="True"/>
   <Setter Property="CanUserAddRows" Value="False"/>
   <Setter Property="CanUserDeleteRows" Value="False"/>
   <Setter Property="CanUserResizeRows" Value="False"/>
   <Setter Property="HeadersVisibility" Value="Column"/>
   <Setter Property="GridLinesVisibility" Value="Horizontal"/>
   <Setter Property="HorizontalGridLinesBrush" Value="#263648"/>
   <Setter Property="Background" Value="#0F1722"/>
   <Setter Property="RowBackground" Value="#121C28"/>
   <Setter Property="AlternatingRowBackground" Value="#172332"/>
   <Setter Property="Foreground" Value="#F2F5F8"/>
   <Setter Property="BorderThickness" Value="0"/>
   <Setter Property="RowHeight" Value="23"/>
   <Setter Property="ColumnHeaderHeight" Value="23"/>
   <Setter Property="ColumnHeaderStyle" Value="{StaticResource MeterHeaderStyle}"/>
   <Setter Property="CellStyle" Value="{StaticResource MeterCellStyle}"/>
   <Setter Property="RowStyle" Value="{StaticResource MeterRowStyle}"/>
   <Setter Property="SelectionMode" Value="Single"/>
   <Setter Property="SelectionUnit" Value="FullRow"/>
   <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
   <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
   <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
   <Setter Property="EnableRowVirtualization" Value="True"/>
   <Setter Property="EnableColumnVirtualization" Value="True"/>
  </Style>
 </Window.Resources>
 <Border CornerRadius="8"
         BorderThickness="1"
         BorderBrush="{DynamicResource ThemeAccentBrush}"
         Background="{DynamicResource ThemeWindowBrush}"
         ClipToBounds="True">
  <Grid>
   <Grid.RowDefinitions>
    <RowDefinition Height="34"/>
    <RowDefinition Height="48"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="27"/>
   </Grid.RowDefinitions>

   <Grid x:Name="TitleBar" Grid.Row="0" Background="{DynamicResource ThemeChromeBrush}">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="35"/>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Border Width="28" Height="28" CornerRadius="6" Margin="3">
     <Image x:Name="PortraitImage" Stretch="UniformToFill"/>
    </Border>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
     <TextBlock Text="TARTE"
                FontSize="{DynamicResource MeterTextTitle}"
                FontWeight="Bold"
                Foreground="{DynamicResource ThemeAccentBrush}"/>
     <TextBlock Text="METER"
                FontSize="{DynamicResource MeterTextTitle}"
                FontWeight="SemiBold"
                Margin="4,0,0,0"
                Foreground="{DynamicResource ThemeTextBrush}"/>
     <Border Background="{DynamicResource ThemeBadgeBrush}"
             CornerRadius="6"
             Padding="5,1"
             Margin="6,0,0,0">
      <TextBlock Text="v2.5.2"
                 FontSize="{DynamicResource MeterTextSmall}"
                 Foreground="{DynamicResource ThemeAccentTextBrush}"/>
     </Border>
     <TextBlock Text="COMBAT ANALYZER"
                FontSize="{DynamicResource MeterTextSmall}"
                Foreground="{DynamicResource ThemeMutedBrush}"
                Margin="7,1,0,0"
                VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal">
     <Button x:Name="SettingsButton"
             ToolTip="Settings"
             Width="34"
             Background="Transparent"
             BorderThickness="0"
             Padding="0">
      <Viewbox Width="21" Height="21">
       <Grid Width="22" Height="22">
        <Path Stroke="{DynamicResource ThemeTextBrush}"
              StrokeThickness="2"
              StrokeLineJoin="Round"
              Fill="Transparent"
              Data="M8,1 L14,1 L14.8,4 L17.2,2.8 L19.2,4.8 L18,7.2 L21,8 L21,14 L18,14.8 L19.2,17.2 L17.2,19.2 L14.8,18 L14,21 L8,21 L7.2,18 L4.8,19.2 L2.8,17.2 L4,14.8 L1,14 L1,8 L4,7.2 L2.8,4.8 L4.8,2.8 L7.2,4 Z"/>
        <Ellipse Width="7"
                 Height="7"
                 Stroke="{DynamicResource ThemeTextBrush}"
                 StrokeThickness="2"
                 Fill="Transparent"
                 HorizontalAlignment="Center"
                 VerticalAlignment="Center"/>
       </Grid>
      </Viewbox>
     </Button>
     <Button x:Name="MinimizeButton"
             ToolTip="Minimize"
             Width="27"
             Background="Transparent"
             BorderThickness="0"
             Padding="0">
      <Rectangle Width="11"
                 Height="1.5"
                 Fill="#DDE6EF"
                 VerticalAlignment="Center"/>
     </Button>
     <Button x:Name="MaximizeButton"
             ToolTip="Maximize / Restore"
             Width="27"
             Background="Transparent"
             BorderThickness="0"
             Padding="0">
      <Border Width="10"
              Height="9"
              BorderBrush="#DDE6EF"
              BorderThickness="1.4"/>
     </Button>
     <Button x:Name="CloseButton"
             ToolTip="Hide meter (use the overlay hotkey to reopen)"
             Width="27"
             Background="Transparent"
             BorderThickness="0"
             Padding="0">
      <Viewbox Width="12" Height="12">
       <Path Stroke="#E07A72"
             StrokeThickness="1.8"
             StrokeStartLineCap="Round"
             StrokeEndLineCap="Round"
             Data="M1,1 L11,11 M11,1 L1,11"/>
      </Viewbox>
     </Button>
    </StackPanel>
   </Grid>

   <Grid Grid.Row="1" Margin="4,3,4,3">
    <Image x:Name="BannerImage" Stretch="UniformToFill" Opacity="0.15"/>
    <Border Background="#C0141E2B"
            CornerRadius="7"
            BorderBrush="{DynamicResource ThemeBorderBrush}"
            BorderThickness="1"/>
    <Grid Margin="6,3">
     <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="112"/>
      <ColumnDefinition Width="112"/>
     </Grid.ColumnDefinitions>
     <StackPanel VerticalAlignment="Center">
      <TextBlock x:Name="StatusText"
                 Text="READY"
                 FontSize="{DynamicResource MeterTextNormal}"
                 FontWeight="SemiBold"
                 Foreground="#8FA4BA"/>
      <TextBlock x:Name="TargetText"
                 Text="TARGET  Unknown"
                 FontSize="{DynamicResource MeterTextMedium}"
                 FontWeight="Bold"
                 Foreground="{DynamicResource ThemeTextBrush}"
                 Margin="0,1,0,0"
                 TextTrimming="CharacterEllipsis"/>
     </StackPanel>
     <Border Grid.Column="1"
             Background="#1B2736"
             CornerRadius="6"
             Margin="3,0"
             Padding="6,3">
      <StackPanel>
       <TextBlock Text="TOTAL DAMAGE"
                  FontSize="{DynamicResource MeterTextSmall}"
                  FontWeight="Bold"
                  Foreground="{DynamicResource ThemeAccentBrush}"/>
       <TextBlock x:Name="TotalText"
                  Text="0"
                  FontSize="{DynamicResource MeterTextStat}"
                  FontWeight="Bold"
                  Foreground="{DynamicResource ThemeTextBrush}"/>
      </StackPanel>
     </Border>
     <Border Grid.Column="2"
             Background="#182739"
             CornerRadius="6"
             Margin="3,0,0,0"
             Padding="6,3">
      <StackPanel>
       <TextBlock Text="DPS / TIME"
                  FontSize="{DynamicResource MeterTextSmall}"
                  FontWeight="Bold"
                  Foreground="#8DB3D1"/>
       <TextBlock x:Name="DpsText"
                  Text="0 / 0.0s"
                  FontSize="{DynamicResource MeterTextStat}"
                  FontWeight="Bold"
                  Foreground="{DynamicResource ThemeTextBrush}"/>
      </StackPanel>
     </Border>
    </Grid>
   </Grid>

   <TabControl
               Grid.Row="2"
               Margin="4,0,4,3"
               Background="{DynamicResource ThemeGridBrush}"
               BorderBrush="{DynamicResource ThemeBorderBrush}"
               Foreground="{DynamicResource ThemeTextBrush}">
    <TabItem Header="DAMAGE">
     <DataGrid x:Name="DamageGrid"
               Style="{StaticResource MeterGridStyle}"
               RowStyle="{StaticResource DamageRowStyle}"
               Margin="2">
      <DataGrid.Columns>
       <DataGridTemplateColumn Header="CHARACTER" Width="*" MinWidth="145">
        <DataGridTemplateColumn.CellTemplate>
         <DataTemplate>
          <Grid Margin="1,0"
                Height="19"
                ClipToBounds="True"
                ToolTip="{Binding ShareTooltip}">
           <Border Width="4"
                   HorizontalAlignment="Left"
                   Margin="0,2,0,2"
                   Background="{Binding BarBrush}"
                   CornerRadius="2"/>
           <TextBlock Text="{Binding Character}"
                      VerticalAlignment="Center"
                      Margin="9,0,4,0"
                      TextTrimming="CharacterEllipsis"
                      FontSize="{DynamicResource MeterTextNormal}"
                      FontFamily="Bahnschrift SemiBold, Segoe UI Semibold"
                      FontWeight="SemiBold"
                      Foreground="#FFFFFF"/>
          </Grid>
         </DataTemplate>
        </DataGridTemplateColumn.CellTemplate>
       </DataGridTemplateColumn>
       <DataGridTextColumn Header="DMG" Binding="{Binding Damage}" Width="70"/>
       <DataGridTextColumn Header="DPS" Binding="{Binding DPS}" Width="58"/>
       <DataGridTemplateColumn Header="D%" Width="94">
        <DataGridTemplateColumn.CellTemplate>
         <DataTemplate>
          <Grid Margin="3,2"
                ToolTip="{Binding ShareTooltip}">
           <ProgressBar Style="{StaticResource ShareBarStyle}"
                        Value="{Binding ShareNumber}"
                        Foreground="{Binding BarBrush}"/>
           <TextBlock Text="{Binding Share}"
                      Foreground="#FFFFFF"
                      FontWeight="SemiBold"
                      FontSize="{DynamicResource MeterTextSmall}"
                      HorizontalAlignment="Center"
                      VerticalAlignment="Center"
                      IsHitTestVisible="False"/>
          </Grid>
         </DataTemplate>
        </DataGridTemplateColumn.CellTemplate>
       </DataGridTemplateColumn>
       <DataGridTextColumn Header="HITS" Binding="{Binding Hits}" Width="42"/>
       <DataGridTextColumn Header="CRIT" Binding="{Binding CritRate}" Width="48"/>
       <DataGridTextColumn Header="MAX" Binding="{Binding Highest}" Width="64"/>
       <DataGridTextColumn Header="AVG" Binding="{Binding Average}" Width="64"/>
      </DataGrid.Columns>
     </DataGrid>
    </TabItem>

    <TabItem Header="LOGS">
     <Grid Margin="2">
      <Grid.RowDefinitions>
       <RowDefinition Height="92"/>
       <RowDefinition Height="4"/>
       <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <DataGrid x:Name="HistoryGrid"
                Grid.Row="0"
                Style="{StaticResource MeterGridStyle}"
                SelectionMode="Single"
                RowHeight="21"
                ColumnHeaderHeight="21">
       <DataGrid.Columns>
        <DataGridTextColumn Header="DATE" Binding="{Binding Date}" Width="124"/>
        <DataGridTextColumn Header="TARGET" Binding="{Binding Target}" Width="*" MinWidth="125"/>
        <DataGridTextColumn Header="TIME" Binding="{Binding Duration}" Width="58"/>
        <DataGridTextColumn Header="DMG" Binding="{Binding Damage}" Width="78"/>
        <DataGridTextColumn Header="DPS" Binding="{Binding DPS}" Width="68"/>
        <DataGridTextColumn Header="TYPE" Binding="{Binding Reason}" Width="82"/>
       </DataGrid.Columns>
      </DataGrid>

      <GridSplitter Grid.Row="1"
                    Height="4"
                    HorizontalAlignment="Stretch"
                    Background="#806C4A"/>

      <Grid Grid.Row="2">
       <Grid.RowDefinitions>
        <RowDefinition Height="48"/>
        <RowDefinition Height="18"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="18"/>
        <RowDefinition Height="56"/>
       </Grid.RowDefinitions>

       <Border Grid.Row="0"
               Background="{DynamicResource ThemeChromeBrush}"
               BorderBrush="{DynamicResource ThemeBorderBrush}"
               BorderThickness="0,0,0,1"
               Padding="7,4">
        <Grid>
         <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="92"/>
          <ColumnDefinition Width="80"/>
          <ColumnDefinition Width="70"/>
          <ColumnDefinition Width="70"/>
         </Grid.ColumnDefinitions>

         <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="LogTargetText"
                     Text="SELECT AN ENCOUNTER"
                     Foreground="{DynamicResource ThemeTextBrush}"
                     FontWeight="Bold"
                     FontSize="{DynamicResource MeterTextMedium}"
                     TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="LogMetaText"
                     Text="Saved encounters appear above"
                     Foreground="{DynamicResource ThemeMutedBrush}"
                     FontSize="{DynamicResource MeterTextSmall}"
                     Margin="0,2,0,0"
                     TextTrimming="CharacterEllipsis"/>
         </StackPanel>

         <StackPanel Grid.Column="1"
                     VerticalAlignment="Center"
                     Margin="6,0,0,0">
          <TextBlock Text="TOTAL DMG"
                     Foreground="{DynamicResource ThemeAccentBrush}"
                     FontSize="{DynamicResource MeterTextSmall}"
                     FontWeight="Bold"/>
          <TextBlock x:Name="LogTotalDamageText"
                     Text="0"
                     Foreground="#FFFFFF"
                     FontSize="{DynamicResource MeterTextStat}"
                     FontWeight="Bold"/>
         </StackPanel>

         <StackPanel Grid.Column="2"
                     VerticalAlignment="Center"
                     Margin="6,0,0,0">
          <TextBlock Text="DPS"
                     Foreground="#8DB3D1"
                     FontSize="{DynamicResource MeterTextSmall}"
                     FontWeight="Bold"/>
          <TextBlock x:Name="LogDpsText"
                     Text="0"
                     Foreground="#FFFFFF"
                     FontSize="{DynamicResource MeterTextStat}"
                     FontWeight="Bold"/>
         </StackPanel>

         <StackPanel Grid.Column="3"
                     VerticalAlignment="Center"
                     Margin="6,0,0,0">
          <TextBlock Text="TIME"
                     Foreground="{DynamicResource ThemeMutedBrush}"
                     FontSize="{DynamicResource MeterTextSmall}"
                     FontWeight="Bold"/>
          <TextBlock x:Name="LogDurationText"
                     Text="0.0s"
                     Foreground="#FFFFFF"
                     FontSize="{DynamicResource MeterTextStat}"
                     FontWeight="Bold"/>
         </StackPanel>

         <StackPanel Grid.Column="4"
                     VerticalAlignment="Center"
                     Margin="6,0,0,0">
          <TextBlock Text="CRIT"
                     Foreground="#E7A96A"
                     FontSize="{DynamicResource MeterTextSmall}"
                     FontWeight="Bold"/>
          <TextBlock x:Name="LogCritText"
                     Text="0.0%"
                     Foreground="#FFFFFF"
                     FontSize="{DynamicResource MeterTextStat}"
                     FontWeight="Bold"/>
         </StackPanel>
        </Grid>
       </Border>

       <Grid Grid.Row="1" Background="{DynamicResource ThemeHeaderBrush}">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="PARTY DAMAGE BREAKDOWN"
                   Foreground="{DynamicResource ThemeAccentTextBrush}"
                   FontWeight="Bold"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"
                   Margin="5,0"/>
        <TextBlock x:Name="LogPartySummaryText"
                   Grid.Column="1"
                   Text="0 MEMBERS / 0 HITS"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"
                   Margin="5,0"/>
       </Grid>

       <DataGrid x:Name="LogCharacterGrid"
                 Grid.Row="2"
                 Style="{StaticResource MeterGridStyle}"
                 RowStyle="{StaticResource DamageRowStyle}"
                 SelectionMode="Single">
        <DataGrid.Columns>
         <DataGridTextColumn Header="#" Binding="{Binding Rank}" Width="28"/>
         <DataGridTemplateColumn Header="CHARACTER" Width="*" MinWidth="130">
          <DataGridTemplateColumn.CellTemplate>
           <DataTemplate>
            <Grid Margin="1,0"
                  Height="19"
                  ClipToBounds="True"
                  ToolTip="{Binding ShareTooltip}">
             <Border Width="4"
                     HorizontalAlignment="Left"
                     Margin="0,2,0,2"
                     Background="{Binding BarBrush}"
                     CornerRadius="2"/>
             <TextBlock Text="{Binding Character}"
                        VerticalAlignment="Center"
                        Margin="9,0,4,0"
                        TextTrimming="CharacterEllipsis"
                        FontSize="{DynamicResource MeterTextNormal}"
                        FontFamily="Bahnschrift SemiBold, Segoe UI Semibold"
                        FontWeight="SemiBold"
                        Foreground="#FFFFFF"/>
            </Grid>
           </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
         </DataGridTemplateColumn>
         <DataGridTextColumn Header="DMG" Binding="{Binding Damage}" Width="72"/>
         <DataGridTextColumn Header="DPS" Binding="{Binding DPS}" Width="62"/>
         <DataGridTemplateColumn Header="D%" Width="94">
          <DataGridTemplateColumn.CellTemplate>
           <DataTemplate>
            <Grid Margin="3,2"
                  ToolTip="{Binding ShareTooltip}">
             <ProgressBar Style="{StaticResource ShareBarStyle}"
                          Value="{Binding ShareNumber}"
                          Foreground="{Binding BarBrush}"/>
             <TextBlock Text="{Binding Share}"
                        Foreground="#FFFFFF"
                        FontWeight="SemiBold"
                        FontSize="{DynamicResource MeterTextSmall}"
                        HorizontalAlignment="Center"
                        VerticalAlignment="Center"
                        IsHitTestVisible="False"/>
            </Grid>
           </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
         </DataGridTemplateColumn>
         <DataGridTextColumn Header="CRIT" Binding="{Binding CritRate}" Width="50"/>
         <DataGridTextColumn Header="HITS" Binding="{Binding Hits}" Width="44"/>
         <DataGridTextColumn Header="MAX" Binding="{Binding Highest}" Width="66"/>
         <DataGridTextColumn Header="AVG" Binding="{Binding Average}" Width="66"/>
        </DataGrid.Columns>
       </DataGrid>

       <TextBlock x:Name="HistoryTimelineLabel"
                  Grid.Row="3"
                  Text="Select an encounter to view its timeline"
                  Foreground="{DynamicResource ThemeMutedBrush}"
                  FontSize="{DynamicResource MeterTextSmall}"
                  VerticalAlignment="Center"
                  TextTrimming="CharacterEllipsis"
                  Margin="4,0"/>

       <ScrollViewer x:Name="HistoryTimelineScroll"
                     Grid.Row="4"
                     HorizontalScrollBarVisibility="Auto"
                     VerticalScrollBarVisibility="Disabled"
                     CanContentScroll="False"
                     Background="#111B27">
        <Canvas x:Name="HistoryTimelineCanvas"
                Height="56"
                MinWidth="580"
                Background="#111B27"
                ClipToBounds="True"/>
       </ScrollViewer>
      </Grid>
     </Grid>
    </TabItem>
   </TabControl>

   <Grid Grid.Row="3" Background="{DynamicResource ThemeChromeBrush}">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="Auto"/>
     <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Button x:Name="ResetButton"
            Content="RESET F6"
            Width="68"
            Height="21"
            Margin="4,3,0,3"/>
    <TextBlock x:Name="HotkeyFooterText"
               Grid.Column="1"
               Text="RESET SAVES LOG  •  F9 SHOW/HIDE  •  F10 PASS"
               Foreground="{DynamicResource ThemeMutedBrush}"
               FontSize="{DynamicResource MeterTextSmall}"
               VerticalAlignment="Center"
               HorizontalAlignment="Center"/>
   </Grid>

   <Grid
         Grid.RowSpan="4"
         Panel.ZIndex="9000"
         IsHitTestVisible="True">
    <Grid.RowDefinitions>
     <RowDefinition Height="4"/>
     <RowDefinition Height="*"/>
     <RowDefinition Height="4"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="4"/>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="4"/>
    </Grid.ColumnDefinitions>
    <Border x:Name="ResizeTopLeft" Grid.Row="0" Grid.Column="0" Background="#01000000" Cursor="SizeNWSE"/>
    <Border x:Name="ResizeTop" Grid.Row="0" Grid.Column="1" Background="#01000000" Cursor="SizeNS"/>
    <Border x:Name="ResizeTopRight" Grid.Row="0" Grid.Column="2" Background="#01000000" Cursor="SizeNESW"/>
    <Border x:Name="ResizeLeft" Grid.Row="1" Grid.Column="0" Background="#01000000" Cursor="SizeWE"/>
    <Border x:Name="ResizeRight" Grid.Row="1" Grid.Column="2" Background="#01000000" Cursor="SizeWE"/>
    <Border x:Name="ResizeBottomLeft" Grid.Row="2" Grid.Column="0" Background="#01000000" Cursor="SizeNESW"/>
    <Border x:Name="ResizeBottom" Grid.Row="2" Grid.Column="1" Background="#01000000" Cursor="SizeNS"/>
    <Border x:Name="ResizeBottomRight" Grid.Row="2" Grid.Column="2" Background="#01000000" Cursor="SizeNWSE"/>
   </Grid>

   <Border x:Name="SettingsPanel"
           Grid.RowSpan="4"
           Panel.ZIndex="10000"
           Width="365"
           MaxHeight="368"
           HorizontalAlignment="Right"
           VerticalAlignment="Top"
           Margin="0,35,6,0"
           Padding="0"
           Background="{DynamicResource ThemePanelBrush}"
           BorderBrush="{DynamicResource ThemeAccentBrush}"
           BorderThickness="1"
           CornerRadius="7"
           Visibility="Collapsed">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="32"/>
      <RowDefinition Height="*"/>
     </Grid.RowDefinitions>
     <Grid Grid.Row="0"
           Background="{DynamicResource ThemeChromeBrush}"
           Margin="1">
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="*"/>
       <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="TARTEMETER SETTINGS"
                 FontWeight="Bold"
                 Foreground="{DynamicResource ThemeAccentTextBrush}"
                 FontSize="{DynamicResource MeterTextNormal}"
                 VerticalAlignment="Center"
                 Margin="10,0,0,0"/>
      <Button x:Name="SettingsCloseButton"
              Grid.Column="1"
              Width="30"
              Height="26"
              Padding="0"
              Background="Transparent"
              BorderThickness="0">
       <Viewbox Width="11" Height="11">
        <Path Stroke="#E07A72"
              StrokeThickness="1.8"
              StrokeStartLineCap="Round"
              StrokeEndLineCap="Round"
              Data="M1,1 L9,9 M9,1 L1,9"/>
       </Viewbox>
      </Button>
     </Grid>
     <ScrollViewer Grid.Row="1"
                   VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Disabled"
                   Padding="11,8,11,10">
      <StackPanel>
       <Grid Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="COLOR THEME"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <ComboBox x:Name="ThemeCombo"
                  Grid.Column="1"
                  Height="24"
                  IsReadOnly="True"
                  ToolTip="Choose one of three dark color designs"/>
       </Grid>

       <Grid Margin="0,0,0,7">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="44"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="OPACITY"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <Slider x:Name="OpacitySlider"
                Grid.Column="1"
                Minimum="55"
                Maximum="100"
                Value="92"
                TickFrequency="5"
                Height="20"/>
        <TextBlock x:Name="OpacityText"
                   Grid.Column="2"
                   Text="92%"
                   Foreground="{DynamicResource ThemeTextBrush}"
                   FontSize="{DynamicResource MeterTextNormal}"
                   VerticalAlignment="Center"
                   TextAlignment="Right"/>
       </Grid>

       <Grid Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="44"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="TEXT SIZE"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <Slider x:Name="TextScaleSlider"
                Grid.Column="1"
                Minimum="80"
                Maximum="140"
                Value="100"
                TickFrequency="10"
                Height="20"/>
        <TextBlock x:Name="TextScaleText"
                   Grid.Column="2"
                   Text="100%"
                   Foreground="{DynamicResource ThemeTextBrush}"
                   FontSize="{DynamicResource MeterTextNormal}"
                   VerticalAlignment="Center"
                   TextAlignment="Right"/>
       </Grid>

       <StackPanel Orientation="Horizontal" Margin="0,0,0,9">
        <CheckBox x:Name="TopmostCheck"
                  Content="ALWAYS ON TOP"
                  IsChecked="True"
                  Margin="0,0,18,0"/>
        <CheckBox x:Name="ClickThroughCheck"
                  Content="CLICK THROUGH"/>
       </StackPanel>

       <Border Height="1"
               Background="{DynamicResource ThemeBorderBrush}"
               Margin="0,1,0,8"/>
       <TextBlock Text="KEY BINDINGS"
                  Foreground="{DynamicResource ThemeAccentTextBrush}"
                  FontWeight="Bold"
                  FontSize="{DynamicResource MeterTextSmall}"
                  Margin="0,0,0,6"/>

       <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="RESET + SAVE"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <ComboBox x:Name="ResetHotkeyCombo"
                  Grid.Column="1"
                  Height="23"
                  IsEditable="False"
                  IsTextSearchEnabled="True"/>
       </Grid>

       <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="SHOW / HIDE"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <ComboBox x:Name="OverlayHotkeyCombo"
                  Grid.Column="1"
                  Height="23"
                  IsEditable="False"
                  IsTextSearchEnabled="True"/>
       </Grid>

       <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
         <ColumnDefinition Width="90"/>
         <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="CLICK THROUGH"
                   Foreground="{DynamicResource ThemeMutedBrush}"
                   FontSize="{DynamicResource MeterTextSmall}"
                   VerticalAlignment="Center"/>
        <ComboBox x:Name="PassHotkeyCombo"
                  Grid.Column="1"
                  Height="23"
                  IsEditable="False"
                  IsTextSearchEnabled="True"/>
       </Grid>

       <TextBlock x:Name="HotkeyStatusText"
                  Text="Changes apply immediately. Use F1-F12 or combinations such as Ctrl+F8."
                  TextWrapping="Wrap"
                  Foreground="{DynamicResource ThemeMutedBrush}"
                  FontSize="{DynamicResource MeterTextSmall}"
                  Margin="0,2,0,7"/>

       <Button x:Name="ExitButton"
               Content="EXIT TARTEMETER PROCESS"
               Height="24"
               HorizontalAlignment="Stretch"
               ToolTip="Completely close the overlay process. Start the game or mod again to reopen it."/>
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
$SettingsButton = $window.FindName("SettingsButton")
$SettingsCloseButton = $window.FindName("SettingsCloseButton")
$SettingsPanel = $window.FindName("SettingsPanel")
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
$ResetHotkeyCombo = $window.FindName("ResetHotkeyCombo")
$OverlayHotkeyCombo = $window.FindName("OverlayHotkeyCombo")
$PassHotkeyCombo = $window.FindName("PassHotkeyCombo")
$HotkeyStatusText = $window.FindName("HotkeyStatusText")
$HotkeyFooterText = $window.FindName("HotkeyFooterText")
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
    Write-WindowSettings
})

$timelineResizeTimer = New-Object Windows.Threading.DispatcherTimer
$timelineResizeTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$timelineResizeTimer.Add_Tick({
    $timelineResizeTimer.Stop()
    if ($null -ne $script:selectedBattle) {
        Draw-LogsTimeline $script:selectedBattle
    }
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
        $resource = $window.Resources[$resourceKey]

        if ($null -eq $resource) {
            throw "Missing theme resource: $resourceKey"
        }
        if (-not ($resource -is [Windows.Media.SolidColorBrush])) {
            throw "Theme resource is not a SolidColorBrush: $resourceKey"
        }
        if ($resource.IsFrozen) {
            throw "Theme resource is unexpectedly frozen: $resourceKey"
        }

        $resource.Color = Convert-ToWpfColor -Hex ([string]$entry.Value)
    }

    $script:settings.Theme = $name
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
    $ResetButton.Content = "RESET {0}" -f $script:settings.ResetHotkey
    $HotkeyFooterText.Text = (
        "RESET SAVES LOG  •  {0} SHOW/HIDE  •  {1} PASS" -f
        $script:settings.OverlayHotkey,
        $script:settings.PassHotkey
    )
}

function Sync-HotkeyControls {
    $script:syncingHotkeyControls = $true
    try {
        $ResetHotkeyCombo.Text = [string]$script:settings.ResetHotkey
        $OverlayHotkeyCombo.Text = [string]$script:settings.OverlayHotkey
        $PassHotkeyCombo.Text = [string]$script:settings.PassHotkey
    }
    finally {
        $script:syncingHotkeyControls = $false
    }
}

function Register-MeterHotkeys {
    param([bool]$ShowStatus = $true)

    if ($script:windowHandle -eq [IntPtr]::Zero) { return $false }

    try {
        $reset = Convert-HotkeyDefinition ([string]$ResetHotkeyCombo.Text)
        $overlay = Convert-HotkeyDefinition ([string]$OverlayHotkeyCombo.Text)
        $pass = Convert-HotkeyDefinition ([string]$PassHotkeyCombo.Text)

        $signatures = @($reset.Signature, $overlay.Signature, $pass.Signature)
        if (@($signatures | Select-Object -Unique).Count -ne 3) {
            throw "Each action must use a different hotkey."
        }

        Unregister-MeterHotkeys
        $items = @(
            [pscustomobject]@{ Id = $script:resetHotkeyId; Definition = $reset },
            [pscustomobject]@{ Id = $script:overlayHotkeyId; Definition = $overlay },
            [pscustomobject]@{ Id = $script:passHotkeyId; Definition = $pass }
        )

        foreach ($item in $items) {
            $id = [int]$item.Id
            $definition = $item.Definition
            $ok = [TarteNative]::RegisterHotKey(
                $script:windowHandle,
                $id,
                [uint32]$definition.Modifiers,
                [uint32]$definition.VirtualKey
            )
            if (-not $ok) {
                throw "Windows could not register $($definition.Text). It may already be used by another application."
            }
        }

        $script:hotkeysRegistered = $true
        $script:settings.ResetHotkey = $reset.Text
        $script:settings.OverlayHotkey = $overlay.Text
        $script:settings.PassHotkey = $pass.Text
        Sync-HotkeyControls
        Update-HotkeyLabels
        if ($ShowStatus) {
            $HotkeyStatusText.Foreground = $window.Resources["ThemeMutedBrush"]
            $HotkeyStatusText.Text = "Hotkeys updated and active immediately."
        }
        Queue-SettingsSave
        return $true
    }
    catch {
        Unregister-MeterHotkeys
        Sync-HotkeyControls
        if ($ShowStatus) {
            $HotkeyStatusText.Foreground = New-Brush "#F08A82"
            $HotkeyStatusText.Text = $_.Exception.Message
        }

        # Restore the last valid bindings.
        try {
            $reset = Convert-HotkeyDefinition ([string]$script:settings.ResetHotkey)
            $overlay = Convert-HotkeyDefinition ([string]$script:settings.OverlayHotkey)
            $pass = Convert-HotkeyDefinition ([string]$script:settings.PassHotkey)
            [void][TarteNative]::RegisterHotKey($script:windowHandle, $script:resetHotkeyId, [uint32]$reset.Modifiers, [uint32]$reset.VirtualKey)
            [void][TarteNative]::RegisterHotKey($script:windowHandle, $script:overlayHotkeyId, [uint32]$overlay.Modifiers, [uint32]$overlay.VirtualKey)
            [void][TarteNative]::RegisterHotKey($script:windowHandle, $script:passHotkeyId, [uint32]$pass.Modifiers, [uint32]$pass.VirtualKey)
            $script:hotkeysRegistered = $true
        }
        catch {}
        return $false
    }
}

function Toggle-OverlayVisibility {
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
        $window.Show()
        [void]$window.Activate()
        return
    }

    if ($window.Visibility -eq [Windows.Visibility]::Visible) {
        $window.Hide()
        return
    }

    $window.Show()
    [void]$window.Activate()
}

function Process-OverlayShowRequest {
    if (-not (Test-Path -LiteralPath $showRequestPath -PathType Leaf)) {
        return
    }

    try {
        Remove-Item -LiteralPath $showRequestPath -Force -ErrorAction SilentlyContinue
        if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
            $window.WindowState = [Windows.WindowState]::Normal
        }
        $window.Show()
        $window.ShowInTaskbar = $true
        [void]$window.Activate()
        [IO.File]::WriteAllText(
            $readyPath,
            ("TarteMeter v2.5.2 ready | " + [DateTime]::Now.ToString("o")),
            [Text.Encoding]::UTF8
        )
        Write-StartupDiagnostic "Existing window shown by request"
    }
    catch {
        Write-WindowError $_
    }
}

function Set-TextScale {
    param([double]$Percent)

    $Percent = [Math]::Max(80.0, [Math]::Min(140.0, $Percent))
    $scale = $Percent / 100.0
    $script:settings.TextScale = $Percent

    $window.Resources["MeterTextSmall"] = [double](8.0 * $scale)
    $window.Resources["MeterTextNormal"] = [double](9.0 * $scale)
    $window.Resources["MeterTextMedium"] = [double](11.0 * $scale)
    $window.Resources["MeterTextTitle"] = [double](12.0 * $scale)
    $window.Resources["MeterTextStat"] = [double](13.0 * $scale)

    $rowHeight = [Math]::Max(23.0, 23.0 * $scale)
    $headerHeight = [Math]::Max(23.0, 23.0 * $scale)
    foreach ($grid in @($DamageGrid, $HistoryGrid, $LogCharacterGrid)) {
        $grid.RowHeight = $rowHeight
        $grid.ColumnHeaderHeight = $headerHeight
    }

    $TextScaleText.Text = "{0:0}%" -f $Percent
}

function Toggle-SettingsPanel {
    if ($SettingsPanel.Visibility -eq [Windows.Visibility]::Visible) {
        $SettingsPanel.Visibility = [Windows.Visibility]::Collapsed
    }
    else {
        $SettingsPanel.Visibility = [Windows.Visibility]::Visible
    }
}

function Toggle-MaximizeRestore {
    if ($window.WindowState -eq [Windows.WindowState]::Maximized) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
    else {
        $window.WindowState = [Windows.WindowState]::Maximized
    }
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
                    "{0}  •  {1:0.00}% of total damage" -f
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

        $StatusText.Text = "$status  •  ACTIVE  $active"
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

function Read-BattleHistory {
    if (-not (Test-Path -LiteralPath $historyPath)) {
        $HistoryGrid.ItemsSource = $null
        return
    }

    try {
        # Parse only the small summary prefix for the list. Full event arrays are
        # converted from JSON only when the user selects one encounter.
        $lines = @(
            Get-Content `
                -LiteralPath $historyPath `
                -Tail $script:maxHistoryRows `
                -Encoding UTF8 `
                -ErrorAction Stop
        )
        $rows = New-Object 'System.Collections.Generic.List[object]'

        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $timestamp = Get-JsonStringField $line "timestamp"
            $date = $timestamp
            try {
                $date = ([datetime]$timestamp).ToLocalTime().ToString(
                    "yyyy-MM-dd HH:mm"
                )
            }
            catch {}

            $duration = Get-JsonNumberField $line "duration"
            $damage = Get-JsonNumberField $line "total_damage"
            $dps = Get-JsonNumberField $line "dps"

            $rows.Add([pscustomobject]@{
                Date = $date
                Target = Get-JsonStringField $line "target"
                Duration = "{0:0.0}s" -f $duration
                Damage = "{0:N0}" -f $damage
                DPS = "{0:N0}" -f $dps
                Reason = Get-JsonStringField $line "reason"
                RawJson = $line
            })
        }

        $HistoryGrid.ItemsSource = $rows
        if ($rows.Count -gt 0 -and $HistoryGrid.SelectedIndex -lt 0) {
            $HistoryGrid.SelectedIndex = 0
        }
    }
    catch {
        Write-WindowError $_
    }
}

function Update-HistoryIfChanged {
    param([bool]$Force = $false)

    try {
        if (-not (Test-Path -LiteralPath $historyPath)) { return }
        $item = Get-Item -LiteralPath $historyPath
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

    $timestamp = Get-JsonStringField $clean "timestamp"
    $reason = Get-JsonStringField $clean "reason"
    $target = Get-JsonStringField $clean "target"
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

    return [pscustomobject]@{
        timestamp = $timestamp
        reason = $reason
        target = $target
        duration = $duration
        total_damage = $totalDamage
        dps = $battleDps
        events_truncated = $eventsTruncated
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

    $viewportWidth = [Math]::Max(
        580.0,
        $HistoryTimelineScroll.ViewportWidth
    )
    $height = 56.0

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

    $durationOverflow = [Math]::Max(0.0, $maxTime - 45.0)
    $densityOverflow = [Math]::Max(0.0, $events.Count - 220)
    $timelineWidth = [Math]::Max(
        $viewportWidth,
        580.0 + ($durationOverflow * 8.0) + ($densityOverflow * 1.5)
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
    $detailNote = if ([bool]$Battle.events_truncated) {
        " | detailed events capped"
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
    $selected = $HistoryGrid.SelectedItem
    if ($null -eq $selected) { return }

    $battle = $null
    try {
        $battle = Convert-BattleRecord ([string]$selected.RawJson)
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

Write-StartupDiagnostic "Controls resolved"

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

$hotkeyOptions = Get-HotkeyOptions
foreach ($combo in @($ResetHotkeyCombo, $OverlayHotkeyCombo, $PassHotkeyCombo)) {
    foreach ($option in $hotkeyOptions) {
        [void]$combo.Items.Add($option)
    }
}
Sync-HotkeyControls
Update-HotkeyLabels
Write-StartupDiagnostic "Theme and hotkey controls initialized"

$OpacitySlider.Value = $script:settings.Opacity
$OpacityText.Text = "{0:0}%" -f $script:settings.Opacity
$window.Opacity = [Math]::Max(
    0.55,
    [Math]::Min(1.0, $script:settings.Opacity / 100.0)
)
$TextScaleSlider.Value = $script:settings.TextScale
Set-TextScale $script:settings.TextScale
$window.Topmost = [bool]$script:settings.Topmost
$script:syncingTopmostCheck = $true
$TopmostCheck.IsChecked = [bool]$script:settings.Topmost
$script:syncingTopmostCheck = $false
$script:clickThroughEnabled = [bool]$script:settings.ClickThrough
$script:syncingClickThroughCheck = $true
$ClickThroughCheck.IsChecked = [bool]$script:settings.ClickThrough
$script:syncingClickThroughCheck = $false

$ResetButton.Add_Click({ Write-MeterCommand "RESET" })
$SettingsButton.Add_Click({ Toggle-SettingsPanel })
$SettingsCloseButton.Add_Click({
    $SettingsPanel.Visibility = [Windows.Visibility]::Collapsed
})
$ExitButton.Add_Click({
    $script:forceClose = $true
    $window.Close()
})
$ThemeCombo.Add_SelectionChanged({
    if ($null -eq $ThemeCombo.SelectedItem) { return }
    if ($script:loadingSettings) { return }

    $previousTheme = [string]$script:settings.Theme
    try {
        Apply-Theme ([string]$ThemeCombo.SelectedItem)
        Queue-SettingsSave
    }
    catch {
        Write-WindowError $_
        $script:loadingSettings = $true
        try {
            $ThemeCombo.SelectedItem = $previousTheme
        }
        finally {
            $script:loadingSettings = $false
        }
    }
})

$applyHotkeyChange = {
    if ($script:syncingHotkeyControls) { return }
    if ($script:windowHandle -eq [IntPtr]::Zero) { return }
    [void](Register-MeterHotkeys $true)
}
foreach ($combo in @($ResetHotkeyCombo, $OverlayHotkeyCombo, $PassHotkeyCombo)) {
    $combo.Add_SelectionChanged($applyHotkeyChange)
    $combo.Add_DropDownClosed($applyHotkeyChange)
    $combo.Add_LostKeyboardFocus($applyHotkeyChange)
}
$MinimizeButton.Add_Click({
    $window.WindowState = [Windows.WindowState]::Minimized
})
$MaximizeButton.Add_Click({ Toggle-MaximizeRestore })
$CloseButton.Add_Click({ $window.Hide() })

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
$HistoryTimelineScroll.Add_SizeChanged({
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
                Write-MeterCommand "RESET"
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
    Process-OverlayShowRequest
    Update-MeterIfChanged
    Update-HistoryIfChanged
})

$window.Add_Loaded({
    Write-StartupDiagnostic "Window Loaded event"

    try {
        $window.ShowInTaskbar = $true
        if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
            $window.WindowState = [Windows.WindowState]::Normal
        }
        $window.Visibility = [Windows.Visibility]::Visible
        $window.Show()
        [void]$window.Activate()
    }
    catch {
        Write-StartupDiagnostic "Visibility recovery warning" $_.Exception.Message
    }

    try {
        [IO.File]::WriteAllText(
            $readyPath,
            ("TarteMeter v2.5.2 ready | " + [DateTime]::Now.ToString("o")),
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
    try { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue } catch {}
    Write-WindowSettings

    Unregister-MeterHotkeys

    if ($null -ne $instanceMutex) {
        try { $instanceMutex.ReleaseMutex() } catch {}
        $instanceMutex.Dispose()
        $instanceMutex = $null
    }
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
