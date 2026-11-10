{ Quake 1's monsters as Call of the Void (Quake II Remastered mod, -game
  q1q2) puts them in Quake 2: the ogre, knight, enforcer, grunt, zombie,
  scrag, fiend, rottweiler, hell knight, shambler, vore, rotfish and spawn,
  each in the mod's variants (plain, _prototype, _strogg ...). Their models
  keep Quake 1's frames in Quake 1's order (some name them only frame0 ..
  frameN), so the tables here address frames by index: '#<index>' in
  FirstFrame, computed from each monster's $frame list.

  The attack and walk / run tables are facts from Quake 1's QuakeC
  (id-Software/quake-rerelease-qc, quakec/monsters/*.qc): which frames
  play, the ai_walk / ai_run distance of each, the frames that attack and
  the damage. No QuakeC is copied (it is GPLv2; this project is MIT).
  Variants whose model has a different frame count keep the generic AI. }
unit QuakeQ1Monsters;

{$mode objfpc}{$H+}

interface

uses
  QuakeMonsterAttacks, QuakeMonsterMoves;

type
  TQ1Archetype = (qaNone, qaOgre, qaKnight, qaEnforcer, qaGrunt, qaZombie, qaScrag,
    qaFiend, qaDog, qaHellKnight, qaShambler, qaVore, qaFish, qaSpawn);

{ The Quake 1 monster a class is a variant of (qaNone: not one, or a model
  with other frames) }
function Q1Archetype(const MonsterClass: String): TQ1Archetype;

{ Model frame index of Quake 1's $<Group><N> (N from 1), -1 if none }
function Q1FrameIndex(const Arch: TQ1Archetype; const Group: String; const N: Integer): Integer;

{ Number of frames of the archetype's model }
function Q1FrameCount(const Arch: TQ1Archetype): Integer;

{ The $frame group holding model frame Index: its first frame and length }
function Q1GroupAt(const Arch: TQ1Archetype; const Index: Integer; out First, Count: Integer): Boolean;

{ '#first:count' animation (for TQuakeMd2.FindAnim) of an animation name
  the monster code asks for ('stand', 'walk', 'run', 'pain', 'death',
  'duck'); '' when the archetype has none }
function Q1AnimRange(const Arch: TQ1Archetype; const Name: String): String;

{ Attack sequences / walk or run loop of a Quake 1 monster class (empty
  when it isn't one) }
function Q1MonsterAttackSeqs(const MonsterClass: String): TMonsterAttackSeqs;
function Q1MonsterMoveSeq(const MonsterClass: String; const Run: Boolean): TMonsterMoveSeq;

implementation

uses
  SysUtils;

type
  TFrameGroup = record
    Name: String;
    Count: Integer;
  end;

function G(const Name: String; const Count: Integer): TFrameGroup;
begin
  Result.Name := Name;
  Result.Count := Count;
end;

{ Quake 1's $frame order of each monster }
function FrameGroups(const Arch: TQ1Archetype): specialize TArray<TFrameGroup>;
begin
  case Arch of
    qaOgre: Result := [G('stand', 9), G('walk', 16), G('run', 8), G('swing', 14), G('smash', 14),
      G('shoot', 6), G('pain', 5), G('painb', 3), G('painc', 6), G('paind', 16), G('paine', 15),
      G('death', 14), G('bdeath', 10), G('pull', 11)];
    qaKnight: Result := [G('stand', 9), G('runb', 8), G('runattack', 11), G('pain', 3), G('painb', 11),
      G('attackb', 11), G('walk', 14), G('kneel', 5), G('standing', 4), G('death', 10), G('deathb', 11)];
    qaEnforcer: Result := [G('stand', 7), G('walk', 16), G('run', 8), G('attack', 10), G('death', 14),
      G('fdeath', 11), G('paina', 4), G('painb', 5), G('painc', 8), G('paind', 19)];
    qaGrunt: Result := [G('stand', 8), G('death', 10), G('deathc', 11), G('load', 11), G('pain', 6),
      G('painb', 14), G('painc', 13), G('run', 8), G('shoot', 9), G('prowl_', 24)];
    qaZombie: Result := [G('stand', 15), G('walk', 19), G('run', 18), G('atta', 13), G('attb', 14),
      G('attc', 12), G('paina', 12), G('painb', 28), G('painc', 18), G('paind', 13), G('paine', 30),
      G('cruc_', 6)];
    qaScrag: Result := [G('hover', 15), G('fly', 14), G('magatt', 13), G('pain', 4), G('death', 8)];
    qaFiend: Result := [G('stand', 13), G('walk', 8), G('run', 6), G('leap', 12), G('pain', 6),
      G('death', 9), G('attacka', 15)];
    qaDog: Result := [G('attack', 8), G('death', 9), G('deathb', 9), G('pain', 6), G('painb', 16),
      G('run', 12), G('leap', 9), G('stand', 9), G('walk', 8)];
    qaHellKnight: Result := [G('stand', 9), G('walk', 20), G('run', 8), G('pain', 5), G('death', 12),
      G('deathb', 9), G('char_a', 16), G('magica', 14), G('magicb', 13), G('char_b', 6), G('slice', 10),
      G('smash', 11), G('w_attack', 22), G('magicc', 11)];
    qaShambler: Result := [G('stand', 17), G('walk', 12), G('run', 6), G('smash', 12), G('swingr', 9),
      G('swingl', 9), G('magic', 12), G('pain', 6), G('death', 11)];
    qaVore: Result := [G('attack', 11), G('pain', 5), G('death', 7), G('walk', 12)];
    qaFish: Result := [G('attack', 18), G('death', 21), G('swim', 18), G('pain', 9)];
    qaSpawn: Result := [G('walk', 25), G('run', 25), G('jump', 6), G('fly', 4), G('exp', 1)];
    else Result := nil;
  end;
end;

function Q1Archetype(const MonsterClass: String): TQ1Archetype;

  function OneOf(const Names: array of String): Boolean;
  var
    N: String;
  begin
    for N in Names do
      if MonsterClass = N then
        Exit(True);
    Result := False;
  end;

begin
  { Only the variants whose models have Quake 1's frames (the strogg ogre
    with 90 frames, the strogg vore with 138, the strogg dog on the
    parasite's tongue and the hybrids keep the generic AI) }
  if OneOf(['monster_ogre', 'monster_ogre_prototype', 'monster_ogre2_strogg']) then
    Result := qaOgre
  else
  if OneOf(['monster_knight', 'monster_knight_prototype', 'monster_knight_strogg']) then
    Result := qaKnight
  else
  if OneOf(['monster_enforcer', 'monster_enforcer_prototype', 'monster_enforcer_strogg']) then
    Result := qaEnforcer
  else
  if OneOf(['monster_soldier_grunt', 'monster_soldier_grunt_double', 'monster_soldier_grunt_prototype',
     'monster_soldier_strogg']) then
    Result := qaGrunt
  else
  if OneOf(['monster_zombie', 'monster_zombie_prototype', 'monster_zombie_strogg']) then
    Result := qaZombie
  else
  if OneOf(['monster_wizard', 'monster_wizard_prototype', 'monster_wizard_strogg',
     'monster_wizarcuda_strogg']) then
    Result := qaScrag
  else
  if OneOf(['monster_fiend', 'monster_fiend_prototype', 'monster_fiend_strogg']) then
    Result := qaFiend
  else
  if OneOf(['monster_dog', 'monster_dog_prototype']) then
    Result := qaDog
  else
  if OneOf(['monster_hellknight', 'monster_hknight_prototype', 'monster_hknight_hyper',
     'monster_hknight_bsk_strogg']) then
    Result := qaHellKnight
  else
  if OneOf(['monster_shambler', 'monster_shambler_prototype', 'monster_shambler_strogg',
     'monster_shamacudda']) then
    Result := qaShambler
  else
  if OneOf(['monster_shalrath', 'monster_shalrath_prototype']) then
    Result := qaVore
  else
  if MonsterClass = 'monster_fish' then
    Result := qaFish
  else
  if MonsterClass = 'monster_spawn' then
    Result := qaSpawn
  else
    Result := qaNone;
end;

function Q1FrameIndex(const Arch: TQ1Archetype; const Group: String; const N: Integer): Integer;
var
  Fg: TFrameGroup;
  Base: Integer;
begin
  Base := 0;
  for Fg in FrameGroups(Arch) do
  begin
    if Fg.Name = Group then
    begin
      if (N < 1) or (N > Fg.Count) then
        Exit(-1);
      Exit(Base + N - 1);
    end;
    Base := Base + Fg.Count;
  end;
  Result := -1;
end;

function Q1FrameCount(const Arch: TQ1Archetype): Integer;
var
  Fg: TFrameGroup;
begin
  Result := 0;
  for Fg in FrameGroups(Arch) do
    Result := Result + Fg.Count;
end;

function Q1GroupAt(const Arch: TQ1Archetype; const Index: Integer; out First, Count: Integer): Boolean;
var
  Fg: TFrameGroup;
begin
  First := 0;
  for Fg in FrameGroups(Arch) do
  begin
    if (Index >= First) and (Index < First + Fg.Count) then
    begin
      Count := Fg.Count;
      Exit(True);
    end;
    First := First + Fg.Count;
  end;
  Count := 0;
  Result := False;
end;

function GroupCount(const Arch: TQ1Archetype; const Group: String): Integer;
var
  Fg: TFrameGroup;
begin
  for Fg in FrameGroups(Arch) do
    if Fg.Name = Group then
      Exit(Fg.Count);
  Result := 0;
end;

{ '#index' of $<Group><N> }
function F(const Arch: TQ1Archetype; const Group: String; const N: Integer): String;
begin
  Result := '#' + IntToStr(Q1FrameIndex(Arch, Group, N));
end;

function Range(const Arch: TQ1Archetype; const Group: String): String;
begin
  if GroupCount(Arch, Group) = 0 then
    Exit('');
  Result := Format('#%d:%d', [Q1FrameIndex(Arch, Group, 1), GroupCount(Arch, Group)]);
end;

function Q1AnimRange(const Arch: TQ1Archetype; const Name: String): String;
var
  Stand, Walk, Run, Pain, Death: String;
begin
  Result := '';
  if Arch = qaNone then
    Exit;
  Stand := 'stand';
  Walk := 'walk';
  Run := 'run';
  Pain := 'pain';
  Death := 'death';
  case Arch of
    qaKnight: Run := 'runb';
    qaEnforcer: Pain := 'paina';
    qaGrunt: Walk := 'prowl_';
    qaZombie: Pain := 'paina';
    qaScrag:
      begin
        Stand := 'hover';
        Walk := 'hover';
        Run := 'fly';
      end;
    qaVore:
      begin
        Stand := 'walk';
        Run := 'walk';
      end;
    qaFish:
      begin
        Stand := 'swim';
        Walk := 'swim';
        Run := 'swim';
      end;
    qaSpawn:
      begin
        Stand := 'walk';
        Pain := 'walk';
        Death := 'exp';
      end;
  end;
  if Name = 'stand' then
    Result := Range(Arch, Stand)
  else
  if Name = 'walk' then
    Result := Range(Arch, Walk)
  else
  if Name = 'run' then
    Result := Range(Arch, Run)
  else
  if Name = 'pain' then
    Result := Range(Arch, Pain)
  else
  if Name = 'death' then
    Result := Range(Arch, Death);
end;

function Moves(const First: String; const Dists: array of Single): TMonsterMoveSeq;
var
  I: Integer;
begin
  Result.FirstFrame := First;
  SetLength(Result.Dists, Length(Dists));
  for I := 0 to High(Dists) do
    Result.Dists[I] := Dists[I];
end;

function EvenMoves(const First: String; const Count: Integer; const Dist: Single): TMonsterMoveSeq;
var
  I: Integer;
begin
  Result.FirstFrame := First;
  SetLength(Result.Dists, Count);
  for I := 0 to Count - 1 do
    Result.Dists[I] := Dist;
end;

function Q1MonsterMoveSeq(const MonsterClass: String; const Run: Boolean): TMonsterMoveSeq;
var
  A: TQ1Archetype;
begin
  Result := Default(TMonsterMoveSeq);
  A := Q1Archetype(MonsterClass);
  case A of
    qaOgre:
      if Run then
        Result := Moves(F(A, 'run', 1), [9, 12, 8, 22, 16, 4, 13, 24])
      else
        Result := Moves(F(A, 'walk', 1), [3, 2, 2, 2, 2, 5, 3, 2, 3, 1, 2, 3, 3, 3, 3, 4]);
    qaKnight:
      if Run then
        Result := Moves(F(A, 'runb', 1), [16, 20, 13, 7, 16, 20, 14, 6])
      else
        Result := Moves(F(A, 'walk', 1), [3, 2, 3, 4, 3, 3, 3, 4, 3, 3, 2, 3, 4, 3]);
    qaEnforcer:
      if Run then
        Result := Moves(F(A, 'run', 1), [18, 14, 7, 12, 14, 14, 7, 11])
      else
        Result := Moves(F(A, 'walk', 1), [2, 4, 4, 3, 1, 2, 2, 1, 2, 4, 4, 1, 2, 3, 4, 2]);
    qaGrunt:
      if Run then
        Result := Moves(F(A, 'run', 1), [11, 15, 10, 10, 8, 15, 10, 8])
      else
        Result := Moves(F(A, 'prowl_', 1), [1, 1, 1, 1, 2, 3, 4, 4, 2, 2, 2, 1, 0, 1, 1, 1, 3, 3, 3, 3,
          2, 1, 1, 1]);
    qaZombie:
      if Run then
        Result := Moves(F(A, 'run', 1), [1, 1, 0, 1, 2, 3, 4, 4, 2, 0, 0, 0, 2, 4, 6, 7, 3, 8])
      else
        Result := Moves(F(A, 'walk', 1), [0, 2, 3, 2, 1, 0, 0, 0, 0, 0, 2, 2, 1, 0, 0, 0, 0, 0, 0]);
    qaScrag:
      { wiz_walk flies on hover1 .. 8, wiz_run on fly1 .. 14 }
      if Run then
        Result := EvenMoves(F(A, 'fly', 1), 14, 16)
      else
        Result := EvenMoves(F(A, 'hover', 1), 8, 8);
    qaFiend:
      if Run then
        Result := Moves(F(A, 'run', 1), [20, 15, 36, 20, 15, 36])
      else
        Result := Moves(F(A, 'walk', 1), [8, 6, 6, 7, 4, 6, 10, 10]);
    qaDog:
      if Run then
        Result := Moves(F(A, 'run', 1), [16, 32, 32, 20, 64, 32, 16, 32, 32, 20, 64, 32])
      else
        Result := EvenMoves(F(A, 'walk', 1), 8, 8);
    qaHellKnight:
      if Run then
        Result := Moves(F(A, 'run', 1), [20, 25, 18, 16, 14, 25, 21, 13])
      else
        Result := Moves(F(A, 'walk', 1), [2, 5, 5, 4, 4, 2, 2, 3, 3, 4, 3, 4, 6, 2, 2, 4, 3, 3, 3, 2]);
    qaShambler:
      if Run then
        Result := Moves(F(A, 'run', 1), [20, 24, 20, 20, 24, 20])
      else
        Result := Moves(F(A, 'walk', 1), [10, 9, 9, 5, 6, 12, 8, 3, 13, 9, 7, 7]);
    qaVore:
      { shal_walk / shal_run: the same frames and distances (walk2 .. 12, walk1) }
      Result := Moves(F(A, 'walk', 1), [5, 6, 4, 0, 0, 0, 0, 5, 6, 5, 0, 4]);
    qaFish:
      if Run then
        Result := EvenMoves(F(A, 'swim', 1), 18, 12)
      else
        Result := EvenMoves(F(A, 'swim', 1), 18, 8);
    qaSpawn:
      { tbaby_walk / tbaby_run: ten frames turning, then 2 a frame }
      if Run then
        Result := Moves(F(A, 'run', 1), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          2, 2, 2, 2, 2])
      else
        Result := Moves(F(A, 'walk', 1), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          2, 2, 2, 2, 2]);
  end;
end;

{ A leap: takeoff on Frame, Forward / Up speeds, Damage + 0 .. Spread - 1
  on touch }
function LeapSeq(const First: String; const Count, Frame: Integer; const Forward, Up: Single;
  const Damage, Spread: Integer; const Sound: String; const MinDist: Single): TMonsterAttackSeq;
begin
  Result := MakeSeq(First, Count, [Frame], akLeap, Damage, Sound);
  Result.DamageRandom := Spread;
  Result.LeapForward := Forward;
  Result.LeapUp := Up;
  Result.MinDist := MinDist;
end;

function Q1MonsterAttackSeqs(const MonsterClass: String): TMonsterAttackSeqs;
var
  A: TQ1Archetype;
  S: TMonsterAttackSeq;
begin
  Result := nil;
  A := Q1Archetype(MonsterClass);
  case A of
    qaOgre:
      begin
        { ogre_melee, half and half: swing (chainsaw on swing5 .. 11) or
          smash (smash6 .. 11), (r + r + r) * 4 within 100 each;
          ogre_nail: a grenade of 40 on shoot4 }
        AddSeq(Result, MeleeSeq(F(A, 'swing', 1), 14, [4, 5, 6, 7, 8, 9, 10], 0, 13, 0, 'ogsawatk'));
        AddSeq(Result, MeleeSeq(F(A, 'smash', 1), 14, [5, 6, 7, 8, 9, 10], 0, 13, 0, 'ogsawatk'));
        AddSeq(Result, MakeSeq(F(A, 'shoot', 1), 6, [3], akGrenade, 40, 'ogshoot'));
      end;
    qaKnight:
      begin
        { knight_atk: the sword on attackb6 .. 8; knight_runatk: on
          runattack5 .. 9, (r + r + r) * 3 within 60 }
        AddSeq(Result, MeleeSeq(F(A, 'attackb', 1), 10, [5, 6, 7], 0, 10, 0, 'sword1'));
        AddSeq(Result, MeleeSeq(F(A, 'runattack', 1), 11, [4, 5, 6, 7, 8], 0, 10, 0, 'sword2'));
      end;
    qaEnforcer:
      begin
        { enf_atk: a laser of 15 (speed 600) on attack6, attack5 .. 8 again
          for a second one, then attack9 .. 10 }
        S := MakeSeq(F(A, 'attack', 1), 10, [5], akBlaster, 15, 'enfire');
        S := Looping(S, 4, 7, 1);
        S.MaxLoops := 1;
        S.Speed := 600;
        AddSeq(Result, S);
      end;
    qaGrunt:
      begin
        { army_atk: the shotgun, 4 pellets of 4, on shoot5; SUB_CheckRefire on
          shoot7 (nightmare: once more) }
        S := MakeSeq(F(A, 'shoot', 1), 9, [4], akPellets, 4, 'sattck1');
        S.Volley := 4;
        AddSeq(Result, Looping(S, 0, 6, 1, lcRefire));
      end;
    qaZombie:
      begin
        { zombie_atta / attb / attc: a lump of flesh (10 on a hit) thrown on
          the last frame }
        AddSeq(Result, MakeSeq(F(A, 'atta', 1), 13, [12], akGrenade, 10, 'z_shot1'));
        AddSeq(Result, MakeSeq(F(A, 'attb', 1), 14, [13], akGrenade, 10, 'z_shot1'));
        AddSeq(Result, MakeSeq(F(A, 'attc', 1), 12, [11], akGrenade, 10, 'z_shot1'));
      end;
    qaScrag:
      begin
        { wiz_fast: two spikes of 9 (speed 600), 0.3 and 0.8 s after
          Wiz_StartFast on magatt1 }
        S := MakeSeq(F(A, 'magatt', 1), 10, [3, 8], akBlaster, 9, 'wattack');
        S.Speed := 600;
        AddSeq(Result, S);
      end;
    qaFiend:
      begin
        { demon1_atta: claws of 10 .. 14 on attacka5 and attacka11;
          demon1_jump: leap (600 forward, 250 up) on leap4, 40 .. 49 on touch }
        AddSeq(Result, MeleeSeq(F(A, 'attacka', 1), 15, [4, 10], 10, 5, 0, 'dhit2'));
        AddSeq(Result, LeapSeq(F(A, 'leap', 1), 12, 3, 600, 250, 40, 10, 'djump', 100));
      end;
    qaDog:
      begin
        { dog_atta: a bite of (r + r + r) * 8 on attack4; dog_leap: 300
          forward, 200 up on leap2, 10 .. 19 on touch }
        AddSeq(Result, MeleeSeq(F(A, 'attack', 1), 8, [3], 0, 25, 0, 'dattack1'));
        AddSeq(Result, LeapSeq(F(A, 'leap', 1), 9, 1, 300, 200, 10, 10, 'dattack1', 80));
      end;
    qaHellKnight:
      begin
        { hknight_magica / b / c: six spikes of 9 (speed 300) fanning out
          (6 degrees apart); melee: slice, smash, w_attack (ai_melee:
          (r + r + r) * 3) }
        S := MakeSeq(F(A, 'magica', 1), 14, [6, 7, 8, 9, 10, 11], akBlaster, 9, 'attack1');
        S.Speed := 300;
        S.YawStep := 6;
        S.YawCenter := 8;
        AddSeq(Result, S);
        S := MakeSeq(F(A, 'magicb', 1), 13, [6, 7, 8, 9, 10, 11], akBlaster, 9, 'attack1');
        S.Speed := 300;
        S.YawStep := 6;
        S.YawCenter := 8;
        AddSeq(Result, S);
        AddSeq(Result, MeleeSeq(F(A, 'slice', 1), 10, [4, 5, 6, 7, 8], 0, 10, 0, 'slash1'));
        AddSeq(Result, MeleeSeq(F(A, 'smash', 1), 11, [4, 5, 6, 7, 8], 0, 10, 0, 'slash1'));
        AddSeq(Result, MeleeSeq(F(A, 'w_attack', 1), 22, [3, 4, 5, 9, 10, 11, 16, 17, 18], 0, 10, 0, 'slash1'));
      end;
    qaShambler:
      begin
        { sham_smash: (r + r + r) * 40 on smash10; sham_swingl / r: claws of
          (r + r + r) * 20 on swing7; sham_magic: lightning of 10 on
          magic6 .. 8 }
        AddSeq(Result, MeleeSeq(F(A, 'smash', 1), 12, [9], 0, 121, 0, 'smack'));
        AddSeq(Result, MeleeSeq(F(A, 'swingl', 1), 9, [6], 0, 61, 0, 'shurt2'));
        AddSeq(Result, MeleeSeq(F(A, 'swingr', 1), 9, [6], 0, 61, 0, 'shurt2'));
        AddSeq(Result, MakeSeq(F(A, 'magic', 1), 10, [5, 6, 7], akHitscan, 10, 'sboom'));
      end;
    qaVore:
      { shal_attack: a homing pod of 40 (speed 400) on attack9 }
      begin
        S := MakeSeq(F(A, 'attack', 1), 11, [8], akRocket, 40, 'attack2');
        S.Speed := 400;
        AddSeq(Result, S);
      end;
    qaFish:
      { f_attack: bites of (r + r) * 3 on attack3, 9 and 15 }
      AddSeq(Result, MeleeSeq(F(A, 'attack', 1), 18, [2, 8, 14], 0, 7, 0, 'bite'));
    qaSpawn:
      { tbaby_jump: 600 forward, 200 up on jump5, 10 .. 19 on touch }
      AddSeq(Result, LeapSeq(F(A, 'jump', 1), 6, 4, 600, 200, 10, 10, 'sight1', 0));
  end;
end;

end.
