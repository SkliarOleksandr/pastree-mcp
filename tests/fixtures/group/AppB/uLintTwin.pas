unit uLintTwin;

// For `lint`: LintTwin for a string - see uLintTwinA.

interface

function LintTwin(const S: string): string; overload;

implementation

function LintTwin(const S: string): string;
begin
  Result := S;
end;

end.
