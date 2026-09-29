unit uFrame;

// A frame: wherever it is placed inline, its components are fields of
// TfraName, and the host form may set its button's handler to a method of the
// host's own (uMainForm.dfm).

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;

type
  // Set THROUGH a property of the frame by uChildForm.dfm: `Style.Accent`
  // and a `Tags` item's `Weight` - form lines that references of each lists.
  TNameStyle = class(TPersistent)
  private
    FAccent: Integer;
    FShade: Integer;
  published
    property Accent: Integer read FAccent write FAccent;
    property Shade: Integer read FShade write FShade;   // no form sets it
  end;

  TNameTag = class(TCollectionItem)
  private
    FWeight: Integer;
  published
    property Weight: Integer read FWeight write FWeight;
  end;

  TNameTags = class(TCollection)
  private
    function GetItem(AIndex: Integer): TNameTag;
  public
    property Items[AIndex: Integer]: TNameTag read GetItem; default;
  end;

  TfraName = class(TFrame)
    edtValue: TEdit;
    btnClear: TButton;
    procedure btnClearClick(Sender: TObject);
  private
    FTitle: string;
    FStyle: TNameStyle;
    FTags: TNameTags;
  published
    // Set by uChildForm.dfm on its frame: a form line that references of
    // the property lists, and no code uses.
    property Title: string read FTitle write FTitle;
    property Note: string read FTitle;   // published, and no form sets it
    property Style: TNameStyle read FStyle;
    property Tags: TNameTags read FTags;
  end;

implementation

{$R *.dfm}

function TNameTags.GetItem(AIndex: Integer): TNameTag;
begin
  Result := TNameTag(inherited Items[AIndex]);
end;

procedure TfraName.btnClearClick(Sender: TObject);
begin
  edtValue.Text := '';
  // A code use of a property two form lines set: cut to one row, the
  // answer keeps this one (smoke: references form cut).
  if FStyle <> nil then
    FStyle.Accent := 0;
end;

end.
