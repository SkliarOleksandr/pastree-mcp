unit uCells;

// Fixture for a default array property: `AList[0]` uses it with no name
// written - references, callers of its getter and setter, callees of a
// routine indexing it. The smoke test pins line numbers of this file.

interface

type
  TCell = class
  public
    Text: string;
  end;

  TCellList = class
  private
    FCells: array of TCell;
    function GetCell(I: Integer): TCell;
    procedure SetCell(I: Integer; ACell: TCell);
  public
    property Cells[I: Integer]: TCell read GetCell write SetCell; default;
  end;

procedure SwapCells(AList: TCellList);
function FirstText(AList: TCellList): string;

implementation

function TCellList.GetCell(I: Integer): TCell;
begin
  Result := FCells[I];
end;

procedure TCellList.SetCell(I: Integer; ACell: TCell);
begin
  FCells[I] := ACell;
end;

procedure SwapCells(AList: TCellList);
var
  LCell: TCell;
begin
  LCell := AList[0];
  AList[0] := AList[1];
  AList[1] := LCell;
end;

function FirstText(AList: TCellList): string;
begin
  Result := AList[0].Text;
end;

end.
