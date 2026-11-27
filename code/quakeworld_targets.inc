{ Targets and triggers: use chains, target_* entities, clocks, timers, lasers, lights.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.UseTargetsOf(const Ent: TQuakeEntity);
var
  D: TDelayedTarget;
begin
  { G_UseTargets: an entity's "delay" postpones the use of its targets }
  if Ent.GetFloat('delay', 0) > 0 then
  begin
    D.Time := FTime + Ent.GetFloat('delay', 0);
    D.Target := Ent.Target;
    D.Entity := nil;
    FDelayed.Add(D);
  end else
    UseTargets(Ent.Target, Ent);
end;

procedure TQuakeWorld.UseEntity(const Ent: TQuakeEntity);
var
  CName, Msg, MapName: String;
  Mover, M2: TQuakeMover;
  Count: Integer;
  ItemDef: PQuakeItemDef;
  M: TQuakeMonster;
  Trig: TQuakeTrigger;
  D: TDelayedTarget;
  Speaker: TQuakeSpeaker;
  Laser: TQuakeLaser;
  Prop: TQuakeProp;
  Lights: TQuakeEntityList;
  Light: TQuakeEntity;
  NewEnt: TQuakeEntity;
  Box: TBox3D;
  I: Integer;
  Turret: TQuakeTurret;
begin
  CName := Ent.ClassName;
  Msg := Ent.MessageText;

  if CName = 'func_areaportal' then
  begin
    FGeometry.ToggleAreaPortal(Ent);
    Exit;
  end;

  { trigger_key: needs an item; used once (Quake 2 clears its use), which
    is kept in FCounters as -1 so savegames keep it }
  if CName = 'trigger_key' then
  begin
    if FCounters.TryGetValue(Ent, Count) and (Count < 0) then
      Exit;
    ItemDef := FindItemDef(LowerCase(Ent.GetField('item')));
    if (ItemDef <> nil) and ((FCur.Stats.Keys and Cardinal(ItemDef^.Amount)) = 0) then
    begin
      if FHud <> nil then
        FHud.ShowMessage('You need the ' + ItemDef^.Name);
      WritelnLog('QuakeWorld', 'trigger_key "%s": you need the %s', [Ent.TargetName, ItemDef^.Name]);
      Sounds.Play('sound/misc/keytry.wav');
      Exit;
    end;
    Sounds.Play('sound/misc/keyuse.wav');
    if ItemDef <> nil then
      FCur.Stats.Keys := FCur.Stats.Keys and not Cardinal(ItemDef^.Amount);
    FCounters.AddOrSetValue(Ent, -1);
    WritelnLog('QuakeWorld', 'trigger_key "%s" unlocks "%s"', [Ent.TargetName, Ent.Target]);
    UseTargets(Ent.Target, Ent);
    Exit;
  end;

  if CName = 'trigger_counter' then
  begin
    if not FCounters.TryGetValue(Ent, Count) then
      Exit;
    Dec(Count);
    FCounters[Ent] := Count;
    if Count > 0 then
    begin
      if ((Ent.SpawnFlags and 1) = 0) and (FHud <> nil) then
        FHud.ShowMessage(Format('%d more to go...', [Count]));
      Exit;
    end;
    if ((Ent.SpawnFlags and 1) = 0) and (FHud <> nil) then
      FHud.ShowMessage('Sequence completed!');
    UseTargets(Ent.Target, Ent);
    Exit;
  end;

  { (target_string's message is its text, not a centerprint) }
  if (Msg <> '') and (FHud <> nil) and (Copy(CName, 1, 7) = 'target_') and (CName <> 'target_string') then
    FHud.ShowMessage(Msg, 4);

  if (CName = 'target_changelevel') and Deathmatch and not DMFlag(DF_ALLOW_EXIT) then
  begin
    { use_target_changelevel in deathmatch without DF_ALLOW_EXIT: the
      player who got there dies (MOD_EXIT) }
    if not FCur.Dead then
    begin
      FObituaryText := 'found a way out';
      FCur.Stats.Health := 0;
      FCur.HasKiller := False;
      KillPlayer;
    end;
    Exit;
  end;
  if CName = 'target_changelevel' then
  begin
    MapName := Ent.GetField('map');
    { Ignore cinematics / end screens (e.g. "victory.pcx", "*.cin") }
    if (MapName <> '') and (Pos('.', MapName) = 0) then
    begin
      FLevelExited := True;
      FNextMap := MapName;
      { The remaster: a target naming an info_landmark carries the player's
        place and view relative to it into the next map }
      FLandmarkName := '';
      Light := PickTarget(Ent.Target);
      if (Light <> nil) and (Light.ClassName = 'info_landmark') and (FCur.PM <> nil) then
      begin
        FLandmarkName := Light.TargetName;
        FLandmarkLocal := LandmarkLocal(FCur.PM.Origin, Light.Origin, Light.Angle);
        FLandmarkViewYaw := RadToDeg(ArcTan2(-FCur.Dir.Z, FCur.Dir.X)) - Light.Angle;
        WritelnLog('QuakeWorld', 'Leaving by info_landmark "%s" at %s from it', [FLandmarkName, FLandmarkLocal.ToString]);
      end;
    end;
  end else
  if CName = 'target_poi' then
    PoiUse(Ent)
  else
  if CName = 'target_crosslevel_trigger' then
  begin
    FServerFlags := FServerFlags or (Ent.SpawnFlags and $FF);
    WritelnLog('QuakeWorld', 'Cross-level flags now %d', [FServerFlags]);
  end else
  if CName = 'target_secret' then
  begin
    Inc(FCur.Stats.Secrets);
    Sounds.Play('sound/misc/secret.wav');
  end else
  if CName = 'target_goal' then
  begin
    Inc(FCur.Stats.Goals);
    Sounds.Play('sound/misc/secret.wav');
  end else
  if CName = 'target_speaker' then
  begin
    for Speaker in FSpeakers do
      if Speaker.Entity = Ent then
        Speaker.Activate;
  end else
  if (Copy(CName, 1, 5) = 'light') and (Ent.GetInt('style', 0) >= 32) then
  begin
    { Toggle a switchable light }
    if Lighting.GetStyle(Ent.GetInt('style', 0)) = 'a' then
      Lighting.SetStyle(Ent.GetInt('style', 0), 'm')
    else
      Lighting.SetStyle(Ent.GetInt('style', 0), 'a');
  end else
  if CName = 'target_lightramp' then
  begin
    { Ramp the targeted light's style between the two message letters over
      "speed" seconds; each use reverses the direction (Quake 2 TOGGLE) }
    Msg := LowerCase(Ent.GetField('message', 'az'));
    if Length(Msg) = 2 then
    begin
      Lights := FBsp.FindByTargetName(Ent.Target);
      try
        for Light in Lights do
          if Light.GetInt('style', 0) >= 32 then
          begin
            if Lighting.GetStyle(Light.GetInt('style', 0)) = Msg[2] then
              Lighting.RampStyle(Light.GetInt('style', 0), Msg[2], Msg[1], Ent.GetFloat('speed', 1))
            else
              Lighting.RampStyle(Light.GetInt('style', 0), Msg[1], Msg[2], Ent.GetFloat('speed', 1));
          end;
      finally
        Lights.Free;
      end;
    end;
    Exit;
  end else
  if CName = 'func_timer' then
  begin
    { Using a timer toggles it }
    if FTimers.ContainsKey(Ent) then
    begin
      if FTimers[Ent] < 0 then
        FTimers[Ent] := FTime + Ent.GetFloat('delay', 0) + TimerInterval(Ent)
      else
        FTimers[Ent] := -1;
    end;
    Exit;
  end else
  if CName = 'target_splash' then
  begin
    Particles.SpawnSplash(QuakeToCge(Ent.Origin), EntityMoveDir(Ent), Ent.Sounds,
      Ent.GetInt('count', 32));
    if Ent.Sounds = 1 then
      Sounds.PlayAtPoint('sound/world/spark' + IntToStr(5 + Random(3)) + '.wav', QuakeToCge(Ent.Origin));
  end else
  if CName = 'target_laser' then
  begin
    for Laser in FLasers do
      if Laser.Entity = Ent then
        Laser.IsOn := not Laser.IsOn;
  end else
  if CName = 'target_mal_laser' then
  begin
    for Laser in FLasers do
      if Laser.Entity = Ent then
        Laser.IsOn := not Laser.IsOn;
  end else
  if CName = 'misc_viper_missile' then
    ViperMissileUse(Ent)
  else
  if CName = 'misc_nuke' then
    NukeUse(Ent)
  else
  if CName = 'target_steam' then
    SteamUse(Ent, FUseSource)
  else
  if CName = 'target_anger' then
    AngerUse(Ent)
  else
  if CName = 'target_killplayers' then
    KillPlayersUse(Ent)
  else
  if (Copy(CName, 1, 5) = 'misc_') or (CName = 'monster_commander_body') or (CName = 'monster_boss3_stand') or
     (CName = 'rotating_light') then
  begin
    for Prop in FProps do
      if Prop.Entity = Ent then
        ActivateProp(Prop);
  end else
  if CName = 'target_temp_entity' then
    { Use_Target_Tent: the temp entity "style" at its origin }
    TempEntity(Ent.GetInt('style', 0), QuakeToCge(Ent.Origin))
  else
  if CName = 'turret_invisible_brain' then
  begin
    { turret_brain_activate: the first use starts it, the first shot "wait"
      (3) seconds later; the next use stops it for good }
    for Turret in FTurrets do
      if Turret.Brain = Ent then
      begin
        if Turret.BrainStopped then
          Break;
        if not Turret.BrainOn then
        begin
          Turret.BrainOn := True;
          Turret.AttackFinished := FTime + Ent.GetFloat('wait', 3);
          WritelnLog('QuakeWorld', 'turret_invisible_brain "%s" starts', [Ent.TargetName]);
        end else
        begin
          Turret.BrainOn := False;
          Turret.BrainStopped := True;
          WritelnLog('QuakeWorld', 'turret_invisible_brain "%s" stops', [Ent.TargetName]);
        end;
        Break;
      end;
  end else
  if CName = 'target_explosion' then
  begin
    { use_target_explosion: its own "delay" postpones the blast }
    if Ent.GetFloat('delay', 0) > 0 then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 0);
      D.Target := '';
      D.Entity := Ent;
      FDelayed.Add(D);
    end else
      Explode(QuakeToCge(Ent.Origin), Ent.GetInt('dmg', 0), 120, False);
  end else
  if CName = 'target_help' then
  begin
    { spawnflags 1 = primary objective, else secondary }
    if (Ent.SpawnFlags and 1) <> 0 then
      FHelpPrimary := Msg
    else
      FHelpSecondary := Msg;
    Sounds.Play('sound/misc/pc_up.wav');
    if FHud <> nil then
    begin
      FHud.HelpPrimary := FHelpPrimary;
      FHud.HelpSecondary := FHelpSecondary;
      FHud.ShowMessage('Help computer updated (F1)', 3);
    end;
  end else
  if CName = 'target_earthquake' then
  begin
    { target_earthquake_use: shake for "count" seconds (default 5) }
    SetLength(FQuakes, Length(FQuakes) + 1);
    FQuakes[High(FQuakes)].Entity := Ent;
    FQuakes[High(FQuakes)].EndTime := FTime + Ent.GetFloat('count', 5);
    FQuakes[High(FQuakes)].NextShove := FTime;
    FQuakes[High(FQuakes)].NextSound := FTime;
  end else
  if CName = 'target_string' then
    TargetStringUse(Ent)
  else
  if CName = 'func_clock' then
  begin
    { func_clock_use: start once (again only with MULTI_USE after a reset) }
    for I := 0 to High(FClocks) do
      if (FClocks[I].Entity = Ent) and not FClocks[I].Activated then
      begin
        FClocks[I].Activated := True;
        ClockThink(I);
      end;
  end else
  if CName = 'target_blaster' then
  begin
    { use_target_blaster: a blaster bolt along movedir ("dmg" 15, "speed" 1000) }
    SpawnProjectile(pkBlasterBolt, QuakeToCge(Ent.Origin), EntityMoveDir(Ent), Ent.Speed(1000),
      Ent.GetInt('dmg', 15), False);
    Sounds.PlayAtPoint('sound/weapons/laser2.wav', QuakeToCge(Ent.Origin));
  end else
  if CName = 'func_killbox' then
  begin
    if EntityBox(Ent, Box) then
      KillBox(Box);
  end else
  if CName = 'target_spawner' then
  begin
    { use_target_spawner: a new entity of class "target" here, facing the
      same way (G_Spawn + ED_CallSpawn); "speed" throws it along movedir,
      which only matters for items in Quake 2 and is ignored here }
    NewEnt := TQuakeEntity.Create;
    NewEnt.SetField('classname', Ent.Target);
    NewEnt.SetField('origin', Ent.GetField('origin'));
    NewEnt.SetField('angle', Ent.GetField('angle', '0'));
    FBsp.Entities.Add(NewEnt);
    SpawnEntity(NewEnt);
    { Like KillBox at the spawn point: telefrag what is in the way }
    KillBox(Box3D(QuakeToCge(NewEnt.Origin) - Vector3(16, 24, 16), QuakeToCge(NewEnt.Origin) + Vector3(16, 32, 16)));
    WritelnLog('QuakeWorld', 'target_spawner made a %s', [Ent.Target]);
  end else
  if CName = 'trigger_elevator' then
    ElevatorUse(Ent, FUseSource)
  else
  if CName = 'dynamic_light' then
  begin
    { dynamic_light_use: on / off }
    if FCounters.TryGetValue(Ent, Count) then
    begin
      FCounters[Ent] := 1 - Count;
      if Count = 0 then
        WritelnLog('QuakeWorld', 'dynamic_light "%s" on', [Ent.TargetName])
      else
        WritelnLog('QuakeWorld', 'dynamic_light "%s" off', [Ent.TargetName]);
    end;
  end else
  if CName = 'trigger_relay' then
    UseTargetsOf(Ent)
  else
  if Copy(CName, 1, 8) = 'monster_' then
  begin
    for M in FMonsters do
      if M.Entity = Ent then
      begin
        if M.TurretWallWaiting then
          M.ActivateWallTurret
        else
        if M.Dormant then
          M.Spawn { TRIGGER_SPAWN }
        else
          M.Alert;
      end;
  end else
  if (CName = 'trigger_teleport') or (CName = 'trigger_disguise') then
  begin
    { trigger_teleport_use / trigger_disguise_use: on / off each time }
    for Trig in FTriggers do
      if Trig.Entity = Ent then
        Trig.Enabled := not Trig.Enabled;
  end else
  if Copy(CName, 1, 8) = 'trigger_' then
  begin
    { Using a TRIGGERED trigger enables it }
    for Trig in FTriggers do
      if Trig.Entity = Ent then
        Trig.Enabled := True;
  end else
  begin
    Mover := FGeometry.FindMoverByModel(Ent.Model);
    { Box movers spawned from the console have no *N model }
    if (Mover = nil) and (Ent.Model = '') then
      for M2 in FGeometry.Movers do
        if M2.Entity = Ent then
          Mover := M2;
    if Mover <> nil then
    begin
      if Mover.Kind = mkStatic then
      begin
        if CName = 'func_explosive' then
          BreakExplosive(Mover)
        else
        if CName = 'func_object' then
        begin
          { func_object_use: appears (KillBox) and falls }
          if not Mover.Transform.Exists then
          begin
            Mover.Transform.Exists := True;
            KillBox(Mover.WorldBox);
            Mover.Tossing := True;
          end;
        end else
        if CName = 'func_wall' then
        begin
          { func_wall_use: a plain wall has no use; it appears (killing
            what is in the way, KillBox) and, with TOGGLE, also goes away }
          if (Ent.SpawnFlags and 7) <> 0 then
          begin
            if not Mover.Transform.Exists then
            begin
              Mover.Transform.Exists := True;
              KillBox(Mover.WorldBox);
            end else
            if (Ent.SpawnFlags and 2) <> 0 then
              Mover.Transform.Exists := False;
          end;
        end else
          Mover.Transform.Exists := not Mover.Transform.Exists;
      end else
        Mover.Use;
    end;
  end;

  { Only "target_*" entities pass the activation further here; movers fire
    their own targets when they finish (buttons) }
  if (Copy(CName, 1, 7) = 'target_') and (Ent.Target <> '') then
  begin
    if Ent.GetFloat('delay', 0) > 0 then
    begin
      D.Time := FTime + Ent.GetFloat('delay', 0);
      D.Target := Ent.Target;
      D.Entity := nil;
      FDelayed.Add(D);
    end else
      UseTargets(Ent.Target, Ent);
  end;
end;

function TQuakeWorld.TimerInterval(const Ent: TQuakeEntity): Single;
begin
  { Quake 2 func_timer: wait + crandom() * random }
  Result := Max(0.1, Ent.GetFloat('wait', 1) + (Random * 2 - 1) * Ent.GetFloat('random', 0));
end;

procedure TQuakeWorld.KillBox(const Box: TBox3D);
var
  M: TQuakeMonster;
  Prop: TQuakeProp;
begin
  { KillBox: MOD_TELEFRAG damage to everything solid in the box }
  if (FCur.PM <> nil) and not FCur.Dead and Box.Collision(PlayerBox) then
    DamagePlayer(100000, Box.Center);
  for M in FMonsters do
    if M.IsAlive and not M.Dormant and
       Box.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
      M.TakeDamage(100000);
  for Prop in FProps do
    if (Prop.Kind = pkExplobox) and not Prop.Destroyed and Box.Contains(Prop.Transform.Translation) then
      DamageProp(Prop, 100000);
end;

procedure TQuakeWorld.SetPlayerGravity(const Value: Single);
begin
  FCur.Gravity := Value;
  if (FCur.PM <> nil) and (FBaseGravity > 0) then
    FCur.PM.GravityAcceleration := FBaseGravity * Value;
end;

function TQuakeWorld.EarthquakeCount: Integer;
begin
  Result := Length(FQuakes);
end;

procedure TQuakeWorld.ResetClock(const I: Integer);
var
  Flags, Count: Integer;
begin
  { func_clock_reset }
  Flags := FClocks[I].Entity.SpawnFlags;
  Count := FClocks[I].Entity.GetInt('count', 0);
  if ((Flags and 1) <> 0) and (Count = 0) then
    Count := 60 * 60;
  FClocks[I].Activated := False;
  if (Flags and 1) <> 0 then
  begin
    FClocks[I].Health := 0;
    FClocks[I].Wait := Count;
  end else
  if (Flags and 2) <> 0 then
  begin
    FClocks[I].Health := Count;
    FClocks[I].Wait := 0;
  end;
end;

procedure TQuakeWorld.ClockThink(const I: Integer);
var
  Ent: TQuakeEntity;
  Flags, Style: Integer;
  Text: String;
  List: TQuakeEntityList;
  H, M, Sec, MSec: Word;
begin
  { func_clock_think, once a second }
  Ent := FClocks[I].Entity;
  Flags := Ent.SpawnFlags;
  Style := Ent.GetInt('style', 0);
  if FClocks[I].Display = nil then
  begin
    List := FBsp.FindByTargetName(Ent.Target);
    try
      if List.Count > 0 then
        FClocks[I].Display := List[0];
    finally
      List.Free;
    end;
    if FClocks[I].Display = nil then
    begin
      FClocks[I].NextThink := -1;
      Exit;
    end;
  end;
  if (Flags and 1) <> 0 then
  begin
    Text := ClockText(Style, FClocks[I].Health);
    Inc(FClocks[I].Health);
  end else
  if (Flags and 2) <> 0 then
  begin
    Text := ClockText(Style, FClocks[I].Health);
    Dec(FClocks[I].Health);
  end else
  begin
    { The time of day }
    DecodeTime(Now, H, M, Sec, MSec);
    Text := ClockText(2, H * 3600 + M * 60 + Sec);
  end;
  FClocks[I].Display.SetField('message', Text);
  TargetStringUse(FClocks[I].Display);
  FClocks[I].NextThink := FTime + 1;
  if (((Flags and 1) <> 0) and (FClocks[I].Health > FClocks[I].Wait)) or
     (((Flags and 2) <> 0) and (FClocks[I].Health < FClocks[I].Wait)) then
  begin
    { Time is up: fire the pathtarget }
    if Ent.GetField('pathtarget') <> '' then
    begin
      WritelnLog('QuakeWorld', 'func_clock fires "%s"', [Ent.GetField('pathtarget')]);
      UseTargets(Ent.GetField('pathtarget'));
    end;
    if (Flags and 8) = 0 then
    begin
      FClocks[I].NextThink := -1;
      Exit;
    end;
    ResetClock(I);
    if (Flags and 4) <> 0 then
      FClocks[I].NextThink := -1;
  end;
end;

procedure TQuakeWorld.UpdateClocks;
var
  I: Integer;
begin
  for I := 0 to High(FClocks) do
    if (FClocks[I].NextThink >= 0) and (FTime >= FClocks[I].NextThink) then
      ClockThink(I);
end;

procedure TQuakeWorld.TargetStringUse(const Ent: TQuakeEntity);
var
  Mover: TQuakeMover;
  Team, Msg: String;
begin
  Team := Ent.GetField('team');
  Msg := Ent.MessageText;
  FLastString := Msg;
  if Team = '' then
    Exit;
  for Mover in FGeometry.Movers do
    if (Mover.Entity.ClassName = 'target_character') and (Mover.Entity.GetField('team') = Team) and
       (Mover.Entity.GetInt('count', 0) > 0) then
      Mover.CharFrame := CharacterFrame(Msg, Mover.Entity.GetInt('count', 0));
end;

procedure TQuakeWorld.UpdateEarthquakes;
var
  I: Integer;
  V: TVector3;
begin
  { target_earthquake_think, every 0.1 s: shove the player while on the
    ground (Quake 2 adds crandom() * 150 sideways and sets the vertical
    speed to speed * 100 / mass, mass 200), quake.wav every 0.5 s }
  for I := High(FQuakes) downto 0 do
  begin
    if FTime >= FQuakes[I].EndTime then
    begin
      Delete(FQuakes, I, 1);
      Continue;
    end;
    if FTime >= FQuakes[I].NextSound then
    begin
      FQuakes[I].NextSound := FTime + 0.5;
      Sounds.Play('sound/world/quake.wav');
    end;
    if (FTime >= FQuakes[I].NextShove) and (FCur.PM <> nil) and FCur.PM.OnGround and not FCur.Dead then
    begin
      FQuakes[I].NextShove := FTime + 0.1;
      V := FCur.PM.Velocity;
      V.X := V.X + (Random * 2 - 1) * 150;
      V.Z := V.Z + (Random * 2 - 1) * 150;
      V.Y := FQuakes[I].Entity.Speed(200) * 0.5;
      FCur.PM.Velocity := V;
    end;
  end;
end;

procedure TQuakeWorld.UpdateTimersAndLasers(const SecondsPassed: Single);
var
  Pair: specialize TPair<TQuakeEntity, Single>;
  Fire: TQuakeEntityList;
  Ent: TQuakeEntity;
  Laser: TQuakeLaser;
  Prop: TQuakeProp;
  List: TQuakeEntityList;
  Dist: Single;
  LaserTrace: TQuakeTrace;
begin
  { func_timer }
  Fire := TQuakeEntityList.Create(False);
  try
    for Pair in FTimers do
      if (Pair.Value >= 0) and (Pair.Value <= FTime) then
        Fire.Add(Pair.Key);
    for Ent in Fire do
    begin
      FTimers[Ent] := FTime + TimerInterval(Ent);
      UseTargets(Ent.Target, Ent);
    end;
  finally
    Fire.Free;
  end;

  { func_object_repair: welding sparks every "delay" seconds; misc_amb4:
    world/amb4.wav everywhere every 2 s }
  Fire := TQuakeEntityList.Create(False);
  try
    for Pair in FPeriodic do
      if Pair.Value <= FTime then
        Fire.Add(Pair.Key);
    for Ent in Fire do
      if Ent.ClassName = 'misc_amb4' then
      begin
        FPeriodic[Ent] := FTime + 2;
        Sounds.PlayAtPoint('sound/world/amb4.wav', QuakeToCge(Ent.Origin), 1, ATTN_NONE);
      end else
        RepairThink(Ent);
  finally
    Fire.Free;
  end;

  UpdateSteam;
  { target_laser: beam until the first wall, damages the player in it }
  for Laser in FLasers do
  begin
    if not Laser.IsOn then
      Continue;
    if Laser.Mal then
    begin
      UpdateMalLaser(Laser, SecondsPassed);
      Continue;
    end;
    { target_laser_think: a MASK_SHOT trace; it hurts what it stops on }
    LaserTrace := WorldTrace(CgeToQuake(Laser.Origin), CgeToQuake(Laser.Origin + Laser.Direction * 2048),
      TVector3.Zero, TVector3.Zero, MASK_SHOT, nil);
    Dist := PointsDistance(Laser.Origin, QuakeToCge(LaserTrace.EndPos));
    Laser.SetLength(Dist);
    if LaserTrace.Ent is TQuakeMonster then
      TQuakeMonster(LaserTrace.Ent).TakeDamage(Max(1, Laser.Damage div 10));
    if (LaserTrace.Ent is TQuakePMove) and (PlayerOfEnt(LaserTrace.Ent) <> nil) then
    begin
      PlayerOfEnt(LaserTrace.Ent).HurtTimer := PlayerOfEnt(LaserTrace.Ent).HurtTimer - SecondsPassed;
      if PlayerOfEnt(LaserTrace.Ent).HurtTimer <= 0 then
      begin
        PlayerOfEnt(LaserTrace.Ent).HurtTimer := 0.1;
        DamagePlayerHit(LaserTrace.Ent, Laser.Damage div 10, Laser.Origin);
      end;
    end;
  end;

  { Props: animation, ships following their path_corners }
  for Prop in FProps do
  begin
    Prop.UpdateProp(SecondsPassed);
    if Prop.Flying and (PointsDistance(Prop.Transform.Translation, Prop.FlyTarget) < 1) then
    begin
      UseTargets(Prop.FlyCorner.GetField('pathtarget'));
      List := FBsp.FindByTargetName(Prop.FlyCorner.Target);
      try
        if (Prop.FlyCorner.Target <> '') and (List.Count > 0) then
        begin
          Prop.FlyCorner := List[0];
          Prop.FlyTarget := QuakeToCge(List[0].Origin);
        end else
        begin
          { The ships vanish at the end of their path; misc_transport is a
            train and stays at its last corner }
          Prop.Flying := False;
          if Prop.Kind <> pkTransport then
            Prop.Transform.Exists := False;
        end;
      finally
        List.Free;
      end;
    end;
  end;
end;

procedure TQuakeWorld.SteamPuff(const Ent: TQuakeEntity);
var
  Dir, Pos: TVector3;
  Speed: Single;
  List: TQuakeEntityList;
begin
  { use_target_steam: towards the target's centre (else its angles), from
    half the speed out along it }
  Speed := Ent.GetFloat('speed', 75);
  Dir := EntityMoveDir(Ent);
  if Ent.Target <> '' then
  begin
    List := FBsp.FindByTargetName(Ent.Target);
    try
      if (List.Count > 0) and not (List[0].Origin - Ent.Origin).IsZero then
        Dir := QuakeToCge(List[0].Origin) - QuakeToCge(Ent.Origin);
    finally
      List.Free;
    end;
  end;
  if Dir.IsZero then
    Dir := Vector3(0, 1, 0)
  else
    Dir := Dir.Normalize;
  Pos := QuakeToCge(Ent.Origin) + Dir * (Speed * 0.5);
  Particles.SpawnSteam(Pos, Dir, Ent.GetInt('count', 32), Speed, Ent.GetInt('sounds', 8));
end;

procedure TQuakeWorld.SteamUse(const Ent, Activator: TQuakeEntity);
var
  Wait: Single;
begin
  { "wait" seconds of steam (else the using func_timer's, else 1): more
    than 0.1 s is a sustained effect, puffing every 0.1 s }
  if Ent.HasField('wait') then
    Wait := Ent.GetFloat('wait', 1)
  else
  if (Activator <> nil) and (Activator.ClassName = 'func_timer') then
    Wait := Activator.GetFloat('wait', 1)
  else
    Wait := 1;
  WritelnLog('QuakeWorld', 'target_steam puffs for %.1f s', [Wait]);
  SteamPuff(Ent);
  if Wait > 0.1 then
    FSteam.AddOrSetValue(Ent, Vector2(FTime + Wait, FTime + 0.1));
end;

procedure TQuakeWorld.UpdateSteam;
var
  Pair: specialize TPair<TQuakeEntity, TVector2>;
  Done: TQuakeEntityList;
  E: TQuakeEntity;
begin
  if FSteam.Count = 0 then
    Exit;
  Done := TQuakeEntityList.Create(False);
  try
    for Pair in FSteam do
      if FTime >= Pair.Value.X then
        Done.Add(Pair.Key)
      else
      if FTime >= Pair.Value.Y then
        Done.Add(Pair.Key);
    for E in Done do
      if FTime >= FSteam[E].X then
        FSteam.Remove(E)
      else
      begin
        SteamPuff(E);
        FSteam[E] := Vector2(FSteam[E].X, FTime + 0.1);
      end;
  finally
    Done.Free;
  end;
end;

procedure TQuakeWorld.AngerUse(const Ent: TQuakeEntity);
var
  Victims: TQuakeEntityList;
  M: TQuakeMonster;
  Pos: TVector3;
begin
  { target_anger_use: the monsters named by "target" go after the entity
    named by "killtarget" (an info_notnull in the game's maps: they shoot
    at a spot) }
  if (Ent.Target = '') or (Ent.GetField('killtarget') = '') then
    Exit;
  Victims := FBsp.FindByTargetName(Ent.GetField('killtarget'));
  try
    if Victims.Count = 0 then
      Exit;
    Pos := QuakeToCge(Victims[0].Origin);
  finally
    Victims.Free;
  end;
  for M in FMonsters do
    if M.IsAlive and SameText(M.Entity.TargetName, Ent.Target) then
    begin
      if M.Dormant then
        M.Spawn;
      M.AngerActive := True;
      M.AngerPos := Pos;
      M.Alert;
      WritelnLog('QuakeWorld', '%s angered at %s', [M.Transform.Name, Ent.GetField('killtarget')]);
    end;
end;

procedure TQuakeWorld.KillPlayersUse(const Ent: TQuakeEntity);
var
  M: TQuakeMonster;
  Count: Integer;
begin
  { target_killplayers_use: the player dies, and so does every monster the
    player can see }
  Count := 0;
  for M in FMonsters do
    if M.IsAlive and (not M.Dormant) and M.HasLineOfSight(FCur.Pos) then
    begin
      M.TakeDamage(M.Health);
      Inc(Count);
    end;
  WritelnLog('QuakeWorld', 'target_killplayers: the player and %d monsters killed', [Count]);
  DamagePlayer(100000, QuakeToCge(Ent.Origin), True);
end;

procedure TQuakeWorld.UpdateMalLaser(const Laser: TQuakeLaser; const SecondsPassed: Single);
var
  T: TQuakeTrace;
  From, Stop: TVector3;
  Ignore: TObject;
  I: Integer;
  Pulse: Boolean;
begin
  { mal_laser_think: the beam goes through monsters and the player (each
    hit takes "dmg" on a pulse) and stops at anything else }
  Laser.PulseTimer := Laser.PulseTimer - SecondsPassed;
  Pulse := Laser.PulseTimer <= 0;
  if Pulse then
    Laser.PulseTimer := Laser.PulseTimer + Laser.Wait + 0.1;
  From := CgeToQuake(Laser.Origin);
  Stop := CgeToQuake(Laser.Origin + Laser.Direction * 2048);
  Ignore := nil;
  for I := 1 to 16 do
  begin
    T := WorldTrace(From, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    if T.Ent is TQuakeMonster then
    begin
      if Pulse then
        TQuakeMonster(T.Ent).TakeDamage(Laser.Damage);
    end else
    if T.Ent is TQuakePMove then
    begin
      if Pulse then
        DamagePlayerHit(T.Ent, Laser.Damage, Laser.Origin);
    end else
      Break;
    Ignore := T.Ent;
    From := T.EndPos;
  end;
  Laser.SetLength(PointsDistance(Laser.Origin, QuakeToCge(T.EndPos)));
  if Pulse then
  begin
    if (Laser.Pulses > 0) and (T.Fraction < 1) then
      TempEntity(TE_LASER_SPARKS, QuakeToCge(T.EndPos));
    Inc(Laser.Pulses);
  end;
end;

function TQuakeWorld.PickTarget(const ATargetName: String): TQuakeEntity;
var
  List: TQuakeEntityList;
begin
  Result := nil;
  if (ATargetName = '') or (FBsp = nil) then
    Exit;
  List := FBsp.FindByTargetName(ATargetName);
  try
    if List.Count > 0 then
      Result := List[Random(List.Count)];
  finally
    List.Free;
  end;
end;

procedure TQuakeWorld.UseTargets(const ATarget: String; const Source: TQuakeEntity);
var
  List: TQuakeEntityList;
  Ent, OldSource: TQuakeEntity;
begin
  if (ATarget = '') or (FBsp = nil) or (FUseDepth > 16) then
    Exit;
  Inc(FUseDepth);
  OldSource := FUseSource;
  List := FBsp.FindByTargetName(ATarget);
  try
    for Ent in List do
    begin
      FUseSource := Source;
      UseEntity(Ent);
    end;
  finally
    List.Free;
    FUseSource := OldSource;
    Dec(FUseDepth);
  end;
end;

{ dynamic_light: a light each frame while on, at its "shadowlightradius",
  coloured, times "shadowlightintensity" and its light style
  ("shadowlightstyle", or the style of the "shadowlightstyletarget" light) }
procedure TQuakeWorld.UpdateDynamicLights;
var
  Prop: TQuakeProp;
  Ent, StyleEnt: TQuakeEntity;
  OnOff, Style: Integer;
  Brightness: Single;
  List: TQuakeEntityList;
begin
  { EF_SPINNINGLIGHTS (CL_AddPacketEntities): a red light of radius 100 going
    round the rotating_light 64 units out, at its height }
  for Prop in FProps do
    if (Prop.Kind = pkRotatingLight) and Prop.LightOn and not Prop.Destroyed and
       Prop.Transform.Exists then
      Lighting.AddLight(Prop.Transform.Translation +
        YawToCgeDir(Prop.Entity.Angle + Prop.SpinAngle) * 64, 100, Vector3(1, 0, 0));
  for Ent in FDynamicLights do
  begin
    if (not FCounters.TryGetValue(Ent, OnOff)) or (OnOff = 0) then
      Continue;
    Style := Ent.GetInt('shadowlightstyle', -1);
    if Ent.GetField('shadowlightstyletarget') <> '' then
    begin
      List := FBsp.FindByTargetName(Ent.GetField('shadowlightstyletarget'));
      try
        if List.Count > 0 then
        begin
          StyleEnt := List[0];
          Style := StyleEnt.GetInt('style', Style);
        end;
      finally
        List.Free;
      end;
    end;
    Brightness := Ent.GetFloat('shadowlightintensity', 1);
    if Style >= 0 then
      Brightness := Brightness * Lighting.StyleValue(Style);
    if Brightness <= 0 then
      Continue;
    Lighting.AddLight(QuakeToCge(Ent.Origin), Ent.GetFloat('shadowlightradius', 0),
      RemasterLightColor(Ent) * Brightness);
  end;
end;

{ Quake 2 trigger_elevator_use: sends its func_train to a path_corner named
  by the pathtarget of whatever used it (a button for each floor), unless
  the train is moving }
procedure TQuakeWorld.ElevatorUse(const Ent, Source: TQuakeEntity);
var
  Mover, Train: TQuakeMover;
  Corners: TQuakeEntityList;
  Corner: TQuakeEntity;
begin
  Train := nil;
  for Mover in FGeometry.Movers do
    if (Mover.Kind = mkTrain) and (Mover.TargetName <> '') and (Mover.TargetName = Ent.Target) then
    begin
      Train := Mover;
      Break;
    end;
  if Train = nil then
  begin
    WritelnLog('QuakeWorld', 'trigger_elevator "%s": target "%s" is not a func_train', [Ent.TargetName, Ent.Target]);
    Exit;
  end;
  if Train.TrainRunning and not Train.TrainWaiting then
    Exit;
  if (Source = nil) or (Source.GetField('pathtarget') = '') then
  begin
    WritelnLog('QuakeWorld', 'trigger_elevator "%s" used with no pathtarget', [Ent.TargetName]);
    Exit;
  end;
  Corners := FBsp.FindByTargetName(Source.GetField('pathtarget'));
  try
    if Corners.Count = 0 then
    begin
      WritelnLog('QuakeWorld', 'trigger_elevator "%s": bad pathtarget "%s"', [Ent.TargetName, Source.GetField('pathtarget')]);
      Exit;
    end;
    { G_PickTarget: one of them at random }
    Corner := Corners[Random(Corners.Count)];
  finally
    Corners.Free;
  end;
  Train.TrainResume(Corner);
  WritelnLog('QuakeWorld', 'trigger_elevator "%s" sends %s to "%s"', [Ent.TargetName, Train.Entity.Model, Corner.TargetName]);
end;

procedure TQuakeWorld.CheckTriggers(const SecondsPassed: Single);
var
  Trig: TQuakeTrigger;
  CName, Msg: String;
  PBox: TBox3D;
  Dests: TQuakeEntityList;
  Dest: TQuakeEntity;
  D: TDelayedTarget;
begin
  PBox := PlayerBox;
  for Trig in FTriggers do
  begin
    { Once a tick: on the local player's pass }
    if IsLocal then
      Trig.Cooldown := Max(0, Trig.Cooldown - SecondsPassed);
    if (not Trig.Enabled) or (Trig.Cooldown > 0) or not Trig.Box.Collision(PBox) then
      Continue;

    CName := Trig.Entity.ClassName;
    if CName = 'trigger_hurt' then
    begin
      FCur.HurtTimer := FCur.HurtTimer - SecondsPassed;
      if FCur.HurtTimer <= 0 then
      begin
        FCur.HurtTimer := 0.1;
        DamagePlayer(Max(1, Trig.Entity.GetInt('dmg', 5)), Trig.Box.Center);
      end;
      Continue;
    end;

    if (CName = 'misc_teleporter') or (CName = 'trigger_teleport') then
    begin
      { teleporter_touch / trigger_teleport_touch (G_PickTarget: one of the
        destinations at random) to misc_teleporter_dest or
        info_teleport_destination, 10 above it, facing its angle }
      Dests := FBsp.FindByTargetName(Trig.Entity.Target);
      try
        if Dests.Count > 0 then
        begin
          Dest := Dests[Random(Dests.Count)];
          if CName = 'misc_teleporter' then
            Dest := Dests[0];
          if IsLocal then
          begin
            { The view places the camera (and the server's player) }
            FTeleportPending := True;
            FTeleportPos := QuakeToCge(Dest.Origin) + Vector3(0, PlayerEyeHeight - 24 + 10, 0);
            FTeleportAngle := Dest.Angle;
          end else
          if FCur.PM <> nil then
          begin
            { Another player: its pmove at once }
            FCur.PM.Origin := Dest.Origin + Vector3(0, 0, 10);
            FCur.PM.ResetState;
            FCur.Pos := QuakeToCge(FCur.PM.Origin + Vector3(0, 0, FCur.PM.ViewHeight));
            FCur.Dir := YawToCgeDir(Dest.Angle);
            Inc(FCur.ViewTurns);
          end;
          Particles.SpawnTeleport(QuakeToCge(Dest.Origin) + Vector3(0, PlayerEyeHeight - 24 + 10, 0));
          Sounds.Play('sound/misc/tele1.wav');
          Trig.Cooldown := 1.0;
        end;
      finally
        Dests.Free;
      end;
      Continue;
    end;

    if (CName = 'trigger_multiple') or (CName = 'trigger_once') then
    begin
      Msg := Trig.Entity.MessageText;
      if (Msg <> '') and (FHud <> nil) then
      begin
        FHud.ShowMessage(Msg, 4);
        Sounds.Play('sound/misc/talk1.wav');
      end;
      if Trig.Entity.GetFloat('delay', 0) > 0 then
      begin
        D.Time := FTime + Trig.Entity.GetFloat('delay', 0);
        D.Target := Trig.Entity.Target;
        D.Entity := nil;
        FDelayed.Add(D);
      end else
        UseTargets(Trig.Entity.Target, Trig.Entity);
      if CName = 'trigger_once' then
        Trig.Enabled := False
      else
        Trig.Cooldown := Max(0.2, Trig.Entity.GetFloat('wait', 0.2));
    end else
    if CName = 'trigger_disguise' then
    begin
      { trigger_disguise_touch: disguised (REMOVE, 4: no longer) }
      PlayerDisguised := (Trig.Entity.SpawnFlags and 4) = 0;
      Continue;
    end else
    if CName = 'trigger_gravity' then
    begin
      { trigger_gravity_touch: the toucher keeps this gravity multiplier }
      SetPlayerGravity(Trig.Entity.GetFloat('gravity', 1));
      Continue;
    end else
    if CName = 'trigger_push' then
    begin
      { Quake 2 trigger_push: velocity = movedir * speed * 10 (speed default 1000) }
      if FCur.PM <> nil then
        FCur.PM.Velocity := EntityMoveDir(Trig.Entity) * Trig.Entity.GetFloat('speed', 1000) * 10;
      Sounds.Play('sound/misc/windfly.wav');
      { PUSH_ONCE = 1 }
      if (Trig.Entity.SpawnFlags and 1) <> 0 then
        Trig.Enabled := False
      else
        Trig.Cooldown := 0.1;
    end;
  end;
end;

procedure TQuakeWorld.CheckMonsterTriggers;
var
  Trig: TQuakeTrigger;
  Monster: TQuakeMonster;
  Dir: TVector3;
  Speed, Height: Single;
begin
  for Trig in FTriggers do
  begin
    if (not Trig.Enabled) or (Trig.Entity.ClassName <> 'trigger_monsterjump') then
      Continue;
    { SP_trigger_monsterjump: speed 200, height 200; movedir is horizontal }
    Speed := Trig.Entity.GetFloat('speed', 200);
    Height := Trig.Entity.GetFloat('height', 200);
    Dir := EntityMoveDir(Trig.Entity);
    Dir.Y := 0;
    if not Dir.IsZero then
      Dir := Dir.Normalize;
    for Monster in FMonsters do
      if Monster.IsAlive and (not Monster.Dormant) and (not Monster.Def^.Flying) and
         Trig.Box.Collision(Monster.Transform.BoundingBox) then
        Monster.MonsterJump(Dir * Speed, Height);
  end;
end;

procedure TQuakeWorld.SetSurfaceLights;
var
  Lights: TQuakeSurfaceLights;
  Count: Integer;
begin
  Count := Lighting.NearestLights(FCur.Pos, Lights);
  FGeometry.SetSurfaceLights(Lights, Count);
end;

procedure TQuakeWorld.ActivateUse(const Origin, Dir: TVector3);
var
  Hit: TCastleTransform;
  Dist: Single;
  Mover: TQuakeMover;
begin
  if FBsp = nil then
    Exit;
  Hit := FItems.WorldRayCast(Origin, Dir, Dist);
  if (Hit = nil) or (Dist > 96) then
    Exit;
  Mover := MoverByTransform(Hit);
  if (Mover <> nil) and (Mover.Kind in [mkDoor, mkDoorRotating, mkButton, mkPlat]) and
     ((Mover.Kind = mkButton) or Mover.AutoOpen) then
    Mover.Use;
end;
