unit uOwn;

interface

uses
  LibBase, LibInl, LibMath, LibReg;

type
  TOwnWorker = class(TLibWorker)
  public
    procedure DoWork; override;
  end;

procedure OwnMain;

implementation

procedure TOwnWorker.DoWork;
begin
  inherited;
end;

procedure OwnMain;
var
  LW: TOwnWorker;
begin
  LW := TOwnWorker.Create;
  try
    LibRun(LW);
    if Twice(2) = 4 then
      LW.DoWork;
  finally
    LW.Free;
  end;
end;

end.
