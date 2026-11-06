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
  up to the repository root; none: the installed library indexed, and the
  tools for a project's own code refuse), --also <.dproj|.dpr> (repeats: a project outside
  the group indexed and built with it - relative to the project's directory),
  --studio <BDS version>,
  --platform <Win32|Win64>, --config <Debug|Release>, --groups <shared|strict>,
  --build-dir <dir> (where `compile` builds; default %TEMP%\pastree-mcp),
  --light <dir> (repeats: a directory tree whose units are read
  interface-only, besides the installed library), --no-light (every unit in
  full), --log <file|none>, --version.

  - As a Claude Code PreToolUse hook: `pastree-mcp --hook`, alone - reads the
    hook's JSON from stdin, no project, no log (PasMcp.Hook).
}

{$APPTYPE CONSOLE}
// 16 MB per thread, PasTree's pool workers and the executor included - only
// the program can set it (PasTree README, "The stack every host should
// reserve"): a long operator chain in generated code overflows the default.
{$MAXSTACKSIZE $01000000}

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
  PasMcp.Server in 'source\PasMcp.Server.pas',
  PasMcp.Hook in 'source\PasMcp.Hook.pas';

type
  TCall = record
    Tool: string;
    Json: string;
  end;

var
  GProject, GStudio, GPlatform, GConfig, GLog: string;
  // No project found: why (DiscoverProject); GProject is then the server's
  // own program of the installed library.
  GNoProject: string;
  // No --project: the project was looked for from the working directory, and
  // a client root elsewhere may name another (PasMcp.Server's roots). The
  // --platform given, before the no-project default replaced it.
  GDiscovered: Boolean;
  GPlatformGiven: string;
  GAlso: TArray<string>;
  GLight: TArray<string>;
  GNoLight: Boolean;
  GPolicy: TMcpGroupPolicy;
  GCalls: TArray<TCall>;
  GWs: TMcpWorkspace;

procedure Fail(const AMsg: string);
begin
  Log(AMsg);
  ExitProcess(2);
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
  LAlso, LGot: TArray<string>;

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
    else if SameText(ParamStr(LIdx), '--light') then
      GLight := GLight + [Next]
    else if SameText(ParamStr(LIdx), '--no-light') then
      GNoLight := True
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
  GPlatformGiven := GPlatform;
  // Registered once for every repository (`claude mcp add --scope user`), the
  // server starts in whatever directory the client starts it in - often a
  // subdirectory of the project's (DiscoverProject). None found, or none to
  // choose: GNoProject says why, and the server starts without a project
  // rather than exit - an exit before the handshake is "Connection closed" in
  // every repository without a Delphi project, and `compile` with `code`
  // needs none.
  GDiscovered := GProject = '';
  if GDiscovered then
  begin
    GProject := DiscoverProject(GetCurrentDir, GNoProject);
    if (GProject <> '') and not SameText(ExtractFileDir(GProject),
       ExcludeTrailingPathDelimiter(GetCurrentDir)) then
      Log('project %s found above the working directory %s', [GProject,
        GetCurrentDir]);
  end;
  if GProject = '' then
  begin
    GProject := NoProjectProgram(GetCurrentDir);
    // Code tried with no project is built with dcc64 unless --platform: the
    // language reference's claims are checked on it.
    if GPlatform = '' then
      GPlatform := 'Win64';
  end;
  GProject := TPath.GetFullPath(GProject);
  if not TFile.Exists(GProject) then
    Fail('no such project: ' + GProject);
  LAlso := nil;
  for var LOne in GAlso do
  begin
    LGot := ExpandProjectPattern(TPath.GetDirectoryName(GProject), LOne);
    if LGot = nil then
      Fail('no such project (--also): ' + TPath.GetFullPath(TPath.Combine(
        TPath.GetDirectoryName(GProject), LOne)));
    LAlso := LAlso + LGot;
  end;
  GAlso := LAlso;
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

// The session's directory as the client gives it (MCP roots), when the
// project was looked for from the working directory: the workspace of the
// project found from it, when that is another - a session in a git worktree
// inside the repository got a server started in the main checkout, which
// indexed the main checkout's files while the session edited its own (a
// field report) - else nil. ANote: what status says of it.
function WorkspaceForRoot(const ADir: string; out ANote: string): TMcpWorkspace;
var
  LProject, LWhy, LHad: string;
begin
  Result := nil;
  ANote := '';
  LHad := IfThen(GNoProject <> '', 'no project', GProject);
  LProject := DiscoverProject(ADir, LWhy);
  if LProject = '' then
  begin
    if GNoProject = '' then
      ANote := Format('it has no project of its own (%s): the answers are '
        + 'about %s, found from the directory the server was started in', [LWhy,
        GProject]);
    Exit;
  end;
  if SameText(LProject, GProject) then
    Exit;
  ANote := Format('the server was started in %s (%s) and indexes %s, the '
    + 'session''s project, instead', [GetCurrentDir, LHad, LProject]);
  Log('the client''s root %s holds the project %s - indexing it rather than '
    + '%s, found from the working directory %s', [ADir, LProject, LHad,
    GetCurrentDir]);
  Result := TMcpWorkspace.Create(LProject, GStudio, GPlatformGiven, GConfig,
    GPolicy, GAlso);
  Result.SetLight(not GNoLight, GLight);
  Result.SetLaunch(Format('%s, the project found from the client''s root %s',
    [GetCurrentDir, ADir]));
end;

procedure RunServer;
var
  LTransport: TMcpTransport;
  LServer: TMcpServer;
begin
  // The handshake must not wait for a closure-sized analysis: the server
  // starts the load once it knows which project (TMcpServer.Settle).
  LTransport := TMcpTransport.Create;
  LServer := TMcpServer.Create(GWs, LTransport);
  if GDiscovered then
    LServer.RootWorkspace := WorkspaceForRoot;
  LServer.Run;
  // stdin closed: the client is gone. An analysis still running on the other
  // thread has nobody to answer, so do not wait for it.
  ExitProcess(0);
end;

begin
  // EVERY PasTree host must set this: the analysis fans out across cores, and
  // with the default the memory manager SLEEPS on lock contention.
  System.NeverSleepOnMMThreadContention := True;
  // Before anything logs: a hook's stdout and stderr reach the agent.
  if (ParamCount = 1) and SameText(ParamStr(1), '--hook') then
    RunHook;
  try
    ParseArgs;
    if GLog = '' then
    begin
      // No project: in the directory of the working directory's builds,
      // above the library program's (NoProjectProgram).
      if (Length(GCalls) = 0) and (GNoProject <> '') then
        SetLogFile(TPath.Combine(ExtractFileDir(ExtractFileDir(GProject)),
          'pastree-mcp.log'))
      else if Length(GCalls) = 0 then
        SetLogFile(TPath.Combine(TPath.GetDirectoryName(GProject),
          TPath.GetFileNameWithoutExtension(GProject) + '-pastree-mcp.log'));
    end
    else if not SameText(GLog, 'none') then
      SetLogFile(GLog);
    Log(PasMcpVersionBanner);
    CheckPasTreeVersion;
    if GNoProject <> '' then
      Log('no project - %s; indexing the installed library (%s), `compile` '
        + 'with `code` builds without one; --project <file> names one',
        [GNoProject, GProject])
    else
      Log('project %s', [GProject]);
    GWs := TMcpWorkspace.Create(GProject, GStudio, GPlatform, GConfig, GPolicy,
      GAlso);
    Log('working directory %s', [GetCurrentDir]);
    if GNoProject <> '' then
      GWs.SetNoProject(GNoProject);
    GWs.SetLight(not GNoLight, GLight);
    GWs.SetLaunch(GetCurrentDir + IfThen(not GDiscovered, ', the project given '
      + 'by --project', IfThen(GNoProject <> '', ', no project found from it',
      ', the project found from it')));
    if Length(GCalls) > 0 then
      RunCli
    else
      RunServer;
  except
    on E: Exception do
      Fail(E.ClassName + ': ' + E.Message);
  end;
end.
