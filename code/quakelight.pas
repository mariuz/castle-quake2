{ Quake 2 lighting: coordinate conversion, baked-light sampling for models,
  light styles and dynamic lights (muzzle flashes, explosions, projectiles). }
unit QuakeLight;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, Generics.Collections,
  CastleVectors,
  QuakeBsp;

const
  { Dynamic lights drawn on world surfaces at once (shader uniforms) }
  MaxSurfaceLights = 4;

type
  { Quake 2 dlight_t: a point light added to the lightmaps }
  TQuakeDynLight = record
    Position: TVector3; { CGE coordinates }
    Radius: Single;     { Quake units; intensity (Radius - distance) / 256 }
    Color: TVector3;
    { Seconds left / total. Duration 0 = only until the next EndFrame. }
    Life, Duration: Single;
    function CurrentRadius: Single;
  end;
  TQuakeDynLightList = specialize TList<TQuakeDynLight>;
  TQuakeSurfaceLights = array[0..MaxSurfaceLights - 1] of TQuakeDynLight;

  { Lighting manager. World surfaces use baked RGB lightmaps (see QuakeGeometry);
    models (monsters, items, the view weapon) are tinted with the lightmap color
    sampled below them, like Quake 2's R_LightPoint. }
  TQuakeLighting = class
  private
    FBsp: TQuakeBsp;
    FLights: TQuakeDynLightList;
    FTime: Single;
    FStyles: array[0..255] of String;
    FValues: array[0..255] of Single;
    FRampFrom, FRampTo: array[0..255] of Single;
    FRampTime, FRampDuration: array[0..255] of Single;
    FVersion: Cardinal;
    procedure ResetStyles;
    procedure UpdateStyleValues;
  public
    constructor Create;
    destructor Destroy; override;
    { Set the current map (nil when no map is loaded). }
    procedure SetMap(const ABsp: TQuakeBsp);

    { Model tint (0..1 RGB) at a CGE position. }
    function SampleLight(const CgePos: TVector3): TVector3;

    { Weapon muzzle flash: a short light at Position. }
    procedure TriggerMuzzleFlash(const Position: TVector3);

    { Add a dynamic light (CGE position, Quake radius). Timed lights shrink to
      nothing over Duration (explosions); Duration 0 lasts until EndFrame
      (lights carried by projectiles, added every frame). }
    procedure AddLight(const Position: TVector3; const Radius: Single;
      const Color: TVector3; const Duration: Single = 0);
    { The lights closest to Pos (for the world shader); returns their count. }
    function NearestLights(const Pos: TVector3; out Lights: TQuakeSurfaceLights): Integer;
    { Forget the single-frame lights }
    procedure EndFrame;
    property Lights: TQuakeDynLightList read FLights;

    procedure Update(const SecondsPassed: Single);

    { Light style brightness (1.0 = normal "m"), like Quake 2's d_lightstylevalue.
      Styles 0..11 animate, 32..62 are switchable lights, 63 is "off". }
    function StyleValue(const Style: Integer): Single;
    { Replace a style's pattern of 'a'..'z' letters, played at 10 Hz }
    procedure SetStyle(const Style: Integer; const Pattern: String);
    function GetStyle(const Style: Integer): String;
    { Smoothly change a style from one letter to another (target_lightramp) }
    procedure RampStyle(const Style: Integer; const FromChar, ToChar: Char; const Duration: Single);
    { Incremented whenever any style value changes (to know when to relight) }
    property Version: Cardinal read FVersion;

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

function TQuakeDynLight.CurrentRadius: Single;
begin
  if Duration > 0 then
    Result := Radius * Max(0, Life / Duration)
  else
    Result := Radius;
end;

constructor TQuakeLighting.Create;
begin
  inherited Create;
  FLights := TQuakeDynLightList.Create;
  ResetStyles;
end;

destructor TQuakeLighting.Destroy;
begin
  FreeAndNil(FLights);
  inherited Destroy;
end;

procedure TQuakeLighting.ResetStyles;
var
  I: Integer;
begin
  { Quake 2 SP_worldspawn light styles }
  for I := 0 to 255 do
  begin
    FStyles[I] := 'm';
    FRampDuration[I] := 0;
  end;
  FStyles[1] := 'mmnmmommommnonmmonqnmmo';                         { flicker }
  FStyles[2] := 'abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba'; { slow strong pulse }
  FStyles[3] := 'mmmmmaaaaammmmmaaaaaabcdefgabcdefg';              { candle 1 }
  FStyles[4] := 'mamamamamama';                                    { fast strobe }
  FStyles[5] := 'jklmnopqrstuvwxyzyxwvutsrqponmlkj';               { gentle pulse }
  FStyles[6] := 'nmonqnmomnmomomno';                               { flicker 2 }
  FStyles[7] := 'mmmaaaabcdefgmmmmaaaammmaamm';                    { candle 2 }
  FStyles[8] := 'mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa';      { candle 3 }
  FStyles[9] := 'aaaaaaaazzzzzzzz';                                { slow strobe }
  FStyles[10] := 'mmamammmmammamamaaamamm';                        { fluorescent flicker }
  FStyles[11] := 'abcdefghijklmnopqrrqponmlkjihgfedcba';           { slow pulse, no black }
  FStyles[63] := 'a';
  FTime := 0;
  UpdateStyleValues;
  Inc(FVersion);
end;

procedure TQuakeLighting.UpdateStyleValues;
var
  I, Frame: Integer;
  V: Single;
  Pat: String;
  Changed: Boolean;
begin
  Changed := False;
  Frame := Trunc(FTime * 10);
  for I := 0 to 255 do
  begin
    if FRampDuration[I] > 0 then
      V := FRampFrom[I] + (FRampTo[I] - FRampFrom[I]) *
        Min(1, FRampTime[I] / FRampDuration[I])
    else
    begin
      Pat := FStyles[I];
      if Pat = '' then
        V := 1
      else
        { 'a' = 0, 'm' = 1, 'z' = ~2 }
        V := (Ord(Pat[1 + Frame mod Length(Pat)]) - Ord('a')) / 12;
    end;
    if V <> FValues[I] then
    begin
      FValues[I] := V;
      Changed := True;
    end;
  end;
  if Changed then
    Inc(FVersion);
end;

function TQuakeLighting.StyleValue(const Style: Integer): Single;
begin
  if (Style < 0) or (Style > 255) then
    Result := 0
  else
    Result := FValues[Style];
end;

procedure TQuakeLighting.SetStyle(const Style: Integer; const Pattern: String);
begin
  if (Style < 0) or (Style > 255) then
    Exit;
  FStyles[Style] := Pattern;
  FRampDuration[Style] := 0;
  UpdateStyleValues;
end;

function TQuakeLighting.GetStyle(const Style: Integer): String;
begin
  if (Style < 0) or (Style > 255) then
    Result := ''
  else
    Result := FStyles[Style];
end;

procedure TQuakeLighting.RampStyle(const Style: Integer; const FromChar, ToChar: Char;
  const Duration: Single);
begin
  if (Style < 0) or (Style > 255) then
    Exit;
  FRampFrom[Style] := (Ord(FromChar) - Ord('a')) / 12;
  FRampTo[Style] := (Ord(ToChar) - Ord('a')) / 12;
  FRampTime[Style] := 0;
  FRampDuration[Style] := Max(0.01, Duration);
  FStyles[Style] := ToChar;
end;

procedure TQuakeLighting.SetMap(const ABsp: TQuakeBsp);
begin
  FBsp := ABsp;
  FLights.Clear;
  ResetStyles;
end;

function TQuakeLighting.SampleLight(const CgePos: TVector3): TVector3;
var
  C: TVector3;
  L: TQuakeDynLight;
  Samples: TLightPointSamples;
  I: Integer;
begin
  if (FBsp <> nil) and FBsp.LightPointStyles(CgeToQuake(CgePos), Samples) then
  begin
    { R_LightPoint: each style's lightmap scaled by its current value (so
      models flicker and switch with the lights), with the same 2x
      "overbright" factor as the world lightmaps }
    C := TVector3.Zero;
    for I := 0 to Samples.Count - 1 do
      C := C + Samples.Colors[I] * StyleValue(Samples.Styles[I]);
    Result := C * 2.0;
  end else
    Result := Vector3(1, 1, 1);

  { Never fully black, so silhouettes stay readable }
  Result := Vector3(Max(Result.X, 0.18), Max(Result.Y, 0.18), Max(Result.Z, 0.18));

  { Same falloff as on the world surfaces (see TQuakeGeometry) }
  for L in FLights do
    Result := Result + L.Color *
      (2.0 * Max(0, L.CurrentRadius - PointsDistance(CgePos, L.Position)) / 256);

  Result := Vector3(Min(Result.X, 1.6), Min(Result.Y, 1.6), Min(Result.Z, 1.6));
end;

procedure TQuakeLighting.TriggerMuzzleFlash(const Position: TVector3);
begin
  { Quake 2 MZ_*: radius 200 + random 31, one frame (0.1 s) }
  AddLight(Position, 200 + Random(32), Vector3(1, 1, 0), 0.1);
end;

procedure TQuakeLighting.AddLight(const Position: TVector3; const Radius: Single;
  const Color: TVector3; const Duration: Single);
var
  L: TQuakeDynLight;
begin
  L.Position := Position;
  L.Radius := Radius;
  L.Color := Color;
  L.Life := Duration;
  L.Duration := Duration;
  FLights.Add(L);
end;

function TQuakeLighting.NearestLights(const Pos: TVector3; out Lights: TQuakeSurfaceLights): Integer;
var
  L: TQuakeDynLight;
  I, Worst: Integer;
  Dist: array[0..MaxSurfaceLights - 1] of Single;
  D: Single;
begin
  Result := 0;
  for L in FLights do
  begin
    if L.CurrentRadius <= 0 then
      Continue;
    { Distance to the light's sphere: big lights far away still matter }
    D := PointsDistance(Pos, L.Position) - L.CurrentRadius;
    if Result < MaxSurfaceLights then
    begin
      Lights[Result] := L;
      Dist[Result] := D;
      Inc(Result);
    end else
    begin
      Worst := 0;
      for I := 1 to MaxSurfaceLights - 1 do
        if Dist[I] > Dist[Worst] then
          Worst := I;
      if D < Dist[Worst] then
      begin
        Lights[Worst] := L;
        Dist[Worst] := D;
      end;
    end;
  end;
end;

procedure TQuakeLighting.EndFrame;
var
  I: Integer;
begin
  for I := FLights.Count - 1 downto 0 do
    if FLights[I].Duration = 0 then
      FLights.Delete(I);
end;

procedure TQuakeLighting.Update(const SecondsPassed: Single);
var
  I: Integer;
  L: TQuakeDynLight;
begin
  FTime := FTime + SecondsPassed;
  for I := 0 to 255 do
    if FRampDuration[I] > 0 then
    begin
      FRampTime[I] := FRampTime[I] + SecondsPassed;
      { Finished ramps stay at their last letter (FStyles holds it) }
      if FRampTime[I] >= FRampDuration[I] then
      begin
        FRampDuration[I] := 0;
      end;
    end;
  UpdateStyleValues;
  for I := FLights.Count - 1 downto 0 do
    if FLights[I].Duration > 0 then
    begin
      L := FLights[I];
      L.Life := L.Life - SecondsPassed;
      if L.Life <= 0 then
        FLights.Delete(I)
      else
        FLights[I] := L;
    end;
end;

initialization
  Lighting := TQuakeLighting.Create;

finalization
  FreeAndNil(Lighting);
end.
