{ The server end of E.1 / E.2: owns the simulation (TQuakeWorld) and a
  client per connection (TServerClient: its loopback channel, pmove, world
  player, command sequence and snapshots). It runs each client's commands
  (usercmd_t moves through its pmove, string commands) with the world acting
  on that client's player, and sends every client a snapshot every tick:
  its player state and the entity_state_t of the entities it can see (the
  other players too), delta coded against the last snapshot that client
  acknowledged (SV_BuildClientFrame, SV_WriteFrameToClient). Client 0 is
  this program's view. }
unit QuakeServer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, CastleVectors, CastleTransform,
  QuakeNet, QuakeWorld, QuakePMove;

type
  { One connection }
  TServerClient = class
  public
    Channel: TNetLoopback;
    { The world's player of this client and its pmove (owned) }
    Player: TQuakePlayer;
    PM: TQuakePMove;
    { This program's view (the world's local player) }
    Local: Boolean;
    LastCmd: TNetUserCmd;
    { The last snapshot the client said it has (-1 none), the last command
      run and the one after which the player was placed by code }
    Ack, LastSequence, PlacedSequence: Integer;
    { Placed since the last snapshot; map data and models still to send }
    PlayerChanged, SendServerData: Boolean;
    ModelsSent: Integer;
    Frames: array[0..UpdateBackup - 1] of TNetFrame;
    Commands, StringCommands, LastBytes, LastDelta: Integer;
    constructor Create(const AChannel: TNetLoopback);
    destructor Destroy; override;
    procedure ResetFrames;
  end;
  TServerClientList = specialize TObjectList<TServerClient>;

  TQuakeServer = class
  strict private
    type
      TNetSlot = record
        Number, ModelIndex, SeenFrame: Integer;
      end;
    var
      FWorld: TQuakeWorld;
      FMsg: TNetMessage;
      FFrameNum: Integer;
      FClients: TServerClientList;
      FLocal: TServerClient;
      FMapName: String;
      { Model table (configstrings CS_MODELS + i): index - 1 -> path }
      FModels: TStringList;
      FModelIndex: specialize TDictionary<String, Integer>;
      { Entity numbers: the object behind each entity sent }
      FSlots: specialize TDictionary<TObject, TNetSlot>;
      FUsed: array[0..MaxNetEntities - 1] of Boolean;
      FNextNumber: Integer;
      FHideModels: Boolean;
      FPlayerModel: String;
    function ModelIndexOf(const Path: String): Integer;
    function NumberOf(const Obj: TObject; const ModelIndex: Integer): Integer;
    procedure BuildFrame(const C: TServerClient; out F: TNetFrame);
    procedure SendFrameTo(const C: TServerClient);
    procedure FreeUnseenNumbers;
    procedure ExecuteMove(const C: TServerClient; const Cmd: TNetUserCmd; const Sequence: Integer);
    procedure UpdateEye(const C: TServerClient);
    procedure ExecuteString(const C: TServerClient; const S: String);
    procedure SpawnCommand(const C: TServerClient; const Args: String);
    procedure HurtCommand(const Args: String);
    procedure MoveMonsterCommand(const Args: String);
    procedure ReadClient(const C: TServerClient);
    function PlayerModelPath: String;
    function GetPM: TQuakePMove;
    function GetPlayerChanged: Boolean;
    function GetPlayerPos: TVector3;
    function GetPlayerDir: TVector3;
    function GetCommands: Integer;
    function GetStringCommands: Integer;
    function GetLastBytes: Integer;
    function GetLastDelta: Integer;
    function GetClient(const Index: Integer): TServerClient;
    function GetClientCount: Integer;
  public
    constructor Create(const AWorld: TQuakeWorld; const AChannel: TNetLoopback);
    destructor Destroy; override;
    { Another client on Channel (not owned): a player of its own in the
      world, at a spawn point }
    function AddClient(const Channel: TNetLoopback): TServerClient;
    procedure RemoveClient(const C: TServerClient);
    { A map was loaded: entity numbers, models and snapshots start again
      (svc_serverdata tells the clients); the other players respawn }
    procedure NewMap(const MapName: String);
    { The local player was put here by code (Quake origin; Dir in our
      coordinates): spawn, teleport, loaded game (Reset: standing still), or
      the view moved the camera (demo actions, console: velocity kept) }
    procedure PlacePlayer(const QuakeOrigin, Dir: TVector3; const Reset: Boolean);
    { Apply what the clients sent }
    procedure ReadPackets;
    { Text for a client's console (svc_print) or the middle of its screen
      (svc_centerprint); nil: the local client }
    procedure Print(const Text: String; const Center: Boolean = False; C: TServerClient = nil);
    { svc_print to every client (gi.bprintf: deathmatch obituaries) }
    procedure BroadcastPrint(const Text: String);
    { One game tick with the players' last known views }
    procedure RunTick(const Seconds: Single);
    { Send this tick's snapshot to every client }
    procedure SendFrame;
    { The snapshot sent last to the local client (to check its copy) }
    function LastFrame: TNetFrame;
    { The local client's }
    property PM: TQuakePMove read GetPM;
    property PlayerChanged: Boolean read GetPlayerChanged;
    property PlayerPos: TVector3 read GetPlayerPos;
    property PlayerDir: TVector3 read GetPlayerDir;
    property Commands: Integer read GetCommands;
    property StringCommands: Integer read GetStringCommands;
    { Size of the last snapshot message and the frame it was delta coded
      from (-1 = full) }
    property LastBytes: Integer read GetLastBytes;
    property LastDelta: Integer read GetLastDelta;
    property FrameNum: Integer read FFrameNum;
    property Clients[const Index: Integer]: TServerClient read GetClient;
    property ClientCount: Integer read GetClientCount;
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

{ TServerClient --------------------------------------------------------------- }

constructor TServerClient.Create(const AChannel: TNetLoopback);
begin
  inherited Create;
  Channel := AChannel;
  PM := TQuakePMove.Create;
  Ack := -1;
  SendServerData := True;
end;

destructor TServerClient.Destroy;
begin
  FreeAndNil(PM);
  inherited Destroy;
end;

procedure TServerClient.ResetFrames;
var
  I: Integer;
begin
  { Frame numbers go on, so an old acknowledgement finds no snapshot and
    the next one is sent in full }
  for I := 0 to UpdateBackup - 1 do
    Frames[I] := Default(TNetFrame);
  Ack := -1;
  ModelsSent := 0;
  SendServerData := True;
end;

{ TQuakeServer ---------------------------------------------------------------- }

constructor TQuakeServer.Create(const AWorld: TQuakeWorld; const AChannel: TNetLoopback);
begin
  inherited Create;
  FWorld := AWorld;
  FMsg := TNetMessage.Create;
  FModels := TStringList.Create;
  FModelIndex := specialize TDictionary<String, Integer>.Create;
  FSlots := specialize TDictionary<TObject, TNetSlot>.Create;
  FClients := TServerClientList.Create(True);
  FNextNumber := MaxNetClients + 1;
  FLocal := TServerClient.Create(AChannel);
  FLocal.Local := True;
  FLocal.Player := FWorld.Players[0];
  FLocal.Player.Dir := Vector3(1, 0, 0);
  FClients.Add(FLocal);
  FWorld.OnBroadcast := @BroadcastPrint;
end;

destructor TQuakeServer.Destroy;
begin
  if FWorld <> nil then
    FWorld.OnBroadcast := nil;
  FClients.Free;
  FSlots.Free;
  FModelIndex.Free;
  FModels.Free;
  FMsg.Free;
  inherited Destroy;
end;

function TQuakeServer.GetPM: TQuakePMove;
begin
  Result := FLocal.PM;
end;

function TQuakeServer.GetPlayerChanged: Boolean;
begin
  Result := FLocal.PlayerChanged;
end;

function TQuakeServer.GetPlayerPos: TVector3;
begin
  Result := FLocal.Player.Pos;
end;

function TQuakeServer.GetPlayerDir: TVector3;
begin
  Result := FLocal.Player.Dir;
end;

function TQuakeServer.GetCommands: Integer;
begin
  Result := FLocal.Commands;
end;

function TQuakeServer.GetStringCommands: Integer;
begin
  Result := FLocal.StringCommands;
end;

function TQuakeServer.GetLastBytes: Integer;
begin
  Result := FLocal.LastBytes;
end;

function TQuakeServer.GetLastDelta: Integer;
begin
  Result := FLocal.LastDelta;
end;

function TQuakeServer.GetClient(const Index: Integer): TServerClient;
begin
  Result := FClients[Index];
end;

function TQuakeServer.GetClientCount: Integer;
begin
  Result := FClients.Count;
end;

function TQuakeServer.AddClient(const Channel: TNetLoopback): TServerClient;
begin
  if FClients.Count >= MaxNetClients then
    Exit(nil);
  Result := TServerClient.Create(Channel);
  Result.PM.CopyParams(FLocal.PM);
  FClients.Add(Result);
  Result.Player := FWorld.AddPlayer(Result.PM);
  UpdateEye(Result);
end;

procedure TQuakeServer.RemoveClient(const C: TServerClient);
begin
  if (C = nil) or C.Local then
    Exit;
  FWorld.RemovePlayer(C.Player);
  C.Player := nil;
  FClients.Remove(C);
end;

procedure TQuakeServer.NewMap(const MapName: String);
var
  C: TServerClient;
begin
  FMapName := MapName;
  FModels.Clear;
  FModelIndex.Clear;
  FSlots.Clear;
  FillChar(FUsed, SizeOf(FUsed), 0);
  FNextNumber := MaxNetClients + 1;
  for C in FClients do
  begin
    C.ResetFrames;
    if not C.Local then
    begin
      FWorld.SelectPlayer(C.Player);
      FWorld.RespawnCurrent;
      FWorld.SelectPlayer(FLocal.Player);
    end;
  end;
end;

procedure TQuakeServer.UpdateEye(const C: TServerClient);
begin
  C.Player.Pos := QuakeToCge(C.PM.Origin + Vector3(0, 0, C.PM.ViewHeight));
end;

procedure TQuakeServer.PlacePlayer(const QuakeOrigin, Dir: TVector3; const Reset: Boolean);
begin
  FLocal.PM.Origin := QuakeOrigin;
  if Reset then
    FLocal.PM.ResetState;
  if not Dir.IsZero then
    FLocal.Player.Dir := Dir.Normalize;
  UpdateEye(FLocal);
  FLocal.PlacedSequence := FLocal.LastSequence;
  FLocal.PlayerChanged := True;
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
end;

function TQuakeServer.PlayerModelPath: String;
begin
  { The demo has no player model: a soldier stands in for the others }
  if FPlayerModel = '' then
  begin
    if Md2Manager.GetModel('players/male/tris.md2') <> nil then
      FPlayerModel := 'players/male/tris.md2'
    else
      FPlayerModel := 'models/monsters/soldier/tris.md2';
  end;
  Result := FPlayerModel;
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

procedure TQuakeServer.BuildFrame(const C: TServerClient; out F: TNetFrame);
var
  Count: Integer;

  procedure Append(const S: TNetEntityState);
  begin
    if Count = Length(F.Entities) then
      SetLength(F.Entities, 2 * Count + 32);
    F.Entities[Count] := S;
    Inc(Count);
  end;

  { What this client can see: the local one the PVS of the view (as
    SV_BuildClientFrame), the others everything for now }
  function Visible(const Box: TBox3D): Boolean;
  begin
    Result := (not C.Local) or FWorld.Geometry.BoxVisible(Box);
  end;

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
    if not Visible(Box) then
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
    Append(S);
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

  { The other players (entity numbers 1 .. MaxNetClients) }
  procedure AddPlayers;
  var
    P: TQuakePlayer;
    S: TNetEntityState;
    Org: TVector3;
  begin
    for P in FWorld.Players do
    begin
      if (P = C.Player) or P.Dead or (P.PM = nil) then
        Continue;
      Org := P.PM.Origin;
      if not Visible(Box3DAroundPoint(QuakeToCge(Org), 32)) then
        Continue;
      S := NullEntityState(P.Number);
      S.ModelIndex := ModelIndexOf(PlayerModelPath);
      S.Origin := Org;
      S.Angles := Vector3(0, QuantizeAngle(RadToDeg(ArcTan2(-P.Dir.Z, P.Dir.X))), 0);
      S.Scale := 1;
      Append(S);
    end;
  end;

var
  Mover: TQuakeMover;
  Monster: TQuakeMonster;
  Pickup: TQuakePickup;
  Prop: TQuakeProp;
  Proj: TQuakeProjectile;
  Stats: TQuakePlayerStats;
  Ammo: TAmmoType;
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
    AddPlayers;
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

  { player_state_t }
  Stats := C.Player.Stats;
  F.Player.PmType := NetPmNormal;
  if C.Player.Dead then
  begin
    if C.Player.Gibbed then
      F.Player.PmType := NetPmGib
    else
      F.Player.PmType := NetPmDead;
  end;
  PMoveToNet(C.PM, F.Player);
  F.Player.CommandAck := C.LastSequence;
  { Placed after the last command: the client's prediction for it is moot }
  if C.PlacedSequence = C.LastSequence then
    F.Player.PmFlags := F.Player.PmFlags or PmfTeleport;
  Angles := Vector3(-RadToDeg(ArcSin(EnsureRange(C.Player.Dir.Y, -1, 1))),
    RadToDeg(ArcTan2(-C.Player.Dir.Z, C.Player.Dir.X)), 0);
  F.Player.ViewAngles := Vector3(QuantizeAngle(Angles.X), QuantizeAngle(Angles.Y), 0);
  if C.Local and (FWorld.WeaponModel <> nil) and (FWorld.WeaponModel.Model <> nil) then
    F.Player.GunIndex := ModelIndexOf(FWorld.WeaponModel.Model.ModelPath);
  F.Player.GunFrame := Max(0, C.Player.Gun.Frame);
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
  F.Player.Stats[StatFrags] := ClampShort(C.Player.Frags);
end;

procedure TQuakeServer.FreeUnseenNumbers;
var
  Gone: specialize TList<TObject>;
  Pair: specialize TPair<TObject, TNetSlot>;
  I: Integer;
begin
  { Numbers of entities no client saw this frame are free again }
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
end;

procedure TQuakeServer.ExecuteMove(const C: TServerClient; const Cmd: TNetUserCmd; const Sequence: Integer);
begin
  Inc(C.Commands);
  C.LastCmd := Cmd;
  C.LastSequence := Sequence;
  C.Player.Dir := NetAnglesToDir(ShortToAngle(Cmd.Angles[0]), ShortToAngle(Cmd.Angles[1])).Normalize;
  { ClientThink's Pmove: movers push the player first (PlayerBeforeMove) }
  if (Cmd.Msec > 0) and not C.Player.Dead then
  begin
    if Assigned(C.PM.OnBeforeMove) then
      C.PM.OnBeforeMove(C.PM);
    C.PM.Move(UserCmdToPMoveInput(Cmd));
  end;
  UpdateEye(C);
  { Held fire is sent in every command (ClientThink latches BUTTON_ATTACK) }
  if (Cmd.Buttons and NetButtonAttack) <> 0 then
    FWorld.FireWeapon(C.Player.Pos, C.Player.Dir);
end;

procedure TQuakeServer.Print(const Text: String; const Center: Boolean; C: TServerClient);
var
  Msg: TNetMessage;
begin
  if C = nil then
    C := FLocal;
  Msg := TNetMessage.Create;
  try
    if Center then
      Msg.WriteByte(SvcCenterPrint)
    else
      Msg.WriteByte(SvcPrint);
    Msg.WriteString(Text);
    C.Channel.SendToClient(Msg);
  finally
    Msg.Free;
  end;
end;

procedure TQuakeServer.BroadcastPrint(const Text: String);
var
  C: TServerClient;
begin
  for C in FClients do
    Print(Text, False, C);
end;

procedure TQuakeServer.SpawnCommand(const C: TServerClient; const Args: String);
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
      Print('Usage: spawn <classname> [key value]...  e.g. spawn target_earthquake targetname q count 2', False, C);
      Exit;
    end;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Words[0]);
    { 96 units in front of the player, at the origin's height (24 above the
      feet), unless "origin" is given }
    Org := CgeToQuake(C.Player.Pos) +
      CgeToQuake(Vector3(C.Player.Dir.X, 0, C.Player.Dir.Z).Normalize * 96);
    Org.Z := C.PM.Origin.Z;
    Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
    I := 1;
    while I + 1 < Words.Count do
    begin
      Ent.SetField(Words[I], Words[I + 1]);
      Inc(I, 2);
    end;
    FWorld.Bsp.Entities.Add(Ent);
    FWorld.SpawnEntity(Ent);
    Print(Format('Spawned %s at %s', [Ent.ClassName, Ent.GetField('origin')]), False, C);
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

procedure TQuakeServer.ExecuteString(const C: TServerClient; const S: String);
var
  Cmd, Args: String;
  P, Slot: Integer;
begin
  Inc(C.StringCommands);
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
    FWorld.ActivateUse(C.Player.Pos, C.Player.Dir)
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
      Print('Unknown item: ' + Args, False, C);
  end else
  if Cmd = 'powerarmor' then
    FWorld.TogglePowerArmor
  else
  if Cmd = 'notarget' then
  begin
    NoTarget := not NoTarget;
    Print('notarget ' + Iff(NoTarget, 'ON', 'OFF'), True, C);
  end else
  if Cmd = 'noclip' then
    C.PM.Noclip := Args <> '0'
  else
  if Cmd = 'kill' then
    FWorld.Suicide
  else
  if Cmd = 'spawn' then
    SpawnCommand(C, Args)
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
    Print('Unknown command: ' + Cmd, False, C);
  end;
end;

procedure TQuakeServer.ReadClient(const C: TServerClient);
var
  Data: TBytes;
  Msg: TNetMessage;
  Cmd: Byte;
  Sequence: Integer;
begin
  while C.Channel.ReceiveOnServer(Data) do
  begin
    Msg := TNetMessage.CreateFrom(Data);
    try
      while not Msg.AtEnd do
      begin
        Cmd := Msg.ReadByte;
        case Cmd of
          ClcMove:
            begin
              C.Ack := Msg.ReadLong;
              Sequence := Msg.ReadLong;
              ExecuteMove(C, ReadDeltaUserCmd(Msg, C.LastCmd), Sequence);
            end;
          ClcStringCmd:
            ExecuteString(C, Msg.ReadString);
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

procedure TQuakeServer.ReadPackets;
var
  C: TServerClient;
begin
  for C in FClients do
  begin
    { The world acts on this client's player while running its commands }
    FWorld.SelectPlayer(C.Player);
    try
      ReadClient(C);
    finally
      FWorld.SelectPlayer(FLocal.Player);
    end;
  end;
end;

procedure TQuakeServer.RunTick(const Seconds: Single);
begin
  FWorld.Update(Seconds);
end;

procedure TQuakeServer.SendFrameTo(const C: TServerClient);
var
  F: TNetFrame;
  Base: TNetFrame;
  I: Integer;
begin
  BuildFrame(C, F);
  Base := Default(TNetFrame);
  F.DeltaFrame := -1;
  if (C.Ack > 0) and (FFrameNum - C.Ack < UpdateBackup) and C.Frames[C.Ack and UpdateMask].Valid and
     (C.Frames[C.Ack and UpdateMask].ServerFrame = C.Ack) then
  begin
    Base := C.Frames[C.Ack and UpdateMask];
    F.DeltaFrame := C.Ack;
  end;
  C.PlayerChanged := False;
  FMsg.Clear;
  if C.SendServerData then
  begin
    FMsg.WriteByte(SvcServerData);
    FMsg.WriteString(FMapName);
    C.SendServerData := False;
  end;
  { The models this client doesn't know yet }
  for I := C.ModelsSent + 1 to FModels.Count do
  begin
    FMsg.WriteByte(SvcConfigString);
    FMsg.WriteWord(I);
    FMsg.WriteString(FModels[I - 1]);
  end;
  C.ModelsSent := FModels.Count;
  FMsg.WriteByte(SvcFrame);
  FMsg.WriteLong(F.ServerFrame);
  FMsg.WriteLong(F.DeltaFrame);
  FMsg.WriteByte(SvcPlayerInfo);
  WriteDeltaPlayerState(FMsg, Base.Player, F.Player);
  FMsg.WriteByte(SvcPacketEntities);
  WritePacketEntities(FMsg, Base.Entities, F.Entities);
  C.Channel.SendToClient(FMsg);
  C.LastBytes := FMsg.Size;
  C.LastDelta := F.DeltaFrame;
  C.Frames[FFrameNum and UpdateMask] := F;
end;

procedure TQuakeServer.SendFrame;
var
  C: TServerClient;
begin
  Inc(FFrameNum);
  for C in FClients do
    SendFrameTo(C);
  FreeUnseenNumbers;
end;

function TQuakeServer.LastFrame: TNetFrame;
begin
  Result := FLocal.Frames[FFrameNum and UpdateMask];
end;

end.
