{ The title screen / menu view. }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleWindow, CastleColors, CastleLog,
  QuakeSound, QuakeMenu, GameViewPlay;

type
  TViewMenu = class(TCastleView)
  private
    FMenu: TQuakeMenu;
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    procedure Stop; override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewMenu: TViewMenu;

implementation

constructor TViewMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMenu := TQuakeMenu.Create(Self);
  FMenu.OnMenuAction := @HandleMenuAction;
  InsertFront(FMenu);
end;

procedure TViewMenu.Start;
begin
  inherited Start;
  { Quake 2 menu music is CD track 2 (if ripped to data/music/track02.ogg) }
  Sounds.PlayMusic('track02.ogg');
end;

procedure TViewMenu.Stop;
begin
  inherited Stop;
end;

procedure TViewMenu.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame:
      begin
        ViewPlay.MapName := Param;
        Container.View := ViewPlay;
      end;
    maWarpMap:
      begin
        ViewPlay.MapName := Param;
        Container.View := ViewPlay;
      end;
    maQuit:
      Application.Terminate;
  end;
end;

function TViewMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := FMenu.Press(Event);
end;

end.
