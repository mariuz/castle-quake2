{ The client end of E.1: sends the player's inputs as usercmd_t moves
  (acknowledging the last snapshot it has) and string commands, keeps the
  snapshots the server sends (CL_ParseFrame, CL_ParsePacketEntities) and
  predicts its own player (CL_PredictMovement): the last snapshot's pmove
  state, then the commands the server hasn't run yet, then this frame's.
  It knows nothing of TQuakeWorld: only what the messages carry. }
unit QuakeClient;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, CastleVectors, QuakeNet, QuakePMove;

const
  { Commands kept for prediction (CMD_BACKUP) }
  CmdBackup = 64;
  CmdMask = CmdBackup - 1;

type
  TClientPrintEvent = procedure(const Text: String; const Center: Boolean) of object;

  TQuakeClient = class
  strict private
    type
      TSentCmd = record
        Sequence: Integer;
        Cmd: TNetUserCmd;
        { Where prediction put the player after it }
        Predicted: TVector3;
      end;
    var
      FChannel: TNetLoopback;
      FMsg: TNetMessage;
      FLastCmd: TNetUserCmd;
      FStringCmds: TStringList;
      FFrames: array[0..UpdateBackup - 1] of TNetFrame;
      FFrame: TNetFrame;
      FModels: array[0..MaxNetModels - 1] of String;
      FMapName: String;
      FFramesReceived, FBadFrames: Integer;
      FCmds: array[0..CmdBackup - 1] of TSentCmd;
      FOutgoing: Integer;
      FPending: TNetUserCmd;
      FPendingPredicted: TVector3;
      FHasPending: Boolean;
      FMsecRemainder: Single;
      FCheckedFrame, FPredictionChecks, FPredictionErrors: Integer;
      FMaxPredictionError: Single;
      FOnPrint: TClientPrintEvent;
    function ParseFrame(const Msg: TNetMessage): Boolean;
    function GetModelName(const Index: Integer): String;
    procedure CheckPrediction;
  public
    constructor Create(const AChannel: TNetLoopback);
    destructor Destroy; override;
    { A command for the server after the next move (clc_stringcmd) }
    procedure AddCommand(const S: String);
    { Move PM for this frame (Input.Dt = the frame's seconds): the command
      is made here (sent by SendMove) and PM predicted from the last
      snapshot. Without a snapshot PM moves on from its own state. }
    procedure Predict(const Input: TPMoveInput; const PM: TQuakePMove);
    { Send this frame's command (the predicted move, or none: msec 0 with
      AimDir's angles) with its buttons, and the queued string commands }
    procedure SendMove(const Attack: Boolean; const AimDirQuake: TVector3);
    { Read what the server sent }
    procedure ReadPackets;
    { The latest snapshot (Valid False before the first one) }
    property Frame: TNetFrame read FFrame;
    property ModelNames[const Index: Integer]: String read GetModelName;
    property MapName: String read FMapName;
    property FramesReceived: Integer read FFramesReceived;
    { Snapshots that could not be read (missing delta base, short message) }
    property BadFrames: Integer read FBadFrames;
    property CommandsSent: Integer read FOutgoing;
    { Snapshots whose player origin was compared with the prediction for the
      same command, those off by more than 1/8 unit, the largest error }
    property PredictionChecks: Integer read FPredictionChecks;
    property PredictionErrors: Integer read FPredictionErrors;
    property MaxPredictionError: Single read FMaxPredictionError;
    { svc_print / svc_centerprint }
    property OnPrint: TClientPrintEvent read FOnPrint write FOnPrint;
  end;

implementation

uses
  Math, CastleLog;

constructor TQuakeClient.Create(const AChannel: TNetLoopback);
begin
  inherited Create;
  FChannel := AChannel;
  FMsg := TNetMessage.Create;
  FStringCmds := TStringList.Create;
end;

destructor TQuakeClient.Destroy;
begin
  FStringCmds.Free;
  FMsg.Free;
  inherited Destroy;
end;

function TQuakeClient.GetModelName(const Index: Integer): String;
begin
  if (Index > 0) and (Index < MaxNetModels) then
    Result := FModels[Index]
  else
    Result := '';
end;

procedure TQuakeClient.AddCommand(const S: String);
begin
  FStringCmds.Add(S);
end;

procedure TQuakeClient.CheckPrediction;
var
  Ack: Integer;
  Err: Single;
begin
  { CL_CheckPredictionError: once per snapshot, the server's origin after a
    command against where we predicted it }
  if (not FFrame.Valid) or (FFrame.ServerFrame = FCheckedFrame) then
    Exit;
  FCheckedFrame := FFrame.ServerFrame;
  Ack := FFrame.Player.CommandAck;
  if (Ack <= 0) or (FCmds[Ack and CmdMask].Sequence <> Ack) or
     ((FFrame.Player.PmFlags and PmfTeleport) <> 0) then
    Exit;
  Inc(FPredictionChecks);
  Err := PointsDistance(FFrame.Player.Origin, FCmds[Ack and CmdMask].Predicted);
  FMaxPredictionError := Max(FMaxPredictionError, Err);
  if Err > 0.125 then
    Inc(FPredictionErrors);
end;

procedure TQuakeClient.Predict(const Input: TPMoveInput; const PM: TQuakePMove);
var
  Total: Single;
  Msec, Seq: Integer;
begin
  { Whole milliseconds, the rest carried to the next frame }
  Total := Input.Dt + FMsecRemainder;
  Msec := Min(250, Trunc(Total * 1000 + 1e-3));
  FMsecRemainder := Total - Msec / 1000;
  if Msec = 250 then
    FMsecRemainder := 0;
  FPending := PMoveInputToUserCmd(Input, Msec);
  if FFrame.Valid then
  begin
    CheckPrediction;
    NetToPMove(FFrame.Player, PM);
    for Seq := Max(FFrame.Player.CommandAck + 1, FOutgoing - CmdBackup + 1) to FOutgoing do
      if FCmds[Seq and CmdMask].Sequence = Seq then
        PM.Move(UserCmdToPMoveInput(FCmds[Seq and CmdMask].Cmd));
  end;
  { This frame's command last: its landing makes the view dip }
  PM.Move(UserCmdToPMoveInput(FPending));
  FPendingPredicted := PM.Origin;
  FHasPending := True;
end;

procedure TQuakeClient.SendMove(const Attack: Boolean; const AimDirQuake: TVector3);
var
  Cmd: TNetUserCmd;
  Idle: TPMoveInput;
  I: Integer;
begin
  if FHasPending then
    Cmd := FPending
  else
  begin
    { No move this frame (dead, suspended): only the view and the buttons }
    Idle := Default(TPMoveInput);
    Idle.Dir := AimDirQuake;
    Cmd := PMoveInputToUserCmd(Idle, 0);
    FPendingPredicted := TVector3.Zero;
  end;
  if Attack then
    Cmd.Buttons := Cmd.Buttons or NetButtonAttack;
  Inc(FOutgoing);
  FCmds[FOutgoing and CmdMask].Sequence := FOutgoing;
  FCmds[FOutgoing and CmdMask].Cmd := Cmd;
  FCmds[FOutgoing and CmdMask].Predicted := FPendingPredicted;
  if not FHasPending then
    { Nothing predicted for it: not compared }
    FCmds[FOutgoing and CmdMask].Sequence := -1;
  FHasPending := False;

  FMsg.Clear;
  FMsg.WriteByte(ClcMove);
  { The last snapshot we have: the server codes the next ones from it }
  if FFrame.Valid then
    FMsg.WriteLong(FFrame.ServerFrame)
  else
    FMsg.WriteLong(-1);
  FMsg.WriteLong(FOutgoing);
  WriteDeltaUserCmd(FMsg, FLastCmd, Cmd);
  FLastCmd := Cmd;
  for I := 0 to FStringCmds.Count - 1 do
  begin
    FMsg.WriteByte(ClcStringCmd);
    FMsg.WriteString(FStringCmds[I]);
  end;
  FStringCmds.Clear;
  FChannel.SendToServer(FMsg);
end;

function TQuakeClient.ParseFrame(const Msg: TNetMessage): Boolean;
var
  F, Base: TNetFrame;
  Entities: TNetEntityStates;
begin
  Result := False;
  F := Default(TNetFrame);
  F.ServerFrame := Msg.ReadLong;
  F.DeltaFrame := Msg.ReadLong;
  Base := Default(TNetFrame);
  if F.DeltaFrame > 0 then
  begin
    Base := FFrames[F.DeltaFrame and UpdateMask];
    { The base is gone (too old, or before the map changed) }
    if not (Base.Valid and (Base.ServerFrame = F.DeltaFrame)) then
      Exit;
  end;
  if Msg.ReadByte <> SvcPlayerInfo then
    Exit;
  F.Player := ReadDeltaPlayerState(Msg, Base.Player);
  if Msg.ReadByte <> SvcPacketEntities then
    Exit;
  if not ReadPacketEntities(Msg, Base.Entities, Entities) then
    Exit;
  F.Entities := Entities;
  F.Valid := True;
  FFrames[F.ServerFrame and UpdateMask] := F;
  FFrame := F;
  Inc(FFramesReceived);
  Result := True;
end;

procedure TQuakeClient.ReadPackets;
var
  Data: TBytes;
  Msg: TNetMessage;
  Cmd: Byte;
  Index, I: Integer;
  Name: String;
begin
  while FChannel.ReceiveOnClient(Data) do
  begin
    Msg := TNetMessage.CreateFrom(Data);
    try
      while not Msg.AtEnd do
      begin
        Cmd := Msg.ReadByte;
        case Cmd of
          SvcServerData:
            begin
              FMapName := Msg.ReadString;
              for I := 0 to UpdateBackup - 1 do
                FFrames[I] := Default(TNetFrame);
              FFrame := Default(TNetFrame);
              for I := 0 to MaxNetModels - 1 do
                FModels[I] := '';
            end;
          SvcPrint, SvcCenterPrint:
            begin
              Name := Msg.ReadString;
              if Assigned(FOnPrint) then
                FOnPrint(Name, Cmd = SvcCenterPrint);
            end;
          SvcConfigString:
            begin
              Index := Msg.ReadWord;
              Name := Msg.ReadString;
              if (Index > 0) and (Index < MaxNetModels) then
                FModels[Index] := Name;
            end;
          SvcFrame:
            if not ParseFrame(Msg) then
            begin
              Inc(FBadFrames);
              WritelnWarning('QuakeClient', 'Snapshot could not be read');
              { Ask for a full one }
              FFrame.Valid := False;
              Break;
            end;
          else
            begin
              WritelnWarning('QuakeClient', 'Bad server message %d', [Cmd]);
              Break;
            end;
        end;
        if Msg.BadRead then
          Break;
      end;
    finally
      Msg.Free;
    end;
  end;
end;

end.
