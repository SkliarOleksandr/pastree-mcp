unit uAppT;

// Fixture for tests\smoke.ps1: the unit of a project outside the group. The
// smoke test pins line numbers of this file.

interface

procedure CheckAreas;

implementation

uses
  uShapes;

procedure CheckAreas;
begin
  if TotalArea([TCircle.Create(1)]) <= 0 then
    Halt(1);
end;

end.
