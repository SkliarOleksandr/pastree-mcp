unit uFallback;

// Named by AppB.dpr `in 'Gone\uFallback.pas'`, a file that does not exist:
// dcc compiles this one, found beside the program, and so must the index.

interface

function FallbackName: string;

implementation

function FallbackName: string;
begin
  Result := 'fallback';
end;

end.
