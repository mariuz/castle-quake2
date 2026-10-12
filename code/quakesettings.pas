{ Player options (mouse, field of view, volumes, key bindings, last skill),
  saved in CGE's UserConfig, and the skill of the game being played. }
unit QuakeSettings;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleKeysMouse, CastleXmlConfig;

type
  { Actions with a configurable key (weapon number keys stay fixed) }
  TQuakeAction = (qaForward, qaBack, qaMoveLeft, qaMoveRight, qaJump, qaCrouch,
    qaUse, qaFire, qaGrenade, qaHelp);

  TQuakeSettings = class
  public
    { Skill of the last new game: 0 easy, 1 medium, 2 hard, 3 nightmare }
    Skill: Integer;
    { Multiplier of CGE's default mouse look sensitivity }
    MouseSensitivity: Single;
    InvertMouse: Boolean;
    { Horizontal field of view in degrees (Quake 2 default 90) }
    FieldOfView: Integer;
    { Percent }
    SoundVolume, MusicVolume: Integer;
    Keys: array[TQuakeAction] of TKey;
    { Save to UserConfig (off in autotests: they use the defaults and must
      not change the user's settings) }
    Persistent: Boolean;
    constructor Create;
    procedure ResetToDefaults;
    procedure ResetKeys;
    { Read / write under "quake2/" in a config (UserConfig by default) }
    procedure Load(const Config: TCastleConfig = nil);
    procedure Save(const Config: TCastleConfig = nil);
    { Set the key of an action; an action that had this key gets the
      previous key of Action (swap), so no key does two things. }
    procedure BindKey(const Action: TQuakeAction; const Key: TKey);
    { Set the sound engine's effects volume and the music channel volume }
    procedure ApplyAudio;
    { Is Key bound to Action }
    function IsKey(const Action: TQuakeAction; const Key: TKey): Boolean;
  end;

const
  SkillNames: array[0..3] of String = ('Easy', 'Medium', 'Hard', 'Nightmare');
  ActionNames: array[TQuakeAction] of String = ('Move Forward', 'Move Back',
    'Strafe Left', 'Strafe Right', 'Jump', 'Crouch', 'Use', 'Fire',
    'Hand Grenades', 'Help Computer');
  DefaultKeys: array[TQuakeAction] of TKey = (keyW, keyS, keyA, keyD, keySpace, keyC,
    keyE, keyCtrl, keyG, keyF1);

  { Quake 2 spawnflags removing an entity on a skill }
  SPAWNFLAG_NOT_EASY = 256;
  SPAWNFLAG_NOT_MEDIUM = 512;
  SPAWNFLAG_NOT_HARD = 1024;

var
  Settings: TQuakeSettings;
  { Skill of the game being played (Quake 2's latched "skill" cvar): set by
    a new game, the "skill" console command and loading a savegame }
  GameSkill: Integer = 1;

{ Spawnflag that removes an entity on a skill (hard and nightmare share one) }
function SkillSpawnFlag(const ASkill: Integer): Integer;
{ Monster time between attacks is multiplied by this (Quake 2 M_CheckAttack
  halves the attack chance on easy and doubles it from hard on) }
function SkillAttackDelay(const ASkill: Integer): Single;

implementation

uses
  Math, CastleConfig, CastleSoundEngine;

function SkillSpawnFlag(const ASkill: Integer): Integer;
begin
  case ASkill of
    0: Result := SPAWNFLAG_NOT_EASY;
    1: Result := SPAWNFLAG_NOT_MEDIUM;
    else Result := SPAWNFLAG_NOT_HARD;
  end;
end;

function SkillAttackDelay(const ASkill: Integer): Single;
begin
  case ASkill of
    0: Result := 1.5;
    1: Result := 1.0;
    2: Result := 0.75;
    else Result := 0.6;
  end;
end;

{ TQuakeSettings }

constructor TQuakeSettings.Create;
begin
  inherited Create;
  Persistent := True;
  ResetToDefaults;
end;

procedure TQuakeSettings.ResetToDefaults;
begin
  Skill := 1;
  MouseSensitivity := 1;
  InvertMouse := False;
  FieldOfView := 90;
  SoundVolume := 100;
  MusicVolume := 70;
  ResetKeys;
end;

procedure TQuakeSettings.ResetKeys;
var
  A: TQuakeAction;
begin
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    Keys[A] := DefaultKeys[A];
end;

procedure TQuakeSettings.Load(const Config: TCastleConfig);
var
  C: TCastleConfig;
  A: TQuakeAction;
begin
  C := Config;
  if C = nil then
    C := UserConfig;
  Skill := EnsureRange(C.GetValue('quake2/skill', 1), 0, 3);
  MouseSensitivity := EnsureRange(C.GetFloat('quake2/mouse_sensitivity', 1), 0.1, 5);
  InvertMouse := C.GetValue('quake2/invert_mouse', False);
  FieldOfView := EnsureRange(C.GetValue('quake2/fov', 90), 60, 130);
  SoundVolume := EnsureRange(C.GetValue('quake2/sound_volume', 100), 0, 100);
  MusicVolume := EnsureRange(C.GetValue('quake2/music_volume', 70), 0, 100);
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    Keys[A] := StrToKey(C.GetValue('quake2/keys/' + IntToStr(Ord(A)),
      KeyToStr(DefaultKeys[A])), DefaultKeys[A]);
end;

procedure TQuakeSettings.Save(const Config: TCastleConfig);
var
  C: TCastleConfig;
  A: TQuakeAction;
begin
  C := Config;
  if C = nil then
  begin
    if not Persistent then
      Exit;
    C := UserConfig;
  end;
  C.SetDeleteValue('quake2/skill', Skill, 1);
  C.SetDeleteFloat('quake2/mouse_sensitivity', MouseSensitivity, 1);
  C.SetDeleteValue('quake2/invert_mouse', InvertMouse, False);
  C.SetDeleteValue('quake2/fov', FieldOfView, 90);
  C.SetDeleteValue('quake2/sound_volume', SoundVolume, 100);
  C.SetDeleteValue('quake2/music_volume', MusicVolume, 70);
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    C.SetDeleteValue('quake2/keys/' + IntToStr(Ord(A)), KeyToStr(Keys[A]), KeyToStr(DefaultKeys[A]));
  if Config = nil then
    UserConfig.Save;
end;

procedure TQuakeSettings.BindKey(const Action: TQuakeAction; const Key: TKey);
var
  A: TQuakeAction;
begin
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    if (A <> Action) and (Keys[A] = Key) then
      Keys[A] := Keys[Action];
  Keys[Action] := Key;
end;

procedure TQuakeSettings.ApplyAudio;
begin
  SoundEngine.Volume := SoundVolume / 100;
  SoundEngine.LoopingChannel[0].Volume := MusicVolume / 100;
end;

function TQuakeSettings.IsKey(const Action: TQuakeAction; const Key: TKey): Boolean;
begin
  Result := (Key <> keyNone) and (Keys[Action] = Key);
end;

initialization
  Settings := TQuakeSettings.Create;
finalization
  FreeAndNil(Settings);
end.
