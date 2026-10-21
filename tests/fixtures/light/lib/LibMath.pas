unit LibMath;

interface

function Mul2(A: Integer): Integer;

implementation

function Mul2(A: Integer): Integer;
begin
  Result := A * 2;
end;

// Declared in the implementation alone: `find` lists it in light mode too.
type
  TMathCache = class
    procedure Reset;
  end;

procedure TMathCache.Reset;
begin
end;

end.
