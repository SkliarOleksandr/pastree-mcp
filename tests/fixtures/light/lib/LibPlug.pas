unit LibPlug;

// A library unit whose implementation overrides TLibWorker.Name: read light,
// `callees` of a call through Name makes it full before it answers.

interface

uses
  LibBase;

function PlugWorker: TLibWorker;

implementation

type
  TPlugWorker = class(TLibWorker)
  public
    function Name: string; override;
  end;

function TPlugWorker.Name: string;
begin
  Result := 'plug';
end;

function PlugWorker: TLibWorker;
begin
  Result := TPlugWorker.Create;
end;

end.
