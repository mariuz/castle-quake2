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
    { An ellipse in its rectangle, the edges smoothed with diagonal walls }
    Round: Boolean;
    { Steps from the start room in the room graph, and 0..1 along the way }
    Depth: Integer;
    Rank: Single;
  end;

  TLevelGenReport = record
    Rooms, Links, Loops, OpenCells, FixedCells, WalledCells, Monsters, Items, Doors, Pools, Lifts, Switches: Integer;
    SlimePools, KeyDoors, Teleporters, LavaPools, Ladders, OutdoorRooms, Ramps, Windows, Diagonals, RoundRooms: Integer;
    { Rooms whose extra monsters appear when the player walks in, and those monsters }
    Ambushes, AmbushMonsters: Integer;
    { Rooms whose lights flicker or pulse (Quake 2 light styles) }
    FlickeringRooms: Integer;
    StartRoom, ExitRoom, SecretRoom: Integer;
    { The secret door's cell (-1 without a secret room) }
    SecretDoorX, SecretDoorY: Integer;
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

type
  TLevelKeySet = set of Byte;

{ Can (TX, TY) be reached on foot from (X, Y) with the doors of these keys
  and the switch doors shut? }
function ReachableWithLockedDoors(const Level: TQuakeLevel; const X, Y, TX, TY: Integer;
  const LockedKeys: TLevelKeySet = [1, 2]): Boolean;

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

function CanStepFloors(const A, B: PLevelCell): Boolean; forward;

function CanStep(const A, B: PLevelCell): Boolean;
var
  LA, LB: TLevelCell;
begin
  if A^.Solid or B^.Solid then
    Exit(False);
  if CanStepFloors(A, B) then
    Exit(True);
  { A lift joins its floor and its top: try the cell as if at its top }
  LA := A^;
  LB := B^;
  if A^.Lift then
  begin
    LA.Floor := A^.LiftTop;
    LA.Wet := False;
    if CanStepFloors(@LA, B) then
      Exit(True);
  end;
  if B^.Lift then
  begin
    LB.Floor := B^.LiftTop;
    LB.Wet := False;
    if CanStepFloors(A, @LB) then
      Exit(True);
    if A^.Lift and CanStepFloors(@LA, @LB) then
      Exit(True);
  end;
  Result := False;
end;

function CanStepFloors(const A, B: PLevelCell): Boolean;
var
  Lo, Hi: PLevelCell;
begin
  Result := False;
  if A^.Solid or B^.Solid or (Min(A^.Ceil, B^.Ceil) - Max(A^.Floor, B^.Floor) < LevelMinHeadroom) then
    Exit;
  if Abs(A^.Floor - B^.Floor) <= LevelHeightStep then
    Exit(True);
  { Out of water the player swims up to the surface and climbs out
    (PM_CheckWaterJump): a ledge at most a step above the water }
  if A^.Floor < B^.Floor then
  begin
    Lo := A;
    Hi := B;
  end else
  begin
    Lo := B;
    Hi := A;
  end;
  Result := CellHasWater(Lo) and (Hi^.Floor <= Lo^.Water + LevelHeightStep) and
    (not CellHasWater(Hi) or (Hi^.Water >= Lo^.Water));
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
        { A ladder joins its cell and the step it climbs, both ways }
        if CanStep(Level.Cell(CX, CY), Level.Cell(NX, NY)) or
           (Level.Cell(CX, CY)^.Ladder and (Level.LadderDir(CX, CY) = D)) or
           (Level.Cell(NX, NY)^.Ladder and (Level.LadderDir(NX, NY) = D xor 1)) then
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
    if (not Reached[I]) and not Level.Cell(I mod Level.Width, I div Level.Width)^.Solid and
       not Level.Cell(I mod Level.Width, I div Level.Width)^.Window then
      Inc(Result);
end;

function ReachableWithLockedDoors(const Level: TQuakeLevel; const X, Y, TX, TY: Integer;
  const LockedKeys: TLevelKeySet): Boolean;
var
  Reached: array of Boolean;
  Locked: specialize TList<Integer>;
  I: Integer;
begin
  Locked := specialize TList<Integer>.Create;
  try
    for I := 0 to Level.Width * Level.Height - 1 do
      if (not Level.Cell(I mod Level.Width, I div Level.Width)^.Solid) and
         ((Level.Cell(I mod Level.Width, I div Level.Width)^.Key in LockedKeys - [0]) or
          (Level.Cell(I mod Level.Width, I div Level.Width)^.Channel > 0) and
          Level.Cell(I mod Level.Width, I div Level.Width)^.Door) then
      begin
        Locked.Add(I);
        Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := True;
      end;
    SetLength(Reached, Level.Width * Level.Height);
    FloodReach(Level, X, Y, Reached);
    Result := Reached[TY * Level.Width + TX];
  finally
    for I in Locked do
      Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := False;
    Locked.Free;
  end;
end;

function Round16(const V: Single): Integer;
begin
  Result := Round(V / LevelHeightStep) * LevelHeightStep;
end;

function GenerateLevel(const Seed: Cardinal; const Options: TLevelGenOptions;
  out Report: TLevelGenReport): TQuakeLevel;
var
  Rnd: TGenRandom;
  { Random state of the ambushes, apart from Rnd, so adding them changes
    nothing else of a seed's level }
  AmbushState: Cardinal;
  { Same for the light styles of the rooms }
  LightStyleState: Cardinal;
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
      R.Theme := IndoorTheme(Rnd.Int(IndoorThemeCount));
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
    I, K, Other, Climb: Integer;
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
          { Mostly a few steps; now and then a big height, reached by a lift }
          if Rnd.Chance(0.2) then
            Climb := (2 * Rnd.Int(2) - 1) * Rnd.Range(6, 9) * LevelHeightStep
          else
            Climb := Rnd.Range(-3, 3) * LevelHeightStep;
          if I = 0 then
          begin
            if not (Done[Links[K].A] and not Done[Links[K].B]) then
              Continue;
            Other := Links[K].B;
            Rooms[Other].Floor := EnsureRange(Rooms[Links[K].A].Floor + Climb, -128, 288);
            Rooms[Other].Depth := Rooms[Links[K].A].Depth + 1;
          end else
          begin
            if not (Done[Links[K].B] and not Done[Links[K].A]) then
              Continue;
            Other := Links[K].A;
            Rooms[Other].Floor := EnsureRange(Rooms[Links[K].B].Floor + Climb, -128, 288);
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
    begin
      { A round room in one big room in four (by seed and number, not the
        random generator, so the other rooms stay the same) }
      Rooms[I].Round := (Rooms[I].W >= 7) and (Rooms[I].H >= 7) and ((Seed + Cardinal(I)) mod 4 = 2);
      if Rooms[I].Round then
        Inc(Report.RoundRooms);
      for Y := Rooms[I].Y to Rooms[I].Y + Rooms[I].H - 1 do
        for X := Rooms[I].X to Rooms[I].X + Rooms[I].W - 1 do
        begin
          if Rooms[I].Round and not Level.InEllipse(X, Y, Rooms[I].X, Rooms[I].Y,
             Rooms[I].X + Rooms[I].W - 1, Rooms[I].Y + Rooms[I].H - 1) then
            Continue;
          Level.SetOpen(X, Y, Rooms[I].Floor, Rooms[I].Ceil, Rooms[I].Theme);
          C := Level.Cell(X, Y);
          C^.Sky := Rooms[I].Sky;
          InRoom[Y * Level.Width + X] := I;
        end;
    end;
  end;

  { A 2-cell corridor from room A to room B: along X then Y (or Y then X),
    climbing at most one step per cell }
  procedure CarveCorridor(const A, B: Integer);
  var
    Path: specialize TList<TPoint>;
    X, Y, TX, TY, I, Floor, Remaining, CellsLeft, Step, OutCount, Theme, Headroom: Integer;
    OutIndex, LiftIndex, LowFloor, HighFloor: Integer;
    XFirst, DoorPlaced, NeedLift, UseLadder: Boolean;
    P, Lane: TPoint;
    C, D2: PLevelCell;

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

    { A lift cell: from the low floor up to the high one }
    procedure OpenLiftCell(const CX, CY: Integer);
    begin
      if (not Level.InGrid(CX, CY)) or (CellRoom(CX, CY) >= 0) or not Level.Cell(CX, CY)^.Solid then
        Exit;
      OpenCorridorCell(CX, CY, LowFloor);
      C := Level.Cell(CX, CY);
      if C^.Solid then
        Exit;
      if UseLadder then
        { A ladder up the step to the high corridor cell (LadderDir) }
        C^.Ladder := True
      else
      begin
        C^.Lift := True;
        C^.LiftTop := HighFloor;
      end;
      C^.Ceil := HighFloor + Headroom;
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
      Theme := IndoorTheme(Rnd.Int(IndoorThemeCount));
      { One low ceiling along the corridor (it follows the floor's steps) }
      Headroom := 112 + 16 * Rnd.Int(2);
      Floor := Rooms[A].Floor;
      CellsLeft := OutCount + 1;
      DoorPlaced := not Rnd.Chance(0.4);
      { A big height (80+), or too high to climb in steps: a lift beside the
        lower room, the rest of the corridor at the higher floor }
      NeedLift := (OutCount >= 2) and ((Abs(Rooms[B].Floor - Rooms[A].Floor) >= 80) or
        (Abs(Rooms[B].Floor - Rooms[A].Floor) > LevelHeightStep * OutCount));
      LowFloor := Min(Rooms[A].Floor, Rooms[B].Floor);
      HighFloor := Max(Rooms[A].Floor, Rooms[B].Floor);
      if Rooms[A].Floor < Rooms[B].Floor then
        LiftIndex := 0
      else
        LiftIndex := OutCount - 1;
      UseLadder := False;
      if NeedLift then
      begin
        { Every other climb (by seed, not the random generator, so the
          layouts stay the same) is a ladder instead of a lift }
        UseLadder := (Seed + Cardinal(Report.Lifts + Report.Ladders)) mod 2 = 0;
        if UseLadder then
          Inc(Report.Ladders)
        else
          Inc(Report.Lifts);
        if LiftIndex = 0 then
          DoorPlaced := True; { the lift is where the door would be }
      end;
      OutIndex := -1;
      for I := 0 to Path.Count - 1 do
      begin
        P := Path[I];
        if CellRoom(P.X, P.Y) >= 0 then
          Continue;
        Inc(OutIndex);
        { Second lane: beside the path (also at the corner, both sides) }
        if (I > 0) and (Path[I - 1].Y = P.Y) then
          Lane := Point(P.X, P.Y + 1)
        else
          Lane := Point(P.X + 1, P.Y);
        if NeedLift then
        begin
          if OutIndex = LiftIndex then
          begin
            OpenLiftCell(P.X, P.Y);
            OpenLiftCell(Lane.X, Lane.Y);
          end else
          begin
            OpenCorridorCell(P.X, P.Y, HighFloor);
            OpenCorridorCell(Lane.X, Lane.Y, HighFloor);
          end;
          Floor := HighFloor;
        end else
        begin
          Remaining := Rooms[B].Floor - Floor;
          Step := EnsureRange(Round16(Remaining / CellsLeft), -LevelHeightStep, LevelHeightStep);
          Floor := Floor + Step;
          Dec(CellsLeft);
          OpenCorridorCell(P.X, P.Y, Floor);
          OpenCorridorCell(Lane.X, Lane.Y, Floor);
        end;
        { A door where the corridor leaves room A: both lanes, the same
          heights, straight on (not at a corner) }
        if (not DoorPlaced) and (I > 0) and (CellRoom(Path[I - 1].X, Path[I - 1].Y) = A) and
           (I + 1 < Path.Count) and ((Path[I - 1].X = Path[I + 1].X) or (Path[I - 1].Y = Path[I + 1].Y)) then
        begin
          DoorPlaced := True;
          C := Level.Cell(P.X, P.Y);
          D2 := Level.Cell(Lane.X, Lane.Y);
          if (not C^.Solid) and (not D2^.Solid) and (C^.Floor = D2^.Floor) and (C^.Ceil = D2^.Ceil) and
             (CellRoom(Lane.X, Lane.Y) < 0) then
          begin
            C^.Door := True;
            D2^.Door := True;
            Inc(Report.Doors);
          end;
        end;
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
      end else
      { Or a sunken pool to swim in (its edge a step above the water) }
      if (not Rooms[I].Sky) and (Rooms[I].W >= 5) and (Rooms[I].H >= 5) and Rnd.Chance(0.3) then
      begin
        PW := Rnd.Range(2, Rooms[I].W - 3);
        PH := Rnd.Range(2, Rooms[I].H - 3);
        PX := Rooms[I].X + Rnd.Range(1, Rooms[I].W - PW - 1);
        PY := Rooms[I].Y + Rnd.Range(1, Rooms[I].H - PH - 1);
        for Y := PY to PY + PH - 1 do
          for X := PX to PX + PW - 1 do
          begin
            C := Level.Cell(X, Y);
            if C^.Solid or (CellRoom(X, Y) <> I) then
              Continue;
            if (Seed + Cardinal(I)) mod 3 = 0 then
            begin
              { A third of the pools: a shallow slime pit (hurts) }
              C^.Floor := Rooms[I].Floor - 2 * LevelHeightStep;
              C^.Wet := True;
              C^.Slime := True;
              C^.Water := Rooms[I].Floor - 16;
            end else
            if (Seed + Cardinal(I)) mod 3 = 1 then
            begin
              { A third: a lava pit (hurts a lot; walk round it) }
              C^.Floor := Rooms[I].Floor - 2 * LevelHeightStep;
              C^.Wet := True;
              C^.Lava := True;
              C^.Water := Rooms[I].Floor - 16;
            end else
            begin
              C^.Floor := Rooms[I].Floor - 64;
              C^.Wet := True;
              C^.Water := Rooms[I].Floor - 8;
            end;
          end;
        if (Seed + Cardinal(I)) mod 3 = 0 then
          Inc(Report.SlimePools)
        else
        if (Seed + Cardinal(I)) mod 3 = 1 then
          Inc(Report.LavaPools);
        Inc(Report.Pools);
      end;
    end;
  end;

  { Big sky rooms become outdoor areas: rock or grass, rolling ground
    (TerrainHeight) that is flat at the room's edge (where corridors join)
    and rises at most a step per cell }
  procedure MakeOutdoor;
  var
    I, X, Y, D, Edge, Theme: Integer;
    C, N: PLevelCell;
    Changed: Boolean;
  begin
    for I := 0 to High(Rooms) do
    begin
      if (not Rooms[I].Sky) or (Rooms[I].W < 6) or (Rooms[I].H < 6) then
        Continue;
      if OutdoorThemeCount = 0 then
        Theme := Rooms[I].Theme
      else
        Theme := OutdoorTheme(Integer((Seed + Cardinal(I)) mod Cardinal(OutdoorThemeCount)));
      for Y := Rooms[I].Y to Rooms[I].Y + Rooms[I].H - 1 do
        for X := Rooms[I].X to Rooms[I].X + Rooms[I].W - 1 do
        begin
          C := Level.Cell(X, Y);
          if C^.Solid or (CellRoom(X, Y) <> I) then
            Continue;
          C^.Theme := Theme;
          if (C^.Floor <> Rooms[I].Floor) or C^.Wet then
            Continue;
          Edge := Min(Min(X - Rooms[I].X, Rooms[I].X + Rooms[I].W - 1 - X),
            Min(Y - Rooms[I].Y, Rooms[I].Y + Rooms[I].H - 1 - Y));
          C^.Floor := Rooms[I].Floor + Min(TerrainHeight(X, Y), Edge * LevelHeightStep);
          C^.Ceil := Max(C^.Ceil, C^.Floor + 160);
        end;
      { Walkable: lower cells more than a step above a room neighbour }
      repeat
        Changed := False;
        for Y := Rooms[I].Y to Rooms[I].Y + Rooms[I].H - 1 do
          for X := Rooms[I].X to Rooms[I].X + Rooms[I].W - 1 do
          begin
            C := Level.Cell(X, Y);
            if C^.Solid or C^.Wet or (CellRoom(X, Y) <> I) or (C^.Floor <= Rooms[I].Floor) then
              Continue;
            for D := 0 to 3 do
            begin
              N := Level.Cell(X + DX[D], Y + DY[D]);
              if (not N^.Solid) and (CellRoom(X + DX[D], Y + DY[D]) = I) and
                 (C^.Floor > N^.Floor + LevelHeightStep) then
              begin
                C^.Floor := N^.Floor + LevelHeightStep;
                Changed := True;
              end;
            end;
          end;
      until not Changed;
      Inc(Report.OutdoorRooms);
    end;
  end;

  { Diagonal walls across room corners (two rooms in three, 5 x 5 and up):
    a corner whose outer neighbours are all wall, so no corridor ends
    there }
  procedure CutRoomCorners;
  var
    I, K, X, Y, SX, SY: Integer;
    C: PLevelCell;
  begin
    for I := 0 to High(Rooms) do
    begin
      { Round rooms: every outer corner of their own cells }
      if Rooms[I].Round then
      begin
        for Y := Rooms[I].Y to Rooms[I].Y + Rooms[I].H - 1 do
          for X := Rooms[I].X to Rooms[I].X + Rooms[I].W - 1 do
          begin
            if CellRoom(X, Y) <> I then
              Continue;
            K := Level.DiagonalCornerFor(X, Y);
            if Level.CanCutCorner(X, Y, K) then
            begin
              Level.Cell(X, Y)^.Diagonal := K;
              Inc(Report.Diagonals);
            end;
          end;
        Continue;
      end;
      if Rooms[I].Secret or (Rooms[I].W < 5) or (Rooms[I].H < 5) or ((Seed + Cardinal(I)) mod 3 = 0) then
        Continue;
      for K := 0 to 3 do
      begin
        if K in [0, 3] then
        begin
          X := Rooms[I].X + Rooms[I].W - 1; SX := 1;
        end else
        begin
          X := Rooms[I].X; SX := -1;
        end;
        if K in [0, 1] then
        begin
          Y := Rooms[I].Y + Rooms[I].H - 1; SY := 1;
        end else
        begin
          Y := Rooms[I].Y; SY := -1;
        end;
        C := Level.Cell(X, Y);
        if C^.Solid or C^.Wet or C^.Door or C^.Lift or C^.Button or C^.Ladder or (CellRoom(X, Y) <> I) or
           not Level.Cell(X + SX, Y)^.Solid or not Level.Cell(X, Y + SY)^.Solid or
           not Level.Cell(X + SX, Y + SY)^.Solid then
          Continue;
        C^.Diagonal := K + 1;
        Inc(Report.Diagonals);
      end;
    end;
  end;

  { Steps become slopes: corridor cells and outdoor ground with a higher
    neighbour (at most LevelRampMaxRise up) are ramps }
  procedure AddRamps;
  var
    X, Y, R: Integer;
    C: PLevelCell;
  begin
    for Y := 1 to Level.Height - 2 do
      for X := 1 to Level.Width - 2 do
      begin
        C := Level.Cell(X, Y);
        if C^.Solid or C^.Wet or C^.Door or C^.Lift or C^.Button or C^.Ladder or (C^.Diagonal > 0) then
          Continue;
        R := CellRoom(X, Y);
        if (R >= 0) and not (Rooms[R].Sky and (Rooms[R].W >= 6) and (Rooms[R].H >= 6)) then
          Continue;
        C^.Ramp := True;
        if Level.RampDir(X, Y) < 0 then
          C^.Ramp := False
        else
          Inc(Report.Ramps);
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
      if Level.Cell(CX, CY)^.Solid or not Reached[CY * Level.Width + CX] or CellHasWater(Level.Cell(CX, CY)) or
         Level.Cell(CX, CY)^.Door or Level.Cell(CX, CY)^.Lift or Level.Cell(CX, CY)^.Button or
         Level.Cell(CX, CY)^.Ladder or (Level.Cell(CX, CY)^.Diagonal > 0) then
        Continue;
      if Level.EntityAtCell(CX, CY) >= 0 then
        Continue;
      Exit(True);
    end;
    Result := False;
  end;

  { The 8 cells around (CX, CY) are open, flat and no higher, without
    diagonal walls }
  function RoomyCell(const CX, CY: Integer): Boolean;
  var
    DX2, DY2: Integer;
    N: PLevelCell;
  begin
    for DY2 := -1 to 1 do
      for DX2 := -1 to 1 do
      begin
        N := Level.Cell(CX + DX2, CY + DY2);
        if N^.Solid or (N^.Diagonal > 0) or N^.Ramp or (N^.Floor > Level.Cell(CX, CY)^.Floor) then
          Exit(False);
      end;
    Result := True;
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

    { Quake 2's monster closets: extra monsters with spawnflag 2
      (TRIGGER_SPAWN: absent until used) and a trigger_once over the room,
      so they appear when the player walks in }
    procedure AddAmbush(const R: Integer);
    var
      MainState: Cardinal;
      N, K, AX, AY: Integer;
      A, B, Org, Half: TVector3;
      Name: String;
      Amb: TLevelEntity;
      Placed: Integer;
    begin
      MainState := Rnd.State;
      Rnd.State := AmbushState;
      try
        if not Rnd.Chance(0.4) then
          Exit;
        Name := 'ambush' + IntToStr(Report.Ambushes + 1);
        N := 1 + Rnd.Int(2);
        if Rooms[R].Rank > 0.6 then
          Inc(N);
        Placed := 0;
        for K := 1 to N do
        begin
          if not FreeCell(R, AX, AY) then
            Break;
          Amb := Level.AddEntityAtCell(PickMonster(Rooms[R].Rank, False), AX, AY,
            AngleTo(AX, AY, RoomCenterX(R), RoomCenterY(R)));
          Amb.SetKey('spawnflags', '2');
          Amb.SetKey('targetname', Name);
          Inc(Placed);
        end;
        if Placed = 0 then
          Exit;
        { The trigger: the room less one cell all round (the player is
          inside when it fires), from below the lowest floor to well above }
        A := Level.CellFloorCenter(Rooms[R].X, Rooms[R].Y);
        B := Level.CellFloorCenter(Rooms[R].X + Rooms[R].W - 1, Rooms[R].Y + Rooms[R].H - 1);
        Org := (A + B) / 2;
        Org.Z := Min(A.Z, B.Z);
        Half := Vector3(Max(Abs(B.X - A.X) / 2 - 32, 32), Max(Abs(B.Y - A.Y) / 2 - 32, 32), 0);
        Amb := Level.AddEntity('trigger_once', Org);
        Amb.SetKey('target', Name);
        Amb.SetKey('mins', Format('%d %d -64', [-Round(Half.X), -Round(Half.Y)]));
        Amb.SetKey('maxs', Format('%d %d 192', [Round(Half.X), Round(Half.Y)]));
        Inc(Report.Ambushes);
        Inc(Report.AmbushMonsters, Placed);
      finally
        AmbushState := Rnd.State;
        Rnd.State := MainState;
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
        { The tank's box is a whole cell wide: it needs open cells all round
          (a pillar or a diagonal wall next to it would hold it in solid) }
        if (Monster = 'monster_tank') and not RoomyCell(CX, CY) then
          Monster := 'monster_gunner';
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
      if (R <> ExitRoom) and (Rooms[R].Rank >= 0.25) and (Rooms[R].W * Rooms[R].H >= 16) then
        AddAmbush(R);
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
  const
    { Quake 2's light styles: flicker, fluorescent flicker, gentle pulse }
    RoomStyles: array[0..2] of Integer = (1, 10, 5);
  var
    I, X, Y, Step, Style: Integer;
    C: PLevelCell;
    Count: Integer;
    MainState: Cardinal;
    E: TLevelEntity;
  begin
    for I := 0 to High(Rooms) do
    begin
      { Some rooms' lights flicker or pulse (their own random state: the
        rest of the seed's level stays the same) }
      MainState := Rnd.State;
      Rnd.State := LightStyleState;
      Style := 0;
      if (I > 0) and Rnd.Chance(0.25) then
        Style := RoomStyles[Rnd.Int(Length(RoomStyles))];
      LightStyleState := Rnd.State;
      Rnd.State := MainState;
      if Style <> 0 then
        Inc(Report.FlickeringRooms);
      Step := 4;
      Y := Rooms[I].Y + 1;
      while Y < Rooms[I].Y + Rooms[I].H do
      begin
        X := Rooms[I].X + 1;
        while X < Rooms[I].X + Rooms[I].W do
        begin
          C := Level.Cell(X, Y);
          if not C^.Solid then
          begin
            E := Level.AddEntityAtCell('light', X, Y);
            E.SetKey('light', IntToStr(Round16(Rooms[I].Ceil - Rooms[I].Floor + 180)));
            if Style <> 0 then
              E.SetKey('style', IntToStr(Style));
          end;
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
        { The cell next to the room is a secret door: it looks like the
          room's wall and opens when shot (Quake 2 func_door_secret) }
        if I = 1 then
        begin
          Level.Cell(X, Y)^.Door := True;
          Level.Cell(X, Y)^.SecretDoor := True;
          Report.SecretDoorX := X;
          Report.SecretDoorY := Y;
        end;
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

  { The exit room locked: doors (channel 1) at its entrances, opened by a
    button (channel 1) in a room on the way, reachable with the doors shut }
  { The corridor cells at a room's entrances; False when one can't hold a
    door (lift, water, sky, button, ladder) }
  function RoomEntrances(const Room: Integer; const List: specialize TList<Integer>): Boolean;
  var
    X, Y, D: Integer;
    C: PLevelCell;
    Next: Boolean;
  begin
    List.Clear;
    for Y := 1 to Level.Height - 2 do
      for X := 1 to Level.Width - 2 do
      begin
        C := Level.Cell(X, Y);
        if C^.Solid or (CellRoom(X, Y) >= 0) then
          Continue;
        Next := False;
        for D := 0 to 3 do
          if CellRoom(X + DX[D], Y + DY[D]) = Room then
            Next := True;
        if not Next then
          Continue;
        if C^.Lift or C^.Wet or C^.Sky or C^.Button or C^.Ladder then
          Exit(False);
        List.Add(Y * Level.Width + X);
      end;
    Result := List.Count > 0;
  end;

  procedure SetSolid(const List: specialize TList<Integer>; const Value: Boolean);
  var
    I: Integer;
  begin
    for I in List do
      Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := Value;
  end;

  { Even seeds, the key hunt: the blue key (of the exit) lies in a vault
    room behind red doors, the red key somewhere reachable with all those
    doors shut. False: no vault fits (then the blue key lies in the open). }
  function AddRedVault(const VaultRoom, BX, BY, SX, SY: Integer;
    const ExitEntrances: specialize TList<Integer>; const Cands: array of Integer): Boolean;
  var
    Vault: specialize TList<Integer>;
    I, T, R, KX, KY: Integer;
    C: PLevelCell;
  begin
    Result := False;
    Vault := specialize TList<Integer>.Create;
    try
      if not RoomEntrances(VaultRoom, Vault) then
        Exit;
      for I in Vault do
        if ExitEntrances.Contains(I) then
          Exit;
      SetSolid(ExitEntrances, True);
      SetSolid(Vault, True);
      FloodReach(Level, SX, SY, Reached);
      SetSolid(Vault, False);
      SetSolid(ExitEntrances, False);
      { The vault must be sealed by its doors }
      if Reached[BY * Level.Width + BX] then
        Exit;
      for T := 1 to 10 do
      begin
        R := Cands[Rnd.Int(Length(Cands))];
        if (R = VaultRoom) or not FreeCell(R, KX, KY) then
          Continue;
        Level.AddEntityAtCell(LevelKeyClasses[2], KX, KY);
        for I in Vault do
        begin
          C := Level.Cell(I mod Level.Width, I div Level.Width);
          C^.Door := True;
          C^.Key := 2;
        end;
        Exit(True);
      end;
    finally
      Vault.Free;
    end;
  end;

  procedure AddExitSwitch(const StartRoom, ExitRoom, SX, SY: Integer);
  var
    Entrances: specialize TList<Integer>;
    X, Y, D, R, BX, BY, MaxDepth, T, I: Integer;
    C: PLevelCell;
    Next: Boolean;
    Cands: array of Integer;
  begin
    Entrances := specialize TList<Integer>.Create;
    try
      for Y := 1 to Level.Height - 2 do
        for X := 1 to Level.Width - 2 do
        begin
          C := Level.Cell(X, Y);
          if C^.Solid or (CellRoom(X, Y) >= 0) then
            Continue;
          Next := False;
          for D := 0 to 3 do
            if CellRoom(X + DX[D], Y + DY[D]) = ExitRoom then
              Next := True;
          if not Next then
            Continue;
          { Lifts, water and sky can't hold a door: then no switch }
          if C^.Lift or C^.Wet or C^.Sky or C^.Button or C^.Ladder then
            Exit;
          Entrances.Add(Y * Level.Width + X);
        end;
      if Entrances.Count = 0 then
        Exit;
      MaxDepth := 1;
      for R := 0 to High(Rooms) do
        MaxDepth := Max(MaxDepth, Rooms[R].Depth);
      Cands := nil;
      for R := 0 to High(Rooms) do
        if (R <> StartRoom) and (R <> ExitRoom) and not Rooms[R].Secret and
           (Rooms[R].Depth / MaxDepth >= 0.25) and (Rooms[R].Depth / MaxDepth <= 0.85) then
        begin
          SetLength(Cands, Length(Cands) + 1);
          Cands[High(Cands)] := R;
        end;
      if Length(Cands) = 0 then
        Exit;
      { With the entrances shut, find a reachable spot for the button }
      for I in Entrances do
        Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := True;
      FloodReach(Level, SX, SY, Reached);
      for I in Entrances do
        Level.Cell(I mod Level.Width, I div Level.Width)^.Solid := False;
      for T := 1 to 10 do
      begin
        R := Cands[Rnd.Int(Length(Cands))];
        if not FreeCell(R, BX, BY) then
          Continue;
        if Seed mod 2 = 0 then
        begin
          { Even seeds: the exit is locked, its key lies where the button
            would stand }
          Level.AddEntityAtCell(LevelKeyClasses[1], BX, BY);
          for I in Entrances do
          begin
            C := Level.Cell(I mod Level.Width, I div Level.Width);
            C^.Door := True;
            C^.Key := 1;
          end;
          Report.KeyDoors := 1;
          { The room of the blue key may be a vault locked with the red key }
          if AddRedVault(R, BX, BY, SX, SY, Entrances, Cands) then
            Report.KeyDoors := 2;
        end else
        begin
          C := Level.Cell(BX, BY);
          C^.Button := True;
          C^.Channel := 1;
          for I in Entrances do
          begin
            C := Level.Cell(I mod Level.Width, I div Level.Width);
            C^.Door := True;
            C^.Channel := 1;
          end;
          Report.Switches := 1;
        end;
        Break;
      end;
    finally
      Entrances.Free;
      { Back to the reach with the doors open }
      FloodReach(Level, SX, SY, Reached);
    end;
  end;

  { A teleporter in a corner of the secret room back to the start room }
  procedure AddSecretTeleporter(const SecretRoom, StartRoom: Integer);
  var
    S: TGenRoom;
    X, Y, BX, BY, Dist, BestDist: Integer;
  begin
    if SecretRoom < 0 then
      Exit;
    S := Rooms[SecretRoom];
    if Level.EntityAtCell(S.X, S.Y) >= 0 then
      Exit;
    { The destination: the free cell of the start room nearest its middle }
    BestDist := MaxInt;
    BX := -1;
    BY := -1;
    for Y := Rooms[StartRoom].Y to Rooms[StartRoom].Y + Rooms[StartRoom].H - 1 do
      for X := Rooms[StartRoom].X to Rooms[StartRoom].X + Rooms[StartRoom].W - 1 do
      begin
        if Level.Cell(X, Y)^.Solid or CellHasWater(Level.Cell(X, Y)) or Level.Cell(X, Y)^.Lift or
           Level.Cell(X, Y)^.Button or Level.Cell(X, Y)^.Door or not Reached[Y * Level.Width + X] or
           (Level.EntityAtCell(X, Y) >= 0) then
          Continue;
        Dist := Sqr(X - RoomCenterX(StartRoom)) + Sqr(Y - RoomCenterY(StartRoom));
        if (Dist > 0) and (Dist < BestDist) then
        begin
          BestDist := Dist;
          BX := X;
          BY := Y;
        end;
      end;
    if BX < 0 then
      Exit;
    Level.AddEntityAtCell('misc_teleporter', S.X, S.Y);
    Level.AddEntityAtCell('misc_teleporter_dest', BX, BY,
      AngleTo(BX, BY, RoomCenterX(StartRoom), RoomCenterY(StartRoom)));
    Report.Teleporters := 1;
  end;

  { Windows: glass in one-cell walls between two open areas (a room and a
    corridor, two corridors), a sill 48 above the higher floor }
  procedure AddWindows;
  const
    MaxWindows = 4;
  var
    Cands: specialize TList<Integer>;
    X, Y, I, Axis, Sill, Top: Integer;
    C, A, B, S1, S2: PLevelCell;

    function Plain(const N: PLevelCell): Boolean;
    begin
      Result := (not N^.Solid) and not (N^.Door or N^.Lift or N^.Button or N^.Wet or N^.Ladder or
        N^.Ramp or N^.Window or (N^.Diagonal > 0));
    end;

  begin
    Cands := specialize TList<Integer>.Create;
    try
      for Y := 2 to Level.Height - 3 do
        for X := 2 to Level.Width - 3 do
        begin
          C := Level.Cell(X, Y);
          if not C^.Solid then
            Continue;
          for Axis := 0 to 1 do
          begin
            if Axis = 0 then
            begin
              A := Level.Cell(X - 1, Y); B := Level.Cell(X + 1, Y);
              S1 := Level.Cell(X, Y - 1); S2 := Level.Cell(X, Y + 1);
            end else
            begin
              A := Level.Cell(X, Y - 1); B := Level.Cell(X, Y + 1);
              S1 := Level.Cell(X - 1, Y); S2 := Level.Cell(X + 1, Y);
            end;
            { A wall one cell thick, solid along it, open on both sides }
            if not (Plain(A) and Plain(B) and S1^.Solid and S2^.Solid) then
              Continue;
            Sill := Max(A^.Floor, B^.Floor) + 48;
            Top := Min(A^.Ceil, B^.Ceil) - 16;
            if Top - Sill >= LevelMinHeadroom then
              Cands.Add((Y * Level.Width + X) * 2 + Axis);
          end;
        end;
      for I := 1 to MaxWindows do
      begin
        if Cands.Count = 0 then
          Break;
        Axis := Cands[Rnd.Int(Cands.Count)];
        X := (Axis div 2) mod Level.Width;
        Y := (Axis div 2) div Level.Width;
        Axis := Axis mod 2;
        if not Level.Cell(X, Y)^.Solid then
          Continue;
        if Axis = 0 then
        begin
          A := Level.Cell(X - 1, Y); B := Level.Cell(X + 1, Y);
        end else
        begin
          A := Level.Cell(X, Y - 1); B := Level.Cell(X, Y + 1);
        end;
        Sill := Max(A^.Floor, B^.Floor) + 48;
        Top := Min(A^.Ceil, B^.Ceil) - 16;
        Level.SetOpen(X, Y, Sill, Top, A^.Theme);
        Level.Cell(X, Y)^.Window := True;
        Inc(Report.Windows);
      end;
    finally
      Cands.Free;
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
  Report.SecretDoorX := -1;
  Report.SecretDoorY := -1;
  EnsureLevelThemes;
  Rnd.State := SeedState(Seed);
  AmbushState := SeedState(Seed xor $5A17C3E9);
  LightStyleState := SeedState(Seed xor $1F2E3D4C);
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
  MakeOutdoor;
  CutRoomCorners;

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
  AddRamps;
  FloodReach(Level, CX, CY, Reached);
  AddExitSwitch(StartRoom, ExitRoom, CX, CY);

  AddLights;
  Populate(StartRoom, ExitRoom);
  AddSecretTeleporter(Report.SecretRoom, StartRoom);
  AddExit(ExitRoom);
  AddWindows;

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
      WritelnLog('QuakeLevelGen', 'Generated %s: %d rooms, %d links (%d loops), %d open cells (%d fixed, %d walled), %d doors, %d pools (%d slime), %d lifts, %d ladders, %d switches, %d key doors, %d teleporters, %d lava pits, %d outdoor rooms, %d ramps, %d windows, %d diagonal walls, %d round rooms, %d monsters, %d ambushes (%d monsters), %d flickering rooms, %d items, secret room %d',
        [Name, Report.Rooms, Report.Links, Report.Loops, Report.OpenCells, Report.FixedCells,
         Report.WalledCells, Report.Doors, Report.Pools, Report.SlimePools, Report.Lifts, Report.Ladders, Report.Switches,
         Report.KeyDoors, Report.Teleporters, Report.LavaPools, Report.OutdoorRooms, Report.Ramps, Report.Windows, Report.Diagonals, Report.RoundRooms, Report.Monsters,
         Report.Ambushes, Report.AmbushMonsters, Report.FlickeringRooms, Report.Items, Report.SecretRoom]);
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
