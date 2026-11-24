{ The player's weapons: the gun model and frames, firing, switching.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.AttachWeaponToCamera(const Camera, ViewCamera: TCastleTransform);
begin
  FViewCamera := ViewCamera;
  if FWeaponTransform.Parent <> nil then
    FWeaponTransform.Parent.Remove(FWeaponTransform);
  Camera.Add(FWeaponTransform);
  { Quake models face +X; the camera looks along -Z }
  FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
end;

procedure TQuakeWorld.SetGunAngles(const Angles: TVector3);
var
  Q: TQuaternion;
begin
  { Camera space: pitch around +X (negative = down), yaw around +Y, roll
    around -Z (the view axis); then the base turn of the model (+X to -Z) }
  Q := QuatFromAxisAngle(Vector3(1, 0, 0), -DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, -1), DegToRad(Angles.Z)) *
    QuatFromAxisAngle(Vector3(0, 1, 0), Pi / 2);
  FWeaponTransform.Rotation := Q.ToAxisAngle;
end;

procedure TQuakeWorld.UpdateWeaponModel;
begin
  { The view weapon is the local player's }
  if not IsLocal then
    Exit;
  if FWeaponModelSlot = FCur.Stats.CurrentWeapon then
    Exit;
  FWeaponModelSlot := FCur.Stats.CurrentWeapon;
  FreeAndNil(FWeaponModel);
  FWeaponModel := Md2Manager.CreateInstance(WeaponDefs[FCur.Stats.CurrentWeapon].ViewModel);
  if FWeaponModel <> nil then
  begin
    FWeaponModel.Scene.Collides := False;
    FWeaponModel.Scene.Pickable := False;
    FWeaponTransform.Add(FWeaponModel.Scene);
    FWeaponModel.ShowFrames(FCur.Gun.OldFrame, FCur.Gun.Frame, FCur.Gun.FrameLerp);
  end;
end;

procedure TQuakeWorld.FireHitscan(const Origin, Dir: TVector3; const Damage: Integer;
  const HSpread, VSpread: Single; const Rail: Boolean);
var
  ShotDir, HitPos, Right, Muzzle, Start, Stop: TVector3;
  T: TQuakeTrace;
  Ignore: TObject;
  Pierce: Integer;
begin
  ShotDir := SpreadDir(Dir, HSpread, VSpread);
  { Rail trails start at the gun muzzle (right and below the eye), not the eye }
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.Length > 0.001 then
    Right := Right.Normalize;
  Muzzle := Origin + Dir * 24 + Right * 7 - Vector3(0, 8, 0);
  { Quake 2 fire_lead / fire_rail: a point trace for MASK_SHOT; the railgun
    goes on through monsters (ignoring the one it just hit) }
  Start := CgeToQuake(Origin);
  Stop := Start + CgeToQuake(ShotDir) * 8192;
  Ignore := FCur.PM;
  for Pierce := 0 to 4 do
  begin
    T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, Ignore);
    HitPos := QuakeToCge(T.EndPos);
    if not T.Hit then
    begin
      if Rail then
        Particles.SpawnRailTrail(Muzzle, HitPos);
      Exit;
    end;
    if (T.Ent is TQuakeMonster) or (T.Ent is TQuakePMove) then
    begin
      if T.Ent is TQuakeMonster then
        TQuakeMonster(T.Ent).TakeDamage(Damage)
      else
        DamagePlayerHit(T.Ent, Damage, Origin);
      Particles.SpawnBlood(HitPos, -ShotDir);
      if Rail then
      begin
        Start := T.EndPos;
        Ignore := T.Ent;
        Continue;
      end;
      Exit;
    end;
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Damage)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Damage);
    if Rail then
      Particles.SpawnRailTrail(Muzzle, HitPos)
    else
      Particles.SpawnImpact(HitPos - ShotDir * 2, -ShotDir);
    Exit;
  end;
end;

procedure TQuakeWorld.ThrowHandGrenade(const Fuse: Single);
const
  { Quake 2 weapon_grenade_fire: speed grows with the time the pin was pulled }
  MinSpeed = 400;
  MaxSpeed = 800;
begin
  if FCur.Stats.Ammo[atGrenades] > 0 then
    Dec(FCur.Stats.Ammo[atGrenades]);
  SpawnProjectile(pkHandGrenade, FCur.Pos + FCur.Dir * 16, (FCur.Dir + Vector3(0, 0.1, 0)).Normalize,
    MinSpeed + (GrenadeTimer - Fuse) * (MaxSpeed - MinSpeed) / GrenadeTimer, 125 * DamageMultiplier, True);
  FProjectiles.Last.Life := Max(0.1, Fuse);
  Sounds.Play('sound/weapons/hgrent1a.wav', 1, chWeapon);
end;

procedure TQuakeWorld.ThrowTesla(const Fuse: Single);
const
  MinSpeed = 400;
  MaxSpeed = 800;
var
  Speed: Single;
  Right, Vel: TVector3;
begin
  if FCur.Stats.Ammo[atTesla] > 0 then
    Dec(FCur.Stats.Ammo[atTesla]);
  { weapon_tesla_fire: a grenade's 400 .. 800 by the time it was held,
    from 22 below the eyes; fire_tesla: up 200 (+- 10), a little sideways }
  Speed := EnsureRange(MinSpeed + (GrenadeTimer - Fuse) * (MaxSpeed - MinSpeed) / GrenadeTimer, MinSpeed, MaxSpeed);
  Right := TVector3.CrossProduct(FCur.Dir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Vel := FCur.Dir * Speed + Vector3(0, 200 + (Random * 2 - 1) * 10, 0) + Right * ((Random * 2 - 1) * 10);
  { The damage: TESLA_DAMAGE 3 times the multiplier at the throw }
  SpawnProjectile(pkTesla, FCur.Pos - Vector3(0, 22, 0) - Right * 4, Vel.Normalize, Vel.Length,
    3 * DamageMultiplier, True);
  Sounds.Play('sound/weapons/hgrent1a.wav', 1, chWeapon);
  WritelnLog('QuakeWorld', 'Tesla thrown at %.0f units/s', [Speed]);
end;

procedure TQuakeWorld.ThrowTrap(const Fuse: Single);
const
  { weapon_trap_fire: 300 .. 700 over TRAP_TIMER (5 s), from the time the
    trap was held (the hold timer starts at 3.2 s like a grenade's) }
  TrapTimer = 5.0;
  MinSpeed = 300;
  MaxSpeed = 700;
var
  Speed: Single;
  Right, Vel: TVector3;
begin
  if FCur.Stats.Ammo[atTraps] > 0 then
    Dec(FCur.Stats.Ammo[atTraps]);
  Speed := Min(MinSpeed + (TrapTimer - Fuse) * (MaxSpeed - MinSpeed) / TrapTimer, MaxSpeed);
  { fire_trap: up 200 (+- 10) and a little sideways on top }
  Right := TVector3.CrossProduct(FCur.Dir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Vel := FCur.Dir * Speed + Vector3(0, 200 + (Random * 2 - 1) * 10, 0) + Right * ((Random * 2 - 1) * 10);
  SpawnProjectile(pkTrap, FCur.Pos + FCur.Dir * 8 - Vector3(0, 8, 0), Vel.Normalize, Vel.Length, 0, True);
  WritelnLog('QuakeWorld', 'Trap thrown at %.0f units/s', [Speed]);
end;

procedure TQuakeWorld.UpdateGun(const SecondsPassed: Single);
begin
  if FCur.Dead then
  begin
    FCur.Gun.Attack := False;
    FCur.Gun.AttackLatched := False;
    FCur.FireHeld := False;
    FCur.PrevFireHeld := False;
    Exit;
  end;
  { FireWeapon of the previous frame set FCur.FireHeld }
  FCur.Gun.Attack := FCur.FireHeld;
  FCur.Gun.Update(SecondsPassed);
  FCur.PrevFireHeld := FCur.FireHeld;
  FCur.FireHeld := False;
  FCur.Gun.Attack := False;
end;

function TQuakeWorld.GunAmmo(const Slot: Integer): Integer;
var
  Def: TQuakeWeaponDef;
begin
  Def := WeaponDefs[Slot];
  if (Def.AmmoType = atNone) or (Def.AmmoPerShot <= 0) then
    Result := MaxInt
  else
    Result := FCur.Stats.Ammo[Def.AmmoType] div Def.AmmoPerShot;
end;

procedure TQuakeWorld.NoAmmoWeaponChange;

  function Has(const Slot: Integer; const Ammo: TAmmoType; const Count: Integer): Boolean;
  begin
    Result := ((FCur.Stats.WeaponMask and (1 shl Slot)) <> 0) and (FCur.Stats.Ammo[Ammo] >= Count);
  end;

begin
  { NoAmmoWeaponChange, with The Reckoning's weapons in their chains }
  if Has(9, atSlugs, 1) then
    SelectWeapon(9)
  else
  if Has(PhalanxSlot, atMagSlugs, 1) then
    SelectWeapon(PhalanxSlot)
  else
  if Has(PlasmaBeamSlot, atCells, 2) then
    SelectWeapon(PlasmaBeamSlot)
  else
  if Has(8, atCells, 1) then
    SelectWeapon(8)
  else
  if Has(IonRipperSlot, atCells, 2) then
    SelectWeapon(IonRipperSlot)
  else
  if Has(EtfRifleSlot, atFlechettes, 1) then
    SelectWeapon(EtfRifleSlot)
  else
  if Has(5, atBullets, 1) then
    SelectWeapon(5)
  else
  if Has(4, atBullets, 1) then
    SelectWeapon(4)
  else
  if Has(3, atShells, 2) then
    SelectWeapon(3)
  else
  if Has(2, atShells, 1) then
    SelectWeapon(2)
  else
    SelectWeapon(1);
end;

function TQuakeWorld.SilencedVolume: Single;
begin
  if FCur.Stats.SilencerShots > 0 then
    Result := 0.2
  else
    Result := 1;
end;

procedure TQuakeWorld.WeaponNoise;
begin
  if FCur.Stats.SilencerShots > 0 then
    Dec(FCur.Stats.SilencerShots)
  else
    PlayerNoise(FCur.Pos);
end;

procedure TQuakeWorld.GunEvent(const Event: TGunEvent);
var
  SavedAttacker: TQuakePlayer;
begin
  { What the gun does now is the current player's doing }
  SavedAttacker := FAttacker;
  FAttacker := FCur;
  try
  case Event of
    geFire: FireGun;
    geBfgFlash:
      begin
        { weapon_bfg_fire frame 9: flash and sound, the ball follows on frame 17 }
        Sounds.Play(WeaponDefs[10].Sound, SilencedVolume, chWeapon);
        Lighting.TriggerMuzzleFlash(FCur.Pos + FCur.Dir * 16);
        FCur.LastFireTime := FTime;
        WeaponNoise;
      end;
    geNoAmmo:
      begin
        Sounds.Play('sound/weapons/noammo.wav', 1, chVoice);
        if FHud <> nil then
          FHud.ShowMessage('No ammo for ' + WeaponDefs[FCur.Gun.Slot].Name, 1.5);
        NoAmmoWeaponChange;
      end;
    geChangeWeapon:
      begin
        if FCur.Gun.PendingSlot <> 0 then
          FCur.Stats.CurrentWeapon := FCur.Gun.PendingSlot;
        UpdateWeaponModel;
      end;
    geGrenadePin:
      if FCur.Gun.Slot = TrapSlot then
        Sounds.Play('sound/weapons/trapcock.wav', 1, chWeapon)
      else
        Sounds.Play('sound/weapons/hgrena1b.wav', 1, chWeapon);
    geGrenadeThrow:
      if FCur.Gun.Slot = TrapSlot then
        ThrowTrap(FCur.Gun.Fuse)
      else
      if FCur.Gun.Slot = TeslaSlot then
        ThrowTesla(FCur.Gun.Fuse)
      else
        ThrowHandGrenade(FCur.Gun.Fuse);
    geGrenadeBlowUp:
      begin
        { Held too long: it goes off in the hand }
        if FCur.Stats.Ammo[atGrenades] > 0 then
          Dec(FCur.Stats.Ammo[atGrenades]);
        Explode(FCur.Pos + FCur.Dir * 16, 125 * DamageMultiplier, 165, True);
      end;
    geChaingunUp: Sounds.Play('sound/weapons/chngnu1a.wav');
    geChaingunDown: Sounds.Play('sound/weapons/chngnd1a.wav');
    geHyperBlasterDown: Sounds.Play('sound/weapons/hyprbd1a.wav');
  end;
  finally
    FAttacker := SavedAttacker;
  end;
end;

function TQuakeWorld.ChainedWeapon(const Slot: Integer): Integer;
var
  Chain: array of Integer;
  I, Cur: Integer;

  function Owned(const S: Integer): Boolean;
  begin
    Result := (FCur.Stats.WeaponMask and (1 shl S)) <> 0;
  end;

begin
  { The items' chains (the blaster and the chainfist, the machinegun and
    the ETF rifle, the grenade launcher and the prox launcher, the
    hyperblaster, ion ripper and plasma beam, the railgun and the phalanx,
    grenades and traps): with one of the chain up, the key picks the next
    owned one; otherwise the first owned one }
  case Slot of
    1: Chain := [1, ChainfistSlot];
    4: Chain := [4, EtfRifleSlot];
    6: Chain := [6, ProxLauncherSlot];
    8: Chain := [8, IonRipperSlot, PlasmaBeamSlot];
    9: Chain := [9, PhalanxSlot];
    HandGrenadeSlot: Chain := [HandGrenadeSlot, TrapSlot, TeslaSlot];
    else Exit(Slot);
  end;
  Result := Slot;
  Cur := -1;
  for I := 0 to High(Chain) do
    if Chain[I] = FCur.Stats.CurrentWeapon then
      Cur := I;
  if Cur >= 0 then
  begin
    for I := 1 to High(Chain) do
      if Owned(Chain[(Cur + I) mod Length(Chain)]) then
        Exit(Chain[(Cur + I) mod Length(Chain)]);
    Exit(FCur.Stats.CurrentWeapon);
  end;
  for I := 0 to High(Chain) do
    if Owned(Chain[I]) then
      Exit(Chain[I]);
end;

procedure TQuakeWorld.SelectWeapon(const Slot: Integer);
begin
  if (Slot < 1) or (Slot > WeaponSlots) or ((FCur.Stats.WeaponMask and (1 shl Slot)) = 0) then
    Exit;
  if Slot = FCur.Stats.CurrentWeapon then
    Exit;
  { Put the current weapon away, then raise this one (Quake 2 newweapon) }
  FCur.Gun.Select(Slot);
end;

procedure TQuakeWorld.FireWeapon(const Origin, Dir: TVector3);
begin
  FCur.Pos := Origin;
  FCur.Dir := Dir;
  if FCur.Dead then
    FCur.LatchedAttack := True;
  if (FBsp = nil) or FCur.Dead then
    Exit;
  { A new press is latched (a short tap still fires) and thinks at once }
  if not FCur.FireHeld and not FCur.PrevFireHeld then
    FCur.Gun.AttackLatched := True;
  FCur.FireHeld := True;
  FCur.Gun.Attack := True;
  FCur.Gun.Update(0);
  FCur.Gun.Attack := False;
end;

procedure TQuakeWorld.FireGun;
var
  Def: TQuakeWeaponDef;
  I, Mult, Slot, Shots: Integer;
  Origin, Dir, MuzzlePos, Right, Up: TVector3;
  Angle: Single;
begin
  Origin := FCur.Pos;
  Dir := FCur.Dir;
  Slot := FCur.Gun.Slot;
  Def := WeaponDefs[Slot];
  Shots := 1;
  if Slot = 5 then
    Shots := FCur.Gun.Shots;
  { weapon_phalanx_fire: one mag slug for both balls, taken on frame 8 }
  if (Slot = PhalanxSlot) and (FCur.Gun.Frame <> 8) then
    Shots := 0;
  if Def.AmmoType <> atNone then
    FCur.Stats.Ammo[Def.AmmoType] := Max(0, FCur.Stats.Ammo[Def.AmmoType] - Def.AmmoPerShot * Shots);

  if IsLocal then
    FWeaponKick := 1.0;
  Mult := DamageMultiplier;
  MuzzlePos := Origin + Dir * 16;
  if Slot <> 10 then { the BFG flashed on frame 9 }
  begin
    Lighting.TriggerMuzzleFlash(MuzzlePos);
    { MZ_SILENCED: the muzzle flash sound at 0.2 volume }
    if Slot in [4, 5] then
      Sounds.Play(Format('sound/weapons/machgf%db.wav', [1 + Random(5)]), SilencedVolume, chWeapon)
    else
      Sounds.Play(Def.Sound, SilencedVolume, chWeapon);
  end;
  if Mult = 2 then
    Sounds.Play('sound/misc/ddamage3.wav', 1, chItem)
  else
  if Mult > 1 then
    Sounds.Play('sound/items/damage3.wav', 1, chItem);

  { Firing makes noise (PNOISE_WEAPON) and shows the player hostile }
  FCur.LastFireTime := FTime;
  WeaponNoise;

  case Slot of
    1: SpawnProjectile(pkBlasterBolt, MuzzlePos, Dir, 1000, 15 * Mult, True);
    2: for I := 1 to 12 do
         FireHitscan(Origin, Dir, 4 * Mult, 500, 500);
    3: for I := 1 to 20 do
         FireHitscan(Origin, Dir, 6 * Mult, 1000, 500);
    4: FireHitscan(Origin, Dir, 8 * Mult, 300, 500);
    { Chaingun_Fire: 1, then 2, then 3 bullets a frame as it spins up }
    5: for I := 1 to Shots do
         FireHitscan(Origin, Dir, 6 * Mult, 300, 500);
    6: SpawnProjectile(pkGrenade, MuzzlePos, (Dir + Vector3(0, 0.15, 0)).Normalize, 600, 120 * Mult, True);
    7: SpawnProjectile(pkRocket, MuzzlePos, Dir, 650, 100 * Mult, True);
    8:
      begin
        { Weapon_HyperBlaster_Fire: the bolt origin circles the muzzle }
        Angle := (FCur.Gun.Frame - 5) * 2 * Pi / 6;
        Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
        if Right.IsZero then
          Right := Vector3(1, 0, 0);
        Right := Right.Normalize;
        Up := TVector3.CrossProduct(Right, Dir).Normalize;
        SpawnProjectile(pkBlasterBolt, MuzzlePos - Dir * (4 * Sin(Angle)) + Up * (4 * Cos(Angle)),
          Dir, 1000, 15 * Mult, True);
      end;
    9: FireHitscan(Origin, Dir, 100 * Mult, 0, 0, True);
    10: SpawnProjectile(pkBfg, MuzzlePos, Dir, 400, 200 * Mult, True);
    { weapon_ionripper_fire: 50, speed 500, the yaw off by up to a degree }
    IonRipperSlot:
      SpawnProjectile(pkRipper, MuzzlePos, YawTurned(Dir, Random * 2 - 1), 500, 50 * Mult, True);
    { weapon_phalanx_fire: 70..79 at 725, 1.5 degrees to the left on frame
      7 with a 120 splash, to the right on frame 8 with 30 (radius 120) }
    ChainfistSlot:
      ChainfistHit(Origin, Dir, 15 * Mult);
    { weapon_etf_rifle_fire: flechettes of 10 at 750 from the right barrel
      on frame 6, the left on 7 }
    EtfRifleSlot:
      begin
        Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
        if Right.IsZero then
          Right := Vector3(1, 0, 0);
        Right := Right.Normalize;
        if FCur.Gun.Frame = 7 then
          SpawnProjectile(pkFlechette, Origin + Dir * 15 + Right * 8 - Vector3(0, 8, 0), Dir, 750, 10 * Mult, True)
        else
          SpawnProjectile(pkFlechette, Origin + Dir * 15 + Right * 6 - Vector3(0, 8, 0), Dir, 750, 10 * Mult, True);
      end;
    { weapon_grenadelauncher_fire with prox: 600 ahead, 200 up }
    ProxLauncherSlot:
      begin
        Right := Dir * 600 + Vector3(0, 200 + Random * 10, 0);
        SpawnProjectile(pkProx, MuzzlePos, Right.Normalize, Right.Length, 90 * Mult, True);
      end;
    PlasmaBeamSlot:
      PlasmaBeam(Origin, Dir, 15 * Mult);
    PhalanxSlot:
      begin
        if FCur.Gun.Frame = 8 then
          SpawnProjectile(pkPlasma, MuzzlePos, YawTurned(Dir, -1.5), 725, (70 + Random(10)) * Mult, True)
        else
          SpawnProjectile(pkPlasma, MuzzlePos, YawTurned(Dir, 1.5), 725, (70 + Random(10)) * Mult, True);
        FProjectiles.Last.SplashRadius := 120;
        if FCur.Gun.Frame = 8 then
          FProjectiles.Last.SplashDamage := 30 * Mult
        else
          FProjectiles.Last.SplashDamage := 120 * Mult;
      end;
  end;
end;

procedure TQuakeWorld.ChainfistHit(const Origin, Dir: TVector3; const Damage: Integer);
var
  T: TQuakeTrace;
  HitPos: TVector3;
begin
  { chainfist_fire / fire_player_melee: a trace of 64 (CHAINFIST_REACH);
    a hit pushes the player forward and up 75; walls get sparks }
  T := WorldTrace(CgeToQuake(Origin), CgeToQuake(Origin + Dir * 64), TVector3.Zero, TVector3.Zero,
    MASK_SHOT, FCur.PM);
  if not T.Hit then
    Exit;
  HitPos := QuakeToCge(T.EndPos);
  if (T.Ent is TQuakeMonster) or (T.Ent is TQuakePMove) then
  begin
    if T.Ent is TQuakeMonster then
      TQuakeMonster(T.Ent).TakeDamage(Damage)
    else
      DamagePlayerHit(T.Ent, Damage, Origin);
    Particles.SpawnBlood(HitPos, -Dir);
    if FCur.PM <> nil then
      FCur.PM.AddVelocity(Vector3(Dir.X, 0, Dir.Z) * 75 + Vector3(0, 75, 0));
  end else
  begin
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Damage)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Damage);
    Particles.SpawnImpact(HitPos - Dir * 2, -Dir);
  end;
end;

procedure TQuakeWorld.PlasmaBeam(const Origin, Dir: TVector3; const Damage: Integer);
var
  T: TQuakeTrace;
  Start, Stop: TVector3;
  Dmg: Integer;
  Right, Muzzle, HitPos: TVector3;
begin
  { fire_heatbeam: a trace of 8192, half the damage through water (the
    beam goes on), the beam drawn from the gun }
  Dmg := Damage;
  Start := CgeToQuake(Origin);
  Stop := Start + CgeToQuake(Dir) * 8192;
  T := WorldTrace(Start, Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT or 8 or 16 or 32, FCur.PM);
  if T.Hit and ((T.Contents and (8 or 16 or 32)) <> 0) then
  begin
    Dmg := Dmg div 2;
    T := WorldTrace(T.EndPos + CgeToQuake(Dir), Stop, TVector3.Zero, TVector3.Zero, MASK_SHOT, FCur.PM);
  end;
  HitPos := QuakeToCge(T.EndPos);
  Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
  if Right.IsZero then
    Right := Vector3(1, 0, 0);
  Muzzle := Origin + Dir * 7 + Right.Normalize * 2 - Vector3(0, 3, 0);
  Particles.SpawnBeam(Muzzle, HitPos, Vector3(1.0, 0.75, 0.2));
  if not T.Hit then
    Exit;
  if (T.Ent is TQuakeMonster) or (T.Ent is TQuakePMove) then
  begin
    if T.Ent is TQuakeMonster then
      TQuakeMonster(T.Ent).TakeDamage(Dmg)
    else
      DamagePlayerHit(T.Ent, Dmg, Origin);
    Particles.SpawnBlood(HitPos, -Dir);
  end else
  begin
    if T.Ent is TQuakeMover then
      DamageMover(TQuakeMover(T.Ent), Dmg)
    else
    if T.Ent is TQuakeProp then
      DamageProp(TQuakeProp(T.Ent), Dmg);
    { TE_HEATBEAM_STEAM }
    if (T.Contents and CONTENTS_SOLID) <> 0 then
      Particles.SpawnSteam(HitPos - Dir * 2, -Dir, 8, 60, 223);
  end;
end;
