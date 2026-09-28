unit uChildForm;

// An inherited form: uChildForm.dfm reopens a component of its ancestor's with
// `inherited` and binds its click to a handler of its own, and binds the
// ancestor's handler on a component it adds. It redeclares FormCreate, which
// only its ancestor's form binds: MethodAddress on a TfrmChild finds its own.
// It clears the ancestor's edtName.OnChange with nil, and the two items of a
// button group (no field declared for it) bind a handler each.

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, uMainForm;

type
  TfrmChild = class(TfrmMain)
    chkConfirm: TCheckBox;
    procedure ChildSaveClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  end;

var
  frmChild: TfrmChild;

implementation

{$R *.dfm}

procedure TfrmChild.ChildSaveClick(Sender: TObject);
begin
  NameChange(Sender);
end;

procedure TfrmChild.FormCreate(Sender: TObject);
begin
  chkConfirm.Checked := True;
end;

end.
