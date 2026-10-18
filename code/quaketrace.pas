{ Box traces against the BSP brushes, like Quake 2's collision model
  (cmodel.c: CM_BoxTrace, CM_TransformedBoxTrace). The player's movement
  sweeps its box with these traces and slides along the planes it hits
  (PM_StepSlideMove), so collisions are exact against the map's convex
  brushes instead of approximate overlap tests against render meshes.

  Everything here is in Quake coordinates (Z up). }
unit QuakeTrace;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  CastleVectors,
  QuakeBsp;

const
  { Traces stop this far in front of planes (DIST_EPSILON) }
  TraceEpsilon = 0.03125;

type
  TQuakeTrace = record
    { Started in a solid / stayed in it the whole way }
    StartSolid, AllSolid: Boolean;
    { 0..1: how far it got (1 = nothing hit) }
    Fraction: Single;
    EndPos: TVector3;
    { The plane hit (valid when Fraction < 1) }
    Normal: TVector3;
    PlaneDist: Single;
    { CONTENTS_* of the brush hit }
    Contents: Integer;
    { What was hit: nil for the world, else the entity (mover, monster) }
    Ent: TObject;
    { Fraction < 1 or StartSolid }
    function Hit: Boolean;
  end;

  { Traces against one loaded map }
  TQuakeCollision = class
  strict private
    FBsp: TQuakeBsp;
    FBrushCheck: array of Integer;
    FCheckCount: Integer;
    { Current trace }
    FStart, FEnd, FMins, FMaxs, FExtents: TVector3;
    FIsPoint: Boolean;
    FMask: Integer;
    FTrace: TQuakeTrace;
    procedure ClipBoxToBrush(const BrushIndex: Integer);
    procedure TestBoxInBrush(const BrushIndex: Integer);
    procedure TraceToLeaf(const Leaf: Integer);
    procedure TestInLeaf(const Leaf: Integer);
    procedure RecursiveHullCheck(const Num: Integer; const P1F, P2F: Single; const P1, P2: TVector3);
    procedure BoxLeafsRecursive(const Node: Integer; const Mins, Maxs: TVector3;
      var Leafs: array of Integer; var Count: Integer);
  public
    constructor Create(const ABsp: TQuakeBsp);
    { Sweep the box Mins..Maxs (relative to the moving point) from Start to
      Stop through the brush model of HeadNode (Bsp.Models[i].HeadNode; 0
      for the world), against brushes with contents in Mask. Start = Stop
      tests the position. }
    function BoxTrace(const Start, Stop, Mins, Maxs: TVector3; const HeadNode, Mask: Integer): TQuakeTrace;
    { Contents of the brushes of a model at a point }
    function PointContents(const P: TVector3; const HeadNode: Integer): Integer;
    property Bsp: TQuakeBsp read FBsp;
  end;

{ Sweep a box against another axis-aligned box (a monster: BoxMins..BoxMaxs
  in world space), like Quake 2's CM_HeadnodeForBox trace }
function BoxTraceAgainstBox(const Start, Stop, Mins, Maxs, BoxMins, BoxMaxs: TVector3;
  const BoxContents: Integer): TQuakeTrace;

implementation

uses
  Math;

function TQuakeTrace.Hit: Boolean;
begin
  Result := (Fraction < 1) or StartSolid;
end;

function EmptyTrace(const Stop: TVector3): TQuakeTrace;
begin
  Result := Default(TQuakeTrace);
  Result.Fraction := 1;
  Result.EndPos := Stop;
end;

{ TQuakeCollision }

constructor TQuakeCollision.Create(const ABsp: TQuakeBsp);
begin
  inherited Create;
  FBsp := ABsp;
  SetLength(FBrushCheck, Length(ABsp.Brushes));
end;

procedure TQuakeCollision.ClipBoxToBrush(const BrushIndex: Integer);
var
  Brush: TBSPBrush;
  Plane: TBSPPlane;
  I, J: Integer;
  EnterFrac, LeaveFrac, Dist, D1, D2, F: Single;
  ClipNormal: TVector3;
  ClipDist: Single;
  GetOut, StartOut, Clipped: Boolean;
  Ofs: TVector3;
begin
  Brush := FBsp.Brushes[BrushIndex];
  if Brush.NumSides <= 0 then
    Exit;
  EnterFrac := -1;
  LeaveFrac := 1;
  GetOut := False;
  StartOut := False;
  Clipped := False;
  ClipNormal := TVector3.Zero;
  ClipDist := 0;
  for I := 0 to Brush.NumSides - 1 do
  begin
    Plane := FBsp.Planes[FBsp.BrushSides[Brush.FirstSide + I].PlaneNum];
    { Push the plane out by the box corner nearest to it }
    if not FIsPoint then
    begin
      for J := 0 to 2 do
        if Plane.Normal.Data[J] < 0 then
          Ofs.Data[J] := FMaxs.Data[J]
        else
          Ofs.Data[J] := FMins.Data[J];
      Dist := Plane.Dist - TVector3.DotProduct(Ofs, Plane.Normal);
    end else
      Dist := Plane.Dist;
    D1 := TVector3.DotProduct(FStart, Plane.Normal) - Dist;
    D2 := TVector3.DotProduct(FEnd, Plane.Normal) - Dist;
    if D2 > 0 then
      GetOut := True;
    if D1 > 0 then
      StartOut := True;
    { Completely in front of this face: no intersection }
    if (D1 > 0) and (D2 >= D1) then
      Exit;
    if (D1 <= 0) and (D2 <= 0) then
      Continue;
    { Crosses the face }
    if D1 > D2 then
    begin
      { Entering }
      F := (D1 - TraceEpsilon) / (D1 - D2);
      if F > EnterFrac then
      begin
        EnterFrac := F;
        ClipNormal := Plane.Normal;
        ClipDist := Plane.Dist;
        Clipped := True;
      end;
    end else
    begin
      { Leaving }
      F := (D1 + TraceEpsilon) / (D1 - D2);
      if F < LeaveFrac then
        LeaveFrac := F;
    end;
  end;

  if not StartOut then
  begin
    { The original point was inside the brush }
    FTrace.StartSolid := True;
    if not GetOut then
      FTrace.AllSolid := True;
    FTrace.Contents := Brush.Contents;
    Exit;
  end;
  if (EnterFrac < LeaveFrac) and Clipped and (EnterFrac > -1) and (EnterFrac < FTrace.Fraction) then
  begin
    if EnterFrac < 0 then
      EnterFrac := 0;
    FTrace.Fraction := EnterFrac;
    FTrace.Normal := ClipNormal;
    FTrace.PlaneDist := ClipDist;
    FTrace.Contents := Brush.Contents;
  end;
end;

procedure TQuakeCollision.TestBoxInBrush(const BrushIndex: Integer);
var
  Brush: TBSPBrush;
  Plane: TBSPPlane;
  I, J: Integer;
  Dist, D1: Single;
  Ofs: TVector3;
begin
  Brush := FBsp.Brushes[BrushIndex];
  if Brush.NumSides <= 0 then
    Exit;
  for I := 0 to Brush.NumSides - 1 do
  begin
    Plane := FBsp.Planes[FBsp.BrushSides[Brush.FirstSide + I].PlaneNum];
    for J := 0 to 2 do
      if Plane.Normal.Data[J] < 0 then
        Ofs.Data[J] := FMaxs.Data[J]
      else
        Ofs.Data[J] := FMins.Data[J];
    Dist := Plane.Dist - TVector3.DotProduct(Ofs, Plane.Normal);
    D1 := TVector3.DotProduct(FStart, Plane.Normal) - Dist;
    { In front of a side: not inside }
    if D1 > 0 then
      Exit;
  end;
  { Inside all sides }
  FTrace.StartSolid := True;
  FTrace.AllSolid := True;
  FTrace.Fraction := 0;
  FTrace.Contents := Brush.Contents;
end;

procedure TQuakeCollision.TraceToLeaf(const Leaf: Integer);
var
  L: TBSPLeaf;
  K, B: Integer;
begin
  L := FBsp.Leafs[Leaf];
  if (L.Contents and FMask) = 0 then
    Exit;
  for K := 0 to L.NumLeafBrushes - 1 do
  begin
    B := FBsp.LeafBrush(L.FirstLeafBrush + K);
    if FBrushCheck[B] = FCheckCount then
      Continue; { already checked this brush in another leaf }
    FBrushCheck[B] := FCheckCount;
    if (FBsp.Brushes[B].Contents and FMask) = 0 then
      Continue;
    ClipBoxToBrush(B);
    if FTrace.Fraction = 0 then
      Exit;
  end;
end;

procedure TQuakeCollision.TestInLeaf(const Leaf: Integer);
var
  L: TBSPLeaf;
  K, B: Integer;
begin
  L := FBsp.Leafs[Leaf];
  if (L.Contents and FMask) = 0 then
    Exit;
  for K := 0 to L.NumLeafBrushes - 1 do
  begin
    B := FBsp.LeafBrush(L.FirstLeafBrush + K);
    if FBrushCheck[B] = FCheckCount then
      Continue;
    FBrushCheck[B] := FCheckCount;
    if (FBsp.Brushes[B].Contents and FMask) = 0 then
      Continue;
    TestBoxInBrush(B);
    if FTrace.Fraction = 0 then
      Exit;
  end;
end;

procedure TQuakeCollision.RecursiveHullCheck(const Num: Integer; const P1F, P2F: Single;
  const P1, P2: TVector3);
var
  Node: TBSPNode;
  Plane: TBSPPlane;
  T1, T2, Offset, Frac, Frac2, IDist, MidF: Single;
  Side: Integer;
  Mid: TVector3;
begin
  if FTrace.Fraction <= P1F then
    Exit; { already hit something nearer }
  if Num < 0 then
  begin
    TraceToLeaf(-1 - Num);
    Exit;
  end;
  Node := FBsp.Nodes[Num];
  Plane := FBsp.Planes[Node.PlaneNum];
  if Plane.PlaneType < 3 then
  begin
    T1 := P1.Data[Plane.PlaneType] - Plane.Dist;
    T2 := P2.Data[Plane.PlaneType] - Plane.Dist;
    Offset := FExtents.Data[Plane.PlaneType];
  end else
  begin
    T1 := TVector3.DotProduct(Plane.Normal, P1) - Plane.Dist;
    T2 := TVector3.DotProduct(Plane.Normal, P2) - Plane.Dist;
    if FIsPoint then
      Offset := 0
    else
      Offset := Abs(FExtents.X * Plane.Normal.X) + Abs(FExtents.Y * Plane.Normal.Y) +
        Abs(FExtents.Z * Plane.Normal.Z);
  end;

  { See which sides we need to consider }
  if (T1 >= Offset) and (T2 >= Offset) then
  begin
    RecursiveHullCheck(Node.Children[0], P1F, P2F, P1, P2);
    Exit;
  end;
  if (T1 < -Offset) and (T2 < -Offset) then
  begin
    RecursiveHullCheck(Node.Children[1], P1F, P2F, P1, P2);
    Exit;
  end;

  { Put the crosspoint DIST_EPSILON pixels on the near side }
  if T1 < T2 then
  begin
    IDist := 1 / (T1 - T2);
    Side := 1;
    Frac2 := (T1 + Offset + TraceEpsilon) * IDist;
    Frac := (T1 - Offset + TraceEpsilon) * IDist;
  end else
  if T1 > T2 then
  begin
    IDist := 1 / (T1 - T2);
    Side := 0;
    Frac2 := (T1 - Offset - TraceEpsilon) * IDist;
    Frac := (T1 + Offset + TraceEpsilon) * IDist;
  end else
  begin
    Side := 0;
    Frac := 1;
    Frac2 := 0;
  end;

  { Move up to the node }
  Frac := EnsureRange(Frac, 0, 1);
  MidF := P1F + (P2F - P1F) * Frac;
  Mid := P1 + (P2 - P1) * Frac;
  RecursiveHullCheck(Node.Children[Side], P1F, MidF, P1, Mid);

  { Go past the node }
  Frac2 := EnsureRange(Frac2, 0, 1);
  MidF := P1F + (P2F - P1F) * Frac2;
  Mid := P1 + (P2 - P1) * Frac2;
  RecursiveHullCheck(Node.Children[Side xor 1], MidF, P2F, Mid, P2);
end;

procedure TQuakeCollision.BoxLeafsRecursive(const Node: Integer; const Mins, Maxs: TVector3;
  var Leafs: array of Integer; var Count: Integer);
var
  N: TBSPNode;
  Plane: TBSPPlane;
  DMin, DMax: Single;
  J: Integer;
  Near, Far: TVector3;
begin
  if Node < 0 then
  begin
    if Count < Length(Leafs) then
    begin
      Leafs[Count] := -1 - Node;
      Inc(Count);
    end;
    Exit;
  end;
  N := FBsp.Nodes[Node];
  Plane := FBsp.Planes[N.PlaneNum];
  { BoxOnPlaneSide }
  for J := 0 to 2 do
    if Plane.Normal.Data[J] < 0 then
    begin
      Near.Data[J] := Maxs.Data[J];
      Far.Data[J] := Mins.Data[J];
    end else
    begin
      Near.Data[J] := Mins.Data[J];
      Far.Data[J] := Maxs.Data[J];
    end;
  DMax := TVector3.DotProduct(Far, Plane.Normal) - Plane.Dist;
  DMin := TVector3.DotProduct(Near, Plane.Normal) - Plane.Dist;
  if DMax >= 0 then
    BoxLeafsRecursive(N.Children[0], Mins, Maxs, Leafs, Count);
  if DMin < 0 then
    BoxLeafsRecursive(N.Children[1], Mins, Maxs, Leafs, Count);
end;

function TQuakeCollision.BoxTrace(const Start, Stop, Mins, Maxs: TVector3;
  const HeadNode, Mask: Integer): TQuakeTrace;
var
  Leafs: array[0..1023] of Integer;
  Count, I: Integer;
begin
  Inc(FCheckCount);
  FTrace := EmptyTrace(Stop);
  Result := FTrace;
  if (Length(FBsp.Nodes) = 0) or (Length(FBrushCheck) <> Length(FBsp.Brushes)) then
    Exit;
  FMask := Mask;
  FStart := Start;
  FEnd := Stop;
  FMins := Mins;
  FMaxs := Maxs;

  { Position test }
  if TVector3.PerfectlyEquals(Start, Stop) then
  begin
    Count := 0;
    BoxLeafsRecursive(HeadNode, Start + Mins - Vector3(1, 1, 1), Start + Maxs + Vector3(1, 1, 1),
      Leafs, Count);
    for I := 0 to Count - 1 do
    begin
      TestInLeaf(Leafs[I]);
      if FTrace.AllSolid then
        Break;
    end;
    FTrace.EndPos := Start;
    Exit(FTrace);
  end;

  FIsPoint := Mins.IsPerfectlyZero and Maxs.IsPerfectlyZero;
  for I := 0 to 2 do
    FExtents.Data[I] := Max(-Mins.Data[I], Maxs.Data[I]);
  RecursiveHullCheck(HeadNode, 0, 1, Start, Stop);
  if FTrace.Fraction = 1 then
    FTrace.EndPos := Stop
  else
    FTrace.EndPos := Start + (Stop - Start) * FTrace.Fraction;
  Result := FTrace;
end;

function TQuakeCollision.PointContents(const P: TVector3; const HeadNode: Integer): Integer;
var
  T: TQuakeTrace;
begin
  T := BoxTrace(P, P, TVector3.Zero, TVector3.Zero, HeadNode, -1);
  if T.StartSolid then
    Result := T.Contents
  else
    Result := 0;
end;

function BoxTraceAgainstBox(const Start, Stop, Mins, Maxs, BoxMins, BoxMaxs: TVector3;
  const BoxContents: Integer): TQuakeTrace;
var
  { The target box grown by the moving box: trace a point against it }
  Lo, Hi, Dir: TVector3;
  EnterFrac, LeaveFrac, D1, D2, F: Single;
  I, Sign: Integer;
  StartOut, GetOut: Boolean;
  Normal, N: TVector3;
begin
  Result := EmptyTrace(Stop);
  Lo := BoxMins - Maxs;
  Hi := BoxMaxs - Mins;
  Dir := Stop - Start;
  EnterFrac := -1;
  LeaveFrac := 1;
  StartOut := False;
  GetOut := False;
  Normal := TVector3.Zero;
  { Six planes: +axis (dist Hi) and -axis (dist -Lo), like a brush }
  for I := 0 to 5 do
  begin
    N := TVector3.Zero;
    Sign := 1 - 2 * (I mod 2);
    N.Data[I div 2] := Sign;
    if Sign > 0 then
    begin
      D1 := Start.Data[I div 2] - Hi.Data[I div 2];
      D2 := Stop.Data[I div 2] - Hi.Data[I div 2];
    end else
    begin
      D1 := Lo.Data[I div 2] - Start.Data[I div 2];
      D2 := Lo.Data[I div 2] - Stop.Data[I div 2];
    end;
    if D2 > 0 then
      GetOut := True;
    if D1 > 0 then
      StartOut := True;
    if (D1 > 0) and (D2 >= D1) then
      Exit;
    if (D1 <= 0) and (D2 <= 0) then
      Continue;
    if D1 > D2 then
    begin
      F := (D1 - TraceEpsilon) / (D1 - D2);
      if F > EnterFrac then
      begin
        EnterFrac := F;
        Normal := N;
      end;
    end else
    begin
      F := (D1 + TraceEpsilon) / (D1 - D2);
      if F < LeaveFrac then
        LeaveFrac := F;
    end;
  end;
  if not StartOut then
  begin
    Result.StartSolid := True;
    Result.AllSolid := not GetOut;
    Result.Contents := BoxContents;
    if Result.AllSolid then
      Result.Fraction := 0;
    Result.EndPos := Start;
    Exit;
  end;
  if (EnterFrac < LeaveFrac) and (EnterFrac > -1) then
  begin
    Result.Fraction := Max(0, EnterFrac);
    Result.Normal := Normal;
    Result.Contents := BoxContents;
    Result.EndPos := Start + Dir * Result.Fraction;
  end;
end;

end.
