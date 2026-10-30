{ Game controller (gamepad) input: stick deadzones, look speed and the
  button layout, on top of CGE's Controllers.

  Layout (Xbox names; CGE's gbSouth / gbEast / gbWest / gbNorth):
    left stick       move / strafe          right stick    look
    right trigger    fire                   left trigger   crouch
    A (south)        jump                   B (east)       crouch
    X (west)         use                    Y (north)      hand grenades
    bumpers, D-pad up / down                cycle weapons
    Menu (start)     menu                   View (back)    help computer
  In menus: D-pad / left stick to choose, A to confirm, B to go back.
  The face buttons, bumpers, View, stick clicks and D-pad left / right can be
  rebound (Settings.PadButtons, Options -> Controls -> Gamepad); the sticks,
  triggers, Menu and D-pad up / down are fixed. A left stick click also
  crouches while no action is bound to it.

  The mapping functions are plain code so the unit tests can check them
  without a device. }
unit QuakeGamepad;

{$mode objfpc}{$H+}

interface

uses
  CastleVectors, CastleKeysMouse;

const
  { Stick positions inside this radius are ignored (worn sticks don't
    return to 0) }
  StickDeadZone = 0.2;
  { Analog triggers count as pressed above this }
  TriggerThreshold = 0.5;
  { Look speed at full stick deflection and sensitivity 1, degrees / second
    (Quake 2 cl_yawspeed 140, cl_pitchspeed 150 for the arrow keys) }
  GamepadYawSpeed = 160;
  GamepadPitchSpeed = 120;
  { A stick pushed this far counts as a menu arrow press }
  StickMenuThreshold = 0.6;

type
  { Gamepad input of one frame, summed over all connected controllers }
  TGamepadInput = record
    Connected: Boolean;
    Forward, Side: Single;
    { Degrees to turn this frame: yaw left, pitch up }
    YawDeg, PitchDeg: Single;
    Fire, Jump, Crouch: Boolean;
    { Left stick direction as a menu arrow (keyNone when centered) }
    MenuArrow: TKey;
  end;

{ Radial deadzone: 0 inside the deadzone, then rescaled so the input still
  goes from 0 to 1 (no jump at the deadzone edge); clamped to length 1 }
function ApplyDeadZone(const Stick: TVector2; const DeadZone: Single = StickDeadZone): TVector2;

{ Left stick to InputForward / InputSide (stick up = forward, right = right) }
procedure StickToMove(const Stick: TVector2; out Forward, Side: Single);

{ Right stick to degrees of turn this frame. The squared response gives
  fine aim near the center and full speed at the edge. Sensitivity is the
  mouse sensitivity option; Invert flips the pitch like the mouse option. }
procedure StickToLook(const Stick: TVector2; const SecondsPassed, Sensitivity: Single;
  const Invert: Boolean; out YawDeg, PitchDeg: Single);

{ Stick direction as an arrow key for menus }
function StickToArrow(const Stick: TVector2): TKey;

{ Key a game controller button stands for in menus (keyNone if none) }
function GamepadMenuKey(const Button: TGameControllerButton): TKey;

{ A controller press as the key press it means in menus; other events are
  returned unchanged }
function GamepadMenuEvent(const Event: TInputPressRelease): TInputPressRelease;

{ Weapon cycle direction of a button: 1 next, -1 previous, 0 none
  (Settings.PadButtons, plus the fixed D-pad up / down) }
function GamepadWeaponCycle(const Button: TGameControllerButton): Integer;

type
  { Virtual controller for demo scripts (autotests have no device) }
  TVirtualGamepad = record
    Active: Boolean;
    Left, Right: TVector2;
    LeftTrigger, RightTrigger: Single;
    { Buttons held down (GH: demo action) }
    Held: set of TGameControllerButton;
  end;

var
  VirtualGamepad: TVirtualGamepad;

{ Read all connected controllers (after InitializeGamepads) and the
  virtual one }
function ReadGamepads(const SecondsPassed, Sensitivity: Single;
  const Invert: Boolean): TGamepadInput;

{ Button from a short name (south, east, west, north, lb, rb, up, down, left,
  right, menu, view, ls, rs, guide, share); False if unknown }
function GamepadButtonFromName(const Name: String; out Button: TGameControllerButton): Boolean;

{ Start polling controllers; CGE then sends button presses as input events }
procedure InitializeGamepads;

implementation

uses
  SysUtils, Math, CastleGameControllers, CastleLog, QuakeSettings;

function ApplyDeadZone(const Stick: TVector2; const DeadZone: Single): TVector2;
var
  Len: Single;
begin
  Len := Stick.Length;
  if (Len <= DeadZone) or (Len = 0) then
    Exit(TVector2.Zero);
  Result := Stick * (Min((Len - DeadZone) / (1 - DeadZone), 1) / Len);
end;

procedure StickToMove(const Stick: TVector2; out Forward, Side: Single);
var
  S: TVector2;
begin
  S := ApplyDeadZone(Stick);
  Forward := S.Y;
  Side := S.X;
end;

procedure StickToLook(const Stick: TVector2; const SecondsPassed, Sensitivity: Single;
  const Invert: Boolean; out YawDeg, PitchDeg: Single);
var
  S: TVector2;
  Len, Scale: Single;
begin
  S := ApplyDeadZone(Stick);
  Len := S.Length;
  { Squared response along the stick direction }
  Scale := Len * Sensitivity * SecondsPassed;
  { Stick right turns right, i.e. negative (counter-clockwise) yaw }
  YawDeg := -S.X * Scale * GamepadYawSpeed;
  PitchDeg := S.Y * Scale * GamepadPitchSpeed;
  if Invert then
    PitchDeg := -PitchDeg;
end;

function StickToArrow(const Stick: TVector2): TKey;
begin
  Result := keyNone;
  if Max(Abs(Stick.X), Abs(Stick.Y)) < StickMenuThreshold then
    Exit;
  if Abs(Stick.Y) >= Abs(Stick.X) then
  begin
    if Stick.Y > 0 then
      Result := keyArrowUp
    else
      Result := keyArrowDown;
  end else
  if Stick.X > 0 then
    Result := keyArrowRight
  else
    Result := keyArrowLeft;
end;

function GamepadMenuKey(const Button: TGameControllerButton): TKey;
begin
  case Button of
    gbDPadUp: Result := keyArrowUp;
    gbDPadDown: Result := keyArrowDown;
    gbDPadLeft: Result := keyArrowLeft;
    gbDPadRight: Result := keyArrowRight;
    gbSouth: Result := keyEnter;
    gbEast, gbMenu: Result := keyEscape;
    else Result := keyNone;
  end;
end;

function GamepadMenuEvent(const Event: TInputPressRelease): TInputPressRelease;
var
  Key: TKey;
begin
  Result := Event;
  if Event.EventType <> itGameController then
    Exit;
  Key := GamepadMenuKey(Event.Controller.Button);
  if Key <> keyNone then
    Result := InputKey(Event.Position, Key, '', Event.ModifiersDown);
end;

function GamepadWeaponCycle(const Button: TGameControllerButton): Integer;
var
  A: TPadAction;
begin
  case Button of
    gbDPadUp: Exit(1);
    gbDPadDown: Exit(-1);
  end;
  Result := 0;
  if Settings.PadActionOf(Button, A) then
    case A of
      paNextWeapon: Result := 1;
      paPrevWeapon: Result := -1;
    end;
end;

{ Is a held button jump / crouch, by the bindings }
procedure HeldActions(const Down: array of Boolean; out JumpHeld, CrouchHeld: Boolean);
var
  A: TPadAction;
begin
  JumpHeld := Down[Ord(Settings.PadButtons[paJump])];
  CrouchHeld := Down[Ord(Settings.PadButtons[paCrouch])] or
    ((not Settings.PadActionOf(gbLeftStickClick, A)) and Down[Ord(gbLeftStickClick)]);
end;

function ReadGamepads(const SecondsPassed, Sensitivity: Single;
  const Invert: Boolean): TGamepadInput;
var
  R: TGamepadInput;

  procedure AddController(const Left, Right: TVector2; const LeftTrigger, RightTrigger: Single;
    const JumpHeld, CrouchHeld: Boolean);
  var
    F, S, Yaw, Pitch: Single;
  begin
    R.Connected := True;
    StickToMove(Left, F, S);
    R.Forward := R.Forward + F;
    R.Side := R.Side + S;
    StickToLook(Right, SecondsPassed, Sensitivity, Invert, Yaw, Pitch);
    R.YawDeg := R.YawDeg + Yaw;
    R.PitchDeg := R.PitchDeg + Pitch;
    R.Fire := R.Fire or (RightTrigger > TriggerThreshold);
    R.Jump := R.Jump or JumpHeld;
    R.Crouch := R.Crouch or CrouchHeld or (LeftTrigger > TriggerThreshold);
    if R.MenuArrow = keyNone then
      R.MenuArrow := StickToArrow(Left);
  end;

var
  I: Integer;
  C: TGameController;
  B: TGameControllerButton;
  Down: array[TGameControllerButton] of Boolean;
  JumpHeld, CrouchHeld: Boolean;
begin
  R := Default(TGamepadInput);
  if Controllers.Initialized then
    for I := 0 to Controllers.Count - 1 do
    begin
      C := Controllers[I];
      for B := Low(B) to High(B) do
        Down[B] := C.Pressed[B];
      HeldActions(Down, JumpHeld, CrouchHeld);
      AddController(C.AxisLeft, C.AxisRight, C.AxisLeftTrigger, C.AxisRightTrigger,
        JumpHeld, CrouchHeld);
    end;
  if VirtualGamepad.Active or (VirtualGamepad.Held <> []) then
  begin
    for B := Low(B) to High(B) do
      Down[B] := B in VirtualGamepad.Held;
    HeldActions(Down, JumpHeld, CrouchHeld);
    AddController(VirtualGamepad.Left, VirtualGamepad.Right, VirtualGamepad.LeftTrigger,
      VirtualGamepad.RightTrigger, JumpHeld, CrouchHeld);
  end;
  Result := R;
  Result.Forward := EnsureRange(Result.Forward, -1, 1);
  Result.Side := EnsureRange(Result.Side, -1, 1);
end;

function GamepadButtonFromName(const Name: String; out Button: TGameControllerButton): Boolean;
begin
  Result := PadButtonFromName(Name, Button);
end;

procedure InitializeGamepads;
var
  I: Integer;
begin
  try
    Controllers.Initialize;
    for I := 0 to Controllers.Count - 1 do
      WritelnLog('Gamepad', 'Controller %d: %s', [I, Controllers[I].Name]);
  except
    on E: Exception do
      WritelnWarning('Gamepad', 'Cannot initialize game controllers: ' + E.Message);
  end;
end;

end.
