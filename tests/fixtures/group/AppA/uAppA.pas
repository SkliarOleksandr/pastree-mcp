unit uAppA;

// Project A's own unit: creates, uses and frees shapes.

interface

procedure RunA;

implementation

uses
  System.SysUtils,
  uShapes;

procedure RunA;
var
  LShape: TShape;
begin
  LShape := TCircle.Create(2);
  try
    TCircle(LShape).Radius := 3;
    Writeln(LShape.Describe, ' ', LShape.Area:0:2);
  finally
    FreeAndNil(LShape);
  end;
end;

end.
