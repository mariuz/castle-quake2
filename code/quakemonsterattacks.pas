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

  { When a sequence can be chosen (auDodge: only by a dodge, never by range) }
  TAttackUse = (auRanged, auMelee, auAny, auDodge);

  { When a refire loop goes back:
    lcSeen: while the player is visible, with LoopChance;
    lcRefire: soldier_attack*_refire: in melee range, or half the time on
      nightmare (else on to SkipFrame, if any);
    lcPause: soldier_attack3_refire: while the dodge pause has more than
      0.4 s left;
    lcMelee: flyer_check_melee: in melee range, with LoopChance }
  TLoopCondition = (lcSeen, lcRefire, lcPause, lcMelee);

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
    LoopCondition: TLoopCondition;
    { Frame to continue on when the loop doesn't go back (-1: the next) }
    SkipFrame: Integer;
    { Crouched on these frames (soldier_duck_down .. duck_up): the shot box
      is 32 lower (-1: never) }
    DuckFrom, DuckTo: Integer;
    Use: TAttackUse;
    { Only chosen farther than this (tank rockets: beyond 250) }
    MinDist: Single;
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
    function LoopsBack(const CanSee: Boolean): Boolean;
  public
    OnFire: TMonsterFireEvent;
    { Set by the monster before Update, for lcRefire / lcPause loops }
    Melee, Nightmare: Boolean;
    PauseLeft: Single;
    { Crouched now (DuckFrom .. DuckTo) }
    function Ducked: Boolean;
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
  Result.SkipFrame := -1;
  Result.DuckFrom := -1;
  Result.DuckTo := -1;
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

{ Machinegun burst: fire again on Frame for 3 .. 10 more frames }
function HoldBurst(const S: TMonsterAttackSeq; const Frame: Integer): TMonsterAttackSeq;
begin
  Result := S;
  Result.HoldFrame := Frame;
  Result.HoldMin := 3;
  Result.HoldMax := 10;
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
    { soldier_fire: blaster 5, shotgun 2 a pellet, machinegun 2 a bullet
      holding the frame for 3 .. 10 more frames (AI_HOLD_FRAME) }
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
    if MonsterClass = 'monster_soldier_ss' then
      { soldier_attack: the machinegun soldier (skin 4+) only uses attack4,
        firing on attak403 }
      AddSeq(Result, HoldBurst(MakeSeq('attak401', 6, [2], Kind, Damage, Sound), 2))
    else
    begin
      { attack1 fires on attak103. Light soldier: attack1_refire1 on attak106
        goes back to attak102, or skips the cocking to attak110; the
        shotgun soldier: attack1_refire2 on attak110 goes back to attak102 }
      S := MakeSeq('attak101', 12, [2], Kind, Damage, Sound);
      S.LoopCondition := lcRefire;
      S.LoopStart := 1;
      if MonsterClass = 'monster_soldier_light' then
      begin
        S.LoopEnd := 5;
        S.SkipFrame := 9;
      end else
        S.LoopEnd := 9;
      AddSeq(Result, S);
      { attack2 fires on attak205; refire1 on attak208 goes back to attak204
        or skips to attak216 (light), refire2 on attak216 goes back (shotgun) }
      S := MakeSeq('attak201', 18, [4], Kind, Damage, Sound);
      S.LoopCondition := lcRefire;
      S.LoopStart := 3;
      if MonsterClass = 'monster_soldier_light' then
      begin
        S.LoopEnd := 7;
        S.SkipFrame := 15;
      end else
        S.LoopEnd := 15;
      AddSeq(Result, S);
    end;
    { attack3, from soldier_dodge: duck down (attak303), fire, fire again
      from attak306 while the dodge pause lasts, stand up on attak307 }
    S := MakeSeq('attak301', 9, [2], Kind, Damage, Sound, auDodge);
    if Kind = akHitscan then
      S := HoldBurst(S, 2);
    S.LoopCondition := lcPause;
    S.LoopStart := 2;
    S.LoopEnd := 5;
    S.DuckFrom := 2;
    S.DuckTo := 5;
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
  begin
    { attack2: blaster bolts of 1 from alternating guns on attak205 .. 213 }
    AddSeq(Result, MakeSeq('attak201', 17, Frames(4, 12).FireFrames, akBlaster, 1, 'flyatck3'));
    { melee: pop the blades (attak101 .. 106), slash left on attak109 and
      right on attak114 (5 each), loop attak107 .. 118 again 80 % of the
      time while in melee range (flyer_check_melee), then attak119 .. 121 }
    S := MakeSeq('attak101', 21, [8, 13], akMelee, 5, 'flyatck2', auMelee);
    S.LoopStart := 6;
    S.LoopEnd := 17;
    S.LoopChance := 0.8;
    S.LoopCondition := lcMelee;
    AddSeq(Result, S);
  end else
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
      rockets: lean in, three rockets of 50 (attak322, 325, 328);
      attack_chain: TankMachineGun on attak406 .. 424, 19 bullets of 20 }
    AddSeq(Result, MakeSeq('attak101', 22, [9, 12, 15], akBlaster, 30, 'tnkatck3'));
    { tank_attack: rockets only beyond 250 units (closer: blast or chain) }
    S := MakeSeq('attak301', 53, [21, 24, 27], akRocket, 50, 'tnkatck1');
    S.MinDist := 250;
    AddSeq(Result, S);
    AddSeq(Result, MakeSeq('attak401', 29, Frames(5, 23).FireFrames, akHitscan, 20, 'tnkatk2a'));
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
      auDodge: Result := False;
      else Result := True;
    end;
    if Dist <= S.MinDist then
      Result := False;
  end;

begin
  Melee := Dist < MeleeDistance;
  N := 0;
  for I := 0 to High(Seqs) do
    if Fits(Seqs[I]) then
      Inc(N);
  if N = 0 then
  begin
    { Nothing for this range (e.g. a ranged monster up close): any but
      the dodge-only ones }
    for I := 0 to High(Seqs) do
      if (Seqs[I].Use <> auDodge) and (Dist > Seqs[I].MinDist) then
        Inc(N);
    if N = 0 then
      Exit(-1);
    Pick := Min(N - 1, Trunc(R * N));
    for I := 0 to High(Seqs) do
      if (Seqs[I].Use <> auDodge) and (Dist > Seqs[I].MinDist) then
      begin
        if Pick = 0 then
          Exit(I);
        Dec(Pick);
      end;
    Exit(-1);
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

function TMonsterAttack.LoopsBack(const CanSee: Boolean): Boolean;
begin
  case FSeq.LoopCondition of
    lcRefire: Result := Melee or (Nightmare and (Random < 0.5));
    { Quake 2 checks on entering LoopEnd, a frame before leaving it }
    lcPause: Result := PauseLeft + MonsterFrameTime > 0.4;
    lcMelee: Result := Melee and (Random < FSeq.LoopChance);
    else Result := CanSee and (Random < FSeq.LoopChance);
  end;
end;

function TMonsterAttack.Ducked: Boolean;
begin
  Result := FActive and (FSeq.DuckFrom >= 0) and (FFrame >= FSeq.DuckFrom) and (FFrame <= FSeq.DuckTo);
end;

procedure TMonsterAttack.Update(const SecondsPassed: Single; const CanSee: Boolean);
begin
  if not FActive then
    Exit;
  PauseLeft := PauseLeft - SecondsPassed;
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
    if FFrame = FSeq.LoopEnd then
    begin
      if LoopsBack(CanSee) then
        FFrame := FSeq.LoopStart
      else
      if FSeq.SkipFrame >= 0 then
        FFrame := FSeq.SkipFrame
      else
        Inc(FFrame);
    end else
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
