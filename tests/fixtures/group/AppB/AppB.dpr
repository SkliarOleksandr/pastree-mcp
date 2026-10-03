program AppB;

// A bare .dpr member (no .dproj): the group reader takes both.

{$APPTYPE CONSOLE}

uses
  uShapes in '..\Shared\uShapes.pas',
  uAppB in 'uAppB.pas',
  uBoxes in 'uBoxes.pas', uGenLists in 'uGenLists.pas', uCells in 'uCells.pas', Lib.Notes in 'Lib.Notes.pas', uFlags in '..\Shared\uFlags.pas', uFallback in 'Gone\uFallback.pas';

begin
  RunB;
  Notes('done');
end.
