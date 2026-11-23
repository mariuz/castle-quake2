{ Projectiles: rockets, grenades, BFG, traps, prox and tesla mines, explosions.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.TeslaThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
const
  { TESLA_ACTIVATE_TIME, TESLA_TIME_TO_LIVE; the field: 128 each way, up
    128 from its bottom; TESLA_EXPLOSION_DAMAGE_MULT 50, radius 200 }
  ActivateTime = 3;
  TimeToLive = 30;
var
  Pos, Top, Mins, Maxs: TVector3;
  M: TQuakeMonster;
  Frame: Integer;

  procedure Blow;
  begin
    { tesla_remove / tesla_blow: the grenade explosion, 50 times its zap }
    WritelnLog('QuakeWorld', 'Tesla blows up');
    Explode(Proj.Transform.Translation + Vector3(0, 8, 0), Proj.Damage * 50, 200, Proj.FromPlayer);
    Proj.Life := 0;
  end;

begin
  Proj.TeslaClock := Proj.TeslaClock + SecondsPassed;
  Pos := Proj.Transform.Translation;
  if not Proj.TeslaActive then
  begin
    if Proj.TeslaClock < ActivateTime then
      Exit;
    { tesla_activate: open frames 0..14 a tenth of a second each (skins on
      10, 12 and 14), then on }
    Frame := Min(14, Trunc((Proj.TeslaClock - ActivateTime) * 10));
    if Frame <> Proj.TeslaFrame then
    begin
      if Proj.TeslaFrame < 0 then
        Sounds.PlayAt('sound/weapons/teslaopen.wav', Proj.Transform);
      Proj.TeslaFrame := Frame;
      if Proj.Model <> nil then
      begin
        Proj.Model.SetFrame(Frame);
        if Frame >= 14 then
          Proj.Model.SetSkin(3)
        else
        if Frame >= 12 then
          Proj.Model.SetSkin(2)
        else
        if Frame >= 10 then
          Proj.Model.SetSkin(1);
      end;
    end;
    if Proj.TeslaClock < ActivateTime + 1.6 then
      Exit;
    { In water, slime or lava it blows up at once }
    if (MonsterPointContents(CgeToQuake(Pos + Vector3(0, 4, 0))) and MASK_LIQUID) <> 0 then
    begin
      Blow;
      Exit;
    end;
    Proj.TeslaActive := True;
    Proj.TeslaClock := 0;
    WritelnLog('QuakeWorld', 'Tesla active at %s', [CgeToQuake(Pos).ToString]);
    Exit;
  end;
  if Proj.TeslaClock >= TimeToLive then
  begin
    Blow;
    Exit;
  end;
  { tesla_think_active: every 0.1 s each monster in the field it can see
    takes 3 (times the multiplier), drawn as lightning }
  Proj.TeslaZap := Proj.TeslaZap - SecondsPassed;
  if Proj.TeslaZap > 0 then
    Exit;
  Proj.TeslaZap := Proj.TeslaZap + 0.1;
  Top := Pos + Vector3(0, 16, 0);
  for M in FMonsters do
    if M.IsAlive and (not M.Dormant) then
    begin
      Mins := M.Origin + M.BoxMins;
      Maxs := M.Origin + M.BoxMaxs;
      if (Maxs.X < CgeToQuake(Pos).X - 128) or (Mins.X > CgeToQuake(Pos).X + 128) or
         (Maxs.Y < CgeToQuake(Pos).Y - 128) or (Mins.Y > CgeToQuake(Pos).Y + 128) or
         (Maxs.Z < CgeToQuake(Pos).Z) or (Mins.Z > CgeToQuake(Pos).Z + 128) then
        Continue;
      if not HintPointsVisible(Top, M.Transform.Translation) then
        Continue;
      Particles.SpawnBeam(Top, M.Transform.Translation, Vector3(0.6, 0.7, 1.0));
      M.TakeDamage(Proj.Damage);
      if not M.IsAlive then
        WritelnLog('QuakeWorld', 'Tesla killed %s', [M.Transform.Name]);
    end;
end;

procedure TQuakeWorld.AddProjectileLights;
var
  Proj: TQuakeProjectile;
begin
  { Quake 2 CL_AddPacketEntities: EF_ROCKET / EF_BLASTER / EF_HYPERBLASTER / EF_BFG }
  for Proj in FProjectiles do
    case Proj.Kind of
      { EF_TRAP: a flickering orange light while it is open }
      pkTrap:
        if Proj.TrapFrame >= 4 then
          Lighting.AddLight(Proj.Transform.Translation, 100 + Random(100), Vector3(1, 0.8, 0.1));
      pkRocket, pkBlasterBolt, pkHeatRocket, pkLoogie:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(1, 1, 0));
      { EF_IONRIPPER / EF_BLUEHYPERBLASTER / EF_PLASMA (the client's colours
        aren't in the game code: orange, blue and white-blue here) }
      pkRipper:
        Lighting.AddLight(Proj.Transform.Translation, 120, Vector3(1, 0.5, 0.1));
      pkBlueBolt:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0.2, 0.3, 1));
      pkPlasma:
        Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0.6, 0.8, 1));
      pkBfg:
        if not Proj.Exploding then
          Lighting.AddLight(Proj.Transform.Translation, 200, Vector3(0, 1, 0));
    end;
end;

procedure TQuakeWorld.SpawnProjectile(const Kind: TProjectileKind; const Origin, Dir: TVector3;
  const Speed: Single; const Damage: Integer; const FromPlayer: Boolean; const Owner: TQuakeMonster);
var
  Proj: TQuakeProjectile;
begin
  Proj := TQuakeProjectile.Create(FItems, Kind, Origin, Dir * Speed, Damage, FromPlayer);
  Proj.Owner := Owner;
  { fire_blaster, fire_rocket and fire_bfg let the target dodge }
  if FromPlayer and (Kind in [pkBlasterBolt, pkRocket, pkBfg, pkRipper, pkPlasma]) then
    CheckDodge(Origin, Dir, Speed);
  case Kind of
    pkRocket:
      begin
        Proj.SplashDamage := 120;
        Proj.SplashRadius := 120;
      end;
    pkGrenade:
      begin
        Proj.SplashDamage := Damage;
        Proj.SplashRadius := 160;
        Proj.Life := 2.5;
      end;
    pkHandGrenade:
      begin
        Proj.SplashDamage := Damage;
        Proj.SplashRadius := 165;
        Proj.Life := 3;
      end;
    pkBfg:
      begin
        { weapon_bfg_fire: fire_bfg(damage 500, speed 400, radius 1000); the
          shot's Damage is the 200 of the core hit, both times the quad }
        Proj.SplashDamage := Damage * 5 div 2;
        Proj.SplashRadius := 1000;
        Proj.LaserTimer := 0.1;
      end;
  end;
  FProjectiles.Add(Proj);
end;

function TQuakeWorld.ProjectileCount: Integer;
begin
  Result := FProjectiles.Count;
end;

procedure TQuakeWorld.Explode(const Pos: TVector3; const Damage: Integer; const Radius: Single;
  const FromPlayer: Boolean; const ExplosionSound: Boolean);
var
  M: TQuakeMonster;
  Mover: TQuakeMover;
  Prop: TQuakeProp;
  Dist: Single;
  Points: Integer;
begin
  Particles.SpawnExplosion(Pos);
  { Quake 2 rocket / grenade impacts: PlayerNoise(PNOISE_IMPACT) }
  if FromPlayer then
    PlayerNoise(Pos);
  { Heard from where it happens (Quake 2 TE_ROCKET_EXPLOSION, ATTN_NORM) }
  if ExplosionSound then
    Sounds.PlayAtPoint('sound/weapons/rocklx1a.wav', Pos);
  { Quake 2 explosion light: radius 350, orange, fading with the fireball }
  Lighting.AddLight(Pos, 350, Vector3(1, 0.5, 0.5), 0.5);
  if Damage <= 0 then
    Exit;
  for M in FMonsters do
  begin
    Dist := PointsDistance(M.Transform.Translation, Pos);
    if Dist < Radius then
    begin
      Points := Round(Damage * (1 - 0.5 * Dist / Radius));
      if Points > 0 then
        M.TakeDamage(Points);
    end;
  end;
  { Splash damage also sets off explosive brushes and barrels (chain reactions) }
  if (FGeometry <> nil) and (FUseDepth < 8) then
  begin
    Inc(FUseDepth);
    try
      for Mover in FGeometry.Movers do
        if (Mover.Health > 0) and Mover.Transform.Exists and
           (PointsDistance(Mover.Center, Pos) < Radius + 32) then
          DamageMover(Mover, Damage div 2);
      for Prop in FProps do
        if (Prop.Kind in [pkExplobox, pkRotatingLight]) and not Prop.Destroyed and
           (PointsDistance(Prop.Transform.Translation, Pos) < Radius) then
          DamageProp(Prop, Damage div 2);
    finally
      Dec(FUseDepth);
    end;
  end;

  Dist := PointsDistance(FPlayerPos - Vector3(0, 22, 0), Pos);
  if Dist < Radius then
  begin
    Points := Round(Damage * (1 - 0.5 * Dist / Radius));
    { Self damage is halved, like Quake 2 rockets }
    if FromPlayer then
      Points := Points div 2;
    if Points > 0 then
      DamagePlayer(Points, Pos);
  end;
end;

procedure TQuakeWorld.BfgLasers(const Proj: TQuakeProjectile);
const
  LaserMask = CONTENTS_SOLID or CONTENTS_MONSTER or CONTENTS_DEADMONSTER;
  LaserDamage = 10; { single player }
var
  Origin: TVector3;

  procedure LaserAt(const Target: TVector3);
  var
    Dir, Start, Stop: TVector3;
    Ignore: TObject;
    T: TQuakeTrace;
    I: Integer;
  begin
    Dir := (Target - Origin).Normalize;
    Start := Origin;
    Stop := Origin + Dir * 2048;
    Ignore := nil;
    { Through monsters (and the player), hurting each, until something else }
    for I := 0 to 7 do
    begin
      T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, LaserMask, Ignore);
      if not T.Hit then
        Break;
      if T.Ent is TQuakeMonster then
      begin
        if T.Ent <> Proj.Owner then
          TQuakeMonster(T.Ent).TakeDamage(LaserDamage);
      end else
      if T.Ent is TQuakePMove then
      begin
        if not Proj.FromPlayer then
          DamagePlayer(LaserDamage, QuakeToCge(Origin));
      end else
        Break;
      Ignore := T.Ent;
      Start := T.EndPos;
    end;
    Particles.SpawnBfgLaser(QuakeToCge(Origin), QuakeToCge(T.EndPos));
  end;

var
  M: TQuakeMonster;
  Center: TVector3;
begin
  Origin := CgeToQuake(Proj.Transform.Translation);
  for M in FMonsters do
    if M.IsAlive and (M <> Proj.Owner) and M.Transform.Exists then
    begin
      Center := MonsterCenter(M);
      if PointsDistance(Center, Origin) <= 256 then
        LaserAt(Center);
    end;
  if not Proj.FromPlayer and not FDead then
  begin
    Center := CgeToQuake(FPlayerPos - Vector3(0, 22, 0));
    if PointsDistance(Center, Origin) <= 256 then
      LaserAt(Center);
  end;
end;

procedure TQuakeWorld.BfgEffect(const Proj: TQuakeProjectile);
const
  SightMask = CONTENTS_SOLID or CONTENTS_WINDOW;
var
  Origin, Shooter: TVector3;

  { CanDamage, simplified to the centre: no brush between the two points }
  function Clear(const A, B: TVector3): Boolean;
  begin
    Result := not WorldTrace(A, B, TVector3.Zero, TVector3.Zero, SightMask, nil).Hit;
  end;

  function Points(const Center: TVector3): Integer;
  var
    Dist: Single;
  begin
    Result := 0;
    Dist := PointsDistance(Center, Origin);
    if (Dist > Proj.SplashRadius) or not Clear(Origin, Center) or not Clear(Shooter, Center) then
      Exit;
    Result := Round(Proj.SplashDamage * (1 - Sqrt(Dist / Proj.SplashRadius)));
  end;

  procedure HitEffect(const CgePos: TVector3);
  begin
    { TE_BFG_EXPLOSION: the s_bfg2 sprite and a green light }
    Particles.SpawnBfgHit(CgePos);
    Lighting.AddLight(CgePos, 350, Vector3(0, 1, 0), 0.4);
  end;

var
  M: TQuakeMonster;
  N: Integer;
begin
  Origin := CgeToQuake(Proj.Transform.Translation);
  if Proj.FromPlayer then
    Shooter := CgeToQuake(FPlayerPos)
  else
  if Proj.Owner <> nil then
    Shooter := MonsterCenter(Proj.Owner)
  else
    Shooter := Origin;
  for M in FMonsters do
    if (M <> Proj.Owner) and not M.Gibbed and M.Transform.Exists then
    begin
      N := Points(MonsterCenter(M));
      if N <= 0 then
        Continue;
      HitEffect(M.Transform.Translation);
      M.TakeDamage(N);
    end;
  if not Proj.FromPlayer and not FDead then
  begin
    N := Points(CgeToQuake(FPlayerPos - Vector3(0, 22, 0)));
    if N > 0 then
    begin
      HitEffect(FPlayerPos - Vector3(0, 22, 0));
      DamagePlayer(N, Proj.Transform.Translation);
    end;
  end;
end;

procedure TQuakeWorld.TrapThink(const Proj: TQuakeProjectile);
var
  M, Best: TQuakeMonster;
  TrapQ, Vec, Org: TVector3;
  Len, BestLen, Speed: Single;
  T: TQuakeTrace;
  Ent: TQuakeEntity;
begin
  { Trap_Think (10 Hz, on the ground only) }
  if not Proj.TrapLanded then
    Exit;
  TrapQ := CgeToQuake(Proj.Transform.Translation);
  if Proj.TrapFrame > 4 then
  begin
    { A monster went in: frame 5 while the gibs turn (wait 64 down by 2),
      then 6, 7 and at 8 the food cube }
    if Proj.TrapFrame = 5 then
    begin
      if Proj.TrapWait = 64 then
        Sounds.PlayAtPoint('sound/weapons/trapdown.wav', Proj.Transform.Translation);
      Dec(Proj.TrapWait, 2);
      if Proj.TrapWait < 19 then
        Inc(Proj.TrapFrame);
    end else
    if Proj.TrapFrame < 8 then
    begin
      Inc(Proj.TrapFrame);
      if Proj.TrapFrame = 8 then
      begin
        { SP_item_foodcube: a tenth of the monster's mass in health, from
          24 above the trap; the trap goes 1 s later }
        Org := TrapQ + Vector3(0, 0, 24);
        Ent := TQuakeEntity.Create;
        Ent.SetField('classname', 'item_foodcube');
        Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
        Ent.SetField('count', IntToStr(Max(1, Proj.TrapMass div 10)));
        FBsp.Entities.Add(Ent);
        SpawnEntity(Ent);
        Sounds.PlayAtPoint('sound/misc/fhit3.wav', Proj.Transform.Translation);
        Proj.Life := 1;
        Proj.TrapSucking := False;
        WritelnLog('QuakeWorld', 'Trap made a food cube of %d health', [Max(1, Proj.TrapMass div 10)]);
      end;
    end;
    if Proj.Model <> nil then
      Proj.Model.SetFrame(Min(Proj.TrapFrame, 7));
    Exit;
  end;

  if Proj.TrapFrame < 4 then
  begin
    Inc(Proj.TrapFrame);
    if Proj.Model <> nil then
      Proj.Model.SetFrame(Proj.TrapFrame);
    Exit;
  end;

  { Open (EF_TRAP): the nearest live monster it can see within 256 }
  Best := nil;
  BestLen := 8000;
  for M in FMonsters do
  begin
    if (not M.IsAlive) or M.Dormant or (not M.Transform.Exists) then
      Continue;
    Len := (M.Origin - TrapQ).Length;
    if (Len > 256) or (Len >= BestLen) then
      Continue;
    T := WorldTrace(TrapQ + Vector3(0, 0, 4), MonsterCenter(M), TVector3.Zero, TVector3.Zero, MASK_OPAQUE, nil);
    if T.Hit then
      Continue;
    Best := M;
    BestLen := Len;
  end;
  Proj.TrapSucking := Best <> nil;
  if Best = nil then
    Exit;

  { Pull it in: up to 150 a second, faster the nearer (at least 64) }
  Vec := TrapQ - Best.Origin;
  Len := Vec.Length;
  if Len > 0.001 then
    Vec := Vec / Len;
  Speed := EnsureRange(150 - Len, 64, 150);
  Best.MonsterJump(QuakeToCge(Vector3(Vec.X, Vec.Y, 0)) * Speed, 50);
  if Len < 48 then
  begin
    if MonsterMass(Best.Def^.ClassName) < 400 then
    begin
      WritelnLog('QuakeWorld', 'Trap swallowed %s', [Best.Transform.Name]);
      Proj.TrapMass := MonsterMass(Best.Def^.ClassName);
      Best.TakeDamage(100000);
      Proj.TrapWait := 64;
      Proj.Life := 30;
      Proj.TrapFrame := 5;
      Proj.TrapSucking := False;
      if Proj.Model <> nil then
        Proj.Model.SetFrame(5);
    end else
    begin
      WritelnLog('QuakeWorld', 'Trap: %s is too heavy', [Best.Transform.Name]);
      Proj.Life := 0;
    end;
  end;
end;

procedure TQuakeWorld.ProxThink(const Proj: TQuakeProjectile; const SecondsPassed: Single);
const
  { PROX_DAMAGE_RADIUS, PROX_BOUND_SIZE }
  DamageRadius = 192;
  FieldSize = 96;
var
  M: TQuakeMonster;
  Pos: TVector3;
  Mult: Integer;
  Box: TBox3D;
begin
  Pos := Proj.Transform.Translation;
  { prox_open: 10 frames of opening, then armed }
  if Proj.ProxArm > 0 then
  begin
    Proj.ProxArm := Proj.ProxArm - SecondsPassed;
    if Proj.ProxArm > 0 then
      Exit;
    { Armed: a monster in sight within 202 sets it off now; else it lives
      45 s (30, 15, 10 with double, quad or both) }
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and (PointsDistance(M.Transform.Translation, Pos) < DamageRadius + 10) and
         M.HasLineOfSight(Pos) then
      begin
        Proj.ProxTrigger := 0;
        Break;
      end;
    Mult := Max(1, Proj.Damage div 90);
    case Mult of
      1: Proj.ProxFuse := 45;
      2: Proj.ProxFuse := 30;
      4: Proj.ProxFuse := 15;
      else Proj.ProxFuse := 10;
    end;
  end;
  { prox_field_touch: a monster in the 192 box: proxwarn, off 0.5 s later }
  if Proj.ProxTrigger < 0 then
  begin
    Box := Box3D(Pos - Vector3(FieldSize, FieldSize, FieldSize), Pos + Vector3(FieldSize, FieldSize, FieldSize));
    for M in FMonsters do
      if M.IsAlive and (not M.Dormant) and Box.Collision(M.Transform.BoundingBox) then
      begin
        Proj.ProxTrigger := 0.5;
        Sounds.PlayAt('sound/weapons/proxwarn.wav', Proj.Transform);
        Break;
      end;
  end;
  if Proj.ProxTrigger >= 0 then
    Proj.ProxTrigger := Proj.ProxTrigger - SecondsPassed;
  Proj.ProxFuse := Proj.ProxFuse - SecondsPassed;
  if (Proj.ProxTrigger < 0) and (Proj.ProxTrigger > -0.5) or (Proj.ProxFuse <= 0) then
  begin
    { Prox_Explode: 90 (times the multiplier) within 192 }
    WritelnLog('QuakeWorld', 'Prox mine goes off');
    Explode(Pos, Proj.Damage, DamageRadius, Proj.FromPlayer);
    Proj.Life := 0;
  end;
end;

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single);
var
  I: Integer;
  Proj: TQuakeProjectile;
  OldPos, Dir, NewPos, HitNormal: TVector3;
  StepLen: Single;
  Remove, Damageable: Boolean;
  T: TQuakeTrace;
  Shooter: TObject;
begin
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    Proj := FProjectiles[I];
    Proj.Life := Proj.Life - SecondsPassed;
    Remove := False;
    OldPos := Proj.Transform.Translation;

    if (Proj.Kind in [pkGrenade, pkHandGrenade]) or ((Proj.Kind in [pkTrap, pkTesla]) and not Proj.TrapLanded) or
       ((Proj.Kind = pkProx) and not Proj.ProxStuck) then
      Proj.Velocity.Y := Proj.Velocity.Y - 800 * SecondsPassed;
    if Proj.Sprite <> nil then
      Proj.Sprite.Update(SecondsPassed);

    if Proj.Life <= 0 then
    begin
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
        Explode(OldPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer)
      else
      if Proj.Exploding then
        BfgEffect(Proj)
      else
      if Proj.Kind = pkRipper then
        { ionripper_think: TE_WELDING_SPARKS when its 3 s are up }
        TempEntity(TE_WELDING_SPARKS, OldPos)
      else
      if (Proj.Kind = pkTrap) and (Proj.TrapFrame < 8) then
      begin
        { Trap_Think after 30 s (or a monster too heavy): BecomeExplosion1,
          no damage }
        TempEntity(TE_EXPLOSION1, OldPos);
        WritelnLog('QuakeWorld', 'Trap blew up');
      end;
      FProjectiles.Delete(I);
      Continue;
    end;

    if Proj.Kind = pkTesla then
    begin
      TeslaThink(Proj, SecondsPassed);
      if Proj.Life <= 0 then
      begin
        FProjectiles.Delete(I);
        Continue;
      end;
      if Proj.TrapLanded then
        Continue;
    end;

    if (Proj.Kind = pkProx) and Proj.ProxStuck then
    begin
      ProxThink(Proj, SecondsPassed);
      if Proj.Life <= 0 then
        FProjectiles.Delete(I);
      Continue;
    end;

    if Proj.Kind = pkTrap then
    begin
      Proj.TrapTimer := Proj.TrapTimer - SecondsPassed;
      while Proj.TrapTimer <= 0 do
      begin
        Proj.TrapTimer := Proj.TrapTimer + 0.1;
        TrapThink(Proj);
      end;
      if Proj.TrapLanded then
        Continue;
    end;

    if (Proj.Kind = pkHeatRocket) and (Proj.HeatTurn > 0) then
      SteerHeatRocket(Proj, SecondsPassed);

    if (Proj.Kind = pkBfg) and not Proj.Exploding then
    begin
      Proj.LaserTimer := Proj.LaserTimer - SecondsPassed;
      if Proj.LaserTimer <= 0 then
      begin
        Proj.LaserTimer := Proj.LaserTimer + 0.1;
        BfgLasers(Proj);
      end;
    end;

    StepLen := Proj.Velocity.Length * SecondsPassed;
    if StepLen < 0.001 then
      Continue;
    Dir := Proj.Velocity.Normalize;
    NewPos := OldPos + Dir * StepLen;

    { Quake 2 MOVETYPE_FLYMISSILE / BOUNCE: a point trace along the step,
      ignoring the shooter }
    if Proj.FromPlayer then
      Shooter := FPlayer
    else
      Shooter := Proj.Owner;
    T := WorldTrace(CgeToQuake(OldPos), CgeToQuake(NewPos), TVector3.Zero, TVector3.Zero, MASK_SHOT, Shooter);
    if T.Hit and not T.AllSolid then
    begin
      NewPos := QuakeToCge(T.EndPos);
      HitNormal := QuakeToCge(T.Normal);
      Damageable := (T.Ent is TQuakeMonster) or (T.Ent is TQuakePMove);
      if (Proj.Kind = pkRipper) and not Damageable then
      begin
        { MOVETYPE_WALLBOUNCE: a perfect reflection off anything that doesn't
          take damage (the sky ends it) }
        if (T.Contents and CONTENTS_SOLID) = 0 then
          Remove := True
        else
        begin
          Proj.Velocity := Proj.Velocity - HitNormal * (2 * TVector3.DotProduct(Proj.Velocity, HitNormal));
          NewPos := NewPos + HitNormal * 0.5;
        end;
      end else
      if Proj.Kind in [pkTrap, pkTesla] then
      begin
        { MOVETYPE_BOUNCE off everything; it stays where it lands }
        Proj.Velocity := Proj.Velocity - HitNormal * (1.5 * TVector3.DotProduct(Proj.Velocity, HitNormal));
        NewPos := NewPos + HitNormal * 0.5;
        if (HitNormal.Y > 0.7) and (Proj.Velocity.Y < 60) then
        begin
          Proj.Velocity := TVector3.Zero;
          Proj.TrapLanded := True;
          Proj.Transform.Rotation := Vector4(0, 1, 0, Random * 2 * Pi);
        end;
      end else
      if Proj.Kind = pkProx then
      begin
        { prox_land: a monster (or the player) sets it off; lava or slime
          too; it sticks to the world and to movers' tops }
        if Damageable or ((T.Contents and (8 or 16)) <> 0) or
           ((T.Ent is TQuakeMover) and (HitNormal.Y <= 0.7)) then
        begin
          Explode(NewPos, Proj.Damage, 192, Proj.FromPlayer);
          Remove := True;
        end else
        if (T.Contents and CONTENTS_SOLID) = 0 then
          Remove := True
        else
        begin
          NewPos := NewPos + HitNormal * 0.5;
          Proj.Velocity := TVector3.Zero;
          Proj.ProxStuck := True;
          Proj.ProxArm := 0.5;
          Proj.ProxFuse := -1;
          Proj.ProxTrigger := -1;
          Sounds.PlayAt('sound/weapons/proxopen.wav', Proj.Transform);
          WritelnLog('QuakeWorld', 'Prox mine stuck at %s', [CgeToQuake(NewPos).ToString]);
        end;
      end else
      if Proj.Kind in [pkGrenade, pkHandGrenade] then
      begin
        if Damageable then
        begin
          Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          Remove := True;
        end else
        begin
          { ClipVelocity with overbounce 1.5; stop on floors when slow }
          Proj.Velocity := Proj.Velocity - HitNormal * (1.5 * TVector3.DotProduct(Proj.Velocity, HitNormal));
          NewPos := NewPos + HitNormal * 0.5;
          if (HitNormal.Y > 0.7) and (Proj.Velocity.Y < 60) then
          begin
            Proj.Velocity := Proj.Velocity * 0.6;
            Proj.Velocity.Y := 0;
          end;
          if Proj.Velocity.Length > 30 then
          begin
            if Proj.Kind = pkHandGrenade then
              Sounds.PlayAt(Format('sound/weapons/hgrenb%da.wav', [1 + Random(2)]), Proj.Transform)
            else
              Sounds.PlayAt('sound/weapons/grenlb1b.wav', Proj.Transform);
          end;
        end;
      end else
      begin
        if T.Ent is TQuakeMonster then
        begin
          TQuakeMonster(T.Ent).TakeDamage(Proj.Damage);
          Particles.SpawnBlood(NewPos, -Dir);
        end else
        if T.Ent is TQuakePMove then
        begin
          FDamageSource := Proj.Owner;
          if Proj.Kind in [pkBlasterBolt, pkBfg, pkRipper, pkBlueBolt, pkLoogie, pkPlasma] then
            DamagePlayer(Proj.Damage, OldPos);
        end else
        if T.Ent is TQuakeMover then
          DamageMover(TQuakeMover(T.Ent), Proj.Damage)
        else
        if T.Ent is TQuakeProp then
          DamageProp(TQuakeProp(T.Ent), Proj.Damage);
        case Proj.Kind of
          pkRocket, pkHeatRocket: Explode(NewPos, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          pkPlasma:
            { plasma_touch: the hit, then the splash (TE_PLASMA_EXPLOSION) }
            Explode(NewPos - Dir * 2, Proj.SplashDamage * DamageMultiplier, Proj.SplashRadius, Proj.FromPlayer);
          pkBfg:
            begin
              { bfg_touch: the core blast (T_RadiusDamage 200 within 100), the
                s_bfg3 explosion, then the BFG effect a frame later from
                where the ball was 0.1 s before }
              Particles.SpawnBfgExplosion(NewPos);
              Lighting.AddLight(NewPos, 350, Vector3(0, 1, 0), 0.5);
              Sounds.PlayAtPoint('sound/weapons/bfg__x1b.wav', NewPos);
              Explode(NewPos, 200, 100, Proj.FromPlayer, False);
              Proj.Exploding := True;
              Proj.Life := 0.1;
              NewPos := NewPos - Proj.Velocity * 0.1;
              Proj.Velocity := TVector3.Zero;
              Proj.Transform.Exists := False;
            end;
          { flechette_touch: TE_FLECHETTE on walls }
          pkFlechette:
            if not Damageable then
              Particles.SpawnImpact(NewPos - Dir * 2, -Dir);
          else
            begin
              Particles.SpawnBlasterImpact(NewPos - Dir * 2, -Dir);
              Sounds.PlayAtPoint('sound/weapons/lashit.wav', NewPos);
            end;
        end;
        { an exploding BFG ball stays until its effect went off }
        Remove := not Proj.Exploding;
      end;
    end;

    if Remove then
      FProjectiles.Delete(I)
    else
      Proj.Transform.Translation := NewPos;
  end;
end;

procedure TQuakeWorld.SteerHeatRocket(const Proj: TQuakeProjectile; const SecondsPassed: Single);
var
  Pos, ToTarget, Dir: TVector3;
  Speed, F: Single;
begin
  { heat_think: towards the player when he is alive, in sight and within
    1024 (the only client here), every 0.025 s by HeatTurn of the way:
    over SecondsPassed that is 1 - (1 - HeatTurn) ^ (SecondsPassed / 0.025) }
  if FDead then
    Exit;
  Pos := Proj.Transform.Translation;
  ToTarget := (FPlayerPos - Vector3(0, 12, 0)) - Pos;
  if (ToTarget.Length > 1024) or (ToTarget.Length < 1) or
     (WorldTrace(CgeToQuake(Pos), CgeToQuake(FPlayerPos), TVector3.Zero, TVector3.Zero,
      CONTENTS_SOLID or CONTENTS_WINDOW, nil).Fraction < 1) then
    Exit;
  Speed := Proj.Velocity.Length;
  if Speed < 1 then
    Exit;
  F := 1 - Power(1 - Proj.HeatTurn, SecondsPassed / 0.025);
  Dir := Proj.Velocity / Speed;
  Dir := (Dir + (ToTarget.Normalize - Dir) * F).Normalize;
  Proj.Velocity := Dir * Speed;
end;
