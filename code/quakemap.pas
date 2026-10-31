{ TQuakeMap: a Quake 2 map as a regular Castle Game Engine component.

  Place it in any viewport (in code or in the CGE editor), set PakUrl and
  MapName, and it builds the BSP world geometry, brush movers and (optionally)
  a static preview of items and monsters. Registered with
  RegisterSerializableComponent and listed in editor_units, so the CGE editor
  ("Project -> Restart Editor (With Custom Components)") can show Quake 2
  levels in the design. See https://castle-engine.io/custom_components . }
unit QuakeMap;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleClassUtils, CastleLog, CastleScene,
  { TCastleToolTransform }
  CastleInternalPhysicsVisualization,
  QuakeBsp, QuakeGeometry, QuakeMd2;

type
  { One previewed map entity (TQuakeMap.PreviewEntities / PreviewMarkers):
    holds its model or marker box. Select it in the CGE editor to see the
    entity's keys in the inspector (read-only: the map file owns them).
    A TCastleToolTransform: the editor shows and selects it although it is
    transient (never saved, not deletable). }
  TQuakeEntityTransform = class(TCastleToolTransform)
  strict private
    FEntityIndex: Integer;
    FEntityClass, FTargetName, FTarget: String;
    FSpawnFlags: Integer;
    FFields: TStringList;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;
    { Copy the keys of an entity (Index: its place in the map's entity list) }
    procedure AssignEntity(const Ent: TQuakeEntity; const Index: Integer);
  published
    property EntityIndex: Integer read FEntityIndex;
    property EntityClass: String read FEntityClass;
    property TargetName: String read FTargetName;
    property Target: String read FTarget;
    property SpawnFlags: Integer read FSpawnFlags;
    { All keys as key=value lines, sorted }
    property Fields: TStringList read FFields;
  end;

  TQuakeMap = class(TCastleTransform)
  strict private
    FPakUrl: String;
    FMapName: String;
    FLevelUrl: String;
    FPreviewEntities: Boolean;
    FPreviewMarkers: Boolean;
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FPreview: TCastleTransform;
    FPreviewModels: specialize TObjectList<TQuakeMd2Instance>;
    FBackground: TCastleBackground;
    FSkyOverride: String;
    FSkyRotate: Single;
    FSkyAxis: TVector3;
    procedure SetBackground(const Value: TCastleBackground);
    procedure SetPakUrl(const Value: String);
    procedure SetMapName(const Value: String);
    procedure SetLevelUrl(const Value: String);
    procedure SetPreviewEntities(const Value: Boolean);
    procedure SetPreviewMarkers(const Value: Boolean);
    procedure BuildMarkers;
    function GetSkyName: String;
    function GetEntityCount: Integer;
    function GetFaceCount: Integer;
    procedure ClearMap;
    procedure Rebuild;
    procedure ClearPreview;
    procedure BuildPreview;
    function AddEntityTransform(const Ent: TQuakeEntity; const Index: Integer;
      const Pos: TVector3): TQuakeEntityTransform;
  protected
    procedure Loaded; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;

    { Make sure PAK, palette and URL protocols are ready (also in the editor). }
    procedure EnsureData;

    { Rebuild from PakUrl, MapName and LevelUrl (the editor's "Reload Map"
      verb: after the PAK or a level file changed on disk) }
    procedure ReloadMap;
    { Maps of the loaded PAKs (names without maps/ and .bsp), sorted;
      the caller frees the list. For the editor's MapName dropdown. }
    function AvailableMaps: TStringList;

    { (Re)load a map, even if MapName didn't change (e.g. to restart a level).
      Returns False if the map couldn't be loaded. }
    function LoadMap(const AMapName: String): Boolean;

    { Show the map's skybox (worldspawn "sky", env/<sky>rt.pcx ...) on
      Background. Done automatically whenever the map is (re)built. }
    procedure ApplySky;

    { The "sky" console command: another sky, rotating Rotate degrees a
      second around Axis (Quake coordinates), until the next map }
    procedure SetSky(const AName: String; const Rotate: Single; const Axis: TVector3);
    { Turn the skybox for the time (seconds) of the level: worldspawn
      "skyrotate" degrees a second around "skyaxis" (R_SetSky) }
    procedure UpdateSkyRotation(const Time: Single);
    property SkyRotate: Single read FSkyRotate;
    property SkyAxis: TVector3 read FSkyAxis;

    { Loaded map data, nil when no map is loaded. }
    property Bsp: TQuakeBsp read FBsp;
    property Geometry: TQuakeGeometry read FGeometry;
  published
    { PAK with the map. Added to the PAKs the game already loaded (if missing).
      The bundled Quake 2 demo is castle-data:/paks/quake2_demo.pak . }
    property PakUrl: String read FPakUrl write SetPakUrl;
    { Map name, like "demo1" (maps/demo1.bsp) or "base1" in the full game. }
    property MapName: String read FMapName write SetMapName;
    { A level of the level editor (castle-quake2-level JSON, e.g.
      castle-config:/levels/mylevel.json), compiled into a map when MapName
      is empty. (MapName "rand<seed>" shows a random level.) }
    property LevelUrl: String read FLevelUrl write SetLevelUrl;
    { Show items and monsters as static models (for the editor; the game
      spawns live ones itself). }
    property PreviewEntities: Boolean read FPreviewEntities write SetPreviewEntities default False;
    { Show entities without a model as markers (for the editor): player
      starts (green, player-sized), path_corner / point_combat (yellow),
      sound speakers (small, orange), other point entities like targets and
      teleporter destinations (cyan)
      and trigger brushes (translucent magenta). Lights are left out. }
    property PreviewMarkers: Boolean read FPreviewMarkers write SetPreviewMarkers default False;
    { Background (usually the viewport's) that shows the map's skybox,
      also in the editor. }
    property Background: TCastleBackground read FBackground write SetBackground;
    { Read-only information, visible in the editor's inspector. }
    property SkyName: String read GetSkyName;
    property EntityCount: Integer read GetEntityCount;
    property FaceCount: Integer read GetFaceCount;
  end;

const
  DefaultPakUrl = 'castle-data:/paks/quake2_demo.pak';

implementation

uses
  CastleComponentSerialize, CastleUtils, CastleStringUtils, CastleUriUtils, CastleImages, CastleColors, CastleRenderOptions,
  QuakePak, QuakePalette, QuakeLight, QuakeEntities, QuakeLevel, QuakeBspBuilder,
  { (its MissingMapHook builds rand<seed> maps, also in the editor) }
  QuakeLevelGen;

{ TQuakeEntityTransform }

constructor TQuakeEntityTransform.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FFields := TStringList.Create;
  FEntityIndex := -1;
  SetTransient;
end;

destructor TQuakeEntityTransform.Destroy;
begin
  FreeAndNil(FFields);
  inherited Destroy;
end;

function TQuakeEntityTransform.PropertySections(const PropertyName: String): TPropertySections;
begin
  if (PropertyName = 'EntityIndex') or (PropertyName = 'EntityClass') or
     (PropertyName = 'TargetName') or (PropertyName = 'Target') or
     (PropertyName = 'SpawnFlags') or (PropertyName = 'Fields') then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

procedure TQuakeEntityTransform.AssignEntity(const Ent: TQuakeEntity; const Index: Integer);
var
  Pair: specialize TPair<String, String>;
begin
  FEntityIndex := Index;
  FEntityClass := Ent.ClassName;
  FTargetName := Ent.TargetName;
  FTarget := Ent.Target;
  FSpawnFlags := Ent.SpawnFlags;
  FFields.Clear;
  for Pair in Ent.Fields do
    FFields.Add(Pair.Key + '=' + Pair.Value);
  FFields.Sort;
end;

{ TQuakeMap }

function TQuakeMap.AddEntityTransform(const Ent: TQuakeEntity; const Index: Integer;
  const Pos: TVector3): TQuakeEntityTransform;
begin
  Result := TQuakeEntityTransform.Create(FPreview);
  Result.Name := Format('Entity%d_%s', [Index, Ent.ClassName]);
  Result.AssignEntity(Ent, Index);
  Result.Translation := Pos;
  FPreview.Add(Result);
end;

constructor TQuakeMap.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPakUrl := DefaultPakUrl;
  FPreviewModels := specialize TObjectList<TQuakeMd2Instance>.Create(True);
end;

destructor TQuakeMap.Destroy;
begin
  ClearMap;
  FreeAndNil(FPreviewModels);
  inherited Destroy;
end;

function TQuakeMap.PropertySections(const PropertyName: String): TPropertySections;
begin
  if ArrayContainsString(PropertyName, ['PakUrl', 'MapName', 'LevelUrl', 'PreviewEntities', 'PreviewMarkers',
    'Background', 'SkyName', 'EntityCount', 'FaceCount']) then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

procedure TQuakeMap.EnsureData;
begin
  Pak.RegisterProtocol;
  Palette.RegisterProtocol;
  if (FPakUrl <> '') and not Pak.HasPak(FPakUrl) and UriFileExists(FPakUrl) then
    Pak.AddFile(FPakUrl);
  if not Palette.HasPalette then
    Palette.LoadFromPak;
end;

procedure TQuakeMap.ReloadMap;
begin
  EnsureData;
  Rebuild;
end;

function TQuakeMap.AvailableMaps: TStringList;
var
  Files: TStringList;
  I: Integer;
  MapId: String;
begin
  EnsureData;
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Files := Pak.FindFiles('maps/', '.bsp');
  try
    for I := 0 to Files.Count - 1 do
    begin
      MapId := ChangeFileExt(Copy(Files[I], Length('maps/') + 1, MaxInt), '');
      if (MapId <> '') and (Pos('/', MapId) = 0) then
        Result.Add(MapId);
    end;
  finally
    Files.Free;
  end;
end;

procedure TQuakeMap.ClearPreview;
begin
  FPreviewModels.Clear;
  FreeAndNil(FPreview);
end;

procedure TQuakeMap.ClearMap;
begin
  ClearPreview;
  if Lighting.Bsp = FBsp then
    Lighting.SetMap(nil);
  { Freeing the geometry frees its transforms, which removes them from Self }
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);
end;

procedure TQuakeMap.BuildPreview;
var
  I: Integer;
  Ent: TQuakeEntity;
  ItemDef: PQuakeItemDef;
  MonsterDef: PQuakeMonsterDef;
  Model: TQuakeMd2Instance;
  Holder: TQuakeEntityTransform;
  Pos: TVector3;
begin
  ClearPreview;
  if (FBsp = nil) or not (FPreviewEntities or FPreviewMarkers) then
    Exit;
  { A tool transform, so the editor lists the entities below it }
  FPreview := TCastleToolTransform.Create(nil);
  FPreview.Name := 'EntityPreview';
  FPreview.SetTransient;
  Add(FPreview);
  if FPreviewMarkers then
    BuildMarkers;
  if not FPreviewEntities then
    Exit;
  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    ItemDef := FindItemDef(Ent.ClassName);
    MonsterDef := FindMonsterDef(Ent.ClassName);
    if ItemDef <> nil then
      Model := Md2Manager.CreateInstance(ItemDef^.Model)
    else
    if MonsterDef <> nil then
      Model := Md2Manager.CreateInstance(MonsterDef^.Model, MonsterDef^.Skin)
    else
      Continue;
    if Model = nil then
      Continue;
    Pos := QuakeToCge(Ent.Origin);
    Model.Scene.Collides := False;
    { Pickable and transient: clicking the model in the CGE editor selects
      its TQuakeEntityTransform }
    Model.Scene.SetTransient;
    Model.SetTint(Lighting.SampleLight(Pos));
    Holder := AddEntityTransform(Ent, I, Pos);
    Holder.Rotation := Vector4(0, 1, 0, DegToRad(Ent.Angle));
    Holder.Add(Model.Scene);
    FPreviewModels.Add(Model);
  end;
end;

procedure TQuakeMap.Rebuild;
var
  MapPath, LevelMap: String;
  Level: TQuakeLevel;
begin
  ClearMap;
  LevelMap := '';
  if (FMapName = '') and (FLevelUrl <> '') then
  begin
    EnsureData;
    Level := TQuakeLevel.Create(3, 3);
    try
      try
        Level.LoadFromFile(FLevelUrl);
        Level.Name := 'level_' + LowerCase(ChangeFileExt(ExtractUriName(FLevelUrl), ''));
        LevelMap := RegisterLevelMap(Level);
      except
        on E: Exception do
          WritelnWarning('QuakeMap', 'Cannot build level "%s": %s', [FLevelUrl, E.Message]);
      end;
    finally
      Level.Free;
    end;
  end;
  if (FMapName = '') and (LevelMap = '') then
    Exit;
  EnsureData;

  if LevelMap <> '' then
    MapPath := LevelMap
  else
    MapPath := LowerCase(FMapName);
  if Pos('/', MapPath) = 0 then
    MapPath := 'maps/' + MapPath;
  if ExtractFileExt(MapPath) = '' then
    MapPath := MapPath + '.bsp';

  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak(MapPath) then
  begin
    WritelnWarning('QuakeMap', 'Cannot load map "%s" (PAK "%s")', [MapPath, FPakUrl]);
    FreeAndNil(FBsp);
    Exit;
  end;
  FGeometry := TQuakeGeometry.Create(FBsp);
  FGeometry.AddToWorld(Self);
  Lighting.SetMap(FBsp);
  if FPreviewEntities or FPreviewMarkers then
    BuildPreview;
  ApplySky;
end;

procedure TQuakeMap.SetBackground(const Value: TCastleBackground);
begin
  if FBackground = Value then
    Exit;
  if FBackground <> nil then
    FBackground.RemoveFreeNotification(Self);
  FBackground := Value;
  if FBackground <> nil then
  begin
    FBackground.FreeNotification(Self);
    if (FBsp <> nil) and not (csLoading in ComponentState) then
      ApplySky;
  end;
end;

procedure TQuakeMap.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FBackground) then
    FBackground := nil;
end;

procedure TQuakeMap.ApplySky;
var
  Sky: String;

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
    Base := 'env/' + Sky + Suffix;
    Id := 'sky/' + Sky + Suffix;
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
          WritelnWarning('QuakeMap', 'Cannot load sky "%s": %s', [Base, E.Message]);
      end;
      if Src = nil then
        Exit;
      WritelnLog('QuakeMap', 'Sky side %s: %dx%d %s', [Base, Src.Width, Src.Height, Src.ClassName]);
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
    Exit;
  { worldspawn skyrotate / skyaxis (unless the sky command set them) }
  if (FSkyOverride = '') and (FBsp <> nil) and (FBsp.FindEntity('worldspawn') <> nil) then
  begin
    FSkyRotate := FBsp.FindEntity('worldspawn').GetFloat('skyrotate', 0);
    FSkyAxis := FBsp.FindEntity('worldspawn').GetVector('skyaxis', TVector3.Zero);
  end;
  Sky := GetSkyName;
  FBackground.SkyTopColor := Vector3(0.05, 0.05, 0.08);
  FBackground.SkyEquatorColor := Vector3(0.1, 0.1, 0.12);
  if Sky = '' then
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


function TQuakeMap.LoadMap(const AMapName: String): Boolean;
begin
  FMapName := AMapName;
  { The sky command lasts until the next map }
  FSkyOverride := '';
  Rebuild;
  Result := FBsp <> nil;
end;

procedure TQuakeMap.Loaded;
begin
  inherited Loaded;
  { In the editor, show the map right away. In the game TQuakeWorld calls
    LoadMap with the level it wants, so don't build the design's map first. }
  if CastleDesignMode then
    Rebuild;
end;

procedure TQuakeMap.SetPakUrl(const Value: String);
begin
  if FPakUrl = Value then
    Exit;
  FPakUrl := Value;
  if not (csLoading in ComponentState) then
    Rebuild;
end;

procedure TQuakeMap.SetMapName(const Value: String);
begin
  if FMapName = Value then
    Exit;
  FMapName := Value;
  if not (csLoading in ComponentState) then
    Rebuild;
end;

procedure TQuakeMap.SetLevelUrl(const Value: String);
begin
  if FLevelUrl = Value then
    Exit;
  FLevelUrl := Value;
  if not (csLoading in ComponentState) then
    Rebuild;
end;

procedure TQuakeMap.SetPreviewMarkers(const Value: Boolean);
begin
  if FPreviewMarkers = Value then
    Exit;
  FPreviewMarkers := Value;
  if (FBsp <> nil) and not (csLoading in ComponentState) then
    BuildPreview;
end;

procedure TQuakeMap.BuildMarkers;

  procedure AddMarker(const Ent: TQuakeEntity; const Index: Integer;
    const Center, Size: TVector3; const Color: TCastleColor);
  var
    Holder: TQuakeEntityTransform;
    Box: TCastleBox;
  begin
    Holder := AddEntityTransform(Ent, Index, Center);
    Box := TCastleBox.Create(Holder);
    Box.Name := Format('Marker%d', [Index]);
    Box.Size := Size;
    Box.Color := Color;
    Box.Material := pmUnlit; { the map has no real-time lights }
    Box.Collides := False;
    { Pickable and transient: clicking the marker in the CGE editor
      selects its TQuakeEntityTransform }
    Box.SetTransient;
    Holder.Add(Box);
  end;

var
  I, ModelIdx: Integer;
  Ent: TQuakeEntity;
  CName: String;
  A, B: TVector3;
begin
  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    CName := Ent.ClassName;
    if (FindItemDef(CName) <> nil) or (FindMonsterDef(CName) <> nil) or
       (Copy(CName, 1, 5) = 'light') or (CName = 'worldspawn') then
      Continue;
    { Trigger brushes: their model's bounds }
    if Copy(CName, 1, 8) = 'trigger_' then
    begin
      ModelIdx := StrToIntDef(Copy(Ent.Model, 2, MaxInt), -1);
      if (Copy(Ent.Model, 1, 1) = '*') and (ModelIdx > 0) and (ModelIdx < FBsp.ModelCount) then
      begin
        A := QuakeToCge(FBsp.Models[ModelIdx].Mins);
        B := QuakeToCge(FBsp.Models[ModelIdx].Maxs);
        AddMarker(Ent, I, (A + B) / 2,
          Vector3(Abs(B.X - A.X), Abs(B.Y - A.Y), Abs(B.Z - A.Z)), Vector4(1, 0, 1, 0.25));
      end;
      Continue;
    end;
    { Other brush entities are already drawn by the geometry }
    if Ent.Model <> '' then
      Continue;
    if Copy(CName, 1, 12) = 'info_player_' then
      { Quake 2 player box: 32 x 32 x 56, origin 24 above the feet }
      AddMarker(Ent, I, QuakeToCge(Ent.Origin) + Vector3(0, 4, 0), Vector3(32, 56, 32), Vector4(0, 1, 0, 0.5))
    else
    if (CName = 'path_corner') or (CName = 'point_combat') then
      AddMarker(Ent, I, QuakeToCge(Ent.Origin), Vector3(8, 8, 8), Vector4(1, 1, 0, 1))
    else
    if CName = 'target_speaker' then
      AddMarker(Ent, I, QuakeToCge(Ent.Origin), Vector3(6, 6, 6), Vector4(1, 0.5, 0, 1))
    else
      AddMarker(Ent, I, QuakeToCge(Ent.Origin), Vector3(12, 12, 12), Vector4(0, 1, 1, 1));
  end;
end;

procedure TQuakeMap.SetPreviewEntities(const Value: Boolean);
begin
  if FPreviewEntities = Value then
    Exit;
  FPreviewEntities := Value;
  if not (csLoading in ComponentState) then
    BuildPreview; { clears it when nothing is previewed }
end;

procedure TQuakeMap.SetSky(const AName: String; const Rotate: Single; const Axis: TVector3);
begin
  FSkyOverride := AName;
  ApplySky;
  FSkyRotate := Rotate;
  FSkyAxis := Axis;
end;

procedure TQuakeMap.UpdateSkyRotation(const Time: Single);
var
  Axis: TVector3;
begin
  if FBackground = nil then
    Exit;
  if (FSkyRotate = 0) then
  begin
    FBackground.Rotation := Vector4(0, 1, 0, 0);
    Exit;
  end;
  { Quake -> CGE axes keep the handedness, so the angle keeps its sign.
    A map without "skyaxis" turns around the vertical. }
  Axis := QuakeToCge(FSkyAxis);
  if Axis.IsZero then
    Axis := Vector3(0, 1, 0);
  FBackground.Rotation := Vector4(Axis.Normalize, DegToRad(FMod(Time * FSkyRotate, 360)));
end;

function TQuakeMap.GetSkyName: String;
begin
  if FSkyOverride <> '' then
    Result := FSkyOverride
  else
  if FGeometry <> nil then
    Result := FGeometry.SkyName
  else
    Result := '';
end;

function TQuakeMap.GetEntityCount: Integer;
begin
  if FBsp <> nil then
    Result := FBsp.Entities.Count
  else
    Result := 0;
end;

function TQuakeMap.GetFaceCount: Integer;
begin
  if FBsp <> nil then
    Result := FBsp.FaceCount
  else
    Result := 0;
end;

initialization
  RegisterSerializableComponent(TQuakeMap, 'Quake 2 Map');
end.
