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
  CastleVectors, CastleTransform, CastleClassUtils, CastleBoxes, CastleTriangles;

type
  TFallDamageEvent = procedure(const Damage: Integer) of object;
  { Contents (Quake CONTENTS_* bits) at a CGE position }
  TPointContentsEvent = function(const CgePos: TVector3): Integer of object;

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
    procedure CategorizeWater(const Pos: TVector3);
    procedure WaterMove(const Pos: TVector3; const SecondsPassed: Single);
    function EyeHeight: Single;
    { Height of the eye above the ground below Pos (huge if no ground) }
    function HeightAboveGround(const Pos: TVector3): Single;
    procedure Accelerate(const WishDir: TVector3; const WishSpeed, Accel, SecondsPassed: Single);
    procedure ApplyFriction(const SecondsPassed: Single);
    function TryHorizontalMove(const Pos: TVector3; const Delta: TVector3): TVector3;
  public
    { Input for this frame, set by the view: -1..1 }
    InputForward, InputSide: Single;
    InputJump, InputCrouch: Boolean;
    { Temporarily frozen (dead, intermission) }
    Suspended: Boolean;
    constructor Create(AOwner: TComponent); override;
    function PropertySections(const PropertyName: String): TPropertySections; override;
    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;
    { Forget the velocity (after teleports, level loads, respawn) }
    procedure ResetVelocity;
    { Throw the player (trigger_push, explosions) }
    procedure AddVelocity(const V: TVector3);
    { Pmove velocity in CGE units per second }
    property Velocity: TVector3 read FVelocity write FVelocity;
    property OnFallDamage: TFallDamageEvent read FOnFallDamage write FOnFallDamage;
    property OnLandSound: TNotifyEvent read FOnLandSound write FOnLandSound;
    property OnPointContents: TPointContentsEvent read FOnPointContents write FOnPointContents;
    { Contents bits of the liquid the player is in (0 = none) }
    property WaterType: Integer read FWaterType;
  published
    { 0 = not in liquid, 1 = feet, 2 = waist (swimming), 3 = eyes under }
    property WaterLevel: Integer read FWaterLevel;
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
    property Radius: Single read FRadius write FRadius;
    property StandEyeHeight: Single read FEyeHeight write FEyeHeight;
    property CrouchEyeHeight: Single read FCrouchEyeHeight write FCrouchEyeHeight;
  end;

implementation

uses
  CastleComponentSerialize, CastleUtils, CastleStringUtils;

constructor TQuakePlayerMovement.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { Quake 2 defaults (pm_maxspeed, pm_duckspeed, pm_accelerate, pm_friction...) }
  FActive := True;
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
  FEyeHeight := 46;       { origin 24 above the feet + viewheight 22 }
  FCrouchEyeHeight := 22; { ducked: origin 24 + viewheight -2 }
  FWaterSpeed := 400 * 0.5; { pm_waterspeed, halved by PM_WaterMove }
  FWaterFriction := 1;
  FWaterSink := 60;
end;

function TQuakePlayerMovement.PropertySections(const PropertyName: String): TPropertySections;
begin
  if ArrayContainsString(PropertyName, ['Active', 'OnGround', 'Crouched', 'Noclip', 'RunSpeed',
    'JumpSpeed', 'GravityAcceleration', 'StepSize']) then
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

function TQuakePlayerMovement.HeightAboveGround(const Pos: TVector3): Single;
var
  Ground: PTriangle;
begin
  if (World = nil) or not World.WorldHeight(Pos, Result, Ground) then
    Result := 100000;
end;

procedure TQuakePlayerMovement.ResetVelocity;
begin
  FVelocity := TVector3.Zero;
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

  { Move with wall sliding of the eye sphere; then refuse it if the ground at
    the new place rises more than StepSize (a wall lower than the eye sphere) }
  function Attempt(const D: TVector3; out NewPos: TVector3): Boolean;
  var
    Rise: Single;
  begin
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
  if not World.WorldSegmentCollision(NewPos, NewPos + Vector3(0, FVelocity.Y * SecondsPassed +
    Sign(FVelocity.Y) * FRadius, 0)) then
    NewPos.Y := NewPos.Y + FVelocity.Y * SecondsPassed
  else
    FVelocity.Y := 0;
  { Don't sink through the bottom }
  if HeightAboveGround(NewPos) < EyeHeight then
    NewPos.Y := NewPos.Y + (EyeHeight - HeightAboveGround(NewPos));
  Parent.Translation := NewPos;
  FOnGround := False;
end;

procedure TQuakePlayerMovement.Update(const SecondsPassed: Single; var RemoveMe: TRemoveType);
var
  Pos, Forward, Right, WishVel, WishDir, NewPos: TVector3;
  WishSpeed, Above, Dt, FallSpeed, Delta: Single;
  Dir: TVector3;
  WasOnGround: Boolean;
begin
  inherited Update(SecondsPassed, RemoveMe);
  if (not FActive) or Suspended or (Parent = nil) or (World = nil) or (SecondsPassed <= 0) then
    Exit;
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

  { Crouch: stand up only if there is room above }
  if InputCrouch then
    FCrouched := True
  else
  if FCrouched and not World.WorldSegmentCollision(Pos, Pos + Vector3(0, FEyeHeight - FCrouchEyeHeight + 8, 0)) then
    FCrouched := False;

  CategorizeWater(Pos);
  if FWaterLevel >= 2 then
  begin
    WaterMove(Pos, Dt);
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
    if World.WorldSegmentCollision(NewPos, NewPos + Vector3(0, FVelocity.Y * Dt + FRadius, 0)) then
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

initialization
  RegisterSerializableComponent(TQuakePlayerMovement, 'Quake 2 Player Movement');
end.
