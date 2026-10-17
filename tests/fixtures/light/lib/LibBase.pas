unit LibBase;

// A library unit (tests\smoke.ps1 names this directory with --light): its
// body runs an own override, which light mode does not see.

interface

type
  TLibWorker = class
  public
    procedure DoWork; virtual;
    function Name: string; virtual;
  end;

procedure LibRun(AWorker: TLibWorker);

implementation

uses
  LibHidden;

procedure TLibWorker.DoWork;
begin
  HiddenStep;
end;

function TLibWorker.Name: string;
begin
  Result := 'worker';
end;

procedure LibRun(AWorker: TLibWorker);
begin
  AWorker.DoWork;
end;

end.
