{ Quake 2 Main Menu: New Game, Map Select (from the loaded PAKs), Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, CastleSoundEngine, QuakePak, QuakeSound, QuakeSettings, QuakeGamepad;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maToggleCamera, maSettingsChanged, maLevelEditor, maQuit
  );

  TMenuPage = (smMain, smSkill, smMaps, smOptions, smControls, smShowcase);

  { Rows of the Options page }
  TOptionItem = (oiCamera, oiSensitivity, oiInvert, oiViewBob, oiFieldOfView, oiInterfaceSize,
    oiSoundVolume, oiMusicVolume, oiControls, oiBack);

const
  { Map name the menu passes for a new random level }
  RandomGameMap = 'random';
  PageNames: array[TMenuPage] of String = ('Main', 'Skill', 'Maps', 'Options', 'Controls', 'Showcase');

type
  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: TMenuPage;
    { The skill page starts a random level (Random Level) }
    FRandomGame: Boolean;
    FItems: TStringList;
    FOnMenuAction: TOnMenuActionEvent;
    FCameraModeName: String;
    FMaps: TStringList;
    { Controls page: action waiting for a key press, or False }
    FBinding: Boolean;
    FBindingAction: TQuakeAction;
    { Gamepad stick as arrows: direction held and time to the next repeat }
    FStickArrow: TKey;
    FStickRepeat: Single;
    procedure RebuildMenuItems(const KeepSelection: Boolean = False);
    procedure ExecuteSelection;
    procedure ShowPage(const Page: TMenuPage);
    { Change the value of the selected option (-1 / +1); False if it has none }
    function AdjustOption(const Delta: Integer): Boolean;
    procedure SettingsChanged;
    { Index of the item row at a position (container pixels), -1 if none }
    function ItemAt(const P: TVector2): Integer;
    function PageTitle: String;
    { Rows layout shared by Render and ItemAt: baseline of the first shown
      row, row height, first shown item and the number of shown rows }
    procedure RowLayout(out StartY, RowH: Single; out First, Count: Integer);
  public
    { Size of everything: CGE's UIScale times InterfaceScale }
    function MenuScale: Single;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    procedure Render; override;

    property OnMenuAction: TOnMenuActionEvent read FOnMenuAction write FOnMenuAction;
    property CameraModeName: String read FCameraModeName write FCameraModeName;
  end;

{ Map to start a new game with: base1 (Quake 2 unit 1) or the first map found }
function FirstMapName: String;

implementation

uses
  CastleComponentSerialize, CastleLog;

function FirstMapName: String;
var
  Maps: TStringList;
begin
  if Pak.FileExists('maps/base1.bsp') then
    Exit('base1');
  Maps := Pak.FindFiles('maps/', '.bsp');
  try
    Maps.Sort;
    if Maps.Count > 0 then
      Result := ChangeFileExt(ExtractFileName(Maps[0]), '')
    else
      Result := 'base1';
  finally
    Maps.Free;
  end;
end;

constructor TQuakeMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FItems := TStringList.Create;
  FSelectedIdx := 0;
  FSubMenu := smMain;
  FCameraModeName := 'First-Person';
  FMaps := Pak.FindFiles('maps/', '.bsp');
  FMaps.Sort;
  RebuildMenuItems;
end;

destructor TQuakeMenu.Destroy;
begin
  FItems.Free;
  FMaps.Free;
  inherited Destroy;
end;

function OnOff(const Value: Boolean): String;
begin
  if Value then
    Result := 'On'
  else
    Result := 'Off';
end;

procedure TQuakeMenu.RebuildMenuItems(const KeepSelection: Boolean);
var
  A: TQuakeAction;
  I: Integer;
begin
  FItems.Clear;
  case FSubMenu of
    smMain:
      begin
        FItems.Add('Single Player');
        FItems.Add('Map Warp');
        FItems.Add('Options');
        FItems.Add('Random Level');
        FItems.Add('Level Editor');
        FItems.Add('CGE Features Showcase');
        FItems.Add('Quit');
      end;
    smSkill:
      begin
        for I := 0 to High(SkillNames) do
          FItems.Add(SkillNames[I]);
        FItems.Add('Back to Main Menu');
      end;
    smMaps:
      begin
        FItems.AddStrings(FMaps);
        FItems.Add('Back to Main Menu');
      end;
    smOptions:
      begin
        FItems.Add('Camera View: [' + FCameraModeName + ']');
        FItems.Add(Format('Mouse Sensitivity: [%.2f]', [Settings.MouseSensitivity]));
        FItems.Add('Invert Mouse: [' + OnOff(Settings.InvertMouse) + ']');
        FItems.Add('View Bob: [' + OnOff(Settings.ViewBob) + ']');
        FItems.Add(Format('Field of View: [%d]', [Settings.FieldOfView]));
        FItems.Add('Interface Size: [' + InterfaceSizeNames[Settings.InterfaceSize] + ']');
        FItems.Add(Format('Sound Volume: [%d%%]', [Settings.SoundVolume]));
        FItems.Add(Format('Music Volume: [%d%%]', [Settings.MusicVolume]));
        FItems.Add('Controls...');
        FItems.Add('Back to Main Menu');
      end;
    smControls:
      begin
        for A := Low(TQuakeAction) to High(TQuakeAction) do
          FItems.Add(ActionNames[A] + ': [' + KeyToStr(Settings.Keys[A]) + ']');
        FItems.Add('Reset to Defaults');
        FItems.Add('Back to Options');
      end;
    smShowcase:
      begin
        FItems.Add('Back to Main Menu');
      end;
  end;
  if not KeepSelection then
    FSelectedIdx := 0;
  FSelectedIdx := EnsureRange(FSelectedIdx, 0, FItems.Count - 1);
end;

procedure TQuakeMenu.ShowPage(const Page: TMenuPage);
begin
  FSubMenu := Page;
  FBinding := False;
  RebuildMenuItems;
  WritelnLog('Menu', 'Page %s', [PageNames[Page]]);
  { Start on the current skill }
  if FSubMenu = smSkill then
    FSelectedIdx := Settings.Skill;
end;

procedure TQuakeMenu.SettingsChanged;
begin
  Settings.Save;
  RebuildMenuItems(True);
  if Assigned(FOnMenuAction) then
    FOnMenuAction(maSettingsChanged, '');
end;

function TQuakeMenu.AdjustOption(const Delta: Integer): Boolean;
begin
  Result := FSubMenu = smOptions;
  if not Result then
    Exit;
  case TOptionItem(FSelectedIdx) of
    oiSensitivity:
      Settings.MouseSensitivity := EnsureRange(Settings.MouseSensitivity + 0.25 * Delta, 0.25, 3);
    oiInvert:
      Settings.InvertMouse := not Settings.InvertMouse;
    oiViewBob:
      Settings.ViewBob := not Settings.ViewBob;
    oiFieldOfView:
      Settings.FieldOfView := EnsureRange(Settings.FieldOfView + 5 * Delta, 70, 120);
    oiInterfaceSize:
      Settings.InterfaceSize := EnsureRange(Settings.InterfaceSize + Delta, 0, High(InterfaceSizeNames));
    oiSoundVolume:
      Settings.SoundVolume := EnsureRange(Settings.SoundVolume + 10 * Delta, 0, 100);
    oiMusicVolume:
      Settings.MusicVolume := EnsureRange(Settings.MusicVolume + 10 * Delta, 0, 100);
    else
      Exit(False);
  end;
  Sounds.Play('sound/misc/menu2.wav');
  SettingsChanged;
end;

function TQuakeMenu.PageTitle: String;
begin
  case FSubMenu of
    smSkill: Result := 'CHOOSE SKILL';
    smMaps: Result := 'MAP WARP';
    smOptions: Result := 'OPTIONS';
    smControls: Result := 'CONTROLS';
    else Result := '';
  end;
end;

procedure TQuakeMenu.ExecuteSelection;
var
  ItemText: String;
begin
  if (FSelectedIdx < 0) or (FSelectedIdx >= FItems.Count) then
    Exit;

  ItemText := FItems[FSelectedIdx];

  case FSubMenu of
    smMain:
      begin
        Sounds.Play('sound/misc/menu2.wav');
        case FSelectedIdx of
          0:
            begin
              FRandomGame := False;
              ShowPage(smSkill);
            end;
          1: ShowPage(smMaps);
          2: ShowPage(smOptions);
          3:
            begin
              { A random level (QuakeLevelGen) after choosing the skill }
              FRandomGame := True;
              ShowPage(smSkill);
            end;
          4: if Assigned(FOnMenuAction) then FOnMenuAction(maLevelEditor, '');
          5: ShowPage(smShowcase);
          6: if Assigned(FOnMenuAction) then FOnMenuAction(maQuit, '');
        end;
      end;
    smSkill:
      begin
        Sounds.Play('sound/misc/menu2.wav');
        if FSelectedIdx > High(SkillNames) then
          ShowPage(smMain)
        else
        begin
          GameSkill := FSelectedIdx;
          Settings.Skill := FSelectedIdx;
          Settings.Save;
          ShowPage(smMain);
          if Assigned(FOnMenuAction) then
            if FRandomGame then
              FOnMenuAction(maNewGame, RandomGameMap)
            else
              FOnMenuAction(maNewGame, FirstMapName);
        end;
      end;
    smMaps:
      begin
        Sounds.Play('sound/misc/menu2.wav');
        if ItemText = 'Back to Main Menu' then
          ShowPage(smMain)
        else
        if Assigned(FOnMenuAction) then
          FOnMenuAction(maWarpMap, ChangeFileExt(ExtractFileName(ItemText), ''));
      end;
    smOptions:
      case TOptionItem(FSelectedIdx) of
        oiCamera:
          begin
            Sounds.Play('sound/misc/menu2.wav');
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleCamera, '');
            RebuildMenuItems(True);
          end;
        oiControls:
          begin
            Sounds.Play('sound/misc/menu2.wav');
            ShowPage(smControls);
          end;
        oiBack:
          begin
            Sounds.Play('sound/misc/menu2.wav');
            ShowPage(smMain);
          end;
        else
          AdjustOption(1);
      end;
    smControls:
      begin
        Sounds.Play('sound/misc/menu2.wav');
        if FSelectedIdx <= Ord(High(TQuakeAction)) then
        begin
          { Wait for the key to bind }
          FBinding := True;
          FBindingAction := TQuakeAction(FSelectedIdx);
        end else
        if FSelectedIdx = Ord(High(TQuakeAction)) + 1 then
        begin
          Settings.ResetKeys;
          SettingsChanged;
        end else
        begin
          ShowPage(smOptions);
          FSelectedIdx := Ord(oiControls);
        end;
      end;
    smShowcase:
      ShowPage(smMain);
  end;
end;

procedure TQuakeMenu.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Arrow: TKey;
begin
  inherited Update(SecondsPassed, HandleInput);
  { The left stick works like the arrow keys, repeating while held }
  Arrow := ReadGamepads(0, 1, False).MenuArrow;
  if (Arrow = keyNone) or FBinding then
  begin
    FStickArrow := keyNone;
    Exit;
  end;
  if Arrow <> FStickArrow then
  begin
    FStickArrow := Arrow;
    FStickRepeat := 0.4;
    Press(InputKey(TVector2.Zero, Arrow, '', []));
  end else
  begin
    FStickRepeat := FStickRepeat - SecondsPassed;
    if FStickRepeat <= 0 then
    begin
      FStickRepeat := 0.15;
      Press(InputKey(TVector2.Zero, Arrow, '', []));
    end;
  end;
end;

function TQuakeMenu.MenuScale: Single;
begin
  Result := UIScale * InterfaceScale;
end;

procedure TQuakeMenu.RowLayout(out StartY, RowH: Single; out First, Count: Integer);
var
  S: Single;
begin
  S := MenuScale;
  RowH := 36 * S;
  StartY := RenderRect.Height / 2 + 130 * S;
  { As many rows as fit above the hint line (at most 10), around the selection }
  Count := EnsureRange(Floor((StartY - 80 * S) / RowH) + 1, 3, 10);
  First := EnsureRange(FSelectedIdx - Count div 2, 0, Max(0, FItems.Count - Count));
  Count := Min(Count, FItems.Count - First);
end;

function TQuakeMenu.ItemAt(const P: TVector2): Integer;
var
  L: TVector2;
  First, Count, I: Integer;
  StartY, RowH, Baseline: Single;
begin
  Result := -1;
  L := P - RenderRect.LeftBottom;
  RowLayout(StartY, RowH, First, Count);
  for I := First to First + Count - 1 do
  begin
    { The whole row height around the text's baseline }
    Baseline := StartY - (I - First) * RowH;
    if (L.Y >= Baseline - RowH * 0.3) and (L.Y < Baseline + RowH * 0.7) and
       (Abs(L.X - RenderRect.Width / 2) < RenderRect.Width * 0.45) then
      Exit(I);
  end;
end;

function TQuakeMenu.Press(const Event: TInputPressRelease): Boolean;
var
  Tapped: Integer;
begin
  Result := False;

  { Mouse / touch: a tap selects a row, a tap on the selected row activates
    it (or changes its value: right half up, left half down) }
  if (Event.EventType = itMouseButton) and not FBinding then
  begin
    if FSubMenu = smShowcase then
    begin
      ExecuteSelection;
      Exit(True);
    end;
    Tapped := ItemAt(Event.Position);
    if Tapped < 0 then
      Exit(True);
    if Tapped <> FSelectedIdx then
    begin
      FSelectedIdx := Tapped;
      Sounds.Play('sound/misc/menu1.wav');
    end else
    if not AdjustOption(IfThen(Event.Position.X - RenderRect.Left < RenderRect.Width / 2, -1, 1)) then
      ExecuteSelection;
    Exit(True);
  end;

  if FBinding then
  begin
    if Event.EventType <> itKey then
      Exit;
    FBinding := False;
    { Escape cancels; the console and menu keys can't be bound }
    if (Event.Key <> keyNone) and not (Event.Key in [keyEscape, keyBackQuote]) then
    begin
      Settings.BindKey(FBindingAction, Event.Key);
      Sounds.Play('sound/misc/menu2.wav');
      SettingsChanged;
    end else
      Sounds.Play('sound/misc/menu3.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowUp) then
  begin
    FSelectedIdx := (FSelectedIdx - 1 + FItems.Count) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowDown) then
  begin
    FSelectedIdx := (FSelectedIdx + 1) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowLeft) then
    Exit(AdjustOption(-1));
  if Event.IsKey(keyArrowRight) then
    Exit(AdjustOption(1));

  if Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    ExecuteSelection;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    if FSubMenu = smControls then
    begin
      ShowPage(smOptions);
      FSelectedIdx := Ord(oiControls);
      Sounds.Play('sound/misc/menu3.wav');
      Exit(True);
    end;
    if FSubMenu <> smMain then
    begin
      ShowPage(smMain);
      Sounds.Play('sound/misc/menu3.wav');
      Exit(True);
    end;
  end;
end;

procedure TQuakeMenu.Render;
const
  ShowcaseLines: array[0..10] of String = (
    '- Full 3D X3D Scene Graphs (TIndexedTriangleSetNode, TShapeNode)',
    '- Baked RGB Lightmaps via MultiTexture (2x overbright) + LightPoint Model Shading',
    '- Skybox from env/*.pcx|tga via TCastleBackground',
    '- Quake 2 MD2 Model Loading with Interpolated Frame Animation',
    '- Positional 3D Spatial Audio via OpenAL (TCastleSoundSource)',
    '- Custom URL Protocols ("quakepak:", "quaketex:") with Streaming Cache',
    '- First/Third Person & Free-Fly Navigation (TCastleWalkNavigation)',
    '- Brush Movers (doors, rotating doors, plats, buttons, trains) via TCastleTransform',
    '- Billboard Particles (rail trails, blaster sparks, explosions, BFG)',
    '- Quake 2 Box Traces Against BSP Brushes for Movement, Shots and Sight',
    '- Touch Controls, Gamepads and UI Scaling for Phones');
var
  CX, CY, S, StartY, RowH, BlockLeft, MaxW, BaseSize: Single;
  I, First, Count: Integer;
  Col: TVector4;
  Hint: String;

  procedure Centered(const Y: Single; const Color: TVector4; const Text: String);
  begin
    UIFont.Print(CX - UIFont.TextWidth(Text) / 2, Y, Color, Text);
  end;

begin
  inherited Render;

  S := MenuScale;
  CX := RenderRect.Width / 2;
  CY := RenderRect.Height / 2;

  { Dark vignette backdrop }
  DrawRectangle(RenderRect, Vector4(0.04, 0.04, 0.05, 0.88));

  UIFont.PushProperties;
  try
    BaseSize := UIFont.EffectiveSize * S;
    UIFont.Size := BaseSize;

    { Quake Title }
    Centered(CY + 220 * S, Vector4(1.0, 0.45, 0.1, 1.0), 'CASTLE QUAKE II');
    Centered(CY + 195 * S, Vector4(0.8, 0.8, 0.8, 0.8), 'Castle Game Engine Quake 2 Showcase');

    if FSubMenu = smShowcase then
    begin
      Centered(CY + 150 * S, Vector4(1.0, 0.8, 0.2, 1.0), 'Engine Features Used:');
      { One left-aligned block, centered, shrunk to fit narrow screens }
      MaxW := 0;
      for I := 0 to High(ShowcaseLines) do
        MaxW := Max(MaxW, UIFont.TextWidth(ShowcaseLines[I]));
      if MaxW > RenderRect.Width * 0.94 then
      begin
        UIFont.Size := UIFont.Size * RenderRect.Width * 0.94 / MaxW;
        MaxW := RenderRect.Width * 0.94;
      end;
      BlockLeft := CX - MaxW / 2;
      for I := 0 to High(ShowcaseLines) do
        UIFont.Print(BlockLeft, CY + (115 - I * 25) * S, Vector4(0.9, 0.9, 0.9, 1.0), ShowcaseLines[I]);
      UIFont.Size := BaseSize;
      if TouchInterface then
        Centered(CY - 175 * S, Vector4(1.0, 0.5, 0.1, 1.0), '[ Tap to Return ]')
      else
        Centered(CY - 175 * S, Vector4(1.0, 0.5, 0.1, 1.0), '[ Press Enter / Esc to Return ]');
      Exit;
    end;

    if PageTitle <> '' then
      Centered(CY + 165 * S, Vector4(1.0, 0.65, 0.2, 1.0), PageTitle);

    RowLayout(StartY, RowH, First, Count);
    for I := First to First + Count - 1 do
      if I = FSelectedIdx then
      begin
        Col := Vector4(1.0, 0.85, 0.15, 1.0);
        { Cursor indicator }
        Centered(StartY - (I - First) * RowH, Col, '> ' + FItems[I] + ' <');
      end else
      begin
        Col := Vector4(0.75, 0.75, 0.75, 0.9);
        Centered(StartY - (I - First) * RowH, Col, FItems[I]);
      end;
    { More rows above / below }
    if First > 0 then
      Centered(StartY + RowH * 0.75, Vector4(0.6, 0.6, 0.6, 0.7), '...');
    if First + Count < FItems.Count then
      Centered(StartY - Count * RowH + RowH * 0.3, Vector4(0.6, 0.6, 0.6, 0.7), '...');

    { Bottom help hint }
    Col := Vector4(0.6, 0.6, 0.6, 0.7);
    if FBinding then
    begin
      Col := Vector4(1.0, 0.85, 0.15, 1.0);
      Hint := 'Press a key for ' + ActionNames[FBindingAction] + ' (Esc cancels)';
    end else
    if TouchInterface and (FSubMenu = smOptions) then
      Hint := 'Tap: Select, Tap Again: Change (Left / Right Half: Down / Up)'
    else
    if TouchInterface then
      Hint := 'Tap: Select, Tap Again: Enter, Back Button: Back'
    else
    if FSubMenu = smOptions then
      Hint := 'Arrows: Navigate, Left / Right: Change, Enter: Select, Esc: Back'
    else
      Hint := 'Use Arrow Keys to Navigate, Enter to Select, Esc to Back';
    if UIFont.TextWidth(Hint) > RenderRect.Width * 0.94 then
      UIFont.Size := UIFont.Size * RenderRect.Width * 0.94 / UIFont.TextWidth(Hint);
    Centered(40 * S, Col, Hint);
  finally
    UIFont.PopProperties;
  end;
end;

initialization
  RegisterSerializableComponent(TQuakeMenu, 'Quake 2 Menu');
end.
