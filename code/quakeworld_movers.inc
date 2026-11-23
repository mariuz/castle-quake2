{ Movers: brush entities, their traces and pushing, turrets.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.BreakExplosive(const Mover: TQuakeMover);
var
  Dmg: Integer;
begin
  { Quake 2 func_explosive_explode: debris always, an explosion (and
    radius damage) only with "dmg"; glass (our "_glass" key, the level
    compiler's windows) shatters }
  Dmg := Mover.Entity.GetInt('dmg', 0);
  if Dmg > 0 then
    Explode(Mover.Center, Dmg, 120, False);
  Particles.SpawnDebris(Mover.Center);
  if Mover.Entity.GetField('_glass') = '1' then
    Sounds.PlayAtPoint('sound/world/brkglas.wav', Mover.Center);
  Mover.Transform.Exists := False;
  WritelnLog('QuakeWorld', 'func_explosive %s breaks', [Mover.Entity.Model]);
end;

procedure TQuakeWorld.DamageMover(const Mover: TQuakeMover; const Damage: Integer);
begin
  if (Mover.Health <= 0) or not Mover.Transform.Exists then
    Exit;
  Mover.Health := Mover.Health - Damage;
  if Mover.Health > 0 then
    Exit;
  if Mover.Entity.ClassName = 'func_explosive' then
  begin
    BreakExplosive(Mover);
    UseTargets(Mover.Target, Mover.Entity);
  end else
  begin
    { Shot-activated doors and buttons reset their health, like Quake 2 }
    Mover.Health := Mover.Entity.GetInt('health', 0);
    Mover.Use;
    if Mover.Kind <> mkButton then
      UseTargets(Mover.Target, Mover.Entity);
  end;
end;

function TQuakeWorld.EntityMoveDir(const Ent: TQuakeEntity): TVector3;
var
  A: TVector3;
  Pitch, Yaw: Single;
begin
  { G_SetMovedir: "angle" -1 = up, -2 = down, else angles (pitch yaw roll) }
  if Ent.HasField('angle') then
  begin
    if SameValue(Ent.Angle, -1) then
      Exit(Vector3(0, 1, 0));
    if SameValue(Ent.Angle, -2) then
      Exit(Vector3(0, -1, 0));
    Exit(YawToCgeDir(Ent.Angle));
  end;
  A := Ent.GetVector('angles', Vector3(0, 0, 0));
  Pitch := DegToRad(A.X);
  Yaw := DegToRad(A.Y);
  { Quake pitch is positive looking down }
  Result := Vector3(Cos(Yaw) * Cos(Pitch), -Sin(Pitch), -Sin(Yaw) * Cos(Pitch));
end;

procedure TQuakeWorld.CheckMovers;
const
  DOOR_NOMONSTER = 8;
var
  Mover: TQuakeMover;
  Box, PBox: TBox3D;
  M: TQuakeMonster;

  { touch_DoorTrigger: monsters open doors too (not DOOR_NOMONSTER ones) }
  function MonsterInField(const Field: TBox3D): Boolean;
  var
    M: TQuakeMonster;
  begin
    Result := False;
    if (Mover.Entity.SpawnFlags and DOOR_NOMONSTER) <> 0 then
      Exit;
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and (M.Transform <> nil) and M.Transform.Exists and
         Field.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
        Exit(True);
  end;

begin
  PBox := PlayerBox;
  { func_plat2's use: the activator is the player }
  FGeometry.PlayerOriginZ := FPlayerPos.Y - (PlayerEyeHeight - 24);
  for Mover in FGeometry.Movers do
  begin
    if not Mover.Transform.Exists then
      Continue;
    Box := Mover.WorldBox;
    if Box.IsEmpty then
      Continue;
    case Mover.Kind of
      mkDoor, mkDoorRotating:
        if Mover.AutoOpen then
        begin
          { Quake 2 door trigger field: the closed door's box expanded by 60
            horizontally, made once; it stays there while the door moves, so
            standing in it keeps an open door open (door_go_up at the top
            restarts the wait) }
          if Mover.TriggerField.IsEmpty and (Mover.State = msAtStart) then
          begin
            Box.Data[0] := Box.Data[0] - Vector3(60, 0, 60);
            Box.Data[1] := Box.Data[1] + Vector3(60, 0, 60);
            Mover.TriggerField := Box;
          end;
          if not Mover.TriggerField.IsEmpty then
          begin
            if (Mover.State = msAtStart) and
               (Mover.TriggerField.Collision(PBox) or MonsterInField(Mover.TriggerField)) then
              Mover.Use
            else
            if (Mover.State = msAtEnd) and
               (Mover.TriggerField.Collision(PBox) or MonsterInField(Mover.TriggerField)) then
              Mover.StateTimer := Mover.WaitTime;
          end;
        end;
      mkPlat2:
        { Touch_Plat_Center2: live players and monsters in its field }
        if Mover.Plat2Active then
        begin
          if (not FDead) and Mover.TriggerField.Collision(PBox) then
            Mover.Plat2Operate(FPlayerPos.Y - (PlayerEyeHeight - 24));
          for M in FMonsters do
            if M.IsAlive and (not M.Dormant) and M.Transform.Exists and
               Mover.TriggerField.Collision(QuakeBoxToCge(M.Origin + M.BoxMins, M.Origin + M.BoxMaxs)) then
              Mover.Plat2Operate(M.Origin.Z);
        end;
      mkPlat:
        if (FPlayerPos.X >= Box.Data[0].X) and (FPlayerPos.X <= Box.Data[1].X) and
           (FPlayerPos.Z >= Box.Data[0].Z) and (FPlayerPos.Z <= Box.Data[1].Z) and
           (Abs((FPlayerPos.Y - PlayerEyeHeight) - Box.Data[1].Y) < 24) then
          Mover.PlayerOnTop;
      mkButton:
        if (Mover.Health = 0) and (Mover.State = msAtStart) then
        begin
          Box.Data[0] := Box.Data[0] - Vector3(8, 8, 8);
          Box.Data[1] := Box.Data[1] + Vector3(8, 8, 8);
          if Box.Collision(PBox) then
            Mover.Use;
        end;
    end;
  end;
end;

function TQuakeWorld.MoverByTransform(const T: TCastleTransform): TQuakeMover;
var
  Mover: TQuakeMover;
begin
  if FGeometry <> nil then
    for Mover in FGeometry.Movers do
      if (T = Mover.Scene) or (T = Mover.Transform) then
        Exit(Mover);
  Result := nil;
end;

procedure TQuakeWorld.LinkTurret(const T: TQuakeTurret);
var
  List: TQuakeEntityList;
  Team: String;
  Mover: TQuakeMover;
begin
  { turret_breach_finish_init: the muzzle from the breach's target; the
    bases are the turret_bases of its team }
  T.Linked := True;
  if T.Breach.Target <> '' then
  begin
    List := FBsp.FindByTargetName(T.Breach.Target);
    try
      if List.Count > 0 then
        T.MoveOrigin := List[0].Origin - T.Breach.Entity.Origin;
    finally
      List.Free;
    end;
  end else
    WritelnLog('QuakeWorld', 'turret_breach at %s needs a target', [T.Breach.Entity.Origin.ToString]);
  Team := T.Breach.Entity.GetField('team', '');
  if Team <> '' then
    for Mover in FGeometry.Movers do
      if (Mover.EntityClass = 'turret_base') and (Mover.Entity.GetField('team', '') = Team) then
      begin
        SetLength(T.Bases, Length(T.Bases) + 1);
        T.Bases[High(T.Bases)] := Mover;
      end;
end;

procedure TQuakeWorld.TurretFire(const T: TQuakeTurret);
var
  Muzzle, F, R, U: TVector3;
  Damage: Integer;
  Proj: TQuakeProjectile;
begin
  { turret_breach_fire: a rocket along the breach's forward, 100..150
    damage (also the splash, radius 150), speed 550 + 50 * skill }
  Muzzle := TurretMuzzle(T.Breach.Entity.Origin, T.Breach.TurretPitch, T.Breach.TurretYaw, T.MoveOrigin);
  QuakeAngleVectors(T.Breach.TurretPitch, T.Breach.TurretYaw, F, R, U);
  { The breach's "count" sets the damage (the remaster) }
  Damage := T.Breach.Entity.GetInt('count', 0);
  if Damage <= 0 then
    Damage := 100 + Random(51);
  SpawnProjectile(pkRocket, QuakeToCge(Muzzle), QuakeToCge(F), 550 + 50 * GameSkill, Damage, False, T.Driver);
  Proj := FProjectiles.Last;
  Proj.SplashDamage := Damage;
  Proj.SplashRadius := 150;
  Sounds.PlayAtPoint('sound/weapons/rocklf1a.wav', QuakeToCge(Muzzle), 1, 1, T.Breach, chWeapon);
  Inc(T.Shots);
  WritelnLog('QuakeWorld', 'turret_breach fires (pitch %.1f yaw %.1f, %d damage)',
    [T.Breach.TurretPitch, T.Breach.TurretYaw, Damage]);
end;

function TQuakeWorld.BrainEnemyPos(const T: TQuakeTurret; out Pos: TVector3): Boolean;
var
  M: TQuakeMonster;
begin
  { The middle of the enemy's box: a monster with that entity (gone once it
    died), else the entity's own origin }
  Result := False;
  if T.BrainEnemy = nil then
    Exit;
  for M in FMonsters do
    if M.Entity = T.BrainEnemy then
    begin
      if (not M.IsAlive) or M.Dormant then
        Exit;
      Pos := M.Origin + (M.BoxMins + M.BoxMaxs) * 0.5;
      Exit(True);
    end;
  Pos := T.BrainEnemy.Origin;
  Result := True;
end;

function TQuakeWorld.UpdateTurretBrain(const T: TQuakeTurret): Boolean;
var
  EnemyPos, BreachOrg: TVector3;
  Tr: TQuakeTrace;
  Reaction: Single;
begin
  { turret_brain_think: no searching; it stops when its enemy is gone }
  Result := False;
  BreachOrg := T.Breach.Entity.Origin;
  if not BrainEnemyPos(T, EnemyPos) then
  begin
    T.BrainOn := False;
    T.BrainStopped := True;
    WritelnLog('QuakeWorld', 'turret_invisible_brain: its enemy is gone');
    Exit;
  end;
  { Sight: a MASK_SHOT line from the breach (IGNORE_SIGHT 1 skips it) }
  if (T.Brain.SpawnFlags and 1) = 0 then
  begin
    Tr := WorldTrace(BreachOrg, EnemyPos, TVector3.Zero, TVector3.Zero, MASK_SHOT, T.Breach);
    if (Tr.Fraction < 1) and ((Tr.Ent = nil) or (Tr.Ent is TQuakeMover)) then
    begin
      T.LostSight := True;
      Exit;
    end;
  end;
  if T.LostSight or not T.HadEnemy then
  begin
    { Reaction time counted from when it (re)gained sight }
    T.TrailTime := FTime;
    T.LostSight := False;
    T.HadEnemy := True;
  end;
  QuakeVecToAngles(EnemyPos - BreachOrg, T.MovePitch, T.MoveYaw);
  { "delay" between shots, else 3 - skill seconds }
  Reaction := T.Brain.GetFloat('delay', 0);
  if Reaction <= 0 then
    Reaction := 3 - GameSkill;
  if (FTime >= T.AttackFinished) and (FTime - T.TrailTime >= Reaction) then
  begin
    T.AttackFinished := FTime + Reaction + 1;
    Result := True;
  end;
end;

procedure TQuakeWorld.UpdateTurrets(const SecondsPassed: Single);
var
  T: TQuakeTurret;
  M: TQuakeMonster;
  I: Integer;
  BreachOrg: TVector3;
  DP, DY, Reaction: Single;
  Fire: Boolean;
begin
  if FTurrets.Count = 0 then
    Exit;
  { turret_driver_link: a driver takes the breach its target names }
  for M in FMonsters do
    if M.TurretDriver and (not M.TurretLinked) and M.IsAlive and not M.Dormant then
      for T in FTurrets do
        if (T.Driver = nil) and (T.Breach.TargetName <> '') and SameText(T.Breach.TargetName, M.Entity.Target) then
        begin
          M.TurretLinked := True;
          T.Driver := M;
          T.DriverOffset := TurretDriverOffset(M.Origin, T.Breach.Entity.Origin);
          WritelnLog('QuakeWorld', '%s drives turret_breach "%s"', [M.Transform.Name, T.Breach.TargetName]);
          Break;
        end;

  { turret_brain_link: a brain takes the breach its target names, and the
    entity its killtarget names as its enemy }
  for I := FBrainEnts.Count - 1 downto 0 do
    for T in FTurrets do
      if (T.Brain = nil) and (T.Breach.TargetName <> '') and SameText(T.Breach.TargetName, FBrainEnts[I].Target) then
      begin
        T.Brain := FBrainEnts[I];
        T.BrainEnemy := PickTarget(T.Brain.GetField('killtarget'));
        T.BrainOn := T.Brain.TargetName = '';
        WritelnLog('QuakeWorld', 'turret_invisible_brain drives turret_breach "%s" against "%s" (on: %s)',
          [T.Breach.TargetName, T.Brain.GetField('killtarget'), BoolToStr(T.BrainOn, True)]);
        FBrainEnts.Delete(I);
        Break;
      end;

  for T in FTurrets do
  begin
    if not T.Linked then
      LinkTurret(T);
    BreachOrg := T.Breach.Entity.Origin;
    Fire := False;

    if (T.Brain <> nil) and T.BrainOn then
      Fire := UpdateTurretBrain(T);

    { turret_driver_die: the gun levels, the turret has no owner any more }
    if (T.Driver <> nil) and not T.Driver.IsAlive then
    begin
      WritelnLog('QuakeWorld', 'turret_driver died: the turret levels');
      T.Driver := nil;
      T.MovePitch := 0;
    end;

    { turret_driver_think: aim at the visible enemy, fire after the
      reaction time (3 - skill seconds) from when it was (re)acquired }
    M := T.Driver;
    if (M <> nil) and M.Alerted and (not FDead) and (not NoTarget) then
    begin
      if not T.HadEnemy then
      begin
        T.HadEnemy := True;
        T.TrailTime := FTime;
        T.LostSight := False;
      end;
      if M.CanSeePlayer then
      begin
        if T.LostSight then
        begin
          T.TrailTime := FTime;
          T.LostSight := False;
        end;
        QuakeVecToAngles(CgeToQuake(FPlayerPos) - BreachOrg, T.MovePitch, T.MoveYaw);
        Reaction := 3 - GameSkill;
        if (FTime >= T.AttackFinished) and (FTime - T.TrailTime >= Reaction) then
        begin
          T.AttackFinished := FTime + Reaction + 1;
          Fire := True;
        end;
      end else
        T.LostSight := True;
    end;

    { turret_breach_think: turn towards the (clamped) wished angles }
    TurretClampAngles(T.MovePitch, T.MoveYaw, T.Limits);
    TurretStep(T.Breach.TurretPitch, T.Breach.TurretYaw, T.MovePitch, T.MoveYaw,
      T.Speed * SecondsPassed, DP, DY);
    T.Breach.TurretPitch := T.Breach.TurretPitch + DP;
    T.Breach.TurretYaw := T.Breach.TurretYaw + DY;
    T.Breach.ApplyPose;
    for I := 0 to High(T.Bases) do
    begin
      T.Bases[I].TurretYaw := T.Bases[I].TurretYaw + DY;
      T.Bases[I].ApplyPose;
    end;

    { The driver sits behind the breach, turned and tilted with it }
    if T.Driver <> nil then
    begin
      M := T.Driver;
      M.FacingAngle := T.Breach.TurretYaw;
      M.Transform.Translation := QuakeToCge(TurretDriverOrigin(BreachOrg, T.Breach.TurretPitch,
        T.Breach.TurretYaw, T.DriverOffset, M.Origin.Z));
      M.Transform.Rotation := TurretRotation(T.Breach.TurretPitch, T.Breach.TurretYaw);
      if Fire then
        TurretFire(T);
    end else
    if Fire then
      { turret_invisible_brain: no driver to move }
      TurretFire(T);
  end;
end;

function TQuakeWorld.MoverTrace(const Mover: TQuakeMover; const Start, Stop, Mins, Maxs: TVector3;
  const Mask: Integer): TQuakeTrace;
begin
  Result := MoverTraceAt(Mover, Mover.Transform.Transform, Start, Stop, Mins, Maxs, Mask);
end;

function TQuakeWorld.MoverTraceAt(const Mover: TQuakeMover; const M: TMatrix4;
  const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
var
  Inv: TMatrix4;
  LStart, LStop, Org: TVector3;
begin
  { Into the brush model's own coordinates (CM_TransformedBoxTrace): the
    scene is placed relative to the entity origin (BaseOffset) by its
    transform; a rotated model keeps the box axis-aligned, like Quake 2.
    Console-spawned boxes (ModelIndex 0) have no brushes: doors are traced
    as their mins / maxs box at the entity origin (so they block and can be
    shot); turrets are never hit (their muzzle is inside the breach box). }
  if not M.TryInverse(Inv) then
    Exit(BoxTraceAgainstBox(Stop, Stop, TVector3.Zero, TVector3.Zero, Vector3(1, 1, 1), Vector3(0, 0, 0), 0));
  LStart := CgeToQuake(Inv.MultPoint(QuakeToCge(Start)) + Mover.BaseOffset);
  LStop := CgeToQuake(Inv.MultPoint(QuakeToCge(Stop)) + Mover.BaseOffset);
  if Mover.ModelIndex <= 0 then
  begin
    if (not (Mover.Kind in [mkDoor, mkSecretDoor])) or ((Mask and CONTENTS_SOLID) = 0) or
       not (Mover.Entity.HasField('mins') and Mover.Entity.HasField('maxs')) then
      Exit(BoxTraceAgainstBox(Stop, Stop, TVector3.Zero, TVector3.Zero, Vector3(1, 1, 1), Vector3(0, 0, 0), 0));
    Org := Mover.Entity.Origin;
    Result := BoxTraceAgainstBox(LStart, LStop, Mins, Maxs,
      Org + Mover.Entity.GetVector('mins', TVector3.Zero),
      Org + Mover.Entity.GetVector('maxs', TVector3.Zero), CONTENTS_SOLID);
  end else
    Result := FCollision.BoxTrace(LStart, LStop, Mins, Maxs, FBsp.Models[Mover.ModelIndex].HeadNode, Mask);
  if Result.Hit then
  begin
    Result.Normal := CgeToQuake(M.MultDirection(QuakeToCge(Result.Normal))).Normalize;
    Result.EndPos := Start + (Stop - Start) * Result.Fraction;
    Result.Ent := Mover;
  end else
    Result.EndPos := Stop;
end;

procedure TQuakeWorld.PushPlayerByMovers;
const
  { Quake 2 item boxes, and what blocks items (MASK_SOLID) }
  ItemMins: TVector3 = (X: -15; Y: -15; Z: -15);
  ItemMaxs: TVector3 = (X: 15; Y: 15; Z: 15);
  MASK_SOLID = CONTENTS_SOLID or CONTENTS_WINDOW;
var
  Mover: TQuakeMover;
  M, Old, OldInv: TMatrix4;
  Org, Mins, Maxs, Delta: TVector3;
  Blocked: Boolean;
  Damage: Integer;
  Monster: TQuakeMonster;
  Pickup: TQuakePickup;

  { Quake 2 SV_Push for one entity: it moves with the mover when it rides
    it (stood on its old pose) or the mover moved into it; it keeps the
    pushed position if free, else the old one if that is free; else the
    mover is blocked. True with Delta (CGE) when it should move. }
  function PushOne(const AOrg, AMins, AMaxs: TVector3; const Mask: Integer; const Ent: TObject;
    const Riding: Boolean; out ADelta: TVector3; out ABlocked: Boolean): Boolean;
  var
    T: TQuakeTrace;
    Ride, Inside: Boolean;
    NewQ: TVector3;
  begin
    Result := False;
    ABlocked := False;
    ADelta := TVector3.Zero;
    Ride := Riding;
    if not Ride then
    begin
      T := MoverTraceAt(Mover, Old, AOrg, AOrg - Vector3(0, 0, 1), AMins, AMaxs, Mask);
      Ride := (T.Fraction < 1) and not T.StartSolid;
    end;
    Inside := (not Ride) and MoverTrace(Mover, AOrg, AOrg, AMins, AMaxs, Mask).StartSolid and
      not MoverTraceAt(Mover, Old, AOrg, AOrg, AMins, AMaxs, Mask).StartSolid;
    if not (Ride or Inside) then
      Exit;
    { Like a point fixed to the mover }
    NewQ := CgeToQuake(M.MultPoint(OldInv.MultPoint(QuakeToCge(AOrg))));
    { A push longer than 64 units in one frame is the box approximation of
      a rotated model catching something far away: ignore it. A spinning
      brush moves a point near it a few units a frame, so from one a push
      over 16 is such a catch too (a fan in demo1 threw the player 60
      units). }
    if (PointsDistance(NewQ, AOrg) > 64) or
       ((Mover.Kind = mkRotating) and (PointsDistance(NewQ, AOrg) > 16)) then
      Exit;
    if not WorldTrace(NewQ, NewQ, AMins, AMaxs, Mask, Ent).StartSolid then
    begin
      ADelta := QuakeToCge(NewQ) - QuakeToCge(AOrg);
      Result := True;
    end else
      ABlocked := WorldTrace(AOrg, AOrg, AMins, AMaxs, Mask, Ent).StartSolid;
  end;

begin
  if FGeometry = nil then
    Exit;
  for Mover in FGeometry.Movers do
  begin
    if Mover.ModelIndex <= 0 then
      Continue; { console-spawned boxes have no brushes }
    M := Mover.Transform.Transform;
    if FMoverPoses.TryGetValue(Mover, Old) and not TMatrix4.PerfectlyEquals(M, Old) and
       Mover.Transform.Exists and Old.TryInverse(OldInv) then
    begin
      { The player }
      if (FPlayer <> nil) and Assigned(FPlayer.OnTrace) and (not FDead) then
      begin
        Org := FPlayer.Origin;
        Mins := FPlayer.BoxMins;
        Maxs := FPlayer.BoxMaxs;
        if PushOne(Org, Mins, Maxs, MASK_PLAYERSOLID, FPlayer, FPlayer.GroundObject = Mover, Delta, Blocked) then
          FPlayer.Push(Delta)
        else
        if Blocked then
        begin
          Damage := Mover.Blocked;
          if Damage > 0 then
            DamagePlayer(Damage, Mover.Center);
        end;
      end;
      { Continuously spinning brushes only push the player }
      if Mover.Kind in [mkRotating, mkTurret] then
      begin
        FMoverPoses.AddOrSetValue(Mover, M);
        Continue;
      end;
      { Monsters and corpses (a corpse caught in a door is gibbed) }
      for Monster in FMonsters do
      begin
        { Flyers too (SV_Push moves every MOVETYPE_STEP entity): a closing
          door used to swallow floaters }
        if Monster.Dormant or Monster.Gibbed or (Monster.Transform = nil) or (not Monster.Transform.Exists) then
          Continue;
        Org := Monster.Origin;
        Maxs := Monster.BoxMaxs;
        if not Monster.IsAlive then
          Maxs.Z := Monster.BoxMins.Z + 16;
        if PushOne(Org, Monster.BoxMins, Maxs, MASK_MONSTERSOLID, Monster, False, Delta, Blocked) then
        begin
          Monster.Transform.Translation := Monster.Transform.Translation + Delta;
        end
        else
        if Blocked then
        begin
          Damage := Mover.Blocked;
          if not Monster.IsAlive then
            Monster.TakeDamage(1000)
          else
          if Damage > 0 then
            Monster.TakeDamage(Damage);
        end;
      end;
      { Items }
      for Pickup in FPickups do
      begin
        if Pickup.Collected or (Pickup.Transform = nil) or (not Pickup.Transform.Exists) then
          Continue;
        Org := CgeToQuake(Pickup.Origin);
        { Items never block movers: their spawn origins may touch the floor }
        if PushOne(Org, ItemMins, ItemMaxs, MASK_SOLID, Pickup, False, Delta, Blocked) then
        begin
          Pickup.Origin := Pickup.Origin + Delta;
          Pickup.Transform.Translation := Pickup.Transform.Translation + Delta;
        end;
      end;
    end;
    FMoverPoses.AddOrSetValue(Mover, M);
  end;
end;
