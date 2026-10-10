# Castle Quake 2: Architecture & Technical Design

How Quake 2 game data is parsed and played in the **Castle Game Engine (CGE)**, and which engine features each subsystem uses. The structure mirrors [castle-quake1](https://github.com/mariuz/castle-quake1); this document focuses on what is different for Quake 2.

---

## 1. Data flow

```
 quake2_demo.pak / baseq2/pak*.pak
              │
              ▼
        QuakePak (PACK reader, "quakepak:" protocol, MIME from extension)
     ┌────────┼──────────────────────────┬──────────────────────┐
     ▼        ▼                          ▼                      ▼
 QuakePalette  QuakeBsp (IBSP v38)    QuakeMd2 (IDP2 v8)     QuakeSound
 colormap.pcx  entities, planes,      unwelded meshes,       WAV via
 PCX + WAL     nodes, faces, texinfo, frame lerp, skins      TCastleSound /
 "quaketex:"   RGB lightmaps,                                TCastleSoundSource
     │         LightPoint()                 │
     │             │                        │
     └──────┬──────┴──────────┬─────────────┘
            ▼                 ▼
     QuakeGeometry       QuakeEntities (item / weapon / monster tables,
     X3D batches,        pickups, monster AI, projectiles, triggers)
     lightmap atlas,          │
     movers, sky clip         │
            └───────┬─────────┘
                    ▼
               QuakeWorld  (G_UseTargets, triggers, weapons, damage, armor,
                    │       level changes, teleporters)
                    ▼
               GameViewPlay (TCastleView)
               ├── TCastleViewport + TCastleWalkNavigation + TCastleBackground (skybox)
               ├── QuakeHud (pics/*.pcx via TDrawableImage)
               ├── QuakeParticles (one batched scene of camera-facing quads)
               └── QuakeConsole / QuakeMenu
```

---

## 2. Coordinates

Quake: X east, Y north, Z up. CGE: Y up.

- `CGE = (Quake.X, Quake.Z, -Quake.Y)` (`QuakeToCge`), determinant +1, so windings are preserved.
- A Quake yaw `a` (0 = east, 90 = north) is a CGE rotation of `a` around +Y; the facing vector is `(cos a, 0, -sin a)` (`YawToCgeDir`).
- Quake 2 player: origin 24 above the feet, eye 22 above the origin → eye height 46 (22 when crouched), 18-unit steps, 300 u/s run.

### Player movement

`TQuakePlayerMovement` (unit `QuakePlayer`) is a `TCastleBehavior` of the camera that ports the core of Quake 2's `pmove.c`: `PM_Friction` (stop speed 100, friction 6), `PM_Accelerate` (10 on the ground, 1 in the air), gravity 800, jump 270 (needs the key released in between), crouching. Collision uses CGE's world queries: `WorldMoveAllowed` with wall sliding for a sphere at the eye, plus `WorldHeight` below the new position to step up stairs (≤ 18 units), refuse higher obstacles, stick to the ground going down and land. Landing speed gives Quake 2's falling damage (`delta = v² × 0.0001`, damage `(delta − 30) / 2`). `trigger_push` sets the velocity to `movedir × speed × 10`. `TCastleWalkNavigation` keeps only mouse look (its movement inputs are cleared).

---

## 3. Textures and images (`QuakePalette`)

| Quake 2 asset | Format | Handling |
| --- | --- | --- |
| `pics/colormap.pcx` | 8-bit PCX | Its 256-color palette becomes the global palette. |
| `textures/*.wal` | 8-bit, mip levels, `animname`, flags | Mip 0 decoded with the global palette; size / `animname` / flags cached in `TQuakeWalInfo`. |
| Model skins, HUD pics, `env/*.pcx` | 8-bit RLE PCX with own palette | Decoded with their embedded palette; index 255 transparent for skins and pics. |
| `env/*.tga` | TGA | Loaded directly by CGE from `quakepak:` (MIME type derived from the extension). |

Decoded images are cached and served as uncompressed TGA streams through the `quaketex:` URL protocol, so CGE's texture cache, mipmapping and `TTexturePropertiesNode` filtering apply unchanged. Rows are flipped to CGE's bottom-to-top order, so UV `v = 1 - t / height`.

---

## 4. BSP and world geometry (`QuakeBsp`, `QuakeGeometry`)

- IBSP v38 header with 19 lumps. Planes, nodes, vertices, edges, surfedges, texinfo (76 bytes, with the texture name, flags, value and `nexttexinfo`), faces (20 bytes, 4 light styles), models (48 bytes) and the RGB lighting lump are read.
- Per face, the lightmap extents are computed like Quake 2's `CalcSurfaceExtents` (16-unit luxels), stored in `TQuakeFaceExtents`.
- Faces are batched by texture name + `SURF_WARP | SURF_TRANS33 | SURF_TRANS66 | SURF_FLOWING` into `TIndexedTriangleSetNode` shapes (`Ccw := False`).
- **Lightmaps**: each face's first-style RGB block is shelf-packed into a 2048² (world) or 512² (brush model) `TRGBImage` atlas with 1 texel padding. Batches use `TMultiTextureNode` with two `MODULATE` stages (WAL texture, lightmap) and an unlit material whose `EmissiveColor` is (2, 2, 2) for the overbright factor. (`MODULATE2X` would be the natural choice, but CGE generates `*= 2;` for it, which WebGL's GLSL ES rejects.) A 4×4 neutral (128) block serves faces without lightmaps. `-gamma` lifts dark lightmaps (default 1.2).
- **Player clip**: brushes with `CONTENTS_PLAYERCLIP` (and not solid) have no faces; their polygons are rebuilt from the brush planes (a huge quad on each plane clipped by the others) into an invisible, non-pickable `PlayerClip` scene, so they block walking but not shots.
- **Ladders**: `TQuakeBsp.PointInLadder` tests points against the ladder brushes' planes. Leaf contents can't be used: ladders are detail brushes, which don't split leafs.
- **Sky**: `SURF_SKY` faces go to a separate invisible (`Visible := False`) but colliding scene, so the player can't leave the map while the skybox (`TCastleBackground`, built from `worldspawn.sky`) shows through.
- **Translucent / warp / flowing**: `SURF_TRANS33/66` become blended with 0.67 / 0.34 transparency; `SURF_FLOWING` gets a `TTextureTransformNode` scrolled like Quake 2 GL (`-64 * frac(t/40)`).
- **Animated textures** follow WAL `animname` chains and are switched at 2 frames/second by changing `TImageTextureNode` URLs.
- **Light styles**: a face stores up to 4 style indices and one RGB lightmap block per style. Faces whose styles are all 0 use the static atlas. Others go into a separate dynamic atlas (1024² for the world, 256² for brush models) with their own batches; `TQuakeDynamicLightmap.Compose` sums `block[i] * StyleValue(style[i])` per texel, applies the gamma and calls `FdImage.Changed` to re-upload. `TQuakeLighting` evaluates Quake 2's style strings (`'a'` = 0, `'m'` = 1, `'z'` ≈ 2) at 10 Hz, switchable lights (styles 32+) and `target_lightramp` ramps, and increments `Version` only when a value changes, so static frames cost nothing.

### Movers

Brush entities (`model "*N"`, classname `func_*`) are separate `TCastleScene`s in `TCastleTransform`s (`TQuakeMover`). Entities with an origin brush store vertices relative to `origin`, so the transform starts at the entity origin.

| Classname | Behaviour |
| --- | --- |
| `func_door`, `func_door_secret`, `func_water` | Slides along `angle` (-1 up, -2 down) by size − `lip`; `wait` (−1 = toggle), `DOOR_START_OPEN`. Doors without `targetname`/`health` open when the player enters the box expanded by 60 units. |
| `func_door_rotating` | Rotates `distance` degrees around Z / X / Y axis (spawnflags). |
| `func_plat` | Built at the top, starts at the bottom, rises when stood on, waits 3 s. |
| `func_button` | Pushed by touch, `E`, or shooting (`health`); fires its targets. |
| `func_rotating` | Spins at `speed` deg/s; toggled when targeted. |
| `func_train` | Moves through the `path_corner` chain (`corner.origin − model.mins`), honours `wait` and `pathtarget`. |
| `func_wall`, `func_object` | Static; toggled visible when targeted. |
| `func_explosive` | Shootable (default 100 health when untargeted), explodes, chain-reacts through splash damage. |

---

## 4b. Sound

`target_speaker`s become `TQuakeSpeaker` behaviors next to a `TCastleSoundSource`: looped speakers set `Source.Sound` (always looping) and toggle `SoundPlaying` when used; one-shot speakers call `Source.Play`. Quake 2's attenuation (full volume up to 80 units, then `0.0005 × attenuation` per unit) maps onto `SoundEngine.DistanceModel := dmLinear` with `ReferenceDistance = 80` and `MaxDistance = 80 + 1 / (0.0005 × attenuation)`; `TCastleSound` instances are cached per path and attenuation.

## 5. Models (`QuakeMd2`)

- MD2 indexes positions and texture coordinates separately; triangle corners are "unwelded" into unique (xyz, st) pairs so X3D can use one index list.
- Every frame is decompressed into a `TVector3List` in CGE coordinates. Animations are grouped by frame name (`run3` → `run`, `attak105` → `attak1`).
- `TQuakeMd2Instance` owns a scene, plays an animation by name with fallbacks (`'attak,attack,fire,...'`), and linearly interpolates between frames by rewriting the `TCoordinateNode` only when the frame / blend changes.
- Lighting: models use an unlit material whose `EmissiveColor` is the lightmap color sampled under the model with `TQuakeBsp.LightPoint` (Quake 2's `RecursiveLightPoint` through the BSP nodes), ×2 overbright, plus muzzle flashes.

---

## 6. Game logic (`QuakeWorld`, `QuakeEntities`)

- **Tables** (`ItemDefs`, `WeaponDefs`, `MonsterDefs`) map Quake 2 classnames to models, icons, sounds and numbers, so adding an item or monster is a table row.
- **Targets**: `UseTargets(targetname)` implements `G_UseTargets` for movers, `trigger_relay`, `trigger_counter`, `trigger_key`, `target_changelevel` (`map$spawn`), `target_secret`, `target_goal`, `target_help`, `target_speaker`, `target_explosion`, monsters (wake up) and `TRIGGERED` triggers (enable); `delay` is queued.
- **Triggers** use the brush model bounds; `misc_teleporter` uses a box around its origin and moves the camera to `misc_teleporter_dest`.
- **Weapons**: hitscan pellets with Quake 2 spreads (`SpreadDir`, units at 8192), resolved with `TCastleAbstractRootTransform.WorldRayCast`; the leaf transform hit is mapped back to a monster (`OwnsTransform`) or a shootable mover. The railgun pierces. Projectiles step with a ray cast per frame; grenades bounce and explode on a fuse. Held-fire weapons use `FFireHeld` (set by every `FireWeapon` call, checked and cleared in `UpdateHeldFire`) to detect the release: the chaingun spins down, a cooked hand grenade (slot 11, `WeaponSlots`) is thrown with the remaining fuse.
- **Props** (`TQuakeProp`): `misc_explobox` (10 health, `dmg`+40 radius explosion, chain reactions), `misc_banner` (looping animation), `misc_deadsoldier` (pose from spawnflags), `misc_satellite_dish` (animates when used), `misc_strogg_ship` (hidden until used, then flies its `path_corner`s), `misc_gib_head`.
- **Timers and effects**: `func_timer` (`wait` ± `random`, START_ON, toggled by use), `target_splash` (particle colours by `sounds`), `target_laser` (`TCastleBox` beam stretched to the first wall hit, damages the player in it, toggled by use).
- **Help computer / intermission**: `target_help` fills the primary / secondary objectives; on `target_changelevel` the view moves the camera to `info_player_intermission`, freezes the world and shows the help-computer layout as a mission summary until a key press.
- **Damage**: armor absorbs `protection × damage` (jacket 0.3, combat 0.6, body 0.8), quad damage ×4, invulnerability; death restarts the level.
- **Monsters**: idle → sight (throttled `LineOfSight`) → chase (`TCastleTransform.Move` with `CollisionSphereRadius`, floor via `TCastleTransform.Height`) → attack (callback into the world: melee, hitscan, pellets, rail, blaster bolt, rocket, grenade) → pain → death / gib. Dead monsters fire their `target`.

---

## 6b. Savegames

`TQuakeWorld.SaveState` / `LoadState` write and read a `fpjson` object: player stats and inventory, then arrays per entity list (monsters, pickups, movers, props, triggers, lasers, speakers) in spawn order, plus `func_timer` / `trigger_counter` state keyed by BSP entity index and light styles 32–62. Loading reloads the map fresh and applies the state on top (`TQuakeMonster.RestoreState`, `TQuakeMover.ApplyPose`). The view adds the camera and stores the file with `UrlSaveStream('castle-config:/saves/<name>.json')`.

## 7. Castle Game Engine editor integration

| CGE convention (from templates / samples) | How Castle Quake 2 follows it |
| --- | --- |
| Views with `DesignUrl` and published component fields (`3d_fps_game` template) | `TViewPlay` / `TViewMenu` + `data/gameview*.castle-user-interface`. Viewport, camera, navigation, background, HUD, console, menu are designed. |
| `{$region 'Castle View Creation'}` / `'Castle Initialization Uses'` in `GameInitialize` | Present, so the editor can add new views automatically. |
| Custom components + `editor_units` (`examples/advanced_editor/custom_component`) | `TQuakeMap` (`TCastleTransform`), `TQuakeHud`, `TQuakeConsole`, `TQuakeMenu`, registered with `RegisterSerializableComponent`, basic properties grouped with `PropertySections`. |
| Game logic as `TCastleBehavior` (`GameEnemy` in the template) | `TQuakeMonster`, `TQuakePickup`, `TQuakeMover`, with read-only published state for the inspector. |
| Graceful design-time loading | `TQuakeMap` adds its PAK, palette and URL protocols itself (`EnsureData`), logs a warning instead of failing when a map is missing, and rebuilds when `MapName` / `PakUrl` change. |

## 8. Automated testing

`--autotest <map> <prefix> --demo "<script>"` loads a map, runs the script (see README) and exits after a final screenshot. Screenshots log the FPS and camera position, `V` logs every mover's state, and `N:` / `I:` / `D:` place the camera on a floor near a monster / item / mover, which makes visual regression checks of AI, pickups and movers possible without a human player.
