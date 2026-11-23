{ The player: damage, death, movement hooks, liquids, falling.
  Part of the implementation of TQuakeWorld (unit QuakeWorld). }

procedure TQuakeWorld.DamagePlayer(const Amount: Integer; const FromPos: TVector3;
  const NoArmor: Boolean);
var
  Save, Take: Integer;
begin
  { The defender sphere goes after whoever hurt the player (defender_pain) }
  if (FStats.DefenderTime > 0) and (FDamageSource <> nil) and FDamageSource.IsAlive then
    FDefenderEnemy := FDamageSource;
  if FDead or FStats.GodMode or (FStats.InvulnTime > 0) or (Amount <= 0) then
    Exit;
  Take := Amount;
  { T_Damage: half damage while a defender sphere is out }
  if FStats.DefenderTime > 0 then
    Take := Max(1, Take div 2);
  { Quake 2 T_Damage: half damage on easy }
  if GameSkill = 0 then
    Take := Max(1, Take div 2);
  { Power armor first, then armor (T_Damage: CheckPowerArmor, CheckArmor) }
  if not NoArmor then
    Take := Take - AbsorbPlayerPowerArmor(Take, FromPos);
  if (not NoArmor) and (FStats.Armor > 0) and (FStats.ArmorType > 0) then
  begin
    Save := Min(FStats.Armor, Ceil(ArmorProtection[FStats.ArmorType] * Take));
    FStats.Armor := FStats.Armor - Save;
    Take := Take - Save;
    if FStats.Armor <= 0 then
      FStats.ArmorType := 0;
  end;
  FStats.Health := FStats.Health - Take;
  if FHud <> nil then
    FHud.FlashDamage(Amount);
  if FViewPlayer <> nil then
    FViewPlayer.DamageKick(Amount, FromPos, FStats.Health);

  if FStats.Health <= 0 then
  begin
    FKillerPos := FromPos;
    FHasKiller := PointsDistance(FromPos, FPlayerPos) > 1;
    KillPlayer;
    Exit;
  end;

  if FPainSoundTimer <= 0 then
  begin
    FPainSoundTimer := 0.7;
    if FStats.Health < 25 then
      Sounds.Play('sound/player/male/pain25_1.wav', 1, chVoice)
    else
    if FStats.Health < 50 then
      Sounds.Play('sound/player/male/pain50_1.wav', 1, chVoice)
    else
    if FStats.Health < 75 then
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
  FDead := True;
  FDeadTimer := 3.0;
  { player_die: below -40 health the body is gibbed (4 meat + the head the
    view stays in), else the death sound }
  FPlayerGibbed := FStats.Health < -40;
  if FPlayerGibbed then
  begin
    Sounds.Play('sound/misc/udeath.wav', 1, chBody);
    Pieces[0].Model := 'models/objects/gibs/sm_meat/tris.md2';
    Pieces[0].Count := 4;
    Pieces[0].Metallic := False;
    Org := FPlayerPos - Vector3(0, PlayerEyeHeight - 24, 0);
    Particles.ThrowGibs(Org + Vector3(-16, -24, -16), Org + Vector3(16, 32, 16), Pieces, -FStats.Health);
    WritelnLog('QuakeWorld', 'Player gibbed (health %d)', [FStats.Health]);
  end else
  begin
    Sounds.Play('sound/player/male/death' + IntToStr(1 + Random(4)) + '.wav', 1, chVoice);
    WritelnLog('QuakeWorld', 'Player died (health %d)', [FStats.Health]);
  end;
  FStats.Health := Min(FStats.Health, 0);
  { ps.gunindex = 0: no view weapon while dead }
  if FWeaponTransform <> nil then
    FWeaponTransform.Exists := False;
  if FHud <> nil then
    FHud.ShowMessage('You died. Restarting level...', 3);
end;

function TQuakeWorld.KillerPosition(out Pos: TVector3): Boolean;
begin
  Pos := FKillerPos;
  Result := FDead and FHasKiller;
end;

procedure TQuakeWorld.Suicide;
begin
  if FDead then
    Exit;
  FStats.Health := 0;
  FHasKiller := False;
  KillPlayer;
end;

function TQuakeWorld.PlayerTrace(const Start, Stop, Mins, Maxs: TVector3; const Mask: Integer): TQuakeTrace;
begin
  Result := WorldTrace(Start, Stop, Mins, Maxs, Mask, FPlayer);
end;

procedure TQuakeWorld.PlayerBeforeMove(Sender: TObject);
var
  Org: TVector3;
begin
  if FBsp = nil then
    Exit;
  PushPlayerByMovers;
  { For monster moves: the player's box in CGE space }
  if FDead then
    PlayerBlockBox := TBox3D.Empty
  else
  begin
    Org := FPlayer.Origin;
    PlayerBlockBox := QuakeBoxToCge(Org + FPlayer.BoxMins, Org + FPlayer.BoxMaxs);
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
  if (FPlayer = nil) or FDead then
    Exit;
  Level := FPlayer.WaterLevel;
  WType := FPlayer.WaterType;

  { P_WorldEffects: enter / leave sounds }
  if (FLastWaterLevel = 0) and (Level > 0) then
  begin
    if (WType and CONTENTS_LAVA) <> 0 then
      Sounds.Play('sound/player/lava_in.wav', 1, chBody)
    else
      Sounds.Play('sound/player/watr_in.wav', 1, chBody);
  end else
  if (FLastWaterLevel > 0) and (Level = 0) then
    Sounds.Play('sound/player/watr_out.wav', 1, chBody)
  else
  if (FLastWaterLevel < 3) and (Level = 3) then
    Sounds.Play('sound/player/watr_un.wav', 1, chBody);
  if (FLastWaterLevel = 3) and (Level < 3) and (FAirFinished < FTime + 7) then
    Sounds.Play('sound/player/gasp1.wav', 1, chVoice);

  { Drowning: 12 seconds of air, then 2 damage per second, increasing;
    the rebreather and environment suit give air (P_WorldEffects) }
  if Level < 3 then
    FAirFinished := FTime + 12
  else
  begin
    if (FStats.BreatherTime > 0) or (FStats.EnviroTime > 0) then
    begin
      FAirFinished := FTime + 10;
      { u_breath1 / u_breath2 every 2.5 s }
      FBreathTimer := FBreathTimer - SecondsPassed;
      if FBreathTimer <= 0 then
      begin
        FBreathTimer := 2.5;
        FBreathSound := not FBreathSound;
        if FBreathSound then
          Sounds.Play('sound/player/u_breath1.wav', 1, chAuto)
        else
          Sounds.Play('sound/player/u_breath2.wav', 1, chAuto);
        PlayerNoise(FPlayerPos);
      end;
    end;
    if FTime > FAirFinished then
    begin
      FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
      if FLiquidDamageTimer <= 0 then
      begin
        FLiquidDamageTimer := 1;
        DamagePlayer(Min(15, 2 + 2 * Trunc(FTime - FAirFinished)), FPlayerPos, True);
      end;
    end;
  end;

  { Lava: 3 per water level a frame (1 with the environment suit); slime: 1,
    none with the suit }
  if (Level > 0) and ((WType and (CONTENTS_LAVA or CONTENTS_SLIME)) <> 0) then
  begin
    FLiquidDamageTimer := FLiquidDamageTimer - SecondsPassed;
    if FLiquidDamageTimer <= 0 then
    begin
      FLiquidDamageTimer := 0.1;
      if (WType and CONTENTS_LAVA) <> 0 then
      begin
        if FStats.EnviroTime > 0 then
          DamagePlayer(Level, FPlayerPos)
        else
          DamagePlayer(3 * Level, FPlayerPos);
      end else
      if FStats.EnviroTime <= 0 then
        DamagePlayer(Level, FPlayerPos);
    end;
  end;

  FLastWaterLevel := Level;
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
  DamagePlayer(Damage, FPlayerPos);
end;

procedure TQuakeWorld.PlayerLanded(Sender: TObject);
begin
  Sounds.Play('sound/player/land1.wav');
end;

procedure TQuakeWorld.TeleportDone;
begin
  FTeleportPending := False;
end;
