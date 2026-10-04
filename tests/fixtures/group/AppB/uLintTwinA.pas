unit uLintTwinA;

// For `lint`: LintTwin for an AnsiString. uLintLast lists this unit and
// uLintTwin and calls LintTwin: dcc picks among both units' overloads, and
// which one the index binds may not be dcc's - the row says so.

interface

function LintTwin(const S: AnsiString): AnsiString; overload;

implementation

function LintTwin(const S: AnsiString): AnsiString;
begin
  Result := S;
end;

end.
