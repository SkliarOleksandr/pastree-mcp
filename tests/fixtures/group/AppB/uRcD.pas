unit uRcD;

// TRcD and RcDF take TRcRec in; RcD does not.

interface

uses
  uRcA;

type
  TRcD = record
    R: TRcRec;
  end;

const
  RcD = 5;

function RcDF: TRcRec;

implementation

function RcDF: TRcRec;
begin
  Result.X := RcD;
end;

end.
