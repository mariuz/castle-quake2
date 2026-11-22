{ Monsters' world glue: perception, attacks, medics, bosses.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.UpdateMedics(const SecondsPassed: Single);
var
  Medic, M, Best: TQuakeMonster;
begin
  FMedicTimer := FMedicTimer - SecondsPassed;
  if FMedicTimer > 0 then
    Exit;
  FMedicTimer := 1;
  for Medic in FMonsters do
  begin
    if (not Medic.IsMedic) or (not Medic.IsAlive) or Medic.Dormant or (Medic.HealTarget <> nil) or
       (Medic.WeldTarget <> nil) then
      Continue;
    { medic_FindDeadMonster: a visible, finished corpse within 1024 units,
      not claimed by another medic, the one with the most max health }
    Best := nil;
    for M in FMonsters do
      if (M <> Medic) and (not M.IsAlive) and (M.State = msDead) and (not M.Gibbed) and (not M.GoodGuy) and
         (not M.Dormant) and M.Transform.Exists and (M.Healer = nil) and
         (PointsDistance(M.Transform.Translation, Medic.Transform.Translation) <= 1024) and
         Medic.HasLineOfSight(M.Transform.Translation + Vector3(0, 8, 0)) and
         ((Best = nil) or (M.Def^.Health > Best.Def^.Health)) then
        Best := M;
    if Best <> nil then
    begin
      Medic.HealTarget := Best;
      Medic.HealTime := 0;
      Best.Healer := Medic;
      WritelnLog('QuakeWorld', '%s goes to revive %s', [Medic.Transform.Name, Best.Transform.Name]);
    end else
    if Medic.IsFixbot and (Medic.WeldTarget = nil) and (Medic.WeldCooldown = 0) and not Medic.Alerted then
      FindWeldTarget(Medic);
  end;
end;

procedure TQuakeWorld.FindWeldTarget(const Fixbot: TQuakeMonster);
var
  Pair: specialize TPair<TQuakeEntity, Single>;
  Pos: TVector3;
begin
  { use_scanner: the first func_object_repair within 1024 units, in sight,
    with health 100 or more }
  for Pair in FPeriodic do
    if Pair.Key.ClassName = 'func_object_repair' then
    begin
      Pos := QuakeToCge(Pair.Key.Origin);
      if (RepairHealth(Pair.Key) >= 100) and
         (PointsDistance(Pos, Fixbot.Transform.Translation) <= 1024) and Fixbot.HasLineOfSight(Pos) then
      begin
        Fixbot.WeldTarget := Pair.Key;
        WritelnLog('QuakeWorld', '%s goes to weld at %s', [Fixbot.Transform.Name, Pair.Key.Origin.ToString]);
        Exit;
      end;
    end;
end;

procedure TQuakeWorld.MonsterRevived(const Monster: TQuakeMonster);
begin
  { monster_start counts the monster again }
  Inc(FStats.TotalKills);
end;

procedure TQuakeWorld.BossSummon(const Boss: TQuakeMonster);
var
  Cls: String;
  Offsets: array of TVector3;
  I: Integer;
  YawRad: Single;
  Fwd, Right, Pos, Mins, Maxs: TVector3;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
  Before, M: TQuakeMonster;
  Made: Integer;
begin
  if Boss.MonsterSlots <= 0 then
    Exit;
  if Boss.Def^.ClassName = 'monster_carrier' then
  begin
    { CarrierSpawn: flyers 105 ahead and 58 below, one each half second
      (three a spawn move; the middle one a kamikaze in Ground Zero) }
    Cls := 'monster_flyer';
    Offsets := [Vector3(105, 0, -58), Vector3(105, 48, -58), Vector3(105, -48, -58)];
  end else
  begin
    { WidowSpawn / Widow2Spawn: two stalkers beside her }
    Cls := 'monster_stalker';
    if Boss.Def^.ClassName = 'monster_widow2' then
      Offsets := [Vector3(30, 135, 0), Vector3(30, -135, 0)]
    else
      Offsets := [Vector3(30, 100, 16), Vector3(30, -100, 16)];
  end;
  MonsterBoxSize(Cls, Mins, Maxs);
  YawRad := DegToRad(Boss.Facing);
  Fwd := Vector3(Cos(YawRad), Sin(YawRad), 0);
  Right := Vector3(Sin(YawRad), -Cos(YawRad), 0);
  Made := 0;
  for I := 0 to High(Offsets) do
  begin
    if Boss.MonsterSlots <= 0 then
      Break;
    Pos := Boss.Origin + Fwd * Offsets[I].X - Right * Offsets[I].Y + Vector3(0, 0, Offsets[I].Z);
    T := WorldTrace(Pos, Pos, Mins, Maxs, MASK_MONSTERSOLID, Boss);
    if T.StartSolid then
      Continue;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Cls);
    Ent.SetField('origin', Format('%d %d %d', [Round(Pos.X), Round(Pos.Y), Round(Pos.Z)]));
    Ent.SetField('angle', IntToStr(Round(Boss.Facing)));
    FBsp.Entities.Add(Ent);
    Before := nil;
    if FMonsters.Count > 0 then
      Before := FMonsters.Last;
    SpawnEntity(Ent);
    if (FMonsters.Count = 0) or (FMonsters.Last = Before) then
      Continue;
    M := FMonsters.Last;
    { AI_SPAWNED_*, AI_DO_NOT_COUNT; they go after the boss's enemy }
    M.DoNotCount := True;
    Dec(FStats.TotalKills);
    M.Alert;
    Particles.SpawnTeleport(M.Transform.Translation);
    Dec(Boss.MonsterSlots);
    Inc(Made);
  end;
  if Made > 0 then
    Sounds.PlayAt('sound/medic_commander/monsterspawn1.wav', Boss.Transform, 1, ATTN_NONE, chBody);
  WritelnLog('QuakeWorld', '%s spawns %d %s (%d slots left)', [Boss.Transform.Name, Made, Cls, Boss.MonsterSlots]);
end;

procedure TQuakeWorld.HeatBeam(const Monster: TQuakeMonster; const Eye, Target: TVector3);
var
  T: TQuakeTrace;
  Dir: TVector3;
begin
  { monster_fire_heat: a trace to the target and on, 10 to what it hits }
  Dir := (Target - Eye).Normalize;
  T := WorldTrace(CgeToQuake(Eye), CgeToQuake(Eye + Dir * 8192), TVector3.Zero, TVector3.Zero, MASK_SHOT, Monster);
  if T.Ent is TQuakePlayerMovement then
  begin
    { Drawn to just short of the player: particles at the eye fill the view }
    if PointsDistance(Eye, QuakeToCge(T.EndPos)) > 64 then
      Particles.SpawnBeam(Eye, QuakeToCge(T.EndPos) - Dir * 48, Vector3(1.0, 0.6, 0.2));
    DamagePlayer(Monster.AttackDamage, Eye);
  end else
  begin
    Particles.SpawnBeam(Eye, QuakeToCge(T.EndPos), Vector3(1.0, 0.6, 0.2));
  end;
  if not (T.Ent is TQuakePlayerMovement) then
  if T.Hit and ((T.Contents and CONTENTS_SOLID) <> 0) then
    Particles.SpawnSteam(QuakeToCge(T.EndPos) - Dir * 2, -Dir, 8, 60, 223);
end;

procedure TQuakeWorld.UpdateWidows;
var
  M, S: TQuakeMonster;
  Ent: TQuakeEntity;
  Org: TVector3;
begin
  for M in FMonsters do
    if (M.Def^.ClassName = 'monster_widow') and (M.State = msDead) and (not M.Gibbed) and M.Transform.Exists then
    begin
      { spawn_out_do: splashes, TE_BOSSTPORT, the legs left behind, gone }
      Org := M.Origin;
      TempEntity(TE_EXPLOSION1, M.Transform.Translation + Vector3(0, 36, 0));
      Particles.SpawnTeleport(M.Transform.Translation);
      Sounds.PlayAtPoint('sound/misc/bigtele.wav', M.Transform.Translation);
      Ent := TQuakeEntity.Create;
      Ent.SetField('classname', 'widow_legs');
      Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z - 24)]));
      Ent.SetField('angle', IntToStr(Round(M.Facing)));
      FBsp.Entities.Add(Ent);
      FProps.Add(TQuakeProp.CreateProp(FMap, pkWidowLegs, Ent));
      M.Gibbed := True;
      M.Transform.Exists := False;
      WritelnLog('QuakeWorld', '%s beams out', [M.Transform.Name]);
    end else
    if (M.Def^.ClassName = 'monster_widow2') and (not M.IsAlive) and (not M.Gibbed) and
       (M.Health > M.GibHealth) and not FCounters.ContainsKey(M.Entity) then
    begin
      { widow2_die: KillChildren, every stalker on the map dies }
      FCounters.AddOrSetValue(M.Entity, 1);
      for S in FMonsters do
        if S.IsAlive and (S.Def^.ClassName = 'monster_stalker') then
          S.TakeDamage(S.Health + 1);
      WritelnLog('QuakeWorld', '%s dies: her stalkers with her', [M.Transform.Name]);
    end;
end;

procedure TQuakeWorld.MedicSummon(const Medic: TQuakeMonster);
const
  Reinforcements: array[0..6] of String = ('monster_soldier_light', 'monster_soldier',
    'monster_soldier_ss', 'monster_infantry', 'monster_gunner', 'monster_medic', 'monster_gladiator');
  Offsets: array[0..4] of record X, Y: Single; end = (
    (X: 80; Y: 0), (X: 40; Y: 60), (X: 40; Y: -60), (X: 0; Y: 80), (X: 0; Y: -80));
  SlotOffsets: array[0..4] of Integer = (0, 2, 2, 4, 4);
var
  Strength, Count, I, Side, SideIdx, Cls, Made: Integer;
  R, YawRad: Single;
  Fwd, Right, Pos, Mins, Maxs: TVector3;
  Spots: array of TVector3;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
  Before, M: TQuakeMonster;
begin
  if Medic.MonsterSlots <= 0 then
    Exit;
  { The strength: the skill plus luck (-3 .. +3), at least 0; the number:
    1, 1, 1, 3, 3, 5, 5 for strength 0 .. 6 }
  Strength := GameSkill;
  R := Random;
  if R < 0.05 then Dec(Strength, 3)
  else if R < 0.15 then Dec(Strength, 2)
  else if R < 0.3 then Dec(Strength)
  else if R > 0.95 then Inc(Strength, 3)
  else if R > 0.85 then Inc(Strength, 2)
  else if R > 0.7 then Inc(Strength);
  Strength := Max(0, Strength);
  if Strength = 0 then
    Count := 1
  else
    Count := (Strength - 1) + (Strength mod 2);
  Count := Min(Min(Count, 5), Medic.MonsterSlots);
  { The spots in front (80 ahead, 40 ahead and 60 to the sides, 80 to the
    sides), else the same behind: free for the box, a floor within 256 }
  YawRad := DegToRad(Medic.Facing);
  Fwd := Vector3(Cos(YawRad), Sin(YawRad), 0);
  Right := Vector3(Sin(YawRad), -Cos(YawRad), 0);
  Spots := nil;
  for SideIdx := 0 to 1 do
  begin
    Side := 1 - 2 * SideIdx;
    for I := 0 to Count - 1 do
    begin
      Cls := EnsureRange(Strength - SlotOffsets[I], 0, 6);
      MonsterBoxSize(Reinforcements[Cls], Mins, Maxs);
      Pos := Medic.Origin + Fwd * (Offsets[I].X * Side) - Right * (Offsets[I].Y * Side) + Vector3(0, 0, 10);
      T := WorldTrace(Pos, Pos, Mins, Maxs, MASK_MONSTERSOLID, Medic);
      if T.StartSolid then
        Continue;
      T := WorldTrace(Pos, Pos - Vector3(0, 0, 256), Mins, Maxs, MASK_MONSTERSOLID, Medic);
      if T.Fraction >= 1 then
        Continue;
      SetLength(Spots, Length(Spots) + 1);
      Spots[High(Spots)] := Vector3(T.EndPos.X, T.EndPos.Y, I);
    end;
    if Length(Spots) > 0 then
      Break;
  end;
  Made := 0;
  for I := 0 to High(Spots) do
  begin
    Cls := EnsureRange(Strength - SlotOffsets[Round(Spots[I].Z)], 0, 6);
    MonsterBoxSize(Reinforcements[Cls], Mins, Maxs);
    Pos := Medic.Origin + Fwd * 0;
    T := WorldTrace(Vector3(Spots[I].X, Spots[I].Y, Medic.Origin.Z + 10),
      Vector3(Spots[I].X, Spots[I].Y, Medic.Origin.Z + 10 - 256), Mins, Maxs, MASK_MONSTERSOLID, Medic);
    Pos := T.EndPos;
    Ent := TQuakeEntity.Create;
    Ent.SetField('classname', Reinforcements[Cls]);
    Ent.SetField('origin', Format('%d %d %d', [Round(Pos.X), Round(Pos.Y), Round(Pos.Z)]));
    Ent.SetField('angle', IntToStr(Round(Medic.Facing)));
    FBsp.Entities.Add(Ent);
    Before := nil;
    if FMonsters.Count > 0 then
      Before := FMonsters.Last;
    SpawnEntity(Ent);
    if (FMonsters.Count = 0) or (FMonsters.Last = Before) then
      Continue;
    M := FMonsters.Last;
    { AI_DO_NOT_COUNT: not in the level's totals }
    M.DoNotCount := True;
    Dec(FStats.TotalKills);
    M.Alert;
    Particles.SpawnTeleport(M.Transform.Translation);
    Dec(Medic.MonsterSlots);
    Inc(Made);
  end;
  WritelnLog('QuakeWorld', '%s calls %d reinforcements (strength %d, %d slots left)',
    [Medic.Transform.Name, Made, Strength, Medic.MonsterSlots]);
end;

function TQuakeWorld.WeldCycle(const Target: TQuakeEntity): Boolean;
var
  Health: Integer;
begin
  { weldstate on weldmiddle_07: 10 off; done below 0 }
  Health := RepairHealth(Target) - 10;
  FRepairHealth.AddOrSetValue(Target, Health);
  Result := Health < 0;
end;

function TQuakeWorld.MonsterPointContents(const QuakePos: TVector3): Integer;
begin
  if FBsp = nil then
    Exit(0);
  Result := FBsp.PointContents(QuakePos);
end;

function TQuakeWorld.MonsterByTransform(const T: TCastleTransform): TQuakeMonster;
var
  M: TQuakeMonster;
begin
  for M in FMonsters do
    if M.OwnsTransform(T) then
      Exit(M);
  Result := nil;
end;

function TQuakeWorld.DelayedCount: Integer;
begin
  Result := FDelayed.Count;
end;

procedure TQuakeWorld.MonsterFoundTarget(const Monster: TQuakeMonster);
begin
  if FSightEntities.IndexOf(Monster) < 0 then
    FSightEntities.Add(Monster);
end;

procedure TQuakeWorld.UpdatePlayerTrail(const SecondsPassed: Single);
var
  Origin, ToSpot: TVector3;
begin
  PlayerTrail.Now := FTime;
  FTrailTimer := FTrailTimer - SecondsPassed;
  if (FTrailTimer > 0) or FDead then
    Exit;
  FTrailTimer := 0.1;
  { The player's origin: 22 below the eye }
  Origin := FPlayerPos - Vector3(0, 22, 0);
  if PlayerTrail.Count > 0 then
  begin
    ToSpot := PlayerTrail.LastSpot - Origin;
    if ToSpot.Length < 1 then
      Exit;
    if WorldTrace(CgeToQuake(Origin), CgeToQuake(PlayerTrail.LastSpot), TVector3.Zero, TVector3.Zero,
       MASK_OPAQUE, FPlayer).Fraction >= 1 then
      Exit; { still sees the last spot }
  end;
  PlayerTrail.Add(Origin);
end;

procedure TQuakeWorld.ProcessSightEntities;
var
  Spotters: array of TQuakeMonster;
  S, M: TQuakeMonster;
  I: Integer;
begin
  if FSightEntities.Count = 0 then
    Exit;
  { Monsters woken here find the player too: they act as sight entities
    on the next frame, like Quake 2's one sight_entity per frame }
  SetLength(Spotters, FSightEntities.Count);
  for I := 0 to FSightEntities.Count - 1 do
    Spotters[I] := FSightEntities[I];
  FSightEntities.Clear;
  for S in Spotters do
    for M in FMonsters do
      if (M <> S) and not M.Alerted and not M.Ambush and not M.Dormant and M.IsAlive and
         M.WouldNotice(S.Transform.Translation - M.Transform.Translation) and
         M.HasLineOfSight(S.EyePos) then
        M.Alert;
end;

procedure TQuakeWorld.CheckDodge(const Origin, Dir: TVector3; const Speed: Single);
var
  T: TQuakeTrace;
  Dist: Single;
  M: TQuakeMonster;
begin
  if (Speed <= 0) or ((GameSkill = 0) and (Random > 0.25)) then
    Exit;
  T := WorldTrace(CgeToQuake(Origin), CgeToQuake(Origin + Dir * 8192), TVector3.Zero, TVector3.Zero,
    MASK_SHOT, FPlayer);
  if not (T.Ent is TQuakeMonster) then
    Exit;
  M := TQuakeMonster(T.Ent);
  Dist := PointsDistance(Origin, QuakeToCge(T.EndPos));
  if not M.IsAlive then
    Exit;
  { infront(monster, player) }
  if TVector3.DotProduct(YawToCgeDir(M.FacingAngle), (FPlayerPos - M.Transform.Translation).Normalize) <= 0.3 then
    Exit;
  M.Dodge(Max(0, Dist - 16) / Speed);
end;

procedure TQuakeWorld.PlayerNoise(const Pos: TVector3);
var
  M: TQuakeMonster;
begin
  if NoTarget or (FGeometry = nil) then
    Exit;
  for M in FMonsters do
    if (not M.Alerted) and (not M.Dormant) and M.IsAlive and
       (PointsDistance(M.Transform.Translation, Pos) <= 1000) and
       FGeometry.CanHear(Pos, M.Transform.Translation) and
       ((not M.Ambush) or M.HasLineOfSight(Pos)) then
      M.Alert;
end;

function TQuakeWorld.MonsterRail(const Monster: TQuakeMonster; const Eye, Target: TVector3): Boolean;
var
  Start, Stop: TVector3;
  Ignore: TObject;
  T: TQuakeTrace;
  I: Integer;
begin
  { fire_rail: on through monsters to the first wall }
  Result := False;
  Start := CgeToQuake(Eye);
  Stop := Start + (CgeToQuake(Target) - Start).Normalize * 8192;
  Ignore := Monster;
  Sounds.PlayAt('sound/weapons/railgf1a.wav', Monster.Transform, 1, 1, chWeapon);
  for I := 0 to 8 do
  begin
    T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    if not T.Hit then
      Break;
    if T.Ent is TQuakePlayerMovement then
    begin
      DamagePlayer(Monster.AttackDamage, Eye);
      Result := True;
    end else
    if T.Ent is TQuakeMonster then
      TQuakeMonster(T.Ent).TakeDamage(Monster.AttackDamage)
    else
      Break;
    Ignore := T.Ent;
    Start := T.EndPos;
  end;
  Particles.SpawnRailTrail(Eye, QuakeToCge(T.EndPos));
end;

procedure TQuakeWorld.UpdateBossExplosions;
const
  { BossExplode: where explosions 0..7 go around the body (x, y offsets) }
  Offsets: array[0..7, 0..1] of Integer = ((-24, -24), (24, 24), (24, -24), (-24, 24),
    (-48, -48), (48, 48), (-48, 48), (48, -48));
var
  M: TQuakeMonster;
  I, K: Integer;
  Org: TVector3;
  Pieces: array[0..3] of TGibPiece;
  Known: Boolean;
begin
  { The supertank, the hornet and Jorg: when their death animation ends,
    BossExplode (supertank_dead / boss2_die / jorg_dead) }
  for M in FMonsters do
    if (M.State = msDead) and (not M.Gibbed) and M.Transform.Exists and
       ((M.Def^.ClassName = 'monster_supertank') or (M.Def^.ClassName = 'monster_boss2') or
        (M.Def^.ClassName = 'monster_jorg') or (M.Def^.ClassName = 'monster_boss5') or
        { Ground Zero: carrier_dead, widow2's death explosions }
        (M.Def^.ClassName = 'monster_carrier') or (M.Def^.ClassName = 'monster_widow2')) then
    begin
      Known := False;
      for K := 0 to High(FBossExplosions) do
        if FBossExplosions[K].Monster = M then
          Known := True;
      if not Known then
      begin
        SetLength(FBossExplosions, Length(FBossExplosions) + 1);
        FBossExplosions[High(FBossExplosions)].Monster := M;
        FBossExplosions[High(FBossExplosions)].Count := 0;
        FBossExplosions[High(FBossExplosions)].Next := FTime;
        WritelnLog('QuakeWorld', '%s explodes (BossExplode)', [M.Transform.Name]);
      end;
    end;

  for I := High(FBossExplosions) downto 0 do
  begin
    M := FBossExplosions[I].Monster;
    if FMonsters.IndexOf(M) < 0 then
    begin
      Delete(FBossExplosions, I, 1);
      Continue;
    end;
    while (FBossExplosions[I].Count < 8) and (FTime >= FBossExplosions[I].Next) do
    begin
      { A TE_EXPLOSION1 24..39 above the origin, around it, every 0.1 s }
      Org := M.Origin + Vector3(Offsets[FBossExplosions[I].Count, 0], Offsets[FBossExplosions[I].Count, 1],
        24 + Random(16));
      TempEntity(TE_EXPLOSION1, QuakeToCge(Org));
      Inc(FBossExplosions[I].Count);
      FBossExplosions[I].Next := FBossExplosions[I].Next + 0.1;
    end;
    if (FBossExplosions[I].Count >= 8) and (FTime >= FBossExplosions[I].Next) then
    begin
      { Then 4 meat, 8 metal, the chest and a gear (the head); the body is gone }
      Pieces[0].Model := 'models/objects/gibs/sm_meat/tris.md2';
      Pieces[0].Count := 4;
      Pieces[0].Metallic := False;
      Pieces[1].Model := 'models/objects/gibs/sm_metal/tris.md2';
      Pieces[1].Count := 8;
      Pieces[1].Metallic := True;
      Pieces[2].Model := 'models/objects/gibs/chest/tris.md2';
      Pieces[2].Count := 1;
      Pieces[2].Metallic := False;
      Pieces[3].Model := 'models/objects/gibs/gear/tris.md2';
      Pieces[3].Count := 1;
      Pieces[3].Metallic := True;
      Particles.ThrowGibs(QuakeToCge(M.Origin + M.BoxMins), QuakeToCge(M.Origin + M.BoxMaxs), Pieces, 500);
      WritelnLog('QuakeWorld', '%s blew up: 8 explosions, 14 gibs', [M.Transform.Name]);
      M.Gibbed := True;
      M.Transform.Exists := False;
      Delete(FBossExplosions, I, 1);
    end;
  end;
end;

procedure TQuakeWorld.UpdateBossesAndLeaps;
var
  M: TQuakeMonster;
  I: Integer;
  Ent: TQuakeEntity;
  Org: TVector3;
  Makron: TQuakeMonster;
  ToPlayer: TVector3;
begin
  { mutant_jump_touch: 40 .. 49 when it hits the player faster than 400 }
  for M in FMonsters do
    if M.LeapDamage > 0 then
    begin
      if not M.Jumping then
        M.LeapDamage := 0
      else
      if (M.JumpSpeed > 400) and not FDead and
         (Abs(M.Transform.Translation.X - FPlayerPos.X) < 16 + M.BoxMaxs.X + 4) and
         (Abs(M.Transform.Translation.Z - FPlayerPos.Z) < 16 + M.BoxMaxs.Y + 4) and
         (Abs(M.Transform.Translation.Y - (FPlayerPos.Y - 22)) < 64) then
      begin
        DamagePlayer(M.LeapDamage, M.Transform.Translation);
        M.LeapDamage := 0;
      end;
    end;

  UpdateBossExplosions;
  UpdateWidows;

  { MakronSpawn: a monster_makron where Jorg died, jumping at the player
    (400 toward him, 200 up) }
  for I := High(FMakronTosses) downto 0 do
    if FTime >= FMakronTosses[I].Time then
    begin
      Org := CgeToQuake(FMakronTosses[I].Pos);
      Ent := TQuakeEntity.Create;
      Ent.SetField('classname', 'monster_makron');
      Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
      Ent.SetField('angle', IntToStr(Round(FMakronTosses[I].Yaw)));
      if FMakronTosses[I].Target <> '' then
        Ent.SetField('target', FMakronTosses[I].Target);
      Delete(FMakronTosses, I, 1);
      FBsp.Entities.Add(Ent);
      Makron := nil;
      if FMonsters.Count > 0 then
        Makron := FMonsters.Last;
      SpawnEntity(Ent);
      if (FMonsters.Count > 0) and (FMonsters.Last <> Makron) then
      begin
        Makron := FMonsters.Last;
        ToPlayer := FPlayerPos - Makron.Transform.Translation;
        ToPlayer.Y := 0;
        if not ToPlayer.IsZero then
          Makron.MonsterJump(ToPlayer.Normalize * 400, 200);
        Makron.Alert;
        WritelnLog('QuakeWorld', 'The Makron comes out: %s', [Makron.Transform.Name]);
      end;
    end;
end;

procedure TQuakeWorld.MonsterAttack(const Monster: TQuakeMonster);
var
  Eye, Target, Dir: TVector3;
  Dist, Accuracy: Single;
  I, Hits: Integer;
begin
  if FDead then
    Exit;
  Inc(FMonsterShots);
  FDamageSource := Monster;
  Eye := Monster.EyePos;
  Target := FPlayerPos - Vector3(0, 12, 0);
  { A turret's blind shot: at the spot the player was last seen }
  if Monster.BlindFire then
    Target := Monster.BlindAim;
  if Monster.AngerActive then
  begin
    { target_anger: shooting at a spot; hitscans make impacts there,
      projectiles fly to it, nothing reaches the player }
    Target := Monster.AngerPos;
    Dir := (Target - Eye).Normalize;
    if Monster.AttackKind in [akMelee, akLeap, akLaser] then
      Exit;
    if Monster.AttackKind in [akHitscan, akPellets, akRail] then
    begin
      Lighting.TriggerMuzzleFlash(Eye);
      if Monster.AttackKind = akRail then
        Particles.SpawnRailTrail(Eye, Target)
      else
        Particles.SpawnImpact(Target + Vector3((Random - 0.5) * 24, (Random - 0.5) * 24,
          (Random - 0.5) * 24), -Dir);
      Exit;
    end;
  end;
  Dir := (Target - Eye).Normalize;
  Dist := PointsDistance(Eye, Target);
  if not (Monster.AttackKind in [akMelee, akLeap]) then
    Lighting.TriggerMuzzleFlash(Eye);

  { Monster.AttackKind / AttackDamage / AttackBullets: the shot of its
    attack sequence (or of the generic attack) }
  { MakronHyperblaster sweeps across: the shot turned by AttackYaw }
  if Monster.AttackYaw <> 0 then
    Dir := RotatePointAroundAxisRad(DegToRad(Monster.AttackYaw), Dir, Vector3(0, 1, 0));
  { Shots aimed at a saved position (gladiator / Makron railgun) }
  if Monster.AimSaved and (Monster.AttackKind = akRail) then
  begin
    MonsterRail(Monster, Eye, Monster.SavedAim);
    Exit;
  end;

  case Monster.AttackKind of
    akMelee:
      if Dist < Monster.AttackReach then
      begin
        DamagePlayer(Monster.AttackDamage, Eye);
        { fire_hit's kick: push (or pull) the player }
        if (Monster.AttackKick <> 0) and (FPlayer <> nil) then
          FPlayer.AddVelocity(Dir * Monster.AttackKick);
      end;
    akLeap:
      Monster.Leap;
    akBfg:
      begin
        { monster_fire_bfg: speed 300, its own damage and radius for the
          BFG effect; the core hit stays bfg_touch's 200 }
        SpawnProjectile(pkBfg, Eye + Dir * 24, Dir, 300, 200, False, Monster);
        FProjectiles.Last.SplashDamage := Monster.AttackDamage;
        FProjectiles.Last.SplashRadius := Monster.AttackRadius;
      end;
    akHitscan, akPellets, akRail:
      if Monster.CanSeePlayer then
      begin
        { Accuracy falls off with distance }
        Accuracy := EnsureRange(1.1 - Dist / 1200, 0.25, 0.95);
        if Monster.AttackKind = akPellets then
        begin
          Hits := 0;
          { 9 pellets (Quake 2 shotgun soldiers) or the shot's own count
            (Quake 1's grunt: 4) }
          for I := 1 to Max(Monster.AttackBullets, 9 * Ord(Monster.AttackBullets <= 1)) do
            if Random < Accuracy * 0.8 then
              Inc(Hits);
          if Hits > 0 then
            DamagePlayer(Hits * Monster.AttackDamage, Eye);
        end else
        if Monster.AttackKind = akRail then
        begin
          Particles.SpawnRailTrail(Eye, Target);
          Sounds.PlayAt('sound/weapons/railgf1a.wav', Monster.Transform, 1, 1, chWeapon);
          if Random < Accuracy then
            DamagePlayer(Monster.AttackDamage, Eye);
        end else
        begin
          for I := 1 to Monster.AttackBullets do
            if Random < Accuracy * 0.6 then
              DamagePlayer(Monster.AttackDamage, Eye);
          Particles.SpawnImpact(Target + Vector3((Random - 0.5) * 40, (Random - 0.5) * 30,
            (Random - 0.5) * 40), -Dir);
        end;
      end;
    akBlaster:
      if Monster.AttackSpeed > 0 then
        SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, Monster.AttackSpeed, Monster.AttackDamage, False, Monster)
      else
        SpawnProjectile(pkBlasterBolt, Eye + Dir * 20, Dir, 600, Monster.AttackDamage, False, Monster);
    akRocket:
      { Volleys (the hornet's four rockets) leave from side by side muzzles }
      for I := 0 to Max(1, Monster.AttackBullets) - 1 do
        SpawnProjectile(pkRocket, Eye + Dir * 24 +
          TVector3.CrossProduct(Dir, Vector3(0, 1, 0)).Normalize * (16 * (I - (Monster.AttackBullets - 1) / 2)),
          Dir, 500, Monster.AttackDamage, False, Monster);
    akGrenade:
      SpawnProjectile(pkGrenade, Eye + Dir * 24, (Dir + Vector3(0, 0.35, 0)).Normalize,
        Min(600, Dist * 1.1), Monster.AttackDamage, False, Monster);
    akRipper, akBlueBlaster, akLoogie, akHeatRocket, akPlasma:
      XatrixMonsterShot(Monster, Eye, Dir);
    akSummon:
      if Monster.Def^.ClassName = 'monster_medic_commander' then
        MedicSummon(Monster)
      else
        BossSummon(Monster);
    akHeatBeam:
      HeatBeam(Monster, Eye, Target);
    akLaser:
      begin
        { The laser soldier's beam (dabeam): 1 to the player each frame it
          holds, unless a wall is in the way; it re-aims with a little lag }
        Target := Target + Vector3((Random - 0.5) * 16, (Random - 0.5) * 16, (Random - 0.5) * 16);
        if WorldTrace(CgeToQuake(Eye), CgeToQuake(Target), TVector3.Zero, TVector3.Zero,
           CONTENTS_SOLID or CONTENTS_WINDOW, Monster).Fraction >= 1 then
        begin
          DamagePlayer(Monster.AttackDamage, Eye);
          Particles.SpawnBeam(Eye, Target, Vector3(1.0, 0.15, 0.1));
        end;
      end;
  end;
end;

procedure TQuakeWorld.XatrixMonsterShot(const Monster: TQuakeMonster; const Eye, Dir: TVector3);
var
  Kind: TProjectileKind;
  Speed: Single;
  Sound: String;
  Proj: TQuakeProjectile;
begin
  { The Reckoning's monster projectiles: monster_fire_ionripper (600),
    monster_fire_blueblaster (600), the gekk's loogie (550), fire_heat (the
    heat chick 500, turning 0.15; boss5 500, 0.075), fire_plasma (725) }
  Sound := '';
  case Monster.AttackKind of
    akRipper:
      begin
        Kind := pkRipper;
        Speed := 600;
        Sound := 'sound/weapons/rippfire.wav';
      end;
    akBlueBlaster:
      begin
        Kind := pkBlueBolt;
        Speed := 600;
        Sound := 'sound/weapons/hyprbf1a.wav';
      end;
    akLoogie:
      begin
        Kind := pkLoogie;
        Speed := 550;
      end;
    akHeatRocket:
      begin
        Kind := pkHeatRocket;
        Speed := 500;
      end;
  else
    Kind := pkPlasma;
    Speed := 725;
    Sound := 'sound/weapons/plasshot.wav';
  end;
  if Monster.AttackSpeed > 0 then
    Speed := Monster.AttackSpeed;
  if Sound <> '' then
    Sounds.PlayAt(Sound, Monster.Transform, 1, 1, chWeapon);
  SpawnProjectile(Kind, Eye + Dir * 20, Dir, Speed, Monster.AttackDamage, False, Monster);
  Proj := FProjectiles.Last;
  case Kind of
    pkHeatRocket:
      begin
        Proj.SplashDamage := Monster.AttackDamage;
        Proj.SplashRadius := 50;
        if Monster.Def^.ClassName = 'monster_chick_heat' then
          Proj.HeatTurn := 0.15
        else
          Proj.HeatTurn := 0.075;
      end;
    pkPlasma:
      begin
        { gladb: 35 on a hit and 45 within 45 (17 / 22 for the second ball) }
        Proj.SplashDamage := Round(Monster.AttackDamage * 9 / 7);
        Proj.SplashRadius := Max(1, Monster.AttackRadius);
      end;
  end;
end;
