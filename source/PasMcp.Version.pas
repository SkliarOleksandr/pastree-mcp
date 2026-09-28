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
  PasTreeMcpVersion = '0.15.4';
  cMinPasTreeVersion = '0.69.0';

// 'pastree-mcp 0.1.0 (PasTree 0.50.1), built 2026-09-25 15:00' - the first
// line of every log.
function PasMcpVersionBanner: string;

// Raises when the linked PasTree is older than cMinPasTreeVersion.
procedure CheckPasTreeVersion;

implementation

uses
  System.SysUtils,
  PasTree.Version;

function PasMcpVersionBanner: string;
begin
  Result := Format('pastree-mcp %s (PasTree %s), built %s',
    [PasTreeMcpVersion, PasTreeVersion, BinaryBuiltOn(ParamStr(0))]);
end;

procedure CheckPasTreeVersion;
begin
  if CompareVersions(PasTreeVersion, cMinPasTreeVersion) < 0 then
    raise Exception.CreateFmt(
      'PasTree %s is older than the required %s - update ../object-pascal-tree',
      [PasTreeVersion, cMinPasTreeVersion]);
end;

end.
