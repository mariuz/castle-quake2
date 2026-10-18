{ Quake 2 player movement (a port of the essentials of pmove.c) as a CGE behavior.

  Attach TQuakePlayerMovement to the camera (in data/gameviewplay.castle-user-interface
  it's a behavior of "Camera"). TCastleWalkNavigation stays responsible for mouse
  look only; this behavior handles walking, friction, acceleration, air control,
  gravity, jumping, crouching, 18-unit steps, falling damage and jump pads.
  Set Enabled = false to go back to TCastleWalkNavigation's own movement. }
unit QuakePlayer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleClassUtils, CastleBoxes, CastleTriangles,
  QuakeTrace;

type
  TFallDamageEvent = procedure(const Damage: Integer) of object;
  { Contents (Quake CONTENTS_* bits) at a CGE position }
  TPointContentsEvent = function(const CgePos: TVector3): Integer of object;
  { Sweep a box (Quake coordinates: Mins / Maxs around the moving origin)
    against everything solid for Mask (map brushes, movers, monsters) }
  TPlayerTraceEvent = function(const Start, Stop, Mins, Maxs: TVector3;
    const Mask: Integer): TQuakeTrace of object;

  TQuakePlayerMovement = class(TCastleBehavior)
  strict private
    FVelocity: TVector3;
    FOnGround: Boolean;
    FCrouched: Boolean;
    FJumpHeld: Boolean;
    FNoclip: Boolean;
    FActive: Boolean;
    FRunSpeed, FCrouchSpeed, FAccelerate, FAirAccelerate, FFriction, FStopSpeed: Single;
    FGravity, FJumpSpeed, FStepSize, FRadius, FEyeHeight, FCrouchEyeHeight: Single;
    FOnFallDamage: TFallDamageEvent;
    FOnPointContents: TPointContentsEvent;
    FWaterLevel: Integer;
    FWaterType: Integer;
    FWaterSpeed, FWaterFriction, FWaterSink: Single;
    FOnLandSound: TNotifyEvent;
    FOnLadder: Boolean;
    FBoxCollision: Boolean;
    FHalfWidth: Single;
    { View effects (Quake 2 SV_CalcViewOffset / SV_CalcGunOffset), applied to
      the camera after the move and removed before the next one, so they
      never change where the player is }
    FViewBob: Boolean;
    FAppliedOffset: TVector3;
    FAppliedPitch, FAppliedRoll: Single; { degrees }
    FBobTime: Single;
    FFallTime, FFallValue: Single;
    FDamageTime, FDamagePitch, FDamageRoll: Single;
    FGunAngles: TVector3;
    FHasLastAngles: Boolean;
    FLastYaw, FLastPitch, FYawRate, FPitchRate: Single;
    { Trace-based pmove (when OnTrace is set): origin and velocity in Quake
      coordinates during a move, eye above the origin (smoothed when
      ducking), view lag after steps up, landing time, ground entity }
    FOnTrace: TPlayerTraceEvent;
    FOnBeforeMove: TNotifyEvent;
    FOrg, FVel: TVector3;
    FViewZ, FStepOffset, FLandTime: Single;
    FGroundObject: TObject;
    FStuckCount: Integer;
    function PMMins: TVector3;
    function PMMaxs: TVector3;
    function PMViewHeight: Single;
    function PMTrace(const Start, Stop: TVector3): TQuakeTrace;
    function PMGoodPosition(const Org: TVector3): Boolean;
    procedure PMUnstick;
    function PMFindFree(const MaxDist: Single): Boolean;
    procedure PMSlideMove(const Dt: Single);
    procedure PMStepSlideMove(const Dt: Single);
    procedure PMCategorizePosition;
    procedure PMCheckDuck;
    procedure PMFriction(const Dt: Single);
    procedure PMAccelerate(const WishDir: TVector3; const WishSpeed, Accel, Dt: Single);
    procedure PMCheckJump;
    procedure PMMove(const Dt: Single);
    { Move the player (the pmove part of Update) }
    procedure Move(const SecondsPassed: Single);
    procedure StartFallKick(const Delta: Single);
    procedure UpdateViewEffects(const SecondsPassed: Single);
    { Base view: the camera view without the applied effects }
    procedure UndoEffects(var Dir, Up: TVector3);
    procedure CategorizeWater(const Pos: TVector3);
    { A ladder brush right in front of the player (PM_CatagorizePosition's
      ladder trace, done with point contents) }
    function TouchingLadder(const Pos: TVector3): Boolean;
    procedure LadderMove(const Pos: TVector3; const SecondsPassed: Single);
    procedure WaterMove(const Pos: TVector3; const SecondsPassed: Single);
    function EyeHeight: Single;
    { Box top above the eye: Quake 2 maxs.z 32 (ducked 4) above the origin }
    function HeadRoom: Single;
    { Player box at eye position Pos, its bottom raised by BottomLift }
    function PlayerBox(const Pos: TVector3; const BottomLift: Single): TBox3D;
    { Is there room to move the head from Pos up by Dy (> 0)? }
    function RoomAbove(const Pos: TVector3; const Dy: Single): Boolean;
    { Height of the eye above the ground below Pos (huge if no ground).
      With box collision, the highest ground under the box centre or corners
      (you stand on a ledge until the whole box is off it, like Quake 2). }
    function HeightAboveGround(const Pos: TVector3): Single;
    procedure Accelerate(const WishDir: TVector3; const WishSpeed, Accel, SecondsPassed: Single);
    procedure ApplyFriction(const SecondsPassed: Single);
    function TryHorizontalMove(const Pos: TVector3; const Delta: TVector3): TVector3;
    procedure ApplyTurn;
  public
    { Input for this frame, set by the view: -1..1 }
    InputForward, InputSide: Single;
    InputJump, InputCrouch: Boolean;
    { Degrees to turn this frame (gamepad look): yaw left, pitch up; applied
      to the view without effects, then cleared }
    InputYaw, InputPitch: Single;
    { Temporarily frozen (dead, intermission) }
    Suspended: Boolean;
    constructor Create(AOwner: TComponent); override;
    function PropertySections(const PropertyName: String): TPropertySections; override;
    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;
    { Forget the velocity (after teleports, level loads, respawn) }
    procedure ResetVelocity;
    { Restore the camera to the view without effects and forget them (before
      moving or turning the camera from code: teleports, autotest actions) }
    procedure ClearViewEffects;
    { Quake 2 P_DamageFeedback view kick: tilt away from where the damage
      came from (FromPos in world space), decaying in 0.5 s }
    procedure DamageKick(const Amount: Integer; const FromPos: TVector3; const Health: Integer);
    { Eye position and view direction without bob and kicks: aim and use
      with these, like Quake 2 uses viewangles, not the kicked view }
    function AimPosition: TVector3;
    function AimDirection: TVector3;
    { Weapon angles in degrees (X pitch down, Y yaw left, Z roll) for the
      view weapon: bob while walking and lag behind turning }
    property GunAngles: TVector3 read FGunAngles;
    { View pitch (down) and roll in degrees added this frame }
    property ViewKickPitch: Single read FAppliedPitch;
    property ViewKickRoll: Single read FAppliedRoll;
    { Throw the player (trigger_push, explosions) }
    procedure AddVelocity(const V: TVector3);
    { Pmove velocity in CGE units per second }
    property Velocity: TVector3 read FVelocity write FVelocity;
    property OnFallDamage: TFallDamageEvent read FOnFallDamage write FOnFallDamage;
    property OnLandSound: TNotifyEvent read FOnLandSound write FOnLandSound;
    property OnPointContents: TPointContentsEvent read FOnPointContents write FOnPointContents;
    { Box traces for Quake 2's pmove (PM_StepSlideMove against the BSP
      brushes, movers and monsters). Without it the player collides with
      the scene through approximate overlap tests (editor, tests). }
    property OnTrace: TPlayerTraceEvent read FOnTrace write FOnTrace;
    { Called right before each move: movers carry / push the player here,
      so the move starts from where they left him }
    property OnBeforeMove: TNotifyEvent read FOnBeforeMove write FOnBeforeMove;
    { What the player stands on (nil: the world or nothing; a mover / monster) }
    property GroundObject: TObject read FGroundObject;
    { Moves that started inside a solid (and were nudged out); demo log }
    property StuckCount: Integer read FStuckCount;
    { The player's box (Quake coordinates, around Origin) and origin }
    function BoxMins: TVector3;
    function BoxMaxs: TVector3;
    function Origin: TVector3;
    { Move the player by Delta (CGE), e.g. carried by a platform }
    procedure Push(const Delta: TVector3);
    { Move the player out of solids to the nearest free spot within MaxDist
      units (after placing the camera from code); False if none found }
    function SnapToFreeSpace(const MaxDist: Single = 128): Boolean;
    { Contents bits of the liquid the player is in (0 = none) }
    property WaterType: Integer read FWaterType;
  published
    { 0 = not in liquid, 1 = feet, 2 = waist (swimming), 3 = eyes under }
    property WaterLevel: Integer read FWaterLevel;
    property OnLadder: Boolean read FOnLadder;
    property WaterSpeed: Single read FWaterSpeed write FWaterSpeed;
    { Read-only state, visible in the inspector }
    property OnGround: Boolean read FOnGround;
    property Crouched: Boolean read FCrouched;
    property Noclip: Boolean read FNoclip write FNoclip default False;
    { False: don't move the player; use TCastleWalkNavigation's movement instead }
    property Active: Boolean read FActive write FActive default True;
    { Quake 2 pmove constants }
    property RunSpeed: Single read FRunSpeed write FRunSpeed;
    property CrouchSpeed: Single read FCrouchSpeed write FCrouchSpeed;
    property AccelerateRate: Single read FAccelerate write FAccelerate;
    property AirAccelerateRate: Single read FAirAccelerate write FAirAccelerate;
    property Friction: Single read FFriction write FFriction;
    property StopSpeed: Single read FStopSpeed write FStopSpeed;
    property GravityAcceleration: Single read FGravity write FGravity;
    property JumpSpeed: Single read FJumpSpeed write FJumpSpeed;
    property StepSize: Single read FStepSize write FStepSize;
    { Sphere radius, used when BoxCollision is False }
    property Radius: Single read FRadius write FRadius;
    { Collide with Quake 2's player box (32 x 32 x 56, ducked 32 high)
      instead of a sphere at the eye }
    property BoxCollision: Boolean read FBoxCollision write FBoxCollision default True;
    { Half of the box width (Quake 2: 16) }
    property HalfWidth: Single read FHalfWidth write FHalfWidth;
    property StandEyeHeight: Single read FEyeHeight write FEyeHeight;
    property CrouchEyeHeight: Single read FCrouchEyeHeight write FCrouchEyeHeight;
    { View and weapon bob, landing dip and damage kicks (Quake 2's bob_up,
      bob_pitch, bob_roll, run_pitch, run_roll) }
    property ViewBob: Boolean read FViewBob write FViewBob default True;
  end;

implementation

uses
  CastleComponentSerialize, CastleUtils, CastleStringUtils;

constructor TQuakePlayerMovement.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { Quake 2 defaults (pm_maxspeed, pm_duckspeed, pm_accelerate, pm_friction...) }
  FActive := True;
  FViewBob := True;
  FRunSpeed := 300;
  FCrouchSpeed := 100;
  FAccelerate := 10;
  FAirAccelerate := 1;
  FFriction := 6;
  FStopSpeed := 100;
  FGravity := 800;
  FJumpSpeed := 270;
  FStepSize := 18;
  FRadius := 14;
  FBoxCollision := True;
  FHalfWidth := 16;
  FEyeHeight := 46;       { origin 24 above the feet + viewheight 22 }
  FCrouchEyeHeight := 22; { ducked: origin 24 + viewheight -2 }
  FWaterSpeed := 400 * 0.5; { pm_waterspeed, halved by PM_WaterMove }
  FWaterFriction := 1;
  FWaterSink := 60;
  FViewZ := FEyeHeight - 24;
end;

function TQuakePlayerMovement.PropertySections(const PropertyName: String): TPropertySections;
begin
  if ArrayContainsString(PropertyName, ['Active', 'OnGround', 'Crouched', 'Noclip', 'RunSpeed',
    'JumpSpeed', 'GravityAcceleration', 'StepSize', 'BoxCollision']) then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

function TQuakePlayerMovement.EyeHeight: Single;
begin
  if FCrouched then
    Result := FCrouchEyeHeight
  else
    Result := FEyeHeight;
end;

function TQuakePlayerMovement.HeadRoom: Single;
begin
  if FCrouched then
    Result := 6   { origin 24 + maxs 4 - eye 22 }
  else
    Result := 10; { origin 24 + maxs 32 - eye 46 }
end;

function TQuakePlayerMovement.PlayerBox(const Pos: TVector3; const BottomLift: Single): TBox3D;
var
  H: Single;
begin
  { A hair smaller than the Quake 2 box, so touching a wall isn't a collision
    and 32-unit gaps stay passable }
  H := FHalfWidth - 0.25;
  Result := Box3D(
    Pos + Vector3(-H, BottomLift - EyeHeight, -H),
    Pos + Vector3( H, HeadRoom, H));
end;

function TQuakePlayerMovement.RoomAbove(const Pos: TVector3; const Dy: Single): Boolean;
var
  H: Single;
begin
  if not FBoxCollision then
    Exit(not World.WorldSegmentCollision(Pos, Pos + Vector3(0, Dy + FRadius, 0)));
  H := FHalfWidth - 0.25;
  Result := not World.WorldBoxCollision(Box3D(
    Pos + Vector3(-H, HeadRoom, -H),
    Pos + Vector3( H, HeadRoom + Dy + 0.25, H)));
end;

function TQuakePlayerMovement.HeightAboveGround(const Pos: TVector3): Single;

  function RayAbove(const P: TVector3): Single;
  var
    Ground: PTriangle;
  begin
    if not World.WorldHeight(P, Result, Ground) then
      Result := 100000;
  end;

var
  H: Single;
begin
  if World = nil then
    Exit(100000);
  Result := RayAbove(Pos);
  { Corners only matter when the centre has no ground within a step }
  if FBoxCollision and (Result > EyeHeight + FStepSize) then
  begin
    H := FHalfWidth - 1;
    Result := Min(Result, RayAbove(Pos + Vector3(-H, 0, -H)));
    Result := Min(Result, RayAbove(Pos + Vector3( H, 0, -H)));
    Result := Min(Result, RayAbove(Pos + Vector3(-H, 0,  H)));
    Result := Min(Result, RayAbove(Pos + Vector3( H, 0,  H)));
  end;
end;

procedure TQuakePlayerMovement.ResetVelocity;
begin
  FVelocity := TVector3.Zero;
  { The camera was just placed: its view has no effects applied }
  FAppliedOffset := TVector3.Zero;
  FAppliedPitch := 0;
  FAppliedRoll := 0;
  FFallTime := 0;
  FDamageTime := 0;
  FBobTime := 0;
  FHasLastAngles := False;
  FCrouched := False;
  FViewZ := PMViewHeight;
  FStepOffset := 0;
  FLandTime := 0;
  FGroundObject := nil;
end;

procedure TQuakePlayerMovement.AddVelocity(const V: TVector3);
begin
  FVelocity := FVelocity + V;
  if V.Y > 0 then
    FOnGround := False;
end;

procedure TQuakePlayerMovement.ApplyFriction(const SecondsPassed: Single);
var
  Speed, Drop, NewSpeed: Single;
begin
  { PM_Friction: only on the ground, horizontal velocity }
  Speed := Sqrt(Sqr(FVelocity.X) + Sqr(FVelocity.Z));
  if Speed < 1 then
  begin
    FVelocity.X := 0;
    FVelocity.Z := 0;
    Exit;
  end;
  Drop := Max(Speed, FStopSpeed) * FFriction * SecondsPassed;
  NewSpeed := Max(0, Speed - Drop) / Speed;
  FVelocity.X := FVelocity.X * NewSpeed;
  FVelocity.Z := FVelocity.Z * NewSpeed;
end;

procedure TQuakePlayerMovement.Accelerate(const WishDir: TVector3;
  const WishSpeed, Accel, SecondsPassed: Single);
var
  CurrentSpeed, AddSpeed, AccelSpeed: Single;
begin
  { PM_Accelerate }
  CurrentSpeed := TVector3.DotProduct(FVelocity, WishDir);
  AddSpeed := WishSpeed - CurrentSpeed;
  if AddSpeed <= 0 then
    Exit;
  AccelSpeed := Min(AddSpeed, Accel * SecondsPassed * WishSpeed);
  FVelocity := FVelocity + WishDir * AccelSpeed;
end;

function TQuakePlayerMovement.TryHorizontalMove(const Pos: TVector3; const Delta: TVector3): TVector3;

  { Move the box (its bottom StepSize up, so it passes over stairs) or the
    eye sphere (with wall sliding); then refuse it if the ground at the new
    place rises more than StepSize }
  function Attempt(const D: TVector3; out NewPos: TVector3): Boolean;
  var
    Rise: Single;
  begin
    if FBoxCollision then
    begin
      NewPos := Pos + D;
      Result := not World.WorldBoxCollision(PlayerBox(NewPos, FStepSize));
    end else
      Result := World.WorldMoveAllowed(Pos, Pos + D, NewPos, True, FRadius,
        TBox3D.Empty, TBox3D.Empty, False);
    if not Result then
      Exit;
    Rise := EyeHeight - HeightAboveGround(NewPos);
    if Rise > FStepSize + 0.5 then
      Exit(False);
    { Step up stairs }
    if (Rise > 0) and FOnGround then
      NewPos.Y := NewPos.Y + Rise;
  end;

var
  NewPos: TVector3;
begin
  Result := Pos;
  if Delta.IsPerfectlyZero then
    Exit;
  if Attempt(Delta, NewPos) then
    Exit(NewPos);
  { Blocked by a low obstacle: try the axes separately (simple clip velocity) }
  if Attempt(Vector3(Delta.X, 0, 0), NewPos) then
  begin
    FVelocity.Z := 0;
    Exit(NewPos);
  end;
  if Attempt(Vector3(0, 0, Delta.Z), NewPos) then
  begin
    FVelocity.X := 0;
    Exit(NewPos);
  end;
  FVelocity.X := 0;
  FVelocity.Z := 0;
end;

procedure TQuakePlayerMovement.CategorizeWater(const Pos: TVector3);
const
  MASK_LIQUID = 8 or 16 or 32;
var
  Feet: TVector3;
  C: Integer;
begin
  { PM_CatagorizePosition: sample at the feet, waist and eyes }
  FWaterLevel := 0;
  FWaterType := 0;
  if not Assigned(FOnPointContents) then
    Exit;
  Feet := Pos - Vector3(0, EyeHeight - 1, 0);
  C := FOnPointContents(Feet);
  if (C and MASK_LIQUID) = 0 then
    Exit;
  FWaterType := C and MASK_LIQUID;
  FWaterLevel := 1;
  if (FOnPointContents(Pos - Vector3(0, EyeHeight / 2, 0)) and MASK_LIQUID) <> 0 then
  begin
    FWaterLevel := 2;
    if (FOnPointContents(Pos) and MASK_LIQUID) <> 0 then
      FWaterLevel := 3;
  end;
end;

procedure TQuakePlayerMovement.WaterMove(const Pos: TVector3; const SecondsPassed: Single);
var
  Dir, Right, WishVel, NewPos: TVector3;
  WishSpeed, Speed, Drop: Single;
begin
  { PM_WaterMove: swim in the view direction (including pitch), sink slowly
    without input, jump swims up }
  Dir := Parent.Direction;
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0)).Normalize;
  WishVel := Dir * InputForward + Right * InputSide;
  if InputJump then
    WishVel.Y := WishVel.Y + 1;
  if (InputForward = 0) and (InputSide = 0) and not InputJump then
    WishVel.Y := WishVel.Y - FWaterSink / FWaterSpeed;
  WishSpeed := Min(1, WishVel.Length) * FWaterSpeed;

  { Water friction, scaled by how deep we are }
  Speed := FVelocity.Length;
  if Speed > 0.1 then
  begin
    Drop := Speed * FFriction * FWaterFriction * FWaterLevel * SecondsPassed * 0.5;
    FVelocity := FVelocity * (Max(0, Speed - Drop) / Speed);
  end;
  if WishVel.Length > 0.001 then
    Accelerate(WishVel.Normalize, WishSpeed, FAccelerate, SecondsPassed);

  NewPos := TryHorizontalMove(Pos, Vector3(FVelocity.X, 0, FVelocity.Z) * SecondsPassed);
  if (FVelocity.Y <= 0) or RoomAbove(NewPos, FVelocity.Y * SecondsPassed) then
    NewPos.Y := NewPos.Y + FVelocity.Y * SecondsPassed
  else
    FVelocity.Y := 0;
  { Don't sink through the bottom }
  if HeightAboveGround(NewPos) < EyeHeight then
    NewPos.Y := NewPos.Y + (EyeHeight - HeightAboveGround(NewPos));
  Parent.Translation := NewPos;
  FOnGround := False;
end;

function TQuakePlayerMovement.TouchingLadder(const Pos: TVector3): Boolean;
const
  CONTENTS_LADDER = $20000000;
var
  Forward, Probe: TVector3;
  Heights: array[0..1] of Single;
  Dists: array[0..3] of Single;
  I, J: Integer;
begin
  Result := False;
  if not Assigned(FOnPointContents) then
    Exit;
  Forward := Vector3(Parent.Direction.X, 0, Parent.Direction.Z);
  if Forward.Length < 0.001 then
    Exit;
  Forward := Forward.Normalize;
  { Probe just beyond the collision sphere, at waist and at the eyes }
  { Ladders are usually thin player-clip brushes (no visible faces), so check
    at the player and at a few distances ahead }
  Heights[0] := EyeHeight / 2;
  Heights[1] := 4;
  Dists[0] := 0;
  Dists[1] := 8;
  Dists[2] := FRadius + 2;
  Dists[3] := FRadius + 8;
  for I := 0 to High(Heights) do
    for J := 0 to High(Dists) do
    begin
      Probe := Pos + Forward * Dists[J] - Vector3(0, Heights[I], 0);
      if (FOnPointContents(Probe) and CONTENTS_LADDER) <> 0 then
        Exit(True);
    end;
end;

procedure TQuakePlayerMovement.LadderMove(const Pos: TVector3; const SecondsPassed: Single);
const
  ClimbSpeed = 200;
  SinPitch15 = 0.2588;
var
  Dir, Forward, Right, WishVel, NewPos: TVector3;
  WantY, Above: Single;
begin
  { PM_AirMove ladder rules: forward + looking up climbs, forward + looking
    down descends, jump / crouch climb / descend; no gravity; slow sideways }
  Dir := Parent.Direction;
  if (InputForward > 0) and (Dir.Y >= SinPitch15) then
    WantY := ClimbSpeed
  else
  if (InputForward > 0) and (Dir.Y <= -SinPitch15) then
    WantY := -ClimbSpeed
  else
  if InputJump then
    WantY := ClimbSpeed
  else
  if InputCrouch then
    WantY := -ClimbSpeed
  else
    WantY := 0;

  Forward := Vector3(Dir.X, 0, Dir.Z).Normalize;
  Right := TVector3.CrossProduct(Forward, Vector3(0, 1, 0)).Normalize;
  WishVel := (Forward * InputForward + Right * InputSide) * FRunSpeed;
  FVelocity.X := EnsureRange(WishVel.X, -25, 25);
  FVelocity.Z := EnsureRange(WishVel.Z, -25, 25);
  FVelocity.Y := WantY;

  NewPos := TryHorizontalMove(Pos, Vector3(FVelocity.X, 0, FVelocity.Z) * SecondsPassed);
  if FVelocity.Y > 0 then
  begin
    if RoomAbove(NewPos, FVelocity.Y * SecondsPassed) then
      NewPos.Y := NewPos.Y + FVelocity.Y * SecondsPassed;
  end else
  if FVelocity.Y < 0 then
  begin
    Above := HeightAboveGround(NewPos);
    NewPos.Y := NewPos.Y - Min(-FVelocity.Y * SecondsPassed, Max(0, Above - EyeHeight));
  end;
  Parent.Translation := NewPos;
  FOnGround := HeightAboveGround(NewPos) <= EyeHeight + 2;
end;

procedure TQuakePlayerMovement.Update(const SecondsPassed: Single; var RemoveMe: TRemoveType);
begin
  inherited Update(SecondsPassed, RemoveMe);
  if (not FActive) or Suspended or (Parent = nil) or (World = nil) or (SecondsPassed <= 0) then
    Exit;
  ClearViewEffects;
  ApplyTurn;
  if Assigned(FOnBeforeMove) then
    FOnBeforeMove(Self);
  Move(SecondsPassed);
  UpdateViewEffects(SecondsPassed);
end;

procedure TQuakePlayerMovement.ApplyTurn;
const
  { Keep the view away from straight up / down, like mouse look }
  MaxPitch = 89;
var
  Dir, Side: TVector3;
  Pitch, NewPitch: Single;
begin
  if (InputYaw = 0) and (InputPitch = 0) then
    Exit;
  Dir := Parent.Direction;
  if InputYaw <> 0 then
    Dir := RotatePointAroundAxisRad(DegToRad(InputYaw), Dir, Vector3(0, 1, 0));
  if InputPitch <> 0 then
  begin
    Pitch := RadToDeg(ArcSin(EnsureRange(Dir.Normalize.Y, -1, 1)));
    NewPitch := EnsureRange(Pitch + InputPitch, -MaxPitch, MaxPitch);
    Side := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
    if not Side.IsZero then
      Dir := RotatePointAroundAxisRad(DegToRad(NewPitch - Pitch), Dir, Side);
  end;
  Parent.SetView(Dir, Vector3(0, 1, 0));
  InputYaw := 0;
  InputPitch := 0;
end;

{ Trace-based pmove (Quake 2 pmove.c), in Quake coordinates }

function QV(const C: TVector3): TVector3; inline;
begin
  Result := Vector3(C.X, -C.Z, C.Y);
end;

function CV(const Q: TVector3): TVector3; inline;
begin
  Result := Vector3(Q.X, Q.Z, -Q.Y);
end;

const
  PM_STOP_EPSILON = 0.1;
  PM_MIN_STEP_NORMAL = 0.7;
  PM_MAX_CLIP_PLANES = 5;
  PM_CONTENTS_LADDER = $20000000;
  PM_MASK_LIQUID = 8 or 16 or 32;
  PM_CONTENTS_LAVA = 8;
  PM_CONTENTS_SLIME = 16;
  PM_CONTENTS_WATER = 32;
  PM_MASK_PLAYERSOLID = 1 or 2 or $10000 or $2000000;

function TQuakePlayerMovement.BoxMins: TVector3;
begin
  Result := PMMins;
end;

function TQuakePlayerMovement.BoxMaxs: TVector3;
begin
  Result := PMMaxs;
end;

function TQuakePlayerMovement.Origin: TVector3;
begin
  if Parent = nil then
    Exit(TVector3.Zero);
  Result := QV(Parent.Translation - FAppliedOffset) - Vector3(0, 0, FViewZ - FStepOffset);
end;

procedure TQuakePlayerMovement.Push(const Delta: TVector3);
begin
  if Parent <> nil then
    Parent.Translation := Parent.Translation + Delta;
end;

function TQuakePlayerMovement.PMMins: TVector3;
begin
  Result := Vector3(-FHalfWidth, -FHalfWidth, -24);
end;

function TQuakePlayerMovement.PMMaxs: TVector3;
begin
  if FCrouched then
    Result := Vector3(FHalfWidth, FHalfWidth, 4)
  else
    Result := Vector3(FHalfWidth, FHalfWidth, 32);
end;

function TQuakePlayerMovement.PMViewHeight: Single;
begin
  { Origin to eye: standing 22, ducked -2 (origin 24 above the feet) }
  Result := EyeHeight - 24;
end;

function TQuakePlayerMovement.PMTrace(const Start, Stop: TVector3): TQuakeTrace;
begin
  Result := FOnTrace(Start, Stop, PMMins, PMMaxs, PM_MASK_PLAYERSOLID);
end;

function TQuakePlayerMovement.PMGoodPosition(const Org: TVector3): Boolean;
begin
  Result := not PMTrace(Org, Org).AllSolid;
end;

function TQuakePlayerMovement.PMFindFree(const MaxDist: Single): Boolean;
var
  R: Single;
  DX, DY, DZ: Integer;
  Off: TVector3;
begin
  if PMGoodPosition(FOrg) then
    Exit(True);
  R := 1;
  while R <= MaxDist do
  begin
    { Up first, then the 26 directions around }
    if PMGoodPosition(FOrg + Vector3(0, 0, R)) then
    begin
      FOrg := FOrg + Vector3(0, 0, R);
      Exit(True);
    end;
    for DZ := 1 downto -1 do
      for DX := -1 to 1 do
        for DY := -1 to 1 do
          if (DX <> 0) or (DY <> 0) or (DZ <> 0) then
          begin
            Off := Vector3(DX, DY, DZ).Normalize * R;
            if PMGoodPosition(FOrg + Off) then
            begin
              FOrg := FOrg + Off;
              Exit(True);
            end;
          end;
    R := R * 1.5;
  end;
  Result := False;
end;

function TQuakePlayerMovement.SnapToFreeSpace(const MaxDist: Single): Boolean;
begin
  if (Parent = nil) or not Assigned(FOnTrace) then
    Exit(False);
  FOrg := Origin;
  Result := PMFindFree(MaxDist);
  if Result then
    Parent.Translation := CV(FOrg + Vector3(0, 0, FViewZ - FStepOffset)) + FAppliedOffset;
end;

procedure TQuakePlayerMovement.PMUnstick;
const
  Dists: array[0..5] of Single = (1, 2, 4, 8, 16, 24);
  Dirs: array[0..5] of TVector3 = ((X: 0; Y: 0; Z: 1), (X: 1; Y: 0; Z: 0), (X: -1; Y: 0; Z: 0),
    (X: 0; Y: 1; Z: 0), (X: 0; Y: -1; Z: 0), (X: 0; Y: 0; Z: -1));
var
  D, I: Integer;
begin
  { Started inside a solid (spawned in a wall, pushed by a mover): find the
    nearest free spot, like Quake 2's PM_InitialSnapPosition but further }
  if PMGoodPosition(FOrg) then
    Exit;
  Inc(FStuckCount);
  for D := 0 to High(Dists) do
    for I := 0 to High(Dirs) do
      if PMGoodPosition(FOrg + Dirs[I] * Dists[D]) then
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

procedure TQuakePlayerMovement.PMSlideMove(const Dt: Single);
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

procedure TQuakePlayerMovement.PMStepSlideMove(const Dt: Single);
var
  StartO, StartV, DownO, DownV, Up, Down: TVector3;
  T: TQuakeTrace;
  DownDist, UpDist: Single;
begin
  { PM_StepSlideMove: slide; then try again from StepSize higher and keep
    whichever got further (walks up stairs) }
  StartO := FOrg;
  StartV := FVel;
  PMSlideMove(Dt);
  DownO := FOrg;
  DownV := FVel;

  Up := StartO + Vector3(0, 0, FStepSize);
  T := PMTrace(Up, Up);
  if T.AllSolid then
    Exit; { can't step up }

  FOrg := Up;
  FVel := StartV;
  PMSlideMove(Dt);
  { Push down the final amount }
  Down := FOrg - Vector3(0, 0, FStepSize);
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

procedure TQuakePlayerMovement.PMCategorizePosition;
var
  Point: TVector3;
  T: TQuakeTrace;
  Sample1, Sample2: Single;
  C: Integer;
begin
  { PM_CatagorizePosition: on ground if a 0.25 unit trace down hits a
    walkable plane (normal z >= 0.7) }
  Point := FOrg - Vector3(0, 0, 0.25);
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
  Sample1 := PMViewHeight - PMMins.Z;
  Sample2 := Sample1 / 2;
  Point := FOrg + Vector3(0, 0, PMMins.Z + 1);
  C := FOnPointContents(CV(Point));
  if (C and PM_MASK_LIQUID) <> 0 then
  begin
    FWaterType := C and PM_MASK_LIQUID;
    FWaterLevel := 1;
    Point.Z := FOrg.Z + PMMins.Z + Sample2;
    if (FOnPointContents(CV(Point)) and PM_MASK_LIQUID) <> 0 then
    begin
      FWaterLevel := 2;
      Point.Z := FOrg.Z + PMMins.Z + Sample1;
      if (FOnPointContents(CV(Point)) and PM_MASK_LIQUID) <> 0 then
        FWaterLevel := 3;
    end;
  end;
end;

procedure TQuakePlayerMovement.PMCheckDuck;
begin
  { PM_CheckDuck: duck on the ground; stand up when there is room }
  if InputCrouch and FOnGround then
    FCrouched := True
  else
  if FCrouched then
  begin
    FCrouched := False;
    if PMTrace(FOrg, FOrg).AllSolid then
      FCrouched := True;
  end;
end;

procedure TQuakePlayerMovement.PMFriction(const Dt: Single);
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
    Control := Max(Speed, FStopSpeed);
    Drop := Drop + Control * FFriction * Dt;
  end;
  if (FWaterLevel > 0) and not FOnLadder then
    Drop := Drop + Speed * FWaterFriction * FWaterLevel * Dt;
  NewSpeed := Max(0, Speed - Drop) / Speed;
  FVel := FVel * NewSpeed;
end;

procedure TQuakePlayerMovement.PMAccelerate(const WishDir: TVector3; const WishSpeed, Accel, Dt: Single);
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

procedure TQuakePlayerMovement.PMCheckJump;
begin
  { PM_CheckJump }
  if FLandTime > 0 then
    Exit;
  if not InputJump then
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
  FVel.Z := Max(FVel.Z + FJumpSpeed, FJumpSpeed);
end;

procedure TQuakePlayerMovement.PMMove(const Dt: Single);
const
  SinPitch15 = 0.2588;
  MoveScale = 400; { cl_forwardspeed / cl_sidespeed with always run }
var
  DirQ, Forward, Right, WishVel, WishDir: TVector3;
  FMove, SMove, WishSpeed, MaxSpeed, PreVelZ, FallSpeed, Delta, Rise, TargetView, StartZ: Single;
  WasOnGround: Boolean;
  T: TQuakeTrace;
begin
  FOrg := QV(Parent.Translation) - Vector3(0, 0, FViewZ - FStepOffset);
  FVel := QV(FVelocity);
  PMUnstick;
  StartZ := FOrg.Z;

  PMCheckDuck;
  WasOnGround := FOnGround;
  PMCategorizePosition;
  if FLandTime > 0 then
    FLandTime := Max(0, FLandTime - Dt);

  DirQ := QV(Parent.Direction);
  Forward := Vector3(DirQ.X, DirQ.Y, 0);
  if Forward.Length < 0.001 then
    Forward := Vector3(1, 0, 0);
  Forward := Forward.Normalize;
  Right := Vector3(Forward.Y, -Forward.X, 0);

  { PM_CheckSpecialMovement: a ladder brush just in front }
  T := FOnTrace(FOrg, FOrg + Forward, PMMins, PMMaxs, PM_MASK_PLAYERSOLID or PM_CONTENTS_LADDER);
  FOnLadder := (T.Fraction < 1) and ((T.Contents and PM_CONTENTS_LADDER) <> 0);

  PMCheckJump;
  PMFriction(Dt);
  PreVelZ := FVel.Z;

  FMove := InputForward * MoveScale;
  SMove := InputSide * MoveScale;
  if FCrouched then
    MaxSpeed := FCrouchSpeed
  else
    MaxSpeed := FRunSpeed;

  if FWaterLevel >= 2 then
  begin
    { PM_WaterMove: swim along the view, sink slowly without input }
    WishVel := DirQ * FMove + Right * SMove;
    if (FMove = 0) and (SMove = 0) and not InputJump and not InputCrouch then
      WishVel.Z := WishVel.Z - FWaterSink
    else
    if InputJump then
      WishVel.Z := WishVel.Z + 200
    else
    if InputCrouch then
      WishVel.Z := WishVel.Z - 200;
    WishSpeed := WishVel.Length;
    if WishSpeed > MaxSpeed then
      WishSpeed := MaxSpeed;
    WishSpeed := WishSpeed * 0.5;
    if WishVel.Length > 0.001 then
      PMAccelerate(WishVel.Normalize, WishSpeed, FAccelerate, Dt);
    PMStepSlideMove(Dt);
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
      if InputJump then
        WishVel.Z := 200
      else
      if InputCrouch then
        WishVel.Z := -200;
      WishVel.X := EnsureRange(WishVel.X, -25, 25);
      WishVel.Y := EnsureRange(WishVel.Y, -25, 25);
    end;
    WishSpeed := WishVel.Length;
    if WishSpeed > 0.001 then
      WishDir := WishVel / WishSpeed
    else
      WishDir := TVector3.Zero;
    if WishSpeed > MaxSpeed then
      WishSpeed := MaxSpeed;

    if FOnLadder then
    begin
      PMAccelerate(WishDir, WishSpeed, FAccelerate, Dt);
      if WishVel.Z = 0 then
      begin
        if FVel.Z > 0 then
          FVel.Z := Max(0, FVel.Z - FGravity * Dt)
        else
          FVel.Z := Min(0, FVel.Z + FGravity * Dt);
      end;
      PMStepSlideMove(Dt);
    end else
    if FOnGround then
    begin
      FVel.Z := 0;
      PMAccelerate(WishDir, WishSpeed, FAccelerate, Dt);
      FVel.Z := 0;
      if (FVel.X <> 0) or (FVel.Y <> 0) then
        PMStepSlideMove(Dt);
    end else
    begin
      PMAccelerate(WishDir, WishSpeed, FAirAccelerate, Dt);
      FVel.Z := FVel.Z - FGravity * Dt;
      PMStepSlideMove(Dt);
    end;
  end;

  Rise := FOrg.Z - StartZ;
  PMCategorizePosition;

  { Landing: Quake 2 P_FallingDamage (less in water) }
  if FOnGround and not WasOnGround and (PreVelZ < 0) then
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
    StartFallKick(Delta);
    if (Delta > 30) and Assigned(FOnFallDamage) then
      FOnFallDamage(Max(1, Round((Delta - 30) / 2)))
    else
    if (Delta >= 15) and Assigned(FOnLandSound) then
      FOnLandSound(Self);
  end;

  { Smooth the view over steps up (Quake 2 client predicted_step) }
  if WasOnGround and FOnGround and (Rise > 4) and (Rise <= FStepSize + 2) then
    FStepOffset := Min(FStepSize, FStepOffset + Rise);
  FStepOffset := Max(0, FStepOffset - Dt * FStepSize * 10);
  { The eye follows ducking within 0.1 s, like Quake 2's viewoffset lerp }
  TargetView := PMViewHeight;
  if FViewZ < TargetView then
    FViewZ := Min(TargetView, FViewZ + 240 * Dt)
  else
    FViewZ := Max(TargetView, FViewZ - 240 * Dt);

  Parent.Translation := CV(FOrg + Vector3(0, 0, FViewZ - FStepOffset));
  FVelocity := CV(FVel);
end;

procedure TQuakePlayerMovement.Move(const SecondsPassed: Single);
var
  Pos, Forward, Right, WishVel, WishDir, NewPos: TVector3;
  WishSpeed, Above, Dt, FallSpeed, Delta: Single;
  Dir: TVector3;
  WasOnGround: Boolean;
begin
  { Large steps (loading hitches) would tunnel through floors }
  Dt := Min(SecondsPassed, 0.05);
  Pos := Parent.Translation;
  Dir := Parent.Direction;

  if FNoclip then
  begin
    Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0)).Normalize;
    Parent.Translation := Pos + (Dir * InputForward + Right * InputSide) * FRunSpeed * 1.5 * Dt;
    FVelocity := TVector3.Zero;
    Exit;
  end;

  if Assigned(FOnTrace) then
  begin
    PMMove(Dt);
    Exit;
  end;

  { Crouch: stand up only if there is room above }
  if InputCrouch then
    FCrouched := True
  else
  if FCrouched and RoomAbove(Pos, FEyeHeight - FCrouchEyeHeight + 4) then
    FCrouched := False;

  CategorizeWater(Pos);
  if FWaterLevel >= 2 then
  begin
    WaterMove(Pos, Dt);
    Exit;
  end;

  { On a ladder unless just standing at its foot without input }
  FOnLadder := TouchingLadder(Pos);
  if FOnLadder and ((InputForward <> 0) or InputJump or InputCrouch or not FOnGround) then
  begin
    LadderMove(Pos, Dt);
    Exit;
  end;

  Above := HeightAboveGround(Pos);
  WasOnGround := FOnGround;
  FOnGround := (Above <= EyeHeight + 2) and (FVelocity.Y <= 0);

  { Wish direction from the view, flattened (PM_AirMove / PM_WalkMove) }
  Forward := Vector3(Dir.X, 0, Dir.Z);
  if Forward.Length < 0.001 then
    Forward := Vector3(0, 0, -1);
  Forward := Forward.Normalize;
  Right := TVector3.CrossProduct(Forward, Vector3(0, 1, 0)).Normalize;
  WishVel := Forward * InputForward + Right * InputSide;
  if WishVel.Length > 1 then
    WishVel := WishVel.Normalize;
  if FCrouched then
    WishSpeed := FCrouchSpeed * WishVel.Length
  else
    WishSpeed := FRunSpeed * WishVel.Length;
  if WishVel.Length > 0.001 then
    WishDir := WishVel.Normalize
  else
    WishDir := TVector3.Zero;

  if FOnGround then
  begin
    ApplyFriction(Dt);
    Accelerate(WishDir, WishSpeed, FAccelerate, Dt);
    { Jump needs the key released in between (PM_CheckJump) }
    if InputJump and not FJumpHeld and not FCrouched then
    begin
      FVelocity.Y := Max(FVelocity.Y, FJumpSpeed);
      FOnGround := False;
      FJumpHeld := True;
    end;
  end else
  begin
    Accelerate(WishDir, WishSpeed, FAirAccelerate, Dt);
    FVelocity.Y := FVelocity.Y - FGravity * Dt;
  end;
  if not InputJump then
    FJumpHeld := False;

  { Horizontal move with walls, steps }
  NewPos := TryHorizontalMove(Pos, Vector3(FVelocity.X, 0, FVelocity.Z) * Dt);

  { Vertical move }
  if FVelocity.Y > 0 then
  begin
    { Going up: stop at ceilings }
    if not RoomAbove(NewPos, FVelocity.Y * Dt) then
      FVelocity.Y := 0
    else
      NewPos.Y := NewPos.Y + FVelocity.Y * Dt;
  end else
  begin
    Above := HeightAboveGround(NewPos);
    if FOnGround then
    begin
      { Walking down stairs and slopes: stick to the ground }
      if (Above > EyeHeight) and (Above <= EyeHeight + FStepSize) then
        NewPos.Y := NewPos.Y - (Above - EyeHeight)
      else
      if Above > EyeHeight + FStepSize then
        FOnGround := False; { walked off a ledge }
      FVelocity.Y := 0;
    end else
    if Above + FVelocity.Y * Dt <= EyeHeight then
    begin
      { Landing }
      FallSpeed := -FVelocity.Y;
      NewPos.Y := NewPos.Y - (Above - EyeHeight);
      FVelocity.Y := 0;
      FOnGround := True;
      { P_FallingDamage: delta = speed^2 * 0.0001 }
      Delta := Sqr(FallSpeed / 10) * 0.01;
      StartFallKick(Delta);
      if (Delta > 30) and Assigned(FOnFallDamage) then
        FOnFallDamage(Max(1, Round((Delta - 30) / 2)))
      else
      if (Delta >= 15) and Assigned(FOnLandSound) then
        FOnLandSound(Self);
    end else
      NewPos.Y := NewPos.Y + FVelocity.Y * Dt;
  end;

  { Keep the eye at the right height when crouching / standing up on the ground }
  if FOnGround and WasOnGround then
  begin
    Above := HeightAboveGround(NewPos);
    if Abs(Above - EyeHeight) <= FEyeHeight - FCrouchEyeHeight + 1 then
      NewPos.Y := NewPos.Y - (Above - EyeHeight) * Min(1, Dt * 12);
  end;

  Parent.Translation := NewPos;
end;

procedure TQuakePlayerMovement.StartFallKick(const Delta: Single);
begin
  { P_FallingDamage: soft landings (delta < 15) only make a footstep }
  if Delta < 15 then
    Exit;
  FFallTime := 0.3; { FALL_TIME }
  FFallValue := Min(40, Delta * 0.5);
end;

procedure TQuakePlayerMovement.DamageKick(const Amount: Integer; const FromPos: TVector3;
  const Health: Integer);
var
  Kick, Side: Single;
  ToSource, Dir, Up, Right: TVector3;
begin
  if (Amount <= 0) or (Health <= 0) or (Parent = nil) then
    Exit;
  { P_DamageFeedback: kick = knockback * 100 / health, at least half the
    damage, at most 50; split into roll and pitch by the direction }
  Kick := Min(50, Max(Amount * 100 / Health, Amount * 0.5));
  ToSource := FromPos - AimPosition;
  if ToSource.IsZero then
    Exit;
  ToSource := ToSource.Normalize;
  Dir := Parent.Direction;
  Up := Parent.Up;
  UndoEffects(Dir, Up);
  Right := TVector3.CrossProduct(Dir, Up).Normalize;
  Side := TVector3.DotProduct(ToSource, Right);
  FDamageRoll := Kick * Side * 0.3;
  Side := -TVector3.DotProduct(ToSource, Dir);
  FDamagePitch := Kick * Side * 0.3;
  FDamageTime := 0.5; { DAMAGE_TIME }
end;

procedure TQuakePlayerMovement.UndoEffects(var Dir, Up: TVector3);
var
  Right: TVector3;
begin
  { Effects are applied as pitch around the right axis, then roll around the
    view direction: undo in reverse order }
  if FAppliedRoll <> 0 then
    Up := RotatePointAroundAxisRad(-DegToRad(FAppliedRoll), Up, Dir);
  if FAppliedPitch <> 0 then
  begin
    Right := TVector3.CrossProduct(Dir, Up).Normalize;
    Dir := RotatePointAroundAxisRad(DegToRad(FAppliedPitch), Dir, Right);
    Up := RotatePointAroundAxisRad(DegToRad(FAppliedPitch), Up, Right);
  end;
end;

procedure TQuakePlayerMovement.ClearViewEffects;
var
  Dir, Up: TVector3;
begin
  if Parent = nil then
    Exit;
  if (FAppliedPitch <> 0) or (FAppliedRoll <> 0) then
  begin
    Dir := Parent.Direction;
    Up := Parent.Up;
    UndoEffects(Dir, Up);
    Parent.SetView(Dir, Up);
  end;
  if not FAppliedOffset.IsPerfectlyZero then
    Parent.Translation := Parent.Translation - FAppliedOffset;
  FAppliedOffset := TVector3.Zero;
  FAppliedPitch := 0;
  FAppliedRoll := 0;
end;

function TQuakePlayerMovement.AimPosition: TVector3;
begin
  if Parent = nil then
    Exit(TVector3.Zero);
  Result := Parent.Translation - FAppliedOffset;
end;

function TQuakePlayerMovement.AimDirection: TVector3;
var
  Up: TVector3;
begin
  if Parent = nil then
    Exit(Vector3(0, 0, -1));
  Result := Parent.Direction;
  Up := Parent.Up;
  UndoEffects(Result, Up);
end;

procedure TQuakePlayerMovement.UpdateViewEffects(const SecondsPassed: Single);
const
  BobUp = 0.005;
  BobPitch = 0.002;
  BobRoll = 0.002;
  RunPitch = 0.002;
  RunRoll = 0.005;
var
  XYSpeed, BobMove, BobFracSin, Bob, Ratio, Delta, Pitch, Roll, Yaw, ViewPitch, Smooth: Single;
  BobOdd: Boolean;
  Dir, Up, Right, Flat, Offset: TVector3;
begin
  { Quake 2 runs this every 0.1 s server frame: rates below are per second }
  XYSpeed := Sqrt(Sqr(FVelocity.X) + Sqr(FVelocity.Z));
  if (XYSpeed < 5) or FNoclip then
    FBobTime := 0
  else
  if FOnGround or FOnLadder then
  begin
    if FCrouched then
      BobMove := 0.0625
    else
    if XYSpeed > 210 then
      BobMove := 0.25
    else
    if XYSpeed > 100 then
      BobMove := 0.125
    else
      BobMove := 0.0625;
    FBobTime := FBobTime + BobMove * 10 * SecondsPassed;
  end;
  BobFracSin := Abs(Sin(FBobTime * Pi));
  BobOdd := Odd(Trunc(FBobTime));

  FFallTime := Max(0, FFallTime - SecondsPassed);
  FDamageTime := Max(0, FDamageTime - SecondsPassed);

  { Base view this frame }
  Dir := Parent.Direction;
  Up := Parent.Up;
  Right := TVector3.CrossProduct(Dir, Up).Normalize;
  Flat := Vector3(Dir.X, 0, Dir.Z);
  if not Flat.IsZero then
    Flat := Flat.Normalize;

  Pitch := 0;
  Roll := 0;
  Offset := TVector3.Zero;
  if FViewBob and not FNoclip then
  begin
    { Damage and fall kicks }
    Ratio := FDamageTime / 0.5;
    Pitch := Pitch + Ratio * FDamagePitch;
    Roll := Roll + Ratio * FDamageRoll;
    Ratio := FFallTime / 0.3;
    Pitch := Pitch + Ratio * FFallValue;
    { Running tilts the view }
    Pitch := Pitch + TVector3.DotProduct(FVelocity, Flat) * RunPitch;
    Roll := Roll + TVector3.DotProduct(FVelocity, Right) * RunRoll;
    { Bob }
    Delta := BobFracSin * BobPitch * XYSpeed;
    if FCrouched then
      Delta := Delta * 6;
    Pitch := Pitch + Delta;
    Delta := BobFracSin * BobRoll * XYSpeed;
    if FCrouched then
      Delta := Delta * 6;
    if BobOdd then
      Delta := -Delta;
    Roll := Roll + Delta;
    { Eye height: bob up to 6 units, dip on landing }
    Bob := Min(6, BobFracSin * XYSpeed * BobUp);
    Offset.Y := Bob - Ratio * FFallValue * 0.4;
  end;

  { Weapon: bob, and lag behind turning (oldviewangles - viewangles) }
  Yaw := RadToDeg(ArcTan2(-Dir.X, -Dir.Z));
  ViewPitch := RadToDeg(ArcSin(EnsureRange(Dir.Y, -1, 1)));
  if FHasLastAngles and (SecondsPassed > 0) then
  begin
    Delta := Yaw - FLastYaw;
    if Delta > 180 then
      Delta := Delta - 360
    else
    if Delta < -180 then
      Delta := Delta + 360;
    Smooth := Min(1, SecondsPassed / 0.1);
    FYawRate := FYawRate + (Delta / SecondsPassed - FYawRate) * Smooth;
    FPitchRate := FPitchRate + ((ViewPitch - FLastPitch) / SecondsPassed - FPitchRate) * Smooth;
  end;
  FHasLastAngles := True;
  FLastYaw := Yaw;
  FLastPitch := ViewPitch;
  if FViewBob then
  begin
    FGunAngles.Z := XYSpeed * BobFracSin * 0.005;
    FGunAngles.Y := XYSpeed * BobFracSin * 0.01;
    if BobOdd then
    begin
      FGunAngles.Z := -FGunAngles.Z;
      FGunAngles.Y := -FGunAngles.Y;
    end;
    FGunAngles.X := XYSpeed * BobFracSin * 0.005;
    { Per 0.1 s frame, clamped to 45 degrees, like Quake 2 }
    Delta := EnsureRange(-FYawRate * 0.1, -45, 45);
    FGunAngles.Z := FGunAngles.Z + 0.1 * Delta;
    FGunAngles.Y := FGunAngles.Y + 0.2 * Delta;
    FGunAngles.X := FGunAngles.X + 0.2 * EnsureRange(FPitchRate * 0.1, -45, 45);
  end else
    FGunAngles := TVector3.Zero;

  { Apply: pitch (positive = down) around the right axis, then roll }
  if (Pitch <> 0) or (Roll <> 0) then
  begin
    Dir := RotatePointAroundAxisRad(-DegToRad(Pitch), Dir, Right);
    Up := RotatePointAroundAxisRad(-DegToRad(Pitch), Up, Right);
    Up := RotatePointAroundAxisRad(DegToRad(Roll), Up, Dir);
    Parent.SetView(Dir, Up);
  end;
  Parent.Translation := Parent.Translation + Offset;
  FAppliedOffset := Offset;
  FAppliedPitch := Pitch;
  FAppliedRoll := Roll;
end;

initialization
  RegisterSerializableComponent(TQuakePlayerMovement, 'Quake 2 Player Movement');
end.
