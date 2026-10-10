{ Main 3D gameplay view for Castle Quake 2. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, {$ifdef MSWINDOWS} Windows, {$endif}
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils, CastleScene,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu;

type
  TCameraMode = (cmFirstPerson, cmNoclip);

  { The main gameplay view }
  TViewPlay = class(TCastleView)
  private
    FViewport: TCastleViewport;
    FNavigation: TCastleWalkNavigation;
    FBackground: TCastleBackground;
    FWorld: TQuakeWorld;
    FHud: TQuakeHud;
    FConsole: TQuakeConsole;
    FMenu: TQuakeMenu;
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
    procedure SetupNavigation;
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
  FCameraMode := cmFirstPerson;
  FDemoCommands := TStringList.Create;
end;

destructor TViewPlay.Destroy;
begin
  FreeAndNil(FWorld);
  FDemoCommands.Free;
  inherited Destroy;
end;

procedure TViewPlay.SetupNavigation;
begin
  if FNavigation <> nil then
    Exit;
  FNavigation := TCastleWalkNavigation.Create(Self);
  FNavigation.PreferredHeight := PlayerEyeHeight; { Quake 2 eye: 46 above the feet }
  FNavigation.Radius := 14;
  FNavigation.ClimbHeight := 18;                  { Quake 2 STEPSIZE }
  FNavigation.MoveSpeed := 300;                   { Quake 2 run speed }
  FNavigation.JumpMaxHeight := 1.0;
  FNavigation.CrouchHeight := 0.55;
  FNavigation.MouseLook := True;
  FNavigation.HeadBobbing := 0.02;
  { No camera roll when falling, Quake doesn't do that }
  FNavigation.FallingEffect := False;
  FViewport.InsertFront(FNavigation);
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  FNavigation.Gravity := Mode = cmFirstPerson;
  FNavigation.MouseLook := True;
  if Mode = cmNoclip then
  begin
    FMenu.CameraModeName := 'Noclip Fly';
    FHud.ShowMessage('noclip ON');
  end else
  begin
    FMenu.CameraModeName := 'First-Person';
    FHud.ShowMessage('noclip OFF');
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
  if FBackground = nil then
  begin
    FBackground := TCastleBackground.Create(Self);
    FViewport.Background := FBackground;
  end;
  FBackground.SkyTopColor := Vector3(0.05, 0.05, 0.08);
  FBackground.SkyEquatorColor := Vector3(0.1, 0.1, 0.12);
  if SkyName = '' then
  begin
    FBackground.TexturePositiveX := '';
    FBackground.TextureNegativeX := '';
    FBackground.TexturePositiveY := '';
    FBackground.TextureNegativeY := '';
    FBackground.TextureNegativeZ := '';
    FBackground.TexturePositiveZ := '';
    Exit;
  end;
  { Quake 2: rt = +X, lf = -X, bk = Quake +Y (CGE -Z), ft = Quake -Y (CGE +Z).
    Note TCastleBackground.TexturePositiveZ is the X3D "front", drawn at -Z. }
  FBackground.TexturePositiveX := SideUrl('rt');
  FBackground.TextureNegativeX := SideUrl('lf');
  FBackground.TexturePositiveY := SideUrl('up');
  FBackground.TextureNegativeY := SideUrl('dn');
  FBackground.TexturePositiveZ := SideUrl('bk');
  FBackground.TextureNegativeZ := SideUrl('ft');
end;

procedure TViewPlay.Start;
begin
  inherited Start;

  if FViewport = nil then
  begin
    FViewport := TCastleViewport.Create(Self);
    FViewport.FullSize := True;
    FViewport.Transparent := False;
    FViewport.BackgroundColor := Vector4(0.02, 0.02, 0.03, 1.0);
    InsertFront(FViewport);
    FViewport.Camera.ProjectionNear := 2.0;
    FViewport.Camera.ProjectionFar := 0; { infinite }
    FViewport.Camera.Perspective.FieldOfViewAxis := faHorizontal;
    FViewport.Camera.Perspective.FieldOfView := DegToRad(90.0);
  end;

  SetupNavigation;

  if FWorld = nil then
  begin
    FWorld := TQuakeWorld.Create(FViewport.Items);
    FWorld.AttachWeaponToCamera(FViewport.Camera);
  end;

  Particles.SetParent(FViewport.Items);

  if FHud = nil then
  begin
    FHud := TQuakeHud.Create(Self);
    InsertFront(FHud);
    FWorld.Hud := FHud;
  end;

  if FConsole = nil then
  begin
    FConsole := TQuakeConsole.Create(Self);
    FConsole.OnCommand := @HandleConsoleCommand;
    InsertFront(FConsole);
  end;

  if FMenu = nil then
  begin
    FMenu := TQuakeMenu.Create(Self);
    FMenu.OnMenuAction := @HandleMenuAction;
    FMenu.Exists := False;
    InsertFront(FMenu);
  end;

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
  inherited Stop;
end;

procedure TViewPlay.PlaceCamera(const Pos: TVector3; const YawDeg: Single);
begin
  FViewport.Camera.SetWorldView(Pos, YawToCgeDir(YawDeg), Vector3(0, 1, 0));
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
begin
  WritelnLog('GameViewPlay', 'Loading level "%s"', [AMapName]);
  if FWorld.LoadMap(AMapName) then
  begin
    FMapName := FWorld.Bsp.MapName;
    PlaceCamera(FWorld.SpawnPoint, FWorld.SpawnAngle);
    SetupSky(FWorld.Geometry.SkyName);
    FHud.ShowMessage(FMapName, 3.0);
  end else
    FHud.ShowMessage('Failed to load level: ' + AMapName, 5.0);
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
      [OutPath, Container.Fps.RealFps, FViewport.Camera.Translation.ToString]);
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
    FWorld.FireWeapon(FViewport.Camera.Translation, FViewport.Camera.Direction)
  else
  if Action = 'H' then { Hold / release fire }
    FDemoFireHeld := not FDemoFireHeld
  else
  if Action = 'U' then
    FWorld.ActivateUse(FViewport.Camera.Translation, FViewport.Camera.Direction)
  else
  if Action = 'A' then { Absolute yaw (Quake degrees) }
    PlaceCamera(FViewport.Camera.Translation, StrToFloatDef(Param, 0))
  else
  if Action = 'T' then { Turn left by degrees }
    FViewport.Camera.SetWorldView(FViewport.Camera.Translation,
      RotatePointAroundAxisRad(DegToRad(StrToFloatDef(Param, 0)), FViewport.Camera.Direction,
      Vector3(0, 1, 0)), Vector3(0, 1, 0))
  else
  if Action = 'P' then { Pitch up by degrees }
  begin
    Dir := FViewport.Camera.Direction;
    Dir := RotatePointAroundAxisRad(DegToRad(StrToFloatDef(Param, 0)), Dir,
      TVector3.CrossProduct(Dir, Vector3(0, 1, 0)));
    FViewport.Camera.SetWorldView(FViewport.Camera.Translation, Dir, Vector3(0, 1, 0));
  end else
  if Action = 'M' then { Move along camera direction, with collisions }
  begin
    Val := StrToFloatDef(Param, 50.0);
    Dir := FViewport.Camera.Direction;
    Dir.Y := 0;
    if Dir.Length > 0 then
      FViewport.Camera.Translation := FViewport.Camera.Translation + Dir.Normalize * Val;
  end else
  if (Action = 'N') or (Action = 'I') or (Action = 'D') then
  begin
    { Go near monster / item / mover number Param, standing on a floor, facing it }
    P := StrToIntDef(Param, 0);
    Target := FViewport.Camera.Translation;
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
    FViewport.Camera.Translation := QuakeToCge(Target);
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
  Items := FViewport.Items;
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
      FViewport.Camera.SetWorldView(Spot, (Target - Spot).Normalize, Vector3(0, 1, 0));
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

  FWorld.Update(SecondsPassed, FViewport.Camera.Translation, FViewport.Camera.Direction);
  FNavigation.Exists := not FWorld.Dead;

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
  if not FConsole.IsOpen and not FMenu.Exists then
    Firing := Firing or Container.Pressed[keyCtrl] or (buttonLeft in Container.MousePressed);
  if Firing then
    FWorld.FireWeapon(FViewport.Camera.Translation, FViewport.Camera.Direction);
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
const
  WeaponKeys: array[1..10] of TKey = (key1, key2, key3, key4, key5, key6, key7, key8, key9, key0);
var
  Slot: Integer;
begin
  Result := False;

  if FConsole.IsOpen then
    Exit(FConsole.Press(Event));

  if FMenu.Exists then
  begin
    if Event.IsKey(keyEscape) then
    begin
      FMenu.Exists := False;
      FNavigation.MouseLook := True;
      Exit(True);
    end;
    Exit(FMenu.Press(Event));
  end;

  if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
  begin
    FConsole.Toggle;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    FMenu.Exists := True;
    FNavigation.MouseLook := False;
    Exit(True);
  end;

  if Event.IsKey(keyE) then
  begin
    FWorld.ActivateUse(FViewport.Camera.Translation, FViewport.Camera.Direction);
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
    FHud.ShowMessage('Screenshot saved');
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
      FConsole.Print('Usage: map <mapname>');
  end else
  if Cmd = 'maps' then
  begin
    Maps := Pak.FindFiles('maps/', '.bsp');
    try
      Maps.Sort;
      FConsole.Print(Maps.CommaText);
    finally
      Maps.Free;
    end;
  end else
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
    FWorld.DamagePlayer(1000, FViewport.Camera.Translation)
  else
  if (Cmd = 'quit') or (Cmd = 'exit') then
    Application.Terminate
  else
  if Cmd = 'help' then
  begin
    FConsole.Print('Commands:');
    FConsole.Print('  map <name>   - Load map (e.g. base1, base2$spawn)');
    FConsole.Print('  maps         - List maps in the loaded PAKs');
    FConsole.Print('  god          - Toggle god mode');
    FConsole.Print('  give all     - All weapons, ammo, armor, keys');
    FConsole.Print('  noclip       - Toggle fly mode');
    FConsole.Print('  kill         - Suicide');
    FConsole.Print('  quit         - Exit game');
  end else
    FConsole.Print('Unknown command: ' + Cmd);
end;

procedure TViewPlay.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame, maWarpMap:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := True;
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
