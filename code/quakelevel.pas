{ A level as the random generator and the level editor make it: a grid of
  64-unit cells, each a wall or open space with its own floor and ceiling
  height (Doom-style sectors on a grid), a texture theme and an optional
  sky ceiling, plus Quake 2 entities (monsters, items, lights, triggers).
  QuakeBspBuilder compiles it into a Quake 2 IBSP v38 map. Saved as JSON.
  Positions are Quake coordinates; cell (X, Y) spans
  X * LevelCellSize .. (X + 1) * LevelCellSize on Quake X / Y. }
unit QuakeLevel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections, CastleVectors;

const
  LevelCellSize = 64;
  { Heights are kept on this step (Quake 2's player climbs 18) }
  LevelHeightStep = 16;
  { Lowest headroom the player fits in (his box is 56 high) }
  LevelMinHeadroom = 64;

type
  TLevelCell = record
    Solid: Boolean;
    Floor, Ceil: SmallInt;
    Sky: Boolean;
    Theme: Byte;
    { A door fills the cell from floor to ceiling and slides up (func_door;
      touching door cells with the same heights are one door) }
    Door: Boolean;
    { Water in the cell, its surface at height Water (above Floor) }
    Wet: Boolean;
    Water: SmallInt;
    { The liquid is slime (CONTENTS_SLIME, hurts) or lava (CONTENTS_LAVA,
      hurts a lot) instead of water }
    Slime, Lava: Boolean;
    { A ladder against the highest neighbouring step (LadderDir), up to its
      floor }
    Ladder: Boolean;
    { A slope: the floor rises from Floor at the back edge to the floor of
      the neighbour RampDir points to (at most LevelRampMaxRise higher) }
    Ramp: Boolean;
    { A window: a glass pane (CONTENTS_WINDOW, translucent) across the
      cell between its open sides (WindowAxis), from Floor (the sill) to
      Ceil }
    Window: Boolean;
    { A lift (func_plat): a slab moving between Floor and LiftTop; touching
      lift cells with the same heights are one lift }
    Lift: Boolean;
    LiftTop: SmallInt;
    { A button (func_button) standing in the cell }
    Button: Boolean;
    { Switch channel 1..9: the buttons of a channel open its doors (which
      then stay open); 0 = a door that opens by itself }
    Channel: Byte;
    { A locked door: 1 = blue key, 2 = red key opens it (then it stays
      open); 0 = not locked }
    Key: Byte;
  end;
  PLevelCell = ^TLevelCell;

  { Texture set of a theme (WAL names in the PAK, without "textures/") }
  TLevelTheme = record
    Name, Floor, Wall, Ceil, Step, Light: String;
    { For outdoor (sky) areas: the generator's outdoor rooms }
    Outdoor: Boolean;
  end;

  { A Quake 2 entity: classname, origin and the other key / value pairs }
  TLevelEntity = class
  public
    EntClass: String;
    Origin: TVector3;
    Angle: Single;
    { Other keys as name=value (targetname, spawnflags, light, ...) }
    Keys: TStringList;
    constructor Create(const AClassName: String; const AOrigin: TVector3; const AAngle: Single = 0);
    destructor Destroy; override;
    function Key(const Name: String; const Default: String = ''): String;
    procedure SetKey(const Name, Value: String);
  end;
  TLevelEntityList = specialize TObjectList<TLevelEntity>;

  TQuakeLevel = class
  strict private
    FWidth, FHeight: Integer;
    FCells: array of TLevelCell;
    FOutside: TLevelCell;
    FEntities: TLevelEntityList;
  public
    Name: String;
    Message: String;
    Sky: String;
    Seed: Cardinal;
    constructor Create(const AWidth, AHeight: Integer);
    destructor Destroy; override;
    procedure Resize(const AWidth, AHeight: Integer);
    { All cells solid, no entities }
    procedure Clear;
    function InGrid(const X, Y: Integer): Boolean;
    { Direction (0 +X, 1 -X, 2 +Y, 3 -Y) of the open neighbour a ladder in
      (X, Y) climbs to: the highest floor more than a step up; -1 = none }
    function LadderDir(const X, Y: Integer): Integer;
    { Direction a ramp in (X, Y) rises towards: the highest open neighbour
      above its floor, at most LevelRampMaxRise up; -1 = flat }
    function RampDir(const X, Y: Integer): Integer;
    { The axis a window looks along (0 X: open to the west and east, 1 Y),
      -1 when it isn't between two open cells }
    function WindowAxis(const X, Y: Integer): Integer;
    { The floor of (X, Y) at a point of the cell (Quake coordinates; a ramp
      slopes, other cells are flat) }
    function FloorAt(const X, Y: Integer; const PX, PY: Single): Single;
    { The cell, or a solid one outside the grid (don't change that) }
    function Cell(const X, Y: Integer): PLevelCell;
    procedure SetOpen(const X, Y: Integer; const AFloor, ACeil: Integer; const ATheme: Integer = 0);
    { Quake position of the middle of a cell's floor }
    function CellFloorCenter(const X, Y: Integer): TVector3;
    { The cell holding a Quake position (may be outside the grid) }
    procedure CellAt(const P: TVector3; out X, Y: Integer);
    { Border cells solid, heights on LevelHeightStep, enough headroom }
    procedure Normalize;
    function AddEntity(const AClassName: String; const AOrigin: TVector3; const AAngle: Single = 0): TLevelEntity;
    { Entity standing on the floor of a cell: origin raised like Quake 2
      maps (monsters and the player 24, items 16, lights near the ceiling) }
    function AddEntityAtCell(const AClassName: String; const X, Y: Integer; const AAngle: Single = 0): TLevelEntity;
    { Entities in a cell (index list order), -1 when none }
    function EntityAtCell(const X, Y: Integer): Integer;
    function OpenCellCount: Integer;
    procedure SaveToStream(const Stream: TStream);
    procedure LoadFromStream(const Stream: TStream);
    procedure SaveToFile(const Url: String);
    procedure LoadFromFile(const Url: String);
    { The Quake 2 entity lump text (worldspawn first) }
    function EntityText: String;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Entities: TLevelEntityList read FEntities;
  end;

const
  { The themes of the demo's textures (LevelThemes starts with them; more
    are discovered in the full game's PAKs, DiscoverLevelThemes) }
  BuiltInThemes: array[0..7] of TLevelTheme = (
    (Name: 'base'; Floor: 'e1u1/floor3_1'; Wall: 'e1u1/wslt1_1'; Ceil: 'e1u1/ceil1_1';
      Step: 'e1u1/metal3_2'; Light: 'e1u1/plite1_1'; Outdoor: False),
    (Name: 'metal'; Floor: 'e1u1/grate1_3'; Wall: 'e1u1/metal2_2'; Ceil: 'e1u1/ceil1_3';
      Step: 'e1u1/metal1_1'; Light: 'e1u1/plite1_3'; Outdoor: False),
    (Name: 'green'; Floor: 'e1u1/florr1_2'; Wall: 'e1u1/grnx2_1'; Ceil: 'e1u1/ceil1_4';
      Step: 'e1u1/grnmt1_1'; Light: 'e1u1/plite1_1'; Outdoor: False),
    (Name: 'tech'; Floor: 'e1u1/floor3_2'; Wall: 'e1u1/wbasic1_1'; Ceil: 'e1u1/ceil1_7';
      Step: 'e1u1/metal3_5'; Light: 'e1u1/baselt_2'; Outdoor: False),
    (Name: 'red'; Floor: 'e1u1/floor3_3'; Wall: 'e1u1/red1_2'; Ceil: 'e1u1/metal5_1';
      Step: 'e1u1/metal1_3'; Light: 'e1u1/baselt_3'; Outdoor: False),
    (Name: 'brown'; Floor: 'e1u1/c_met7_1'; Wall: 'e1u2/metal13_1'; Ceil: 'e1u1/wtroof4_2';
      Step: 'e1u1/metal3_3'; Light: 'e1u1/baselt_4'; Outdoor: False),
    (Name: 'rock'; Floor: 'e1u1/rocks16_2'; Wall: 'e1u1/rocks19_1'; Ceil: 'e1u1/rocks16_2';
      Step: 'e1u1/rocks19_1'; Light: 'e1u1/plite1_3'; Outdoor: True),
    (Name: 'grass'; Floor: 'e1u1/grass1_7'; Wall: 'e1u1/rocks19_1'; Ceil: 'e1u1/rocks16_2';
      Step: 'e1u1/rocks16_2'; Light: 'e1u1/plite1_3'; Outdoor: True)
  );
  LevelSkyTexture = 'e1u1/sky1';
  LevelWaterTexture = 'e1u1/bluwter';
  { The demo has no slime texture: its warping sewage stands in }
  LevelSlimeTexture = 'e1u1/sewer1';
  { Doors of the blue and red key (the red one has a red lamp) }
  LevelKeyDoorTextures: array[1..2] of String = ('e1u1/keydr1_1', 'e1u2/keydran1_1');
  { Made in memory by QuakeBspBuilder (the demo has no lava texture) }
  LevelLavaTexture = 'castle/lava';
  LevelLadderTexture = 'e1u1/wsupprt1_3';
  { A ladder: this deep in front of its wall, this wide }
  LevelLadderDepth = 8;
  LevelLadderHalfWidth = 20;
  { A ramp rises at most this much over its cell (45 degrees: Quake 2's
    walkable limit is a floor normal of 0.7) }
  LevelRampMaxRise = 48;
  LevelWindowTexture = 'e1u1/wndow0_3';
  LevelWindowThickness = 4;
  { Key items of Key = 1, 2 }
  LevelKeyClasses: array[1..2] of String = ('key_blue_key', 'key_red_key');
  LevelDoorTexture = 'e1u1/dr02_1';
  LevelLiftTexture = 'e1u1/wplat1_1';
  LevelButtonTexture = 'e1u1/btactmach0';
  { Lift slab thickness, button size }
  LevelLiftThickness = 16;
  LevelButtonHalfWidth = 12;
  LevelButtonHeight = 40;

var
  { The themes levels can use: BuiltInThemes, then the ones discovered in
    the loaded PAKs (EnsureLevelThemes). Cells store an index; level files
    also store the names, so they keep their themes as the list changes. }
  LevelThemes: array of TLevelTheme;

{ Back to BuiltInThemes only }
procedure ResetLevelThemes;

{ BuiltInThemes plus a theme per texture directory of the PAKs with enough
  plain textures (the full game's e1u2, e2u3...; the demo's few extra ones
  don't count): floor, wall, ceiling, step and light picked by the WAL
  flags and names }
procedure DiscoverLevelThemes;

{ DiscoverLevelThemes when the PAKs changed since the last time }
procedure EnsureLevelThemes;

{ Themes the generator uses for rooms and corridors / outdoor areas }
function IndoorThemeCount: Integer;
function IndoorTheme(const I: Integer): Integer;
function OutdoorThemeCount: Integer;
function OutdoorTheme(const I: Integer): Integer;
function ThemeIndex(const Name: String): Integer;

{ Water in the cell (its surface above the floor) }
function CellHasWater(const C: PLevelCell): Boolean;

{ Rolling ground: a smooth height 0..64 (16-unit steps) for each cell,
  for outdoor areas (the Hills tool, the generator's outdoor rooms) }
function TerrainHeight(const X, Y: Integer): Integer;

{ Height above the floor where an entity of this class has its origin:
  its box 1 unit above the floor (an origin that makes the box touch the
  floor starts its traces in solid) }
function EntityFloorOffset(const AClassName: String): Single;

implementation

uses
  Math, StrUtils, fpjson, jsonparser, CastleDownload, CastleFilesUtils, CastleUriUtils, CastleLog, QuakePak;

var
  DotFormat: TFormatSettings;

const
  LadderDX: array[0..3] of Integer = (1, -1, 0, 0);
  LadderDY: array[0..3] of Integer = (0, 0, 1, -1);

function CellHasWater(const C: PLevelCell): Boolean;
begin
  Result := (not C^.Solid) and C^.Wet and (C^.Water > C^.Floor);
end;

var
  ThemesForFileCount: Integer = -1;

procedure ResetLevelThemes;
var
  I: Integer;
begin
  SetLength(LevelThemes, Length(BuiltInThemes));
  for I := 0 to High(BuiltInThemes) do
    LevelThemes[I] := BuiltInThemes[I];
end;

procedure DiscoverLevelThemes;
const
  { A directory needs this many plain textures to be a theme }
  MinTextures = 12;
  SURF_LIGHT = 1;
  SURF_SKY = 4;
  SURF_WARP = 8;
  SURF_TRANS33 = $10;
  SURF_TRANS66 = $20;
  SURF_NODRAW = $80;
var
  Files, Dirs: TStringList;
  Plain, Lights: TStringList;
  I, J, Slash: Integer;
  Path, Dir, Name: String;
  Data: PByte;
  Size: Cardinal;
  Flags, Contents, Value: LongInt;
  T: TLevelTheme;

  function Skipped(const N: String): Boolean;
  const
    Words: array[0..15] of String = ('sky', 'clip', 'trigger', 'hint', 'origin', 'skip', 'door', 'dr0',
      'btn', 'button', 'sign', 'exit', 'arrow', 'lever', 'alarm', 'black');
  var
    W: String;
  begin
    Result := (N = '') or (N[1] in ['+', '*', '#']);
    for W in Words do
      if Pos(W, N) > 0 then
        Exit(True);
  end;

  function Pick(const Hints: array of String; const Fallback: String): String;
  var
    K: Integer;
    H: String;
  begin
    for H in Hints do
      for K := 0 to Plain.Count - 1 do
        if Pos(H, Plain[K]) > 0 then
          Exit(Dir + '/' + Plain[K]);
    Result := Fallback;
  end;

begin
  ResetLevelThemes;
  Files := Pak.FindFiles('textures/', '.wal');
  Dirs := TStringList.Create;
  Plain := TStringList.Create;
  Lights := TStringList.Create;
  try
    Files.Sort;
    Dirs.Sorted := True;
    Dirs.Duplicates := dupIgnore;
    for Path in Files do
    begin
      Slash := Pos('/', Copy(Path, 10, MaxInt));
      if Slash > 0 then
        Dirs.Add(Copy(Path, 10, Slash - 1));
    end;
    for Dir in Dirs do
    begin
      { The demo's own textures are the built-in themes }
      if Dir = 'e1u1' then
        Continue;
      Plain.Clear;
      Lights.Clear;
      for J := 0 to Files.Count - 1 do
      begin
        Path := Files[J];
        if Copy(Path, 1, 10 + Length(Dir)) <> 'textures/' + Dir + '/' then
          Continue;
        Name := ChangeFileExt(Copy(Path, 11 + Length(Dir), MaxInt), '');
        if Pos('/', Name) > 0 then
          Continue;
        Data := Pak.GetData(Path, Size);
        if (Data = nil) or (Size < 100) then
          Continue;
        { WAL header: name, size, mip offsets, next anim name, then flags }
        Flags := PLongInt(Data + 88)^;
        Contents := PLongInt(Data + 92)^;
        Value := PLongInt(Data + 96)^;
        if ((Flags and (SURF_SKY or SURF_WARP or SURF_TRANS33 or SURF_TRANS66 or SURF_NODRAW)) <> 0) or
           (Contents <> 0) or Skipped(Name) then
          Continue;
        if ((Flags and SURF_LIGHT) <> 0) and (Value > 0) then
          Lights.Add(Name)
        else
          Plain.Add(Name);
      end;
      if Plain.Count < MinTextures then
        Continue;
      T.Name := Dir;
      T.Floor := Pick(['floor', 'flr', 'grate', 'grnd', 'flat', 'plat', 'grass', 'dirt'], Dir + '/' + Plain[0]);
      T.Wall := Pick(['wall', 'wbasic', 'wslt', 'brick', 'stone', 'rock', 'metal', 'comp', 'bas'], Dir + '/' + Plain[1]);
      T.Ceil := Pick(['ceil', 'roof', 'top'], T.Floor);
      T.Step := Pick(['step', 'trim', 'support', 'metal', 'pip'], T.Wall);
      if Lights.Count > 0 then
        T.Light := Dir + '/' + Lights[0]
      else
        T.Light := BuiltInThemes[0].Light;
      T.Outdoor := (Pos('grass', T.Floor) > 0) or (Pos('rock', T.Floor) > 0) or (Pos('dirt', T.Floor) > 0) or
        (Pos('grnd', T.Floor) > 0);
      SetLength(LevelThemes, Length(LevelThemes) + 1);
      LevelThemes[High(LevelThemes)] := T;
      WritelnLog('QuakeLevel', 'Theme "%s" from the PAKs: floor %s, wall %s, ceiling %s, step %s, light %s%s',
        [T.Name, T.Floor, T.Wall, T.Ceil, T.Step, T.Light, StrUtils.IfThen(T.Outdoor, ' (outdoor)', '')]);
    end;
  finally
    Lights.Free;
    Plain.Free;
    Dirs.Free;
    Files.Free;
  end;
  ThemesForFileCount := Pak.FileCount;
end;

procedure EnsureLevelThemes;
begin
  if (Pak <> nil) and (Pak.FileCount <> ThemesForFileCount) then
    DiscoverLevelThemes;
end;

function IndoorThemeCount: Integer;
var
  T: TLevelTheme;
begin
  Result := 0;
  for T in LevelThemes do
    if not T.Outdoor then
      Inc(Result);
end;

function IndoorTheme(const I: Integer): Integer;
var
  K, N: Integer;
begin
  N := 0;
  for K := 0 to High(LevelThemes) do
    if not LevelThemes[K].Outdoor then
    begin
      if N = I then
        Exit(K);
      Inc(N);
    end;
  Result := 0;
end;

function OutdoorThemeCount: Integer;
begin
  Result := Length(LevelThemes) - IndoorThemeCount;
end;

function OutdoorTheme(const I: Integer): Integer;
var
  K, N: Integer;
begin
  N := 0;
  for K := 0 to High(LevelThemes) do
    if LevelThemes[K].Outdoor then
    begin
      if N = I then
        Exit(K);
      Inc(N);
    end;
  Result := 0;
end;

function ThemeIndex(const Name: String): Integer;
var
  K: Integer;
begin
  for K := 0 to High(LevelThemes) do
    if LevelThemes[K].Name = Name then
      Exit(K);
  Result := -1;
end;

function TerrainHeight(const X, Y: Integer): Integer;
var
  H: Single;
begin
  H := 32 + 16 * Sin(0.55 * X + 1.3 * Sin(0.31 * Y)) + 16 * Sin(0.47 * Y + 0.9 * Sin(0.37 * X));
  Result := EnsureRange(Round(H / LevelHeightStep) * LevelHeightStep, 0, 64);
end;

function EntityFloorOffset(const AClassName: String): Single;
begin
  if (Copy(AClassName, 1, 8) = 'monster_') or (Copy(AClassName, 1, 12) = 'info_player_') or
     (AClassName = 'misc_explobox') or (Copy(AClassName, 1, 15) = 'misc_teleporter') then
    Result := 25
  else
  if (Copy(AClassName, 1, 5) = 'item_') or (Copy(AClassName, 1, 7) = 'weapon_') or
     (Copy(AClassName, 1, 5) = 'ammo_') or (Copy(AClassName, 1, 4) = 'key_') then
    Result := 17
  else
    Result := 0;
end;

{ TLevelEntity }

constructor TLevelEntity.Create(const AClassName: String; const AOrigin: TVector3; const AAngle: Single);
begin
  inherited Create;
  EntClass := AClassName;
  Origin := AOrigin;
  Angle := AAngle;
  Keys := TStringList.Create;
end;

destructor TLevelEntity.Destroy;
begin
  Keys.Free;
  inherited Destroy;
end;

function TLevelEntity.Key(const Name: String; const Default: String): String;
var
  I: Integer;
begin
  I := Keys.IndexOfName(Name);
  if I < 0 then
    Result := Default
  else
    Result := Keys.ValueFromIndex[I];
end;

procedure TLevelEntity.SetKey(const Name, Value: String);
begin
  Keys.Values[Name] := Value;
end;

{ TQuakeLevel }

constructor TQuakeLevel.Create(const AWidth, AHeight: Integer);
begin
  inherited Create;
  FEntities := TLevelEntityList.Create(True);
  FOutside.Solid := True;
  Name := 'level';
  Sky := 'unit1_';
  Resize(AWidth, AHeight);
end;

destructor TQuakeLevel.Destroy;
begin
  FEntities.Free;
  inherited Destroy;
end;

procedure TQuakeLevel.Resize(const AWidth, AHeight: Integer);
begin
  FWidth := Max(3, AWidth);
  FHeight := Max(3, AHeight);
  SetLength(FCells, FWidth * FHeight);
  Clear;
end;

procedure TQuakeLevel.Clear;
var
  I: Integer;
begin
  for I := 0 to High(FCells) do
  begin
    FCells[I] := Default(TLevelCell);
    FCells[I].Solid := True;
    FCells[I].Ceil := 128;
  end;
  FEntities.Clear;
end;

function TQuakeLevel.InGrid(const X, Y: Integer): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight);
end;

function TQuakeLevel.WindowAxis(const X, Y: Integer): Integer;

  function Open(const NX, NY: Integer): Boolean;
  begin
    Result := InGrid(NX, NY) and not Cell(NX, NY)^.Solid;
  end;

begin
  Result := -1;
  if (not InGrid(X, Y)) or Cell(X, Y)^.Solid or not Cell(X, Y)^.Window then
    Exit;
  if Open(X - 1, Y) and Open(X + 1, Y) then
    Result := 0
  else
  if Open(X, Y - 1) and Open(X, Y + 1) then
    Result := 1;
end;

function TQuakeLevel.RampDir(const X, Y: Integer): Integer;
var
  D, Best: Integer;
  C, N: PLevelCell;
begin
  Result := -1;
  if not InGrid(X, Y) then
    Exit;
  C := Cell(X, Y);
  if C^.Solid or not C^.Ramp then
    Exit;
  Best := C^.Floor;
  for D := 0 to 3 do
    if InGrid(X + LadderDX[D], Y + LadderDY[D]) then
    begin
      N := Cell(X + LadderDX[D], Y + LadderDY[D]);
      if (not N^.Solid) and (N^.Floor > Best) and (N^.Floor <= C^.Floor + LevelRampMaxRise) then
      begin
        Best := N^.Floor;
        Result := D;
      end;
    end;
end;

function TQuakeLevel.FloorAt(const X, Y: Integer; const PX, PY: Single): Single;
var
  C: PLevelCell;
  D: Integer;
  T, Top: Single;
begin
  C := Cell(X, Y);
  Result := C^.Floor;
  D := RampDir(X, Y);
  if D < 0 then
    Exit;
  Top := Cell(X + LadderDX[D], Y + LadderDY[D])^.Floor;
  { 0 at the back edge, 1 at the edge towards D }
  case D of
    0: T := PX / LevelCellSize - X;
    1: T := X + 1 - PX / LevelCellSize;
    2: T := PY / LevelCellSize - Y;
    else T := Y + 1 - PY / LevelCellSize;
  end;
  Result := C^.Floor + (Top - C^.Floor) * EnsureRange(T, 0, 1);
end;

function TQuakeLevel.LadderDir(const X, Y: Integer): Integer;
var
  D, Best: Integer;
  C, N: PLevelCell;
begin
  Result := -1;
  if not InGrid(X, Y) then
    Exit;
  C := Cell(X, Y);
  if C^.Solid then
    Exit;
  Best := C^.Floor + LevelHeightStep;
  for D := 0 to 3 do
    if InGrid(X + LadderDX[D], Y + LadderDY[D]) then
    begin
      N := Cell(X + LadderDX[D], Y + LadderDY[D]);
      if (not N^.Solid) and (N^.Floor > Best) then
      begin
        Best := N^.Floor;
        Result := D;
      end;
    end;
end;

function TQuakeLevel.Cell(const X, Y: Integer): PLevelCell;
begin
  if InGrid(X, Y) then
    Result := @FCells[Y * FWidth + X]
  else
  begin
    FOutside := Default(TLevelCell);
    FOutside.Solid := True;
    Result := @FOutside;
  end;
end;

procedure TQuakeLevel.SetOpen(const X, Y: Integer; const AFloor, ACeil: Integer; const ATheme: Integer);
var
  C: PLevelCell;
begin
  if not InGrid(X, Y) then
    Exit;
  C := Cell(X, Y);
  C^.Solid := False;
  C^.Floor := AFloor;
  C^.Ceil := ACeil;
  C^.Theme := ATheme;
end;

function TQuakeLevel.CellFloorCenter(const X, Y: Integer): TVector3;
begin
  Result := Vector3((X + 0.5) * LevelCellSize, (Y + 0.5) * LevelCellSize, Cell(X, Y)^.Floor);
end;

procedure TQuakeLevel.CellAt(const P: TVector3; out X, Y: Integer);
begin
  X := Floor(P.X / LevelCellSize);
  Y := Floor(P.Y / LevelCellSize);
end;

procedure TQuakeLevel.Normalize;
var
  X, Y, D: Integer;
  C: PLevelCell;
begin
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      C := Cell(X, Y);
      if (X = 0) or (Y = 0) or (X = FWidth - 1) or (Y = FHeight - 1) then
        C^.Solid := True;
      if C^.Solid then
        Continue;
      C^.Floor := Round(C^.Floor / LevelHeightStep) * LevelHeightStep;
      C^.Ceil := Round(C^.Ceil / LevelHeightStep) * LevelHeightStep;
      if C^.Ceil < C^.Floor + LevelMinHeadroom then
        C^.Ceil := C^.Floor + LevelMinHeadroom;
      if C^.Theme > High(LevelThemes) then
        C^.Theme := 0;
      if C^.Wet and (C^.Water > C^.Floor) then
        C^.Water := EnsureRange(Round(C^.Water / 8) * 8, C^.Floor + 8, C^.Ceil - 8)
      else
        C^.Wet := False;
      if not C^.Wet then
      begin
        C^.Slime := False;
        C^.Lava := False;
      end;
      if C^.Lava then
        C^.Slime := False;
      { A door under the sky or over water isn't supported }
      if C^.Door and (C^.Sky or C^.Wet) then
        C^.Door := False;
      { One mover per cell: door, lift or button }
      if C^.Lift and (C^.Door or C^.Wet) then
        C^.Lift := False;
      if C^.Lift then
      begin
        C^.LiftTop := Round(C^.LiftTop / LevelHeightStep) * LevelHeightStep;
        if C^.LiftTop <= C^.Floor then
          C^.Lift := False
        else
        if C^.Ceil < C^.LiftTop + LevelMinHeadroom then
          C^.Ceil := C^.LiftTop + LevelMinHeadroom;
      end;
      if C^.Ladder and (C^.Door or C^.Lift or C^.Button or C^.Wet) then
        C^.Ladder := False;
      if C^.Ramp and (C^.Door or C^.Lift or C^.Button or C^.Wet or C^.Ladder) then
        C^.Ramp := False;
      if C^.Window and (C^.Door or C^.Lift or C^.Button or C^.Wet or C^.Ladder or C^.Ramp or C^.Sky) then
        C^.Window := False;
      if C^.Button and (C^.Door or C^.Lift or C^.Wet) then
        C^.Button := False;
      if C^.Button and (C^.Channel = 0) then
        C^.Channel := 1;
      C^.Channel := Min(C^.Channel, 9);
      if (not C^.Door) or (C^.Key > High(LevelKeyClasses)) then
        C^.Key := 0;
      { A locked door opens with its key, not a switch }
      if C^.Key > 0 then
        C^.Channel := 0;
    end;
  { Headroom over a ramp's high end }
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      C := Cell(X, Y);
      D := RampDir(X, Y);
      if D >= 0 then
        C^.Ceil := Max(C^.Ceil, Cell(X + LadderDX[D], Y + LadderDY[D])^.Floor + LevelMinHeadroom);
    end;
end;

function TQuakeLevel.AddEntity(const AClassName: String; const AOrigin: TVector3;
  const AAngle: Single): TLevelEntity;
begin
  Result := TLevelEntity.Create(AClassName, AOrigin, AAngle);
  FEntities.Add(Result);
end;

function TQuakeLevel.AddEntityAtCell(const AClassName: String; const X, Y: Integer;
  const AAngle: Single): TLevelEntity;
var
  P: TVector3;
begin
  P := CellFloorCenter(X, Y);
  { On a ramp: the floor's highest point under a 32-unit box }
  P.Z := Max(Max(FloorAt(X, Y, P.X - 16, P.Y - 16), FloorAt(X, Y, P.X + 16, P.Y - 16)),
    Max(FloorAt(X, Y, P.X - 16, P.Y + 16), FloorAt(X, Y, P.X + 16, P.Y + 16)));
  if AClassName = 'light' then
    P.Z := Cell(X, Y)^.Ceil - 16
  else
    P.Z := P.Z + EntityFloorOffset(AClassName);
  Result := AddEntity(AClassName, P, AAngle);
end;

function TQuakeLevel.EntityAtCell(const X, Y: Integer): Integer;
var
  I, CX, CY: Integer;
begin
  for I := 0 to FEntities.Count - 1 do
  begin
    CellAt(FEntities[I].Origin, CX, CY);
    if (CX = X) and (CY = Y) then
      Exit(I);
  end;
  Result := -1;
end;

function TQuakeLevel.OpenCellCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FCells) do
    if not FCells[I].Solid then
      Inc(Result);
end;

function FormatNum(const V: Single): String;
begin
  if Frac(V) = 0 then
    Result := IntToStr(Round(V))
  else
    Result := FormatFloat('0.##', V, DotFormat);
end;

function TQuakeLevel.EntityText: String;
var
  E: TLevelEntity;
  I, Teleporters, Dests: Integer;
  SB: TStringBuilder;

  procedure Pair(const K, V: String);
  begin
    SB.Append('"').Append(K).Append('" "').Append(V).Append('"').Append(LineEnding);
  end;

begin
  Teleporters := 0;
  Dests := 0;
  SB := TStringBuilder.Create;
  try
    SB.Append('{').Append(LineEnding);
    Pair('classname', 'worldspawn');
    if Message <> '' then
      Pair('message', Message);
    if Sky <> '' then
      Pair('sky', Sky);
    SB.Append('}').Append(LineEnding);
    for E in FEntities do
    begin
      SB.Append('{').Append(LineEnding);
      Pair('classname', E.EntClass);
      Pair('origin', FormatNum(E.Origin.X) + ' ' + FormatNum(E.Origin.Y) + ' ' + FormatNum(E.Origin.Z));
      if E.Angle <> 0 then
        Pair('angle', FormatNum(E.Angle));
      for I := 0 to E.Keys.Count - 1 do
        Pair(E.Keys.Names[I], E.Keys.ValueFromIndex[I]);
      { Teleporters without a target go to the destination of the same
        number (the n-th misc_teleporter to the n-th misc_teleporter_dest) }
      if (E.EntClass = 'misc_teleporter') and (E.Key('target') = '') then
      begin
        Inc(Teleporters);
        Pair('target', 'teleport' + IntToStr(Teleporters));
      end;
      if (E.EntClass = 'misc_teleporter_dest') and (E.Key('targetname') = '') then
      begin
        Inc(Dests);
        Pair('targetname', 'teleport' + IntToStr(Dests));
      end;
      SB.Append('}').Append(LineEnding);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TQuakeLevel.SaveToStream(const Stream: TStream);
var
  Root, JE, JKeys: TJSONObject;
  Rows, Ents, Names: TJSONArray;
  X, Y, I: Integer;
  C: PLevelCell;
  Row: String;
  E: TLevelEntity;
  S: String;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('format', 'castle-quake2-level');
    Root.Add('version', 1);
    Root.Add('name', Name);
    Root.Add('message', Message);
    Root.Add('sky', Sky);
    Root.Add('seed', Int64(Seed));
    Root.Add('width', FWidth);
    Root.Add('height', FHeight);
    { One string per row: "#" for walls, else
      floor,ceil,theme[,s][,d][,w<h>][,l<top>][,b][,c<n>] cells (sky, door,
      water surface, lift top, button, switch channel) separated by spaces }
    Rows := TJSONArray.Create;
    for Y := 0 to FHeight - 1 do
    begin
      Row := '';
      for X := 0 to FWidth - 1 do
      begin
        C := Cell(X, Y);
        if X > 0 then
          Row := Row + ' ';
        if C^.Solid then
          Row := Row + '#'
        else
        begin
          Row := Row + Format('%d,%d,%d', [C^.Floor, C^.Ceil, C^.Theme]);
          if C^.Sky then
            Row := Row + ',s';
          if C^.Door then
            Row := Row + ',d';
          if CellHasWater(C) then
            Row := Row + ',w' + IntToStr(C^.Water);
          if CellHasWater(C) and C^.Slime then
            Row := Row + ',m';
          if CellHasWater(C) and C^.Lava then
            Row := Row + ',v';
          if C^.Ladder then
            Row := Row + ',r';
          if C^.Ramp then
            Row := Row + ',p';
          if C^.Window then
            Row := Row + ',g';
          if C^.Door and (C^.Key > 0) then
            Row := Row + ',k' + IntToStr(C^.Key);
          if C^.Lift then
            Row := Row + ',l' + IntToStr(C^.LiftTop);
          if C^.Button then
            Row := Row + ',b';
          if C^.Channel > 0 then
            Row := Row + ',c' + IntToStr(C^.Channel);
        end;
      end;
      Rows.Add(Row);
    end;
    Root.Add('rows', Rows);
    { The theme names, so the cells keep their themes when the list differs
      (other PAKs) }
    Names := TJSONArray.Create;
    for I := 0 to High(LevelThemes) do
      Names.Add(LevelThemes[I].Name);
    Root.Add('themes', Names);
    Ents := TJSONArray.Create;
    for E in FEntities do
    begin
      JE := TJSONObject.Create;
      JE.Add('classname', E.EntClass);
      JE.Add('origin', TJSONArray.Create([E.Origin.X, E.Origin.Y, E.Origin.Z]));
      if E.Angle <> 0 then
        JE.Add('angle', E.Angle);
      if E.Keys.Count > 0 then
      begin
        JKeys := TJSONObject.Create;
        for I := 0 to E.Keys.Count - 1 do
          JKeys.Add(E.Keys.Names[I], E.Keys.ValueFromIndex[I]);
        JE.Add('keys', JKeys);
      end;
      Ents.Add(JE);
    end;
    Root.Add('entities', Ents);
    S := Root.FormatJSON;
    Stream.WriteBuffer(S[1], Length(S));
  finally
    Root.Free;
  end;
end;

procedure TQuakeLevel.LoadFromStream(const Stream: TStream);
var
  Data: TJSONData;
  Root, JE, JKeys: TJSONObject;
  Rows, Ents, Org, Names: TJSONArray;
  X, Y, I: Integer;
  Parts, Vals: TStringArray;
  C: PLevelCell;
  E: TLevelEntity;
  S, RowText: String;
begin
  SetLength(S, Stream.Size - Stream.Position);
  if Length(S) > 0 then
    Stream.ReadBuffer(S[1], Length(S));
  Data := GetJSON(S);
  try
    if not (Data is TJSONObject) then
      raise Exception.Create('Level file is not a JSON object');
    Root := TJSONObject(Data);
    Resize(Root.Get('width', 32), Root.Get('height', 32));
    Name := Root.Get('name', 'level');
    Message := Root.Get('message', '');
    Sky := Root.Get('sky', 'unit1_');
    Seed := Cardinal(Root.Get('seed', Int64(0)));
    Rows := Root.Find('rows', jtArray) as TJSONArray;
    if Rows <> nil then
      for Y := 0 to Min(Rows.Count, FHeight) - 1 do
      begin
        RowText := Rows.Strings[Y];
        Parts := RowText.Split([' '], TStringSplitOptions.ExcludeEmpty);
        for X := 0 to Min(Length(Parts), FWidth) - 1 do
        begin
          C := Cell(X, Y);
          if Parts[X] = '#' then
            Continue;
          RowText := Parts[X];
          Vals := RowText.Split([',']);
          if Length(Vals) < 2 then
            Continue;
          C^.Solid := False;
          C^.Floor := StrToIntDef(Vals[0], 0);
          C^.Ceil := StrToIntDef(Vals[1], 128);
          if Length(Vals) > 2 then
            C^.Theme := StrToIntDef(Vals[2], 0);
          for I := 3 to High(Vals) do
            if Vals[I] = 's' then
              C^.Sky := True
            else
            if Vals[I] = 'd' then
              C^.Door := True
            else
            if Copy(Vals[I], 1, 1) = 'w' then
            begin
              C^.Wet := True;
              C^.Water := StrToIntDef(Copy(Vals[I], 2, MaxInt), 0);
            end else
            if Copy(Vals[I], 1, 1) = 'l' then
            begin
              C^.Lift := True;
              C^.LiftTop := StrToIntDef(Copy(Vals[I], 2, MaxInt), 0);
            end else
            if Vals[I] = 'b' then
              C^.Button := True
            else
            if Vals[I] = 'm' then
              C^.Slime := True
            else
            if Vals[I] = 'v' then
              C^.Lava := True
            else
            if Vals[I] = 'r' then
              C^.Ladder := True
            else
            if Vals[I] = 'p' then
              C^.Ramp := True
            else
            if Vals[I] = 'g' then
              C^.Window := True
            else
            if Copy(Vals[I], 1, 1) = 'k' then
              C^.Key := StrToIntDef(Copy(Vals[I], 2, MaxInt), 0)
            else
            if Copy(Vals[I], 1, 1) = 'c' then
              C^.Channel := StrToIntDef(Copy(Vals[I], 2, MaxInt), 0);
        end;
      end;
    { Theme indexes of the file -> ours, by name (missing: the first) }
    Names := Root.Find('themes', jtArray) as TJSONArray;
    if Names <> nil then
    begin
      EnsureLevelThemes;
      for Y := 0 to FHeight - 1 do
        for X := 0 to FWidth - 1 do
        begin
          C := Cell(X, Y);
          if (not C^.Solid) and (C^.Theme < Names.Count) then
            C^.Theme := Max(0, ThemeIndex(Names.Strings[C^.Theme]));
        end;
    end;
    Ents := Root.Find('entities', jtArray) as TJSONArray;
    if Ents <> nil then
      for I := 0 to Ents.Count - 1 do
      begin
        if not (Ents[I] is TJSONObject) then
          Continue;
        JE := TJSONObject(Ents[I]);
        Org := JE.Find('origin', jtArray) as TJSONArray;
        E := TLevelEntity.Create(JE.Get('classname', 'info_null'), TVector3.Zero, JE.Get('angle', 0.0));
        if (Org <> nil) and (Org.Count >= 3) then
          E.Origin := Vector3(Org.Floats[0], Org.Floats[1], Org.Floats[2]);
        JKeys := JE.Find('keys', jtObject) as TJSONObject;
        if JKeys <> nil then
          for X := 0 to JKeys.Count - 1 do
            E.SetKey(JKeys.Names[X], JKeys.Items[X].AsString);
        FEntities.Add(E);
      end;
  finally
    Data.Free;
  end;
  Normalize;
end;

procedure TQuakeLevel.SaveToFile(const Url: String);
var
  Stream: TStream;
begin
  Stream := UrlSaveStream(Url);
  try
    SaveToStream(Stream);
  finally
    Stream.Free;
  end;
end;

procedure TQuakeLevel.LoadFromFile(const Url: String);
var
  Stream: TStream;
begin
  Stream := Download(Url);
  try
    LoadFromStream(Stream);
  finally
    Stream.Free;
  end;
end;

initialization
  ResetLevelThemes;
  DotFormat := DefaultFormatSettings;
  DotFormat.DecimalSeparator := '.';
end.
