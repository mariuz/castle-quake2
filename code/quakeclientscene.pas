{ The client's drawing of the snapshots (E.1, third part): every md2 entity
  of the last snapshot gets a model of its own, placed between the previous
  snapshot and the last one (CL_AddPacketEntities' lerp: the tick clock's
  Alpha), on frames blended the same way, with its skin, shells and light
  tint. Brush models and sprites are still drawn by the shared world. }
unit QuakeClientScene;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, CastleVectors, CastleTransform,
  QuakeNet, QuakeClient, QuakeMd2;

type
  TQuakeClientScene = class
  strict private
    type
      TClientEntity = class
        Number, ModelIndex, ModelIndex2: Integer;
        Transform: TCastleTransform;
        Model, Model2: TQuakeMd2Instance;
        LightTimer: Single;
        destructor Destroy; override;
      end;
      TClientEntities = specialize TObjectDictionary<Integer, TClientEntity>;
    var
      FParent: TCastleTransform;
      FEntities: TClientEntities;
      FEnabled: Boolean;
    function CreateEntity(const Client: TQuakeClient; const S: TNetEntityState): TClientEntity;
    procedure SetEnabled(const Value: Boolean);
  public
    constructor Create(const AParent: TCastleTransform);
    destructor Destroy; override;
    { Place every md2 entity of the client's last snapshot, Alpha of the way
      from the one before }
    procedure Update(const Client: TQuakeClient; const Alpha, SecondsPassed: Single);
    { Forget every entity (a new map) }
    procedure Clear;
    { Draw the snapshots (off: nothing is drawn, the server's models are) }
    property Enabled: Boolean read FEnabled write SetEnabled;
    function Count: Integer;
  end;

{ Degrees from A to B by T, the short way round }
function LerpAngle(const A, B, T: Single): Single;

implementation

uses
  Math, CastleLog, QuakeLight;

function LerpAngle(const A, B, T: Single): Single;
var
  D: Single;
begin
  D := B - A;
  while D > 180 do
    D := D - 360;
  while D < -180 do
    D := D + 360;
  Result := A + D * T;
end;

destructor TQuakeClientScene.TClientEntity.Destroy;
begin
  FreeAndNil(Model2);
  FreeAndNil(Model);
  FreeAndNil(Transform);
  inherited Destroy;
end;

constructor TQuakeClientScene.Create(const AParent: TCastleTransform);
begin
  inherited Create;
  FParent := AParent;
  FEntities := TClientEntities.Create([doOwnsValues]);
end;

destructor TQuakeClientScene.Destroy;
begin
  FreeAndNil(FEntities);
  inherited Destroy;
end;

procedure TQuakeClientScene.Clear;
begin
  FEntities.Clear;
end;

function TQuakeClientScene.Count: Integer;
begin
  Result := FEntities.Count;
end;

procedure TQuakeClientScene.SetEnabled(const Value: Boolean);
begin
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  if not Value then
    Clear;
end;

function TQuakeClientScene.CreateEntity(const Client: TQuakeClient;
  const S: TNetEntityState): TClientEntity;
var
  Md2, Md2b: TQuakeMd2;
begin
  Result := nil;
  Md2 := Md2Manager.GetModel(Client.ModelNames[S.ModelIndex]);
  if Md2 = nil then
    Exit;
  Result := TClientEntity.Create;
  Result.Number := S.Number;
  Result.ModelIndex := S.ModelIndex;
  Result.ModelIndex2 := S.ModelIndex2;
  Result.Transform := TCastleTransform.Create(nil);
  Result.Transform.Name := 'ClientEntity' + IntToStr(S.Number);
  Result.Transform.Collides := False;
  Result.Transform.Pickable := False;
  Result.Model := TQuakeMd2Instance.Create(Md2, S.Skin);
  Result.Model.Scene.Collides := False;
  Result.Model.Scene.Pickable := False;
  Result.Transform.Add(Result.Model.Scene);
  if S.ModelIndex2 > 0 then
  begin
    Md2b := Md2Manager.GetModel(Client.ModelNames[S.ModelIndex2]);
    if Md2b <> nil then
    begin
      Result.Model2 := TQuakeMd2Instance.Create(Md2b);
      Result.Model2.Scene.Collides := False;
      Result.Model2.Scene.Pickable := False;
      Result.Transform.Add(Result.Model2.Scene);
      Result.Model.Follower := Result.Model2;
    end;
  end;
  FParent.Add(Result.Transform);
end;

procedure TQuakeClientScene.Update(const Client: TQuakeClient; const Alpha, SecondsPassed: Single);
const
  { A jump this far in one snapshot (a teleport, a respawn) isn't blended }
  MaxLerpMove = 64;
var
  Cur, Prev: TNetFrame;
  HasPrev: Boolean;
  Seen: specialize TList<Integer>;
  Gone: specialize TList<Integer>;
  Pair: specialize TPair<Integer, TClientEntity>;
  S, P: TNetEntityState;
  E: TClientEntity;
  I, J: Integer;
  OldFrame, NewFrame: Integer;
  Lerp: Single;
  Org, Ang: TVector3;
  Shell: TVector3;
  Name: String;
begin
  if not FEnabled then
    Exit;
  Cur := Client.Frame;
  if not Cur.Valid then
  begin
    Clear;
    Exit;
  end;
  HasPrev := Client.FrameAt(Cur.ServerFrame - 1, Prev);
  Seen := specialize TList<Integer>.Create;
  Gone := specialize TList<Integer>.Create;
  try
    J := 0;
    for I := 0 to High(Cur.Entities) do
    begin
      S := Cur.Entities[I];
      Name := Client.ModelNames[S.ModelIndex];
      if not SameText(ExtractFileExt(Name), '.md2') then
        Continue;
      if not FEntities.TryGetValue(S.Number, E) or (E.ModelIndex <> S.ModelIndex) or
         (E.ModelIndex2 <> S.ModelIndex2) then
      begin
        FEntities.Remove(S.Number);
        E := CreateEntity(Client, S);
        if E = nil then
          Continue;
        FEntities.Add(S.Number, E);
      end;
      Seen.Add(S.Number);

      { The same entity in the previous snapshot (both lists are sorted) }
      P := S;
      if HasPrev then
      begin
        while (J < Length(Prev.Entities)) and (Prev.Entities[J].Number < S.Number) do
          Inc(J);
        if (J < Length(Prev.Entities)) and (Prev.Entities[J].Number = S.Number) and
           (Prev.Entities[J].ModelIndex = S.ModelIndex) and
           (PointsDistance(Prev.Entities[J].Origin, S.Origin) <= MaxLerpMove) then
        begin
          P := Prev.Entities[J];
        end;
      end;
      Org := P.Origin + (S.Origin - P.Origin) * Alpha;
      Ang := Vector3(LerpAngle(P.Angles.X, S.Angles.X, Alpha), LerpAngle(P.Angles.Y, S.Angles.Y, Alpha),
        LerpAngle(P.Angles.Z, S.Angles.Z, Alpha));
      E.Transform.Translation := QuakeToCge(Org);
      E.Transform.Rotation := QuakeAnglesToRotation(Ang);
      if S.Scale > 0 then
        E.Transform.Scale := Vector3(S.Scale, S.Scale, S.Scale)
      else
        E.Transform.Scale := Vector3(1, 1, 1);
      E.Model.SetSkin(S.Skin);
      { The server's blend, moved on between the two snapshots when it is
        the same pair of frames, else this snapshot's }
      OldFrame := S.OldFrame;
      NewFrame := S.Frame;
      Lerp := S.Lerp / 255;
      if (P.OldFrame = S.OldFrame) and (P.Frame = S.Frame) then
        Lerp := (P.Lerp + (S.Lerp - P.Lerp) * Alpha) / 255;
      E.Model.ShowFrames(OldFrame, NewFrame, Lerp);
      Shell := TVector3.Zero;
      if (S.RenderFx and NetRfShellRed) <> 0 then
        Shell.X := 1;
      if (S.RenderFx and NetRfShellGreen) <> 0 then
        Shell.Y := 1;
      if (S.RenderFx and NetRfShellBlue) <> 0 then
        Shell.Z := 1;
      if not TVector3.PerfectlyEquals(Shell, E.Model.ShellColor) then
        E.Model.SetShell(Shell);
      { The light under the model, 10 times a second like the server's }
      E.LightTimer := E.LightTimer - SecondsPassed;
      if E.LightTimer <= 0 then
      begin
        E.LightTimer := 0.1;
        if (S.RenderFx and NetRfIrVisible) <> 0 then
          E.Model.SetTint(Vector3(2.0, 0.25, 0.25))
        else
          E.Model.SetTint(Lighting.SampleLight(E.Transform.Translation + Vector3(0, 8, 0)));
      end;
    end;

    for Pair in FEntities do
      if not Seen.Contains(Pair.Key) then
        Gone.Add(Pair.Key);
    for I := 0 to Gone.Count - 1 do
      FEntities.Remove(Gone[I]);
  finally
    Gone.Free;
    Seen.Free;
  end;
end;

end.
