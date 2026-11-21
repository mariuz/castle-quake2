{ The fixed game tick: the world's simulation runs in steps of TickSeconds
  (40 a second), whatever the frame rate, and the transforms it moves are
  drawn between their last two ticks. }
unit QuakeTick;

{$mode objfpc}{$H+}

interface

uses
  Generics.Collections, CastleVectors, CastleTransform;

const
  TicksPerSecond = 40;
  TickSeconds = 1 / TicksPerSecond;
  { A frame runs at most this many ticks (half a second, CGE's own cap on a
    frame's SecondsPassed, so the world keeps the demo scripts' clock); a
    longer stall slows the game down instead of catching up all at once }
  MaxTicksPerFrame = 20;
  { A transform that moved further in one tick jumped (a spawn, a teleport):
    it isn't drawn between its poses }
  MaxInterpolatedMove = 64;

type
  TTickPose = record
    Translation: TVector3;
    Rotation: TVector4;
  end;

  TTickPoses = specialize TDictionary<TCastleTransform, TTickPose>;

  { Counts the ticks of each frame, keeps the moving transforms' poses
    before and after the last tick, and draws them in between }
  TQuakeTickClock = class
  strict private
    FPrev, FCur: TTickPoses;
    FApplied: array of record
      Transform: TCastleTransform;
      Pose: TTickPose;
    end;
    FAppliedCount: Integer;
    FAccumulator: Double;
    FTicks: Int64;
    class procedure Capture(const Poses: TTickPoses; const List: TCastleTransformList); static;
  public
    constructor Create;
    destructor Destroy; override;
    { Add a frame's time; returns how many ticks to run now }
    function AddFrame(const SecondsPassed: Single): Integer;
    { Around each tick, with the transforms the simulation may move }
    procedure BeforeTick(const List: TCastleTransformList);
    procedure AfterTick(const List: TCastleTransformList);
    { How far the frame is past the last tick, 0..1 }
    function Alpha: Single;
    { Move List's transforms to their drawn poses, until Restore }
    procedure Apply(const List: TCastleTransformList);
    procedure Restore;
    { A new map or a loaded game: forget the poses and the time left over }
    procedure Reset;
    { Ticks run so far }
    property Ticks: Int64 read FTicks;
  end;

{ The pose drawn at Alpha (0 = the previous tick, 1 = the last) of a
  transform whose pose is Logical now and was Prev / Cur at the ticks.
  Pure, for the tests. }
function TickDrawnPose(const Logical, Prev, Cur: TTickPose; const Alpha: Single): TTickPose;

implementation

uses
  Math, CastleQuaternions;

function TickDrawnPose(const Logical, Prev, Cur: TTickPose; const Alpha: Single): TTickPose;
var
  Moved: TVector3;
begin
  Result := Logical;
  Moved := Cur.Translation - Prev.Translation;
  if Moved.Length > MaxInterpolatedMove then
    Exit;
  { An offset, so a push after the tick (a lift carrying a monster) is kept }
  Result.Translation := Logical.Translation - Moved * (1 - Alpha);
  { The rotation only while nothing turned it since the tick }
  if TVector4.PerfectlyEquals(Logical.Rotation, Cur.Rotation) and
     not TVector4.PerfectlyEquals(Prev.Rotation, Cur.Rotation) then
    Result.Rotation := SLerp(Alpha, Prev.Rotation, Cur.Rotation);
end;

constructor TQuakeTickClock.Create;
begin
  inherited;
  FPrev := TTickPoses.Create;
  FCur := TTickPoses.Create;
end;

destructor TQuakeTickClock.Destroy;
begin
  FPrev.Free;
  FCur.Free;
  inherited;
end;

class procedure TQuakeTickClock.Capture(const Poses: TTickPoses; const List: TCastleTransformList);
var
  T: TCastleTransform;
  P: TTickPose;
begin
  Poses.Clear;
  for T in List do
  begin
    P.Translation := T.Translation;
    P.Rotation := T.Rotation;
    Poses.AddOrSetValue(T, P);
  end;
end;

function TQuakeTickClock.AddFrame(const SecondsPassed: Single): Integer;
begin
  FAccumulator := FAccumulator + Max(0, SecondsPassed);
  Result := Floor(FAccumulator / TickSeconds + 1e-6);
  if Result > MaxTicksPerFrame then
  begin
    Result := MaxTicksPerFrame;
    FAccumulator := Result * TickSeconds;
  end;
  FAccumulator := Max(0, FAccumulator - Result * TickSeconds);
  FTicks := FTicks + Result;
end;

procedure TQuakeTickClock.BeforeTick(const List: TCastleTransformList);
begin
  Capture(FPrev, List);
end;

procedure TQuakeTickClock.AfterTick(const List: TCastleTransformList);
begin
  Capture(FCur, List);
end;

function TQuakeTickClock.Alpha: Single;
begin
  Result := EnsureRange(FAccumulator / TickSeconds, 0, 1);
end;

procedure TQuakeTickClock.Apply(const List: TCastleTransformList);
var
  T: TCastleTransform;
  Logical, Prev, Cur, Drawn: TTickPose;
  A: Single;
begin
  Restore;
  A := Alpha;
  if Length(FApplied) < List.Count then
    SetLength(FApplied, List.Count);
  for T in List do
  begin
    if not (FPrev.TryGetValue(T, Prev) and FCur.TryGetValue(T, Cur)) then
      Continue;
    Logical.Translation := T.Translation;
    Logical.Rotation := T.Rotation;
    Drawn := TickDrawnPose(Logical, Prev, Cur, A);
    if TVector3.PerfectlyEquals(Drawn.Translation, Logical.Translation) and
       TVector4.PerfectlyEquals(Drawn.Rotation, Logical.Rotation) then
      Continue;
    FApplied[FAppliedCount].Transform := T;
    FApplied[FAppliedCount].Pose := Logical;
    Inc(FAppliedCount);
    T.Translation := Drawn.Translation;
    T.Rotation := Drawn.Rotation;
  end;
end;

procedure TQuakeTickClock.Restore;
var
  I: Integer;
begin
  for I := FAppliedCount - 1 downto 0 do
  begin
    FApplied[I].Transform.Translation := FApplied[I].Pose.Translation;
    FApplied[I].Transform.Rotation := FApplied[I].Pose.Rotation;
  end;
  FAppliedCount := 0;
end;

procedure TQuakeTickClock.Reset;
begin
  Restore;
  FPrev.Clear;
  FCur.Clear;
  FAccumulator := 0;
end;

end.
