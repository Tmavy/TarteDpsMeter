TARTEMETER v2.7.4

FILES
Scripts\main.lua       UE4SS combat parser and attribution engine
DPSWindow.ps1          WPF renderer
OverlayBootstrap.ps1   hidden overlay bootstrap and startup diagnostics
LaunchOverlay.vbs      fallback hidden launcher
Assets\                icon, portrait and banner

RUNTIME DATA
dps_state.txt
dps_command.txt
dps_meter.txt
battle_history.jsonl
current_timeline.csv
latest_battle.csv
latest_battle.json
window_settings_v7.ini

DEFAULT HOTKEYS
F6  Reset and archive
F9  Show / hide
F10 Click-through

DESIGN
The parser does not depend on the WPF renderer. The renderer reads throttled
state snapshots and never touches Unreal Engine objects.


PROCESS LIFECYCLE
The overlay watches the DragonSword process that launched it and exits when the game exits.
The title-bar X fully closes the overlay process; F9 is show/hide.
