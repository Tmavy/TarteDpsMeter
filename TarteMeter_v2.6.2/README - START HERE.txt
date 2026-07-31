TARTEMETER v2.6.2 - START HERE

INSTALL OR UPDATE
1. Close DragonSword.
2. Close every old TarteMeter window and TarteMeter PowerShell process.
3. Extract this complete archive.
4. Run TarteMeter Setup.vbs.
5. Click Install or Update TarteMeter.
6. Start or restart DragonSword through Steam.

CHAKO
Chako remains a separate damage row. Projectile overlap events now capture the
enemy target as a plain string key. An exact Chako source + target match is used
before the delayed batch's LastAttacker value, so switching away from Dana does
not redirect Chako's damage to the active character.

TIMELINE
The LOGS timeline uses a fixed horizontal scale. Resizing the window does not
compress the encounter. Use the visible horizontal scrollbar to move through
the fight. The existing splitter still adjusts timeline height.

PERFORMANCE
The v2.6.1 batching, bounded source map, deferred disk writes, owner limits, and
no-persistent-UObject architecture are retained. No new scan or polling path was
added.
