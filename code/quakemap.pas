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
  CastleVectors, CastleTransform, CastleClassUtils, CastleLog,
  QuakeBsp, QuakeGeometry, QuakeMd2;

type
  TQuakeMap = class(TCastleTransform)
  strict private
    FPakUrl: String;
    FMapName: String;
    FPreviewEntities: Boolean;
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FPreview: TCastleTransform;
    FPreviewModels: specialize TObjectList<TQuakeMd2Instance>;
    procedure SetPakUrl(const Value: String);
    procedure SetMapName(const Value: String);
    procedure SetPreviewEntities(const Value: Boolean);
    function GetSkyName: String;
    function GetEntityCount: Integer;
    function GetFaceCount: Integer;
    procedure ClearMap;
    procedure Rebuild;
    procedure ClearPreview;
    procedure BuildPreview;
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;

    { Make sure PAK, palette and URL protocols are ready (also in the editor). }
    procedure EnsureData;

    { (Re)load a map, even if MapName didn't change (e.g. to restart a level).
      Returns False if the map couldn't be loaded. }
    function LoadMap(const AMapName: String): Boolean;

    { Loaded map data, nil when no map is loaded. }
    property Bsp: TQuakeBsp read FBsp;
    property Geometry: TQuakeGeometry read FGeometry;
  published
    { PAK with the map. Added to the PAKs the game already loaded (if missing).
      The bundled Quake 2 demo is castle-data:/paks/quake2_demo.pak . }
    property PakUrl: String read FPakUrl write SetPakUrl;
    { Map name, like "demo1" (maps/demo1.bsp) or "base1" in the full game. }
    property MapName: String read FMapName write SetMapName;
    { Show items and monsters as static models (for the editor; the game
      spawns live ones itself). }
    property PreviewEntities: Boolean read FPreviewEntities write SetPreviewEntities default False;
    { Read-only information, visible in the editor's inspector. }
    property SkyName: String read GetSkyName;
    property EntityCount: Integer read GetEntityCount;
    property FaceCount: Integer read GetFaceCount;
  end;

const
  DefaultPakUrl = 'castle-data:/paks/quake2_demo.pak';

implementation

uses
  CastleComponentSerialize, CastleUtils, CastleStringUtils, CastleUriUtils,
  QuakePak, QuakePalette, QuakeLight, QuakeEntities;

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
  if ArrayContainsString(PropertyName, ['PakUrl', 'MapName', 'PreviewEntities',
    'SkyName', 'EntityCount', 'FaceCount']) then
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
  Ent: TQuakeEntity;
  ItemDef: PQuakeItemDef;
  MonsterDef: PQuakeMonsterDef;
  Model: TQuakeMd2Instance;
  Holder: TCastleTransform;
  Pos: TVector3;
begin
  ClearPreview;
  if (FBsp = nil) or not FPreviewEntities then
    Exit;
  FPreview := TCastleTransform.Create(nil);
  FPreview.Name := 'EntityPreview';
  Add(FPreview);
  for Ent in FBsp.Entities do
  begin
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
    Model.Scene.Pickable := False;
    Model.SetTint(Lighting.SampleLight(Pos));
    Holder := TCastleTransform.Create(FPreview);
    Holder.Name := 'Preview_' + Ent.ClassName + '_' + IntToStr(FPreviewModels.Count);
    Holder.Translation := Pos;
    Holder.Rotation := Vector4(0, 1, 0, DegToRad(Ent.Angle));
    Holder.Add(Model.Scene);
    FPreview.Add(Holder);
    FPreviewModels.Add(Model);
  end;
end;

procedure TQuakeMap.Rebuild;
var
  MapPath: String;
begin
  ClearMap;
  if FMapName = '' then
    Exit;
  EnsureData;

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
  if FPreviewEntities then
    BuildPreview;
end;

function TQuakeMap.LoadMap(const AMapName: String): Boolean;
begin
  FMapName := AMapName;
  Rebuild;
  Result := FBsp <> nil;
end;

procedure TQuakeMap.Loaded;
begin
  inherited Loaded;
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

procedure TQuakeMap.SetPreviewEntities(const Value: Boolean);
begin
  if FPreviewEntities = Value then
    Exit;
  FPreviewEntities := Value;
  if not (csLoading in ComponentState) then
  begin
    if Value then
      BuildPreview
    else
      ClearPreview;
  end;
end;

function TQuakeMap.GetSkyName: String;
begin
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
