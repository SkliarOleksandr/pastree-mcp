unit uFlags;

// Conditional compilation for `defines`: a project define (FIXTURE_A, in
// AppA's .dproj only - AppB shares its analysis), a unit's own $DEFINE and
// $UNDEF from an include, nesting, an $IF expression, a branch nothing
// selects.

interface

{$I Flags.inc}

function FlagName: string;

implementation

function FlagName: string;
begin
{$IFDEF FIXTURE_A}
  Result := 'A';
{$ELSE}
  Result := 'other';
{$ENDIF}
{$IFDEF FIXTURE_LOCAL}
  {$IFNDEF FIXTURE_OFF}
  Result := Result + '+local';
  {$ENDIF}
{$ENDIF}
{$IF Defined(MSWINDOWS) and not Defined(FIXTURE_GONE)}
  Result := Result + '+win';
{$IFEND}
{$IFDEF FIXTURE_NEVER}
  Result := Result + '+never';
  {$IFDEF FIXTURE_A}
  Result := Result + '+deep';
  {$ENDIF}
{$ENDIF}
end;

end.
