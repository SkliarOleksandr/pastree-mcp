unit uMembers;

// Fixture for `members` and `callees` in tests\smoke.ps1: a hierarchy in one
// unit - what a descendant reaches of its ancestor's private, strict and
// protected members - overloads across the two, a property republished, a
// streaming class, an empty record and a routine calling through a getter.
// The smoke test pins line numbers of this file.

interface

uses
  System.Classes;

type
  TBase = class
  strict private
    FSecret: Integer;
  private
    FCount: Integer;
  strict protected
    procedure Guarded; virtual;
  protected
    function GetCount: Integer;
  public
    procedure Add(AValue: Integer); overload;
    procedure Add(const AText: string); overload;
    procedure Reset; virtual;
    property Count: Integer read GetCount;
  end;

  TDerived = class(TBase)
  protected
    procedure Guarded; override;
  public
    procedure Add(AValue: Double); overload;
    procedure Reset; override;
  published
    property Count;
  end;

  // A TPersistent streams: its unnamed first section is published, where a
  // form's components and event handlers sit.
  TPanelModel = class(TPersistent)
    Source: TComponent;
    procedure SourceChange(Sender: TObject);
  end;

  TEmpty = record
  end;

  // For `callees`: a routine reaching others through a property's getter, a
  // virtual method the receiver's type may override, an overload, a nested
  // routine and a method pointer.
  TRunner = class
  private
    FBase: TBase;
    FOnDone: TNotifyEvent;
    function GetBase: TBase;
  public
    procedure Run;
    property Base: TBase read GetBase;
  end;

implementation

procedure TBase.Guarded;
begin
end;

function TBase.GetCount: Integer;
begin
  Result := FCount + FSecret;
end;

procedure TBase.Add(AValue: Integer);
begin
  Inc(FCount, AValue);
end;

procedure TBase.Add(const AText: string);
begin
  Add(Length(AText));
end;

procedure TBase.Reset;
begin
  FCount := 0;
end;

procedure TDerived.Guarded;
begin
  inherited;
end;

procedure TDerived.Add(AValue: Double);
begin
end;

procedure TDerived.Reset;
begin
  inherited;
end;

procedure TPanelModel.SourceChange(Sender: TObject);
begin
end;

function TRunner.GetBase: TBase;
begin
  if FBase = nil then
    FBase := TDerived.Create;
  Result := FBase;
end;

procedure TRunner.Run;

  procedure Finish;
  begin
    if Assigned(FOnDone) then
      FOnDone(Self);
  end;

begin
  Base.Reset;
  Base.Add('done');
  Finish;
end;

type
  // An indexed property written runs its setter, and read its getter.
  TSlots = class
  private
    function GetSlot(I: Integer): TBase;
    procedure SetSlot(I: Integer; AValue: TBase);
  public
    property Slots[I: Integer]: TBase read GetSlot write SetSlot;
  end;

function TSlots.GetSlot(I: Integer): TBase;
begin
  Result := nil;
end;

procedure TSlots.SetSlot(I: Integer; AValue: TBase);
begin
end;

procedure FillSlots(ASlots: TSlots);
begin
  ASlots.Slots[0] := ASlots.Slots[1];
end;

end.
