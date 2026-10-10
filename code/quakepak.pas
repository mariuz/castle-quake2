{ Quake PAK (Quake 1 / Quake 2 share the format) archive reader and custom URL protocol. }
unit QuakePak;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleDownload, CastleUriUtils, CastleLog;

type
  { Single file entry inside a Quake PAK archive. }
  TQuakePakEntry = record
    Path: String;
    Offset: Cardinal;
    Size: Cardinal;
    PakIndex: Integer;
  end;

  TQuakePakEntryList = specialize TList<TQuakePakEntry>;

  { Quake PAK archive manager. Supports stacking multiple PAK files
    (e.g. pak0.pak, pak1.pak) where later paks override earlier ones. }
  TQuakePak = class
  private
    FStreams: specialize TList<TMemoryStream>;
    FFilenames: TStringList;
    FEntries: TQuakePakEntryList;
    { Normalized path -> index in FEntries, for O(1) lookups }
    FIndex: specialize TDictionary<String, Integer>;
    FProtocolRegistered: Boolean;
    function FindEntryIndex(const APath: String): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    { Add a PAK archive from file or castle-data URL. Returns true if successful. }
    function AddFile(const AUrlOrFilename: String): Boolean;

    { Was this PAK URL / filename already added? }
    function HasPak(const AUrlOrFilename: String): Boolean;

    { Check if a file exists in any loaded PAK. }
    function FileExists(const APath: String): Boolean;

    { Get file contents as a newly created TMemoryStream. Caller owns the stream. }
    function GetStream(const APath: String): TMemoryStream;

    { Direct pointer to file data in memory (valid as long as TQuakePak lives). }
    function GetData(const APath: String; out ASize: Cardinal): Pointer;

    { Find all files matching prefix and optional extension. Caller owns returned TStringList. }
    function FindFiles(const APrefix, AExtension: String): TStringList;

    { Register quakepak: URL protocol handler in Castle Game Engine. }
    procedure RegisterProtocol;
    function ReadPak(const Url: String; out MimeType: String): TStream;
    function GetFileCount: Integer; inline;

    property Entries: TQuakePakEntryList read FEntries;
    property FileCount: Integer read GetFileCount;
  end;

var
  Pak: TQuakePak;

implementation

type
  TPakHeader = packed record
    Magic: array[0..3] of AnsiChar; { 'PACK' }
    DirOffset: Cardinal;
    DirLength: Cardinal;
  end;

  TPakRawEntry = packed record
    Name: array[0..55] of AnsiChar;
    Offset: Cardinal;
    Size: Cardinal;
  end;

function NormalizePath(const S: String): String;
var
  I: Integer;
begin
  Result := LowerCase(S);
  for I := 1 to Length(Result) do
    if Result[I] = '\' then
      Result[I] := '/';
  while (Length(Result) > 0) and (Result[1] = '/') do
    Delete(Result, 1, 1);
end;

{ TQuakePak }

constructor TQuakePak.Create;
begin
  inherited Create;
  FStreams := specialize TList<TMemoryStream>.Create;
  FFilenames := TStringList.Create;
  FEntries := TQuakePakEntryList.Create;
  FIndex := specialize TDictionary<String, Integer>.Create;
  FProtocolRegistered := False;
end;

destructor TQuakePak.Destroy;
var
  Stream: TMemoryStream;
begin
  if FProtocolRegistered then
    CastleDownload.UnregisterUrlProtocol('quakepak');
  for Stream in FStreams do
    Stream.Free;
  FStreams.Free;
  FFilenames.Free;
  FEntries.Free;
  FIndex.Free;
  inherited Destroy;
end;

function TQuakePak.GetFileCount: Integer;
begin
  Result := FEntries.Count;
end;

function TQuakePak.AddFile(const AUrlOrFilename: String): Boolean;
var
  InStream: TStream;
  MemStream: TMemoryStream;
  Header: TPakHeader;
  RawEntry: TPakRawEntry;
  Count, I: Integer;
  EntryName: String;
  Entry: TQuakePakEntry;
  ExistingIndex: Integer;
  PakIdx: Integer;
begin
  Result := False;
  try
    InStream := Download(AUrlOrFilename);
    try
      MemStream := TMemoryStream.Create;
      MemStream.CopyFrom(InStream, InStream.Size);
      MemStream.Position := 0;
    finally
      InStream.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to load PAK "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;

  if MemStream.Size < SizeOf(TPakHeader) then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" is too small (%d bytes)', [AUrlOrFilename, MemStream.Size]);
    MemStream.Free;
    Exit;
  end;

  MemStream.ReadBuffer(Header, SizeOf(TPakHeader));
  if (Header.Magic[0] <> 'P') or (Header.Magic[1] <> 'A') or
     (Header.Magic[2] <> 'C') or (Header.Magic[3] <> 'K') then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" has invalid magic (not "PACK")', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;

  Count := Header.DirLength div SizeOf(TPakRawEntry);
  if (Header.DirOffset + Header.DirLength > Cardinal(MemStream.Size)) or
     (Header.DirLength mod SizeOf(TPakRawEntry) <> 0) then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" has invalid directory header', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;

  PakIdx := FStreams.Count;
  FStreams.Add(MemStream);
  FFilenames.Add(AUrlOrFilename);

  MemStream.Position := Header.DirOffset;
  for I := 0 to Count - 1 do
  begin
    MemStream.ReadBuffer(RawEntry, SizeOf(TPakRawEntry));
    EntryName := NormalizePath(PAnsiChar(@RawEntry.Name[0]));

    ExistingIndex := FindEntryIndex(EntryName);
    Entry.Path := EntryName;
    Entry.Offset := RawEntry.Offset;
    Entry.Size := RawEntry.Size;
    Entry.PakIndex := PakIdx;

    if ExistingIndex >= 0 then
      FEntries[ExistingIndex] := Entry
    else
      FIndex.AddOrSetValue(EntryName, FEntries.Add(Entry));
  end;

  WritelnLog('QuakePak', 'Loaded PAK "%s": %d files (total indexed: %d)',
    [AUrlOrFilename, Count, FEntries.Count]);
  Result := True;
end;

function TQuakePak.HasPak(const AUrlOrFilename: String): Boolean;
begin
  Result := FFilenames.IndexOf(AUrlOrFilename) >= 0;
end;

function TQuakePak.FindEntryIndex(const APath: String): Integer;
begin
  if not FIndex.TryGetValue(NormalizePath(APath), Result) then
    Result := -1;
end;

function TQuakePak.FileExists(const APath: String): Boolean;
begin
  Result := FindEntryIndex(APath) >= 0;
end;

function TQuakePak.GetStream(const APath: String): TMemoryStream;
var
  Idx: Integer;
  Entry: TQuakePakEntry;
  Src: TMemoryStream;
begin
  Result := nil;
  Idx := FindEntryIndex(APath);
  if Idx < 0 then
    Exit;

  Entry := FEntries[Idx];
  Src := FStreams[Entry.PakIndex];
  if Entry.Offset + Entry.Size > Cardinal(Src.Size) then
  begin
    WritelnWarning('QuakePak', 'File entry "%s" points out of bounds', [APath]);
    Exit;
  end;

  Result := TMemoryStream.Create;
  Result.Size := Entry.Size;
  Move((PByte(Src.Memory) + Entry.Offset)^, Result.Memory^, Entry.Size);
  Result.Position := 0;
end;

function TQuakePak.GetData(const APath: String; out ASize: Cardinal): Pointer;
var
  Idx: Integer;
  Entry: TQuakePakEntry;
  Src: TMemoryStream;
begin
  ASize := 0;
  Result := nil;
  Idx := FindEntryIndex(APath);
  if Idx < 0 then
    Exit;

  Entry := FEntries[Idx];
  Src := FStreams[Entry.PakIndex];
  if Entry.Offset + Entry.Size > Cardinal(Src.Size) then
    Exit;

  ASize := Entry.Size;
  Result := PByte(Src.Memory) + Entry.Offset;
end;

function TQuakePak.FindFiles(const APrefix, AExtension: String): TStringList;
var
  I: Integer;
  Entry: TQuakePakEntry;
  PrefixNorm, ExtNorm: String;
begin
  Result := TStringList.Create;
  PrefixNorm := NormalizePath(APrefix);
  ExtNorm := LowerCase(AExtension);

  for I := 0 to FEntries.Count - 1 do
  begin
    Entry := FEntries[I];
    if (PrefixNorm = '') or (Pos(PrefixNorm, Entry.Path) = 1) then
    begin
      if (ExtNorm = '') or (ExtractFileExt(Entry.Path) = ExtNorm) then
        Result.Add(Entry.Path);
    end;
  end;
end;

function TQuakePak.ReadPak(const Url: String; out MimeType: String): TStream;
var
  Path: String;
  P: Integer;
begin
  Path := Url;
  P := Pos(':', Path);
  if P > 0 then Delete(Path, 1, P);
  while (Path <> '') and (Path[1] = '/') do Delete(Path, 1, 1);

  Result := GetStream(Path);
  { CGE picks the sound / image loader by MIME type, so derive it from the extension }
  MimeType := UriMimeType(Path);
  if Result = nil then
  begin
    WritelnLog('QuakePak', 'Resource not found: ' + Url);
    raise EFOpenError.Create('Resource not found in PAK: ' + Url);
  end;
end;

procedure TQuakePak.RegisterProtocol;
begin
  if not FProtocolRegistered then
  begin
    CastleDownload.RegisterUrlProtocol('quakepak', @ReadPak, nil);
    FProtocolRegistered := True;
    WritelnLog('QuakePak', 'Registered "quakepak:" URL protocol');
  end;
end;

initialization
  Pak := TQuakePak.Create;

finalization
  FreeAndNil(Pak);
end.
