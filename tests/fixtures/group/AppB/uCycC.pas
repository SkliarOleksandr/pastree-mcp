unit uCycC;

interface

function CycC: Integer;

implementation

uses
  uCycA;

function CycC: Integer;
begin
  Result := CycA;
end;

end.
