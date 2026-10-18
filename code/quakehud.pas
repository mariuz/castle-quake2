{ Quake 2 Heads-Up Display: status bar drawn with the original pics/*.pcx
  numbers and icons, crosshair, pickup notifications, damage flash. }
unit QuakeHud;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  CastleVectors, CastleControls, CastleUIControls, CastleColors,
  CastleRectangles, CastleGLUtils, CastleGLImages, CastleImages,
  QuakePalette;

type
  TAmmoType = (atNone, atShells, atBullets, atGrenades, atRockets, atCells, atSlugs);

  { Player statistics needed for HUD rendering and gameplay }
  TQuakePlayerStats = record
    Health, MaxHealth: Integer;
    Armor: Integer;
    ArmorType: Integer; { 0 = none, 1 = jacket, 2 = combat, 3 = body }
    Ammo: array[TAmmoType] of Integer;
    MaxAmmo: array[TAmmoType] of Integer;
    WeaponMask: Cardinal;   { bit N = weapon slot N (1..11) }
    CurrentWeapon: Integer; { 1 blaster .. 10 BFG10K, 11 hand grenades }
    Keys: Cardinal;         { bitmask of TQuakeKey }
    Kills, TotalKills: Integer;
    Secrets, TotalSecrets: Integer;
    Goals, TotalGoals: Integer;
    LevelTime: Single;
    QuadTime, InvulnTime: Single;
    GodMode: Boolean;
  end;

  { Quake 2 Heads-Up Display container }
  TQuakeHud = class(TCastleUserInterface)
  private
    FStats: TQuakePlayerStats;
    FMessageLabel: TCastleLabel;
    FStatsLabel: TCastleLabel;
    FMessageTimer: Single;
    FCrosshairVisible: Boolean;
    FPics: specialize TObjectDictionary<String, TDrawableImage>;
    FPickupIcon: String;
    FPickupText: String;
    FPickupTimer: Single;
    FDamageFlash: Single;
    FPickupFlash: Single;
    FWeaponIcon, FAmmoIcon: String;
    FKeyIcons: TStringList;
    FHelpVisible: Boolean;
    FUnderwaterType: Integer;
    FIntermission: Boolean;
    FLevelName, FHelpPrimary, FHelpSecondary: String;
    procedure RenderHelpComputer;
    procedure RenderHelpComputerScaled;
    function Pic(const AName: String): TDrawableImage;
    function DrawNumber(const X, Y: Single; const Value, Digits: Integer;
      const Alt: Boolean; const Scale: Single): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Update HUD with latest player state }
    procedure Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats;
      const WeaponIcon, AmmoIcon: String; const KeyIcons: TStrings); reintroduce;

    { Display a centered notification message }
    procedure ShowMessage(const S: String; const Duration: Single = 3.0);

    { Pickup notification at the bottom right, like Quake 2 }
    procedure ShowPickup(const Icon, Text: String);

    { Flash the screen red (damage) }
    procedure FlashDamage(const Amount: Integer);

    procedure Render; override;

    property CrosshairVisible: Boolean read FCrosshairVisible write FCrosshairVisible;
    { Quake 2 help computer (F1): objectives and level statistics }
    property HelpVisible: Boolean read FHelpVisible write FHelpVisible;
    { Contents bits of the liquid the eye is in (screen tint), 0 = none }
    property UnderwaterType: Integer read FUnderwaterType write FUnderwaterType;
    { End of level: the help computer layout as a mission summary, no status bar }
    property Intermission: Boolean read FIntermission write FIntermission;
    property LevelName: String read FLevelName write FLevelName;
    property HelpPrimary: String read FHelpPrimary write FHelpPrimary;
    property HelpSecondary: String read FHelpSecondary write FHelpSecondary;
  end;

implementation

uses
  CastleComponentSerialize, QuakeSettings;

const
  { Quake 2 pics were drawn for 320x240; scale them up on the 1600x900 UI }
  PicScale = 3.0;

constructor TQuakeHud.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FPics := specialize TObjectDictionary<String, TDrawableImage>.Create([doOwnsValues]);
  FKeyIcons := TStringList.Create;

  FillChar(FStats, SizeOf(FStats), 0);
  FStats.Health := 100;

  { Children created in code are transient: not saved into designs }
  FMessageLabel := TCastleLabel.Create(Self);
  FMessageLabel.SetTransient;
  FMessageLabel.Color := Vector4(0.3, 1.0, 0.3, 1.0);
  FMessageLabel.FontSize := 28;
  FMessageLabel.Alignment := hpMiddle;
  FMessageLabel.Anchor(hpMiddle);
  FMessageLabel.Anchor(vpTop, -120);
  InsertFront(FMessageLabel);

  FStatsLabel := TCastleLabel.Create(Self);
  FStatsLabel.SetTransient;
  FStatsLabel.Color := Vector4(0.8, 0.8, 0.8, 0.85);
  FStatsLabel.Anchor(hpLeft, 16);
  FStatsLabel.Anchor(vpTop, -16);
  InsertFront(FStatsLabel);

  FCrosshairVisible := True;
end;

destructor TQuakeHud.Destroy;
begin
  FPics.Free;
  FKeyIcons.Free;
  inherited Destroy;
end;

function TQuakeHud.Pic(const AName: String): TDrawableImage;
var
  Path: String;
  Img: TCastleImage;
begin
  if AName = '' then
    Exit(nil);
  if FPics.TryGetValue(AName, Result) then
    Exit;
  Result := nil;
  Path := 'pics/' + AName + '.pcx';
  if Palette.LoadPcx(Path, True) then
  begin
    Img := Palette.GetCachedImage(Path);
    if Img <> nil then
    begin
      Result := TDrawableImage.Create(Img.MakeCopy, False, True);
    end;
  end;
  FPics.Add(AName, Result);
end;

function TQuakeHud.DrawNumber(const X, Y: Single; const Value, Digits: Integer;
  const Alt: Boolean; const Scale: Single): Boolean;
var
  S, Prefix, PicName: String;
  I: Integer;
  Img: TDrawableImage;
  CX: Single;
begin
  Result := False;
  if Alt then
    Prefix := 'anum_'
  else
    Prefix := 'num_';
  if Pic(Prefix + '0') = nil then
    Exit;
  S := IntToStr(Value);
  if Length(S) > Digits then
    S := Copy(S, Length(S) - Digits + 1, Digits);
  { Right-aligned in a Digits-wide field, 16 px per digit in 320x240 }
  CX := X + (Digits - Length(S)) * 16 * Scale;
  for I := 1 to Length(S) do
  begin
    if S[I] = '-' then
      PicName := Prefix + 'minus'
    else
      PicName := Prefix + S[I];
    Img := Pic(PicName);
    if Img <> nil then
      Img.Draw(FloatRectangle(CX, Y, Img.Width * Scale, Img.Height * Scale));
    CX := CX + 16 * Scale;
  end;
  Result := True;
end;

procedure TQuakeHud.ShowMessage(const S: String; const Duration: Single);
begin
  { Quake 2 map messages use "\n" for line breaks }
  FMessageLabel.Caption := StringReplace(S, '\n', LineEnding, [rfReplaceAll]);
  FMessageTimer := Duration;
end;

procedure TQuakeHud.ShowPickup(const Icon, Text: String);
begin
  FPickupIcon := Icon;
  FPickupText := Text;
  FPickupTimer := 3.0;
  FPickupFlash := 0.25;
end;

procedure TQuakeHud.FlashDamage(const Amount: Integer);
begin
  FDamageFlash := Min(0.6, FDamageFlash + 0.1 + Amount / 60);
end;

procedure TQuakeHud.Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats;
  const WeaponIcon, AmmoIcon: String; const KeyIcons: TStrings);
var
  Mins, Secs: Integer;
  S: String;
begin
  FStats := Stats;
  FWeaponIcon := WeaponIcon;
  FAmmoIcon := AmmoIcon;
  FKeyIcons.Assign(KeyIcons);

  if FMessageTimer > 0 then
  begin
    FMessageTimer := FMessageTimer - SecondsPassed;
    if FMessageTimer <= 0 then
      FMessageLabel.Caption := '';
  end;
  FPickupTimer := Max(0, FPickupTimer - SecondsPassed);
  FDamageFlash := Max(0, FDamageFlash - SecondsPassed * 1.5);
  FPickupFlash := Max(0, FPickupFlash - SecondsPassed);

  Mins := Trunc(Stats.LevelTime) div 60;
  Secs := Trunc(Stats.LevelTime) mod 60;
  S := Format('KILLS %d/%d   SECRETS %d/%d', [Stats.Kills, Stats.TotalKills,
    Stats.Secrets, Stats.TotalSecrets]);
  if Stats.TotalGoals > 0 then
    S := S + Format('   GOALS %d/%d', [Stats.Goals, Stats.TotalGoals]);
  S := S + Format('   TIME %.2d:%.2d', [Mins, Secs]);
  if Stats.GodMode then
    S := S + '   [GOD]';
  if Stats.QuadTime > 0 then
    S := S + Format('   QUAD %d', [Ceil(Stats.QuadTime)]);
  if Stats.InvulnTime > 0 then
    S := S + Format('   INVULNERABLE %d', [Ceil(Stats.InvulnTime)]);
  FStatsLabel.Caption := S;
  { Larger text on phones (Options -> Interface Size); labels add UIScale }
  if FMessageLabel.FontSize <> 28 * InterfaceScale then
  begin
    FMessageLabel.FontSize := 28 * InterfaceScale;
    FMessageLabel.Anchor(vpTop, -120 * InterfaceScale);
    FStatsLabel.FontSize := 20 * InterfaceScale;
  end;
end;

procedure TQuakeHud.RenderHelpComputer;
begin
  { Text grows with the picture on large screens }
  UIFont.PushProperties;
  try
    UIFont.Size := UIFont.EffectiveSize * UIScale;
    RenderHelpComputerScaled;
  finally
    UIFont.PopProperties;
  end;
end;

procedure TQuakeHud.RenderHelpComputerScaled;
const
  Green: TVector4 = (X: 0.35; Y: 1.0; Z: 0.35; W: 1.0);
var
  Sc, PanelLeft, PanelTop, CX: Single;
  Img: TDrawableImage;

  { Quake 2 layout coordinates are in a 320x240 screen; y grows downwards }
  function PY(const Y: Single): Single;
  begin
    Result := PanelTop - Y * Sc;
  end;

  procedure CenterText(const Y: Single; const S: String);
  var
    Lines: TStringList;
    I: Integer;
  begin
    Lines := TStringList.Create;
    try
      Lines.Text := StringReplace(S, '\n', LineEnding, [rfReplaceAll]);
      for I := 0 to Lines.Count - 1 do
        UIFont.Print(CX - UIFont.TextWidth(Lines[I]) / 2,
          PY(Y + I * 9) - UIFont.Height, Green, Lines[I]);
    finally
      Lines.Free;
    end;
  end;

  procedure BoxText(const X, Y: Single; const S: String);
  begin
    UIFont.Print(PanelLeft + X * Sc - UIFont.TextWidth(S) / 2, PY(Y) - UIFont.Height / 2, Green, S);
  end;

begin
  Sc := PicScale * UIScale * 0.8;
  CX := RenderRect.Width / 2;
  PanelLeft := CX - 160 * Sc;
  PanelTop := RenderRect.Height / 2 + 120 * Sc;
  Img := Pic('help');
  if Img <> nil then
    Img.Draw(FloatRectangle(PanelLeft + 32 * Sc, PY(8 + 192), 256 * Sc, 192 * Sc))
  else
    DrawRectangle(FloatRectangle(PanelLeft + 32 * Sc, PY(8 + 192), 256 * Sc, 192 * Sc),
      Vector4(0.05, 0.12, 0.05, 0.9));
  if FIntermission then
    UIFont.Print(PanelLeft + 202 * Sc - UIFont.TextWidth('complete'), PY(12) - UIFont.Height, Green, 'complete')
  else
    UIFont.Print(PanelLeft + 202 * Sc - UIFont.TextWidth('medium'), PY(12) - UIFont.Height, Green, 'medium');
  CenterText(26, FLevelName);
  CenterText(56, FHelpPrimary);
  CenterText(112, FHelpSecondary);
  { help.pcx has KILLS / GOALS / SECRETS boxes; centre the numbers in them }
  BoxText(32 + 48, 172, Format('%d/%d', [FStats.Kills, FStats.TotalKills]));
  BoxText(32 + 128, 172, Format('%d/%d', [FStats.Goals, FStats.TotalGoals]));
  BoxText(32 + 208, 172, Format('%d/%d', [FStats.Secrets, FStats.TotalSecrets]));
  if FIntermission then
    CenterText(186, Format('time %.2d:%.2d - press a key to continue',
      [Trunc(FStats.LevelTime) div 60, Trunc(FStats.LevelTime) mod 60]));
end;

procedure TQuakeHud.Render;
var
  R: TFloatRectangle;
  W, H, X, Y, CX, CY, Sc: Single;
  Img: TDrawableImage;
  HasPics: Boolean;
  AmmoValue, I: Integer;
  ArmorIcon: String;
  AmmoT: TAmmoType;
begin
  inherited Render;
  R := RenderRect;
  W := R.Width;
  H := R.Height;
  Sc := PicScale * UIScale;

  if FIntermission then
  begin
    RenderHelpComputer;
    Exit;
  end;

  { Quake 2 V_CalcBlend liquid tints: lava, slime, water }
  if (FUnderwaterType and 8) <> 0 then
    DrawRectangle(R, Vector4(1.0, 0.3, 0.0, 0.6))
  else
  if (FUnderwaterType and 16) <> 0 then
    DrawRectangle(R, Vector4(0.0, 0.1, 0.05, 0.6))
  else
  if (FUnderwaterType and 32) <> 0 then
    DrawRectangle(R, Vector4(0.5, 0.3, 0.2, 0.4));

  { Screen blends: damage (red), quad (blue), pickup (yellow) }
  if FDamageFlash > 0 then
    DrawRectangle(R, Vector4(0.8, 0.0, 0.0, FDamageFlash));
  if FStats.QuadTime > 0 then
    DrawRectangle(R, Vector4(0.0, 0.0, 1.0, 0.08));
  if FStats.InvulnTime > 0 then
    DrawRectangle(R, Vector4(1.0, 1.0, 0.0, 0.08));
  if FPickupFlash > 0 then
    DrawRectangle(R, Vector4(1.0, 1.0, 0.3, FPickupFlash * 0.4));

  { Current ammo of the selected weapon }
  AmmoValue := -1;
  case FStats.CurrentWeapon of
    2, 3: AmmoT := atShells;
    4, 5: AmmoT := atBullets;
    6, 11: AmmoT := atGrenades;
    7: AmmoT := atRockets;
    8, 10: AmmoT := atCells;
    9: AmmoT := atSlugs;
    else AmmoT := atNone;
  end;
  if AmmoT <> atNone then
    AmmoValue := FStats.Ammo[AmmoT];

  case FStats.ArmorType of
    1: ArmorIcon := 'i_jacketarmor';
    2: ArmorIcon := 'i_combatarmor';
    3: ArmorIcon := 'i_bodyarmor';
    else ArmorIcon := '';
  end;

  { Quake 2 layout: ammo | health | armor along the bottom }
  Y := 8 * UIScale;
  HasPics := Pic('num_0') <> nil;
  if HasPics then
  begin
    X := W / 2 - 160 * Sc;
    if AmmoValue >= 0 then
    begin
      DrawNumber(X, Y, AmmoValue, 3, AmmoValue <= 5, Sc);
      Img := Pic(FAmmoIcon);
      if Img <> nil then
        Img.Draw(FloatRectangle(X + 50 * Sc, Y, 24 * Sc, 24 * Sc));
    end;

    X := W / 2 - 54 * Sc;
    DrawNumber(X, Y, Max(0, FStats.Health), 3, FStats.Health <= 25, Sc);
    Img := Pic('i_health');
    if Img <> nil then
      Img.Draw(FloatRectangle(X + 50 * Sc, Y, 24 * Sc, 24 * Sc));

    X := W / 2 + 54 * Sc;
    if FStats.Armor > 0 then
    begin
      DrawNumber(X, Y, FStats.Armor, 3, False, Sc);
      Img := Pic(ArmorIcon);
      if Img <> nil then
        Img.Draw(FloatRectangle(X + 50 * Sc, Y, 24 * Sc, 24 * Sc));
    end;
  end else
  begin
    UIFont.Print(W / 2 - 300, Y + 10, Vector4(1, 0.75, 0.2, 1), Format('AMMO %d', [Max(0, AmmoValue)]));
    UIFont.Print(W / 2 - 60, Y + 10, Vector4(1, 1, 1, 1), Format('HEALTH %d', [FStats.Health]));
    UIFont.Print(W / 2 + 160, Y + 10, Vector4(0.4, 1, 0.4, 1), Format('ARMOR %d', [FStats.Armor]));
  end;

  { Selected weapon icon (bottom left) }
  Img := Pic(FWeaponIcon);
  if Img <> nil then
    Img.Draw(FloatRectangle(16 * UIScale, Y, 24 * Sc, 24 * Sc));

  { Keys stack at the right edge }
  for I := 0 to FKeyIcons.Count - 1 do
  begin
    Img := Pic(FKeyIcons[I]);
    if Img <> nil then
      Img.Draw(FloatRectangle(W - 30 * Sc, H / 2 - I * 26 * Sc, 24 * Sc, 24 * Sc));
  end;

  { Pickup notification }
  if FPickupTimer > 0 then
  begin
    UIFont.PushProperties;
    try
      UIFont.Size := UIFont.EffectiveSize * UIScale * InterfaceScale;
      { Bottom right, or centered on touch screens (the buttons are there) }
      if TouchInterface then
        X := W / 2 - UIFont.TextWidth(FPickupText) / 2 + 12 * Sc
      else
        X := W - 260 * UIScale;
      Img := Pic(FPickupIcon);
      if Img <> nil then
        Img.Draw(FloatRectangle(X - 24 * Sc - 8, Y + 34 * Sc, 24 * Sc, 24 * Sc));
      UIFont.Print(X, Y + 34 * Sc + 20 * UIScale, Vector4(1, 1, 1, 1), FPickupText);
    finally
      UIFont.PopProperties;
    end;
  end;

  { Crosshair }
  if FCrosshairVisible then
  begin
    CX := W / 2;
    CY := H / 2;
    Img := Pic('ch1');
    if Img <> nil then
      Img.Draw(FloatRectangle(CX - Img.Width * UIScale, CY - Img.Height * UIScale,
        Img.Width * 2 * UIScale, Img.Height * 2 * UIScale))
    else
    begin
      DrawRectangle(FloatRectangle(CX - 8, CY - 1, 5, 2), Vector4(1, 1, 1, 0.75));
      DrawRectangle(FloatRectangle(CX + 3, CY - 1, 5, 2), Vector4(1, 1, 1, 0.75));
      DrawRectangle(FloatRectangle(CX - 1, CY - 8, 2, 5), Vector4(1, 1, 1, 0.75));
      DrawRectangle(FloatRectangle(CX - 1, CY + 3, 2, 5), Vector4(1, 1, 1, 0.75));
    end;
  end;

  if FHelpVisible then
    RenderHelpComputer;
end;

initialization
  RegisterSerializableComponent(TQuakeHud, 'Quake 2 HUD');
end.
