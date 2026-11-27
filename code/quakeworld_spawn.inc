{ Spawning a level: maps, entities, spawn points, landmarks, hint paths.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.ResetStats;
begin
  FillChar(FCur.Stats, SizeOf(FCur.Stats), 0);
  FCur.Stats.Health := 100;
  FCur.Stats.MaxHealth := 100;
  FCur.Stats.MaxAmmo[atShells] := 100;
  FCur.Stats.MaxAmmo[atBullets] := 200;
  FCur.Stats.MaxAmmo[atGrenades] := 50;
  FCur.Stats.MaxAmmo[atRockets] := 50;
  FCur.Stats.MaxAmmo[atCells] := 200;
  FCur.Stats.MaxAmmo[atSlugs] := 50;
  FCur.Stats.MaxAmmo[atMagSlugs] := 50;
  FCur.Stats.MaxAmmo[atTraps] := 5;
  { Ground Zero's InitClientPersistant }
  FCur.Stats.MaxAmmo[atFlechettes] := 200;
  FCur.Stats.MaxAmmo[atProx] := 50;
  FCur.Stats.MaxAmmo[atTesla] := 50;
  FCur.Stats.WeaponMask := 1 shl 1; { Blaster }
  FCur.Stats.CurrentWeapon := 1;
end;

procedure TQuakeWorld.ClearLevel;
begin
  if FMoverPoses <> nil then
    FMoverPoses.Clear;
  if PlayerTrail <> nil then
    PlayerTrail.Clear;
  FPickups.Clear;
  FSightEntities.Clear;
  FTurrets.Clear;
  FBrainEnts.Clear;
  FMonsters.Clear;
  FProjectiles.Clear;
  FTriggers.Clear;
  FSpeakers.Clear;
  FProps.Clear;
  FLasers.Clear;
  FTimers.Clear;
  FPeriodic.Clear;
  FRepairHealth.Clear;
  FSteam.Clear;
  PlayerDisguised := False;
  RemoveDefender(False);
  FCur.DamageSource := nil;
  FDelayed.Clear;
  FCounters.Clear;
  FDynamicLights.Clear;
  Particles.Clear;
  { Map data is owned by the TQuakeMap component }
  FGeometry := nil;
  FBsp := nil;
end;

function TQuakeWorld.ModelBox(const AModel: String; out Box: TBox3D): Boolean;
var
  Idx: Integer;
  Mdl: TBSPModel;
begin
  Result := False;
  Box := TBox3D.Empty;
  if (Length(AModel) < 2) or (AModel[1] <> '*') then
    Exit;
  Idx := StrToIntDef(Copy(AModel, 2, MaxInt), -1);
  if (Idx <= 0) or (Idx >= FBsp.ModelCount) then
    Exit;
  Mdl := FBsp.Models[Idx];
  Box := QuakeBoxToCge(Mdl.Mins, Mdl.Maxs);
  Result := True;
end;

procedure TQuakeWorld.ChooseSpawnPoint(const SpawnName: String);
const
  { Maps whose starts all have targetnames: loaded directly (no "$spawn"),
    start where the previous level leads, like Yamagi Quake II's
    SP_CreateUnnamedSpawn table (the original game takes the first start) }
  DirectStarts: array[0..7, 0..1] of String = (('mine1', 'mintro'), ('mine2', 'mine1'),
    ('mine3', 'mine2a'), ('mine4', 'mine3'), ('power2', 'power1'), ('waste1', 'power2'),
    ('waste2', 'waste1'), ('city2', 'city2NL'));
var
  Ent, Best: TQuakeEntity;
  Score, BestScore, I: Integer;
  Wanted: String;
begin
  Wanted := SpawnName;
  if Wanted = '' then
    for I := 0 to High(DirectStarts) do
      if SameText(ExtractFileName(ChangeFileExt(FBsp.MapName, '')), DirectStarts[I, 0]) then
        Wanted := DirectStarts[I, 1];
  { Best: the info_player_start named by the changelevel "$spawn" suffix,
    then an unnamed info_player_start, then any start, then deathmatch spots }
  Best := nil;
  BestScore := 0;
  { Deathmatch: a deathmatch spot (SelectDeathmatchSpawnPoint) }
  if Deathmatch and SelectDeathmatchSpot(Best) then
  begin
    FSpawnPoint := QuakeToCge(Best.Origin + Vector3(0, 0, 1)) + Vector3(0, PlayerEyeHeight - 24, 0);
    FSpawnAngle := Best.Angle;
    Exit;
  end;
  for Ent in FBsp.Entities do
  begin
    if Ent.ClassName = 'info_player_start' then
    begin
      if (Wanted <> '') and SameText(Ent.TargetName, Wanted) then
        Score := 4
      else
      if Ent.TargetName = '' then
        Score := 3
      else
        Score := 2;
    end else
    if Ent.ClassName = 'info_player_deathmatch' then
      Score := 1
    else
      Score := 0;
    if Score > BestScore then
    begin
      Best := Ent;
      BestScore := Score;
    end;
  end;
  if Best <> nil then
  begin
    FSpawnPoint := QuakeToCge(Best.Origin) + Vector3(0, PlayerEyeHeight - 24, 0);
    FSpawnAngle := Best.Angle;
  end;
end;

procedure TQuakeWorld.SpawnEntity(const Ent: TQuakeEntity);
var
  CName: String;
  Pos: TVector3;
  ItemDef: PQuakeItemDef;
  MonsterDef: PQuakeMonsterDef;
  Monster: TQuakeMonster;
  Box: TBox3D;
  Trig: TQuakeTrigger;
  SpawnFlags: Integer;
  D: TDelayedTarget;
  Mover, M2: TQuakeMover;
  Turret: TQuakeTurret;
  Prop: TQuakeProp;
  T: TQuakeTrace;
begin
  CName := Ent.ClassName;
  { Ground Zero's SpawnItem in single player: the disruptor (without
    g_disruptor), the A-M bomb, the hunter and vengeance spheres and the
    doppelganger are deathmatch only; the nailgun and weapon_heatbeam aren't in its item list }
  if (CName = 'weapon_disintegrator') or (CName = 'ammo_disruptor') or (CName = 'ammo_nuke') or
     (CName = 'item_sphere_hunter') or (CName = 'item_sphere_vengeance') or (CName = 'item_doppleganger') or
     (CName = 'weapon_nailgun') or (CName = 'ammo_nails') or (CName = 'dm_tag_token') or
     (CName = 'weapon_heatbeam') then
    Exit;
  Pos := QuakeToCge(Ent.Origin);
  SpawnFlags := Ent.SpawnFlags;

  if Deathmatch then
  begin
    { SpawnEntities: SPAWNFLAG_NOT_DEATHMATCH instead of the skill flags;
      no monsters (SP_monster_*, misc_insane, turret_driver) and no
      help / secret / goal targets in deathmatch }
    if (SpawnFlags and SPAWNFLAG_NOT_DEATHMATCH) <> 0 then
      Exit;
    if ((Copy(CName, 1, 8) = 'monster_') and (CName <> 'monster_commander_body')) or
       (CName = 'misc_insane') or (CName = 'turret_driver') or
       (CName = 'target_help') or (CName = 'target_secret') or (CName = 'target_goal') then
      Exit;
    ItemDef := FindItemDef(CName);
    if (ItemDef <> nil) and not ItemAllowedByDMFlags(ItemDef^, DMFlags) then
      Exit;
  end else
  { Entities not on this skill (single player) }
  if (SpawnFlags and SkillSpawnFlag(GameSkill)) <> 0 then
    Exit;

  if (CName = 'info_player_start') or (CName = 'info_player_deathmatch') then
    Exit; { chosen by ChooseSpawnPoint }

  { A joining client's world (TViewPlay's join mode): only the map's brush
    entities (doors, lifts, glass) to draw and to trace against; the host's
    server runs everything else and sends it in snapshots }
  if FClientOnly and not ((Length(Ent.Model) > 1) and (Ent.Model[1] = '*')) then
    Exit;

  { Doors spawned from the console with mins / maxs (no *N model): a box
    mover, like the turrets below }
  if ((CName = 'func_door') or (CName = 'func_door_secret') or (CName = 'func_door_secret2')) and (Ent.Model = '') and
     Ent.HasField('mins') and Ent.HasField('maxs') and (FGeometry <> nil) then
  begin
    FGeometry.AddBoxMover(Ent, Ent.GetVector('mins', TVector3.Zero),
      Ent.GetVector('maxs', TVector3.Zero), FMap);
    Exit;
  end;

  if (CName = 'turret_breach') or (CName = 'turret_base') then
  begin
    { SP_turret_breach / SP_turret_base: the brush model, or a box for
      turrets spawned from the console with mins / maxs }
    Mover := nil;
    if FGeometry <> nil then
      for M2 in FGeometry.Movers do
        if M2.Entity = Ent then
          Mover := M2;
    if (Mover = nil) and (FGeometry <> nil) and Ent.HasField('mins') and Ent.HasField('maxs') then
      Mover := FGeometry.AddBoxMover(Ent, Ent.GetVector('mins', TVector3.Zero),
        Ent.GetVector('maxs', TVector3.Zero), FMap);
    if (Mover <> nil) and (CName = 'turret_breach') then
    begin
      Turret := TQuakeTurret.Create;
      Turret.Breach := Mover;
      Turret.Speed := Ent.GetFloat('speed', 0);
      if Turret.Speed = 0 then
        Turret.Speed := 50;
      Turret.Limits := TurretLimits(Ent.GetFloat('minpitch', 0), Ent.GetFloat('maxpitch', 0),
        Ent.GetFloat('minyaw', 0), Ent.GetFloat('maxyaw', 0));
      Turret.MoveYaw := Mover.TurretYaw;
      FTurrets.Add(Turret);
    end;
    Exit;
  end;

  if CName = 'turret_invisible_brain' then
  begin
    { SP_turret_invisible_brain: needs a target (the breach) and a
      killtarget (what it shoots at); linked in UpdateTurrets }
    if (Ent.Target = '') or (Ent.GetField('killtarget') = '') then
      WritelnLog('QuakeWorld', 'turret_invisible_brain without target / killtarget: removed')
    else
      FBrainEnts.Add(Ent);
    Exit;
  end;

  if CName = 'turret_driver' then
  begin
    { SP_turret_driver: an infantry with 100 health, linked to the breach
      its target names on the next update }
    Monster := TQuakeMonster.CreateMonster(FMap, FindMonsterDef('monster_infantry'), Ent, Pos, Ent.Angle);
    Monster.TurretDriver := True;
    Monster.Health := 100;
    Monster.Transform.Name := StringReplace(Monster.Transform.Name, 'monster_infantry', 'turret_driver', []);
    Monster.OnFoundTarget := @MonsterFoundTarget;
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    if Monster.Model <> nil then
      Monster.Model.PlayAnim('stand', True, 10);
    FMonsters.Add(Monster);
    Inc(FCur.Stats.TotalKills);
    Exit;
  end;

  { SP_light_mine1 / 2: the mine's lamp models (the light is in the lightmap) }
  if (CName = 'light_mine1') or (CName = 'light_mine2') then
  begin
    FProps.Add(TQuakeProp.CreateProp(FMap, TPropKind(Ord(pkMineLight1) + Ord(CName = 'light_mine2')), Ent));
    Exit;
  end;
  if CName = 'monster_commander_body' then
  begin
    Prop := TQuakeProp.CreateProp(FMap, pkCommanderBody, Ent);
    FProps.Add(Prop);
    { commander_body_drop: MOVETYPE_TOSS (2 up) onto what is below, box
      -32 -32 0 .. 32 32 48 }
    T := WorldTrace(Ent.Origin + Vector3(0, 0, 2), Ent.Origin - Vector3(0, 0, 1024),
      Vector3(-32, -32, 0), Vector3(32, 32, 48), MASK_MONSTERSOLID, Prop);
    if not T.StartSolid then
      Prop.Transform.Translation := QuakeToCge(T.EndPos);
    Exit;
  end;
  if CName = 'monster_boss3_stand' then
  begin
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBoss3Stand, Ent));
    Exit;
  end;

  if CName = 'misc_insane' then
  begin
    { SP_misc_insane: a good guy (AI_GOOD_GUY), not counted in the kills }
    Monster := TQuakeMonster.CreateMonster(FMap, @InsaneDef, Ent, Pos, Ent.Angle);
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    Monster.ResolveTargets;
    FMonsters.Add(Monster);
    Exit;
  end;

  ItemDef := FindItemDef(CName);
  if ItemDef <> nil then
  begin
    { Items rest on the floor; origin is 15 units above it }
    FPickups.Add(TQuakePickup.CreatePickup(FMap, ItemDef, Ent, Pos));
    Exit;
  end;

  MonsterDef := FindMonsterDef(CName);
  if MonsterDef <> nil then
  begin
    Monster := TQuakeMonster.CreateMonster(FMap, MonsterDef, Ent, Pos, Ent.Angle);
    Monster.OnAttack := @MonsterAttack;
    Monster.OnFoundTarget := @MonsterFoundTarget;
    Monster.OnPickTarget := @PickTarget;
    Monster.OnUseTargets := @UseTargets;
    Monster.OnRevived := @MonsterRevived;
    Monster.ResolveTargets;
    FMonsters.Add(Monster);
    Inc(FCur.Stats.TotalKills);
    Exit;
  end;

  if (Copy(CName, 1, 8) = 'trigger_') and EntityBox(Ent, Box) then
  begin
    Trig := TQuakeTrigger.Create(Ent, Box);
    if CName = 'trigger_teleport' then
      { SP_trigger_teleport (remaster / Rogue): with a targetname it waits
        to be used, unless START_ON (8) }
      Trig.Enabled := (Ent.TargetName = '') or ((SpawnFlags and 8) <> 0)
    else
    if CName = 'trigger_disguise' then
      { SP_trigger_disguise: touchable only with START_ON (2) }
      Trig.Enabled := (SpawnFlags and 2) <> 0
    else
    if ((SpawnFlags and TRIGGER_TRIGGERED) <> 0) and (Ent.TargetName <> '') then
      Trig.Enabled := False;
    FTriggers.Add(Trig);
    Exit;
  end;

  if CName = 'misc_teleporter' then
  begin
    { Teleporter pad trigger, around its origin }
    Trig := TQuakeTrigger.Create(Ent, Box3D(Pos - Vector3(24, 24, 24), Pos + Vector3(24, 32, 24)));
    FTriggers.Add(Trig);
    { and the pad model }
    FProps.Add(TQuakeProp.CreateProp(FMap, pkTeleporter, Ent));
    Exit;
  end;

  if CName = 'target_speaker' then
  begin
    FSpeakers.Add(TQuakeSpeaker.CreateSpeaker(FMap, Ent));
    Exit;
  end;

  { Quake II Remastered: a light drawn at run time (a "shadow light"), not
    in the lightmaps; only with a radius. START_OFF = 1 }
  if CName = 'dynamic_light' then
  begin
    if Ent.GetFloat('shadowlightradius', 0) > 0 then
    begin
      FDynamicLights.Add(Ent);
      if not FCounters.ContainsKey(Ent) then
        FCounters.AddOrSetValue(Ent, Ord((Ent.SpawnFlags and 1) = 0));
    end;
    Exit;
  end;

  { Switchable lights (style 32+ assigned by the map compiler), START_OFF = 1 }
  if (Copy(CName, 1, 5) = 'light') and (Ent.TargetName <> '') and
     (Ent.GetInt('style', 0) >= 32) then
  begin
    if (SpawnFlags and 1) <> 0 then
      Lighting.SetStyle(Ent.GetInt('style', 0), 'a')
    else
      Lighting.SetStyle(Ent.GetInt('style', 0), 'm');
    Exit;
  end;

  if CName = 'misc_explobox' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkExplobox, Ent))
  else
  if CName = 'misc_banner' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBanner, Ent))
  else
  if CName = 'misc_deadsoldier' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkDeadSoldier, Ent))
  else
  if CName = 'misc_satellite_dish' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkSatelliteDish, Ent))
  else
  if CName = 'misc_strogg_ship' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkStroggShip, Ent))
  else
  if CName = 'misc_gib_head' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkGibHead, Ent))
  else
  if CName = 'misc_viper' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkViper, Ent))
  else
  if CName = 'misc_bigviper' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBigViper, Ent))
  else
  if CName = 'misc_viper_bomb' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkViperBomb, Ent))
  else
  if CName = 'misc_blackhole' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBlackHole, Ent))
  else
  if CName = 'misc_eastertank' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterTank, Ent))
  else
  if CName = 'misc_easterchick' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterChick, Ent))
  else
  if CName = 'misc_easterchick2' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkEasterChick2, Ent))
  else
  if CName = 'rotating_light' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkRotatingLight, Ent))
  else
  if CName = 'misc_nuke_core' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkNukeCore, Ent))
  else
  if CName = 'target_blacklight' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkBlacklight, Ent))
  else
  if CName = 'target_orb' then
    FProps.Add(TQuakeProp.CreateProp(FMap, pkOrb, Ent))
  else
  if CName = 'misc_transport' then
  begin
    { SP_misc_transport: needs a target; it starts along its path at once
      (TRAIN_START_ON), hidden, and the first use shows it }
    if Ent.Target = '' then
      WritelnLog('QuakeWorld', 'misc_transport without a target: removed')
    else
    begin
      Prop := TQuakeProp.CreateProp(FMap, pkTransport, Ent);
      FProps.Add(Prop);
      StartPropFlight(Prop);
    end;
  end else
  if CName = 'func_object_repair' then
    { SP_object_repair: welding sparks every "delay" (1) seconds }
    FPeriodic.AddOrSetValue(Ent, FTime + Ent.GetFloat('delay', 1))
  else
  if CName = 'misc_amb4' then
    { SP_misc_amb4: world/amb4.wav 1 s after spawning, then every 2 s }
    FPeriodic.AddOrSetValue(Ent, FTime + 1)
  else
  if CName = 'target_mal_laser' then
    FLasers.Add(TQuakeLaser.CreateLaser(FMap, Ent, EntityMoveDir(Ent)))
  else
  if CName = 'target_laser' then
    FLasers.Add(TQuakeLaser.CreateLaser(FMap, Ent, EntityMoveDir(Ent)))
  else
  if CName = 'func_timer' then
  begin
    { spawnflags 1 = START_ON }
    if (SpawnFlags and 1) <> 0 then
      FTimers.AddOrSetValue(Ent, FTime + 1 + Ent.GetFloat('delay', 0) + TimerInterval(Ent))
    else
      FTimers.AddOrSetValue(Ent, -1);
  end;

  if CName = 'target_crosslevel_target' then
  begin
    { Fires its targets after "delay" (default 1 s) if all its bits were set
      by target_crosslevel_trigger in other levels }
    if ((SpawnFlags and $FF) <> 0) and ((FServerFlags and SpawnFlags and $FF) = (SpawnFlags and $FF)) then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 1);
      D.Target := Ent.Target;
      D.Entity := nil;
      FDelayed.Add(D);
      WritelnLog('QuakeWorld', 'Cross-level target will fire "%s"', [Ent.Target]);
    end;
  end else
  if CName = 'func_clock' then
  begin
    { SP_func_clock: TIMER_UP 1 (default an hour), TIMER_DOWN 2, START_OFF 4,
      MULTI_USE 8 }
    SetLength(FClocks, Length(FClocks) + 1);
    FClocks[High(FClocks)].Entity := Ent;
    FClocks[High(FClocks)].Display := nil;
    ResetClock(High(FClocks));
    if (SpawnFlags and 4) <> 0 then
      FClocks[High(FClocks)].NextThink := -1
    else
      FClocks[High(FClocks)].NextThink := FTime + 1;
  end else
  if CName = 'target_secret' then
    Inc(FCur.Stats.TotalSecrets)
  else
  if CName = 'target_goal' then
    Inc(FCur.Stats.TotalGoals)
  else
  if CName = 'trigger_counter' then
    FCounters.AddOrSetValue(Ent, Ent.GetInt('count', 2))
  else
  if CName = 'trigger_always' then
    UseEntity(Ent);
end;

procedure TQuakeWorld.ApplyLandmark;
const
  BoxMins: TVector3 = (X: -16; Y: -16; Z: -24);
  BoxMaxs: TVector3 = (X: 16; Y: 16; Z: 32);
var
  Ent, Landmark: TQuakeEntity;
  Org: TVector3;
begin
  { TryLandmarkSpawn: the same place relative to this map's info_landmark
    of that name, unless something is in the way there }
  if FLandmarkName = '' then
    Exit;
  Landmark := nil;
  for Ent in FBsp.Entities do
    if (Ent.ClassName = 'info_landmark') and SameText(Ent.TargetName, FLandmarkName) then
    begin
      Landmark := Ent;
      Break;
    end;
  if Landmark <> nil then
  begin
    Org := LandmarkWorld(FLandmarkLocal, Landmark.Origin, Landmark.Angle);
    if WorldTrace(Org, Org, BoxMins, BoxMaxs, MASK_PLAYERSOLID, nil).StartSolid then
      WritelnLog('QuakeWorld', 'info_landmark "%s": the spot is blocked, using the spawn point', [FLandmarkName])
    else
    begin
      FSpawnPoint := QuakeToCge(Org) + Vector3(0, PlayerEyeHeight - 24, 0);
      FSpawnAngle := Landmark.Angle + FLandmarkViewYaw;
      WritelnLog('QuakeWorld', 'Arrived by info_landmark "%s" at %s', [FLandmarkName, Org.ToString]);
    end;
  end;
  FLandmarkName := '';
end;

procedure TQuakeWorld.PoiUse(const Ent: TQuakeEntity);
const
  POI_NEAREST = 1;
  POI_DUMMY = 2;
  POI_DISABLED = 8;
var
  Team: String;
  E, Best: TQuakeEntity;
  Count, BestStyle, Flags: Integer;
  BestDist, Dist: Single;
  Disabled: Integer;
begin
  { use_target_poi: it is enabled; a stage ("count") only moves forward }
  FCounters.AddOrSetValue(Ent, 0);
  Count := Ent.GetInt('count', 0);
  if Count > 0 then
  begin
    if FPoiStage > Count then
      Exit;
    FPoiStage := Count;
  end;
  Best := Ent;
  Team := Ent.GetField('team');
  if Team <> '' then
  begin
    { The team member to point at: enabled, no dummy, on this stage; the
      lowest style, then the nearest (NEAREST) or the last one }
    Best := nil;
    BestStyle := MaxInt;
    BestDist := MaxSingle;
    for E in FBsp.Entities do
    begin
      if (E.ClassName <> 'target_poi') or (E.GetField('team') <> Team) then
        Continue;
      Flags := E.SpawnFlags;
      if not FCounters.TryGetValue(E, Disabled) then
        Disabled := Ord((Flags and POI_DISABLED) <> 0);
      if (Disabled <> 0) or ((Flags and POI_DUMMY) <> 0) or
         ((E.GetInt('count', 0) > 0) and (E.GetInt('count', 0) < FPoiStage)) then
        Continue;
      Dist := PointsDistance(E.Origin, CgeToQuake(FCur.Pos));
      if (E.GetInt('style', 0) < BestStyle) or
         ((E.GetInt('style', 0) = BestStyle) and (((Flags and POI_NEAREST) = 0) or (Dist < BestDist))) then
      begin
        Best := E;
        BestStyle := E.GetInt('style', 0);
        BestDist := Dist;
      end;
    end;
  end;
  if Best = nil then
    Exit;
  FPoiValid := True;
  FPoiPosition := Best.Origin;
  WritelnLog('QuakeWorld', 'Point of interest at %s', [FPoiPosition.ToString]);
end;

procedure TQuakeWorld.SpawnEntities(const SpawnName: String);
var
  Ent: TQuakeEntity;
  Monster: TQuakeMonster;
  AmbushCount, DormantCount: Integer;
begin
  ChooseSpawnPoint(SpawnName);
  FPoiValid := False;
  FPoiStage := 0;
  for Ent in FBsp.Entities do
    SpawnEntity(Ent);
  BuildHintPaths;
  ApplyLandmark;
  { Pickups after these are drops (DropMonsterItem), saved by class }
  FMapPickupCount := FPickups.Count;

  WritelnLog('QuakeWorld', 'Spawned %d pickups, %d monsters, %d triggers, %d movers, %d speakers, %d props, %d lasers, %d timers',
    [FPickups.Count, FMonsters.Count, FTriggers.Count, FGeometry.Movers.Count, FSpeakers.Count,
     FProps.Count, FLasers.Count, FTimers.Count]);
  AmbushCount := 0;
  DormantCount := 0;
  for Monster in FMonsters do
  begin
    if Monster.Ambush then
      Inc(AmbushCount);
    if Monster.Dormant then
      Inc(DormantCount);
  end;
  WritelnLog('QuakeWorld', '%d ambush monsters, %d waiting for a trigger to spawn',
    [AmbushCount, DormantCount]);
end;

function TQuakeWorld.LoadMap(const AMapName: String): Boolean;
var
  RestoreRemembered: Boolean;
  MapName, SpawnName, MapPath: String;
  P: Integer;
  Pl: TQuakePlayer;
  World: TQuakeEntity;
begin
  Result := False;
  MapName := LowerCase(Trim(AMapName));
  { "base2$spawnpoint", "*base1" (new unit) }
  SpawnName := '';
  P := Pos('$', MapName);
  if P > 0 then
  begin
    SpawnName := Copy(MapName, P + 1, MaxInt);
    MapName := Copy(MapName, 1, P - 1);
  end;
  while (MapName <> '') and (MapName[1] = '*') do
    Delete(MapName, 1, 1);
  if Pos('maps/', MapName) = 1 then
    MapPath := MapName
  else
    MapPath := 'maps/' + MapName;
  if ExtractFileExt(MapPath) = '' then
    MapPath := MapPath + '.bsp';

  { Generated / editor levels are made on demand (MissingMapHook) }
  if (not Pak.FileExists(MapPath)) and Assigned(MissingMapHook) then
    MissingMapHook(MapPath);
  if not Pak.FileExists(MapPath) then
  begin
    WritelnWarning('QuakeWorld', 'Map "%s" not found', [MapPath]);
    Exit;
  end;

  { Quake 2 units: leaving a level through a changelevel remembers its state
    for when the player comes back; a "*map" starts a new unit (forget all) }
  if Pos('*', AMapName) = 1 then
    FLevelStates.Clear
  else
  if FLevelExited and (FBsp <> nil) then
  begin
    if FLevelStates.IndexOfName(FBsp.MapName) >= 0 then
      FLevelStates.Delete(FBsp.MapName);
    FLevelStates.Add(FBsp.MapName, SaveState);
  end;
  RestoreRemembered := FLevelExited;

  ClearLevel;
  { A new TQuakeBsp may reuse the old one's address: never keep the
    collision of the previous map }
  FreeAndNil(FCollision);
  FCur.Gibbed := False;
  FCur.HasKiller := False;
  { Scores start over on each map (InitClientResp) }
  for Pl in FPlayers do
    Pl.Frags := 0;
  if FWeaponTransform <> nil then
    FWeaponTransform.Exists := True;
  FClocks := nil;
  FLastString := '';
  FQuakes := nil;
  { PutClientInServer: every level starts with normal gravity }
  SetPlayerGravity(1);
  FLevelExited := False;
  FNextMap := '';
  FTeleportPending := False;
  FCur.Dead := False;
  FRestartPending := False;
  FCur.Stats.LevelTime := 0;
  FCur.Stats.Kills := 0;
  FCur.Stats.TotalKills := 0;
  FCur.Stats.Secrets := 0;
  FCur.Stats.TotalSecrets := 0;
  FCur.Stats.Goals := 0;
  FCur.Stats.TotalGoals := 0;
  FSpawnPoint := Vector3(0, PlayerEyeHeight, 0);
  FSpawnAngle := 0;

  { The map component (TQuakeMap, placed in the view design) builds the
    geometry; the world adds the gameplay on top of it. }
  { Reuse the map the design already loaded (only the first time: restarts
    and level changes must rebuild movers in their initial state) }
  if FMapReused or (FMap.Bsp = nil) or not SameText(FMap.MapName, MapName) then
    if not FMap.LoadMap(MapName) then
      Exit;
  FMapReused := True;
  FBsp := FMap.Bsp;
  FGeometry := FMap.Geometry;
  FGeometry.OnFireTargets := @UseTargets;

  SpawnEntities(SpawnName);
  if RestoreRemembered and (FLevelStates.IndexOfName(FBsp.MapName) >= 0) then
  begin
    LoadState(FLevelStates.Objects[FBsp.MapName], False);
    WritelnLog('QuakeWorld', 'Restored remembered state of "%s"', [FBsp.MapName]);
  end;
  { Raise the weapon (Quake 2 starts levels with the activate frames) }
  FCur.Gun.Reset(FCur.Stats.CurrentWeapon);
  UpdateWeaponModel;

  World := FBsp.FindEntity('worldspawn');
  Sounds.StopMusic;
  FHelpPrimary := '';
  FHelpSecondary := '';
  if FHud <> nil then
  begin
    FHud.HelpPrimary := '';
    FHud.HelpSecondary := '';
    FHud.Intermission := False;
    if World <> nil then
      FHud.LevelName := World.MessageText
    else
      FHud.LevelName := FBsp.MapName;
  end;
  if World <> nil then
  begin
    Sounds.PlayMusic(Sounds.TrackFileName(World.Sounds));
    if (FHud <> nil) and (World.MessageText <> '') then
      FHud.ShowMessage(World.MessageText, 4);
  end;

  WritelnLog('QuakeWorld', 'Initialized map "%s"', [MapPath]);
  Result := True;
end;

function TQuakeWorld.EntityBox(const Ent: TQuakeEntity; out Box: TBox3D): Boolean;
begin
  Result := ModelBox(Ent.Model, Box);
  if (not Result) and Ent.HasField('mins') and Ent.HasField('maxs') then
  begin
    Box := QuakeBoxToCge(Ent.Origin + Ent.GetVector('mins', TVector3.Zero),
      Ent.Origin + Ent.GetVector('maxs', TVector3.Zero));
    Result := True;
  end;
end;

procedure TQuakeWorld.BuildHintPaths;
const
  HINT_ENDPOINT = 1;
var
  Hints: TQuakeEntityList;
  Ent, Node: TQuakeEntity;
  Chain: array of Integer;
  Seen: specialize TDictionary<TQuakeEntity, Integer>;
  I, C, Idx: Integer;

  function HintNamed(const Name: String): TQuakeEntity;
  var
    E: TQuakeEntity;
  begin
    Result := nil;
    if Name = '' then
      Exit;
    for E in Hints do
      if E.TargetName = Name then
        Exit(E);
  end;

begin
  if HintPaths = FHintPaths then
    HintPaths := nil;
  FreeAndNil(FHintPaths);
  Hints := TQuakeEntityList.Create(False);
  Seen := specialize TDictionary<TQuakeEntity, Integer>.Create;
  try
    for Ent in FBsp.Entities do
      if Ent.ClassName = 'hint_path' then
        Hints.Add(Ent);
    if Hints.Count = 0 then
      Exit;
    FHintPaths := TQuakeHintPaths.Create;
    SetLength(FHintPaths.Nodes, Hints.Count);
    for I := 0 to Hints.Count - 1 do
    begin
      FHintPaths.Nodes[I].Pos := QuakeToCge(Hints[I].Origin);
      FHintPaths.Nodes[I].Chain := -1;
      Seen.Add(Hints[I], I);
    end;
    { Chain starts: END, a target, no targetname (at most 100) }
    for Ent in Hints do
      if ((Ent.SpawnFlags and HINT_ENDPOINT) <> 0) and (Ent.Target <> '') and (Ent.TargetName = '') and
         (Length(FHintPaths.Chains) < 100) then
      begin
        C := Length(FHintPaths.Chains);
        SetLength(Chain, 0);
        Node := Ent;
        while Node <> nil do
        begin
          Idx := Seen[Node];
          { A fork or a loop cuts the chain }
          if FHintPaths.Nodes[Idx].Chain >= 0 then
            Break;
          FHintPaths.Nodes[Idx].Chain := C;
          FHintPaths.Nodes[Idx].Order := Length(Chain);
          SetLength(Chain, Length(Chain) + 1);
          Chain[High(Chain)] := Idx;
          Node := HintNamed(Node.Target);
        end;
        if Length(Chain) > 1 then
        begin
          SetLength(FHintPaths.Chains, C + 1);
          FHintPaths.Chains[C] := Copy(Chain);
        end else
          for Idx in Chain do
            FHintPaths.Nodes[Idx].Chain := -1;
      end;
    WritelnLog('QuakeWorld', 'Hint paths: %d chains of %d nodes', [Length(FHintPaths.Chains), Hints.Count]);
  finally
    Seen.Free;
    Hints.Free;
  end;
  HintPaths := FHintPaths;
end;

function TQuakeWorld.HintPointsVisible(const FromPos, ToPos: TVector3): Boolean;
begin
  Result := WorldTrace(CgeToQuake(FromPos), CgeToQuake(ToPos), TVector3.Zero, TVector3.Zero,
    MASK_OPAQUE, nil).Fraction >= 1;
end;

function TQuakeWorld.IntermissionSpot(out Pos: TVector3; out Yaw, Pitch: Single): Boolean;
var
  Ent: TQuakeEntity;
  A: TVector3;
begin
  Result := False;
  Pos := FCur.Pos;
  Yaw := 0;
  Pitch := 0;
  if FBsp = nil then
    Exit;
  Ent := FBsp.FindEntity('info_player_intermission');
  if Ent = nil then
    Exit;
  A := Ent.GetVector('angles', Vector3(0, Ent.Angle, 0));
  Pos := QuakeToCge(Ent.Origin);
  Pitch := A.X;
  Yaw := A.Y;
  Result := True;
end;

procedure TQuakeWorld.SetPlayer(const Value: TQuakePMove);
begin
  FCur.PM := Value;
  if FCur.PM <> nil then
  begin
    FBaseGravity := FCur.PM.GravityAcceleration;
    FCur.Gravity := 1;
    WirePlayerMove(FCur.PM);
  end;
end;

procedure TQuakeWorld.WirePlayerMove(const PM: TQuakePMove);
begin
  PM.OnFallDamage := @PlayerFallDamage;
  PM.OnPointContents := @PlayerPointContents;
  PM.OnLandSound := @PlayerLanded;
  PM.OnTrace := @PlayerTrace;
  PM.OnBeforeMove := @PlayerBeforeMove;
end;
