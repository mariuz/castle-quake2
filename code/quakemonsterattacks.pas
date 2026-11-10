{ Monster attacks on Quake 2's animation frames (the mframe_t tables of
  m_soldier.c, m_infantry.c, m_gunner.c, m_berserk.c, m_flyer.c,
  m_parasite.c, m_tank.c, and of the full game's m_gladiator.c, m_chick.c,
  m_mutant.c, m_brain.c, m_float.c, m_hover.c, m_flipper.c, m_medic.c,
  m_supertank.c, m_boss2.c, m_boss31.c (Jorg), m_boss32.c (Makron)):
  which model frames an attack plays, on which of them it fires, bursts
  that hold a frame (AI_HOLD_FRAME) and refire loops. TMonsterAttack plays
  one sequence at Quake 2's 10 frames a second.

  Plain code without scenes, so the unit tests can step it. Monsters
  without a table here keep the generic attack. }
unit QuakeMonsterAttacks;

{$mode objfpc}{$H+}

interface

const
  { Quake 2 monsters think (and animate) every 0.1 s }
  MonsterFrameTime = 0.1;
  { Quake 2 MELEE_DISTANCE (RANGE_MELEE) }
  MeleeDistance = 80;

type
  { akBfg: monster_fire_bfg (Jorg, Makron); akLeap: the mutant's jump
    (mutant_jump_takeoff: forward 600, up 250, hurts on touch) }
  TAttackKind = (akMelee, akHitscan, akBlaster, akRocket, akGrenade, akRail, akPellets,
    akBfg, akLeap);

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
    { Shots fired at once on a fire frame (Jorg's two guns, the hornet's
      four rockets); 1 normally }
    Volley: Integer;
    { fire_hit's kick: the player is pushed this fast away from the
      monster on a melee hit (negative pulls: the brain's tentacles) }
    Kick: Single;
    { BFG effect radius of akBfg balls (dmg_radius) }
    Radius: Single;
    { Frame on which the target's position is saved and the shot aimed at it,
      not at where the target is when it fires (gladiator: 0 = at the start,
      Makron's railgun: MakronSaveloc); -1: aim when firing }
    AimFrame: Integer;
    { MakronHyperblaster: the shots sweep across, the yaw offset following
      the frame }
    Sweep: Boolean;
    { Relative chance among the sequences that fit (default 1) }
    Weight: Single;
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

{ Yaw offset in degrees of the Makron's sweeping hyperblaster on frame F }
function SweepYaw(const F: Integer): Single;

{ Index of a sequence to use at distance Dist (R in 0..1 picks among the
  usable ones by their Weight); -1 when none fits }
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
  Result.Volley := 1;
  Result.AimFrame := -1;
  Result.Weight := 1;
end;

{ A sequence chosen with Weight among those that fit }
function Weighted(const S: TMonsterAttackSeq; const Weight: Single): TMonsterAttackSeq;
begin
  Result := S;
  Result.Weight := Weight;
end;

{ Refire: after LoopEnd go back to LoopStart with Chance while visible }
function Looping(const S: TMonsterAttackSeq; const LoopStart, LoopEnd: Integer;
  const Chance: Single; const Condition: TLoopCondition = lcSeen): TMonsterAttackSeq;
begin
  Result := S;
  Result.LoopStart := LoopStart;
  Result.LoopEnd := LoopEnd;
  Result.LoopChance := Chance;
  Result.LoopCondition := Condition;
end;

{ Melee hit of Damage .. Damage + Spread - 1 with fire_hit's Kick }
function MeleeSeq(const First: String; const Count: Integer; const Fire: array of Integer;
  const Damage, Spread: Integer; const Kick: Single; const Sound: String): TMonsterAttackSeq;
begin
  Result := MakeSeq(First, Count, Fire, akMelee, Damage, Sound, auMelee);
  Result.DamageRandom := Spread;
  Result.Kick := Kick;
end;

{ Yaw offset (degrees) of MakronHyperblaster's shot on frame F of attak401:
  attak405 .. 413 swing from 80 back to 0, attak414 .. 421 from -70 to 0 }
function SweepYaw(const F: Integer): Single;
begin
  if F <= 12 then
    Result := -10 * (F - 12)
  else
    Result := 10 * (F - 20);
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
  { The tank commander is m_tank.c too }
  if (MonsterClass = 'monster_tank') or (MonsterClass = 'monster_tank_commander') then
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
  end else
  if MonsterClass = 'monster_gladiator' then
  begin
    { gladiator_attack (beyond MELEE_DISTANCE + 32): save the target's
      position, railgun of 50 at it on attack4; gladiator_melee: cleaver
      hits of 20 .. 24 (kick 300) on melee7 and melee14 }
    S := MakeSeq('attack1', 9, [3], akRail, 50, 'railgun');
    S.AimFrame := 0;
    S.MinDist := MeleeDistance + 32;
    AddSeq(Result, S);
    AddSeq(Result, MeleeSeq('melee1', 17, [6, 13], 20, 5, 300, 'melee1'));
  end else
  if MonsterClass = 'monster_chick' then
  begin
    { chick_attack: start_attack1 (attak101 .. 113), rocket of 50 on
      attak114, reload, chick_rerocket on attak127 goes back to attak114 60 %
      of the time while visible and not in melee range, end_attack1 to
      attak132. chick_melee: slash of 10 .. 15 (kick 100) on attak205,
      chick_reslash on attak212 again 90 % of the time in melee range }
    AddSeq(Result, Looping(MakeSeq('attak101', 32, [13], akRocket, 50, 'chkatck2'), 13, 26, 0.6));
    S := MeleeSeq('attak201', 16, [4], 10, 6, 100, 'chkatck3');
    AddSeq(Result, Looping(S, 3, 11, 0.9, lcMelee));
  end else
  if MonsterClass = 'monster_mutant' then
  begin
    { mutant_melee: hits of 10 .. 14 (kick 100) on attack11 and attack14,
      mutant_check_refire on attack15 again in melee range (or half the time
      on nightmare). Farther than 100 units: the jump (attack01 .. 08), taking
      off on attack03; 40 .. 49 damage when it lands on the player }
    AddSeq(Result, Looping(MeleeSeq('attack09', 7, [2, 5], 10, 5, 100, 'mutatck1'), 0, 6, 1, lcRefire));
    S := MakeSeq('attack01', 8, [2], akLeap, 40, 'mutatck2');
    S.DamageRandom := 10;
    S.MinDist := 100;
    AddSeq(Result, S);
  end else
  if MonsterClass = 'monster_brain' then
  begin
    { brain_melee, half and half: attack1, claws of 15 .. 19 (kick 40) on
      attak108 and attak112; attack2, the tentacles of 10 .. 14 on attak207
      pulling the player in (kick -600) }
    AddSeq(Result, MeleeSeq('attak101', 18, [7, 11], 15, 5, 40, 'melee1'));
    AddSeq(Result, MeleeSeq('attak201', 17, [6], 10, 5, -600, 'melee3'));
  end else
  if MonsterClass = 'monster_floater' then
  begin
    { floater_attack: blaster bolts of 1 on attak104 .. 110; floater_melee,
      half and half: attack3, the zap of 5 .. 10 on attak309; attack2, the
      wham of 5 .. 10 (kick -50) on attak212 }
    AddSeq(Result, MakeSeq('attak101', 14, Frames(3, 9).FireFrames, akBlaster, 1, 'fltatck1'));
    AddSeq(Result, MeleeSeq('attak301', 34, [8], 5, 6, 0, 'fltatck2'));
    AddSeq(Result, MeleeSeq('attak201', 25, [11], 5, 6, -50, 'fltatck3'));
  end else
  if MonsterClass = 'monster_hover' then
    { start_attack (attak101 .. 103), blaster bolts of 1 on attak104 and 105,
      hover_reattack on attak106 again 60 % of the time while visible,
      end_attack to attak108 }
    AddSeq(Result, Looping(MakeSeq('attak101', 8, [3, 4], akBlaster, 1, 'hovatck1'), 3, 5, 0.6))
  else
  if MonsterClass = 'monster_flipper' then
    { flipper_melee: bites of 5 on flpbit14 and flpbit19 }
    AddSeq(Result, MeleeSeq('flpbit01', 20, [13, 18], 5, 0, 0, 'flpatck1'))
  else
  if MonsterClass = 'monster_medic' then
    { medic_attack: blaster bolts of 2 on attack9 and attack12, then
      medic_continue (95 %: the hyperblaster, a bolt every frame of
      attack19 .. 30); the cable that revives monsters is TQuakeMonster's }
    AddSeq(Result, MakeSeq('attack1', 30, [8, 11, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29],
      akBlaster, 2, 'medatck1'))
  else
  if MonsterClass = 'monster_supertank' then
  begin
    { supertank_attack: within 160 the chaingun, beyond it the chaingun 30 %
      of the time, else three rockets of 50 (attakb8, b11, b14). Chaingun:
      a bullet of 6 every frame of attaka1 .. 6, supertank_reattack1 again
      90 % of the time while visible, then attaka7 .. 20 }
    S := MakeSeq('attaka1', 20, Frames(0, 5).FireFrames, akHitscan, 6, 'btkunqv1', auAny);
    AddSeq(Result, Weighted(Looping(S, 0, 5, 0.9), 0.3));
    S := MakeSeq('attakb1', 27, [7, 10, 13], akRocket, 50, 'btkunqv2');
    S.MinDist := 160;
    AddSeq(Result, Weighted(S, 0.7));
  end else
  if MonsterClass = 'monster_boss2' then
  begin
    { boss2_attack: within 125 the machineguns, beyond 60 % machineguns,
      40 % rockets. Machineguns: pre_mg (attack1 .. 9), both guns fire a
      bullet of 6 on each of attack10 .. 14, boss2_reattack_mg on attack15
      again 70 % of the time, post_mg to attack19. Rockets: four of 50 at
      once on attack32 }
    S := MakeSeq('attack1', 19, Frames(9, 13).FireFrames, akHitscan, 6, '', auAny);
    S.Volley := 2;
    AddSeq(Result, Weighted(Looping(S, 9, 14, 0.7), 0.6));
    S := MakeSeq('attack20', 21, [12], akRocket, 50, '');
    S.Volley := 4;
    S.MinDist := 125;
    AddSeq(Result, Weighted(S, 0.4));
  end else
  if MonsterClass = 'monster_jorg' then
  begin
    { jorg_attack: 75 % the chainguns (start_attack1 attak101 .. 108, both
      fire a bullet of 6 on each of attak109 .. 114, jorg_reattack1 again 90 %
      of the time while visible, end to attak118); 25 % a BFG ball of 50
      (radius 200) on attak207 }
    S := MakeSeq('attak101', 18, Frames(8, 13).FireFrames, akHitscan, 6, 'bs3atck1', auAny);
    S.Volley := 2;
    S.SoundOnce := True;
    AddSeq(Result, Weighted(Looping(S, 8, 13, 0.9), 0.75));
    S := MakeSeq('attak201', 13, [6], akBfg, 50, 'bs3atck2', auAny);
    S.Radius := 200;
    AddSeq(Result, Weighted(S, 0.25));
  end else
  if MonsterClass = 'monster_makron' then
  begin
    { makron_attack: 30 % a BFG ball of 50 (radius 300) on attak304; 30 % the
      hyperblaster, bolts of 15 on attak405 .. 421 sweeping across; 40 % the
      railgun of 50 on attak509 at where the target was on attak508 }
    S := MakeSeq('attak301', 8, [3], akBfg, 50, 'bfg_fire', auAny);
    S.Radius := 300;
    AddSeq(Result, Weighted(S, 0.3));
    S := MakeSeq('attak401', 26, Frames(4, 20).FireFrames, akBlaster, 15, 'blaster', auAny);
    S.Sweep := True;
    AddSeq(Result, Weighted(S, 0.3));
    S := MakeSeq('attak501', 16, [8], akRail, 50, 'rail_up', auAny);
    S.AimFrame := 7;
    AddSeq(Result, Weighted(S, 0.4));
  end;
end;

function ChooseAttackSeq(const Seqs: TMonsterAttackSeqs; const Dist, R: Single): Integer;
var
  I, N: Integer;
  Melee: Boolean;
  Total, Pick: Single;

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

  function AnyFits(const S: TMonsterAttackSeq): Boolean;
  begin
    Result := (S.Use <> auDodge) and (Dist > S.MinDist);
  end;

var
  Relaxed: Boolean;

  function Usable(const S: TMonsterAttackSeq): Boolean;
  begin
    if Relaxed then
      Result := AnyFits(S)
    else
      Result := Fits(S);
  end;

begin
  Melee := Dist < MeleeDistance;
  { Nothing for this range (e.g. a ranged monster up close): any but the
    dodge-only ones }
  Relaxed := False;
  N := 0;
  for I := 0 to High(Seqs) do
    if Usable(Seqs[I]) then
      Inc(N);
  if N = 0 then
  begin
    Relaxed := True;
    for I := 0 to High(Seqs) do
      if Usable(Seqs[I]) then
        Inc(N);
    if N = 0 then
      Exit(-1);
  end;
  { Pick by Weight }
  Total := 0;
  for I := 0 to High(Seqs) do
    if Usable(Seqs[I]) then
      Total := Total + Max(0.0001, Seqs[I].Weight);
  Pick := R * Total;
  Result := -1;
  for I := 0 to High(Seqs) do
    if Usable(Seqs[I]) then
    begin
      Result := I;
      Pick := Pick - Max(0.0001, Seqs[I].Weight);
      if Pick < 0 then
        Exit;
    end;
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
