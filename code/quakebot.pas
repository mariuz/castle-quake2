{ Deathmatch bots (roadmap E.3). }
unit QuakeBot;

{ A TQuakeBot plays a player like a person at a client would: each frame it
  looks at the server's world from its player's eye (sight lines through
  TQuakeWorld.WorldTrace, the items it can see), then decides a usercmd:
  forward / side moves, a jump, the view's yaw and pitch, fire, and weapon
  changes. The view sends that through a test client's loopback channel,
  so the server runs a bot like any other client (pmove, the gun's frames,
  pickups, damage, respawn).

  Enemies: in deathmatch the other living players (not the local one with
  notarget), else live monsters (a helper in single player). Firing waits a
  reaction time after an enemy comes into sight, aims with a spread that
  changes now and then, and turns at a limited speed: all by skill 0..3.
  Without an enemy it goes to the last spot it saw one, else to the best
  item it can see (worth by what it lacks), else wanders, turning away from
  walls, drops and lava / slime; it jumps and turns when stuck. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, CastleVectors,
  QuakeHud, QuakeEntities, QuakeWorld;

const
  BotMaxSkill = 3;

type
  TQuakeBot = class
  strict private
    FNumber, FSkill: Integer;
    FRandom: Cardinal;
    { The enemy (a player number, or a monster compared only by identity:
      never dereferenced after this frame), where it was seen last, and for
      how long it has been in sight }
    FEnemyPlayer: Integer;
    FEnemyMonster: TObject;
    FEnemyVisible: Boolean;
    FEnemyPos: TVector3;
    FEnemySeen: Single;
    FLastSeenPos: TVector3;
    FLastSeenTime: Single;
    { An item goal: index in World.Pickups (-1: none), one skipped after
      getting stuck on the way, and its seconds left }
    FGoalItem, FSkipItem: Integer;
    FSkipTime: Single;
    FGoalText: String;
    FSightTimer, FAimTimer, FStrafeTimer, FWeaponTimer, FProbeTimer: Single;
    FAimErrYaw, FAimErrPitch: Single;
    FStrafeDir: Single;
    FWanderYaw: Single;
    { Stuck test: the position 0.5 s ago }
    FStuckTimer, FJumpTimer: Single;
    FStuckPos: TVector3;
    FStuckCount: Integer;
    FWeaponRequest: Integer;
    FShots: Integer;
    FPrevFire: Boolean;
    { Hurt lately: looks all around (no front cone) }
    FLastHealth: Integer;
    FAlertTime: Single;
    function NextRandom: Single;
    function RandomRange(const A, B: Single): Single;
    procedure FindEnemy(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye: TVector3);
    procedure FindItem(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye: TVector3);
    function Visible(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye, Target: TVector3): Boolean;
    function SafeStep(const World: TQuakeWorld; const Me: TQuakePlayer; const DirYaw, Dist: Single): Single;
    procedure TurnTo(const WantYaw, WantPitch, Dt: Single);
    procedure MoveTo(const World: TQuakeWorld; const Me: TQuakePlayer; const Point: TVector3; const Dt: Single);
    procedure Wander(const World: TQuakeWorld; const Me: TQuakePlayer; const Dt: Single);
  public
    { This frame's usercmd (moves -1..1, Quake degrees; pitch up positive) }
    Forward, Side, Yaw, Pitch: Single;
    Jump, Fire: Boolean;
    constructor Create(const ANumber, ASkill: Integer; const AYaw: Single);
    { Decide this frame's command for Me (the bot's player on the server) }
    procedure Think(const World: TQuakeWorld; const Me: TQuakePlayer; const Dt: Single);
    { A weapon slot to ask the server for ("weapon N"), once }
    function TakeWeaponRequest(out Slot: Integer): Boolean;
    { One line for the V log }
    function Describe(const World: TQuakeWorld; const Me: TQuakePlayer): String;
    { View direction of Yaw / Pitch (Quake coordinates) }
    function ViewDir: TVector3;
    property Skill: Integer read FSkill;
    property StuckCount: Integer read FStuckCount;
    property Shots: Integer read FShots;
  end;

{ Pure helpers (unit tests) }
{ A - B in -180 .. 180 }
function BotAngleDiff(const A, B: Single): Single;
{ Cur turned towards Want by at most MaxStep degrees }
function BotTurn(const Cur, Want, MaxStep: Single): Single;
{ Seconds an enemy must be in sight before the first shot, aim spread in
  degrees and turn speed in degrees a second, by skill 0..3 }
function BotReactionTime(const Skill: Integer): Single;
function BotAimSpread(const Skill: Integer): Single;
function BotTurnSpeed(const Skill: Integer): Single;
{ The weapon slot a bot wants at Dist from its enemy: the best one it owns
  with ammo, no splash weapons close by }
function BotWeaponChoice(const Stats: TQuakePlayerStats; const Dist: Single): Integer;
{ How much the bot wants an item (0: not at all); WeaponsStay: weapons it
  owns can't be picked again }
function BotItemWorth(const Def: TQuakeItemDef; const Stats: TQuakePlayerStats;
  const WeaponsStay: Boolean): Single;

implementation

uses
  QuakeBsp, QuakeTrace, QuakeSettings, QuakePMove, QuakeLight;

function BotAngleDiff(const A, B: Single): Single;
begin
  Result := A - B;
  Result := Result - 360 * Floor((Result + 180) / 360);
end;

function BotTurn(const Cur, Want, MaxStep: Single): Single;
var
  D: Single;
begin
  D := BotAngleDiff(Want, Cur);
  if Abs(D) <= MaxStep then
    Result := Want
  else
    Result := Cur + Sign(D) * MaxStep;
  Result := Result - 360 * Floor(Result / 360);
end;

function BotReactionTime(const Skill: Integer): Single;
begin
  Result := 0.7 - 0.15 * EnsureRange(Skill, 0, BotMaxSkill);
end;

function BotAimSpread(const Skill: Integer): Single;
begin
  Result := 8 - 2 * EnsureRange(Skill, 0, BotMaxSkill);
end;

function BotTurnSpeed(const Skill: Integer): Single;
begin
  Result := 270 + 150 * EnsureRange(Skill, 0, BotMaxSkill);
end;

function BotWeaponChoice(const Stats: TQuakePlayerStats; const Dist: Single): Integer;
const
  { Best first: BFG, rockets, rail, hyperblaster, chaingun, super shotgun,
    machinegun, shotgun, grenades, blaster }
  Order: array[0..9] of Integer = (10, 7, 9, 8, 5, 3, 4, 2, 6, 1);
var
  I, Slot: Integer;
  Def: TQuakeWeaponDef;
begin
  for I := Low(Order) to High(Order) do
  begin
    Slot := Order[I];
    if (Stats.WeaponMask and (1 shl Slot)) = 0 then
      Continue;
    Def := WeaponDefs[Slot];
    if (Def.AmmoType <> atNone) and (Stats.Ammo[Def.AmmoType] < Max(1, Def.AmmoPerShot)) then
      Continue;
    { Splash hurts the bot too close by; the BFG takes long to fly }
    if (Slot in [6, 7]) and (Dist < 160) then
      Continue;
    if (Slot = 10) and (Dist < 300) then
      Continue;
    if (Slot = 6) and (Dist > 800) then
      Continue;
    if (Slot = 3) and (Dist > 600) then
      Continue;
    Exit(Slot);
  end;
  Result := 1;
end;

function BotItemWorth(const Def: TQuakeItemDef; const Stats: TQuakePlayerStats;
  const WeaponsStay: Boolean): Single;
var
  Slot: Integer;
begin
  Result := 0;
  case Def.Category of
    icWeapon:
      begin
        Slot := Def.Weapon;
        if (Slot >= 1) and (Slot <= 31) and ((Stats.WeaponMask and (1 shl Slot)) = 0) then
          Result := 3
        else
        if not WeaponsStay then
          Result := 0.4;
      end;
    icAmmo:
      if Stats.Ammo[Def.AmmoType] < Stats.MaxAmmo[Def.AmmoType] then
        Result := 0.8;
    icHealth:
      if (Def.ClassName = 'item_health_mega') or (Def.ClassName = 'item_adrenaline') or
         (Def.ClassName = 'item_ancient_head') then
        Result := 2
      else
      if Def.ClassName = 'item_health_small' then
        Result := 0.5
      else
      if Stats.Health < Stats.MaxHealth then
        Result := 1 + (Stats.MaxHealth - Stats.Health) / 25;
    icArmor:
      if Stats.Armor < 200 then
      begin
        if Def.ClassName = 'item_armor_shard' then
          Result := 0.5
        else
          Result := 1.5;
      end;
    icPowerup:
      if (Def.ClassName = 'item_quad') or (Def.ClassName = 'item_invulnerability') then
        Result := 2.5
      else
        Result := 1;
    icKey:
      Result := 0;
  end;
end;

{ TQuakeBot }

constructor TQuakeBot.Create(const ANumber, ASkill: Integer; const AYaw: Single);
begin
  inherited Create;
  FNumber := ANumber;
  FSkill := EnsureRange(ASkill, 0, BotMaxSkill);
  { Its own random numbers (xorshift): bots don't change the game's }
  FRandom := Cardinal(ANumber) * 2654435761 + 12345;
  if FRandom = 0 then
    FRandom := 1;
  Yaw := AYaw;
  FWanderYaw := AYaw;
  FGoalItem := -1;
  FSkipItem := -1;
  FStrafeDir := 1;
end;

function TQuakeBot.NextRandom: Single;
begin
  FRandom := FRandom xor (FRandom shl 13);
  FRandom := FRandom xor (FRandom shr 17);
  FRandom := FRandom xor (FRandom shl 5);
  Result := (FRandom and $FFFFFF) / $1000000;
end;

function TQuakeBot.RandomRange(const A, B: Single): Single;
begin
  Result := A + (B - A) * NextRandom;
end;

function TQuakeBot.ViewDir: TVector3;
var
  Y, P: Single;
begin
  Y := DegToRad(Yaw);
  P := DegToRad(Pitch);
  Result := Vector3(Cos(P) * Cos(Y), Cos(P) * Sin(Y), Sin(P));
end;

function TQuakeBot.Visible(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye, Target: TVector3): Boolean;
var
  T: TQuakeTrace;
begin
  T := World.WorldTrace(Eye, Target, TVector3.Zero, TVector3.Zero, MASK_OPAQUE, Me.PM);
  Result := not T.StartSolid and (T.Fraction >= 1);
end;

procedure TQuakeBot.FindEnemy(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye: TVector3);
var
  P: TQuakePlayer;
  M: TQuakeMonster;
  BestDist, D: Single;
  BestPlayer: Integer;
  BestMonster: TObject;
  BestPos, Pos, Delta, Facing: TVector3;
  Found: Boolean;

  { In the front cone, close by or the enemy it has now }
  function Considered(const Pos: TVector3; const Current: Boolean): Boolean;
  begin
    Delta := Pos - Eye;
    D := Delta.Length;
    if D > 2048 then
      Exit(False);
    if Current or (D < 256) or (FAlertTime > 0) then
      Exit(True);
    Delta := Delta / Max(D, 1);
    Result := TVector3.DotProduct(Delta, Facing) > -0.2;
  end;

begin
  Facing := Vector3(Cos(DegToRad(Yaw)), Sin(DegToRad(Yaw)), 0);
  BestDist := MaxSingle;
  BestPlayer := 0;
  BestMonster := nil;
  BestPos := TVector3.Zero;
  Found := False;
  if Deathmatch then
  begin
    for P in World.Players do
    begin
      if (P = Me) or P.Dead or (P.PM = nil) then
        Continue;
      if P.Local and NoTarget then
        Continue;
      Pos := P.PM.Origin;
      if not Considered(Pos, P.Number = FEnemyPlayer) then
        Continue;
      if (D < BestDist) and Visible(World, Me, Eye, Pos) then
      begin
        BestDist := D;
        BestPlayer := P.Number;
        BestPos := Pos;
        Found := True;
      end;
    end;
  end else
    for M in World.Monsters do
    begin
      if (not M.IsAlive) or M.Dormant or M.GoodGuy or (M.Transform = nil) or not M.Transform.Exists then
        Continue;
      Pos := M.Origin + (M.BoxMins + M.ShotBoxMaxs) * 0.5;
      if not Considered(Pos, M = FEnemyMonster) then
        Continue;
      if (D < BestDist) and Visible(World, Me, Eye, Pos) then
      begin
        BestDist := D;
        BestMonster := M;
        BestPos := Pos;
        Found := True;
      end;
    end;

  if Found then
  begin
    { A new enemy: the reaction time starts again }
    if (BestPlayer <> FEnemyPlayer) or (BestMonster <> FEnemyMonster) or not FEnemyVisible then
      FEnemySeen := 0;
    FEnemyPlayer := BestPlayer;
    FEnemyMonster := BestMonster;
    FEnemyVisible := True;
    FEnemyPos := BestPos;
    FLastSeenPos := BestPos;
    FLastSeenTime := 3;
  end else
  begin
    FEnemyVisible := False;
    FEnemyPlayer := 0;
    FEnemyMonster := nil;
  end;
end;

procedure TQuakeBot.FindItem(const World: TQuakeWorld; const Me: TQuakePlayer; const Eye: TVector3);
var
  I, Best: Integer;
  Pick: TQuakePickup;
  Worth, Score, BestScore, Dist: Single;
  Pos, Feet: TVector3;
  WeaponsStay: Boolean;
begin
  WeaponsStay := DMFlag(DF_WEAPONS_STAY);
  Feet := Me.PM.Origin + Vector3(0, 0, Me.PM.Mins.Z);
  Best := -1;
  BestScore := 0;
  for I := 0 to World.Pickups.Count - 1 do
  begin
    Pick := World.Pickups[I];
    if Pick.Collected or (Pick.Def = nil) or (I = FSkipItem) then
      Continue;
    Pos := CgeToQuake(Pick.Origin);
    Dist := (Pos - Feet).Length;
    { Close enough, and not on a ledge above a step }
    if (Dist > 1024) or (Pos.Z - Feet.Z > 40) then
      Continue;
    Worth := BotItemWorth(Pick.Def^, Me.Stats, WeaponsStay);
    if Worth <= 0 then
      Continue;
    Score := Worth / (1 + Dist / 256);
    if (Score > BestScore) and Visible(World, Me, Eye, Pos + Vector3(0, 0, 8)) then
    begin
      BestScore := Score;
      Best := I;
    end;
  end;
  FGoalItem := Best;
end;

function TQuakeBot.SafeStep(const World: TQuakeWorld; const Me: TQuakePlayer; const DirYaw, Dist: Single): Single;
var
  Org, Dir, Stop: TVector3;
  T, Down: TQuakeTrace;
  Contents: Integer;
begin
  { How far it can walk that way (0..1 of Dist): stopped by walls, and 0
    when the ground there is a drop deeper than 200 or lava / slime }
  Org := Me.PM.Origin;
  Dir := Vector3(Cos(DegToRad(DirYaw)), Sin(DegToRad(DirYaw)), 0);
  { Steps: the box is lifted by a step's height }
  T := World.WorldTrace(Org + Vector3(0, 0, 18), Org + Vector3(0, 0, 18) + Dir * Dist,
    Me.PM.Mins, Me.PM.Maxs, MASK_PLAYERSOLID, Me.PM);
  if T.StartSolid then
    T := World.WorldTrace(Org, Org + Dir * Dist, Me.PM.Mins, Me.PM.Maxs, MASK_PLAYERSOLID, Me.PM);
  Result := T.Fraction;
  if Result <= 0 then
    Exit;
  { The ground in front of the box's leading edge }
  Stop := T.EndPos + Dir * 16;
  Down := World.WorldTrace(Stop, Stop - Vector3(0, 0, 220), Me.PM.Mins, Me.PM.Maxs,
    MASK_PLAYERSOLID, Me.PM);
  if Down.StartSolid then
    Exit;
  if Down.Fraction >= 1 then
    Exit(0);
  if World.Bsp <> nil then
  begin
    Contents := World.Bsp.PointContents(Down.EndPos + Vector3(0, 0, Me.PM.Mins.Z + 1));
    if (Contents and (CONTENTS_LAVA or CONTENTS_SLIME)) <> 0 then
      Exit(0);
  end;
end;

procedure TQuakeBot.TurnTo(const WantYaw, WantPitch, Dt: Single);
var
  Step: Single;
begin
  Step := BotTurnSpeed(FSkill) * Dt;
  Yaw := BotTurn(Yaw, WantYaw, Step);
  if Abs(WantPitch - Pitch) <= Step then
    Pitch := WantPitch
  else
    Pitch := Pitch + Sign(WantPitch - Pitch) * Step;
  Pitch := EnsureRange(Pitch, -80, 80);
end;

procedure TQuakeBot.MoveTo(const World: TQuakeWorld; const Me: TQuakePlayer; const Point: TVector3; const Dt: Single);
var
  Delta: TVector3;
  WantYaw: Single;
begin
  Delta := Point - Me.PM.Origin;
  WantYaw := RadToDeg(ArcTan2(Delta.Y, Delta.X));
  TurnTo(WantYaw, 0, Dt);
  if Abs(BotAngleDiff(WantYaw, Yaw)) < 45 then
    Forward := 1
  else
    Forward := 0.2;
  Side := 0;
end;

procedure TQuakeBot.Wander(const World: TQuakeWorld; const Me: TQuakePlayer; const Dt: Single);
var
  I: Integer;
  Y, Score, BestScore, BestYaw: Single;
begin
  FProbeTimer := FProbeTimer - Dt;
  if FProbeTimer <= 0 then
  begin
    FProbeTimer := 0.3;
    if SafeStep(World, Me, FWanderYaw, 96) < 0.7 then
    begin
      { Blocked: the most open of 8 directions, rather ahead than back }
      BestScore := -1;
      BestYaw := FWanderYaw + 180;
      for I := 0 to 7 do
      begin
        Y := FWanderYaw + I * 45 + RandomRange(-15, 15);
        Score := SafeStep(World, Me, Y, 192) + RandomRange(0, 0.2);
        if Abs(BotAngleDiff(Y, FWanderYaw + 180)) < 50 then
          Score := Score - 0.3;
        if Score > BestScore then
        begin
          BestScore := Score;
          BestYaw := Y;
        end;
      end;
      FWanderYaw := BestYaw - 360 * Floor(BestYaw / 360);
    end else
    if NextRandom < 0.05 then
      FWanderYaw := FWanderYaw + RandomRange(-60, 60);
  end;
  TurnTo(FWanderYaw, 0, Dt);
  if Abs(BotAngleDiff(FWanderYaw, Yaw)) < 60 then
    Forward := 1
  else
    Forward := 0;
  Side := 0;
end;

procedure TQuakeBot.Think(const World: TQuakeWorld; const Me: TQuakePlayer; const Dt: Single);
var
  Eye, Delta, Target, Flat: TVector3;
  Dist, WantYaw, WantPitch, MoveYaw: Single;
  Slot: Integer;
  P: TQuakePlayer;
  Pick: TQuakePickup;
  Moving: Boolean;

  function YawOfMove: Single;
  begin
    { Quake's side move is to the right: yaw - 90 }
    Result := Yaw + RadToDeg(ArcTan2(-Side, Forward));
  end;

  procedure SkipGoal;
  begin
    if FGoalItem >= 0 then
    begin
      FSkipItem := FGoalItem;
      FSkipTime := 5;
    end;
    FGoalItem := -1;
    FLastSeenTime := 0;
  end;

begin
  Forward := 0;
  Side := 0;
  Jump := False;
  Fire := False;
  if (Me = nil) or (Me.PM = nil) or (World.Bsp = nil) then
    Exit;
  if Me.Dead then
  begin
    { Fire respawns it (deathmatch); a new life forgets the old one }
    Fire := True;
    FEnemyPlayer := 0;
    FEnemyMonster := nil;
    FEnemyVisible := False;
    FLastSeenTime := 0;
    FGoalItem := -1;
    FGoalText := 'dead';
    FPrevFire := False;
    Pitch := 0;
    Exit;
  end;
  Eye := Me.PM.Origin + Vector3(0, 0, Me.PM.ViewHeight);
  FWeaponTimer := FWeaponTimer - Dt;
  FSkipTime := FSkipTime - Dt;
  FAlertTime := FAlertTime - Dt;
  { Hurt by something it doesn't see: turn around and look everywhere }
  if (Me.Stats.Health < FLastHealth) and not FEnemyVisible then
  begin
    FAlertTime := 2;
    FSightTimer := 0;
    FWanderYaw := Yaw + 180;
    FWanderYaw := FWanderYaw - 360 * Floor(FWanderYaw / 360);
    FProbeTimer := 0.5;
    FLastSeenTime := 0;
  end;
  FLastHealth := Me.Stats.Health;
  if FSkipTime <= 0 then
    FSkipItem := -1;

  { Look around 10 times a second }
  FSightTimer := FSightTimer - Dt;
  if FSightTimer <= 0 then
  begin
    FSightTimer := 0.1;
    FindEnemy(World, Me, Eye);
    if not FEnemyVisible then
      FindItem(World, Me, Eye);
  end;

  if FEnemyVisible then
  begin
    FGoalText := 'fight';
    FEnemySeen := FEnemySeen + Dt;
    { A player is followed between looks; a monster is aimed at where the
      last look saw it }
    Target := FEnemyPos;
    if FEnemyPlayer <> 0 then
      for P in World.Players do
        if (P.Number = FEnemyPlayer) and (P.PM <> nil) and not P.Dead then
          Target := P.PM.Origin;
    Delta := Target - Eye;
    Dist := Delta.Length;
    FAimTimer := FAimTimer - Dt;
    if FAimTimer <= 0 then
    begin
      FAimTimer := RandomRange(0.3, 0.6);
      FAimErrYaw := RandomRange(-1, 1) * BotAimSpread(FSkill);
      FAimErrPitch := RandomRange(-0.5, 0.5) * BotAimSpread(FSkill);
    end;
    WantYaw := RadToDeg(ArcTan2(Delta.Y, Delta.X)) + FAimErrYaw;
    WantPitch := RadToDeg(ArcTan2(Delta.Z, Sqrt(Sqr(Delta.X) + Sqr(Delta.Y)))) + FAimErrPitch;
    TurnTo(WantYaw, WantPitch, Dt);
    Slot := BotWeaponChoice(Me.Stats, Dist);
    if (Slot <> Me.Stats.CurrentWeapon) and (FWeaponTimer <= 0) then
    begin
      FWeaponRequest := Slot;
      FWeaponTimer := 2;
    end;
    Fire := (FEnemySeen >= BotReactionTime(FSkill)) and
      (Abs(BotAngleDiff(WantYaw, Yaw)) < 10) and (Abs(WantPitch - Pitch) < 10);
    { Strafe, changing side now and then; closer when far, back when close }
    FStrafeTimer := FStrafeTimer - Dt;
    if FStrafeTimer <= 0 then
    begin
      FStrafeTimer := RandomRange(0.6, 1.6);
      if NextRandom < 0.6 then
        FStrafeDir := -FStrafeDir;
    end;
    if Dist > 500 then
      Forward := 1
    else
    if Dist < 160 then
      Forward := -1;
    Side := FStrafeDir;
    { Not into walls, drops or lava: the other side, else stand }
    if SafeStep(World, Me, YawOfMove, 64) < 0.5 then
    begin
      FStrafeDir := -FStrafeDir;
      Side := FStrafeDir;
      if SafeStep(World, Me, YawOfMove, 64) < 0.5 then
      begin
        Side := 0;
        if SafeStep(World, Me, YawOfMove, 64) < 0.5 then
          Forward := 0;
      end;
    end;
  end else
  begin
    FEnemySeen := 0;
    FLastSeenTime := FLastSeenTime - Dt;
    if FLastSeenTime > 0 then
    begin
      { Where the enemy went out of sight }
      FGoalText := 'last seen';
      MoveTo(World, Me, FLastSeenPos, Dt);
      Flat := FLastSeenPos - Me.PM.Origin;
      if Sqr(Flat.X) + Sqr(Flat.Y) < Sqr(48) then
        FLastSeenTime := 0;
    end else
    if (FGoalItem >= 0) and (FGoalItem < World.Pickups.Count) and
       not World.Pickups[FGoalItem].Collected and (World.Pickups[FGoalItem].Def <> nil) then
    begin
      Pick := World.Pickups[FGoalItem];
      FGoalText := Pick.Def^.ClassName;
      MoveTo(World, Me, CgeToQuake(Pick.Origin), Dt);
    end else
    begin
      FGoalItem := -1;
      FGoalText := 'wander';
      Wander(World, Me, Dt);
    end;
    { A goal over a drop or lava is given up }
    if (FGoalText <> 'wander') and (Forward > 0) and (SafeStep(World, Me, Yaw, 64) <= 0) then
    begin
      Forward := 0;
      SkipGoal;
    end;
  end;
  MoveYaw := YawOfMove;

  { Stuck: moving but not 16 units further in half a second: jump, turn,
    and give up the goal }
  Moving := Abs(Forward) + Abs(Side) > 0.5;
  FStuckTimer := FStuckTimer - Dt;
  if FStuckTimer <= 0 then
  begin
    Flat := Me.PM.Origin - FStuckPos;
    if Moving and (Sqr(Flat.X) + Sqr(Flat.Y) < Sqr(16)) then
    begin
      Inc(FStuckCount);
      FJumpTimer := 0.3;
      FWanderYaw := MoveYaw + RandomRange(90, 270);
      FWanderYaw := FWanderYaw - 360 * Floor(FWanderYaw / 360);
      FProbeTimer := 0;
      FStrafeDir := -FStrafeDir;
      SkipGoal;
    end;
    FStuckPos := Me.PM.Origin;
    FStuckTimer := 0.5;
  end;
  if FJumpTimer > 0 then
  begin
    FJumpTimer := FJumpTimer - Dt;
    Jump := True;
  end;
  if Fire and not FPrevFire then
    Inc(FShots);
  FPrevFire := Fire;
end;

function TQuakeBot.TakeWeaponRequest(out Slot: Integer): Boolean;
begin
  Slot := FWeaponRequest;
  Result := Slot <> 0;
  FWeaponRequest := 0;
end;

function TQuakeBot.Describe(const World: TQuakeWorld; const Me: TQuakePlayer): String;
var
  Enemy: String;
  Health, Weapon: Integer;
begin
  if not FEnemyVisible then
    Enemy := 'none'
  else
  if FEnemyPlayer <> 0 then
    Enemy := Format('Player %d (in sight %.1f s)', [FEnemyPlayer, FEnemySeen], DefaultFormatSettings)
  else
    Enemy := Format('a monster (in sight %.1f s)', [FEnemySeen], DefaultFormatSettings);
  Health := 0;
  Weapon := 0;
  if Me <> nil then
  begin
    Health := Me.Stats.Health;
    Weapon := Me.Stats.CurrentWeapon;
  end;
  Result := Format('skill %d, health %d, weapon %d, enemy %s, goal %s, shots %d, stuck %d',
    [FSkill, Health, Weapon, Enemy, FGoalText, FShots, FStuckCount]);
end;

end.
