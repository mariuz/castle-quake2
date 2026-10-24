{ Game initialization: window, views, PAK asset loading, and command-line parsing.
  This unit is cross-platform.
  It will be used by the platform-specific program or library file. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils,
  QuakePak, QuakePalette, QuakeSound, QuakeGeometry, QuakeMonsterTypes, QuakeSettings, QuakeGamepad, QuakeTouch, CastleConfig
  {$region 'Castle Initialization Uses'}
  // The content here may be automatically updated by CGE editor.
  , GameViewMenu
  , GameViewPlay
  {$endregion 'Castle Initialization Uses'};

var
  Window: TCastleWindow;
  AutoTestMap: String;
  MapReportFile: String;
  AutoTestPrefix: String;
  AutoTestDemo: String;
  CmdWarp: String;
  CmdBaseDir: String;
  CmdPaks: TStringList;

procedure ApplicationInitialize;

implementation

{ Load pak0.pak, pak1.pak ... from a directory (later paks override earlier ones). }
function AddPakDir(const Dir: String): Boolean;
var
  I: Integer;
  F: String;
begin
  Result := False;
  for I := 0 to 9 do
  begin
    F := IncludeTrailingPathDelimiter(Dir) + 'pak' + IntToStr(I) + '.pak';
    if FileExists(F) and Pak.AddFile(F) then
      Result := True;
  end;
end;

procedure ApplicationInitialize;
var
  I: Integer;
  LoadedAny: Boolean;
begin
  I := 1;
  while I <= Parameters.High do
  begin
    if (Parameters[I] = '--autotest') and (I + 2 <= Parameters.High) then
    begin
      AutoTestMap := Parameters[I + 1];
      AutoTestPrefix := Parameters[I + 2];
      Inc(I, 2);
    end else
    if (Parameters[I] = '--map-report') and (I + 1 <= Parameters.High) then
    begin
      MapReportFile := Parameters[I + 1];
      { Runs like an autotest: default options, nothing saved }
      AutoTestMap := 'report';
    end;
    if Parameters[I] = '--touch' then
      TouchControlsForced := True;
    if (Parameters[I] = '--demo') and (I + 1 <= Parameters.High) then
    begin
      AutoTestDemo := Parameters[I + 1];
      { "@file": a script file, e.g. one written by the record command }
      if (AutoTestDemo <> '') and (AutoTestDemo[1] = '@') then
        AutoTestDemo := FileToString(Copy(AutoTestDemo, 2, MaxInt));
      Inc(I);
    end else
    if ((Parameters[I] = '-warp') or (Parameters[I] = '--warp') or (Parameters[I] = '-map') or
        (Parameters[I] = '+map')) and (I + 1 <= Parameters.High) then
    begin
      CmdWarp := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-basedir') or (Parameters[I] = '--basedir')) and (I + 1 <= Parameters.High) then
    begin
      CmdBaseDir := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-gamma') or (Parameters[I] = '--gamma')) and (I + 1 <= Parameters.High) then
    begin
      LightmapGamma := StrToFloatDef(Parameters[I + 1], LightmapGamma);
      Inc(I);
    end else
    if ((Parameters[I] = '-pak') or (Parameters[I] = '--pak')) and (I + 1 <= Parameters.High) then
    begin
      CmdPaks.Add(Parameters[I + 1]);
      Inc(I);
    end;
    Inc(I);
  end;

  WritelnLog('GameInitialize', 'Parsed AutoTestMap="%s" Prefix="%s" Demo="%s"',
    [AutoTestMap, AutoTestPrefix, AutoTestDemo]);

  Window.Container.LoadSettings('castle-data:/CastleSettings.xml');

  Pak.RegisterProtocol;
  Palette.RegisterProtocol;

  { Touch screens get a larger interface (Options -> Interface Size: Auto) }
  TouchInterface := TouchControlsWanted;

  { Quake 2 data: bundled demo PAK first, then a full install (overrides it),
    then PAKs given explicitly on the command line. }
  LoadedAny := False;
  if UriFileExists('castle-data:/paks/quake2_demo.pak') then
    LoadedAny := Pak.AddFile('castle-data:/paks/quake2_demo.pak') or LoadedAny;
  if AddPakDir('baseq2') then
    LoadedAny := True;
  if CmdBaseDir <> '' then
  begin
    if AddPakDir(IncludeTrailingPathDelimiter(CmdBaseDir) + 'baseq2') then
      LoadedAny := True;
    if AddPakDir(CmdBaseDir) then
      LoadedAny := True;
  end;
  for I := 0 to CmdPaks.Count - 1 do
    if Pak.AddFile(CmdPaks[I]) then
      LoadedAny := True;

  if not LoadedAny then
    WritelnWarning('GameInitialize',
      'No Quake 2 PAK found! Put pak0.pak in data/paks/quake2_demo.pak or baseq2/, ' +
      'or pass -basedir <quake2 dir> / -pak <file>');

  Palette.LoadFromPak;
  { Player options; autotests use the defaults (results must not depend on
    the user's settings) and don't save }
  if AutoTestMap = '' then
  begin
    UserConfig.Load;
    Settings.Load;
  end else
    Settings.Persistent := False;
  GameSkill := Settings.Skill;
  { Game controllers; not in autotests (results must not depend on devices) }
  if AutoTestMap = '' then
    InitializeGamepads;
  Settings.ApplyAudio;
  { Designs editable in the CGE editor: monster tunables, named sounds }
  LoadMonsterTypes;
  Sounds.LoadNamedSounds;
  Sounds.ConfigureEngine;
  Sounds.PreloadCommonSounds;

  { Create views (see https://castle-engine.io/views ). }
  {$region 'Castle View Creation'}
  // The content here may be automatically updated by CGE editor.
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);
  {$endregion 'Castle View Creation'}

  if AutoTestMap <> '' then
  begin
    ViewPlay.AutoTestMap := AutoTestMap;
    ViewPlay.MapReportFile := MapReportFile;
    ViewPlay.AutoTestPrefix := AutoTestPrefix;
    ViewPlay.AutoTestDemo := AutoTestDemo;
    Window.Container.View := ViewPlay;
  end else
  if CmdWarp <> '' then
  begin
    ViewPlay.MapName := CmdWarp;
    Window.Container.View := ViewPlay;
  end else
    Window.Container.View := ViewMenu;
end;

initialization
  CmdPaks := TStringList.Create;
  ApplicationProperties.ApplicationName := 'castle-quake2';
  ApplicationProperties.Version := '0.8.0';
  LogFileName := 'castle-quake2.log';
  InitializeLog;
  Application.OnInitialize := @ApplicationInitialize;

  Window := TCastleWindow.Create(Application);
  Window.Caption := 'Castle Quake 2';
  Window.Width := 1600;
  Window.Height := 900;
  Application.MainWindow := Window;
  Window.ParseParameters;

finalization
  { Stop the current view before the Quake* units finalize (they finalize
    before CastleWindow, which frees the views): this frees the world, the
    design and its scenes while the model / texture caches still exist. }
  if (Window <> nil) and (Window.Container <> nil) then
    Window.Container.View := nil;
  CmdPaks.Free;
end.
