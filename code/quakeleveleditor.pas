{ In-game level editor: a top-down view of a TQuakeLevel grid to paint
  walls and floors, raise / lower floors and ceilings, open cells to the
  sky, set texture themes and place entities (player start, lights,
  monsters, items, barrels, the exit). It generates random levels, saves /
  loads them (castle-config:/levels/<name>.json), plays them at once
  (OnPlay: TViewPlay compiles the level with QuakeBspBuilder and loads it)
  and exports the compiled .bsp (castle-config:/maps/<name>.bsp).

  Mouse: left paints with the tool, right erases (wall / entity), middle
  (or Alt + left) picks a cell's heights and theme; drag paints. Keys:
  1..0 tools, PageUp / PageDown floor, Home / End ceiling, T theme, Q / E
  turn the entity, [ / ] entity type, arrows / WASD pan, + / - / wheel
  zoom, Ctrl+Z undo, G generate, P play, Ctrl+S save, L load next,
  Escape close.

  A registered component: it can be placed in a design and shows its
  level in the CGE editor too (LevelUrl). }
unit QuakeLevelEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections,
  CastleVectors, CastleUIControls, CastleKeysMouse, CastleRectangles, CastleColors, CastleClassUtils,
  QuakeLevel;

type
  TLevelEditTool = (etFloor, etWall, etRaise, etLower, etCeilUp, etCeilDown, etSky, etTheme,
    etEntity, etErase, etDoor, etWater, etLift, etButton, etSlime, etKeyDoor, etLava, etLadder, etHills);
  TLevelEditCommand = (ecNew, ecGenerate, ecSave, ecLoad, ecPlay, ecExport, ecClose);

  TLevelEditorEvent = procedure(const Level: TQuakeLevel) of object;

  TQuakeLevelEditor = class(TCastleUserInterface)
  strict private
    FLevel: TQuakeLevel;
    FTool: TLevelEditTool;
    FBrushFloor, FBrushCeil, FBrushTheme, FBrushWater, FBrushLift, FBrushChannel: Integer;
    { Key of the Key tool's doors: 1 blue, 2 red }
    FBrushKey: Integer;
    FEntityIndex: Integer;
    FEntityAngle: Single;
    FZoom: Single;
    FPan: TVector2;
    FHover: TPoint;
    FPainting: Boolean;
    FPaintErase: Boolean;
    FLastPaint: TPoint;
    FStrokeCells: specialize TList<Integer>;
    FUndo: TStringList;
    FStatus: String;
    FStatusTime: Single;
    FLevelUrl: String;
    FOnPlay, FOnClose: TLevelEditorEvent;
    FLoadIndex: Integer;
    function Scale: Single;
    function ToolbarRect: TFloatRectangle;
    function StatusRect: TFloatRectangle;
    function PaletteRect: TFloatRectangle;
    function GridRect: TFloatRectangle;
    function ToolButtonRect(const Index: Integer): TFloatRectangle;
    function CommandButtonRect(const Index: Integer): TFloatRectangle;
    function PaletteRowRect(const Index: Integer): TFloatRectangle;
    function CellRect(const X, Y: Integer): TFloatRectangle;
    function CellAtScreen(const P: TVector2; out X, Y: Integer): Boolean;
    procedure SetLevelUrl(const Value: String);
    procedure PushUndo;
    procedure ApplyTool(const X, Y: Integer; const Erase: Boolean);
    procedure PickCell(const X, Y: Integer);
    procedure FitView;
    function SafeName: String;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Render; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;
    { Run a toolbar command (also from the console: "editor <command>") }
    procedure RunCommand(const Command: TLevelEditCommand);
    { A room to start from (New) }
    procedure NewLevel;
    procedure Generate(const Seed: Cardinal);
    procedure SaveLevel;
    function LoadLevel(const AName: String): Boolean;
    function ExportBsp: String;
    procedure ShowStatus(const Text: String);
    { Apply the current tool to every cell of a rectangle (scripts) }
    procedure FillRect(const X0, Y0, X1, Y1: Integer);
    { Saved level names (castle-config:/levels) }
    function SavedLevels: TStringList;
    property Level: TQuakeLevel read FLevel;
    property Tool: TLevelEditTool read FTool write FTool;
    property BrushFloor: Integer read FBrushFloor write FBrushFloor;
    property BrushCeil: Integer read FBrushCeil write FBrushCeil;
    property BrushTheme: Integer read FBrushTheme write FBrushTheme;
    property EntityIndex: Integer read FEntityIndex write FEntityIndex;
    property BrushLift: Integer read FBrushLift write FBrushLift;
    property BrushChannel: Integer read FBrushChannel write FBrushChannel;
    property BrushKey: Integer read FBrushKey write FBrushKey;
    property OnPlay: TLevelEditorEvent read FOnPlay write FOnPlay;
    property OnClose: TLevelEditorEvent read FOnClose write FOnClose;
  published
    { A level JSON to show (e.g. in the CGE editor); '' keeps the current }
    property LevelUrl: String read FLevelUrl write SetLevelUrl;
  end;

const
  ToolNames: array[TLevelEditTool] of String = ('Floor', 'Wall', 'Raise', 'Lower', 'Ceil+', 'Ceil-',
    'Sky', 'Theme', 'Entity', 'Erase', 'Door', 'Water', 'Lift', 'Button', 'Slime', 'Key', 'Lava', 'Ladder', 'Hills');
  ToolKeys: array[TLevelEditTool] of String = ('1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'O', 'U',
    'H', 'J', 'M', 'K', 'I', 'R', '');
  CommandNames: array[TLevelEditCommand] of String = ('New', 'Generate', 'Save', 'Load', 'Play',
    'Export', 'Close');
  { What the Entity tool places; "exit" is a trigger with a changelevel }
  EditorEntityClasses: array[0..35] of String = (
    'info_player_start', 'light', 'exit',
    'monster_soldier_light', 'monster_soldier', 'monster_soldier_ss', 'monster_infantry',
    'monster_gunner', 'monster_berserk', 'monster_flyer', 'monster_parasite', 'monster_tank',
    'weapon_shotgun', 'weapon_supershotgun', 'weapon_machinegun', 'weapon_chaingun',
    'weapon_grenadelauncher', 'weapon_rocketlauncher', 'weapon_hyperblaster', 'weapon_railgun',
    'ammo_shells', 'ammo_bullets', 'ammo_grenades', 'ammo_rockets', 'ammo_cells', 'ammo_slugs',
    'item_health', 'item_health_large', 'item_health_mega', 'item_armor_jacket', 'item_armor_combat',
    'misc_explobox', 'key_blue_key', 'key_red_key', 'misc_teleporter', 'misc_teleporter_dest');

{ Place an editor entity class at a cell (the exit adds its trigger and
  changelevel) }
procedure PlaceEditorEntity(const Level: TQuakeLevel; const AClass: String; const X, Y: Integer;
  const Angle: Single);
{ Remove the entities in a cell (and the exit's partner) }
procedure RemoveCellEntities(const Level: TQuakeLevel; const X, Y: Integer);

implementation

uses
  Math, StrUtils, CastleGLUtils, CastleControls, CastleComponentSerialize, CastleLog, CastleUriUtils,
  CastleFilesUtils, CastleFindFiles, CastleDownload,
  QuakeSettings, QuakeLevelGen, QuakeBspBuilder;

const
  EntityColors: array[0..5] of TCastleColor = (
    (X: 0.2; Y: 1.0; Z: 0.3; W: 1), { player }
    (X: 1.0; Y: 0.9; Z: 0.3; W: 1), { light }
    (X: 1.0; Y: 0.25; Z: 0.2; W: 1), { monster }
    (X: 0.3; Y: 0.7; Z: 1.0; W: 1), { item }
    (X: 0.9; Y: 0.4; Z: 1.0; W: 1), { trigger }
    (X: 1.0; Y: 0.6; Z: 0.2; W: 1)  { other }
  );
  ThemeTints: array[0..3] of TVector3 = (
    (X: 0.62; Y: 0.5; Z: 0.38),
    (X: 0.5; Y: 0.55; Z: 0.62),
    (X: 0.45; Y: 0.62; Z: 0.42),
    (X: 0.42; Y: 0.6; Z: 0.62)
  );

function EntityKind(const AClass: String): Integer;
begin
  if Copy(AClass, 1, 12) = 'info_player_' then
    Result := 0
  else
  if AClass = 'light' then
    Result := 1
  else
  if Copy(AClass, 1, 8) = 'monster_' then
    Result := 2
  else
  if (Copy(AClass, 1, 5) = 'item_') or (Copy(AClass, 1, 7) = 'weapon_') or (Copy(AClass, 1, 5) = 'ammo_') then
    Result := 3
  else
  if (Copy(AClass, 1, 8) = 'trigger_') or (Copy(AClass, 1, 7) = 'target_') then
    Result := 4
  else
    Result := 5;
end;

function EntityLetter(const AClass: String): String;
var
  P: Integer;
begin
  if AClass = 'info_player_start' then
    Exit('P');
  if AClass = 'trigger_once' then
    Exit('X');
  P := Pos('_', AClass);
  if P > 0 then
    Result := UpperCase(Copy(AClass, P + 1, 1))
  else
    Result := UpperCase(Copy(AClass, 1, 1));
end;

procedure RemoveCellEntities(const Level: TQuakeLevel; const X, Y: Integer);
var
  I, CX, CY: Integer;
begin
  for I := Level.Entities.Count - 1 downto 0 do
  begin
    Level.CellAt(Level.Entities[I].Origin, CX, CY);
    if (CX = X) and (CY = Y) then
      Level.Entities.Delete(I);
  end;
end;

procedure PlaceEditorEntity(const Level: TQuakeLevel; const AClass: String; const X, Y: Integer;
  const Angle: Single);
var
  E: TLevelEntity;
  Org: TVector3;
  I: Integer;
begin
  if Level.Cell(X, Y)^.Solid then
    Exit;
  RemoveCellEntities(Level, X, Y);
  if AClass = 'info_player_start' then
    for I := Level.Entities.Count - 1 downto 0 do
      if Level.Entities[I].EntClass = 'info_player_start' then
        Level.Entities.Delete(I);
  if AClass = 'exit' then
  begin
    Org := Level.CellFloorCenter(X, Y);
    E := Level.AddEntity('trigger_once', Org);
    E.SetKey('target', Format('exit_%d_%d', [X, Y]));
    E.SetKey('mins', '-32 -32 0');
    E.SetKey('maxs', '32 32 96');
    E := Level.AddEntity('target_changelevel', Org + Vector3(0, 0, 32));
    E.SetKey('targetname', Format('exit_%d_%d', [X, Y]));
    E.SetKey('map', RandomMapName(Max(1, Level.Seed) + 1));
    E.SetKey('message', 'Exit');
    Exit;
  end;
  Level.AddEntityAtCell(AClass, X, Y, Angle);
end;

{ TQuakeLevelEditor }

constructor TQuakeLevelEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FLevel := TQuakeLevel.Create(32, 32);
  FStrokeCells := specialize TList<Integer>.Create;
  FUndo := TStringList.Create;
  FBrushFloor := 0;
  FBrushCeil := 160;
  FBrushWater := 48;
  FBrushLift := 96;
  FBrushKey := 1;
  FZoom := 20;
  FHover := Point(-1, -1);
  FLoadIndex := -1;
  NewLevel;
end;

destructor TQuakeLevelEditor.Destroy;
begin
  FreeAndNil(FLevel);
  FreeAndNil(FStrokeCells);
  FreeAndNil(FUndo);
  inherited Destroy;
end;

function TQuakeLevelEditor.PropertySections(const PropertyName: String): TPropertySections;
begin
  if PropertyName = 'LevelUrl' then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

function TQuakeLevelEditor.Scale: Single;
begin
  Result := UIScale * InterfaceScale;
end;

function TQuakeLevelEditor.ToolbarRect: TFloatRectangle;
var
  R: TFloatRectangle;
begin
  R := RenderRect;
  Result := FloatRectangle(R.Left, R.Top - 84 * Scale, R.Width, 84 * Scale);
end;

function TQuakeLevelEditor.StatusRect: TFloatRectangle;
var
  R: TFloatRectangle;
begin
  R := RenderRect;
  Result := FloatRectangle(R.Left, R.Bottom, R.Width, 30 * Scale);
end;

function TQuakeLevelEditor.PaletteRect: TFloatRectangle;
var
  R: TFloatRectangle;
begin
  R := RenderRect;
  Result := FloatRectangle(R.Right - 250 * Scale, StatusRect.Top, 250 * Scale,
    ToolbarRect.Bottom - StatusRect.Top);
end;

function TQuakeLevelEditor.GridRect: TFloatRectangle;
var
  R: TFloatRectangle;
begin
  R := RenderRect;
  Result := FloatRectangle(R.Left, StatusRect.Top, PaletteRect.Left - R.Left, ToolbarRect.Bottom - StatusRect.Top);
end;

function TQuakeLevelEditor.ToolButtonRect(const Index: Integer): TFloatRectangle;
var
  W: Single;
begin
  W := ToolbarRect.Width / (Ord(High(TLevelEditTool)) + 1);
  Result := FloatRectangle(ToolbarRect.Left + Index * W + 2 * Scale, ToolbarRect.Bottom + 44 * Scale,
    W - 4 * Scale, 36 * Scale);
end;

function TQuakeLevelEditor.CommandButtonRect(const Index: Integer): TFloatRectangle;
var
  W: Single;
begin
  W := ToolbarRect.Width / (Ord(High(TLevelEditCommand)) + 1);
  Result := FloatRectangle(ToolbarRect.Left + Index * W + 2 * Scale, ToolbarRect.Bottom + 4 * Scale,
    W - 4 * Scale, 36 * Scale);
end;

function TQuakeLevelEditor.PaletteRowRect(const Index: Integer): TFloatRectangle;
var
  P: TFloatRectangle;
  H: Single;
begin
  P := PaletteRect;
  H := Min(26 * Scale, (P.Height - 8 * Scale) / Length(EditorEntityClasses));
  Result := FloatRectangle(P.Left + 4 * Scale, P.Top - 4 * Scale - (Index + 1) * H, P.Width - 8 * Scale, H);
end;

function TQuakeLevelEditor.CellRect(const X, Y: Integer): TFloatRectangle;
var
  G: TFloatRectangle;
begin
  G := GridRect;
  Result := FloatRectangle(G.Left + (X - FPan.X) * FZoom, G.Bottom + (Y - FPan.Y) * FZoom, FZoom, FZoom);
end;

function TQuakeLevelEditor.CellAtScreen(const P: TVector2; out X, Y: Integer): Boolean;
var
  G: TFloatRectangle;
begin
  G := GridRect;
  X := Floor((P.X - G.Left) / FZoom + FPan.X);
  Y := Floor((P.Y - G.Bottom) / FZoom + FPan.Y);
  Result := G.Contains(P) and FLevel.InGrid(X, Y);
end;

procedure TQuakeLevelEditor.FitView;
var
  G: TFloatRectangle;
begin
  G := GridRect;
  if (G.Width <= 0) or (G.Height <= 0) then
    Exit;
  FZoom := Max(4, Min(G.Width / FLevel.Width, G.Height / FLevel.Height));
  FPan := Vector2((FLevel.Width - G.Width / FZoom) / 2, (FLevel.Height - G.Height / FZoom) / 2);
end;

procedure TQuakeLevelEditor.SetLevelUrl(const Value: String);
begin
  FLevelUrl := Value;
  if Value = '' then
    Exit;
  try
    FLevel.LoadFromFile(Value);
    FitView;
  except
    on E: Exception do
      WritelnWarning('QuakeLevelEditor', 'Cannot load level "%s": %s', [Value, E.Message]);
  end;
end;

procedure TQuakeLevelEditor.ShowStatus(const Text: String);
begin
  FStatus := Text;
  FStatusTime := 4;
  WritelnLog('LevelEditor', Text);
end;

procedure TQuakeLevelEditor.PushUndo;
var
  Stream: TStringStream;
begin
  Stream := TStringStream.Create('');
  try
    FLevel.SaveToStream(Stream);
    FUndo.Add(Stream.DataString);
    while FUndo.Count > 40 do
      FUndo.Delete(0);
  finally
    Stream.Free;
  end;
end;

procedure TQuakeLevelEditor.NewLevel;
var
  X, Y: Integer;
  OldName: String;
begin
  OldName := FLevel.Name;
  FLevel.Resize(32, 32);
  FLevel.Name := OldName;
  if (FLevel.Name = '') or (FLevel.Name = 'level') then
    FLevel.Name := 'mylevel';
  FLevel.Message := 'Custom level';
  FLevel.Seed := 0;
  { A first room with a start and a light }
  for Y := 12 to 19 do
    for X := 12 to 19 do
      FLevel.SetOpen(X, Y, 0, 192);
  PlaceEditorEntity(FLevel, 'info_player_start', 14, 15, 0);
  PlaceEditorEntity(FLevel, 'light', 16, 16, 0);
  FLevel.Entities.Last.SetKey('light', '350');
  FitView;
end;

procedure TQuakeLevelEditor.Generate(const Seed: Cardinal);
var
  Gen: TQuakeLevel;
  Stream: TStringStream;
  OldName: String;
begin
  PushUndo;
  OldName := FLevel.Name;
  Gen := GenerateLevel(Seed);
  Stream := TStringStream.Create('');
  try
    Gen.SaveToStream(Stream);
    Stream.Position := 0;
    FLevel.LoadFromStream(Stream);
  finally
    Stream.Free;
    Gen.Free;
  end;
  { Keep the editor's name: playing / saving it doesn't replace rand<seed> }
  FLevel.Name := OldName;
  FitView;
  ShowStatus(Format('Generated random level %d (%d open cells, %d entities)',
    [Seed, FLevel.OpenCellCount, FLevel.Entities.Count]));
end;

function TQuakeLevelEditor.SafeName: String;
var
  I: Integer;
  Seed: Cardinal;
begin
  Result := LowerCase(FLevel.Name);
  for I := 1 to Length(Result) do
    if not (Result[I] in ['a'..'z', '0'..'9', '_']) then
      Result[I] := '_';
  if Result = '' then
    Result := 'mylevel';
  { Not a name the generator or the PAKs own }
  if IsRandomMapName(Result, Seed) or ((Pos('demo', Result) = 1) and (Length(Result) <= 5)) then
    Result := 'custom_' + Result;
  FLevel.Name := Result;
end;

procedure TQuakeLevelEditor.SaveLevel;
var
  Url: String;
begin
  SafeName;
  Url := LevelFileUrl(FLevel.Name);
  try
    FLevel.SaveToFile(Url);
    ShowStatus('Saved ' + Url);
  except
    on E: Exception do
      ShowStatus('Cannot save: ' + E.Message);
  end;
end;

function TQuakeLevelEditor.SavedLevels: TStringList;
var
  Found: TFileInfoList;
  Info: TFileInfo;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  try
    Found := FindFilesList('castle-config:/levels/', '*.json', False, []);
    try
      for Info in Found do
        Result.Add(ChangeFileExt(Info.Name, ''));
    finally
      Found.Free;
    end;
  except
    { no levels directory yet }
  end;
end;

function TQuakeLevelEditor.LoadLevel(const AName: String): Boolean;
begin
  Result := False;
  try
    PushUndo;
    FLevel.LoadFromFile(LevelFileUrl(AName));
    FLevel.Name := LowerCase(AName);
    FitView;
    ShowStatus('Loaded ' + LevelFileUrl(AName));
    Result := True;
  except
    on E: Exception do
      ShowStatus('Cannot load "' + AName + '": ' + E.Message);
  end;
end;

function TQuakeLevelEditor.ExportBsp: String;
var
  Stream: TMemoryStream;
  Stats: TBspBuildStats;
  Out: TStream;
begin
  Result := '';
  SafeName;
  try
    Stream := BuildLevelBsp(FLevel, Stats);
    try
      Result := 'castle-config:/maps/' + FLevel.Name + '.bsp';
      Out := UrlSaveStream(Result);
      try
        Stream.Position := 0;
        Out.CopyFrom(Stream, Stream.Size);
      finally
        Out.Free;
      end;
    finally
      Stream.Free;
    end;
    ShowStatus(Format('Exported %s (%d faces, %d brushes); path %s',
      [Result, Stats.Faces, Stats.Brushes, UriToFilenameSafe(Result)]));
  except
    on E: Exception do
    begin
      ShowStatus('Cannot export: ' + E.Message);
      Result := '';
    end;
  end;
end;

procedure TQuakeLevelEditor.RunCommand(const Command: TLevelEditCommand);
var
  Names: TStringList;
begin
  case Command of
    ecNew:
      begin
        PushUndo;
        NewLevel;
        ShowStatus('New level');
      end;
    ecGenerate:
      Generate(1 + Random(999999));
    ecSave:
      SaveLevel;
    ecLoad:
      begin
        { The next saved level, in name order }
        Names := SavedLevels;
        try
          if Names.Count = 0 then
            ShowStatus('No saved levels in castle-config:/levels/')
          else
          begin
            FLoadIndex := (FLoadIndex + 1) mod Names.Count;
            LoadLevel(Names[FLoadIndex]);
          end;
        finally
          Names.Free;
        end;
      end;
    ecPlay:
      begin
        SafeName;
        if Assigned(FOnPlay) then
          FOnPlay(FLevel);
      end;
    ecExport:
      ExportBsp;
    ecClose:
      if Assigned(FOnClose) then
        FOnClose(FLevel)
      else
        Exists := False;
  end;
end;

procedure TQuakeLevelEditor.FillRect(const X0, Y0, X1, Y1: Integer);
var
  X, Y: Integer;
begin
  PushUndo;
  FStrokeCells.Clear;
  for Y := Min(Y0, Y1) to Max(Y0, Y1) do
    for X := Min(X0, X1) to Max(X0, X1) do
      ApplyTool(X, Y, False);
  FStrokeCells.Clear;
end;

procedure TQuakeLevelEditor.PickCell(const X, Y: Integer);
var
  C: PLevelCell;
begin
  C := FLevel.Cell(X, Y);
  if C^.Solid then
    Exit;
  FBrushFloor := C^.Floor;
  FBrushCeil := C^.Ceil;
  FBrushTheme := C^.Theme;
  ShowStatus(Format('Picked floor %d ceiling %d theme %s', [FBrushFloor, FBrushCeil, LevelThemes[FBrushTheme].Name]));
end;

procedure TQuakeLevelEditor.ApplyTool(const X, Y: Integer; const Erase: Boolean);
var
  C: PLevelCell;
  Key: Integer;
begin
  if (X <= 0) or (Y <= 0) or (X >= FLevel.Width - 1) or (Y >= FLevel.Height - 1) then
    Exit; { the border stays solid }
  Key := Y * FLevel.Width + X;
  { Step tools change a cell once per stroke }
  if FStrokeCells.IndexOf(Key) >= 0 then
    Exit;
  FStrokeCells.Add(Key);
  C := FLevel.Cell(X, Y);
  if Erase then
  begin
    if FTool in [etEntity, etErase] then
      RemoveCellEntities(FLevel, X, Y)
    else
    begin
      C^.Solid := True;
      RemoveCellEntities(FLevel, X, Y);
    end;
    Exit;
  end;
  case FTool of
    etFloor:
      FLevel.SetOpen(X, Y, FBrushFloor, Max(FBrushCeil, FBrushFloor + LevelMinHeadroom), FBrushTheme);
    etWall:
      begin
        C^.Solid := True;
        RemoveCellEntities(FLevel, X, Y);
      end;
    etRaise:
      if not C^.Solid then
      begin
        C^.Floor := C^.Floor + LevelHeightStep;
        C^.Ceil := Max(C^.Ceil, C^.Floor + LevelMinHeadroom);
      end;
    etLower:
      if not C^.Solid then
        C^.Floor := C^.Floor - LevelHeightStep;
    etCeilUp:
      if not C^.Solid then
        C^.Ceil := C^.Ceil + LevelHeightStep;
    etCeilDown:
      if not C^.Solid then
        C^.Ceil := Max(C^.Floor + LevelMinHeadroom, C^.Ceil - LevelHeightStep);
    etSky:
      if not C^.Solid then
        C^.Sky := not C^.Sky;
    etTheme:
      if not C^.Solid then
        C^.Theme := FBrushTheme;
    etEntity:
      PlaceEditorEntity(FLevel, EditorEntityClasses[FEntityIndex], X, Y, FEntityAngle);
    etErase:
      RemoveCellEntities(FLevel, X, Y);
    etDoor:
      if not C^.Solid then
      begin
        { A door (of the brush channel: 0 opens by itself) or none again }
        C^.Door := not C^.Door;
        if C^.Door then
        begin
          C^.Sky := False;
          C^.Wet := False;
          C^.Lift := False;
          C^.Button := False;
          C^.Channel := FBrushChannel;
          C^.Key := 0;
        end else
          C^.Channel := 0;
      end;
    etKeyDoor:
      if not C^.Solid then
      begin
        { A door locked with the brush key (Y switches blue / red) or none }
        if C^.Door and (C^.Key > 0) then
        begin
          C^.Door := False;
          C^.Key := 0;
        end else
        begin
          C^.Door := True;
          C^.Key := EnsureRange(FBrushKey, 1, High(LevelKeyClasses));
          C^.Channel := 0;
          C^.Sky := False;
          C^.Wet := False;
          C^.Lift := False;
          C^.Button := False;
        end;
      end;
    etLava:
      if not C^.Solid then
      begin
        { Lava FBrushWater deep (or none again) }
        if CellHasWater(C) then
          C^.Wet := False
        else
        begin
          C^.Wet := True;
          C^.Lava := True;
          C^.Slime := False;
          C^.Water := Min(C^.Floor + FBrushWater, C^.Ceil - 8);
          C^.Door := False;
          C^.Ladder := False;
        end;
      end;
    etLadder:
      if not C^.Solid then
      begin
        { A ladder up the highest neighbouring step (or none again) }
        C^.Ladder := not C^.Ladder;
        if C^.Ladder then
        begin
          C^.Door := False;
          C^.Lift := False;
          C^.Button := False;
          C^.Wet := False;
        end;
      end;
    etHills:
      if not C^.Solid then
      begin
        { Rolling ground around the brush floor (TerrainHeight, the same
          everywhere for a cell, so neighbouring strokes fit together) }
        C^.Floor := FBrushFloor + TerrainHeight(X, Y);
        C^.Ceil := Max(C^.Ceil, C^.Floor + LevelMinHeadroom);
      end;
    etSlime:
      if not C^.Solid then
      begin
        { Slime FBrushWater deep (or none again) }
        if CellHasWater(C) then
          C^.Wet := False
        else
        begin
          C^.Wet := True;
          C^.Slime := True;
          C^.Lava := False;
          C^.Water := Min(C^.Floor + FBrushWater, C^.Ceil - 8);
          C^.Door := False;
        end;
      end;
    etLift:
      if not C^.Solid then
      begin
        { A lift from the floor up FBrushLift (or none again) }
        C^.Lift := not C^.Lift;
        if C^.Lift then
        begin
          C^.LiftTop := C^.Floor + FBrushLift;
          C^.Ceil := Max(C^.Ceil, C^.LiftTop + LevelMinHeadroom);
          C^.Door := False;
          C^.Wet := False;
          C^.Button := False;
        end;
      end;
    etButton:
      if not C^.Solid then
      begin
        { A button of the brush channel (1 when 0) or none again }
        C^.Button := not C^.Button;
        if C^.Button then
        begin
          C^.Channel := Max(1, FBrushChannel);
          C^.Door := False;
          C^.Lift := False;
          C^.Wet := False;
          RemoveCellEntities(FLevel, X, Y);
        end else
          C^.Channel := 0;
      end;
    etWater:
      if not C^.Solid then
      begin
        { Water FBrushWater deep (or none again) }
        if CellHasWater(C) then
          C^.Wet := False
        else
        begin
          C^.Wet := True;
          C^.Slime := False;
          C^.Lava := False;
          C^.Water := Min(C^.Floor + FBrushWater, C^.Ceil - 8);
          C^.Door := False;
        end;
      end;
  end;
end;

procedure TQuakeLevelEditor.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited Update(SecondsPassed, HandleInput);
  if FStatusTime > 0 then
    FStatusTime := FStatusTime - SecondsPassed;
  if Exists then
    HandleInput := False;
end;

function TQuakeLevelEditor.Press(const Event: TInputPressRelease): Boolean;
var
  X, Y, I: Integer;
  T: TLevelEditTool;
  Cmd: TLevelEditCommand;
  Stream: TStringStream;
  P: TVector2;
  Old: Single;
begin
  Result := inherited Press(Event);
  if Result or not Exists then
    Exit;
  Result := True;
  if Event.EventType = itMouseButton then
  begin
    P := Event.Position;
    for T := Low(TLevelEditTool) to High(TLevelEditTool) do
      if ToolButtonRect(Ord(T)).Contains(P) then
      begin
        FTool := T;
        ShowStatus('Tool: ' + ToolNames[T]);
        Exit;
      end;
    for Cmd := Low(TLevelEditCommand) to High(TLevelEditCommand) do
      if CommandButtonRect(Ord(Cmd)).Contains(P) then
      begin
        RunCommand(Cmd);
        Exit;
      end;
    for I := 0 to High(EditorEntityClasses) do
      if PaletteRowRect(I).Contains(P) then
      begin
        FEntityIndex := I;
        FTool := etEntity;
        ShowStatus('Entity: ' + EditorEntityClasses[I]);
        Exit;
      end;
    if CellAtScreen(P, X, Y) then
    begin
      if (Event.MouseButton = buttonMiddle) or ((Event.MouseButton = buttonLeft) and (mkAlt in Event.ModifiersDown)) then
      begin
        PickCell(X, Y);
        Exit;
      end;
      PushUndo;
      FPainting := True;
      FPaintErase := Event.MouseButton = buttonRight;
      FStrokeCells.Clear;
      ApplyTool(X, Y, FPaintErase);
      FLastPaint := Point(X, Y);
    end;
    Exit;
  end;
  if Event.EventType = itMouseWheel then
  begin
    Old := FZoom;
    if Event.MouseWheelScroll > 0 then
      FZoom := Min(80, FZoom * 1.2)
    else
      FZoom := Max(4, FZoom / 1.2);
    { Zoom around the middle of the grid }
    FPan := FPan + Vector2(GridRect.Width, GridRect.Height) * (1 / Old - 1 / FZoom) / 2;
    Exit;
  end;
  if Event.EventType <> itKey then
    Exit;

  if Event.IsKey(keyEscape) then
    RunCommand(ecClose)
  else
  if Event.IsKey(keyZ) and (mkCtrl in Event.ModifiersDown) then
  begin
    if FUndo.Count > 0 then
    begin
      Stream := TStringStream.Create(FUndo[FUndo.Count - 1]);
      try
        FLevel.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      FUndo.Delete(FUndo.Count - 1);
      ShowStatus('Undo');
    end;
  end else
  if Event.IsKey(keyS) and (mkCtrl in Event.ModifiersDown) then
    RunCommand(ecSave)
  else
  if (Ord(Event.Key) >= Ord(key1)) and (Ord(Event.Key) <= Ord(key9)) then
    FTool := TLevelEditTool(Min(Ord(Event.Key) - Ord(key1), Ord(High(TLevelEditTool))))
  else
  if Event.IsKey(key0) then
    FTool := etErase
  else
  if Event.IsKey(keyPageUp) then
    FBrushFloor := FBrushFloor + LevelHeightStep
  else
  if Event.IsKey(keyPageDown) then
    FBrushFloor := FBrushFloor - LevelHeightStep
  else
  if Event.IsKey(keyHome) then
    FBrushCeil := FBrushCeil + LevelHeightStep
  else
  if Event.IsKey(keyEnd) then
    FBrushCeil := Max(FBrushFloor + LevelMinHeadroom, FBrushCeil - LevelHeightStep)
  else
  if Event.IsKey(keyT) then
    FBrushTheme := (FBrushTheme + 1) mod Length(LevelThemes)
  else
  if Event.IsKey(keyO) then
    FTool := etDoor
  else
  if Event.IsKey(keyU) then
    FTool := etWater
  else
  if Event.IsKey(keyH) then
    FTool := etLift
  else
  if Event.IsKey(keyJ) then
    FTool := etButton
  else
  if Event.IsKey(keyM) then
    FTool := etSlime
  else
  if Event.IsKey(keyK) then
    FTool := etKeyDoor
  else
  if Event.IsKey(keyI) then
    FTool := etLava
  else
  if Event.IsKey(keyR) then
    FTool := etLadder
  else
  if Event.IsKey(keyY) then
    FBrushKey := FBrushKey mod High(LevelKeyClasses) + 1
  else
  if Event.IsKey(keyC) then
    FBrushChannel := (FBrushChannel + 1) mod 10
  else
  if Event.IsKey(keyPeriod) then
    FBrushLift := FBrushLift + LevelHeightStep
  else
  if Event.IsKey(keyComma) then
    FBrushLift := Max(LevelHeightStep * 2, FBrushLift - LevelHeightStep)
  else
  if Event.IsKey(keyV) then
    FBrushWater := FBrushWater + 8
  else
  if Event.IsKey(keyB) then
    FBrushWater := Max(8, FBrushWater - 8)
  else
  if Event.IsKey(keyQ) then
    FEntityAngle := Round(FEntityAngle + 45) mod 360
  else
  if Event.IsKey(keyE) then
    FEntityAngle := Round(FEntityAngle + 315) mod 360
  else
  if Event.IsKey(keyRightBracket) then
    FEntityIndex := (FEntityIndex + 1) mod Length(EditorEntityClasses)
  else
  if Event.IsKey(keyLeftBracket) then
    FEntityIndex := (FEntityIndex + Length(EditorEntityClasses) - 1) mod Length(EditorEntityClasses)
  else
  if Event.IsKey(keyArrowLeft) or Event.IsKey(keyA) then
    FPan.X := FPan.X - 2
  else
  if Event.IsKey(keyArrowRight) or Event.IsKey(keyD) then
    FPan.X := FPan.X + 2
  else
  if Event.IsKey(keyArrowUp) or Event.IsKey(keyW) then
    FPan.Y := FPan.Y + 2
  else
  if Event.IsKey(keyArrowDown) or (Event.IsKey(keyS) and not (mkCtrl in Event.ModifiersDown)) then
    FPan.Y := FPan.Y - 2
  else
  if Event.IsKey(keyPlus) or Event.IsKey(keyNumpadPlus) or (Event.KeyString = '=') then
    FZoom := Min(80, FZoom * 1.2)
  else
  if Event.IsKey(keyMinus) or Event.IsKey(keyNumpadMinus) then
    FZoom := Max(4, FZoom / 1.2)
  else
  if Event.IsKey(keyF) then
    FitView
  else
  if Event.IsKey(keyG) then
    RunCommand(ecGenerate)
  else
  if Event.IsKey(keyP) or Event.IsKey(keyF5) then
    RunCommand(ecPlay)
  else
  if Event.IsKey(keyL) then
    RunCommand(ecLoad)
  else
  if Event.IsKey(keyN) then
    RunCommand(ecNew)
  else
  if Event.IsKey(keyX) then
    RunCommand(ecExport);
end;

function TQuakeLevelEditor.Release(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Release(Event);
  if not Exists then
    Exit;
  if Event.EventType = itMouseButton then
  begin
    FPainting := False;
    FStrokeCells.Clear;
  end;
  Result := True;
end;

function TQuakeLevelEditor.Motion(const Event: TInputMotion): Boolean;
var
  X, Y, I, Steps: Integer;
begin
  Result := inherited Motion(Event);
  if not Exists then
    Exit;
  if CellAtScreen(Event.Position, X, Y) then
  begin
    FHover := Point(X, Y);
    if FPainting then
    begin
      { Every cell between the last one and this (fast drags) }
      Steps := Max(Abs(X - FLastPaint.X), Abs(Y - FLastPaint.Y));
      for I := 1 to Steps do
        ApplyTool(FLastPaint.X + Round((X - FLastPaint.X) * I / Steps),
          FLastPaint.Y + Round((Y - FLastPaint.Y) * I / Steps), FPaintErase);
      FLastPaint := Point(X, Y);
    end;
  end else
    FHover := Point(-1, -1);
  Result := True;
end;

procedure TQuakeLevelEditor.Render;
var
  S, H, V: Single;
  G, R, B: TFloatRectangle;
  X, Y, I, CX, CY: Integer;
  C: PLevelCell;
  Col, KeyCol: TCastleColor;
  Tint: TVector3;
  E: TLevelEntity;
  Txt, HoverInfo: String;
  T: TLevelEditTool;
  Cmd: TLevelEditCommand;
  Mid, Dir: TVector2;
  Pts: array[0..1] of TVector2;

  procedure Button(const Rect: TFloatRectangle; const Caption: String; const Active: Boolean);
  begin
    if Active then
      DrawRectangle(Rect, Vector4(0.75, 0.42, 0.1, 1))
    else
      DrawRectangle(Rect, Vector4(0.18, 0.18, 0.2, 1));
    DrawRectangleOutline(Rect, Vector4(0.45, 0.45, 0.5, 1));
    UIFont.Print(Rect.Left + (Rect.Width - UIFont.TextWidth(Caption)) / 2,
      Rect.Bottom + (Rect.Height - UIFont.Height) / 2, White, Caption);
  end;

begin
  inherited Render;
  S := Scale;
  if (FZoom <= 0) or (GridRect.Width <= 0) then
    Exit;
  if (FPan.X = 0) and (FPan.Y = 0) and (FZoom = 20) then
    FitView;
  DrawRectangle(RenderRect, Vector4(0.05, 0.05, 0.06, 1));
  G := GridRect;

  { Cells }
  for Y := Max(0, Floor(FPan.Y)) to Min(FLevel.Height - 1, Ceil(FPan.Y + G.Height / FZoom)) do
    for X := Max(0, Floor(FPan.X)) to Min(FLevel.Width - 1, Ceil(FPan.X + G.Width / FZoom)) do
    begin
      R := CellRect(X, Y);
      if not R.Collides(G) then
        Continue;
      C := FLevel.Cell(X, Y);
      if C^.Solid then
        Col := Vector4(0.1, 0.1, 0.11, 1)
      else
      begin
        { Brighter = higher floor; tinted by the theme }
        V := EnsureRange(0.45 + C^.Floor / 400, 0.2, 1.1);
        Tint := ThemeTints[Min(C^.Theme, High(ThemeTints))];
        Col := Vector4(Tint * V, 1);
        if C^.Sky then
          Col := Vector4(Col.XYZ * 0.6 + Vector3(0.1, 0.2, 0.45), 1);
      end;
      DrawRectangle(R, Col);
      if CellHasWater(C) and C^.Lava then
        DrawRectangle(R, Vector4(1, 0.4, 0.05, 0.65))
      else
      if CellHasWater(C) and C^.Slime then
        DrawRectangle(R, Vector4(0.45, 0.75, 0.1, 0.55))
      else
      if CellHasWater(C) then
        DrawRectangle(R, Vector4(0.1, 0.35, 0.9, 0.45));
      if C^.Door and not C^.Solid then
      begin
        { Locked doors in the colour of their key }
        if C^.Key = 1 then
          KeyCol := Vector4(0.25, 0.45, 1, 1)
        else
        if C^.Key = 2 then
          KeyCol := Vector4(1, 0.25, 0.2, 1)
        else
          KeyCol := Vector4(1, 0.7, 0.3, 1);
        DrawRectangle(FloatRectangle(R.Left + R.Width * 0.2, R.Bottom, R.Width * 0.6, R.Height),
          Vector4(KeyCol.XYZ * 0.75, 0.85));
        DrawRectangleOutline(R, KeyCol);
      end;
      if C^.Ladder and not C^.Solid then
      begin
        { Rungs }
        for I := 1 to 3 do
          DrawRectangle(FloatRectangle(R.Left + R.Width * 0.2, R.Bottom + R.Height * I / 4 - R.Height * 0.05,
            R.Width * 0.6, R.Height * 0.1), Vector4(0.9, 0.85, 0.6, 0.9));
      end;
      if C^.Lift and not C^.Solid then
      begin
        DrawRectangle(FloatRectangle(R.Left + R.Width * 0.1, R.Bottom + R.Height * 0.1, R.Width * 0.8, R.Height * 0.8),
          Vector4(0.3, 0.8, 0.4, 0.6));
        DrawRectangleOutline(R, Vector4(0.4, 1, 0.5, 1));
      end;
      if C^.Button and not C^.Solid then
        DrawRectangle(FloatRectangle(R.Left + R.Width * 0.3, R.Bottom + R.Height * 0.3, R.Width * 0.4, R.Height * 0.4),
          Vector4(1, 0.2, 0.6, 1));
      if (C^.Channel > 0) and (not C^.Solid) and (FZoom >= 14) then
        UIFont.Print(R.Right - UIFont.TextWidth(IntToStr(C^.Channel)) - 2 * S, R.Top - UIFont.Height - 2 * S,
          Vector4(1, 1, 1, 0.9), IntToStr(C^.Channel));
      if FZoom >= 10 then
        DrawRectangleOutline(R, Vector4(0, 0, 0, 0.35));
      if (not C^.Solid) and (FZoom >= 30) then
      begin
        Txt := IntToStr(C^.Floor);
        UIFont.Print(R.Left + 2 * S, R.Bottom + 2 * S, Vector4(1, 1, 1, 0.55), Txt);
      end;
    end;

  { Entities: a dot with a letter, a tick for the facing }
  for E in FLevel.Entities do
  begin
    if (E.EntClass = 'target_changelevel') or (E.EntClass = 'target_secret') then
      Continue;
    FLevel.CellAt(E.Origin, CX, CY);
    R := CellRect(CX, CY);
    if not R.Collides(G) then
      Continue;
    H := Max(4, FZoom * 0.7);
    B := FloatRectangle(R.Left + (R.Width - H) / 2, R.Bottom + (R.Height - H) / 2, H, H);
    DrawRectangle(B, EntityColors[EntityKind(E.EntClass)]);
    if FZoom >= 14 then
      UIFont.Print(B.Left + (B.Width - UIFont.TextWidth(EntityLetter(E.EntClass))) / 2,
        B.Bottom + (B.Height - UIFont.Height) / 2, Black, EntityLetter(E.EntClass));
    if (E.Angle <> 0) or (Copy(E.EntClass, 1, 8) = 'monster_') or (E.EntClass = 'info_player_start') then
    begin
      Mid := B.Center;
      Dir := Vector2(Cos(DegToRad(E.Angle)), Sin(DegToRad(E.Angle)));
      Pts[0] := Mid;
      Pts[1] := Mid + Dir * FZoom * 0.6;
      DrawPrimitive2D(pmLines, Pts, White);
    end;
  end;

  { Hovered cell }
  if FLevel.InGrid(FHover.X, FHover.Y) then
    DrawRectangleOutline(CellRect(FHover.X, FHover.Y), Vector4(1, 1, 0.3, 1), 2);

  UIFont.PushProperties;
  try
    UIFont.Size := UIFont.EffectiveSize * S;
    { Toolbar }
    DrawRectangle(ToolbarRect, Vector4(0.09, 0.09, 0.1, 1));
    for T := Low(TLevelEditTool) to High(TLevelEditTool) do
      Button(ToolButtonRect(Ord(T)), Trim(ToolKeys[T] + ' ' + ToolNames[T]), T = FTool);
    for Cmd := Low(TLevelEditCommand) to High(TLevelEditCommand) do
      Button(CommandButtonRect(Ord(Cmd)), CommandNames[Cmd], False);

    { Entity palette }
    DrawRectangle(PaletteRect, Vector4(0.08, 0.08, 0.09, 1));
    for I := 0 to High(EditorEntityClasses) do
    begin
      R := PaletteRowRect(I);
      if I = FEntityIndex then
        DrawRectangle(R, Vector4(0.75, 0.42, 0.1, IfThen(FTool = etEntity, 1.0, 0.45)));
      DrawRectangle(FloatRectangle(R.Left + 2 * S, R.Bottom + R.Height * 0.25, R.Height * 0.5, R.Height * 0.5),
        EntityColors[EntityKind(EditorEntityClasses[I])]);
      UIFont.Print(R.Left + R.Height, R.Bottom + (R.Height - UIFont.Height) / 2, White, EditorEntityClasses[I]);
    end;

    { Status line }
    DrawRectangle(StatusRect, Vector4(0.09, 0.09, 0.1, 1));
    HoverInfo := '';
    if FLevel.InGrid(FHover.X, FHover.Y) then
    begin
      C := FLevel.Cell(FHover.X, FHover.Y);
      if C^.Solid then
        HoverInfo := Format('(%d,%d) wall', [FHover.X, FHover.Y])
      else
        HoverInfo := Format('(%d,%d) floor %d ceiling %d %s%s%s%s', [FHover.X, FHover.Y, C^.Floor, C^.Ceil,
          LevelThemes[Min(C^.Theme, High(LevelThemes))].Name, StrUtils.IfThen(C^.Sky, ' sky', ''),
          StrUtils.IfThen(C^.Door, ' door', '') + StrUtils.IfThen(C^.Lift, ' lift to ' + IntToStr(C^.LiftTop), '') +
            StrUtils.IfThen(C^.Button, ' button', '') + StrUtils.IfThen(C^.Channel > 0, ' channel ' + IntToStr(C^.Channel), '') +
            StrUtils.IfThen(C^.Key = 1, ' blue key', '') + StrUtils.IfThen(C^.Key = 2, ' red key', ''),
          StrUtils.IfThen(C^.Ladder, ' ladder', '') +
          StrUtils.IfThen(CellHasWater(C), StrUtils.IfThen(C^.Lava, ' lava ', StrUtils.IfThen(C^.Slime, ' slime ', ' water ')) + IntToStr(C^.Water), '')]);
      I := FLevel.EntityAtCell(FHover.X, FHover.Y);
      if I >= 0 then
        HoverInfo := HoverInfo + ' - ' + FLevel.Entities[I].EntClass;
    end;
    if FStatusTime > 0 then
      Txt := FStatus
    else
      Txt := Format('%s | %s | floor %d ceiling %d water %d lift %d channel %d key %s theme %s | entity %s %d° | %s',
        [FLevel.Name, ToolNames[FTool], FBrushFloor, FBrushCeil, FBrushWater, FBrushLift, FBrushChannel,
         StrUtils.IfThen(FBrushKey = 2, 'red', 'blue'),
         LevelThemes[FBrushTheme].Name,
         EditorEntityClasses[FEntityIndex], Round(FEntityAngle), HoverInfo]);
    UIFont.Print(StatusRect.Left + 8 * S, StatusRect.Bottom + (StatusRect.Height - UIFont.Height) / 2, White, Txt);
  finally
    UIFont.PopProperties;
  end;
end;

initialization
  RegisterSerializableComponent(TQuakeLevelEditor, 'Quake Level Editor');
end.
