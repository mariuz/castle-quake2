{ Settings from the web page's address: "?map=demo2&skill=2&touch=1&fps=1"
  becomes command-line arguments ("+map demo2 +set skill 2 --touch --fps"),
  so the browser build and the desktop build share one parser
  (GameInitialize).

  Keys: map, skill (0..3), touch (1), fps (1), gamma, demo (a demo script;
  it runs as an autotest on the map, demo1 by default, and quits). Unknown
  keys are returned in Ignored. Pure string code, so the unit tests check
  it on the desktop. }
unit QuakeWebParams;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Decode one query component: "+" is a space, %XX a byte }
function UrlDecodeComponent(const S: String): String;

{ Arguments for the query string (with or without the leading "?");
  unknown keys are added to Ignored (when not nil) }
function QueryToParameters(const Query: String; const Ignored: TStrings = nil): TStringArray;

implementation

function UrlDecodeComponent(const S: String): String;
var
  I, Code: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '+' then
      Result := Result + ' '
    else
    if (S[I] = '%') and (I + 2 <= Length(S)) and TryStrToInt('$' + Copy(S, I + 1, 2), Code) then
    begin
      Result := Result + Chr(Code);
      Inc(I, 2);
    end else
      Result := Result + S[I];
    Inc(I);
  end;
end;

function QueryToParameters(const Query: String; const Ignored: TStrings): TStringArray;
var
  Pairs: TStringArray;
  Pair, Key, Value, Map, Demo: String;
  Args: TStringList;
  Eq, I: Integer;
begin
  Args := TStringList.Create;
  try
    Map := '';
    Demo := '';
    Pairs := Query.TrimLeft(['?']).Split(['&']);
    for Pair in Pairs do
    begin
      if Pair = '' then
        Continue;
      Eq := Pos('=', Pair);
      if Eq > 0 then
      begin
        Key := LowerCase(UrlDecodeComponent(Copy(Pair, 1, Eq - 1)));
        Value := UrlDecodeComponent(Copy(Pair, Eq + 1, MaxInt));
      end else
      begin
        Key := LowerCase(UrlDecodeComponent(Pair));
        Value := '1';
      end;
      if Key = 'map' then
        Map := Value
      else
      if Key = 'skill' then
      begin
        Args.Add('+set');
        Args.Add('skill');
        Args.Add(Value);
      end else
      if Key = 'touch' then
      begin
        if Value <> '0' then
          Args.Add('--touch');
      end else
      if Key = 'fps' then
      begin
        if Value <> '0' then
          Args.Add('--fps');
      end else
      if Key = 'gamma' then
      begin
        Args.Add('-gamma');
        Args.Add(Value);
      end else
      if Key = 'demo' then
        Demo := Value
      else
      if Ignored <> nil then
        Ignored.Add(Key);
    end;
    if Demo <> '' then
    begin
      { A script runs as an autotest: default options, quits at Q }
      if Map = '' then
        Map := 'demo1';
      Args.Add('--autotest');
      Args.Add(Map);
      Args.Add('web');
      Args.Add('--demo');
      Args.Add(Demo);
    end else
    if Map <> '' then
    begin
      Args.Add('+map');
      Args.Add(Map);
    end;
    SetLength(Result, Args.Count);
    for I := 0 to Args.Count - 1 do
      Result[I] := Args[I];
  finally
    Args.Free;
  end;
end;

end.
