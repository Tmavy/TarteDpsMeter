TARTEMETER v2.5.2 - START HERE

TarteMeter is an English-language UE4SS damage meter for
DragonSword: Awakening.

INSTALL OR UPDATE
1. Close DragonSword.
2. Extract the entire archive to a normal folder.
3. Double-click TarteMeter Setup.vbs.
4. Select DSClient-Win64-Shipping.exe when automatic detection does not find it.
5. Click Install or Update TarteMeter.
6. Keep Launch TarteMeter after installation enabled for the first test.
7. Start or restart DragonSword through Steam.

v2.5.2 FIX
This release fixes WPF theme startup failures such as:

  '#FF3A4B60' is not a valid value for property 'BorderBrush'.

The color is valid. Replacing a DynamicResource dictionary entry at runtime
caused Windows PowerShell 5.1/WPF to reapply the resource through style setters
incorrectly. TarteMeter now keeps the original XAML SolidColorBrush resources
and changes their Color values in place.

STARTUP DIAGNOSTICS
  Mods\TarteMeter\startup_diagnostic.txt
  Mods\TarteMeter\startup_error.txt
  Mods\TarteMeter\window_error.txt
  Mods\TarteMeter\window_launcher_error.txt
