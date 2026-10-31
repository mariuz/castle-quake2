{ CGE editor helpers for TQuakeMap: a dropdown of the PAK's maps for
  MapName, file dialogs for PakUrl and LevelUrl, and a "Reload Map" verb
  (right-click the component in the hierarchy).

  Listed in editor_units, so only the custom editor uses it; everything
  that needs the LCL is inside CASTLE_DESIGN_MODE, and the game never
  uses this unit. }
unit QuakeMapEditors;

{$mode objfpc}{$H+}

interface

implementation

{$ifdef CASTLE_DESIGN_MODE}

uses
  SysUtils, Classes, PropEdits, ComponentEditors, CastleDialogs, CastleLog,
  QuakeMap;

type
  { MapName: choose from the maps of the loaded PAKs (typing works too:
    "rand<seed>" builds a random level) }
  TQuakeMapNamePropertyEditor = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
  end;

  { PakUrl: open a .pak file }
  TQuakePakUrlPropertyEditor = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

  { LevelUrl: open a level editor .json file }
  TQuakeLevelUrlPropertyEditor = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

  { Verb "Reload Map" }
  TQuakeMapComponentEditor = class(TComponentEditor)
  public
    function GetVerbCount: Integer; override;
    function GetVerb(Index: Integer): String; override;
    procedure ExecuteVerb(Index: Integer); override;
  end;

{ Open dialog for a string property; True and the URL if one was chosen }
function ChooseUrl(const Current, Filter: String; out Url: String): Boolean;
var
  Dialog: TCastleOpenDialog;
begin
  Dialog := TCastleOpenDialog.Create(nil);
  try
    Dialog.Filter := Filter;
    Dialog.AdviceDataDirectory := True;
    if Current = '' then
      Dialog.URL := 'castle-data:/'
    else
      Dialog.URL := Current;
    Result := Dialog.Execute;
    if Result then
      Url := Dialog.URL;
  finally
    FreeAndNil(Dialog);
  end;
end;

{ TQuakeMapNamePropertyEditor }

function TQuakeMapNamePropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := [paValueList, paSortList, paRevertable, paMultiSelect];
end;

procedure TQuakeMapNamePropertyEditor.GetValues(Proc: TGetStrProc);
var
  Maps: TStringList;
  I: Integer;
begin
  if not (GetComponent(0) is TQuakeMap) then
    Exit;
  Proc('');
  Maps := TQuakeMap(GetComponent(0)).AvailableMaps;
  try
    for I := 0 to Maps.Count - 1 do
      Proc(Maps[I]);
  finally
    Maps.Free;
  end;
end;

{ TQuakePakUrlPropertyEditor }

function TQuakePakUrlPropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := [paDialog, paRevertable, paMultiSelect];
end;

procedure TQuakePakUrlPropertyEditor.Edit;
var
  Url: String;
begin
  if ChooseUrl(GetStrValue, 'Quake 2 PAK (*.pak)|*.pak;*.PAK|All Files|*', Url) then
    SetStrValue(Url);
end;

{ TQuakeLevelUrlPropertyEditor }

function TQuakeLevelUrlPropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := [paDialog, paRevertable, paMultiSelect];
end;

procedure TQuakeLevelUrlPropertyEditor.Edit;
var
  Url: String;
begin
  if ChooseUrl(GetStrValue, 'Castle Quake 2 Level (*.json)|*.json|All Files|*', Url) then
    SetStrValue(Url);
end;

{ TQuakeMapComponentEditor }

function TQuakeMapComponentEditor.GetVerbCount: Integer;
begin
  Result := (inherited GetVerbCount) + 1;
end;

function TQuakeMapComponentEditor.GetVerb(Index: Integer): String;
begin
  if Index < inherited GetVerbCount then
    Result := inherited GetVerb(Index)
  else
    Result := 'Reload Map';
end;

procedure TQuakeMapComponentEditor.ExecuteVerb(Index: Integer);
begin
  if Index < inherited GetVerbCount then
    inherited ExecuteVerb(Index)
  else
  if Component is TQuakeMap then
  begin
    TQuakeMap(Component).ReloadMap;
    WritelnLog('QuakeMap', 'Reloaded "%s"', [TQuakeMap(Component).MapName]);
  end;
end;

initialization
  RegisterPropertyEditor(TypeInfo(String), TQuakeMap, 'MapName', TQuakeMapNamePropertyEditor);
  RegisterPropertyEditor(TypeInfo(String), TQuakeMap, 'PakUrl', TQuakePakUrlPropertyEditor);
  RegisterPropertyEditor(TypeInfo(String), TQuakeMap, 'LevelUrl', TQuakeLevelUrlPropertyEditor);
  RegisterComponentEditor(TQuakeMap, TQuakeMapComponentEditor);
{$endif}
end.
