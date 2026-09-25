unit uBoxes;

// Fixture for `callers` in tests\smoke.ps1: a property's getter and setter, a
// handler assigned rather than called, a bare inherited and a routine nothing
// calls. The smoke test pins line numbers of this file.

interface

uses
  System.Classes;

type
  TShapeBox = class(TPersistent)
  private
    FItem: TObject;
    FOnChange: TNotifyEvent;
    function GetItem: TObject;
    procedure SetItem(AValue: TObject);
  protected
    procedure Changed; virtual;
  published
    procedure BoxClick(Sender: TObject);
    property Item: TObject read GetItem write SetItem;
  end;

  TBigBox = class(TShapeBox)
  protected
    procedure Changed; override;
  end;

procedure NeverCalled;

implementation

function TShapeBox.GetItem: TObject;
begin
  Result := FItem;
end;

procedure TShapeBox.SetItem(AValue: TObject);
begin
  FItem := AValue;
  FOnChange := BoxClick;
  Changed;
end;

procedure TShapeBox.Changed;
begin
end;

procedure TShapeBox.BoxClick(Sender: TObject);
begin
  if Item <> nil then
    Item := nil;
end;

procedure TBigBox.Changed;
begin
  inherited;
end;

procedure NeverCalled;
begin
end;

end.
