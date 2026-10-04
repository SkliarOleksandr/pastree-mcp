unit uLintOnce;

// For `lint`: reached by AppB through uLintLast alone - uLintDef lists it
// only under FIXTURE_A, which the shared analysis takes from AppA and AppB
// does not define.

interface

var
  LintOnce: Boolean;

implementation

initialization
  LintOnce := True;

end.
