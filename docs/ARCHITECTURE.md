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
               ├── QuakeParticles (TBillboardNode quads)
               └── QuakeConsole / QuakeMenu
```

---

## 2. Coordinates

Quake: X east, Y north, Z up. CGE: Y up.

- `CGE = (Quake.X, Quake.Z, -Quake.Y)` (`QuakeToCge`), determinant +1, so windings are preserved.
- A Quake yaw `a` (0 = east, 90 = north) is a CGE rotation of `a` around +Y; the facing vector is `(cos a, 0, -sin a)` (`YawToCgeDir`).
- Quake 2 player: origin 24 above the feet, eye 22 above the origin → `PreferredHeight = 46`, `ClimbHeight = 18`, `MoveSpeed = 300`.

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
- **Lightmaps**: each face's first-style RGB block is shelf-packed into a 2048² (world) or 512² (brush model) `TRGBImage` atlas with 1 texel padding. Batches use `TMultiTextureNode` with modes `MODULATE` (WAL texture) and `MODULATE2X` (lightmap), with an unlit material. A 4×4 neutral (128) block serves faces without lightmaps. `-gamma` lifts dark lightmaps (default 1.2).
- **Sky**: `SURF_SKY` faces go to a separate invisible (`Visible := False`) but colliding scene, so the player can't leave the map while the skybox (`TCastleBackground`, built from `worldspawn.sky`) shows through.
- **Translucent / warp / flowing**: `SURF_TRANS33/66` become blended with 0.67 / 0.34 transparency; `SURF_FLOWING` gets a `TTextureTransformNode` scrolled like Quake 2 GL (`-64 * frac(t/40)`).
- **Animated textures** follow WAL `animname` chains and are switched at 2 frames/second by changing `TImageTextureNode` URLs.

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
- **Weapons**: hitscan pellets with Quake 2 spreads (`SpreadDir`, units at 8192), resolved with `TCastleAbstractRootTransform.WorldRayCast`; the leaf transform hit is mapped back to a monster (`OwnsTransform`) or a shootable mover. The railgun pierces. Projectiles step with a ray cast per frame; grenades bounce and explode on a fuse.
- **Damage**: armor absorbs `protection × damage` (jacket 0.3, combat 0.6, body 0.8), quad damage ×4, invulnerability; death restarts the level.
- **Monsters**: idle → sight (throttled `LineOfSight`) → chase (`TCastleTransform.Move` with `CollisionSphereRadius`, floor via `TCastleTransform.Height`) → attack (callback into the world: melee, hitscan, pellets, rail, blaster bolt, rocket, grenade) → pain → death / gib. Dead monsters fire their `target`.

---

## 7. Automated testing

`--autotest <map> <prefix> --demo "<script>"` loads a map, runs the script (see README) and exits after a final screenshot. Screenshots log the FPS and camera position, `V` logs every mover's state, and `N:` / `I:` / `D:` place the camera on a floor near a monster / item / mover, which makes visual regression checks of AI, pickups and movers possible without a human player.
