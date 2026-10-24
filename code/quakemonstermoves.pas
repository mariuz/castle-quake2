{ Monster walking and running on Quake 2's animation frames: the looping
  walk / run mframe_t tables of m_soldier.c, m_infantry.c, m_gunner.c,
  m_berserk.c, m_flyer.c, m_parasite.c and m_tank.c, each frame with the
  distance ai_walk / ai_run moves the monster on it. TMonsterMoveAnim plays
  one at 10 frames a second; its Speed is the current frame's distance
  per second, so the feet move with the ground and each monster type keeps
  its Quake 2 pace (the tank plods, the parasite lunges).

  Plain code without scenes, so the unit tests can check it. Monsters
  without a table (the full game's others) keep their constant Speed. }
unit QuakeMonsterMoves;

{$mode objfpc}{$H+}

interface

type
  TMonsterMoveSeq = record
    { Model frame where the loop starts (e.g. 'run03') }
    FirstFrame: String;
    { Units moved on each frame (mframe_t dist) }
    Dists: array of Single;
  end;

  { One walk / run loop being played }
  TMonsterMoveAnim = class
  strict private
    FSeq: TMonsterMoveSeq;
    FFrame, FOldFrame: Integer;
    FClock: Single;
    FActive: Boolean;
  public
    procedure Start(const Seq: TMonsterMoveSeq);
    procedure Stop;
    procedure Update(const SecondsPassed: Single);
    { Units a second on the current frame }
    function Speed: Single;
    { 0..1 from OldFrame to Frame, for drawing }
    function FrameLerp: Single;
    property Active: Boolean read FActive;
    property Seq: TMonsterMoveSeq read FSeq;
    property Frame: Integer read FFrame;
    property OldFrame: Integer read FOldFrame;
  end;

{ The walk (Run = False) or run loop of a monster class (no Dists: none) }
function MonsterMoveSeq(const MonsterClass: String; const Run: Boolean): TMonsterMoveSeq;

{ Average units a second over the loop (0 when empty) }
function MoveSeqSpeed(const Seq: TMonsterMoveSeq): Single;

implementation

uses
  Math, QuakeMonsterAttacks;

function MakeMove(const First: String; const Dists: array of Single): TMonsterMoveSeq;
var
  I: Integer;
begin
  Result.FirstFrame := First;
  SetLength(Result.Dists, Length(Dists));
  for I := 0 to High(Dists) do
    Result.Dists[I] := Dists[I];
end;

function Even(const First: String; const Count: Integer; const Dist: Single): TMonsterMoveSeq;
var
  I: Integer;
begin
  Result.FirstFrame := First;
  SetLength(Result.Dists, Count);
  for I := 0 to Count - 1 do
    Result.Dists[I] := Dist;
end;

function MonsterMoveSeq(const MonsterClass: String; const Run: Boolean): TMonsterMoveSeq;
begin
  Result := Default(TMonsterMoveSeq);
  if Copy(MonsterClass, 1, 15) = 'monster_soldier' then
  begin
    { soldier_move_run (after start_run); walking: soldier_move_walk2
      (walk1 mostly stands still) }
    if Run then
      Result := MakeMove('run03', [10, 11, 11, 16, 10, 15])
    else
      Result := MakeMove('walk209', [4, 4, 9, 8, 5, 1, 3, 7, 6, 7]);
  end else
  if MonsterClass = 'monster_infantry' then
  begin
    if Run then
      Result := MakeMove('run01', [10, 20, 5, 7, 30, 35, 2, 6])
    else
      Result := MakeMove('walk03', [5, 4, 4, 5, 4, 5, 6, 4, 4, 4, 4, 5]);
  end else
  if MonsterClass = 'monster_gunner' then
  begin
    if Run then
      Result := MakeMove('run01', [26, 9, 9, 9, 15, 10, 13, 6])
    else
      Result := MakeMove('walk07', [0, 3, 4, 5, 7, 2, 6, 4, 2, 7, 5, 7, 4]);
  end else
  if MonsterClass = 'monster_berserk' then
  begin
    { berserk_move_walk lists 12 distances for its 11 frames (walkc1 ..
      walkc11); Quake 2 plays only the first 11 }
    if Run then
      Result := MakeMove('run1', [21, 11, 21, 25, 18, 19])
    else
      Result := MakeMove('walkc1', [9.1, 6.3, 4.9, 6.7, 6.0, 8.2, 7.2, 6.1, 4.9, 4.7, 4.7]);
  end else
  if MonsterClass = 'monster_flyer' then
  begin
    { The flyer flies on its stand frames: 10 a frame running, 5 walking }
    if Run then
      Result := Even('stand01', 45, 10)
    else
      Result := Even('stand01', 45, 5);
  end else
  if MonsterClass = 'monster_parasite' then
    { parasite_move_run / parasite_move_walk: the same frames and distances }
    Result := MakeMove('run03', [30, 30, 22, 19, 24, 28, 25])
  else
  if Copy(MonsterClass, 1, 12) = 'monster_tank' then
    { tank_move_run / tank_move_walk: the same frames and distances }
    Result := MakeMove('walk05', [4, 5, 3, 2, 5, 5, 4, 4, 3, 5, 4, 5, 7, 7, 6, 6]);
end;

function MoveSeqSpeed(const Seq: TMonsterMoveSeq): Single;
var
  D: Single;
begin
  Result := 0;
  if Length(Seq.Dists) = 0 then
    Exit;
  for D in Seq.Dists do
    Result := Result + D;
  Result := Result / Length(Seq.Dists) / MonsterFrameTime;
end;

{ TMonsterMoveAnim }

procedure TMonsterMoveAnim.Start(const Seq: TMonsterMoveSeq);
begin
  FSeq := Seq;
  FFrame := 0;
  FOldFrame := 0;
  FClock := 0;
  FActive := Length(Seq.Dists) > 0;
end;

procedure TMonsterMoveAnim.Stop;
begin
  FActive := False;
end;

procedure TMonsterMoveAnim.Update(const SecondsPassed: Single);
begin
  if not FActive then
    Exit;
  FClock := FClock + SecondsPassed;
  while FClock >= MonsterFrameTime do
  begin
    FClock := FClock - MonsterFrameTime;
    FOldFrame := FFrame;
    FFrame := (FFrame + 1) mod Length(FSeq.Dists);
  end;
end;

function TMonsterMoveAnim.Speed: Single;
begin
  if FActive then
    Result := FSeq.Dists[FFrame] / MonsterFrameTime
  else
    Result := 0;
end;

function TMonsterMoveAnim.FrameLerp: Single;
begin
  Result := EnsureRange(FClock / MonsterFrameTime, 0, 1);
end;

end.
