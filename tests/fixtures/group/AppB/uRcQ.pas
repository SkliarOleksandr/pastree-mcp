unit uRcQ;

// Only declares a variable of the generic: its method bodies are part of it.

interface

function RcQ: Boolean;

implementation

uses
  uRcA;

function RcQ: Boolean;
var
  LV: TRcGen<Integer>;
begin
  LV := nil;
  Result := LV = nil;
end;

end.
