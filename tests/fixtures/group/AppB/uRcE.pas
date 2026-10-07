unit uRcE;

interface

function RcE: Integer;

implementation

uses
  uRcD;

function RcE: Integer;
var
  LV: TRcD;
begin
  LV.R.X := 1;
  Result := LV.R.X;
end;

end.
