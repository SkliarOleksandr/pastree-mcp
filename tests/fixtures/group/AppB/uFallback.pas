unit uFallback;

// Named by AppB.dpr `in 'Gone\uFallback.pas'`, a file that does not exist:
// dcc compiles this one, found beside the program, and so must the index.

interface

function FallbackName: string;

implementation

// What a routine body declares: `find` names the nested routines and the
// local type under it, and lists the local and the parameter only when no
// named declaration has the name.
function NestHost: Integer;
type
  TNestRec = record
    NestField: Integer;
  end;
var
  LNestVar: TNestRec;

  function NestInner(ANestArg: Integer): Integer;

    function NestDeepest: Integer;
    begin
      Result := 1;
    end;

  begin
    Result := ANestArg + NestDeepest;
  end;

begin
  LNestVar.NestField := NestInner(1);
  Result := LNestVar.NestField;
end;

function FallbackName: string;
begin
  if NestHost = 0 then
    Exit('');
  Result := 'fallback';
end;

end.
