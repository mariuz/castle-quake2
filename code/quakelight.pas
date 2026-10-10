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
    { Set the current map (nil when no map is loaded). }
    procedure SetMap(const ABsp: TQuakeBsp);

    { Model tint (0..1 RGB) at a CGE position. }
    function SampleLight(const CgePos: TVector3): TVector3;

    { Brighten models near Position for a short moment. }
    procedure TriggerMuzzleFlash(const Position: TVector3);

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

constructor TQuakeLighting.Create;
begin
  inherited Create;
  ResetStyles;
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
  FMuzzleTimer := 0;
  ResetStyles;
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
var
  I: Integer;
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
  if FMuzzleTimer > 0 then
    FMuzzleTimer := Max(0, FMuzzleTimer - SecondsPassed);
end;

initialization
  Lighting := TQuakeLighting.Create;

finalization
  FreeAndNil(Lighting);
end.
