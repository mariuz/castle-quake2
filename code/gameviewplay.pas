{ Main 3D gameplay view for Castle Quake 2.
  Its components (viewport, camera, navigation, TQuakeMap, HUD, console, menu)
  are designed in data/gameviewplay.castle-user-interface ,
  so they can be inspected and tweaked in the CGE editor. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils, CastleScene,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu, QuakeMap,
  QuakePlayer, fpjson, jsonparser, CastleDownload;

type
  TCameraMode = (cmFirstPerson, cmNoclip);

  { The main gameplay view }
  TViewPlay = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    MainViewport: TCastleViewport;
    { Draws only the view weapon, on top of MainViewport with a cleared depth
      buffer, so the gun never sticks into walls (like Quake 2's depth hack) }
    WeaponViewport: TCastleViewport;
    WalkNavigation: TCastleWalkNavigation;
    { Quake 2 pmove (behavior of Camera); WalkNavigation only does mouse look
      while it's enabled }
    PlayerMovement: TQuakePlayerMovement;
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
    FIntermission: Boolean;
    FIntermissionTime: Single;
    { Demo script movement: hold forward / side input until FDemoMoveTime runs out }
    FDemoMoveForward, FDemoMoveSide: Single;
    FDemoMoveTime: Single;
    FDemoJump: Boolean;
    procedure UpdateMovementInput(const SecondsPassed: Single);
    procedure BeginIntermission;
    procedure EndIntermission;
    procedure PlaceCamera(const Pos: TVector3; const YawDeg: Single);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure CaptureScreenshot(const Prefix: String);
    procedure CycleWeapon(const Delta: Integer);
    { Savegames in castle-config:/saves/<name>.json }
    procedure SaveGame(const SaveName: String);
    procedure LoadGame(const SaveName: String);
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
  WalkNavigation.Gravity := (Mode = cmFirstPerson) and not PlayerMovement.Active;
  PlayerMovement.Noclip := Mode = cmNoclip;
  { Autotests must not depend on where the desktop mouse happens to be }
  WalkNavigation.MouseLook := FAutoTestMap = '';
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

procedure TViewPlay.Start;
begin
  inherited Start;

  { Settings that are not published (so not in the design) }
  WalkNavigation.FallingEffect := False; { Quake doesn't roll the camera when falling }
  if PlayerMovement.Active then
  begin
    { pmove moves the player; the navigation only turns the view }
    WalkNavigation.Gravity := False;
    WalkNavigation.Input_Forward.MakeClear;
    WalkNavigation.Input_Backward.MakeClear;
    WalkNavigation.Input_LeftStrafe.MakeClear;
    WalkNavigation.Input_RightStrafe.MakeClear;
    WalkNavigation.Input_Jump.MakeClear;
    WalkNavigation.Input_Crouch.MakeClear;
  end;

  FWorld := TQuakeWorld.Create(MainViewport.Items, QuakeMap);
  FWorld.AttachWeaponToCamera(WeaponViewport.Camera);
  FWorld.Hud := Hud;
  FWorld.Player := PlayerMovement;
  Particles.SetParent(MainViewport.Items);
  Particles.Camera := MainViewport.Camera;
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
  Particles.Camera := nil;
  Particles.SetParent(nil);
  { The world references design components, which are freed by inherited Stop }
  FreeAndNil(FWorld);
  inherited Stop;
end;

procedure TViewPlay.PlaceCamera(const Pos: TVector3; const YawDeg: Single);
begin
  MainViewport.Camera.SetWorldView(Pos, YawToCgeDir(YawDeg), Vector3(0, 1, 0));
  PlayerMovement.ResetVelocity;
end;

procedure TViewPlay.UpdateMovementInput(const SecondsPassed: Single);
var
  Typing: Boolean;
begin
  Typing := Console.IsOpen or Menu.Exists or FIntermission or FWorld.Dead;
  PlayerMovement.InputForward := 0;
  PlayerMovement.InputSide := 0;
  PlayerMovement.InputJump := False;
  PlayerMovement.InputCrouch := False;
  if not Typing then
  begin
    if Container.Pressed[keyW] or Container.Pressed[keyArrowUp] then
      PlayerMovement.InputForward := PlayerMovement.InputForward + 1;
    if Container.Pressed[keyS] or Container.Pressed[keyArrowDown] then
      PlayerMovement.InputForward := PlayerMovement.InputForward - 1;
    if Container.Pressed[keyD] then
      PlayerMovement.InputSide := PlayerMovement.InputSide + 1;
    if Container.Pressed[keyA] then
      PlayerMovement.InputSide := PlayerMovement.InputSide - 1;
    PlayerMovement.InputJump := Container.Pressed[keySpace];
    PlayerMovement.InputCrouch := Container.Pressed[keyC];
  end;
  { Scripted movement for autotests }
  if FDemoMoveTime > 0 then
  begin
    FDemoMoveTime := FDemoMoveTime - SecondsPassed;
    PlayerMovement.InputForward := FDemoMoveForward;
    PlayerMovement.InputSide := FDemoMoveSide;
  end;
  if FDemoJump then
  begin
    PlayerMovement.InputJump := True;
    FDemoJump := False;
  end;
  PlayerMovement.Suspended := FWorld.Dead or FIntermission;
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
begin
  WritelnLog('GameViewPlay', 'Loading level "%s"', [AMapName]);
  if FWorld.LoadMap(AMapName) then
  begin
    FMapName := FWorld.Bsp.MapName;
    PlaceCamera(FWorld.SpawnPoint, FWorld.SpawnAngle);
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
  { Leave through the normal main loop exit, so views stop and everything is
    freed in order (Halt / ExitProcess skipped or broke unit finalization) }
  FDemoCommands.Clear;
  FAutoTestActive := False;
  Application.Terminate;
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
  if Action = 'GO' then { Hold movement input: "GO:forward side seconds", e.g. GO:1 0 2 }
  begin
    J := 0;
    for Cmd in Param.Split([' ']) do
      if Cmd <> '' then
      begin
        case J of
          0: FDemoMoveForward := StrToFloatDef(Cmd, 0);
          1: FDemoMoveSide := StrToFloatDef(Cmd, 0);
          2: FDemoMoveTime := StrToFloatDef(Cmd, 1);
        end;
        Inc(J);
      end;
  end else
  if Action = 'J' then { Jump }
    FDemoJump := True
  else
  if Action = 'M' then { Move along camera direction, with collisions }
  begin
    Val := StrToFloatDef(Param, 50.0);
    Dir := MainViewport.Camera.Direction;
    Dir.Y := 0;
    if Dir.Length > 0 then
      MainViewport.Camera.Translation := MainViewport.Camera.Translation + Dir.Normalize * Val;
  end else
  if (Action = 'N') or (Action = 'I') or (Action = 'D') or (Action = 'R') then
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
      Target := FWorld.Geometry.Movers[P].Center
    else
    if (Action = 'R') and (P < FWorld.Props.Count) then
    begin
      Target := FWorld.Props[P].Transform.Translation + Vector3(0, 16, 0);
      Ignore := FWorld.Props[P].Transform;
    end;
    { The target itself must not block the line of sight probes }
    if Ignore <> nil then
      Ignore.Exists := False;
    GoNear(Target);
    if Ignore <> nil then
      Ignore.Exists := True;
  end else
  if Action = 'F' then { Toggle the help computer (F1) }
    Hud.HelpVisible := not Hud.HelpVisible
  else
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
    WritelnLog('Demo', 'Player at %s ladder %s water level %d on ground %s velocity %s health %d', [
      MainViewport.Camera.Translation.ToString, BoolToStr(PlayerMovement.OnLadder, True), PlayerMovement.WaterLevel,
      BoolToStr(PlayerMovement.OnGround, True), PlayerMovement.Velocity.ToString,
      FWorld.Stats.Health]);
    for J := 0 to FWorld.Geometry.Movers.Count - 1 do
      WritelnLog('Demo', 'Mover %d %s state %d progress %.2f exists %s', [J,
        FWorld.Geometry.Movers[J].Entity.ClassName, Ord(FWorld.Geometry.Movers[J].State),
        FWorld.Geometry.Movers[J].Progress, BoolToStr(FWorld.Geometry.Movers[J].Transform.Exists, True)]);
    for J := 0 to FWorld.Props.Count - 1 do
      WritelnLog('Demo', 'Prop %d %s health %d destroyed %s flying %s exists %s', [J,
        FWorld.Props[J].Entity.ClassName, FWorld.Props[J].Health,
        BoolToStr(FWorld.Props[J].Destroyed, True), BoolToStr(FWorld.Props[J].Flying, True),
        BoolToStr(FWorld.Props[J].Transform.Exists, True)]);
    for J := 0 to FWorld.Monsters.Count - 1 do
      if FWorld.Monsters[J].IsAlive and (FWorld.Monsters[J].Alerted or
         (FWorld.Monsters[J].MoveTarget <> nil) or (FWorld.Monsters[J].GoalEntity <> nil) or
         (FWorld.Monsters[J].CombatTarget <> '')) then
        WritelnLog('Demo', 'Monster %d %s state %d dist %.0f pos %s alerted %s patrol %s combatpoint %s %s hold %s', [J,
          FWorld.Monsters[J].Def^.ClassName, Ord(FWorld.Monsters[J].State),
          PointsDistance(FWorld.Monsters[J].Transform.Translation, MainViewport.Camera.Translation),
          CgeToQuake(FWorld.Monsters[J].Transform.Translation).ToString,
          BoolToStr(FWorld.Monsters[J].Alerted, True),
          BoolToStr(FWorld.Monsters[J].MoveTarget <> nil, True),
          BoolToStr(FWorld.Monsters[J].GoalEntity <> nil, True), FWorld.Monsters[J].CombatTarget,
          BoolToStr(FWorld.Monsters[J].HoldGround, True)]);
    for J := 0 to FWorld.Lasers.Count - 1 do
      WritelnLog('Demo', 'Laser %d on %s length %.0f', [J,
        BoolToStr(FWorld.Lasers[J].IsOn, True), FWorld.Lasers[J].Length]);
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
    QuitNow;
    Exit;
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

procedure TViewPlay.BeginIntermission;
var
  Pos, Dir: TVector3;
  Yaw, Pitch: Single;
begin
  FIntermission := True;
  FIntermissionTime := 0;
  Hud.Intermission := True;
  Hud.HelpVisible := False;
  WalkNavigation.Exists := False;
  if FWorld.WeaponTransform <> nil then
    FWorld.WeaponTransform.Exists := False;
  if FWorld.IntermissionSpot(Pos, Yaw, Pitch) then
  begin
    { Quake pitch: positive looks down }
    Dir := YawToCgeDir(Yaw) * Cos(DegToRad(Pitch)) + Vector3(0, -Sin(DegToRad(Pitch)), 0);
    MainViewport.Camera.SetWorldView(Pos, Dir.Normalize, Vector3(0, 1, 0));
  end;
  Sounds.Play('sound/misc/secret.wav');
end;

procedure TViewPlay.EndIntermission;
begin
  FIntermission := False;
  Hud.Intermission := False;
  WalkNavigation.Exists := True;
  if FWorld.WeaponTransform <> nil then
    FWorld.WeaponTransform.Exists := True;
  LoadLevel(FWorld.NextMap);
end;

function SaveUrl(const SaveName: String): String;
begin
  Result := 'castle-config:/saves/' + LowerCase(SaveName) + '.json';
end;

procedure TViewPlay.SaveGame(const SaveName: String);
var
  Obj: TJSONObject;
  Stream: TStream;
  Text: String;
begin
  if (FWorld = nil) or (FWorld.Bsp = nil) or FWorld.Dead or FIntermission then
  begin
    Hud.ShowMessage('Can''t save now');
    Exit;
  end;
  Obj := FWorld.SaveState;
  try
    Obj.Add('camera', TJSONArray.Create([MainViewport.Camera.Translation.X,
      MainViewport.Camera.Translation.Y, MainViewport.Camera.Translation.Z]));
    Obj.Add('direction', TJSONArray.Create([MainViewport.Camera.Direction.X,
      MainViewport.Camera.Direction.Y, MainViewport.Camera.Direction.Z]));
    Obj.Add('unitLevels', FWorld.UnitLevelsToJson);
    Text := Obj.FormatJSON;
  finally
    Obj.Free;
  end;
  try
    Stream := UrlSaveStream(SaveUrl(SaveName));
    try
      if Text <> '' then
        Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
    Hud.ShowMessage('Game saved: ' + SaveName);
    WritelnLog('GameViewPlay', 'Saved game to %s', [SaveUrl(SaveName)]);
  except
    on E: Exception do
      Hud.ShowMessage('Save failed: ' + E.Message);
  end;
end;

procedure TViewPlay.LoadGame(const SaveName: String);
var
  Stream: TStream;
  Data: TJSONData;
  Obj: TJSONObject;
  Text: String;
  Arr: TJSONArray;
  Dir: TVector3;
begin
  try
    Stream := Download(SaveUrl(SaveName));
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    Hud.ShowMessage('No savegame "' + SaveName + '"');
    Exit;
  end;
  Data := GetJSON(Text);
  try
    if not (Data is TJSONObject) then
      Exit;
    Obj := TJSONObject(Data);
    if FIntermission then
    begin
      FIntermission := False;
      Hud.Intermission := False;
    end;
    LoadLevel(Obj.Get('map', 'demo1'));
    if FWorld.Bsp = nil then
      Exit;
    FWorld.LoadState(Obj);
    FWorld.UnitLevelsFromJson(Obj.Get('unitLevels', TJSONObject(nil)));
    Arr := Obj.Get('camera', TJSONArray(nil));
    if (Arr <> nil) and (Arr.Count = 3) then
    begin
      Dir := Vector3(0, 0, -1);
      if (Obj.Get('direction', TJSONArray(nil)) <> nil) and (Obj.Arrays['direction'].Count = 3) then
        Dir := Vector3(Obj.Arrays['direction'].Floats[0], Obj.Arrays['direction'].Floats[1],
          Obj.Arrays['direction'].Floats[2]);
      MainViewport.Camera.SetWorldView(Vector3(Arr.Floats[0], Arr.Floats[1], Arr.Floats[2]),
        Dir, Vector3(0, 1, 0));
      PlayerMovement.ResetVelocity;
    end;
    Hud.ShowMessage('Game loaded: ' + SaveName);
    WritelnLog('GameViewPlay', 'Loaded game from %s', [SaveUrl(SaveName)]);
  finally
    Data.Free;
  end;
end;

procedure TViewPlay.CycleWeapon(const Delta: Integer);
var
  I, Slot: Integer;
begin
  Slot := FWorld.Stats.CurrentWeapon;
  for I := 1 to WeaponSlots do
  begin
    Slot := ((Slot - 1 + Delta + WeaponSlots) mod WeaponSlots) + 1;
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

  { Intermission: world frozen until a key press (or 8 seconds) }
  if FIntermission then
  begin
    FIntermissionTime := FIntermissionTime + SecondsPassed;
    if FIntermissionTime > 8 then
      EndIntermission;
    Exit;
  end;

  UpdateMovementInput(SecondsPassed);
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
    BeginIntermission;

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

  if FIntermission then
  begin
    if FIntermissionTime > 1 then
      EndIntermission;
    Exit(True);
  end;

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
  if Event.IsKey(keyG) then
  begin
    FWorld.SelectWeapon(11); { hand grenades }
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
    { Quake 2 help computer }
    Hud.HelpVisible := not Hud.HelpVisible;
    Sounds.Play('sound/misc/pc_up.wav');
    Exit(True);
  end;

  if Event.IsKey(keyF6) then
  begin
    SaveGame('quick');
    Exit(True);
  end;

  if Event.IsKey(keyF9) then
  begin
    LoadGame('quick');
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
  P: Integer;
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
  if Cmd = 'markers' then
    QuakeMap.PreviewMarkers := not QuakeMap.PreviewMarkers
  else
  if Cmd = 'save' then
  begin
    if Args = '' then
      SaveGame('quick')
    else
      SaveGame(Args);
  end else
  if Cmd = 'load' then
  begin
    if Args = '' then
      LoadGame('quick')
    else
      LoadGame(Args);
  end else
  if Cmd = 'lightstyle' then
  begin
    { lightstyle <n> <pattern of a..z>, e.g. "lightstyle 0 z" for full bright }
    P := Pos(' ', Args);
    if P > 0 then
      Lighting.SetStyle(StrToIntDef(Copy(Args, 1, P - 1), 0), LowerCase(Trim(Copy(Args, P + 1, MaxInt))))
    else
      Console.Print('Usage: lightstyle <0..255> <pattern a..z>');
  end else
  if Cmd = 'god' then
    FWorld.CheatGodMode
  else
  if (Cmd = 'give') and (Args = 'all') then
    FWorld.CheatGiveAll
  else
  if (Cmd = 'give') and (Args = 'quad') then
    FWorld.CheatPowerup(True)
  else
  if (Cmd = 'give') and (Args = 'invulnerability') then
    FWorld.CheatPowerup(False)
  else
  if Cmd = 'notarget' then
  begin
    NoTarget := not NoTarget;
    Hud.ShowMessage('notarget ' + Iff(NoTarget, 'ON', 'OFF'), 2);
  end else
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
    Console.Print('  give quad / give invulnerability - Powerups');
    Console.Print('  noclip       - Toggle fly mode');
    Console.Print('  notarget     - Monsters ignore you');
    Console.Print('  fps          - Toggle FPS counter');
    Console.Print('  markers      - Show player starts, paths and triggers');
    Console.Print('  save [name]  - Save the game (F6 = quick save)');
    Console.Print('  load [name]  - Load a saved game (F9 = quick load)');
    Console.Print('  lightstyle n p - Set light style n to pattern p (a = dark .. z = bright)');
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
