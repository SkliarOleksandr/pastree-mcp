program AppB;

// A bare .dpr member (no .dproj): the group reader takes both.

{$APPTYPE CONSOLE}

uses
  uShapes in '..\Shared\uShapes.pas',
  uAppB in 'uAppB.pas';

begin
  RunB;
end.
