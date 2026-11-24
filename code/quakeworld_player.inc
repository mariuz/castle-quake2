{ The player: damage, death, movement hooks, liquids, falling.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.DamagePlayer(const Amount: Integer; const FromPos: TVector3;
  const NoArmor: Boolean);
var
  Save, Take: Integer;
begin
  { The defender sphere goes after whoever hurt the player (defender_pain) }
  if (FCur.Stats.DefenderTime > 0) and (FCur.DamageSource <> nil) and FCur.DamageSource.IsAlive then
    FDefenderEnemy := FCur.DamageSource;
  if FCur.Dead or FCur.Stats.GodMode or (FCur.Stats.InvulnTime > 0) or (Amount <= 0) then
    Exit;
  Take := Amount;
  { T_Damage: half damage while a defender sphere is out }
  if FCur.Stats.DefenderTime > 0 then
    Take := Max(1, Take div 2);
  { Quake 2 T_Damage: half damage on easy (not in deathmatch) }
  if (GameSkill = 0) and not Deathmatch then
    Take := Max(1, Take div 2);
  { Power armor first, then armor (T_Damage: CheckPowerArmor, CheckArmor) }
  if not NoArmor then
    Take := Take - AbsorbPlayerPowerArmor(Take, FromPos);
  if (not NoArmor) and (FCur.Stats.Armor > 0) and (FCur.Stats.ArmorType > 0) then
  begin
    Save := Min(FCur.Stats.Armor, Ceil(ArmorProtection[FCur.Stats.ArmorType] * Take));
    FCur.Stats.Armor := FCur.Stats.Armor - Save;
    Take := Take - Save;
    if FCur.Stats.Armor <= 0 then
      FCur.Stats.ArmorType := 0;
  end;
  FCur.Stats.Health := FCur.Stats.Health - Take;
  if FHud <> nil then
    FHud.FlashDamage(Amount);
  if FViewPlayer <> nil then
    FViewPlayer.DamageKick(Amount, FromPos, FCur.Stats.Health);

  if FCur.Stats.Health <= 0 then
  begin
    FCur.KillerPos := FromPos;
    FCur.HasKiller := PointsDistance(FromPos, FCur.Pos) > 1;
    KillPlayer;
    Exit;
  end;
  if (FAttacker <> nil) and (FAttacker <> FCur) then
    WritelnLog('QuakeWorld', '%s hurt by %s: %d (health %d)',
      [PlayerName(FCur), PlayerName(FAttacker), Take, FCur.Stats.Health]);

  if FCur.PainSoundTimer <= 0 then
  begin
    FCur.PainSoundTimer := 0.7;
    if FCur.Stats.Health < 25 then
      Sounds.Play('sound/player/male/pain25_1.wav', 1, chVoice)
    else
    if FCur.Stats.Health < 50 then
      Sounds.Play('sound/player/male/pain50_1.wav', 1, chVoice)
    else
    if FCur.Stats.Health < 75 then
      Sounds.Play('sound/player/male/pain75_1.wav', 1, chVoice)
    else
      Sounds.Play('sound/player/male/pain100_1.wav', 1, chVoice);
  end;
end;

procedure TQuakeWorld.KillPlayer;
var
  Pieces: array[0..0] of TGibPiece;
  Org: TVector3;
begin
  FCur.Dead := True;
  FCur.LatchedAttack := False;
  { player_die: respawn_time 1 s in deathmatch }
  if Deathmatch then
    FCur.DeadTimer := 1.0
  else
    FCur.DeadTimer := 3.0;
  { player_die: below -40 health the body is gibbed (4 meat + the head the
    view stays in), else the death sound }
  FCur.Gibbed := FCur.Stats.Health < -40;
  if FCur.Gibbed then
  begin
    Sounds.Play('sound/misc/udeath.wav', 1, chBody);
    Pieces[0].Model := 'models/objects/gibs/sm_meat/tris.md2';
    Pieces[0].Count := 4;
    Pieces[0].Metallic := False;
    Org := FCur.Pos - Vector3(0, PlayerEyeHeight - 24, 0);
    Particles.ThrowGibs(Org + Vector3(-16, -24, -16), Org + Vector3(16, 32, 16), Pieces, -FCur.Stats.Health);
    WritelnLog('QuakeWorld', 'Player gibbed (health %d)', [FCur.Stats.Health]);
  end else
  begin
    Sounds.Play('sound/player/male/death' + IntToStr(1 + Random(4)) + '.wav', 1, chVoice);
    WritelnLog('QuakeWorld', 'Player died (health %d)', [FCur.Stats.Health]);
  end;
  FCur.Stats.Health := Min(FCur.Stats.Health, 0);
  { ps.gunindex = 0: no view weapon while dead }
  if (FWeaponTransform <> nil) and IsLocal then
    FWeaponTransform.Exists := False;
  Obituary(FAttacker);
  FObituaryText := '';
  if (FHud <> nil) and not Deathmatch then
    FHud.ShowMessage('You died. Restarting level...', 3);
end;

function TQuakeWorld.KillerPosition(out Pos: TVector3): Boolean;
begin
  Pos := FCur.KillerPos;
  Result := FCur.Dead and FCur.HasKiller;
end;

procedure TQuakeWorld.Suicide;
var
  Saved: TQuakePlayer;
begin
  if FCur.Dead then
    Exit;
  FCur.Stats.Health := 0;
  FCur.HasKiller := False;
  { MOD_SUICIDE: by oneself }
  Saved := FAttacker;
  FAttacker := FCur;
  try
    KillPlayer;
  finally
    FAttacker := Saved;
  end;
end;

function TQuakeWorld.PlayerTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
begin
  Result := WorldTrace(Start, Stop, Mins, Maxs, Mask, FCur.PM);
end;

procedure TQuakeWorld.PlayerBeforeMove(Sender: TObject);
var
  Org: TVector3;
begin
  if FBsp = nil then
    Exit;
  PushPlayerByMovers;
  { For monster moves: the player's box in CGE space }
  if FCur.Dead then
    PlayerBlockBox := TBox3D.Empty
  else
  begin
    Org := FCur.PM.Origin;
    PlayerBlockBox := QuakeBoxToCge(Org + FCur.PM.BoxMins, Org + FCur.PM.BoxMaxs);
  end;
end;

function TQuakeWorld.PlayerPointContents(const CgePos: TVector3): Integer;
begin
  if FBsp = nil then
    Exit(0);
  { Leaf contents, but the ladder bit only when really inside a ladder brush }
  Result := FBsp.PointContents(CgeToQuake(CgePos)) and not CONTENTS_LADDER;
  if FBsp.PointInLadder(CgeToQuake(CgePos)) then
    Result := Result or CONTENTS_LADDER;
end;

procedure TQuakeWorld.UpdateLiquids(const SecondsPassed: Single);
var
  Level, WType: Integer;
begin
  if (FCur.PM = nil) or FCur.Dead then
    Exit;
  Level := FCur.PM.WaterLevel;
  WType := FCur.PM.WaterType;

  { P_WorldEffects: enter / leave sounds }
  if (FCur.LastWaterLevel = 0) and (Level > 0) then
  begin
    if (WType and CONTENTS_LAVA) <> 0 then
      Sounds.Play('sound/player/lava_in.wav', 1, chBody)
    else
      Sounds.Play('sound/player/watr_in.wav', 1, chBody);
  end else
  if (FCur.LastWaterLevel > 0) and (Level = 0) then
    Sounds.Play('sound/player/watr_out.wav', 1, chBody)
  else
  if (FCur.LastWaterLevel < 3) and (Level = 3) then
    Sounds.Play('sound/player/watr_un.wav', 1, chBody);
  if (FCur.LastWaterLevel = 3) and (Level < 3) and (FCur.AirFinished < FTime + 7) then
    Sounds.Play('sound/player/gasp1.wav', 1, chVoice);

  { Drowning: 12 seconds of air, then 2 damage per second, increasing;
    the rebreather and environment suit give air (P_WorldEffects) }
  if Level < 3 then
    FCur.AirFinished := FTime + 12
  else
  begin
    if (FCur.Stats.BreatherTime > 0) or (FCur.Stats.EnviroTime > 0) then
    begin
      FCur.AirFinished := FTime + 10;
      { u_breath1 / u_breath2 every 2.5 s }
      FCur.BreathTimer := FCur.BreathTimer - SecondsPassed;
      if FCur.BreathTimer <= 0 then
      begin
        FCur.BreathTimer := 2.5;
        FCur.BreathSound := not FCur.BreathSound;
        if FCur.BreathSound then
          Sounds.Play('sound/player/u_breath1.wav', 1, chAuto)
        else
          Sounds.Play('sound/player/u_breath2.wav', 1, chAuto);
        PlayerNoise(FCur.Pos);
      end;
    end;
    if FTime > FCur.AirFinished then
    begin
      FCur.LiquidDamageTimer := FCur.LiquidDamageTimer - SecondsPassed;
      if FCur.LiquidDamageTimer <= 0 then
      begin
        FCur.LiquidDamageTimer := 1;
        DamagePlayer(Min(15, 2 + 2 * Trunc(FTime - FCur.AirFinished)), FCur.Pos, True);
      end;
    end;
  end;

  { Lava: 3 per water level a frame (1 with the environment suit); slime: 1,
    none with the suit }
  if (Level > 0) and ((WType and (CONTENTS_LAVA or CONTENTS_SLIME)) <> 0) then
  begin
    FCur.LiquidDamageTimer := FCur.LiquidDamageTimer - SecondsPassed;
    if FCur.LiquidDamageTimer <= 0 then
    begin
      FCur.LiquidDamageTimer := 0.1;
      if (WType and CONTENTS_LAVA) <> 0 then
      begin
        if FCur.Stats.EnviroTime > 0 then
          DamagePlayer(Level, FCur.Pos)
        else
          DamagePlayer(3 * Level, FCur.Pos);
      end else
      if FCur.Stats.EnviroTime <= 0 then
        DamagePlayer(Level, FCur.Pos);
    end;
  end;

  FCur.LastWaterLevel := Level;
  if FHud <> nil then
  begin
    if Level = 3 then
      FHud.UnderwaterType := WType
    else
      FHud.UnderwaterType := 0;
  end;
end;

procedure TQuakeWorld.PlayerFallDamage(const Damage: Integer);
begin
  if Damage >= 10 then
    Sounds.Play('sound/player/male/fall1.wav', 1, chVoice)
  else
    Sounds.Play('sound/player/male/fall2.wav', 1, chVoice);
  { P_FallingDamage: the fall event still plays, no damage }
  if DMFlag(DF_NO_FALLING) then
    Exit;
  DamagePlayer(Damage, FCur.Pos);
end;

procedure TQuakeWorld.PlayerLanded(Sender: TObject);
begin
  Sounds.Play('sound/player/land1.wav');
end;

procedure TQuakeWorld.TeleportDone;
begin
  FTeleportPending := False;
end;
