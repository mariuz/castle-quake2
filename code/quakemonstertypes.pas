{ Monster types as components, editable in the CGE editor.

  data/monsters.castle-transform holds one TQuakeMonsterType per monster
  class, with its tunables (health, speed, attack, damage, ranges, sounds)
  as published properties. Open it in the CGE editor to balance monsters:
  each type shows its MD2 model there. LoadMonsterTypes applies the design
  over the built-in DefaultMonsterDefs table at startup. }
unit QuakeMonsterTypes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleClassUtils, CastleTransform, CastleVectors,
  QuakeEntities, QuakeMd2;

type
  { One monster class (e.g. monster_soldier) and its tunables.
    A TCastleTransform, so the editor can show its model. }
  TQuakeMonsterType = class(TCastleTransform)
  strict private
    FDef: TQuakeMonsterDef;
    FPreview: TQuakeMd2Instance;
    procedure SetMonsterClass(const Value: String);
    procedure SetModel(const Value: String);
    procedure SetSkin(const Value: Integer);
    procedure UpdatePreview;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Loaded; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;
    { Monster definition with these properties }
    property Def: TQuakeMonsterDef read FDef write FDef;
    { Set all properties from a definition (and refresh the preview) }
    procedure Assign(const ADef: TQuakeMonsterDef); reintroduce;
  published
    { Entity classname in the maps, e.g. "monster_soldier" }
    property MonsterClass: String read FDef.ClassName write SetMonsterClass;
    { MD2 model path in the PAK }
    property Model: String read FDef.Model write SetModel;
    property Skin: Integer read FDef.Skin write SetSkin default 0;
    property Health: Integer read FDef.Health write FDef.Health default 0;
    { Run speed, Quake units per second }
    property Speed: Single read FDef.Speed write FDef.Speed;
    property Attack: TAttackKind read FDef.Attack write FDef.Attack default akMelee;
    { Damage per hit (per pellet for akPellets) }
    property Damage: Integer read FDef.Damage write FDef.Damage default 0;
    { Distance (Quake units) from which the monster attacks }
    property AttackRange: Single read FDef.AttackRange write FDef.AttackRange;
    { Seconds between attacks }
    property AttackCooldown: Single read FDef.AttackCooldown write FDef.AttackCooldown;
    property Flying: Boolean read FDef.Flying write FDef.Flying default False;
    { Sounds are sound/<SoundDir>/<name>.wav }
    property SoundDir: String read FDef.SoundDir write FDef.SoundDir;
    property SightSound: String read FDef.SightSound write FDef.SightSound;
    property PainSound: String read FDef.PainSound write FDef.PainSound;
    property DeathSound: String read FDef.DeathSound write FDef.DeathSound;
    property AttackSound: String read FDef.AttackSound write FDef.AttackSound;
  end;

const
  MonsterTypesUrl = 'castle-data:/monsters.castle-transform';

{ Apply the monster types of a design (TQuakeMonsterType anywhere in it)
  to MonsterDefs: replace the definition with the same MonsterClass, or add
  a new one. Call before creating monsters. Returns the number applied. }
function LoadMonsterTypes(const Url: String = MonsterTypesUrl): Integer;

{ Root transform with a TQuakeMonsterType per entry of DefaultMonsterDefs,
  laid out in a row (to regenerate data/monsters.castle-transform). }
function CreateDefaultMonsterTypes(const AOwner: TComponent): TCastleTransform;

var
  { Show models in TQuakeMonsterType also outside the editor (tests) }
  PreviewMonsterTypes: Boolean = False;

implementation

uses
  Math,
  CastleComponentSerialize, CastleLog, CastleUriUtils, CastleUtils, CastleStringUtils,
  QuakePak, QuakePalette;

const
  DefaultPakUrl = 'castle-data:/paks/quake2_demo.pak';

{ TQuakeMonsterType }

constructor TQuakeMonsterType.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDef := Default(TQuakeMonsterDef);
end;

destructor TQuakeMonsterType.Destroy;
begin
  FreeAndNil(FPreview);
  inherited Destroy;
end;

procedure TQuakeMonsterType.Loaded;
begin
  inherited Loaded;
  UpdatePreview;
end;

function TQuakeMonsterType.PropertySections(const PropertyName: String): TPropertySections;
begin
  if ArrayContainsString(PropertyName, ['MonsterClass', 'Model', 'Skin', 'Health', 'Speed',
    'Attack', 'Damage', 'AttackRange', 'AttackCooldown', 'Flying']) then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

procedure TQuakeMonsterType.Assign(const ADef: TQuakeMonsterDef);
begin
  FDef := ADef;
  UpdatePreview;
end;

procedure TQuakeMonsterType.SetMonsterClass(const Value: String);
begin
  FDef.ClassName := LowerCase(Value);
end;

procedure TQuakeMonsterType.SetModel(const Value: String);
begin
  if FDef.Model = Value then
    Exit;
  FDef.Model := Value;
  if not (csLoading in ComponentState) then
    UpdatePreview;
end;

procedure TQuakeMonsterType.SetSkin(const Value: Integer);
begin
  if FDef.Skin = Value then
    Exit;
  FDef.Skin := Value;
  if not (csLoading in ComponentState) then
    UpdatePreview;
end;

procedure TQuakeMonsterType.UpdatePreview;
begin
  FreeAndNil(FPreview);
  if not (CastleDesignMode or PreviewMonsterTypes) or (FDef.Model = '') then
    Exit;
  { In the editor nothing else may have loaded the Quake data yet }
  Pak.RegisterProtocol;
  Palette.RegisterProtocol;
  if not Pak.FileExists(FDef.Model) and not Pak.HasPak(DefaultPakUrl) and UriFileExists(DefaultPakUrl) then
    Pak.AddFile(DefaultPakUrl);
  if not Palette.HasPalette then
    Palette.LoadFromPak;
  FPreview := Md2Manager.CreateInstance(FDef.Model, FDef.Skin);
  if FPreview = nil then
    Exit;
  FPreview.Scene.SetTransient;
  FPreview.Scene.Collides := False;
  FPreview.Scene.Pickable := False;
  Add(FPreview.Scene);
end;

{ Global functions }

function LoadMonsterTypes(const Url: String): Integer;
var
  Owner: TComponent;
  I, J: Integer;
  MonsterType: TQuakeMonsterType;
  Found: Boolean;
begin
  Result := 0;
  if not UriFileExists(Url) then
    Exit;
  Owner := TComponent.Create(nil);
  try
    TransformLoad(Url, Owner);
    for I := 0 to Owner.ComponentCount - 1 do
      if Owner.Components[I] is TQuakeMonsterType then
      begin
        MonsterType := TQuakeMonsterType(Owner.Components[I]);
        if MonsterType.MonsterClass = '' then
          Continue;
        Found := False;
        for J := 0 to High(MonsterDefs) do
          if MonsterDefs[J].ClassName = MonsterType.MonsterClass then
          begin
            MonsterDefs[J] := MonsterType.Def;
            Found := True;
            Break;
          end;
        if not Found then
        begin
          SetLength(MonsterDefs, Length(MonsterDefs) + 1);
          MonsterDefs[High(MonsterDefs)] := MonsterType.Def;
        end;
        Inc(Result);
      end;
  finally
    Owner.Free;
  end;
  WritelnLog('QuakeMonsterTypes', 'Loaded %d monster types from "%s"', [Result, Url]);
end;

function CreateDefaultMonsterTypes(const AOwner: TComponent): TCastleTransform;
const
  Spacing = 96;
var
  I: Integer;
  MonsterType: TQuakeMonsterType;
begin
  Result := TCastleTransform.Create(AOwner);
  Result.Name := 'MonsterTypes';
  for I := 0 to High(DefaultMonsterDefs) do
  begin
    MonsterType := TQuakeMonsterType.Create(AOwner);
    MonsterType.Name := StringReplace(DefaultMonsterDefs[I].ClassName, 'monster_', '', []);
    MonsterType.Assign(DefaultMonsterDefs[I]);
    { A row along X, models facing +Z (the editor's default camera) }
    MonsterType.Translation := Vector3(I * Spacing, 0, 0);
    MonsterType.Rotation := Vector4(0, 1, 0, -Pi / 2);
    Result.Add(MonsterType);
  end;
end;

initialization
  RegisterSerializableComponent(TQuakeMonsterType, 'Quake 2 Monster Type');
end.
