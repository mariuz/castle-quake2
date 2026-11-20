{ Quake 2's misc_insane (m_insane.c): the insane marines of the jail and
  lab levels. They are monsters on the player's side (AI_GOOD_GUY): they
  never notice or attack anyone, aren't counted in the kills, and medics
  leave their bodies alone. They stand and fidget, scream and moan, walk
  their path_corners, crawl (spawnflag 4) or hang crucified (8, struggling
  now and then). Facts (frames, sounds, health, flags) from id's game
  source (GPLv2); no code copied.

  The model's frames: stand1..stand160 (0..159), walk27..walk39 (160..172),
  walk1..walk26 (173..198), st_pain2..12 (199..209), st_death2..18
  (210..226), crawl1..9 (227..235), cr_pain2..10 (236..244), cr_death10..16
  (245..251), cross1..30 (252..281). }
unit QuakeInsane;

{$mode objfpc}{$H+}

interface

uses
  QuakeEntities, QuakeMonsterAttacks;

const
  INSANE_CRAWL = 4;
  INSANE_CRUCIFIED = 8;
  INSANE_STAND_GROUND = 16;
  INSANE_ALWAYS_STAND = 32;

  InsaneDef: TQuakeMonsterDef = (ClassName: 'misc_insane'; Model: 'models/monsters/insane/tris.md2';
    Skin: 0; Health: 100; Speed: 40; Attack: akMelee; Damage: 0; AttackRange: 0; AttackCooldown: 1;
    Flying: False; SoundDir: 'insane'; SightSound: ''; PainSound: ''; DeathSound: ''; AttackSound: '');

  { Frame ranges ('#first:count', TQuakeMd2.FindAnim) }
  InsaneStand = '#59:35';        { stand60..stand94: insane_move_stand_normal }
  InsaneFidget = '#99:61';       { stand100..stand160: insane_move_stand_insane }
  InsaneWalkNormal = '#160:13';  { walk27..walk39 }
  InsaneWalkInsane = '#173:26';  { walk1..walk26 }
  InsanePain = '#199:11';
  InsaneDeath = '#210:17';
  InsaneCrawl = '#227:9';
  InsaneCrawlStill = '#227:1';
  InsaneCrawlPain = '#236:9';
  InsaneCrawlDeath = '#245:7';
  InsaneCross = '#252:15';       { cross1..cross15: hanging }
  InsaneStruggle = '#267:15';    { cross16..cross30: struggling on the cross }
  InsaneCrossDead = '#252:1';

  InsaneMoan = 'sound/insane/insane7.wav';
  InsaneShake = 'sound/insane/insane5.wav';
  InsaneScreams: array[0..7] of String = ('sound/insane/insane1.wav', 'sound/insane/insane2.wav',
    'sound/insane/insane3.wav', 'sound/insane/insane4.wav', 'sound/insane/insane6.wav',
    'sound/insane/insane8.wav', 'sound/insane/insane9.wav', 'sound/insane/insane10.wav');

{ The frame range for PlayAnim names ('stand,idle,fidget', 'walk,run',
  'pain', 'death,die,dead') for an insane marine with these spawnflags;
  WalkInsane picks the staggering walk }
function InsaneAnim(const Names: String; const SpawnFlags: Integer; const WalkInsane: Boolean): String;

{ insane_pain: the player's male pain sound for the health left (25 / 50 /
  75 / 100), Variant 1 or 2 }
function InsanePainSound(const Health, Variant: Integer): String;
{ insane_die: player/male/death1..4 }
function InsaneDeathSound(const Variant: Integer): String;
{ An idle scream or moan: Pick in 0..1 }
function InsaneIdleSound(const Pick: Single): String;

implementation

uses
  SysUtils, Math;

function InsaneAnim(const Names: String; const SpawnFlags: Integer; const WalkInsane: Boolean): String;
var
  Crawl, Cross: Boolean;
begin
  Cross := (SpawnFlags and INSANE_CRUCIFIED) <> 0;
  Crawl := (not Cross) and ((SpawnFlags and INSANE_CRAWL) <> 0);
  if Pos('death', Names) > 0 then
  begin
    if Cross then
      Result := InsaneCrossDead
    else
    if Crawl then
      Result := InsaneCrawlDeath
    else
      Result := InsaneDeath;
  end else
  if Pos('pain', Names) > 0 then
  begin
    if Cross then
      Result := InsaneStruggle
    else
    if Crawl then
      Result := InsaneCrawlPain
    else
      Result := InsanePain;
  end else
  if (Pos('walk', Names) > 0) or (Pos('run', Names) > 0) then
  begin
    if Cross then
      Result := InsaneCross
    else
    if Crawl then
      Result := InsaneCrawl
    else
    if WalkInsane then
      Result := InsaneWalkInsane
    else
      Result := InsaneWalkNormal;
  end else
  begin
    if Cross then
      Result := InsaneCross
    else
    if Crawl then
      Result := InsaneCrawlStill
    else
      Result := InsaneStand;
  end;
end;

function InsanePainSound(const Health, Variant: Integer): String;
var
  L: Integer;
begin
  if Health < 25 then
    L := 25
  else
  if Health < 50 then
    L := 50
  else
  if Health < 75 then
    L := 75
  else
    L := 100;
  Result := Format('sound/player/male/pain%d_%d.wav', [L, EnsureRange(Variant, 1, 2)]);
end;

function InsaneDeathSound(const Variant: Integer): String;
begin
  Result := Format('sound/player/male/death%d.wav', [EnsureRange(Variant, 1, 4)]);
end;

function InsaneIdleSound(const Pick: Single): String;
begin
  if Pick < 0.3 then
    Result := InsaneMoan
  else
    Result := InsaneScreams[EnsureRange(Trunc((Pick - 0.3) / 0.7 * Length(InsaneScreams)), 0, High(InsaneScreams))];
end;

end.
