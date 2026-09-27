unit uData;

// A data module: a form names one of its components through the module's
// Name - `PopupMenu = dmData.pmActions` in uMainForm.dfm - as TReader's global
// fixups resolve it.

interface

uses
  System.Classes, Vcl.Menus;

type
  TdmData = class(TDataModule)
    pmActions: TPopupMenu;
    miSave: TMenuItem;
    procedure miSaveClick(Sender: TObject);
  end;

var
  dmData: TdmData;

implementation

{$R *.dfm}

procedure TdmData.miSaveClick(Sender: TObject);
begin
end;

end.
