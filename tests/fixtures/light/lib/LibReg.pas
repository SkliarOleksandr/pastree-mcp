unit LibReg;

// Listed for what its initialization does, nothing of it named.

interface

procedure RegisterLib;

implementation

var
  GRegistered: Boolean;

procedure RegisterLib;
begin
  GRegistered := True;
end;

initialization
  RegisterLib;

end.
