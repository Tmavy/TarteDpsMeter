$ErrorActionPreference = "Stop"

$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex(
    $true,
    "Local\TarteMeterOverlay",
    [ref]$createdNew
)
if (-not $createdNew) {
    $instanceMutex.Dispose()
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$statePath = Join-Path $PSScriptRoot "dps_state.txt"
$commandPath = Join-Path $PSScriptRoot "dps_command.txt"
$historyPath = Join-Path $PSScriptRoot "battle_history.jsonl"
$errorPath = Join-Path $PSScriptRoot "window_error.txt"
$iconPath = Join-Path $PSScriptRoot "Assets\TarteMeter.ico"
$portraitPath = Join-Path $PSScriptRoot "Assets\tarte.png"
$bannerPath = Join-Path $PSScriptRoot "Assets\banner.png"
$settingsPath = Join-Path $PSScriptRoot "window_settings_v4.ini"
$legacySettingsPath = Join-Path $PSScriptRoot "window_settings_v3.ini"

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
    public const uint MOD_NOREPEAT = 0x4000;
    public const uint VK_F10 = 0x79;

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
$script:clickHotkeyId = 0x544A
$script:maxHistoryRows = 200
$script:maxTimelineMarkers = 500
$script:maxEventRows = 2500
$script:settings = [ordered]@{
    Opacity = 92.0
    TextScale = 100.0
    Topmost = $true
    ClickThrough = $false
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

function New-Brush {
    param([string]$Hex)

    if ($script:brushCache.ContainsKey($Hex)) {
        return $script:brushCache[$Hex]
    }

    $color = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $brush = New-Object Windows.Media.SolidColorBrush($color)
    $brush.Freeze()
    $script:brushCache[$Hex] = $brush
    return $brush
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

function Read-WindowSettings {
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            foreach ($line in [IO.File]::ReadAllLines($settingsPath)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line -split "=", 2
                if ($parts.Count -ne 2) { continue }

                switch ($parts[0].Trim()) {
                    "Opacity" {
                        $value = Convert-ToNumber $parts[1]
                        if ($value -ge 55 -and $value -le 100) {
                            $script:settings.Opacity = $value
                        }
                    }
                    "TextScale" {
                        $value = Convert-ToNumber $parts[1]
                        if ($value -ge 80 -and $value -le 140) {
                            $script:settings.TextScale = $value
                        }
                    }
                    "Topmost" {
                        $script:settings.Topmost = Convert-ToBoolean `
                            -Value $parts[1] `
                            -Fallback $script:settings.Topmost
                    }
                    "ClickThrough" {
                        $script:settings.ClickThrough = Convert-ToBoolean `
                            -Value $parts[1] `
                            -Fallback $script:settings.ClickThrough
                    }
                }
            }
            return
        }

        # One-time migration from the older opacity-only settings file.
        if (Test-Path -LiteralPath $legacySettingsPath) {
            $legacyValue = Convert-ToNumber(
                [IO.File]::ReadAllText($legacySettingsPath).Trim()
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
            "ClickThrough={0}" -f $script:settings.ClickThrough
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
        Title="TarteMeter v2.2.0"
        Width="640"
        Height="360"
        MinWidth="500"
        MinHeight="280"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="CanResize"
        Topmost="True"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        FontFamily="Bahnschrift, Segoe UI Variable, Segoe UI"
        Foreground="#E9EEF5">
 <Window.Resources>
  <sys:Double x:Key="MeterTextSmall">8</sys:Double>
  <sys:Double x:Key="MeterTextNormal">9</sys:Double>
  <sys:Double x:Key="MeterTextMedium">11</sys:Double>
  <sys:Double x:Key="MeterTextTitle">12</sys:Double>
  <sys:Double x:Key="MeterTextStat">13</sys:Double>
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
   <Setter Property="BorderBrush" Value="#253547"/>
   <Setter Property="BorderThickness" Value="0,0,1,0"/>
   <Setter Property="Padding" Value="4,0"/>
   <Setter Property="FontSize" Value="{DynamicResource MeterTextNormal}"/>
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
   <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
   <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
   <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
   <Setter Property="EnableRowVirtualization" Value="True"/>
   <Setter Property="EnableColumnVirtualization" Value="True"/>
  </Style>
 </Window.Resources>
 <Border CornerRadius="8"
         BorderThickness="1"
         BorderBrush="#CFA95C"
         Background="#101722"
         ClipToBounds="True">
  <Grid>
   <Grid.RowDefinitions>
    <RowDefinition Height="30"/>
    <RowDefinition Height="48"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="27"/>
   </Grid.RowDefinitions>

   <Grid x:Name="TitleBar" Grid.Row="0" Background="#151F2D">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="31"/>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Border Width="22" Height="22" CornerRadius="11" Margin="4">
     <Image x:Name="PortraitImage" Stretch="UniformToFill"/>
    </Border>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
     <TextBlock Text="TARTE"
                FontSize="{DynamicResource MeterTextTitle}"
                FontWeight="Bold"
                Foreground="#E3B45C"/>
     <TextBlock Text="METER"
                FontSize="{DynamicResource MeterTextTitle}"
                FontWeight="SemiBold"
                Margin="4,0,0,0"
                Foreground="#E9EEF5"/>
     <Border Background="#2B3A4D"
             CornerRadius="6"
             Padding="5,1"
             Margin="6,0,0,0">
      <TextBlock Text="v2.2.0"
                 FontSize="{DynamicResource MeterTextSmall}"
                 Foreground="#E8C984"/>
     </Border>
     <TextBlock Text="COMBAT ANALYZER"
                FontSize="{DynamicResource MeterTextSmall}"
                Foreground="#8193A7"
                Margin="7,1,0,0"
                VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal">
     <Button x:Name="SettingsButton"
             Content="⚙"
             ToolTip="Window settings"
             Width="29"
             FontFamily="Segoe UI Symbol"
             FontSize="{DynamicResource MeterTextMedium}"
             Background="Transparent"
             BorderThickness="0"
             Padding="0"/>
     <Button x:Name="MinimizeButton"
             Content="—"
             ToolTip="Minimize"
             Width="27"
             Background="Transparent"
             BorderThickness="0"
             Padding="0"/>
     <Button x:Name="MaximizeButton"
             Content="□"
             ToolTip="Maximize / Restore"
             Width="27"
             FontSize="{DynamicResource MeterTextStat}"
             Background="Transparent"
             BorderThickness="0"
             Padding="0"/>
     <Button x:Name="CloseButton"
             Content="×"
             ToolTip="Close"
             Width="27"
             FontSize="17"
             Background="Transparent"
             BorderThickness="0"
             Foreground="#E07A72"
             Padding="0"/>
    </StackPanel>
   </Grid>

   <Grid Grid.Row="1" Margin="4,3,4,3">
    <Image x:Name="BannerImage" Stretch="UniformToFill" Opacity="0.15"/>
    <Border Background="#C0141E2B"
            CornerRadius="7"
            BorderBrush="#3A4B60"
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
                 Foreground="#F2F5F8"
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
                  Foreground="#D5B06A"/>
       <TextBlock x:Name="TotalText"
                  Text="0"
                  FontSize="{DynamicResource MeterTextStat}"
                  FontWeight="Bold"
                  Foreground="#F2F5F8"/>
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
                  Foreground="#F2F5F8"/>
      </StackPanel>
     </Border>
    </Grid>
   </Grid>

   <TabControl
               Grid.Row="2"
               Margin="4,0,4,3"
               Background="#0F1722"
               BorderBrush="#33465A"
               Foreground="#E9EEF5">
    <TabItem Header="DAMAGE">
     <DataGrid x:Name="DamageGrid"
               Style="{StaticResource MeterGridStyle}"
               Margin="2">
      <DataGrid.Columns>
       <DataGridTemplateColumn Header="CHARACTER" Width="*" MinWidth="145">
        <DataGridTemplateColumn.CellTemplate>
         <DataTemplate>
          <Grid Margin="1,1"
                Height="19"
                ClipToBounds="True"
                ToolTip="Live DPS relative to the current leader">
           <Border Background="#33465C" CornerRadius="3"/>
           <Border Width="{Binding BarWidth}"
                   HorizontalAlignment="Left"
                   Background="{Binding BarBrush}"
                   CornerRadius="3"/>
           <TextBlock Text="{Binding Character}"
                      VerticalAlignment="Center"
                      Margin="6,0"
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
       <DataGridTextColumn Header="%" Binding="{Binding Share}" Width="43"/>
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
       <RowDefinition Height="*"/>
       <RowDefinition Height="4"/>
       <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <DataGrid x:Name="HistoryGrid"
                Grid.Row="0"
                Style="{StaticResource MeterGridStyle}"
                SelectionMode="Single">
       <DataGrid.Columns>
        <DataGridTextColumn Header="DATE" Binding="{Binding Date}" Width="125"/>
        <DataGridTextColumn Header="TARGET" Binding="{Binding Target}" Width="*" MinWidth="110"/>
        <DataGridTextColumn Header="TIME" Binding="{Binding Duration}" Width="58"/>
        <DataGridTextColumn Header="DMG" Binding="{Binding Damage}" Width="76"/>
        <DataGridTextColumn Header="DPS" Binding="{Binding DPS}" Width="65"/>
        <DataGridTextColumn Header="TYPE" Binding="{Binding Reason}" Width="100"/>
       </DataGrid.Columns>
      </DataGrid>
      <GridSplitter Grid.Row="1"
                    Height="4"
                    HorizontalAlignment="Stretch"
                    Background="#806C4A"/>
      <Grid Grid.Row="2">
       <Grid.RowDefinitions>
        <RowDefinition Height="19"/>
        <RowDefinition Height="54"/>
        <RowDefinition Height="*"/>
       </Grid.RowDefinitions>
       <TextBlock x:Name="HistoryTimelineLabel"
                  Grid.Row="0"
                  Text="Select an encounter"
                  Foreground="#A7B5C5"
                  FontSize="{DynamicResource MeterTextNormal}"
                  VerticalAlignment="Center"
                  TextTrimming="CharacterEllipsis"/>
       <ScrollViewer x:Name="HistoryTimelineScroll"
                     Grid.Row="1"
                     HorizontalScrollBarVisibility="Auto"
                     VerticalScrollBarVisibility="Disabled"
                     CanContentScroll="False"
                     Background="#111B27">
        <Canvas x:Name="HistoryTimelineCanvas"
                Height="54"
                MinWidth="580"
                Background="#111B27"
                ClipToBounds="True"/>
       </ScrollViewer>
       <DataGrid x:Name="EventGrid"
                 Grid.Row="2"
                 Style="{StaticResource MeterGridStyle}"
                 Margin="0,2,0,0">
        <DataGrid.Columns>
         <DataGridTextColumn Header="TIME" Binding="{Binding Time}" Width="58"/>
         <DataGridTextColumn Header="CHARACTER" Binding="{Binding Character}" Width="*" MinWidth="110"/>
         <DataGridTextColumn Header="DMG" Binding="{Binding Damage}" Width="76"/>
         <DataGridTextColumn Header="CRIT" Binding="{Binding Critical}" Width="48"/>
        </DataGrid.Columns>
       </DataGrid>
      </Grid>
     </Grid>
    </TabItem>
   </TabControl>

   <Grid Grid.Row="3" Background="#151F2D">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="Auto"/>
     <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Button x:Name="ResetButton"
            Content="RESET F6"
            Width="68"
            Height="21"
            Margin="4,3,0,3"/>
    <TextBlock Grid.Column="1"
               Text="RESET SAVES LOG  •  F9 OPEN  •  F10 PASS"
               Foreground="#718397"
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
           Width="276"
           HorizontalAlignment="Right"
           VerticalAlignment="Top"
           Margin="0,31,5,0"
           Padding="10"
           Background="#F2172332"
           BorderBrush="#CFA95C"
           BorderThickness="1"
           CornerRadius="7"
           Visibility="Collapsed">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <Grid Grid.Row="0" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="*"/>
       <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="WINDOW SETTINGS"
                 FontWeight="Bold"
                 Foreground="#E8C984"
                 FontSize="{DynamicResource MeterTextNormal}"
                 VerticalAlignment="Center"/>
      <Button x:Name="SettingsCloseButton"
              Grid.Column="1"
              Content="×"
              Width="24"
              Height="20"
              Padding="0"
              Background="Transparent"
              BorderThickness="0"
              Foreground="#E07A72"/>
     </Grid>
     <Grid Grid.Row="1" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="76"/>
       <ColumnDefinition Width="*"/>
       <ColumnDefinition Width="42"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="OPACITY"
                 FontSize="{DynamicResource MeterTextSmall}"
                 Foreground="#9EADBD"
                 VerticalAlignment="Center"/>
      <Slider x:Name="OpacitySlider"
              Grid.Column="1"
              Minimum="55"
              Maximum="100"
              Value="92"
              TickFrequency="5"
              IsSnapToTickEnabled="False"
              Height="20"
              ToolTip="Window opacity"/>
      <TextBlock x:Name="OpacityText"
                 Grid.Column="2"
                 Text="92%"
                 FontSize="{DynamicResource MeterTextNormal}"
                 Foreground="#DCE5EE"
                 VerticalAlignment="Center"
                 TextAlignment="Right"/>
     </Grid>
     <Grid Grid.Row="2" Margin="0,0,0,9">
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="76"/>
       <ColumnDefinition Width="*"/>
       <ColumnDefinition Width="42"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="TEXT SIZE"
                 FontSize="{DynamicResource MeterTextSmall}"
                 Foreground="#9EADBD"
                 VerticalAlignment="Center"/>
      <Slider x:Name="TextScaleSlider"
              Grid.Column="1"
              Minimum="80"
              Maximum="140"
              Value="100"
              TickFrequency="10"
              IsSnapToTickEnabled="False"
              Height="20"
              ToolTip="Interface text size"/>
      <TextBlock x:Name="TextScaleText"
                 Grid.Column="2"
                 Text="100%"
                 FontSize="{DynamicResource MeterTextNormal}"
                 Foreground="#DCE5EE"
                 VerticalAlignment="Center"
                 TextAlignment="Right"/>
     </Grid>
     <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,8">
      <CheckBox x:Name="TopmostCheck"
                Content="ALWAYS ON TOP"
                IsChecked="True"
                Margin="0,0,16,0"/>
      <CheckBox x:Name="ClickThroughCheck"
                Content="CLICK THROUGH"/>
     </StackPanel>
     <TextBlock Grid.Row="4"
                Text="F10 toggles click-through even when the window ignores clicks."
                TextWrapping="Wrap"
                Foreground="#8193A7"
                FontSize="{DynamicResource MeterTextSmall}"/>
    </Grid>
   </Border>
  </Grid>
 </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader($xaml)
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
catch {
    $startupError = Join-Path $PSScriptRoot "startup_error.txt"
    $errorText = (
        "TarteMeter failed to load the WPF interface.`r`n" +
        $_.Exception.ToString()
    )
    $errorText | Set-Content -LiteralPath $startupError -Encoding UTF8
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
$EventGrid = $window.FindName("EventGrid")
$ResetButton = $window.FindName("ResetButton")
$OpacitySlider = $window.FindName("OpacitySlider")
$OpacityText = $window.FindName("OpacityText")
$TextScaleSlider = $window.FindName("TextScaleSlider")
$TextScaleText = $window.FindName("TextScaleText")
$TopmostCheck = $window.FindName("TopmostCheck")
$ClickThroughCheck = $window.FindName("ClickThroughCheck")

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
    foreach ($grid in @($DamageGrid, $HistoryGrid, $EventGrid)) {
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
        $MaximizeButton.Content = "□"
    }
    else {
        $window.WindowState = [Windows.WindowState]::Maximized
        $MaximizeButton.Content = "❐"
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
        "Theresa" = "#FF9CBD"
        "Ornette" = "#C0AEFF"
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
        $maxBarValue = 1.0
        if ($rawRows.Count -gt 0) {
            $maxBarValue = (
                $rawRows |
                Measure-Object -Property DpsNumber -Maximum
            ).Maximum
            if ($maxBarValue -le 0) {
                $maxBarValue = (
                    $rawRows |
                    Measure-Object -Property DamageNumber -Maximum
                ).Maximum
            }
            if ($maxBarValue -le 0) { $maxBarValue = 1.0 }
        }

        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in ($rawRows | Sort-Object DamageNumber -Descending)) {
            $critRate = if ($row.HitsNumber -gt 0) {
                100.0 * $row.CritsNumber / $row.HitsNumber
            }
            else { 0.0 }

            $barValue = $row.DpsNumber
            if ($barValue -le 0) { $barValue = $row.DamageNumber }
            $barPercent = 100.0 * $barValue / $maxBarValue

            $rows.Add([pscustomobject]@{
                Character = $row.Character
                Damage = "{0:N0}" -f $row.DamageNumber
                DPS = "{0:N0}" -f $row.DpsNumber
                Share = "{0:0.00}%" -f $row.ShareNumber
                Hits = $row.HitsNumber
                CritRate = "{0:0.0}%" -f $critRate
                Highest = "{0:N0}" -f $row.HighestNumber
                Average = "{0:N0}" -f $row.AverageNumber
                BarPercent = $barPercent
                BarWidth = [Math]::Max(
                    3.0,
                    [Math]::Min(300.0, $barPercent * 3.0)
                )
                BarBrush = Get-CharacterBarBrush $row.Character
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

function Get-SampledEvents {
    param([object[]]$Events, [int]$Limit)

    if ($Events.Count -le $Limit) { return $Events }

    $step = [int][Math]::Ceiling($Events.Count / [double]$Limit)
    $sampled = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $Events.Count; $index += $step) {
        $sampled.Add($Events[$index])
    }
    if ($sampled[$sampled.Count - 1] -ne $Events[$Events.Count - 1]) {
        $sampled.Add($Events[$Events.Count - 1])
    }
    return $sampled.ToArray()
}

function Populate-EventGrid {
    param([object[]]$Events)

    $visibleEvents = @(Get-SampledEvents $Events $script:maxEventRows)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($event in $visibleEvents) {
        $critical = [bool]$event.critical
        $rows.Add([pscustomobject]@{
            Time = "{0:0.000}s" -f (Convert-ToNumber $event.time)
            Character = [string]$event.character
            Damage = "{0:N0}" -f (Convert-ToNumber $event.damage)
            Critical = if ($critical) { "CRIT" } else { "" }
        })
    }
    $EventGrid.ItemsSource = $rows
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

    $allEvents = @($Battle.events)
    if ($allEvents.Count -eq 0) {
        $HistoryTimelineLabel.Text = (
            "This legacy entry does not contain a detailed timeline"
        )
        return
    }

    $events = @(Get-SampledEvents $allEvents $script:maxTimelineMarkers)
    $viewportWidth = [Math]::Max(
        580.0,
        $HistoryTimelineScroll.ViewportWidth
    )
    $height = 54.0

    $maxTime = 0.0
    $maxDamage = 0.0
    foreach ($event in $allEvents) {
        $eventTime = Convert-ToNumber $event.time
        $eventDamage = Convert-ToNumber $event.damage
        if ($eventTime -gt $maxTime) { $maxTime = $eventTime }
        if ($eventDamage -gt $maxDamage) { $maxDamage = $eventDamage }
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
            "{0:0.000}s  •  {1}`n{2:N0} damage{3}" -f
            $eventTime,
            [string]$event.character,
            $eventDamage,
            $(if ($isCritical) { "  •  CRITICAL" } else { "" })
        )
        $bar.ToolTip = $tooltip
        [Windows.Controls.ToolTipService]::SetInitialShowDelay($bar, 80)
        [Windows.Controls.ToolTipService]::SetBetweenShowDelay($bar, 0)
        [Windows.Controls.ToolTipService]::SetShowDuration($bar, 12000)

        [Windows.Controls.Canvas]::SetLeft($bar, $x)
        [Windows.Controls.Canvas]::SetTop($bar, $barTop)
        [void]$HistoryTimelineCanvas.Children.Add($bar)
    }

    $markerText = if ($events.Count -lt $allEvents.Count) {
        "{0}/{1} markers" -f $events.Count, $allEvents.Count
    }
    else {
        "{0} hits" -f $allEvents.Count
    }
    $detailNote = if ([bool]$Battle.events_truncated) {
        " • detailed events capped"
    }
    else { "" }

    $HistoryTimelineLabel.Text = (
        "{0} • {1} • {2:0.0}s • gold = critical{3}" -f
        $Battle.target,
        $markerText,
        (Convert-ToNumber $Battle.duration),
        $detailNote
    )
}

function Select-HistoryEntry {
    $selected = $HistoryGrid.SelectedItem
    if ($null -eq $selected) { return }

    try {
        $battle = $selected.RawJson | ConvertFrom-Json
        $script:selectedBattle = $battle
        $allEvents = @($battle.events)
        Populate-EventGrid $allEvents
        Draw-LogsTimeline $battle
    }
    catch {
        $script:selectedBattle = $null
        $EventGrid.ItemsSource = $null
        $HistoryTimelineCanvas.Children.Clear()
        $HistoryTimelineLabel.Text = "The selected log entry could not be parsed"
        Write-WindowError $_
    }
}

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
$MinimizeButton.Add_Click({
    $window.WindowState = [Windows.WindowState]::Minimized
})
$MaximizeButton.Add_Click({ Toggle-MaximizeRestore })
$CloseButton.Add_Click({ $window.Close() })

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

$window.Add_StateChanged({
    if ($window.WindowState -eq [Windows.WindowState]::Maximized) {
        $MaximizeButton.Content = "❐"
    }
    else {
        $MaximizeButton.Content = "□"
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

        if (
            $message -eq [TarteNative]::WM_HOTKEY -and
            $wParam.ToInt32() -eq $script:clickHotkeyId
        ) {
            Set-ClickThrough (-not $script:clickThroughEnabled)
            $handled.Value = $true
        }
        return [IntPtr]::Zero
    }

    $source.AddHook($hook)
    [void][TarteNative]::RegisterHotKey(
        $script:windowHandle,
        $script:clickHotkeyId,
        [TarteNative]::MOD_NOREPEAT,
        [TarteNative]::VK_F10
    )
    Set-ClickThrough ([bool]$script:settings.ClickThrough) $false
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(750)
$timer.Add_Tick({
    Update-MeterIfChanged
    Update-HistoryIfChanged
})

$window.Add_Loaded({
    Update-MeterIfChanged $true
    Update-HistoryIfChanged $true
    $timer.Start()
})

$window.Add_Closed({
    $timer.Stop()
    $settingsSaveTimer.Stop()
    $timelineResizeTimer.Stop()
    Write-WindowSettings

    if ($script:windowHandle -ne [IntPtr]::Zero) {
        [void][TarteNative]::UnregisterHotKey(
            $script:windowHandle,
            $script:clickHotkeyId
        )
    }

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
}
finally {
    if ($null -ne $instanceMutex) {
        try { $instanceMutex.ReleaseMutex() } catch {}
        $instanceMutex.Dispose()
    }
}
