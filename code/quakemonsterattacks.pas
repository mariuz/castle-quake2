{ Monster attacks on Quake 2's animation frames (the mframe_t tables of
  m_soldier.c, m_infantry.c, m_gunner.c, m_berserk.c, m_flyer.c,
  m_parasite.c, m_tank.c): which model frames an attack plays, on which
  of them it fires, bursts that hold a frame (AI_HOLD_FRAME) and refire
  loops. TMonsterAttack plays one sequence at Quake 2's 10 frames a second.

  Plain code without scenes, so the unit tests can step it. Monsters
  without a table here (the full game's others) keep the generic attack. }
unit QuakeMonsterAttacks;

{$mode objfpc}{$H+}

interface

const
  { Quake 2 monsters think (and animate) every 0.1 s }
  MonsterFrameTime = 0.1;
  { Quake 2 MELEE_DISTANCE (RANGE_MELEE) }
  MeleeDistance = 80;

type
  TAttackKind = (akMelee, akHitscan, akBlaster, akRocket, akGrenade, akRail, akPellets);

  { When a sequence can be chosen }
  TAttackUse = (auRanged, auMelee, auAny);

  TMonsterAttackSeq = record
    { Model frame where the sequence starts (e.g. 'attak101') and its length }
    FirstFrame: String;
    Count: Integer;
    { Frames (0-based in the sequence) that fire }
    FireFrames: array of Integer;
    Kind: TAttackKind;
    { Damage of the first shot, of the later ones (0: the same), plus 0 ..
      DamageRandom - 1 }
    Damage, RepeatDamage, DamageRandom: Integer;
    { Sound file in the monster's sound directory, played with the shots
      (only the first when SoundOnce) }
    Sound: String;
    SoundOnce: Boolean;
    { Burst: on HoldFrame fire again every frame for HoldMin .. HoldMax more
      frames while the player is visible (-1: none) }
    HoldFrame, HoldMin, HoldMax: Integer;
    { Refire: after LoopEnd go back to LoopStart with LoopChance while the
      player is visible (-1: none) }
    LoopStart, LoopEnd: Integer;
    LoopChance: Single;
    Use: TAttackUse;
  end;
  PMonsterAttackSeq = ^TMonsterAttackSeq;

  TMonsterAttackSeqs = array of TMonsterAttackSeq;

  TMonsterFireEvent = procedure(const ShotIndex: Integer) of object;

  { One attack sequence being played }
  TMonsterAttack = class
  strict private
    FSeq: TMonsterAttackSeq;
    FFrame, FOldFrame: Integer;
    FClock: Single;
    FHoldLeft: Integer;
    FShots: Integer;
    FActive: Boolean;
    procedure EnterFrame(const CanSee: Boolean);
    procedure Fire;
  public
    OnFire: TMonsterFireEvent;
    { Start Seq on its frame 0 (fires at once if frame 0 is a fire frame) }
    procedure Start(const Seq: TMonsterAttackSeq; const CanSee: Boolean = True);
    procedure Stop;
    { Advance; CanSee decides bursts and refire loops }
    procedure Update(const SecondsPassed: Single; const CanSee: Boolean);
    property Active: Boolean read FActive;
    property Seq: TMonsterAttackSeq read FSeq;
    property Frame: Integer read FFrame;
    property OldFrame: Integer read FOldFrame;
    { 0..1 from OldFrame to Frame, for drawing }
    function FrameLerp: Single;
    { Shots fired so far }
    property Shots: Integer read FShots;
    { Damage of a shot by index, with its random part }
    function ShotDamage(const ShotIndex: Integer): Integer;
  end;

{ Attack sequences of a monster class (empty: no table, generic attack) }
function MonsterAttackSeqs(const MonsterClass: String): TMonsterAttackSeqs;

{ Index of a sequence to use at distance Dist (R in 0..1 picks among the
  usable ones); -1 when none fits }
function ChooseAttackSeq(const Seqs: TMonsterAttackSeqs; const Dist, R: Single): Integer;

implementation

uses
  Math;

function MakeSeq(const First: String; const Count: Integer; const Fire: array of Integer;
  const Kind: TAttackKind; const Damage: Integer; const Sound: String;
  const Use: TAttackUse = auRanged): TMonsterAttackSeq;
var
  I: Integer;
begin
  Result := Default(TMonsterAttackSeq);
  Result.FirstFrame := First;
  Result.Count := Count;
  SetLength(Result.FireFrames, Length(Fire));
  for I := 0 to High(Fire) do
    Result.FireFrames[I] := Fire[I];
  Result.Kind := Kind;
  Result.Damage := Damage;
  Result.Sound := Sound;
  Result.HoldFrame := -1;
  Result.LoopStart := -1;
  Result.LoopEnd := -1;
  Result.Use := Use;
end;

function Frames(const First, Last: Integer): TMonsterAttackSeq;
var
  I: Integer;
begin
  { Only FireFrames is used: a helper for runs of fire frames }
  Result := Default(TMonsterAttackSeq);
  SetLength(Result.FireFrames, Last - First + 1);
  for I := First to Last do
    Result.FireFrames[I - First] := I;
end;

procedure AddSeq(var Seqs: TMonsterAttackSeqs; const S: TMonsterAttackSeq);
begin
  SetLength(Seqs, Length(Seqs) + 1);
  Seqs[High(Seqs)] := S;
end;

function MonsterAttackSeqs(const MonsterClass: String): TMonsterAttackSeqs;
var
  S: TMonsterAttackSeq;
  Kind: TAttackKind;
  Damage: Integer;
  Sound: String;
begin
  Result := nil;
  if (MonsterClass = 'monster_soldier_light') or (MonsterClass = 'monster_soldier') or
     (MonsterClass = 'monster_soldier_ss') then
  begin
    { soldier_attack: attack1 (fire on attak103) or attack2 (attak205);
      soldier_fire: blaster 5, shotgun 2 a pellet, machinegun 2 a bullet
      holding the frame for 3 .. 10 more frames }
    if MonsterClass = 'monster_soldier_light' then
    begin
      Kind := akBlaster;
      Damage := 5;
      Sound := 'solatck2';
    end else
    if MonsterClass = 'monster_soldier' then
    begin
      Kind := akPellets;
      Damage := 2;
      Sound := 'solatck1';
    end else
    begin
      Kind := akHitscan;
      Damage := 2;
      Sound := 'solatck3';
    end;
    S := MakeSeq('attak101', 12, [2], Kind, Damage, Sound);
    if Kind = akHitscan then
    begin
      S.HoldFrame := 2;
      S.HoldMin := 3;
      S.HoldMax := 10;
    end;
    AddSeq(Result, S);
    S := MakeSeq('attak201', 18, [4], Kind, Damage, Sound);
    if Kind = akHitscan then
    begin
      S.HoldFrame := 4;
      S.HoldMin := 3;
      S.HoldMax := 10;
    end;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_infantry' then
  begin
    { attack1: cock the gun on attak104, fire on attak111 and hold it until
      the pause set when cocking (10 .. 25 frames) runs out; attack2 in
      melee range: smack on attak206, 5 .. 9 }
    S := MakeSeq('attak101', 15, [10], akHitscan, 3, 'infatck1');
    S.HoldFrame := 10;
    S.HoldMin := 3;
    S.HoldMax := 18;
    AddSeq(Result, S);
    S := MakeSeq('attak201', 8, [5], akMelee, 5, 'infatck2', auMelee);
    S.DamageRandom := 5;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_gunner' then
  begin
    { attack_grenade: four grenades (attak105, 108, 111, 114);
      attack_chain: spin up, fire every frame of attak216 .. 223, refire
      the loop half of the time, wind down. Melee range: chain only. }
    AddSeq(Result, MakeSeq('attak101', 21, [4, 7, 10, 13], akGrenade, 50, 'gunatck3'));
    S := MakeSeq('attak209', 22, Frames(7, 14).FireFrames, akHitscan, 3, 'gunatck2', auAny);
    S.LoopStart := 7;
    S.LoopEnd := 14;
    S.LoopChance := 0.5;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_berserk' then
  begin
    { berserk_melee: spike (att_c4, 15 .. 20) or club (att_c17, 5 .. 10) }
    S := MakeSeq('att_c1', 8, [3], akMelee, 15, 'attack', auMelee);
    S.DamageRandom := 6;
    AddSeq(Result, S);
    S := MakeSeq('att_c9', 12, [8], akMelee, 5, 'attack', auMelee);
    S.DamageRandom := 6;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_flyer' then
    { attack2: blaster bolts of 1 from alternating guns on attak205 .. 213 }
    AddSeq(Result, MakeSeq('attak201', 17, Frames(4, 12).FireFrames, akBlaster, 1, 'flyatck3'))
  else
  if MonsterClass = 'monster_parasite' then
  begin
    { drain: launch the proboscis, drain on drain03 .. drain13 (5, then 2) }
    S := MakeSeq('drain01', 18, Frames(2, 12).FireFrames, akMelee, 5, 'paratck3', auAny);
    S.RepeatDamage := 2;
    S.SoundOnce := True;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_tank' then
  begin
    { attack_blast: three blaster bolts of 30 (attak110, 113, 116);
      rockets: lean in, three rockets of 50 (attak322, 325, 328) }
    AddSeq(Result, MakeSeq('attak101', 22, [9, 12, 15], akBlaster, 30, 'tnkatck3'));
    AddSeq(Result, MakeSeq('attak301', 53, [21, 24, 27], akRocket, 50, 'tnkatck1'));
  end;
end;

function ChooseAttackSeq(const Seqs: TMonsterAttackSeqs; const Dist, R: Single): Integer;
var
  I, N, Pick: Integer;
  Melee: Boolean;

  function Fits(const S: TMonsterAttackSeq): Boolean;
  begin
    case S.Use of
      auMelee: Result := Melee;
      auRanged: Result := not Melee;
      else Result := True;
    end;
  end;

begin
  Melee := Dist < MeleeDistance;
  N := 0;
  for I := 0 to High(Seqs) do
    if Fits(Seqs[I]) then
      Inc(N);
  if N = 0 then
  begin
    { Nothing for this range (e.g. a ranged monster up close): any }
    if Length(Seqs) = 0 then
      Exit(-1);
    Exit(Min(High(Seqs), Trunc(R * Length(Seqs))));
  end;
  Pick := Min(N - 1, Trunc(R * N));
  for I := 0 to High(Seqs) do
    if Fits(Seqs[I]) then
    begin
      if Pick = 0 then
        Exit(I);
      Dec(Pick);
    end;
  Result := -1;
end;

{ TMonsterAttack }

procedure TMonsterAttack.Start(const Seq: TMonsterAttackSeq; const CanSee: Boolean);
begin
  FSeq := Seq;
  FFrame := 0;
  FOldFrame := 0;
  FClock := 0;
  FHoldLeft := 0;
  FShots := 0;
  FActive := Seq.Count > 0;
  if FActive then
    EnterFrame(CanSee);
end;

procedure TMonsterAttack.Stop;
begin
  FActive := False;
end;

function TMonsterAttack.FrameLerp: Single;
begin
  Result := EnsureRange(FClock / MonsterFrameTime, 0, 1);
end;

function TMonsterAttack.ShotDamage(const ShotIndex: Integer): Integer;
begin
  if (ShotIndex > 0) and (FSeq.RepeatDamage > 0) then
    Result := FSeq.RepeatDamage
  else
    Result := FSeq.Damage;
  if FSeq.DamageRandom > 0 then
    Result := Result + Random(FSeq.DamageRandom);
end;

procedure TMonsterAttack.Fire;
begin
  if Assigned(OnFire) then
    OnFire(FShots);
  Inc(FShots);
end;

procedure TMonsterAttack.EnterFrame(const CanSee: Boolean);
var
  F: Integer;
begin
  for F in FSeq.FireFrames do
    if F = FFrame then
    begin
      Fire;
      Break;
    end;
  if (FFrame = FSeq.HoldFrame) and CanSee then
    FHoldLeft := FSeq.HoldMin + Random(Max(1, FSeq.HoldMax - FSeq.HoldMin + 1));
end;

procedure TMonsterAttack.Update(const SecondsPassed: Single; const CanSee: Boolean);
begin
  if not FActive then
    Exit;
  FClock := FClock + SecondsPassed;
  while FActive and (FClock >= MonsterFrameTime) do
  begin
    FClock := FClock - MonsterFrameTime;
    FOldFrame := FFrame;
    { AI_HOLD_FRAME: fire again on the same frame }
    if (FHoldLeft > 0) and CanSee then
    begin
      Dec(FHoldLeft);
      Fire;
      Continue;
    end;
    FHoldLeft := 0;
    if (FFrame = FSeq.LoopEnd) and CanSee and (Random < FSeq.LoopChance) then
      FFrame := FSeq.LoopStart
    else
      Inc(FFrame);
    if FFrame >= FSeq.Count then
    begin
      FFrame := FSeq.Count - 1;
      FActive := False;
      Exit;
    end;
    EnterFrame(CanSee);
  end;
end;

end.
