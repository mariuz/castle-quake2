{ On-screen touch controls for phones and tablets (Android, mobile web):
  a move stick that appears where the left thumb touches, drag anywhere on
  the right to look, and buttons for fire, jump, crouch, use, next weapon
  and the menu. Multi-touch: every finger has its own role until lifted.

  The view reads Stick / TakeLook / the held buttons each frame and gets
  OnUse / OnNextWeapon / OnMenu presses. On desktop it can be tried with
  the --touch command-line option (the mouse is one finger). }
unit QuakeTouch;

{$mode objfpc}{$H+}

interface

uses
  Classes, CastleVectors, CastleUIControls, CastleKeysMouse, CastleRectangles;

type
  TTouchButton = (tbFire, tbJump, tbCrouch, tbUse, tbWeapon, tbMenu);

  TQuakeTouchControls = class(TCastleUserInterface)
  strict private
    FMoveFinger, FLookFinger: Integer;
    FMoveOrigin, FMovePos, FLookLast: TVector2;
    FLookDelta: TVector2;
    FButtonFinger: array[TTouchButton] of Integer;
    FOnUse, FOnNextWeapon, FOnMenu: TNotifyEvent;
    function StickRadius: Single;
    function ButtonCircle(const B: TTouchButton; out Middle: TVector2): Single;
    function ButtonAt(const P: TVector2; out B: TTouchButton): Boolean;
    function LocalPos(const P: TVector2): TVector2;
  public
    { Look speed: degrees per pixel dragged (times the mouse sensitivity) }
    LookDegreesPerPixel: Single;
    constructor Create(AOwner: TComponent); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;
    procedure Render; override;
    { Forget all fingers (when hidden by a menu, death...) }
    procedure ResetTouches;
    { Move stick, -1..1 (up = forward, right = strafe right) }
    function Stick: TVector2;
    { Pixels dragged on the look side since the last call }
    function TakeLook: TVector2;
    function Held(const B: TTouchButton): Boolean;
    property OnUse: TNotifyEvent read FOnUse write FOnUse;
    property OnNextWeapon: TNotifyEvent read FOnNextWeapon write FOnNextWeapon;
    property OnMenu: TNotifyEvent read FOnMenu write FOnMenu;
  end;

const
  TouchButtonLabels: array[TTouchButton] of String = ('FIRE', 'JUMP', 'DUCK', 'USE', 'WPN', 'MENU');

var
  { --touch: show the touch controls on desktop too }
  TouchControlsForced: Boolean;

{ Touch controls are wanted: a touch device (Android, iOS) or --touch }
function TouchControlsWanted: Boolean;

{ Stick vector of a drag from Origin to Pos with the given radius: clamped
  to length 1 (pure, for the unit tests) }
function TouchStickVector(const Origin, Pos: TVector2; const Radius: Single): TVector2;

implementation

uses
  Math, CastleGLUtils, CastleColors, CastleControls, CastleApplicationProperties;

function TouchControlsWanted: Boolean;
begin
  Result := TouchControlsForced or ApplicationProperties.TouchDevice;
end;

function TouchStickVector(const Origin, Pos: TVector2; const Radius: Single): TVector2;
var
  D: TVector2;
  L: Single;
begin
  if Radius <= 0 then
    Exit(TVector2.Zero);
  D := (Pos - Origin) / Radius;
  L := D.Length;
  if L > 1 then
    D := D / L;
  Result := D;
end;

{ TQuakeTouchControls }

constructor TQuakeTouchControls.Create(AOwner: TComponent);
var
  B: TTouchButton;
begin
  inherited Create(AOwner);
  FullSize := True;
  LookDegreesPerPixel := 0.25;
  FMoveFinger := -1;
  FLookFinger := -1;
  for B := Low(TTouchButton) to High(TTouchButton) do
    FButtonFinger[B] := -1;
end;

function TQuakeTouchControls.StickRadius: Single;
begin
  Result := RenderRect.Height * 0.12;
end;

function TQuakeTouchControls.LocalPos(const P: TVector2): TVector2;
begin
  Result := P - RenderRect.LeftBottom;
end;

function TQuakeTouchControls.ButtonCircle(const B: TTouchButton; out Middle: TVector2): Single;
var
  W, H, R: Single;
begin
  { Right thumb cluster (left of the HUD's inventory icons): FIRE big at
    the bottom, JUMP above it, DUCK and USE to its left, WPN above JUMP;
    MENU in the top right corner }
  W := RenderRect.Width;
  H := RenderRect.Height;
  R := H * 0.07;
  case B of
    tbFire: begin Middle := Vector2(W - R * 3.2, R * 2.0); Result := R * 1.3; end;
    tbJump: begin Middle := Vector2(W - R * 3.2, R * 5.0); Result := R; end;
    tbCrouch: begin Middle := Vector2(W - R * 6.2, R * 2.5); Result := R; end;
    tbUse: begin Middle := Vector2(W - R * 6.2, R * 5.0); Result := R; end;
    tbWeapon: begin Middle := Vector2(W - R * 3.2, R * 7.6); Result := R * 0.85; end;
    else begin Middle := Vector2(W - R * 1.2, H - R * 1.2); Result := R * 0.8; end;
  end;
end;

function TQuakeTouchControls.ButtonAt(const P: TVector2; out B: TTouchButton): Boolean;
var
  C: TVector2;
  R: Single;
  K: TTouchButton;
begin
  for K := Low(TTouchButton) to High(TTouchButton) do
  begin
    R := ButtonCircle(K, C);
    if PointsDistance(P, C) <= R * 1.15 then
    begin
      B := K;
      Exit(True);
    end;
  end;
  B := tbFire;
  Result := False;
end;

function TQuakeTouchControls.Press(const Event: TInputPressRelease): Boolean;
var
  P: TVector2;
  B: TTouchButton;
begin
  Result := inherited Press(Event);
  if Result or (Event.EventType <> itMouseButton) then
    Exit;
  P := LocalPos(Event.Position);
  if ButtonAt(P, B) then
  begin
    FButtonFinger[B] := Event.FingerIndex;
    case B of
      tbUse: if Assigned(FOnUse) then FOnUse(Self);
      tbWeapon: if Assigned(FOnNextWeapon) then FOnNextWeapon(Self);
      tbMenu: if Assigned(FOnMenu) then FOnMenu(Self);
      else ;
    end;
    Exit(True);
  end;
  if (P.X < RenderRect.Width * 0.4) and (FMoveFinger < 0) then
  begin
    FMoveFinger := Event.FingerIndex;
    FMoveOrigin := P;
    FMovePos := P;
    Exit(True);
  end;
  if FLookFinger < 0 then
  begin
    FLookFinger := Event.FingerIndex;
    FLookLast := P;
    Exit(True);
  end;
end;

function TQuakeTouchControls.Release(const Event: TInputPressRelease): Boolean;
var
  B: TTouchButton;
begin
  Result := inherited Release(Event);
  if Event.EventType <> itMouseButton then
    Exit;
  if Event.FingerIndex = FMoveFinger then
    FMoveFinger := -1;
  if Event.FingerIndex = FLookFinger then
    FLookFinger := -1;
  for B := Low(TTouchButton) to High(TTouchButton) do
    if FButtonFinger[B] = Event.FingerIndex then
      FButtonFinger[B] := -1;
end;

function TQuakeTouchControls.Motion(const Event: TInputMotion): Boolean;
var
  P: TVector2;
begin
  Result := inherited Motion(Event);
  P := LocalPos(Event.Position);
  if Event.FingerIndex = FMoveFinger then
  begin
    FMovePos := P;
    Result := True;
  end else
  if Event.FingerIndex = FLookFinger then
  begin
    FLookDelta := FLookDelta + (P - FLookLast);
    FLookLast := P;
    Result := True;
  end;
end;

procedure TQuakeTouchControls.ResetTouches;
var
  B: TTouchButton;
begin
  FMoveFinger := -1;
  FLookFinger := -1;
  FLookDelta := TVector2.Zero;
  for B := Low(TTouchButton) to High(TTouchButton) do
    FButtonFinger[B] := -1;
end;

function TQuakeTouchControls.Stick: TVector2;
begin
  if FMoveFinger < 0 then
    Exit(TVector2.Zero);
  Result := TouchStickVector(FMoveOrigin, FMovePos, StickRadius);
end;

function TQuakeTouchControls.TakeLook: TVector2;
begin
  Result := FLookDelta;
  FLookDelta := TVector2.Zero;
end;

function TQuakeTouchControls.Held(const B: TTouchButton): Boolean;
begin
  Result := FButtonFinger[B] >= 0;
end;

procedure TQuakeTouchControls.Render;
var
  B: TTouchButton;
  C, Knob: TVector2;
  R: Single;
  Col: TCastleColor;
begin
  inherited Render;
  { Move stick: base where the thumb went down, knob under it }
  if FMoveFinger >= 0 then
  begin
    C := RenderRect.LeftBottom + FMoveOrigin;
    DrawCircle(C, StickRadius, StickRadius, Vector4(1, 1, 1, 0.15));
    Knob := C + Stick * StickRadius;
    DrawCircle(Knob, StickRadius * 0.4, StickRadius * 0.4, Vector4(1, 0.8, 0.3, 0.45));
  end else
    UIFont.Print(RenderRect.Left + RenderRect.Width * 0.08, RenderRect.Bottom + RenderRect.Height * 0.08,
      Vector4(1, 1, 1, 0.35), 'MOVE');
  for B := Low(TTouchButton) to High(TTouchButton) do
  begin
    R := ButtonCircle(B, C);
    C := RenderRect.LeftBottom + C;
    if Held(B) then
      Col := Vector4(1, 0.7, 0.2, 0.5)
    else
      Col := Vector4(1, 1, 1, 0.18);
    DrawCircle(C, R, R, Col);
    UIFont.Print(C.X - UIFont.TextWidth(TouchButtonLabels[B]) / 2, C.Y - UIFont.Height / 2,
      Vector4(1, 1, 1, 0.8), TouchButtonLabels[B]);
  end;
end;

end.
