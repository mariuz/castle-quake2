# Castle Quake 2 Roadmap

Comparison with the original **Quake 2** (id Tech 2, `ref_gl` + `game` DLL), what is left to do, and how Castle Game Engine (CGE) features can carry it.

## Comparison

| Subsystem | Original Quake 2 | Castle Quake 2 (now) | Gap |
| :--- | :--- | :--- | :--- |
| World geometry | IBSP v38, PVS / areaportal culling | X3D batches per texture, CGE frustum culling | PVS / area culling on big maps. |
| Lighting | RGB lightmaps, 4 styles, dynamic lights | All 4 styles (animated, switchable, ramps), 2x overbright, LightPoint model tint | Dynamic lights on the world; light styles on model tint. |
| Sky | Skybox, `skyrotate`, `skyaxis` | Skybox via `TCastleBackground` | Sky rotation. |
| Liquids | Warped water / lava (`SURF_WARP`), contents | Non-solid liquid surfaces, point contents from BSP leafs, swimming, drowning, lava / slime damage, underwater tints | Warp shader. |
| Models | MD2 with lerp, skins, `EF_*` effects | MD2 with lerp and skins | Powerup shells, glow, bobbing items. |
| Sprites | SP2 (BFG, explosions) | SP2 loader, BFG ball / explosion sprites | Other sprite users (bubbles, flashes). |
| Player physics | Pmove (air control, water, ladders, crouch slide) | Pmove essentials as `TQuakePlayerMovement` (friction, accel, air control, steps, crouch, jump pads, falling damage) | Exact box (not sphere) collision. |
| Weapons | 10 + hand grenades | 10 weapons | Hand grenades, chaingun spin-up, frame-accurate timing. |
| Monsters | Full AI (`ai_run`, dodge, ambush, medic revive, bosses) | Sight / chase / attack / pain / death, 19 definitions | Pathing, ambush flag, dodging, attack frames, bosses. |
| Props / effects | Barrels, banners, ships, lasers, splashes, explosion models | All of these used by the demo maps | Gib models with velocities, `misc_viper`, `target_blaster`. |
| Level flow | Units, cross-level triggers, help computer, intermission, savegames | Changelevel with spawn points, cross-level triggers, help computer (F1), intermission, savegames | — |
| Audio | 3D sounds, looping speakers / entity sounds, CD music | 3D sounds with Quake 2 attenuation, looping / triggered speakers, OGG tracks | Monster idle / search sounds. |
| Tooling | Console, `+map`, demos | Console, autotest scripts in CI (Linux, xvfb + Mesa), CGE editor components, F8 inspector | Editor property editors, screenshot diffing. |

## Suggested improvements (prioritised)

### 1. Feel of the game (highest impact)
- ~~Port Quake 2 `pmove`~~ — essentials done (`TQuakePlayerMovement`); still missing: water, ladders, and colliding with a box instead of the eye sphere + ground height test.
- **Per-frame weapon and monster timing** driven by MD2 frame indices (Quake 2 fires on specific animation frames), instead of cooldown timers.
- **Monster navigation**: wall-follow / step-around when `Move` is blocked, ledge checks so monsters don't walk off cliffs, `ambush` spawnflag, dodge from rockets.
- ~~Help computer (F1) and intermission~~ — done.

### 2. Look
- ~~Light styles~~ — done on the CPU with a separate dynamic atlas; a shader version would avoid the re-uploads if very large maps need it.
- **Dynamic lights** (muzzle flash, rockets, BFG) on world surfaces: add a light-accumulation term in the same shader effect.
- ~~Water warp~~ — done; an underwater wobble `TCastleScreenEffect` would complete it.
- **Powerup shells** (quad blue, invulnerability yellow) as an extra MD2 shape with additive blending.
- ~~SP2 sprites, gibs~~ — done.
- ~~Weapon in its own viewport~~ — done (`WeaponViewport` in the design).

### 3. CGE editor / inspectability
- **Property editors** (under `{$ifdef CASTLE_DESIGN_MODE}`): a dropdown of maps found in the PAK for `TQuakeMap.MapName`, a file picker for `PakUrl`, and a component editor verb *Reload map* (like `TImageGridEditor` in the custom_component sample).
- **Skybox from the map at design time**: let `TQuakeMap` fill a referenced `TCastleBackground` (published `Background` property) so the editor shows the sky too; the game currently does it in code.
- **Entity gizmos**: show triggers, `path_corner`s, teleporters and spawn points as wireframe boxes / `TCastleImageTransform` icons when `PreviewEntities` is on, selectable in the editor hierarchy with their key/value pairs as a read-only property.
- **Prefab designs** (`.castle-transform`) per monster type with the `TQuakeMonster` behavior and tunables (speed, ranges, damage) as published read-write properties, instead of the Pascal `MonsterDefs` table, so balancing happens in the editor.
- **Named sounds** like the template's `GameSound` / `NamedSound`: a `data/sounds.castle-component` mapping logical names to PAK sound URLs, editable in the editor.

### 4. Engineering
- ~~CI autotests~~ — done (`autotest` job); next: compare screenshots against references.
- ~~Unit tests for the parsers~~ — done (`tests/`, against the demo PAK).
- ~~Savegames~~ — done as JSON (entities matched by spawn order); projectiles and pending delayed events are not saved.
- **PVS culling**: decompress the visibility lump and toggle per-cluster shapes, important for the larger full-game maps.
- **Performance**: ~~batch particles~~ (done: one scene, camera-facing quads rebuilt per frame); cache `LineOfSight` results across monsters; merge mover scenes that never move (`func_wall`).
- **Platforms**: verify the WebAssembly workflow end to end; Android / iOS with CGE's touch navigation; gamepad input via `Controllers`.

## Milestones

### Phase 1 – Look
- [x] BSP v38 geometry, WAL textures, RGB lightmaps, translucent / flowing surfaces, animated textures
- [x] Skybox
- [x] MD2 models with interpolation and lightmap tint
- [x] Quake 2 HUD pics, crosshair, screen blends
- [x] Light styles: flickering, switchable lights, `target_lightramp`
- [ ] Dynamic lights on world surfaces (shader effect)
- [x] Underwater screen tints
- [x] Water warp shader (`PLUG_texture_coord_shift` effect, like Quake 2's EmitWaterPolys)
- [x] Explosion model, soft particles, splashes, lasers, props (barrels, banners, ships, dish, corpses)
- [x] Gibs and barrel debris with gravity and bounce
- [x] Powerup "shells" on the view weapon (quad blue, invulnerability gold)
- [x] SP2 sprites (BFG ball and explosion)
- [ ] Shells on monsters / third-person models
- [x] Weapon viewport (no wall clipping)

### Phase 2 – Play
- [x] All 10 weapons, items, armor rules, keys, powerups
- [x] Doors, rotating doors, plats, buttons, trains, rotating brushes, explosives
- [x] Target / trigger chains, counters, keys, secrets, goals, teleporters, level changes
- [x] Monster sight / chase / attack / pain / death
- [x] Pmove player physics: friction, acceleration, air control, steps, crouch, jump pads, falling damage
- [x] Swimming, drowning, lava / slime damage, underwater tints
- [x] Ladders (exact test against ladder brushes; they are detail brushes that don't split leafs)
- [x] Player-clip brushes as invisible walls (polygons built from the brush planes)
- [ ] Box-shaped player collision
- [x] Monster steering around obstacles (±45° / ±90° detours) and ledge checks
- [x] Attacks happen partway through the attack animation (wind-up; pain cancels the shot)
- [ ] Medic revive, bosses, real pathfinding
- [ ] Hand grenades, chaingun spin-up

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
- [ ] Design-time skybox and entity gizmos
- [ ] Monster prefabs (`.castle-transform`) and named sounds
- [x] CI autotests with screenshots (Linux, xvfb + Mesa)
- [x] Parser unit tests (`tests/`, in CI)
- [ ] Screenshot diffing
- [x] WebAssembly build deployed to GitHub Pages
