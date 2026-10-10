{ Quake 2 BSP (IBSP version 38) map parser. }
unit QuakeBsp;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleLog,
  QuakePak, QuakePalette;

const
  BSP_IDENT   = $50534249; { 'IBSP' little-endian }
  BSP_VERSION = 38;

  LUMP_ENTITIES    = 0;
  LUMP_PLANES      = 1;
  LUMP_VERTICES    = 2;
  LUMP_VISIBILITY  = 3;
  LUMP_NODES       = 4;
  LUMP_TEXINFO     = 5;
  LUMP_FACES       = 6;
  LUMP_LIGHTING    = 7;
  LUMP_LEAFS       = 8;
  LUMP_LEAFFACES   = 9;
  LUMP_LEAFBRUSHES = 10;
  LUMP_EDGES       = 11;
  LUMP_SURFEDGES   = 12;
  LUMP_MODELS      = 13;
  LUMP_BRUSHES     = 14;
  LUMP_BRUSHSIDES  = 15;
  LUMP_POP         = 16;
  LUMP_AREAS       = 17;
  LUMP_AREAPORTALS = 18;
  LUMP_COUNT       = 19;

  { Texinfo surface flags }
  SURF_LIGHT   = $1;   { value holds the light strength }
  SURF_SLICK   = $2;   { effects game physics }
  SURF_SKY     = $4;   { don't draw, but add to skybox }
  SURF_WARP    = $8;   { turbulent water warp }
  SURF_TRANS33 = $10;
  SURF_TRANS66 = $20;
  SURF_FLOWING = $40;  { scroll towards angle }
  SURF_NODRAW  = $80;  { don't bother referencing the texture }

  { Brush / leaf contents }
  CONTENTS_SOLID  = 1;
  CONTENTS_WINDOW = 2;
  CONTENTS_LAVA   = 8;
  CONTENTS_SLIME  = 16;
  CONTENTS_WATER  = 32;
  MASK_LIQUID = CONTENTS_LAVA or CONTENTS_SLIME or CONTENTS_WATER;

type
  TBSPLump = packed record
    Offset: Cardinal;
    Length: Cardinal;
  end;

  TBSPHeader = packed record
    Ident: Cardinal;
    Version: Cardinal;
    Lumps: array[0..LUMP_COUNT - 1] of TBSPLump;
  end;

  TBSPPlane = packed record
    Normal: TVector3;
    Dist: Single;
    PlaneType: LongInt;
  end;

  TBSPNode = packed record
    PlaneNum: LongInt;
    Children: array[0..1] of LongInt; { negative numbers are -(leafs+1) }
    Mins, Maxs: array[0..2] of SmallInt;
    FirstFace: Word;
    NumFaces: Word;
  end;

  TBSPLeaf = packed record
    Contents: LongInt;
    Cluster: SmallInt;
    Area: SmallInt;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstLeafFace, NumLeafFaces: Word;
    FirstLeafBrush, NumLeafBrushes: Word;
  end;

  TBSPEdge = packed record
    V0: Word;
    V1: Word;
  end;

  TBSPTexInfo = packed record
    VecS: TVector4;
    VecT: TVector4;
    Flags: LongInt;
    Value: LongInt;
    Texture: array[0..31] of AnsiChar;
    NextTexInfo: LongInt; { for animations, -1 = end of chain }
  end;

  TBSPFace = packed record
    PlaneId: Word;
    Side: SmallInt;
    FirstEdge: LongInt;
    NumEdges: SmallInt;
    TexInfoId: SmallInt;
    Styles: array[0..3] of Byte;
    LightmapOffset: LongInt;
  end;

  TBSPModel = packed record
    Mins: TVector3;
    Maxs: TVector3;
    Origin: TVector3;
    HeadNode: LongInt;
    FirstFace: LongInt;
    NumFaces: LongInt;
  end;

  { Lightmap extents of a face, computed like Quake 2's CalcSurfaceExtents. }
  TQuakeFaceExtents = record
    TexMinS, TexMinT: Integer; { multiples of 16 }
    ExtentS, ExtentT: Integer; { multiples of 16 }
    function LightmapWidth: Integer;
    function LightmapHeight: Integer;
  end;

  TQuakeEntity = class
  private
    FFields: specialize TDictionary<String, String>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetField(const Key, Value: String);
    function GetField(const Key: String; const Default: String = ''): String;
    function HasField(const Key: String): Boolean;
    function GetVector(const Key: String; const Default: TVector3): TVector3;
    function GetFloat(const Key: String; const Default: Single = 0): Single;
    function GetInt(const Key: String; const Default: Integer = 0): Integer;

    function ClassName: String;
    function Origin: TVector3;
    function Target: String;
    function TargetName: String;
    function Model: String;
    function Angle: Single;
    function MessageText: String;
    function Speed(const Default: Single = 100): Single;
    function Sounds: Integer;
    function SpawnFlags: Integer;

    property Fields: specialize TDictionary<String, String> read FFields;
  end;

  TQuakeEntityList = specialize TObjectList<TQuakeEntity>;

  TBSPPlaneArray = array of TBSPPlane;
  TBSPNodeArray = array of TBSPNode;
  TBSPLeafArray = array of TBSPLeaf;
  TVector3Array = array of TVector3;
  TBSPEdgeArray = array of TBSPEdge;
  TSurfEdgeArray = array of LongInt;
  TBSPTexInfoArray = array of TBSPTexInfo;
  TBSPFaceArray = array of TBSPFace;
  TBSPModelArray = array of TBSPModel;
  TFaceExtentsArray = array of TQuakeFaceExtents;

  { Loaded Quake 2 BSP map }
  TQuakeBsp = class
  private
    FMapName: String;
    FPlanes: TBSPPlaneArray;
    FNodes: TBSPNodeArray;
    FLeafs: TBSPLeafArray;
    FVertices: TVector3Array;
    FEdges: TBSPEdgeArray;
    FSurfEdges: TSurfEdgeArray;
    FTexInfos: TBSPTexInfoArray;
    FTexNames: array of String;
    FTexSizes: array of TVector2Integer;
    FFaces: TBSPFaceArray;
    FExtents: TFaceExtentsArray;
    FModels: TBSPModelArray;
    FLightmaps: TBytes;
    FEntities: TQuakeEntityList;
    function GetFaceCount: Integer; inline;
    function GetModelCount: Integer; inline;
    procedure ParseEntities(const Text: String);
    procedure LoadTextures;
    procedure ComputeExtents;
    function RecursiveLightPoint(const NodeIdx: Integer; const Start, Stop: TVector3;
      out Color: TVector3): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    { Load map from PAK, e.g. "maps/base1.bsp" }
    function LoadFromPak(const AMapPath: String): Boolean;

    { Vertex position (Quake coordinates) for given face and local index (0 .. NumEdges - 1) }
    function GetFaceVertex(const FaceIdx, VertIdx: Integer): TVector3;

    { Raw texture-space S/T of a point for a texinfo (in texels) }
    function TexS(const Vert: TVector3; const TexInfoIdx: Integer): Single;
    function TexT(const Vert: TVector3; const TexInfoIdx: Integer): Single;

    { Texture UV coordinates (CGE convention, V flipped) for a point and texinfo }
    function GetFaceTexCoord(const Vert: TVector3; const TexInfoIdx: Integer): TVector2;

    { Face plane normal (Quake coordinates) }
    function GetFaceNormal(const FaceIdx: Integer): TVector3;

    { Texture name ("e1u1/floor1_3") of a texinfo }
    function TexName(const TexInfoIdx: Integer): String;

    { Sample the baked lightmap below a point, like Quake 2's R_LightPoint.
      Returns 0..1 RGB (unmodulated); False when nothing below was found. }
    function LightPoint(const P: TVector3; out Color: TVector3): Boolean;

    { Contents (CONTENTS_* bits) of the BSP leaf containing a point
      (Quake coordinates), like Quake 2's CM_PointContents for the world. }
    function PointContents(const P: TVector3): Integer;

    { Find first entity by classname }
    function FindEntity(const AClassName: String): TQuakeEntity;

    { Find all entities matching classname (all when empty). Caller frees the list. }
    function FindEntities(const AClassName: String): TQuakeEntityList;

    { Find all entities with given targetname. Caller frees the list. }
    function FindByTargetName(const ATargetName: String): TQuakeEntityList;

    property MapName: String read FMapName;
    property Faces: TBSPFaceArray read FFaces;
    property FaceExtents: TFaceExtentsArray read FExtents;
    property FaceCount: Integer read GetFaceCount;
    property Models: TBSPModelArray read FModels;
    property ModelCount: Integer read GetModelCount;
    property Entities: TQuakeEntityList read FEntities;
    property Lightmaps: TBytes read FLightmaps;
    property TexInfos: TBSPTexInfoArray read FTexInfos;
  end;

implementation

{ TQuakeFaceExtents }

function TQuakeFaceExtents.LightmapWidth: Integer;
begin
  Result := (ExtentS shr 4) + 1;
end;

function TQuakeFaceExtents.LightmapHeight: Integer;
begin
  Result := (ExtentT shr 4) + 1;
end;

{ TQuakeEntity }

constructor TQuakeEntity.Create;
begin
  inherited Create;
  FFields := specialize TDictionary<String, String>.Create;
end;

destructor TQuakeEntity.Destroy;
begin
  FFields.Free;
  inherited Destroy;
end;

procedure TQuakeEntity.SetField(const Key, Value: String);
begin
  FFields.AddOrSetValue(LowerCase(Key), Value);
end;

function TQuakeEntity.GetField(const Key: String; const Default: String): String;
begin
  if not FFields.TryGetValue(LowerCase(Key), Result) then
    Result := Default;
end;

function TQuakeEntity.HasField(const Key: String): Boolean;
begin
  Result := FFields.ContainsKey(LowerCase(Key));
end;

function TQuakeEntity.GetVector(const Key: String; const Default: TVector3): TVector3;
var
  Parts: TStringArray;
  I, Idx: Integer;
  F: Single;
  FS: TFormatSettings;
begin
  Result := Default;
  if not HasField(Key) then
    Exit;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Parts := Trim(GetField(Key)).Split([' ', #9]);
  Idx := 0;
  for I := 0 to High(Parts) do
    if (Parts[I] <> '') and (Idx < 3) then
    begin
      if TryStrToFloat(Parts[I], F, FS) then
        Result.Data[Idx] := F;
      Inc(Idx);
    end;
end;

function TQuakeEntity.GetFloat(const Key: String; const Default: Single): Single;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(GetField(Key)), Default, FS);
end;

function TQuakeEntity.GetInt(const Key: String; const Default: Integer): Integer;
begin
  Result := Round(GetFloat(Key, Default));
end;

function TQuakeEntity.ClassName: String;
begin
  Result := LowerCase(GetField('classname'));
end;

function TQuakeEntity.Origin: TVector3;
begin
  Result := GetVector('origin', Vector3(0, 0, 0));
end;

function TQuakeEntity.Target: String;
begin
  Result := GetField('target');
end;

function TQuakeEntity.TargetName: String;
begin
  Result := GetField('targetname');
end;

function TQuakeEntity.Model: String;
begin
  Result := GetField('model');
end;

function TQuakeEntity.Angle: Single;
begin
  if HasField('angle') then
    Result := GetFloat('angle', 0)
  else
    Result := GetVector('angles', Vector3(0, 0, 0)).Y;
end;

function TQuakeEntity.MessageText: String;
begin
  Result := GetField('message');
end;

function TQuakeEntity.Speed(const Default: Single): Single;
begin
  Result := GetFloat('speed', Default);
  if Result <= 0 then
    Result := Default;
end;

function TQuakeEntity.Sounds: Integer;
begin
  Result := GetInt('sounds', 0);
end;

function TQuakeEntity.SpawnFlags: Integer;
begin
  Result := GetInt('spawnflags', 0);
end;

{ TQuakeBsp }

constructor TQuakeBsp.Create;
begin
  inherited Create;
  FEntities := TQuakeEntityList.Create(True);
end;

destructor TQuakeBsp.Destroy;
begin
  FEntities.Free;
  inherited Destroy;
end;

function TQuakeBsp.GetFaceCount: Integer;
begin
  Result := Length(FFaces);
end;

function TQuakeBsp.GetModelCount: Integer;
begin
  Result := Length(FModels);
end;

procedure TQuakeBsp.ParseEntities(const Text: String);
var
  I, Len: Integer;
  CurEnt: TQuakeEntity;
  Tokens: array[0..1] of String;
  TokenCount: Integer;
  S: String;
begin
  FEntities.Clear;
  Len := Length(Text);
  I := 1;
  CurEnt := nil;
  TokenCount := 0;
  while I <= Len do
  begin
    case Text[I] of
      '{':
        begin
          FreeAndNil(CurEnt);
          CurEnt := TQuakeEntity.Create;
          TokenCount := 0;
        end;
      '}':
        if CurEnt <> nil then
        begin
          FEntities.Add(CurEnt);
          CurEnt := nil;
        end;
      '"':
        begin
          Inc(I);
          S := '';
          while (I <= Len) and (Text[I] <> '"') do
          begin
            S := S + Text[I];
            Inc(I);
          end;
          if CurEnt <> nil then
          begin
            Tokens[TokenCount] := S;
            Inc(TokenCount);
            if TokenCount = 2 then
            begin
              CurEnt.SetField(Tokens[0], Tokens[1]);
              TokenCount := 0;
            end;
          end;
        end;
    end;
    Inc(I);
  end;
  CurEnt.Free;
end;

procedure TQuakeBsp.LoadTextures;
var
  I: Integer;
  Info: TQuakeWalInfo;
begin
  SetLength(FTexNames, Length(FTexInfos));
  SetLength(FTexSizes, Length(FTexInfos));
  for I := 0 to High(FTexInfos) do
  begin
    FTexNames[I] := LowerCase(Trim(PAnsiChar(@FTexInfos[I].Texture[0])));
    if (FTexInfos[I].Flags and SURF_NODRAW) <> 0 then
    begin
      FTexSizes[I] := Vector2Integer(64, 64);
      Continue;
    end;
    Palette.LoadWal(FTexNames[I], Info);
    FTexSizes[I] := Vector2Integer(Max(1, Info.Width), Max(1, Info.Height));
  end;
end;

procedure TQuakeBsp.ComputeExtents;
var
  FaceIdx, V: Integer;
  MinS, MaxS, MinT, MaxT, S, T: Single;
  P: TVector3;
  Ext: TQuakeFaceExtents;
  BMinS, BMinT, BMaxS, BMaxT: Integer;
begin
  SetLength(FExtents, Length(FFaces));
  for FaceIdx := 0 to High(FFaces) do
  begin
    MinS := 1e30; MaxS := -1e30;
    MinT := 1e30; MaxT := -1e30;
    for V := 0 to FFaces[FaceIdx].NumEdges - 1 do
    begin
      P := GetFaceVertex(FaceIdx, V);
      S := TexS(P, FFaces[FaceIdx].TexInfoId);
      T := TexT(P, FFaces[FaceIdx].TexInfoId);
      MinS := Min(MinS, S); MaxS := Max(MaxS, S);
      MinT := Min(MinT, T); MaxT := Max(MaxT, T);
    end;
    BMinS := Floor(MinS / 16);
    BMinT := Floor(MinT / 16);
    BMaxS := Ceil(MaxS / 16);
    BMaxT := Ceil(MaxT / 16);
    Ext.TexMinS := BMinS * 16;
    Ext.TexMinT := BMinT * 16;
    Ext.ExtentS := (BMaxS - BMinS) * 16;
    Ext.ExtentT := (BMaxT - BMinT) * 16;
    FExtents[FaceIdx] := Ext;
  end;
end;

function TQuakeBsp.LoadFromPak(const AMapPath: String): Boolean;
var
  Data: PByte;
  Size: Cardinal;
  Hdr: TBSPHeader;
  I: Integer;
  EntText: String;

  function LumpValid(const L: Integer): Boolean;
  begin
    Result := Hdr.Lumps[L].Offset + Hdr.Lumps[L].Length <= Size;
  end;

begin
  Result := False;
  FMapName := LowerCase(ChangeFileExt(ExtractFileName(AMapPath), ''));
  Data := Pak.GetData(AMapPath, Size);
  if Data = nil then
  begin
    WritelnWarning('QuakeBsp', 'Map "%s" not found in PAK', [AMapPath]);
    Exit;
  end;
  if Size < SizeOf(TBSPHeader) then
    Exit;

  Move(Data^, Hdr, SizeOf(Hdr));
  if (Hdr.Ident <> BSP_IDENT) or (Hdr.Version <> BSP_VERSION) then
  begin
    WritelnWarning('QuakeBsp', 'Map "%s" is not a Quake 2 IBSP v38 map (version %d)',
      [AMapPath, Hdr.Version]);
    Exit;
  end;
  for I := 0 to LUMP_COUNT - 1 do
    if not LumpValid(I) then
    begin
      WritelnWarning('QuakeBsp', 'Map "%s" lump %d out of bounds', [AMapPath, I]);
      Exit;
    end;

  SetString(EntText, PAnsiChar(Data + Hdr.Lumps[LUMP_ENTITIES].Offset),
    Hdr.Lumps[LUMP_ENTITIES].Length);
  ParseEntities(EntText);

  SetLength(FPlanes, Hdr.Lumps[LUMP_PLANES].Length div SizeOf(TBSPPlane));
  if Length(FPlanes) > 0 then
    Move((Data + Hdr.Lumps[LUMP_PLANES].Offset)^, FPlanes[0], Length(FPlanes) * SizeOf(TBSPPlane));

  SetLength(FNodes, Hdr.Lumps[LUMP_NODES].Length div SizeOf(TBSPNode));
  if Length(FNodes) > 0 then
    Move((Data + Hdr.Lumps[LUMP_NODES].Offset)^, FNodes[0], Length(FNodes) * SizeOf(TBSPNode));

  SetLength(FLeafs, Hdr.Lumps[LUMP_LEAFS].Length div SizeOf(TBSPLeaf));
  if Length(FLeafs) > 0 then
    Move((Data + Hdr.Lumps[LUMP_LEAFS].Offset)^, FLeafs[0], Length(FLeafs) * SizeOf(TBSPLeaf));

  SetLength(FVertices, Hdr.Lumps[LUMP_VERTICES].Length div SizeOf(TVector3));
  if Length(FVertices) > 0 then
    Move((Data + Hdr.Lumps[LUMP_VERTICES].Offset)^, FVertices[0], Length(FVertices) * SizeOf(TVector3));

  SetLength(FEdges, Hdr.Lumps[LUMP_EDGES].Length div SizeOf(TBSPEdge));
  if Length(FEdges) > 0 then
    Move((Data + Hdr.Lumps[LUMP_EDGES].Offset)^, FEdges[0], Length(FEdges) * SizeOf(TBSPEdge));

  SetLength(FSurfEdges, Hdr.Lumps[LUMP_SURFEDGES].Length div SizeOf(LongInt));
  if Length(FSurfEdges) > 0 then
    Move((Data + Hdr.Lumps[LUMP_SURFEDGES].Offset)^, FSurfEdges[0], Length(FSurfEdges) * SizeOf(LongInt));

  SetLength(FTexInfos, Hdr.Lumps[LUMP_TEXINFO].Length div SizeOf(TBSPTexInfo));
  if Length(FTexInfos) > 0 then
    Move((Data + Hdr.Lumps[LUMP_TEXINFO].Offset)^, FTexInfos[0], Length(FTexInfos) * SizeOf(TBSPTexInfo));

  SetLength(FFaces, Hdr.Lumps[LUMP_FACES].Length div SizeOf(TBSPFace));
  if Length(FFaces) > 0 then
    Move((Data + Hdr.Lumps[LUMP_FACES].Offset)^, FFaces[0], Length(FFaces) * SizeOf(TBSPFace));

  SetLength(FModels, Hdr.Lumps[LUMP_MODELS].Length div SizeOf(TBSPModel));
  if Length(FModels) > 0 then
    Move((Data + Hdr.Lumps[LUMP_MODELS].Offset)^, FModels[0], Length(FModels) * SizeOf(TBSPModel));

  SetLength(FLightmaps, Hdr.Lumps[LUMP_LIGHTING].Length);
  if Length(FLightmaps) > 0 then
    Move((Data + Hdr.Lumps[LUMP_LIGHTING].Offset)^, FLightmaps[0], Length(FLightmaps));

  LoadTextures;
  ComputeExtents;

  WritelnLog('QuakeBsp', 'Loaded map "%s": %d faces, %d vertices, %d texinfos, %d models, %d entities',
    [AMapPath, Length(FFaces), Length(FVertices), Length(FTexInfos), Length(FModels), FEntities.Count]);
  Result := Length(FModels) > 0;
end;

function TQuakeBsp.GetFaceVertex(const FaceIdx, VertIdx: Integer): TVector3;
var
  SurfEdge: LongInt;
  VIdx: Integer;
begin
  Result := Vector3(0, 0, 0);
  SurfEdge := FSurfEdges[FFaces[FaceIdx].FirstEdge + VertIdx];
  if SurfEdge >= 0 then
    VIdx := FEdges[SurfEdge].V0
  else
    VIdx := FEdges[-SurfEdge].V1;
  if VIdx < Length(FVertices) then
    Result := FVertices[VIdx];
end;

function TQuakeBsp.TexS(const Vert: TVector3; const TexInfoIdx: Integer): Single;
begin
  if (TexInfoIdx < 0) or (TexInfoIdx > High(FTexInfos)) then
    Exit(0);
  Result := TVector3.DotProduct(Vert, FTexInfos[TexInfoIdx].VecS.XYZ) + FTexInfos[TexInfoIdx].VecS.W;
end;

function TQuakeBsp.TexT(const Vert: TVector3; const TexInfoIdx: Integer): Single;
begin
  if (TexInfoIdx < 0) or (TexInfoIdx > High(FTexInfos)) then
    Exit(0);
  Result := TVector3.DotProduct(Vert, FTexInfos[TexInfoIdx].VecT.XYZ) + FTexInfos[TexInfoIdx].VecT.W;
end;

function TQuakeBsp.GetFaceTexCoord(const Vert: TVector3; const TexInfoIdx: Integer): TVector2;
begin
  if (TexInfoIdx < 0) or (TexInfoIdx > High(FTexInfos)) then
    Exit(Vector2(0, 0));
  Result := Vector2(
    TexS(Vert, TexInfoIdx) / FTexSizes[TexInfoIdx].X,
    1.0 - TexT(Vert, TexInfoIdx) / FTexSizes[TexInfoIdx].Y);
end;

function TQuakeBsp.GetFaceNormal(const FaceIdx: Integer): TVector3;
var
  Face: TBSPFace;
begin
  Result := Vector3(0, 0, 1);
  Face := FFaces[FaceIdx];
  if Face.PlaneId < Length(FPlanes) then
  begin
    Result := FPlanes[Face.PlaneId].Normal;
    if Face.Side <> 0 then
      Result := -Result;
  end;
end;

function TQuakeBsp.TexName(const TexInfoIdx: Integer): String;
begin
  if (TexInfoIdx >= 0) and (TexInfoIdx <= High(FTexNames)) then
    Result := FTexNames[TexInfoIdx]
  else
    Result := '';
end;

function TQuakeBsp.RecursiveLightPoint(const NodeIdx: Integer; const Start, Stop: TVector3;
  out Color: TVector3): Integer;
var
  Node: TBSPNode;
  Plane: TBSPPlane;
  Front, Back, Frac, S, T: Single;
  Side, I, FaceIdx, DS, DT, Ofs: Integer;
  Mid: TVector3;
  Ext: TQuakeFaceExtents;
  Ti: Integer;
begin
  Color := Vector3(0, 0, 0);
  if NodeIdx < 0 then
    Exit(-1); { reached a leaf }

  Node := FNodes[NodeIdx];
  Plane := FPlanes[Node.PlaneNum];
  Front := TVector3.DotProduct(Start, Plane.Normal) - Plane.Dist;
  Back := TVector3.DotProduct(Stop, Plane.Normal) - Plane.Dist;
  Side := Ord(Front < 0);

  if (Back < 0) = (Side = 1) then
    Exit(RecursiveLightPoint(Node.Children[Side], Start, Stop, Color));

  Frac := Front / (Front - Back);
  Mid := Start + (Stop - Start) * Frac;

  { Go down front side }
  Result := RecursiveLightPoint(Node.Children[Side], Start, Mid, Color);
  if Result >= 0 then
    Exit;

  { Check for impact on this node's faces }
  for I := 0 to Node.NumFaces - 1 do
  begin
    FaceIdx := Node.FirstFace + I;
    Ti := FFaces[FaceIdx].TexInfoId;
    if (FTexInfos[Ti].Flags and (SURF_WARP or SURF_SKY)) <> 0 then
      Continue;
    Ext := FExtents[FaceIdx];
    S := TexS(Mid, Ti);
    T := TexT(Mid, Ti);
    if (S < Ext.TexMinS) or (T < Ext.TexMinT) then
      Continue;
    DS := Trunc(S - Ext.TexMinS);
    DT := Trunc(T - Ext.TexMinT);
    if (DS > Ext.ExtentS) or (DT > Ext.ExtentT) then
      Continue;
    if FFaces[FaceIdx].LightmapOffset < 0 then
      Exit(0);
    Ofs := FFaces[FaceIdx].LightmapOffset + 3 * ((DT shr 4) * Ext.LightmapWidth + (DS shr 4));
    if Ofs + 2 < Length(FLightmaps) then
      Color := Vector3(FLightmaps[Ofs], FLightmaps[Ofs + 1], FLightmaps[Ofs + 2]) / 255.0;
    Exit(1);
  end;

  { Go down back side }
  Result := RecursiveLightPoint(Node.Children[1 - Side], Mid, Stop, Color);
end;

function TQuakeBsp.LightPoint(const P: TVector3; out Color: TVector3): Boolean;
begin
  Color := Vector3(0.5, 0.5, 0.5);
  if (Length(FNodes) = 0) or (Length(FModels) = 0) or (Length(FLightmaps) = 0) then
    Exit(False);
  Result := RecursiveLightPoint(FModels[0].HeadNode, P, P - Vector3(0, 0, 2048), Color) >= 0;
end;

function TQuakeBsp.PointContents(const P: TVector3): Integer;
var
  Node: Integer;
  Plane: TBSPPlane;
begin
  Result := 0;
  if (Length(FModels) = 0) or (Length(FNodes) = 0) then
    Exit;
  Node := FModels[0].HeadNode;
  while Node >= 0 do
  begin
    Plane := FPlanes[FNodes[Node].PlaneNum];
    if TVector3.DotProduct(P, Plane.Normal) - Plane.Dist >= 0 then
      Node := FNodes[Node].Children[0]
    else
      Node := FNodes[Node].Children[1];
  end;
  Node := -(Node + 1);
  if Node < Length(FLeafs) then
    Result := FLeafs[Node].Contents;
end;

function TQuakeBsp.FindEntity(const AClassName: String): TQuakeEntity;
var
  Ent: TQuakeEntity;
begin
  for Ent in FEntities do
    if Ent.ClassName = LowerCase(AClassName) then
      Exit(Ent);
  Result := nil;
end;

function TQuakeBsp.FindEntities(const AClassName: String): TQuakeEntityList;
var
  Ent: TQuakeEntity;
begin
  Result := TQuakeEntityList.Create(False);
  for Ent in FEntities do
    if (AClassName = '') or (Ent.ClassName = LowerCase(AClassName)) then
      Result.Add(Ent);
end;

function TQuakeBsp.FindByTargetName(const ATargetName: String): TQuakeEntityList;
var
  Ent: TQuakeEntity;
begin
  Result := TQuakeEntityList.Create(False);
  if ATargetName = '' then
    Exit;
  for Ent in FEntities do
    if SameText(Ent.TargetName, ATargetName) then
      Result.Add(Ent);
end;

end.
