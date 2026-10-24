{ Quake 2 palette, PCX and WAL image decoding, and the quaketex: texture protocol. }
unit QuakePalette;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleImages, CastleDownload, CastleUriUtils, CastleLog,
  QuakePak;

const
  { Quake 2 palette index 255 is used as the transparent color in skins and pics. }
  TransparentIndex = 255;

type
  TQuakeRGB = packed record
    R, G, B: Byte;
  end;

  TQuakeRGBPalette = array[0..255] of TQuakeRGB;

  { Information about a Quake 2 wall texture (textures/*.wal). }
  TQuakeWalInfo = record
    Width, Height: Integer;
    { Next frame of an animated texture, '' if not animated. }
    AnimName: String;
    Flags, Contents, Value: Integer;
  end;

  { Quake 2 palette (from pics/colormap.pcx) and texture cache. }
  TQuakePalette = class
  private
    FColors: TQuakeRGBPalette;
    FHasPalette: Boolean;
    FTextureCache: specialize TObjectDictionary<String, TCastleImage>;
    FWalInfos: specialize TDictionary<String, TQuakeWalInfo>;
    FProtocolRegistered: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Load the global palette from pics/colormap.pcx of the active PAKs. }
    function LoadFromPak: Boolean;

    { Get RGBA byte vector for a palette index. }
    function Color(const Index: Byte; const Alpha: Byte = 255): TVector4Byte;

    { Convert 8-bit palette indexed buffer to TRGBAlphaImage using the global palette.
      If ATransparentIndex >= 0, that palette index becomes fully transparent. }
    function DecodeIndexed(const Pixels: PByte; const Width, Height: Integer;
      const ATransparentIndex: Integer = -1): TRGBAlphaImage;

    { Load a Quake 2 wall texture, e.g. "e1u1/floor1_3" (without "textures/" and ".wal").
      Caches it for the quaketex: protocol under TextureId(Name).
      Returns False if the WAL is missing (a checkerboard is cached instead). }
    function LoadWal(const Name: String; out Info: TQuakeWalInfo): Boolean;

    { Load any PCX from the PAK (skins, pics, sky) and cache it under its path.
      Palette index 255 becomes transparent when Transparent is set. }
    function LoadPcx(const APath: String; const Transparent: Boolean = True): Boolean;

    { Add an image to the memory cache under a unique identifier. }
    procedure CacheImage(const AId: String; const Image: TCastleImage);

    { Retrieve an image from cache (nil if missing). }
    function GetCachedImage(const AId: String): TCastleImage;

    { Check if image is cached. }
    function HasCachedImage(const AId: String): Boolean;

    { Register quaketex: URL protocol for on-the-fly texture serving. }
    procedure RegisterProtocol;
    function ReadTex(const Url: String; out MimeType: String): TStream;

    property HasPalette: Boolean read FHasPalette;
  end;

{ Cache id (and quaketex: path) of a WAL texture. }
function WalTextureId(const Name: String): String;

{ Decode a PCX (version 5, 8-bit, RLE) into indexed pixels and its own 256-color palette. }
function DecodePcx(const Data: PByte; const Size: Cardinal;
  out Width, Height: Integer; out Pixels: TBytes; out Pal: TQuakeRGBPalette): Boolean;

{ Fast uncompressed 32-bit TGA writer for memory streams. }
procedure WriteTga(const Image: TRGBAlphaImage; Stream: TStream);

var
  Palette: TQuakePalette;

implementation

type
  TTgaHeader = packed record
    IdLength: Byte;
    ColorMapType: Byte;
    ImageType: Byte; { 2 = uncompressed true-color }
    ColorMapSpec: array[0..4] of Byte;
    XOrigin: Word;
    YOrigin: Word;
    Width: Word;
    Height: Word;
    PixelDepth: Byte; { 32 }
    ImageDescriptor: Byte; { bit 5 = top-to-bottom, bits 3..0 = alpha depth }
  end;

  TPcxHeader = packed record
    Manufacturer: Byte; { $0A }
    Version: Byte;      { 5 }
    Encoding: Byte;     { 1 = RLE }
    BitsPerPixel: Byte; { 8 }
    XMin, YMin, XMax, YMax: Word;
    HRes, VRes: Word;
    EgaPalette: array[0..47] of Byte;
    Reserved: Byte;
    ColorPlanes: Byte;
    BytesPerLine: Word;
    PaletteType: Word;
    Filler: array[0..57] of Byte;
  end;

  TWalHeader = packed record
    Name: array[0..31] of AnsiChar;
    Width, Height: Cardinal;
    Offsets: array[0..3] of Cardinal;
    AnimName: array[0..31] of AnsiChar;
    Flags, Contents, Value: LongInt;
  end;

function WalTextureId(const Name: String): String;
begin
  Result := 'textures/' + LowerCase(Name) + '.wal';
end;

procedure WriteTga(const Image: TRGBAlphaImage; Stream: TStream);
var
  Hdr: TTgaHeader;
  X, Y: Integer;
  Pixel: PVector4Byte;
  Row: array of Byte;
begin
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr.ImageType := 2;
  Hdr.Width := Image.Width;
  Hdr.Height := Image.Height;
  Hdr.PixelDepth := 32;
  Hdr.ImageDescriptor := 8; { 8-bit alpha, origin at bottom-left like CGE images }
  Stream.WriteBuffer(Hdr, SizeOf(Hdr));

  SetLength(Row, Image.Width * 4);
  for Y := 0 to Image.Height - 1 do
  begin
    Pixel := Image.PixelPtr(0, Y);
    for X := 0 to Image.Width - 1 do
    begin
      Row[X * 4 + 0] := Pixel^[2];
      Row[X * 4 + 1] := Pixel^[1];
      Row[X * 4 + 2] := Pixel^[0];
      Row[X * 4 + 3] := Pixel^[3];
      Inc(Pixel);
    end;
    if Length(Row) > 0 then
      Stream.WriteBuffer(Row[0], Length(Row));
  end;
end;

function DecodePcx(const Data: PByte; const Size: Cardinal;
  out Width, Height: Integer; out Pixels: TBytes; out Pal: TQuakeRGBPalette): Boolean;
var
  Hdr: ^TPcxHeader;
  Src, SrcEnd: PByte;
  X, Y, RunLen: Integer;
  B: Byte;
begin
  Result := False;
  Width := 0;
  Height := 0;
  Pixels := nil;
  FillChar(Pal, SizeOf(Pal), 0);
  if (Data = nil) or (Size < SizeOf(TPcxHeader) + 769) then
    Exit;

  Hdr := Pointer(Data);
  if (Hdr^.Manufacturer <> $0A) or (Hdr^.Version <> 5) or (Hdr^.Encoding <> 1) or
     (Hdr^.BitsPerPixel <> 8) then
    Exit;

  Width := Hdr^.XMax - Hdr^.XMin + 1;
  Height := Hdr^.YMax - Hdr^.YMin + 1;
  if (Width <= 0) or (Height <= 0) or (Width > 4096) or (Height > 4096) then
    Exit;

  { 256-color palette is stored in the last 768 bytes, preceded by $0C }
  Move((Data + Size - 768)^, Pal[0], 768);

  SetLength(Pixels, Width * Height);
  Src := Data + SizeOf(TPcxHeader);
  SrcEnd := Data + Size - 769;
  for Y := 0 to Height - 1 do
  begin
    X := 0;
    while X < Hdr^.BytesPerLine do
    begin
      if Src >= SrcEnd then
        Break;
      B := Src^;
      Inc(Src);
      if (B and $C0) = $C0 then
      begin
        RunLen := B and $3F;
        if Src >= SrcEnd then
          Break;
        B := Src^;
        Inc(Src);
      end else
        RunLen := 1;
      while RunLen > 0 do
      begin
        if X < Width then
          Pixels[Y * Width + X] := B;
        Inc(X);
        Dec(RunLen);
      end;
    end;
  end;
  Result := True;
end;

{ TQuakePalette }

constructor TQuakePalette.Create;
begin
  inherited Create;
  FTextureCache := specialize TObjectDictionary<String, TCastleImage>.Create([doOwnsValues]);
  FWalInfos := specialize TDictionary<String, TQuakeWalInfo>.Create;
  FHasPalette := False;
  FProtocolRegistered := False;
end;

destructor TQuakePalette.Destroy;
begin
  if FProtocolRegistered then
    CastleDownload.UnregisterUrlProtocol('quaketex');
  FTextureCache.Free;
  FWalInfos.Free;
  inherited Destroy;
end;

function TQuakePalette.LoadFromPak: Boolean;
var
  Data: Pointer;
  Size: Cardinal;
  W, H: Integer;
  Pixels: TBytes;
begin
  Result := False;
  Data := Pak.GetData('pics/colormap.pcx', Size);
  if (Data <> nil) and DecodePcx(Data, Size, W, H, Pixels, FColors) then
  begin
    FHasPalette := True;
    WritelnLog('QuakePalette', 'Loaded palette from pics/colormap.pcx');
  end else
    WritelnWarning('QuakePalette', 'Failed to load pics/colormap.pcx (is a Quake 2 PAK loaded?)');
  Result := FHasPalette;
end;

function TQuakePalette.Color(const Index: Byte; const Alpha: Byte): TVector4Byte;
begin
  Result := Vector4Byte(FColors[Index].R, FColors[Index].G, FColors[Index].B, Alpha);
end;

function DecodeWithPalette(const Pal: TQuakeRGBPalette; const Pixels: PByte;
  const Width, Height: Integer; const ATransparentIndex: Integer): TRGBAlphaImage;
var
  X, Y: Integer;
  Src: PByte;
  Dst: PVector4Byte;
  Idx: Byte;
begin
  Result := TRGBAlphaImage.Create(Width, Height);
  { Quake images are stored top-to-bottom, CGE images bottom-to-top }
  for Y := 0 to Height - 1 do
  begin
    Src := Pixels + (Height - 1 - Y) * Width;
    Dst := Result.PixelPtr(0, Y);
    for X := 0 to Width - 1 do
    begin
      Idx := Src^;
      Inc(Src);
      if (ATransparentIndex >= 0) and (Idx = ATransparentIndex) then
        Dst^ := Vector4Byte(0, 0, 0, 0)
      else
        Dst^ := Vector4Byte(Pal[Idx].R, Pal[Idx].G, Pal[Idx].B, 255);
      Inc(Dst);
    end;
  end;
end;

function TQuakePalette.DecodeIndexed(const Pixels: PByte; const Width, Height: Integer;
  const ATransparentIndex: Integer): TRGBAlphaImage;
begin
  Result := DecodeWithPalette(FColors, Pixels, Width, Height, ATransparentIndex);
end;

function CheckerImage: TRGBAlphaImage;
var
  X, Y: Integer;
begin
  Result := TRGBAlphaImage.Create(64, 64);
  for Y := 0 to 63 do
    for X := 0 to 63 do
      if ((X div 8) + (Y div 8)) mod 2 = 0 then
        PVector4Byte(Result.PixelPtr(X, Y))^ := Vector4Byte(90, 90, 90, 255)
      else
        PVector4Byte(Result.PixelPtr(X, Y))^ := Vector4Byte(40, 40, 40, 255);
end;

function TQuakePalette.LoadWal(const Name: String; out Info: TQuakeWalInfo): Boolean;
var
  Key: String;
  Data: PByte;
  Size: Cardinal;
  Hdr: ^TWalHeader;
begin
  Key := WalTextureId(Name);
  if FWalInfos.TryGetValue(Key, Info) then
    Exit(FTextureCache.ContainsKey(Key));

  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Width := 64;
  Info.Height := 64;

  Data := Pak.GetData(Key, Size);
  if (Data <> nil) and (Size >= SizeOf(TWalHeader)) then
  begin
    Hdr := Pointer(Data);
    Info.Width := Hdr^.Width;
    Info.Height := Hdr^.Height;
    Info.AnimName := LowerCase(Trim(PAnsiChar(@Hdr^.AnimName[0])));
    Info.Flags := Hdr^.Flags;
    Info.Contents := Hdr^.Contents;
    Info.Value := Hdr^.Value;
    if (Info.Width > 0) and (Info.Height > 0) and
       (Hdr^.Offsets[0] + Cardinal(Info.Width * Info.Height) <= Size) and FHasPalette then
    begin
      CacheImage(Key, DecodeIndexed(Data + Hdr^.Offsets[0], Info.Width, Info.Height, -1));
      Result := True;
    end;
  end;

  if not Result then
  begin
    WritelnWarning('QuakePalette', 'Missing wall texture "%s"', [Key]);
    CacheImage(Key, CheckerImage);
  end;
  FWalInfos.AddOrSetValue(Key, Info);
end;

function TQuakePalette.LoadPcx(const APath: String; const Transparent: Boolean): Boolean;
var
  Key: String;
  Data: Pointer;
  Size: Cardinal;
  W, H, TransIdx: Integer;
  Pixels: TBytes;
  Pal: TQuakeRGBPalette;
begin
  Key := LowerCase(APath);
  if FTextureCache.ContainsKey(Key) then
    Exit(True);

  Result := False;
  Data := Pak.GetData(Key, Size);
  if (Data = nil) or not DecodePcx(Data, Size, W, H, Pixels, Pal) then
    Exit;

  if Transparent then
    TransIdx := TransparentIndex
  else
    TransIdx := -1;
  CacheImage(Key, DecodeWithPalette(Pal, @Pixels[0], W, H, TransIdx));
  Result := True;
end;

procedure TQuakePalette.CacheImage(const AId: String; const Image: TCastleImage);
begin
  FTextureCache.AddOrSetValue(LowerCase(AId), Image);
end;

function TQuakePalette.GetCachedImage(const AId: String): TCastleImage;
begin
  if not FTextureCache.TryGetValue(LowerCase(AId), Result) then
    Result := nil;
end;

function TQuakePalette.HasCachedImage(const AId: String): Boolean;
begin
  Result := FTextureCache.ContainsKey(LowerCase(AId));
end;

function TQuakePalette.ReadTex(const Url: String; out MimeType: String): TStream;
var
  Path: String;
  P: Integer;
  Img: TCastleImage;
  RgbAlpha: TRGBAlphaImage;
begin
  Path := Url;
  P := Pos(':', Path);
  if P > 0 then Delete(Path, 1, P);
  while (Path <> '') and (Path[1] = '/') do Delete(Path, 1, 1);

  Img := GetCachedImage(Path);
  if Img = nil then
    raise EFOpenError.Create('Texture not in cache: ' + Path);

  if Img is TRGBAlphaImage then
    RgbAlpha := TRGBAlphaImage(Img)
  else
  begin
    RgbAlpha := TRGBAlphaImage.Create(Img.Width, Img.Height);
    { DrawFrom copies only the colours of an image without alpha (e.g. a
      sky side from a TGA), so make it opaque first: uninitialized alpha
      made such textures randomly transparent }
    RgbAlpha.Clear(Vector4Byte(0, 0, 0, 255));
    RgbAlpha.DrawFrom(Img, 0, 0);
  end;

  Result := TMemoryStream.Create;
  try
    WriteTga(RgbAlpha, Result);
    Result.Position := 0;
    MimeType := 'image/x-tga';
  finally
    if RgbAlpha <> Img then
      RgbAlpha.Free;
  end;
end;

procedure TQuakePalette.RegisterProtocol;
begin
  if not FProtocolRegistered then
  begin
    CastleDownload.RegisterUrlProtocol('quaketex', @ReadTex, nil);
    FProtocolRegistered := True;
    WritelnLog('QuakePalette', 'Registered "quaketex:" URL protocol');
  end;
end;

initialization
  Palette := TQuakePalette.Create;

finalization
  FreeAndNil(Palette);
end.
