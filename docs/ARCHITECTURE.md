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

`TQuakePlayerMovement` (unit `QuakePlayer`) is a `TCastleBehavior` of the camera that ports the core of Quake 2's `pmove.c`: `PM_Friction` (stop speed 100, friction 6), `PM_Accelerate` (10 on the ground, 1 in the air), gravity 800, jump 270 (needs the key released in between), crouching. Collision uses CGE's world queries with Quake 2's player box (32 × 32 × 56, ducked 32; `BoxCollision`, default on): a horizontal move is allowed when `WorldBoxCollision` finds nothing in the box at the new place with its bottom raised by the step size (so it passes over stairs), sliding along the X / Z axes when blocked; ceilings and standing up check a thin box above the head. `WorldHeight` below the centre (and below the box corners when the centre has no ground within a step, so you stand on ledge edges) steps up stairs (≤ 18 units), refuses higher obstacles, sticks to the ground going down and lands. `BoxCollision = false` uses the older eye sphere (`WorldMoveAllowed` with wall sliding). Landing speed gives Quake 2's falling damage (`delta = v² × 0.0001`, damage `(delta − 30) / 2`). `trigger_push` sets the velocity to `movedir × speed × 10`. `TCastleWalkNavigation` keeps only mouse look (its movement inputs are cleared).

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
- **PVS culling** (Quake 2 `R_MarkLeaves`): `TQuakeBsp` keeps the visibility lump, leaf faces and leaf clusters; `PointCluster` finds the camera's cluster and `ClusterPVS` run-length decompresses its row (`CM_DecompressVis`). `TQuakeGeometry.BuildVisRegions` puts each world face into a 1024-unit grid cell (a `TQuakeVisRegion`, which also splits the texture batches) and ORs in the clusters of all leafs listing its faces. `UpdateVisibility` (called by `TViewPlay.Update` with the camera position) recomputes only when the cluster changes and sets `Shape.Visible` (rendering only: hidden shapes still collide). Regions are also split by area (the area of the first leaf listing a face) and record the areas of all leafs listing their faces: `TQuakeBsp.FloodAreas` (`CM_FloodArea`) finds the areas connected to the camera's area through open portals, and a region must hit both the PVS and those areas. A `TQuakeAreaPortal` (`func_areaportal`, portal number in `style`) is open while a door targeting it is not closed (Quake 2 `door_use_areaportals`), otherwise it toggles when used (`ToggleAreaPortal`, saved as `areaPortals`). Cluster -1 (outside the map, noclip in a wall) or `NoVis` shows everything. Entities are culled the same way, like Quake 2's `SV_BuildClientFrame`: every frame `TQuakeWorld.CullEntities` asks `TQuakeGeometry.BoxVisible` for the bounding box of each mover (`WorldBox`), monster, item, prop and laser; `TQuakeBsp.BoxLeafs` (`CM_BoxLeafnums`) lists the leafs the box touches (more than 64: drawn) and the entity is shown when one of them is in a potentially visible cluster and a connected area. Hidden transforms get `Visible := False`, so they still collide and are hit by ray casts. Gibs, debris, projectiles and particles are not culled. Autotest screenshots log the cluster and the visible / total regions.
- **Player clip**: brushes with `CONTENTS_PLAYERCLIP` (and not solid) have no faces; their polygons are rebuilt from the brush planes (a huge quad on each plane clipped by the others) into an invisible, non-pickable `PlayerClip` scene, so they block walking but not shots.
- **Ladders**: `TQuakeBsp.PointInLadder` tests points against the ladder brushes' planes. Leaf contents can't be used: ladders are detail brushes, which don't split leafs.
- **Sky**: `SURF_SKY` faces go to a separate invisible (`Visible := False`) but colliding scene, so the player can't leave the map while the skybox (`TCastleBackground`, built from `worldspawn.sky` by `TQuakeMap.ApplySky` into the map's published `Background`, so the editor shows it too) shows through.
- **Translucent / warp / flowing**: `SURF_TRANS33/66` become blended with 0.67 / 0.34 transparency; `SURF_FLOWING` gets a `TTextureTransformNode` scrolled like Quake 2 GL (`-64 * frac(t/40)`).
- **Animated textures** follow WAL `animname` chains and are switched at 2 frames/second by changing `TImageTextureNode` URLs.
- **Light styles**: a face stores up to 4 style indices and one RGB lightmap block per style. Faces whose styles are all 0 use the static atlas. Others go into a separate dynamic atlas (1024² for the world, 256² for brush models) with their own batches; `TQuakeDynamicLightmap.Compose` sums `block[i] * StyleValue(style[i])` per texel, applies the gamma and calls `FdImage.Changed` to re-upload. `TQuakeLighting` evaluates Quake 2's style strings (`'a'` = 0, `'m'` = 1, `'z'` ≈ 2) at 10 Hz, switchable lights (styles 32+) and `target_lightramp` ramps, and increments `Version` only when a value changes, so static frames cost nothing.
- **Dynamic lights** (Quake 2 `dlight_t`): `TQuakeLighting.AddLight` keeps timed lights (muzzle flashes 0.1 s, explosions 0.5 s, shrinking) and single-frame lights (rockets, blaster bolts, BFG balls, re-added every frame and dropped by `EndFrame`). Every frame `TQuakeWorld.SetSurfaceLights` sends the 4 nearest (`NearestLights`) to `TQuakeGeometry.SetSurfaceLights`. Each brush model's lightmap textures carry an `Effect` (one per model, since X3D nodes can't be shared by scenes) whose vertex part passes the object-space position (= world space) and whose `PLUG_texture_color` adds `color * (radius - distance) / 256` to the lightmap sample before it modulates the wall texture, like `R_AddDynamicLights`. `SampleLight` adds the same term to model tints.

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

`TQuakeSounds` (unit `QuakeSound`) follows Quake 2's `snd_dma.c`:

- **Attenuation**: full volume up to `SOUND_FULLVOLUME` (80 units), then `1 - distance × dist_mult` with `dist_mult = 0.0005 × attenuation` (`0.001 × 3` for `ATTN_STATIC`). That is OpenAL's clamped linear model (`SoundEngine.DistanceModel := dmLinear`) with `ReferenceDistance = 80` and `MaxDistance = 80 + 1 / dist_mult`; `TCastleSound`s are cached per path and `dist_mult`. `ATTN_NONE` (0) plays as a 2D sound.
- **Channels** (`TQuakeSoundChannel`: `chAuto`, `chWeapon`, `chVoice`, `chItem`, `chBody`, Quake 2's `CHAN_*`): a sound on the same owner and channel stops the previous one (`chAuto` never does). The player's 2D sounds use owner nil: weapon fire on `chWeapon` (rapid fire doesn't pile up), pain / death / no-ammo / falls on `chVoice`, pickups and quad on `chItem`, water on `chBody`. Monsters: sight / pain / death / idle / search on `chVoice`, attacks on `chWeapon`, gibs on `chBody`. Movers: start / end sounds on `chVoice`.
- **Point sounds**: `PlayAt(path, transform)` and `PlayAtPoint(path, position)` play from a throwaway emitter with `TCastlePlayingSoundSource.Follow := False`, so the sound keeps playing where it started after the transform is hidden or freed (gibs, exploding projectiles, level changes). Explosions (`rocklx1a`, `bfg__x1b`), blaster impacts and `target_splash` sparks are heard from where they happen; movers play from `Center` (their transform origin can be far from the brush).
- **Loops** (Quake 2 `S_AddLoopSounds`): looping `target_speaker`s and moving doors / plats don't own sources. Every frame `TQuakeWorld.UpdateLoopSounds` passes the active emitters in the PVS / connected areas (`TQuakeGeometry.BoxVisible`) to `Sounds.BeginLoops` / `AddLoop` / `EndLoops`; each distinct sound has one voice (`TQuakeLoopVoice`, a transform with a looping `TCastleSoundSource` in `Sounds.WorldParent`) placed at its loudest emitter, with `SOUND_LOOPATTENUATE` (0.003: silent beyond ~413 units). demo1 has 84 speakers but plays 1–3 loops at a time.
- **Sources**: `SoundEngine.MaxAllocatedSources := 32` (Quake 2 `MAX_CHANNELS`). Before the loop mixer, every looping speaker held a source, so the default 16 were exhausted and one-shot sounds (explosions, pain) were dropped.

Audio can be checked headless with OpenAL Soft's wave backend (`ALSOFT_CONF` with `drivers = wave`, `sample-type = int16`, `[wave] file = ...`): it writes the final mix to a WAV file.

## 5. Models (`QuakeMd2`)

- MD2 indexes positions and texture coordinates separately; triangle corners are "unwelded" into unique (xyz, st) pairs so X3D can use one index list.
- Every frame is decompressed into a `TVector3List` in CGE coordinates. Animations are grouped by frame name (`run3` → `run`, `attak105` → `attak1`).
- `TQuakeMd2Instance` owns a scene, plays an animation by name with fallbacks (`'attak,attack,fire,...'`), and linearly interpolates between frames by rewriting the `TCoordinateNode` only when the frame / blend changes. `SetShell(Color)` adds (lazily, in a `Switch`) a second shape: the same triangles with vertices moved 4 units along smoothed normals (`TQuakeMd2.OffsetAlongNormals`, summed per original MD2 vertex so UV seams don't crack), unlit, alpha 0.3, back faces culled. The view weapon uses it for quad (blue) / invulnerability (red); monsters for power armor (`AbsorbPowerArmor`, Quake 2 `CheckPowerArmor`: screen absorbs a third of the damage at 1 cell per point, shield two thirds at 2 points per cell; green for 0.2 s).
- Lighting: models use an unlit material whose `EmissiveColor` is the lightmap color sampled under the model with `TQuakeBsp.LightPoint` (Quake 2's `RecursiveLightPoint` through the BSP nodes), ×2 overbright, plus the dynamic lights.

---

## 6. Game logic (`QuakeWorld`, `QuakeEntities`)

- **Tables** (`ItemDefs`, `WeaponDefs`, `MonsterDefs`) map Quake 2 classnames to models, icons, sounds and numbers, so adding an item or monster is a table row. Monsters come from `DefaultMonsterDefs`, then `LoadMonsterTypes` (unit `QuakeMonsterTypes`) applies `data/monsters.castle-transform` over `MonsterDefs` by `MonsterClass` (replacing or adding entries) before any monster exists, since `FindMonsterDef` returns pointers into the array.
- **Targets**: `UseTargets(targetname)` implements `G_UseTargets` for movers, `trigger_relay`, `trigger_counter`, `trigger_key`, `target_changelevel` (`map$spawn`), `target_secret`, `target_goal`, `target_help`, `target_speaker`, `target_explosion`, monsters (wake up) and `TRIGGERED` triggers (enable); `delay` is queued.
- **Triggers** use the brush model bounds; `misc_teleporter` uses a box around its origin and moves the camera to `misc_teleporter_dest`.
- **Weapons**: hitscan pellets with Quake 2 spreads (`SpreadDir`, units at 8192), resolved with `TCastleAbstractRootTransform.WorldRayCast`; the leaf transform hit is mapped back to a monster (`OwnsTransform`) or a shootable mover. The railgun pierces. Projectiles step with a ray cast per frame; grenades bounce and explode on a fuse. - **Gun frames** (unit `QuakeWeaponFrames`, Quake 2 `p_weapon.c`): `TQuakeGun` is `Weapon_Generic` / `Weapon_Grenade` as plain code, stepped at 10 Hz over the view model's frames. `GunFrameDef(Slot)` holds the Quake 2 frame ranges (activate / fire / idle / put away, e.g. blaster 4, 8, 52, 55) with their pause and fire frames; states `gsActivating`, `gsReady`, `gsFiring`, `gsDropping`. A weapon fires when the gun reaches a fire frame (`geFire` → `TQuakeWorld.FireGun`) and refires once the firing frames have played (blaster 0.5 s, shotgun 1.2 s); switching puts the old weapon away and raises the new one (`geChangeWeapon` makes `PendingSlot` current); the shotgun's frame 9 only ejects, the machinegun alternates frames 4 / 5 while held, the chaingun spins 1 / 2 / 3 bullets a frame and loops frames 15–21 (`geChaingunUp` / `Down`, loop sound), the hyperblaster loops 6–11 with its bolt circling the muzzle, the BFG flashes on frame 9 (`geBfgFlash`) and fires the ball on 17, hand grenades pull the pin on frame 5, cook on frame 11 (3.2 s fuse, `hgrenc1b` loop) and are thrown on 12 or go off in the hand (`geGrenadeThrow` / `geGrenadeBlowUp`). Without ammo it clicks at most once a second (`geNoAmmo`) and `NoAmmoWeaponChange` picks the best weapon with ammo. `FireWeapon` (called every frame while fire is held) sets `Attack`; a new press is latched (a tap fires even mid-switch, when the gun gets ready) and thinks at once (Quake 2 `weapon_thunk`), restarting the frame clock. `TQuakeMd2Instance.ShowFrames` draws the view model between `OldFrame` and `Frame` (`FrameLerp`). Idle frames pause at random like Quake 2 (`RandomPauses`, off in autotests so screenshots repeat). The gun's `LoopSound` goes through the loop mixer at the listener.
- **Props** (`TQuakeProp`): `misc_explobox` (10 health, `dmg`+40 radius explosion, chain reactions), `misc_banner` (looping animation), `misc_deadsoldier` (pose from spawnflags), `misc_satellite_dish` (animates when used), `misc_strogg_ship` (hidden until used, then flies its `path_corner`s), `misc_gib_head`.
- **Timers and effects**: `func_timer` (`wait` ± `random`, START_ON, toggled by use), `target_splash` (particle colours by `sounds`), `target_laser` (`TCastleBox` beam stretched to the first wall hit, damages the player in it, toggled by use).
- **Help computer / intermission**: `target_help` fills the primary / secondary objectives; on `target_changelevel` the view moves the camera to `info_player_intermission`, freezes the world and shows the help-computer layout as a mission summary until a key press.
- **Damage**: armor absorbs `protection × damage` (jacket 0.3, combat 0.6, body 0.8), quad damage ×4, invulnerability; death restarts the level.
- **Monsters**: idle → sight (throttled `LineOfSight`) → chase (`TCastleTransform.Move` with `CollisionSphereRadius`, floor via `TCastleTransform.Height`) → attack (callback into the world: melee, hitscan, pellets, rail, blaster bolt, rocket, grenade) → pain → death / gib. `ResolveTargets` sorts `target` like Quake 2's `monster_start_go`: a `path_corner` becomes `MoveTarget` (idle `Patrol` at 40% speed with the walk animation, `wait` pauses, `pathtarget` fires, `wait -1` stops), a `point_combat` becomes `CombatTarget` (`Alert` turns it into `GoalEntity`: run there without attacking, follow its `target` chain, spawnflag 1 sets `HoldGround`), anything else is the `DeathTarget` fired on death. Player-clip brushes are switched off while monsters move.
- **Attack frames** (unit `QuakeMonsterAttacks`): `MonsterAttackSeqs(ClassName)` lists a monster's Quake 2 attack sequences (from the `mframe_t` tables of `m_soldier.c`, `m_infantry.c`, `m_gunner.c`, `m_berserk.c`, `m_flyer.c`, `m_parasite.c`, `m_tank.c`): first model frame and length, fire frames, kind and per-shot damage (with `RepeatDamage` / `DamageRandom`), sound, a burst frame held for `HoldMin`..`HoldMax` more frames while the player is visible (`AI_HOLD_FRAME`: machinegun soldier 3–10, infantry 3–18) and a refire loop (`LoopStart`..`LoopEnd`, `LoopChance`: the gunner's chaingun). `ChooseAttackSeq` picks by range like the Quake 2 attack functions (`auMelee` under 80 units, `auRanged` beyond, `auAny` both). `TMonsterAttack` plays one at 10 frames a second and calls `OnFire` on fire frames; `TQuakeMonster.StartAttackSeq` resolves the first frame by name in the model, draws `Model.ShowFrames(old, current, lerp)`, and `AttackSeqFire` sets `AttackKind` / `AttackDamage` / `AttackBullets` / `AttackReach` before `OnAttack` (`TQuakeWorld.MonsterAttack` fires one bullet per hitscan call). Pain, ducking and death stop the sequence (`SetState`). Monsters without a table keep the generic attack (one shot partway through the attack animation, `AttackFirePoint`). The unit tests check every table against the demo models' frame names and the timings.
- **Perception** (Quake 2 `FindTarget`): a monster notices the player it can see within 1000 units: always within 80 (melee range), within 500 when he is in front of it (cos > 0.3) or fired in the last second (`PlayerShowHostile`, Quake 2 `show_hostile`), within 1000 only in front (`TQuakeMonster.WouldNotice`). Noise (`TQuakeWorld.PlayerNoise`: weapon fire, the player's explosions) wakes monsters within 1000 units that can hear it: in the PHS of the noise's cluster and in an area connected through open portals (`TQuakeGeometry.CanHear`, PHS rows decompressed by `TQuakeBsp.ClusterPHS`); AMBUSH monsters (spawnflag 1, most of the demo's) must also see it. When a monster finds the player (`OnFoundTarget`), non-ambush monsters that would notice it and see it join in on the next frame (`ProcessSightEntities`, Quake 2 `level.sight_entity`). TRIGGER_SPAWN monsters (spawnflag 2) are `Dormant` (no transform, collisions, damage or AI) until their targetname is used; then they appear and, unless AMBUSH, hunt the player (`monster_triggered_spawn`). `Dormant` is kept in savegames.
- **Pursuit** (Quake 2 `p_trail.c`, `ai_run`): `TQuakeWorld.UpdatePlayerTrail` (every 0.1 s) drops a spot at the player's origin when the newest spot is no longer in his line of sight, keeping the last 8 (`TQuakePlayerTrail`). A hunting monster that can't see the player runs to where it saw him last (`FLastSighting`), then to the oldest trail spot newer than the one it reached before (`PursuitGoal`), spot by spot, which leads it around corners instead of into the wall between them; with no spot left it heads for the player again. Flyers keep heading straight for him. The trail isn't saved in savegames.
- **Dodging** (Quake 2 `check_dodge`): when the player fires a blaster bolt, rocket or BFG ball (`SpawnProjectile`), `TQuakeWorld.CheckDodge` ray casts along the shot; if it reaches a living monster facing the player (cos > 0.3), `TQuakeMonster.Dodge(eta)` runs (on easy only a quarter of the time). Soldiers, infantry, gunners, medics and iron maidens (the monsters with `monsterinfo.dodge`) then duck a quarter of the time: state `msDuck`, the `duck` animation stretched over `eta + 0.3` s (0.4–1.5 s). Shots use `ShotRayCast`, which ignores hits on a ducking monster above 8 units below its origin (Quake 2 ducks to `maxs.z = -8`), so level shots fly over it.

---

## 6b. Savegames

`TQuakeWorld.SaveState` / `LoadState` write and read a `fpjson` object: player stats and inventory, then arrays per entity list (monsters, pickups, movers, props, triggers, lasers, speakers) in spawn order, plus `func_timer` / `trigger_counter` state keyed by BSP entity index and light styles 32–62. Loading reloads the map fresh and applies the state on top (`TQuakeMonster.RestoreState`, `TQuakeMover.ApplyPose`). The view adds the camera and stores the file with `UrlSaveStream('castle-config:/saves/<name>.json')`.

Projectiles in flight (kind, position, velocity, damage, splash, remaining life, owner monster index) and pending delayed events (seconds left, targetname or the BSP entity index for a delayed `target_explosion`) are saved too, so a quick save mid-fight restores exactly. The world clock restarts at 0 on load, hence the delays are stored relative. A level revisited in a unit (`IncludePlayer = False`) starts without projectiles and keeps the events scheduled at spawn (Quake 2's `ReadLevel` re-arms `target_crosslevel_target` that way).

`delay` follows Quake 2: an entity's `delay` postpones the use of its targets (`UseTargetsOf`, `G_UseTargets` for relays, `target_*`, `trigger_*`), and `target_explosion` delays its own blast (`use_target_explosion`).

## 7. Castle Game Engine editor integration

| CGE convention (from templates / samples) | How Castle Quake 2 follows it |
| --- | --- |
| Views with `DesignUrl` and published component fields (`3d_fps_game` template) | `TViewPlay` / `TViewMenu` + `data/gameview*.castle-user-interface`. Viewport, camera, navigation, background, HUD, console, menu are designed. |
| `{$region 'Castle View Creation'}` / `'Castle Initialization Uses'` in `GameInitialize` | Present, so the editor can add new views automatically. |
| Custom components + `editor_units` (`examples/advanced_editor/custom_component`) | `TQuakeMap` (`TCastleTransform`), `TQuakeHud`, `TQuakeConsole`, `TQuakeMenu`, registered with `RegisterSerializableComponent`, basic properties grouped with `PropertySections`. |
| Data in designs (`.castle-transform` / `.castle-component`, the template's named sounds) | `data/monsters.castle-transform`: `TQuakeMonsterType` (a `TCastleTransform` showing its MD2 in the editor) with the monster tunables published. `data/sounds.castle-component`: `TQuakeNamedSound` (a `TCastleSound` with `QuakePath`); `TQuakeSounds.GetSound` returns it for that path, and `SpatialSound` copies its `Url`, `Volume` and `Pitch`. Both are regenerated from the code by `castle-quake2-tests --generate-designs ../data` (overwriting edits). |
| Game logic as `TCastleBehavior` (`GameEnemy` in the template) | `TQuakeMonster`, `TQuakePickup`, `TQuakeMover`, with read-only published state for the inspector. |
| Graceful design-time loading | `TQuakeMap` adds its PAK, palette and URL protocols itself (`EnsureData`), logs a warning instead of failing when a map is missing, and rebuilds when `MapName` / `PakUrl` change. |

## 7b. View feel (`TQuakePlayerMovement`)

Quake 2's `SV_CalcViewOffset` / `SV_CalcGunOffset` / `P_DamageFeedback`: every frame `TQuakePlayerMovement.Update` removes the previous frame's view effects from the camera (`ClearViewEffects`), runs pmove (`Move`), then applies new ones (`UpdateViewEffects`), so effects never change where the player is or what collides. Effects: eye bob (`bob_up` 0.005 × horizontal speed, at most 6 units, `bobtime` advancing 0.0625–0.25 per 0.1 s frame by speed), bob pitch / roll (`bob_pitch`, `bob_roll` 0.002, ×6 crouched), running pitch / roll (`run_pitch` 0.002, `run_roll` 0.005), the landing dip and nod (`fall_value` = landing delta / 2, at most 40, over 0.3 s, for deltas ≥ 15) and the damage kick (`DamageKick`, called by `TQuakeWorld.DamagePlayer`: kick = damage × 100 / health clamped to 50, split into pitch and roll by where the damage came from, over 0.5 s). Pitch is applied around the camera's right axis, then roll around the view direction, and undone in reverse. `GunAngles` (weapon bob and lag behind turning: 0.2 × the per-0.1 s angle change, clamped to 45°) goes to `TQuakeWorld.SetGunAngles`, which rotates the view weapon in the weapon viewport. Code that aims, uses or saves the view reads `AimPosition` / `AimDirection` (view without effects); code that moves the camera directly calls `ClearViewEffects` first, and `ResetVelocity` (after `PlaceCamera`) forgets them. *Options → View Bob* (`Settings.ViewBob`) turns it all off.

## 8. Options and skill

`QuakeGamepad` maps game controllers (CGE `Controllers`, initialized at startup except in autotests) to the same inputs. Its functions are pure so the unit tests check them: `ApplyDeadZone` (radial, 0.2, rescaled so output starts at 0), `StickToMove`, `StickToLook` (squared response, 160 / 120 degrees per second yaw / pitch at full deflection, times the mouse sensitivity option, inverted with *Invert Mouse*), `StickToArrow` / `GamepadMenuKey` / `GamepadMenuEvent` for menus and `GamepadWeaponCycle`. `ReadGamepads` sums every connected controller plus `VirtualGamepad` (set by the `GP:` demo action, since CI has no device). `TViewPlay.UpdateMovementInput` adds the sticks to the key movement and passes look as `TQuakePlayerMovement.InputYaw` / `InputPitch`, which `ApplyTurn` applies after `ClearViewEffects` and before pmove (pitch clamped to ±89°); the right trigger fires in `Update`. Buttons arrive as `itGameController` press events in `TViewPlay.Press` (use, grenades, weapon cycle, help, menu); while the menu is open they are translated to arrow / Enter / Escape key events, and `TQuakeMenu.Update` turns the left stick into repeating arrows.

`QuakeSettings` holds the player options (`TQuakeSettings`: mouse sensitivity as a multiplier of CGE's default, invert, horizontal FOV, sound / music volume, a key per `TQuakeAction`, last chosen skill), loaded from and saved to CGE's `UserConfig` (`quake2/...` keys, only non-default values stored). `TQuakeMenu` edits them on the *Options* and *Controls* pages (Left / Right change values, Enter on a control waits for a key; binding a used key swaps the two) and raises `maSettingsChanged`, on which `TViewPlay.ApplySettings` sets `TCastleWalkNavigation` sensitivity / `InvertVerticalMouseLook`, the camera's `Perspective.FieldOfView` and the sound engine volumes. `GameSkill` is Quake 2's latched `skill`: set by *Single Player*, the `skill` console command (next map) and savegames (before the map loads, since entities are matched by spawn order). It selects the spawnflag that removes entities (`SPAWNFLAG_NOT_EASY` / `_MEDIUM` / `_HARD`), halves player damage on easy (`T_Damage`), scales the time between monster attacks (`M_CheckAttack`'s attack chance) and disables pain reactions on nightmare.

## 9. Automated testing

`--map-report <file.md>` runs like an autotest (default options) but loads every map of the PAKs through `TQuakeWorld.LoadMap` (`*map`, a fresh unit each) and writes a Markdown report (`QuakeMapReport.TMapReport`): load time, faces, entities, monsters, items, and the entity classes the game doesn't handle (`EntitySupport`: supported = spawned, used by targets, drawn or used as markers; partial = generic monster AI, `func_*` brushes without their behaviour, `func_wall` toggles; unsupported = the rest), counting only entities spawned on the current skill. CI runs it on the demo PAK and fails if an unsupported class appears.

`--autotest <map> <prefix> --demo "<script>"` loads a map, runs the script (see README) and exits after a final screenshot. Screenshots log the FPS and camera position, `V` logs every mover's state, and `N:` / `I:` / `D:` place the camera on a floor near a monster / item / mover, which makes visual regression checks of AI, pickups and movers possible without a human player.
