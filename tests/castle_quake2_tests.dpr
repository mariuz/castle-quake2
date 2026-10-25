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
  QuakeMonsterTypes, QuakeSound, QuakeSettings, CastleKeysMouse, CastleXmlConfig, QuakeMapReport, QuakeGamepad, QuakeWeaponFrames, QuakeMonsterAttacks, QuakeTrace, QuakeTouch, QuakeRecord, QuakePlayer, QuakeParticles, QuakeWorld, QuakeTurret, QuakeMonsterMoves, QuakeLevel, QuakeBspBuilder, QuakeLevelGen, QuakeMap;

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
    S.InterfaceSize := 3;
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
    Check(S.InterfaceSize = 3, 'interface size survives save / load');
    Check(SameValue(InterfaceScaleFor(0, False), 1) and SameValue(InterfaceScaleFor(0, True), TouchInterfaceScale),
      'auto interface size: normal on desktop, larger on touch screens');
    Check(SameValue(InterfaceScaleFor(2, True), 1) and (InterfaceScaleFor(4, False) > InterfaceScaleFor(3, False)) and
      (InterfaceScaleFor(1, False) < 1), 'chosen interface sizes ignore the device');
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

procedure TestMapReport;
var
  NoteText: String;
begin
  Check(ClassSupport('monster_soldier', NoteText) = csSupported, 'soldiers are fully supported');
  Check(ClassSupport('weapon_railgun', NoteText) = csSupported, 'items are supported');
  Check(ClassSupport('func_group', NoteText) = csSupported, 'func_group is merged into the world');
  Check((ClassSupport('monster_medic', NoteText) = csPartial) and (NoteText <> ''), 'medic is partial (no revive)');
  Check(ClassSupport('func_object', NoteText) = csPartial, 'unknown func_ brushes are drawn (partial)');
  Check(ClassSupport('func_conveyor', NoteText) = csSupported, 'func_conveyor moves the player by its contents');
  Check(ClassSupport('misc_viper', NoteText) = csSupported, 'misc_viper flies its path');
  Check(ClassSupport('turret_breach', NoteText) = csSupported, 'turret_breach turns and fires');
  Check(ClassSupport('turret_driver', NoteText) = csSupported, 'turret_driver aims its breach');
  Check(ClassSupport('misc_actor', NoteText) = csUnsupported, 'misc_actor is unsupported');
  Check(ClassSupport('target_string', NoteText) = csSupported, 'target_string writes its target_characters');
end;

type
  { Records what the gun asks the world to do }
  TGunProbe = class
    Gun: TQuakeGun;
    AmmoLeft: Integer;
    Events: array of TGunEvent;
    Times: array of Single;
    Shots: array of Integer;
    procedure OnEvent(const Event: TGunEvent);
    function OnAmmo(const Slot: Integer): Integer;
    function Count(const Event: TGunEvent): Integer;
    function FirstTime(const Event: TGunEvent): Single;
    { Run for Seconds in 0.01 s steps, holding fire if Hold }
    procedure Run(const Seconds: Single; const Hold: Boolean);
  end;

procedure TGunProbe.OnEvent(const Event: TGunEvent);
begin
  SetLength(Events, Length(Events) + 1);
  Events[High(Events)] := Event;
  SetLength(Times, Length(Times) + 1);
  Times[High(Times)] := Gun.Time;
  SetLength(Shots, Length(Shots) + 1);
  Shots[High(Shots)] := Gun.Shots;
  if Event = geFire then
    Dec(AmmoLeft, Gun.Shots);
end;

function TGunProbe.OnAmmo(const Slot: Integer): Integer;
begin
  Result := AmmoLeft;
end;

function TGunProbe.Count(const Event: TGunEvent): Integer;
var
  E: TGunEvent;
begin
  Result := 0;
  for E in Events do
    if E = Event then
      Inc(Result);
end;

function TGunProbe.FirstTime(const Event: TGunEvent): Single;
var
  I: Integer;
begin
  for I := 0 to High(Events) do
    if Events[I] = Event then
      Exit(Times[I]);
  Result := -1;
end;

procedure TGunProbe.Run(const Seconds: Single; const Hold: Boolean);
var
  I: Integer;
  WasHeld: Boolean;
begin
  WasHeld := Gun.Attack;
  for I := 1 to Round(Seconds / 0.01) do
  begin
    { Like TQuakeWorld: a new press is latched and thinks at once }
    if Hold and not WasHeld then
      Gun.AttackLatched := True;
    Gun.Attack := Hold;
    WasHeld := Hold;
    Gun.Update(0.01);
  end;
end;

{ Fresh gun with Slot ready and Ammo shots }
function NewProbe(const Slot, Ammo: Integer): TGunProbe;
begin
  Result := TGunProbe.Create;
  Result.Gun := TQuakeGun.Create;
  Result.Gun.RandomPauses := False;
  Result.Gun.OnEvent := @Result.OnEvent;
  Result.Gun.OnAmmo := @Result.OnAmmo;
  Result.AmmoLeft := Ammo;
  Result.Gun.Reset(Slot, False);
end;

procedure FreeProbe(var P: TGunProbe);
begin
  P.Gun.Free;
  FreeAndNil(P);
end;

procedure TestGun;
var
  P: TGunProbe;
  I: Integer;
  T: Single;
begin
  { Weapon_Generic timing: the blaster refires every 0.5 s, the shot leaves
    on the press, not on the next frame }
  P := NewProbe(1, MaxInt);
  P.Run(1.95, True);
  CheckEquals(4, P.Count(geFire), 'blaster held 1.95 s fires 4 bolts (0.5 s refire)');
  Check(SameValue(P.FirstTime(geFire), 0.01, 0.001), 'the first shot leaves on the press');
  FreeProbe(P);
  P := NewProbe(2, MaxInt);
  P.Run(2.35, True);
  CheckEquals(2, P.Count(geFire), 'shotgun refires after its 1.2 s of frames');
  FreeProbe(P);
  P := NewProbe(4, MaxInt);
  P.Run(0.95, True);
  CheckEquals(10, P.Count(geFire), 'machinegun fires every frame (frames 4 / 5) while held');
  FreeProbe(P);
  { Machinegun tap: one bullet, then back to ready }
  P := NewProbe(4, MaxInt);
  P.Run(0.01, True);
  P.Run(0.5, False);
  Check((P.Count(geFire) = 1) and (P.Gun.State = gsReady), 'machinegun tap fires one bullet');
  FreeProbe(P);
  { Chaingun spin up: 1, 1, 1, 1, then 2 a frame, then 3 }
  P := NewProbe(5, 1000);
  P.Run(1.995, True);
  Check((Length(P.Shots) > 0) and (P.Events[0] = geChaingunUp), 'chaingun spin-up sound first');
  I := 0;
  T := 0;
  for I := 0 to High(P.Events) do
    if P.Events[I] = geFire then
      T := T + P.Shots[I];
  CheckEquals(47, Round(T), 'chaingun fires 47 bullets in 2 s (Chaingun_Fire spin-up)');
  Check(P.Gun.LoopSound <> '', 'chaingun spinning has a loop sound');
  P.Run(1.5, False);
  Check((P.Gun.State = gsReady) and (P.Gun.LoopSound = '') and (P.Count(geChaingunDown) = 1),
    'released chaingun spins down to ready');
  FreeProbe(P);
  { BFG: flash on the press, the ball 0.8 s later }
  P := NewProbe(10, 1);
  P.Run(1.0, True);
  Check((P.Count(geBfgFlash) = 1) and (P.Count(geFire) = 1) and
    SameValue(P.FirstTime(geFire) - P.FirstTime(geBfgFlash), 0.8, 0.02), 'BFG ball leaves 0.8 s after the flash');
  FreeProbe(P);
  { Switching: blaster put away (3 frames) then the shotgun raised (7) }
  P := NewProbe(1, MaxInt);
  P.Gun.Select(2);
  P.Run(0.45, False);
  Check((P.Count(geChangeWeapon) = 1) and (P.Gun.Slot = 2) and (P.Gun.State = gsActivating),
    'blaster put away after 0.4 s of frames');
  P.Run(0.8, False);
  Check(P.Gun.State = gsReady, 'shotgun raised and ready');
  P.Run(0.5, True);
  CheckEquals(1, P.Count(geFire), 'raised shotgun fires');
  FreeProbe(P);
  { No ammo: one click a second }
  P := NewProbe(2, 0);
  P.Run(1.55, True);
  Check((P.Count(geNoAmmo) = 2) and (P.Count(geFire) = 0), 'no ammo clicks once a second');
  FreeProbe(P);
  { Hand grenade tap: pin on frame 5, thrown on frame 12 with ~3.1 s fuse }
  P := NewProbe(HandGrenadeSlot, 5);
  P.Run(0.01, True);
  P.Run(1.5, False);
  Check((P.Count(geGrenadePin) = 1) and (P.Count(geGrenadeThrow) = 1) and (P.Gun.Fuse > 3.0) and
    (P.Gun.Fuse < 3.2), 'hand grenade thrown with a full fuse');
  FreeProbe(P);
  { Held: the fuse runs down and it goes off in the hand }
  P := NewProbe(HandGrenadeSlot, 5);
  P.Run(5.0, True);
  Check((P.Count(geGrenadeBlowUp) = 1) and (P.Count(geGrenadeThrow) = 0) and
    SameValue(P.FirstTime(geGrenadeBlowUp), 1.1 + 3.2, 0.05),
    'held hand grenade blows up 3.2 s after the throw frame (4.3 s after the press)');
  FreeProbe(P);
end;

type
  TAttackProbe = class
    Attack: TMonsterAttack;
    Times: array of Single;
    Damage: Integer;
    Clock: Single;
    procedure OnFire(const ShotIndex: Integer);
    procedure Run(const Seq: TMonsterAttackSeq; const CanSee: Boolean);
  end;

procedure TAttackProbe.OnFire(const ShotIndex: Integer);
begin
  SetLength(Times, Length(Times) + 1);
  Times[High(Times)] := Clock;
  Damage := Damage + Attack.ShotDamage(ShotIndex);
end;

procedure TAttackProbe.Run(const Seq: TMonsterAttackSeq; const CanSee: Boolean);
begin
  Times := nil;
  Damage := 0;
  Clock := 0;
  Attack.Start(Seq, CanSee);
  while Attack.Active and (Clock < 30) do
  begin
    Clock := Clock + 0.01;
    Attack.Update(0.01, CanSee);
  end;
end;

{ Base of an MD2 frame name: attak203 -> attak2, att_c4 -> att_c }
function FrameBase(const N: String): String;
var
  Digits: Integer;
begin
  Digits := 0;
  while (Digits < Length(N)) and (N[Length(N) - Digits] in ['0'..'9']) do
    Inc(Digits);
  if Digits >= 3 then
    Result := Copy(N, 1, Length(N) - 2)
  else
    Result := Copy(N, 1, Length(N) - Digits);
end;

procedure TestMonsterAttacks;
const
  MonsterClasses: array[0..8] of String = ('monster_soldier_light', 'monster_soldier', 'monster_soldier_ss',
    'monster_infantry', 'monster_gunner', 'monster_berserk', 'monster_flyer', 'monster_parasite',
    'monster_tank');
var
  C: String;
  Seqs: TMonsterAttackSeqs;
  Seq: TMonsterAttackSeq;
  Mdl: TQuakeMd2;
  First, I: Integer;
  AllMatch: Boolean;
  P: TAttackProbe;
begin
  { Every sequence lies on the model frames of one Quake 2 animation }
  AllMatch := True;
  for C in MonsterClasses do
  begin
    Seqs := MonsterAttackSeqs(C);
    Mdl := Md2Manager.GetModel(FindMonsterDef(C)^.Model);
    if (Length(Seqs) = 0) or (Mdl = nil) then
    begin
      AllMatch := False;
      Writeln('  no attack table or model for ', C);
      Continue;
    end;
    for Seq in Seqs do
    begin
      First := Mdl.FrameNames.IndexOf(Seq.FirstFrame);
      if (First < 0) or (First + Seq.Count > Mdl.FrameCount) then
      begin
        AllMatch := False;
        Writeln('  ', C, ': frame ', Seq.FirstFrame, ' missing');
        Continue;
      end;
      for I := First to First + Seq.Count - 1 do
        if FrameBase(Mdl.FrameNames[I]) <> FrameBase(Seq.FirstFrame) then
        begin
          AllMatch := False;
          Writeln('  ', C, ': ', Seq.FirstFrame, ' + ', Seq.Count, ' runs into ', Mdl.FrameNames[I]);
          Break;
        end;
    end;
  end;
  Check(AllMatch, 'monster attack sequences match the demo models frame names');
  CheckEquals(0, Length(MonsterAttackSeqs('monster_supertank')), 'monsters without a table use the generic attack');

  { Range choice like the Quake 2 attack functions }
  Seqs := MonsterAttackSeqs('monster_infantry');
  CheckEquals(1, ChooseAttackSeq(Seqs, 50, 0.3), 'infantry swings its gun in melee range');
  CheckEquals(0, ChooseAttackSeq(Seqs, 400, 0.9), 'infantry fires its machinegun further away');
  Seqs := MonsterAttackSeqs('monster_gunner');
  CheckEquals(1, ChooseAttackSeq(Seqs, 50, 0.0), 'gunner uses the chaingun in melee range');
  Seqs := MonsterAttackSeqs('monster_flyer');
  CheckEquals(1, ChooseAttackSeq(Seqs, 50, 0.0), 'flyer slashes in melee range');
  CheckEquals(0, ChooseAttackSeq(Seqs, 400, 0.9), 'flyer shoots further away');
  { tank_attack: rockets only beyond 250 }
  Seqs := MonsterAttackSeqs('monster_tank');
  Check((ChooseAttackSeq(Seqs, 200, 0.5) <> 1) and (ChooseAttackSeq(Seqs, 100, 0.99) <> 1) and
    (ChooseAttackSeq(Seqs, 50, 0.6) <> 1), 'tank fires no rockets within 250 units');
  CheckEquals(1, ChooseAttackSeq(Seqs, 400, 0.5), 'tank fires rockets further away');

  P := TAttackProbe.Create;
  P.Attack := TMonsterAttack.Create;
  P.Attack.OnFire := @P.OnFire;
  try
    { Soldier attack1: one shot on its third frame, 1.2 s long }
    P.Run(MonsterAttackSeqs('monster_soldier_light')[0], True);
    Check((Length(P.Times) = 1) and SameValue(P.Times[0], 0.2, 0.011) and SameValue(P.Clock, 0.9, 0.02),
      'light soldier fires on attak103, then skips the cocking frames (0.9 s)');
    P.Run(MonsterAttackSeqs('monster_soldier')[0], True);
    Check((Length(P.Times) = 1) and SameValue(P.Clock, 1.2, 0.02), 'shotgun soldier: attack1 takes 1.2 s');
    { soldier_attack1_refire1: in melee range, fire again every 0.5 s }
    P.Attack.Melee := True;
    P.Run(MonsterAttackSeqs('monster_soldier_light')[0], True);
    P.Attack.Melee := False;
    Check((Length(P.Times) > 10) and SameValue(P.Times[1] - P.Times[0], 0.5, 0.011),
      'light soldier refires every 0.5 s in melee range');
    { Flyer melee: slashes on attak109 and attak114, 2.1 s; in melee
      range it keeps slashing (80 % a loop) }
    P.Run(MonsterAttackSeqs('monster_flyer')[1], True);
    Check((Length(P.Times) = 2) and SameValue(P.Times[0], 0.8, 0.011) and SameValue(P.Times[1], 1.3, 0.011) and
      SameValue(P.Clock, 2.1, 0.02), 'flyer slashes left and right once out of melee range');
    P.Attack.Melee := True;
    RandSeed := 1;
    P.Run(MonsterAttackSeqs('monster_flyer')[1], True);
    P.Attack.Melee := False;
    Check(Length(P.Times) > 2, 'flyer keeps slashing in melee range');
    { Machinegun soldier: only attack4 (+ attack3 for dodges, never chosen by range) }
    Seqs := MonsterAttackSeqs('monster_soldier_ss');
    Check((Length(Seqs) = 2) and (Seqs[0].FirstFrame = 'attak401') and (ChooseAttackSeq(Seqs, 400, 0.99) = 0) and
      (ChooseAttackSeq(Seqs, 40, 0.99) = 0), 'machinegun soldier attacks with attack4 only');
    { attack3 (duck and shoot): crouched, refires while the dodge pause lasts }
    Seqs := MonsterAttackSeqs('monster_soldier_light');
    P.Attack.PauseLeft := 1.0;
    P.Run(Seqs[High(Seqs)], True);
    Check((Seqs[High(Seqs)].Use = auDodge) and (Length(P.Times) = 2) and SameValue(P.Times[1], 0.6, 0.011),
      'duck-and-shoot fires twice in a 1 s dodge pause');
    P.Attack.Start(Seqs[High(Seqs)]);
    P.Attack.Update(0.25, True);
    Check(P.Attack.Ducked, 'crouched while shooting from the duck');
    { Tank machinegun: 19 bullets of 20 from attak406 }
    P.Run(MonsterAttackSeqs('monster_tank')[2], True);
    Check((Length(P.Times) = 19) and (P.Damage = 380) and SameValue(P.Times[0], 0.5, 0.011),
      'tank machinegun fires 19 bullets of 20');
    { Machinegun soldier: burst holding the frame, not when it lost sight }
    P.Run(MonsterAttackSeqs('monster_soldier_ss')[0], True);
    Check((Length(P.Times) >= 4) and (Length(P.Times) <= 11), 'machinegun soldier fires a 4 .. 11 bullet burst');
    P.Run(MonsterAttackSeqs('monster_soldier_ss')[0], False);
    CheckEquals(1, Length(P.Times), 'no burst without sight of the player');
    { Gunner grenades: four, 0.3 s apart }
    P.Run(MonsterAttackSeqs('monster_gunner')[0], True);
    Check((Length(P.Times) = 4) and SameValue(P.Times[0], 0.4, 0.011) and SameValue(P.Times[3], 1.3, 0.011),
      'gunner launches four grenades on attak105 .. 114');
    { Parasite drain: 5, then 2 a frame, 11 times }
    P.Run(MonsterAttackSeqs('monster_parasite')[0], True);
    Check((Length(P.Times) = 11) and (P.Damage = 25), 'parasite drains 5 then 2 a frame (25)');
    { Tank rockets: three, 0.3 s apart, after leaning in for 2.1 s }
    P.Run(MonsterAttackSeqs('monster_tank')[1], True);
    Check((Length(P.Times) = 3) and SameValue(P.Times[0], 2.1, 0.011), 'tank fires three rockets after 2.1 s');
  finally
    P.Attack.Free;
    P.Free;
  end;
end;

procedure TestTrace;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  Start, Floor: TVector3;
  T, Down: TQuakeTrace;
  I, Walls: Integer;
  Dirs: array[0..3] of TVector3;
  AllFree: Boolean;
begin
  Bsp := TQuakeBsp.Create;
  try
    if not Bsp.LoadFromPak('maps/demo1.bsp') then
    begin
      Check(False, 'load demo1 for traces');
      Exit;
    end;
    Check(Length(Bsp.Brushes) > 0, 'brushes loaded for collision');
    Col := TQuakeCollision.Create(Bsp);
    try
      { Player start: free, standing on a walkable floor }
      Start := Bsp.FindEntity('info_player_start').Origin;
      T := Col.BoxTrace(Start, Start, Mins, Maxs, 0, MASK_PLAYERSOLID);
      Check(not T.StartSolid, 'player box at the start is free');
      Down := Col.BoxTrace(Start, Start - Vector3(0, 0, 1000), Mins, Maxs, 0, MASK_PLAYERSOLID);
      Check((Down.Fraction < 1) and (Down.Normal.Z > 0.7) and not Down.StartSolid, 'trace down hits a walkable floor');
      Floor := Down.EndPos;
      Check(not Col.BoxTrace(Floor, Floor, Mins, Maxs, 0, MASK_PLAYERSOLID).StartSolid,
        'the end of a trace is a free position');
      Check(Col.BoxTrace(Floor, Floor - Vector3(0, 0, 0.25), Mins, Maxs, 0, MASK_PLAYERSOLID).Fraction < 1,
        'standing on it: 0.25 units down hits the ground (PM_CatagorizePosition)');
      { Walls all around within 4096 units, never passed through }
      Dirs[0] := Vector3(1, 0, 0);
      Dirs[1] := Vector3(-1, 0, 0);
      Dirs[2] := Vector3(0, 1, 0);
      Dirs[3] := Vector3(0, -1, 0);
      Walls := 0;
      AllFree := True;
      for I := 0 to 3 do
      begin
        T := Col.BoxTrace(Floor + Vector3(0, 0, 4), Floor + Vector3(0, 0, 4) + Dirs[I] * 4096, Mins, Maxs, 0,
          MASK_PLAYERSOLID);
        if (T.Fraction < 1) and (Abs(T.Normal.Z) < 0.7) then
          Inc(Walls);
        if Col.BoxTrace(T.EndPos, T.EndPos, Mins, Maxs, 0, MASK_PLAYERSOLID).StartSolid then
          AllFree := False;
      end;
      CheckEquals(4, Walls, 'horizontal traces stop at walls');
      Check(AllFree, 'traces stop in front of walls (DIST_EPSILON), not inside');
      { A point trace through the floor stops at it }
      T := Col.BoxTrace(Start, Start - Vector3(0, 0, 1000), TVector3.Zero, TVector3.Zero, 0, MASK_PLAYERSOLID);
      Check((T.Fraction < 1) and (T.EndPos.Z < Floor.Z) and (T.EndPos.Z > Floor.Z - 25), 'point trace hits the floor below the box');
    finally
      Col.Free;
    end;
  finally
    Bsp.Free;
  end;
  { Box against a box (monsters) }
  T := BoxTraceAgainstBox(Vector3(-100, 0, 0), Vector3(100, 0, 0), Mins, Maxs,
    Vector3(-16, -16, -24), Vector3(16, 16, 32), CONTENTS_MONSTER);
  Check((T.Fraction < 1) and SameValue(T.EndPos.X, -32, 0.1) and (T.Normal.X = -1), 'box trace stops at a monster box');
  T := BoxTraceAgainstBox(Vector3(0, 0, 0), Vector3(0, 0, 0), Mins, Maxs,
    Vector3(-16, -16, -24), Vector3(16, 16, 32), CONTENTS_MONSTER);
  Check(T.StartSolid and T.AllSolid, 'box inside a monster box is solid');
end;

procedure TestMonsterJump;
var
  Root: TCastleRootTransform;
  Floor: TCastleBox;
  Ent: TQuakeEntity;
  M: TQuakeMonster;
  I: Integer;
  MaxY, StartX: Single;
  Landed: Boolean;
begin
  { trigger_monsterjump: a soldier on a floor thrown with 200 forward and
    200 up flies about 100 units (0.5 s of flight under gravity 800) }
  Root := TCastleRootTransform.Create(nil);
  Ent := TQuakeEntity.Create;
  try
    Floor := TCastleBox.Create(Root);
    Floor.Size := Vector3(4000, 2, 4000);
    Floor.Translation := Vector3(0, -1, 0);
    Root.Add(Floor);
    Ent.SetField('classname', 'monster_soldier');
    M := TQuakeMonster.CreateMonster(Root, FindMonsterDef('monster_soldier'), Ent, Vector3(0, 24, 0), 0);
    try
      StartX := M.Transform.Translation.X;
      M.MonsterJump(Vector3(200, 0, 0), 200);
      Check(M.Jumping, 'monster on the ground takes off');
      MaxY := 0;
      Landed := False;
      for I := 1 to 100 do
      begin
        M.UpdateAI(0.01, Vector3(10000, 0, 0));
        MaxY := Max(MaxY, M.Transform.Translation.Y);
        if not M.Jumping then
        begin
          Landed := True;
          Break;
        end;
      end;
      Check(Landed and SameValue(M.Transform.Translation.Y, 24, 1), 'monster lands back on the floor');
      Check(SameValue(MaxY, 24 + 25, 3), 'jump peaks 25 units up (200^2 / 1600)');
      Check(SameValue(M.Transform.Translation.X - StartX, 100, 8), 'jump carries it ~100 units forward');
    finally
      M.Free;
    end;
  finally
    Ent.Free;
    Root.Free;
  end;
end;

procedure TestCurrents;
var
  V: TVector3;
begin
  { PM_AddCurrents }
  V := PMCurrentVelocity(0, 0, True, CONTENTS_SOLID or CONTENTS_CURRENT_90);
  Check(SameValue(V.Y, 100) and SameValue(V.X, 0), 'conveyor belt (CURRENT_90) moves the player 100 along +Y');
  V := PMCurrentVelocity(0, 0, False, CONTENTS_SOLID or CONTENTS_CURRENT_90);
  Check(V.IsZero, 'no conveyor push in the air');
  V := PMCurrentVelocity(CONTENTS_WATER or CONTENTS_CURRENT_180, 2, False, 0);
  Check(SameValue(V.X, -400), 'water current (CURRENT_180) pushes 400 along -X while swimming');
  V := PMCurrentVelocity(CONTENTS_WATER or CONTENTS_CURRENT_UP, 1, True, CONTENTS_SOLID);
  Check(SameValue(V.Z, 200), 'wading on the ground halves a water current');
end;

procedure TestGibs;
var
  V: TVector3;
  G: TMonsterGibs;
  P: TGibPiece;
  N: Integer;
begin
  { VelocityForDamage + ClipGibVelocity }
  V := GibVelocity(20, 1, 0, 0);
  Check(SameValue(V.X, 70) and SameValue(V.Z, -70) and SameValue(V.Y, 200), 'weak hits throw gibs at 0.7 speed, at least 200 up');
  V := GibVelocity(200, 1, 1, 1);
  Check(SameValue(V.X, 120) and SameValue(V.Y, 360), 'strong hits throw gibs at 1.2 speed');
  { Per-class gibs from the die functions }
  G := MonsterGibs('monster_soldier');
  N := 0;
  for P in G.Pieces do
    N := N + P.Count;
  Check((G.GibHealth = -30) and (N = 5), 'soldier: gib health -30, 5 pieces');
  G := MonsterGibs('monster_tank');
  Check((G.GibHealth = -200) and G.Pieces[High(G.Pieces)].Metallic, 'tank: gib health -200, metal gear head');
  Check(MonsterGibs('monster_flyer').Explodes, 'flyer explodes instead of leaving a corpse');
end;

procedure TestClock;
begin
  { func_clock_format_countdown and target_string_use }
  Check(ClockText(0, 7) = ' 7', 'clock style 0: seconds');
  Check(ClockText(1, 65) = ' 1:05', 'clock style 1: minutes and zero-padded seconds');
  Check(ClockText(2, 3725) = ' 1:02:05', 'clock style 2: hours, minutes, seconds');
  Check((CharacterFrame(' 1:05', 2) = 1) and (CharacterFrame(' 1:05', 3) = 11) and
    (CharacterFrame('-', 1) = 10), 'target_character frames: digits, colon, minus');
  Check((CharacterFrame(' 1:05', 1) = 12) and (CharacterFrame(' 1:05', 9) = 12), 'blank for spaces and past the end');
end;

procedure TestMonsterMoves;
const
  MonsterClasses: array[0..8] of String = ('monster_soldier_light', 'monster_soldier', 'monster_soldier_ss',
    'monster_infantry', 'monster_gunner', 'monster_berserk', 'monster_flyer', 'monster_parasite',
    'monster_tank');
var
  C: String;
  Run: Boolean;
  Seq: TMonsterMoveSeq;
  Mdl: TQuakeMd2;
  First, I: Integer;
  AllMatch: Boolean;
  Anim: TMonsterMoveAnim;
begin
  { Every walk / run loop lies on the frames of one model animation }
  AllMatch := True;
  for C in MonsterClasses do
  begin
    Mdl := Md2Manager.GetModel(FindMonsterDef(C)^.Model);
    for Run in Boolean do
    begin
      Seq := MonsterMoveSeq(C, Run);
      First := -1;
      if Mdl <> nil then
        First := Mdl.FrameNames.IndexOf(Seq.FirstFrame);
      if (Length(Seq.Dists) = 0) or (First < 0) or (First + Length(Seq.Dists) > Mdl.FrameCount) then
      begin
        AllMatch := False;
        Writeln('  ', C, ': move frames ', Seq.FirstFrame, ' missing');
        Continue;
      end;
      for I := First to First + High(Seq.Dists) do
        if FrameBase(Mdl.FrameNames[I]) <> FrameBase(Seq.FirstFrame) then
        begin
          AllMatch := False;
          Writeln('  ', C, ': ', Seq.FirstFrame, ' runs into ', Mdl.FrameNames[I]);
          Break;
        end;
    end;
  end;
  Check(AllMatch, 'monster walk / run loops match the demo models frame names');
  CheckEquals(0, Length(MonsterMoveSeq('monster_supertank', True).Dists), 'monsters without a move table keep their speed');
  { Quake 2 paces: 10 frames a second of ai_run distances }
  Check(SameValue(MoveSeqSpeed(MonsterMoveSeq('monster_soldier', True)), 121.67, 0.01) and
    SameValue(MoveSeqSpeed(MonsterMoveSeq('monster_tank', True)), 46.875, 0.01) and
    SameValue(MoveSeqSpeed(MonsterMoveSeq('monster_parasite', True)), 254.29, 0.01),
    'soldier runs 122, tank 47, parasite 254 units a second');
  Anim := TMonsterMoveAnim.Create;
  try
    Anim.Start(MonsterMoveSeq('monster_infantry', True));
    Anim.Update(0.25);
    Check((Anim.Frame = 2) and SameValue(Anim.Speed, 50) and SameValue(Anim.FrameLerp, 0.5, 0.01),
      'infantry run: frame 3 after 0.25 s moves 5 a frame');
    Anim.Update(0.6);
    CheckEquals(0, Anim.Frame, 'the run loop wraps around');
  finally
    Anim.Free;
  end;
end;

{ A small level: room A (floor 0, ceiling 128) and room B east of it one
  step up (floor 16, ceiling 192, part sky), a light in A }
function MakeTestLevel: TQuakeLevel;
var
  X, Y: Integer;
begin
  Result := TQuakeLevel.Create(10, 8);
  Result.Name := 'unittest_level';
  for Y := 1 to 6 do
  begin
    for X := 1 to 4 do
      Result.SetOpen(X, Y, 0, 128);
    for X := 5 to 8 do
      Result.SetOpen(X, Y, 16, 192, 1);
  end;
  Result.Cell(7, 3)^.Sky := True;
  Result.AddEntityAtCell('info_player_start', 2, 3, 0);
  Result.AddEntityAtCell('light', 2, 3).SetKey('light', '300');
  Result.AddEntityAtCell('monster_soldier', 7, 4, 180);
end;

procedure TestLevelBsp;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level, Loaded: TQuakeLevel;
  MapName: String;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  Color: TVector3;
  Stream: TMemoryStream;
  Stats: TBspBuildStats;
begin
  Level := MakeTestLevel;
  try
    { JSON round trip }
    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check((Loaded.Width = 10) and (Loaded.Height = 8) and (Loaded.Cell(7, 3)^.Sky) and
        (Loaded.Cell(5, 2)^.Floor = 16) and (Loaded.Cell(5, 2)^.Theme = 1) and Loaded.Cell(0, 0)^.Solid and
        (Loaded.Entities.Count = 3) and (Loaded.Entities[1].Key('light') = '300'),
        'level JSON saves and loads cells and entities');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    Stream := BuildLevelBsp(Level, Stats);
    Stream.Free;
    { One region per uniform rectangle: room A, room B split around its sky cell }
    Check((Stats.Clusters >= 2) and (Stats.Faces > 0) and (Stats.LightBytes > 0), 'level builds into a BSP');

    MapName := RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/' + MapName + '.bsp'), 'the built level loads as a Quake 2 map');
      Check((Bsp.ModelCount = 1) and (Bsp.ClusterCount = Stats.Clusters) and
        (Bsp.FindEntity('monster_soldier') <> nil) and (Bsp.FindEntity('info_player_start') <> nil),
        'built map: one model, its clusters and the level''s entities');
      Check((Bsp.PointContents(Vector3(160, 224, 64)) and CONTENTS_SOLID) = 0, 'room A is empty');
      Check((Bsp.PointContents(Vector3(32, 224, 64)) and CONTENTS_SOLID) <> 0, 'the wall cell is solid');
      Check((Bsp.PointContents(Vector3(160, 224, -8)) and CONTENTS_SOLID) <> 0, 'below the floor is solid');
      Check((Bsp.PointContents(Vector3(400, 224, 160)) and CONTENTS_SOLID) = 0, 'room B is higher');
      Col := TQuakeCollision.Create(Bsp);
      try
        T := Col.BoxTrace(Vector3(160, 224, 64), Vector3(160, 224, -200), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and SameValue(T.EndPos.Z, 24, 0.2) and (T.Normal.Z > 0.9),
          'the player stands on room A''s floor (origin 24 above it)');
        T := Col.BoxTrace(Vector3(160, 224, 24), Vector3(160, 224, 300), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(SameValue(T.EndPos.Z, 128 - 32, 0.2), 'room A''s ceiling stops the player');
        T := Col.BoxTrace(Vector3(160, 224, 24.1), Vector3(-200, 224, 24.1), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(SameValue(T.EndPos.X, 64 + 16, 0.2), 'the west wall stops the player');
        T := Col.BoxTrace(Vector3(160, 224, 24.1), Vector3(500, 224, 24.1), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(SameValue(T.EndPos.X, 320 - 16, 0.2) and (T.Normal.X < -0.9),
          'the 16 unit step up to room B blocks a flat move (pmove steps up)');
        T := Col.BoxTrace(Vector3(160, 224, 44), Vector3(500, 224, 44), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(T.Fraction = 1, 'above the step the player walks into room B');
      finally
        Col.Free;
      end;
      Check(Bsp.LightPoint(Vector3(160, 224, 40), Color) and (Color.X > 0.3),
        'models in room A are lit by the light (R_LightPoint finds the lightmap)');
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

{ Compiled levels get a grid PVS: rooms behind walls or around corners are
  out of it, a straight corridor joins them }
procedure TestLevelVis;
var
  Level: TQuakeLevel;
  Bsp: TQuakeBsp;
  Stats: TBspBuildStats;
  X, Y: Integer;

  function ClusterAt(const CX, CY: Integer): Integer;
  begin
    Result := Bsp.LeafCluster(Bsp.PointLeaf(Vector3((CX + 0.5) * LevelCellSize, (CY + 0.5) * LevelCellSize, 40)));
  end;

  function Sees(const Phs: Boolean; const AX, AY, BX, BY: Integer): Boolean;
  var
    Row: TBytes;
    C: Integer;
  begin
    if Phs then
      Bsp.ClusterPHS(ClusterAt(AX, AY), Row)
    else
      Bsp.ClusterPVS(ClusterAt(AX, AY), Row);
    C := ClusterAt(BX, BY);
    Result := (C >= 0) and ((Row[C shr 3] and (1 shl (C and 7))) <> 0);
  end;

  function Load(const Name: String): Boolean;
  begin
    Level.Name := Name;
    FreeAndNil(Bsp);
    Bsp := TQuakeBsp.Create;
    Result := Bsp.LoadFromPak('maps/' + RegisterLevelMap(Level) + '.bsp');
  end;

begin
  Bsp := nil;
  Level := TQuakeLevel.Create(16, 16);
  try
    { Room A (1..4, 1..4), room B (9..12, 1..4) behind a wall; room C
      (9..12, 8..12) reached from A by a corridor turning a corner }
    for Y := 1 to 4 do
      for X := 1 to 4 do
      begin
        Level.SetOpen(X, Y, 0, 128);
        Level.SetOpen(X + 8, Y, 0, 128);
      end;
    for Y := 8 to 12 do
      for X := 9 to 12 do
        Level.SetOpen(X, Y, 0, 128);
    for Y := 5 to 10 do
      Level.SetOpen(2, Y, 0, 128);
    for X := 3 to 8 do
      Level.SetOpen(X, 10, 0, 128);
    Level.AddEntityAtCell('info_player_start', 2, 2, 0);
    Check(Load('unittest_vis'), 'the vis test level loads');
    Check((ClusterAt(2, 2) >= 0) and (ClusterAt(10, 2) >= 0) and (ClusterAt(10, 10) >= 0),
      'rooms and corridors have clusters');
    Check(Sees(False, 2, 2, 3, 3) and Sees(False, 2, 2, 2, 6) and Sees(False, 2, 9, 5, 10),
      'a room sees itself and the corridor leaving it, the corridor its bend');
    Check((not Sees(False, 2, 2, 10, 2)) and not Sees(False, 10, 2, 2, 2),
      'rooms behind a wall are out of each other''s PVS');
    Check(not Sees(False, 2, 2, 10, 10), 'a room around a corner is out of the PVS');
    Check(Sees(True, 2, 6, 10, 10) and not Sees(True, 2, 2, 10, 2),
      'the PHS reaches one room further (the corridor hears room C), not through walls');

    { A straight corridor between A and B: they see each other }
    for X := 5 to 8 do
      Level.SetOpen(X, 2, 0, 128);
    Check(Load('unittest_vis2') and Sees(False, 2, 2, 10, 2) and Sees(False, 1, 1, 12, 3) and
      not Sees(False, 2, 2, 10, 10),
      'a straight corridor joins the PVS of both rooms');

    BuildLevelBsp(Level, Stats).Free;
    Check((Stats.VisPercent > 0) and (Stats.VisPercent < 100), 'the build reports the share of visible clusters');
  finally
    Bsp.Free;
    Level.Free;
  end;
end;

procedure TestLevelDoorsWater;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level: TQuakeLevel;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  Door: TQuakeEntity;
  X, Y: Integer;
begin
  { Room A (x 1..4) and room B (x 6..11) joined at x 5 by a 2-cell door
    (y 3..4); a pool (floor -64, water up to -8) in room B }
  Level := TQuakeLevel.Create(14, 8);
  try
    Level.Name := 'unittest_doors';
    for Y := 1 to 6 do
    begin
      for X := 1 to 4 do
        Level.SetOpen(X, Y, 0, 128);
      for X := 6 to 11 do
        Level.SetOpen(X, Y, 0, 128);
    end;
    for Y := 3 to 4 do
    begin
      Level.SetOpen(5, Y, 0, 128);
      Level.Cell(5, Y)^.Door := True;
    end;
    for Y := 2 to 4 do
      for X := 8 to 10 do
      begin
        Level.Cell(X, Y)^.Floor := -64;
        Level.Cell(X, Y)^.Wet := True;
        Level.Cell(X, Y)^.Water := -8;
      end;
    Level.AddEntityAtCell('info_player_start', 2, 3);
    Level.AddEntityAtCell('light', 3, 3);
    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_doors.bsp'), 'a level with a door and water builds and loads');
      Check(Bsp.ModelCount = 2, 'the door is a brush model (*1)');
      Door := Bsp.FindEntity('func_door');
      Check((Door <> nil) and (Door.Model = '*1') and SameValue(Door.Angle, -1), 'the door is a func_door moving up');
      Check((Bsp.PointContents(Vector3(9 * 64 + 32, 3 * 64 + 32, -20)) and CONTENTS_WATER) <> 0,
        'the pool is water');
      Check((Bsp.PointContents(Vector3(9 * 64 + 32, 3 * 64 + 32, 40)) and CONTENTS_WATER) = 0,
        'above the pool is air');
      Col := TQuakeCollision.Create(Bsp);
      try
        T := Col.BoxTrace(Vector3(160, 224, 25), Vector3(450, 224, 25), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(T.Fraction = 1, 'the world is open where the door is');
        T := Col.BoxTrace(Vector3(160, 224, 25), Vector3(450, 224, 25), Mins, Maxs,
          Bsp.Models[1].HeadNode, MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and SameValue(T.EndPos.X, 5 * 64 - 16, 0.2), 'the closed door blocks the doorway');
        Check((Col.PointContents(Vector3(9 * 64 + 32, 3 * 64 + 32, -20), 0) and CONTENTS_WATER) <> 0,
          'the pool has a water brush');
      finally
        Col.Free;
      end;
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

{ Slime, key doors (a lock per key: one trigger_key opens all its doors)
  and teleporters linked in order }
procedure TestLevelKeysSlime;
var
  Level, Loaded: TQuakeLevel;
  Bsp: TQuakeBsp;
  E: TQuakeEntity;
  X, Y, KeyTriggers, Touchers, KeyDoorCount: Integer;
  Stream: TMemoryStream;
  TeleOk: Boolean;
  Dests: TQuakeEntityList;
begin
  { Room A (1..4), a blue key door at x 5 (rows 1-2 and 4-5: two doors),
    room B (6..10); slime in A; a teleporter in A to B }
  Level := TQuakeLevel.Create(12, 8);
  try
    Level.Name := 'unittest_keys';
    for Y := 1 to 6 do
      for X := 1 to 10 do
        Level.SetOpen(X, Y, 0, 160);
    for Y := 1 to 6 do
      if Y <> 3 then
      begin
        Level.Cell(5, Y)^.Door := True;
        Level.Cell(5, Y)^.Key := 1;
      end
      else
        Level.Cell(5, Y)^.Solid := True;
    for Y := 5 to 6 do
      for X := 2 to 3 do
      begin
        Level.Cell(X, Y)^.Floor := -32;
        Level.Cell(X, Y)^.Wet := True;
        Level.Cell(X, Y)^.Slime := True;
        Level.Cell(X, Y)^.Water := -16;
      end;
    Level.AddEntityAtCell('info_player_start', 2, 2);
    Level.AddEntityAtCell('misc_teleporter', 3, 3);
    Level.AddEntityAtCell('misc_teleporter_dest', 8, 3);

    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check(Loaded.Cell(2, 5)^.Slime and CellHasWater(Loaded.Cell(2, 5)) and Loaded.Cell(5, 1)^.Door and
        (Loaded.Cell(5, 1)^.Key = 1) and (Loaded.Cell(5, 1)^.Channel = 0) and not Loaded.Cell(4, 1)^.Slime,
        'slime and key doors save and load');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_keys.bsp'), 'the key / slime level loads');
      Check((Bsp.PointContents(Vector3(2.5 * 64, 5.5 * 64, -24)) and CONTENTS_SLIME) <> 0,
        'slime cells are CONTENTS_SLIME');
      KeyTriggers := 0;
      Touchers := 0;
      KeyDoorCount := 0;
      TeleOk := False;
      for E in Bsp.Entities do
      begin
        if E.ClassName = 'trigger_key' then
        begin
          Inc(KeyTriggers);
          Check((E.GetField('item') = 'key_blue_key') and (E.Target = 'keydoor1') and (E.TargetName = 'keylock1'),
            'the blue key''s trigger_key opens the blue doors');
        end;
        if (E.ClassName = 'trigger_multiple') and (E.Target = 'keylock1') and (Copy(E.Model, 1, 1) = '*') then
          Inc(Touchers);
        if (E.ClassName = 'func_door') and (E.TargetName = 'keydoor1') then
          Inc(KeyDoorCount);
        if (E.ClassName = 'misc_teleporter') and (E.Target = 'teleport1') then
        begin
          Dests := Bsp.FindByTargetName('teleport1');
          TeleOk := (Dests.Count = 1) and (Dests[0].ClassName = 'misc_teleporter_dest');
          Dests.Free;
        end;
      end;
      Check((KeyDoorCount = 2) and (Touchers = 2) and (KeyTriggers = 1),
        'two locked doors, a touch trigger each, one trigger_key for their key');
      Check(TeleOk, 'a teleporter without a target goes to the destination of its number');
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

{ Ladders (a solid ladder brush against the step, for the player only)
  and lava (CONTENTS_LAVA, a texture made in memory) }
procedure TestLevelLaddersLava;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level, Loaded: TQuakeLevel;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  X, Y: Integer;
  Stream: TMemoryStream;
begin
  { Room A (1..4, floor 0), a ledge (6..8, floor 128) beyond x 5; a ladder
    in (4, 3) up the ledge's step at x 5 (floor 128 too); lava in (2, 5) }
  Level := TQuakeLevel.Create(10, 8);
  try
    Level.Name := 'unittest_ladder';
    for Y := 1 to 6 do
    begin
      for X := 1 to 4 do
        Level.SetOpen(X, Y, 0, 256);
      for X := 5 to 8 do
        Level.SetOpen(X, Y, 128, 256);
    end;
    Level.Cell(4, 3)^.Ladder := True;
    Level.Cell(2, 5)^.Floor := -32;
    Level.Cell(2, 5)^.Wet := True;
    Level.Cell(2, 5)^.Lava := True;
    Level.Cell(2, 5)^.Water := -16;
    Level.AddEntityAtCell('info_player_start', 2, 2);
    Check(Level.LadderDir(4, 3) = 0, 'the ladder climbs to the higher neighbour (+X)');
    Check(Level.LadderDir(2, 2) = -1, 'no ladder direction without a step');

    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check(Loaded.Cell(4, 3)^.Ladder and Loaded.Cell(2, 5)^.Lava and CellHasWater(Loaded.Cell(2, 5)) and
        not Loaded.Cell(2, 5)^.Slime, 'ladders and lava save and load');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_ladder.bsp') and Pak.FileExists('textures/' + LevelLavaTexture + '.wal'),
        'the ladder / lava level loads, with the lava texture made in memory');
      Check((Bsp.PointContents(Vector3(2.5 * 64, 5.5 * 64, -24)) and CONTENTS_LAVA) <> 0, 'lava cells are CONTENTS_LAVA');
      Check(Bsp.PointInLadder(Vector3(5 * 64 - 4, 3.5 * 64, 64)) and not Bsp.PointInLadder(Vector3(5 * 64 - 4, 3.5 * 64, 140)),
        'the ladder brush stands against the step, up to its top');
      Col := TQuakeCollision.Create(Bsp);
      try
        T := Col.BoxTrace(Vector3(4 * 64, 3.5 * 64, 40), Vector3(5 * 64, 3.5 * 64, 40), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check(SameValue(T.EndPos.X, 5 * 64 - LevelLadderDepth - 16, 0.2) and ((T.Contents and CONTENTS_LADDER) <> 0),
          'the player bumps into the ladder (CONTENTS_LADDER, Quake 2''s ladder test)');
        T := Col.BoxTrace(Vector3(4 * 64, 3.5 * 64, 40), Vector3(5 * 64, 3.5 * 64, 40), Mins, Maxs, 0, MASK_MONSTERSOLID);
        Check(SameValue(T.EndPos.X, 5 * 64 - 16, 0.2), 'monsters walk up to the wall behind it');
      finally
        Col.Free;
      end;
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

{ Ramps: a sloped floor node and wedge brush, walkable }
procedure TestLevelRamps;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level, Loaded: TQuakeLevel;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  Color: TVector3;
  X, Y: Integer;
  Stream: TMemoryStream;
begin
  { Floor 0 (x 1..3), a ramp in x 4 rising to floor 32 (x 5..8) }
  Level := TQuakeLevel.Create(10, 6);
  try
    Level.Name := 'unittest_ramp';
    for Y := 1 to 4 do
    begin
      for X := 1 to 4 do
        Level.SetOpen(X, Y, 0, 192);
      for X := 5 to 8 do
        Level.SetOpen(X, Y, 32, 192);
      Level.Cell(4, Y)^.Ramp := True;
    end;
    Level.AddEntityAtCell('info_player_start', 2, 2);
    Level.AddEntityAtCell('light', 4, 2).SetKey('light', '400');
    Check((Level.RampDir(4, 2) = 0) and (Level.RampDir(2, 2) = -1), 'a ramp rises towards its higher neighbour');
    Check(SameValue(Level.FloorAt(4, 2, 4.5 * 64, 2.5 * 64), 16, 0.01) and SameValue(Level.FloorAt(4, 2, 5 * 64, 0), 32, 0.01),
      'the floor of a ramp slopes along it');
    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check(Loaded.Cell(4, 3)^.Ramp and not Loaded.Cell(3, 3)^.Ramp, 'ramps save and load');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_ramp.bsp'), 'the ramp level loads');
      Col := TQuakeCollision.Create(Bsp);
      try
        { Dropping onto the middle of the ramp: its box corner touches at
          x 4.5 * 64 - 16 (floor 8 there; box bottom 24 below the origin) }
        T := Col.BoxTrace(Vector3(4.5 * 64, 2.5 * 64, 120), Vector3(4.5 * 64, 2.5 * 64, -50), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and SameValue(T.EndPos.Z, 24 + 24, 0.5) and (T.Normal.Z > 0.7) and (T.Normal.Z < 0.99),
          'the player lands on the slope (a walkable, tilted plane)');
        T := Col.BoxTrace(Vector3(2 * 64, 2.5 * 64, 24.1), Vector3(7 * 64, 2.5 * 64, 24.1), Mins, Maxs, 0, MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and (T.Normal.Z > 0.7), 'walking into the ramp meets its slope, not a wall');
      finally
        Col.Free;
      end;
      Check(Bsp.LightPoint(Vector3(4.5 * 64, 2.5 * 64, 40), Color) and (Color.X > 0.2),
        'models on the ramp are lit by its lightmap (R_LightPoint on the sloped node)');
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

{ Windows: a glass pane that stops shots and the player, not sight }
procedure TestLevelWindows;
var
  Level, Loaded: TQuakeLevel;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  X, Y: Integer;
  Stream: TMemoryStream;
  Report: TLevelGenReport;
  Seed: Cardinal;
  Windows: Integer;
begin
  { Rooms A (x 1..4) and B (x 6..9) behind a wall at x 5 with a window in
    (5, 3): sill 48, top 144 }
  Level := TQuakeLevel.Create(11, 7);
  try
    Level.Name := 'unittest_window';
    for Y := 1 to 5 do
      for X := 1 to 9 do
        if X <> 5 then
          Level.SetOpen(X, Y, 0, 192);
    Level.SetOpen(5, 3, 48, 144);
    Level.Cell(5, 3)^.Window := True;
    Level.AddEntityAtCell('info_player_start', 2, 3);
    Check(Level.WindowAxis(5, 3) = 0, 'the window looks along X (open on both sides)');
    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check(Loaded.Cell(5, 3)^.Window and (Loaded.Cell(5, 3)^.Floor = 48), 'windows save and load');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_window.bsp'), 'the window level loads');
      Col := TQuakeCollision.Create(Bsp);
      try
        T := Col.BoxTrace(Vector3(3 * 64, 3.5 * 64, 96), Vector3(8 * 64, 3.5 * 64, 96), TVector3.Zero, TVector3.Zero,
          0, MASK_SHOT);
        Check((T.Fraction < 1) and SameValue(T.EndPos.X, 5.5 * 64 - LevelWindowThickness / 2, 0.2) and
          ((T.Contents and CONTENTS_WINDOW) <> 0), 'shots stop at the glass');
        T := Col.BoxTrace(Vector3(3 * 64, 3.5 * 64, 96), Vector3(8 * 64, 3.5 * 64, 96), TVector3.Zero, TVector3.Zero,
          0, MASK_OPAQUE);
        Check(T.Fraction = 1, 'sight passes the glass (monsters see through windows)');
        T := Col.BoxTrace(Vector3(3 * 64, 3.5 * 64, 40), Vector3(8 * 64, 3.5 * 64, 40), TVector3.Zero, TVector3.Zero,
          0, MASK_OPAQUE);
        Check(T.Fraction < 1, 'below the sill is wall');
      finally
        Col.Free;
      end;
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;

  Windows := 0;
  for Seed := 1 to 12 do
  begin
    Level := GenerateLevel(Seed, DefaultLevelGenOptions, Report);
    Inc(Windows, Report.Windows);
    Level.Free;
  end;
  Check(Windows > 0, 'random levels have windows between areas');
end;

procedure TestLevelLiftsSwitches;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level, Loaded: TQuakeLevel;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  E: TQuakeEntity;
  X, Y, Plat, Button, Door: Integer;
  Stream: TMemoryStream;
begin
  { Room A (floor 0) with a 2-cell lift up to 128 and a button (channel 2);
    a door of channel 2 at x 5 into room B }
  Level := TQuakeLevel.Create(14, 8);
  try
    Level.Name := 'unittest_lifts';
    for Y := 1 to 6 do
    begin
      for X := 1 to 4 do
        Level.SetOpen(X, Y, 0, 256);
      for X := 6 to 11 do
        Level.SetOpen(X, Y, 0, 128);
    end;
    for Y := 3 to 4 do
    begin
      Level.SetOpen(5, Y, 0, 128);
      Level.Cell(5, Y)^.Door := True;
      Level.Cell(5, Y)^.Channel := 2;
    end;
    for Y := 1 to 2 do
    begin
      Level.Cell(1, Y)^.Lift := True;
      Level.Cell(1, Y)^.LiftTop := 128;
    end;
    Level.Cell(3, 5)^.Button := True;
    Level.Cell(3, 5)^.Channel := 2;
    Level.AddEntityAtCell('info_player_start', 2, 3);

    Stream := TMemoryStream.Create;
    Loaded := TQuakeLevel.Create(3, 3);
    try
      Level.SaveToStream(Stream);
      Stream.Position := 0;
      Loaded.LoadFromStream(Stream);
      Check(Loaded.Cell(1, 2)^.Lift and (Loaded.Cell(1, 2)^.LiftTop = 128) and Loaded.Cell(3, 5)^.Button and
        (Loaded.Cell(3, 5)^.Channel = 2) and Loaded.Cell(5, 3)^.Door and (Loaded.Cell(5, 3)^.Channel = 2),
        'lifts, buttons and switch channels save and load');
    finally
      Loaded.Free;
      Stream.Free;
    end;

    RegisterLevelMap(Level);
    Bsp := TQuakeBsp.Create;
    try
      Check(Bsp.LoadFromPak('maps/unittest_lifts.bsp') and (Bsp.ModelCount = 4),
        'a door, a lift and a button: three brush models');
      Plat := -1; Button := -1; Door := -1;
      for E in Bsp.Entities do
        if E.ClassName = 'func_plat' then
          Plat := StrToIntDef(Copy(E.Model, 2, 9), -1)
        else
        if E.ClassName = 'func_button' then
        begin
          Button := StrToIntDef(Copy(E.Model, 2, 9), -1);
          Check((E.Target = 'switch2') and SameValue(E.Angle, -2), 'the button fires its channel, pressed down');
        end else
        if E.ClassName = 'func_door' then
        begin
          Door := StrToIntDef(Copy(E.Model, 2, 9), -1);
          Check((E.TargetName = 'switch2') and SameValue(E.GetFloat('wait', 0), -1),
            'the channel''s door waits for its button and stays open');
        end;
      E := Bsp.FindEntity('func_plat');
      Check((Plat > 0) and (Button > 0) and (Door > 0) and (E <> nil) and (E.GetInt('height', 0) = 130),
        'the lift goes from 128 down to just under the floor');
      Col := TQuakeCollision.Create(Bsp);
      try
        { The lift model is built up: a slab with its top at 128 }
        T := Col.BoxTrace(Vector3(96, 96, 200), Vector3(96, 96, 0), Mins, Maxs, Bsp.Models[Plat].HeadNode,
          MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and SameValue(T.EndPos.Z, 128 + 24, 0.2), 'the lift slab is solid at its top');
        { The button pedestal (40 high) in the middle of its cell }
        T := Col.BoxTrace(Vector3(160, 352, 25), Vector3(250, 352, 25), Mins, Maxs, Bsp.Models[Button].HeadNode,
          MASK_PLAYERSOLID);
        Check((T.Fraction < 1) and SameValue(T.EndPos.X, 224 - 12 - 16, 0.2), 'the button pedestal is solid');
      finally
        Col.Free;
      end;
    finally
      Bsp.Free;
    end;
  finally
    Level.Free;
  end;
end;

procedure TestLevelGen;
const
  Mins: TVector3 = (X: -16; Y: -16; Z: -24);
  Maxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Level: TQuakeLevel;
  Report: TLevelGenReport;
  Seed: Cardinal;
  AllOk, Same: Boolean;
  Start: TLevelEntity;
  E: TLevelEntity;
  SX, SY, KX, KY, Monsters, Lifts, Switches, Doors, Pools, KeyDoors, Slime, Teleporters: Integer;
  Ladders, Lava, Outdoor, RX, RY, Vaults: Integer;
  Ok1: Boolean;
  KeyOk: Boolean;
  A, B: TMemoryStream;
  Bsp: TQuakeBsp;
  Col: TQuakeCollision;
  T: TQuakeTrace;
  P: TVector3;
begin
  AllOk := True;
  Lifts := 0;
  Switches := 0;
  Doors := 0;
  Pools := 0;
  KeyDoors := 0;
  Slime := 0;
  Teleporters := 0;
  Ladders := 0;
  Lava := 0;
  Outdoor := 0;
  Vaults := 0;
  KeyOk := True;
  for Seed := 1 to 12 do
  begin
    Level := GenerateLevel(Seed, DefaultLevelGenOptions, Report);
    Inc(Lifts, Report.Lifts);
    Inc(Switches, Report.Switches);
    Inc(Doors, Report.Doors);
    Inc(Pools, Report.Pools);
    Inc(KeyDoors, Report.KeyDoors);
    Inc(Slime, Report.SlimePools);
    Inc(Teleporters, Report.Teleporters);
    Inc(Ladders, Report.Ladders);
    Inc(Lava, Report.LavaPools);
    Inc(Outdoor, Report.OutdoorRooms);
    try
      Start := nil;
      Monsters := 0;
      for E in Level.Entities do
      begin
        if E.EntClass = 'info_player_start' then
          Start := E;
        if Copy(E.EntClass, 1, 8) = 'monster_' then
          Inc(Monsters);
      end;
      if Start = nil then
      begin
        AllOk := False;
        Writeln('  seed ', Seed, ': no player start');
        Continue;
      end;
      Level.CellAt(Start.Origin, SX, SY);
      { The key hunt: one key opens the exit (its key on the near side of
        the exit's doors), or the red key (reachable with every locked door
        shut) opens the vault of the blue key }
      if Report.KeyDoors > 0 then
      begin
        KX := -1;
        RX := -1;
        for E in Level.Entities do
          if E.EntClass = 'key_blue_key' then
            Level.CellAt(E.Origin, KX, KY)
          else
          if E.EntClass = 'key_red_key' then
            Level.CellAt(E.Origin, RX, RY);
        if Report.KeyDoors = 1 then
          Ok1 := (KX >= 0) and (RX < 0) and ReachableWithLockedDoors(Level, SX, SY, KX, KY)
        else
        begin
          Ok1 := (KX >= 0) and (RX >= 0) and ReachableWithLockedDoors(Level, SX, SY, RX, RY, [1, 2]) and
            not ReachableWithLockedDoors(Level, SX, SY, KX, KY, [1, 2]) and
            ReachableWithLockedDoors(Level, SX, SY, KX, KY, [1]);
          Inc(Vaults);
        end;
        if (not Ok1) or (Seed mod 2 <> 0) then
        begin
          KeyOk := False;
          Writeln('  seed ', Seed, ': keys (', Report.KeyDoors, ') blue at ', KX, ' ', KY, ' red at ', RX, ' ', RY,
            ' in the wrong order');
        end;
      end;
      if (Report.Rooms < 6) or (Monsters < 5) or (UnreachableCells(Level, SX, SY) > 0) or
         (Level.Entities.Count < 20) then
      begin
        AllOk := False;
        Writeln('  seed ', Seed, ': rooms ', Report.Rooms, ' monsters ', Monsters, ' unreachable ',
          UnreachableCells(Level, SX, SY));
      end;
    finally
      Level.Free;
    end;
  end;
  Check(AllOk, 'random levels: 6+ rooms, monsters, every open cell reachable from the start');
  Check((Lifts > 0) and (Switches > 0) and (Doors > 0) and (Pools > 0),
    'random levels have lifts, exit switches, doors and pools');
  Check((KeyDoors > 0) and KeyOk, 'even seeds lock the exit with a blue key reachable with the doors shut');
  Check(Vaults > 0, 'some levels keep the blue key in a vault behind red doors, its red key in the open');
  Check((Slime > 0) and (Teleporters > 0), 'random levels have slime pits and secret room teleporters');
  Check((Ladders > 0) and (Lava > 0) and (Outdoor > 0), 'random levels have ladders, lava pits and outdoor rooms (all reachable)');

  { The same seed makes the same level }
  A := TMemoryStream.Create;
  B := TMemoryStream.Create;
  try
    Level := GenerateLevel(5);
    Level.SaveToStream(A);
    Level.Free;
    Level := GenerateLevel(5);
    Level.SaveToStream(B);
    Level.Free;
    Same := (A.Size = B.Size) and CompareMem(A.Memory, B.Memory, A.Size);
    Check(Same, 'a seed always makes the same level');
  finally
    A.Free;
    B.Free;
  end;

  { rand<seed> maps are generated on demand, the player stands at the start }
  Bsp := TQuakeBsp.Create;
  try
    Check(Bsp.LoadFromPak('maps/' + RandomMapName(7) + '.bsp'), 'rand7 is generated when loaded');
    Col := TQuakeCollision.Create(Bsp);
    try
      P := Bsp.FindEntity('info_player_start').Origin;
      T := Col.BoxTrace(P, P - Vector3(0, 0, 500), Mins, Maxs, 0, MASK_PLAYERSOLID);
      Check((not T.StartSolid) and (T.Fraction < 1) and (T.Normal.Z > 0.9) and (Abs(T.EndPos.Z - P.Z) < 2),
        'the player starts on a floor of the random level');
    finally
      Col.Free;
    end;
  finally
    Bsp.Free;
  end;
end;

procedure TestMapLevelUrl;
var
  Level: TQuakeLevel;
  Map: TQuakeMap;
begin
  { What the CGE editor shows: a level file through TQuakeMap.LevelUrl, a
    random level through MapName }
  Level := MakeTestLevel;
  try
    Level.SaveToFile('castle-config:/levels/unittest_map.json');
  finally
    Level.Free;
  end;
  Map := TQuakeMap.Create(nil);
  try
    Map.PakUrl := 'castle-data:/paks/quake2_demo.pak';
    Map.LevelUrl := 'castle-config:/levels/unittest_map.json';
    Check((Map.Bsp <> nil) and (Map.FaceCount > 0) and (Map.EntityCount >= 3),
      'TQuakeMap.LevelUrl builds a level of the editor (its 3 entities and worldspawn)');
    Map.MapName := RandomMapName(3);
    Check((Map.Bsp <> nil) and (Map.Bsp.MapName = 'rand3') and (Map.FaceCount > 100),
      'TQuakeMap.MapName rand3 shows random level 3');
  finally
    Map.Free;
  end;
end;

procedure TestTurret;
var
  L: TTurretLimits;
  P, Y, DP, DY: Single;
  Off, F, R, U, Fwd: TVector3;
begin
  { g_turret.c defaults and angle rules }
  L := TurretLimits(0, 0, 0, 0);
  Check(SameValue(L.Pos1Pitch, 30) and SameValue(L.Pos2Pitch, -30) and SameValue(L.Pos2Yaw, 360),
    'turret limits default to pitch -30..30, yaw 0..360');
  QuakeVecToAngles(Vector3(1, 0, 1), P, Y);
  Check(SameValue(P, -45) and SameValue(Y, 0), 'vectoangles: up is negative pitch');
  QuakeVecToAngles(Vector3(0, -1, 0), P, Y);
  Check(SameValue(Y, 270), 'vectoangles: -Y is yaw 270');
  P := -60; Y := 0;
  TurretClampAngles(P, Y, L);
  Check(SameValue(P, -30), 'turret aims at most 30 degrees up');
  P := 0; Y := 100;
  TurretClampAngles(P, Y, TurretLimits(0, 0, 0, 90));
  Check(SameValue(Y, 90), 'turret yaw clamped to maxyaw');
  P := 0; Y := 350;
  TurretClampAngles(P, Y, TurretLimits(0, 0, 0, 90));
  Check(SameValue(Y, 0), 'turret yaw clamped to the nearer limit');
  TurretStep(0, 350, 0, 10, 5, DP, DY);
  Check(SameValue(DY, 5) and SameValue(DP, 0), 'turret turns the short way, at its speed');
  { Muzzle along forward / right / up }
  Off := TurretMuzzle(TVector3.Zero, 0, 90, Vector3(32, 0, 8));
  Check(TVector3.Equals(Off, Vector3(0, 32, 8), 0.001), 'turret muzzle turns with the breach');
  { The driver's seat }
  Off := TurretDriverOffset(Vector3(-40, 0, 0), TVector3.Zero);
  Check(SameValue(Off.X, 40) and SameValue(Off.Y, 180) and SameValue(Off.Z, 0), 'turret driver offset');
  Check(TVector3.Equals(TurretDriverOrigin(TVector3.Zero, 0, 90, Off, 0), Vector3(0, -40, 0), 0.001),
    'turret driver turns with the breach');
  Check(SameValue(TurretDriverOrigin(TVector3.Zero, 10, 0, Off, 0).Z, 7), 'turret driver rises when the gun dips');
  Check(SameValue(SnapToEights(1.07), 1.125) and SameValue(SnapToEights(-1.07), -1.125), 'SnapToEights');
  { The brush is drawn with the breach's angles }
  QuakeAngleVectors(30, 90, F, R, U);
  Fwd := RotatePointAroundAxis(TurretRotation(30, 90), Vector3(1, 0, 0));
  Check(TVector3.Equals(Fwd, QuakeToCge(F), 0.001), 'turret rotation matches AngleVectors');
end;

procedure TestModelLightStyles;
var
  Bsp: TQuakeBsp;
  Samples: TLightPointSamples;
  P, Found: TVector3;
  X, Y, Z, K, Style: Integer;
  Lit, Dark: TVector3;
begin
  Bsp := TQuakeBsp.Create;
  try
    if not Bsp.LoadFromPak('maps/demo1.bsp') then
    begin
      Check(False, 'load demo1 for light styles');
      Exit;
    end;
    { A point whose floor has a light style other than 0, with some light }
    Style := -1;
    Found := TVector3.Zero;
    X := Trunc(Bsp.Models[0].Mins.X);
    while (X < Bsp.Models[0].Maxs.X) and (Style < 0) do
    begin
      Y := Trunc(Bsp.Models[0].Mins.Y);
      while (Y < Bsp.Models[0].Maxs.Y) and (Style < 0) do
      begin
        Z := Trunc(Bsp.Models[0].Mins.Z);
        while (Z < Bsp.Models[0].Maxs.Z) and (Style < 0) do
        begin
          P := Vector3(X, Y, Z);
          if Bsp.LightPointStyles(P, Samples) then
            for K := 1 to Samples.Count - 1 do
              if (Samples.Styles[K] <> 0) and (Samples.Colors[K].Length > 0.05) then
              begin
                Style := Samples.Styles[K];
                Found := P;
                Break;
              end;
          Z := Z + 48;
        end;
        Y := Y + 48;
      end;
      X := X + 48;
    end;
    Check(Style > 0, 'demo1 has floors lit by a second light style');
    if Style <= 0 then
      Exit;
    Lighting.SetMap(Bsp);
    try
      Lighting.Update(0.1);
      Lit := Lighting.SampleLight(QuakeToCge(Found));
      { Switch that style off ('a' = 0): models there get darker (R_LightPoint) }
      Lighting.SetStyle(Style, 'a');
      Lighting.Update(0.1);
      Dark := Lighting.SampleLight(QuakeToCge(Found));
      Check((Dark.X + Dark.Y + Dark.Z) < (Lit.X + Lit.Y + Lit.Z) - 0.05,
        Format('a model under light style %d darkens when it is switched off', [Style]));
    finally
      Lighting.SetMap(nil);
    end;
  finally
    Bsp.Free;
  end;
end;

procedure TestTouch;
var
  V: TVector2;
begin
  V := TouchStickVector(Vector2(100, 100), Vector2(100, 150), 100);
  Check(SameValue(V.Y, 0.5, 1e-5) and SameValue(V.X, 0, 1e-5), 'touch stick: half way up is half forward');
  V := TouchStickVector(Vector2(100, 100), Vector2(400, 100), 100);
  Check(SameValue(V.X, 1, 1e-5), 'touch stick: dragged past the radius is full speed');
  V := TouchStickVector(Vector2(100, 100), Vector2(300, 300), 100);
  Check(SameValue(V.Length, 1, 1e-5) and SameValue(V.X, V.Y, 1e-5), 'touch stick: diagonal keeps its direction, length 1');
end;

function DemoIn(const T, Yaw, Fwd: Single; const Buttons: Integer): TDemoInput;
begin
  Result := Default(TDemoInput);
  Result.Time := T;
  Result.Yaw := Yaw;
  Result.Forward := Fwd;
  Result.Buttons := Buttons;
  Result.HasOrigin := True;
  Result.Origin := Vector3(T * 100, 0, 24);
end;

procedure TestRecord;
var
  R: TQuakeRecorder;
  I: TDemoInput;
begin
  CheckEquals(10, Round(AngleDiff(175, -175)), 'angle difference wraps around');
  Check(ParseDemoInput('1.50 90.0 -10.0 1.00 -0.50 3 10.25 -20.00 24.03', I), 'IN parses');
  Check(SameValue(I.Time, 1.5) and SameValue(I.Pitch, -10) and SameValue(I.Side, -0.5) and
    (I.Buttons = 3) and I.HasOrigin and SameValue(I.Origin.Z, 24.03, 1e-4), 'IN fields');
  Check(ParseDemoInput('2 0 0 0 0 0', I) and not I.HasOrigin, 'IN without a position');
  Check(not ParseDemoInput('2 0 0', I), 'short IN is rejected');
  I := DemoIn(1.5, 90, 1, InButtonFire);
  I.Pitch := -10;
  Check(ParseDemoInput(Copy(FormatDemoInput(I), 4, MaxInt), I) and SameValue(I.Yaw, 90) and
    SameValue(I.Origin.X, 150, 1e-3), 'IN round trip');

  R := TQuakeRecorder.Create('demo1');
  try
    R.Sample(DemoIn(0, 0, 0, 0));
    R.Sample(DemoIn(0.02, 0.1, 0, 0)); { tiny turn: nothing }
    R.Sample(DemoIn(0.04, 0.1, 1, 0)); { forward pressed: right away }
    R.Sample(DemoIn(0.3, 0.1, 1, 0)); { held, moving < KeyInterval: nothing }
    R.Sample(DemoIn(0.6, 0.1, 1, 0)); { position keyframe }
    R.Sample(DemoIn(0.62, 30, 1, 0)); { turn, but within ViewInterval }
    R.Sample(DemoIn(0.66, 30, 1, 0)); { turn }
    R.Sample(DemoIn(1.0, 30, 1, InButtonJump));
    R.Sample(DemoIn(1.02, 30, 1, 0)); { jump kept 0.1 s }
    R.Sample(DemoIn(1.1, 30, 1, 0));
    R.AddTimedCommand(1.2, 'C:3');
    R.Finish(1.5);
    CheckEquals(10, R.Lines.Count, 'recorded lines');
    Check(Copy(R.Lines[1], 1, 8) = 'IN:0.04 ', 'input change recorded at once');
    Check(Copy(R.Lines[2], 1, 8) = 'IN:0.60 ', 'position keyframe while moving');
    Check(Copy(R.Lines[3], 1, 8) = 'IN:0.66 ', 'view change after the view interval');
    Check(ParseDemoInput(Copy(R.Lines[5], 4, MaxInt), I) and SameValue(I.Time, 1.1, 1e-4) and (I.Buttons = 0),
      'jump released after 0.1 s');
    Check(ParseDemoInput(Copy(R.Lines[6], 4, MaxInt), I) and SameValue(I.Time, 1.2, 1e-4) and not I.HasOrigin and
      SameValue(I.Forward, 1), 'timed command waits, holding the inputs, without a stale position');
    Check(R.Lines[7] = 'C:3', 'timed command');
    Check(ParseDemoInput(Copy(R.Lines[8], 4, MaxInt), I) and SameValue(I.Forward, 0) and SameValue(I.Time, 1.5),
      'finish releases the inputs');
    Check(R.Lines[9] = 'V', 'finish logs the state');
  finally
    R.Free;
  end;
end;

procedure TestGamepad;
var
  V: TVector2;
  F, S, Yaw, Pitch, Yaw2, Pitch2: Single;
  E: TInputPressRelease;
begin
  { Deadzone: small drift ignored, output starts at 0 and reaches 1 }
  Check(ApplyDeadZone(Vector2(0.15, 0.1)).IsZero, 'stick drift inside the deadzone ignored');
  V := ApplyDeadZone(Vector2(0, 0.21));
  Check((V.Y > 0) and (V.Y < 0.05), 'stick just past the deadzone gives a small value');
  Check(SameValue(ApplyDeadZone(Vector2(0, 1)).Y, 1, 1e-5) and
    SameValue(ApplyDeadZone(Vector2(1.2, 0)).X, 1, 1e-5), 'full stick is 1 (clamped)');
  StickToMove(Vector2(0, 1), F, S);
  Check((F > 0.99) and (Abs(S) < 1e-5), 'left stick up moves forward');
  StickToMove(Vector2(-1, 0), F, S);
  Check(S < -0.99, 'left stick left strafes left');
  { Look: right turns right (negative yaw), up looks up, half deflection is
    a quarter speed, sensitivity and invert apply }
  StickToLook(Vector2(1, 0), 1, 1, False, Yaw, Pitch);
  Check(SameValue(Yaw, -GamepadYawSpeed, 0.01) and (Pitch = 0), 'right stick right turns right at full speed');
  StickToLook(Vector2(0, 0.6), 0.5, 1, False, Yaw, Pitch);
  StickToLook(Vector2(0, 0.6), 0.5, 2, True, Yaw2, Pitch2);
  Check((Pitch > 0) and SameValue(Pitch, 0.5 * 0.25 * GamepadPitchSpeed, 0.01), 'look response is squared');
  Check(SameValue(Pitch2, -2 * Pitch, 0.01), 'sensitivity and invert apply to the stick');
  { Menus }
  CheckEquals(Ord(keyArrowDown), Ord(StickToArrow(Vector2(0.2, -0.9))), 'stick down is the down arrow');
  CheckEquals(Ord(keyNone), Ord(StickToArrow(Vector2(0.3, 0.3))), 'centered stick is no arrow');
  CheckEquals(Ord(keyEnter), Ord(GamepadMenuKey(gbSouth)), 'A confirms in menus');
  CheckEquals(Ord(keyEscape), Ord(GamepadMenuKey(gbEast)), 'B goes back in menus');
  E := Default(TInputPressRelease);
  E.EventType := itGameController;
  E.Controller.Button := gbDPadUp;
  Check(GamepadMenuEvent(E).IsKey(keyArrowUp), 'D-pad up is the up arrow in menus');
  CheckEquals(1, GamepadWeaponCycle(gbRightBumper), 'right bumper selects the next weapon');
  CheckEquals(-1, GamepadWeaponCycle(gbLeftBumper), 'left bumper selects the previous weapon');
end;

procedure TestPlayerTrail;
var
  Trail: TQuakePlayerTrail;
  I: Integer;
  Pos: TVector3;
  T: Single;
begin
  Trail := TQuakePlayerTrail.Create;
  try
    for I := 1 to 10 do
    begin
      Trail.Now := I;
      Trail.Add(Vector3(I, 0, 0));
    end;
    CheckEquals(TQuakePlayerTrail.Length, Trail.Count, 'trail keeps the last 8 spots');
    Check(Trail.FirstAfter(0, Pos, T) and (T = 3) and (Pos.X = 3), 'oldest spot first');
    Check(Trail.FirstAfter(5, Pos, T) and (T = 6), 'next spot after a time');
    Check(not Trail.FirstAfter(10, Pos, T), 'no spot after the newest');
    Check(Trail.LastSpot.X = 10, 'last spot is the newest');
  finally
    Trail.Free;
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
  TestMapReport;
  TestPlayerTrail;
  TestGamepad;
  TestTouch;
  TestCurrents;
  TestGibs;
  TestClock;
  TestModelLightStyles;
  TestTurret;
  TestLevelBsp;
  TestLevelVis;
  TestLevelDoorsWater;
  TestLevelKeysSlime;
  TestLevelLaddersLava;
  TestLevelRamps;
  TestLevelWindows;
  TestLevelLiftsSwitches;
  TestLevelGen;
  TestMapLevelUrl;
  TestRecord;
  TestGun;
  TestMonsterAttacks;
  TestMonsterMoves;
  TestTrace;
  TestMonsterJump;

  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
