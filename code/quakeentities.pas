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

  { Ground Zero's hint_path chains (g_newai.c): built by the world from
    the chain starts (END, a target, no targetname) along target ->
    targetname; Chains[c] lists node indices in order }
  THintNode = record
    Pos: TVector3; { CGE }
    Chain, Order: Integer;
  end;

  TQuakeHintPaths = class
    Nodes: array of THintNode;
    Chains: array of array of Integer;
  end;

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
  TUseTargetsEvent = procedure(const ATarget: String; const Source: TQuakeEntity) of object;

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
    { The gekk: its swim loop and water attacks, and the land ones while it
      swims (SetSwimming swaps them) }
    FSwimSeq, FLandWalkSeq, FLandRunSeq: TMonsterMoveSeq;
    FWaterAttackSeqs, FLandAttackSeqs: TMonsterAttackSeqs;
    FSwimTimer, FLeaveWaterTimer: Single;
    { The fixbot's weld: 0 going there, 1 weldstart, 2 weldmiddle, 3 weldend;
      clock of the phase, frame of the weld loop that made sparks }
    FWeldPhase: Integer;
    FWeldClock, FWeldApproach: Single;
    FWeldFrame: Integer;
    { The fixbot's roaming (change_to_roam): its spawnflags 4 / 8 / 16 (roam,
      take off, land; 0 stays put), 0 stand, 1 flying to the goal, 2
      landing, 3 taking off; the goal (Quake), clocks, the take-off frame
      that made puffs }
    FRoamFlags, FRoamPhase, FRoamFrame: Integer;
    FRoamGoal, FRoamOld: TVector3;
    FRoamClock, FRoamStuck: Single;
    FCeilingStuck: Boolean;
    { The stalker's false death (stalker_false_death*): 0 none, 1 falling
      down (death01..09), 2 twitching and healing (twitch), 3 getting up
      (reactive01..04); seconds in it, to the next heal }
    FFalseDeath: Integer;
    FFalseDeathTime, FHealTimer: Single;
    { stalker_jump_straightup to the ceiling: gravity reversed, Quake
      vertical speed, seconds in the air }
    FCeilingJump: Boolean;
    FCeilingVel, FCeilingJumpTime: Single;
    { monster_turret's blind fire: where the player was last seen (CGE,
      his origin), seconds since, the delay before the next blind shot }
    FBlindTarget: TVector3;
    FHasBlind: Boolean;
    FBlindLost, FBlindDelay: Single;
    FTurretCooldown, FTurretThink, FTurretReady, FTurretOutSpeed: Single;
    FTurretBase: TCastleTransform;
    FTurretBaseModel: TQuakeMd2Instance;
    FMove: TMonsterMoveAnim;
    FMoveFirst: Integer;
    FMoveRun: Boolean;
    { trigger_monsterjump: flying through the air with this velocity (CGE) }
    FJumping: Boolean;
    FJumpVel: TVector3;
    { Where the player was on the last UpdateAI (eye, CGE) }
    FLastPlayerPos: TVector3;
    { Jorg's legs (models/monsters/boss3/jorg), following Model's frames }
    FModel2: TQuakeMd2Instance;
    { Placed on the floor with traces (Quake 2 M_droptofloor) }
    FDropped: Boolean;
    FIdleTimer: Single;
    FLostSightTime: Single;
    { Losing the player (Quake 2 AI_PURSUIT_LAST_SEEN): go where he was
      last seen, then along the player trail }
    FLastSighting: TVector3;
    FHasLastSighting: Boolean;
    { Following a hint_path chain (AI_HINT_PATH): its chain, the order of
      the node it goes to and of the goal; tried once each time the player
      is lost }
    FOnHint, FHintTried: Boolean;
    FHintChain, FHintOrder, FHintGoal: Integer;
    FTrailTime: Single;
    FTrailGoal: TVector3;
    FHasTrailGoal: Boolean;
    FSearched: Boolean;
    FWalking: Boolean;
    { Power armor absorbed a hit recently: show the green shell (powerarmor_time) }
    FPowerArmorFlash: Single;
    { EF_POWERSCREEN: models/items/armor/effect, made on the first hit }
    FScreenModel: TQuakeMd2Instance;
    { Seconds to stand at the current path_corner ("wait") }
    FPauseTime: Single;
    { misc_insane: the staggering walk, seconds to the next fidget /
      struggle, playing one now, seconds of pain flinches left }
    FInsaneWalk: Boolean;
    FInsaneTimer: Single;
    FInsaneFidget: Boolean;
    FPainDebounce: Single;
    { misc_insane between pain / fidgets (QuakeInsane) }
    procedure UpdateInsane(const SecondsPassed: Single);
    { monster_turret: aim within its mounting, fire, come out of the wall }
    procedure UpdateTurret(const SecondsPassed: Single; const PlayerPos: TVector3);
    { turret_checkattack's blind fire and TurretFireBlind }
    procedure TurretBlindFire(const PlayerPos, Aim: TVector3);
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
    { The stalker: stalker_pain (True: handled), the false death, the jump
      up to the ceiling }
    function StalkerPain(const Dmg: Integer): Boolean;
    procedure StartFalseDeath;
    procedure StalkerReactivate;
    procedure UpdateFalseDeath(const SecondsPassed: Single);
    procedure UpdateCeilingJump(const SecondsPassed: Single);
    function MTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer = MASK_MONSTERSOLID): TQuakeTrace;
    procedure SetOrigin(const Q: TVector3);
    function OnGroundTrace: Boolean;
    { Quake 2 SV_movestep / M_CheckBottom: Move in Quake units }
    function StepMove(const Move: TVector3): Boolean;
    { The box at ToPos doesn't overlap solid (more than touching), or it
      already does at FromPos }
    function ClearToMoveTo(const FromPos, ToPos: TVector3): Boolean;
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
    function PursuitGoal(const PlayerPos: TVector3; out Goal: TVector3): Boolean;
    { monsterlost_checkhint: a hint_path chain from near here to near the
      player (True: following it) }
    function CheckHint(const PlayerPos: TVector3): Boolean;
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
    { Quake 2 AI_GOOD_GUY (misc_insane): never notices or attacks, not
      counted in the kills, not revived by medics }
    GoodGuy: Boolean;
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
    { fire_hit kick of the melee shot (negative pulls), BFG effect radius,
      blaster speed (0: the default), Makron's sweep yaw offset (degrees) }
    AttackKick: Single;
    AttackRadius: Single;
    { akLeap speeds of the shot's sequence (0: the mutant's) }
    AttackLeapForward, AttackLeapUp: Single;
    AttackSpeed: Single;
    AttackYaw: Single;
    { The target's position saved for this shot (gladiator / Makron railgun) }
    AimSaved: Boolean;
    SavedAim: TVector3;
    { Damage the mutant's jump deals when it lands on the player (0: none) }
    LeapDamage: Integer;
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
    { The gekk in water (FL_SWIM): it moves in three dimensions and stays in
      the water, with its swim frames and water attacks }
    Swimming: Boolean;
    { The fixbot (m_xatrix_fixbot): the func_object_repair it goes to weld
      (set by the world's use_scanner), and seconds before it looks for
      another (FIXBOT_WELD_GOAL_TIMEOUT) }
    WeldTarget: TQuakeEntity;
    WeldCooldown: Single;
    { target_anger (Ground Zero): it attacks this point (CGE) instead of
      the player until it is hurt }
    AngerActive: Boolean;
    AngerPos: TVector3;
    { Ground Zero: not counted as a kill (the medic commander's
      reinforcements, AI_DO_NOT_COUNT); the commander's monster slots }
    DoNotCount: Boolean;
    MonsterSlots: Integer;
    { The stalker on the ceiling (STALKER_ON_CEILING: spawnflag 8, its box
      and model upside down, walking along the ceiling) }
    OnCeiling: Boolean;
    { monster_turret: its weapon (0 blaster, 1 machinegun, 2 rocket), its
      mounting (the "angle" key: -1 facing up, -2 facing down, else the
      wall's yaw), its aim (Quake pitch / yaw); a WallUnit waits in the
      wall until used, then comes out 32 units (TurretOut left) }
    TurretWeapon: Integer;
    TurretFacing, TurretAimPitch, TurretAimYaw, TurretOut: Single;
    TurretWallWaiting: Boolean;
    function IsTurretMonster: Boolean;
    procedure ActivateWallTurret;
    { The stalker drops from the ceiling (stalker_jump_straightup there) }
    procedure DropFromCeiling;
    { stalker_ok_to_transition: a flat ceiling within 256 above (ToCeiling)
      or a floor within 384 below }
    function CeilingTransitionOk(const ToCeiling: Boolean): Boolean;
    { Turn the stalker upside down (or back), its box staying where it is }
    procedure SetCeiling(const Up: Boolean);
    { stalker_jump_straightup: up to the ceiling (or a hop), or down from it }
    procedure JumpStraightUp;
  public
    { Health it spawned with (the stalker heals back to it) }
    MaxHealth: Integer;
    { A turret's blind shot: MonsterAttack aims at BlindAim (CGE) }
    BlindFire: Boolean;
    BlindAim: TVector3;
    { The stalker is playing dead (or falling / getting up) }
    function FalseDeath: Boolean;
    { Flying, or swimming }
    function Flies: Boolean;
    { Is a Quake point in water, slime or lava }
    function WaterAt(const QuakePos: TVector3): Boolean;
    procedure SetSwimming(const Value: Boolean);
    { The gekk: into the water, out after the player }
    procedure UpdateSwimming(const SecondsPassed: Single; const PlayerPos: TVector3);
    { The fixbot welding (True while it does only that) }
    function UpdateWeld(const SecondsPassed: Single): Boolean;
    { The fixbot roaming, landing or taking off while idle (True: it did) }
    function UpdateRoam(const SecondsPassed: Single): Boolean;
    function IsFixbot: Boolean;
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
    { mutant_jump_takeoff: fly forward at 600, up at 250, keeping the attack
      animation; LeapDamage hurts the player on touch while faster than 400 }
    procedure Leap;
    { Animation names for PlayAnim: the Makron's own frames on its rider
      model (stand201.., walk201.., pain401.., death201..), not the ones
      riding Jorg }
    function AnimNames(const Names: String): String;
    function Q1AnimNames(const Names: String): String;
    { Model frame of a table's FirstFrame (a name or '#<index>'), -1 if none }
    function FrameOf(const AName: String): Integer;
    { Speed of the jump (CGE units a second) }
    function JumpSpeed: Single;
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

  TProjectileKind = (pkBlasterBolt, pkRocket, pkGrenade, pkHandGrenade, pkBfg,
    { The Reckoning: the ion ripper's bolt (bounces off walls for 3 s), the
      blue hyperblaster bolt, the heat-seeking rocket, the phalanx plasma
      ball (a hit and a splash), the gekk's spit }
    pkRipper, pkBlueBolt, pkHeatRocket, pkPlasma, pkLoogie,
    { The Reckoning's trap (fire_trap): bounces, opens, pulls a monster in,
      turns it into a food cube }
    pkTrap,
    { Ground Zero: the ETF rifle's flechette, the prox mine (sticks where it
      lands, arms, goes off when a monster comes near) }
    pkFlechette, pkProx,
    { Ground Zero's tesla mine: lands, opens after 3 s, zaps monsters near
      it for 30 s }
    pkTesla);

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
    { The player who fired it: its pmove (nil after loading a game) }
    OwnerPlayer: TObject;
    { BFG ball: seconds to its next laser think (bfg_think, every 0.1 s) }
    LaserTimer: Single;
    { BFG ball that hit something: stopped and hidden, its "BFG effect"
      (bfg_explode) goes off when Life runs out }
    Exploding: Boolean;
    { pkHeatRocket: how much of the way to its target it turns in 0.025 s
      (fire_heat's slerp fraction per server frame), 0 = none }
    HeatTurn: Single;
    { pkTrap (Trap_Think): seconds to the next think, model frame, landed,
      the countdown of frame 5 (wait: 64 down by 2), the victim's mass }
    TrapTimer: Single;
    TrapFrame: Integer;
    TrapLanded: Boolean;
    TrapWait: Integer;
    TrapMass: Integer;
    { pkTrap pulling a monster in (trapsuck.wav instead of traploop.wav) }
    TrapSucking: Boolean;
    { pkProx: stuck to a surface, seconds to arming (prox_open), its
      lifetime once armed, the countdown after a monster came near }
    ProxStuck: Boolean;
    ProxArm, ProxFuse, ProxTrigger: Single;
    { pkTesla: seconds since thrown, its open frame (-1 before), active,
      the next zap }
    TeslaClock: Single;
    TeslaFrame: Integer;
    TeslaActive: Boolean;
    TeslaZap: Single;
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
    pkTeleporter, pkCommanderBody, pkBoss3Stand, pkMineLight1, pkMineLight2,
    pkRotatingLight, pkTransport, pkNukeCore, pkBlacklight, pkOrb, pkWidowLegs);

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
    { Play AnimFirst..AnimLast once and stay on the last frame (the
      commander's body when used); its thud sound was played }
    AnimOnce: Boolean;
    ThudPlayed: Boolean;
    { Re-light the model 10 times a second (light styles flicker) }
    LightTimer: Single;
    { The Reckoning's rotating_light: spinning (EF_SPINNINGLIGHTS) while
      LightOn, SpinAngle degrees past its yaw; with ALARM, misc/alarm.wav
      every second once used (AlarmActive, AlarmTimer) }
    LightOn, Alarm, AlarmActive: Boolean;
    SpinAngle, AlarmTimer: Single;
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
    { The Reckoning's target_mal_laser: drawn while on, it hurts only in
      pulses, every Wait + 0.1 s (the first Wait + Delay after it is turned
      on), with sparks where it stops from the second pulse on }
    Mal: Boolean;
    Wait, Delay, PulseTimer: Single;
    Pulses: Integer;
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
  { Quake II Remastered's keys (the N64 levels, the mission packs) and Call
    of the Void's Quake 1 keys and runes }
  KEY_EXPLOSIVE_CHARGES = 1 shl 9;
  KEY_YELLOW            = 1 shl 10;
  KEY_POWER_CORE        = 1 shl 11;
  KEY_GREEN             = 1 shl 12;
  KEY_NUKE_CONTAINER    = 1 shl 13;
  KEY_NUKE              = 1 shl 14;
  KEY_Q1_RUNE1          = 1 shl 15;
  KEY_Q1_RUNE2          = 1 shl 16;
  KEY_Q1_RUNE3          = 1 shl 17;
  KEY_Q1_RUNE4          = 1 shl 18;
  KEY_Q1_BASE_GOLD      = 1 shl 19;
  KEY_Q1_BASE_SILVER    = 1 shl 20;
  KEY_Q1_MEDIEVAL_GOLD  = 1 shl 21;
  KEY_Q1_MEDIEVAL_SILVER = 1 shl 22;
  KEY_Q1_RUNIC_GOLD     = 1 shl 23;
  KEY_Q1_RUNIC_SILVER   = 1 shl 24;

  { Weapon slots: 1 Blaster .. 10 BFG10K, 11 Hand Grenades, then The
    Reckoning's 12 Ion Ripper, 13 Phalanx, 14 Traps (chained with the
    hyperblaster, the railgun and the grenades: their keys switch between
    the two) }
  WeaponSlots = 19;
  IonRipperSlot = 12;
  PhalanxSlot = 13;
  TrapSlot = 14;
  { Ground Zero's 15 Chainfist, 16 ETF Rifle, 17 Prox Launcher, 18 Plasma
    Beam (chained with the blaster, the machinegun, the grenade launcher
    and the hyperblaster) }
  ChainfistSlot = 15;
  EtfRifleSlot = 16;
  ProxLauncherSlot = 17;
  PlasmaBeamSlot = 18;
  { Ground Zero's tesla mines: thrown (Throw_Generic), on the G key after
    the hand grenades and the traps }
  TeslaSlot = 19;

  POWERUP_QUAD = 1;
  POWERUP_INVULN = 2;
  POWERUP_ADRENALINE = 3;
  POWERUP_BANDOLIER = 4;
  POWERUP_PACK = 5;
  POWERUP_OTHER = 6;
  POWERUP_ANCIENT_HEAD = 7;
  POWERUP_QUADFIRE = 8;
  { Ground Zero }
  POWERUP_DOUBLE = 9;
  POWERUP_IR = 10;
  POWERUP_DEFENDER = 11;

  ItemDefs: array[0..74] of TQuakeItemDef = (
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
    (ClassName: 'key_airstrike_target'; Category: icKey; Model: 'models/items/keys/target/tris.md2'; Icon: 'i_airstrike'; Name: 'Airstrike Marker'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_AIRSTRIKE; Param: 0),
    { Quake II Remastered and Call of the Void (models and names from the
      mod's item list; its medieval / runic key names are swapped there,
      kept as players see them; no icons known yet) }
    (ClassName: 'key_explosive_charges'; Category: icKey; Model: 'models/items/n64/charge/tris.md2'; Icon: ''; Name: 'Explosive Charges'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_EXPLOSIVE_CHARGES; Param: 0),
    (ClassName: 'key_yellow_key'; Category: icKey; Model: 'models/items/n64/yellow_key/tris.md2'; Icon: ''; Name: 'Yellow Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_YELLOW; Param: 0),
    (ClassName: 'key_power_core'; Category: icKey; Model: 'models/items/n64/power_core/tris.md2'; Icon: ''; Name: 'Power Core'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_POWER_CORE; Param: 0),
    (ClassName: 'key_green_key'; Category: icKey; Model: 'models/items/keys/green_key/tris.md2'; Icon: ''; Name: 'Green Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_GREEN; Param: 0),
    (ClassName: 'key_nuke_container'; Category: icKey; Model: 'models/weapons/g_nuke/tris.md2'; Icon: ''; Name: 'Antimatter Pod'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_NUKE_CONTAINER; Param: 0),
    (ClassName: 'key_nuke'; Category: icKey; Model: 'models/weapons/g_nuke/tris.md2'; Icon: ''; Name: 'Antimatter Bomb'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_NUKE; Param: 0),
    (ClassName: 'key_q1_rune_end1'; Category: icKey; Model: 'models/items/keys/end1/end1.md2'; Icon: ''; Name: 'Rune of Earth Magic'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNE1; Param: 0),
    (ClassName: 'key_q1_rune_end2'; Category: icKey; Model: 'models/items/keys/end2/end2.md2'; Icon: ''; Name: 'Rune of Black Magic'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNE2; Param: 0),
    (ClassName: 'key_q1_rune_end3'; Category: icKey; Model: 'models/items/keys/end3/end3.md2'; Icon: ''; Name: 'Rune of Hell Magic'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNE3; Param: 0),
    (ClassName: 'key_q1_rune_end4'; Category: icKey; Model: 'models/items/keys/end4/end4.md2'; Icon: ''; Name: 'Rune of Elder Magic'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNE4; Param: 0),
    (ClassName: 'key_q1_base_gold_key'; Category: icKey; Model: 'models/items/keys/base/b_g_key.md2'; Icon: ''; Name: 'Gold Keycard'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_BASE_GOLD; Param: 0),
    (ClassName: 'key_q1_base_silver_key'; Category: icKey; Model: 'models/items/keys/base/b_s_key.md2'; Icon: ''; Name: 'Silver Keycard'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_BASE_SILVER; Param: 0),
    (ClassName: 'key_q1_medieval_gold_key'; Category: icKey; Model: 'models/items/keys/medieval/m_g_key.md2'; Icon: ''; Name: 'Runic Gold Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_MEDIEVAL_GOLD; Param: 0),
    (ClassName: 'key_q1_medieval_silver_key'; Category: icKey; Model: 'models/items/keys/medieval/m_s_key.md2'; Icon: ''; Name: 'Runic Silver Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_MEDIEVAL_SILVER; Param: 0),
    (ClassName: 'key_q1_runic_gold_key'; Category: icKey; Model: 'models/items/keys/wizard/w_g_key.md2'; Icon: ''; Name: 'Medieval Gold Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNIC_GOLD; Param: 0),
    (ClassName: 'key_q1_runic_silver_key'; Category: icKey; Model: 'models/items/keys/wizard/w_s_key.md2'; Icon: ''; Name: 'Medieval Silver Key'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: KEY_Q1_RUNIC_SILVER; Param: 0),
    { Pickup_AncientHead: 2 more max health (city3's secret) }
    (ClassName: 'item_ancient_head'; Category: icPowerup; Model: 'models/items/c_head/tris.md2'; Icon: 'i_fixme'; Name: 'Ancient Head'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 0; Param: POWERUP_ANCIENT_HEAD),
    { The Reckoning (g_items' xatrix entries): the ion ripper uses 2 cells a
      shot, the phalanx mag slugs; traps are both ammo and weapon }
    (ClassName: 'weapon_boomer'; Category: icWeapon; Model: 'models/weapons/g_boom/tris.md2'; Icon: 'w_ripper'; Name: 'Ion Ripper'; Sound: 'sound/misc/w_pkup.wav'; Weapon: IonRipperSlot; AmmoType: atCells; Amount: 50; Param: 0),
    (ClassName: 'weapon_phalanx'; Category: icWeapon; Model: 'models/weapons/g_shotx/tris.md2'; Icon: 'w_phallanx'; Name: 'Phalanx'; Sound: 'sound/misc/w_pkup.wav'; Weapon: PhalanxSlot; AmmoType: atMagSlugs; Amount: 10; Param: 0),
    (ClassName: 'ammo_magslug'; Category: icAmmo; Model: 'models/objects/ammo/tris.md2'; Icon: 'a_mslugs'; Name: 'Mag Slug'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atMagSlugs; Amount: 10; Param: 0),
    (ClassName: 'ammo_trap'; Category: icAmmo; Model: 'models/weapons/g_trap/tris.md2'; Icon: 'a_trap'; Name: 'Trap'; Sound: 'sound/misc/am_pkup.wav'; Weapon: TrapSlot; AmmoType: atTraps; Amount: 1; Param: 0),
    (ClassName: 'item_quadfire'; Category: icPowerup; Model: 'models/items/quadfire/tris.md2'; Icon: 'p_quadfire'; Name: 'DualFire Damage'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 30; Param: POWERUP_QUADFIRE),
    { Ground Zero (its g_items entries): the ETF rifle fires flechettes, the
      plasma beam 2 cells a frame, the chainfist nothing }
    (ClassName: 'weapon_chainfist'; Category: icWeapon; Model: 'models/weapons/g_chainf/tris.md2'; Icon: 'w_chainfist'; Name: 'Chainfist'; Sound: 'sound/misc/w_pkup.wav'; Weapon: ChainfistSlot; AmmoType: atNone; Amount: 0; Param: 0),
    (ClassName: 'weapon_etf_rifle'; Category: icWeapon; Model: 'models/weapons/g_etf_rifle/tris.md2'; Icon: 'w_etf_rifle'; Name: 'ETF Rifle'; Sound: 'sound/misc/w_pkup.wav'; Weapon: EtfRifleSlot; AmmoType: atFlechettes; Amount: 50; Param: 0),
    (ClassName: 'weapon_proxlauncher'; Category: icWeapon; Model: 'models/weapons/g_plaunch/tris.md2'; Icon: 'w_proxlaunch'; Name: 'Prox Launcher'; Sound: 'sound/misc/w_pkup.wav'; Weapon: ProxLauncherSlot; AmmoType: atProx; Amount: 5; Param: 0),
    (ClassName: 'weapon_plasmabeam'; Category: icWeapon; Model: 'models/weapons/g_beamer/tris.md2'; Icon: 'w_heatbeam'; Name: 'Plasma Beam'; Sound: 'sound/misc/w_pkup.wav'; Weapon: PlasmaBeamSlot; AmmoType: atCells; Amount: 50; Param: 0),
    (ClassName: 'ammo_flechettes'; Category: icAmmo; Model: 'models/ammo/am_flechette/tris.md2'; Icon: 'a_flechettes'; Name: 'Flechettes'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atFlechettes; Amount: 50; Param: 0),
    (ClassName: 'item_double'; Category: icPowerup; Model: 'models/items/ddamage/tris.md2'; Icon: 'p_double'; Name: 'Double Damage'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 30; Param: POWERUP_DOUBLE),
    (ClassName: 'item_ir_goggles'; Category: icPowerup; Model: 'models/items/goggles/tris.md2'; Icon: 'p_ir'; Name: 'IR Goggles'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 60; Param: POWERUP_IR),
    (ClassName: 'item_sphere_defender'; Category: icPowerup; Model: 'models/items/defender/tris.md2'; Icon: 'p_defender'; Name: 'Defender Sphere'; Sound: 'sound/items/pkup.wav'; Weapon: 0; AmmoType: atNone; Amount: 30; Param: POWERUP_DEFENDER),
    (ClassName: 'ammo_tesla'; Category: icAmmo; Model: 'models/ammo/am_tesl/tris.md2'; Icon: 'a_tesla'; Name: 'Tesla'; Sound: 'sound/misc/am_pkup.wav'; Weapon: TeslaSlot; AmmoType: atTesla; Amount: 5; Param: 0),
    (ClassName: 'ammo_prox'; Category: icAmmo; Model: 'models/ammo/am_prox/tris.md2'; Icon: 'a_prox'; Name: 'Prox'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atProx; Amount: 5; Param: 0),
    { What a trap leaves of a monster (SP_item_foodcube): health over the
      maximum, the entity's "count" (a tenth of the monster's mass) }
    (ClassName: 'item_foodcube'; Category: icHealth; Model: 'models/objects/trapfx/tris.md2'; Icon: 'i_health'; Name: 'Food Cube'; Sound: 'sound/items/s_health.wav'; Weapon: 0; AmmoType: atNone; Amount: 2; Param: 1)
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
    (Name: 'Hand Grenades'; ViewModel: 'models/weapons/v_handgr/tris.md2'; Icon: 'w_hgrenade'; AmmoType: atGrenades; AmmoPerShot: 1; Sound: 'sound/weapons/hgrent1a.wav'),
    { The Reckoning: the phalanx fires two balls for one mag slug (taken
      on the second), traps are thrown like hand grenades }
    (Name: 'Ion Ripper'; ViewModel: 'models/weapons/v_boomer/tris.md2'; Icon: 'w_ripper'; AmmoType: atCells; AmmoPerShot: 2; Sound: 'sound/weapons/rippfire.wav'),
    (Name: 'Phalanx'; ViewModel: 'models/weapons/v_shotx/tris.md2'; Icon: 'w_phallanx'; AmmoType: atMagSlugs; AmmoPerShot: 1; Sound: 'sound/weapons/plasshot.wav'),
    (Name: 'Traps'; ViewModel: 'models/weapons/v_trap/tris.md2'; Icon: 'a_trap'; AmmoType: atTraps; AmmoPerShot: 1; Sound: ''),
    { Ground Zero: the chainfist's saw and the plasma beam's hum are loop
      sounds (TQuakeGun.LoopSound) }
    (Name: 'Chainfist'; ViewModel: 'models/weapons/v_chainf/tris.md2'; Icon: 'w_chainfist'; AmmoType: atNone; AmmoPerShot: 0; Sound: ''),
    (Name: 'ETF Rifle'; ViewModel: 'models/weapons/v_etf_rifle/tris.md2'; Icon: 'w_etf_rifle'; AmmoType: atFlechettes; AmmoPerShot: 1; Sound: 'sound/weapons/nail1.wav'),
    (Name: 'Prox Launcher'; ViewModel: 'models/weapons/v_plaunch/tris.md2'; Icon: 'w_proxlaunch'; AmmoType: atProx; AmmoPerShot: 1; Sound: 'sound/weapons/grenlf1a.wav'),
    (Name: 'Plasma Beam'; ViewModel: 'models/weapons/v_beamer/tris.md2'; Icon: 'w_heatbeam'; AmmoType: atCells; AmmoPerShot: 2; Sound: ''),
    (Name: 'Tesla'; ViewModel: 'models/weapons/v_tesla/tris.md2'; Icon: 'a_tesla'; AmmoType: atTesla; AmmoPerShot: 1; Sound: '')
  );

  AmmoIcons: array[TAmmoType] of String = ('', 'a_shells', 'a_bullets', 'a_grenades',
    'a_rockets', 'a_cells', 'a_slugs', 'a_mslugs', 'a_trap', 'a_flechettes', 'a_prox', 'a_tesla');

  { Built-in monster definitions. At startup data/monsters.castle-transform
    (TQuakeMonsterType components, editable in the CGE editor) overrides
    and extends them in MonsterDefs. }
  DefaultMonsterDefs: array[0..36] of TQuakeMonsterDef = (
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
    (ClassName: 'monster_supertank'; Model: 'models/monsters/boss1/tris.md2'; Skin: 0; Health: 1500; Speed: 80; Attack: akRocket; Damage: 50; AttackRange: 1500; AttackCooldown: 1.2; Flying: False; SoundDir: 'bosstank'; SightSound: 'btkunqv1'; PainSound: 'btkpain1'; DeathSound: 'btkdeth1'; AttackSound: 'btkunqv2'),
    (ClassName: 'monster_boss2'; Model: 'models/monsters/boss2/tris.md2'; Skin: 0; Health: 2000; Speed: 80; Attack: akRocket; Damage: 50; AttackRange: 1500; AttackCooldown: 1.2; Flying: True; SoundDir: 'bosshovr'; SightSound: ''; PainSound: 'bhvpain1'; DeathSound: 'bhvdeth1'; AttackSound: ''),
    (ClassName: 'monster_jorg'; Model: 'models/monsters/boss3/rider/tris.md2'; Skin: 0; Health: 3000; Speed: 100; Attack: akHitscan; Damage: 6; AttackRange: 1500; AttackCooldown: 1.2; Flying: False; SoundDir: 'boss3'; SightSound: ''; PainSound: 'bs3pain1'; DeathSound: 'bs3deth1'; AttackSound: 'bs3atck1'),
    (ClassName: 'monster_makron'; Model: 'models/monsters/boss3/rider/tris.md2'; Skin: 0; Health: 3000; Speed: 90; Attack: akRail; Damage: 50; AttackRange: 1500; AttackCooldown: 1.2; Flying: False; SoundDir: 'makron'; SightSound: 'voice4'; PainSound: 'pain1'; DeathSound: 'death'; AttackSound: 'rail_up'),
    { The Reckoning (models of its PAK: soldierh skins 0 / 2 / 4, gladb,
      boss5; facts from m_soldier / m_chick / m_gladiator / m_supertank's
      branches and m_xatrix_gekk / m_xatrix_fixbot) }
    (ClassName: 'monster_soldier_ripper'; Model: 'models/monsters/soldierh/tris.md2'; Skin: 0; Health: 50; Speed: 120; Attack: akRipper; Damage: 5; AttackRange: 900; AttackCooldown: 1.6; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain2'; DeathSound: 'soldeth2'; AttackSound: ''),
    (ClassName: 'monster_soldier_hypergun'; Model: 'models/monsters/soldierh/tris.md2'; Skin: 2; Health: 60; Speed: 120; Attack: akBlueBlaster; Damage: 1; AttackRange: 900; AttackCooldown: 1.6; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain1'; DeathSound: 'soldeth1'; AttackSound: ''),
    (ClassName: 'monster_soldier_lasergun'; Model: 'models/monsters/soldierh/tris.md2'; Skin: 4; Health: 70; Speed: 120; Attack: akLaser; Damage: 1; AttackRange: 900; AttackCooldown: 1.6; Flying: False; SoundDir: 'soldier'; SightSound: 'solsght1'; PainSound: 'solpain3'; DeathSound: 'soldeth3'; AttackSound: ''),
    (ClassName: 'monster_chick_heat'; Model: 'models/monsters/bitch/tris.md2'; Skin: 2; Health: 175; Speed: 130; Attack: akHeatRocket; Damage: 50; AttackRange: 1000; AttackCooldown: 2.0; Flying: False; SoundDir: 'chick'; SightSound: 'chksght1'; PainSound: 'chkpain1'; DeathSound: 'chkdeth1'; AttackSound: 'chkatck2'),
    (ClassName: 'monster_gladb'; Model: 'models/monsters/gladb/tris.md2'; Skin: 0; Health: 250; Speed: 120; Attack: akPlasma; Damage: 35; AttackRange: 1200; AttackCooldown: 2.5; Flying: False; SoundDir: 'gladiator'; SightSound: 'sight'; PainSound: 'pain'; DeathSound: 'glddeth2'; AttackSound: ''),
    (ClassName: 'monster_boss5'; Model: 'models/monsters/boss5/tris.md2'; Skin: 0; Health: 1500; Speed: 80; Attack: akHeatRocket; Damage: 40; AttackRange: 1500; AttackCooldown: 1.2; Flying: False; SoundDir: 'bosstank'; SightSound: 'btkunqv1'; PainSound: 'btkpain1'; DeathSound: 'btkdeth1'; AttackSound: 'btkunqv2'),
    (ClassName: 'monster_gekk'; Model: 'models/monsters/gekk/tris.md2'; Skin: 0; Health: 125; Speed: 150; Attack: akMelee; Damage: 5; AttackRange: 1000; AttackCooldown: 1.0; Flying: False; SoundDir: 'gek'; SightSound: 'gk_sght1'; PainSound: 'gk_pain1'; DeathSound: 'gk_deth1'; AttackSound: 'gk_atck1'),
    (ClassName: 'monster_fixbot'; Model: 'models/monsters/fixbot/tris.md2'; Skin: 0; Health: 150; Speed: 110; Attack: akBlaster; Damage: 15; AttackRange: 900; AttackCooldown: 2.0; Flying: True; SoundDir: 'flyer'; SightSound: 'flysght1'; PainSound: 'flypain1'; DeathSound: 'flydeth1'; AttackSound: ''),
    { Ground Zero (its PAK's hover / medic models have the variants' skin 2;
      facts from yquake2/rogue's hover.c, medic.c, stalker.c, turret.c) }
    (ClassName: 'monster_daedalus'; Model: 'models/monsters/hover/tris.md2'; Skin: 2; Health: 450; Speed: 120; Attack: akBlaster; Damage: 1; AttackRange: 900; AttackCooldown: 0.8; Flying: True; SoundDir: 'daedalus'; SightSound: 'daedsght1'; PainSound: 'daedpain1'; DeathSound: 'daeddeth1'; AttackSound: 'daedatck1'),
    (ClassName: 'monster_medic_commander'; Model: 'models/monsters/medic/tris.md2'; Skin: 2; Health: 600; Speed: 110; Attack: akBlaster; Damage: 2; AttackRange: 900; AttackCooldown: 0.4; Flying: False; SoundDir: 'medic_commander'; SightSound: 'medsght'; PainSound: 'medpain1'; DeathSound: 'meddeth'; AttackSound: 'medatck1a'),
    (ClassName: 'monster_stalker'; Model: 'models/monsters/stalker/tris.md2'; Skin: 0; Health: 250; Speed: 170; Attack: akBlaster; Damage: 15; AttackRange: 1000; AttackCooldown: 1.0; Flying: False; SoundDir: 'stalker'; SightSound: 'sight'; PainSound: 'pain'; DeathSound: 'death'; AttackSound: ''),
    (ClassName: 'monster_turret'; Model: 'models/monsters/turret/tris.md2'; Skin: 0; Health: 240; Speed: 0; Attack: akBlaster; Damage: 20; AttackRange: 2000; AttackCooldown: 1.2; Flying: True; SoundDir: ''; SightSound: ''; PainSound: ''; DeathSound: ''; AttackSound: ''),
    { Ground Zero's bosses (health by skill: CreateMonster) }
    (ClassName: 'monster_carrier'; Model: 'models/monsters/carrier/tris.md2'; Skin: 0; Health: 2000; Speed: 60; Attack: akHitscan; Damage: 6; AttackRange: 1500; AttackCooldown: 1.0; Flying: True; SoundDir: 'carrier'; SightSound: 'sight'; PainSound: 'pain_md'; DeathSound: 'death'; AttackSound: ''),
    (ClassName: 'monster_widow'; Model: 'models/monsters/blackwidow/tris.md2'; Skin: 0; Health: 2000; Speed: 80; Attack: akBlaster; Damage: 10; AttackRange: 1500; AttackCooldown: 1.0; Flying: False; SoundDir: 'widow'; SightSound: ''; PainSound: 'bw1pain1'; DeathSound: ''; AttackSound: ''),
    (ClassName: 'monster_widow2'; Model: 'models/monsters/blackwidow2/tris.md2'; Skin: 0; Health: 2800; Speed: 140; Attack: akHitscan; Damage: 10; AttackRange: 1500; AttackCooldown: 1.0; Flying: False; SoundDir: 'widow'; SightSound: ''; PainSound: 'bw2pain1'; DeathSound: 'death'; AttackSound: '')
  );

var
  { Monster definitions in use: DefaultMonsterDefs, then the overrides of
    the monster types design. Change only before monsters are created
    (FindMonsterDef returns pointers into it). }
  MonsterDefs: array of TQuakeMonsterDef;

{ Lookup tables (nil when the classname is unknown) }
function FindItemDef(const AClassName: String): PQuakeItemDef;
function FindMonsterDef(const AClassName: String): PQuakeMonsterDef;

type
  TGenericMoveKind = (gmWalk, gmFly, gmSwim);
  { A monster this port has no code for (Call of the Void's Quake 1 and
    hybrid monsters): its model, health, how it moves (facts from the
    mod's SP_monster_* functions) and a coarse attack by kind of monster
    (Quake 1's: melee, grenades, lasers, bolts, homing pods, lightning).
    It plays with the generic AI. Chthon gets 3000 health instead of 16:
    in Quake 1 only the level's electrodes kill him, which the generic AI
    can't do. }
  TGenericMonsterFact = record
    ClassName, ModelDir: String;
    Health: Integer;
    Move: TGenericMoveKind;
    Attack: TAttackKind;
    Damage: Integer;
    Range: Single;
  end;

const
  GenericMonsterFacts: array[0..53] of TGenericMonsterFact = (
    (ClassName: 'monster_arachnid'; ModelDir: 'models/monsters/arachnid'; Health: 1000; Move: gmWalk; Attack: akRail; Damage: 35; Range: 1200),
    (ClassName: 'monster_chthon'; ModelDir: 'models/monsters/chthon'; Health: 3000; Move: gmWalk; Attack: akRocket; Damage: 40; Range: 1500),
    (ClassName: 'monster_chtjor'; ModelDir: 'models/monsters/chtjor'; Health: 12000; Move: gmWalk; Attack: akRocket; Damage: 50; Range: 1500),
    (ClassName: 'monster_dog'; ModelDir: 'models/monsters/dog'; Health: 50; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_dog_prototype'; ModelDir: 'models/monsters/dog_prototype'; Health: 50; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_dog_strogg'; ModelDir: 'models/monsters/parasite/tip'; Health: 35; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_enforcer'; ModelDir: 'models/monsters/enforcer'; Health: 80; Move: gmWalk; Attack: akBlaster; Damage: 15; Range: 900),
    (ClassName: 'monster_enforcer_prototype'; ModelDir: 'models/monsters/enforcer_prototype'; Health: 100; Move: gmWalk; Attack: akBlaster; Damage: 15; Range: 900),
    (ClassName: 'monster_enforcer_strogg'; ModelDir: 'models/monsters/enforcerstrogg'; Health: 100; Move: gmWalk; Attack: akBlaster; Damage: 15; Range: 900),
    (ClassName: 'monster_fiend'; ModelDir: 'models/monsters/fiend'; Health: 300; Move: gmWalk; Attack: akMelee; Damage: 20; Range: 100),
    (ClassName: 'monster_fiend_prototype'; ModelDir: 'models/monsters/fiend_prototype'; Health: 300; Move: gmWalk; Attack: akMelee; Damage: 20; Range: 100),
    (ClassName: 'monster_fiend_strogg'; ModelDir: 'models/monsters/fiendstrogg'; Health: 300; Move: gmWalk; Attack: akMelee; Damage: 20; Range: 100),
    (ClassName: 'monster_fish'; ModelDir: 'models/monsters/fish'; Health: 25; Move: gmSwim; Attack: akMelee; Damage: 3; Range: 70),
    (ClassName: 'monster_fishgunner'; ModelDir: 'models/monsters/fishgunner'; Health: 225; Move: gmWalk; Attack: akHitscan; Damage: 4; Range: 900),
    (ClassName: 'monster_guardian'; ModelDir: 'models/monsters/guardian'; Health: 2500; Move: gmWalk; Attack: akRocket; Damage: 50; Range: 1500),
    (ClassName: 'monster_guncmdr'; ModelDir: 'models/monsters/gunner'; Health: 325; Move: gmWalk; Attack: akGrenade; Damage: 50; Range: 800),
    (ClassName: 'monster_hellknight'; ModelDir: 'models/monsters/hellknight'; Health: 250; Move: gmWalk; Attack: akBlaster; Damage: 9; Range: 900),
    (ClassName: 'monster_hknight_hyper'; ModelDir: 'models/monsters/hyperknight'; Health: 250; Move: gmWalk; Attack: akBlaster; Damage: 9; Range: 900),
    (ClassName: 'monster_hknight_prototype'; ModelDir: 'models/monsters/hellknight_prototype'; Health: 250; Move: gmWalk; Attack: akBlaster; Damage: 9; Range: 900),
    (ClassName: 'monster_hknight_strogg'; ModelDir: 'models/monsters/hellknightstrogg'; Health: 250; Move: gmWalk; Attack: akBlaster; Damage: 9; Range: 900),
    (ClassName: 'monster_hknight_bsk_strogg'; ModelDir: 'models/monsters/hellberserkerstrogg'; Health: 250; Move: gmWalk; Attack: akMelee; Damage: 20; Range: 90),
    (ClassName: 'monster_insane_spawn'; ModelDir: 'models/monsters/insane_spawn'; Health: 100; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_ironvore'; ModelDir: 'models/monsters/ironvore'; Health: 175; Move: gmWalk; Attack: akRocket; Damage: 40; Range: 1000),
    (ClassName: 'monster_knight'; ModelDir: 'models/monsters/knight'; Health: 75; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_knight_prototype'; ModelDir: 'models/monsters/knight_prototype'; Health: 75; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_knight_strogg'; ModelDir: 'models/monsters/knightstrogg'; Health: 100; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_mutantspawn'; ModelDir: 'models/monsters/mutantspawn'; Health: 300; Move: gmWalk; Attack: akMelee; Damage: 15; Range: 90),
    (ClassName: 'monster_ogre'; ModelDir: 'models/monsters/ogre'; Health: 200; Move: gmWalk; Attack: akGrenade; Damage: 40; Range: 800),
    (ClassName: 'monster_ogre_prototype'; ModelDir: 'models/monsters/ogre_prototype'; Health: 200; Move: gmWalk; Attack: akGrenade; Damage: 40; Range: 800),
    (ClassName: 'monster_ogre2_strogg'; ModelDir: 'models/monsters/ogre2strogg'; Health: 220; Move: gmWalk; Attack: akPellets; Damage: 4; Range: 700),
    (ClassName: 'monster_ogre_strogg'; ModelDir: 'models/monsters/ogrestrogg'; Health: 450; Move: gmWalk; Attack: akGrenade; Damage: 40; Range: 800),
    (ClassName: 'monster_rotflyer'; ModelDir: 'models/monsters/rotflyer'; Health: 50; Move: gmFly; Attack: akBlaster; Damage: 5; Range: 800),
    (ClassName: 'monster_shalrath'; ModelDir: 'models/monsters/shalrath'; Health: 400; Move: gmWalk; Attack: akRocket; Damage: 40; Range: 1000),
    (ClassName: 'monster_shalrath_prototype'; ModelDir: 'models/monsters/shalrath_prototype'; Health: 400; Move: gmWalk; Attack: akRocket; Damage: 40; Range: 1000),
    (ClassName: 'monster_shalrath_strogg'; ModelDir: 'models/monsters/shalrathstrogg'; Health: 400; Move: gmWalk; Attack: akRocket; Damage: 40; Range: 1000),
    (ClassName: 'monster_shamacudda'; ModelDir: 'models/monsters/shamacudda'; Health: 600; Move: gmWalk; Attack: akHitscan; Damage: 8; Range: 600),
    (ClassName: 'monster_shambler'; ModelDir: 'models/monsters/shambler'; Health: 600; Move: gmWalk; Attack: akHitscan; Damage: 8; Range: 600),
    (ClassName: 'monster_shambler_prototype'; ModelDir: 'models/monsters/shambler_prototype'; Health: 600; Move: gmWalk; Attack: akHitscan; Damage: 8; Range: 600),
    (ClassName: 'monster_shambler_strogg'; ModelDir: 'models/monsters/shamblerstrogg'; Health: 775; Move: gmWalk; Attack: akHitscan; Damage: 8; Range: 600),
    (ClassName: 'monster_shamedic'; ModelDir: 'models/monsters/shamblerthunder'; Health: 550; Move: gmWalk; Attack: akHitscan; Damage: 8; Range: 600),
    (ClassName: 'monster_shamjorg'; ModelDir: 'models/monsters/shamjorg'; Health: 12000; Move: gmWalk; Attack: akRocket; Damage: 50; Range: 1500),
    (ClassName: 'monster_soldier_grunt'; ModelDir: 'models/monsters/grunt'; Health: 60; Move: gmWalk; Attack: akPellets; Damage: 4; Range: 700),
    (ClassName: 'monster_soldier_grunt_double'; ModelDir: 'models/monsters/grunt_double'; Health: 60; Move: gmWalk; Attack: akPellets; Damage: 4; Range: 700),
    (ClassName: 'monster_soldier_grunt_prototype'; ModelDir: 'models/monsters/grunt_prototype'; Health: 30; Move: gmWalk; Attack: akPellets; Damage: 4; Range: 700),
    (ClassName: 'monster_soldier_strogg'; ModelDir: 'models/monsters/grunt_strogg'; Health: 30; Move: gmWalk; Attack: akPellets; Damage: 4; Range: 700),
    (ClassName: 'monster_spawn'; ModelDir: 'models/monsters/spawn'; Health: 80; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_supershamblertank'; ModelDir: 'models/monsters/shamblertank'; Health: 3000; Move: gmWalk; Attack: akRocket; Damage: 50; Range: 1500),
    (ClassName: 'monster_wizard'; ModelDir: 'models/monsters/wizard'; Health: 80; Move: gmFly; Attack: akBlaster; Damage: 9; Range: 800),
    (ClassName: 'monster_wizarcuda_strogg'; ModelDir: 'models/monsters/scraggacuda'; Health: 120; Move: gmFly; Attack: akBlaster; Damage: 9; Range: 800),
    (ClassName: 'monster_wizard_prototype'; ModelDir: 'models/monsters/wizard_prototype'; Health: 80; Move: gmFly; Attack: akBlaster; Damage: 9; Range: 800),
    (ClassName: 'monster_wizard_strogg'; ModelDir: 'models/monsters/wizardstrogg'; Health: 120; Move: gmFly; Attack: akBlaster; Damage: 9; Range: 800),
    (ClassName: 'monster_zombie'; ModelDir: 'models/monsters/zombie'; Health: 60; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_zombie_prototype'; ModelDir: 'models/monsters/zombie_prototype'; Health: 60; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80),
    (ClassName: 'monster_zombie_strogg'; ModelDir: 'models/monsters/zombiestrogg'; Health: 60; Move: gmWalk; Attack: akMelee; Damage: 10; Range: 80)
  );

{ A definition for a monster without one of its own (GenericMonsterFacts,
  or any monster_<name> with models/monsters/<name>/tris.md2), only when
  its model is in the loaded PAKs; nil otherwise. FindMonsterDef falls
  back to it. }
function GenericMonsterDef(const AClassName: String): PQuakeMonsterDef;
{ Is this definition one of GenericMonsterDef's }
function IsGenericMonsterDef(const Def: PQuakeMonsterDef): Boolean;

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
  { trigger_disguise (Ground Zero, FL_DISGUISED): monsters don't notice the
    player by sight }
  PlayerDisguised: Boolean = False;
  { Ground Zero's IR goggles on: monsters are drawn glowing red }
  IRGogglesOn: Boolean = False;
  { The player's trail (created and fed by TQuakeWorld) }
  PlayerTrail: TQuakePlayerTrail;
  { The level's hint_path chains (nil without any; owned by the world) and
    a sight test between two points (CGE, MASK_OPAQUE) for them }
  HintPaths: TQuakeHintPaths;
  HintSight: function(const FromPos, ToPos: TVector3): Boolean of object;
  { The player's box (CGE space), set by the world each frame: monsters
    don't walk into it (only used without EntityTrace) }
  PlayerBlockBox: TBox3D;
  { Box traces through the world for entities (map brushes, movers,
    monster boxes, the player's box; Quake coordinates), skipping Ignore.
    Set by TQuakeWorld; without it monsters use CGE collisions. }
  EntityTrace: TEntityTraceFunc;
  { Can a sight line between two points (CGE space) be clear at all (the
    PVS); set by TQuakeWorld. Sight traces are skipped when it says no. }
  EntitySightPossible: function(const FromPos, ToPos: TVector3): Boolean of object;
  { Sight traces skipped by EntitySightPossible, for the benchmark }
  SightTracesSkipped: Int64;
  { Contents of the map's brushes at a Quake point (swimming monsters);
    set by TQuakeWorld }
  EntityPointContents: function(const QuakePos: TVector3): Integer of object;
  { A fixbot finished a weld cycle (7 frames) on a func_object_repair;
    returns True when the repair is done (TQuakeWorld) }
  MonsterWeldCycle: function(const Target: TQuakeEntity): Boolean of object;

{ Quake 2 bounding box of a monster class (mins / maxs around its origin),
  moved so the bottom is at -24 like every monster's origin here }
procedure MonsterBoxSize(const MonsterClass: String; out Mins, Maxs: TVector3);
{ Quake 2's own box of a monster class (True: used as it is, a flyer or
  a turret whose origin is its middle) }
function QuakeMonsterBox(const MonsterClass: String; out Mins, Maxs: TVector3): Boolean;
{ How much lower than our origin its model is drawn (CGE units): Quake's
  origin is at mins.z above the box's bottom (0 for most monsters, -24 for
  the chick, Jorg, the Makron, the supertank, the Widows) }
function MonsterModelOffset(const MonsterClass: String): Single;

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

{ A monster's mass (the SP_monster_* functions' self->mass; 200 when not
  known). Traps (Trap_Think) swallow monsters under 400 and leave a food
  cube of a tenth of it. }
function MonsterMass(const MonsterClass: String): Integer;

implementation

uses
  QuakeQ1Monsters, QuakeInsane, QuakeTurret;

procedure AdaptVariantAttacks(var Seqs: TMonsterAttackSeqs; const Def: PQuakeMonsterDef); forward;

function MonsterMass(const MonsterClass: String): Integer;
const
  Masses: array[0..30] of record
    ClassName: String;
    Mass: Integer;
  end = (
    (ClassName: 'monster_soldier'; Mass: 100), (ClassName: 'monster_infantry'; Mass: 200),
    (ClassName: 'monster_gunner'; Mass: 200), (ClassName: 'monster_berserk'; Mass: 250),
    (ClassName: 'monster_gladiator'; Mass: 400), (ClassName: 'monster_gladb'; Mass: 350),
    (ClassName: 'monster_flyer'; Mass: 50), (ClassName: 'monster_parasite'; Mass: 250),
    (ClassName: 'monster_tank'; Mass: 500), (ClassName: 'monster_medic'; Mass: 400),
    (ClassName: 'monster_chick'; Mass: 200), (ClassName: 'monster_mutant'; Mass: 300),
    (ClassName: 'monster_brain'; Mass: 400), (ClassName: 'monster_floater'; Mass: 300),
    (ClassName: 'monster_hover'; Mass: 150), (ClassName: 'monster_flipper'; Mass: 100),
    (ClassName: 'monster_supertank'; Mass: 800), (ClassName: 'monster_boss5'; Mass: 800),
    (ClassName: 'monster_boss2'; Mass: 1000), (ClassName: 'monster_jorg'; Mass: 1000),
    (ClassName: 'monster_makron'; Mass: 500), (ClassName: 'misc_insane'; Mass: 300),
    (ClassName: 'monster_gekk'; Mass: 300), (ClassName: 'monster_fixbot'; Mass: 150),
    (ClassName: 'monster_daedalus'; Mass: 225), (ClassName: 'monster_medic_commander'; Mass: 600),
    (ClassName: 'monster_stalker'; Mass: 250), (ClassName: 'monster_turret'; Mass: 250),
    (ClassName: 'monster_carrier'; Mass: 1000), (ClassName: 'monster_widow'; Mass: 1500),
    (ClassName: 'monster_widow2'; Mass: 2500));
var
  I, Best: Integer;
begin
  { The longest matching prefix: monster_soldier_light is a soldier,
    monster_tank_commander a tank, monster_chick_heat a chick }
  Result := 200;
  Best := 0;
  for I := Low(Masses) to High(Masses) do
    if (Pos(Masses[I].ClassName, MonsterClass) = 1) and (Length(Masses[I].ClassName) > Best) then
    begin
      Best := Length(Masses[I].ClassName);
      Result := Masses[I].Mass;
    end;
end;

function MonsterGibs(const MonsterClass: String): TMonsterGibs;

  procedure Add(const Model: String; const Count: Integer; const Metallic: Boolean = False);
  begin
    SetLength(Result.Pieces, Length(Result.Pieces) + 1);
    { A gib of models/objects/gibs, or a model's own folder ("gekkgib/arm") }
    if Pos('/', Model) > 0 then
      Result.Pieces[High(Result.Pieces)].Model := 'models/objects/' + Model + '/tris.md2'
    else
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
  if (MonsterClass = 'monster_flyer') or (MonsterClass = 'monster_floater') then
  begin
    { flyer_die / floater_die: BecomeExplosion1, always }
    Result.GibHealth := -50;
    Result.Explodes := True;
  end else
  if MonsterClass = 'monster_gekk' then
  begin
    { gekk_die: acid gibs (gekkgib: pelvis, two arms, torso, claw, two legs,
      head), gib_health -30 }
    Result.GibHealth := -30;
    Result.Pieces := nil;
    Add('gekkgib/pelvis', 1);
    Add('gekkgib/arm', 2);
    Add('gekkgib/torso', 1);
    Add('gekkgib/claw', 1);
    Add('gekkgib/leg', 2);
    Add('gekkgib/head', 1);
  end else
  if MonsterClass = 'monster_stalker' then
  begin
    { stalker_die: 2 bones, 4 small meats and a head below -50 }
    Result.GibHealth := -50;
    Add('bone', 2);
    Add('sm_meat', 4);
    Add('head2', 1);
  end else
  if MonsterClass = 'monster_carrier' then
    Result.GibHealth := -200
  else
  if MonsterClass = 'monster_widow' then
    Result.GibHealth := -5000
  else
  if MonsterClass = 'monster_widow2' then
    Result.GibHealth := -900
  else
  if MonsterClass = 'monster_turret' then
  begin
    { turret_die: an explosion and debris, always }
    Result.GibHealth := -100;
    Result.Explodes := True;
  end else
  if MonsterClass = 'monster_fixbot' then
  begin
    { fixbot_die: BecomeExplosion1, always }
    Result.GibHealth := -50;
    Result.Explodes := True;
  end else
  if (XatrixBaseClass(MonsterClass) <> '') and (Copy(MonsterClass, 1, 16) <> 'monster_soldier_') then
  begin
    { The heat chick, the beta gladiator, boss5: their base monster's }
    Result := MonsterGibs(XatrixBaseClass(MonsterClass));
    Exit;
  end else
  if (MonsterClass = 'monster_supertank') or (MonsterClass = 'monster_jorg') or
     (MonsterClass = 'monster_boss2') then
  begin
    { supertank_die / jorg_die / boss2_die never gib: their death ends in
      BossExplode (TQuakeWorld.UpdateBossExplosions) }
    Result.GibHealth := -100000;
    Add('sm_metal', 4, True);
  end else
  begin
    { gib_health of the full game's monsters (m_*.c SP_monster_*) }
    if MonsterClass = 'monster_gladiator' then
      Result.GibHealth := -175
    else
    if MonsterClass = 'monster_chick' then
      Result.GibHealth := -70
    else
    if MonsterClass = 'monster_mutant' then
      Result.GibHealth := -120
    else
    if MonsterClass = 'monster_brain' then
      Result.GibHealth := -150
    else
    if MonsterClass = 'monster_hover' then
      Result.GibHealth := -100
    else
    if MonsterClass = 'monster_flipper' then
      Result.GibHealth := -30
    else
    if MonsterClass = 'monster_medic' then
      Result.GibHealth := -130
    else
    if MonsterClass = 'monster_makron' then
      Result.GibHealth := -2000
    else
    if MonsterClass = 'misc_insane' then
      Result.GibHealth := -50;
    Add('bone', 2);
    Add('sm_meat', 4);
    Add('head2', 1);
  end;
end;

function QuakeMonsterBox(const MonsterClass: String; out Mins, Maxs: TVector3): Boolean;
begin
  Result := False;
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
  end else
  if MonsterClass = 'monster_boss2' then
  begin
    Mins := Vector3(-56, -56, 0); Maxs := Vector3(56, 56, 80);
  end else
  if MonsterClass = 'monster_jorg' then
  begin
    Mins := Vector3(-80, -80, 0); Maxs := Vector3(80, 80, 140);
  end else
  if MonsterClass = 'monster_makron' then
  begin
    Mins := Vector3(-30, -30, 0); Maxs := Vector3(30, 30, 90);
  end else
  { The Reckoning: the variants have their base's box; the gekk 48 x 48 x 48
    (40 high while it swims: SetSwimming), the fixbot 64 x 64 x 48 }
  if XatrixBaseClass(MonsterClass) <> '' then
  begin
    Exit(QuakeMonsterBox(XatrixBaseClass(MonsterClass), Mins, Maxs));
  end else
  if MonsterClass = 'monster_gekk' then
  begin
    Mins := Vector3(-24, -24, -24); Maxs := Vector3(24, 24, 24);
  end else
  if MonsterClass = 'monster_fixbot' then
  begin
    Mins := Vector3(-32, -32, -24); Maxs := Vector3(32, 32, 24);
  end else
  if MonsterClass = 'monster_stalker' then
  begin
    Mins := Vector3(-28, -28, -18); Maxs := Vector3(28, 28, 18);
  end else
  if MonsterClass = 'monster_carrier' then
  begin
    { It flies: Quake's box around its origin, not moved to the feet }
    Mins := Vector3(-56, -56, -44); Maxs := Vector3(56, 56, 44);
    Exit(True);
  end else
  if MonsterClass = 'monster_widow' then
  begin
    Mins := Vector3(-40, -40, 0); Maxs := Vector3(40, 40, 144);
  end else
  if MonsterClass = 'monster_widow2' then
  begin
    Mins := Vector3(-70, -70, 0); Maxs := Vector3(70, 70, 144);
  end else
  if MonsterClass = 'monster_turret' then
  begin
    { A 24 cube around its origin, in the wall it hangs on }
    Mins := Vector3(-12, -12, -12); Maxs := Vector3(12, 12, 12);
    Exit(True);
  end;
end;

procedure MonsterBoxSize(const MonsterClass: String; out Mins, Maxs: TVector3);
var
  Height: Single;
begin
  if QuakeMonsterBox(MonsterClass, Mins, Maxs) then
    Exit;
  { Our monster origins are 24 above the feet }
  Height := Maxs.Z - Mins.Z;
  Mins.Z := -24;
  Maxs.Z := -24 + Height;
end;

function MonsterModelOffset(const MonsterClass: String): Single;
var
  Mins, Maxs: TVector3;
begin
  { Quake draws a model at the entity's origin, mins.z above the box's
    bottom; ours is always 24 above it }
  if QuakeMonsterBox(MonsterClass, Mins, Maxs) then
    Result := 0
  else
    Result := -24 - Mins.Z;
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

var
  { Heap records (MonsterDefs can be reallocated; monsters keep pointers) }
  GenericDefs: specialize TList<PQuakeMonsterDef>;

function GenericMonsterDef(const AClassName: String): PQuakeMonsterDef;
var
  I: Integer;
  ModelDir, Model: String;
  Fact: TGenericMonsterFact;
  Found: Boolean;
begin
  Result := nil;
  if Copy(AClassName, 1, 8) <> 'monster_' then
    Exit;
  if GenericDefs = nil then
    GenericDefs := specialize TList<PQuakeMonsterDef>.Create;
  for I := 0 to GenericDefs.Count - 1 do
    if GenericDefs[I]^.ClassName = AClassName then
      Exit(GenericDefs[I]);
  Found := False;
  Fact := Default(TGenericMonsterFact);
  for I := 0 to High(GenericMonsterFacts) do
    if GenericMonsterFacts[I].ClassName = AClassName then
    begin
      Fact := GenericMonsterFacts[I];
      Found := True;
    end;
  if Found then
    ModelDir := Fact.ModelDir
  else
  begin
    { Any other monster_<name>: models/monsters/<name>, ranged }
    ModelDir := 'models/monsters/' + Copy(AClassName, 9, MaxInt);
    Fact.Health := 100;
    Fact.Move := gmWalk;
    Fact.Attack := akHitscan;
    Fact.Damage := 4;
    Fact.Range := 900;
  end;
  Model := ModelDir + '/tris.md2';
  if not Pak.FileExists(Model) then
    Exit;
  New(Result);
  Result^ := Default(TQuakeMonsterDef);
  Result^.ClassName := AClassName;
  Result^.Model := Model;
  Result^.Health := Fact.Health;
  Result^.Attack := Fact.Attack;
  Result^.Damage := Fact.Damage;
  Result^.AttackRange := Fact.Range;
  if Fact.Attack = akMelee then
  begin
    Result^.Speed := 170;
    Result^.AttackCooldown := 0.8;
  end else
  begin
    Result^.Speed := 110;
    Result^.AttackCooldown := 1.5;
  end;
  Result^.Flying := Fact.Move in [gmFly, gmSwim];
  { Sounds: sound/<model folder>/ (MonsterSoundLike finds idle / search) }
  Result^.SoundDir := ExtractFileName(ModelDir);
  GenericDefs.Add(Result);
  WritelnLog('QuakeEntities', 'Generic monster %s: %s, health %d', [AClassName, Model, Result^.Health]);
end;

function IsGenericMonsterDef(const Def: PQuakeMonsterDef): Boolean;
begin
  Result := (Def <> nil) and (GenericDefs <> nil) and (GenericDefs.IndexOf(Def) >= 0);
end;

function FindMonsterDef(const AClassName: String): PQuakeMonsterDef;
var
  I: Integer;
begin
  for I := 0 to High(MonsterDefs) do
    if MonsterDefs[I].ClassName = AClassName then
      Exit(@MonsterDefs[I]);
  Result := GenericMonsterDef(AClassName);
end;

procedure FreeGenericDefs;
var
  I: Integer;
begin
  if GenericDefs = nil then
    Exit;
  for I := 0 to GenericDefs.Count - 1 do
    Dispose(GenericDefs[I]);
  FreeAndNil(GenericDefs);
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
var
  Skin: Integer;
  SwapZ: Single;
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
  { Call of the Void's variants keep their own weapon (the strogg ogre's
    pellets, the berserker hell knight's melee only) }
  if IsGenericMonsterDef(Def) then
    AdaptVariantAttacks(FAttackSeqs, Def);
  FMove := TMonsterMoveAnim.Create;
  FWalkSeq := MonsterMoveSeq(Def^.ClassName, False);
  FRunSeq := MonsterMoveSeq(Def^.ClassName, True);
  FSwimSeq := MonsterSwimSeq(Def^.ClassName);
  FWaterAttackSeqs := MonsterWaterAttackSeqs(Def^.ClassName);
  MonsterBoxSize(Def^.ClassName, BoxMins, BoxMaxs);
  Skin := Def^.Skin;
  if Def^.ClassName = 'misc_insane' then
  begin
    { SP_misc_insane: one of three skins; a crucified one hangs in a thin
      box (no gravity, never moves) }
    GoodGuy := True;
    Skin := Random(3);
    FInsaneWalk := Random < 0.5;
    FInsaneTimer := 4 + Random * 10;
    if (AEntity.SpawnFlags and INSANE_CRUCIFIED) <> 0 then
    begin
      BoxMins := Vector3(-16, 0, 0);
      BoxMaxs := Vector3(16, 8, 32);
      FDropped := True;
    end;
  end;
  { Quake 2 base game: only the brain has power armor (a power screen) }
  if Def^.ClassName = 'monster_brain' then
  begin
    PowerArmorType := paScreen;
    PowerArmorPower := 100;
  end;
  { The Reckoning: power shields on the beta gladiator (250) and boss5 (400),
    unless the map gives its own "power_armor_power" }
  { Ground Zero: the daedalus has a power screen of 100 }
  if Def^.ClassName = 'monster_daedalus' then
  begin
    PowerArmorType := paScreen;
    PowerArmorPower := AEntity.GetInt('power_armor_power', 100);
  end;
  { Ground Zero's bosses: health and spawning slots by skill, power
    shields on nightmare }
  if Def^.ClassName = 'monster_carrier' then
  begin
    Health := Max(2000, 2000 + 1000 * (GameSkill - 1));
    case GameSkill of
      0: MonsterSlots := 3;
      3: MonsterSlots := 9;
      else MonsterSlots := 6;
    end;
  end;
  if (Def^.ClassName = 'monster_widow') or (Def^.ClassName = 'monster_widow2') then
  begin
    if Def^.ClassName = 'monster_widow' then
      Health := 2000 + 1000 * GameSkill
    else
      Health := 2800 + 1000 * GameSkill;
    case GameSkill of
      0, 1: MonsterSlots := 3;
      2: MonsterSlots := 4;
      else MonsterSlots := 6;
    end;
    if GameSkill >= 3 then
    begin
      PowerArmorType := paShield;
      if Def^.ClassName = 'monster_widow' then
        PowerArmorPower := 500
      else
        PowerArmorPower := 750;
    end;
  end;
  { The medic commander's reinforcement slots by skill }
  if Def^.ClassName = 'monster_medic_commander' then
    case GameSkill of
      0: MonsterSlots := 3;
      1: MonsterSlots := 4;
      else MonsterSlots := 6;
    end;
  if Def^.ClassName = 'monster_turret' then
  begin
    { SP_monster_turret: the weapon from the spawnflags (heatbeam is a
      blaster), the skin with it; no gravity, never dropped }
    FDropped := True;
    if (AEntity.SpawnFlags and 16) <> 0 then
      TurretWeapon := 1
    else
    if (AEntity.SpawnFlags and 32) <> 0 then
      TurretWeapon := 2
    else
      TurretWeapon := 0;
    Skin := TurretWeapon;
    TurretFacing := AEntity.GetFloat('angle', 0);
    TurretWallWaiting := ((AEntity.SpawnFlags and 128) <> 0) and (AEntity.TargetName <> '');
  end;
  if (Def^.ClassName = 'monster_stalker') and ((AEntity.SpawnFlags and 8) <> 0) then
  begin
    { STALKER_ON_CEILING: upside down; its box mirrored }
    OnCeiling := True;
    FDropped := True;
    SwapZ := BoxMins.Z;
    BoxMins.Z := -BoxMaxs.Z;
    BoxMaxs.Z := -SwapZ;
  end;
  if (Def^.ClassName = 'monster_gladb') or (Def^.ClassName = 'monster_boss5') then
  begin
    PowerArmorType := paShield;
    if Def^.ClassName = 'monster_gladb' then
      PowerArmorPower := AEntity.GetInt('power_armor_power', 250)
    else
      PowerArmorPower := AEntity.GetInt('power_armor_power', 400);
  end;

  MaxHealth := Health;
  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Monster%.3d_%s', [NextEntityNumber, Def^.ClassName]);
  Transform.Translation := Pos;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(Yaw));
  Transform.CollisionSphereRadius := 16;

  Model := Md2Manager.CreateInstance(Def^.Model, Skin);
  { Jorg: the Makron riding (modelindex) on Jorg's legs (modelindex2) }
  if (Model <> nil) and (Def^.ClassName = 'monster_jorg') then
  begin
    FModel2 := Md2Manager.CreateInstance('models/monsters/boss3/jorg/tris.md2');
    if FModel2 <> nil then
    begin
      FModel2.Scene.Collides := False;
      FModel2.Scene.Pickable := False;
      Model.Follower := FModel2;
    end;
  end;
  if Model <> nil then
  begin
    Model.Scene.Name := Transform.Name + '_Model';
    { Monsters block the player, and are found by ray casts (see OwnsTransform) }
    Model.Scene.Collides := True;
    Model.Scene.PreciseCollisions := False;
    if FModel2 <> nil then
      Transform.Add(FModel2.Scene);
    Transform.Add(Model.Scene);
    { The stalker on the ceiling: upside down (roll 180) }
    if OnCeiling then
      Model.Scene.Rotation := Vector4(1, 0, 0, Pi);
    { Drawn from Quake's origin (MonsterModelOffset); upside down the
      other way }
    if OnCeiling then
      Model.Scene.Translation := Vector3(0, -MonsterModelOffset(Def^.ClassName), 0)
    else
      Model.Scene.Translation := Vector3(0, MonsterModelOffset(Def^.ClassName), 0);
    if FModel2 <> nil then
      FModel2.Scene.Translation := Model.Scene.Translation;
  end;
  if IsTurretMonster then
  begin
    { The mounting: facing up / down (pitch 270 / 90), else the wall's yaw;
      2 units out of the wall }
    if TurretFacing = -1 then
    begin
      TurretAimPitch := 270;
      TurretAimYaw := 0;
      Transform.Translation := Transform.Translation + Vector3(0, 2, 0);
    end else
    if TurretFacing = -2 then
    begin
      TurretAimPitch := 90;
      TurretAimYaw := 0;
      Transform.Translation := Transform.Translation - Vector3(0, 2, 0);
    end else
    begin
      TurretAimPitch := 0;
      TurretAimYaw := TurretFacing;
      Transform.Translation := Transform.Translation + YawToCgeDir(TurretFacing) * 2;
    end;
    FacingAngle := TurretAimYaw;
    Transform.Rotation := TurretRotation(TurretAimPitch, TurretAimYaw);
    if (AEntity.SpawnFlags and 128) <> 0 then
    begin
      { turret_wall_spawn: the base it comes out of }
      FTurretBase := TCastleTransform.Create(nil);
      FTurretBase.Name := Transform.Name + '_Base';
      FTurretBase.Translation := Transform.Translation;
      FTurretBase.Rotation := Transform.Rotation;
      FTurretBaseModel := Md2Manager.CreateInstance('models/monsters/turretbase/tris.md2');
      if FTurretBaseModel <> nil then
      begin
        FTurretBaseModel.Scene.Collides := False;
        FTurretBaseModel.Scene.Pickable := False;
        FTurretBaseModel.SetTint(Lighting.SampleLight(Pos));
        FTurretBase.Add(FTurretBaseModel.Scene);
      end;
      AParent.Add(FTurretBase);
      FTurretOutSpeed := Max(1, AEntity.GetFloat('speed', 15));
    end;
  end;
  SetState(msIdle);
  Ambush := (AEntity.SpawnFlags and 1) <> 0;
  if IsFixbot then
    FRoamFlags := AEntity.SpawnFlags and (4 or 8 or 16);
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
  { Gibbed while dormant: removed for good (misc_nuke) }
  if (not Dormant) or Gibbed then
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
    (Def^.ClassName = 'monster_medic') or (Def^.ClassName = 'monster_medic_commander') or
    (Def^.ClassName = 'monster_chick');
end;

procedure TQuakeMonster.Dodge(const Eta: Single);
begin
  if Def^.ClassName = 'monster_stalker' then
  begin
    { stalker_dodge: a jump straight up (off the ceiling there) unless the
      shot is about to hit or far off; a quarter of the time on easy
      (check_dodge) }
    if Dormant or not IsAlive or (Model = nil) or (FFalseDeath > 0) or FJumping or FCeilingJump then
      Exit;
    if (Eta < 0.1) or (Eta > 5) or ((GameSkill = 0) and (Random > 0.25)) then
      Exit;
    if not Alerted then
      Alert;
    JumpStraightUp;
    Exit;
  end;
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
  if not Model.PlayAnim(AnimNames('duck'), False, 5 / FDuckTime) then
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
  if PlayerDisguised then
    Exit(False);
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
  if Assigned(EntitySightPossible) and not EntitySightPossible(FromPos, ToPos) then
  begin
    Inc(SightTracesSkipped);
    Exit(False);
  end;
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
  if OnCeiling then
  begin
    { SV_movestep upside down: from a step below the wished position,
      push up two steps; it must find the ceiling }
    NewOrg := Org + Move;
    NewOrg.Z := NewOrg.Z - StepSize;
    EndPos := NewOrg + Vector3(0, 0, StepSize * 2);
    T := MTrace(NewOrg, EndPos, BoxMins, BoxMaxs);
    if T.AllSolid or T.StartSolid or (T.Fraction >= 1) or not ClearToMoveTo(Org, T.EndPos) then
      Exit(False);
    SetOrigin(T.EndPos);
    Exit(True);
  end;
  if Flies then
  begin
    { Flyers: the whole move must be free }
    T := MTrace(Org, Org + Move, BoxMins, BoxMaxs);
    if T.AllSolid or T.StartSolid or (T.Fraction < 1) or not ClearToMoveTo(Org, T.EndPos) then
      Exit(False);
    { SV_movestep with FL_SWIM: the bottom stays in the water }
    if Swimming and not WaterAt(T.EndPos + Vector3(0, 0, BoxMins.Z + 1)) then
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
  if not ClearToMoveTo(Org, T.EndPos) then
    Exit(False);
  SetOrigin(T.EndPos);
  Result := True;
end;

function TQuakeMonster.ClearToMoveTo(const FromPos, ToPos: TVector3): Boolean;
const
  { Overlap allowed: exact contact (maps place monsters against walls) and
    the DIST_EPSILON gaps of traces aren't stuck }
  Slack = 0.0625;
  SlackV: TVector3 = (X: Slack; Y: Slack; Z: Slack);
begin
  { A swept trace stops at the first thing it hits at fraction 0 (the floor
    a walker stands on), so it can miss a brush the box overlaps higher up
    (a ledge, an angled wall): test the new spot itself. A monster already
    stuck may move anywhere (it has to get out somehow). }
  Result := (not MTrace(ToPos, ToPos, BoxMins + SlackV, BoxMaxs - SlackV).StartSolid) or
    MTrace(FromPos, FromPos, BoxMins + SlackV, BoxMaxs - SlackV).StartSolid;
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
  FreeAndNil(FScreenModel);
  if Model <> nil then
    Model.Follower := nil;
  FreeAndNil(FModel2);
  FreeAndNil(Model);
  FreeAndNil(FTurretBaseModel);
  FreeAndNil(FTurretBase);
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
      Model.PlayAnim(AnimNames('death,die,dead'), False, 10);
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
    Model.PlayAnim(AnimNames('stand'), True, 10);
    Exit;
  end;
  case NewState of
    msIdle: Model.PlayAnim(AnimNames('stand,idle,fidget'), True, 10);
    msChase:
      if not Model.PlayAnim(AnimNames('run'), True, 10) then
        Model.PlayAnim(AnimNames('walk,stand'), True, 10);
    msAttack: Model.PlayAnim(AnimNames('attak,attack,atk,fire,shoot,melee,swing,stand'), False, 12);
    msPain: Model.PlayAnim(AnimNames('pain'), False, 12);
    msDuck: ; { started by Dodge, which picks the speed }
    msDying: Model.PlayAnim(AnimNames('death,die,dead'), False, 10);
    msDead: ;
  end;
end;

procedure TQuakeMonster.Alert;
begin
  if Alerted or not IsAlive or NoTarget or Dormant or GoodGuy then
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
    Model.PlayAnim(AnimNames('walk,run'), True, 10)
  else
    Model.PlayAnim(AnimNames('stand,idle,fidget'), True, 10);
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
  if not Flies then
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
    OnUseTargets(Corner.GetField('pathtarget'), Corner);
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
    OnUseTargets(Point.GetField('pathtarget'), Point);
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
  { The fixbot revives the dead too (fixbot_search, AI_MEDIC) }
  Result := (Def^.ClassName = 'monster_medic') or (Def^.ClassName = 'monster_medic_commander') or IsFixbot;
end;

function TQuakeMonster.IsFixbot: Boolean;
begin
  Result := Def^.ClassName = 'monster_fixbot';
end;

function TQuakeMonster.Flies: Boolean;
begin
  Result := Def^.Flying or Swimming;
end;

function TQuakeMonster.WaterAt(const QuakePos: TVector3): Boolean;
const
  MASK_WATER = 8 or 16 or 32; { CONTENTS_LAVA | SLIME | WATER }
begin
  Result := Assigned(EntityPointContents) and ((EntityPointContents(QuakePos) and MASK_WATER) <> 0);
end;

procedure TQuakeMonster.SetSwimming(const Value: Boolean);
begin
  if Swimming = Value then
    Exit;
  Swimming := Value;
  if Value then
  begin
    { land_to_water: the swim loop and the water attacks }
    FLandWalkSeq := FWalkSeq;
    FLandRunSeq := FRunSeq;
    FLandAttackSeqs := FAttackSeqs;
    FWalkSeq := FSwimSeq;
    FRunSeq := FSwimSeq;
    if Length(FWaterAttackSeqs) > 0 then
      FAttackSeqs := FWaterAttackSeqs;
    { land_to_water: the box's top 8 lower (maxs 16) }
    BoxMaxs.Z := BoxMaxs.Z - 8;
    FSwimTimer := 0.4;
    WritelnLog('QuakeEntities', '%s swims at %s', [Transform.Name, Origin.ToString]);
  end else
  begin
    FWalkSeq := FLandWalkSeq;
    FRunSeq := FLandRunSeq;
    FAttackSeqs := FLandAttackSeqs;
    { water_to_land: the land box back }
    BoxMaxs.Z := BoxMaxs.Z + 8;
    WritelnLog('QuakeEntities', '%s leaves the water at %s', [Transform.Name, Origin.ToString]);
  end;
  FMove.Stop;
  if (State in [msIdle, msChase]) and (Model <> nil) then
    SetState(State);
end;

procedure TQuakeMonster.UpdateSwimming(const SecondsPassed: Single; const PlayerPos: TVector3);
var
  Dir, Feet, Up: TVector3;
begin
  if (Length(FSwimSeq.Dists) = 0) or Dormant or not IsAlive or not Assigned(EntityPointContents) then
    Exit;
  FLeaveWaterTimer := Max(0, FLeaveWaterTimer - SecondsPassed);
  if not Swimming then
  begin
    { gekk_check_underwater: any water at its feet -> land_to_water }
    if (FLeaveWaterTimer = 0) and (not FJumping) and WaterAt(Origin + Vector3(0, 0, BoxMins.Z + 1)) then
      SetSwimming(True);
    Exit;
  end;
  { gekk_swim at the end of each swim loop (4 frames): after an enemy whose
    feet are out of the water, 30 % of the time, water_to_land }
  FSwimTimer := FSwimTimer - SecondsPassed;
  if FSwimTimer > 0 then
    Exit;
  FSwimTimer := FSwimTimer + 0.4;
  if (not Alerted) or (State <> msChase) then
    Exit;
  Feet := CgeToQuake(PlayerPos) - Vector3(0, 0, 45);
  if WaterAt(Feet) or (Random <= 0.7) then
    Exit;
  SetSwimming(False);
  FLeaveWaterTimer := 2;
  { gekk_jump_takeoff2: up to the player's height first (where its box
    fits), then forward 300, up 250, at the player; its touch hurts 10 .. 19 }
  Up := Origin;
  Up.Z := Max(Up.Z, CgeToQuake(PlayerPos).Z - 22);
  if (Up.Z > Origin.Z) and Assigned(EntityTrace) and not MTrace(Up, Up, BoxMins, BoxMaxs).StartSolid then
    SetOrigin(Up);
  Dir := PlayerPos - Transform.Translation;
  Dir.Y := 0;
  if Dir.IsZero then
    Dir := YawToCgeDir(FacingAngle)
  else
    Dir := Dir.Normalize;
  FJumpVel := Dir * 300;
  FJumpVel.Y := 250;
  FJumping := True;
  LeapDamage := 10 + Random(10);
  if Model <> nil then
    Model.PlayAnim('leapatk', False, 10);
end;

function TQuakeMonster.UpdateWeld(const SecondsPassed: Single): Boolean;
var
  Target, Delta, Fwd, Spark: TVector3;
  Frame: Integer;
begin
  Result := False;
  WeldCooldown := Max(0, WeldCooldown - SecondsPassed);
  if WeldTarget = nil then
    Exit;
  if Alerted or not IsAlive or (HealTarget <> nil) then
  begin
    WeldTarget := nil;
    FWeldPhase := 0;
    Exit;
  end;
  Result := True;
  Target := QuakeToCge(WeldTarget.Origin);
  Delta := Target - Transform.Translation;
  case FWeldPhase of
    0:
      begin
        { fixbot_move_forward: use_scanner welds within 56 units; stuck
          for 15 s: given up }
        FWeldApproach := FWeldApproach + SecondsPassed;
        if FWeldApproach > 15 then
        begin
          WeldTarget := nil;
          WeldCooldown := 15;
          Exit(False);
        end;
        if Delta.Length > 56 then
        begin
          FaceTowards(Vector3(Delta.X, 0, Delta.Z), SecondsPassed);
          Steer(Delta.Normalize, SecondsPassed);
          Exit;
        end;
        FWeldPhase := 1;
        FWeldClock := 0;
        SetWalking(False);
        if Model <> nil then
          Model.PlayAnim('weldstart', False, 10);
        WritelnLog('QuakeEntities', '%s welds %s', [Transform.Name, WeldTarget.ClassName]);
      end;
    1:
      begin
        { weldstart_01 .. 10, then the weld loop }
        FWeldClock := FWeldClock + SecondsPassed;
        if FWeldClock >= 1 then
        begin
          FWeldPhase := 2;
          FWeldClock := 0;
          FWeldFrame := -1;
          if Model <> nil then
            Model.PlayAnim('weldmiddle', True, 10);
        end;
      end;
    2:
      begin
        { weldmiddle_01 .. 07: fixbot_fire_welder on 01 .. 06 (welding
          sparks 24 ahead, 10 down; a welder sound 20 % of the time), 10 off
          the repair's health on 07 (weldstate) }
        FWeldClock := FWeldClock + SecondsPassed;
        Frame := Trunc(FWeldClock * 10);
        if (Frame <> FWeldFrame) and (Frame < 6) then
        begin
          FWeldFrame := Frame;
          Fwd := YawToCgeDir(FacingAngle);
          Spark := Transform.Translation + Fwd * 24 + Vector3(0, -10, 0);
          Particles.SpawnImpact(Spark, Vector3(0, 1, 0));
          if Random < 0.2 then
            Sounds.PlayAt('sound/misc/welder' + IntToStr(1 + Random(3)) + '.wav', Transform, 1, 2, chWeapon);
        end;
        if FWeldClock >= 0.7 then
        begin
          FWeldClock := FWeldClock - 0.7;
          FWeldFrame := -1;
          if Assigned(MonsterWeldCycle) and MonsterWeldCycle(WeldTarget) then
          begin
            FWeldPhase := 3;
            FWeldClock := 0;
            if Model <> nil then
              Model.PlayAnim('weldend', False, 10);
          end;
        end;
      end;
    3:
      begin
        { weldend_01 .. 07, backing off 2 a frame; then it looks again in
          15 s }
        FWeldClock := FWeldClock + SecondsPassed;
        if FWeldClock >= 0.7 then
        begin
          WritelnLog('QuakeEntities', '%s finished welding', [Transform.Name]);
          WeldTarget := nil;
          WeldCooldown := 15;
          FWeldPhase := 0;
          SetState(msIdle);
          Exit(False);
        end;
      end;
  end;
end;

function TQuakeMonster.IsTurretMonster: Boolean;
begin
  Result := Def^.ClassName = 'monster_turret';
end;

procedure TQuakeMonster.ActivateWallTurret;
begin
  { turret_activate: 32 units out of the wall at "speed", then turret_wake }
  if not TurretWallWaiting then
    Exit;
  TurretWallWaiting := False;
  TurretOut := 32;
  Sounds.PlayAt('sound/world/dr_short.wav', Transform, 1, 1, chVoice);
  WritelnLog('QuakeEntities', '%s comes out of the wall', [Transform.Name]);
end;

procedure TQuakeMonster.DropFromCeiling;
begin
  if not OnCeiling then
    Exit;
  { Alive, only onto a floor (a dying one just falls) }
  if IsAlive and not CeilingTransitionOk(False) then
    Exit;
  FCeilingJump := False;
  SetCeiling(False);
  if IsAlive then
  begin
    FJumping := True;
    FJumpVel := TVector3.Zero;
  end;
  WritelnLog('QuakeEntities', '%s drops from the ceiling', [Transform.Name]);
end;

function TQuakeMonster.CeilingTransitionOk(const ToCeiling: Boolean): Boolean;
var
  T, C: TQuakeTrace;
  Corner: TVector3;
  I: Integer;
begin
  if not Assigned(EntityTrace) then
    Exit(not ToCeiling);
  if not ToCeiling then
  begin
    T := MTrace(Origin, Origin - Vector3(0, 0, 384), BoxMins, BoxMaxs);
    Exit((T.Fraction < 1) and (T.Normal.Z >= 0.9));
  end;
  T := MTrace(Origin, Origin + Vector3(0, 0, 256), BoxMins, BoxMaxs);
  if T.StartSolid or (T.Fraction >= 1) or (T.Normal.Z > -0.9) or (T.Ent <> nil) then
    Exit(False);
  { Flat enough: each corner of the top (2 inside, off the brush edges the
    box touched) meets the ceiling within 8 }
  for I := 0 to 3 do
  begin
    Corner := T.EndPos + Vector3(0, 0, BoxMaxs.Z - 1);
    if (I and 1) <> 0 then
      Corner.X := Corner.X + BoxMaxs.X - 2
    else
      Corner.X := Corner.X + BoxMins.X + 2;
    if (I and 2) <> 0 then
      Corner.Y := Corner.Y + BoxMaxs.Y - 2
    else
      Corner.Y := Corner.Y + BoxMins.Y + 2;
    C := MTrace(Corner, Corner + Vector3(0, 0, 9), TVector3.Zero, TVector3.Zero);
    if C.Fraction >= 1 then
      Exit(False);
  end;
  Result := True;
end;

procedure TQuakeMonster.SetCeiling(const Up: Boolean);
var
  OldMinsZ, SwapZ: Single;
begin
  if OnCeiling = Up then
    Exit;
  OldMinsZ := BoxMins.Z;
  OnCeiling := Up;
  SwapZ := BoxMins.Z;
  BoxMins.Z := -BoxMaxs.Z;
  BoxMaxs.Z := -SwapZ;
  { Our box isn't centred on the origin: move the origin so the box stays }
  Transform.Translation := Transform.Translation + Vector3(0, OldMinsZ - BoxMins.Z, 0);
  FCeilingStuck := True;
  if Model <> nil then
  begin
    if Up then
    begin
      Model.Scene.Rotation := Vector4(1, 0, 0, Pi);
      Model.Scene.Translation := Vector3(0, -MonsterModelOffset(Def^.ClassName), 0);
    end else
    begin
      Model.Scene.Rotation := Vector4(0, 1, 0, 0);
      Model.Scene.Translation := Vector3(0, MonsterModelOffset(Def^.ClassName), 0);
    end;
  end;
end;

procedure TQuakeMonster.JumpStraightUp;
begin
  if not IsAlive then
    Exit;
  if OnCeiling then
  begin
    DropFromCeiling;
    Exit;
  end;
  if not OnGroundTrace then
    Exit;
  State := msChase;
  SetWalking(False);
  if Model <> nil then
    Model.PlayAnim('jump', False, 10);
  if CeilingTransitionOk(True) then
  begin
    { 400 up, gravity pulling it up from now on }
    SetCeiling(True);
    FCeilingJump := True;
    FCeilingVel := 400;
    FCeilingJumpTime := 0;
    WritelnLog('QuakeEntities', '%s jumps up to the ceiling', [Transform.Name]);
  end else
  begin
    { No ceiling to cling to: a hop }
    FJumping := True;
    FJumpVel := Vector3(Random * 10 - 5, 400, Random * 10 - 5);
    WritelnLog('QuakeEntities', '%s jumps (no ceiling to cling to)', [Transform.Name]);
  end;
end;

procedure TQuakeMonster.UpdateCeilingJump(const SecondsPassed: Single);
var
  T: TQuakeTrace;
begin
  FCeilingJumpTime := FCeilingJumpTime + SecondsPassed;
  FCeilingVel := FCeilingVel + 800 * SecondsPassed;
  T := MTrace(Origin, Origin + Vector3(0, 0, FCeilingVel * SecondsPassed), BoxMins, BoxMaxs);
  if not T.AllSolid then
    SetOrigin(T.EndPos);
  if T.Fraction < 1 then
  begin
    FCeilingJump := False;
    WritelnLog('QuakeEntities', '%s climbs back to the ceiling at %s', [Transform.Name, Origin.ToString]);
  end else
  if FCeilingJumpTime > 2 then
  begin
    { Never got there: fall back down }
    FCeilingJump := False;
    SetCeiling(False);
    FJumping := True;
    FJumpVel := TVector3.Zero;
  end;
end;

function TQuakeMonster.FalseDeath: Boolean;
begin
  Result := FFalseDeath > 0;
end;

function TQuakeMonster.StalkerPain(const Dmg: Integer): Boolean;
begin
  Result := True;
  { Falling down or getting up: no pain; hurt while playing dead: up }
  if FFalseDeath in [1, 3] then
    Exit;
  if FFalseDeath = 2 then
  begin
    StalkerReactivate;
    Exit;
  end;
  { Below a quarter of its health, 30 % of the time: plays dead (from the
    ceiling only when there's a floor to fall to) }
  if (Health < MaxHealth div 4) and (Random < 0.3) and (not FCeilingJump) and
     ((not OnCeiling) or CeilingTransitionOk(False)) then
  begin
    StartFalseDeath;
    Exit;
  end;
  if FPainDebounce > 0 then
    Exit;
  FPainDebounce := 3;
  { Only hits over 10 count; no pain animation on nightmare }
  if (Dmg <= 10) or (GameSkill >= 3) then
    Exit;
  Sounds.PlayAt(MonsterSound(Def, Def^.PainSound), Transform, 1, 1, chWeapon);
  { Half the time a dodge jump (up to the ceiling, or down from it) }
  if (OnCeiling or OnGroundTrace) and (Random < 0.5) and not (FJumping or FCeilingJump) then
    JumpStraightUp
  else
  if not OnCeiling then
    SetState(msPain);
end;

procedure TQuakeMonster.StartFalseDeath;
begin
  FCeilingJump := False;
  if OnCeiling then
  begin
    SetCeiling(False);
    FJumping := True;
    FJumpVel := TVector3.Zero;
  end;
  FFalseDeath := 1;
  FFalseDeathTime := 0;
  SetWalking(False);
  State := msPain;
  if Def^.DeathSound <> '' then
    Sounds.PlayAt(MonsterSound(Def, Def^.DeathSound), Transform, 1, 1, chVoice);
  if Model <> nil then
    Model.PlayAnim('death', False, 10);
  WritelnLog('QuakeEntities', '%s plays dead (health %d)', [Transform.Name, Health]);
end;

procedure TQuakeMonster.StalkerReactivate;
begin
  FFalseDeath := 3;
  FFalseDeathTime := 0;
  if Model <> nil then
    Model.PlayAnim('reactive', False, 10);
  WritelnLog('QuakeEntities', '%s gets up (health %d)', [Transform.Name, Health]);
end;

procedure TQuakeMonster.UpdateFalseDeath(const SecondsPassed: Single);
begin
  FFalseDeathTime := FFalseDeathTime + SecondsPassed;
  StickToFloor(SecondsPassed);
  case FFalseDeath of
    1:
      { death01..09, then lying there twitching }
      if (Model = nil) or Model.AnimDone or (FFalseDeathTime > 1) then
      begin
        FFalseDeath := 2;
        FFalseDeathTime := 0;
        FHealTimer := 0;
        if Model <> nil then
          Model.PlayAnim('twitch', True, 10);
      end;
    2:
      begin
        { stalker_heal every frame: 1 health, 2 on hard, 3 on nightmare;
          up again at full health }
        FHealTimer := FHealTimer + SecondsPassed;
        while FHealTimer >= 0.1 do
        begin
          FHealTimer := FHealTimer - 0.1;
          Health := Health + Max(1, GameSkill);
          if Health >= MaxHealth then
          begin
            Health := MaxHealth;
            StalkerReactivate;
            Break;
          end;
        end;
      end;
    else
      if (Model = nil) or Model.AnimDone or (FFalseDeathTime > 0.5) then
      begin
        FFalseDeath := 0;
        SetState(msChase);
      end;
  end;
end;

procedure TQuakeMonster.TurretBlindFire(const PlayerPos, Aim: TVector3);
var
  T: TQuakeTrace;
  Dir, Target: TVector3;
begin
  { Blaster and rocket turrets that lost the player shoot where he was
    last seen: at once, then after a delay growing by 5.2 .. 8.2 s a shot,
    until it passes 10 s; nothing but the target in the way (the machinegun
    turret only aims there) }
  if (not FHasBlind) or (TurretWeapon = 1) or (FBlindDelay > 10) or (FBlindLost < FBlindDelay) then
    Exit;
  T := MTrace(Origin, CgeToQuake(FBlindTarget), TVector3.Zero, TVector3.Zero, CONTENTS_MONSTER);
  if T.StartSolid or T.AllSolid or (T.Fraction < 1) then
    Exit;
  FTurretCooldown := 0.5 + 2 * Random;
  FBlindDelay := FBlindDelay + 5.2 + 3 * Random;
  Dir := Vector3(Cos(DegToRad(TurretAimPitch)) * Cos(DegToRad(TurretAimYaw)),
    Cos(DegToRad(TurretAimPitch)) * Sin(DegToRad(TurretAimYaw)), -Sin(DegToRad(TurretAimPitch)));
  if (Aim.Length < 1) or (TVector3.DotProduct(Dir, Aim.Normalize) < 0.98) then
    Exit;
  { Above the spot if the player is lower now, else below it }
  Target := FBlindTarget;
  if PlayerPos.Y - 22 < FBlindTarget.Y then
    Target.Y := Target.Y + 22 + 10
  else
    Target.Y := Target.Y - 24 - 10;
  if Model <> nil then
    Model.PlayAnim('pow', False, 10);
  if TurretWeapon = 2 then
  begin
    AttackKind := akRocket;
    AttackDamage := 50;
  end else
  begin
    AttackKind := akBlaster;
    AttackDamage := 20;
    AttackSpeed := 1000;
  end;
  AttackBullets := 1;
  AttackYaw := 0;
  AttackKick := 0;
  AttackReach := 2000;
  BlindFire := True;
  BlindAim := Target;
  WritelnLog('QuakeEntities', '%s blind fires at %s', [Transform.Name, CgeToQuake(Target).ToString]);
  if Assigned(OnAttack) then
    OnAttack(Self);
  BlindFire := False;
end;

procedure TQuakeMonster.UpdateTurret(const SecondsPassed: Single; const PlayerPos: TVector3);
const
  { turret_checkattack: blaster, machinegun, rocket }
  Chances: array[0..2] of Single = (0.35, 0.5, 0.1);
var
  Aim, Dir: TVector3;
  WantPitch, WantYaw, Step, Diff, Chance, Dist: Single;
begin
  { A WallUnit coming out of the wall (Move_Calc at "speed"), with its base }
  if TurretOut > 0 then
  begin
    Step := Min(TurretOut, FTurretOutSpeed * SecondsPassed);
    TurretOut := TurretOut - Step;
    if TurretFacing = -1 then
      Dir := Vector3(0, 1, 0)
    else
    if TurretFacing = -2 then
      Dir := Vector3(0, -1, 0)
    else
      Dir := YawToCgeDir(TurretFacing);
    Transform.Translation := Transform.Translation + Dir * Step;
    if FTurretBase <> nil then
      FTurretBase.Translation := FTurretBase.Translation + Dir * Step;
    Exit;
  end;
  if TurretWallWaiting or not IsAlive then
    Exit;
  Dist := PointsDistance(PlayerPos, Transform.Translation);
  FSightTimer := FSightTimer - SecondsPassed;
  if FSightTimer <= 0 then
  begin
    FSightTimer := 0.2;
    CanSeePlayer := (Dist < 2000) and SightClear(Transform.Translation, PlayerPos);
    if (not Alerted) and CanSeePlayer and (Dist < 1000) and (not NoTarget) and (not PlayerDisguised) then
      Alert;
    { The blind fire target: the player's origin when last seen }
    if CanSeePlayer and Alerted then
    begin
      FBlindTarget := PlayerPos - Vector3(0, 22, 0);
      FHasBlind := True;
      FBlindLost := 0;
      FBlindDelay := 0;
    end;
  end;
  if not CanSeePlayer then
    FBlindLost := FBlindLost + SecondsPassed;
  if not Alerted then
    Exit;
  { turret_move_ready_gun (active01 .. run01) the first time }
  if FTurretReady = 0 then
  begin
    FTurretReady := 0.7;
    if Model <> nil then
      Model.PlayAnim('active', False, 10);
  end;
  if FTurretReady > 0.01 then
  begin
    FTurretReady := Max(0.01, FTurretReady - SecondsPassed);
    if FTurretReady > 0.01 then
      Exit;
  end;
  { TurretAim: at the player (where he was last seen once lost), limited
    by the mounting, 45 degrees a frame }
  if CanSeePlayer or not FHasBlind then
    Aim := CgeToQuake(PlayerPos) - Origin
  else
    Aim := CgeToQuake(FBlindTarget) - Origin;
  WantYaw := RadToDeg(ArcTan2(Aim.Y, Aim.X));
  WantPitch := -RadToDeg(ArcTan2(Aim.Z, Sqrt(Sqr(Aim.X) + Sqr(Aim.Y))));
  if TurretFacing = -1 then
    WantPitch := Min(WantPitch, -5)
  else
  if TurretFacing = -2 then
    WantPitch := Max(WantPitch, 5)
  else
  begin
    WantPitch := EnsureRange(WantPitch, -85, 85);
    Diff := FloatModulo(WantYaw - TurretFacing + 540, 360) - 180;
    WantYaw := TurretFacing + EnsureRange(Diff, -85, 85);
  end;
  if TurretAimPitch > 180 then
    TurretAimPitch := TurretAimPitch - 360;
  Step := 450 * SecondsPassed;
  TurretAimPitch := TurretAimPitch + EnsureRange(WantPitch - TurretAimPitch, -Step, Step);
  Diff := FloatModulo(WantYaw - TurretAimYaw + 540, 360) - 180;
  TurretAimYaw := TurretAimYaw + EnsureRange(Diff, -Step, Step);
  FacingAngle := TurretAimYaw;
  Transform.Rotation := TurretRotation(TurretAimPitch, TurretAimYaw);
  { turret_checkattack, a frame at a time: the weapon's chance (half on
    easy, double on hard), then its cooldown }
  FTurretCooldown := FTurretCooldown - SecondsPassed;
  FTurretThink := FTurretThink - SecondsPassed;
  if (FTurretThink > 0) or (FTurretCooldown > 0) then
    Exit;
  FTurretThink := 0.1;
  if not CanSeePlayer then
  begin
    TurretBlindFire(PlayerPos, Aim);
    Exit;
  end;
  Chance := Chances[TurretWeapon];
  if GameSkill = 0 then
    Chance := Chance * 0.5
  else
  if GameSkill >= 2 then
    Chance := Chance * 2;
  if Random >= Chance then
    Exit;
  case TurretWeapon of
    1: FTurretCooldown := 0.8 - 0.1 * GameSkill;
    2: FTurretCooldown := 1.8 - 0.2 * GameSkill;
    else FTurretCooldown := 1.2 - 0.2 * GameSkill;
  end;
  if Model <> nil then
    Model.PlayAnim('pow', False, 10);
  { TurretFire: only within about 11 degrees of where it points; no
    rockets closer than 72 }
  Dir := Vector3(Cos(DegToRad(TurretAimPitch)) * Cos(DegToRad(TurretAimYaw)),
    Cos(DegToRad(TurretAimPitch)) * Sin(DegToRad(TurretAimYaw)), -Sin(DegToRad(TurretAimPitch)));
  if (Aim.Length < 1) or (TVector3.DotProduct(Dir, Aim.Normalize) < 0.98) then
    Exit;
  if (TurretWeapon = 2) and (Dist <= 72) then
    Exit;
  case TurretWeapon of
    1:
      begin
        AttackKind := akHitscan;
        AttackDamage := 4;
        AttackBullets := 1;
      end;
    2:
      begin
        AttackKind := akRocket;
        AttackDamage := 50;
        AttackBullets := 1;
      end;
    else
      begin
        AttackKind := akBlaster;
        AttackDamage := 20;
        case GameSkill of
          0: AttackSpeed := 600;
          1: AttackSpeed := 800;
          else AttackSpeed := 1000;
        end;
      end;
  end;
  AttackYaw := 0;
  AttackKick := 0;
  AttackReach := 2000;
  if Assigned(OnAttack) then
    OnAttack(Self);
end;

function TQuakeMonster.UpdateRoam(const SecondsPassed: Single): Boolean;
const
  { fixbot_move_forward: M_MoveToGoal 5 a frame }
  RoamSpeed = 50;
  { Our choice: the landing and take-off frames don't move the fixbot in
    Quake 2 (ai_move 0 / 0.01); here it goes down to its goal at the flying
    speed and up its 128 units over the 16 take-off frames }
  TakeoffSpeed = 128 / 1.6;
var
  I, Frame: Integer;
  Yaw, Best, Dist, Spread: Single;
  Dir, Delta, Flat, Down: TVector3;
  T: TQuakeTrace;

  procedure ShowAnim(const Name: String; const Loop: Boolean);
  begin
    if Model <> nil then
      Model.PlayAnim(Name, Loop, 10);
    { Not the stand frames: SetWalking(False) shows them again }
    FWalking := True;
  end;

  procedure Stand;
  begin
    FRoamPhase := 0;
    FRoamClock := 0;
    SetWalking(False);
  end;

  { Seconds without moving give up (FIXBOT_MAX_STUCK_FRAMES) }
  procedure CheckStuck;
  begin
    if PointsDistance(Origin, FRoamOld) < 0.01 then
      FRoamStuck := FRoamStuck + SecondsPassed
    else
      FRoamStuck := 0;
    FRoamOld := Origin;
  end;

begin
  Result := False;
  if (FRoamFlags = 0) or Dormant or not Assigned(EntityTrace) then
    Exit;
  Result := True;
  FRoamClock := FRoamClock + SecondsPassed;
  case FRoamPhase of
    0:
      begin
        { fixbot_move_stand: ambient_01 .. 19, then change_to_roam }
        SetWalking(False);
        if FRoamClock < 1.9 then
          Exit;
        FRoamClock := 0;
        FRoamStuck := 0;
        FRoamFrame := -1;
        FRoamOld := Origin;
        if (FRoamFlags and 16) <> 0 then
        begin
          { landing_goal: its box traced 8096 down }
          T := MTrace(Origin, Origin - Vector3(0, 0, 8096), BoxMins, BoxMaxs);
          FRoamGoal := T.EndPos;
          FRoamPhase := 2;
          ShowAnim('landing', True);
          WritelnLog('QuakeEntities', '%s lands at %s', [Transform.Name, FRoamGoal.ToString]);
        end else
        if (FRoamFlags and 8) <> 0 then
        begin
          { takeoff_goal: its box traced 128 up }
          T := MTrace(Origin, Origin + Vector3(0, 0, 128), BoxMins, BoxMaxs);
          FRoamGoal := T.EndPos;
          FRoamPhase := 3;
          ShowAnim('takeoff', False);
          WritelnLog('QuakeEntities', '%s takes off to %s', [Transform.Name, FRoamGoal.ToString]);
        end else
        begin
          { roam_goal: 12 shot traces of 8192 from +150 to -150 degrees
            around its yaw, the farthest end is the goal }
          Best := -1;
          for I := 0 to 11 do
          begin
            if I < 6 then
              Yaw := FacingAngle + 30 * I
            else
              Yaw := FacingAngle - 30 * (I - 6);
            Dir := Vector3(Cos(DegToRad(Yaw)), Sin(DegToRad(Yaw)), 0);
            T := MTrace(Origin, Origin + Dir * 8192, TVector3.Zero, TVector3.Zero, MASK_SHOT);
            Dist := PointsDistance(T.EndPos, Origin);
            if Dist > Best then
            begin
              Best := Dist;
              FRoamGoal := T.EndPos;
            end;
          end;
          FRoamPhase := 1;
          WritelnLog('QuakeEntities', '%s roams to %s', [Transform.Name, FRoamGoal.ToString]);
        end;
        { The spawnflags are read once (change_to_roam sets them to 32);
          afterwards it roams }
        FRoamFlags := 4;
      end;
    1:
      begin
        { fixbot_move_turn until the goal is in front, then forward;
          use_scanner gives up after 15 s, within 32 or stuck }
        Delta := QuakeToCge(FRoamGoal) - Transform.Translation;
        if (FRoamClock > 15) or (Delta.Length < 32) or (FRoamStuck > 1) then
        begin
          Stand;
          Exit;
        end;
        Flat := Vector3(Delta.X, 0, Delta.Z);
        FaceTowards(Flat, SecondsPassed);
        if Flat.IsZero or (TVector3.DotProduct(YawToCgeDir(FacingAngle), Flat.Normalize) > 0.3) then
        begin
          ShowAnim(AnimNames('walk,run'), True);
          { M_MoveToGoal: with detours when blocked }
          Steer(Delta.Normalize, SecondsPassed, RoamSpeed / Max(1, Def^.Speed));
          CheckStuck;
        end else
          FRoamOld := Origin;
      end;
    2:
      begin
        { landing_01 .. 58 (fly_vertical2): down to the goal, done within 32 }
        Dist := PointsDistance(Origin, FRoamGoal);
        if (Dist < 32) or (FRoamStuck > 1) then
        begin
          WritelnLog('QuakeEntities', '%s landed at %s', [Transform.Name, Origin.ToString]);
          Stand;
          Exit;
        end;
        StepMove((FRoamGoal - Origin).Normalize * Min(RoamSpeed * SecondsPassed, Dist));
        CheckStuck;
      end;
    3:
      begin
        { takeoff_01 .. 16 (fly_vertical): each frame blastoff puffs 10
          shotgun pellets downwards, spreading wider frame by frame (no
          damage here) }
        Frame := Trunc(FRoamClock * 10);
        if (Frame <> FRoamFrame) and (Frame < 16) then
        begin
          FRoamFrame := Frame;
          Spread := 0.05 * (Frame + 1);
          for I := 1 to 10 do
          begin
            Down := Vector3((Random * 2 - 1) * Spread, (Random * 2 - 1) * Spread, -1).Normalize;
            T := MTrace(Origin, Origin + Down * 8192, TVector3.Zero, TVector3.Zero, MASK_SHOT);
            if T.Fraction < 1 then
              Particles.SpawnImpact(QuakeToCge(T.EndPos), Vector3(T.Normal.X, T.Normal.Z, -T.Normal.Y));
          end;
        end;
        Dist := PointsDistance(Origin, FRoamGoal);
        if Dist > 0.01 then
          StepMove((FRoamGoal - Origin).Normalize * Min(TakeoffSpeed * SecondsPassed, Dist));
        if FRoamClock >= 1.6 then
        begin
          WritelnLog('QuakeEntities', '%s took off at %s', [Transform.Name, Origin.ToString]);
          Stand;
        end;
      end;
  end;
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
  if IsFixbot then
    { It flies to a little above the corpse }
    Delta.Y := Delta.Y + 40
  else
    Delta.Y := 0;
  Dist := Delta.Length;
  FaceTowards(Vector3(Delta.X, 0, Delta.Z), SecondsPassed);
  { medic_cable_attack reaches MEDIC_MAX_HEAL_DISTANCE (400); get well inside
    it, in sight of the corpse; the fixbot's laser within 128 }
  if (Dist > IfThen(IsFixbot, 120, 250)) or not SightClear(EyePos, CorpsePos + Vector3(0, 8, 0)) then
  begin
    HealTime := 0;
    if Dist > 1 then
      Steer(Delta.Normalize, SecondsPassed);
    StickToFloor(SecondsPassed);
    Exit;
  end;
  SetWalking(False);
  if IsFixbot then
  begin
    { fixbot_fire_laser on shoot_01 .. 06: a beam to the corpse each frame
      (dmg -1: a point of health each); it gets up past a tenth of its
      mass (fixbot_fire_laser's revive) }
    if (HealTime = 0) and (Model <> nil) then
      Model.PlayAnim('shoot', True, 10);
    if Trunc((HealTime + SecondsPassed) * 10) <> Trunc(HealTime * 10) then
      Particles.SpawnBeam(Transform.Translation, CorpsePos + Vector3(0, 8, 0), Vector3(1, 0.5, 0.1));
    HealTime := HealTime + SecondsPassed;
    if HealTime < Max(1, (MonsterMass(HealTarget.Def^.ClassName) / 10 - HealTarget.Health + 1) / 10) then
      Exit;
    HealTarget.Revive;
    if Assigned(OnRevived) then
      OnRevived(HealTarget);
    HealTarget := nil;
    HealTime := 0;
    SetState(msIdle);
    Exit;
  end;
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
  if Dormant or TurretWallWaiting or (TurretOut > 0) then
    Exit;
  { Hurt: back to the player (M_ReactToDamage) }
  AngerActive := False;
  if not IsAlive then
  begin
    { Shooting corpses gibs them }
    Health := Health - Dmg;
    if (Health <= GibHealth) and not Gibbed then
      Gib(Dmg);
    Exit;
  end;

  Health := Health - (Dmg - AbsorbPowerArmor(Dmg));
  if GoodGuy then
  begin
    { insane_pain / insane_die: the player's voice; a flinch at most every
      3 seconds (crucified ones struggle) }
    if Health <= 0 then
    begin
      if Model <> nil then
        Model.Scene.Collides := False;
      if Health <= GibHealth then
      begin
        Gib(Dmg);
        State := msDead;
      end else
      begin
        Sounds.PlayAt(InsaneDeathSound(1 + Random(4)), Transform, 1, ATTN_IDLE, chVoice);
        SetState(msDying);
      end;
    end else
    if FPainDebounce <= 0 then
    begin
      FPainDebounce := 3;
      Sounds.PlayAt(InsanePainSound(Health, 1 + Random(2)), Transform, 1, ATTN_IDLE, chVoice);
      SetState(msPain);
    end;
    Exit;
  end;
  if Health <= 0 then
  begin
    if Def^.DeathSound <> '' then
      Sounds.PlayAt(MonsterSound(Def, Def^.DeathSound), Transform, 1, 1, chVoice);
    if Model <> nil then
      Model.Scene.Collides := False;
    { stalker_die: gravity down again, it falls }
    FFalseDeath := 0;
    FCeilingJump := False;
    if OnCeiling then
      DropFromCeiling;
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
  { SP_turret_driver has no pain function, turret_pain does nothing }
  if TurretDriver or IsTurretMonster then
    Exit;
  if (Def^.ClassName = 'monster_stalker') and StalkerPain(Dmg) then
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
  if Flies or OnCeiling then
    Exit;
  { A crucified misc_insane hangs where it is }
  if GoodGuy and ((Entity.SpawnFlags and INSANE_CRUCIFIED) <> 0) then
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
  CeilTrace: TQuakeTrace;
  CeilDown: Integer;
begin
  FLastPlayerPos := PlayerPos;
  if Dormant then
    Exit;
  FPainDebounce := FPainDebounce - SecondsPassed;
  if Model <> nil then
  begin
    Model.Update(SecondsPassed);
    FLightTimer := FLightTimer - SecondsPassed;
    if FLightTimer <= 0 then
    begin
      { 10 times a second, like Quake 2 relights entities every frame }
      FLightTimer := 0.1;
      if IRGogglesOn and IsAlive then
        { RDF_IRGOGGLES: RF_IR_VISIBLE entities full bright red }
        Model.SetTint(Vector3(2.0, 0.25, 0.25))
      else
        Model.SetTint(Lighting.SampleLight(Transform.Translation));
    end;
    { M_SetEffects while the power armor is absorbing: a power screen shows
      EF_POWERSCREEN (the screen model, translucent with a green shell, in
      front of the monster), a power shield a green shell }
    if FPowerArmorFlash > 0 then
    begin
      FPowerArmorFlash := FPowerArmorFlash - SecondsPassed;
      if PowerArmorType = paScreen then
      begin
        if FScreenModel = nil then
        begin
          FScreenModel := Md2Manager.CreateInstance('models/items/armor/effect/tris.md2');
          if FScreenModel <> nil then
          begin
            FScreenModel.Scene.Collides := False;
            FScreenModel.Scene.Pickable := False;
            FScreenModel.SetTransparency(0.7);
            FScreenModel.SetShell(Vector3(0, 1, 0));
            Transform.Add(FScreenModel.Scene);
          end;
        end;
        if FScreenModel <> nil then
          FScreenModel.Scene.Exists := True;
      end else
        Model.SetShell(Vector3(0, 1, 0));
    end else
    begin
      Model.SetShell(TVector3.Zero);
      if FScreenModel <> nil then
        FScreenModel.Scene.Exists := False;
    end;
  end;

  if TurretDriver then
  begin
    UpdateDriverSight(PlayerPos);
    Exit;
  end;

  if (not FDropped) and Assigned(EntityTrace) and IsAlive then
    DropToFloor;
  { The stalker on the ceiling: up against it }
  if OnCeiling and (not FCeilingStuck) and Assigned(EntityTrace) and IsAlive then
  begin
    FCeilingStuck := True;
    { Our box reaches 6 higher above the origin than Quake's (-18 .. 18):
      down until free, then up against the ceiling }
    CeilDown := 0;
    while (CeilDown < 16) and MTrace(Origin - Vector3(0, 0, CeilDown), Origin - Vector3(0, 0, CeilDown),
      BoxMins, BoxMaxs).StartSolid do
      Inc(CeilDown);
    CeilTrace := MTrace(Origin - Vector3(0, 0, CeilDown), Origin + Vector3(0, 0, 256), BoxMins, BoxMaxs);
    if not CeilTrace.StartSolid then
      SetOrigin(CeilTrace.EndPos);
  end;

  UpdateSwimming(SecondsPassed, PlayerPos);

  if FJumping and IsAlive then
  begin
    UpdateJump(SecondsPassed);
    Exit;
  end;
  if FCeilingJump and IsAlive then
  begin
    UpdateCeilingJump(SecondsPassed);
    Exit;
  end;
  if (FFalseDeath > 0) and IsAlive then
  begin
    UpdateFalseDeath(SecondsPassed);
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
        if GoodGuy then
        begin
          StickToFloor(SecondsPassed);
          if (Model = nil) or Model.AnimDone or (StateTimer > 1.5) then
            SetState(msIdle);
          Exit;
        end;
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

  if GoodGuy then
  begin
    UpdateInsane(SecondsPassed);
    Exit;
  end;
  if IsTurretMonster then
  begin
    UpdateTurret(SecondsPassed, PlayerPos);
    Exit;
  end;

  { A medic on its way to a corpse (AI_MEDIC) does only that; a fixbot
    going to weld, or welding, too }
  if UpdateMedic(SecondsPassed) or UpdateWeld(SecondsPassed) then
  begin
    FRoamPhase := 0;
    FRoamClock := 0;
    Exit;
  end;

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
      FHintTried := False;
      FOnHint := False;
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
    if not (IsFixbot and UpdateRoam(SecondsPassed)) then
      SetWalking(False);
    StickToFloor(SecondsPassed);
    Exit;
  end;
  FWalking := False;
  FRoamPhase := 0;
  FRoamClock := 0;

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
      { MakronSaveloc: remember where the target is for the coming shot }
      if (FAttack.Seq.AimFrame > 0) and not AimSaved and (FAttack.Frame >= FAttack.Seq.AimFrame - 1) then
      begin
        AimSaved := True;
        SavedAim := PlayerPos;
      end;
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
    if (not CanSeePlayer) and PursuitGoal(PlayerPos, Goal) then
      MoveVec := Goal - Transform.Translation;
    if Swimming then
      { The gekk swims at the player's middle }
      MoveVec.Y := (PlayerPos.Y - 20) - Transform.Translation.Y
    else
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

procedure TQuakeMonster.UpdateInsane(const SecondsPassed: Single);
var
  Cross: Boolean;
begin
  Cross := (Entity.SpawnFlags and INSANE_CRUCIFIED) <> 0;
  { Screams and moans (ATTN_IDLE) }
  FIdleTimer := FIdleTimer - SecondsPassed;
  if FIdleTimer <= 0 then
  begin
    FIdleTimer := 3 + Random * 7;
    Sounds.PlayAt(InsaneIdleSound(Random), Transform, 1, ATTN_IDLE, chVoice);
  end;

  { A fidget (insane_move_stand_insane) or, on the cross, a struggle with
    its shake sound, now and then; back to the loop when it's done }
  if FInsaneFidget then
  begin
    if (Model = nil) or Model.AnimDone then
    begin
      FInsaneFidget := False;
      SetState(msIdle);
    end;
    StickToFloor(SecondsPassed);
    Exit;
  end;
  FInsaneTimer := FInsaneTimer - SecondsPassed;
  if (FInsaneTimer <= 0) and (not FWalking) and (Model <> nil) and
     ((Entity.SpawnFlags and INSANE_CRAWL) = 0) then
  begin
    FInsaneTimer := 6 + Random * 12;
    FInsaneFidget := True;
    if Cross then
    begin
      Model.PlayAnim(InsaneStruggle, False, 10);
      Sounds.PlayAt(InsaneShake, Transform, 1, ATTN_IDLE, chBody);
    end else
      Model.PlayAnim(InsaneFidget, False, 10);
    Exit;
  end;

  { Walk the path_corners, unless crucified or told to stand }
  if (MoveTarget <> nil) and not Cross and
     ((Entity.SpawnFlags and (INSANE_STAND_GROUND or INSANE_ALWAYS_STAND)) = 0) then
    Patrol(SecondsPassed)
  else
    SetWalking(False);
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

{ A Call of the Void variant whose definition gives another weapon than its
  Quake 1 archetype's: its ranged sequences use that kind and damage, or
  are dropped for a melee-only one }
procedure AdaptVariantAttacks(var Seqs: TMonsterAttackSeqs; const Def: PQuakeMonsterDef);
var
  I: Integer;
  Kept: TMonsterAttackSeqs;
begin
  if Q1Archetype(Def^.ClassName) = qaNone then
    Exit;
  Kept := nil;
  for I := 0 to High(Seqs) do
  begin
    if (Seqs[I].Kind in [akMelee, akLeap]) or (Seqs[I].Kind = Def^.Attack) then
    begin
      AddSeq(Kept, Seqs[I]);
      Continue;
    end;
    if Def^.Attack in [akMelee, akLeap] then
      Continue;
    Seqs[I].Kind := Def^.Attack;
    Seqs[I].Damage := Def^.Damage;
    Seqs[I].DamageRandom := 0;
    if Def^.Attack = akPellets then
      Seqs[I].Volley := 4;
    AddSeq(Kept, Seqs[I]);
  end;
  if Length(Kept) > 0 then
    Seqs := Kept;
end;

function TQuakeMonster.Q1AnimNames(const Names: String): String;
var
  Part, R: String;
begin
  { 'stand,idle,fidget' -> the archetype's stand range, keeping the names
    it has no range for as fallbacks }
  Result := '';
  for Part in Names.Split([',']) do
  begin
    R := Q1AnimRange(Q1Archetype(Def^.ClassName), Trim(Part));
    if R = '' then
      R := Trim(Part);
    if Result <> '' then
      Result := Result + ',';
    Result := Result + R;
  end;
end;

function TQuakeMonster.FrameOf(const AName: String): Integer;
begin
  { '#<index>' (QuakeQ1Monsters) or a frame name }
  if (AName <> '') and (AName[1] = '#') then
  begin
    Result := StrToIntDef(Copy(AName, 2, MaxInt), -1);
    if (Model = nil) or (Result >= Model.Model.FrameCount) then
      Result := -1;
  end else
  if Model <> nil then
    Result := Model.Model.FrameNames.IndexOf(AName)
  else
    Result := -1;
end;

function TQuakeMonster.AnimNames(const Names: String): String;
begin
  Result := Names;
  if GoodGuy then
  begin
    Result := InsaneAnim(Names, Entity.SpawnFlags, FInsaneWalk);
    Exit;
  end;
  { Call of the Void's Quake 1 monsters: frame ranges by index }
  if Q1Archetype(Def^.ClassName) <> qaNone then
  begin
    Result := Q1AnimNames(Names);
    Exit;
  end;
  { The gekk in water: amb_ to stand, pain_, wdeath_ }
  if Swimming then
  begin
    if (Pos('death', Result) > 0) or (Pos('die', Result) > 0) then
      Exit('wdeath_');
    if Pos('pain', Result) > 0 then
      Exit('pain_');
    if (Pos('stand', Result) > 0) or (Pos('idle', Result) > 0) then
      Exit('amb_');
  end;
  if Def^.ClassName = 'monster_makron' then
  begin
    Result := StringReplace(Result, 'stand', 'stand2', [rfReplaceAll]);
    Result := StringReplace(Result, 'walk', 'walk2', [rfReplaceAll]);
    Result := StringReplace(Result, 'run', 'walk2', [rfReplaceAll]);
    Result := StringReplace(Result, 'pain', 'pain4', [rfReplaceAll]);
    Result := StringReplace(Result, 'death', 'death2', [rfReplaceAll]);
  end;
end;

procedure TQuakeMonster.Leap;
begin
  if Def^.Flying or not IsAlive then
    Exit;
  if AttackLeapForward > 0 then
    FJumpVel := YawToCgeDir(FacingAngle) * AttackLeapForward
  else
    FJumpVel := YawToCgeDir(FacingAngle) * 600;
  if AttackLeapUp > 0 then
    FJumpVel.Y := AttackLeapUp
  else
    FJumpVel.Y := 250;
  FJumping := True;
  LeapDamage := AttackDamage;
end;

function TQuakeMonster.JumpSpeed: Single;
begin
  if FJumping then
    Result := FJumpVel.Length
  else
    Result := 0;
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
      First := FrameOf(FAttackSeqs[I].FirstFrame);
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
    First := FrameOf(Seq.FirstFrame);
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
  I, J, First: Integer;
begin
  Result := False;
  if (Model = nil) or (Length(FAttackSeqs) = 0) then
    Exit;
  I := ChooseAttackSeq(FAttackSeqs, Dist, Random);
  { The medic commander calls reinforcements only with more than 2 slots }
  if (I >= 0) and (FAttackSeqs[I].Kind = akSummon) and (MonsterSlots <= 2) then
  begin
    I := ChooseAttackSeq(FAttackSeqs, Dist, Random);
    if (I >= 0) and (FAttackSeqs[I].Kind = akSummon) then
      I := 0;
  end;
  if I < 0 then
    Exit;
  { On the ceiling only its blaster (stalker_do_pounce: not from there) }
  if OnCeiling and (FAttackSeqs[I].Kind <> akBlaster) then
    for J := 0 to High(FAttackSeqs) do
      if FAttackSeqs[J].Kind = akBlaster then
      begin
        I := J;
        Break;
      end;
  { stalker_shoot_attack: on the ceiling a third of the time it drops }
  if OnCeiling and (FAttackSeqs[I].Kind = akBlaster) and (Random < 0.33) then
    DropFromCeiling;
  First := FrameOf(FAttackSeqs[I].FirstFrame);
  if (First < 0) or (First + FAttackSeqs[I].Count > Model.Model.FrameCount) then
    Exit;
  FAttackFirst := First;
  { gladiator_attack saves the target's position when it starts }
  AimSaved := FAttackSeqs[I].AimFrame = 0;
  SavedAim := FLastPlayerPos;
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
  AttackBullets := Seq.Volley;
  AttackKick := Seq.Kick;
  { The gekk's bites push nothing, its claws do }
  if (Seq.ClawFrom > 0) and (ShotIndex < Seq.ClawFrom) then
    AttackKick := 0;
  AttackRadius := Seq.Radius;
  if Seq.Sweep then
    AttackYaw := SweepYaw(FAttack.Frame)
  else
    AttackYaw := 0;
  AttackSpeed := Seq.Speed;
  if Seq.YawStep <> 0 then
    AttackYaw := (FAttack.Frame - Seq.YawCenter) * Seq.YawStep;
  AttackLeapForward := Seq.LeapForward;
  AttackLeapUp := Seq.LeapUp;
  { monster_fire_blaster at 1000 (the soldiers' and flyers' bolts keep the
    default) }
  if (Seq.Kind = akBlaster) and ((Def^.ClassName = 'monster_floater') or
     (Def^.ClassName = 'monster_hover') or (Def^.ClassName = 'monster_medic') or
     (Def^.ClassName = 'monster_daedalus') or (Def^.ClassName = 'monster_medic_commander') or
     (Def^.ClassName = 'monster_makron')) then
    AttackSpeed := 1000;
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

function TQuakeMonster.CheckHint(const PlayerPos: TVector3): Boolean;
const
  Radius = 512;
var
  C, I, BestChain, StartOrder, GoalOrder, S, G: Integer;
  Pos: TVector3;
  D, SD, GD, BestDist: Single;
begin
  Result := False;
  if (HintPaths = nil) or (Length(HintPaths.Chains) = 0) or (Def^.ClassName = 'monster_turret') then
    Exit;
  { Nodes within 512 of the monster it can see, and within 512 of the
    player that the player can see, on one chain; it goes to the first,
    then along the chain to the second }
  BestChain := -1;
  BestDist := MaxSingle;
  StartOrder := 0;
  GoalOrder := 0;
  for C := 0 to High(HintPaths.Chains) do
  begin
    S := -1;
    G := -1;
    SD := MaxSingle;
    GD := MaxSingle;
    for I := 0 to High(HintPaths.Chains[C]) do
    begin
      Pos := HintPaths.Nodes[HintPaths.Chains[C][I]].Pos;
      D := PointsDistance(Pos, Transform.Translation);
      if (D < Radius) and (D < SD) and HasLineOfSight(Pos) then
      begin
        S := I;
        SD := D;
      end;
      D := PointsDistance(Pos, PlayerPos);
      if (D < Radius) and (D < GD) and Assigned(HintSight) and HintSight(PlayerPos, Pos) then
      begin
        G := I;
        GD := D;
      end;
    end;
    if (S >= 0) and (G >= 0) and (SD < BestDist) then
    begin
      BestChain := C;
      BestDist := SD;
      StartOrder := S;
      GoalOrder := G;
    end;
  end;
  if BestChain < 0 then
    Exit;
  FOnHint := True;
  FHintChain := BestChain;
  FHintOrder := StartOrder;
  FHintGoal := GoalOrder;
  WritelnLog('QuakeEntities', '%s follows hint path %d from node %d to %d', [Transform.Name, BestChain,
    StartOrder, GoalOrder]);
  Result := True;
end;

function TQuakeMonster.PursuitGoal(const PlayerPos: TVector3; out Goal: TVector3): Boolean;
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
  if Flies then
    Exit; { flyers keep heading for the player }
  { Along a hint_path chain (hint_path_touch: the next node towards the
    goal; at the goal hintpath_stop) }
  if FOnHint and (HintPaths <> nil) then
  begin
    if Near(HintPaths.Nodes[HintPaths.Chains[FHintChain][FHintOrder]].Pos) then
    begin
      if FHintOrder = FHintGoal then
      begin
        FOnHint := False;
        WritelnLog('QuakeEntities', '%s reached the end of its hint path', [Transform.Name]);
      end else
      if FHintGoal > FHintOrder then
        Inc(FHintOrder)
      else
        Dec(FHintOrder);
    end;
    if FOnHint then
    begin
      Goal := HintPaths.Nodes[HintPaths.Chains[FHintChain][FHintOrder]].Pos;
      Exit(True);
    end;
  end;
  { First where the player was last seen }
  if FHasLastSighting then
  begin
    if not Near(FLastSighting) then
    begin
      Goal := FLastSighting;
      Exit(True);
    end;
    FHasLastSighting := False;
    { Lost there: a hint path, once }
    if not FHintTried then
    begin
      FHintTried := True;
      if CheckHint(PlayerPos) then
        Exit(PursuitGoal(PlayerPos, Goal));
    end;
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
    pkBlasterBolt, pkBlueBolt: MdlPath := 'models/objects/laser/tris.md2';
    pkRocket, pkHeatRocket: MdlPath := 'models/objects/rocket/tris.md2';
    pkGrenade: MdlPath := 'models/objects/grenade/tris.md2';
    pkHandGrenade: MdlPath := 'models/objects/grenade2/tris.md2';
    pkRipper: MdlPath := 'models/objects/boomrang/tris.md2';
    pkLoogie: MdlPath := 'models/objects/loogy/tris.md2';
    pkTrap: MdlPath := 'models/weapons/z_trap/tris.md2';
    pkFlechette: MdlPath := 'models/proj/flechette/tris.md2';
    pkProx: MdlPath := 'models/weapons/g_prox/tris.md2';
    pkTesla: MdlPath := 'models/weapons/g_tesla/tris.md2';
    else MdlPath := '';
  end;
  case AKind of
    pkRipper: Life := 3;
    pkBlueBolt, pkLoogie: Life := 2;
    { 8000 / speed (725): about 11 s }
    pkPlasma: Life := 11;
    { fire_flechette: 8000 / 750 }
    pkFlechette: Life := 8000 / 750;
    { A prox mine lives until it went off (its lifetime starts when armed) }
    pkProx: Life := 1000;
    pkTesla:
      begin
        Life := 1000;
        TeslaFrame := -1;
      end;
    { fire_trap: 30 s (timestamp), its first think after 1 s }
    pkTrap:
      begin
        Life := 30;
        TrapTimer := 1;
      end;
  end;
  if MdlPath <> '' then
    { fire_blueblaster: the laser model's second skin }
    Model := Md2Manager.CreateInstance(MdlPath, Ord(AKind = pkBlueBolt));
  { The BFG ball and the plasma ball are animated sprites }
  if AKind in [pkBfg, pkPlasma] then
  begin
    if AKind = pkPlasma then
      Sprite := SpriteManager.CreateInstance('sprites/s_photon.sp2')
    else
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
    'models/monsters/bitch/tris.md2', 'models/objects/dmspot/tris.md2',
    'models/monsters/commandr/tris.md2', 'models/monsters/boss3/rider/tris.md2',
    'models/objects/minelite/light1/tris.md2', 'models/objects/minelite/light2/tris.md2',
    'models/objects/light/tris.md2', 'models/objects/ship/tris.md2',
    'models/objects/core/tris.md2', 'models/items/spawngro2/tris.md2',
    'models/items/spawngro2/tris.md2', 'models/monsters/legs/tris.md2');
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
    pkRotatingLight:
      begin
        { SP_rotating_light: "health" 10, START_OFF 1, ALARM 2 }
        Health := AEntity.GetInt('health', 10);
        LightOn := (Flags and 1) = 0;
        Alarm := (Flags and 2) <> 0;
      end;
    pkTransport:
      begin
        { SP_misc_transport: a train (TRAIN_START_ON forced) hidden until used }
        Transform.Exists := False;
        FlySpeed := AEntity.Speed(300);
      end;
    { Ground Zero's target_blacklight / target_orb: spawngro2 frames 1 / 2 }
    pkBlacklight:
      if Model <> nil then
        Model.SetFrame(1);
    pkOrb:
      if Model <> nil then
        Model.SetFrame(2);
    { Widowlegs_Spawn: what the Widow leaves when she beams out }
    pkWidowLegs:
      if Model <> nil then
        Model.PlayAnim('', False, 10);
  end;
  { SP_misc_blackhole / eastertank / easterchick(2): frame ranges }
  AnimFirst := -1;
  case AKind of
    pkBlackHole: begin AnimFirst := 0; AnimLast := 18; end;
    pkEasterTank: begin AnimFirst := 254; AnimLast := 292; end;
    pkEasterChick: begin AnimFirst := 208; AnimLast := 247; end;
    pkEasterChick2: begin AnimFirst := 248; AnimLast := 286; end;
    { Think_Boss3Stand: the Makron's stand201..stand260 on the rider model }
    pkBoss3Stand: begin AnimFirst := 414; AnimLast := 473; end;
    else ;
  end;
  { monster_commander_body: lying still (frame 0, "inactive") until used }
  if (AKind = pkCommanderBody) and (Model <> nil) then
    Model.SetFrame(0);
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
  if (Model <> nil) and (Kind in [pkBanner, pkSatelliteDish, pkWidowLegs]) then
    Model.Update(SecondsPassed);
  if Kind in [pkBlacklight, pkOrb] then
  begin
    { blacklight_think / orb_think: new random angles every 0.1 s }
    AlarmTimer := AlarmTimer - SecondsPassed;
    if AlarmTimer <= 0 then
    begin
      AlarmTimer := 0.1;
      Transform.Rotation := Vector4(Vector3(Random - 0.5, Random - 0.5, Random - 0.5).Normalize,
        Random * 2 * Pi);
    end;
  end;
  if (Kind = pkRotatingLight) and LightOn then
  begin
    { EF_SPINNINGLIGHTS: the model and its light turn half a degree a
      millisecond }
    SpinAngle := FMod(SpinAngle + 500 * SecondsPassed, 360);
    Transform.Rotation := Vector4(0, 1, 0, DegToRad(Entity.Angle + SpinAngle));
    if AlarmActive then
    begin
      { rotating_light_alarm: misc/alarm.wav every second, ATTN_STATIC }
      AlarmTimer := AlarmTimer - SecondsPassed;
      if AlarmTimer <= 0 then
      begin
        AlarmTimer := AlarmTimer + 1;
        Sounds.PlayAt('sound/misc/alarm.wav', Transform, 1, ATTN_STATIC, chVoice);
      end;
    end;
  end;
  if (Model <> nil) and AnimOnce then
  begin
    { commander_body_think: frames 1..24 once, 10 a second; the thud on 22 }
    AnimTime := AnimTime + SecondsPassed * 10;
    Frame := Min(Trunc(AnimTime), AnimLast - AnimFirst);
    Model.ShowFrames(AnimFirst + Frame, AnimFirst + Min(Frame + 1, AnimLast - AnimFirst),
      IfThen(Frame < AnimLast - AnimFirst, Frac(AnimTime), 0));
    if (Kind = pkCommanderBody) and (not ThudPlayed) and (AnimFirst + Frame >= 22) then
    begin
      ThudPlayed := True;
      Sounds.PlayAt('sound/tank/thud.wav', Transform, 1, 1, chBody);
    end;
    if Frame >= AnimLast - AnimFirst then
      AnimOnce := False;
  end else
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
  Mal := AEntity.ClassName = 'target_mal_laser';
  FDamage := AEntity.GetInt('dmg', IfThen(Mal, 5, 100));
  Wait := AEntity.GetFloat('wait', 0.1);
  if Wait <= 0 then
    Wait := 0.1;
  Delay := AEntity.GetFloat('delay', 0.1);
  if Delay <= 0 then
    Delay := 0.1;
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
var
  Width: Single;
begin
  Length := Max(1, Len);
  { target_mal_laser: FAT (64) is 16 units wide, else 4 }
  if Mal and ((Entity.SpawnFlags and 64) <> 0) then
    Width := 6
  else
    Width := 1.5;
  Beam.Size := Vector3(Length, Width, Width);
  Beam.Translation := Vector3(Length / 2, 0, 0);
end;

procedure TQuakeLaser.SetOn(const Value: Boolean);
begin
  if Value and not FOn then
  begin
    { target_mal_laser_on: the first pulse Wait + Delay later }
    PulseTimer := Wait + Delay;
    Pulses := 0;
  end;
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
  FreeGenericDefs;
end.
