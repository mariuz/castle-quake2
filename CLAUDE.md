# CLAUDE.md

Working notes for developers and AI agents on Castle Quake 2: a Quake 2 port to Castle Game Engine (CGE) in Object Pascal (FPC). Sibling of `castle-quake1`. Read `docs/ARCHITECTURE.md` for full architectural details.

## What this is

- Quake 2 levels (`maps/*.bsp`, IBSP v38), wall textures (`textures/*.wal`), models (`models/**/tris.md2`), pics/skins (`*.pcx`), skies (`env/*`) and sounds are parsed from PAK archives at runtime.
- Bundled with the Quake 2 shareware demo (`data/paks/quake2_demo.pak`, maps `demo1`..`demo3`); a full game is loaded from `baseq2/` or `-basedir`.
- Served to CGE through memory URL protocols (`quakepak:`, `quaketex:`).
- Units: `QuakeBsp` (parser, `LightPoint`), `QuakeGeometry` (X3D batches, lightmap atlas, movers), `QuakeMd2`, `QuakePalette` (PCX/WAL), `QuakeEntities` (item/weapon/monster tables, AI), `QuakeWorld` (game rules, targets/triggers, weapons), `QuakeHud`, `QuakeLight` (coordinates, model tint), `QuakeSound`, `QuakeParticles`, `QuakeConsole`, `QuakeMenu`, `Game*` views.

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

Demo script actions: `W:sec` wait, `S` screenshot (logs FPS + camera), `X` fire, `H` hold-fire toggle, `U` use, `C:slot` weapon (1 blaster .. 10 BFG, 11 hand grenades), `K` give all, `Y` god, `A:deg` absolute yaw, `T:deg` turn, `P:deg` pitch, `M:units` move, `N:i`/`I:i`/`D:i`/`R:i` stand near monster/item/mover/prop i, `F` help computer, `G:x y z` goto (Quake coords), `E:targetname` fire targets, `O:command` console command, `V` log mover states, `L:map` load map, `Q` quit.

## Unit tests

`tests/` is a console CGE project (search path `../code/`): `cd tests; castle-engine compile; ./castle-quake2-tests` — 51 checks of the parsers against the demo PAK (counts, contents, ladders, LightPoint, PVS, MD2 animations, SP2). Run from `tests/` (it loads `../data/paks/quake2_demo.pak`). CI runs it before the autotests.

Screenshot comparison: `./castle-quake2-tests --compare reference/<map>.png <shot>.png <diff>.png [limit]` averages both images into 64x36 blocks and fails when the mean channel difference is above 3 (identical runs: < 1; a 10° turn: ~6). CI compares an `O:notarget,W:2,S,Q` shot (no combat, player settled) of each demo map with `tests/reference/*.png`. After an intended visual change, delete the affected reference and commit the one CI creates (artifact `autotest-screenshots`, `compare/reference/`), (references are made by CI's Mesa renderer; Windows shots differ by up to ~4, so don't regenerate them locally).

## CGE editor integration

- Views use designs: `data/gameviewplay.castle-user-interface`, `data/gameviewmenu.castle-user-interface` (`DesignUrl` + published fields). Change viewport / camera / navigation settings in the design, not in code.
- `editor_units="QuakeMap, QuakeHud, QuakeConsole, QuakeMenu"`: these units call `RegisterSerializableComponent`. Children created in a component constructor must call `SetTransient`.
- `TQuakeMap` also fills its published `Background` (the viewport's `TCastleBackground`) with the map's skybox in `ApplySky`, in the editor too, and `PreviewEntities` / `PreviewMarkers` show items, monsters, player starts, paths, speakers and trigger volumes in the editor (`markers` console command in game).
- `TQuakeMap` (in the play design, named `QuakeMap`) owns the BSP + geometry; `TQuakeWorld` gets it in the constructor, reuses the design-loaded map once, and calls `LoadMap` for restarts / level changes. Keep `TQuakeMap` at identity transform: gameplay code uses its local space as world space.
- Monsters, pickups and movers are `TCastleBehavior`s owned by Pascal lists (not by the transform); their destructors free the transform after `BeforeDestruction` detached them. Give runtime transforms readable `Name`s.
- World faces are culled by the PVS in 1024-unit regions (`TQuakeGeometry.UpdateVisibility`, `Shape.Visible`); `novis` in the console draws everything. To check culling, compare shots of the same demo script with and without `O:novis` (they should match within ~1.5).
- Code running during design loading (e.g. in `TQuakeMap.Loaded`) can't use `WorldTransform` / `WorldBoundingBox` yet.

## Conventions & Rules

- 2-space indent, `begin`/`end` on their own lines, PascalCase, no `with`.
- Coordinates: `CGE.X = Quake.X`, `CGE.Y = Quake.Z`, `CGE.Z = -Quake.Y` (`QuakeToCge`). Quake yaw maps to a rotation around +Y by the same angle (`YawToCgeDir`).
- BSP polygons and MD2 triangles are clockwise from the front: `Ccw := False`.
- CGE images are bottom-to-top; PCX/WAL decoders flip rows, so UV `v = 1 - t/height`.
- `TCastleBackground.TexturePositiveZ` is the X3D "front" drawn at **-Z** (and `TextureNegativeZ` at +Z).
- Particles are data (`TQuakeParticle`) drawn by one batched scene in `TQuakeParticleManager.RebuildBatch`; set `Particles.Camera`. (If you use `TBillboardNode` elsewhere, it needs `Scene.ProcessEvents := True`.)
- Don't use `MODULATE2X`/`MODULATE4X` multi-texture modes: CGE emits an int literal (`*= 2;`) that breaks WebGL shaders. Scale the unlit emissive colour instead. Check web logs for `GLSL: Fragment shader not compiled`.
- Dynamic lights: `Lighting.AddLight(pos, radius, color, duration)` (duration 0 = this frame only, re-add every frame). World surfaces show the 4 nearest via the lightmap texture effect in `TQuakeGeometry.CreateDLightEffect`; create one effect per scene, never share X3D nodes between scenes.
- Light styles: `TQuakeLighting` owns style patterns/values (`Version` bumps on change); `TQuakeDynamicLightmap` recomposes the light-style atlas and calls `Node.FdImage.Changed`. Lightmaps of a face are `styles` consecutive RGB blocks.
- `TQuakeMd2Instance.PlayAnim('')` plays all frames (banners, effects).
- Autotests disable mouse look (results must not depend on the desktop mouse). CI runs the same scripts on Linux under xvfb + Mesa (`.github/workflows/build.yml`, job `autotest`).
- Model scenes that must not block ray casts (items, projectiles, view weapon) set `Collides := False`, `Pickable := False`; monsters keep `Collides` and are found by `TQuakeMonster.OwnsTransform` from `WorldRayCast` results.
