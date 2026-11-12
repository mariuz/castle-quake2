# Castle Quake 2 Roadmap

Comparison with the original **Quake 2** (id Tech 2, `ref_gl` + `game` DLL), what is left to do, and how Castle Game Engine (CGE) features can carry it.

## Comparison

| Subsystem | Original Quake 2 | Castle Quake 2 (now) | Gap |
| :--- | :--- | :--- | :--- |
| World geometry | IBSP v38, PVS / areaportal culling | X3D batches per texture and 1024-unit region; PVS and areaportal culling of world regions and of movers / monsters / items / props / lasers; CGE frustum culling | — |
| Lighting | RGB lightmaps, 4 styles, dynamic lights | All 4 styles (animated, switchable, ramps), 2x overbright, LightPoint model tint with all light styles (models flicker and switch with the lights), dynamic lights on the world and models | More than 4 surface lights at once. |
| Sky | Skybox, `skyrotate`, `skyaxis` | Skybox via `TCastleBackground`, rotating (`skyrotate` / `skyaxis`, `sky` console command) | — |
| Liquids | Warped water / lava (`SURF_WARP`), contents | Warp shader, non-solid liquid surfaces, swimming, drowning, lava / slime damage, underwater tints | — |
| Models | MD2 with lerp, skins, `EF_*` effects | MD2 with lerp, skins, shells (quad, invulnerability, power shield), the power screen model (`EF_POWERSCREEN`) | An item inventory (Quake 2 single player uses powerups from it; here they're used on pickup). |
| Sprites | SP2 (BFG, explosions) | SP2 loader, BFG ball / explosion / effect sprites (the demo's other sprites are unused in Quake 2 too) | — |
| Player physics | Pmove (air control, water, ladders, crouch slide) | Pmove as `TQuakePlayerMovement`: the 32 × 32 × 56 box traced against the BSP brushes, movers and monsters (`CM_BoxTrace`, `PM_StepSlideMove`), movers carry and push the player, water currents and conveyor belts (`PM_AddCurrents`) | — |
| Weapons | 10 + hand grenades, frame-timed | 10 + hand grenades on Quake 2's gun frames (`Weapon_Generic`: fire frames, refire, put away / raise, chaingun spin, BFG delay, grenade cook) | — |
| Monsters | Full AI (`ai_run`, dodge, ambush, bosses), skill levels | Quake 2 perception (`FindTarget`, PHS hearing, group wake, ambush, trigger spawn), player trail pursuit, dodging, attacks and walk / run on Quake 2's frames for the demo's and the full game's monsters (incl. supertank, hornet, Jorg with the Makron coming out), `trigger_monsterjump`, patrols, combat points, 22 types tunable in the editor, skill 0–3 | `monster_boss3_stand` (boss1's Makron), `BossExplode` death explosions, the mission packs' monsters. |
| Props / effects | Barrels, banners, ships, lasers, splashes, explosion models | All of these used by the demo maps, plus the full game's `misc_viper` / `misc_bigviper` / `misc_viper_bomb`, `misc_blackhole`, easter-egg poses, `target_blaster`, `target_earthquake` (shakes), `target_spawner`, `func_killbox`, `trigger_gravity`, turrets | — |
| Level flow | Units, cross-level triggers, help computer, intermission, savegames | All of these (JSON savegames, including projectiles in flight and pending delayed events) | — |
| Audio | 3D sounds, entity channels, merged loop sounds, CD music | Quake 2 attenuation (incl. `ATTN_STATIC`), `CHAN_*` channels, point sounds that outlive entities, loop mixer (one voice per sound, PVS-checked, `SOUND_LOOPATTENUATE`), 32 sources, OGG tracks, named sounds editable in the editor | Stereo panning curve (OpenAL's, not Quake 2's), `s_volume` style master limiter. |
| Input / options | Key bindings, mouse sensitivity, joystick, skill | Options menu (sensitivity, invert, FOV, volumes), key rebinding, skill selection, saved in `UserConfig`, gamepad (sticks, triggers, menus), touch controls (stick, drag look, buttons, tap menus) | Gamepad button rebinding; gamepad and touch not yet tried on real hardware. |
| Multiplayer | Deathmatch / coop over UDP | Single player only | Planned in steps: see *Networking and bots* below. |
| Tooling | Console, `+map`, demos | Console, autotest scripts (keys, gamepad, touch), `record` to turn play into a script, screenshot comparison in CI, 371 unit checks, map compatibility report, CGE editor components and designs, F8 inspector, Windows / Linux / Android / WebAssembly builds | Editor property editors. |
| Level making | qbsp / qrad / qvis on brush maps from an editor | Random levels and an in-game grid editor (doors, key doors, lifts, ladders, ramps, diagonal walls, windows, switches, water, slime, lava, teleporters, sky, hills, themes, entities), compiled at runtime into IBSP v38 maps (BSP, brushes, lightmaps, grid PVS / PHS); `.bsp` export; levels in the CGE editor | Free-form brushes (any angle); height-aware vis. |

## Done so far

- **Look**: lightmaps and light styles, dynamic lights, skybox, water warp, MD2 with shells, SP2 sprites, particles, gibs, weapon viewport.
- **Play**: all weapons and items on Quake 2's gun frames, pmove with BSP box traces (`PM_StepSlideMove`), ladders / water, doors / plats / trains / buttons that carry, push and get blocked like Quake 2, trigger chains, monster AI with Quake 2 perception, pursuit, dodging and frame-accurate attacks.
- **Flow**: help computer, intermission, savegames, cross-level triggers, units that remember state.
- **Performance**: PVS + areaportal culling of the world and of entities (`novis` to compare), batched particles.
- **Editor**: views from designs, `TQuakeMap` building levels in the editor with skybox and entity markers, behaviors with published state, monster types (`data/monsters.castle-transform`) and named sounds (`data/sounds.castle-component`).
- **Reach**: options menu with key rebinding, skill levels, gamepad, touch controls, Android APK and WebAssembly builds.
- **Engineering**: CI on Windows / Linux / Android / Web, autotests under Mesa (keyboard, virtual gamepad and simulated touch), screenshot references, culling check (vis vs `novis`), map compatibility report, recorded replays, 371 unit checks.
- **Levels**: random levels from a seed (`QuakeLevelGen`, Quake / Doom layout rules: loops, steps, lifts, doors, pools, an exit switch, pacing) and an in-game level editor (`QuakeLevelEditor`: doors, lifts, switches, water, sky, themes, entities), compiled at runtime into Quake 2 maps (`QuakeBspBuilder`); levels show in the CGE editor through `TQuakeMap`.
- **Releases**: v0.3.0 to v0.31.0, each with Windows / Linux / Android packages and the browser build ([changelog](CHANGELOG.md)).

## Next (prioritised)

Phases 1–6 are done as far as the demo data and a headless machine allow; Phase 7 (levels) is in progress; v0.3.0 to v0.26.0 are released. In order of value for effort:

1. **More level content** (Phase 7): check the discovered themes on a retail `baseq2` (they are tested with a simulated texture directory).
2. **Try it on real hardware** (needs a phone, a gamepad and a GPU). Touch, gamepads and GPU speed were only tested headless: install the APK, play with a controller, run on a real GPU with `fps` on. Expected follow-ups: touch button sizes and look speed.
3. **Android release signing** (needs a key): an `AndroidSigningProperties.txt` release key instead of the debug-signed APK (the launcher icon is done).
4. ~~**Full game monsters**~~ — done with the retail PAK (Quake II Remastered's): attack and move tables for gladiator, chick, mutant, brain, floater, hover, flipper, medic, supertank, hornet, Jorg and the Makron (`castle-quake2-tests --retail <pak>` checks them against the models). `trigger_elevator` and the remaster's `dynamic_light` are done, `target_poi` / `info_landmark` listed as partial. Left: `monster_boss3_stand`, `BossExplode`, the remaster's compass (`target_poi`) and landmark transitions (`info_landmark`), and the retail report's other classes (`misc_insane`, `target_actor`, `turret_invisible_brain`; the mission packs).
5. **Call of the Void** (Quake II Remastered mod, `-game q1q2`): the loader is done (mod folders, `rerelease/` layout, loose files, `.pkz`, PNG / TGA textures, QBSP maps; the mod's monsters spawn with a generic AI from `GenericMonsterFacts`). Done with the mod's files: the map report (all its maps load) and attack / move tables for the Quake 1 monsters (`QuakeQ1Monsters`, facts from id's Quake re-release QuakeC; variants with Quake 1's frame counts). Teleporters (`trigger_teleport` / `info_teleport_destination`) done. Next: the zombies' getting up and the spawn's explosion, the hybrids (`shamjorg`, `chtjor`, `ironvore`, `rotflyer` ...) and Chthon, items and weapons (its keys are done: the Quake 1 keys and runes and the remaster's six new keys), `func_plat2` and the remaster's other new classes (`func_door_secret2` is done).
6. **Exported levels in more engines**: they load, render and play through in Yamagi Quake II (key doors, secrets, lifts, switches, the exit); try the remaster, vkQuake2 and q2pro (not reachable from the cloud container used so far).

Multiplayer (deathmatch / coop) needs a client-server split of `TQuakeWorld` and networking: see section E below for a path in steps, starting with bots and two instances on one web page.

## Proposed: performance, graphics, code, web and networking

Suggestions from a review of the code and the web build (November 2026). Each one says how it would be checked, since CI only has Mesa's software renderer and FPS numbers there only compare runs with each other.

### A. Performance (measure first)
1. ~~**A benchmark that CI keeps**~~ — done: `--benchmark <map>`, `BS` / `BE`, a table in each CI run's summary. First numbers on CI-like software rendering: demo1 p50 36 ms, demo2 45 ms, demo3 51 ms per frame, game logic 4–8 ms of that, 29–56 shapes. Next: also time traces, particles and model animation separately. Original plan: `--benchmark <map>` plays a fixed demo script and logs frame-time percentiles (median, 95th, 99th), draw calls, visible shapes and the time spent in game logic, traces, particles and model animation. CI stores the numbers as an artifact, so a change that doubles the frame time shows up even on Mesa. Everything below is measured with it.
2. **Model animation on the GPU** — tried and parked (November 2026): blending the two frames in a vertex shader (frame B as a `FloatVertexAttribute`, the blend factor as an effect uniform) drew every model right only alone: Castle Game Engine shares one shader program between shapes with the same code and sets effect uniforms on that program when they change, not per shape, so all models got the last model's blend factor. It also gained only 2–6 % on the benchmark (software rendering; uploads already happen only for the ~10 % of models in view). Needs a per-shape uniform in the engine first; not worth a shader per model. Original plan: `TQuakeMd2Instance.Update` blends two frames on the CPU and calls `SetPoint` every frame for every monster, item and the view weapon (a new vertex buffer upload each time). Instead, upload all frames once and blend the current two in a vertex shader (frame indices and lerp as uniforms). Check: same screenshots (within ~1), benchmark on demo1's busy rooms.
3. **A fixed game tick**: run the simulation at a fixed rate (Quake 2's server runs at 10 Hz and interpolates; 40 Hz would keep today's feel) and interpolate transforms for drawing. Monster sight checks, `CullEntities`, light re-sampling and trigger checks then run per tick instead of per frame, results stop depending on the frame rate, and A.1's numbers become comparable. It is also the base of networking (E.1). Check: the existing autotests (their timings are in seconds already), recordings replaying within 8 units.
4. **Fewer draw calls for the world**: today each 1024-unit region gets a shape per texture, plus a shape per mover and per model. Try a texture array (or atlas) per region so a region is one or two shapes, and compare `RegionSize` 512 / 1024 / 2048 with A.1 (culling against draw calls).
5. **Cheaper traces**: cache line-of-sight results between monsters and the player per tick, and give `WorldTrace` a broad phase over entity boxes (a uniform grid) instead of testing every monster, corpse and barrel.
6. **Particles**: `RebuildBatch` rebuilds the whole particle mesh every frame. Billboard in a vertex shader from a fixed buffer of quads instead (only positions, sizes and colours change).

### B. Graphics
1. **Quality settings** — started: *Smooth Textures* and *Brightness* in *Options* (November 2026). Still to do: render scale (needs the viewport drawn to a smaller texture and scaled up; the engine has no option for it), dynamic light count, particle density. Original plan (*Options → Video*): render scale (draw at 50–100 % and upscale, the biggest win on phones and in the browser), texture filtering (Quake 2's nearest-pixel look, or linear with mipmaps and anisotropy), dynamic light count (now 4 nearest per surface), particle density, brightness / gamma.
2. **More dynamic lights**, and lit models: monsters and the gun now take a single `SampleLight` colour; give them the nearest dynamic lights too (muzzle flashes, rockets passing, `dynamic_light`).
3. **The remaster's fog** — parked: the game code only carries `fog_density` / `fog_color` / `fog_sky_factor` and `trigger_fog`'s on / off values; how density becomes fog is in the remaster's renderer, which id did not release, so the scale can't be matched without the game to compare. Original plan: worldspawn `fog_*` keys and `trigger_fog` mapped to CGE's `TFogNode` (its maps use them; the original game has none).
4. **Water and sky**: refraction-like warp of what is seen through water (the underwater warp is done), and the remaster's sky keys.
5. **Check exported levels' lighting**: in Yamagi the key door alcoves look much darker than the rooms; the compiler's lights are per room, so give doorways and corridors a light of their own.

### C. Code simplification
1. **Split `QuakeWorld`** (4,900 lines, the biggest unit): weapons and projectiles, items and pickups, targets and triggers, movers' game rules, save / load and monster glue into their own units, `TQuakeWorld` keeping the frame loop and the lists.
2. **One class table**: `SpawnEntity` and `UseEntity` pick behaviour with long chains of `if CName = '...'` (about 60 in `QuakeWorld`), and the map report keeps a separate hand-written `SupportedClasses` list that can drift. A registry (classname → spawn / use / touch handlers, like Quake 2's `spawns[]`) would serve all three, and the report would list exactly what is registered.
3. **Explicit entity state**: `FCounters` now holds trigger counts, used `trigger_key`s and `dynamic_light` on / off. Give such entities a small state record, saved by its own code, and save movers, monsters and props through their own `SaveState` / `LoadState` instead of one big function.
4. **Structured test logs**: the `V` action writes free text that CI greps with brittle patterns. Add a JSON-lines state dump (`VJ`) and check it with `jq` in CI.
5. **Fixes noticed while doing that**: ~~box movers spawned from the console can't be shot~~ (done: box doors are solid boxes, CI shoots one); ~~the GitHub Pages deploy sometimes times out~~ (done: retried once); ~~an autotest sometimes doesn't exit~~ (done: `QuakeExitWatchdog` ends it 20 s after quitting, CI warns) after `Sound backend closed` (v0.26.0's CI waited 10 minutes for the `inspect` script, which had finished): find what blocks at shutdown, and make `Q` end the process after a short grace time.

### D. Web (wasm) performance and configuration
1. **Smaller download**: the browser build ships the whole 50 MB demo PAK before the first frame. Load the PAK in the background behind a progress bar, start on the menu, or ship a trimmed PAK per map (only the files demo1 uses first, the rest on demand), and keep it in the browser's cache (IndexedDB / Cache API) so the second visit starts at once. Check: time to first frame in a Playwright run (Chromium is in the cloud container), and download size in CI.
2. ~~**Settings from the address**~~ — done: `map`, `skill`, `touch`, `fps`, `gamma`, `demo` (`QuakeWebParams`); `scale` waits for B.1. Original plan: `?map=demo2&skill=2&touch=1&scale=0.75&fps=1` (and the console's `+set`), so a link opens a map with the right options and tests can use the same page.
3. **Browser-friendly defaults**: cap the drawing resolution on high-DPI phones (`devicePixelRatio` 3 means 9× the pixels), pause when the tab is hidden, and pick a lower render scale (B.1) when the first seconds run slow.
4. ~~**Check the build regularly**~~ — done: `tests/web/smoke.js` in the `web` workflow (menu → demo1 in headless Chromium; first numbers on software WebGL: map 5–10 s after opening the page, 7–8 frames per second). Next: run a demo script in the page once D.2 (settings from the address) exists. Original plan: a Playwright job in CI that loads the page, waits for the first frame, runs a short demo script through the address (D.2), and fails on `GLSL: Fragment shader not compiled` or a wasm exception in the console. The web build is the one players reach first and is not tested today.
5. **Compiler settings**: try FPC's `-O3` / `-CfWASM` options for wasm32 and compare the benchmark (A.1) in the browser.

### E. Networking and bots (two instances on the same page first)
Multiplayer was out of scope because `TQuakeWorld` is one object for one player. This is a path in small steps; each one is useful and tested on its own:
1. **Client / server split in one process** (needs A.3): the server owns the simulation and sends snapshots of what players can see (Quake 2's `entity_state_t`: origin, angles, model, frame, skin, effects, sound) each tick; the client draws them, predicts its own player with the same pmove, and sends its inputs (`usercmd`: angles, move, buttons). Single player uses a loopback channel and plays as today. Check: every autotest and recording still passes over loopback.
2. **More than one player**: players as a list (stats, inventory, position, view) instead of `FStats` / `FPlayerPos`; deathmatch rules (`info_player_deathmatch` spawns, item respawn, frags, `dmflags`).
3. **Bots**: a `TQuakeBot` that drives a player's `usercmd` with the monster AI's pieces (sight, `PlayerTrail`, item goals, aiming with reaction time and spread). Bots make deathmatch testable without people, on the desktop too.
4. **Two instances on one page**: a test page (`pages/duel.html`) with two game canvases (two iframes, each its own wasm instance); one hosts, the other joins through `BroadcastChannel` / `postMessage` (no network, no server). Each runs a bot. Check: a Playwright run for 60 s, reading both consoles: both see the other player, frags happen, snapshot rate and prediction errors stay in range.
5. **Real connections**: the same messages over WebRTC data channels between browsers (needs a small signalling server or a copy-paste offer for the host) and UDP between desktop builds; later a dedicated server. Check: two desktop processes with bots under xvfb in CI.

Order of value for effort: A.1, D.4, B.1 (render scale), D.1, A.2, C.2, then A.3 → E.1 → E.3 → E.4.

## Earlier suggestions (history, most done)

### 1. Player-facing polish (highest impact, small)
- ~~Options menu~~ — done: mouse sensitivity and invert, field of view, sound and music volume, *Controls* page with key rebinding, saved in `UserConfig` (`QuakeSettings`).
- ~~Skill selection~~ — done: *Single Player* asks Easy / Medium / Hard / Nightmare; skill filters spawnflags, halves damage on easy, speeds up monster attacks from hard on, no pain flinches on nightmare; `skill` console command; kept in savegames.
- ~~Gamepad~~ — done: CGE's `Controllers` (`QuakeGamepad`): left stick moves, right stick looks (radial deadzone, squared response, mouse sensitivity / invert apply), right trigger fires, A jump, B / left trigger crouch, X use, Y hand grenades, bumpers / D-pad cycle weapons, Menu / View open the menu / help computer; menus work with the D-pad, left stick, A and B. Tested with a virtual pad in the autotests (`GP:` / `GB:` demo actions), not yet on a real controller. Button rebinding done too (*Controls → Gamepad Buttons*, `padbind`; sticks, triggers, Menu and D-pad up / down stay fixed).
- ~~View feel~~ — done: Quake 2's view bob, weapon bob and lag, running tilt, landing dip and damage kicks (`SV_CalcViewOffset`, `SV_CalcGunOffset`, `P_DamageFeedback`), with an *Options → View Bob* switch. Items already rotate (`EF_ROTATE`); Quake 2 items don't bob.

### 2. Feel of combat
- **Frame-accurate attacks**: ~~player weapons~~ — done (`QuakeWeaponFrames`: Quake 2's `Weapon_Generic` / `Weapon_Grenade` frame state machine, so animation, refire, switching and damage line up). ~~Monsters~~ — done for the demo's monsters (`QuakeMonsterAttacks`: soldiers, infantry, gunner, berserk, flyer, parasite, tank play their Quake 2 attack sequences at 10 frames a second and fire on the `mframe_t` fire frames, with machinegun bursts that hold a frame, the gunner's chain refire loop, four-grenade volleys, the tank's three rockets, the parasite's drain, per-shot Quake 2 damage). The soldiers' refire jumps (`soldier_attack*_refire`: melee range or half the time on nightmare; the light soldier skips cocking), their duck-and-shoot attack3 from dodges (by skill), the machinegun soldier's attack4, the tank's machinegun and range choice (rockets beyond 250 units) and the flyer's wing-blade melee are done too. Still to do: tables for the full game's other monsters (they keep the generic wind-up attack).
- **Monster AI gaps**: ~~ambush, trigger-spawned monsters, Quake 2 sight / hearing rules~~ — done (`FindTarget`: front cone and ranges, `show_hostile`, hearing through the PHS and connected areas, `sight_entity` group wake, TRIGGER_SPAWN monsters stay away until triggered). Dodging done too (`check_dodge`: soldiers, infantry, gunners, medics and iron maidens duck under blaster bolts, rockets and BFG balls). Navigation: monsters that lose the player follow Quake 2's player trail (last sighting, then up to 8 breadcrumbs, `p_trail.c`). ~~`trigger_monsterjump`~~ — done (`CheckMonsterTriggers`: horizontal velocity `speed` along the trigger's angle, `height` upward when on the ground, then ballistic flight; not in the demo maps, covered by a unit test); real pathfinding (BSP leaf portals or a walkable grid) only if the trail proves too weak on the full game's maps.
- ~~Swept player box~~ — done: `QuakeTrace` ports `CM_BoxTrace` over the map's brushes (plus movers in their own space and monster boxes) and the player runs Quake 2's `PM_StepSlideMove`, `PM_CatagorizePosition`, `PM_CheckDuck`, friction, water and ladder moves on it; movers carry riders and push the player (`SV_Push`), monsters don't walk into him. Blocked movers act like Quake 2 too (`SV_Push` keeps the pushed or the old position, else the pusher's `blocked`: doors and plats deal their `dmg` (2) and go back, crusher doors keep going, trains deal 100 unless BLOCK_STOPS). ~~Monsters moving with the same traces~~ — done (`SV_movestep`, `M_CheckBottom`).

### 3. Full game support (needs the retail PAK)
- ~~**Medic revive**~~, **boss behaviour** (supertank, Makron, jorg); ~~the missing entities (`misc_viper`, `target_blaster`, `func_killbox`, `turret_*`)~~ — done, tested by spawning them on the demo. Test with a local `baseq2` in a nightly-style workflow that is skipped when the PAK isn't available.
- ~~Save projectiles and delayed events~~ — done (also fixed `trigger_relay` ignoring `delay` and delayed `target_explosion`s, so demo1's opening explosions now come in sequence).
- ~~Map compatibility report~~ — done: `castle-quake2 --map-report report.md` loads every map in the PAKs and lists load times, counts and the unsupported / partially supported entity classes (`QuakeMapReport`); the demo's is in [`map-report-demo.md`](map-report-demo.md) and CI keeps it free of unsupported classes. Run it with a retail `baseq2` to find what to implement next.

### 4. Editor and inspectability
- **Property editors** (under `{$ifdef CASTLE_DESIGN_MODE}`): a dropdown of maps in the PAK for `TQuakeMap.MapName`, a file picker for `PakUrl`, a *Reload map* verb (like `TImageGridEditor` in the custom_component sample). Done (`QuakeMapEditors`), checked in the custom editor built with Lazarus; CI builds that editor (job `build-editor`).
- **Selectable entities in the editor**: make preview markers / models one transform per entity with a read-only `EntityFields` (key/value pairs) property, so clicking a monster in the editor shows its spawnflags and targets.
- **Monster prefabs with live behavior**: optionally move from the single `monsters.castle-transform` to a `.castle-transform` per type that also carries the `TQuakeMonster` behavior, so sounds / scale / effects can be added per monster in the editor.
- **Named sounds by name in code**: replace literal paths (`'sound/items/pkup.wav'`) with `Sounds.PlayNamed('Items_pkup')` gradually, so the design is the single source of truth.

### 5. Performance and platforms
- **Measure on real GPUs**: log frame time and draw calls per map (CI only has Mesa software rendering at ~12 FPS); try `RegionSize` 512 vs 1024 for culling vs draw-call count.
- Merge mover scenes that never move (`func_wall`), cache `LineOfSight` results across monsters, shader-based light styles for big maps.
- ~~Mobile~~ — done: `QuakeTouch` on-screen controls (move stick, drag look, FIRE / JUMP / DUCK / USE / WPN / MENU, multi-touch), tap menus, Android APK built by CI in the CGE Docker image (debug-signed). Not yet tried on a real device; next: try it, tune button sizes and look speed, a release signing key, maybe iOS.

### Out of scope for now
- **Multiplayer** (deathmatch / coop): needs a client-server split of `TQuakeWorld` and networking; large effort, best as a separate project milestone after single player is complete.

## Milestones

### Phase 1 – Look
- [x] BSP v38 geometry, WAL textures, RGB lightmaps, translucent / flowing surfaces, animated textures
- [x] Skybox
- [x] MD2 models with interpolation and lightmap tint
- [x] Quake 2 HUD pics, crosshair, screen blends
- [x] Light styles: flickering, switchable lights, `target_lightramp`
- [x] Dynamic lights on world surfaces and models (lightmap texture shader effect)
- [x] Underwater screen tints
- [x] Water warp shader (`PLUG_texture_coord_shift` effect, like Quake 2's EmitWaterPolys)
- [x] Explosion model, soft particles, splashes, lasers, props (barrels, banners, ships, dish, corpses)
- [x] Gibs and barrel debris with gravity and bounce
- [x] Powerup shells on the view weapon (quad blue, invulnerability red), as offset MD2 shapes
- [x] SP2 sprites (BFG ball and explosion)
- [x] Shells on monsters: power armor (brain's power screen, absorbs damage) flashes green
- [x] Weapon viewport (no wall clipping)
- [x] PVS culling of world regions (visibility lump, `novis` to compare)
- [x] Areaportals (closed doors hide the areas behind them; kept in savegames)
- [x] Entity culling: movers, monsters, items, props, lasers hidden outside the PVS / connected areas

### Phase 2 – Play
- [x] All 10 weapons, items, armor rules, keys, powerups
- [x] Doors, rotating doors, plats, buttons, trains, rotating brushes, explosives
- [x] Target / trigger chains, counters, keys, secrets, goals, teleporters, level changes
- [x] Monster sight / chase / attack / pain / death
- [x] Pmove player physics: friction, acceleration, air control, steps, crouch, jump pads, falling damage
- [x] Swimming, drowning, lava / slime damage, underwater tints
- [x] Ladders (exact test against ladder brushes; they are detail brushes that don't split leafs)
- [x] Player-clip brushes as invisible walls (polygons built from the brush planes)
- [x] Box-shaped player collision (Quake 2's 32 × 32 × 56 box via `WorldBoxCollision`, ledge support from the box corners)
- [x] Monster steering around obstacles (±45° / ±90° detours) and ledge checks
- [x] `path_corner` patrols and `point_combat` (hold) combat points; player-clip doesn't block monsters
- [x] Attacks happen partway through the attack animation (wind-up; pain cancels the shot)
- [x] Medic revive (tested with a model-less medic)
- [ ] Bosses, real pathfinding (needs the full game data: no bosses in the demo)
- [x] Hand grenades (cook, throw speed by hold time, explode in hand), chaingun spin-up

### Phase 3 – Flow
- [x] Help computer (F1) and intermission screens
- [x] Looping ambient sounds (`target_speaker`), `func_timer`
- [x] Savegames (JSON, quick save / load)
- [x] Cross-level triggers (`target_crosslevel_trigger` / `_target`, kept in savegames)
- [x] Levels of a unit remember their state when revisited through a changelevel

### Phase 4 – Editor & tooling
- [x] Views loaded from `.castle-user-interface` designs with published components
- [x] `TQuakeMap`, HUD, console and menu as registered editor components (`editor_units`)
- [x] Monsters, items and movers as `TCastleBehavior`s with named transforms (F8 inspector)
- [x] Map dropdown, PAK / level file dialogs and *Reload Map* verb (`QuakeMapEditors`; CI builds the custom editor)
- [x] Selectable entities with key/value inspection in the CGE editor (`TQuakeEntityTransform` under `EntityPreview`; the in-game level editor has it too: the *Inspect* tool, `editor select / set / unset`)
- [x] Design-time skybox (`TQuakeMap.Background`) and entity markers (`PreviewMarkers`: player starts, paths, speakers, trigger volumes)
- [x] Monster types (`data/monsters.castle-transform`) and named sounds (`data/sounds.castle-component`) editable in the editor
- [x] CI autotests with screenshots (Linux, xvfb + Mesa)
- [x] Parser unit tests (`tests/`, in CI)
- [x] Screenshot comparison in CI (64x36 block averages against `tests/reference`)
- [x] WebAssembly build deployed to GitHub Pages

### Phase 5 – Polish & reach (done)
- [x] Options menu: sensitivity, invert, FOV, music volume, key bindings (`UserConfig`)
- [x] Skill selection (easy … nightmare)
- [x] Gamepad input (`Controllers`; virtual pad in autotests)
- [x] View and weapon bob, weapon lag, landing dip, damage kicks (items already rotate like `EF_ROTATE`; Quake 2 items don't bob)
- [x] Frame-accurate player weapons (Quake 2 `Weapon_Generic`)
- [x] Frame-accurate monster attacks for the demo monsters (`mframe_t` fire frames, bursts, refire loops)
- [x] Monster perception like Quake 2: ambush, trigger-spawned monsters, front cone, hearing through the PHS, group wake
- [x] Monster dodging (duck under blaster bolts, rockets, BFG balls)
- [x] Monster pursuit along the player trail (Quake 2 `p_trail.c`)
- [x] `trigger_monsterjump`
- [x] Blocked doors / plats hurt and reverse (Quake 2 `door_blocked`, `plat_blocked`)
- [x] Swept player box: box traces against BSP brushes, `PM_StepSlideMove`, movers carry / push the player
- [x] Savegames include projectiles and delayed events
- [x] Map compatibility report (`--map-report`, demo report in docs, checked in CI)
- [x] Android build with touch controls (APK from CI; untested on hardware)

### Phase 6 – Hardware, consistency, full game (next)
- [ ] Try Android touch, a gamepad and a real GPU; tune touch controls
- [x] Menu, console and HUD text sized for phone screens (*Interface Size* option, larger on touch screens; checked with 2400 × 1080 screenshots)
- [x] Launcher icon (`art/icon.png` / `.ico`, original artwork) for Android, Windows and Linux
- [ ] Release signing key for Android
- [x] Monster movement on the BSP traces (`SV_movestep`, `M_CheckBottom`, Quake 2 monster boxes, `M_droptofloor`)
- [x] Monster walk / run frames with Quake 2's per-frame distances (`ai_walk` / `ai_run` tables of the demo monsters)
- [x] Hitscan, projectiles (grenades bounce off the hit plane), monster sight, lasers and the player trail on the BSP traces; barrels solid again
- [x] Movers push monsters, items and corpses (`SV_Push` for all entities; corpses caught in doors are gibbed)
- [x] `record` console command: write the player's inputs as an autotest script (`--demo @file` replays it; CI checks a replay)
- [x] Full-game entities testable on the demo: `spawn` console command; `misc_viper` (+ bomb, bigviper), `misc_blackhole`, `misc_easter*`, `target_blaster`, `target_earthquake` shake, `target_spawner`, `func_killbox`, `trigger_gravity`
- [x] Sky rotation (`skyrotate` / `skyaxis`), water currents and conveyor belts (`PM_AddCurrents`, `func_conveyor`)
- [x] Quake 2 gibs: per-monster pieces and gib health, `VelocityForDamage`, toss / bounce on the brushes, the flyer explodes
- [x] Brush entity texture animation like Quake 2 (button frames, ANIMATED spawnflags)
- [x] `func_clock`, `target_string`, `target_character` (countdowns and clocks on digit brushes)
- [x] Light styles in the model tint (R_LightPoint over all styles of the face below)
- [x] Player death view and gibbing (`player_die`, `LookAtKiller`, dead view angles)
- [x] Turrets (`turret_breach` / `turret_base` / `turret_driver`, `g_turret.c`); tested with console-spawned box turrets on the demo
- [x] Medic revive (`medic_FindDeadMonster`, healing cable, the corpse gets up after the player); tested with a model-less medic on the demo
- [x] Attack tables for the full game's monsters, bosses (retail PAK)
- [x] Tagged release v0.3.0 with Windows, Linux, Android and Web packages (notes from `docs/CHANGELOG.md`)

### Audio
- [x] Audio polish: Quake 2's stereo loudness by direction (`QuakePanLoudness`) and a master limiter (2:1 above a summed gain of 3, `Sounds.UpdateMixer`)

### Phase 7 – Levels (new)
- [x] Level compiler: grid levels (cells with floor / ceiling heights, themes, sky, entities) into Quake 2 IBSP v38 maps at runtime (BSP tree, box brushes, faces, lightmaps, vis)
- [x] Random level generator with Quake / Doom design rules (loops, steps, pillars, platforms, sky rooms, pacing of monsters and items, secret, exit to the next level)
- [x] In-game level editor: paint, heights, sky, themes, entities, undo, generate, save / load, play, export `.bsp`
- [x] Levels in the CGE editor (`TQuakeMap.LevelUrl`, `MapName` `rand<seed>`, `TQuakeLevelEditor` component)
- [x] Doors and water in the level editor and the generator (door brush models, water leaves / brushes / warped surfaces); monsters open doors
- [x] Lifts (`func_plat`) and switches (`func_button` → doors of a channel) in the level editor; the generator adds lifts for big heights and locks the exit behind a switch
- [x] Real visibility for compiled levels: a grid PVS (sight lines between the regions through open cells) and the PHS from it, so random and edited levels are culled like the original maps
- [x] Keys and key doors, slime pits and teleporters in the level editor and the generator (the exit locked by a blue key on even seeds, a teleporter from the secret room back to the start)
- [x] Ladders, lava (a texture made in memory), four more themes (red, brown, and rock / grass outdoors) and outdoor areas with rolling ground, in the editor (Ladder, Lava, Hills tools) and the generator
- [x] Key hunt in random levels: the blue key of the exit in a vault behind red doors, the red key in the open
- [x] Real slopes (ramp cells: tilted floor planes and wedge brushes) in corridors, outdoor ground and the editor; windows between rooms (glass panes)
- [x] The full game's textures as themes (discovered per texture directory of the loaded PAKs) and breakable glass (windows are `func_explosive` glass)
- [x] Diagonal walls: a cell cut at 45 degrees (a vertical diagonal plane over a prism brush), in the editor and across room corners in random levels
- [x] Curved walls: round rooms (an ellipse of cells, its staircase cut with diagonal walls) in random levels and the editor (`editor round`)
- [x] Ambushes: monsters that appear when the player walks into a room (spawnflag 2 + a `trigger_once` over the room) in random levels; box triggers compile into real Quake 2 brush models
- [x] Light styles in compiled levels: up to 4 lightmap blocks per face (flickering / pulsing styles 1–11, switchable lights with a targetname from style 32 like qrad); random levels have rooms with flickering, fluorescent or pulsing lights
- [x] Compiled levels play in other Quake 2 engines: every world face sits on a node on its plane (Quake 2's renderers only draw those), checked in Yamagi Quake II (software and OpenGL)
- [x] Secret doors: Quake 2's `func_door_secret` (shot open, a move down / sideways, a pause, a move back, then back again unless `wait` -1); random levels hide the secret passage behind one that looks like the room's wall; the level editor's *Secret* tool
