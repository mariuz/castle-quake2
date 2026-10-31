{ Compiles a TQuakeLevel (grid of cells with floor / ceiling heights) into a
  Quake 2 IBSP v38 map, like qbsp + qrad + qvis would for brushes made of
  such columns:

  - BSP tree: the grid is split in halves (k-d) until a rectangle of cells
    is uniform (same wall / floor / ceiling / sky / theme); an open
    rectangle becomes a node on its ceiling plane (solid above) and one on
    its floor plane (an empty leaf above, solid below).
  - Brushes: one box per solid leaf, so Quake 2's box traces (CM_BoxTrace)
    collide with exactly the walls, floors and ceilings.
  - Faces: per open cell its floor, ceiling and the walls towards solid or
    higher / lower neighbours (Doom's lower / upper sides), on the region's
    nodes (floors / ceilings, for R_LightPoint) and in its leaf.
  - Lightmaps: the "light" entities with qrad's linear falloff and a sky
    term, shadows from rays through the grid.
  - Visibility: one cluster per empty (and water) leaf; a cluster sees
    another when a sight line on the grid joins their rectangles through
    open cells (qvis-like but 2D: heights and doors never block, walls are
    shrunk a little, so it errs towards visible). PHS: the union of the
    PVS rows of the visible clusters. One area.

  The result loads with TQuakeBsp like a map from a PAK
  (RegisterLevelMap adds it to Pak as maps/<name>.bsp). }
unit QuakeBspBuilder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, CastleVectors, QuakeLevel;

type
  TBspBuildStats = record
    Nodes, Leafs, Faces, Brushes, Clusters, LightBytes, Models: Integer;
    { Average share of the clusters in a cluster's PVS (0..100) }
    VisPercent: Integer;
    { Time spent on the visibility, in milliseconds }
    VisMsec: Integer;
  end;

{ The map file of a level }
function BuildLevelBsp(const Level: TQuakeLevel; out Stats: TBspBuildStats): TMemoryStream;

{ Build the level and add it to Pak as maps/<Level.Name>.bsp; returns the
  map name to load }
function RegisterLevelMap(const Level: TQuakeLevel): String;

implementation

uses
  Math, StrUtils, Generics.Collections, CastleLog, QuakeBsp, QuakePak, QuakePalette;

type
  TPlaneList = specialize TList<TBSPPlane>;
  TNodeList = specialize TList<TBSPNode>;
  TLeafList = specialize TList<TBSPLeaf>;
  TFaceList = specialize TList<TBSPFace>;
  TTexInfoList = specialize TList<TBSPTexInfo>;
  TBrushList = specialize TList<TBSPBrush>;
  TBrushSideList = specialize TList<TBSPBrushSide>;
  TEdgeList = specialize TList<TBSPEdge>;
  TVecList = specialize TList<TVector3>;
  TIntList = specialize TList<LongInt>;
  TWordList = specialize TList<Word>;

  TRegion = record
    X0, Y0, X1, Y1: Integer;
    NodeCeil, NodeFloor, Leaf: Integer;
    { With water: the water plane's node and the leaf under the surface }
    NodeWater, WaterLeaf: Integer;
  end;
  TModelList = specialize TList<TBSPModel>;
  TRegionList = specialize TList<TRegion>;

  TLight = record
    Origin: TVector3;
    Value: Single;
    Color: TVector3;
    { Light style: 0 steady, 1..11 Quake 2's patterns (flicker, pulse...),
      32+ switchable (lights with a targetname, like qrad) }
    Style: Integer;
  end;

  { Where a face is: axis of its normal (0 x, 1 y, 2 z) and sign }
  TFaceAxis = record
    Axis: Integer;
    Positive: Boolean;
  end;

  TBuilder = class
    Level: TQuakeLevel;
    ZMin, ZMax: Integer;
    Planes: TPlaneList;
    PlaneIndex: specialize TDictionary<String, Integer>;
    Nodes: TNodeList;
    Leafs: TLeafList;
    Faces: TFaceList;
    TexInfos: TTexInfoList;
    TexInfoIndex: specialize TDictionary<String, Integer>;
    Brushes: TBrushList;
    BrushSides: TBrushSideList;
    Edges: TEdgeList;
    Vertices: TVecList;
    VertexIndex: specialize TDictionary<String, Integer>;
    SurfEdges: TIntList;
    LeafFaces: TWordList;
    LeafBrushes: TWordList;
    Regions: TRegionList;
    Lighting: TMemoryStream;
    Lights: array of TLight;
    Clusters: Integer;
    VisPercent, VisMsec: Integer;
    { Solid cells for sight (BuildVis), row by row }
    SolidCells: array of Boolean;
    Models: TModelList;
    { func_door entities of the door models, for the entity lump }
    DoorEntities: String;
    { Brush models of box triggers ("*N" per level entity, '' for none) }
    EntityModels: array of String;
    { Door building: cells of the current door (component id per cell) }
    DoorComp: array of Integer;
    CurrentDoor: Integer;
    { Height range of the current door / lift model }
    CurZLo, CurZHi: Integer;
    constructor Create(const ALevel: TQuakeLevel);
    destructor Destroy; override;
    function CellKey(const X, Y: Integer): String;
    function Uniform(const X0, Y0, X1, Y1: Integer): Boolean;
    function AddPlane(const Axis: Integer; const Positive: Boolean; const Dist: Single): Integer;
    function AxialPlane(const Axis: Integer; const Dist: Single): Integer;
    { A plane of any direction (types 3..5 by its largest axis) }
    function SlopePlane(const Normal: TVector3; const Dist: Single): Integer;
    { The plane of a ramp region's floor (normal up), False when flat }
    { The diagonal wall's plane of a cell (normal into the open half,
      through the middle), False when it has none }
    function DiagonalPlane(const X, Y: Integer; out Normal: TVector3; out Dist: Single): Boolean;
    { The solid prism behind a diagonal wall: a leaf with its brush }
    function NewPrismLeaf(const X, Y: Integer; const Plane: Integer): Integer;
    { The open triangle of a diagonal cell at height Z }
    procedure DiagonalTriangle(const X, Y: Integer; const Z: Single; out A, B, C: TVector3);
    procedure AddDiagonalWall(const X, Y: Integer);
    function RampPlane(const X0, Y0, X1, Y1: Integer; out Normal: TVector3; out Dist: Single): Boolean;
    { A solid leaf under a ramp: its brush is a wedge (box sides, bottom and
      the slope on top) }
    function NewWedgeLeaf(const Mins, Maxs: TVector3; const Plane: Integer): Integer;
    { A convex polygon face (clockwise from the front) on a plane }
    function AddPolyFace(const Verts: array of TVector3; const Normal: TVector3; const PlaneId, Side,
      TexAxis: Integer; const Tex: String; const Flags: Integer): Integer;
    { Lightmap of a face on the plane Normal . p = Dist (TexAxis: the axis
      its texture is projected along, as TexInfo) }
    procedure LightFacePlane(const FaceIdx: Integer; const Normal: TVector3; const Dist: Single;
      const TexAxis: Integer; const SkyCell: Boolean);
    function NewNode: Integer;
    procedure AddDummySolidLeaf;
    function NewLeaf(const Solid: Boolean; const Mins, Maxs: TVector3): Integer;
    { A leaf of water (CONTENTS_WATER, its own cluster, a water brush) }
    function NewWaterLeaf(const Mins, Maxs: TVector3; const Contents: Integer): Integer;
    { An empty leaf of a brush model (no cluster) }
    function NewModelEmptyLeaf(const Mins, Maxs: TVector3): Integer;
    function AddBoxBrush(const Mins, Maxs: TVector3; const Contents: Integer): Integer;
    function DoorKey(const X, Y: Integer): String;
    function BuildDoorRegion(const X0, Y0, X1, Y1: Integer): Integer;
    { A brush model of one box (buttons) }
    function BuildBoxModel(const Mins, Maxs: TVector3): Integer;
    procedure AddBoxFace(const FA: TFaceAxis; const Mins, Maxs: TVector3; const Tex: String);
    { func_door models (Lifts False) or func_plat models (Lifts True) of
      the groups of touching door / lift cells }
    procedure BuildMoverGroups(const Lifts: Boolean);
    procedure BuildButtons;
    function BuildRegion(const X0, Y0, X1, Y1: Integer): Integer;
    function TexInfo(const Tex: String; const Axis: Integer; const Flags: Integer): Integer;
    function AddVertex(const V: TVector3): Integer;
    { A rectangle on the plane (Axis, Positive normal at Dist), From..To
      in the other two axes; returns the face index }
    function AddFace(const FA: TFaceAxis; const Dist: Single; const AMin, AMax: TVector3;
      const Tex: String; const Flags: Integer): Integer;
    procedure AddWalls(const X, Y: Integer);
    procedure BuildFaces;
    function Blocked(const A, B: TVector3): Boolean;
    { Light of one style at P (the ambient and sky light are style 0) }
    function LightAt(const P, N: TVector3; const SkyCell: Boolean; const Style: Integer = 0): TVector3;
    procedure LightFace(const FaceIdx: Integer; const FA: TFaceAxis; const Dist: Single;
      const SkyCell: Boolean);
    procedure CollectLights;
    { The ladder box of an open cell (False: no ladder there) }
    function LadderBox(const X, Y: Integer; out Mins, Maxs: TVector3; out Dir: Integer): Boolean;
    { Ladder brushes (CONTENTS_SOLID | CONTENTS_LADDER) of a region's cells,
      listed in its air leaf }
    procedure AddLadderBrushes(const R: TRegion);
    procedure AddLadderFaces(const X, Y: Integer);
    { The glass pane of a window cell (False: none) }
    function WindowBox(const X, Y: Integer; out Mins, Maxs: TVector3; out Axis: Integer): Boolean;
    { Every window: a glass func_explosive model (CONTENTS_WINDOW) }
    procedure BuildWindows;
    { Box triggers (trigger_* with mins / maxs keys) as brush models }
    procedure BuildTriggerBoxes;
    { Grid sight from (AX, AY) to (BX, BY), in cells }
    function SightClear(const AX, AY, BX, BY: Double): Boolean;
    function RegionsSee(const A, B: TRegion): Boolean;
    { Compressed PVS and PHS rows of each cluster }
    procedure BuildVis(out Pvs, Phs: array of TBytes);
    function Write(out Stats: TBspBuildStats): TMemoryStream;
  end;

const
  BSP_IDENT_IBSP = $50534249; { 'IBSP' }

{ A list's items as bytes, for a lump }
generic function ListBytes<T>(const List: specialize TList<T>): TBytes;
var
  A: specialize TArray<T>;
begin
  A := List.ToArray;
  SetLength(Result, Length(A) * SizeOf(T));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(Result));
end;

function VecKey(const V: TVector3): String;
begin
  Result := Format('%.2f %.2f %.2f', [V.X, V.Y, V.Z]);
end;

function ClampShort(const V: Single): SmallInt;
begin
  Result := EnsureRange(Round(V), -32767, 32767);
end;

{ TBuilder }

constructor TBuilder.Create(const ALevel: TQuakeLevel);
var
  X, Y: Integer;
  C: PLevelCell;
begin
  inherited Create;
  Level := ALevel;
  Planes := TPlaneList.Create;
  PlaneIndex := specialize TDictionary<String, Integer>.Create;
  Nodes := TNodeList.Create;
  Leafs := TLeafList.Create;
  Faces := TFaceList.Create;
  TexInfos := TTexInfoList.Create;
  TexInfoIndex := specialize TDictionary<String, Integer>.Create;
  Brushes := TBrushList.Create;
  BrushSides := TBrushSideList.Create;
  Edges := TEdgeList.Create;
  Vertices := TVecList.Create;
  VertexIndex := specialize TDictionary<String, Integer>.Create;
  SurfEdges := TIntList.Create;
  LeafFaces := TWordList.Create;
  LeafBrushes := TWordList.Create;
  Regions := TRegionList.Create;
  Lighting := TMemoryStream.Create;
  Models := TModelList.Create;
  ZMin := 0;
  ZMax := 128;
  for Y := 0 to Level.Height - 1 do
    for X := 0 to Level.Width - 1 do
    begin
      C := Level.Cell(X, Y);
      if not C^.Solid then
      begin
        ZMin := Min(ZMin, C^.Floor);
        ZMax := Max(ZMax, C^.Ceil);
      end;
    end;
  ZMin := ZMin - 64;
  ZMax := ZMax + 64;
end;

destructor TBuilder.Destroy;
begin
  Planes.Free;
  PlaneIndex.Free;
  Nodes.Free;
  Leafs.Free;
  Faces.Free;
  TexInfos.Free;
  TexInfoIndex.Free;
  Brushes.Free;
  BrushSides.Free;
  Edges.Free;
  Vertices.Free;
  VertexIndex.Free;
  SurfEdges.Free;
  LeafFaces.Free;
  LeafBrushes.Free;
  Regions.Free;
  Lighting.Free;
  Models.Free;
  inherited Destroy;
end;

function TBuilder.CellKey(const X, Y: Integer): String;
var
  C: PLevelCell;
begin
  C := Level.Cell(X, Y);
  if C^.Solid then
    Result := '#'
  else
    Result := Format('%d,%d,%d,%d,%d,%d,%d', [C^.Floor, C^.Ceil, Ord(C^.Sky), C^.Theme, Ord(C^.Door),
      IfThen(CellHasWater(C), C^.Water, 0), Ord(CellHasWater(C) and C^.Slime)]) +
      Format(',%d,%d,%d', [Ord(CellHasWater(C) and C^.Lava), Ord(C^.Ladder), Level.RampDir(X, Y)]) + StrUtils.IfThen(C^.Window, ',g', '') +
      StrUtils.IfThen(C^.Diagonal > 0, Format(',x%d@%d,%d', [C^.Diagonal, X, Y]), '');
end;

function TBuilder.Uniform(const X0, Y0, X1, Y1: Integer): Boolean;
var
  X, Y: Integer;
  K: String;
begin
  K := CellKey(X0, Y0);
  for Y := Y0 to Y1 - 1 do
    for X := X0 to X1 - 1 do
      if CellKey(X, Y) <> K then
        Exit(False);
  Result := True;
end;

function TBuilder.AddPlane(const Axis: Integer; const Positive: Boolean; const Dist: Single): Integer;
var
  P: TBSPPlane;
  Key: String;
begin
  P := Default(TBSPPlane);
  P.Normal.Data[Axis] := IfThen(Positive, 1, -1);
  if Positive then
  begin
    P.Dist := Dist;
    P.PlaneType := Axis;
  end else
  begin
    P.Dist := -Dist;
    { PLANE_ANYX ..: not the axial shortcut of the traces (they assume a
      positive normal for types 0 .. 2) }
    P.PlaneType := Axis + 3;
  end;
  Key := Format('%d %d %.3f', [Axis, Ord(Positive), Dist]);
  if PlaneIndex.TryGetValue(Key, Result) then
    Exit;
  Result := Planes.Add(P);
  PlaneIndex.Add(Key, Result);
end;

function TBuilder.AxialPlane(const Axis: Integer; const Dist: Single): Integer;
begin
  Result := AddPlane(Axis, True, Dist);
end;

procedure TBuilder.AddDummySolidLeaf;
var
  L: TBSPLeaf;
begin
  L := Default(TBSPLeaf);
  L.Contents := CONTENTS_SOLID;
  L.Cluster := -1;
  Leafs.Add(L);
end;

function TBuilder.NewNode: Integer;
begin
  Result := Nodes.Add(Default(TBSPNode));
end;

function TBuilder.AddBoxBrush(const Mins, Maxs: TVector3; const Contents: Integer): Integer;
var
  B: TBSPBrush;
  I: Integer;
  Sides: array[0..5] of Integer;
  S: TBSPBrushSide;
begin
  Sides[0] := AddPlane(0, True, Maxs.X);
  Sides[1] := AddPlane(0, False, Mins.X);
  Sides[2] := AddPlane(1, True, Maxs.Y);
  Sides[3] := AddPlane(1, False, Mins.Y);
  Sides[4] := AddPlane(2, True, Maxs.Z);
  Sides[5] := AddPlane(2, False, Mins.Z);
  B.FirstSide := BrushSides.Count;
  B.NumSides := 6;
  B.Contents := Contents;
  for I := 0 to 5 do
  begin
    S.PlaneNum := Sides[I];
    S.TexInfo := 0;
    BrushSides.Add(S);
  end;
  Result := Brushes.Add(B);
end;

function TBuilder.NewWaterLeaf(const Mins, Maxs: TVector3; const Contents: Integer): Integer;
var
  L: TBSPLeaf;
  I: Integer;
begin
  L := Default(TBSPLeaf);
  for I := 0 to 2 do
  begin
    L.Mins[I] := ClampShort(Mins.Data[I]);
    L.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
  L.Contents := Contents;
  L.Cluster := Clusters;
  Inc(Clusters);
  L.Area := 1;
  L.FirstLeafBrush := LeafBrushes.Count;
  L.NumLeafBrushes := 1;
  LeafBrushes.Add(AddBoxBrush(Mins, Maxs, Contents));
  Result := Leafs.Add(L);
end;

function TBuilder.NewModelEmptyLeaf(const Mins, Maxs: TVector3): Integer;
var
  L: TBSPLeaf;
  I: Integer;
begin
  L := Default(TBSPLeaf);
  for I := 0 to 2 do
  begin
    L.Mins[I] := ClampShort(Mins.Data[I]);
    L.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
  L.Cluster := -1;
  Result := Leafs.Add(L);
end;

function TBuilder.NewLeaf(const Solid: Boolean; const Mins, Maxs: TVector3): Integer;
var
  L: TBSPLeaf;
  I: Integer;
begin
  L := Default(TBSPLeaf);
  for I := 0 to 2 do
  begin
    L.Mins[I] := ClampShort(Mins.Data[I]);
    L.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
  if Solid then
  begin
    L.Contents := CONTENTS_SOLID;
    L.Cluster := -1;
    L.Area := 0;
    { Its brush: the leaf's box }
    L.FirstLeafBrush := LeafBrushes.Count;
    L.NumLeafBrushes := 1;
    LeafBrushes.Add(AddBoxBrush(Mins, Maxs, CONTENTS_SOLID));
  end else
  begin
    L.Contents := 0;
    L.Cluster := Clusters;
    Inc(Clusters);
    L.Area := 1;
  end;
  Result := Leafs.Add(L);
end;

procedure SetNodeBounds(var N: TBSPNode; const Mins, Maxs: TVector3);
var
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    N.Mins[I] := ClampShort(Mins.Data[I]);
    N.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
end;

function TBuilder.BuildRegion(const X0, Y0, X1, Y1: Integer): Integer;
var
  C: PLevelCell;
  Mins, Maxs: TVector3;
  NodeCeil, NodeFloor, Mid: Integer;
  N: TBSPNode;
  R: TRegion;
  Front, Back: Integer;
  SlopeN, DiagN: TVector3;
  SlopeD, DiagD: Single;
begin
  Mins := Vector3(X0 * LevelCellSize, Y0 * LevelCellSize, ZMin);
  Maxs := Vector3(X1 * LevelCellSize, Y1 * LevelCellSize, ZMax);
  if Uniform(X0, Y0, X1, Y1) then
  begin
    C := Level.Cell(X0, Y0);
    if C^.Solid then
      Exit(-(NewLeaf(True, Mins, Maxs) + 1));
    { Ceiling node (solid above), [water node (air above, water below),]
      floor node (empty or water above, solid below) }
    NodeCeil := NewNode;
    R.NodeWater := -1;
    R.WaterLeaf := -1;
    if CellHasWater(C) then
      R.NodeWater := NewNode;
    NodeFloor := NewNode;
    R.X0 := X0; R.Y0 := Y0; R.X1 := X1; R.Y1 := Y1;
    R.NodeCeil := NodeCeil;
    R.NodeFloor := NodeFloor;
    if R.NodeWater >= 0 then
    begin
      R.Leaf := NewLeaf(False, Vector3(Mins.X, Mins.Y, C^.Water), Vector3(Maxs.X, Maxs.Y, C^.Ceil));
      R.WaterLeaf := NewWaterLeaf(Vector3(Mins.X, Mins.Y, C^.Floor), Vector3(Maxs.X, Maxs.Y, C^.Water),
        IfThen(C^.Lava, CONTENTS_LAVA, IfThen(C^.Slime, CONTENTS_SLIME, CONTENTS_WATER)));
    end else
      R.Leaf := NewLeaf(False, Vector3(Mins.X, Mins.Y, C^.Floor), Vector3(Maxs.X, Maxs.Y, C^.Ceil));
    if C^.Ladder then
      AddLadderBrushes(R);
    Regions.Add(R);

    N := Default(TBSPNode);
    N.PlaneNum := AxialPlane(2, C^.Ceil);
    N.Children[0] := -(NewLeaf(True, Vector3(Mins.X, Mins.Y, C^.Ceil), Maxs) + 1);
    if R.NodeWater >= 0 then
      N.Children[1] := R.NodeWater
    else
      N.Children[1] := NodeFloor;
    SetNodeBounds(N, Mins, Maxs);
    Nodes[NodeCeil] := N;

    if R.NodeWater >= 0 then
    begin
      N := Default(TBSPNode);
      N.PlaneNum := AxialPlane(2, C^.Water);
      N.Children[0] := -(R.Leaf + 1);
      N.Children[1] := NodeFloor;
      SetNodeBounds(N, Mins, Vector3(Maxs.X, Maxs.Y, C^.Ceil));
      Nodes[R.NodeWater] := N;
    end;

    N := Default(TBSPNode);
    if RampPlane(X0, Y0, X1, Y1, SlopeN, SlopeD) then
    begin
      { A ramp: the floor node on the slope, a wedge below it }
      N.PlaneNum := SlopePlane(SlopeN, SlopeD);
      N.Children[0] := -(R.Leaf + 1);
      N.Children[1] := -(NewWedgeLeaf(Mins, Vector3(Maxs.X, Maxs.Y,
        Max(Level.FloorAt(X0, Y0, Mins.X, Mins.Y), Level.FloorAt(X1 - 1, Y1 - 1, Maxs.X, Maxs.Y))),
        N.PlaneNum) + 1);
    end else
    begin
      N.PlaneNum := AxialPlane(2, C^.Floor);
      if R.WaterLeaf >= 0 then
        N.Children[0] := -(R.WaterLeaf + 1)
      else
        N.Children[0] := -(R.Leaf + 1);
      N.Children[1] := -(NewLeaf(True, Mins, Vector3(Maxs.X, Maxs.Y, C^.Floor)) + 1);
    end;
    SetNodeBounds(N, Mins, Vector3(Maxs.X, Maxs.Y, C^.Ceil));
    Nodes[NodeFloor] := N;
    { A diagonal wall: its plane first, the open half in front, the solid
      prism behind }
    if DiagonalPlane(X0, Y0, DiagN, DiagD) then
    begin
      Result := NewNode;
      N := Default(TBSPNode);
      N.PlaneNum := SlopePlane(DiagN, DiagD);
      N.Children[0] := NodeCeil;
      N.Children[1] := -(NewPrismLeaf(X0, Y0, N.PlaneNum) + 1);
      SetNodeBounds(N, Mins, Maxs);
      Nodes[Result] := N;
      Exit;
    end;
    Exit(NodeCeil);
  end;

  { Split the longer side in half; children[0] is the front (higher) half }
  Result := NewNode;
  N := Default(TBSPNode);
  if X1 - X0 >= Y1 - Y0 then
  begin
    Mid := (X0 + X1) div 2;
    N.PlaneNum := AxialPlane(0, Mid * LevelCellSize);
    Front := BuildRegion(Mid, Y0, X1, Y1);
    Back := BuildRegion(X0, Y0, Mid, Y1);
  end else
  begin
    Mid := (Y0 + Y1) div 2;
    N.PlaneNum := AxialPlane(1, Mid * LevelCellSize);
    Front := BuildRegion(X0, Mid, X1, Y1);
    Back := BuildRegion(X0, Y0, X1, Mid);
  end;
  N.Children[0] := Front;
  N.Children[1] := Back;
  SetNodeBounds(N, Mins, Maxs);
  Nodes[Result] := N;
end;

function TBuilder.TexInfo(const Tex: String; const Axis: Integer; const Flags: Integer): Integer;
var
  T: TBSPTexInfo;
  Key: String;
  I: Integer;
begin
  Key := Format('%s %d %d', [Tex, Axis, Flags]);
  if TexInfoIndex.TryGetValue(Key, Result) then
    Exit;
  T := Default(TBSPTexInfo);
  { Quake's TextureAxisFromPlane: floors / ceilings s = x, t = -y; walls
    facing x: s = y, t = -z; walls facing y: s = x, t = -z }
  case Axis of
    2:
      begin
        T.VecS := Vector4(1, 0, 0, 0);
        T.VecT := Vector4(0, -1, 0, 0);
      end;
    0:
      begin
        T.VecS := Vector4(0, 1, 0, 0);
        T.VecT := Vector4(0, 0, -1, 0);
      end;
    else
      begin
        T.VecS := Vector4(1, 0, 0, 0);
        T.VecT := Vector4(0, 0, -1, 0);
      end;
  end;
  T.Flags := Flags;
  for I := 1 to Min(Length(Tex), 31) do
    T.Texture[I - 1] := Tex[I];
  T.NextTexInfo := -1;
  Result := TexInfos.Add(T);
  TexInfoIndex.Add(Key, Result);
end;

function TBuilder.SlopePlane(const Normal: TVector3; const Dist: Single): Integer;
var
  P: TBSPPlane;
  Key: String;
  A: Integer;
begin
  Key := Format('s %.5f %.5f %.5f %.3f', [Normal.X, Normal.Y, Normal.Z, Dist]);
  if PlaneIndex.TryGetValue(Key, Result) then
    Exit;
  P := Default(TBSPPlane);
  P.Normal := Normal;
  P.Dist := Dist;
  A := 2;
  if (Abs(Normal.X) >= Abs(Normal.Y)) and (Abs(Normal.X) >= Abs(Normal.Z)) then
    A := 0
  else
  if Abs(Normal.Y) >= Abs(Normal.Z) then
    A := 1;
  P.PlaneType := 3 + A;
  Result := Planes.Add(P);
  PlaneIndex.Add(Key, Result);
end;

function TBuilder.DiagonalPlane(const X, Y: Integer; out Normal: TVector3; out Dist: Single): Boolean;
var
  D: Integer;
  SX, SY: Single;
begin
  D := Level.Cell(X, Y)^.Diagonal;
  Result := (D >= 1) and (D <= 4) and not Level.Cell(X, Y)^.Solid;
  if not Result then
    Exit;
  SX := IfThen(D in [1, 4], 1, -1);
  SY := IfThen(D in [1, 2], 1, -1);
  Normal := Vector3(-SX, -SY, 0).Normalize;
  Dist := Normal.X * (X + 0.5) * LevelCellSize + Normal.Y * (Y + 0.5) * LevelCellSize;
end;

function TBuilder.NewPrismLeaf(const X, Y: Integer; const Plane: Integer): Integer;
var
  L: TBSPLeaf;
  B: TBSPBrush;
  I, D: Integer;
  Sides: array[0..4] of Integer;
  S: TBSPBrushSide;
  Mins, Maxs: TVector3;
begin
  D := Level.Cell(X, Y)^.Diagonal;
  Mins := Vector3(X * LevelCellSize, Y * LevelCellSize, ZMin);
  Maxs := Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, ZMax);
  L := Default(TBSPLeaf);
  for I := 0 to 2 do
  begin
    L.Mins[I] := ClampShort(Mins.Data[I]);
    L.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
  L.Contents := CONTENTS_SOLID;
  L.Cluster := -1;
  { The triangle: the cell's two sides at the solid corner and the
    diagonal (its outward side faces the open half), floor to top }
  if D in [1, 4] then
    Sides[0] := AddPlane(0, True, Maxs.X)
  else
    Sides[0] := AddPlane(0, False, Mins.X);
  if D in [1, 2] then
    Sides[1] := AddPlane(1, True, Maxs.Y)
  else
    Sides[1] := AddPlane(1, False, Mins.Y);
  Sides[2] := Plane;
  Sides[3] := AddPlane(2, True, Maxs.Z);
  Sides[4] := AddPlane(2, False, Mins.Z);
  B.FirstSide := BrushSides.Count;
  B.NumSides := 5;
  B.Contents := CONTENTS_SOLID;
  for I := 0 to 4 do
  begin
    S.PlaneNum := Sides[I];
    S.TexInfo := 0;
    BrushSides.Add(S);
  end;
  L.FirstLeafBrush := LeafBrushes.Count;
  L.NumLeafBrushes := 1;
  LeafBrushes.Add(Brushes.Add(B));
  Result := Leafs.Add(L);
end;

procedure TBuilder.DiagonalTriangle(const X, Y: Integer; const Z: Single; out A, B, C: TVector3);
var
  D: Integer;
  X0, Y0, X1, Y1: Single;
begin
  D := Level.Cell(X, Y)^.Diagonal;
  X0 := X * LevelCellSize; Y0 := Y * LevelCellSize;
  X1 := X0 + LevelCellSize; Y1 := Y0 + LevelCellSize;
  { The three corners other than the solid one }
  case D of
    1: begin A := Vector3(X0, Y0, Z); B := Vector3(X1, Y0, Z); C := Vector3(X0, Y1, Z); end;
    2: begin A := Vector3(X1, Y0, Z); B := Vector3(X1, Y1, Z); C := Vector3(X0, Y0, Z); end;
    3: begin A := Vector3(X1, Y1, Z); B := Vector3(X0, Y1, Z); C := Vector3(X1, Y0, Z); end;
    else begin A := Vector3(X0, Y1, Z); B := Vector3(X0, Y0, Z); C := Vector3(X1, Y1, Z); end;
  end;
end;

procedure TBuilder.AddDiagonalWall(const X, Y: Integer);
var
  N, A, B, C: TVector3;
  Dist: Single;
  Z, ZTop, FaceIdx: Integer;
  Cell: PLevelCell;
begin
  if not DiagonalPlane(X, Y, N, Dist) then
    Exit;
  Cell := Level.Cell(X, Y);
  { The diagonal's ends: the open triangle's corners next to the solid one }
  DiagonalTriangle(X, Y, 0, A, B, C);
  Z := Cell^.Floor;
  while Z < Cell^.Ceil do
  begin
    ZTop := Min(Cell^.Ceil, Z + 256);
    FaceIdx := AddPolyFace([Vector3(B.X, B.Y, Z), Vector3(C.X, C.Y, Z), Vector3(C.X, C.Y, ZTop),
      Vector3(B.X, B.Y, ZTop)], N, SlopePlane(N, Dist), 0, 0, LevelThemes[Cell^.Theme].Wall, 0);
    LightFacePlane(FaceIdx, N, Dist, 0, Cell^.Sky);
    Z := ZTop;
  end;
end;

function TBuilder.RampPlane(const X0, Y0, X1, Y1: Integer; out Normal: TVector3; out Dist: Single): Boolean;
var
  D: Integer;
  C: PLevelCell;
  Rise, Back: Single;
begin
  D := Level.RampDir(X0, Y0);
  Result := D >= 0;
  if not Result then
    Exit;
  C := Level.Cell(X0, Y0);
  case D of
    0: Rise := Level.Cell(X0 + 1, Y0)^.Floor - C^.Floor;
    1: Rise := Level.Cell(X0 - 1, Y0)^.Floor - C^.Floor;
    2: Rise := Level.Cell(X0, Y0 + 1)^.Floor - C^.Floor;
    else Rise := Level.Cell(X0, Y0 - 1)^.Floor - C^.Floor;
  end;
  { Rising Rise over one cell along D: normal = (-slope along D) + up }
  Rise := Rise / LevelCellSize;
  case D of
    0: begin Normal := Vector3(-Rise, 0, 1); Back := X0 * LevelCellSize; end;
    1: begin Normal := Vector3(Rise, 0, 1); Back := X1 * LevelCellSize; end;
    2: begin Normal := Vector3(0, -Rise, 1); Back := Y0 * LevelCellSize; end;
    else begin Normal := Vector3(0, Rise, 1); Back := Y1 * LevelCellSize; end;
  end;
  Normal := Normal.Normalize;
  { Through the back edge at the low floor }
  if D < 2 then
    Dist := Normal.X * Back + Normal.Z * C^.Floor
  else
    Dist := Normal.Y * Back + Normal.Z * C^.Floor;
end;

function TBuilder.NewWedgeLeaf(const Mins, Maxs: TVector3; const Plane: Integer): Integer;
var
  L: TBSPLeaf;
  B: TBSPBrush;
  I: Integer;
  Sides: array[0..5] of Integer;
  S: TBSPBrushSide;
begin
  L := Default(TBSPLeaf);
  for I := 0 to 2 do
  begin
    L.Mins[I] := ClampShort(Mins.Data[I]);
    L.Maxs[I] := ClampShort(Maxs.Data[I]);
  end;
  L.Contents := CONTENTS_SOLID;
  L.Cluster := -1;
  Sides[0] := AddPlane(0, True, Maxs.X);
  Sides[1] := AddPlane(0, False, Mins.X);
  Sides[2] := AddPlane(1, True, Maxs.Y);
  Sides[3] := AddPlane(1, False, Mins.Y);
  Sides[4] := Plane;
  Sides[5] := AddPlane(2, False, Mins.Z);
  B.FirstSide := BrushSides.Count;
  B.NumSides := 6;
  B.Contents := CONTENTS_SOLID;
  for I := 0 to 5 do
  begin
    S.PlaneNum := Sides[I];
    S.TexInfo := 0;
    BrushSides.Add(S);
  end;
  L.FirstLeafBrush := LeafBrushes.Count;
  L.NumLeafBrushes := 1;
  LeafBrushes.Add(Brushes.Add(B));
  Result := Leafs.Add(L);
end;

function TBuilder.AddPolyFace(const Verts: array of TVector3; const Normal: TVector3; const PlaneId, Side,
  TexAxis: Integer; const Tex: String; const Flags: Integer): Integer;
var
  I, Count: Integer;
  Idx: array of Integer;
  F: TBSPFace;
  E: TBSPEdge;
  Cross: TVector3;
  Reverse: Boolean;
begin
  Count := Length(Verts);
  { Quake faces wind clockwise seen from the front }
  Cross := TVector3.CrossProduct(Verts[1] - Verts[0], Verts[2] - Verts[0]);
  Reverse := TVector3.DotProduct(Cross, Normal) > 0;
  SetLength(Idx, Count);
  for I := 0 to Count - 1 do
    if Reverse then
      Idx[I] := AddVertex(Verts[Count - 1 - I])
    else
      Idx[I] := AddVertex(Verts[I]);
  F := Default(TBSPFace);
  F.PlaneId := PlaneId;
  F.Side := Side;
  F.FirstEdge := SurfEdges.Count;
  F.NumEdges := Count;
  for I := 0 to Count - 1 do
  begin
    E.V0 := Idx[I];
    E.V1 := Idx[(I + 1) mod Count];
    SurfEdges.Add(Edges.Add(E));
  end;
  F.TexInfoId := TexInfo(Tex, TexAxis, Flags);
  F.Styles[0] := 255;
  F.Styles[1] := 255;
  F.Styles[2] := 255;
  F.Styles[3] := 255;
  F.LightmapOffset := -1;
  Result := Faces.Add(F);
end;

function TBuilder.AddVertex(const V: TVector3): Integer;
var
  Key: String;
begin
  Key := VecKey(V);
  if VertexIndex.TryGetValue(Key, Result) then
    Exit;
  Result := Vertices.Add(V);
  VertexIndex.Add(Key, Result);
end;

function TBuilder.AddFace(const FA: TFaceAxis; const Dist: Single; const AMin, AMax: TVector3;
  const Tex: String; const Flags: Integer): Integer;
var
  A1, A2, I: Integer;
  Corners: array[0..3] of TVector3;
  Normal, Cross: TVector3;
  Tmp: TVector3;
  F: TBSPFace;
  E: TBSPEdge;
  Idx: array[0..3] of Integer;
begin
  A1 := (FA.Axis + 1) mod 3;
  A2 := (FA.Axis + 2) mod 3;
  for I := 0 to 3 do
  begin
    Corners[I] := TVector3.Zero;
    Corners[I].Data[FA.Axis] := Dist;
  end;
  Corners[0].Data[A1] := AMin.Data[A1]; Corners[0].Data[A2] := AMin.Data[A2];
  Corners[1].Data[A1] := AMax.Data[A1]; Corners[1].Data[A2] := AMin.Data[A2];
  Corners[2].Data[A1] := AMax.Data[A1]; Corners[2].Data[A2] := AMax.Data[A2];
  Corners[3].Data[A1] := AMin.Data[A1]; Corners[3].Data[A2] := AMax.Data[A2];
  Normal := TVector3.Zero;
  Normal.Data[FA.Axis] := IfThen(FA.Positive, 1, -1);
  { Quake faces wind clockwise seen from the front }
  Cross := TVector3.CrossProduct(Corners[1] - Corners[0], Corners[2] - Corners[0]);
  if TVector3.DotProduct(Cross, Normal) > 0 then
  begin
    Tmp := Corners[1];
    Corners[1] := Corners[3];
    Corners[3] := Tmp;
  end;
  for I := 0 to 3 do
    Idx[I] := AddVertex(Corners[I]);

  F := Default(TBSPFace);
  F.PlaneId := AxialPlane(FA.Axis, Dist);
  F.Side := Ord(not FA.Positive);
  F.FirstEdge := SurfEdges.Count;
  F.NumEdges := 4;
  for I := 0 to 3 do
  begin
    E.V0 := Idx[I];
    E.V1 := Idx[(I + 1) mod 4];
    SurfEdges.Add(Edges.Add(E));
  end;
  F.TexInfoId := TexInfo(Tex, FA.Axis, Flags);
  F.Styles[0] := 255;
  F.Styles[1] := 255;
  F.Styles[2] := 255;
  F.Styles[3] := 255;
  F.LightmapOffset := -1;
  Result := Faces.Add(F);
end;

procedure TBuilder.AddWalls(const X, Y: Integer);
const
  DX: array[0..3] of Integer = (1, -1, 0, 0);
  DY: array[0..3] of Integer = (0, 0, 1, -1);
  MaxWall = 256;
var
  C, N: PLevelCell;
  D: Integer;
  FA: TFaceAxis;
  Dist: Single;
  Theme: TLevelTheme;
  N3: TVector3;

  procedure Wall(const Z0, Z1: Integer; const Tex: String);
  var
    Z, ZTop, FaceIdx: Integer;
    AMin, AMax: TVector3;
  begin
    Z := Z0;
    while Z < Z1 do
    begin
      ZTop := Min(Z1, Z + MaxWall);
      AMin := Vector3(X * LevelCellSize, Y * LevelCellSize, Z);
      AMax := Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, ZTop);
      FaceIdx := AddFace(FA, Dist, AMin, AMax, Tex, 0);
      LightFace(FaceIdx, FA, Dist, C^.Sky);
      Z := ZTop;
    end;
  end;

  { The step between this cell's floor and the neighbour's along the edge
    towards D, where either slopes: a quad, or a triangle where they cross }
  procedure SlopedStep(const D: Integer);
  var
    A, B, Pc: TVector3;
    BA, BB, TA, TB, DA, DB, U: Single;
    FaceIdx: Integer;
  begin
    { The edge's ends (A at the lower coordinate) }
    if DX[D] <> 0 then
    begin
      A := Vector3(Dist, Y * LevelCellSize, 0);
      B := Vector3(Dist, (Y + 1) * LevelCellSize, 0);
    end else
    begin
      A := Vector3(X * LevelCellSize, Dist, 0);
      B := Vector3((X + 1) * LevelCellSize, Dist, 0);
    end;
    BA := Level.FloorAt(X, Y, A.X, A.Y);
    BB := Level.FloorAt(X, Y, B.X, B.Y);
    TA := Min(Level.FloorAt(X + DX[D], Y + DY[D], A.X, A.Y), C^.Ceil);
    TB := Min(Level.FloorAt(X + DX[D], Y + DY[D], B.X, B.Y), C^.Ceil);
    DA := TA - BA;
    DB := TB - BB;
    if (DA <= 0.5) and (DB <= 0.5) then
      Exit;
    N3 := TVector3.Zero;
    N3.Data[FA.Axis] := IfThen(FA.Positive, 1, -1);
    if (DA > 0.5) and (DB > 0.5) then
      FaceIdx := AddPolyFace([Vector3(A.X, A.Y, BA), Vector3(B.X, B.Y, BB), Vector3(B.X, B.Y, TB),
        Vector3(A.X, A.Y, TA)], N3, AxialPlane(FA.Axis, Dist), Ord(not FA.Positive), FA.Axis, Theme.Step, 0)
    else
    begin
      { Where the top crosses the bottom }
      if DA > 0.5 then
        U := DA / (DA - Min(DB, 0))
      else
        U := Max(DA, 0) / (Max(DA, 0) - DB);
      Pc := A + (B - A) * U;
      Pc.Z := BA + (BB - BA) * U;
      if DA > 0.5 then
        FaceIdx := AddPolyFace([Vector3(A.X, A.Y, BA), Pc, Vector3(A.X, A.Y, TA)], N3,
          AxialPlane(FA.Axis, Dist), Ord(not FA.Positive), FA.Axis, Theme.Step, 0)
      else
        FaceIdx := AddPolyFace([Pc, Vector3(B.X, B.Y, BB), Vector3(B.X, B.Y, TB)], N3,
          AxialPlane(FA.Axis, Dist), Ord(not FA.Positive), FA.Axis, Theme.Step, 0);
    end;
    LightFace(FaceIdx, FA, Dist, C^.Sky);
  end;

begin
  C := Level.Cell(X, Y);
  Theme := LevelThemes[C^.Theme];
  for D := 0 to 3 do
  begin
    N := Level.Cell(X + DX[D], Y + DY[D]);
    { Behind this cell's own diagonal wall: nothing to see }
    if Level.DiagonalSolidSide(X, Y, D) then
      Continue;
    { The wall faces back into this cell }
    if DX[D] <> 0 then
    begin
      FA.Axis := 0;
      FA.Positive := DX[D] < 0;
      if DX[D] > 0 then
        Dist := (X + 1) * LevelCellSize
      else
        Dist := X * LevelCellSize;
    end else
    begin
      FA.Axis := 1;
      FA.Positive := DY[D] < 0;
      if DY[D] > 0 then
        Dist := (Y + 1) * LevelCellSize
      else
        Dist := Y * LevelCellSize;
    end;
    if N^.Solid or Level.DiagonalSolidSide(X + DX[D], Y + DY[D], D xor 1) then
      Wall(C^.Floor, C^.Ceil, Theme.Wall)
    else
    begin
      { Lower side: the neighbour's floor is higher (a step up); along a
        ramp the floors slope along the edge }
      if C^.Ramp or N^.Ramp then
        SlopedStep(D)
      else
      if N^.Floor > C^.Floor then
        Wall(C^.Floor, Min(N^.Floor, C^.Ceil), Theme.Step);
      { Upper side: the neighbour's ceiling is lower }
      if N^.Ceil < C^.Ceil then
        Wall(Max(N^.Ceil, C^.Floor), C^.Ceil, Theme.Wall);
    end;
  end;
end;

procedure TBuilder.BuildFaces;
var
  R: TRegion;
  I, X, Y, FirstLeafFace, FaceIdx, LightIdx: Integer;
  C: PLevelCell;
  FA: TFaceAxis;
  N: TBSPNode;
  L: TBSPLeaf;
  Theme: TLevelTheme;
  CeilTex, LiquidTex: String;
  LiquidFlags: Integer;
  HasLight, IsRamp: Boolean;
  LX, LY: Integer;
  SlopeN, TA, TB, TC: TVector3;
  SlopeD: Single;
begin
  for I := 0 to Regions.Count - 1 do
  begin
    R := Regions[I];
    C := Level.Cell(R.X0, R.Y0);
    Theme := LevelThemes[C^.Theme];
    FirstLeafFace := Faces.Count;

    { Floors, on the floor node }
    N := Nodes[R.NodeFloor];
    N.FirstFace := Faces.Count;
    FA.Axis := 2;
    FA.Positive := True;
    IsRamp := RampPlane(R.X0, R.Y0, R.X1, R.Y1, SlopeN, SlopeD);
    for Y := R.Y0 to R.Y1 - 1 do
      for X := R.X0 to R.X1 - 1 do
        if Level.Cell(X, Y)^.Diagonal in [1..4] then
        begin
          { A diagonal cell: its open triangle }
          DiagonalTriangle(X, Y, C^.Floor, TA, TB, TC);
          FaceIdx := AddPolyFace([TA, TB, TC], Vector3(0, 0, 1), AxialPlane(2, C^.Floor), 0, 2, Theme.Floor, 0);
          LightFacePlane(FaceIdx, Vector3(0, 0, 1), C^.Floor, 2, C^.Sky);
        end else
        if IsRamp then
        begin
          { A sloped quad, its corners on the ramp }
          FaceIdx := AddPolyFace([
            Vector3(X * LevelCellSize, Y * LevelCellSize, Level.FloorAt(X, Y, X * LevelCellSize, Y * LevelCellSize)),
            Vector3((X + 1) * LevelCellSize, Y * LevelCellSize, Level.FloorAt(X, Y, (X + 1) * LevelCellSize, Y * LevelCellSize)),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, Level.FloorAt(X, Y, (X + 1) * LevelCellSize, (Y + 1) * LevelCellSize)),
            Vector3(X * LevelCellSize, (Y + 1) * LevelCellSize, Level.FloorAt(X, Y, X * LevelCellSize, (Y + 1) * LevelCellSize))],
            SlopeN, Nodes[R.NodeFloor].PlaneNum, 0, 2, Theme.Floor, 0);
          LightFacePlane(FaceIdx, SlopeN, SlopeD, 2, C^.Sky);
        end else
        begin
          FaceIdx := AddFace(FA, C^.Floor, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), Theme.Floor, 0);
          LightFace(FaceIdx, FA, C^.Floor, C^.Sky);
        end;
    N.NumFaces := Faces.Count - N.FirstFace;
    Nodes[R.NodeFloor] := N;

    { Ceilings (sky, or a light panel over a light), on the ceiling node }
    N := Nodes[R.NodeCeil];
    N.FirstFace := Faces.Count;
    FA.Positive := False;
    for Y := R.Y0 to R.Y1 - 1 do
      for X := R.X0 to R.X1 - 1 do
      begin
        HasLight := False;
        for LightIdx := 0 to High(Lights) do
        begin
          Level.CellAt(Lights[LightIdx].Origin, LX, LY);
          if (LX = X) and (LY = Y) and (Lights[LightIdx].Origin.Z > C^.Ceil - 40) then
            HasLight := True;
        end;
        if C^.Sky then
          CeilTex := LevelSkyTexture
        else
        if HasLight then
          CeilTex := Theme.Light
        else
          CeilTex := Theme.Ceil;
        if Level.Cell(X, Y)^.Diagonal in [1..4] then
        begin
          DiagonalTriangle(X, Y, C^.Ceil, TA, TB, TC);
          FaceIdx := AddPolyFace([TA, TB, TC], Vector3(0, 0, -1), AxialPlane(2, C^.Ceil), 1, 2, CeilTex,
            IfThen(C^.Sky, SURF_SKY, 0));
          if not C^.Sky then
            LightFacePlane(FaceIdx, Vector3(0, 0, -1), -C^.Ceil, 2, False);
        end else
        begin
          FaceIdx := AddFace(FA, C^.Ceil, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), CeilTex,
            IfThen(C^.Sky, SURF_SKY, 0));
          if not C^.Sky then
            LightFace(FaceIdx, FA, C^.Ceil, False);
        end;
      end;
    N.NumFaces := Faces.Count - N.FirstFace;
    Nodes[R.NodeCeil] := N;

    { Walls and steps }
    for Y := R.Y0 to R.Y1 - 1 do
      for X := R.X0 to R.X1 - 1 do
      begin
        AddWalls(X, Y);
        AddLadderFaces(X, Y);
        AddDiagonalWall(X, Y);
      end;

    { The water surface, seen from above and from below (warped, no
      lightmap) }
    if R.NodeWater >= 0 then
    begin
      { Water is translucent; slime (sewage) and lava are opaque }
      if C^.Lava then
      begin
        LiquidTex := LevelLavaTexture;
        LiquidFlags := SURF_WARP;
      end else
      if C^.Slime then
      begin
        LiquidTex := LevelSlimeTexture;
        LiquidFlags := SURF_WARP;
      end else
      begin
        LiquidTex := LevelWaterTexture;
        LiquidFlags := SURF_WARP or SURF_TRANS33;
      end;
      for Y := R.Y0 to R.Y1 - 1 do
        for X := R.X0 to R.X1 - 1 do
        begin
          FA.Axis := 2;
          FA.Positive := True;
          AddFace(FA, C^.Water, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), LiquidTex, LiquidFlags);
          FA.Positive := False;
          AddFace(FA, C^.Water, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), LiquidTex, LiquidFlags);
        end;
    end;

    { Both the air and the water leaf see the region's faces }
    L := Leafs[R.Leaf];
    L.FirstLeafFace := LeafFaces.Count;
    L.NumLeafFaces := Faces.Count - FirstLeafFace;
    for FaceIdx := FirstLeafFace to Faces.Count - 1 do
      LeafFaces.Add(FaceIdx);
    Leafs[R.Leaf] := L;
    if R.WaterLeaf >= 0 then
    begin
      L := Leafs[R.WaterLeaf];
      L.FirstLeafFace := Leafs[R.Leaf].FirstLeafFace;
      L.NumLeafFaces := Leafs[R.Leaf].NumLeafFaces;
      Leafs[R.WaterLeaf] := L;
    end;
  end;
end;

function TBuilder.DoorKey(const X, Y: Integer): String;
begin
  if (not Level.InGrid(X, Y)) or (DoorComp[Y * Level.Width + X] <> CurrentDoor) then
    Result := '-'
  else
    Result := 'M';
end;

function TBuilder.BuildDoorRegion(const X0, Y0, X1, Y1: Integer): Integer;
var
  K: String;
  X, Y, Mid, NodeTop, NodeBottom: Integer;
  Same: Boolean;
  Mins, Maxs: TVector3;
  N: TBSPNode;
  Front, Back: Integer;
begin
  Mins := Vector3(X0 * LevelCellSize, Y0 * LevelCellSize, ZMin);
  Maxs := Vector3(X1 * LevelCellSize, Y1 * LevelCellSize, ZMax);
  K := DoorKey(X0, Y0);
  Same := True;
  for Y := Y0 to Y1 - 1 do
    for X := X0 to X1 - 1 do
      if DoorKey(X, Y) <> K then
        Same := False;
  if Same then
  begin
    if K = '-' then
      Exit(-(NewModelEmptyLeaf(Mins, Maxs) + 1));
    { The mover: solid from CurZLo to CurZHi, empty around }
    NodeTop := NewNode;
    NodeBottom := NewNode;
    N := Default(TBSPNode);
    N.PlaneNum := AxialPlane(2, CurZHi);
    N.Children[0] := -(NewModelEmptyLeaf(Vector3(Mins.X, Mins.Y, CurZHi), Maxs) + 1);
    N.Children[1] := NodeBottom;
    SetNodeBounds(N, Mins, Maxs);
    Nodes[NodeTop] := N;
    N := Default(TBSPNode);
    N.PlaneNum := AxialPlane(2, CurZLo);
    N.Children[0] := -(NewLeaf(True, Vector3(Mins.X, Mins.Y, CurZLo), Vector3(Maxs.X, Maxs.Y, CurZHi)) + 1);
    N.Children[1] := -(NewModelEmptyLeaf(Mins, Vector3(Maxs.X, Maxs.Y, CurZLo)) + 1);
    SetNodeBounds(N, Mins, Vector3(Maxs.X, Maxs.Y, CurZHi));
    Nodes[NodeBottom] := N;
    Exit(NodeTop);
  end;
  Result := NewNode;
  N := Default(TBSPNode);
  if X1 - X0 >= Y1 - Y0 then
  begin
    Mid := (X0 + X1) div 2;
    N.PlaneNum := AxialPlane(0, Mid * LevelCellSize);
    Front := BuildDoorRegion(Mid, Y0, X1, Y1);
    Back := BuildDoorRegion(X0, Y0, Mid, Y1);
  end else
  begin
    Mid := (Y0 + Y1) div 2;
    N.PlaneNum := AxialPlane(1, Mid * LevelCellSize);
    Front := BuildDoorRegion(X0, Mid, X1, Y1);
    Back := BuildDoorRegion(X0, Y0, X1, Mid);
  end;
  N.Children[0] := Front;
  N.Children[1] := Back;
  SetNodeBounds(N, Mins, Maxs);
  Nodes[Result] := N;
end;

function TBuilder.BuildBoxModel(const Mins, Maxs: TVector3): Integer;
var
  Axis, Side, Node, Next: Integer;
  N: TBSPNode;
  Lo, Hi: TVector3;
begin
  { Six nodes, one per side: outside each plane is empty, inside all of
    them is the solid box }
  Result := NewNode;
  Node := Result;
  Lo := Vector3(-32768, -32768, -32768);
  Hi := Vector3(32767, 32767, 32767);
  for Axis := 0 to 2 do
    for Side := 0 to 1 do
    begin
      N := Default(TBSPNode);
      SetNodeBounds(N, Mins, Maxs);
      if (Axis = 2) and (Side = 1) then
        Next := -(NewLeaf(True, Mins, Maxs) + 1)
      else
        Next := NewNode;
      if Side = 0 then
      begin
        { Above the max plane: empty }
        N.PlaneNum := AxialPlane(Axis, Maxs.Data[Axis]);
        N.Children[0] := -(NewModelEmptyLeaf(Lo, Hi) + 1);
        N.Children[1] := Next;
      end else
      begin
        { Below the min plane: empty }
        N.PlaneNum := AxialPlane(Axis, Mins.Data[Axis]);
        N.Children[0] := Next;
        N.Children[1] := -(NewModelEmptyLeaf(Lo, Hi) + 1);
      end;
      Nodes[Node] := N;
      Node := Next;
    end;
end;

procedure TBuilder.AddBoxFace(const FA: TFaceAxis; const Mins, Maxs: TVector3; const Tex: String);
var
  FaceIdx: Integer;
  Dist: Single;
begin
  if FA.Positive then
    Dist := Maxs.Data[FA.Axis]
  else
    Dist := Mins.Data[FA.Axis];
  FaceIdx := AddFace(FA, Dist, Mins, Maxs, Tex, 0);
  LightFace(FaceIdx, FA, Dist, False);
end;

procedure TBuilder.BuildMoverGroups(const Lifts: Boolean);
const
  DX: array[0..3] of Integer = (1, -1, 0, 0);
  DY: array[0..3] of Integer = (0, 0, 1, -1);
var
  X, Y, I, D, CX, CY, NX, NY, X0, Y0, X1, Y1, Z, ZTop, FaceIdx, Head: Integer;
  Queue: specialize TList<Integer>;
  N, Start: PLevelCell;
  M: TBSPModel;
  FA: TFaceAxis;
  Dist: Single;
  Tex, Ent: String;
  KeyModel: TBSPModel;
  KeyLocks: set of Byte;
  SecretYaw: Integer;

  function Member(const C: PLevelCell): Boolean;
  begin
    if C^.Solid then
      Exit(False);
    if Lifts then
      Result := C^.Lift and (C^.Floor = Start^.Floor) and (C^.LiftTop = Start^.LiftTop)
    else
      Result := C^.Door and (C^.Floor = Start^.Floor) and (C^.Ceil = Start^.Ceil) and
        (C^.Channel = Start^.Channel) and (C^.Key = Start^.Key) and (C^.SecretDoor = Start^.SecretDoor);
  end;

  { A secret door looks like the wall of the room beside it (the open
    neighbour with the highest ceiling) and slides away from that room:
    its texture and Quake yaw }
  procedure SecretLook(const CX, CY: Integer; out WallTex: String; out Yaw: Integer);
  const
    Yaws: array[0..3] of Integer = (0, 180, 90, 270);
  var
    D, Best: Integer;
    N: PLevelCell;
  begin
    WallTex := LevelThemes[0].Wall;
    Yaw := 0;
    Best := -1;
    for D := 0 to 3 do
    begin
      if not Level.InGrid(CX + DX[D], CY + DY[D]) then
        Continue;
      N := Level.Cell(CX + DX[D], CY + DY[D]);
      if N^.Solid or N^.Door then
        Continue;
      if (Best < 0) or (N^.Ceil > Level.Cell(CX + DX[Best], CY + DY[Best])^.Ceil) then
        Best := D;
    end;
    if Best < 0 then
      Exit;
    N := Level.Cell(CX + DX[Best], CY + DY[Best]);
    if N^.Theme < Length(LevelThemes) then
      WallTex := LevelThemes[N^.Theme].Wall;
    { Away from the room: the opposite of its direction }
    Yaw := Yaws[Best xor 1];
  end;

begin
  SetLength(DoorComp, Level.Width * Level.Height);
  for I := 0 to High(DoorComp) do
    DoorComp[I] := -1;
  CurrentDoor := 0;
  KeyLocks := [];
  Queue := specialize TList<Integer>.Create;
  try
    for Y := 0 to Level.Height - 1 do
      for X := 0 to Level.Width - 1 do
      begin
        Start := Level.Cell(X, Y);
        if DoorComp[Y * Level.Width + X] >= 0 then
          Continue;
        if Start^.Solid or (Lifts and not Start^.Lift) or ((not Lifts) and not Start^.Door) then
          Continue;
        { One mover: the touching cells of its kind with the same heights }
        Queue.Clear;
        Queue.Add(Y * Level.Width + X);
        DoorComp[Y * Level.Width + X] := CurrentDoor;
        X0 := X; Y0 := Y; X1 := X + 1; Y1 := Y + 1;
        Head := 0;
        while Head < Queue.Count do
        begin
          CX := Queue[Head] mod Level.Width;
          CY := Queue[Head] div Level.Width;
          Inc(Head);
          X0 := Min(X0, CX); Y0 := Min(Y0, CY); X1 := Max(X1, CX + 1); Y1 := Max(Y1, CY + 1);
          for D := 0 to 3 do
          begin
            NX := CX + DX[D];
            NY := CY + DY[D];
            if not Level.InGrid(NX, NY) or (DoorComp[NY * Level.Width + NX] >= 0) then
              Continue;
            if Member(Level.Cell(NX, NY)) then
            begin
              DoorComp[NY * Level.Width + NX] := CurrentDoor;
              Queue.Add(NY * Level.Width + NX);
            end;
          end;
        end;

        SecretYaw := 0;
        if Lifts then
          Tex := LevelLiftTexture
        else
        if Start^.SecretDoor then
          SecretLook(X, Y, Tex, SecretYaw)
        else
        if Start^.Key > 0 then
          Tex := LevelKeyDoorTextures[Start^.Key]
        else
          Tex := LevelDoorTexture;
        { Doors fill floor to ceiling; a lift is a slab with its top at
          LiftTop (built up, it starts down at the floor) }
        if Lifts then
        begin
          CurZHi := Start^.LiftTop;
          CurZLo := Start^.LiftTop - LevelLiftThickness;
        end else
        begin
          CurZLo := Start^.Floor;
          CurZHi := Start^.Ceil;
        end;
        M := Default(TBSPModel);
        M.HeadNode := BuildDoorRegion(X0, Y0, X1, Y1);
        M.FirstFace := Faces.Count;
        { Its sides towards open cells, its bottom, a lift's top }
        for I := 0 to Queue.Count - 1 do
        begin
          CX := Queue[I] mod Level.Width;
          CY := Queue[I] div Level.Width;
          for D := 0 to 3 do
          begin
            NX := CX + DX[D];
            NY := CY + DY[D];
            N := Level.Cell(NX, NY);
            if N^.Solid or (Level.InGrid(NX, NY) and (DoorComp[NY * Level.Width + NX] = CurrentDoor)) then
              Continue;
            if DX[D] <> 0 then
            begin
              FA.Axis := 0;
              FA.Positive := DX[D] > 0;
              Dist := IfThen(DX[D] > 0, (CX + 1) * LevelCellSize, CX * LevelCellSize);
            end else
            begin
              FA.Axis := 1;
              FA.Positive := DY[D] > 0;
              Dist := IfThen(DY[D] > 0, (CY + 1) * LevelCellSize, CY * LevelCellSize);
            end;
            Z := CurZLo;
            while Z < CurZHi do
            begin
              ZTop := Min(CurZHi, Z + 256);
              FaceIdx := AddFace(FA, Dist, Vector3(CX * LevelCellSize, CY * LevelCellSize, Z),
                Vector3((CX + 1) * LevelCellSize, (CY + 1) * LevelCellSize, ZTop), Tex, 0);
              LightFace(FaceIdx, FA, Dist, False);
              Z := ZTop;
            end;
          end;
          FA.Axis := 2;
          FA.Positive := False;
          FaceIdx := AddFace(FA, CurZLo, Vector3(CX * LevelCellSize, CY * LevelCellSize, 0),
            Vector3((CX + 1) * LevelCellSize, (CY + 1) * LevelCellSize, 0), Tex, 0);
          LightFace(FaceIdx, FA, CurZLo, False);
          if Lifts then
          begin
            FA.Positive := True;
            FaceIdx := AddFace(FA, CurZHi, Vector3(CX * LevelCellSize, CY * LevelCellSize, 0),
              Vector3((CX + 1) * LevelCellSize, (CY + 1) * LevelCellSize, 0), Tex, 0);
            LightFace(FaceIdx, FA, CurZHi, False);
          end;
        end;
        M.NumFaces := Faces.Count - M.FirstFace;
        M.Mins := Vector3(X0 * LevelCellSize, Y0 * LevelCellSize, CurZLo);
        M.Maxs := Vector3(X1 * LevelCellSize, Y1 * LevelCellSize, CurZHi);
        if Lifts then
          { func_plat: "height" from the top down to 2 below the floor (its
            top hidden in the floor, no z-fighting) }
          Ent := Format('"classname" "func_plat"' + LineEnding + '"model" "*%d"' + LineEnding +
            '"height" "%d"' + LineEnding + '"speed" "150"' + LineEnding,
            [Models.Count, Start^.LiftTop - Start^.Floor + 2])
        else
        if Start^.SecretDoor then
          { Quake 2 func_door_secret: shot open, first down (SECRET_1ST_DOWN),
            then away along the passage; stays open }
          Ent := Format('"classname" "func_door_secret"' + LineEnding + '"model" "*%d"' + LineEnding +
            '"angle" "%d"' + LineEnding + '"spawnflags" "4"' + LineEnding + '"wait" "-1"' + LineEnding,
            [Models.Count, SecretYaw])
        else
        if Start^.Key > 0 then
          { Locked: opened by the trigger_key of its key, then stays open }
          Ent := Format('"classname" "func_door"' + LineEnding + '"model" "*%d"' + LineEnding +
            '"angle" "-1"' + LineEnding + '"speed" "100"' + LineEnding + '"wait" "-1"' + LineEnding +
            '"lip" "8"' + LineEnding + '"targetname" "keydoor%d"' + LineEnding,
            [Models.Count, Start^.Key])
        else
        if Start^.Channel > 0 then
          { Opened by the channel's buttons, then stays open }
          Ent := Format('"classname" "func_door"' + LineEnding + '"model" "*%d"' + LineEnding +
            '"angle" "-1"' + LineEnding + '"speed" "100"' + LineEnding + '"wait" "-1"' + LineEnding +
            '"lip" "8"' + LineEnding + '"targetname" "switch%d"' + LineEnding,
            [Models.Count, Start^.Channel])
        else
          Ent := Format('"classname" "func_door"' + LineEnding + '"model" "*%d"' + LineEnding +
            '"angle" "-1"' + LineEnding + '"speed" "100"' + LineEnding + '"wait" "3"' + LineEnding +
            '"lip" "8"' + LineEnding, [Models.Count]);
        DoorEntities := DoorEntities + '{' + LineEnding + Ent + '}' + LineEnding;
        Models.Add(M);
        Inc(CurrentDoor);
        if (not Lifts) and (Start^.Key > 0) then
        begin
          { Quake 2's locked door: a trigger_multiple around the door fires
            a trigger_key, which opens the doors of that key when the player
            has it ("You need the Blue Key" otherwise). One trigger_key per
            key (it takes the key), so one key opens all its doors. }
          KeyModel := Default(TBSPModel);
          KeyModel.Mins := M.Mins - Vector3(40, 40, 0);
          KeyModel.Maxs := M.Maxs + Vector3(40, 40, 0);
          KeyModel.HeadNode := BuildBoxModel(KeyModel.Mins, KeyModel.Maxs);
          KeyModel.FirstFace := Faces.Count;
          KeyModel.NumFaces := 0;
          DoorEntities := DoorEntities + Format('{' + LineEnding + '"classname" "trigger_multiple"' + LineEnding +
            '"model" "*%d"' + LineEnding + '"target" "keylock%d"' + LineEnding + '"wait" "2"' + LineEnding +
            '}' + LineEnding, [Models.Count, Start^.Key]);
          if not (Start^.Key in KeyLocks) then
          begin
            Include(KeyLocks, Start^.Key);
            DoorEntities := DoorEntities + Format('{' + LineEnding + '"classname" "trigger_key"' + LineEnding +
              '"origin" "%d %d %d"' + LineEnding + '"targetname" "keylock%d"' + LineEnding +
              '"target" "keydoor%d"' + LineEnding + '"item" "%s"' + LineEnding + '}' + LineEnding,
              [Round((M.Mins.X + M.Maxs.X) / 2), Round((M.Mins.Y + M.Maxs.Y) / 2), Round(M.Mins.Z + 32),
               Start^.Key, Start^.Key, LevelKeyClasses[Start^.Key]]);
          end;
          Models.Add(KeyModel);
        end;
      end;
  finally
    Queue.Free;
  end;
end;

procedure TBuilder.BuildButtons;
var
  X, Y: Integer;
  C: PLevelCell;
  Mins, Maxs: TVector3;
  M: TBSPModel;
  FA: TFaceAxis;
begin
  for Y := 0 to Level.Height - 1 do
    for X := 0 to Level.Width - 1 do
    begin
      C := Level.Cell(X, Y);
      if C^.Solid or not C^.Button then
        Continue;
      { A pedestal in the middle of the cell, pressed down into the floor }
      Mins := Vector3((X + 0.5) * LevelCellSize - LevelButtonHalfWidth,
        (Y + 0.5) * LevelCellSize - LevelButtonHalfWidth, C^.Floor);
      Maxs := Vector3((X + 0.5) * LevelCellSize + LevelButtonHalfWidth,
        (Y + 0.5) * LevelCellSize + LevelButtonHalfWidth, C^.Floor + LevelButtonHeight);
      M := Default(TBSPModel);
      M.HeadNode := BuildBoxModel(Mins, Maxs);
      M.FirstFace := Faces.Count;
      FA.Axis := 0; FA.Positive := True; AddBoxFace(FA, Mins, Maxs, LevelButtonTexture);
      FA.Positive := False; AddBoxFace(FA, Mins, Maxs, LevelButtonTexture);
      FA.Axis := 1; FA.Positive := True; AddBoxFace(FA, Mins, Maxs, LevelButtonTexture);
      FA.Positive := False; AddBoxFace(FA, Mins, Maxs, LevelButtonTexture);
      FA.Axis := 2; FA.Positive := True; AddBoxFace(FA, Mins, Maxs, LevelButtonTexture);
      M.NumFaces := Faces.Count - M.FirstFace;
      M.Mins := Mins;
      M.Maxs := Maxs;
      DoorEntities := DoorEntities + Format('{' + LineEnding + '"classname" "func_button"' + LineEnding +
        '"model" "*%d"' + LineEnding + '"angle" "-2"' + LineEnding + '"lip" "4"' + LineEnding +
        '"wait" "-1"' + LineEnding + '"target" "switch%d"' + LineEnding + '}' + LineEnding,
        [Models.Count, C^.Channel]);
      Models.Add(M);
    end;
end;

function TBuilder.Blocked(const A, B: TVector3): Boolean;
var
  Steps, I, CX, CY: Integer;
  P: TVector3;
  C: PLevelCell;
begin
  Steps := Max(1, Ceil(PointsDistance(A, B) / 8));
  for I := 1 to Steps - 1 do
  begin
    P := A + (B - A) * (I / Steps);
    Level.CellAt(P, CX, CY);
    C := Level.Cell(CX, CY);
    if C^.Solid or (P.Z < C^.Floor - 0.5) or (P.Z > C^.Ceil + 0.5) then
      Exit(True);
  end;
  Result := False;
end;

function TBuilder.LightAt(const P, N: TVector3; const SkyCell: Boolean; const Style: Integer): TVector3;
var
  I: Integer;
  ToLight: TVector3;
  Dist, Dot, V: Single;
begin
  Result := TVector3.Zero;
  { A little ambient, more under the open sky }
  if Style = 0 then
  begin
    Result := Vector3(14, 14, 14);
    if SkyCell then
      Result := Result + Vector3(70, 70, 76);
  end;
  for I := 0 to High(Lights) do
  begin
    if Lights[I].Style <> Style then
      Continue;
    ToLight := Lights[I].Origin - P;
    Dist := ToLight.Length;
    if (Dist >= Lights[I].Value) or (Dist < 0.01) then
      Continue;
    Dot := TVector3.DotProduct(ToLight / Dist, N);
    if Dot <= 0 then
      Continue;
    if Blocked(P, Lights[I].Origin) then
      Continue;
    { qrad's linear point light: intensity - distance, by the angle }
    V := (Lights[I].Value - Dist) * (0.5 + 0.5 * Dot);
    Result := Result + Lights[I].Color * V;
  end;
end;

procedure TBuilder.LightFace(const FaceIdx: Integer; const FA: TFaceAxis; const Dist: Single;
  const SkyCell: Boolean);
var
  N: TVector3;
begin
  N := TVector3.Zero;
  N.Data[FA.Axis] := IfThen(FA.Positive, 1, -1);
  LightFacePlane(FaceIdx, N, Dist * N.Data[FA.Axis], FA.Axis, SkyCell);
end;

procedure TBuilder.LightFacePlane(const FaceIdx: Integer; const Normal: TVector3; const Dist: Single;
  const TexAxis: Integer; const SkyCell: Boolean);
var
  F: TBSPFace;
  T: TBSPTexInfo;
  I, W, H, SI, TI, A1, A2: Integer;
  MinS, MaxS, MinT, MaxT, S, TT: Single;
  V, P, Col, FMin, FMax: TVector3;
  B: array[0..2] of Byte;
  BMinS, BMinT: Integer;
  Styles: array[0..3] of Integer;
  StyleCount, K, J: Integer;
  Samples: array[0..3] of array of TVector3;
  Points: array of TVector3;
  Reaches: Boolean;
  Lit: Boolean;
begin
  F := Faces[FaceIdx];
  T := TexInfos[F.TexInfoId];
  MinS := 1e30; MaxS := -1e30; MinT := 1e30; MaxT := -1e30;
  FMin := Vector3(1e30, 1e30, 1e30);
  FMax := -FMin;
  for I := 0 to F.NumEdges - 1 do
  begin
    V := Vertices[Edges[SurfEdges[F.FirstEdge + I]].V0];
    S := TVector3.DotProduct(V, T.VecS.XYZ) + T.VecS.W;
    TT := TVector3.DotProduct(V, T.VecT.XYZ) + T.VecT.W;
    MinS := Min(MinS, S); MaxS := Max(MaxS, S);
    MinT := Min(MinT, TT); MaxT := Max(MaxT, TT);
    FMin := Vector3(Min(FMin.X, V.X), Min(FMin.Y, V.Y), Min(FMin.Z, V.Z));
    FMax := Vector3(Max(FMax.X, V.X), Max(FMax.Y, V.Y), Max(FMax.Z, V.Z));
  end;
  { Like TQuakeBsp.ComputeExtents (CalcSurfaceExtents) }
  BMinS := Floor(MinS / 16);
  BMinT := Floor(MinT / 16);
  W := Ceil(MaxS / 16) - BMinS + 1;
  H := Ceil(MaxT / 16) - BMinT + 1;
  A1 := (TexAxis + 1) mod 3;
  A2 := (TexAxis + 2) mod 3;
  F.LightmapOffset := Lighting.Position;
  { Styles reaching the face: 0 always, then up to 3 more (Quake 2's
    MAXLIGHTMAPS), each a block of samples after the previous }
  Styles[0] := 0;
  StyleCount := 1;
  for I := 0 to High(Lights) do
  begin
    if (Lights[I].Style = 0) or (StyleCount = 4) then
      Continue;
    Reaches := (Lights[I].Origin.X > FMin.X - Lights[I].Value) and (Lights[I].Origin.X < FMax.X + Lights[I].Value) and
      (Lights[I].Origin.Y > FMin.Y - Lights[I].Value) and (Lights[I].Origin.Y < FMax.Y + Lights[I].Value) and
      (Lights[I].Origin.Z > FMin.Z - Lights[I].Value) and (Lights[I].Origin.Z < FMax.Z + Lights[I].Value);
    if not Reaches then
      Continue;
    Lit := False;
    for K := 0 to StyleCount - 1 do
      if Styles[K] = Lights[I].Style then
        Lit := True;
    if not Lit then
    begin
      Styles[StyleCount] := Lights[I].Style;
      Inc(StyleCount);
    end;
  end;
  SetLength(Points, W * H);
  for TI := 0 to H - 1 do
    for SI := 0 to W - 1 do
    begin
      S := (BMinS + SI) * 16;
      TT := (BMinT + TI) * 16;
      { Back from texture space (axial vectors with no offset) }
      P := TVector3.Zero;
      case TexAxis of
        2:
          begin
            P.X := S;
            P.Y := -TT;
          end;
        0:
          begin
            P.Y := S;
            P.Z := -TT;
          end;
        else
          begin
            P.X := S;
            P.Z := -TT;
          end;
      end;
      { Samples on the face, a unit in front of it: within its box, on its
        plane along the projection axis }
      P.Data[A1] := EnsureRange(P.Data[A1], FMin.Data[A1] + 1, FMax.Data[A1] - 1);
      P.Data[A2] := EnsureRange(P.Data[A2], FMin.Data[A2] + 1, FMax.Data[A2] - 1);
      P.Data[TexAxis] := (Dist - Normal.Data[A1] * P.Data[A1] - Normal.Data[A2] * P.Data[A2]) /
        Normal.Data[TexAxis];
      P := P + Normal;
      Points[TI * W + SI] := P;
    end;
  { Sample each style; drop styles that light nothing here }
  J := 0;
  for K := 0 to StyleCount - 1 do
  begin
    SetLength(Samples[J], W * H);
    Lit := K = 0;
    for I := 0 to W * H - 1 do
    begin
      Col := LightAt(Points[I], Normal, SkyCell, Styles[K]);
      Samples[J][I] := Col;
      if Max(Col.X, Max(Col.Y, Col.Z)) >= 1 then
        Lit := True;
    end;
    if Lit then
    begin
      Styles[J] := Styles[K];
      Inc(J);
    end;
  end;
  StyleCount := J;
  for K := 0 to 3 do
    if K < StyleCount then
      F.Styles[K] := Styles[K]
    else
      F.Styles[K] := 255;
  for K := 0 to StyleCount - 1 do
    for I := 0 to W * H - 1 do
    begin
      Col := Samples[K][I];
      B[0] := EnsureRange(Round(Col.X), 0, 255);
      B[1] := EnsureRange(Round(Col.Y), 0, 255);
      B[2] := EnsureRange(Round(Col.Z), 0, 255);
      Lighting.WriteBuffer(B, 3);
    end;
  Faces[FaceIdx] := F;
end;

function TBuilder.LadderBox(const X, Y: Integer; out Mins, Maxs: TVector3; out Dir: Integer): Boolean;
var
  C: PLevelCell;
  Top: Integer;
  X0, Y0, X1, Y1, CX, CY: Single;
begin
  Result := False;
  C := Level.Cell(X, Y);
  if C^.Solid or not C^.Ladder then
    Exit;
  Dir := Level.LadderDir(X, Y);
  if Dir < 0 then
    Exit;
  case Dir of
    0: Top := Level.Cell(X + 1, Y)^.Floor;
    1: Top := Level.Cell(X - 1, Y)^.Floor;
    2: Top := Level.Cell(X, Y + 1)^.Floor;
    else Top := Level.Cell(X, Y - 1)^.Floor;
  end;
  X0 := X * LevelCellSize;
  Y0 := Y * LevelCellSize;
  X1 := X0 + LevelCellSize;
  Y1 := Y0 + LevelCellSize;
  CX := X0 + LevelCellSize / 2;
  CY := Y0 + LevelCellSize / 2;
  { A slab against the wall towards Dir, from the floor to the step's top }
  case Dir of
    0: begin Mins := Vector3(X1 - LevelLadderDepth, CY - LevelLadderHalfWidth, C^.Floor);
         Maxs := Vector3(X1, CY + LevelLadderHalfWidth, Top); end;
    1: begin Mins := Vector3(X0, CY - LevelLadderHalfWidth, C^.Floor);
         Maxs := Vector3(X0 + LevelLadderDepth, CY + LevelLadderHalfWidth, Top); end;
    2: begin Mins := Vector3(CX - LevelLadderHalfWidth, Y1 - LevelLadderDepth, C^.Floor);
         Maxs := Vector3(CX + LevelLadderHalfWidth, Y1, Top); end;
    else begin Mins := Vector3(CX - LevelLadderHalfWidth, Y0, C^.Floor);
         Maxs := Vector3(CX + LevelLadderHalfWidth, Y0 + LevelLadderDepth, Top); end;
  end;
  Result := True;
end;

procedure TBuilder.AddLadderBrushes(const R: TRegion);
var
  X, Y, Dir: Integer;
  Mins, Maxs: TVector3;
  L: TBSPLeaf;
begin
  L := Leafs[R.Leaf];
  L.FirstLeafBrush := LeafBrushes.Count;
  L.NumLeafBrushes := 0;
  for Y := R.Y0 to R.Y1 - 1 do
    for X := R.X0 to R.X1 - 1 do
      if LadderBox(X, Y, Mins, Maxs, Dir) then
      begin
        LeafBrushes.Add(AddBoxBrush(Mins, Maxs, CONTENTS_SOLID or CONTENTS_LADDER));
        Inc(L.NumLeafBrushes);
      end;
  { Box traces skip leaves whose contents miss the mask (CM_TraceToLeaf):
    player traces (MASK_PLAYERSOLID has PLAYERCLIP) and the ladder test
    look in, monsters and shots don't (Quake 2 leaves get the OR of their
    brushes; SOLID here would make the room solid to point tests) }
  if L.NumLeafBrushes > 0 then
    L.Contents := CONTENTS_PLAYERCLIP or CONTENTS_LADDER;
  Leafs[R.Leaf] := L;
end;

procedure TBuilder.AddLadderFaces(const X, Y: Integer);
var
  Mins, Maxs: TVector3;
  Dir: Integer;
  FA: TFaceAxis;
begin
  if not LadderBox(X, Y, Mins, Maxs, Dir) then
    Exit;
  { The front (away from the wall), both sides and the top }
  FA.Axis := Dir div 2;
  FA.Positive := Odd(Dir);
  AddBoxFace(FA, Mins, Maxs, LevelLadderTexture);
  FA.Axis := 1 - Dir div 2;
  FA.Positive := True;
  AddBoxFace(FA, Mins, Maxs, LevelLadderTexture);
  FA.Positive := False;
  AddBoxFace(FA, Mins, Maxs, LevelLadderTexture);
  FA.Axis := 2;
  FA.Positive := True;
  AddBoxFace(FA, Mins, Maxs, LevelLadderTexture);
end;

function TBuilder.WindowBox(const X, Y: Integer; out Mins, Maxs: TVector3; out Axis: Integer): Boolean;
var
  C: PLevelCell;
begin
  C := Level.Cell(X, Y);
  Axis := Level.WindowAxis(X, Y);
  Result := Axis >= 0;
  if not Result then
    Exit;
  Mins := Vector3(X * LevelCellSize, Y * LevelCellSize, C^.Floor);
  Maxs := Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, C^.Ceil);
  { A thin pane across the middle, facing along Axis }
  Mins.Data[Axis] := (Mins.Data[Axis] + Maxs.Data[Axis] - LevelWindowThickness) / 2;
  Maxs.Data[Axis] := Mins.Data[Axis] + LevelWindowThickness;
end;

{ "x y z" to a vector (missing / bad numbers are 0) }
function ParseVector(const S: String): TVector3;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := TVector3.Zero;
  Parts := Trim(S).Split([' '], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to Min(2, High(Parts)) do
    Result.Data[I] := StrToFloatDef(Parts[I], 0, DefaultFormatSettings);
end;

procedure TBuilder.BuildTriggerBoxes;
var
  I: Integer;
  E: TLevelEntity;
  M: TBSPModel;
  Lo, Hi: TVector3;
begin
  SetLength(EntityModels, Level.Entities.Count);
  for I := 0 to Level.Entities.Count - 1 do
  begin
    E := Level.Entities[I];
    if (Copy(E.EntClass, 1, 8) <> 'trigger_') or (E.Key('model') <> '') or
       (E.Key('mins') = '') or (E.Key('maxs') = '') then
      Continue;
    Lo := E.Origin + ParseVector(E.Key('mins'));
    Hi := E.Origin + ParseVector(E.Key('maxs'));
    if (Hi.X <= Lo.X) or (Hi.Y <= Lo.Y) or (Hi.Z <= Lo.Z) then
      Continue;
    { A faceless box model, like the triggers of the key doors: a real
      Quake 2 brush trigger instead of our mins / maxs extension }
    M := Default(TBSPModel);
    M.Mins := Lo;
    M.Maxs := Hi;
    M.HeadNode := BuildBoxModel(Lo, Hi);
    M.FirstFace := Faces.Count;
    M.NumFaces := 0;
    EntityModels[I] := '*' + IntToStr(Models.Count);
    Models.Add(M);
  end;
end;

procedure TBuilder.BuildWindows;
var
  X, Y, Axis, Head, I: Integer;
  Mins, Maxs: TVector3;
  M: TBSPModel;
  FA: TFaceAxis;
  L: TBSPLeaf;
  B: TBSPBrush;
begin
  for Y := 0 to Level.Height - 1 do
    for X := 0 to Level.Width - 1 do
    begin
      if not WindowBox(X, Y, Mins, Maxs, Axis) then
        Continue;
      M := Default(TBSPModel);
      Head := BuildBoxModel(Mins, Maxs);
      { The pane's leaf and brush are glass: player, monster and shot
        traces stop at it, sight (MASK_OPAQUE) passes }
      for I := 0 to Leafs.Count - 1 do
        if (Leafs[I].Contents = CONTENTS_SOLID) and (Leafs[I].FirstLeafBrush = LeafBrushes.Count - 1) then
        begin
          L := Leafs[I];
          L.Contents := CONTENTS_WINDOW;
          Leafs[I] := L;
          B := Brushes[LeafBrushes[L.FirstLeafBrush]];
          B.Contents := CONTENTS_WINDOW;
          Brushes[LeafBrushes[L.FirstLeafBrush]] := B;
        end;
      M.HeadNode := Head;
      M.FirstFace := Faces.Count;
      { Both sides of the pane: translucent, no lightmap (like qrad) }
      FA.Axis := Axis;
      FA.Positive := True;
      AddFace(FA, Maxs.Data[Axis], Mins, Maxs, LevelWindowTexture, SURF_TRANS33);
      FA.Positive := False;
      AddFace(FA, Mins.Data[Axis], Mins, Maxs, LevelWindowTexture, SURF_TRANS33);
      M.NumFaces := Faces.Count - M.FirstFace;
      M.Mins := Mins;
      M.Maxs := Maxs;
      { Quake 2 glass: a func_explosive without dmg (debris, no blast);
        "_glass" (ours) makes it shatter with world/brkglas.wav }
      DoorEntities := DoorEntities + Format('{' + LineEnding + '"classname" "func_explosive"' + LineEnding +
        '"model" "*%d"' + LineEnding + '"health" "10"' + LineEnding + '"mass" "50"' + LineEnding +
        '"_glass" "1"' + LineEnding + '}' + LineEnding, [Models.Count]);
      Models.Add(M);
    end;
end;

procedure TBuilder.CollectLights;
var
  E: TLevelEntity;
  L: TLight;
  Parts: TStringArray;
  Fmt: TFormatSettings;
  X, Y, I: Integer;
  Switchable: TStringList;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Lights := nil;
  Switchable := TStringList.Create;
  try
  for E in Level.Entities do
  begin
    if E.EntClass <> 'light' then
      Continue;
    { qrad: lights with a targetname share a style from 32 on (the game
      switches it); the entity gets the "style" key }
    L.Style := EnsureRange(StrToIntDef(E.Key('style', '0'), 0), 0, 63);
    if E.Key('targetname') <> '' then
    begin
      I := Switchable.IndexOf(E.Key('targetname'));
      if I < 0 then
        I := Switchable.Add(E.Key('targetname'));
      L.Style := 32 + I;
      E.SetKey('style', IntToStr(L.Style));
    end;
    L.Origin := E.Origin;
    L.Value := StrToFloatDef(E.Key('light', '300'), 300, Fmt);
    L.Color := Vector3(1, 1, 1);
    Parts := E.Key('_color', '').Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Parts) >= 3 then
      L.Color := Vector3(StrToFloatDef(Parts[0], 1, Fmt), StrToFloatDef(Parts[1], 1, Fmt),
        StrToFloatDef(Parts[2], 1, Fmt));
    SetLength(Lights, Length(Lights) + 1);
    Lights[High(Lights)] := L;
  end;
  finally
    Switchable.Free;
  end;
  L.Style := 0;
  { Lava glows: an orange light over every other lava cell }
  for Y := 0 to Level.Height - 1 do
    for X := 0 to Level.Width - 1 do
      if CellHasWater(Level.Cell(X, Y)) and Level.Cell(X, Y)^.Lava and ((X + Y) mod 2 = 0) then
      begin
        L.Origin := Vector3((X + 0.5) * LevelCellSize, (Y + 0.5) * LevelCellSize, Level.Cell(X, Y)^.Water + 40);
        L.Value := 160;
        L.Color := Vector3(1, 0.45, 0.15);
        SetLength(Lights, Length(Lights) + 1);
        Lights[High(Lights)] := L;
      end;
end;

const
  { Walls are this much (in cells) thinner for sight: lines grazing a
    corner stay clear }
  SightShrink = 4 / LevelCellSize;
  SightInset = 0.01;

function TBuilder.SightClear(const AX, AY, BX, BY: Double): Boolean;
var
  CX, CY, EX, EY, SX, SY, Steps: Integer;
  DX, DY, TMaxX, TMaxY, TDeltaX, TDeltaY: Double;

  function SolidAt(const X, Y: Integer): Boolean;
  begin
    Result := (X < 0) or (Y < 0) or (X >= Level.Width) or (Y >= Level.Height) or
      SolidCells[Y * Level.Width + X];
  end;

  { Does the segment cross solid cell (X, Y), shrunk on its open sides
    (walls of several cells stay closed along their seams)? }
  function Blocks(const X, Y: Integer): Boolean;
  var
    T0, T1: Double;

    function Inset(const NX, NY: Integer): Double;
    begin
      if SolidAt(NX, NY) then
        Result := 0
      else
        Result := SightShrink;
    end;

    function Slab(const P, D, Lo, Hi: Double): Boolean;
    var
      TA, TB, Tmp: Double;
    begin
      if Abs(D) < 1e-12 then
        { Along a seam between walls (Lo or Hi not inset) counts as inside }
        Exit((P >= Lo) and (P <= Hi));
      TA := (Lo - P) / D;
      TB := (Hi - P) / D;
      if TA > TB then
      begin
        Tmp := TA; TA := TB; TB := Tmp;
      end;
      T0 := Max(T0, TA);
      T1 := Min(T1, TB);
      Result := T0 < T1;
    end;

  begin
    if not SolidAt(X, Y) then
      Exit(False);
    T0 := 0;
    T1 := 1;
    Result := Slab(AX, DX, X + Inset(X - 1, Y), X + 1 - Inset(X + 1, Y)) and
      Slab(AY, DY, Y + Inset(X, Y - 1), Y + 1 - Inset(X, Y + 1));
  end;

begin
  CX := Floor(AX); CY := Floor(AY);
  EX := Floor(BX); EY := Floor(BY);
  DX := BX - AX; DY := BY - AY;
  if DX > 0 then
  begin
    SX := 1; TDeltaX := 1 / DX; TMaxX := (CX + 1 - AX) / DX;
  end else
  if DX < 0 then
  begin
    SX := -1; TDeltaX := -1 / DX; TMaxX := (AX - CX) / -DX;
  end else
  begin
    SX := 0; TDeltaX := MaxDouble; TMaxX := MaxDouble;
  end;
  if DY > 0 then
  begin
    SY := 1; TDeltaY := 1 / DY; TMaxY := (CY + 1 - AY) / DY;
  end else
  if DY < 0 then
  begin
    SY := -1; TDeltaY := -1 / DY; TMaxY := (AY - CY) / -DY;
  end else
  begin
    SY := 0; TDeltaY := MaxDouble; TMaxY := MaxDouble;
  end;
  Steps := Abs(EX - CX) + Abs(EY - CY) + 2;
  while Steps > 0 do
  begin
    if Blocks(CX, CY) then
      Exit(False);
    if ((CX = EX) and (CY = EY)) or (Min(TMaxX, TMaxY) > 1) then
      Break;
    if TMaxX < TMaxY then
    begin
      Inc(CX, SX); TMaxX := TMaxX + TDeltaX;
    end else
    begin
      Inc(CY, SY); TMaxY := TMaxY + TDeltaY;
    end;
    Dec(Steps);
  end;
  Result := True;
end;

function TBuilder.RegionsSee(const A, B: TRegion): Boolean;
type
  TPoint2 = record
    X, Y: Double;
  end;
var
  PA, PB: array of TPoint2;

  { Sample points (every cell corner) on the sides of R facing O }
  procedure Samples(const R, O: TRegion; var P: array of TPoint2; out Count: Integer);

    procedure Add(const X, Y: Double);
    begin
      if Count <= High(P) then
      begin
        P[Count].X := X;
        P[Count].Y := Y;
        Inc(Count);
      end;
    end;

    procedure Side(const Vertical: Boolean; const Fixed: Double; const Lo, Hi: Integer);
    var
      I: Integer;
      V: Double;
    begin
      for I := 0 to Hi - Lo do
      begin
        V := EnsureRange(Lo + I, Lo + SightInset, Hi - SightInset);
        if Vertical then
          Add(Fixed, V)
        else
          Add(V, Fixed);
      end;
    end;

  begin
    Count := 0;
    if O.X1 > R.X1 then
      Side(True, R.X1 - SightInset, R.Y0, R.Y1);
    if O.X0 < R.X0 then
      Side(True, R.X0 + SightInset, R.Y0, R.Y1);
    if O.Y1 > R.Y1 then
      Side(False, R.Y1 - SightInset, R.X0, R.X1);
    if O.Y0 < R.Y0 then
      Side(False, R.Y0 + SightInset, R.X0, R.X1);
  end;

var
  CA, CB, I, J: Integer;
begin
  { Touching (sharing an edge or a corner): always visible }
  if (A.X0 <= B.X1) and (B.X0 <= A.X1) and (A.Y0 <= B.Y1) and (B.Y0 <= A.Y1) then
    Exit(True);
  SetLength(PA, 4 * (A.X1 - A.X0 + A.Y1 - A.Y0) + 8);
  SetLength(PB, 4 * (B.X1 - B.X0 + B.Y1 - B.Y0) + 8);
  Samples(A, B, PA, CA);
  Samples(B, A, PB, CB);
  for I := 0 to CA - 1 do
    for J := 0 to CB - 1 do
      if SightClear(PA[I].X, PA[I].Y, PB[J].X, PB[J].Y) then
        Exit(True);
  Result := False;
end;

function CompressVisRow(const Row: TBytes): TBytes;
var
  I, N, Zeros: Integer;
begin
  SetLength(Result, 2 * Length(Row) + 2);
  N := 0;
  I := 0;
  while I < Length(Row) do
  begin
    if Row[I] <> 0 then
    begin
      Result[N] := Row[I];
      Inc(N);
      Inc(I);
    end else
    begin
      Zeros := 0;
      while (I < Length(Row)) and (Row[I] = 0) and (Zeros < 255) do
      begin
        Inc(Zeros);
        Inc(I);
      end;
      Result[N] := 0;
      Result[N + 1] := Zeros;
      Inc(N, 2);
    end;
  end;
  SetLength(Result, N);
end;

procedure TBuilder.BuildVis(out Pvs, Phs: array of TBytes);
var
  RowBytes, I, J, K, C: Integer;
  RegionClusters: array of array[0..1] of Integer;
  See: array of TBytes;
  Row: TBytes;
  Start: QWord;
  Seen: Int64;

  procedure SetBit(var R: TBytes; const Cluster: Integer);
  begin
    if Cluster >= 0 then
      R[Cluster shr 3] := R[Cluster shr 3] or (1 shl (Cluster and 7));
  end;

  procedure Link(const RA, RB: Integer);
  var
    A, B: Integer;
  begin
    for A in RegionClusters[RA] do
      for B in RegionClusters[RB] do
        if (A >= 0) and (B >= 0) then
        begin
          SetBit(See[A], B);
          SetBit(See[B], A);
        end;
  end;

begin
  Start := GetTickCount64;
  SetLength(SolidCells, Level.Width * Level.Height);
  for I := 0 to High(SolidCells) do
    SolidCells[I] := Level.Cell(I mod Level.Width, I div Level.Width)^.Solid;
  RowBytes := (Clusters + 7) div 8;
  SetLength(See, Clusters);
  for I := 0 to Clusters - 1 do
  begin
    SetLength(See[I], RowBytes);
    FillChar(See[I][0], RowBytes, 0);
  end;
  SetLength(RegionClusters, Regions.Count);
  for I := 0 to Regions.Count - 1 do
  begin
    RegionClusters[I][0] := Leafs[Regions[I].Leaf].Cluster;
    RegionClusters[I][1] := -1;
    if Regions[I].WaterLeaf >= 0 then
      RegionClusters[I][1] := Leafs[Regions[I].WaterLeaf].Cluster;
  end;
  for I := 0 to Regions.Count - 1 do
    for J := I to Regions.Count - 1 do
      if (I = J) or RegionsSee(Regions[I], Regions[J]) then
        Link(I, J);
  Seen := 0;
  for C := 0 to Clusters - 1 do
  begin
    for K := 0 to Clusters - 1 do
      if (See[C][K shr 3] and (1 shl (K and 7))) <> 0 then
        Inc(Seen);
    Pvs[C] := CompressVisRow(See[C]);
    { PHS: everything the visible clusters see }
    Row := Copy(See[C]);
    for K := 0 to Clusters - 1 do
      if (See[C][K shr 3] and (1 shl (K and 7))) <> 0 then
        for J := 0 to RowBytes - 1 do
          Row[J] := Row[J] or See[K][J];
    Phs[C] := CompressVisRow(Row);
  end;
  VisPercent := 0;
  if Clusters > 0 then
    VisPercent := Round(100 * Seen / (Int64(Clusters) * Clusters));
  VisMsec := GetTickCount64 - Start;
end;

function TBuilder.Write(out Stats: TBspBuildStats): TMemoryStream;
var
  Hdr: TBSPHeader;
  Ents: String;
  Vis: TMemoryStream;
  I, Ofs: Integer;
  PvsRows, PhsRows: array of TBytes;
  Areas: array[0..1] of TBSPArea;
  Portal: TBSPAreaPortal;
  Zero: Byte;

  procedure Lump(const Index: Integer; const Data: Pointer; const Size: Integer);
  begin
    while Result.Position mod 4 <> 0 do
      Result.WriteByte(0);
    Hdr.Lumps[Index].Offset := Result.Position;
    Hdr.Lumps[Index].Length := Size;
    if Size > 0 then
      Result.WriteBuffer(Data^, Size);
  end;

  procedure BytesLump(const Index: Integer; const Bytes: TBytes);
  begin
    Lump(Index, Pointer(Bytes), Length(Bytes));
  end;

begin
  Result := TMemoryStream.Create;
  Hdr := Default(TBSPHeader);
  Hdr.Ident := BSP_IDENT_IBSP;
  Hdr.Version := 38;
  Result.WriteBuffer(Hdr, SizeOf(Hdr));

  Ents := Level.EntityText(EntityModels) + DoorEntities + #0;
  Lump(LUMP_ENTITIES, @Ents[1], Length(Ents));
  BytesLump(LUMP_PLANES, specialize ListBytes<TBSPPlane>(Planes));
  BytesLump(LUMP_VERTICES, specialize ListBytes<TVector3>(Vertices));

  { Visibility: PVS and PHS rows after the offsets }
  SetLength(PvsRows, Clusters);
  SetLength(PhsRows, Clusters);
  BuildVis(PvsRows, PhsRows);
  Vis := TMemoryStream.Create;
  try
    Vis.WriteDWord(Clusters);
    Ofs := 4 + 8 * Clusters;
    for I := 0 to Clusters - 1 do
    begin
      Vis.WriteDWord(Ofs);
      Inc(Ofs, Length(PvsRows[I]));
      Vis.WriteDWord(Ofs);
      Inc(Ofs, Length(PhsRows[I]));
    end;
    for I := 0 to Clusters - 1 do
    begin
      if Length(PvsRows[I]) > 0 then
        Vis.WriteBuffer(PvsRows[I][0], Length(PvsRows[I]));
      if Length(PhsRows[I]) > 0 then
        Vis.WriteBuffer(PhsRows[I][0], Length(PhsRows[I]));
    end;
    Lump(LUMP_VISIBILITY, Vis.Memory, Vis.Size);
  finally
    Vis.Free;
  end;

  BytesLump(LUMP_NODES, specialize ListBytes<TBSPNode>(Nodes));
  BytesLump(LUMP_TEXINFO, specialize ListBytes<TBSPTexInfo>(TexInfos));
  BytesLump(LUMP_FACES, specialize ListBytes<TBSPFace>(Faces));
  if Lighting.Size > 0 then
    Lump(LUMP_LIGHTING, Lighting.Memory, Lighting.Size)
  else
  begin
    Zero := 0;
    Lump(LUMP_LIGHTING, @Zero, 1);
  end;
  BytesLump(LUMP_LEAFS, specialize ListBytes<TBSPLeaf>(Leafs));
  BytesLump(LUMP_LEAFFACES, specialize ListBytes<Word>(LeafFaces));
  BytesLump(LUMP_LEAFBRUSHES, specialize ListBytes<Word>(LeafBrushes));
  BytesLump(LUMP_EDGES, specialize ListBytes<TBSPEdge>(Edges));
  BytesLump(LUMP_SURFEDGES, specialize ListBytes<LongInt>(SurfEdges));

  BytesLump(LUMP_MODELS, specialize ListBytes<TBSPModel>(Models));
  BytesLump(LUMP_BRUSHES, specialize ListBytes<TBSPBrush>(Brushes));
  BytesLump(LUMP_BRUSHSIDES, specialize ListBytes<TBSPBrushSide>(BrushSides));
  Lump(LUMP_POP, nil, 0);
  Areas[0] := Default(TBSPArea);
  Areas[1] := Default(TBSPArea);
  Lump(LUMP_AREAS, @Areas[0], SizeOf(Areas));
  Portal := Default(TBSPAreaPortal);
  Lump(LUMP_AREAPORTALS, @Portal, SizeOf(Portal));

  Result.Position := 0;
  Result.WriteBuffer(Hdr, SizeOf(Hdr));
  Result.Position := 0;

  Stats.Nodes := Nodes.Count;
  Stats.Leafs := Leafs.Count;
  Stats.Faces := Faces.Count;
  Stats.Brushes := Brushes.Count;
  Stats.Clusters := Clusters;
  Stats.VisPercent := VisPercent;
  Stats.VisMsec := VisMsec;
  Stats.LightBytes := Lighting.Size;
end;

{ The textures levels use that the PAKs may lack: a lava WAL (64 x 64,
  tileable waves of dark red to yellow in the Quake 2 palette) }
procedure EnsureLevelTextures;
const
  Size = 64;
  Ramp: array[0..3] of TVector3 = ((X: 70; Y: 8; Z: 0), (X: 200; Y: 50; Z: 0),
    (X: 250; Y: 140; Z: 15), (X: 255; Y: 225; Z: 90));
var
  Stream: TMemoryStream;
  Name: array[0..31] of AnsiChar;
  Pixels: array of Byte;
  X, Y, I, Best: Integer;
  V, T, D, BestD: Single;
  Col: TVector3;
  P: TVector4Byte;
  Path: String;
begin
  Path := 'textures/' + LevelLavaTexture + '.wal';
  if Pak.FileExists(Path) then
    Exit;
  if not Palette.HasPalette then
    Palette.LoadFromPak;
  SetLength(Pixels, Size * Size);
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
    begin
      V := 0.5 + 0.2 * Sin(2 * Pi * (2 * X / Size + 0.35 * Sin(2 * Pi * Y / Size))) +
        0.2 * Sin(2 * Pi * (3 * Y / Size + 0.3 * Sin(4 * Pi * X / Size))) +
        0.12 * Sin(2 * Pi * 2 * (X + Y) / Size);
      V := EnsureRange(V, 0, 0.999) * 3;
      I := Trunc(V);
      T := V - I;
      Col := Ramp[I] * (1 - T) + Ramp[I + 1] * T;
      { The nearest palette colour (not 255, transparent) }
      Best := 0;
      BestD := MaxSingle;
      if Palette.HasPalette then
        for I := 0 to 254 do
        begin
          P := Palette.Color(I);
          D := Sqr(P.X - Col.X) + Sqr(P.Y - Col.Y) + Sqr(P.Z - Col.Z);
          if D < BestD then
          begin
            BestD := D;
            Best := I;
          end;
        end;
      Pixels[Y * Size + X] := Best;
    end;
  Stream := TMemoryStream.Create;
  FillChar(Name, SizeOf(Name), 0);
  Move(LevelLavaTexture[1], Name[0], Length(LevelLavaTexture));
  Stream.WriteBuffer(Name, 32);
  Stream.WriteDWord(Size);
  Stream.WriteDWord(Size);
  { One mip level after the 100-byte header (the others point to it) }
  for I := 0 to 3 do
    Stream.WriteDWord(100);
  FillChar(Name, SizeOf(Name), 0);
  Stream.WriteBuffer(Name, 32);
  Stream.WriteDWord(SURF_WARP);
  Stream.WriteDWord(CONTENTS_LAVA);
  Stream.WriteDWord(0);
  Stream.WriteBuffer(Pixels[0], Length(Pixels));
  Pak.AddMemoryFile(Path, Stream);
end;

function BuildLevelBsp(const Level: TQuakeLevel; out Stats: TBspBuildStats): TMemoryStream;
var
  B: TBuilder;
  Root: Integer;
  WorldModel: TBSPModel;
begin
  Stats := Default(TBspBuildStats);
  EnsureLevelTextures;
  EnsureLevelThemes;
  Level.Normalize;
  if Level.OpenCellCount = 0 then
    raise Exception.Create('The level has no open cells');
  B := TBuilder.Create(Level);
  try
    { Edge 0 is never used by faces (surfedges sign their direction) }
    B.Edges.Add(Default(TBSPEdge));
    { Leaf 0 is solid in every Quake 2 map (CM_LoadLeafs checks it) }
    B.AddDummySolidLeaf;
    B.CollectLights;
    Root := B.BuildRegion(0, 0, Level.Width, Level.Height);
    if Root <> 0 then
      raise Exception.Create('The level BSP has no root node');
    B.BuildFaces;
    { Model 0: the world; then a model per door }
    WorldModel := Default(TBSPModel);
    WorldModel.Mins := Vector3(0, 0, B.ZMin);
    WorldModel.Maxs := Vector3(Level.Width * LevelCellSize, Level.Height * LevelCellSize, B.ZMax);
    WorldModel.HeadNode := 0;
    WorldModel.FirstFace := 0;
    WorldModel.NumFaces := B.Faces.Count;
    B.Models.Add(WorldModel);
    B.BuildMoverGroups(False);
    B.BuildMoverGroups(True);
    B.BuildButtons;
    B.BuildWindows;
    B.BuildTriggerBoxes;
    Result := B.Write(Stats);
    Stats.Models := B.Models.Count;
  finally
    B.Free;
  end;
  WritelnLog('QuakeBspBuilder', 'Built "%s": %d nodes, %d leafs, %d clusters (%d %% visible, %d ms), %d faces, %d brushes, %d models, %d lightmap bytes',
    [Level.Name, Stats.Nodes, Stats.Leafs, Stats.Clusters, Stats.VisPercent, Stats.VisMsec,
     Stats.Faces, Stats.Brushes, Stats.Models, Stats.LightBytes]);
end;

function RegisterLevelMap(const Level: TQuakeLevel): String;
var
  Stream: TMemoryStream;
  Stats: TBspBuildStats;
begin
  Stream := BuildLevelBsp(Level, Stats);
  Result := LowerCase(Level.Name);
  Pak.AddMemoryFile('maps/' + Result + '.bsp', Stream);
end;

end.
