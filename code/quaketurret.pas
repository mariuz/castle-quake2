{ Quake 2 turrets (g_turret.c) as pure functions: the breach's angle limits
  and turning, the muzzle point, the driver's seat behind the breach and
  vectoangles. Angles are Quake degrees (pitch positive looks down),
  positions Quake coordinates. Used by TQuakeWorld.UpdateTurrets. }
unit QuakeTurret;

{$mode objfpc}{$H+}

interface

uses
  CastleVectors;

type
  { pos1 / pos2 of SP_turret_breach: pitch limits (pos1 = -minpitch is the
    lowest aim, pos2 = -maxpitch the highest) and yaw limits }
  TTurretLimits = record
    Pos1Pitch, Pos1Yaw, Pos2Pitch, Pos2Yaw: Single;
  end;

{ SP_turret_breach limits from the entity's fields; 0 (or missing) takes
  Quake 2's defaults: minpitch -30, maxpitch 30, maxyaw 360 }
function TurretLimits(MinPitch, MaxPitch, MinYaw, MaxYaw: Single): TTurretLimits;

{ AnglesNormalize of g_turret.c: into 0..360 }
function TurretAngleNormalize(const A: Single): Single;

{ turret_breach_think, first part: normalize the wished angles and clamp
  them to the limits }
procedure TurretClampAngles(var MovePitch, MoveYaw: Single; const L: TTurretLimits);

{ turret_breach_think, second part: the change of the current angles
  towards the wished ones (shorter way round), at most MaxStep degrees }
procedure TurretStep(const CurPitch, CurYaw, MovePitch, MoveYaw, MaxStep: Single;
  out DPitch, DYaw: Single);

{ AngleVectors with roll 0 }
procedure QuakeAngleVectors(const Pitch, Yaw: Single; out Fwd, Right, Up: TVector3);

{ turret_breach_fire: the rocket's start, MoveOrigin (the breach's target
  minus its origin) along forward / right / up of the breach }
function TurretMuzzle(const Origin: TVector3; const Pitch, Yaw: Single;
  const MoveOrigin: TVector3): TVector3;

{ SnapToEights of g_turret.c }
function SnapToEights(const X: Single): Single;

{ turret_driver_link: the driver's move_origin (horizontal distance to the
  breach, yaw from the breach to the driver, height above the breach) }
function TurretDriverOffset(const DriverOrigin, BreachOrigin: TVector3): TVector3;

{ turret_breach_think: where the driver goes for the breach's angles }
function TurretDriverOrigin(const BreachOrigin: TVector3; const Pitch, Yaw: Single;
  const DriverOffset: TVector3; const DriverZ: Single): TVector3;

{ vectoangles (whole degrees, like Quake 2): pitch negative looks up }
procedure QuakeVecToAngles(const Dir: TVector3; out Pitch, Yaw: Single);

{ Rotation (CGE axis-angle) of a brush model with these Quake angles }
function TurretRotation(const Pitch, Yaw: Single): TVector4;

implementation

uses
  Math, CastleQuaternions;

function TurretLimits(MinPitch, MaxPitch, MinYaw, MaxYaw: Single): TTurretLimits;
begin
  if MinPitch = 0 then
    MinPitch := -30;
  if MaxPitch = 0 then
    MaxPitch := 30;
  if MaxYaw = 0 then
    MaxYaw := 360;
  Result.Pos1Pitch := -MinPitch;
  Result.Pos1Yaw := MinYaw;
  Result.Pos2Pitch := -MaxPitch;
  Result.Pos2Yaw := MaxYaw;
end;

function TurretAngleNormalize(const A: Single): Single;
begin
  Result := A;
  while Result > 360 do
    Result := Result - 360;
  while Result < 0 do
    Result := Result + 360;
end;

function Wrap180(const A: Single): Single;
begin
  Result := A;
  if Result < -180 then
    Result := Result + 360
  else
  if Result > 180 then
    Result := Result - 360;
end;

procedure TurretClampAngles(var MovePitch, MoveYaw: Single; const L: TTurretLimits);
var
  DMin, DMax: Single;
begin
  MovePitch := TurretAngleNormalize(MovePitch);
  MoveYaw := TurretAngleNormalize(MoveYaw);
  if MovePitch > 180 then
    MovePitch := MovePitch - 360;
  if MovePitch > L.Pos1Pitch then
    MovePitch := L.Pos1Pitch
  else
  if MovePitch < L.Pos2Pitch then
    MovePitch := L.Pos2Pitch;
  if (MoveYaw < L.Pos1Yaw) or (MoveYaw > L.Pos2Yaw) then
  begin
    DMin := Wrap180(Abs(L.Pos1Yaw - MoveYaw));
    DMax := Wrap180(Abs(L.Pos2Yaw - MoveYaw));
    if Abs(DMin) < Abs(DMax) then
      MoveYaw := L.Pos1Yaw
    else
      MoveYaw := L.Pos2Yaw;
  end;
end;

procedure TurretStep(const CurPitch, CurYaw, MovePitch, MoveYaw, MaxStep: Single;
  out DPitch, DYaw: Single);
begin
  DPitch := EnsureRange(Wrap180(MovePitch - TurretAngleNormalize(CurPitch)), -MaxStep, MaxStep);
  DYaw := EnsureRange(Wrap180(MoveYaw - TurretAngleNormalize(CurYaw)), -MaxStep, MaxStep);
end;

procedure QuakeAngleVectors(const Pitch, Yaw: Single; out Fwd, Right, Up: TVector3);
var
  SP, CP, SY, CY: Single;
begin
  SinCos(DegToRad(Pitch), SP, CP);
  SinCos(DegToRad(Yaw), SY, CY);
  Fwd := Vector3(CP * CY, CP * SY, -SP);
  Right := Vector3(SY, -CY, 0);
  Up := Vector3(SP * CY, SP * SY, CP);
end;

function TurretMuzzle(const Origin: TVector3; const Pitch, Yaw: Single;
  const MoveOrigin: TVector3): TVector3;
var
  F, R, U: TVector3;
begin
  QuakeAngleVectors(Pitch, Yaw, F, R, U);
  Result := Origin + F * MoveOrigin.X + R * MoveOrigin.Y + U * MoveOrigin.Z;
end;

function SnapToEights(const X: Single): Single;
var
  V: Single;
begin
  V := X * 8;
  if V > 0 then
    V := V + 0.5
  else
    V := V - 0.5;
  Result := 0.125 * Trunc(V);
end;

function TurretDriverOffset(const DriverOrigin, BreachOrigin: TVector3): TVector3;
var
  P, Y: Single;
begin
  Result.X := Vector2(BreachOrigin.X - DriverOrigin.X, BreachOrigin.Y - DriverOrigin.Y).Length;
  QuakeVecToAngles(DriverOrigin - BreachOrigin, P, Y);
  Result.Y := TurretAngleNormalize(Y);
  Result.Z := DriverOrigin.Z - BreachOrigin.Z;
end;

function TurretDriverOrigin(const BreachOrigin: TVector3; const Pitch, Yaw: Single;
  const DriverOffset: TVector3; const DriverZ: Single): TVector3;
var
  A: Single;
begin
  A := DegToRad(Yaw + DriverOffset.Y);
  Result.X := SnapToEights(BreachOrigin.X + Cos(A) * DriverOffset.X);
  Result.Y := SnapToEights(BreachOrigin.Y + Sin(A) * DriverOffset.X);
  { z: lifted / lowered with the pitch, like a point on the gun's axis }
  Result.Z := SnapToEights(BreachOrigin.Z + DriverOffset.X * Tan(DegToRad(Pitch)) + DriverOffset.Z);
  if IsNan(Result.Z) then
    Result.Z := DriverZ;
end;

procedure QuakeVecToAngles(const Dir: TVector3; out Pitch, Yaw: Single);
var
  Fwd: Single;
begin
  if (Dir.X = 0) and (Dir.Y = 0) then
  begin
    Yaw := 0;
    if Dir.Z > 0 then
      Pitch := 90
    else
      Pitch := 270;
  end else
  begin
    if Dir.X <> 0 then
      Yaw := Trunc(RadToDeg(ArcTan2(Dir.Y, Dir.X)))
    else
    if Dir.Y > 0 then
      Yaw := 90
    else
      Yaw := 270;
    if Yaw < 0 then
      Yaw := Yaw + 360;
    Fwd := Sqrt(Sqr(Dir.X) + Sqr(Dir.Y));
    Pitch := Trunc(RadToDeg(ArcTan2(Dir.Z, Fwd)));
    if Pitch < 0 then
      Pitch := Pitch + 360;
  end;
  Pitch := -Pitch;
end;

function TurretRotation(const Pitch, Yaw: Single): TVector4;
var
  Q: TQuaternion;
begin
  { Quake applies pitch about the model's Y axis (CGE -Z), then yaw about
    Z (CGE +Y) }
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Yaw)) *
    QuatFromAxisAngle(Vector3(0, 0, -1), DegToRad(Pitch));
  Result := Q.ToAxisAngle;
end;

end.
