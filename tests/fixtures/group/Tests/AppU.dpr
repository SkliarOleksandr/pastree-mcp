program AppU;

// A project under the group's directory that Fixture.groupproj does not list
// (tests\smoke.ps1): its uses of uShapes are outside the index until
// pastree-mcp.json names it. Its `uses` has no `in`: uShapes resolves only
// through the search path it takes from AppA. The smoke test pins its lines.

{$APPTYPE CONSOLE}

uses
  uShapes;

begin
  if TotalArea([TCircle.Create(2)]) <= 0 then
    Halt(1);
end.
