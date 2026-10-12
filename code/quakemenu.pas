{ Quake 2 Main Menu: New Game, Map Select (from the loaded PAKs), Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, CastleSoundEngine, QuakePak, QuakeSound, QuakeSettings;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maToggleCamera, maSettingsChanged, maQuit
  );

  TMenuPage = (smMain, smSkill, smMaps, smOptions, smControls, smShowcase);

  { Rows of the Options page }
  TOptionItem = (oiCamera, oiSensitivity, oiInvert, oiFieldOfView, oiSoundVolume,
    oiMusicVolume, oiControls, oiBack);

  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: TMenuPage;
    FItems: TStringList;
    FOnMenuAction: TOnMenuActionEvent;
    FCameraModeName: String;
    FMaps: TStringList;
    { Controls page: action waiting for a key press, or False }
    FBinding: Boolean;
    FBindingAction: TQuakeAction;
    procedure RebuildMenuItems(const KeepSelection: Boolean = False);
    procedure ExecuteSelection;
    procedure ShowPage(const Page: TMenuPage);
    { Change the value of the selected option (-1 / +1); False if it has none }
    function AdjustOption(const Delta: Integer): Boolean;
    procedure SettingsChanged;
    function PageTitle: String;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Render; override;

    property OnMenuAction: TOnMenuActionEvent read FOnMenuAction write FOnMenuAction;
    property CameraModeName: String read FCameraModeName write FCameraModeName;
  end;

{ Map to start a new game with: base1 (Quake 2 unit 1) or the first map found }
function FirstMapName: String;

implementation

uses
  CastleComponentSerialize;

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
        FItems.Add(Format('Field of View: [%d]', [Settings.FieldOfView]));
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
    oiFieldOfView:
      Settings.FieldOfView := EnsureRange(Settings.FieldOfView + 5 * Delta, 70, 120);
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
          0: ShowPage(smSkill);
          1: ShowPage(smMaps);
          2: ShowPage(smOptions);
          3: ShowPage(smShowcase);
          4: if Assigned(FOnMenuAction) then FOnMenuAction(maQuit, '');
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

function TQuakeMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := False;

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
var
  CX, CY, StartY: Single;
  I, First: Integer;
  Col: TVector4;
begin
  inherited Render;

  CX := RenderRect.Width / 2;
  CY := RenderRect.Height / 2;

  { Dark vignette backdrop }
  DrawRectangle(RenderRect, Vector4(0.04, 0.04, 0.05, 0.88));

  { Quake Title }
  UIFont.Print(CX - 130, CY + 220, Vector4(1.0, 0.45, 0.1, 1.0), 'CASTLE QUAKE II');
  UIFont.Print(CX - 165, CY + 195, Vector4(0.8, 0.8, 0.8, 0.8), 'Castle Game Engine Quake 2 Showcase');

  if FSubMenu = smShowcase then
  begin
    UIFont.Print(CX - 280, CY + 140, Vector4(1.0, 0.8, 0.2, 1.0), 'Engine Features Used:');
    UIFont.Print(CX - 280, CY + 110, Vector4(0.9, 0.9, 0.9, 1.0), '- Full 3D X3D Scene Graphs (TIndexedTriangleSetNode, TShapeNode)');
    UIFont.Print(CX - 280, CY + 85,  Vector4(0.9, 0.9, 0.9, 1.0), '- Baked RGB Lightmaps via MultiTexture (2x overbright) + LightPoint Model Shading');
    UIFont.Print(CX - 280, CY + 60,  Vector4(0.9, 0.9, 0.9, 1.0), '- Skybox from env/*.pcx|tga via TCastleBackground');
    UIFont.Print(CX - 280, CY + 35,  Vector4(0.9, 0.9, 0.9, 1.0), '- Quake 2 MD2 Model Loading with Interpolated Frame Animation');
    UIFont.Print(CX - 280, CY + 10,  Vector4(0.9, 0.9, 0.9, 1.0), '- Positional 3D Spatial Audio via OpenAL (TCastleSoundSource)');
    UIFont.Print(CX - 280, CY - 15,  Vector4(0.9, 0.9, 0.9, 1.0), '- Custom URL Protocols ("quakepak:", "quaketex:") with Streaming Cache');
    UIFont.Print(CX - 280, CY - 40,  Vector4(0.9, 0.9, 0.9, 1.0), '- First/Third Person & Free-Fly Navigation (TCastleWalkNavigation)');
    UIFont.Print(CX - 280, CY - 65,  Vector4(0.9, 0.9, 0.9, 1.0), '- Brush Movers (doors, rotating doors, plats, buttons, trains) via TCastleTransform');
    UIFont.Print(CX - 280, CY - 90,  Vector4(0.9, 0.9, 0.9, 1.0), '- Billboard Particles (rail trails, blaster sparks, explosions, BFG)');
    UIFont.Print(CX - 280, CY - 115, Vector4(0.9, 0.9, 0.9, 1.0), '- Ray Casts (WorldRayCast) for Hitscan Weapons and Projectiles');

    UIFont.Print(CX - 80, CY - 160, Vector4(1.0, 0.5, 0.1, 1.0), '[ Press Enter / Esc to Return ]');
    Exit;
  end;

  if PageTitle <> '' then
    UIFont.Print(CX - UIFont.TextWidth(PageTitle) / 2, CY + 165, Vector4(1.0, 0.65, 0.2, 1.0), PageTitle);

  StartY := CY + 130;
  { Show a window of at most 10 items around the selection }
  First := EnsureRange(FSelectedIdx - 5, 0, Max(0, FItems.Count - 10));
  for I := First to Min(FItems.Count - 1, First + 9) do
  begin
    if I = FSelectedIdx then
    begin
      Col := Vector4(1.0, 0.85, 0.15, 1.0);
      { Cursor indicator }
      UIFont.Print(CX - 150, StartY - (I - First) * 36, Col, '> ' + FItems[I] + ' <');
    end else
    begin
      Col := Vector4(0.75, 0.75, 0.75, 0.9);
      UIFont.Print(CX - 130, StartY - (I - First) * 36, Col, FItems[I]);
    end;
  end;

  { Bottom help hint }
  if FBinding then
    UIFont.Print(CX - 200, 40, Vector4(1.0, 0.85, 0.15, 1.0),
      'Press a key for ' + ActionNames[FBindingAction] + ' (Esc cancels)')
  else
  if FSubMenu = smOptions then
    UIFont.Print(CX - 200, 40, Vector4(0.6, 0.6, 0.6, 0.7),
      'Arrows: Navigate, Left / Right: Change, Enter: Select, Esc: Back')
  else
    UIFont.Print(CX - 160, 40, Vector4(0.6, 0.6, 0.6, 0.7),
      'Use Arrow Keys to Navigate, Enter to Select, Esc to Back');
end;

initialization
  RegisterSerializableComponent(TQuakeMenu, 'Quake 2 Menu');
end.
