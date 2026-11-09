# Game data, mods and the Castle Game Engine editor

## Game data

Data is loaded in this order, each source over the earlier ones:

1. `data/paks/quake2_demo.pak`: the bundled shareware demo (`pak0.pak` from `q2-314-demo-x86.exe`).
2. The `baseq2` game folder: next to the executable, in `rerelease/` (Quake II Remastered's layout), and in `-basedir <dir>` (also `<dir>/rerelease/`). The PAKs right in `-basedir` load too.
3. The mod folder given by `-game <folder>` (or `+set game <folder>`), looked up in the same places.
4. `-pak <file>`: any extra PAK.

A game folder is loaded whole, in this order:
1. `pak0.pak` .. `pak9.pak`;
2. its `.pkz` archives (zips, Quake II Remastered's mod packages);
3. its loose files.

Each layer overrides the one before it. Loose files and zip entries are read only when first used.

Quake II Remastered's 32-bit textures (`textures/<name>.png` or `.tga`) replace the `.wal` images, keeping the WAL's size for the texture scale; a texture with only a PNG / TGA uses the image's size. Maps can be standard IBSP or the extended QBSP format (ericw-tools `-qbism`).

## Mods

`-game <folder>` (or `+set game <folder>`, as in Quake 2) loads a mod's folder next to `baseq2` over it. [Call of the Void](https://www.moddb.com/mods/quake-ii-call-of-the-void), the Quake 1 / 2 crossover for Quake II Remastered, installs as `rerelease/q1q2`:

```
castle-quake2 -basedir "C:\Program Files (x86)\Steam\steamapps\common\Quake 2" -game q1q2 +map q2e1start
castle-quake2 -basedir <same> -game q1q2 --map-report cotv-report.md   # what the mod's maps still need
```

What works: its maps (IBSP or the extended QBSP format), textures (PNG / TGA), models and sounds load; its Quake 1 and hybrid monsters (dogs, ogres, knights, fiends, shamblers, scrags, vores, grunts, the `_strogg` / `_prototype` hybrids, the bosses) spawn with their model and health and fight with the generic monster AI (one attack each: melee, grenades, lasers, bolts, homing pods or lightning, by kind). Its keys work too (the Quake 1 gold / silver keys and runes, and Quake II Remastered's new keys). Not yet: the monsters' own animations and attack sequences, the mod's new weapons, items and special entities (the map report lists them), and Quake II Remastered's own new features.

To see what any mod or full install still lacks, run the map report: `castle-quake2 -basedir <dir> [-game <mod>] --map-report report.md` (see [TESTING.md](TESTING.md)).

## Working in the Castle Game Engine editor

The project follows the structure of CGE's own templates (`3d_fps_game`) and the `examples/advanced_editor/custom_component` sample:

- **Views are designed, not hard-coded.** `TViewPlay` and `TViewMenu` load `data/gameviewplay.castle-user-interface` and `data/gameviewmenu.castle-user-interface` (`DesignUrl`); the viewport, camera (90° horizontal FOV), `TCastleWalkNavigation` (Quake 2 eye height 46, step 18, speed 300), `TCastleBackground`, HUD, console, menu and FPS label are published fields you can select and tweak in the editor.
- **Custom components** (`editor_units` in `CastleEngineManifest.xml`): **Quake 2 Map** (`TQuakeMap`), **Quake 2 HUD**, **Quake 2 Console**, **Quake 2 Menu**, **Quake 2 Monster Type**, **Quake 2 Named Sound**. Open the project in the editor and use *Project → Restart Editor (With Custom Components)*. `TQuakeMap.MapName` has a dropdown of the PAK's maps, `PakUrl` / `LevelUrl` open file dialogs, and right-clicking the map in the hierarchy offers *Reload Map*. With *PreviewEntities* / *PreviewMarkers* on, every entity is listed under *EntityPreview*: select one to see its class, targetname, target, spawnflags and all its keys (*Fields*).
- **`TQuakePlayerMovement`** is a behavior of the camera in the play design: select *Camera → PlayerMovement* to tune run speed, jump, gravity, step size or to watch `OnGround` / `Crouched` live.
- **`TQuakeMap`** is a `TCastleTransform`: set `PakUrl` (default `castle-data:/paks/quake2_demo.pak`) and `MapName` (`demo1`, `demo2`, `demo3`, or `base1`... with a full PAK) and the level is built right in the editor viewport. Turn on `PreviewEntities` to see items and monsters as static models. Read-only `SkyName`, `EntityCount` and `FaceCount` show map info in the inspector. The game reuses this component: `TQuakeWorld` adds live entities on top of it.
- **Monster balancing in the editor.** Open `data/monsters.castle-transform`: a row of `TQuakeMonsterType`s, one per monster class, each showing its model. Select one and change `Health`, `Speed`, `Attack`, `Damage`, `AttackRange`, `AttackCooldown`, `Flying`, model, skin or sounds; the game applies the design over its built-in table at startup (a new `MonsterClass` adds a monster type).
- **Named sounds.** `data/sounds.castle-component` names every sound the code plays (`Items_pkup`, `Weapons_railgf1a`, `Doors_dr1_strt`...) as a `TCastleSound` with a `QuakePath`. Change its `Volume` / `Pitch`, or point `Url` at your own file (e.g. `castle-data:/sounds/pickup.ogg`), and the game plays that instead of the PAK sound.
- **Levels in the editor.** Set `TQuakeMap.MapName` to `rand42` to see random level 42, or `LevelUrl` to a level saved by the in-game editor (e.g. `castle-config:/levels/mylevel.json`) to see it compiled in the viewport. The 2D editor itself is a component too (**Quake Level Editor**, `TQuakeLevelEditor`, with `LevelUrl`).
- **Behaviors with published state.** Monsters (`TQuakeMonster`), items (`TQuakePickup`) and brush entities (`TQuakeMover`) are `TCastleBehavior`s attached to named transforms such as `Monster007_monster_soldier`, `Item012_weapon_shotgun` or `Mover19_func_door`. In a debug build (`castle-engine compile --mode=debug`) press **F8** to open the CGE inspector and watch `MonsterState`, `HitPoints`, `IsAlerted`, `MoverState`, `MoveProgress` and more change live.
