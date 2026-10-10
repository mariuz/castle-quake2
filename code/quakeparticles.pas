{ Particle effects and impact visuals for Castle Quake 2. }
unit QuakeParticles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleColors, CastleUtils, X3DNodes,
  CastleImages, CastleRenderOptions,
  QuakePalette, QuakeMd2;

type
  { Particle type kinds }
  TParticleKind = (pkSparks, pkSmoke, pkBlood, pkFireball, pkTeleport, pkTrail);

  { Single active particle in the world }
  TQuakeParticle = class
  public
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Material: TUnlitMaterialNode;
    Velocity: TVector3;
    Kind: TParticleKind;
    Life: Single;
    MaxLife: Single;
    StartScale: Single;
    EndScale: Single;
    Gravity: Single;
    constructor Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
      const AKind: TParticleKind; const ALife, AStartScale, AEndScale: Single;
      const ColorTint: TVector3);
    destructor Destroy; override;
    function Update(const SecondsPassed: Single): Boolean; { returns False when expired }
  end;

  TQuakeParticleList = specialize TObjectList<TQuakeParticle>;

  { Animated explosion model (models/objects/r_explode), removed when done }
  TQuakeExplosionModel = class
  public
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Life: Single;
    constructor Create(const Parent: TCastleTransform; const Pos: TVector3);
    destructor Destroy; override;
  end;

  TQuakeExplosionModelList = specialize TObjectList<TQuakeExplosionModel>;

  { Particle effects manager }
  TQuakeParticleManager = class
  private
    FParticles: TQuakeParticleList;
    FExplosions: TQuakeExplosionModelList;
    FParent: TCastleTransform;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetParent(const AParent: TCastleTransform);
    procedure Update(const SecondsPassed: Single);
    procedure Clear;

    { Spawn bullet impact sparks and smoke }
    procedure SpawnImpact(const Pos, Normal: TVector3);

    { Spawn blood burst when enemy is shot }
    procedure SpawnBlood(const Pos, Normal: TVector3);

    { Spawn rocket explosion fireball and sparks }
    procedure SpawnExplosion(const Pos: TVector3);

    { Spawn teleport particle fountain }
    procedure SpawnTeleport(const Pos: TVector3);

    { target_splash: Kind 1 sparks, 2 blue water, 3 brown water, 4 slime, 5 lava, 6 blood }
    procedure SpawnSplash(const Pos, Dir: TVector3; const Kind, Count: Integer);

    { Railgun: blue spiral + white core between two points }
    procedure SpawnRailTrail(const FromPos, ToPos: TVector3);

    { Blaster bolt impact (yellow sparks) }
    procedure SpawnBlasterImpact(const Pos, Normal: TVector3);

    { Large green BFG explosion }
    procedure SpawnBfgExplosion(const Pos: TVector3);
  end;

var
  Particles: TQuakeParticleManager;

implementation

{ Generate (once) a white disc with smooth alpha falloff, cached for quaketex: }
function SoftDotTexture: String;
const
  Size = 32;
var
  Img: TRGBAlphaImage;
  X, Y: Integer;
  D, A: Single;
begin
  Result := 'fx/softdot';
  if Palette.HasCachedImage(Result) then
    Exit;
  Img := TRGBAlphaImage.Create(Size, Size);
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
    begin
      D := Sqrt(Sqr(X + 0.5 - Size / 2) + Sqr(Y + 0.5 - Size / 2)) / (Size / 2);
      A := Clamped(1 - D, 0, 1);
      PVector4Byte(Img.PixelPtr(X, Y))^ := Vector4Byte(255, 255, 255, Round(255 * Sqrt(A)));
    end;
  Palette.CacheImage(Result, Img);
end;

{ TQuakeExplosionModel }

constructor TQuakeExplosionModel.Create(const Parent: TCastleTransform; const Pos: TVector3);
begin
  inherited Create;
  Transform := TCastleTransform.Create(nil);
  Transform.Name := 'Explosion';
  Transform.Translation := Pos;
  Transform.Rotation := Vector4(0, 1, 0, Random * 2 * Pi);
  Model := Md2Manager.CreateInstance('models/objects/r_explode/tris.md2');
  if Model <> nil then
  begin
    Model.Scene.Collides := False;
    Model.Scene.Pickable := False;
    { Fullbright, like Quake 2's RF_FULLBRIGHT explosions }
    Model.SetTint(Vector3(1, 1, 1));
    Model.SetTransparency(0.25);
    { Quake 2 rocket explosions play the "explode" or "explodb" sequence }
    if Random(2) = 0 then
      Model.PlayAnim('explode', False, 10)
    else
      Model.PlayAnim('explodb', False, 10);
    Transform.Add(Model.Scene);
  end;
  Life := 1.6;
  Parent.Add(Transform);
end;

destructor TQuakeExplosionModel.Destroy;
begin
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
end;

constructor TQuakeParticle.Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
  const AKind: TParticleKind; const ALife, AStartScale, AEndScale: Single;
  const ColorTint: TVector3);
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  Coord: TCoordinateNode;
  App: TAppearanceNode;
  Billboard: TBillboardNode;
  TexCoord: TTextureCoordinateNode;
  Tex: TImageTextureNode;
  CoordsList: TVector3List;
  IndicesList: TInt32List;
  HalfS: Single;
begin
  inherited Create;
  Kind := AKind;
  Velocity := Vel;
  Life := ALife;
  MaxLife := ALife;
  StartScale := AStartScale;
  EndScale := AEndScale;

  if (AKind = pkSparks) or (AKind = pkBlood) then
    Gravity := 400.0
  else
  if AKind = pkTrail then
    Gravity := 0
  else
    Gravity := -50.0; { Smoke and fire rise }

  Transform := TCastleTransform.Create(nil);
  Transform.Translation := Pos;
  Transform.Scale := Vector3(AStartScale, AStartScale, AStartScale);

  Scene := TCastleScene.Create(nil);
  Scene.PreciseCollisions := False;
  Scene.Collides := False;

  Root := TX3DRootNode.Create;
  Shape := TShapeNode.Create;

  { Simple camera-facing billboard quad }
  HalfS := 1.0;
  CoordsList := TVector3List.Create;
  CoordsList.Add(Vector3(-HalfS, -HalfS, 0));
  CoordsList.Add(Vector3( HalfS, -HalfS, 0));
  CoordsList.Add(Vector3( HalfS,  HalfS, 0));
  CoordsList.Add(Vector3(-HalfS,  HalfS, 0));

  Coord := TCoordinateNode.Create;
  Coord.SetPoint(CoordsList);
  CoordsList.Free;

  IndicesList := TInt32List.Create;
  IndicesList.Add(0); IndicesList.Add(1); IndicesList.Add(2);
  IndicesList.Add(0); IndicesList.Add(2); IndicesList.Add(3);

  Geom := TIndexedTriangleSetNode.Create;
  Geom.Coord := Coord;
  TexCoord := TTextureCoordinateNode.Create;
  TexCoord.SetPoint([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]);
  Geom.TexCoord := TexCoord;
  Geom.SetIndex(IndicesList);
  IndicesList.Free;
  Geom.Solid := False;

  App := TAppearanceNode.Create;
  Material := TUnlitMaterialNode.Create;
  Material.EmissiveColor := ColorTint;
  Material.Transparency := 0.1;
  App.Material := Material;
  App.AlphaMode := amBlend;
  { Soft round dot instead of a hard square }
  Tex := TImageTextureNode.Create;
  Tex.SetUrl(['quaketex:/' + SoftDotTexture]);
  App.Texture := Tex;

  Shape.Geometry := Geom;
  Shape.Appearance := App;
  { Always face the camera }
  Billboard := TBillboardNode.Create;
  Billboard.AxisOfRotation := Vector3(0, 0, 0);
  Billboard.AddChildren(Shape);
  Root.AddChildren(Billboard);

  Scene.Load(Root, True);
  { Billboards are oriented to the camera only when processing events }
  Scene.ProcessEvents := True;
  Scene.Pickable := False;
  Transform.Add(Scene);
  Parent.Add(Transform);
end;

destructor TQuakeParticle.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

function TQuakeParticle.Update(const SecondsPassed: Single): Boolean;
var
  Fraction, CurScale: Single;
begin
  Life := Life - SecondsPassed;
  if Life <= 0 then
    Exit(False);

  { Update physics }
  Velocity.Y := Velocity.Y - Gravity * SecondsPassed;
  Transform.Translation := Transform.Translation + Velocity * SecondsPassed;

  { Update scale and fade }
  Fraction := 1.0 - (Life / MaxLife);
  CurScale := StartScale + (EndScale - StartScale) * Fraction;
  Transform.Scale := Vector3(CurScale, CurScale, CurScale);

  if Material <> nil then
    Material.Transparency := 0.1 + Fraction * 0.9;

  Result := True;
end;

{ TQuakeParticleManager }

constructor TQuakeParticleManager.Create;
begin
  inherited Create;
  FParticles := TQuakeParticleList.Create(True);
  FExplosions := TQuakeExplosionModelList.Create(True);
  FParent := nil;
end;

destructor TQuakeParticleManager.Destroy;
begin
  FParticles.Free;
  FExplosions.Free;
  inherited Destroy;
end;

procedure TQuakeParticleManager.SetParent(const AParent: TCastleTransform);
begin
  Clear;
  FParent := AParent;
end;

procedure TQuakeParticleManager.Clear;
begin
  FParticles.Clear;
  FExplosions.Clear;
end;

procedure TQuakeParticleManager.Update(const SecondsPassed: Single);
var
  I: Integer;
begin
  for I := FParticles.Count - 1 downto 0 do
  begin
    if not FParticles[I].Update(SecondsPassed) then
      FParticles.Delete(I);
  end;
  for I := FExplosions.Count - 1 downto 0 do
  begin
    FExplosions[I].Life := FExplosions[I].Life - SecondsPassed;
    if FExplosions[I].Model <> nil then
    begin
      FExplosions[I].Model.Update(SecondsPassed);
      { Quake 2 darkens the explosion by stepping through its 7 skins (2 frames each) }
      FExplosions[I].Model.SetSkin(Min(6, Trunc((1.6 - FExplosions[I].Life) * 10) div 2));
    end;
    if (FExplosions[I].Life <= 0) or (FExplosions[I].Model = nil) or FExplosions[I].Model.AnimDone then
      FExplosions.Delete(I);
  end;
end;

procedure TQuakeParticleManager.SpawnImpact(const Pos, Normal: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;

  { Sparks bouncing away from surface }
  for I := 1 to 6 do
  begin
    Vel := Normal * (100.0 + Random * 120.0) +
      Vector3((Random - 0.5) * 100.0, (Random - 0.5) * 100.0, (Random - 0.5) * 100.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkSparks, 0.3 + Random * 0.2, 1.5, 0.5,
      Vector3(1.0, 0.85, 0.3));
    FParticles.Add(P);
  end;

  { Smoke puff }
  Vel := Normal * 20.0 + Vector3(0, 30.0, 0);
  P := TQuakeParticle.Create(FParent, Pos, Vel, pkSmoke, 0.5, 2.0, 8.0,
    Vector3(0.5, 0.5, 0.5));
  FParticles.Add(P);
end;

procedure TQuakeParticleManager.SpawnBlood(const Pos, Normal: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;

  for I := 1 to 8 do
  begin
    Vel := Normal * (60.0 + Random * 80.0) +
      Vector3((Random - 0.5) * 80.0, (Random - 0.5) * 80.0, (Random - 0.5) * 80.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkBlood, 0.4 + Random * 0.3, 2.0, 0.8,
      Vector3(0.75, 0.05, 0.05));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnExplosion(const Pos: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;

  { Quake 2's animated explosion model; a fireball particle if it's missing }
  FExplosions.Add(TQuakeExplosionModel.Create(FParent, Pos));
  if FExplosions.Last.Model = nil then
  begin
    P := TQuakeParticle.Create(FParent, Pos, Vector3(0, 20.0, 0), pkFireball, 0.4, 6.0, 24.0,
      Vector3(1.0, 0.5, 0.1));
    FParticles.Add(P);
  end;

  { Flying fiery debris }
  for I := 1 to 10 do
  begin
    Vel := Vector3((Random - 0.5) * 300.0, (Random * 200.0 + 50.0), (Random - 0.5) * 300.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkSparks, 0.6 + Random * 0.4, 3.0, 0.5,
      Vector3(1.0, 0.6, 0.1));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnTeleport(const Pos: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;

  for I := 1 to 20 do
  begin
    Vel := Vector3((Random - 0.5) * 80.0, Random * 250.0 + 80.0, (Random - 0.5) * 80.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkTeleport, 0.8 + Random * 0.4, 2.5, 0.5,
      Vector3(0.2, 0.9, 0.95));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnSplash(const Pos, Dir: TVector3; const Kind, Count: Integer);
var
  I: Integer;
  Col: TVector3;
  P: TQuakeParticle;
  PKind: TParticleKind;
begin
  if FParent = nil then
    Exit;
  case Kind of
    1: Col := Vector3(1.0, 0.85, 0.3);
    2: Col := Vector3(0.3, 0.45, 0.9);
    3: Col := Vector3(0.45, 0.35, 0.2);
    4: Col := Vector3(0.3, 0.8, 0.2);
    5: Col := Vector3(1.0, 0.4, 0.05);
    6: Col := Vector3(0.7, 0.05, 0.05);
    else Col := Vector3(0.8, 0.8, 0.8);
  end;
  if Kind = 1 then
    PKind := pkSparks
  else
    PKind := pkBlood;
  { Fewer, bigger particles than Quake 2 (each one is a scene here) }
  for I := 1 to Max(4, Min(Count, 32) div 3) do
  begin
    P := TQuakeParticle.Create(FParent, Pos, Dir * (80 + Random * 120) +
      Vector3((Random - 0.5) * 120, (Random - 0.5) * 120, (Random - 0.5) * 120),
      PKind, 0.4 + Random * 0.4, 1.0, 0.3, Col);
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnRailTrail(const FromPos, ToPos: TVector3);
var
  Dir, Side, Up, Offset: TVector3;
  Len, D, A: Single;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;
  Dir := ToPos - FromPos;
  Len := Dir.Length;
  if Len < 1 then
    Exit;
  Dir := Dir / Len;
  Side := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Side.Length < 0.01 then
    Side := Vector3(1, 0, 0);
  Side := Side.Normalize;
  Up := TVector3.CrossProduct(Side, Dir);
  D := 8;
  while D < Len do
  begin
    A := D * 0.1;
    Offset := (Side * Cos(A) + Up * Sin(A)) * 3;
    P := TQuakeParticle.Create(FParent, FromPos + Dir * D + Offset, Offset * 2, pkTrail,
      0.8, 0.9, 0.3, Vector3(0.3, 0.5, 1.0));
    FParticles.Add(P);
    if Round(D) mod 24 < 8 then
    begin
      P := TQuakeParticle.Create(FParent, FromPos + Dir * D, Vector3(0, 0, 0), pkTrail,
        0.6, 0.7, 0.2, Vector3(0.9, 0.9, 1.0));
      FParticles.Add(P);
    end;
    D := D + 8;
  end;
end;

procedure TQuakeParticleManager.SpawnBlasterImpact(const Pos, Normal: TVector3);
var
  I: Integer;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;
  for I := 1 to 8 do
  begin
    P := TQuakeParticle.Create(FParent, Pos, Normal * (60 + Random * 80) +
      Vector3((Random - 0.5) * 120, (Random - 0.5) * 120, (Random - 0.5) * 120),
      pkSparks, 0.3 + Random * 0.2, 1.5, 0.4, Vector3(1.0, 0.9, 0.2));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnBfgExplosion(const Pos: TVector3);
var
  I: Integer;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;
  P := TQuakeParticle.Create(FParent, Pos, Vector3(0, 0, 0), pkFireball, 0.6, 10, 60,
    Vector3(0.3, 1.0, 0.3));
  FParticles.Add(P);
  for I := 1 to 30 do
  begin
    P := TQuakeParticle.Create(FParent, Pos, Vector3((Random - 0.5) * 500,
      (Random - 0.5) * 500, (Random - 0.5) * 500), pkTrail, 0.8 + Random * 0.4, 3, 0.5,
      Vector3(0.4, 1.0, 0.4));
    FParticles.Add(P);
  end;
end;

initialization
  Particles := TQuakeParticleManager.Create;

finalization
  FreeAndNil(Particles);
end.
