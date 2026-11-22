{ Savegames and unit levels.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

function TQuakeWorld.UnitLevelsToJson: TJSONObject;
begin
  Result := FLevelStates.Clone as TJSONObject;
end;

procedure TQuakeWorld.UnitLevelsFromJson(const Obj: TJSONObject);
begin
  FreeAndNil(FLevelStates);
  if Obj <> nil then
    FLevelStates := Obj.Clone as TJSONObject
  else
    FLevelStates := TJSONObject.Create;
end;

function TQuakeWorld.SaveState: TJSONObject;
var
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
  A: TAmmoType;
  Pair: specialize TPair<TQuakeEntity, Single>;
  CPair: specialize TPair<TQuakeEntity, Integer>;
begin
  Result := TJSONObject.Create;
  Result.Add('map', FBsp.MapName);
  Result.Add('time', FTime);
  Result.Add('skill', GameSkill);
  { Player inventory }
  O := TJSONObject.Create;
  O.Add('health', FStats.Health);
  O.Add('maxHealth', FStats.MaxHealth);
  O.Add('armor', FStats.Armor);
  O.Add('armorType', FStats.ArmorType);
  O.Add('weaponMask', Int64(FStats.WeaponMask));
  O.Add('weapon', FStats.CurrentWeapon);
  O.Add('keys', Int64(FStats.Keys));
  O.Add('kills', FStats.Kills);
  O.Add('secrets', FStats.Secrets);
  O.Add('goals', FStats.Goals);
  O.Add('levelTime', FStats.LevelTime);
  O.Add('quad', FStats.QuadTime);
  O.Add('quadFire', FStats.QuadFireTime);
  O.Add('double', FStats.DoubleTime);
  O.Add('ir', FStats.IRTime);
  O.Add('defender', FStats.DefenderTime);
  O.Add('invuln', FStats.InvulnTime);
  O.Add('breather', FStats.BreatherTime);
  O.Add('enviro', FStats.EnviroTime);
  O.Add('silencer', FStats.SilencerShots);
  O.Add('powerScreens', FStats.PowerScreens);
  O.Add('powerShields', FStats.PowerShields);
  O.Add('powerArmorOn', FStats.PowerArmorOn);
  Arr := TJSONArray.Create;
  for A := Low(TAmmoType) to High(TAmmoType) do
    Arr.Add(FStats.Ammo[A]);
  O.Add('ammo', Arr);
  Arr := TJSONArray.Create;
  for A := Low(TAmmoType) to High(TAmmoType) do
    Arr.Add(FStats.MaxAmmo[A]);
  O.Add('maxAmmo', Arr);
  O.Add('helpPrimary', FHelpPrimary);
  O.Add('serverFlags', FServerFlags);
  O.Add('helpSecondary', FHelpSecondary);
  Result.Add('player', O);

  { Entities, matched by their deterministic spawn order }
  Arr := TJSONArray.Create;
  for I := 0 to FMonsters.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('pos', VecToJson(FMonsters[I].Transform.Translation));
    O.Add('facing', FMonsters[I].FacingAngle);
    O.Add('health', FMonsters[I].Health);
    O.Add('state', Ord(FMonsters[I].State));
    O.Add('alerted', FMonsters[I].Alerted);
    O.Add('gibbed', FMonsters[I].Gibbed);
    O.Add('dormant', FMonsters[I].Dormant);
    if FMonsters[I].Def^.ClassName = 'monster_stalker' then
      O.Add('ceiling', FMonsters[I].OnCeiling);
    Arr.Add(O);
  end;
  Result.Add('monsters', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to Min(FMapPickupCount, FPickups.Count) - 1 do
    Arr.Add(FPickups[I].Collected);
  Result.Add('pickups', Arr);
  { Items monsters dropped (not in the map): class and origin, if still there }
  Arr := TJSONArray.Create;
  for I := FMapPickupCount to FPickups.Count - 1 do
    if not FPickups[I].Collected then
    begin
      O := TJSONObject.Create;
      O.Add('class', FPickups[I].Entity.ClassName);
      O.Add('origin', FPickups[I].Entity.GetField('origin'));
      Arr.Add(O);
    end;
  Result.Add('drops', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FGeometry.Movers.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('state', Ord(FGeometry.Movers[I].State));
    O.Add('progress', FGeometry.Movers[I].Progress);
    O.Add('timer', FGeometry.Movers[I].StateTimer);
    O.Add('health', FGeometry.Movers[I].Health);
    O.Add('exists', FGeometry.Movers[I].Transform.Exists);
    O.Add('spinning', FGeometry.Movers[I].Spinning);
    O.Add('spin', FGeometry.Movers[I].SpinAngle);
    O.Add('turretPitch', FGeometry.Movers[I].TurretPitch);
    O.Add('turretYaw', FGeometry.Movers[I].TurretYaw);
    O.Add('trainRunning', FGeometry.Movers[I].TrainRunning);
    O.Add('trainWaiting', FGeometry.Movers[I].TrainWaiting);
    if FGeometry.Movers[I].Kind = mkPlat2 then
    begin
      O.Add('plat2Flags', FGeometry.Movers[I].Plat2Flags);
      O.Add('plat2Timer', FGeometry.Movers[I].Plat2Timer);
      O.Add('plat2Active', FGeometry.Movers[I].Plat2Active);
    end;
    O.Add('pos', VecToJson(FGeometry.Movers[I].Transform.Translation));
    O.Add('trainFrom', VecToJson(FGeometry.Movers[I].TrainFrom));
    O.Add('trainTo', VecToJson(FGeometry.Movers[I].TrainTo));
    O.Add('moveLength', FGeometry.Movers[I].MoveLength);
    if FGeometry.Movers[I].TrainCorner <> nil then
      O.Add('trainCorner', FBsp.Entities.IndexOf(FGeometry.Movers[I].TrainCorner))
    else
      O.Add('trainCorner', -1);
    Arr.Add(O);
  end;
  Result.Add('movers', Arr);

  { Projectiles in flight and grenades waiting to explode }
  Arr := TJSONArray.Create;
  for I := 0 to FProjectiles.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('kind', Ord(FProjectiles[I].Kind));
    O.Add('pos', VecToJson(FProjectiles[I].Transform.Translation));
    O.Add('velocity', VecToJson(FProjectiles[I].Velocity));
    O.Add('damage', FProjectiles[I].Damage);
    O.Add('splashDamage', FProjectiles[I].SplashDamage);
    O.Add('splashRadius', FProjectiles[I].SplashRadius);
    O.Add('life', FProjectiles[I].Life);
    O.Add('fromPlayer', FProjectiles[I].FromPlayer);
    O.Add('owner', FMonsters.IndexOf(FProjectiles[I].Owner));
    O.Add('exploding', FProjectiles[I].Exploding);
    if FProjectiles[I].Kind = pkTrap then
    begin
      O.Add('trapFrame', FProjectiles[I].TrapFrame);
      O.Add('trapLanded', FProjectiles[I].TrapLanded);
      O.Add('trapWait', FProjectiles[I].TrapWait);
      O.Add('trapMass', FProjectiles[I].TrapMass);
    end;
    Arr.Add(O);
  end;
  Result.Add('projectiles', Arr);

  { Targets fired later (trigger "delay"), as seconds from now: the world
    clock starts again from 0 when a level is loaded }
  Arr := TJSONArray.Create;
  for I := 0 to FDelayed.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('in', Max(0, FDelayed[I].Time - FTime));
    O.Add('target', FDelayed[I].Target);
    O.Add('entity', FBsp.Entities.IndexOf(FDelayed[I].Entity));
    Arr.Add(O);
  end;
  Result.Add('delayed', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FGeometry.AreaPortals.Count - 1 do
    Arr.Add(FGeometry.AreaPortals[I].Toggled);
  Result.Add('areaPortals', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FProps.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('health', FProps[I].Health);
    O.Add('destroyed', FProps[I].Destroyed);
    O.Add('exists', FProps[I].Transform.Exists);
    O.Add('flying', FProps[I].Flying);
    if FProps[I].Kind = pkRotatingLight then
    begin
      O.Add('lightOn', FProps[I].LightOn);
      O.Add('alarm', FProps[I].AlarmActive);
    end;
    O.Add('pos', VecToJson(FProps[I].Transform.Translation));
    O.Add('flyTarget', VecToJson(FProps[I].FlyTarget));
    if FProps[I].FlyCorner <> nil then
      O.Add('flyCorner', FBsp.Entities.IndexOf(FProps[I].FlyCorner))
    else
      O.Add('flyCorner', -1);
    Arr.Add(O);
  end;
  Result.Add('props', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FTriggers.Count - 1 do
    Arr.Add(FTriggers[I].Enabled);
  Result.Add('triggers', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FLasers.Count - 1 do
    Arr.Add(FLasers[I].IsOn);
  Result.Add('lasers', Arr);

  Arr := TJSONArray.Create;
  for I := 0 to FSpeakers.Count - 1 do
    Arr.Add(FSpeakers[I].Playing);
  Result.Add('speakers', Arr);

  O := TJSONObject.Create;
  for Pair in FTimers do
    if Pair.Value < 0 then
      O.Add(IntToStr(FBsp.Entities.IndexOf(Pair.Key)), -1)
    else
      O.Add(IntToStr(FBsp.Entities.IndexOf(Pair.Key)), Pair.Value - FTime);
  Result.Add('timers', O);

  O := TJSONObject.Create;
  for CPair in FCounters do
    O.Add(IntToStr(FBsp.Entities.IndexOf(CPair.Key)), CPair.Value);
  Result.Add('counters', O);

  Arr := TJSONArray.Create;
  for I := 32 to 62 do
    Arr.Add(Lighting.GetStyle(I));
  Result.Add('lightStyles', Arr);
end;

procedure TQuakeWorld.LoadState(const Obj: TJSONObject; const IncludePlayer: Boolean);
var
  O: TJSONObject;
  Arr: TJSONArray;
  I, Idx: Integer;
  A: TAmmoType;
  Mover: TQuakeMover;
  Prop: TQuakeProp;
  Proj: TQuakeProjectile;
  D: TDelayedTarget;
  Key: String;
  DropEnt: TQuakeEntity;
begin
  O := Obj.Get('player', TJSONObject(nil));
  if (O <> nil) and not IncludePlayer then
  begin
    { Level counters belong to the level }
    FStats.Kills := O.Get('kills', 0);
    FStats.Secrets := O.Get('secrets', 0);
    FStats.Goals := O.Get('goals', 0);
    O := nil;
  end;
  if O <> nil then
  begin
    FStats.Health := O.Get('health', FStats.Health);
    FStats.MaxHealth := O.Get('maxHealth', FStats.MaxHealth);
    FStats.Armor := O.Get('armor', FStats.Armor);
    FStats.ArmorType := O.Get('armorType', FStats.ArmorType);
    FStats.WeaponMask := O.Get('weaponMask', Int64(FStats.WeaponMask));
    FStats.Keys := O.Get('keys', Int64(FStats.Keys));
    FStats.Kills := O.Get('kills', 0);
    FStats.Secrets := O.Get('secrets', 0);
    FStats.Goals := O.Get('goals', 0);
    FStats.LevelTime := O.Get('levelTime', 0.0);
    FStats.QuadTime := O.Get('quad', 0.0);
    FStats.QuadFireTime := O.Get('quadFire', 0.0);
    FStats.DoubleTime := O.Get('double', 0.0);
    FStats.IRTime := O.Get('ir', 0.0);
    FStats.DefenderTime := O.Get('defender', 0.0);
    FStats.InvulnTime := O.Get('invuln', 0.0);
    FStats.BreatherTime := O.Get('breather', 0.0);
    FStats.EnviroTime := O.Get('enviro', 0.0);
    FStats.SilencerShots := O.Get('silencer', 0);
    FStats.PowerScreens := O.Get('powerScreens', 0);
    FStats.PowerShields := O.Get('powerShields', 0);
    FStats.PowerArmorOn := O.Get('powerArmorOn', False);
    Arr := O.Get('ammo', TJSONArray(nil));
    if Arr <> nil then
      for A := Low(TAmmoType) to High(TAmmoType) do
        if Ord(A) < Arr.Count then
          FStats.Ammo[A] := Arr.Integers[Ord(A)];
    Arr := O.Get('maxAmmo', TJSONArray(nil));
    if Arr <> nil then
      for A := Low(TAmmoType) to High(TAmmoType) do
        if Ord(A) < Arr.Count then
          FStats.MaxAmmo[A] := Arr.Integers[Ord(A)];
    FHelpPrimary := O.Get('helpPrimary', '');
    FServerFlags := O.Get('serverFlags', 0);
    FHelpSecondary := O.Get('helpSecondary', '');
    if FHud <> nil then
    begin
      FHud.HelpPrimary := FHelpPrimary;
      FHud.HelpSecondary := FHelpSecondary;
    end;
    I := O.Get('weapon', 1);
    if (I < 1) or (I > WeaponSlots) or ((FStats.WeaponMask and (1 shl I)) = 0) then
      I := 1;
    FStats.CurrentWeapon := I;
    FGun.Reset(I, False);
    UpdateWeaponModel;
  end;

  Arr := Obj.Get('monsters', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FMonsters.Count) - 1 do
    begin
      O := Arr.Objects[I];
      if O.Find('ceiling') <> nil then
        FMonsters[I].SetCeiling(O.Get('ceiling', False));
      FMonsters[I].RestoreState(JsonToVec(O.Find('pos')), O.Get('facing', 0.0),
        O.Get('health', 0), TMonsterState(O.Get('state', 0)),
        O.Get('alerted', False), O.Get('gibbed', False));
      FMonsters[I].SetDormant(O.Get('dormant', False));
    end;

  Arr := Obj.Get('pickups', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FPickups.Count) - 1 do
      FPickups[I].Collected := Arr.Booleans[I];
  Arr := Obj.Get('drops', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        O := TJSONObject(Arr.Items[I]);
        DropEnt := TQuakeEntity.Create;
        DropEnt.SetField('classname', O.Get('class', ''));
        DropEnt.SetField('origin', O.Get('origin', '0 0 0'));
        FBsp.Entities.Add(DropEnt);
        SpawnEntity(DropEnt);
        WritelnLog('QuakeWorld', 'Restored dropped %s at %s', [DropEnt.ClassName, DropEnt.GetField('origin')]);
      end;

  Arr := Obj.Get('movers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FGeometry.Movers.Count) - 1 do
    begin
      O := Arr.Objects[I];
      Mover := FGeometry.Movers[I];
      Mover.State := TQuakeMoverState(O.Get('state', 0));
      Mover.Progress := O.Get('progress', 0.0);
      Mover.StateTimer := O.Get('timer', 0.0);
      Mover.Health := O.Get('health', Mover.Health);
      Mover.Transform.Exists := O.Get('exists', True);
      Mover.Spinning := O.Get('spinning', Mover.Spinning);
      Mover.SpinAngle := O.Get('spin', 0.0);
      Mover.TurretPitch := O.Get('turretPitch', Mover.TurretPitch);
      Mover.TurretYaw := O.Get('turretYaw', Mover.TurretYaw);
      Mover.TrainRunning := O.Get('trainRunning', Mover.TrainRunning);
      Mover.TrainWaiting := O.Get('trainWaiting', False);
      if Mover.Kind = mkPlat2 then
      begin
        Mover.Plat2Flags := O.Get('plat2Flags', 0);
        Mover.Plat2Timer := O.Get('plat2Timer', 0.0);
        Mover.Plat2Active := O.Get('plat2Active', Mover.Plat2Active);
      end;
      Mover.MoveLength := O.Get('moveLength', Mover.MoveLength);
      Mover.TrainFrom := JsonToVec(O.Find('trainFrom'));
      Mover.TrainTo := JsonToVec(O.Find('trainTo'));
      Idx := O.Get('trainCorner', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        Mover.TrainCorner := FBsp.Entities[Idx];
      if Mover.Kind = mkTrain then
        Mover.Transform.Translation := JsonToVec(O.Find('pos'));
      Mover.ApplyPose;
    end;

  Arr := Obj.Get('areaPortals', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FGeometry.AreaPortals.Count) - 1 do
      FGeometry.AreaPortals[I].Toggled := Arr.Booleans[I];

  { Savegames restore projectiles and pending events. A revisited level
    (IncludePlayer = False) starts without projectiles and keeps the events
    scheduled at spawn: Quake 2's ReadLevel re-arms target_crosslevel_target
    the same way. }
  if not IncludePlayer then
    FProjectiles.Clear;
  Arr := Obj.Get('projectiles', TJSONArray(nil));
  if (Arr <> nil) and IncludePlayer then
  begin
    FProjectiles.Clear;
    for I := 0 to Arr.Count - 1 do
    begin
      O := Arr.Objects[I];
      Idx := O.Get('kind', 0);
      if (Idx < Ord(Low(TProjectileKind))) or (Idx > Ord(High(TProjectileKind))) then
        Continue;
      Proj := TQuakeProjectile.Create(FItems, TProjectileKind(Idx), JsonToVec(O.Find('pos')),
        JsonToVec(O.Find('velocity')), O.Get('damage', 0), O.Get('fromPlayer', False));
      Proj.SplashDamage := O.Get('splashDamage', 0);
      Proj.SplashRadius := O.Get('splashRadius', 0.0);
      Proj.Life := O.Get('life', Proj.Life);
      Proj.Exploding := O.Get('exploding', False);
      Proj.Transform.Exists := not Proj.Exploding;
      Proj.TrapFrame := O.Get('trapFrame', 0);
      Proj.TrapLanded := O.Get('trapLanded', False);
      Proj.TrapWait := O.Get('trapWait', 0);
      Proj.TrapMass := O.Get('trapMass', 0);
      if (Proj.Kind = pkTrap) and (Proj.Model <> nil) then
        Proj.Model.SetFrame(Min(Proj.TrapFrame, 7));
      Idx := O.Get('owner', -1);
      if (Idx >= 0) and (Idx < FMonsters.Count) then
        Proj.Owner := FMonsters[Idx];
      FProjectiles.Add(Proj);
    end;
  end;

  Arr := Obj.Get('delayed', TJSONArray(nil));
  if IncludePlayer then
    FDelayed.Clear;
  if (Arr <> nil) and IncludePlayer then
  begin
    FDelayed.Clear;
    for I := 0 to Arr.Count - 1 do
    begin
      D.Time := FTime + Arr.Objects[I].Get('in', 0.0);
      D.Target := Arr.Objects[I].Get('target', '');
      Idx := Arr.Objects[I].Get('entity', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        D.Entity := FBsp.Entities[Idx]
      else
        D.Entity := nil;
      FDelayed.Add(D);
    end;
  end;

  Arr := Obj.Get('props', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FProps.Count) - 1 do
    begin
      O := Arr.Objects[I];
      Prop := FProps[I];
      Prop.Health := O.Get('health', Prop.Health);
      Prop.Destroyed := O.Get('destroyed', False);
      Prop.Transform.Exists := O.Get('exists', True);
      Prop.Flying := O.Get('flying', False);
      if Prop.Kind = pkRotatingLight then
      begin
        Prop.LightOn := O.Get('lightOn', Prop.LightOn);
        Prop.AlarmActive := O.Get('alarm', False);
      end;
      Prop.Transform.Translation := JsonToVec(O.Find('pos'));
      Prop.FlyTarget := JsonToVec(O.Find('flyTarget'));
      Idx := O.Get('flyCorner', -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        Prop.FlyCorner := FBsp.Entities[Idx];
    end;

  Arr := Obj.Get('triggers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FTriggers.Count) - 1 do
      FTriggers[I].Enabled := Arr.Booleans[I];

  Arr := Obj.Get('lasers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FLasers.Count) - 1 do
      FLasers[I].IsOn := Arr.Booleans[I];

  Arr := Obj.Get('speakers', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, FSpeakers.Count) - 1 do
      if FSpeakers[I].Looped and (FSpeakers[I].Playing <> Arr.Booleans[I]) then
        FSpeakers[I].Activate;

  O := Obj.Get('timers', TJSONObject(nil));
  if O <> nil then
    for I := 0 to O.Count - 1 do
    begin
      Key := O.Names[I];
      Idx := StrToIntDef(Key, -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) and FTimers.ContainsKey(FBsp.Entities[Idx]) then
      begin
        if O.Items[I].AsFloat < 0 then
          FTimers[FBsp.Entities[Idx]] := -1
        else
          FTimers[FBsp.Entities[Idx]] := FTime + O.Items[I].AsFloat;
      end;
    end;

  O := Obj.Get('counters', TJSONObject(nil));
  if O <> nil then
    for I := 0 to O.Count - 1 do
    begin
      Idx := StrToIntDef(O.Names[I], -1);
      if (Idx >= 0) and (Idx < FBsp.Entities.Count) then
        FCounters.AddOrSetValue(FBsp.Entities[Idx], O.Items[I].AsInteger);
    end;

  Arr := Obj.Get('lightStyles', TJSONArray(nil));
  if Arr <> nil then
    for I := 0 to Min(Arr.Count, 31) - 1 do
      Lighting.SetStyle(32 + I, Arr.Strings[I]);

end;
