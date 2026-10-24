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

// Audit 2026-10-24 (0.44.1). An unscoped enum value and a record field of the
// same name: `find akBeta` lists both (the value lost to any namesake).
type
  TAuditKind = (akAlpha, akBeta);
  TAuditHolder = record
    akBeta: Integer;
  end;

  // A generic list of a class: creating it creates no TAuditBox.
  TAuditList<T> = class
  end;

  // A generic type's method and a class method, addressed by file + line.
  TAuditMap<V> = record
    function Get: Integer;
  end;

  TAuditBox = class
  public
    class procedure Twice;
    class function Make: TAuditBox;
  end;

function TAuditMap<V>.Get: Integer;
begin
  Result := Ord(akBeta);
end;

class procedure TAuditBox.Twice;
{ The body starts over 200 lines below the header: `definition` names the
  header as where it is implemented, not a line of the body.
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
  .
}
begin
  TAuditList<TAuditBox>.Create.Free;
end;

class function TAuditBox.Make: TAuditBox;
begin
  Result := TAuditBox.Create;
end;

end.
