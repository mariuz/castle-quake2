{ Quake 2 SP2 sprites (IDS2 version 2): camera-facing animated quads,
  used for the BFG ball and its explosion. }
unit QuakeSprite;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleTransform, CastleScene, X3DNodes, CastleLog, CastleRenderOptions,
  QuakePak, QuakePalette;

type
  TSp2Frame = record
    Width, Height, OriginX, OriginY: Integer;
    TextureId: String; { quaketex: id of the frame's PCX }
  end;

  { Loaded SP2 sprite }
  TQuakeSprite = class
  public
    Frames: array of TSp2Frame;
    function LoadFromPak(const APath: String): Boolean;
  end;

  { A placed sprite: a billboard quad with the current frame's texture }
  TQuakeSpriteInstance = class
  private
    FSprite: TQuakeSprite;
    FCoord: TCoordinateNode;
    FTexture: TImageTextureNode;
    FMaterial: TUnlitMaterialNode;
    FFrame: Integer;
    FTime: Single;
    FFps: Single;
    procedure ShowFrame(const Index: Integer);
  public
    Scene: TCastleScene;
    constructor Create(const ASprite: TQuakeSprite; const Fps: Single = 10);
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single);
    { 0 = opaque .. 1 = invisible }
    procedure SetTransparency(const Value: Single);
    function FrameCount: Integer;
    { Frames shown since creation }
    property Time: Single read FTime;
  end;

  TQuakeSpriteManager = class
  private
    FCache: specialize TObjectDictionary<String, TQuakeSprite>;
  public
    constructor Create;
    destructor Destroy; override;
    { nil when the sprite is missing }
    function CreateInstance(const APath: String; const Fps: Single = 10): TQuakeSpriteInstance;
  end;

var
  SpriteManager: TQuakeSpriteManager;

implementation

type
  TSp2Header = packed record
    Ident: array[0..3] of AnsiChar; { 'IDS2' }
    Version: LongInt;               { 2 }
    NumFrames: LongInt;
  end;

  TSp2FrameRaw = packed record
    Width, Height: LongInt;
    OriginX, OriginY: LongInt;
    Name: array[0..63] of AnsiChar;
  end;

{ TQuakeSprite }

function TQuakeSprite.LoadFromPak(const APath: String): Boolean;
var
  Data: PByte;
  Size: Cardinal;
  Hdr: ^TSp2Header;
  Raw: ^TSp2FrameRaw;
  I: Integer;
begin
  Result := False;
  Data := Pak.GetData(APath, Size);
  if (Data = nil) or (Size < SizeOf(TSp2Header)) then
    Exit;
  Hdr := Pointer(Data);
  if (Hdr^.Ident[0] <> 'I') or (Hdr^.Ident[1] <> 'D') or (Hdr^.Ident[2] <> 'S') or
     (Hdr^.Ident[3] <> '2') or (Hdr^.Version <> 2) or
     (SizeOf(TSp2Header) + Hdr^.NumFrames * SizeOf(TSp2FrameRaw) > Size) then
    Exit;
  SetLength(Frames, Hdr^.NumFrames);
  Raw := Pointer(Data + SizeOf(TSp2Header));
  for I := 0 to Hdr^.NumFrames - 1 do
  begin
    Frames[I].Width := Raw[I].Width;
    Frames[I].Height := Raw[I].Height;
    Frames[I].OriginX := Raw[I].OriginX;
    Frames[I].OriginY := Raw[I].OriginY;
    Frames[I].TextureId := LowerCase(Trim(PAnsiChar(@Raw[I].Name[0])));
    Palette.LoadPcx(Frames[I].TextureId, True);
  end;
  Result := Length(Frames) > 0;
end;

{ TQuakeSpriteInstance }

constructor TQuakeSpriteInstance.Create(const ASprite: TQuakeSprite; const Fps: Single);
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  TexCoord: TTextureCoordinateNode;
  App: TAppearanceNode;
  Billboard: TBillboardNode;
begin
  inherited Create;
  FSprite := ASprite;
  FFps := Fps;
  FFrame := -1;

  FCoord := TCoordinateNode.Create;
  TexCoord := TTextureCoordinateNode.Create;
  TexCoord.SetPoint([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]);
  Geom := TIndexedTriangleSetNode.Create;
  Geom.Coord := FCoord;
  Geom.TexCoord := TexCoord;
  Geom.SetIndex([0, 1, 2, 0, 2, 3]);
  Geom.Solid := False;

  FMaterial := TUnlitMaterialNode.Create;
  FTexture := TImageTextureNode.Create;
  App := TAppearanceNode.Create;
  App.Material := FMaterial;
  App.Texture := FTexture;
  App.AlphaMode := amBlend;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geom;
  Shape.Appearance := App;
  { Screen-aligned, like Quake 2 sprites }
  Billboard := TBillboardNode.Create;
  Billboard.AxisOfRotation := TVector3.Zero;
  Billboard.AddChildren(Shape);
  Root := TX3DRootNode.Create;
  Root.AddChildren(Billboard);

  ShowFrame(0);
  Scene := TCastleScene.Create(nil);
  Scene.Load(Root, True);
  Scene.ProcessEvents := True; { billboards need it }
  Scene.Collides := False;
  Scene.Pickable := False;
end;

destructor TQuakeSpriteInstance.Destroy;
begin
  FreeAndNil(Scene);
  inherited Destroy;
end;

function TQuakeSpriteInstance.FrameCount: Integer;
begin
  Result := Length(FSprite.Frames);
end;

procedure TQuakeSpriteInstance.ShowFrame(const Index: Integer);
var
  F: TSp2Frame;
  L, R, B, T: Single;
begin
  if (Index = FFrame) or (Length(FSprite.Frames) = 0) then
    Exit;
  FFrame := Index;
  F := FSprite.Frames[Index];
  { Quake 2: origin is the pixel at the sprite's position, y grows downwards }
  L := -F.OriginX;
  R := F.Width - F.OriginX;
  T := F.OriginY;
  B := F.OriginY - F.Height;
  FCoord.SetPoint([Vector3(L, B, 0), Vector3(R, B, 0), Vector3(R, T, 0), Vector3(L, T, 0)]);
  FTexture.SetUrl(['quaketex:/' + F.TextureId]);
end;

procedure TQuakeSpriteInstance.Update(const SecondsPassed: Single);
begin
  FTime := FTime + SecondsPassed;
  if Length(FSprite.Frames) > 0 then
    ShowFrame(Trunc(FTime * FFps) mod Length(FSprite.Frames));
end;

procedure TQuakeSpriteInstance.SetTransparency(const Value: Single);
begin
  FMaterial.Transparency := Value;
end;

{ TQuakeSpriteManager }

constructor TQuakeSpriteManager.Create;
begin
  inherited Create;
  FCache := specialize TObjectDictionary<String, TQuakeSprite>.Create([doOwnsValues]);
end;

destructor TQuakeSpriteManager.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

function TQuakeSpriteManager.CreateInstance(const APath: String; const Fps: Single): TQuakeSpriteInstance;
var
  Key: String;
  Sprite: TQuakeSprite;
begin
  Key := LowerCase(APath);
  if not FCache.TryGetValue(Key, Sprite) then
  begin
    Sprite := TQuakeSprite.Create;
    if not Sprite.LoadFromPak(Key) then
    begin
      WritelnWarning('QuakeSprite', 'Sprite "%s" missing or invalid', [Key]);
      FreeAndNil(Sprite);
    end;
    FCache.Add(Key, Sprite);
  end;
  if Sprite = nil then
    Exit(nil);
  Result := TQuakeSpriteInstance.Create(Sprite, Fps);
end;

initialization
  SpriteManager := TQuakeSpriteManager.Create;

finalization
  FreeAndNil(SpriteManager);
end.
