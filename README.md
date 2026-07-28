TarteMeter

TarteMeter is a real-time DPS meter and combat analysis tool for DragonSword: Awakening.

It tracks damage by character, calculates DPS, records critical hits, stores encounter history, and provides timeline and export tools through a standalone overlay interface.

Features
Real-time damage tracking
Per-character DPS statistics
Total damage and damage share
Hit count and critical-hit rate
Highest and average hit
Encounter duration tracking
Saved battle history
Damage timeline visualization
JSON and CSV exports
Borderless scalable overlay
Click-through and topmost modes
Keyboard shortcuts
UE4SS-based integration
Controls
Key	Action
F6	Reset current combat statistics
F7	Save the current encounter
F9	Open or reopen TarteMeter
F10	Toggle click-through mode
Installation
Download the latest release.
Open Install_TarteMeter.cmd and choose path to DSClient-Win64-Shipping.exe
Start the game.
Press F9 to open or reopen the TarteMeter window.

UE4SS is included in the packaged release unless stated otherwise.

Exported files

TarteMeter can generate:

latest_battle.json
latest_battle.csv
current_timeline.csv
battle_history.jsonl

These files are stored inside the TarteMeter mod directory.

UE4SS

TarteMeter uses UE4SS, an open-source Lua scripting and modding framework for Unreal Engine games.

Official repository:

https://github.com/UE4SS-RE/RE-UE4SS

UE4SS is distributed under the MIT License. Its original copyright and license notices are retained in distributed packages.

Disclaimer

TarteMeter is an independent community project.

It is not affiliated with, endorsed by, or officially supported by the developers or publishers of DragonSword: Awakening or by the UE4SS development team.

Use mods at your own risk. Game updates may temporarily break compatibility.

Bug reports

When reporting a problem, include:

TarteMeter version
UE4SS log files
startup_error.txt, when present
A description of the character, attack, or summon involved
Steps needed to reproduce the issue
License

The license for TarteMeter should be specified separately from the licenses of bundled third-party components.

Third-party software, including UE4SS, remains subject to its original license terms.
