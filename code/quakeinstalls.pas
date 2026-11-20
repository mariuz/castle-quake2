{ Finds Quake II installations on this computer: GOG (Galaxy's registry
  entries, its default folders), Steam (every library in
  libraryfolders.vdf, "steamapps/common/Quake 2") and a few common folders.
  An installation is a folder with baseq2/pak0.pak, or Quake II
  Remastered's rerelease/baseq2 (pak0.pak or .pkz). Used for
  "-basedir auto / gog / steam" and when no baseq2 is next to the game. }
unit QuakeInstalls;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TQuakeInstall = record
    { The folder holding baseq2 (and rerelease/ for the remaster) }
    Root: String;
    { 'GOG', 'Steam' or 'folder' }
    Source: String;
    { Has Quake II Remastered's rerelease/baseq2 }
    Remastered: Boolean;
  end;
  TQuakeInstallList = array of TQuakeInstall;

{ The library folders listed in Steam's steamapps/libraryfolders.vdf text
  (its "path" values, "\\" unescaped) }
function ParseSteamLibraryPaths(const Vdf: String): TStringList;

{ Root holds Quake II data: baseq2/pak0.pak, or rerelease/baseq2 with
  pak0.pak or a .pkz }
function HasQuake2Data(const Root: String): Boolean;
function HasRemasterData(const Root: String): Boolean;

{ Every installation found, remastered ones first, no folder twice.
  SourceFilter '' = all, else 'gog' / 'steam' (case-insensitive) }
function FindQuake2Installs(const SourceFilter: String = ''): TQuakeInstallList;

{ "GOG: F:\Games\Quake II (remastered)" }
function InstallDescription(const Install: TQuakeInstall): String;

implementation

uses
  {$ifdef MSWINDOWS} Registry, Windows, {$endif}
  StrUtils;

function ParseSteamLibraryPaths(const Vdf: String): TStringList;
var
  Lines: TStringList;
  Line, Key, Value: String;
  I, Q1, Q2, Q3, Q4: Integer;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Vdf;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      { "path"		"C:\\Program Files (x86)\\Steam" }
      Q1 := Pos('"', Line);
      if Q1 <> 1 then
        Continue;
      Q2 := PosEx('"', Line, Q1 + 1);
      if Q2 = 0 then
        Continue;
      Key := Copy(Line, Q1 + 1, Q2 - Q1 - 1);
      if not SameText(Key, 'path') then
        Continue;
      Q3 := PosEx('"', Line, Q2 + 1);
      Q4 := RPos('"', Line);
      if (Q3 = 0) or (Q4 <= Q3) then
        Continue;
      Value := StringReplace(Copy(Line, Q3 + 1, Q4 - Q3 - 1), '\\', '\', [rfReplaceAll]);
      if Value <> '' then
        Result.Add(Value);
    end;
  finally
    Lines.Free;
  end;
end;

function DirHasPkz(const Dir: String): Boolean;
var
  SR: TSearchRec;
begin
  Result := False;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.pkz', faAnyFile, SR) = 0 then
  try
    Result := True;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function HasRemasterData(const Root: String): Boolean;
var
  Dir: String;
begin
  Dir := IncludeTrailingPathDelimiter(Root) + 'rerelease' + PathDelim + 'baseq2';
  Result := FileExists(IncludeTrailingPathDelimiter(Dir) + 'pak0.pak') or
    (DirectoryExists(Dir) and DirHasPkz(Dir));
end;

function HasQuake2Data(const Root: String): Boolean;
begin
  Result := (Root <> '') and
    (FileExists(IncludeTrailingPathDelimiter(Root) + 'baseq2' + PathDelim + 'pak0.pak') or
     HasRemasterData(Root));
end;

function InstallDescription(const Install: TQuakeInstall): String;
begin
  Result := Install.Source + ': ' + Install.Root;
  if Install.Remastered then
    Result := Result + ' (remastered)';
end;

type
  TFinder = class
    List: TQuakeInstallList;
    procedure Consider(const Root, Source: String);
  end;

procedure TFinder.Consider(const Root, Source: String);
var
  R: String;
  I: Integer;
  Item: TQuakeInstall;
begin
  R := ExcludeTrailingPathDelimiter(Root);
  if not HasQuake2Data(R) then
    Exit;
  for I := 0 to High(List) do
    if SameFileName(ExpandFileName(List[I].Root), ExpandFileName(R)) then
      Exit;
  Item.Root := R;
  Item.Source := Source;
  Item.Remastered := HasRemasterData(R);
  SetLength(List, Length(List) + 1);
  List[High(List)] := Item;
end;

{ Steam folders: the install itself and its library folders' "Quake 2" }
procedure AddSteam(const Finder: TFinder; const SteamDir: String);
var
  Vdf: String;
  Libs: TStringList;
  S: TStringStream;
  I: Integer;
begin
  if (SteamDir = '') or not DirectoryExists(SteamDir) then
    Exit;
  Libs := nil;
  Vdf := IncludeTrailingPathDelimiter(SteamDir) + 'steamapps' + PathDelim + 'libraryfolders.vdf';
  if FileExists(Vdf) then
  begin
    S := TStringStream.Create('');
    try
      try
        S.LoadFromFile(Vdf);
        Libs := ParseSteamLibraryPaths(S.DataString);
      except
        Libs := nil;
      end;
    finally
      S.Free;
    end;
  end;
  if Libs = nil then
    Libs := TStringList.Create;
  try
    Libs.Insert(0, SteamDir);
    for I := 0 to Libs.Count - 1 do
      Finder.Consider(IncludeTrailingPathDelimiter(Libs[I]) + 'steamapps' + PathDelim + 'common' +
        PathDelim + 'Quake 2', 'Steam');
  finally
    Libs.Free;
  end;
end;

{$ifdef MSWINDOWS}
function RegString(const Root: HKEY; const Key, Name: String): String;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := Root;
    if Reg.OpenKeyReadOnly(Key) then
    try
      if Reg.ValueExists(Name) then
        Result := Reg.ReadString(Name);
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

{ GOG Galaxy and the GOG installers: HKLM\SOFTWARE\(WOW6432Node\)GOG.com\Games\<id>
  with gameName and path }
procedure AddGogRegistry(const Finder: TFinder; const Key: String);
var
  Reg: TRegistry;
  Ids: TStringList;
  I: Integer;
  Name, Path: String;
begin
  Ids := TStringList.Create;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if Reg.OpenKeyReadOnly(Key) then
    begin
      Reg.GetKeyNames(Ids);
      Reg.CloseKey;
    end;
    for I := 0 to Ids.Count - 1 do
      if Reg.OpenKeyReadOnly(Key + '\' + Ids[I]) then
      try
        Name := '';
        Path := '';
        if Reg.ValueExists('gameName') then
          Name := Reg.ReadString('gameName');
        if Reg.ValueExists('path') then
          Path := Reg.ReadString('path');
        { "Quake II", "Quake II: Quad Damage", "Quake II Enhanced"; not III }
        if (Pos('QUAKE II', UpperCase(Name)) > 0) and (Pos('QUAKE III', UpperCase(Name)) = 0) then
          Finder.Consider(Path, 'GOG');
      finally
        Reg.CloseKey;
      end;
  finally
    Reg.Free;
    Ids.Free;
  end;
end;
{$endif}

function FindQuake2Installs(const SourceFilter: String): TQuakeInstallList;
var
  Finder: TFinder;
  WantGog, WantSteam, WantFolders: Boolean;
  Remastered, Original: TQuakeInstallList;
  I: Integer;
  {$ifdef MSWINDOWS}
  Drive: Char;
  Pf86: String;
  {$else}
  Home: String;
  {$endif}
begin
  WantGog := (SourceFilter = '') or SameText(SourceFilter, 'gog');
  WantSteam := (SourceFilter = '') or SameText(SourceFilter, 'steam');
  WantFolders := SourceFilter = '';
  Finder := TFinder.Create;
  try
    {$ifdef MSWINDOWS}
    if WantGog then
    begin
      AddGogRegistry(Finder, 'SOFTWARE\WOW6432Node\GOG.com\Games');
      AddGogRegistry(Finder, 'SOFTWARE\GOG.com\Games');
      Pf86 := SysUtils.GetEnvironmentVariable('ProgramFiles(x86)');
      if Pf86 = '' then
        Pf86 := 'C:\Program Files (x86)';
      Finder.Consider(Pf86 + '\GOG Galaxy\Games\Quake II Enhanced', 'GOG');
      Finder.Consider(Pf86 + '\GOG Galaxy\Games\Quake II', 'GOG');
      for Drive := 'C' to 'F' do
      begin
        Finder.Consider(Drive + ':\GOG Games\Quake II Enhanced', 'GOG');
        Finder.Consider(Drive + ':\GOG Games\Quake II', 'GOG');
      end;
    end;
    if WantSteam then
    begin
      AddSteam(Finder, StringReplace(RegString(HKEY_CURRENT_USER, 'Software\Valve\Steam', 'SteamPath'),
        '/', '\', [rfReplaceAll]));
      AddSteam(Finder, RegString(HKEY_LOCAL_MACHINE, 'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'));
      Pf86 := SysUtils.GetEnvironmentVariable('ProgramFiles(x86)');
      if Pf86 <> '' then
        AddSteam(Finder, Pf86 + '\Steam');
    end;
    if WantFolders then
      for Drive := 'C' to 'F' do
      begin
        Finder.Consider(Drive + ':\Quake2', 'folder');
        Finder.Consider(Drive + ':\Games\Quake II', 'folder');
      end;
    {$else}
    Home := SysUtils.GetEnvironmentVariable('HOME');
    if WantSteam and (Home <> '') then
    begin
      AddSteam(Finder, Home + '/.steam/steam');
      AddSteam(Finder, Home + '/.local/share/Steam');
      AddSteam(Finder, Home + '/.var/app/com.valvesoftware.Steam/.local/share/Steam');
      AddSteam(Finder, Home + '/Library/Application Support/Steam');
    end;
    if WantGog and (Home <> '') then
    begin
      Finder.Consider(Home + '/GOG Games/Quake II Enhanced', 'GOG');
      Finder.Consider(Home + '/GOG Games/Quake II', 'GOG');
      Finder.Consider(Home + '/Games/Heroic/Quake II Enhanced', 'GOG');
      Finder.Consider(Home + '/Games/Heroic/Quake II', 'GOG');
    end;
    if WantFolders then
    begin
      if Home <> '' then
      begin
        Finder.Consider(Home + '/.yq2', 'folder');
        Finder.Consider(Home + '/quake2', 'folder');
      end;
      Finder.Consider('/usr/share/games/quake2', 'folder');
      Finder.Consider('/usr/local/share/games/quake2', 'folder');
    end;
    {$endif}
    { Remastered first: it has the most (the remaster's maps and models) }
    Remastered := nil;
    Original := nil;
    for I := 0 to High(Finder.List) do
      if Finder.List[I].Remastered then
      begin
        SetLength(Remastered, Length(Remastered) + 1);
        Remastered[High(Remastered)] := Finder.List[I];
      end else
      begin
        SetLength(Original, Length(Original) + 1);
        Original[High(Original)] := Finder.List[I];
      end;
    SetLength(Result, Length(Remastered) + Length(Original));
    for I := 0 to High(Remastered) do
      Result[I] := Remastered[I];
    for I := 0 to High(Original) do
      Result[Length(Remastered) + I] := Original[I];
  finally
    Finder.Free;
  end;
end;

end.
