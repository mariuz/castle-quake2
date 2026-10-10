{ Quake 2 MD2 (IDP2 version 8) model loader, animation and scene builder. }
unit QuakeMd2;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, X3DNodes, CastleLog, CastleUtils, CastleRenderOptions,
  QuakePak, QuakePalette, QuakeLight;

type
  { Consecutive frames sharing a name prefix, e.g. "run1".."run8" }
  TMd2Anim = record
    First, Count: Integer;
  end;

  { Quake 2 MD2 model. Vertices are "unwelded" so every output vertex has a
    single position + texture coordinate (MD2 indexes them separately). }
  TQuakeMd2 = class
  private
    FModelPath: String;
    FSkins: TStringList;
    FUVs: TVector2List;
    FIndices: TInt32List;
    FFrames: specialize TObjectList<TVector3List>;
    FFrameNames: TStringList;
    FAnims: specialize TDictionary<String, TMd2Anim>;
    function GetFrameCount: Integer;
  public
    constructor Create(const AModelPath: String);
    destructor Destroy; override;
    function LoadFromData(const Data: PByte; const Size: Cardinal): Boolean;

    { Texture id (for quaketex:) of the skin, '' if none could be loaded }
    function SkinId(const SkinIndex: Integer): String;

    { Find animation by name (e.g. "stand", "run", "attak1", "death1").
      Tries each comma-separated alternative; returns False if none exists.
      An empty name means all frames. }
    function FindAnim(const Names: String; out Anim: TMd2Anim): Boolean;

    { Interpolated vertex positions between frames A and B (0 <= T <= 1) }
    procedure LerpFrames(const A, B: Integer; const T: Single; const Dest: TVector3List);

    property ModelPath: String read FModelPath;
    property FrameCount: Integer read GetFrameCount;
    property FrameNames: TStringList read FFrameNames;
  end;

  { One placed copy of an MD2 model with its own scene, animation and tint. }
  TQuakeMd2Instance = class
  private
    FModel: TQuakeMd2;
    FCoord: TCoordinateNode;
    FMaterial: TUnlitMaterialNode;
    FAppearance: TAppearanceNode;
    FTexture: TImageTextureNode;
    FSkinIndex: Integer;
    FTemp: TVector3List;
    FAnim: TMd2Anim;
    FAnimTime: Single;
    FAnimLoop: Boolean;
    FAnimDone: Boolean;
    FFps: Single;
    FLastA, FLastB: Integer;
    FLastT: Single;
  public
    Scene: TCastleScene;
    constructor Create(const AModel: TQuakeMd2; const SkinIndex: Integer = 0);
    destructor Destroy; override;
    { Start playing animation (Names as in TQuakeMd2.FindAnim). Returns False if missing. }
    function PlayAnim(const Names: String; const Loop: Boolean = True; const Fps: Single = 10): Boolean;
    { Advance and apply the current animation }
    procedure Update(const SecondsPassed: Single);
    { Show a fixed frame }
    procedure SetFrame(const Index: Integer);
    { Lighting tint (0..1+, see TQuakeLighting.SampleLight) }
    procedure SetTint(const Color: TVector3);
    { Switch to another skin of the model (ignored if missing) }
    procedure SetSkin(const SkinIndex: Integer);
    { 0 = opaque, 1 = invisible (switches to alpha blending) }
    procedure SetTransparency(const Value: Single);
    property Model: TQuakeMd2 read FModel;
    { True when a non-looping animation reached its last frame }
    property AnimDone: Boolean read FAnimDone;
    { 0..1 position in the current animation (non-looping ones stop at 1) }
    function AnimProgress: Single;
  end;

  { Model cache }
  TQuakeMd2Manager = class
  private
    FCache: specialize TObjectDictionary<String, TQuakeMd2>;
  public
    constructor Create;
    destructor Destroy; override;
    { Get or load model, e.g. "models/monsters/soldier/tris.md2". nil if missing. }
    function GetModel(const APath: String): TQuakeMd2;
    { Create an instance (nil if the model is missing) }
    function CreateInstance(const APath: String; const SkinIndex: Integer = 0): TQuakeMd2Instance;
  end;

var
  Md2Manager: TQuakeMd2Manager;

implementation

type
  TMd2Header = packed record
    Ident: array[0..3] of AnsiChar; { 'IDP2' }
    Version: LongInt;               { 8 }
    SkinWidth, SkinHeight: LongInt;
    FrameSize: LongInt;
    NumSkins, NumXyz, NumSt, NumTris, NumGlCmds, NumFrames: LongInt;
    OfsSkins, OfsSt, OfsTris, OfsFrames, OfsGlCmds, OfsEnd: LongInt;
  end;

  TMd2St = packed record
    S, T: SmallInt;
  end;

  TMd2Tri = packed record
    IndexXyz: array[0..2] of Word;
    IndexSt: array[0..2] of Word;
  end;

  TMd2Vert = packed record
    V: array[0..2] of Byte;
    LightNormalIndex: Byte;
  end;

  TMd2FrameHeader = packed record
    Scale: TVector3;
    Translate: TVector3;
    Name: array[0..15] of AnsiChar;
  end;

{ Animation name of a frame: "run3" -> "run", "stand01" -> "stand",
  "attak105" -> "attak1" (3+ digits: the last two are the frame number,
  the rest selects one of several sequences, like death1 / death2). }
function AnimBaseName(const FrameName: String): String;
var
  DigitCount: Integer;
begin
  Result := FrameName;
  DigitCount := 0;
  while (DigitCount < Length(Result)) and
        CharInSet(Result[Length(Result) - DigitCount], ['0'..'9']) do
    Inc(DigitCount);
  if DigitCount >= 3 then
    SetLength(Result, Length(Result) - 2)
  else
    SetLength(Result, Length(Result) - DigitCount);
end;

{ TQuakeMd2 }

constructor TQuakeMd2.Create(const AModelPath: String);
begin
  inherited Create;
  FModelPath := AModelPath;
  FSkins := TStringList.Create;
  FUVs := TVector2List.Create;
  FIndices := TInt32List.Create;
  FFrames := specialize TObjectList<TVector3List>.Create(True);
  FFrameNames := TStringList.Create;
  FAnims := specialize TDictionary<String, TMd2Anim>.Create;
end;

destructor TQuakeMd2.Destroy;
begin
  FSkins.Free;
  FUVs.Free;
  FIndices.Free;
  FFrames.Free;
  FFrameNames.Free;
  FAnims.Free;
  inherited Destroy;
end;

function TQuakeMd2.GetFrameCount: Integer;
begin
  Result := FFrames.Count;
end;

function TQuakeMd2.LoadFromData(const Data: PByte; const Size: Cardinal): Boolean;
var
  Hdr: TMd2Header;
  I, J, K, OutIdx: Integer;
  Sts: ^TMd2St;
  Tris: ^TMd2Tri;
  Tri: TMd2Tri;
  St: TMd2St;
  Pairs: specialize TDictionary<Int64, Integer>;
  PairKey: Int64;
  OutXyz: TInt32List;
  FrameHdr: ^TMd2FrameHeader;
  Verts: ^TMd2Vert;
  Vert: TMd2Vert;
  FramePoints: TVector3List;
  Name, Base, SkinName: String;
  Anim: TMd2Anim;
  P: TVector3;
begin
  Result := False;
  if Size < SizeOf(TMd2Header) then
    Exit;
  Move(Data^, Hdr, SizeOf(Hdr));
  if (Hdr.Ident[0] <> 'I') or (Hdr.Ident[1] <> 'D') or (Hdr.Ident[2] <> 'P') or
     (Hdr.Ident[3] <> '2') or (Hdr.Version <> 8) or (Hdr.NumTris <= 0) or
     (Hdr.NumFrames <= 0) or (Cardinal(Hdr.OfsEnd) > Size) then
  begin
    WritelnWarning('QuakeMd2', 'Invalid MD2 file "%s"', [FModelPath]);
    Exit;
  end;

  { Skins: 64-char paths of PCX images }
  for I := 0 to Hdr.NumSkins - 1 do
  begin
    SetString(SkinName, PAnsiChar(Data + Hdr.OfsSkins + I * 64), 64);
    SkinName := LowerCase(Trim(PAnsiChar(SkinName)));
    FSkins.Add(SkinName);
  end;

  Sts := Pointer(Data + Hdr.OfsSt);
  Tris := Pointer(Data + Hdr.OfsTris);

  { Unweld (xyz, st) pairs into output vertices }
  Pairs := specialize TDictionary<Int64, Integer>.Create;
  OutXyz := TInt32List.Create;
  try
    for I := 0 to Hdr.NumTris - 1 do
    begin
      Tri := Tris[I];
      for J := 0 to 2 do
      begin
        if (Tri.IndexXyz[J] >= Hdr.NumXyz) or (Tri.IndexSt[J] >= Hdr.NumSt) then
          Exit;
        PairKey := Int64(Tri.IndexXyz[J]) shl 32 or Tri.IndexSt[J];
        if not Pairs.TryGetValue(PairKey, OutIdx) then
        begin
          OutIdx := OutXyz.Count;
          OutXyz.Add(Tri.IndexXyz[J]);
          St := Sts[Tri.IndexSt[J]];
          FUVs.Add(Vector2(
            (St.S + 0.5) / Max(1, Hdr.SkinWidth),
            1.0 - (St.T + 0.5) / Max(1, Hdr.SkinHeight)));
          Pairs.Add(PairKey, OutIdx);
        end;
        FIndices.Add(OutIdx);
      end;
    end;

    { Frames }
    for I := 0 to Hdr.NumFrames - 1 do
    begin
      FrameHdr := Pointer(Data + Hdr.OfsFrames + I * Hdr.FrameSize);
      Verts := Pointer(PByte(FrameHdr) + SizeOf(TMd2FrameHeader));
      FramePoints := TVector3List.Create;
      FramePoints.Count := OutXyz.Count;
      for K := 0 to OutXyz.Count - 1 do
      begin
        Vert := Verts[OutXyz[K]];
        P := Vector3(
          Vert.V[0] * FrameHdr^.Scale.X + FrameHdr^.Translate.X,
          Vert.V[1] * FrameHdr^.Scale.Y + FrameHdr^.Translate.Y,
          Vert.V[2] * FrameHdr^.Scale.Z + FrameHdr^.Translate.Z);
        FramePoints.L[K] := QuakeToCge(P);
      end;
      FFrames.Add(FramePoints);

      Name := LowerCase(Trim(PAnsiChar(@FrameHdr^.Name[0])));
      FFrameNames.Add(Name);
      Base := AnimBaseName(Name);
      if FAnims.TryGetValue(Base, Anim) and (Anim.First + Anim.Count = I) then
      begin
        Inc(Anim.Count);
        FAnims[Base] := Anim;
      end else
      if not FAnims.ContainsKey(Base) then
      begin
        Anim.First := I;
        Anim.Count := 1;
        FAnims.Add(Base, Anim);
      end;
    end;
  finally
    Pairs.Free;
    OutXyz.Free;
  end;
  Result := True;
end;

function TQuakeMd2.SkinId(const SkinIndex: Integer): String;
var
  Candidates: TStringList;
  C: String;
begin
  Result := '';
  Candidates := TStringList.Create;
  try
    if (SkinIndex >= 0) and (SkinIndex < FSkins.Count) then
      Candidates.Add(FSkins[SkinIndex]);
    if FSkins.Count > 0 then
      Candidates.Add(FSkins[0]);
    { Many models reference skins by a path that differs from the PAK;
      fall back to a skin.pcx next to tris.md2 }
    Candidates.Add(ExtractFilePath(FModelPath) + 'skin.pcx');
    for C in Candidates do
      if (C <> '') and Palette.LoadPcx(C) then
        Exit(C);
  finally
    Candidates.Free;
  end;
end;

function TQuakeMd2.FindAnim(const Names: String; out Anim: TMd2Anim): Boolean;
var
  Parts: TStringArray;
  N: String;
  I: Integer;
begin
  { Empty name: the whole frame range (banners, dish, effects) }
  if Trim(Names) = '' then
  begin
    Anim.First := 0;
    Anim.Count := FFrames.Count;
    Exit(True);
  end;
  Parts := LowerCase(Names).Split([',']);
  for N in Parts do
  begin
    if FAnims.TryGetValue(Trim(N), Anim) then
      Exit(True);
    { Prefix match, e.g. "death" matches "death1" sequences }
    for I := 0 to FFrameNames.Count - 1 do
      if (Trim(N) <> '') and (Pos(Trim(N), FFrameNames[I]) = 1) and
         FAnims.TryGetValue(AnimBaseName(FFrameNames[I]), Anim) then
        Exit(True);
  end;
  Anim.First := 0;
  Anim.Count := 1;
  Result := False;
end;

procedure TQuakeMd2.LerpFrames(const A, B: Integer; const T: Single; const Dest: TVector3List);
var
  FA, FB: TVector3List;
  I: Integer;
begin
  FA := FFrames[EnsureRange(A, 0, FFrames.Count - 1)];
  FB := FFrames[EnsureRange(B, 0, FFrames.Count - 1)];
  Dest.Count := FA.Count;
  for I := 0 to FA.Count - 1 do
    Dest.L[I] := FA.L[I] + (FB.L[I] - FA.L[I]) * T;
end;

{ TQuakeMd2Instance }

constructor TQuakeMd2Instance.Create(const AModel: TQuakeMd2; const SkinIndex: Integer);
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  TexCoord: TTextureCoordinateNode;
  App: TAppearanceNode;
  Tex: TImageTextureNode;
  TexProps: TTexturePropertiesNode;
  Skin: String;
begin
  inherited Create;
  FModel := AModel;
  FTemp := TVector3List.Create;
  FLastA := -1;
  FAnim.First := 0;
  FAnim.Count := 1;
  FAnimLoop := True;
  FFps := 10;

  FCoord := TCoordinateNode.Create;
  FCoord.SetPoint(FModel.FFrames[0]);
  TexCoord := TTextureCoordinateNode.Create;
  TexCoord.SetPoint(FModel.FUVs);

  Geom := TIndexedTriangleSetNode.Create;
  Geom.Coord := FCoord;
  Geom.TexCoord := TexCoord;
  Geom.SetIndex(FModel.FIndices);
  { MD2 triangles are clockwise from the front, like BSP faces }
  Geom.Ccw := False;
  Geom.Solid := False;

  FMaterial := TUnlitMaterialNode.Create;
  FMaterial.EmissiveColor := Vector3(1, 1, 1);
  App := TAppearanceNode.Create;
  App.Material := FMaterial;
  FAppearance := App;
  FSkinIndex := SkinIndex;

  Skin := FModel.SkinId(SkinIndex);
  if Skin <> '' then
  begin
    TexProps := TTexturePropertiesNode.Create;
    TexProps.MagnificationFilter := magNearest;
    TexProps.MinificationFilter := minNearestMipmapLinear;
    Tex := TImageTextureNode.Create;
    FTexture := Tex;
    Tex.SetUrl(['quaketex:/' + Skin]);
    Tex.TextureProperties := TexProps;
    App.Texture := Tex;
    { Skins may use index 255 for holes }
    App.AlphaMode := amMask;
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geom;
  Shape.Appearance := App;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);

  Scene := TCastleScene.Create(nil);
  Scene.Load(Root, True);
end;

destructor TQuakeMd2Instance.Destroy;
begin
  FTemp.Free;
  { Freeing the scene also removes it from its parent transform }
  FreeAndNil(Scene);
  inherited Destroy;
end;

function TQuakeMd2Instance.PlayAnim(const Names: String; const Loop: Boolean; const Fps: Single): Boolean;
begin
  Result := FModel.FindAnim(Names, FAnim);
  FAnimLoop := Loop;
  FAnimTime := 0;
  FAnimDone := False;
  FFps := Fps;
  Update(0);
end;

procedure TQuakeMd2Instance.Update(const SecondsPassed: Single);
var
  Pos: Single;
  A, B: Integer;
  T: Single;
begin
  FAnimTime := FAnimTime + SecondsPassed;
  Pos := FAnimTime * FFps;
  if FAnimLoop then
  begin
    Pos := FloatModulo(Pos, FAnim.Count);
    A := Trunc(Pos);
    B := (A + 1) mod FAnim.Count;
    T := Frac(Pos);
  end else
  begin
    if Pos >= FAnim.Count - 1 then
    begin
      Pos := FAnim.Count - 1;
      FAnimDone := True;
    end;
    A := Trunc(Pos);
    B := Min(A + 1, FAnim.Count - 1);
    T := Pos - A;
  end;
  A := FAnim.First + A;
  B := FAnim.First + B;
  if (A = FLastA) and (B = FLastB) and SameValue(T, FLastT, 0.01) then
    Exit;
  FLastA := A;
  FLastB := B;
  FLastT := T;
  FModel.LerpFrames(A, B, T, FTemp);
  FCoord.SetPoint(FTemp);
end;

function TQuakeMd2Instance.AnimProgress: Single;
begin
  if FAnim.Count <= 1 then
    Exit(1);
  Result := Min(1, FAnimTime * FFps / (FAnim.Count - 1));
end;

procedure TQuakeMd2Instance.SetFrame(const Index: Integer);
begin
  FAnim.First := EnsureRange(Index, 0, FModel.FrameCount - 1);
  FAnim.Count := 1;
  FAnimTime := 0;
  Update(0);
end;

procedure TQuakeMd2Instance.SetSkin(const SkinIndex: Integer);
var
  Skin: String;
begin
  if (SkinIndex = FSkinIndex) or (FTexture = nil) then
    Exit;
  FSkinIndex := SkinIndex;
  Skin := FModel.SkinId(SkinIndex);
  if Skin <> '' then
    FTexture.SetUrl(['quaketex:/' + Skin]);
end;

procedure TQuakeMd2Instance.SetTransparency(const Value: Single);
begin
  FMaterial.Transparency := Value;
  if Value > 0 then
    FAppearance.AlphaMode := amBlend;
end;

procedure TQuakeMd2Instance.SetTint(const Color: TVector3);
begin
  if not TVector3.Equals(FMaterial.EmissiveColor, Color, 0.02) then
    FMaterial.EmissiveColor := Color;
end;

{ TQuakeMd2Manager }

constructor TQuakeMd2Manager.Create;
begin
  inherited Create;
  FCache := specialize TObjectDictionary<String, TQuakeMd2>.Create([doOwnsValues]);
end;

destructor TQuakeMd2Manager.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

function TQuakeMd2Manager.GetModel(const APath: String): TQuakeMd2;
var
  Key: String;
  Data: Pointer;
  Size: Cardinal;
begin
  Key := LowerCase(APath);
  if FCache.TryGetValue(Key, Result) then
    Exit;

  Result := nil;
  Data := Pak.GetData(Key, Size);
  if Data = nil then
    WritelnWarning('QuakeMd2', 'Model "%s" not found in PAK', [Key])
  else
  begin
    Result := TQuakeMd2.Create(Key);
    if Result.LoadFromData(Data, Size) then
      WritelnLog('QuakeMd2', 'Loaded model "%s": %d frames', [Key, Result.FrameCount])
    else
      FreeAndNil(Result);
  end;
  { Cache failures too (as nil) so we don't retry every spawn }
  FCache.Add(Key, Result);
end;

function TQuakeMd2Manager.CreateInstance(const APath: String; const SkinIndex: Integer): TQuakeMd2Instance;
var
  Mdl: TQuakeMd2;
begin
  Mdl := GetModel(APath);
  if Mdl = nil then
    Exit(nil);
  Result := TQuakeMd2Instance.Create(Mdl, SkinIndex);
end;

initialization
  Md2Manager := TQuakeMd2Manager.Create;

finalization
  FreeAndNil(Md2Manager);
end.
