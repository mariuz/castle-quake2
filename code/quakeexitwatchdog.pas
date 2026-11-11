{ Exit watchdog for scripted runs (autotests, --map-report).

  After a script asks to quit, the main loop ends and the units are
  finalized. On CI's virtual display the process has sometimes stayed alive
  after that (after "Sound backend closed"), until CI killed it 10 minutes
  later. StartExitWatchdog starts a thread that ends the process at once if
  it is still running after the grace time, saying so on stdout. }
unit QuakeExitWatchdog;

{$mode objfpc}{$H+}

interface

{ Start the watchdog (once; later calls do nothing) }
procedure StartExitWatchdog(const GraceSeconds: Integer = 20);

implementation

uses
  SysUtils, Classes {$ifdef UNIX}, BaseUnix{$endif};

var
  Started: Boolean;
  Grace: Integer;

function WatchdogThread(Parameter: Pointer): PtrInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Grace * 10 do
    Sleep(100);
  { Still here: shutdown is stuck. Skip whatever blocks it. }
  WriteLn('ExitWatchdog: still running ', Grace, ' s after quitting, ending the process');
  Flush(Output);
  {$ifdef UNIX}
  FpExit(0);
  {$else}
  Halt(0);
  {$endif}
end;

procedure StartExitWatchdog(const GraceSeconds: Integer);
begin
  if Started then
    Exit;
  {$if defined(WASI) or defined(CASTLE_DISABLE_THREADS)}
  Exit; { no threads (the web build); it has no shutdown to wait for anyway }
  {$endif}
  Started := True;
  Grace := GraceSeconds;
  { A plain thread (not TThread): nothing waits for it at exit }
  BeginThread(@WatchdogThread, nil);
end;

end.
