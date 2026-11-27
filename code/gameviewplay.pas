{ Main 3D gameplay view for Castle Quake 2.
  Its components (viewport, camera, navigation, TQuakeMap, HUD, console, menu)
  are designed in data/gameviewplay.castle-user-interface ,
  so they can be inspected and tweaked in the CGE editor. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Generics.Collections,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils, CastleScene, CastleGLImages, CastleRectangles, CastleRenderContext,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeMd2,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu, QuakeMap, QuakeGamepad, QuakeTouch, QuakeExitWatchdog, QuakeBenchmark, CastleTimeUtils,
  X3DNodes, X3DFields, CastleRenderOptions,
  QuakePlayer, QuakeSettings, QuakeMapReport, QuakeRecord, QuakeLevel, QuakeLevelGen, QuakeLevelEditor, QuakeBspBuilder, QuakeTrace, QuakeTick, QuakeNet, QuakeServer, QuakeClient, QuakeClientScene, QuakePMove, QuakeBot, QuakeNetLink, fpjson, jsonparser, CastleDownload, CastleUriUtils;

type
  TCameraMode = (cmFirstPerson, cmNoclip);

  { A client without a view (tests, bots): its channel, client, a pmove for
    its prediction (no traces: the server moves it) and inputs held until
    changed, or decided every frame by its bot (addbot) }
  TTestClient = class
    Net: TNetLoopback;
    Client: TQuakeClient;
    PM: TQuakePMove;
    Server: TServerClient;
    Forward, Side, Yaw, Pitch: Single;
    Fire, Jump: Boolean;
    { Owned; nil for a test client driven by clientinput }
    Bot: TQuakeBot;
    destructor Destroy; override;
  end;

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
    FWaterWarp: TScreenEffectNode;
    FWaterWarpTime: TSFFloat;
    { The 3D view drawn below full resolution (RenderScale < 100) }
    FScaledView: TDrawableImage;
    { The fixed game tick, and the transforms it moves (drawn between ticks) }
    FTickClock: TQuakeTickClock;
    FTickList: TCastleTransformList;
    FWaterWarpClock: Single;
    { Quit on the next Update (the map report) }
    FQuitPending: Boolean;
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
    { E.1: the server (the simulation) and the client (this view) in one
      process, over a loopback channel }
    FNet: TNetLoopback;
    FServer: TQuakeServer;
    FClient: TQuakeClient;
    { The client's drawing of the snapshots' models (clientdraw) }
    FClientScene: TQuakeClientScene;
    { Test clients (addclient): more players on the server, each with a
      loopback channel and a client of its own, held inputs (clientinput) }
    FTestClients: specialize TObjectList<TTestClient>;
    { E.4: remote clients of this game over a packet link, or the link to
      the host this view joined (then the world is ClientOnly and doesn't
      tick: everything comes in snapshots) }
    FHostBridge: TNetHostBridge;
    FJoinBridge: TNetJoinBridge;
    { The host's server data messages acted on (a new one: its map) }
    FJoinServerData: Integer;
    FJoinLost: Boolean;
    { Take the host's view angles (a new map, a respawn, a teleport), once
      per snapshot; the health before (a respawn: from <= 0 to above) }
    FJoinAim: Boolean;
    FJoinAimFrame, FJoinLastHealth: Integer;
    { A tapped shot (X, a recorded tap) for the next command }
    FNetAttackTap: Boolean;
    { Snapshots compared with the server's, and how many differed }
    FNetChecked, FNetMismatches: Integer;
    { A replayed IN's recorded position, checked after this frame's move
      (the recorder samples after it) }
    FDemoSyncPending: Boolean;
    FDemoSyncOrigin: TVector3;
    FDemoSyncTime: Single;
    { Where the last prediction left the view (a camera moved by code since
      moves the server's player there) }
    FPredictedView: TVector3;
    FPredictValid: Boolean;
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
    { Demo actions BS / BE: frame times between them }
    FBenchmark: TQuakeBenchmark;
    FBenchLast: TTimerResult;
    FBenchSkip: Boolean;
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
    { Move the player (client prediction) and send this frame's usercmd to
      the server, which runs it at once }
    procedure MoveAndSend(const Attack: Boolean; const SecondsPassed: Single);
    procedure PredictMove(Sender: TObject; const Input: TPMoveInput; const PM: TQuakePMove);
    { The server's svc_print / svc_centerprint }
    procedure ClientPrint(const Text: String; const AtCenter: Boolean);
    { The console's addclient / clientinput / removeclient }
    procedure TestClientCommand(const Cmd, Args: String);
    { +set bots N }
    procedure AddStartBots;
    { E.4: other instances join this game (+set port, host) or this one
      joins another's (+connect, connect) }
    procedure StartHosting(const Port: Integer);
    procedure StartJoining(const Address: String);
    function PeerConnect(const Peer: String; const Channel: TNetLoopback): TObject;
    procedure PeerDisconnect(const Peer: String; const Ref: TObject);
    { Join mode, each frame first: the link, the snapshots, the host's map }
    procedure UpdateJoin(const SecondsPassed: Single);
    { Join mode: the snapshot's stats into the world's player (HUD, gun) }
    procedure ApplyClientStats;
    { Each test client reads its snapshots and sends its command }
    procedure UpdateTestClients(const SecondsPassed: Single);
    { The client's copy of the last snapshot must be the server's }
    procedure CheckSnapshot;
    { Measure a replay's drift from the recorded position and put the
      player back on its path (after the move) }
    procedure ApplyDemoSync;
    { V: the players and test clients }
    procedure LogClients;
    { Player actions that a recording keeps }
    procedure DoSelectWeapon(const Slot: Integer);
    procedure DoUse;
    procedure DoToggleHelp;
    { padbind [<action> <button> | reset]: list or change the gamepad buttons }
    procedure PadBindCommand(const Args: String);
    { Look along Quake yaw / pitch (pitch positive looks down), keeping the velocity }
    procedure SetLook(const YawDeg, PitchDeg: Single);
    procedure UpdateDeathView(const SecondsPassed: Single);
    { Underwater view warp (Quake 2 software renderer's D_WarpScreen) }
    procedure CreateWaterWarp;
    procedure UpdateWaterWarp(const SecondsPassed: Single);
    { target_poi marker on the HUD (UpdateCompass) and how long it shows }
    procedure UpdateCompass(const SecondsPassed: Single);
  private
    FCompassTime: Single;
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
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure CaptureScreenshot(const Prefix: String);
    { The screen drawn into a framebuffer (OffscreenScreenshots) }
    function SaveScreenOffscreen: TCastleImage;
    procedure CycleWeapon(const Delta: Integer);
    { Savegames in castle-config:/saves/<name>.json }
    procedure SaveGame(const SaveName: String);
    procedure LoadGame(const SaveName: String);
    { Autotest helper: stand on a floor near Target, looking at it }
    procedure GoNear(const Target: TVector3);
    function GoNearByTraces(const Target: TVector3): Boolean;
    { A free player box with a brush floor just below this eye (CGE) }
    function SpotStandsOnBrushes(const Eye: TVector3): Boolean;
    procedure QuitNow;
    procedure RunMapReport;
    { Draw MainViewport and WeaponViewport into FScaledView (at
      RenderScale percent of their size), then that image over their
      rectangle }
    procedure RenderScaled3D(const ViewportRect: TRectangle);
    procedure RenderLoopScaled(const ViewportRect: TRectangle);
    { Run the world's ticks for this frame }
    procedure RunTicks(const SecondsPassed: Single);
    { Effective render scale in percent: RenderScaleOverride or the option }
    function RenderScale: Integer;
  protected
    procedure InternalRenderLoop(const ViewportRect: TRectangle); override;
  public
    { --render-scale: overrides Settings.RenderScale (percent) when > 0 }
    RenderScaleOverride: Integer;
    { --fps / ?fps=1: show the frame rate counter from the start }
    ShowFpsAtStart: Boolean;
    { --offscreen-shots: autotest screenshots drawn into a framebuffer, so a
      minimized or covered window still saves real images }
    OffscreenScreenshots: Boolean;
    { The client draws the models from the snapshots (--server-draw: False;
      the clientdraw console command toggles it) }
    ClientDrawAtStart: Boolean;
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

{ ", dualfire N s" for the V log while DualFire runs }
function DualFireText(const Time: Single): String;
begin
  if Time > 0 then
    Result := Format(', dualfire %.1f s', [Time])
  else
    Result := '';
end;

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FCameraMode := cmFirstPerson;
  FWatchedMonster := -1;
  FDeathTime := -1;
  FDemoCommands := TStringList.Create;
  FBenchmark := TQuakeBenchmark.Create;
end;

destructor TViewPlay.Destroy;
begin
  FreeAndNil(FRecorder);
  FDemoCommands.Free;
  FBenchmark.Free;
  inherited Destroy;
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  WalkNavigation.Gravity := (Mode = cmFirstPerson) and not PlayerMovement.Active;
  PlayerMovement.Noclip := Mode = cmNoclip;
  if FClient <> nil then
    FClient.AddCommand('noclip ' + Iff(Mode = cmNoclip, '1', '0'));
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
  { Used by the next map load: textures and lightmaps are built then }
  SmoothTextures := Settings.SmoothTextures;
  if not GammaFromCommandLine then
    LightmapGamma := Settings.Brightness;
  WalkNavigation.MouseLookHorizontalSensitivity :=
    TCastleWalkNavigation.DefaultMouseLookHorizontalSensitivity * Settings.MouseSensitivity;
  WalkNavigation.MouseLookVerticalSensitivity :=
    TCastleWalkNavigation.DefaultMouseLookVerticalSensitivity * Settings.MouseSensitivity;
  WalkNavigation.InvertVerticalMouseLook := Settings.InvertMouse;
  { The design's camera uses a horizontal field of view, like Quake 2; Hor+
    keeps the vertical one of a 4:3 view instead (Yamagi, the remaster) }
  if Settings.WidescreenFov then
  begin
    MainViewport.Camera.Perspective.FieldOfViewAxis := faVertical;
    MainViewport.Camera.Perspective.FieldOfView := HorPlusVerticalFov(Settings.FieldOfView);
  end else
  begin
    MainViewport.Camera.Perspective.FieldOfViewAxis := faHorizontal;
    MainViewport.Camera.Perspective.FieldOfView := DegToRad(Settings.FieldOfView);
  end;
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


{ Move a control to the front of its parent's children. Removed first:
  InsertFront of a control that is already in the list adds it twice
  (CGE: "the result is undefined"), and the stale entry was written to
  after the control was freed, crashing on exit. }
procedure BringToFront(const C: TCastleUserInterface);
var
  P: TCastleUserInterface;
begin
  P := C.Parent;
  if P = nil then
    Exit;
  P.RemoveControl(C);
  P.InsertFront(C);
end;

procedure TViewPlay.OpenEditor;
begin
  EnsureLevelThemes;
  if FEditor = nil then
  begin
    FEditor := TQuakeLevelEditor.Create(FreeAtStop);
    FEditor.Name := 'LevelEditor';
    FEditor.OnPlay := @EditorPlay;
    FEditor.OnClose := @EditorClose;
    InsertFront(FEditor);
    { The console stays usable over the editor }
    BringToFront(Console);
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
  Cmd, Value: String;
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
    if (Cmd = 'select') and (Words.Count > 2) then
    begin
      FEditor.Tool := etInspect;
      FEditor.SelectAt(StrToIntDef(Words[1], 0), StrToIntDef(Words[2], 0));
    end else
    if (Cmd = 'set') and (Words.Count > 2) then
    begin
      { The value: the rest of the words (a target name, a light level...) }
      Value := Words[2];
      for I := 3 to Words.Count - 1 do
        Value := Value + ' ' + Words[I];
      if FEditor.SetSelectedKey(Words[1], Value) then
        WritelnLog('LevelEditor', 'Entity: ' + FEditor.SelectedText)
      else
        Console.Print('editor set: select an entity first (editor select x y); not classname / origin');
    end else
    if (Cmd = 'unset') and (Words.Count > 1) then
    begin
      if FEditor.SetSelectedKey(Words[1], '') then
        WritelnLog('LevelEditor', 'Entity: ' + FEditor.SelectedText);
    end else
    if (Cmd = 'round') and (Words.Count > 4) then
      FEditor.RoundRect(StrToIntDef(Words[1], 0), StrToIntDef(Words[2], 0), StrToIntDef(Words[3], 0),
        StrToIntDef(Words[4], 0))
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
      Console.Print('editor [new|generate [seed]|save [name]|load <name>|play|export|close|name <n>|tool <t>|entity <class>|brush <floor> <ceil> <theme>|channel <0-9>|lift <height>|key <blue|red>|fill <x0> <y0> <x1> <y1>|round <x0> <y0> <x1> <y1>|select <x> <y>|set <key> <value>|unset <key>]');
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
  FTickClock := TQuakeTickClock.Create;
  FTickList := TCastleTransformList.Create(False);
  if ShowFpsAtStart then
    LabelFps.Exists := True;

  { Touch screens get on-screen controls in front of everything but the
    menu and console }
  if TouchControlsWanted then
  begin
    FTouch := TQuakeTouchControls.Create(FreeAtStop);
    FTouch.OnUse := @TouchUse;
    FTouch.OnNextWeapon := @TouchNextWeapon;
    FTouch.OnMenu := @TouchMenu;
    InsertFront(FTouch);
    BringToFront(Menu);
    BringToFront(Console);
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
  FWorld.AttachWeaponToCamera(WeaponViewport.Camera, MainViewport.Camera);
  FWorld.Hud := Hud;
  FNet := TNetLoopback.Create;
  FServer := TQuakeServer.Create(FWorld, FNet);
  FClient := TQuakeClient.Create(FNet);
  { The server moves the player (the world's Player); the view predicts it
    with the same pmove and its own copy of the state }
  PlayerMovement.SyncParams;
  FServer.PM.CopyParams(PlayerMovement.PM);
  FWorld.Player := FServer.PM;
  FWorld.ViewPlayer := PlayerMovement;
  PlayerMovement.OnTrace := @FWorld.PlayerTrace;
  PlayerMovement.OnPointContents := @FWorld.PlayerPointContents;
  PlayerMovement.OnPredict := @PredictMove;
  FClient.OnPrint := @ClientPrint;
  FClientScene := TQuakeClientScene.Create(MainViewport.Items);
  FTestClients := specialize TObjectList<TTestClient>.Create(True);
  FClientScene.Enabled := ClientDrawAtStart;
  { Screenshots must not depend on random idle pauses of the view weapon }
  FWorld.Gun.RandomPauses := FAutoTestMap = '';
  Particles.SetParent(MainViewport.Items);
  Particles.Camera := MainViewport.Camera;
  Console.OnCommand := @HandleConsoleCommand;
  Menu.OnMenuAction := @HandleMenuAction;
  SetCameraMode(FCameraMode);
  ApplySettings;
  CreateWaterWarp;

  if FMapReportFile <> '' then
  begin
    RunMapReport;
    { Quit on the first Update: Application.Terminate during Start (before
      the main loop runs) was lost and the report never exited }
    FQuitPending := True;
  end else
  if NetConnectTo <> '' then
  begin
    { +connect: the host's map comes with its server data (UpdateJoin); a
      script runs meanwhile (the autotest's map is not loaded) }
    if FAutoTestMap <> '' then
    begin
      FAutoTestActive := True;
      ParseDemoScript(FAutoTestDemo);
    end;
    StartJoining(NetConnectTo);
    NetConnectTo := '';
  end else
  if FAutoTestMap <> '' then
  begin
    FAutoTestActive := True;
    ParseDemoScript(FAutoTestDemo);
    LoadLevel(FAutoTestMap);
    AddStartBots;
  end else
  begin
    if FMapName = '' then
      FMapName := FirstMapName;
    LoadLevel(FMapName);
    AddStartBots;
    { The title menu's Level Editor }
    if OpenEditorOnStart then
    begin
      OpenEditorOnStart := False;
      OpenEditor;
    end;
  end;
  if (NetHostPort > 0) and (FJoinBridge = nil) then
    StartHosting(NetHostPort);
end;

procedure TViewPlay.StartHosting(const Port: Integer);
{$ifndef WASI}
var
  Link: TNetUdpLink;
{$endif}
begin
  if FHostBridge <> nil then
  begin
    Console.Print('Already hosting');
    Exit;
  end;
  if FJoinBridge <> nil then
  begin
    Console.Print('Joined to a host: no hosting');
    Exit;
  end;
  {$ifdef WASI}
  Console.Print('No UDP on the web');
  {$else}
  Link := TNetUdpLink.Create(Port, NetBindAddress);
  if not Link.Opened then
  begin
    Console.Print('Cannot host: ' + Link.Error);
    WritelnWarning('Net', 'Cannot host on UDP port %d: %s', [Port, Link.Error]);
    Link.Free;
    Exit;
  end;
  FHostBridge := TNetHostBridge.Create(Link);
  FHostBridge.OnConnect := @PeerConnect;
  FHostBridge.OnDisconnect := @PeerDisconnect;
  Console.Print(Format('Hosting on UDP port %d', [Link.Port]));
  WritelnLog('Net', 'Hosting on UDP port %d', [Link.Port]);
  {$endif}
end;

procedure TViewPlay.StartJoining(const Address: String);
{$ifndef WASI}
var
  Link: TNetUdpLink;
{$endif}
begin
  if FHostBridge <> nil then
  begin
    Console.Print('Hosting: no joining');
    Exit;
  end;
  {$ifdef WASI}
  Console.Print('No UDP on the web');
  {$else}
  Link := TNetUdpLink.Create(0, NetBindAddress);
  if not Link.Opened then
  begin
    Console.Print('Cannot connect: ' + Link.Error);
    WritelnWarning('Net', 'Cannot open a UDP port: %s', [Link.Error]);
    Link.Free;
    Exit;
  end;
  FreeAndNil(FJoinBridge);
  FJoinBridge := TNetJoinBridge.Create(Link, Address);
  { The client talks to the host from now on; the local server idles }
  FreeAndNil(FClient);
  FClient := TQuakeClient.Create(FJoinBridge.Channel);
  FClient.OnPrint := @ClientPrint;
  FWorld.ClientOnly := True;
  FClientScene.Enabled := True;
  FJoinServerData := 0;
  FJoinLost := False;
  Console.Print('Connecting to ' + FJoinBridge.Host + '...');
  WritelnLog('Net', 'Joining %s from UDP port %d', [FJoinBridge.Host, Link.Port]);
  {$endif}
end;

function TViewPlay.PeerConnect(const Peer: String; const Channel: TNetLoopback): TObject;
var
  C: TServerClient;
begin
  C := FServer.AddClient(Channel);
  Result := C;
  if C = nil then
    Exit;
  WritelnLog('Net', 'Remote client %s is player %d', [Peer, C.Player.Number]);
  FServer.BroadcastPrint(Format('%s entered the game.', [FWorld.PlayerName(C.Player)]));
end;

procedure TViewPlay.PeerDisconnect(const Peer: String; const Ref: TObject);
begin
  if (Ref = nil) or (FServer = nil) then
    Exit;
  FServer.BroadcastPrint(Format('%s left the game.', [FWorld.PlayerName(TServerClient(Ref).Player)]));
  FServer.RemoveClient(TServerClient(Ref));
end;

procedure TViewPlay.UpdateJoin(const SecondsPassed: Single);
begin
  FJoinBridge.Pump(SecondsPassed);
  FClient.ReadPackets;
  if FClient.ServerDataCount <> FJoinServerData then
  begin
    { The host's map (first, or a new one): this world loads it with only
      the brush entities, under the host's deathmatch and skill }
    FJoinServerData := FClient.ServerDataCount;
    Deathmatch := FClient.Deathmatch;
    GameSkill := FClient.Skill;
    WritelnLog('Net', 'Host map "%s" (deathmatch %d, skill %d)',
      [FClient.MapName, Ord(Deathmatch), GameSkill]);
    LoadLevel(FClient.MapName);
    FJoinAim := True;
  end;
  if FJoinServerData = 0 then
  begin
    { Knocking: commands without a move until the host answers }
    FClient.SendMove(False, Vector3(1, 0, 0));
    FJoinBridge.Pump(0);
  end;
  if (FJoinBridge.Silence > PeerTimeout) and not FJoinLost then
  begin
    FJoinLost := True;
    Hud.ShowMessage('No answer from ' + FJoinBridge.Host, 5);
    WritelnWarning('Net', 'No answer from host %s', [FJoinBridge.Host]);
  end;
end;

procedure TViewPlay.ApplyClientStats;
var
  P: TQuakePlayer;
  S: TNetPlayerState;
  Weapon: Integer;
begin
  if not FClient.Frame.Valid then
    Exit;
  P := FWorld.CurrentPlayer;
  S := FClient.Frame.Player;
  P.Stats.Health := S.Stats[StatHealth];
  P.Stats.Armor := S.Stats[StatArmor];
  P.Stats.ArmorType := S.Stats[StatArmorType];
  P.Stats.WeaponMask := Cardinal(Word(S.Stats[StatWeaponsLow])) or (Cardinal(Word(S.Stats[StatWeaponsHigh])) shl 16);
  P.Stats.Keys := Cardinal(Word(S.Stats[StatKeysLow])) or (Cardinal(Word(S.Stats[StatKeysHigh])) shl 16);
  P.Stats.Kills := S.Stats[StatKills];
  P.Stats.TotalKills := S.Stats[StatTotalKills];
  P.Stats.Secrets := S.Stats[StatSecrets];
  P.Stats.TotalSecrets := S.Stats[StatTotalSecrets];
  P.Stats.Goals := S.Stats[StatGoals];
  P.Stats.TotalGoals := S.Stats[StatTotalGoals];
  P.Stats.QuadTime := S.Stats[StatQuad] / 10;
  P.Stats.InvulnTime := S.Stats[StatInvulnerable] / 10;
  P.Stats.LevelTime := S.Stats[StatLevelSeconds];
  P.Frags := S.Stats[StatFrags];
  Weapon := S.Stats[StatWeapon];
  if (Weapon >= 1) and (Weapon <= WeaponSlots) then
  begin
    if S.Stats[StatAmmo] >= 0 then
      P.Stats.Ammo[WeaponDefs[Weapon].AmmoType] := S.Stats[StatAmmo];
    if Weapon <> P.Stats.CurrentWeapon then
      FWorld.ShowClientWeapon(Weapon);
  end;
end;

procedure TViewPlay.AddStartBots;
var
  I: Integer;
begin
  { +set bots N: N bots join once the first map is loaded }
  for I := 1 to StartBots do
    TestClientCommand('addbot', '');
  StartBots := 0;
end;

function TViewPlay.RenderScale: Integer;
begin
  if RenderScaleOverride > 0 then
    Result := RenderScaleOverride
  else
    Result := Settings.RenderScale;
end;

procedure TViewPlay.InternalRenderLoop(const ViewportRect: TRectangle);
begin
  { Monsters, items, props and projectiles drawn between their last two
    ticks, back at their simulated poses right after drawing }
  if (FWorld <> nil) and (FTickClock <> nil) and not EditorOpen then
  begin
    FWorld.CollectMovingTransforms(FTickList);
    FTickClock.Apply(FTickList);
  end;
  try
    RenderLoopScaled(ViewportRect);
  finally
    if FTickClock <> nil then
      FTickClock.Restore;
  end;
end;

procedure TViewPlay.RenderLoopScaled(const ViewportRect: TRectangle);
var
  I, J: Integer;
  Group, C: TCastleUserInterface;
  Full: TFloatRectangle;
begin
  { The design's root holds both viewports, the HUD, the console and the
    menu; only the viewports are drawn at the lower resolution. The root
    draws nothing itself, so its children are drawn here in its place. }
  Group := nil;
  if (RenderScale < MaxRenderScale) and (MainViewport <> nil) and (WeaponViewport <> nil) and
     (MainViewport.Parent <> nil) and (MainViewport.Parent.Parent = Self) and
     (WeaponViewport.Parent = MainViewport.Parent) and
     (not MainViewport.Parent.Border.Exists) then
  begin
    Full := MainViewport.RenderRect;
    { The viewport is drawn at the image's origin }
    if (Abs(Full.Left) < 0.5) and (Abs(Full.Bottom) < 0.5) and (Full.Width >= 1) and (Full.Height >= 1) then
      Group := MainViewport.Parent;
  end;
  if Group = nil then
  begin
    inherited InternalRenderLoop(ViewportRect);
    Exit;
  end;
  for I := 0 to ControlsCount - 1 do
  begin
    C := Controls[I];
    if C <> Group then
      C.InternalRecursiveRender(ViewportRect)
    else
    if Group.Exists then
      for J := 0 to Group.ControlsCount - 1 do
      begin
        C := Group.Controls[J];
        if C = MainViewport then
          RenderScaled3D(ViewportRect)
        else
        if C <> WeaponViewport then
          C.InternalRecursiveRender(ViewportRect);
      end;
  end;
end;

procedure TViewPlay.RenderScaled3D(const ViewportRect: TRectangle);

  { Shrink both viewports to the bottom-left W x H pixels (their projection
    keeps the aspect ratio), or give them back their full size }
  procedure SetShrink(const DX, DY: Single);
  begin
    MainViewport.Border.Right := DX;
    MainViewport.Border.Top := DY;
    WeaponViewport.Border.Right := DX;
    WeaponViewport.Border.Top := DY;
  end;

var
  Full: TFloatRectangle;
  W, H: Integer;
begin
  if not MainViewport.Exists then
    Exit;
  Full := MainViewport.RenderRect;
  W := Max(1, Round(Full.Width * RenderScale / 100));
  H := Max(1, Round(Full.Height * RenderScale / 100));
  if (FScaledView = nil) or (FScaledView.Width <> Cardinal(W)) or (FScaledView.Height <> Cardinal(H)) then
  begin
    FreeAndNil(FScaledView);
    FScaledView := TDrawableImage.Create(TRGBImage.Create(W, H), Settings.SmoothTextures, True);
    WritelnLog('GameViewPlay', 'Render scale %d%%: 3D view drawn at %dx%d for %dx%d',
      [RenderScale, W, H, Round(Full.Width), Round(Full.Height)]);
  end;
  FScaledView.SmoothScaling := Settings.SmoothTextures;

  SetShrink((Full.Width - W) / UIScale, (Full.Height - H) / UIScale);
  try
    FScaledView.RenderToImageBegin;
    try
      RenderContext.Clear([cbColor, cbDepth], Black);
      MainViewport.InternalRecursiveRender(Rectangle(0, 0, W, H));
      if WeaponViewport.Exists then
        WeaponViewport.InternalRecursiveRender(Rectangle(0, 0, W, H));
    finally
      FScaledView.RenderToImageEnd;
    end;
  finally
    SetShrink(0, 0);
  end;
  { What TCastleContainer.RenderControlPrepare sets up for 2D drawing }
  RenderContext.DepthTest := False;
  RenderContext.Viewport := ViewportRect;
  OrthoProjection(FloatRectangle(0, 0, ViewportRect.Width, ViewportRect.Height));
  FScaledView.Draw(Full);
end;

procedure TViewPlay.Stop;
begin
  if FRecorder <> nil then
    StopRecording;
  Sounds.StopMusic;
  Particles.Camera := nil;
  Particles.SetParent(nil);
  FreeAndNil(FClientScene);
  { Their server clients go with the server; their channels after it }
  if FTestClients <> nil then
    FTestClients.OwnsObjects := False;
  { Remote clients leave the server before it goes (PeerDisconnect) }
  FreeAndNil(FHostBridge);
  FreeAndNil(FClient);
  { After its client: the client sends through the bridge's channel }
  FreeAndNil(FJoinBridge);
  FreeAndNil(FServer);
  if FTestClients <> nil then
    while FTestClients.Count > 0 do
    begin
      FTestClients[0].Server := nil;
      FTestClients[0].Free;
      FTestClients.Delete(0);
    end;
  FreeAndNil(FTestClients);
  FreeAndNil(FNet);
  { The world references design components, which are freed by inherited Stop }
  FreeAndNil(FWorld);
  FreeAndNil(FScaledView);
  FreeAndNil(FTickClock);
  FreeAndNil(FTickList);
  { Owned by MainViewport's screen effects, freed with the design }
  FWaterWarp := nil;
  FWaterWarpTime := nil;
  inherited Stop;
end;

procedure TViewPlay.PlaceCamera(const Pos: TVector3; const YawDeg: Single);
begin
  MainViewport.Camera.SetWorldView(Pos, YawToCgeDir(YawDeg), Vector3(0, 1, 0));
  PlayerMovement.ResetVelocity;
  { The server places the player (spawn, teleport) }
  if FServer <> nil then
    FServer.PlacePlayer(PlayerMovement.Origin, YawToCgeDir(YawDeg), True);
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
  if FTickClock <> nil then
    FTickClock.Reset;
  { "random" (the menus' Random Level): a new random level }
  LevelName := AMapName;
  if LevelName = RandomGameMap then
    LevelName := RandomMapName(1 + Random(999999));
  WritelnLog('GameViewPlay', 'Loading level "%s"', [LevelName]);
  if FWorld.LoadMap(LevelName) then
  begin
    FMapName := FWorld.Bsp.MapName;
    if FServer <> nil then
    begin
      FNet.Clear;
      FServer.NewMap(FMapName);
    end;
    PlaceCamera(FWorld.SpawnPoint, FWorld.SpawnAngle);
    Hud.ShowMessage(FMapName, 3.0);
  end else
  begin
    Hud.ShowMessage('Failed to load level: ' + LevelName, 5.0);
    { An autotest with no map to play can't run its script: say so, quit
      with exit code 1 (a missing map used to hang the test) }
    if FAutoTestActive and (FWorld.Bsp = nil) then
    begin
      WritelnWarning('GameViewPlay', 'Autotest: level "%s" could not be loaded, quitting', [LevelName]);
      ExitCode := 1;
      FQuitPending := True;
    end;
  end;
end;

function TViewPlay.SaveScreenOffscreen: TCastleImage;
var
  RT: TGLRenderToTexture;
  R: TRectangle;
  I: Integer;
begin
  { Draw every control into a framebuffer of the window's size and read it
    back: works while the window is minimized or covered, where reading the
    window itself gives black }
  R := Rectangle(0, 0, Container.Width, Container.Height);
  RT := TGLRenderToTexture.Create(R.Width, R.Height);
  try
    RT.Buffer := tbNone;
    RT.GLContextOpen;
    RT.RenderBegin;
    try
      RenderContext.Clear([cbColor, cbDepth], Black);
      for I := 0 to Container.Controls.Count - 1 do
        if Container.Controls[I].Exists then
          Container.RenderControl(Container.Controls[I], R);
      Result := RT.SaveScreen(TRGBImage, R);
    finally
      RT.RenderEnd;
    end;
  finally
    RT.Free;
  end;
end;

procedure TViewPlay.CaptureScreenshot(const Prefix: String);
var
  OutPath: String;
  Img: TCastleImage;
begin
  Inc(FAutoTestShots);
  OutPath := Prefix + '_' + IntToStr(FAutoTestShots) + '.png';
  try
    if OffscreenScreenshots then
      Img := SaveScreenOffscreen
    else
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
  { If shutdown gets stuck (seen on CI's virtual display), end anyway }
  StartExitWatchdog;
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

{ What a trace hit, for logs: the world, a mover, monster, prop or the player }
{ Model instances that have dynamic lights on them now }
function ModelsLitCount: Integer;
var
  Inst: TQuakeMd2Instance;
begin
  Result := 0;
  for Inst in Md2Instances do
    if Inst.DynamicLightCount > 0 then
      Inc(Result);
end;

function TraceHitName(const Ent: TObject): String;
begin
  if Ent = nil then
    Result := 'world'
  else
  if Ent is TQuakeMover then
    Result := TQuakeMover(Ent).Entity.ClassName + ' ' + TQuakeMover(Ent).Entity.Model
  else
  if Ent is TQuakeMonster then
    Result := TQuakeMonster(Ent).Transform.Name
  else
  if Ent is TQuakeProp then
    Result := TQuakeProp(Ent).Transform.Name
  else
    Result := Ent.ClassName;
end;

{ The smallest move (Quake units, along an axis) that gets a monster's box
  out of solid, for the V log: 'none within 32' if there is none }
function FreeingNudge(const M: TQuakeMonster): String;
const
  Dirs: array[0..5] of TVector3 = ((X: 1; Y: 0; Z: 0), (X: -1; Y: 0; Z: 0), (X: 0; Y: 1; Z: 0),
    (X: 0; Y: -1; Z: 0), (X: 0; Y: 0; Z: 1), (X: 0; Y: 0; Z: -1));
  Steps: array[0..10] of Single = (0.001, 0.03125, 0.125, 0.5, 1, 2, 4, 8, 16, 24, 32);
var
  D: Single;
  I: Integer;
  P: TVector3;
begin
  for D in Steps do
    for I := 0 to High(Dirs) do
    begin
      P := M.Origin + Dirs[I] * D;
      if not EntityTrace(P, P, M.BoxMins, M.BoxMaxs, MASK_MONSTERSOLID, M).StartSolid then
        Exit((Dirs[I] * D).ToString);
    end;
  Result := 'none within 32';
end;

procedure TViewPlay.RunDemoStep(const SecondsPassed: Single);
const
  { V log: how far a monster's box may overlap solid and still count as
    touching (twice Quake 2's DIST_EPSILON) }
  SolidSlack = 0.0625;
var
  Cmd, Action, Param: String;
  P, J: Integer;
  Val: Single;
  Dir, Target, TrainAt: TVector3;
  Ignore: TCastleTransform;
  Key, K: TKey;
  SolidCount: Integer;
  SolidTrace, SweepTrace: TQuakeTrace;
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
        FNetAttackTap := True;
      Input := NextInput;
      Inc(FDemoIndex);
    end;
    SetLook(Input.Yaw, Input.Pitch);
    { The recorded position is after this frame's inputs moved the player:
      compared after the move (ApplyDemoSync) }
    if Input.HasOrigin then
    begin
      FDemoSyncPending := True;
      FDemoSyncOrigin := Input.Origin;
      FDemoSyncTime := Input.Time;
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

  if Action = 'BS' then { Benchmark start: measure frames until BE }
  begin
    FBenchmark.Start;
    FBenchLast := Timer;
    FBenchSkip := True;
  end else
  if Action = 'BE' then { Benchmark end: log the frame time percentiles }
    WritelnLog('Demo', BenchmarkText(FBenchmark.Stop))
  else
  if Action = 'S' then
    CaptureScreenshot(FAutoTestPrefix)
  else
  if Action = 'X' then
  begin
    RecordCommand('X');
    FNetAttackTap := True;
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
      { Spawned in this frame: the server knows it when it runs the command }
      if J >= 0 then
      begin
        FClient.AddCommand('mv ' + Param);
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
  if Action = 'GH' then { Hold / release a gamepad button (toggle), e.g. "GH:south" }
  begin
    if GamepadButtonFromName(Param, Button) then
    begin
      if Button in VirtualGamepad.Held then
        Exclude(VirtualGamepad.Held, Button)
      else
        Include(VirtualGamepad.Held, Button);
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
        PlayerMovement.BoxMaxs, MASK_PLAYERSOLID, FServer.PM).EndPos;
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
    FClient.AddCommand('fire ' + Param)
  else
  if (Action = 'V') and (FWorld.Bsp = nil) then
  begin
    { No map (a join still waiting for the host's) }
    WritelnLog('Demo', 'No map loaded');
    LogClients;
  end else
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
    { Trains: where their mins corner is (on a path_corner when there) }
    for J := 0 to FWorld.Geometry.Movers.Count - 1 do
      if FWorld.Geometry.Movers[J].Kind = mkTrain then
      begin
        TrainAt := CgeToQuake(FWorld.Geometry.Movers[J].Transform.Translation) +
          FWorld.Geometry.Bsp.Models[FWorld.Geometry.Movers[J].ModelIndex].Mins;
        WritelnLog('Demo', 'Train %d %s at %.0f %.0f %.0f running %s waiting %s', [J,
          FWorld.Geometry.Movers[J].Entity.Model, TrainAt.X, TrainAt.Y, TrainAt.Z,
          BoolToStr(FWorld.Geometry.Movers[J].TrainRunning, True),
          BoolToStr(FWorld.Geometry.Movers[J].TrainWaiting, True)]);
      end;
    WritelnLog('Demo', 'Sound mixer: %d playing, load %.2f, limiter %.2f', [Sounds.ActiveSoundCount,
      Sounds.MixLoad, Sounds.LimiterGain]);
    for J := 0 to FWorld.Turrets.Count - 1 do
      WritelnLog('Demo', 'Turret %d pitch %.1f yaw %.1f aim %.1f %.1f bases %d driver %s shots %d', [J,
        FWorld.Turrets[J].Breach.TurretPitch, FWorld.Turrets[J].Breach.TurretYaw,
        FWorld.Turrets[J].MovePitch, FWorld.Turrets[J].MoveYaw, Length(FWorld.Turrets[J].Bases),
        BoolToStr(FWorld.Turrets[J].Driver <> nil, True), FWorld.Turrets[J].Shots]);
    for J := 0 to FWorld.Props.Count - 1 do
      WritelnLog('Demo', 'Prop %d %s health %d destroyed %s flying %s exists %s light %s', [J,
        FWorld.Props[J].Entity.ClassName, FWorld.Props[J].Health,
        BoolToStr(FWorld.Props[J].Destroyed, True), BoolToStr(FWorld.Props[J].Flying, True),
        BoolToStr(FWorld.Props[J].Transform.Exists, True), BoolToStr(FWorld.Props[J].LightOn, True)]);
    for J := 0 to FWorld.Lasers.Count - 1 do
      WritelnLog('Demo', 'Laser %d on %s length %.0f %s pulses %d', [J,
        BoolToStr(FWorld.Lasers[J].IsOn, True), FWorld.Lasers[J].Length,
        FWorld.Lasers[J].Entity.ClassName, FWorld.Lasers[J].Pulses]);
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
        { Turrets hang in their walls by design }
        if Assigned(EntityTrace) and not FWorld.Monsters[J].IsTurretMonster then
        begin
          { Inside, not touching: maps place monsters with their box exactly
            against a wall, and movers push them to DIST_EPSILON (1/32) from
            one; Quake 2 doesn't count either as stuck (they move away fine),
            so the box is tested 1/16 smaller on each side }
          SolidTrace := EntityTrace(FWorld.Monsters[J].Origin, FWorld.Monsters[J].Origin,
            FWorld.Monsters[J].BoxMins + Vector3(SolidSlack, SolidSlack, SolidSlack),
            FWorld.Monsters[J].BoxMaxs - Vector3(SolidSlack, SolidSlack, SolidSlack),
            MASK_MONSTERSOLID, FWorld.Monsters[J]);
          if SolidTrace.StartSolid then
          begin
            Inc(SolidCount);
            { StepMove's second trace: from the position itself down a step }
            SweepTrace := EntityTrace(FWorld.Monsters[J].Origin,
              FWorld.Monsters[J].Origin - Vector3(0, 0, 18), FWorld.Monsters[J].BoxMins,
              FWorld.Monsters[J].BoxMaxs, MASK_MONSTERSOLID, FWorld.Monsters[J]);
            WritelnLog('Demo', 'Monster %d %s in solid at %s (%s%s, free by %s; step sweep start solid %s all solid %s fraction %.3f)', [J, FWorld.Monsters[J].Def^.ClassName,
              FWorld.Monsters[J].Origin.ToString, TraceHitName(SolidTrace.Ent),
              Iff(SolidTrace.AllSolid, ', all solid', ''), FreeingNudge(FWorld.Monsters[J]),
              BoolToStr(SweepTrace.StartSolid, True), BoolToStr(SweepTrace.AllSolid, True), SweepTrace.Fraction]);
          end;
        end;
      end;
    WritelnLog('Demo', 'Monsters: %d alerted of %d alive, %d in solid, sight traces skipped by the PVS %d', [P, Round(Val), SolidCount, SightTracesSkipped]);
    for J := 0 to FWorld.Monsters.Count - 1 do
      if FWorld.Monsters[J].Alerted and FWorld.Monsters[J].IsAlive then
        WritelnLog('Demo', 'Hunting monster %d sees player %s dist %.0f', [J,
          BoolToStr(FWorld.Monsters[J].CanSeePlayer, True),
          PointsDistance(FWorld.Monsters[J].Transform.Translation, PlayerMovement.AimPosition)]);
    WritelnLog('Demo', 'Projectiles: %d, delayed targets: %d, earthquakes: %d, player gravity %.2f, gibs: %d',
      [FWorld.ProjectileCount, FWorld.DelayedCount, FWorld.EarthquakeCount, FWorld.PlayerGravity, Particles.GibCount]);
    WritelnLog('Demo', 'Particles: %d (mesh uploads %d)', [Particles.ParticleCount, Particles.Uploads]);
    if FNet.PacketsToClient > 0 then
      WritelnLog('Demo', 'Net: server frame %d, %d entities in view, last snapshot %d bytes (delta from %d), %d bytes a snapshot on average, %d commands (%d string), client frames %d (%d bad), %d of %d checked differ, prediction checked %d times, %d off by more than 1/8 (max %.2f)',
        [FServer.FrameNum, Length(FServer.LastFrame.Entities), FServer.LastBytes, FServer.LastDelta,
         FNet.BytesToClient div FNet.PacketsToClient, FServer.Commands, FServer.StringCommands,
         FClient.FramesReceived, FClient.BadFrames, FNetMismatches, FNetChecked,
         FClient.PredictionChecks, FClient.PredictionErrors, FClient.MaxPredictionError]);
    WritelnLog('Demo', 'Client draws %d models from the snapshots%s',
      [FClientScene.Count, Iff(FClientScene.Enabled, '', ' (clientdraw off)')]);
    LogClients;
    WritelnLog('Demo', 'Player: server origin %s velocity %s%s water %d, client origin %s%s',
      [FServer.PM.Origin.ToString, FServer.PM.QuakeVelocity.ToString,
       Iff(FServer.PM.Crouched, ' crouched', ''), FServer.PM.WaterLevel,
       PlayerMovement.Origin.ToString, Iff(PlayerMovement.PM.Crouched, ' crouched', '')]);
    WritelnLog('Demo', 'Model lights: %d of %d models lit by dynamic lights%s', [ModelsLitCount, Md2Instances.Count,
      Iff((FWorld.WeaponModel <> nil) and (FWorld.WeaponModel.DynamicLightCount > 0), ', the gun too', '')]);
    WritelnLog('Demo', 'String: "%s"', [FWorld.LastString]);
    WritelnLog('Demo', 'Monster shots: %d, player health %d armor %d, player stuck %d', [FWorld.MonsterShots,
      FWorld.Stats.Health, FWorld.Stats.Armor, FServer.PM.StuckCount]);
    WritelnLog('Demo', 'Replay drift: max %.1f units', [FDemoMaxDrift]);
    WritelnLog('Demo', 'Kills: %d / %d, secrets %d / %d, goals %d / %d', [FWorld.Stats.Kills, FWorld.Stats.TotalKills,
      FWorld.Stats.Secrets, FWorld.Stats.TotalSecrets, FWorld.Stats.Goals, FWorld.Stats.TotalGoals]);
    WritelnLog('Demo', 'Gun: weapon %d state %d frame %d, ammo shells %d bullets %d grenades %d cells %d slugs %d mag slugs %d traps %d flechettes %d prox %d tesla %d%s', [
      FWorld.Gun.Slot, Ord(FWorld.Gun.State), FWorld.Gun.Frame, FWorld.Stats.Ammo[atShells],
      FWorld.Stats.Ammo[atBullets], FWorld.Stats.Ammo[atGrenades], FWorld.Stats.Ammo[atCells],
      FWorld.Stats.Ammo[atSlugs], FWorld.Stats.Ammo[atMagSlugs], FWorld.Stats.Ammo[atTraps], FWorld.Stats.Ammo[atFlechettes], FWorld.Stats.Ammo[atProx], FWorld.Stats.Ammo[atTesla],
      DualFireText(FWorld.Stats.QuadFireTime)]);
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
    FClient.AddCommand('give all')
  else
  if Action = 'Y' then
    FClient.AddCommand('god')
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
      { Render meshes aren't the brushes (sky, clip, detail): the spot must
        be free and over a brush floor for Quake traces too, else the
        player may land outside the map and fall forever }
      if not SpotStandsOnBrushes(Spot) then
        Continue;
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

function TViewPlay.SpotStandsOnBrushes(const Eye: TVector3): Boolean;
const
  BoxMins: TVector3 = (X: -16; Y: -16; Z: -24);
  BoxMaxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Org: TVector3;
  Tr: TQuakeTrace;
begin
  { The player's origin is 22 below the eye }
  Org := CgeToQuake(Eye) - Vector3(0, 0, PlayerEyeHeight - 24);
  Tr := FWorld.WorldTrace(Org + Vector3(0, 0, 2), Org - Vector3(0, 0, 48), BoxMins, BoxMaxs, MASK_PLAYERSOLID, nil);
  Result := (not Tr.StartSolid) and (Tr.Fraction < 1) and (Tr.Normal.Z >= 0.7);
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
  if FTickClock <> nil then
    FTickClock.Reset;
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
      FServer.PlacePlayer(PlayerMovement.Origin, Dir, True);
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
  FClient.AddCommand('weapon ' + IntToStr(Slot));
end;

procedure TViewPlay.DoUse;
begin
  RecordCommand('U');
  FClient.AddCommand('use');
end;

procedure TViewPlay.PadBindCommand(const Args: String);
const
  ShortNames: array[TPadAction] of String = ('jump', 'crouch', 'use', 'grenade',
    'help', 'next', 'prev');
var
  Parts: TStringArray;
  A, Found: TPadAction;
  HasAction: Boolean;
  Button: TGameControllerButton;
begin
  Parts := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
  if (Length(Parts) = 1) and SameText(Parts[0], 'reset') then
    Settings.ResetPadButtons
  else
  if Length(Parts) = 2 then
  begin
    HasAction := False;
    Found := paJump;
    for A := Low(TPadAction) to High(TPadAction) do
      if SameText(ShortNames[A], Parts[0]) then
      begin
        Found := A;
        HasAction := True;
      end;
    if not HasAction then
    begin
      Console.Print('Unknown action "' + Parts[0] + '" (jump, crouch, use, grenade, help, next, prev)');
      Exit;
    end;
    if not (PadButtonFromName(Parts[1], Button) and Settings.BindPadButton(Found, Button)) then
    begin
      Console.Print('Cannot bind "' + Parts[1] + '" (south, east, west, north, lb, rb, ls, rs, left, right, view, share)');
      Exit;
    end;
    Settings.Save;
  end else
  if Length(Parts) <> 0 then
  begin
    Console.Print('Usage: padbind [<action> <button> | reset]');
    Exit;
  end;
  for A := Low(TPadAction) to High(TPadAction) do
  begin
    Console.Print(Format('%s: %s', [ShortNames[A], PadButtonNames[Settings.PadButtons[A]]]));
    WritelnLog('Gamepad', '%s: %s', [ShortNames[A], PadButtonNames[Settings.PadButtons[A]]]);
  end;
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

procedure TViewPlay.CreateWaterWarp;
var
  Shader: TComposedShaderNode;
  Part: TShaderPartNode;
begin
  { D_WarpScreen: every row is shifted sideways and every column up / down by
    a sine of the other coordinate (AMP2 = 3 pixels, CYCLE = 128 pixels,
    SPEED = 20 table steps a second, at 320 x 240), the picture shrunk a
    little so the edges stay covered. Scaled with the screen height. }
  Part := TShaderPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents :=
    'uniform float time;' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec2 size = vec2(float(screen_width), float(screen_height));' + LineEnding +
    '  float s = size.y / 240.0;' + LineEnding +
    '  float amp = 3.0 * s;' + LineEnding +
    '  float k = 6.2831853 / (128.0 * s);' + LineEnding +
    '  float phase = time * 6.2831853 * 20.0 / 128.0;' + LineEnding +
    '  vec2 p = screenf_position();' + LineEnding +
    '  vec2 q = (p - size * 0.5) * (1.0 - 2.0 * amp / size) + size * 0.5;' + LineEnding +
    '  q += amp * vec2(sin(p.y * k + phase), sin(p.x * k + phase));' + LineEnding +
    '  gl_FragColor = screenf_get_color(q);' + LineEnding +
    '}';
  Shader := TComposedShaderNode.Create;
  Shader.SetParts([Part]);
  FWaterWarpTime := TSFFloat.Create(Shader, True, 'time', 0);
  Shader.AddCustomField(FWaterWarpTime);
  FWaterWarp := TScreenEffectNode.Create;
  FWaterWarp.SetShaders([Shader]);
  FWaterWarp.Enabled := False;
  MainViewport.AddScreenEffect(FWaterWarp);
end;

procedure TViewPlay.UpdateCompass(const SecondsPassed: Single);
var
  Target, ToTarget: TVector3;
  P: TVector2;
begin
  { The remaster's compass: the target_poi marker for a few seconds after
    the compass command, and while the help computer is open }
  FCompassTime := Max(0, FCompassTime - SecondsPassed);
  Hud.PoiVisible := (FWorld <> nil) and FWorld.PoiValid and ((FCompassTime > 0) or Hud.HelpVisible);
  if not Hud.PoiVisible then
    Exit;
  Target := QuakeToCge(FWorld.PoiPosition);
  ToTarget := Target - MainViewport.Camera.Translation;
  Hud.PoiDistance := ToTarget.Length;
  P := MainViewport.PositionFromWorld(Target);
  P := Vector2(P.X / Max(1, MainViewport.EffectiveWidth), P.Y / Max(1, MainViewport.EffectiveHeight));
  { Behind the camera the projection is mirrored: put it at the bottom edge }
  if TVector3.DotProduct(ToTarget, MainViewport.Camera.Direction) < 0 then
    P := Vector2(1 - P.X, 0);
  Hud.PoiScreen := P;
end;

procedure TViewPlay.UpdateWaterWarp(const SecondsPassed: Single);
var
  Underwater: Boolean;
begin
  if FWaterWarp = nil then
    Exit;
  { The eye is in water, slime or lava (RDF_UNDERWATER) }
  Underwater := Hud.UnderwaterType <> 0;
  if FWaterWarp.Enabled <> Underwater then
    FWaterWarp.Enabled := Underwater;
  if Underwater then
  begin
    FWaterWarpClock := FWaterWarpClock + SecondsPassed;
    FWaterWarpTime.Send(FWaterWarpClock);
  end;
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
  FrameStart: TTimerResult;
  FrameSeconds: Double;
  TraceCount0: Int64;
  TraceSeconds0: Double;
begin
  { Traces of this frame, player movement (in inherited Update) included }
  TraceTiming := FBenchmark.Running;
  TraceCount0 := TraceCount;
  TraceSeconds0 := TraceSeconds;
  inherited Update(SecondsPassed, HandleInput);
  { Benchmark: wall time since the previous frame (rendering included) }
  FrameStart := Timer;
  FrameSeconds := 0;
  if FBenchmark.Running then
  begin
    FrameSeconds := TimerSeconds(FrameStart, FBenchLast);
    FBenchLast := FrameStart;
  end;
  if FQuitPending then
  begin
    FQuitPending := False;
    QuitNow;
    Exit;
  end;

  if FDemoCommands.Count > 0 then
  begin
    FDemoClock := FDemoClock + SecondsPassed;
    RunDemoStep(SecondsPassed);
  end;
  if FRecorder <> nil then
    FRecordClock := FRecordClock + SecondsPassed;

  if FWorld = nil then
    Exit;

  { Join mode: nothing to show until the host's map has come }
  if FJoinBridge <> nil then
  begin
    UpdateJoin(SecondsPassed);
    if FJoinServerData = 0 then
      Exit;
  end;

  if LabelFps.Exists then
    LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  { No map loaded (it was missing): nothing to update; the menu and the
    console still work }
  if FWorld.Bsp = nil then
    Exit;

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
  FWorld.UpdateFrame(SecondsPassed);
  RunTicks(SecondsPassed);
  { Hold to fire (left mouse / Ctrl) }
  Firing := FDemoFireHeld or FDemoInFire;
  if not Console.IsOpen and not Menu.Exists then
    { With touch controls every touch is a "left button": fire only by FIRE }
    Firing := Firing or Container.Pressed[Settings.Keys[qaFire]] or
      ((FTouch = nil) and (buttonLeft in Container.MousePressed)) or FGamepadFire;
  { Like Quake 2's client frame: this frame's command, predicted here and
    run by the server at once (ClientThink: the move, then fire) }
  MoveAndSend(Firing or FNetAttackTap, SecondsPassed);
  FNetAttackTap := False;
  ApplyDemoSync;
  { The snapshots' models, between the last two ticks like the server's }
  FServer.HideModels := FClientScene.Enabled;
  FClientScene.Update(FClient, FTickClock.Alpha, SecondsPassed);
  FWorld.SetGunAngles(PlayerMovement.GunAngles);
  FWorld.Geometry.UpdateVisibility(CgeToQuake(MainViewport.Camera.Translation));
  FWorld.CullEntities;
  Sounds.ListenerRight := TVector3.CrossProduct(MainViewport.Camera.Direction, MainViewport.Camera.Up).Normalize;
  FWorld.UpdateLoopSounds(MainViewport.Camera.Translation);
  if FBenchmark.Running then
  begin
    { The first frame after BS also holds the time before it }
    if not FBenchSkip then
      FBenchmark.AddFrame(FrameSeconds, TimerSeconds(Timer, FrameStart),
        MainViewport.Statistics.ShapesRendered, TraceCount - TraceCount0, TraceSeconds - TraceSeconds0);
    FBenchSkip := False;
  end;
  Sounds.UpdateMixer(SecondsPassed, Settings.SoundVolume / 100);
  WalkNavigation.Exists := not FWorld.Dead;
  UpdateDeathView(SecondsPassed);
  UpdateWaterWarp(SecondsPassed);
  UpdateCompass(SecondsPassed);

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

  if FRecorder <> nil then
    SampleRecording(Firing);
end;

procedure TViewPlay.ClientPrint(const Text: String; const AtCenter: Boolean);
begin
  if AtCenter then
    Hud.ShowMessage(Text, 2)
  else
    Console.Print(Text);
end;

procedure TViewPlay.PredictMove(Sender: TObject; const Input: TPMoveInput; const PM: TQuakePMove);
begin
  FClient.Predict(Input, PM);
end;

procedure TViewPlay.MoveAndSend(const Attack: Boolean; const SecondsPassed: Single);
var
  Alive: Boolean;
begin
  if FJoinBridge <> nil then
  begin
    { Join mode: the host runs the game; this view predicts its player
      from the snapshots and sends its commands }
    FClient.ReadPackets;
    ApplyClientStats;
    if FClient.Frame.Valid and (FClient.Frame.ServerFrame <> FJoinAimFrame) then
    begin
      if FJoinAim or ((FClient.Frame.Player.PmFlags and PmfTeleport) <> 0) or
         ((FJoinLastHealth <= 0) and (FClient.Frame.Player.Stats[StatHealth] > 0)) then
      begin
        SetLook(FClient.Frame.Player.ViewAngles.Y, FClient.Frame.Player.ViewAngles.X);
        FJoinAim := False;
      end;
      FJoinAimFrame := FClient.Frame.ServerFrame;
      FJoinLastHealth := FClient.Frame.Player.Stats[StatHealth];
    end;
    FWorld.UpdateClientView(SecondsPassed, FClient.Frame.Player.GunFrame);
    Alive := FClient.Frame.Valid and (FClient.Frame.Player.Stats[StatHealth] > 0) and
      not PlayerMovement.Suspended;
    FPredictValid := Alive and PlayerMovement.MoveNow(SecondsPassed);
    FClient.SendMove(Attack, CgeToQuake(PlayerMovement.AimDirection));
    FJoinBridge.Pump(0);
    Exit;
  end;
  { Remote clients' commands in, this frame's snapshots out }
  if FHostBridge <> nil then
    FHostBridge.Pump(SecondsPassed);
  Alive := not FWorld.Dead and not PlayerMovement.Suspended;
  { Code moved the camera since the last prediction (demo actions, the
    console): the server's player goes there, keeping its velocity }
  if FPredictValid and Alive and
     not TVector3.PerfectlyEquals(PlayerMovement.AimPosition, FPredictedView) then
    FServer.PlacePlayer(PlayerMovement.Origin, PlayerMovement.AimDirection, False);
  { A placed player is sent at once, so prediction starts from there }
  if FServer.PlayerChanged then
    FServer.SendFrame;
  FClient.ReadPackets;
  FPredictValid := Alive and PlayerMovement.MoveNow(SecondsPassed);
  if FPredictValid then
    FPredictedView := PlayerMovement.AimPosition;
  FClient.SendMove(Attack, CgeToQuake(PlayerMovement.AimDirection));
  UpdateTestClients(SecondsPassed);
  FServer.ReadPackets;
end;

destructor TTestClient.Destroy;
begin
  FreeAndNil(Bot);
  FreeAndNil(Client);
  FreeAndNil(PM);
  FreeAndNil(Net);
  inherited Destroy;
end;

procedure TViewPlay.UpdateTestClients(const SecondsPassed: Single);
var
  T: TTestClient;
  Input: TPMoveInput;
  Slot: Integer;
begin
  for T in FTestClients do
  begin
    T.Client.ReadPackets;
    if (T.Bot <> nil) and (T.Server <> nil) then
    begin
      { The bot decides from the server's world; its command goes through
        the channel like a person's }
      T.Bot.Think(FWorld, T.Server.Player, SecondsPassed);
      T.Forward := T.Bot.Forward;
      T.Side := T.Bot.Side;
      T.Yaw := T.Bot.Yaw;
      T.Pitch := T.Bot.Pitch;
      T.Fire := T.Bot.Fire;
      T.Jump := T.Bot.Jump;
      if T.Bot.TakeWeaponRequest(Slot) then
        T.Client.AddCommand('weapon ' + IntToStr(Slot));
    end;
    Input := Default(TPMoveInput);
    Input.Forward := T.Forward;
    Input.Side := T.Side;
    Input.Jump := T.Jump;
    Input.Dir := Vector3(Cos(DegToRad(T.Pitch)) * Cos(DegToRad(T.Yaw)),
      Cos(DegToRad(T.Pitch)) * Sin(DegToRad(T.Yaw)), Sin(DegToRad(T.Pitch)));
    Input.Dt := SecondsPassed;
    T.Client.Predict(Input, T.PM);
    T.Client.SendMove(T.Fire, Input.Dir);
  end;
end;

procedure TViewPlay.TestClientCommand(const Cmd, Args: String);
var
  T: TTestClient;
  Words: TStringList;
  N: Integer;
begin
  Words := SplitArgs(Args);
  try
    if (Cmd = 'addclient') or (Cmd = 'addbot') then
    begin
      T := TTestClient.Create;
      T.Net := TNetLoopback.Create;
      T.Client := TQuakeClient.Create(T.Net);
      T.PM := TQuakePMove.Create;
      T.Server := FServer.AddClient(T.Net);
      if T.Server = nil then
      begin
        T.Free;
        Console.Print('No room for another client');
        Exit;
      end;
      T.PM.CopyParams(PlayerMovement.PM);
      T.Yaw := FWorld.SpawnAngle;
      FTestClients.Add(T);
      if Cmd = 'addbot' then
      begin
        { addbot [skill 0..3] (default: the game's skill) }
        N := GameSkill;
        if Words.Count > 0 then
          N := StrToIntDef(Words[0], GameSkill);
        T.Bot := TQuakeBot.Create(T.Server.Player.Number, N, T.Yaw);
        Console.Print(Format('Bot %d added (player %d, skill %d)', [FTestClients.Count, T.Server.Player.Number, T.Bot.Skill]));
        WritelnLog('Net', 'Bot %d added: player %d, skill %d', [FTestClients.Count, T.Server.Player.Number, T.Bot.Skill]);
        Exit;
      end;
      Console.Print(Format('Client %d added (player %d)', [FTestClients.Count, T.Server.Player.Number]));
      WritelnLog('Net', 'Test client %d added: player %d', [FTestClients.Count, T.Server.Player.Number]);
      Exit;
    end;
    N := -1;
    if Words.Count > 0 then
      N := StrToIntDef(Words[0], 0) - 1;
    if (N < 0) or (N >= FTestClients.Count) then
    begin
      Console.Print('Usage: ' + Cmd + ' <client 1..' + IntToStr(FTestClients.Count) + '> ...');
      Exit;
    end;
    T := FTestClients[N];
    if Cmd = 'removeclient' then
    begin
      FServer.RemoveClient(T.Server);
      T.Server := nil;
      FTestClients.Delete(N);
    end else
    if Cmd = 'clientgoto' then
    begin
      { clientgoto <n> <x> <y> <z>: the client's player at a Quake origin
        (tests; like a teleport of another player) }
      if (Words.Count >= 4) and (T.Server.PM <> nil) then
      begin
        T.Server.PM.Origin := Vector3(StrToFloatDef(Words[1], 0, DefaultFormatSettings),
          StrToFloatDef(Words[2], 0, DefaultFormatSettings), StrToFloatDef(Words[3], 0, DefaultFormatSettings));
        T.Server.PM.ResetState;
        T.Server.Player.Pos := QuakeToCge(T.Server.PM.Origin + Vector3(0, 0, T.Server.PM.ViewHeight));
        WritelnLog('Net', 'Test client %d placed at %s', [N + 1, T.Server.PM.Origin.ToString]);
      end;
    end else
    begin
      { clientinput <n> <forward> <side> <yaw> [fire 0|1] }
      if Words.Count >= 2 then
        T.Forward := StrToFloatDef(Words[1], 0);
      if Words.Count >= 3 then
        T.Side := StrToFloatDef(Words[2], 0);
      if Words.Count >= 4 then
        T.Yaw := StrToFloatDef(Words[3], T.Yaw);
      if Words.Count >= 5 then
        T.Fire := Words[4] <> '0';
    end;
  finally
    Words.Free;
  end;
end;

procedure TViewPlay.LogClients;
var
  I, Seen: Integer;
  Frags: String;
  P: TQuakePlayer;
  T: TTestClient;
  F: TNetFrame;
  S: TNetEntityState;
begin
  { The players the view's snapshot shows (numbers 1 .. MaxNetClients) }
  Seen := 0;
  for S in FClient.Frame.Entities do
    if S.Number <= MaxNetClients then
      Inc(Seen);
  if FJoinBridge <> nil then
  begin
    { Join mode: the local server is idle; what came from the host }
    WritelnLog('Demo', 'Join: host %s map "%s", packets in %d out %d, silence %.1f s, frames %d (%d bad), ' +
      'the view sees %d other players, health %d frags %d, prediction checked %d times, %d off by more than 1/8 (max %.2f), origin %s',
      [FJoinBridge.Host, FClient.MapName, FJoinBridge.PacketsIn, FJoinBridge.PacketsOut, FJoinBridge.Silence,
       FClient.FramesReceived, FClient.BadFrames, Seen, FClient.Frame.Player.Stats[StatHealth],
       FClient.Frame.Player.Stats[StatFrags], FClient.PredictionChecks, FClient.PredictionErrors,
       FClient.MaxPredictionError, FClient.Frame.Player.Origin.ToString]);
    Exit;
  end;
  WritelnLog('Demo', 'Clients: %d, players %d, the view sees %d other players',
    [FServer.ClientCount, FWorld.Players.Count, Seen]);
  if FHostBridge <> nil then
  begin
    Frags := '';
    for I := 0 to FHostBridge.PeerCount - 1 do
      Frags := Frags + ' ' + FHostBridge.PeerName(I);
    WritelnLog('Demo', 'Host: %d remote clients (%s), packets in %d out %d',
      [FHostBridge.PeerCount, Trim(Frags), FHostBridge.PacketsIn, FHostBridge.PacketsOut]);
    for I := 0 to FServer.ClientCount - 1 do
      if not FServer.Clients[I].Local then
        WritelnLog('Demo', 'Remote player %d at %s health %d',
          [FServer.Clients[I].Player.Number, FServer.Clients[I].PM.Origin.ToString,
           FServer.Clients[I].Player.Stats.Health]);
  end;
  if Deathmatch then
  begin
    Frags := '';
    for P in FWorld.Players do
    begin
      if Frags <> '' then
        Frags := Frags + ', ';
      Frags := Frags + Format('%s %d', [FWorld.PlayerName(P), P.Frags]);
    end;
    WritelnLog('Demo', 'Deathmatch: dmflags %d, frags %s (the view''s HUD %d)',
      [DMFlags, Frags, FClient.Frame.Player.Stats[StatFrags]]);
  end;
  for I := 0 to FTestClients.Count - 1 do
  begin
    T := FTestClients[I];
    F := T.Client.Frame;
    Seen := 0;
    for S in F.Entities do
      if S.Number <= MaxNetClients then
        Inc(Seen);
    WritelnLog('Demo', 'Client %d: player %d at %s health %d, frames %d (%d bad), sees %d entities and %d other players',
      [I + 1, T.Server.Player.Number, T.Server.PM.Origin.ToString, T.Server.Player.Stats.Health,
       T.Client.FramesReceived, T.Client.BadFrames, Length(F.Entities), Seen]);
    if T.Bot <> nil then
      WritelnLog('Demo', 'Bot %d: %s', [I + 1, T.Bot.Describe(FWorld, T.Server.Player)]);
  end;
end;

procedure TViewPlay.ApplyDemoSync;
var
  Val: Single;
  Old: TVector3;
begin
  if not FDemoSyncPending then
    Exit;
  FDemoSyncPending := False;
  Val := PointsDistance(FDemoSyncOrigin, CgeToQuake(PlayerMovement.AimPosition));
  FDemoMaxDrift := Max(FDemoMaxDrift, Val);
  if Val > 16 then
    WritelnLog('Demo', 'Replay drift %.1f units at %.2f s', [Val, FDemoSyncTime]);
  { Frame timing differs from the recording: put the player back on its
    path (a few units are normal, more is a different outcome); the server
    takes it before the next move }
  if (Val > 2) and not FDemoNoSync then
  begin
    PlayerMovement.ClearViewEffects;
    Old := MainViewport.Camera.Translation;
    MainViewport.Camera.Translation := QuakeToCge(FDemoSyncOrigin);
    { Not into a wall (when the map changed since the recording) }
    if Assigned(EntityTrace) and EntityTrace(PlayerMovement.Origin, PlayerMovement.Origin,
       PlayerMovement.BoxMins, PlayerMovement.BoxMaxs, MASK_PLAYERSOLID, FServer.PM).StartSolid then
      MainViewport.Camera.Translation := Old;
  end;
end;

procedure TViewPlay.CheckSnapshot;
var
  S, C: TNetFrame;
begin
  S := FServer.LastFrame;
  if not S.Valid then
    Exit;
  C := FClient.Frame;
  Inc(FNetChecked);
  if not (C.Valid and (C.ServerFrame = S.ServerFrame) and FramesEqual(C, S)) then
  begin
    Inc(FNetMismatches);
    if FNetMismatches <= 5 then
      WritelnWarning('Net', 'Client snapshot %d differs from the server''s %d (%d / %d entities)',
        [C.ServerFrame, S.ServerFrame, Length(C.Entities), Length(S.Entities)]);
  end;
end;

procedure TViewPlay.RunTicks(const SecondsPassed: Single);
var
  I, Count: Integer;
begin
  Count := FTickClock.AddFrame(SecondsPassed);
  { Join mode: no ticks here (the clock only places the snapshots' models
    between the last two) }
  if FJoinBridge <> nil then
    Exit;
  for I := 1 to Count do
  begin
    FWorld.CollectMovingTransforms(FTickList);
    FTickClock.BeforeTick(FTickList);
    FServer.RunTick(TickSeconds);
    FServer.SendFrame;
    FWorld.CollectMovingTransforms(FTickList);
    FTickClock.AfterTick(FTickList);
    { The frame acts on these first (a new map, a teleport, the intermission) }
    if FWorld.RestartPending or FWorld.TeleportPending or FWorld.LevelExited then
      Break;
  end;
  if Count > 0 then
  begin
    FClient.ReadPackets;
    CheckSnapshot;
  end;
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
const
  WeaponKeys: array[1..10] of TKey = (key1, key2, key3, key4, key5, key6, key7, key8, key9, key0);
var
  Slot: Integer;
  MenuEvent: TInputPressRelease;
  PadAction: TPadAction;
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
    { The raw event: the Gamepad page binds controller buttons }
    if Menu.Press(Event) then
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
    if not Settings.PadActionOf(Event.Controller.Button, PadAction) then
      Exit(False);
    case PadAction of
      QuakeSettings.paUse: DoUse;
      QuakeSettings.paGrenade: DoSelectWeapon(FWorld.ChainedWeapon(11)); { hand grenades / traps }
      QuakeSettings.paHelp: DoToggleHelp;
      else Exit(False); { jump / crouch are held: ReadGamepads }
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
      DoSelectWeapon(FWorld.ChainedWeapon(Slot));
      Exit(True);
    end;
  if Event.IsKey(Settings.Keys[qaGrenade]) then
  begin
    DoSelectWeapon(FWorld.ChainedWeapon(11)); { hand grenades / traps }
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

  { Commands that change the game run on the server (cheats, spawns, tests),
    in order with the moves and the other commands }
  if (Cmd = 'spawn') or (Cmd = 'hurt') or (Cmd = 'god') or (Cmd = 'give') or
     (Cmd = 'powerarmor') or (Cmd = 'notarget') or (Cmd = 'kill') then
    FClient.AddCommand(Trim(Cmd + ' ' + Args))
  else
  if (Cmd = 'addclient') or (Cmd = 'addbot') or (Cmd = 'clientinput') or (Cmd = 'removeclient') or (Cmd = 'clientgoto') then
    TestClientCommand(Cmd, Args)
  else
  if Cmd = 'host' then
    { host [port]: other instances may join (UDP) }
    StartHosting(StrToIntDef(Trim(Args), DefaultNetPort))
  else
  if Cmd = 'connect' then
  begin
    { connect <address[:port]>: join another instance's game }
    if Trim(Args) = '' then
      Console.Print('Usage: connect <address[:port]>')
    else
      StartJoining(Trim(Args));
  end else
  if Cmd = 'clientdraw' then
  begin
    { clientdraw [0|1]: the client draws the models from the snapshots }
    if Args = '' then
      FClientScene.Enabled := not FClientScene.Enabled
    else
      FClientScene.Enabled := Args <> '0';
    Hud.ShowMessage('clientdraw ' + Iff(FClientScene.Enabled, 'ON', 'OFF'), 2);
  end else
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
  if Cmd = 'compass' then
  begin
    { The remaster's compass: show the point of interest for 5 seconds }
    if FWorld.PoiValid then
      FCompassTime := 5
    else
      Hud.ShowMessage('No point of interest', 2);
  end else
  if Cmd = 'renderscale' then
  begin
    { renderscale [25..100]: percent of the window's resolution the 3D view
      is drawn at (Options -> Render Scale) }
    if Args <> '' then
    begin
      Settings.RenderScale := EnsureRange(StrToIntDef(Args, Settings.RenderScale), MinRenderScale, MaxRenderScale);
      RenderScaleOverride := 0;
      Settings.Save;
    end;
    Hud.ShowMessage(Format('renderscale %d', [RenderScale]), 2);
  end else
  if Cmd = 'horplus' then
  begin
    { horplus [0|1]: Hor+ widescreen field of view (Options -> Widescreen View) }
    if Args = '' then
      Settings.WidescreenFov := not Settings.WidescreenFov
    else
      Settings.WidescreenFov := Args <> '0';
    Settings.Save;
    ApplySettings;
    Hud.ShowMessage('horplus ' + Iff(Settings.WidescreenFov, 'ON', 'OFF'), 2);
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
  if Cmd = 'padbind' then
    PadBindCommand(Args)
  else
  if Cmd = 'deathmatch' then
  begin
    { Quake 2's latched cvar: takes effect when a map is (re)loaded }
    if Args <> '' then
      Deathmatch := StrToIntDef(Args, 0) <> 0;
    Console.Print(Format('deathmatch %d, applies to the next map', [Ord(Deathmatch)]));
  end else
  if Cmd = 'dmflags' then
  begin
    if Args <> '' then
      DMFlags := StrToIntDef(Args, DMFlags);
    Console.Print(Format('dmflags %d', [DMFlags]));
  end else
  if Cmd = 'skill' then
  begin
    { Like Quake 2: takes effect when a map is (re)loaded }
    if Args <> '' then
      GameSkill := EnsureRange(StrToIntDef(Args, GameSkill), 0, 3);
    Console.Print(Format('skill %d (%s), applies to the next map', [GameSkill, SkillNames[GameSkill]]));
  end else
  if Cmd = 'noclip' then
  begin
    if FCameraMode = cmFirstPerson then
      SetCameraMode(cmNoclip)
    else
      SetCameraMode(cmFirstPerson);
  end else
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
    Console.Print('  give <item>  - Any item by name, e.g. give power shield');
    Console.Print('  powerarmor   - Switch the power screen / shield on or off');
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
