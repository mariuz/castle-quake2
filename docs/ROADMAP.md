# Castle Quake 2 Roadmap

Comparison with the original **Quake 2** (id Tech 2, `ref_gl` + `game` DLL) and what is left to do.

## Comparison

| Subsystem | Original Quake 2 | Castle Quake 2 (now) | Gap |
| :--- | :--- | :--- | :--- |
| World geometry | IBSP v38, PVS/areaportal culling | X3D batches per texture, CGE frustum culling | Use PVS / areas for culling on big maps. |
| Lighting | RGB lightmaps, 4 styles, dynamic lights | First lightmap style, `MODULATE2X`, LightPoint model tint | Light styles (flicker / switchable lights), dynamic lights on the world. |
| Sky | Skybox, `skyrotate`, `skyaxis` | Skybox via `TCastleBackground` | Sky rotation. |
| Liquids | Warped water/lava (`SURF_WARP`), contents | Static texture, blended when `TRANS33/66` | Warp shader, swimming, liquid contents, damage from lava/slime. |
| Models | MD2 with lerp, skins, `EF_*` effects | MD2 with lerp and skins | Shell effects (quad/invuln), glow, rotating powerup bob. |
| Sprites | SP2 (BFG, explosions) | Billboard particles instead | SP2 loader. |
| Player physics | Pmove (air control, water, ladders, crouch slide) | `TCastleWalkNavigation` (walk, jump, crouch, noclip) | Pmove port, `trigger_push` jump pads, ladders, falling damage. |
| Weapons | 10 + hand grenades | 10 weapons | Hand grenades, chaingun spin-up, weapon frame-accurate timing. |
| Monsters | Full AI (`ai_run`, dodge, ambush, medic revive, bosses) | Sight / chase / attack / pain / death, 19 definitions | Pathing around obstacles, ambush flag, dodging, per-monster attack frames, bosses. |
| Gibs | Gib models with physics | Hide + sound | Spawn gib models with velocities. |
| Level flow | Units, cross-level triggers, help computer, intermission | `target_changelevel` with spawn points, objectives in HUD | Help computer screen (F1), intermission, cross-level triggers, savegames. |
| Audio | 3D sounds, looping `target_speaker` / entity sounds, CD music | 3D one-shot sounds, OGG tracks | Looping ambient speakers, mover move loops. |
| Game code | `gamex86.dll` (C) | Native Object Pascal | — |

## Milestones

### Phase 1 – Look
- [x] BSP v38 geometry, WAL textures, RGB lightmaps, translucent / flowing surfaces, animated textures
- [x] Skybox
- [x] MD2 models with interpolation and lightmap tint
- [x] Quake 2 HUD pics, crosshair, screen blends
- [ ] Light styles and dynamic lights on world surfaces (shader multiplying per-style lightmap layers)
- [ ] Water warp shader and underwater tint
- [ ] SP2 sprites, powerup shells

### Phase 2 – Play
- [x] All 10 weapons, items, armor rules, keys, powerups
- [x] Doors, rotating doors, plats, buttons, trains, rotating brushes, explosives
- [x] Target / trigger chains, counters, keys, secrets, goals, teleporters, level changes
- [x] Monster sight / chase / attack / pain / death
- [ ] Pmove player physics (jump pads, ladders, swimming, falling damage)
- [ ] Monster navigation around obstacles, per-frame attack timing, medic revive
- [ ] Hand grenades, chaingun spin-up

### Phase 3 – Flow
- [ ] Help computer (F1) and intermission screens
- [ ] Savegames
- [ ] Looping ambient sounds
- [ ] WebAssembly build of the demo (the workflow is in place, untested)
