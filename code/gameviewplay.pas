{ Main 3D gameplay view for Castle Quake 2.
  Its components (viewport, camera, navigation, TQuakeMap, HUD, console, menu)
  are designed in data/gameviewplay.castle-user-interface ,
  so they can be inspected and tweaked in the CGE editor. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, {$ifdef MSWINDOWS} Windows, {$endif}
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils, CastleScene,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu, QuakeMap;

type
  TCameraMode = (cmFirstPerson, cmNoclip);

  { The main gameplay view }
  TViewPlay = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    MainViewport: TCastleViewport;
    WalkNavigation: TCastleWalkNavigation;
    Background: TCastleBackground;
    QuakeMap: TQuakeMap;
    Hud: TQuakeHud;
    Console: TQuakeConsole;
    Menu: TQuakeMenu;
    LabelFps: TCastleLabel;
  private
    FWorld: TQuakeWorld;
    FCameraMode: TCameraMode;
    FMapName: String;
    FAutoTestMap: String;
    FAutoTestPrefix: String;
    FAutoTestDemo: String;
    FAutoTestActive: Boolean;
    FAutoTestShots: Integer;
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FDemoTimer: Single;
    FDemoFireHeld: Boolean;
    procedure SetupSky(const SkyName: String);
    procedure PlaceCamera(const Pos: TVector3; const YawDeg: Single);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure CaptureScreenshot(const Prefix: String);
    procedure CycleWeapon(const Delta: Integer);
    { Autotest helper: stand on a floor near Target, looking at it }
    procedure GoNear(const Target: TVector3);
    procedure QuitNow;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;

    procedure LoadLevel(const AMapName: String);
    procedure SetCameraMode(const Mode: TCameraMode);

    property World: TQuakeWorld read FWorld;
    property MapName: String read FMapName write FMapName;
    property AutoTestMap: String read FAutoTestMap write FAutoTestMap;
    property AutoTestPrefix: String read FAutoTestPrefix write FAutoTestPrefix;
    property AutoTestDemo: String read FAutoTestDemo write FAutoTestDemo;
  end;

var
  ViewPlay: TViewPlay;

implementation

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FCameraMode := cmFirstPerson;
  FDemoCommands := TStringList.Create;
end;

destructor TViewPlay.Destroy;
begin
  FDemoCommands.Free;
  inherited Destroy;
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  WalkNavigation.Gravity := Mode = cmFirstPerson;
  WalkNavigation.MouseLook := True;
  if Mode = cmNoclip then
  begin
    Menu.CameraModeName := 'Noclip Fly';
    Hud.ShowMessage('noclip ON');
  end else
  begin
    Menu.CameraModeName := 'First-Person';
    Hud.ShowMessage('noclip OFF');
  end;
end;

procedure TViewPlay.SetupSky(const SkyName: String);

  { Load env/<sky><suffix>.tga (or .pcx), re-oriented for TCastleBackground,
    cache it and return its quaketex: URL ('' if missing).
    Quake 2 side faces already match X3D (upright, seen from inside);
    the up / down faces are rotated by 90 degrees relative to X3D. }
  function SideUrl(const Suffix: String): String;
  var
    Base, Id: String;
    Src, Dst: TCastleImage;
    X, Y, N: Integer;
  begin
    Result := '';
    Base := 'env/' + SkyName + Suffix;
    Id := 'sky/' + SkyName + Suffix;
    if not Palette.HasCachedImage(Id) then
    begin
      Src := nil;
      try
        if Pak.FileExists(Base + '.tga') then
          Src := LoadImage('quakepak:/' + Base + '.tga', [TRGBImage, TRGBAlphaImage])
        else
        if Palette.LoadPcx(Base + '.pcx', False) then
          Src := Palette.GetCachedImage(Base + '.pcx').MakeCopy;
      except
        on E: Exception do
          WritelnWarning('GameViewPlay', 'Cannot load sky "%s": %s', [Base, E.Message]);
      end;
      if Src = nil then
        Exit;
      WritelnLog('GameViewPlay', 'Sky side %s: %dx%d %s', [Base, Src.Width, Src.Height, Src.ClassName]);
      if (Suffix = 'up') or (Suffix = 'dn') then
      begin
        N := Min(Src.Width, Src.Height);
        Dst := TRGBAlphaImage.Create(N, N);
        for Y := 0 to N - 1 do
          for X := 0 to N - 1 do
            if Suffix = 'up' then
              Dst.Colors[X, Y, 0] := Src.Colors[Y, N - 1 - X, 0]
            else
              Dst.Colors[X, Y, 0] := Src.Colors[N - 1 - Y, X, 0];
        Src.Free;
        Palette.CacheImage(Id, Dst);
      end else
        Palette.CacheImage(Id, Src);
    end;
    Result := 'quaketex:/' + Id;
  end;

begin
  Background.SkyTopColor := Vector3(0.05, 0.05, 0.08);
  Background.SkyEquatorColor := Vector3(0.1, 0.1, 0.12);
  if SkyName = '' then
  begin
    Background.TexturePositiveX := '';
    Background.TextureNegativeX := '';
    Background.TexturePositiveY := '';
    Background.TextureNegativeY := '';
    Background.TextureNegativeZ := '';
    Background.TexturePositiveZ := '';
    Exit;
  end;
  { Quake 2: rt = +X, lf = -X, bk = Quake +Y (CGE -Z), ft = Quake -Y (CGE +Z).
    Note TCastleBackground.TexturePositiveZ is the X3D "front", drawn at -Z. }
  Background.TexturePositiveX := SideUrl('rt');
  Background.TextureNegativeX := SideUrl('lf');
  Background.TexturePositiveY := SideUrl('up');
  Background.TextureNegativeY := SideUrl('dn');
  Background.TexturePositiveZ := SideUrl('bk');
  Background.TextureNegativeZ := SideUrl('ft');
end;

procedure TViewPlay.Start;
begin
  inherited Start;

  { Settings that are not published (so not in the design) }
  WalkNavigation.FallingEffect := False; { Quake doesn't roll the camera when falling }

  FWorld := TQuakeWorld.Create(MainViewport.Items, QuakeMap);
  FWorld.AttachWeaponToCamera(MainViewport.Camera);
  FWorld.Hud := Hud;
  Particles.SetParent(MainViewport.Items);
  Console.OnCommand := @HandleConsoleCommand;
  Menu.OnMenuAction := @HandleMenuAction;
  SetCameraMode(FCameraMode);

  if FAutoTestMap <> '' then
  begin
    FAutoTestActive := True;
    ParseDemoScript(FAutoTestDemo);
    LoadLevel(FAutoTestMap);
  end else
  begin
    if FMapName = '' then
      FMapName := FirstMapName;
    LoadLevel(FMapName);
  end;
end;

procedure TViewPlay.Stop;
begin
  Sounds.StopMusic;
  Particles.SetParent(nil);
  { The world references design components, which are freed by inherited Stop }
  FreeAndNil(FWorld);
  inherited Stop;
end;

procedure TViewPlay.PlaceCamera(const Pos: TVector3; const YawDeg: Single);
begin
  MainViewport.Camera.SetWorldView(Pos, YawToCgeDir(YawDeg), Vector3(0, 1, 0));
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
begin
  WritelnLog('GameViewPlay', 'Loading level "%s"', [AMapName]);
  if FWorld.LoadMap(AMapName) then
  begin
    FMapName := FWorld.Bsp.MapName;
    PlaceCamera(FWorld.SpawnPoint, FWorld.SpawnAngle);
    SetupSky(FWorld.Geometry.SkyName);
    Hud.ShowMessage(FMapName, 3.0);
  end else
    Hud.ShowMessage('Failed to load level: ' + AMapName, 5.0);
end;

procedure TViewPlay.CaptureScreenshot(const Prefix: String);
var
  OutPath: String;
  Img: TCastleImage;
begin
  Inc(FAutoTestShots);
  OutPath := Prefix + '_' + IntToStr(FAutoTestShots) + '.png';
  try
    Img := Container.SaveScreen;
    try
      SaveImage(Img, OutPath);
    finally
      Img.Free;
    end;
    WritelnLog('GameViewPlay', 'Saved screenshot to "%s" (%.1f FPS, camera %s)',
      [OutPath, Container.Fps.RealFps, MainViewport.Camera.Translation.ToString]);
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewPlay.QuitNow;
begin
  {$ifdef MSWINDOWS}
  ExitProcess(0);
  {$else}
  Halt(0);
  {$endif}
end;

procedure TViewPlay.ParseDemoScript(const Script: String);
var
  Cmd: String;
begin
  FDemoCommands.Clear;
  FDemoIndex := 0;
  FDemoTimer := 0;
  for Cmd in Script.Split([',']) do
    if Trim(Cmd) <> '' then
      FDemoCommands.Add(Trim(Cmd));
end;

procedure TViewPlay.RunDemoStep(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P, J: Integer;
  Val: Single;
  Dir, Target: TVector3;
  Ignore: TCastleTransform;
begin
  if FDemoIndex >= FDemoCommands.Count then
  begin
    if FAutoTestActive then
    begin
      CaptureScreenshot(FAutoTestPrefix);
      QuitNow;
    end;
    Exit;
  end;

  Cmd := FDemoCommands[FDemoIndex];
  P := Pos(':', Cmd);
  if P > 0 then
  begin
    Action := UpperCase(Copy(Cmd, 1, P - 1));
    Param := Copy(Cmd, P + 1, MaxInt);
  end else
  begin
    Action := UpperCase(Cmd);
    Param := '';
  end;

  if Action = 'W' then { Wait }
  begin
    FDemoTimer := FDemoTimer + SecondsPassed;
    if FDemoTimer >= StrToFloatDef(Param, 1.0) then
    begin
      FDemoTimer := 0;
      Inc(FDemoIndex);
    end;
    Exit;
  end;

  if Action = 'S' then
    CaptureScreenshot(FAutoTestPrefix)
  else
  if Action = 'X' then
    FWorld.FireWeapon(MainViewport.Camera.Translation, MainViewport.Camera.Direction)
  else
  if Action = 'H' then { Hold / release fire }
    FDemoFireHeld := not FDemoFireHeld
  else
  if Action = 'U' then
    FWorld.ActivateUse(MainViewport.Camera.Translation, MainViewport.Camera.Direction)
  else
  if Action = 'A' then { Absolute yaw (Quake degrees) }
    PlaceCamera(MainViewport.Camera.Translation, StrToFloatDef(Param, 0))
  else
  if Action = 'T' then { Turn left by degrees }
    MainViewport.Camera.SetWorldView(MainViewport.Camera.Translation,
      RotatePointAroundAxisRad(DegToRad(StrToFloatDef(Param, 0)), MainViewport.Camera.Direction,
      Vector3(0, 1, 0)), Vector3(0, 1, 0))
  else
  if Action = 'P' then { Pitch up by degrees }
  begin
    Dir := MainViewport.Camera.Direction;
    Dir := RotatePointAroundAxisRad(DegToRad(StrToFloatDef(Param, 0)), Dir,
      TVector3.CrossProduct(Dir, Vector3(0, 1, 0)));
    MainViewport.Camera.SetWorldView(MainViewport.Camera.Translation, Dir, Vector3(0, 1, 0));
  end else
  if Action = 'M' then { Move along camera direction, with collisions }
  begin
    Val := StrToFloatDef(Param, 50.0);
    Dir := MainViewport.Camera.Direction;
    Dir.Y := 0;
    if Dir.Length > 0 then
      MainViewport.Camera.Translation := MainViewport.Camera.Translation + Dir.Normalize * Val;
  end else
  if (Action = 'N') or (Action = 'I') or (Action = 'D') then
  begin
    { Go near monster / item / mover number Param, standing on a floor, facing it }
    P := StrToIntDef(Param, 0);
    Target := MainViewport.Camera.Translation;
    Ignore := nil;
    if (Action = 'N') and (P < FWorld.Monsters.Count) then
    begin
      Target := FWorld.Monsters[P].Transform.Translation;
      Ignore := FWorld.Monsters[P].Transform;
    end else
    if (Action = 'I') and (P < FWorld.Pickups.Count) then
      Target := FWorld.Pickups[P].Origin
    else
    if (Action = 'D') and (P < FWorld.Geometry.Movers.Count) then
      Target := FWorld.Geometry.Movers[P].Center;
    { The target itself must not block the line of sight probes }
    if Ignore <> nil then
      Ignore.Exists := False;
    GoNear(Target);
    if Ignore <> nil then
      Ignore.Exists := True;
  end else
  if Action = 'O' then { Run a console command, e.g. "O:kill" or "O:map demo2" }
  begin
    P := Pos(' ', Param);
    if P > 0 then
      HandleConsoleCommand(LowerCase(Copy(Param, 1, P - 1)), Trim(Copy(Param, P + 1, MaxInt)))
    else
      HandleConsoleCommand(LowerCase(Param), '');
  end else
  if Action = 'E' then { Fire entity targets, like a trigger would }
    FWorld.UseTargets(Param)
  else
  if Action = 'V' then { Log mover states }
  begin
    for J := 0 to FWorld.Geometry.Movers.Count - 1 do
      WritelnLog('Demo', 'Mover %d %s state %d progress %.2f exists %s', [J,
        FWorld.Geometry.Movers[J].Entity.ClassName, Ord(FWorld.Geometry.Movers[J].State),
        FWorld.Geometry.Movers[J].Progress, BoolToStr(FWorld.Geometry.Movers[J].Transform.Exists, True)]);
  end else
  if Action = 'G' then { Go to "x y z" (Quake coordinates) }
  begin
    Val := 0;
    Target := Vector3(0, 0, 0);
    J := 0;
    for Cmd in Param.Split([' ']) do
      if (Cmd <> '') and (J < 3) then
      begin
        Target.Data[J] := StrToFloatDef(Cmd, 0);
        Inc(J);
      end;
    MainViewport.Camera.Translation := QuakeToCge(Target);
  end else
  if Action = 'C' then
    FWorld.SelectWeapon(StrToIntDef(Param, 2))
  else
  if Action = 'K' then
    FWorld.CheatGiveAll
  else
  if Action = 'Y' then
    FWorld.CheatGodMode
  else
  if Action = 'L' then { Load map }
    LoadLevel(Param)
  else
  if Action = 'Q' then
  begin
    if FAutoTestActive then
      QuitNow
    else
      Application.Terminate;
  end;
  Inc(FDemoIndex);
end;

procedure TViewPlay.GoNear(const Target: TVector3);
var
  J, Dist: Integer;
  Dir, Spot: TVector3;
  FloorDist: Single;
  Items: TCastleAbstractRootTransform;
begin
  Items := MainViewport.Items;
  for Dist in [160, 110, 220, 70] do
    for J := 0 to 7 do
    begin
      Dir := RotatePointAroundAxisRad(J * Pi / 4, Vector3(1, 0, 0), Vector3(0, 1, 0));
      Spot := Target + Dir * Dist;
      if not Items.WorldLineOfSight(Target, Spot) then
        Continue;
      { Need a floor less than 160 units below }
      if (Items.WorldRayCast(Spot, Vector3(0, -1, 0), FloorDist) = nil) or (FloorDist > 160) then
        Continue;
      Spot.Y := Spot.Y - FloorDist + PlayerEyeHeight;
      MainViewport.Camera.SetWorldView(Spot, (Target - Spot).Normalize, Vector3(0, 1, 0));
      WritelnLog('GameViewPlay', 'GoNear %s -> %s', [Target.ToString, Spot.ToString]);
      Exit;
    end;
  WritelnWarning('GameViewPlay', 'GoNear %s: no free spot found', [Target.ToString]);
end;

procedure TViewPlay.CycleWeapon(const Delta: Integer);
var
  I, Slot: Integer;
begin
  Slot := FWorld.Stats.CurrentWeapon;
  for I := 1 to 10 do
  begin
    Slot := ((Slot - 1 + Delta + 10) mod 10) + 1;
    if (FWorld.Stats.WeaponMask and (1 shl Slot)) <> 0 then
    begin
      FWorld.SelectWeapon(Slot);
      Exit;
    end;
  end;
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Firing: Boolean;
begin
  inherited Update(SecondsPassed, HandleInput);

  if FDemoCommands.Count > 0 then
    RunDemoStep(SecondsPassed);

  if FWorld = nil then
    Exit;

  if LabelFps.Exists then
    LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  FWorld.Update(SecondsPassed, MainViewport.Camera.Translation, MainViewport.Camera.Direction);
  WalkNavigation.Exists := not FWorld.Dead;

  if FWorld.TeleportPending then
  begin
    PlaceCamera(FWorld.TeleportPos, FWorld.TeleportAngle);
    FWorld.TeleportDone;
  end;

  if FWorld.RestartPending then
    LoadLevel(FMapName)
  else
  if FWorld.LevelExited and (FWorld.NextMap <> '') then
    LoadLevel(FWorld.NextMap);

  { Hold to fire (left mouse / Ctrl) }
  Firing := FDemoFireHeld;
  if not Console.IsOpen and not Menu.Exists then
    Firing := Firing or Container.Pressed[keyCtrl] or (buttonLeft in Container.MousePressed);
  if Firing then
    FWorld.FireWeapon(MainViewport.Camera.Translation, MainViewport.Camera.Direction);
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
const
  WeaponKeys: array[1..10] of TKey = (key1, key2, key3, key4, key5, key6, key7, key8, key9, key0);
var
  Slot: Integer;
begin
  Result := False;

  if Console.IsOpen then
    Exit(Console.Press(Event));

  if Menu.Exists then
  begin
    if Event.IsKey(keyEscape) then
    begin
      Menu.Exists := False;
      WalkNavigation.MouseLook := True;
      Exit(True);
    end;
    Exit(Menu.Press(Event));
  end;

  if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
  begin
    Console.Toggle;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    Menu.Exists := True;
    WalkNavigation.MouseLook := False;
    Exit(True);
  end;

  if Event.IsKey(keyE) then
  begin
    FWorld.ActivateUse(MainViewport.Camera.Translation, MainViewport.Camera.Direction);
    Exit(True);
  end;

  for Slot := 1 to 10 do
    if Event.IsKey(WeaponKeys[Slot]) then
    begin
      FWorld.SelectWeapon(Slot);
      Exit(True);
    end;

  if Event.EventType = itMouseWheel then
  begin
    if Event.MouseWheelScroll > 0 then
      CycleWeapon(1)
    else
      CycleWeapon(-1);
    Exit(True);
  end;

  if Event.IsKey(keyF1) then
  begin
    if FCameraMode = cmFirstPerson then
      SetCameraMode(cmNoclip)
    else
      SetCameraMode(cmFirstPerson);
    Exit(True);
  end;

  if Event.IsKey(keyF12) then
  begin
    CaptureScreenshot('screenshot');
    Hud.ShowMessage('Screenshot saved');
    Exit(True);
  end;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Maps: TStringList;
begin
  if (Cmd = 'map') or (Cmd = 'gamemap') then
  begin
    if Args <> '' then
      LoadLevel(Args)
    else
      Console.Print('Usage: map <mapname>');
  end else
  if Cmd = 'maps' then
  begin
    Maps := Pak.FindFiles('maps/', '.bsp');
    try
      Maps.Sort;
      Console.Print(Maps.CommaText);
    finally
      Maps.Free;
    end;
  end else
  if Cmd = 'fps' then
    LabelFps.Exists := not LabelFps.Exists
  else
  if Cmd = 'god' then
    FWorld.CheatGodMode
  else
  if (Cmd = 'give') and (Args = 'all') then
    FWorld.CheatGiveAll
  else
  if Cmd = 'noclip' then
  begin
    if FCameraMode = cmFirstPerson then
      SetCameraMode(cmNoclip)
    else
      SetCameraMode(cmFirstPerson);
  end else
  if Cmd = 'kill' then
    FWorld.DamagePlayer(1000, MainViewport.Camera.Translation)
  else
  if (Cmd = 'quit') or (Cmd = 'exit') then
    Application.Terminate
  else
  if Cmd = 'help' then
  begin
    Console.Print('Commands:');
    Console.Print('  map <name>   - Load map (e.g. base1, base2$spawn)');
    Console.Print('  maps         - List maps in the loaded PAKs');
    Console.Print('  god          - Toggle god mode');
    Console.Print('  give all     - All weapons, ammo, armor, keys');
    Console.Print('  noclip       - Toggle fly mode');
    Console.Print('  fps          - Toggle FPS counter');
    Console.Print('  kill         - Suicide');
    Console.Print('  quit         - Exit game');
  end else
    Console.Print('Unknown command: ' + Cmd);
end;

procedure TViewPlay.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame, maWarpMap:
      begin
        Menu.Exists := False;
        WalkNavigation.MouseLook := True;
        LoadLevel(Param);
      end;
    maToggleCamera:
      if FCameraMode = cmFirstPerson then
        SetCameraMode(cmNoclip)
      else
        SetCameraMode(cmFirstPerson);
    maQuit:
      Application.Terminate;
  end;
end;

end.
