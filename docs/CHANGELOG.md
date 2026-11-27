# Changelog

## Unreleased

- Join another game (roadmap E.4, first step): `+set port N` (or `host` in the console) lets other instances join this game over UDP, and `+connect address:port` (or `connect`) joins one. The joining game loads the host's map and shows its players and monsters from the host's snapshots, with its own HUD, gun and prediction. Doors and lifts don't move for it yet and it hears none of the host's sounds; the two-instance web page comes next.
- Bots (roadmap E.3): `addbot [skill]` in the console or `+set bots N` on the command line adds players that play by themselves: they fight the other players in deathmatch (monsters in single player) with a reaction time and aim by skill 0..3, choose weapons by distance, pick up what they lack, wander around walls, drops and lava, and respawn. They find each other only by sight (no routes yet).
- Deathmatch rules (roadmap E.2): `+set deathmatch 1` (or `deathmatch 1` in the console, then load a map) spawns players at the deathmatch spots without monsters, counts frags (shown at the top right, death messages for everyone), brings picked items back after 20 to 300 seconds and respawns a dead player when they press fire. `dmflags` supports no health, no powerups, weapons stay, no falling damage, spawn farthest, forced respawn, no armor and allowed exits. Other players are still test clients from the console (`addclient`); bots come next.
- More than one player on the server (roadmap E.2): the world keeps a list of players and runs each one's part of the game; `addclient` in the console adds a player without a view (shown as a soldier on the demo), `clientinput` moves it and `removeclient` takes it away. Monsters go for the nearest player.
- Fixed: standing near a spinning brush (`func_rotating`, the fans in demo1) could throw the player tens of units in one frame: its pushes come from a box around the rotated model, and from a spinning brush a push over 16 units is now ignored as one that caught the player from afar.
- First step of multiplayer (roadmap E.1): inside the game, the view and the simulation now talk like a Quake 2 client and server, over a channel in the same process. Your inputs go to the server as commands (fire, use and weapon switches act through them), and after every tick the server sends back a delta-coded snapshot of the player and of everything in view (about 60 bytes on demo1). The server moves the player with Quake 2's pmove and the view predicts its own moves from the snapshots, so they match exactly (on lifts the view catches up a few units). Console cheats, `spawn` and the test scripts' actions are server commands too. Monsters, items, props and projectiles are drawn from the snapshots, smoothly between ticks (`clientdraw 0` or `--server-draw` draws the server's own models instead). Single player plays as before; CI checks that every snapshot arrives intact.
- Dynamic lights on models: muzzle flashes, rockets, explosions and the remaster's `dynamic_light` now light monsters, items, props and the gun per pixel, every frame, brightest on the side facing the light (the 4 nearest lights, like the walls). Before, a model took one flat colour updated ten times a second, so short flashes were often missed.

## v0.33.0 — 2026-11-22

- Fixed: with a render scale below 100 % the world could be drawn at half its light on some OpenGL drivers (Mesa 22): the lightmaps' 2× overbright is now applied to the lightmap sample in the shader instead of through a material colour above 1.
- `QuakeWorld`'s methods are split into include files by subsystem (no change in behaviour).
- Ground Zero's stalker plays dead: below a quarter of its health a hit may make it fall over (off the ceiling too), twitching while it heals back (1 health a tenth of a second, 2 on hard, 3 on nightmare), getting up at full health or when hit again. Hurt by more than 10, or dodging a shot, it jumps straight up and clings to the ceiling when there's a flat one within 256 units (from the ceiling it drops down). Turrets with a blaster or rockets that lose the player shoot blind at the spot he was last seen: at once, then after a few seconds more, then not again until they see him.
- Monsters whose Quake 2 box doesn't start 24 below their origin are drawn at the right height: the chick (and the heat chick), the flipper, the supertank (and boss5), the hornet boss, Jorg and the Makron no longer float 24 units above the floor, the tank 8 and the stalker 6.
- Ground Zero's bosses: the carrier (2000 to 4000 health by skill; machineguns, grenades, the railgun, rockets, flyers it launches, which don't count as kills; it blows up when killed), the Widow (2000 to 5000; a blaster, the railgun, a kick and stalkers; killed, she beams out and leaves her legs) and her second form (2800 to 5800; a heat beam, a homing disruptor shot, her tongue and stalkers; killed, her stalkers die with her and she blows up). On nightmare both Widows have power shields. Ground Zero's map report has no unsupported class any more.
- Ground Zero's tesla mines (`ammo_tesla`, slot 19 on the G key): thrown like a grenade (farther the longer you hold fire), a mine lands, opens after 3 s and for 30 s zaps the monsters it can see within 128 units with lightning, 3 damage a tenth of a second, then blows up (in water at once). Ground Zero's map report now lists only the carrier and the Widow.
- Ground Zero's weapons and items: the chainfist, ETF rifle, prox launcher and plasma beam (slots 15 to 18, chained on the 1, 4, 6 and 8 keys), flechettes and prox mines; double damage, IR goggles and the defender sphere, used on pickup. As in Ground Zero's single player, the disruptor, the A-M bomb, the hunter and vengeance spheres and the doppelganger are left out, and so are the maps' nailguns and `weapon_heatbeam`s, which aren't in its item list.
- Ground Zero's monsters: the turret (blaster, machinegun or rocket, on a wall, floor or ceiling; it aims within its mounting and fires when it points at you, a wall unit comes out of the wall when triggered; it explodes when killed), the stalker (on the ceiling it walks upside down and shoots from there, then drops; on the floor it pounces, claws and shoots green bolts), the daedalus (a hover with a power screen, 450 health) and the medic commander (600 health; revives the dead like the medic and calls up to its skill's number of reinforcements, which don't count as kills). The pack's map report now lists only the carrier and the Widow among its monsters.
- Ground Zero's map entities (`-game rogue`): `func_plat2` lifts go to the other end when you step in their field or use them, wait 5 s when called (or 2 s back to their resting end), and fire their targets at each end; monsters that lose you at your last seen spot follow the level's `hint_path` chains to near you; `target_steam` blows steam (for its `wait` seconds), `target_anger` makes monsters shoot at a spot until you hurt them, `target_killplayers` kills you and the monsters you can see, `trigger_disguise` hides you from monsters' sight, `misc_nuke_core` shows and hides, and the Widow's room has its orbs. The pack's map report lists only its monsters, weapons and items as unsupported now.
- The fixbot roams: placed to roam (as in The Reckoning's maps) it flies to the farthest point it can see, rests, and looks again, welding the repairs and reviving the dead it finds on the way; placed to land it goes down to the floor first, placed to take off it rises 128 units in a cloud of puffs. The gekk's box is Quake 2's 48 × 48 × 48, 8 lower while it swims.
- The gekk swims: in water it moves in three dimensions without leaving the water, plays its swim, water attack (two bites, two claws), pain and death frames, and when you are out of the water it leaps out after you (from your height when there is room), back to its land attacks. The fixbot welds: it flies to a `func_object_repair`, welds it in sparks (with the welder's sounds) until it is repaired, which fires the repair's targets; repaired, the object stops sparking until it has healed. The fixbot also revives dead monsters like the medic, with its laser from close by, the longer the heavier and deader the monster.
- The Reckoning's props: spinning red alarm lights (`rotating_light`: on / off by use, the alarm sound every second, shot down in welding sparks), the pulsing lasers of the last level (`target_mal_laser`: they hurt every `wait` + 0.1 s, straight through monsters and the player), the vipers' missiles (`misc_viper_missile`), the transport ship (`misc_transport`), the nuke (`misc_nuke`: every monster gone, the player killed), welding sparks (`func_object_repair`) and Mal's ambient sound (`misc_amb4`). The pack's map report has no unsupported class any more. The `V` log shows whether a prop's light is on and each laser's class and pulses.
- Particles are moved on the GPU: the particle mesh is sent to the graphics card only when particles appear, and a vertex shader moves, grows, fades and turns them to the camera, instead of the whole mesh being rebuilt and sent every frame. They look the same.
- A fixed game tick: monsters, triggers, projectiles, the gun and items now run 40 times a second whatever the frame rate (a slow or very fast machine plays the same game), and monsters, items, props and projectiles are drawn between their last two ticks, so they still move smoothly at 60, 144 or 240 frames a second. The player, lifts, doors and particles still move every frame. A frame that takes too long runs at most 20 ticks (half a second), so the game slows down rather than jumping ahead after a stall.
- Monsters skip a line-of-sight trace when the map's visibility data says the two places can't see each other (the same answer, without the trace). The benchmark line now also gives the world traces per frame and their time, and `--region-size <units>` changes the world's culling regions to compare culling with draw calls; CI's table adds demo1 at region sizes 512 and 2048.
- Render scale: *Options → Render Scale* (30 % to 100 %, at once), `renderscale <25..100>` in the console and `--render-scale <percent>` on the command line draw the 3D view (the world, the models and the gun) at a lower resolution and scale it up to the window, while the HUD, console and menu stay sharp. Smooth Textures also smooths the scaling. For phones, slow GPUs and big screens; CI's benchmark table adds demo1 at 50 %, and a shot at 50 % keeps the same framing as one at full resolution.
- An installed Quake II is found by itself: GOG (Galaxy's registry, `GOG Games` folders), Steam (all libraries) and common folders, Quake II Remastered first. `-basedir auto` / `gog` / `steam` ask for it (autotests and the map report too), `--no-detect` keeps the demo. `castle-quake2-tests --retail auto` checks the full game's monster tables against the installed PAK. Checked on GOG's Quake II: all 65 maps load, base1 plays, Ground Zero loads with `-game rogue`.
- The full game's last unsupported classes: the insane marines (`misc_insane`: on the player's side, never counted as kills, standing, fidgeting, screaming, walking their paths, crawling or hanging crucified and struggling), the commander's body on lab (comes alive when used), the standing Makron on boss1 (`monster_boss3_stand`, teleports away), `target_temp_entity` (explosions, the boss teleport, sparks...), the Ancient Head (city3's secret: 2 more max health), the mine lamps (`light_mine1` / `light_mine2`), `func_wall`'s TRIGGER_SPAWN / TOGGLE / START_ON and falling `func_object`s. The retail map report now has no unsupported class.
- Monsters with an `item` key drop it when they die (Quake 2's `monster_death_use`: soldiers' ammo, the insane marines' grenades and shells); drops are kept in savegames.
- The bosses blow up when they die, like Quake 2's BossExplode: the supertank, the hornet, Jorg and The Reckoning's boss end their death with 8 explosions around the body, 0.1 s apart, then meat, metal and a gear fly and the body is gone.
- Quake II Remastered's `turret_invisible_brain`: a turret driver without a body. It aims the `turret_breach` its `target` names at its `killtarget` whenever the breach has a clear line to it, fires after `delay` (or 3 − skill) seconds, can't be killed, starts at once or when used (a second use stops it), and stops when its enemy dies. A breach's `count` sets its rockets' damage.
- Quake II Remastered's compass and landmarks: `target_poi` sets the point of interest (teams, stages, NEAREST, DUMMY, DISABLED); `compass` in the console shows it for 5 seconds as a marker with its distance (also while the help computer is open). A `target_changelevel` aimed at an `info_landmark` keeps the player's place and view relative to it, so the next map puts you at the same spot by its landmark of that name.
- The Reckoning (`-game xatrix`), its monsters: the ion ripper, hyperblaster and laser soldiers, the heat-seeking chick, the beta gladiator (plasma, a power shield), its boss (`monster_boss5`: a supertank with a power shield and heat-seeking rockets), the gekk (claws, spit, the leap, its own gibs) and the fixbot (a flying blaster). Bouncing ion ripper bolts, blue bolts, gekk spit, heat-seeking rockets and plasma balls. All 88 maps (the base game's and the pack's) play through; its props are next. Facts from id's game code of the pack (GPLv2), no code copied.
- The Reckoning's weapons and items: the ion ripper (`weapon_boomer`: bouncing bolts, 2 cells a shot), the phalanx (two plasma balls for one mag slug, with splash), traps (thrown like hand grenades; one opens on the floor, pulls in the nearest monster it sees within 256 and, if it weighs under 400, swallows it and leaves a food cube of a tenth of its mass in health, over your maximum), mag slugs and DualFire (`item_quadfire`: for 30 s the gun runs at twice its frame rate). The 8 key switches between the hyperblaster and the ion ripper, 9 between the railgun and the phalanx, G between grenades and traps. `K` gives them when the pack is loaded. CI checks them on the demo maps.
- `hurt <monster index | last> <damage>` in the console (tests).
- Fixed: starting on a map that doesn't exist (a mistyped name or game folder) crashed in the first frame; the game now says it couldn't load the level and the menu and console work. An autotest whose map is missing logs it and quits with exit code 1 instead of hanging.
- Fixed: monsters could walk into walls. A step's swept trace stops at the floor the monster stands on, so it missed a ledge or angled wall the box overlapped higher up; a step to a spot that overlaps solid is now refused (`ClearToMoveTo`). Closing doors and other movers push flying monsters too (city2's door swallowed two floaters). Checked with a state dump after every move on eight full-game maps: no monster inside anything.
- The autotests' "monsters in solid" count (and `tests/retail-playthrough.ps1`'s InSolid column) only counts monsters really inside something: on the full game it flagged monsters the maps place exactly against a wall and ones a train left 1/32 unit away, which aren't stuck (they walk off; Quake 2 doesn't report them either). Each one reported is named with what it overlaps and the nudge that frees it.
- Random levels on the full game: the level themes found in its PAKs are checked; the `test` folder (id's number textures) is no theme any more, near-black textures aren't used for floors, walls or ceilings (e1u4's dark metal made black rooms), and computer-bank textures aren't used as walls (e3u2 rooms were walls of screens; they get its hall panels).
- Compared with Yamagi Quake II on the 39 single-player maps: the same kill / goal / secret totals on every help computer, and the same start views. Fixes found that way:
  - Doors that open by themselves no longer close on a player standing in the doorway: their trigger field stays where the closed door was, like Quake 2's (it used to move up with the door, so the door shut after 3 seconds and opened again).
  - Maps whose starts all have names (entered from another level) start where Yamagi does when loaded directly (`map waste2`, *Map Warp*): mine1–mine4, power2, waste1, waste2 and city2 use the start from the previous level instead of the first one.
  - `func_object`s fall onto floors only (Quake 2 tosses them with `MASK_SOLID`), so mine4's rocks no longer crush the player at the start.
  - *Options → Widescreen View* (`horplus` in the console): **Hor+** keeps a 4:3 view's height and shows more at the sides on wide screens, like Yamagi and Quake II Remastered (fov 90 is 106° wide at 16:9); it is the default now; **Fixed** keeps the original game's 90° width. The CI reference screenshots are made anew with it.
- Fixed: maps with lava or water on doors and other moving brushes logged "X3D node Effect is already part of another TCastleScene" (each brush model has its own warp effect now).
- Testing on retail data: `tests/retail-playthrough.ps1` plays every map of an installed game; `tests/yamagi-compare.ps1` takes the same shots in Yamagi Quake II; `--log-file <file>` keeps parallel runs' logs apart, `--no-sound` turns audio off and `--offscreen-shots` takes autotest screenshots from a framebuffer (so the tests run minimized); the `V` log adds kill / secret / goal totals; autotest placements check the spot against the brushes (a player placed over a render-only floor fell out of biggun).

## v0.32.0 — 2026-11-20

The browser build draws at a sensible resolution on phones and takes `?scale=`, and every setting in its address now arrives. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Browser build: on high-density screens (phones, tablets, retina laptops) the game no longer draws at the screen's full pixel count (3× the page size on many phones, 9× the pixels): it draws at most at 1.5× and 1920 × 1080 in all, and the browser scales the picture up. `?scale=0.5` in the address draws at half resolution on top (in CI's software rendering 27 instead of 9 frames a second); `?fullres=1` turns the limits off.
- Fixed: the first setting in the web address was ignored (`?map=demo1` stayed in the menu, `?skill=0&map=demo2` played at the saved skill). CI now checks that the skill arrives.

## v0.31.0 — 2026-11-12

Smooth Textures and Brightness options. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Two video options in *Options*: *Smooth Textures* (filtered textures instead of Quake 2's sharp pixels) and *Brightness* (the lightmap gamma, 0.8 to 2.0; before only `-gamma` on the command line, which still wins). Both apply when a map is loaded and are saved with the other options. CI checks that they change the picture.
- Roadmap: the remaster's fog is parked until its density can be checked against the real game (its renderer, which turns `fog_density` into fog, is not in id's released source).

## v0.30.0 — 2026-11-12

Doors spawned from the console are solid and can be shot. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Doors spawned from the console (`spawn func_door ... mins "..." maxs "..."`, also `func_door_secret` / `func_door_secret2`) are solid: they block the player and monsters and can be shot, so a secret door without a targetname opens when hit, as on a real map. Before, shots and players went through them, so only compiled maps could test shootable doors. CI shoots one.
- Roadmap: model animation on the GPU was tried and parked (the engine sets effect uniforms per shader program, shared by all models; the benchmark gained only 2–6 %).

## v0.29.0 — 2026-11-11

The browser build is tested before it is published, and takes settings from its address (`?map=demo2&skill=2&fps=1`). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- The browser build is tested before it is published: the `web` workflow opens it in headless Chromium, starts a game from the menu, and fails on shader errors, WebAssembly exceptions or no map; the load time and frame rate (software WebGL) go to the run's summary. `tests/web/smoke.js` does the same on any build folder or on the published page. See [TESTING.md](TESTING.md#the-browser-build).
- The web build is sturdier: the GitHub Pages deploy is retried once when GitHub doesn't answer (it timed out twice for v0.24.0), and its toolchain install skips 100 MB of recommended packages and retries (a mirror answered 404 during v0.28.0).
- Settings in the web page's address: `?map=demo2&skill=2&fps=1` (also `touch=1`, `gamma`, and `demo=<script>` to run a test script) opens that map at that skill with the frame rate shown, without the menu. On the desktop `+set skill <0-3>` and `--fps` do the same. CI opens the built page with such an address too.

## v0.28.0 — 2026-11-11

A benchmark that CI runs on every change, and scripted runs that can't hang at shutdown any more. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- A benchmark: `--benchmark <map> <prefix>` plays a fixed tour of the map and logs frame time percentiles (p50, p95, p99, max), the game logic's share and the shapes drawn; the demo script actions `BS` / `BE` time any part of a script. CI benchmarks the three demo maps and shows the table in each run's summary. See [TESTING.md](TESTING.md#benchmark).
- Scripted runs (autotests, `--map-report`, benchmarks) end even if shutdown hangs: 20 s after quitting a watchdog ends the process and says so. CI waited 10 minutes for such a run during v0.26.0's release; it now passes with a warning instead.

## v0.27.0 — 2026-11-11

The mission pack's secret door (`func_door_secret2`), exported lifts and switches checked in Yamagi Quake II, and a roadmap for performance, graphics, the web build and networking. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- `func_door_secret2`, the mission pack's secret door (in Quake II Remastered and used by Call of the Void): it slides sideways, pauses, then back (or forward with its flag, or those two the other way round with 1ST_DOWN), waits 5 s or its `wait` and comes back, or stays open with OPEN_ONCE; it opens when shot unless it has a targetname (then with ALWAYS_SHOOT).
- Checked in Yamagi Quake II: an exported level's lift (`func_plat`) carries you up and its switch (`func_button`) opens the doors it is wired to, like in this port.

## v0.26.0 — 2026-11-10

Multi-floor elevators (`trigger_elevator`) and Quake II Remastered's `dynamic_light`. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- `trigger_elevator` (the full game's multi-floor lifts): each floor's button names a `path_corner` in its `pathtarget`, and the elevator sends its `func_train` there, unless the train is moving. Trains now stop at a `wait -1` corner, and only stop when used again if they have the TOGGLE flag, like Quake 2's `train_wait` / `train_use`. The demo maps have neither, so they play as before.
- Quake II Remastered's `dynamic_light`: a light drawn at run time with its `shadowlightradius`, colour (`rgba` or `_color`), `shadowlightintensity` and light style (`shadowlightstyle`, or the style of the light named by `shadowlightstyletarget`); a targetname switches it on and off, and START_OFF starts it off. Kept in savegames.
- The map report lists the remaster's `target_poi` (compass targets; there is no compass) and `info_landmark` (level transition offsets aren't kept) as partly supported instead of unknown.
- The `V` demo action logs each train's position and whether it is running or waiting.

## v0.25.0 — 2026-11-10

The full game's monsters and Call of the Void's Quake 1 monsters fight on their own frames, the BFG10K and the power-ups work like Quake 2's, the view ripples underwater, and the remaster's teleporters work. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Quake II Remastered's (and Rogue's) teleporters: `trigger_teleport` brushes send the player to a random `info_teleport_destination` of their target, like `misc_teleporter`; with a targetname they wait to be used (unless START_ON) and switch on / off each time. Call of the Void's hubs and levels use them.
- Call of the Void: its Quake 1 monsters (ogre, knight, enforcer, grunt, zombie, scrag, fiend, rottweiler, hell knight, shambler, vore, rotfish, spawn, in their plain, `_prototype` and `_strogg` variants whose models keep Quake 1's frames) walk, run and attack on Quake 1's animation frames with Quake 1's damage, instead of the generic one-attack AI; models that only number their frames are animated by index. Variants keep their own weapon (the strogg ogre's pellets). `castle-quake2-tests --retail <pak> <mod pak>` checks the models' frame counts.
- The map report (`--map-report`) quits when it's done; it used to stay open after writing the report.
- `-game` takes an absolute folder too.
- The full game's monsters fight like Quake 2's (checked with Quake II Remastered's data): attack and walk / run tables from `m_gladiator.c`, `m_chick.c`, `m_mutant.c`, `m_brain.c`, `m_float.c`, `m_hover.c`, `m_flipper.c`, `m_medic.c`, `m_supertank.c`, `m_boss2.c`, `m_boss31.c`, `m_boss32.c`: the gladiator's railgun at where you were and its cleaver, the iron maiden's rockets (refired 60 % of the time) and slashes, the mutant's claws and leap, the brain's claws and pulling tentacles, the technician's blaster, zap and wham, the icarus's blaster, the shark's bites, the medic's blaster and hyperblaster, the supertank's chaingun and rockets, the hornet's machineguns and four-rocket volleys, Jorg (now spawned: the Makron riding Jorg's legs) with twin chainguns and BFG, and the Makron with BFG, a sweeping hyperblaster and a railgun, launched from Jorg 5.6 s after it dies. Melee hits push (or pull) like `fire_hit`; their gib health is Quake 2's. The tank commander now uses the tank's attacks. `castle-quake2-tests --retail <pak>` checks the tables against the retail models.
- The rebreather, environment suit, silencer and power shield / screen work (demo3 has all but the screen; before, picking them up did nothing): 30 s of air underwater (the suit also cuts lava to a third and stops slime), 30 shots monsters don't hear, power armor that absorbs a third (screen, front only) or two thirds (shield) of each hit for cells, shown in the HUD's armor slot. `give <item>` gives any item by name, `powerarmor` switches power armor. Drowning no longer goes through armor (Quake 2's `DAMAGE_NO_ARMOR`). A monster's power screen shows Quake 2's screen model (`EF_POWERSCREEN`) when it absorbs a hit.
- BFG10K like Quake 2's: in flight the ball lasers the monsters within 256 units (10 damage every 0.1 s, through monsters, `bfg_think`), its impact deals the core blast (200 within 100) and 0.1 s later the BFG effect hits everything visible from the blast and from the shooter within 1000 units for up to 500 damage (`bfg_explode`), each target flashing with the translucent `s_bfg2` sprite and a green light. Before, the impact was a bigger rocket blast. Kept in savegames. Screenshots in the README.
- Underwater view warp: with your eyes in water, slime or lava the picture ripples like in Quake 2's software renderer (`D_WarpScreen`: rows and columns shifted by a moving sine, 3 pixels at 320 × 240), a screen effect on the main viewport.
- Exported levels play through in Yamagi Quake II: key doors, the secret area and the exit work there. The exit of an exported level now leads back to the map itself, since the next random level (`rand<seed+1>`) exists only in this port; before, the other engine stopped with "Couldn't load maps/rand9.bsp". CI now checks the export.

## v0.24.0 — 2026-11-09

Exported levels with lava keep their lava texture in other engines, and the documentation is reorganised into shorter pages. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- The level editor's export also writes the lava texture a level with lava needs (`textures/castle/lava.wal`, made in memory here), so another Quake 2 engine shows the lava too.
- Documentation reorganised: a shorter README (why this port, getting started, controls), with the details moved to new pages: [FEATURES.md](FEATURES.md), [LEVELS.md](LEVELS.md) (random levels, the editor and its commands, exporting), [MODDING.md](MODDING.md) and [TESTING.md](TESTING.md) (unit tests, demo script actions, recording, screenshot comparison).

## v0.23.0 — 2026-11-09

Exported levels render in other Quake 2 engines (checked in Yamagi Quake II). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Exported levels (random levels and the level editor's) now render in other Quake 2 engines: walls, steps, water and diagonal walls were missing there (Quake 2's renderers only draw faces a BSP node lists). Checked in Yamagi Quake II with its software and OpenGL renderers.

## v0.22.0 — 2026-11-09

Call of the Void's and Quake II Remastered's keys. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Call of the Void's keys (the Quake 1 gold and silver keys and the four runes) and Quake II Remastered's new keys (explosive charges, yellow and green keys, power core, antimatter pod and bomb) can be picked up and open their `trigger_key` locks.

## v0.21.0 — 2026-11-07

Call of the Void and Quake II Remastered data, Quake 2's secret doors, a sky fix. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Mods and Quake II Remastered data: `-game <folder>` (or `+set game <folder>`) loads a mod over `baseq2`, also from the remaster's `rerelease/` folder; game folders load their `.pkz` archives and loose files too; the remaster's PNG / TGA textures replace the WAL images; maps in the extended QBSP format load.
- Call of the Void (`-game q1q2`): its maps, textures and models load, and its Quake 1 and hybrid monsters spawn with their model and health and fight with the generic monster AI.
- Secret doors: Quake 2's `func_door_secret` works like the original (opened by a shot or a trigger, it moves down or sideways, pauses, slides back, and closes again after its wait); before, it opened like a plain door when touched. Random levels hide the secret passage behind a secret door that looks like the room's wall, and the level editor has a *Secret* tool.
- Fixed parts of the sky showing as a dark blue patch: the sides of the skybox were sometimes partly transparent.

## v0.20.0 — 2026-10-31

Flickering, pulsing and switchable lights in compiled levels. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Light styles in compiled levels: lights of the level editor and random levels can flicker, pulse or be switched (a light's `style`, or a `targetname` for a switchable light, like Quake 2's qrad). Random levels have rooms with flickering, fluorescent or pulsing lights.

## v0.19.0 — 2026-10-31

Ambushes in random levels and selectable map entities in the CGE editor. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Ambushes in random levels: in some later rooms, extra monsters appear when you walk in (Quake 2's trigger-spawned monsters and a `trigger_once` over the room).
- Box triggers of compiled levels (the exit, ambushes) are real Quake 2 brush models now, so exported `.bsp` files follow the Quake 2 format more closely (not yet tried in Quake 2 itself or other engines).

- CGE editor: map entities are selectable. With *PreviewEntities* / *PreviewMarkers* on, every entity is listed under *EntityPreview*; selecting one shows its class, targetname, target, spawnflags and all its keys.
- Fixed: saving a design in the CGE editor wrote the whole generated map (world, movers) into the file. Only `TQuakeMap`'s own properties are saved now.

## v0.18.0 — 2026-10-31

CGE editor property editors for the Quake 2 map, and the custom editor builds again. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- CGE editor: `TQuakeMap.MapName` has a dropdown of the PAK's maps, `PakUrl` and `LevelUrl` open file dialogs, and right-clicking the map in the hierarchy offers *Reload Map*.
- Fixed: *Restart Editor (With Custom Components)* failed to compile because the console unit used `CastleWindow`, which the editor doesn't have. CI now builds the custom editor.

## v0.17.0 — 2026-10-31

Gamepad button rebinding. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Gamepad buttons can be rebound: *Options → Controls → Gamepad Buttons* (press the button to use for jump, crouch, use, hand grenades, help, next or previous weapon) or `padbind <action> <button>` in the console. Bindings are saved with the other options.

## v0.16.0 — 2026-10-30

Round rooms, an entity inspector in the level editor and a launcher icon. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- An entity inspector in the level editor: the **Inspect** tool selects a placed entity and shows its keys; Q / E turn it, and `editor set <key> <value>` / `editor unset <key>` in the console change its light level, colour, spawnflags, targets and so on.
- A launcher icon for Android, Windows and Linux (original artwork: a castle tower with a glowing 2).
- Curved walls: round rooms. Random levels make some big rooms round, with walls of 45-degree facets, and the level editor carves one with `editor round x0 y0 x1 y1` in the console.
- Fixed: monsters in random levels could start stuck in a wall: a tank next to a pillar or a step, or anything placed in a cell with a diagonal wall. The tests now compile 12 random levels and check every monster's starting spot.

## v0.15.0 — 2026-10-30

Diagonal walls in random and edited levels. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Diagonal walls: the level editor has a **Diagonal** tool that cuts a corner at 45 degrees (it picks the corner between two walls), and random levels cut the corners of most bigger rooms.
- README: the license section no longer suggests Castle Game Engine is MIT (it is LGPL with a static linking exception, which lets games use any license).

## v0.14.0 — 2026-10-26

Real slopes, breakable glass windows, a key hunt, the full game's textures as themes, and audio polish. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Fixed: the game could crash on exit after playing a level from the level editor (the console was inserted into the screen twice when the editor opened).
- The full game's textures as themes: with the retail Quake 2 PAKs, every texture set (e1u2, e2u3...) becomes a level theme for the editor and the random levels. Level files remember theme names, so they still load on the demo.
- Breakable glass: windows shatter when shot, with Quake 2's glass sound and debris. Quake 2's breakable walls only explode now if they are meant to (`dmg`), and always throw debris.
- Real slopes: ramps in levels. The level editor has a **Ramp** tool: the floor slopes up to the highest neighbouring cell, smooth to walk on. Random levels climb on slopes instead of 16-unit steps, outdoor hills roll, and the *Hills* tool paints slopes.
- Windows between rooms: a **Window** tool in the editor, and a few windows in random levels. You and monsters can see through the glass, but nobody can walk or shoot through it.
- Audio polish: sounds straight ahead are a little quieter than sounds to the side, as in Quake 2, and the master volume is turned down gently when many loud sounds play at once (big fights no longer distort).
- A key hunt in random levels: on even seeds the blue key that opens the exit often lies in a vault behind red doors, and you have to find the red key first. Red key doors have a red lamp.

## v0.13.0 — 2026-10-25

Keys, ladders, slime, lava, teleporters and outdoor areas in random and edited levels. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Ladders, lava and outdoor areas in levels. The level editor has a **Ladder** tool (R): a ladder goes up the highest step next to the cell, and you climb it like Quake 2's (walk into it, look up). The **Lava** tool (I) makes glowing lava pools that hurt a lot. Quake 2's demo has no lava texture, so the game draws its own. The **Hills** tool paints rolling ground for outdoor areas.
- Four more themes: red and brown indoors, rock and grass outdoors.
- Random levels use ladders for some of the big climbs, have lava pits as well as slime pits, and turn big sky rooms into outdoor areas with grass or rock and rolling ground.
- Keys, slime and teleporters in levels. The level editor has a **Key** tool (K; Y switches between the blue and red key): those doors stay shut ("You need the Blue Key") until you bring the key, which then opens all doors of its colour. It also has a **Slime** tool (M): a damaging green pool. Keys and teleporters are in the entity palette; each teleporter takes you to the teleporter destination of the same number.
- Random levels lock the exit with the blue key on even seeds (with the switch on odd ones), turn a third of the pools into shallow slime pits, and put a teleporter in the secret room that takes you back to the start.
- Teleporters show their pad (the `dmspot` model), as in Quake 2.
- Autotest scripts can now stand next to things in parts of the level that are not drawn at the moment.

## v0.12.0 — 2026-10-24

Real visibility in random and edited levels: only what you can see is drawn. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Random and edited levels now have real visibility: the level compiler works out which parts of the level can see each other (like Quake 2's `qvis`, on the level grid), so only what you can see is drawn and monsters only hear you through open space, as in the original maps. On a typical random level about a quarter of it is drawn at a time.
- CI: the lift test accepts small differences in where the player rests on the lift.

## v0.11.0 — 2026-10-24

Lifts and switches: in the level editor and in random levels (lifts to high rooms, the exit locked behind a switch). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Lifts and switches in levels. The level editor has a **Lift** tool (H; `,` / `.` set the height): lift cells become a Quake 2 platform (`func_plat`) that carries you up when you step on it and comes back down. It also has a **Button** tool (J): a button opens the doors of its channel (C cycles channel 1–9, and the Door tool uses the current channel), and those doors then stay open. Doors without a channel still open by themselves.
- Random levels use lifts to reach rooms much higher or lower than their neighbours, and lock the exit room behind doors opened by a switch somewhere along the way (checked to be reachable with the exit shut), a classic Doom / Quake progression.
- The roadmap is rewritten as a short, current priority list.

## v0.10.0 — 2026-10-24

Doors and water in random and edited levels, monsters that open doors, and Random Level / Level Editor working from the first screen (and in the browser). Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Fixed: *Random Level* and *Level Editor* in the title menu (the first screen, as in the browser build) failed to load ("Failed to load level"); the title menu passed the placeholder name instead of a new random level, and didn't open the editor.
- Doors and water in levels. The level editor has **Door** (O) and **Water** (U) tools: door cells become Quake 2 doors (`func_door`, touching cells are one door) that slide up when you come near, and water cells fill up to a depth (V / B change it) to wade or swim in, with the warping water surface. Random levels put doors at some corridor entrances and sunken pools in some rooms; the generator counts swimming up out of a pool as a way out.
- Monsters open doors too, like Quake 2's door trigger field (not doors with the "no monsters" spawnflag).

## v0.9.0 — 2026-10-24

Random levels and a level editor, compiled into Quake 2 maps while the game runs; monsters walk and run at their Quake 2 pace. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Random levels: *Random Level* in the menu or `randmap [seed]` makes a level from a seed, following classic Quake / Doom design. Rooms of varied size are linked into loops (more than one way around). Low corridors climb in steps between high rooms. Big rooms get pillars for cover and raised platforms, and some rooms open to the sky. Monsters get more numerous and tougher further in, some in ambush and some only on harder skills. Weapons come in order of strength, with ammo after them, health and armor after the fights, and barrels. There is a secret room with a reward, and an exit to the next random level. The same seed always makes the same level.
- Level editor: *Level Editor* in the menu (or `editor`) to paint levels from above. You can paint walls and floors, set floor and ceiling heights, sky and texture themes, and place the player start, lights, monsters, weapons, ammo, items, barrels and the exit. It has undo, can generate a random level to start from, and saves and loads levels. *Play* compiles the level into a Quake 2 map and starts it at once; *Export* saves the `.bsp`. In the Castle Game Engine editor, `TQuakeMap.LevelUrl` shows a saved level and `MapName` `rand<seed>` a random one, and the editor is a component too (`TQuakeLevelEditor`).
- Levels are compiled at runtime into real Quake 2 maps (BSP tree, brushes, lightmaps, visibility), so monsters, items, triggers, saves and the exit work in them as in the original maps.
- Fixed: after a level change the game could keep testing collisions against the previous map (the player and monsters could fall through floors).
- Monsters walk and run on Quake 2's animation frames: each frame moves them by its distance from the original game's tables, so their feet keep step and every type has its Quake 2 pace — the tank plods at under half the speed it had (47 units a second), parasites lunge almost twice as fast (254), infantry and berserkers are quicker, flyers slower (100). The demo maps' monsters are now all fully supported in the map report.

## v0.8.1 — 2026-10-24

Flyers fight up close and the tank picks its attacks like Quake 2. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Flyers slash with their wing blades when the player is close (`flyer_melee`: 5 damage a wing, repeated most of the time while he stays in reach), and the tank picks its attack by distance like `tank_attack` (rockets only beyond 250 units, blaster or machinegun closer).
- Fixed: a monster with a gun swinging at the player up close (the infantry's gun butt, now the flyer's blades) could hit from as far as its gun reaches; melee hits now reach 80 units like Quake 2's `fire_hit`.

## v0.8.0 — 2026-10-24

Turrets from the full game and a Quake 2 death. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Turrets (`g_turret.c`): a `turret_breach` turns towards where its `turret_driver` aims (within its pitch / yaw limits, at its `speed`), its `turret_base` turns with it, and it fires rockets (100–150 damage, faster on harder skills) from the point its target marks, once the driver has seen the player for 3 − skill seconds; the driver is an infantry that rides behind the gun, never flinches and is gibbed when killed, and the gun then levels. The demo has no turrets: CI spawns one (as boxes) with the `spawn` command.
- Player death like Quake 2's `player_die`: the view drops (eye 8 above the origin), turns to the killer, looks a little up and rolls 40°, and the view weapon goes away; below -40 health the player is gibbed (splat, 4 pieces of meat, the view at floor level). The `kill` command is a suicide at health 0 (no gibs, also in god mode), as in Quake 2.

## v0.7.0 — 2026-10-23

Medics bring dead monsters back. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Medics revive dead monsters (`m_medic.c`): once a second a medic looks for a corpse it can see within 1024 units (the one with the most health), walks to it, uses its healing cable for a second and the monster gets up with full health, after the player; it counts towards the level's monsters again. Tested on the demo with a medic without its model (the demo has none).

## v0.6.0 — 2026-10-20

Clocks and digit displays from the full game, and models lit by the flickering and switchable lights around them. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Models are lit by all the light styles of the floor below them, like Quake 2's `R_LightPoint`: monsters, items and props flicker with flickering lights and go dark when a light is switched off (they only saw the first style before); they are re-lit 10 times a second.
- Clocks and displays: `func_clock` (count up, count down or the time of day, once a second, firing its `pathtarget` when the time is up), `target_string` and `target_character` (digit brushes showing 0-9, `-` and `:` through their texture frame), like the full game's countdowns.

## v0.5.0 — 2026-10-19

Quake 2 gibs, rotating skies, currents and conveyor belts, and brush textures that animate like the original. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- Brush entity textures animate like Quake 2 (`R_TextureAnimation` with the entity frame and `EF_ANIM*`): buttons show their first frame until pressed, then cycle their "pressed" frames 2 / 3 and, after returning, 0 / 1; doors, walls, rotating brushes and explosives cycle only when their spawnflags say ANIMATED (10 frames a second for ANIMATED_FAST); everything else stays still (before, every animated brush texture cycled twice a second all the time). Faces that start in the middle of a texture chain keep their offset.
- Gibs like Quake 2's `ThrowGib`: each monster breaks into its own pieces (soldiers 3 meat + chest + head, the tank metal and a gear, ...) at its own gib health (soldiers -30, gunner -70, tank -200; it was -40 for all), thrown faster by harder hits from all over the body, spinning; flesh lands on the map's brushes with a splat, metal and barrel debris bounce; pieces vanish after 10 - 20 s. The flyer explodes when it dies.
- Rotating skies: worldspawn `skyrotate` / `skyaxis` like Quake 2's `R_SetSky`, and a `sky <name> [rotate [x y z]]` console command (CI checks that the sky turns).
- Water currents and conveyor belts: brushes with `CURRENT_*` contents push the player like Quake 2's `PM_AddCurrents` (400 in water, half when wading, 100 on a belt); `func_conveyor` is supported.

## v0.4.0 — 2026-10-19

Phones, more of the full game, and monsters that fight more like Quake 2. Windows, Linux and Android packages below; the browser build is at <https://mariuz.github.io/castle-quake2/>.

- *Options → Interface Size* (Auto, Small, Normal, Large, Huge): the menu, console and HUD text scale on top of CGE's UI scaling; Auto is 1.75× on touch screens, so menu rows are big enough to tap on a phone. The menu shows as many rows as fit (with "..." for more), centers its text and shows touch hints; pickup messages move to the center on touch screens; console lines no longer overlap.
- CI taps through the menu on a 2400 × 1080 touch screen.
- Full-game entities: `misc_viper`, `misc_bigviper`, `misc_viper_bomb`, `misc_blackhole`, `misc_eastertank` / `misc_easterchick(2)`, `target_blaster`, `target_spawner`, `func_killbox`, `trigger_gravity`; `target_earthquake` now shakes the player (it only played the sound).
- Monster attacks closer to Quake 2: soldiers refire in melee range (and half the time on nightmare), the light soldier skips cocking its gun, soldiers duck and shoot when dodging (from medium skill), the machinegun soldier uses its own attack, the tank uses its machinegun (19 bullets of 20).
- `spawn <class> [key value]...` console command, to try entities the demo maps lack (CI tests the ones above with it).

## v0.3.0 — 2026-10-18

The first tagged release: Windows, Linux and Android packages below, the browser build at <https://mariuz.github.io/castle-quake2/>. Bundled with the Quake 2 shareware demo (`demo1`–`demo3`); a full Quake 2 install loads from `baseq2/` or `-basedir`.

### Play like Quake 2
- Player movement is Quake 2's pmove on box traces against the map's brushes (`CM_BoxTrace`, `PM_StepSlideMove`): steps, slopes, crouch, ladders, water, player-clip brushes.
- Weapons run on Quake 2's gun frames (`Weapon_Generic` / `Weapon_Grenade`): fire frames, refire, put away / raise, chaingun spin-up, BFG delay, cooking hand grenades.
- Monsters attack on Quake 2's attack frames (machinegun bursts, the gunner's chain refire, grenade volleys, the tank's rockets, the parasite's drain), notice the player like Quake 2 (front cone, hearing through the PHS, ambush, trigger-spawned monsters, group wake), follow the player trail, duck under shots and use `trigger_monsterjump`.
- Monsters walk with `SV_movestep` / `M_CheckBottom` (step up 18, don't walk off ledges, respect monster-clip brushes); hitscan, projectiles, sight and lasers trace the brushes too, grenades bounce off the hit plane, barrels are solid.
- Doors, plats and trains carry and push the player, monsters, corpses and items (`SV_Push`); blocked movers hurt and reverse, crushers keep going, corpses caught in a door are gibbed.
- View and weapon bob, weapon lag, landing dip and damage kicks; Quake 2 style sound (attenuation, entity channels, merged looping sounds).

### Options and devices
- Options menu: mouse sensitivity and invert, field of view, volumes, view bob, key rebinding; skill selection (easy … nightmare).
- Gamepads (sticks, triggers, menus) and on-screen touch controls (move stick, drag to look, buttons, tap menus); an Android APK (debug-signed, for sideloading).
- Gamepad and touch were only tested with simulated input so far — reports from real devices are welcome.

### Levels
- PVS and areaportal culling of the world and of entities; savegames with projectiles and delayed events; units remember their levels; cross-level triggers; help computer and intermission.
- `--map-report` lists what a set of maps needs (the demo has no unsupported entity classes).

### Tools
- `record <name>` / `stop` console commands record a playthrough as an autotest script (`--demo @file` replays it), to turn a bug into a regression test.
- CI: 173 unit checks, headless autotests (keyboard, virtual gamepad, simulated touch, a recorded replay), screenshot comparison, culling check, map report; Windows, Linux, Android and WebAssembly builds.
- The CGE editor opens the levels (`TQuakeMap` with skybox and entity markers); monster types and named sounds are editable designs.
