# Changelog

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
