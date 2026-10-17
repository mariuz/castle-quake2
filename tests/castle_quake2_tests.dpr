{ Unit tests for Castle Quake 2's Quake 2 file parsers, using the bundled
  shareware demo PAK. Exit code 0 = all passed. Run from this directory:
    castle-engine compile && ./castle-quake2-tests

  Regenerates data/monsters.castle-transform (from DefaultMonsterDefs) and
  data/sounds.castle-component (from DesignSoundPaths), overwriting edits:
    ./castle-quake2-tests --generate-designs ../data

  Also compares autotest screenshots with reference images (used by CI):
    ./castle-quake2-tests --compare reference.png screenshot.png diff.png [max-mean-diff]
  Both images are averaged into 64x36 blocks (robust to tiny camera shifts
  and flicker); exit code 1 when the mean absolute channel difference
  (0..255) is above the limit (default 3). A missing reference is created
  from the screenshot (64x36, the blocks themselves). }
program castle_quake2_tests;

{$apptype console}
{$mode objfpc}{$H+}

uses
  {$ifdef UNIX} CThreads, {$endif}
  SysUtils, Math,
  Classes,
  CastleVectors, CastleLog, CastleImages, CastleClassUtils, CastleComponentSerialize,
  CastleTransform, CastleUriUtils, CastleScene,
  QuakePak, QuakePalette, QuakeBsp, QuakeMd2, QuakeSprite, QuakeLight, QuakeEntities,
  QuakeMonsterTypes, QuakeSound, QuakeSettings, CastleKeysMouse, CastleXmlConfig;

var
  Passed, Failed: Integer;

procedure Check(const Condition: Boolean; const What: String);
begin
  if Condition then
    Inc(Passed)
  else
  begin
    Inc(Failed);
    Writeln('FAIL: ', What);
  end;
end;

procedure CheckEquals(const Expected, Actual: Int64; const What: String);
begin
  Check(Expected = Actual, Format('%s: expected %d, got %d', [What, Expected, Actual]));
end;

procedure TestPak;
begin
  CheckEquals(1106, Pak.FileCount, 'PAK file count');
  Check(Pak.FileExists('maps/demo1.bsp'), 'maps/demo1.bsp exists');
  Check(Pak.FileExists('MAPS\DEMO1.BSP'), 'lookups are case-insensitive, accept backslashes');
  Check(not Pak.FileExists('maps/base1.bsp'), 'base1 is not in the demo');
end;

procedure TestImages;
var
  Info: TQuakeWalInfo;
  Data: Pointer;
  Size: Cardinal;
  W, H: Integer;
  Pixels: TBytes;
  Pal: TQuakeRGBPalette;
begin
  Check(Palette.HasPalette, 'palette loaded from pics/colormap.pcx');
  Data := Pak.GetData('pics/help.pcx', Size);
  Check(DecodePcx(Data, Size, W, H, Pixels, Pal), 'decode pics/help.pcx');
  CheckEquals(256, W, 'help.pcx width');
  CheckEquals(192, H, 'help.pcx height');
  CheckEquals(W * H, Length(Pixels), 'help.pcx pixel count');
  Check(Palette.LoadWal('e1u1/box1_1', Info), 'load WAL e1u1/box1_1');
  CheckEquals(96, Info.Width, 'box1_1 width');
  CheckEquals(32, Info.Height, 'box1_1 height');
  Check(Palette.HasCachedImage(WalTextureId('e1u1/box1_1')), 'WAL cached for quaketex:');
  Check(not Palette.LoadWal('does/not/exist', Info), 'missing WAL reported');
end;

procedure TestBsp;
var
  Bsp: TQuakeBsp;
  World: TQuakeEntity;
  C: TVector3;
  Cluster, I, Seen: Integer;
  Same: Boolean;
  Pvs, PortalOpen, AreaBits: TBytes;
  Leafs: array[0..63] of Integer;
  LeafCount: Integer;
  Start: TVector3;
begin
  Bsp := TQuakeBsp.Create;
  try
    Check(Bsp.LoadFromPak('maps/demo1.bsp'), 'load demo1.bsp');
    CheckEquals(7905, Bsp.FaceCount, 'demo1 faces');
    CheckEquals(631, Length(Bsp.TexInfos), 'demo1 texinfos');
    CheckEquals(35, Bsp.ModelCount, 'demo1 models');
    CheckEquals(652, Bsp.Entities.Count, 'demo1 entities');
    World := Bsp.FindEntity('worldspawn');
    Check(World <> nil, 'worldspawn present');
    if World <> nil then
      Check(World.GetField('sky') = 'unit1_', 'worldspawn sky = unit1_');
    Check(Bsp.FindEntity('info_player_start') <> nil, 'info_player_start present');
    { Point contents: inside the big pool, and in the air above it }
    Check((Bsp.PointContents(Vector3(319, 680, -300)) and CONTENTS_WATER) <> 0, 'water in the pool');
    Check((Bsp.PointContents(Vector3(319, 680, -200)) and CONTENTS_WATER) = 0, 'no water above the pool');
    { The one ladder brush: x 368..408, y 21..31, z -242..-60 }
    Check(Bsp.PointInLadder(Vector3(388, 26, -221)), 'inside the ladder brush');
    Check(not Bsp.PointInLadder(Vector3(388, 60, -221)), 'in front of the ladder brush');
    Check(not Bsp.PointInLadder(Vector3(388, 26, 0)), 'above the ladder brush');
    { Baked light below the player start }
    Check(Bsp.LightPoint(CgeToQuake(Vector3(128, 46, 320)), C), 'LightPoint finds a lit surface');
    Check((C.X > 0) or (C.Y > 0) or (C.Z > 0), 'LightPoint colour is not black');

    Check(Bsp.ClusterCount > 0, 'demo1 has visibility clusters');
    Cluster := Bsp.PointCluster(Bsp.FindEntity('info_player_start').Origin);
    Check(Cluster >= 0, 'player start is in a cluster');
    Bsp.ClusterPVS(Cluster, Pvs);
    CheckEquals(Bsp.ClusterBytes, Length(Pvs), 'PVS row size');
    Check((Pvs[Cluster shr 3] and (1 shl (Cluster and 7))) <> 0, 'a cluster sees itself');
    Seen := 0;
    for I := 0 to Bsp.ClusterCount - 1 do
      if (Pvs[I shr 3] and (1 shl (I and 7))) <> 0 then
        Inc(Seen);
    Check((Seen > 1) and (Seen < Bsp.ClusterCount), Format('PVS culls clusters (%d of %d seen)', [Seen, Bsp.ClusterCount]));
    Bsp.ClusterPHS(Cluster, PortalOpen);
    Check((PortalOpen[Cluster shr 3] and (1 shl (Cluster and 7))) <> 0, 'a cluster hears itself');
    Same := True;
    I := 0;
    while I < Bsp.ClusterCount do
    begin
      if ((Pvs[I shr 3] and (1 shl (I and 7))) <> 0) and ((PortalOpen[I shr 3] and (1 shl (I and 7))) = 0) then
        Same := False;
      Inc(I);
    end;
    Check(Same, 'PHS contains the PVS');
    CheckEquals(-1, Bsp.PointCluster(Vector3(100000, 0, 0)), 'no cluster outside the map');
    Bsp.ClusterPVS(-1, Pvs);
    Check(Pvs[0] = $FF, 'cluster -1 sees everything');

    CheckEquals(3, Bsp.AreaCount, 'demo1 areas (0 = solid)');
    CheckEquals(2, Bsp.AreaPortalCount, 'demo1 portal states (portal 1)');
    CheckEquals(2, Bsp.LeafArea(Bsp.PointLeaf(Bsp.FindEntity('info_player_start').Origin)), 'player start area');
    PortalOpen := nil;
    SetLength(PortalOpen, Bsp.AreaPortalCount);
    Bsp.FloodAreas(2, PortalOpen, AreaBits);
    CheckEquals(1 shl 2, AreaBits[0], 'closed portal: only area 2 connected');
    PortalOpen[1] := 1;
    Bsp.FloodAreas(2, PortalOpen, AreaBits);
    CheckEquals((1 shl 1) or (1 shl 2), AreaBits[0], 'open portal connects areas 1 and 2');

    Start := Bsp.FindEntity('info_player_start').Origin;
    Check(Bsp.BoxLeafs(Start - Vector3(16, 16, 24), Start + Vector3(16, 16, 32), Leafs, LeafCount) and
      (LeafCount >= 1), 'player box touches leafs');
    Seen := 0;
    for I := 0 to LeafCount - 1 do
      if Leafs[I] = Bsp.PointLeaf(Start) then
        Inc(Seen);
    CheckEquals(1, Seen, 'box leafs include the leaf of its center');
    Check(not Bsp.BoxLeafs(Vector3(-4096, -4096, -4096), Vector3(4096, 4096, 4096), Leafs, LeafCount),
      'whole-map box overflows 64 leafs');
  finally
    Bsp.Free;
  end;
end;

procedure TestMd2;
var
  Mdl: TQuakeMd2;
  Anim: TMd2Anim;
begin
  Mdl := Md2Manager.GetModel('models/monsters/soldier/tris.md2');
  Check(Mdl <> nil, 'load soldier MD2');
  if Mdl = nil then
    Exit;
  CheckEquals(475, Mdl.FrameCount, 'soldier frames');
  Check(Mdl.FindAnim('run', Anim) and (Anim.Count > 1), 'soldier has a run animation');
  Check(Mdl.FindAnim('death', Anim) and (Anim.Count > 1), 'soldier has a death animation');
  Check(Mdl.FindAnim('', Anim) and (Anim.Count = 475), 'empty animation name = all frames');
  Check(not Mdl.FindAnim('nonexistent', Anim), 'unknown animation reported');
  Check(Mdl.SkinId(0) <> '', 'soldier skin found');
  Check(Md2Manager.GetModel('models/does/not/exist.md2') = nil, 'missing MD2 returns nil');
end;

procedure TestSprite;
var
  Sprite: TQuakeSprite;
begin
  Sprite := TQuakeSprite.Create;
  try
    Check(Sprite.LoadFromPak('sprites/s_bfg1.sp2'), 'load s_bfg1.sp2');
    CheckEquals(2, Length(Sprite.Frames), 's_bfg1 frames');
    if Length(Sprite.Frames) > 0 then
    begin
      CheckEquals(48, Sprite.Frames[0].Width, 's_bfg1 frame width');
      Check(Sprite.Frames[0].TextureId = 'sprites/s_bfg1_0.pcx', 's_bfg1 frame texture');
    end;
  finally
    Sprite.Free;
  end;
end;

procedure TestCoordinates;
var
  V: TVector3;
begin
  V := Vector3(1, 2, 3);
  Check(TVector3.Equals(CgeToQuake(QuakeToCge(V)), V), 'Quake <-> CGE coordinates round trip');
  Check(TVector3.Equals(QuakeToCge(Vector3(0, 0, 1)), Vector3(0, 1, 0)), 'Quake up is CGE +Y');
  Check(TVector3.Equals(YawToCgeDir(90), Vector3(0, 0, -1), 0.0001), 'yaw 90 (north) is CGE -Z');
end;

const
  CompareWidth = 64;
  CompareHeight = 36;

type
  TBlockColors = array[0..CompareWidth * CompareHeight - 1] of TVector3;

{ Average colour of each block of the image (a box-filter downscale, so a
  tiny camera shift or flickering texel barely changes the result) }
procedure BlockAverages(const Image: TCastleImage; out Blocks: TBlockColors);
var
  X, Y, BX, BY, I: Integer;
  Counts: array[0..CompareWidth * CompareHeight - 1] of Integer;
  P: PVector3Byte;
begin
  for I := 0 to High(Blocks) do
  begin
    Blocks[I] := TVector3.Zero;
    Counts[I] := 0;
  end;
  for Y := 0 to Image.Height - 1 do
  begin
    BY := Y * CompareHeight div Image.Height;
    for X := 0 to Image.Width - 1 do
    begin
      BX := X * CompareWidth div Image.Width;
      I := BY * CompareWidth + BX;
      P := Image.PixelPtr(X, Y);
      Blocks[I] := Blocks[I] + Vector3(P^.X, P^.Y, P^.Z);
      Inc(Counts[I]);
    end;
  end;
  for I := 0 to High(Blocks) do
    if Counts[I] > 0 then
      Blocks[I] := Blocks[I] / Counts[I];
end;

{ Mean absolute RGB difference (0..255) of the block averages of two images;
  writes the amplified difference as an image. }
function CompareImages(const ReferencePath, ShotPath, DiffPath: String): Single;
var
  Ref, Shot: TCastleImage;
  RefBlocks, ShotBlocks: TBlockColors;
  Diff: TRGBImage;
  I: Integer;
  D: TVector3;
  Sum: Single;
begin
  Shot := LoadImage(ShotPath, [TRGBImage]);
  try
    BlockAverages(Shot, ShotBlocks);
  finally
    Shot.Free;
  end;

  { No reference yet: the shot's blocks become it }
  if not FileExists(ReferencePath) then
  begin
    Diff := TRGBImage.Create(CompareWidth, CompareHeight);
    try
      for I := 0 to High(ShotBlocks) do
        PVector3Byte(Diff.PixelPtr(I mod CompareWidth, I div CompareWidth))^ := Vector3Byte(
          Round(ShotBlocks[I].X), Round(ShotBlocks[I].Y), Round(ShotBlocks[I].Z));
      SaveImage(Diff, ReferencePath);
    finally
      Diff.Free;
    end;
    Writeln('Created reference ', ReferencePath);
    Exit(0);
  end;

  Ref := LoadImage(ReferencePath, [TRGBImage]);
  try
    BlockAverages(Ref, RefBlocks);
  finally
    Ref.Free;
  end;

  Diff := TRGBImage.Create(CompareWidth, CompareHeight);
  try
    Sum := 0;
    for I := 0 to High(RefBlocks) do
    begin
      D := RefBlocks[I] - ShotBlocks[I];
      D := Vector3(Abs(D.X), Abs(D.Y), Abs(D.Z));
      Sum := Sum + D.X + D.Y + D.Z;
      PVector3Byte(Diff.PixelPtr(I mod CompareWidth, I div CompareWidth))^ := Vector3Byte(
        Min(255, Round(D.X * 4)), Min(255, Round(D.Y * 4)), Min(255, Round(D.Z * 4)));
    end;
    if DiffPath <> '' then
      SaveImage(Diff, DiffPath);
  finally
    Diff.Free;
  end;
  Result := Sum / (Length(RefBlocks) * 3);
end;

procedure RunCompare;
var
  MaxDiff, Mean: Single;
begin
  MaxDiff := 3;
  if ParamCount >= 5 then
    MaxDiff := StrToFloatDef(ParamStr(5), MaxDiff);
  Mean := CompareImages(ParamStr(2), ParamStr(3), ParamStr(4));
  Writeln(Format('%s vs %s: mean difference %.2f (limit %.2f)',
    [ParamStr(2), ParamStr(3), Mean, MaxDiff]));
  if Mean > MaxDiff then
    Halt(1);
end;

const
  { Sounds the game code plays by literal path, named in the sounds design }
  DesignSoundPaths: array[0..62] of String = (
    'sound/doors/dr1_end.wav',
    'sound/doors/dr1_mid.wav',
    'sound/doors/dr1_strt.wav',
    'sound/items/damage3.wav',
    'sound/items/l_health.wav',
    'sound/items/m_health.wav',
    'sound/items/n_health.wav',
    'sound/items/pkup.wav',
    'sound/items/s_health.wav',
    'sound/misc/am_pkup.wav',
    'sound/misc/ar1_pkup.wav',
    'sound/misc/ar2_pkup.wav',
    'sound/misc/ar3_pkup.wav',
    'sound/misc/keytry.wav',
    'sound/misc/keyuse.wav',
    'sound/misc/menu1.wav',
    'sound/misc/menu2.wav',
    'sound/misc/menu3.wav',
    'sound/misc/pc_up.wav',
    'sound/misc/secret.wav',
    'sound/misc/talk1.wav',
    'sound/misc/tele1.wav',
    'sound/misc/udeath.wav',
    'sound/misc/w_pkup.wav',
    'sound/misc/windfly.wav',
    'sound/plats/pt1_end.wav',
    'sound/plats/pt1_mid.wav',
    'sound/plats/pt1_strt.wav',
    'sound/player/gasp1.wav',
    'sound/player/land1.wav',
    'sound/player/lava_in.wav',
    'sound/player/male/death1.wav',
    'sound/player/male/fall1.wav',
    'sound/player/male/fall2.wav',
    'sound/player/male/jump1.wav',
    'sound/player/male/pain100_1.wav',
    'sound/player/male/pain25_1.wav',
    'sound/player/male/pain50_1.wav',
    'sound/player/male/pain75_1.wav',
    'sound/player/watr_in.wav',
    'sound/player/watr_out.wav',
    'sound/player/watr_un.wav',
    'sound/switches/butn2.wav',
    'sound/weapons/bfg__f1y.wav',
    'sound/weapons/bfg__x1b.wav',
    'sound/weapons/blastf1a.wav',
    'sound/weapons/chngnd1a.wav',
    'sound/weapons/chngnu1a.wav',
    'sound/weapons/grenlb1b.wav',
    'sound/weapons/grenlf1a.wav',
    'sound/weapons/hgrena1b.wav',
    'sound/weapons/hgrent1a.wav',
    'sound/weapons/hyprbf1a.wav',
    'sound/weapons/lashit.wav',
    'sound/weapons/machgf1b.wav',
    'sound/weapons/machgf2b.wav',
    'sound/weapons/noammo.wav',
    'sound/weapons/railgf1a.wav',
    'sound/weapons/rocklf1a.wav',
    'sound/weapons/rocklx1a.wav',
    'sound/weapons/shotgf1b.wav',
    'sound/weapons/sshotf1b.wav',
    'sound/world/quake.wav'
  );

{ Readable component name for a sound path: sound/items/pkup.wav -> Items_pkup }
function SoundComponentName(const Path: String): String;
var
  I: Integer;
begin
  Result := Copy(ChangeFileExt(Path, ''), Length('sound/') + 1, MaxInt);
  for I := 1 to Length(Result) do
    if not (Result[I] in ['a'..'z', 'A'..'Z', '0'..'9']) then
      Result[I] := '_';
  Result[1] := UpCase(Result[1]);
end;

procedure GenerateDesigns(const Dir: String);
var
  Owner: TComponent;
  Root: TCastleComponent;
  Sound: TQuakeNamedSound;
  Path: String;
begin
  Owner := TComponent.Create(nil);
  try
    TransformSave(CreateDefaultMonsterTypes(Owner), FilenameToUriSafe(Dir + '/monsters.castle-transform'));
  finally
    Owner.Free;
  end;
  Owner := TComponent.Create(nil);
  try
    Root := TCastleComponent.Create(Owner);
    Root.Name := 'NamedSounds';
    for Path in DesignSoundPaths do
    begin
      Sound := TQuakeNamedSound.Create(Owner);
      Sound.Name := SoundComponentName(Path);
      Sound.Url := 'quakepak:/' + Path;
      Sound.QuakePath := Path;
      Root.AddNonVisualComponent(Sound);
    end;
    ComponentSave(Root, FilenameToUriSafe(Dir + '/sounds.castle-component'));
  finally
    Owner.Free;
  end;
  Writeln('Wrote monsters.castle-transform and sounds.castle-component to ', Dir);
end;

procedure TestDesigns;
var
  I, PreviewCount: Integer;
  Same: Boolean;
  Owner: TComponent;
  Named: TQuakeNamedSound;
  Root: TCastleTransform;
  MonsterType: TQuakeMonsterType;
  TempUrl: String;
begin
  CheckEquals(Length(DefaultMonsterDefs),
    LoadMonsterTypes(FilenameToUriSafe('../data/monsters.castle-transform')), 'monster types in the design');
  CheckEquals(Length(DefaultMonsterDefs), Length(MonsterDefs), 'design adds no unknown monsters');
  Same := True;
  for I := 0 to High(DefaultMonsterDefs) do
    Same := Same and (MonsterDefs[I].ClassName = DefaultMonsterDefs[I].ClassName) and
      (MonsterDefs[I].Model = DefaultMonsterDefs[I].Model) and (MonsterDefs[I].Skin = DefaultMonsterDefs[I].Skin) and
      (MonsterDefs[I].Health = DefaultMonsterDefs[I].Health) and SameValue(MonsterDefs[I].Speed, DefaultMonsterDefs[I].Speed) and
      (MonsterDefs[I].Attack = DefaultMonsterDefs[I].Attack) and (MonsterDefs[I].Damage = DefaultMonsterDefs[I].Damage) and
      SameValue(MonsterDefs[I].AttackRange, DefaultMonsterDefs[I].AttackRange) and
      SameValue(MonsterDefs[I].AttackCooldown, DefaultMonsterDefs[I].AttackCooldown) and
      (MonsterDefs[I].Flying = DefaultMonsterDefs[I].Flying) and (MonsterDefs[I].SoundDir = DefaultMonsterDefs[I].SoundDir) and
      (MonsterDefs[I].PainSound = DefaultMonsterDefs[I].PainSound) and (MonsterDefs[I].AttackSound = DefaultMonsterDefs[I].AttackSound);
  Check(Same, 'monster types design matches DefaultMonsterDefs');

  { As in the editor: every type shows its model }
  PreviewMonsterTypes := True;
  Owner := TComponent.Create(nil);
  try
    TransformLoad(FilenameToUriSafe('../data/monsters.castle-transform'), Owner);
    PreviewCount := 0;
    for I := 0 to Owner.ComponentCount - 1 do
      if (Owner.Components[I] is TQuakeMonsterType) and (TQuakeMonsterType(Owner.Components[I]).Count = 1) then
        Inc(PreviewCount);
    { Not all models are in the demo PAK }
    Check(PreviewCount >= 10, Format('monster type previews (%d)', [PreviewCount]));
  finally
    Owner.Free;
    PreviewMonsterTypes := False;
  end;

  { A design overrides a type by MonsterClass and adds unknown ones }
  Owner := TComponent.Create(nil);
  try
    Root := TCastleTransform.Create(Owner);
    MonsterType := TQuakeMonsterType.Create(Owner);
    MonsterType.Assign(FindMonsterDef('monster_soldier')^);
    MonsterType.Health := 999;
    Root.Add(MonsterType);
    MonsterType := TQuakeMonsterType.Create(Owner);
    MonsterType.MonsterClass := 'Monster_Test';
    MonsterType.Health := 7;
    Root.Add(MonsterType);
    TempUrl := FilenameToUriSafe(GetTempDir + 'castle_quake2_test_monsters.castle-transform');
    TransformSave(Root, TempUrl);
  finally
    Owner.Free;
  end;
  CheckEquals(2, LoadMonsterTypes(TempUrl), 'monster types in the test design');
  DeleteFile(UriToFilenameSafe(TempUrl));
  CheckEquals(999, FindMonsterDef('monster_soldier')^.Health, 'design overrides monster_soldier health');
  Check((FindMonsterDef('monster_test') <> nil) and (FindMonsterDef('monster_test')^.Health = 7),
    'design adds monster_test');

  Check(Sounds.LoadNamedSounds(FilenameToUriSafe('../data/sounds.castle-component')) >= 40, 'named sounds loaded');
  Named := Sounds.NamedSound('SOUND/items/pkup.wav');
  Check((Named <> nil) and (Named.Name = 'Items_pkup'), 'named sound for sound/items/pkup.wav');
  Check(Sounds.SoundFor('sound/items/pkup.wav') = Named, 'playing the path uses the named sound');
  Check(Sounds.SoundFor('sound/misc/does_not_exist.wav') = nil, 'unknown sound');
end;

procedure TestSettings;
var
  S: TQuakeSettings;
  Config: TCastleConfig;
  Path: String;
begin
  CheckEquals(SPAWNFLAG_NOT_EASY, SkillSpawnFlag(0), 'easy removes NOT_EASY entities');
  CheckEquals(SPAWNFLAG_NOT_MEDIUM, SkillSpawnFlag(1), 'medium removes NOT_MEDIUM entities');
  CheckEquals(SPAWNFLAG_NOT_HARD, SkillSpawnFlag(3), 'nightmare uses the hard spawnflag');
  Check(SkillAttackDelay(0) > SkillAttackDelay(1), 'monsters attack less often on easy');
  Check(SkillAttackDelay(3) < SkillAttackDelay(2), 'and most often on nightmare');

  S := TQuakeSettings.Create;
  try
    S.BindKey(qaForward, keyA);
    Check((S.Keys[qaForward] = keyA) and (S.Keys[qaMoveLeft] = keyW), 'binding a used key swaps the keys');
    S.Skill := 3;
    S.MouseSensitivity := 1.75;
    S.InvertMouse := True;
    S.ViewBob := False;
    S.FieldOfView := 110;
    S.MusicVolume := 30;
    Path := GetTempDir + 'castle_quake2_test_settings.xml';
    Config := TCastleConfig.Create(nil);
    try
      Config.LoadFromString('<?xml version="1.0"?><CONFIG></CONFIG>', FilenameToUriSafe(Path));
      S.Save(Config);
      S.ResetToDefaults;
      S.Load(Config);
    finally
      Config.Free;
    end;
    Check((S.Skill = 3) and SameValue(S.MouseSensitivity, 1.75) and S.InvertMouse and not S.ViewBob and
      (S.FieldOfView = 110) and (S.MusicVolume = 30) and (S.SoundVolume = 100),
      'settings survive save / load');
    Check((S.Keys[qaForward] = keyA) and (S.Keys[qaMoveLeft] = keyW) and (S.Keys[qaFire] = keyCtrl),
      'key bindings survive save / load');
  finally
    S.Free;
  end;
end;

procedure TestSounds;
var
  Root: TCastleRootTransform;
  Pos: TVector3;
begin
  { Quake 2 attenuation: full volume up to 80 units, then 1 - d * dist_mult,
    dist_mult = 0.0005 * attenuation (0.001 * 3 for ATTN_STATIC) }
  Check(SameValue(Sounds.SpatialSound('sound/items/pkup.wav', ATTN_NORM).MaxDistance, 2080, 0.01), 'ATTN_NORM silent at 2080 units');
  Check(SameValue(Sounds.SpatialSound('sound/items/pkup.wav', ATTN_IDLE).MaxDistance, 1080, 0.01), 'ATTN_IDLE silent at 1080 units');
  Check(SameValue(Sounds.SpatialSound('sound/items/pkup.wav', ATTN_STATIC).MaxDistance, 80 + 1000 / 3, 0.01), 'ATTN_STATIC silent at 413 units');
  Check(SameValue(Sounds.SpatialSound('sound/items/pkup.wav', ATTN_NORM).ReferenceDistance, 80), 'full volume within 80 units');

  { Loop mixer: one voice per distinct sound, at its loudest emitter;
    emitters beyond loop attenuation (413 units) are silent }
  Root := TCastleRootTransform.Create(nil);
  try
    Sounds.WorldParent := Root;
    Sounds.BeginLoops(TVector3.Zero);
    Sounds.AddLoop('sound/world/amb7.wav', Vector3(300, 0, 0));
    Sounds.AddLoop('sound/world/amb7.wav', Vector3(0, 0, 100));
    Sounds.AddLoop('sound/world/amb8.wav', Vector3(1000, 0, 0));
    Sounds.EndLoops;
    CheckEquals(1, Sounds.PlayingLoopCount, 'one loop voice for two emitters, none out of range');
    Check(Sounds.LoopPosition('sound/world/amb7.wav', Pos) and TVector3.Equals(Pos, Vector3(0, 0, 100)),
      'loop voice plays at the loudest (nearest) emitter');
    Sounds.BeginLoops(Vector3(1000, 0, 0));
    Sounds.AddLoop('sound/world/amb7.wav', Vector3(300, 0, 0));
    Sounds.AddLoop('sound/world/amb8.wav', Vector3(1000, 0, 0));
    Sounds.EndLoops;
    Check(not Sounds.LoopPosition('sound/world/amb7.wav', Pos) and Sounds.LoopPosition('sound/world/amb8.wav', Pos),
      'loops follow the listener');
    Sounds.BeginLoops(TVector3.Zero);
    Sounds.EndLoops;
    CheckEquals(0, Sounds.PlayingLoopCount, 'loops stop when nothing requests them');
    Sounds.ClearLoops;
  finally
    Sounds.WorldParent := nil;
    Root.Free;
  end;
end;

const
  PakPath = '../data/paks/quake2_demo.pak';
begin
  if (ParamCount >= 2) and (ParamStr(1) = '--generate-designs') then
  begin
    GenerateDesigns(ParamStr(2));
    Exit;
  end;
  if (ParamCount >= 4) and (ParamStr(1) = '--compare') then
  begin
    RunCompare;
    Exit;
  end;
  if not Pak.AddFile(PakPath) then
  begin
    Writeln('Cannot load ', PakPath, ' (run the tests from the tests/ directory)');
    Halt(2);
  end;
  Palette.RegisterProtocol;
  Palette.LoadFromPak;

  TestPak;
  TestImages;
  TestBsp;
  TestMd2;
  TestSprite;
  TestCoordinates;
  TestDesigns;
  TestSettings;
  TestSounds;

  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
