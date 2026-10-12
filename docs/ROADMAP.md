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
| Player physics | Pmove (air control, water, ladders, crouch slide) | Pmove as `TQuakePlayerMovement` with the 32 × 32 × 56 player box | Swept box traces with plane clipping (`PM_StepSlideMove`) instead of overlap tests. |
| Weapons | 10 + hand grenades, frame-timed | 10 + hand grenades, chaingun spin-up, cooldown timers | Firing on the MD2 frames Quake 2 uses. |
| Monsters | Full AI (`ai_run`, dodge, ambush, medic revive, bosses), skill levels | Sight / chase / attack wind-up / pain / death, patrols, combat points, steering, 19 types tunable in the editor, skill 0–3 | Pathfinding, `ambush` spawnflag, dodging, medic revive, boss behaviour. |
| Props / effects | Barrels, banners, ships, lasers, splashes, explosion models | All of these used by the demo maps | Gib models with velocities, `misc_viper`, `target_blaster`, `trigger_monsterjump`, `func_killbox`. |
| Level flow | Units, cross-level triggers, help computer, intermission, savegames | All of these (JSON savegames) | Projectiles and pending delayed events are not saved. |
| Audio | 3D sounds, looping speakers / entity sounds, CD music | 3D sounds with Quake 2 attenuation, looping / triggered speakers, OGG tracks, named sounds editable in the editor | — |
| Input / options | Key bindings, mouse sensitivity, joystick, skill | Options menu (sensitivity, invert, FOV, volumes), key rebinding, skill selection, saved in `UserConfig` | Gamepad. |
| Multiplayer | Deathmatch / coop over UDP | Single player only | Out of scope for now (see below). |
| Tooling | Console, `+map`, demos | Console, autotest scripts and screenshot comparison in CI, parser unit tests, CGE editor components and designs, F8 inspector, WebAssembly build | Editor property editors, demo recording. |

## Done so far

- **Look**: lightmaps and light styles, dynamic lights, skybox, water warp, MD2 with shells, SP2 sprites, particles, gibs, weapon viewport.
- **Play**: all weapons and items, pmove with ladders / water / player box, doors / plats / trains / buttons, trigger chains, monster AI with patrols and combat points.
- **Flow**: help computer, intermission, savegames, cross-level triggers, units that remember state.
- **Performance**: PVS + areaportal culling of the world and of entities (`novis` to compare), batched particles.
- **Editor**: views from designs, `TQuakeMap` building levels in the editor with skybox and entity markers, behaviors with published state, monster types (`data/monsters.castle-transform`) and named sounds (`data/sounds.castle-component`).
- **Engineering**: CI on Windows / Linux / Web, autotests under Mesa, screenshot references, culling check (vis vs `novis`), 70 parser and design unit tests.

## Suggested improvements (prioritised)

### 1. Player-facing polish (highest impact, small)
- ~~Options menu~~ — done: mouse sensitivity and invert, field of view, sound and music volume, *Controls* page with key rebinding, saved in `UserConfig` (`QuakeSettings`).
- ~~Skill selection~~ — done: *Single Player* asks Easy / Medium / Hard / Nightmare; skill filters spawnflags, halves damage on easy, speeds up monster attacks from hard on, no pain flinches on nightmare; `skill` console command; kept in savegames.
- **Gamepad** through CGE's `Controllers`: move / look sticks, triggers to fire, mapped like Quake 2's joystick cvars; needed for the Android / console-like targets anyway.
- **Rotating, bobbing items** (`EF_ROTATE`) and weapon bob tied to pmove speed, so items read clearly from a distance.

### 2. Feel of combat
- **Frame-accurate attacks** for weapons and monsters: fire on the MD2 frame indices the Quake 2 game code uses (its `mframe_t` tables) instead of cooldown timers, so animation and damage line up.
- **Monster AI gaps**: `ambush` spawnflag (stay asleep until seen), dodging rockets / grenades (`monster_dodge`), `trigger_monsterjump`, and a short-range **navigation fallback** (a breadth-first search over BSP leaf portals or a coarse grid of walkable cells) when steering fails.
- **Swept player box** (`PM_StepSlideMove`): trace the 32 × 32 × 56 box against BSP brushes with plane clipping, removing the remaining snag cases on diagonal walls and stairs.

### 3. Full game support (needs the retail PAK)
- **Medic revive**, **boss behaviour** (supertank, Makron, jorg) and the missing entities (`misc_viper`, `target_blaster`, `func_killbox`, `turret_*`). Test with a local `baseq2` in a nightly-style workflow that is skipped when the PAK isn't available.
- **Save projectiles and delayed events**, so a quick save mid-fight restores exactly.
- A **map compatibility report**: autotest every map in a PAK (`maps` console command), log unknown classnames and load times, so missing entities are found systematically.

### 4. Editor and inspectability
- **Property editors** (under `{$ifdef CASTLE_DESIGN_MODE}`): a dropdown of maps in the PAK for `TQuakeMap.MapName`, a file picker for `PakUrl`, a *Reload map* verb (like `TImageGridEditor` in the custom_component sample). Needs the Lazarus-built editor to verify.
- **Selectable entities in the editor**: make preview markers / models one transform per entity with a read-only `EntityFields` (key/value pairs) property, so clicking a monster in the editor shows its spawnflags and targets.
- **Monster prefabs with live behavior**: optionally move from the single `monsters.castle-transform` to a `.castle-transform` per type that also carries the `TQuakeMonster` behavior, so sounds / scale / effects can be added per monster in the editor.
- **Named sounds by name in code**: replace literal paths (`'sound/items/pkup.wav'`) with `Sounds.PlayNamed('Items_pkup')` gradually, so the design is the single source of truth.

### 5. Performance and platforms
- **Measure on real GPUs**: log frame time and draw calls per map (CI only has Mesa software rendering at ~12 FPS); try `RegionSize` 512 vs 1024 for culling vs draw-call count.
- Merge mover scenes that never move (`func_wall`), cache `LineOfSight` results across monsters, shader-based light styles for big maps.
- **Mobile**: Android build with CGE touch navigation (two virtual sticks) and the gamepad support above.

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

### Phase 5 – Polish & reach (next)
- [x] Options menu: sensitivity, invert, FOV, music volume, key bindings (`UserConfig`)
- [x] Skill selection (easy … nightmare)
- [ ] Gamepad input (`Controllers`)
- [ ] Rotating / bobbing items, weapon bob
- [ ] Frame-accurate weapon and monster attacks
- [ ] Monster `ambush`, dodging, `trigger_monsterjump`, navigation fallback
- [ ] Swept player box (`PM_StepSlideMove`)
- [ ] Savegames include projectiles and delayed events
- [ ] Map compatibility report over a full PAK
- [ ] Android build with touch controls
