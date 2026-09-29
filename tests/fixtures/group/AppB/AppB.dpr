program AppB;

// A bare .dpr member (no .dproj): the group reader takes both.

{$APPTYPE CONSOLE}

uses
  uShapes in '..\Shared\uShapes.pas',
  uAppB in 'uAppB.pas',
  uBoxes in 'uBoxes.pas', uGenLists in 'uGenLists.pas';

begin
  RunB;
end.
