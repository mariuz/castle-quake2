# Random levels and the level editor

New Quake 2 levels without any tools: endless random levels, and a grid editor inside the game. Both compile, at runtime, into real Quake 2 maps (BSP tree, brushes for collision, lightmaps, visibility), so everything in the game works in them, and you can export them for other Quake 2 engines.

## Random levels

Pick *Random Level* in the menu, or type `randmap [seed]` in the console. Every seed makes its own level; the same seed always makes the same one (`rand<seed>` is its map name, so `+map rand42` or `map rand42` works too). The generator follows classic Quake and Doom layout rules:

- **Layout:** rooms of varied size linked into loops, not dead-end trees; low corridors that climb on slopes between high rooms; windows from one area into another; round rooms and rooms with cut corners.
- **Height:** big rooms get pillars for cover, raised platforms, sunken pools, slime and lava pits; rooms far higher or lower are reached by lifts or ladders.
- **Outdoors:** some rooms open to the sky, and big ones become outdoor areas with grass or rock and rolling ground.
- **Progress:** some corridors have doors; the exit is locked behind a switch or a blue key, and often the blue key lies in a vault only the red key opens.
- **Monsters:** they grow tougher along the way; some only appear on harder skills or wait in ambush, and in some rooms more appear as soon as you walk in.
- **Pickups:** weapons come in order of strength, with ammo after them and health after the fights.
- **Light:** some rooms have flickering or pulsing lights.
- **Secrets:** a secret room hides behind a wall that opens when you shoot it, with a reward and a teleporter back to the start.
- **The exit** leads to the next random level.

## The level editor

Open *Level Editor* in the menu, or type `editor` in the console. It's a top-down grid of 64-unit cells: paint walls and floors, raise or lower floors and ceilings, then press *Play* to compile the level and drop into it at once.

What you can add:
- **Moving parts:** doors, lifts, buttons that open the doors of their switch channel, doors locked with a blue or red key, secret doors that open when shot.
- **Shape:** ladders, ramps (real slopes), diagonal walls, round rooms (`editor round`), breakable glass windows, rolling hills for outdoor areas, cells open to the sky.
- **Liquids:** water, slime and lava.
- **Looks:** texture themes; with the full game, every texture set in its PAKs becomes a theme too.
- **Entities:** the player start, lights, monsters, weapons, ammo, health, armor, barrels, keys, teleporters (each goes to the destination of the same number) and the exit.
- **Inspecting:** the *Inspect* tool shows a placed entity's keys; `editor set <key> <value>` changes them.

The editor has undo. It can generate a random level to start from, and saves and loads levels as `castle-config:/levels/<name>.json`. *Export* writes the Quake 2 `.bsp` (see below).

### Editor controls

| Input | Action |
| --- | --- |
| Left mouse | Paint with the current tool (drag to paint) |
| Right mouse | Erase |
| Middle mouse (or Alt + left) | Pick a cell's heights and theme |
| **1** – **0** | Tools: Floor, Wall, Raise, Lower, Ceil+, Ceil-, Sky, Theme, Entity, Erase |
| **O**, **U**, **H**, **J** | Door, water, lift, button tools |
| **M**, **I**, **R**, **K** | Slime, lava, ladder, key door tools |
| Toolbar only | *Hills*, *Ramp*, *Window*, *Diagonal*, *Secret* (secret door), *Inspect* |
| **V / B** | Water depth |
| **, / .** | Lift height |
| **C** | Switch channel (buttons open the doors of their channel) |
| **Y** | Key door colour (blue / red) |
| **PageUp / PageDown**, **Home / End** | Brush floor height, brush ceiling height |
| **T** | Next texture theme |
| **[ / ]**, **Q / E** | Entity type; turn the entity |
| Arrows / WASD, wheel / + / -, **F** | Pan, zoom, fit the level in view |
| **Ctrl+Z** | Undo |
| **G**, **N** | Generate a random level, new empty level |
| **P** | Play: compile the level and start it |
| **Ctrl+S**, **L** | Save, load the next saved level |
| **X** | Export the `.bsp` |
| **Escape** | Back to the menu |

### Editor console commands

Everything the editor does can also be typed in the console (and used in test scripts as `O:editor ...`):

```
editor new | generate [seed] | save [name] | load <name> | play | export | close
editor name <name> | tool <tool> | entity <class> | brush <floor> <ceil> <theme>
editor channel <0-9> | lift <height> | key <blue|red>
editor fill <x0> <y0> <x1> <y1> | round <x0> <y0> <x1> <y1>
editor select <x> <y> | set <key> <value> | unset <key>
```

## Playing exported levels in other Quake 2 engines

*Export* (or `editor export`) writes the map to the user config folder as `maps/<name>.bsp`, plus, for a level with lava, the lava texture it needs (`textures/castle/lava.wal`, which this port generates). That folder has the layout of a Quake 2 game folder: copy `maps/` and `textures/` into your `baseq2` and run `map <name>` in the other engine. The textures themselves come from the Quake 2 data you already have (the shareware demo's are enough).

A level's exit leads to the next random level (`rand<seed+1>`), which only this port can make, so the exported map's exit leads back to the map itself: the other engine restarts it, keeping your inventory. The saved level is not changed.

Exported random levels have been checked in **Yamagi Quake II** with its software and OpenGL renderers:
- they load, and every wall, floor, water surface and ladder is drawn;
- `rand8`'s key hunt plays through: the red and blue key doors say "You need the Red Key" / "You need the Blue Key" until you carry the key, then open; the secret area counts; the exit restarts the map.

Other engines have not been tried yet.

Where the user config folder is: `~/.config/castle-quake2/` on Linux, `%LOCALAPPDATA%\castle-quake2\` on Windows.

## Levels in the Castle Game Engine editor

Set `TQuakeMap.MapName` to `rand42` to see random level 42 in the CGE editor's viewport, or `LevelUrl` to a level saved by the in-game editor (e.g. `castle-config:/levels/mylevel.json`). The 2D editor itself is a component too (**Quake Level Editor**, `TQuakeLevelEditor`).

How the compiler and the generator work: [ARCHITECTURE.md, section 6c](ARCHITECTURE.md).
