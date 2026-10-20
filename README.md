# Castle Quake 2

A port of **Quake 2** to the **Castle Game Engine** (Object Pascal / Free Pascal), the sibling of [mariuz/castle-quake1](https://github.com/mariuz/castle-quake1). Bundled with the original **Quake 2 shareware demo** data (`demo1`–`demo3`, the first three Outer Base levels), and able to load a full Quake 2 install (`baseq2/pak*.pak`).

![demo1 start](docs/screenshot-demo1.png)

- 🌐 **[Play in the browser (WebAssembly)](https://mariuz.github.io/castle-quake2/)**
- 📦 **[Download for Windows, Linux and Android](https://github.com/mariuz/castle-quake2/releases)** (latest: v0.6.0, see the [changelog](docs/CHANGELOG.md))
- 📖 **[Architecture & Engine Mapping](docs/ARCHITECTURE.md)**
- 🗺️ **[Quake 2 Comparison & Roadmap](docs/ROADMAP.md)**

---

## Features (and the Castle Game Engine parts they use)

- **Quake 2 BSP (IBSP v38) world geometry**
  - All 19 lumps parsed; faces batched per texture + surface flags into X3D `TIndexedTriangleSetNode`s loaded into `TCastleScene` with `PreciseCollisions` for walking and ray casts.
  - **WAL wall textures** decoded with the `pics/colormap.pcx` palette and served through the `quaketex:` URL protocol.
  - **Baked RGB lightmaps** packed into one atlas per model and applied with `TMultiTextureNode` (`MODULATE` × 2, the overbright factor in the unlit material's emissive colour, which also works in WebGL), like Quake 2's GL renderer.
  - Surface flags: `SURF_SKY` (invisible but solid), `SURF_NODRAW`, `SURF_WARP` (animated with a GLSL `PLUG_texture_coord_shift` shader effect, non-solid), `SURF_TRANS33/66` (blended), `SURF_FLOWING` (scrolling `TTextureTransformNode`).
  - **Animated textures** following the WAL `animname` chains at 2 frames/second.
  - **Light styles**: flickering, pulsing and switchable lights. Faces lit by animated styles live in a separate lightmap atlas that is recomposed from their up to 4 style layers (10 Hz, only when a style changes) and re-uploaded; `light` entities with a `targetname` switch on/off, `target_lightramp` fades them.
- **Skybox** from `env/<sky>{rt,lf,up,dn,bk,ft}.tga|pcx` via `TCastleBackground` (`TQuakeMap.Background`, also shown in the CGE editor).
- **SP2 sprites** (IDS2 v2): the BFG10K ball and its explosion, as animated camera-facing quads.
- **MD2 models** (IDP2 v8): monsters, items, weapons, projectiles and the first-person view weapon, with **interpolated frame animation**, PCX skins (index 255 transparent) and per-model tint sampled from the lightmaps below them (Quake 2's `R_LightPoint`, done by walking the BSP nodes). **Shells** like `RF_SHELL_*`: a translucent copy pushed 4 units out along the normals, blue on the view weapon with quad damage, red with invulnerability, green on monsters whose power armor absorbs a hit (the brain's power screen).
- **Brush entities** as `TCastleTransform`s: `func_door`, `func_door_rotating`, `func_plat`, `func_button`, `func_rotating`, `func_train` (follows `path_corner`s), `func_wall`, `func_explosive` (shootable, chain reactions).
- **Quake 2 entity logic**: `target` / `targetname` chains (`G_UseTargets`), `trigger_multiple/once/relay/counter/key/hurt/always`, `delay`, `target_changelevel` (with `map$spawnpoint`; levels of a unit remember their state when you come back), `target_crosslevel_trigger` / `_target`, `target_secret/goal/help/speaker/explosion`, `misc_teleporter`, messages and the help-computer objectives.
- **Dynamic lights**: muzzle flashes, explosions, rockets, blaster bolts and BFG balls light the walls and models around them (a shader effect on the lightmaps).
- **All 10 weapons plus hand grenades**: Blaster, Shotgun, Super Shotgun, Machinegun, Chaingun (spins up from 1 to 3 bullets per frame), Grenade Launcher (bouncing grenades), Rocket Launcher (splash damage), HyperBlaster, Railgun (piercing, spiral trail), BFG10K, hand grenades (hold fire to cook, throw harder the longer you hold, explode in your hand after 3 s). Guns run on Quake 2's weapon frames: shots leave on the frames the original fires them, refire when the animation allows, and switching weapons plays the put-away and raise animations (the BFG fires its ball 0.8 s after the flash, like the original). Shots are Quake 2 traces through the map's brushes, doors and plats, monster boxes (shorter while a monster ducks), corpses and barrels; grenades bounce off the surface they hit.
- **Items**: health, armor (jacket/combat/body with Quake 2 protection and salvage rules, shards), ammo, quad damage, invulnerability, adrenaline, bandolier, ammo pack, keys (data CD, power cube, pyramid, spinner, pass, blue/red key, commander's head, airstrike marker).
- **Monsters** (19 types defined; the demo has soldiers, enforcers, gunners, berserkers, flyers, parasites and tanks): sight via line-of-sight checks, chase with wall sliding (`TCastleTransform.Move`), floor following, melee / hitscan / blaster / rocket / grenade / railgun attacks, pain and death animations, gibbing into flying gib models; monsters detour around obstacles and won't walk off ledges; idle monsters walk their `path_corner` patrols (with `wait` and `pathtarget`), alerted ones first run to their `point_combat` (and hold it when flagged); monster projectiles can hurt other monsters.
- **View weapon in its own transparent viewport** (`WeaponViewport`, cleared depth), so it never clips into walls.
- **Invisible player-clip walls** rebuilt from the clip brushes' planes.
- **Player physics ported from Quake 2's pmove** (`TQuakePlayerMovement`, a behavior on the camera): Quake 2's 32 × 32 × 56 player box (32 high when crouched) swept through the map's BSP brushes like Quake 2's collision model (`QuakeTrace`: exact sliding along walls, slopes and creases, 18-unit step-ups with a smoothed view, platforms and doors carry and push you, monsters block you), friction 6, accelerate 10, air control 1, gravity 800, jump 270, 18-unit steps, crouch (eye 46 → 22, speed 100), ladders (forward + look up / down, jump / crouch), falling damage and jump pads (`trigger_push`). Tunables are published, so they can be tweaked in the editor; `Active = false` falls back to `TCastleWalkNavigation` movement. **Swimming** (`PM_WaterMove`: water level from BSP leaf contents, water friction, sinking, swim up / along the view), underwater tints, lava / slime damage, drowning after 12 seconds, splash sounds; warped liquid surfaces don't collide. Plus noclip, damage with armor absorption, death and level restart.
- **HUD** drawn with the original `pics/*.pcx` big numbers, ammo/health/armor/weapon/key icons and crosshair (`TDrawableImage`), pickup notices and damage / quad / invulnerability screen blends.
- **Spatial audio** from the PAK's WAVs via `TCastleSoundSource` (doors and lifts loop their move sound, idle monsters mutter), with Quake 2's distance attenuation mapped to OpenAL's linear model; **ambient `target_speaker` loops** (80–90 per demo map) and triggered sounds; optional CD-music replacement as `data/music/trackNN.ogg`.
- **Props and effects**: exploding barrels (`misc_explobox`, chain reactions), waving banners, corpses, the satellite dish, flying Strogg ships along their `path_corner`s, `func_timer`, `target_splash` sparks, `target_laser` beams, and Quake 2's animated, skin-fading explosion model.
- **Help computer (F1)** with the original `help.pcx`, level name, primary / secondary objectives and kills / goals / secrets, and an **intermission** at `info_player_intermission` before the next unit loads.
- **Particles** batched into one scene (camera-facing quads with per-vertex colour / alpha and a soft round sprite): bullet impacts, blood, blaster sparks, splashes, rail trails, BFG blasts, teleport fountains.
- **Savegames** (F6 / F9 quick save / load, `save` / `load <name>` in the console): the whole level state as JSON in the user config directory (`castle-config:/saves/`) — player, inventory, monsters, items, doors / plats / trains, barrels, ships, triggers, counters, timers, lasers, speakers, switchable lights, objectives.
- Drop-down **console**, **menu** with the map list read from the loaded PAKs, and a headless **autotest / demo-script harness**.

| | |
|---|---|
| ![Soldier](docs/screenshot-soldier.png) | ![Railgun](docs/screenshot-railgun.png) |
| ![Help computer](docs/screenshot-help-computer.png) | ![Barrel explosion](docs/screenshot-explosion.png) |

---

## Working in the Castle Game Engine editor

The project follows the structure of CGE's own templates (`3d_fps_game`) and the `examples/advanced_editor/custom_component` sample:

- **Views are designed, not hard-coded.** `TViewPlay` and `TViewMenu` load `data/gameviewplay.castle-user-interface` and `data/gameviewmenu.castle-user-interface` (`DesignUrl`); the viewport, camera (90° horizontal FOV), `TCastleWalkNavigation` (Quake 2 eye height 46, step 18, speed 300), `TCastleBackground`, HUD, console, menu and FPS label are published fields you can select and tweak in the editor.
- **Custom components** (`editor_units` in `CastleEngineManifest.xml`): **Quake 2 Map** (`TQuakeMap`), **Quake 2 HUD**, **Quake 2 Console**, **Quake 2 Menu**, **Quake 2 Monster Type**, **Quake 2 Named Sound**. Open the project in the editor and use *Project → Restart Editor (With Custom Components)*.
- **`TQuakePlayerMovement`** is a behavior of the camera in the play design: select *Camera → PlayerMovement* to tune run speed, jump, gravity, step size or to watch `OnGround` / `Crouched` live.
- **`TQuakeMap`** is a `TCastleTransform`: set `PakUrl` (default `castle-data:/paks/quake2_demo.pak`) and `MapName` (`demo1`, `demo2`, `demo3`, or `base1`... with a full PAK) and the level is built right in the editor viewport. Turn on `PreviewEntities` to see items and monsters as static models. Read-only `SkyName`, `EntityCount` and `FaceCount` show map info in the inspector. The game reuses this component: `TQuakeWorld` adds live entities on top of it.
- **Monster balancing in the editor.** Open `data/monsters.castle-transform`: a row of `TQuakeMonsterType`s, one per monster class, each showing its model. Select one and change `Health`, `Speed`, `Attack`, `Damage`, `AttackRange`, `AttackCooldown`, `Flying`, model, skin or sounds; the game applies the design over its built-in table at startup (a new `MonsterClass` adds a monster type).
- **Named sounds.** `data/sounds.castle-component` names every sound the code plays (`Items_pkup`, `Weapons_railgf1a`, `Doors_dr1_strt`...) as a `TCastleSound` with a `QuakePath`. Change its `Volume` / `Pitch`, or point `Url` at your own file (e.g. `castle-data:/sounds/pickup.ogg`), and the game plays that instead of the PAK sound.
- **Behaviors with published state.** Monsters (`TQuakeMonster`), items (`TQuakePickup`) and brush entities (`TQuakeMover`) are `TCastleBehavior`s attached to named transforms such as `Monster007_monster_soldier`, `Item012_weapon_shotgun` or `Mover19_func_door`. In a debug build (`castle-engine compile --mode=debug`) press **F8** to open the CGE inspector and watch `MonsterState`, `HitPoints`, `IsAlerted`, `MoverState`, `MoveProgress` and more change live.

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
| **G** | Hand grenades |
| **F1** | Help computer (objectives, kills / goals / secrets) |
| **F6 / F9** | Quick save / quick load |
| **F12** | Screenshot |
| **~** | Console (`map`, `maps`, `save`, `load`, `god`, `give all`, `give quad`, `give invulnerability`, `noclip`, `notarget`, `kill`, `fps`, `markers`, `novis`, `skill`, `lightstyle`, `record <name>` / `stop`, `spawn <class> [key value]...`, `sky <name> [rotate [x y z]]`, `quit`, `help`) |
| **F8** (debug build) | CGE inspector: hierarchy and live properties |
| **Escape** | Menu: *Single Player* (choose Easy / Medium / Hard / Nightmare), *Map Warp*, *Options* (camera, mouse sensitivity, invert mouse, view bob, field of view, sound and music volume, *Controls* to rebind keys) |

| **Touch** (phones, tablets; `--touch` on desktop) | Left thumb anywhere on the left 40 % of the screen: move stick; drag on the right: look; buttons FIRE, JUMP, DUCK, USE, WPN (next weapon), MENU; in menus tap a row to select it, tap it again to activate it (or change its value: left half down, right half up); the Android back button is Escape |
| **Gamepad** | Left stick move, right stick look, right trigger fire, A jump, B / left trigger crouch, X use, Y hand grenades, bumpers / D-pad up-down weapons, Menu menu, View help computer; in menus D-pad / left stick, A select, B back |

The movement, jump, crouch, use, fire, grenade and help keys above are the defaults; rebind them in *Options → Controls*. Options are saved with CGE's `UserConfig` and restored on the next start.

Skill works like Quake 2: it picks which entities spawn (demo1 has 18 / 21 / 33 / 33 monsters on easy / medium / hard / nightmare), halves the damage you take on easy, makes monsters attack more often from hard on, and removes their pain flinches on nightmare. The `skill <0-3>` console command changes it for the next map; savegames remember it.

---

## Building and Running

Prerequisites: [Castle Game Engine](https://castle-engine.io/) 7.0-alpha.3 or later (bundles FPC 3.2.2).

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release
.\castle-quake2.exe
```

### Android

`castle-engine package --target=android --mode=release` builds an APK for arm and aarch64 with the demo PAK inside (CGE reads it from the APK assets). CI builds it in the CGE Docker image (artifact `castle-quake2-android`, attached to releases); without `AndroidSigningProperties.txt` it is signed with a debug key, fine for sideloading (`adb install castle-quake2-*.apk`). Touch controls appear automatically on touch devices. The APK is built by CI but not yet tried on a device.

### Game data

PAKs are loaded in this order (later ones override earlier ones):

1. `data/paks/quake2_demo.pak` — the bundled shareware demo (`pak0.pak` from `q2-314-demo-x86.exe`).
2. `baseq2/pak0.pak`, `pak1.pak`, ... next to the executable — a full Quake 2 install.
3. `-basedir <quake2 dir>` (loads `<dir>/baseq2/pak*.pak`) and `-pak <file>`.

### Tests

```powershell
cd tests
castle-engine compile
.\castle-quake2-tests.exe   # parser unit tests (PAK, PCX, WAL, BSP, MD2, SP2) against the demo PAK
```

`castle-quake2 --map-report report.md` loads every map in the loaded PAKs and writes a compatibility report (load times, entity counts, unsupported and partially supported entity classes); see [`docs/map-report-demo.md`](docs/map-report-demo.md). With a full Quake 2 install (`-basedir`) it shows what the game still lacks.

CI also runs the `--autotest` demo scripts on Linux (xvfb + Mesa), uploads their screenshots, and compares an early screenshot of each demo map with `tests/reference/*.png` (`castle-quake2-tests --compare`, 64x36 block averages), so rendering regressions fail the build.

### Command line

```powershell
.\castle-quake2.exe +map demo2                 # start on a map ("base1" with the full game)
.\castle-quake2.exe -basedir "C:\Games\Quake2" # use a full Quake 2 install
.\castle-quake2.exe -gamma 1.0                 # original lightmap brightness (default 1.2)
.\castle-quake2.exe --autotest demo1 shot --demo "W:1,S,K,C:9,N:3,X,W:0.2,S,Q"
```

Demo script actions (comma separated): `W:sec` wait, `S` screenshot, `X` fire, `H` toggle hold-fire, `U` use, `C:slot` weapon, `K` give all, `Y` god, `A:deg` yaw, `T:deg` turn, `P:deg` pitch, `M:units` move, `N:i` / `I:i` / `D:i` / `R:i` stand near monster / item / brush entity / prop number i, `F` toggle the help computer, `G:x y z` go to Quake coordinates, `GO:forward side seconds` hold movement keys, `J` jump, `E:targetname` fire targets, `O:command` run a console command (e.g. `O:kill`), `V` log mover, prop and laser states, `L:map` load map, `B:key` press a key (`B:escape`, `B:down`, `B:enter`... to drive the menu), `GP:lx ly rx ry lt rt` hold a virtual gamepad's sticks and triggers (`GP:` releases), `GB:button` press a gamepad button (`south`, `east`, `west`, `north`, `lb`, `rb`, `up`, `down`, `left`, `right`, `menu`, `view`), `MV:i x y z` place monster i (Quake coordinates), `IN:time yaw pitch forward side buttons [x y z]` recorded view and inputs (see below), `SY:0` don't correct a replay's drift, `TD:x y finger` / `TM:x y finger` / `TU:finger` touch down / move / up (x, y as fractions of the window from the bottom left; with `--touch` this drives the touch controls), `Q` quit. Autotests ignore the saved options and don't save them.

**Recording a playthrough as a test.** `record <name>` in the console restarts the map with a new player and records what you do; `stop` saves it as a demo script in the user config directory (`recordings/<name>.txt`, e.g. `~/.config/castle-quake2/recordings/` on Linux) and prints the command that replays it:

```powershell
castle-quake2 --autotest demo1 bug --demo @C:\Users\me\AppData\Local\castle-quake2\recordings\bug.txt
```

The script holds one `IN:` line per change of the view or the held keys, timed on the script clock (so a slower machine doesn't fall behind), plus weapon switches, use, the help computer and console commands. Each `IN` also has the player's position: the replay logs how far it drifted (`Replay drift` in the `V` log) and puts the player back when it is more than 2 units off, so frame-rate differences don't add up (`SY:0` turns that off, to reproduce a movement bug exactly). Monsters can still act differently, as their random choices depend on the frames. Add `S` (screenshot) or `V` (state log) lines anywhere to turn the recording into a regression test.

---

## License

- Code: MIT License (matching Castle Game Engine and mariuz/castle-quake1).
- `data/paks/quake2_demo.pak` is the unmodified Quake 2 demo data © id Software, redistributed electronically free of charge under the id Software demo license in `data/paks/QUAKE2_DEMO_LICENSE.txt`, which must accompany it.
- Quake is a registered trademark of id Software / ZeniMax Media.
