unit uShapes;

// Fixture for tests\smoke.ps1: a class hierarchy with an interface, shared by
// both projects of Fixture.groupproj. The smoke test pins line numbers of
// this file - move a declaration and update the expectations with it.

interface

type
  IShape = interface
    ['{6B1E2D57-2F0E-4B8B-9C44-0F1A7C3E5D21}']
    function Area: Double;
  end;

  TShape = class(TInterfacedObject, IShape)
  public
    function Area: Double; virtual; abstract;
    function Describe: string; virtual;
  end;

  TCircle = class(TShape)
  private
    FRadius: Double;
  public
    constructor Create(ARadius: Double);
    function Area: Double; override;
    property Radius: Double read FRadius write FRadius;
  end;

  TSquare = class(TShape)
  private
    FSide: Double;
  public
    constructor Create(ASide: Double);
    function Area: Double; override;
  end;

function TotalArea(const AShapes: array of IShape): Double;

implementation

function TShape.Describe: string;
begin
  Result := ClassName;
end;

constructor TCircle.Create(ARadius: Double);
begin
  inherited Create;
  FRadius := ARadius;
end;

function TCircle.Area: Double;
begin
  Result := Pi * FRadius * FRadius;
end;

constructor TSquare.Create(ASide: Double);
begin
  inherited Create;
  FSide := ASide;
end;

function TSquare.Area: Double;
begin
  Result := FSide * FSide;
end;

function TotalArea(const AShapes: array of IShape): Double;
var
  LShape: IShape;
begin
  Result := 0;
  for LShape in AShapes do
    Result := Result + LShape.Area;
end;

end.
