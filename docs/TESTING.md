# Testing

The port is checked by machine on every push: unit tests, scripted play sessions under a virtual display, and screenshot comparisons ([`.github/workflows/build.yml`](../.github/workflows/build.yml)). You can use the same tools to reproduce a bug, check a change, or turn a playthrough into a test.

## Unit tests

`tests/` is a separate console project (it uses the game's units from `../code/`). It runs about 370 checks against the bundled demo PAK. They cover:
- the file formats: PAK, PCX, WAL, BSP and QBSP, MD2, SP2;
- the map queries: contents, PVS, PHS, areas, light, traces;
- the game tables: monster attacks and moves, gun timing, gibs, settings, gamepad mapping;
- the level compiler and the random level generator;
- mod loading.

```powershell
cd tests
castle-engine compile
.\castle-quake2-tests.exe     # run from tests/: it loads ../data/paks/quake2_demo.pak
```

It prints `N passed, M failed` and exits with an error when something fails.

## Scripted play sessions (autotests)

`--autotest <map> <prefix> --demo "<script>"` loads a map, plays the script and quits; screenshots go to `<prefix>_1.png`, `<prefix>_2.png`... and everything else to the log. Autotests use the default options (your saved options are neither read nor changed) and turn mouse look off, so results don't depend on your machine.

```powershell
.\castle-quake2.exe --autotest demo1 shot --demo "W:1,S,K,C:9,N:3,X,W:0.2,S,Q"
.\castle-quake2.exe --autotest demo1 shot --demo @myscript.txt   # a script file: commas or one action per line
```

On Linux without a display, run under `xvfb-run -a -s "-screen 0 1600x900x24"`, as CI does.

| Action | What it does |
| --- | --- |
| `W:sec` | Wait |
| `S` | Screenshot (logs the FPS and the camera too) |
| `V` | Log the state: movers, props, lasers, monsters, the gun, the player (health, position, `player stuck`) |
| `Q` | Quit |
| `X`, `H` | Fire once; toggle holding fire |
| `U`, `F`, `J` | Use; toggle the help computer; jump |
| `C:slot` | Select a weapon (1 Blaster .. 10 BFG, 11 hand grenades); wait about 1 s before firing it |
| `K`, `Y` | Give everything; god mode |
| `A:deg`, `T:deg`, `P:deg` | Absolute yaw, turn, pitch |
| `M:units`, `GO:forward side seconds` | Move along the view; hold movement keys |
| `G:x y z` | Go to Quake coordinates |
| `N:i`, `I:i`, `D:i`, `R:i` | Stand near monster, item, brush entity or prop number i |
| `MV:i x y z` | Place monster i at Quake coordinates |
| `E:targetname` | Fire the entities with that targetname |
| `O:command` | Run a console command (e.g. `O:notarget`, `O:spawn monster_soldier`, `O:randmap 7`, `O:editor generate 3`) |
| `L:map` | Load a map |
| `B:key` | Press and release a key (`B:escape`, `B:down`, `B:enter`... to drive the menu) |
| `GP:lx ly rx ry lt rt`, `GP:` | Hold a virtual gamepad's sticks and triggers; release them |
| `GB:button`, `GH:button` | Press a gamepad button; hold / release one (`south`, `east`, `west`, `north`, `lb`, `rb`, `ls`, `rs`, `up`, `down`, `left`, `right`, `menu`, `view`, `share`) |
| `TD:x y finger`, `TM:x y finger`, `TU:finger` | Touch down / move / up (window fractions from the bottom left; run with `--touch` to show the touch controls) |
| `IN:time yaw pitch forward side buttons [x y z]` | A recorded view and held inputs (see below) |
| `SY:0` | Don't correct a replay's drift |

The `spawn <classname> [key "value"]...` console command adds any entity in front of the player (or at `origin`), which is how entities the demo maps lack get tested; brush entities take a box from `mins` / `maxs`.

### Recording a playthrough as a test

`record <name>` in the console restarts the map with a new player and records what you do. `stop` saves it as a demo script in the user config folder (`recordings/<name>.txt`: `~/.config/castle-quake2/` on Linux, `%LOCALAPPDATA%\castle-quake2\` on Windows) and prints the command that replays it:

```powershell
castle-quake2 --autotest demo1 bug --demo @C:\Users\me\AppData\Local\castle-quake2\recordings\bug.txt
```

What the script holds:
- one `IN:` line per change of the view or the held keys, timed on the script clock, so a slower machine doesn't fall behind;
- weapon switches, use, the help computer and console commands.

Each `IN` line also stores the player's position. On replay, the drift is logged (`Replay drift` in the `V` log), and the player is put back when more than 2 units off, so frame-rate differences don't add up. `SY:0` turns that correction off, to reproduce a movement bug exactly. Monsters can still act differently, since their random choices depend on the frames.

Add `S` (screenshot) or `V` (state log) lines anywhere to turn the recording into a regression test.

## Screenshot comparison

```powershell
.\castle-quake2-tests.exe --compare reference.png shot.png diff.png [limit]
```

The tool averages both images into 64 × 36 blocks and fails when the mean channel difference is above the limit (default 3). Identical runs differ by less than 1, and a 10° turn by about 6. CI compares a calm early shot of each demo map with `tests/reference/*.png`, so rendering regressions fail the build.

After an intended visual change:
1. delete the affected reference;
2. commit the one CI creates (artifact `autotest-screenshots`).

The references come from CI's software renderer, and Windows shots differ from them by up to about 4, so don't regenerate them locally.

## Map compatibility report

```powershell
.\castle-quake2.exe --map-report report.md
.\castle-quake2.exe -basedir "C:\Games\Quake2" --map-report full.md      # a full install
.\castle-quake2.exe -basedir "<dir>" -game q1q2 --map-report cotv.md      # a mod
```

The report loads every map in the loaded data and lists load times, entity counts, and the unsupported and partly supported entity classes. [`map-report-demo.md`](map-report-demo.md) is the demo's; CI fails if a demo map gets an unsupported class. Run it on the full game or a mod to see what's still missing.

## Running the CI checks locally

The `autotest` job's steps in `.github/workflows/build.yml` are plain shell. On Linux with Mesa and `xvfb-run`, you can run them from the repository root after `castle-engine compile` (and building the tests). Each step greps the log for what it expects and prints `::error::` on failure.

## Checking exported levels in another engine

See [LEVELS.md](LEVELS.md#playing-exported-levels-in-other-quake-2-engines). `CLAUDE.md` has the recipe for Yamagi Quake II under a virtual display.
