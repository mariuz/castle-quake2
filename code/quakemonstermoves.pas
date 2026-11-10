{ Monster walking and running on Quake 2's animation frames: the looping
  walk / run mframe_t tables of m_soldier.c, m_infantry.c, m_gunner.c,
  m_berserk.c, m_flyer.c, m_parasite.c, m_tank.c and the full game's
  m_gladiator.c, m_chick.c, m_mutant.c, m_brain.c, m_float.c, m_hover.c,
  m_flipper.c, m_medic.c, m_supertank.c, m_boss2.c, m_boss31.c and
  m_boss32.c, each frame with the
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
    Result := MakeMove('walk05', [4, 5, 3, 2, 5, 5, 4, 4, 3, 5, 4, 5, 7, 7, 6, 6])
  else
  if MonsterClass = 'monster_gladiator' then
  begin
    if Run then
      Result := MakeMove('run1', [23, 14, 14, 21, 12, 13])
    else
      Result := MakeMove('walk1', [15, 7, 6, 5, 2, 0, 2, 8, 12, 8, 5, 5, 2, 2, 1, 8]);
  end else
  if MonsterClass = 'monster_chick' then
    { chick_move_run / chick_move_walk: the same frames and distances }
    Result := MakeMove('walk11', [6, 8, 13, 5, 7, 4, 11, 5, 9, 7])
  else
  if MonsterClass = 'monster_mutant' then
  begin
    if Run then
      Result := MakeMove('run03', [40, 40, 24, 5, 17, 10])
    else
      Result := MakeMove('walk05', [3, 1, 5, 10, 13, 10, 0, 5, 6, 16, 15, 6]);
  end else
  if MonsterClass = 'monster_brain' then
  begin
    { brain_move_run / brain_move_walk1 (the brain shuffles back a little) }
    if Run then
      Result := MakeMove('walk101', [9, 2, 3, 3, 1, 0, 0, 10, -4, -1, 2])
    else
      Result := MakeMove('walk101', [7, 2, 3, 3, 1, 0, 0, 9, -4, -1, 2]);
  end else
  if MonsterClass = 'monster_floater' then
  begin
    { The floater flies on its stand1 frames: 13 a frame running, 5 walking }
    if Run then
      Result := Even('stand101', 52, 13)
    else
      Result := Even('stand101', 52, 5);
  end else
  if MonsterClass = 'monster_hover' then
  begin
    if Run then
      Result := Even('forwrd01', 35, 10)
    else
      Result := Even('forwrd01', 35, 4);
  end else
  if MonsterClass = 'monster_flipper' then
  begin
    { flipper_move_run_loop (FLIPPER_RUN_SPEED 24) / flipper_move_walk }
    if Run then
      Result := Even('flpver06', 24, 24)
    else
      Result := Even('flphor01', 24, 4);
  end else
  if MonsterClass = 'monster_medic' then
  begin
    if Run then
      Result := MakeMove('run1', [18, 22.5, 25.4, 23.4, 24, 35.6])
    else
      Result := MakeMove('walk1', [6.2, 18.1, 1, 9, 10, 9, 11, 11.6, 2, 9.9, 14, 9.3]);
  end else
  if MonsterClass = 'monster_supertank' then
  begin
    { supertank_move_run / supertank_move_forward on the forwrd frames }
    if Run then
      Result := Even('forwrd1', 18, 12)
    else
      Result := Even('forwrd1', 18, 4);
  end else
  if MonsterClass = 'monster_boss2' then
    { boss2_move_run / boss2_move_walk: 8 a frame }
    Result := Even('walk1', 20, 8)
  else
  if MonsterClass = 'monster_jorg' then
    { jorg_move_run / jorg_move_walk: the same frames and distances }
    Result := MakeMove('walk06', [17, 0, 0, 0, 12, 8, 10, 33, 0, 0, 0, 9, 9, 9])
  else
  if MonsterClass = 'monster_makron' then
    { makron_move_run / makron_move_walk: the same }
    Result := MakeMove('walk204', [3, 12, 8, 8, 8, 6, 12, 9, 6, 12]);
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
