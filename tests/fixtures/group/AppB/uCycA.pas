unit uCycA;

// metrics cycles: uCycA -> uCycB ~> uCycA, and uCycA ~> uCycC ~> uCycA
// through an entry lint finds unused (uCycC below).

interface

uses
  uCycB;

function CycA: TCycB;

implementation

uses
  uCycC;

function CycA: TCycB;
begin
  Result := 1;
end;

end.
