unit uBinaryForm;

// A form whose .dfm is binary - the resource format older IDEs saved, which
// grep cannot read: its names are read from the text it converts to, and a
// rename cannot write it in place.

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;

type
  TfrmBinary = class(TForm)
    btnBinary: TButton;
    procedure btnBinaryClick(Sender: TObject);
  end;

var
  frmBinary: TfrmBinary;

implementation

{$R *.dfm}

procedure TfrmBinary.btnBinaryClick(Sender: TObject);
begin
end;

end.
