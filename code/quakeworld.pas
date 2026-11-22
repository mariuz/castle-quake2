{ Quake 2 gameplay simulation: weapons, inventory, armor, combat, monster
  attacks, pickups, target/trigger chains, movers and level transitions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson, jsonparser,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes, CastleQuaternions, CastleTimeUtils,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeMap, QuakeMd2, QuakePlayer, QuakeLight, QuakeSound, QuakeHud, QuakeSettings,
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

  { World simulation manager }
  TQuakeWorld = class
  private
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
    { The monster that fired the shot hurting the player now (for the
      defender sphere); the sphere, its enemy, its next shot }
    FDamageSource: TQuakeMonster;
    FDefender: TCastleTransform;
    FDefenderModel, FDefenderShell: TQuakeMd2Instance;
    FDefenderEnemy: TQuakeMonster;
    FDefenderCooldown, FDefenderThink: Single;
    { Quake II Remastered dynamic_light entities (not owned; on / off in
      FCounters: 1 / 0) }
    FDynamicLights: TQuakeEntityList;
    FStats: TQuakePlayerStats;
    FHud: TQuakeHud;
    FPlayerPos: TVector3;
    FPlayerDir: TVector3;
    FTime: Single;
    { Last time the player fired (Quake 2 show_hostile lasts 1 s) }
    FLastFireTime: Single;
    FTrailTimer: Single;
    { Monsters that found the player this frame (Quake 2 level.sight_entity) }
    FSightEntities: specialize TList<TQuakeMonster>;
    FWeaponTransform: TCastleTransform;
    FWeaponModel: TQuakeMd2Instance;
    FWeaponModelSlot: Integer;
    FWeaponKick: Single;
    { The player's gun: Quake 2's weapon frame state machine }
    FGun: TQuakeGun;
    { Fire held this frame (FireWeapon is called every frame while held) and
      in the previous one (to latch new presses) }
    FFireHeld, FPrevFireHeld: Boolean;
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
    FDead: Boolean;
    FDeadTimer: Single;
    { How the player died: gibbed (health below -40), and where the killing
      blow came from (CGE coordinates; the death view turns to it) }
    FPlayerGibbed: Boolean;
    FKillerPos: TVector3;
    FHasKiller: Boolean;
    FRestartPending: Boolean;
    FPainSoundTimer: Single;
    FHurtTimer: Single;
    FKeyIcons: TStringList;
    FUseDepth: Integer;
    { The entity whose targets are being used (Quake 2's "other" in use
      functions: trigger_elevator reads its pathtarget); nil if unknown }
    FUseSource: TQuakeEntity;
    FHelpPrimary, FHelpSecondary: String;
    FPlayer: TQuakePlayerMovement;
    { Pickups spawned from the map; later ones are monsters' drops }
    FMapPickupCount: Integer;
    { Quake 2 game.serverflags: cross-level trigger bits, kept across maps of a unit }
    FServerFlags: Integer;
    { States of levels left through a changelevel in the current unit, by map name }
    FLevelStates: TJSONObject;
    FLastWaterLevel: Integer;
    FAirFinished: Single;
    FLiquidDamageTimer: Single;
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
    { Rebreather / environment suit breathing sounds (u_breath1 / 2) }
    FBreathTimer: Single;
    FBreathSound: Boolean;
    { target_earthquake shakes: entity -> end time; time of the next shove /
      sound per quake }
    FQuakes: array of record
      Entity: TQuakeEntity;
      EndTime, NextShove, NextSound: Single;
    end;
    FPlayerGravity, FBaseGravity: Single;
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
    procedure SetPlayer(const Value: TQuakePlayerMovement);
    procedure PlayerFallDamage(const Damage: Integer);
    procedure PlayerLanded(Sender: TObject);
    procedure ChooseSpawnPoint(const SpawnName: String);
    procedure SpawnEntities(const SpawnName: String);
    function ModelBox(const AModel: String; out Box: TBox3D): Boolean;
    procedure UpdateWeaponModel;
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
    procedure Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
      const FromPlayer: Boolean; const ExplosionSound: Boolean = True);
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
    procedure Update(const SecondsPassed: Single; const PlayerPos, PlayerDir: TVector3);
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
    property Gun: TQuakeGun read FGun;
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
    property PlayerGravity: Single read FPlayerGravity;

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
    procedure AttachWeaponToCamera(const Camera: TCastleTransform);
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

    property Hud: TQuakeHud read FHud write FHud;
    { Contents bits at a CGE position (liquids, exact ladders) }
    function PlayerPointContents(const CgePos: TVector3): Integer;
    function PlayerTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
    { Everything solid for Mask: map brushes, movers, live monster boxes and
      the player's box, skipping Ignore (Quake 2 SV_Trace) }
    function WorldTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
      const Ignore: TObject): TQuakeTrace;
    procedure PlayerBeforeMove(Sender: TObject);
    { Player movement (pmove), for falling damage and jump pads; may be nil }
    property Player: TQuakePlayerMovement read FPlayer write SetPlayer;
    property Stats: TQuakePlayerStats read FStats;
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
    property Dead: Boolean read FDead;
    property PlayerGibbed: Boolean read FPlayerGibbed;
    { The killer's position, when the death had one (LookAtKiller) }
    function KillerPosition(out Pos: TVector3): Boolean;
    { The "kill" console command: health 0 and player_die (no gibs, also in
      god mode) }
    procedure Suicide;
    property Monsters: TQuakeMonsterList read FMonsters;
    function ProjectileCount: Integer;
    function DelayedCount: Integer;
    property Pickups: TQuakePickupList read FPickups;
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
  FGun := TQuakeGun.Create;
  FGun.OnEvent := @GunEvent;
  FGun.OnAmmo := @GunAmmo;
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
  FreeAndNil(FGun);
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

procedure TQuakeWorld.ResetStats;
begin
  FillChar(FStats, SizeOf(FStats), 0);
  FStats.Health := 100;
  FStats.MaxHealth := 100;
  FStats.MaxAmmo[atShells] := 100;
  FStats.MaxAmmo[atBullets] := 200;
  FStats.MaxAmmo[atGrenades] := 50;
  FStats.MaxAmmo[atRockets] := 50;
  FStats.MaxAmmo[atCells] := 200;
  FStats.MaxAmmo[atSlugs] := 50;
  FStats.MaxAmmo[atMagSlugs] := 50;
  FStats.MaxAmmo[atTraps] := 5;
  { Ground Zero's InitClientPersistant }
  FStats.MaxAmmo[atFlechettes] := 200;
  FStats.MaxAmmo[atProx] := 50;
  FStats.MaxAmmo[atTesla] := 50;
  FStats.WeaponMask := 1 shl 1; { Blaster }
  FStats.CurrentWeapon := 1;
end;

procedure TQuakeWorld.ClearLevel;
begin
  if FMoverPoses <> nil then
    FMoverPoses.Clear;
  if PlayerTrail <> nil then
    PlayerTrail.Clear;
  FPickups.Clear;
  FSightEntities.Clear;
  FTurrets.Clear;
  FBrainEnts.Clear;
  FMonsters.Clear;
  FProjectiles.Clear;
  FTriggers.Clear;
  FSpeakers.Clear;
  FProps.Clear;
  FLasers.Clear;
  FTimers.Clear;
  FPeriodic.Clear;
  FRepairHealth.Clear;
  FSteam.Clear;
  PlayerDisguised := False;
  RemoveDefender(False);
  FDamageSource := nil;
  FDelayed.Clear;
  FCounters.Clear;
  FDynamicLights.Clear;
  Particles.Clear;
  { Map data is owned by the TQuakeMap component }
  FGeometry := nil;
  FBsp := nil;
end;

procedure TQuakeWorld.AttachWeaponToCamera(const Camera: TCastleTransform);
begin
  if FWeaponTransform.Parent <> nil then
    FWeaponTransform.Parent.Remove(FWeaponTransform);
  Camera.Add(FWeaponTransform);
  { Quake models face +X; the camera looks along -Z }
  FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
end;

procedure TQuakeWorld.SetGunAngles(const Angles: TVector3);
var
  Q: TQuaternion;
begin
  { Camera space: pitch around +X (negative = down), yaw around +Y, roll
    around -Z (the view axis); then the base turn of the model (+X to -Z) }
  Q := QuatFromAxisAngle(Vector3(1, 0, 0), -DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, -1), DegToRad(Angles.Z)) *
    QuatFromAxisAngle(Vector3(0, 1, 0), Pi / 2);
  FWeaponTransform.Rotation := Q.ToAxisAngle;
end;

procedure TQuakeWorld.UpdateWeaponModel;
begin
  if FWeaponModelSlot = FStats.CurrentWeapon then
    Exit;
  FWeaponModelSlot := FStats.CurrentWeapon;
  FreeAndNil(FWeaponModel);
  FWeaponModel := Md2Manager.CreateInstance(WeaponDefs[FStats.CurrentWeapon].ViewModel);
  if FWeaponModel <> nil then
  begin
    FWeaponModel.Scene.Collides := False;
    FWeaponModel.Scene.Pickable := False;
    FWeaponTransform.Add(FWeaponModel.Scene);
    FWeaponModel.ShowFrames(FGun.OldFrame, FGun.Frame, FGun.FrameLerp);
  end;
end;

function TQuakeWorld.ModelBox(const AModel: String; out Box: TBox3D): Boolean;
var
  Idx: Integer;
  Mdl: TBSPModel;
begin
  Result := False;
  Box := TBox3D.Empty;
  if (Length(AModel) < 2) or (AModel[1] <> '*') then
    Exit;
  Idx := StrToIntDef(Copy(AModel, 2, MaxInt), -1);
  if (Idx <= 0) or (Idx >= FBsp.ModelCount) then
    Exit;
  Mdl := FBsp.Models[Idx];
  Box := QuakeBoxToCge(Mdl.Mins, Mdl.Maxs);
  Result := True;
end;

procedure TQuakeWorld.ChooseSpawnPoint(const SpawnName: String);
const
  { Maps whose starts all have targetnames: loaded directly (no "$spawn"),
    start where the previous level leads, like Yamagi Quake II's
    SP_CreateUnnamedSpawn table (the original game takes the first start) }
  DirectStarts: array[0..7, 0..1] of String = (('mine1', 'mintro'), ('mine2', 'mine1'),
    ('mine3', 'mine2a'), ('mine4', 'mine3'), ('power2', 'power1'), ('waste1', 'power2'),
    ('waste2', 'waste1'), ('city2', 'city2NL'));
var
  Ent, Best: TQuakeEntity;
  Score, BestScore, I: Integer;
  Wanted: String;
begin
  Wanted := SpawnName;
  if Wanted = '' then
    for I := 0 to High(DirectStarts) do
      if SameText(ExtractFileName(ChangeFileExt(FBsp.MapName, '')), DirectStarts[I, 0]) then
        Wanted := DirectStarts[I, 1];
  { Best: the info_player_start named by the changelevel "$spawn" suffix,
    then an unnamed info_player_start, then any start, then deathmatch spots }
  Best := nil;
  BestScore := 0;
  for Ent in FBsp.Entities do
  begin
    if Ent.ClassName = 'info_player_start' then
    begin
      if (Wanted <> '') and SameText(Ent.TargetName, Wanted) then
        Score := 4
      else
      if Ent.TargetName = '' then
        Score := 3
      else
        Score := 2;
    end else
    if Ent.ClassName = 'info_player_deathmatch' then
      Score := 1
    else
      Score := 0;
    if Score > BestScore then
    begin
      Best := Ent;
      BestScore := Score;
    end;
  end;
  if Best <> nil then
  begin
    FSpawnPoint := QuakeToCge(Best.Origin) + Vector3(0, PlayerEyeHeight - 24, 0);
    FSpawnAngle := Best.Angle;
  end;
end;

procedure TQuakeWorld.SpawnEntity(const Ent: TQuakeEntity);
var
  CName: String;
  Pos: TVector3;
  ItemDef: PQuakeItemDef;
  MonsterDef: PQuakeMonsterDef;
  Monster: TQuakeMonster;
  Box: TBox3D;
  Trig: TQuakeTrigger;
  SpawnFlags: Integer;
  D: TDelayedTarget;
  Mover, M2: TQuakeMover;
  Turret: TQuakeTurret;
  Prop: TQuakeProp;
  T: TQuakeTrace;
begin
  CName := Ent.ClassName;
  { Ground Zero's SpawnItem in single player: the disruptor (without
    g_disruptor), the A-M bomb, the hunter and vengeance spheres and the
    doppelganger are deathmatch only; the nailgun and weapon_heatbeam aren't in its item list }
  if (CName = 'weapon_disintegrator') or (CName = 'ammo_disruptor') or (CName = 'ammo_nuke') or
     (CName = 'item_sphere_hunter') or (CName = 'item_sphere_vengeance') or (CName = 'item_doppleganger') or
     (CName = 'weapon_nailgun') or (CName = 'ammo_nails') or (CName = 'dm_tag_token') or
     (CName = 'weapon_heatbeam') then
    Exit;
  Pos := QuakeToCge(Ent.Origin);
  SpawnFlags := Ent.SpawnFlags;

  { Entities not on this skill (single player) }
  if (SpawnFlags and SkillSpawnFlag(GameSkill)) <> 0 then
    Exit;

  if (CName = 'info_player_start') or (CName = 'info_player_deathmatch') then
    Exit; { chosen by ChooseSpawnPoint }

  { Doors spawned from the console with mins / maxs (no *N model): a box
    mover, like the turrets below }
  if ((CName = 'func_door') or (CName = 'func_door_secret') or (CName = 'func_door_secret2')) and (Ent.Model = '') and
     Ent.HasField('mins') and Ent.HasField('maxs') and (FGeometry <> nil) then
  begin
    FGeometry.AddBoxMover(Ent, Ent.GetVector('mins', TVector3.Zero),
      Ent.GetVector('maxs', TVector3.Zero), FMap);
    Exit;
  end;

  if (CName = 'turret_breach') or (CName = 'turret_base') then
  begin
    { SP_turret_breach / SP_turret_base: the brush model, or a box for
      turrets spawned from the console with mins / maxs }
    Mover := nil;
    if FGeometry <> nil then
      for M2 in FGeometry.Movers do
        if M2.Entity = Ent then
          Mover := M2;
    if (Mover = nil) and (FGeometry <> nil) and Ent.HasField('mins') and Ent.HasField('maxs') then
      Mover := FGeometry.AddBoxMover(Ent, Ent.GetVector('mins', TVector3.Zero),
        Ent.GetVector('maxs', TVector3.Zero), FMap);
    if (Mover <> nil) and (CName = 'turret_breach') then
    begin
      Turret := TQuakeTurret.Create;
      Turret.Breach := Mover;
      Turret.Speed := Ent.GetFloat('speed', 0);
      if Turret.Speed = 0 then
        Turret.Speed := 50;
      Turret.Limits := TurretLimits(Ent.GetFloat('minpitch', 0), Ent.GetFloat('maxpitch', 0),
        Ent.GetFloat('minyaw', 0), Ent.GetFloat('maxyaw', 0));
      Turret.MoveYaw := Mover.TurretYaw;
      FTurrets.Add(Turret);
    end;
    Exit;
  end;

  if CName = 'turret_invisible_brain' then
  begin
    { SP_turret_invisible_brain: needs a target (the breach) and a
      killtarget (what it shoots at); linked in UpdateTurrets }
    if (Ent.Target = '') or (Ent.GetField('killtarget') = '') then
      WritelnLog('QuakeWorld', 'turret_invisible_brain without target / killtarget: removed')
    else
      FBrainEnts.Add(Ent);
    Exit;
  end;

  if CName = 'turret_driver' then
  begin
    { SP_turret_driver: an infantry with 100 health, linked to the breach
      its target names on the next update }
    Monster := TQuakeMonster.CreateMonster(FMap, FindMonsterDef('monster_infantry'), Ent, Pos, Ent.Angle);
    Monster.TurretDriver := True;
    Monster.Health := 100;
    Monster.Transform.Name := StringReplace(Monster.Transform.Name, 'monster_infantry', 'turret_driver', []);
    Monster.OnFoundTarget := @MonsterFoundTarget;
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    if Monster.Model <> nil then
      Monster.Model.PlayAnim('stand', True, 10);
    FMonsters.Add(Monster);
    Inc(FStats.TotalKills);
    Exit;
  end;

  { SP_light_mine1 / 2: the mine's lamp models (the light is in the lightmap) }
  if (CName = 'light_mine1') or (CName = 'light_mine2') then
  begin
    FProps.Add(TQuakeProp.CreateProp(FMap, TPropKind(Ord(pkMineLight1) + Ord(CName = 'light_mine2')), Ent));
    Exit;
  end;
  if CName = 'monster_commander_body' then
  begin
    Prop := TQuakeProp.CreateProp(FMap, pkCommanderBody, Ent);
    FProps.Add(Prop);
    { commander_body_drop: MOVETYPE_TOSS (2 up) onto what is below, box
      -32 -32 0 .. 32 32 48 }
    T := WorldTrace(Ent.Origin + Vector3(0, 0, 2), Ent.Origin - Vector3(0, 0, 1024),
      Vector3(-32, -32, 0), Vector3(32, 32, 48), MASK_MONSTERSOLID, Prop);
    if not T.StartSolid then
      Prop.Transform.Translation := QuakeToCge(T.EndPos);
    Exit;
  end;
  if CName = 'monster_boss3_stand' then
  begin
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBoss3Stand, Ent));
    Exit;
  end;

  if CName = 'misc_insane' then
  begin
    { SP_misc_insane: a good guy (AI_GOOD_GUY), not counted in the kills }
    Monster := TQuakeMonster.CreateMonster(FMap, @InsaneDef, Ent, Pos, Ent.Angle);
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    Monster.ResolveTargets;
    FMonsters.Add(Monster);
    Exit;
  end;

  ItemDef := FindItemDef(CName);
  if ItemDef <> nil then
  begin
    { Items rest on the floor; origin is 15 units above it }
    FPickups.Add(TQuakePickup.CreatePickup(FMap, ItemDef, Ent, Pos));
    Exit;
  end;

  MonsterDef := FindMonsterDef(CName);
  if MonsterDef <> nil then
  begin
    Monster := TQuakeMonster.CreateMonster(FMap, MonsterDef, Ent, Pos, Ent.Angle);
    Monster.OnAttack := @MonsterAttack;
    Monster.OnFoundTarget := @MonsterFoundTarget;
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    Monster.OnRevived := @MonsterRevived;
    Monster.ResolveTargets;
    FMonsters.Add(Monster);
    Inc(FStats.TotalKills);
    Exit;
  end;

  if (Copy(CName, 1, 8) = 'trigger_') and EntityBox(Ent, Box) then
  begin
    Trig := TQuakeTrigger.Create(Ent, Box);
    if CName = 'trigger_teleport' then
      { SP_trigger_teleport (remaster / Rogue): with a targetname it waits
        to be used, unless START_ON (8) }
      Trig.Enabled := (Ent.TargetName = '') or ((SpawnFlags and 8) <> 0)
    else
    if CName = 'trigger_disguise' then
      { SP_trigger_disguise: touchable only with START_ON (2) }
      Trig.Enabled := (SpawnFlags and 2) <> 0
    else
    if ((SpawnFlags and TRIGGER_TRIGGERED) <> 0) and (Ent.TargetName <> '') then
      Trig.Enabled := False;
    FTriggers.Add(Trig);
    Exit;
  end;

  if CName = 'misc_teleporter' then
  begin
    { Teleporter pad trigger, around its origin }
    Trig := TQuakeTrigger.Create(Ent, Box3D(Pos - Vector3(24, 24, 24), Pos + Vector3(24, 32, 24)));
    FTriggers.Add(Trig);
    { and the pad model }
    FProps.Add(TQuakeProp.CreateProp(FMap, pkTeleporter, Ent));
    Exit;
  end;

  if CName = 'target_speaker' then
  begin
    FSpeakers.Add(TQuakeSpeaker.CreateSpeaker(FMap, Ent));
    Exit;
  end;

  { Quake II Remastered: a light drawn at run time (a "shadow light"), not
    in the lightmaps; only with a radius. START_OFF = 1 }
  if CName = 'dynamic_light' then
  begin
    if Ent.GetFloat('shadowlightradius', 0) > 0 then
    begin
      FDynamicLights.Add(Ent);
      if not FCounters.ContainsKey(Ent) then
        FCounters.AddOrSetValue(Ent, Ord((Ent.SpawnFlags and 1) = 0));
    end;
    Exit;
  end;

  { Switchable lights (style 32+ assigned by the map compiler), START_OFF = 1 }
  if (Copy(CName, 1, 5) = 'light') and (Ent.TargetName <> '') and
     (Ent.GetInt('style', 0) >= 32) then
  begin
    if (SpawnFlags and 1) <> 0 then
      Lighting.SetStyle(Ent.GetInt('style', 0), 'a')
    else
      Lighting.SetStyle(Ent.GetInt('style', 0), 'm');
    Exit;
  end;

  if CName = 'misc_explobox' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkExplobox, Ent))
  else
  if CName = 'misc_banner' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBanner, Ent))
  else
  if CName = 'misc_deadsoldier' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkDeadSoldier, Ent))
  else
  if CName = 'misc_satellite_dish' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkSatelliteDish, Ent))
  else
  if CName = 'misc_strogg_ship' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkStroggShip, Ent))
  else
  if CName = 'misc_gib_head' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkGibHead, Ent))
  else
  if CName = 'misc_viper' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkViper, Ent))
  else
  if CName = 'misc_bigviper' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBigViper, Ent))
  else
  if CName = 'misc_viper_bomb' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkViperBomb, Ent))
  else
  if CName = 'misc_blackhole' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBlackHole, Ent))
  else
  if CName = 'misc_eastertank' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterTank, Ent))
  else
  if CName = 'misc_easterchick' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterChick, Ent))
  else
  if CName = 'misc_easterchick2' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterChick2, Ent))
  else
  if CName = 'rotating_light' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkRotatingLight, Ent))
  else
  if CName = 'misc_nuke_core' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkNukeCore, Ent))
  else
  if CName = 'target_blacklight' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBlacklight, Ent))
  else
  if CName = 'target_orb' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkOrb, Ent))
  else
  if CName = 'misc_transport' then
  begin
    { SP_misc_transport: needs a target; it starts along its path at once
      (TRAIN_START_ON), hidden, and the first use shows it }
    if Ent.Target = '' then
      WritelnLog('QuakeWorld', 'misc_transport without a target: removed')
    else
    begin
      Prop := TQuakeProp.CreateProp(FMap, pkTransport, Ent);
      FProps.Add(Prop);
      StartPropFlight(Prop);
    end;
  end else
  if CName = 'func_object_repair' then
    { SP_object_repair: welding sparks every "delay" (1) seconds }
    FPeriodic.AddOrSetValue(Ent, FTime + Ent.GetFloat('delay', 1))
  else
  if CName = 'misc_amb4' then
    { SP_misc_amb4: world/amb4.wav 1 s after spawning, then every 2 s }
    FPeriodic.AddOrSetValue(Ent, FTime + 1)
  else
  if CName = 'target_mal_laser' then
    FLasers.Add(TQuakeLaser.CreateLaser(FMap, Ent, EntityMoveDir(Ent)))
  else
  if CName = 'target_laser' then
    FLasers.Add(TQuakeLaser.CreateLaser(FMap, Ent, EntityMoveDir(Ent)))
  else
  if CName = 'func_timer' then
  begin
    { spawnflags 1 = START_ON }
    if (SpawnFlags and 1) <> 0 then
      FTimers.AddOrSetValue(Ent, FTime + 1 + Ent.GetFloat('delay', 0) + TimerInterval(Ent))
    else
      FTimers.AddOrSetValue(Ent, -1);
  end;

  if CName = 'target_crosslevel_target' then
  begin
    { Fires its targets after "delay" (default 1 s) if all its bits were set
      by target_crosslevel_trigger in other levels }
    if ((SpawnFlags and $FF) <> 0) and ((FServerFlags and SpawnFlags and $FF) = (SpawnFlags and $FF)) then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 1);
      D.Target := Ent.Target;
      D.Entity := nil;
      FDelayed.Add(D);
      WritelnLog('QuakeWorld', 'Cross-level target will fire "%s"', [Ent.Target]);
    end;
  end else
  if CName = 'func_clock' then
  begin
    { SP_func_clock: TIMER_UP 1 (default an hour), TIMER_DOWN 2, START_OFF 4,
      MULTI_USE 8 }
    SetLength(FClocks, Length(FClocks) + 1);
    FClocks[High(FClocks)].Entity := Ent;
    FClocks[High(FClocks)].Display := nil;
    ResetClock(High(FClocks));
    if (SpawnFlags and 4) <> 0 then
      FClocks[High(FClocks)].NextThink := -1
    else
      FClocks[High(FClocks)].NextThink := FTime + 1;
  end else
  if CName = 'target_secret' then
    Inc(FStats.TotalSecrets)
  else
  if CName = 'target_goal' then
    Inc(FStats.TotalGoals)
  else
  if CName = 'trigger_counter' then
    FCounters.AddOrSetValue(Ent, Ent.GetInt('count', 2))
  else
  if CName = 'trigger_always' then
    UseEntity(Ent);
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

procedure TQuakeWorld.ApplyLandmark;
const
  BoxMins: TVector3 = (X: -16; Y: -16; Z: -24);
  BoxMaxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Ent, Landmark: TQuakeEntity;
  Org: TVector3;
begin
  { TryLandmarkSpawn: the same place relative to this map's info_landmark
    of that name, unless something is in the way there }
  if FLandmarkName = '' then
    Exit;
  Landmark := nil;
  for Ent in FBsp.Entities do
    if (Ent.ClassName = 'info_landmark') and SameText(Ent.TargetName, FLandmarkName) then
    begin
      Landmark := Ent;
      Break;
    end;
  if Landmark <> nil then
  begin
    Org := LandmarkWorld(FLandmarkLocal, Landmark.Origin, Landmark.Angle);
    if WorldTrace(Org, Org, BoxMins, BoxMaxs, MASK_PLAYERSOLID, nil).StartSolid then
      WritelnLog('QuakeWorld', 'info_landmark "%s": the spot is blocked, using the spawn point', [FLandmarkName])
    else
    begin
      FSpawnPoint := QuakeToCge(Org) + Vector3(0, PlayerEyeHeight - 24, 0);
      FSpawnAngle := Landmark.Angle + FLandmarkViewYaw;
      WritelnLog('QuakeWorld', 'Arrived by info_landmark "%s" at %s', [FLandmarkName, Org.ToString]);
    end;
  end;
  FLandmarkName := '';
end;

procedure TQuakeWorld.PoiUse(const Ent: TQuakeEntity);
const
  POI_NEAREST = 1;
  POI_DUMMY = 2;
  POI_DISABLED = 8;
var
  Team: String;
  E, Best: TQuakeEntity;
  Count, BestStyle, Flags: Integer;
  BestDist, Dist: Single;
  Disabled: Integer;
begin
  { use_target_poi: it is enabled; a stage ("count") only moves forward }
  FCounters.AddOrSetValue(Ent, 0);
  Count := Ent.GetInt('count', 0);
  if Count > 0 then
  begin
    if FPoiStage > Count then
      Exit;
    FPoiStage := Count;
  end;
  Best := Ent;
  Team := Ent.GetField('team');
  if Team <> '' then
  begin
    { The team member to point at: enabled, no dummy, on this stage; the
      lowest style, then the nearest (NEAREST) or the last one }
    Best := nil;
    BestStyle := MaxInt;
    BestDist := MaxSingle;
    for E in FBsp.Entities do
    begin
      if (E.ClassName <> 'target_poi') or (E.GetField('team') <> Team) then
        Continue;
      Flags := E.SpawnFlags;
      if not FCounters.TryGetValue(E, Disabled) then
        Disabled := Ord((Flags and POI_DISABLED) <> 0);
      if (Disabled <> 0) or ((Flags and POI_DUMMY) <> 0) or
         ((E.GetInt('count', 0) > 0) and (E.GetInt('count', 0) < FPoiStage)) then
        Continue;
      Dist := PointsDistance(E.Origin, CgeToQuake(FPlayerPos));
      if (E.GetInt('style', 0) < BestStyle) or
         ((E.GetInt('style', 0) = BestStyle) and (((Flags and POI_NEAREST) = 0) or (Dist < BestDist))) then
      begin
        Best := E;
        BestStyle := E.GetInt('style', 0);
        BestDist := Dist;
      end;
    end;
  end;
  if Best = nil then
    Exit;
  FPoiValid := True;
  FPoiPosition := Best.Origin;
  WritelnLog('QuakeWorld', 'Point of interest at %s', [FPoiPosition.ToString]);
end;

procedure TQuakeWorld.SpawnEntities(const SpawnName: String);
var
  Ent: TQuakeEntity;
  Monster: TQuakeMonster;
  AmbushCount, DormantCount: Integer;
begin
  ChooseSpawnPoint(SpawnName);
  FPoiValid := False;
  FPoiStage := 0;
  for Ent in FBsp.Entities do
    SpawnEntity(Ent);
  BuildHintPaths;
  ApplyLandmark;
  { Pickups after these are drops (DropMonsterItem), saved by class }
  FMapPickupCount := FPickups.Count;

  WritelnLog('QuakeWorld', 'Spawned %d pickups, %d monsters, %d triggers, %d movers, %d speakers, %d props, %d lasers, %d timers',
    [FPickups.Count, FMonsters.Count, FTriggers.Count, FGeometry.Movers.Count, FSpeakers.Count,
     FProps.Count, FLasers.Count, FTimers.Count]);
  AmbushCount := 0;
  DormantCount := 0;
  for Monster in FMonsters do
  begin
    if Monster.Ambush then
      Inc(AmbushCount);
    if Monster.Dormant then
      Inc(DormantCount);
  end;
  WritelnLog('QuakeWorld', '%d ambush monsters, %d waiting for a trigger to spawn',
    [AmbushCount, DormantCount]);
end;

function TQuakeWorld.LoadMap(const AMapName: String): Boolean;
var
  RestoreRemembered: Boolean;
  MapName, SpawnName, MapPath: String;
  P: Integer;
  World: TQuakeEntity;
begin
  Result := False;
  MapName := LowerCase(Trim(AMapName));
  { "base2$spawnpoint", "*base1" (new unit) }
  SpawnName := '';
  P := Pos('$', MapName);
  if P > 0 then
  begin
    SpawnName := Copy(MapName, P + 1, MaxInt);
    MapName := Copy(MapName, 1, P - 1);
  end;
  while (MapName <> '') and (MapName[1] = '*') do
    Delete(MapName, 1, 1);
  if Pos('maps/', MapName) = 1 then
    MapPath := MapName
  else
    MapPath := 'maps/' + MapName;
  if ExtractFileExt(MapPath) = '' then
    MapPath := MapPath + '.bsp';

  { Generated / editor levels are made on demand (MissingMapHook) }
  if (not Pak.FileExists(MapPath)) and Assigned(MissingMapHook) then
    MissingMapHook(MapPath);
  if not Pak.FileExists(MapPath) then
  begin
    WritelnWarning('QuakeWorld', 'Map "%s" not found', [MapPath]);
    Exit;
  end;

  { Quake 2 units: leaving a level through a changelevel remembers its state
    for when the player comes back; a "*map" starts a new unit (forget all) }
  if Pos('*', AMapName) = 1 then
    FLevelStates.Clear
  else
  if FLevelExited and (FBsp <> nil) then
  begin
    if FLevelStates.IndexOfName(FBsp.MapName) >= 0 then
      FLevelStates.Delete(FBsp.MapName);
    FLevelStates.Add(FBsp.MapName, SaveState);
  end;
  RestoreRemembered := FLevelExited;

  ClearLevel;
  { A new TQuakeBsp may reuse the old one's address: never keep the
    collision of the previous map }
  FreeAndNil(FCollision);
  FPlayerGibbed := False;
  FHasKiller := False;
  if FWeaponTransform <> nil then
    FWeaponTransform.Exists := True;
  FClocks := nil;
  FLastString := '';
  FQuakes := nil;
  { PutClientInServer: every level starts with normal gravity }
  SetPlayerGravity(1);
  FLevelExited := False;
  FNextMap := '';
  FTeleportPending := False;
  FDead := False;
  FRestartPending := False;
  FStats.LevelTime := 0;
  FStats.Kills := 0;
  FStats.TotalKills := 0;
  FStats.Secrets := 0;
  FStats.TotalSecrets := 0;
  FStats.Goals := 0;
  FStats.TotalGoals := 0;
  FSpawnPoint := Vector3(0, PlayerEyeHeight, 0);
  FSpawnAngle := 0;

  { The map component (TQuakeMap, placed in the view design) builds the
    geometry; the world adds the gameplay on top of it. }
  { Reuse the map the design already loaded (only the first time: restarts
    and level changes must rebuild movers in their initial state) }
  if FMapReused or (FMap.Bsp = nil) or not SameText(FMap.MapName, MapName) then
    if not FMap.LoadMap(MapName) then
      Exit;
  FMapReused := True;
  FBsp := FMap.Bsp;
  FGeometry := FMap.Geometry;
  FGeometry.OnFireTargets := @UseTargets;

  SpawnEntities(SpawnName);
  if RestoreRemembered and (FLevelStates.IndexOfName(FBsp.MapName) >= 0) then
  begin
    LoadState(FLevelStates.Objects[FBsp.MapName], False);
    WritelnLog('QuakeWorld', 'Restored remembered state of "%s"', [FBsp.MapName]);
  end;
  { Raise the weapon (Quake 2 starts levels with the activate frames) }
  FGun.Reset(FStats.CurrentWeapon);
  UpdateWeaponModel;

  World := FBsp.FindEntity('worldspawn');
  Sounds.StopMusic;
  FHelpPrimary := '';
  FHelpSecondary := '';
  if FHud <> nil then
  begin
    FHud.HelpPrimary := '';
    FHud.HelpSecondary := '';
    FHud.Intermission := False;
    if World <> nil then
      FHud.LevelName := World.MessageText
    else
      FHud.LevelName := FBsp.MapName;
  end;
  if World <> nil then
  begin
    Sounds.PlayMusic(Sounds.TrackFileName(World.Sounds));
    if (FHud <> nil) and (World.MessageText <> '') then
      FHud.ShowMessage(World.MessageText, 4);
  end;

  WritelnLog('QuakeWorld', 'Initialized map "%s"', [MapPath]);
  Result := True;
end;

function TQuakeWorld.PlayerBox: TBox3D;
var
  Feet: Single;
begin
  Feet := FPlayerPos.Y - PlayerEyeHeight;
  Result := Box3D(
    Vector3(FPlayerPos.X - 16, Feet, FPlayerPos.Z - 16),
    Vector3(FPlayerPos.X + 16, Feet + 56, FPlayerPos.Z + 16));
end;

function TQuakeWorld.GiveItem(const Def: PQuakeItemDef): Boolean;
var
  OldType, Salvage: Integer;
  A: TAmmoType;

  function AddAmmo(const AType: TAmmoType; const Count: Integer): Boolean;
  begin
    Result := FStats.Ammo[AType] < FStats.MaxAmmo[AType];
    FStats.Ammo[AType] := Min(FStats.MaxAmmo[AType], FStats.Ammo[AType] + Count);
  end;

begin
  Result := True;
  case Def^.Category of
    icWeapon:
      begin
        FStats.WeaponMask := FStats.WeaponMask or (1 shl Def^.Weapon);
        AddAmmo(Def^.AmmoType, Def^.Amount);
        { Quake 2 auto-switches away from the blaster }
        if FStats.CurrentWeapon = 1 then
          SelectWeapon(Def^.Weapon);
      end;
    icAmmo:
      begin
        Result := AddAmmo(Def^.AmmoType, Def^.Amount);
        { Grenades are both ammo and the hand grenade weapon }
        if Result and (Def^.Weapon <> 0) then
          FStats.WeaponMask := FStats.WeaponMask or (1 shl Def^.Weapon);
      end;
    icHealth:
      begin
        if (Def^.Param = 0) and (FStats.Health >= FStats.MaxHealth) then
          Exit(False);
        if Def^.Param = 0 then
          FStats.Health := Min(FStats.MaxHealth, FStats.Health + Def^.Amount)
        else
          FStats.Health := Min(250, FStats.Health + Def^.Amount);
      end;
    icArmor:
      begin
        if Def^.Param = 0 then
        begin
          { Shard: +2 of the current type }
          if FStats.ArmorType = 0 then
            FStats.ArmorType := 1;
          FStats.Armor := FStats.Armor + Def^.Amount;
        end else
        begin
          OldType := FStats.ArmorType;
          if OldType = 0 then
          begin
            FStats.ArmorType := Def^.Param;
            FStats.Armor := Def^.Amount;
          end else
          if ArmorProtection[Def^.Param] > ArmorProtection[OldType] then
          begin
            { Upgrade: salvage the old armor at the new protection rate }
            Salvage := Round(FStats.Armor * ArmorProtection[OldType] / ArmorProtection[Def^.Param]);
            FStats.ArmorType := Def^.Param;
            FStats.Armor := Min(ArmorMax[Def^.Param], Def^.Amount + Salvage);
          end else
          begin
            Salvage := Round(Def^.Amount * ArmorProtection[Def^.Param] / ArmorProtection[OldType]);
            if FStats.Armor >= ArmorMax[OldType] then
              Exit(False);
            FStats.Armor := Min(ArmorMax[OldType], FStats.Armor + Salvage);
          end;
        end;
      end;
    icPowerup:
      case Def^.Param of
        POWERUP_QUAD: FStats.QuadTime := FStats.QuadTime + Def^.Amount;
        { Use_QuadFire: 30 s more of DualFire }
        POWERUP_QUADFIRE:
          begin
            FStats.QuadFireTime := FStats.QuadFireTime + Def^.Amount;
            Sounds.Play('sound/items/quadfire1.wav', 1, chItem);
          end;
        POWERUP_INVULN: FStats.InvulnTime := FStats.InvulnTime + Def^.Amount;
        { Ground Zero, used on pickup: Use_Double (30 s), Use_IR (60 s),
          Use_Defender (one sphere at a time: Pickup_Sphere refuses) }
        POWERUP_DOUBLE:
          begin
            FStats.DoubleTime := FStats.DoubleTime + Def^.Amount;
            Sounds.Play('sound/misc/ddamage1.wav', 1, chItem);
          end;
        POWERUP_IR:
          begin
            FStats.IRTime := FStats.IRTime + Def^.Amount;
            Sounds.Play('sound/misc/ir_start.wav', 1, chItem);
          end;
        POWERUP_DEFENDER:
          begin
            if FStats.DefenderTime > 0 then
              Exit(False);
            FStats.DefenderTime := Def^.Amount;
            FDefenderEnemy := nil;
            WritelnLog('QuakeWorld', 'Defender sphere out');
          end;
        { Used on pickup here (Quake 2 single player keeps them in the
          inventory until used): Use_Breather, Use_Envirosuit, Use_Silencer }
        POWERUP_OTHER:
          if Def^.ClassName = 'item_breather' then
            FStats.BreatherTime := FStats.BreatherTime + 30
          else
          if Def^.ClassName = 'item_enviro' then
            FStats.EnviroTime := FStats.EnviroTime + 30
          else
          if Def^.ClassName = 'item_silencer' then
            Inc(FStats.SilencerShots, 30)
          else
          if (Def^.ClassName = 'item_power_screen') or (Def^.ClassName = 'item_power_shield') then
          begin
            if Def^.ClassName = 'item_power_screen' then
              Inc(FStats.PowerScreens)
            else
              Inc(FStats.PowerShields);
            { Switched on with the first one, like Quake 2 deathmatch's
              auto-use; the powerarmor command switches it }
            if not FStats.PowerArmorOn then
              TogglePowerArmor;
          end;
        POWERUP_ADRENALINE:
          begin
            Inc(FStats.MaxHealth);
            FStats.Health := Max(FStats.Health, FStats.MaxHealth);
          end;
        POWERUP_ANCIENT_HEAD:
          Inc(FStats.MaxHealth, 2);
        POWERUP_BANDOLIER, POWERUP_PACK:
          begin
            if Def^.Param = POWERUP_PACK then
            begin
              FStats.MaxAmmo[atShells] := Max(FStats.MaxAmmo[atShells], 200);
              FStats.MaxAmmo[atBullets] := Max(FStats.MaxAmmo[atBullets], 300);
              FStats.MaxAmmo[atGrenades] := Max(FStats.MaxAmmo[atGrenades], 100);
              FStats.MaxAmmo[atRockets] := Max(FStats.MaxAmmo[atRockets], 100);
              FStats.MaxAmmo[atCells] := Max(FStats.MaxAmmo[atCells], 300);
              FStats.MaxAmmo[atSlugs] := Max(FStats.MaxAmmo[atSlugs], 100);
              FStats.MaxAmmo[atMagSlugs] := Max(FStats.MaxAmmo[atMagSlugs], 100);
              FStats.MaxAmmo[atFlechettes] := Max(FStats.MaxAmmo[atFlechettes], 300);
              AddAmmo(atMagSlugs, 10);
              AddAmmo(atFlechettes, 50);
            end else
            begin
              FStats.MaxAmmo[atShells] := Max(FStats.MaxAmmo[atShells], 150);
              FStats.MaxAmmo[atBullets] := Max(FStats.MaxAmmo[atBullets], 250);
              FStats.MaxAmmo[atCells] := Max(FStats.MaxAmmo[atCells], 250);
              FStats.MaxAmmo[atSlugs] := Max(FStats.MaxAmmo[atSlugs], 75);
              FStats.MaxAmmo[atMagSlugs] := Max(FStats.MaxAmmo[atMagSlugs], 75);
              FStats.MaxAmmo[atFlechettes] := Max(FStats.MaxAmmo[atFlechettes], 250);
            end;
            for A := atShells to atSlugs do
              AddAmmo(A, 10);
          end;
      end;
    icKey:
      FStats.Keys := FStats.Keys or Cardinal(Def^.Amount);
  end;
end;

procedure TQuakeWorld.CheckPickups;
var
  P: TQuakePickup;
  Delta: TVector3;
  Amount: Integer;
begin
  for P in FPickups do
  begin
    if P.Collected then
      Continue;
    Delta := P.Origin - FPlayerPos;
    if (Sqr(Delta.X) + Sqr(Delta.Z) < Sqr(40)) and (Delta.Y > -PlayerEyeHeight - 20) and (Delta.Y < 20) then
    begin
      if P.Def^.ClassName = 'item_foodcube' then
      begin
        { A trap's food cube: its count in health, over the maximum
          (HEALTH_IGNORE_MAX), the sound by the amount }
        Amount := Max(1, P.Entity.GetInt('count', 2));
        FStats.Health := FStats.Health + Amount;
        P.Collected := True;
        if Amount < 10 then
          Sounds.Play('sound/items/s_health.wav', 1, chItem)
        else
        if Amount < 25 then
          Sounds.Play('sound/items/n_health.wav', 1, chItem)
        else
        if Amount < 50 then
          Sounds.Play('sound/items/l_health.wav', 1, chItem)
        else
          Sounds.Play('sound/items/m_health.wav', 1, chItem);
        if FHud <> nil then
          FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
        WritelnLog('QuakeWorld', 'Food cube: %d health', [Amount]);
        Continue;
      end;
      if not GiveItem(P.Def) then
        Continue;
      P.Collected := True;
      Sounds.Play(P.Def^.Sound, 1, chItem);
      if FHud <> nil then
        FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
      { Picked items can fire targets too }
      UseTargets(P.Entity.Target, P.Entity);
    end;
  end;
end;

procedure TQuakeWorld.UseTargetsOf(const Ent: TQuakeEntity);
var
  D: TDelayedTarget;
begin
  { G_UseTargets: an entity's "delay" postpones the use of its targets }
  if Ent.GetFloat('delay', 0) > 0 then
  begin
    D.Time := FTime + Ent.GetFloat('delay', 0);
    D.Target := Ent.Target;
    D.Entity := nil;
    FDelayed.Add(D);
  end else
    UseTargets(Ent.Target, Ent);
end;

procedure TQuakeWorld.UseEntity(const Ent: TQuakeEntity);
var
  CName, Msg, MapName: String;
  Mover, M2: TQuakeMover;
  Count: Integer;
  ItemDef: PQuakeItemDef;
  M: TQuakeMonster;
  Trig: TQuakeTrigger;
  D: TDelayedTarget;
  Speaker: TQuakeSpeaker;
  Laser: TQuakeLaser;
  Prop: TQuakeProp;
  Lights: TQuakeEntityList;
  Light: TQuakeEntity;
  NewEnt: TQuakeEntity;
  Box: TBox3D;
  I: Integer;
  Turret: TQuakeTurret;
begin
  CName := Ent.ClassName;
  Msg := Ent.MessageText;

  if CName = 'func_areaportal' then
  begin
    FGeometry.ToggleAreaPortal(Ent);
    Exit;
  end;

  { trigger_key: needs an item; used once (Quake 2 clears its use), which
    is kept in FCounters as -1 so savegames keep it }
  if CName = 'trigger_key' then
  begin
    if FCounters.TryGetValue(Ent, Count) and (Count < 0) then
      Exit;
    ItemDef := FindItemDef(LowerCase(Ent.GetField('item')));
    if (ItemDef <> nil) and ((FStats.Keys and Cardinal(ItemDef^.Amount)) = 0) then
    begin
      if FHud <> nil then
        FHud.ShowMessage('You need the ' + ItemDef^.Name);
      WritelnLog('QuakeWorld', 'trigger_key "%s": you need the %s', [Ent.TargetName, ItemDef^.Name]);
      Sounds.Play('sound/misc/keytry.wav');
      Exit;
    end;
    Sounds.Play('sound/misc/keyuse.wav');
    if ItemDef <> nil then
      FStats.Keys := FStats.Keys and not Cardinal(ItemDef^.Amount);
    FCounters.AddOrSetValue(Ent, -1);
    WritelnLog('QuakeWorld', 'trigger_key "%s" unlocks "%s"', [Ent.TargetName, Ent.Target]);
    UseTargets(Ent.Target, Ent);
    Exit;
  end;

  if CName = 'trigger_counter' then
  begin
    if not FCounters.TryGetValue(Ent, Count) then
      Exit;
    Dec(Count);
    FCounters[Ent] := Count;
    if Count > 0 then
    begin
      if ((Ent.SpawnFlags and 1) = 0) and (FHud <> nil) then
        FHud.ShowMessage(Format('%d more to go...', [Count]));
      Exit;
    end;
    if ((Ent.SpawnFlags and 1) = 0) and (FHud <> nil) then
      FHud.ShowMessage('Sequence completed!');
    UseTargets(Ent.Target, Ent);
    Exit;
  end;

  { (target_string's message is its text, not a centerprint) }
  if (Msg <> '') and (FHud <> nil) and (Copy(CName, 1, 7) = 'target_') and (CName <> 'target_string') then
    FHud.ShowMessage(Msg, 4);

  if CName = 'target_changelevel' then
  begin
    MapName := Ent.GetField('map');
    { Ignore cinematics / end screens (e.g. "victory.pcx", "*.cin") }
    if (MapName <> '') and (Pos('.', MapName) = 0) then
    begin
      FLevelExited := True;
      FNextMap := MapName;
      { The remaster: a target naming an info_landmark carries the player's
        place and view relative to it into the next map }
      FLandmarkName := '';
      Light := PickTarget(Ent.Target);
      if (Light <> nil) and (Light.ClassName = 'info_landmark') and (FPlayer <> nil) then
      begin
        FLandmarkName := Light.TargetName;
        FLandmarkLocal := LandmarkLocal(FPlayer.Origin, Light.Origin, Light.Angle);
        FLandmarkViewYaw := RadToDeg(ArcTan2(-FPlayerDir.Z, FPlayerDir.X)) - Light.Angle;
        WritelnLog('QuakeWorld', 'Leaving by info_landmark "%s" at %s from it', [FLandmarkName, FLandmarkLocal.ToString]);
      end;
    end;
  end else
  if CName = 'target_poi' then
    PoiUse(Ent)
  else
  if CName = 'target_crosslevel_trigger' then
  begin
    FServerFlags := FServerFlags or (Ent.SpawnFlags and $FF);
    WritelnLog('QuakeWorld', 'Cross-level flags now %d', [FServerFlags]);
  end else
  if CName = 'target_secret' then
  begin
    Inc(FStats.Secrets);
    Sounds.Play('sound/misc/secret.wav');
  end else
  if CName = 'target_goal' then
  begin
    Inc(FStats.Goals);
    Sounds.Play('sound/misc/secret.wav');
  end else
  if CName = 'target_speaker' then
  begin
    for Speaker in FSpeakers do
      if Speaker.Entity = Ent then
        Speaker.Activate;
  end else
  if (Copy(CName, 1, 5) = 'light') and (Ent.GetInt('style', 0) >= 32) then
  begin
    { Toggle a switchable light }
    if Lighting.GetStyle(Ent.GetInt('style', 0)) = 'a' then
      Lighting.SetStyle(Ent.GetInt('style', 0), 'm')
    else
      Lighting.SetStyle(Ent.GetInt('style', 0), 'a');
  end else
  if CName = 'target_lightramp' then
  begin
    { Ramp the targeted light's style between the two message letters over
      "speed" seconds; each use reverses the direction (Quake 2 TOGGLE) }
    Msg := LowerCase(Ent.GetField('message', 'az'));
    if Length(Msg) = 2 then
    begin
      Lights := FBsp.FindByTargetName(Ent.Target);
      try
        for Light in Lights do
          if Light.GetInt('style', 0) >= 32 then
          begin
            if Lighting.GetStyle(Light.GetInt('style', 0)) = Msg[2] then
              Lighting.RampStyle(Light.GetInt('style', 0), Msg[2], Msg[1], Ent.GetFloat('speed', 1))
            else
              Lighting.RampStyle(Light.GetInt('style', 0), Msg[1], Msg[2], Ent.GetFloat('speed', 1));
          end;
      finally
        Lights.Free;
      end;
    end;
    Exit;
  end else
  if CName = 'func_timer' then
  begin
    { Using a timer toggles it }
    if FTimers.ContainsKey(Ent) then
    begin
      if FTimers[Ent] < 0 then
        FTimers[Ent] := FTime + Ent.GetFloat('delay', 0) + TimerInterval(Ent)
      else
        FTimers[Ent] := -1;
    end;
    Exit;
  end else
  if CName = 'target_splash' then
  begin
    Particles.SpawnSplash(QuakeToCge(Ent.Origin), EntityMoveDir(Ent), Ent.Sounds,
      Ent.GetInt('count', 32));
    if Ent.Sounds = 1 then
      Sounds.PlayAtPoint('sound/world/spark' + IntToStr(5 + Random(3)) + '.wav', QuakeToCge(Ent.Origin));
  end else
  if CName = 'target_laser' then
  begin
    for Laser in FLasers do
      if Laser.Entity = Ent then
        Laser.IsOn := not Laser.IsOn;
  end else
  if CName = 'target_mal_laser' then
  begin
    for Laser in FLasers do
      if Laser.Entity = Ent then
        Laser.IsOn := not Laser.IsOn;
  end else
  if CName = 'misc_viper_missile' then
    ViperMissileUse(Ent)
  else
  if CName = 'misc_nuke' then
    NukeUse(Ent)
  else
  if CName = 'target_steam' then
    SteamUse(Ent, FUseSource)
  else
  if CName = 'target_anger' then
    AngerUse(Ent)
  else
  if CName = 'target_killplayers' then
    KillPlayersUse(Ent)
  else
  if (Copy(CName, 1, 5) = 'misc_') or (CName = 'monster_commander_body') or (CName = 'monster_boss3_stand') or
     (CName = 'rotating_light') then
  begin
    for Prop in FProps do
      if Prop.Entity = Ent then
        ActivateProp(Prop);
  end else
  if CName = 'target_temp_entity' then
    { Use_Target_Tent: the temp entity "style" at its origin }
    TempEntity(Ent.GetInt('style', 0), QuakeToCge(Ent.Origin))
  else
  if CName = 'turret_invisible_brain' then
  begin
    { turret_brain_activate: the first use starts it, the first shot "wait"
      (3) seconds later; the next use stops it for good }
    for Turret in FTurrets do
      if Turret.Brain = Ent then
      begin
        if Turret.BrainStopped then
          Break;
        if not Turret.BrainOn then
        begin
          Turret.BrainOn := True;
          Turret.AttackFinished := FTime + Ent.GetFloat('wait', 3);
          WritelnLog('QuakeWorld', 'turret_invisible_brain "%s" starts', [Ent.TargetName]);
        end else
        begin
          Turret.BrainOn := False;
          Turret.BrainStopped := True;
          WritelnLog('QuakeWorld', 'turret_invisible_brain "%s" stops', [Ent.TargetName]);
        end;
        Break;
      end;
  end else
  if CName = 'target_explosion' then
  begin
    { use_target_explosion: its own "delay" postpones the blast }
    if Ent.GetFloat('delay', 0) > 0 then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 0);
      D.Target := '';
      D.Entity := Ent;
      FDelayed.Add(D);
    end else
      Explode(QuakeToCge(Ent.Origin), Ent.GetInt('dmg', 0), 120, False);
  end else
  if CName = 'target_help' then
  begin
    { spawnflags 1 = primary objective, else secondary }
    if (Ent.SpawnFlags and 1) <> 0 then
      FHelpPrimary := Msg
    else
      FHelpSecondary := Msg;
    Sounds.Play('sound/misc/pc_up.wav');
    if FHud <> nil then
    begin
      FHud.HelpPrimary := FHelpPrimary;
      FHud.HelpSecondary := FHelpSecondary;
      FHud.ShowMessage('Help computer updated (F1)', 3);
    end;
  end else
  if CName = 'target_earthquake' then
  begin
    { target_earthquake_use: shake for "count" seconds (default 5) }
    SetLength(FQuakes, Length(FQuakes) + 1);
    FQuakes[High(FQuakes)].Entity := Ent;
    FQuakes[High(FQuakes)].EndTime := FTime + Ent.GetFloat('count', 5);
    FQuakes[High(FQuakes)].NextShove := FTime;
    FQuakes[High(FQuakes)].NextSound := FTime;
  end else
  if CName = 'target_string' then
    TargetStringUse(Ent)
  else
  if CName = 'func_clock' then
  begin
    { func_clock_use: start once (again only with MULTI_USE after a reset) }
    for I := 0 to High(FClocks) do
      if (FClocks[I].Entity = Ent) and not FClocks[I].Activated then
      begin
        FClocks[I].Activated := True;
        ClockThink(I);
      end;
  end else
  if CName = 'target_blaster' then
  begin
    { use_target_blaster: a blaster bolt along movedir ("dmg" 15, "speed" 1000) }
    SpawnProjectile(pkBlasterBolt, QuakeToCge(Ent.Origin), EntityMoveDir(Ent), Ent.Speed(1000),
      Ent.GetInt('dmg', 15), False);
    Sounds.PlayAtPoint('sound/weapons/laser2.wav', QuakeToCge(Ent.Origin));
  end else
  if CName = 'func_killbox' then
  begin
    if EntityBox(Ent, Box) then
      KillBox(Box);
  end else
  if CName = 'target_spawner' then
  begin
    { use_target_spawner: a new entity of class "target" here, facing the
      same way (G_Spawn + ED_CallSpawn); "speed" throws it along movedir,
      which only matters for items in Quake 2 and is ignored here }
    NewEnt := TQuakeEntity.Create;
    NewEnt.SetField('classname', Ent.Target);
    NewEnt.SetField('origin', Ent.GetField('origin'));
    NewEnt.SetField('angle', Ent.GetField('angle', '0'));
    FBsp.Entities.Add(NewEnt);
    SpawnEntity(NewEnt);
    { Like KillBox at the spawn point: telefrag what is in the way }
    KillBox(Box3D(QuakeToCge(NewEnt.Origin) - Vector3(16, 24, 16), QuakeToCge(NewEnt.Origin) + Vector3(16, 32, 16)));
    WritelnLog('QuakeWorld', 'target_spawner made a %s', [Ent.Target]);
  end else
  if CName = 'trigger_elevator' then
    ElevatorUse(Ent, FUseSource)
  else
  if CName = 'dynamic_light' then
  begin
    { dynamic_light_use: on / off }
    if FCounters.TryGetValue(Ent, Count) then
    begin
      FCounters[Ent] := 1 - Count;
      if Count = 0 then
        WritelnLog('QuakeWorld', 'dynamic_light "%s" on', [Ent.TargetName])
      else
        WritelnLog('QuakeWorld', 'dynamic_light "%s" off', [Ent.TargetName]);
    end;
  end else
  if CName = 'trigger_relay' then
    UseTargetsOf(Ent)
  else
  if Copy(CName, 1, 8) = 'monster_' then
  begin
    for M in FMonsters do
      if M.Entity = Ent then
      begin
        if M.TurretWallWaiting then
          M.ActivateWallTurret
        else
        if M.Dormant then
          M.Spawn { TRIGGER_SPAWN }
        else
          M.Alert;
      end;
  end else
  if (CName = 'trigger_teleport') or (CName = 'trigger_disguise') then
  begin
    { trigger_teleport_use / trigger_disguise_use: on / off each time }
    for Trig in FTriggers do
      if Trig.Entity = Ent then
        Trig.Enabled := not Trig.Enabled;
  end else
  if Copy(CName, 1, 8) = 'trigger_' then
  begin
    { Using a TRIGGERED trigger enables it }
    for Trig in FTriggers do
      if Trig.Entity = Ent then
        Trig.Enabled := True;
  end else
  begin
    Mover := FGeometry.FindMoverByModel(Ent.Model);
    { Box movers spawned from the console have no *N model }
    if (Mover = nil) and (Ent.Model = '') then
      for M2 in FGeometry.Movers do
        if M2.Entity = Ent then
          Mover := M2;
    if Mover <> nil then
    begin
      if Mover.Kind = mkStatic then
      begin
        if CName = 'func_explosive' then
          BreakExplosive(Mover)
        else
        if CName = 'func_object' then
        begin
          { func_object_use: appears (KillBox) and falls }
          if not Mover.Transform.Exists then
          begin
            Mover.Transform.Exists := True;
            KillBox(Mover.WorldBox);
            Mover.Tossing := True;
          end;
        end else
        if CName = 'func_wall' then
        begin
          { func_wall_use: a plain wall has no use; it appears (killing
            what is in the way, KillBox) and, with TOGGLE, also goes away }
          if (Ent.SpawnFlags and 7) <> 0 then
          begin
            if not Mover.Transform.Exists then
            begin
              Mover.Transform.Exists := True;
              KillBox(Mover.WorldBox);
            end else
            if (Ent.SpawnFlags and 2) <> 0 then
              Mover.Transform.Exists := False;
          end;
        end else
          Mover.Transform.Exists := not Mover.Transform.Exists;
      end else
        Mover.Use;
    end;
  end;

  { Only "target_*" entities pass the activation further here; movers fire
    their own targets when they finish (buttons) }
  if (Copy(CName, 1, 7) = 'target_') and (Ent.Target <> '') then
  begin
    if Ent.GetFloat('delay', 0) > 0 then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 0);
      D.Target := Ent.Target;
      D.Entity := nil;
      FDelayed.Add(D);
    end else
      UseTargets(Ent.Target, Ent);
  end;
end;

procedure TQuakeWorld.BreakExplosive(const Mover: TQuakeMover);
var
  Dmg: Integer;
begin
  { Quake 2 func_explosive_explode: debris always, an explosion (and
    radius damage) only with "dmg"; glass (our "_glass" key, the level
    compiler's windows) shatters }
  Dmg := Mover.Entity.GetInt('dmg', 0);
  if Dmg > 0 then
    Explode(Mover.Center, Dmg, 120, False);
  Particles.SpawnDebris(Mover.Center);
  if Mover.Entity.GetField('_glass') = '1' then
    Sounds.PlayAtPoint('sound/world/brkglas.wav', Mover.Center);
  Mover.Transform.Exists := False;
  WritelnLog('QuakeWorld', 'func_explosive %s breaks', [Mover.Entity.Model]);
end;

procedure TQuakeWorld.DamageMover(const Mover: TQuakeMover; const Damage: Integer);
begin
  if (Mover.Health <= 0) or not Mover.Transform.Exists then
    Exit;
  Mover.Health := Mover.Health - Damage;
  if Mover.Health > 0 then
    Exit;
  if Mover.Entity.ClassName = 'func_explosive' then
  begin
    BreakExplosive(Mover);
    UseTargets(Mover.Target, Mover.Entity);
  end else
  begin
    { Shot-activated doors and buttons reset their health, like Quake 2 }
    Mover.Health := Mover.Entity.GetInt('health', 0);
    Mover.Use;
    if Mover.Kind <> mkButton then
      UseTargets(Mover.Target, Mover.Entity);
  end;
end;

function TQuakeWorld.TimerInterval(const Ent: TQuakeEntity): Single;
begin
  { Quake 2 func_timer: wait + crandom() * random }
  Result := Max(0.1, Ent.GetFloat('wait', 1) + (Random * 2 - 1) * Ent.GetFloat('random', 0));
end;

function TQuakeWorld.EntityMoveDir(const Ent: TQuakeEntity): TVector3;
var
  A: TVector3;
  Pitch, Yaw: Single;
begin
  { G_SetMovedir: "angle" -1 = up, -2 = down, else angles (pitch yaw roll) }
  if Ent.HasField('angle') then
  begin
    if SameValue(Ent.Angle, -1) then
      Exit(Vector3(0, 1, 0));
    if SameValue(Ent.Angle, -2) then
      Exit(Vector3(0, -1, 0));
    Exit(YawToCgeDir(Ent.Angle));
  end;
  A := Ent.GetVector('angles', Vector3(0, 0, 0));
  Pitch := DegToRad(A.X);
  Yaw := DegToRad(A.Y);
  { Quake pitch is positive looking down }
  Result := Vector3(Cos(Yaw) * Cos(Pitch), -Sin(Pitch), -Sin(Yaw) * Cos(Pitch));
end;

function TQuakeWorld.PropByTransform(const T: TCastleTransform): TQuakeProp;
var
  Prop: TQuakeProp;
begin
  for Prop in FProps do
    if Prop.OwnsTransform(T) then
      Exit(Prop);
  Result := nil;
end;

function TQuakeWorld.EntityBox(const Ent: TQuakeEntity; out Box: TBox3D): Boolean;
begin
  Result := ModelBox(Ent.Model, Box);
  if (not Result) and Ent.HasField('mins') and Ent.HasField('maxs') then
  begin
    Box := QuakeBoxToCge(Ent.Origin + Ent.GetVector('mins', TVector3.Zero),
      Ent.Origin + Ent.GetVector('maxs', TVector3.Zero));
    Result := True;
  end;
end;

procedure TQuakeWorld.KillBox(const Box: TBox3D);
var
  M: TQuakeMonster;
  Prop: TQuakeProp;
begin
  { KillBox: MOD_TELEFRAG damage to everything solid in the box }
  if (FPlayer <> nil) and not FDead and Box.Collision(PlayerBox) then
    DamagePlayer(100000, Box.Center);
  for M in FMonsters do
    if M.IsAlive and not M.Dormant and
       Box.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
      M.TakeDamage(100000);
  for Prop in FProps do
    if (Prop.Kind = pkExplobox) and not Prop.Destroyed and Box.Contains(Prop.Transform.Translation) then
      DamageProp(Prop, 100000);
end;

procedure TQuakeWorld.SetPlayerGravity(const Value: Single);
begin
  FPlayerGravity := Value;
  if (FPlayer <> nil) and (FBaseGravity > 0) then
    FPlayer.GravityAcceleration := FBaseGravity * Value;
end;

function TQuakeWorld.EarthquakeCount: Integer;
begin
  Result := Length(FQuakes);
end;

function TQuakeWorld.GibTraceMap(const Start, Stop: TVector3; out EndPos, Normal: TVector3): Boolean;
var
  T: TQuakeTrace;
begin
  EndPos := Stop;
  Normal := Vector3(0, 1, 0);
  Result := False;
  if FBsp = nil then
    Exit;
  T := WorldTrace(CgeToQuake(Start), CgeToQuake(Stop), TVector3.Zero, TVector3.Zero,
    CONTENTS_SOLID or CONTENTS_WINDOW, nil);
  if T.AllSolid then
    Exit;
  Result := T.Hit;
  if Result then
  begin
    EndPos := QuakeToCge(T.EndPos);
    Normal := QuakeToCge(T.Normal) - QuakeToCge(TVector3.Zero);
  end;
end;

procedure TQuakeWorld.ResetClock(const I: Integer);
var
  Flags, Count: Integer;
begin
  { func_clock_reset }
  Flags := FClocks[I].Entity.SpawnFlags;
  Count := FClocks[I].Entity.GetInt('count', 0);
  if ((Flags and 1) <> 0) and (Count = 0) then
    Count := 60 * 60;
  FClocks[I].Activated := False;
  if (Flags and 1) <> 0 then
  begin
    FClocks[I].Health := 0;
    FClocks[I].Wait := Count;
  end else
  if (Flags and 2) <> 0 then
  begin
    FClocks[I].Health := Count;
    FClocks[I].Wait := 0;
  end;
end;

procedure TQuakeWorld.ClockThink(const I: Integer);
var
  Ent: TQuakeEntity;
  Flags, Style: Integer;
  Text: String;
  List: TQuakeEntityList;
  H, M, Sec, MSec: Word;
begin
  { func_clock_think, once a second }
  Ent := FClocks[I].Entity;
  Flags := Ent.SpawnFlags;
  Style := Ent.GetInt('style', 0);
  if FClocks[I].Display = nil then
  begin
    List := FBsp.FindByTargetName(Ent.Target);
    try
      if List.Count > 0 then
        FClocks[I].Display := List[0];
    finally
      List.Free;
    end;
    if FClocks[I].Display = nil then
    begin
      FClocks[I].NextThink := -1;
      Exit;
    end;
  end;
  if (Flags and 1) <> 0 then
  begin
    Text := ClockText(Style, FClocks[I].Health);
    Inc(FClocks[I].Health);
  end else
  if (Flags and 2) <> 0 then
  begin
    Text := ClockText(Style, FClocks[I].Health);
    Dec(FClocks[I].Health);
  end else
  begin
    { The time of day }
    DecodeTime(Now, H, M, Sec, MSec);
    Text := ClockText(2, H * 3600 + M * 60 + Sec);
  end;
  FClocks[I].Display.SetField('message', Text);
  TargetStringUse(FClocks[I].Display);
  FClocks[I].NextThink := FTime + 1;
  if (((Flags and 1) <> 0) and (FClocks[I].Health > FClocks[I].Wait)) or
     (((Flags and 2) <> 0) and (FClocks[I].Health < FClocks[I].Wait)) then
  begin
    { Time is up: fire the pathtarget }
    if Ent.GetField('pathtarget') <> '' then
    begin
      WritelnLog('QuakeWorld', 'func_clock fires "%s"', [Ent.GetField('pathtarget')]);
      UseTargets(Ent.GetField('pathtarget'));
    end;
    if (Flags and 8) = 0 then
    begin
      FClocks[I].NextThink := -1;
      Exit;
    end;
    ResetClock(I);
    if (Flags and 4) <> 0 then
      FClocks[I].NextThink := -1;
  end;
end;

procedure TQuakeWorld.UpdateMedics(const SecondsPassed: Single);
var
  Medic, M, Best: TQuakeMonster;
begin
  FMedicTimer := FMedicTimer - SecondsPassed;
  if FMedicTimer > 0 then
    Exit;
  FMedicTimer := 1;
  for Medic in FMonsters do
  begin
    if (not Medic.IsMedic) or (not Medic.IsAlive) or Medic.Dormant or (Medic.HealTarget <> nil) or
       (Medic.WeldTarget <> nil) then
      Continue;
    { medic_FindDeadMonster: a visible, finished corpse within 1024 units,
      not claimed by another medic, the one with the most max health }
    Best := nil;
    for M in FMonsters do
      if (M <> Medic) and (not M.IsAlive) and (M.State = msDead) and (not M.Gibbed) and (not M.GoodGuy) and
         (not M.Dormant) and M.Transform.Exists and (M.Healer = nil) and
         (PointsDistance(M.Transform.Translation, Medic.Transform.Translation) <= 1024) and
         Medic.HasLineOfSight(M.Transform.Translation + Vector3(0, 8, 0)) and
         ((Best = nil) or (M.Def^.Health > Best.Def^.Health)) then
        Best := M;
    if Best <> nil then
    begin
      Medic.HealTarget := Best;
      Medic.HealTime := 0;
      Best.Healer := Medic;
      WritelnLog('QuakeWorld', '%s goes to revive %s', [Medic.Transform.Name, Best.Transform.Name]);
    end else
    if Medic.IsFixbot and (Medic.WeldTarget = nil) and (Medic.WeldCooldown = 0) and not Medic.Alerted then
      FindWeldTarget(Medic);
  end;
end;

procedure TQuakeWorld.FindWeldTarget(const Fixbot: TQuakeMonster);
var
  Pair: specialize TPair<TQuakeEntity, Single>;
  Pos: TVector3;
begin
  { use_scanner: the first func_object_repair within 1024 units, in sight,
    with health 100 or more }
  for Pair in FPeriodic do
    if Pair.Key.ClassName = 'func_object_repair' then
    begin
      Pos := QuakeToCge(Pair.Key.Origin);
      if (RepairHealth(Pair.Key) >= 100) and
         (PointsDistance(Pos, Fixbot.Transform.Translation) <= 1024) and Fixbot.HasLineOfSight(Pos) then
      begin
        Fixbot.WeldTarget := Pair.Key;
        WritelnLog('QuakeWorld', '%s goes to weld at %s', [Fixbot.Transform.Name, Pair.Key.Origin.ToString]);
        Exit;
      end;
    end;
end;

procedure TQuakeWorld.MonsterRevived(const Monster: TQuakeMonster);
begin
  { monster_start counts the monster again }
  Inc(FStats.TotalKills);
end;

procedure TQuakeWorld.UpdateClocks;
var
  I: Integer;
begin
  for I := 0 to High(FClocks) do
    if (FClocks[I].NextThink >= 0) and (FTime >= FClocks[I].NextThink) then
      ClockThink(I);
end;

procedure TQuakeWorld.TargetStringUse(const Ent: TQuakeEntity);
var
  Mover: TQuakeMover;
  Team, Msg: String;
begin
  Team := Ent.GetField('team');
  Msg := Ent.MessageText;
  FLastString := Msg;
  if Team = '' then
    Exit;
  for Mover in FGeometry.Movers do
    if (Mover.Entity.ClassName = 'target_character') and (Mover.Entity.GetField('team') = Team) and
       (Mover.Entity.GetInt('count', 0) > 0) then
      Mover.CharFrame := CharacterFrame(Msg, Mover.Entity.GetInt('count', 0));
end;

procedure TQuakeWorld.UpdateEarthquakes;
var
  I: Integer;
  V: TVector3;
begin
  { target_earthquake_think, every 0.1 s: shove the player while on the
    ground (Quake 2 adds crandom() * 150 sideways and sets the vertical
    speed to speed * 100 / mass, mass 200), quake.wav every 0.5 s }
  for I := High(FQuakes) downto 0 do
  begin
    if FTime >= FQuakes[I].EndTime then
    begin
      Delete(FQuakes, I, 1);
      Continue;
    end;
    if FTime >= FQuakes[I].NextSound then
    begin
      FQuakes[I].NextSound := FTime + 0.5;
      Sounds.Play('sound/world/quake.wav');
    end;
    if (FTime >= FQuakes[I].NextShove) and (FPlayer <> nil) and FPlayer.OnGround and not FDead then
    begin
      FQuakes[I].NextShove := FTime + 0.1;
      V := FPlayer.Velocity;
      V.X := V.X + (Random * 2 - 1) * 150;
      V.Z := V.Z + (Random * 2 - 1) * 150;
      V.Y := FQuakes[I].Entity.Speed(200) * 0.5;
      FPlayer.Velocity := V;
    end;
  end;
end;

procedure TQuakeWorld.DropMonsterItem(const M: TQuakeMonster);
var
  CName: String;
  Ent: TQuakeEntity;
  Org: TVector3;
begin
  CName := LowerCase(M.Entity.GetField('item'));
  if FindItemDef(CName) = nil then
  begin
    WritelnLog('QuakeWorld', '%s: item "%s" unknown, not dropped', [M.Transform.Name, CName]);
    Exit;
  end;
  { A new entity (no targets of its own), where the monster died, resting
    like map items (origin 15 above the floor; a monster's is 24) }
  Org := M.Origin - Vector3(0, 0, 9);
  Ent := TQuakeEntity.Create;
  Ent.SetField('classname', CName);
  Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
  FBsp.Entities.Add(Ent);
  SpawnEntity(Ent);
  WritelnLog('QuakeWorld', '%s dropped %s', [M.Transform.Name, CName]);
end;

procedure TQuakeWorld.UpdateFallingObjects(const SecondsPassed: Single);
var
  Mover: TQuakeMover;
  Box: TBox3D;
  A, B, QMin, QMax, C: TVector3;
  T: TQuakeTrace;
begin
  { func_object: MOVETYPE_TOSS (gravity 800) until it lands }
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
    if Mover.Tossing and Mover.Transform.Exists then
    begin
      Box := Mover.WorldBox;
      if Box.IsEmpty then
      begin
        Mover.Tossing := False;
        Continue;
      end;
      A := CgeToQuake(Box.Data[0]);
      B := CgeToQuake(Box.Data[1]);
      QMin := Vector3(Min(A.X, B.X), Min(A.Y, B.Y), Min(A.Z, B.Z));
      QMax := Vector3(Max(A.X, B.X), Max(A.Y, B.Y), Max(A.Z, B.Z));
      C := (QMin + QMax) * 0.5;
      Mover.TossSpeed := Min(Mover.TossSpeed + 800 * SecondsPassed, 2000);
      { SV_Physics_Toss with MASK_SOLID: it falls through players and
        monsters onto walls and floors (so func_object_touch, which only
        hurts what it lands on, never fires in practice) }
      T := WorldTrace(C, C - Vector3(0, 0, Mover.TossSpeed * SecondsPassed), QMin - C, QMax - C,
        CONTENTS_SOLID or CONTENTS_WINDOW, Mover);
      if T.StartSolid then
      begin
        Mover.Tossing := False;
        Continue;
      end;
      Mover.Transform.Translation := Mover.Transform.Translation + QuakeToCge(T.EndPos) - QuakeToCge(C);
      if T.Fraction < 1 then
      begin
        Mover.Tossing := False;
        Mover.TossSpeed := 0;
      end;
    end;
end;

procedure TQuakeWorld.UpdateFallingProps(const SecondsPassed: Single);
var
  Prop: TQuakeProp;
  OldPos, NewPos: TVector3;
  T: TQuakeTrace;
  Dmg: Integer;
begin
  { misc_viper_bomb: MOVETYPE_TOSS until it touches something, then
    misc_viper_bomb_touch: radius damage "dmg" (1000) }
  for Prop in FProps do
    if Prop.Falling and not Prop.Destroyed then
    begin
      Prop.Velocity.Y := Prop.Velocity.Y - 800 * SecondsPassed;
      OldPos := Prop.Transform.Translation;
      NewPos := OldPos + Prop.Velocity * SecondsPassed;
      if not Prop.Velocity.IsZero then
        Prop.Transform.Rotation := Vector4(0, 1, 0, ArcTan2(-Prop.Velocity.Z, Prop.Velocity.X));
      T := WorldTrace(CgeToQuake(OldPos), CgeToQuake(NewPos), Vector3(-8, -8, -8), Vector3(8, 8, 8),
        MASK_SHOT, Prop);
      if T.Hit then
      begin
        Prop.Falling := False;
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
        Dmg := Prop.Entity.GetInt('dmg', 1000);
        Explode(QuakeToCge(T.EndPos), Dmg, Dmg + 40, False);
        UseTargets(Prop.Entity.Target, Prop.Entity);
      end else
        Prop.Transform.Translation := NewPos;
    end;
end;

procedure TQuakeWorld.TempEntity(const Style: Integer; const Pos: TVector3);
begin
  { The client's CL_ParseTEnt for the temp entities maps use }
  case Style of
    TE_EXPLOSION1, TE_EXPLOSION2, TE_ROCKET_EXPLOSION, TE_GRENADE_EXPLOSION,
    TE_ROCKET_EXPLOSION_WATER, TE_GRENADE_EXPLOSION_WATER:
      begin
        Particles.SpawnExplosion(Pos);
        if Style in [TE_GRENADE_EXPLOSION, TE_GRENADE_EXPLOSION_WATER] then
          Sounds.PlayAtPoint('sound/weapons/grenlx1a.wav', Pos)
        else
          Sounds.PlayAtPoint('sound/weapons/rocklx1a.wav', Pos);
      end;
    TE_BFG_EXPLOSION, TE_BFG_BIGEXPLOSION:
      Particles.SpawnBfgExplosion(Pos);
    TE_BOSSTPORT:
      begin
        { CL_BigTeleportParticles and misc/bigtele.wav, heard everywhere }
        Particles.SpawnTeleport(Pos);
        Particles.SpawnTeleport(Pos + Vector3(0, 40, 0));
        Sounds.PlayAtPoint('sound/misc/bigtele.wav', Pos, 1, ATTN_NONE);
      end;
    TE_GUNSHOT, TE_SHOTGUN, TE_SPARKS, TE_BULLET_SPARKS, TE_SCREEN_SPARKS, TE_SHIELD_SPARKS,
    TE_LASER_SPARKS, TE_WELDING_SPARKS:
      Particles.SpawnImpact(Pos, Vector3(0, 1, 0));
    TE_BLOOD:
      Particles.SpawnBlood(Pos, Vector3(0, 1, 0));
    TE_BLASTER:
      Particles.SpawnBlasterImpact(Pos, Vector3(0, 1, 0));
    TE_SPLASH:
      Particles.SpawnSplash(Pos, Vector3(0, 1, 0), 0, 32);
  else
    WritelnLog('QuakeWorld', 'target_temp_entity style %d not drawn', [Style]);
  end;
end;

procedure TQuakeWorld.ActivateProp(const Prop: TQuakeProp);
var
  Other: TQuakeProp;
begin
  case Prop.Kind of
    pkSatelliteDish:
      if Prop.Model <> nil then
        Prop.Model.PlayAnim('', False, 10);
    pkCommanderBody:
      if not Prop.ThudPlayed and not Prop.AnimOnce then
      begin
        { commander_body_use: the tank's pain sound, then frames 1..24 }
        Sounds.PlayAt('sound/tank/pain.wav', Prop.Transform, 1, 1, chBody);
        Prop.AnimFirst := 1;
        Prop.AnimLast := 24;
        Prop.AnimTime := 0;
        Prop.AnimOnce := True;
      end;
    pkBoss3Stand:
      begin
        { Use_Boss3: TE_BOSSTPORT, and the Makron is gone }
        TempEntity(TE_BOSSTPORT, Prop.Transform.Translation);
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
      end;
    pkBlackHole:
      begin
        { misc_blackhole_use: it goes away }
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
      end;
    pkViperBomb:
      if not Prop.Falling and not Prop.Destroyed then
      begin
        { misc_viper_bomb_use: drop with the velocity of the flying viper }
        Prop.Transform.Exists := True;
        Prop.Falling := True;
        Prop.Velocity := TVector3.Zero;
        for Other in FProps do
          if (Other.Kind = pkViper) and Other.Flying then
          begin
            Prop.Velocity := Other.FlyTarget - Other.Transform.Translation;
            if not Prop.Velocity.IsZero then
              Prop.Velocity := Prop.Velocity.Normalize * Other.FlySpeed;
            Break;
          end;
      end;
    pkStroggShip, pkViper:
      if StartPropFlight(Prop) then
        Prop.Transform.Exists := True;
    pkTransport:
      { misc_strogg_ship_use: shown; train_use ignores the use (START_ON) }
      Prop.Transform.Exists := True;
    pkNukeCore:
      { misc_nuke_core_use: shown / hidden }
      Prop.Transform.Exists := not Prop.Transform.Exists;
    pkRotatingLight:
      if not Prop.Destroyed then
      begin
        { rotating_light_use: toggles the light; turning it on starts the
          alarm (0.1 s later) when it has one }
        Prop.LightOn := not Prop.LightOn;
        Prop.AlarmActive := Prop.LightOn and Prop.Alarm;
        Prop.AlarmTimer := 0.1;
      end;
    pkExplobox:
      DamageProp(Prop, 1000);
  end;
end;

function TQuakeWorld.StartPropFlight(const Prop: TQuakeProp): Boolean;
var
  List: TQuakeEntityList;
begin
  List := FBsp.FindByTargetName(Prop.Entity.Target);
  try
    Result := List.Count > 0;
    if Result then
    begin
      Prop.FlyCorner := List[0];
      Prop.FlyTarget := QuakeToCge(List[0].Origin);
      Prop.Flying := True;
    end;
  finally
    List.Free;
  end;
end;

procedure TQuakeWorld.ViperMissileUse(const Ent: TQuakeEntity);
var
  Target: TQuakeEntity;
  Start, Dir: TVector3;
begin
  { misc_viper_missile_use: one rocket ("dmg" 250, speed 500) at the entity
    its target names, then it is gone }
  if FCounters.ContainsKey(Ent) then
    Exit;
  FCounters.AddOrSetValue(Ent, 1);
  Target := PickTarget(Ent.Target);
  if Target = nil then
  begin
    WritelnLog('QuakeWorld', 'misc_viper_missile: no target "%s"', [Ent.Target]);
    Exit;
  end;
  Start := QuakeToCge(Ent.Origin);
  Dir := QuakeToCge(Target.Origin) - Start;
  if Dir.IsZero then
    Exit;
  SpawnProjectile(pkRocket, Start, Dir.Normalize, 500, Ent.GetInt('dmg', 250), False);
  { MZ2_CHICK_ROCKET_1's flash }
  Sounds.PlayAtPoint('sound/chick/chkatck2.wav', Start);
  Lighting.AddLight(Start, 200, Vector3(1, 0.5, 0.2), 0.1);
  WritelnLog('QuakeWorld', 'misc_viper_missile fired at "%s"', [Ent.Target]);
end;

procedure TQuakeWorld.NukeUse(const Ent: TQuakeEntity);
var
  M: TQuakeMonster;
  Prop: TQuakeProp;
  Count: Integer;
begin
  { use_nuke, once: 100000 damage to the player, and every monster entity
    (alive or dead, and the dead soldiers and gib heads) removed }
  if FCounters.ContainsKey(Ent) then
    Exit;
  FCounters.AddOrSetValue(Ent, 1);
  Count := 0;
  for M in FMonsters do
    if not (M.Dormant and M.Gibbed) then
    begin
      M.Gibbed := True;
      M.SetDormant(True);
      Inc(Count);
    end;
  for Prop in FProps do
    if (Prop.Kind in [pkDeadSoldier, pkGibHead]) and not Prop.Destroyed then
    begin
      Prop.Destroyed := True;
      Prop.Transform.Exists := False;
    end;
  WritelnLog('QuakeWorld', 'misc_nuke: %d monsters removed', [Count]);
  DamagePlayer(100000, QuakeToCge(Ent.Origin), True);
end;

procedure TQuakeWorld.DamageProp(const Prop: TQuakeProp; const Damage: Integer);
var
  Dmg: Integer;
begin
  if (Prop.Kind = pkRotatingLight) and not Prop.Destroyed then
  begin
    { rotating_light_killed: welding sparks, the light goes out, gone }
    Prop.Health := Prop.Health - Damage;
    if Prop.Health > 0 then
      Exit;
    TempEntity(TE_WELDING_SPARKS, Prop.Transform.Translation);
    Prop.Destroyed := True;
    Prop.LightOn := False;
    Prop.AlarmActive := False;
    Prop.Transform.Exists := False;
    WritelnLog('QuakeWorld', 'rotating_light destroyed');
    Exit;
  end;
  if (Prop.Kind <> pkExplobox) or Prop.Destroyed then
    Exit;
  Prop.Health := Prop.Health - Damage;
  if Prop.Health > 0 then
    Exit;
  { Barrel explosion: Quake 2 barrel_explode, radius damage dmg (default 150) }
  Prop.Destroyed := True;
  Prop.Transform.Exists := False;
  Particles.SpawnDebris(Prop.Transform.Translation + Vector3(0, 16, 0));
  Dmg := Prop.Entity.GetInt('dmg', 150);
  Explode(Prop.Transform.Translation + Vector3(0, 16, 0), Dmg, Dmg + 40, False);
  UseTargets(Prop.Entity.Target, Prop.Entity);
end;

procedure TQuakeWorld.UpdateTimersAndLasers(const SecondsPassed: Single);
var
  Pair: specialize TPair<TQuakeEntity, Single>;
  Fire: TQuakeEntityList;
  Ent: TQuakeEntity;
  Laser: TQuakeLaser;
  Prop: TQuakeProp;
  List: TQuakeEntityList;
  Dist: Single;
  LaserTrace: TQuakeTrace;
begin
  { func_timer }
  Fire := TQuakeEntityList.Create(False);
  try
    for Pair in FTimers do
      if (Pair.Value >= 0) and (Pair.Value <= FTime) then
        Fire.Add(Pair.Key);
    for Ent in Fire do
    begin
      FTimers[Ent] := FTime + TimerInterval(Ent);
      UseTargets(Ent.Target, Ent);
    end;
  finally
    Fire.Free;
  end;

  { func_object_repair: welding sparks every "delay" seconds; misc_amb4:
    world/amb4.wav everywhere every 2 s }
  Fire := TQuakeEntityList.Create(False);
  try
    for Pair in FPeriodic do
      if Pair.Value <= FTime then
        Fire.Add(Pair.Key);
    for Ent in Fire do
      if Ent.ClassName = 'misc_amb4' then
      begin
        FPeriodic[Ent] := FTime + 2;
        Sounds.PlayAtPoint('sound/world/amb4.wav', QuakeToCge(Ent.Origin), 1, ATTN_NONE);
      end else
        RepairThink(Ent);
  finally
    Fire.Free;
  end;

  UpdateSteam;
  { target_laser: beam until the first wall, damages the player in it }
  for Laser in FLasers do
  begin
    if not Laser.IsOn then
      Continue;
    if Laser.Mal then
    begin
      UpdateMalLaser(Laser, SecondsPassed);
      Continue;
    end;
    { target_laser_think: a MASK_SHOT trace; it hurts what it stops on }
    LaserTrace := WorldTrace(CgeToQuake(Laser.Origin), CgeToQuake(Laser.Origin + Laser.Direction * 2048),
      TVector3.Zero, TVector3.Zero, MASK_SHOT, nil);
    Dist := PointsDistance(Laser.Origin, QuakeToCge(LaserTrace.EndPos));
    Laser.SetLength(Dist);
    if LaserTrace.Ent is TQuakeMonster then
      TQuakeMonster(LaserTrace.Ent).TakeDamage(Max(1, Laser.Damage div 10));
    if LaserTrace.Ent = FPlayer then
    begin
      FHurtTimer := FHurtTimer - SecondsPassed;
      if FHurtTimer <= 0 then
      begin
        FHurtTimer := 0.1;
        DamagePlayer(Laser.Damage div 10, Laser.Origin);
      end;
    end;
  end;

  { Props: animation, ships following their path_corners }
  for Prop in FProps do
  begin
    Prop.UpdateProp(SecondsPassed);
    if Prop.Flying and (PointsDistance(Prop.Transform.Translation, Prop.FlyTarget) < 1) then
    begin
      UseTargets(Prop.FlyCorner.GetField('pathtarget'));
      List := FBsp.FindByTargetName(Prop.FlyCorner.Target);
      try
        if (Prop.FlyCorner.Target <> '') and (List.Count > 0) then
        begin
          Prop.FlyCorner := List[0];
          Prop.FlyTarget := QuakeToCge(List[0].Origin);
        end else
        begin
          { The ships vanish at the end of their path; misc_transport is a
            train and stays at its last corner }
          Prop.Flying := False;
          if Prop.Kind <> pkTransport then
            Prop.Transform.Exists := False;
        end;
      finally
        List.Free;
      end;
    end;
  end;
end;

procedure TQuakeWorld.SteamPuff(const Ent: TQuakeEntity);
var
  Dir, Pos: TVector3;
  Speed: Single;
  List: TQuakeEntityList;
begin
  { use_target_steam: towards the target's centre (else its angles), from
    half the speed out along it }
  Speed := Ent.GetFloat('speed', 75);
  Dir := EntityMoveDir(Ent);
  if Ent.Target <> '' then
  begin
    List := FBsp.FindByTargetName(Ent.Target);
    try
      if (List.Count > 0) and not (List[0].Origin - Ent.Origin).IsZero then
        Dir := QuakeToCge(List[0].Origin) - QuakeToCge(Ent.Origin);
    finally
      List.Free;
    end;
  end;
  if Dir.IsZero then
    Dir := Vector3(0, 1, 0)
  else
    Dir := Dir.Normalize;
  Pos := QuakeToCge(Ent.Origin) + Dir * (Speed * 0.5);
  Particles.SpawnSteam(Pos, Dir, Ent.GetInt('count', 32), Speed, Ent.GetInt('sounds', 8));
end;

procedure TQuakeWorld.SteamUse(const Ent, Activator: TQuakeEntity);
var
  Wait: Single;
begin
  { "wait" seconds of steam (else the using func_timer's, else 1): more
    than 0.1 s is a sustained effect, puffing every 0.1 s }
  if Ent.HasField('wait') then
    Wait := Ent.GetFloat('wait', 1)
  else
  if (Activator <> nil) and (Activator.ClassName = 'func_timer') then
    Wait := Activator.GetFloat('wait', 1)
  else
    Wait := 1;
  WritelnLog('QuakeWorld', 'target_steam puffs for %.1f s', [Wait]);
  SteamPuff(Ent);
  if Wait > 0.1 then
    FSteam.AddOrSetValue(Ent, Vector2(FTime + Wait, FTime + 0.1));
end;

procedure TQuakeWorld.UpdateSteam;
var
  Pair: specialize TPair<TQuakeEntity, TVector2>;
  Done: TQuakeEntityList;
  E: TQuakeEntity;
begin
  if FSteam.Count = 0 then
    Exit;
  Done := TQuakeEntityList.Create(False);
  try
    for Pair in FSteam do
      if FTime >= Pair.Value.X then
        Done.Add(Pair.Key)
      else
      if FTime >= Pair.Value.Y then
        Done.Add(Pair.Key);
    for E in Done do
      if FTime >= FSteam[E].X then
        FSteam.Remove(E)
      else
      begin
        SteamPuff(E);
        FSteam[E] := Vector2(FSteam[E].X, FTime + 0.1);
      end;
  finally
    Done.Free;
  end;
end;

procedure TQuakeWorld.BuildHintPaths;
const
  HINT_ENDPOINT = 1;
var
  Hints: TQuakeEntityList;
  Ent, Node: TQuakeEntity;
  Chain: array of Integer;
  Seen: specialize TDictionary<TQuakeEntity, Integer>;
  I, C, Idx: Integer;

  function HintNamed(const Name: String): TQuakeEntity;
  var
    E: TQuakeEntity;
  begin
    Result := nil;
    if Name = '' then
      Exit;
    for E in Hints do
      if E.TargetName = Name then
        Exit(E);
  end;

begin
  if HintPaths = FHintPaths then
    HintPaths := nil;
  FreeAndNil(FHintPaths);
  Hints := TQuakeEntityList.Create(False);
  Seen := specialize TDictionary<TQuakeEntity, Integer>.Create;
  try
    for Ent in FBsp.Entities do
      if Ent.ClassName = 'hint_path' then
        Hints.Add(Ent);
    if Hints.Count = 0 then
      Exit;
    FHintPaths := TQuakeHintPaths.Create;
    SetLength(FHintPaths.Nodes, Hints.Count);
    for I := 0 to Hints.Count - 1 do
    begin
      FHintPaths.Nodes[I].Pos := QuakeToCge(Hints[I].Origin);
      FHintPaths.Nodes[I].Chain := -1;
      Seen.Add(Hints[I], I);
    end;
    { Chain starts: END, a target, no targetname (at most 100) }
    for Ent in Hints do
      if ((Ent.SpawnFlags and HINT_ENDPOINT) <> 0) and (Ent.Target <> '') and (Ent.TargetName = '') and
         (Length(FHintPaths.Chains) < 100) then
      begin
        C := Length(FHintPaths.Chains);
        SetLength(Chain, 0);
        Node := Ent;
        while Node <> nil do
        begin
          Idx := Seen[Node];
          { A fork or a loop cuts the chain }
          if FHintPaths.Nodes[Idx].Chain >= 0 then
            Break;
          FHintPaths.Nodes[Idx].Chain := C;
          FHintPaths.Nodes[Idx].Order := Length(Chain);
          SetLength(Chain, Length(Chain) + 1);
          Chain[High(Chain)] := Idx;
          Node := HintNamed(Node.Target);
        end;
        if Length(Chain) > 1 then
        begin
          SetLength(FHintPaths.Chains, C + 1);
          FHintPaths.Chains[C] := Copy(Chain);
        end else
          for Idx in Chain do
            FHintPaths.Nodes[Idx].Chain := -1;
      end;
    WritelnLog('QuakeWorld', 'Hint paths: %d chains of %d nodes', [Length(FHintPaths.Chains), Hints.Count]);
  finally
    Seen.Free;
    Hints.Free;
  end;
  HintPaths := FHintPaths;
end;

function TQuakeWorld.HintPointsVisible(const FromPos, ToPos: TVector3): Boolean;
begin
  Result := WorldTrace(CgeToQuake(FromPos), CgeToQuake(ToPos), TVector3.Zero, TVector3.Zero,
    MASK_OPAQUE, nil).Fraction >= 1;
end;

procedure TQuakeWorld.BossSummon(const Boss: TQuakeMonster);
var
  Cls: String;
  Offsets: array of TVector3;
  I: Integer;
  YawRad: Single;
  Fwd, Right, Pos, Mins, Maxs: TVector3;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
  Before, M: TQuakeMonster;
  Made: Integer;
begin
  if Boss.MonsterSlots <= 0 then
    Exit;
  if Boss.Def^.ClassName = 'monster_carrier' then
  begin
    { CarrierSpawn: flyers 105 ahead and 58 below, one each half second
      (three a spawn move; the middle one a kamikaze in Ground Zero) }
    Cls := 'monster_flyer';
    Offsets := [Vector3(105, 0, -58), Vector3(105, 48, -58), Vector3(105, -48, -58)];
  end else
  begin
    { WidowSpawn / Widow2Spawn: two stalkers beside her }
    Cls := 'monster_stalker';
    if Boss.Def^.ClassName = 'monster_widow2' then
      Offsets := [Vector3(30, 135, 0), Vector3(30, -135, 0)]
    else
      Offsets := [Vector3(30, 100, 16), Vector3(30, -100, 16)];
  end;
  MonsterBoxSize(Cls, Mins, Maxs);
  YawRad := DegToRad(Boss.Facing);
  Fwd := Vector3(Cos(YawRad), Sin(YawRad), 0);
  Right := Vector3(Sin(YawRad), -Cos(YawRad), 0);
  Made := 0;
  for I := 0 to High(Offsets) do
  begin
    if Boss.MonsterSlots <= 0 then
      Break;
    Pos := Boss.Origin + Fwd * Offsets[I].X - Right * Offsets[I].Y + Vector3(0, 0, Offsets[I].Z);
    T := WorldTrace(Pos, Pos, Mins, Maxs, MASK_MONSTERSOLID, Boss);
    if T.StartSolid then
      Continue;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Cls);
    Ent.SetField('origin', Format('%d %d %d', [Round(Pos.X), Round(Pos.Y), Round(Pos.Z)]));
    Ent.SetField('angle', IntToStr(Round(Boss.Facing)));
    FBsp.Entities.Add(Ent);
    Before := nil;
    if FMonsters.Count > 0 then
      Before := FMonsters.Last;
    SpawnEntity(Ent);
    if (FMonsters.Count = 0) or (FMonsters.Last = Before) then
      Continue;
    M := FMonsters.Last;
    { AI_SPAWNED_*, AI_DO_NOT_COUNT; they go after the boss's enemy }
    M.DoNotCount := True;
    Dec(FStats.TotalKills);
    M.Alert;
    Particles.SpawnTeleport(M.Transform.Translation);
    Dec(Boss.MonsterSlots);
    Inc(Made);
  end;
  if Made > 0 then
    Sounds.PlayAt('sound/medic_commander/monsterspawn1.wav', Boss.Transform, 1, ATTN_NONE, chBody);
  WritelnLog('QuakeWorld', '%s spawns %d %s (%d slots left)', [Boss.Transform.Name, Made, Cls, Boss.MonsterSlots]);
end;

procedure TQuakeWorld.HeatBeam(const Monster: TQuakeMonster; const Eye, Target: TVector3);
var
  T: TQuakeTrace;
  Dir: TVector3;
begin
  { monster_fire_heat: a trace to the target and on, 10 to what it hits }
  Dir := (Target - Eye).Normalize;
  T := WorldTrace(CgeToQuake(Eye), CgeToQuake(Eye + Dir * 8192), TVector3.Zero, TVector3.Zero, MASK_SHOT, Monster);
  if T.Ent is TQuakePlayerMovement then
  begin
    { Drawn to just short of the player: particles at the eye fill the view }
    if PointsDistance(Eye, QuakeToCge(T.EndPos)) > 64 then
      Particles.SpawnBeam(Eye, QuakeToCge(T.EndPos) - Dir * 48, Vector3(1.0, 0.6, 0.2));
    DamagePlayer(Monster.AttackDamage, Eye);
  end else
  begin
    Particles.SpawnBeam(Eye, QuakeToCge(T.EndPos), Vector3(1.0, 0.6, 0.2));
  end;
  if not (T.Ent is TQuakePlayerMovement) then
  if T.Hit and ((T.Contents and CONTENTS_SOLID) <> 0) then
    Particles.SpawnSteam(QuakeToCge(T.EndPos) - Dir * 2, -Dir, 8, 60, 223);
end;

procedure TQuakeWorld.UpdateWidows;
var
  M, S: TQuakeMonster;
  Ent: TQuakeEntity;
  Org: TVector3;
begin
  for M in FMonsters do
    if (M.Def^.ClassName = 'monster_widow') and (M.State = msDead) and (not M.Gibbed) and M.Transform.Exists then
    begin
      { spawn_out_do: splashes, TE_BOSSTPORT, the legs left behind, gone }
      Org := M.Origin;
      TempEntity(TE_EXPLOSION1, M.Transform.Translation + Vector3(0, 36, 0));
      Particles.SpawnTeleport(M.Transform.Translation);
      Sounds.PlayAtPoint('sound/misc/bigtele.wav', M.Transform.Translation);
      Ent := TQuakeEntity.Create;
      Ent.SetField('classname', 'widow_legs');
      Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z - 24)]));
      Ent.SetField('angle', IntToStr(Round(M.Facing)));
      FBsp.Entities.Add(Ent);
      FProps.Add(TQuakeProp.CreateProp(FMap, pkWidowLegs, Ent));
      M.Gibbed := True;
      M.Transform.Exists := False;
      WritelnLog('QuakeWorld', '%s beams out', [M.Transform.Name]);
    end else
    if (M.Def^.ClassName = 'monster_widow2') and (not M.IsAlive) and (not M.Gibbed) and
       (M.Health > M.GibHealth) and not FCounters.ContainsKey(M.Entity) then
    begin
      { widow2_die: KillChildren, every stalker on the map dies }
      FCounters.AddOrSetValue(M.Entity, 1);
      for S in FMonsters do
        if S.IsAlive and (S.Def^.ClassName = 'monster_stalker') then
          S.TakeDamage(S.Health + 1);
      WritelnLog('QuakeWorld', '%s dies: her stalkers with her', [M.Transform.Name]);
    end;
end;

procedure TQuakeWorld.MedicSummon(const Medic: TQuakeMonster);
const
  Reinforcements: array[0..6] of String = ('monster_soldier_light', 'monster_soldier',
    'monster_soldier_ss', 'monster_infantry', 'monster_gunner', 'monster_medic', 'monster_gladiator');
  Offsets: array[0..4] of record X, Y: Single; end = (
    (X: 80; Y: 0), (X: 40; Y: 60), (X: 40; Y: -60), (X: 0; Y: 80), (X: 0; Y: -80));
  SlotOffsets: array[0..4] of Integer = (0, 2, 2, 4, 4);
var
  Strength, Count, I, Side, SideIdx, Cls, Made: Integer;
  R, YawRad: Single;
  Fwd, Right, Pos, Mins, Maxs: TVector3;
  Spots: array of TVector3;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
  Before, M: TQuakeMonster;
begin
  if Medic.MonsterSlots <= 0 then
    Exit;
  { The strength: the skill plus luck (-3 .. +3), at least 0; the number:
    1, 1, 1, 3, 3, 5, 5 for strength 0 .. 6 }
  Strength := GameSkill;
  R := Random;
  if R < 0.05 then Dec(Strength, 3)
  else if R < 0.15 then Dec(Strength, 2)
  else if R < 0.3 then Dec(Strength)
  else if R > 0.95 then Inc(Strength, 3)
  else if R > 0.85 then Inc(Strength, 2)
  else if R > 0.7 then Inc(Strength);
  Strength := Max(0, Strength);
  if Strength = 0 then
    Count := 1
  else
    Count := (Strength - 1) + (Strength mod 2);
  Count := Min(Min(Count, 5), Medic.MonsterSlots);
  { The spots in front (80 ahead, 40 ahead and 60 to the sides, 80 to the
    sides), else the same behind: free for the box, a floor within 256 }
  YawRad := DegToRad(Medic.Facing);
  Fwd := Vector3(Cos(YawRad), Sin(YawRad), 0);
  Right := Vector3(Sin(YawRad), -Cos(YawRad), 0);
  Spots := nil;
  for SideIdx := 0 to 1 do
  begin
    Side := 1 - 2 * SideIdx;
    for I := 0 to Count - 1 do
    begin
      Cls := EnsureRange(Strength - SlotOffsets[I], 0, 6);
      MonsterBoxSize(Reinforcements[Cls], Mins, Maxs);
      Pos := Medic.Origin + Fwd * (Offsets[I].X * Side) - Right * (Offsets[I].Y * Side) + Vector3(0, 0, 10);
      T := WorldTrace(Pos, Pos, Mins, Maxs, MASK_MONSTERSOLID, Medic);
      if T.StartSolid then
        Continue;
      T := WorldTrace(Pos, Pos - Vector3(0, 0, 256), Mins, Maxs, MASK_MONSTERSOLID, Medic);
      if T.Fraction >= 1 then
        Continue;
      SetLength(Spots, Length(Spots) + 1);
      Spots[High(Spots)] := Vector3(T.EndPos.X, T.EndPos.Y, I);
    end;
    if Length(Spots) > 0 then
      Break;
  end;
  Made := 0;
  for I := 0 to High(Spots) do
  begin
    Cls := EnsureRange(Strength - SlotOffsets[Round(Spots[I].Z)], 0, 6);
    MonsterBoxSize(Reinforcements[Cls], Mins, Maxs);
    Pos := Medic.Origin + Fwd * 0;
    T := WorldTrace(Vector3(Spots[I].X, Spots[I].Y, Medic.Origin.Z + 10),
      Vector3(Spots[I].X, Spots[I].Y, Medic.Origin.Z + 10 - 256), Mins, Maxs, MASK_MONSTERSOLID, Medic);
    Pos := T.EndPos;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Reinforcements[Cls]);
    Ent.SetField('origin', Format('%d %d %d', [Round(Pos.X), Round(Pos.Y), Round(Pos.Z)]));
    Ent.SetField('angle', IntToStr(Round(Medic.Facing)));
    FBsp.Entities.Add(Ent);
    Before := nil;
    if FMonsters.Count > 0 then
      Before := FMonsters.Last;
    SpawnEntity(Ent);
    if (FMonsters.Count = 0) or (FMonsters.Last = Before) then
      Continue;
    M := FMonsters.Last;
    { AI_DO_NOT_COUNT: not in the level's totals }
    M.DoNotCount := True;
    Dec(FStats.TotalKills);
    M.Alert;
    Particles.SpawnTeleport(M.Transform.Translation);
    Dec(Medic.MonsterSlots);
    Inc(Made);
  end;
  WritelnLog('QuakeWorld', '%s calls %d reinforcements (strength %d, %d slots left)',
    [Medic.Transform.Name, Made, Strength, Medic.MonsterSlots]);
end;

procedure TQuakeWorld.RemoveDefender(const WithExplosion: Boolean);
begin
  if FDefender = nil then
    Exit;
  { sphere_think_explode: BecomeExplosion1 }
  if WithExplosion then
    TempEntity(TE_EXPLOSION1, FDefender.Translation);
  FreeAndNil(FDefenderModel);
  FreeAndNil(FDefenderShell);
  FreeAndNil(FDefender);
  FDefenderEnemy := nil;
end;

procedure TQuakeWorld.UpdateDefender(const SecondsPassed: Single);
var
  Goal, Dir: TVector3;
begin
  if (FStats.DefenderTime <= 0) or FDead then
  begin
    if FDefender <> nil then
      WritelnLog('QuakeWorld', 'Defender sphere gone');
    RemoveDefender(FDefender <> nil);
    FStats.DefenderTime := 0;
    Exit;
  end;
  FStats.DefenderTime := Max(0, FStats.DefenderTime - SecondsPassed);
  { Above the player's head (4 over the top of the box) }
  Goal := FPlayerPos + Vector3(0, 32 - 22 + 4, 0);
  if FDefender = nil then
  begin
    FDefender := TCastleTransform.Create(nil);
    FDefender.Name := 'DefenderSphere';
    FDefender.Translation := Goal;
    FDefenderModel := Md2Manager.CreateInstance('models/items/defender/tris.md2');
    if FDefenderModel <> nil then
    begin
      FDefenderModel.Scene.Collides := False;
      FDefenderModel.Scene.Pickable := False;
      FDefender.Add(FDefenderModel.Scene);
    end;
    FDefenderShell := Md2Manager.CreateInstance('models/items/shell/tris.md2');
    if FDefenderShell <> nil then
    begin
      FDefenderShell.Scene.Collides := False;
      FDefenderShell.Scene.Pickable := False;
      FDefender.Add(FDefenderShell.Scene);
    end;
    FItems.Add(FDefender);
  end;
  { defender_think: 5 times the way there a second; RF_FULLBRIGHT }
  FDefender.Translation := FDefender.Translation + (Goal - FDefender.Translation) * Min(1, 5 * SecondsPassed);
  FDefender.Rotation := Vector4(0, 1, 0, FTime * 2);
  if FDefenderModel <> nil then
    FDefenderModel.SetTint(Vector3(1.5, 1.5, 1.5));
  { Every 0.1 s: a bolt of 10 at 1000 at its enemy while it is alive and in
    sight, 0.4 s apart }
  FDefenderCooldown := FDefenderCooldown - SecondsPassed;
  FDefenderThink := FDefenderThink - SecondsPassed;
  if FDefenderThink > 0 then
    Exit;
  FDefenderThink := 0.1;
  if (FDefenderEnemy <> nil) and ((not FDefenderEnemy.IsAlive) or FDefenderEnemy.Dormant) then
    FDefenderEnemy := nil;
  if (FDefenderEnemy = nil) or (FDefenderCooldown > 0) then
    Exit;
  if not HintPointsVisible(FDefender.Translation, FDefenderEnemy.EyePos) then
    Exit;
  Dir := (FDefenderEnemy.Transform.Translation - FDefender.Translation).Normalize;
  SpawnProjectile(pkBlasterBolt, FDefender.Translation + Vector3(0, 2, 0), Dir, 1000, 10, True);
  Sounds.PlayAt('sound/weapons/laser2.wav', FDefender, 1, 1, chWeapon);
  FDefenderCooldown := 0.4;
  WritelnLog('QuakeWorld', 'Defender sphere fires at %s', [FDefenderEnemy.Transform.Name]);
end;

procedure TQuakeWorld.AngerUse(const Ent: TQuakeEntity);
var
  Victims: TQuakeEntityList;
  M: TQuakeMonster;
  Pos: TVector3;
begin
  { target_anger_use: the monsters named by "target" go after the entity
    named by "killtarget" (an info_notnull in the game's maps: they shoot
    at a spot) }
  if (Ent.Target = '') or (Ent.GetField('killtarget') = '') then
    Exit;
  Victims := FBsp.FindByTargetName(Ent.GetField('killtarget'));
  try
    if Victims.Count = 0 then
      Exit;
    Pos := QuakeToCge(Victims[0].Origin);
  finally
    Victims.Free;
  end;
  for M in FMonsters do
    if M.IsAlive and SameText(M.Entity.TargetName, Ent.Target) then
    begin
      if M.Dormant then
        M.Spawn;
      M.AngerActive := True;
      M.AngerPos := Pos;
      M.Alert;
      WritelnLog('QuakeWorld', '%s angered at %s', [M.Transform.Name, Ent.GetField('killtarget')]);
    end;
end;

procedure TQuakeWorld.KillPlayersUse(const Ent: TQuakeEntity);
var
  M: TQuakeMonster;
  Count: Integer;
begin
  { target_killplayers_use: the player dies, and so does every monster the
    player can see }
  Count := 0;
  for M in FMonsters do
    if M.IsAlive and (not M.Dormant) and M.HasLineOfSight(FPlayerPos) then
    begin
      M.TakeDamage(M.Health);
      Inc(Count);
    end;
  WritelnLog('QuakeWorld', 'target_killplayers: the player and %d monsters killed', [Count]);
  DamagePlayer(100000, QuakeToCge(Ent.Origin), True);
end;

function TQuakeWorld.RepairHealth(const Ent: TQuakeEntity): Integer;
begin
  if not FRepairHealth.TryGetValue(Ent, Result) then
    Result := 100;
end;

procedure TQuakeWorld.RepairThink(const Ent: TQuakeEntity);
var
  Health: Integer;
  Delay: Single;
begin
  Health := RepairHealth(Ent);
  Delay := Max(0.1, Ent.GetFloat('delay', 1));
  FPeriodic[Ent] := FTime + Delay;
  if not FCounters.ContainsKey(Ent) then
  begin
    { object_repair_sparks: sparks every "delay" until welded below 0;
      then (object_repair_dead) its targets fire once }
    if Health < 0 then
    begin
      FCounters.AddOrSetValue(Ent, 1);
      FPeriodic[Ent] := FTime + 0.1;
      WritelnLog('QuakeWorld', 'func_object_repair repaired: fires "%s"', [Ent.Target]);
      UseTargets(Ent.Target, Ent);
    end else
      TempEntity(TE_WELDING_SPARKS, QuakeToCge(Ent.Origin));
  end else
  if Health <= 100 then
    { object_repair_fx: a point of health every "delay", no sparks }
    FRepairHealth.AddOrSetValue(Ent, Health + 1)
  else
    TempEntity(TE_WELDING_SPARKS, QuakeToCge(Ent.Origin));
end;

function TQuakeWorld.WeldCycle(const Target: TQuakeEntity): Boolean;
var
  Health: Integer;
begin
  { weldstate on weldmiddle_07: 10 off; done below 0 }
  Health := RepairHealth(Target) - 10;
  FRepairHealth.AddOrSetValue(Target, Health);
  Result := Health < 0;
end;

function TQuakeWorld.MonsterPointContents(const QuakePos: TVector3): Integer;
begin
  if FBsp = nil then
    Exit(0);
  Result := FBsp.PointContents(QuakePos);
end;

procedure TQuakeWorld.UpdateMalLaser(const Laser: TQuakeLaser; const SecondsPassed: Single);
var
  T: TQuakeTrace;
  From, Stop: TVector3;
  Ignore: TObject;
  I: Integer;
  Pulse: Boolean;
begin
  { mal_laser_think: the beam goes through monsters and the player (each
    hit takes "dmg" on a pulse) and stops at anything else }
  Laser.PulseTimer := Laser.PulseTimer - SecondsPassed;
  Pulse := Laser.PulseTimer <= 0;
  if Pulse then
    Laser.PulseTimer := Laser.PulseTimer + Laser.Wait + 0.1;
  From := CgeToQuake(Laser.Origin);
  Stop := CgeToQuake(Laser.Origin + Laser.Direction * 2048);
  Ignore := nil;
  for I := 1 to 16 do
  begin
    T := WorldTrace(From, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    if T.Ent is TQuakeMonster then
    begin
      if Pulse then
        TQuakeMonster(T.Ent).TakeDamage(Laser.Damage);
    end else
    if T.Ent = FPlayer then
    begin
      if Pulse then
        DamagePlayer(Laser.Damage, Laser.Origin);
    end else
      Break;
    Ignore := T.Ent;
    From := T.EndPos;
  end;
  Laser.SetLength(PointsDistance(Laser.Origin, QuakeToCge(T.EndPos)));
  if Pulse then
  begin
    if (Laser.Pulses > 0) and (T.Fraction < 1) then
      TempEntity(TE_LASER_SPARKS, QuakeToCge(T.EndPos));
    Inc(Laser.Pulses);
  end;
end;

function TQuakeWorld.PickTarget(const ATargetName: String): TQuakeEntity;
var
  List: TQuakeEntityList;
begin
  Result := nil;
  if (ATargetName = '') or (FBsp = nil) then
    Exit;
  List := FBsp.FindByTargetName(ATargetName);
  try
    if List.Count > 0 then
      Result := List[Random(List.Count)];
  finally
    List.Free;
  end;
end;

procedure TQuakeWorld.UseTargets(const ATarget: String; const Source: TQuakeEntity);
var
  List: TQuakeEntityList;
  Ent, OldSource: TQuakeEntity;
begin
  if (ATarget = '') or (FBsp = nil) or (FUseDepth > 16) then
    Exit;
  Inc(FUseDepth);
  OldSource := FUseSource;
  List := FBsp.FindByTargetName(ATarget);
  try
    for Ent in List do
    begin
      FUseSource := Source;
      UseEntity(Ent);
    end;
  finally
    List.Free;
    FUseSource := OldSource;
    Dec(FUseDepth);
  end;
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

{ dynamic_light: a light each frame while on, at its "shadowlightradius",
  coloured, times "shadowlightintensity" and its light style
  ("shadowlightstyle", or the style of the "shadowlightstyletarget" light) }
procedure TQuakeWorld.UpdateDynamicLights;
var
  Prop: TQuakeProp;
  Ent, StyleEnt: TQuakeEntity;
  OnOff, Style: Integer;
  Brightness: Single;
  List: TQuakeEntityList;
begin
  { EF_SPINNINGLIGHTS (CL_AddPacketEntities): a red light of radius 100 going
    round the rotating_light 64 units out, at its height }
  for Prop in FProps do
    if (Prop.Kind = pkRotatingLight) and Prop.LightOn and not Prop.Destroyed and
       Prop.Transform.Exists then
      Lighting.AddLight(Prop.Transform.Translation +
        YawToCgeDir(Prop.Entity.Angle + Prop.SpinAngle) * 64, 100, Vector3(1, 0, 0));
  for Ent in FDynamicLights do
  begin
    if (not FCounters.TryGetValue(Ent, OnOff)) or (OnOff = 0) then
      Continue;
    Style := Ent.GetInt('shadowlightstyle', -1);
    if Ent.GetField('shadowlightstyletarget') <> '' then
    begin
      List := FBsp.FindByTargetName(Ent.GetField('shadowlightstyletarget'));
      try
        if List.Count > 0 then
        begin
          StyleEnt := List[0];
          Style := StyleEnt.GetInt('style', Style);
        end;
      finally
        List.Free;
      end;
    end;
    Brightness := Ent.GetFloat('shadowlightintensity', 1);
    if Style >= 0 then
      Brightness := Brightness * Lighting.StyleValue(Style);
    if Brightness <= 0 then
      Continue;
    Lighting.AddLight(QuakeToCge(Ent.Origin), Ent.GetFloat('shadowlightradius', 0),
      RemasterLightColor(Ent) * Brightness);
  end;
end;

{ Quake 2 trigger_elevator_use: sends its func_train to a path_corner named
  by the pathtarget of whatever used it (a button for each floor), unless
  the train is moving }
procedure TQuakeWorld.ElevatorUse(const Ent, Source: TQuakeEntity);
var
  Mover, Train: TQuakeMover;
  Corners: TQuakeEntityList;
  Corner: TQuakeEntity;
begin
  Train := nil;
  for Mover in FGeometry.Movers do
    if (Mover.Kind = mkTrain) and (Mover.TargetName <> '') and (Mover.TargetName = Ent.Target) then
    begin
      Train := Mover;
      Break;
    end;
  if Train = nil then
  begin
    WritelnLog('QuakeWorld', 'trigger_elevator "%s": target "%s" is not a func_train', [Ent.TargetName, Ent.Target]);
    Exit;
  end;
  if Train.TrainRunning and not Train.TrainWaiting then
    Exit;
  if (Source = nil) or (Source.GetField('pathtarget') = '') then
  begin
    WritelnLog('QuakeWorld', 'trigger_elevator "%s" used with no pathtarget', [Ent.TargetName]);
    Exit;
  end;
  Corners := FBsp.FindByTargetName(Source.GetField('pathtarget'));
  try
    if Corners.Count = 0 then
    begin
      WritelnLog('QuakeWorld', 'trigger_elevator "%s": bad pathtarget "%s"', [Ent.TargetName, Source.GetField('pathtarget')]);
      Exit;
    end;
    { G_PickTarget: one of them at random }
    Corner := Corners[Random(Corners.Count)];
  finally
    Corners.Free;
  end;
  Train.TrainResume(Corner);
  WritelnLog('QuakeWorld', 'trigger_elevator "%s" sends %s to "%s"', [Ent.TargetName, Train.Entity.Model, Corner.TargetName]);
end;

procedure TQuakeWorld.CheckTriggers(const SecondsPassed: Single);
var
  Trig: TQuakeTrigger;
  CName, Msg: String;
  PBox: TBox3D;
  Dests: TQuakeEntityList;
  Dest: TQuakeEntity;
  D: TDelayedTarget;
begin
  PBox := PlayerBox;
  for Trig in FTriggers do
  begin
    Trig.Cooldown := Max(0, Trig.Cooldown - SecondsPassed);
    if (not Trig.Enabled) or (Trig.Cooldown > 0) or not Trig.Box.Collision(PBox) then
      Continue;

    CName := Trig.Entity.ClassName;
    if CName = 'trigger_hurt' then
    begin
      FHurtTimer := FHurtTimer - SecondsPassed;
      if FHurtTimer <= 0 then
      begin
        FHurtTimer := 0.1;
        DamagePlayer(Max(1, Trig.Entity.GetInt('dmg', 5)), Trig.Box.Center);
      end;
      Continue;
    end;

    if (CName = 'misc_teleporter') or (CName = 'trigger_teleport') then
    begin
      { teleporter_touch / trigger_teleport_touch (G_PickTarget: one of the
        destinations at random) to misc_teleporter_dest or
        info_teleport_destination, 10 above it, facing its angle }
      Dests := FBsp.FindByTargetName(Trig.Entity.Target);
      try
        if Dests.Count > 0 then
        begin
          Dest := Dests[Random(Dests.Count)];
          if CName = 'misc_teleporter' then
            Dest := Dests[0];
          FTeleportPending := True;
          FTeleportPos := QuakeToCge(Dest.Origin) + Vector3(0, PlayerEyeHeight - 24 + 10, 0);
          FTeleportAngle := Dest.Angle;
          Particles.SpawnTeleport(FTeleportPos);
          Sounds.Play('sound/misc/tele1.wav');
          Trig.Cooldown := 1.0;
        end;
      finally
        Dests.Free;
      end;
      Continue;
    end;

    if (CName = 'trigger_multiple') or (CName = 'trigger_once') then
    begin
      Msg := Trig.Entity.MessageText;
      if (Msg <> '') and (FHud <> nil) then
      begin
        FHud.ShowMessage(Msg, 4);
        Sounds.Play('sound/misc/talk1.wav');
      end;
      if Trig.Entity.GetFloat('delay', 0) > 0 then
      begin
        D.Time := FTime + Trig.Entity.GetFloat('delay', 0);
        D.Target := Trig.Entity.Target;
        D.Entity := nil;
        FDelayed.Add(D);
      end else
        UseTargets(Trig.Entity.Target, Trig.Entity);
      if CName = 'trigger_once' then
        Trig.Enabled := False
      else
        Trig.Cooldown := Max(0.2, Trig.Entity.GetFloat('wait', 0.2));
    end else
    if CName = 'trigger_disguise' then
    begin
      { trigger_disguise_touch: disguised (REMOVE, 4: no longer) }
      PlayerDisguised := (Trig.Entity.SpawnFlags and 4) = 0;
      Continue;
    end else
    if CName = 'trigger_gravity' then
    begin
      { trigger_gravity_touch: the toucher keeps this gravity multiplier }
      SetPlayerGravity(Trig.Entity.GetFloat('gravity', 1));
      Continue;
    end else
    if CName = 'trigger_push' then
    begin
      { Quake 2 trigger_push: velocity = movedir * speed * 10 (speed default 1000) }
      if FPlayer <> nil then
        FPlayer.Velocity := EntityMoveDir(Trig.Entity) * Trig.Entity.GetFloat('speed', 1000) * 10;
      Sounds.Play('sound/misc/windfly.wav');
      { PUSH_ONCE = 1 }
      if (Trig.Entity.SpawnFlags and 1) <> 0 then
        Trig.Enabled := False
      else
        Trig.Cooldown := 0.1;
    end;
  end;
end;

procedure TQuakeWorld.CheckMonsterTriggers;
var
  Trig: TQuakeTrigger;
  Monster: TQuakeMonster;
  Dir: TVector3;
  Speed, Height: Single;
begin
  for Trig in FTriggers do
  begin
    if (not Trig.Enabled) or (Trig.Entity.ClassName <> 'trigger_monsterjump') then
      Continue;
    { SP_trigger_monsterjump: speed 200, height 200; movedir is horizontal }
    Speed := Trig.Entity.GetFloat('speed', 200);
    Height := Trig.Entity.GetFloat('height', 200);
    Dir := EntityMoveDir(Trig.Entity);
    Dir.Y := 0;
    if not Dir.IsZero then
      Dir := Dir.Normalize;
    for Monster in FMonsters do
      if Monster.IsAlive and (not Monster.Dormant) and (not Monster.Def^.Flying) and
         Trig.Box.Collision(Monster.Transform.BoundingBox) then
        Monster.MonsterJump(Dir * Speed, Height);
  end;
end;

procedure TQuakeWorld.CheckMovers;
const
  DOOR_NOMONSTER = 8;
var
  Mover: TQuakeMover;
  Box, PBox: TBox3D;
  M: TQuakeMonster;

  { touch_DoorTrigger: monsters open doors too (not DOOR_NOMONSTER ones) }
  function MonsterInField(const Field: TBox3D): Boolean;
  var
    M: TQuakeMonster;
  begin
    Result := False;
    if (Mover.Entity.SpawnFlags and DOOR_NOMONSTER) <> 0 then
      Exit;
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and (M.Transform <> nil) and M.Transform.Exists and
         Field.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
        Exit(True);
  end;

begin
  PBox := PlayerBox;
  { func_plat2's use: the activator is the player }
  FGeometry.PlayerOriginZ := FPlayerPos.Y - (PlayerEyeHeight - 24);
  for Mover in FGeometry.Movers do
  begin
    if not Mover.Transform.Exists then
      Continue;
    Box := Mover.WorldBox;
    if Box.IsEmpty then
      Continue;
    case Mover.Kind of
      mkDoor, mkDoorRotating:
        if Mover.AutoOpen then
        begin
          { Quake 2 door trigger field: the closed door's box expanded by 60
            horizontally, made once; it stays there while the door moves, so
            standing in it keeps an open door open (door_go_up at the top
            restarts the wait) }
          if Mover.TriggerField.IsEmpty and (Mover.State = msAtStart) then
          begin
            Box.Data[0] := Box.Data[0] - Vector3(60, 0, 60);
            Box.Data[1] := Box.Data[1] + Vector3(60, 0, 60);
            Mover.TriggerField := Box;
          end;
          if not Mover.TriggerField.IsEmpty then
          begin
            if (Mover.State = msAtStart) and
               (Mover.TriggerField.Collision(PBox) or MonsterInField(Mover.TriggerField)) then
              Mover.Use
            else
            if (Mover.State = msAtEnd) and
               (Mover.TriggerField.Collision(PBox) or MonsterInField(Mover.TriggerField)) then
              Mover.StateTimer := Mover.WaitTime;
          end;
        end;
      mkPlat2:
        { Touch_Plat_Center2: live players and monsters in its field }
        if Mover.Plat2Active then
        begin
          if (not FDead) and Mover.TriggerField.Collision(PBox) then
            Mover.Plat2Operate(FPlayerPos.Y - (PlayerEyeHeight - 24));
          for M in FMonsters do
            if M.IsAlive and (not M.Dormant) and M.Transform.Exists and
               Mover.TriggerField.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
              Mover.Plat2Operate(M.Origin.Z);
        end;
      mkPlat:
        if (FPlayerPos.X >= Box.Data[0].X) and (FPlayerPos.X <= Box.Data[1].X) and
           (FPlayerPos.Z >= Box.Data[0].Z) and (FPlayerPos.Z <= Box.Data[1].Z) and
           (Abs((FPlayerPos.Y - PlayerEyeHeight) - Box.Data[1].Y) < 24) then
          Mover.PlayerOnTop;
      mkButton:
        if (Mover.Health = 0) and (Mover.State = msAtStart) then
        begin
          Box.Data[0] := Box.Data[0] - Vector3(8, 8, 8);
          Box.Data[1] := Box.Data[1] + Vector3(8, 8, 8);
          if Box.Collision(PBox) then
            Mover.Use;
        end;
    end;
  end;
end;

function TQuakeWorld.MonsterByTransform(const T: TCastleTransform): TQuakeMonster;
var
  M: TQuakeMonster;
begin
  for M in FMonsters do
    if M.OwnsTransform(T) then
      Exit(M);
  Result := nil;
end;

function TQuakeWorld.MoverByTransform(const T: TCastleTransform): TQuakeMover;
var
  Mover: TQuakeMover;
begin
  if FGeometry <> nil then
    for Mover in FGeometry.Movers do
      if (T = Mover.Scene) or (T = Mover.Transform) then
        Exit(Mover);
  Result := nil;
end;

function TQuakeWorld.DamageMultiplier: Integer;
begin
  { P_DamageModifier: quad 4, else double damage 2 }
  if FStats.QuadTime > 0 then
    Result := 4
  else
  if FStats.DoubleTime > 0 then
    Result := 2
  else
    Result := 1;
end;

procedure TQuakeWorld.FireHitscan(const Origin, Dir: TVector3; const Damage: Integer;
  const HSpread, VSpread: Single; const Rail: Boolean);
var
  ShotDir, HitPos, Right, Muzzle, Start, Stop: TVector3;
  T: TQuakeTrace;
  Ignore: TObject;
  Pierce: Integer;
begin
  ShotDir := SpreadDir(Dir, HSpread, VSpread);
  { Rail trails start at the gun muzzle (right and below the eye), not the eye }
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.Length > 0.001 then
    Right := Right.Normalize;
  Muzzle := Origin + Dir * 24 + Right * 7 - Vector3(0, 8, 0);
  { Quake 2 fire_lead / fire_rail: a point trace for MASK_SHOT; the railgun
    goes on through monsters (ignoring the one it just hit) }
  Start := CgeToQuake(Origin);
  Stop := Start + CgeToQuake(ShotDir) * 8192;
  Ignore := FPlayer;
  for Pierce := 0 to 4 do
  begin
    T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    HitPos := QuakeToCge(T.EndPos);
    if not T.Hit then
    begin
      if Rail then
        Particles.SpawnRailTrail(Muzzle, HitPos);
      Exit;
    end;
    if T.Ent is TQuakeMonster then
    begin
      TQuakeMonster(T.Ent).TakeDamage(Damage);
      Particles.SpawnBlood(HitPos, -ShotDir);
      if Rail then
      begin
        Start := T.EndPos;
        Ignore := T.Ent;
        Continue;
      end;
      Exit;
    end;
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Damage)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Damage);
    if Rail then
      Particles.SpawnRailTrail(Muzzle, HitPos)
    else
      Particles.SpawnImpact(HitPos - ShotDir * 2, -ShotDir);
    Exit;
  end;
end;

procedure TQuakeWorld.ThrowHandGrenade(const Fuse: Single);
const
  { Quake 2 weapon_grenade_fire: speed grows with the time the pin was pulled }
  MinSpeed = 400;
  MaxSpeed = 800;
begin
  if FStats.Ammo[atGrenades] > 0 then
    Dec(FStats.Ammo[atGrenades]);
  SpawnProjectile(pkHandGrenade, FPlayerPos + FPlayerDir * 16, (FPlayerDir + Vector3(0, 0.1, 0)).Normalize,
    MinSpeed + (GrenadeTimer - Fuse) * (MaxSpeed - MinSpeed) / GrenadeTimer, 125 * DamageMultiplier, True);
  FProjectiles.Last.Life := Max(0.1, Fuse);
  Sounds.Play('sound/weapons/hgrent1a.wav', 1, chWeapon);
end;

procedure TQuakeWorld.ThrowTesla(const Fuse: Single);
const
  MinSpeed = 400;
  MaxSpeed = 800;
var
  Speed: Single;
  Right, Vel: TVector3;
begin
  if FStats.Ammo[atTesla] > 0 then
    Dec(FStats.Ammo[atTesla]);
  { weapon_tesla_fire: a grenade's 400 .. 800 by the time it was held,
    from 22 below the eyes; fire_tesla: up 200 (+- 10), a little sideways }
  Speed := EnsureRange(MinSpeed + (GrenadeTimer - Fuse) * (MaxSpeed - MinSpeed) / GrenadeTimer, MinSpeed, MaxSpeed);
  Right := TVector3.CrossProduct(FPlayerDir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Vel := FPlayerDir * Speed + Vector3(0, 200 + (Random * 2 - 1) * 10, 0) + Right * ((Random * 2 - 1) * 10);
  { The damage: TESLA_DAMAGE 3 times the multiplier at the throw }
  SpawnProjectile(pkTesla, FPlayerPos - Vector3(0, 22, 0) - Right * 4, Vel.Normalize, Vel.Length,
    3 * DamageMultiplier, True);
  Sounds.Play('sound/weapons/hgrent1a.wav', 1, chWeapon);
  WritelnLog('QuakeWorld', 'Tesla thrown at %.0f units/s', [Speed]);
end;

procedure TQuakeWorld.TeslaThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
const
  { TESLA_ACTIVATE_TIME, TESLA_TIME_TO_LIVE; the field: 128 each way, up
    128 from its bottom; TESLA_EXPLOSION_DAMAGE_MULT 50, radius 200 }
  ActivateTime = 3;
  TimeToLive = 30;
var
  Pos, Top, Mins, Maxs: TVector3;
  M: TQuakeMonster;
  Frame: Integer;

  procedure Blow;
  begin
    { tesla_remove / tesla_blow: the grenade explosion, 50 times its zap }
    WritelnLog('QuakeWorld', 'Tesla blows up');
    Explode(Proj.Transform.Translation + Vector3(0, 8, 0), Proj.Damage * 50, 200, Proj.FromPlayer);
    Proj.Life := 0;
  end;

begin
  Proj.TeslaClock := Proj.TeslaClock + SecondsPassed;
  Pos := Proj.Transform.Translation;
  if not Proj.TeslaActive then
  begin
    if Proj.TeslaClock < ActivateTime then
      Exit;
    { tesla_activate: open frames 0..14 a tenth of a second each (skins on
      10, 12 and 14), then on }
    Frame := Min(14, Trunc((Proj.TeslaClock - ActivateTime) * 10));
    if Frame <> Proj.TeslaFrame then
    begin
      if Proj.TeslaFrame < 0 then
        Sounds.PlayAt('sound/weapons/teslaopen.wav', Proj.Transform);
      Proj.TeslaFrame := Frame;
      if Proj.Model <> nil then
      begin
        Proj.Model.SetFrame(Frame);
        if Frame >= 14 then
          Proj.Model.SetSkin(3)
        else
        if Frame >= 12 then
          Proj.Model.SetSkin(2)
        else
        if Frame >= 10 then
          Proj.Model.SetSkin(1);
      end;
    end;
    if Proj.TeslaClock < ActivateTime + 1.6 then
      Exit;
    { In water, slime or lava it blows up at once }
    if (MonsterPointContents(CgeToQuake(Pos + Vector3(0, 4, 0))) and MASK_LIQUID) <> 0 then
    begin
      Blow;
      Exit;
    end;
    Proj.TeslaActive := True;
    Proj.TeslaClock := 0;
    WritelnLog('QuakeWorld', 'Tesla active at %s', [CgeToQuake(Pos).ToString]);
    Exit;
  end;
  if Proj.TeslaClock >= TimeToLive then
  begin
    Blow;
    Exit;
  end;
  { tesla_think_active: every 0.1 s each monster in the field it can see
    takes 3 (times the multiplier), drawn as lightning }
  Proj.TeslaZap := Proj.TeslaZap - SecondsPassed;
  if Proj.TeslaZap > 0 then
    Exit;
  Proj.TeslaZap := Proj.TeslaZap + 0.1;
  Top := Pos + Vector3(0, 16, 0);
  for M in FMonsters do
    if M.IsAlive and (not M.Dormant) then
    begin
      Mins := M.Origin + M.BoxMins;
      Maxs := M.Origin + M.BoxMaxs;
      if (Maxs.X < CgeToQuake(Pos).X - 128) or (Mins.X > CgeToQuake(Pos).X + 128) or
         (Maxs.Y < CgeToQuake(Pos).Y - 128) or (Mins.Y > CgeToQuake(Pos).Y + 128) or
         (Maxs.Z < CgeToQuake(Pos).Z) or (Mins.Z > CgeToQuake(Pos).Z + 128) then
        Continue;
      if not HintPointsVisible(Top, M.Transform.Translation) then
        Continue;
      Particles.SpawnBeam(Top, M.Transform.Translation, Vector3(0.6, 0.7, 1.0));
      M.TakeDamage(Proj.Damage);
      if not M.IsAlive then
        WritelnLog('QuakeWorld', 'Tesla killed %s', [M.Transform.Name]);
    end;
end;

procedure TQuakeWorld.ThrowTrap(const Fuse: Single);
const
  { weapon_trap_fire: 300 .. 700 over TRAP_TIMER (5 s), from the time the
    trap was held (the hold timer starts at 3.2 s like a grenade's) }
  TrapTimer = 5.0;
  MinSpeed = 300;
  MaxSpeed = 700;
var
  Speed: Single;
  Right, Vel: TVector3;
begin
  if FStats.Ammo[atTraps] > 0 then
    Dec(FStats.Ammo[atTraps]);
  Speed := Min(MinSpeed + (TrapTimer - Fuse) * (MaxSpeed - MinSpeed) / TrapTimer, MaxSpeed);
  { fire_trap: up 200 (+- 10) and a little sideways on top }
  Right := TVector3.CrossProduct(FPlayerDir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Vel := FPlayerDir * Speed + Vector3(0, 200 + (Random * 2 - 1) * 10, 0) + Right * ((Random * 2 - 1) * 10);
  SpawnProjectile(pkTrap, FPlayerPos + FPlayerDir * 8 - Vector3(0, 8, 0), Vel.Normalize, Vel.Length, 0, True);
  WritelnLog('QuakeWorld', 'Trap thrown at %.0f units/s', [Speed]);
end;

procedure TQuakeWorld.UpdateGun(const SecondsPassed: Single);
begin
  if FDead then
  begin
    FGun.Attack := False;
    FGun.AttackLatched := False;
    FFireHeld := False;
    FPrevFireHeld := False;
    Exit;
  end;
  { FireWeapon of the previous frame set FFireHeld }
  FGun.Attack := FFireHeld;
  FGun.Update(SecondsPassed);
  FPrevFireHeld := FFireHeld;
  FFireHeld := False;
  FGun.Attack := False;
end;

function TQuakeWorld.GunAmmo(const Slot: Integer): Integer;
var
  Def: TQuakeWeaponDef;
begin
  Def := WeaponDefs[Slot];
  if (Def.AmmoType = atNone) or (Def.AmmoPerShot <= 0) then
    Result := MaxInt
  else
    Result := FStats.Ammo[Def.AmmoType] div Def.AmmoPerShot;
end;

procedure TQuakeWorld.NoAmmoWeaponChange;

  function Has(const Slot: Integer; const Ammo: TAmmoType; const Count: Integer): Boolean;
  begin
    Result := ((FStats.WeaponMask and (1 shl Slot)) <> 0) and (FStats.Ammo[Ammo] >= Count);
  end;

begin
  { NoAmmoWeaponChange, with The Reckoning's weapons in their chains }
  if Has(9, atSlugs, 1) then
    SelectWeapon(9)
  else
  if Has(PhalanxSlot, atMagSlugs, 1) then
    SelectWeapon(PhalanxSlot)
  else
  if Has(PlasmaBeamSlot, atCells, 2) then
    SelectWeapon(PlasmaBeamSlot)
  else
  if Has(8, atCells, 1) then
    SelectWeapon(8)
  else
  if Has(IonRipperSlot, atCells, 2) then
    SelectWeapon(IonRipperSlot)
  else
  if Has(EtfRifleSlot, atFlechettes, 1) then
    SelectWeapon(EtfRifleSlot)
  else
  if Has(5, atBullets, 1) then
    SelectWeapon(5)
  else
  if Has(4, atBullets, 1) then
    SelectWeapon(4)
  else
  if Has(3, atShells, 2) then
    SelectWeapon(3)
  else
  if Has(2, atShells, 1) then
    SelectWeapon(2)
  else
    SelectWeapon(1);
end;

function TQuakeWorld.SilencedVolume: Single;
begin
  if FStats.SilencerShots > 0 then
    Result := 0.2
  else
    Result := 1;
end;

procedure TQuakeWorld.WeaponNoise;
begin
  if FStats.SilencerShots > 0 then
    Dec(FStats.SilencerShots)
  else
    PlayerNoise(FPlayerPos);
end;

procedure TQuakeWorld.UpdatePlayerItems(const SecondsPassed: Single);

  { airout.wav as 3 seconds are left (remaining == 30 frames) }
  procedure Tick(var Time: Single);
  begin
    if Time <= 0 then
      Exit;
    if (Time > 3) and (Time - SecondsPassed <= 3) then
      Sounds.Play('sound/items/airout.wav', 1, chItem);
    Time := Max(0, Time - SecondsPassed);
  end;

begin
  Tick(FStats.EnviroTime);
  Tick(FStats.BreatherTime);
  { G_SetStats: power armor goes off when the cells run out }
  if FStats.PowerArmorOn and (FStats.Ammo[atCells] <= 0) then
  begin
    FStats.PowerArmorOn := False;
    Sounds.Play('sound/misc/power2.wav', 1, chItem);
  end;
end;

procedure TQuakeWorld.GunEvent(const Event: TGunEvent);
begin
  case Event of
    geFire: FireGun;
    geBfgFlash:
      begin
        { weapon_bfg_fire frame 9: flash and sound, the ball follows on frame 17 }
        Sounds.Play(WeaponDefs[10].Sound, SilencedVolume, chWeapon);
        Lighting.TriggerMuzzleFlash(FPlayerPos + FPlayerDir * 16);
        FLastFireTime := FTime;
        WeaponNoise;
      end;
    geNoAmmo:
      begin
        Sounds.Play('sound/weapons/noammo.wav', 1, chVoice);
        if FHud <> nil then
          FHud.ShowMessage('No ammo for ' + WeaponDefs[FGun.Slot].Name, 1.5);
        NoAmmoWeaponChange;
      end;
    geChangeWeapon:
      begin
        if FGun.PendingSlot <> 0 then
          FStats.CurrentWeapon := FGun.PendingSlot;
        UpdateWeaponModel;
      end;
    geGrenadePin:
      if FGun.Slot = TrapSlot then
        Sounds.Play('sound/weapons/trapcock.wav', 1, chWeapon)
      else
        Sounds.Play('sound/weapons/hgrena1b.wav', 1, chWeapon);
    geGrenadeThrow:
      if FGun.Slot = TrapSlot then
        ThrowTrap(FGun.Fuse)
      else
      if FGun.Slot = TeslaSlot then
        ThrowTesla(FGun.Fuse)
      else
        ThrowHandGrenade(FGun.Fuse);
    geGrenadeBlowUp:
      begin
        { Held too long: it goes off in the hand }
        if FStats.Ammo[atGrenades] > 0 then
          Dec(FStats.Ammo[atGrenades]);
        Explode(FPlayerPos + FPlayerDir * 16, 125 * DamageMultiplier, 165, True);
      end;
    geChaingunUp: Sounds.Play('sound/weapons/chngnu1a.wav');
    geChaingunDown: Sounds.Play('sound/weapons/chngnd1a.wav');
    geHyperBlasterDown: Sounds.Play('sound/weapons/hyprbd1a.wav');
  end;
end;

procedure TQuakeWorld.AddProjectileLights;
var
  Proj: TQuakeProjectile;
begin
  { Quake 2 CL_AddPacketEntities: EF_ROCKET / EF_BLASTER / EF_HYPERBLASTER / EF_BFG }
  for Proj in FProjectiles do
    case Proj.Kind of
      { EF_TRAP: a flickering orange light while it is open }
      pkTrap:
        if Proj.TrapFrame >= 4 then
          Lighting.AddLight(Proj.Transform.Translation, 100 + Random(100), Vector3(1, 0.8, 0.1));
      pkRocket, pkBlasterBolt, pkHeatRocket, pkLoogie:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(1, 1, 0));
      { EF_IONRIPPER / EF_BLUEHYPERBLASTER / EF_PLASMA (the client's colours
        aren't in the game code: orange, blue and white-blue here) }
      pkRipper:
        Lighting.AddLight(Proj.Transform.Translation, 120, Vector3(1, 0.5, 0.1));
      pkBlueBolt:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0.2, 0.3, 1));
      pkPlasma:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0.6, 0.8, 1));
      pkBfg:
        if not Proj.Exploding then
          Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0, 1, 0));
    end;
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
  if (FGun.LoopSound <> '') and not FDead then
    Sounds.AddLoop(FGun.LoopSound, Listener);
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

procedure TQuakeWorld.SetSurfaceLights;
var
  Lights: TQuakeSurfaceLights;
  Count: Integer;
begin
  Count := Lighting.NearestLights(FPlayerPos, Lights);
  FGeometry.SetSurfaceLights(Lights, Count);
end;

procedure TQuakeWorld.SpawnProjectile(const Kind: TProjectileKind; const Origin, Dir: TVector3;
  const Speed: Single; const Damage: Integer; const FromPlayer: Boolean; const Owner: TQuakeMonster);
var
  Proj: TQuakeProjectile;
begin
  Proj := TQuakeProjectile.Create(FItems, Kind, Origin, Dir * Speed, Damage, FromPlayer);
  Proj.Owner := Owner;
  { fire_blaster, fire_rocket and fire_bfg let the target dodge }
  if FromPlayer and (Kind in [pkBlasterBolt, pkRocket, pkBfg, pkRipper, pkPlasma]) then
    CheckDodge(Origin, Dir, Speed);
  case Kind of
    pkRocket:
      begin
        Proj.SplashDamage := 120;
        Proj.SplashRadius := 120;
      end;
    pkGrenade:
      begin
        Proj.SplashDamage := Damage;
        Proj.SplashRadius := 160;
        Proj.Life := 2.5;
      end;
    pkHandGrenade:
      begin
        Proj.SplashDamage := Damage;
        Proj.SplashRadius := 165;
        Proj.Life := 3;
      end;
    pkBfg:
      begin
        { weapon_bfg_fire: fire_bfg(damage 500, speed 400, radius 1000); the
          shot's Damage is the 200 of the core hit, both times the quad }
        Proj.SplashDamage := Damage * 5 div 2;
        Proj.SplashRadius := 1000;
        Proj.LaserTimer := 0.1;
      end;
  end;
  FProjectiles.Add(Proj);
end;

function TQuakeWorld.ProjectileCount: Integer;
begin
  Result := FProjectiles.Count;
end;

function TQuakeWorld.DelayedCount: Integer;
begin
  Result := FDelayed.Count;
end;

procedure TQuakeWorld.MonsterFoundTarget(const Monster: TQuakeMonster);
begin
  if FSightEntities.IndexOf(Monster) < 0 then
    FSightEntities.Add(Monster);
end;

procedure TQuakeWorld.UpdatePlayerTrail(const SecondsPassed: Single);
var
  Origin, ToSpot: TVector3;
begin
  PlayerTrail.Now := FTime;
  FTrailTimer := FTrailTimer - SecondsPassed;
  if (FTrailTimer > 0) or FDead then
    Exit;
  FTrailTimer := 0.1;
  { The player's origin: 22 below the eye }
  Origin := FPlayerPos - Vector3(0, 22, 0);
  if PlayerTrail.Count > 0 then
  begin
    ToSpot := PlayerTrail.LastSpot - Origin;
    if ToSpot.Length < 1 then
      Exit;
    if WorldTrace(CgeToQuake(Origin), CgeToQuake(PlayerTrail.LastSpot), TVector3.Zero, TVector3.Zero,
       MASK_OPAQUE, FPlayer).Fraction >= 1 then
      Exit; { still sees the last spot }
  end;
  PlayerTrail.Add(Origin);
end;

procedure TQuakeWorld.ProcessSightEntities;
var
  Spotters: array of TQuakeMonster;
  S, M: TQuakeMonster;
  I: Integer;
begin
  if FSightEntities.Count = 0 then
    Exit;
  { Monsters woken here find the player too: they act as sight entities
    on the next frame, like Quake 2's one sight_entity per frame }
  SetLength(Spotters, FSightEntities.Count);
  for I := 0 to FSightEntities.Count - 1 do
    Spotters[I] := FSightEntities[I];
  FSightEntities.Clear;
  for S in Spotters do
    for M in FMonsters do
      if (M <> S) and not M.Alerted and not M.Ambush and not M.Dormant and M.IsAlive and
         M.WouldNotice(S.Transform.Translation - M.Transform.Translation) and
         M.HasLineOfSight(S.EyePos) then
        M.Alert;
end;

procedure TQuakeWorld.CheckDodge(const Origin, Dir: TVector3; const Speed: Single);
var
  T: TQuakeTrace;
  Dist: Single;
  M: TQuakeMonster;
begin
  if (Speed <= 0) or ((GameSkill = 0) and (Random > 0.25)) then
    Exit;
  T := WorldTrace(CgeToQuake(Origin), CgeToQuake(Origin + Dir * 8192), TVector3.Zero, TVector3.Zero,
    MASK_SHOT, FPlayer);
  if not (T.Ent is TQuakeMonster) then
    Exit;
  M := TQuakeMonster(T.Ent);
  Dist := PointsDistance(Origin, QuakeToCge(T.EndPos));
  if not M.IsAlive then
    Exit;
  { infront(monster, player) }
  if TVector3.DotProduct(YawToCgeDir(M.FacingAngle), (FPlayerPos - M.Transform.Translation).Normalize) <= 0.3 then
    Exit;
  M.Dodge(Max(0, Dist - 16) / Speed);
end;

procedure TQuakeWorld.PlayerNoise(const Pos: TVector3);
var
  M: TQuakeMonster;
begin
  if NoTarget or (FGeometry = nil) then
    Exit;
  for M in FMonsters do
    if (not M.Alerted) and (not M.Dormant) and M.IsAlive and
       (PointsDistance(M.Transform.Translation, Pos) <= 1000) and
       FGeometry.CanHear(Pos, M.Transform.Translation) and
       ((not M.Ambush) or M.HasLineOfSight(Pos)) then
      M.Alert;
end;

procedure TQuakeWorld.Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
  const FromPlayer: Boolean; const ExplosionSound: Boolean);
var
  M: TQuakeMonster;
  Mover: TQuakeMover;
  Prop: TQuakeProp;
  Dist: Single;
  Points: Integer;
begin
  Particles.SpawnExplosion(Pos);
  { Quake 2 rocket / grenade impacts: PlayerNoise(PNOISE_IMPACT) }
  if FromPlayer then
    PlayerNoise(Pos);
  { Heard from where it happens (Quake 2 TE_ROCKET_EXPLOSION, ATTN_NORM) }
  if ExplosionSound then
    Sounds.PlayAtPoint('sound/weapons/rocklx1a.wav', Pos);
  { Quake 2 explosion light: radius 350, orange, fading with the fireball }
  Lighting.AddLight(Pos, 350, Vector3(1, 0.5, 0.5), 0.5);
  if Damage <= 0 then
    Exit;
  for M in FMonsters do
  begin
    Dist := PointsDistance(M.Transform.Translation, Pos);
    if Dist < Radius then
    begin
      Points := Round(Damage * (1 - 0.5 * Dist / Radius));
      if Points > 0 then
        M.TakeDamage(Points);
    end;
  end;
  { Splash damage also sets off explosive brushes and barrels (chain reactions) }
  if (FGeometry <> nil) and (FUseDepth < 8) then
  begin
    Inc(FUseDepth);
    try
      for Mover in FGeometry.Movers do
        if (Mover.Health > 0) and Mover.Transform.Exists and
           (PointsDistance(Mover.Center, Pos) < Radius + 32) then
          DamageMover(Mover, Damage div 2);
      for Prop in FProps do
        if (Prop.Kind in [pkExplobox, pkRotatingLight]) and not Prop.Destroyed and
           (PointsDistance(Prop.Transform.Translation, Pos) < Radius) then
          DamageProp(Prop, Damage div 2);
    finally
      Dec(FUseDepth);
    end;
  end;

  Dist := PointsDistance(FPlayerPos - Vector3(0, 22, 0), Pos);
  if Dist < Radius then
  begin
    Points := Round(Damage * (1 - 0.5 * Dist / Radius));
    { Self damage is halved, like Quake 2 rockets }
    if FromPlayer then
      Points := Points div 2;
    if Points > 0 then
      DamagePlayer(Points, Pos);
  end;
end;

function MonsterCenter(const M: TQuakeMonster): TVector3;
begin
  Result := CgeToQuake(M.Transform.Translation) + (M.BoxMins + M.BoxMaxs) * 0.5;
end;

procedure TQuakeWorld.BfgLasers(const Proj: TQuakeProjectile);
const
  LaserMask = CONTENTS_SOLID or CONTENTS_MONSTER or CONTENTS_DEADMONSTER;
  LaserDamage = 10; { single player }
var
  Origin: TVector3;

  procedure LaserAt(const Target: TVector3);
  var
    Dir, Start, Stop: TVector3;
    Ignore: TObject;
    T: TQuakeTrace;
    I: Integer;
  begin
    Dir := (Target - Origin).Normalize;
    Start := Origin;
    Stop := Origin + Dir * 2048;
    Ignore := nil;
    { Through monsters (and the player), hurting each, until something else }
    for I := 0 to 7 do
    begin
      T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, LaserMask, Ignore);
      if not T.Hit then
        Break;
      if T.Ent is TQuakeMonster then
      begin
        if T.Ent <> Proj.Owner then
          TQuakeMonster(T.Ent).TakeDamage(LaserDamage);
      end else
      if T.Ent is TQuakePlayerMovement then
      begin
        if not Proj.FromPlayer then
          DamagePlayer(LaserDamage, QuakeToCge(Origin));
      end else
        Break;
      Ignore := T.Ent;
      Start := T.EndPos;
    end;
    Particles.SpawnBfgLaser(QuakeToCge(Origin), QuakeToCge(T.EndPos));
  end;

var
  M: TQuakeMonster;
  Center: TVector3;
begin
  Origin := CgeToQuake(Proj.Transform.Translation);
  for M in FMonsters do
    if M.IsAlive and (M <> Proj.Owner) and M.Transform.Exists then
    begin
      Center := MonsterCenter(M);
      if PointsDistance(Center, Origin) <= 256 then
        LaserAt(Center);
    end;
  if not Proj.FromPlayer and not FDead then
  begin
    Center := CgeToQuake(FPlayerPos - Vector3(0, 22, 0));
    if PointsDistance(Center, Origin) <= 256 then
      LaserAt(Center);
  end;
end;

procedure TQuakeWorld.BfgEffect(const Proj: TQuakeProjectile);
const
  SightMask = CONTENTS_SOLID or CONTENTS_WINDOW;
var
  Origin, Shooter: TVector3;

  { CanDamage, simplified to the centre: no brush between the two points }
  function Clear(const A, B: TVector3): Boolean;
  begin
    Result := not WorldTrace(A, B, TVector3.Zero, TVector3.Zero, SightMask, nil).Hit;
  end;

  function Points(const Center: TVector3): Integer;
  var
    Dist: Single;
  begin
    Result := 0;
    Dist := PointsDistance(Center, Origin);
    if (Dist > Proj.SplashRadius) or not Clear(Origin, Center) or not Clear(Shooter, Center) then
      Exit;
    Result := Round(Proj.SplashDamage * (1 - Sqrt(Dist / Proj.SplashRadius)));
  end;

  procedure HitEffect(const CgePos: TVector3);
  begin
    { TE_BFG_EXPLOSION: the s_bfg2 sprite and a green light }
    Particles.SpawnBfgHit(CgePos);
    Lighting.AddLight(CgePos, 350, Vector3(0, 1, 0), 0.4);
  end;

var
  M: TQuakeMonster;
  N: Integer;
begin
  Origin := CgeToQuake(Proj.Transform.Translation);
  if Proj.FromPlayer then
    Shooter := CgeToQuake(FPlayerPos)
  else
  if Proj.Owner <> nil then
    Shooter := MonsterCenter(Proj.Owner)
  else
    Shooter := Origin;
  for M in FMonsters do
    if (M <> Proj.Owner) and not M.Gibbed and M.Transform.Exists then
    begin
      N := Points(MonsterCenter(M));
      if N <= 0 then
        Continue;
      HitEffect(M.Transform.Translation);
      M.TakeDamage(N);
    end;
  if not Proj.FromPlayer and not FDead then
  begin
    N := Points(CgeToQuake(FPlayerPos - Vector3(0, 22, 0)));
    if N > 0 then
    begin
      HitEffect(FPlayerPos - Vector3(0, 22, 0));
      DamagePlayer(N, Proj.Transform.Translation);
    end;
  end;
end;

procedure TQuakeWorld.TrapThink(const Proj: TQuakeProjectile);
var
  M, Best: TQuakeMonster;
  TrapQ, Vec, Org: TVector3;
  Len, BestLen, Speed: Single;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
begin
  { Trap_Think (10 Hz, on the ground only) }
  if not Proj.TrapLanded then
    Exit;
  TrapQ := CgeToQuake(Proj.Transform.Translation);
  if Proj.TrapFrame > 4 then
  begin
    { A monster went in: frame 5 while the gibs turn (wait 64 down by 2),
      then 6, 7 and at 8 the food cube }
    if Proj.TrapFrame = 5 then
    begin
      if Proj.TrapWait = 64 then
        Sounds.PlayAtPoint('sound/weapons/trapdown.wav', Proj.Transform.Translation);
      Dec(Proj.TrapWait, 2);
      if Proj.TrapWait < 19 then
        Inc(Proj.TrapFrame);
    end else
    if Proj.TrapFrame < 8 then
    begin
      Inc(Proj.TrapFrame);
      if Proj.TrapFrame = 8 then
      begin
        { SP_item_foodcube: a tenth of the monster's mass in health, from
          24 above the trap; the trap goes 1 s later }
        Org := TrapQ + Vector3(0, 0, 24);
        Ent := TQuakeEntity.Create;
        Ent.SetField('classname', 'item_foodcube');
        Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
        Ent.SetField('count', IntToStr(Max(1, Proj.TrapMass div 10)));
        FBsp.Entities.Add(Ent);
        SpawnEntity(Ent);
        Sounds.PlayAtPoint('sound/misc/fhit3.wav', Proj.Transform.Translation);
        Proj.Life := 1;
        Proj.TrapSucking := False;
        WritelnLog('QuakeWorld', 'Trap made a food cube of %d health', [Max(1, Proj.TrapMass div 10)]);
      end;
    end;
    if Proj.Model <> nil then
      Proj.Model.SetFrame(Min(Proj.TrapFrame, 7));
    Exit;
  end;

  if Proj.TrapFrame < 4 then
  begin
    Inc(Proj.TrapFrame);
    if Proj.Model <> nil then
      Proj.Model.SetFrame(Proj.TrapFrame);
    Exit;
  end;

  { Open (EF_TRAP): the nearest live monster it can see within 256 }
  Best := nil;
  BestLen := 8000;
  for M in FMonsters do
  begin
    if (not M.IsAlive) or M.Dormant or (not M.Transform.Exists) then
      Continue;
    Len := (M.Origin - TrapQ).Length;
    if (Len > 256) or (Len >= BestLen) then
      Continue;
    T := WorldTrace(TrapQ + Vector3(0, 0, 4), MonsterCenter(M), TVector3.Zero, TVector3.Zero, MASK_OPAQUE, nil);
    if T.Hit then
      Continue;
    Best := M;
    BestLen := Len;
  end;
  Proj.TrapSucking := Best <> nil;
  if Best = nil then
    Exit;

  { Pull it in: up to 150 a second, faster the nearer (at least 64) }
  Vec := TrapQ - Best.Origin;
  Len := Vec.Length;
  if Len > 0.001 then
    Vec := Vec / Len;
  Speed := EnsureRange(150 - Len, 64, 150);
  Best.MonsterJump(QuakeToCge(Vector3(Vec.X, Vec.Y, 0)) * Speed, 50);
  if Len < 48 then
  begin
    if MonsterMass(Best.Def^.ClassName) < 400 then
    begin
      WritelnLog('QuakeWorld', 'Trap swallowed %s', [Best.Transform.Name]);
      Proj.TrapMass := MonsterMass(Best.Def^.ClassName);
      Best.TakeDamage(100000);
      Proj.TrapWait := 64;
      Proj.Life := 30;
      Proj.TrapFrame := 5;
      Proj.TrapSucking := False;
      if Proj.Model <> nil then
        Proj.Model.SetFrame(5);
    end else
    begin
      WritelnLog('QuakeWorld', 'Trap: %s is too heavy', [Best.Transform.Name]);
      Proj.Life := 0;
    end;
  end;
end;

procedure TQuakeWorld.ProxThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
const
  { PROX_DAMAGE_RADIUS, PROX_BOUND_SIZE }
  DamageRadius = 192;
  FieldSize = 96;
var
  M: TQuakeMonster;
  Pos: TVector3;
  Mult: Integer;
  Box: TBox3D;
begin
  Pos := Proj.Transform.Translation;
  { prox_open: 10 frames of opening, then armed }
  if Proj.ProxArm > 0 then
  begin
    Proj.ProxArm := Proj.ProxArm - SecondsPassed;
    if Proj.ProxArm > 0 then
      Exit;
    { Armed: a monster in sight within 202 sets it off now; else it lives
      45 s (30, 15, 10 with double, quad or both) }
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and (PointsDistance(M.Transform.Translation, Pos) < DamageRadius + 10) and
         M.HasLineOfSight(Pos) then
      begin
        Proj.ProxTrigger := 0;
        Break;
      end;
    Mult := Max(1, Proj.Damage div 90);
    case Mult of
      1: Proj.ProxFuse := 45;
      2: Proj.ProxFuse := 30;
      4: Proj.ProxFuse := 15;
      else Proj.ProxFuse := 10;
    end;
  end;
  { prox_field_touch: a monster in the 192 box: proxwarn, off 0.5 s later }
  if Proj.ProxTrigger < 0 then
  begin
    Box := Box3D(Pos - Vector3(FieldSize, FieldSize, FieldSize), Pos + Vector3(FieldSize, FieldSize, FieldSize));
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and Box.Collision(M.Transform.BoundingBox) then
      begin
        Proj.ProxTrigger := 0.5;
        Sounds.PlayAt('sound/weapons/proxwarn.wav', Proj.Transform);
        Break;
      end;
  end;
  if Proj.ProxTrigger >= 0 then
    Proj.ProxTrigger := Proj.ProxTrigger - SecondsPassed;
  Proj.ProxFuse := Proj.ProxFuse - SecondsPassed;
  if (Proj.ProxTrigger < 0) and (Proj.ProxTrigger > -0.5) or (Proj.ProxFuse <= 0) then
  begin
    { Prox_Explode: 90 (times the multiplier) within 192 }
    WritelnLog('QuakeWorld', 'Prox mine goes off');
    Explode(Pos, Proj.Damage, DamageRadius, Proj.FromPlayer);
    Proj.Life := 0;
  end;
end;

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single);
var
  I: Integer;
  Proj: TQuakeProjectile;
  OldPos, Dir, NewPos, HitNormal: TVector3;
  StepLen: Single;
  Remove, Damageable: Boolean;
  T: TQuakeTrace;
  Shooter: TObject;
begin
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    Proj := FProjectiles[I];
    Proj.Life := Proj.Life - SecondsPassed;
    Remove := False;
    OldPos := Proj.Transform.Translation;

    if (Proj.Kind in [pkGrenade, pkHandGrenade]) or ((Proj.Kind in [pkTrap, pkTesla]) and not Proj.TrapLanded) or
       ((Proj.Kind = pkProx) and not Proj.ProxStuck) then
      Proj.Velocity.Y := Proj.Velocity.Y - 800 * SecondsPassed;
    if Proj.Sprite <> nil then
      Proj.Sprite.Update(SecondsPassed);

    if Proj.Life <= 0 then
    begin
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
        Explode(OldPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer)
      else
      if Proj.Exploding then
        BfgEffect(Proj)
      else
      if Proj.Kind = pkRipper then
        { ionripper_think: TE_WELDING_SPARKS when its 3 s are up }
        TempEntity(TE_WELDING_SPARKS, OldPos)
      else
      if (Proj.Kind = pkTrap) and (Proj.TrapFrame < 8) then
      begin
        { Trap_Think after 30 s (or a monster too heavy): BecomeExplosion1,
          no damage }
        TempEntity(TE_EXPLOSION1, OldPos);
        WritelnLog('QuakeWorld', 'Trap blew up');
      end;
      FProjectiles.Delete(I);
      Continue;
    end;

    if Proj.Kind = pkTesla then
    begin
      TeslaThink(Proj, SecondsPassed);
      if Proj.Life <= 0 then
      begin
        FProjectiles.Delete(I);
        Continue;
      end;
      if Proj.TrapLanded then
        Continue;
    end;

    if (Proj.Kind = pkProx) and Proj.ProxStuck then
    begin
      ProxThink(Proj, SecondsPassed);
      if Proj.Life <= 0 then
        FProjectiles.Delete(I);
      Continue;
    end;

    if Proj.Kind = pkTrap then
    begin
      Proj.TrapTimer := Proj.TrapTimer - SecondsPassed;
      while Proj.TrapTimer <= 0 do
      begin
        Proj.TrapTimer := Proj.TrapTimer + 0.1;
        TrapThink(Proj);
      end;
      if Proj.TrapLanded then
        Continue;
    end;

    if (Proj.Kind = pkHeatRocket) and (Proj.HeatTurn > 0) then
      SteerHeatRocket(Proj, SecondsPassed);

    if (Proj.Kind = pkBfg) and not Proj.Exploding then
    begin
      Proj.LaserTimer := Proj.LaserTimer - SecondsPassed;
      if Proj.LaserTimer <= 0 then
      begin
        Proj.LaserTimer := Proj.LaserTimer + 0.1;
        BfgLasers(Proj);
      end;
    end;

    StepLen := Proj.Velocity.Length * SecondsPassed;
    if StepLen < 0.001 then
      Continue;
    Dir := Proj.Velocity.Normalize;
    NewPos := OldPos + Dir * StepLen;

    { Quake 2 MOVETYPE_FLYMISSILE / BOUNCE: a point trace along the step,
      ignoring the shooter }
    if Proj.FromPlayer then
      Shooter := FPlayer
    else
      Shooter := Proj.Owner;
    T := WorldTrace(CgeToQuake(OldPos), CgeToQuake(NewPos), TVector3.Zero, TVector3.Zero, MASK_SHOT, Shooter);
    if T.Hit and not T.AllSolid then
    begin
      NewPos := QuakeToCge(T.EndPos);
      HitNormal := QuakeToCge(T.Normal);
      Damageable := (T.Ent is TQuakeMonster) or (T.Ent is TQuakePlayerMovement);
      if (Proj.Kind = pkRipper) and not Damageable then
      begin
        { MOVETYPE_WALLBOUNCE: a perfect reflection off anything that doesn't
          take damage (the sky ends it) }
        if (T.Contents and CONTENTS_SOLID) = 0 then
          Remove := True
        else
        begin
          Proj.Velocity := Proj.Velocity - HitNormal * (2 * TVector3.DotProduct(Proj.Velocity, HitNormal));
          NewPos := NewPos + HitNormal * 0.5;
        end;
      end else
      if Proj.Kind in [pkTrap, pkTesla] then
      begin
        { MOVETYPE_BOUNCE off everything; it stays where it lands }
        Proj.Velocity := Proj.Velocity - HitNormal * (1.5 * TVector3.DotProduct(Proj.Velocity, HitNormal));
        NewPos := NewPos + HitNormal * 0.5;
        if (HitNormal.Y > 0.7) and (Proj.Velocity.Y < 60) then
        begin
          Proj.Velocity := TVector3.Zero;
          Proj.TrapLanded := True;
          Proj.Transform.Rotation := Vector4(0, 1, 0, Random * 2 * Pi);
        end;
      end else
      if Proj.Kind = pkProx then
      begin
        { prox_land: a monster (or the player) sets it off; lava or slime
          too; it sticks to the world and to movers' tops }
        if Damageable or ((T.Contents and (8 or 16)) <> 0) or
           ((T.Ent is TQuakeMover) and (HitNormal.Y <= 0.7)) then
        begin
          Explode(NewPos, Proj.Damage, 192, Proj.FromPlayer);
          Remove := True;
        end else
        if (T.Contents and CONTENTS_SOLID) = 0 then
          Remove := True
        else
        begin
          NewPos := NewPos + HitNormal * 0.5;
          Proj.Velocity := TVector3.Zero;
          Proj.ProxStuck := True;
          Proj.ProxArm := 0.5;
          Proj.ProxFuse := -1;
          Proj.ProxTrigger := -1;
          Sounds.PlayAt('sound/weapons/proxopen.wav', Proj.Transform);
          WritelnLog('QuakeWorld', 'Prox mine stuck at %s', [CgeToQuake(NewPos).ToString]);
        end;
      end else
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
      begin
        if Damageable then
        begin
          Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          Remove := True;
        end else
        begin
          { ClipVelocity with overbounce 1.5; stop on floors when slow }
          Proj.Velocity := Proj.Velocity - HitNormal * (1.5 * TVector3.DotProduct(Proj.Velocity, HitNormal));
          NewPos := NewPos + HitNormal * 0.5;
          if (HitNormal.Y > 0.7) and (Proj.Velocity.Y < 60) then
          begin
            Proj.Velocity := Proj.Velocity * 0.6;
            Proj.Velocity.Y := 0;
          end;
          if Proj.Velocity.Length > 30 then
          begin
            if Proj.Kind = pkHandGrenade then
              Sounds.PlayAt(Format('sound/weapons/hgrenb%da.wav', [1 + Random(2)]), Proj.Transform)
            else
              Sounds.PlayAt('sound/weapons/grenlb1b.wav', Proj.Transform);
          end;
        end;
      end else
      begin
        if T.Ent is TQuakeMonster then
        begin
          TQuakeMonster(T.Ent).TakeDamage(Proj.Damage);
          Particles.SpawnBlood(NewPos, -Dir);
        end else
        if T.Ent is TQuakePlayerMovement then
        begin
          FDamageSource := Proj.Owner;
          if Proj.Kind in [pkBlasterBolt, pkBfg, pkRipper, pkBlueBolt, pkLoogie, pkPlasma] then
            DamagePlayer(Proj.Damage, OldPos);
        end else
        if T.Ent is TQuakeMover then
          DamageMover(TQuakeMover(T.Ent), Proj.Damage)
        else
        if T.Ent is TQuakeProp then
          DamageProp(TQuakeProp(T.Ent), Proj.Damage);
        case Proj.Kind of
          pkRocket, pkHeatRocket: Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          pkPlasma:
            { plasma_touch: the hit, then the splash (TE_PLASMA_EXPLOSION) }
            Explode(NewPos - Dir * 2, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          pkBfg:
            begin
              { bfg_touch: the core blast (T_RadiusDamage 200 within 100), the
                s_bfg3 explosion, then the BFG effect a frame later from
                where the ball was 0.1 s before }
              Particles.SpawnBfgExplosion(NewPos);
              Lighting.AddLight(NewPos, 350, Vector3(0, 1, 0), 0.5);
              Sounds.PlayAtPoint('sound/weapons/bfg__x1b.wav', NewPos);
              Explode(NewPos, 200, 100, Proj.FromPlayer, False);
              Proj.Exploding := True;
              Proj.Life := 0.1;
              NewPos := NewPos - Proj.Velocity * 0.1;
              Proj.Velocity := TVector3.Zero;
              Proj.Transform.Exists := False;
            end;
          { flechette_touch: TE_FLECHETTE on walls }
          pkFlechette:
            if not Damageable then
              Particles.SpawnImpact(NewPos - Dir * 2, -Dir);
          else
            begin
              Particles.SpawnBlasterImpact(NewPos - Dir * 2, -Dir);
              Sounds.PlayAtPoint('sound/weapons/lashit.wav', NewPos);
            end;
        end;
        { an exploding BFG ball stays until its effect went off }
        Remove := not Proj.Exploding;
      end;
    end;

    if Remove then
      FProjectiles.Delete(I)
    else
      Proj.Transform.Translation := NewPos;
  end;
end;

function TQuakeWorld.MonsterRail(const Monster: TQuakeMonster; const Eye, Target: TVector3): Boolean;
var
  Start, Stop: TVector3;
  Ignore: TObject;
  T: TQuakeTrace;
  I: Integer;
begin
  { fire_rail: on through monsters to the first wall }
  Result := False;
  Start := CgeToQuake(Eye);
  Stop := Start + (CgeToQuake(Target) - Start).Normalize * 8192;
  Ignore := Monster;
  Sounds.PlayAt('sound/weapons/railgf1a.wav', Monster.Transform, 1, 1, chWeapon);
  for I := 0 to 8 do
  begin
    T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    if not T.Hit then
      Break;
    if T.Ent is TQuakePlayerMovement then
    begin
      DamagePlayer(Monster.AttackDamage, Eye);
      Result := True;
    end else
    if T.Ent is TQuakeMonster then
      TQuakeMonster(T.Ent).TakeDamage(Monster.AttackDamage)
    else
      Break;
    Ignore := T.Ent;
    Start := T.EndPos;
  end;
  Particles.SpawnRailTrail(Eye, QuakeToCge(T.EndPos));
end;

procedure TQuakeWorld.UpdateBossExplosions;
const
  { BossExplode: where explosions 0..7 go around the body (x, y offsets) }
  Offsets: array[0..7, 0..1] of Integer = ((-24, -24), (24, 24), (24, -24), (-24, 24),
    (-48, -48), (48, 48), (-48, 48), (48, -48));
var
  M: TQuakeMonster;
  I, K: Integer;
  Org: TVector3;
  Pieces: array[0..3] of TGibPiece;
  Known: Boolean;
begin
  { The supertank, the hornet and Jorg: when their death animation ends,
    BossExplode (supertank_dead / boss2_die / jorg_dead) }
  for M in FMonsters do
    if (M.State = msDead) and (not M.Gibbed) and M.Transform.Exists and
       ((M.Def^.ClassName = 'monster_supertank') or (M.Def^.ClassName = 'monster_boss2') or
        (M.Def^.ClassName = 'monster_jorg') or (M.Def^.ClassName = 'monster_boss5') or
        { Ground Zero: carrier_dead, widow2's death explosions }
        (M.Def^.ClassName = 'monster_carrier') or (M.Def^.ClassName = 'monster_widow2')) then
    begin
      Known := False;
      for K := 0 to High(FBossExplosions) do
        if FBossExplosions[K].Monster = M then
          Known := True;
      if not Known then
      begin
        SetLength(FBossExplosions, Length(FBossExplosions) + 1);
        FBossExplosions[High(FBossExplosions)].Monster := M;
        FBossExplosions[High(FBossExplosions)].Count := 0;
        FBossExplosions[High(FBossExplosions)].Next := FTime;
        WritelnLog('QuakeWorld', '%s explodes (BossExplode)', [M.Transform.Name]);
      end;
    end;

  for I := High(FBossExplosions) downto 0 do
  begin
    M := FBossExplosions[I].Monster;
    if FMonsters.IndexOf(M) < 0 then
    begin
      Delete(FBossExplosions, I, 1);
      Continue;
    end;
    while (FBossExplosions[I].Count < 8) and (FTime >= FBossExplosions[I].Next) do
    begin
      { A TE_EXPLOSION1 24..39 above the origin, around it, every 0.1 s }
      Org := M.Origin + Vector3(Offsets[FBossExplosions[I].Count, 0], Offsets[FBossExplosions[I].Count, 1],
        24 + Random(16));
      TempEntity(TE_EXPLOSION1, QuakeToCge(Org));
      Inc(FBossExplosions[I].Count);
      FBossExplosions[I].Next := FBossExplosions[I].Next + 0.1;
    end;
    if (FBossExplosions[I].Count >= 8) and (FTime >= FBossExplosions[I].Next) then
    begin
      { Then 4 meat, 8 metal, the chest and a gear (the head); the body is gone }
      Pieces[0].Model := 'models/objects/gibs/sm_meat/tris.md2';
      Pieces[0].Count := 4;
      Pieces[0].Metallic := False;
      Pieces[1].Model := 'models/objects/gibs/sm_metal/tris.md2';
      Pieces[1].Count := 8;
      Pieces[1].Metallic := True;
      Pieces[2].Model := 'models/objects/gibs/chest/tris.md2';
      Pieces[2].Count := 1;
      Pieces[2].Metallic := False;
      Pieces[3].Model := 'models/objects/gibs/gear/tris.md2';
      Pieces[3].Count := 1;
      Pieces[3].Metallic := True;
      Particles.ThrowGibs(QuakeToCge(M.Origin + M.BoxMins), QuakeToCge(M.Origin + M.BoxMaxs), Pieces, 500);
      WritelnLog('QuakeWorld', '%s blew up: 8 explosions, 14 gibs', [M.Transform.Name]);
      M.Gibbed := True;
      M.Transform.Exists := False;
      Delete(FBossExplosions, I, 1);
    end;
  end;
end;

procedure TQuakeWorld.UpdateBossesAndLeaps;
var
  M: TQuakeMonster;
  I: Integer;
  Ent: TQuakeEntity;
  Org: TVector3;
  Makron: TQuakeMonster;
  ToPlayer: TVector3;
begin
  { mutant_jump_touch: 40 .. 49 when it hits the player faster than 400 }
  for M in FMonsters do
    if M.LeapDamage > 0 then
    begin
      if not M.Jumping then
        M.LeapDamage := 0
      else
      if (M.JumpSpeed > 400) and not FDead and
         (Abs(M.Transform.Translation.X - FPlayerPos.X) < 16 + M.BoxMaxs.X + 4) and
         (Abs(M.Transform.Translation.Z - FPlayerPos.Z) < 16 + M.BoxMaxs.Y + 4) and
         (Abs(M.Transform.Translation.Y - (FPlayerPos.Y - 22)) < 64) then
      begin
        DamagePlayer(M.LeapDamage, M.Transform.Translation);
        M.LeapDamage := 0;
      end;
    end;

  UpdateBossExplosions;
  UpdateWidows;

  { MakronSpawn: a monster_makron where Jorg died, jumping at the player
    (400 toward him, 200 up) }
  for I := High(FMakronTosses) downto 0 do
    if FTime >= FMakronTosses[I].Time then
    begin
      Org := CgeToQuake(FMakronTosses[I].Pos);
      Ent := TQuakeEntity.Create;
      Ent.SetField('classname', 'monster_makron');
      Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
      Ent.SetField('angle', IntToStr(Round(FMakronTosses[I].Yaw)));
      if FMakronTosses[I].Target <> '' then
        Ent.SetField('target', FMakronTosses[I].Target);
      Delete(FMakronTosses, I, 1);
      FBsp.Entities.Add(Ent);
      Makron := nil;
      if FMonsters.Count > 0 then
        Makron := FMonsters.Last;
      SpawnEntity(Ent);
      if (FMonsters.Count > 0) and (FMonsters.Last <> Makron) then
      begin
        Makron := FMonsters.Last;
        ToPlayer := FPlayerPos - Makron.Transform.Translation;
        ToPlayer.Y := 0;
        if not ToPlayer.IsZero then
          Makron.MonsterJump(ToPlayer.Normalize * 400, 200);
        Makron.Alert;
        WritelnLog('QuakeWorld', 'The Makron comes out: %s', [Makron.Transform.Name]);
      end;
    end;
end;

procedure TQuakeWorld.MonsterAttack(const Monster: TQuakeMonster);
var
  Eye, Target, Dir: TVector3;
  Dist, Accuracy: Single;
  I, Hits: Integer;
begin
  if FDead then
    Exit;
  Inc(FMonsterShots);
  FDamageSource := Monster;
  Eye := Monster.EyePos;
  Target := FPlayerPos - Vector3(0, 12, 0);
  { A turret's blind shot: at the spot the player was last seen }
  if Monster.BlindFire then
    Target := Monster.BlindAim;
  if Monster.AngerActive then
  begin
    { target_anger: shooting at a spot; hitscans make impacts there,
      projectiles fly to it, nothing reaches the player }
    Target := Monster.AngerPos;
    Dir := (Target - Eye).Normalize;
    if Monster.AttackKind in [akMelee, akLeap, akLaser] then
      Exit;
    if Monster.AttackKind in [akHitscan, akPellets, akRail] then
    begin
      Lighting.TriggerMuzzleFlash(Eye);
      if Monster.AttackKind = akRail then
        Particles.SpawnRailTrail(Eye, Target)
      else
        Particles.SpawnImpact(Target + Vector3((Random - 0.5) * 24, (Random - 0.5) * 24,
          (Random - 0.5) * 24), -Dir);
      Exit;
    end;
  end;
  Dir := (Target - Eye).Normalize;
  Dist := PointsDistance(Eye, Target);
  if not (Monster.AttackKind in [akMelee, akLeap]) then
    Lighting.TriggerMuzzleFlash(Eye);

  { Monster.AttackKind / AttackDamage / AttackBullets: the shot of its
    attack sequence (or of the generic attack) }
  { MakronHyperblaster sweeps across: the shot turned by AttackYaw }
  if Monster.AttackYaw <> 0 then
    Dir := RotatePointAroundAxisRad(DegToRad(Monster.AttackYaw), Dir, Vector3(0, 1, 0));
  { Shots aimed at a saved position (gladiator / Makron railgun) }
  if Monster.AimSaved and (Monster.AttackKind = akRail) then
  begin
    MonsterRail(Monster, Eye, Monster.SavedAim);
    Exit;
  end;

  case Monster.AttackKind of
    akMelee:
      if Dist < Monster.AttackReach then
      begin
        DamagePlayer(Monster.AttackDamage, Eye);
        { fire_hit's kick: push (or pull) the player }
        if (Monster.AttackKick <> 0) and (FPlayer <> nil) then
          FPlayer.AddVelocity(Dir * Monster.AttackKick);
      end;
    akLeap:
      Monster.Leap;
    akBfg:
      begin
        { monster_fire_bfg: speed 300, its own damage and radius for the
          BFG effect; the core hit stays bfg_touch's 200 }
        SpawnProjectile(pkBfg, Eye + Dir * 24, Dir, 300, 200, False, Monster);
        FProjectiles.Last.SplashDamage := Monster.AttackDamage;
        FProjectiles.Last.SplashRadius := Monster.AttackRadius;
      end;
    akHitscan, akPellets, akRail:
      if Monster.CanSeePlayer then
      begin
        { Accuracy falls off with distance }
        Accuracy := EnsureRange(1.1 - Dist / 1200, 0.25, 0.95);
        if Monster.AttackKind = akPellets then
        begin
          Hits := 0;
          { 9 pellets (Quake 2 shotgun soldiers) or the shot's own count
            (Quake 1's grunt: 4) }
          for I := 1 to Max(Monster.AttackBullets, 9 * Ord(Monster.AttackBullets <= 1)) do
            if Random < Accuracy * 0.8 then
              Inc(Hits);
          if Hits > 0 then
            DamagePlayer(Hits * Monster.AttackDamage, Eye);
        end else
        if Monster.AttackKind = akRail then
        begin
          Particles.SpawnRailTrail(Eye, Target);
          Sounds.PlayAt('sound/weapons/railgf1a.wav', Monster.Transform, 1, 1, chWeapon);
          if Random < Accuracy then
            DamagePlayer(Monster.AttackDamage, Eye);
        end else
        begin
          for I := 1 to Monster.AttackBullets do
            if Random < Accuracy * 0.6 then
              DamagePlayer(Monster.AttackDamage, Eye);
          Particles.SpawnImpact(Target + Vector3((Random - 0.5) * 40, (Random - 0.5) * 30,
            (Random - 0.5) * 40), -Dir);
        end;
      end;
    akBlaster:
      if Monster.AttackSpeed > 0 then
        SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, Monster.AttackSpeed, Monster.AttackDamage, False, Monster)
      else
        SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, 600, Monster.AttackDamage, False, Monster);
    akRocket:
      { Volleys (the hornet's four rockets) leave from side by side muzzles }
      for I := 0 to Max(1, Monster.AttackBullets) - 1 do
        SpawnProjectile(pkRocket, Eye + Dir * 24 +
          TVector3.CrossProduct(Dir, Vector3(0, 1, 0)).Normalize * (16 * (I - (Monster.AttackBullets - 1) / 2)),
          Dir, 500, Monster.AttackDamage, False, Monster);
    akGrenade:
      SpawnProjectile(pkGrenade, Eye + Dir * 24, (Dir + Vector3(0, 0.35, 0)).Normalize,
        Min(600, Dist * 1.1), Monster.AttackDamage, False, Monster);
    akRipper, akBlueBlaster, akLoogie, akHeatRocket, akPlasma:
      XatrixMonsterShot(Monster, Eye, Dir);
    akSummon:
      if Monster.Def^.ClassName = 'monster_medic_commander' then
        MedicSummon(Monster)
      else
        BossSummon(Monster);
    akHeatBeam:
      HeatBeam(Monster, Eye, Target);
    akLaser:
      begin
        { The laser soldier's beam (dabeam): 1 to the player each frame it
          holds, unless a wall is in the way; it re-aims with a little lag }
        Target := Target + Vector3((Random - 0.5) * 16, (Random - 0.5) * 16, (Random - 0.5) * 16);
        if WorldTrace(CgeToQuake(Eye), CgeToQuake(Target), TVector3.Zero, TVector3.Zero,
           CONTENTS_SOLID or CONTENTS_WINDOW, Monster).Fraction >= 1 then
        begin
          DamagePlayer(Monster.AttackDamage, Eye);
          Particles.SpawnBeam(Eye, Target, Vector3(1.0, 0.15, 0.1));
        end;
      end;
  end;
end;

procedure TQuakeWorld.SteerHeatRocket(const Proj: TQuakeProjectile; const SecondsPassed: Single);
var
  Pos, ToTarget, Dir: TVector3;
  Speed, F: Single;
begin
  { heat_think: towards the player when he is alive, in sight and within
    1024 (the only client here), every 0.025 s by HeatTurn of the way:
    over SecondsPassed that is 1 - (1 - HeatTurn) ^ (SecondsPassed / 0.025) }
  if FDead then
    Exit;
  Pos := Proj.Transform.Translation;
  ToTarget := (FPlayerPos - Vector3(0, 12, 0)) - Pos;
  if (ToTarget.Length > 1024) or (ToTarget.Length < 1) or
     (WorldTrace(CgeToQuake(Pos), CgeToQuake(FPlayerPos), TVector3.Zero, TVector3.Zero,
      CONTENTS_SOLID or CONTENTS_WINDOW, nil).Fraction < 1) then
    Exit;
  Speed := Proj.Velocity.Length;
  if Speed < 1 then
    Exit;
  F := 1 - Power(1 - Proj.HeatTurn, SecondsPassed / 0.025);
  Dir := Proj.Velocity / Speed;
  Dir := (Dir + (ToTarget.Normalize - Dir) * F).Normalize;
  Proj.Velocity := Dir * Speed;
end;

procedure TQuakeWorld.XatrixMonsterShot(const Monster: TQuakeMonster; const Eye, Dir: TVector3);
var
  Kind: TProjectileKind;
  Speed: Single;
  Sound: String;
  Proj: TQuakeProjectile;
begin
  { The Reckoning's monster projectiles: monster_fire_ionripper (600),
    monster_fire_blueblaster (600), the gekk's loogie (550), fire_heat (the
    heat chick 500, turning 0.15; boss5 500, 0.075), fire_plasma (725) }
  Sound := '';
  case Monster.AttackKind of
    akRipper:
      begin
        Kind := pkRipper;
        Speed := 600;
        Sound := 'sound/weapons/rippfire.wav';
      end;
    akBlueBlaster:
      begin
        Kind := pkBlueBolt;
        Speed := 600;
        Sound := 'sound/weapons/hyprbf1a.wav';
      end;
    akLoogie:
      begin
        Kind := pkLoogie;
        Speed := 550;
      end;
    akHeatRocket:
      begin
        Kind := pkHeatRocket;
        Speed := 500;
      end;
  else
    Kind := pkPlasma;
    Speed := 725;
    Sound := 'sound/weapons/plasshot.wav';
  end;
  if Monster.AttackSpeed > 0 then
    Speed := Monster.AttackSpeed;
  if Sound <> '' then
    Sounds.PlayAt(Sound, Monster.Transform, 1, 1, chWeapon);
  SpawnProjectile(Kind, Eye + Dir * 20, Dir, Speed, Monster.AttackDamage, False, Monster);
  Proj := FProjectiles.Last;
  case Kind of
    pkHeatRocket:
      begin
        Proj.SplashDamage := Monster.AttackDamage;
        Proj.SplashRadius := 50;
        if Monster.Def^.ClassName = 'monster_chick_heat' then
          Proj.HeatTurn := 0.15
        else
          Proj.HeatTurn := 0.075;
      end;
    pkPlasma:
      begin
        { gladb: 35 on a hit and 45 within 45 (17 / 22 for the second ball) }
        Proj.SplashDamage := Round(Monster.AttackDamage * 9 / 7);
        Proj.SplashRadius := Max(1, Monster.AttackRadius);
      end;
  end;
end;

function TQuakeWorld.AbsorbPlayerPowerArmor(const Damage: Integer; const FromPos: TVector3): Integer;
var
  Forward, ToHit: TVector3;
  DamagePerCell, Part, Cells: Integer;
begin
  { Quake 2 CheckPowerArmor for a client: the shield if carried, else the
    screen, which only stops hits from the front; cells pay for it }
  Result := 0;
  Cells := FStats.Ammo[atCells];
  if not FStats.PowerArmorOn or (Cells <= 0) or (Damage <= 0) then
    Exit;
  if FStats.PowerShields > 0 then
  begin
    DamagePerCell := 2;
    Part := (2 * Damage) div 3;
  end else
  if FStats.PowerScreens > 0 then
  begin
    Forward := Vector3(FPlayerDir.X, 0, FPlayerDir.Z);
    ToHit := FromPos - FPlayerPos;
    ToHit.Y := 0;
    if Forward.IsZero or ToHit.IsZero or
       (TVector3.DotProduct(ToHit.Normalize, Forward.Normalize) <= 0.3) then
      Exit;
    DamagePerCell := 1;
    Part := Damage div 3;
  end else
    Exit;
  Result := Min(Cells * DamagePerCell, Part);
  if Result <= 0 then
    Exit;
  FStats.Ammo[atCells] := Max(0, Cells - Result div DamagePerCell);
  { TE_SCREEN_SPARKS / TE_SHIELD_SPARKS }
  Sounds.Play('sound/weapons/lashit.wav', 1, chAuto);
end;

procedure TQuakeWorld.TogglePowerArmor;
begin
  if (FStats.PowerScreens = 0) and (FStats.PowerShields = 0) then
    Exit;
  if FStats.PowerArmorOn then
  begin
    FStats.PowerArmorOn := False;
    Sounds.Play('sound/misc/power2.wav', 1, chAuto);
  end else
  if FStats.Ammo[atCells] <= 0 then
  begin
    if FHud <> nil then
      FHud.ShowMessage('No cells for power armor.', 2);
  end else
  begin
    FStats.PowerArmorOn := True;
    Sounds.Play('sound/misc/power1.wav', 1, chAuto);
  end;
end;

procedure TQuakeWorld.DamagePlayer(const Amount: Integer; const FromPos: TVector3;
  const NoArmor: Boolean);
var
  Save, Take: Integer;
begin
  { The defender sphere goes after whoever hurt the player (defender_pain) }
  if (FStats.DefenderTime > 0) and (FDamageSource <> nil) and FDamageSource.IsAlive then
    FDefenderEnemy := FDamageSource;
  if FDead or FStats.GodMode or (FStats.InvulnTime > 0) or (Amount <= 0) then
    Exit;
  Take := Amount;
  { T_Damage: half damage while a defender sphere is out }
  if FStats.DefenderTime > 0 then
    Take := Max(1, Take div 2);
  { Quake 2 T_Damage: half damage on easy }
  if GameSkill = 0 then
    Take := Max(1, Take div 2);
  { Power armor first, then armor (T_Damage: CheckPowerArmor, CheckArmor) }
  if not NoArmor then
    Take := Take - AbsorbPlayerPowerArmor(Take, FromPos);
  if (not NoArmor) and (FStats.Armor > 0) and (FStats.ArmorType > 0) then
  begin
    Save := Min(FStats.Armor, Ceil(ArmorProtection[FStats.ArmorType] * Take));
    FStats.Armor := FStats.Armor - Save;
    Take := Take - Save;
    if FStats.Armor <= 0 then
      FStats.ArmorType := 0;
  end;
  FStats.Health := FStats.Health - Take;
  if FHud <> nil then
    FHud.FlashDamage(Amount);
  if FPlayer <> nil then
    FPlayer.DamageKick(Amount, FromPos, FStats.Health);

  if FStats.Health <= 0 then
  begin
    FKillerPos := FromPos;
    FHasKiller := PointsDistance(FromPos, FPlayerPos) > 1;
    KillPlayer;
    Exit;
  end;

  if FPainSoundTimer <= 0 then
  begin
    FPainSoundTimer := 0.7;
    if FStats.Health < 25 then
      Sounds.Play('sound/player/male/pain25_1.wav', 1, chVoice)
    else
    if FStats.Health < 50 then
      Sounds.Play('sound/player/male/pain50_1.wav', 1, chVoice)
    else
    if FStats.Health < 75 then
      Sounds.Play('sound/player/male/pain75_1.wav', 1, chVoice)
    else
      Sounds.Play('sound/player/male/pain100_1.wav', 1, chVoice);
  end;
end;

procedure TQuakeWorld.KillPlayer;
var
  Pieces: array[0..0] of TGibPiece;
  Org: TVector3;
begin
  FDead := True;
  FDeadTimer := 3.0;
  { player_die: below -40 health the body is gibbed (4 meat + the head the
    view stays in), else the death sound }
  FPlayerGibbed := FStats.Health < -40;
  if FPlayerGibbed then
  begin
    Sounds.Play('sound/misc/udeath.wav', 1, chBody);
    Pieces[0].Model := 'models/objects/gibs/sm_meat/tris.md2';
    Pieces[0].Count := 4;
    Pieces[0].Metallic := False;
    Org := FPlayerPos - Vector3(0, PlayerEyeHeight - 24, 0);
    Particles.ThrowGibs(Org + Vector3(-16, -24, -16), Org + Vector3(16, 32, 16), Pieces, -FStats.Health);
    WritelnLog('QuakeWorld', 'Player gibbed (health %d)', [FStats.Health]);
  end else
  begin
    Sounds.Play('sound/player/male/death' + IntToStr(1 + Random(4)) + '.wav', 1, chVoice);
    WritelnLog('QuakeWorld', 'Player died (health %d)', [FStats.Health]);
  end;
  FStats.Health := Min(FStats.Health, 0);
  { ps.gunindex = 0: no view weapon while dead }
  if FWeaponTransform <> nil then
    FWeaponTransform.Exists := False;
  if FHud <> nil then
    FHud.ShowMessage('You died. Restarting level...', 3);
end;

function TQuakeWorld.KillerPosition(out Pos: TVector3): Boolean;
begin
  Pos := FKillerPos;
  Result := FDead and FHasKiller;
end;

procedure TQuakeWorld.Suicide;
begin
  if FDead then
    Exit;
  FStats.Health := 0;
  FHasKiller := False;
  KillPlayer;
end;

procedure TQuakeWorld.Update(const SecondsPassed: Single; const PlayerPos, PlayerDir: TVector3);
var
  I: Integer;
  M: TQuakeMonster;
  D: TDelayedTarget;
  Kick: Single;
  Shell: TVector3;
  A: TAmmoType;
begin
  if FBsp = nil then
    Exit;
  FPlayerPos := PlayerPos;
  FPlayerDir := PlayerDir;
  PlayerShowHostile := (FLastFireTime > 0) and (FTime - FLastFireTime < 1);
  UpdatePlayerTrail(SecondsPassed);
  FTime := FTime + SecondsPassed;
  FStats.LevelTime := FStats.LevelTime + SecondsPassed;
  FStats.QuadTime := Max(0, FStats.QuadTime - SecondsPassed);
  FStats.InvulnTime := Max(0, FStats.InvulnTime - SecondsPassed);
  { DualFire: quadfire2.wav as it starts to fade (3 s left) }
  if (FStats.QuadFireTime > 3) and (FStats.QuadFireTime - SecondsPassed <= 3) then
    Sounds.Play('sound/items/quadfire2.wav', 1, chItem);
  FStats.QuadFireTime := Max(0, FStats.QuadFireTime - SecondsPassed);
  FGun.Haste := FStats.QuadFireTime > 0;
  { Double damage: ddamage2.wav 3 s before it ends }
  if (FStats.DoubleTime > 3) and (FStats.DoubleTime - SecondsPassed <= 3) then
    Sounds.Play('sound/misc/ddamage2.wav', 1, chItem);
  FStats.DoubleTime := Max(0, FStats.DoubleTime - SecondsPassed);
  FStats.IRTime := Max(0, FStats.IRTime - SecondsPassed);
  IRGogglesOn := FStats.IRTime > 0;
  UpdatePlayerItems(SecondsPassed);
  UpdateDefender(SecondsPassed);
  FPainSoundTimer := FPainSoundTimer - SecondsPassed;
  { Projectile lights of the previous frame }
  Lighting.EndFrame;
  UpdateDynamicLights;

  if FDead then
  begin
    FDeadTimer := FDeadTimer - SecondsPassed;
    if FDeadTimer <= 0 then
    begin
      FRestartPending := True;
      ResetStats;
    end;
  end;

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
    FPickups[I].UpdatePickup(SecondsPassed);
  if not FDead then
  begin
    CheckPickups;
    CheckTriggers(SecondsPassed);
    CheckMovers;
  end;

  { Player-clip brushes only block the player (Quake 2 MASK_MONSTERSOLID) }
  FGeometry.ScenePlayerClip.Collides := False;
  for M in FMonsters do
  begin
    if M.AngerActive then
      M.UpdateAI(SecondsPassed, M.AngerPos)
    else
      M.UpdateAI(SecondsPassed, FPlayerPos);
    if (not M.IsAlive) and not M.KillCounted then
    begin
      M.KillCounted := True;
      if not (M.GoodGuy or M.DoNotCount) then
        Inc(FStats.Kills);
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
  UpdateLiquids(SecondsPassed);
  UpdateGun(SecondsPassed);
  UpdateProjectiles(SecondsPassed);
  UpdateFallingProps(SecondsPassed);
  UpdateFallingObjects(SecondsPassed);
  UpdateClocks;
  UpdateMedics(SecondsPassed);
  FMap.UpdateSkyRotation(FStats.LevelTime);
  UpdateEarthquakes;
  AddProjectileLights;
  Lighting.Update(SecondsPassed);
  SetSurfaceLights;

  { View weapon: gun frames, kick and lighting }
  FWeaponKick := Max(0, FWeaponKick - SecondsPassed * 6);
  if FWeaponModel <> nil then
  begin
    FWeaponModel.ShowFrames(FGun.OldFrame, FGun.Frame, FGun.FrameLerp);
    FWeaponModel.SetTint(Lighting.SampleLight(FPlayerPos - Vector3(0, 20, 0)));
    { Powerup shells: quad RF_SHELL_BLUE, invulnerability RF_SHELL_RED;
      they blink in the last 3 seconds, like the Quake 2 HUD icons }
    Shell := TVector3.Zero;
    if (FStats.QuadTime > 3) or ((FStats.QuadTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(0, 0, 1)
    else
    { EF_DOUBLE: a gold shell }
    if (FStats.DoubleTime > 3) or ((FStats.DoubleTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(0.6, 0.45, 0);
    if (FStats.InvulnTime > 3) or ((FStats.InvulnTime > 0) and (Frac(FTime * 4) < 0.5)) then
      Shell := Shell + Vector3(1, 0, 0);
    FWeaponModel.SetShell(Shell);
  end;
  Kick := FWeaponKick;
  FWeaponTransform.Translation := Vector3(0, -Kick * 1.0, Kick * 3.0);

  { Inventory to HUD }
  FKeyIcons.Clear;
  for I := 0 to High(KeyIconNames) do
    if (FStats.Keys and (1 shl I)) <> 0 then
      FKeyIcons.Add(KeyIconNames[I]);
  A := WeaponDefs[FStats.CurrentWeapon].AmmoType;
  if FHud <> nil then
    FHud.Update(SecondsPassed, FStats, WeaponDefs[FStats.CurrentWeapon].Icon, AmmoIcons[A], FKeyIcons);
end;

procedure TQuakeWorld.UpdateFrame(const SecondsPassed: Single);
begin
  if FBsp = nil then
    Exit;
  FGeometry.Update(SecondsPassed);
  Particles.Update(SecondsPassed);
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

function TQuakeWorld.ChainedWeapon(const Slot: Integer): Integer;
var
  Chain: array of Integer;
  I, Cur: Integer;

  function Owned(const S: Integer): Boolean;
  begin
    Result := (FStats.WeaponMask and (1 shl S)) <> 0;
  end;

begin
  { The items' chains (the blaster and the chainfist, the machinegun and
    the ETF rifle, the grenade launcher and the prox launcher, the
    hyperblaster, ion ripper and plasma beam, the railgun and the phalanx,
    grenades and traps): with one of the chain up, the key picks the next
    owned one; otherwise the first owned one }
  case Slot of
    1: Chain := [1, ChainfistSlot];
    4: Chain := [4, EtfRifleSlot];
    6: Chain := [6, ProxLauncherSlot];
    8: Chain := [8, IonRipperSlot, PlasmaBeamSlot];
    9: Chain := [9, PhalanxSlot];
    HandGrenadeSlot: Chain := [HandGrenadeSlot, TrapSlot, TeslaSlot];
    else Exit(Slot);
  end;
  Result := Slot;
  Cur := -1;
  for I := 0 to High(Chain) do
    if Chain[I] = FStats.CurrentWeapon then
      Cur := I;
  if Cur >= 0 then
  begin
    for I := 1 to High(Chain) do
      if Owned(Chain[(Cur + I) mod Length(Chain)]) then
        Exit(Chain[(Cur + I) mod Length(Chain)]);
    Exit(FStats.CurrentWeapon);
  end;
  for I := 0 to High(Chain) do
    if Owned(Chain[I]) then
      Exit(Chain[I]);
end;

procedure TQuakeWorld.SelectWeapon(const Slot: Integer);
begin
  if (Slot < 1) or (Slot > WeaponSlots) or ((FStats.WeaponMask and (1 shl Slot)) = 0) then
    Exit;
  if Slot = FStats.CurrentWeapon then
    Exit;
  { Put the current weapon away, then raise this one (Quake 2 newweapon) }
  FGun.Select(Slot);
end;

procedure TQuakeWorld.FireWeapon(const Origin, Dir: TVector3);
begin
  FPlayerPos := Origin;
  FPlayerDir := Dir;
  if (FBsp = nil) or FDead then
    Exit;
  { A new press is latched (a short tap still fires) and thinks at once }
  if not FFireHeld and not FPrevFireHeld then
    FGun.AttackLatched := True;
  FFireHeld := True;
  FGun.Attack := True;
  FGun.Update(0);
  FGun.Attack := False;
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

procedure TQuakeWorld.FireGun;
var
  Def: TQuakeWeaponDef;
  I, Mult, Slot, Shots: Integer;
  Origin, Dir, MuzzlePos, Right, Up: TVector3;
  Angle: Single;
begin
  Origin := FPlayerPos;
  Dir := FPlayerDir;
  Slot := FGun.Slot;
  Def := WeaponDefs[Slot];
  Shots := 1;
  if Slot = 5 then
    Shots := FGun.Shots;
  { weapon_phalanx_fire: one mag slug for both balls, taken on frame 8 }
  if (Slot = PhalanxSlot) and (FGun.Frame <> 8) then
    Shots := 0;
  if Def.AmmoType <> atNone then
    FStats.Ammo[Def.AmmoType] := Max(0, FStats.Ammo[Def.AmmoType] - Def.AmmoPerShot * Shots);

  FWeaponKick := 1.0;
  Mult := DamageMultiplier;
  MuzzlePos := Origin + Dir * 16;
  if Slot <> 10 then { the BFG flashed on frame 9 }
  begin
    Lighting.TriggerMuzzleFlash(MuzzlePos);
    { MZ_SILENCED: the muzzle flash sound at 0.2 volume }
    if Slot in [4, 5] then
      Sounds.Play(Format('sound/weapons/machgf%db.wav', [1 + Random(5)]), SilencedVolume, chWeapon)
    else
      Sounds.Play(Def.Sound, SilencedVolume, chWeapon);
  end;
  if Mult = 2 then
    Sounds.Play('sound/misc/ddamage3.wav', 1, chItem)
  else
  if Mult > 1 then
    Sounds.Play('sound/items/damage3.wav', 1, chItem);

  { Firing makes noise (PNOISE_WEAPON) and shows the player hostile }
  FLastFireTime := FTime;
  WeaponNoise;

  case Slot of
    1: SpawnProjectile(pkBlasterBolt, MuzzlePos, Dir, 1000, 15 * Mult, True);
    2: for I := 1 to 12 do
         FireHitscan(Origin, Dir, 4 * Mult, 500, 500);
    3: for I := 1 to 20 do
         FireHitscan(Origin, Dir, 6 * Mult, 1000, 500);
    4: FireHitscan(Origin, Dir, 8 * Mult, 300, 500);
    { Chaingun_Fire: 1, then 2, then 3 bullets a frame as it spins up }
    5: for I := 1 to Shots do
         FireHitscan(Origin, Dir, 6 * Mult, 300, 500);
    6: SpawnProjectile(pkGrenade, MuzzlePos, (Dir + Vector3(0, 0.15, 0)).Normalize, 600, 120 * Mult, True);
    7: SpawnProjectile(pkRocket, MuzzlePos, Dir, 650, 100 * Mult, True);
    8:
      begin
        { Weapon_HyperBlaster_Fire: the bolt origin circles the muzzle }
        Angle := (FGun.Frame - 5) * 2 * Pi / 6;
        Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
        if Right.IsZero then
          Right := Vector3(1, 0, 0);
        Right := Right.Normalize;
        Up := TVector3.CrossProduct(Right, Dir).Normalize;
        SpawnProjectile(pkBlasterBolt, MuzzlePos - Dir * (4 * Sin(Angle)) + Up * (4 * Cos(Angle)),
          Dir, 1000, 15 * Mult, True);
      end;
    9: FireHitscan(Origin, Dir, 100 * Mult, 0, 0, True);
    10: SpawnProjectile(pkBfg, MuzzlePos, Dir, 400, 200 * Mult, True);
    { weapon_ionripper_fire: 50, speed 500, the yaw off by up to a degree }
    IonRipperSlot:
      SpawnProjectile(pkRipper, MuzzlePos, YawTurned(Dir, Random * 2 - 1), 500, 50 * Mult, True);
    { weapon_phalanx_fire: 70..79 at 725, 1.5 degrees to the left on frame
      7 with a 120 splash, to the right on frame 8 with 30 (radius 120) }
    ChainfistSlot:
      ChainfistHit(Origin, Dir, 15 * Mult);
    { weapon_etf_rifle_fire: flechettes of 10 at 750 from the right barrel
      on frame 6, the left on 7 }
    EtfRifleSlot:
      begin
        Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
        if Right.IsZero then
          Right := Vector3(1, 0, 0);
        Right := Right.Normalize;
        if FGun.Frame = 7 then
          SpawnProjectile(pkFlechette, Origin + Dir * 15 + Right * 8 - Vector3(0, 8, 0), Dir, 750, 10 * Mult, True)
        else
          SpawnProjectile(pkFlechette, Origin + Dir * 15 + Right * 6 - Vector3(0, 8, 0), Dir, 750, 10 * Mult, True);
      end;
    { weapon_grenadelauncher_fire with prox: 600 ahead, 200 up }
    ProxLauncherSlot:
      begin
        Right := Dir * 600 + Vector3(0, 200 + Random * 10, 0);
        SpawnProjectile(pkProx, MuzzlePos, Right.Normalize, Right.Length, 90 * Mult, True);
      end;
    PlasmaBeamSlot:
      PlasmaBeam(Origin, Dir, 15 * Mult);
    PhalanxSlot:
      begin
        if FGun.Frame = 8 then
          SpawnProjectile(pkPlasma, MuzzlePos, YawTurned(Dir, -1.5), 725, (70 + Random(10)) * Mult, True)
        else
          SpawnProjectile(pkPlasma, MuzzlePos, YawTurned(Dir, 1.5), 725, (70 + Random(10)) * Mult, True);
        FProjectiles.Last.SplashRadius := 120;
        if FGun.Frame = 8 then
          FProjectiles.Last.SplashDamage := 30 * Mult
        else
          FProjectiles.Last.SplashDamage := 120 * Mult;
      end;
  end;
end;

procedure TQuakeWorld.ChainfistHit(const Origin, Dir: TVector3; const Damage: Integer);
var
  T: TQuakeTrace;
  HitPos: TVector3;
begin
  { chainfist_fire / fire_player_melee: a trace of 64 (CHAINFIST_REACH);
    a hit pushes the player forward and up 75; walls get sparks }
  T := WorldTrace(CgeToQuake(Origin), CgeToQuake(Origin + Dir * 64), TVector3.Zero, TVector3.Zero,
    MASK_SHOT, FPlayer);
  if not T.Hit then
    Exit;
  HitPos := QuakeToCge(T.EndPos);
  if T.Ent is TQuakeMonster then
  begin
    TQuakeMonster(T.Ent).TakeDamage(Damage);
    Particles.SpawnBlood(HitPos, -Dir);
    if FPlayer <> nil then
      FPlayer.AddVelocity(Vector3(Dir.X, 0, Dir.Z) * 75 + Vector3(0, 75, 0));
  end else
  begin
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Damage)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Damage);
    Particles.SpawnImpact(HitPos - Dir * 2, -Dir);
  end;
end;

procedure TQuakeWorld.PlasmaBeam(const Origin, Dir: TVector3; const Damage: Integer);
var
  T: TQuakeTrace;
  Start, Stop: TVector3;
  Dmg: Integer;
  Right, Muzzle, HitPos: TVector3;
begin
  { fire_heatbeam: a trace of 8192, half the damage through water (the
    beam goes on), the beam drawn from the gun }
  Dmg := Damage;
  Start := CgeToQuake(Origin);
  Stop := Start + CgeToQuake(Dir) * 8192;
  T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT or 8 or 16 or 32, FPlayer);
  if T.Hit and ((T.Contents and (8 or 16 or 32)) <> 0) then
  begin
    Dmg := Dmg div 2;
    T := WorldTrace(T.EndPos + CgeToQuake(Dir), Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, FPlayer);
  end;
  HitPos := QuakeToCge(T.EndPos);
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Muzzle := Origin + Dir * 7 + Right.Normalize * 2 - Vector3(0, 3, 0);
  Particles.SpawnBeam(Muzzle, HitPos, Vector3(1.0, 0.75, 0.2));
  if not T.Hit then
    Exit;
  if T.Ent is TQuakeMonster then
  begin
    TQuakeMonster(T.Ent).TakeDamage(Dmg);
    Particles.SpawnBlood(HitPos, -Dir);
  end else
  begin
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Dmg)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Dmg);
    { TE_HEATBEAM_STEAM }
    if (T.Contents and CONTENTS_SOLID) <> 0 then
      Particles.SpawnSteam(HitPos - Dir * 2, -Dir, 8, 60, 223);
  end;
end;

procedure TQuakeWorld.ActivateUse(const Origin, Dir: TVector3);
var
  Hit: TCastleTransform;
  Dist: Single;
  Mover: TQuakeMover;
begin
  if FBsp = nil then
    Exit;
  Hit := FItems.WorldRayCast(Origin, Dir, Dist);
  if (Hit = nil) or (Dist > 96) then
    Exit;
  Mover := MoverByTransform(Hit);
  if (Mover <> nil) and (Mover.Kind in [mkDoor, mkDoorRotating, mkButton, mkPlat]) and
     ((Mover.Kind = mkButton) or Mover.AutoOpen) then
    Mover.Use;
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

function TQuakeWorld.UnitLevelsToJson: TJSONObject;
begin
  Result := FLevelStates.Clone as TJSONObject;
end;

procedure TQuakeWorld.UnitLevelsFromJson(const Obj: TJSONObject);
begin
  FreeAndNil(FLevelStates);
  if Obj <> nil then
    FLevelStates := Obj.Clone as TJSONObject
  else
    FLevelStates := TJSONObject.Create;
end;

function TQuakeWorld.SaveState: TJSONObject;
var
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
  A: TAmmoType;
  Pair: specialize TPair<TQuakeEntity, Single>;
  CPair: specialize TPair<TQuakeEntity, Integer>;
begin
  Result := TJSONObject.Create;
  Result.Add('map', FBsp.MapName);
  Result.Add('time', FTime);
  Result.Add('skill', GameSkill);
  { Player inventory }
  O := TJSONObject.Create;
  O.Add('health', FStats.Health);
  O.Add('maxHealth', FStats.MaxHealth);
  O.Add('armor', FStats.Armor);
  O.Add('armorType', FStats.ArmorType);
  O.Add('weaponMask', Int64(FStats.WeaponMask));
  O.Add('weapon', FStats.CurrentWeapon);
  O.Add('keys', Int64(FStats.Keys));
  O.Add('kills', FStats.Kills);
  O.Add('secrets', FStats.Secrets);
  O.Add('goals', FStats.Goals);
  O.Add('levelTime', FStats.LevelTime);
  O.Add('quad', FStats.QuadTime);
  O.Add('quadFire', FStats.QuadFireTime);
  O.Add('double', FStats.DoubleTime);
  O.Add('ir', FStats.IRTime);
  O.Add('defender', FStats.DefenderTime);
  O.Add('invuln', FStats.InvulnTime);
  O.Add('breather', FStats.BreatherTime);
  O.Add('enviro', FStats.EnviroTime);
  O.Add('silencer', FStats.SilencerShots);
  O.Add('powerScreens', FStats.PowerScreens);
  O.Add('powerShields', FStats.PowerShields);
  O.Add('powerArmorOn', FStats.PowerArmorOn);
  Arr := TJSONArray.Create;
  for A := Low(TAmmoType) to High(TAmmoType) do
    Arr.Add(FStats.Ammo[A]);
  O.Add('ammo', Arr);
  Arr := TJSONArray.Create;
  for A := Low(TAmmoType) to High(TAmmoType) do
    Arr.Add(FStats.MaxAmmo[A]);
  O.Add('maxAmmo', Arr);
  O.Add('helpPrimary', FHelpPrimary);
  O.Add('serverFlags', FServerFlags);
  O.Add('helpSecondary', FHelpSecondary);
  Result.Add('player', O);

  { Entities, matched by their deterministic spawn order }
  Arr := TJSONArray.Create;
  for I := 0 to FMonsters.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('pos', VecToJson(FMonsters[I].Transform.Translation));
    O.Add('facing', FMonsters[I].FacingAngle);
    O.Add('health', FMonsters[I].Health);
    O.Add('state', Ord(FMonsters[I].State));
    O.Add('alerted', FMonsters[I].Alerted);
    O.Add('gibbed', FMonsters[I].Gibbed);
    O.Add('dormant', FMonsters[I].Dormant);
    if FMonsters[I].Def^.ClassName = 'monster_stalker' then
      O.Add('ceiling', FMonsters[I].OnCeiling);
    Arr.Add(O);
  end;
  Result.Add('monsters', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to Min(FMapPickupCount, FPickups.Count) - 1 do
    Arr.Add(FPickups[I].Collected);
  Result.Add('pickups', Arr);
  { Items monsters dropped (not in the map): class and origin, if still there }
  Arr := TJSONArray.Create;
  for I := FMapPickupCount to FPickups.Count - 1 do
    if not FPickups[I].Collected then
    begin
      O := TJSONObject.Create;
      O.Add('class', FPickups[I].Entity.ClassName);
      O.Add('origin', FPickups[I].Entity.GetField('origin'));
      Arr.Add(O);
    end;
  Result.Add('drops', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FGeometry.Movers.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('state', Ord(FGeometry.Movers[I].State));
    O.Add('progress', FGeometry.Movers[I].Progress);
    O.Add('timer', FGeometry.Movers[I].StateTimer);
    O.Add('health', FGeometry.Movers[I].Health);
    O.Add('exists', FGeometry.Movers[I].Transform.Exists);
    O.Add('spinning', FGeometry.Movers[I].Spinning);
    O.Add('spin', FGeometry.Movers[I].SpinAngle);
    O.Add('turretPitch', FGeometry.Movers[I].TurretPitch);
    O.Add('turretYaw', FGeometry.Movers[I].TurretYaw);
    O.Add('trainRunning', FGeometry.Movers[I].TrainRunning);
    O.Add('trainWaiting', FGeometry.Movers[I].TrainWaiting);
    if FGeometry.Movers[I].Kind = mkPlat2 then
    begin
      O.Add('plat2Flags', FGeometry.Movers[I].Plat2Flags);
      O.Add('plat2Timer', FGeometry.Movers[I].Plat2Timer);
      O.Add('plat2Active', FGeometry.Movers[I].Plat2Active);
    end;
    O.Add('pos', VecToJson(FGeometry.Movers[I].Transform.Translation));
    O.Add('trainFrom', VecToJson(FGeometry.Movers[I].TrainFrom));
    O.Add('trainTo', VecToJson(FGeometry.Movers[I].TrainTo));
    O.Add('moveLength', FGeometry.Movers[I].MoveLength);
    if FGeometry.Movers[I].TrainCorner <> nil then
      O.Add('trainCorner', FBsp.Entities.IndexOf(FGeometry.Movers[I].TrainCorner))
    else
      O.Add('trainCorner', -1);
    Arr.Add(O);
  end;
  Result.Add('movers', Arr);

  { Projectiles in flight and grenades waiting to explode }
  Arr := TJSONArray.Create;
  for I := 0 to FProjectiles.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('kind', Ord(FProjectiles[I].Kind));
    O.Add('pos', VecToJson(FProjectiles[I].Transform.Translation));
    O.Add('velocity', VecToJson(FProjectiles[I].Velocity));
    O.Add('damage', FProjectiles[I].Damage);
    O.Add('splashDamage', FProjectiles[I].SplashDamage);
    O.Add('splashRadius', FProjectiles[I].SplashRadius);
    O.Add('life', FProjectiles[I].Life);
    O.Add('fromPlayer', FProjectiles[I].FromPlayer);
    O.Add('owner', FMonsters.IndexOf(FProjectiles[I].Owner));
    O.Add('exploding', FProjectiles[I].Exploding);
    if FProjectiles[I].Kind = pkTrap then
    begin
      O.Add('trapFrame', FProjectiles[I].TrapFrame);
      O.Add('trapLanded', FProjectiles[I].TrapLanded);
      O.Add('trapWait', FProjectiles[I].TrapWait);
      O.Add('trapMass', FProjectiles[I].TrapMass);
    end;
    Arr.Add(O);
  end;
  Result.Add('projectiles', Arr);

  { Targets fired later (trigger "delay"), as seconds from now: the world
    clock starts again from 0 when a level is loaded }
  Arr := TJSONArray.Create;
  for I := 0 to FDelayed.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('in', Max(0, FDelayed[I].Time - FTime));
    O.Add('target', FDelayed[I].Target);
    O.Add('entity', FBsp.Entities.IndexOf(FDelayed[I].Entity));
    Arr.Add(O);
  end;
  Result.Add('delayed', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FGeometry.AreaPortals.Count - 1 do
    Arr.Add(FGeometry.AreaPortals[I].Toggled);
  Result.Add('areaPortals', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FProps.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('health', FProps[I].Health);
    O.Add('destroyed', FProps[I].Destroyed);
    O.Add('exists', FProps[I].Transform.Exists);
    O.Add('flying', FProps[I].Flying);
    if FProps[I].Kind = pkRotatingLight then
    begin
      O.Add('lightOn', FProps[I].LightOn);
      O.Add('alarm', FProps[I].AlarmActive);
    end;
    O.Add('pos', VecToJson(FProps[I].Transform.Translation));
    O.Add('flyTarget', VecToJson(FProps[I].FlyTarget));
    if FProps[I].FlyCorner <> nil then
      O.Add('flyCorner', FBsp.Entities.IndexOf(FProps[I].FlyCorner))
    else
      O.Add('flyCorner', -1);
    Arr.Add(O);
  end;
  Result.Add('props', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FTriggers.Count - 1 do
    Arr.Add(FTriggers[I].Enabled);
  Result.Add('triggers', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FLasers.Count - 1 do
    Arr.Add(FLasers[I].IsOn);
  Result.Add('lasers', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FSpeakers.Count - 1 do
    Arr.Add(FSpeakers[I].Playing);
  Result.Add('speakers', Arr);

  O := TJSONObject.Create;
  for Pair in FTimers do
    if Pair.Value < 0 then
      O.Add(IntToStr(FBsp.Entities.IndexOf(Pair.Key)), -1)
    else
      O.Add(IntToStr(FBsp.Entities.IndexOf(Pair.Key)), Pair.Value - FTime);
  Result.Add('timers', O);

  O := TJSONObject.Create;
  for CPair in FCounters do
    O.Add(IntToStr(FBsp.Entities.IndexOf(CPair.Key)), CPair.Value);
  Result.Add('counters', O);

  Arr := TJSONArray.Create;
  for I := 32 to 62 do
    Arr.Add(Lighting.GetStyle(I));
  Result.Add('lightStyles', Arr);
end;

procedure TQuakeWorld.LoadState(const Obj: TJSONObject; const IncludePlayer: Boolean);
var
  O: TJSONObject;
  Arr: TJSONArray;
  I, Idx: Integer;
  A: TAmmoType;
  Mover: TQuakeMover;
  Prop: TQuakeProp;
  Proj: TQuakeProjectile;
  D: TDelayedTarget;
  Key: String;
  DropEnt: TQuakeEntity;
begin
  O := Obj.Get('player', TJSONObject(nil));
  if (O <> nil) and not IncludePlayer then
  begin
    { Level counters belong to the level }
    FStats.Kills := O.Get('kills', 0);
    FStats.Secrets := O.Get('secrets', 0);
    FStats.Goals := O.Get('goals', 0);
    O := nil;
  end;
  if O <> nil then
  begin
    FStats.Health := O.Get('health', FStats.Health);
    FStats.MaxHealth := O.Get('maxHealth', FStats.MaxHealth);
    FStats.Armor := O.Get('armor', FStats.Armor);
    FStats.ArmorType := O.Get('armorType', FStats.ArmorType);
    FStats.WeaponMask := O.Get('weaponMask', Int64(FStats.WeaponMask));
    FStats.Keys := O.Get('keys', Int64(FStats.Keys));
    FStats.Kills := O.Get('kills', 0);
    FStats.Secrets := O.Get('secrets', 0);
    FStats.Goals := O.Get('goals', 0);
    FStats.LevelTime := O.Get('levelTime', 0.0);
    FStats.QuadTime := O.Get('quad', 0.0);
    FStats.QuadFireTime := O.Get('quadFire', 0.0);
    FStats.DoubleTime := O.Get('double', 0.0);
    FStats.IRTime := O.Get('ir', 0.0);
    FStats.DefenderTime := O.Get('defender', 0.0);
    FStats.InvulnTime := O.Get('invuln', 0.0);
    FStats.BreatherTime := O.Get('breather', 0.0);
    FStats.EnviroTime := O.Get('enviro', 0.0);
    FStats.SilencerShots := O.Get('silencer', 0);
    FStats.PowerScreens := O.Get('powerScreens', 0);
    FStats.PowerShields := O.Get('powerShields', 0);
    FStats.PowerArmorOn := O.Get('powerArmorOn', False);
    Arr := O.Get('ammo', TJSONArray(nil));
    if Arr <> nil then
      for A := Low(TAmmoType) to High(TAmmoType) do
        if Ord(A) < Arr.Count then
          FStats.Ammo[A] := Arr.Integers[Ord(A)];
    Arr := O.Get('maxAmmo', TJSONArray(nil));
    if Arr <> nil then
      for A := Low(TAmmoType) to High(TAmmoType) do
        if Ord(A) < Arr.Count then
          FStats.MaxAmmo[A] := Arr.Integers[Ord(A)];
    FHelpPrimary := O.Get('helpPrimary', '');
    FServerFlags := O.Get('serverFlags', 0);
    FHelpSecondary := O.Get('helpSecondary', '');
    if FHud <> nil then
    begin
      FHud.HelpPrimary := FHelpPrimary;
      FHud.HelpSecondary := FHelpSecondary;
    end;
    I := O.Get('weapon', 1);
    if (I < 1) or (I > WeaponSlots) or ((FStats.WeaponMask and (1 shl I)) = 0) then
      I := 1;
    FStats.CurrentWeapon := I;
    FGun.Reset(I, False);
    UpdateWeaponModel;
  end;

  Arr := Obj.Get('monsters', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FMonsters.Count) - 1 do
    begin
      O := Arr.Objects[I];
      if O.Find('ceiling') <> nil then
        FMonsters[I].SetCeiling(O.Get('ceiling', False));
      FMonsters[I].RestoreState(JsonToVec(O.Find('pos')), O.Get('facing', 0.0),
        O.Get('health', 0), TMonsterState(O.Get('state', 0)),
        O.Get('alerted', False), O.Get('gibbed', False));
      FMonsters[I].SetDormant(O.Get('dormant', False));
    end;

  Arr := Obj.Get('pickups', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FPickups.Count) - 1 do
      FPickups[I].Collected := Arr.Booleans[I];
  Arr := Obj.Get('drops', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        O := TJSONObject(Arr.Items[I]);
        DropEnt := TQuakeEntity.Create;
        DropEnt.SetField('classname', O.Get('class', ''));
        DropEnt.SetField('origin', O.Get('origin', '0 0 0'));
        FBsp.Entities.Add(DropEnt);
        SpawnEntity(DropEnt);
        WritelnLog('QuakeWorld', 'Restored dropped %s at %s', [DropEnt.ClassName, DropEnt.GetField('origin')]);
      end;

  Arr := Obj.Get('movers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FGeometry.Movers.Count) - 1 do
    begin
      O := Arr.Objects[I];
      Mover := FGeometry.Movers[I];
      Mover.State := TQuakeMoverState(O.Get('state', 0));
      Mover.Progress := O.Get('progress', 0.0);
      Mover.StateTimer := O.Get('timer', 0.0);
      Mover.Health := O.Get('health', Mover.Health);
      Mover.Transform.Exists := O.Get('exists', True);
      Mover.Spinning := O.Get('spinning', Mover.Spinning);
      Mover.SpinAngle := O.Get('spin', 0.0);
      Mover.TurretPitch := O.Get('turretPitch', Mover.TurretPitch);
      Mover.TurretYaw := O.Get('turretYaw', Mover.TurretYaw);
      Mover.TrainRunning := O.Get('trainRunning', Mover.TrainRunning);
      Mover.TrainWaiting := O.Get('trainWaiting', False);
      if Mover.Kind = mkPlat2 then
      begin
        Mover.Plat2Flags := O.Get('plat2Flags', 0);
        Mover.Plat2Timer := O.Get('plat2Timer', 0.0);
        Mover.Plat2Active := O.Get('plat2Active', Mover.Plat2Active);
      end;
      Mover.MoveLength := O.Get('moveLength', Mover.MoveLength);
      Mover.TrainFrom := JsonToVec(O.Find('trainFrom'));
      Mover.TrainTo := JsonToVec(O.Find('trainTo'));
      Idx := O.Get('trainCorner', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        Mover.TrainCorner := FBsp.Entities[Idx];
      if Mover.Kind = mkTrain then
        Mover.Transform.Translation := JsonToVec(O.Find('pos'));
      Mover.ApplyPose;
    end;

  Arr := Obj.Get('areaPortals', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FGeometry.AreaPortals.Count) - 1 do
      FGeometry.AreaPortals[I].Toggled := Arr.Booleans[I];

  { Savegames restore projectiles and pending events. A revisited level
    (IncludePlayer = False) starts without projectiles and keeps the events
    scheduled at spawn: Quake 2's ReadLevel re-arms target_crosslevel_target
    the same way. }
  if not IncludePlayer then
    FProjectiles.Clear;
  Arr := Obj.Get('projectiles', TJSONArray(nil));
  if (Arr <> nil) and IncludePlayer then
  begin
    FProjectiles.Clear;
    for I := 0 to Arr.Count - 1 do
    begin
      O := Arr.Objects[I];
      Idx := O.Get('kind', 0);
      if (Idx < Ord(Low(TProjectileKind))) or (Idx > Ord(High(TProjectileKind))) then
        Continue;
      Proj := TQuakeProjectile.Create(FItems, TProjectileKind(Idx), JsonToVec(O.Find('pos')),
        JsonToVec(O.Find('velocity')), O.Get('damage', 0), O.Get('fromPlayer', False));
      Proj.SplashDamage := O.Get('splashDamage', 0);
      Proj.SplashRadius := O.Get('splashRadius', 0.0);
      Proj.Life := O.Get('life', Proj.Life);
      Proj.Exploding := O.Get('exploding', False);
      Proj.Transform.Exists := not Proj.Exploding;
      Proj.TrapFrame := O.Get('trapFrame', 0);
      Proj.TrapLanded := O.Get('trapLanded', False);
      Proj.TrapWait := O.Get('trapWait', 0);
      Proj.TrapMass := O.Get('trapMass', 0);
      if (Proj.Kind = pkTrap) and (Proj.Model <> nil) then
        Proj.Model.SetFrame(Min(Proj.TrapFrame, 7));
      Idx := O.Get('owner', -1);
      if (Idx >= 0) and (Idx < FMonsters.Count) then
        Proj.Owner := FMonsters[Idx];
      FProjectiles.Add(Proj);
    end;
  end;

  Arr := Obj.Get('delayed', TJSONArray(nil));
  if IncludePlayer then
    FDelayed.Clear;
  if (Arr <> nil) and IncludePlayer then
  begin
    FDelayed.Clear;
    for I := 0 to Arr.Count - 1 do
    begin
      D.Time := FTime + Arr.Objects[I].Get('in', 0.0);
      D.Target := Arr.Objects[I].Get('target', '');
      Idx := Arr.Objects[I].Get('entity', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        D.Entity := FBsp.Entities[Idx]
      else
        D.Entity := nil;
      FDelayed.Add(D);
    end;
  end;

  Arr := Obj.Get('props', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FProps.Count) - 1 do
    begin
      O := Arr.Objects[I];
      Prop := FProps[I];
      Prop.Health := O.Get('health', Prop.Health);
      Prop.Destroyed := O.Get('destroyed', False);
      Prop.Transform.Exists := O.Get('exists', True);
      Prop.Flying := O.Get('flying', False);
      if Prop.Kind = pkRotatingLight then
      begin
        Prop.LightOn := O.Get('lightOn', Prop.LightOn);
        Prop.AlarmActive := O.Get('alarm', False);
      end;
      Prop.Transform.Translation := JsonToVec(O.Find('pos'));
      Prop.FlyTarget := JsonToVec(O.Find('flyTarget'));
      Idx := O.Get('flyCorner', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        Prop.FlyCorner := FBsp.Entities[Idx];
    end;

  Arr := Obj.Get('triggers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FTriggers.Count) - 1 do
      FTriggers[I].Enabled := Arr.Booleans[I];

  Arr := Obj.Get('lasers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FLasers.Count) - 1 do
      FLasers[I].IsOn := Arr.Booleans[I];

  Arr := Obj.Get('speakers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FSpeakers.Count) - 1 do
      if FSpeakers[I].Looped and (FSpeakers[I].Playing <> Arr.Booleans[I]) then
        FSpeakers[I].Activate;

  O := Obj.Get('timers', TJSONObject(nil));
  if O <> nil then
    for I := 0 to O.Count - 1 do
    begin
      Key := O.Names[I];
      Idx := StrToIntDef(Key, -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) and FTimers.ContainsKey(FBsp.Entities[Idx]) then
      begin
        if O.Items[I].AsFloat < 0 then
          FTimers[FBsp.Entities[Idx]] := -1
        else
          FTimers[FBsp.Entities[Idx]] := FTime + O.Items[I].AsFloat;
      end;
    end;

  O := Obj.Get('counters', TJSONObject(nil));
  if O <> nil then
    for I := 0 to O.Count - 1 do
    begin
      Idx := StrToIntDef(O.Names[I], -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        FCounters.AddOrSetValue(FBsp.Entities[Idx], O.Items[I].AsInteger);
    end;

  Arr := Obj.Get('lightStyles', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, 31) - 1 do
      Lighting.SetStyle(32 + I, Arr.Strings[I]);

end;

function TQuakeWorld.IntermissionSpot(out Pos: TVector3; out Yaw, Pitch: Single): Boolean;
var
  Ent: TQuakeEntity;
  A: TVector3;
begin
  Result := False;
  Pos := FPlayerPos;
  Yaw := 0;
  Pitch := 0;
  if FBsp = nil then
    Exit;
  Ent := FBsp.FindEntity('info_player_intermission');
  if Ent = nil then
    Exit;
  A := Ent.GetVector('angles', Vector3(0, Ent.Angle, 0));
  Pos := QuakeToCge(Ent.Origin);
  Pitch := A.X;
  Yaw := A.Y;
  Result := True;
end;

procedure TQuakeWorld.SetPlayer(const Value: TQuakePlayerMovement);
begin
  FPlayer := Value;
  if FPlayer <> nil then
  begin
    FBaseGravity := FPlayer.GravityAcceleration;
    FPlayerGravity := 1;
    FPlayer.OnFallDamage := @PlayerFallDamage;
    FPlayer.OnPointContents := @PlayerPointContents;
    FPlayer.OnLandSound := @PlayerLanded;
    FPlayer.OnTrace := @PlayerTrace;
    FPlayer.OnBeforeMove := @PlayerBeforeMove;
  end;
end;

procedure TQuakeWorld.LinkTurret(const T: TQuakeTurret);
var
  List: TQuakeEntityList;
  Team: String;
  Mover: TQuakeMover;
begin
  { turret_breach_finish_init: the muzzle from the breach's target; the
    bases are the turret_bases of its team }
  T.Linked := True;
  if T.Breach.Target <> '' then
  begin
    List := FBsp.FindByTargetName(T.Breach.Target);
    try
      if List.Count > 0 then
        T.MoveOrigin := List[0].Origin - T.Breach.Entity.Origin;
    finally
      List.Free;
    end;
  end else
    WritelnLog('QuakeWorld', 'turret_breach at %s needs a target', [T.Breach.Entity.Origin.ToString]);
  Team := T.Breach.Entity.GetField('team', '');
  if Team <> '' then
    for Mover in FGeometry.Movers do
      if (Mover.EntityClass = 'turret_base') and (Mover.Entity.GetField('team', '') = Team) then
      begin
        SetLength(T.Bases, Length(T.Bases) + 1);
        T.Bases[High(T.Bases)] := Mover;
      end;
end;

procedure TQuakeWorld.TurretFire(const T: TQuakeTurret);
var
  Muzzle, F, R, U: TVector3;
  Damage: Integer;
  Proj: TQuakeProjectile;
begin
  { turret_breach_fire: a rocket along the breach's forward, 100..150
    damage (also the splash, radius 150), speed 550 + 50 * skill }
  Muzzle := TurretMuzzle(T.Breach.Entity.Origin, T.Breach.TurretPitch, T.Breach.TurretYaw, T.MoveOrigin);
  QuakeAngleVectors(T.Breach.TurretPitch, T.Breach.TurretYaw, F, R, U);
  { The breach's "count" sets the damage (the remaster) }
  Damage := T.Breach.Entity.GetInt('count', 0);
  if Damage <= 0 then
    Damage := 100 + Random(51);
  SpawnProjectile(pkRocket, QuakeToCge(Muzzle), QuakeToCge(F), 550 + 50 * GameSkill, Damage, False, T.Driver);
  Proj := FProjectiles.Last;
  Proj.SplashDamage := Damage;
  Proj.SplashRadius := 150;
  Sounds.PlayAtPoint('sound/weapons/rocklf1a.wav', QuakeToCge(Muzzle), 1, 1, T.Breach, chWeapon);
  Inc(T.Shots);
  WritelnLog('QuakeWorld', 'turret_breach fires (pitch %.1f yaw %.1f, %d damage)',
    [T.Breach.TurretPitch, T.Breach.TurretYaw, Damage]);
end;

function TQuakeWorld.BrainEnemyPos(const T: TQuakeTurret; out Pos: TVector3): Boolean;
var
  M: TQuakeMonster;
begin
  { The middle of the enemy's box: a monster with that entity (gone once it
    died), else the entity's own origin }
  Result := False;
  if T.BrainEnemy = nil then
    Exit;
  for M in FMonsters do
    if M.Entity = T.BrainEnemy then
    begin
      if (not M.IsAlive) or M.Dormant then
        Exit;
      Pos := M.Origin + (M.BoxMins + M.BoxMaxs) * 0.5;
      Exit(True);
    end;
  Pos := T.BrainEnemy.Origin;
  Result := True;
end;

function TQuakeWorld.UpdateTurretBrain(const T: TQuakeTurret): Boolean;
var
  EnemyPos, BreachOrg: TVector3;
  Tr: TQuakeTrace;
  Reaction: Single;
begin
  { turret_brain_think: no searching; it stops when its enemy is gone }
  Result := False;
  BreachOrg := T.Breach.Entity.Origin;
  if not BrainEnemyPos(T, EnemyPos) then
  begin
    T.BrainOn := False;
    T.BrainStopped := True;
    WritelnLog('QuakeWorld', 'turret_invisible_brain: its enemy is gone');
    Exit;
  end;
  { Sight: a MASK_SHOT line from the breach (IGNORE_SIGHT 1 skips it) }
  if (T.Brain.SpawnFlags and 1) = 0 then
  begin
    Tr := WorldTrace(BreachOrg, EnemyPos, TVector3.Zero, TVector3.Zero, MASK_SHOT, T.Breach);
    if (Tr.Fraction < 1) and ((Tr.Ent = nil) or (Tr.Ent is TQuakeMover)) then
    begin
      T.LostSight := True;
      Exit;
    end;
  end;
  if T.LostSight or not T.HadEnemy then
  begin
    { Reaction time counted from when it (re)gained sight }
    T.TrailTime := FTime;
    T.LostSight := False;
    T.HadEnemy := True;
  end;
  QuakeVecToAngles(EnemyPos - BreachOrg, T.MovePitch, T.MoveYaw);
  { "delay" between shots, else 3 - skill seconds }
  Reaction := T.Brain.GetFloat('delay', 0);
  if Reaction <= 0 then
    Reaction := 3 - GameSkill;
  if (FTime >= T.AttackFinished) and (FTime - T.TrailTime >= Reaction) then
  begin
    T.AttackFinished := FTime + Reaction + 1;
    Result := True;
  end;
end;

procedure TQuakeWorld.UpdateTurrets(const SecondsPassed: Single);
var
  T: TQuakeTurret;
  M: TQuakeMonster;
  I: Integer;
  BreachOrg: TVector3;
  DP, DY, Reaction: Single;
  Fire: Boolean;
begin
  if FTurrets.Count = 0 then
    Exit;
  { turret_driver_link: a driver takes the breach its target names }
  for M in FMonsters do
    if M.TurretDriver and (not M.TurretLinked) and M.IsAlive and not M.Dormant then
      for T in FTurrets do
        if (T.Driver = nil) and (T.Breach.TargetName <> '') and SameText(T.Breach.TargetName, M.Entity.Target) then
        begin
          M.TurretLinked := True;
          T.Driver := M;
          T.DriverOffset := TurretDriverOffset(M.Origin, T.Breach.Entity.Origin);
          WritelnLog('QuakeWorld', '%s drives turret_breach "%s"', [M.Transform.Name, T.Breach.TargetName]);
          Break;
        end;

  { turret_brain_link: a brain takes the breach its target names, and the
    entity its killtarget names as its enemy }
  for I := FBrainEnts.Count - 1 downto 0 do
    for T in FTurrets do
      if (T.Brain = nil) and (T.Breach.TargetName <> '') and SameText(T.Breach.TargetName, FBrainEnts[I].Target) then
      begin
        T.Brain := FBrainEnts[I];
        T.BrainEnemy := PickTarget(T.Brain.GetField('killtarget'));
        T.BrainOn := T.Brain.TargetName = '';
        WritelnLog('QuakeWorld', 'turret_invisible_brain drives turret_breach "%s" against "%s" (on: %s)',
          [T.Breach.TargetName, T.Brain.GetField('killtarget'), BoolToStr(T.BrainOn, True)]);
        FBrainEnts.Delete(I);
        Break;
      end;

  for T in FTurrets do
  begin
    if not T.Linked then
      LinkTurret(T);
    BreachOrg := T.Breach.Entity.Origin;
    Fire := False;

    if (T.Brain <> nil) and T.BrainOn then
      Fire := UpdateTurretBrain(T);

    { turret_driver_die: the gun levels, the turret has no owner any more }
    if (T.Driver <> nil) and not T.Driver.IsAlive then
    begin
      WritelnLog('QuakeWorld', 'turret_driver died: the turret levels');
      T.Driver := nil;
      T.MovePitch := 0;
    end;

    { turret_driver_think: aim at the visible enemy, fire after the
      reaction time (3 - skill seconds) from when it was (re)acquired }
    M := T.Driver;
    if (M <> nil) and M.Alerted and (not FDead) and (not NoTarget) then
    begin
      if not T.HadEnemy then
      begin
        T.HadEnemy := True;
        T.TrailTime := FTime;
        T.LostSight := False;
      end;
      if M.CanSeePlayer then
      begin
        if T.LostSight then
        begin
          T.TrailTime := FTime;
          T.LostSight := False;
        end;
        QuakeVecToAngles(CgeToQuake(FPlayerPos) - BreachOrg, T.MovePitch, T.MoveYaw);
        Reaction := 3 - GameSkill;
        if (FTime >= T.AttackFinished) and (FTime - T.TrailTime >= Reaction) then
        begin
          T.AttackFinished := FTime + Reaction + 1;
          Fire := True;
        end;
      end else
        T.LostSight := True;
    end;

    { turret_breach_think: turn towards the (clamped) wished angles }
    TurretClampAngles(T.MovePitch, T.MoveYaw, T.Limits);
    TurretStep(T.Breach.TurretPitch, T.Breach.TurretYaw, T.MovePitch, T.MoveYaw,
      T.Speed * SecondsPassed, DP, DY);
    T.Breach.TurretPitch := T.Breach.TurretPitch + DP;
    T.Breach.TurretYaw := T.Breach.TurretYaw + DY;
    T.Breach.ApplyPose;
    for I := 0 to High(T.Bases) do
    begin
      T.Bases[I].TurretYaw := T.Bases[I].TurretYaw + DY;
      T.Bases[I].ApplyPose;
    end;

    { The driver sits behind the breach, turned and tilted with it }
    if T.Driver <> nil then
    begin
      M := T.Driver;
      M.FacingAngle := T.Breach.TurretYaw;
      M.Transform.Translation := QuakeToCge(TurretDriverOrigin(BreachOrg, T.Breach.TurretPitch,
        T.Breach.TurretYaw, T.DriverOffset, M.Origin.Z));
      M.Transform.Rotation := TurretRotation(T.Breach.TurretPitch, T.Breach.TurretYaw);
      if Fire then
        TurretFire(T);
    end else
    if Fire then
      { turret_invisible_brain: no driver to move }
      TurretFire(T);
  end;
end;

function TQuakeWorld.MoverTrace(const Mover: TQuakeMover; const Start, Stop, Mins, Maxs: TVector3;
  const Mask: Integer): TQuakeTrace;
begin
  Result := MoverTraceAt(Mover, Mover.Transform.Transform, Start, Stop, Mins, Maxs, Mask);
end;

function TQuakeWorld.MoverTraceAt(const Mover: TQuakeMover; const M: TMatrix4;
  const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
var
  Inv: TMatrix4;
  LStart, LStop, Org: TVector3;
begin
  { Into the brush model's own coordinates (CM_TransformedBoxTrace): the
    scene is placed relative to the entity origin (BaseOffset) by its
    transform; a rotated model keeps the box axis-aligned, like Quake 2.
    Console-spawned boxes (ModelIndex 0) have no brushes: doors are traced
    as their mins / maxs box at the entity origin (so they block and can be
    shot); turrets are never hit (their muzzle is inside the breach box). }
  if not M.TryInverse(Inv) then
    Exit(BoxTraceAgainstBox(Stop, Stop, TVector3.Zero, TVector3.Zero, Vector3(1, 1, 1), Vector3(0, 0, 0), 0));
  LStart := CgeToQuake(Inv.MultPoint(QuakeToCge(Start)) + Mover.BaseOffset);
  LStop := CgeToQuake(Inv.MultPoint(QuakeToCge(Stop)) + Mover.BaseOffset);
  if Mover.ModelIndex <= 0 then
  begin
    if (not (Mover.Kind in [mkDoor, mkSecretDoor])) or ((Mask and CONTENTS_SOLID) = 0) or
       not (Mover.Entity.HasField('mins') and Mover.Entity.HasField('maxs')) then
      Exit(BoxTraceAgainstBox(Stop, Stop, TVector3.Zero, TVector3.Zero, Vector3(1, 1, 1), Vector3(0, 0, 0), 0));
    Org := Mover.Entity.Origin;
    Result := BoxTraceAgainstBox(LStart, LStop, Mins, Maxs,
      Org + Mover.Entity.GetVector('mins', TVector3.Zero),
      Org + Mover.Entity.GetVector('maxs', TVector3.Zero), CONTENTS_SOLID);
  end else
    Result := FCollision.BoxTrace(LStart, LStop, Mins, Maxs, FBsp.Models[Mover.ModelIndex].HeadNode, Mask);
  if Result.Hit then
  begin
    Result.Normal := CgeToQuake(M.MultDirection(QuakeToCge(Result.Normal))).Normalize;
    Result.EndPos := Start + (Stop - Start) * Result.Fraction;
    Result.Ent := Mover;
  end else
    Result.EndPos := Stop;
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

function TQuakeWorld.PlayerTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
begin
  Result := WorldTrace(Start, Stop, Mins, Maxs, Mask, FPlayer);
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
  { The player's box (for monsters and their shots) }
  if ((Mask and CONTENTS_MONSTER) <> 0) and (FPlayer <> nil) and (Ignore <> FPlayer) and (not FDead) and
     (FPlayer.Parent <> nil) then
  begin
    Org := FPlayer.Origin;
    if Overlaps(Org + FPlayer.BoxMins, Org + FPlayer.BoxMaxs) then
    begin
      T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, Org + FPlayer.BoxMins, Org + FPlayer.BoxMaxs,
        CONTENTS_MONSTER);
      if T.Hit then
      begin
        T.Ent := FPlayer;
        CombineTrace(Result, T);
      end;
    end;
  end;
end;

procedure TQuakeWorld.PlayerBeforeMove(Sender: TObject);
var
  Org: TVector3;
begin
  if FBsp = nil then
    Exit;
  PushPlayerByMovers;
  { For monster moves: the player's box in CGE space }
  if FDead then
    PlayerBlockBox := TBox3D.Empty
  else
  begin
    Org := FPlayer.Origin;
    PlayerBlockBox := QuakeBoxToCge(Org + FPlayer.BoxMins, Org + FPlayer.BoxMaxs);
  end;
end;

procedure TQuakeWorld.PushPlayerByMovers;
const
  { Quake 2 item boxes, and what blocks items (MASK_SOLID) }
  ItemMins: TVector3 = (X: -15; Y: -15; Z: -15);
  ItemMaxs: TVector3 = (X: 15; Y: 15; Z: 15);
  MASK_SOLID = CONTENTS_SOLID or CONTENTS_WINDOW;
var
  Mover: TQuakeMover;
  M, Old, OldInv: TMatrix4;
  Org, Mins, Maxs, Delta: TVector3;
  Blocked: Boolean;
  Damage: Integer;
  Monster: TQuakeMonster;
  Pickup: TQuakePickup;

  { Quake 2 SV_Push for one entity: it moves with the mover when it rides
    it (stood on its old pose) or the mover moved into it; it keeps the
    pushed position if free, else the old one if that is free; else the
    mover is blocked. True with Delta (CGE) when it should move. }
  function PushOne(const AOrg, AMins, AMaxs: TVector3; const Mask: Integer; const Ent: TObject;
    const Riding: Boolean; out ADelta: TVector3; out ABlocked: Boolean): Boolean;
  var
    T: TQuakeTrace;
    Ride, Inside: Boolean;
    NewQ: TVector3;
  begin
    Result := False;
    ABlocked := False;
    ADelta := TVector3.Zero;
    Ride := Riding;
    if not Ride then
    begin
      T := MoverTraceAt(Mover, Old, AOrg, AOrg - Vector3(0, 0, 1), AMins, AMaxs, Mask);
      Ride := (T.Fraction < 1) and not T.StartSolid;
    end;
    Inside := (not Ride) and MoverTrace(Mover, AOrg, AOrg, AMins, AMaxs, Mask).StartSolid and
      not MoverTraceAt(Mover, Old, AOrg, AOrg, AMins, AMaxs, Mask).StartSolid;
    if not (Ride or Inside) then
      Exit;
    { Like a point fixed to the mover }
    NewQ := CgeToQuake(M.MultPoint(OldInv.MultPoint(QuakeToCge(AOrg))));
    { A push longer than 64 units in one frame is the box approximation of
      a rotated model catching something far away: ignore it }
    if PointsDistance(NewQ, AOrg) > 64 then
      Exit;
    if not WorldTrace(NewQ, NewQ, AMins, AMaxs, Mask, Ent).StartSolid then
    begin
      ADelta := QuakeToCge(NewQ) - QuakeToCge(AOrg);
      Result := True;
    end else
      ABlocked := WorldTrace(AOrg, AOrg, AMins, AMaxs, Mask, Ent).StartSolid;
  end;

begin
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
  begin
    if Mover.ModelIndex <= 0 then
      Continue; { console-spawned boxes have no brushes }
    M := Mover.Transform.Transform;
    if FMoverPoses.TryGetValue(Mover, Old) and not TMatrix4.PerfectlyEquals(M, Old) and
       Mover.Transform.Exists and Old.TryInverse(OldInv) then
    begin
      { The player }
      if (FPlayer <> nil) and Assigned(FPlayer.OnTrace) and (not FDead) and (FPlayer.Parent <> nil) then
      begin
        Org := FPlayer.Origin;
        Mins := FPlayer.BoxMins;
        Maxs := FPlayer.BoxMaxs;
        if PushOne(Org, Mins, Maxs, MASK_PLAYERSOLID, FPlayer, FPlayer.GroundObject = Mover, Delta, Blocked) then
          FPlayer.Push(Delta)
        else
        if Blocked then
        begin
          Damage := Mover.Blocked;
          if Damage > 0 then
            DamagePlayer(Damage, Mover.Center);
        end;
      end;
      { Continuously spinning brushes only push the player }
      if Mover.Kind in [mkRotating, mkTurret] then
      begin
        FMoverPoses.AddOrSetValue(Mover, M);
        Continue;
      end;
      { Monsters and corpses (a corpse caught in a door is gibbed) }
      for Monster in FMonsters do
      begin
        { Flyers too (SV_Push moves every MOVETYPE_STEP entity): a closing
          door used to swallow floaters }
        if Monster.Dormant or Monster.Gibbed or (Monster.Transform = nil) or (not Monster.Transform.Exists) then
          Continue;
        Org := Monster.Origin;
        Maxs := Monster.BoxMaxs;
        if not Monster.IsAlive then
          Maxs.Z := Monster.BoxMins.Z + 16;
        if PushOne(Org, Monster.BoxMins, Maxs, MASK_MONSTERSOLID, Monster, False, Delta, Blocked) then
        begin
          Monster.Transform.Translation := Monster.Transform.Translation + Delta;
        end
        else
        if Blocked then
        begin
          Damage := Mover.Blocked;
          if not Monster.IsAlive then
            Monster.TakeDamage(1000)
          else
          if Damage > 0 then
            Monster.TakeDamage(Damage);
        end;
      end;
      { Items }
      for Pickup in FPickups do
      begin
        if Pickup.Collected or (Pickup.Transform = nil) or (not Pickup.Transform.Exists) then
          Continue;
        Org := CgeToQuake(Pickup.Origin);
        { Items never block movers: their spawn origins may touch the floor }
        if PushOne(Org, ItemMins, ItemMaxs, MASK_SOLID, Pickup, False, Delta, Blocked) then
        begin
          Pickup.Origin := Pickup.Origin + Delta;
          Pickup.Transform.Translation := Pickup.Transform.Translation + Delta;
        end;
      end;
    end;
    FMoverPoses.AddOrSetValue(Mover, M);
  end;
end;

function TQuakeWorld.PlayerPointContents(const CgePos: TVector3): Integer;
begin
  if FBsp = nil then
    Exit(0);
  { Leaf contents, but the ladder bit only when really inside a ladder brush }
  Result := FBsp.PointContents(CgeToQuake(CgePos)) and not CONTENTS_LADDER;
  if FBsp.PointInLadder(CgeToQuake(CgePos)) then
    Result := Result or CONTENTS_LADDER;
end;

procedure TQuakeWorld.UpdateLiquids(const SecondsPassed: Single);
var
  Level, WType: Integer;
begin
  if (FPlayer = nil) or FDead then
    Exit;
  Level := FPlayer.WaterLevel;
  WType := FPlayer.WaterType;

  { P_WorldEffects: enter / leave sounds }
  if (FLastWaterLevel = 0) and (Level > 0) then
  begin
    if (WType and CONTENTS_LAVA) <> 0 then
      Sounds.Play('sound/player/lava_in.wav', 1, chBody)
    else
      Sounds.Play('sound/player/watr_in.wav', 1, chBody);
  end else
  if (FLastWaterLevel > 0) and (Level = 0) then
    Sounds.Play('sound/player/watr_out.wav', 1, chBody)
  else
  if (FLastWaterLevel < 3) and (Level = 3) then
    Sounds.Play('sound/player/watr_un.wav', 1, chBody);
  if (FLastWaterLevel = 3) and (Level < 3) and (FAirFinished < FTime + 7) then
    Sounds.Play('sound/player/gasp1.wav', 1, chVoice);

  { Drowning: 12 seconds of air, then 2 damage per second, increasing;
    the rebreather and environment suit give air (P_WorldEffects) }
  if Level < 3 then
    FAirFinished := FTime + 12
  else
  begin
    if (FStats.BreatherTime > 0) or (FStats.EnviroTime > 0) then
    begin
      FAirFinished := FTime + 10;
      { u_breath1 / u_breath2 every 2.5 s }
      FBreathTimer := FBreathTimer - SecondsPassed;
      if FBreathTimer <= 0 then
      begin
        FBreathTimer := 2.5;
        FBreathSound := not FBreathSound;
        if FBreathSound then
          Sounds.Play('sound/player/u_breath1.wav', 1, chAuto)
        else
          Sounds.Play('sound/player/u_breath2.wav', 1, chAuto);
        PlayerNoise(FPlayerPos);
      end;
    end;
    if FTime > FAirFinished then
    begin
      FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
      if FLiquidDamageTimer <= 0 then
      begin
        FLiquidDamageTimer := 1;
        DamagePlayer(Min(15, 2 + 2 * Trunc(FTime - FAirFinished)), FPlayerPos, True);
      end;
    end;
  end;

  { Lava: 3 per water level a frame (1 with the environment suit); slime: 1,
    none with the suit }
  if (Level > 0) and ((WType and (CONTENTS_LAVA or CONTENTS_SLIME)) <> 0) then
  begin
    FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
    if FLiquidDamageTimer <= 0 then
    begin
      FLiquidDamageTimer := 0.1;
      if (WType and CONTENTS_LAVA) <> 0 then
      begin
        if FStats.EnviroTime > 0 then
          DamagePlayer(Level, FPlayerPos)
        else
          DamagePlayer(3 * Level, FPlayerPos);
      end else
      if FStats.EnviroTime <= 0 then
        DamagePlayer(Level, FPlayerPos);
    end;
  end;

  FLastWaterLevel := Level;
  if FHud <> nil then
  begin
    if Level = 3 then
      FHud.UnderwaterType := WType
    else
      FHud.UnderwaterType := 0;
  end;
end;

procedure TQuakeWorld.PlayerFallDamage(const Damage: Integer);
begin
  if Damage >= 10 then
    Sounds.Play('sound/player/male/fall1.wav', 1, chVoice)
  else
    Sounds.Play('sound/player/male/fall2.wav', 1, chVoice);
  DamagePlayer(Damage, FPlayerPos);
end;

procedure TQuakeWorld.PlayerLanded(Sender: TObject);
begin
  Sounds.Play('sound/player/land1.wav');
end;

procedure TQuakeWorld.TeleportDone;
begin
  FTeleportPending := False;
end;

procedure TQuakeWorld.CheatGiveAll;
var
  A: TAmmoType;
  I: Integer;
begin
  FStats.WeaponMask := ((1 shl (HandGrenadeSlot + 1)) - 1) and not 1; { slots 1..11 }
  for A := atShells to atSlugs do
    FStats.Ammo[A] := FStats.MaxAmmo[A];
  { The Reckoning's weapons when their models are there (-game xatrix) }
  { and Ground Zero's (-game rogue) }
  for I := IonRipperSlot to TeslaSlot do
    if Pak.FileExists(WeaponDefs[I].ViewModel) then
    begin
      FStats.WeaponMask := FStats.WeaponMask or (1 shl I);
      if WeaponDefs[I].AmmoType <> atNone then
        FStats.Ammo[WeaponDefs[I].AmmoType] := FStats.MaxAmmo[WeaponDefs[I].AmmoType];
    end;
  FStats.ArmorType := 3;
  FStats.Armor := 200;
  FStats.Health := Max(FStats.Health, 100);
  FStats.Keys := $1FF;
  if FHud <> nil then
    FHud.ShowMessage('All weapons, ammo, armor and keys');
end;

function TQuakeWorld.CheatGiveItem(const AName: String): Boolean;
var
  I: Integer;
begin
  for I := Low(ItemDefs) to High(ItemDefs) do
    if SameText(ItemDefs[I].Name, AName) or SameText(ItemDefs[I].ClassName, AName) then
    begin
      Result := GiveItem(@ItemDefs[I]);
      if Result and (FHud <> nil) then
        FHud.ShowMessage(ItemDefs[I].Name, 2);
      Exit(True);
    end;
  Result := False;
end;

procedure TQuakeWorld.CheatPowerup(const Quad: Boolean);
begin
  if Quad then
    GiveItem(FindItemDef('item_quad'))
  else
    GiveItem(FindItemDef('item_invulnerability'));
end;

procedure TQuakeWorld.CheatGodMode;
begin
  FStats.GodMode := not FStats.GodMode;
  if FHud <> nil then
    if FStats.GodMode then
      FHud.ShowMessage('god ON')
    else
      FHud.ShowMessage('god OFF');
end;

end.
