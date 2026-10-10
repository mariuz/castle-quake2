# Castle Quake 2

A port of **Quake 2** to the **Castle Game Engine** (Object Pascal / Free Pascal), the sibling of [mariuz/castle-quake1](https://github.com/mariuz/castle-quake1). Bundled with the original **Quake 2 shareware demo** data (`demo1`–`demo3`, the first three Outer Base levels), and able to load a full Quake 2 install (`baseq2/pak*.pak`).

![demo1 start](docs/screenshot-demo1.png)

- 📖 **[Architecture & Engine Mapping](docs/ARCHITECTURE.md)**
- 🗺️ **[Quake 2 Comparison & Roadmap](docs/ROADMAP.md)**

---

## Features (and the Castle Game Engine parts they use)

- **Quake 2 BSP (IBSP v38) world geometry**
  - All 19 lumps parsed; faces batched per texture + surface flags into X3D `TIndexedTriangleSetNode`s loaded into `TCastleScene` with `PreciseCollisions` for walking and ray casts.
  - **WAL wall textures** decoded with the `pics/colormap.pcx` palette and served through the `quaketex:` URL protocol.
  - **Baked RGB lightmaps** packed into one atlas per model and applied with `TMultiTextureNode` (`MODULATE` + `MODULATE2X`), like Quake 2's GL renderer.
  - Surface flags: `SURF_SKY` (invisible but solid), `SURF_NODRAW`, `SURF_WARP`, `SURF_TRANS33/66` (blended), `SURF_FLOWING` (scrolling `TTextureTransformNode`).
  - **Animated textures** following the WAL `animname` chains at 2 frames/second.
- **Skybox** from `env/<sky>{rt,lf,up,dn,bk,ft}.tga|pcx` via `TCastleBackground`.
- **MD2 models** (IDP2 v8): monsters, items, weapons, projectiles and the first-person view weapon, with **interpolated frame animation**, PCX skins (index 255 transparent) and per-model tint sampled from the lightmaps below them (Quake 2's `R_LightPoint`, done by walking the BSP nodes).
- **Brush entities** as `TCastleTransform`s: `func_door`, `func_door_rotating`, `func_plat`, `func_button`, `func_rotating`, `func_train` (follows `path_corner`s), `func_wall`, `func_explosive` (shootable, chain reactions).
- **Quake 2 entity logic**: `target` / `targetname` chains (`G_UseTargets`), `trigger_multiple/once/relay/counter/key/hurt/always`, `delay`, `target_changelevel` (with `map$spawnpoint`), `target_secret/goal/help/speaker/explosion`, `misc_teleporter`, messages and the help-computer objectives.
- **All 10 weapons**: Blaster, Shotgun, Super Shotgun, Machinegun, Chaingun, Grenade Launcher (bouncing grenades), Rocket Launcher (splash damage), HyperBlaster, Railgun (piercing, spiral trail), BFG10K. Hitscan uses `WorldRayCast` against the scene, so shots stop at walls and hit the exact monster mesh.
- **Items**: health, armor (jacket/combat/body with Quake 2 protection and salvage rules, shards), ammo, quad damage, invulnerability, adrenaline, bandolier, ammo pack, keys (data CD, power cube, pyramid, spinner, pass, blue/red key, commander's head, airstrike marker).
- **Monsters** (19 types defined; the demo has soldiers, enforcers, gunners, berserkers, flyers, parasites and tanks): sight via line-of-sight checks, chase with wall sliding (`TCastleTransform.Move`), floor following, melee / hitscan / blaster / rocket / grenade / railgun attacks, pain and death animations, gibbing; monster projectiles can hurt other monsters.
- **Player**: Quake 2 dimensions (eye 46 above the floor, 18-unit steps, 300 u/s run), crouch, noclip, damage with armor absorption, death and level restart.
- **HUD** drawn with the original `pics/*.pcx` big numbers, ammo/health/armor/weapon/key icons and crosshair (`TDrawableImage`), pickup notices and damage / quad / invulnerability screen blends.
- **Spatial audio** from the PAK's WAVs via `TCastleSoundSource`; optional CD-music replacement as `data/music/trackNN.ogg`.
- **Billboard particles** (`TBillboardNode`): bullet impacts, blood, blaster sparks, explosions, rail trails, BFG blasts, teleport fountains.
- Drop-down **console**, **menu** with the map list read from the loaded PAKs, and a headless **autotest / demo-script harness**.

| | |
|---|---|
| ![Soldier](docs/screenshot-soldier.png) | ![Railgun](docs/screenshot-railgun.png) |

---

## Controls

| Key | Action |
| --- | --- |
| **W, A, S, D** / Arrows | Move / strafe |
| **Mouse** | Look |
| **Left Mouse / Ctrl** (hold) | Fire |
| **Space** / **C** | Jump / Crouch |
| **E** | Use (doors, buttons) |
| **1 .. 9, 0** / Mouse wheel | Select weapon (Blaster .. BFG10K) |
| **F1** | Toggle noclip fly mode |
| **F12** | Screenshot |
| **~** | Console (`map`, `maps`, `god`, `give all`, `noclip`, `kill`, `quit`, `help`) |
| **Escape** | Menu |

---

## Building and Running

Prerequisites: [Castle Game Engine](https://castle-engine.io/) 7.0-alpha.3 or later (bundles FPC 3.2.2).

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release
.\castle-quake2.exe
```

### Game data

PAKs are loaded in this order (later ones override earlier ones):

1. `data/paks/quake2_demo.pak` — the bundled shareware demo (`pak0.pak` from `q2-314-demo-x86.exe`).
2. `baseq2/pak0.pak`, `pak1.pak`, ... next to the executable — a full Quake 2 install.
3. `-basedir <quake2 dir>` (loads `<dir>/baseq2/pak*.pak`) and `-pak <file>`.

### Command line

```powershell
.\castle-quake2.exe +map demo2                 # start on a map ("base1" with the full game)
.\castle-quake2.exe -basedir "C:\Games\Quake2" # use a full Quake 2 install
.\castle-quake2.exe -gamma 1.0                 # original lightmap brightness (default 1.2)
.\castle-quake2.exe --autotest demo1 shot --demo "W:1,S,K,C:9,N:3,X,W:0.2,S,Q"
```

Demo script actions (comma separated): `W:sec` wait, `S` screenshot, `X` fire, `H` toggle hold-fire, `U` use, `C:slot` weapon, `K` give all, `Y` god, `A:deg` yaw, `T:deg` turn, `P:deg` pitch, `M:units` move, `N:i` / `I:i` / `D:i` stand near monster / item / brush entity number i, `G:x y z` go to Quake coordinates, `E:targetname` fire targets, `V` log mover states, `L:map` load map, `Q` quit.

---

## License

- Code: MIT License (matching Castle Game Engine and mariuz/castle-quake1).
- `data/paks/quake2_demo.pak` is the unmodified Quake 2 demo data © id Software, redistributed electronically free of charge under the id Software demo license in `data/paks/QUAKE2_DEMO_LICENSE.txt`, which must accompany it.
- Quake is a registered trademark of id Software / ZeniMax Media.
