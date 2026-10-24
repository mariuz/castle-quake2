{ The title screen / menu view.
  Its components are designed in data/gameviewmenu.castle-user-interface . }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  CastleUIControls, CastleKeysMouse,
  QuakeMenu;

type
  TViewMenu = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    Menu: TQuakeMenu;
  private
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewMenu: TViewMenu;

implementation

uses
  CastleWindow,
  QuakeSound, QuakeGamepad, GameViewPlay;

constructor TViewMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewmenu.castle-user-interface';
end;

procedure TViewMenu.Start;
begin
  inherited Start;
  Menu.OnMenuAction := @HandleMenuAction;
  { Quake 2 menu music is CD track 2 (if ripped to data/music/track02.ogg) }
  Sounds.PlayMusic('track02.ogg');
end;

procedure TViewMenu.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame, maWarpMap:
      begin
        { "random" becomes a new random level in TViewPlay.LoadLevel }
        ViewPlay.MapName := Param;
        Container.View := ViewPlay;
      end;
    maLevelEditor:
      begin
        ViewPlay.MapName := '';
        ViewPlay.OpenEditorOnStart := True;
        Container.View := ViewPlay;
      end;
    maQuit:
      Application.Terminate;
    else ;
  end;
end;

function TViewMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  Result := Menu.Press(GamepadMenuEvent(Event));
end;

end.
