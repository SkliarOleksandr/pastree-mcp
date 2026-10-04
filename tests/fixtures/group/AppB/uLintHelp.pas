unit uLintHelp;

// For `lint`: a helper uLint uses only in its implementation, and a constant
// uLintMore declares too - moved to the end of uLint's implementation uses,
// this unit's Limit would hide uLintMore's.

interface

type
  TLintHelper = record helper for Integer
    function Twice: Integer;
  end;

const
  Limit = 1;

implementation

function TLintHelper.Twice: Integer;
begin
  Result := Self * 2;
end;

end.
