unit uLintReg;

// For `lint`: uLintAlias and uLintBase list this unit and use nothing of it.
// Either row alone is safe to act on - the other keeps it in AppB - but the
// two together leave its initialization out.

interface

var
  LintRegistered: Boolean;

implementation

initialization
  LintRegistered := True;

end.
