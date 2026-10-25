program LightApp;

// The light-mode fixture: its library is ..\lib, on the search path.

{$APPTYPE CONSOLE}

uses
  uOwn in 'uOwn.pas',
  uPlug in 'uPlug.pas';

begin
  OwnMain;
  Writeln(PlugName);
end.
