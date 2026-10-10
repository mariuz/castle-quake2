{ Quake 2 lighting: coordinate conversion, baked-light sampling for models,
  and the weapon muzzle flash. }
unit QuakeLight;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math,
  CastleVectors,
  QuakeBsp;

type
  { Lighting manager. World surfaces use baked RGB lightmaps (see QuakeGeometry);
    models (monsters, items, the view weapon) are tinted with the lightmap color
    sampled below them, like Quake 2's R_LightPoint. }
  TQuakeLighting = class
  private
    FBsp: TQuakeBsp;
    FMuzzleTimer: Single;
    FMuzzlePos: TVector3;
  public
    { Set the current map (nil when no map is loaded). }
    procedure SetMap(const ABsp: TQuakeBsp);

    { Model tint (0..1 RGB) at a CGE position. }
    function SampleLight(const CgePos: TVector3): TVector3;

    { Brighten models near Position for a short moment. }
    procedure TriggerMuzzleFlash(const Position: TVector3);

    procedure Update(const SecondsPassed: Single);

    property Bsp: TQuakeBsp read FBsp;
  end;

{ Convert Quake world coordinates to CGE world coordinates }
function QuakeToCge(const V: TVector3): TVector3; inline;
function CgeToQuake(const V: TVector3): TVector3; inline;

{ CGE direction for a Quake yaw angle in degrees (0 = east, 90 = north) }
function YawToCgeDir(const YawDeg: Single): TVector3;

var
  Lighting: TQuakeLighting;

implementation

function QuakeToCge(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, V.Z, -V.Y);
end;

function CgeToQuake(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, -V.Z, V.Y);
end;

function YawToCgeDir(const YawDeg: Single): TVector3;
var
  Rad: Single;
begin
  Rad := DegToRad(YawDeg);
  Result := Vector3(Cos(Rad), 0, -Sin(Rad));
end;

procedure TQuakeLighting.SetMap(const ABsp: TQuakeBsp);
begin
  FBsp := ABsp;
  FMuzzleTimer := 0;
end;

function TQuakeLighting.SampleLight(const CgePos: TVector3): TVector3;
var
  C: TVector3;
  Flash: Single;
begin
  if (FBsp <> nil) and FBsp.LightPoint(CgeToQuake(CgePos), C) then
    { Same 2x "overbright" factor as the world lightmaps }
    Result := C * 2.0
  else
    Result := Vector3(1, 1, 1);

  { Never fully black, so silhouettes stay readable }
  Result := Vector3(Max(Result.X, 0.18), Max(Result.Y, 0.18), Max(Result.Z, 0.18));

  if FMuzzleTimer > 0 then
  begin
    Flash := (FMuzzleTimer / 0.1) * Max(0, 1 - PointsDistance(CgePos, FMuzzlePos) / 300);
    Result := Result + Vector3(0.9, 0.7, 0.3) * Flash;
  end;

  Result := Vector3(Min(Result.X, 1.6), Min(Result.Y, 1.6), Min(Result.Z, 1.6));
end;

procedure TQuakeLighting.TriggerMuzzleFlash(const Position: TVector3);
begin
  FMuzzlePos := Position;
  FMuzzleTimer := 0.1;
end;

procedure TQuakeLighting.Update(const SecondsPassed: Single);
begin
  if FMuzzleTimer > 0 then
    FMuzzleTimer := Max(0, FMuzzleTimer - SecondsPassed);
end;

initialization
  Lighting := TQuakeLighting.Create;

finalization
  FreeAndNil(Lighting);
end.
