{ Quake 2's player movement (pmove.c) on its own: the state of one player
  (pmove_state_t and the categorised position) and the move of one
  command. The server moves the real player with it (TQuakeServer, the
  world's TQuakeWorld.Player) and the client predicts its own with a copy
  (TQuakePlayerMovement), replaying the commands the server hasn't
  acknowledged yet. Quake coordinates throughout, except where a name says
  CGE. }
unit QuakePMove;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, CastleVectors, QuakeTrace;

type
  TFallDamageEvent = procedure(const Damage: Integer) of object;
  { Contents (Quake CONTENTS_* bits) at a CGE position }
  TPointContentsEvent = function(const CgePos: TVector3): Integer of object;
  { Sweep a box (Quake coordinates: Mins / Maxs around the moving origin)
    against everything solid for Mask (map brushes, movers, monsters) }
  TPlayerTraceEvent = function(const Start, Stop, Mins, Maxs: TVector3;
    const Mask: Integer): TQuakeTrace of object;

  { What one command asks of pmove }
  TPMoveInput = record
    { -1..1 }
    Forward, Side: Single;
    Jump, Crouch: Boolean;
    { View direction (Quake coordinates, unit length) }
    Dir: TVector3;
    { Seconds (at most 0.05 are moved, like before: no tunnelling) }
    Dt: Single;
  end;

  TQuakePMove = class
  strict private
    FOrg, FVel: TVector3;
    FOnGround, FCrouched, FJumpHeld, FOnLadder, FNoclip: Boolean;
    FWaterLevel, FWaterType: Integer;
    { Full contents at the feet (with current bits) and of the ground brush }
    FWaterContents, FGroundContents: Integer;
    FGroundObject: TObject;
    FLandTime: Single;
    FStuckCount: Integer;
    FLastRise, FLastFallDelta: Single;
    FLastWasOnGround: Boolean;
    FOnTrace: TPlayerTraceEvent;
    FOnPointContents: TPointContentsEvent;
    FOnFallDamage: TFallDamageEvent;
    FOnLandSound: TNotifyEvent;
    FOnBeforeMove: TNotifyEvent;
    function PMTrace(const Start, Stop: TVector3): TQuakeTrace;
    function GoodPosition(const Org: TVector3): Boolean;
    procedure Unstick;
    procedure SlideMove(const Dt: Single);
    procedure StepSlideMove(const Dt: Single);
    procedure CategorizePosition;
    procedure CheckDuck(const Input: TPMoveInput);
    procedure ApplyFriction(const Dt: Single);
    procedure Accelerate(const WishDir: TVector3; const WishSpeed, Accel, Dt: Single);
    procedure CheckJump(const Input: TPMoveInput);
    function GetVelocityCge: TVector3;
    procedure SetVelocityCge(const Value: TVector3);
  public
    { Quake 2 pmove constants (pm_maxspeed, pm_duckspeed, pm_accelerate...) }
    RunSpeed, CrouchSpeed, AccelerateRate, AirAccelerateRate, Friction, StopSpeed: Single;
    GravityAcceleration, JumpSpeed, StepSize, HalfWidth: Single;
    WaterFriction, WaterSink: Single;
    { Eye above the feet, standing and ducked (origin 24 above the feet) }
    StandEyeHeight, CrouchEyeHeight: Single;
    constructor Create;
    procedure CopyParams(const Source: TQuakePMove);
    { The whole state of Source (not the events) }
    procedure CopyState(const Source: TQuakePMove);
    { Placed by code: not moving, standing, no landing pause }
    procedure ResetState;
    { One command (PM_Move). Without OnTrace only noclip moves. }
    procedure Move(const Input: TPMoveInput);
    { Out of solids to the nearest free spot within MaxDist; False if none }
    function FindFree(const MaxDist: Single): Boolean;
    function Mins: TVector3;
    function Maxs: TVector3;
    { Origin to eye: standing 22, ducked -2 }
    function ViewHeight: Single;
    { Throw the player (CGE units per second) }
    procedure AddVelocity(const V: TVector3);
    { Move by Delta (CGE), carried by a mover }
    procedure Push(const Delta: TVector3);
    { The same names as TQuakePlayerMovement's, for the world }
    function BoxMins: TVector3;
    function BoxMaxs: TVector3;
    property Origin: TVector3 read FOrg write FOrg;
    { Quake units per second }
    property QuakeVelocity: TVector3 read FVel write FVel;
    { CGE units per second }
    property Velocity: TVector3 read GetVelocityCge write SetVelocityCge;
    property OnGround: Boolean read FOnGround write FOnGround;
    property Crouched: Boolean read FCrouched write FCrouched;
    property JumpHeld: Boolean read FJumpHeld write FJumpHeld;
    property OnLadder: Boolean read FOnLadder;
    property Noclip: Boolean read FNoclip write FNoclip;
    property LandTime: Single read FLandTime write FLandTime;
    property WaterLevel: Integer read FWaterLevel;
    property WaterType: Integer read FWaterType;
    property GroundObject: TObject read FGroundObject;
    { Moves that started inside a solid (and were nudged out) }
    property StuckCount: Integer read FStuckCount;
    { Of the last Move: how far it went up, the landing's fall delta (0 =
      no landing; P_FallingDamage's delta), on ground before it }
    property LastRise: Single read FLastRise;
    property LastFallDelta: Single read FLastFallDelta;
    property LastWasOnGround: Boolean read FLastWasOnGround;
    property OnTrace: TPlayerTraceEvent read FOnTrace write FOnTrace;
    property OnPointContents: TPointContentsEvent read FOnPointContents write FOnPointContents;
    { Called by Move on a hard landing / an audible one (the server's
      player only: a client replaying commands mustn't hurt anyone) }
    property OnFallDamage: TFallDamageEvent read FOnFallDamage write FOnFallDamage;
    property OnLandSound: TNotifyEvent read FOnLandSound write FOnLandSound;
    { Called by the server before each command's move (movers push the
      player there) }
    property OnBeforeMove: TNotifyEvent read FOnBeforeMove write FOnBeforeMove;
  end;

{ PM_AddCurrents (Quake coordinates): the velocity water currents (contents
  where the player is, 400, halved when wading on the ground) and conveyor
  belts (contents of the ground brush, 100) add to the wished velocity }
function PMCurrentVelocity(const WaterContents, WaterLevel: Integer; const OnGround: Boolean;
  const GroundContents: Integer): TVector3;

implementation

uses
  QuakeBsp;

const
  PM_STOP_EPSILON = 0.1;
  PM_MIN_STEP_NORMAL = 0.7;
  PM_MAX_CLIP_PLANES = 5;
  PM_CONTENTS_LADDER = $20000000;
  PM_MASK_LIQUID = 8 or 16 or 32;
  PM_CONTENTS_SLIME = 16;
  PM_CONTENTS_WATER = 32;
  PM_MASK_PLAYERSOLID = 1 or 2 or $10000 or $2000000;

function QV(const C: TVector3): TVector3; inline;
begin
  Result := Vector3(C.X, -C.Z, C.Y);
end;

function CV(const Q: TVector3): TVector3; inline;
begin
  Result := Vector3(Q.X, Q.Z, -Q.Y);
end;

constructor TQuakePMove.Create;
begin
  inherited Create;
  RunSpeed := 300;
  CrouchSpeed := 100;
  AccelerateRate := 10;
  AirAccelerateRate := 1;
  Friction := 6;
  StopSpeed := 100;
  GravityAcceleration := 800;
  JumpSpeed := 270;
  StepSize := 18;
  HalfWidth := 16;
  WaterFriction := 1;
  WaterSink := 60;
  StandEyeHeight := 46;
  CrouchEyeHeight := 22;
end;

procedure TQuakePMove.CopyParams(const Source: TQuakePMove);
begin
  RunSpeed := Source.RunSpeed;
  CrouchSpeed := Source.CrouchSpeed;
  AccelerateRate := Source.AccelerateRate;
  AirAccelerateRate := Source.AirAccelerateRate;
  Friction := Source.Friction;
  StopSpeed := Source.StopSpeed;
  GravityAcceleration := Source.GravityAcceleration;
  JumpSpeed := Source.JumpSpeed;
  StepSize := Source.StepSize;
  HalfWidth := Source.HalfWidth;
  WaterFriction := Source.WaterFriction;
  WaterSink := Source.WaterSink;
  StandEyeHeight := Source.StandEyeHeight;
  CrouchEyeHeight := Source.CrouchEyeHeight;
end;

procedure TQuakePMove.CopyState(const Source: TQuakePMove);
begin
  FOrg := Source.FOrg;
  FVel := Source.FVel;
  FOnGround := Source.FOnGround;
  FCrouched := Source.FCrouched;
  FJumpHeld := Source.FJumpHeld;
  FOnLadder := Source.FOnLadder;
  FNoclip := Source.FNoclip;
  FWaterLevel := Source.FWaterLevel;
  FWaterType := Source.FWaterType;
  FWaterContents := Source.FWaterContents;
  FGroundContents := Source.FGroundContents;
  FGroundObject := Source.FGroundObject;
  FLandTime := Source.FLandTime;
  GravityAcceleration := Source.GravityAcceleration;
end;

procedure TQuakePMove.ResetState;
begin
  FVel := TVector3.Zero;
  FCrouched := False;
  FJumpHeld := False;
  FLandTime := 0;
  FGroundObject := nil;
end;

function TQuakePMove.GetVelocityCge: TVector3;
begin
  Result := CV(FVel);
end;

procedure TQuakePMove.SetVelocityCge(const Value: TVector3);
begin
  FVel := QV(Value);
end;

procedure TQuakePMove.AddVelocity(const V: TVector3);
begin
  FVel := FVel + QV(V);
  if V.Y > 0 then
    FOnGround := False;
end;

procedure TQuakePMove.Push(const Delta: TVector3);
begin
  FOrg := FOrg + QV(Delta);
end;

function TQuakePMove.Mins: TVector3;
begin
  Result := Vector3(-HalfWidth, -HalfWidth, -24);
end;

function TQuakePMove.Maxs: TVector3;
begin
  if FCrouched then
    Result := Vector3(HalfWidth, HalfWidth, 4)
  else
    Result := Vector3(HalfWidth, HalfWidth, 32);
end;

function TQuakePMove.BoxMins: TVector3;
begin
  Result := Mins;
end;

function TQuakePMove.BoxMaxs: TVector3;
begin
  Result := Maxs;
end;

function TQuakePMove.ViewHeight: Single;
begin
  if FCrouched then
    Result := CrouchEyeHeight - 24
  else
    Result := StandEyeHeight - 24;
end;

function TQuakePMove.PMTrace(const Start, Stop: TVector3): TQuakeTrace;
begin
  Result := FOnTrace(Start, Stop, Mins, Maxs, PM_MASK_PLAYERSOLID);
end;

function TQuakePMove.GoodPosition(const Org: TVector3): Boolean;
begin
  Result := not PMTrace(Org, Org).AllSolid;
end;

function TQuakePMove.FindFree(const MaxDist: Single): Boolean;
var
  R: Single;
  DX, DY, DZ: Integer;
  Off: TVector3;
begin
  if not Assigned(FOnTrace) then
    Exit(False);
  if GoodPosition(FOrg) then
    Exit(True);
  R := 1;
  while R <= MaxDist do
  begin
    { Up first, then the 26 directions around }
    if GoodPosition(FOrg + Vector3(0, 0, R)) then
    begin
      FOrg := FOrg + Vector3(0, 0, R);
      Exit(True);
    end;
    for DZ := 1 downto 0 do
      for DX := -1 to 1 do
        for DY := -1 to 1 do
          if (DX <> 0) or (DY <> 0) or (DZ <> 0) then
          begin
            Off := Vector3(DX, DY, DZ).Normalize * R;
            if GoodPosition(FOrg + Off) then
            begin
              FOrg := FOrg + Off;
              Exit(True);
            end;
          end;
    R := R * 1.5;
  end;
  Result := False;
end;

procedure TQuakePMove.Unstick;
const
  Dists: array[0..5] of Single = (1, 2, 4, 8, 16, 24);
  { Never down: below a floor is the void outside the map }
  Dirs: array[0..4] of TVector3 = ((X: 0; Y: 0; Z: 1), (X: 1; Y: 0; Z: 0), (X: -1; Y: 0; Z: 0),
    (X: 0; Y: 1; Z: 0), (X: 0; Y: -1; Z: 0));
var
  D, I: Integer;
begin
  { Started inside a solid (spawned in a wall, pushed by a mover): find the
    nearest free spot, like Quake 2's PM_InitialSnapPosition but further }
  if GoodPosition(FOrg) then
    Exit;
  Inc(FStuckCount);
  for D := 0 to High(Dists) do
    for I := 0 to High(Dirs) do
      if GoodPosition(FOrg + Dirs[I] * Dists[D]) then
      begin
        FOrg := FOrg + Dirs[I] * Dists[D];
        Exit;
      end;
end;

procedure PMClipVelocity(const InV, Normal: TVector3; out OutV: TVector3; const Overbounce: Single);
var
  Backoff: Single;
  I: Integer;
begin
  Backoff := TVector3.DotProduct(InV, Normal) * Overbounce;
  OutV := InV - Normal * Backoff;
  for I := 0 to 2 do
    if Abs(OutV.Data[I]) < PM_STOP_EPSILON then
      OutV.Data[I] := 0;
end;

procedure TQuakePMove.SlideMove(const Dt: Single);
var
  Bump, I, J, NumPlanes: Integer;
  Planes: array[0..PM_MAX_CLIP_PLANES - 1] of TVector3;
  PrimalVel, Dir, Stop: TVector3;
  TimeLeft, D: Single;
  T: TQuakeTrace;
begin
  { PM_StepSlideMove_: move, clipping the velocity against every plane hit
    (at most 4 bumps), along creases between two planes }
  NumPlanes := 0;
  PrimalVel := FVel;
  TimeLeft := Dt;
  for Bump := 0 to 3 do
  begin
    Stop := FOrg + FVel * TimeLeft;
    T := PMTrace(FOrg, Stop);
    if T.AllSolid then
    begin
      { Trapped in a solid }
      FVel.Z := 0;
      Exit;
    end;
    if T.Fraction > 0 then
    begin
      FOrg := T.EndPos;
      NumPlanes := 0;
    end;
    if T.Fraction = 1 then
      Break;
    TimeLeft := TimeLeft - TimeLeft * T.Fraction;
    if NumPlanes >= PM_MAX_CLIP_PLANES then
    begin
      FVel := TVector3.Zero;
      Break;
    end;
    Planes[NumPlanes] := T.Normal;
    Inc(NumPlanes);
    { Make the velocity parallel to all clip planes }
    I := 0;
    while I < NumPlanes do
    begin
      PMClipVelocity(FVel, Planes[I], FVel, 1.01);
      J := 0;
      while J < NumPlanes do
      begin
        if (J <> I) and (TVector3.DotProduct(FVel, Planes[J]) < 0) then
          Break;
        Inc(J);
      end;
      if J = NumPlanes then
        Break;
      Inc(I);
    end;
    if I = NumPlanes then
    begin
      { Go along the crease }
      if NumPlanes <> 2 then
      begin
        FVel := TVector3.Zero;
        Break;
      end;
      Dir := TVector3.CrossProduct(Planes[0], Planes[1]);
      D := TVector3.DotProduct(Dir, FVel);
      FVel := Dir * D;
    end;
    { Stop dead rather than oscillate in sloping corners }
    if TVector3.DotProduct(FVel, PrimalVel) <= 0 then
    begin
      FVel := TVector3.Zero;
      Break;
    end;
  end;
end;

procedure TQuakePMove.StepSlideMove(const Dt: Single);
var
  StartO, StartV, DownO, DownV, Up, Down: TVector3;
  T: TQuakeTrace;
  DownDist, UpDist: Single;
begin
  { PM_StepSlideMove: slide; then try again from StepSize higher and keep
    whichever got further (walks up stairs) }
  StartO := FOrg;
  StartV := FVel;
  SlideMove(Dt);
  DownO := FOrg;
  DownV := FVel;

  Up := StartO + Vector3(0, 0, StepSize);
  T := PMTrace(Up, Up);
  if T.AllSolid then
    Exit; { can't step up }

  FOrg := Up;
  FVel := StartV;
  SlideMove(Dt);
  { Push down the final amount }
  Down := FOrg - Vector3(0, 0, StepSize);
  T := PMTrace(FOrg, Down);
  if not T.AllSolid then
    FOrg := T.EndPos;
  Up := FOrg;

  DownDist := Sqr(DownO.X - StartO.X) + Sqr(DownO.Y - StartO.Y);
  UpDist := Sqr(Up.X - StartO.X) + Sqr(Up.Y - StartO.Y);
  if (DownDist > UpDist) or (T.Normal.Z < PM_MIN_STEP_NORMAL) then
  begin
    FOrg := DownO;
    FVel := DownV;
    Exit;
  end;
  { Walking along a plane: keep the vertical speed of the plain slide }
  FVel.Z := DownV.Z;
end;

procedure TQuakePMove.CategorizePosition;
var
  Point: TVector3;
  T: TQuakeTrace;
  Sample1, Sample2: Single;
  C: Integer;
begin
  { PM_CatagorizePosition: on ground if a 0.25 unit trace down hits a
    walkable plane (normal z >= 0.7) }
  Point := FOrg - Vector3(0, 0, 0.25);
  FGroundContents := 0;
  if FVel.Z > 180 then
  begin
    FOnGround := False;
    FGroundObject := nil;
  end else
  begin
    T := PMTrace(FOrg, Point);
    if (not T.Hit) or ((T.Normal.Z < 0.7) and not T.StartSolid) then
    begin
      FOnGround := False;
      FGroundObject := nil;
    end else
    begin
      FGroundObject := T.Ent;
      FGroundContents := T.Contents;
      if not FOnGround then
      begin
        { Just hit the ground: a hard landing stops jumps for a moment }
        if FVel.Z < -200 then
        begin
          if FVel.Z < -400 then
            FLandTime := 25 * 0.008
          else
            FLandTime := 18 * 0.008;
        end;
      end;
      FOnGround := True;
    end;
  end;

  { Water level: feet, waist, eyes }
  FWaterLevel := 0;
  FWaterType := 0;
  if not Assigned(FOnPointContents) then
    Exit;
  Sample1 := ViewHeight - Mins.Z;
  Sample2 := Sample1 / 2;
  Point := FOrg + Vector3(0, 0, Mins.Z + 1);
  C := FOnPointContents(CV(Point));
  if (C and PM_MASK_LIQUID) <> 0 then
  begin
    FWaterType := C and PM_MASK_LIQUID;
    FWaterContents := C;
    FWaterLevel := 1;
    Point.Z := FOrg.Z + Mins.Z + Sample2;
    if (FOnPointContents(CV(Point)) and PM_MASK_LIQUID) <> 0 then
    begin
      FWaterLevel := 2;
      Point.Z := FOrg.Z + Mins.Z + Sample1;
      if (FOnPointContents(CV(Point)) and PM_MASK_LIQUID) <> 0 then
        FWaterLevel := 3;
    end;
  end;
end;

function CurrentDirection(const Contents: Integer): TVector3;
begin
  Result := TVector3.Zero;
  if (Contents and CONTENTS_CURRENT_0) <> 0 then Result.X := Result.X + 1;
  if (Contents and CONTENTS_CURRENT_90) <> 0 then Result.Y := Result.Y + 1;
  if (Contents and CONTENTS_CURRENT_180) <> 0 then Result.X := Result.X - 1;
  if (Contents and CONTENTS_CURRENT_270) <> 0 then Result.Y := Result.Y - 1;
  if (Contents and CONTENTS_CURRENT_UP) <> 0 then Result.Z := Result.Z + 1;
  if (Contents and CONTENTS_CURRENT_DOWN) <> 0 then Result.Z := Result.Z - 1;
end;

function PMCurrentVelocity(const WaterContents, WaterLevel: Integer; const OnGround: Boolean;
  const GroundContents: Integer): TVector3;
var
  S: Single;
begin
  Result := TVector3.Zero;
  if (WaterLevel > 0) and ((WaterContents and MASK_CURRENT) <> 0) then
  begin
    S := 400; { pm_waterspeed }
    if (WaterLevel = 1) and OnGround then
      S := S / 2;
    Result := Result + CurrentDirection(WaterContents) * S;
  end;
  if OnGround then
    Result := Result + CurrentDirection(GroundContents) * 100;
end;

procedure TQuakePMove.CheckDuck(const Input: TPMoveInput);
begin
  { PM_CheckDuck: duck on the ground; stand up when there is room }
  if Input.Crouch and FOnGround then
    FCrouched := True
  else
  if FCrouched then
  begin
    FCrouched := False;
    if PMTrace(FOrg, FOrg).AllSolid then
      FCrouched := True;
  end;
end;

procedure TQuakePMove.ApplyFriction(const Dt: Single);
var
  Speed, Drop, Control, NewSpeed: Single;
begin
  { PM_Friction: ground (and ladder) friction, water friction by depth }
  Speed := FVel.Length;
  if Speed < 1 then
  begin
    FVel.X := 0;
    FVel.Y := 0;
    Exit;
  end;
  Drop := 0;
  if FOnGround or FOnLadder then
  begin
    Control := Max(Speed, StopSpeed);
    Drop := Drop + Control * Friction * Dt;
  end;
  if (FWaterLevel > 0) and not FOnLadder then
    Drop := Drop + Speed * WaterFriction * FWaterLevel * Dt;
  NewSpeed := Max(0, Speed - Drop) / Speed;
  FVel := FVel * NewSpeed;
end;

procedure TQuakePMove.Accelerate(const WishDir: TVector3; const WishSpeed, Accel, Dt: Single);
var
  CurrentSpeed, AddSpeed, AccelSpeed: Single;
begin
  CurrentSpeed := TVector3.DotProduct(FVel, WishDir);
  AddSpeed := WishSpeed - CurrentSpeed;
  if AddSpeed <= 0 then
    Exit;
  AccelSpeed := Min(AddSpeed, Accel * Dt * WishSpeed);
  FVel := FVel + WishDir * AccelSpeed;
end;

procedure TQuakePMove.CheckJump(const Input: TPMoveInput);
begin
  { PM_CheckJump }
  if FLandTime > 0 then
    Exit;
  if not Input.Jump then
  begin
    FJumpHeld := False;
    Exit;
  end;
  if FJumpHeld then
    Exit;
  if FWaterLevel >= 2 then
  begin
    { Swim up }
    FOnGround := False;
    FGroundObject := nil;
    if FVel.Z <= -300 then
      Exit;
    if FWaterType = PM_CONTENTS_WATER then
      FVel.Z := 100
    else
    if FWaterType = PM_CONTENTS_SLIME then
      FVel.Z := 80
    else
      FVel.Z := 50;
    Exit;
  end;
  if not FOnGround then
    Exit;
  FJumpHeld := True;
  FOnGround := False;
  FGroundObject := nil;
  FVel.Z := Max(FVel.Z + JumpSpeed, JumpSpeed);
end;

procedure TQuakePMove.Move(const Input: TPMoveInput);
const
  SinPitch15 = 0.2588;
  MoveScale = 400; { cl_forwardspeed / cl_sidespeed with always run }
var
  DirQ, Forward, Right, WishVel, WishDir: TVector3;
  FMove, SMove, WishSpeed, MaxSpeed, PreVelZ, FallSpeed, Delta, StartZ, Dt: Single;
  T: TQuakeTrace;
begin
  FLastRise := 0;
  FLastFallDelta := 0;
  FLastWasOnGround := FOnGround;
  { Large steps (loading hitches) would tunnel through floors }
  Dt := Min(Input.Dt, 0.05);
  if Dt <= 0 then
    Exit;
  DirQ := Input.Dir;
  if DirQ.IsZero then
    DirQ := Vector3(1, 0, 0);

  if FNoclip then
  begin
    Right := TVector3.CrossProduct(DirQ, Vector3(0, 0, 1));
    if not Right.IsZero then
      Right := Right.Normalize;
    FOrg := FOrg + (DirQ * Input.Forward + Right * Input.Side) * RunSpeed * 1.5 * Dt;
    FVel := TVector3.Zero;
    Exit;
  end;
  if not Assigned(FOnTrace) then
    Exit;

  Unstick;
  StartZ := FOrg.Z;

  CheckDuck(Input);
  FLastWasOnGround := FOnGround;
  CategorizePosition;
  if FLandTime > 0 then
    FLandTime := Max(0, FLandTime - Dt);

  Forward := Vector3(DirQ.X, DirQ.Y, 0);
  if Forward.Length < 0.001 then
    Forward := Vector3(1, 0, 0);
  Forward := Forward.Normalize;
  Right := Vector3(Forward.Y, -Forward.X, 0);

  { PM_CheckSpecialMovement: a ladder brush just in front }
  T := FOnTrace(FOrg, FOrg + Forward, Mins, Maxs, PM_MASK_PLAYERSOLID or PM_CONTENTS_LADDER);
  FOnLadder := (T.Fraction < 1) and ((T.Contents and PM_CONTENTS_LADDER) <> 0);

  CheckJump(Input);
  ApplyFriction(Dt);
  PreVelZ := FVel.Z;

  FMove := Input.Forward * MoveScale;
  SMove := Input.Side * MoveScale;
  if FCrouched then
    MaxSpeed := CrouchSpeed
  else
    MaxSpeed := RunSpeed;

  if FWaterLevel >= 2 then
  begin
    { PM_WaterMove: swim along the view, sink slowly without input }
    WishVel := DirQ * FMove + Right * SMove;
    if (FMove = 0) and (SMove = 0) and not Input.Jump and not Input.Crouch then
      WishVel.Z := WishVel.Z - WaterSink
    else
    if Input.Jump then
      WishVel.Z := WishVel.Z + 200
    else
    if Input.Crouch then
      WishVel.Z := WishVel.Z - 200;
    WishVel := WishVel + PMCurrentVelocity(FWaterContents, FWaterLevel, FOnGround, FGroundContents);
    WishSpeed := WishVel.Length;
    if WishSpeed > MaxSpeed then
      WishSpeed := MaxSpeed;
    WishSpeed := WishSpeed * 0.5;
    if WishVel.Length > 0.001 then
      Accelerate(WishVel.Normalize, WishSpeed, AccelerateRate, Dt);
    StepSlideMove(Dt);
  end else
  begin
    { PM_AirMove }
    WishVel := Forward * FMove + Right * SMove;
    WishVel.Z := 0;
    if FOnLadder and (Abs(FVel.Z) <= 200) then
    begin
      { PM_AddCurrents: climb by looking up / down, jump and crouch }
      if (DirQ.Z >= SinPitch15) and (FMove > 0) then
        WishVel.Z := 200
      else
      if (DirQ.Z <= -SinPitch15) and (FMove > 0) then
        WishVel.Z := -200
      else
      if Input.Jump then
        WishVel.Z := 200
      else
      if Input.Crouch then
        WishVel.Z := -200;
      WishVel.X := EnsureRange(WishVel.X, -25, 25);
      WishVel.Y := EnsureRange(WishVel.Y, -25, 25);
    end;
    WishVel := WishVel + PMCurrentVelocity(FWaterContents, FWaterLevel, FOnGround, FGroundContents);
    WishSpeed := WishVel.Length;
    if WishSpeed > 0.001 then
      WishDir := WishVel / WishSpeed
    else
      WishDir := TVector3.Zero;
    if WishSpeed > MaxSpeed then
      WishSpeed := MaxSpeed;

    if FOnLadder then
    begin
      Accelerate(WishDir, WishSpeed, AccelerateRate, Dt);
      if WishVel.Z = 0 then
      begin
        if FVel.Z > 0 then
          FVel.Z := Max(0, FVel.Z - GravityAcceleration * Dt)
        else
          FVel.Z := Min(0, FVel.Z + GravityAcceleration * Dt);
      end;
      StepSlideMove(Dt);
    end else
    if FOnGround then
    begin
      FVel.Z := 0;
      Accelerate(WishDir, WishSpeed, AccelerateRate, Dt);
      FVel.Z := 0;
      if (FVel.X <> 0) or (FVel.Y <> 0) then
        StepSlideMove(Dt);
    end else
    begin
      Accelerate(WishDir, WishSpeed, AirAccelerateRate, Dt);
      FVel.Z := FVel.Z - GravityAcceleration * Dt;
      StepSlideMove(Dt);
    end;
  end;

  FLastRise := FOrg.Z - StartZ;
  CategorizePosition;

  { Landing: Quake 2 P_FallingDamage (less in water) }
  if FOnGround and not FLastWasOnGround and (PreVelZ < 0) then
  begin
    FallSpeed := -PreVelZ;
    Delta := Sqr(FallSpeed / 10) * 0.01;
    if FWaterLevel = 3 then
      Delta := 0
    else
    if FWaterLevel = 2 then
      Delta := Delta * 0.25
    else
    if FWaterLevel = 1 then
      Delta := Delta * 0.5;
    FLastFallDelta := Delta;
    if (Delta > 30) and Assigned(FOnFallDamage) then
      FOnFallDamage(Max(1, Round((Delta - 30) / 2)))
    else
    if (Delta >= 15) and Assigned(FOnLandSound) then
      FOnLandSound(Self);
  end;
end;

end.
