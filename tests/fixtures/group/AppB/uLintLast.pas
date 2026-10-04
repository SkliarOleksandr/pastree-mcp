unit uLintLast;

// For `lint`: lists uLintOnce and uses nothing of it (see uLintDef), and
// calls LintTwin, which uLintTwinA and uLintTwin both declare.

interface

implementation

uses
  uLintOnce,
  uLintTwinA,
  uLintTwin;

var
  LastText: string = 'a';

initialization
  if LintTwin(LastText) = '' then
    Halt(1);

end.
