unit uRcA;

// metrics recompile: what a change to this interface recompiles. The smoke
// rows pin it; dcc's Make recompiles the same units (SPEC 9.7): those binding
// a declaration of it (uRcC, uRcD, uRcG, uRcH, uRcM, uRcQ) and those binding
// a declaration taking one in (uRcE through TRcD, uRcN through RcM) - not
// uRcB, which lists the unit and binds nothing of it, nor uRcF.

interface

const
  RcA = 1;
  RcB = 2;

type
  TRcRec = record
    X: Integer;
  end;
  TRcObj = class
  private
    FV: Integer;
  public
    procedure Touch;
  end;
  TRcGen<T> = class
    function Get: T;
  end;

function RcPlain(X: Integer): Integer;
function RcInline: Integer; inline;
function RcObj: TRcObj;

implementation

procedure TRcObj.Touch;
begin
  FV := 1;
end;

function TRcGen<T>.Get: T;
begin
  Result := Default(T);
end;

function RcPlain(X: Integer): Integer;
begin
  Result := X + RcB;
end;

function RcInline: Integer;
begin
  Result := 7;
end;

function RcObj: TRcObj;
begin
  Result := TRcObj.Create;
end;

end.
