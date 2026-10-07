unit uRcG;

interface

function RcG: Integer;

implementation

uses
  uRcA;

function RcG: Integer;
begin
  Result := RcInline;
end;

end.
