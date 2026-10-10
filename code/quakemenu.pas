{ Quake 2 Main Menu: New Game, Map Select (from the loaded PAKs), Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, CastleSoundEngine, QuakePak, QuakeSound;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maToggleCamera, maQuit
  );

  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: (smMain, smEpisodes, smMaps, smOptions, smShowcase);
    FItems: TStringList;
    FOnMenuAction: TOnMenuActionEvent;
    FCameraModeName: String;
    FVolume: Integer;
    FMaps: TStringList;
    procedure RebuildMenuItems;
    procedure ExecuteSelection;
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
  FVolume := 100;
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

procedure TQuakeMenu.RebuildMenuItems;
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
    smMaps:
      begin
        FItems.AddStrings(FMaps);
        FItems.Add('Back to Main Menu');
      end;
    smOptions:
      begin
        FItems.Add('Camera View: [' + FCameraModeName + ']');
        FItems.Add('Sound Effects: [' + IntToStr(FVolume) + '%]');
        FItems.Add('Back to Main Menu');
      end;
    smShowcase:
      begin
        FItems.Add('Back to Main Menu');
      end;
  end;
  FSelectedIdx := 0;
end;

procedure TQuakeMenu.ExecuteSelection;
var
  ItemText: String;
begin
  if (FSelectedIdx < 0) or (FSelectedIdx >= FItems.Count) then
    Exit;

  ItemText := FItems[FSelectedIdx];
  Sounds.Play('sound/misc/menu2.wav');

  case FSubMenu of
    smMain:
      case FSelectedIdx of
        0: if Assigned(FOnMenuAction) then FOnMenuAction(maNewGame, FirstMapName);
        1: begin FSubMenu := smMaps; RebuildMenuItems; end;
        2: begin FSubMenu := smOptions; RebuildMenuItems; end;
        3: begin FSubMenu := smShowcase; RebuildMenuItems; end;
        4: if Assigned(FOnMenuAction) then FOnMenuAction(maQuit, '');
      end;
    smMaps:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) then
          FOnMenuAction(maWarpMap, ChangeFileExt(ExtractFileName(ItemText), ''));
      end;
    smOptions:
      case FSelectedIdx of
        0:
          begin
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleCamera, '');
            RebuildMenuItems;
          end;
        1:
          begin
            FVolume := (FVolume + 25) mod 125;
            SoundEngine.Volume := FVolume / 100;
            RebuildMenuItems;
            FSelectedIdx := 1;
          end;
        2:
          begin
            FSubMenu := smMain;
            RebuildMenuItems;
          end;
      end;
    smShowcase:
      begin
        FSubMenu := smMain;
        RebuildMenuItems;
      end;
  end;
end;

function TQuakeMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := False;

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

  if Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    ExecuteSelection;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    if FSubMenu <> smMain then
    begin
      FSubMenu := smMain;
      RebuildMenuItems;
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
    UIFont.Print(CX - 280, CY + 85,  Vector4(0.9, 0.9, 0.9, 1.0), '- Baked RGB Lightmaps via MultiTexture (MODULATE2X) + LightPoint Model Shading');
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

  StartY := CY + 140;
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
  UIFont.Print(CX - 160, 40, Vector4(0.6, 0.6, 0.6, 0.7),
    'Use Arrow Keys to Navigate, Enter to Select, Esc to Back');
end;

end.
