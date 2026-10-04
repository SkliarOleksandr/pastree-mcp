unit uLintDef;

// For `lint`: lists uLintOnce under FIXTURE_A. The shared analysis compiles
// the entry (AppA's defines) - AppB, built without FIXTURE_A, does not have
// it, and uLintLast's entry is its only path to uLintOnce. System.Classes,
// used only in the implementation, is listed in the interface under
// FIXTURE_A: moved bare, AppB would compile it too.

interface

{$IFDEF FIXTURE_A}
uses
  System.Classes;
{$ENDIF}

procedure LintDef;

implementation

{$IFDEF FIXTURE_A}
uses
  uLintOnce;
{$ENDIF}

procedure LintDef;
begin
{$IFDEF FIXTURE_A}
  LintOnce := TStringList.ClassName <> '';
{$ENDIF}
end;

end.
