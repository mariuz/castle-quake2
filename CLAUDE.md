# CLAUDE.md

Working notes for developers and AI agents on Castle Quake 2: a Quake 2 port to Castle Game Engine (CGE) in Object Pascal (FPC). Sibling of `castle-quake1`. Read `docs/ARCHITECTURE.md` for full architectural details.

## What this is

- Quake 2 levels (`maps/*.bsp`, IBSP v38), wall textures (`textures/*.wal`), models (`models/**/tris.md2`), pics/skins (`*.pcx`), skies (`env/*`) and sounds are parsed from PAK archives at runtime.
- Bundled with the Quake 2 shareware demo (`data/paks/quake2_demo.pak`, maps `demo1`..`demo3`); a full game is loaded from `baseq2/` or `-basedir`.
- Served to CGE through memory URL protocols (`quakepak:`, `quaketex:`).
- Units: `QuakeBsp` (parser, `LightPoint`), `QuakeGeometry` (X3D batches, lightmap atlas, movers), `QuakeMd2`, `QuakePalette` (PCX/WAL), `QuakeEntities` (item/weapon/monster tables, AI), `QuakeWorld` (game rules, targets/triggers, weapons), `QuakeWeaponFrames` (the gun's Quake 2 frame state machine), `QuakeMonsterAttacks` (monster attack sequences on Quake 2's frames), `QuakeTrace` (box traces against BSP brushes, `CM_BoxTrace`), `QuakeTouch` (on-screen touch controls), `QuakeHud`, `QuakeLight` (coordinates, model tint), `QuakeSound`, `QuakeParticles`, `QuakeConsole`, `QuakeMenu`, `Game*` views.

## Build and Run (Windows)

CGE 7.0-alpha.3 snapshot with bundled FPC 3.2.2 is installed at `C:\castle-engine`:

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release      # or --mode=debug
.\castle-quake2.exe
```

The log goes to `%LOCALAPPDATA%\castle-quake2\castle-quake2.log`. Audio needs `OpenAL32.dll` and `wrap_oal.dll` next to the exe.

Linux (as in CI, or a cloud container): FPC 3.2.2 (`apt install fpc libgtk-3-dev`), CGE cloned from GitHub with its build tool compiled by `tools/build-tool/castle-engine_compile.sh`, `CASTLE_ENGINE_PATH` set; autotests run under `xvfb-run -a -s "-screen 0 1600x900x24"` with Mesa.

## Automated Headless Testing

```powershell
.\castle-quake2.exe --autotest demo1 test_output\shot --demo "W:1.5,S,K,C:9,N:3,W:0.5,X,W:0.2,S,Q"
```

Demo script actions: `W:sec` wait, `S` screenshot (logs FPS + camera), `X` fire, `H` hold-fire toggle, `U` use, `C:slot` weapon (1 blaster .. 10 BFG, 11 hand grenades), `K` give all, `Y` god, `A:deg` absolute yaw, `T:deg` turn, `P:deg` pitch, `M:units` move, `N:i`/`I:i`/`D:i`/`R:i` stand near monster/item/mover/prop i, `F` help computer, `G:x y z` goto (Quake coords), `E:targetname` fire targets, `O:command` console command, `V` log mover states (and `Gun: weapon state frame, ammo`, `Monster shots: N, player health ... player stuck N`, `Monsters: N alerted of M alive, K in solid`), `L:map` load map, `B:key` press and release a key (CGE key name, case-insensitive, e.g. `B:escape` to drive the menu), `GP:lx ly rx ry lt rt` virtual gamepad sticks / triggers (`GP:` off), `GB:button` gamepad button (`south`, `east`, `menu`, `rb`...), `TD:x y finger` / `TM:x y finger` / `TU:finger` touch down / move / up (window fractions; run with `--touch` to show the touch controls), `Q` quit. Autotests use default options (`Settings.Persistent := False`, user config not loaded).

Map compatibility report: `castle-quake2 --map-report report.md` (under xvfb on Linux) loads every map and lists unsupported / partial entity classes (`QuakeMapReport.EntitySupport`; add new classnames there when you implement them). `docs/map-report-demo.md` is the demo's; CI fails if the demo maps get an unsupported class.

## Unit tests

`tests/` is a console CGE project (search path `../code/`): `cd tests; castle-engine compile; ./castle-quake2-tests` — 158 checks of the parsers against the demo PAK (counts, contents, ladders, LightPoint, PVS, PHS, areas, box leafs, MD2 animations, SP2, monster types and named sounds designs, settings save / load and skill rules, sound attenuation and loop mixer, map report classes, player trail, gamepad mapping, gun frame timing, monster attack tables and timing, box traces, monster jumps, touch stick). Run from `tests/` (it loads `../data/paks/quake2_demo.pak`). CI runs it before the autotests.

Screenshot comparison: `./castle-quake2-tests --compare reference/<map>.png <shot>.png <diff>.png [limit]` averages both images into 64x36 blocks and fails when the mean channel difference is above 3 (identical runs: < 1; a 10° turn: ~6). CI compares an `O:notarget,W:2,S,Q` shot (no combat, player settled) of each demo map with `tests/reference/*.png`. After an intended visual change, delete the affected reference and commit the one CI creates (artifact `autotest-screenshots`, `compare/reference/`), (references are made by CI's Mesa renderer; Windows shots differ by up to ~4, so don't regenerate them locally).

## CGE editor integration

- Views use designs: `data/gameviewplay.castle-user-interface`, `data/gameviewmenu.castle-user-interface` (`DesignUrl` + published fields). Change viewport / camera / navigation settings in the design, not in code.
- `editor_units` (`QuakeMap, QuakePlayer, QuakeHud, QuakeConsole, QuakeMenu, QuakeMonsterTypes, QuakeSound`): these units call `RegisterSerializableComponent`. Children created in a component constructor must call `SetTransient`.
- `TQuakeMap` also fills its published `Background` (the viewport's `TCastleBackground`) with the map's skybox in `ApplySky`, in the editor too, and `PreviewEntities` / `PreviewMarkers` show items, monsters, player starts, paths, speakers and trigger volumes in the editor (`markers` console command in game).
- `TQuakeMap` (in the play design, named `QuakeMap`) owns the BSP + geometry; `TQuakeWorld` gets it in the constructor, reuses the design-loaded map once, and calls `LoadMap` for restarts / level changes. Keep `TQuakeMap` at identity transform: gameplay code uses its local space as world space.
- Monsters, pickups and movers are `TCastleBehavior`s owned by Pascal lists (not by the transform); their destructors free the transform after `BeforeDestruction` detached them. Give runtime transforms readable `Name`s.
- World faces are culled by the PVS and areaportals in 1024-unit, per-area regions (`TQuakeGeometry.UpdateVisibility`, `Shape.Visible`); movers, monsters, items, props and lasers get `Transform.Visible := False` outside it (`TQuakeWorld.CullEntities`, by the leafs their boxes touch; they still collide). `novis` in the console draws everything. To check culling, compare shots of the same demo script with and without `O:novis` (they should match within ~1.5).
- Monster tunables live in `data/monsters.castle-transform` (`TQuakeMonsterType`, applied over `DefaultMonsterDefs` by `LoadMonsterTypes` at startup) and sound overrides in `data/sounds.castle-component` (`TQuakeNamedSound`, matched by `QuakePath`). When adding a monster or a literal sound path in code, add it to `DefaultMonsterDefs` / `DesignSoundPaths` (tests) and to the design; `castle-quake2-tests --generate-designs ../data` regenerates both files from code (overwriting editor changes).
- Player weapons run on Quake 2's gun frames (`TQuakeWorld.Gun`, `TQuakeGun`): fire, refire and switching happen on frame events, never on timers. `SelectWeapon` only queues the switch (`FStats.CurrentWeapon` changes on `geChangeWeapon`, after the put-away frames), so demo scripts need a wait after `C:slot` (about 1 s) before shots of the new weapon.
- Player collision in game is Quake 2's: `TQuakeWorld.PlayerTrace` (BSP brushes via `TQuakeCollision`, movers in model space, live monster boxes; Quake coordinates) drives `TQuakePlayerMovement.PMMove` (`PM_StepSlideMove` etc.). Render meshes no longer decide where the player can go, so autotest placements (`G`, `N`, `I`, `D`, `R`) call `PlayerMovement.SnapToFreeSpace`; `player stuck` in the `V` log should stay 0 in normal scripts. Movers carry / push the player in `PushPlayerByMovers` (from `OnBeforeMove`).
- Monster attacks: `MonsterAttackSeqs` (unit `QuakeMonsterAttacks`) holds each demo monster's Quake 2 attack sequences (first frame name, length, fire frames, damage, bursts, loops); when adding a monster, add its table there (the tests check frame names against the model) or it uses the generic attack. Damage per shot comes from the table, not `TQuakeMonsterDef.Damage`.
- Touch: `TQuakeTouchControls` (unit `QuakeTouch`) is created by `TViewPlay.Start` when `TouchControlsWanted` (`ApplicationProperties.TouchDevice` or `--touch`) and inserted in front of the viewport, behind the menu and console. `UpdateMovementInput` reads `Stick`, `TakeLook` (pixels, times `LookDegreesPerPixel` and the mouse sensitivity) and `Held(tb...)`; with touch controls the left mouse button no longer fires (every touch is a left button) and mouse look is off. `TQuakeMenu` selects / activates rows by tap (`ItemAt` mirrors `Render`'s layout). Android: CI job `build-android` runs `castle-engine package --target=android`.
- Gamepads: `QuakeGamepad` (pure mapping functions + `ReadGamepads`, which sums CGE's `Controllers` and the demo scripts' `VirtualGamepad`). Sticks / triggers are polled in `TViewPlay.UpdateMovementInput` (look goes through `PlayerMovement.InputYaw` / `InputPitch`, applied to the view without effects before pmove); buttons arrive as `itGameController` press events (`GamepadMenuEvent` turns them into menu keys). Controllers are not initialized in autotests.
- Options live in `QuakeSettings` (`Settings`: mouse, FOV, volumes, key bindings `Settings.Keys[qa...]`, last skill; saved in `UserConfig` under `quake2/`). Read keys through `Settings.Keys`, never hard-code movement / action keys. `GameSkill` is the skill of the running game (spawn filter `SkillSpawnFlag`, `SkillAttackDelay`, easy half damage, no pain on nightmare) and is saved in savegames.
- Monster perception follows Quake 2 `FindTarget`: `TQuakeMonster.WouldNotice` (ranges, front cone, `PlayerShowHostile`), noise through `TQuakeWorld.PlayerNoise` (PHS + areas via `TQuakeGeometry.CanHear`; call it for new player noises instead of alerting monsters by distance), `Ambush` / `Dormant` from spawnflags 1 / 2 (dormant monsters are absent until `Spawn`). The `V` demo action logs `Monsters: N alerted of M alive`. Monsters that lose sight of the player follow `PlayerTrail` (fed by `TQuakeWorld.UpdatePlayerTrail`; `TQuakeMonster.PursuitGoal`); `V` logs `Hunting monster i sees player ...`. Player projectiles call `CheckDodge` (monsters may duck, `msDuck`); hit tests for shots go through `ShotRayCast` so shots pass over ducking monsters.
- Code running during design loading (e.g. in `TQuakeMap.Loaded`) can't use `WorldTransform` / `WorldBoundingBox` yet.

## Conventions & Rules

- 2-space indent, `begin`/`end` on their own lines, PascalCase, no `with`.
- Coordinates: `CGE.X = Quake.X`, `CGE.Y = Quake.Z`, `CGE.Z = -Quake.Y` (`QuakeToCge`). Quake yaw maps to a rotation around +Y by the same angle (`YawToCgeDir`).
- BSP polygons and MD2 triangles are clockwise from the front: `Ccw := False`.
- CGE images are bottom-to-top; PCX/WAL decoders flip rows, so UV `v = 1 - t/height`.
- `TCastleBackground.TexturePositiveZ` is the X3D "front" drawn at **-Z** (and `TextureNegativeZ` at +Z).
- Sounds: use `Sounds.Play(path, volume, channel)` for the player (2D), `PlayAt(path, transform, volume, attenuation, channel)` / `PlayAtPoint(path, position, ...)` for the world, with Quake 2's `CHAN_*` as `chWeapon` / `chVoice` / `chItem` / `chBody` (same owner + channel replaces the previous sound). Never attach looping `TCastleSoundSource`s to entities: report looping sounds each frame through `TQuakeWorld.UpdateLoopSounds` (loop mixer). To listen headless, run with `ALSOFT_CONF` pointing to an OpenAL Soft config with `drivers = wave` and `sample-type = int16`.
- View effects (bob, landing dip, damage kicks, weapon bob / lag) are applied to the camera by `TQuakePlayerMovement` after pmove and removed before the next move. Aim, use and save with `PlayerMovement.AimPosition` / `AimDirection`, not the camera; call `PlayerMovement.ClearViewEffects` before moving or turning the camera from code.
- Particles are data (`TQuakeParticle`) drawn by one batched scene in `TQuakeParticleManager.RebuildBatch`; set `Particles.Camera`. (If you use `TBillboardNode` elsewhere, it needs `Scene.ProcessEvents := True`.)
- Don't use `MODULATE2X`/`MODULATE4X` multi-texture modes: CGE emits an int literal (`*= 2;`) that breaks WebGL shaders. Scale the unlit emissive colour instead. Check web logs for `GLSL: Fragment shader not compiled`.
- Dynamic lights: `Lighting.AddLight(pos, radius, color, duration)` (duration 0 = this frame only, re-add every frame). World surfaces show the 4 nearest via the lightmap texture effect in `TQuakeGeometry.CreateDLightEffect`; create one effect per scene, never share X3D nodes between scenes.
- Light styles: `TQuakeLighting` owns style patterns/values (`Version` bumps on change); `TQuakeDynamicLightmap` recomposes the light-style atlas and calls `Node.FdImage.Changed`. Lightmaps of a face are `styles` consecutive RGB blocks.
- `TQuakeMd2Instance.PlayAnim('')` plays all frames (banners, effects).
- Autotests disable mouse look (results must not depend on the desktop mouse). CI runs the same scripts on Linux under xvfb + Mesa (`.github/workflows/build.yml`, job `autotest`).
- Collisions, shots and sight go through `TQuakeWorld.WorldTrace` (also `EntityTrace` for monsters): map brushes, movers, monster boxes (`BoxMins` / `ShotBoxMaxs`), the player's box, corpses and barrels, with Quake 2 masks (`MASK_PLAYERSOLID`, `MASK_MONSTERSOLID`, `MASK_SHOT`, `MASK_OPAQUE`) and an `Ignore` entity; the hit is `T.Ent`. Don't use `WorldRayCast` / CGE collisions for gameplay any more (render meshes aren't the brushes). Model scenes still set `Collides := False`, `Pickable := False` where they don't need CGE picking.
