{ Recording a playthrough as an autotest demo script (the "record" console
  command). The player's view and held inputs become "IN:" commands timed on
  the script clock, one per change; instant actions (weapon switches, use,
  console commands) are added between them as ordinary demo commands.

  IN:time yaw pitch forward side buttons [x y z]
    Wait until the script clock (seconds since the script started) reaches
    time, then look along yaw / pitch (Quake degrees, pitch positive looks
    down) and hold forward / side (-1..1) and the buttons (InButton* bits)
    until the next IN. Several due INs in one frame are skipped to the last,
    so slow frames don't make the replay fall behind. x y z is the recorded
    view position (Quake coordinates): the replay measures its drift and
    moves the player back when it is far (frame timing differs). }
unit QuakeRecord;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, CastleVectors;

const
  InButtonFire = 1;
  InButtonJump = 2;
  InButtonCrouch = 4;

type
  TDemoInput = record
    Time, Yaw, Pitch, Forward, Side: Single;
    Buttons: Integer;
    HasOrigin: Boolean;
    Origin: TVector3;
  end;

  TQuakeRecorder = class
  strict private
    FLines: TStringList;
    FLast: TDemoInput;
    FHasLast: Boolean;
    FMapName: String;
    FJumpTime: Single;
  public
    { Minimum time between two INs that only turn the view }
    ViewInterval: Single;
    { Smallest view change (degrees) worth an IN }
    ViewThreshold: Single;
    { While moving, an IN (with the position) at least this often }
    KeyInterval: Single;
    constructor Create(const AMapName: String);
    destructor Destroy; override;
    { Called every frame with the current view and inputs }
    procedure Sample(const AInput: TDemoInput);
    { An instant demo command (e.g. "C:3", "U", "O:god") at this point }
    procedure AddCommand(const Cmd: String);
    { Cmd at Time: after an IN that waits for Time, holding the last inputs }
    procedure AddTimedCommand(const Time: Single; const Cmd: String);
    { Release everything at Time, log the state (V) }
    procedure Finish(const Time: Single);
    function Script: String;
    property Lines: TStringList read FLines;
    property MapName: String read FMapName;
  end;

function FormatDemoInput(const Input: TDemoInput): String;
{ Parse the parameter of an IN command (without "IN:") }
function ParseDemoInput(const Param: String; out Input: TDemoInput): Boolean;
{ Smallest difference of two angles in degrees, 0..180 }
function AngleDiff(const A, B: Single): Single;

implementation

uses
  Math;

var
  DotFormat: TFormatSettings;

function FormatDemoInput(const Input: TDemoInput): String;
begin
  Result := Format('IN:%.2f %.1f %.1f %.2f %.2f %d', [Input.Time, Input.Yaw, Input.Pitch,
    Input.Forward, Input.Side, Input.Buttons], DotFormat);
  if Input.HasOrigin then
    Result := Result + Format(' %.2f %.2f %.2f', [Input.Origin.X, Input.Origin.Y, Input.Origin.Z], DotFormat);
end;

function ParseDemoInput(const Param: String; out Input: TDemoInput): Boolean;
var
  Vals: TStringArray;
begin
  Input := Default(TDemoInput);
  Vals := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
  Result := Length(Vals) >= 6;
  if not Result then
    Exit;
  Input.Time := StrToFloatDef(Vals[0], 0, DotFormat);
  Input.Yaw := StrToFloatDef(Vals[1], 0, DotFormat);
  Input.Pitch := StrToFloatDef(Vals[2], 0, DotFormat);
  Input.Forward := StrToFloatDef(Vals[3], 0, DotFormat);
  Input.Side := StrToFloatDef(Vals[4], 0, DotFormat);
  Input.Buttons := StrToIntDef(Vals[5], 0);
  Input.HasOrigin := Length(Vals) >= 9;
  if Input.HasOrigin then
    Input.Origin := Vector3(StrToFloatDef(Vals[6], 0, DotFormat), StrToFloatDef(Vals[7], 0, DotFormat),
      StrToFloatDef(Vals[8], 0, DotFormat));
end;

function AngleDiff(const A, B: Single): Single;
begin
  Result := Abs(FMod(A - B, 360));
  if Result > 180 then
    Result := 360 - Result;
end;

constructor TQuakeRecorder.Create(const AMapName: String);
begin
  inherited Create;
  FMapName := AMapName;
  FLines := TStringList.Create;
  ViewInterval := 0.05;
  ViewThreshold := 0.2;
  KeyInterval := 0.5;
end;

destructor TQuakeRecorder.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TQuakeRecorder.Sample(const AInput: TDemoInput);
var
  Held, View, Key: Boolean;
  Input: TDemoInput;
begin
  Input := AInput;
  { A jump is one frame of the key; keep it 0.1 s so a replay with other
    frames can't miss it (pmove jumps once per press anyway) }
  if (Input.Buttons and InButtonJump) <> 0 then
  begin
    if not FHasLast or ((FLast.Buttons and InButtonJump) = 0) then
      FJumpTime := Input.Time;
  end else
  if FHasLast and ((FLast.Buttons and InButtonJump) <> 0) and (Input.Time - FJumpTime < 0.1) then
    Input.Buttons := Input.Buttons or InButtonJump;
  if FHasLast then
  begin
    { Inputs right away (short taps must not be lost), the view at most
      every ViewInterval }
    Held := (Abs(Input.Forward - FLast.Forward) > 0.01) or (Abs(Input.Side - FLast.Side) > 0.01) or
      (Input.Buttons <> FLast.Buttons);
    View := (Input.Time - FLast.Time >= ViewInterval) and
      ((AngleDiff(Input.Yaw, FLast.Yaw) > ViewThreshold) or (Abs(Input.Pitch - FLast.Pitch) > ViewThreshold));
    Key := (Input.Time - FLast.Time >= KeyInterval) and Input.HasOrigin and FLast.HasOrigin and
      (PointsDistance(Input.Origin, FLast.Origin) > 1);
    if not (Held or View or Key) then
      Exit;
  end;
  FLines.Add(FormatDemoInput(Input));
  FLast := Input;
  FHasLast := True;
end;

procedure TQuakeRecorder.AddCommand(const Cmd: String);
begin
  FLines.Add(Cmd);
end;

procedure TQuakeRecorder.AddTimedCommand(const Time: Single; const Cmd: String);
var
  Timed: TDemoInput;
begin
  if FHasLast and (Time > FLast.Time) then
  begin
    Timed := FLast;
    Timed.Time := Time;
    { The position isn't known here (the player moved since the last IN) }
    Timed.HasOrigin := False;
    FLines.Add(FormatDemoInput(Timed));
    FLast.Time := Time;
  end;
  FLines.Add(Cmd);
end;

procedure TQuakeRecorder.Finish(const Time: Single);
var
  Last: TDemoInput;
begin
  Last := FLast;
  Last.Time := Max(Time, FLast.Time);
  Last.Forward := 0;
  Last.Side := 0;
  Last.Buttons := 0;
  Last.HasOrigin := False;
  FLines.Add(FormatDemoInput(Last));
  FLines.Add('V');
end;

function TQuakeRecorder.Script: String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FLines.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + FLines[I];
  end;
end;

initialization
  DotFormat := DefaultFormatSettings;
  DotFormat.DecimalSeparator := '.';
end.
