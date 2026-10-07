unit uRcN;

interface

function RcN: Integer;

implementation

uses
  uRcM;

function RcN: Integer;
begin
  Result := RcM + RcM2;
end;

end.
