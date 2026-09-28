unit uFrame;

// A frame: wherever it is placed inline, its components are fields of
// TfraName, and the host form may set its button's handler to a method of the
// host's own (uMainForm.dfm).

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;

type
  TfraName = class(TFrame)
    edtValue: TEdit;
    btnClear: TButton;
    procedure btnClearClick(Sender: TObject);
  private
    FTitle: string;
  published
    // Set by uChildForm.dfm on its frame: a form line that references of
    // the property lists, and no code uses.
    property Title: string read FTitle write FTitle;
    property Note: string read FTitle;   // published, and no form sets it
  end;

implementation

{$R *.dfm}

procedure TfraName.btnClearClick(Sender: TObject);
begin
  edtValue.Text := '';
end;

end.
