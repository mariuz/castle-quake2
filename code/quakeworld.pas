{ Quake 2 gameplay simulation: weapons, inventory, armor, combat, monster
  attacks, pickups, target/trigger chains, movers and level transitions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson, jsonparser,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleBoxes,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeMap, QuakeMd2, QuakePlayer, QuakeLight, QuakeSound, QuakeHud,
  QuakeParticles, QuakeEntities;

const
  { Quake 2 player: eye 22 above origin, origin 24 above the feet }
  PlayerEyeHeight = 46.0;

type
  TDelayedTarget = record
    Time: Single;
    Target: String;
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
    FTimers: specialize TDictionary<TQuakeEntity, Single>; { func_timer -> next fire time (<0: off) }
    FDelayed: specialize TList<TDelayedTarget>;
    FCounters: specialize TDictionary<TQuakeEntity, Integer>;
    FStats: TQuakePlayerStats;
    FHud: TQuakeHud;
    FPlayerPos: TVector3;
    FPlayerDir: TVector3;
    FTime: Single;
    FWeaponTransform: TCastleTransform;
    FWeaponModel: TQuakeMd2Instance;
    FWeaponModelSlot: Integer;
    FWeaponCooldown: Single;
    FWeaponKick: Single;
    { Fire was held during the previous frame (FireWeapon is called every
      frame while held; Update looks at it to detect the release) }
    FFireHeld: Boolean;
    { Chaingun: seconds of continuous fire (more bullets per shot when spun up) }
    FChainSpin: Single;
    { Hand grenade cooking: fuse time left while the pin is pulled }
    FGrenadeCooking: Boolean;
    FGrenadeFuse: Single;
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
    procedure PlayWeaponAnim(const Names: String; const Loop: Boolean);
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
    procedure ThrowHandGrenade(const Origin, Dir: TVector3);
    procedure UpdateHeldFire(const SecondsPassed: Single);
    procedure SpawnProjectile(const Kind: TProjectileKind; const Origin, Dir: TVector3;
      const Speed: Single; const Damage: Integer; const FromPlayer: Boolean;
      const Owner: TQuakeMonster = nil);
    procedure UpdateProjectiles(const SecondsPassed: Single);
    { Rockets, blaster bolts and BFG balls light their surroundings }
    procedure AddProjectileLights;
    { Send the dynamic lights nearest to the player to the world shader }
    procedure SetSurfaceLights;
    procedure Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
      const FromPlayer: Boolean);
    function MonsterByTransform(const T: TCastleTransform): TQuakeMonster;
    function MoverByTransform(const T: TCastleTransform): TQuakeMover;
    procedure UseEntity(const Ent: TQuakeEntity);
    function TimerInterval(const Ent: TQuakeEntity): Single;
    function EntityMoveDir(const Ent: TQuakeEntity): TVector3;
    { A transform at the entity origin, for positional one-shot sounds }
    function FPlayerTransformFor(const Ent: TQuakeEntity): TCastleTransform;
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
    property Pickups: TQuakePickupList read FPickups;
    property Props: TQuakePropList read FProps;
    property Lasers: TQuakeLaserList read FLasers;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Geometry: TQuakeGeometry read FGeometry;
    property Bsp: TQuakeBsp read FBsp;
  end;

implementation

const
  SPAWNFLAG_NOT_MEDIUM = 512;
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
  FPickups := TQuakePickupList.Create(True);
  FMonsters := TQuakeMonsterList.Create(True);
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
  ClearLevel;
  FreeAndNil(FWeaponModel);
  FreeAndNil(FWeaponTransform);
  FPickups.Free;
  FMonsters.Free;
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
  FPickups.Clear;
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
    PlayWeaponAnim('active,idle', False); { v_handgr has no 'active' }
  end;
end;

procedure TQuakeWorld.PlayWeaponAnim(const Names: String; const Loop: Boolean);
begin
  if FWeaponModel <> nil then
    FWeaponModel.PlayAnim(Names, Loop, 10);
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

    { Medium skill, single player }
    if (SpawnFlags and SPAWNFLAG_NOT_MEDIUM) <> 0 then
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
  UpdateWeaponModel;
  PlayWeaponAnim('active', False);

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
      Sounds.Play(P.Def^.Sound);
      if FHud <> nil then
        FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
      { Picked items can fire targets too }
      UseTargets(P.Entity.Target);
    end;
  end;
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
      Sounds.PlayAt('sound/world/spark' + IntToStr(5 + Random(3)) + '.wav', FPlayerTransformFor(Ent));
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
    UseTargets(Ent.Target)
  else
  if Copy(CName, 1, 8) = 'monster_' then
  begin
    for M in FMonsters do
      if M.Entity = Ent then
        M.Alert;
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

function TQuakeWorld.FPlayerTransformFor(const Ent: TQuakeEntity): TCastleTransform;
var
  Speaker: TQuakeSpeaker;
begin
  { Reuse any speaker transform close to the entity, else play at the map root }
  for Speaker in FSpeakers do
    if PointsDistance(Speaker.Transform.Translation, QuakeToCge(Ent.Origin)) < 64 then
      Exit(Speaker.Transform);
  Result := FMap;
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
    Hit := FItems.WorldRayCast(Start, ShotDir, Dist);
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

procedure TQuakeWorld.ThrowHandGrenade(const Origin, Dir: TVector3);
const
  { Quake 2 weapon_grenade_fire: speed grows with the time the pin was pulled }
  GrenadeTimer = 3.0;
  MinSpeed = 400;
  MaxSpeed = 800;
var
  Held: Single;
begin
  FGrenadeCooking := False;
  Held := GrenadeTimer - FGrenadeFuse;
  SpawnProjectile(pkHandGrenade, Origin + Dir * 16, (Dir + Vector3(0, 0.1, 0)).Normalize,
    MinSpeed + Held * (MaxSpeed - MinSpeed) / GrenadeTimer, 125 * DamageMultiplier, True);
  FProjectiles.Last.Life := Max(0.1, FGrenadeFuse);
  Sounds.Play('sound/weapons/hgrent1a.wav');
  PlayWeaponAnim('throw', False);
  FWeaponCooldown := WeaponDefs[11].Cooldown;
end;

procedure TQuakeWorld.UpdateHeldFire(const SecondsPassed: Single);
begin
  { Released the trigger: spin the chaingun down, throw a cooked grenade }
  if not FFireHeld then
  begin
    if FChainSpin > 0 then
    begin
      if FChainSpin > 0.5 then
        Sounds.Play('sound/weapons/chngnd1a.wav');
      FChainSpin := 0;
      PlayWeaponAnim('idle', True);
    end;
    if FGrenadeCooking then
      ThrowHandGrenade(FPlayerPos, FPlayerDir);
  end;
  FFireHeld := False;

  if FGrenadeCooking then
  begin
    FGrenadeFuse := FGrenadeFuse - SecondsPassed;
    if FGrenadeFuse <= 0 then
    begin
      { Held too long: it goes off in the hand }
      FGrenadeCooking := False;
      FWeaponCooldown := WeaponDefs[11].Cooldown;
      Explode(FPlayerPos + FPlayerDir * 16, 125 * DamageMultiplier, 165, True);
    end;
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

procedure TQuakeWorld.Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
  const FromPlayer: Boolean);
var
  M: TQuakeMonster;
  Mover: TQuakeMover;
  Prop: TQuakeProp;
  Dist: Single;
  Points: Integer;
begin
  Particles.SpawnExplosion(Pos);
  Sounds.Play('sound/weapons/rocklx1a.wav');
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

    Hit := FItems.WorldRayCast(OldPos, Dir, Dist);
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
              Sounds.Play('sound/weapons/bfg__x1b.wav');
              Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius * 0.3, Proj.FromPlayer);
            end;
          else
            begin
              Particles.SpawnBlasterImpact(NewPos, -Dir);
              Sounds.PlayAt('sound/weapons/lashit.wav', Proj.Transform);
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
  Eye := Monster.EyePos;
  Target := FPlayerPos - Vector3(0, 12, 0);
  Dir := (Target - Eye).Normalize;
  Dist := PointsDistance(Eye, Target);
  if Monster.Def^.Attack <> akMelee then
    Lighting.TriggerMuzzleFlash(Eye);

  case Monster.Def^.Attack of
    akMelee:
      if Dist < Monster.Def^.AttackRange + 24 then
        DamagePlayer(Monster.Def^.Damage, Eye);
    akHitscan, akPellets, akRail:
      if Monster.CanSeePlayer then
      begin
        { Accuracy falls off with distance }
        Accuracy := EnsureRange(1.1 - Dist / 1200, 0.25, 0.95);
        if Monster.Def^.Attack = akPellets then
        begin
          Hits := 0;
          for I := 1 to 9 do
            if Random < Accuracy * 0.8 then
              Inc(Hits);
          if Hits > 0 then
            DamagePlayer(Hits * Monster.Def^.Damage, Eye);
        end else
        if Monster.Def^.Attack = akRail then
        begin
          Particles.SpawnRailTrail(Eye, Target);
          Sounds.PlayAt('sound/weapons/railgf1a.wav', Monster.Transform);
          if Random < Accuracy then
            DamagePlayer(Monster.Def^.Damage, Eye);
        end else
        begin
          for I := 1 to 4 do
            if Random < Accuracy * 0.6 then
              DamagePlayer(Monster.Def^.Damage, Eye);
          Particles.SpawnImpact(Target + Vector3((Random - 0.5) * 40, (Random - 0.5) * 30,
            (Random - 0.5) * 40), -Dir);
        end;
      end;
    akBlaster:
      SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, 600, Monster.Def^.Damage * 3, False, Monster);
    akRocket:
      SpawnProjectile(pkRocket, Eye + Dir * 24, Dir, 500, Monster.Def^.Damage, False, Monster);
    akGrenade:
      SpawnProjectile(pkGrenade, Eye + Dir * 24, (Dir + Vector3(0, 0.35, 0)).Normalize,
        Min(600, Dist * 1.1), Monster.Def^.Damage, False, Monster);
  end;
end;

procedure TQuakeWorld.DamagePlayer(const Amount: Integer; const FromPos: TVector3);
var
  Save, Take: Integer;
begin
  if FDead or FStats.GodMode or (FStats.InvulnTime > 0) or (Amount <= 0) then
    Exit;
  Take := Amount;
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

  if FStats.Health <= 0 then
  begin
    KillPlayer;
    Exit;
  end;

  if FPainSoundTimer <= 0 then
  begin
    FPainSoundTimer := 0.7;
    if FStats.Health < 25 then
      Sounds.Play('sound/player/male/pain25_1.wav')
    else
    if FStats.Health < 50 then
      Sounds.Play('sound/player/male/pain50_1.wav')
    else
    if FStats.Health < 75 then
      Sounds.Play('sound/player/male/pain75_1.wav')
    else
      Sounds.Play('sound/player/male/pain100_1.wav');
  end;
end;

procedure TQuakeWorld.KillPlayer;
begin
  FDead := True;
  FDeadTimer := 3.0;
  FStats.Health := Min(FStats.Health, 0);
  Sounds.Play('sound/player/male/death' + IntToStr(1 + Random(4)) + '.wav');
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
  FGeometry.ScenePlayerClip.Collides := True;

  UpdateTimersAndLasers(SecondsPassed);
  UpdateLiquids(SecondsPassed);
  UpdateHeldFire(SecondsPassed);
  UpdateProjectiles(SecondsPassed);
  AddProjectileLights;
  Particles.Update(SecondsPassed);
  Lighting.Update(SecondsPassed);
  SetSurfaceLights;

  { View weapon: animation, kick and lighting }
  if FWeaponCooldown > 0 then
    FWeaponCooldown := FWeaponCooldown - SecondsPassed;
  FWeaponKick := Max(0, FWeaponKick - SecondsPassed * 6);
  if FWeaponModel <> nil then
  begin
    FWeaponModel.Update(SecondsPassed);
    if FWeaponModel.AnimDone then
      PlayWeaponAnim('idle', True);
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
  if (Slot = FStats.CurrentWeapon) or FGrenadeCooking then
    Exit;
  FChainSpin := 0;
  FStats.CurrentWeapon := Slot;
  UpdateWeaponModel;
  FWeaponCooldown := 0.3;
end;

procedure TQuakeWorld.FireWeapon(const Origin, Dir: TVector3);
var
  Def: TQuakeWeaponDef;
  I, Mult, Shots: Integer;
  MuzzlePos: TVector3;
begin
  FFireHeld := True;
  if (FBsp = nil) or FDead or (FWeaponCooldown > 0) or FGrenadeCooking then
    Exit;
  Def := WeaponDefs[FStats.CurrentWeapon];
  if (Def.AmmoType <> atNone) and (FStats.Ammo[Def.AmmoType] < Def.AmmoPerShot) then
  begin
    Sounds.Play('sound/weapons/noammo.wav');
    FWeaponCooldown := 0.5;
    if FHud <> nil then
      FHud.ShowMessage('No ammo for ' + Def.Name, 1.5);
    Exit;
  end;
  if Def.AmmoType <> atNone then
    Dec(FStats.Ammo[Def.AmmoType], Def.AmmoPerShot);

  { Hand grenades: pull the pin now, throw when fire is released }
  if FStats.CurrentWeapon = 11 then
  begin
    FGrenadeCooking := True;
    FGrenadeFuse := 3.0;
    Sounds.Play('sound/weapons/hgrena1b.wav');
    PlayWeaponAnim('throw', False);
    Exit;
  end;

  FWeaponCooldown := Def.Cooldown;
  FWeaponKick := 1.0;
  Mult := DamageMultiplier;
  MuzzlePos := Origin + Dir * 16;
  Lighting.TriggerMuzzleFlash(MuzzlePos);
  if FStats.CurrentWeapon in [4, 5] then
    Sounds.Play(Format('sound/weapons/machgf%db.wav', [1 + Random(5)]))
  else
    Sounds.Play(Def.Sound);
  if Mult > 1 then
    Sounds.Play('sound/items/damage3.wav');
  if FStats.CurrentWeapon = 5 then
    PlayWeaponAnim('pow', True)
  else
    PlayWeaponAnim('fire,shoot,attack', False);

  { Firing makes noise: wake up monsters nearby }
  for I := 0 to FMonsters.Count - 1 do
    if PointsDistance(FMonsters[I].Transform.Translation, Origin) < 800 then
      FMonsters[I].Alert;

  case FStats.CurrentWeapon of
    1: SpawnProjectile(pkBlasterBolt, MuzzlePos, Dir, 1000, 15 * Mult, True);
    2: for I := 1 to 12 do
         FireHitscan(Origin, Dir, 4 * Mult, 500, 500);
    3: for I := 1 to 20 do
         FireHitscan(Origin, Dir, 6 * Mult, 1000, 500);
    4: FireHitscan(Origin, Dir, 8 * Mult, 300, 500);
    5:
      begin
        { Quake 2 Chaingun_Fire: 1, then 2, then 3 bullets per frame as it spins up }
        if FChainSpin = 0 then
          Sounds.Play('sound/weapons/chngnu1a.wav');
        if FChainSpin < 0.5 then
          Shots := 1
        else
        if FChainSpin < 1.0 then
          Shots := 2
        else
          Shots := 3;
        Shots := Min(Shots, FStats.Ammo[atBullets] + 1); { one was already taken }
        Dec(FStats.Ammo[atBullets], Shots - 1);
        for I := 1 to Shots do
          FireHitscan(Origin, Dir, 6 * Mult, 300, 500);
        FChainSpin := FChainSpin + Def.Cooldown;
      end;
    6: SpawnProjectile(pkGrenade, MuzzlePos, (Dir + Vector3(0, 0.15, 0)).Normalize, 600, 120 * Mult, True);
    7: SpawnProjectile(pkRocket, MuzzlePos, Dir, 650, 100 * Mult, True);
    8: SpawnProjectile(pkBlasterBolt, MuzzlePos, Dir, 1000, 15 * Mult, True);
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
    FStats.CurrentWeapon := 1;
    SelectWeapon(O.Get('weapon', 1));
    FWeaponCooldown := 0;
  end;

  Arr := Obj.Get('monsters', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FMonsters.Count) - 1 do
    begin
      O := Arr.Objects[I];
      FMonsters[I].RestoreState(JsonToVec(O.Find('pos')), O.Get('facing', 0.0),
        O.Get('health', 0), TMonsterState(O.Get('state', 0)),
        O.Get('alerted', False), O.Get('gibbed', False));
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

  { Pending events from before a save are not restored. When revisiting a
    level, keep the ones scheduled at spawn: Quake 2's ReadLevel re-arms
    target_crosslevel_target the same way. }
  if IncludePlayer then
    FDelayed.Clear;
  FProjectiles.Clear;
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
      Sounds.Play('sound/player/lava_in.wav')
    else
      Sounds.Play('sound/player/watr_in.wav');
  end else
  if (FLastWaterLevel > 0) and (Level = 0) then
    Sounds.Play('sound/player/watr_out.wav')
  else
  if (FLastWaterLevel < 3) and (Level = 3) then
    Sounds.Play('sound/player/watr_un.wav');
  if (FLastWaterLevel = 3) and (Level < 3) and (FAirFinished < FTime + 7) then
    Sounds.Play('sound/player/gasp1.wav');

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
    Sounds.Play('sound/player/male/fall1.wav')
  else
    Sounds.Play('sound/player/male/fall2.wav');
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
