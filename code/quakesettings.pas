{ Player options (mouse, field of view, volumes, key and gamepad bindings, last skill),
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
  { Actions with a configurable game controller button (the sticks, the
    triggers, Menu and D-pad up / down stay fixed) }
  TPadAction = (paJump, paCrouch, paUse, paGrenade, paHelp, paNextWeapon, paPrevWeapon);

  TQuakeSettings = class
  public
    { Skill of the last new game: 0 easy, 1 medium, 2 hard, 3 nightmare }
    Skill: Integer;
    { Multiplier of CGE's default mouse look sensitivity }
    MouseSensitivity: Single;
    InvertMouse: Boolean;
    { View and weapon bob, landing dip, damage kicks }
    ViewBob: Boolean;
    { Horizontal field of view in degrees (Quake 2 default 90) }
    FieldOfView: Integer;
    { Percent }
    SoundVolume, MusicVolume: Integer;
    { Size of the menu, console and HUD text: 0 auto (larger on touch
      screens), 1..4 small, normal, large, huge (InterfaceSizeNames) }
    InterfaceSize: Integer;
    Keys: array[TQuakeAction] of TKey;
    PadButtons: array[TPadAction] of TGameControllerButton;
    { Save to UserConfig (off in autotests: they use the defaults and must
      not change the user's settings) }
    Persistent: Boolean;
    constructor Create;
    procedure ResetToDefaults;
    procedure ResetKeys;
    procedure ResetPadButtons;
    { Read / write under "quake2/" in a config (UserConfig by default) }
    procedure Load(const Config: TCastleConfig = nil);
    procedure Save(const Config: TCastleConfig = nil);
    { Set the key of an action; an action that had this key gets the
      previous key of Action (swap), so no key does two things. }
    procedure BindKey(const Action: TQuakeAction; const Key: TKey);
    { Same for a controller button (swaps with the action that had it);
      False for buttons that can't be bound (PadButtonBindable) }
    function BindPadButton(const Action: TPadAction; const Button: TGameControllerButton): Boolean;
    { Action bound to a controller button }
    function PadActionOf(const Button: TGameControllerButton; out Action: TPadAction): Boolean;
    { Set the sound engine's effects volume and the music channel volume }
    procedure ApplyAudio;
    { Is Key bound to Action }
    function IsKey(const Action: TQuakeAction; const Key: TKey): Boolean;
  end;

const
  InterfaceSizeNames: array[0..4] of String = ('Auto', 'Small', 'Normal', 'Large', 'Huge');
  InterfaceSizeScales: array[1..4] of Single = (0.8, 1.0, 1.4, 1.75);
  { Auto on touch screens: phones are small, rows must be big enough to tap }
  TouchInterfaceScale = 1.75;

  SkillNames: array[0..3] of String = ('Easy', 'Medium', 'Hard', 'Nightmare');
  ActionNames: array[TQuakeAction] of String = ('Move Forward', 'Move Back',
    'Strafe Left', 'Strafe Right', 'Jump', 'Crouch', 'Use', 'Fire',
    'Hand Grenades', 'Help Computer');
  DefaultKeys: array[TQuakeAction] of TKey = (keyW, keyS, keyA, keyD, keySpace, keyC,
    keyE, keyCtrl, keyG, keyF1);

  PadActionNames: array[TPadAction] of String = ('Jump', 'Crouch', 'Use',
    'Hand Grenades', 'Help Computer', 'Next Weapon', 'Previous Weapon');
  DefaultPadButtons: array[TPadAction] of TGameControllerButton = (gbSouth, gbEast,
    gbWest, gbNorth, gbView, gbRightBumper, gbLeftBumper);
  { Short names (config, console, demo scripts) and labels (Xbox layout) }
  PadButtonNames: array[TGameControllerButton] of String = ('north', 'east', 'south',
    'west', 'lb', 'rb', 'ls', 'rs', 'up', 'right', 'down', 'left', 'view', 'menu',
    'guide', 'share');
  PadButtonLabels: array[TGameControllerButton] of String = ('Y', 'B', 'A', 'X',
    'LB', 'RB', 'Left Stick', 'Right Stick', 'D-Pad Up', 'D-Pad Right', 'D-Pad Down',
    'D-Pad Left', 'View', 'Menu', 'Guide', 'Share');

  { Quake 2 spawnflags removing an entity on a skill }
  SPAWNFLAG_NOT_EASY = 256;
  SPAWNFLAG_NOT_MEDIUM = 512;
  SPAWNFLAG_NOT_HARD = 1024;

var
  Settings: TQuakeSettings;
  { Skill of the game being played (Quake 2's latched "skill" cvar): set by
    a new game, the "skill" console command and loading a savegame }
  GameSkill: Integer = 1;
  { Touch screen (or --touch): set at startup, Auto interface size is larger }
  TouchInterface: Boolean;

{ Menu opens the menu, D-pad up / down cycle weapons and choose in menus,
  Guide belongs to the system: these can't be bound }
function PadButtonBindable(const Button: TGameControllerButton): Boolean;
{ Button from its short name (PadButtonNames, case-insensitive) }
function PadButtonFromName(const Name: String; out Button: TGameControllerButton): Boolean;

{ Extra scale of the menu, console and HUD text over CGE's UIScale, from
  Settings.InterfaceSize (and TouchInterface for Auto) }
function InterfaceScale: Single;
{ Same for a given size setting (pure, for the tests) }
function InterfaceScaleFor(const Size: Integer; const Touch: Boolean): Single;

{ Spawnflag that removes an entity on a skill (hard and nightmare share one) }
function SkillSpawnFlag(const ASkill: Integer): Integer;
{ Monster time between attacks is multiplied by this (Quake 2 M_CheckAttack
  halves the attack chance on easy and doubles it from hard on) }
function SkillAttackDelay(const ASkill: Integer): Single;

implementation

uses
  Math, CastleConfig, CastleSoundEngine;

function InterfaceScaleFor(const Size: Integer; const Touch: Boolean): Single;
begin
  if (Size >= Low(InterfaceSizeScales)) and (Size <= High(InterfaceSizeScales)) then
    Result := InterfaceSizeScales[Size]
  else
  if Touch then
    Result := TouchInterfaceScale
  else
    Result := 1;
end;

function InterfaceScale: Single;
begin
  if Settings = nil then
    Result := InterfaceScaleFor(0, TouchInterface)
  else
    Result := InterfaceScaleFor(Settings.InterfaceSize, TouchInterface);
end;

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

function PadButtonBindable(const Button: TGameControllerButton): Boolean;
begin
  Result := not (Button in [gbMenu, gbGuide, gbDPadUp, gbDPadDown]);
end;

function PadButtonFromName(const Name: String; out Button: TGameControllerButton): Boolean;
var
  B: TGameControllerButton;
begin
  for B := Low(TGameControllerButton) to High(TGameControllerButton) do
    if SameText(PadButtonNames[B], Name) then
    begin
      Button := B;
      Exit(True);
    end;
  Button := gbSouth;
  Result := False;
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
  ViewBob := True;
  FieldOfView := 90;
  SoundVolume := 100;
  MusicVolume := 70;
  InterfaceSize := 0;
  ResetKeys;
  ResetPadButtons;
end;

procedure TQuakeSettings.ResetPadButtons;
var
  A: TPadAction;
begin
  for A := Low(TPadAction) to High(TPadAction) do
    PadButtons[A] := DefaultPadButtons[A];
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
  PA: TPadAction;
  B: TGameControllerButton;
begin
  C := Config;
  if C = nil then
    C := UserConfig;
  Skill := EnsureRange(C.GetValue('quake2/skill', 1), 0, 3);
  MouseSensitivity := EnsureRange(C.GetFloat('quake2/mouse_sensitivity', 1), 0.1, 5);
  InvertMouse := C.GetValue('quake2/invert_mouse', False);
  ViewBob := C.GetValue('quake2/view_bob', True);
  FieldOfView := EnsureRange(C.GetValue('quake2/fov', 90), 60, 130);
  SoundVolume := EnsureRange(C.GetValue('quake2/sound_volume', 100), 0, 100);
  MusicVolume := EnsureRange(C.GetValue('quake2/music_volume', 70), 0, 100);
  InterfaceSize := EnsureRange(C.GetValue('quake2/interface_size', 0), 0, High(InterfaceSizeNames));
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    Keys[A] := StrToKey(C.GetValue('quake2/keys/' + IntToStr(Ord(A)),
      KeyToStr(DefaultKeys[A])), DefaultKeys[A]);
  for PA := Low(TPadAction) to High(TPadAction) do
    if PadButtonFromName(C.GetValue('quake2/pad/' + IntToStr(Ord(PA)),
      PadButtonNames[DefaultPadButtons[PA]]), B) and PadButtonBindable(B) then
      PadButtons[PA] := B
    else
      PadButtons[PA] := DefaultPadButtons[PA];
end;

procedure TQuakeSettings.Save(const Config: TCastleConfig);
var
  C: TCastleConfig;
  A: TQuakeAction;
  PA: TPadAction;
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
  C.SetDeleteValue('quake2/view_bob', ViewBob, True);
  C.SetDeleteValue('quake2/fov', FieldOfView, 90);
  C.SetDeleteValue('quake2/sound_volume', SoundVolume, 100);
  C.SetDeleteValue('quake2/music_volume', MusicVolume, 70);
  C.SetDeleteValue('quake2/interface_size', InterfaceSize, 0);
  for A := Low(TQuakeAction) to High(TQuakeAction) do
    C.SetDeleteValue('quake2/keys/' + IntToStr(Ord(A)), KeyToStr(Keys[A]), KeyToStr(DefaultKeys[A]));
  for PA := Low(TPadAction) to High(TPadAction) do
    C.SetDeleteValue('quake2/pad/' + IntToStr(Ord(PA)), PadButtonNames[PadButtons[PA]],
      PadButtonNames[DefaultPadButtons[PA]]);
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

function TQuakeSettings.BindPadButton(const Action: TPadAction;
  const Button: TGameControllerButton): Boolean;
var
  A: TPadAction;
begin
  Result := PadButtonBindable(Button);
  if not Result then
    Exit;
  for A := Low(TPadAction) to High(TPadAction) do
    if (A <> Action) and (PadButtons[A] = Button) then
      PadButtons[A] := PadButtons[Action];
  PadButtons[Action] := Button;
end;

function TQuakeSettings.PadActionOf(const Button: TGameControllerButton;
  out Action: TPadAction): Boolean;
var
  A: TPadAction;
begin
  for A := Low(TPadAction) to High(TPadAction) do
    if PadButtons[A] = Button then
    begin
      Action := A;
      Exit(True);
    end;
  Action := paJump;
  Result := False;
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
