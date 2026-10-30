unit PasMcp.Hook;

{
  `pastree-mcp --hook`: a Claude Code PreToolUse hook that points an agent
  searching Object Pascal sources by text at the index (README, "The grep
  hook"; SPEC 8.2).

  Why: agents with the server configured often never call it. In the
  scaled-up task comparison (SPEC 10.4) the arm with the tools and no word
  about them called pastree in 5 of 12 runs, and its one wrong answer was a
  run that searched by text instead; the arm told to use the index called it
  in all 12. Serena hit the same and answers with a hook of this kind.

  What it does, per tool call Claude Code hands it on stdin:
  - a call of a pastree tool is remembered (the agent knows the tools);
  - a text search for a name - Grep, or grep/rg/findstr/Select-String in a
    Bash or PowerShell command - over Pascal sources, or `sed -n A,Bp` of a
    Pascal file, is denied with a note naming the call that answers it,
    unless a pastree tool was called in the last 5 minutes or a note was
    given in the last 10. The same command run again then goes through: a
    search for a comment, a string or a name built at run time is the
    agent's to make, and the note is a hint, never a wall.
  - everything else passes without a word (exit 0, nothing written).

  Denied, not passed with the note as `additionalContext` beside the
  result: an agent holding the grep's answer has no reason left to ask
  again, and the runs that skipped the index were the ones sure of a text
  search. The deny costs a turn once per 10 minutes at most.

  A name is an identifier of three letters or more with both cases in it
  (TFoo, SaveToFile, Create) - `TODO`, `error` and English words are not
  pointed anywhere. A Grep with no glob, type or file is over Pascal sources:
  the session's directory is a Delphi project's - a `.groupproj` or `.dproj`
  there or above it, up to the repository root - or the hook says nothing.
  A command is over them when it names a Pascal file or extension, or
  searches recursively (rg, -r) without an include of another kind.

  State per session is one small file under %TEMP%\pastree-mcp\hook. This
  mode reads no project and writes no log: stderr and stdout are the hook
  protocol's, and anything there reaches the agent.
}

interface

// Answers the hook call on stdin and ends the process.
procedure RunHook;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.StrUtils,
  System.DateUtils,
  System.Character,
  System.RegularExpressions,
  Winapi.Windows;

const
  cNoteEverySeconds = 10 * 60;
  cKnowsToolsSeconds = 5 * 60;
  cPascalExts: array[0..5] of string = ('.pas', '.dpr', '.dpk', '.inc',
    '.dfm', '.fmx');
  cKeywords: array[0..23] of string = ('procedure', 'function', 'constructor',
    'destructor', 'class', 'property', 'type', 'var', 'const', 'begin', 'end',
    'inherited', 'record', 'interface', 'implementation', 'uses', 'unit',
    'override', 'virtual', 'string', 'Integer', 'Boolean', 'Result', 'Self');

type
  TFinding = record
    Name: string;      // the name searched for, '' for a line read
    FileName: string;  // a line read: the file
    Lines: string;     // a line read: `A-B`
  end;

function ReadStdin: string;
var
  LIn: THandle;
  LBuf: TBytes;
  LAll: TBytesStream;
  LRead: DWORD;
begin
  LIn := GetStdHandle(STD_INPUT_HANDLE);
  SetLength(LBuf, 65536);
  LAll := TBytesStream.Create;
  try
    while ReadFile(LIn, LBuf[0], Length(LBuf), LRead, nil) and (LRead > 0) do
      LAll.WriteBuffer(LBuf[0], LRead);
    Result := TEncoding.UTF8.GetString(LAll.Bytes, 0, LAll.Size);
  finally
    LAll.Free;
  end;
  if Result.StartsWith(#$FEFF) then
    Delete(Result, 1, 1);
end;

procedure WriteStdout(const AText: string);
var
  LOut: TBytes;
  LWritten: DWORD;
begin
  LOut := TEncoding.UTF8.GetBytes(AText);
  if Length(LOut) > 0 then
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), LOut[0], Length(LOut),
      LWritten, nil);
end;

function Str(AObj: TJSONObject; const AName: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.GetValue(AName);
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

function IsPascalFile(const APath: string): Boolean;
begin
  Result := MatchText(ExtractFileExt(APath), cPascalExts);
end;

// A glob, a type or a whole command naming a Pascal extension: `*.pas`,
// `*.{pas,inc}`, `-t pascal` - not `pastree` or `--include`.
function NamesPascal(const AText: string): Boolean;
begin
  Result := TRegEx.IsMatch(AText,
    '(?i)[.{,](pas|dpr|dpk|inc|dfm|fmx)\b|\bpascal\b');
end;

function LooksLikeName(const AToken: string): Boolean;
var
  LUpper, LLower: Boolean;
begin
  if (Length(AToken) < 3) or not (AToken[1].IsLetter or (AToken[1] = '_')) or
     MatchText(AToken, cKeywords) then
    Exit(False);
  LUpper := False;
  LLower := False;
  for var LC in AToken do
  begin
    if not (LC.IsLetterOrDigit or (LC = '_')) then
      Exit(False);
    LUpper := LUpper or LC.IsUpper;
    LLower := LLower or LC.IsLower;
  end;
  Result := LUpper and LLower;
end;

// The name a search pattern looks for, or '' when it is not a search for a
// name: a regex of identifiers, dots, word boundaries, alternation and the
// keywords before a declaration (`procedure\s+TFoo\.Bar`, `\bSave\b`,
// `Load|Save`). Anything else - a quote, a bracket, a quantifier - is a
// search for text.
function NameInPattern(const APattern: string): string;
const
  cDecor: array[0..14] of string = ('(?i)', '\b', '\s+', '\s*', '\s', '\w*',
    '\w+', '.*', '.+', '\<', '\>', '^', '$', '\(', '\)');
var
  LText, LSeg: string;
begin
  Result := '';
  LText := APattern;
  for var LD in cDecor do
    LText := LText.Replace(LD, ' ', [rfReplaceAll]);
  LText := LText.Replace('\.', '.', [rfReplaceAll]);
  for var LC in LText do
    if not (LC.IsLetterOrDigit or CharInSet(LC, ['_', '.', ' ', '|', '(', ')',
      ':', '=', ';', ',', '-'])) then
      Exit;
  for var LTok in LText.Split([' ', '|', '(', ')', ':', '=', ';', ',', '-'],
    TStringSplitOptions.ExcludeEmpty) do
  begin
    // A dotted name is found by its last segment; every segment must be one.
    LSeg := LTok.Trim(['.']);
    if LSeg = '' then
      Continue;
    var LOk := True;
    for var LPart in LSeg.Split(['.']) do
      if not ((LPart <> '') and (LPart[1].IsLetter or (LPart[1] = '_'))) then
        LOk := False;
    if LOk and LooksLikeName(Copy(LSeg, LastDelimiter('.', LSeg) + 1, MaxInt)) then
      Exit(LSeg);
  end;
end;

// A file named as such - an extension, no wildcard. A search in files the
// agent names is a read of something it has found already: `grep -n "X ="
// Version.pas` for the line's text was denied in a compound command, its
// git commands with it (0.45.2). The searches that went wrong (SPEC 10.4)
// were over the code base.
function IsNamedFile(const APath: string): Boolean;
begin
  Result := (APath <> '') and (ExtractFileExt(APath) <> '') and
    (APath.IndexOfAny(['*', '?', '{']) < 0);
end;

function GrepFinding(AInput: TJSONObject; out AFinding: TFinding): Boolean;
var
  LGlob, LType, LPath: string;
  LPascal: Boolean;
begin
  AFinding := Default(TFinding);
  LGlob := Str(AInput, 'glob');
  LType := Str(AInput, 'type');
  LPath := Str(AInput, 'path');
  if LGlob <> '' then
    LPascal := NamesPascal(LGlob)
  else if LType <> '' then
    LPascal := NamesPascal(LType)
  else if IsNamedFile(LPath) then
    Exit(False)   // one file the agent named: a read, not a search
  else
    LPascal := True;
  AFinding.Name := NameInPattern(Str(AInput, 'pattern'));
  Result := LPascal and (AFinding.Name <> '');
end;

// Words of one shell command, quotes taken off; a pipe, `;`, `&&` or `||`
// outside quotes is a word of its own, so the caller splits on it.
function ShellWords(const ACommand: string): TArray<string>;
var
  LWord: string;
  LQuote: Char;
  LHas: Boolean;
  LI: Integer;

  procedure Push;
  begin
    if LHas then
      Result := Result + [LWord];
    LWord := '';
    LHas := False;
  end;

begin
  Result := nil;
  LWord := '';
  LHas := False;
  LQuote := #0;
  LI := 1;
  while LI <= Length(ACommand) do
  begin
    var LC := ACommand[LI];
    if LQuote <> #0 then
    begin
      if LC = LQuote then
        LQuote := #0
      else
        LWord := LWord + LC;
    end
    else if CharInSet(LC, ['''', '"']) then
    begin
      LQuote := LC;
      LHas := True;
    end
    else if CharInSet(LC, [' ', #9, #10, #13]) then
      Push
    else if CharInSet(LC, ['|', ';', '&']) then
    begin
      Push;
      Result := Result + ['|'];
      while (LI < Length(ACommand)) and CharInSet(ACommand[LI + 1], ['|', '&']) do
        Inc(LI);
    end
    else
    begin
      LWord := LWord + LC;
      LHas := True;
    end;
    Inc(LI);
  end;
  Push;
end;

// One segment of a command: a search for a name over Pascal sources, or a
// `sed -n` line range of a Pascal file. Over Pascal sources: the command
// names a Pascal file or extension anywhere (`Get-ChildItem -Recurse
// -Include *.pas | Select-String Foo` names it in another segment), or the
// search is recursive and includes no other kind of file - and it is not
// a search in files named one by one, without recursion (IsNamedFile).
function SegmentFinding(const AWords: TArray<string>; const AWhole: string;
  out AFinding: TFinding): Boolean;
const
  cValued: array[0..17] of string = ('-A', '-B', '-C', '-m', '-f', '-g', '-t',
    '-T', '--max-count', '--context', '--glob', '--type', '--include',
    '--exclude', '-Path', '-Include', '-Exclude', '-Context');
var
  LStart, LI: Integer;
  LPattern, LTool: string;
  LRecursive, LOtherInclude, LGrepLike, LNamedOnly: Boolean;
  LPaths: Integer;
begin
  AFinding := Default(TFinding);
  Result := False;
  if Length(AWords) = 0 then
    Exit;
  LTool := Copy(AWords[0], LastDelimiter('/\', AWords[0]) + 1, MaxInt);
  if SameText(LTool, 'sed') then
  begin
    for LI := 1 to High(AWords) do
      if (AWords[LI].Length > 2) and AWords[LI].EndsWith('p') and
         CharInSet(AWords[LI][1], ['0'..'9']) and
         (Pos(',', AWords[LI]) > 0) then
        AFinding.Lines := Copy(AWords[LI], 1, Length(AWords[LI]) - 1)
          .Replace(',', '-')
      else if IsPascalFile(AWords[LI]) then
        AFinding.FileName := AWords[LI];
    Exit((AFinding.Lines <> '') and (AFinding.FileName <> ''));
  end;
  LStart := 1;
  if SameText(LTool, 'git') and (Length(AWords) > 1) and
     SameText(AWords[1], 'grep') then
    LStart := 2
  else if not (MatchText(ChangeFileExt(LTool, ''), ['grep', 'egrep', 'rg',
    'findstr', 'Select-String', 'sls'])) then
    Exit;
  LRecursive := SameText(ChangeFileExt(LTool, ''), 'rg') or (LStart = 2);
  LGrepLike := MatchText(ChangeFileExt(LTool, ''), ['grep', 'egrep']);
  LOtherInclude := False;
  LNamedOnly := True;
  LPaths := 0;
  LPattern := '';
  LI := LStart;
  while LI <= High(AWords) do
  begin
    var LW := AWords[LI];
    if SameText(LW, '-e') or SameText(LW, '--regexp') or
       SameText(LW, '-Pattern') then
    begin
      if LI < High(AWords) then
        LPattern := AWords[LI + 1];
      Inc(LI);
    end
    else if MatchText(LW, cValued) then
    begin
      if (LI < High(AWords)) and MatchText(LW, ['-g', '--glob', '--include',
        '-Include', '-t', '--type', '-T']) and
         not NamesPascal(AWords[LI + 1]) then
        LOtherInclude := True;
      if (LI < High(AWords)) and SameText(LW, '-Path') then
      begin
        Inc(LPaths);
        LNamedOnly := LNamedOnly and IsNamedFile(AWords[LI + 1]);
      end;
      Inc(LI);
    end
    else if LW.StartsWith('--include=') or LW.StartsWith('--glob=') or
      LW.StartsWith('--type=') then
      LOtherInclude := LOtherInclude or not NamesPascal(LW)
    else if SameText(LW, '--recursive') or SameText(LW, '/s') or
      (LGrepLike and TRegEx.IsMatch(LW, '^-[a-zA-Z]*[rR][a-zA-Z]*$')) then
      LRecursive := True
    else if LW.StartsWith('-') or (LW.StartsWith('/') and (Length(LW) = 2)) then
      // another option
    else if LPattern = '' then
      LPattern := LW
    else
    begin
      Inc(LPaths);
      LNamedOnly := LNamedOnly and IsNamedFile(LW);
    end;
    Inc(LI);
  end;
  AFinding.Name := NameInPattern(LPattern);
  Result := (AFinding.Name <> '') and
    not ((LPaths > 0) and LNamedOnly and not LRecursive) and
    (NamesPascal(AWhole) or (LRecursive and not LOtherInclude));
end;

function CommandFinding(const ACommand: string; out AFinding: TFinding): Boolean;
var
  LWords, LSeg: TArray<string>;
begin
  LWords := ShellWords(ACommand) + ['|'];
  LSeg := nil;
  for var LW in LWords do
    if LW = '|' then
    begin
      if SegmentFinding(LSeg, ACommand, AFinding) then
        Exit(True);
      LSeg := nil;
    end
    else
      LSeg := LSeg + [LW];
  Result := False;
end;

// A Delphi project in ADir or a directory above it, up to the repository
// root - the walk the server's own project discovery makes. So a hook
// installed once for every repository says nothing in the others.
function InDelphiProject(const ADir: string): Boolean;
var
  LDir, LUp: string;
begin
  Result := False;
  if (ADir = '') or not TDirectory.Exists(ADir) then
    Exit;
  LDir := IncludeTrailingPathDelimiter(ADir);
  repeat
    if (Length(TDirectory.GetFiles(LDir, '*.groupproj')) > 0) or
       (Length(TDirectory.GetFiles(LDir, '*.dproj')) > 0) then
      Exit(True);
    if TDirectory.Exists(LDir + '.git') or TFile.Exists(LDir + '.git') then
      Exit;
    LUp := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(LDir)));
    if Length(LUp) >= Length(LDir) then
      Exit;
    LDir := LUp;
  until False;
end;

function StateFile(const ASession: string): string;
var
  LName: string;
begin
  LName := '';
  for var LC in ASession do
    if LC.IsLetterOrDigit or (LC = '-') then
      LName := LName + LC;
  if LName = '' then
    LName := 'no-session';
  Result := TPath.Combine(TPath.Combine(TPath.GetTempPath, 'pastree-mcp\hook'),
    LName + '.txt');
end;

// Two times, Unix seconds: the last note given, the last pastree call.
procedure ReadState(const AFile: string; out ANoted, AUsed: Int64);
var
  LParts: TArray<string>;
begin
  ANoted := 0;
  AUsed := 0;
  try
    if not TFile.Exists(AFile) then
      Exit;
    LParts := TFile.ReadAllText(AFile).Trim.Split([' ']);
    if Length(LParts) = 2 then
    begin
      ANoted := StrToInt64Def(LParts[0], 0);
      AUsed := StrToInt64Def(LParts[1], 0);
    end;
  except
    // a state file another hook call is writing: as if none
  end;
end;

procedure WriteState(const AFile: string; ANoted, AUsed: Int64);
begin
  try
    ForceDirectories(ExtractFileDir(AFile));
    TFile.WriteAllText(AFile, Format('%d %d', [ANoted, AUsed]));
  except
    // a note given twice is the worst of it
  end;
end;

// Short: Claude Code shows it to the user as a red "hook error", and the
// first wording - 700 characters on what the index sees that grep does not -
// read as a wall of text (0.45.2). The agent needs the call, and that a
// repeat goes through.
function NoteFor(const AFinding: TFinding): string;
begin
  if AFinding.Name = '' then
    Result := Format('pastree index: `source` {"file":"%s","lines":"%s"} ' +
      'gives these lines; `file` + `line` alone, the whole routine.',
      [AFinding.FileName.Replace('\', '/'), AFinding.Lines])
  else
    Result := Format('pastree index: `%s` looks like a Pascal name - ' +
      '`references` {"symbol":"%0:s"} for its resolved uses (form lines and ' +
      'virtual calls too), `find`, `callers`, `source`.', [AFinding.Name]);
  Result := Result + ' Not loaded? ToolSearch "pastree". Want the text ' +
    'anyway? Repeat the command.';
end;

procedure Deny(const AReason: string);
var
  LOut, LSpecific: TJSONObject;
begin
  LOut := TJSONObject.Create;
  try
    LSpecific := TJSONObject.Create;
    LSpecific.AddPair('hookEventName', 'PreToolUse');
    LSpecific.AddPair('permissionDecision', 'deny');
    LSpecific.AddPair('permissionDecisionReason', AReason);
    LOut.AddPair('hookSpecificOutput', LSpecific);
    WriteStdout(LOut.ToJSON);
  finally
    LOut.Free;
  end;
end;

procedure RunHook;
var
  LRoot: TJSONValue;
  LObj, LInput: TJSONObject;
  LTool, LState: string;
  LFinding: TFinding;
  LFound: Boolean;
  LNoted, LUsed, LNow: Int64;
begin
  // Whatever goes wrong here, the agent's call goes through: a hook failing
  // is a call lost, a note missed is nothing.
  try
    LRoot := TJSONObject.ParseJSONValue(ReadStdin);
    try
      if not (LRoot is TJSONObject) then
        ExitProcess(0);
      LObj := TJSONObject(LRoot);
      LTool := Str(LObj, 'tool_name');
      LState := StateFile(Str(LObj, 'session_id'));
      LNow := DateTimeToUnix(Now, False);
      ReadState(LState, LNoted, LUsed);
      if LTool.StartsWith('mcp__') and ContainsText(LTool, 'pastree') then
      begin
        WriteState(LState, LNoted, LNow);
        ExitProcess(0);
      end;
      if not (LObj.GetValue('tool_input') is TJSONObject) then
        ExitProcess(0);
      LInput := TJSONObject(LObj.GetValue('tool_input'));
      if SameText(LTool, 'Grep') then
        LFound := GrepFinding(LInput, LFinding)
      else if SameText(LTool, 'Bash') or SameText(LTool, 'PowerShell') then
        LFound := CommandFinding(Str(LInput, 'command'), LFinding)
      else
        LFound := False;
      if not LFound or (LNow - LNoted < cNoteEverySeconds) or
         (LNow - LUsed < cKnowsToolsSeconds) or
         not InDelphiProject(Str(LObj, 'cwd')) then
        ExitProcess(0);
      WriteState(LState, LNow, LUsed);
      Deny(NoteFor(LFinding));
    finally
      LRoot.Free;
    end;
  except
    // nothing on stdout: the call goes through
  end;
  ExitProcess(0);
end;

end.
