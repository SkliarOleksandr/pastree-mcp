unit uColors;

// Enum values addressed by name (field report FR.1): an unscoped enum's
// value by its own name or as TTint.tnRed; a scoped one's as TShade.Dark,
// by its bare name only when nothing else has it - its TSquare must not make
// the class TSquare of uShapes ambiguous.

interface

type
  TTint = (tnRed, tnGreen, tnBlue);

{$SCOPEDENUMS ON}
  TShade = (Light, Dark, TSquare);
{$SCOPEDENUMS OFF}

function TintName(ATint: TTint): string;
function IsDark(AShade: TShade): Boolean;

implementation

function TintName(ATint: TTint): string;
begin
  case ATint of
    tnRed: Result := 'red';
    tnGreen: Result := 'green';
  else
    Result := 'other';
  end;
end;

function IsDark(AShade: TShade): Boolean;
begin
  Result := AShade = TShade.Dark;
end;

end.
