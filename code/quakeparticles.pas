{ Particle effects and impact visuals for Castle Quake 2. }
unit QuakeParticles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleColors, CastleUtils, X3DNodes;

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

  { Particle effects manager }
  TQuakeParticleManager = class
  private
    FParticles: TQuakeParticleList;
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
  Geom.SetIndex(IndicesList);
  IndicesList.Free;
  Geom.Solid := False;

  App := TAppearanceNode.Create;
  Material := TUnlitMaterialNode.Create;
  Material.EmissiveColor := ColorTint;
  Material.Transparency := 0.1;
  App.Material := Material;
  App.AlphaMode := amBlend;

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
  FParent := nil;
end;

destructor TQuakeParticleManager.Destroy;
begin
  FParticles.Free;
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

  { Central fireball expanding }
  P := TQuakeParticle.Create(FParent, Pos, Vector3(0, 20.0, 0), pkFireball, 0.4, 6.0, 24.0,
    Vector3(1.0, 0.5, 0.1));
  FParticles.Add(P);

  { Flying fiery debris }
  for I := 1 to 14 do
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
