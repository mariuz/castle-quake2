# Changelog

## Unreleased

- Curved walls: round rooms. Random levels make some big rooms round, with walls of 45-degree facets, and the level editor carves one with `editor round x0 y0 x1 y1` in the console.
- Fixed: monsters in random levels could start stuck in a wall: a tank next to a pillar or a step, or anything placed in a cell with a diagonal wall. The tests now compile 12 random levels and check every monster's starting spot.

## v0.15.0 — 2026-10-30

Diagonal walls in random and edited levels. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Diagonal walls: the level editor has a **Diagonal** tool that cuts a corner at 45 degrees (it picks the corner between two walls), and random levels cut the corners of most bigger rooms.
- README: the license section no longer suggests Castle Game Engine is MIT (it is LGPL with a static linking exception, which lets games use any license).

## v0.14.0 — 2026-10-26

Real slopes, breakable glass windows, a key hunt, the full game's textures as themes, and audio polish. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Fixed: the game could crash on exit after playing a level from the level editor (the console was inserted into the screen twice when the editor opened).
- The full game's textures as themes: with the retail Quake 2 PAKs, every texture set (e1u2, e2u3...) becomes a level theme for the editor and the random levels. Level files remember theme names, so they still load on the demo.
- Breakable glass: windows shatter when shot, with Quake 2's glass sound and debris. Quake 2's breakable walls only explode now if they are meant to (`dmg`), and always throw debris.
- Real slopes: ramps in levels. The level editor has a **Ramp** tool: the floor slopes up to the highest neighbouring cell, smooth to walk on. Random levels climb on slopes instead of 16-unit steps, outdoor hills roll, and the *Hills* tool paints slopes.
- Windows between rooms: a **Window** tool in the editor, and a few windows in random levels. You and monsters can see through the glass, but nobody can walk or shoot through it.
- Audio polish: sounds straight ahead are a little quieter than sounds to the side, as in Quake 2, and the master volume is turned down gently when many loud sounds play at once (big fights no longer distort).
- A key hunt in random levels: on even seeds the blue key that opens the exit often lies in a vault behind red doors, and you have to find the red key first. Red key doors have a red lamp.

## v0.13.0 — 2026-10-25

Keys, ladders, slime, lava, teleporters and outdoor areas in random and edited levels. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Ladders, lava and outdoor areas in levels. The level editor has a **Ladder** tool (R): a ladder goes up the highest step next to the cell, and you climb it like Quake 2's (walk into it, look up). The **Lava** tool (I) makes glowing lava pools that hurt a lot. Quake 2's demo has no lava texture, so the game draws its own. The **Hills** tool paints rolling ground for outdoor areas.
- Four more themes: red and brown indoors, rock and grass outdoors.
- Random levels use ladders for some of the big climbs, have lava pits as well as slime pits, and turn big sky rooms into outdoor areas with grass or rock and rolling ground.
- Keys, slime and teleporters in levels. The level editor has a **Key** tool (K; Y switches between the blue and red key): those doors stay shut ("You need the Blue Key") until you bring the key, which then opens all doors of its colour. It also has a **Slime** tool (M): a damaging green pool. Keys and teleporters are in the entity palette; each teleporter takes you to the teleporter destination of the same number.
- Random levels lock the exit with the blue key on even seeds (with the switch on odd ones), turn a third of the pools into shallow slime pits, and put a teleporter in the secret room that takes you back to the start.
- Teleporters show their pad (the `dmspot` model), as in Quake 2.
- Autotest scripts can now stand next to things in parts of the level that are not drawn at the moment.

## v0.12.0 — 2026-10-24

Real visibility in random and edited levels: only what you can see is drawn. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Random and edited levels now have real visibility: the level compiler works out which parts of the level can see each other (like Quake 2's `qvis`, on the level grid), so only what you can see is drawn and monsters only hear you through open space, as in the original maps. On a typical random level about a quarter of it is drawn at a time.
- CI: the lift test accepts small differences in where the player rests on the lift.

## v0.11.0 — 2026-10-24

Lifts and switches: in the level editor and in random levels (lifts to high rooms, the exit locked behind a switch). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Lifts and switches in levels. The level editor has a **Lift** tool (H; `,` / `.` set the height): lift cells become a Quake 2 platform (`func_plat`) that carries you up when you step on it and comes back down. It also has a **Button** tool (J): a button opens the doors of its channel (C cycles channel 1–9, and the Door tool uses the current channel), and those doors then stay open. Doors without a channel still open by themselves.
- Random levels use lifts to reach rooms much higher or lower than their neighbours, and lock the exit room behind doors opened by a switch somewhere along the way (checked to be reachable with the exit shut), a classic Doom / Quake progression.
- The roadmap is rewritten as a short, current priority list.

## v0.10.0 — 2026-10-24

Doors and water in random and edited levels, monsters that open doors, and Random Level / Level Editor working from the first screen (and in the browser). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Fixed: *Random Level* and *Level Editor* in the title menu (the first screen, as in the browser build) failed to load ("Failed to load level"); the title menu passed the placeholder name instead of a new random level, and didn't open the editor.
- Doors and water in levels. The level editor has **Door** (O) and **Water** (U) tools: door cells become Quake 2 doors (`func_door`, touching cells are one door) that slide up when you come near, and water cells fill up to a depth (V / B change it) to wade or swim in, with the warping water surface. Random levels put doors at some corridor entrances and sunken pools in some rooms; the generator counts swimming up out of a pool as a way out.
- Monsters open doors too, like Quake 2's door trigger field (not doors with the "no monsters" spawnflag).

## v0.9.0 — 2026-10-24

Random levels and a level editor, compiled into Quake 2 maps while the game runs; monsters walk and run at their Quake 2 pace. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Random levels: *Random Level* in the menu or `randmap [seed]` makes a level from a seed, following classic Quake / Doom design. Rooms of varied size are linked into loops (more than one way around). Low corridors climb in steps between high rooms. Big rooms get pillars for cover and raised platforms, and some rooms open to the sky. Monsters get more numerous and tougher further in, some in ambush and some only on harder skills. Weapons come in order of strength, with ammo after them, health and armor after the fights, and barrels. There is a secret room with a reward, and an exit to the next random level. The same seed always makes the same level.
- Level editor: *Level Editor* in the menu (or `editor`) to paint levels from above. You can paint walls and floors, set floor and ceiling heights, sky and texture themes, and place the player start, lights, monsters, weapons, ammo, items, barrels and the exit. It has undo, can generate a random level to start from, and saves and loads levels. *Play* compiles the level into a Quake 2 map and starts it at once; *Export* saves the `.bsp`. In the Castle Game Engine editor, `TQuakeMap.LevelUrl` shows a saved level and `MapName` `rand<seed>` a random one, and the editor is a component too (`TQuakeLevelEditor`).
- Levels are compiled at runtime into real Quake 2 maps (BSP tree, brushes, lightmaps, visibility), so monsters, items, triggers, saves and the exit work in them as in the original maps.
- Fixed: after a level change the game could keep testing collisions against the previous map (the player and monsters could fall through floors).
- Monsters walk and run on Quake 2's animation frames: each frame moves them by its distance from the original game's tables, so their feet keep step and every type has its Quake 2 pace — the tank plods at under half the speed it had (47 units a second), parasites lunge almost twice as fast (254), infantry and berserkers are quicker, flyers slower (100). The demo maps' monsters are now all fully supported in the map report.

## v0.8.1 — 2026-10-24

Flyers fight up close and the tank picks its attacks like Quake 2. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Flyers slash with their wing blades when the player is close (`flyer_melee`: 5 damage a wing, repeated most of the time while he stays in reach), and the tank picks its attack by distance like `tank_attack` (rockets only beyond 250 units, blaster or machinegun closer).
- Fixed: a monster with a gun swinging at the player up close (the infantry's gun butt, now the flyer's blades) could hit from as far as its gun reaches; melee hits now reach 80 units like Quake 2's `fire_hit`.

## v0.8.0 — 2026-10-24

Turrets from the full game and a Quake 2 death. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Turrets (`g_turret.c`): a `turret_breach` turns towards where its `turret_driver` aims (within its pitch / yaw limits, at its `speed`), its `turret_base` turns with it, and it fires rockets (100–150 damage, faster on harder skills) from the point its target marks, once the driver has seen the player for 3 − skill seconds; the driver is an infantry that rides behind the gun, never flinches and is gibbed when killed, and the gun then levels. The demo has no turrets: CI spawns one (as boxes) with the `spawn` command.
- Player death like Quake 2's `player_die`: the view drops (eye 8 above the origin), turns to the killer, looks a little up and rolls 40°, and the view weapon goes away; below -40 health the player is gibbed (splat, 4 pieces of meat, the view at floor level). The `kill` command is a suicide at health 0 (no gibs, also in god mode), as in Quake 2.

## v0.7.0 — 2026-10-23

Medics bring dead monsters back. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Medics revive dead monsters (`m_medic.c`): once a second a medic looks for a corpse it can see within 1024 units (the one with the most health), walks to it, uses its healing cable for a second and the monster gets up with full health, after the player; it counts towards the level's monsters again. Tested on the demo with a medic without its model (the demo has none).

## v0.6.0 — 2026-10-20

Clocks and digit displays from the full game, and models lit by the flickering and switchable lights around them. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Models are lit by all the light styles of the floor below them, like Quake 2's `R_LightPoint`: monsters, items and props flicker with flickering lights and go dark when a light is switched off (they only saw the first style before); they are re-lit 10 times a second.
- Clocks and displays: `func_clock` (count up, count down or the time of day, once a second, firing its `pathtarget` when the time is up), `target_string` and `target_character` (digit brushes showing 0-9, `-` and `:` through their texture frame), like the full game's countdowns.

## v0.5.0 — 2026-10-19

Quake 2 gibs, rotating skies, currents and conveyor belts, and brush textures that animate like the original. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Brush entity textures animate like Quake 2 (`R_TextureAnimation` with the entity frame and `EF_ANIM*`): buttons show their first frame until pressed, then cycle their "pressed" frames 2 / 3 and, after returning, 0 / 1; doors, walls, rotating brushes and explosives cycle only when their spawnflags say ANIMATED (10 frames a second for ANIMATED_FAST); everything else stays still (before, every animated brush texture cycled twice a second all the time). Faces that start in the middle of a texture chain keep their offset.
- Gibs like Quake 2's `ThrowGib`: each monster breaks into its own pieces (soldiers 3 meat + chest + head, the tank metal and a gear, ...) at its own gib health (soldiers -30, gunner -70, tank -200; it was -40 for all), thrown faster by harder hits from all over the body, spinning; flesh lands on the map's brushes with a splat, metal and barrel debris bounce; pieces vanish after 10 - 20 s. The flyer explodes when it dies.
- Rotating skies: worldspawn `skyrotate` / `skyaxis` like Quake 2's `R_SetSky`, and a `sky <name> [rotate [x y z]]` console command (CI checks that the sky turns).
- Water currents and conveyor belts: brushes with `CURRENT_*` contents push the player like Quake 2's `PM_AddCurrents` (400 in water, half when wading, 100 on a belt); `func_conveyor` is supported.

## v0.4.0 — 2026-10-19

Phones, more of the full game, and monsters that fight more like Quake 2. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- *Options → Interface Size* (Auto, Small, Normal, Large, Huge): the menu, console and HUD text scale on top of CGE's UI scaling; Auto is 1.75× on touch screens, so menu rows are big enough to tap on a phone. The menu shows as many rows as fit (with "..." for more), centers its text and shows touch hints; pickup messages move to the center on touch screens; console lines no longer overlap.
- CI taps through the menu on a 2400 × 1080 touch screen.
- Full-game entities: `misc_viper`, `misc_bigviper`, `misc_viper_bomb`, `misc_blackhole`, `misc_eastertank` / `misc_easterchick(2)`, `target_blaster`, `target_spawner`, `func_killbox`, `trigger_gravity`; `target_earthquake` now shakes the player (it only played the sound).
- Monster attacks closer to Quake 2: soldiers refire in melee range (and half the time on nightmare), the light soldier skips cocking its gun, soldiers duck and shoot when dodging (from medium skill), the machinegun soldier uses its own attack, the tank uses its machinegun (19 bullets of 20).
- `spawn <class> [key value]...` console command, to try entities the demo maps lack (CI tests the ones above with it).

## v0.3.0 — 2026-10-18

The first tagged release: Windows, Linux and Android packages below, the browser build at <https://mariuz.github.io/castle-quake2/>. Bundled with the Quake 2 shareware demo (`demo1`–`demo3`); a full Quake 2 install loads from `baseq2/` or `-basedir`.

### Play like Quake 2
- Player movement is Quake 2's pmove on box traces against the map's brushes (`CM_BoxTrace`, `PM_StepSlideMove`): steps, slopes, crouch, ladders, water, player-clip brushes.
- Weapons run on Quake 2's gun frames (`Weapon_Generic` / `Weapon_Grenade`): fire frames, refire, put away / raise, chaingun spin-up, BFG delay, cooking hand grenades.
- Monsters attack on Quake 2's attack frames (machinegun bursts, the gunner's chain refire, grenade volleys, the tank's rockets, the parasite's drain), notice the player like Quake 2 (front cone, hearing through the PHS, ambush, trigger-spawned monsters, group wake), follow the player trail, duck under shots and use `trigger_monsterjump`.
- Monsters walk with `SV_movestep` / `M_CheckBottom` (step up 18, don't walk off ledges, respect monster-clip brushes); hitscan, projectiles, sight and lasers trace the brushes too, grenades bounce off the hit plane, barrels are solid.
- Doors, plats and trains carry and push the player, monsters, corpses and items (`SV_Push`); blocked movers hurt and reverse, crushers keep going, corpses caught in a door are gibbed.
- View and weapon bob, weapon lag, landing dip and damage kicks; Quake 2 style sound (attenuation, entity channels, merged looping sounds).

### Options and devices
- Options menu: mouse sensitivity and invert, field of view, volumes, view bob, key rebinding; skill selection (easy … nightmare).
- Gamepads (sticks, triggers, menus) and on-screen touch controls (move stick, drag to look, buttons, tap menus); an Android APK (debug-signed, for sideloading).
- Gamepad and touch were only tested with simulated input so far — reports from real devices are welcome.

### Levels
- PVS and areaportal culling of the world and of entities; savegames with projectiles and delayed events; units remember their levels; cross-level triggers; help computer and intermission.
- `--map-report` lists what a set of maps needs (the demo has no unsupported entity classes).

### Tools
- `record <name>` / `stop` console commands record a playthrough as an autotest script (`--demo @file` replays it), to turn a bug into a regression test.
- CI: 173 unit checks, headless autotests (keyboard, virtual gamepad, simulated touch, a recorded replay), screenshot comparison, culling check, map report; Windows, Linux, Android and WebAssembly builds.
- The CGE editor opens the levels (`TQuakeMap` with skybox and entity markers); monster types and named sounds are editable designs.
