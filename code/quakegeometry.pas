{ Quake 2 BSP geometry to Castle Game Engine X3D scenes, plus brush movers
  (doors, platforms, buttons, rotating brushes, trains). }
unit QuakeGeometry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, X3DNodes, CastleLog,
  CastleImages, CastleUtils, CastleBoxes, CastleRenderOptions,
  QuakeBsp, QuakePalette, QuakeLight, QuakeSound;

type
  { A batch of polygons sharing one texture and surface flags }
  TQuakeGeomBatch = class
  public
    TextureName: String;
    Flags: Integer;
    Coords: TVector3List;
    TexCoords: TVector2List;
    LMTexCoords: TVector2List;
    Indices: TInt32List;
    TexNode: TImageTextureNode;
    ScrollNode: TTextureTransformNode;
    Shape: TShapeNode;
    { Uses the dynamic (light-style animated) lightmap atlas }
    Dynamic: Boolean;
    constructor Create(const ATexName: String; const AFlags: Integer);
    destructor Destroy; override;
    function UsesLightmap: Boolean;
    procedure AddPolygon(const Verts: array of TVector3; const UVs, LMUVs: array of TVector2);
    { Build X3D nodes. LightmapTex may be nil (then the batch is fullbright). }
    procedure CreateNodes(const LightmapTex: TPixelTextureNode);
  end;

  TQuakeGeomBatchDict = specialize TObjectDictionary<String, TQuakeGeomBatch>;

  { A face whose lightmap is the sum of animated light styles }
  TQuakeDynFace = record
    AtlasX, AtlasY, Width, Height: Integer;
    LightmapOffset: Integer;
    Styles: array[0..3] of Byte;
  end;

  { Lightmap atlas recomposed from light styles when their values change. }
  TQuakeDynamicLightmap = class
  public
    Node: TPixelTextureNode;  { owned by the scene graph }
    Faces: array of TQuakeDynFace;
    FaceCount: Integer;
    ComposedVersion: Cardinal;
    procedure AddFace(const F: TQuakeDynFace);
    { Write all faces' texels for the current Lighting style values }
    procedure Compose(const Image: TRGBImage; const Lightmaps: TBytes);
  end;

  TQuakeDynamicLightmapList = specialize TObjectList<TQuakeDynamicLightmap>;

  { Packs per-face RGB lightmaps into one atlas texture. }
  TQuakeLightmapAtlas = class
  private
    FWidth, FHeight: Integer;
    FImage: TRGBImage;
    FShelfX, FShelfY, FShelfH: Integer;
  public
    constructor Create(const AWidth, AHeight: Integer);
    destructor Destroy; override;
    { Reserve a W x H block. Returns False if the atlas is full. }
    function Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
    procedure SetTexel(const X, Y: Integer; const R, G, B: Byte);
    { Create final texture node; the atlas image ownership moves to the node. }
    function CreateTextureNode: TPixelTextureNode;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

  TQuakeMoverKind = (mkStatic, mkDoor, mkDoorRotating, mkPlat, mkButton, mkRotating, mkTrain);
  TQuakeMoverState = (msAtStart, msToEnd, msAtEnd, msToStart);

  TQuakeGeometry = class;

  { Brush entity (func_*) rendered as its own scene, possibly moving.
    A TCastleBehavior attached to its Transform, so the published state
    below is visible in the CGE inspector (F8 in debug builds). }
  TQuakeMover = class(TCastleBehavior)
  strict private
    function GetEntityClass: String;
  public
    Geometry: TQuakeGeometry;
    Entity: TQuakeEntity;
    ModelIndex: Integer;
    Kind: TQuakeMoverKind;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    BaseOffset: TVector3;    { entity origin in CGE space }
    Pos1, Pos2: TVector3;    { translation offsets (start / end) }
    Angle1, Angle2: Single;  { rotation angles in radians (door_rotating) }
    RotAxis: TVector3;
    Progress: Single;        { 0 = at start, 1 = at end }
    MoveLength: Single;      { distance (units) or angle (degrees) between ends }
    Speed: Single;
    WaitTime: Single;
    StateTimer: Single;
    State: TQuakeMoverState;
    Spinning: Boolean;
    SpinAngle: Single;
    Target: String;
    TargetName: String;
    Health: Integer;
    { True for doors with no targetname: they open when the player comes near }
    AutoOpen: Boolean;
    StartSound, EndSound: String;
    { Train path }
    TrainCorner: TQuakeEntity;
    TrainFrom, TrainTo: TVector3;
    TrainRunning: Boolean;
    constructor CreateMover(const AGeometry: TQuakeGeometry; const AEntity: TQuakeEntity;
      const AModelIndex: Integer);
    destructor Destroy; override;
    { Bounding box in map (= world, CGE) space, at the current position
      (empty when the brush has no visible faces) }
    function WorldBox: TBox3D;
    { Center in world (CGE) space; works for invisible brushes too }
    function Center: TVector3;
    procedure Update(const SecondsPassed: Single);
    { Activate (open door, raise plat, press button, toggle rotating/train).
      Returns True if something started moving. }
    function Use: Boolean;
    { For plats: player stepped on it. }
    procedure PlayerOnTop;
    { Re-apply Transform from State / Progress / SpinAngle (after loading a save) }
    procedure ApplyPose;
  published
    property EntityClass: String read GetEntityClass;
    property EntityTargetName: String read TargetName;
    property EntityTarget: String read Target;
    property MoverKind: TQuakeMoverKind read Kind;
    property MoverState: TQuakeMoverState read State;
    property MoveProgress: Single read Progress;
    property MoveSpeed: Single read Speed;
    property Wait: Single read WaitTime;
    property HitPoints: Integer read Health;
    property OpensWhenNear: Boolean read AutoOpen;
  end;

  TQuakeMoverList = specialize TObjectList<TQuakeMover>;

  { Animated texture chain (WAL animname), cycled at 2 frames/second like Quake 2 }
  TQuakeAnimTex = class
  public
    Frames: TStringList;
    Nodes: specialize TList<TImageTextureNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  TQuakeAnimTexList = specialize TObjectList<TQuakeAnimTex>;

  { Event to fire entity targets (implemented by the world simulation). }
  TQuakeFireTargetsEvent = procedure(const ATarget: String) of object;

  { World geometry builder and manager }
  TQuakeGeometry = class
  private
    FBsp: TQuakeBsp;
    FSceneWorld: TCastleScene;
    FSceneSkyClip: TCastleScene;
    { Warped liquid surfaces: visible, but you swim through them and shots
      pass them, so they neither collide nor are pickable }
    FSceneLiquids: TCastleScene;
    FWorldTransform: TCastleTransform;
    FMovers: TQuakeMoverList;
    FAnimTextures: TQuakeAnimTexList;
    FScrollNodes: specialize TList<TTextureTransformNode>;
    FDynLightmaps: TQuakeDynamicLightmapList;
    FTime: Single;
    FAnimFrame: Integer;
    FSkyName: String;
    FOnFireTargets: TQuakeFireTargetsEvent;
    procedure BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
      const SkyRoot: TX3DRootNode; const LiquidRoot: TX3DRootNode = nil);
    procedure SetupMovers(const Parent: TCastleTransform);
    procedure RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
  public
    constructor Create(const ABsp: TQuakeBsp);
    destructor Destroy; override;

    { Build all geometry and add to parent transform (viewport.Items) }
    procedure AddToWorld(const Parent: TCastleTransform);

    { Advance animated textures and movers }
    procedure Update(const SecondsPassed: Single);

    { Number of faces lit by animated / switchable light styles }
    function DynamicFaceCount: Integer;

    { Fire OnFireTargets (used by movers) }
    procedure FireTargets(const ATarget: String);

    { Find mover by model string like "*1" }
    function FindMoverByModel(const AModel: String): TQuakeMover;

    property Bsp: TQuakeBsp read FBsp;
    property SceneWorld: TCastleScene read FSceneWorld;
    property WorldTransform: TCastleTransform read FWorldTransform;
    property Movers: TQuakeMoverList read FMovers;
    { Worldspawn "sky" key, e.g. "unit1_" (env/unit1_rt.pcx ...) }
    property SkyName: String read FSkyName;
    property OnFireTargets: TQuakeFireTargetsEvent read FOnFireTargets write FOnFireTargets;
  end;

{ Classnames that are built as brush movers / visible brush entities. }
function IsVisibleBrushClass(const CName: String): Boolean;

var
  { Gamma applied to lightmaps (1.0 = original data; >1 brightens the dark
    areas, like raising Quake 2's brightness slider). Set with -gamma. }
  LightmapGamma: Single = 1.2;

implementation

const
  { Flags that split surfaces into separate batches }
  BatchFlagMask = SURF_WARP or SURF_TRANS33 or SURF_TRANS66 or SURF_FLOWING;

  DOOR_START_OPEN = 1;
  DOOR_REVERSE    = 2;
  DOOR_X_AXIS     = 64;
  DOOR_Y_AXIS     = 128;
  ROTATING_START_ON = 1;
  ROTATING_REVERSE  = 2;
  ROTATING_X_AXIS   = 4;
  ROTATING_Y_AXIS   = 8;
  TRAIN_START_ON  = 1;

function IsVisibleBrushClass(const CName: String): Boolean;
begin
  Result := (Copy(CName, 1, 5) = 'func_') and (CName <> 'func_areaportal') and
    (CName <> 'func_clock') and (CName <> 'func_timer') and (CName <> 'func_group');
end;

{ CGE direction from Quake movedir conventions (angle -1 = up, -2 = down) }
function MoveDirFromAngle(const AngleVal: Single): TVector3;
begin
  if SameValue(AngleVal, -1) then
    Result := Vector3(0, 1, 0)
  else
  if SameValue(AngleVal, -2) then
    Result := Vector3(0, -1, 0)
  else
    Result := YawToCgeDir(AngleVal);
end;

var
  GammaTable: array[Byte] of Byte;
  GammaTableFor: Single = -1;

function ApplyGamma(const V: Byte): Byte;
var
  I: Integer;
begin
  if GammaTableFor <> LightmapGamma then
  begin
    for I := 0 to 255 do
      GammaTable[I] := Round(255 * Power(I / 255, 1 / Max(0.1, LightmapGamma)));
    GammaTableFor := LightmapGamma;
  end;
  Result := GammaTable[V];
end;

{ TQuakeGeomBatch }

constructor TQuakeGeomBatch.Create(const ATexName: String; const AFlags: Integer);
begin
  inherited Create;
  TextureName := ATexName;
  Flags := AFlags;
  Coords := TVector3List.Create;
  TexCoords := TVector2List.Create;
  LMTexCoords := TVector2List.Create;
  Indices := TInt32List.Create;
end;

destructor TQuakeGeomBatch.Destroy;
begin
  Coords.Free;
  TexCoords.Free;
  LMTexCoords.Free;
  Indices.Free;
  inherited Destroy;
end;

function TQuakeGeomBatch.UsesLightmap: Boolean;
begin
  Result := (Flags and (SURF_WARP or SURF_SKY or SURF_TRANS33 or SURF_TRANS66)) = 0;
end;

procedure TQuakeGeomBatch.AddPolygon(const Verts: array of TVector3; const UVs, LMUVs: array of TVector2);
var
  BaseIdx, I: Integer;
begin
  if Length(Verts) < 3 then
    Exit;
  BaseIdx := Coords.Count;
  for I := 0 to High(Verts) do
  begin
    Coords.Add(Verts[I]);
    TexCoords.Add(UVs[I]);
    LMTexCoords.Add(LMUVs[I]);
  end;
  { Triangle fan; Quake winding is clockwise, see Geometry.Ccw }
  for I := 1 to High(Verts) - 1 do
  begin
    Indices.Add(BaseIdx);
    Indices.Add(BaseIdx + I);
    Indices.Add(BaseIdx + I + 1);
  end;
end;

procedure TQuakeGeomBatch.CreateNodes(const LightmapTex: TPixelTextureNode);
var
  CoordNode: TCoordinateNode;
  TexCoordNode, LMCoordNode: TTextureCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Appearance: TAppearanceNode;
  TexProps: TTexturePropertiesNode;
  UnlitMat: TUnlitMaterialNode;
  MultiTex: TMultiTextureNode;
  MultiCoord: TMultiTextureCoordinateNode;
  MultiTransform: TMultiTextureTransformNode;
  UseLightmap: Boolean;
begin
  if Coords.Count = 0 then
    Exit;

  CoordNode := TCoordinateNode.Create;
  CoordNode.SetPoint(Coords);
  TexCoordNode := TTextureCoordinateNode.Create;
  TexCoordNode.SetPoint(TexCoords);

  Geometry := TIndexedTriangleSetNode.Create;
  Geometry.Coord := CoordNode;
  Geometry.SetIndex(Indices);
  { Quake BSP polygons are wound clockwise when seen from the front }
  Geometry.Ccw := False;
  Geometry.Solid := (Flags and (SURF_WARP or SURF_TRANS33 or SURF_TRANS66)) = 0;

  { Sky faces are only kept for collisions: no texture needed }
  if (Flags and SURF_SKY) <> 0 then
  begin
    Geometry.TexCoord := TexCoordNode;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Exit;
  end;

  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magNearest;
  TexProps.MinificationFilter := minNearestMipmapLinear;
  TexProps.AnisotropicDegree := 4;

  TexNode := TImageTextureNode.Create;
  TexNode.SetUrl(['quaketex:/' + WalTextureId(TextureName)]);
  TexNode.RepeatS := True;
  TexNode.RepeatT := True;
  TexNode.TextureProperties := TexProps;

  { World surfaces are not lit dynamically: the look comes from the baked
    lightmaps, modulated 2x (Quake 2 lightmaps are "overbright"). }
  Appearance := TAppearanceNode.Create;
  UnlitMat := TUnlitMaterialNode.Create;
  UnlitMat.EmissiveColor := Vector3(1, 1, 1);
  Appearance.Material := UnlitMat;

  if (Flags and SURF_FLOWING) <> 0 then
    ScrollNode := TTextureTransformNode.Create;

  UseLightmap := (LightmapTex <> nil) and UsesLightmap;
  if UseLightmap then
  begin
    MultiTex := TMultiTextureNode.Create;
    MultiTex.FdTexture.Add(TexNode);
    MultiTex.FdTexture.Add(LightmapTex);
    MultiTex.FdMode.Items.Clear;
    MultiTex.FdMode.Items.Add('MODULATE');
    MultiTex.FdMode.Items.Add('MODULATE2X');
    Appearance.Texture := MultiTex;

    LMCoordNode := TTextureCoordinateNode.Create;
    LMCoordNode.SetPoint(LMTexCoords);
    MultiCoord := TMultiTextureCoordinateNode.Create;
    MultiCoord.FdTexCoord.Add(TexCoordNode);
    MultiCoord.FdTexCoord.Add(LMCoordNode);
    Geometry.TexCoord := MultiCoord;

    if ScrollNode <> nil then
    begin
      MultiTransform := TMultiTextureTransformNode.Create;
      MultiTransform.FdTextureTransform.Add(ScrollNode);
      MultiTransform.FdTextureTransform.Add(TTextureTransformNode.Create);
      Appearance.TextureTransform := MultiTransform;
    end;
  end else
  begin
    Appearance.Texture := TexNode;
    Geometry.TexCoord := TexCoordNode;
    if ScrollNode <> nil then
      Appearance.TextureTransform := ScrollNode;
  end;

  if (Flags and SURF_TRANS33) <> 0 then
  begin
    UnlitMat.Transparency := 0.67;
    Appearance.AlphaMode := amBlend;
  end else
  if (Flags and SURF_TRANS66) <> 0 then
  begin
    UnlitMat.Transparency := 0.34;
    Appearance.AlphaMode := amBlend;
  end else
    Appearance.AlphaMode := amOpaque;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geometry;
  Shape.Appearance := Appearance;
end;

{ TQuakeLightmapAtlas }

constructor TQuakeLightmapAtlas.Create(const AWidth, AHeight: Integer);
var
  X, Y: Integer;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FImage := TRGBImage.Create(FWidth, FHeight);
  FImage.Clear(Vector4Byte(0, 0, 0, 255));
  { Reserve a 4x4 block at (0,0) filled with 128 (= 1.0 with MODULATE2X)
    for faces without lightmap data. }
  for Y := 0 to 3 do
    for X := 0 to 3 do
      PVector3Byte(FImage.PixelPtr(X, Y))^ := Vector3Byte(128, 128, 128);
  FShelfX := 5;
  FShelfY := 0;
  FShelfH := 4;
end;

destructor TQuakeLightmapAtlas.Destroy;
begin
  FImage.Free;
  inherited Destroy;
end;

function TQuakeLightmapAtlas.Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
begin
  Result := False;
  X := 0;
  Y := 0;
  if (W > FWidth) or (W <= 0) or (H <= 0) then
    Exit;
  { 1 texel padding to avoid bleeding with linear filtering }
  if FShelfX + W + 1 > FWidth then
  begin
    FShelfY := FShelfY + FShelfH + 1;
    FShelfX := 0;
    FShelfH := 0;
  end;
  if FShelfY + H > FHeight then
    Exit;
  X := FShelfX;
  Y := FShelfY;
  FShelfX := FShelfX + W + 1;
  FShelfH := Max(FShelfH, H);
  Result := True;
end;

procedure TQuakeLightmapAtlas.SetTexel(const X, Y: Integer; const R, G, B: Byte);
begin
  if (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
    PVector3Byte(FImage.PixelPtr(X, Y))^ := Vector3Byte(ApplyGamma(R), ApplyGamma(G), ApplyGamma(B));
end;

function TQuakeLightmapAtlas.CreateTextureNode: TPixelTextureNode;
var
  TexProps: TTexturePropertiesNode;
begin
  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magLinear;
  TexProps.MinificationFilter := minLinear;
  TexProps.BoundaryModeS := bmClampToEdge;
  TexProps.BoundaryModeT := bmClampToEdge;

  Result := TPixelTextureNode.Create;
  Result.FdImage.Value := FImage;
  FImage := nil; { owned by the node now }
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := TexProps;
end;

{ TQuakeDynamicLightmap }

procedure TQuakeDynamicLightmap.AddFace(const F: TQuakeDynFace);
begin
  if FaceCount = Length(Faces) then
    SetLength(Faces, Max(64, FaceCount * 2));
  Faces[FaceCount] := F;
  Inc(FaceCount);
end;

procedure TQuakeDynamicLightmap.Compose(const Image: TRGBImage; const Lightmaps: TBytes);
var
  I, S, Row, Col, Size, Ofs, LayerCount: Integer;
  Scale: array[0..3] of Single;
  R, G, B: Single;
  P: PVector3Byte;
begin
  for I := 0 to FaceCount - 1 do
  begin
    Size := Faces[I].Width * Faces[I].Height;
    LayerCount := 0;
    for S := 0 to 3 do
      if Faces[I].Styles[S] <> 255 then
      begin
        Scale[S] := Lighting.StyleValue(Faces[I].Styles[S]);
        LayerCount := S + 1;
      end;
    for Row := 0 to Faces[I].Height - 1 do
    begin
      P := Image.PixelPtr(Faces[I].AtlasX, Faces[I].AtlasY + Row);
      for Col := 0 to Faces[I].Width - 1 do
      begin
        R := 0; G := 0; B := 0;
        Ofs := Faces[I].LightmapOffset + (Row * Faces[I].Width + Col) * 3;
        for S := 0 to LayerCount - 1 do
        begin
          if Ofs + 2 < Length(Lightmaps) then
          begin
            R := R + Lightmaps[Ofs] * Scale[S];
            G := G + Lightmaps[Ofs + 1] * Scale[S];
            B := B + Lightmaps[Ofs + 2] * Scale[S];
          end;
          Ofs := Ofs + Size * 3;
        end;
        P^ := Vector3Byte(ApplyGamma(Min(255, Round(R))), ApplyGamma(Min(255, Round(G))),
          ApplyGamma(Min(255, Round(B))));
        Inc(P);
      end;
    end;
  end;
  ComposedVersion := Lighting.Version;
end;

{ TQuakeAnimTex }

constructor TQuakeAnimTex.Create;
begin
  inherited Create;
  Frames := TStringList.Create;
  Nodes := specialize TList<TImageTextureNode>.Create;
end;

destructor TQuakeAnimTex.Destroy;
begin
  Frames.Free;
  Nodes.Free;
  inherited Destroy;
end;

{ TQuakeMover }

constructor TQuakeMover.CreateMover(const AGeometry: TQuakeGeometry; const AEntity: TQuakeEntity;
  const AModelIndex: Integer);
var
  CName: String;
  Mdl: TBSPModel;
  Size: TVector3;
  MoveDir: TVector3;
  Lip, Dist, H: Single;
  SpawnFlags: Integer;
begin
  inherited Create(nil);
  Geometry := AGeometry;
  Entity := AEntity;
  ModelIndex := AModelIndex;
  CName := AEntity.ClassName;
  SpawnFlags := AEntity.SpawnFlags;
  Target := AEntity.Target;
  TargetName := AEntity.TargetName;
  Health := AEntity.GetInt('health', 0);
  { Untargeted func_explosive is shootable with 100 health by default }
  if (CName = 'func_explosive') and (TargetName = '') and (Health <= 0) then
    Health := 100;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := Format('Mover%.2d_%s', [ModelIndex, CName]);
  Scene := TCastleScene.Create(nil);
  Scene.Name := Transform.Name + '_Scene';
  Scene.PreciseCollisions := True;
  Transform.Add(Scene);
  Transform.AddBehavior(Self);

  Mdl := Geometry.Bsp.Models[ModelIndex];
  { Size in CGE axes (Quake Z height becomes Y) }
  Size := Vector3(Mdl.Maxs.X - Mdl.Mins.X, Mdl.Maxs.Z - Mdl.Mins.Z, Mdl.Maxs.Y - Mdl.Mins.Y);
  BaseOffset := QuakeToCge(AEntity.Origin);
  Pos1 := Vector3(0, 0, 0);
  Pos2 := Pos1;
  RotAxis := Vector3(0, 1, 0);
  State := msAtStart;
  Kind := mkStatic;

  if (CName = 'func_door') or (CName = 'func_door_secret') or (CName = 'func_water') then
  begin
    Kind := mkDoor;
    MoveDir := MoveDirFromAngle(AEntity.Angle);
    Lip := AEntity.GetFloat('lip', 8);
    Dist := Abs(MoveDir.X) * Size.X + Abs(MoveDir.Y) * Size.Y + Abs(MoveDir.Z) * Size.Z - Lip;
    Pos2 := MoveDir * Dist;
    MoveLength := Abs(Dist);
    Speed := AEntity.Speed(100);
    WaitTime := AEntity.GetFloat('wait', 3);
    AutoOpen := (TargetName = '') and (Health = 0) and (CName <> 'func_water');
    if (SpawnFlags and DOOR_START_OPEN) <> 0 then
    begin
      Pos1 := Pos2;
      Pos2 := Vector3(0, 0, 0);
    end;
    if AEntity.Sounds <> 1 then
    begin
      StartSound := 'sound/doors/dr1_strt.wav';
      EndSound := 'sound/doors/dr1_end.wav';
    end;
  end else
  if CName = 'func_door_rotating' then
  begin
    Kind := mkDoorRotating;
    if (SpawnFlags and DOOR_X_AXIS) <> 0 then
      RotAxis := Vector3(0, 0, -1) { Quake X axis rotation = roll }
    else
    if (SpawnFlags and DOOR_Y_AXIS) <> 0 then
      RotAxis := Vector3(1, 0, 0)
    else
      RotAxis := Vector3(0, 1, 0);
    MoveLength := AEntity.GetFloat('distance', 90);
    Angle1 := 0;
    Angle2 := DegToRad(MoveLength);
    if (SpawnFlags and DOOR_REVERSE) <> 0 then
      Angle2 := -Angle2;
    if (SpawnFlags and DOOR_START_OPEN) <> 0 then
    begin
      Angle1 := Angle2;
      Angle2 := 0;
    end;
    Speed := AEntity.Speed(100); { degrees per second }
    WaitTime := AEntity.GetFloat('wait', 3);
    AutoOpen := (TargetName = '') and (Health = 0);
    StartSound := 'sound/doors/dr1_strt.wav';
    EndSound := 'sound/doors/dr1_end.wav';
  end else
  if CName = 'func_plat' then
  begin
    Kind := mkPlat;
    Lip := AEntity.GetFloat('lip', 8);
    H := AEntity.GetFloat('height', 0);
    if H <= 0 then
      H := Size.Y - Lip;
    { Built in the "up" position; pos2 is the bottom }
    Pos1 := Vector3(0, 0, 0);
    Pos2 := Vector3(0, -H, 0);
    MoveLength := H;
    Speed := AEntity.Speed(200);
    WaitTime := 3;
    StartSound := 'sound/plats/pt1_strt.wav';
    EndSound := 'sound/plats/pt1_end.wav';
    if TargetName = '' then
    begin
      { Start at the bottom: swap so "start" = bottom }
      Pos1 := Pos2;
      Pos2 := Vector3(0, 0, 0);
    end;
  end else
  if CName = 'func_button' then
  begin
    Kind := mkButton;
    MoveDir := MoveDirFromAngle(AEntity.Angle);
    Lip := AEntity.GetFloat('lip', 4);
    Dist := Abs(MoveDir.X) * Size.X + Abs(MoveDir.Y) * Size.Y + Abs(MoveDir.Z) * Size.Z - Lip;
    Pos2 := MoveDir * Dist;
    MoveLength := Abs(Dist);
    Speed := AEntity.Speed(40);
    WaitTime := AEntity.GetFloat('wait', 1);
    StartSound := 'sound/switches/butn2.wav';
  end else
  if CName = 'func_rotating' then
  begin
    Kind := mkRotating;
    if (SpawnFlags and ROTATING_X_AXIS) <> 0 then
      RotAxis := Vector3(0, 0, -1)
    else
    if (SpawnFlags and ROTATING_Y_AXIS) <> 0 then
      RotAxis := Vector3(1, 0, 0)
    else
      RotAxis := Vector3(0, 1, 0);
    if (SpawnFlags and ROTATING_REVERSE) <> 0 then
      RotAxis := -RotAxis;
    Speed := AEntity.Speed(100);
    Spinning := (SpawnFlags and ROTATING_START_ON) <> 0;
  end else
  if CName = 'func_train' then
  begin
    Kind := mkTrain;
    Speed := AEntity.Speed(100);
    TrainRunning := (TargetName = '') or ((SpawnFlags and TRAIN_START_ON) <> 0);
  end;

  Transform.Translation := BaseOffset + Pos1;
  if Kind = mkDoorRotating then
    Transform.Rotation := Vector4(RotAxis, Angle1);
end;

destructor TQuakeMover.Destroy;
begin
  { BeforeDestruction already detached this behavior from Transform }
  FreeAndNil(Scene);
  FreeAndNil(Transform);
  inherited Destroy;
end;

function TQuakeMover.GetEntityClass: String;
begin
  Result := Entity.ClassName;
end;

function TQuakeMover.WorldBox: TBox3D;
begin
  { In the TQuakeMap coordinate system (the map itself is kept at identity),
    so this works also while the design is being loaded }
  Result := Transform.BoundingBox;
end;

procedure TQuakeMover.ApplyPose;
begin
  case Kind of
    mkDoorRotating:
      Transform.Rotation := Vector4(RotAxis, Angle1 + (Angle2 - Angle1) * Progress);
    mkRotating:
      Transform.Rotation := Vector4(RotAxis, SpinAngle);
    mkTrain:
      ; { trains save their translation directly }
    mkStatic:
      ;
    else
      Transform.Translation := BaseOffset + Pos1 + (Pos2 - Pos1) * Progress;
  end;
end;

function TQuakeMover.Center: TVector3;
var
  Box: TBox3D;
  Mdl: TBSPModel;
begin
  Box := WorldBox;
  if not Box.IsEmpty then
    Exit(Box.Center);
  Mdl := Geometry.Bsp.Models[ModelIndex];
  Result := QuakeToCge((Mdl.Mins + Mdl.Maxs) / 2) + Transform.Translation;
end;

function TQuakeMover.Use: Boolean;
begin
  Result := False;
  case Kind of
    mkDoor, mkDoorRotating, mkPlat, mkButton:
      begin
        if State = msAtStart then
        begin
          State := msToEnd;
          Result := True;
        end else
        if (State = msAtEnd) and ((WaitTime < 0) or (Kind = mkPlat)) then
        begin
          { Toggle doors (wait -1) and targeted plats }
          State := msToStart;
          Result := True;
        end else
        if State = msAtEnd then
          StateTimer := WaitTime;
        if Result and (StartSound <> '') then
          Sounds.PlayAt(StartSound, Transform);
        { Buttons fire their targets when pressed }
        if Result and (Kind = mkButton) and (State = msToEnd) then
          Geometry.FireTargets(Target);
      end;
    mkRotating:
      begin
        Spinning := not Spinning;
        Result := True;
      end;
    mkTrain:
      begin
        TrainRunning := not TrainRunning;
        Result := True;
      end;
  end;
end;

procedure TQuakeMover.PlayerOnTop;
begin
  if (Kind = mkPlat) and (State = msAtStart) and (TargetName = '') then
  begin
    State := msToEnd;
    Sounds.PlayAt(StartSound, Transform);
  end else
  if (Kind = mkPlat) and (State = msAtEnd) then
    StateTimer := WaitTime;
end;

procedure TQuakeMover.Update(const SecondsPassed: Single);

  procedure ApplyProgress;
  begin
    if Kind = mkDoorRotating then
      Transform.Rotation := Vector4(RotAxis, Angle1 + (Angle2 - Angle1) * Progress)
    else
      Transform.Translation := BaseOffset + Pos1 + (Pos2 - Pos1) * Progress;
  end;

  procedure TrainNextCorner;
  var
    List: TQuakeEntityList;
    Mdl: TBSPModel;
  begin
    if (TrainCorner = nil) or (TrainCorner.Target = '') then
    begin
      TrainRunning := False;
      Exit;
    end;
    List := Geometry.Bsp.FindByTargetName(TrainCorner.Target);
    try
      if List.Count = 0 then
      begin
        TrainRunning := False;
        Exit;
      end;
      Mdl := Geometry.Bsp.Models[ModelIndex];
      TrainFrom := Transform.Translation;
      TrainCorner := List[0];
      TrainTo := QuakeToCge(TrainCorner.Origin - Mdl.Mins);
      Progress := 0;
      MoveLength := PointsDistance(TrainFrom, TrainTo);
    finally
      List.Free;
    end;
  end;

var
  Step: Single;
begin
  case Kind of
    mkStatic:
      ;
    mkRotating:
      if Spinning then
      begin
        SpinAngle := SpinAngle + DegToRad(Speed) * SecondsPassed;
        if SpinAngle > 2 * Pi then
          SpinAngle := SpinAngle - 2 * Pi;
        Transform.Rotation := Vector4(RotAxis, SpinAngle);
      end;
    mkTrain:
      begin
        if not TrainRunning then
          Exit;
        if StateTimer > 0 then
        begin
          StateTimer := StateTimer - SecondsPassed;
          Exit;
        end;
        if MoveLength <= 0.01 then
        begin
          TrainNextCorner;
          Exit;
        end;
        Progress := Min(1, Progress + Speed * SecondsPassed / MoveLength);
        Transform.Translation := TrainFrom + (TrainTo - TrainFrom) * Progress;
        if Progress >= 1 then
        begin
          if TrainCorner <> nil then
          begin
            StateTimer := TrainCorner.GetFloat('wait', 0);
            { path_corner can fire targets via "pathtarget" }
            Geometry.FireTargets(TrainCorner.GetField('pathtarget'));
          end;
          TrainNextCorner;
        end;
      end;
    else
      begin
        if MoveLength <= 0 then
          Step := 1
        else
          Step := Speed * SecondsPassed / MoveLength;
        case State of
          msToEnd:
            begin
              Progress := Min(1, Progress + Step);
              ApplyProgress;
              if Progress >= 1 then
              begin
                State := msAtEnd;
                StateTimer := WaitTime;
                if EndSound <> '' then
                  Sounds.PlayAt(EndSound, Transform);
              end;
            end;
          msAtEnd:
            if WaitTime >= 0 then
            begin
              StateTimer := StateTimer - SecondsPassed;
              if StateTimer <= 0 then
              begin
                State := msToStart;
                if StartSound <> '' then
                  Sounds.PlayAt(StartSound, Transform);
              end;
            end;
          msToStart:
            begin
              Progress := Max(0, Progress - Step);
              ApplyProgress;
              if Progress <= 0 then
              begin
                State := msAtStart;
                if EndSound <> '' then
                  Sounds.PlayAt(EndSound, Transform);
              end;
            end;
          msAtStart:
            ;
        end;
      end;
  end;
end;

{ TQuakeGeometry }

constructor TQuakeGeometry.Create(const ABsp: TQuakeBsp);
var
  World: TQuakeEntity;
begin
  inherited Create;
  FBsp := ABsp;
  FSceneWorld := TCastleScene.Create(nil);
  FSceneWorld.Name := 'WorldGeometry';
  FSceneWorld.PreciseCollisions := True;
  { Sky faces are not drawn (the skybox is visible through them), but they
    still need to block the player. }
  FSceneSkyClip := TCastleScene.Create(nil);
  FSceneSkyClip.Name := 'SkyClip';
  FSceneSkyClip.PreciseCollisions := True;
  FSceneSkyClip.Visible := False;
  FSceneLiquids := TCastleScene.Create(nil);
  FSceneLiquids.Name := 'Liquids';
  FSceneLiquids.Collides := False;
  FSceneLiquids.Pickable := False;
  FWorldTransform := TCastleTransform.Create(nil);
  FWorldTransform.Name := 'World';
  FWorldTransform.Add(FSceneWorld);
  FWorldTransform.Add(FSceneSkyClip);
  FWorldTransform.Add(FSceneLiquids);
  FMovers := TQuakeMoverList.Create(True);
  FAnimTextures := TQuakeAnimTexList.Create(True);
  FScrollNodes := specialize TList<TTextureTransformNode>.Create;
  FDynLightmaps := TQuakeDynamicLightmapList.Create(True);

  World := FBsp.FindEntity('worldspawn');
  if World <> nil then
    FSkyName := LowerCase(World.GetField('sky'));
end;

destructor TQuakeGeometry.Destroy;
begin
  FMovers.Free;
  FSceneWorld.Free;
  FSceneSkyClip.Free;
  FSceneLiquids.Free;
  FWorldTransform.Free;
  FAnimTextures.Free;
  FScrollNodes.Free;
  FDynLightmaps.Free;
  inherited Destroy;
end;

procedure TQuakeGeometry.RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
var
  Anim: TQuakeAnimTex;
  Info: TQuakeWalInfo;
  Cur: String;
begin
  Palette.LoadWal(TexName, Info);
  if Info.AnimName = '' then
    Exit;

  for Anim in FAnimTextures do
    if Anim.Frames.IndexOf(TexName) >= 0 then
    begin
      Anim.Nodes.Add(Node);
      Exit;
    end;

  Anim := TQuakeAnimTex.Create;
  Cur := TexName;
  while (Cur <> '') and (Anim.Frames.IndexOf(Cur) < 0) and (Anim.Frames.Count < 32) do
  begin
    Anim.Frames.Add(Cur);
    Palette.LoadWal(Cur, Info);
    Cur := Info.AnimName;
  end;
  Anim.Nodes.Add(Node);
  FAnimTextures.Add(Anim);
end;

procedure TQuakeGeometry.BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
  const SkyRoot: TX3DRootNode; const LiquidRoot: TX3DRootNode);
var
  Batches: TQuakeGeomBatchDict;
  SkyBatch: TQuakeGeomBatch;
  Mdl: TBSPModel;
  FaceIdx, VertCount, V, Row, Col, Ofs: Integer;
  Face: TBSPFace;
  TexInfo: TBSPTexInfo;
  TexName, Key: String;
  Batch: TQuakeGeomBatch;
  PolyVerts: array of TVector3;
  PolyUVs, PolyLMUVs: array of TVector2;
  RawVert: TVector3;
  Atlas, DynAtlas: TQuakeLightmapAtlas;
  LightmapTex, DynTex: TPixelTextureNode;
  Dyn: TQuakeDynamicLightmap;
  DynFace: TQuakeDynFace;
  IsDynamic: Boolean;
  StyleIdx: Integer;
  Ext: TQuakeFaceExtents;
  LmW, LmH, AtlasX, AtlasY: Integer;
  AllocOk: Boolean;
  Lightmaps: TBytes;
  BatchPair: specialize TPair<String, TQuakeGeomBatch>;
begin
  Mdl := FBsp.Models[ModelIdx];
  Lightmaps := FBsp.Lightmaps;
  if ModelIdx = 0 then
    Atlas := TQuakeLightmapAtlas.Create(2048, 2048)
  else
    Atlas := TQuakeLightmapAtlas.Create(512, 512);
  Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
  SkyBatch := TQuakeGeomBatch.Create('sky', SURF_SKY);
  DynAtlas := nil;
  Dyn := nil;
  try
    for FaceIdx := Mdl.FirstFace to Mdl.FirstFace + Mdl.NumFaces - 1 do
    begin
      Face := FBsp.Faces[FaceIdx];
      VertCount := Face.NumEdges;
      if (VertCount < 3) or (Face.TexInfoId < 0) then
        Continue;
      TexInfo := FBsp.TexInfos[Face.TexInfoId];
      TexName := FBsp.TexName(Face.TexInfoId);

      SetLength(PolyVerts, VertCount);
      SetLength(PolyUVs, VertCount);
      SetLength(PolyLMUVs, VertCount);
      for V := 0 to VertCount - 1 do
      begin
        RawVert := FBsp.GetFaceVertex(FaceIdx, V);
        PolyVerts[V] := QuakeToCge(RawVert);
        PolyUVs[V] := FBsp.GetFaceTexCoord(RawVert, Face.TexInfoId);
        PolyLMUVs[V] := Vector2(2.0 / Atlas.Width, 2.0 / Atlas.Height);
      end;

      if (TexInfo.Flags and SURF_SKY) <> 0 then
      begin
        SkyBatch.AddPolygon(PolyVerts, PolyUVs, PolyLMUVs);
        Continue;
      end;
      if (TexInfo.Flags and SURF_NODRAW) <> 0 then
        Continue;

      { Faces lit by animated or switchable light styles go to the dynamic atlas }
      IsDynamic := False;
      for StyleIdx := 0 to 3 do
        if (Face.Styles[StyleIdx] <> 0) and (Face.Styles[StyleIdx] <> 255) then
          IsDynamic := True;
      IsDynamic := IsDynamic and ((TexInfo.Flags and (SURF_WARP or SURF_TRANS33 or SURF_TRANS66)) = 0);

      Key := TexName + '|' + IntToStr(TexInfo.Flags and BatchFlagMask);
      if IsDynamic then
        Key := Key + '|dyn';
      if not Batches.TryGetValue(Key, Batch) then
      begin
        Batch := TQuakeGeomBatch.Create(TexName, TexInfo.Flags and BatchFlagMask);
        Batch.Dynamic := IsDynamic;
        Batches.Add(Key, Batch);
      end;

      { Copy this face's lightmap (first style) into the atlas }
      Ext := FBsp.FaceExtents[FaceIdx];
      LmW := Ext.LightmapWidth;
      LmH := Ext.LightmapHeight;
      AllocOk := False;
      if IsDynamic and (Face.LightmapOffset >= 0) and (LmW <= 256) and (LmH <= 256) then
      begin
        if DynAtlas = nil then
        begin
          if ModelIdx = 0 then
            DynAtlas := TQuakeLightmapAtlas.Create(1024, 1024)
          else
            DynAtlas := TQuakeLightmapAtlas.Create(256, 256);
          Dyn := TQuakeDynamicLightmap.Create;
        end;
        AllocOk := DynAtlas.Allocate(LmW, LmH, AtlasX, AtlasY);
        if AllocOk then
        begin
          DynFace.AtlasX := AtlasX;
          DynFace.AtlasY := AtlasY;
          DynFace.Width := LmW;
          DynFace.Height := LmH;
          DynFace.LightmapOffset := Face.LightmapOffset;
          for StyleIdx := 0 to 3 do
            DynFace.Styles[StyleIdx] := Face.Styles[StyleIdx];
          Dyn.AddFace(DynFace);
          for V := 0 to VertCount - 1 do
          begin
            RawVert := FBsp.GetFaceVertex(FaceIdx, V);
            PolyLMUVs[V] := Vector2(
              (AtlasX + (FBsp.TexS(RawVert, Face.TexInfoId) - Ext.TexMinS) / 16 + 0.5) / DynAtlas.Width,
              (AtlasY + (FBsp.TexT(RawVert, Face.TexInfoId) - Ext.TexMinT) / 16 + 0.5) / DynAtlas.Height);
          end;
        end else
        begin
          { Atlas full: keep the neutral UVs (the reserved mid-gray block of
            this atlas), as the batch samples the dynamic atlas anyway }
          WritelnWarning('QuakeGeometry', 'Light-style atlas full, face %d unlit', [FaceIdx]);
          AllocOk := True;
        end;
      end;

      if (not AllocOk) and Batch.UsesLightmap and (Face.LightmapOffset >= 0) and
         (LmW <= 256) and (LmH <= 256) and
         (Face.LightmapOffset + LmW * LmH * 3 <= Length(Lightmaps)) then
      begin
        AllocOk := Atlas.Allocate(LmW, LmH, AtlasX, AtlasY);
        if AllocOk then
        begin
          for Row := 0 to LmH - 1 do
            for Col := 0 to LmW - 1 do
            begin
              Ofs := Face.LightmapOffset + (Row * LmW + Col) * 3;
              Atlas.SetTexel(AtlasX + Col, AtlasY + Row,
                Lightmaps[Ofs], Lightmaps[Ofs + 1], Lightmaps[Ofs + 2]);
            end;
          for V := 0 to VertCount - 1 do
          begin
            RawVert := FBsp.GetFaceVertex(FaceIdx, V);
            PolyLMUVs[V] := Vector2(
              (AtlasX + (FBsp.TexS(RawVert, Face.TexInfoId) - Ext.TexMinS) / 16 + 0.5) / Atlas.Width,
              (AtlasY + (FBsp.TexT(RawVert, Face.TexInfoId) - Ext.TexMinT) / 16 + 0.5) / Atlas.Height);
          end;
        end;
      end;

      Batch.AddPolygon(PolyVerts, PolyUVs, PolyLMUVs);
    end;

    LightmapTex := Atlas.CreateTextureNode;
    DynTex := nil;
    if DynAtlas <> nil then
    begin
      DynTex := DynAtlas.CreateTextureNode;
      Dyn.Node := DynTex;
      Dyn.Compose(DynTex.FdImage.Value as TRGBImage, Lightmaps);
    end;
    for BatchPair in Batches do
    begin
      Batch := BatchPair.Value;
      if Batch.Dynamic and (DynTex <> nil) then
        Batch.CreateNodes(DynTex)
      else
        Batch.CreateNodes(LightmapTex);
      if Batch.Shape = nil then
        Continue;
      if (LiquidRoot <> nil) and ((Batch.Flags and SURF_WARP) <> 0) then
        LiquidRoot.AddChildren(Batch.Shape)
      else
        RootNode.AddChildren(Batch.Shape);
      RegisterAnimNode(Batch.TextureName, Batch.TexNode);
      if Batch.ScrollNode <> nil then
        FScrollNodes.Add(Batch.ScrollNode);
    end;
    { Nobody used the atlas (e.g. only sky / water): free it }
    if LightmapTex.ParentFieldsCount = 0 then
      LightmapTex.Free;
    if DynTex <> nil then
    begin
      if DynTex.ParentFieldsCount = 0 then
      begin
        DynTex.Free;
        Dyn.Free;
      end else
        FDynLightmaps.Add(Dyn);
    end;

    if (SkyRoot <> nil) and (SkyBatch.Coords.Count > 0) then
    begin
      SkyBatch.CreateNodes(nil);
      SkyRoot.AddChildren(SkyBatch.Shape);
    end;
  finally
    SkyBatch.Free;
    Batches.Free;
    Atlas.Free;
    DynAtlas.Free;
  end;
end;

procedure TQuakeGeometry.SetupMovers(const Parent: TCastleTransform);
var
  Ent: TQuakeEntity;
  MdlStr: String;
  MdlIdx: Integer;
  Mover: TQuakeMover;
  Root: TX3DRootNode;
  List: TQuakeEntityList;
begin
  for Ent in FBsp.Entities do
  begin
    MdlStr := Ent.Model;
    if (Length(MdlStr) < 2) or (MdlStr[1] <> '*') or not IsVisibleBrushClass(Ent.ClassName) then
      Continue;
    MdlIdx := StrToIntDef(Copy(MdlStr, 2, MaxInt), -1);
    if (MdlIdx <= 0) or (MdlIdx >= FBsp.ModelCount) then
      Continue;

    Mover := TQuakeMover.CreateMover(Self, Ent, MdlIdx);
    Root := TX3DRootNode.Create;
    BuildModelGeometry(MdlIdx, Root, nil);
    Mover.Scene.Load(Root, True);

    { Trains start at their first path_corner }
    if Mover.Kind = mkTrain then
    begin
      List := FBsp.FindByTargetName(Ent.Target);
      try
        if List.Count > 0 then
        begin
          Mover.TrainCorner := List[0];
          Mover.Transform.Translation := QuakeToCge(List[0].Origin - FBsp.Models[MdlIdx].Mins);
          Mover.MoveLength := 0; { pick next corner on first update }
        end else
          Mover.TrainRunning := False;
      finally
        List.Free;
      end;
    end;

    Parent.Add(Mover.Transform);
    FMovers.Add(Mover);
    WritelnLog('QuakeGeometry', 'Mover %d: %s model %s kind %d targetname "%s" at %s',
      [FMovers.Count - 1, Ent.ClassName, MdlStr, Ord(Mover.Kind), Ent.TargetName,
       Mover.Center.ToString]);
  end;
  WritelnLog('QuakeGeometry', 'Configured %d brush entities', [FMovers.Count]);
end;

procedure TQuakeGeometry.AddToWorld(const Parent: TCastleTransform);
var
  RootWorld, RootSky, RootLiquids: TX3DRootNode;
begin
  RootWorld := TX3DRootNode.Create;
  RootSky := TX3DRootNode.Create;
  RootLiquids := TX3DRootNode.Create;
  BuildModelGeometry(0, RootWorld, RootSky, RootLiquids);
  FSceneWorld.Load(RootWorld, True);
  FSceneSkyClip.Load(RootSky, True);
  FSceneLiquids.Load(RootLiquids, True);
  Parent.Add(FWorldTransform);
  SetupMovers(Parent);
  WritelnLog('QuakeGeometry', '%d animated texture chains, %d flowing surfaces, %d light-style faces, sky "%s"',
    [FAnimTextures.Count, FScrollNodes.Count, DynamicFaceCount, FSkyName]);
end;

function TQuakeGeometry.DynamicFaceCount: Integer;
var
  Dyn: TQuakeDynamicLightmap;
begin
  Result := 0;
  for Dyn in FDynLightmaps do
    Result := Result + Dyn.FaceCount;
end;

procedure TQuakeGeometry.FireTargets(const ATarget: String);
begin
  if (ATarget <> '') and Assigned(FOnFireTargets) then
    FOnFireTargets(ATarget);
end;

procedure TQuakeGeometry.Update(const SecondsPassed: Single);
var
  Mover: TQuakeMover;
  Anim: TQuakeAnimTex;
  Node: TImageTextureNode;
  Frame: Integer;
  Scroll: TTextureTransformNode;
  Dyn: TQuakeDynamicLightmap;
begin
  FTime := FTime + SecondsPassed;

  for Mover in FMovers do
    Mover.Update(SecondsPassed);

  { Relight faces with animated light styles when any style value changed }
  for Dyn in FDynLightmaps do
    if Dyn.ComposedVersion <> Lighting.Version then
    begin
      Dyn.Compose(Dyn.Node.FdImage.Value as TRGBImage, FBsp.Lightmaps);
      Dyn.Node.FdImage.Changed;
    end;

  { Quake 2 animates wall textures at 2 frames per second }
  Frame := Trunc(FTime * 2);
  if Frame <> FAnimFrame then
  begin
    FAnimFrame := Frame;
    for Anim in FAnimTextures do
      for Node in Anim.Nodes do
        Node.SetUrl(['quaketex:/' + WalTextureId(Anim.Frames[Frame mod Anim.Frames.Count])]);
  end;

  { SURF_FLOWING: same scroll as Quake 2 GL (-64 texture repeats per 40 seconds) }
  for Scroll in FScrollNodes do
    Scroll.Translation := Vector2(-64 * Frac(FTime / 40), 0);
end;

function TQuakeGeometry.FindMoverByModel(const AModel: String): TQuakeMover;
var
  Mover: TQuakeMover;
  Num: Integer;
begin
  Result := nil;
  if (Length(AModel) < 2) or (AModel[1] <> '*') then
    Exit;
  Num := StrToIntDef(Copy(AModel, 2, MaxInt), -1);
  for Mover in FMovers do
    if Mover.ModelIndex = Num then
      Exit(Mover);
end;

end.
