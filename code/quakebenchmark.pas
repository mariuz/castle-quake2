{ Frame time benchmark: collects per-frame numbers between the demo script
  actions BS (start) and BE (end), and reports percentiles.

  Pure data (no rendering), so the unit tests can check the statistics. }
unit QuakeBenchmark;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections;

type
  TBenchmarkResult = record
    Frames: Integer;
    Seconds: Double;
    { Frame times in milliseconds }
    P50, P95, P99, MaxMs, MeanMs: Double;
    { Mean time of the game's own update (world, movement, culling, sounds) }
    LogicMs: Double;
    { Mean shapes drawn per frame }
    Shapes: Double;
  end;

  TQuakeBenchmark = class
  private
    FFrameMs, FLogicMs, FShapes: specialize TList<Double>;
    FRunning: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure AddFrame(const FrameSeconds, LogicSeconds: Double; const ShapesRendered: Cardinal);
    function Stop: TBenchmarkResult;
    property Running: Boolean read FRunning;
  end;

{ The demo script of --benchmark: settle, then stand near items 0, 3, 6 ...
  21 (maps with fewer items stay at the last) and turn around in four
  steps at each, timed between BS and BE; ends with a screenshot }
function BenchmarkScript: String;

{ The P-th percentile (0..100) of Values, by nearest rank on a sorted copy;
  0 for no values }
function Percentile(const Values: array of Double; const P: Double): Double;

{ One log line: "Benchmark: N frames in S s, frame ms p50 ... p95 ... p99 ...
  max ..., mean ..., logic ms ..., shapes ..." }
function BenchmarkText(const R: TBenchmarkResult): String;

implementation

uses
  Math;

function Percentile(const Values: array of Double; const P: Double): Double;
var
  Sorted: array of Double;
  I, J, Rank: Integer;
  T: Double;
begin
  Result := 0;
  if Length(Values) = 0 then
    Exit;
  SetLength(Sorted, Length(Values));
  for I := 0 to High(Values) do
    Sorted[I] := Values[I];
  { Insertion sort: a few thousand frames at most }
  for I := 1 to High(Sorted) do
  begin
    T := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J] > T) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := T;
  end;
  Rank := Ceil(EnsureRange(P, 0, 100) / 100 * Length(Sorted));
  Result := Sorted[EnsureRange(Rank - 1, 0, High(Sorted))];
end;

function BenchmarkScript: String;
var
  I: Integer;
begin
  Result := 'O:notarget,Y,W:2,BS';
  I := 0;
  while I <= 21 do
  begin
    Result := Result + Format(',I:%d,W:0.3,T:90,W:0.4,T:90,W:0.4,T:90,W:0.4,T:90,W:0.4', [I]);
    Inc(I, 3);
  end;
  Result := Result + ',BE,S,Q';
end;

function BenchmarkText(const R: TBenchmarkResult): String;
begin
  Result := Format('Benchmark: %d frames in %.1f s, frame ms p50 %.1f p95 %.1f p99 %.1f max %.1f mean %.1f, logic ms %.2f, shapes %.0f',
    [R.Frames, R.Seconds, R.P50, R.P95, R.P99, R.MaxMs, R.MeanMs, R.LogicMs, R.Shapes],
    DefaultFormatSettings);
end;

{ TQuakeBenchmark }

constructor TQuakeBenchmark.Create;
begin
  inherited Create;
  FFrameMs := specialize TList<Double>.Create;
  FLogicMs := specialize TList<Double>.Create;
  FShapes := specialize TList<Double>.Create;
end;

destructor TQuakeBenchmark.Destroy;
begin
  FFrameMs.Free;
  FLogicMs.Free;
  FShapes.Free;
  inherited Destroy;
end;

procedure TQuakeBenchmark.Start;
begin
  FFrameMs.Clear;
  FLogicMs.Clear;
  FShapes.Clear;
  FRunning := True;
end;

procedure TQuakeBenchmark.AddFrame(const FrameSeconds, LogicSeconds: Double; const ShapesRendered: Cardinal);
begin
  if not FRunning then
    Exit;
  FFrameMs.Add(FrameSeconds * 1000);
  FLogicMs.Add(LogicSeconds * 1000);
  FShapes.Add(ShapesRendered);
end;

function TQuakeBenchmark.Stop: TBenchmarkResult;
var
  Arr: array of Double;
  I: Integer;
  Sum, LogicSum, ShapeSum: Double;
begin
  FRunning := False;
  Result := Default(TBenchmarkResult);
  Result.Frames := FFrameMs.Count;
  if Result.Frames = 0 then
    Exit;
  SetLength(Arr, FFrameMs.Count);
  Sum := 0;
  LogicSum := 0;
  ShapeSum := 0;
  for I := 0 to FFrameMs.Count - 1 do
  begin
    Arr[I] := FFrameMs[I];
    Sum := Sum + FFrameMs[I];
    LogicSum := LogicSum + FLogicMs[I];
    ShapeSum := ShapeSum + FShapes[I];
    Result.MaxMs := Max(Result.MaxMs, FFrameMs[I]);
  end;
  Result.Seconds := Sum / 1000;
  Result.MeanMs := Sum / Result.Frames;
  Result.LogicMs := LogicSum / Result.Frames;
  Result.Shapes := ShapeSum / Result.Frames;
  Result.P50 := Percentile(Arr, 50);
  Result.P95 := Percentile(Arr, 95);
  Result.P99 := Percentile(Arr, 99);
end;

end.
