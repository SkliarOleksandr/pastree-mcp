unit uLint;

// Fixture for `lint` in tests\smoke.ps1: each `uses` entry is here for one
// case. The smoke test pins line numbers of this file.

interface

uses
  System.SysUtils,
  System.Classes,
  uColors,
  uLintInit,
  uLintHelp,
  uLintBase;

type
  ELint = class(Exception);

procedure LintRun;
function LintTotal: TLintCount;

implementation

uses
  uLintMore,
  uCells,
  uFlags,
  uBoxes,
  uLintAlias;

procedure LintRun;
var
  LList: TStringList;
  LCount: Integer;
begin
  LList := TStringList.Create;
  try
    LCount := 2;
    LList.Add(IntToStr(LCount.Twice + Limit));
    LList.Add(AnyCell.Text);
    LList.Add(uFlags.FlagName);
    LList.Add(IntToStr(SizeOf(IItem)));
{$IFDEF LINT_NEVER}
    NeverCalled;
{$ENDIF}
  finally
    LList.Free;
  end;
end;

function LintTotal;
begin
  Result := Limit;
end;

end.
