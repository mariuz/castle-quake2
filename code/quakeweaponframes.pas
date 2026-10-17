{ The player's gun as Quake 2 runs it (p_weapon.c): a state machine
  stepped at 10 Hz over the view model's frames. Weapons fire on the frames
  Quake 2 fires them on, refire when the firing frames have played, take the
  time of their put-away and raise animations to switch, and the machinegun,
  chaingun, hyperblaster and hand grenades have their own frame logic.

  TQuakeGun is plain code (no scene, no sounds): TQuakeWorld asks it to Think
  and does what its events say, and the unit tests drive it directly. }
unit QuakeWeaponFrames;

{$mode objfpc}{$H+}

interface

const
  { Quake 2 server frame: guns advance one model frame per 0.1 s }
  GunFrameTime = 0.1;
  { Hand grenade fuse (GRENADE_TIMER) }
  GrenadeTimer = 3.0;
  HandGrenadeSlot = 11;

type
  { Weapon_Generic's frame ranges: activate 0..ActivateLast, fire
    ActivateLast+1..FireLast, idle FireLast+1..IdleLast, put away
    IdleLast+1..DeactivateLast }
  TGunFrameDef = record
    ActivateLast, FireLast, IdleLast, DeactivateLast: Integer;
    PauseFrames, FireFrames: array of Integer;
  end;

  TGunState = (gsActivating, gsReady, gsFiring, gsDropping);

  TGunEvent = (
    { Fire the current weapon now (Shots: chaingun bullets this frame) }
    geFire,
    { BFG: muzzle flash and sound; the ball leaves 0.8 s later }
    geBfgFlash,
    { Fire pressed without ammo (at most once a second) }
    geNoAmmo,
    { The old weapon is put away: make PendingSlot current }
    geChangeWeapon,
    { Hand grenade: pin pulled, thrown (Fuse: seconds left), blew up in hand }
    geGrenadePin, geGrenadeThrow, geGrenadeBlowUp,
    { Chaingun spin up / spin down sounds }
    geChaingunUp, geChaingunDown,
    { HyperBlaster stops (spin-down sound) }
    geHyperBlasterDown);

  TGunEventProc = procedure(const Event: TGunEvent) of object;
  { Shots of ammo available for a weapon slot (MaxInt without ammo use) }
  TGunAmmoFunc = function(const Slot: Integer): Integer of object;

  TQuakeGun = class
  strict private
    FSlot, FPendingSlot: Integer;
    FFrame, FOldFrame: Integer;
    FState: TGunState;
    FTime, FAccum: Single;
    FNoAmmoTime: Single;
    FGrenadeTime: Single;
    FGrenadeBlewUp: Boolean;
    FShots: Integer;
    FFuse: Single;
    FLoopSound: String;
    procedure Event(const E: TGunEvent);
    function Ammo(const ASlot: Integer): Integer;
    procedure Generic(const Def: TGunFrameDef);
    procedure Grenade;
    { Fire functions: they advance the frame themselves, like Quake 2's }
    procedure FireFrame;
    procedure ChangeWeapon;
  public
    { Fire held this frame / pressed since the last think (latched) }
    Attack, AttackLatched: Boolean;
    OnEvent: TGunEventProc;
    OnAmmo: TGunAmmoFunc;
    { Pause on idle frames like Quake 2 (rand() & 15); off in tests }
    RandomPauses: Boolean;
    constructor Create;
    { Start with a weapon being raised (level start, respawn) }
    procedure Reset(const ASlot: Integer; const RaiseIt: Boolean = True);
    { Switch to Slot after putting the current weapon away }
    procedure Select(const ASlot: Integer);
    { Advance time; runs Think every 0.1 s. A new press of fire thinks at
      once (Quake 2 weapon_thunk), so the first shot is not delayed. }
    procedure Update(const SecondsPassed: Single);
    { One Quake 2 weapon think }
    procedure Think;
    property Slot: Integer read FSlot;
    property PendingSlot: Integer read FPendingSlot;
    property State: TGunState read FState;
    property Frame: Integer read FFrame;
    property OldFrame: Integer read FOldFrame;
    { 0..1 between OldFrame and Frame, for drawing }
    function FrameLerp: Single;
    { Bullets of the current chaingun geFire }
    property Shots: Integer read FShots;
    { Seconds left on a thrown or blown-up hand grenade }
    property Fuse: Single read FFuse;
    { Hand grenade with the pin pulled }
    function Cooking: Boolean;
    { Looping weapon sound of the player ('' for none) }
    property LoopSound: String read FLoopSound;
    property Time: Single read FTime;
  end;

{ Frame table of a weapon slot (1 blaster .. 10 BFG, 11 hand grenades) }
function GunFrameDef(const Slot: Integer): TGunFrameDef;

implementation

uses
  Math;

function MakeDef(const A, F, I, D: Integer; const Pause, Fire: array of Integer): TGunFrameDef;
var
  K: Integer;
begin
  Result.ActivateLast := A;
  Result.FireLast := F;
  Result.IdleLast := I;
  Result.DeactivateLast := D;
  SetLength(Result.PauseFrames, Length(Pause));
  for K := 0 to High(Pause) do
    Result.PauseFrames[K] := Pause[K];
  SetLength(Result.FireFrames, Length(Fire));
  for K := 0 to High(Fire) do
    Result.FireFrames[K] := Fire[K];
end;

function GunFrameDef(const Slot: Integer): TGunFrameDef;
begin
  { Weapon_Generic arguments of the Quake 2 weapons (p_weapon.c) }
  case Slot of
    1: Result := MakeDef(4, 8, 52, 55, [19, 32], [5]);
    2: Result := MakeDef(7, 18, 36, 39, [22, 28, 34], [8, 9]);
    3: Result := MakeDef(6, 17, 57, 61, [29, 42, 57], [7]);
    4: Result := MakeDef(3, 5, 45, 49, [23, 45], [4, 5]);
    5: Result := MakeDef(4, 31, 61, 64, [38, 43, 51, 61],
         [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]);
    6: Result := MakeDef(5, 16, 59, 64, [34, 51, 59], [6]);
    7: Result := MakeDef(4, 12, 50, 54, [25, 33, 42, 50], [5]);
    8: Result := MakeDef(5, 20, 49, 53, [], [6, 7, 8, 9, 10, 11]);
    9: Result := MakeDef(3, 18, 56, 61, [56], [4]);
    10: Result := MakeDef(8, 32, 55, 58, [39, 45, 50, 55], [9, 17]);
    { Weapon_Grenade: throw 0..15, idle 16..48, no raise / put away }
    else Result := MakeDef(0, 15, 48, 48, [29, 34, 39, 48], []);
  end;
end;

{ TQuakeGun }

constructor TQuakeGun.Create;
begin
  inherited Create;
  RandomPauses := True;
  FSlot := 1;
  FNoAmmoTime := -1;
end;

procedure TQuakeGun.Event(const E: TGunEvent);
begin
  if Assigned(OnEvent) then
    OnEvent(E);
end;

function TQuakeGun.Ammo(const ASlot: Integer): Integer;
begin
  if Assigned(OnAmmo) then
    Result := OnAmmo(ASlot)
  else
    Result := MaxInt;
end;

procedure TQuakeGun.Reset(const ASlot: Integer; const RaiseIt: Boolean);
begin
  FSlot := ASlot;
  FPendingSlot := 0;
  FGrenadeTime := 0;
  FGrenadeBlewUp := False;
  FLoopSound := '';
  FAccum := 0;
  Attack := False;
  AttackLatched := False;
  if RaiseIt then
  begin
    FState := gsActivating;
    FFrame := 0;
  end else
  begin
    FState := gsReady;
    FFrame := GunFrameDef(ASlot).FireLast + 1;
  end;
  FOldFrame := FFrame;
end;

procedure TQuakeGun.Select(const ASlot: Integer);
begin
  if ASlot = FSlot then
    FPendingSlot := 0
  else
    FPendingSlot := ASlot;
end;

function TQuakeGun.FrameLerp: Single;
begin
  Result := EnsureRange(FAccum / GunFrameTime, 0, 1);
end;

function TQuakeGun.Cooking: Boolean;
begin
  Result := (FSlot = HandGrenadeSlot) and (FState = gsFiring) and (FFrame <= 12);
end;

procedure TQuakeGun.Update(const SecondsPassed: Single);
begin
  FTime := FTime + SecondsPassed;
  { A new press thinks at once (Quake 2 weapon_thunk) and restarts the
    frame clock, so the first shot isn't delayed and refire stays exact }
  if AttackLatched and (FState = gsReady) then
  begin
    Think;
    FAccum := 0;
    Exit;
  end;
  FAccum := FAccum + SecondsPassed;
  { Large steps (loading hitches): don't replay many frames }
  if FAccum > 4 * GunFrameTime then
    FAccum := GunFrameTime;
  while FAccum >= GunFrameTime do
  begin
    FAccum := FAccum - GunFrameTime;
    Think;
  end;
end;

procedure TQuakeGun.ChangeWeapon;
begin
  { A cooked grenade is thrown when switching away (Quake 2 ChangeWeapon) }
  if FGrenadeTime > 0 then
  begin
    FFuse := Max(0, FGrenadeTime - FTime);
    FGrenadeTime := 0;
    Event(geGrenadeThrow);
  end;
  Event(geChangeWeapon);
  if FPendingSlot <> 0 then
    FSlot := FPendingSlot;
  FPendingSlot := 0;
  FLoopSound := '';
  FState := gsActivating;
  FFrame := 0;
end;

procedure TQuakeGun.Think;
begin
  FOldFrame := FFrame;
  if FSlot = HandGrenadeSlot then
    Grenade
  else
    Generic(GunFrameDef(FSlot));
end;

procedure TQuakeGun.Generic(const Def: TGunFrameDef);
var
  N: Integer;
  Fired: Boolean;
begin
  if FState = gsDropping then
  begin
    if FFrame >= Def.DeactivateLast then
    begin
      ChangeWeapon;
      Exit;
    end;
    Inc(FFrame);
    Exit;
  end;

  if FState = gsActivating then
  begin
    if FFrame >= Def.ActivateLast then
    begin
      FState := gsReady;
      FFrame := Def.FireLast + 1;
      Exit;
    end;
    Inc(FFrame);
    Exit;
  end;

  if (FPendingSlot <> 0) and (FState <> gsFiring) then
  begin
    FState := gsDropping;
    FFrame := Def.IdleLast + 1;
    Exit;
  end;

  if FState = gsReady then
  begin
    if Attack or AttackLatched then
    begin
      AttackLatched := False;
      if Ammo(FSlot) > 0 then
      begin
        FFrame := Def.ActivateLast + 1;
        FState := gsFiring;
      end else
      begin
        if FTime >= FNoAmmoTime then
        begin
          FNoAmmoTime := FTime + 1;
          Event(geNoAmmo);
        end;
        Exit;
      end;
    end else
    begin
      if FFrame >= Def.IdleLast then
      begin
        FFrame := Def.FireLast + 1;
        Exit;
      end;
      if RandomPauses then
        for N in Def.PauseFrames do
          if (FFrame = N) and (Random(16) <> 0) then
            Exit;
      Inc(FFrame);
      Exit;
    end;
  end;

  if FState = gsFiring then
  begin
    Fired := False;
    for N in Def.FireFrames do
      if FFrame = N then
      begin
        FireFrame;
        Fired := True;
        Break;
      end;
    if not Fired then
      Inc(FFrame);
    if FFrame = Def.FireLast + 2 then
      FState := gsReady;
  end;
end;

procedure TQuakeGun.FireFrame;
begin
  FShots := 1;
  case FSlot of
    2: { Shotgun: frame 9 only ejects the shell }
      begin
        if FFrame = 9 then
        begin
          Inc(FFrame);
          Exit;
        end;
        Event(geFire);
        Inc(FFrame);
      end;
    4: { Machinegun_Fire: alternate frames 4 / 5 while held }
      begin
        if not Attack then
        begin
          Inc(FFrame);
          Exit;
        end;
        if FFrame = 5 then
          FFrame := 4
        else
          FFrame := 5;
        if Ammo(FSlot) < 1 then
        begin
          FFrame := 6;
          if FTime >= FNoAmmoTime then
          begin
            FNoAmmoTime := FTime + 1;
            Event(geNoAmmo);
          end;
          Exit;
        end;
        Event(geFire);
      end;
    5: { Chaingun_Fire: spin up 1, 2, 3 bullets a frame, loop 15..21 }
      begin
        if FFrame = 5 then
          Event(geChaingunUp);
        if (FFrame = 14) and not Attack then
        begin
          FFrame := 32;
          FLoopSound := '';
          Exit;
        end else
        if (FFrame = 21) and Attack and (Ammo(FSlot) > 0) then
          FFrame := 15
        else
          Inc(FFrame);
        if FFrame = 22 then
        begin
          FLoopSound := '';
          Event(geChaingunDown);
        end else
          FLoopSound := 'sound/weapons/chngnl1a.wav';
        if FFrame <= 9 then
          FShots := 1
        else
        if FFrame <= 14 then
        begin
          if Attack then
            FShots := 2
          else
            FShots := 1;
        end else
          FShots := 3;
        FShots := Min(FShots, Ammo(FSlot));
        if FShots <= 0 then
        begin
          if FTime >= FNoAmmoTime then
          begin
            FNoAmmoTime := FTime + 1;
            Event(geNoAmmo);
          end;
          Exit;
        end;
        Event(geFire);
      end;
    8: { Weapon_HyperBlaster_Fire: frames 6..11 loop while held }
      begin
        FLoopSound := 'sound/weapons/hyprbl1a.wav';
        if not Attack then
          Inc(FFrame)
        else
        begin
          if Ammo(FSlot) <= 0 then
          begin
            if FTime >= FNoAmmoTime then
            begin
              FNoAmmoTime := FTime + 1;
              Event(geNoAmmo);
            end;
          end else
            Event(geFire);
          Inc(FFrame);
          if (FFrame = 12) and (Ammo(FSlot) > 0) then
            FFrame := 6;
        end;
        if FFrame = 12 then
        begin
          FLoopSound := '';
          Event(geHyperBlasterDown);
        end;
      end;
    10: { weapon_bfg_fire: flash on frame 9, the ball on 17 }
      begin
        if FFrame = 9 then
        begin
          Event(geBfgFlash);
          Inc(FFrame);
          Exit;
        end;
        if Ammo(FSlot) > 0 then
          Event(geFire);
        Inc(FFrame);
      end;
    else
      begin
        Event(geFire);
        Inc(FFrame);
      end;
  end;
end;

procedure TQuakeGun.Grenade;
var
  N: Integer;
begin
  { Weapon_Grenade }
  if (FPendingSlot <> 0) and (FState = gsReady) then
  begin
    ChangeWeapon;
    Exit;
  end;

  if FState = gsActivating then
  begin
    FState := gsReady;
    FFrame := 16;
    Exit;
  end;

  if FState = gsReady then
  begin
    if Attack or AttackLatched then
    begin
      AttackLatched := False;
      if Ammo(FSlot) > 0 then
      begin
        FFrame := 1;
        FState := gsFiring;
        FGrenadeTime := 0;
      end else
      if FTime >= FNoAmmoTime then
      begin
        FNoAmmoTime := FTime + 1;
        Event(geNoAmmo);
      end;
      Exit;
    end;
    if FFrame >= 48 then
    begin
      FFrame := 16;
      Exit;
    end;
    if RandomPauses then
      for N in GunFrameDef(HandGrenadeSlot).PauseFrames do
        if (FFrame = N) and (Random(16) <> 0) then
          Exit;
    Inc(FFrame);
    Exit;
  end;

  if FState = gsFiring then
  begin
    if FFrame = 5 then
      Event(geGrenadePin);
    if FFrame = 11 then
    begin
      if FGrenadeTime = 0 then
      begin
        FGrenadeTime := FTime + GrenadeTimer + 0.2;
        FLoopSound := 'sound/weapons/hgrenc1b.wav';
      end;
      { Held too long: it goes off in the hand }
      if (not FGrenadeBlewUp) and (FTime >= FGrenadeTime) then
      begin
        FLoopSound := '';
        FFuse := 0;
        Event(geGrenadeBlowUp);
        FGrenadeBlewUp := True;
        FGrenadeTime := FTime + 1.0;
      end;
      if Attack then
        Exit;
      if FGrenadeBlewUp then
      begin
        if FTime >= FGrenadeTime then
        begin
          FFrame := 15;
          FGrenadeBlewUp := False;
        end else
          Exit;
      end;
    end;
    if FFrame = 12 then
    begin
      FLoopSound := '';
      FFuse := Max(0, FGrenadeTime - FTime);
      Event(geGrenadeThrow);
      FGrenadeTime := FTime + 1.0;
    end;
    if (FFrame = 15) and (FTime < FGrenadeTime) then
      Exit;
    Inc(FFrame);
    if FFrame = 16 then
    begin
      FGrenadeTime := 0;
      FState := gsReady;
    end;
  end;
end;

end.
