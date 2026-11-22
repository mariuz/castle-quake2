{ Props: misc_* models, falling objects, temp entities.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

function TQuakeWorld.PropByTransform(const T: TCastleTransform): TQuakeProp;
var
  Prop: TQuakeProp;
begin
  for Prop in FProps do
    if Prop.OwnsTransform(T) then
      Exit(Prop);
  Result := nil;
end;

function TQuakeWorld.GibTraceMap(const Start, Stop: TVector3; out EndPos, Normal: TVector3): Boolean;
var
  T: TQuakeTrace;
begin
  EndPos := Stop;
  Normal := Vector3(0, 1, 0);
  Result := False;
  if FBsp = nil then
    Exit;
  T := WorldTrace(CgeToQuake(Start), CgeToQuake(Stop), TVector3.Zero, TVector3.Zero,
    CONTENTS_SOLID or CONTENTS_WINDOW, nil);
  if T.AllSolid then
    Exit;
  Result := T.Hit;
  if Result then
  begin
    EndPos := QuakeToCge(T.EndPos);
    Normal := QuakeToCge(T.Normal) - QuakeToCge(TVector3.Zero);
  end;
end;

procedure TQuakeWorld.UpdateFallingObjects(const SecondsPassed: Single);
var
  Mover: TQuakeMover;
  Box: TBox3D;
  A, B, QMin, QMax, C: TVector3;
  T: TQuakeTrace;
begin
  { func_object: MOVETYPE_TOSS (gravity 800) until it lands }
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
    if Mover.Tossing and Mover.Transform.Exists then
    begin
      Box := Mover.WorldBox;
      if Box.IsEmpty then
      begin
        Mover.Tossing := False;
        Continue;
      end;
      A := CgeToQuake(Box.Data[0]);
      B := CgeToQuake(Box.Data[1]);
      QMin := Vector3(Min(A.X, B.X), Min(A.Y, B.Y), Min(A.Z, B.Z));
      QMax := Vector3(Max(A.X, B.X), Max(A.Y, B.Y), Max(A.Z, B.Z));
      C := (QMin + QMax) * 0.5;
      Mover.TossSpeed := Min(Mover.TossSpeed + 800 * SecondsPassed, 2000);
      { SV_Physics_Toss with MASK_SOLID: it falls through players and
        monsters onto walls and floors (so func_object_touch, which only
        hurts what it lands on, never fires in practice) }
      T := WorldTrace(C, C - Vector3(0, 0, Mover.TossSpeed * SecondsPassed), QMin - C, QMax - C,
        CONTENTS_SOLID or CONTENTS_WINDOW, Mover);
      if T.StartSolid then
      begin
        Mover.Tossing := False;
        Continue;
      end;
      Mover.Transform.Translation := Mover.Transform.Translation + QuakeToCge(T.EndPos) - QuakeToCge(C);
      if T.Fraction < 1 then
      begin
        Mover.Tossing := False;
        Mover.TossSpeed := 0;
      end;
    end;
end;

procedure TQuakeWorld.UpdateFallingProps(const SecondsPassed: Single);
var
  Prop: TQuakeProp;
  OldPos, NewPos: TVector3;
  T: TQuakeTrace;
  Dmg: Integer;
begin
  { misc_viper_bomb: MOVETYPE_TOSS until it touches something, then
    misc_viper_bomb_touch: radius damage "dmg" (1000) }
  for Prop in FProps do
    if Prop.Falling and not Prop.Destroyed then
    begin
      Prop.Velocity.Y := Prop.Velocity.Y - 800 * SecondsPassed;
      OldPos := Prop.Transform.Translation;
      NewPos := OldPos + Prop.Velocity * SecondsPassed;
      if not Prop.Velocity.IsZero then
        Prop.Transform.Rotation := Vector4(0, 1, 0, ArcTan2(-Prop.Velocity.Z, Prop.Velocity.X));
      T := WorldTrace(CgeToQuake(OldPos), CgeToQuake(NewPos), Vector3(-8, -8, -8), Vector3(8, 8, 8),
        MASK_SHOT, Prop);
      if T.Hit then
      begin
        Prop.Falling := False;
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
        Dmg := Prop.Entity.GetInt('dmg', 1000);
        Explode(QuakeToCge(T.EndPos), Dmg, Dmg + 40, False);
        UseTargets(Prop.Entity.Target, Prop.Entity);
      end else
        Prop.Transform.Translation := NewPos;
    end;
end;

procedure TQuakeWorld.TempEntity(const Style: Integer; const Pos: TVector3);
begin
  { The client's CL_ParseTEnt for the temp entities maps use }
  case Style of
    TE_EXPLOSION1, TE_EXPLOSION2, TE_ROCKET_EXPLOSION, TE_GRENADE_EXPLOSION,
    TE_ROCKET_EXPLOSION_WATER, TE_GRENADE_EXPLOSION_WATER:
      begin
        Particles.SpawnExplosion(Pos);
        if Style in [TE_GRENADE_EXPLOSION, TE_GRENADE_EXPLOSION_WATER] then
          Sounds.PlayAtPoint('sound/weapons/grenlx1a.wav', Pos)
        else
          Sounds.PlayAtPoint('sound/weapons/rocklx1a.wav', Pos);
      end;
    TE_BFG_EXPLOSION, TE_BFG_BIGEXPLOSION:
      Particles.SpawnBfgExplosion(Pos);
    TE_BOSSTPORT:
      begin
        { CL_BigTeleportParticles and misc/bigtele.wav, heard everywhere }
        Particles.SpawnTeleport(Pos);
        Particles.SpawnTeleport(Pos + Vector3(0, 40, 0));
        Sounds.PlayAtPoint('sound/misc/bigtele.wav', Pos, 1, ATTN_NONE);
      end;
    TE_GUNSHOT, TE_SHOTGUN, TE_SPARKS, TE_BULLET_SPARKS, TE_SCREEN_SPARKS, TE_SHIELD_SPARKS,
    TE_LASER_SPARKS, TE_WELDING_SPARKS:
      Particles.SpawnImpact(Pos, Vector3(0, 1, 0));
    TE_BLOOD:
      Particles.SpawnBlood(Pos, Vector3(0, 1, 0));
    TE_BLASTER:
      Particles.SpawnBlasterImpact(Pos, Vector3(0, 1, 0));
    TE_SPLASH:
      Particles.SpawnSplash(Pos, Vector3(0, 1, 0), 0, 32);
  else
    WritelnLog('QuakeWorld', 'target_temp_entity style %d not drawn', [Style]);
  end;
end;

procedure TQuakeWorld.ActivateProp(const Prop: TQuakeProp);
var
  Other: TQuakeProp;
begin
  case Prop.Kind of
    pkSatelliteDish:
      if Prop.Model <> nil then
        Prop.Model.PlayAnim('', False, 10);
    pkCommanderBody:
      if not Prop.ThudPlayed and not Prop.AnimOnce then
      begin
        { commander_body_use: the tank's pain sound, then frames 1..24 }
        Sounds.PlayAt('sound/tank/pain.wav', Prop.Transform, 1, 1, chBody);
        Prop.AnimFirst := 1;
        Prop.AnimLast := 24;
        Prop.AnimTime := 0;
        Prop.AnimOnce := True;
      end;
    pkBoss3Stand:
      begin
        { Use_Boss3: TE_BOSSTPORT, and the Makron is gone }
        TempEntity(TE_BOSSTPORT, Prop.Transform.Translation);
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
      end;
    pkBlackHole:
      begin
        { misc_blackhole_use: it goes away }
        Prop.Destroyed := True;
        Prop.Transform.Exists := False;
      end;
    pkViperBomb:
      if not Prop.Falling and not Prop.Destroyed then
      begin
        { misc_viper_bomb_use: drop with the velocity of the flying viper }
        Prop.Transform.Exists := True;
        Prop.Falling := True;
        Prop.Velocity := TVector3.Zero;
        for Other in FProps do
          if (Other.Kind = pkViper) and Other.Flying then
          begin
            Prop.Velocity := Other.FlyTarget - Other.Transform.Translation;
            if not Prop.Velocity.IsZero then
              Prop.Velocity := Prop.Velocity.Normalize * Other.FlySpeed;
            Break;
          end;
      end;
    pkStroggShip, pkViper:
      if StartPropFlight(Prop) then
        Prop.Transform.Exists := True;
    pkTransport:
      { misc_strogg_ship_use: shown; train_use ignores the use (START_ON) }
      Prop.Transform.Exists := True;
    pkNukeCore:
      { misc_nuke_core_use: shown / hidden }
      Prop.Transform.Exists := not Prop.Transform.Exists;
    pkRotatingLight:
      if not Prop.Destroyed then
      begin
        { rotating_light_use: toggles the light; turning it on starts the
          alarm (0.1 s later) when it has one }
        Prop.LightOn := not Prop.LightOn;
        Prop.AlarmActive := Prop.LightOn and Prop.Alarm;
        Prop.AlarmTimer := 0.1;
      end;
    pkExplobox:
      DamageProp(Prop, 1000);
  end;
end;

function TQuakeWorld.StartPropFlight(const Prop: TQuakeProp): Boolean;
var
  List: TQuakeEntityList;
begin
  List := FBsp.FindByTargetName(Prop.Entity.Target);
  try
    Result := List.Count > 0;
    if Result then
    begin
      Prop.FlyCorner := List[0];
      Prop.FlyTarget := QuakeToCge(List[0].Origin);
      Prop.Flying := True;
    end;
  finally
    List.Free;
  end;
end;

procedure TQuakeWorld.ViperMissileUse(const Ent: TQuakeEntity);
var
  Target: TQuakeEntity;
  Start, Dir: TVector3;
begin
  { misc_viper_missile_use: one rocket ("dmg" 250, speed 500) at the entity
    its target names, then it is gone }
  if FCounters.ContainsKey(Ent) then
    Exit;
  FCounters.AddOrSetValue(Ent, 1);
  Target := PickTarget(Ent.Target);
  if Target = nil then
  begin
    WritelnLog('QuakeWorld', 'misc_viper_missile: no target "%s"', [Ent.Target]);
    Exit;
  end;
  Start := QuakeToCge(Ent.Origin);
  Dir := QuakeToCge(Target.Origin) - Start;
  if Dir.IsZero then
    Exit;
  SpawnProjectile(pkRocket, Start, Dir.Normalize, 500, Ent.GetInt('dmg', 250), False);
  { MZ2_CHICK_ROCKET_1's flash }
  Sounds.PlayAtPoint('sound/chick/chkatck2.wav', Start);
  Lighting.AddLight(Start, 200, Vector3(1, 0.5, 0.2), 0.1);
  WritelnLog('QuakeWorld', 'misc_viper_missile fired at "%s"', [Ent.Target]);
end;

procedure TQuakeWorld.NukeUse(const Ent: TQuakeEntity);
var
  M: TQuakeMonster;
  Prop: TQuakeProp;
  Count: Integer;
begin
  { use_nuke, once: 100000 damage to the player, and every monster entity
    (alive or dead, and the dead soldiers and gib heads) removed }
  if FCounters.ContainsKey(Ent) then
    Exit;
  FCounters.AddOrSetValue(Ent, 1);
  Count := 0;
  for M in FMonsters do
    if not (M.Dormant and M.Gibbed) then
    begin
      M.Gibbed := True;
      M.SetDormant(True);
      Inc(Count);
    end;
  for Prop in FProps do
    if (Prop.Kind in [pkDeadSoldier, pkGibHead]) and not Prop.Destroyed then
    begin
      Prop.Destroyed := True;
      Prop.Transform.Exists := False;
    end;
  WritelnLog('QuakeWorld', 'misc_nuke: %d monsters removed', [Count]);
  DamagePlayer(100000, QuakeToCge(Ent.Origin), True);
end;

procedure TQuakeWorld.DamageProp(const Prop: TQuakeProp; const Damage: Integer);
var
  Dmg: Integer;
begin
  if (Prop.Kind = pkRotatingLight) and not Prop.Destroyed then
  begin
    { rotating_light_killed: welding sparks, the light goes out, gone }
    Prop.Health := Prop.Health - Damage;
    if Prop.Health > 0 then
      Exit;
    TempEntity(TE_WELDING_SPARKS, Prop.Transform.Translation);
    Prop.Destroyed := True;
    Prop.LightOn := False;
    Prop.AlarmActive := False;
    Prop.Transform.Exists := False;
    WritelnLog('QuakeWorld', 'rotating_light destroyed');
    Exit;
  end;
  if (Prop.Kind <> pkExplobox) or Prop.Destroyed then
    Exit;
  Prop.Health := Prop.Health - Damage;
  if Prop.Health > 0 then
    Exit;
  { Barrel explosion: Quake 2 barrel_explode, radius damage dmg (default 150) }
  Prop.Destroyed := True;
  Prop.Transform.Exists := False;
  Particles.SpawnDebris(Prop.Transform.Translation + Vector3(0, 16, 0));
  Dmg := Prop.Entity.GetInt('dmg', 150);
  Explode(Prop.Transform.Translation + Vector3(0, 16, 0), Dmg, Dmg + 40, False);
  UseTargets(Prop.Entity.Target, Prop.Entity);
end;

function TQuakeWorld.RepairHealth(const Ent: TQuakeEntity): Integer;
begin
  if not FRepairHealth.TryGetValue(Ent, Result) then
    Result := 100;
end;

procedure TQuakeWorld.RepairThink(const Ent: TQuakeEntity);
var
  Health: Integer;
  Delay: Single;
begin
  Health := RepairHealth(Ent);
  Delay := Max(0.1, Ent.GetFloat('delay', 1));
  FPeriodic[Ent] := FTime + Delay;
  if not FCounters.ContainsKey(Ent) then
  begin
    { object_repair_sparks: sparks every "delay" until welded below 0;
      then (object_repair_dead) its targets fire once }
    if Health < 0 then
    begin
      FCounters.AddOrSetValue(Ent, 1);
      FPeriodic[Ent] := FTime + 0.1;
      WritelnLog('QuakeWorld', 'func_object_repair repaired: fires "%s"', [Ent.Target]);
      UseTargets(Ent.Target, Ent);
    end else
      TempEntity(TE_WELDING_SPARKS, QuakeToCge(Ent.Origin));
  end else
  if Health <= 100 then
    { object_repair_fx: a point of health every "delay", no sparks }
    FRepairHealth.AddOrSetValue(Ent, Health + 1)
  else
    TempEntity(TE_WELDING_SPARKS, QuakeToCge(Ent.Origin));
end;
