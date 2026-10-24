{ Random levels in the spirit of Quake / Doom level design. The same seed
  always makes the same level ("rand<seed>" maps).

  - Layout: rooms of varied size placed apart, connected by a minimum
    spanning tree plus extra links, so there are loops and more than one
    way around (no pure dead-end trees). 2-cell corridors with low ceilings
    between high rooms (compression and release).
  - Height: every room has its own floor; corridors climb in 16-unit steps
    (Quake 2's player steps 18), big rooms get pillars for cover and raised
    platforms with a step ring, some rooms are open to the sky.
  - Flow: start in the room farthest from the exit; monsters grow in number
    and toughness along the way (none in the start room, the tank only in a
    big late room, some only on harder skills, some in ambush); weapons come
    in order of strength, ammo after them, health and armor after the
    fights; a secret side room with a reward; the exit (a trigger) leads to
    the next random level.
  - Light: lights over every room and along corridors, sky rooms brighter.
  - Checks: every open cell is reachable from the start on foot (steps of
    at most 16, headroom 64); unreachable ones are fixed or walled up. }
unit QuakeLevelGen;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, CastleVectors, QuakeLevel;

type
  TLevelGenOptions = record
    Width, Height: Integer;
    Rooms: Integer;
  end;

  TGenRoom = record
    X, Y, W, H: Integer;
    Floor, Ceil, Theme: Integer;
    Sky, Secret: Boolean;
    { Steps from the start room in the room graph, and 0..1 along the way }
    Depth: Integer;
    Rank: Single;
  end;

  TLevelGenReport = record
    Rooms, Links, Loops, OpenCells, FixedCells, WalledCells, Monsters, Items: Integer;
    StartRoom, ExitRoom, SecretRoom: Integer;
  end;

function DefaultLevelGenOptions: TLevelGenOptions;

{ A random level for Seed, named "rand<Seed>" }
function GenerateLevel(const Seed: Cardinal; const Options: TLevelGenOptions;
  out Report: TLevelGenReport): TQuakeLevel;
function GenerateLevel(const Seed: Cardinal): TQuakeLevel;

{ Map name of a seed's level, and the seed back from a name }
function RandomMapName(const Seed: Cardinal): String;
function IsRandomMapName(const MapName: String; out Seed: Cardinal): Boolean;

{ Open cells that can't be reached on foot from (X, Y) (steps <= 16,
  headroom >= 64) }
function UnreachableCells(const Level: TQuakeLevel; const X, Y: Integer): Integer;

{ Where the level editor saves the level of this name }
function LevelFileUrl(const Name: String): String;

implementation

uses
  Math, Generics.Collections, CastleLog, CastleUriUtils, QuakeBsp, QuakeBspBuilder;

type
  { xorshift32: the same numbers on every platform }
  TGenRandom = record
    State: Cardinal;
    function Next: Cardinal;
    function Int(const N: Integer): Integer;
    function Range(const A, B: Integer): Integer;
    function Chance(const P: Single): Boolean;
    function Float: Single;
  end;

  TLink = record
    A, B: Integer;
  end;

{$push}{$R-}{$Q-} { xorshift and seed hashing wrap around on purpose }
function TGenRandom.Next: Cardinal;
begin
  State := State xor (State shl 13);
  State := State xor (State shr 17);
  State := State xor (State shl 5);
  Result := State;
end;

function TGenRandom.Int(const N: Integer): Integer;
begin
  if N <= 1 then
    Exit(0);
  Result := Next mod Cardinal(N);
end;

function TGenRandom.Range(const A, B: Integer): Integer;
begin
  Result := A + Int(B - A + 1);
end;

function TGenRandom.Chance(const P: Single): Boolean;
begin
  Result := Float < P;
end;

function TGenRandom.Float: Single;
begin
  Result := (Next and $FFFFFF) / $1000000;
end;

function SeedState(const Seed: Cardinal): Cardinal;
begin
  Result := Seed * Cardinal(2654435761) + 12345;
  if Result = 0 then
    Result := 1;
end;
{$pop}

function DefaultLevelGenOptions: TLevelGenOptions;
begin
  Result.Width := 52;
  Result.Height := 52;
  Result.Rooms := 11;
end;

function RandomMapName(const Seed: Cardinal): String;
begin
  Result := 'rand' + IntToStr(Seed);
end;

function IsRandomMapName(const MapName: String; out Seed: Cardinal): Boolean;
var
  V: Int64;
begin
  Seed := 0;
  Result := (Copy(LowerCase(MapName), 1, 4) = 'rand') and TryStrToInt64(Copy(MapName, 5, MaxInt), V) and
    (V >= 0) and (V <= High(Cardinal));
  if Result then
    Seed := V;
end;

function CanStep(const A, B: PLevelCell): Boolean;
begin
  Result := (not A^.Solid) and (not B^.Solid) and (Abs(A^.Floor - B^.Floor) <= LevelHeightStep) and
    (Min(A^.Ceil, B^.Ceil) - Max(A^.Floor, B^.Floor) >= LevelMinHeadroom);
end;

const
  DX: array[0..3] of Integer = (1, -1, 0, 0);
  DY: array[0..3] of Integer = (0, 0, 1, -1);

{ Cells reachable on foot from (X, Y) }
procedure FloodReach(const Level: TQuakeLevel; const X, Y: Integer; var Reached: array of Boolean);
var
  Queue: specialize TList<Integer>;
  Head, I, CX, CY, NX, NY, D: Integer;
begin
  for I := 0 to High(Reached) do
    Reached[I] := False;
  if Level.Cell(X, Y)^.Solid then
    Exit;
  Queue := specialize TList<Integer>.Create;
  try
    Reached[Y * Level.Width + X] := True;
    Queue.Add(Y * Level.Width + X);
    Head := 0;
    while Head < Queue.Count do
    begin
      CX := Queue[Head] mod Level.Width;
      CY := Queue[Head] div Level.Width;
      Inc(Head);
      for D := 0 to 3 do
      begin
        NX := CX + DX[D];
        NY := CY + DY[D];
        if (not Level.InGrid(NX, NY)) or Reached[NY * Level.Width + NX] then
          Continue;
        if CanStep(Level.Cell(CX, CY), Level.Cell(NX, NY)) then
        begin
          Reached[NY * Level.Width + NX] := True;
          Queue.Add(NY * Level.Width + NX);
        end;
      end;
    end;
  finally
    Queue.Free;
  end;
end;

function UnreachableCells(const Level: TQuakeLevel; const X, Y: Integer): Integer;
var
  Reached: array of Boolean;
  I: Integer;
begin
  SetLength(Reached, Level.Width * Level.Height);
  FloodReach(Level, X, Y, Reached);
  Result := 0;
  for I := 0 to High(Reached) do
    if (not Reached[I]) and not Level.Cell(I mod Level.Width, I div Level.Width)^.Solid then
      Inc(Result);
end;

function Round16(const V: Single): Integer;
begin
  Result := Round(V / LevelHeightStep) * LevelHeightStep;
end;

function GenerateLevel(const Seed: Cardinal; const Options: TLevelGenOptions;
  out Report: TLevelGenReport): TQuakeLevel;
var
  Rnd: TGenRandom;
  Level: TQuakeLevel;
  Rooms: array of TGenRoom;
  Links: array of TLink;
  InRoom: array of Integer; { room index of a cell, -1 corridor / wall }
  Reached: array of Boolean;

  function CellRoom(const X, Y: Integer): Integer;
  begin
    if Level.InGrid(X, Y) then
      Result := InRoom[Y * Level.Width + X]
    else
      Result := -1;
  end;

  function RoomCenterX(const R: Integer): Integer;
  begin
    Result := Rooms[R].X + Rooms[R].W div 2;
  end;

  function RoomCenterY(const R: Integer): Integer;
  begin
    Result := Rooms[R].Y + Rooms[R].H div 2;
  end;

  function RoomDist(const A, B: Integer): Integer;
  begin
    Result := Abs(RoomCenterX(A) - RoomCenterX(B)) + Abs(RoomCenterY(A) - RoomCenterY(B));
  end;

  procedure PlaceRooms;
  var
    Tries, I, W, H, X, Y: Integer;
    Ok: Boolean;
    R: TGenRoom;
  begin
    Tries := 0;
    while (Length(Rooms) < Options.Rooms) and (Tries < 600) do
    begin
      Inc(Tries);
      { Mostly medium rooms, now and then a big arena or a small closet }
      if Rnd.Chance(0.2) then
      begin
        W := Rnd.Range(9, 13);
        H := Rnd.Range(8, 12);
      end else
      begin
        W := Rnd.Range(4, 8);
        H := Rnd.Range(4, 8);
      end;
      X := Rnd.Range(2, Level.Width - W - 2);
      Y := Rnd.Range(2, Level.Height - H - 2);
      Ok := True;
      for I := 0 to High(Rooms) do
        if (X < Rooms[I].X + Rooms[I].W + 3) and (Rooms[I].X < X + W + 3) and
           (Y < Rooms[I].Y + Rooms[I].H + 3) and (Rooms[I].Y < Y + H + 3) then
        begin
          Ok := False;
          Break;
        end;
      if not Ok then
        Continue;
      R := Default(TGenRoom);
      R.X := X; R.Y := Y; R.W := W; R.H := H;
      R.Theme := Rnd.Int(Length(LevelThemes));
      R.Sky := Rnd.Chance(0.22);
      SetLength(Rooms, Length(Rooms) + 1);
      Rooms[High(Rooms)] := R;
    end;
  end;

  procedure ConnectRooms;
  var
    InTree: array of Boolean;
    I, J, K, BestA, BestB, BestD, Extra: Integer;
    L: TLink;
    Linked: Boolean;
  begin
    { Prim's minimum spanning tree over the room centers }
    SetLength(InTree, Length(Rooms));
    InTree[0] := True;
    for K := 1 to High(Rooms) do
    begin
      BestD := MaxInt;
      BestA := -1;
      BestB := -1;
      for I := 0 to High(Rooms) do
        if InTree[I] then
          for J := 0 to High(Rooms) do
            if (not InTree[J]) and (RoomDist(I, J) < BestD) then
            begin
              BestD := RoomDist(I, J);
              BestA := I;
              BestB := J;
            end;
      InTree[BestB] := True;
      L.A := BestA;
      L.B := BestB;
      SetLength(Links, Length(Links) + 1);
      Links[High(Links)] := L;
    end;
    { Loops: short extra links between rooms not yet linked }
    Extra := Max(1, Length(Rooms) div 3);
    for I := 0 to High(Rooms) do
      for J := I + 1 to High(Rooms) do
      begin
        if Extra = 0 then
          Break;
        Linked := False;
        for K := 0 to High(Links) do
          if ((Links[K].A = I) and (Links[K].B = J)) or ((Links[K].A = J) and (Links[K].B = I)) then
            Linked := True;
        if (not Linked) and (RoomDist(I, J) < Level.Width div 2) and Rnd.Chance(0.35) then
        begin
          L.A := I;
          L.B := J;
          SetLength(Links, Length(Links) + 1);
          Links[High(Links)] := L;
          Dec(Extra);
          Inc(Report.Loops);
        end;
      end;
  end;

  { Rooms get floors outward from the start, each link a moderate climb }
  procedure AssignHeights;
  var
    Done: array of Boolean;
    Changed: Boolean;
    I, K, Other: Integer;
  begin
    SetLength(Done, Length(Rooms));
    Rooms[0].Floor := 0;
    Rooms[0].Depth := 0;
    Done[0] := True;
    repeat
      Changed := False;
      for K := 0 to High(Links) do
        for I := 0 to 1 do
        begin
          if I = 0 then
          begin
            if not (Done[Links[K].A] and not Done[Links[K].B]) then
              Continue;
            Other := Links[K].B;
            Rooms[Other].Floor := EnsureRange(Rooms[Links[K].A].Floor + Rnd.Range(-3, 3) * LevelHeightStep, -96, 192);
            Rooms[Other].Depth := Rooms[Links[K].A].Depth + 1;
          end else
          begin
            if not (Done[Links[K].B] and not Done[Links[K].A]) then
              Continue;
            Other := Links[K].A;
            Rooms[Other].Floor := EnsureRange(Rooms[Links[K].B].Floor + Rnd.Range(-3, 3) * LevelHeightStep, -96, 192);
            Rooms[Other].Depth := Rooms[Links[K].B].Depth + 1;
          end;
          Done[Other] := True;
          Changed := True;
        end;
    until not Changed;
    for I := 0 to High(Rooms) do
    begin
      { Higher ceilings for bigger rooms and skies }
      Rooms[I].Ceil := Rooms[I].Floor + Round16(160 + 12 * Min(Rooms[I].W, Rooms[I].H) + Rnd.Range(0, 3) * 16);
      if Rooms[I].Sky then
        Rooms[I].Ceil := Rooms[I].Ceil + 96;
    end;
  end;

  procedure CarveRooms;
  var
    I, X, Y: Integer;
    C: PLevelCell;
  begin
    for I := 0 to High(Rooms) do
      for Y := Rooms[I].Y to Rooms[I].Y + Rooms[I].H - 1 do
        for X := Rooms[I].X to Rooms[I].X + Rooms[I].W - 1 do
        begin
          Level.SetOpen(X, Y, Rooms[I].Floor, Rooms[I].Ceil, Rooms[I].Theme);
          C := Level.Cell(X, Y);
          C^.Sky := Rooms[I].Sky;
          InRoom[Y * Level.Width + X] := I;
        end;
  end;

  { A 2-cell corridor from room A to room B: along X then Y (or Y then X),
    climbing at most one step per cell }
  procedure CarveCorridor(const A, B: Integer);
  var
    Path: specialize TList<TPoint>;
    X, Y, TX, TY, I, Floor, Remaining, CellsLeft, Step, OutCount, Theme, Headroom: Integer;
    XFirst: Boolean;
    P: TPoint;
    C: PLevelCell;

    procedure Add(const PX, PY: Integer);
    begin
      Path.Add(Point(PX, PY));
    end;

    procedure OpenCorridorCell(const CX, CY, F: Integer);
    begin
      if (not Level.InGrid(CX, CY)) or (CX < 1) or (CY < 1) or (CX >= Level.Width - 1) or
         (CY >= Level.Height - 1) then
        Exit;
      if CellRoom(CX, CY) >= 0 then
        Exit;
      C := Level.Cell(CX, CY);
      if not C^.Solid then
        Exit; { another corridor was here first }
      Level.SetOpen(CX, CY, F, F + Headroom, Theme);
    end;

  begin
    Path := specialize TList<TPoint>.Create;
    try
      X := RoomCenterX(A);
      Y := RoomCenterY(A);
      TX := RoomCenterX(B);
      TY := RoomCenterY(B);
      XFirst := Rnd.Chance(0.5);
      Add(X, Y);
      while (X <> TX) or (Y <> TY) do
      begin
        if XFirst and (X <> TX) or (Y = TY) then
          X := X + Sign(TX - X)
        else
          Y := Y + Sign(TY - Y);
        Add(X, Y);
      end;
      { Cells outside both rooms: the climb is spread over them }
      OutCount := 0;
      for P in Path do
        if CellRoom(P.X, P.Y) < 0 then
          Inc(OutCount);
      Theme := Rnd.Int(Length(LevelThemes));
      { One low ceiling along the corridor (it follows the floor's steps) }
      Headroom := 112 + 16 * Rnd.Int(2);
      Floor := Rooms[A].Floor;
      CellsLeft := OutCount + 1;
      for I := 0 to Path.Count - 1 do
      begin
        P := Path[I];
        if CellRoom(P.X, P.Y) >= 0 then
          Continue;
        Remaining := Rooms[B].Floor - Floor;
        Step := EnsureRange(Round16(Remaining / CellsLeft), -LevelHeightStep, LevelHeightStep);
        Floor := Floor + Step;
        Dec(CellsLeft);
        OpenCorridorCell(P.X, P.Y, Floor);
        { Second lane: beside the path (also at the corner, both sides) }
        if (I > 0) and (Path[I - 1].Y = P.Y) then
          OpenCorridorCell(P.X, P.Y + 1, Floor)
        else
          OpenCorridorCell(P.X + 1, P.Y, Floor);
      end;
    finally
      Path.Free;
    end;
  end;

  procedure Furnish;
  var
    I, X, Y, PX, PY, PW, PH: Integer;
    C: PLevelCell;
  begin
    for I := 0 to High(Rooms) do
    begin
      { Pillars for cover in big rooms, away from the walls (entrances) }
      if (Rooms[I].W >= 8) and (Rooms[I].H >= 8) and Rnd.Chance(0.7) then
        for Y := Rooms[I].Y + 2 to Rooms[I].Y + Rooms[I].H - 3 do
          for X := Rooms[I].X + 2 to Rooms[I].X + Rooms[I].W - 3 do
            if ((X - Rooms[I].X) mod 3 = 2) and ((Y - Rooms[I].Y) mod 3 = 2) then
              Level.Cell(X, Y)^.Solid := True;
      { A raised platform with a step ring (only where no pillars stand) }
      if (Rooms[I].W >= 6) and (Rooms[I].H >= 6) and Rnd.Chance(0.5) then
      begin
        PW := Rnd.Range(2, Rooms[I].W div 3);
        PH := Rnd.Range(2, Rooms[I].H div 3);
        PX := Rooms[I].X + Rnd.Range(1, Rooms[I].W - PW - 1);
        PY := Rooms[I].Y + Rnd.Range(1, Rooms[I].H - PH - 1);
        for Y := PY - 1 to PY + PH do
          for X := PX - 1 to PX + PW do
          begin
            C := Level.Cell(X, Y);
            if C^.Solid or (CellRoom(X, Y) <> I) then
              Continue;
            if (X >= PX) and (X < PX + PW) and (Y >= PY) and (Y < PY + PH) then
              C^.Floor := Rooms[I].Floor + 2 * LevelHeightStep
            else
              C^.Floor := Rooms[I].Floor + LevelHeightStep;
          end;
      end;
    end;
  end;

  { Fix steps that are too high (corridors crossing): pull unreachable
    cells towards a reachable neighbour; wall up what still can't be
    reached }
  procedure MakeReachable(const SX, SY: Integer);
  var
    Iter, I, X, Y, D, NX, NY: Integer;
    C, N: PLevelCell;
    Changed: Boolean;
  begin
    SetLength(Reached, Level.Width * Level.Height);
    for Iter := 1 to 60 do
    begin
      FloodReach(Level, SX, SY, Reached);
      Changed := False;
      for I := 0 to High(Reached) do
      begin
        X := I mod Level.Width;
        Y := I div Level.Width;
        C := Level.Cell(X, Y);
        if Reached[I] or C^.Solid then
          Continue;
        for D := 0 to 3 do
        begin
          NX := X + DX[D];
          NY := Y + DY[D];
          if not Level.InGrid(NX, NY) or not Reached[NY * Level.Width + NX] then
            Continue;
          N := Level.Cell(NX, NY);
          C^.Floor := EnsureRange(C^.Floor, N^.Floor - LevelHeightStep, N^.Floor + LevelHeightStep);
          C^.Ceil := Max(C^.Ceil, C^.Floor + 112);
          if N^.Ceil < C^.Floor + LevelMinHeadroom then
            N^.Ceil := C^.Floor + LevelMinHeadroom + 32;
          Inc(Report.FixedCells);
          Changed := True;
          Break;
        end;
      end;
      if not Changed then
        Break;
    end;
    FloodReach(Level, SX, SY, Reached);
    for I := 0 to High(Reached) do
      if (not Reached[I]) and not Level.Cell(I mod Level.Width, I div Level.Width)^.Solid then
      begin
        Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := True;
        Inc(Report.WalledCells);
      end;
  end;

  { A random free floor cell of a room (reachable, no entity yet) }
  function FreeCell(const R: Integer; out CX, CY: Integer; const Margin: Integer = 1): Boolean;
  var
    T: Integer;
  begin
    for T := 1 to 40 do
    begin
      CX := Rooms[R].X + Rnd.Range(Min(Margin, Rooms[R].W div 2), Max(Min(Margin, Rooms[R].W div 2), Rooms[R].W - 1 - Margin));
      CY := Rooms[R].Y + Rnd.Range(Min(Margin, Rooms[R].H div 2), Max(Min(Margin, Rooms[R].H div 2), Rooms[R].H - 1 - Margin));
      if Level.Cell(CX, CY)^.Solid or not Reached[CY * Level.Width + CX] then
        Continue;
      if Level.EntityAtCell(CX, CY) >= 0 then
        Continue;
      Exit(True);
    end;
    Result := False;
  end;

  function AngleTo(const FromX, FromY, ToX, ToY: Integer): Single;
  begin
    if (FromX = ToX) and (FromY = ToY) then
      Exit(0);
    Result := Round(RadToDeg(ArcTan2(ToY - FromY, ToX - FromX)) / 45) * 45;
    if Result < 0 then
      Result := Result + 360;
  end;

  procedure AddItem(const AClass: String; const R: Integer);
  var
    CX, CY: Integer;
  begin
    if FreeCell(R, CX, CY) then
    begin
      Level.AddEntityAtCell(AClass, CX, CY);
      Inc(Report.Items);
    end;
  end;

  procedure Populate(const StartRoom, ExitRoom: Integer);
  const
    Weapons: array[0..6] of String = ('weapon_shotgun', 'weapon_supershotgun', 'weapon_machinegun',
      'weapon_grenadelauncher', 'weapon_chaingun', 'weapon_rocketlauncher', 'weapon_hyperblaster');
    WeaponAmmo: array[0..6] of String = ('ammo_shells', 'ammo_shells', 'ammo_bullets',
      'ammo_grenades', 'ammo_bullets', 'ammo_rockets', 'ammo_cells');
  var
    Order: array of Integer;
    I, J, K, R, CX, CY, Count, NextWeapon, LastWeapon: Integer;
    Monster: String;
    E: TLevelEntity;
    MaxDepth: Integer;

    function PickMonster(const Rank: Single; const Big: Boolean): String;
    var
      Pick: Single;
    begin
      Pick := Rnd.Float;
      if Rank < 0.3 then
      begin
        if Pick < 0.6 then Result := 'monster_soldier_light' else Result := 'monster_soldier';
      end else
      if Rank < 0.6 then
      begin
        if Pick < 0.3 then Result := 'monster_soldier'
        else if Pick < 0.55 then Result := 'monster_soldier_ss'
        else if Pick < 0.85 then Result := 'monster_infantry'
        else Result := 'monster_flyer';
      end else
      begin
        if Pick < 0.2 then Result := 'monster_infantry'
        else if Pick < 0.4 then Result := 'monster_gunner'
        else if Pick < 0.55 then Result := 'monster_berserk'
        else if Pick < 0.7 then Result := 'monster_parasite'
        else if Pick < 0.85 then Result := 'monster_flyer'
        else if Big then Result := 'monster_tank'
        else Result := 'monster_soldier_ss';
      end;
    end;

  begin
    { Rooms in the order the player meets them }
    MaxDepth := 1;
    for I := 0 to High(Rooms) do
      MaxDepth := Max(MaxDepth, Rooms[I].Depth);
    SetLength(Order, Length(Rooms));
    for I := 0 to High(Rooms) do
    begin
      Order[I] := I;
      Rooms[I].Rank := Rooms[I].Depth / MaxDepth;
    end;
    for I := 0 to High(Order) do
      for J := I + 1 to High(Order) do
        if Rooms[Order[J]].Depth < Rooms[Order[I]].Depth then
        begin
          K := Order[I];
          Order[I] := Order[J];
          Order[J] := K;
        end;

    { The player starts facing the way out of the start room }
    CX := RoomCenterX(StartRoom);
    CY := RoomCenterY(StartRoom);
    if Level.Cell(CX, CY)^.Solid or not FreeCell(StartRoom, CX, CY) then
      FreeCell(StartRoom, CX, CY, 0);
    J := -1;
    for K := 0 to High(Links) do
      if Links[K].A = StartRoom then
        J := Links[K].B
      else
      if Links[K].B = StartRoom then
        J := Links[K].A;
    if J >= 0 then
      Level.AddEntityAtCell('info_player_start', CX, CY, AngleTo(CX, CY, RoomCenterX(J), RoomCenterY(J)))
    else
      Level.AddEntityAtCell('info_player_start', CX, CY);
    AddItem('item_armor_shard', StartRoom);

    NextWeapon := 0;
    LastWeapon := -1;
    for I := 0 to High(Order) do
    begin
      R := Order[I];
      if (R = StartRoom) or Rooms[R].Secret then
        Continue;
      { A weapon every room or so, strongest last, with ammo from then on }
      if (NextWeapon <= High(Weapons)) and (Rooms[R].Rank >= NextWeapon / (Length(Weapons) + 1)) then
      begin
        AddItem(Weapons[NextWeapon], R);
        LastWeapon := NextWeapon;
        Inc(NextWeapon);
      end;
      if LastWeapon >= 0 then
        AddItem(WeaponAmmo[Rnd.Int(LastWeapon + 1)], R);
      { Monsters: more and tougher further on }
      Count := EnsureRange(Round(Rooms[R].W * Rooms[R].H / 14 * (0.6 + Rooms[R].Rank)), 1, 7);
      for J := 1 to Count do
      begin
        if not FreeCell(R, CX, CY) then
          Break;
        Monster := PickMonster(Rooms[R].Rank, (Rooms[R].W >= 8) and (Rooms[R].H >= 8));
        E := Level.AddEntityAtCell(Monster, CX, CY, AngleTo(CX, CY, RoomCenterX(R), RoomCenterY(R)) + 180);
        if E.Angle >= 360 then
          E.Angle := E.Angle - 360;
        Inc(Report.Monsters);
        { Some wait in ambush; extras only on medium / hard (not easy) }
        if Rnd.Chance(0.2) then
          E.SetKey('spawnflags', '1')
        else
        if (J > 2) and Rnd.Chance(0.5) then
          E.SetKey('spawnflags', '256');
      end;
      { Health after the fight, armor now and then; barrels to shoot }
      if Rnd.Chance(0.7) then
        AddItem('item_health', R);
      if Rnd.Chance(0.35) then
        AddItem('item_health_small', R);
      if Rnd.Chance(0.25) then
        if Rooms[R].Rank < 0.5 then
          AddItem('item_armor_jacket', R)
        else
          AddItem('item_armor_combat', R);
      if (Rooms[R].W >= 6) and Rnd.Chance(0.3) then
        AddItem('misc_explobox', R);
    end;
    { Before the exit: a big health }
    AddItem('item_health_large', ExitRoom);
  end;

  procedure AddLights;
  var
    I, X, Y, Step: Integer;
    C: PLevelCell;
    Count: Integer;
  begin
    for I := 0 to High(Rooms) do
    begin
      Step := 4;
      Y := Rooms[I].Y + 1;
      while Y < Rooms[I].Y + Rooms[I].H do
      begin
        X := Rooms[I].X + 1;
        while X < Rooms[I].X + Rooms[I].W do
        begin
          C := Level.Cell(X, Y);
          if not C^.Solid then
            Level.AddEntityAtCell('light', X, Y).SetKey('light',
              IntToStr(Round16(Rooms[I].Ceil - Rooms[I].Floor + 180)));
          Inc(X, Step);
        end;
        Inc(Y, Step);
      end;
    end;
    { Corridors: a dimmer light every few cells }
    Count := 0;
    for Y := 1 to Level.Height - 2 do
      for X := 1 to Level.Width - 2 do
      begin
        C := Level.Cell(X, Y);
        if C^.Solid or (CellRoom(X, Y) >= 0) then
          Continue;
        Inc(Count);
        if (Count mod 6 = 0) and (Level.EntityAtCell(X, Y) < 0) then
          Level.AddEntityAtCell('light', X, Y).SetKey('light', '220');
      end;
  end;

  { A small secret room off a room, through a 1-wide passage, with a
    reward and a trigger counting the secret }
  function AddSecret(const StartRoom, ExitRoom: Integer): Integer;
  var
    T, R, D, X, Y, I, L: Integer;
    Ok: Boolean;
    S: TGenRoom;
    E: TLevelEntity;
    Org: TVector3;
  begin
    Result := -1;
    for T := 1 to 60 do
    begin
      R := Rnd.Int(Length(Rooms));
      if (R = StartRoom) or (R = ExitRoom) then
        Continue;
      D := Rnd.Int(4);
      S := Default(TGenRoom);
      S.W := 3;
      S.H := 3;
      L := 3; { passage length }
      case D of
        0: begin S.X := Rooms[R].X + Rooms[R].W + L; S.Y := Rooms[R].Y + Rooms[R].H div 2 - 1; end;
        1: begin S.X := Rooms[R].X - L - S.W; S.Y := Rooms[R].Y + Rooms[R].H div 2 - 1; end;
        2: begin S.X := Rooms[R].X + Rooms[R].W div 2 - 1; S.Y := Rooms[R].Y + Rooms[R].H + L; end;
        else begin S.X := Rooms[R].X + Rooms[R].W div 2 - 1; S.Y := Rooms[R].Y - L - S.H; end;
      end;
      { The room and its passage must be untouched rock }
      Ok := (S.X >= 2) and (S.Y >= 2) and (S.X + S.W < Level.Width - 2) and (S.Y + S.H < Level.Height - 2);
      if Ok then
        for Y := S.Y - 1 to S.Y + S.H do
          for X := S.X - 1 to S.X + S.W do
            if not Level.Cell(X, Y)^.Solid then
              Ok := False;
      if not Ok then
        Continue;
      for I := 1 to L do
      begin
        case D of
          0: begin X := Rooms[R].X + Rooms[R].W - 1 + I; Y := S.Y + 1; end;
          1: begin X := Rooms[R].X - I; Y := S.Y + 1; end;
          2: begin X := S.X + 1; Y := Rooms[R].Y + Rooms[R].H - 1 + I; end;
          else begin X := S.X + 1; Y := Rooms[R].Y - I; end;
        end;
        if not Level.Cell(X, Y)^.Solid then
          Ok := False;
      end;
      if not Ok then
        Continue;
      { Carve: a low crawlway (dark), then the room }
      for I := 1 to L do
      begin
        case D of
          0: begin X := Rooms[R].X + Rooms[R].W - 1 + I; Y := S.Y + 1; end;
          1: begin X := Rooms[R].X - I; Y := S.Y + 1; end;
          2: begin X := S.X + 1; Y := Rooms[R].Y + Rooms[R].H - 1 + I; end;
          else begin X := S.X + 1; Y := Rooms[R].Y - I; end;
        end;
        Level.SetOpen(X, Y, Rooms[R].Floor, Rooms[R].Floor + 80, 3);
      end;
      S.Floor := Rooms[R].Floor;
      S.Ceil := S.Floor + 128;
      S.Theme := 3;
      S.Secret := True;
      S.Depth := Rooms[R].Depth + 1;
      SetLength(Rooms, Length(Rooms) + 1);
      Rooms[High(Rooms)] := S;
      Result := High(Rooms);
      for Y := S.Y to S.Y + S.H - 1 do
        for X := S.X to S.X + S.W - 1 do
        begin
          Level.SetOpen(X, Y, S.Floor, S.Ceil, S.Theme);
          InRoom[Y * Level.Width + X] := Result;
        end;
      Level.AddEntityAtCell('light', S.X + 1, S.Y + 1).SetKey('light', '200');
      { The reward and the secret trigger (a box over the room) }
      if Rnd.Chance(0.5) then
        Level.AddEntityAtCell('item_quad', S.X + 1, S.Y + 1)
      else
        Level.AddEntityAtCell('item_health_mega', S.X + 1, S.Y + 1);
      Org := Level.CellFloorCenter(S.X + 1, S.Y + 1);
      E := Level.AddEntity('trigger_once', Org);
      E.SetKey('target', 'secret' + IntToStr(Result));
      E.SetKey('mins', '-80 -80 0');
      E.SetKey('maxs', '80 80 96');
      E := Level.AddEntity('target_secret', Org + Vector3(0, 0, 32));
      E.SetKey('targetname', 'secret' + IntToStr(Result));
      E.SetKey('message', 'You found a secret area!');
      Exit;
    end;
  end;

  procedure AddExit(const ExitRoom: Integer);
  var
    E: TLevelEntity;
    CX, CY: Integer;
    Org: TVector3;
  begin
    { The exit: a trigger over the middle of the exit room, to the next
      random level }
    CX := RoomCenterX(ExitRoom);
    CY := RoomCenterY(ExitRoom);
    Org := Level.CellFloorCenter(CX, CY);
    E := Level.AddEntity('trigger_once', Org);
    E.SetKey('target', 'exit');
    E.SetKey('mins', '-48 -48 0');
    E.SetKey('maxs', '48 48 96');
    E := Level.AddEntity('target_changelevel', Org + Vector3(0, 0, 32));
    E.SetKey('targetname', 'exit');
    E.SetKey('map', RandomMapName(Seed + 1));
    E.SetKey('message', 'Exit: on to the next level');
    Level.AddEntityAtCell('light', CX, CY).SetKey('light', '400');
  end;

var
  I, StartRoom, ExitRoom, CX, CY, Best: Integer;
begin
  Report := Default(TLevelGenReport);
  Rnd.State := SeedState(Seed);
  for I := 1 to 8 do
    Rnd.Next;
  Level := TQuakeLevel.Create(Options.Width, Options.Height);
  Result := Level;
  Level.Name := RandomMapName(Seed);
  Level.Seed := Seed;
  Level.Message := 'Random level ' + IntToStr(Seed);
  SetLength(InRoom, Level.Width * Level.Height);
  for I := 0 to High(InRoom) do
    InRoom[I] := -1;

  PlaceRooms;
  if Length(Rooms) < 2 then
    raise Exception.Create('Level generator could not place rooms');
  ConnectRooms;
  AssignHeights;
  CarveRooms;
  for I := 0 to High(Links) do
    CarveCorridor(Links[I].A, Links[I].B);
  Furnish;

  { Start in room 0 (the root of the heights); the exit is the deepest room }
  StartRoom := 0;
  ExitRoom := 1;
  Best := -1;
  for I := 1 to High(Rooms) do
    if Rooms[I].Depth * 100 + RoomDist(0, I) > Best then
    begin
      Best := Rooms[I].Depth * 100 + RoomDist(0, I);
      ExitRoom := I;
    end;
  Report.SecretRoom := AddSecret(StartRoom, ExitRoom);
  Level.Normalize;
  CX := RoomCenterX(StartRoom);
  CY := RoomCenterY(StartRoom);
  if Level.Cell(CX, CY)^.Solid then
    CX := Rooms[StartRoom].X;
  MakeReachable(CX, CY);
  Level.Normalize;
  FloodReach(Level, CX, CY, Reached);

  AddLights;
  Populate(StartRoom, ExitRoom);
  AddExit(ExitRoom);

  Report.Rooms := Length(Rooms);
  Report.Links := Length(Links);
  Report.OpenCells := Level.OpenCellCount;
  Report.StartRoom := StartRoom;
  Report.ExitRoom := ExitRoom;
end;

function GenerateLevel(const Seed: Cardinal): TQuakeLevel;
var
  Report: TLevelGenReport;
begin
  Result := GenerateLevel(Seed, DefaultLevelGenOptions, Report);
end;

function LevelFileUrl(const Name: String): String;
begin
  Result := 'castle-config:/levels/' + LowerCase(Name) + '.json';
end;

{ maps/rand<seed>.bsp: generate it; maps/<name>.bsp: a level saved by the
  level editor (castle-config:/levels/<name>.json) }
function GenerateMissingMap(const MapPath: String): Boolean;
var
  Name: String;
  Seed: Cardinal;
  Level: TQuakeLevel;
  Report: TLevelGenReport;
begin
  Result := False;
  Name := LowerCase(ChangeFileExt(ExtractFileName(MapPath), ''));
  Level := nil;
  try
    if IsRandomMapName(Name, Seed) then
    begin
      Level := GenerateLevel(Seed, DefaultLevelGenOptions, Report);
      WritelnLog('QuakeLevelGen', 'Generated %s: %d rooms, %d links (%d loops), %d open cells (%d fixed, %d walled), %d monsters, %d items, secret room %d',
        [Name, Report.Rooms, Report.Links, Report.Loops, Report.OpenCells, Report.FixedCells,
         Report.WalledCells, Report.Monsters, Report.Items, Report.SecretRoom]);
    end else
    if UriExists(LevelFileUrl(Name)) = ueFile then
    begin
      Level := TQuakeLevel.Create(3, 3);
      Level.LoadFromFile(LevelFileUrl(Name));
      Level.Name := Name;
    end else
      Exit;
    RegisterLevelMap(Level);
    Result := True;
  except
    on E: Exception do
      WritelnWarning('QuakeLevelGen', 'Could not make map "%s": %s', [Name, E.Message]);
  end;
  Level.Free;
end;

initialization
  MissingMapHook := @GenerateMissingMap;
end.
