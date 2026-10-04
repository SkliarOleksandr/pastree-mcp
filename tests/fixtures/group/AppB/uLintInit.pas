unit uLintInit;

// For `lint`: a unit whose only effect is its initialization - uLint names
// nothing of it, and removing it from there leaves this out of AppB.

interface

var
  LintStarted: Boolean;

implementation

initialization
  LintStarted := True;

end.
