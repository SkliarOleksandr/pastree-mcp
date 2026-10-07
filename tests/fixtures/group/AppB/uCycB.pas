unit uCycB;

interface

type
  TCycB = type Integer;

function CycB: Integer;

implementation

uses
  uCycA;

function CycB: Integer;
begin
  Result := CycA;
end;

end.
