unit uPlug;

interface

function PlugName: string;

implementation

uses
  LibBase, LibPlug;

function PlugName: string;
var
  LW: TLibWorker;
begin
  LW := PlugWorker;
  try
    Result := LW.Name;
  finally
    LW.Free;
  end;
end;

end.
