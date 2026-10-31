unit PasMcp.Version;

{
  The product version and the floor on the sibling PasTree library.

  PasTreeMcpVersion moves on EVERY commit - PATCH mechanically, MINOR for a
  new tool or a changed tool contract. The server reports it in its MCP
  `serverInfo`, in the log banner and in `pastree_status`, so a report from
  another machine says which build produced it.

  cMinPasTreeVersion is the oldest PasTree this server is known to work with.
  Raise it when a change here depends on a library fix whose absence would be
  SILENT (a wrong answer) rather than a compile error. Checked at startup.
}

interface

const
  PasTreeMcpVersion = '0.46.2';
  // 0.145.0: nkAmbiguous and AmbigReadingOf - `F(Gen<A, B>(D))` is one node
  // whose head is a call only when the model reads it as type arguments (a
  // compile error without them).
  // 0.129.0 before: NamedDeclRoot and ScopeOwner - the name lists' one rule, nested
  // routines and a body's types included (a compile error without them).
  // 0.124.0 before: a search by name completes itself in light mode (EnsureFind -
  // DemandFind; the units nobody loaded, NotLoadedFiles): `find` lists what
  // a full analysis lists, where an older PasTree misses the declarations of
  // library implementation sections (a silent light gap).
  // 0.123.0 before: the graph past the loaded models (NotLoadedImports,
  // NotLoadedUses, ScanNotLoaded) for lint's own reach, and a directive in
  // a `uses` clause spelling its words again (a light `defines` short).
  // 0.122.0 before: a unit's references and its rename through the workspace
  // (FindUnitReferences, PlanUnitRename), and a property's overrides whose
  // demand was empty before (a silent light gap).
  // 0.121.0 before: the tools ask through TPasWorkspace (0.120.0), whose queries
  // make the light units an answer needs full - and PlanRename's AInactive
  // overload (0.121.0). An older PasTree has no workspace (a compile error)
  // or a workspace whose demand misses a family (a silent light gap).
  // 0.117.1 before: light mode, promotion, LintPromotions (0.31.0).
  cMinPasTreeVersion = '0.145.0';

// 'pastree-mcp 0.1.0 (PasTree 0.50.1), built 2026-09-25 15:00' - the first
// line of every log.
function PasMcpVersionBanner: string;

// Raises when the linked PasTree is older than cMinPasTreeVersion.
procedure CheckPasTreeVersion;

// When this process started - `status` names it beside the pid.
function ProcessStarted: TDateTime;

implementation

uses
  System.SysUtils,
  PasTree.Version;

var
  GStarted: TDateTime;
  // Read at startup: build.bat renames a running exe aside and puts the new
  // one at its path, so read later it would be the next build's stamp.
  GBuiltOn: string;

function PasMcpVersionBanner: string;
begin
  Result := Format('pastree-mcp %s (PasTree %s), built %s',
    [PasTreeMcpVersion, PasTreeVersion, GBuiltOn]);
end;

procedure CheckPasTreeVersion;
begin
  if CompareVersions(PasTreeVersion, cMinPasTreeVersion) < 0 then
    raise Exception.CreateFmt(
      'PasTree %s is older than the required %s - update ../object-pascal-tree',
      [PasTreeVersion, cMinPasTreeVersion]);
end;

function ProcessStarted: TDateTime;
begin
  Result := GStarted;
end;

initialization
  GStarted := Now;
  GBuiltOn := BinaryBuiltOn(ParamStr(0));

end.
