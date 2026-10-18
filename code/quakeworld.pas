{ Quake 2 gameplay simulation: weapons, inventory, armor, combat, monster
  attacks, pickups, target/trigger chains, movers and level transitions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson, jsonparser,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes, CastleQuaternions,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeMap, QuakeMd2, QuakePlayer, QuakeLight, QuakeSound, QuakeHud, QuakeSettings,
  QuakeParticles, QuakeEntities, QuakeWeaponFrames, QuakeMonsterAttacks, QuakeTrace;

const
  { Quake 2 player: eye 22 above origin, origin 24 above the feet }
  PlayerEyeHeight = 46.0;

type
  { Something to do later: use the entities named Target, or (Entity set)
    do Entity's own delayed action (target_explosion) }
  TDelayedTarget = record
    Time: Single;
    Target: String;
    Entity: TQuakeEntity;
  end;

  { World simulation manager }
  TQuakeWorld = class
  private
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
    FTeleportPending: Boolean;
    FTeleportPos: TVector3;
    FTeleportAngle: Single;
    FDead: Boolean;
    FDeadTimer: Single;
    FRestartPending: Boolean;
    FPainSoundTimer: Single;
    FHurtTimer: Single;
    FKeyIcons: TStringList;
    FUseDepth: Integer;
    FHelpPrimary, FHelpSecondary: String;
    FPlayer: TQuakePlayerMovement;
    { Quake 2 game.serverflags: cross-level trigger bits, kept across maps of a unit }
    FServerFlags: Integer;
    { States of levels left through a changelevel in the current unit, by map name }
    FLevelStates: TJSONObject;
    FLastWaterLevel: Integer;
    FAirFinished: Single;
    FLiquidDamageTimer: Single;
    procedure UpdateLiquids(const SecondsPassed: Single);
    procedure SetPlayer(const Value: TQuakePlayerMovement);
    procedure PlayerFallDamage(const Damage: Integer);
    procedure PlayerLanded(Sender: TObject);
    procedure ResetStats;
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
    function MoverTrace(const Mover: TQuakeMover; const Start, Stop, Mins, Maxs: TVector3;
      const Mask: Integer): TQuakeTrace;
    { The same with the mover at pose M (its transform matrix) }
    function MoverTraceAt(const Mover: TQuakeMover; const M: TMatrix4;
      const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
    { Movers carry the player standing on them and push him when they
      move into him (Quake 2 SV_Push) }
    procedure PushPlayerByMovers;
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
    { WorldRayCast for shots: a ducking monster only has the lower part of
      its body (Quake 2 ducks to maxs.z = -8, 8 units below the origin), so
      higher hits pass over it }
    function ShotRayCast(const Origin, Dir: TVector3; out Dist: Single): TCastleTransform;
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
    procedure DamageProp(const Prop: TQuakeProp; const Damage: Integer);
    function PropByTransform(const T: TCastleTransform): TQuakeProp;
    procedure UpdateTimersAndLasers(const SecondsPassed: Single);
    { Shootable brushes: func_explosive, doors / buttons with "health" }
    procedure DamageMover(const Mover: TQuakeMover; const Damage: Integer);
    procedure KillPlayer;
    procedure ClearLevel;
  public
    { AMap is the TQuakeMap component inside AItems (usually from the view design). }
    constructor Create(const AItems: TCastleAbstractRootTransform; const AMap: TQuakeMap);
    destructor Destroy; override;

    { Load a map, e.g. "base1" or "base2$spawnname". Keeps the inventory. }
    function LoadMap(const AMapName: String): Boolean;

    { Fire all entities with the given targetname (Quake 2 G_UseTargets) }
    procedure UseTargets(const ATarget: String);

    { Advance world simulation. PlayerPos is the camera (eye) position. }
    procedure Update(const SecondsPassed: Single; const PlayerPos, PlayerDir: TVector3);
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

    { Press / open what the player is looking at }
    procedure ActivateUse(const Origin, Dir: TVector3);

    { Damage the player (armor absorbs part of it) }
    procedure DamagePlayer(const Amount: Integer; const FromPos: TVector3);

    procedure CheatGiveAll;
    procedure CheatGodMode;
    { give quad / give invulnerability: 30 seconds, like the items }
    procedure CheatPowerup(const Quad: Boolean);

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
    property LevelExited: Boolean read FLevelExited;
    property NextMap: String read FNextMap;
    property TeleportPending: Boolean read FTeleportPending;
    property TeleportPos: TVector3 read FTeleportPos;
    property TeleportAngle: Single read FTeleportAngle;
    property RestartPending: Boolean read FRestartPending;
    property Dead: Boolean read FDead;
    property Monsters: TQuakeMonsterList read FMonsters;
    function ProjectileCount: Integer;
    function DelayedCount: Integer;
    property Pickups: TQuakePickupList read FPickups;
    property Props: TQuakePropList read FProps;
    property Lasers: TQuakeLaserList read FLasers;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Geometry: TQuakeGeometry read FGeometry;
    property Bsp: TQuakeBsp read FBsp;
  end;

implementation

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
  FSightEntities := specialize TList<TQuakeMonster>.Create;
  FMoverPoses := specialize TDictionary<TQuakeMover, TMatrix4>.Create;
  PlayerBlockBox := TBox3D.Empty;
  EntityTrace := @WorldTrace;
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
  FDelayed := specialize TList<TDelayedTarget>.Create;
  FCounters := specialize TDictionary<TQuakeEntity, Integer>.Create;
  FKeyIcons := TStringList.Create;
  FLevelStates := TJSONObject.Create;
  FWeaponTransform := TCastleTransform.Create(nil);
  FWeaponModelSlot := -1;
  ResetStats;
end;

destructor TQuakeWorld.Destroy;
begin
  Sounds.ClearLoops;
  Sounds.WorldParent := nil;
  ClearLevel;
  FreeAndNil(FWeaponModel);
  FreeAndNil(FWeaponTransform);
  FreeAndNil(FGun);
  FreeAndNil(FMoverPoses);
  EntityTrace := nil;
  FreeAndNil(FCollision);
  FPickups.Free;
  FMonsters.Free;
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
  FMonsters.Clear;
  FProjectiles.Clear;
  FTriggers.Clear;
  FSpeakers.Clear;
  FProps.Clear;
  FLasers.Clear;
  FTimers.Clear;
  FDelayed.Clear;
  FCounters.Clear;
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
var
  Ent, Best: TQuakeEntity;
  Score, BestScore: Integer;
begin
  { Best: the info_player_start named by the changelevel "$spawn" suffix,
    then an unnamed info_player_start, then any start, then deathmatch spots }
  Best := nil;
  BestScore := 0;
  for Ent in FBsp.Entities do
  begin
    if Ent.ClassName = 'info_player_start' then
    begin
      if (SpawnName <> '') and SameText(Ent.TargetName, SpawnName) then
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

procedure TQuakeWorld.SpawnEntities(const SpawnName: String);
var
  Ent: TQuakeEntity;
  CName: String;
  Pos: TVector3;
  ItemDef: PQuakeItemDef;
  MonsterDef: PQuakeMonsterDef;
  Monster: TQuakeMonster;
  AmbushCount, DormantCount: Integer;
  Box: TBox3D;
  Trig: TQuakeTrigger;
  SpawnFlags: Integer;
  D: TDelayedTarget;
begin
  ChooseSpawnPoint(SpawnName);
  for Ent in FBsp.Entities do
  begin
    CName := Ent.ClassName;
    Pos := QuakeToCge(Ent.Origin);
    SpawnFlags := Ent.SpawnFlags;

    { Entities not on this skill (single player) }
    if (SpawnFlags and SkillSpawnFlag(GameSkill)) <> 0 then
      Continue;

    if (CName = 'info_player_start') or (CName = 'info_player_deathmatch') then
      Continue; { chosen by ChooseSpawnPoint }

    ItemDef := FindItemDef(CName);
    if ItemDef <> nil then
    begin
      { Items rest on the floor; origin is 15 units above it }
      FPickups.Add(TQuakePickup.CreatePickup(FMap, ItemDef, Ent, Pos));
      Continue;
    end;

    MonsterDef := FindMonsterDef(CName);
    if MonsterDef <> nil then
    begin
      Monster := TQuakeMonster.CreateMonster(FMap, MonsterDef, Ent, Pos, Ent.Angle);
      Monster.OnAttack := @MonsterAttack;
      Monster.OnFoundTarget := @MonsterFoundTarget;
      Monster.OnPickTarget := @PickTarget;
      Monster.OnUseTargets := @UseTargets;
      Monster.ResolveTargets;
      FMonsters.Add(Monster);
      Inc(FStats.TotalKills);
      Continue;
    end;

    if (Copy(CName, 1, 8) = 'trigger_') and ModelBox(Ent.Model, Box) then
    begin
      Trig := TQuakeTrigger.Create(Ent, Box);
      if ((SpawnFlags and TRIGGER_TRIGGERED) <> 0) and (Ent.TargetName <> '') then
        Trig.Enabled := False;
      FTriggers.Add(Trig);
      Continue;
    end;

    if CName = 'misc_teleporter' then
    begin
      { Teleporter pad trigger, around its origin }
      Trig := TQuakeTrigger.Create(Ent, Box3D(Pos - Vector3(24, 24, 24), Pos + Vector3(24, 32, 24)));
      FTriggers.Add(Trig);
      Continue;
    end;

    if CName = 'target_speaker' then
    begin
      FSpeakers.Add(TQuakeSpeaker.CreateSpeaker(FMap, Ent));
      Continue;
    end;

    { Switchable lights (style 32+ assigned by the map compiler), START_OFF = 1 }
    if (Copy(CName, 1, 5) = 'light') and (Ent.TargetName <> '') and
       (Ent.GetInt('style', 0) >= 32) then
    begin
      if (SpawnFlags and 1) <> 0 then
        Lighting.SetStyle(Ent.GetInt('style', 0), 'a')
      else
        Lighting.SetStyle(Ent.GetInt('style', 0), 'm');
      Continue;
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
        POWERUP_INVULN: FStats.InvulnTime := FStats.InvulnTime + Def^.Amount;
        POWERUP_ADRENALINE:
          begin
            Inc(FStats.MaxHealth);
            FStats.Health := Max(FStats.Health, FStats.MaxHealth);
          end;
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
            end else
            begin
              FStats.MaxAmmo[atShells] := Max(FStats.MaxAmmo[atShells], 150);
              FStats.MaxAmmo[atBullets] := Max(FStats.MaxAmmo[atBullets], 250);
              FStats.MaxAmmo[atCells] := Max(FStats.MaxAmmo[atCells], 250);
              FStats.MaxAmmo[atSlugs] := Max(FStats.MaxAmmo[atSlugs], 75);
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
begin
  for P in FPickups do
  begin
    if P.Collected then
      Continue;
    Delta := P.Origin - FPlayerPos;
    if (Sqr(Delta.X) + Sqr(Delta.Z) < Sqr(40)) and (Delta.Y > -PlayerEyeHeight - 20) and (Delta.Y < 20) then
    begin
      if not GiveItem(P.Def) then
        Continue;
      P.Collected := True;
      Sounds.Play(P.Def^.Sound, 1, chItem);
      if FHud <> nil then
        FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
      { Picked items can fire targets too }
      UseTargets(P.Entity.Target);
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
    UseTargets(Ent.Target);
end;

procedure TQuakeWorld.UseEntity(const Ent: TQuakeEntity);
var
  CName, Msg, MapName: String;
  Mover: TQuakeMover;
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
begin
  CName := Ent.ClassName;
  Msg := Ent.MessageText;

  if CName = 'func_areaportal' then
  begin
    FGeometry.ToggleAreaPortal(Ent);
    Exit;
  end;

  { trigger_key: needs an item }
  if CName = 'trigger_key' then
  begin
    ItemDef := FindItemDef(LowerCase(Ent.GetField('item')));
    if (ItemDef <> nil) and ((FStats.Keys and Cardinal(ItemDef^.Amount)) = 0) then
    begin
      if FHud <> nil then
        FHud.ShowMessage('You need the ' + ItemDef^.Name);
      Sounds.Play('sound/misc/keytry.wav');
      Exit;
    end;
    Sounds.Play('sound/misc/keyuse.wav');
    if ItemDef <> nil then
      FStats.Keys := FStats.Keys and not Cardinal(ItemDef^.Amount);
    UseTargets(Ent.Target);
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
    UseTargets(Ent.Target);
    Exit;
  end;

  if (Msg <> '') and (FHud <> nil) and (Copy(CName, 1, 7) = 'target_') then
    FHud.ShowMessage(Msg, 4);

  if CName = 'target_changelevel' then
  begin
    MapName := Ent.GetField('map');
    { Ignore cinematics / end screens (e.g. "victory.pcx", "*.cin") }
    if (MapName <> '') and (Pos('.', MapName) = 0) then
    begin
      FLevelExited := True;
      FNextMap := MapName;
    end;
  end else
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
  if Copy(CName, 1, 5) = 'misc_' then
  begin
    for Prop in FProps do
      if Prop.Entity = Ent then
        ActivateProp(Prop);
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
    Sounds.Play('sound/world/quake.wav')
  else
  if CName = 'trigger_relay' then
    UseTargetsOf(Ent)
  else
  if Copy(CName, 1, 8) = 'monster_' then
  begin
    for M in FMonsters do
      if M.Entity = Ent then
      begin
        if M.Dormant then
          M.Spawn { TRIGGER_SPAWN }
        else
          M.Alert;
      end;
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
    if Mover <> nil then
    begin
      if Mover.Kind = mkStatic then
      begin
        if CName = 'func_explosive' then
        begin
          Explode(Mover.Center, Ent.GetInt('dmg', 0), 120, False);
          Mover.Transform.Exists := False;
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
      UseTargets(Ent.Target);
  end;
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
    Explode(Mover.Center, Mover.Entity.GetInt('dmg', 0), 120, False);
    Mover.Transform.Exists := False;
    UseTargets(Mover.Target);
  end else
  begin
    { Shot-activated doors and buttons reset their health, like Quake 2 }
    Mover.Health := Mover.Entity.GetInt('health', 0);
    Mover.Use;
    if Mover.Kind <> mkButton then
      UseTargets(Mover.Target);
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

procedure TQuakeWorld.ActivateProp(const Prop: TQuakeProp);
var
  List: TQuakeEntityList;
begin
  case Prop.Kind of
    pkSatelliteDish:
      if Prop.Model <> nil then
        Prop.Model.PlayAnim('', False, 10);
    pkStroggShip:
      begin
        List := FBsp.FindByTargetName(Prop.Entity.Target);
        try
          if List.Count > 0 then
          begin
            Prop.Transform.Exists := True;
            Prop.FlyCorner := List[0];
            Prop.FlyTarget := QuakeToCge(List[0].Origin);
            Prop.Flying := True;
          end;
        finally
          List.Free;
        end;
      end;
    pkExplobox:
      DamageProp(Prop, 1000);
  end;
end;

procedure TQuakeWorld.DamageProp(const Prop: TQuakeProp; const Damage: Integer);
var
  Dmg: Integer;
begin
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
  UseTargets(Prop.Entity.Target);
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
  Hit: TCastleTransform;
  ToPlayer: TVector3;
  Along: Single;
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
      UseTargets(Ent.Target);
    end;
  finally
    Fire.Free;
  end;

  { target_laser: beam until the first wall, damages the player in it }
  for Laser in FLasers do
  begin
    if not Laser.IsOn then
      Continue;
    Hit := FItems.WorldRayCast(Laser.Origin, Laser.Direction, Dist);
    if (Hit = nil) or (Dist > 2048) then
      Dist := 2048;
    Laser.SetLength(Dist);
    ToPlayer := (FPlayerPos - Vector3(0, 22, 0)) - Laser.Origin;
    Along := TVector3.DotProduct(ToPlayer, Laser.Direction);
    if (Along > 0) and (Along < Dist) and
       ((ToPlayer - Laser.Direction * Along).Length < 20) then
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
          Prop.Flying := False;
          Prop.Transform.Exists := False;
        end;
      finally
        List.Free;
      end;
    end;
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

procedure TQuakeWorld.UseTargets(const ATarget: String);
var
  List: TQuakeEntityList;
  Ent: TQuakeEntity;
begin
  if (ATarget = '') or (FBsp = nil) or (FUseDepth > 16) then
    Exit;
  Inc(FUseDepth);
  List := FBsp.FindByTargetName(ATarget);
  try
    for Ent in List do
      UseEntity(Ent);
  finally
    List.Free;
    Dec(FUseDepth);
  end;
end;

procedure TQuakeWorld.CheckTriggers(const SecondsPassed: Single);
var
  Trig: TQuakeTrigger;
  CName, Msg: String;
  PBox: TBox3D;
  Dests: TQuakeEntityList;
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

    if CName = 'misc_teleporter' then
    begin
      Dests := FBsp.FindByTargetName(Trig.Entity.Target);
      try
        if Dests.Count > 0 then
        begin
          FTeleportPending := True;
          FTeleportPos := QuakeToCge(Dests[0].Origin) + Vector3(0, PlayerEyeHeight - 24 + 10, 0);
          FTeleportAngle := Dests[0].Angle;
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
        UseTargets(Trig.Entity.Target);
      if CName = 'trigger_once' then
        Trig.Enabled := False
      else
        Trig.Cooldown := Max(0.2, Trig.Entity.GetFloat('wait', 0.2));
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
var
  Mover: TQuakeMover;
  Box, PBox: TBox3D;
begin
  PBox := PlayerBox;
  for Mover in FGeometry.Movers do
  begin
    if not Mover.Transform.Exists then
      Continue;
    Box := Mover.WorldBox;
    if Box.IsEmpty then
      Continue;
    case Mover.Kind of
      mkDoor, mkDoorRotating:
        if Mover.AutoOpen and (Mover.State = msAtStart) then
        begin
          { Quake 2 door trigger field: the door box expanded by 60 horizontally }
          Box.Data[0] := Box.Data[0] - Vector3(60, 0, 60);
          Box.Data[1] := Box.Data[1] + Vector3(60, 0, 60);
          if Box.Collision(PBox) then
            Mover.Use;
        end else
        if Mover.AutoOpen and (Mover.State = msAtEnd) then
        begin
          Box.Data[0] := Box.Data[0] - Vector3(60, 0, 60);
          Box.Data[1] := Box.Data[1] + Vector3(60, 0, 60);
          if Box.Collision(PBox) then
            Mover.StateTimer := Mover.WaitTime;
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
  if FStats.QuadTime > 0 then
    Result := 4
  else
    Result := 1;
end;

procedure TQuakeWorld.FireHitscan(const Origin, Dir: TVector3; const Damage: Integer;
  const HSpread, VSpread: Single; const Rail: Boolean);
var
  ShotDir, HitPos, Start, Right, Muzzle: TVector3;
  Hit: TCastleTransform;
  Dist: Single;
  M: TQuakeMonster;
  Mover: TQuakeMover;
  Pierce: Integer;
begin
  ShotDir := SpreadDir(Dir, HSpread, VSpread);
  Start := Origin;
  { Rail trails start at the gun muzzle (right and below the eye), not the eye }
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.Length > 0.001 then
    Right := Right.Normalize;
  Muzzle := Origin + Dir * 24 + Right * 7 - Vector3(0, 8, 0);
  { The railgun pierces through monsters }
  for Pierce := 0 to 4 do
  begin
    Hit := ShotRayCast(Start, ShotDir, Dist);
    if (Hit = nil) or (Dist > 8192) then
    begin
      if Rail then
        Particles.SpawnRailTrail(Muzzle, Start + ShotDir * 2000);
      Exit;
    end;
    HitPos := Start + ShotDir * Dist;
    M := MonsterByTransform(Hit);
    if M <> nil then
    begin
      M.TakeDamage(Damage);
      Particles.SpawnBlood(HitPos, -ShotDir);
      if Rail then
      begin
        { Temporarily continue the ray behind the monster }
        Start := HitPos + ShotDir * 40;
        Continue;
      end;
      Exit;
    end;

    Mover := MoverByTransform(Hit);
    if Mover <> nil then
      DamageMover(Mover, Damage);
    if PropByTransform(Hit) <> nil then
      DamageProp(PropByTransform(Hit), Damage);
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
  if Has(9, atSlugs, 1) then
    SelectWeapon(9)
  else
  if Has(8, atCells, 1) then
    SelectWeapon(8)
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

procedure TQuakeWorld.GunEvent(const Event: TGunEvent);
begin
  case Event of
    geFire: FireGun;
    geBfgFlash:
      begin
        { weapon_bfg_fire frame 9: flash and sound, the ball follows on frame 17 }
        Sounds.Play(WeaponDefs[10].Sound, 1, chWeapon);
        Lighting.TriggerMuzzleFlash(FPlayerPos + FPlayerDir * 16);
        FLastFireTime := FTime;
        PlayerNoise(FPlayerPos);
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
    geGrenadePin: Sounds.Play('sound/weapons/hgrena1b.wav', 1, chWeapon);
    geGrenadeThrow: ThrowHandGrenade(FGun.Fuse);
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
      pkRocket, pkBlasterBolt:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(1, 1, 0));
      pkBfg:
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
  if FromPlayer and (Kind in [pkBlasterBolt, pkRocket, pkBfg]) then
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
        Proj.SplashDamage := 200;
        Proj.SplashRadius := 1000;
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
  Hit: TCastleTransform;
  Dist: Single;
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
    Hit := FItems.WorldRayCast(Origin, ToSpot.Normalize, Dist);
    if (Hit = nil) or (Dist >= ToSpot.Length - 1) then
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

function TQuakeWorld.ShotRayCast(const Origin, Dir: TVector3; out Dist: Single): TCastleTransform;
var
  M: TQuakeMonster;
  Skipped: array of TCastleScene;
  I: Integer;
begin
  Skipped := nil;
  try
    repeat
      Result := FItems.WorldRayCast(Origin, Dir, Dist);
      M := MonsterByTransform(Result);
      if (M = nil) or (M.State <> msDuck) or (M.Model = nil) or
         ((Origin + Dir * Dist).Y <= M.Transform.Translation.Y - 8) or (Length(Skipped) >= 8) then
        Exit;
      { Over the ducked monster: look further }
      WritelnLog('QuakeWorld', 'Shot passes over ducking %s', [M.Transform.Name]);
      M.Model.Scene.Pickable := False;
      SetLength(Skipped, Length(Skipped) + 1);
      Skipped[High(Skipped)] := M.Model.Scene;
    until False;
  finally
    for I := 0 to High(Skipped) do
      Skipped[I].Pickable := True;
  end;
end;

procedure TQuakeWorld.CheckDodge(const Origin, Dir: TVector3; const Speed: Single);
var
  Hit: TCastleTransform;
  Dist: Single;
  M: TQuakeMonster;
begin
  if (Speed <= 0) or ((GameSkill = 0) and (Random > 0.25)) then
    Exit;
  Hit := FItems.WorldRayCast(Origin, Dir, Dist);
  if (Hit = nil) or (Dist > 8192) then
    Exit;
  M := MonsterByTransform(Hit);
  if (M = nil) or not M.IsAlive then
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
        if (Prop.Kind = pkExplobox) and not Prop.Destroyed and
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

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single);
var
  I: Integer;
  Proj: TQuakeProjectile;
  OldPos, Dir, NewPos: TVector3;
  StepLen, Dist: Single;
  Hit: TCastleTransform;
  M: TQuakeMonster;
  Remove: Boolean;
  PlayerCenter: TVector3;
begin
  PlayerCenter := FPlayerPos - Vector3(0, 18, 0);
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    Proj := FProjectiles[I];
    Proj.Life := Proj.Life - SecondsPassed;
    Remove := False;
    OldPos := Proj.Transform.Translation;

    if Proj.Kind in [pkGrenade, pkHandGrenade] then
      Proj.Velocity.Y := Proj.Velocity.Y - 800 * SecondsPassed;
    if Proj.Sprite <> nil then
      Proj.Sprite.Update(SecondsPassed);

    if Proj.Life <= 0 then
    begin
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
        Explode(OldPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
      FProjectiles.Delete(I);
      Continue;
    end;

    StepLen := Proj.Velocity.Length * SecondsPassed;
    if StepLen < 0.001 then
      Continue;
    Dir := Proj.Velocity.Normalize;
    NewPos := OldPos + Dir * StepLen;

    { Monster projectiles hit the player (approximate sphere test) }
    if not Proj.FromPlayer and (PointsDistance(NewPos, PlayerCenter) < 28) then
    begin
      if Proj.SplashRadius > 0 then
        Explode(NewPos, Proj.Damage, Proj.SplashRadius, False)
      else
      begin
        DamagePlayer(Proj.Damage, OldPos);
        Particles.SpawnBlasterImpact(NewPos, -Dir);
      end;
      FProjectiles.Delete(I);
      Continue;
    end;

    Hit := ShotRayCast(OldPos, Dir, Dist);
    M := MonsterByTransform(Hit);
    if (M <> nil) and (M = Proj.Owner) then
      Hit := nil; { don't hit yourself right after firing }
    if (Hit <> nil) and (Dist <= StepLen) then
    begin
      NewPos := OldPos + Dir * Max(0, Dist - 2);
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
      begin
        if M <> nil then
        begin
          Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          Remove := True;
        end else
        begin
          { Bounce: floors invert the vertical speed, walls the horizontal }
          if (Dir.Y < -0.5) then
            Proj.Velocity := Vector3(Proj.Velocity.X * 0.6, -Proj.Velocity.Y * 0.4, Proj.Velocity.Z * 0.6)
          else
            Proj.Velocity := Vector3(-Proj.Velocity.X * 0.5, Proj.Velocity.Y, -Proj.Velocity.Z * 0.5);
          if Proj.Kind = pkHandGrenade then
            Sounds.PlayAt(Format('sound/weapons/hgrenb%da.wav', [1 + Random(2)]), Proj.Transform)
          else
            Sounds.PlayAt('sound/weapons/grenlb1b.wav', Proj.Transform);
        end;
      end else
      begin
        if M <> nil then
        begin
          M.TakeDamage(Proj.Damage);
          Particles.SpawnBlood(NewPos, -Dir);
        end else
        if MoverByTransform(Hit) <> nil then
          DamageMover(MoverByTransform(Hit), Proj.Damage)
        else
        if PropByTransform(Hit) <> nil then
          DamageProp(PropByTransform(Hit), Proj.Damage);
        case Proj.Kind of
          pkRocket: Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          pkBfg:
            begin
              Particles.SpawnBfgExplosion(NewPos);
              Lighting.AddLight(NewPos, 350, Vector3(0, 1, 0), 0.5);
              Sounds.PlayAtPoint('sound/weapons/bfg__x1b.wav', NewPos);
              Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius * 0.3, Proj.FromPlayer, False);
            end;
          else
            begin
              Particles.SpawnBlasterImpact(NewPos, -Dir);
              Sounds.PlayAtPoint('sound/weapons/lashit.wav', NewPos);
            end;
        end;
        Remove := True;
      end;
    end;

    if Remove then
      FProjectiles.Delete(I)
    else
      Proj.Transform.Translation := NewPos;
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
  Eye := Monster.EyePos;
  Target := FPlayerPos - Vector3(0, 12, 0);
  Dir := (Target - Eye).Normalize;
  Dist := PointsDistance(Eye, Target);
  if Monster.AttackKind <> akMelee then
    Lighting.TriggerMuzzleFlash(Eye);

  { Monster.AttackKind / AttackDamage / AttackBullets: the shot of its
    attack sequence (or of the generic attack) }
  case Monster.AttackKind of
    akMelee:
      if Dist < Monster.AttackReach then
        DamagePlayer(Monster.AttackDamage, Eye);
    akHitscan, akPellets, akRail:
      if Monster.CanSeePlayer then
      begin
        { Accuracy falls off with distance }
        Accuracy := EnsureRange(1.1 - Dist / 1200, 0.25, 0.95);
        if Monster.AttackKind = akPellets then
        begin
          Hits := 0;
          for I := 1 to 9 do
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
      SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, 600, Monster.AttackDamage, False, Monster);
    akRocket:
      SpawnProjectile(pkRocket, Eye + Dir * 24, Dir, 500, Monster.AttackDamage, False, Monster);
    akGrenade:
      SpawnProjectile(pkGrenade, Eye + Dir * 24, (Dir + Vector3(0, 0.35, 0)).Normalize,
        Min(600, Dist * 1.1), Monster.AttackDamage, False, Monster);
  end;
end;

procedure TQuakeWorld.DamagePlayer(const Amount: Integer; const FromPos: TVector3);
var
  Save, Take: Integer;
begin
  if FDead or FStats.GodMode or (FStats.InvulnTime > 0) or (Amount <= 0) then
    Exit;
  Take := Amount;
  { Quake 2 T_Damage: half damage on easy }
  if GameSkill = 0 then
    Take := Max(1, Take div 2);
  if (FStats.Armor > 0) and (FStats.ArmorType > 0) then
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
begin
  FDead := True;
  FDeadTimer := 3.0;
  FStats.Health := Min(FStats.Health, 0);
  Sounds.Play('sound/player/male/death' + IntToStr(1 + Random(4)) + '.wav', 1, chVoice);
  if FHud <> nil then
    FHud.ShowMessage('You died. Restarting level...', 3);
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
  FPainSoundTimer := FPainSoundTimer - SecondsPassed;
  { Projectile lights of the previous frame }
  Lighting.EndFrame;

  if FDead then
  begin
    FDeadTimer := FDeadTimer - SecondsPassed;
    if FDeadTimer <= 0 then
    begin
      FRestartPending := True;
      ResetStats;
    end;
  end;

  FGeometry.Update(SecondsPassed);

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
    M.UpdateAI(SecondsPassed, FPlayerPos);
    if (not M.IsAlive) and not M.KillCounted then
    begin
      M.KillCounted := True;
      Inc(FStats.Kills);
      { Dead monsters fire their targets (Quake 2 monster_death_use) }
      UseTargets(M.DeathTarget);
    end;
  end;
  ProcessSightEntities;
  FGeometry.ScenePlayerClip.Collides := True;

  CheckMonsterTriggers;
  UpdateTimersAndLasers(SecondsPassed);
  UpdateLiquids(SecondsPassed);
  UpdateGun(SecondsPassed);
  UpdateProjectiles(SecondsPassed);
  AddProjectileLights;
  Particles.Update(SecondsPassed);
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
      Shell := Shell + Vector3(0, 0, 1);
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
  if Def.AmmoType <> atNone then
    FStats.Ammo[Def.AmmoType] := Max(0, FStats.Ammo[Def.AmmoType] - Def.AmmoPerShot * Shots);

  FWeaponKick := 1.0;
  Mult := DamageMultiplier;
  MuzzlePos := Origin + Dir * 16;
  if Slot <> 10 then { the BFG flashed on frame 9 }
  begin
    Lighting.TriggerMuzzleFlash(MuzzlePos);
    if Slot in [4, 5] then
      Sounds.Play(Format('sound/weapons/machgf%db.wav', [1 + Random(5)]), 1, chWeapon)
    else
      Sounds.Play(Def.Sound, 1, chWeapon);
  end;
  if Mult > 1 then
    Sounds.Play('sound/items/damage3.wav', 1, chItem);

  { Firing makes noise (PNOISE_WEAPON) and shows the player hostile }
  FLastFireTime := FTime;
  PlayerNoise(Origin);

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
  O.Add('invuln', FStats.InvulnTime);
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
    Arr.Add(O);
  end;
  Result.Add('monsters', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FPickups.Count - 1 do
    Arr.Add(FPickups[I].Collected);
  Result.Add('pickups', Arr);

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
    O.Add('trainRunning', FGeometry.Movers[I].TrainRunning);
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
    FStats.InvulnTime := O.Get('invuln', 0.0);
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
      FMonsters[I].RestoreState(JsonToVec(O.Find('pos')), O.Get('facing', 0.0),
        O.Get('health', 0), TMonsterState(O.Get('state', 0)),
        O.Get('alerted', False), O.Get('gibbed', False));
      FMonsters[I].SetDormant(O.Get('dormant', False));
    end;

  Arr := Obj.Get('pickups', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FPickups.Count) - 1 do
      FPickups[I].Collected := Arr.Booleans[I];

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
      Mover.TrainRunning := O.Get('trainRunning', Mover.TrainRunning);
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
    FPlayer.OnFallDamage := @PlayerFallDamage;
    FPlayer.OnPointContents := @PlayerPointContents;
    FPlayer.OnLandSound := @PlayerLanded;
    FPlayer.OnTrace := @PlayerTrace;
    FPlayer.OnBeforeMove := @PlayerBeforeMove;
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
  LStart, LStop: TVector3;
begin
  { Into the brush model's own coordinates (CM_TransformedBoxTrace): the
    scene is placed relative to the entity origin (BaseOffset) by its
    transform; a rotated model keeps the box axis-aligned, like Quake 2 }
  if not M.TryInverse(Inv) then
    Exit(BoxTraceAgainstBox(Stop, Stop, TVector3.Zero, TVector3.Zero, Vector3(1, 1, 1), Vector3(0, 0, 0), 0));
  LStart := CgeToQuake(Inv.MultPoint(QuakeToCge(Start)) + Mover.BaseOffset);
  LStop := CgeToQuake(Inv.MultPoint(QuakeToCge(Stop)) + Mover.BaseOffset);
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
  Mover: TQuakeMover;
  Monster: TQuakeMonster;
  Lo, Hi, A, B, Org: TVector3;
  Box: TBox3D;
  T: TQuakeTrace;

  function Overlaps(const BMins, BMaxs: TVector3): Boolean;
  begin
    Result := not ((BMins.X > Hi.X) or (BMaxs.X < Lo.X) or (BMins.Y > Hi.Y) or
      (BMaxs.Y < Lo.Y) or (BMins.Z > Hi.Z) or (BMaxs.Z < Lo.Z));
  end;

begin
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
      if (not Mover.Transform.Exists) or (Mover.ModelIndex <= 0) or (Mover.ModelIndex >= FBsp.ModelCount) then
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
  if (Mask and CONTENTS_MONSTER) = 0 then
    Exit;
  { Live monsters are boxes (corpses don't block, SVF_DEADMONSTER) }
  for Monster in FMonsters do
  begin
    if (Monster = Ignore) or (not Monster.IsAlive) or Monster.Dormant or (Monster.Transform = nil) or
       (not Monster.Transform.Exists) then
      Continue;
    Org := Monster.Origin;
    if not Overlaps(Org + Monster.BoxMins, Org + Monster.ShotBoxMaxs) then
      Continue;
    T := BoxTraceAgainstBox(Start, Stop, Mins, Maxs, Org + Monster.BoxMins, Org + Monster.ShotBoxMaxs,
      CONTENTS_MONSTER);
    if T.Hit then
    begin
      T.Ent := Monster;
      CombineTrace(Result, T);
      if Result.AllSolid then
        Exit;
    end;
  end;
  { The player's box (for monsters and their shots) }
  if (FPlayer <> nil) and (Ignore <> FPlayer) and (not FDead) and (FPlayer.Parent <> nil) then
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
var
  Mover: TQuakeMover;
  M, Old, OldInv: TMatrix4;
  Org, Mins, Maxs, OldCge, NewCge: TVector3;
  Riding, Inside: Boolean;
  Damage: Integer;
begin
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
  begin
    M := Mover.Transform.Transform;
    if FMoverPoses.TryGetValue(Mover, Old) and not TMatrix4.PerfectlyEquals(M, Old) and
       Mover.Transform.Exists and (FPlayer <> nil) and Assigned(FPlayer.OnTrace) and (not FDead) and
       (FPlayer.Parent <> nil) and Old.TryInverse(OldInv) then
    begin
      Org := FPlayer.Origin;
      Mins := FPlayer.BoxMins;
      Maxs := FPlayer.BoxMaxs;
      Riding := FPlayer.GroundObject = Mover;
      { Pushed: the mover moved into him (he was clear of its old pose) }
      Inside := (not Riding) and MoverTrace(Mover, Org, Org, Mins, Maxs, MASK_PLAYERSOLID).StartSolid and
        not MoverTraceAt(Mover, Old, Org, Org, Mins, Maxs, MASK_PLAYERSOLID).StartSolid;
      if Riding or Inside then
      begin
        { Move the player like a point fixed to the mover }
        OldCge := QuakeToCge(Org);
        NewCge := M.MultPoint(OldInv.MultPoint(OldCge));
        { Quake 2 SV_Push: keep the pushed position if it is free, else the
          old one if that is free; else the pusher is blocked (hurts him,
          doors / plats go back) }
        if not PlayerTrace(CgeToQuake(NewCge), CgeToQuake(NewCge), Mins, Maxs, MASK_PLAYERSOLID).StartSolid then
          FPlayer.Push(NewCge - OldCge)
        else
        if PlayerTrace(Org, Org, Mins, Maxs, MASK_PLAYERSOLID).StartSolid then
        begin
          Damage := Mover.Blocked;
          if Damage > 0 then
            DamagePlayer(Damage, Mover.Center);
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

  { Drowning: 12 seconds of air, then 2 damage per second, increasing }
  if Level < 3 then
    FAirFinished := FTime + 12
  else
  if FTime > FAirFinished then
  begin
    FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
    if FLiquidDamageTimer <= 0 then
    begin
      FLiquidDamageTimer := 1;
      DamagePlayer(Min(15, 2 + 2 * Trunc(FTime - FAirFinished)), FPlayerPos);
    end;
  end;

  { Lava: 30 per second per water level; slime: 10 (no enviro suit here) }
  if (Level > 0) and ((WType and (CONTENTS_LAVA or CONTENTS_SLIME)) <> 0) then
  begin
    FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
    if FLiquidDamageTimer <= 0 then
    begin
      FLiquidDamageTimer := 0.1;
      if (WType and CONTENTS_LAVA) <> 0 then
        DamagePlayer(3 * Level, FPlayerPos)
      else
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
begin
  FStats.WeaponMask := ((1 shl (WeaponSlots + 1)) - 1) and not 1; { slots 1..WeaponSlots }
  for A := atShells to atSlugs do
    FStats.Ammo[A] := FStats.MaxAmmo[A];
  FStats.ArmorType := 3;
  FStats.Armor := 200;
  FStats.Health := Max(FStats.Health, 100);
  FStats.Keys := $1FF;
  if FHud <> nil then
    FHud.ShowMessage('All weapons, ammo, armor and keys');
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
