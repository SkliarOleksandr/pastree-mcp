unit uChildForm;

// An inherited form: uChildForm.dfm reopens a component of its ancestor's with
// `inherited` and binds its click to a handler of its own, and binds the
// ancestor's handler on a component it adds.

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, uMainForm;

type
  TfrmChild = class(TfrmMain)
    chkConfirm: TCheckBox;
    procedure ChildSaveClick(Sender: TObject);
  end;

var
  frmChild: TfrmChild;

implementation

{$R *.dfm}

procedure TfrmChild.ChildSaveClick(Sender: TObject);
begin
  NameChange(Sender);
end;

end.
