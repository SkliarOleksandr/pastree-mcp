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

type
  // Declarations written over several lines: `find`, `members` and `outline`
  // show each whole, and one longer than a row cut at a parameter boundary.
  TWideBox = class
  public
    function Configure(const AFirstName: string; ASecondValue: Integer;
      const AThirdName: string = 'third';
      AFourthFlag: Boolean = False): Boolean;
    procedure Many(const AAlphaName, ABetaName, AGammaName: string;
      ADeltaCount, AEpsilonCount, AZetaCount: Integer;
      const AEtaText, AThetaText, AIotaText: string); virtual;
  end;

function TWideBox.Configure(const AFirstName: string; ASecondValue: Integer;
  const AThirdName: string; AFourthFlag: Boolean): Boolean;
begin
  Result := AFourthFlag;
end;

procedure TWideBox.Many(const AAlphaName, ABetaName, AGammaName: string;
  ADeltaCount, AEpsilonCount, AZetaCount: Integer;
  const AEtaText, AThetaText, AIotaText: string);
begin
end;

// Fields whose types are written in place: `members` of one says so.
type
  TBufRec = record
    Buf: array[0..3] of Byte;
    Code: string[6];
  end;
  // A class-reference type: `related descendants` of it is of TShapeBox.
  TShapeBoxClass = class of TShapeBox;

end.
