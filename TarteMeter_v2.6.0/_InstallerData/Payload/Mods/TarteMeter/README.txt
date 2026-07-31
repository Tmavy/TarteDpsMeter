TARTEMETER v2.6.0

Native stability architecture:
- no transient UObject is retained by LoopAsync;
- no target UObject is stored in delayed damage events;
- delayed target/LastAttacker resolution runs on the game thread;
- background work is limited to plain Lua data and file I/O.

Dana's DsMon_Chaco_V2_C summon is displayed as Chako.
