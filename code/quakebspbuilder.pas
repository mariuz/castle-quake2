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
  - Visibility: one cluster per empty leaf, everything visible (PVS / PHS
    all ones); one area.

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
  end;

{ The map file of a level }
function BuildLevelBsp(const Level: TQuakeLevel; out Stats: TBspBuildStats): TMemoryStream;

{ Build the level and add it to Pak as maps/<Level.Name>.bsp; returns the
  map name to load }
function RegisterLevelMap(const Level: TQuakeLevel): String;

implementation

uses
  Math, Generics.Collections, CastleLog, QuakeBsp, QuakePak;

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
    Models: TModelList;
    { func_door entities of the door models, for the entity lump }
    DoorEntities: String;
    { Door building: cells of the current door (component id per cell) }
    DoorComp: array of Integer;
    CurrentDoor: Integer;
    constructor Create(const ALevel: TQuakeLevel);
    destructor Destroy; override;
    function CellKey(const X, Y: Integer): String;
    function Uniform(const X0, Y0, X1, Y1: Integer): Boolean;
    function AddPlane(const Axis: Integer; const Positive: Boolean; const Dist: Single): Integer;
    function AxialPlane(const Axis: Integer; const Dist: Single): Integer;
    function NewNode: Integer;
    procedure AddDummySolidLeaf;
    function NewLeaf(const Solid: Boolean; const Mins, Maxs: TVector3): Integer;
    { A leaf of water (CONTENTS_WATER, its own cluster, a water brush) }
    function NewWaterLeaf(const Mins, Maxs: TVector3): Integer;
    { An empty leaf of a brush model (no cluster) }
    function NewModelEmptyLeaf(const Mins, Maxs: TVector3): Integer;
    function AddBoxBrush(const Mins, Maxs: TVector3; const Contents: Integer): Integer;
    function DoorKey(const X, Y: Integer): String;
    function BuildDoorRegion(const X0, Y0, X1, Y1: Integer): Integer;
    procedure BuildDoors;
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
    function LightAt(const P, N: TVector3; const SkyCell: Boolean): TVector3;
    procedure LightFace(const FaceIdx: Integer; const FA: TFaceAxis; const Dist: Single;
      const SkyCell: Boolean);
    procedure CollectLights;
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
    Result := Format('%d,%d,%d,%d,%d,%d', [C^.Floor, C^.Ceil, Ord(C^.Sky), C^.Theme, Ord(C^.Door),
      IfThen(CellHasWater(C), C^.Water, 0)]);
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

function TBuilder.NewWaterLeaf(const Mins, Maxs: TVector3): Integer;
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
  L.Contents := CONTENTS_WATER;
  L.Cluster := Clusters;
  Inc(Clusters);
  L.Area := 1;
  L.FirstLeafBrush := LeafBrushes.Count;
  L.NumLeafBrushes := 1;
  LeafBrushes.Add(AddBoxBrush(Mins, Maxs, CONTENTS_WATER));
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
      R.WaterLeaf := NewWaterLeaf(Vector3(Mins.X, Mins.Y, C^.Floor), Vector3(Maxs.X, Maxs.Y, C^.Water));
    end else
      R.Leaf := NewLeaf(False, Vector3(Mins.X, Mins.Y, C^.Floor), Vector3(Maxs.X, Maxs.Y, C^.Ceil));
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
    N.PlaneNum := AxialPlane(2, C^.Floor);
    if R.WaterLeaf >= 0 then
      N.Children[0] := -(R.WaterLeaf + 1)
    else
      N.Children[0] := -(R.Leaf + 1);
    N.Children[1] := -(NewLeaf(True, Mins, Vector3(Maxs.X, Maxs.Y, C^.Floor)) + 1);
    SetNodeBounds(N, Mins, Vector3(Maxs.X, Maxs.Y, C^.Ceil));
    Nodes[NodeFloor] := N;
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

begin
  C := Level.Cell(X, Y);
  Theme := LevelThemes[C^.Theme];
  for D := 0 to 3 do
  begin
    N := Level.Cell(X + DX[D], Y + DY[D]);
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
    if N^.Solid then
      Wall(C^.Floor, C^.Ceil, Theme.Wall)
    else
    begin
      { Lower side: the neighbour's floor is higher (a step up) }
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
  CeilTex: String;
  HasLight: Boolean;
  LX, LY: Integer;
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
    for Y := R.Y0 to R.Y1 - 1 do
      for X := R.X0 to R.X1 - 1 do
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
        FaceIdx := AddFace(FA, C^.Ceil, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
          Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), CeilTex,
          IfThen(C^.Sky, SURF_SKY, 0));
        if not C^.Sky then
          LightFace(FaceIdx, FA, C^.Ceil, False);
      end;
    N.NumFaces := Faces.Count - N.FirstFace;
    Nodes[R.NodeCeil] := N;

    { Walls and steps }
    for Y := R.Y0 to R.Y1 - 1 do
      for X := R.X0 to R.X1 - 1 do
        AddWalls(X, Y);

    { The water surface, seen from above and from below (warped, no
      lightmap) }
    if R.NodeWater >= 0 then
      for Y := R.Y0 to R.Y1 - 1 do
        for X := R.X0 to R.X1 - 1 do
        begin
          FA.Axis := 2;
          FA.Positive := True;
          AddFace(FA, C^.Water, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), LevelWaterTexture,
            SURF_WARP or SURF_TRANS33);
          FA.Positive := False;
          AddFace(FA, C^.Water, Vector3(X * LevelCellSize, Y * LevelCellSize, 0),
            Vector3((X + 1) * LevelCellSize, (Y + 1) * LevelCellSize, 0), LevelWaterTexture,
            SURF_WARP or SURF_TRANS33);
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
var
  C: PLevelCell;
begin
  if (not Level.InGrid(X, Y)) or (DoorComp[Y * Level.Width + X] <> CurrentDoor) then
    Exit('-');
  C := Level.Cell(X, Y);
  Result := Format('%d,%d', [C^.Floor, C^.Ceil]);
end;

function TBuilder.BuildDoorRegion(const X0, Y0, X1, Y1: Integer): Integer;
var
  K: String;
  X, Y, Mid, NodeCeil, NodeFloor: Integer;
  Same: Boolean;
  C: PLevelCell;
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
    { The door: solid from its floor to its ceiling, empty around }
    C := Level.Cell(X0, Y0);
    NodeCeil := NewNode;
    NodeFloor := NewNode;
    N := Default(TBSPNode);
    N.PlaneNum := AxialPlane(2, C^.Ceil);
    N.Children[0] := -(NewModelEmptyLeaf(Vector3(Mins.X, Mins.Y, C^.Ceil), Maxs) + 1);
    N.Children[1] := NodeFloor;
    SetNodeBounds(N, Mins, Maxs);
    Nodes[NodeCeil] := N;
    N := Default(TBSPNode);
    N.PlaneNum := AxialPlane(2, C^.Floor);
    N.Children[0] := -(NewLeaf(True, Vector3(Mins.X, Mins.Y, C^.Floor), Vector3(Maxs.X, Maxs.Y, C^.Ceil)) + 1);
    N.Children[1] := -(NewModelEmptyLeaf(Mins, Vector3(Maxs.X, Maxs.Y, C^.Floor)) + 1);
    SetNodeBounds(N, Mins, Vector3(Maxs.X, Maxs.Y, C^.Ceil));
    Nodes[NodeFloor] := N;
    Exit(NodeCeil);
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

procedure TBuilder.BuildDoors;
const
  DX: array[0..3] of Integer = (1, -1, 0, 0);
  DY: array[0..3] of Integer = (0, 0, 1, -1);
var
  X, Y, I, D, CX, CY, NX, NY, X0, Y0, X1, Y1, Z, ZTop, FaceIdx, Head: Integer;
  Queue: specialize TList<Integer>;
  C, N, Start: PLevelCell;
  M: TBSPModel;
  FA: TFaceAxis;
  Dist: Single;
begin
  SetLength(DoorComp, Level.Width * Level.Height);
  for I := 0 to High(DoorComp) do
    DoorComp[I] := -1;
  CurrentDoor := 0;
  Queue := specialize TList<Integer>.Create;
  try
    for Y := 0 to Level.Height - 1 do
      for X := 0 to Level.Width - 1 do
      begin
        Start := Level.Cell(X, Y);
        if Start^.Solid or not Start^.Door or (DoorComp[Y * Level.Width + X] >= 0) then
          Continue;
        { One door: the touching door cells with the same heights }
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
            N := Level.Cell(NX, NY);
            if (not N^.Solid) and N^.Door and (N^.Floor = Start^.Floor) and (N^.Ceil = Start^.Ceil) then
            begin
              DoorComp[NY * Level.Width + NX] := CurrentDoor;
              Queue.Add(NY * Level.Width + NX);
            end;
          end;
        end;

        M := Default(TBSPModel);
        M.HeadNode := BuildDoorRegion(X0, Y0, X1, Y1);
        M.FirstFace := Faces.Count;
        { Its sides towards open cells, and its bottom (seen when it is up) }
        for I := 0 to Queue.Count - 1 do
        begin
          CX := Queue[I] mod Level.Width;
          CY := Queue[I] div Level.Width;
          C := Level.Cell(CX, CY);
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
            Z := C^.Floor;
            while Z < C^.Ceil do
            begin
              ZTop := Min(C^.Ceil, Z + 256);
              FaceIdx := AddFace(FA, Dist, Vector3(CX * LevelCellSize, CY * LevelCellSize, Z),
                Vector3((CX + 1) * LevelCellSize, (CY + 1) * LevelCellSize, ZTop), LevelDoorTexture, 0);
              LightFace(FaceIdx, FA, Dist, False);
              Z := ZTop;
            end;
          end;
          FA.Axis := 2;
          FA.Positive := False;
          FaceIdx := AddFace(FA, C^.Floor, Vector3(CX * LevelCellSize, CY * LevelCellSize, 0),
            Vector3((CX + 1) * LevelCellSize, (CY + 1) * LevelCellSize, 0), LevelDoorTexture, 0);
          LightFace(FaceIdx, FA, C^.Floor, False);
        end;
        M.NumFaces := Faces.Count - M.FirstFace;
        M.Mins := Vector3(X0 * LevelCellSize, Y0 * LevelCellSize, Start^.Floor);
        M.Maxs := Vector3(X1 * LevelCellSize, Y1 * LevelCellSize, Start^.Ceil);
        DoorEntities := DoorEntities + Format(
          '{' + LineEnding + '"classname" "func_door"' + LineEnding + '"model" "*%d"' + LineEnding +
          '"angle" "-1"' + LineEnding + '"speed" "100"' + LineEnding + '"wait" "3"' + LineEnding +
          '"lip" "8"' + LineEnding + '}' + LineEnding, [Models.Count]);
        Models.Add(M);
        Inc(CurrentDoor);
      end;
  finally
    Queue.Free;
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

function TBuilder.LightAt(const P, N: TVector3; const SkyCell: Boolean): TVector3;
var
  I: Integer;
  ToLight: TVector3;
  Dist, Dot, V: Single;
begin
  { A little ambient, more under the open sky }
  Result := Vector3(14, 14, 14);
  if SkyCell then
    Result := Result + Vector3(70, 70, 76);
  for I := 0 to High(Lights) do
  begin
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
  F: TBSPFace;
  T: TBSPTexInfo;
  I, W, H, SI, TI: Integer;
  MinS, MaxS, MinT, MaxT, S, TT: Single;
  V, P, N, Col, FMin, FMax: TVector3;
  B: array[0..2] of Byte;
  BMinS, BMinT: Integer;
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
  N := TVector3.Zero;
  N.Data[FA.Axis] := IfThen(FA.Positive, 1, -1);
  F.LightmapOffset := Lighting.Position;
  F.Styles[0] := 0;
  for TI := 0 to H - 1 do
    for SI := 0 to W - 1 do
    begin
      S := (BMinS + SI) * 16;
      TT := (BMinT + TI) * 16;
      { Back from texture space (axial vectors with no offset) }
      P := TVector3.Zero;
      P.Data[FA.Axis] := Dist;
      case FA.Axis of
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
      { Samples on the face, a unit in front of it }
      P := Vector3(EnsureRange(P.X, FMin.X + 1, FMax.X - 1), EnsureRange(P.Y, FMin.Y + 1, FMax.Y - 1),
        EnsureRange(P.Z, FMin.Z + 1, FMax.Z - 1));
      P.Data[FA.Axis] := Dist;
      P := P + N;
      Col := LightAt(P, N, SkyCell);
      B[0] := EnsureRange(Round(Col.X), 0, 255);
      B[1] := EnsureRange(Round(Col.Y), 0, 255);
      B[2] := EnsureRange(Round(Col.Z), 0, 255);
      Lighting.WriteBuffer(B, 3);
    end;
  Faces[FaceIdx] := F;
end;

procedure TBuilder.CollectLights;
var
  E: TLevelEntity;
  L: TLight;
  Parts: TStringArray;
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Lights := nil;
  for E in Level.Entities do
  begin
    if E.EntClass <> 'light' then
      Continue;
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
end;

function TBuilder.Write(out Stats: TBspBuildStats): TMemoryStream;
var
  Hdr: TBSPHeader;
  Ents: String;
  Vis: TMemoryStream;
  I, RowBytes, Ofs: Integer;
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

  Ents := Level.EntityText + DoorEntities + #0;
  Lump(LUMP_ENTITIES, @Ents[1], Length(Ents));
  BytesLump(LUMP_PLANES, specialize ListBytes<TBSPPlane>(Planes));
  BytesLump(LUMP_VERTICES, specialize ListBytes<TVector3>(Vertices));

  { Visibility: every cluster sees every cluster (one shared row) }
  Vis := TMemoryStream.Create;
  try
    RowBytes := (Clusters + 7) div 8;
    Vis.WriteDWord(Clusters);
    Ofs := 4 + 8 * Clusters;
    for I := 0 to Clusters - 1 do
    begin
      Vis.WriteDWord(Ofs);
      Vis.WriteDWord(Ofs);
    end;
    for I := 0 to RowBytes - 1 do
      Vis.WriteByte($FF);
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
  Stats.LightBytes := Lighting.Size;
end;

function BuildLevelBsp(const Level: TQuakeLevel; out Stats: TBspBuildStats): TMemoryStream;
var
  B: TBuilder;
  Root: Integer;
  WorldModel: TBSPModel;
begin
  Stats := Default(TBspBuildStats);
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
    B.BuildDoors;
    Result := B.Write(Stats);
    Stats.Models := B.Models.Count;
  finally
    B.Free;
  end;
  WritelnLog('QuakeBspBuilder', 'Built "%s": %d nodes, %d leafs, %d clusters, %d faces, %d brushes, %d models, %d lightmap bytes',
    [Level.Name, Stats.Nodes, Stats.Leafs, Stats.Clusters, Stats.Faces, Stats.Brushes, Stats.Models, Stats.LightBytes]);
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
