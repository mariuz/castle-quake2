{ Items: pickups, inventory, powerups, power armor, cheats.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

function TQuakeWorld.PlayerBox: TBox3D;
var
  Feet: Single;
begin
  Feet := FPlayerPos.Y - PlayerEyeHeight;
  Result := Box3D(
    Vector3(FPlayerPos.X - 16, Feet, FPlayerPos.Z - 16),
    Vector3(FPlayerPos.X + 16, Feet + 56, FPlayerPos.Z + 16));
end;

function TQuakeWorld.GiveItem(const Def: PQuakeItemDef): Boolean;
var
  OldType, Salvage: Integer;
  A: TAmmoType;

  function AddAmmo(const AType: TAmmoType; const Count: Integer): Boolean;
  begin
    Result := FStats.Ammo[AType] < FStats.MaxAmmo[AType];
    FStats.Ammo[AType] := Min(FStats.MaxAmmo[AType], FStats.Ammo[AType] + Count);
  end;

begin
  Result := True;
  case Def^.Category of
    icWeapon:
      begin
        FStats.WeaponMask := FStats.WeaponMask or (1 shl Def^.Weapon);
        AddAmmo(Def^.AmmoType, Def^.Amount);
        { Quake 2 auto-switches away from the blaster }
        if FStats.CurrentWeapon = 1 then
          SelectWeapon(Def^.Weapon);
      end;
    icAmmo:
      begin
        Result := AddAmmo(Def^.AmmoType, Def^.Amount);
        { Grenades are both ammo and the hand grenade weapon }
        if Result and (Def^.Weapon <> 0) then
          FStats.WeaponMask := FStats.WeaponMask or (1 shl Def^.Weapon);
      end;
    icHealth:
      begin
        if (Def^.Param = 0) and (FStats.Health >= FStats.MaxHealth) then
          Exit(False);
        if Def^.Param = 0 then
          FStats.Health := Min(FStats.MaxHealth, FStats.Health + Def^.Amount)
        else
          FStats.Health := Min(250, FStats.Health + Def^.Amount);
      end;
    icArmor:
      begin
        if Def^.Param = 0 then
        begin
          { Shard: +2 of the current type }
          if FStats.ArmorType = 0 then
            FStats.ArmorType := 1;
          FStats.Armor := FStats.Armor + Def^.Amount;
        end else
        begin
          OldType := FStats.ArmorType;
          if OldType = 0 then
          begin
            FStats.ArmorType := Def^.Param;
            FStats.Armor := Def^.Amount;
          end else
          if ArmorProtection[Def^.Param] > ArmorProtection[OldType] then
          begin
            { Upgrade: salvage the old armor at the new protection rate }
            Salvage := Round(FStats.Armor * ArmorProtection[OldType] / ArmorProtection[Def^.Param]);
            FStats.ArmorType := Def^.Param;
            FStats.Armor := Min(ArmorMax[Def^.Param], Def^.Amount + Salvage);
          end else
          begin
            Salvage := Round(Def^.Amount * ArmorProtection[Def^.Param] / ArmorProtection[OldType]);
            if FStats.Armor >= ArmorMax[OldType] then
              Exit(False);
            FStats.Armor := Min(ArmorMax[OldType], FStats.Armor + Salvage);
          end;
        end;
      end;
    icPowerup:
      case Def^.Param of
        POWERUP_QUAD: FStats.QuadTime := FStats.QuadTime + Def^.Amount;
        { Use_QuadFire: 30 s more of DualFire }
        POWERUP_QUADFIRE:
          begin
            FStats.QuadFireTime := FStats.QuadFireTime + Def^.Amount;
            Sounds.Play('sound/items/quadfire1.wav', 1, chItem);
          end;
        POWERUP_INVULN: FStats.InvulnTime := FStats.InvulnTime + Def^.Amount;
        { Ground Zero, used on pickup: Use_Double (30 s), Use_IR (60 s),
          Use_Defender (one sphere at a time: Pickup_Sphere refuses) }
        POWERUP_DOUBLE:
          begin
            FStats.DoubleTime := FStats.DoubleTime + Def^.Amount;
            Sounds.Play('sound/misc/ddamage1.wav', 1, chItem);
          end;
        POWERUP_IR:
          begin
            FStats.IRTime := FStats.IRTime + Def^.Amount;
            Sounds.Play('sound/misc/ir_start.wav', 1, chItem);
          end;
        POWERUP_DEFENDER:
          begin
            if FStats.DefenderTime > 0 then
              Exit(False);
            FStats.DefenderTime := Def^.Amount;
            FDefenderEnemy := nil;
            WritelnLog('QuakeWorld', 'Defender sphere out');
          end;
        { Used on pickup here (Quake 2 single player keeps them in the
          inventory until used): Use_Breather, Use_Envirosuit, Use_Silencer }
        POWERUP_OTHER:
          if Def^.ClassName = 'item_breather' then
            FStats.BreatherTime := FStats.BreatherTime + 30
          else
          if Def^.ClassName = 'item_enviro' then
            FStats.EnviroTime := FStats.EnviroTime + 30
          else
          if Def^.ClassName = 'item_silencer' then
            Inc(FStats.SilencerShots, 30)
          else
          if (Def^.ClassName = 'item_power_screen') or (Def^.ClassName = 'item_power_shield') then
          begin
            if Def^.ClassName = 'item_power_screen' then
              Inc(FStats.PowerScreens)
            else
              Inc(FStats.PowerShields);
            { Switched on with the first one, like Quake 2 deathmatch's
              auto-use; the powerarmor command switches it }
            if not FStats.PowerArmorOn then
              TogglePowerArmor;
          end;
        POWERUP_ADRENALINE:
          begin
            Inc(FStats.MaxHealth);
            FStats.Health := Max(FStats.Health, FStats.MaxHealth);
          end;
        POWERUP_ANCIENT_HEAD:
          Inc(FStats.MaxHealth, 2);
        POWERUP_BANDOLIER, POWERUP_PACK:
          begin
            if Def^.Param = POWERUP_PACK then
            begin
              FStats.MaxAmmo[atShells] := Max(FStats.MaxAmmo[atShells], 200);
              FStats.MaxAmmo[atBullets] := Max(FStats.MaxAmmo[atBullets], 300);
              FStats.MaxAmmo[atGrenades] := Max(FStats.MaxAmmo[atGrenades], 100);
              FStats.MaxAmmo[atRockets] := Max(FStats.MaxAmmo[atRockets], 100);
              FStats.MaxAmmo[atCells] := Max(FStats.MaxAmmo[atCells], 300);
              FStats.MaxAmmo[atSlugs] := Max(FStats.MaxAmmo[atSlugs], 100);
              FStats.MaxAmmo[atMagSlugs] := Max(FStats.MaxAmmo[atMagSlugs], 100);
              FStats.MaxAmmo[atFlechettes] := Max(FStats.MaxAmmo[atFlechettes], 300);
              AddAmmo(atMagSlugs, 10);
              AddAmmo(atFlechettes, 50);
            end else
            begin
              FStats.MaxAmmo[atShells] := Max(FStats.MaxAmmo[atShells], 150);
              FStats.MaxAmmo[atBullets] := Max(FStats.MaxAmmo[atBullets], 250);
              FStats.MaxAmmo[atCells] := Max(FStats.MaxAmmo[atCells], 250);
              FStats.MaxAmmo[atSlugs] := Max(FStats.MaxAmmo[atSlugs], 75);
              FStats.MaxAmmo[atMagSlugs] := Max(FStats.MaxAmmo[atMagSlugs], 75);
              FStats.MaxAmmo[atFlechettes] := Max(FStats.MaxAmmo[atFlechettes], 250);
            end;
            for A := atShells to atSlugs do
              AddAmmo(A, 10);
          end;
      end;
    icKey:
      FStats.Keys := FStats.Keys or Cardinal(Def^.Amount);
  end;
end;

procedure TQuakeWorld.CheckPickups;
var
  P: TQuakePickup;
  Delta: TVector3;
  Amount: Integer;
begin
  for P in FPickups do
  begin
    if P.Collected then
      Continue;
    Delta := P.Origin - FPlayerPos;
    if (Sqr(Delta.X) + Sqr(Delta.Z) < Sqr(40)) and (Delta.Y > -PlayerEyeHeight - 20) and (Delta.Y < 20) then
    begin
      if P.Def^.ClassName = 'item_foodcube' then
      begin
        { A trap's food cube: its count in health, over the maximum
          (HEALTH_IGNORE_MAX), the sound by the amount }
        Amount := Max(1, P.Entity.GetInt('count', 2));
        FStats.Health := FStats.Health + Amount;
        P.Collected := True;
        if Amount < 10 then
          Sounds.Play('sound/items/s_health.wav', 1, chItem)
        else
        if Amount < 25 then
          Sounds.Play('sound/items/n_health.wav', 1, chItem)
        else
        if Amount < 50 then
          Sounds.Play('sound/items/l_health.wav', 1, chItem)
        else
          Sounds.Play('sound/items/m_health.wav', 1, chItem);
        if FHud <> nil then
          FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
        WritelnLog('QuakeWorld', 'Food cube: %d health', [Amount]);
        Continue;
      end;
      if not GiveItem(P.Def) then
        Continue;
      P.Collected := True;
      Sounds.Play(P.Def^.Sound, 1, chItem);
      if FHud <> nil then
        FHud.ShowPickup(P.Def^.Icon, P.Def^.Name);
      { Picked items can fire targets too }
      UseTargets(P.Entity.Target, P.Entity);
    end;
  end;
end;

procedure TQuakeWorld.DropMonsterItem(const M: TQuakeMonster);
var
  CName: String;
  Ent: TQuakeEntity;
  Org: TVector3;
begin
  CName := LowerCase(M.Entity.GetField('item'));
  if FindItemDef(CName) = nil then
  begin
    WritelnLog('QuakeWorld', '%s: item "%s" unknown, not dropped', [M.Transform.Name, CName]);
    Exit;
  end;
  { A new entity (no targets of its own), where the monster died, resting
    like map items (origin 15 above the floor; a monster's is 24) }
  Org := M.Origin - Vector3(0, 0, 9);
  Ent := TQuakeEntity.Create;
  Ent.SetField('classname', CName);
  Ent.SetField('origin', Format('%d %d %d', [Round(Org.X), Round(Org.Y), Round(Org.Z)]));
  FBsp.Entities.Add(Ent);
  SpawnEntity(Ent);
  WritelnLog('QuakeWorld', '%s dropped %s', [M.Transform.Name, CName]);
end;

procedure TQuakeWorld.RemoveDefender(const WithExplosion: Boolean);
begin
  if FDefender = nil then
    Exit;
  { sphere_think_explode: BecomeExplosion1 }
  if WithExplosion then
    TempEntity(TE_EXPLOSION1, FDefender.Translation);
  FreeAndNil(FDefenderModel);
  FreeAndNil(FDefenderShell);
  FreeAndNil(FDefender);
  FDefenderEnemy := nil;
end;

procedure TQuakeWorld.UpdateDefender(const SecondsPassed: Single);
var
  Goal, Dir: TVector3;
begin
  if (FStats.DefenderTime <= 0) or FDead then
  begin
    if FDefender <> nil then
      WritelnLog('QuakeWorld', 'Defender sphere gone');
    RemoveDefender(FDefender <> nil);
    FStats.DefenderTime := 0;
    Exit;
  end;
  FStats.DefenderTime := Max(0, FStats.DefenderTime - SecondsPassed);
  { Above the player's head (4 over the top of the box) }
  Goal := FPlayerPos + Vector3(0, 32 - 22 + 4, 0);
  if FDefender = nil then
  begin
    FDefender := TCastleTransform.Create(nil);
    FDefender.Name := 'DefenderSphere';
    FDefender.Translation := Goal;
    FDefenderModel := Md2Manager.CreateInstance('models/items/defender/tris.md2');
    if FDefenderModel <> nil then
    begin
      FDefenderModel.Scene.Collides := False;
      FDefenderModel.Scene.Pickable := False;
      FDefender.Add(FDefenderModel.Scene);
    end;
    FDefenderShell := Md2Manager.CreateInstance('models/items/shell/tris.md2');
    if FDefenderShell <> nil then
    begin
      FDefenderShell.Scene.Collides := False;
      FDefenderShell.Scene.Pickable := False;
      FDefender.Add(FDefenderShell.Scene);
    end;
    FItems.Add(FDefender);
  end;
  { defender_think: 5 times the way there a second; RF_FULLBRIGHT }
  FDefender.Translation := FDefender.Translation + (Goal - FDefender.Translation) * Min(1, 5 * SecondsPassed);
  FDefender.Rotation := Vector4(0, 1, 0, FTime * 2);
  if FDefenderModel <> nil then
    FDefenderModel.SetTint(Vector3(1.5, 1.5, 1.5));
  { Every 0.1 s: a bolt of 10 at 1000 at its enemy while it is alive and in
    sight, 0.4 s apart }
  FDefenderCooldown := FDefenderCooldown - SecondsPassed;
  FDefenderThink := FDefenderThink - SecondsPassed;
  if FDefenderThink > 0 then
    Exit;
  FDefenderThink := 0.1;
  if (FDefenderEnemy <> nil) and ((not FDefenderEnemy.IsAlive) or FDefenderEnemy.Dormant) then
    FDefenderEnemy := nil;
  if (FDefenderEnemy = nil) or (FDefenderCooldown > 0) then
    Exit;
  if not HintPointsVisible(FDefender.Translation, FDefenderEnemy.EyePos) then
    Exit;
  Dir := (FDefenderEnemy.Transform.Translation - FDefender.Translation).Normalize;
  SpawnProjectile(pkBlasterBolt, FDefender.Translation + Vector3(0, 2, 0), Dir, 1000, 10, True);
  Sounds.PlayAt('sound/weapons/laser2.wav', FDefender, 1, 1, chWeapon);
  FDefenderCooldown := 0.4;
  WritelnLog('QuakeWorld', 'Defender sphere fires at %s', [FDefenderEnemy.Transform.Name]);
end;

function TQuakeWorld.DamageMultiplier: Integer;
begin
  { P_DamageModifier: quad 4, else double damage 2 }
  if FStats.QuadTime > 0 then
    Result := 4
  else
  if FStats.DoubleTime > 0 then
    Result := 2
  else
    Result := 1;
end;

procedure TQuakeWorld.UpdatePlayerItems(const SecondsPassed: Single);

  { airout.wav as 3 seconds are left (remaining == 30 frames) }
  procedure Tick(var Time: Single);
  begin
    if Time <= 0 then
      Exit;
    if (Time > 3) and (Time - SecondsPassed <= 3) then
      Sounds.Play('sound/items/airout.wav', 1, chItem);
    Time := Max(0, Time - SecondsPassed);
  end;

begin
  Tick(FStats.EnviroTime);
  Tick(FStats.BreatherTime);
  { G_SetStats: power armor goes off when the cells run out }
  if FStats.PowerArmorOn and (FStats.Ammo[atCells] <= 0) then
  begin
    FStats.PowerArmorOn := False;
    Sounds.Play('sound/misc/power2.wav', 1, chItem);
  end;
end;

function TQuakeWorld.AbsorbPlayerPowerArmor(const Damage: Integer; const FromPos: TVector3): Integer;
var
  Forward, ToHit: TVector3;
  DamagePerCell, Part, Cells: Integer;
begin
  { Quake 2 CheckPowerArmor for a client: the shield if carried, else the
    screen, which only stops hits from the front; cells pay for it }
  Result := 0;
  Cells := FStats.Ammo[atCells];
  if not FStats.PowerArmorOn or (Cells <= 0) or (Damage <= 0) then
    Exit;
  if FStats.PowerShields > 0 then
  begin
    DamagePerCell := 2;
    Part := (2 * Damage) div 3;
  end else
  if FStats.PowerScreens > 0 then
  begin
    Forward := Vector3(FPlayerDir.X, 0, FPlayerDir.Z);
    ToHit := FromPos - FPlayerPos;
    ToHit.Y := 0;
    if Forward.IsZero or ToHit.IsZero or
       (TVector3.DotProduct(ToHit.Normalize, Forward.Normalize) <= 0.3) then
      Exit;
    DamagePerCell := 1;
    Part := Damage div 3;
  end else
    Exit;
  Result := Min(Cells * DamagePerCell, Part);
  if Result <= 0 then
    Exit;
  FStats.Ammo[atCells] := Max(0, Cells - Result div DamagePerCell);
  { TE_SCREEN_SPARKS / TE_SHIELD_SPARKS }
  Sounds.Play('sound/weapons/lashit.wav', 1, chAuto);
end;

procedure TQuakeWorld.TogglePowerArmor;
begin
  if (FStats.PowerScreens = 0) and (FStats.PowerShields = 0) then
    Exit;
  if FStats.PowerArmorOn then
  begin
    FStats.PowerArmorOn := False;
    Sounds.Play('sound/misc/power2.wav', 1, chAuto);
  end else
  if FStats.Ammo[atCells] <= 0 then
  begin
    if FHud <> nil then
      FHud.ShowMessage('No cells for power armor.', 2);
  end else
  begin
    FStats.PowerArmorOn := True;
    Sounds.Play('sound/misc/power1.wav', 1, chAuto);
  end;
end;

procedure TQuakeWorld.CheatGiveAll;
var
  A: TAmmoType;
  I: Integer;
begin
  FStats.WeaponMask := ((1 shl (HandGrenadeSlot + 1)) - 1) and not 1; { slots 1..11 }
  for A := atShells to atSlugs do
    FStats.Ammo[A] := FStats.MaxAmmo[A];
  { The Reckoning's weapons when their models are there (-game xatrix) }
  { and Ground Zero's (-game rogue) }
  for I := IonRipperSlot to TeslaSlot do
    if Pak.FileExists(WeaponDefs[I].ViewModel) then
    begin
      FStats.WeaponMask := FStats.WeaponMask or (1 shl I);
      if WeaponDefs[I].AmmoType <> atNone then
        FStats.Ammo[WeaponDefs[I].AmmoType] := FStats.MaxAmmo[WeaponDefs[I].AmmoType];
    end;
  FStats.ArmorType := 3;
  FStats.Armor := 200;
  FStats.Health := Max(FStats.Health, 100);
  FStats.Keys := $1FF;
  if FHud <> nil then
    FHud.ShowMessage('All weapons, ammo, armor and keys');
end;

function TQuakeWorld.CheatGiveItem(const AName: String): Boolean;
var
  I: Integer;
begin
  for I := Low(ItemDefs) to High(ItemDefs) do
    if SameText(ItemDefs[I].Name, AName) or SameText(ItemDefs[I].ClassName, AName) then
    begin
      Result := GiveItem(@ItemDefs[I]);
      if Result and (FHud <> nil) then
        FHud.ShowMessage(ItemDefs[I].Name, 2);
      Exit(True);
    end;
  Result := False;
end;

procedure TQuakeWorld.CheatPowerup(const Quad: Boolean);
begin
  if Quad then
    GiveItem(FindItemDef('item_quad'))
  else
    GiveItem(FindItemDef('item_invulnerability'));
end;

procedure TQuakeWorld.CheatGodMode;
begin
  FStats.GodMode := not FStats.GodMode;
  if FHud <> nil then
    if FStats.GodMode then
      FHud.ShowMessage('god ON')
    else
      FHud.ShowMessage('god OFF');
end;
