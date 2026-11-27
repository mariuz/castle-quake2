{ Client / server messages in Quake 2's shape (roadmap E.1): the client
  sends its inputs (usercmd_t), the server answers every tick with a
  snapshot of what the player can see (player_state_t and the
  entity_state_t of every entity in the PVS), delta coded against the last
  snapshot the client acknowledged, like SV_EmitPacketEntities /
  CL_ParsePacketEntities. Single player runs both ends in one process over
  TNetLoopback. The bytes are our own layout, not Quake 2's protocol 34:
  origins are floats and angles 16 bits. }
unit QuakeNet;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, CastleVectors, QuakePMove;

const
  { Server to client (Quake 2 svc_*) }
  SvcPrint = 10;
  SvcCenterPrint = 15;
  SvcServerData = 12;
  SvcConfigString = 13;
  SvcPlayerInfo = 17;
  SvcPacketEntities = 18;
  SvcFrame = 20;
  { Client to server (clc_*) }
  ClcMove = 2;
  ClcStringCmd = 4;

  { Snapshots both ends keep for delta coding (UPDATE_BACKUP) }
  UpdateBackup = 16;
  UpdateMask = UpdateBackup - 1;
  MaxNetEntities = 1024;
  { Entity numbers 1..MaxNetClients belong to players (edicts 1..maxclients) }
  MaxNetClients = 8;
  MaxNetStats = 32;
  MaxNetModels = 256;

  { usercmd_t buttons }
  NetButtonAttack = 1;
  NetButtonUse = 2;
  NetButtonAny = 128;
  { usercmd_t moves: -1..1 of the client's inputs times this (cl_forwardspeed
    with run) }
  NetMoveScale = 400;

  { entity_state_t effects (EF_*) and renderfx (RF_*) }
  NetEfRotate = 1;
  NetEfBlaster = 8;
  NetEfRocket = 16;
  NetEfGrenade = 32;
  NetEfHyperblaster = 64;
  NetEfBfg = 128;
  NetRfShellRed = 1024;
  NetRfShellGreen = 2048;
  NetRfShellBlue = 4096;
  NetRfShellDouble = $10000;
  { Full bright red through IR goggles (RF_IR_VISIBLE) }
  NetRfIrVisible = $8000;

  { pmove_state_t pm_flags }
  PmfDucked = 1;
  PmfJumpHeld = 2;
  PmfOnGround = 4;
  PmfNoclip = 8;
  { Placed by code after the last command (teleport, spawn): no prediction
    error to measure }
  PmfTeleport = 16;

  { player_state_t pm_type }
  NetPmNormal = 0;
  NetPmDead = 2;
  NetPmGib = 3;

  { player_state_t stats (STAT_*: our own list). Times in tenths of a
    second; StatAmmo is -1 for weapons without ammo. }
  StatHealth = 0;
  StatArmor = 1;
  StatArmorType = 2;
  StatAmmo = 3;
  StatWeapon = 4;
  StatWeaponsLow = 5;
  StatWeaponsHigh = 6;
  StatKeysLow = 7;
  StatKeysHigh = 8;
  StatKills = 9;
  StatTotalKills = 10;
  StatSecrets = 11;
  StatTotalSecrets = 12;
  StatGoals = 13;
  StatTotalGoals = 14;
  StatQuad = 15;
  StatInvulnerable = 16;
  StatLevelSeconds = 17;
  { Deathmatch score (Quake 2 STAT_FRAGS) }
  StatFrags = 18;

  { Entity delta bits }
  UOrigin1 = 1;
  UOrigin2 = 2;
  UOrigin3 = 4;
  UAngle1 = 8;
  UAngle2 = 16;
  UAngle3 = 32;
  UModel = 64;
  UModel2 = 128;
  UFrame = 256;
  USkin = 512;
  UEffects = 1024;
  URenderFx = 2048;
  UScale = 4096;
  UOldFrame = 8192;
  ULerp = 16384;
  URemove = $8000;

type
  TNetUserCmd = record
    Msec: Byte;
    Buttons: Byte;
    { Pitch, yaw, roll (ANGLE2SHORT) }
    Angles: array[0..2] of SmallInt;
    ForwardMove, SideMove, UpMove: SmallInt;
    Impulse: Byte;
  end;

  TNetEntityState = record
    Number: Integer;
    ModelIndex, ModelIndex2: Integer;
    { Shown as OldFrame blended towards Frame by Lerp / 255 (the server's
      models step 10 frames a second over 40 ticks) }
    Frame, OldFrame, Lerp: Integer;
    Skin: Integer;
    Effects, RenderFx: Cardinal;
    { Quake coordinates }
    Origin: TVector3;
    { Pitch, yaw, roll in degrees, as sent (QuantizeAngle) }
    Angles: TVector3;
    { The model's size (the remaster's scale; 0 = 1) }
    Scale: Single;
  end;
  TNetEntityStates = array of TNetEntityState;

  TNetPlayerState = record
    PmType: Byte;
    { pmove_state_t: origin and velocity (Quake coordinates), flags, the
      landing pause (seconds) and gravity: what the client predicts from }
    Origin, Velocity: TVector3;
    PmFlags: Byte;
    PmTime, Gravity: Single;
    { The last command the server ran (the client replays the later ones) }
    CommandAck: LongInt;
    ViewAngles: TVector3;
    GunIndex: Integer;
    GunFrame: Integer;
    Stats: array[0..MaxNetStats - 1] of SmallInt;
  end;

  { A snapshot: what the server sent for one of its frames }
  TNetFrame = record
    Valid: Boolean;
    ServerFrame: Integer;
    { The frame it was delta coded from, -1 = none (full) }
    DeltaFrame: Integer;
    Player: TNetPlayerState;
    { Sorted by Number }
    Entities: TNetEntityStates;
  end;

  { A message being written or read }
  TNetMessage = class
  strict private
    FData: TBytes;
    FSize, FReadPos: Integer;
    FBadRead: Boolean;
    procedure Reserve(const Count: Integer);
    function ReadRaw(const P: Pointer; const Count: Integer): Boolean;
    procedure WriteRaw(const P: Pointer; const Count: Integer);
  public
    constructor Create;
    constructor CreateFrom(const Bytes: TBytes);
    procedure Clear;
    procedure WriteByte(const B: Byte);
    procedure WriteShort(const S: SmallInt);
    procedure WriteWord(const W: Word);
    procedure WriteLong(const L: LongInt);
    procedure WriteFloat(const F: Single);
    procedure WriteVector(const V: TVector3);
    { Degrees in 16 bits (ANGLE2SHORT) }
    procedure WriteAngle16(const Deg: Single);
    procedure WriteString(const S: String);
    function ReadByte: Byte;
    function ReadShort: SmallInt;
    function ReadWord: Word;
    function ReadLong: LongInt;
    function ReadFloat: Single;
    function ReadVector: TVector3;
    function ReadAngle16: Single;
    function ReadString: String;
    function ToBytes: TBytes;
    function AtEnd: Boolean;
    property Size: Integer read FSize;
    { A read went past the end (the values read are 0) }
    property BadRead: Boolean read FBadRead;
  end;

  { Both directions of a connection inside one process (Quake 2's
    NET_SendLoopPacket), with byte counts }
  TNetLoopback = class
  strict private
    FToServer, FToClient: specialize TQueue<TBytes>;
  public
    BytesToServer, BytesToClient: Int64;
    PacketsToServer, PacketsToClient: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure SendToServer(const Msg: TNetMessage);
    procedure SendToClient(const Msg: TNetMessage);
    function ReceiveOnServer(out Data: TBytes): Boolean;
    function ReceiveOnClient(out Data: TBytes): Boolean;
    { A packet that came from elsewhere (QuakeNetLink's bridges): for the
      server end, or for the client end }
    procedure PushToServer(const Data: TBytes);
    procedure PushToClient(const Data: TBytes);
    procedure Clear;
  end;

{ Words of a command's arguments; "quoted words" may hold spaces }
function SplitArgs(const Args: String): TStringList;

function AngleToShort(const Deg: Single): SmallInt;
function ShortToAngle(const S: SmallInt): Single;
{ The angle as the other end reads it (-180 .. 180) }
function QuantizeAngle(const Deg: Single): Single;

function NullEntityState(const Number: Integer): TNetEntityState;
function EntityStatesEqual(const A, B: TNetEntityState): Boolean;
function PlayerStatesEqual(const A, B: TNetPlayerState): Boolean;
{ Same player state and entities (not the frame numbers) }
function FramesEqual(const A, B: TNetFrame): Boolean;

procedure WriteDeltaUserCmd(const Msg: TNetMessage; const From, Cmd: TNetUserCmd);
function ReadDeltaUserCmd(const Msg: TNetMessage; const From: TNetUserCmd): TNetUserCmd;

{ Nothing is written when To equals From, unless Force (a new entity) }
procedure WriteDeltaEntity(const Msg: TNetMessage; const From, ToState: TNetEntityState;
  const Force: Boolean);
procedure WritePacketEntities(const Msg: TNetMessage; const OldStates, NewStates: TNetEntityStates);
function ReadPacketEntities(const Msg: TNetMessage; const OldStates: TNetEntityStates;
  out NewStates: TNetEntityStates): Boolean;

procedure WriteDeltaPlayerState(const Msg: TNetMessage; const From, P: TNetPlayerState);
function ReadDeltaPlayerState(const Msg: TNetMessage; const From: TNetPlayerState): TNetPlayerState;

{ pmove's input for a command: what the server runs and the client
  replays, so both move the same (view direction from the 16-bit angles,
  moves of NetMoveScale steps, msec) }
function UserCmdToPMoveInput(const Cmd: TNetUserCmd): TPMoveInput;
{ A command for pmove's input (Msec given: the client keeps the remainder) }
function PMoveInputToUserCmd(const Input: TPMoveInput; const Msec: Byte): TNetUserCmd;
{ pmove_state_t of a pmove and back }
procedure PMoveToNet(const PM: TQuakePMove; var P: TNetPlayerState);
procedure NetToPMove(const P: TNetPlayerState; const PM: TQuakePMove);

{ Quake angles (pitch down positive, yaw, roll; degrees) of a transform
  rotation in our coordinates (a model at yaw Y has rotation Y around +Y),
  and back }
function RotationToQuakeAngles(const Rotation: TVector4): TVector3;
function QuakeAnglesToRotation(const Angles: TVector3): TVector4;
{ Quake angles of a world matrix (our coordinates) and its scale }
function MatrixToQuakeAngles(const M: TMatrix4; out Scale: Single): TVector3;

implementation

uses
  Math, CastleQuaternions;

{ TNetMessage ---------------------------------------------------------------- }

constructor TNetMessage.Create;
begin
  inherited Create;
  SetLength(FData, 256);
end;

constructor TNetMessage.CreateFrom(const Bytes: TBytes);
begin
  inherited Create;
  FData := Copy(Bytes);
  FSize := Length(FData);
end;

procedure TNetMessage.Clear;
begin
  FSize := 0;
  FReadPos := 0;
  FBadRead := False;
end;

procedure TNetMessage.Reserve(const Count: Integer);
begin
  if FSize + Count > Length(FData) then
    SetLength(FData, Max(FSize + Count, 2 * Length(FData) + 64));
end;

procedure TNetMessage.WriteRaw(const P: Pointer; const Count: Integer);
begin
  Reserve(Count);
  Move(P^, FData[FSize], Count);
  Inc(FSize, Count);
end;

function TNetMessage.ReadRaw(const P: Pointer; const Count: Integer): Boolean;
begin
  Result := FReadPos + Count <= FSize;
  if Result then
  begin
    Move(FData[FReadPos], P^, Count);
    Inc(FReadPos, Count);
  end else
  begin
    FillChar(P^, Count, 0);
    FReadPos := FSize;
    FBadRead := True;
  end;
end;

procedure TNetMessage.WriteByte(const B: Byte);
begin
  WriteRaw(@B, 1);
end;

procedure TNetMessage.WriteShort(const S: SmallInt);
var
  V: SmallInt;
begin
  V := NtoLE(S);
  WriteRaw(@V, 2);
end;

procedure TNetMessage.WriteWord(const W: Word);
var
  V: Word;
begin
  V := NtoLE(W);
  WriteRaw(@V, 2);
end;

procedure TNetMessage.WriteLong(const L: LongInt);
var
  V: LongInt;
begin
  V := NtoLE(L);
  WriteRaw(@V, 4);
end;

procedure TNetMessage.WriteFloat(const F: Single);
var
  V: LongWord;
begin
  V := NtoLE(PLongWord(@F)^);
  WriteRaw(@V, 4);
end;

procedure TNetMessage.WriteVector(const V: TVector3);
begin
  WriteFloat(V.X);
  WriteFloat(V.Y);
  WriteFloat(V.Z);
end;

procedure TNetMessage.WriteAngle16(const Deg: Single);
begin
  WriteShort(AngleToShort(Deg));
end;

procedure TNetMessage.WriteString(const S: String);
begin
  if S <> '' then
    WriteRaw(@S[1], Length(S));
  WriteByte(0);
end;

function TNetMessage.ReadByte: Byte;
begin
  ReadRaw(@Result, 1);
end;

function TNetMessage.ReadShort: SmallInt;
begin
  ReadRaw(@Result, 2);
  Result := LEtoN(Result);
end;

function TNetMessage.ReadWord: Word;
begin
  ReadRaw(@Result, 2);
  Result := LEtoN(Result);
end;

function TNetMessage.ReadLong: LongInt;
begin
  ReadRaw(@Result, 4);
  Result := LEtoN(Result);
end;

function TNetMessage.ReadFloat: Single;
var
  V: LongWord;
begin
  ReadRaw(@V, 4);
  V := LEtoN(V);
  Result := PSingle(@V)^;
end;

function TNetMessage.ReadVector: TVector3;
begin
  Result.X := ReadFloat;
  Result.Y := ReadFloat;
  Result.Z := ReadFloat;
end;

function TNetMessage.ReadAngle16: Single;
begin
  Result := ShortToAngle(ReadShort);
end;

function TNetMessage.ReadString: String;
var
  B: Byte;
begin
  Result := '';
  repeat
    B := ReadByte;
    if (B = 0) or FBadRead then
      Break;
    Result := Result + Chr(B);
  until False;
end;

function TNetMessage.ToBytes: TBytes;
begin
  Result := Copy(FData, 0, FSize);
end;

function TNetMessage.AtEnd: Boolean;
begin
  Result := FReadPos >= FSize;
end;

{ TNetLoopback --------------------------------------------------------------- }

constructor TNetLoopback.Create;
begin
  inherited Create;
  FToServer := specialize TQueue<TBytes>.Create;
  FToClient := specialize TQueue<TBytes>.Create;
end;

destructor TNetLoopback.Destroy;
begin
  FToServer.Free;
  FToClient.Free;
  inherited Destroy;
end;

procedure TNetLoopback.SendToServer(const Msg: TNetMessage);
begin
  FToServer.Enqueue(Msg.ToBytes);
  Inc(BytesToServer, Msg.Size);
  Inc(PacketsToServer);
end;

procedure TNetLoopback.SendToClient(const Msg: TNetMessage);
begin
  FToClient.Enqueue(Msg.ToBytes);
  Inc(BytesToClient, Msg.Size);
  Inc(PacketsToClient);
end;

procedure TNetLoopback.PushToServer(const Data: TBytes);
begin
  FToServer.Enqueue(Data);
  Inc(BytesToServer, Length(Data));
  Inc(PacketsToServer);
end;

procedure TNetLoopback.PushToClient(const Data: TBytes);
begin
  FToClient.Enqueue(Data);
  Inc(BytesToClient, Length(Data));
  Inc(PacketsToClient);
end;

function TNetLoopback.ReceiveOnServer(out Data: TBytes): Boolean;
begin
  Result := FToServer.Count > 0;
  if Result then
    Data := FToServer.Dequeue
  else
    Data := nil;
end;

function TNetLoopback.ReceiveOnClient(out Data: TBytes): Boolean;
begin
  Result := FToClient.Count > 0;
  if Result then
    Data := FToClient.Dequeue
  else
    Data := nil;
end;

procedure TNetLoopback.Clear;
begin
  FToServer.Clear;
  FToClient.Clear;
end;

function SplitArgs(const Args: String): TStringList;
var
  I: Integer;
  Word: String;
  Quoted, HasWord: Boolean;
begin
  Result := TStringList.Create;
  Word := '';
  Quoted := False;
  HasWord := False;
  for I := 1 to Length(Args) do
    if Args[I] = '"' then
    begin
      Quoted := not Quoted;
      HasWord := True;
    end else
    if (Args[I] = ' ') and not Quoted then
    begin
      if HasWord then
        Result.Add(Word);
      Word := '';
      HasWord := False;
    end else
    begin
      Word := Word + Args[I];
      HasWord := True;
    end;
  if HasWord then
    Result.Add(Word);
end;

{ Angles --------------------------------------------------------------------- }

function AngleToShort(const Deg: Single): SmallInt;
begin
  Result := SmallInt(Word(Round(Deg * 65536 / 360) and $FFFF));
end;

function ShortToAngle(const S: SmallInt): Single;
begin
  Result := S * (360 / 65536);
end;

function QuantizeAngle(const Deg: Single): Single;
begin
  Result := ShortToAngle(AngleToShort(Deg));
end;

{ Quake angles of a model whose forward (its +X) and up (+Y) point along F
  and U (unit length, our coordinates) }
function DirectionsToQuakeAngles(const F, U: TVector3): TVector3;
var
  U0, S0: TVector3;
  Yaw, Pitch: Single;
begin
  Yaw := ArcTan2(-F.Z, F.X);
  Pitch := -ArcSin(EnsureRange(F.Y, -1, 1));
  { The up and side vectors of the same yaw and pitch without roll }
  U0 := Vector3(Sin(Pitch) * Cos(Yaw), Cos(Pitch), -Sin(Pitch) * Sin(Yaw));
  S0 := Vector3(Sin(Yaw), 0, Cos(Yaw));
  Result := Vector3(RadToDeg(Pitch), RadToDeg(Yaw),
    RadToDeg(ArcTan2(TVector3.DotProduct(U, S0), TVector3.DotProduct(U, U0))));
end;

function RotationToQuakeAngles(const Rotation: TVector4): TVector3;
var
  Q: TQuaternion;
begin
  Q := QuatFromAxisAngle(Rotation, True);
  Result := DirectionsToQuakeAngles(Q.Rotate(Vector3(1, 0, 0)), Q.Rotate(Vector3(0, 1, 0)));
end;

function MatrixToQuakeAngles(const M: TMatrix4; out Scale: Single): TVector3;
var
  F, U: TVector3;
begin
  F := M.MultDirection(Vector3(1, 0, 0));
  U := M.MultDirection(Vector3(0, 1, 0));
  Scale := F.Length;
  if (Scale < 1e-6) or (U.Length < 1e-6) then
  begin
    Scale := 1;
    Exit(TVector3.Zero);
  end;
  Result := DirectionsToQuakeAngles(F / Scale, U.Normalize);
end;

function QuakeAnglesToRotation(const Angles: TVector3): TVector4;
var
  Q: TQuaternion;
begin
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), -DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Angles.Z));
  Result := Q.ToAxisAngle;
end;

{ States --------------------------------------------------------------------- }

function NullEntityState(const Number: Integer): TNetEntityState;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Number := Number;
end;

function EntityStatesEqual(const A, B: TNetEntityState): Boolean;
begin
  Result := (A.Number = B.Number) and (A.ModelIndex = B.ModelIndex) and
    (A.ModelIndex2 = B.ModelIndex2) and (A.Frame = B.Frame) and (A.OldFrame = B.OldFrame) and
    (A.Lerp = B.Lerp) and (A.Skin = B.Skin) and
    (A.Effects = B.Effects) and (A.RenderFx = B.RenderFx) and
TVector3.PerfectlyEquals(A.Origin, B.Origin) and TVector3.PerfectlyEquals(A.Angles, B.Angles) and
    (A.Scale = B.Scale);
end;

function PlayerStatesEqual(const A, B: TNetPlayerState): Boolean;
var
  I: Integer;
begin
  Result := (A.PmType = B.PmType) and TVector3.PerfectlyEquals(A.Origin, B.Origin) and
    TVector3.PerfectlyEquals(A.Velocity, B.Velocity) and (A.PmFlags = B.PmFlags) and
    (A.PmTime = B.PmTime) and (A.Gravity = B.Gravity) and (A.CommandAck = B.CommandAck) and
    TVector3.PerfectlyEquals(A.ViewAngles, B.ViewAngles) and (A.GunIndex = B.GunIndex) and (A.GunFrame = B.GunFrame);
  if Result then
    for I := 0 to MaxNetStats - 1 do
      if A.Stats[I] <> B.Stats[I] then
        Exit(False);
end;

function FramesEqual(const A, B: TNetFrame): Boolean;
var
  I: Integer;
begin
  Result := PlayerStatesEqual(A.Player, B.Player) and (Length(A.Entities) = Length(B.Entities));
  if Result then
    for I := 0 to High(A.Entities) do
      if not EntityStatesEqual(A.Entities[I], B.Entities[I]) then
        Exit(False);
end;

{ usercmd -------------------------------------------------------------------- }

const
  CmAngle1 = 1;
  CmAngle2 = 2;
  CmAngle3 = 4;
  CmForward = 8;
  CmSide = 16;
  CmUp = 32;
  CmButtons = 64;
  CmImpulse = 128;

procedure WriteDeltaUserCmd(const Msg: TNetMessage; const From, Cmd: TNetUserCmd);
var
  Bits: Word;
begin
  Bits := 0;
  if Cmd.Angles[0] <> From.Angles[0] then Bits := Bits or CmAngle1;
  if Cmd.Angles[1] <> From.Angles[1] then Bits := Bits or CmAngle2;
  if Cmd.Angles[2] <> From.Angles[2] then Bits := Bits or CmAngle3;
  if Cmd.ForwardMove <> From.ForwardMove then Bits := Bits or CmForward;
  if Cmd.SideMove <> From.SideMove then Bits := Bits or CmSide;
  if Cmd.UpMove <> From.UpMove then Bits := Bits or CmUp;
  if Cmd.Buttons <> From.Buttons then Bits := Bits or CmButtons;
  if Cmd.Impulse <> From.Impulse then Bits := Bits or CmImpulse;
  Msg.WriteWord(Bits);
  if (Bits and CmAngle1) <> 0 then Msg.WriteShort(Cmd.Angles[0]);
  if (Bits and CmAngle2) <> 0 then Msg.WriteShort(Cmd.Angles[1]);
  if (Bits and CmAngle3) <> 0 then Msg.WriteShort(Cmd.Angles[2]);
  if (Bits and CmForward) <> 0 then Msg.WriteShort(Cmd.ForwardMove);
  if (Bits and CmSide) <> 0 then Msg.WriteShort(Cmd.SideMove);
  if (Bits and CmUp) <> 0 then Msg.WriteShort(Cmd.UpMove);
  if (Bits and CmButtons) <> 0 then Msg.WriteByte(Cmd.Buttons);
  if (Bits and CmImpulse) <> 0 then Msg.WriteByte(Cmd.Impulse);
  Msg.WriteByte(Cmd.Msec);
end;

function ReadDeltaUserCmd(const Msg: TNetMessage; const From: TNetUserCmd): TNetUserCmd;
var
  Bits: Word;
begin
  Result := From;
  Bits := Msg.ReadWord;
  if (Bits and CmAngle1) <> 0 then Result.Angles[0] := Msg.ReadShort;
  if (Bits and CmAngle2) <> 0 then Result.Angles[1] := Msg.ReadShort;
  if (Bits and CmAngle3) <> 0 then Result.Angles[2] := Msg.ReadShort;
  if (Bits and CmForward) <> 0 then Result.ForwardMove := Msg.ReadShort;
  if (Bits and CmSide) <> 0 then Result.SideMove := Msg.ReadShort;
  if (Bits and CmUp) <> 0 then Result.UpMove := Msg.ReadShort;
  if (Bits and CmButtons) <> 0 then Result.Buttons := Msg.ReadByte;
  if (Bits and CmImpulse) <> 0 then Result.Impulse := Msg.ReadByte;
  Result.Msec := Msg.ReadByte;
end;

{ Entities ------------------------------------------------------------------- }

procedure WriteDeltaEntity(const Msg: TNetMessage; const From, ToState: TNetEntityState;
  const Force: Boolean);
var
  Bits: Word;
begin
  Bits := 0;
  if ToState.Origin.X <> From.Origin.X then Bits := Bits or UOrigin1;
  if ToState.Origin.Y <> From.Origin.Y then Bits := Bits or UOrigin2;
  if ToState.Origin.Z <> From.Origin.Z then Bits := Bits or UOrigin3;
  if AngleToShort(ToState.Angles.X) <> AngleToShort(From.Angles.X) then Bits := Bits or UAngle1;
  if AngleToShort(ToState.Angles.Y) <> AngleToShort(From.Angles.Y) then Bits := Bits or UAngle2;
  if AngleToShort(ToState.Angles.Z) <> AngleToShort(From.Angles.Z) then Bits := Bits or UAngle3;
  if ToState.ModelIndex <> From.ModelIndex then Bits := Bits or UModel;
  if ToState.ModelIndex2 <> From.ModelIndex2 then Bits := Bits or UModel2;
  if ToState.Frame <> From.Frame then Bits := Bits or UFrame;
  if ToState.Skin <> From.Skin then Bits := Bits or USkin;
  if ToState.Effects <> From.Effects then Bits := Bits or UEffects;
  if ToState.RenderFx <> From.RenderFx then Bits := Bits or URenderFx;
  if ToState.Scale <> From.Scale then Bits := Bits or UScale;
  if ToState.OldFrame <> From.OldFrame then Bits := Bits or UOldFrame;
  if ToState.Lerp <> From.Lerp then Bits := Bits or ULerp;
  if (Bits = 0) and not Force then
    Exit;
  Msg.WriteWord(ToState.Number);
  Msg.WriteWord(Bits);
  if (Bits and UModel) <> 0 then Msg.WriteWord(ToState.ModelIndex);
  if (Bits and UModel2) <> 0 then Msg.WriteWord(ToState.ModelIndex2);
  if (Bits and UFrame) <> 0 then Msg.WriteWord(ToState.Frame);
  if (Bits and USkin) <> 0 then Msg.WriteByte(ToState.Skin);
  if (Bits and UEffects) <> 0 then Msg.WriteLong(LongInt(ToState.Effects));
  if (Bits and URenderFx) <> 0 then Msg.WriteLong(LongInt(ToState.RenderFx));
  if (Bits and UScale) <> 0 then Msg.WriteFloat(ToState.Scale);
  if (Bits and UOldFrame) <> 0 then Msg.WriteWord(ToState.OldFrame);
  if (Bits and ULerp) <> 0 then Msg.WriteByte(ToState.Lerp);
  if (Bits and UOrigin1) <> 0 then Msg.WriteFloat(ToState.Origin.X);
  if (Bits and UOrigin2) <> 0 then Msg.WriteFloat(ToState.Origin.Y);
  if (Bits and UOrigin3) <> 0 then Msg.WriteFloat(ToState.Origin.Z);
  if (Bits and UAngle1) <> 0 then Msg.WriteAngle16(ToState.Angles.X);
  if (Bits and UAngle2) <> 0 then Msg.WriteAngle16(ToState.Angles.Y);
  if (Bits and UAngle3) <> 0 then Msg.WriteAngle16(ToState.Angles.Z);
end;

function ReadDeltaEntity(const Msg: TNetMessage; const From: TNetEntityState;
  const Number: Integer; const Bits: Word): TNetEntityState;
begin
  Result := From;
  Result.Number := Number;
  if (Bits and UModel) <> 0 then Result.ModelIndex := Msg.ReadWord;
  if (Bits and UModel2) <> 0 then Result.ModelIndex2 := Msg.ReadWord;
  if (Bits and UFrame) <> 0 then Result.Frame := Msg.ReadWord;
  if (Bits and USkin) <> 0 then Result.Skin := Msg.ReadByte;
  if (Bits and UEffects) <> 0 then Result.Effects := Cardinal(Msg.ReadLong);
  if (Bits and URenderFx) <> 0 then Result.RenderFx := Cardinal(Msg.ReadLong);
  if (Bits and UScale) <> 0 then Result.Scale := Msg.ReadFloat;
  if (Bits and UOldFrame) <> 0 then Result.OldFrame := Msg.ReadWord;
  if (Bits and ULerp) <> 0 then Result.Lerp := Msg.ReadByte;
  if (Bits and UOrigin1) <> 0 then Result.Origin.X := Msg.ReadFloat;
  if (Bits and UOrigin2) <> 0 then Result.Origin.Y := Msg.ReadFloat;
  if (Bits and UOrigin3) <> 0 then Result.Origin.Z := Msg.ReadFloat;
  if (Bits and UAngle1) <> 0 then Result.Angles.X := Msg.ReadAngle16;
  if (Bits and UAngle2) <> 0 then Result.Angles.Y := Msg.ReadAngle16;
  if (Bits and UAngle3) <> 0 then Result.Angles.Z := Msg.ReadAngle16;
end;

procedure WritePacketEntities(const Msg: TNetMessage; const OldStates, NewStates: TNetEntityStates);
var
  OldIndex, NewIndex, OldNum, NewNum: Integer;
begin
  OldIndex := 0;
  NewIndex := 0;
  while (NewIndex < Length(NewStates)) or (OldIndex < Length(OldStates)) do
  begin
    if NewIndex < Length(NewStates) then
      NewNum := NewStates[NewIndex].Number
    else
      NewNum := MaxInt;
    if OldIndex < Length(OldStates) then
      OldNum := OldStates[OldIndex].Number
    else
      OldNum := MaxInt;
    if NewNum = OldNum then
    begin
      { Changed fields only (nothing if the same) }
      WriteDeltaEntity(Msg, OldStates[OldIndex], NewStates[NewIndex], False);
      Inc(OldIndex);
      Inc(NewIndex);
    end else
    if NewNum < OldNum then
    begin
      { Came into view: everything that differs from an empty state }
      WriteDeltaEntity(Msg, NullEntityState(NewNum), NewStates[NewIndex], True);
      Inc(NewIndex);
    end else
    begin
      { Went out of view or was removed }
      Msg.WriteWord(OldNum);
      Msg.WriteWord(URemove);
      Inc(OldIndex);
    end;
  end;
  Msg.WriteWord(0);
end;

function ReadPacketEntities(const Msg: TNetMessage; const OldStates: TNetEntityStates;
  out NewStates: TNetEntityStates): Boolean;
var
  Count, OldIndex, Num, LastNum: Integer;
  Bits: Word;

  procedure Add(const S: TNetEntityState);
  begin
    if Count = Length(NewStates) then
      SetLength(NewStates, 2 * Count + 16);
    NewStates[Count] := S;
    Inc(Count);
  end;

begin
  Result := False;
  NewStates := nil;
  Count := 0;
  OldIndex := 0;
  LastNum := 0;
  repeat
    Num := Msg.ReadWord;
    if Msg.BadRead then
      Exit;
    if Num = 0 then
      Break;
    { Numbers come in increasing order }
    if (Num <= LastNum) or (Num >= MaxNetEntities) then
      Exit;
    LastNum := Num;
    Bits := Msg.ReadWord;
    while (OldIndex < Length(OldStates)) and (OldStates[OldIndex].Number < Num) do
    begin
      Add(OldStates[OldIndex]);
      Inc(OldIndex);
    end;
    if (OldIndex < Length(OldStates)) and (OldStates[OldIndex].Number = Num) then
    begin
      if (Bits and URemove) = 0 then
        Add(ReadDeltaEntity(Msg, OldStates[OldIndex], Num, Bits));
      Inc(OldIndex);
    end else
    if (Bits and URemove) = 0 then
      Add(ReadDeltaEntity(Msg, NullEntityState(Num), Num, Bits));
  until False;
  while OldIndex < Length(OldStates) do
  begin
    Add(OldStates[OldIndex]);
    Inc(OldIndex);
  end;
  SetLength(NewStates, Count);
  Result := not Msg.BadRead;
end;

{ Player state --------------------------------------------------------------- }

const
  PsType = 1;
  PsOrigin = 2;
  PsAngles = 4;
  PsGunIndex = 8;
  PsGunFrame = 16;
  PsVelocity = 32;
  PsFlags = 64;
  PsTime = 128;
  PsGravity = 256;
  PsCommand = 512;

procedure WriteDeltaPlayerState(const Msg: TNetMessage; const From, P: TNetPlayerState);
var
  Bits: Word;
  StatBits: LongWord;
  I: Integer;
begin
  Bits := 0;
  if P.PmType <> From.PmType then Bits := Bits or PsType;
  if not TVector3.PerfectlyEquals(P.Origin, From.Origin) then Bits := Bits or PsOrigin;
  if not TVector3.PerfectlyEquals(P.ViewAngles, From.ViewAngles) then Bits := Bits or PsAngles;
  if P.GunIndex <> From.GunIndex then Bits := Bits or PsGunIndex;
  if P.GunFrame <> From.GunFrame then Bits := Bits or PsGunFrame;
  if not TVector3.PerfectlyEquals(P.Velocity, From.Velocity) then Bits := Bits or PsVelocity;
  if P.PmFlags <> From.PmFlags then Bits := Bits or PsFlags;
  if P.PmTime <> From.PmTime then Bits := Bits or PsTime;
  if P.Gravity <> From.Gravity then Bits := Bits or PsGravity;
  if P.CommandAck <> From.CommandAck then Bits := Bits or PsCommand;
  Msg.WriteWord(Bits);
  if (Bits and PsType) <> 0 then Msg.WriteByte(P.PmType);
  if (Bits and PsOrigin) <> 0 then Msg.WriteVector(P.Origin);
  if (Bits and PsVelocity) <> 0 then Msg.WriteVector(P.Velocity);
  if (Bits and PsFlags) <> 0 then Msg.WriteByte(P.PmFlags);
  if (Bits and PsTime) <> 0 then Msg.WriteFloat(P.PmTime);
  if (Bits and PsGravity) <> 0 then Msg.WriteFloat(P.Gravity);
  if (Bits and PsCommand) <> 0 then Msg.WriteLong(P.CommandAck);
  if (Bits and PsAngles) <> 0 then
  begin
    Msg.WriteAngle16(P.ViewAngles.X);
    Msg.WriteAngle16(P.ViewAngles.Y);
    Msg.WriteAngle16(P.ViewAngles.Z);
  end;
  if (Bits and PsGunIndex) <> 0 then Msg.WriteWord(P.GunIndex);
  if (Bits and PsGunFrame) <> 0 then Msg.WriteWord(P.GunFrame);
  StatBits := 0;
  for I := 0 to MaxNetStats - 1 do
    if P.Stats[I] <> From.Stats[I] then
      StatBits := StatBits or (LongWord(1) shl I);
  Msg.WriteLong(LongInt(StatBits));
  for I := 0 to MaxNetStats - 1 do
    if (StatBits and (LongWord(1) shl I)) <> 0 then
      Msg.WriteShort(P.Stats[I]);
end;

function ReadDeltaPlayerState(const Msg: TNetMessage; const From: TNetPlayerState): TNetPlayerState;
var
  Bits: Word;
  StatBits: LongWord;
  I: Integer;
begin
  Result := From;
  Bits := Msg.ReadWord;
  if (Bits and PsType) <> 0 then Result.PmType := Msg.ReadByte;
  if (Bits and PsOrigin) <> 0 then Result.Origin := Msg.ReadVector;
  if (Bits and PsVelocity) <> 0 then Result.Velocity := Msg.ReadVector;
  if (Bits and PsFlags) <> 0 then Result.PmFlags := Msg.ReadByte;
  if (Bits and PsTime) <> 0 then Result.PmTime := Msg.ReadFloat;
  if (Bits and PsGravity) <> 0 then Result.Gravity := Msg.ReadFloat;
  if (Bits and PsCommand) <> 0 then Result.CommandAck := Msg.ReadLong;
  if (Bits and PsAngles) <> 0 then
  begin
    Result.ViewAngles.X := Msg.ReadAngle16;
    Result.ViewAngles.Y := Msg.ReadAngle16;
    Result.ViewAngles.Z := Msg.ReadAngle16;
  end;
  if (Bits and PsGunIndex) <> 0 then Result.GunIndex := Msg.ReadWord;
  if (Bits and PsGunFrame) <> 0 then Result.GunFrame := Msg.ReadWord;
  StatBits := LongWord(Msg.ReadLong);
  for I := 0 to MaxNetStats - 1 do
    if (StatBits and (LongWord(1) shl I)) <> 0 then
      Result.Stats[I] := Msg.ReadShort;
end;

{ pmove ---------------------------------------------------------------------- }

function UserCmdToPMoveInput(const Cmd: TNetUserCmd): TPMoveInput;
var
  Pitch, Yaw: Single;
begin
  Result.Forward := Cmd.ForwardMove / NetMoveScale;
  Result.Side := Cmd.SideMove / NetMoveScale;
  Result.Jump := Cmd.UpMove > 0;
  Result.Crouch := Cmd.UpMove < 0;
  { AngleVectors' forward (pitch down positive) }
  Pitch := DegToRad(ShortToAngle(Cmd.Angles[0]));
  Yaw := DegToRad(ShortToAngle(Cmd.Angles[1]));
  Result.Dir := Vector3(Cos(Pitch) * Cos(Yaw), Cos(Pitch) * Sin(Yaw), -Sin(Pitch));
  Result.Dt := Cmd.Msec / 1000;
end;

function PMoveInputToUserCmd(const Input: TPMoveInput; const Msec: Byte): TNetUserCmd;
var
  D: TVector3;
begin
  Result := Default(TNetUserCmd);
  D := Input.Dir;
  if D.IsZero then
    D := Vector3(1, 0, 0);
  D := D.Normalize;
  Result.Angles[0] := AngleToShort(-RadToDeg(ArcSin(EnsureRange(D.Z, -1, 1))));
  Result.Angles[1] := AngleToShort(RadToDeg(ArcTan2(D.Y, D.X)));
  Result.ForwardMove := Round(EnsureRange(Input.Forward, -1, 1) * NetMoveScale);
  Result.SideMove := Round(EnsureRange(Input.Side, -1, 1) * NetMoveScale);
  if Input.Jump then
    Result.UpMove := NetMoveScale
  else
  if Input.Crouch then
    Result.UpMove := -NetMoveScale;
  Result.Msec := Msec;
end;

procedure PMoveToNet(const PM: TQuakePMove; var P: TNetPlayerState);
begin
  P.Origin := PM.Origin;
  P.Velocity := PM.QuakeVelocity;
  P.PmFlags := 0;
  if PM.Crouched then
    P.PmFlags := P.PmFlags or PmfDucked;
  if PM.JumpHeld then
    P.PmFlags := P.PmFlags or PmfJumpHeld;
  if PM.OnGround then
    P.PmFlags := P.PmFlags or PmfOnGround;
  if PM.Noclip then
    P.PmFlags := P.PmFlags or PmfNoclip;
  P.PmTime := PM.LandTime;
  P.Gravity := PM.GravityAcceleration;
end;

procedure NetToPMove(const P: TNetPlayerState; const PM: TQuakePMove);
begin
  PM.Origin := P.Origin;
  PM.QuakeVelocity := P.Velocity;
  PM.Crouched := (P.PmFlags and PmfDucked) <> 0;
  PM.JumpHeld := (P.PmFlags and PmfJumpHeld) <> 0;
  PM.OnGround := (P.PmFlags and PmfOnGround) <> 0;
  PM.Noclip := (P.PmFlags and PmfNoclip) <> 0;
  PM.LandTime := P.PmTime;
  PM.GravityAcceleration := P.Gravity;
end;

end.
