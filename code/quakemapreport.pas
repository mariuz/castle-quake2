{ Map compatibility report: which entity classnames of the maps in the
  loaded PAKs the game handles. Run the game with
    --map-report report.md
  to load every map through TQuakeWorld.LoadMap and write the report
  (load times, counts, unsupported and partially supported classnames). }
unit QuakeMapReport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  QuakeBsp;

type
  TClassSupport = (csSupported, csPartial, csUnsupported);

  { Results of loading one map }
  TMapReportEntry = record
    MapName: String;
    Loaded: Boolean;
    LoadSeconds: Single;
    Entities, Monsters, Items, Faces: Integer;
    Partial, Unsupported: Integer;
  end;

  { Collects map results and classname counts, writes Markdown }
  TMapReport = class
  strict private
    type
      TClassInfo = class
        Count: Integer;
        Maps: TStringList;
        constructor Create;
        destructor Destroy; override;
      end;
      TClassDict = specialize TObjectDictionary<String, TClassInfo>;
    var
      FEntries: specialize TList<TMapReportEntry>;
      FPartial, FUnsupported: TClassDict;
    procedure Note(const Dict: TClassDict; const CName, MapName: String);
    procedure WriteClassTable(const Lines: TStrings; const Dict: TClassDict; const WithNote: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    { Classify the entities of a loaded map and add its results }
    procedure AddMap(Entry: TMapReportEntry; const Bsp: TQuakeBsp);
    procedure AddFailedMap(const MapName: String);
    function MapCount: Integer;
    function UnsupportedCount: Integer;
    procedure SaveMarkdown(const FileName, PakList: String);
  end;

{ How well the game handles an entity classname; Note explains partial
  support }
function ClassSupport(const CName: String; out Note: String): TClassSupport;
{ The same for one entity, looking at its spawnflags too }
function EntitySupport(const Ent: TQuakeEntity; out Note: String): TClassSupport;

implementation

uses
  Math, StrUtils,
  QuakeEntities, QuakeGeometry, QuakeSettings, QuakeMonsterAttacks;

const
  { Spawned, used by targets, drawn or used as markers by the game code }
  SupportedClasses: array[0..55] of String = (
    { func_group: brushes the map compiler merged into the world }
    'func_group', 'worldspawn', 'info_player_start', 'info_player_deathmatch', 'info_player_coop',
    'info_player_intermission', 'info_null', 'info_notnull', 'misc_teleporter',
    'misc_teleporter_dest', 'path_corner', 'point_combat', 'light',
    'target_changelevel', 'target_crosslevel_target', 'target_crosslevel_trigger',
    'target_earthquake', 'target_explosion', 'target_goal', 'target_help', 'target_laser',
    'target_lightramp', 'target_secret', 'target_speaker', 'target_splash',
    'trigger_always', 'trigger_counter', 'trigger_hurt', 'trigger_key', 'trigger_multiple',
    'trigger_once', 'trigger_push', 'trigger_relay', 'trigger_monsterjump',
    'func_areaportal', 'func_button', 'func_door', 'func_door_rotating', 'func_door_secret',
    'func_explosive', 'func_plat', 'func_rotating', 'func_timer', 'func_train', 'func_water',
    'misc_banner', 'misc_deadsoldier', 'misc_explobox', 'misc_gib_head',
    'misc_satellite_dish', 'misc_strogg_ship',
    { monsters with the generic AI that is all they need }
    'monster_soldier_light', 'monster_soldier', 'monster_soldier_ss', 'monster_infantry',
    'monster_gunner');

function ClassSupport(const CName: String; out Note: String): TClassSupport;
var
  S: String;
begin
  Note := '';
  for S in SupportedClasses do
    if S = CName then
      Exit(csSupported);
  if FindItemDef(CName) <> nil then
    Exit(csSupported);
  if FindMonsterDef(CName) <> nil then
  begin
    if CName = 'monster_medic' then
      Note := 'no revive of dead monsters'
    else
    if (CName = 'monster_supertank') or (CName = 'monster_boss2') or (CName = 'monster_jorg') or
       (CName = 'monster_makron') then
      Note := 'boss with the generic monster AI'
    else
    if Length(MonsterAttackSeqs(CName)) > 0 then
      Note := 'Quake 2 attack frames, generic movement (no special moves)'
    else
      Note := 'generic monster AI (one attack, no special moves)';
    Exit(csPartial);
  end;
  if Copy(CName, 1, 8) = 'monster_' then
  begin
    Note := 'no definition: not spawned';
    Exit(csUnsupported);
  end;
  if CName = 'func_wall' then
  begin
    Note := 'TRIGGER_SPAWN / TOGGLE spawnflags not handled (plain walls are)';
    Exit(csPartial);
  end;
  if IsVisibleBrushClass(CName) then
  begin
    Note := 'drawn and solid as a static brush, no behaviour';
    Exit(csPartial);
  end;
  if Copy(CName, 1, 6) = 'light_' then
  begin
    Note := 'treated as a light (no model)';
    Exit(csPartial);
  end;
  Result := csUnsupported;
end;

function EntitySupport(const Ent: TQuakeEntity; out Note: String): TClassSupport;
begin
  { func_wall without TRIGGER_SPAWN / TOGGLE / START_ON is just a wall }
  if (Ent.ClassName = 'func_wall') and ((Ent.SpawnFlags and 7) = 0) then
  begin
    Note := '';
    Exit(csSupported);
  end;
  Result := ClassSupport(Ent.ClassName, Note);
end;

{ TMapReport.TClassInfo }

constructor TMapReport.TClassInfo.Create;
begin
  inherited Create;
  Maps := TStringList.Create;
  Maps.Sorted := True;
  Maps.Duplicates := dupIgnore;
end;

destructor TMapReport.TClassInfo.Destroy;
begin
  Maps.Free;
  inherited Destroy;
end;

{ TMapReport }

constructor TMapReport.Create;
begin
  inherited Create;
  FEntries := specialize TList<TMapReportEntry>.Create;
  FPartial := TClassDict.Create([doOwnsValues]);
  FUnsupported := TClassDict.Create([doOwnsValues]);
end;

destructor TMapReport.Destroy;
begin
  FEntries.Free;
  FPartial.Free;
  FUnsupported.Free;
  inherited Destroy;
end;

procedure TMapReport.Note(const Dict: TClassDict; const CName, MapName: String);
var
  Info: TClassInfo;
begin
  if not Dict.TryGetValue(CName, Info) then
  begin
    Info := TClassInfo.Create;
    Dict.Add(CName, Info);
  end;
  Inc(Info.Count);
  Info.Maps.Add(MapName);
end;

procedure TMapReport.AddMap(Entry: TMapReportEntry; const Bsp: TQuakeBsp);
var
  Ent: TQuakeEntity;
  NoteText: String;
begin
  Entry.Partial := 0;
  Entry.Unsupported := 0;
  Entry.Entities := Bsp.Entities.Count;
  Entry.Faces := Bsp.FaceCount;
  for Ent in Bsp.Entities do
  begin
    { Not spawned on this skill (deathmatch-only entities have all three) }
    if (Ent.SpawnFlags and SkillSpawnFlag(GameSkill)) <> 0 then
      Continue;
    case EntitySupport(Ent, NoteText) of
      csPartial:
        begin
          Inc(Entry.Partial);
          Note(FPartial, Ent.ClassName, Entry.MapName);
        end;
      csUnsupported:
        begin
          Inc(Entry.Unsupported);
          Note(FUnsupported, Ent.ClassName, Entry.MapName);
        end;
      else ;
    end;
  end;
  FEntries.Add(Entry);
end;

procedure TMapReport.AddFailedMap(const MapName: String);
var
  Entry: TMapReportEntry;
begin
  Entry := Default(TMapReportEntry);
  Entry.MapName := MapName;
  Entry.Loaded := False;
  FEntries.Add(Entry);
end;

function TMapReport.MapCount: Integer;
begin
  Result := FEntries.Count;
end;

function TMapReport.UnsupportedCount: Integer;
var
  Info: TClassInfo;
begin
  Result := 0;
  for Info in FUnsupported.Values do
    Result := Result + Info.Count;
end;

procedure TMapReport.WriteClassTable(const Lines: TStrings; const Dict: TClassDict;
  const WithNote: Boolean);
var
  Names: TStringList;
  CName, NoteText: String;
  Info: TClassInfo;
begin
  if Dict.Count = 0 then
  begin
    Lines.Add('None.');
    Exit;
  end;
  if WithNote then
  begin
    Lines.Add('| Classname | Entities | Maps | Note |');
    Lines.Add('| :--- | ---: | :--- | :--- |');
  end else
  begin
    Lines.Add('| Classname | Entities | Maps |');
    Lines.Add('| :--- | ---: | :--- |');
  end;
  Names := TStringList.Create;
  try
    for CName in Dict.Keys do
      Names.Add(CName);
    Names.Sort;
    for CName in Names do
    begin
      Info := Dict[CName];
      ClassSupport(CName, NoteText);
      if WithNote then
        Lines.Add(Format('| `%s` | %d | %s | %s |', [CName, Info.Count,
          StringReplace(Info.Maps.CommaText, ',', ', ', [rfReplaceAll]), NoteText]))
      else
        Lines.Add(Format('| `%s` | %d | %s |', [CName, Info.Count,
          StringReplace(Info.Maps.CommaText, ',', ', ', [rfReplaceAll])]));
    end;
  finally
    Names.Free;
  end;
end;

procedure TMapReport.SaveMarkdown(const FileName, PakList: String);
var
  Lines: TStringList;
  E: TMapReportEntry;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('# Map compatibility report');
    Lines.Add('');
    Lines.Add('Generated by `castle-quake2 --map-report` from: ' + PakList + '.');
    Lines.Add(Format('Every map was loaded with `TQuakeWorld.LoadMap` (skill %d); the entities spawned on that skill',
      [GameSkill]));
    Lines.Add('are checked against what the game handles (`QuakeMapReport.EntitySupport`).');
    Lines.Add('');
    Lines.Add('## Maps');
    Lines.Add('');
    Lines.Add('| Map | Loaded | Load time | Faces | Entities | Monsters | Items | Partial | Unsupported |');
    Lines.Add('| :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |');
    for E in FEntries do
      if E.Loaded then
        Lines.Add(Format('| %s | yes | %.2f s | %d | %d | %d | %d | %d | %d |', [E.MapName, E.LoadSeconds,
          E.Faces, E.Entities, E.Monsters, E.Items, E.Partial, E.Unsupported]))
      else
        Lines.Add(Format('| %s | **no** | | | | | | | |', [E.MapName]));
    Lines.Add('');
    Lines.Add('## Unsupported classnames');
    Lines.Add('');
    WriteClassTable(Lines, FUnsupported, False);
    Lines.Add('');
    Lines.Add('## Partially supported classnames');
    Lines.Add('');
    WriteClassTable(Lines, FPartial, True);
    Lines.SaveToFile(FileName);
  finally
    Lines.Free;
  end;
end;

end.
