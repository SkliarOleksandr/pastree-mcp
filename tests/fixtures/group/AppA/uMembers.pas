unit uMembers;

// Fixture for `members` in tests\smoke.ps1: a hierarchy in one unit - what a
// descendant's methods reach of its ancestor's private, strict and protected
// members - overloads across the two, a property republished, a streaming
// class's unnamed first section and a record with no members. The smoke test
// pins line numbers of this file.

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

end.
