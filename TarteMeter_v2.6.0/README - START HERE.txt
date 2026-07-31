TARTEMETER v2.6.0 - START HERE

INSTALL OR UPDATE
1. Close DragonSword.
2. Close every TarteMeter window and old TarteMeter PowerShell process.
3. Extract the complete archive.
4. Run TarteMeter Setup.vbs.
5. Click Install or Update TarteMeter.
6. Start or restart DragonSword through Steam.

NATIVE CRASH FIX
The combat core no longer retains transient Unreal actor objects between ticks.

Removed from asynchronous/background state:
- cached player-controller UObject;
- monster UObject cache;
- actor entries in the position cache;
- target UObject inside delayed damage events.

ClientShowDamageText now captures only plain Lua values. After the existing
80 ms attribution delay, the target is reacquired inside ExecuteInGameThread.
The background LoopAsync performs only Lua-table maintenance and file I/O.

CHAKO
Dana's summon is now shown as a separate character named Chako.
The exact DsMon_Chaco_V2_C attacker/source resolves to Chako regardless of the
currently active player character.

PRESERVED
- target-specific LastAttacker attribution;
- HitLocation target matching;
- explicit projectile/source ownership;
- total damage, DPS, hits, crits, highest hit;
- automatic raid logging, manual RESET protection, history, and exports;
- configurable hotkeys, themes, opacity, click-through, and LOGS timeline.
