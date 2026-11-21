{ Particle effects and impact visuals for Castle Quake 2. }
unit QuakeParticles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleColors, CastleUtils, X3DNodes,
  CastleImages, CastleRenderOptions, X3DFields,
  QuakePalette, QuakeMd2, QuakeSprite;

type
  { Particle type kinds }
  TParticleKind = (pkSparks, pkSmoke, pkBlood, pkFireball, pkTeleport, pkTrail);

  { Single active particle: plain data, drawn by TQuakeParticleManager as one
    camera-facing quad in a single batched scene. Position and Velocity are
    the ones at SpawnTime: the vertex shader moves it (PositionAt). }
  TQuakeParticle = class
  public
    Position: TVector3;
    Color: TVector3;
    Velocity: TVector3;
    { TQuakeParticleManager's clock when it was added }
    SpawnTime: Double;
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
    { Where the particle is Age seconds after it spawned (what the shader
      draws: velocity plus gravity on Y) }
    function PositionAt(const Age: Single): TVector3;
  end;

  TQuakeParticleList = specialize TObjectList<TQuakeParticle>;

  { Animated explosion model (models/objects/r_explode), removed when done }
  TQuakeExplosionModel = class
  public
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Sprite: TQuakeSpriteInstance;
    Life: Single;
    constructor Create(const Parent: TCastleTransform; const Pos: TVector3);
    { Sprite explosion (e.g. the BFG's sprites/s_bfg3.sp2), played once }
    constructor CreateSprite(const Parent: TCastleTransform; const Pos: TVector3;
      const SpritePath: String);
    destructor Destroy; override;
  end;

  TQuakeExplosionModelList = specialize TObjectList<TQuakeExplosionModel>;

  { One kind of piece a body breaks into (Quake 2 ThrowGib / ThrowHead) }
  TGibPiece = record
    Model: String;
    Count: Integer;
    { GIB_METALLIC: bounces (MOVETYPE_BOUNCE); organic ones stop on the
      floor with a splat (MOVETYPE_TOSS, gib_touch) }
    Metallic: Boolean;
  end;

  { Point trace for gibs against the map (CGE coordinates): True and the
    end position / plane normal when something solid is in the way }
  TGibTraceFunc = function(const Start, Stop: TVector3; out EndPos, Normal: TVector3): Boolean of object;

  { Flying gib / debris model with gravity, landing and bouncing }
  TQuakeGib = class
  public
    Transform: TCastleTransform;
    Model: TQuakeMd2Instance;
    Velocity, Spin: TVector3;
    Angle, SpinSpeed: Single;
    Life: Single;
    Resting: Boolean;
    Metallic: Boolean;
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
    { All particles are quads in one shape of one scene. The mesh holds each
      particle's spawn data and changes only when particles are added (or
      many expired); a vertex shader moves, sizes, fades and turns them to
      the camera from the time. }
    FBatchScene: TCastleScene;
    FBatchCoord: TCoordinateNode;
    FBatchTexCoord: TTextureCoordinateNode;
    FBatchColor: TColorRGBANode;
    FBatchMotion, FBatchLife, FBatchCorner: TFloatVertexAttributeNode;
    FBatchGeometry: TIndexedTriangleSetNode;
    FTimeField: TSFFloat;
    FRightField, FUpField: TSFVec3f;
    FCoords: TVector3List;
    FTexCoords: TVector2List;
    FColors: TVector4List;
    FMotion, FLifeData, FCorners: TSingleList;
    FIndices: TInt32List;
    { The particles' clock, and its value when the mesh was built (times in
      the mesh are relative to it, to keep them small) }
    FTime, FBatchBase: Double;
    { Particles in the mesh, those of them expired since, added since }
    FBatchCount, FBatchExpired: Integer;
    FBatchDirty: Boolean;
    FUploads: Int64;
    procedure CreateBatchScene;
    procedure RebuildBatch;
    procedure UpdateBatchUniforms;
    procedure AddParticle(const P: TQuakeParticle);
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
    { Quake 2 ThrowGib for each piece: from random points of the box
      (CGE coordinates), with VelocityForDamage / ClipGibVelocity, spinning,
      gone after 10 .. 20 s }
    procedure ThrowGibs(const BoxMin, BoxMax: TVector3; const Pieces: array of TGibPiece;
      const Damage: Integer);

    { Barrel / brush debris }
    procedure SpawnDebris(const Pos: TVector3);

    { Large green BFG explosion }
    procedure SpawnBfgExplosion(const Pos: TVector3);
    { TE_BFG_EXPLOSION: the translucent sprites/s_bfg2.sp2 on a target hit by
      the BFG effect }
    procedure SpawnBfgHit(const Pos: TVector3);
    { TE_BFG_LASER: a short green beam from the ball to a target }
    procedure SpawnBfgLaser(const FromPos, ToPos: TVector3);
    { A laser beam of this colour for 0.1 s (the laser soldier's: red) }
    procedure SpawnBeam(const FromPos, ToPos, Color: TVector3);
  public
    { Set by the world: gibs land on and bounce off the map's brushes
      (else render meshes are ray cast) }
    GibTrace: TGibTraceFunc;
  public
    { Gibs flying or lying around }
    function GibCount: Integer;
    { Live particles }
    function ParticleCount: Integer;
    { Times the particle mesh was sent to the GPU }
    property Uploads: Int64 read FUploads;
  end;

var
  Particles: TQuakeParticleManager;

{ Quake 2 VelocityForDamage + ClipGibVelocity in CGE coordinates (Y up);
  R1 .. R3 in 0..1 are the random numbers (pure, for the tests) }
function GibVelocity(const Damage: Integer; const R1, R2, R3: Single): TVector3;

implementation

uses
  QuakeSound;

function GibVelocity(const Damage: Integer; const R1, R2, R3: Single): TVector3;
var
  Scale: Single;
begin
  { 100 * crandom() sideways, 200 + 100 * random() up }
  Result := Vector3(100 * (R1 * 2 - 1), 200 + 100 * R3, 100 * (R2 * 2 - 1));
  if Damage < 50 then
    Scale := 0.7
  else
    Scale := 1.2;
  Result := Result * Scale;
  { ClipGibVelocity }
  Result.X := EnsureRange(Result.X, -300, 300);
  Result.Z := EnsureRange(Result.Z, -300, 300);
  Result.Y := EnsureRange(Result.Y, 200, 500);
end;

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
  SpinSpeed := 6;
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

constructor TQuakeExplosionModel.CreateSprite(const Parent: TCastleTransform;
  const Pos: TVector3; const SpritePath: String);
begin
  inherited Create;
  Transform := TCastleTransform.Create(nil);
  Transform.Name := 'SpriteExplosion';
  Transform.Translation := Pos;
  Sprite := SpriteManager.CreateInstance(SpritePath);
  if Sprite <> nil then
  begin
    Transform.Add(Sprite.Scene);
    Life := Sprite.FrameCount / 10;
  end;
  Parent.Add(Transform);
end;

destructor TQuakeExplosionModel.Destroy;
begin
  FreeAndNil(Sprite);
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
  Result := Life > 0;
end;

function TQuakeParticle.PositionAt(const Age: Single): TVector3;
begin
  Result := Position + Velocity * Age;
  Result.Y := Result.Y - 0.5 * Gravity * Sqr(Age);
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
  FMotion := TSingleList.Create;
  FLifeData := TSingleList.Create;
  FCorners := TSingleList.Create;
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
  FMotion.Free;
  FLifeData.Free;
  FCorners.Free;
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
const
  { Per vertex: q2p_motion = velocity, gravity (Y down); q2p_life = spawn
    time (from the mesh's base), life, start / end size; q2p_corner = -1 / +1.
    Expired quads shrink to a point until the mesh is rebuilt. }
  VertexCode =
    'attribute vec4 q2p_motion;' + LineEnding +
    'attribute vec4 q2p_life;' + LineEnding +
    'attribute vec2 q2p_corner;' + LineEnding +
    'uniform float q2p_time;' + LineEnding +
    'uniform vec3 q2p_right;' + LineEnding +
    'uniform vec3 q2p_up;' + LineEnding +
    'varying mediump float q2p_alpha;' + LineEnding +
    'void PLUG_vertex_object_space_change(inout vec4 vertex_object, inout vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  float age = max(0.0, q2p_time - q2p_life.x);' + LineEnding +
    '  float f = age / q2p_life.y;' + LineEnding +
    '  vec3 p = vertex_object.xyz + q2p_motion.xyz * age;' + LineEnding +
    '  p.y -= 0.5 * q2p_motion.w * age * age;' + LineEnding +
    '  float size = f < 1.0 ? mix(q2p_life.z, q2p_life.w, f) : 0.0;' + LineEnding +
    '  p += (q2p_right * q2p_corner.x + q2p_up * q2p_corner.y) * size;' + LineEnding +
    '  vertex_object.xyz = p;' + LineEnding +
    '  q2p_alpha = 0.9 * max(0.0, 1.0 - f);' + LineEnding +
    '}';
  FragmentCode =
    'varying mediump float q2p_alpha;' + LineEnding +
    'void PLUG_fragment_modify(inout vec4 fragment_color)' + LineEnding +
    '{' + LineEnding +
    '  fragment_color.a *= q2p_alpha;' + LineEnding +
    '}';
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TImageTextureNode;
  Effect: TEffectNode;
  VertexPart, FragmentPart: TEffectPartNode;

  function NewAttribute(const AName: String; const Components: Integer): TFloatVertexAttributeNode;
  begin
    Result := TFloatVertexAttributeNode.Create;
    Result.NameField := AName;
    Result.NumComponents := Components;
  end;

begin
  FBatchCoord := TCoordinateNode.Create;
  FBatchTexCoord := TTextureCoordinateNode.Create;
  FBatchColor := TColorRGBANode.Create;
  FBatchMotion := NewAttribute('q2p_motion', 4);
  FBatchLife := NewAttribute('q2p_life', 4);
  FBatchCorner := NewAttribute('q2p_corner', 2);
  FBatchGeometry := TIndexedTriangleSetNode.Create;
  FBatchGeometry.Coord := FBatchCoord;
  FBatchGeometry.TexCoord := FBatchTexCoord;
  FBatchGeometry.Color := FBatchColor;
  FBatchGeometry.SetAttrib([FBatchMotion, FBatchLife, FBatchCorner]);
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

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  FTimeField := TSFFloat.Create(Effect, True, 'q2p_time', 0);
  Effect.AddCustomField(FTimeField);
  FRightField := TSFVec3f.Create(Effect, True, 'q2p_right', Vector3(1, 0, 0));
  Effect.AddCustomField(FRightField);
  FUpField := TSFVec3f.Create(Effect, True, 'q2p_up', Vector3(0, 1, 0));
  Effect.AddCustomField(FUpField);
  VertexPart := TEffectPartNode.Create;
  VertexPart.ShaderType := stVertex;
  VertexPart.Contents := VertexCode;
  FragmentPart := TEffectPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  FragmentPart.Contents := FragmentCode;
  Effect.SetParts([VertexPart, FragmentPart]);
  App.SetEffects([Effect]);

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
  { The shader moves the particles away from the mesh's bounding box }
  FBatchScene.ShapeFrustumCulling := False;
  FBatchScene.SceneFrustumCulling := False;
  FBatchScene.Exists := False;
  FParent.Add(FBatchScene);
  FBatchCount := 0;
  FBatchExpired := 0;
  FBatchDirty := True;
end;

procedure TQuakeParticleManager.AddParticle(const P: TQuakeParticle);
begin
  P.SpawnTime := FTime;
  FParticles.Insert(FParticles.Count, P);
  FBatchDirty := True;
end;

function TQuakeParticleManager.ParticleCount: Integer;
begin
  Result := FParticles.Count;
end;

procedure TQuakeParticleManager.RebuildBatch;
const
  CornerX: array [0..3] of Single = (-1, 1, 1, -1);
  CornerY: array [0..3] of Single = (-1, -1, 1, 1);
var
  I, J, Base: Integer;
  P: TQuakeParticle;
begin
  if FBatchScene = nil then
    Exit;
  FBatchBase := FTime;
  FCoords.Count := FParticles.Count * 4;
  FTexCoords.Count := FParticles.Count * 4;
  FColors.Count := FParticles.Count * 4;
  FMotion.Count := FParticles.Count * 16;
  FLifeData.Count := FParticles.Count * 16;
  FCorners.Count := FParticles.Count * 8;
  FIndices.Count := FParticles.Count * 6;
  for I := 0 to FParticles.Count - 1 do
  begin
    P := FParticles[I];
    Base := I * 4;
    for J := 0 to 3 do
    begin
      FCoords.L[Base + J] := P.Position;
      FTexCoords.L[Base + J] := Vector2((CornerX[J] + 1) / 2, (CornerY[J] + 1) / 2);
      FColors.L[Base + J] := Vector4(P.Color, 1);
      FMotion.L[(Base + J) * 4] := P.Velocity.X;
      FMotion.L[(Base + J) * 4 + 1] := P.Velocity.Y;
      FMotion.L[(Base + J) * 4 + 2] := P.Velocity.Z;
      FMotion.L[(Base + J) * 4 + 3] := P.Gravity;
      FLifeData.L[(Base + J) * 4] := P.SpawnTime - FBatchBase;
      FLifeData.L[(Base + J) * 4 + 1] := P.MaxLife;
      FLifeData.L[(Base + J) * 4 + 2] := P.StartScale;
      FLifeData.L[(Base + J) * 4 + 3] := P.EndScale;
      FCorners.L[(Base + J) * 2] := CornerX[J];
      FCorners.L[(Base + J) * 2 + 1] := CornerY[J];
    end;
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
  FBatchMotion.SetValue(FMotion);
  FBatchLife.SetValue(FLifeData);
  FBatchCorner.SetValue(FCorners);
  FBatchGeometry.SetIndex(FIndices);
  FBatchCount := FParticles.Count;
  FBatchExpired := 0;
  FBatchDirty := False;
  Inc(FUploads);
end;

procedure TQuakeParticleManager.UpdateBatchUniforms;
var
  Right, Up: TVector3;
begin
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
  FTimeField.Send(FTime - FBatchBase);
  FRightField.Send(Right);
  FUpField.Send(Up);
end;

procedure TQuakeParticleManager.Clear;
begin
  FParticles.Clear;
  FExplosions.Clear;
  FGibs.Clear;
  FBatchDirty := True;
end;

procedure TQuakeParticleManager.Update(const SecondsPassed: Single);
var
  I: Integer;
begin
  FTime := FTime + SecondsPassed;
  for I := FParticles.Count - 1 downto 0 do
  begin
    if not FParticles[I].Update(SecondsPassed) then
    begin
      FParticles.Delete(I);
      Inc(FBatchExpired);
    end;
  end;
  if FBatchScene <> nil then
  begin
    { Expired particles stay in the mesh (drawn as nothing) until particles
      are added or most of the mesh has expired }
    if FParticles.Count = 0 then
      FBatchDirty := FBatchCount > 0
    else
    if FBatchExpired * 2 > FBatchCount then
      FBatchDirty := True;
    if FBatchDirty then
      RebuildBatch;
    FBatchScene.Exists := FBatchCount > 0;
    if FBatchCount > 0 then
      UpdateBatchUniforms;
  end;
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
    if FExplosions[I].Sprite <> nil then
      FExplosions[I].Sprite.Update(SecondsPassed);
    if (FExplosions[I].Life <= 0) or
       ((FExplosions[I].Sprite = nil) and ((FExplosions[I].Model = nil) or FExplosions[I].Model.AnimDone)) then
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
    AddParticle(P);
  end;

  { Smoke puff }
  Vel := Normal * 20.0 + Vector3(0, 30.0, 0);
  P := TQuakeParticle.Create(FParent, Pos, Vel, pkSmoke, 0.5, 2.0, 8.0,
    Vector3(0.5, 0.5, 0.5));
  AddParticle(P);
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
    AddParticle(P);
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
    AddParticle(P);
  end;

  { Flying fiery debris }
  for I := 1 to 10 do
  begin
    Vel := Vector3((Random - 0.5) * 300.0, (Random * 200.0 + 50.0), (Random - 0.5) * 300.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkSparks, 0.6 + Random * 0.4, 3.0, 0.5,
      Vector3(1.0, 0.6, 0.1));
    AddParticle(P);
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
    AddParticle(P);
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
    AddParticle(P);
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
    AddParticle(P);
    if Round(D) mod 24 < 8 then
    begin
      P := TQuakeParticle.Create(FParent, FromPos + Dir * D, Vector3(0, 0, 0), pkTrail,
        0.6, 0.7, 0.2, Vector3(0.9, 0.9, 1.0));
      AddParticle(P);
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
    AddParticle(P);
  end;
end;

procedure TQuakeParticleManager.UpdateGibs(const SecondsPassed: Single);
var
  I: Integer;
  G: TQuakeGib;
  Dist, Into: Single;
  NewPos, EndPos, Normal: TVector3;
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
    if Assigned(GibTrace) then
    begin
      { Quake 2 SV_Physics_Toss on the map's brushes }
      if GibTrace(G.Transform.Translation, NewPos, EndPos, Normal) then
      begin
        NewPos := EndPos + Normal * 0.25;
        Into := TVector3.DotProduct(G.Velocity, Normal);
        if G.Metallic then
        begin
          { MOVETYPE_BOUNCE: ClipVelocity with overbounce 1.5, stop on a
            floor when slow }
          G.Velocity := G.Velocity - Normal * (1.5 * Into);
          if (Normal.Y > 0.7) and (G.Velocity.Y < 60) then
            G.Resting := True;
        end else
        begin
          { MOVETYPE_TOSS: slide along walls, stop on a floor (gib_touch
            splats once) }
          G.Velocity := G.Velocity - Normal * Into;
          if Normal.Y > 0.7 then
          begin
            G.Resting := True;
            Sounds.PlayAtPoint('sound/misc/fhit3.wav', NewPos);
          end;
        end;
      end;
    end else
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
    { Organic gibs stop turning when they land (avelocity cleared) }
    if not G.Resting or G.Metallic then
    begin
      G.Angle := G.Angle + G.SpinSpeed * SecondsPassed;
      G.Transform.Rotation := Vector4(G.Spin, G.Angle);
    end;
  end;
end;

function TQuakeParticleManager.GibCount: Integer;
begin
  Result := FGibs.Count;
end;

procedure TQuakeParticleManager.ThrowGibs(const BoxMin, BoxMax: TVector3;
  const Pieces: array of TGibPiece; const Damage: Integer);
var
  I, N: Integer;
  Pos: TVector3;
  G: TQuakeGib;
begin
  if FParent = nil then
    Exit;
  for I := 0 to High(Pieces) do
    for N := 1 to Pieces[I].Count do
    begin
      Pos := Vector3(BoxMin.X + Random * (BoxMax.X - BoxMin.X), BoxMin.Y + Random * (BoxMax.Y - BoxMin.Y),
        BoxMin.Z + Random * (BoxMax.Z - BoxMin.Z));
      G := TQuakeGib.Create(FParent, Pieces[I].Model, Pos, GibVelocity(Damage, Random, Random, Random));
      G.Metallic := Pieces[I].Metallic;
      { avelocity: crandom() * 600 degrees a second on each axis }
      G.SpinSpeed := DegToRad(300 + Random * 600);
      G.Life := 10 + Random * 10;
      FGibs.Add(G);
    end;
  Pos := (BoxMin + BoxMax) / 2;
  SpawnBlood(Pos, Vector3(0, 1, 0));
  SpawnBlood(Pos + Vector3(0, 16, 0), Vector3(0, 1, 0));
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
  begin
    { ThrowDebris: MOVETYPE_BOUNCE }
    FGibs.Add(TQuakeGib.Create(FParent, Debris[I], Pos,
      Vector3((Random - 0.5) * 500, 250 + Random * 300, (Random - 0.5) * 500)));
    FGibs.Last.Metallic := True;
  end;
end;

procedure TQuakeParticleManager.SpawnBfgHit(const Pos: TVector3);
var
  Explosion: TQuakeExplosionModel;
begin
  if FParent = nil then
    Exit;
  Explosion := TQuakeExplosionModel.CreateSprite(FParent, Pos, 'sprites/s_bfg2.sp2');
  FExplosions.Add(Explosion);
  if Explosion.Sprite <> nil then
    { RF_TRANSLUCENT, alpha 0.30 }
    Explosion.Sprite.SetTransparency(0.7);
end;

procedure TQuakeParticleManager.SpawnBfgLaser(const FromPos, ToPos: TVector3);
begin
  { CL_ParseLaser: a green beam for 0.1 s }
  SpawnBeam(FromPos, ToPos, Vector3(0.3, 1.0, 0.3));
end;

procedure TQuakeParticleManager.SpawnBeam(const FromPos, ToPos, Color: TVector3);
var
  Dir: TVector3;
  Len, D: Single;
begin
  if FParent = nil then
    Exit;
  Dir := ToPos - FromPos;
  Len := Dir.Length;
  if Len < 1 then
    Exit;
  Dir := Dir / Len;
  D := 0;
  while D < Len do
  begin
    AddParticle(TQuakeParticle.Create(FParent, FromPos + Dir * D, TVector3.Zero, pkTrail,
      0.1, 1.5, 1.5, Color));
    D := D + 6;
  end;
end;

procedure TQuakeParticleManager.SpawnBfgExplosion(const Pos: TVector3);
var
  I: Integer;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;
  FExplosions.Add(TQuakeExplosionModel.CreateSprite(FParent, Pos, 'sprites/s_bfg3.sp2'));
  if FExplosions.Last.Sprite = nil then
  begin
    P := TQuakeParticle.Create(FParent, Pos, Vector3(0, 0, 0), pkFireball, 0.6, 10, 60,
      Vector3(0.3, 1.0, 0.3));
    AddParticle(P);
  end;
  for I := 1 to 30 do
  begin
    P := TQuakeParticle.Create(FParent, Pos, Vector3((Random - 0.5) * 500,
      (Random - 0.5) * 500, (Random - 0.5) * 500), pkTrail, 0.8 + Random * 0.4, 3, 0.5,
      Vector3(0.4, 1.0, 0.4));
    AddParticle(P);
  end;
end;

initialization
  Particles := TQuakeParticleManager.Create;

finalization
  FreeAndNil(Particles);
end.
