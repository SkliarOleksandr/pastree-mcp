program AppT;

// A project outside Fixture.groupproj (tests\smoke.ps1 adds it with --also):
// the client group's tests are such a project, which no .groupproj lists.

{$APPTYPE CONSOLE}

uses
  uShapes in '..\..\group\Shared\uShapes.pas',
  uAppT in 'uAppT.pas';

begin
  CheckAreas;
end.
