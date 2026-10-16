unit uFlags;

// Conditional compilation for `defines`: a project define and switch ($R+;
// FIXTURE_A, in AppA's .dproj only - AppB shares its analysis), a unit's own
// $DEFINE and $UNDEF from an include, nesting, an $IF expression, a branch
// nothing selects, `$IFOPT R+` before and after the unit's own `$R-`.

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
{$IFOPT R+}
  Result := Result + '+range';
{$ELSE}
  Result := Result + '+norange';
{$ENDIF}
{$R-}
{$IFOPT R+}
  Result := Result + '+still';
{$ENDIF}
end;

end.
