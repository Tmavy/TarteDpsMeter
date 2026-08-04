TARTEMETER v3.0.1 - COMPACT STABLE EDITION
===========================================

PROGRAM FILES
Scripts\main.lua        UE4SS combat parser and attribution engine
DPSWindow.ps1           detached Compact WPF renderer
OverlayBootstrap.ps1    hidden overlay bootstrap and startup diagnostics
LaunchOverlay.vbs       fallback hidden launcher
Assets\                 icon, portrait and banner

RUNTIME DATA
dps_state.txt                 throttled live snapshot
dps_command.txt               renderer-to-parser commands
dps_meter.txt                 bounded diagnostic log
battle_history.jsonl          compact encounter records
battle_history_index.tsv      History metadata index
battle_timelines\             complete archived encounter Timelines
current_timeline.csv          active encounter Timeline
latest_battle.csv/json        latest checkpoint/export
window_settings_v11_compact.ini  Compact UI, theme and hotkeys

DEFAULT HOTKEYS
F6  Save/archive/reset
F9  Show/hide
F10 Click-through

HOOKS
/Script/DS.DsAnimationProjectile:OnAttackBeginOverlap
/Script/DS.DsPlayerController:ClientShowDamageText

ARCHITECTURE
The UE4SS parser and WPF renderer are independent. WPF reads plain files and
never touches Unreal objects. Full hit Timelines stream incrementally; History
metadata remains compact. The title-bar X fully closes the overlay, while F9
only changes visibility. An overlay associated with the game exits when the
exact watched DragonSword process ends.

v3.0.1 fixes the installer and overlay fallback VBScript launchers; combat logic is unchanged.
