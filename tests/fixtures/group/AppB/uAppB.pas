unit uAppB;

// Project B's own unit: a descendant only project B knows about.

interface

uses
  uShapes;

type
  TBigCircle = class(TCircle)
  public
    function Area: Double; override;
  end;

procedure RunB;

implementation

function TBigCircle.Area: Double;
begin
  Result := 2 * inherited Area;
end;

procedure RunB;
var
  LSquare: TSquare;
begin
  LSquare := TSquare.Create(4);
  Writeln(TotalArea([LSquare, TBigCircle.Create(1)]):0:2);
end;

end.
