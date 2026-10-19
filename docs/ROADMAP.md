# Castle Quake 2 Roadmap

Comparison with the original **Quake 2** (id Tech 2, `ref_gl` + `game` DLL), what is left to do, and how Castle Game Engine (CGE) features can carry it.

## Comparison

| Subsystem | Original Quake 2 | Castle Quake 2 (now) | Gap |
| :--- | :--- | :--- | :--- |
| World geometry | IBSP v38, PVS / areaportal culling | X3D batches per texture and 1024-unit region; PVS and areaportal culling of world regions and of movers / monsters / items / props / lasers; CGE frustum culling | — |
| Lighting | RGB lightmaps, 4 styles, dynamic lights | All 4 styles (animated, switchable, ramps), 2x overbright, LightPoint model tint, dynamic lights on the world and models | More than 4 surface lights at once; light styles in the model tint. |
| Sky | Skybox, `skyrotate`, `skyaxis` | Skybox via `TCastleBackground` | Sky rotation. |
| Liquids | Warped water / lava (`SURF_WARP`), contents | Warp shader, non-solid liquid surfaces, swimming, drowning, lava / slime damage, underwater tints | Underwater view wobble. |
| Models | MD2 with lerp, skins, `EF_*` effects | MD2 with lerp, skins, shells (quad, invulnerability, power armor) | `EF_POWERSCREEN` model, glow, rotating / bobbing items. |
| Sprites | SP2 (BFG, explosions) | SP2 loader, BFG ball / explosion sprites | Other sprite users (bubbles, flashes). |
| Player physics | Pmove (air control, water, ladders, crouch slide) | Pmove as `TQuakePlayerMovement`: the 32 × 32 × 56 box traced against the BSP brushes, movers and monsters (`CM_BoxTrace`, `PM_StepSlideMove`), movers carry and push the player | — |
| Weapons | 10 + hand grenades, frame-timed | 10 + hand grenades on Quake 2's gun frames (`Weapon_Generic`: fire frames, refire, put away / raise, chaingun spin, BFG delay, grenade cook) | — |
| Monsters | Full AI (`ai_run`, dodge, ambush, medic revive, bosses), skill levels | Quake 2 perception (`FindTarget`, PHS hearing, group wake, ambush, trigger spawn), player trail pursuit, dodging, attacks on Quake 2's attack frames (demo monsters), `trigger_monsterjump`, patrols, combat points, 19 types tunable in the editor, skill 0–3 | Attack tables for the full game's monsters; medic revive, bosses. |
| Props / effects | Barrels, banners, ships, lasers, splashes, explosion models | All of these used by the demo maps, plus the full game's `misc_viper` / `misc_bigviper` / `misc_viper_bomb`, `misc_blackhole`, easter-egg poses, `target_blaster`, `target_earthquake` (shakes), `target_spawner`, `func_killbox`, `trigger_gravity` | Gib models with velocities, `func_conveyor`, `func_clock` / `target_string`, turrets. |
| Level flow | Units, cross-level triggers, help computer, intermission, savegames | All of these (JSON savegames, including projectiles in flight and pending delayed events) | — |
| Audio | 3D sounds, entity channels, merged loop sounds, CD music | Quake 2 attenuation (incl. `ATTN_STATIC`), `CHAN_*` channels, point sounds that outlive entities, loop mixer (one voice per sound, PVS-checked, `SOUND_LOOPATTENUATE`), 32 sources, OGG tracks, named sounds editable in the editor | Stereo panning curve (OpenAL's, not Quake 2's), `s_volume` style master limiter. |
| Input / options | Key bindings, mouse sensitivity, joystick, skill | Options menu (sensitivity, invert, FOV, volumes), key rebinding, skill selection, saved in `UserConfig`, gamepad (sticks, triggers, menus), touch controls (stick, drag look, buttons, tap menus) | Gamepad button rebinding; gamepad and touch not yet tried on real hardware. |
| Multiplayer | Deathmatch / coop over UDP | Single player only | Out of scope for now (see below). |
| Tooling | Console, `+map`, demos | Console, autotest scripts (keys, gamepad, touch), `record` to turn play into a script, screenshot comparison in CI, 183 unit checks, map compatibility report, CGE editor components and designs, F8 inspector, Windows / Linux / Android / WebAssembly builds | Editor property editors. |

## Done so far

- **Look**: lightmaps and light styles, dynamic lights, skybox, water warp, MD2 with shells, SP2 sprites, particles, gibs, weapon viewport.
- **Play**: all weapons and items on Quake 2's gun frames, pmove with BSP box traces (`PM_StepSlideMove`), ladders / water, doors / plats / trains / buttons that carry, push and get blocked like Quake 2, trigger chains, monster AI with Quake 2 perception, pursuit, dodging and frame-accurate attacks.
- **Flow**: help computer, intermission, savegames, cross-level triggers, units that remember state.
- **Performance**: PVS + areaportal culling of the world and of entities (`novis` to compare), batched particles.
- **Editor**: views from designs, `TQuakeMap` building levels in the editor with skybox and entity markers, behaviors with published state, monster types (`data/monsters.castle-transform`) and named sounds (`data/sounds.castle-component`).
- **Reach**: options menu with key rebinding, skill levels, gamepad, touch controls, Android APK and WebAssembly builds.
- **Engineering**: CI on Windows / Linux / Android / Web, autotests under Mesa (keyboard, virtual gamepad and simulated touch), screenshot references, culling check (vis vs `novis`), map compatibility report, recorded replays, 183 unit checks.
- **Release**: v0.3.0, the first tagged release, with Windows / Linux / Android packages ([changelog](CHANGELOG.md)).

## Next: suggested improvements (Phase 6, prioritised)

Phase 5 is complete and v0.3.0 is released. What would help most now, roughly in order of value for effort:

1. **Try it on real hardware** (small effort, removes the biggest unknowns). Gamepad, Android touch and GPU performance were only tested headless. Install the APK on a phone, play with a controller, and run on a real GPU with `fps` on. Expected follow-ups: touch button sizes and look speed, ~~menu and HUD scaling on phone screens~~ (done: *Options → Interface Size*, Auto = 1.75× on touch screens, on top of CGE's UI scaling; the menu shows as many rows as fit and taps whole rows), an `AndroidSigningProperties.txt` release key and a proper launcher icon.
2. ~~**Monsters and shots on the BSP traces**~~ — done (monsters move with `SV_movestep` / `M_CheckBottom`, shots / projectiles / sight / lasers trace `MASK_SHOT` / `MASK_OPAQUE`). The player now collides with the real brushes, but monsters still move with CGE mesh collisions and the `PlayerBlockBox` workaround, and hitscan / projectiles / line of sight use `WorldRayCast` against render meshes. Porting `SV_movestep` / `M_CheckBottom` (step up 18, don't walk off ledges) and using `TQuakeCollision` for shots and sight would make monsters respect player-clip / monster-clip brushes, ride and be pushed by movers, and make sight checks much cheaper.
3. ~~**Movers push everything**~~ — done (monsters, corpses and items ride and get pushed; blocked monsters take the mover's damage, corpses are gibbed). Plats and doors only carry / push the player; monsters, items and corpses on a moving plat stay behind. Once monsters use traces, extend `PushPlayerByMovers` to all entities (`SV_Push` iterates every entity).
4. ~~**Record playthroughs as test scripts**~~ — done (`record <name>` / `stop`, `IN:` lines on the script clock with drift correction, `--demo @file`). A `record` console command that writes the player's inputs as an autotest demo script (`GO` / `T` / `P` / `X` with timings) would turn any bug repro into a regression test, and is a cheap stand-in for Quake 2's demo files.
5. **Full game monsters** (medium–large, needs the retail PAK). Attack tables (`QuakeMonsterAttacks`) for gladiator, chick, mutant, brain, floater, hover, flipper, medic and the bosses; medic revive; supertank / Makron / jorg behaviour; `misc_viper`, `target_blaster`, `func_killbox`, `turret_*`. Run `--map-report` on a retail `baseq2` to order the work; a nightly workflow can test against a private PAK.
6. ~~**Release v0.3.0**~~ — done. Tag a release so the Windows, Linux, Android and Web packages are published together, with a short changelog of Phase 5.
7. **Editor**: property editors (map dropdown, reload verb), selectable entities with their key / value pairs (needs the Lazarus-built editor).
8. **Audio polish**: Quake 2's stereo panning curve and a master limiter, so many loud sounds at once don't clip.

## Earlier suggestions (most done)

### 1. Player-facing polish (highest impact, small)
- ~~Options menu~~ — done: mouse sensitivity and invert, field of view, sound and music volume, *Controls* page with key rebinding, saved in `UserConfig` (`QuakeSettings`).
- ~~Skill selection~~ — done: *Single Player* asks Easy / Medium / Hard / Nightmare; skill filters spawnflags, halves damage on easy, speeds up monster attacks from hard on, no pain flinches on nightmare; `skill` console command; kept in savegames.
- ~~Gamepad~~ — done: CGE's `Controllers` (`QuakeGamepad`): left stick moves, right stick looks (radial deadzone, squared response, mouse sensitivity / invert apply), right trigger fires, A jump, B / left trigger crouch, X use, Y hand grenades, bumpers / D-pad cycle weapons, Menu / View open the menu / help computer; menus work with the D-pad, left stick, A and B. Tested with a virtual pad in the autotests (`GP:` / `GB:` demo actions), not yet on a real controller. Later: button rebinding.
- ~~View feel~~ — done: Quake 2's view bob, weapon bob and lag, running tilt, landing dip and damage kicks (`SV_CalcViewOffset`, `SV_CalcGunOffset`, `P_DamageFeedback`), with an *Options → View Bob* switch. Items already rotate (`EF_ROTATE`); Quake 2 items don't bob.

### 2. Feel of combat
- **Frame-accurate attacks**: ~~player weapons~~ — done (`QuakeWeaponFrames`: Quake 2's `Weapon_Generic` / `Weapon_Grenade` frame state machine, so animation, refire, switching and damage line up). ~~Monsters~~ — done for the demo's monsters (`QuakeMonsterAttacks`: soldiers, infantry, gunner, berserk, flyer, parasite, tank play their Quake 2 attack sequences at 10 frames a second and fire on the `mframe_t` fire frames, with machinegun bursts that hold a frame, the gunner's chain refire loop, four-grenade volleys, the tank's three rockets, the parasite's drain, per-shot Quake 2 damage). The soldiers' refire jumps (`soldier_attack*_refire`: melee range or half the time on nightmare; the light soldier skips cocking), their duck-and-shoot attack3 from dodges (by skill), the machinegun soldier's attack4 and the tank's machinegun are done too. Still to do: tables for the full game's other monsters (they keep the generic wind-up attack).
- **Monster AI gaps**: ~~ambush, trigger-spawned monsters, Quake 2 sight / hearing rules~~ — done (`FindTarget`: front cone and ranges, `show_hostile`, hearing through the PHS and connected areas, `sight_entity` group wake, TRIGGER_SPAWN monsters stay away until triggered). Dodging done too (`check_dodge`: soldiers, infantry, gunners, medics and iron maidens duck under blaster bolts, rockets and BFG balls). Navigation: monsters that lose the player follow Quake 2's player trail (last sighting, then up to 8 breadcrumbs, `p_trail.c`). ~~`trigger_monsterjump`~~ — done (`CheckMonsterTriggers`: horizontal velocity `speed` along the trigger's angle, `height` upward when on the ground, then ballistic flight; not in the demo maps, covered by a unit test); real pathfinding (BSP leaf portals or a walkable grid) only if the trail proves too weak on the full game's maps.
- ~~Swept player box~~ — done: `QuakeTrace` ports `CM_BoxTrace` over the map's brushes (plus movers in their own space and monster boxes) and the player runs Quake 2's `PM_StepSlideMove`, `PM_CatagorizePosition`, `PM_CheckDuck`, friction, water and ladder moves on it; movers carry riders and push the player (`SV_Push`), monsters don't walk into him. Blocked movers act like Quake 2 too (`SV_Push` keeps the pushed or the old position, else the pusher's `blocked`: doors and plats deal their `dmg` (2) and go back, crusher doors keep going, trains deal 100 unless BLOCK_STOPS). Still to do: monsters moving with the same traces.

### 3. Full game support (needs the retail PAK)
- **Medic revive**, **boss behaviour** (supertank, Makron, jorg) and the missing entities (`misc_viper`, `target_blaster`, `func_killbox`, `turret_*`). Test with a local `baseq2` in a nightly-style workflow that is skipped when the PAK isn't available.
- ~~Save projectiles and delayed events~~ — done (also fixed `trigger_relay` ignoring `delay` and delayed `target_explosion`s, so demo1's opening explosions now come in sequence).
- ~~Map compatibility report~~ — done: `castle-quake2 --map-report report.md` loads every map in the PAKs and lists load times, counts and the unsupported / partially supported entity classes (`QuakeMapReport`); the demo's is in [`map-report-demo.md`](map-report-demo.md) and CI keeps it free of unsupported classes. Run it with a retail `baseq2` to find what to implement next.

### 4. Editor and inspectability
- **Property editors** (under `{$ifdef CASTLE_DESIGN_MODE}`): a dropdown of maps in the PAK for `TQuakeMap.MapName`, a file picker for `PakUrl`, a *Reload map* verb (like `TImageGridEditor` in the custom_component sample). Needs the Lazarus-built editor to verify.
- **Selectable entities in the editor**: make preview markers / models one transform per entity with a read-only `EntityFields` (key/value pairs) property, so clicking a monster in the editor shows its spawnflags and targets.
- **Monster prefabs with live behavior**: optionally move from the single `monsters.castle-transform` to a `.castle-transform` per type that also carries the `TQuakeMonster` behavior, so sounds / scale / effects can be added per monster in the editor.
- **Named sounds by name in code**: replace literal paths (`'sound/items/pkup.wav'`) with `Sounds.PlayNamed('Items_pkup')` gradually, so the design is the single source of truth.

### 5. Performance and platforms
- **Measure on real GPUs**: log frame time and draw calls per map (CI only has Mesa software rendering at ~12 FPS); try `RegionSize` 512 vs 1024 for culling vs draw-call count.
- Merge mover scenes that never move (`func_wall`), cache `LineOfSight` results across monsters, shader-based light styles for big maps.
- ~~Mobile~~ — done: `QuakeTouch` on-screen controls (move stick, drag look, FIRE / JUMP / DUCK / USE / WPN / MENU, multi-touch), tap menus, Android APK built by CI in the CGE Docker image (debug-signed). Not yet tried on a real device; next: try it, tune button sizes and look speed, a release signing key, maybe iOS.

### Out of scope for now
- **Multiplayer** (deathmatch / coop): needs a client-server split of `TQuakeWorld` and networking; large effort, best as a separate project milestone after single player is complete.

## Milestones

### Phase 1 – Look
- [x] BSP v38 geometry, WAL textures, RGB lightmaps, translucent / flowing surfaces, animated textures
- [x] Skybox
- [x] MD2 models with interpolation and lightmap tint
- [x] Quake 2 HUD pics, crosshair, screen blends
- [x] Light styles: flickering, switchable lights, `target_lightramp`
- [x] Dynamic lights on world surfaces and models (lightmap texture shader effect)
- [x] Underwater screen tints
- [x] Water warp shader (`PLUG_texture_coord_shift` effect, like Quake 2's EmitWaterPolys)
- [x] Explosion model, soft particles, splashes, lasers, props (barrels, banners, ships, dish, corpses)
- [x] Gibs and barrel debris with gravity and bounce
- [x] Powerup shells on the view weapon (quad blue, invulnerability red), as offset MD2 shapes
- [x] SP2 sprites (BFG ball and explosion)
- [x] Shells on monsters: power armor (brain's power screen, absorbs damage) flashes green
- [x] Weapon viewport (no wall clipping)
- [x] PVS culling of world regions (visibility lump, `novis` to compare)
- [x] Areaportals (closed doors hide the areas behind them; kept in savegames)
- [x] Entity culling: movers, monsters, items, props, lasers hidden outside the PVS / connected areas

### Phase 2 – Play
- [x] All 10 weapons, items, armor rules, keys, powerups
- [x] Doors, rotating doors, plats, buttons, trains, rotating brushes, explosives
- [x] Target / trigger chains, counters, keys, secrets, goals, teleporters, level changes
- [x] Monster sight / chase / attack / pain / death
- [x] Pmove player physics: friction, acceleration, air control, steps, crouch, jump pads, falling damage
- [x] Swimming, drowning, lava / slime damage, underwater tints
- [x] Ladders (exact test against ladder brushes; they are detail brushes that don't split leafs)
- [x] Player-clip brushes as invisible walls (polygons built from the brush planes)
- [x] Box-shaped player collision (Quake 2's 32 × 32 × 56 box via `WorldBoxCollision`, ledge support from the box corners)
- [x] Monster steering around obstacles (±45° / ±90° detours) and ledge checks
- [x] `path_corner` patrols and `point_combat` (hold) combat points; player-clip doesn't block monsters
- [x] Attacks happen partway through the attack animation (wind-up; pain cancels the shot)
- [ ] Medic revive, bosses, real pathfinding (needs the full game data: no medic or bosses in the demo)
- [x] Hand grenades (cook, throw speed by hold time, explode in hand), chaingun spin-up

### Phase 3 – Flow
- [x] Help computer (F1) and intermission screens
- [x] Looping ambient sounds (`target_speaker`), `func_timer`
- [x] Savegames (JSON, quick save / load)
- [x] Cross-level triggers (`target_crosslevel_trigger` / `_target`, kept in savegames)
- [x] Levels of a unit remember their state when revisited through a changelevel

### Phase 4 – Editor & tooling
- [x] Views loaded from `.castle-user-interface` designs with published components
- [x] `TQuakeMap`, HUD, console and menu as registered editor components (`editor_units`)
- [x] Monsters, items and movers as `TCastleBehavior`s with named transforms (F8 inspector)
- [ ] Map dropdown / reload verb property editors
- [ ] Selectable entities with key/value inspection in the editor
- [x] Design-time skybox (`TQuakeMap.Background`) and entity markers (`PreviewMarkers`: player starts, paths, speakers, trigger volumes)
- [x] Monster types (`data/monsters.castle-transform`) and named sounds (`data/sounds.castle-component`) editable in the editor
- [x] CI autotests with screenshots (Linux, xvfb + Mesa)
- [x] Parser unit tests (`tests/`, in CI)
- [x] Screenshot comparison in CI (64x36 block averages against `tests/reference`)
- [x] WebAssembly build deployed to GitHub Pages

### Phase 5 – Polish & reach (done)
- [x] Options menu: sensitivity, invert, FOV, music volume, key bindings (`UserConfig`)
- [x] Skill selection (easy … nightmare)
- [x] Gamepad input (`Controllers`; virtual pad in autotests)
- [x] View and weapon bob, weapon lag, landing dip, damage kicks (items already rotate like `EF_ROTATE`; Quake 2 items don't bob)
- [x] Frame-accurate player weapons (Quake 2 `Weapon_Generic`)
- [x] Frame-accurate monster attacks for the demo monsters (`mframe_t` fire frames, bursts, refire loops)
- [x] Monster perception like Quake 2: ambush, trigger-spawned monsters, front cone, hearing through the PHS, group wake
- [x] Monster dodging (duck under blaster bolts, rockets, BFG balls)
- [x] Monster pursuit along the player trail (Quake 2 `p_trail.c`)
- [x] `trigger_monsterjump`
- [x] Blocked doors / plats hurt and reverse (Quake 2 `door_blocked`, `plat_blocked`)
- [x] Swept player box: box traces against BSP brushes, `PM_StepSlideMove`, movers carry / push the player
- [x] Savegames include projectiles and delayed events
- [x] Map compatibility report (`--map-report`, demo report in docs, checked in CI)
- [x] Android build with touch controls (APK from CI; untested on hardware)

### Phase 6 – Hardware, consistency, full game (next)
- [ ] Try Android touch, a gamepad and a real GPU; tune touch controls
- [x] Menu, console and HUD text sized for phone screens (*Interface Size* option, larger on touch screens; checked with 2400 × 1080 screenshots)
- [ ] Release signing key and launcher icon for Android
- [x] Monster movement on the BSP traces (`SV_movestep`, `M_CheckBottom`, Quake 2 monster boxes, `M_droptofloor`)
- [x] Hitscan, projectiles (grenades bounce off the hit plane), monster sight, lasers and the player trail on the BSP traces; barrels solid again
- [x] Movers push monsters, items and corpses (`SV_Push` for all entities; corpses caught in doors are gibbed)
- [x] `record` console command: write the player's inputs as an autotest script (`--demo @file` replays it; CI checks a replay)
- [x] Full-game entities testable on the demo: `spawn` console command; `misc_viper` (+ bomb, bigviper), `misc_blackhole`, `misc_easter*`, `target_blaster`, `target_earthquake` shake, `target_spawner`, `func_killbox`, `trigger_gravity`
- [ ] Attack tables for the full game's monsters, medic revive, bosses (retail PAK)
- [x] Tagged release v0.3.0 with Windows, Linux, Android and Web packages (notes from `docs/CHANGELOG.md`)
