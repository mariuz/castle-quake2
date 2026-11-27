{ Packets between game instances (roadmap E.4): a TNetLink carries
  datagrams to and from peers named by strings ("127.0.0.1:27910", a
  page's id on the web), and two bridges join it to the loopback channels
  the server and the client already use (QuakeNet.TNetLoopback):

  - TNetHostBridge: every peer that sends to the host becomes a client of
    its server (OnConnect hands the peer's channel to TQuakeServer.AddClient);
    what the server sends to that channel goes back to the peer. A peer
    that says goodbye or stays silent for PeerTimeout seconds leaves
    (OnDisconnect).
  - TNetJoinBridge: a client's channel whose server is the host: commands
    go out to it, its snapshots come in.

  A datagram is one byte of kind (data or goodbye) and one message. The
  links don't resend: on localhost and between pages nothing is lost; over
  real networks (E.5) the server data and models must become reliable. }
unit QuakeNetLink;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, QuakeNet;

const
  { Quake 2's port }
  DefaultNetPort = 27910;
  { Seconds without a packet before a peer is dropped }
  PeerTimeout = 10;
  NetLinkData = 1;
  NetLinkBye = 2;

type
  TNetLink = class
  public
    { False: it could not be sent (a closed link, a bad address) }
    function Send(const Peer: String; const Data: TBytes): Boolean; virtual; abstract;
    function Receive(out Peer: String; out Data: TBytes): Boolean; virtual; abstract;
    { The name Receive reports for this peer (UDP: "localhost" ->
      "127.0.0.1", the default port added) }
    function NormalizePeer(const Peer: String): String; virtual;
  end;

  { Two links joined in memory (tests): what one sends, the other receives
    from the peer named by the sender's Name }
  TNetMemoryLink = class(TNetLink)
  strict private
    type
      TPacket = record
        Peer: String;
        Data: TBytes;
      end;
    var
      FInbox: specialize TQueue<TPacket>;
      FOther: TNetMemoryLink;
      FName: String;
  public
    constructor Create(const AName: String);
    destructor Destroy; override;
    procedure Connect(const Other: TNetMemoryLink);
    function Send(const Peer: String; const Data: TBytes): Boolean; override;
    function Receive(out Peer: String; out Data: TBytes): Boolean; override;
    property Name: String read FName;
  end;

  {$ifndef WASI}
  { UDP datagrams (IPv4), not blocking }
  TNetUdpLink = class(TNetLink)
  strict private
    FSocket: PtrInt;
    FPort: Integer;
    FError: String;
    FBuffer: TBytes;
  public
    { Port 0: any free port; BindAddress '' = every address (other
      machines may send), '127.0.0.1' = this machine only (tests) }
    constructor Create(const APort: Integer; const BindAddress: String = '');
    destructor Destroy; override;
    function Opened: Boolean;
    function Send(const Peer: String; const Data: TBytes): Boolean; override;
    function Receive(out Peer: String; out Data: TBytes): Boolean; override;
    function NormalizePeer(const Peer: String): String; override;
    { The port bound (the given one, or the one picked for 0) }
    property Port: Integer read FPort;
    property Error: String read FError;
  end;
  {$endif}

  {$ifdef WASI}
  { Datagrams between pages of one browser (pages/duel.html: two iframes):
    web/page.html defines document.CastleNetOpen / CastleNetSend /
    CastleNetReceive over a BroadcastChannel; peers are page names, the
    data goes as hex text }
  TNetWebLink = class(TNetLink)
  strict private
    FName, FError: String;
  public
    { AName '' = a name the page makes up (a joining page) }
    constructor Create(const AName: String);
    function Opened: Boolean;
    function Send(const Peer: String; const Data: TBytes): Boolean; override;
    function Receive(out Peer: String; out Data: TBytes): Boolean; override;
    property Name: String read FName;
    property Error: String read FError;
  end;
  {$endif}

  TNetPeerConnectEvent = function(const Peer: String; const Channel: TNetLoopback): TObject of object;
  TNetPeerEvent = procedure(const Peer: String; const Ref: TObject) of object;

  TNetHostBridge = class
  strict private
    type
      TPeer = class
        Name: String;
        Channel: TNetLoopback;
        { What OnConnect returned (the server's client) }
        Ref: TObject;
        Silence: Single;
        destructor Destroy; override;
      end;
    var
      FLink: TNetLink;
      FPeers: specialize TObjectList<TPeer>;
      FRefused: TStringList;
      FOnConnect: TNetPeerConnectEvent;
      FOnDisconnect: TNetPeerEvent;
      FPacketsIn, FPacketsOut: Integer;
    function FindPeer(const Name: String): Integer;
    procedure DropPeer(const Index: Integer; const Why: String);
  public
    { Owns ALink }
    constructor Create(const ALink: TNetLink);
    destructor Destroy; override;
    { Receive and send what is waiting; Seconds since the last call count
      towards the timeouts }
    procedure Pump(const Seconds: Single);
    { Every peer leaves (the map's server stops): OnDisconnect for each }
    procedure DropAll;
    function PeerCount: Integer;
    function PeerName(const Index: Integer): String;
    property Link: TNetLink read FLink;
    property PacketsIn: Integer read FPacketsIn;
    property PacketsOut: Integer read FPacketsOut;
    { A new peer: return its reference, nil to refuse it (no room) }
    property OnConnect: TNetPeerConnectEvent read FOnConnect write FOnConnect;
    property OnDisconnect: TNetPeerEvent read FOnDisconnect write FOnDisconnect;
  end;

  TNetJoinBridge = class
  strict private
    FLink: TNetLink;
    FHost: String;
    FChannel: TNetLoopback;
    FSilence: Single;
    FPacketsIn, FPacketsOut: Integer;
  public
    { Owns ALink; the client uses Channel's client end }
    constructor Create(const ALink: TNetLink; const AHost: String);
    destructor Destroy; override;
    procedure Pump(const Seconds: Single);
    { Seconds since the host last sent something }
    property Silence: Single read FSilence;
    property Channel: TNetLoopback read FChannel;
    property Host: String read FHost;
    property PacketsIn: Integer read FPacketsIn;
    property PacketsOut: Integer read FPacketsOut;
  end;

{ "host:port" -> host and port (DefaultNetPort without one); False when the
  port isn't a number }
function SplitHostPort(const S: String; out Host: String; out Port: Integer): Boolean;

{ The web link's text: bytes as lowercase hex, and back (False on an odd
  length or a character that isn't hex) }
function BytesToHex(const Data: TBytes): String;
function HexToBytes(const S: String; out Data: TBytes): Boolean;

implementation

uses
  {$ifndef WASI}
  Sockets,
  {$ifdef MSWINDOWS} WinSock2, {$else} BaseUnix, {$endif}
  {$endif}
  {$ifdef WASI} Job.Js, CastleInternalJobWeb, {$endif}
  CastleLog;

function SplitHostPort(const S: String; out Host: String; out Port: Integer): Boolean;
var
  P: Integer;
begin
  P := LastDelimiter(':', S);
  if P = 0 then
  begin
    Host := S;
    Port := DefaultNetPort;
    Exit(Host <> '');
  end;
  Host := Copy(S, 1, P - 1);
  Result := TryStrToInt(Copy(S, P + 1, MaxInt), Port) and (Port > 0) and (Port < 65536) and (Host <> '');
end;

function BytesToHex(const Data: TBytes): String;
const
  Digits: array [0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, Length(Data) * 2);
  for I := 0 to Length(Data) - 1 do
  begin
    Result[I * 2 + 1] := Digits[Data[I] shr 4];
    Result[I * 2 + 2] := Digits[Data[I] and 15];
  end;
end;

function HexToBytes(const S: String; out Data: TBytes): Boolean;

  function Nibble(const C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
      else Result := -1;
    end;
  end;

var
  I, Hi, Lo: Integer;
begin
  Data := nil;
  if Odd(Length(S)) then
    Exit(False);
  SetLength(Data, Length(S) div 2);
  for I := 0 to Length(Data) - 1 do
  begin
    Hi := Nibble(S[I * 2 + 1]);
    Lo := Nibble(S[I * 2 + 2]);
    if (Hi < 0) or (Lo < 0) then
    begin
      Data := nil;
      Exit(False);
    end;
    Data[I] := (Hi shl 4) or Lo;
  end;
  Result := True;
end;

function TNetLink.NormalizePeer(const Peer: String): String;
begin
  Result := Peer;
end;

function Framed(const Kind: Byte; const Data: TBytes): TBytes;
begin
  SetLength(Result, Length(Data) + 1);
  Result[0] := Kind;
  if Length(Data) > 0 then
    Move(Data[0], Result[1], Length(Data));
end;

function Unframed(const Packet: TBytes; out Kind: Byte): TBytes;
begin
  Result := nil;
  Kind := 0;
  if Length(Packet) = 0 then
    Exit;
  Kind := Packet[0];
  SetLength(Result, Length(Packet) - 1);
  if Length(Result) > 0 then
    Move(Packet[1], Result[0], Length(Result));
end;

{ TNetMemoryLink }

constructor TNetMemoryLink.Create(const AName: String);
begin
  inherited Create;
  FName := AName;
  FInbox := specialize TQueue<TPacket>.Create;
end;

destructor TNetMemoryLink.Destroy;
begin
  if (FOther <> nil) and (FOther.FOther = Self) then
    FOther.FOther := nil;
  FInbox.Free;
  inherited Destroy;
end;

procedure TNetMemoryLink.Connect(const Other: TNetMemoryLink);
begin
  FOther := Other;
  Other.FOther := Self;
end;

function TNetMemoryLink.Send(const Peer: String; const Data: TBytes): Boolean;
var
  P: TPacket;
begin
  Result := (FOther <> nil) and (Peer = FOther.Name);
  if not Result then
    Exit;
  P.Peer := FName;
  P.Data := Copy(Data);
  FOther.FInbox.Enqueue(P);
end;

function TNetMemoryLink.Receive(out Peer: String; out Data: TBytes): Boolean;
var
  P: TPacket;
begin
  Result := FInbox.Count > 0;
  if not Result then
  begin
    Peer := '';
    Data := nil;
    Exit;
  end;
  P := FInbox.Dequeue;
  Peer := P.Peer;
  Data := P.Data;
end;

{$ifdef WASI}

{ TNetWebLink }

constructor TNetWebLink.Create(const AName: String);
begin
  inherited Create;
  try
    FName := String(JSDocument.InvokeJSUnicodeStringResult('CastleNetOpen', [UnicodeString(AName)]));
    if FName = '' then
      FError := 'the page has no BroadcastChannel';
  except
    on E: Exception do
    begin
      FName := '';
      FError := 'the page has no CastleNetOpen (' + E.Message + ')';
    end;
  end;
end;

function TNetWebLink.Opened: Boolean;
begin
  Result := FName <> '';
end;

function TNetWebLink.Send(const Peer: String; const Data: TBytes): Boolean;
begin
  Result := Opened and (Peer <> '') and (Length(Data) > 0);
  if Result then
    Result := JSDocument.InvokeJSBooleanResult('CastleNetSend',
      [UnicodeString(Peer), UnicodeString(BytesToHex(Data))]);
end;

function TNetWebLink.Receive(out Peer: String; out Data: TBytes): Boolean;
var
  S: String;
  P: Integer;
begin
  Peer := '';
  Data := nil;
  Result := False;
  if not Opened then
    Exit;
  repeat
    { "<from>" + #10 + "<hex>", '' when nothing waits }
    S := String(JSDocument.InvokeJSUnicodeStringResult('CastleNetReceive', []));
    if S = '' then
      Exit;
    P := Pos(#10, S);
    if (P > 1) and HexToBytes(Copy(S, P + 1, MaxInt), Data) and (Length(Data) > 0) then
    begin
      Peer := Copy(S, 1, P - 1);
      Exit(True);
    end;
  until False;
end;

{$endif}

{$ifndef WASI}

{ TNetUdpLink }

constructor TNetUdpLink.Create(const APort: Integer; const BindAddress: String);
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  {$ifdef MSWINDOWS}
  NonBlocking: u_long;
  {$endif}
begin
  inherited Create;
  SetLength(FBuffer, 65536);
  FSocket := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if FSocket < 0 then
  begin
    FError := Format('socket: error %d', [SocketError]);
    Exit;
  end;
  Addr := Default(TInetSockAddr);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := 0;
  if (BindAddress <> '') and not SameText(BindAddress, 'localhost') then
    Addr.sin_addr := StrToNetAddr(BindAddress)
  else
  if SameText(BindAddress, 'localhost') then
    Addr.sin_addr := StrToNetAddr('127.0.0.1');
  if fpBind(FSocket, @Addr, SizeOf(Addr)) <> 0 then
  begin
    FError := Format('bind to port %d: error %d', [APort, SocketError]);
    CloseSocket(FSocket);
    FSocket := -1;
    Exit;
  end;
  Len := SizeOf(Addr);
  if fpGetSockName(FSocket, @Addr, @Len) = 0 then
    FPort := ntohs(Addr.sin_port)
  else
    FPort := APort;
  {$ifdef MSWINDOWS}
  NonBlocking := 1;
  ioctlsocket(FSocket, LongInt(FIONBIO), @NonBlocking);
  {$else}
  fpfcntl(FSocket, F_SETFL, fpfcntl(FSocket, F_GETFL, 0) or O_NONBLOCK);
  {$endif}
end;

destructor TNetUdpLink.Destroy;
begin
  if FSocket >= 0 then
    CloseSocket(FSocket);
  inherited Destroy;
end;

function TNetUdpLink.Opened: Boolean;
begin
  Result := FSocket >= 0;
end;

function TNetUdpLink.Send(const Peer: String; const Data: TBytes): Boolean;
var
  Host: String;
  PeerPort: Integer;
  Addr: TInetSockAddr;
begin
  Result := False;
  if (FSocket < 0) or (Length(Data) = 0) or not SplitHostPort(Peer, Host, PeerPort) then
    Exit;
  if SameText(Host, 'localhost') then
    Host := '127.0.0.1';
  Addr := Default(TInetSockAddr);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(PeerPort);
  Addr.sin_addr := StrToNetAddr(Host);
  if Addr.sin_addr.s_addr = 0 then
    Exit;
  Result := fpSendTo(FSocket, @Data[0], Length(Data), 0, @Addr, SizeOf(Addr)) = Length(Data);
end;

function TNetUdpLink.NormalizePeer(const Peer: String): String;
var
  Host: String;
  PeerPort: Integer;
begin
  if not SplitHostPort(Peer, Host, PeerPort) then
    Exit(Peer);
  if SameText(Host, 'localhost') then
    Host := '127.0.0.1';
  Result := Host + ':' + IntToStr(PeerPort);
end;

function TNetUdpLink.Receive(out Peer: String; out Data: TBytes): Boolean;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  N: PtrInt;
begin
  Peer := '';
  Data := nil;
  Result := False;
  if FSocket < 0 then
    Exit;
  Len := SizeOf(Addr);
  N := fpRecvFrom(FSocket, @FBuffer[0], Length(FBuffer), 0, @Addr, @Len);
  { Nothing waiting (or an error, e.g. Windows' "port unreachable" after a
    send to a closed peer): nothing received }
  if N <= 0 then
    Exit;
  SetLength(Data, N);
  Move(FBuffer[0], Data[0], N);
  Peer := NetAddrToStr(Addr.sin_addr) + ':' + IntToStr(ntohs(Addr.sin_port));
  Result := True;
end;

{$endif}

{ TNetHostBridge }

destructor TNetHostBridge.TPeer.Destroy;
begin
  Channel.Free;
  inherited Destroy;
end;

constructor TNetHostBridge.Create(const ALink: TNetLink);
begin
  inherited Create;
  FLink := ALink;
  FPeers := specialize TObjectList<TPeer>.Create(True);
  FRefused := TStringList.Create;
end;

destructor TNetHostBridge.Destroy;
begin
  DropAll;
  FPeers.Free;
  FRefused.Free;
  FLink.Free;
  inherited Destroy;
end;

function TNetHostBridge.FindPeer(const Name: String): Integer;
begin
  for Result := 0 to FPeers.Count - 1 do
    if FPeers[Result].Name = Name then
      Exit;
  Result := -1;
end;

procedure TNetHostBridge.DropPeer(const Index: Integer; const Why: String);
var
  P: TPeer;
begin
  P := FPeers[Index];
  WritelnLog('Net', 'Peer %s left (%s)', [P.Name, Why]);
  if Assigned(FOnDisconnect) then
    FOnDisconnect(P.Name, P.Ref);
  FPeers.Delete(Index);
end;

procedure TNetHostBridge.DropAll;
begin
  while FPeers.Count > 0 do
  begin
    FLink.Send(FPeers[FPeers.Count - 1].Name, Framed(NetLinkBye, nil));
    DropPeer(FPeers.Count - 1, 'host stopped');
  end;
end;

function TNetHostBridge.PeerCount: Integer;
begin
  Result := FPeers.Count;
end;

function TNetHostBridge.PeerName(const Index: Integer): String;
begin
  Result := FPeers[Index].Name;
end;

procedure TNetHostBridge.Pump(const Seconds: Single);
var
  Name: String;
  Packet, Data: TBytes;
  Kind: Byte;
  I: Integer;
  P: TPeer;
begin
  for P in FPeers do
    P.Silence := P.Silence + Seconds;
  while FLink.Receive(Name, Packet) do
  begin
    Data := Unframed(Packet, Kind);
    I := FindPeer(Name);
    if Kind = NetLinkBye then
    begin
      if I >= 0 then
        DropPeer(I, 'goodbye');
      Continue;
    end;
    if Kind <> NetLinkData then
      Continue;
    if I < 0 then
    begin
      P := TPeer.Create;
      P.Name := Name;
      P.Channel := TNetLoopback.Create;
      if Assigned(FOnConnect) then
        P.Ref := FOnConnect(Name, P.Channel);
      if P.Ref = nil then
      begin
        { No room: told once, then ignored until it goes away }
        if FRefused.IndexOf(Name) < 0 then
        begin
          FRefused.Add(Name);
          WritelnLog('Net', 'Peer %s refused', [Name]);
          FLink.Send(Name, Framed(NetLinkBye, nil));
        end;
        P.Free;
        Continue;
      end;
      WritelnLog('Net', 'Peer %s joined', [Name]);
      FPeers.Add(P);
      I := FPeers.Count - 1;
    end;
    Inc(FPacketsIn);
    FPeers[I].Silence := 0;
    FPeers[I].Channel.PushToServer(Data);
  end;
  for I := FPeers.Count - 1 downto 0 do
  begin
    P := FPeers[I];
    while P.Channel.ReceiveOnClient(Data) do
    begin
      FLink.Send(P.Name, Framed(NetLinkData, Data));
      Inc(FPacketsOut);
    end;
    if P.Silence > PeerTimeout then
      DropPeer(I, 'timed out');
  end;
end;

{ TNetJoinBridge }

constructor TNetJoinBridge.Create(const ALink: TNetLink; const AHost: String);
begin
  inherited Create;
  FLink := ALink;
  FHost := ALink.NormalizePeer(AHost);
  FChannel := TNetLoopback.Create;
end;

destructor TNetJoinBridge.Destroy;
begin
  FLink.Send(FHost, Framed(NetLinkBye, nil));
  FChannel.Free;
  FLink.Free;
  inherited Destroy;
end;

procedure TNetJoinBridge.Pump(const Seconds: Single);
var
  Name: String;
  Packet, Data: TBytes;
  Kind: Byte;
begin
  FSilence := FSilence + Seconds;
  while FLink.Receive(Name, Packet) do
  begin
    { Only the host's packets (UDP: any address may send) }
    if Name <> FHost then
      Continue;
    Data := Unframed(Packet, Kind);
    FSilence := 0;
    if Kind = NetLinkData then
    begin
      Inc(FPacketsIn);
      FChannel.PushToClient(Data);
    end else
    if Kind = NetLinkBye then
      FSilence := PeerTimeout + 1;
  end;
  while FChannel.ReceiveOnServer(Data) do
  begin
    FLink.Send(FHost, Framed(NetLinkData, Data));
    Inc(FPacketsOut);
  end;
end;

end.
