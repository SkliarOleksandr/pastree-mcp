unit uMainForm;

// A form whose .dfm binds by name: its components to these published fields,
// events to these published methods, a label to a component, a button to a
// data module's menu, and a frame inline, whose button's click is set to a
// method of this form.

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, uFrame;

type
  TfrmMain = class(TForm)
    lblName: TLabel;
    edtName: TEdit;
    btnSave: TButton;
    fraName1: TfraName;
    procedure FormCreate(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure NameChange(Sender: TObject);
    procedure fraName1btnClearClick(Sender: TObject);
    procedure NeverBound(Sender: TObject);
  private
    FSaved: Boolean;
    procedure Save;
  end;

var
  frmMain: TfrmMain;

implementation

uses
  uData;

{$R *.dfm}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  btnSave.Enabled := False;
end;

// Bound by uMainForm.dfm and uChildForm.dfm; no code calls it.
procedure TfrmMain.btnSaveClick(Sender: TObject);
begin
  Save;
end;

// Bound by uMainForm.dfm, and called from code too.
procedure TfrmMain.NameChange(Sender: TObject);
begin
  btnSave.Enabled := edtName.Text <> '';
end;

// The inline frame's button runs this, the host form's method.
procedure TfrmMain.fraName1btnClearClick(Sender: TObject);
begin
  fraName1.btnClearClick(Sender);
  NameChange(Sender);
end;

// Published, and bound by no form file.
procedure TfrmMain.NeverBound(Sender: TObject);
begin
end;

procedure TfrmMain.Save;
begin
  FSaved := True;
end;

end.
