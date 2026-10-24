{ Quake 2 entity definitions: items, pickups, monsters, triggers and projectiles. }
unit QuakeEntities;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes, CastleQuaternions, CastleUtils,
  CastleSoundEngine, CastleBehaviors, CastleColors, CastleRenderOptions,
  QuakePak, QuakeBsp, QuakeMd2, QuakeLight, QuakeSound, QuakeHud, QuakeParticles, QuakeSprite, QuakeSettings,
  QuakeMonsterAttacks, QuakeMonsterMoves, QuakeTrace;

type
  TItemCategory = (icWeapon, icAmmo, icHealth, icArmor, icPowerup, icKey);

  { Static description of a Quake 2 item classname }
  TQuakeItemDef = record
    ClassName: String;
    Category: TItemCategory;
    Model: String;
    Icon: String;      { pics/<Icon>.pcx }
    Name: String;
    Sound: String;
    Weapon: Integer;   { weapon slot for icWeapon }
    AmmoType: TAmmoType;
    Amount: Integer;   { ammo / health / armor amount, or key bit }
    Param: Integer;    { armor type, max health, powerup kind... }
  end;
  PQuakeItemDef = ^TQuakeItemDef;

  { Static description of a Quake 2 weapon slot }
  TQuakeWeaponDef = record
    Name: String;
    ViewModel: String;
    Icon: String;
    AmmoType: TAmmoType;
    AmmoPerShot: Integer;
    Sound: String;
  end;

  { Attack kinds (TAttackKind, akMelee ...) are in QuakeMonsterAttacks }

  { Static description of a Quake 2 monster classname }
  TQuakeMonsterDef = record
    ClassName: String;
    Model: String;
    Skin: Integer;
    Health: Integer;
    Speed: Single;
    Attack: TAttackKind;
    Damage: Integer;
    AttackRange: Single;
    AttackCooldown: Single;
    Flying: Boolean;
    SoundDir: String;  { sound/<SoundDir>/ }
    SightSound, PainSound, DeathSound, AttackSound: String;
  end;
  PQuakeMonsterDef = ^TQuakeMonsterDef;

  { Single active 3D pickup entity in the world.
    A TCastleBehavior of its Transform, inspectable in the CGE inspector. }
  TQuakePickup = class(TCastleBehavior)
  strict private
    function GetItemName: String;
    function GetEntityClass: String;
  public
    Def: PQuakeItemDef;
    Entity: TQuakeEntity;
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Origin: TVector3;
    RotationAngle: Single;
    Collected: Boolean;
    { Re-light the model 10 times a second (light styles flicker) }
    LightTimer: Single;
    constructor CreatePickup(const AParent: TCastleTransform; const ADef: PQuakeItemDef;
      const AEntity: TQuakeEntity; const Pos: TVector3);
    destructor Destroy; override;
    procedure UpdatePickup(const SecondsPassed: Single);
  published
    property EntityClass: String read GetEntityClass;
    property ItemName: String read GetItemName;
    property IsCollected: Boolean read Collected;
  end;

  TQuakePickupList = specialize TObjectList<TQuakePickup>;

  { msDuck is last so savegames' state numbers stay valid }
  TMonsterState = (msIdle, msChase, msAttack, msPain, msDying, msDead, msDuck);
  { Quake 2 POWER_ARMOR_NONE / SCREEN / SHIELD }
  TPowerArmorType = (paNone, paScreen, paShield);

  TQuakeMonster = class;

  TEntityTraceFunc = function(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer;
    const Ignore: TObject): TQuakeTrace of object;
  TMonsterAttackEvent = procedure(const Monster: TQuakeMonster) of object;

  { Quake 2 p_trail.c: up to 8 spots the player passed, a new one each time
    the newest went out of the player's sight. Monsters that lost sight of
    the player follow it (oldest first), which takes them around corners. }
  TQuakePlayerTrail = class
  public
    const
      Length = 8;
    var
      Spots: array[0..Length - 1] of TVector3;
      Times: array[0..Length - 1] of Single;
      Count: Integer;
      { Game time, set by the world every frame }
      Now: Single;
    procedure Clear;
    procedure Add(const Pos: TVector3);
    function LastSpot: TVector3;
    { Oldest spot newer than AfterTime; False if none }
    function FirstAfter(const AfterTime: Single; out Pos: TVector3; out Time: Single): Boolean;
  end;
  { Pick an entity by targetname (random one if several, like G_PickTarget) }
  TPickTargetEvent = function(const ATargetName: String): TQuakeEntity of object;
  TUseTargetsEvent = procedure(const ATarget: String) of object;

  { Active 3D monster in the world.
    A TCastleBehavior of its Transform, inspectable in the CGE inspector. }
  TQuakeMonster = class(TCastleBehavior)
  private
    FLightTimer: Single;
    FSightTimer: Single;
    FFallSpeed: Single;
    FDetourDir: TVector3;
    FDetourTime: Single;
    FDetourSide: Single;
    FDuckTime: Single;
    FAttackFired: Boolean;
    { Quake 2 attack sequences of this monster type and the one playing
      (its first model frame in FAttackFirst) }
    FAttackSeqs: TMonsterAttackSeqs;
    FAttack: TMonsterAttack;
    FAttackFirst: Integer;
    { Quake 2 walk / run loops (QuakeMonsterMoves) and the one playing }
    FWalkSeq, FRunSeq: TMonsterMoveSeq;
    FMove: TMonsterMoveAnim;
    FMoveFirst: Integer;
    FMoveRun: Boolean;
    { trigger_monsterjump: flying through the air with this velocity (CGE) }
    FJumping: Boolean;
    FJumpVel: TVector3;
    { Placed on the floor with traces (Quake 2 M_droptofloor) }
    FDropped: Boolean;
    FIdleTimer: Single;
    FLostSightTime: Single;
    { Losing the player (Quake 2 AI_PURSUIT_LAST_SEEN): go where he was
      last seen, then along the player trail }
    FLastSighting: TVector3;
    FHasLastSighting: Boolean;
    FTrailTime: Single;
    FTrailGoal: TVector3;
    FHasTrailGoal: Boolean;
    FSearched: Boolean;
    FWalking: Boolean;
    { Power armor absorbed a hit recently: show the green shell (powerarmor_time) }
    FPowerArmorFlash: Single;
    { Seconds to stand at the current path_corner ("wait") }
    FPauseTime: Single;
    { Fraction of the attack animation at which the attack happens }
    function AttackFirePoint: Single;
    { Start a Quake 2 attack sequence for the distance; False if the
      monster has none (generic attack) }
    function StartAttackSeq(const Dist: Single): Boolean;
    { soldier attack3 (duck and shoot) for a dodge; PauseTime: Quake 2's
      pausetime from now }
    function StartDodgeAttack(const PauseTime: Single): Boolean;
    procedure AttackSeqFire(const ShotIndex: Integer);
    procedure UpdateJump(const SecondsPassed: Single);
    function MTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer = MASK_MONSTERSOLID): TQuakeTrace;
    procedure SetOrigin(const Q: TVector3);
    function OnGroundTrace: Boolean;
    { Quake 2 SV_movestep / M_CheckBottom: Move in Quake units }
    function StepMove(const Move: TVector3): Boolean;
    function CheckBottom(const Pos: TVector3): Boolean;
    procedure DropToFloor;
    { Nothing opaque between two CGE points (Quake 2 visible()) }
    function SightClear(const FromPos, ToPos: TVector3): Boolean;
    { Move along Dir (with wall sliding) unless it walks off a ledge }
    function TryMove(const Dir: TVector3; const SecondsPassed: Single;
      const SpeedScale: Single = 1): Boolean;
    { Move towards WantDir, detouring around obstacles }
    { Play the walk / run frames; their distance sets the speed of TryMove }
    procedure AdvanceMove(const Run: Boolean; const SecondsPassed: Single);
    procedure Steer(const WantDir: TVector3; const SecondsPassed: Single;
      const SpeedScale: Single = 1);
    { Turn (at most 360 degrees per second) to look along Delta }
    procedure FaceTowards(const Delta: TVector3; const SecondsPassed: Single);
    { Distance to an entity's origin (horizontal unless flying); Delta = CGE vector to it }
    function DistanceTo(const Ent: TQuakeEntity; out Delta: TVector3): Single;
    { Idle: walk the path_corner chain (Quake 2 ai_walk / path_corner_touch) }
    procedure Patrol(const SecondsPassed: Single);
    { Alerted with a point_combat goal: run there without attacking }
    procedure GoToCombatPoint(const SecondsPassed: Single);
    procedure SetWalking(const Value: Boolean);
    function GetEntityClass: String;
    procedure SetState(const NewState: TMonsterState);
    { Where to run when the player can't be seen; False: towards him }
    function PursuitGoal(out Goal: TVector3): Boolean;
    procedure StickToFloor(const SecondsPassed: Single);
  public
    Def: PQuakeMonsterDef;
    Entity: TQuakeEntity;
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    State: TMonsterState;
    Health: Integer;
    FacingAngle: Single;
    StateTimer: Single;
    AttackCooldown: Single;
    Alerted: Boolean;
    CanSeePlayer: Boolean;
    Gibbed: Boolean;
    KillCounted: Boolean;
    { turret_driver: an infantry that only aims its turret_breach (placed,
      turned and fired by TQuakeWorld.UpdateTurrets); no pain, gibbed on
      death (gib_health 0) }
    TurretDriver: Boolean;
    { The driver took its breach (turret_driver_link), once }
    TurretLinked: Boolean;
    { Targets fired on death (monster_death_use); empty when "target" was a path }
    DeathTarget: String;
    { path_corner walked to while idle }
    MoveTarget: TQuakeEntity;
    { point_combat targetname to run to when alerted; GoalEntity while running }
    CombatTarget: String;
    GoalEntity: TQuakeEntity;
    { Reached a "hold" point_combat: attack from here, don't chase (AI_STAND_GROUND) }
    HoldGround: Boolean;
    { Power armor (monster_brain: screen 100) and its remaining cells }
    PowerArmorType: TPowerArmorType;
    PowerArmorPower: Integer;
    { Quake 2 monster spawnflags: AMBUSH (1) doesn't wake from noise unless
      it also sees the player, nor from other monsters spotting him;
      TRIGGER_SPAWN (2) stays Dormant (absent) until its targetname is used }
    Ambush: Boolean;
    Dormant: Boolean;
    OnAttack: TMonsterAttackEvent;
    { The shot OnAttack should fire: kind, damage (per bullet / pellet),
      bullets for hitscan, reach for melee }
    AttackKind: TAttackKind;
    AttackDamage: Integer;
    AttackBullets: Integer;
    AttackReach: Single;
    { Quake 2 bounding box around the origin (Quake coordinates) }
    BoxMins, BoxMaxs: TVector3;
    { Called when the monster finds the player (Quake 2 FoundTarget, which
      makes it level.sight_entity for others to notice) }
    OnFoundTarget: TMonsterAttackEvent;
    OnPickTarget: TPickTargetEvent;
    OnUseTargets: TUseTargetsEvent;
    { Medic (m_medic.c): the corpse it goes to revive (set by the world's
      medic_FindDeadMonster), and on a corpse the medic coming for it }
    HealTarget, Healer: TQuakeMonster;
    { Seconds of the healing cable so far (revives at 1 s, attack43) }
    HealTime: Single;
    { Called on the medic when its patient got up (the world counts it) }
    OnRevived: TMonsterAttackEvent;
    { Origin in Quake coordinates }
    function Origin: TVector3;
    { The box shots and players collide with (shorter while ducking) }
    function ShotBoxMaxs: TVector3;
    constructor CreateMonster(const AParent: TCastleTransform; const ADef: PQuakeMonsterDef;
      const AEntity: TQuakeEntity; const Pos: TVector3; const Yaw: Single);
    destructor Destroy; override;
    { Eye position in CGE space }
    function EyePos: TVector3;
    { Sort "target" into a patrol path, a combat point or death targets,
      like Quake 2 monster_start_go. Call once OnPickTarget is set. }
    procedure ResolveTargets;
    procedure UpdateAI(const SecondsPassed: Single; const PlayerPos: TVector3);
    procedure TakeDamage(const Dmg: Integer);
    { Throw the class's gibs (or explode) and vanish }
    procedure Gib(const Dmg: Integer);
    { Health at or below which the body is gibbed (gib_health) }
    function GibHealth: Integer;
    { turret_driver: notice the player (no moving, no attacks) }
    procedure UpdateDriverSight(const PlayerPos: TVector3);
    { A medic brought this corpse back: full health, standing, after the
      player (ED_CallSpawn + FoundTarget) }
    procedure Revive;
    { The medic's walk to its patient and the healing cable; False when it
      has no (valid) patient }
    function UpdateMedic(const SecondsPassed: Single): Boolean;
    function IsMedic: Boolean;
    { Part of Dmg the power armor absorbs (and uses up) }
    function AbsorbPowerArmor(const Dmg: Integer): Integer;
    procedure Alert;
    function IsAlive: Boolean;
    { Would it notice something at Delta from it that it can see (Quake 2
      FindTarget): within 1000 units; beyond melee range only in front
      (cos > 0.3), or within 500 units also when the player just fired }
    function WouldNotice(const Delta: TVector3): Boolean;
    { Clear line from the monster's eye to a point }
    function HasLineOfSight(const Target: TVector3): Boolean;
    { TRIGGER_SPAWN: appear now (monster_triggered_spawn) }
    procedure Spawn;
    procedure SetDormant(const Value: Boolean);
    { A shot of the player will reach it in Eta seconds (Quake 2
      monsterinfo.dodge, from check_dodge): soldiers, infantry, gunners,
      medics and iron maidens duck a quarter of the time, so it may fly over }
    procedure Dodge(const Eta: Single);
    { Touching a trigger_monsterjump: horizontal velocity always, the
      upward speed when on the ground (Quake 2 trigger_monsterjump_touch) }
    procedure MonsterJump(const HorizVel: TVector3; const UpSpeed: Single);
    property Jumping: Boolean read FJumping;
    { Has a dodge (duck) reaction }
    function CanDodge: Boolean;
    { Owns the scene: used to map ray hits back to monsters }
    function OwnsTransform(const T: TCastleTransform): Boolean;
    { Restore from a savegame: position, facing, health, alive / dead / gibbed }
    procedure RestoreState(const APos: TVector3; const AFacing: Single; const AHealth: Integer;
      const AState: TMonsterState; const AAlerted, AGibbed: Boolean);
  published
    property EntityClass: String read GetEntityClass;
    property MonsterState: TMonsterState read State;
    property HitPoints: Integer read Health;
    property IsAlerted: Boolean read Alerted;
    property SeesPlayer: Boolean read CanSeePlayer;
    property Facing: Single read FacingAngle;
    property PowerArmor: Integer read PowerArmorPower;
    property IsAmbush: Boolean read Ambush;
    property IsDormant: Boolean read Dormant;
  end;

  TQuakeMonsterList = specialize TObjectList<TQuakeMonster>;

  TProjectileKind = (pkBlasterBolt, pkRocket, pkGrenade, pkHandGrenade, pkBfg);

  { Active projectile (blaster bolt, rocket, grenade, BFG ball) }
  TQuakeProjectile = class
  public
    Kind: TProjectileKind;
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Sprite: TQuakeSpriteInstance;
    Velocity: TVector3;
    Damage: Integer;
    SplashDamage: Integer;
    SplashRadius: Single;
    Life: Single;
    FromPlayer: Boolean;
    Owner: TQuakeMonster;
    constructor Create(const Parent: TCastleTransform; const AKind: TProjectileKind;
      const Pos, Vel: TVector3; const ADamage: Integer; const AFromPlayer: Boolean);
    destructor Destroy; override;
  end;

  TQuakeProjectileList = specialize TObjectList<TQuakeProjectile>;

  { target_speaker: ambient loop or triggered one-shot sound at a position.
    A TCastleBehavior next to the TCastleSoundSource on its Transform. }
  TQuakeSpeaker = class(TCastleBehavior)
  strict private
    FNoise: String;
    FLooped: Boolean;
    FAttenuation: Single;
    FPath: String;
    FLoopOn: Boolean;
    FSound: TCastleSound;
    function GetPlaying: Boolean;
  public
    Entity: TQuakeEntity;
    Transform: TCastleTransform;
    Source: TCastleSoundSource;
    constructor CreateSpeaker(const AParent: TCastleTransform; const AEntity: TQuakeEntity);
    destructor Destroy; override;
    { Toggle a looped speaker, or play a one-shot one }
    procedure Activate;
    { Sound path, e.g. sound/world/amb10.wav }
    property Path: String read FPath;
  published
    property Noise: String read FNoise;
    property Looped: Boolean read FLooped;
    property Attenuation: Single read FAttenuation;
    property Playing: Boolean read GetPlaying;
  end;

  TQuakeSpeakerList = specialize TObjectList<TQuakeSpeaker>;

  TPropKind = (pkExplobox, pkBanner, pkDeadSoldier, pkSatelliteDish, pkStroggShip, pkGibHead,
    pkViper, pkBigViper, pkViperBomb, pkBlackHole, pkEasterTank, pkEasterChick, pkEasterChick2,
    pkTeleporter);

  { misc_* decorations: exploding barrels, banners, corpses, the satellite dish,
    flying Strogg ships and vipers (follow path_corners when triggered), gib
    heads, the big viper, viper bombs (fall when triggered, explode on
    impact), the black hole and the "easter egg" tank / chick poses. }
  TQuakeProp = class(TCastleBehavior)
  strict private
    function GetEntityClass: String;
  public
    Kind: TPropKind;
    Entity: TQuakeEntity;
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Health: Integer;
    Destroyed: Boolean;
    { Strogg ship flight }
    Flying: Boolean;
    FlySpeed: Single;
    FlyTarget: TVector3;
    FlyCorner: TQuakeEntity;
    { Viper bomb fall (Quake 2 MOVETYPE_TOSS) }
    Falling: Boolean;
    Velocity: TVector3;
    { Looping frame range (black hole, easter tank / chick), 10 frames a second }
    AnimFirst, AnimLast: Integer;
    AnimTime: Single;
    { Re-light the model 10 times a second (light styles flicker) }
    LightTimer: Single;
    constructor CreateProp(const AParent: TCastleTransform; const AKind: TPropKind;
      const AEntity: TQuakeEntity);
    destructor Destroy; override;
    procedure UpdateProp(const SecondsPassed: Single);
    function OwnsTransform(const T: TCastleTransform): Boolean;
  published
    property EntityClass: String read GetEntityClass;
    property PropKind: TPropKind read Kind;
    property HitPoints: Integer read Health;
    property IsDestroyed: Boolean read Destroyed;
    property IsFlying: Boolean read Flying;
  end;

  TQuakePropList = specialize TObjectList<TQuakeProp>;

  { target_laser: a beam from its origin along its direction until it hits a wall. }
  TQuakeLaser = class(TCastleBehavior)
  strict private
    FOn: Boolean;
    FDamage: Integer;
    procedure SetOn(const Value: Boolean);
  public
    Entity: TQuakeEntity;
    Transform: TCastleTransform;
    Beam: TCastleBox;
    Origin, Direction: TVector3;
    Length: Single;
    constructor CreateLaser(const AParent: TCastleTransform; const AEntity: TQuakeEntity;
      const ADirection: TVector3);
    destructor Destroy; override;
    { Stretch the beam to Len units }
    procedure SetLength(const Len: Single);
  published
    property IsOn: Boolean read FOn write SetOn;
    property Damage: Integer read FDamage;
  end;

  TQuakeLaserList = specialize TObjectList<TQuakeLaser>;

  { Trigger brush (trigger_multiple, trigger_once, trigger_push, ...) }
  TQuakeTrigger = class
  public
    Entity: TQuakeEntity;
    Box: TBox3D;       { CGE space }
    Enabled: Boolean;
    Fired: Boolean;
    Cooldown: Single;
    constructor Create(const AEntity: TQuakeEntity; const ABox: TBox3D);
    function Contains(const Pos: TVector3; const Radius: Single = 16.0): Boolean;
  end;

  TQuakeTriggerList = specialize TObjectList<TQuakeTrigger>;

const
  KEY_DATA_CD      = 1 shl 0;
  KEY_POWER_CUBE   = 1 shl 1;
  KEY_PYRAMID      = 1 shl 2;
  KEY_DATA_SPINNER = 1 shl 3;
  KEY_PASS         = 1 shl 4;
  KEY_BLUE         = 1 shl 5;
  KEY_RED          = 1 shl 6;
  KEY_COMMANDER    = 1 shl 7;
  KEY_AIRSTRIKE    = 1 shl 8;

  { Weapon slots: 1 Blaster .. 10 BFG10K, 11 Hand Grenades }
  WeaponSlots = 11;

  POWERUP_QUAD = 1;
  POWERUP_INVULN = 2;
  POWERUP_ADRENALINE = 3;
  POWERUP_BANDOLIER = 4;
  POWERUP_PACK = 5;
  POWERUP_OTHER = 6;

  ItemDefs: array[0..41] of TQuakeItemDef = (
    (ClassName: 'weapon_shotgun'; Category: icWeapon; Model: 'models/weapons/g_shotg/tris.md2'; Icon: 'w_shotgun'; Name: 'Shotgun'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 2; AmmoType: atShells; Amount: 10; Param: 0),
    (ClassName: 'weapon_supershotgun'; Category: icWeapon; Model: 'models/weapons/g_shotg2/tris.md2'; Icon: 'w_sshotgun'; Name: 'Super Shotgun'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 3; AmmoType: atShells; Amount: 10; Param: 0),
    (ClassName: 'weapon_machinegun'; Category: icWeapon; Model: 'models/weapons/g_machn/tris.md2'; Icon: 'w_machinegun'; Name: 'Machinegun'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 4; AmmoType: atBullets; Amount: 50; Param: 0),
    (ClassName: 'weapon_chaingun'; Category: icWeapon; Model: 'models/weapons/g_chain/tris.md2'; Icon: 'w_chaingun'; Name: 'Chaingun'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 5; AmmoType: atBullets; Amount: 50; Param: 0),
    (ClassName: 'weapon_grenadelauncher'; Category: icWeapon; Model: 'models/weapons/g_launch/tris.md2'; Icon: 'w_glauncher'; Name: 'Grenade Launcher'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 6; AmmoType: atGrenades; Amount: 5; Param: 0),
    (ClassName: 'weapon_rocketlauncher'; Category: icWeapon; Model: 'models/weapons/g_rocket/tris.md2'; Icon: 'w_rlauncher'; Name: 'Rocket Launcher'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 7; AmmoType: atRockets; Amount: 5; Param: 0),
    (ClassName: 'weapon_hyperblaster'; Category: icWeapon; Model: 'models/weapons/g_hyperb/tris.md2'; Icon: 'w_hyperblaster'; Name: 'HyperBlaster'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 8; AmmoType: atCells; Amount: 50; Param: 0),
    (ClassName: 'weapon_railgun'; Category: icWeapon; Model: 'models/weapons/g_rail/tris.md2'; Icon: 'w_railgun'; Name: 'Railgun'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 9; AmmoType: atSlugs; Amount: 5; Param: 0),
    (ClassName: 'weapon_bfg'; Category: icWeapon; Model: 'models/weapons/g_bfg/tris.md2'; Icon: 'w_bfg'; Name: 'BFG10K'; Sound: 'sound/misc/w_pkup.wav'; Weapon: 10; AmmoType: atCells; Amount: 50; Param: 0),

    (ClassName: 'ammo_shells'; Category: icAmmo; Model: 'models/items/ammo/shells/medium/tris.md2'; Icon: 'a_shells'; Name: 'Shells'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atShells; Amount: 10; Param: 0),
    (ClassName: 'ammo_bullets'; Category: icAmmo; Model: 'models/items/ammo/bullets/medium/tris.md2'; Icon: 'a_bullets'; Name: 'Bullets'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atBullets; Amount: 50; Param: 0),
    (ClassName: 'ammo_grenades'; Category: icAmmo; Model: 'models/items/ammo/grenades/medium/tris.md2'; Icon: 'a_grenades'; Name: 'Grenades'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 11; AmmoType: atGrenades; Amount: 5; Param: 0),
    (ClassName: 'ammo_rockets'; Category: icAmmo; Model: 'models/items/ammo/rockets/medium/tris.md2'; Icon: 'a_rockets'; Name: 'Rockets'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atRockets; Amount: 5; Param: 0),
    (ClassName: 'ammo_cells'; Category: icAmmo; Model: 'models/items/ammo/cells/medium/tris.md2'; Icon: 'a_cells'; Name: 'Cells'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atCells; Amount: 50; Param: 0),
    (ClassName: 'ammo_slugs'; Category: icAmmo; Model: 'models/items/ammo/slugs/medium/tris.md2'; Icon: 'a_slugs'; Name: 'Slugs'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atSlugs; Amount: 10; Param: 0),

    (ClassName: 'item_health_small'; Category: icHealth; Model: 'models/items/healing/stimpack/tris.md2'; Icon: 'i_health'; Name: 'Stimpack'; Sound: 'sound/items/s_health.wav'; Weapon: 0; AmmoType: atNone; Amount: 2; Param: 1),
    (ClassName: 'item_health'; Category: icHealth; Model: 'models/items/healing/medium/tris.md2'; Icon: 'i_health'; Name: 'Medium Health'; Sound: 'sound/items/n_health.wav'; Weapon: 0; AmmoType: atNone; Amount: 10; Param: 0),
    (ClassName: 'item_health_large'; Category: icHealth; Model: 'models/items/healing/large/tris.md2'; Icon: 'i_health'; Name: 'Large Health'; Sound: 'sound/items/l_health.wav'; Weapon: 0; AmmoType: atNone; Amount: 25; Param: 0),
    (ClassName: 'item_health_mega'; Category: icHealth; Model: 'models/items/mega_h/tris.md2'; Icon: 'p_megahealth'; Name: 'Mega Health'; Sound: 'sound/items/m_health.wav'; Weapon: 0; AmmoType: atNone; Amount: 100; Param: 1),

    (ClassName: 'item_armor_shard'; Category: icArmor; Model: 'models/items/armor/shard/tris.md2'; Icon: 'i_jacketarmor'; Name: 'Armor Shard'; Sound: 'sound/misc/ar2_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 2; Param: 0),
    (ClassName: 'item_armor_jacket'; Category: icArmor; Model: 'models/items/armor/jacket/tris.md2'; Icon: 'i_jacketarmor'; Name: 'Jacket Armor'; Sound: 'sound/misc/ar1_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 25; Param: 1),
    (ClassName: 'item_armor_combat'; Category: icArmor; Model: 'models/items/armor/combat/tris.md2'; Icon: 'i_combatarmor'; Name: 'Combat Armor'; Sound: 'sound/misc/ar1_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 50; Param: 2),
    (ClassName: 'item_armor_body'; Category: icArmor; Model: 'models/items/armor/body/tris.md2'; Icon: 'i_bodyarmor'; Name: 'Body Armor'; Sound: 'sound/misc/ar3_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 100; Param: 3),

    (ClassName: 'item_quad'; Category: icPowerup; Model: 'models/items/quaddama/tris.md2'; Icon: 'p_quad'; Name: 'Quad Damage'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 30; Param: POWERUP_QUAD),
    (ClassName: 'item_invulnerability'; Category: icPowerup; Model: 'models/items/invulner/tris.md2'; Icon: 'p_invulnerability'; Name: 'Invulnerability'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 30; Param: POWERUP_INVULN),
    (ClassName: 'item_adrenaline'; Category: icPowerup; Model: 'models/items/adrenal/tris.md2'; Icon: 'p_adrenaline'; Name: 'Adrenaline'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_ADRENALINE),
    (ClassName: 'item_bandolier'; Category: icPowerup; Model: 'models/items/band/tris.md2'; Icon: 'p_bandolier'; Name: 'Bandolier'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_BANDOLIER),
    (ClassName: 'item_pack'; Category: icPowerup; Model: 'models/items/pack/tris.md2'; Icon: 'i_pack'; Name: 'Ammo Pack'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_PACK),
    (ClassName: 'item_silencer'; Category: icPowerup; Model: 'models/items/silencer/tris.md2'; Icon: 'p_silencer'; Name: 'Silencer'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_OTHER),
    (ClassName: 'item_breather'; Category: icPowerup; Model: 'models/items/breather/tris.md2'; Icon: 'p_rebreather'; Name: 'Rebreather'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_OTHER),
    (ClassName: 'item_enviro'; Category: icPowerup; Model: 'models/items/enviro/tris.md2'; Icon: 'p_envirosuit'; Name: 'Environment Suit'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_OTHER),
    (ClassName: 'item_power_screen'; Category: icPowerup; Model: 'models/items/armor/screen/tris.md2'; Icon: 'i_powerscreen'; Name: 'Power Screen'; Sound: 'sound/misc/ar3_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_OTHER),
    (ClassName: 'item_power_shield'; Category: icPowerup; Model: 'models/items/armor/shield/tris.md2'; Icon: 'i_powershield'; Name: 'Power Shield'; Sound: 'sound/misc/ar3_pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_OTHER),

    (ClassName: 'key_data_cd'; Category: icKey; Model: 'models/items/keys/data_cd/tris.md2'; Icon: 'k_datacd'; Name: 'Data CD'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_DATA_CD; Param: 0),
    (ClassName: 'key_power_cube'; Category: icKey; Model: 'models/items/keys/power/tris.md2'; Icon: 'k_powercube'; Name: 'Power Cube'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_POWER_CUBE; Param: 0),
    (ClassName: 'key_pyramid'; Category: icKey; Model: 'models/items/keys/pyramid/tris.md2'; Icon: 'k_pyramid'; Name: 'Pyramid Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_PYRAMID; Param: 0),
    (ClassName: 'key_data_spinner'; Category: icKey; Model: 'models/items/keys/spinner/tris.md2'; Icon: 'k_dataspin'; Name: 'Data Spinner'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_DATA_SPINNER; Param: 0),
    (ClassName: 'key_pass'; Category: icKey; Model: 'models/items/keys/pass/tris.md2'; Icon: 'k_security'; Name: 'Security Pass'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_PASS; Param: 0),
    (ClassName: 'key_blue_key'; Category: icKey; Model: 'models/items/keys/key/tris.md2'; Icon: 'k_bluekey'; Name: 'Blue Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_BLUE; Param: 0),
    (ClassName: 'key_red_key'; Category: icKey; Model: 'models/items/keys/red_key/tris.md2'; Icon: 'k_redkey'; Name: 'Red Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_RED; Param: 0),
    (ClassName: 'key_commander_head'; Category: icKey; Model: 'models/monsters/commandr/head/tris.md2'; Icon: 'k_comhead'; Name: 'Commander''s Head'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_COMMANDER; Param: 0),
    (ClassName: 'key_airstrike_target'; Category: icKey; Model: 'models/items/keys/target/tris.md2'; Icon: 'i_airstrike'; Name: 'Airstrike Marker'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_AIRSTRIKE; Param: 0)
  );

  { Weapon slots 1..11 (key 0 selects slot 10, G slot 11) }
  WeaponDefs: array[1..WeaponSlots] of TQuakeWeaponDef = (
    (Name: 'Blaster'; ViewModel: 'models/weapons/v_blast/tris.md2'; Icon: 'w_blaster'; AmmoType: atNone; AmmoPerShot: 0; Sound: 'sound/weapons/blastf1a.wav'),
    (Name: 'Shotgun'; ViewModel: 'models/weapons/v_shotg/tris.md2'; Icon: 'w_shotgun'; AmmoType: atShells; AmmoPerShot: 1; Sound: 'sound/weapons/shotgf1b.wav'),
    (Name: 'Super Shotgun'; ViewModel: 'models/weapons/v_shotg2/tris.md2'; Icon: 'w_sshotgun'; AmmoType: atShells; AmmoPerShot: 2; Sound: 'sound/weapons/sshotf1b.wav'),
    (Name: 'Machinegun'; ViewModel: 'models/weapons/v_machn/tris.md2'; Icon: 'w_machinegun'; AmmoType: atBullets; AmmoPerShot: 1; Sound: 'sound/weapons/machgf1b.wav'),
    (Name: 'Chaingun'; ViewModel: 'models/weapons/v_chain/tris.md2'; Icon: 'w_chaingun'; AmmoType: atBullets; AmmoPerShot: 1; Sound: 'sound/weapons/machgf2b.wav'),
    (Name: 'Grenade Launcher'; ViewModel: 'models/weapons/v_launch/tris.md2'; Icon: 'w_glauncher'; AmmoType: atGrenades; AmmoPerShot: 1; Sound: 'sound/weapons/grenlf1a.wav'),
    (Name: 'Rocket Launcher'; ViewModel: 'models/weapons/v_rocket/tris.md2'; Icon: 'w_rlauncher'; AmmoType: atRockets; AmmoPerShot: 1; Sound: 'sound/weapons/rocklf1a.wav'),
    (Name: 'HyperBlaster'; ViewModel: 'models/weapons/v_hyperb/tris.md2'; Icon: 'w_hyperblaster'; AmmoType: atCells; AmmoPerShot: 1; Sound: 'sound/weapons/hyprbf1a.wav'),
    (Name: 'Railgun'; ViewModel: 'models/weapons/v_rail/tris.md2'; Icon: 'w_railgun'; AmmoType: atSlugs; AmmoPerShot: 1; Sound: 'sound/weapons/railgf1a.wav'),
    (Name: 'BFG10K'; ViewModel: 'models/weapons/v_bfg/tris.md2'; Icon: 'w_bfg'; AmmoType: atCells; AmmoPerShot: 50; Sound: 'sound/weapons/bfg__f1y.wav'),
    { Thrown on release; picking up grenades gives it (Quake 2 "Grenades") }
    (Name: 'Hand Grenades'; ViewModel: 'models/weapons/v_handgr/tris.md2'; Icon: 'w_hgrenade'; AmmoType: atGrenades; AmmoPerShot: 1; Sound: 'sound/weapons/hgrent1a.wav')
  );

  AmmoIcons: array[TAmmoType] of String = ('', 'a_shells', 'a_bullets', 'a_grenades',
    'a_rockets', 'a_cells', 'a_slugs');

  { Built-in monster definitions. At startup data/monsters.castle-transform
    (TQuakeMonsterType components, editable in the CGE editor) overrides
    and extends them in MonsterDefs. }
  DefaultMonsterDefs: array[0..18] of TQuakeMonsterDef = (
    (ClassName: 'monster_soldier_light'; Model: 'models/monsters/soldier/tris.md2'; Skin: 0; Health: 20; Speed: 120; Attack: akBlaster; Damage: 5; AttackRange: 900; AttackCooldown: 1.6; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain2'; DeathSound: 'soldeth1'; AttackSound: 'solatck2'),
    (ClassName: 'monster_soldier'; Model: 'models/monsters/soldier/tris.md2'; Skin: 2; Health: 30; Speed: 120; Attack: akPellets; Damage: 2; AttackRange: 700; AttackCooldown: 1.6; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain1'; DeathSound: 'soldeth1'; AttackSound: 'solatck1'),
    (ClassName: 'monster_soldier_ss'; Model: 'models/monsters/soldier/tris.md2'; Skin: 4; Health: 40; Speed: 120; Attack: akHitscan; Damage: 2; AttackRange: 900; AttackCooldown: 0.9; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain3'; DeathSound: 'soldeth3'; AttackSound: 'solatck3'),
    (ClassName: 'monster_infantry'; Model: 'models/monsters/infantry/tris.md2'; Skin: 0; Health: 100; Speed: 110; Attack: akHitscan; Damage: 3; AttackRange: 900; AttackCooldown: 0.9; Flying: False; SoundDir: 'infantry'; SightSound: 'infsght1'; PainSound: 'infpain1'; DeathSound: 'infdeth1'; AttackSound: 'infatck1'),
    (ClassName: 'monster_gunner'; Model: 'models/monsters/gunner/tris.md2'; Skin: 0; Health: 175; Speed: 110; Attack: akGrenade; Damage: 50; AttackRange: 800; AttackCooldown: 1.8; Flying: False; SoundDir: 'gunner'; SightSound: 'sight1'; PainSound: 'gunpain1'; DeathSound: 'death1'; AttackSound: 'gunatck3'),
    (ClassName: 'monster_berserk'; Model: 'models/monsters/berserk/tris.md2'; Skin: 0; Health: 240; Speed: 160; Attack: akMelee; Damage: 20; AttackRange: 70; AttackCooldown: 1.0; Flying: False; SoundDir: 'berserk'; SightSound: 'sight'; PainSound: 'berpain2'; DeathSound: 'berdeth2'; AttackSound: 'attack'),
    (ClassName: 'monster_gladiator'; Model: 'models/monsters/gladiatr/tris.md2'; Skin: 0; Health: 400; Speed: 120; Attack: akRail; Damage: 50; AttackRange: 1200; AttackCooldown: 2.5; Flying: False; SoundDir: 'gladiator'; SightSound: 'sight'; PainSound: 'pain'; DeathSound: 'glddeth2'; AttackSound: 'railgun'),
    (ClassName: 'monster_flyer'; Model: 'models/monsters/flyer/tris.md2'; Skin: 0; Health: 50; Speed: 180; Attack: akBlaster; Damage: 5; AttackRange: 800; AttackCooldown: 1.0; Flying: True; SoundDir: 'flyer'; SightSound: 'flysght1'; PainSound: 'flypain1'; DeathSound: 'flydeth1'; AttackSound: 'flyatck3'),
    (ClassName: 'monster_parasite'; Model: 'models/monsters/parasite/tris.md2'; Skin: 0; Health: 175; Speed: 140; Attack: akMelee; Damage: 10; AttackRange: 90; AttackCooldown: 0.6; Flying: False; SoundDir: 'parasite'; SightSound: 'parsght1'; PainSound: 'parpain1'; DeathSound: 'pardeth1'; AttackSound: 'paratck1'),
    (ClassName: 'monster_tank'; Model: 'models/monsters/tank/tris.md2'; Skin: 0; Health: 750; Speed: 90; Attack: akRocket; Damage: 50; AttackRange: 1200; AttackCooldown: 2.0; Flying: False; SoundDir: 'tank'; SightSound: 'sight1'; PainSound: 'tnkpain2'; DeathSound: 'tnkdeth2'; AttackSound: 'tnkatck1'),
    (ClassName: 'monster_tank_commander'; Model: 'models/monsters/tank/tris.md2'; Skin: 2; Health: 1000; Speed: 90; Attack: akRocket; Damage: 50; AttackRange: 1200; AttackCooldown: 1.6; Flying: False; SoundDir: 'tank'; SightSound: 'sight1'; PainSound: 'tnkpain2'; DeathSound: 'tnkdeth2'; AttackSound: 'tnkatck1'),
    (ClassName: 'monster_medic'; Model: 'models/monsters/medic/tris.md2'; Skin: 0; Health: 300; Speed: 110; Attack: akBlaster; Damage: 4; AttackRange: 900; AttackCooldown: 0.4; Flying: False; SoundDir: 'medic'; SightSound: 'medsght1'; PainSound: 'medpain1'; DeathSound: 'meddeth1'; AttackSound: 'medatck1'),
    (ClassName: 'monster_chick'; Model: 'models/monsters/bitch/tris.md2'; Skin: 0; Health: 175; Speed: 130; Attack: akRocket; Damage: 50; AttackRange: 1000; AttackCooldown: 2.0; Flying: False; SoundDir: 'chick'; SightSound: 'chksght1'; PainSound: 'chkpain1'; DeathSound: 'chkdeth1'; AttackSound: 'chkatck2'),
    (ClassName: 'monster_mutant'; Model: 'models/monsters/mutant/tris.md2'; Skin: 0; Health: 300; Speed: 200; Attack: akMelee; Damage: 15; AttackRange: 80; AttackCooldown: 0.7; Flying: False; SoundDir: 'mutant'; SightSound: 'mutsght1'; PainSound: 'mutpain1'; DeathSound: 'mutdeth1'; AttackSound: 'mutatck1'),
    (ClassName: 'monster_brain'; Model: 'models/monsters/brain/tris.md2'; Skin: 0; Health: 300; Speed: 100; Attack: akMelee; Damage: 15; AttackRange: 90; AttackCooldown: 0.9; Flying: False; SoundDir: 'brain'; SightSound: 'brnsght1'; PainSound: 'brnpain1'; DeathSound: 'brndeth1'; AttackSound: 'melee1'),
    (ClassName: 'monster_floater'; Model: 'models/monsters/float/tris.md2'; Skin: 0; Health: 200; Speed: 100; Attack: akBlaster; Damage: 1; AttackRange: 800; AttackCooldown: 0.6; Flying: True; SoundDir: 'floater'; SightSound: 'fltsght1'; PainSound: 'fltpain1'; DeathSound: 'fltdeth1'; AttackSound: 'fltatck1'),
    (ClassName: 'monster_hover'; Model: 'models/monsters/hover/tris.md2'; Skin: 0; Health: 240; Speed: 120; Attack: akBlaster; Damage: 1; AttackRange: 900; AttackCooldown: 0.8; Flying: True; SoundDir: 'hover'; SightSound: 'hovsght1'; PainSound: 'hovpain1'; DeathSound: 'hovdeth1'; AttackSound: 'hovatck1'),
    (ClassName: 'monster_flipper'; Model: 'models/monsters/flipper/tris.md2'; Skin: 0; Health: 50; Speed: 150; Attack: akMelee; Damage: 5; AttackRange: 70; AttackCooldown: 0.6; Flying: True; SoundDir: 'flipper'; SightSound: 'flpsght1'; PainSound: 'flppain1'; DeathSound: 'flpdeth1'; AttackSound: 'flpatck1'),
    (ClassName: 'monster_supertank'; Model: 'models/monsters/boss1/tris.md2'; Skin: 0; Health: 1500; Speed: 80; Attack: akRocket; Damage: 50; AttackRange: 1500; AttackCooldown: 1.2; Flying: False; SoundDir: 'bosstank'; SightSound: 'btkunqv1'; PainSound: 'btkpain1'; DeathSound: 'btkdeth1'; AttackSound: 'btkunqv2')
  );

var
  { Monster definitions in use: DefaultMonsterDefs, then the overrides of
    the monster types design. Change only before monsters are created
    (FindMonsterDef returns pointers into it). }
  MonsterDefs: array of TQuakeMonsterDef;

{ Lookup tables (nil when the classname is unknown) }
function FindItemDef(const AClassName: String): PQuakeItemDef;
function FindMonsterDef(const AClassName: String): PQuakeMonsterDef;

{ Full sound path for a monster sound name }
function MonsterSound(const Def: PQuakeMonsterDef; const Name: String): String;
{ The monster's idle / search sound found in the PAK ('' if none) }
function MonsterIdleSound(const Def: PQuakeMonsterDef): String;
function MonsterSearchSound(const Def: PQuakeMonsterDef): String;

var
  { Quake 2 "notarget" cheat: monsters don't notice the player
    (also keeps the CI screenshot comparison free of combat) }
  NoTarget: Boolean = False;
  { The player fired in the last second (Quake 2 show_hostile): monsters
    nearby notice him even when he's not in front of them }
  PlayerShowHostile: Boolean = False;
  { The player's trail (created and fed by TQuakeWorld) }
  PlayerTrail: TQuakePlayerTrail;
  { The player's box (CGE space), set by the world each frame: monsters
    don't walk into it (only used without EntityTrace) }
  PlayerBlockBox: TBox3D;
  { Box traces through the world for entities (map brushes, movers,
    monster boxes, the player's box; Quake coordinates), skipping Ignore.
    Set by TQuakeWorld; without it monsters use CGE collisions. }
  EntityTrace: TEntityTraceFunc;

{ Quake 2 bounding box of a monster class (mins / maxs around its origin),
  moved so the bottom is at -24 like every monster's origin here }
procedure MonsterBoxSize(const MonsterClass: String; out Mins, Maxs: TVector3);

type
  TMonsterGibs = record
    { Pieces thrown when gibbed (the *_die functions' ThrowGib / ThrowHead) }
    Pieces: array of TGibPiece;
    { Health at or below which the body is gibbed (gib_health) }
    GibHealth: Integer;
    { BecomeExplosion1 on death instead of a corpse (the flyer) }
    Explodes: Boolean;
  end;

{ Quake 2 gibs of a monster class (generic meat and bones for others) }
function MonsterGibs(const MonsterClass: String): TMonsterGibs;

implementation

function MonsterGibs(const MonsterClass: String): TMonsterGibs;

  procedure Add(const Model: String; const Count: Integer; const Metallic: Boolean = False);
  begin
    SetLength(Result.Pieces, Length(Result.Pieces) + 1);
    Result.Pieces[High(Result.Pieces)].Model := 'models/objects/gibs/' + Model + '/tris.md2';
    Result.Pieces[High(Result.Pieces)].Count := Count;
    Result.Pieces[High(Result.Pieces)].Metallic := Metallic;
  end;

begin
  Result := Default(TMonsterGibs);
  Result.GibHealth := -40;
  if Copy(MonsterClass, 1, 15) = 'monster_soldier' then
  begin
    { soldier_die: 3 meat, chest, head2; gib_health -30 }
    Result.GibHealth := -30;
    Add('sm_meat', 3);
    Add('chest', 1);
    Add('head2', 1);
  end else
  if MonsterClass = 'monster_infantry' then
  begin
    Add('bone', 1);
    Add('sm_meat', 4);
    Add('head2', 1);
  end else
  if (MonsterClass = 'monster_gunner') or (MonsterClass = 'monster_berserk') then
  begin
    { gunner_die (gib_health -70), berserk_die (-60) }
    if MonsterClass = 'monster_gunner' then
      Result.GibHealth := -70
    else
      Result.GibHealth := -60;
    Add('bone', 2);
    Add('sm_meat', 4);
    Add('head2', 1);
  end else
  if MonsterClass = 'monster_parasite' then
  begin
    Result.GibHealth := -50;
    Add('bone', 2);
    Add('sm_meat', 4);
    Add('head2', 1);
  end else
  if Copy(MonsterClass, 1, 12) = 'monster_tank' then
  begin
    { tank_die: meat, 4 metal pieces, chest, a gear for the head; -200 }
    Result.GibHealth := -200;
    Add('sm_meat', 1);
    Add('sm_metal', 4, True);
    Add('chest', 1);
    Add('gear', 1, True);
  end else
  if MonsterClass = 'monster_flyer' then
  begin
    { flyer_die: BecomeExplosion1, always }
    Result.GibHealth := -50;
    Result.Explodes := True;
  end else
  begin
    Add('bone', 2);
    Add('sm_meat', 4);
    Add('head2', 1);
  end;
end;

procedure MonsterBoxSize(const MonsterClass: String; out Mins, Maxs: TVector3);
var
  Height: Single;
begin
  { Quake 2 m_*.c SP_monster_* mins / maxs }
  Mins := Vector3(-16, -16, -24);
  Maxs := Vector3(16, 16, 32);
  if (MonsterClass = 'monster_gladiator') then
  begin
    Mins := Vector3(-32, -32, -24); Maxs := Vector3(32, 32, 64);
  end else
  if (MonsterClass = 'monster_tank') or (MonsterClass = 'monster_tank_commander') then
  begin
    Mins := Vector3(-32, -32, -16); Maxs := Vector3(32, 32, 72);
  end else
  if MonsterClass = 'monster_parasite' then
    Maxs.Z := 24
  else
  if (MonsterClass = 'monster_medic') or (MonsterClass = 'monster_floater') or
     (MonsterClass = 'monster_hover') then
  begin
    Mins := Vector3(-24, -24, -24); Maxs := Vector3(24, 24, 32);
  end else
  if MonsterClass = 'monster_mutant' then
  begin
    Mins := Vector3(-32, -32, -24); Maxs := Vector3(32, 32, 48);
  end else
  if MonsterClass = 'monster_chick' then
  begin
    Mins := Vector3(-16, -16, 0); Maxs := Vector3(16, 16, 56);
  end else
  if MonsterClass = 'monster_flipper' then
  begin
    Mins := Vector3(-16, -16, 0); Maxs := Vector3(16, 16, 32);
  end else
  if MonsterClass = 'monster_supertank' then
  begin
    Mins := Vector3(-64, -64, 0); Maxs := Vector3(64, 64, 112);
  end;
  { Our monster origins are 24 above the feet }
  Height := Maxs.Z - Mins.Z;
  Mins.Z := -24;
  Maxs.Z := -24 + Height;
end;

function FindItemDef(const AClassName: String): PQuakeItemDef;
var
  I: Integer;
begin
  for I := Low(ItemDefs) to High(ItemDefs) do
    if ItemDefs[I].ClassName = AClassName then
      Exit(@ItemDefs[I]);
  Result := nil;
end;

function FindMonsterDef(const AClassName: String): PQuakeMonsterDef;
var
  I: Integer;
begin
  for I := 0 to High(MonsterDefs) do
    if MonsterDefs[I].ClassName = AClassName then
      Exit(@MonsterDefs[I]);
  Result := nil;
end;

var
  IdleSounds: TStringList;

{ First sound/<dir>/*<Part>*.wav in the PAKs, looked up once per directory and part }
function MonsterSoundLike(const Def: PQuakeMonsterDef; const Part: String): String;
var
  Files: TStringList;
  I: Integer;
  Key: String;
begin
  if IdleSounds = nil then
    IdleSounds := TStringList.Create;
  Key := Def^.SoundDir + '/' + Part;
  I := IdleSounds.IndexOfName(Key);
  if I >= 0 then
    Exit(IdleSounds.ValueFromIndex[I]);
  Result := '';
  Files := Pak.FindFiles('sound/' + Def^.SoundDir + '/', '.wav');
  try
    for I := 0 to Files.Count - 1 do
      if Pos(Part, ExtractFileName(Files[I])) > 0 then
      begin
        Result := Files[I];
        Break;
      end;
  finally
    Files.Free;
  end;
  WritelnLog('QuakeEntities', 'Sound "%s" for "%s": "%s"', [Part, Def^.SoundDir, Result]);
  IdleSounds.Add(Key + '=' + Result);
end;

function MonsterIdleSound(const Def: PQuakeMonsterDef): String;
begin
  Result := MonsterSoundLike(Def, 'idle');
end;

function MonsterSearchSound(const Def: PQuakeMonsterDef): String;
begin
  Result := MonsterSoundLike(Def, 'srch');
  if Result = '' then
    Result := MonsterSoundLike(Def, 'search');
end;

function MonsterSound(const Def: PQuakeMonsterDef; const Name: String): String;
begin
  if Name = '' then
    Result := ''
  else
    Result := 'sound/' + Def^.SoundDir + '/' + Name + '.wav';
end;

var
  EntityCounter: Integer;

{ Unique number for readable transform names in the inspector }
function NextEntityNumber: Integer;
begin
  Inc(EntityCounter);
  Result := EntityCounter;
end;

{ Model scenes never block the player's shots against themselves or the
  ray casts used for floor detection; they are found by OwnsTransform. }
procedure ConfigureDecorScene(const Scene: TCastleScene);
begin
  Scene.Collides := False;
  Scene.Pickable := False;
end;

{ TQuakePickup }

constructor TQuakePickup.CreatePickup(const AParent: TCastleTransform; const ADef: PQuakeItemDef;
  const AEntity: TQuakeEntity; const Pos: TVector3);
begin
  inherited Create(nil);
  Def := ADef;
  Entity := AEntity;
  Origin := Pos;
  RotationAngle := Random * 360;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Item%.3d_%s', [NextEntityNumber, Def^.ClassName]);
  Transform.Translation := Pos;
  Model := Md2Manager.CreateInstance(Def^.Model);
  if Model <> nil then
  begin
    ConfigureDecorScene(Model.Scene);
    Model.Scene.Name := Transform.Name + '_Model';
    Model.SetTint(Lighting.SampleLight(Pos + Vector3(0, 8, 0)));
    Transform.Add(Model.Scene);
  end;
  Transform.AddBehavior(Self);
  AParent.Add(Transform);
end;

destructor TQuakePickup.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
end;

function TQuakePickup.GetItemName: String;
begin
  Result := Def^.Name;
end;

function TQuakePickup.GetEntityClass: String;
begin
  Result := Def^.ClassName;
end;

procedure TQuakePickup.UpdatePickup(const SecondsPassed: Single);
begin
  Transform.Exists := not Collected;
  if Collected then
    Exit;
  { Quake 2 items rotate (EF_ROTATE) at 180 degrees per second }
  RotationAngle := FloatModulo(RotationAngle + 180 * SecondsPassed, 360);
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(RotationAngle));
  LightTimer := LightTimer - SecondsPassed;
  if (LightTimer <= 0) and (Model <> nil) and Transform.Visible then
  begin
    LightTimer := 0.1;
    Model.SetTint(Lighting.SampleLight(Transform.Translation + Vector3(0, 8, 0)));
  end;
end;

{ TQuakeMonster }

constructor TQuakeMonster.CreateMonster(const AParent: TCastleTransform; const ADef: PQuakeMonsterDef;
  const AEntity: TQuakeEntity; const Pos: TVector3; const Yaw: Single);
begin
  inherited Create(nil);
  Def := ADef;
  Entity := AEntity;
  Health := Def^.Health;
  FacingAngle := Yaw;
  FLightTimer := Random * 0.25;
  FSightTimer := Random * 0.2;
  FDetourSide := 1;
  FIdleTimer := 3 + Random * 12;
  FAttack := TMonsterAttack.Create;
  FAttack.OnFire := @AttackSeqFire;
  FAttackSeqs := MonsterAttackSeqs(Def^.ClassName);
  FMove := TMonsterMoveAnim.Create;
  FWalkSeq := MonsterMoveSeq(Def^.ClassName, False);
  FRunSeq := MonsterMoveSeq(Def^.ClassName, True);
  MonsterBoxSize(Def^.ClassName, BoxMins, BoxMaxs);
  { Quake 2 base game: only the brain has power armor (a power screen) }
  if Def^.ClassName = 'monster_brain' then
  begin
    PowerArmorType := paScreen;
    PowerArmorPower := 100;
  end;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Monster%.3d_%s', [NextEntityNumber, Def^.ClassName]);
  Transform.Translation := Pos;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(Yaw));
  Transform.CollisionSphereRadius := 16;

  Model := Md2Manager.CreateInstance(Def^.Model, Def^.Skin);
  if Model <> nil then
  begin
    Model.Scene.Name := Transform.Name + '_Model';
    { Monsters block the player, and are found by ray casts (see OwnsTransform) }
    Model.Scene.Collides := True;
    Model.Scene.PreciseCollisions := False;
    Transform.Add(Model.Scene);
  end;
  SetState(msIdle);
  Ambush := (AEntity.SpawnFlags and 1) <> 0;
  Transform.AddBehavior(Self);
  AParent.Add(Transform);
  if ((AEntity.SpawnFlags and 2) <> 0) and (AEntity.TargetName <> '') then
    SetDormant(True);
end;

procedure TQuakeMonster.SetDormant(const Value: Boolean);
begin
  Dormant := Value;
  { Absent: not drawn, doesn't collide, can't be hit }
  Transform.Exists := not Value;
end;

procedure TQuakeMonster.Spawn;
begin
  if not Dormant then
    Exit;
  SetDormant(False);
  WritelnLog('QuakeEntities', 'Monster %s spawned (trigger_spawn)', [Transform.Name]);
  { monster_triggered_spawn: hunts whoever triggered it, unless AMBUSH }
  if not Ambush then
    Alert;
end;

function TQuakeMonster.CanDodge: Boolean;
begin
  if TurretDriver then
    Exit(False);
  { The monsters with monsterinfo.dodge in the Quake 2 game code }
  Result := (Copy(Def^.ClassName, 1, 15) = 'monster_soldier') or
    (Def^.ClassName = 'monster_infantry') or (Def^.ClassName = 'monster_gunner') or
    (Def^.ClassName = 'monster_medic') or (Def^.ClassName = 'monster_chick');
end;

procedure TQuakeMonster.Dodge(const Eta: Single);
begin
  if Dormant or not IsAlive or not CanDodge or (Model = nil) or
     (State in [msPain, msDuck]) or ((State = msAttack) and FAttack.Ducked) then
    Exit;
  { soldier_dodge & co.: only a quarter of the time }
  if Random > 0.25 then
    Exit;
  if not Alerted then
    Alert;
  { soldier_dodge: from medium skill on, sometimes duck and shoot (attack3:
    a third of the time on medium, two thirds from hard on) }
  if (Copy(Def^.ClassName, 1, 15) = 'monster_soldier') and
     (((GameSkill = 1) and (Random <= 0.33)) or ((GameSkill >= 2) and (Random <= 0.66))) and
     StartDodgeAttack(Eta + 0.3) then
  begin
    WritelnLog('QuakeEntities', '%s ducks and shoots (shot in %.2f s)', [Transform.Name, Eta]);
    Exit;
  end;
  { Down until the shot passed (pausetime = eta + 0.3), within reason }
  FDuckTime := EnsureRange(Eta + 0.3, 0.4, 1.5);
  if not Model.PlayAnim('duck', False, 5 / FDuckTime) then
    Exit;
  State := msDuck;
  StateTimer := 0;
  SetWalking(False);
  WritelnLog('QuakeEntities', '%s ducks (shot in %.2f s)', [Transform.Name, Eta]);
end;

function TQuakeMonster.WouldNotice(const Delta: TVector3): Boolean;
var
  Dist: Single;
  InFront: Boolean;
begin
  Dist := Delta.Length;
  if Dist > 1000 then
    Exit(False); { RANGE_FAR }
  if Dist < 80 then
    Exit(True); { RANGE_MELEE }
  InFront := TVector3.DotProduct(YawToCgeDir(FacingAngle), Delta / Dist) > 0.3;
  if Dist < 500 then
    Result := InFront or PlayerShowHostile { RANGE_NEAR }
  else
    Result := InFront; { RANGE_MID }
end;

function TQuakeMonster.HasLineOfSight(const Target: TVector3): Boolean;
begin
  Result := SightClear(EyePos, Target);
end;

function TQuakeMonster.SightClear(const FromPos, ToPos: TVector3): Boolean;
begin
  if Assigned(EntityTrace) then
    Result := EntityTrace(CgeToQuake(FromPos), CgeToQuake(ToPos), TVector3.Zero, TVector3.Zero,
      MASK_OPAQUE, Self).Fraction >= 1
  else
    Result := Transform.LineOfSight(FromPos, ToPos);
end;

function TQuakeMonster.Origin: TVector3;
begin
  Result := CgeToQuake(Transform.Translation);
end;

function TQuakeMonster.ShotBoxMaxs: TVector3;
begin
  Result := BoxMaxs;
  { Quake 2 monster duck: maxs[2] -= 32 }
  if (State = msDuck) or ((State = msAttack) and FAttack.Ducked) then
    Result.Z := Max(BoxMins.Z + 16, Result.Z - 32);
end;

procedure TQuakeMonster.SetOrigin(const Q: TVector3);
begin
  Transform.Translation := QuakeToCge(Q);
end;

function TQuakeMonster.MTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
begin
  Result := EntityTrace(Start, Stop, Mins, Maxs, Mask, Self);
end;

function TQuakeMonster.OnGroundTrace: Boolean;
var
  T: TQuakeTrace;
begin
  T := MTrace(Origin, Origin - Vector3(0, 0, 1), BoxMins, BoxMaxs);
  Result := (T.Fraction < 1) or T.StartSolid;
end;

function TQuakeMonster.CheckBottom(const Pos: TVector3): Boolean;
const
  StepSize = 18;
var
  Lo, Hi, Start: TVector3;
  T: TQuakeTrace;
  Mid, Bottom: Single;
  X, Y: Integer;
begin
  { M_CheckBottom: the middle and every corner of the box bottom must have
    ground no more than a step below, so monsters don't walk off ledges }
  Lo := Pos + BoxMins;
  Hi := Pos + BoxMaxs;
  Start := Vector3((Lo.X + Hi.X) / 2, (Lo.Y + Hi.Y) / 2, Lo.Z);
  T := MTrace(Start, Start - Vector3(0, 0, 2 * StepSize), TVector3.Zero, TVector3.Zero);
  if T.Fraction >= 1 then
    Exit(False);
  Mid := T.EndPos.Z;
  Bottom := Mid;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      Start := Vector3(IfThen(X = 0, Lo.X, Hi.X), IfThen(Y = 0, Lo.Y, Hi.Y), Lo.Z);
      T := MTrace(Start, Start - Vector3(0, 0, 2 * StepSize), TVector3.Zero, TVector3.Zero);
      if (T.Fraction < 1) and (T.EndPos.Z > Bottom) then
        Bottom := T.EndPos.Z;
      if (T.Fraction >= 1) or (Mid - T.EndPos.Z > StepSize) then
        Exit(False);
    end;
  Result := True;
end;

function TQuakeMonster.StepMove(const Move: TVector3): Boolean;
const
  StepSize = 18;
var
  Org, NewOrg, EndPos: TVector3;
  T: TQuakeTrace;
begin
  Org := Origin;
  if Def^.Flying then
  begin
    { Flyers: the whole move must be free }
    T := MTrace(Org, Org + Move, BoxMins, BoxMaxs);
    if T.AllSolid or T.StartSolid or (T.Fraction < 1) then
      Exit(False);
    SetOrigin(T.EndPos);
    Exit(True);
  end;
  { SV_movestep: from a step above the wished position, push down two steps }
  NewOrg := Org + Move;
  NewOrg.Z := NewOrg.Z + StepSize;
  EndPos := NewOrg - Vector3(0, 0, StepSize * 2);
  T := MTrace(NewOrg, EndPos, BoxMins, BoxMaxs);
  if T.AllSolid then
    Exit(False);
  if T.StartSolid then
  begin
    NewOrg.Z := NewOrg.Z - StepSize;
    T := MTrace(NewOrg, EndPos, BoxMins, BoxMaxs);
    if T.AllSolid or T.StartSolid then
      Exit(False);
  end;
  { Nothing below: it would walk off a ledge }
  if T.Fraction >= 1 then
    Exit(False);
  if not CheckBottom(T.EndPos) then
    Exit(False);
  SetOrigin(T.EndPos);
  Result := True;
end;

procedure TQuakeMonster.DropToFloor;
var
  Org: TVector3;
  T: TQuakeTrace;
  I: Integer;
begin
  { M_droptofloor: up a bit out of the floor (monster boxes differ from the
    spawn origin's), then down onto it }
  FDropped := True;
  if Def^.Flying then
    Exit;
  Org := Origin + Vector3(0, 0, 1);
  I := 0;
  while MTrace(Org, Org, BoxMins, BoxMaxs).StartSolid and (I < 32) do
  begin
    Org.Z := Org.Z + 1;
    Inc(I);
  end;
  T := MTrace(Org, Org - Vector3(0, 0, 256), BoxMins, BoxMaxs);
  if not T.AllSolid then
    SetOrigin(T.EndPos);
end;

destructor TQuakeMonster.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  FreeAndNil(Model);
  FreeAndNil(Transform);
  FreeAndNil(FAttack);
  FreeAndNil(FMove);
  inherited Destroy;
end;

procedure TQuakeMonster.RestoreState(const APos: TVector3; const AFacing: Single;
  const AHealth: Integer; const AState: TMonsterState; const AAlerted, AGibbed: Boolean);
begin
  Transform.Translation := APos;
  FacingAngle := AFacing;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(AFacing));
  Health := AHealth;
  Alerted := AAlerted;
  Gibbed := AGibbed;
  if AState in [msDying, msDead] then
  begin
    KillCounted := True;
    if Model <> nil then
    begin
      Model.Scene.Collides := False;
      { Jump to the last frame of the death animation }
      Model.PlayAnim('death,die,dead', False, 10);
      Model.Update(30);
    end;
    State := msDead;
    Transform.Exists := not AGibbed;
  end else
  if AAlerted then
    SetState(msChase)
  else
    SetState(msIdle);
end;

function TQuakeMonster.GetEntityClass: String;
begin
  Result := Def^.ClassName;
end;

function TQuakeMonster.EyePos: TVector3;
begin
  Result := Transform.Translation + Vector3(0, 16, 0);
end;

function TQuakeMonster.IsAlive: Boolean;
begin
  Result := (State <> msDying) and (State <> msDead);
end;

function TQuakeMonster.OwnsTransform(const T: TCastleTransform): Boolean;
begin
  Result := (T <> nil) and ((T = Transform) or ((Model <> nil) and (T = Model.Scene)));
end;

procedure TQuakeMonster.SetState(const NewState: TMonsterState);
begin
  State := NewState;
  StateTimer := 0;
  { Pain, ducking or death interrupt an attack sequence }
  if FAttack <> nil then
    FAttack.Stop;
  if FMove <> nil then
    FMove.Stop;
  if Model = nil then
    Exit;
  { The turret driver stands (infantry_stand) until it dies }
  if TurretDriver and (NewState in [msIdle, msChase, msAttack]) then
  begin
    Model.PlayAnim('stand', True, 10);
    Exit;
  end;
  case NewState of
    msIdle: Model.PlayAnim('stand,idle,fidget', True, 10);
    msChase:
      if not Model.PlayAnim('run', True, 10) then
        Model.PlayAnim('walk,stand', True, 10);
    msAttack: Model.PlayAnim('attak,attack,atk,fire,shoot,melee,swing,stand', False, 12);
    msPain: Model.PlayAnim('pain', False, 12);
    msDuck: ; { started by Dodge, which picks the speed }
    msDying: Model.PlayAnim('death,die,dead', False, 10);
    msDead: ;
  end;
end;

procedure TQuakeMonster.Alert;
begin
  if Alerted or not IsAlive or NoTarget or Dormant then
    Exit;
  Alerted := True;
  Sounds.PlayAt(MonsterSound(Def, Def^.SightSound), Transform, 1, 1, chVoice);
  { Quake 2 FoundTarget: stop patrolling, run to the combat point first }
  MoveTarget := nil;
  if (CombatTarget <> '') and Assigned(OnPickTarget) then
    GoalEntity := OnPickTarget(CombatTarget);
  CombatTarget := '';
  SetState(msChase);
  if Assigned(OnFoundTarget) then
    OnFoundTarget(Self);
end;

procedure TQuakeMonster.ResolveTargets;
var
  Ent: TQuakeEntity;
begin
  DeathTarget := Entity.Target;
  CombatTarget := Entity.GetField('combattarget');
  if (Entity.Target = '') or not Assigned(OnPickTarget) then
    Exit;
  Ent := OnPickTarget(Entity.Target);
  if Ent = nil then
    Exit;
  if Ent.ClassName = 'point_combat' then
  begin
    CombatTarget := Entity.Target;
    DeathTarget := '';
  end else
  if Ent.ClassName = 'path_corner' then
  begin
    MoveTarget := Ent;
    DeathTarget := '';
  end;
end;

procedure TQuakeMonster.SetWalking(const Value: Boolean);
begin
  if FWalking = Value then
    Exit;
  FWalking := Value;
  if (not Value) and (FMove <> nil) then
    FMove.Stop;
  if Model = nil then
    Exit;
  if Value then
    Model.PlayAnim('walk,run', True, 10)
  else
    Model.PlayAnim('stand,idle,fidget', True, 10);
end;

procedure TQuakeMonster.FaceTowards(const Delta: TVector3; const SecondsPassed: Single);
var
  TargetYaw, Diff: Single;
begin
  TargetYaw := RadToDeg(ArcTan2(-Delta.Z, Delta.X));
  Diff := FloatModulo(TargetYaw - FacingAngle + 540, 360) - 180;
  FacingAngle := FacingAngle + EnsureRange(Diff, -360 * SecondsPassed, 360 * SecondsPassed);
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(FacingAngle));
end;

function TQuakeMonster.DistanceTo(const Ent: TQuakeEntity; out Delta: TVector3): Single;
begin
  Delta := QuakeToCge(Ent.Origin) - Transform.Translation;
  if not Def^.Flying then
    Delta.Y := 0;
  Result := Delta.Length;
end;

procedure TQuakeMonster.Patrol(const SecondsPassed: Single);
var
  Delta: TVector3;
  Wait: Single;
  Corner: TQuakeEntity;
begin
  if FPauseTime > 0 then
  begin
    FPauseTime := FPauseTime - SecondsPassed;
    SetWalking(False);
    Exit;
  end;
  if DistanceTo(MoveTarget, Delta) > 24 then
  begin
    SetWalking(True);
    AdvanceMove(False, SecondsPassed);
    FaceTowards(Delta, SecondsPassed);
    Steer(Delta.Normalize, SecondsPassed, 0.4);
    Exit;
  end;

  { Reached the corner (path_corner_touch) }
  Corner := MoveTarget;
  if Assigned(OnUseTargets) then
    OnUseTargets(Corner.GetField('pathtarget'));
  Wait := Corner.GetFloat('wait', 0);
  if (Corner.Target <> '') and (Wait >= 0) then
    MoveTarget := OnPickTarget(Corner.Target)
  else
    MoveTarget := nil;
  if Wait > 0 then
    FPauseTime := Wait;
  if MoveTarget = nil then
    SetWalking(False);
end;

procedure TQuakeMonster.GoToCombatPoint(const SecondsPassed: Single);
var
  Delta: TVector3;
  Point: TQuakeEntity;
begin
  if DistanceTo(GoalEntity, Delta) > 24 then
  begin
    FaceTowards(Delta, SecondsPassed);
    Steer(Delta.Normalize, SecondsPassed);
    Exit;
  end;

  { Reached it (point_combat_touch): next point, or hold / resume the fight }
  Point := GoalEntity;
  if Assigned(OnUseTargets) then
    OnUseTargets(Point.GetField('pathtarget'));
  if Point.Target <> '' then
    GoalEntity := OnPickTarget(Point.Target)
  else
  begin
    GoalEntity := nil;
    HoldGround := (Point.GetInt('spawnflags') and 1) <> 0;
  end;
end;

function TQuakeMonster.AbsorbPowerArmor(const Dmg: Integer): Integer;
var
  DamagePerCell, Damage: Integer;
begin
  { Quake 2 CheckPowerArmor (the screen protects from all sides here, not
    only from the front) }
  Result := 0;
  if (PowerArmorType = paNone) or (PowerArmorPower <= 0) or (Dmg <= 0) then
    Exit;
  if PowerArmorType = paScreen then
  begin
    DamagePerCell := 1;
    Damage := Dmg div 3;
  end else
  begin
    DamagePerCell := 2;
    Damage := (2 * Dmg) div 3;
  end;
  Result := Min(PowerArmorPower * DamagePerCell, Damage);
  if Result <= 0 then
    Exit;
  PowerArmorPower := Max(0, PowerArmorPower - Result div DamagePerCell);
  FPowerArmorFlash := 0.2;
  Sounds.PlayAt('sound/weapons/lashit.wav', Transform);
end;

function TQuakeMonster.IsMedic: Boolean;
begin
  Result := Def^.ClassName = 'monster_medic';
end;

procedure TQuakeMonster.Revive;
begin
  Health := Def^.Health;
  Healer := nil;
  Gibbed := False;
  Transform.Exists := True;
  if Model <> nil then
    Model.Scene.Collides := True;
  FDropped := False;
  SetState(msChase);
  Alert;
  WritelnLog('QuakeEntities', '%s revived', [Transform.Name]);
end;

function TQuakeMonster.UpdateMedic(const SecondsPassed: Single): Boolean;
var
  Delta, CorpsePos: TVector3;
  Dist: Single;
begin
  Result := False;
  if HealTarget = nil then
    Exit;
  { The patient got gibbed, revived by someone else or removed }
  if HealTarget.IsAlive or HealTarget.Gibbed or not HealTarget.Transform.Exists then
  begin
    if HealTarget.Healer = Self then
      HealTarget.Healer := nil;
    HealTarget := nil;
    HealTime := 0;
    Exit;
  end;
  Result := True;
  CorpsePos := HealTarget.Transform.Translation;
  Delta := CorpsePos - Transform.Translation;
  Delta.Y := 0;
  Dist := Delta.Length;
  FaceTowards(Delta, SecondsPassed);
  { medic_cable_attack reaches MEDIC_MAX_HEAL_DISTANCE (400); get well inside
    it, in sight of the corpse }
  if (Dist > 250) or not SightClear(EyePos, CorpsePos + Vector3(0, 8, 0)) then
  begin
    HealTime := 0;
    if Dist > 1 then
      Steer(Delta.Normalize, SecondsPassed);
    StickToFloor(SecondsPassed);
    Exit;
  end;
  SetWalking(False);
  if HealTime = 0 then
    Sounds.PlayAt(MonsterSound(Def, 'medatck2'), Transform, 1, 1, chWeapon);
  HealTime := HealTime + SecondsPassed;
  { attack33 .. attack43 at 10 frames a second: the patient gets up }
  if HealTime >= 1.0 then
  begin
    Sounds.PlayAt(MonsterSound(Def, 'medatck5'), Transform, 1, 1, chWeapon);
    HealTarget.Revive;
    if Assigned(OnRevived) then
      OnRevived(HealTarget);
    HealTarget := nil;
    HealTime := 0;
  end;
  StickToFloor(SecondsPassed);
end;

function TQuakeMonster.GibHealth: Integer;
begin
  if TurretDriver then
    Result := 0
  else
    Result := MonsterGibs(Def^.ClassName).GibHealth;
end;

procedure TQuakeMonster.Gib(const Dmg: Integer);
var
  G: TMonsterGibs;
  Org: TVector3;
begin
  Gibbed := True;
  G := MonsterGibs(Def^.ClassName);
  Org := Origin;
  if G.Explodes then
  begin
    { BecomeExplosion1: TE_EXPLOSION1 }
    Particles.SpawnExplosion(Transform.Translation);
    Sounds.PlayAtPoint('sound/weapons/rocklx1a.wav', Transform.Translation);
  end else
  begin
    Sounds.PlayAt('sound/misc/udeath.wav', Transform, 1, 1, chBody);
    Particles.ThrowGibs(QuakeToCge(Org + BoxMins), QuakeToCge(Org + BoxMaxs), G.Pieces, Dmg);
  end;
  Transform.Exists := False;
  WritelnLog('QuakeEntities', '%s gibbed (%d damage)', [Transform.Name, Dmg]);
end;

procedure TQuakeMonster.TakeDamage(const Dmg: Integer);
begin
  if Dormant then
    Exit;
  if not IsAlive then
  begin
    { Shooting corpses gibs them }
    Health := Health - Dmg;
    if (Health <= GibHealth) and not Gibbed then
      Gib(Dmg);
    Exit;
  end;

  Health := Health - (Dmg - AbsorbPowerArmor(Dmg));
  if Health <= 0 then
  begin
    Sounds.PlayAt(MonsterSound(Def, Def^.DeathSound), Transform, 1, 1, chVoice);
    if Model <> nil then
      Model.Scene.Collides := False;
    if (Health <= GibHealth) or MonsterGibs(Def^.ClassName).Explodes then
    begin
      Gib(Dmg);
      State := msDead;
    end else
      SetState(msDying);
    Exit;
  end;

  if not Alerted then
    Alert;
  { SP_turret_driver has no pain function }
  if TurretDriver then
    Exit;
  { Quake 2 monsters don't flinch on every hit, and never on nightmare }
  if (State <> msPain) and (GameSkill < 3) and (Random < 0.6) then
  begin
    Sounds.PlayAt(MonsterSound(Def, Def^.PainSound), Transform, 1, 1, chVoice);
    SetState(msPain);
  end;
end;

procedure TQuakeMonster.StickToFloor(const SecondsPassed: Single);
var
  Above: Single;
  P: TVector3;
  T: TQuakeTrace;
begin
  if Def^.Flying then
    Exit;
  if Assigned(EntityTrace) then
  begin
    { MOVETYPE_STEP: fall under gravity 800 until a trace finds the floor }
    if OnGroundTrace then
      FFallSpeed := 0
    else
    begin
      FFallSpeed := Min(FFallSpeed + 800 * SecondsPassed, 1000);
      T := MTrace(Origin, Origin - Vector3(0, 0, FFallSpeed * SecondsPassed), BoxMins, BoxMaxs);
      if not T.AllSolid then
        SetOrigin(T.EndPos);
      if T.Fraction < 1 then
        FFallSpeed := 0;
    end;
    Exit;
  end;
  { Monster origin is 24 units above its feet (Quake 2 mins.z = -24) }
  P := Transform.Translation;
  if Transform.Height(P, Above) then
  begin
    if Above > 25 then
    begin
      FFallSpeed := Min(FFallSpeed + 800 * SecondsPassed, 1000);
      P.Y := P.Y - Min(FFallSpeed * SecondsPassed, Above - 24);
    end else
    begin
      FFallSpeed := 0;
      P.Y := P.Y + (24 - Above);
    end;
    Transform.Translation := P;
  end;
end;

procedure TQuakeMonster.UpdateAI(const SecondsPassed: Single; const PlayerPos: TVector3);
var
  Delta, MoveVec, Goal: TVector3;
  Dist, TargetYaw, Diff: Single;
begin
  if Dormant then
    Exit;
  if Model <> nil then
  begin
    Model.Update(SecondsPassed);
    FLightTimer := FLightTimer - SecondsPassed;
    if FLightTimer <= 0 then
    begin
      { 10 times a second, like Quake 2 relights entities every frame }
      FLightTimer := 0.1;
      Model.SetTint(Lighting.SampleLight(Transform.Translation));
    end;
    { M_SetEffects: green shell while the power armor is absorbing }
    if FPowerArmorFlash > 0 then
    begin
      FPowerArmorFlash := FPowerArmorFlash - SecondsPassed;
      Model.SetShell(Vector3(0, 1, 0));
    end else
      Model.SetShell(TVector3.Zero);
  end;

  if TurretDriver then
  begin
    UpdateDriverSight(PlayerPos);
    Exit;
  end;

  if (not FDropped) and Assigned(EntityTrace) and IsAlive then
    DropToFloor;

  if FJumping and IsAlive then
  begin
    UpdateJump(SecondsPassed);
    Exit;
  end;

  StateTimer := StateTimer + SecondsPassed;
  case State of
    msDead:
      Exit;
    msDying:
      begin
        StickToFloor(SecondsPassed);
        if (Model = nil) or Model.AnimDone or (StateTimer > 3) then
          State := msDead;
        Exit;
      end;
    msPain:
      begin
        if (Model = nil) or Model.AnimDone or (StateTimer > 0.6) then
          SetState(msChase);
        Exit;
      end;
    msDuck:
      begin
        { Down (smaller bounding box: shots pass over) until the shot passed }
        StickToFloor(SecondsPassed);
        if StateTimer >= FDuckTime then
          SetState(msChase);
        Exit;
      end;
  end;

  { A medic on its way to a corpse (AI_MEDIC) does only that }
  if UpdateMedic(SecondsPassed) then
    Exit;

  Delta := PlayerPos - Transform.Translation;
  Dist := Delta.Length;

  { Line of sight checks are throttled }
  FSightTimer := FSightTimer - SecondsPassed;
  if FSightTimer <= 0 then
  begin
    FSightTimer := 0.2;
    CanSeePlayer := (Dist < 2000) and SightClear(EyePos, PlayerPos);
    { Alerted but lost the player for a while: search sound, once per loss }
    if CanSeePlayer then
    begin
      FLostSightTime := 0;
      FLastSighting := PlayerPos;
      FHasLastSighting := True;
      FHasTrailGoal := False;
      if PlayerTrail <> nil then
        FTrailTime := PlayerTrail.Now;
      FSearched := False;
    end else
    if Alerted then
    begin
      FLostSightTime := FLostSightTime + 0.2;
      if (FLostSightTime > 3) and not FSearched then
      begin
        FSearched := True;
        if MonsterSearchSound(Def) <> '' then
          Sounds.PlayAt(MonsterSearchSound(Def), Transform, 1, ATTN_IDLE, chVoice);
      end;
    end;
    if (not Alerted) and CanSeePlayer and WouldNotice(Delta) and not NoTarget then
      Alert;
  end;

  if not Alerted then
  begin
    { Idle mutter now and then (ATTN_IDLE: fades out quickly) }
    FIdleTimer := FIdleTimer - SecondsPassed;
    if FIdleTimer <= 0 then
    begin
      FIdleTimer := 5 + Random * 15;
      if MonsterIdleSound(Def) <> '' then
        Sounds.PlayAt(MonsterIdleSound(Def), Transform, 1, ATTN_IDLE, chVoice);
    end;
    if MoveTarget <> nil then
      Patrol(SecondsPassed)
    else
      SetWalking(False);
    StickToFloor(SecondsPassed);
    Exit;
  end;
  FWalking := False;

  if State = msChase then
    AdvanceMove(True, SecondsPassed);

  if (GoalEntity <> nil) and (State <> msAttack) then
  begin
    GoToCombatPoint(SecondsPassed);
    StickToFloor(SecondsPassed);
    Exit;
  end;

  { Turn towards the player }
  FaceTowards(Delta, SecondsPassed);

  AttackCooldown := AttackCooldown - SecondsPassed;

  if State = msAttack then
  begin
    { Quake 2 attack sequence: frames at 10 a second, shots on its fire frames }
    if FAttack.Active then
    begin
      FAttack.Melee := Dist < MeleeDistance;
      FAttack.Nightmare := GameSkill >= 3;
      FAttack.Update(SecondsPassed, CanSeePlayer);
      if Model <> nil then
        Model.ShowFrames(FAttackFirst + FAttack.OldFrame, FAttackFirst + FAttack.Frame, FAttack.FrameLerp);
      if not FAttack.Active then
        SetState(msChase);
      StickToFloor(SecondsPassed);
      Exit;
    end;
    { Generic attack (monsters without a sequence table): the shot / hit
      happens partway through the animation, not when it starts }
    if (not FAttackFired) and ((Model = nil) or (Model.AnimProgress >= AttackFirePoint) or
       (StateTimer > 0.8)) then
    begin
      FAttackFired := True;
      Sounds.PlayAt(MonsterSound(Def, Def^.AttackSound), Transform, 1, 1, chWeapon);
      AttackKind := Def^.Attack;
      AttackDamage := Def^.Damage;
      if AttackKind = akBlaster then
        AttackDamage := Def^.Damage * 3;
      AttackBullets := 4;
      AttackReach := Def^.AttackRange + 24;
      if Assigned(OnAttack) then
        OnAttack(Self);
    end;
    if (Model = nil) or Model.AnimDone or (StateTimer > 1.2) then
      SetState(msChase);
    StickToFloor(SecondsPassed);
    Exit;
  end;

  if CanSeePlayer and (Dist <= Def^.AttackRange) and (AttackCooldown <= 0) then
  begin
    SetState(msAttack);
    FAttackFired := False;
    StartAttackSeq(Dist);
    AttackCooldown := Def^.AttackCooldown * SkillAttackDelay(GameSkill) * (0.8 + Random * 0.4);
    Exit;
  end;

  { Chase: melee monsters close in, ranged ones keep some distance
    (not when holding a combat point) }
  if HoldGround then
  begin
    StickToFloor(SecondsPassed);
    Exit;
  end else
  if (Def^.Attack = akMelee) or (Dist > Def^.AttackRange * 0.6) or not CanSeePlayer then
  begin
    MoveVec := Delta;
    { Out of sight: last sighting, then the player trail (ai_run) }
    if (not CanSeePlayer) and PursuitGoal(Goal) then
      MoveVec := Goal - Transform.Translation;
    if not Def^.Flying then
      MoveVec.Y := 0
    else
      { Flyers hover a bit above the player's eyes }
      MoveVec.Y := (PlayerPos.Y + 24) - Transform.Translation.Y;
    if (MoveVec.Length > 1) and (Dist > 40) then
      Steer(MoveVec.Normalize, SecondsPassed);
  end;
  StickToFloor(SecondsPassed);
end;

procedure TQuakeMonster.UpdateDriverSight(const PlayerPos: TVector3);
var
  Delta: TVector3;
begin
  { turret_driver_think: FindTarget, then only whether the enemy is
    visible; the world aims and fires the breach }
  if (State in [msDying, msDead]) then
  begin
    if State = msDying then
      State := msDead;
    Exit;
  end;
  Delta := PlayerPos - Transform.Translation;
  CanSeePlayer := (not NoTarget) and (Delta.Length < 2000) and SightClear(EyePos, PlayerPos);
  if (not Alerted) and CanSeePlayer and WouldNotice(Delta) then
    Alert;
end;

procedure TQuakeMonster.MonsterJump(const HorizVel: TVector3; const UpSpeed: Single);
var
  Above: Single;
begin
  if Def^.Flying or Dormant or not IsAlive then
    Exit;
  FJumpVel.X := HorizVel.X;
  FJumpVel.Z := HorizVel.Z;
  if FJumping then
    Exit;
  { On the ground (origin 24 above the feet): take off }
  if (Assigned(EntityTrace) and OnGroundTrace) or
     ((not Assigned(EntityTrace)) and Transform.Height(Transform.Translation, Above) and (Above <= 26)) then
  begin
    FJumpVel.Y := UpSpeed;
    FJumping := True;
    if State = msAttack then
      SetState(msChase);
  end;
end;

procedure TQuakeMonster.UpdateJump(const SecondsPassed: Single);
var
  Above: Single;
  P: TVector3;
  T: TQuakeTrace;
begin
  { Ballistic flight (MOVETYPE_STEP with no ground): gravity 800 }
  if Assigned(EntityTrace) then
  begin
    T := MTrace(Origin, Origin + CgeToQuake(FJumpVel * SecondsPassed), BoxMins, BoxMaxs);
    if not T.AllSolid then
      SetOrigin(T.EndPos);
    FJumpVel.Y := FJumpVel.Y - 800 * SecondsPassed;
    if (T.Fraction < 1) and (T.Normal.Z < 0.7) then
    begin
      { Hit a wall or ceiling: lose the speed into it }
      FJumpVel := FJumpVel - QuakeToCge(T.Normal) * TVector3.DotProduct(FJumpVel, QuakeToCge(T.Normal));
    end;
    if (FJumpVel.Y <= 0) and OnGroundTrace then
    begin
      FJumping := False;
      FJumpVel := TVector3.Zero;
    end;
    Exit;
  end;
  Transform.Move(FJumpVel * SecondsPassed, False, True);
  FJumpVel.Y := FJumpVel.Y - 800 * SecondsPassed;
  P := Transform.Translation;
  if (FJumpVel.Y <= 0) and Transform.Height(P, Above) and (Above <= 25) then
  begin
    P.Y := P.Y + (24 - Above);
    Transform.Translation := P;
    FJumping := False;
    FJumpVel := TVector3.Zero;
  end;
end;

function TQuakeMonster.StartDodgeAttack(const PauseTime: Single): Boolean;
var
  I, First: Integer;
begin
  Result := False;
  if Model = nil then
    Exit;
  for I := 0 to High(FAttackSeqs) do
    if FAttackSeqs[I].Use = auDodge then
    begin
      First := Model.Model.FrameNames.IndexOf(FAttackSeqs[I].FirstFrame);
      if (First < 0) or (First + FAttackSeqs[I].Count > Model.Model.FrameCount) then
        Exit;
      SetState(msAttack);
      FAttackFired := False;
      FAttackFirst := First;
      FAttack.PauseLeft := PauseTime;
      FAttack.Start(FAttackSeqs[I], CanSeePlayer);
      Model.ShowFrames(First, First, 0);
      SetWalking(False);
      Exit(True);
    end;
end;

procedure TQuakeMonster.AdvanceMove(const Run: Boolean; const SecondsPassed: Single);
var
  Seq: TMonsterMoveSeq;
  First: Integer;
begin
  if Model = nil then
    Exit;
  if (not FMove.Active) or (FMoveRun <> Run) then
  begin
    if Run then
      Seq := FRunSeq
    else
      Seq := FWalkSeq;
    First := Model.Model.FrameNames.IndexOf(Seq.FirstFrame);
    if (Length(Seq.Dists) = 0) or (First < 0) or (First + Length(Seq.Dists) > Model.Model.FrameCount) then
    begin
      FMove.Stop;
      Exit;
    end;
    FMoveFirst := First;
    FMoveRun := Run;
    FMove.Start(Seq);
  end else
    FMove.Update(SecondsPassed);
  Model.ShowFrames(FMoveFirst + FMove.OldFrame, FMoveFirst + FMove.Frame, FMove.FrameLerp);
end;

function TQuakeMonster.StartAttackSeq(const Dist: Single): Boolean;
var
  I, First: Integer;
begin
  Result := False;
  if (Model = nil) or (Length(FAttackSeqs) = 0) then
    Exit;
  I := ChooseAttackSeq(FAttackSeqs, Dist, Random);
  if I < 0 then
    Exit;
  First := Model.Model.FrameNames.IndexOf(FAttackSeqs[I].FirstFrame);
  if (First < 0) or (First + FAttackSeqs[I].Count > Model.Model.FrameCount) then
    Exit;
  FAttackFirst := First;
  FAttack.Start(FAttackSeqs[I], CanSeePlayer);
  Model.ShowFrames(First, First, 0);
  WritelnLog('QuakeEntities', '%s attacks: %s', [Transform.Name, FAttackSeqs[I].FirstFrame]);
  Result := True;
end;

procedure TQuakeMonster.AttackSeqFire(const ShotIndex: Integer);
var
  Seq: TMonsterAttackSeq;
begin
  Seq := FAttack.Seq;
  if (Seq.Sound <> '') and ((ShotIndex = 0) or not Seq.SoundOnce) then
    Sounds.PlayAt(MonsterSound(Def, Seq.Sound), Transform, 1, 1, chWeapon);
  AttackKind := Seq.Kind;
  AttackDamage := FAttack.ShotDamage(ShotIndex);
  AttackBullets := 1;
  { fire_hit reaches MELEE_DISTANCE; melee monsters (berserk, parasite)
    keep their own reach, ranged ones swinging up close don't get theirs }
  if (Seq.Kind = akMelee) and (Def^.Attack <> akMelee) then
    AttackReach := MeleeDistance + 24
  else
    AttackReach := Max(Def^.AttackRange, MeleeDistance) + 24;
  FAttackFired := True;
  if Assigned(OnAttack) then
    OnAttack(Self);
end;

function TQuakeMonster.AttackFirePoint: Single;
begin
  if Def^.Attack = akMelee then
    Result := 0.55
  else
    Result := 0.35;
end;

function TQuakeMonster.TryMove(const Dir: TVector3; const SecondsPassed: Single;
  const SpeedScale: Single): Boolean;
var
  Probe: TVector3;
  Above, MoveSpeed: Single;
  Box: TBox3D;
begin
  { The distance of the walk / run frame shown (Quake 2 ai_walk / ai_run),
    else the type's constant speed }
  if (FMove <> nil) and FMove.Active then
    MoveSpeed := FMove.Speed
  else
    MoveSpeed := Def^.Speed * SpeedScale;
  if Assigned(EntityTrace) then
    Exit(StepMove(CgeToQuake(Dir * MoveSpeed * SecondsPassed) - CgeToQuake(TVector3.Zero)));
  { Don't walk off ledges higher than 64 units (Quake 2 M_CheckBottom-like) }
  if not Def^.Flying then
  begin
    Probe := Transform.Translation + Dir * 24;
    if (not Transform.Height(Probe, Above)) or (Above > 24 + 64) then
      Exit(False);
  end;
  { The player's box blocks monsters like a solid (Quake 2 SV_movestep) }
  Box := Transform.BoundingBox;
  if (not PlayerBlockBox.IsEmpty) and (not Box.IsEmpty) and
     Box.Translate(Dir * MoveSpeed * SecondsPassed).Collision(PlayerBlockBox) and
     not Box.Collision(PlayerBlockBox) then
    Exit(False);
  Result := Transform.Move(Dir * MoveSpeed * SecondsPassed, False, True);
end;

function TQuakeMonster.PursuitGoal(out Goal: TVector3): Boolean;
const
  Reached = 40;
var
  Spot: TVector3;
  SpotTime: Single;

  function Near(const P: TVector3): Boolean;
  var
    D: TVector3;
  begin
    D := P - Transform.Translation;
    D.Y := 0;
    Result := D.Length < Reached;
  end;

begin
  Result := False;
  if Def^.Flying then
    Exit; { flyers keep heading for the player }
  { First where the player was last seen }
  if FHasLastSighting then
  begin
    if not Near(FLastSighting) then
    begin
      Goal := FLastSighting;
      Exit(True);
    end;
    FHasLastSighting := False;
  end;
  if PlayerTrail = nil then
    Exit;
  { Then the trail, spot by spot (PlayerTrail_PickFirst / PickNext) }
  if FHasTrailGoal and Near(FTrailGoal) then
    FHasTrailGoal := False;
  if not FHasTrailGoal then
  begin
    if not PlayerTrail.FirstAfter(FTrailTime, Spot, SpotTime) then
      Exit;
    FTrailGoal := Spot;
    FTrailTime := SpotTime;
    FHasTrailGoal := True;
  end;
  Goal := FTrailGoal;
  Result := True;
end;

procedure TQuakeMonster.Steer(const WantDir: TVector3; const SecondsPassed: Single;
  const SpeedScale: Single);
const
  DetourAngles: array[0..3] of Single = (Pi / 4, -Pi / 4, Pi / 2, -Pi / 2);
var
  I: Integer;
  Dir: TVector3;
begin
  { Keep following a detour that worked, for a short time }
  if FDetourTime > 0 then
  begin
    FDetourTime := FDetourTime - SecondsPassed;
    if TryMove(FDetourDir, SecondsPassed, SpeedScale) then
      Exit;
    FDetourTime := 0;
  end;
  if TryMove(WantDir, SecondsPassed, SpeedScale) then
    Exit;
  { Blocked: try turning left / right, alternating which side first }
  for I := 0 to High(DetourAngles) do
  begin
    Dir := RotatePointAroundAxisRad(DetourAngles[I] * FDetourSide, WantDir, Vector3(0, 1, 0));
    if TryMove(Dir, SecondsPassed, SpeedScale) then
    begin
      FDetourDir := Dir;
      FDetourTime := 0.6;
      Exit;
    end;
  end;
  FDetourSide := -FDetourSide;
end;

{ TQuakePlayerTrail }

procedure TQuakePlayerTrail.Clear;
begin
  Count := 0;
end;

procedure TQuakePlayerTrail.Add(const Pos: TVector3);
var
  I: Integer;
begin
  if Count = Length then
  begin
    for I := 1 to Length - 1 do
    begin
      Spots[I - 1] := Spots[I];
      Times[I - 1] := Times[I];
    end;
    Dec(Count);
  end;
  Spots[Count] := Pos;
  Times[Count] := Now;
  Inc(Count);
end;

function TQuakePlayerTrail.LastSpot: TVector3;
begin
  if Count = 0 then
    Result := TVector3.Zero
  else
    Result := Spots[Count - 1];
end;

function TQuakePlayerTrail.FirstAfter(const AfterTime: Single; out Pos: TVector3; out Time: Single): Boolean;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Times[I] > AfterTime then
    begin
      Pos := Spots[I];
      Time := Times[I];
      Exit(True);
    end;
  Result := False;
end;

{ TQuakeProjectile }

constructor TQuakeProjectile.Create(const Parent: TCastleTransform; const AKind: TProjectileKind;
  const Pos, Vel: TVector3; const ADamage: Integer; const AFromPlayer: Boolean);
var
  MdlPath: String;
  Dir: TVector3;
  Yaw, Pitch: Single;
begin
  inherited Create;
  Kind := AKind;
  Velocity := Vel;
  Damage := ADamage;
  FromPlayer := AFromPlayer;
  Life := 5;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Projectile%.3d', [NextEntityNumber]);
  Transform.Translation := Pos;
  { Orient the model along the velocity (Quake models face +X) }
  { A grenade at rest (restored from a savegame) has no velocity }
  if Vel.IsZero then
    Dir := Vector3(1, 0, 0)
  else
    Dir := Vel.Normalize;
  Yaw := ArcTan2(-Dir.Z, Dir.X);
  Pitch := ArcSin(EnsureRange(Dir.Y, -1, 1));
  Transform.Rotation := (QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) *
    QuatFromAxisAngle(Vector3(0, 0, 1), Pitch)).ToAxisAngle;

  case AKind of
    pkBlasterBolt: MdlPath := 'models/objects/laser/tris.md2';
    pkRocket: MdlPath := 'models/objects/rocket/tris.md2';
    pkGrenade: MdlPath := 'models/objects/grenade/tris.md2';
    pkHandGrenade: MdlPath := 'models/objects/grenade2/tris.md2';
    else MdlPath := '';
  end;
  if MdlPath <> '' then
    Model := Md2Manager.CreateInstance(MdlPath);
  { The BFG ball is an animated sprite }
  if AKind = pkBfg then
  begin
    Sprite := SpriteManager.CreateInstance('sprites/s_bfg1.sp2');
    if Sprite <> nil then
      Transform.Add(Sprite.Scene);
  end;
  if Model <> nil then
  begin
    ConfigureDecorScene(Model.Scene);
    Model.SetTint(Vector3(1.2, 1.2, 1.2));
    Transform.Add(Model.Scene);
  end;
  Parent.Add(Transform);
end;

destructor TQuakeProjectile.Destroy;
begin
  FreeAndNil(Sprite);
  Model.Free;
  Transform.Free;
  inherited Destroy;
end;

{ TQuakeSpeaker }

constructor TQuakeSpeaker.CreateSpeaker(const AParent: TCastleTransform; const AEntity: TQuakeEntity);
const
  LOOPED_ON = 1;
  LOOPED_OFF = 2;
var
  SoundPath: String;
begin
  inherited Create(nil);
  Entity := AEntity;
  FNoise := LowerCase(AEntity.GetField('noise'));
  FLooped := (AEntity.SpawnFlags and (LOOPED_ON or LOOPED_OFF)) <> 0;
  { Quake 2: attenuation -1 = none (heard everywhere), 0 = default (normal) }
  FAttenuation := AEntity.GetFloat('attenuation', 1);
  if FAttenuation = 0 then
    FAttenuation := 1;

  SoundPath := FNoise;
  if ExtractFileExt(SoundPath) = '' then
    SoundPath := SoundPath + '.wav';
  SoundPath := 'sound/' + SoundPath;
  FPath := SoundPath;
  FSound := Sounds.SpatialSound(SoundPath, FAttenuation);

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Speaker%.3d', [NextEntityNumber]);
  Transform.Translation := QuakeToCge(AEntity.Origin);
  Source := TCastleSoundSource.Create(nil);
  Source.Spatial := FAttenuation > 0;
  Source.Volume := AEntity.GetFloat('volume', 1);
  Transform.AddBehavior(Source);
  Transform.AddBehavior(Self);
  { Looped speakers are played by the world through the loop mixer
    (Sounds.AddLoop), only one source per distinct sound }
  FLoopOn := FLooped and ((AEntity.SpawnFlags and LOOPED_ON) <> 0);
  AParent.Add(Transform);
end;

destructor TQuakeSpeaker.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  if Source <> nil then
    Source.Sound := nil;
  FreeAndNil(Source);
  FreeAndNil(Transform);
  inherited Destroy;
end;

function TQuakeSpeaker.GetPlaying: Boolean;
begin
  Result := FLooped and (FSound <> nil) and FLoopOn;
end;

procedure TQuakeSpeaker.Activate;
begin
  if FSound = nil then
    Exit;
  if FLooped then
    FLoopOn := not FLoopOn
  else
    Source.Play(FSound);
end;

{ TQuakeProp }

constructor TQuakeProp.CreateProp(const AParent: TCastleTransform; const AKind: TPropKind;
  const AEntity: TQuakeEntity);
const
  Models: array[TPropKind] of String = (
    'models/objects/barrels/tris.md2', 'models/objects/banner/tris.md2',
    'models/deadbods/dude/tris.md2', 'models/objects/satellite/tris.md2',
    'models/ships/strogg1/tris.md2', 'models/objects/gibs/head2/tris.md2',
    'models/ships/viper/tris.md2', 'models/ships/bigviper/tris.md2',
    'models/objects/bomb/tris.md2', 'models/objects/black/tris.md2',
    'models/monsters/tank/tris.md2', 'models/monsters/bitch/tris.md2',
    'models/monsters/bitch/tris.md2', 'models/objects/dmspot/tris.md2');
var
  Pos: TVector3;
  Flags, Frame: Integer;
begin
  inherited Create(nil);
  Kind := AKind;
  Entity := AEntity;
  Pos := QuakeToCge(AEntity.Origin);
  Flags := AEntity.SpawnFlags;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Prop%.3d_%s', [NextEntityNumber, AEntity.ClassName]);
  Transform.Translation := Pos;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(AEntity.Angle));
  { SP_misc_teleporter: the dmspot pad with its second skin }
  Model := Md2Manager.CreateInstance(Models[AKind], IfThen(AKind = pkTeleporter, 1, 0));
  if Model <> nil then
  begin
    Model.Scene.Name := Transform.Name + '_Model';
    Model.SetTint(Lighting.SampleLight(Pos + Vector3(0, 8, 0)));
    { Barrels block the player and stop shots; other props are decoration }
    Model.Scene.Collides := AKind = pkExplobox;
    Model.Scene.Pickable := AKind = pkExplobox;
    Transform.Add(Model.Scene);
  end;

  case AKind of
    pkExplobox:
      Health := AEntity.GetInt('health', 10);
    pkBanner:
      if Model <> nil then
      begin
        { Waving flag: loop all frames, random phase }
        Model.PlayAnim('', True, 10);
        Model.Update(Random * 2);
      end;
    pkDeadSoldier:
      if Model <> nil then
      begin
        { Quake 2 picks the corpse pose from the spawnflags }
        if (Flags and 2) <> 0 then Frame := 1
        else if (Flags and 4) <> 0 then Frame := 2
        else if (Flags and 8) <> 0 then Frame := 3
        else if (Flags and 16) <> 0 then Frame := 4
        else if (Flags and 32) <> 0 then Frame := 5
        else Frame := 0;
        Model.SetFrame(Frame);
      end;
    pkStroggShip, pkViper:
      begin
        { Invisible until triggered, then flies along its path_corners }
        Transform.Exists := False;
        FlySpeed := AEntity.Speed(300);
      end;
    pkViperBomb:
      { Invisible until triggered (misc_viper_bomb_use) }
      Transform.Exists := False;
  end;
  { SP_misc_blackhole / eastertank / easterchick(2): frame ranges }
  AnimFirst := -1;
  case AKind of
    pkBlackHole: begin AnimFirst := 0; AnimLast := 18; end;
    pkEasterTank: begin AnimFirst := 254; AnimLast := 292; end;
    pkEasterChick: begin AnimFirst := 208; AnimLast := 247; end;
    pkEasterChick2: begin AnimFirst := 248; AnimLast := 286; end;
    else ;
  end;
  if (AnimFirst >= 0) and (Model <> nil) then
    Model.SetFrame(AnimFirst);

  Transform.AddBehavior(Self);
  AParent.Add(Transform);
end;

destructor TQuakeProp.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
end;

function TQuakeProp.GetEntityClass: String;
begin
  Result := Entity.ClassName;
end;

function TQuakeProp.OwnsTransform(const T: TCastleTransform): Boolean;
begin
  Result := (T <> nil) and ((T = Transform) or ((Model <> nil) and (T = Model.Scene)));
end;

procedure TQuakeProp.UpdateProp(const SecondsPassed: Single);
var
  Delta: TVector3;
  Dist, Step: Single;
  Frame: Integer;
begin
  if Destroyed then
    Exit;
  LightTimer := LightTimer - SecondsPassed;
  if (LightTimer <= 0) and (Model <> nil) and Transform.Exists and Transform.Visible then
  begin
    LightTimer := 0.1;
    Model.SetTint(Lighting.SampleLight(Transform.Translation + Vector3(0, 8, 0)));
  end;
  if (Model <> nil) and (Kind in [pkBanner, pkSatelliteDish]) then
    Model.Update(SecondsPassed);
  if (Model <> nil) and (AnimFirst >= 0) and (AnimLast > AnimFirst) then
  begin
    AnimTime := AnimTime + SecondsPassed * 10;
    Frame := Trunc(AnimTime) mod (AnimLast - AnimFirst + 1);
    Model.ShowFrames(AnimFirst + Frame, AnimFirst + (Frame + 1) mod (AnimLast - AnimFirst + 1), Frac(AnimTime));
  end;
  if Flying then
  begin
    Delta := FlyTarget - Transform.Translation;
    Dist := Delta.Length;
    Step := FlySpeed * SecondsPassed;
    if Dist > 0.01 then
    begin
      Transform.Rotation := Vector4(0, 1, 0, ArcTan2(-Delta.Z, Delta.X));
      if Step < Dist then
        Transform.Translation := Transform.Translation + Delta * (Step / Dist)
      else
        Transform.Translation := FlyTarget;
    end;
  end;
end;

{ TQuakeLaser }

constructor TQuakeLaser.CreateLaser(const AParent: TCastleTransform; const AEntity: TQuakeEntity;
  const ADirection: TVector3);
const
  LASER_ON = 1;
var
  Flags: Integer;
  Col: TCastleColor;
begin
  inherited Create(nil);
  Entity := AEntity;
  Origin := QuakeToCge(AEntity.Origin);
  Direction := ADirection;
  FDamage := AEntity.GetInt('dmg', 100);
  Flags := AEntity.SpawnFlags;
  { spawnflags: 2 red, 4 green, 8 blue, 16 yellow, 32 orange }
  if (Flags and 2) <> 0 then Col := Vector4(1, 0.1, 0.1, 1)
  else if (Flags and 4) <> 0 then Col := Vector4(0.1, 1, 0.1, 1)
  else if (Flags and 8) <> 0 then Col := Vector4(0.2, 0.3, 1, 1)
  else if (Flags and 16) <> 0 then Col := Vector4(1, 1, 0.2, 1)
  else if (Flags and 32) <> 0 then Col := Vector4(1, 0.6, 0.1, 1)
  else Col := Vector4(1, 0.1, 0.1, 1);

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Laser%.3d', [NextEntityNumber]);
  Transform.Translation := Origin;
  { The beam box is built along +X; rotate +X onto the direction }
  Transform.Rotation := (QuatFromAxisAngle(Vector3(0, 1, 0), ArcTan2(-Direction.Z, Direction.X)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), ArcSin(EnsureRange(Direction.Y, -1, 1)))).ToAxisAngle;
  Beam := TCastleBox.Create(nil);
  Beam.Name := Transform.Name + '_Beam';
  Beam.Material := pmUnlit;
  Beam.Color := Col;
  Beam.Collides := False;
  Beam.Pickable := False;
  Transform.Add(Beam);
  Transform.AddBehavior(Self);
  AParent.Add(Transform);
  SetLength(16);
  SetOn((Flags and LASER_ON) <> 0);
end;

destructor TQuakeLaser.Destroy;
begin
  FreeAndNil(Beam);
  FreeAndNil(Transform);
  inherited Destroy;
end;

procedure TQuakeLaser.SetLength(const Len: Single);
begin
  Length := Max(1, Len);
  Beam.Size := Vector3(Length, 1.5, 1.5);
  Beam.Translation := Vector3(Length / 2, 0, 0);
end;

procedure TQuakeLaser.SetOn(const Value: Boolean);
begin
  FOn := Value;
  Transform.Exists := Value;
end;

{ TQuakeTrigger }

constructor TQuakeTrigger.Create(const AEntity: TQuakeEntity; const ABox: TBox3D);
begin
  inherited Create;
  Entity := AEntity;
  Box := ABox;
  { Triggers with a targetname are often enabled by other triggers in Quake 2
    (TRIGGERED spawnflag 4); keep it simple and enable everything }
  Enabled := True;
end;

function TQuakeTrigger.Contains(const Pos: TVector3; const Radius: Single): Boolean;
begin
  Result := (Pos.X + Radius >= Box.Data[0].X) and (Pos.X - Radius <= Box.Data[1].X) and
            (Pos.Y + Radius >= Box.Data[0].Y) and (Pos.Y - Radius <= Box.Data[1].Y) and
            (Pos.Z + Radius >= Box.Data[0].Z) and (Pos.Z - Radius <= Box.Data[1].Z);
end;

procedure InitMonsterDefs;
var
  I: Integer;
begin
  SetLength(MonsterDefs, Length(DefaultMonsterDefs));
  for I := 0 to High(DefaultMonsterDefs) do
    MonsterDefs[I] := DefaultMonsterDefs[I];
end;

initialization
  InitMonsterDefs;
finalization
  FreeAndNil(IdleSounds);
end.
