# Castle Quake 2 Roadmap

Comparison with the original **Quake 2** (id Tech 2, `ref_gl` + `game` DLL), what is left to do, and how Castle Game Engine (CGE) features can carry it.

## Comparison

| Subsystem | Original Quake 2 | Castle Quake 2 (now) | Gap |
| :--- | :--- | :--- | :--- |
| World geometry | IBSP v38, PVS / areaportal culling | X3D batches per texture, CGE frustum culling | PVS / area culling on big maps. |
| Lighting | RGB lightmaps, 4 styles, dynamic lights | First lightmap style, `MODULATE2X`, LightPoint model tint | Light styles (flicker / switchable lights), dynamic lights on the world. |
| Sky | Skybox, `skyrotate`, `skyaxis` | Skybox via `TCastleBackground` | Sky rotation. |
| Liquids | Warped water / lava (`SURF_WARP`), contents | Static texture, blended when `TRANS33/66` | Warp shader, swimming, liquid damage. |
| Models | MD2 with lerp, skins, `EF_*` effects | MD2 with lerp and skins | Powerup shells, glow, bobbing items. |
| Sprites | SP2 (BFG, explosions) | Billboard particles instead | SP2 loader. |
| Player physics | Pmove (air control, water, ladders, crouch slide) | `TCastleWalkNavigation` (walk, jump, crouch, noclip) | Pmove port, jump pads, ladders, falling damage. |
| Weapons | 10 + hand grenades | 10 weapons | Hand grenades, chaingun spin-up, frame-accurate timing. |
| Monsters | Full AI (`ai_run`, dodge, ambush, medic revive, bosses) | Sight / chase / attack / pain / death, 19 definitions | Pathing, ambush flag, dodging, attack frames, bosses. |
| Gibs | Gib models with physics | Hide + sound | Gib models with velocities. |
| Level flow | Units, cross-level triggers, help computer, intermission | `target_changelevel` with spawn points, objectives in HUD | Help computer (F1), intermission, cross-level state, savegames. |
| Audio | 3D sounds, looping speakers / entity sounds, CD music | 3D one-shot sounds, OGG tracks | Looping ambient sounds, mover loops. |
| Tooling | Console, `+map`, demos | Console, autotest scripts, CGE editor components, F8 inspector | Editor property editors, CI screenshots. |

## Suggested improvements (prioritised)

### 1. Feel of the game (highest impact)
- **Port Quake 2 `pmove`** as a custom `TCastleNavigation` descendant: friction, acceleration, air control, step-up / step-down, water and ladders, crouch, and `trigger_push` jump pads (base maps rely on them). Today `TCastleWalkNavigation` makes movement feel "floaty" and pads are ignored.
- **Per-frame weapon and monster timing** driven by MD2 frame indices (Quake 2 fires on specific animation frames), instead of cooldown timers.
- **Monster navigation**: wall-follow / step-around when `Move` is blocked, ledge checks so monsters don't walk off cliffs, `ambush` spawnflag, dodge from rockets.
- **Help computer (F1)** with `pics/help.pcx` and the current objectives, plus the intermission screen (`pics/inventory.pcx`) with kills / secrets / goals tallies. Rebind noclip from F1 to the console.

### 2. Look
- **Light styles**: store each face's 4 style lightmaps in separate atlas layers and blend them in a CGE shader effect (`TEffectNode` / `TEffectPartNode`) with per-style uniforms, updated at 10 Hz. Enables flickering and switchable lights (`light` with `targetname`).
- **Dynamic lights** (muzzle flash, rockets, BFG) on world surfaces: add a light-accumulation term in the same shader effect.
- **Water / lava warp** shader for `SURF_WARP` surfaces and an underwater `TCastleScreenEffect` tint + wobble.
- **Powerup shells** (quad blue, invulnerability yellow) as an extra MD2 shape with additive blending.
- **SP2 sprites** for BFG ball / explosions; **gib models** (`models/objects/gibs/*`) with simple physics.
- **Weapon in its own viewport** (a second transparent `TCastleViewport` sharing the camera) so the gun never clips into walls, and to allow a different FOV for it.

### 3. CGE editor / inspectability
- **Property editors** (under `{$ifdef CASTLE_DESIGN_MODE}`): a dropdown of maps found in the PAK for `TQuakeMap.MapName`, a file picker for `PakUrl`, and a component editor verb *Reload map* (like `TImageGridEditor` in the custom_component sample).
- **Skybox from the map at design time**: let `TQuakeMap` fill a referenced `TCastleBackground` (published `Background` property) so the editor shows the sky too; the game currently does it in code.
- **Entity gizmos**: show triggers, `path_corner`s, teleporters and spawn points as wireframe boxes / `TCastleImageTransform` icons when `PreviewEntities` is on, selectable in the editor hierarchy with their key/value pairs as a read-only property.
- **Prefab designs** (`.castle-transform`) per monster type with the `TQuakeMonster` behavior and tunables (speed, ranges, damage) as published read-write properties, instead of the Pascal `MonsterDefs` table, so balancing happens in the editor.
- **Named sounds** like the template's `GameSound` / `NamedSound`: a `data/sounds.castle-component` mapping logical names to PAK sound URLs, editable in the editor.

### 4. Engineering
- **CI autotests**: run the `--autotest` scripts on GitHub Actions (Linux + xvfb + Mesa) and upload screenshots as artifacts; fail on exceptions in the log.
- **Unit tests** for the parsers (BSP lumps, MD2 unwelding, PCX RLE, WAL) with small fixture files, using CGE's test framework (`castle-tester`).
- **Savegames**: published behavior state already exists; serialize world + behaviors with `ComponentSave` / `ComponentLoad`.
- **PVS culling**: decompress the visibility lump and toggle per-cluster shapes, important for the larger full-game maps.
- **Performance**: batch particles into one scene (currently one `TCastleScene` per particle); cache `LineOfSight` results across monsters.
- **Platforms**: verify the WebAssembly workflow end to end; Android / iOS with CGE's touch navigation; gamepad input via `Controllers`.

## Milestones

### Phase 1 – Look
- [x] BSP v38 geometry, WAL textures, RGB lightmaps, translucent / flowing surfaces, animated textures
- [x] Skybox
- [x] MD2 models with interpolation and lightmap tint
- [x] Quake 2 HUD pics, crosshair, screen blends
- [ ] Light styles and dynamic lights on world surfaces (shader effect)
- [ ] Water warp shader and underwater screen effect
- [ ] SP2 sprites, powerup shells, gibs
- [ ] Weapon viewport (no wall clipping)

### Phase 2 – Play
- [x] All 10 weapons, items, armor rules, keys, powerups
- [x] Doors, rotating doors, plats, buttons, trains, rotating brushes, explosives
- [x] Target / trigger chains, counters, keys, secrets, goals, teleporters, level changes
- [x] Monster sight / chase / attack / pain / death
- [ ] Pmove player physics (jump pads, ladders, swimming, falling damage)
- [ ] Monster navigation, per-frame attack timing, medic revive, bosses
- [ ] Hand grenades, chaingun spin-up

### Phase 3 – Flow
- [ ] Help computer (F1) and intermission screens
- [ ] Savegames
- [ ] Looping ambient sounds

### Phase 4 – Editor & tooling
- [x] Views loaded from `.castle-user-interface` designs with published components
- [x] `TQuakeMap`, HUD, console and menu as registered editor components (`editor_units`)
- [x] Monsters, items and movers as `TCastleBehavior`s with named transforms (F8 inspector)
- [ ] Map dropdown / reload verb property editors
- [ ] Design-time skybox and entity gizmos
- [ ] Monster prefabs (`.castle-transform`) and named sounds
- [ ] CI autotests with screenshots; parser unit tests
- [ ] WebAssembly build verified
