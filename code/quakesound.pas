{ Quake 2 sound effects and music player using Castle Game Engine audio. }
unit QuakeSound;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleSoundEngine, CastleSoundBase, CastleTransform, CastleBehaviors, CastleLog, CastleUriUtils,
  CastleClassUtils, CastleComponentSerialize, CastleStringUtils, Math,
  QuakePak;

type
  { A sound of data/sounds.castle-component: a TCastleSound (edit its Url,
    Volume, Pitch... in the CGE editor) used whenever the game plays
    QuakePath. Its component Name is the sound's readable name. }
  TQuakeNamedSound = class(TCastleSound)
  strict private
    FQuakePath: String;
    procedure SetQuakePath(const Value: String);
  public
    function PropertySections(const PropertyName: String): TPropertySections; override;
  published
    { Path the game code plays, e.g. "sound/items/pkup.wav" }
    property QuakePath: String read FQuakePath write SetQuakePath;
  end;

  { Quake 2 entity sound channels: a new sound on the same entity and
    channel replaces the playing one (CHAN_AUTO never does). }
  TQuakeSoundChannel = (chAuto, chWeapon, chVoice, chItem, chBody);

  { A one-shot sound, remembered while it plays on an entity channel }
  TQuakePlayingSound = class(TCastlePlayingSoundSource)
  public
    ChannelOwner: TObject;
    Channel: TQuakeSoundChannel;
    { Its gain at the listener when it started (for the limiter) }
    Load: Single;
    destructor Destroy; override;
  end;

  { A voice of the loop mixer: one per looping sound, played at the
    loudest emitter of that sound (Quake 2 S_AddLoopSounds) }
  TQuakeLoopVoice = class
  public
    Transform: TCastleTransform;
    Source: TCastleSoundSource;
    { Loudest request of the current frame }
    Requested: Boolean;
    BestGain, BestVolume: Single;
    BestPosition: TVector3;
    destructor Destroy; override;
  end;

const
  { Quake 2 attenuations }
  ATTN_NONE = 0;
  ATTN_NORM = 1;
  ATTN_IDLE = 2;
  ATTN_STATIC = 3;

type
  { Sound manager for Quake SFX and music }
  TQuakeSounds = class
  private
    FSoundCache: specialize TObjectDictionary<String, TCastleSound>;
    FChannelSounds: specialize TList<TQuakePlayingSound>;
    FLoopVoices: specialize TObjectDictionary<String, TQuakeLoopVoice>;
    FWorldParent: TCastleTransform;
    FListener: TVector3;
    { Owns the components of the named sounds design }
    FNamedOwner: TComponent;
    FNamedSounds: specialize TDictionary<String, TQuakeNamedSound>;
    FMusicSound: TCastleSound;
    { Every playing sound (for the limiter), loop voices apart }
    FActiveSounds: specialize TList<TQuakePlayingSound>;
    FListenerRight: TVector3;
    FLimiterGain, FMixLoad: Single;
    FCurrentMusicTrack: String;
    FEnabled: Boolean;
    function GetSound(const APath: String): TCastleSound;
    function SpatialSoundMult(const APath: String; const DistMult: Single): TCastleSound;
    { Stop the sound playing on Owner's Channel (not chAuto), remember New there }
    procedure UseChannel(const Owner: TObject; const Channel: TQuakeSoundChannel;
      const New: TQuakePlayingSound);
    function NewPlaying(const Snd: TCastleSound; const Volume: Single;
      const Owner: TObject; const Channel: TQuakeSoundChannel): TQuakePlayingSound;
  public
    constructor Create;
    destructor Destroy; override;

    { Play a 2D sound of the player (weapon fire, pain, pickups, UI).
      On a channel other than chAuto it replaces the player's previous
      sound there, like Quake 2 (rapid fire doesn't pile up). }
    procedure Play(const APath: String; const Volume: Single = 1.0;
      const Channel: TQuakeSoundChannel = chAuto);

    { Play a sound from where a transform is now (monster, mover...).
      Attenuation as in Quake 2: 0 = none (heard everywhere), 1 = normal,
      2 = idle, 3 = static (fades fastest). The sound keeps playing at
      that point when the transform is hidden or freed (gibs, kills). }
    procedure PlayAt(const APath: String; const ATransform: TCastleTransform;
      const Volume: Single = 1.0; const Attenuation: Single = 1.0;
      const Channel: TQuakeSoundChannel = chAuto);

    { Play a sound at a point in the world (explosions, impacts). Owner +
      Channel (optional) make it replace Owner's previous sound there. }
    procedure PlayAtPoint(const APath: String; const Position: TVector3;
      const Volume: Single = 1.0; const Attenuation: Single = 1.0;
      const Owner: TObject = nil; const Channel: TQuakeSoundChannel = chAuto);

    { Stop what plays on Owner's channel (nil Owner: the player's 2D sounds) }
    procedure StopChannel(const Owner: TObject; const Channel: TQuakeSoundChannel);

    { Sound for a path with Quake 2 distance attenuation (<= 0: heard everywhere).
      nil if the sound isn't in the PAK. Cached per path and attenuation. }
    function SpatialSound(const APath: String; const Attenuation: Single): TCastleSound;

    { Looping sounds (Quake 2 entity "s.sound": ambient speakers, moving
      doors and platforms). Every frame call BeginLoops, AddLoop for each
      active audible emitter, then EndLoops: each
      distinct sound plays once, from its loudest emitter, with Quake 2's
      loop attenuation (silent beyond ~413 units). Attenuation <= 0: heard
      everywhere at Volume. Needs WorldParent. }
    procedure BeginLoops(const Listener: TVector3);
    procedure AddLoop(const APath: String; const Position: TVector3; const Volume: Single = 1;
      const Attenuation: Single = 1);
    procedure EndLoops;
    { Stop the loops and take their voices out of WorldParent (when the
      world goes away; EndLoops puts them back) }
    procedure ClearLoops;
    { Number of loop voices playing (after EndLoops) }
    function PlayingLoopCount: Integer;
    { Where the loop voice of a sound plays (False if it isn't playing) }
    function LoopPosition(const APath: String; out Position: TVector3): Boolean;
    { Where the loop mixer's voices live (the viewport's Items) }
    property WorldParent: TCastleTransform read FWorldParent write FWorldParent;

    { Use the TQuakeNamedSound components of a design (by default
      data/sounds.castle-component) for their QuakePath. Returns their number. }
    function LoadNamedSounds(const Url: String = 'castle-data:/sounds.castle-component'): Integer;

    { Named sound for a path (nil if the design doesn't name it) }
    function NamedSound(const APath: String): TQuakeNamedSound;

    { Sound played for a path: the named sound or the PAK file (nil if neither) }
    function SoundFor(const APath: String): TCastleSound;

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
    { The listener's right (CGE coordinates), for Quake 2's stereo
      loudness (QuakePanLoudness) of the sounds started from now on }
    property ListenerRight: TVector3 read FListenerRight write FListenerRight;
    { Master limiter: once a frame, from the summed gains of the playing
      sounds and loops (MixLoad) moves LimiterGain towards
      LimiterTarget and sets SoundEngine.Volume to Master * LimiterGain }
    procedure UpdateMixer(const SecondsPassed, Master: Single);
    property LimiterGain: Single read FLimiterGain;
    property MixLoad: Single read FMixLoad;
    function ActiveSoundCount: Integer;
  end;

const
  { Summed gain above which the limiter turns the master volume down }
  LimiterThreshold = 3.0;

{ Quake 2's stereo spatialization (S_SpatializeOrigin) gives each ear
  0.5 * (1 -/+ Dot), Dot = listener right . direction to the sound:
  a sound straight ahead is 3 dB quieter than one at a side. OpenAL pans
  at constant power, so spatial sounds are scaled by the root of Quake's
  power, Sqrt(0.5 * (1 + Dot^2)), to keep the loudness. }
function QuakePanLoudness(const Dot: Single): Single;

{ The limiter's gain for a summed load: 1 up to Threshold, then a 2:1
  compression, Sqrt(Threshold / Load) (OpenAL Soft's own output limiter
  still catches peaks; this keeps busy fights from pumping it) }
function LimiterTarget(const Load, Threshold: Single): Single;

{ The limiter's gain after SecondsPassed: down fast (attack 0.03 s), up
  slowly (release 0.5 s) }
function LimiterStep(const Current, Target, SecondsPassed: Single): Single;

var
  Sounds: TQuakeSounds;

implementation

function QuakePanLoudness(const Dot: Single): Single;
var
  D: Single;
begin
  D := EnsureRange(Dot, -1, 1);
  Result := Sqrt(0.5 * (1 + D * D));
end;

function LimiterTarget(const Load, Threshold: Single): Single;
begin
  if Load <= Threshold then
    Result := 1
  else
    Result := Sqrt(Threshold / Load);
end;

function LimiterStep(const Current, Target, SecondsPassed: Single): Single;
var
  Time: Single;
begin
  if Target < Current then
    Time := 0.03
  else
    Time := 0.5;
  Result := Target + (Current - Target) * Exp(-Max(0, SecondsPassed) / Time);
end;

constructor TQuakeSounds.Create;
begin
  inherited Create;
  FActiveSounds := specialize TList<TQuakePlayingSound>.Create;
  FListenerRight := Vector3(1, 0, 0);
  FLimiterGain := 1;
  FSoundCache := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FNamedSounds := specialize TDictionary<String, TQuakeNamedSound>.Create;
  FChannelSounds := specialize TList<TQuakePlayingSound>.Create;
  FLoopVoices := specialize TObjectDictionary<String, TQuakeLoopVoice>.Create([doOwnsValues]);
  FEnabled := True;
  FMusicSound := nil;
  FCurrentMusicTrack := '';
end;

destructor TQuakeSounds.Destroy;
begin
  StopMusic;
  FreeAndNil(FLoopVoices);
  { Playing sounds outlive us (they free themselves on stop): forget them }
  FreeAndNil(FChannelSounds);
  FreeAndNil(FActiveSounds);
  FSoundCache.Free;
  FNamedSounds.Free;
  FNamedOwner.Free;
  inherited Destroy;
end;

function TQuakeSounds.GetSound(const APath: String): TCastleSound;
var
  NormPath: String;
begin
  NormPath := LowerCase(APath);
  if NormPath = '' then
    Exit(nil);
  if FNamedSounds.ContainsKey(NormPath) then
    Exit(FNamedSounds[NormPath]);
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

const
  { Quake 2 snd_dma.c: full volume within SOUND_FULLVOLUME units, loops fade
    with SOUND_LOOPATTENUATE per unit }
  SoundFullVolume = 80;
  SoundLoopAttenuate = 0.003;

{ Quake 2 S_StartSound: dist_mult = attenuation * 0.0005, or * 0.001 for
  ATTN_STATIC (3) }
function DistanceMult(const Attenuation: Single): Single;
begin
  if Attenuation <= 0 then
    Result := 0
  else
  if Attenuation >= 3 then
    Result := Attenuation * 0.001
  else
    Result := Attenuation * 0.0005;
end;

{ TQuakePlayingSound }

destructor TQuakePlayingSound.Destroy;
begin
  if (Sounds <> nil) and (Sounds.FChannelSounds <> nil) then
    Sounds.FChannelSounds.Remove(Self);
  if (Sounds <> nil) and (Sounds.FActiveSounds <> nil) then
    Sounds.FActiveSounds.Remove(Self);
  inherited Destroy;
end;

{ TQuakeLoopVoice }

destructor TQuakeLoopVoice.Destroy;
begin
  if Source <> nil then
    Source.Sound := nil;
  FreeAndNil(Source);
  FreeAndNil(Transform);
  inherited Destroy;
end;

{ TQuakeSounds }

procedure TQuakeSounds.UseChannel(const Owner: TObject; const Channel: TQuakeSoundChannel;
  const New: TQuakePlayingSound);
begin
  New.ChannelOwner := Owner;
  New.Channel := Channel;
  if Channel = chAuto then
    Exit;
  StopChannel(Owner, Channel);
  FChannelSounds.Add(New);
end;

procedure TQuakeSounds.StopChannel(const Owner: TObject; const Channel: TQuakeSoundChannel);
var
  I: Integer;
  Old: TQuakePlayingSound;
begin
  for I := FChannelSounds.Count - 1 downto 0 do
    if I < FChannelSounds.Count then
    begin
      Old := FChannelSounds[I];
      if (Old.ChannelOwner = Owner) and (Old.Channel = Channel) then
      begin
        FChannelSounds.Delete(I);
        { FreeOnStop: frees it, and its destructor finds nothing to remove }
        Old.Stop;
      end;
    end;
end;

function TQuakeSounds.NewPlaying(const Snd: TCastleSound; const Volume: Single;
  const Owner: TObject; const Channel: TQuakeSoundChannel): TQuakePlayingSound;
begin
  Result := TQuakePlayingSound.Create(nil);
  Result.Sound := Snd;
  Result.Volume := Volume;
  Result.FreeOnStop := True;
  { Stay where the sound started, also after the source is freed }
  Result.Follow := False;
  Result.Load := Volume;
  FActiveSounds.Add(Result);
  UseChannel(Owner, Channel, Result);
end;

function TQuakeSounds.ActiveSoundCount: Integer;
begin
  Result := FActiveSounds.Count;
end;

procedure TQuakeSounds.UpdateMixer(const SecondsPassed, Master: Single);
var
  Voice: TQuakeLoopVoice;
  P: TQuakePlayingSound;
begin
  FMixLoad := 0;
  for P in FActiveSounds do
    FMixLoad := FMixLoad + P.Load;
  if FLoopVoices <> nil then
    for Voice in FLoopVoices.Values do
      if Voice.Requested then
        FMixLoad := FMixLoad + Max(0, Voice.BestGain);
  FLimiterGain := LimiterStep(FLimiterGain, LimiterTarget(FMixLoad, LimiterThreshold), SecondsPassed);
  if SoundEngine <> nil then
    SoundEngine.Volume := Master * FLimiterGain;
end;

procedure TQuakeSounds.Play(const APath: String; const Volume: Single;
  const Channel: TQuakeSoundChannel);
var
  Snd: TCastleSound;
begin
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  try
    Snd := GetSound(APath);
    if Snd <> nil then
      SoundEngine.Play(NewPlaying(Snd, Volume, nil, Channel));
  except
    on E: Exception do
      WritelnWarning('QuakeSound', 'Failed to play "%s": %s', [APath, E.Message]);
  end;
end;

function TQuakeSounds.SpatialSound(const APath: String; const Attenuation: Single): TCastleSound;
begin
  Result := SpatialSoundMult(APath, DistanceMult(Attenuation));
end;

function TQuakeSounds.SpatialSoundMult(const APath: String; const DistMult: Single): TCastleSound;
var
  Base: TCastleSound;
  Key: String;
begin
  Result := nil;
  Base := GetSound(APath);
  if Base = nil then
    Exit;
  Key := LowerCase(APath) + '@' + FloatToStr(DistMult);
  if not FSoundCache.TryGetValue(Key, Result) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := Base.Url;
    Result.Volume := Base.Volume;
    Result.Pitch := Base.Pitch;
    { Quake 2 S_SpatializeOrigin: full volume up to SOUND_FULLVOLUME, then
      1 - distance * dist_mult: OpenAL's clamped linear model with these
      distances gives the same gain }
    Result.ReferenceDistance := SoundFullVolume;
    if DistMult > 0 then
      Result.MaxDistance := SoundFullVolume + 1 / DistMult
    else
      Result.MaxDistance := 100000;
    FSoundCache.Add(Key, Result);
  end;
end;

procedure TQuakeSounds.BeginLoops(const Listener: TVector3);
var
  Voice: TQuakeLoopVoice;
begin
  FListener := Listener;
  for Voice in FLoopVoices.Values do
  begin
    Voice.Requested := False;
    Voice.BestGain := 0;
  end;
end;

procedure TQuakeSounds.AddLoop(const APath: String; const Position: TVector3;
  const Volume: Single; const Attenuation: Single);
var
  Voice: TQuakeLoopVoice;
  Key: String;
  Gain: Single;
begin
  if not FEnabled or (SoundEngine = nil) or (FWorldParent = nil) or (APath = '') then
    Exit;
  Key := LowerCase(APath);
  if Attenuation <= 0 then
    Key := Key + '@none';
  if not FLoopVoices.TryGetValue(Key, Voice) then
  begin
    Voice := TQuakeLoopVoice.Create;
    FLoopVoices.Add(Key, Voice);
    Voice.Transform := TCastleTransform.Create(nil);
    Voice.Transform.Name := 'LoopSound' + IntToStr(FLoopVoices.Count);
    Voice.Source := TCastleSoundSource.Create(nil);
    Voice.Source.SoundPlaying := False;
    Voice.Source.Spatial := Attenuation > 0;
    if Attenuation > 0 then
      Voice.Source.Sound := SpatialSoundMult(APath, SoundLoopAttenuate)
    else
      Voice.Source.Sound := GetSound(APath);
    Voice.Transform.AddBehavior(Voice.Source);
    FWorldParent.Add(Voice.Transform);
  end;
  if Voice.Source.Sound = nil then
    Exit;
  { Gain the emitter would have here, to pick the loudest one }
  if Attenuation > 0 then
    Gain := Volume * (1 - Max(0, PointsDistance(Position, FListener) - SoundFullVolume) * SoundLoopAttenuate)
  else
    Gain := Volume;
  if (not Voice.Requested) or (Gain > Voice.BestGain) then
  begin
    Voice.Requested := True;
    Voice.BestGain := Gain;
    Voice.BestVolume := Volume;
    Voice.BestPosition := Position;
  end;
end;

procedure TQuakeSounds.EndLoops;
var
  Voice: TQuakeLoopVoice;
  Audible: Boolean;
begin
  for Voice in FLoopVoices.Values do
  begin
    Audible := Voice.Requested and (Voice.BestGain > 0);
    if Audible then
    begin
      if (Voice.Transform.Parent = nil) and (FWorldParent <> nil) then
        FWorldParent.Add(Voice.Transform);
      Voice.Transform.Translation := Voice.BestPosition;
      Voice.Source.Volume := Voice.BestVolume;
    end;
    if Voice.Source.SoundPlaying <> Audible then
      Voice.Source.SoundPlaying := Audible;
  end;
end;

function TQuakeSounds.LoopPosition(const APath: String; out Position: TVector3): Boolean;
var
  Voice: TQuakeLoopVoice;
begin
  Result := FLoopVoices.TryGetValue(LowerCase(APath), Voice) and Voice.Source.SoundPlaying;
  if Result then
    Position := Voice.Transform.Translation
  else
    Position := TVector3.Zero;
end;

procedure TQuakeSounds.ClearLoops;
var
  Voice: TQuakeLoopVoice;
begin
  for Voice in FLoopVoices.Values do
  begin
    Voice.Source.SoundPlaying := False;
    if Voice.Transform.Parent <> nil then
      Voice.Transform.Parent.Remove(Voice.Transform);
  end;
end;

function TQuakeSounds.PlayingLoopCount: Integer;
var
  Voice: TQuakeLoopVoice;
begin
  Result := 0;
  for Voice in FLoopVoices.Values do
    if Voice.Source.SoundPlaying and (Voice.Source.Sound <> nil) then
      Inc(Result);
end;

function TQuakeSounds.LoadNamedSounds(const Url: String): Integer;
var
  I: Integer;
  Named: TQuakeNamedSound;
begin
  Result := 0;
  if not UriFileExists(Url) then
    Exit;
  FNamedSounds.Clear;
  FreeAndNil(FNamedOwner);
  FNamedOwner := TComponent.Create(nil);
  ComponentLoad(Url, FNamedOwner);
  for I := 0 to FNamedOwner.ComponentCount - 1 do
    if FNamedOwner.Components[I] is TQuakeNamedSound then
    begin
      Named := TQuakeNamedSound(FNamedOwner.Components[I]);
      if Named.QuakePath = '' then
        Continue;
      { A sound left in the PAK path must exist there }
      if IsPrefix('quakepak:/', Named.Url, True) and
         not Pak.FileExists(PrefixRemove('quakepak:/', Named.Url, True)) then
        Continue;
      FNamedSounds.AddOrSetValue(Named.QuakePath, Named);
      Inc(Result);
    end;
  WritelnLog('QuakeSound', 'Loaded %d named sounds from "%s"', [Result, Url]);
end;

function TQuakeSounds.NamedSound(const APath: String): TQuakeNamedSound;
begin
  if not FNamedSounds.TryGetValue(LowerCase(APath), Result) then
    Result := nil;
end;

function TQuakeSounds.SoundFor(const APath: String): TCastleSound;
begin
  Result := GetSound(APath);
end;

procedure TQuakeSounds.ConfigureEngine;
begin
  if SoundEngine <> nil then
  begin
    SoundEngine.DistanceModel := dmLinear;
    { Quake 2 mixes up to MAX_CHANNELS = 32 sounds }
    SoundEngine.MaxAllocatedSources := 32;
  end;
end;

procedure TQuakeSounds.PlayAt(const APath: String; const ATransform: TCastleTransform;
  const Volume: Single; const Attenuation: Single; const Channel: TQuakeSoundChannel);
begin
  if ATransform = nil then
    Exit;
  { The transform's place in the world (its parent is the map, at identity) }
  PlayAtPoint(APath, ATransform.Translation, Volume, Attenuation, ATransform, Channel);
end;

procedure TQuakeSounds.PlayAtPoint(const APath: String; const Position: TVector3;
  const Volume: Single; const Attenuation: Single; const Owner: TObject;
  const Channel: TQuakeSoundChannel);
var
  Snd: TCastleSound;
  Emitter: TCastleTransform;
  Source: TCastleSoundSource;
  Playing: TQuakePlayingSound;
  Dist, Gain: Single;
begin
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  try
    if Attenuation <= 0 then
    begin
      { ATTN_NONE: heard everywhere, like a 2D sound }
      Snd := GetSound(APath);
      if Snd <> nil then
        SoundEngine.Play(NewPlaying(Snd, Volume, Owner, Channel));
      Exit;
    end;
    Snd := SpatialSound(APath, Attenuation);
    if Snd = nil then
      Exit;
    { Quake 2's stereo loudness for the direction, and the gain at the
      listener (S_SpatializeOrigin's distance falloff) for the limiter }
    Dist := PointsDistance(Position, FListener);
    Gain := Volume;
    if Dist > 1 then
      Gain := Volume * QuakePanLoudness(TVector3.DotProduct(FListenerRight, (Position - FListener) / Dist));
    { A throwaway emitter: the sound doesn't follow it (Follow = False), so
      it keeps playing at Position after the emitter is freed }
    Emitter := TCastleTransform.Create(nil);
    try
      Emitter.Translation := Position;
      Source := TCastleSoundSource.Create(Emitter);
      Emitter.AddBehavior(Source);
      Playing := NewPlaying(Snd, Gain, Owner, Channel);
      Playing.Load := Gain * Max(0, 1 - Max(0, Dist - SoundFullVolume) * DistanceMult(Attenuation));
      Source.Play(Playing);
    finally
      Emitter.Free;
    end;
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

{ TQuakeNamedSound }

procedure TQuakeNamedSound.SetQuakePath(const Value: String);
begin
  FQuakePath := LowerCase(Value);
end;

function TQuakeNamedSound.PropertySections(const PropertyName: String): TPropertySections;
begin
  if PropertyName = 'QuakePath' then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

initialization
  RegisterSerializableComponent(TQuakeNamedSound, 'Quake 2 Named Sound');
  Sounds := TQuakeSounds.Create;

finalization
  FreeAndNil(Sounds);
end.
