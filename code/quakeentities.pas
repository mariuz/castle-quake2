{ Quake 2 entity definitions: items, pickups, monsters, triggers and projectiles. }
unit QuakeEntities;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes, CastleQuaternions, CastleUtils,
  QuakeBsp, QuakeMd2, QuakeLight, QuakeSound, QuakeHud;

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
    Cooldown: Single;
    Sound: String;
  end;

  TAttackKind = (akMelee, akHitscan, akBlaster, akRocket, akGrenade, akRail, akPellets);

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

  TMonsterState = (msIdle, msChase, msAttack, msPain, msDying, msDead);

  TQuakeMonster = class;
  TMonsterAttackEvent = procedure(const Monster: TQuakeMonster) of object;

  { Active 3D monster in the world.
    A TCastleBehavior of its Transform, inspectable in the CGE inspector. }
  TQuakeMonster = class(TCastleBehavior)
  private
    FLightTimer: Single;
    FSightTimer: Single;
    FFallSpeed: Single;
    function GetEntityClass: String;
    procedure SetState(const NewState: TMonsterState);
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
    OnAttack: TMonsterAttackEvent;
    constructor CreateMonster(const AParent: TCastleTransform; const ADef: PQuakeMonsterDef;
      const AEntity: TQuakeEntity; const Pos: TVector3; const Yaw: Single);
    destructor Destroy; override;
    { Eye position in CGE space }
    function EyePos: TVector3;
    procedure UpdateAI(const SecondsPassed: Single; const PlayerPos: TVector3);
    procedure TakeDamage(const Dmg: Integer);
    procedure Alert;
    function IsAlive: Boolean;
    { Owns the scene: used to map ray hits back to monsters }
    function OwnsTransform(const T: TCastleTransform): Boolean;
  published
    property EntityClass: String read GetEntityClass;
    property MonsterState: TMonsterState read State;
    property HitPoints: Integer read Health;
    property IsAlerted: Boolean read Alerted;
    property SeesPlayer: Boolean read CanSeePlayer;
    property Facing: Single read FacingAngle;
  end;

  TQuakeMonsterList = specialize TObjectList<TQuakeMonster>;

  TProjectileKind = (pkBlasterBolt, pkRocket, pkGrenade, pkBfg);

  { Active projectile (blaster bolt, rocket, grenade, BFG ball) }
  TQuakeProjectile = class
  public
    Kind: TProjectileKind;
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
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
    (ClassName: 'ammo_grenades'; Category: icAmmo; Model: 'models/items/ammo/grenades/medium/tris.md2'; Icon: 'a_grenades'; Name: 'Grenades'; Sound: 'sound/misc/am_pkup.wav'; Weapon: 0; AmmoType: atGrenades; Amount: 5; Param: 0),
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

  { Weapon slots 1..10 (key 0 selects slot 10) }
  WeaponDefs: array[1..10] of TQuakeWeaponDef = (
    (Name: 'Blaster'; ViewModel: 'models/weapons/v_blast/tris.md2'; Icon: 'w_blaster'; AmmoType: atNone; AmmoPerShot: 0; Cooldown: 0.5; Sound: 'sound/weapons/blastf1a.wav'),
    (Name: 'Shotgun'; ViewModel: 'models/weapons/v_shotg/tris.md2'; Icon: 'w_shotgun'; AmmoType: atShells; AmmoPerShot: 1; Cooldown: 1.0; Sound: 'sound/weapons/shotgf1b.wav'),
    (Name: 'Super Shotgun'; ViewModel: 'models/weapons/v_shotg2/tris.md2'; Icon: 'w_sshotgun'; AmmoType: atShells; AmmoPerShot: 2; Cooldown: 1.1; Sound: 'sound/weapons/sshotf1b.wav'),
    (Name: 'Machinegun'; ViewModel: 'models/weapons/v_machn/tris.md2'; Icon: 'w_machinegun'; AmmoType: atBullets; AmmoPerShot: 1; Cooldown: 0.1; Sound: 'sound/weapons/machgf1b.wav'),
    (Name: 'Chaingun'; ViewModel: 'models/weapons/v_chain/tris.md2'; Icon: 'w_chaingun'; AmmoType: atBullets; AmmoPerShot: 1; Cooldown: 0.05; Sound: 'sound/weapons/machgf2b.wav'),
    (Name: 'Grenade Launcher'; ViewModel: 'models/weapons/v_launch/tris.md2'; Icon: 'w_glauncher'; AmmoType: atGrenades; AmmoPerShot: 1; Cooldown: 0.8; Sound: 'sound/weapons/grenlf1a.wav'),
    (Name: 'Rocket Launcher'; ViewModel: 'models/weapons/v_rocket/tris.md2'; Icon: 'w_rlauncher'; AmmoType: atRockets; AmmoPerShot: 1; Cooldown: 0.8; Sound: 'sound/weapons/rocklf1a.wav'),
    (Name: 'HyperBlaster'; ViewModel: 'models/weapons/v_hyperb/tris.md2'; Icon: 'w_hyperblaster'; AmmoType: atCells; AmmoPerShot: 1; Cooldown: 0.1; Sound: 'sound/weapons/hyprbf1a.wav'),
    (Name: 'Railgun'; ViewModel: 'models/weapons/v_rail/tris.md2'; Icon: 'w_railgun'; AmmoType: atSlugs; AmmoPerShot: 1; Cooldown: 1.5; Sound: 'sound/weapons/railgf1a.wav'),
    (Name: 'BFG10K'; ViewModel: 'models/weapons/v_bfg/tris.md2'; Icon: 'w_bfg'; AmmoType: atCells; AmmoPerShot: 50; Cooldown: 2.5; Sound: 'sound/weapons/bfg__f1y.wav')
  );

  AmmoIcons: array[TAmmoType] of String = ('', 'a_shells', 'a_bullets', 'a_grenades',
    'a_rockets', 'a_cells', 'a_slugs');

  MonsterDefs: array[0..18] of TQuakeMonsterDef = (
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

{ Lookup tables (nil when the classname is unknown) }
function FindItemDef(const AClassName: String): PQuakeItemDef;
function FindMonsterDef(const AClassName: String): PQuakeMonsterDef;

{ Full sound path for a monster sound name }
function MonsterSound(const Def: PQuakeMonsterDef; const Name: String): String;

implementation

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
  for I := Low(MonsterDefs) to High(MonsterDefs) do
    if MonsterDefs[I].ClassName = AClassName then
      Exit(@MonsterDefs[I]);
  Result := nil;
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
  Transform.AddBehavior(Self);
  AParent.Add(Transform);
end;

destructor TQuakeMonster.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
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
  if Model = nil then
    Exit;
  case NewState of
    msIdle: Model.PlayAnim('stand,idle,fidget', True, 10);
    msChase:
      if not Model.PlayAnim('run', True, 10) then
        Model.PlayAnim('walk,stand', True, 10);
    msAttack: Model.PlayAnim('attak,attack,atk,fire,shoot,melee,swing,stand', False, 12);
    msPain: Model.PlayAnim('pain', False, 12);
    msDying: Model.PlayAnim('death,die,dead', False, 10);
    msDead: ;
  end;
end;

procedure TQuakeMonster.Alert;
begin
  if Alerted or not IsAlive then
    Exit;
  Alerted := True;
  Sounds.PlayAt(MonsterSound(Def, Def^.SightSound), Transform);
  SetState(msChase);
end;

procedure TQuakeMonster.TakeDamage(const Dmg: Integer);
begin
  if not IsAlive then
  begin
    { Shooting corpses gibs them }
    Health := Health - Dmg;
    if (Health < -40) and not Gibbed then
    begin
      Gibbed := True;
      Sounds.PlayAt('sound/misc/udeath.wav', Transform);
      Transform.Exists := False;
    end;
    Exit;
  end;

  Health := Health - Dmg;
  if Health <= 0 then
  begin
    Sounds.PlayAt(MonsterSound(Def, Def^.DeathSound), Transform);
    if Model <> nil then
      Model.Scene.Collides := False;
    if Health < -40 then
    begin
      Gibbed := True;
      Sounds.PlayAt('sound/misc/udeath.wav', Transform);
      Transform.Exists := False;
      State := msDead;
    end else
      SetState(msDying);
    Exit;
  end;

  if not Alerted then
    Alert;
  { Quake 2 monsters don't flinch on every hit }
  if (State <> msPain) and (Random < 0.6) then
  begin
    Sounds.PlayAt(MonsterSound(Def, Def^.PainSound), Transform);
    SetState(msPain);
  end;
end;

procedure TQuakeMonster.StickToFloor(const SecondsPassed: Single);
var
  Above: Single;
  P: TVector3;
begin
  if Def^.Flying then
    Exit;
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
  Delta, MoveVec: TVector3;
  Dist, TargetYaw, Diff: Single;
begin
  if Model <> nil then
  begin
    Model.Update(SecondsPassed);
    FLightTimer := FLightTimer - SecondsPassed;
    if FLightTimer <= 0 then
    begin
      FLightTimer := 0.25;
      Model.SetTint(Lighting.SampleLight(Transform.Translation));
    end;
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
  end;

  Delta := PlayerPos - Transform.Translation;
  Dist := Delta.Length;

  { Line of sight checks are throttled }
  FSightTimer := FSightTimer - SecondsPassed;
  if FSightTimer <= 0 then
  begin
    FSightTimer := 0.2;
    CanSeePlayer := (Dist < 2000) and Transform.LineOfSight(EyePos, PlayerPos);
    if (not Alerted) and CanSeePlayer and (Dist < 1200) then
      Alert;
  end;

  if not Alerted then
  begin
    StickToFloor(SecondsPassed);
    Exit;
  end;

  { Turn towards the player }
  TargetYaw := RadToDeg(ArcTan2(-Delta.Z, Delta.X));
  Diff := FloatModulo(TargetYaw - FacingAngle + 540, 360) - 180;
  FacingAngle := FacingAngle + EnsureRange(Diff, -360 * SecondsPassed, 360 * SecondsPassed);
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(FacingAngle));

  AttackCooldown := AttackCooldown - SecondsPassed;

  if State = msAttack then
  begin
    if (Model = nil) or Model.AnimDone or (StateTimer > 1.2) then
      SetState(msChase);
    StickToFloor(SecondsPassed);
    Exit;
  end;

  if CanSeePlayer and (Dist <= Def^.AttackRange) and (AttackCooldown <= 0) then
  begin
    SetState(msAttack);
    AttackCooldown := Def^.AttackCooldown * (0.8 + Random * 0.4);
    Sounds.PlayAt(MonsterSound(Def, Def^.AttackSound), Transform);
    if Assigned(OnAttack) then
      OnAttack(Self);
    Exit;
  end;

  { Chase: melee monsters close in, ranged ones keep some distance }
  if (Def^.Attack = akMelee) or (Dist > Def^.AttackRange * 0.6) or not CanSeePlayer then
  begin
    MoveVec := Delta;
    if not Def^.Flying then
      MoveVec.Y := 0
    else
      { Flyers hover a bit above the player's eyes }
      MoveVec.Y := (PlayerPos.Y + 24) - Transform.Translation.Y;
    if (MoveVec.Length > 1) and (Dist > 40) then
      Transform.Move(MoveVec.Normalize * Def^.Speed * SecondsPassed, False, True);
  end;
  StickToFloor(SecondsPassed);
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
  Dir := Vel.Normalize;
  Yaw := ArcTan2(-Dir.Z, Dir.X);
  Pitch := ArcSin(EnsureRange(Dir.Y, -1, 1));
  Transform.Rotation := (QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) *
    QuatFromAxisAngle(Vector3(0, 0, 1), Pitch)).ToAxisAngle;

  case AKind of
    pkBlasterBolt: MdlPath := 'models/objects/laser/tris.md2';
    pkRocket: MdlPath := 'models/objects/rocket/tris.md2';
    pkGrenade: MdlPath := 'models/objects/grenade/tris.md2';
    else MdlPath := '';
  end;
  if MdlPath <> '' then
    Model := Md2Manager.CreateInstance(MdlPath);
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
  Model.Free;
  Transform.Free;
  inherited Destroy;
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

end.
