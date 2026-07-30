TarteMeter v2.5.2
DragonSword: Awakening combat analyzer

CONTROLS
- Reset + Save, Show / Hide, and Click Through are configurable in Settings.
- Defaults: F6, F9, and F10.
- The title-bar X hides the window.
- EXIT TARTEMETER PROCESS closes the overlay process completely.

DISPLAY
- Midnight Gold, Obsidian Violet, and Graphite Teal themes.
- Adjustable opacity and text size.
- Character-specific damage-share gauges.
- Encounter logs with totals, ranked character breakdown, and timeline.

DATA
- battle_history.jsonl: saved encounter history.
- latest_battle.json / latest_battle.csv: latest exported encounter.
- current_timeline.csv: current encounter timeline.
- window_settings_v5.ini: theme, display, and hotkey preferences.

DIAGNOSTICS
- startup_diagnostic.txt is created on every launch.
- startup_error.txt is created for every fatal startup failure.
- window_error.txt contains runtime WPF errors.
- window_launcher_error.txt contains Windows Script Host launcher failures.

COMBAT SAFETY
The v2.4.3 damage attribution and calculation pipeline is preserved.
v2.4.4 changes startup reliability and installer presentation only.


v2.4.5 STARTUP FIX
- Windows Script Host launchers are now plain ASCII with CRLF.
- Fixes invalid-character errors at line 1, character 1.


v2.5.0 STARTUP ARCHITECTURE
- Restored detached CMD START to hidden PowerShell as the primary path.
- Windows Script Host is fallback-only.
- Uses a version-specific mutex to bypass older hidden processes.
- Forces the overlay to the center of the screen and Windows taskbar.


v2.5.1 WPF THEME FIX
- New-Brush now returns exactly one SolidColorBrush.
- Theme resources are assigned without PowerShell pipeline output.
- Invalid saved theme values safely fall back to Midnight Gold.


v2.5.2 WPF RESOURCE FIX
- Theme switching no longer replaces DynamicResource dictionary entries.
- Existing XAML SolidColorBrush colors are updated in place.
- Startup keeps valid XAML defaults if a saved theme cannot be applied.
