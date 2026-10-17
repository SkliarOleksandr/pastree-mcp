unit LibInl;

// An inline routine whose body needs LibMath: a unit calling Twice must list
// LibMath for dcc to expand the call (H2443).

interface

function Twice(A: Integer): Integer; inline;

implementation

uses
  LibMath;

function Twice(A: Integer): Integer;
begin
  Result := Mul2(A);
end;

end.
