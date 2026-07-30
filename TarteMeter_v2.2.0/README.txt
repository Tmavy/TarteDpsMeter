TarteMeter v2.2.0

MAJOR UI UPDATE
- Preserved the compact TarteMeter visual design.
- Moved window controls into a dedicated gear settings panel.
- Settings include opacity, click-through, always-on-top, and text size.
- Renamed HISTORY to LOGS.
- Removed the old raw debug-log tab.
- Removed the SAVE/F7 control.
- RESET archives the encounter before clearing the meter.
- If the history file is temporarily locked, RESET keeps the current data intact
  instead of deleting an unsaved encounter.
- Character damage bars use stable, character-specific colors.

PERFORMANCE AND STABILITY
- Removed duplicate reset handling: F6 is registered only by UE4SS.
- Replaced repeated player-controller searches with a validated UObject cache.
- Removed recurring full-world monster scans. The monster list is built after map
  readiness and refreshed only when the cached actors are no longer valid.
- Added owner-resolution cache pruning so transient projectile objects cannot
  accumulate indefinitely during long sessions.
- Reduced roster enumeration to a 60-second safety refresh.
- Reduced command-file polling from four times to two times per second.
- State and timeline writes remain buffered and throttled.
- Failed state-file replacements are retried without clearing the last valid UI.
- The WPF window reads state only when the state file actually changes.
- Removed the raw log refresh path from the interface.
- Full battle JSON is parsed only for the selected encounter.
- Event-grid and timeline rendering are sampled for extremely long encounters.
- Detailed JSON events are capped at 25,000 per encounter; damage totals, DPS,
  hits, critical counts, and the live timeline CSV remain exact.
- Timeline redraw during resizing is debounced.
- Shared frozen brushes are reused instead of recreated for every marker.

CORRECTNESS
- Fixed encounter duration so automatic saving no longer adds the idle detection
  delay to combat time or lowers the saved DPS.
- Fixed a Lua forward-reference issue in automatic encounter saving.
- Preserved the v2.0.1 conservative attribution order:
  LastAttacker aggregate -> explicit source fallback -> captured active character.
- Preserved SWAP_CARRY_SECONDS = 0.000.
- No speculative damage transfer between switched characters was reintroduced.
- Reset avoids duplicate history entries after a battle was already auto-saved.

INSTALLER
- The installer no longer overwrites Mods\mods.txt before backing it up.
- Existing TarteMeter history, settings, logs, and entries for other mods are
  preserved during an update.
