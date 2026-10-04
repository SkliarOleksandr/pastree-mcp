unit uLintMore;

// For `lint`: uLint's Limit binds here, its interface's TLintCount does
// not (see uLintBase), and AnyCell hands it a TCell whose field it reads
// without naming uCells for anything.

interface

uses
  uCells;

const
  Limit = 2;

type
  TLintCount = Int64;

function AnyCell: TCell;

implementation

function AnyCell: TCell;
begin
  Result := TCell.Create;
end;

end.
