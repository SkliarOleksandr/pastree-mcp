unit uPlainForm;

// A form class with no form file of its own - no {$R} names one - so the VCL
// streams its ancestor's, uMainForm.dfm, onto an instance of it: that
// file's OnCreate = FormCreate runs this class's redeclaration. It calls
// Greet once over two lines, a comment between the arguments, and once on
// one: a callers row holds the whole call.

interface

uses
  System.Classes, uMainForm;

type
  TfrmPlain = class(TfrmMain)
    procedure FormCreate(Sender: TObject);
  private
    procedure Greet(const AName: string; ACount: Integer);
  end;

implementation

procedure TfrmPlain.FormCreate(Sender: TObject);
begin
  btnSave.Enabled := True;
  Greet(Caption, // who
    Length(Caption));
  Greet('x', 1);
end;

procedure TfrmPlain.Greet(const AName: string; ACount: Integer);
begin
end;

// A namesake no build compiles, in a unit whose uses never reach uBoxes:
// references of TCountBox.BoxCount does not count it.
{$IFDEF PASTREE_NEVER}
function BoxCount: Integer;
begin
  Result := 0;
end;
{$ENDIF}

end.
