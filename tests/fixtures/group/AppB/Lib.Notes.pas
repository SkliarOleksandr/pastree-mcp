unit Lib.Notes;

// A dotted unit whose last segment is also the name of a routine it exports:
// `Notes(...)` in a unit that uses Lib.Notes calls the routine - the segment
// is no name in scope (only the written `Lib.Notes` qualifies).

interface

procedure Notes(const AText: string);

implementation

procedure Notes(const AText: string);
begin
  Writeln(AText);
end;

end.