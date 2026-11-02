{ Quake PAK (Quake 1 / Quake 2 share the format) archive reader and custom URL protocol. }
unit QuakePak;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleDownload, CastleUriUtils, CastleLog, CastleZip;

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
    { Files loaded on first use (loose files of a game folder, .pkz
      entries): per stream index, the zip (index in FZips, -1 for a file
      on disk) and the disk path or path in the zip; FStreams holds nil
      until loaded }
    FZips: specialize TObjectList<TCastleZip>;
    FLazyZip: specialize TList<Integer>;
    FLazyPath: TStringList;
    function FindEntryIndex(const APath: String): Integer;
    { The stream of a PAK index, loading a lazy file now (nil if it fails) }
    function StreamOf(const PakIndex: Integer): TMemoryStream;
    procedure AddLazyEntry(const APath, Source: String; const ZipIndex: Integer; const Size: Int64);
  public
    constructor Create;
    destructor Destroy; override;

    { Add (or replace) a file made in memory, e.g. a generated map
      (maps/<name>.bsp); takes ownership of Stream }
    procedure AddMemoryFile(const APath: String; const Stream: TMemoryStream);

    { Add a PAK archive from file or castle-data URL. Returns true if successful. }
    function AddFile(const AUrlOrFilename: String): Boolean;

    { Add every file under a folder (a game folder like baseq2 or a mod's),
      named by its path inside it, over what was loaded before. Files are
      read when first used. Skips .pak / .pkz archives and dot folders.
      Returns the number of files added. }
    function AddDirectory(const Dir: String): Integer;

    { Add a .pkz archive (a zip, Quake 2 Remastered's mod packages), its
      files read when first used. Returns true if it could be opened. }
    function AddZip(const FileName: String): Boolean;

    { Loaded PAK files, comma separated (for reports) }
    function PakList: String;

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
  FZips := specialize TObjectList<TCastleZip>.Create(True);
  FLazyZip := specialize TList<Integer>.Create;
  FLazyPath := TStringList.Create;
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
  FLazyPath.Free;
  FLazyZip.Free;
  FZips.Free;
  inherited Destroy;
end;

function TQuakePak.StreamOf(const PakIndex: Integer): TMemoryStream;
var
  Src: TStream;
begin
  Result := FStreams[PakIndex];
  if (Result <> nil) or (PakIndex >= FLazyZip.Count) or (FLazyPath[PakIndex] = '') then
    Exit;
  try
    if FLazyZip[PakIndex] >= 0 then
      Src := FZips[FLazyZip[PakIndex]].Read(FLazyPath[PakIndex])
    else
      Src := TFileStream.Create(FLazyPath[PakIndex], fmOpenRead or fmShareDenyWrite);
    try
      Result := TMemoryStream.Create;
      Result.CopyFrom(Src, 0);
      Result.Position := 0;
    finally
      Src.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Cannot read "%s": %s', [FLazyPath[PakIndex], E.Message]);
      FreeAndNil(Result);
      Exit;
    end;
  end;
  FStreams[PakIndex] := Result;
end;

procedure TQuakePak.AddLazyEntry(const APath, Source: String; const ZipIndex: Integer; const Size: Int64);
var
  Entry: TQuakePakEntry;
  Idx: Integer;
begin
  Entry.Path := NormalizePath(APath);
  Entry.Offset := 0;
  Entry.Size := Size;
  Entry.PakIndex := FStreams.Add(nil);
  FFilenames.Add(Source);
  while FLazyZip.Count < Entry.PakIndex do
  begin
    FLazyZip.Add(-1);
    FLazyPath.Add('');
  end;
  if ZipIndex >= 0 then
    FLazyPath.Add(APath)
  else
    FLazyPath.Add(Source);
  FLazyZip.Add(ZipIndex);
  Idx := FindEntryIndex(Entry.Path);
  if Idx >= 0 then
    FEntries[Idx] := Entry
  else
    FIndex.AddOrSetValue(Entry.Path, FEntries.Add(Entry));
end;

function TQuakePak.AddDirectory(const Dir: String): Integer;

  procedure Scan(const Folder, Prefix: String);
  var
    SR: TSearchRec;
    Ext: String;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '') or (SR.Name[1] = '.') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
          Scan(IncludeTrailingPathDelimiter(Folder) + SR.Name, Prefix + SR.Name + '/')
        else
        begin
          Ext := LowerCase(ExtractFileExt(SR.Name));
          if (Ext = '.pak') or (Ext = '.pkz') or (Ext = '.dll') or (Ext = '.so') or (Ext = '.exe') then
            Continue;
          AddLazyEntry(Prefix + SR.Name, IncludeTrailingPathDelimiter(Folder) + SR.Name, -1, SR.Size);
          Inc(Result);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  Result := 0;
  if not DirectoryExists(Dir) then
    Exit;
  Scan(ExcludeTrailingPathDelimiter(Dir), '');
  if Result > 0 then
    WritelnLog('QuakePak', 'Added folder "%s": %d loose files (total indexed: %d)', [Dir, Result, FEntries.Count]);
end;

function TQuakePak.AddZip(const FileName: String): Boolean;
var
  Zip: TCastleZip;
  ZipIndex, I: Integer;
  Name: String;
begin
  Result := False;
  Zip := TCastleZip.Create;
  try
    Zip.Open(FilenameToUriSafe(ExpandFileName(FileName)));
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Cannot open "%s": %s', [FileName, E.Message]);
      Zip.Free;
      Exit;
    end;
  end;
  ZipIndex := FZips.Add(Zip);
  for I := 0 to Zip.Files.Count - 1 do
  begin
    Name := Zip.Files[I];
    if (Name = '') or (Name[Length(Name)] = '/') then
      Continue; { folders }
    AddLazyEntry(Name, 'zip:' + FileName + ':' + Name, ZipIndex, 0);
  end;
  WritelnLog('QuakePak', 'Loaded "%s": %d files (total indexed: %d)', [FileName, Zip.Files.Count, FEntries.Count]);
  Result := True;
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

procedure TQuakePak.AddMemoryFile(const APath: String; const Stream: TMemoryStream);
var
  Entry: TQuakePakEntry;
  Idx: Integer;
  Name: String;
begin
  Name := NormalizePath(APath);
  Idx := FindEntryIndex(Name);
  { A file added in memory before: its stream is only its own }
  if (Idx >= 0) and (FFilenames[FEntries[Idx].PakIndex] = 'memory:' + Name) then
  begin
    FStreams[FEntries[Idx].PakIndex].Free;
    FStreams[FEntries[Idx].PakIndex] := Stream;
    Entry := FEntries[Idx];
    Entry.Size := Stream.Size;
    FEntries[Idx] := Entry;
    Exit;
  end;
  Entry.Path := Name;
  Entry.Offset := 0;
  Entry.Size := Stream.Size;
  Entry.PakIndex := FStreams.Add(Stream);
  FFilenames.Add('memory:' + Name);
  if Idx >= 0 then
    FEntries[Idx] := Entry
  else
    FIndex.AddOrSetValue(Name, FEntries.Add(Entry));
  WritelnLog('QuakePak', 'Added "%s" from memory (%d bytes)', [Name, Stream.Size]);
end;

function TQuakePak.PakList: String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FFilenames.Count - 1 do
  begin
    if Copy(FFilenames[I], 1, 7) = 'memory:' then
      Continue;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ExtractFileName(FFilenames[I]);
  end;
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
  Src := StreamOf(Entry.PakIndex);
  if Src = nil then
    Exit;
  { Lazy files: their real size is known once loaded }
  if (Entry.Offset = 0) and (FFilenames[Entry.PakIndex] <> '') and (Entry.Size <> Src.Size) and
     (Entry.PakIndex < FLazyPath.Count) and (FLazyPath[Entry.PakIndex] <> '') then
  begin
    Entry.Size := Src.Size;
    FEntries[Idx] := Entry;
  end;
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
  Src := StreamOf(Entry.PakIndex);
  if Src = nil then
    Exit;
  if (Entry.PakIndex < FLazyPath.Count) and (FLazyPath[Entry.PakIndex] <> '') and (Entry.Size <> Src.Size) then
  begin
    Entry.Size := Src.Size;
    FEntries[Idx] := Entry;
  end;
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
