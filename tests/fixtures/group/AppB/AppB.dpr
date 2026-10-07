program AppB;

// A bare .dpr member (no .dproj): the group reader takes both.

{$APPTYPE CONSOLE}

uses
  uShapes in '..\Shared\uShapes.pas',
  uAppB in 'uAppB.pas',
  uBoxes in 'uBoxes.pas', uGenLists in 'uGenLists.pas', uCells in 'uCells.pas', Lib.Notes in 'Lib.Notes.pas', uFlags in '..\Shared\uFlags.pas', uFallback in 'Gone\uFallback.pas', uLint in 'uLint.pas', uLintDef in 'uLintDef.pas', uLintLast in 'uLintLast.pas', uRcB in 'uRcB.pas', uRcC in 'uRcC.pas', uRcE in 'uRcE.pas', uRcF in 'uRcF.pas', uRcG in 'uRcG.pas', uRcH in 'uRcH.pas', uRcN in 'uRcN.pas', uRcQ in 'uRcQ.pas', uCycA in 'uCycA.pas';

begin
  RunB;
  Notes('done');
end.
