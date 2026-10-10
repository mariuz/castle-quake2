{ Quake 2 sound effects and music player using Castle Game Engine audio. }
unit QuakeSound;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleSoundEngine, CastleSoundBase, CastleTransform, CastleBehaviors, CastleLog, CastleUriUtils,
  QuakePak;

type
  { Sound manager for Quake SFX and music }
  TQuakeSounds = class
  private
    FSoundCache: specialize TObjectDictionary<String, TCastleSound>;
    FMusicSound: TCastleSound;
    FCurrentMusicTrack: String;
    FEnabled: Boolean;
    function GetSound(const APath: String): TCastleSound;
  public
    constructor Create;
    destructor Destroy; override;

    { Play 2D non-positional sound (weapon fire, UI, player damage) }
    procedure Play(const APath: String; const Volume: Single = 1.0);

    { Play 3D positional sound attached to a transform (door, monster, elevator).
      Attenuation as in Quake 2: 1 = normal, 2 = idle, 3 = static (fades fastest). }
    procedure PlayAt(const APath: String; const ATransform: TCastleTransform;
      const Volume: Single = 1.0; const Attenuation: Single = 1.0);

    { Sound for a path with Quake 2 distance attenuation (<= 0: heard everywhere).
      nil if the sound isn't in the PAK. Cached per path and attenuation. }
    function SpatialSound(const APath: String; const Attenuation: Single): TCastleSound;

    { Use Quake-like linear distance attenuation for all spatial sounds }
    procedure ConfigureEngine;

    { Play background music from castle-data:/music/<TrackName> if it exists.
      Quake 2 music is CD audio, so place ripped tracks there as trackNN.ogg. }
    procedure PlayMusic(const TrackName: String);

    { Music file name for a worldspawn "sounds" CD track number (0 = none) }
    function TrackFileName(const CdTrack: Integer): String;

    { Stop music }
    procedure StopMusic;

    { Preload common player and weapon sounds }
    procedure PreloadCommonSounds;

    property Enabled: Boolean read FEnabled write FEnabled;
  end;

var
  Sounds: TQuakeSounds;

implementation

constructor TQuakeSounds.Create;
begin
  inherited Create;
  FSoundCache := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FEnabled := True;
  FMusicSound := nil;
  FCurrentMusicTrack := '';
end;

destructor TQuakeSounds.Destroy;
begin
  StopMusic;
  FSoundCache.Free;
  inherited Destroy;
end;

function TQuakeSounds.GetSound(const APath: String): TCastleSound;
var
  NormPath: String;
begin
  NormPath := LowerCase(APath);
  if NormPath = '' then
    Exit(nil);
  if not FSoundCache.TryGetValue(NormPath, Result) then
  begin
    { Missing sounds are cached as nil, so they are reported only once }
    if not Pak.FileExists(NormPath) then
    begin
      WritelnLog('QuakeSound', 'Sound "%s" not in PAK, skipping', [NormPath]);
      FSoundCache.Add(NormPath, nil);
      Exit(nil);
    end;
    Result := TCastleSound.Create(nil);
    Result.Url := 'quakepak:/' + NormPath;
    FSoundCache.Add(NormPath, Result);
  end;
end;

procedure TQuakeSounds.Play(const APath: String; const Volume: Single);
var
  Snd: TCastleSound;
  Playing: TCastlePlayingSound;
begin
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  try
    Snd := GetSound(APath);
    if Snd <> nil then
    begin
      Playing := TCastlePlayingSound.Create(nil);
      Playing.Sound := Snd;
      Playing.Volume := Volume;
      Playing.FreeOnStop := True;
      SoundEngine.Play(Playing);
    end;
  except
    on E: Exception do
      WritelnWarning('QuakeSound', 'Failed to play "%s": %s', [APath, E.Message]);
  end;
end;

function TQuakeSounds.SpatialSound(const APath: String; const Attenuation: Single): TCastleSound;
var
  Base: TCastleSound;
  Key: String;
begin
  Result := nil;
  Base := GetSound(APath);
  if Base = nil then
    Exit;
  Key := LowerCase(APath) + '@' + FloatToStr(Attenuation);
  if not FSoundCache.TryGetValue(Key, Result) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := Base.Url;
    { Quake 2 S_SpatializeOrigin: full volume up to 80 units (SOUND_FULLVOLUME),
      then linear falloff of 0.0005 * attenuation per unit }
    Result.ReferenceDistance := 80;
    if Attenuation > 0 then
      Result.MaxDistance := 80 + 1 / (0.0005 * Attenuation)
    else
      Result.MaxDistance := 100000;
    FSoundCache.Add(Key, Result);
  end;
end;

procedure TQuakeSounds.ConfigureEngine;
begin
  if SoundEngine <> nil then
    SoundEngine.DistanceModel := dmLinear;
end;

procedure TQuakeSounds.PlayAt(const APath: String; const ATransform: TCastleTransform;
  const Volume: Single; const Attenuation: Single);
var
  Snd: TCastleSound;
  Source: TCastleSoundSource;
begin
  if not FEnabled or (SoundEngine = nil) or (ATransform = nil) then
    Exit;

  try
    Snd := SpatialSound(APath, Attenuation);
    if Snd = nil then
      Exit;

    Source := ATransform.FindBehavior(TCastleSoundSource) as TCastleSoundSource;
    if Source = nil then
    begin
      Source := TCastleSoundSource.Create(ATransform);
      Source.Spatial := True;
      ATransform.AddBehavior(Source);
    end;
    Source.Volume := Volume;
    Source.Play(Snd);
  except
    on E: Exception do
      WritelnWarning('QuakeSound', 'Failed to play 3D sound "%s": %s', [APath, E.Message]);
  end;
end;

procedure TQuakeSounds.PlayMusic(const TrackName: String);
var
  MusicUrl: String;
begin
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  if FCurrentMusicTrack = TrackName then
    Exit;

  StopMusic;

  MusicUrl := 'castle-data:/music/' + TrackName;
  if (TrackName = '') or not UriFileExists(MusicUrl) then
    Exit;
  try
    FMusicSound := TCastleSound.Create(nil);
    FMusicSound.Url := MusicUrl;
    SoundEngine.LoopingChannel[0].Volume := 0.7;
    SoundEngine.LoopingChannel[0].Sound := FMusicSound;
    FCurrentMusicTrack := TrackName;
    WritelnLog('QuakeSound', 'Playing music "%s"', [MusicUrl]);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakeSound', 'Could not play music track "%s": %s', [TrackName, E.Message]);
      FreeAndNil(FMusicSound);
    end;
  end;
end;

function TQuakeSounds.TrackFileName(const CdTrack: Integer): String;
begin
  if CdTrack <= 1 then
    Result := ''
  else
    Result := Format('track%.2d.ogg', [CdTrack]);
end;

procedure TQuakeSounds.StopMusic;
begin
  if SoundEngine <> nil then
    SoundEngine.LoopingChannel[0].Sound := nil;
  FreeAndNil(FMusicSound);
  FCurrentMusicTrack := '';
end;

procedure TQuakeSounds.PreloadCommonSounds;
begin
  { Warm up frequently used sounds }
  GetSound('sound/weapons/blastf1a.wav');
  GetSound('sound/weapons/shotgf1b.wav');
  GetSound('sound/weapons/sshotf1b.wav');
  GetSound('sound/weapons/machgf1b.wav');
  GetSound('sound/weapons/rocklf1a.wav');
  GetSound('sound/weapons/rocklx1a.wav');
  GetSound('sound/weapons/noammo.wav');
  GetSound('sound/items/pkup.wav');
  GetSound('sound/misc/w_pkup.wav');
  GetSound('sound/misc/am_pkup.wav');
  GetSound('sound/misc/ar1_pkup.wav');
  GetSound('sound/items/n_health.wav');
  GetSound('sound/player/male/pain100_1.wav');
  GetSound('sound/player/male/death1.wav');
  GetSound('sound/player/male/jump1.wav');
  GetSound('sound/doors/dr1_strt.wav');
  GetSound('sound/doors/dr1_end.wav');
end;

initialization
  Sounds := TQuakeSounds.Create;

finalization
  FreeAndNil(Sounds);
end.
