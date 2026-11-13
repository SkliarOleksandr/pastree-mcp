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
  searches recursively (rg, -r) without an include of another kind - unless
  it names no file and reads a pipe.

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
  System.Generics.Collections,
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
    Names: TArray<string>;  // every name of the pattern, Name first
    Decl: Boolean;     // a search for their declarations
    InFile: string;    // a declaration search in one named file: that file
    FileName: string;  // a line read: the file
    Lines: TArray<string>;  // a line read: `A-B`, one per sed range
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
// `*.{pas,inc}`, `-t pascal` - not `pastree` or `--include`, nor a path
// through `object-pascal-tree` (a hyphen is a word boundary: every command
// naming PasTree's directory was a search over Pascal sources).
function NamesPascal(const AText: string): Boolean;
begin
  Result := TRegEx.IsMatch(AText,
    '(?i)[.{,](pas|dpr|dpk|inc|dfm|fmx)\b|(^|[\s=''"])pascal\b(?!-)');
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
//
// Every name of an alternation (`A\|B`, `TFoo\.\(A\|B\)`), one per
// alternative - the first there: `SetSite(const Value: Integer)` is SetSite,
// not Value - in order. A part of a name written as a regex (`PasArray\w*`,
// `TFoo\..*Builtin`) is `find`'s wildcard (`PasArray*`, `TFoo.*Builtin`).
// ADecl: a search for their declarations - a routine's or a type's keyword
// in the pattern (AKeyword too), or `Name =`. 587 of 771 declaration greps in
// the sessions of 2026-11-03..12 named several names, for their lines - what
// `find` with `A|B` answers (0.51.0); the note named the first one only.
function NamesInPattern(const APattern: string; out ADecl,
  AKeyword: Boolean): TArray<string>;
const
  cWild: array[0..3] of string = ('\w*', '\w+', '.*', '.+');
  cDecor: array[0..8] of string = ('(?i)', '\b', '\s+', '\s*', '\s', '\<',
    '\>', '^', '$');
  cDeclWords: array[0..7] of string = ('procedure', 'function', 'constructor',
    'destructor', 'class', 'record', 'interface', 'property');
var
  LText, LSeg, LBare: string;
  LHasEq: Boolean;
begin
  Result := nil;
  ADecl := False;
  AKeyword := False;
  // grep's basic regex as an extended one, then `Prefix\.(A|B)` spelled out
  // as `Prefix\.A|Prefix\.B`.
  LText := APattern.Replace('\|', '|', [rfReplaceAll]).Replace('\(', '(',
    [rfReplaceAll]).Replace('\)', ')', [rfReplaceAll]);
  var LGroup := TRegEx.Match(LText,
    '([A-Za-z_]\w*(?:\\\.[A-Za-z_]\w*)*)\\\.\(([^()]*)\)');
  while LGroup.Success do
  begin
    var LSpelled := '';
    for var LAlt in LGroup.Groups[2].Value.Split(['|']) do
      LSpelled := LSpelled + IfThen(LSpelled <> '', '|') +
        LGroup.Groups[1].Value + '\.' + LAlt;
    LText := Copy(LText, 1, LGroup.Index - 1) + LSpelled +
      Copy(LText, LGroup.Index + LGroup.Length, MaxInt);
    LGroup := TRegEx.Match(LText,
      '([A-Za-z_]\w*(?:\\\.[A-Za-z_]\w*)*)\\\.\(([^()]*)\)');
  end;
  for var LW in cWild do
    LText := LText.Replace(LW, '*', [rfReplaceAll]);
  for var LD in cDecor do
    LText := LText.Replace(LD, ' ', [rfReplaceAll]);
  LText := LText.Replace('\.', '.', [rfReplaceAll]);
  for var LC in LText do
    if not (LC.IsLetterOrDigit or CharInSet(LC, ['_', '.', ' ', '|', '(', ')',
      ':', '=', ';', ',', '-', '*'])) then
      Exit;
  LHasEq := LText.Contains('=');
  for var LAlt in LText.Split(['|']) do
    for var LTok in LAlt.Split([' ', '(', ')', ':', '=', ';', ',', '-'],
      TStringSplitOptions.ExcludeEmpty) do
    begin
      if MatchText(LTok, cDeclWords) then
      begin
        AKeyword := True;
        Continue;
      end;
      // A dotted name is found by its last segment; every segment must be
      // one (a wildcard aside).
      LSeg := LTok.Trim(['.']);
      LBare := LSeg.Replace('*', '', [rfReplaceAll]);
      if (LBare = '') or LBare.EndsWith('.') then
        Continue;
      var LOk := True;
      for var LPart in LSeg.Split(['.']) do
        if not ((LPart <> '') and (LPart[1].IsLetter or CharInSet(LPart[1],
          ['_', '*']))) then
          LOk := False;
      if LOk and LooksLikeName(Copy(LBare, LastDelimiter('.', LBare) + 1,
        MaxInt)) then
      begin
        if not MatchText(LSeg, Result) then
          Result := Result + [LSeg];
        Break;   // the alternative's first name is the one it looks for
      end;
    end;
  ADecl := (Result <> nil) and (AKeyword or LHasEq);
end;

function NameInPattern(const APattern: string): string;
var
  LDecl, LKeyword: Boolean;
  LNames: TArray<string>;
begin
  LNames := NamesInPattern(APattern, LDecl, LKeyword);
  if LNames = nil then
    Exit('');
  Result := LNames[0];
end;

// The finding's names from APattern; a search in one file the agent named
// is a finding only when it looks for routines or types by their keyword:
// their lines are `find`'s answer, `in` that file. `grep -n "X =" Version.pas`
// for a line's text stays a read (0.45.2).
function FillNames(var AFinding: TFinding; const APattern, ANamedFile: string;
  ANamedOnly: Boolean): Boolean;
var
  LKeyword: Boolean;
begin
  AFinding.Names := NamesInPattern(APattern, AFinding.Decl, LKeyword);
  if AFinding.Names = nil then
    Exit(False);
  AFinding.Name := AFinding.Names[0];
  if ANamedOnly then
  begin
    if not LKeyword then
      Exit(False);
    AFinding.InFile := ANamedFile;
  end;
  Result := True;
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
    // One file the agent named: a read, not a search - unless it looks for
    // routines or types by their keyword.
    Exit(IsPascalFile(LPath) and FillNames(AFinding, Str(AInput, 'pattern'),
      LPath, True))
  else
    LPascal := True;
  Result := LPascal and FillNames(AFinding, Str(AInput, 'pattern'), '', False);
end;

// Words of one shell command, quotes taken off; outside quotes a pipe (`|`,
// `|&`) is the word `|` and `;`, `&`, `&&` or `||` the word `;`, so the caller
// splits on them and knows which segments read the one before. `2>&1` is a
// word.
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
    else if (LC = '&') and LWord.EndsWith('>') then
      LWord := LWord + LC
    else if CharInSet(LC, ['|', ';', '&']) then
    begin
      Push;
      var LPipe := (LC = '|') and ((LI = Length(ACommand)) or
        (ACommand[LI + 1] <> '|'));
      Result := Result + [IfThen(LPipe, '|', ';')];
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
// a search in files named one by one, without recursion (IsNamedFile), nor
// one with no file that reads the pipe (APipeIn): `build.bat | Select-String
// "Error|Fatal"` searches a build's output, and a command naming `.dpr` on
// the left of it made that a search for `Error` (0.46.1).
//
// A `sed -n` of several ranges (`'10,20p;40,50p'`, `-e 10,20p -e 40,50p`) is
// a read of each: the note gives `source` one `targets` entry per range -
// pieces of one file the agent knows by line, which `source` answers as they
// are. A script doing anything else (`s/../../`, `/re/p`) is not a line read.
function SegmentFinding(const AWords: TArray<string>; const AWhole: string;
  APipeIn: Boolean; out AFinding: TFinding): Boolean;
const
  cValued: array[0..17] of string = ('-A', '-B', '-C', '-m', '-f', '-g', '-t',
    '-T', '--max-count', '--context', '--glob', '--type', '--include',
    '--exclude', '-Path', '-Include', '-Exclude', '-Context');
var
  LStart, LI: Integer;
  LPattern, LTool, LOneFile: string;
  LRecursive, LOtherInclude, LGrepLike, LNamedOnly, LHasPattern: Boolean;
  LPaths, LOthers: Integer;

  // A file, or a glob of files, by an extension not Pascal's: `x.bat`,
  // `scripts/*.bat`. A directory has none - `.`, `..`, `../pastree-lsp`
  // are not extensions (ExtractFileExt reads `/` as no delimiter).
  function OtherKind(const APath: string): Boolean;
  begin
    Result := TRegEx.IsMatch(APath, '(^|[\\/])[^\\/.][^\\/]*\.[A-Za-z0-9]+$')
      and not NamesPascal(APath);
  end;

begin
  LOthers := 0;
  LOneFile := '';
  AFinding := Default(TFinding);
  Result := False;
  if Length(AWords) = 0 then
    Exit;
  LTool := Copy(AWords[0], LastDelimiter('/\', AWords[0]) + 1, MaxInt);
  if SameText(LTool, 'sed') then
  begin
    for LI := 1 to High(AWords) do
      if (AWords[LI] <> '') and CharInSet(AWords[LI][1], ['0'..'9']) then
      begin
        for var LCmd in AWords[LI].Split([';', #10],
          TStringSplitOptions.ExcludeEmpty) do
        begin
          var LRange := TRegEx.Match(LCmd.Trim, '^(\d+),(\d+)p$');
          if not LRange.Success then
            Exit;
          AFinding.Lines := AFinding.Lines + [LRange.Groups[1].Value + '-' +
            LRange.Groups[2].Value];
        end;
      end
      else if IsPascalFile(AWords[LI]) then
        AFinding.FileName := AWords[LI];
    Exit((AFinding.Lines <> nil) and (AFinding.FileName <> ''));
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
  // Set by the word, not by its text: `grep "" PasTree-x.log` has an empty
  // pattern, and the file name is not one.
  LHasPattern := False;
  LI := LStart;
  while LI <= High(AWords) do
  begin
    var LW := AWords[LI];
    if SameText(LW, '-e') or SameText(LW, '--regexp') or
       SameText(LW, '-Pattern') then
    begin
      if LI < High(AWords) then
        LPattern := AWords[LI + 1];
      LHasPattern := True;
      Inc(LI);
    end
    // A letter option by its case: grep's -c counts and -C takes a value, and
    // `grep -c x PasTree-mcp.log` was read as -C x and a search for the file
    // name, `PasTree` (a field report). PowerShell's words are any case.
    else if ((Length(LW) = 2) and MatchStr(LW, cValued)) or
      ((Length(LW) > 2) and MatchText(LW, cValued)) then
    begin
      if (LI < High(AWords)) and MatchText(LW, ['-g', '--glob', '--include',
        '-Include', '-t', '--type', '-T']) and
         not NamesPascal(AWords[LI + 1]) then
        LOtherInclude := True;
      if (LI < High(AWords)) and SameText(LW, '-Path') then
      begin
        Inc(LPaths);
        if OtherKind(AWords[LI + 1]) then
          Inc(LOthers);
        LNamedOnly := LNamedOnly and IsNamedFile(AWords[LI + 1]);
        LOneFile := AWords[LI + 1];
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
    else if not LHasPattern then
    begin
      LPattern := LW;
      LHasPattern := True;
    end
    else
    begin
      Inc(LPaths);
      if OtherKind(LW) then
        Inc(LOthers);
      LNamedOnly := LNamedOnly and IsNamedFile(LW);
      LOneFile := LW;
    end;
    Inc(LI);
  end;
  // No file and no recursion of its own: it searches what the pipe brings
  // (rg and Select-String read a pipe when given no path, recursive or not).
  if APipeIn and (LPaths = 0) and (LStart = 1) and
     not (LGrepLike and LRecursive) then
    Exit;
  // Every path of another kind of file (`build.bat scripts/*.bat`): not a
  // search of Pascal sources, whatever else the command names.
  if (LPaths > 0) and (LOthers = LPaths) then
    Exit;
  // In files named one by one: a read - unless one Pascal file is searched
  // for routines or types by their keyword (FillNames).
  if (LPaths > 0) and LNamedOnly and not LRecursive then
    Exit((LPaths = 1) and IsPascalFile(LOneFile) and FillNames(AFinding,
      LPattern, LOneFile, True));
  Result := FillNames(AFinding, LPattern, '', False) and
    (NamesPascal(AWhole) or (LRecursive and not LOtherInclude));
end;

// A segment piping files, not text, to the next: Get-ChildItem and its
// aliases hand Select-String the files to search.
function ListsFiles(const ASeg: TArray<string>): Boolean;
begin
  Result := (Length(ASeg) > 0) and MatchText(ASeg[0], ['Get-ChildItem', 'gci',
    'dir', 'ls', 'Get-Item', 'gi']);
end;

// A Git Bash path, `/c/Repos/x`, as Windows writes it: `C:/Repos/x`.
function WindowsPath(const APath: string): string;
begin
  Result := APath;
  if (Length(Result) >= 3) and (Result[1] = '/') and
     CharInSet(Result[2], ['a'..'z', 'A'..'Z']) and (Result[3] = '/') then
    Result := UpperCase(Result[2]) + ':' + Copy(Result, 3, MaxInt)
  else if (Length(Result) = 2) and (Result[1] = '/') and
     CharInSet(Result[2], ['a'..'z', 'A'..'Z']) then
    Result := UpperCase(Result[2]) + ':/';
end;

// APath seen from ADir (a `cd` before it in the command; '' for none).
function PathFrom(const ADir, APath: string): string;
begin
  Result := WindowsPath(APath);
  if (ADir <> '') and not TPath.IsPathRooted(Result) then
    Result := IncludeTrailingPathDelimiter(ADir.Replace('/', '\')) + Result;
end;

// `$R`, `${R}`, `$env:R` in APath from the assignments made before it in the
// command; False when one is not known - the note would name a file no one
// can open.
function ExpandVars(var APath: string; AVars: TDictionary<string, string>):
  Boolean;
var
  LM: TMatch;
  LValue: string;
begin
  repeat
    LM := TRegEx.Match(APath, '\$(?:env:)?\{?([A-Za-z_]\w*)\}?');
    if not LM.Success then
      Exit(True);
    if not AVars.TryGetValue(LM.Groups[1].Value, LValue) then
      Exit(False);
    APath := Copy(APath, 1, LM.Index - 1) + LValue +
      Copy(APath, LM.Index + LM.Length, MaxInt);
  until False;
end;

// The segments one by one. A `cd` (`pushd`, `Set-Location`) and a variable
// set (`R="C:/..."`, `$R = "..."`) are kept for the segments after them: the
// note names the file a `sed -n` reads, and in the usage audit of 2026-11-12
// 53 of 91 notes named one that is not where the server looks - `cd source;
// sed -n 10,20p X.pas`, `sed -n ... "$R/rtl/X.pas"`, `/c/Repos/...`.
function CommandFinding(const ACommand: string; out AFinding: TFinding): Boolean;
var
  LWords, LSeg: TArray<string>;
  LPipeIn: Boolean;
  LDir, LPath: string;
  LVars: TDictionary<string, string>;
  LAssign: TMatch;
begin
  LWords := ShellWords(ACommand) + [';'];
  LSeg := nil;
  LPipeIn := False;
  LDir := '';
  LVars := TDictionary<string, string>.Create;
  try
    for var LW in LWords do
      if (LW = '|') or (LW = ';') then
      begin
        if (Length(LSeg) = 2) and MatchText(LSeg[0], ['cd', 'pushd',
          'Set-Location', 'sl', 'chdir']) then
        begin
          LPath := LSeg[1];
          if ExpandVars(LPath, LVars) then
            LDir := PathFrom(LDir, LPath)
          else
            LDir := '?';
        end
        else if (Length(LSeg) = 3) and LSeg[0].StartsWith('$') and
          (LSeg[1] = '=') then
          LVars.AddOrSetValue(LSeg[0].Substring(1).Replace('env:', ''), LSeg[2])
        else if Length(LSeg) >= 1 then
        begin
          LAssign := TRegEx.Match(LSeg[0], '^([A-Za-z_]\w*)=(.*)$');
          if LAssign.Success then
            LVars.AddOrSetValue(LAssign.Groups[1].Value, LAssign.Groups[2].Value);
        end;
        if SegmentFinding(LSeg, ACommand, LPipeIn, AFinding) then
        begin
          if AFinding.FileName = '' then
            Exit(True);
          // A line read: the file as the server will look for it.
          LPath := AFinding.FileName;
          if (LDir <> '?') and ExpandVars(LPath, LVars) then
          begin
            AFinding.FileName := PathFrom(LDir, LPath);
            Exit(True);
          end;
        end;
        LPipeIn := (LW = '|') and not ListsFiles(LSeg);
        LSeg := nil;
      end
      else
        LSeg := LSeg + [LW];
  finally
    LVars.Free;
  end;
  Result := False;
end;

// The directory of a Delphi project in ADir or a directory above it, up to
// the repository root - the walk the server's own project discovery makes;
// '' for none. So a hook installed once for every repository says nothing in
// the others.
function ProjectDirOf(const ADir: string): string;
var
  LDir, LUp: string;
begin
  Result := '';
  if (ADir = '') or not TDirectory.Exists(ADir) then
    Exit;
  LDir := IncludeTrailingPathDelimiter(ADir);
  repeat
    if (Length(TDirectory.GetFiles(LDir, '*.groupproj')) > 0) or
       (Length(TDirectory.GetFiles(LDir, '*.dproj')) > 0) then
      Exit(LDir);
    if TDirectory.Exists(LDir + '.git') or TFile.Exists(LDir + '.git') then
      Exit;
    LUp := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(LDir)));
    if Length(LUp) >= Length(LDir) then
      Exit;
    LDir := LUp;
  until False;
end;

// One state per agent: Claude Code gives a subagent's call its parent's
// `session_id` and adds `agent_id`. Keyed by the session alone, the subagents
// of a session (Explore, a workflow's agents) shared one note per 10 minutes,
// and one agent's pastree call silenced the hook for all of them.
function StateFile(const ASession, AAgent: string): string;
var
  LName: string;
begin
  LName := '';
  for var LC in ASession + IfThen(AAgent <> '', '-' + AAgent) do
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
var
  LFile, LTargets: string;
begin
  LFile := AFinding.FileName.Replace('\', '/');
  if (AFinding.Name = '') and (Length(AFinding.Lines) = 1) then
    Result := Format('pastree index: `source` {"file":"%s","lines":"%s"} ' +
      'gives these lines; `file` + `line` alone, the whole routine.',
      [LFile, AFinding.Lines[0]])
  else if AFinding.Name = '' then
  begin
    LTargets := '';
    for var LLines in AFinding.Lines do
      LTargets := LTargets + IfThen(LTargets <> '', ',') +
        Format('{"file":"%s","lines":"%s"}', [LFile, LLines]);
    Result := Format('pastree index: `source` {"targets":[%s]} gives these ' +
      'lines; `file` + `line` alone, the whole routine.', [LTargets]);
  end
  else if AFinding.Decl or string.Join('|', AFinding.Names).Contains('*') then
    // Declarations of one or several names - or a name written with a
    // wildcard, which only `find` takes: `find`, a line each; in the file
    // searched, by its name (`in` matches a part of the path).
    Result := Format('pastree index: `find` {"query":"%s"%s} gives their ' +
      'declarations, a line each; `source` their text.', [string.Join('|',
      AFinding.Names), IfThen(AFinding.InFile <> '', Format(',"in":"%s"',
      [ExtractFileName(AFinding.InFile.Replace('/', '\'))]), '')])
  else if Length(AFinding.Names) > 1 then
  begin
    LTargets := '';
    for var LN in AFinding.Names do
      LTargets := LTargets + IfThen(LTargets <> '', ',') + '"' + LN + '"';
    Result := Format('pastree index: these look like Pascal names - ' +
      '`references` {"targets":[%s]} for their resolved uses, `find` ' +
      '{"query":"%s"} for their declarations.', [LTargets, string.Join('|',
      AFinding.Names)]);
  end
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
      LState := StateFile(Str(LObj, 'session_id'), Str(LObj, 'agent_id'));
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
         (ProjectDirOf(Str(LObj, 'cwd')) = '') then
        ExitProcess(0);
      // A line read in a directory below the project's (the shell keeps a
      // `cd source` from a call before): the file as the server, which
      // resolves against the project's directory, finds it.
      if (LFinding.FileName <> '') and
         not TPath.IsPathRooted(LFinding.FileName) then
      begin
        var LProjDir := ProjectDirOf(Str(LObj, 'cwd'));
        var LFull := TPath.GetFullPath(TPath.Combine(Str(LObj, 'cwd'),
          LFinding.FileName));
        if LFull.StartsWith(LProjDir, True) then
          LFinding.FileName := Copy(LFull, Length(LProjDir) + 1, MaxInt)
        else
          LFinding.FileName := LFull;
      end;
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
