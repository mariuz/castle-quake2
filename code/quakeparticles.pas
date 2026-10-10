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

  { Single active particle: plain data, drawn by TQuakeParticleManager as one
    camera-facing quad in a single batched scene. }
  TQuakeParticle = class
  public
    Position: TVector3;
    Color: TVector3;
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
    function Update(const SecondsPassed: Single): Boolean; { returns False when expired }
    function CurrentScale: Single;
    function CurrentAlpha: Single;
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

  { Flying gib / debris model with gravity and simple floor bounce }
  TQuakeGib = class
  public
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Velocity, Spin: TVector3;
    Angle: Single;
    Life: Single;
    Resting: Boolean;
    constructor Create(const Parent: TCastleTransform; const ModelPath: String;
      const Pos, Vel: TVector3);
    destructor Destroy; override;
  end;

  TQuakeGibList = specialize TObjectList<TQuakeGib>;

  { Particle effects manager }
  TQuakeParticleManager = class
  private
    FParticles: TQuakeParticleList;
    FExplosions: TQuakeExplosionModelList;
    FGibs: TQuakeGibList;
    FParent: TCastleTransform;
    FCamera: TCastleTransform;
    { All particles are quads in one shape of one scene }
    FBatchScene: TCastleScene;
    FBatchCoord: TCoordinateNode;
    FBatchTexCoord: TTextureCoordinateNode;
    FBatchColor: TColorRGBANode;
    FBatchGeometry: TIndexedTriangleSetNode;
    FCoords: TVector3List;
    FTexCoords: TVector2List;
    FColors: TVector4List;
    FIndices: TInt32List;
    procedure CreateBatchScene;
    procedure RebuildBatch;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetParent(const AParent: TCastleTransform);
    { Camera the particle quads face (set by the view) }
    property Camera: TCastleTransform read FCamera write FCamera;
    procedure UpdateGibs(const SecondsPassed: Single);
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

    { Monster gibbed: flying meat, bones and a head, plus blood }
    procedure SpawnGibs(const Pos: TVector3);

    { Barrel / brush debris }
    procedure SpawnDebris(const Pos: TVector3);

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

{ TQuakeGib }

constructor TQuakeGib.Create(const Parent: TCastleTransform; const ModelPath: String;
  const Pos, Vel: TVector3);
begin
  inherited Create;
  Transform := TCastleTransform.Create(nil);
  Transform.Name := 'Gib';
  Transform.Translation := Pos;
  Velocity := Vel;
  Spin := Vector3(Random - 0.5, Random - 0.5, Random - 0.5).Normalize;
  Life := 8 + Random * 4;
  Model := Md2Manager.CreateInstance(ModelPath);
  if Model <> nil then
  begin
    Model.Scene.Collides := False;
    Model.Scene.Pickable := False;
    Model.SetTint(Vector3(0.8, 0.8, 0.8));
    Transform.Add(Model.Scene);
  end;
  Parent.Add(Transform);
end;

destructor TQuakeGib.Destroy;
begin
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
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
begin
  inherited Create;
  Kind := AKind;
  Position := Pos;
  Velocity := Vel;
  Color := ColorTint;
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
end;

function TQuakeParticle.Update(const SecondsPassed: Single): Boolean;
begin
  Life := Life - SecondsPassed;
  if Life <= 0 then
    Exit(False);
  Velocity.Y := Velocity.Y - Gravity * SecondsPassed;
  Position := Position + Velocity * SecondsPassed;
  Result := True;
end;

function TQuakeParticle.CurrentScale: Single;
begin
  Result := StartScale + (EndScale - StartScale) * (1 - Life / MaxLife);
end;

function TQuakeParticle.CurrentAlpha: Single;
begin
  Result := 0.9 * (Life / MaxLife);
end;

{ TQuakeParticleManager }

constructor TQuakeParticleManager.Create;
begin
  inherited Create;
  FParticles := TQuakeParticleList.Create(True);
  FExplosions := TQuakeExplosionModelList.Create(True);
  FGibs := TQuakeGibList.Create(True);
  FParent := nil;
  FCoords := TVector3List.Create;
  FTexCoords := TVector2List.Create;
  FColors := TVector4List.Create;
  FIndices := TInt32List.Create;
end;

destructor TQuakeParticleManager.Destroy;
begin
  FParticles.Free;
  FExplosions.Free;
  FGibs.Free;
  FreeAndNil(FBatchScene);
  FCoords.Free;
  FTexCoords.Free;
  FColors.Free;
  FIndices.Free;
  inherited Destroy;
end;

procedure TQuakeParticleManager.SetParent(const AParent: TCastleTransform);
begin
  Clear;
  FreeAndNil(FBatchScene);
  FParent := AParent;
  if FParent <> nil then
    CreateBatchScene;
end;

procedure TQuakeParticleManager.CreateBatchScene;
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TImageTextureNode;
begin
  FBatchCoord := TCoordinateNode.Create;
  FBatchTexCoord := TTextureCoordinateNode.Create;
  FBatchColor := TColorRGBANode.Create;
  FBatchGeometry := TIndexedTriangleSetNode.Create;
  FBatchGeometry.Coord := FBatchCoord;
  FBatchGeometry.TexCoord := FBatchTexCoord;
  FBatchGeometry.Color := FBatchColor;
  FBatchGeometry.Solid := False;

  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1, 1, 1);
  App := TAppearanceNode.Create;
  App.Material := Mat;
  App.AlphaMode := amBlend;
  { Soft round dot, multiplied by the per-vertex colour and alpha }
  Tex := TImageTextureNode.Create;
  Tex.SetUrl(['quaketex:/' + SoftDotTexture]);
  App.Texture := Tex;

  Shape := TShapeNode.Create;
  Shape.Geometry := FBatchGeometry;
  Shape.Appearance := App;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);

  FBatchScene := TCastleScene.Create(nil);
  FBatchScene.Name := 'Particles';
  FBatchScene.Load(Root, True);
  FBatchScene.Collides := False;
  FBatchScene.Pickable := False;
  FParent.Add(FBatchScene);
end;

procedure TQuakeParticleManager.RebuildBatch;
var
  I, Base: Integer;
  P: TQuakeParticle;
  Right, Up, R, U: TVector3;
  Size, Alpha: Single;
begin
  if FBatchScene = nil then
    Exit;
  if FCamera <> nil then
  begin
    Up := FCamera.Up;
    Right := TVector3.CrossProduct(FCamera.Direction, Up).Normalize;
    Up := TVector3.CrossProduct(Right, FCamera.Direction).Normalize;
  end else
  begin
    Right := Vector3(1, 0, 0);
    Up := Vector3(0, 1, 0);
  end;

  FCoords.Count := FParticles.Count * 4;
  FTexCoords.Count := FParticles.Count * 4;
  FColors.Count := FParticles.Count * 4;
  FIndices.Count := FParticles.Count * 6;
  for I := 0 to FParticles.Count - 1 do
  begin
    P := FParticles[I];
    Size := P.CurrentScale;
    Alpha := P.CurrentAlpha;
    R := Right * Size;
    U := Up * Size;
    Base := I * 4;
    FCoords.L[Base] := P.Position - R - U;
    FCoords.L[Base + 1] := P.Position + R - U;
    FCoords.L[Base + 2] := P.Position + R + U;
    FCoords.L[Base + 3] := P.Position - R + U;
    FTexCoords.L[Base] := Vector2(0, 0);
    FTexCoords.L[Base + 1] := Vector2(1, 0);
    FTexCoords.L[Base + 2] := Vector2(1, 1);
    FTexCoords.L[Base + 3] := Vector2(0, 1);
    FColors.L[Base] := Vector4(P.Color, Alpha);
    FColors.L[Base + 1] := FColors.L[Base];
    FColors.L[Base + 2] := FColors.L[Base];
    FColors.L[Base + 3] := FColors.L[Base];
    FIndices.L[I * 6] := Base;
    FIndices.L[I * 6 + 1] := Base + 1;
    FIndices.L[I * 6 + 2] := Base + 2;
    FIndices.L[I * 6 + 3] := Base;
    FIndices.L[I * 6 + 4] := Base + 2;
    FIndices.L[I * 6 + 5] := Base + 3;
  end;
  FBatchCoord.SetPoint(FCoords);
  FBatchTexCoord.SetPoint(FTexCoords);
  FBatchColor.SetColor(FColors);
  FBatchGeometry.SetIndex(FIndices);
  FBatchScene.Exists := FParticles.Count > 0;
end;

procedure TQuakeParticleManager.Clear;
begin
  FParticles.Clear;
  FExplosions.Clear;
  FGibs.Clear;
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
  RebuildBatch;
  UpdateGibs(SecondsPassed);
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

procedure TQuakeParticleManager.UpdateGibs(const SecondsPassed: Single);
var
  I: Integer;
  G: TQuakeGib;
  Dist: Single;
  NewPos: TVector3;
  Hit: TCastleTransform;
begin
  for I := FGibs.Count - 1 downto 0 do
  begin
    G := FGibs[I];
    G.Life := G.Life - SecondsPassed;
    if G.Life <= 0 then
    begin
      FGibs.Delete(I);
      Continue;
    end;
    if G.Resting then
      Continue;
    G.Velocity.Y := G.Velocity.Y - 800 * SecondsPassed;
    NewPos := G.Transform.Translation + G.Velocity * SecondsPassed;
    { Stop on the first surface below / ahead (ray cast along the motion) }
    if (G.Velocity.Length > 0.01) and (G.Transform.World <> nil) then
    begin
      Hit := G.Transform.World.WorldRayCast(G.Transform.Translation, G.Velocity.Normalize, Dist);
      if (Hit <> nil) and (Dist <= (G.Velocity * SecondsPassed).Length + 2) then
      begin
        if G.Velocity.Y < 0 then
        begin
          { Floor: bounce once, then rest }
          if Abs(G.Velocity.Y) > 150 then
            G.Velocity := Vector3(G.Velocity.X * 0.5, -G.Velocity.Y * 0.3, G.Velocity.Z * 0.5)
          else
            G.Resting := True;
        end else
          G.Velocity := Vector3(-G.Velocity.X * 0.3, G.Velocity.Y, -G.Velocity.Z * 0.3);
        Continue;
      end;
    end;
    G.Transform.Translation := NewPos;
    G.Angle := G.Angle + 6 * SecondsPassed;
    G.Transform.Rotation := Vector4(G.Spin, G.Angle);
  end;
end;

procedure TQuakeParticleManager.SpawnGibs(const Pos: TVector3);
const
  Gibs: array[0..5] of String = ('models/objects/gibs/sm_meat/tris.md2',
    'models/objects/gibs/sm_meat/tris.md2', 'models/objects/gibs/bone/tris.md2',
    'models/objects/gibs/sm_meat/tris.md2', 'models/objects/gibs/bone2/tris.md2',
    'models/objects/gibs/head2/tris.md2');
var
  I: Integer;
begin
  if FParent = nil then
    Exit;
  for I := 0 to High(Gibs) do
    FGibs.Add(TQuakeGib.Create(FParent, Gibs[I], Pos + Vector3(0, 8, 0),
      Vector3((Random - 0.5) * 400, 200 + Random * 300, (Random - 0.5) * 400)));
  SpawnBlood(Pos, Vector3(0, 1, 0));
  SpawnBlood(Pos + Vector3(0, 16, 0), Vector3(0, 1, 0));
end;

procedure TQuakeParticleManager.SpawnDebris(const Pos: TVector3);
const
  Debris: array[0..3] of String = ('models/objects/debris1/tris.md2',
    'models/objects/debris2/tris.md2', 'models/objects/debris3/tris.md2',
    'models/objects/debris2/tris.md2');
var
  I: Integer;
begin
  if FParent = nil then
    Exit;
  for I := 0 to High(Debris) do
    FGibs.Add(TQuakeGib.Create(FParent, Debris[I], Pos,
      Vector3((Random - 0.5) * 500, 250 + Random * 300, (Random - 0.5) * 500)));
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
