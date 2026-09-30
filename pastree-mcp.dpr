program pastree_mcp;

{
  PasTree MCP server (see README.md and SPEC.md). WIN64 ONLY, like every
  PasTree host: a real project group's closure does not fit a 32-bit address
  space.

  Two ways to run it:

  - As an MCP server (the default): stdin/stdout carry the protocol, stderr
    and <project>-pastree-mcp.log beside the project carry the log.

  - As a one-shot CLI, for trying tools and measuring them without a client:
      pastree-mcp --project X.groupproj --call find <json arguments>
    `--call <tool> <json>` repeats; `--script <file>` reads one
    `tool <json>` per line instead (shell quoting of JSON on Windows is
    miserable; tests\smoke.calls is an example). NB no JSON object literal in
    this comment: its closing brace would end the comment early. The
    analysis is built once and every call runs against it.

  Options: --project <.groupproj|.dproj|.dpr> (default: the only .groupproj,
  else the only .dproj, in the current directory or the nearest one above it
  up to the repository root), --also <.dproj|.dpr> (repeats: a project outside
  the group indexed and built with it - relative to the project's directory),
  --studio <BDS version>,
  --platform <Win32|Win64>, --config <Debug|Release>, --groups <shared|strict>,
  --build-dir <dir> (where `compile` builds; default %TEMP%\pastree-mcp),
  --log <file|none>, --version.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.StrUtils,
  System.Diagnostics,
  Winapi.Windows,
  PasMcp.Version in 'source\PasMcp.Version.pas',
  PasMcp.Log in 'source\PasMcp.Log.pas',
  PasMcp.Transport in 'source\PasMcp.Transport.pas',
  PasMcp.Studio in 'source\PasMcp.Studio.pas',
  PasMcp.GroupProj in 'source\PasMcp.GroupProj.pas',
  PasMcp.Workspace in 'source\PasMcp.Workspace.pas',
  PasMcp.Build in 'source\PasMcp.Build.pas',
  PasMcp.Tools in 'source\PasMcp.Tools.pas',
  PasMcp.Server in 'source\PasMcp.Server.pas';

type
  TCall = record
    Tool: string;
    Json: string;
  end;

var
  GProject, GStudio, GPlatform, GConfig, GLog: string;
  GAlso: TArray<string>;
  GPolicy: TMcpGroupPolicy;
  GCalls: TArray<TCall>;
  GWs: TMcpWorkspace;

procedure Fail(const AMsg: string);
begin
  Log(AMsg);
  ExitProcess(2);
end;

{ Registered once for every repository (`claude mcp add --scope user`), the
  server starts in whatever directory the session was opened in - often a
  subdirectory of the project's. So the nearest directory holding a project
  file, from the current one up: the first one holding any decides, and an
  ambiguous one fails rather than being passed over for a project above it
  that the session is not in. The walk stops at the repository root (a `.git`
  directory, or the `.git` file of a worktree or submodule) - above it is
  another repository, or none - and at the drive root. }
function DiscoverProject: string;
var
  LDir, LUp: string;
  LFound: TArray<string>;
begin
  // With its delimiter throughout: `C:` alone is the drive's current directory.
  LDir := IncludeTrailingPathDelimiter(GetCurrentDir);
  repeat
    LFound := TDirectory.GetFiles(LDir, '*.groupproj');
    if Length(LFound) > 1 then
      Fail('several .groupproj files in ' + LDir + ' - pass --project');
    if Length(LFound) = 0 then
    begin
      LFound := TDirectory.GetFiles(LDir, '*.dproj');
      if Length(LFound) > 1 then
        Fail('several .dproj files and no .groupproj in ' + LDir +
          ' - pass --project');
    end;
    if Length(LFound) = 1 then
    begin
      if not SameText(LDir, IncludeTrailingPathDelimiter(GetCurrentDir)) then
        Log('project %s found above the working directory %s',
          [LFound[0], GetCurrentDir]);
      Exit(LFound[0]);
    end;
    if TDirectory.Exists(LDir + '.git') or TFile.Exists(LDir + '.git') then
      Break;
    LUp := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(LDir)));
    if Length(LUp) >= Length(LDir) then
      Break;   // the drive root, or a share's
    LDir := LUp;
  until False;
  Fail('no .groupproj or .dproj in ' + GetCurrentDir + ' or above it up to ' +
    LDir + ' - pass --project <file>');
  Result := '';
end;

procedure AddScript(const APath: string);
var
  LLine: string;
  LCall: TCall;
  LAt: Integer;
begin
  for LLine in TFile.ReadAllLines(APath) do
  begin
    if (Trim(LLine) = '') or Trim(LLine).StartsWith('#') then
      Continue;
    LAt := Pos(' ', Trim(LLine));
    if LAt = 0 then
    begin
      LCall.Tool := Trim(LLine);
      LCall.Json := '{}';
    end
    else
    begin
      LCall.Tool := Copy(Trim(LLine), 1, LAt - 1);
      LCall.Json := Trim(Copy(Trim(LLine), LAt + 1, MaxInt));
    end;
    GCalls := GCalls + [LCall];
  end;
end;

procedure ParseArgs;
var
  LIdx: Integer;
  LCall: TCall;

  function Next: string;
  begin
    Inc(LIdx);
    if LIdx > ParamCount then
      Fail('missing value after ' + ParamStr(LIdx - 1));
    Result := ParamStr(LIdx);
  end;

begin
  GPolicy := gpShared;
  LIdx := 1;
  while LIdx <= ParamCount do
  begin
    if SameText(ParamStr(LIdx), '--version') then
    begin
      Writeln(PasMcpVersionBanner);
      // ExitProcess skips the RTL's closing of Output: redirected to a pipe,
      // the line would still be in its buffer.
      Flush(Output);
      ExitProcess(0);
    end
    else if SameText(ParamStr(LIdx), '--project') then
      GProject := Next
    else if SameText(ParamStr(LIdx), '--also') then
      GAlso := GAlso + [Next]
    else if SameText(ParamStr(LIdx), '--studio') then
      GStudio := Next
    else if SameText(ParamStr(LIdx), '--platform') then
      GPlatform := Next
    else if SameText(ParamStr(LIdx), '--config') then
      GConfig := Next
    else if SameText(ParamStr(LIdx), '--log') then
      GLog := Next
    else if SameText(ParamStr(LIdx), '--build-dir') then
      BuildRoot := TPath.GetFullPath(Next)
    else if SameText(ParamStr(LIdx), '--groups') then
    begin
      if SameText(Next, 'strict') then
        GPolicy := gpStrict
      else
        GPolicy := gpShared;
    end
    else if SameText(ParamStr(LIdx), '--call') then
    begin
      LCall.Tool := Next;
      if (LIdx < ParamCount) and not ParamStr(LIdx + 1).StartsWith('--') then
        LCall.Json := Next
      else
        LCall.Json := '{}';
      GCalls := GCalls + [LCall];
    end
    else if SameText(ParamStr(LIdx), '--script') then
      AddScript(Next)
    else
      Fail('unknown argument: ' + ParamStr(LIdx));
    Inc(LIdx);
  end;
  if GProject = '' then
    GProject := DiscoverProject;
  GProject := TPath.GetFullPath(GProject);
  if not TFile.Exists(GProject) then
    Fail('no such project: ' + GProject);
  for var LI := 0 to High(GAlso) do
  begin
    GAlso[LI] := TPath.GetFullPath(TPath.Combine(TPath.GetDirectoryName(
      GProject), GAlso[LI]));
    if not TFile.Exists(GAlso[LI]) then
      Fail('no such project (--also): ' + GAlso[LI]);
  end;
end;

procedure RunCli;
var
  LArgs: TJSONValue;
  LText: string;
  LIsError: Boolean;
  LSW: TStopwatch;
  LOut: TBytes;
  LWritten: DWORD;
begin
  GWs.Load;
  for var LCall in GCalls do
  begin
    LArgs := TJSONObject.ParseJSONValue(LCall.Json);
    try
      if (LArgs <> nil) and not (LArgs is TJSONObject) then
        FreeAndNil(LArgs);
      if LArgs = nil then
      begin
        Writeln('=== ', LCall.Tool, ' ', LCall.Json, ' === BAD JSON');
        Continue;
      end;
      LSW := TStopwatch.StartNew;
      LText := CallToolNow(GWs, LCall.Tool, TJSONObject(LArgs), LIsError);
      LSW.Stop;
      // UTF-8 straight to the handle: Writeln would go through the console
      // code page, and a redirected run must read like the MCP answer does.
      LOut := TEncoding.UTF8.GetBytes(Format('=== %s %s  (%d ms, ~%d tokens%s)'
        + sLineBreak + '%s' + sLineBreak, [LCall.Tool, LCall.Json,
        LSW.ElapsedMilliseconds, Length(LText) div 4,
        IfThen(LIsError, ', ERROR', ''), LText]));
      WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), LOut[0], Length(LOut),
        LWritten, nil);
    finally
      LArgs.Free;
    end;
  end;
end;

procedure RunServer;
var
  LTransport: TMcpTransport;
  LServer: TMcpServer;
begin
  // The handshake must not wait for a closure-sized analysis.
  TThread.CreateAnonymousThread(
    procedure
    begin
      GWs.Load;
    end).Start;
  LTransport := TMcpTransport.Create;
  LServer := TMcpServer.Create(GWs, LTransport);
  LServer.Run;
  // stdin closed: the client is gone. An analysis still running on the other
  // thread has nobody to answer, so do not wait for it.
  ExitProcess(0);
end;

begin
  // EVERY PasTree host must set this: the analysis fans out across cores, and
  // with the default the memory manager SLEEPS on lock contention.
  System.NeverSleepOnMMThreadContention := True;
  try
    ParseArgs;
    if GLog = '' then
    begin
      if Length(GCalls) = 0 then
        SetLogFile(TPath.Combine(TPath.GetDirectoryName(GProject),
          TPath.GetFileNameWithoutExtension(GProject) + '-pastree-mcp.log'));
    end
    else if not SameText(GLog, 'none') then
      SetLogFile(GLog);
    Log(PasMcpVersionBanner);
    CheckPasTreeVersion;
    Log('project %s', [GProject]);
    GWs := TMcpWorkspace.Create(GProject, GStudio, GPlatform, GConfig, GPolicy,
      GAlso);
    if Length(GCalls) > 0 then
      RunCli
    else
      RunServer;
  except
    on E: Exception do
      Fail(E.ClassName + ': ' + E.Message);
  end;
end.
