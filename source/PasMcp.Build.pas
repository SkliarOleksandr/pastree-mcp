unit PasMcp.Build;

{
  `compile` (SPEC 9.4): one member of the group built by the real compiler,
  in a directory of the server's own, and what the compiler said read back.

  How a member is built:

  - A .dproj through MSBuild, with the member's platform and configuration:
    the build the IDE runs, option sets and conditions included - the
    server's own reading of the .dproj is not asked. A bare .dpr/.dpk has no
    MSBuild project, so dcc runs directly with what the IDE would pass it:
    the member's paths, then the registry search path.
  - Target `Make`, never `Build`: `Build` also runs AutoIncBuildNumber, which
    rewrites the .dproj of a project that increments its build number.
  - Every output goes under the member's build directory: exe, dcu, bpl,
    dcp, hpp, obj, resources, the type library. Pre- and post-build events
    are not run - on the client group they rewrite version.rc in the source
    tree and run the new exe to regenerate files of the repository. So a
    check never replaces the binary a developer runs, never fails on one the
    debugger holds, and never writes into the source tree.
  - The first build of a member seeds its dcu directory with the .dcu files
    of the developer's last build, from where MSBuild itself says
    DCC_DcuOutput is (a probe: a target that does nothing, at diagnostic
    verbosity). dcc then recompiles what changed since, as the IDE's Compile
    would. From nothing it would recompile every library unit whose source
    is on the path, and that may not even compile: on the client group a
    DevExpress unit fails under the current compiler, and only the
    developer's old .dcu files make the main member buildable at all.
  - The environment is rsvars.bat's plus the IDE's own environment variables
    (TMcpStudio.IdeVariables): the library path names them, and a
    command-line build without them loses every third-party directory - on
    the client group it stops at the first unit it cannot find.
  - MSBuild's log goes to a UTF-8 file; dcc's own output, for a bare .dpr,
    is read from its pipe. Both are read by ParseLine.
  - The child gets a pipe of its own for output and NUL for input, and the
    server's std handles are made non-inheritable before it starts: stdout
    is the protocol. A job object holds the process tree, so a timeout, a
    cancellation, or the server exiting mid-build leaves no msbuild or dcc
    behind.
  - BuildMember runs on a thread of its own, beside the tool calls, and reads
    nothing but its TBuildSpec: the workspace belongs to the thread that runs
    the tools. MemberBuildSpec, MemberBuildDir and CompareWithBaseline's
    caller run on that one.

  What is new (CompareWithBaseline): with Make, dcc reports a unit's warnings
  only when it recompiles it, so the comparison is per unit. A unit this
  build recompiled (its .dcu was written) has its stored warnings replaced;
  one it did not keeps what it had. A unit no earlier build here compiled
  has nothing to compare with: its warnings count as new only in a file
  changed this session.
}

interface

uses
  System.SysUtils,
  PasMcp.Studio,
  PasMcp.Workspace;

type
  // A build's cancellation: set by the thread that reads the client
  // (notifications/cancelled), polled by the one running the compiler, which
  // then kills the process tree.
  TBuildCancel = class
  private
    FCancelled: Integer;
  public
    procedure Cancel;
    function Cancelled: Boolean;
  end;

  // What a member's build needs, copied from the workspace by the thread
  // that owns it: the build itself runs on another thread and never reads
  // the workspace, whose members a reload replaces.
  TBuildSpec = record
    Index: Integer;       // into TMcpWorkspace.Members when it was taken
    Member: TMcpMember;
    Studio: TMcpStudio;
    Dir: string;          // MemberBuildDir
  end;

  TBuildMsgKind = (
    bmError,         // E and F codes
    bmWarning,       // W codes
    bmHint,          // H codes
    bmSetupError,    // MSBuild's own (MSB...), a resource or type library tool
    bmSetupWarning,
    bmMissingDir);   // H2675: a directory of the search path does not exist

  TBuildMsg = record
    Kind: TBuildMsgKind;
    Code: string;       // E2003, W1036, H2164, MSB4057; '' when there is none
    Text: string;
    FileName: string;   // a full path when it could be made one
    Line: Integer;      // 0 when not known
    Col: Integer;
    // dcc cuts the "file(line)" of a message at 128 characters: FileName is
    // then only the start of the path, and Line is 0.
    Truncated: Boolean;
    // Set by CompareWithBaseline for warnings and hints: not reported by the
    // previous compile of its unit - or, for a unit never compiled here
    // before, in a file changed this session.
    IsNew: Boolean;
    // A unit never compiled here before: nothing to compare with, so its
    // warnings count as new only in a file this session changed - and the
    // answer must say that the rest were not compared.
    Uncompared: Boolean;
  end;

  TBuildResult = record
    Spec: TBuildSpec;
    Ran: Boolean;          // False: nothing was started, Error says why
    Ok: Boolean;           // the compiler exited with 0
    TimedOut: Boolean;
    Cancelled: Boolean;
    Ms: Int64;
    Dir: string;           // the member's build directory
    OutputFile: string;    // the exe, dll or bpl this build wrote
    Lines: string;         // dcc's count: '278 lines'
    Messages: TArray<TBuildMsg>;
    Compiled: TArray<string>;  // lower-case unit names whose .dcu it wrote
    FirstBuild: Boolean;   // nothing built in Dir before
    SeededFrom: string;    // the first build started from the .dcu files here
    SeededCount: Integer;
    NotRun: TArray<string>;    // build events skipped: 'pre-build event: cmd'
    Gone: TArray<TBuildMsg>;   // CompareWithBaseline: no longer reported
    Error: string;
  end;

var
  // Where members are built (--build-dir); '' = %TEMP%\pastree-mcp.
  BuildRoot: string;

// The directory member AMember of AWs is built in.
function MemberBuildDir(AWs: TMcpWorkspace; AMember: Integer): string;

// Member AMember's build spec. On the thread that owns AWs.
function MemberBuildSpec(AWs: TMcpWorkspace; AMember: Integer): TBuildSpec;

// Builds the member of ASpec - on any thread. AProgress, when set, gets a
// status line as the build starts and every few seconds while the compiler
// runs; ACancel, when set and cancelled, stops it.
function BuildMember(const ASpec: TBuildSpec; ARebuild: Boolean;
  const AProgress: TProc<string>; ACancel: TBuildCancel): TBuildResult;

// Marks each warning and hint of AResult new or not against the previous
// compiles of its unit here, lists in AResult.Gone those no longer reported,
// and stores this build's for the next compile (in the build directory).
// Call it once the file names are final. AChangedFiles: this session's edits.
procedure CompareWithBaseline(var AResult: TBuildResult;
  const AChangedFiles: TArray<string>);

implementation

uses
  System.Classes,
  System.IOUtils,
  System.Math,
  System.StrUtils,
  System.Hash,
  System.Diagnostics,
  System.RegularExpressions,
  System.Generics.Collections,
  System.SyncObjs,
  Winapi.Windows,
  PasTree.Platforms,
  PasMcp.Log;

const
  // One member. A full build of a large one takes minutes, a first build of
  // one that cannot be seeded longer; past this the tree is killed.
  BUILD_TIMEOUT_MS = 30 * 60 * 1000;
  PROBE_TIMEOUT_MS = 2 * 60 * 1000;
  PROGRESS_EVERY_MS = 5000;
  OUT_DIRS: array[0..7] of string = ('exe', 'dcu', 'bpl', 'dcp', 'hpp', 'obj',
    'res', 'tlb');
  OUTPUT_DIRS: array[0..1] of string = ('exe', 'bpl');
  STD_HANDLES: array[0..2] of DWORD = (STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    STD_ERROR_HANDLE);
  BASELINE_FILE = 'diagnostics.txt';
  BASELINE_HEADER = '# pastree-mcp compile baseline 1';
  PROBE_FILE = 'probe.txt';

{ ---- TBuildCancel ------------------------------------------------------------- }

procedure TBuildCancel.Cancel;
begin
  TInterlocked.Exchange(FCancelled, 1);
end;

function TBuildCancel.Cancelled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FCancelled, 0, 0) <> 0;
end;

function IsCancelled(ACancel: TBuildCancel): Boolean;
begin
  Result := (ACancel <> nil) and ACancel.Cancelled;
end;

{ ---- the build directory ------------------------------------------------------ }

function SafeName(const AText: string): string;
begin
  Result := AText;
  for var LI := 1 to Length(Result) do
    if CharInSet(Result[LI], ['\', '/', ':', '*', '?', '"', '<', '>', '|',
      ' ']) then
      Result[LI] := '_';
end;

function MemberBuildDir(AWs: TMcpWorkspace; AMember: Integer): string;
var
  LRoot: string;
  LM: TMcpMember;
begin
  LRoot := BuildRoot;
  if LRoot = '' then
    LRoot := TPath.Combine(TPath.GetTempPath, 'pastree-mcp');
  LM := AWs.Members[AMember];
  // The group's name for the reader, a hash of its path for two checkouts of
  // one group.
  Result := TPath.Combine(TPath.Combine(LRoot,
    SafeName(TPath.GetFileNameWithoutExtension(AWs.ProjectFile)) + '-' +
    THashFNV1a32.GetHashString(LowerCase(AWs.ProjectFile))),
    SafeName(LM.Name + '-' + PlatformName(LM.Platform) + IfThen(LM.Config <> '',
    '-' + LM.Config, '')));
end;

function MemberBuildSpec(AWs: TMcpWorkspace; AMember: Integer): TBuildSpec;
begin
  Result.Index := AMember;
  Result.Member := AWs.Members[AMember];
  Result.Studio := AWs.Studio;
  Result.Dir := MemberBuildDir(AWs, AMember);
end;

{ ---- the environment ---------------------------------------------------------- }

function FindVar(AEnv: TStringList; const AName: string): Integer;
begin
  for Result := 0 to AEnv.Count - 1 do
    if SameText(AEnv.Names[Result], AName) then
      Exit;
  Result := -1;
end;

function GetVar(AEnv: TStringList; const AName: string): string;
var
  LIdx: Integer;
begin
  LIdx := FindVar(AEnv, AName);
  if LIdx >= 0 then
    Result := AEnv.ValueFromIndex[LIdx]
  else
    Result := '';
end;

procedure SetVar(AEnv: TStringList; const AName, AValue: string);
var
  LIdx: Integer;
begin
  LIdx := FindVar(AEnv, AName);
  if AValue = '' then
  begin
    if LIdx >= 0 then
      AEnv.Delete(LIdx);
  end
  else if LIdx >= 0 then
    AEnv[LIdx] := AName + '=' + AValue
  else
    AEnv.Add(AName + '=' + AValue);
end;

// %NAME% (rsvars.bat) or $(NAME) (the IDE's variables) -> its value in AEnv,
// '' when unset - as a batch file expands it.
function ExpandVars(AEnv: TStringList; const AText, AOpen,
  AClose: string): string;
var
  LFrom, LTo: Integer;
  LValue: string;
begin
  Result := AText;
  LFrom := Pos(AOpen, Result);
  while LFrom > 0 do
  begin
    LTo := Pos(AClose, Result, LFrom + Length(AOpen));
    if LTo = 0 then
      Break;
    LValue := GetVar(AEnv, Copy(Result, LFrom + Length(AOpen),
      LTo - LFrom - Length(AOpen)));
    Result := Copy(Result, 1, LFrom - 1) + LValue +
      Copy(Result, LTo + Length(AClose), MaxInt);
    LFrom := Pos(AOpen, Result, LFrom + Length(LValue));
  end;
end;

// The process environment, then rsvars.bat's SET lines, then the IDE's own
// variables. AError <> '' when rsvars.bat is missing.
function BuildEnvironment(const AStudio: TMcpStudio;
  out AError: string): TStringList;
var
  LBlock, LP: PChar;
  LLine, LText, LRsvars: string;
  LAt: Integer;
begin
  AError := '';
  Result := TStringList.Create;
  LBlock := GetEnvironmentStrings;
  try
    LP := LBlock;
    while LP^ <> #0 do
    begin
      LLine := LP;
      Inc(LP, Length(LLine) + 1);
      Result.Add(LLine);
    end;
  finally
    FreeEnvironmentStrings(LBlock);
  end;
  LRsvars := TPath.Combine(AStudio.Root, 'bin\rsvars.bat');
  if not TFile.Exists(LRsvars) then
  begin
    AError := 'no rsvars.bat in ' + TPath.Combine(AStudio.Root, 'bin');
    Exit;
  end;
  for LLine in TFile.ReadAllLines(LRsvars) do
  begin
    LText := Trim(LLine);
    if LText.StartsWith('@') then
      LText := Trim(Copy(LText, 2, MaxInt));
    if not StartsText('set ', LText) then
      Continue;
    LText := Trim(Copy(LText, 5, MaxInt));
    LAt := Pos('=', LText);
    if LAt > 1 then
      SetVar(Result, Copy(LText, 1, LAt - 1), ExpandVars(Result,
        Copy(LText, LAt + 1, MaxInt), '%', '%'));
  end;
  for var LPair in AStudio.IdeVariables do
    SetVar(Result, LPair.Key, ExpandVars(Result, LPair.Value, '$(', ')'));
end;

function CompareEnvNames(AList: TStringList; AIndex1, AIndex2: Integer): Integer;
begin
  Result := CompareText(AList.Names[AIndex1], AList.Names[AIndex2]);
end;

// NAME=VALUE#0...#0#0, sorted by name as Windows keeps it.
function EnvironmentBlock(AEnv: TStringList): string;
var
  LSorted: TStringList;
  LSb: TStringBuilder;
begin
  LSorted := TStringList.Create;
  LSb := TStringBuilder.Create;
  try
    LSorted.Assign(AEnv);
    LSorted.CustomSort(CompareEnvNames);
    for var LEntry in LSorted do
      if LEntry <> '' then
        LSb.Append(LEntry).Append(#0);
    LSb.Append(#0);
    Result := LSb.ToString;
  finally
    LSb.Free;
    LSorted.Free;
  end;
end;

{ ---- running a process -------------------------------------------------------- }

type
  TRunOutcome = record
    Started: Boolean;
    Error: string;
    ExitCode: Cardinal;
    TimedOut: Boolean;
    Cancelled: Boolean;
    Output: TBytes;
  end;

// Runs AExe with AArgs in ADir under AEnvBlock, stdout and stderr into one
// pipe, until it exits, ATimeoutMs passes or ACancel is cancelled - the last
// two kill the process tree. ATick gets the elapsed milliseconds every
// PROGRESS_EVERY_MS.
function RunProcess(const AExe, AArgs, ADir, AEnvBlock: string;
  ATimeoutMs: Cardinal; const ATick: TProc<Int64>;
  ACancel: TBuildCancel): TRunOutcome;
var
  LSA: TSecurityAttributes;
  LReadPipe, LWritePipe, LNul, LJob: THandle;
  LSI: TStartupInfo;
  LPI: TProcessInformation;
  LLimit: TJobObjectExtendedLimitInformation;
  LCmd: string;
  LOut: TBytesStream;
  LBuf: TBytes;
  LAvail, LRead: DWORD;
  LSW: TStopwatch;
  LNextTick: Int64;
  LDone: Boolean;

  procedure Drain;
  begin
    while PeekNamedPipe(LReadPipe, nil, 0, nil, @LAvail, nil) and (LAvail > 0)
    do
    begin
      if LAvail > DWORD(Length(LBuf)) then
        LAvail := Length(LBuf);
      if not ReadFile(LReadPipe, LBuf[0], LAvail, LRead, nil) or (LRead = 0) then
        Break;
      LOut.WriteBuffer(LBuf[0], LRead);
    end;
  end;

begin
  Result := Default(TRunOutcome);
  // stdout is the protocol: a child that inherited the server's handles
  // could write into it, and would keep the client's pipe open after the
  // server is gone.
  for var LStd in STD_HANDLES do
    SetHandleInformation(GetStdHandle(LStd), HANDLE_FLAG_INHERIT, 0);
  LSA.nLength := SizeOf(LSA);
  LSA.lpSecurityDescriptor := nil;
  LSA.bInheritHandle := True;
  if not CreatePipe(LReadPipe, LWritePipe, @LSA, 0) then
  begin
    Result.Error := 'cannot create a pipe: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  SetHandleInformation(LReadPipe, HANDLE_FLAG_INHERIT, 0);
  LNul := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
    @LSA, OPEN_EXISTING, 0, 0);
  LJob := CreateJobObject(nil, nil);
  if LJob <> 0 then
  begin
    FillChar(LLimit, SizeOf(LLimit), 0);
    LLimit.BasicLimitInformation.LimitFlags :=
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(LJob, JobObjectExtendedLimitInformation, @LLimit,
      SizeOf(LLimit));
  end;
  LOut := TBytesStream.Create;
  try
    FillChar(LSI, SizeOf(LSI), 0);
    LSI.cb := SizeOf(LSI);
    LSI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    LSI.wShowWindow := SW_HIDE;
    LSI.hStdInput := LNul;
    LSI.hStdOutput := LWritePipe;
    LSI.hStdError := LWritePipe;
    LCmd := '"' + AExe + '" ' + AArgs;
    UniqueString(LCmd);   // CreateProcessW may write into the buffer
    if not CreateProcess(PChar(AExe), PChar(LCmd), nil, nil, True,
      CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED,
      PChar(AEnvBlock), PChar(ADir), LSI, LPI) then
    begin
      Result.Error := 'cannot start ' + AExe + ': ' +
        SysErrorMessage(GetLastError);
      Exit;
    end;
    Result.Started := True;
    // The child has its own copies now; ours would keep the pipe open.
    CloseHandle(LWritePipe);
    LWritePipe := 0;
    if LNul <> INVALID_HANDLE_VALUE then
      CloseHandle(LNul);
    LNul := INVALID_HANDLE_VALUE;
    if (LJob <> 0) and not AssignProcessToJobObject(LJob, LPI.hProcess) then
      Log('compile: the process tree is not in a job (%s) - a timeout kills '
        + 'only its root', [SysErrorMessage(GetLastError)]);
    ResumeThread(LPI.hThread);
    CloseHandle(LPI.hThread);
    SetLength(LBuf, 65536);
    LSW := TStopwatch.StartNew;
    LNextTick := PROGRESS_EVERY_MS;
    LDone := False;
    while not LDone do
    begin
      Drain;
      case WaitForSingleObject(LPI.hProcess, 200) of
        WAIT_OBJECT_0:
          LDone := True;
        WAIT_TIMEOUT:
          begin
            if (LSW.ElapsedMilliseconds >= ATimeoutMs) or IsCancelled(ACancel)
            then
            begin
              Result.TimedOut := not IsCancelled(ACancel);
              Result.Cancelled := IsCancelled(ACancel);
              if LJob <> 0 then
                TerminateJobObject(LJob, 1)
              else
                TerminateProcess(LPI.hProcess, 1);
              WaitForSingleObject(LPI.hProcess, 10000);
              LDone := True;
            end
            else if Assigned(ATick) and (LSW.ElapsedMilliseconds >= LNextTick)
            then
            begin
              ATick(LSW.ElapsedMilliseconds);
              Inc(LNextTick, PROGRESS_EVERY_MS);
            end;
          end;
      else
        LDone := True;
      end;
    end;
    GetExitCodeProcess(LPI.hProcess, Result.ExitCode);
    CloseHandle(LPI.hProcess);
    // Whatever the root left running (a stray node) goes with the job, and
    // then every writer of the pipe is gone: what is in it is all there is.
    if LJob <> 0 then
      TerminateJobObject(LJob, 0);
    Drain;
    Result.Output := Copy(LOut.Bytes, 0, Integer(LOut.Size));
  finally
    LOut.Free;
    if LWritePipe <> 0 then
      CloseHandle(LWritePipe);
    if LNul <> INVALID_HANDLE_VALUE then
      CloseHandle(LNul);
    CloseHandle(LReadPipe);
    if LJob <> 0 then
      CloseHandle(LJob);
  end;
end;

// AArg quoted when it has to be. A trailing backslash is doubled inside the
// quotes, or it would escape the closing one.
function Quoted(const AArg: string): string;
begin
  if (AArg = '') or (AArg.IndexOfAny([' ', #9, '&', '(', ')', '^']) >= 0) then
  begin
    if AArg.EndsWith('\') then
      Result := '"' + AArg + '\"'
    else
      Result := '"' + AArg + '"';
  end
  else
    Result := AArg;
end;

// A dcc switch with a value: -U"a;b", as the DCC task writes them.
function Switch(const ANameOf, AValue: string): string;
begin
  if AValue.IndexOfAny([' ', #9, '&', '(', ')', '^']) >= 0 then
    Result := ANameOf + '"' + AValue + '"'
  else
    Result := ANameOf + AValue;
end;

{ ---- reading what the compiler said -------------------------------------------- }

var
  GCanonical, GRaw, GFileLine, GLines, GTrunc: TRegEx;

procedure InitPatterns;
begin
  // MSBuild's canonical form: `origin(line,col): [subcategory ]error|warning
  // CODE: text [project]` - dcc's messages as the DCC task passes them on,
  // MSBuild's own, a tool's.
  GCanonical := TRegEx.Create('^\s*(?<origin>.*?)(?:\((?<line>\d+)(?:,(?<col>'
    + '\d+))?\))?\s*:\s*(?:(?<sub>[A-Za-z]+)\s+)?(?<cat>error|warning)\s*(?<code>'
    + '[A-Za-z]+\d+)?\s*:\s*(?<text>.*?)(?:\s+\[[^\[\]]*\])?\s*$');
  // dcc's own: `file(line) Error: E2003 text`. No word boundary before the
  // category: a path cut at 128 characters runs straight into it.
  GRaw := TRegEx.Create('^(?<pre>.*?)(?<cat>Error|Warning|Hint|Fatal):\s*(?<code>'
    + '[EWHF]\d{4})\s+(?<text>.*?)\s*$');
  GFileLine := TRegEx.Create('^(?<file>.+)\((?<line>\d+)(?:,(?<col>\d+))?\)$');
  GTrunc := TRegEx.Create('\(\d*$');
  GLines := TRegEx.Create('^\s*(?<lines>[\d,.]+ lines), [\d.,]+ seconds');
end;

function KindOf(const ACat, ACode: string): TBuildMsgKind;
begin
  if SameText(ACode, 'H2675') then
    Result := bmMissingDir
  else if (ACode = '') or StartsText('MSB', ACode) or
    not CharInSet(UpCase(ACode[1]), ['E', 'F', 'W', 'H']) then
  begin
    if SameText(ACat, 'error') then
      Result := bmSetupError
    else
      Result := bmSetupWarning;
  end
  else
    case UpCase(ACode[1]) of
      'E', 'F':
        Result := bmError;
      'W':
        Result := bmWarning;
    else
      Result := bmHint;
    end;
end;

// One line of MSBuild's log or of dcc's output. False when it is neither a
// message nor dcc's line count.
function ParseLine(const ALine: string; out AMsg: TBuildMsg;
  var ALines: string): Boolean;
var
  LM, LF: TMatch;
  LPre: string;
begin
  Result := False;
  AMsg := Default(TBuildMsg);
  LM := GLines.Match(ALine);
  if LM.Success then
  begin
    ALines := LM.Groups['lines'].Value;
    Exit;
  end;
  LM := GCanonical.Match(ALine);
  if LM.Success then
  begin
    AMsg.Code := LM.Groups['code'].Value;
    AMsg.Kind := KindOf(LM.Groups['cat'].Value, AMsg.Code);
    AMsg.Text := LM.Groups['text'].Value;
    AMsg.FileName := Trim(LM.Groups['origin'].Value);
    if LM.Groups['line'].Success then
      AMsg.Line := StrToIntDef(LM.Groups['line'].Value, 0);
    if LM.Groups['col'].Success then
      AMsg.Col := StrToIntDef(LM.Groups['col'].Value, 0);
    Exit(True);
  end;
  LM := GRaw.Match(ALine);
  if not LM.Success then
    Exit;
  AMsg.Code := LM.Groups['code'].Value;
  AMsg.Kind := KindOf(LM.Groups['cat'].Value, AMsg.Code);
  if SameText(LM.Groups['cat'].Value, 'Fatal') then
    AMsg.Kind := bmError;
  AMsg.Text := LM.Groups['text'].Value;
  LPre := Trim(LM.Groups['pre'].Value);
  if LPre <> '' then
  begin
    LF := GFileLine.Match(LPre);
    if LF.Success then
    begin
      AMsg.FileName := LF.Groups['file'].Value;
      AMsg.Line := StrToIntDef(LF.Groups['line'].Value, 0);
      if LF.Groups['col'].Success then
        AMsg.Col := StrToIntDef(LF.Groups['col'].Value, 0);
    end
    else
    begin
      AMsg.FileName := GTrunc.Replace(LPre, '');
      AMsg.Truncated := True;
    end;
  end;
  Result := True;
end;

// Every message of ALines, de-duplicated (MSBuild repeats each one in its
// summary), file names made full against AProjectDir.
procedure ReadMessages(const ALines: TArray<string>; const AProjectDir: string;
  var AResult: TBuildResult);
var
  LMsg: TBuildMsg;
  LSeen: TDictionary<string, Boolean>;
  LKey, LCount: string;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  try
    LCount := '';
    for var LLine in ALines do
    begin
      if not ParseLine(LLine, LMsg, LCount) then
        Continue;
      // A file (not MSBUILD or EXEC, what an origin also is), relative to
      // the directory the compiler ran in.
      if (Pos('.', LMsg.FileName) > 0) and
        not TPath.IsPathRooted(LMsg.FileName) then
      try
        LMsg.FileName := TPath.GetFullPath(TPath.Combine(AProjectDir,
          LMsg.FileName));
      except
        // not a path after all: kept as written
      end;
      LKey := IntToStr(Ord(LMsg.Kind)) + '|' + LMsg.Code + '|' +
        LowerCase(LMsg.FileName) + '|' + IntToStr(LMsg.Line) + '|' +
        IntToStr(LMsg.Col) + '|' + LMsg.Text;
      if LSeen.ContainsKey(LKey) then
        Continue;
      LSeen.Add(LKey, True);
      AResult.Messages := AResult.Messages + [LMsg];
    end;
    AResult.Lines := LCount;
  finally
    LSeen.Free;
  end;
end;

{ ---- .dcu files ----------------------------------------------------------------- }

function DcuStamps(const ADir: string): TDictionary<string, TDateTime>;
var
  LSR: TSearchRec;
begin
  Result := TDictionary<string, TDateTime>.Create;
  if FindFirst(TPath.Combine(ADir, '*.dcu'), faAnyFile, LSR) = 0 then
  try
    repeat
      Result.AddOrSetValue(LowerCase(ChangeFileExt(LSR.Name, '')),
        LSR.TimeStamp);
    until FindNext(LSR) <> 0;
  finally
    System.SysUtils.FindClose(LSR);   // not Winapi.Windows' handle one
  end;
end;

{ ---- the probe: what MSBuild evaluates the .dproj to --------------------------- }

type
  TProbe = record
    DcuOutput: string;
    PreBuildEvent: string;
    PostBuildEvent: string;
  end;

function StampText(const APath: string): string;
var
  LStamp: TMcpFileStamp;
begin
  if StampOf(APath, LStamp) then
    Result := FloatToStr(LStamp.Time, TFormatSettings.Invariant) + '|' +
      IntToStr(LStamp.Size)
  else
    Result := '';
end;

function FirstLine(const AText: string): string;
begin
  Result := Trim(AText);
  if Pos(#10, Result) > 0 then
    Result := Trim(Copy(Result, 1, Pos(#10, Result) - 1)) + ' ...';
  if Length(Result) > 100 then
    Result := Copy(Result, 1, 97) + '...';
end;

// The probe of the member's .dproj, from PROBE_FILE while the .dproj is
// unchanged, else by running MSBuild on a target that does nothing
// (SetMakeOptions only sets a property) at diagnostic verbosity, which logs
// every property as evaluated.
function Probe(const ADproj, AMsbuild, AArgsTail, ADir, AEnvBlock: string;
  ACancel: TBuildCancel; out AProbe: TProbe): Boolean;
var
  LFile, LLog, LStamp, LName, LValue: string;
  LLines: TArray<string>;
  LRun: TRunOutcome;
  LIn: Boolean;
  LAt: Integer;
  LCache: TStringList;
begin
  AProbe := Default(TProbe);
  LFile := TPath.Combine(ADir, PROBE_FILE);
  // The format's version first: a cache another version wrote is re-probed.
  LStamp := '2|' + StampText(ADproj);
  if TFile.Exists(LFile) then
  begin
    LLines := TFile.ReadAllLines(LFile, TEncoding.UTF8);
    if (Length(LLines) >= 5) and (LLines[0] = LStamp) and (LLines[4] = 'end')
    then
    begin
      AProbe.DcuOutput := LLines[1];
      AProbe.PreBuildEvent := LLines[2];
      AProbe.PostBuildEvent := LLines[3];
      Exit(True);
    end;
  end;
  LLog := TPath.Combine(ADir, 'probe.log');
  LRun := RunProcess(AMsbuild, Quoted(ADproj) + ' /t:SetMakeOptions' + AArgsTail
    + ' /nologo /nodeReuse:false /noconsolelogger ' + Quoted('/flp:logfile=' +
    LLog + ';verbosity=diagnostic;encoding=utf-8'), TPath.GetDirectoryName(ADproj),
    AEnvBlock, PROBE_TIMEOUT_MS, nil, ACancel);
  if not LRun.Started or LRun.Cancelled or (LRun.ExitCode <> 0) or
    not TFile.Exists(LLog) then
    Exit(False);
  // `Name = value` from column 1, sorted by name, up to the next section
  // (`Initial Items:`). A value may run over several lines, blank ones
  // included - BuildDependsOn's does, before any DCC_ property.
  LIn := False;
  for var LLine in TFile.ReadAllLines(LLog, TEncoding.UTF8) do
  begin
    if not LIn then
    begin
      LIn := Trim(LLine) = 'Initial Properties:';
      Continue;
    end;
    if StartsText('Initial ', LLine) and EndsText(':', TrimRight(LLine)) then
      Break;
    LAt := Pos(' = ', LLine);
    if (LAt <= 1) or (LLine[1] = ' ') or (LLine[1] = #9) then
      Continue;
    LName := Trim(Copy(LLine, 1, LAt - 1));
    LValue := Copy(LLine, LAt + 3, MaxInt);
    if SameText(LName, 'DCC_DcuOutput') then
      AProbe.DcuOutput := Trim(LValue)
    else if SameText(LName, 'PreBuildEvent') then
      AProbe.PreBuildEvent := FirstLine(LValue)
    else if SameText(LName, 'PostBuildEvent') then
      AProbe.PostBuildEvent := FirstLine(LValue);
  end;
  LCache := TStringList.Create;
  try
    LCache.Add(LStamp);
    LCache.Add(AProbe.DcuOutput);
    LCache.Add(AProbe.PreBuildEvent);
    LCache.Add(AProbe.PostBuildEvent);
    LCache.Add('end');
    LCache.WriteBOM := False;
    LCache.SaveToFile(LFile, TEncoding.UTF8);
  finally
    LCache.Free;
  end;
  TFile.Delete(LLog);
  Result := True;
end;

// Copies the .dcu files of ASource into ADcuDir; CopyFile keeps their times,
// and dcc then recompiles exactly what is newer than them.
function SeedDcus(const ASource, ADcuDir: string): Integer;
begin
  Result := 0;
  for var LFile in TDirectory.GetFiles(ASource, '*.dcu') do
  begin
    if CopyFile(PChar(LFile), PChar(TPath.Combine(ADcuDir,
      TPath.GetFileName(LFile))), False) then
      Inc(Result);
  end;
end;

{ ---- building ------------------------------------------------------------------- }

// The exe, dll or bpl written since ASince, the newest of them.
function NewestOutput(const ADir: string; ASince: TDateTime): string;
var
  LBest, LTime: TDateTime;
begin
  Result := '';
  LBest := ASince - 2 / SecsPerDay;   // file times are coarser than Now
  for var LSub in OUTPUT_DIRS do
  begin
    if not TDirectory.Exists(TPath.Combine(ADir, LSub)) then
      Continue;
    for var LFile in TDirectory.GetFiles(TPath.Combine(ADir, LSub)) do
      if MatchText(TPath.GetExtension(LFile), ['.exe', '.dll', '.bpl']) then
      begin
        LTime := TFile.GetLastWriteTime(LFile);
        if LTime >= LBest then
        begin
          LBest := LTime;
          Result := LFile;
        end;
      end;
  end;
end;

function DecodeOem(const ABytes: TBytes): string;
var
  LEnc: TEncoding;
begin
  LEnc := TEncoding.GetEncoding(GetOEMCP);
  try
    Result := LEnc.GetString(ABytes);
  finally
    LEnc.Free;
  end;
end;

function BuildMember(const ASpec: TBuildSpec; ARebuild: Boolean;
  const AProgress: TProc<string>; ACancel: TBuildCancel): TBuildResult;
var
  LM: TMcpMember;
  LEnv: TStringList;
  LEnvBlock, LError, LProjectDir, LExe, LArgs, LTail, LLog, LDevDcu, LDcuDir,
    LPaths, LName, LDir, LOutText: string;
  LIsDproj, LOwned: Boolean;
  LProbe: TProbe;
  LBefore, LAfter: TDictionary<string, TDateTime>;
  LOld: TDateTime;
  LRun: TRunOutcome;
  LSW: TStopwatch;
  LLines: TArray<string>;
  LStart: TDateTime;
  LTick: TProc<Int64>;
  LProgress: TProc<string>;
  LSaved: TStringList;
  LMutex: THandle;
  LWaits: Integer;

  function Sub(const AName: string): string;
  begin
    Result := TPath.Combine(LDir, AName);
  end;

begin
  Result := Default(TBuildResult);
  Result.Spec := ASpec;
  LM := ASpec.Member;
  LName := LM.Name;
  LDir := ASpec.Dir;
  Result.Dir := LDir;
  if LM.Error <> '' then
  begin
    Result.Error := LM.Error;
    Exit;
  end;
  if not ASpec.Studio.Found then
  begin
    Result.Error := 'no RAD Studio installation is registered';
    Exit;
  end;
  LIsDproj := SameText(TPath.GetExtension(LM.ProjectFile), '.dproj');
  if not LIsDproj and not (LM.Platform in [pfWin32, pfWin64]) then
  begin
    Result.Error := 'a project with no .dproj is built for Win32 or Win64 only';
    Exit;
  end;
  LProjectDir := TPath.GetDirectoryName(LM.ProjectFile);
  LDcuDir := Sub('dcu');
  // Two builds of one member write the same .dcu files: one at a time -
  // two sessions on one group, or two calls of one session, now that a
  // build runs beside the calls.
  LOwned := False;
  LMutex := CreateMutex(nil, False, PChar('Local\pastree-mcp-build-' +
    THashFNV1a32.GetHashString(LowerCase(LDir))));
  if LMutex <> 0 then
  begin
    LWaits := 0;
    repeat
      case WaitForSingleObject(LMutex, 1000) of
        WAIT_OBJECT_0, WAIT_ABANDONED:
          LOwned := True;
        WAIT_TIMEOUT:
          begin
            Inc(LWaits);
            if Assigned(AProgress) and (LWaits mod (PROGRESS_EVERY_MS div 1000)
              = 1) then
              AProgress('waiting for another compile of ' + LName + ' to end');
          end;
      else
        Break;   // not a mutex we can wait on: build unguarded
      end;
    until LOwned or IsCancelled(ACancel);
    if not LOwned and IsCancelled(ACancel) then
    begin
      CloseHandle(LMutex);
      Result.Cancelled := True;
      Result.Error := 'cancelled';
      Exit;
    end;
  end;
  LEnv := nil;
  try
    try
      for var LOne in OUT_DIRS do
        TDirectory.CreateDirectory(Sub(LOne));
      if ARebuild then
        for var LFile in TDirectory.GetFiles(LDcuDir, '*.dcu') do
          TFile.Delete(LFile);
    except
      on E: Exception do
      begin
        Result.Error := 'cannot prepare the build directory ' + LDir + ': ' +
          E.Message;
        Exit;
      end;
    end;
    Result.FirstBuild := not TFile.Exists(Sub(BASELINE_FILE));
    LEnv := BuildEnvironment(ASpec.Studio, LError);
    if LError <> '' then
    begin
      Result.Error := LError;
      Exit;
    end;
    LEnvBlock := EnvironmentBlock(LEnv);
    LLog := '';
    if LIsDproj then
    begin
      LExe := TPath.Combine(GetVar(LEnv, 'FrameworkDir'), 'MSBuild.exe');
      if not TFile.Exists(LExe) then
      begin
        Result.Error := 'no MSBuild.exe in the FrameworkDir rsvars.bat sets: '
          + LExe;
        Exit;
      end;
      LTail := ' /p:Platform=' + PlatformName(LM.Platform);
      if LM.Config <> '' then
        LTail := LTail + ' ' + Quoted('/p:Config=' + LM.Config);
      // The developer's own build as MSBuild evaluates the .dproj: where its
      // .dcu files are, and the events this build does not run.
      if Probe(LM.ProjectFile, LExe, LTail, LDir, LEnvBlock, ACancel, LProbe)
      then
      begin
        if LProbe.PreBuildEvent <> '' then
          Result.NotRun := Result.NotRun + ['pre-build event: ' +
            LProbe.PreBuildEvent];
        if LProbe.PostBuildEvent <> '' then
          Result.NotRun := Result.NotRun + ['post-build event: ' +
            LProbe.PostBuildEvent];
        if not ARebuild and (LProbe.DcuOutput <> '') and
          (Length(TDirectory.GetFiles(LDcuDir, '*.dcu')) = 0) then
        begin
          LDevDcu := ExcludeTrailingPathDelimiter(TPath.GetFullPath(
            TPath.Combine(LProjectDir, LProbe.DcuOutput)));
          if TDirectory.Exists(LDevDcu) and not SameText(LDevDcu, LDcuDir) then
          begin
            if Assigned(AProgress) then
              AProgress('copying the .dcu files of ' + LDevDcu);
            Result.SeededCount := SeedDcus(LDevDcu, LDcuDir);
            if Result.SeededCount > 0 then
              Result.SeededFrom := LDevDcu;
          end;
        end;
      end
      else
        Log('compile %s: the probe of %s failed - no .dcu files to start from',
          [LName, LM.ProjectFile]);
      LLog := Sub('build.log');
      if TFile.Exists(LLog) then
        TFile.Delete(LLog);
      LArgs := Quoted(LM.ProjectFile) + ' /t:Make' + LTail
        + ' ' + Quoted('/p:DCC_ExeOutput=' + Sub('exe'))
        + ' ' + Quoted('/p:DCC_DcuOutput=' + LDcuDir)
        + ' ' + Quoted('/p:DCC_BplOutput=' + Sub('bpl'))
        + ' ' + Quoted('/p:DCC_DcpOutput=' + Sub('dcp'))
        + ' ' + Quoted('/p:DCC_BpiOutput=' + Sub('dcp'))
        + ' ' + Quoted('/p:DCC_HppOutput=' + Sub('hpp'))
        + ' ' + Quoted('/p:DCC_ObjOutput=' + Sub('obj'))
        + ' ' + Quoted('/p:DCC_ResourceOutput=' + Sub('res'))
        // The targets append a file name to these two before any backslash
        // is added: `resAppA.res` without one.
        + ' ' + Quoted('/p:BRCC_OutputDir=' + Sub('res') + '\')
        + ' ' + Quoted('/p:GENTLB_OutputDir=' + Sub('tlb') + '\')
        + ' /p:PreBuildEvent= /p:PostBuildEvent='
        + ' /p:DCC_OutputXMLDocumentation=false'
        + ' /nologo /nodeReuse:false /noconsolelogger '
        + Quoted('/flp:logfile=' + LLog + ';verbosity=normal;encoding=utf-8');
    end
    else
    begin
      LExe := TPath.Combine(ASpec.Studio.Root, 'bin\' + IfThen(LM.Platform =
        pfWin64, 'dcc64.exe', 'dcc32.exe'));
      LPaths := String.Join(';', LM.SearchPaths +
        ASpec.Studio.SearchPath(LM.Platform));
      LArgs := '-Q ' + Switch('-N0', LDcuDir) + ' ' + Switch('-E', Sub('exe'))
        + ' ' + Switch('-LE', Sub('bpl')) + ' ' + Switch('-LN', Sub('dcp'))
        + ' ' + Switch('-NH', Sub('hpp')) + ' ' + Switch('-NO', Sub('obj'));
      if Length(LM.Namespaces) > 0 then
        LArgs := LArgs + ' ' + Switch('-NS', String.Join(';', LM.Namespaces));
      if Length(LM.Defines) > 0 then
        LArgs := LArgs + ' ' + Switch('-D', String.Join(';', LM.Defines));
      if LPaths <> '' then
        LArgs := LArgs + ' ' + Switch('-U', LPaths) + ' ' + Switch('-I', LPaths)
          + ' ' + Switch('-R', LPaths);
      LArgs := LArgs + ' ' + Quoted(LM.MainSource);
    end;
    LBefore := DcuStamps(LDcuDir);
    try
      LProgress := AProgress;
      if Assigned(LProgress) then
      begin
        LProgress(Format('building %s (%s%s)', [LName,
          PlatformName(LM.Platform), IfThen(LM.Config <> '', ' ' + LM.Config,
          '')]));
        LTick :=
          procedure(AMs: Int64)
          begin
            LProgress(Format('building %s: %d s', [LName, AMs div 1000]));
          end;
      end
      else
        LTick := nil;
      LStart := Now;
      LSW := TStopwatch.StartNew;
      LRun := RunProcess(LExe, LArgs, LProjectDir, LEnvBlock, BUILD_TIMEOUT_MS,
        LTick, ACancel);
      Result.Ms := LSW.ElapsedMilliseconds;
      if not LRun.Started then
      begin
        Result.Error := LRun.Error;
        Exit;
      end;
      Result.Ran := True;
      Result.TimedOut := LRun.TimedOut;
      Result.Cancelled := LRun.Cancelled;
      if LRun.Cancelled then
      begin
        Result.Error := 'cancelled';
        Exit;
      end;
      Result.Ok := not LRun.TimedOut and (LRun.ExitCode = 0);
      LOutText := DecodeOem(LRun.Output);
      if LLog <> '' then
      begin
        // The log is UTF-8. What MSBuild says about its own command line
        // goes to stdout, not to the log.
        if TFile.Exists(LLog) then
          LLines := TFile.ReadAllLines(LLog, TEncoding.UTF8)
        else
          LLines := nil;
        LLines := LLines + LOutText.Split([#13#10, #10]);
      end
      else
      begin
        LLines := LOutText.Split([#13#10, #10]);
        // Kept for whoever investigates, like MSBuild's log.
        LSaved := TStringList.Create;
        try
          LSaved.Text := LOutText;
          LSaved.WriteBOM := False;
          LSaved.SaveToFile(Sub('build.log'), TEncoding.UTF8);
        finally
          LSaved.Free;
        end;
      end;
      ReadMessages(LLines, LProjectDir, Result);
      LAfter := DcuStamps(LDcuDir);
      try
        for var LPair in LAfter do
          if not LBefore.TryGetValue(LPair.Key, LOld) or (LOld <> LPair.Value)
          then
            Result.Compiled := Result.Compiled + [LPair.Key];
      finally
        LAfter.Free;
      end;
      Result.OutputFile := NewestOutput(LDir, LStart);
    finally
      LBefore.Free;
    end;
  finally
    LEnv.Free;
    if LOwned then
      ReleaseMutex(LMutex);
    if LMutex <> 0 then
      CloseHandle(LMutex);
    Log('compile %s: %s in %d ms, %d messages, %d units compiled%s%s', [LName,
      IfThen(Result.Cancelled, 'cancelled', IfThen(Result.Ok, 'built',
      IfThen(Result.Ran, 'failed', 'not started: ' + Result.Error))),
      Result.Ms, Length(Result.Messages), Length(Result.Compiled),
      IfThen(Result.SeededFrom <> '', Format(', seeded with %d .dcu files',
      [Result.SeededCount]), ''), IfThen(Result.TimedOut, ', TIMED OUT', '')]);
  end;
end;

{ ---- what is new ------------------------------------------------------------------ }

type
  TBaseEntry = record
    Kind: Char;          // W or H
    FileName: string;
    Line: Integer;       // where it was last reported
    Code: string;
    LineText: string;    // the source line, whitespace collapsed
    Text: string;
  end;

function EntryKey(const AE: TBaseEntry): string;
begin
  Result := AE.Kind + #9 + AE.Code + #9 + AE.Text + #9 + AE.LineText;
end;

// The source line, whitespace collapsed: it identifies a warning when lines
// above it moved. A tab would break the baseline's columns.
function SourceLineText(ACache: TDictionary<string, TArray<string>>;
  const AFile: string; ALine: Integer): string;
var
  LLines: TArray<string>;
begin
  Result := '';
  if (AFile = '') or (ALine <= 0) then
    Exit;
  if not ACache.TryGetValue(LowerCase(AFile), LLines) then
  begin
    try
      LLines := TFile.ReadAllLines(AFile);   // BOM-aware
    except
      LLines := nil;
    end;
    ACache.Add(LowerCase(AFile), LLines);
  end;
  if ALine <= Length(LLines) then
    Result := String.Join(' ', Trim(LLines[ALine - 1]).Split([' ', #9],
      TStringSplitOptions.ExcludeEmpty));
end;

function UnitKey(const AFile: string): string;
begin
  Result := LowerCase(TPath.GetFileNameWithoutExtension(AFile));
end;

function IsUnitSource(const AFile: string): Boolean;
begin
  Result := MatchText(TPath.GetExtension(AFile), ['.pas', '.pp']);
end;

function IsProgramSource(const AFile: string): Boolean;
begin
  Result := MatchText(TPath.GetExtension(AFile), ['.dpr', '.dpk']);
end;

procedure CompareWithBaseline(var AResult: TBuildResult;
  const AChangedFiles: TArray<string>);
var
  LPath, LKey, LF: string;
  LParts: TArray<string>;
  LKnown, LChanged, LErrFiles, LCompiled: TDictionary<string, Boolean>;
  LStored, LNow: TObjectDictionary<string, TList<TBaseEntry>>;
  LCounts: TObjectDictionary<string, TDictionary<string, Integer>>;
  LCache: TDictionary<string, TArray<string>>;
  LList: TList<TBaseEntry>;
  LE: TBaseEntry;
  LN: Integer;
  LOut: TStringList;
  LGone: TBuildMsg;

  function CountsOf(const AFileKey: string): TDictionary<string, Integer>;
  var
    LC: Integer;
    LEntries: TList<TBaseEntry>;
  begin
    if LCounts.TryGetValue(AFileKey, Result) then
      Exit;
    Result := TDictionary<string, Integer>.Create;
    LCounts.Add(AFileKey, Result);
    if LStored.TryGetValue(AFileKey, LEntries) then
      for var LOne in LEntries do
      begin
        if not Result.TryGetValue(EntryKey(LOne), LC) then
          LC := 0;
        Result.AddOrSetValue(EntryKey(LOne), LC + 1);
      end;
  end;

  // Was the file's unit compiled by an earlier build here - is there
  // something to compare with? An include file: when it has stored entries.
  function Known(const AFileKey: string): Boolean;
  begin
    if IsUnitSource(AFileKey) or IsProgramSource(AFileKey) then
      Result := LKnown.ContainsKey(UnitKey(AFileKey))
    else
      Result := LStored.ContainsKey(AFileKey);
  end;

  // Did this build compile the file to the end: its .dcu written, or, for
  // the program, the build succeeded; anything it reported from.
  function CompiledNow(const AFileKey: string): Boolean;
  begin
    Result := LNow.ContainsKey(AFileKey) or
      (IsUnitSource(AFileKey) and LCompiled.ContainsKey(UnitKey(AFileKey))) or
      (IsProgramSource(AFileKey) and AResult.Ok);
  end;

  procedure AddEntry(ADict: TObjectDictionary<string, TList<TBaseEntry>>;
    const AEntry: TBaseEntry);
  var
    LTarget: TList<TBaseEntry>;
  begin
    if not ADict.TryGetValue(LowerCase(AEntry.FileName), LTarget) then
    begin
      LTarget := TList<TBaseEntry>.Create;
      ADict.Add(LowerCase(AEntry.FileName), LTarget);
    end;
    LTarget.Add(AEntry);
  end;

  procedure WriteEntries(AEntries: TList<TBaseEntry>);
  begin
    for var LOne in AEntries do
      LOut.Add(LOne.Kind + #9 + LOne.FileName + #9 + IntToStr(LOne.Line) + #9 +
        LOne.Code + #9 + LOne.LineText + #9 + LOne.Text);
  end;

begin
  AResult.Gone := nil;
  LPath := TPath.Combine(AResult.Dir, BASELINE_FILE);
  LKnown := TDictionary<string, Boolean>.Create;
  LChanged := TDictionary<string, Boolean>.Create;
  LErrFiles := TDictionary<string, Boolean>.Create;
  LCompiled := TDictionary<string, Boolean>.Create;
  LStored := TObjectDictionary<string, TList<TBaseEntry>>.Create([doOwnsValues]);
  LNow := TObjectDictionary<string, TList<TBaseEntry>>.Create([doOwnsValues]);
  LCounts := TObjectDictionary<string, TDictionary<string, Integer>>.Create(
    [doOwnsValues]);
  LCache := TDictionary<string, TArray<string>>.Create;
  LOut := TStringList.Create;
  try
    if TFile.Exists(LPath) then
    try
      for var LLine in TFile.ReadAllLines(LPath, TEncoding.UTF8) do
      begin
        LParts := LLine.Split([#9]);
        if (Length(LParts) = 2) and (LParts[0] = 'U') then
          LKnown.AddOrSetValue(LParts[1], True)
        else if (Length(LParts) >= 6) and ((LParts[0] = 'W') or
          (LParts[0] = 'H')) then
        begin
          LE := Default(TBaseEntry);
          LE.Kind := LParts[0][1];
          LE.FileName := LParts[1];
          LE.Line := StrToIntDef(LParts[2], 0);
          LE.Code := LParts[3];
          LE.LineText := LParts[4];
          LE.Text := String.Join(#9, Copy(LParts, 5, MaxInt));
          AddEntry(LStored, LE);
        end;
      end;
    except
      on E: Exception do
      begin
        // A baseline that cannot be read is no baseline: every unit is
        // compared as never compiled here.
        Log('compile: cannot read %s: %s', [LPath, E.Message]);
        LKnown.Clear;
        LStored.Clear;
      end;
    end;
    for var LOne in AChangedFiles do
      LChanged.AddOrSetValue(LowerCase(LOne), True);
    for var LOne in AResult.Compiled do
      LCompiled.AddOrSetValue(LOne, True);

    // This build's warnings and hints, keyed like the stored ones.
    for var LI := 0 to High(AResult.Messages) do
      case AResult.Messages[LI].Kind of
        bmWarning, bmHint:
          begin
            LE := Default(TBaseEntry);
            if AResult.Messages[LI].Kind = bmWarning then
              LE.Kind := 'W'
            else
              LE.Kind := 'H';
            LE.FileName := AResult.Messages[LI].FileName;
            LE.Line := AResult.Messages[LI].Line;
            LE.Code := AResult.Messages[LI].Code;
            LE.LineText := SourceLineText(LCache, LE.FileName, LE.Line);
            LE.Text := AResult.Messages[LI].Text.Replace(#9, ' ');
            AddEntry(LNow, LE);
            LF := LowerCase(LE.FileName);
            if Known(LF) then
            begin
              LKey := EntryKey(LE);
              if CountsOf(LF).TryGetValue(LKey, LN) and (LN > 0) then
              begin
                CountsOf(LF)[LKey] := LN - 1;
                AResult.Messages[LI].IsNew := False;
              end
              else
                AResult.Messages[LI].IsNew := True;
            end
            else
            begin
              // Nothing to compare with: new only where this session edited.
              AResult.Messages[LI].IsNew := LChanged.ContainsKey(LF);
              AResult.Messages[LI].Uncompared := True;
            end;
          end;
        bmError:
          begin
            LErrFiles.AddOrSetValue(LowerCase(AResult.Messages[LI].FileName),
              True);
            AResult.Messages[LI].IsNew := True;
          end;
      else
        AResult.Messages[LI].IsNew := True;
      end;

    // What the stored builds reported and this one, having compiled the
    // unit again, did not. A unit that failed did not get to the end.
    for var LPair in LStored do
    begin
      if LErrFiles.ContainsKey(LPair.Key) or not CompiledNow(LPair.Key) then
        Continue;
      for var LOne in LPair.Value do
      begin
        LKey := EntryKey(LOne);
        if CountsOf(LPair.Key).TryGetValue(LKey, LN) and (LN > 0) then
        begin
          CountsOf(LPair.Key)[LKey] := LN - 1;
          LGone := Default(TBuildMsg);
          if LOne.Kind = 'W' then
            LGone.Kind := bmWarning
          else
            LGone.Kind := bmHint;
          LGone.FileName := LOne.FileName;
          LGone.Line := LOne.Line;
          LGone.Code := LOne.Code;
          LGone.Text := LOne.Text;
          AResult.Gone := AResult.Gone + [LGone];
        end;
      end;
    end;

    // The baseline for the next compile.
    for var LOne in AResult.Compiled do
      LKnown.AddOrSetValue(LOne, True);
    if AResult.Ok then
      for var LOne in LNow.Keys do
        if IsProgramSource(LOne) then
          LKnown.AddOrSetValue(UnitKey(LOne), True);
    LOut.Add(BASELINE_HEADER);
    for var LOne in LKnown.Keys do
      LOut.Add('U' + #9 + LOne);
    for var LPair in LStored do
      if LErrFiles.ContainsKey(LPair.Key) or not CompiledNow(LPair.Key) then
        WriteEntries(LPair.Value);
    for var LPair in LNow do
      if not (LErrFiles.ContainsKey(LPair.Key) and
        LStored.TryGetValue(LPair.Key, LList)) then
        WriteEntries(LPair.Value);
    try
      LOut.WriteBOM := False;
      LOut.SaveToFile(LPath, TEncoding.UTF8);
    except
      on E: Exception do
        Log('compile: cannot write %s: %s', [LPath, E.Message]);
    end;
  finally
    LOut.Free;
    LCache.Free;
    LCounts.Free;
    LNow.Free;
    LStored.Free;
    LCompiled.Free;
    LErrFiles.Free;
    LChanged.Free;
    LKnown.Free;
  end;
end;

initialization
  InitPatterns;

end.
