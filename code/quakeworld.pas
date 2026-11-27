{ Quake 2 gameplay simulation: weapons, inventory, armor, combat, monster
  attacks, pickups, target/trigger chains, movers and level transitions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson, jsonparser,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes, CastleQuaternions, CastleTimeUtils,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeMap, QuakeMd2, QuakePlayer, QuakePMove, QuakeLight, QuakeSound, QuakeHud, QuakeSettings,
  QuakeParticles, QuakeEntities, QuakeWeaponFrames, QuakeMonsterAttacks, QuakeTrace, QuakeTurret, QuakeInsane;

const
  { Quake 2 player: eye 22 above origin, origin 24 above the feet }
  PlayerEyeHeight = 46.0;

  { Quake 2 temp entities (temp_event_t), as target_temp_entity's "style" }
  TE_GUNSHOT = 0; TE_BLOOD = 1; TE_BLASTER = 2; TE_RAILTRAIL = 3; TE_SHOTGUN = 4;
  TE_EXPLOSION1 = 5; TE_EXPLOSION2 = 6; TE_ROCKET_EXPLOSION = 7; TE_GRENADE_EXPLOSION = 8;
  TE_SPARKS = 9; TE_SPLASH = 10; TE_BUBBLETRAIL = 11; TE_SCREEN_SPARKS = 12;
  TE_SHIELD_SPARKS = 13; TE_BULLET_SPARKS = 14; TE_LASER_SPARKS = 15; TE_PARASITE_ATTACK = 16;
  TE_ROCKET_EXPLOSION_WATER = 17; TE_GRENADE_EXPLOSION_WATER = 18; TE_MEDIC_CABLE_ATTACK = 19;
  TE_BFG_EXPLOSION = 20; TE_BFG_BIGEXPLOSION = 21; TE_BOSSTPORT = 22; TE_BFG_LASER = 23;
  TE_GRAPPLE_CABLE = 24; TE_WELDING_SPARKS = 25;

type
  { Something to do later: use the entities named Target, or (Entity set)
    do Entity's own delayed action (target_explosion) }
  TDelayedTarget = record
    Time: Single;
    Target: String;
    Entity: TQuakeEntity;
  end;

  { A turret_breach with its turret_bases and turret_driver (g_turret.c) }
  TQuakeTurret = class
  public
    Breach: TQuakeMover;
    Bases: array of TQuakeMover;
    Driver: TQuakeMonster;
    { Muzzle offset and bases found (turret_breach_finish_init) }
    Linked: Boolean;
    { Wished angles (move_angles), turning speed (degrees a second), limits }
    MovePitch, MoveYaw: Single;
    Speed: Single;
    Limits: TTurretLimits;
    { The breach's target minus its origin: the rocket's start }
    MoveOrigin: TVector3;
    { The driver's seat (turret_driver_link move_origin) }
    DriverOffset: TVector3;
    { turret_driver_think: when the enemy was (re)acquired, next shot }
    TrailTime, AttackFinished: Single;
    LostSight, HadEnemy: Boolean;
    Shots: Integer;
    { turret_invisible_brain (the remaster's g_turret): a driver without a
      body. It shoots at its killtarget only, once on (at once without a
      targetname, else when used; a second use stops it for good) }
    Brain: TQuakeEntity;
    BrainEnemy: TQuakeEntity;
    BrainOn, BrainStopped: Boolean;
  end;
  TQuakeTurretList = specialize TObjectList<TQuakeTurret>;

  { One player's state in the world (E.2): stats and inventory, view, pmove,
    gun, death and the timers that hurt or warn them. TQuakeWorld acts on
    its CurrentPlayer (player 1 in single player). }
  TQuakePlayer = class
  public
    { 1 .. MaxNetClients }
    Number: Integer;
    { The player of this program's view (HUD, view weapon, 2D sounds) }
    Local: Boolean;
    Stats: TQuakePlayerStats;
    { Eye position and view direction (CGE coordinates) }
    Pos, Dir: TVector3;
    { The player's pmove (the server's: TQuakeServer.PM; not owned) }
    PM: TQuakePMove;
    { Quake 2's weapon frame state machine (owned) }
    Gun: TQuakeGun;
    { Fire held this frame (FireWeapon is called every frame while held) and
      in the previous one (to latch new presses) }
    FireHeld, PrevFireHeld: Boolean;
    { Last time the player fired (Quake 2 show_hostile lasts 1 s) }
    LastFireTime: Single;
    Dead: Boolean;
    DeadTimer: Single;
    { How the player died: gibbed (health below -40), and where the killing
      blow came from (CGE coordinates; the death view turns to it) }
    Gibbed: Boolean;
    KillerPos: TVector3;
    HasKiller: Boolean;
    PainSoundTimer, HurtTimer: Single;
    { The monster that fired the shot hurting the player now (for the
      defender sphere) }
    DamageSource: TQuakeMonster;
    { Air and liquids }
    LastWaterLevel: Integer;
    AirFinished, LiquidDamageTimer: Single;
    { Rebreather / environment suit breathing sounds (u_breath1 / 2) }
    BreathTimer: Single;
    BreathSound: Boolean;
    { trigger_gravity's factor of the player's gravity }
    Gravity: Single;
    { Deathmatch score (Quake 2 resp.score): +1 for killing another player,
      -1 for dying by oneself or the world }
    Frags: Integer;
    { Fire pressed while dead (Quake 2 latched_buttons: respawns in
      deathmatch) }
    LatchedAttack: Boolean;
    { Times the world turned the player itself (spawn, respawn, teleport):
      the server then keeps that view until the client has seen it }
    ViewTurns: Integer;
    constructor Create(const ANumber: Integer);
    destructor Destroy; override;
  end;
  TQuakePlayerList = specialize TObjectList<TQuakePlayer>;

  TWorldPrintEvent = procedure(const Text: String) of object;

  { World simulation manager }
  TQuakeWorld = class
  private
    FViewCamera: TCastleTransform;
    FTurrets: TQuakeTurretList;
    { turret_invisible_brain entities not linked to their breach yet }
    FBrainEnts: TQuakeEntityList;
    FItems: TCastleAbstractRootTransform;
    FMap: TQuakeMap;
    FMapReused: Boolean;
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FPickups: TQuakePickupList;
    FMonsters: TQuakeMonsterList;
    FProjectiles: TQuakeProjectileList;
    FTriggers: TQuakeTriggerList;
    FSpeakers: TQuakeSpeakerList;
    FProps: TQuakePropList;
    FLasers: TQuakeLaserList;
    FVisibleEntities, FCulledEntities: Integer;
    FTimers: specialize TDictionary<TQuakeEntity, Single>; { func_timer -> next fire time (<0: off) }
    FDelayed: specialize TList<TDelayedTarget>;
    FCounters: specialize TDictionary<TQuakeEntity, Integer>;
    { The Reckoning's func_object_repair (welding sparks) and misc_amb4
      (world/amb4.wav): entity -> next time }
    FPeriodic: specialize TDictionary<TQuakeEntity, Single>;
    { func_object_repair's health (100; fixbots weld 10 off a cycle, below
      0 it is repaired: its targets fire, in FCounters, and it heals back) }
    FRepairHealth: specialize TDictionary<TQuakeEntity, Integer>;
    { target_steam's sustained effects: until (level time) and the next puff }
    FSteam: specialize TDictionary<TQuakeEntity, TVector2>;
    FHintPaths: TQuakeHintPaths;
    { The defender sphere, its enemy, its next shot }
    FDefender: TCastleTransform;
    FDefenderModel, FDefenderShell: TQuakeMd2Instance;
    FDefenderEnemy: TQuakeMonster;
    FDefenderCooldown, FDefenderThink: Single;
    { Quake II Remastered dynamic_light entities (not owned; on / off in
      FCounters: 1 / 0) }
    FDynamicLights: TQuakeEntityList;
    { The players (E.2): FCur is the one the world acts on now (player 1 in
      single player) }
    FPlayers: TQuakePlayerList;
    FCur: TQuakePlayer;
    { FHud / FViewPlayer are the view's while the world acts on the local
      player, nil for the others (SetCurrent) }
    FHud, FLocalHud: TQuakeHud;
    FTime: Single;
    FTrailTimer: Single;
    { Monsters that found the player this frame (Quake 2 level.sight_entity) }
    FSightEntities: specialize TList<TQuakeMonster>;
    FWeaponTransform: TCastleTransform;
    FWeaponModel: TQuakeMd2Instance;
    FWeaponModelSlot: Integer;
    FWeaponKick: Single;
    { Monster shots fired (demo log) }
    FMonsterShots: Integer;
    { Brush collision of the current map (player box traces) }
    FCollision: TQuakeCollision;
    { Mover poses of the previous frame, to carry / push the player }
    FMoverPoses: specialize TDictionary<TQuakeMover, TMatrix4>;
    FLevelExited: Boolean;
    FNextMap: String;
    FSpawnPoint: TVector3;
    FSpawnAngle: Single;
    { info_landmark: the one left by (its targetname), the player's place
      relative to it and view yaw relative to its angle }
    FLandmarkName: String;
    FLandmarkLocal: TVector3;
    FLandmarkViewYaw: Single;
    { target_poi: the current point of interest (Quake coordinates), stage }
    FPoiValid: Boolean;
    FPoiPosition: TVector3;
    FPoiStage: Integer;
    FTeleportPending: Boolean;
    FTeleportPos: TVector3;
    FTeleportAngle: Single;
    FRestartPending: Boolean;
    FKeyIcons: TStringList;
    FUseDepth: Integer;
    { The entity whose targets are being used (Quake 2's "other" in use
      functions: trigger_elevator reads its pathtarget); nil if unknown }
    FUseSource: TQuakeEntity;
    { The player whose weapon deals the damage being done now (set while
      a player's gun fires and while a player's projectile moves); nil for
      monsters and the world. Deathmatch frags go to it. }
    FAttacker: TQuakePlayer;
    { Join mode: only brush entities spawn (SpawnEntity); the view
      weapon's frame from the host (UpdateClientView) }
    FClientOnly: Boolean;
    FClientGunFrame: Integer;
    { Death message instead of the generic one (target_changelevel in
      deathmatch: "found a way out") }
    FObituaryText: String;
    FOnBroadcast: TWorldPrintEvent;
    FHelpPrimary, FHelpSecondary: String;
    { The view's movement behaviour (damage kicks) }
    FViewPlayer, FLocalViewPlayer: TQuakePlayerMovement;
    { Pickups spawned from the map; later ones are monsters' drops }
    FMapPickupCount: Integer;
    { Quake 2 game.serverflags: cross-level trigger bits, kept across maps of a unit }
    FServerFlags: Integer;
    { States of levels left through a changelevel in the current unit, by map name }
    FLevelStates: TJSONObject;
    { Bosses blowing up (BossExplode): the next explosion's time, how many }
    FBossExplosions: array of record
      Monster: TQuakeMonster;
      Count: Integer;
      Next: Single;
    end;
    { Makrons to launch from dead Jorgs (MakronToss): level time, place, yaw,
      the Jorg's target }
    FMakronTosses: array of record
      Time: Single;
      Pos: TVector3;
      Yaw: Single;
      Target: String;
    end;
    { target_earthquake shakes: entity -> end time; time of the next shove /
      sound per quake }
    FQuakes: array of record
      Entity: TQuakeEntity;
      EndTime, NextShove, NextSound: Single;
    end;
    FBaseGravity: Single;
    { func_clock timers (Health counts, Wait is the end; NextThink < 0: off) }
    FClocks: array of record
      Entity, Display: TQuakeEntity;
      Health, Wait: Integer;
      NextThink: Single;
      Activated: Boolean;
    end;
    FLastString: String;
    { Medics look for corpses to revive once a second (medic_FindDeadMonster) }
    FMedicTimer: Single;
    procedure ResetClock(const I: Integer);
    procedure ClockThink(const I: Integer);
    procedure UpdateClocks;
    { turret_breach_think / turret_driver_think for every turret }
    procedure UpdateTurrets(const SecondsPassed: Single);
    procedure LinkTurret(const T: TQuakeTurret);
    procedure TurretFire(const T: TQuakeTurret);
    procedure UpdateMedics(const SecondsPassed: Single);
    procedure FindWeldTarget(const Fixbot: TQuakeMonster);
    procedure MonsterRevived(const Monster: TQuakeMonster);
    { target_string_use: write the message on the team's target_characters }
    procedure TargetStringUse(const Ent: TQuakeEntity);
    procedure UpdateEarthquakes;
    { Particles.GibTrace: gibs against the map's brushes and movers }
    function GibTraceMap(const Start, Stop: TVector3; out EndPos, Normal: TVector3): Boolean;
    procedure UpdateFallingProps(const SecondsPassed: Single);
    procedure UpdateFallingObjects(const SecondsPassed: Single);
    procedure DropMonsterItem(const M: TQuakeMonster);
    procedure SetPlayerGravity(const Value: Single);
    { Brush model box, or (entities made by "spawn") origin + mins / maxs fields }
    function EntityBox(const Ent: TQuakeEntity; out Box: TBox3D): Boolean;
    { Quake 2 KillBox: telefrag everything in the box }
    procedure KillBox(const Box: TBox3D);
    procedure UpdateLiquids(const SecondsPassed: Single);
    procedure SetPlayer(const Value: TQuakePMove);
    procedure WirePlayerMove(const PM: TQuakePMove);
    procedure SetHud(const Value: TQuakeHud);
    procedure SetViewPlayer(const Value: TQuakePlayerMovement);
    { Act on P from now on: its stats, pmove, gun... The view's HUD, view
      kicks and 2D sounds only reach the local player }
    procedure SetCurrent(const P: TQuakePlayer);
    function IsLocal: Boolean;
    { The player whose pmove Ent is (a trace hit), nil if none }
    function PlayerOfEnt(const Ent: TObject): TQuakePlayer;
    { The player a monster acts against: the nearest one alive }
    function MonsterTarget(const M: TQuakeMonster): TQuakePlayer;
    { Damage the player a trace hit (Ent: its pmove) }
    procedure DamagePlayerHit(const Ent: TObject; const Amount: Integer; const FromPos: TVector3);
    { The current player's per-tick timers (powerups, items, pain) }
    procedure UpdatePlayerTimers(const SecondsPassed: Single);
    { A player other than the local one died: back at a spawn point }
    procedure RespawnPlayer;
    function GetPlayerPM: TQuakePMove;
    function GetStats: TQuakePlayerStats;
    function GetDead: Boolean;
    function GetPlayerGibbed: Boolean;
    function GetGun: TQuakeGun;
    function GetPlayerGravity: Single;
    procedure PlayerFallDamage(const Damage: Integer);
    procedure PlayerLanded(Sender: TObject);
    procedure ChooseSpawnPoint(const SpawnName: String);
    procedure SpawnEntities(const SpawnName: String);
    function ModelBox(const AModel: String; out Box: TBox3D): Boolean;
    procedure UpdateWeaponModel;
    { The view weapon (frames, kick, light, shells) and the HUD }
    procedure UpdateViewWeaponAndHud(const SecondsPassed: Single);
    procedure CheckPickups;
    procedure CheckTriggers(const SecondsPassed: Single);
    procedure CheckMovers;
    function PlayerBox: TBox3D;
    function GiveItem(const Def: PQuakeItemDef): Boolean;
    procedure MonsterAttack(const Monster: TQuakeMonster);
    { Random entity with this targetname (Quake 2 G_PickTarget), nil if none }
    function PickTarget(const ATargetName: String): TQuakeEntity;
    function DamageMultiplier: Integer;
    procedure FireHitscan(const Origin, Dir: TVector3; const Damage: Integer;
      const HSpread, VSpread: Single; const Rail: Boolean = False);
    procedure ThrowHandGrenade(const Fuse: Single);
    { The Reckoning's trap (weapon_trap_fire) }
    procedure ThrowTrap(const Fuse: Single);
    { Trap_Think every 0.1 s on the ground }
    procedure TrapThink(const Proj: TQuakeProjectile);
    function MoverTrace(const Mover: TQuakeMover; const Start, Stop, Mins, Maxs: TVector3;
      const Mask: Integer): TQuakeTrace;
    { The same with the mover at pose M (its transform matrix) }
    function MoverTraceAt(const Mover: TQuakeMover; const M: TMatrix4;
      const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
    { Movers carry the player standing on them and push him when they
      move into him (Quake 2 SV_Push) }
    procedure PushPlayerByMovers;
    { EntitySightPossible: the PVS, unless novis }
    function SightPossible(const FromPos, ToPos: TVector3): Boolean;
    { WorldTrace without counting it }
    function DoWorldTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
      const Ignore: TObject): TQuakeTrace;
    procedure UpdateGun(const SecondsPassed: Single);
    { Triggers that act on monsters (trigger_monsterjump) }
    procedure CheckMonsterTriggers;
    procedure GunEvent(const Event: TGunEvent);
    function GunAmmo(const Slot: Integer): Integer;
    { Fire the current weapon (the gun reached a fire frame) }
    procedure FireGun;
    { Quake 2 NoAmmoWeaponChange: best weapon with ammo }
    procedure NoAmmoWeaponChange;
    procedure SpawnProjectile(const Kind: TProjectileKind; const Origin, Dir: TVector3;
      const Speed: Single; const Damage: Integer; const FromPlayer: Boolean;
      const Owner: TQuakeMonster = nil);
    procedure UpdateProjectiles(const SecondsPassed: Single);
    { The mutant's jump hurting the player on touch, and the Makrons that
      Jorgs launch when they die }
    procedure UpdateBossesAndLeaps;
    procedure UpdateBossExplosions;
    procedure XatrixMonsterShot(const Monster: TQuakeMonster; const Eye, Dir: TVector3);
    { pkHeatRocket: turn towards the player in sight within 1024 }
    procedure SteerHeatRocket(const Proj: TQuakeProjectile; const SecondsPassed: Single);
    procedure ApplyLandmark;
    procedure PoiUse(const Ent: TQuakeEntity);
    function BrainEnemyPos(const T: TQuakeTurret; out Pos: TVector3): Boolean;
    function UpdateTurretBrain(const T: TQuakeTurret): Boolean;
    { A railgun shot from a monster at Target (CGE): a trace through
      monsters like fire_rail; True if it hit the player }
    function MonsterRail(const Monster: TQuakeMonster; const Eye, Target: TVector3): Boolean;
    { Damage the player's power armor absorbs (and the cells it uses) }
    function AbsorbPlayerPowerArmor(const Damage: Integer; const FromPos: TVector3): Integer;
    { Rebreather, environment suit and power armor timers and sounds }
    procedure UpdatePlayerItems(const SecondsPassed: Single);
    { PlayerNoise(PNOISE_WEAPON), unless the silencer uses up a shot }
    procedure WeaponNoise;
    { 0.2 while the silencer has shots (MZ_SILENCED), else 1 }
    function SilencedVolume: Single;
    { BFG ball in flight (bfg_think): lasers to the monsters (or the player,
      for a monster's ball) within 256 units, through monsters, 10 damage each }
    procedure BfgLasers(const Proj: TQuakeProjectile);
    { BFG effect (bfg_explode, 0.1 s after the impact): everything visible from
      the blast and from the shooter within SplashRadius takes
      SplashDamage * (1 - sqrt(dist / radius)), with a TE_BFG_EXPLOSION on it }
    procedure BfgEffect(const Proj: TQuakeProjectile);
    { Rockets, blaster bolts and BFG balls light their surroundings }
    procedure AddProjectileLights;
    { Send the dynamic lights nearest to the player to the world shader }
    procedure MonsterFoundTarget(const Monster: TQuakeMonster);
    { Non-ambush monsters that see a monster which just found the player
      join in (FindTarget's sight_entity check) }
    procedure ProcessSightEntities;
    { ClientThink: drop a trail spot where the player is when the newest one
      went out of his sight }
    procedure UpdatePlayerTrail(const SecondsPassed: Single);
    procedure SetSurfaceLights;
    procedure CullTransform(const T: TCastleTransform; const Box: TBox3D);
    { The player made a noise at Pos (Quake 2 PlayerNoise): monsters within
      1000 units that can hear it (PHS, connected areas) wake; AMBUSH ones
      only if they also see it }
    procedure PlayerNoise(const Pos: TVector3);
    { Quake 2 check_dodge: the monster first hit by a player's shot from
      Origin along Dir, if it faces the player, may dodge before it arrives
      (easy: a quarter as often) }
    procedure CheckDodge(const Origin, Dir: TVector3; const Speed: Single);
    { Splash damage; IgnorePM is the player hit directly (its pmove), left
      out like T_RadiusDamage's ignore }
    procedure Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
      const FromPlayer: Boolean; const ExplosionSound: Boolean = True; const IgnorePM: TObject = nil);
    { A message for every player (the server prints it to every client) }
    procedure Broadcast(const Text: String);
    { Deathmatch: a info_player_deathmatch for the current player
      (SelectRandomDeathmatchSpawnPoint, or the farthest from the other
      players with DF_SPAWN_FARTHEST); False when the map has none }
    function SelectDeathmatchSpot(out Spot: TQuakeEntity): Boolean;
    { Deathmatch: the frag and the death message (ClientObituary) }
    procedure Obituary(const Killer: TQuakePlayer);
    function MonsterByTransform(const T: TCastleTransform): TQuakeMonster;
    function MoverByTransform(const T: TCastleTransform): TQuakeMover;
    procedure UseEntity(const Ent: TQuakeEntity);
    { Use Ent's targets now, or after its "delay" }
    procedure UseTargetsOf(const Ent: TQuakeEntity);
    function TimerInterval(const Ent: TQuakeEntity): Single;
    function EntityMoveDir(const Ent: TQuakeEntity): TVector3;
    { A transform at the entity origin, for positional one-shot sounds }
    procedure ActivateProp(const Prop: TQuakeProp);
    { A ship / viper / transport starts towards the path_corner its target
      names; False when there is none }
    function StartPropFlight(const Prop: TQuakeProp): Boolean;
    { The Reckoning's misc_viper_missile and misc_nuke, used }
    procedure ViperMissileUse(const Ent: TQuakeEntity);
    procedure NukeUse(const Ent: TQuakeEntity);
    { The Reckoning's target_mal_laser, while on }
    procedure UpdateMalLaser(const Laser: TQuakeLaser; const SecondsPassed: Single);
    { Ground Zero's targets }
    procedure SteamUse(const Ent, Activator: TQuakeEntity);
    procedure SteamPuff(const Ent: TQuakeEntity);
    procedure UpdateSteam;
    procedure AngerUse(const Ent: TQuakeEntity);
    { Ground Zero's defender sphere: above the player, blaster bolts at
      whoever hurt the player }
    procedure UpdateDefender(const SecondsPassed: Single);
    procedure RemoveDefender(const WithExplosion: Boolean);
    { Ground Zero's chainfist hit and plasma beam }
    procedure ChainfistHit(const Origin, Dir: TVector3; const Damage: Integer);
    procedure PlasmaBeam(const Origin, Dir: TVector3; const Damage: Integer);
    { A prox mine stuck and armed: monsters near it, its lifetime }
    procedure ProxThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
    { Ground Zero's tesla: thrown, then opening and zapping }
    procedure ThrowTesla(const Fuse: Single);
    procedure TeslaThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
    { medic_callReinforcements / medic_finish_spawn: the medic commander's
      monsters around it }
    procedure MedicSummon(const Medic: TQuakeMonster);
    { CarrierSpawn (flyers) / WidowSpawn and Widow2Spawn (two stalkers) }
    procedure BossSummon(const Boss: TQuakeMonster);
    { Widow2Beam: monster_fire_heat, a beam hurting what it reaches }
    procedure HeatBeam(const Monster: TQuakeMonster; const Eye, Target: TVector3);
    { The Widow's first form beams out (spawn_out_do), the second's death
      kills her stalkers (KillChildren) }
    procedure UpdateWidows;
    { InitHintPaths: the hint_path chains of the level, for monsters }
    procedure BuildHintPaths;
    function HintPointsVisible(const FromPos, ToPos: TVector3): Boolean;
    procedure KillPlayersUse(const Ent: TQuakeEntity);
    { func_object_repair: its health, think (sparks, repaired) and a fixbot's
      weld cycle on it (True: repaired) }
    function RepairHealth(const Ent: TQuakeEntity): Integer;
    procedure RepairThink(const Ent: TQuakeEntity);
    function WeldCycle(const Target: TQuakeEntity): Boolean;
    function MonsterPointContents(const QuakePos: TVector3): Integer;
    { A Quake 2 temp entity (TE_*) at a CGE point: target_temp_entity, Use_Boss3 }
    procedure TempEntity(const Style: Integer; const Pos: TVector3);
    procedure DamageProp(const Prop: TQuakeProp; const Damage: Integer);
    function PropByTransform(const T: TCastleTransform): TQuakeProp;
    procedure UpdateTimersAndLasers(const SecondsPassed: Single);
    { Shootable brushes: func_explosive, doors / buttons with "health" }
    procedure DamageMover(const Mover: TQuakeMover; const Damage: Integer);
    procedure BreakExplosive(const Mover: TQuakeMover);
    procedure KillPlayer;
    procedure ClearLevel;
  public
    { AMap is the TQuakeMap component inside AItems (usually from the view design). }
    constructor Create(const AItems: TCastleAbstractRootTransform; const AMap: TQuakeMap);
    destructor Destroy; override;

    { Load a map, e.g. "base1" or "base2$spawnname". Keeps the inventory. }
    function LoadMap(const AMapName: String): Boolean;

    { Fire all entities with the given targetname (Quake 2 G_UseTargets) }
    procedure UseTargets(const ATarget: String; const Source: TQuakeEntity = nil);
    procedure ElevatorUse(const Ent, Source: TQuakeEntity);
    procedure UpdateDynamicLights;

    { Advance world simulation. PlayerPos is the camera (eye) position. }
    { One game tick (QuakeTick.TickSeconds): the simulation }
    { One tick. Each player's Pos / Dir are set before (the server's
      commands) }
    procedure Update(const SecondsPassed: Single);
    { Every frame, before the ticks: movers (they carry the player, who moves
      every frame), surface animation and particles }
    procedure UpdateFrame(const SecondsPassed: Single);
    { The transforms a tick may move, drawn between ticks (TQuakeTickClock) }
    procedure CollectMovingTransforms(const List: TCastleTransformList);
    { Hide (Visible := False, still colliding) movers, monsters, items, props
      and lasers outside the PVS / connected areas of the geometry's last
      UpdateVisibility. }
    procedure CullEntities;
    { Give the loop mixer the looping sounds heard from Listener: speakers
      that are on and movers that move, if in the PVS (Quake 2 sends
      entity loop sounds only for entities in the client frame). Call after
      the geometry's UpdateVisibility. }
    procedure UpdateLoopSounds(const Listener: TVector3);
    { Entities shown / considered by the last CullEntities }
    property VisibleEntities: Integer read FVisibleEntities;
    { The player's gun (weapon frames); autotests turn off its random idle pauses }
    property Gun: TQuakeGun read GetGun;
    { Monster shots / hits fired since the level started (demo log) }
    property MonsterShots: Integer read FMonsterShots;
    property CulledEntities: Integer read FCulledEntities;

    { Player fires the current weapon }
    procedure FireWeapon(const Origin, Dir: TVector3);

    { Select weapon slot (1..WeaponSlots) }
    procedure SelectWeapon(const Slot: Integer);
    { The slot a weapon key picks: Slot, or the weapon chained with it }
    function ChainedWeapon(const Slot: Integer): Integer;

    { Health 100 and the blaster, like a new game (cheats off) }
    procedure ResetStats;

    { Press / open what the player is looking at }
    procedure ActivateUse(const Origin, Dir: TVector3);

    { Spawn one entity of the map (or a new one: add it to Bsp.Entities
      first, see the "spawn" console command and target_spawner) }
    procedure SpawnEntity(const Ent: TQuakeEntity);
    { Active target_earthquake shakes }
    function EarthquakeCount: Integer;
    { Last text a target_string showed (for the V log) }
    property LastString: String read FLastString;
    { Gravity multiplier set by trigger_gravity (1 = normal) }
    property PlayerGravity: Single read GetPlayerGravity;

    { Damage the player (armor absorbs part of it) }
    { NoArmor: Quake 2 DAMAGE_NO_ARMOR (drowning): armor and power armor don't help }
    procedure DamagePlayer(const Amount: Integer; const FromPos: TVector3;
      const NoArmor: Boolean = False);
    { Use_PowerArmor: switch the power screen / shield on or off }
    procedure TogglePowerArmor;

    procedure CheatGiveAll;
    procedure CheatGodMode;
    { give quad / give invulnerability: 30 seconds, like the items }
    procedure CheatPowerup(const Quad: Boolean);
    { give <item>: an item by its name ("power shield") or classname, as if
      picked up; False if there is no such item }
    function CheatGiveItem(const AName: String): Boolean;

    { Attach the view weapon to the camera }
    { Put the view weapon under the weapon viewport's Camera; ViewCamera is
      the main viewport's (dynamic lights on the gun are placed through it) }
    procedure AttachWeaponToCamera(const Camera, ViewCamera: TCastleTransform);
    { Send every visible model its nearest dynamic lights (each frame) }
    procedure UpdateModelLights;
    { View weapon bob and lag: degrees, X pitch down, Y yaw left, Z roll }
    procedure SetGunAngles(const Angles: TVector3);

    { Called by the view after it moved the camera to a teleport destination }
    procedure TeleportDone;

    { Savegame: the whole level state (the map must already be loaded for
      LoadState). The view adds the camera. }
    function SaveState: TJSONObject;
    { Remembered states of the other levels of the current unit (for savegames) }
    function UnitLevelsToJson: TJSONObject;
    procedure UnitLevelsFromJson(const Obj: TJSONObject);
    { IncludePlayer = False restores only the level (revisiting a level of the unit) }
    procedure LoadState(const Obj: TJSONObject; const IncludePlayer: Boolean = True);

    { info_player_intermission camera (CGE position, Quake yaw / pitch).
      False if the map has none. }
    function IntermissionSpot(out Pos: TVector3; out Yaw, Pitch: Single): Boolean;

    property Hud: TQuakeHud read FLocalHud write SetHud;
    { Contents bits at a CGE position (liquids, exact ladders) }
    function PlayerPointContents(const CgePos: TVector3): Integer;
    function PlayerTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
    { Everything solid for Mask: map brushes, movers, live monster boxes and
      the player's box, skipping Ignore (Quake 2 SV_Trace) }
    function WorldTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
      const Ignore: TObject): TQuakeTrace;
    procedure PlayerBeforeMove(Sender: TObject);
    { Player movement (pmove), for falling damage and jump pads; may be nil }
    property Player: TQuakePMove read GetPlayerPM write SetPlayer;
    { Every player; the world acts on CurrentPlayer (player 1 in single player) }
    property Players: TQuakePlayerList read FPlayers;
    { "Player N" }
    function PlayerName(const P: TQuakePlayer): String;
    { Deathmatch obituaries for every client (the server sets it) }
    property OnBroadcast: TWorldPrintEvent read FOnBroadcast write FOnBroadcast;
    property CurrentPlayer: TQuakePlayer read FCur;
    { Another player (a client of the server) moved by PM (its pmove: the
      server's, not owned), standing at a spawn point }
    function AddPlayer(const PM: TQuakePMove): TQuakePlayer;
    procedure RemovePlayer(const P: TQuakePlayer);
    { Act on P (the server runs P's commands) }
    procedure SelectPlayer(const P: TQuakePlayer);
    { The current player (not the local one) back at a spawn point }
    procedure RespawnCurrent;
    { The view's movement (view kicks on damage); may be nil }
    property ViewPlayer: TQuakePlayerMovement read FLocalViewPlayer write SetViewPlayer;
    property Stats: TQuakePlayerStats read GetStats;
    property SpawnPoint: TVector3 read FSpawnPoint;
    property SpawnAngle: Single read FSpawnAngle;
    { target_poi: a point of interest was set, and where (Quake coordinates) }
    property PoiValid: Boolean read FPoiValid;
    property PoiPosition: TVector3 read FPoiPosition;
    property LevelExited: Boolean read FLevelExited;
    property NextMap: String read FNextMap;
    property TeleportPending: Boolean read FTeleportPending;
    property TeleportPos: TVector3 read FTeleportPos;
    property TeleportAngle: Single read FTeleportAngle;
    property RestartPending: Boolean read FRestartPending;
    property Dead: Boolean read GetDead;
    property PlayerGibbed: Boolean read GetPlayerGibbed;
    { The killer's position, when the death had one (LookAtKiller) }
    function KillerPosition(out Pos: TVector3): Boolean;
    { The "kill" console command: health 0 and player_die (no gibs, also in
      god mode) }
    procedure Suicide;
    property Monsters: TQuakeMonsterList read FMonsters;
    property WeaponModel: TQuakeMd2Instance read FWeaponModel;
    function ProjectileCount: Integer;
    function DelayedCount: Integer;
    property Pickups: TQuakePickupList read FPickups;
    { A joining client's world: maps load only their brush entities (the
      host runs the game); set before LoadMap }
    property ClientOnly: Boolean read FClientOnly write FClientOnly;
    { Join mode: the view weapon of the weapon the host's snapshots name }
    procedure ShowClientWeapon(const Slot: Integer);
    { Join mode, every frame instead of Update: light styles, the sky,
      model lights, the view weapon on GunFrame and the HUD }
    procedure UpdateClientView(const SecondsPassed: Single; const GunFrame: Integer);
    property Projectiles: TQuakeProjectileList read FProjectiles;
    property Props: TQuakePropList read FProps;
    property Lasers: TQuakeLaserList read FLasers;
    property Turrets: TQuakeTurretList read FTurrets;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Geometry: TQuakeGeometry read FGeometry;
    property Bsp: TQuakeBsp read FBsp;
  end;

{ func_clock_format_countdown: style 0 "%2i", 1 "%2i:%2i", 2 "%2i:%2i:%2i"
  (minutes / seconds zero-padded) }
function ClockText(const Style, Value: Integer): String;
{ target_string_use: the frame of the target_character with this "count"
  (1-based position): 0..9 digits, 10 '-', 11 ':', 12 blank }
function CharacterFrame(const Msg: String; const Count: Integer): Integer;

{ The remaster's info_landmark: a position relative to a landmark (its
  yaw undone, Quake coordinates) and back, for level transitions }
function LandmarkLocal(const Pos, LandmarkOrigin: TVector3; const LandmarkYaw: Single): TVector3;
function LandmarkWorld(const Local, LandmarkOrigin: TVector3; const LandmarkYaw: Single): TVector3;

implementation

function ClockText(const Style, Value: Integer): String;
begin
  case Style of
    0: Result := Format('%2d', [Value]);
    1: Result := Format('%2d:%.2d', [Value div 60, Value mod 60]);
    else Result := Format('%2d:%.2d:%.2d', [Value div 3600, (Value mod 3600) div 60, Value mod 60]);
  end;
end;

function CharacterFrame(const Msg: String; const Count: Integer): Integer;
var
  C: Char;
begin
  if (Count < 1) or (Count > Length(Msg)) then
    Exit(12);
  C := Msg[Count];
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    '-': Result := 10;
    ':': Result := 11;
    else Result := 12;
  end;
end;

const
  SPAWNFLAG_NOT_DEATHMATCH = 2048;
  TRIGGER_TRIGGERED = 4;

  { Armor: normal protection fraction and max count per type }
  ArmorProtection: array[1..3] of Single = (0.3, 0.6, 0.8);
  ArmorMax: array[1..3] of Integer = (50, 100, 200);

  KeyIconNames: array[0..8] of String = ('k_datacd', 'k_powercube', 'k_pyramid',
    'k_dataspin', 'k_security', 'k_bluekey', 'k_redkey', 'k_comhead', 'i_airstrike');

{ CGE box of Quake mins/maxs }
function QuakeBoxToCge(const Mins, Maxs: TVector3): TBox3D;
begin
  Result := Box3D(
    Vector3(Mins.X, Mins.Z, -Maxs.Y),
    Vector3(Maxs.X, Maxs.Z, -Mins.Y));
end;

{ Random direction spread like Quake 2's fire_lead (spread in units at 8192) }
function SpreadDir(const Dir: TVector3; const HSpread, VSpread: Single): TVector3;
var
  Right, Up: TVector3;
begin
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.Length < 0.001 then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Up := TVector3.CrossProduct(Right, Dir).Normalize;
  Result := (Dir * 8192 + Right * ((Random * 2 - 1) * HSpread) +
    Up * ((Random * 2 - 1) * VSpread)).Normalize;
end;

function LandmarkLocal(const Pos, LandmarkOrigin: TVector3; const LandmarkYaw: Single): TVector3;
var
  D: TVector3;
  S, C: Single;
begin
  D := Pos - LandmarkOrigin;
  SinCos(DegToRad(-LandmarkYaw), S, C);
  Result := Vector3(D.X * C - D.Y * S, D.X * S + D.Y * C, D.Z);
end;

function LandmarkWorld(const Local, LandmarkOrigin: TVector3; const LandmarkYaw: Single): TVector3;
var
  S, C: Single;
begin
  SinCos(DegToRad(LandmarkYaw), S, C);
  Result := LandmarkOrigin + Vector3(Local.X * C - Local.Y * S, Local.X * S + Local.Y * C, Local.Z);
end;

{ The colour of a remaster light: "_color" / "rgba" as "r g b [a]" (0..1,
  or 0..255 when a value is above 1) or a packed $RRGGBBAA integer
  (ED_LoadColor); white when missing }
function RemasterLightColor(const Ent: TQuakeEntity): TVector3;
var
  S: String;
  Parts: TStringArray;
  V: array[0..2] of Single;
  I, PackedRgba: Integer;
  Bytes: Boolean;
begin
  Result := Vector3(1, 1, 1);
  S := Trim(Ent.GetField('rgba', Ent.GetField('_color')));
  if S = '' then
    Exit;
  if Pos(' ', S) > 0 then
  begin
    Parts := S.Split([' '], TStringSplitOptions.ExcludeEmpty);
    Bytes := False;
    for I := 0 to 2 do
    begin
      V[I] := 0;
      if I < Length(Parts) then
        V[I] := StrToFloatDef(Parts[I], 0, DefaultFormatSettings);
      if V[I] > 1 then
        Bytes := True;
    end;
    if Bytes then
      for I := 0 to 2 do
        V[I] := V[I] / 255;
    Result := Vector3(V[0], V[1], V[2]);
  end else
  if TryStrToInt(S, PackedRgba) and (PackedRgba <> 0) then
    Result := Vector3((PackedRgba shr 24) and $FF, (PackedRgba shr 16) and $FF, (PackedRgba shr 8) and $FF) / 255;
end;

function MonsterCenter(const M: TQuakeMonster): TVector3;
begin
  Result := CgeToQuake(M.Transform.Translation) + (M.BoxMins + M.BoxMaxs) * 0.5;
end;

{ Dir turned around the vertical by Degrees (Quake yaw: positive is left) }
function YawTurned(const Dir: TVector3; const Degrees: Single): TVector3;
var
  C, S: Single;
begin
  C := Cos(DegToRad(Degrees));
  S := Sin(DegToRad(Degrees));
  { a rotation around CGE +Y, like YawToCgeDir }
  Result := Vector3(Dir.X * C + Dir.Z * S, Dir.Y, -Dir.X * S + Dir.Z * C);
end;

function VecToJson(const V: TVector3): TJSONArray;
begin
  Result := TJSONArray.Create([V.X, V.Y, V.Z]);
end;

function JsonToVec(const A: TJSONData): TVector3;
begin
  Result := TVector3.Zero;
  if (A <> nil) and (A.JSONType = jtArray) and (A.Count = 3) then
    Result := Vector3(A.Items[0].AsFloat, A.Items[1].AsFloat, A.Items[2].AsFloat);
end;

{ Keep the nearer of two traces, like SV_ClipMoveToEntities }
procedure CombineTrace(var Result: TQuakeTrace; const T: TQuakeTrace);
var
  WasStartSolid: Boolean;
begin
  if T.AllSolid or T.StartSolid or (T.Fraction < Result.Fraction) then
  begin
    WasStartSolid := Result.StartSolid;
    if T.AllSolid or (T.Fraction < Result.Fraction) or not Result.StartSolid then
      Result := T
    else
      Result.Ent := T.Ent;
    Result.StartSolid := Result.StartSolid or WasStartSolid or T.StartSolid;
  end;
end;

{$I quakeworld_spawn.inc}
{$I quakeworld_items.inc}
{$I quakeworld_targets.inc}
{$I quakeworld_movers.inc}
{$I quakeworld_props.inc}
{$I quakeworld_weapons.inc}
{$I quakeworld_projectiles.inc}
{$I quakeworld_monsters.inc}
{$I quakeworld_player.inc}
{$I quakeworld_save.inc}

{ TQuakePlayer ----------------------------------------------------------------- }

constructor TQuakePlayer.Create(const ANumber: Integer);
begin
  inherited Create;
  Number := ANumber;
  Gun := TQuakeGun.Create;
  Gravity := 1;
end;

destructor TQuakePlayer.Destroy;
begin
  FreeAndNil(Gun);
  inherited Destroy;
end;

{ TQuakeWorld ------------------------------------------------------------------ }

procedure TQuakeWorld.SetHud(const Value: TQuakeHud);
begin
  FLocalHud := Value;
  if (FCur = nil) or FCur.Local then
    FHud := Value;
end;

procedure TQuakeWorld.SetViewPlayer(const Value: TQuakePlayerMovement);
begin
  FLocalViewPlayer := Value;
  if (FCur = nil) or FCur.Local then
    FViewPlayer := Value;
end;

procedure TQuakeWorld.SetCurrent(const P: TQuakePlayer);
begin
  if (P = nil) or (P = FCur) then
    Exit;
  FCur := P;
  if P.Local then
  begin
    FHud := FLocalHud;
    FViewPlayer := FLocalViewPlayer;
  end else
  begin
    FHud := nil;
    FViewPlayer := nil;
  end;
  Sounds.Mute2D := not P.Local;
end;

procedure TQuakeWorld.SelectPlayer(const P: TQuakePlayer);
begin
  SetCurrent(P);
end;

procedure TQuakeWorld.RespawnCurrent;
begin
  if not IsLocal then
    RespawnPlayer;
end;

function TQuakeWorld.IsLocal: Boolean;
begin
  Result := FCur.Local;
end;

function TQuakeWorld.PlayerOfEnt(const Ent: TObject): TQuakePlayer;
var
  P: TQuakePlayer;
begin
  for P in FPlayers do
    if (P.PM <> nil) and (P.PM = Ent) then
      Exit(P);
  Result := nil;
end;

function TQuakeWorld.MonsterTarget(const M: TQuakeMonster): TQuakePlayer;
var
  P: TQuakePlayer;
  D, Best: Single;
begin
  Result := FPlayers[0];
  if FPlayers.Count = 1 then
    Exit;
  Best := MaxSingle;
  for P in FPlayers do
    if not P.Dead then
    begin
      D := PointsDistance(P.Pos, M.Transform.Translation);
      if D < Best then
      begin
        Best := D;
        Result := P;
      end;
    end;
end;

procedure TQuakeWorld.DamagePlayerHit(const Ent: TObject; const Amount: Integer; const FromPos: TVector3);
var
  Saved, P: TQuakePlayer;
begin
  P := PlayerOfEnt(Ent);
  if P = nil then
    P := FCur;
  Saved := FCur;
  SetCurrent(P);
  try
    DamagePlayer(Amount, FromPos);
  finally
    SetCurrent(Saved);
  end;
end;

function TQuakeWorld.AddPlayer(const PM: TQuakePMove): TQuakePlayer;
var
  Saved: TQuakePlayer;
begin
  Result := TQuakePlayer.Create(FPlayers.Count + 1);
  Result.PM := PM;
  Result.Gun.OnEvent := @GunEvent;
  Result.Gun.OnAmmo := @GunAmmo;
  FPlayers.Add(Result);
  WirePlayerMove(PM);
  Saved := FCur;
  SetCurrent(Result);
  try
    ResetStats;
    RespawnPlayer;
  finally
    SetCurrent(Saved);
  end;
  WritelnLog('QuakeWorld', 'Player %d joined', [Result.Number]);
end;

procedure TQuakeWorld.RemovePlayer(const P: TQuakePlayer);
begin
  if (P = nil) or P.Local then
    Exit;
  if FCur = P then
    SetCurrent(FPlayers[0]);
  WritelnLog('QuakeWorld', 'Player %d left', [P.Number]);
  FPlayers.Remove(P);
end;

procedure TQuakeWorld.RespawnPlayer;
var
  Org: TVector3;
  Angle: Single;
  Spot: TQuakeEntity;
  DMSpot: Boolean;
begin
  FCur.Dead := False;
  FCur.Gibbed := False;
  FCur.HasKiller := False;
  FCur.LatchedAttack := False;
  { Deathmatch respawns start over (PutClientInServer: InitClientPersistant) }
  if Deathmatch or (FCur.Stats.Health <= 0) then
  begin
    ResetStats;
    FCur.Gun.Reset(FCur.Stats.CurrentWeapon);
  end;
  DMSpot := Deathmatch and SelectDeathmatchSpot(Spot);
  if DMSpot then
  begin
    { 1 above the spot (PutClientInServer) }
    Org := Spot.Origin + Vector3(0, 0, 1);
    Angle := Spot.Angle;
  end else
  begin
    { A spawn point beside the map's start, out of the other players }
    Org := CgeToQuake(FSpawnPoint) - Vector3(0, 0, PlayerEyeHeight - 24) +
      Vector3(48 * (FCur.Number - 1), 0, 0);
    Angle := FSpawnAngle;
  end;
  if FCur.PM <> nil then
  begin
    FCur.PM.Origin := Org;
    FCur.PM.ResetState;
    FCur.PM.FindFree(128);
    FCur.Pos := QuakeToCge(FCur.PM.Origin + Vector3(0, 0, FCur.PM.ViewHeight));
  end else
    FCur.Pos := QuakeToCge(Org) + Vector3(0, PlayerEyeHeight - 24, 0);
  FCur.Dir := YawToCgeDir(Angle);
  Inc(FCur.ViewTurns);
  if IsLocal then
  begin
    { The view places the camera (and the server's player), like a teleport }
    FTeleportPending := True;
    FTeleportPos := FCur.Pos;
    FTeleportAngle := Angle;
    if FWeaponTransform <> nil then
      FWeaponTransform.Exists := True;
    UpdateWeaponModel;
  end;
  if Deathmatch then
  begin
    { EV_PLAYER_TELEPORT }
    Particles.SpawnTeleport(FCur.Pos);
    Sounds.PlayAtPoint('sound/misc/tele1.wav', FCur.Pos);
  end;
  WritelnLog('QuakeWorld', 'Player %d spawns at %s', [FCur.Number, CgeToQuake(FCur.Pos).ToString]);
end;

function TQuakeWorld.PlayerName(const P: TQuakePlayer): String;
begin
  Result := 'Player ' + IntToStr(P.Number);
end;

procedure TQuakeWorld.Broadcast(const Text: String);
begin
  WritelnLog('QuakeWorld', 'Broadcast: %s', [Text]);
  if Assigned(FOnBroadcast) then
    FOnBroadcast(Text);
end;

function TQuakeWorld.SelectDeathmatchSpot(out Spot: TQuakeEntity): Boolean;
var
  Spots: array of TQuakeEntity;
  Ent, Spot1, Spot2: TQuakeEntity;
  Range, Range1, Range2, Best: Single;
  I, Count, Selection: Integer;

  { PlayersRangeFromSpot: the nearest other player alive }
  function RangeFrom(const E: TQuakeEntity): Single;
  var
    P: TQuakePlayer;
    Org: TVector3;
  begin
    Result := 9999999;
    for P in FPlayers do
      if (P <> FCur) and not P.Dead then
      begin
        if P.PM <> nil then
          Org := P.PM.Origin
        else
          Org := CgeToQuake(P.Pos);
        Result := Min(Result, PointsDistance(Org, E.Origin));
      end;
  end;

begin
  Spot := nil;
  Spots := nil;
  if FBsp = nil then
    Exit(False);
  for Ent in FBsp.Entities do
    if Ent.ClassName = 'info_player_deathmatch' then
    begin
      SetLength(Spots, Length(Spots) + 1);
      Spots[High(Spots)] := Ent;
    end;
  Count := Length(Spots);
  if Count = 0 then
    Exit(False);
  if DMFlag(DF_SPAWN_FARTHEST) then
  begin
    { SelectFarthestDeathmatchSpawnPoint }
    Best := -1;
    for I := 0 to Count - 1 do
    begin
      Range := RangeFrom(Spots[I]);
      if Range > Best then
      begin
        Best := Range;
        Spot := Spots[I];
      end;
    end;
    Exit(True);
  end;
  { SelectRandomDeathmatchSpawnPoint: any spot but the two nearest to a
    player (when there are more than two) }
  Spot1 := nil;
  Spot2 := nil;
  Range1 := 99999;
  Range2 := 99999;
  for I := 0 to Count - 1 do
  begin
    Range := RangeFrom(Spots[I]);
    if Range < Range1 then
    begin
      Range2 := Range1;
      Spot2 := Spot1;
      Range1 := Range;
      Spot1 := Spots[I];
    end else
    if Range < Range2 then
    begin
      Range2 := Range;
      Spot2 := Spots[I];
    end;
  end;
  if Count <= 2 then
  begin
    Spot1 := nil;
    Spot2 := nil;
  end else
  begin
    if Spot1 <> nil then
      Dec(Count);
    if Spot2 <> nil then
      Dec(Count);
  end;
  Selection := Random(Count);
  for I := 0 to High(Spots) do
    if (Spots[I] <> Spot1) and (Spots[I] <> Spot2) then
    begin
      if Selection = 0 then
      begin
        Spot := Spots[I];
        Break;
      end;
      Dec(Selection);
    end;
  if Spot = nil then
    Spot := Spots[0];
  Result := True;
end;

procedure TQuakeWorld.Obituary(const Killer: TQuakePlayer);
var
  Text: String;
begin
  if not Deathmatch then
    Exit;
  if FObituaryText <> '' then
  begin
    Text := PlayerName(FCur) + ' ' + FObituaryText;
    Dec(FCur.Frags);
  end else
  if (Killer <> nil) and (Killer <> FCur) then
  begin
    Text := PlayerName(FCur) + ' was killed by ' + PlayerName(Killer);
    Inc(Killer.Frags);
  end else
  begin
    if Killer = FCur then
      Text := PlayerName(FCur) + ' killed themselves'
    else
      Text := PlayerName(FCur) + ' died';
    Dec(FCur.Frags);
  end;
  Broadcast(Text + '.');
end;

function TQuakeWorld.GetPlayerPM: TQuakePMove;
begin
  Result := FCur.PM;
end;

function TQuakeWorld.GetStats: TQuakePlayerStats;
begin
  Result := FCur.Stats;
end;

function TQuakeWorld.GetDead: Boolean;
begin
  Result := FCur.Dead;
end;

function TQuakeWorld.GetPlayerGibbed: Boolean;
begin
  Result := FCur.Gibbed;
end;

function TQuakeWorld.GetGun: TQuakeGun;
begin
  Result := FCur.Gun;
end;

function TQuakeWorld.GetPlayerGravity: Single;
begin
  Result := FCur.Gravity;
end;

constructor TQuakeWorld.Create(const AItems: TCastleAbstractRootTransform; const AMap: TQuakeMap);
begin
  inherited Create;
  FItems := AItems;
  FMap := AMap;
  Sounds.WorldParent := AItems;
  FPickups := TQuakePickupList.Create(True);
  FMonsters := TQuakeMonsterList.Create(True);
  FTurrets := TQuakeTurretList.Create(True);
  FBrainEnts := TQuakeEntityList.Create(False);
  FSightEntities := specialize TList<TQuakeMonster>.Create;
  FMoverPoses := specialize TDictionary<TQuakeMover, TMatrix4>.Create;
  PlayerBlockBox := TBox3D.Empty;
  EntityTrace := @WorldTrace;
  EntitySightPossible := @SightPossible;
  EntityPointContents := @MonsterPointContents;
  HintSight := @HintPointsVisible;
  MonsterWeldCycle := @WeldCycle;
  FPlayers := TQuakePlayerList.Create(True);
  FCur := TQuakePlayer.Create(1);
  FCur.Local := True;
  FPlayers.Add(FCur);
  FCur.Gun.OnEvent := @GunEvent;
  FCur.Gun.OnAmmo := @GunAmmo;
  PlayerTrail := TQuakePlayerTrail.Create;
  FProjectiles := TQuakeProjectileList.Create(True);
  FTriggers := TQuakeTriggerList.Create(True);
  FSpeakers := TQuakeSpeakerList.Create(True);
  FProps := TQuakePropList.Create(True);
  FLasers := TQuakeLaserList.Create(True);
  FTimers := specialize TDictionary<TQuakeEntity, Single>.Create;
  FPeriodic := specialize TDictionary<TQuakeEntity, Single>.Create;
  FRepairHealth := specialize TDictionary<TQuakeEntity, Integer>.Create;
  FSteam := specialize TDictionary<TQuakeEntity, TVector2>.Create;
  FDelayed := specialize TList<TDelayedTarget>.Create;
  FCounters := specialize TDictionary<TQuakeEntity, Integer>.Create;
  FDynamicLights := TQuakeEntityList.Create(False);
  FKeyIcons := TStringList.Create;
  FLevelStates := TJSONObject.Create;
  FWeaponTransform := TCastleTransform.Create(nil);
  FWeaponModelSlot := -1;
  ResetStats;
  Particles.GibTrace := @GibTraceMap;
end;

destructor TQuakeWorld.Destroy;
begin
  if Particles <> nil then
    Particles.GibTrace := nil;
  Sounds.ClearLoops;
  Sounds.WorldParent := nil;
  ClearLevel;
  FreeAndNil(FWeaponModel);
  FreeAndNil(FWeaponTransform);
  FCur := nil;
  FreeAndNil(FPlayers);
  FreeAndNil(FMoverPoses);
  EntityTrace := nil;
  EntitySightPossible := nil;
  EntityPointContents := nil;
  HintSight := nil;
  MonsterWeldCycle := nil;
  FreeAndNil(FCollision);
  FPickups.Free;
  FMonsters.Free;
  FTurrets.Free;
  FBrainEnts.Free;
  FSightEntities.Free;
  FreeAndNil(PlayerTrail);
  FProjectiles.Free;
  FTriggers.Free;
  FSpeakers.Free;
  FProps.Free;
  FLasers.Free;
  FTimers.Free;
  FDelayed.Free;
  FCounters.Free;
  FPeriodic.Free;
  FRepairHealth.Free;
  RemoveDefender(False);
  FSteam.Free;
  if HintPaths = FHintPaths then
    HintPaths := nil;
  FreeAndNil(FHintPaths);
  FDynamicLights.Free;
  FKeyIcons.Free;
  FLevelStates.Free;
  inherited Destroy;
end;

procedure TQuakeWorld.CullTransform(const T: TCastleTransform; const Box: TBox3D);
begin
  if not T.Exists then
    Exit;
  T.Visible := FGeometry.BoxVisible(Box);
  if T.Visible then
    Inc(FVisibleEntities)
  else
    Inc(FCulledEntities);
end;

procedure TQuakeWorld.UpdateLoopSounds(const Listener: TVector3);
var
  Proj: TQuakeProjectile;
  Speaker: TQuakeSpeaker;
  Mover: TQuakeMover;
  Pos: TVector3;
begin
  Sounds.BeginLoops(Listener);
  if FGeometry <> nil then
  begin
    for Speaker in FSpeakers do
      if Speaker.Playing then
      begin
        Pos := Speaker.Transform.Translation;
        if (Speaker.Attenuation <= 0) or FGeometry.BoxVisible(Box3DAroundPoint(Pos, 8)) then
          Sounds.AddLoop(Speaker.Path, Pos, Speaker.Source.Volume, Speaker.Attenuation);
      end;
    for Mover in FGeometry.Movers do
      if Mover.MoveSoundOn and Mover.Transform.Exists and FGeometry.BoxVisible(Mover.WorldBox) then
        Sounds.AddLoop(Mover.MoveSound, Mover.Center);
  end;
  { Traps hum (traploop) or suck (trapsuck) }
  for Proj in FProjectiles do
    if (Proj.Kind = pkTrap) and (Proj.TrapFrame < 8) then
    begin
      if Proj.TrapSucking then
        Sounds.AddLoop('sound/weapons/trapsuck.wav', Proj.Transform.Translation)
      else
        Sounds.AddLoop('sound/weapons/traploop.wav', Proj.Transform.Translation);
    end;
  { The player's weapon sound (chaingun / hyperblaster spin, grenade fuse) }
  if (FCur.Gun.LoopSound <> '') and not FCur.Dead then
    Sounds.AddLoop(FCur.Gun.LoopSound, Listener);
  Sounds.EndLoops;
end;

procedure TQuakeWorld.CullEntities;
var
  Mover: TQuakeMover;
  Monster: TQuakeMonster;
  Pickup: TQuakePickup;
  Prop: TQuakeProp;
  Laser: TQuakeLaser;
begin
  FVisibleEntities := 0;
  FCulledEntities := 0;
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
    CullTransform(Mover.Transform, Mover.WorldBox);
  for Monster in FMonsters do
    CullTransform(Monster.Transform, Monster.Transform.BoundingBox);
  for Pickup in FPickups do
    CullTransform(Pickup.Transform, Pickup.Transform.BoundingBox);
  for Prop in FProps do
    CullTransform(Prop.Transform, Prop.Transform.BoundingBox);
  for Laser in FLasers do
    CullTransform(Laser.Transform, Laser.Transform.BoundingBox);
end;

procedure TQuakeWorld.UpdatePlayerTimers(const SecondsPassed: Single);
begin
  FCur.Stats.LevelTime := FCur.Stats.LevelTime + SecondsPassed;
  FCur.Stats.QuadTime := Max(0, FCur.Stats.QuadTime - SecondsPassed);
  FCur.Stats.InvulnTime := Max(0, FCur.Stats.InvulnTime - SecondsPassed);
  { DualFire: quadfire2.wav as it starts to fade (3 s left) }
  if (FCur.Stats.QuadFireTime > 3) and (FCur.Stats.QuadFireTime - SecondsPassed <= 3) then
    Sounds.Play('sound/items/quadfire2.wav', 1, chItem);
  FCur.Stats.QuadFireTime := Max(0, FCur.Stats.QuadFireTime - SecondsPassed);
  FCur.Gun.Haste := FCur.Stats.QuadFireTime > 0;
  { Double damage: ddamage2.wav 3 s before it ends }
  if (FCur.Stats.DoubleTime > 3) and (FCur.Stats.DoubleTime - SecondsPassed <= 3) then
    Sounds.Play('sound/misc/ddamage2.wav', 1, chItem);
  FCur.Stats.DoubleTime := Max(0, FCur.Stats.DoubleTime - SecondsPassed);
  FCur.Stats.IRTime := Max(0, FCur.Stats.IRTime - SecondsPassed);
  UpdatePlayerItems(SecondsPassed);
  { The defender sphere is one object: the local player's }
  if IsLocal then
    UpdateDefender(SecondsPassed);
  FCur.PainSoundTimer := FCur.PainSoundTimer - SecondsPassed;
end;

procedure TQuakeWorld.Update(const SecondsPassed: Single);
var
  I: Integer;
  M: TQuakeMonster;
  D: TDelayedTarget;
  P, Local: TQuakePlayer;
begin
  if FBsp = nil then
    Exit;
  Local := FPlayers[0];
  SetCurrent(Local);
  PlayerShowHostile := (FCur.LastFireTime > 0) and (FTime - FCur.LastFireTime < 1);
  UpdatePlayerTrail(SecondsPassed);
  FTime := FTime + SecondsPassed;
  for P in FPlayers do
  begin
    SetCurrent(P);
    UpdatePlayerTimers(SecondsPassed);
  end;
  SetCurrent(Local);
  IRGogglesOn := FCur.Stats.IRTime > 0;
  { Projectile lights of the previous frame }
  Lighting.EndFrame;
  UpdateDynamicLights;

  for P in FPlayers do
    if P.Dead then
    begin
      SetCurrent(P);
      FCur.DeadTimer := FCur.DeadTimer - SecondsPassed;
      if Deathmatch then
      begin
        { ClientBeginServerFrame: after a second, fire (or DF_FORCE_RESPAWN)
          respawns }
        if (FCur.DeadTimer <= 0) and (FCur.LatchedAttack or DMFlag(DF_FORCE_RESPAWN)) then
          RespawnPlayer;
        FCur.LatchedAttack := False;
      end else
      if FCur.DeadTimer <= 0 then
      begin
        if IsLocal then
        begin
          FRestartPending := True;
          ResetStats;
        end else
          RespawnPlayer;
      end;
    end;
  SetCurrent(Local);

  { Delayed target firing }
  for I := FDelayed.Count - 1 downto 0 do
    if FDelayed[I].Time <= FTime then
    begin
      D := FDelayed[I];
      FDelayed.Delete(I);
      if (D.Entity <> nil) and (D.Entity.ClassName = 'target_explosion') then
        Explode(QuakeToCge(D.Entity.Origin), D.Entity.GetInt('dmg', 0), 120, False)
      else
        UseTargets(D.Target);
    end;

  for I := 0 to FPickups.Count - 1 do
  begin
    { Deathmatch: picked items come back (DoRespawn) }
    if FPickups[I].Collected and (FPickups[I].RespawnTime > 0) then
    begin
      FPickups[I].RespawnTime := FPickups[I].RespawnTime - SecondsPassed;
      if FPickups[I].RespawnTime <= 0 then
      begin
        FPickups[I].RespawnTime := 0;
        FPickups[I].Collected := False;
        Sounds.PlayAtPoint('sound/items/respawn1.wav', FPickups[I].Origin);
        WritelnLog('QuakeWorld', '%s respawned', [FPickups[I].Def^.ClassName]);
      end;
    end;
    FPickups[I].UpdatePickup(SecondsPassed);
  end;
  for P in FPlayers do
  begin
    SetCurrent(P);
    if not FCur.Dead then
    begin
      CheckPickups;
      CheckTriggers(SecondsPassed);
      CheckMovers;
    end;
  end;
  SetCurrent(Local);

  { Player-clip brushes only block the player (Quake 2 MASK_MONSTERSOLID) }
  FGeometry.ScenePlayerClip.Collides := False;
  for M in FMonsters do
  begin
    { The monster acts against its target player: its attacks and the
      world's callbacks see that one as the current player }
    SetCurrent(MonsterTarget(M));
    if M.AngerActive then
      M.UpdateAI(SecondsPassed, M.AngerPos)
    else
      M.UpdateAI(SecondsPassed, FCur.Pos);
    SetCurrent(Local);
    if (not M.IsAlive) and not M.KillCounted then
    begin
      M.KillCounted := True;
      if not (M.GoodGuy or M.DoNotCount) then
        Inc(FCur.Stats.Kills);
      { monster_death_use: a monster with an "item" drops it (Drop_Item) }
      if M.Entity.GetField('item') <> '' then
        DropMonsterItem(M);
      { Dead monsters fire their targets (Quake 2 monster_death_use) }
      UseTargets(M.DeathTarget);
      { jorg_die: MakronToss on death frame 49, MakronSpawn 0.8 s later,
        with Jorg's target }
      if M.Def^.ClassName = 'monster_jorg' then
      begin
        SetLength(FMakronTosses, Length(FMakronTosses) + 1);
        FMakronTosses[High(FMakronTosses)].Time := FTime + 4.8 + 0.8;
        FMakronTosses[High(FMakronTosses)].Pos := M.Transform.Translation;
        FMakronTosses[High(FMakronTosses)].Yaw := M.FacingAngle;
        FMakronTosses[High(FMakronTosses)].Target := M.Entity.Target;
        WritelnLog('QuakeWorld', '%s died: the Makron comes out in 5.6 s', [M.Transform.Name]);
      end;
    end;
  end;
  ProcessSightEntities;
  UpdateBossesAndLeaps;
  UpdateTurrets(SecondsPassed);
  FGeometry.ScenePlayerClip.Collides := True;

  CheckMonsterTriggers;
  UpdateTimersAndLasers(SecondsPassed);
  for P in FPlayers do
  begin
    SetCurrent(P);
    UpdateLiquids(SecondsPassed);
    UpdateGun(SecondsPassed);
  end;
  SetCurrent(Local);
  UpdateProjectiles(SecondsPassed);
  FAttacker := nil;
  UpdateFallingProps(SecondsPassed);
  UpdateFallingObjects(SecondsPassed);
  UpdateClocks;
  UpdateMedics(SecondsPassed);
  FMap.UpdateSkyRotation(FCur.Stats.LevelTime);
  UpdateEarthquakes;
  AddProjectileLights;
  Lighting.Update(SecondsPassed);
  SetSurfaceLights;
  UpdateModelLights;

  UpdateViewWeaponAndHud(SecondsPassed);
end;

procedure TQuakeWorld.UpdateViewWeaponAndHud(const SecondsPassed: Single);
var
  Shell: TVector3;
  Kick: Single;
  I: Integer;
  A: TAmmoType;
begin
  { View weapon: gun frames, kick and lighting }
  FWeaponKick := Max(0, FWeaponKick - SecondsPassed * 6);
  if FWeaponModel <> nil then
  begin
    { Join mode: the frame the host's snapshot named }
    if FClientOnly and (FClientGunFrame >= 0) then
      FWeaponModel.ShowFrames(FClientGunFrame, FClientGunFrame, 0)
    else
      FWeaponModel.ShowFrames(FCur.Gun.OldFrame, FCur.Gun.Frame, FCur.Gun.FrameLerp);
    FWeaponModel.SetTint(Lighting.SampleLight(FCur.Pos - Vector3(0, 20, 0)));
    { Powerup shells: quad RF_SHELL_BLUE, invulnerability RF_SHELL_RED;
      they blink in the last 3 seconds, like the Quake 2 HUD icons }
    Shell := TVector3.Zero;
    if (FCur.Stats.QuadTime > 3) or ((FCur.Stats.QuadTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(0, 0, 1)
    else
    { EF_DOUBLE: a gold shell }
    if (FCur.Stats.DoubleTime > 3) or ((FCur.Stats.DoubleTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(0.6, 0.45, 0);
    if (FCur.Stats.InvulnTime > 3) or ((FCur.Stats.InvulnTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(1, 0, 0);
    FWeaponModel.SetShell(Shell);
  end;
  Kick := FWeaponKick;
  FWeaponTransform.Translation := Vector3(0, -Kick * 1.0, Kick * 3.0);

  { Inventory to HUD }
  FKeyIcons.Clear;
  for I := 0 to High(KeyIconNames) do
    if (FCur.Stats.Keys and (1 shl I)) <> 0 then
      FKeyIcons.Add(KeyIconNames[I]);
  A := WeaponDefs[FCur.Stats.CurrentWeapon].AmmoType;
  if FHud <> nil then
  begin
    FHud.ShowFrags := Deathmatch;
    FHud.Frags := FCur.Frags;
    FHud.Update(SecondsPassed, FCur.Stats, WeaponDefs[FCur.Stats.CurrentWeapon].Icon, AmmoIcons[A], FKeyIcons);
  end;
end;

procedure TQuakeWorld.UpdateClientView(const SecondsPassed: Single; const GunFrame: Integer);
begin
  if FBsp = nil then
    Exit;
  { What Update does for the view, without the game: light styles, the
    sky, model lights, the view weapon on the host's frame and the HUD }
  FMap.UpdateSkyRotation(FCur.Stats.LevelTime);
  Lighting.Update(SecondsPassed);
  SetSurfaceLights;
  UpdateModelLights;
  FClientGunFrame := GunFrame;
  UpdateViewWeaponAndHud(SecondsPassed);
end;

procedure TQuakeWorld.UpdateFrame(const SecondsPassed: Single);
begin
  if FBsp = nil then
    Exit;
  FGeometry.Update(SecondsPassed);
  Particles.Update(SecondsPassed);
end;

procedure TQuakeWorld.UpdateModelLights;

  function ShownInWorld(T: TCastleTransform): Boolean;
  begin
    while T <> nil do
    begin
      if not (T.Exists and T.Visible) then
        Exit(False);
      T := T.Parent;
    end;
    Result := True;
  end;

var
  Inst: TQuakeMd2Instance;
  Lights: TQuakeSurfaceLights;
  Count: Integer;
  Pos: TVector3;
  ToLocal: TMatrix4;
  WeaponView: Boolean;
begin
  for Inst in Md2Instances do
  begin
    if (Inst.Scene = nil) or (Inst.Scene.World = nil) or not ShownInWorld(Inst.Scene) then
      Continue;
    { The gun is drawn by its own viewport, in front of its camera }
    WeaponView := (Inst = FWeaponModel) and (FViewCamera <> nil) and
      (FWeaponTransform.Parent <> nil);
    if WeaponView then
      Pos := FCur.Pos
    else
      Pos := Inst.Scene.WorldTransform.MultPoint(TVector3.Zero);
    Count := Lighting.NearestLights(Pos, Lights);
    if (Count = 0) and (Inst.DynamicLightCount = 0) then
      Continue;
    if WeaponView then
      ToLocal := Inst.Scene.WorldInverseTransform *
        FWeaponTransform.Parent.WorldTransform * FViewCamera.WorldInverseTransform
    else
      ToLocal := Inst.Scene.WorldInverseTransform;
    Inst.SetDynamicLights(Lights, Count, ToLocal);
  end;
end;

procedure TQuakeWorld.CollectMovingTransforms(const List: TCastleTransformList);
var
  M: TQuakeMonster;
  Pickup: TQuakePickup;
  Prop: TQuakeProp;
  I: Integer;
begin
  List.Clear;
  for M in FMonsters do
    if (M.Transform <> nil) and not M.Dormant then
      List.Add(M.Transform);
  for Pickup in FPickups do
    if (Pickup.Transform <> nil) and not Pickup.Collected then
      List.Add(Pickup.Transform);
  for Prop in FProps do
    if Prop.Transform <> nil then
      List.Add(Prop.Transform);
  for I := 0 to FProjectiles.Count - 1 do
    if FProjectiles[I].Transform <> nil then
      List.Add(FProjectiles[I].Transform);
end;

function TQuakeWorld.WorldTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
  const Ignore: TObject): TQuakeTrace;
var
  T0: TTimerResult;
begin
  Inc(TraceCount);
  if not TraceTiming then
    Exit(DoWorldTrace(Start, Stop, Mins, Maxs, Mask, Ignore));
  T0 := Timer;
  Result := DoWorldTrace(Start, Stop, Mins, Maxs, Mask, Ignore);
  TraceSeconds := TraceSeconds + TimerSeconds(Timer, T0);
end;

function TQuakeWorld.SightPossible(const FromPos, ToPos: TVector3): Boolean;
begin
  Result := (FGeometry = nil) or FGeometry.NoVis or FGeometry.MaybeVisible(FromPos, ToPos);
end;

function TQuakeWorld.DoWorldTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
  const Ignore: TObject): TQuakeTrace;
var
  P: TQuakePlayer;
  Mover: TQuakeMover;
  Monster: TQuakeMonster;
  Prop: TQuakeProp;
  PropContents: Integer;
  Lo, Hi, A, B, Org, BMin, BMax: TVector3;
  Box: TBox3D;
  T: TQuakeTrace;

  function Overlaps(const BMins, BMaxs: TVector3): Boolean;
  begin
    Result := not ((BMins.X > Hi.X) or (BMaxs.X < Lo.X) or (BMins.Y > Hi.Y) or
      (BMaxs.Y < Lo.Y) or (BMins.Z > Hi.Z) or (BMaxs.Z < Lo.Z));
  end;

begin
  { No map (it was missing): nothing to hit }
  if FBsp = nil then
  begin
    Result := Default(TQuakeTrace);
    Result.Fraction := 1;
    Result.EndPos := Stop;
    Exit;
  end;
  if (FCollision = nil) or (FCollision.Bsp <> FBsp) then
  begin
    FreeAndNil(FCollision);
    FCollision := TQuakeCollision.Create(FBsp);
  end;
  Result := FCollision.BoxTrace(Start, Stop, Mins, Maxs, 0, Mask);
  if Result.AllSolid then
    Exit;
  { Swept bounds, to skip entities far away }
  Lo := Vector3(Min(Start.X, Stop.X), Min(Start.Y, Stop.Y), Min(Start.Z, Stop.Z)) + Mins - Vector3(1, 1, 1);
  Hi := Vector3(Max(Start.X, Stop.X), Max(Start.Y, Stop.Y), Max(Start.Z, Stop.Z)) + Maxs + Vector3(1, 1, 1);
  if FGeometry <> nil then
    for Mover in FGeometry.Movers do
    begin
      { Model 0: console-spawned box movers, only doors are solid (MoverTraceAt) }
      if (Mover = Ignore) or (not Mover.Transform.Exists) or (Mover.ModelIndex >= FBsp.ModelCount) or
         ((Mover.ModelIndex <= 0) and not (Mover.Kind in [mkDoor, mkSecretDoor])) then
        Continue;
      Box := Mover.WorldBox;
      if Box.IsEmpty then
        Continue;
      A := CgeToQuake(Box.Data[0]);
      B := CgeToQuake(Box.Data[1]);
      if not Overlaps(Vector3(Min(A.X, B.X), Min(A.Y, B.Y), Min(A.Z, B.Z)),
        Vector3(Max(A.X, B.X), Max(A.Y, B.Y), Max(A.Z, B.Z))) then
        Continue;
      T := MoverTrace(Mover, Start, Stop, Mins, Maxs, Mask);
      CombineTrace(Result, T);
      if Result.AllSolid then
        Exit;
    end;
  { Props: barrels are solid boxes; dead soldiers only stop shots }
  for Prop in FProps do
  begin
    if (Prop = Ignore) or Prop.Destroyed or (Prop.Transform = nil) or (not Prop.Transform.Exists) then
      Continue;
    { rotating_light: SOLID_BBOX, shootable }
    if Prop.Kind in [pkExplobox, pkRotatingLight] then
      PropContents := CONTENTS_MONSTER
    else
    if Prop.Kind = pkDeadSoldier then
      PropContents := CONTENTS_DEADMONSTER
    else
      Continue;
    if (Mask and PropContents) = 0 then
      Continue;
    Box := Prop.Transform.BoundingBox;
    if Box.IsEmpty then
      Continue;
    A := CgeToQuake(Box.Data[0]);
    B := CgeToQuake(Box.Data[1]);
    BMin := Vector3(Min(A.X, B.X), Min(A.Y, B.Y), Min(A.Z, B.Z));
    BMax := Vector3(Max(A.X, B.X), Max(A.Y, B.Y), Max(A.Z, B.Z));
    if not Overlaps(BMin, BMax) then
      Continue;
    T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, BMin, BMax, PropContents);
    if T.Hit then
    begin
      T.Ent := Prop;
      CombineTrace(Result, T);
    end;
  end;
  if (Mask and (CONTENTS_MONSTER or CONTENTS_DEADMONSTER)) = 0 then
    Exit;
  { Live monsters are boxes; corpses (SVF_DEADMONSTER) only for shots }
  for Monster in FMonsters do
  begin
    if (Monster = Ignore) or Monster.Dormant or (Monster.Transform = nil) or
       (not Monster.Transform.Exists) or Monster.Gibbed then
      Continue;
    if Monster.IsAlive and ((Mask and CONTENTS_MONSTER) = 0) then
      Continue;
    if (not Monster.IsAlive) and ((Mask and CONTENTS_DEADMONSTER) = 0) then
      Continue;
    Org := Monster.Origin;
    if not Overlaps(Org + Monster.BoxMins, Org + Monster.ShotBoxMaxs) then
      Continue;
    if Monster.IsAlive then
      T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, Org + Monster.BoxMins, Org + Monster.ShotBoxMaxs,
        CONTENTS_MONSTER)
    else
      { A corpse lies low: Quake 2 dead monsters get maxs z -8 }
      T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, Org + Monster.BoxMins,
        Vector3(Monster.BoxMaxs.X, Monster.BoxMaxs.Y, Monster.BoxMins.Z + 16), CONTENTS_DEADMONSTER);
    if T.Hit then
    begin
      T.Ent := Monster;
      CombineTrace(Result, T);
      if Result.AllSolid then
        Exit;
    end;
  end;
  { The players' boxes (for monsters, their shots and the other players) }
  if (Mask and CONTENTS_MONSTER) <> 0 then
    for P in FPlayers do
      if (P.PM <> nil) and (Ignore <> P.PM) and not P.Dead then
      begin
        Org := P.PM.Origin;
        if Overlaps(Org + P.PM.BoxMins, Org + P.PM.BoxMaxs) then
        begin
          T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, Org + P.PM.BoxMins, Org + P.PM.BoxMaxs,
            CONTENTS_MONSTER);
          if T.Hit then
          begin
            T.Ent := P.PM;
            CombineTrace(Result, T);
          end;
        end;
      end;
end;

end.
