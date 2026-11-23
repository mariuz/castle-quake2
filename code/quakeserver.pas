{ The server end of E.1: owns the simulation (TQuakeWorld) and the
  player's pmove (PM, the world's Player), runs the client's commands
  (usercmd_t moves through pmove, string commands) and sends a snapshot
  every tick: the player state and the entity_state_t of every entity in the
  player's PVS, delta coded against the last snapshot the client
  acknowledged (SV_BuildClientFrame, SV_WriteFrameToClient). }
unit QuakeServer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, CastleVectors, CastleTransform,
  QuakeNet, QuakeWorld, QuakePMove;

type
  TQuakeServer = class
  strict private
    type
      TNetSlot = record
        Number, ModelIndex, SeenFrame: Integer;
      end;
    var
      FWorld: TQuakeWorld;
      FChannel: TNetLoopback;
      FMsg: TNetMessage;
      FFrameNum: Integer;
      { The last snapshot the client said it has (-1 none) }
      FAck: Integer;
      FFrames: array[0..UpdateBackup - 1] of TNetFrame;
      FLastCmd: TNetUserCmd;
      { The player's movement, the last command run and the one after which
        the player was placed by code (teleport flag) }
      FPM: TQuakePMove;
      FLastSequence, FPlacedSequence: Integer;
      FPlayerChanged: Boolean;
      { The player's eye and view (our coordinates) }
      FPlayerPos, FPlayerDir: TVector3;
      FMapName: String;
      FSendServerData: Boolean;
      { Model table (configstrings CS_MODELS + i): index - 1 -> path }
      FModels: TStringList;
      FModelIndex: specialize TDictionary<String, Integer>;
      FNewModels: specialize TList<Integer>;
      { Entity numbers: the object behind each entity sent }
      FSlots: specialize TDictionary<TObject, TNetSlot>;
      FUsed: array[0..MaxNetEntities - 1] of Boolean;
      FNextNumber: Integer;
      FCommands, FStringCommands: Integer;
      FLastBytes, FLastDelta: Integer;
      FHideModels: Boolean;
    function ModelIndexOf(const Path: String): Integer;
    function NumberOf(const Obj: TObject; const ModelIndex: Integer): Integer;
    procedure BuildFrame(out F: TNetFrame);
    procedure ExecuteMove(const Cmd: TNetUserCmd; const Sequence: Integer);
    procedure UpdateEye;
    procedure ExecuteString(const S: String);
    procedure SpawnCommand(const Args: String);
    procedure HurtCommand(const Args: String);
    procedure MoveMonsterCommand(const Args: String);
  public
    constructor Create(const AWorld: TQuakeWorld; const AChannel: TNetLoopback);
    destructor Destroy; override;
    { A map was loaded: entity numbers, models and snapshots start again
      (svc_serverdata tells the client) }
    procedure NewMap(const MapName: String);
    { The player was put here by code (Quake origin; Dir in our coordinates):
      spawn, teleport, loaded game (Reset: standing still), or the view
      moved the camera (demo actions, console: velocity kept) }
    procedure PlacePlayer(const QuakeOrigin, Dir: TVector3; const Reset: Boolean);
    { Apply what the client sent }
    procedure ReadPackets;
    { Text for the client's console (svc_print) or the middle of its screen
      (svc_centerprint) }
    procedure Print(const Text: String; const Center: Boolean = False);
    { One game tick with the player's last known view }
    procedure RunTick(const Seconds: Single);
    { Send this tick's snapshot }
    procedure SendFrame;
    { The snapshot sent last (to check the client's copy in one process) }
    function LastFrame: TNetFrame;
    property PM: TQuakePMove read FPM;
    { Placed since the last snapshot: send one before the client predicts }
    property PlayerChanged: Boolean read FPlayerChanged;
    property PlayerPos: TVector3 read FPlayerPos;
    property PlayerDir: TVector3 read FPlayerDir;
    property FrameNum: Integer read FFrameNum;
    property Commands: Integer read FCommands;
    property StringCommands: Integer read FStringCommands;
    { Size of the last snapshot message and the frame it was delta coded
      from (-1 = full) }
    property LastBytes: Integer read FLastBytes;
    property LastDelta: Integer read FLastDelta;
    { The client draws the models from the snapshots: the server's own md2
      scenes are hidden (they still simulate and collide) }
    property HideModels: Boolean read FHideModels write FHideModels;
  end;

{ The view direction of usercmd angles (pitch down positive, yaw; our
  coordinates) }
function NetAnglesToDir(const PitchDeg, YawDeg: Single): TVector3;

implementation

uses
  Math, CastleLog, CastleBoxes, CastleUtils, QuakeLight, QuakeEntities, QuakeGeometry, QuakeMd2,
  QuakeHud, QuakeBsp;

function NetAnglesToDir(const PitchDeg, YawDeg: Single): TVector3;
begin
  Result := YawToCgeDir(YawDeg) * Cos(DegToRad(PitchDeg)) +
    Vector3(0, -Sin(DegToRad(PitchDeg)), 0);
end;

function ClampShort(const V: Int64): SmallInt;
begin
  Result := EnsureRange(V, Low(SmallInt), High(SmallInt));
end;

function ShellRenderFx(const Shell: TVector3): Cardinal;
begin
  Result := 0;
  if Shell.X > 0 then
    Result := Result or NetRfShellRed;
  if Shell.Y > 0 then
    Result := Result or NetRfShellGreen;
  if Shell.Z > 0 then
    Result := Result or NetRfShellBlue;
end;

function ProjectileEffects(const Kind: TProjectileKind): Cardinal;
begin
  case Kind of
    pkBlasterBolt, pkBlueBolt: Result := NetEfBlaster;
    pkRocket, pkHeatRocket: Result := NetEfRocket;
    pkGrenade, pkHandGrenade: Result := NetEfGrenade;
    pkBfg: Result := NetEfBfg;
    else Result := 0;
  end;
end;

constructor TQuakeServer.Create(const AWorld: TQuakeWorld; const AChannel: TNetLoopback);
begin
  inherited Create;
  FWorld := AWorld;
  FChannel := AChannel;
  FMsg := TNetMessage.Create;
  FModels := TStringList.Create;
  FModelIndex := specialize TDictionary<String, Integer>.Create;
  FNewModels := specialize TList<Integer>.Create;
  FSlots := specialize TDictionary<TObject, TNetSlot>.Create;
  FAck := -1;
  FNextNumber := MaxNetClients + 1;
  FPlayerDir := Vector3(1, 0, 0);
  FPM := TQuakePMove.Create;
end;

destructor TQuakeServer.Destroy;
begin
  FPM.Free;
  FSlots.Free;
  FNewModels.Free;
  FModelIndex.Free;
  FModels.Free;
  FMsg.Free;
  inherited Destroy;
end;

procedure TQuakeServer.NewMap(const MapName: String);
var
  I: Integer;
begin
  FMapName := MapName;
  FSendServerData := True;
  FModels.Clear;
  FModelIndex.Clear;
  FNewModels.Clear;
  FSlots.Clear;
  FillChar(FUsed, SizeOf(FUsed), 0);
  FNextNumber := MaxNetClients + 1;
  { Frame numbers go on, so an old acknowledgement finds no snapshot and
    the next one is sent in full }
  for I := 0 to UpdateBackup - 1 do
    FFrames[I] := Default(TNetFrame);
  FAck := -1;
end;

procedure TQuakeServer.UpdateEye;
begin
  FPlayerPos := QuakeToCge(FPM.Origin + Vector3(0, 0, FPM.ViewHeight));
end;

procedure TQuakeServer.PlacePlayer(const QuakeOrigin, Dir: TVector3; const Reset: Boolean);
begin
  FPM.Origin := QuakeOrigin;
  if Reset then
    FPM.ResetState;
  if not Dir.IsZero then
    FPlayerDir := Dir.Normalize;
  UpdateEye;
  FPlacedSequence := FLastSequence;
  FPlayerChanged := True;
end;

function TQuakeServer.ModelIndexOf(const Path: String): Integer;
begin
  if Path = '' then
    Exit(0);
  if FModelIndex.TryGetValue(Path, Result) then
    Exit;
  if FModels.Count >= MaxNetModels - 1 then
    Exit(0);
  FModels.Add(Path);
  Result := FModels.Count;
  FModelIndex.Add(Path, Result);
  FNewModels.Add(Result);
end;

function TQuakeServer.NumberOf(const Obj: TObject; const ModelIndex: Integer): Integer;
var
  Slot: TNetSlot;
  I: Integer;
begin
  if FSlots.TryGetValue(Obj, Slot) then
  begin
    { Another entity freed and allocated at the same address gets a new
      number when its model differs }
    if Slot.ModelIndex = ModelIndex then
    begin
      Slot.SeenFrame := FFrameNum;
      FSlots[Obj] := Slot;
      Exit(Slot.Number);
    end;
    FUsed[Slot.Number] := False;
    FSlots.Remove(Obj);
  end;
  { Like G_Spawn, don't hand a freed number out again at once: go on from
    the last one given }
  for I := 0 to MaxNetEntities - 1 do
  begin
    Result := FNextNumber;
    Inc(FNextNumber);
    if FNextNumber >= MaxNetEntities then
      FNextNumber := MaxNetClients + 1;
    if not FUsed[Result] then
    begin
      FUsed[Result] := True;
      Slot.Number := Result;
      Slot.ModelIndex := ModelIndex;
      Slot.SeenFrame := FFrameNum;
      FSlots.Add(Obj, Slot);
      Exit;
    end;
  end;
  Result := 0;
end;

procedure TQuakeServer.BuildFrame(out F: TNetFrame);
var
  Count: Integer;

  { Pose: the transform whose world matrix places the model (the model
    scene itself: offsets, the ceiling stalker's roll, MODEL_SCALE) }
  procedure Add(const Obj: TObject; const T, Pose: TCastleTransform; const Box: TBox3D;
    const ModelPath, ModelPath2: String; const Frame, Skin: Integer;
    const Effects, RenderFx: Cardinal; const OldFrame: Integer = -1; const Lerp: Single = 1);
  var
    S: TNetEntityState;
    ModelIndex: Integer;
    M: TMatrix4;
  begin
    if (T = nil) or not T.Exists then
      Exit;
    { Only what the player's PVS reaches (SV_BuildClientFrame) }
    if not FWorld.Geometry.BoxVisible(Box) then
      Exit;
    ModelIndex := ModelIndexOf(ModelPath);
    if ModelIndex = 0 then
      Exit;
    S := NullEntityState(NumberOf(Obj, ModelIndex));
    if S.Number = 0 then
      Exit;
    S.ModelIndex := ModelIndex;
    S.ModelIndex2 := ModelIndexOf(ModelPath2);
    S.Frame := Max(0, Frame);
    if OldFrame >= 0 then
      S.OldFrame := OldFrame
    else
      S.OldFrame := S.Frame;
    S.Lerp := EnsureRange(Round(Lerp * 255), 0, 255);
    S.Skin := Max(0, Skin);
    S.Effects := Effects;
    S.RenderFx := RenderFx;
    M := Pose.WorldTransform;
    S.Origin := CgeToQuake(M.MultPoint(TVector3.Zero));
    S.Angles := MatrixToQuakeAngles(M, S.Scale);
    S.Angles := Vector3(QuantizeAngle(S.Angles.X), QuantizeAngle(S.Angles.Y),
      QuantizeAngle(S.Angles.Z));
    if Count = Length(F.Entities) then
      SetLength(F.Entities, 2 * Count + 32);
    F.Entities[Count] := S;
    Inc(Count);
  end;

  function BoxOf(const T: TCastleTransform): TBox3D;
  begin
    Result := T.BoundingBox;
    if Result.IsEmpty then
      Result := Box3DAroundPoint(T.Translation, 16);
  end;

  procedure AddModel(const Obj: TObject; const T: TCastleTransform; const Model: TQuakeMd2Instance;
    const Effects: Cardinal; const ExtraRenderFx: Cardinal = 0);
  var
    Path2: String;
  begin
    if (Model = nil) or (T = nil) then
      Exit;
    Model.Scene.Visible := not FHideModels;
    Path2 := '';
    if (Model.Follower <> nil) and (Model.Follower.Model <> nil) then
    begin
      Path2 := Model.Follower.Model.ModelPath;
      Model.Follower.Scene.Visible := not FHideModels;
    end;
    Add(Obj, T, Model.Scene, BoxOf(T), Model.Model.ModelPath, Path2, Model.ShownFrame, Model.SkinIndex,
      Effects, ShellRenderFx(Model.ShellColor) or ExtraRenderFx, Model.ShownOldFrame, Model.ShownLerp);
  end;

var
  Mover: TQuakeMover;
  Monster: TQuakeMonster;
  Pickup: TQuakePickup;
  Prop: TQuakeProp;
  Proj: TQuakeProjectile;
  Stats: TQuakePlayerStats;
  Ammo: TAmmoType;
  Gone: specialize TList<TObject>;
  Pair: specialize TPair<TObject, TNetSlot>;
  Angles: TVector3;
  I, J: Integer;
  Tmp: TNetEntityState;
begin
  F := Default(TNetFrame);
  F.Valid := True;
  F.ServerFrame := FFrameNum;
  Count := 0;
  if (FWorld.Bsp <> nil) and (FWorld.Geometry <> nil) then
  begin
    for Mover in FWorld.Geometry.Movers do
      if Mover.ModelIndex > 0 then
        Add(Mover, Mover.Transform, Mover.Transform, Mover.WorldBox, '*' + IntToStr(Mover.ModelIndex), '',
          0, 0, 0, 0);
    for Monster in FWorld.Monsters do
      if not Monster.Dormant then
        AddModel(Monster, Monster.Transform, Monster.Model, 0,
          Iff(IRGogglesOn and Monster.IsAlive, NetRfIrVisible, 0));
    for Pickup in FWorld.Pickups do
      if not Pickup.Collected then
        AddModel(Pickup, Pickup.Transform, Pickup.Model, NetEfRotate);
    for Prop in FWorld.Props do
      AddModel(Prop, Prop.Transform, Prop.Model, 0);
    for Proj in FWorld.Projectiles do
      if Proj.Model <> nil then
        AddModel(Proj, Proj.Transform, Proj.Model, ProjectileEffects(Proj.Kind))
      else
      if (Proj.Sprite <> nil) and (Proj.Transform <> nil) then
        Add(Proj, Proj.Transform, Proj.Transform, BoxOf(Proj.Transform), Proj.Sprite.Sprite.Path, '', 0, 0,
          ProjectileEffects(Proj.Kind), 0);
  end;
  SetLength(F.Entities, Count);
  { Sorted by number for the delta merge (insertion sort: mostly in order) }
  for I := 1 to Count - 1 do
  begin
    Tmp := F.Entities[I];
    J := I - 1;
    while (J >= 0) and (F.Entities[J].Number > Tmp.Number) do
    begin
      F.Entities[J + 1] := F.Entities[J];
      Dec(J);
    end;
    F.Entities[J + 1] := Tmp;
  end;

  { Numbers of entities not seen this frame are free again }
  Gone := specialize TList<TObject>.Create;
  try
    for Pair in FSlots do
      if Pair.Value.SeenFrame <> FFrameNum then
        Gone.Add(Pair.Key);
    for I := 0 to Gone.Count - 1 do
    begin
      FUsed[FSlots[Gone[I]].Number] := False;
      FSlots.Remove(Gone[I]);
    end;
  finally
    Gone.Free;
  end;

  { player_state_t }
  Stats := FWorld.Stats;
  F.Player.PmType := NetPmNormal;
  if FWorld.Dead then
  begin
    if FWorld.PlayerGibbed then
      F.Player.PmType := NetPmGib
    else
      F.Player.PmType := NetPmDead;
  end;
  PMoveToNet(FPM, F.Player);
  F.Player.CommandAck := FLastSequence;
  { Placed after the last command: the client's prediction for it is moot }
  if FPlacedSequence = FLastSequence then
    F.Player.PmFlags := F.Player.PmFlags or PmfTeleport;
  Angles := Vector3(-RadToDeg(ArcSin(EnsureRange(FPlayerDir.Y, -1, 1))),
    RadToDeg(ArcTan2(-FPlayerDir.Z, FPlayerDir.X)), 0);
  F.Player.ViewAngles := Vector3(QuantizeAngle(Angles.X), QuantizeAngle(Angles.Y), 0);
  if (FWorld.WeaponModel <> nil) and (FWorld.WeaponModel.Model <> nil) then
    F.Player.GunIndex := ModelIndexOf(FWorld.WeaponModel.Model.ModelPath);
  F.Player.GunFrame := Max(0, FWorld.Gun.Frame);
  F.Player.Stats[StatHealth] := ClampShort(Stats.Health);
  F.Player.Stats[StatArmor] := ClampShort(Stats.Armor);
  F.Player.Stats[StatArmorType] := ClampShort(Stats.ArmorType);
  F.Player.Stats[StatAmmo] := -1;
  if (Stats.CurrentWeapon >= Low(WeaponDefs)) and (Stats.CurrentWeapon <= High(WeaponDefs)) then
  begin
    Ammo := WeaponDefs[Stats.CurrentWeapon].AmmoType;
    if Ammo <> atNone then
      F.Player.Stats[StatAmmo] := ClampShort(Stats.Ammo[Ammo]);
  end;
  F.Player.Stats[StatWeapon] := ClampShort(Stats.CurrentWeapon);
  F.Player.Stats[StatWeaponsLow] := SmallInt(Stats.WeaponMask and $FFFF);
  F.Player.Stats[StatWeaponsHigh] := SmallInt(Stats.WeaponMask shr 16);
  F.Player.Stats[StatKeysLow] := SmallInt(Stats.Keys and $FFFF);
  F.Player.Stats[StatKeysHigh] := SmallInt(Stats.Keys shr 16);
  F.Player.Stats[StatKills] := ClampShort(Stats.Kills);
  F.Player.Stats[StatTotalKills] := ClampShort(Stats.TotalKills);
  F.Player.Stats[StatSecrets] := ClampShort(Stats.Secrets);
  F.Player.Stats[StatTotalSecrets] := ClampShort(Stats.TotalSecrets);
  F.Player.Stats[StatGoals] := ClampShort(Stats.Goals);
  F.Player.Stats[StatTotalGoals] := ClampShort(Stats.TotalGoals);
  F.Player.Stats[StatQuad] := ClampShort(Ceil(Stats.QuadTime * 10));
  F.Player.Stats[StatInvulnerable] := ClampShort(Ceil(Stats.InvulnTime * 10));
  F.Player.Stats[StatLevelSeconds] := ClampShort(Trunc(Stats.LevelTime));
end;

procedure TQuakeServer.ExecuteMove(const Cmd: TNetUserCmd; const Sequence: Integer);
begin
  Inc(FCommands);
  FLastCmd := Cmd;
  FLastSequence := Sequence;
  FPlayerDir := NetAnglesToDir(ShortToAngle(Cmd.Angles[0]), ShortToAngle(Cmd.Angles[1])).Normalize;
  { ClientThink's Pmove: movers push the player first (PlayerBeforeMove) }
  if (Cmd.Msec > 0) and not FWorld.Dead then
  begin
    if Assigned(FPM.OnBeforeMove) then
      FPM.OnBeforeMove(FPM);
    FPM.Move(UserCmdToPMoveInput(Cmd));
  end;
  UpdateEye;
  { Held fire is sent in every command (ClientThink latches BUTTON_ATTACK) }
  if (Cmd.Buttons and NetButtonAttack) <> 0 then
    FWorld.FireWeapon(FPlayerPos, FPlayerDir);
end;

procedure TQuakeServer.Print(const Text: String; const Center: Boolean);
var
  Msg: TNetMessage;
begin
  Msg := TNetMessage.Create;
  try
    if Center then
      Msg.WriteByte(SvcCenterPrint)
    else
      Msg.WriteByte(SvcPrint);
    Msg.WriteString(Text);
    FChannel.SendToClient(Msg);
  finally
    Msg.Free;
  end;
end;

procedure TQuakeServer.SpawnCommand(const Args: String);
var
  Words: TStringList;
  Ent: TQuakeEntity;
  I: Integer;
  Org: TVector3;
begin
  Words := SplitArgs(Args);
  try
    if (Words.Count = 0) or (FWorld.Bsp = nil) then
    begin
      Print('Usage: spawn <classname> [key value]...  e.g. spawn target_earthquake targetname q count 2');
      Exit;
    end;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Words[0]);
    { 96 units in front of the player, at the origin's height (24 above the
      feet), unless "origin" is given }
    Org := CgeToQuake(FPlayerPos) +
      CgeToQuake(Vector3(FPlayerDir.X, 0, FPlayerDir.Z).Normalize * 96);
    Org.Z := FPM.Origin.Z;
    Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
    I := 1;
    while I + 1 < Words.Count do
    begin
      Ent.SetField(Words[I], Words[I + 1]);
      Inc(I, 2);
    end;
    FWorld.Bsp.Entities.Add(Ent);
    FWorld.SpawnEntity(Ent);
    Print(Format('Spawned %s at %s', [Ent.ClassName, Ent.GetField('origin')]));
    WritelnLog('Console', 'Spawned %s at %s', [Ent.ClassName, Ent.GetField('origin')]);
  finally
    Words.Free;
  end;
end;

procedure TQuakeServer.HurtCommand(const Args: String);
var
  Words: TStringList;
  I: Integer;
begin
  { hurt <monster index | last> <damage>: damage one monster (tests: boss
    deaths; "last" is the one spawned last) }
  Words := SplitArgs(Args);
  try
    if (Words.Count >= 1) and SameText(Words[0], 'last') then
      Words[0] := IntToStr(FWorld.Monsters.Count - 1);
    I := -1;
    if Words.Count >= 2 then
      I := StrToIntDef(Words[0], -1);
    if (I >= 0) and (I < FWorld.Monsters.Count) then
    begin
      FWorld.Monsters[I].TakeDamage(StrToIntDef(Words[1], 0));
      WritelnLog('Console', 'hurt %s by %s', [FWorld.Monsters[I].Transform.Name, Words[1]]);
    end;
  finally
    Words.Free;
  end;
end;

procedure TQuakeServer.MoveMonsterCommand(const Args: String);
var
  Vals: TStringArray;
  J: Integer;
begin
  { mv <i> <x y z>: put monster i there (Quake coordinates; tests) }
  Vals := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Vals) < 4 then
    Exit;
  J := StrToIntDef(Vals[0], -1);
  if (J >= 0) and (J < FWorld.Monsters.Count) then
    FWorld.Monsters[J].Transform.Translation := QuakeToCge(Vector3(StrToFloatDef(Vals[1], 0),
      StrToFloatDef(Vals[2], 0), StrToFloatDef(Vals[3], 0)));
end;

procedure TQuakeServer.ExecuteString(const S: String);
var
  Cmd, Args: String;
  P, Slot: Integer;
begin
  Inc(FStringCommands);
  P := Pos(' ', S);
  if P > 0 then
  begin
    Cmd := LowerCase(Copy(S, 1, P - 1));
    Args := Trim(Copy(S, P + 1, MaxInt));
  end else
  begin
    Cmd := LowerCase(S);
    Args := '';
  end;
  { Before a map is loaded there is no world to act on }
  if FWorld.Bsp = nil then
    Exit;
  if Cmd = 'use' then
    FWorld.ActivateUse(FPlayerPos, FPlayerDir)
  else
  if (Cmd = 'weapon') and TryStrToInt(Args, Slot) then
    FWorld.SelectWeapon(Slot)
  else
  { Cheats and test commands (Quake 2's Cmd_*_f in g_cmds.c run on the
    server too) }
  if Cmd = 'god' then
    FWorld.CheatGodMode
  else
  if Cmd = 'give' then
  begin
    if Args = 'all' then
      FWorld.CheatGiveAll
    else
    if Args = 'quad' then
      FWorld.CheatPowerup(True)
    else
    if Args = 'invulnerability' then
      FWorld.CheatPowerup(False)
    else
    if not FWorld.CheatGiveItem(Args) then
      Print('Unknown item: ' + Args);
  end else
  if Cmd = 'powerarmor' then
    FWorld.TogglePowerArmor
  else
  if Cmd = 'notarget' then
  begin
    NoTarget := not NoTarget;
    Print('notarget ' + Iff(NoTarget, 'ON', 'OFF'), True);
  end else
  if Cmd = 'noclip' then
    FPM.Noclip := Args <> '0'
  else
  if Cmd = 'kill' then
    FWorld.Suicide
  else
  if Cmd = 'spawn' then
    SpawnCommand(Args)
  else
  if Cmd = 'hurt' then
    HurtCommand(Args)
  else
  if Cmd = 'fire' then
    { Fire entity targets, like a trigger would (demo action E) }
    FWorld.UseTargets(Args)
  else
  if Cmd = 'mv' then
    MoveMonsterCommand(Args)
  else
  begin
    WritelnWarning('QuakeServer', 'Unknown client command "%s"', [S]);
    Print('Unknown command: ' + Cmd);
  end;
end;

procedure TQuakeServer.ReadPackets;
var
  Data: TBytes;
  Msg: TNetMessage;
  Cmd: Byte;
  Sequence: Integer;
begin
  while FChannel.ReceiveOnServer(Data) do
  begin
    Msg := TNetMessage.CreateFrom(Data);
    try
      while not Msg.AtEnd do
      begin
        Cmd := Msg.ReadByte;
        case Cmd of
          ClcMove:
            begin
              FAck := Msg.ReadLong;
              Sequence := Msg.ReadLong;
              ExecuteMove(ReadDeltaUserCmd(Msg, FLastCmd), Sequence);
            end;
          ClcStringCmd:
            ExecuteString(Msg.ReadString);
          else
            begin
              WritelnWarning('QuakeServer', 'Bad client message %d', [Cmd]);
              Break;
            end;
        end;
        if Msg.BadRead then
        begin
          WritelnWarning('QuakeServer', 'Client message cut short');
          Break;
        end;
      end;
    finally
      Msg.Free;
    end;
  end;
end;

procedure TQuakeServer.RunTick(const Seconds: Single);
begin
  FWorld.Update(Seconds, FPlayerPos, FPlayerDir);
end;

procedure TQuakeServer.SendFrame;
var
  F: TNetFrame;
  Base: TNetFrame;
  I: Integer;
begin
  Inc(FFrameNum);
  BuildFrame(F);
  Base := Default(TNetFrame);
  F.DeltaFrame := -1;
  if (FAck > 0) and (FFrameNum - FAck < UpdateBackup) and FFrames[FAck and UpdateMask].Valid and
     (FFrames[FAck and UpdateMask].ServerFrame = FAck) then
  begin
    Base := FFrames[FAck and UpdateMask];
    F.DeltaFrame := FAck;
  end;
  FPlayerChanged := False;
  FMsg.Clear;
  if FSendServerData then
  begin
    FMsg.WriteByte(SvcServerData);
    FMsg.WriteString(FMapName);
    FSendServerData := False;
  end;
  for I := 0 to FNewModels.Count - 1 do
  begin
    FMsg.WriteByte(SvcConfigString);
    FMsg.WriteWord(FNewModels[I]);
    FMsg.WriteString(FModels[FNewModels[I] - 1]);
  end;
  FNewModels.Clear;
  FMsg.WriteByte(SvcFrame);
  FMsg.WriteLong(F.ServerFrame);
  FMsg.WriteLong(F.DeltaFrame);
  FMsg.WriteByte(SvcPlayerInfo);
  WriteDeltaPlayerState(FMsg, Base.Player, F.Player);
  FMsg.WriteByte(SvcPacketEntities);
  WritePacketEntities(FMsg, Base.Entities, F.Entities);
  FChannel.SendToClient(FMsg);
  FLastBytes := FMsg.Size;
  FLastDelta := F.DeltaFrame;
  FFrames[FFrameNum and UpdateMask] := F;
end;

function TQuakeServer.LastFrame: TNetFrame;
begin
  Result := FFrames[FFrameNum and UpdateMask];
end;

end.
