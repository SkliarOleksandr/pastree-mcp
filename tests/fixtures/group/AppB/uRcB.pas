unit uRcB;

// Lists uRcA and binds nothing of it: not recompiled when it changes.

interface

uses
  uRcA;

function RcB2: Integer;

implementation

function RcB2: Integer;
begin
  Result := 2;
end;

end.
