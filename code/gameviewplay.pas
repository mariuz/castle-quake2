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
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu, QuakeMap, QuakeGamepad, QuakeTouch,
  QuakePlayer, QuakeSettings, QuakeMapReport, QuakeRecord, QuakeLevel, QuakeLevelGen, QuakeLevelEditor, QuakeBspBuilder, QuakeTrace, fpjson, jsonparser, CastleDownload, CastleUriUtils;

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
  private
    FEditor: TQuakeLevelEditor;
    FOpenEditorOnStart: Boolean;
  published
    LabelFps: TCastleLabel;
  private
    FWorld: TQuakeWorld;
    FCameraMode: TCameraMode;
    FMapName: String;
    FAutoTestMap: String;
    FAutoTestPrefix: String;
    FAutoTestDemo: String;
    FAutoTestActive: Boolean;
    FMapReportFile: String;
    FAutoTestShots: Integer;
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FDemoTimer: Single;
    FDemoFireHeld: Boolean;
    { Right trigger held this frame }
    FGamepadFire: Boolean;
    FIntermission: Boolean;
    FIntermissionTime: Single;
    { Demo script movement: hold forward / side input until FDemoMoveTime runs out }
    FDemoMoveForward, FDemoMoveSide: Single;
    FDemoMoveTime: Single;
    FDemoJump: Boolean;
    { On-screen touch controls (phones, tablets, --touch), nil otherwise }
    FTouch: TQuakeTouchControls;
    { Demo script touches: last position of each finger }
    FTouchPos: array[0..4] of TVector2;
    { Monster placed by MV: always in the V log }
    FWatchedMonster: Integer;
    { Death view: seconds since death (-1 alive), the eye then and the yaw
      it turns to }
    FDeathTime: Single;
    FDeathFrom: TVector3;
    FDeathYawDir: TVector3;
    { Script clock for IN commands: seconds since the script (or its last L) started }
    FDemoClock: Single;
    { Held by the last IN command }
    FDemoInFire, FDemoInJump, FDemoInCrouch: Boolean;
    { IN positions: correct the drift (SY:0 turns it off); largest drift seen }
    FDemoNoSync: Boolean;
    FDemoMaxDrift: Single;
    { "record" console command: the playthrough being recorded, nil otherwise }
    FRecorder: TQuakeRecorder;
    FRecordClock: Single;
    FRecordName: String;
    procedure StartRecording(const AName: String);
    procedure StopRecording;
    { Note an instant action in the recording, at the current time }
    procedure RecordCommand(const Cmd: String);
    procedure SampleRecording(const Firing: Boolean);
    { Player actions that a recording keeps }
    procedure DoSelectWeapon(const Slot: Integer);
    procedure DoUse;
    procedure DoToggleHelp;
    { Look along Quake yaw / pitch (pitch positive looks down), keeping the velocity }
    procedure SetLook(const YawDeg, PitchDeg: Single);
    procedure UpdateDeathView(const SecondsPassed: Single);
    function WantMouseLook: Boolean;
    procedure TouchUse(Sender: TObject);
    procedure TouchNextWeapon(Sender: TObject);
    procedure TouchMenu(Sender: TObject);
    { The level editor (created when first opened) }
    procedure OpenEditor;
    function EditorOpen: Boolean;
    procedure EditorPlay(const Level: TQuakeLevel);
    procedure EditorClose(const Level: TQuakeLevel);
    procedure EditorCommand(const Args: String);
    procedure UpdateMovementInput(const SecondsPassed: Single);
    procedure BeginIntermission;
    procedure EndIntermission;
    procedure PlaceCamera(const Pos: TVector3; const YawDeg: Single);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    { "spawn classname key value...": a new map entity in front of the player }
    procedure SpawnFromConsole(const Args: String);
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
    function GoNearByTraces(const Target: TVector3): Boolean;
    procedure QuitNow;
    procedure RunMapReport;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;

    procedure LoadLevel(const AMapName: String);
    procedure SetCameraMode(const Mode: TCameraMode);
    { Apply Settings: mouse sensitivity / invert, field of view, volumes }
    procedure ApplySettings;

    property World: TQuakeWorld read FWorld;
    property MapName: String read FMapName write FMapName;
    { Open the level editor once the view has started (the title menu's
      Level Editor) }
    property OpenEditorOnStart: Boolean read FOpenEditorOnStart write FOpenEditorOnStart;
    property AutoTestMap: String read FAutoTestMap write FAutoTestMap;
    property AutoTestPrefix: String read FAutoTestPrefix write FAutoTestPrefix;
    property AutoTestDemo: String read FAutoTestDemo write FAutoTestDemo;
    { Load every map and write a compatibility report here, then quit }
    property MapReportFile: String read FMapReportFile write FMapReportFile;
  end;

var
  ViewPlay: TViewPlay;

implementation

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FCameraMode := cmFirstPerson;
  FWatchedMonster := -1;
  FDeathTime := -1;
  FDemoCommands := TStringList.Create;
end;

destructor TViewPlay.Destroy;
begin
  FreeAndNil(FRecorder);
  FDemoCommands.Free;
  inherited Destroy;
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  WalkNavigation.Gravity := (Mode = cmFirstPerson) and not PlayerMovement.Active;
  PlayerMovement.Noclip := Mode = cmNoclip;
  { Autotests must not depend on where the desktop mouse happens to be }
  WalkNavigation.MouseLook := WantMouseLook;
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

procedure TViewPlay.ApplySettings;
begin
  WalkNavigation.MouseLookHorizontalSensitivity :=
    TCastleWalkNavigation.DefaultMouseLookHorizontalSensitivity * Settings.MouseSensitivity;
  WalkNavigation.MouseLookVerticalSensitivity :=
    TCastleWalkNavigation.DefaultMouseLookVerticalSensitivity * Settings.MouseSensitivity;
  WalkNavigation.InvertVerticalMouseLook := Settings.InvertMouse;
  { The design's camera uses a horizontal field of view, like Quake 2 }
  MainViewport.Camera.Perspective.FieldOfView := DegToRad(Settings.FieldOfView);
  PlayerMovement.ViewBob := Settings.ViewBob;
  Settings.ApplyAudio;
end;

function TViewPlay.WantMouseLook: Boolean;
begin
  { Autotests must not depend on the desktop mouse; touch looks by dragging }
  Result := (FAutoTestMap = '') and (FTouch = nil);
end;

procedure TViewPlay.TouchUse(Sender: TObject);
begin
  if (FWorld <> nil) and not FWorld.Dead then
    DoUse;
end;

procedure TViewPlay.TouchNextWeapon(Sender: TObject);
begin
  if (FWorld <> nil) and not FWorld.Dead then
    CycleWeapon(1);
end;

function SplitArgs(const Args: String): TStringList;
var
  I: Integer;
  Word: String;
  Quoted, HasWord: Boolean;
begin
  Result := TStringList.Create;
  Word := '';
  Quoted := False;
  HasWord := False;
  for I := 1 to Length(Args) do
    if Args[I] = '"' then
    begin
      Quoted := not Quoted;
      HasWord := True;
    end else
    if (Args[I] = ' ') and not Quoted then
    begin
      if HasWord then
        Result.Add(Word);
      Word := '';
      HasWord := False;
    end else
    begin
      Word := Word + Args[I];
      HasWord := True;
    end;
  if HasWord then
    Result.Add(Word);
end;

procedure TViewPlay.OpenEditor;
var
  ConsoleParent: TCastleUserInterface;
begin
  EnsureLevelThemes;
  if FEditor = nil then
  begin
    FEditor := TQuakeLevelEditor.Create(FreeAtStop);
    FEditor.Name := 'LevelEditor';
    FEditor.OnPlay := @EditorPlay;
    FEditor.OnClose := @EditorClose;
    InsertFront(FEditor);
    { The console stays usable over the editor: move it to the front
      (removed first: inserting a control that is already in the list adds
      it twice, and the stale entry was written to after the console was
      freed, crashing on exit) }
    ConsoleParent := Console.Parent;
    ConsoleParent.RemoveControl(Console);
    ConsoleParent.InsertFront(Console);
  end;
  Menu.Exists := False;
  FEditor.Exists := True;
  WalkNavigation.MouseLook := False;
  WritelnLog('GameViewPlay', 'Level editor opened');
end;

function TViewPlay.EditorOpen: Boolean;
begin
  Result := (FEditor <> nil) and FEditor.Exists;
end;

procedure TViewPlay.EditorPlay(const Level: TQuakeLevel);
var
  BuiltMap: String;
begin
  { Saved too, so restarts and savegames can build it again (MissingMapHook) }
  try
    Level.SaveToFile(LevelFileUrl(Level.Name));
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Cannot save level "%s": %s', [Level.Name, E.Message]);
  end;
  try
    BuiltMap := RegisterLevelMap(Level);
  except
    on E: Exception do
    begin
      FEditor.ShowStatus('Cannot build the level: ' + E.Message);
      Exit;
    end;
  end;
  FEditor.Exists := False;
  WalkNavigation.MouseLook := WantMouseLook;
  { A new unit: no remembered state of an older build of this level }
  LoadLevel('*' + BuiltMap);
end;

procedure TViewPlay.EditorClose(const Level: TQuakeLevel);
begin
  FEditor.Exists := False;
  Menu.Exists := True;
end;

procedure TViewPlay.EditorCommand(const Args: String);
var
  Words: TStringList;
  Cmd: String;
  T: TLevelEditTool;
  I: Integer;
begin
  OpenEditor;
  Words := SplitArgs(Args);
  try
    if Words.Count = 0 then
      Exit;
    Cmd := LowerCase(Words[0]);
    if Cmd = 'new' then
      FEditor.RunCommand(ecNew)
    else
    if (Cmd = 'generate') and (Words.Count > 1) then
      FEditor.Generate(StrToIntDef(Words[1], 1))
    else
    if Cmd = 'generate' then
      FEditor.RunCommand(ecGenerate)
    else
    if Cmd = 'save' then
    begin
      if Words.Count > 1 then
        FEditor.Level.Name := Words[1];
      FEditor.SaveLevel;
    end else
    if (Cmd = 'load') and (Words.Count > 1) then
      FEditor.LoadLevel(Words[1])
    else
    if Cmd = 'play' then
      FEditor.RunCommand(ecPlay)
    else
    if Cmd = 'export' then
      FEditor.RunCommand(ecExport)
    else
    if Cmd = 'close' then
      FEditor.RunCommand(ecClose)
    else
    if (Cmd = 'name') and (Words.Count > 1) then
      FEditor.Level.Name := Words[1]
    else
    if (Cmd = 'tool') and (Words.Count > 1) then
    begin
      for T := Low(TLevelEditTool) to High(TLevelEditTool) do
        if SameText(ToolNames[T], Words[1]) then
          FEditor.Tool := T;
    end else
    if (Cmd = 'entity') and (Words.Count > 1) then
    begin
      for I := 0 to High(EditorEntityClasses) do
        if SameText(EditorEntityClasses[I], Words[1]) then
        begin
          FEditor.EntityIndex := I;
          FEditor.Tool := etEntity;
        end;
    end else
    if (Cmd = 'channel') and (Words.Count > 1) then
      FEditor.BrushChannel := EnsureRange(StrToIntDef(Words[1], 0), 0, 9)
    else
    if (Cmd = 'key') and (Words.Count > 1) then
    begin
      { editor key blue|red|1|2 }
      if SameText(Words[1], 'red') or (Words[1] = '2') then
        FEditor.BrushKey := 2
      else
        FEditor.BrushKey := 1;
    end else
    if (Cmd = 'lift') and (Words.Count > 1) then
      FEditor.BrushLift := Max(32, StrToIntDef(Words[1], 96))
    else
    if (Cmd = 'fill') and (Words.Count > 4) then
      FEditor.FillRect(StrToIntDef(Words[1], 0), StrToIntDef(Words[2], 0), StrToIntDef(Words[3], 0),
        StrToIntDef(Words[4], 0))
    else
    if (Cmd = 'brush') and (Words.Count > 3) then
    begin
      FEditor.BrushFloor := StrToIntDef(Words[1], 0);
      FEditor.BrushCeil := StrToIntDef(Words[2], 160);
      FEditor.BrushTheme := EnsureRange(StrToIntDef(Words[3], 0), 0, High(LevelThemes));
    end else
      Console.Print('editor [new|generate [seed]|save [name]|load <name>|play|export|close|name <n>|tool <t>|entity <class>|brush <floor> <ceil> <theme>|channel <0-9>|lift <height>|key <blue|red>|fill <x0> <y0> <x1> <y1>]');
  finally
    Words.Free;
  end;
end;

procedure TViewPlay.TouchMenu(Sender: TObject);
begin
  Menu.Exists := True;
  WalkNavigation.MouseLook := False;
end;

procedure TViewPlay.Start;
begin
  inherited Start;

  { Touch screens get on-screen controls in front of everything but the
    menu and console }
  if TouchControlsWanted then
  begin
    FTouch := TQuakeTouchControls.Create(FreeAtStop);
    FTouch.OnUse := @TouchUse;
    FTouch.OnNextWeapon := @TouchNextWeapon;
    FTouch.OnMenu := @TouchMenu;
    InsertFront(FTouch);
    Menu.Parent.InsertFront(Menu);
    Console.Parent.InsertFront(Console);
  end else
    FTouch := nil;

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
  { Screenshots must not depend on random idle pauses of the view weapon }
  FWorld.Gun.RandomPauses := FAutoTestMap = '';
  Particles.SetParent(MainViewport.Items);
  Particles.Camera := MainViewport.Camera;
  Console.OnCommand := @HandleConsoleCommand;
  Menu.OnMenuAction := @HandleMenuAction;
  SetCameraMode(FCameraMode);
  ApplySettings;

  if FMapReportFile <> '' then
  begin
    RunMapReport;
    QuitNow;
  end else
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
    { The title menu's Level Editor }
    if OpenEditorOnStart then
    begin
      OpenEditorOnStart := False;
      OpenEditor;
    end;
  end;
end;

procedure TViewPlay.Stop;
begin
  if FRecorder <> nil then
    StopRecording;
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
  Pad: TGamepadInput;
  Look: TVector2;
begin
  Typing := Console.IsOpen or Menu.Exists or FIntermission or FWorld.Dead or EditorOpen;
  FGamepadFire := False;
  PlayerMovement.InputYaw := 0;
  PlayerMovement.InputPitch := 0;
  PlayerMovement.InputForward := 0;
  PlayerMovement.InputSide := 0;
  PlayerMovement.InputJump := False;
  PlayerMovement.InputCrouch := False;
  if not Typing then
  begin
    { Bound keys (Options -> Controls); arrows always move too }
    if Container.Pressed[Settings.Keys[qaForward]] or Container.Pressed[keyArrowUp] then
      PlayerMovement.InputForward := PlayerMovement.InputForward + 1;
    if Container.Pressed[Settings.Keys[qaBack]] or Container.Pressed[keyArrowDown] then
      PlayerMovement.InputForward := PlayerMovement.InputForward - 1;
    if Container.Pressed[Settings.Keys[qaMoveRight]] then
      PlayerMovement.InputSide := PlayerMovement.InputSide + 1;
    if Container.Pressed[Settings.Keys[qaMoveLeft]] then
      PlayerMovement.InputSide := PlayerMovement.InputSide - 1;
    PlayerMovement.InputJump := Container.Pressed[Settings.Keys[qaJump]];
    PlayerMovement.InputCrouch := Container.Pressed[Settings.Keys[qaCrouch]];
    { Game controllers (sticks add to the keys) }
    Pad := ReadGamepads(SecondsPassed, Settings.MouseSensitivity, Settings.InvertMouse);
    if Pad.Connected then
    begin
      PlayerMovement.InputForward := EnsureRange(PlayerMovement.InputForward + Pad.Forward, -1, 1);
      PlayerMovement.InputSide := EnsureRange(PlayerMovement.InputSide + Pad.Side, -1, 1);
      PlayerMovement.InputYaw := Pad.YawDeg;
      PlayerMovement.InputPitch := Pad.PitchDeg;
      PlayerMovement.InputJump := PlayerMovement.InputJump or Pad.Jump;
      PlayerMovement.InputCrouch := PlayerMovement.InputCrouch or Pad.Crouch;
      FGamepadFire := Pad.Fire;
    end;
    { Touch: left stick moves, dragging on the right looks }
    if FTouch <> nil then
    begin
      FTouch.Exists := True;
      Look := FTouch.TakeLook * FTouch.LookDegreesPerPixel * Settings.MouseSensitivity;
      PlayerMovement.InputForward := EnsureRange(PlayerMovement.InputForward + FTouch.Stick.Y, -1, 1);
      PlayerMovement.InputSide := EnsureRange(PlayerMovement.InputSide + FTouch.Stick.X, -1, 1);
      PlayerMovement.InputYaw := PlayerMovement.InputYaw - Look.X;
      if Settings.InvertMouse then
        PlayerMovement.InputPitch := PlayerMovement.InputPitch - Look.Y
      else
        PlayerMovement.InputPitch := PlayerMovement.InputPitch + Look.Y;
      PlayerMovement.InputJump := PlayerMovement.InputJump or FTouch.Held(tbJump);
      PlayerMovement.InputCrouch := PlayerMovement.InputCrouch or FTouch.Held(tbCrouch);
      FGamepadFire := FGamepadFire or FTouch.Held(tbFire);
    end;
  end else
  if FTouch <> nil then
  begin
    { Hidden under menus, the console, intermission and death }
    FTouch.Exists := False;
    FTouch.ResetTouches;
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
  if FDemoInJump then
    PlayerMovement.InputJump := True;
  if FDemoInCrouch then
    PlayerMovement.InputCrouch := True;
  PlayerMovement.Suspended := FWorld.Dead or FIntermission;
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
var
  LevelName: String;
begin
  { "random" (the menus' Random Level): a new random level }
  LevelName := AMapName;
  if LevelName = RandomGameMap then
    LevelName := RandomMapName(1 + Random(999999));
  WritelnLog('GameViewPlay', 'Loading level "%s"', [LevelName]);
  if FWorld.LoadMap(LevelName) then
  begin
    FMapName := FWorld.Bsp.MapName;
    PlaceCamera(FWorld.SpawnPoint, FWorld.SpawnAngle);
    Hud.ShowMessage(FMapName, 3.0);
  end else
    Hud.ShowMessage('Failed to load level: ' + LevelName, 5.0);
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
    WritelnLog('GameViewPlay', 'Saved screenshot to "%s" (%.1f FPS, camera %s, PVS cluster %d, area %d, %d / %d world regions, %d / %d entities, %d loop sounds)',
      [OutPath, Container.Fps.RealFps, MainViewport.Camera.Translation.ToString,
       FWorld.Geometry.VisCluster, FWorld.Geometry.VisArea,
       FWorld.Geometry.VisibleRegionCount, FWorld.Geometry.VisRegionCount,
       FWorld.VisibleEntities, FWorld.VisibleEntities + FWorld.CulledEntities,
       Sounds.PlayingLoopCount]);
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewPlay.RunMapReport;
var
  Report: TMapReport;
  Maps: TStringList;
  I: Integer;
  ReportMap: String;
  StartTime: QWord;
  Entry: TMapReportEntry;
  MapLoaded: Boolean;
begin
  Report := TMapReport.Create;
  Maps := Pak.FindFiles('maps/', '.bsp');
  try
    Maps.Sort;
    for I := 0 to Maps.Count - 1 do
    begin
      ReportMap := ChangeFileExt(ExtractFileName(Maps[I]), '');
      StartTime := GetTickCount64;
      try
        { "*" starts a new unit: no state remembered from the previous map }
        MapLoaded := FWorld.LoadMap('*' + ReportMap);
      except
        on E: Exception do
        begin
          WritelnWarning('MapReport', 'Map %s failed: %s', [ReportMap, E.Message]);
          MapLoaded := False;
        end;
      end;
      if MapLoaded and (FWorld.Bsp <> nil) then
      begin
        Entry := Default(TMapReportEntry);
        Entry.MapName := ReportMap;
        Entry.Loaded := True;
        Entry.LoadSeconds := (GetTickCount64 - StartTime) / 1000;
        Entry.Monsters := FWorld.Monsters.Count;
        Entry.Items := FWorld.Pickups.Count;
        Report.AddMap(Entry, FWorld.Bsp);
      end else
        Report.AddFailedMap(ReportMap);
    end;
    Report.SaveMarkdown(FMapReportFile, Pak.PakList);
    WritelnLog('MapReport', 'Wrote "%s": %d maps, %d entities of unsupported classes',
      [FMapReportFile, Report.MapCount, Report.UnsupportedCount]);
  finally
    Maps.Free;
    Report.Free;
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
  FDemoClock := 0;
  { Commas, or one command per line (recorded scripts) }
  for Cmd in Script.Split([',', #10, #13]) do
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
  Key, K: TKey;
  SolidCount: Integer;
  Vals: TStringArray;
  Button: TGameControllerButton;
  PadEvent: TInputPressRelease;
  Target2: TVector2;
  Target2Q: TVector3;
  Input: TDemoInput;
  NextInput: TDemoInput;
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
  { Actions that move or turn the camera work on the view without bob / kicks }
  if (Action = 'T') or (Action = 'A') or (Action = 'P') or (Action = 'M') or (Action = 'N') or
     (Action = 'I') or (Action = 'D') or (Action = 'R') or (Action = 'G') or (Action = 'IN') then
    PlayerMovement.ClearViewEffects;

  if Action = 'IN' then { Recorded view and inputs: "IN:time yaw pitch forward side buttons" }
  begin
    if not ParseDemoInput(Param, Input) then
    begin
      WritelnWarning('Demo', 'Bad IN command "%s"', [Cmd]);
      Inc(FDemoIndex);
      Exit;
    end;
    if FDemoClock < Input.Time then
      Exit;
    { Behind (slow frames): skip to the last IN that is due }
    while (FDemoIndex + 1 < FDemoCommands.Count) and
      (UpperCase(Copy(FDemoCommands[FDemoIndex + 1], 1, 3)) = 'IN:') and
      ParseDemoInput(Copy(FDemoCommands[FDemoIndex + 1], 4, MaxInt), NextInput) and
      (NextInput.Time <= FDemoClock) do
    begin
      { Taps (a jump, a shot) shorter than this frame still happen once }
      if (Input.Buttons and InButtonJump) <> 0 then
        FDemoJump := True;
      if (Input.Buttons and InButtonFire) <> 0 then
        FWorld.FireWeapon(PlayerMovement.AimPosition, PlayerMovement.AimDirection);
      Input := NextInput;
      Inc(FDemoIndex);
    end;
    SetLook(Input.Yaw, Input.Pitch);
    if Input.HasOrigin then
    begin
      Val := PointsDistance(Input.Origin, CgeToQuake(MainViewport.Camera.Translation));
      FDemoMaxDrift := Max(FDemoMaxDrift, Val);
      if Val > 16 then
        WritelnLog('Demo', 'Replay drift %.1f units at %.2f s', [Val, Input.Time]);
      { Frame timing differs from the recording: put the player back on its
        path (a few units are normal, more is a different outcome) }
      if (Val > 2) and not FDemoNoSync then
      begin
        Dir := MainViewport.Camera.Translation;
        MainViewport.Camera.Translation := QuakeToCge(Input.Origin);
        { Not into a wall (when the map changed since the recording) }
        if Assigned(EntityTrace) and EntityTrace(PlayerMovement.Origin, PlayerMovement.Origin,
           PlayerMovement.BoxMins, PlayerMovement.BoxMaxs, MASK_PLAYERSOLID, PlayerMovement).StartSolid then
          MainViewport.Camera.Translation := Dir;
      end;
    end;
    FDemoMoveForward := Input.Forward;
    FDemoMoveSide := Input.Side;
    { Held until the next IN }
    FDemoMoveTime := Iff((Input.Forward <> 0) or (Input.Side <> 0), 1e6, 0);
    FDemoInFire := (Input.Buttons and InButtonFire) <> 0;
    FDemoInJump := (Input.Buttons and InButtonJump) <> 0;
    FDemoInCrouch := (Input.Buttons and InButtonCrouch) <> 0;
    Inc(FDemoIndex);
    Exit;
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
  begin
    RecordCommand('X');
    FWorld.FireWeapon(PlayerMovement.AimPosition, PlayerMovement.AimDirection);
  end
  else
  if Action = 'H' then { Hold / release fire }
    FDemoFireHeld := not FDemoFireHeld
  else
  if Action = 'U' then
    DoUse
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
  if Action = 'B' then { Press and release a key, e.g. "B:escape" (menu tests) }
  begin
    Key := keyNone;
    for K := Low(TKey) to High(TKey) do
      if (K <> keyNone) and SameText(KeyToStr(K), Param) then
      begin
        Key := K;
        Break;
      end;
    if Key <> keyNone then
    begin
      Container.EventPress(InputKey(TVector2.Zero, Key, '', []));
      Container.EventRelease(InputKey(TVector2.Zero, Key, '', []));
    end else
      WritelnWarning('Demo', 'Unknown key "%s"', [Param]);
  end else
  if Action = 'GP' then { Virtual gamepad: "GP:lx ly rx ry lt rt" (sticks -1..1, triggers 0..1), "GP:" off }
  begin
    Vals := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    VirtualGamepad := Default(TVirtualGamepad);
    VirtualGamepad.Active := Length(Vals) > 0;
    for J := 0 to Min(High(Vals), 5) do
      case J of
        0: VirtualGamepad.Left.X := StrToFloatDef(Vals[J], 0);
        1: VirtualGamepad.Left.Y := StrToFloatDef(Vals[J], 0);
        2: VirtualGamepad.Right.X := StrToFloatDef(Vals[J], 0);
        3: VirtualGamepad.Right.Y := StrToFloatDef(Vals[J], 0);
        4: VirtualGamepad.LeftTrigger := StrToFloatDef(Vals[J], 0);
        5: VirtualGamepad.RightTrigger := StrToFloatDef(Vals[J], 0);
      end;
  end else
  if (Action = 'TD') or (Action = 'TM') or (Action = 'TU') then
  begin
    { Touch: "TD:x y finger" down, "TM:x y finger" move (x, y as fractions
      of the window, from the bottom left), "TU:finger" up }
    Vals := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Action = 'TU' then
    begin
      J := StrToIntDef(Param, 0);
      if (J >= 0) and (J <= High(FTouchPos)) then
        Container.EventRelease(InputMouseButton(FTouchPos[J], buttonLeft, J, []));
    end else
    if Length(Vals) >= 2 then
    begin
      J := 0;
      if Length(Vals) >= 3 then
        J := EnsureRange(StrToIntDef(Vals[2], 0), 0, High(FTouchPos));
      Target2 := Vector2(StrToFloatDef(Vals[0], 0) * Container.Width, StrToFloatDef(Vals[1], 0) * Container.Height);
      if Action = 'TD' then
        Container.EventPress(InputMouseButton(Target2, buttonLeft, J, []))
      else
        Container.EventMotion(InputMotion(FTouchPos[J], Target2, [buttonLeft], J));
      FTouchPos[J] := Target2;
    end;
  end else
  if Action = 'MV' then { Place monster i at Quake coordinates: "MV:i x y z" }
  begin
    Vals := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Vals) >= 4 then
    begin
      J := StrToIntDef(Vals[0], -1);
      if (J >= 0) and (J < FWorld.Monsters.Count) then
      begin
        FWorld.Monsters[J].Transform.Translation := QuakeToCge(Vector3(StrToFloatDef(Vals[1], 0),
          StrToFloatDef(Vals[2], 0), StrToFloatDef(Vals[3], 0)));
        FWatchedMonster := J;
      end;
    end;
  end else
  if Action = 'GB' then { Press and release a gamepad button, e.g. "GB:south" }
  begin
    if GamepadButtonFromName(Param, Button) then
    begin
      PadEvent := Default(TInputPressRelease);
      PadEvent.EventType := itGameController;
      PadEvent.Controller.Button := Button;
      Container.EventPress(PadEvent);
      Container.EventRelease(PadEvent);
    end else
      WritelnWarning('Demo', 'Unknown gamepad button "%s"', [Param]);
  end else
  if Action = 'SY' then { Correct the drift of recorded IN positions: SY:1 (default) / SY:0 }
    FDemoNoSync := Param = '0'
  else
  if Action = 'J' then { Jump }
    FDemoJump := True
  else
  if Action = 'M' then { Move along camera direction, with collisions }
  begin
    Val := StrToFloatDef(Param, 50.0);
    Dir := MainViewport.Camera.Direction;
    Dir.Y := 0;
    if (Dir.Length > 0) and Assigned(EntityTrace) then
    begin
      { Swept like the player's box: stops at walls instead of passing them }
      Target := PlayerMovement.Origin;
      Target2Q := EntityTrace(Target, Target + CgeToQuake(Dir.Normalize * Val), PlayerMovement.BoxMins,
        PlayerMovement.BoxMaxs, MASK_PLAYERSOLID, PlayerMovement).EndPos;
      PlayerMovement.Push(QuakeToCge(Target2Q) - QuakeToCge(Target));
    end else
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
    { The probes above use render meshes; settle the player box in free space }
    PlayerMovement.SnapToFreeSpace;
  end else
  if Action = 'F' then { Toggle the help computer (F1) }
    DoToggleHelp
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
    WritelnLog('Demo', 'Player at %s (view offset %s, pitch %.1f roll %.1f, gun %s) ladder %s water level %d on ground %s velocity %s health %d', [
      PlayerMovement.AimPosition.ToString, (MainViewport.Camera.Translation - PlayerMovement.AimPosition).ToString,
      PlayerMovement.ViewKickPitch, PlayerMovement.ViewKickRoll,
      PlayerMovement.GunAngles.ToString, BoolToStr(PlayerMovement.OnLadder, True), PlayerMovement.WaterLevel,
      BoolToStr(PlayerMovement.OnGround, True), PlayerMovement.Velocity.ToString,
      FWorld.Stats.Health]);
    for J := 0 to FWorld.Geometry.Movers.Count - 1 do
      WritelnLog('Demo', 'Mover %d %s %s tex frame %d state %d progress %.2f exists %s', [J,
        FWorld.Geometry.Movers[J].Entity.ClassName, FWorld.Geometry.Movers[J].Entity.Model,
        FWorld.Geometry.ModelTexFrame(FWorld.Geometry.Movers[J].ModelIndex), Ord(FWorld.Geometry.Movers[J].State),
        FWorld.Geometry.Movers[J].Progress, BoolToStr(FWorld.Geometry.Movers[J].Transform.Exists, True)]);
    WritelnLog('Demo', 'Sound mixer: %d playing, load %.2f, limiter %.2f', [Sounds.ActiveSoundCount,
      Sounds.MixLoad, Sounds.LimiterGain]);
    for J := 0 to FWorld.Turrets.Count - 1 do
      WritelnLog('Demo', 'Turret %d pitch %.1f yaw %.1f aim %.1f %.1f bases %d driver %s shots %d', [J,
        FWorld.Turrets[J].Breach.TurretPitch, FWorld.Turrets[J].Breach.TurretYaw,
        FWorld.Turrets[J].MovePitch, FWorld.Turrets[J].MoveYaw, Length(FWorld.Turrets[J].Bases),
        BoolToStr(FWorld.Turrets[J].Driver <> nil, True), FWorld.Turrets[J].Shots]);
    for J := 0 to FWorld.Props.Count - 1 do
      WritelnLog('Demo', 'Prop %d %s health %d destroyed %s flying %s exists %s', [J,
        FWorld.Props[J].Entity.ClassName, FWorld.Props[J].Health,
        BoolToStr(FWorld.Props[J].Destroyed, True), BoolToStr(FWorld.Props[J].Flying, True),
        BoolToStr(FWorld.Props[J].Transform.Exists, True)]);
    for J := 0 to FWorld.Monsters.Count - 1 do
      if (J = FWatchedMonster) or FWorld.Monsters[J].IsAlive and (FWorld.Monsters[J].Alerted or
         (FWorld.Monsters[J].MoveTarget <> nil) or (FWorld.Monsters[J].GoalEntity <> nil) or
         (FWorld.Monsters[J].CombatTarget <> '')) then
        WritelnLog('Demo', 'Monster %d %s state %d dist %.0f pos %s alerted %s patrol %s combatpoint %s %s hold %s sees %s cooldown %.1f health %d', [J,
          FWorld.Monsters[J].Def^.ClassName, Ord(FWorld.Monsters[J].State),
          PointsDistance(FWorld.Monsters[J].Transform.Translation, MainViewport.Camera.Translation),
          CgeToQuake(FWorld.Monsters[J].Transform.Translation).ToString,
          BoolToStr(FWorld.Monsters[J].Alerted, True),
          BoolToStr(FWorld.Monsters[J].MoveTarget <> nil, True),
          BoolToStr(FWorld.Monsters[J].GoalEntity <> nil, True), FWorld.Monsters[J].CombatTarget,
          BoolToStr(FWorld.Monsters[J].HoldGround, True), BoolToStr(FWorld.Monsters[J].CanSeePlayer, True),
          FWorld.Monsters[J].AttackCooldown, FWorld.Monsters[J].Health]);
    P := 0;
    SolidCount := 0;
    Val := 0;
    for J := 0 to FWorld.Monsters.Count - 1 do
      if FWorld.Monsters[J].IsAlive and not FWorld.Monsters[J].Dormant then
      begin
        Val := Val + 1;
        if FWorld.Monsters[J].Alerted then
          Inc(P);
        if Assigned(EntityTrace) and EntityTrace(FWorld.Monsters[J].Origin, FWorld.Monsters[J].Origin,
           FWorld.Monsters[J].BoxMins, FWorld.Monsters[J].BoxMaxs, MASK_MONSTERSOLID,
           FWorld.Monsters[J]).StartSolid then
          Inc(SolidCount);
      end;
    WritelnLog('Demo', 'Monsters: %d alerted of %d alive, %d in solid', [P, Round(Val), SolidCount]);
    for J := 0 to FWorld.Monsters.Count - 1 do
      if FWorld.Monsters[J].Alerted and FWorld.Monsters[J].IsAlive then
        WritelnLog('Demo', 'Hunting monster %d sees player %s dist %.0f', [J,
          BoolToStr(FWorld.Monsters[J].CanSeePlayer, True),
          PointsDistance(FWorld.Monsters[J].Transform.Translation, PlayerMovement.AimPosition)]);
    WritelnLog('Demo', 'Projectiles: %d, delayed targets: %d, earthquakes: %d, player gravity %.2f, gibs: %d',
      [FWorld.ProjectileCount, FWorld.DelayedCount, FWorld.EarthquakeCount, FWorld.PlayerGravity, Particles.GibCount]);
    WritelnLog('Demo', 'String: "%s"', [FWorld.LastString]);
    WritelnLog('Demo', 'Monster shots: %d, player health %d armor %d, player stuck %d', [FWorld.MonsterShots,
      FWorld.Stats.Health, FWorld.Stats.Armor, PlayerMovement.StuckCount]);
    WritelnLog('Demo', 'Replay drift: max %.1f units', [FDemoMaxDrift]);
    WritelnLog('Demo', 'Gun: weapon %d state %d frame %d, ammo shells %d bullets %d grenades %d cells %d slugs %d', [
      FWorld.Gun.Slot, Ord(FWorld.Gun.State), FWorld.Gun.Frame, FWorld.Stats.Ammo[atShells],
      FWorld.Stats.Ammo[atBullets], FWorld.Stats.Ammo[atGrenades], FWorld.Stats.Ammo[atCells],
      FWorld.Stats.Ammo[atSlugs]]);
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
    PlayerMovement.SnapToFreeSpace;
  end else
  if Action = 'C' then
    DoSelectWeapon(StrToIntDef(Param, 2))
  else
  if Action = 'K' then
    FWorld.CheatGiveAll
  else
  if Action = 'Y' then
    FWorld.CheatGodMode
  else
  if Action = 'L' then { Load map; IN times count from here }
  begin
    LoadLevel(Param);
    FDemoClock := 0;
  end
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
  { Render meshes outside the PVS are hidden and missed by the probes above:
    try again with Quake traces (brushes and movers, any culling) }
  if GoNearByTraces(Target) then
    Exit;
  WritelnWarning('GameViewPlay', 'GoNear %s: no free spot found', [Target.ToString]);
end;

function TViewPlay.GoNearByTraces(const Target: TVector3): Boolean;
const
  BoxMins: TVector3 = (X: -16; Y: -16; Z: -24);
  BoxMaxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  J, Dist: Integer;
  T, Spot, Eye: TVector3;
  Tr: TQuakeTrace;
begin
  T := CgeToQuake(Target);
  for Dist in [160, 110, 220, 70] do
    for J := 0 to 7 do
    begin
      Spot := T + Vector3(Cos(J * Pi / 4), Sin(J * Pi / 4), 0) * Dist;
      { A free spot, in sight of the target (up to 48 units: a door's face) }
      Tr := FWorld.WorldTrace(Spot, Spot, BoxMins, BoxMaxs, MASK_PLAYERSOLID, nil);
      if Tr.StartSolid then
        Continue;
      Tr := FWorld.WorldTrace(Spot, T, TVector3.Zero, TVector3.Zero, CONTENTS_SOLID or CONTENTS_WINDOW, nil);
      if Tr.StartSolid or (Tr.Fraction * Dist < Dist - 48) then
        Continue;
      { A floor less than 160 units below }
      Tr := FWorld.WorldTrace(Spot, Spot - Vector3(0, 0, 160), BoxMins, BoxMaxs, MASK_PLAYERSOLID, nil);
      if Tr.StartSolid or (Tr.Fraction >= 1) or (Tr.Normal.Z < 0.7) then
        Continue;
      Eye := QuakeToCge(Tr.EndPos) + Vector3(0, PlayerEyeHeight - 24, 0);
      MainViewport.Camera.SetWorldView(Eye, (Target - Eye).Normalize, Vector3(0, 1, 0));
      WritelnLog('GameViewPlay', 'GoNear %s -> %s (traces)', [Target.ToString, Eye.ToString]);
      Exit(True);
    end;
  Result := False;
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
    Obj.Add('camera', TJSONArray.Create([PlayerMovement.AimPosition.X,
      PlayerMovement.AimPosition.Y, PlayerMovement.AimPosition.Z]));
    Obj.Add('direction', TJSONArray.Create([PlayerMovement.AimDirection.X,
      PlayerMovement.AimDirection.Y, PlayerMovement.AimDirection.Z]));
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
    { Entities are matched by spawn order, which depends on the skill }
    GameSkill := EnsureRange(Obj.Get('skill', GameSkill), 0, 3);
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
      DoSelectWeapon(Slot);
      Exit;
    end;
  end;
end;

procedure TViewPlay.DoSelectWeapon(const Slot: Integer);
begin
  RecordCommand('C:' + IntToStr(Slot));
  FWorld.SelectWeapon(Slot);
end;

procedure TViewPlay.DoUse;
begin
  RecordCommand('U');
  FWorld.ActivateUse(PlayerMovement.AimPosition, PlayerMovement.AimDirection);
end;

procedure TViewPlay.DoToggleHelp;
begin
  RecordCommand('F');
  Hud.HelpVisible := not Hud.HelpVisible;
  Sounds.Play('sound/misc/pc_up.wav');
end;

procedure TViewPlay.SetLook(const YawDeg, PitchDeg: Single);
var
  Dir: TVector3;
begin
  PlayerMovement.ClearViewEffects;
  Dir := YawToCgeDir(YawDeg) * Cos(DegToRad(PitchDeg)) + Vector3(0, -Sin(DegToRad(PitchDeg)), 0);
  MainViewport.Camera.SetWorldView(MainViewport.Camera.Translation, Dir.Normalize, Vector3(0, 1, 0));
end;

function RecordingUrl(const AName: String): String;
begin
  Result := 'castle-config:/recordings/' + LowerCase(AName) + '.txt';
end;

procedure TViewPlay.StartRecording(const AName: String);
begin
  if FRecorder <> nil then
    StopRecording;
  { Start like the autotest that replays it: a new unit, a new player }
  FWorld.ResetStats;
  LoadLevel('*' + FMapName);
  if FWorld.Bsp = nil then
    Exit;
  FRecorder := TQuakeRecorder.Create(FMapName);
  FRecordClock := 0;
  FRecordName := AName;
  { Autotests start on skill 1 }
  if GameSkill <> 1 then
  begin
    FRecorder.AddCommand('O:skill ' + IntToStr(GameSkill));
    FRecorder.AddCommand('L:' + FMapName);
  end;
  if NoTarget then
    FRecorder.AddCommand('O:notarget');
  Console.Print('Recording "' + AName + '" on ' + FMapName + ', "stop" to save');
  Hud.ShowMessage('Recording ' + AName, 2);
  WritelnLog('Record', 'Recording "%s" on %s', [AName, FMapName]);
end;

procedure TViewPlay.StopRecording;
var
  Url, FileName, Line: String;
  Stream: TStream;
  Text: String;
  Recorder: TQuakeRecorder;
begin
  Recorder := FRecorder;
  FRecorder := nil;
  try
    Recorder.Finish(FRecordClock);
    Text := Recorder.Lines.Text;
    Url := RecordingUrl(FRecordName);
    try
      Stream := UrlSaveStream(Url);
      try
        if Text <> '' then
          Stream.WriteBuffer(Text[1], Length(Text));
      finally
        Stream.Free;
      end;
      FileName := UriToFilenameSafe(Url);
      if FileName = '' then
        FileName := Url;
      Line := Format('castle-quake2 --autotest %s %s --demo @%s', [Recorder.MapName, FRecordName, FileName]);
      Console.Print(Format('Saved %d commands (%.1f s) to %s', [Recorder.Lines.Count, FRecordClock, FileName]));
      Console.Print('Replay: ' + Line);
      Hud.ShowMessage('Recording saved: ' + FRecordName, 2);
      WritelnLog('Record', 'Saved %d commands (%.1f s) to "%s". Replay: %s',
        [Recorder.Lines.Count, FRecordClock, FileName, Line]);
    except
      on E: Exception do
        Console.Print('Saving the recording failed: ' + E.Message);
    end;
  finally
    Recorder.Free;
  end;
end;

procedure TViewPlay.RecordCommand(const Cmd: String);
begin
  if FRecorder = nil then
    Exit;
  { An IN with the inputs held so far times the command }
  FRecorder.AddTimedCommand(FRecordClock, Cmd);
end;

procedure TViewPlay.SampleRecording(const Firing: Boolean);
var
  Input: TDemoInput;
  Dir: TVector3;
begin
  Dir := PlayerMovement.AimDirection;
  Input.Time := FRecordClock;
  Input.Yaw := RadToDeg(ArcTan2(-Dir.Z, Dir.X));
  Input.Pitch := -RadToDeg(ArcSin(EnsureRange(Dir.Y / Max(Dir.Length, 1e-6), -1, 1)));
  Input.Forward := PlayerMovement.InputForward;
  Input.Side := PlayerMovement.InputSide;
  Input.HasOrigin := True;
  Input.Origin := CgeToQuake(PlayerMovement.AimPosition);
  Input.Buttons := 0;
  if Firing then
    Input.Buttons := Input.Buttons or InButtonFire;
  if PlayerMovement.InputJump then
    Input.Buttons := Input.Buttons or InButtonJump;
  if PlayerMovement.InputCrouch then
    Input.Buttons := Input.Buttons or InButtonCrouch;
  FRecorder.Sample(Input);
end;

procedure TViewPlay.UpdateDeathView(const SecondsPassed: Single);
const
  DropTime = 0.3;
var
  Killer, Dir, Up, Pos: TVector3;
  T, Drop: Single;
begin
  if not FWorld.Dead then
  begin
    FDeathTime := -1;
    Exit;
  end;
  if FDeathTime < 0 then
  begin
    PlayerMovement.ClearViewEffects;
    FDeathTime := 0;
    FDeathFrom := MainViewport.Camera.Translation;
    { LookAtKiller: face where the killing blow came from }
    FDeathYawDir := MainViewport.Camera.Direction;
    if FWorld.KillerPosition(Killer) then
      FDeathYawDir := Killer - FDeathFrom;
    FDeathYawDir.Y := 0;
    if FDeathYawDir.IsZero then
      FDeathYawDir := Vector3(1, 0, 0);
    FDeathYawDir := FDeathYawDir.Normalize;
  end;
  FDeathTime := FDeathTime + SecondsPassed;
  T := Min(1, FDeathTime / DropTime);
  { The eye goes from origin + 22 to origin + 8 (PM_DEAD); a gibbed
    player's head lies on the floor (PM_GIB: eye at floor + 8) }
  if FWorld.PlayerGibbed then
    Drop := (PlayerEyeHeight - 24) + 24 - 8
  else
    Drop := (PlayerEyeHeight - 24) - 8;
  Pos := FDeathFrom - Vector3(0, Drop * T, 0);
  { Dead view angles: pitch -15 (a bit up), roll 40 }
  Dir := FDeathYawDir * Cos(DegToRad(15 * T)) + Vector3(0, Sin(DegToRad(15 * T)), 0);
  Up := RotatePointAroundAxisRad(DegToRad(40 * T), Vector3(0, 1, 0), Dir.Normalize);
  MainViewport.Camera.SetWorldView(Pos, Dir.Normalize, Up);
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Firing: Boolean;
begin
  inherited Update(SecondsPassed, HandleInput);

  if FDemoCommands.Count > 0 then
  begin
    FDemoClock := FDemoClock + SecondsPassed;
    RunDemoStep(SecondsPassed);
  end;
  if FRecorder <> nil then
    FRecordClock := FRecordClock + SecondsPassed;

  if FWorld = nil then
    Exit;

  if LabelFps.Exists then
    LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  { The level editor covers the game: the world waits }
  if EditorOpen then
    Exit;

  { Intermission: world frozen until a key press (or 8 seconds) }
  if FIntermission then
  begin
    FIntermissionTime := FIntermissionTime + SecondsPassed;
    if FIntermissionTime > 8 then
      EndIntermission;
    Exit;
  end;

  UpdateMovementInput(SecondsPassed);
  FWorld.Update(SecondsPassed, PlayerMovement.AimPosition, PlayerMovement.AimDirection);
  FWorld.SetGunAngles(PlayerMovement.GunAngles);
  FWorld.Geometry.UpdateVisibility(CgeToQuake(MainViewport.Camera.Translation));
  FWorld.CullEntities;
  Sounds.ListenerRight := TVector3.CrossProduct(MainViewport.Camera.Direction, MainViewport.Camera.Up).Normalize;
  FWorld.UpdateLoopSounds(MainViewport.Camera.Translation);
  Sounds.UpdateMixer(SecondsPassed, Settings.SoundVolume / 100);
  WalkNavigation.Exists := not FWorld.Dead;
  UpdateDeathView(SecondsPassed);

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
  Firing := FDemoFireHeld or FDemoInFire;
  if not Console.IsOpen and not Menu.Exists then
    { With touch controls every touch is a "left button": fire only by FIRE }
    Firing := Firing or Container.Pressed[Settings.Keys[qaFire]] or
      ((FTouch = nil) and (buttonLeft in Container.MousePressed)) or FGamepadFire;
  if Firing then
    FWorld.FireWeapon(PlayerMovement.AimPosition, PlayerMovement.AimDirection);
  if FRecorder <> nil then
    SampleRecording(Firing);
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
const
  WeaponKeys: array[1..10] of TKey = (key1, key2, key3, key4, key5, key6, key7, key8, key9, key0);
var
  Slot: Integer;
  MenuEvent: TInputPressRelease;
begin
  Result := False;

  if FIntermission then
  begin
    if FIntermissionTime > 1 then
    begin
      RecordCommand('B:enter');
      EndIntermission;
    end;
    Exit(True);
  end;

  if Console.IsOpen then
    Exit(Console.Press(Event));

  if EditorOpen then
  begin
    if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
    begin
      Console.Toggle;
      Exit(True);
    end;
    Exit(FEditor.Press(Event));
  end;

  if Menu.Exists then
  begin
    { The menu uses Escape to go back from a page or cancel a key binding }
    { Game controller buttons act as the menu keys }
    MenuEvent := GamepadMenuEvent(Event);
    if Menu.Press(MenuEvent) then
      Exit(True);
    if MenuEvent.IsKey(keyEscape) then
    begin
      Menu.Exists := False;
      WalkNavigation.MouseLook := WantMouseLook;
      Exit(True);
    end;
    Exit(False);
  end;

  if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
  begin
    Console.Toggle;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) or Event.IsController(gbMenu) then
  begin
    Menu.Exists := True;
    WalkNavigation.MouseLook := False;
    Exit(True);
  end;

  if Event.EventType = itGameController then
  begin
    if GamepadWeaponCycle(Event.Controller.Button) <> 0 then
    begin
      CycleWeapon(GamepadWeaponCycle(Event.Controller.Button));
      Exit(True);
    end;
    case Event.Controller.Button of
      gbWest: DoUse;
      gbNorth: DoSelectWeapon(11); { hand grenades }
      gbView: DoToggleHelp;
      else Exit(False);
    end;
    Exit(True);
  end;

  if Event.IsKey(Settings.Keys[qaUse]) then
  begin
    DoUse;
    Exit(True);
  end;

  for Slot := 1 to 10 do
    if Event.IsKey(WeaponKeys[Slot]) then
    begin
      DoSelectWeapon(Slot);
      Exit(True);
    end;
  if Event.IsKey(Settings.Keys[qaGrenade]) then
  begin
    DoSelectWeapon(11); { hand grenades }
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

  if Event.IsKey(Settings.Keys[qaHelp]) then
  begin
    { Quake 2 help computer }
    DoToggleHelp;
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

{ Words of a console line; "double quotes" keep spaces }

procedure TViewPlay.SpawnFromConsole(const Args: String);
var
  Words: TStringList;
  Ent: TQuakeEntity;
  I: Integer;
  Org: TVector3;
begin
  Words := SplitArgs(Args);
  try
    if (Words.Count = 0) or (FWorld.Bsp = nil) then
    begin
      Console.Print('Usage: spawn <classname> [key value]...  e.g. spawn target_earthquake targetname q count 2');
      Exit;
    end;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Words[0]);
    { 96 units in front of the player, at foot level, unless "origin" is given }
    Org := CgeToQuake(PlayerMovement.AimPosition) +
      CgeToQuake(Vector3(PlayerMovement.AimDirection.X, 0, PlayerMovement.AimDirection.Z).Normalize * 96);
    Org.Z := PlayerMovement.Origin.Z;
    Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
    I := 1;
    while I + 1 < Words.Count do
    begin
      Ent.SetField(Words[I], Words[I + 1]);
      Inc(I, 2);
    end;
    FWorld.Bsp.Entities.Add(Ent);
    FWorld.SpawnEntity(Ent);
    Console.Print(Format('Spawned %s at %s', [Ent.ClassName, Ent.GetField('origin')]));
    WritelnLog('Console', 'Spawned %s at %s', [Ent.ClassName, Ent.GetField('origin')]);
  finally
    Words.Free;
  end;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Maps: TStringList;
  P: Integer;
  Words: TStringList;
  Axis: TVector3;
begin
  { A recording replays the console commands typed while recording }
  if (FRecorder <> nil) and (Cmd <> 'record') and (Cmd <> 'stop') and (Cmd <> 'quit') and
     (Cmd <> 'exit') and (Cmd <> 'help') and (Cmd <> 'fps') and (Cmd <> 'maps') then
    RecordCommand('O:' + Trim(Cmd + ' ' + Args));

  if Cmd = 'spawn' then
    SpawnFromConsole(Args)
  else
  if Cmd = 'sky' then
  begin
    { sky <name> [rotate [axis x y z]], like Quake 2's sky console command }
    Words := SplitArgs(Args);
    try
      if Words.Count = 0 then
        Console.Print(Format('sky %s, rotate %.1f, axis %s',
          [QuakeMap.SkyName, QuakeMap.SkyRotate, QuakeMap.SkyAxis.ToString]))
      else
      begin
        Axis := TVector3.Zero;
        if Words.Count >= 5 then
          Axis := Vector3(StrToFloatDef(Words[2], 0), StrToFloatDef(Words[3], 0), StrToFloatDef(Words[4], 0));
        if Words.Count >= 2 then
          QuakeMap.SetSky(Words[0], StrToFloatDef(Words[1], 0), Axis)
        else
          QuakeMap.SetSky(Words[0], 0, Axis);
      end;
    finally
      Words.Free;
    end;
  end else
  if Cmd = 'record' then
  begin
    if Args <> '' then
      StartRecording(Args)
    else
      Console.Print('Usage: record <name>  (restarts the map; "stop" saves the script)');
  end else
  if Cmd = 'stop' then
  begin
    if FRecorder <> nil then
      StopRecording
    else
      Console.Print('Not recording');
  end else
  if (Cmd = 'map') or (Cmd = 'gamemap') then
  begin
    if Args <> '' then
      LoadLevel(Args)
    else
      Console.Print('Usage: map <mapname>');
  end else
  if Cmd = 'editor' then
    EditorCommand(Args)
  else
  if Cmd = 'randmap' then
  begin
    { A random level (QuakeLevelGen): the given seed, else a new one }
    if Args <> '' then
      LoadLevel(RandomMapName(StrToIntDef(Args, 1)))
    else
      LoadLevel(RandomMapName(1 + Random(999999)));
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
  if Cmd = 'novis' then
  begin
    FWorld.Geometry.NoVis := not FWorld.Geometry.NoVis;
    Hud.ShowMessage('novis ' + Iff(FWorld.Geometry.NoVis, 'ON', 'OFF'), 2);
  end else
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
  if Cmd = 'skill' then
  begin
    { Like Quake 2: takes effect when a map is (re)loaded }
    if Args <> '' then
      GameSkill := EnsureRange(StrToIntDef(Args, GameSkill), 0, 3);
    Console.Print(Format('skill %d (%s), applies to the next map', [GameSkill, SkillNames[GameSkill]]));
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
    FWorld.Suicide
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
    Console.Print('  spawn <class> [key value]... - Add an entity (e.g. spawn misc_viper)');
    Console.Print('  sky <name> [rotate [x y z]] - Change the sky (e.g. sky unit1_ 10 0 0 1)');
    Console.Print('  record <name> - Restart the map and record an autotest script');
    Console.Print('  stop         - Stop recording and save the script');
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
        WalkNavigation.MouseLook := WantMouseLook;
        LoadLevel(Param);
      end;
    maSettingsChanged:
      ApplySettings;
    maToggleCamera:
      if FCameraMode = cmFirstPerson then
        SetCameraMode(cmNoclip)
      else
        SetCameraMode(cmFirstPerson);
    maLevelEditor:
      OpenEditor;
    maQuit:
      Application.Terminate;
  end;
end;

end.
