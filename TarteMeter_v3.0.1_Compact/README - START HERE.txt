TarteMeter v3.0.1 - Compact Stable Edition
=============================================

This is the primary Compact release of TarteMeter.
Install only one TarteMeter edition at a time.

INSTALLATION
------------
1. Fully close DragonSword.
2. Close any remaining TarteMeter powershell.exe process.
3. Run "TarteMeter Setup.vbs".
4. Select Install / Update.
5. Start DragonSword normally.

DEFAULT HOTKEYS
---------------
F6   Save encounter and reset
F9   Show / hide meter
F10  Toggle click-through

INTERFACE
---------
- Dense two-line character rows.
- Damage, DPS, share, hits, crit rate, maximum hit and average hit remain visible.
- History and selected encounter breakdown share one screen.
- Damage-share bars fill from 0 to 100 percent.
- Title-bar controls use fixed vector glyphs with stable 34 x 32 pixel hit areas.
- At very narrow widths, secondary title labels hide automatically before controls overlap.

COMBAT RUNTIME
--------------
The combat parser is byte-equivalent to the validated v2.7.5 runtime after
normalizing only the version string. Exactly two verified UE4SS hooks remain:

  /Script/DS.DsAnimationProjectile:OnAttackBeginOverlap
  /Script/DS.DsPlayerController:ClientShowDamageText

No additional combat, diagnostic or per-frame hooks were added for v3.0.1.
See _InstallerData/VALIDATION.txt and CRASH_SAFETY_AUDIT.txt for the full audit.

IMPORTANT LIMITATION
--------------------
The package was statically validated in Linux. WPF and live DragonSword combat
cannot be executed in this environment, so Windows/game runtime testing is still
required after installation.

INSTALLER NOTE FOR v3.0.1
-------------------------
The VBScript launchers are strict ASCII/CRLF and contain no continuation lines. This fixes Windows Script Host error 800A03EA from v3.0.0.
