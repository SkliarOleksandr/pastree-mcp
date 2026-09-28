unit PasMcp.Tools;

{
  The tools an agent calls, and the text they answer with.

  Shaped for a language model, not an editor - which is the whole reason this
  is not the LSP server behind a bridge:

  - ADDRESSED BY NAME. An editor asks "what is at line 120, column 17"; an
    agent knows `TFoo.Bar` and is unreliable at counting columns. Every tool
    that takes a symbol accepts a (qualified) name, or a file + line + the
    identifier written on that line, and finds the column itself.
  - ANSWERED IN COMPACT TEXT. Paths relative to the group directory, results
    grouped by file, one trimmed source line per row, a cap with "N more".
    Every token of a result is paid for by the agent, again on every turn.
  - GROUP-WIDE. A symbol lives in a unit, and a unit may be part of several
    analyses (see PasMcp.Workspace): its identity across them is its
    DECLARATION SITE (file, line, column), and every search runs in every
    analysis that holds it, merged and de-duplicated by hit site.

  Errors the agent can act on (no such symbol, ambiguous name, file not in the
  closure) come back as tool results with isError set - that is what MCP
  specifies for them, and the agent reads them, where a protocol error would
  only be logged.
}

interface

uses
  System.SysUtils,
  System.JSON,
  PasMcp.Workspace;

type
  // A tool whose answer comes later - `compile`, a build of seconds to
  // minutes. CallTool hands it back instead of an answer; Work then runs on
  // a thread of its own and must not read the index, so the calls behind it
  // are answered meanwhile; Finish runs where the tools run (it may read the
  // index) and answers. Cancel is called from another thread, any time
  // before Finish.
  TDeferredTool = class
  public
    procedure Work; virtual; abstract;
    function Finish(out AIsError: Boolean): string; virtual; abstract;
    procedure Cancel; virtual; abstract;
  end;

function ToolDefinitions: TJSONArray;
function ServerInstructions(AWs: TMcpWorkspace): string;
// The answer to a call - or '' and ADeferred, for a tool that answers later.
// AProgress, when set, gets a line of status from a tool that reports: set by
// the server when the call carries a progress token.
function CallTool(AWs: TMcpWorkspace; const AName: string; AArgs: TJSONObject;
  out AIsError: Boolean; out ADeferred: TDeferredTool;
  const AProgress: TProc<string> = nil): string;
// CallTool to its answer, a deferred tool's work done on the calling thread:
// the CLI's way.
function CallToolNow(AWs: TMcpWorkspace; const AName: string;
  AArgs: TJSONObject; out AIsError: Boolean): string;

implementation

uses
  System.Classes,
  System.StrUtils,
  System.Character,
  System.Math,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Ast,
  PasTree.Outline,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav,
  PasTree.Dfm,
  PasTree.Sema.Dfm,
  PasTree.Platforms,
  PasMcp.Log,
  PasMcp.Build;

type
  EToolError = class(Exception);

  TTargetKind = (tkSymbol, tkUnit, tkBuiltin, tkDefine);

  TSymId = record
    Mid, Sym: Integer;
  end;

  // What a tool is about, resolved - with its identity in EVERY analysis.
  TTarget = record
    Kind: TTargetKind;
    Name: string;          // qualified display name
    Head: string;          // 'function', 'type', 'unit', ...
    DeclFile: string;
    DeclLine, DeclCol: Integer;
    Snippet: string;
    Own: Boolean;
    Ids: TArray<TSymId>;   // by analysis index; Mid < 0 = not in it
  end;

  // One raw name match before its declaration site is known (see ResolveName).
  TRawMatch = record
    Analysis, Mid, Sym: Integer;
    ModelFile: string;
    Own: Boolean;
  end;

  THit = record
    FilePath: string;
    Line, Col: Integer;
    Snippet: string;
    Tag: string;           // row label for related(): 'TFoo override'
    Own: Boolean;
    // A form file's row: the heading it goes under instead of the routine or
    // type around it - its component - and a note for the file's line.
    Where: string;
    FileNote: string;
  end;

const
  DECL_KINDS = [skType, skVar, skConst, skField, skRoutine, skProperty];
  ROUTINE_HEADS: array[TPasRoutineHead] of string = ('routine', 'procedure',
    'function', 'constructor', 'destructor', 'operator');

{ ---- arguments ------------------------------------------------------------ }

function ArgStr(AArgs: TJSONObject; const AName: string;
  const ADefault: string = ''): string;
var
  LV: TJSONValue;
begin
  Result := ADefault;
  if AArgs = nil then
    Exit;
  LV := AArgs.GetValue(AName);
  if (LV <> nil) and not (LV is TJSONNull) then
    Result := Trim(LV.Value);
end;

function ArgInt(AArgs: TJSONObject; const AName: string;
  ADefault: Integer): Integer;
var
  LV: TJSONValue;
begin
  Result := ADefault;
  if AArgs = nil then
    Exit;
  LV := AArgs.GetValue(AName);
  if LV is TJSONNumber then
    Result := TJSONNumber(LV).AsInt
  else if LV is TJSONString then
    Result := StrToIntDef(LV.Value, ADefault);
end;

function ArgBool(AArgs: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  LV: TJSONValue;
begin
  Result := ADefault;
  if AArgs = nil then
    Exit;
  LV := AArgs.GetValue(AName);
  if LV is TJSONBool then
    Result := TJSONBool(LV).AsBoolean
  else if LV is TJSONString then
    Result := SameText(LV.Value, 'true') or (LV.Value = '1');
end;

// The `file` argument as a full path. A control character in it is a JSON
// escape the caller did not mean - "src\frmMain.pas" holds a form feed -
// and would otherwise come back as the RTL's "invalid characters in path".
function ArgFile(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LRaw: string;
begin
  LRaw := ArgStr(AArgs, 'file');
  for var LCh in LRaw do
    if LCh < ' ' then
      raise EToolError.CreateFmt('`file` holds a control character (#%d): in '
        + 'JSON a backslash is written \\, or use / - %s', [Ord(LCh),
        LRaw.Replace(LCh, '?')]);
  Result := AWs.FullPath(LRaw);
end;

{ ---- small text helpers --------------------------------------------------- }

function CleanLine(const AText: string; AMax: Integer = 160): string;
var
  LSb: TStringBuilder;
  LSpace: Boolean;
begin
  LSb := TStringBuilder.Create;
  try
    LSpace := False;
    for var LCh in Trim(AText) do
      if LCh <= ' ' then
      begin
        if not LSpace then
          LSb.Append(' ');
        LSpace := True;
      end
      else
      begin
        LSb.Append(LCh);
        LSpace := False;
      end;
    Result := LSb.ToString;
  finally
    LSb.Free;
  end;
  if Length(Result) > AMax then
    Result := Copy(Result, 1, AMax - 3) + '...';
end;

{ A declaration's text at most AMax characters, cut after a `;` or a `,` - a
  parameter boundary - with ` ...` for what is left out, and the text from
  its last `)` on kept when that is short: `function Foo(A: X; B: Y; ...):
  Integer;`. Cut anywhere else, the end of a parameter list reads as a
  parameter - `AInterfa...: TPasTree` - and the result type is gone. }
function CutDecl(const AText: string; AMax: Integer = 160): string;
const
  MAX_TAIL = 40;
var
  LTail: string;
  LClose, LCut: Integer;
begin
  if Length(AText) <= AMax then
    Exit(AText);
  LTail := '';
  LClose := LastDelimiter(')', AText);
  if (LClose > 0) and (Length(AText) - LClose < MAX_TAIL) then
    LTail := Copy(AText, LClose, MaxInt);
  LCut := AMax - Length(LTail) - Length(' ...');
  while (LCut > 0) and not CharInSet(AText[LCut], [';', ',']) do
    Dec(LCut);
  if LCut <= 0 then
    Exit(Copy(AText, 1, AMax - 3) + '...');
  Result := Copy(AText, 1, LCut) + ' ...' + LTail;
end;

function IsIdentChar(ACh: Char): Boolean;
begin
  Result := ACh.IsLetterOrDigit or (ACh = '_');
end;

// 1-based column of the first whole-word, case-insensitive occurrence of
// AWord in ALine; 0 when absent.
function FindWord(const ALine, AWord: string): Integer;
var
  LFrom, LAt: Integer;
  LLine, LWord: string;
begin
  Result := 0;
  if AWord = '' then
    Exit;
  LLine := LowerCase(ALine);
  LWord := LowerCase(AWord);
  LFrom := 1;
  while True do
  begin
    LAt := PosEx(LWord, LLine, LFrom);
    if LAt = 0 then
      Exit;
    if ((LAt = 1) or not IsIdentChar(LLine[LAt - 1])) and
       ((LAt + Length(LWord) > Length(LLine)) or
        not IsIdentChar(LLine[LAt + Length(LWord)])) then
      Exit(LAt);
    LFrom := LAt + 1;
  end;
end;

// '*' and '?' over lower-case text.
function WildMatch(const APattern, AText: string): Boolean;
var
  LP, LT, LStar, LMark: Integer;
begin
  LP := 1;
  LT := 1;
  LStar := 0;
  LMark := 0;
  while LT <= Length(AText) do
  begin
    if (LP <= Length(APattern)) and ((APattern[LP] = '?') or
       (APattern[LP] = AText[LT])) then
    begin
      Inc(LP);
      Inc(LT);
    end
    else if (LP <= Length(APattern)) and (APattern[LP] = '*') then
    begin
      LStar := LP;
      LMark := LT;
      Inc(LP);
    end
    else if LStar > 0 then
    begin
      LP := LStar + 1;
      Inc(LMark);
      LT := LMark;
    end
    else
      Exit(False);
  end;
  while (LP <= Length(APattern)) and (APattern[LP] = '*') do
    Inc(LP);
  Result := LP > Length(APattern);
end;

function StripGenerics(const AName: string): string;
var
  LAt: Integer;
begin
  LAt := Pos('<', AName);
  if LAt > 0 then
    Result := Copy(AName, 1, LAt - 1)
  else
    Result := AName;
end;

function ReadLines(const APath: string): TArray<string>;
begin
  try
    Result := TFile.ReadAllLines(APath);   // BOM-aware
  except
    Result := nil;
  end;
end;

{ ---- symbol facts ----------------------------------------------------------- }

// The enclosing struct chain of a member scope, outer first ('TOuter.TInner')
// - the same walk as TPasNavigator.ProjectOutline's OwnerOf.
function OwnerOf(LM: TPasSemaModel; AScope: Integer): string;
var
  LSt: Integer;
begin
  Result := '';
  while (AScope <> NIL_SCOPE) and (AScope < LM.Scopes.Count) and
        (LM.Scopes[AScope].Kind = sckStruct) do
  begin
    LSt := LM.Scopes[AScope].StructSym;
    if LSt = NIL_SYM then
      Break;
    if Result = '' then
      Result := LM.Symbols[LSt].Name
    else
      Result := LM.Symbols[LSt].Name + '.' + Result;
    AScope := LM.Symbols[LSt].Scope;
  end;
end;

// A declaration a reader would look up by name - ProjectOutline's filter:
// module-level or a struct member, with a source declaration.
function IsDeclSymbol(LM: TPasSemaModel; ASym: Integer): Boolean;
var
  LScope: Integer;
begin
  Result := False;
  if not (LM.Symbols[ASym].Kind in DECL_KINDS) or
     (LM.Symbols[ASym].DeclNode = NIL_NODE) or
     (sfBuiltin in LM.Symbols[ASym].Flags) then
    Exit;
  LScope := LM.Symbols[ASym].Scope;
  while (LScope <> NIL_SCOPE) and (LScope < LM.Scopes.Count) and
        (LM.Scopes[LScope].Kind in [sckStruct, sckGenericParams]) do
    LScope := LM.Scopes[LScope].Parent;
  Result := (LScope <> NIL_SCOPE) and (LScope < LM.Scopes.Count) and
    (LM.Scopes[LScope].Kind in [sckUnit, sckImplementation]);
end;

function HeadOf(LM: TPasSemaModel; ASym: Integer): string;
begin
  case LM.Symbols[ASym].Kind of
    skType:
      case LM.Symbols[ASym].TypeCat of
        tcClass: Result := 'class';
        tcRecord: Result := 'record';
        tcInterface: Result := 'interface';
      else
        Result := 'type';
      end;
    skVar: Result := 'var';
    skConst: Result := 'const';
    skField: Result := 'field';
    skProperty: Result := 'property';
    skRoutine: Result := ROUTINE_HEADS[LM.RoutineHead(ASym)];
    skParam: Result := 'parameter';
    skEnumValue: Result := 'enum value';
  else
    Result := 'symbol';
  end;
end;

function KindMatches(LM: TPasSemaModel; ASym: Integer;
  const AKind: string): Boolean;
begin
  if AKind = '' then
    Exit(True);
  case LM.Symbols[ASym].Kind of
    skType: Result := SameText(AKind, 'type') or
      SameText(AKind, HeadOf(LM, ASym));
    skRoutine: Result := SameText(AKind, 'routine') or
      SameText(AKind, 'method') or SameText(AKind, HeadOf(LM, ASym));
    skVar: Result := SameText(AKind, 'var') or SameText(AKind, 'variable');
    skConst: Result := SameText(AKind, 'const') or SameText(AKind, 'constant');
    skField: Result := SameText(AKind, 'field');
    skProperty: Result := SameText(AKind, 'property');
  else
    Result := False;
  end;
end;

function UnitNameOfFile(const APath: string): string;
begin
  Result := TPath.GetFileNameWithoutExtension(APath);
end;

function QualifiedName(LM: TPasSemaModel; ASym: Integer): string;
var
  LOwner: string;
begin
  LOwner := OwnerOf(LM, LM.Symbols[ASym].Scope);
  if LOwner <> '' then
    Result := LOwner + '.' + LM.Symbols[ASym].Name
  else
    Result := LM.Symbols[ASym].Name;
end;

{ The visible tokens AFrom..ATo as one line: each as written, one space
  wherever the source has anything between two - so a comment, a directive,
  a code branch not compiled and the line breaks are gone. Joined into one
  line, a `//` comment would swallow what follows it. None inside brackets:
  a list broken after its `(` would read `( AFirst: X`. }
function VisText(LM: TPasSemaModel; AFrom, ATo: Integer): string;
var
  LSb: TStringBuilder;
  LTok, LPrev: TPasToken;
  LFileId, LPrevFileId: Integer;
begin
  LSb := TStringBuilder.Create;
  try
    LPrev := Default(TPasToken);
    LPrevFileId := -1;
    for var LI := AFrom to ATo do
    begin
      LFileId := LM.Tree.Source.Visible[LI].FileId;
      LTok := LM.Tree.Source.Files[LFileId].Tokens[
        LM.Tree.Source.Visible[LI].TokenIndex];
      if (LI > AFrom) and ((LFileId <> LPrevFileId) or
         (LPrev.EndPos < LTok.Start)) and
         not (LPrev.Kind in [tkLParen, tkLBracket]) and
         not (LTok.Kind in [tkRParen, tkRBracket]) then
        LSb.Append(' ');
      LSb.Append(LM.Tree.Source.Files[LFileId].TokenText(LTok));
      LPrev := LTok;
      LPrevFileId := LFileId;
    end;
    Result := LSb.ToString;
  finally
    LSb.Free;
  end;
end;

{ A declaration written over several lines, as one: `function Foo(A:
  Integer;` alone reads as a routine of one parameter. Its head ends at the
  `;` after it, outside brackets - a routine, property, variable, field or
  constant - or, for a type, at the first line end with every bracket closed
  (a class's members follow `TFoo = class(TBar,` / `IFoo)`). Its first and
  last lines are taken whole, as a one-line declaration is: `class function`
  before the name, directives after the `;`. '' when it is on one line, when
  the model's text is demoted, or when the head runs into an $I include. }
function JoinedDecl(LM: TPasSemaModel; ANameNode: Integer): string;
const
  MAX_LINES = 40;
var
  LRoot, LVis, LFileId, LCol, LLine, LStartLine, LEndLine, LDepth, LFirst,
    LLast, LHigh: Integer;
  LToSemicolon: Boolean;
  LKind: TPasTokenKind;

  function LineOfVis(AVis: Integer): Integer;
  begin
    if LM.Tree.Source.Visible[AVis].FileId <> LFileId then
      Exit(-1);
    LM.Tree.Source.Files[LFileId].OffsetToLineCol(LM.Tree.Source.Files[
      LFileId].Tokens[LM.Tree.Source.Visible[AVis].TokenIndex].Start, Result,
      LCol);
  end;

begin
  Result := '';
  if (ANameNode < 0) or (ANameNode > High(LM.Tree.Nodes)) then
    Exit;
  LRoot := LM.Tree.DeclRootOf(ANameNode);
  LVis := LM.Tree.NodeLeftmostVis(ANameNode);
  LHigh := High(LM.Tree.Source.Visible);
  if (LRoot = NIL_NODE) or (LVis < 0) or (LVis > LHigh) then
    Exit;
  LFileId := LM.Tree.Source.Visible[LVis].FileId;
  LStartLine := LineOfVis(LVis);
  LToSemicolon := LM.Tree.Nodes[LRoot].Kind <> nkTypeDecl;
  LEndLine := LStartLine;
  LLast := LVis;
  LDepth := 0;
  for var LI := LVis + 1 to LHigh do
  begin
    LKind := LM.Tree.Source.VisibleToken(LI).Kind;
    if LKind = tkEndOfFile then
      Break;
    LLine := LineOfVis(LI);
    if LLine < 0 then
      Exit;
    if (LLine > LEndLine) and ((not LToSemicolon and (LDepth <= 0)) or
       (LLine - LStartLine >= MAX_LINES)) then
      Break;
    LEndLine := LLine;
    LLast := LI;
    case LKind of
      tkLParen, tkLBracket:
        Inc(LDepth);
      tkRParen, tkRBracket:
        Dec(LDepth);
      tkSemicolon:
        if LToSemicolon and (LDepth <= 0) then
          Break;
    end;
  end;
  if LEndLine = LStartLine then
    Exit;
  LFirst := LVis;
  while (LFirst > 0) and (LineOfVis(LFirst - 1) = LStartLine) do
    Dec(LFirst);
  while (LLast < LHigh) and (LM.Tree.Source.VisibleToken(LLast + 1).Kind <>
        tkEndOfFile) and (LineOfVis(LLast + 1) = LEndLine) do
    Inc(LLast);
  Result := VisText(LM, LFirst, LLast);
end;

{ The row text of a declaration: its line, or the lines it is written over
  joined (JoinedDecl) and cut at a parameter boundary. }
function DeclRowText(LM: TPasSemaModel; ASym: Integer;
  const ALine: string): string;
begin
  Result := '';
  if (LM <> nil) and (ASym >= 0) and (ASym < LM.SymCount) then
    Result := JoinedDecl(LM, LM.Symbols[ASym].DeclNode);
  if Result <> '' then
    Result := CutDecl(Result)
  else
    Result := CleanLine(ALine);
end;

{ Is the property named at ANameNode the default array property - `property
  Items[I: Integer]: T read GetItem; default;`? `X[I]` uses it without
  writing its name, and a reference search, which follows names, finds none
  of those uses. Reads the tokens: the model must be hydrated. }
function IsDefaultArrayProperty(LM: TPasSemaModel; ANameNode: Integer): Boolean;
var
  LDecl, LChild: Integer;
begin
  Result := False;
  if ANameNode = NIL_NODE then
    Exit;
  LDecl := LM.Tree.Nodes[ANameNode].Parent;
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkPropertyDecl) then
    Exit;
  LChild := LM.Tree.Nodes[LDecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    // The trailing `default;` has no value, unlike `default alLeft`.
    if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and
       (LM.Tree.Nodes[LChild].FirstChild = NIL_NODE) and
       LM.Tree.NodeTextEquals(LChild, 'default') then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

{ ---- targets ---------------------------------------------------------------- }

function NewIds(AWs: TMcpWorkspace): TArray<TSymId>;
begin
  SetLength(Result, AWs.Analyses.Count);
  for var LIdx := 0 to High(Result) do
  begin
    Result[LIdx].Mid := -1;
    Result[LIdx].Sym := -1;
  end;
end;

function FillSymbolTarget(AWs: TMcpWorkspace; AA: TMcpAnalysis;
  ATMid, ATSym: Integer; var AT: TTarget): Boolean;
var
  LHit: TPasRefHit;
  LM: TPasSemaModel;
begin
  Result := AA.Nav.DeclHit(ATMid, ATSym, LHit);
  if not Result then
    Exit;
  LM := AA.Proj.Model(ATMid);
  AT.Kind := tkSymbol;
  AT.Name := QualifiedName(LM, ATSym);
  AT.Head := HeadOf(LM, ATSym);
  AT.DeclFile := LHit.FilePath;
  AT.DeclLine := LHit.Line;
  AT.DeclCol := LHit.Col;
  AT.Snippet := DeclRowText(LM, ATSym, LHit.Snippet);
  AT.Own := AWs.IsOwnFile(LHit.FilePath);
  AT.Ids[AA.Index].Mid := ATMid;
  AT.Ids[AA.Index].Sym := ATSym;
end;

function FillUnitTarget(AWs: TMcpWorkspace; AA: TMcpAnalysis;
  AUnitMid: Integer; var AT: TTarget): Boolean;
var
  LHit: TPasRefHit;
begin
  Result := AA.Nav.UnitDeclHit(AUnitMid, LHit);
  AT.Kind := tkUnit;
  AT.Head := 'unit';
  AT.Name := UnitNameOfFile(AA.Proj.ModelFile(AUnitMid));
  AT.DeclFile := AA.Proj.ModelFile(AUnitMid);
  if Result then
  begin
    AT.DeclLine := LHit.Line;
    AT.DeclCol := LHit.Col;
    AT.Snippet := CleanLine(LHit.Snippet);
  end
  else
  begin
    AT.DeclLine := 1;
    AT.DeclCol := 1;
  end;
  AT.Own := AWs.IsOwnFile(AT.DeclFile);
  AT.Ids[AA.Index].Mid := AUnitMid;
  Result := True;
end;

// The same target in the analyses that did not produce it: by its declaration
// site for a symbol, by file for a unit, by name for a builtin or a define.
procedure MapToOthers(AWs: TMcpWorkspace; var AT: TTarget);
var
  LMid, LTMid, LTSym: Integer;
  LName: string;
begin
  for var LA in AWs.Analyses do
  begin
    if AT.Ids[LA.Index].Mid >= 0 then
      Continue;
    case AT.Kind of
      tkSymbol:
        begin
          LMid := LA.Nav.ModelIdOf(AT.DeclFile);
          if (LMid >= 0) and LA.Proj.EnsureHydrated(LMid) and
             LA.Nav.SymbolAt(LMid, AT.DeclLine, AT.DeclCol, LTMid, LTSym, LName)
          then
          begin
            AT.Ids[LA.Index].Mid := LTMid;
            AT.Ids[LA.Index].Sym := LTSym;
          end;
        end;
      tkUnit:
        AT.Ids[LA.Index].Mid := LA.Nav.ModelIdOf(AT.DeclFile);
      tkBuiltin, tkDefine:
        AT.Ids[LA.Index].Mid := 0;
    end;
  end;
end;

// The own model of AA whose source pulls AFile in as an include ($I), -1
// for none - an include has no model of its own.
function IncluderOf(AWs: TMcpWorkspace; AA: TMcpAnalysis;
  const AFile: string): Integer;
var
  LFiles: TArray<string>;
begin
  for var LMid := 0 to AA.Proj.ModelCount - 1 do
  begin
    if not AWs.IsOwnFile(AA.Proj.ModelFile(LMid)) then
      Continue;
    LFiles := AA.Proj.Model(LMid).Tree.Source.FileNames;
    for var LFi := 1 to High(LFiles) do
      if SameText(LFiles[LFi], AFile) then
        Exit(LMid);
  end;
  Result := -1;
end;

// file + line + (name | column) -> what is there.
function ResolvePosition(AWs: TMcpWorkspace; AArgs: TJSONObject): TTarget;
var
  LFile, LName, LText: string;
  LLine, LCol, LMid, LTMid, LTSym, LRaw: Integer;
  LLines: TArray<string>;
  LInClosure, LFound: Boolean;
begin
  Result := Default(TTarget);
  Result.Ids := NewIds(AWs);
  LFile := ArgFile(AWs, AArgs);
  LLine := ArgInt(AArgs, 'line', 0);
  LName := ArgStr(AArgs, 'name');
  if LName.Contains('.') then
    LName := Copy(LName, LastDelimiter('.', LName) + 1, MaxInt);
  LCol := ArgInt(AArgs, 'column', 0);
  if not TFile.Exists(LFile) then
    raise EToolError.Create('no such file: ' + LFile);
  if LLine <= 0 then
    raise EToolError.Create('`line` is required with `file`');
  if LCol <= 0 then
  begin
    if LName = '' then
      raise EToolError.Create('give `name` (the identifier on that line) or '
        + '`column` together with `file` and `line`');
    LLines := ReadLines(LFile);
    if LLine > Length(LLines) then
      raise EToolError.CreateFmt('%s has only %d lines',
        [AWs.RelPath(LFile), Length(LLines)]);
    LCol := FindWord(LLines[LLine - 1], LName);
    if LCol = 0 then
      raise EToolError.CreateFmt('`%s` is not on line %d of %s, which reads: %s',
        [LName, LLine, AWs.RelPath(LFile), CleanLine(LLines[LLine - 1])]);
  end;
  LInClosure := False;
  LFound := False;
  for var LA in AWs.Analyses do
  begin
    LMid := LA.Nav.ModelIdOf(LFile);
    if LMid < 0 then
    begin
      // An include file: the unit that pulls it in resolves the position,
      // as it does for the rows `references` lists there.
      LMid := IncluderOf(AWs, LA, LFile);
      if LMid < 0 then
        Continue;
      LInClosure := True;
      if LA.Nav.SymbolAtFile(LMid, LFile, LLine, LCol, LTMid, LTSym, LText) then
      begin
        LFound := FillSymbolTarget(AWs, LA, LTMid, LTSym, Result);
        if LFound then
          Break;
      end;
      Continue;
    end;
    LInClosure := True;
    LA.Proj.EnsureHydrated(LMid);
    if LA.Nav.SymbolAt(LMid, LLine, LCol, LTMid, LTSym, LText) then
      LFound := FillSymbolTarget(AWs, LA, LTMid, LTSym, Result)
    else if LA.Nav.UnitAt(LMid, LLine, LCol, LTMid, LText) then
      LFound := FillUnitTarget(AWs, LA, LTMid, Result)
    else if LA.Nav.BuiltinNameAt(LMid, LLine, LCol, LText) then
    begin
      Result.Kind := tkBuiltin;
      Result.Head := 'built-in';
      Result.Name := LText;
      LFound := True;
    end
    else if LA.Nav.DefineAt(LMid, LLine, LCol, LText, LRaw) then
    begin
      Result.Kind := tkDefine;
      Result.Head := 'conditional define';
      Result.Name := LText;
      LFound := True;
    end;
    if LFound then
      Break;
  end;
  if not LInClosure then
    raise EToolError.CreateFmt('%s is not part of any analyzed project '
      + '(not reachable from the main sources through `uses`)',
      [AWs.RelPath(LFile)]);
  if not LFound then
    raise EToolError.CreateFmt('nothing resolvable at %s:%d:%d (%s) - a '
      + 'local without declaration, a keyword, or a name the analysis could '
      + 'not resolve', [AWs.RelPath(LFile), LLine, LCol, LName]);
  MapToOthers(AWs, Result);
end;

// Every declaration matching AQuery ('Bar', 'TFoo.Bar', 'Unit.TFoo.Bar',
// wildcards in the last segment), own units first, at most ALimit distinct
// declaration sites. AMore counts raw matches beyond them.
function ResolveName(AWs: TMcpWorkspace; const AQuery, AKind: string;
  AOwnOnly: Boolean; ALimit: Integer; out AMore: Integer): TArray<TTarget>;
var
  LParts, LQuals, LChain: TArray<string>;
  LName: string;
  LWild: Boolean;
  LRaw: TList<TRawMatch>;
  LMatch: TRawMatch;
  LM: TPasSemaModel;
  LA: TMcpAnalysis;
  LSeen: TDictionary<string, Integer>;
  LMoreKeys: TDictionary<string, Boolean>;
  LList: TList<TTarget>;
  LT: TTarget;
  LHit: TPasRefHit;
  LKey, LFile: string;
  LIdx, LSeenIdx: Integer;
  LOk: Boolean;
begin
  AMore := 0;
  LParts := AQuery.Split(['.']);
  if Length(LParts) = 0 then
    raise EToolError.Create('empty symbol name');
  LName := LowerCase(StripGenerics(LParts[High(LParts)]));
  LWild := (Pos('*', LName) > 0) or (Pos('?', LName) > 0);
  LQuals := Copy(LParts, 0, High(LParts));
  for LIdx := 0 to High(LQuals) do
    LQuals[LIdx] := LowerCase(StripGenerics(LQuals[LIdx]));

  LRaw := TList<TRawMatch>.Create;
  LSeen := TDictionary<string, Integer>.Create;
  LMoreKeys := TDictionary<string, Boolean>.Create;
  LList := TList<TTarget>.Create;
  try
    for LA in AWs.Analyses do
      for var LMid := 0 to LA.Proj.ModelCount - 1 do
      begin
        LFile := LA.Proj.ModelFile(LMid);
        if AOwnOnly and not AWs.IsOwnFile(LFile) then
          Continue;
        LM := LA.Proj.Model(LMid);
        for var LSym := 0 to LM.SymCount - 1 do
        begin
          if LWild then
          begin
            if not WildMatch(LName, LM.Symbols[LSym].NameLower) then
              Continue;
          end
          else if LM.Symbols[LSym].NameLower <> LName then
            Continue;
          if not IsDeclSymbol(LM, LSym) or not KindMatches(LM, LSym, AKind) then
            Continue;
          if Length(LQuals) > 0 then
          begin
            // The qualifiers must be the END of unit-name + owner chain.
            LChain := UnitNameOfFile(LFile).Split(['.']);
            for var LSeg in OwnerOf(LM, LM.Symbols[LSym].Scope).Split(['.']) do
              if LSeg <> '' then
                LChain := LChain + [StripGenerics(LSeg)];
            LOk := Length(LQuals) <= Length(LChain);
            if LOk then
              for LIdx := 0 to High(LQuals) do
                if not SameText(LQuals[LIdx],
                   LChain[Length(LChain) - Length(LQuals) + LIdx]) then
                begin
                  LOk := False;
                  Break;
                end;
            if not LOk then
              Continue;
          end;
          LMatch.Analysis := LA.Index;
          LMatch.Mid := LMid;
          LMatch.Sym := LSym;
          LMatch.ModelFile := LFile;
          LMatch.Own := AWs.IsOwnFile(LFile);
          LRaw.Add(LMatch);
        end;
      end;

    LRaw.Sort(TComparer<TRawMatch>.Construct(
      function(const L, R: TRawMatch): Integer
      begin
        Result := Ord(R.Own) - Ord(L.Own);
        if Result = 0 then
          Result := CompareText(L.ModelFile, R.ModelFile);
        if Result = 0 then
          Result := L.Sym - R.Sym;
        if Result = 0 then
          Result := L.Analysis - R.Analysis;
      end));

    // Declaration sites only for the ones shown: a site costs a rehydration
    // of a demoted library unit, and `Create` matches 25000 times on the
    // client group. The rest are counted by model file + declaration node,
    // which the same unit parsed alike in two analyses shares - an estimate.
    for LIdx := 0 to LRaw.Count - 1 do
    begin
      LMatch := LRaw[LIdx];
      LA := AWs.Analyses[LMatch.Analysis];
      if LList.Count >= ALimit then
      begin
        LKey := LowerCase(LMatch.ModelFile) + '|' + IntToStr(
          LA.Proj.Model(LMatch.Mid).Symbols[LMatch.Sym].DeclNode);
        if not LMoreKeys.ContainsKey(LKey) then
        begin
          LMoreKeys.Add(LKey, True);
          Inc(AMore);
        end;
        Continue;
      end;
      if not LA.Nav.DeclHit(LMatch.Mid, LMatch.Sym, LHit) then
        Continue;
      LKey := LowerCase(LHit.FilePath) + ':' + IntToStr(LHit.Line) + ':' +
        IntToStr(LHit.Col);
      if LSeen.TryGetValue(LKey, LSeenIdx) then
      begin
        LT := LList[LSeenIdx];
        LT.Ids[LA.Index].Mid := LMatch.Mid;
        LT.Ids[LA.Index].Sym := LMatch.Sym;
        LList[LSeenIdx] := LT;
        Continue;
      end;
      LT := Default(TTarget);
      LT.Ids := NewIds(AWs);
      if FillSymbolTarget(AWs, LA, LMatch.Mid, LMatch.Sym, LT) then
      begin
        LSeen.Add(LKey, LList.Count);
        LList.Add(LT);
      end;
    end;

    // No declaration of that name: maybe it names a unit.
    if (LList.Count = 0) and not LWild and (AKind = '') then
      for LA in AWs.Analyses do
      begin
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
          if SameText(UnitNameOfFile(LA.Proj.ModelFile(LMid)), AQuery) then
          begin
            LT := Default(TTarget);
            LT.Ids := NewIds(AWs);
            FillUnitTarget(AWs, LA, LMid, LT);
            MapToOthers(AWs, LT);
            LList.Add(LT);
            Break;
          end;
        if LList.Count > 0 then
          Break;
      end;
    Result := LList.ToArray;
  finally
    LList.Free;
    LSeen.Free;
    LMoreKeys.Free;
    LRaw.Free;
  end;
end;

function DescribeTarget(AWs: TMcpWorkspace; const AT: TTarget): string;
begin
  case AT.Kind of
    tkBuiltin, tkDefine:
      Result := Format('%s (%s)', [AT.Name, AT.Head]);
  else
    Result := Format('%s:%d  %s (%s)  %s', [AWs.RelPath(AT.DeclFile),
      AT.DeclLine, AT.Name, AT.Head, AT.Snippet]);
  end;
  // PasTree reads a unit with no source from its .dcu; the path is a label,
  // not a file anyone can open.
  if SameText(TPath.GetExtension(AT.DeclFile), '.dcu') then
    Result := Result + '  [compiled unit, no source]';
end;

{ ---- what the index does not hold ---------------------------------------------- }

// What was searched, for an answer that found nothing: `the 80 units indexed
// - what pastree-mcp.dproj compiles: 9 of its own, 71 from libraries`.
function IndexScope(AWs: TMcpWorkspace): string;
var
  LAll, LOwn: Integer;
begin
  LAll := AWs.IndexedUnitCount(LOwn);
  Result := Format('the %d units indexed - what %s %s: %d of %s own, %d from '
    + 'libraries', [LAll, AWs.IndexedProjects, IfThen(Length(AWs.Members) = 1,
    'compiles', 'compile'), LOwn, IfThen(Length(AWs.Members) = 1, 'its',
    'their'), LAll - LOwn]);
end;

type
  // One file outside the index that writes a name (OutsideIndexNote).
  TWordSite = record
    FilePath: string;
    Line: Integer;
    Text: string;
    Score: Integer;        // of its line, see OutsideIndexNote
  end;

{ Does the line that writes a name at ACol declare it? A routine, property
  or unit keyword before it (a qualifier - `procedure TFoo.Bar` - skipped),
  or the name first on its line (or after a `,` of a list) and followed by
  `=` or a `:` that is not `:=`. A guess from text - a `case` label reads as
  a field - that only orders the rows. }
function DeclaresAt(const ALine: string; ACol, ALen: Integer): Boolean;
const
  HEADS: array[0..9] of string = ('procedure', 'function', 'constructor',
    'destructor', 'property', 'operator', 'unit', 'program', 'library',
    'package');
var
  LBefore, LAfter: string;
  LAt: Integer;
begin
  LBefore := LowerCase(Trim(Copy(ALine, 1, ACol - 1)));
  while LBefore.EndsWith('.') do
  begin
    LBefore := Copy(LBefore, 1, Length(LBefore) - 1);
    while (LBefore <> '') and IsIdentChar(LBefore[Length(LBefore)]) do
      Delete(LBefore, Length(LBefore), 1);
    LBefore := TrimRight(LBefore);
  end;
  LAt := Length(LBefore);
  while (LAt > 0) and IsIdentChar(LBefore[LAt]) do
    Dec(LAt);
  for var LHead in HEADS do
    if Copy(LBefore, LAt + 1, MaxInt) = LHead then
      Exit(True);
  LAfter := TrimLeft(Copy(ALine, ACol + ALen, MaxInt));
  Result := ((LBefore = '') or LBefore.EndsWith(',')) and
    (LAfter.StartsWith('=') or (LAfter.StartsWith(':') and
    not LAfter.StartsWith(':=')));
end;

{ ALines[AIdx] and, while its parentheses are open, the lines after it, as one
  - JoinedDecl for a file no model holds, so read as text: a `//` comment is
  cut off each line, and a parenthesis in a string or a brace comment can
  end the join early or late. At most MAX_LINES lines. }
function JoinedTextLine(const ALines: TArray<string>; AIdx: Integer): string;
const
  MAX_LINES = 20;
var
  LDepth, LCut: Integer;
  LLine: string;
begin
  Result := '';
  LDepth := 0;
  for var LIdx := AIdx to Min(High(ALines), AIdx + MAX_LINES - 1) do
  begin
    LLine := ALines[LIdx];
    LCut := Pos('//', LLine);
    if LCut > 0 then
      LLine := Copy(LLine, 1, LCut - 1);
    Result := Result + ' ' + Trim(LLine);
    for var LCh in LLine do
      if LCh = '(' then
        Inc(LDepth)
      else if LCh = ')' then
        Dec(LDepth);
    if LDepth <= 0 then
      Break;
  end;
  Result := CutDecl(CleanLine(Result, MaxInt).Replace('( ', '(').Replace(' )',
    ')'));
end;

{ Where the Pascal sources the index does not hold write a name that no
  declaration matches (TMcpWorkspace.UnindexedSources). A unit no project
  uses is invisible to every tool, and "no declaration matches" alone sends
  the agent to conclude there is none - a session on PasTree lost the tree
  checker and the test kit that way, both in units its project did not use.
  Every segment of a qualified name must be in the file. Per file, the line
  that best says where the name is, by score: 4 declares the dotted name
  (`unit A.B;`, `procedure TFoo.Bar`), 3 declares its last segment
  (DeclaresAt), 2 writes the dotted name, 1 writes the last segment - a
  file whose best is 1 for a qualified name only has the words somewhere,
  and is left out. A declaration's line comes with the lines its parameter
  list goes on over (JoinedTextLine). The files are read until SCAN_MS runs
  out, and the answer says so. '' for a wildcard query; with AAlways, a line
  saying that nothing was found, else '' then too. }
function OutsideIndexNote(AWs: TMcpWorkspace; const AQuery: string;
  AAlways: Boolean): string;
const
  SCAN_MS = 2000;
  MAX_FILES = 5;
var
  LSegs, LLower: TArray<string>;
  LFiles, LLines: TArray<string>;
  LSites: TList<TWordSite>;
  LSite: TWordSite;
  LText, LTextLower, LWord, LDotted: string;
  LSearched, LCol, LScore: Integer;
  LAll: Boolean;
  LSW: TStopwatch;
  LSb: TStringBuilder;
begin
  Result := '';
  if (AQuery = '') or AQuery.Contains('*') or AQuery.Contains('?') then
    Exit;
  LSegs := nil;
  LLower := nil;
  for var LSeg in AQuery.Split(['.']) do
    if StripGenerics(Trim(LSeg)) <> '' then
    begin
      LSegs := LSegs + [StripGenerics(Trim(LSeg))];
      LLower := LLower + [LowerCase(StripGenerics(Trim(LSeg)))];
    end;
  if Length(LSegs) = 0 then
    Exit;
  LWord := LSegs[High(LSegs)];
  LDotted := '';
  if Length(LSegs) > 1 then
    LDotted := string.Join('.', LSegs);
  LFiles := AWs.UnindexedSources;
  LSearched := 0;
  LSW := TStopwatch.StartNew;
  LSites := TList<TWordSite>.Create;
  LSb := TStringBuilder.Create;
  try
    for var LFile in LFiles do
    begin
      if LSW.ElapsedMilliseconds > SCAN_MS then
        Break;
      Inc(LSearched);
      try
        LText := TFile.ReadAllText(LFile);   // BOM-aware
      except
        Continue;
      end;
      LTextLower := LowerCase(LText);
      LAll := True;
      for var LSeg in LLower do
        if Pos(LSeg, LTextLower) = 0 then
        begin
          LAll := False;
          Break;
        end;
      if not LAll then
        Continue;
      LLines := LText.Split([#13#10, #10, #13]);
      LSite := Default(TWordSite);
      for var LIdx := 0 to High(LLines) do
      begin
        LScore := 0;
        LCol := 0;
        if LDotted <> '' then
          LCol := FindWord(LLines[LIdx], LDotted);
        if LCol > 0 then
          LScore := IfThen(DeclaresAt(LLines[LIdx], LCol, Length(LDotted)), 4, 2)
        else
        begin
          LCol := FindWord(LLines[LIdx], LWord);
          if LCol > 0 then
            LScore := IfThen(DeclaresAt(LLines[LIdx], LCol, Length(LWord)), 3, 1);
        end;
        if LScore > LSite.Score then
        begin
          LSite.FilePath := LFile;
          LSite.Line := LIdx + 1;
          LSite.Score := LScore;
          if LScore >= 3 then
            LSite.Text := JoinedTextLine(LLines, LIdx)
          else
            LSite.Text := CleanLine(LLines[LIdx]);
          if LScore = 4 then
            Break;
        end;
      end;
      if (LSite.Score > 1) or ((LSite.Score = 1) and (LDotted = '')) then
        LSites.Add(LSite);
    end;
    LSites.Sort(TComparer<TWordSite>.Construct(
      function(const L, R: TWordSite): Integer
      begin
        Result := R.Score - L.Score;
        if Result = 0 then
          Result := CompareText(L.FilePath, R.FilePath);
      end));
    if LSites.Count > 0 then
    begin
      LSb.AppendLine(Format('`%s` is written in %d file(s) that no indexed '
        + 'project uses - no tool here sees them:', [AQuery, LSites.Count]));
      for var LIdx := 0 to Min(LSites.Count, MAX_FILES) - 1 do
        LSb.AppendLine(Format('  %s:%d  %s', [AWs.RelPath(LSites[LIdx].FilePath),
          LSites[LIdx].Line, LSites[LIdx].Text]));
      if LSites.Count > MAX_FILES then
        LSb.AppendLine(Format('  ... and %d more files',
          [LSites.Count - MAX_FILES]));
    end
    else if AAlways then
      LSb.AppendLine(Format('no Pascal file outside them writes `%s` either '
        + '(%d searched, under the group directory and on its projects'' '
        + 'search paths)', [AQuery, LSearched]));
    if (LSearched < Length(LFiles)) and ((LSites.Count > 0) or AAlways) then
      LSb.AppendLine(Format('(%d of %d files outside the index searched - the '
        + 'search stops after %d s)', [LSearched, Length(LFiles),
        SCAN_MS div 1000]));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
    LSites.Free;
  end;
end;

// The refusal of a name no declaration matches, for every tool that takes
// `symbol`: what was searched, and where the name is written outside it.
function NoSuchDeclaration(AWs: TMcpWorkspace; const ASymbol: string): string;
var
  LNote: string;
begin
  Result := Format('no declaration named `%s` among %s - try `find` with a '
    + 'wildcard: *%s*; a local or a parameter is addressed by `file` + '
    + '`line` + `name`', [ASymbol, IndexScope(AWs),
    StripGenerics(ASymbol.Split(['.'])[High(ASymbol.Split(['.']))])]);
  LNote := OutsideIndexNote(AWs, ASymbol, False);
  if LNote <> '' then
    Result := Result + sLineBreak + LNote;
end;

// The ONE declaration a name means, refusing an ambiguous one with the
// candidates listed.
function ResolveNamed(AWs: TMcpWorkspace; const ASymbol,
  AKind: string): TTarget;
var
  LCands: TArray<TTarget>;
  LMore: Integer;
  LSb: TStringBuilder;
begin
  LCands := ResolveName(AWs, ASymbol, AKind, False, 12, LMore);
  if Length(LCands) = 0 then
    raise EToolError.Create(NoSuchDeclaration(AWs, ASymbol));
  if Length(LCands) = 1 then
  begin
    Result := LCands[0];
    MapToOthers(AWs, Result);
    Exit;
  end;
  LSb := TStringBuilder.Create;
  try
    LSb.AppendLine(Format('`%s` is ambiguous - %d declarations%s. Qualify it '
      + '(Unit.Type.Member), add `kind`, or pass `file` + `line` + `name` of '
      + 'the one you mean:', [ASymbol, Length(LCands) + LMore,
      IfThen(LMore > 0, ' (first ' + IntToStr(Length(LCands)) + ')', '')]));
    for var LC in LCands do
      LSb.AppendLine('  ' + DescribeTarget(AWs, LC));
    raise EToolError.Create(LSb.ToString.TrimRight);
  finally
    LSb.Free;
  end;
end;

// The ONE target a search is about: from file+line+name, or from `symbol`.
function ResolveOne(AWs: TMcpWorkspace; AArgs: TJSONObject): TTarget;
begin
  if ArgStr(AArgs, 'file') <> '' then
    Exit(ResolvePosition(AWs, AArgs));
  if ArgStr(AArgs, 'symbol') = '' then
    raise EToolError.Create('give `symbol` (a name like TFoo.Bar) or `file` + '
      + '`line` + `name`');
  Result := ResolveNamed(AWs, ArgStr(AArgs, 'symbol'), ArgStr(AArgs, 'kind'));
end;

{ ---- hits ------------------------------------------------------------------- }

type
  { The merged rows of one search across every analysis, de-duplicated by
    site. Rows in a compiled unit with no source (PasTree reads a .dcu and
    names the model after it) are counted, not kept: the agent can open no
    such file, and TStringList alone has 400 of them on the client group. }
  THitSet = class
  private
    FWs: TMcpWorkspace;
    FList: TList<THit>;
    FSeen: TDictionary<string, Boolean>;
    FCompiled: Integer;
    FForms: Integer;
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    procedure Add(const AHit: TPasRefHit; const ATag: string = '');
    // A form file's site, under its component (FormObjectPath).
    procedure AddForm(const ASite: TPasFormSite);
    function Count: Integer;
    function FormCount: Integer;
    // Own files first, then libraries; by file, line, column.
    function Sorted: TArray<THit>;
    property Compiled: Integer read FCompiled;
  end;

constructor THitSet.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FList := TList<THit>.Create;
  FSeen := TDictionary<string, Boolean>.Create;
end;

destructor THitSet.Destroy;
begin
  FSeen.Free;
  FList.Free;
  inherited;
end;

procedure THitSet.Add(const AHit: TPasRefHit; const ATag: string);
var
  LKey: string;
  LH: THit;
begin
  if AHit.FilePath = '' then
    Exit;
  LKey := LowerCase(AHit.FilePath) + ':' + IntToStr(AHit.Line) + ':' +
    IntToStr(AHit.Col);
  if FSeen.ContainsKey(LKey) then
    Exit;
  FSeen.Add(LKey, True);
  if SameText(TPath.GetExtension(AHit.FilePath), '.dcu') then
  begin
    Inc(FCompiled);
    Exit;
  end;
  LH.FilePath := AHit.FilePath;
  LH.Line := AHit.Line;
  LH.Col := AHit.Col;
  LH.Snippet := AHit.Snippet;
  LH.Tag := ATag;
  LH.Own := FWs.IsOwnFile(AHit.FilePath);
  FList.Add(LH);
end;

{ The component a form file's site belongs to, as the form designer names it
  from the root down: `btnSave`, `fraName1.btnClear` inside an inline frame,
  `frmMain (root)` for the form or module itself. An unnamed object (a menu
  item written without a Name) by its class. A site in an object's own
  header (`object btnSave: TButton`) names that object already and goes one
  level out, as a Pascal row on a declaration's name line does - '' when
  that is the root: the file level. The document is the one the binder
  read, from PasDfmLoad's cache. }
function FormObjectPath(const ASite: TPasFormSite): string;
var
  LHandle: IPasDfmDoc;
  LDoc: TPasDfmDoc;
  LObj: Integer;
  LName: string;
begin
  Result := ASite.ObjectName;
  LHandle := PasDfmLoad(ASite.FilePath);
  if LHandle = nil then
    Exit;
  LDoc := LHandle.Doc;
  LObj := ASite.ObjIndex;
  if (LObj < 0) or (LObj > High(LDoc.Objects)) then
    Exit;
  if ASite.PropName = '' then
  begin
    LObj := LDoc.Objects[LObj].Parent;
    if (LObj < 0) or (LDoc.Objects[LObj].Parent < 0) then
      Exit('');
  end
  else if LDoc.Objects[LObj].Parent < 0 then
    Exit(LDoc.ObjectName(LObj) + ' (root)');
  Result := '';
  while (LObj >= 0) and (LDoc.Objects[LObj].Parent >= 0) do
  begin
    LName := LDoc.ObjectName(LObj);
    if LName = '' then
      LName := LDoc.ObjectClassName(LObj);
    if Result = '' then
      Result := LName
    else
      Result := LName + '.' + Result;
    LObj := LDoc.Objects[LObj].Parent;
  end;
end;

procedure THitSet.AddForm(const ASite: TPasFormSite);
var
  LKey: string;
  LH: THit;
begin
  if ASite.FilePath = '' then
    Exit;
  LKey := LowerCase(ASite.FilePath) + ':' + IntToStr(ASite.Line) + ':' +
    IntToStr(ASite.Col);
  if not FSeen.TryAdd(LKey, True) then
    Exit;
  LH := Default(THit);
  LH.FilePath := ASite.FilePath;
  LH.Line := ASite.Line;
  LH.Col := ASite.Col;
  LH.Snippet := ASite.Snippet;
  LH.Own := FWs.IsOwnFile(ASite.FilePath);
  LH.Where := FormObjectPath(ASite);
  if ASite.IsBinary then
    LH.FileNote := 'binary - lines of its text conversion';
  // The line binds the ancestor's method of the name for the ancestor's own
  // forms too: a rename cannot rewrite it.
  if ASite.Via = fsvAncestor then
    LH.Tag := 'ancestor''s form';
  FList.Add(LH);
  Inc(FForms);
end;

function THitSet.Count: Integer;
begin
  Result := FList.Count;
end;

function THitSet.FormCount: Integer;
begin
  Result := FForms;
end;

function THitSet.Sorted: TArray<THit>;
begin
  Result := FList.ToArray;
  TArray.Sort<THit>(Result, TComparer<THit>.Construct(
    function(const L, R: THit): Integer
    begin
      Result := Ord(R.Own) - Ord(L.Own);
      if Result = 0 then
        Result := CompareText(L.FilePath, R.FilePath);
      if Result = 0 then
        Result := L.Line - R.Line;
      if Result = 0 then
        Result := L.Col - R.Col;
    end));
end;

{ ---- where a row sits --------------------------------------------------------- }

type
  // A routine or type declaration of one file, as the span of its tokens.
  TEnclosingSpan = record
    FromLine, FromCol, ToLine, ToCol: Integer;
    NameLine: Integer;     // the line its name is written on
    Name: string;          // TFoo.Save, TFoo.Save.Helper, TOuter.TInner
    Outer: Integer;        // the span around it, in the same list; -1 if none
  end;

  { The routine or type a row sits in (SPEC 9.2.1): `TFoo.Save` for a
    statement, `TFoo` for a member declaration, `TFoo.Save.Helper` inside a
    nested routine, nothing at unit level. "Who uses X" is mostly answered by
    that name alone - no file opened to see which method a line belongs to.
    Read from the public tree, once per file per call: PasTree's own
    RTEnclosingRoutine is private, and it is only this climb over
    Nodes[].Parent to an nkRoutine. }
  TEnclosing = class
  private
    FWs: TMcpWorkspace;
    FByFile: TObjectDictionary<string, TList<TEnclosingSpan>>;
    function ModelOf(const AFile: string): TPasSemaModel;
    function SpansOf(const AFile: string): TList<TEnclosingSpan>;
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    { The name of the innermost span around ALine:ACol; '' when there is
      none. ASkipNameLine: a row on the line that names that declaration (a
      routine's header, `TFoo = class(...)`) shows the name already and gets
      the next one out instead - a method declaration then names its class. }
    function NameAt(const AFile: string; ALine, ACol: Integer;
      ASkipNameLine: Boolean): string;
  end;

// File and 1-based line and column of visible token AVis.
function VisPos(LM: TPasSemaModel; AVis: Integer; out AFileId, ALine,
  ACol: Integer): Boolean;
var
  LTok: Integer;
begin
  Result := False;
  if (AVis < 0) or (AVis > High(LM.Tree.Source.Visible)) then
    Exit;
  AFileId := LM.Tree.Source.Visible[AVis].FileId;
  LTok := LM.Tree.Source.Visible[AVis].TokenIndex;
  if (AFileId < 0) or (AFileId > High(LM.Tree.Source.Files)) or (LTok < 0) or
     (LTok > High(LM.Tree.Source.Files[AFileId].Tokens)) then
    Exit;
  LM.Tree.Source.Files[AFileId].OffsetToLineCol(
    LM.Tree.Source.Files[AFileId].Tokens[LTok].Start, ALine, ACol);
  Result := True;
end;

// A routine's or type's own name as written, generic parameters left out:
// `Save`, `TFoo.Save` for a method body, `TFoo`; '' for a nameless header.
// ANameVis: the visible token of its first segment, ALastVis of its last -
// `Save` in `TFoo.Save`.
function DeclName(LM: TPasSemaModel; ANode: Integer; out ANameVis,
  ALastVis: Integer): string; overload;
var
  LChild, LPrev: Integer;
begin
  Result := '';
  ANameVis := -1;
  ALastVis := -1;
  LChild := LM.Tree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case LM.Tree.Nodes[LChild].Kind of
      nkIdent:
        begin
          // A parameterless function's result type is an nkIdent too, told
          // apart by the colon before it (as PasTree.Outline does).
          LPrev := LM.Tree.NodeLeftmostVis(LChild) - 1;
          if (LPrev >= 0) and (LPrev <= High(LM.Tree.Source.Visible)) and
             (LM.Tree.Source.VisibleToken(LPrev).Kind = tkColon) then
            Break;
          if Result = '' then
            ANameVis := LM.Tree.NodeLeftmostVis(LChild)
          else
            Result := Result + '.';
          ALastVis := LM.Tree.NodeLeftmostVis(LChild);
          Result := Result + LM.Tree.NodeText(LChild);
          // A type's name is one segment; an alias's next nkIdent is its type.
          if LM.Tree.Nodes[ANode].Kind = nkTypeDecl then
            Break;
        end;
      nkGenericParams, nkAttrGroup:
        ;
    else
      Break;
    end;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

function DeclName(LM: TPasSemaModel; ANode: Integer;
  out ANameVis: Integer): string; overload;
var
  LLastVis: Integer;
begin
  Result := DeclName(LM, ANode, ANameVis, LLastVis);
end;

// The index of AFile among the files a model was read from (its main file
// and its includes); -1 when it is not one of them.
function FileIdOf(LM: TPasSemaModel; const AFile: string): Integer;
begin
  for var LIdx := 0 to High(LM.Tree.Source.FileNames) do
    if SameText(LM.Tree.Source.FileNames[LIdx], AFile) then
      Exit(LIdx);
  Result := -1;
end;

// The nearest routine or type declaration around ANode, NIL_NODE at unit
// level. An anonymous method is not one: its lines belong to the routine
// that writes it.
function OuterDecl(LM: TPasSemaModel; ANode: Integer): Integer;
begin
  Result := LM.Tree.Nodes[ANode].Parent;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> nkRoutine) and
        (LM.Tree.Nodes[Result].Kind <> nkTypeDecl) do
    Result := LM.Tree.Nodes[Result].Parent;
end;

constructor TEnclosing.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FByFile := TObjectDictionary<string, TList<TEnclosingSpan>>.Create(
    [doOwnsValues]);
end;

destructor TEnclosing.Destroy;
begin
  FByFile.Free;
  inherited;
end;

// The model to read AFile's spans from: its owner analysis' for an own file
// (the one diagnostics report from), else one already hydrated - a library
// unit is demoted after every build, and the search that found the row has
// hydrated it in its own analysis - else the first, hydrated now.
function TEnclosing.ModelOf(const AFile: string): TPasSemaModel;
var
  LFirst: TMcpAnalysis;
  LFirstMid, LMid, LOwner: Integer;
begin
  Result := nil;
  LOwner := FWs.OwnerAnalysis(AFile);
  if LOwner >= 0 then
  begin
    LMid := FWs.Analyses[LOwner].Nav.ModelIdOf(AFile);
    if (LMid >= 0) and FWs.Analyses[LOwner].Proj.EnsureHydrated(LMid) then
      Exit(FWs.Analyses[LOwner].Proj.Model(LMid));
  end;
  LFirst := nil;
  LFirstMid := -1;
  for var LA in FWs.Analyses do
  begin
    LMid := LA.Nav.ModelIdOf(AFile);
    if LMid < 0 then
      Continue;
    if not LA.Proj.Model(LMid).Demoted then
      Exit(LA.Proj.Model(LMid));
    if LFirst = nil then
    begin
      LFirst := LA;
      LFirstMid := LMid;
    end;
  end;
  if (LFirst <> nil) and LFirst.Proj.EnsureHydrated(LFirstMid) then
    Result := LFirst.Proj.Model(LFirstMid);
end;

function TEnclosing.SpansOf(const AFile: string): TList<TEnclosingSpan>;
var
  LM: TPasSemaModel;
  LFileId, LFromFile, LToFile, LNameFile, LNameVis, LCol, LUp: Integer;
  LSpan: TEnclosingSpan;
  LNodes: TList<Integer>;
  LIndexOf: TDictionary<Integer, Integer>;
  LNames: TDictionary<Integer, string>;

  // Qualified by the declarations around it, outer first.
  function FullName(ANode: Integer): string;
  var
    LOwn, LOuterName: string;
    LVis, LOuter: Integer;
  begin
    if LNames.TryGetValue(ANode, Result) then
      Exit;
    LOwn := DeclName(LM, ANode, LVis);
    LOuter := OuterDecl(LM, ANode);
    LOuterName := '';
    if LOuter <> NIL_NODE then
      LOuterName := FullName(LOuter);
    if (LOwn = '') or (LOuterName = '') then
      Result := LOwn
    else
      Result := LOuterName + '.' + LOwn;
    LNames.Add(ANode, Result);
  end;

begin
  if FByFile.TryGetValue(LowerCase(AFile), Result) then
    Exit;
  Result := TList<TEnclosingSpan>.Create;
  FByFile.Add(LowerCase(AFile), Result);
  LM := ModelOf(AFile);
  if LM = nil then
    Exit;
  LFileId := FileIdOf(LM, AFile);
  if LFileId < 0 then
    Exit;
  LNodes := TList<Integer>.Create;
  LIndexOf := TDictionary<Integer, Integer>.Create;
  LNames := TDictionary<Integer, string>.Create;
  try
    for var LNode := 0 to High(LM.Tree.Nodes) do
    begin
      if (LM.Tree.Nodes[LNode].Kind <> nkRoutine) and
         (LM.Tree.Nodes[LNode].Kind <> nkTypeDecl) then
        Continue;
      // Both ends in this file: a declaration split over an $I include is
      // not worth reconstructing (NodeSpanText gives up on it too).
      if not VisPos(LM, LM.Tree.NodeLeftmostVis(LNode), LFromFile,
         LSpan.FromLine, LSpan.FromCol) or (LFromFile <> LFileId) or
         not VisPos(LM, LM.Tree.Nodes[LNode].LastToken, LToFile, LSpan.ToLine,
         LSpan.ToCol) or (LToFile <> LFileId) then
        Continue;
      LSpan.Name := FullName(LNode);
      if LSpan.Name = '' then
        Continue;
      DeclName(LM, LNode, LNameVis);
      if not VisPos(LM, LNameVis, LNameFile, LSpan.NameLine, LCol) then
        LSpan.NameLine := LSpan.FromLine;
      LSpan.Outer := -1;
      LIndexOf.Add(LNode, Result.Count);
      LNodes.Add(LNode);
      Result.Add(LSpan);
    end;
    // Once every span is known: a node is not always allocated after the
    // one around it.
    for var LIdx := 0 to Result.Count - 1 do
      if LIndexOf.TryGetValue(OuterDecl(LM, LNodes[LIdx]), LUp) then
      begin
        LSpan := Result[LIdx];
        LSpan.Outer := LUp;
        Result[LIdx] := LSpan;
      end;
  finally
    LNames.Free;
    LIndexOf.Free;
    LNodes.Free;
  end;
end;

function TEnclosing.NameAt(const AFile: string; ALine, ACol: Integer;
  ASkipNameLine: Boolean): string;
var
  LList: TList<TEnclosingSpan>;
  LSpans: TArray<TEnclosingSpan>;
  LCount, LBest: Integer;
begin
  Result := '';
  LList := SpansOf(AFile);
  LCount := LList.Count;
  LSpans := LList.List;   // the list's own array, not a copy
  LBest := -1;
  // Declarations nest, so of the spans around the row the innermost is the
  // one that starts last.
  for var LIdx := 0 to LCount - 1 do
    if ((ALine > LSpans[LIdx].FromLine) or ((ALine = LSpans[LIdx].FromLine) and
        (ACol >= LSpans[LIdx].FromCol))) and
       ((ALine < LSpans[LIdx].ToLine) or ((ALine = LSpans[LIdx].ToLine) and
        (ACol <= LSpans[LIdx].ToCol))) and
       ((LBest < 0) or (LSpans[LIdx].FromLine > LSpans[LBest].FromLine) or
        ((LSpans[LIdx].FromLine = LSpans[LBest].FromLine) and
         (LSpans[LIdx].FromCol > LSpans[LBest].FromCol))) then
      LBest := LIdx;
  if (LBest >= 0) and ASkipNameLine and (LSpans[LBest].NameLine = ALine) then
    LBest := LSpans[LBest].Outer;
  if LBest >= 0 then
    Result := LSpans[LBest].Name;
end;

// Grouped by file, one trimmed line per row:
//   uMain.pas
//     120  LFoo.Bar(1);
// A tagged row (related) reads `120  [TFoo override]  <line>`, and leaves the
// line out when it repeats the previous row's: an override chain is one
// signature written 250 times, and on the client group that was 60% of the
// answer. ATagOnly: the tag is the whole row (descendants).
// AEnclosing: rows are grouped under the routine or type they sit in, its
// name printed once for a run of rows - a row outside any stays at the file
// level:
//   uMain.pas
//     TMain.Save
//       120  LFoo.Bar(1);
//       135  LFoo.Bar(2);
//     300  LFoo: TFoo;
// A form file's row goes under its component (THit.Where) the same way:
//   uMain.dfm
//     btnSave
//       40  OnClick = btnSaveClick
procedure AppendHitsByFile(AWs: TMcpWorkspace; ASb: TStringBuilder;
  const AHits: TArray<THit>; ALimit: Integer; ATagOnly: Boolean = False;
  AEnclosing: TEnclosing = nil);
var
  LFile, LLine, LPrev, LWhere, LLastWhere, LIndent: string;
  LShown, LSame, LRowLine: Integer;
begin
  LFile := '';
  LPrev := '';
  LLastWhere := '';
  LShown := 0;
  LSame := 0;
  LRowLine := 0;
  for var LH in AHits do
  begin
    if LShown >= ALimit then
      Break;
    // A line naming the symbol twice is one row: a second one reads as a
    // second use site. The header still counts occurrences.
    if not ATagOnly and (LH.Tag = '') and (LShown > 0) and
       SameText(LH.FilePath, LFile) and (LH.Line = LRowLine) then
    begin
      Inc(LSame);
      Continue;
    end;
    LRowLine := LH.Line;
    if not SameText(LH.FilePath, LFile) then
    begin
      LFile := LH.FilePath;
      if LH.FileNote <> '' then
        ASb.AppendLine(AWs.RelPath(LFile) + '  (' + LH.FileNote + ')')
      else
        ASb.AppendLine(AWs.RelPath(LFile));
      LLastWhere := '';
    end;
    LIndent := '  ';
    if (AEnclosing <> nil) or (LH.Where <> '') then
    begin
      if LH.Where <> '' then
        LWhere := LH.Where
      else
        LWhere := AEnclosing.NameAt(LH.FilePath, LH.Line, LH.Col, True);
      if LWhere <> '' then
      begin
        if LWhere <> LLastWhere then
          ASb.AppendLine('  ' + LWhere);
        LIndent := '    ';
      end;
      LLastWhere := LWhere;
    end;
    if ATagOnly then
      ASb.AppendLine(Format('%s%d  %s', [LIndent, LH.Line, LH.Tag]))
    else if LH.Tag <> '' then
    begin
      LLine := CleanLine(LH.Snippet);
      if LLine = LPrev then
        ASb.AppendLine(Format('%s%d  [%s]', [LIndent, LH.Line, LH.Tag]))
      else
        ASb.AppendLine(Format('%s%d  [%s]  %s', [LIndent, LH.Line, LH.Tag,
          LLine]));
      LPrev := LLine;
    end
    else
      ASb.AppendLine(Format('%s%d  %s', [LIndent, LH.Line,
        CleanLine(LH.Snippet)]));
    Inc(LShown);
  end;
  if Length(AHits) - LSame > LShown then
    ASb.AppendLine(Format('... %d more (raise `limit`)',
      [Length(AHits) - LSame - LShown]));
end;

function FileCount(const AHits: TArray<THit>): Integer;
var
  LSet: TDictionary<string, Boolean>;
begin
  LSet := TDictionary<string, Boolean>.Create;
  try
    for var LH in AHits do
      LSet.AddOrSetValue(LowerCase(LH.FilePath), True);
    Result := LSet.Count;
  finally
    LSet.Free;
  end;
end;

{ ---- tools ------------------------------------------------------------------ }

function ToolStatus(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
begin
  Result := AWs.StatusText;
end;

function ToolFind(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LQuery, LKind: string;
  LLimit, LMore: Integer;
  LCands: TArray<TTarget>;
  LSb: TStringBuilder;
  LFallback, LOwnOnly: Boolean;
  LAll, LOwn: Integer;
begin
  LQuery := ArgStr(AArgs, 'query');
  if LQuery = '' then
    raise EToolError.Create('`query` is required');
  LKind := ArgStr(AArgs, 'kind');
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 30), 1, 500);
  LOwnOnly := SameText(ArgStr(AArgs, 'scope'), 'project');
  LCands := ResolveName(AWs, LQuery, LKind, LOwnOnly, LLimit, LMore);
  LFallback := False;
  if (Length(LCands) = 0) and (Pos('*', LQuery) = 0) and (Pos('?', LQuery) = 0)
  then
  begin
    // Nothing by that exact name: the agent often half-remembers one.
    LCands := ResolveName(AWs, '*' + LQuery + '*', LKind, LOwnOnly, LLimit,
      LMore);
    LFallback := True;
  end;
  LSb := TStringBuilder.Create;
  try
    // Nothing of that name in the index: say what the index is, and where
    // the name is written outside it - a unit no project uses is invisible
    // to every tool, and nothing else would say so.
    if Length(LCands) = 0 then
    begin
      if LOwnOnly then
      begin
        LAll := AWs.IndexedUnitCount(LOwn);
        LSb.AppendLine(Format('no declaration%s matches `%s` among the group''s '
          + 'own %d units (%d with the libraries; `scope: all` searches those '
          + 'too)', [IfThen(LKind <> '', ' of kind ' + LKind), LQuery, LOwn,
          LAll]));
      end
      else
        LSb.AppendLine(Format('no declaration%s matches `%s` among %s',
          [IfThen(LKind <> '', ' of kind ' + LKind), LQuery, IndexScope(AWs)]));
      LSb.AppendLine(OutsideIndexNote(AWs, LQuery, True));
      Exit(LSb.ToString.TrimRight);
    end;
    if LFallback then
      LSb.AppendLine(Format('no declaration named exactly `%s`; names '
        + 'containing it:', [LQuery]));
    for var LC in LCands do
      LSb.AppendLine(DescribeTarget(AWs, LC));
    if LMore > 0 then
      LSb.AppendLine(Format('... %d more (narrow the query, add `kind`, or '
        + 'raise `limit`)', [LMore]));
    // The names containing it may be the wrong ones when the name itself is
    // declared in a unit nothing uses.
    if LFallback then
      LSb.AppendLine(OutsideIndexNote(AWs, LQuery, False));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
  end;
end;

// The header line of the implementation whose body starts at ABodyLine: the
// nearest line above it that declares a routine of that name.
// A line that STARTS with the routine keyword - `begin // PROCEDURE Foo`
// mentions both and is not a header.
function ImplHeaderLine(const ALines: TArray<string>; ABodyLine: Integer;
  const AName: string): Integer;
var
  LLow: string;
begin
  Result := ABodyLine;
  for var LLine := ABodyLine downto Max(1, ABodyLine - 200) do
  begin
    if LLine > Length(ALines) then
      Continue;
    LLow := LowerCase(Trim(ALines[LLine - 1]));
    if LLow.StartsWith('class ') then
      LLow := Trim(Copy(LLow, 7, MaxInt));
    if (LLow.StartsWith('procedure ') or LLow.StartsWith('function ') or
        LLow.StartsWith('constructor ') or LLow.StartsWith('destructor ') or
        LLow.StartsWith('operator ')) and (FindWord(LLow, AName) > 0) then
      Exit(LLine);
  end;
end;

procedure AppendSource(ASb: TStringBuilder; const ALines: TArray<string>;
  AFrom, ACount: Integer);
begin
  for var LLine := AFrom to Min(Length(ALines), AFrom + ACount - 1) do
    ASb.AppendLine(Format('%6d  %s', [LLine, ALines[LLine - 1].TrimRight]));
end;

function ToolDefinition(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LTargets: TArray<TTarget>;
  LMore, LContext, LMid, LImplLine: Integer;
  LSb: TStringBuilder;
  LNavT: TPasNavTarget;
  LLines: TArray<string>;
  LImplFile, LShort: string;
begin
  LContext := EnsureRange(ArgInt(AArgs, 'context', 0), 0, 200);
  LMore := 0;
  if ArgStr(AArgs, 'file') <> '' then
    LTargets := [ResolvePosition(AWs, AArgs)]
  else
  begin
    if ArgStr(AArgs, 'symbol') = '' then
      raise EToolError.Create('give `symbol` or `file` + `line` + `name`');
    LTargets := ResolveName(AWs, ArgStr(AArgs, 'symbol'), ArgStr(AArgs, 'kind'),
      False, 10, LMore);
    if Length(LTargets) = 0 then
      raise EToolError.Create(NoSuchDeclaration(AWs, ArgStr(AArgs, 'symbol')));
  end;
  LSb := TStringBuilder.Create;
  try
    for var LT in LTargets do
    begin
      if LSb.Length > 0 then
        LSb.AppendLine;
      case LT.Kind of
        tkBuiltin:
          begin
            LSb.AppendLine(Format('%s is a compiler built-in - no source '
              + 'declaration', [LT.Name]));
            Continue;
          end;
        tkDefine:
          begin
            LSb.AppendLine(Format('%s is a conditional define - `references` '
              + 'lists every $DEFINE/$IFDEF of it', [LT.Name]));
            Continue;
          end;
      end;
      LSb.AppendLine(Format('%s (%s) declared at %s:%d', [LT.Name, LT.Head,
        AWs.RelPath(LT.DeclFile), LT.DeclLine]));
      LSb.AppendLine('  ' + LT.Snippet);
      // The implementation of a method or forward-declared routine - always in
      // the declaring unit (Object Pascal requires it there).
      LImplLine := 0;
      LImplFile := '';
      if (LT.Kind = tkSymbol) and ((LT.Head = 'procedure') or
         (LT.Head = 'function') or (LT.Head = 'constructor') or
         (LT.Head = 'destructor') or (LT.Head = 'operator') or
         (LT.Head = 'routine')) then
        for var LA in AWs.Analyses do
        begin
          if LT.Ids[LA.Index].Mid < 0 then
            Continue;
          LMid := LA.Nav.ModelIdOf(LT.DeclFile);
          if (LMid >= 0) and LA.Proj.EnsureHydrated(LMid) and
             LA.Nav.GotoImplementation(LMid, LT.DeclLine, LT.DeclCol, LNavT) then
          begin
            LImplFile := LNavT.FilePath;
            LShort := LT.Name;
            if LShort.Contains('.') then
              LShort := Copy(LShort, LastDelimiter('.', LShort) + 1, MaxInt);
            LLines := ReadLines(LImplFile);
            LImplLine := ImplHeaderLine(LLines, LNavT.Line, LShort);
            LSb.AppendLine(Format('implemented at %s:%d', [
              AWs.RelPath(LImplFile), LImplLine]));
            Break;
          end;
        end;
      if LContext > 0 then
      begin
        if LImplLine > 0 then
          AppendSource(LSb, LLines, LImplLine, LContext)
        else
          AppendSource(LSb, ReadLines(LT.DeclFile), LT.DeclLine, LContext);
      end;
    end;
    if LMore > 0 then
      LSb.AppendLine(Format('... %d more declarations of that name', [LMore]));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
  end;
end;

{ ---- source ------------------------------------------------------------------- }

const
  // A longer comment above a declaration is named, not shown: in old code it
  // is as often a commented-out earlier version as documentation.
  MAX_COMMENT_LINES = 30;

// Line breaks in a whitespace token; CRLF, LF and a lone CR count once each.
function LineBreaks(const AText: string): Integer;
begin
  Result := 0;
  for var LIdx := 1 to Length(AText) do
    if (AText[LIdx] = #10) or ((AText[LIdx] = #13) and
       ((LIdx = Length(AText)) or (AText[LIdx + 1] <> #10))) then
      Inc(Result);
end;

// The first line of the comment written directly above visible token AVis -
// comments each starting their own line, no blank line between them and the
// declaration - read from the raw token stream, where the lexer keeps them.
// AVisLine when there is none.
function CommentAboveLine(LM: TPasSemaModel; AVis, AVisLine: Integer): Integer;
var
  LFileId, LIdx, LFirst, LCol: Integer;
begin
  Result := AVisLine;
  if (AVis < 0) or (AVis > High(LM.Tree.Source.Visible)) then
    Exit;
  LFileId := LM.Tree.Source.Visible[AVis].FileId;
  if (LFileId < 0) or (LFileId > High(LM.Tree.Source.Files)) then
    Exit;
  LFirst := -1;
  LIdx := LM.Tree.Source.Visible[AVis].TokenIndex - 1;
  while LIdx >= 0 do
  begin
    case LM.Tree.Source.Files[LFileId].Tokens[LIdx].Kind of
      tkWhitespace:
        if LineBreaks(LM.Tree.Source.Files[LFileId].TokenText(LIdx)) > 1 then
          Break;
      tkCommentLine, tkCommentBrace, tkCommentParen:
        begin
          // `end; // done` belongs to the code before it.
          if (LIdx > 0) and
             ((LM.Tree.Source.Files[LFileId].Tokens[LIdx - 1].Kind <>
               tkWhitespace) or (LineBreaks(LM.Tree.Source.Files[LFileId].
               TokenText(LIdx - 1)) = 0)) then
            Break;
          LFirst := LIdx;
        end;
    else
      Break;   // code, or a directive - `{$R *.dfm}` is not a doc comment
    end;
    Dec(LIdx);
  end;
  if LFirst >= 0 then
    LM.Tree.Source.Files[LFileId].OffsetToLineCol(
      LM.Tree.Source.Files[LFileId].Tokens[LFirst].Start, Result, LCol);
end;

// A declaration node in lines: its file (an index into the model's files),
// AFrom - the first line to show, the comment above included - AAt, its own
// first line, and ATo, its last. False when it straddles an $I include.
function DeclLines(LM: TPasSemaModel; ANode: Integer; out AFileId, AFrom, AAt,
  ATo: Integer): Boolean;
var
  LToFile, LCol: Integer;
begin
  Result := VisPos(LM, LM.Tree.NodeLeftmostVis(ANode), AFileId, AAt, LCol) and
    VisPos(LM, LM.Tree.Nodes[ANode].LastToken, LToFile, ATo, LCol) and
    (LToFile = AFileId);
  if Result then
    AFrom := CommentAboveLine(LM, LM.Tree.NodeLeftmostVis(ANode), AAt);
end;

// The innermost routine whose tokens in file AFileId hold ALine:ACol.
function RoutineNodeAt(LM: TPasSemaModel; AFileId, ALine, ACol: Integer): Integer;
var
  LFromFile, LFromLine, LFromCol, LToFile, LToLine, LToCol, LBestLine,
    LBestCol: Integer;
begin
  Result := NIL_NODE;
  LBestLine := 0;
  LBestCol := 0;
  for var LNode := 0 to High(LM.Tree.Nodes) do
  begin
    if (LM.Tree.Nodes[LNode].Kind <> nkRoutine) or
       not VisPos(LM, LM.Tree.NodeLeftmostVis(LNode), LFromFile, LFromLine,
       LFromCol) or (LFromFile <> AFileId) or
       not VisPos(LM, LM.Tree.Nodes[LNode].LastToken, LToFile, LToLine,
       LToCol) or (LToFile <> AFileId) then
      Continue;
    if (ALine < LFromLine) or ((ALine = LFromLine) and (ACol < LFromCol)) or
       (ALine > LToLine) or ((ALine = LToLine) and (ACol > LToCol)) then
      Continue;
    if (Result = NIL_NODE) or (LFromLine > LBestLine) or
       ((LFromLine = LBestLine) and (LFromCol > LBestCol)) then
    begin
      Result := LNode;
      LBestLine := LFromLine;
      LBestCol := LFromCol;
    end;
  end;
end;

function HasBody(LM: TPasSemaModel; ARoutine: Integer): Boolean;
var
  LChild: Integer;
begin
  LChild := LM.Tree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkRoutineBody then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
end;

function HasDirective(LM: TPasSemaModel; ARoutine: Integer;
  const AWord: string): Boolean;
var
  LChild: Integer;
begin
  LChild := LM.Tree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       SameText(LM.Tree.NodeText(LChild), AWord) then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
end;

// Is a routine declaration a member of an interface type?
function InInterfaceType(LM: TPasSemaModel; ARoutine: Integer): Boolean;
var
  LUp: Integer;
begin
  LUp := LM.Tree.Nodes[ARoutine].Parent;
  while LUp <> NIL_NODE do
  begin
    case LM.Tree.Nodes[LUp].Kind of
      nkInterfaceType:
        Exit(True);
      nkClassType, nkRecordType, nkObjectType, nkHelperType, nkTypeDecl,
      nkRoutineBody:
        Exit(False);
    end;
    LUp := LM.Tree.Nodes[LUp].Parent;
  end;
  Result := False;
end;

// Why a routine declaration has no body to show.
function NoBodyNote(LM: TPasSemaModel; ARoutine: Integer): string;
begin
  if HasDirective(LM, ARoutine, 'abstract') then
    Result := 'abstract, no body: `related overrides` lists the overrides'
  else if InInterfaceType(LM, ARoutine) then
    Result := 'an interface method, no body: `related implementations` lists '
      + 'the methods implementing it'
  else if HasDirective(LM, ARoutine, 'external') then
    Result := 'external, no body in source'
  else
    Result := 'no implementation found';
end;

// One part - a declaration or an implementation - under its heading, the
// lines numbered as in the file, at most ALimit of them.
procedure AppendPart(ASb: TStringBuilder; AWs: TMcpWorkspace; LM: TPasSemaModel;
  ANode: Integer; const AHead: string; ALimit: Integer);
var
  LFileId, LFrom, LAt, LTo, LLast, LWidth: Integer;
begin
  if not DeclLines(LM, ANode, LFileId, LFrom, LAt, LTo) then
  begin
    ASb.AppendLine(AHead + ' across an $I include - not shown; read the file');
    Exit;
  end;
  ASb.AppendLine(Format('%s at %s:%s', [AHead,
    AWs.RelPath(LM.Tree.Source.FileNames[LFileId]),
    IfThen(LTo > LAt, Format('%d-%d', [LAt, LTo]), IntToStr(LAt))]));
  if LAt - LFrom > MAX_COMMENT_LINES then
  begin
    ASb.AppendLine(Format('(%d comment lines above it, from line %d)',
      [LAt - LFrom, LFrom]));
    LFrom := LAt;
  end;
  LLast := Min(LTo, LFrom + ALimit - 1);
  LWidth := Length(IntToStr(LLast));
  for var LLine := LFrom to LLast do
    ASb.AppendLine(Format('%*d  %s', [LWidth, LLine,
      LM.Tree.Source.Files[LFileId].LineText(LLine)]));
  if LTo > LLast then
    ASb.AppendLine(Format('... %d more lines, to line %d (raise `limit`)',
      [LTo - LLast, LTo]));
end;

{ The exact text of one declaration (SPEC 9.2.2): a routine's implementation
  from its header to its `end;`, a type's whole declaration, a constant with
  its value - where `definition` + `context` makes the agent guess how many
  lines a routine has. The lines come from the model's own token stream, so
  their numbers are the ones every other answer uses. }
function ToolSource(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LPart, LTitle: string;
  LLimit, LMid, LSym, LDeclNode, LImplNode, LDm, LFileId: Integer;
  LA: TMcpAnalysis;
  LM, LImplM: TPasSemaModel;
  LNavT: TPasNavTarget;
  LSb: TStringBuilder;
  LIsRoutine, LSame, LShowDecl, LShowImpl: Boolean;
begin
  LPart := LowerCase(ArgStr(AArgs, 'part'));
  if (LPart <> '') and (LPart <> 'impl') and (LPart <> 'decl') and
     (LPart <> 'both') then
    raise EToolError.Create('`part` is impl, decl or both');
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 300), 1, 5000);
  LT := ResolveOne(AWs, AArgs);
  case LT.Kind of
    tkUnit:
      raise EToolError.CreateFmt('%s is a unit - `outline` shows its '
        + 'structure with line numbers; `source` takes one of its '
        + 'declarations', [LT.Name]);
    tkBuiltin, tkDefine:
      raise EToolError.CreateFmt('%s is a %s - it has no source declaration',
        [LT.Name, LT.Head]);
  end;
  if SameText(TPath.GetExtension(LT.DeclFile), '.dcu') then
    raise EToolError.CreateFmt('%s is declared in a compiled unit without '
      + 'source (%s)', [LT.Name, AWs.RelPath(LT.DeclFile)]);

  // The declaration node, from the first analysis that holds the symbol.
  LA := nil;
  for var LCand in AWs.Analyses do
    if LT.Ids[LCand.Index].Mid >= 0 then
    begin
      LA := LCand;
      Break;
    end;
  LDeclNode := NIL_NODE;
  LM := nil;
  LMid := -1;
  if LA <> nil then
  begin
    LMid := LT.Ids[LA.Index].Mid;
    LSym := LT.Ids[LA.Index].Sym;
    if LA.Proj.EnsureHydrated(LMid) then
    begin
      LM := LA.Proj.Model(LMid);
      if (LSym >= 0) and (LSym < LM.SymCount) then
        LDeclNode := LM.Tree.DeclRootOf(LM.Symbols[LSym].DeclNode);
    end;
  end;
  if LDeclNode = NIL_NODE then
    raise EToolError.CreateFmt('no source declaration of %s found', [LT.Name]);

  // A routine declared apart from its body - a method, an interface-section
  // or a forward routine - is implemented in the declaring unit: the routine
  // around the first statement GotoImplementation finds.
  LIsRoutine := LM.Tree.Nodes[LDeclNode].Kind = nkRoutine;
  LImplNode := NIL_NODE;
  LImplM := nil;
  if LIsRoutine and HasBody(LM, LDeclNode) then
  begin
    LImplNode := LDeclNode;
    LImplM := LM;
  end
  else if LIsRoutine then
  begin
    LDm := LA.Nav.ModelIdOf(LT.DeclFile);
    if LDm < 0 then
      LDm := LMid;
    if LA.Nav.GotoImplementation(LDm, LT.DeclLine, LT.DeclCol, LNavT) and
       LA.Proj.EnsureHydrated(LNavT.UnitId) then
    begin
      LImplM := LA.Proj.Model(LNavT.UnitId);
      LFileId := FileIdOf(LImplM, LNavT.FilePath);
      if LFileId >= 0 then
        LImplNode := RoutineNodeAt(LImplM, LFileId, LNavT.Line, LNavT.Col);
    end;
  end;

  // Declared where it is implemented (a routine of the implementation
  // section only): one text, whichever part is asked.
  LSame := (LImplNode = LDeclNode) and (LImplM = LM);
  if LPart = '' then
    LPart := IfThen(LImplNode <> NIL_NODE, 'impl', 'decl');
  LShowImpl := (LImplNode <> NIL_NODE) and ((LPart = 'impl') or
    (LPart = 'both'));
  LShowDecl := not (LSame and LShowImpl) and ((LPart <> 'impl') or
    (LImplNode = NIL_NODE));
  LTitle := Format('%s (%s) ', [LT.Name, LT.Head]);
  LSb := TStringBuilder.Create;
  try
    if LShowDecl then
    begin
      AppendPart(LSb, AWs, LM, LDeclNode, LTitle + 'declared', LLimit);
      LTitle := '';
      if LIsRoutine and (LImplNode = NIL_NODE) then
        LSb.AppendLine('(' + NoBodyNote(LM, LDeclNode) + ')')
      else if not LIsRoutine and (LPart = 'impl') then
        LSb.AppendLine('(not a routine: its declaration is all its source)');
    end;
    if LShowImpl then
      AppendPart(LSb, AWs, LImplM, LImplNode, LTitle + IfThen(LSame,
        'declared', 'implemented'), LLimit);
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
  end;
end;

function IsRoutineTarget(const AT: TTarget): Boolean;
begin
  Result := (AT.Kind = tkSymbol) and ((AT.Head = 'procedure') or
    (AT.Head = 'function') or (AT.Head = 'constructor') or
    (AT.Head = 'destructor') or (AT.Head = 'operator') or
    (AT.Head = 'routine'));
end;

// For a routine no code names: the calls `callers` finds through what it
// overrides, implements or is the accessor of, as a note line ('' = none).
function ThroughNote(AWs: TMcpWorkspace; const AT: TTarget): string; forward;

// For a member no form file binds: its unit's form file spelling its name
// after the root's `end`, which dcc's conversion drops - a reader who greps
// the file finds the line the answer says is not there. '' = no such text.
function TrailingFormNote(AWs: TMcpWorkspace; const AT: TTarget): string;
var
  LForm, LName: string;
  LDoc: IPasDfmDoc;
begin
  Result := '';
  LForm := PasDfmFileOfUnit(AT.DeclFile);
  if LForm = '' then
    Exit;
  LDoc := PasDfmLoad(LForm);
  if (LDoc = nil) or (LDoc.Doc.TrailingLine = 0) then
    Exit;
  LName := LowerCase(AT.Name);
  LName := Copy(LName, LastDelimiter('.', LName) + 1, MaxInt);
  if LDoc.Doc.MentionsTrailing(LName) then
    Result := Format('%s names it only after the root''s `end` (from line '
      + '%d), which the compiler drops - no form binds it; a stray `end`?',
      [AWs.RelPath(LForm), LDoc.Doc.TrailingLine]);
end;

function ToolReferences(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LSet: THitSet;
  LHits: TArray<THit>;
  LSb: TStringBuilder;
  LLimit: Integer;
  LId: TSymId;
  LEnclosing: TEnclosing;
  LBindable, LSetsProp: Boolean;
  LForms: string;
begin
  LT := ResolveOne(AWs, AArgs);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000);
  LBindable := False;
  LSetsProp := False;
  LSet := THitSet.Create(AWs);
  LSb := TStringBuilder.Create;
  LEnclosing := TEnclosing.Create(AWs);
  try
    for var LA in AWs.Analyses do
    begin
      LId := LT.Ids[LA.Index];
      if LId.Mid < 0 then
        Continue;
      case LT.Kind of
        tkSymbol:
          begin
            for var LH in LA.Nav.FindReferences(LId.Mid, LId.Sym) do
              LSet.Add(LH);
            // What the form files bind by name - a handler no code calls, a
            // component only its form file names - which a rename made from
            // the Pascal rows alone breaks at run time, when the form loads.
            for var LS in LA.Nav.FindFormSites(LId.Mid, LId.Sym) do
              LSet.AddForm(LS);
            if not LBindable then
              LBindable := LA.Nav.FormRoleOf(LId.Mid, LId.Sym).Kind in
                [fskComponent, fskHandler];
            if not LSetsProp and LA.Proj.EnsureHydrated(LId.Mid) then
              LSetsProp := (LA.Proj.Model(LId.Mid).Symbols[LId.Sym].Kind =
                skProperty) and (LA.Proj.Model(LId.Mid).Symbols[LId.Sym].
                Visibility = svPublished);
          end;
        tkUnit:
          for var LH in LA.Nav.FindUnitReferences(LId.Mid) do
            LSet.Add(LH);
        tkBuiltin:
          for var LH in LA.Nav.FindBuiltinReferences(LT.Name) do
            LSet.Add(LH);
        tkDefine:
          for var LH in LA.Nav.FindDefineReferences(LT.Name) do
            LSet.Add(LH.Hit, IfThen(LH.Active, '', 'inactive'));
      end;
    end;
    LHits := LSet.Sorted;
    // A published field or method the forms could bind: say they were read,
    // and what they hold - "no form file names it" is itself the answer.
    if LSet.FormCount > 0 then
      LForms := Format(', %d of them in form files', [LSet.FormCount])
    else if LBindable then
      LForms := '; no form file names it'
    else if LSetsProp then
      LForms := '; no form file sets it'
    else
      LForms := '';
    if LT.Kind in [tkSymbol, tkUnit] then
      LSb.AppendLine(Format('%s (%s) declared at %s:%d - %d references in %d '
        + 'files%s', [LT.Name, LT.Head, AWs.RelPath(LT.DeclFile), LT.DeclLine,
        Length(LHits), FileCount(LHits), LForms]))
    else
      LSb.AppendLine(Format('%s (%s) - %d references in %d files', [LT.Name,
        LT.Head, Length(LHits), FileCount(LHits)]));
    AppendHitsByFile(AWs, LSb, LHits, LLimit, False, LEnclosing);
    if LSet.Compiled > 0 then
      LSb.AppendLine(Format('(+%d in compiled units without source, not '
        + 'shown)', [LSet.Compiled]));
    if (LSet.FormCount = 0) and LBindable then
    begin
      LForms := TrailingFormNote(AWs, LT);
      if LForms <> '' then
        LSb.AppendLine('(' + LForms + ')');
    end;
    // No use by name is not "unused" for a routine called through what it
    // overrides, implements or is the accessor of: identity is the contract,
    // and a bare 0 reads as dead code.
    if (Length(LHits) = LSet.FormCount) and IsRoutineTarget(LT) then
      LSb.Append(ThroughNote(AWs, LT));
    if (LT.Kind = tkSymbol) and (LT.Head = 'property') then
      for var LA in AWs.Analyses do
      begin
        LId := LT.Ids[LA.Index];
        if (LId.Mid < 0) or not LA.Proj.EnsureHydrated(LId.Mid) then
          Continue;
        if IsDefaultArrayProperty(LA.Proj.Model(LId.Mid),
           LA.Proj.Model(LId.Mid).Symbols[LId.Sym].DeclNode) then
          LSb.AppendLine('(the default array property: `X[I]` uses it '
            + 'without its name, and those uses are not listed)');
        Break;
      end;
    Result := LSb.ToString.TrimRight;
  finally
    LEnclosing.Free;
    LSb.Free;
    LSet.Free;
  end;
end;

function ToolRelated(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
const
  OVK: array[TPasOverrideKind] of string = ('introduces', 'override',
    'message', 'reintroduce', 'redeclares');
  IMK: array[TPasImplKind] of string = ('declares', 'implements',
    'implements (inherited)');
var
  LT: TTarget;
  LRel, LName, LWhat: string;
  LSet: THitSet;
  LHits: TArray<THit>;
  LSb: TStringBuilder;
  LLimit, LDm, LTMid, LTSym: Integer;
  LAccepted: Boolean;
  LEnclosing: TEnclosing;

  // The relation's own identity test, at the declaration site (it normalizes:
  // a method to its declaration, an alias to its type); the resolved ids when
  // the declaration sits in an include and has no model of its own.
  function At(AA: TMcpAnalysis; AKind: Integer): Boolean;
  begin
    Result := False;
    LDm := AA.Nav.ModelIdOf(LT.DeclFile);
    if (LDm >= 0) and AA.Proj.EnsureHydrated(LDm) then
      case AKind of
        0: Result := AA.Nav.TypeAt(LDm, LT.DeclLine, LT.DeclCol, LTMid, LTSym,
             LName);
        1: Result := AA.Nav.MethodAt(LDm, LT.DeclLine, LT.DeclCol, LTMid,
             LTSym, LName);
        2: Result := AA.Nav.InterfaceMethodAt(LDm, LT.DeclLine, LT.DeclCol,
             LTMid, LTSym, LName);
        3: Result := AA.Nav.InterfaceAt(LDm, LT.DeclLine, LT.DeclCol, LTMid,
             LTSym, LName);
        4: Result := AA.Nav.AssignableAt(LDm, LT.DeclLine, LT.DeclCol, LTMid,
             LTSym, LName);
        5: Result := AA.Nav.ClassAt(LDm, LT.DeclLine, LT.DeclCol, LTMid, LTSym,
             LName);
      end
    else if LDm < 0 then
    begin
      LTMid := LT.Ids[AA.Index].Mid;
      LTSym := LT.Ids[AA.Index].Sym;
      Result := LTMid >= 0;
    end;
  end;

begin
  LRel := LowerCase(ArgStr(AArgs, 'relation'));
  if LRel = '' then
    raise EToolError.Create('`relation` is required: descendants, overrides, '
      + 'implementations, assignments, creations or destructions');
  LT := ResolveOne(AWs, AArgs);
  if LT.Kind <> tkSymbol then
    raise EToolError.CreateFmt('%s is a %s; relations are about types, '
      + 'methods and variables', [LT.Name, LT.Head]);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000);
  LAccepted := False;
  LEnclosing := nil;
  LSet := THitSet.Create(AWs);
  LSb := TStringBuilder.Create;
  try
    for var LA in AWs.Analyses do
    begin
      if LT.Ids[LA.Index].Mid < 0 then
        Continue;
      if LRel = 'descendants' then
      begin
        LWhat := 'a class or interface type';
        if At(LA, 0) then
        begin
          LAccepted := True;
          // A direct child's parent is the target itself: named only below.
          for var LH in LA.Nav.FindDescendants(LTMid, LTSym) do
            if LH.Kind = pdkDescendant then
              LSet.Add(LH.Hit, LH.TypeName + IfThen(LH.Depth > 1, ' <- ' +
                LH.ParentTypeName, ''));
        end;
      end
      else if LRel = 'overrides' then
      begin
        LWhat := 'a virtual/dynamic/override/message method of a class, or a '
          + 'class property';
        if At(LA, 1) then
        begin
          LAccepted := True;
          for var LH in LA.Nav.FindOverrides(LTMid, LTSym) do
            LSet.Add(LH.Hit, LH.TypeName + ' ' + OVK[LH.Kind]);
        end;
      end
      else if LRel = 'implementations' then
      begin
        LWhat := 'an interface type or an interface method';
        if At(LA, 2) then
        begin
          LAccepted := True;
          for var LH in LA.Nav.FindImplementations(LTMid, LTSym) do
            if LH.Kind <> pikRoot then
              LSet.Add(LH.Hit, LH.TypeName + ' ' + IMK[LH.Kind] +
                IfThen(LH.ViaTypeName <> '', ' via ' + LH.ViaTypeName, ''));
        end
        else if At(LA, 3) then
        begin
          LAccepted := True;
          for var LH in LA.Nav.FindInterfaceImplementors(LTMid, LTSym) do
            if LH.Kind <> pikRoot then
              LSet.Add(LH.Hit, LH.TypeName);
        end;
      end
      else if LRel = 'assignments' then
      begin
        LWhat := 'a variable, field, parameter or writable property';
        if At(LA, 4) then
        begin
          LAccepted := True;
          for var LH in LA.Nav.FindAssignments(LTMid, LTSym) do
            LSet.Add(LH);
        end;
      end
      else if (LRel = 'creations') or (LRel = 'destructions') then
      begin
        LWhat := 'a class type';
        if At(LA, 5) then
        begin
          LAccepted := True;
          if LRel = 'creations' then
            for var LH in LA.Nav.FindCreations(LTMid, LTSym) do
              LSet.Add(LH)
          else
            for var LH in LA.Nav.FindDestructions(LTMid, LTSym) do
              LSet.Add(LH);
        end;
      end
      else
        raise EToolError.CreateFmt('unknown relation `%s` - use descendants, '
          + 'overrides, implementations, assignments, creations or '
          + 'destructions', [LRel]);
    end;
    if not LAccepted then
      raise EToolError.CreateFmt('%s (%s at %s:%d) is not %s, which `%s` needs',
        [LT.Name, LT.Head, AWs.RelPath(LT.DeclFile), LT.DeclLine, LWhat, LRel]);
    LHits := LSet.Sorted;
    LSb.AppendLine(Format('%s of %s (%s:%d): %d', [LRel, LT.Name,
      AWs.RelPath(LT.DeclFile), LT.DeclLine, Length(LHits)]));
    // Descendants by file like every other answer, not as an indented tree:
    // a tree repeats a path on every row (250 rows, 27 tokens each, on the
    // client group), and `<- parent` keeps the shape.
    // A row that is a statement - an assignment, a creation, a destruction -
    // goes under the routine it sits in. A descendant, override or
    // implementation row is a declaration, and its [tag] names its type.
    if (LRel = 'assignments') or (LRel = 'creations') or
       (LRel = 'destructions') then
      LEnclosing := TEnclosing.Create(AWs);
    AppendHitsByFile(AWs, LSb, LHits, LLimit, LRel = 'descendants',
      LEnclosing);
    if LSet.Compiled > 0 then
      LSb.AppendLine(Format('(+%d in compiled units without source, not '
        + 'shown)', [LSet.Compiled]));
    Result := LSb.ToString.TrimRight;
  finally
    LEnclosing.Free;
    LSb.Free;
    LSet.Free;
  end;
end;

{ ---- callers ------------------------------------------------------------------- }

type
  // What one reference to a routine does where it is written.
  TRefUse = (
    ruCall,       // calls it: Foo(1); Foo; X := Foo; inherited Foo
    ruValue,      // hands it on uncalled: @Foo, OnClick := Foo, Run(Foo)
    ruRead,       // a property's `read` accessor: every read calls it
    ruWrite,      // its `write` accessor: every write calls it
    ruMaps,       // `procedure IFoo.Bar = Foo`: what IFoo.Bar runs
    ruExported,   // an `exports` entry: called from outside
    ruNone);      // no use - `Foo := X` inside function Foo sets its result

  TCallSourceKind = (csSelf, csVirtual, csInterface, csRead, csWrite,
    csProperty);

  { A symbol a call can be written against and still end up running the
    routine, in one analysis: the routine itself, a virtual method it
    overrides, an interface method it implements, a property it is an
    accessor of. For a field (impact), the property that reads or writes
    it. }
  TCallSource = record
    Mid, Sym: Integer;
    Kind: TCallSourceKind;
    Name: string;          // qualified - what a `via` tag names
  end;

  // An interface a class of the walk takes on, and the class that lists it
  // (or an interface extending it): its members are what implement it.
  TIfaceListing = record
    Iface, Lister: TSemaXType;
  end;

  // A routine of the walk: a root, or a caller found at Level.
  TCallNode = record
    T: TTarget;
    Name: string;          // as its rows' heading reads: TFoo.Save.Helper
    Level: Integer;
    Found: Integer;        // rows its search found; -1 = not searched
    Data: Boolean;         // a root that is no routine - a type, a variable,
                           // a field (impact): every reference is a use
  end;

  // One level of a walk, counted: rows that call (or use) a node of the level
  // above, the routines they sit in, rows that hand a routine on.
  TCallLevel = record
    Calls, Routines, Others: Integer;
    Bindings: Integer;     // form file lines binding a node to an event
  end;

  // What a walk found, for the answer to word.
  TCallWalkInfo = record
    Levels: TArray<TCallLevel>;
    AllVia: string;        // the one symbol every first-level row is bound to
    Libraries: Integer;    // library routines met, shown and not followed
    CutAt: Integer;        // the depth `limit` kept from being searched; 0
    Pending: Integer;      // routines of the last depth, not searched
  end;

  TCallRow = record
    Hit: THit;
    Caller: string;        // declaration site of the routine it sits in
    Call: Boolean;         // a call - not the routine handed on as a value
    // A form file's line binding it to an event (`OnClick = Foo`): run by
    // the component, not called from code - no caller to follow.
    Binding: Boolean;
    // The row's label, in parts: the routine of the walk it reaches (below
    // the first level), the symbol it is bound to when that is another one,
    // and what it is - 'not a call', 'exported', 'main block'.
    Callee, Via, Note: string;
  end;

const
  SOURCE_KINDS: array[TCallSourceKind] of string = ('', 'virtual',
    'interface', 'property read', 'property write', 'property');

// The designator a name ends - `Obj.Foo`, `Unit.Foo`, `Foo<T>` - or the name
// itself.
function DesignatorOf(LM: TPasSemaModel; ANode: Integer): Integer;
var
  LP: Integer;
begin
  Result := ANode;
  LP := LM.Tree.Nodes[Result].Parent;
  while (LP <> NIL_NODE) and
        (((LM.Tree.Nodes[LP].Kind = nkMember) and
          (LM.Tree.Nodes[LP].FirstChild <> Result)) or
         ((LM.Tree.Nodes[LP].Kind = nkTypeArgs) and
          (LM.Tree.Nodes[LP].FirstChild = Result))) do
  begin
    Result := LP;
    LP := LM.Tree.Nodes[Result].Parent;
  end;
end;

{ What the reference ANode - an identifier bound to a routine - does there.
  A procedure named without a call can only be handed on: assigned to an
  event, passed as a callback, `@`. A function or a constructor so named IS
  called - its result is the value - unless it is assigned to something
  procedural (`FCompare := ByName`). As an argument it is taken for a call:
  telling a function passed as a callback from its result would take the
  callee's parameter types. }
function RefUse(AA: TMcpAnalysis; LM: TPasSemaModel; AMid, ANode: Integer;
  AReturns: Boolean): TRefUse;
var
  LE, LP: Integer;
  LX: TSemaXType;
begin
  LE := DesignatorOf(LM, ANode);
  LP := LM.Tree.Nodes[LE].Parent;
  if LP = NIL_NODE then
    Exit(ruCall);
  case LM.Tree.Nodes[LP].Kind of
    nkCall:
      if (LM.Tree.Nodes[LP].FirstChild = LE) or AReturns then
        Exit(ruCall)
      else
        Exit(ruValue);
    // The base of a selector is evaluated: `GetList.Count`, `GetItems[0]`.
    nkExprStmt, nkInherited, nkMember, nkIndex, nkDeref:
      Exit(ruCall);
    nkUnaryOp:
      if LM.Tree.Source.VisibleToken(LM.Tree.Nodes[LP].Aux).Kind = tkAt then
        Exit(ruValue);
    nkPropSpec:
      if LM.Tree.NodeTextEquals(LP, 'read') then
        Exit(ruRead)
      else if LM.Tree.NodeTextEquals(LP, 'write') then
        Exit(ruWrite)
      else
        Exit(ruValue);   // `stored IsStored`: streaming calls it, not code
    nkMethodResolution:
      Exit(ruMaps);
    nkExportsItem:
      Exit(ruExported);
    nkAssign:
      if LM.Tree.Nodes[LP].FirstChild = LE then
        Exit(ruNone)
      else if AReturns then
      begin
        LX := AA.Proj.CanonTypeX(AA.Proj.WithTargetTypeX(AMid,
          LM.Tree.Nodes[LP].FirstChild));
        if XValid(LX) and
           (AA.Proj.Model(LX.UnitId).Symbols[LX.Sym].TypeCat = tcProc) then
          Exit(ruValue);
        Exit(ruCall);
      end
      else
        Exit(ruValue);
  end;
  if AReturns then
    Result := ruCall
  else
    Result := ruValue;
end;

// `inherited Foo`: a static call of that exact implementation, which no
// override intercepts.
function UnderInherited(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LP: Integer;
begin
  LP := LM.Tree.Nodes[ANode].Parent;
  if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkCall) and
     (LM.Tree.Nodes[LP].FirstChild = ANode) then
    LP := LM.Tree.Nodes[LP].Parent;
  Result := (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkInherited);
end;

function InWithBody(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LUp: Integer;
begin
  LUp := LM.Tree.Nodes[ANode].Parent;
  while LUp <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LUp].Kind = nkWithStmt then
      Exit(True);
    LUp := LM.Tree.Nodes[LUp].Parent;
  end;
  Result := False;
end;

// The class or interface type node a type symbol declares, NIL_NODE for
// anything else - an alias, a record, a helper, a compiled unit's type.
function StructDefNode(AA: TMcpAnalysis; const AX: TSemaXType): Integer;
var
  LM: TPasSemaModel;
  LDecl, LChild: Integer;
begin
  Result := NIL_NODE;
  if not XValid(AX) then
    Exit;
  LM := AA.Proj.Model(AX.UnitId);
  LDecl := LM.Symbols[AX.Sym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.DeclRootOf(LDecl);
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  LChild := LM.Tree.Nodes[LDecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind in [nkClassType, nkInterfaceType] then
      Exit(LChild);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

function IsKindX(AA: TMcpAnalysis; const AX: TSemaXType;
  AKind: TPasNodeKind): Boolean;
var
  LDef: Integer;
begin
  LDef := StructDefNode(AA, AX);
  Result := (LDef <> NIL_NODE) and
    (AA.Proj.Model(AX.UnitId).Tree.Nodes[LDef].Kind = AKind);
end;

// The class a method belongs to; XNil for a routine of no class.
function OwnerClassX(AA: TMcpAnalysis; AMid, ASym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  Result := XNil;
  LM := AA.Proj.Model(AMid);
  LScope := LM.Symbols[ASym].Scope;
  if (LScope <> NIL_SCOPE) and (LScope < LM.Scopes.Count) and
     (LM.Scopes[LScope].Kind = sckStruct) and
     (LM.Scopes[LScope].StructSym <> NIL_SYM) then
    Result := XPlain(AMid, LM.Scopes[LScope].StructSym);
  if not IsKindX(AA, Result, nkClassType) then
    Result := XNil;
end;

{ Can a call dispatched through a virtual slot - bound to a method AClass's
  method (ARMid, ARSym) overrides, or to a property whose getter or setter
  that slot is - run that method? Only when the object may be an AClass, or
  a descendant that does not override it again. So its static type must be
  AClass or an ancestor (`LSquare.Area` bound to TShape.Area never runs
  TCircle.Area), or a descendant whose nearest method of that name is still
  AClass's (a property read on a class that overrides the getter runs its
  own getter, not the ancestor's). A bare call is made on Self, unless a
  `with` supplies the object. What cannot be told is kept. }
function MayRun(AA: TMcpAnalysis; LM: TPasSemaModel; AMid, ANode: Integer;
  const AClass: TSemaXType; ARMid, ARSym: Integer): Boolean;
var
  LP, LK, LFMid, LFSym, LCtx: Integer;
  LX: TSemaXType;
begin
  Result := True;
  LP := LM.Tree.Nodes[ANode].Parent;
  if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkMember) and
     (LM.Tree.Nodes[LP].FirstChild <> ANode) then
    LX := AA.Proj.WithTargetTypeX(AMid, LM.Tree.Nodes[LP].FirstChild)
  else
  begin
    if InWithBody(LM, ANode) then
      Exit;
    LK := AA.Proj.StructSymOfNode(LM, ANode);
    if LK = NIL_SYM then
      Exit;
    LX := XPlain(AMid, LK);
  end;
  LX := AA.Proj.CanonTypeX(LX);
  if not IsKindX(AA, LX, nkClassType) or AA.Proj.XDescendsFrom(AClass, LX)
  then
    Exit;
  Result := False;
  if AA.Proj.XDescendsFrom(LX, AClass) and AA.Proj.FindMemberX(LX.UnitId, LX,
     AA.Proj.Model(ARMid).Symbols[ARSym].NameLower, LFMid, LFSym, LCtx) then
    while LFSym <> NIL_SYM do
    begin
      if (LFMid = ARMid) and (LFSym = ARSym) then
        Exit(True);
      LFSym := AA.Proj.Model(LFMid).Symbols[LFSym].NextOverload;
    end;
end;

// The interfaces a class's own heritage list names, and the interfaces those
// extend - every one the class implements with its members (dcc carries an
// ancestor interface's methods into the class that lists the descendant).
function ListedInterfaces(AA: TMcpAnalysis;
  const AClass: TSemaXType): TArray<TSemaXType>;
var
  LX: TSemaXType;
  LM: TPasSemaModel;
  LDef, LChild: Integer;
  LList: TList<TSemaXType>;
  LInList: Boolean;
begin
  LDef := StructDefNode(AA, AClass);
  if LDef = NIL_NODE then
    Exit(nil);
  LList := TList<TSemaXType>.Create;
  try
    LM := AA.Proj.Model(AClass.UnitId);
    LInList := False;
    LChild := LM.Tree.Nodes[LDef].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkTypeArgs] then
      begin
        LInList := True;
        LX := AA.Proj.CanonTypeX(AA.Proj.ResolveTypeExpr(AClass.UnitId,
          LChild));
        for var LUp := 1 to 64 do
        begin
          if not IsKindX(AA, LX, nkInterfaceType) or LList.Contains(LX) then
            Break;
          LList.Add(LX);
          LX := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LX));
        end;
      end
      else if LInList then
        Break;   // the heritage list is over: members follow
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// Is ANode a use that writes it - the target of an assignment, indexed or
// not (`Items[I] := X` runs the setter)? A property reference that is not,
// reads it: a property cannot be passed to a `var` parameter.
function IsAssignTarget(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LE, LP: Integer;
begin
  LE := DesignatorOf(LM, ANode);
  LP := LM.Tree.Nodes[LE].Parent;
  if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkIndex) and
     (LM.Tree.Nodes[LP].FirstChild = LE) then
  begin
    LE := LP;
    LP := LM.Tree.Nodes[LE].Parent;
  end;
  Result := (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkAssign) and
    (LM.Tree.Nodes[LP].FirstChild = LE);
end;

// `property Items;` in a descendant republishing an inherited property: a
// reference search lists such a name as the same property, but it is a
// declaration, not a use.
function IsPropertyDeclName(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LP: Integer;
begin
  LP := LM.Tree.Nodes[ANode].Parent;
  Result := (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkPropertyDecl) and
    (LM.Tree.Nodes[LP].FirstChild = ANode);
end;

// The routine with a body around ANode; NIL_NODE in a program's main block,
// an initialization section or a declaration. An anonymous method is not
// one: its lines belong to the routine that writes it.
function BodyRoutineOf(LM: TPasSemaModel; ANode: Integer): Integer;
begin
  Result := LM.Tree.Nodes[ANode].Parent;
  while (Result <> NIL_NODE) and not ((LM.Tree.Nodes[Result].Kind = nkRoutine)
        and HasBody(LM, Result)) do
    Result := LM.Tree.Nodes[Result].Parent;
end;

// Where a statement outside every routine runs: 'main block',
// 'initialization', 'finalization'; '' in a declaration.
function RootPlace(LM: TPasSemaModel; ANode: Integer): string;
var
  LUp: Integer;
begin
  Result := '';
  LUp := LM.Tree.Nodes[ANode].Parent;
  while LUp <> NIL_NODE do
  begin
    case LM.Tree.Nodes[LUp].Kind of
      nkInitSec:
        Exit('initialization');
      nkFinalSec:
        Exit('finalization');
      nkBlock:
        if LM.Tree.Nodes[LM.Tree.Nodes[LUp].Parent].Kind in [nkProgram,
           nkLibrary] then
          Exit('main block');
      nkTypeDecl, nkConstDecl, nkVarDecl:
        Exit;
    end;
    LUp := LM.Tree.Nodes[LUp].Parent;
  end;
end;

function SiteKey(const AFile: string; ALine, ACol: Integer): string;
begin
  Result := LowerCase(AFile) + ':' + IntToStr(ALine) + ':' + IntToStr(ACol);
end;

// '1 call', '3 calls'.
function Plural(ACount: Integer; const AWord: string): string;
begin
  Result := IntToStr(ACount) + ' ' + AWord + IfThen(ACount = 1, '', 's');
end;

// Does a class stream - a TPersistent descendant, compiled {$M+}? Its unnamed
// first section is then published: where a form's components and event
// handlers sit.
function StreamsX(AA: TMcpAnalysis; AClass: TSemaXType): Boolean;
begin
  for var LDepth := 1 to 64 do
  begin
    if not XValid(AClass) then
      Break;
    if AA.Proj.Model(AClass.UnitId).Symbols[AClass.Sym].NameLower =
       'tpersistent' then
      Exit(True);
    AClass := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(AClass));
  end;
  Result := False;
end;

// A method a form's .dfm can bind by name: published - written so, or in the
// unnamed first section of a class that streams.
function IsPublishedMethod(AA: TMcpAnalysis; AMid, ASym: Integer): Boolean;
var
  LK: TSemaXType;
begin
  Result := False;
  LK := OwnerClassX(AA, AMid, ASym);
  if not XValid(LK) then
    Exit;
  case AA.Proj.Model(AMid).Symbols[ASym].Visibility of
    svPublished:
      Result := True;
    svDefault:
      Result := StreamsX(AA, LK);
  end;
end;

type
  { The callers of one routine, level by level (SPEC 9.3.1). A row is a
    reference that reaches a routine of the walk: bound to it, or to a symbol
    a call can be written against and still end up running it - the virtual
    method it overrides, an interface method it implements, a property it is
    the accessor of - and a bare `inherited;`, which names nothing a
    reference search could find. Each analysis searches with its own symbol
    ids; rows merge by site, like every answer.
    The roots are the routine asked about - or, for impact, every declaration
    a change touches, a root that is no routine searched for its uses. }
  TCallerWalk = class
  private
    FWs: TMcpWorkspace;
    FEnclosing: TEnclosing;
    FNodes: TList<TCallNode>;
    FNodeOf: TDictionary<string, Integer>;      // declaration site -> node
    FFound: TDictionary<string, TTarget>;       // callers met, not yet nodes
    FCallerOf: TDictionary<string, string>;     // analysis:model:routine node -> site
    FSeen: TDictionary<string, Boolean>;        // row sites, over every level
    FRows: TList<TCallRow>;                     // the level being searched
    FThroughOf: TObjectDictionary<Integer, TStringList>;   // root -> its other sources
    FBelowOf: TObjectDictionary<Integer, TStringList>;     // root -> its overrides
    FNotes: TStringList;                        // what the rows cannot show
    FListings: TDictionary<string, TArray<TIfaceListing>>;   // by class
    FIfaceNames: TDictionary<string, Boolean>;  // analysis:method name
    FIfaceScanned: TDictionary<Integer, Boolean>;
    FCompiled: Integer;
    FReached: Integer;      // calls found, a site listed before included
    FCurrent: Integer;      // the node being searched
    FTagRoots: Boolean;     // several roots: a first-level row names its own
    FViaOnRows: Boolean;    // no header says "all through X" for the rows
    procedure NoteThrough(const ASource: TCallSource);
    procedure NoteBelow(const AText: string);
    function Listed(ALists: TObjectDictionary<Integer, TStringList>;
      ANode: Integer): TArray<string>;
    function IsInterfaceMethodName(AA: TMcpAnalysis;
      const ANameLower: string): Boolean;
    function Listings(AA: TMcpAnalysis;
      const AClass: TSemaXType): TArray<TIfaceListing>;
    function CallerOf(AA: TMcpAnalysis; LM: TPasSemaModel; AMid,
      ANode: Integer): string;
    function CallerOfSym(AA: TMcpAnalysis; AMid, ASym: Integer): string;
    procedure AddRow(const AHit: TPasRefHit; const ANode: TCallNode;
      const AVia, ANote, ACaller: string; ACall: Boolean);
    procedure SearchRefs(AA: TMcpAnalysis; const ANode: TCallNode;
      ASources: TList<TCallSource>; const AClass: TSemaXType;
      AReturns, AVirtual: Boolean);
    procedure SearchBareInherited(AA: TMcpAnalysis; const ANode: TCallNode;
      ADMid, ADSym: Integer);
    procedure SearchFormBindings(AA: TMcpAnalysis; const ANode: TCallNode);
    procedure Search(AA: TMcpAnalysis; const ANode: TCallNode);
    procedure SearchUses(AA: TMcpAnalysis; const ANode: TCallNode);
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    // A root: searched for its callers, or - AData - for its uses. The node
    // index; -1 when that declaration is a root already.
    function AddRoot(const ATarget: TTarget; AData: Boolean): Integer;
    // The walk from the roots, level by level: the rows of each into ALevels,
    // grouped by file under the routine they sit in, `limit` rows over all.
    procedure Walk(ADepth, ALimit: Integer; ALevels: TStringBuilder;
      out AInfo: TCallWalkInfo);
    // What the rows cannot show: the ends of the walk, the notes, what was
    // not searched.
    procedure AppendNotes(ASb: TStringBuilder; const AInfo: TCallWalkInfo;
      ADepth: Integer);
    // A root's other sources - `TShape.Area (virtual)` - in the order met.
    function Through(ANode: Integer): TArray<string>;
    // A root's overrides below it - `TCircle (uShapes.pas:26)` - sorted.
    function Below(ANode: Integer): TArray<string>;
    function Answer(const ATarget: TTarget; ADepth, ALimit: Integer): string;
    property Nodes: TList<TCallNode> read FNodes;
    property ViaOnRows: Boolean read FViaOnRows write FViaOnRows;
  end;

// '3 calls in 3 routines; depth 2: 2 in 2' - the levels of a walk, each with
// the references it found that call nothing. ANoun names the first level's
// rows; '' leaves them a bare count. AThem: those references do not call
// "them", the roots, rather than "it". The form lines of a level bind a
// handler to an event - or, for uses (ANoun ''), name a component or a class.
function LevelsSummary(const AInfo: TCallWalkInfo; const ANoun: string;
  AThem: Boolean): string;
var
  LL: TCallLevel;
  LFormWord: string;
begin
  Result := '';
  LFormWord := IfThen(ANoun = '', 'form line', 'form binding');
  for var LIdx := 0 to High(AInfo.Levels) do
  begin
    LL := AInfo.Levels[LIdx];
    if LIdx = 0 then
    begin
      if ANoun <> '' then
        Result := Plural(LL.Calls, ANoun)
      else
        Result := IntToStr(LL.Calls);
      Result := Result + ' in ' + Plural(LL.Routines, 'routine');
    end
    else if (LL.Calls = 0) and (LL.Bindings > 0) then
    begin
      // Form lines alone: `depth 2: 2 form bindings`, not `0 in 0`.
      Result := Result + Format('; depth %d: %s', [LIdx + 1,
        Plural(LL.Bindings, LFormWord)]);
      LL.Bindings := 0;
    end
    else
      Result := Result + Format('; depth %d: %d in %d', [LIdx + 1, LL.Calls,
        LL.Routines]);
    if LL.Others = 1 then
      Result := Result + ', 1 reference that does not call ' + IfThen(AThem,
        'them', 'it')
    else if LL.Others > 1 then
      Result := Result + Format(', %d references that do not call %s',
        [LL.Others, IfThen(AThem, 'them', 'it')]);
    if LL.Bindings > 0 then
      Result := Result + ', ' + Plural(LL.Bindings, LFormWord);
  end;
end;

// A first level with no call - nothing is below it: none found, or only
// references that hand the roots on, or the form lines that bind them to an
// event. AThem: several roots. AData: some of them are no routine (impact),
// and their form lines name them - a component's object line - rather than
// bind an event.
function NoCallsSummary(const AL: TCallLevel; AThem, AData: Boolean): string;
begin
  if (AL.Others = 0) and (AL.Bindings = 0) then
    Exit('none found');
  Result := IfThen(AData, 'none in code', 'no calls');
  if AL.Others > 0 then
    Result := Result + Format(', %s that %s not call %s', [Plural(AL.Others,
      'reference'), IfThen(AL.Others = 1, 'does', 'do'), IfThen(AThem, 'them',
      'it')]);
  if (AL.Bindings > 0) and AData then
    Result := Result + ', ' + Plural(AL.Bindings, 'form line')
  else if AL.Bindings > 0 then
    Result := Result + Format(', %s - an event of the component runs %s',
      [Plural(AL.Bindings, 'form binding'), IfThen(AThem, 'them', 'it')]);
end;

constructor TCallerWalk.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FEnclosing := TEnclosing.Create(AWs);
  FNodes := TList<TCallNode>.Create;
  FNodeOf := TDictionary<string, Integer>.Create;
  FFound := TDictionary<string, TTarget>.Create;
  FCallerOf := TDictionary<string, string>.Create;
  FSeen := TDictionary<string, Boolean>.Create;
  FRows := TList<TCallRow>.Create;
  FThroughOf := TObjectDictionary<Integer, TStringList>.Create([doOwnsValues]);
  FBelowOf := TObjectDictionary<Integer, TStringList>.Create([doOwnsValues]);
  FNotes := TStringList.Create;
  FListings := TDictionary<string, TArray<TIfaceListing>>.Create;
  FIfaceNames := TDictionary<string, Boolean>.Create;
  FIfaceScanned := TDictionary<Integer, Boolean>.Create;
end;

destructor TCallerWalk.Destroy;
begin
  FIfaceScanned.Free;
  FIfaceNames.Free;
  FListings.Free;
  FNotes.Free;
  FBelowOf.Free;
  FThroughOf.Free;
  FRows.Free;
  FSeen.Free;
  FCallerOf.Free;
  FFound.Free;
  FNodeOf.Free;
  FNodes.Free;
  FEnclosing.Free;
  inherited;
end;

// One of the root's sources other than itself, for the answer's header.
procedure TCallerWalk.NoteThrough(const ASource: TCallSource);
var
  LText: string;
  LList: TStringList;
begin
  LText := Format('%s (%s)', [ASource.Name, SOURCE_KINDS[ASource.Kind]]);
  if not FThroughOf.TryGetValue(FCurrent, LList) then
  begin
    LList := TStringList.Create;
    FThroughOf.Add(FCurrent, LList);
  end;
  if LList.IndexOf(LText) < 0 then
    LList.Add(LText);
end;

// An override below the root: what a change to its signature must follow.
procedure TCallerWalk.NoteBelow(const AText: string);
var
  LList: TStringList;
begin
  if not FBelowOf.TryGetValue(FCurrent, LList) then
  begin
    LList := TStringList.Create;
    FBelowOf.Add(FCurrent, LList);
  end;
  if LList.IndexOf(AText) < 0 then
    LList.Add(AText);
end;

function TCallerWalk.Listed(ALists: TObjectDictionary<Integer, TStringList>;
  ANode: Integer): TArray<string>;
var
  LList: TStringList;
begin
  Result := nil;
  if ALists.TryGetValue(ANode, LList) then
    Result := LList.ToStringArray;
end;

function TCallerWalk.Through(ANode: Integer): TArray<string>;
begin
  Result := Listed(FThroughOf, ANode);
end;

function TCallerWalk.Below(ANode: Integer): TArray<string>;
begin
  Result := Listed(FBelowOf, ANode);
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

{ Does any interface of the analysis declare a method named ANameLower? Most
  routines of a walk are not one, and a no here spares the class hierarchy
  search Listings makes. The names are read once per analysis per call. }
function TCallerWalk.IsInterfaceMethodName(AA: TMcpAnalysis;
  const ANameLower: string): Boolean;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  if not FIfaceScanned.ContainsKey(AA.Index) then
  begin
    FIfaceScanned.Add(AA.Index, True);
    for var LMid := 0 to AA.Proj.ModelCount - 1 do
    begin
      LM := AA.Proj.Model(LMid);
      for var LSym := 0 to LM.SymCount - 1 do
      begin
        if (LM.Symbols[LSym].Kind <> skType) or
           (LM.Symbols[LSym].TypeCat <> tcInterface) then
          Continue;
        LScope := LM.Symbols[LSym].MemberScope;
        if (LScope = NIL_SCOPE) or (LScope >= LM.Scopes.Count) then
          Continue;
        for var LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
          if LM.Symbols[LM.Scopes[LScope].Symbols[LIdx]].Kind = skRoutine then
            FIfaceNames.AddOrSetValue(IntToStr(AA.Index) + ':' +
              LM.Symbols[LM.Scopes[LScope].Symbols[LIdx]].NameLower, True);
      end;
    end;
  end;
  Result := FIfaceNames.ContainsKey(IntToStr(AA.Index) + ':' + ANameLower);
end;

{ Every interface a method of AClass can be called through, with the class
  that lists it: the class and its ancestors - whose members, overridden or
  not, implement it - and its descendants, which may take an interface on
  and leave AClass's method to implement it. Asked once per class. }
function TCallerWalk.Listings(AA: TMcpAnalysis;
  const AClass: TSemaXType): TArray<TIfaceListing>;
var
  LKey: string;
  LList: TList<TIfaceListing>;
  LK: TSemaXType;

  procedure AddClass(const AClassX: TSemaXType);
  var
    LL: TIfaceListing;
  begin
    LL.Lister := AClassX;
    for var LI in ListedInterfaces(AA, AClassX) do
    begin
      LL.Iface := LI;
      LList.Add(LL);
    end;
  end;

begin
  LKey := Format('%d:%d:%d', [AA.Index, AClass.UnitId, AClass.Sym]);
  if FListings.TryGetValue(LKey, Result) then
    Exit;
  LList := TList<TIfaceListing>.Create;
  try
    LK := AClass;
    for var LDepth := 1 to 64 do
    begin
      if StructDefNode(AA, LK) = NIL_NODE then
        Break;
      AddClass(LK);
      LK := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LK));
    end;
    for var LD in AA.Nav.FindDescendants(AClass.UnitId, AClass.Sym) do
      if LD.Kind = pdkDescendant then
        AddClass(XPlain(LD.UnitId, LD.Sym));
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
  FListings.Add(LKey, Result);
end;

// The declaration site of routine (AMid, ASym), remembered with its target
// for the next level; '' when it has none.
function TCallerWalk.CallerOfSym(AA: TMcpAnalysis; AMid,
  ASym: Integer): string;
var
  LT: TTarget;
begin
  Result := '';
  LT := Default(TTarget);
  LT.Ids := NewIds(FWs);
  if not FillSymbolTarget(FWs, AA, AMid, ASym, LT) then
    Exit;
  Result := SiteKey(LT.DeclFile, LT.DeclLine, LT.DeclCol);
  if not FNodeOf.ContainsKey(Result) and not FFound.ContainsKey(Result) then
    FFound.Add(Result, LT);
end;

// The routine a reference sits in, as its declaration site: the symbol its
// implementation header's name resolves to - the declaration's, overload
// and all (SymbolAt pairs the two headers).
function TCallerWalk.CallerOf(AA: TMcpAnalysis; LM: TPasSemaModel; AMid,
  ANode: Integer): string;
var
  LRoutine, LFirstVis, LLastVis, LFileId, LLine, LCol, LCMid, LCSym: Integer;
  LKey, LName: string;
begin
  Result := '';
  LRoutine := BodyRoutineOf(LM, ANode);
  if LRoutine = NIL_NODE then
    Exit;
  LKey := Format('%d:%d:%d', [AA.Index, AMid, LRoutine]);
  if FCallerOf.TryGetValue(LKey, Result) then
    Exit;
  DeclName(LM, LRoutine, LFirstVis, LLastVis);
  if VisPos(LM, LLastVis, LFileId, LLine, LCol) and (LFileId = 0) and
     AA.Nav.SymbolAt(AMid, LLine, LCol, LCMid, LCSym, LName) then
    Result := CallerOfSym(AA, LCMid, LCSym);
  FCallerOf.Add(LKey, Result);
end;

procedure TCallerWalk.AddRow(const AHit: TPasRefHit; const ANode: TCallNode;
  const AVia, ANote, ACaller: string; ACall: Boolean);
var
  LKey: string;
  LRow: TCallRow;
begin
  if AHit.FilePath = '' then
    Exit;
  // Counted before the de-duplication: a routine whose calls were all
  // listed a level up has callers all the same. A routine only handed on
  // (`OnClick := Foo`) has none.
  if ACall then
    Inc(FReached);
  LKey := SiteKey(AHit.FilePath, AHit.Line, AHit.Col);
  if FSeen.ContainsKey(LKey) then
    Exit;
  FSeen.Add(LKey, True);
  if SameText(TPath.GetExtension(AHit.FilePath), '.dcu') then
  begin
    Inc(FCompiled);
    Exit;
  end;
  LRow.Hit.FilePath := AHit.FilePath;
  LRow.Hit.Line := AHit.Line;
  LRow.Hit.Col := AHit.Col;
  LRow.Hit.Snippet := AHit.Snippet;
  LRow.Hit.Tag := '';
  LRow.Hit.Own := FWs.IsOwnFile(AHit.FilePath);
  LRow.Caller := ACaller;
  LRow.Call := ACall;
  LRow.Binding := False;
  LRow.Callee := '';
  if (ANode.Level > 0) or FTagRoots then
    LRow.Callee := ANode.Name;
  LRow.Via := AVia;
  LRow.Note := ANote;
  FRows.Add(LRow);
end;

// The references of every source, the sources growing as accessors and
// resolution clauses turn up among them.
procedure TCallerWalk.SearchRefs(AA: TMcpAnalysis; const ANode: TCallNode;
  ASources: TList<TCallSource>; const AClass: TSemaXType;
  AReturns, AVirtual: Boolean);
var
  LS, LNew: TCallSource;
  LIdx, LMid, LUp, LChild, LNamed, LFileId, LLine, LCol: Integer;
  LM: TPasSemaModel;
  LIdent: TPasNavIdent;
  LNodeOk, LKnown: Boolean;
  LUse: TRefUse;
  LNote, LCaller, LName: string;
begin
  LIdx := 0;
  while LIdx < ASources.Count do
  begin
    LS := ASources[LIdx];
    Inc(LIdx);
    for var LH in AA.Nav.FindReferences(LS.Mid, LS.Sym) do
    begin
      LM := nil;
      LMid := AA.Nav.ModelIdOf(LH.FilePath);
      LNodeOk := (LMid >= 0) and AA.Nav.IdentAt(LMid, LH.Line, LH.Col, LIdent);
      if LNodeOk then
      begin
        LM := AA.Proj.Model(LMid);
        if IsPropertyDeclName(LM, LIdent.Node) then
          Continue;
        // A property: a write calls its setter, anything else its getter.
        if (LS.Kind = csRead) and IsAssignTarget(LM, LIdent.Node) then
          Continue;
        if (LS.Kind = csWrite) and not IsAssignTarget(LM, LIdent.Node) then
          Continue;
      end;
      LUse := ruCall;
      if LNodeOk and (LS.Kind in [csSelf, csVirtual, csInterface]) then
        LUse := RefUse(AA, LM, LMid, LIdent.Node, AReturns);
      case LUse of
        ruNone:
          Continue;
        ruRead, ruWrite, ruMaps:
          begin
            // Not a row: the property, or the interface method a resolution
            // clause maps to it, is one more source. A property's name is its
            // first child; a clause's segments are flat siblings, `IFoo.Bar =
            // Foo`, the method the one before the routine's.
            LNamed := NIL_NODE;
            if LUse = ruMaps then
            begin
              LChild := LM.Tree.Nodes[LM.Tree.Nodes[LIdent.Node].Parent].
                FirstChild;
              while (LChild <> NIL_NODE) and (LChild <> LIdent.Node) do
              begin
                if LM.Tree.Nodes[LChild].Kind = nkIdent then
                  LNamed := LChild;
                LChild := LM.Tree.Nodes[LChild].NextSibling;
              end;
            end
            else
            begin
              LUp := LM.Tree.Nodes[LIdent.Node].Parent;
              while (LUp <> NIL_NODE) and
                    (LM.Tree.Nodes[LUp].Kind <> nkPropertyDecl) do
                LUp := LM.Tree.Nodes[LUp].Parent;
              if LUp <> NIL_NODE then
                LNamed := LM.Tree.Nodes[LUp].FirstChild;
            end;
            LNew := Default(TCallSource);
            if (LNamed = NIL_NODE) or not VisPos(LM,
               LM.Tree.NodeLeftmostVis(LNamed), LFileId, LLine, LCol) or
               (LFileId <> 0) or not AA.Nav.SymbolAt(LMid, LLine, LCol,
               LNew.Mid, LNew.Sym, LName) then
              Continue;
            case LUse of
              ruRead: LNew.Kind := csRead;
              ruWrite: LNew.Kind := csWrite;
            else
              LNew.Kind := csInterface;
            end;
            LKnown := False;
            for var LOld in ASources do
              if (LOld.Mid = LNew.Mid) and (LOld.Sym = LNew.Sym) and
                 (LOld.Kind = LNew.Kind) then
                LKnown := True;
            if LKnown then
              Continue;
            LNew.Name := QualifiedName(AA.Proj.Model(LNew.Mid), LNew.Sym);
            ASources.Add(LNew);
            if ANode.Level = 0 then
              NoteThrough(LNew);
            LName := Format('%s is the default array property: `X[I]` uses '
              + 'it without its name, and those uses are not found',
              [LNew.Name]);
            if (LUse <> ruMaps) and IsDefaultArrayProperty(LM, LNamed) and
               (FNotes.IndexOf(LName) < 0) then
              FNotes.Add(LName);
            Continue;
          end;
      end;
      // Through a virtual slot - an ancestor's method, or a property whose
      // accessor this virtual method is - only an object that runs this
      // implementation counts; `inherited X` is a static call of X's own.
      if LNodeOk and ((LS.Kind = csVirtual) or ((LS.Kind in [csRead,
         csWrite]) and AVirtual)) and (((LS.Kind = csVirtual) and
         UnderInherited(LM, LIdent.Node)) or not MayRun(AA, LM, LMid,
         LIdent.Node, AClass, ANode.T.Ids[AA.Index].Mid,
         ANode.T.Ids[AA.Index].Sym)) then
        Continue;
      LCaller := '';
      LNote := '';
      if LUse = ruValue then
        LNote := 'not a call'
      else if LUse = ruExported then
        LNote := 'exported'
      else if LNodeOk then
      begin
        LCaller := CallerOf(AA, LM, LMid, LIdent.Node);
        if LCaller = '' then
          LNote := RootPlace(LM, LIdent.Node);
      end;
      AddRow(LH, ANode, IfThen(LS.Kind <> csSelf, LS.Name, ''), LNote,
        LCaller, LUse in [ruCall, ruExported]);
    end;
  end;
end;

// A bare `inherited;` in override (ADMid, ADSym) that calls the node's
// routine: no name node, so no reference search finds it.
procedure TCallerWalk.SearchBareInherited(AA: TMcpAnalysis;
  const ANode: TCallNode; ADMid, ADSym: Integer);
var
  LHit, LRow: TPasRefHit;
  LDm, LRoutine, LFileId, LLine, LCol: Integer;
  LNavT, LTo: TPasNavTarget;
  LM: TPasSemaModel;
  LCaller: string;
begin
  if not AA.Nav.DeclHit(ADMid, ADSym, LHit) then
    Exit;
  LDm := AA.Nav.ModelIdOf(LHit.FilePath);
  if (LDm < 0) or not AA.Proj.EnsureHydrated(LDm) or
     not AA.Nav.GotoImplementation(LDm, LHit.Line, LHit.Col, LNavT) or
     not AA.Proj.EnsureHydrated(LNavT.UnitId) then
    Exit;
  LM := AA.Proj.Model(LNavT.UnitId);
  if FileIdOf(LM, LNavT.FilePath) <> 0 then
    Exit;   // GotoBareInherited reads the main file only
  LRoutine := RoutineNodeAt(LM, 0, LNavT.Line, LNavT.Col);
  if LRoutine = NIL_NODE then
    Exit;
  LCaller := '';
  for var LVis := LM.Tree.NodeLeftmostVis(LRoutine) to
      LM.Tree.Nodes[LRoutine].LastToken - 1 do
    if (LM.Tree.Source.VisibleToken(LVis).Kind = tkInherited) and
       (LM.Tree.Source.VisibleToken(LVis + 1).Kind <> tkIdentifier) and
       VisPos(LM, LVis, LFileId, LLine, LCol) and (LFileId = 0) and
       AA.Nav.GotoBareInherited(LNavT.UnitId, LLine, LCol, LTo) and
       SameText(LTo.FilePath, ANode.T.DeclFile) and
       (LTo.Line = ANode.T.DeclLine) and (LTo.Col = ANode.T.DeclCol) then
    begin
      if LCaller = '' then
        LCaller := CallerOfSym(AA, ADMid, ADSym);
      LRow := Default(TPasRefHit);
      LRow.FilePath := LNavT.FilePath;
      LRow.Line := LLine;
      LRow.Col := LCol;
      LRow.Snippet := LM.Tree.Source.Files[0].LineText(LLine);
      AddRow(LRow, ANode, '', '', LCaller, True);
    end;
end;

{ The form file lines that bind the node's routine to an event - `OnClick =
  btnSaveClick` - as rows under the component (FormObjectPath). An event
  runs it, no code calls it: such a handler had "none found", and at a
  deeper level the binding is where a chain of calls starts - the button
  that runs it. Only a published method can be bound, and only its own
  symbol is: the form's class finds the method by name (TReader, through
  MethodAddress), and the binder resolves each line to the one it finds.
  A root that is no routine (impact's data roots) has every line naming it:
  a component's `object` line, a `FocusControl = edtName`, a class in an
  object header - a form that no longer loads when the field or the class
  is renamed or removed. }
procedure TCallerWalk.SearchFormBindings(AA: TMcpAnalysis;
  const ANode: TCallNode);
var
  LMid, LSym: Integer;
  LKey: string;
  LRow: TCallRow;
begin
  LMid := ANode.T.Ids[AA.Index].Mid;
  LSym := ANode.T.Ids[AA.Index].Sym;
  if (LMid < 0) or (LSym < 0) or
     (not ANode.Data and not IsPublishedMethod(AA, LMid, LSym)) then
    Exit;
  for var LS in AA.Nav.FindFormSites(LMid, LSym) do
  begin
    if (LS.FilePath = '') or (LS.Kind = fskCaption) or
       (not ANode.Data and (LS.Kind <> fskHandler)) then
      Continue;
    Inc(FReached);
    LKey := SiteKey(LS.FilePath, LS.Line, LS.Col);
    if not FSeen.TryAdd(LKey, True) then
      Continue;
    LRow := Default(TCallRow);
    LRow.Hit.FilePath := LS.FilePath;
    LRow.Hit.Line := LS.Line;
    LRow.Hit.Col := LS.Col;
    LRow.Hit.Snippet := LS.Snippet;
    LRow.Hit.Own := FWs.IsOwnFile(LS.FilePath);
    LRow.Hit.Where := FormObjectPath(LS);
    if LS.IsBinary then
      LRow.Hit.FileNote := 'binary - lines of its text conversion';
    LRow.Binding := True;
    if (ANode.Level > 0) or FTagRoots then
      LRow.Callee := ANode.Name;
    if LS.Via = fsvAncestor then
      LRow.Note := 'ancestor''s form';
    FRows.Add(LRow);
  end;
end;

// The rows of one routine of the walk, in one analysis.
procedure TCallerWalk.Search(AA: TMcpAnalysis; const ANode: TCallNode);
var
  LRMid, LRSym, LDm, LTMid, LTSym, LIdx, LFMid, LFSym, LCtx: Integer;
  LImplemented, LVirtual: Boolean;
  LHead: TPasRoutineHead;
  LRM, LIM: TPasSemaModel;
  LClass, LCx, LK: TSemaXType;
  LSources: TList<TCallSource>;
  LBelow: TList<TSymId>;
  LSrc: TCallSource;
  LFamily: TArray<TPasOverrideHit>;
  LByClass: TDictionary<string, Integer>;
  LReaches: TDictionary<string, Boolean>;
  LName, LNameLower: string;
  LId: TSymId;

  function Key(AMid, ASym: Integer): string;
  begin
    Result := IntToStr(AMid) + ':' + IntToStr(ASym);
  end;

  procedure AddSource(AMid, ASym: Integer; AKind: TCallSourceKind);
  begin
    LSrc.Mid := AMid;
    LSrc.Sym := ASym;
    LSrc.Kind := AKind;
    LSrc.Name := QualifiedName(AA.Proj.Model(AMid), ASym);
    LSources.Add(LSrc);
    LReaches.AddOrSetValue(Key(AMid, ASym), True);
    if (ANode.Level = 0) and (AKind <> csSelf) then
      NoteThrough(LSrc);
  end;

begin
  LRMid := ANode.T.Ids[AA.Index].Mid;
  LRSym := ANode.T.Ids[AA.Index].Sym;
  if (LRMid < 0) or (LRSym < 0) then
    Exit;
  LRM := AA.Proj.Model(LRMid);
  LNameLower := LRM.Symbols[LRSym].NameLower;
  LHead := LRM.RoutineHead(LRSym);
  LSources := TList<TCallSource>.Create;
  LBelow := TList<TSymId>.Create;
  LByClass := TDictionary<string, Integer>.Create;
  LReaches := TDictionary<string, Boolean>.Create;
  try
    AddSource(LRMid, LRSym, csSelf);
    LVirtual := False;
    LClass := OwnerClassX(AA, LRMid, LRSym);
    if XValid(LClass) then
    begin
      // The virtual chain (FindOverrides answers only for a dispatchable
      // method - MethodAt is its gate, at the declaration site): up from the
      // class, the declaration in each ancestor that has one, to the one that
      // introduced the slot - a `reintroduce` starts a chain of its own. Down,
      // the overrides a bare `inherited;` can call it from.
      LDm := AA.Nav.ModelIdOf(ANode.T.DeclFile);
      LVirtual := (LDm >= 0) and AA.Proj.EnsureHydrated(LDm) and
        AA.Nav.MethodAt(LDm, ANode.T.DeclLine, ANode.T.DeclCol, LTMid, LTSym,
        LName);
      if LVirtual then
      begin
        LFamily := AA.Nav.FindOverrides(LTMid, LTSym);
        LIdx := -1;
        for var LI := 0 to High(LFamily) do
        begin
          LCx := OwnerClassX(AA, LFamily[LI].UnitId, LFamily[LI].Sym);
          if XValid(LCx) then
            LByClass.AddOrSetValue(Key(LCx.UnitId, LCx.Sym), LI);
          if (LFamily[LI].UnitId = LTMid) and (LFamily[LI].Sym = LTSym) then
            LIdx := LI
          else if XValid(LCx) and (LFamily[LI].Kind in [pokOverride,
            pokMessage]) and AA.Proj.XDescendsFrom(LCx, LClass) then
          begin
            LId.Mid := LFamily[LI].UnitId;
            LId.Sym := LFamily[LI].Sym;
            LBelow.Add(LId);
            if ANode.Level = 0 then
              NoteBelow(Format('%s (%s:%d)', [LFamily[LI].TypeName,
                FWs.RelPath(LFamily[LI].Hit.FilePath), LFamily[LI].Hit.Line]));
          end;
        end;
        if (LIdx < 0) or not (LFamily[LIdx].Kind in [pokRoot,
           pokReintroduce]) then
        begin
          LK := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LClass));
          for var LDepth := 1 to 64 do
          begin
            if not XValid(LK) then
              Break;
            if LByClass.TryGetValue(Key(LK.UnitId, LK.Sym), LIdx) then
            begin
              AddSource(LFamily[LIdx].UnitId, LFamily[LIdx].Sym, csVirtual);
              if LFamily[LIdx].Kind in [pokRoot, pokReintroduce] then
                Break;
            end;
            LK := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LK));
          end;
        end;
      end
      else if LHead = rhConstructor then
        // A constructor that is not virtual: `inherited;` in a descendant's
        // constructor of the same name.
        for var LD in AA.Nav.FindDescendants(LClass.UnitId, LClass.Sym) do
        begin
          if LD.Kind <> pdkDescendant then
            Continue;
          LIM := AA.Proj.Model(LD.UnitId);
          LTSym := LIM.FindLocal(LIM.Symbols[LD.Sym].MemberScope, LNameLower);
          while LTSym <> NIL_SYM do
          begin
            if LIM.RoutineHead(LTSym) = rhConstructor then
            begin
              LId.Mid := LD.UnitId;
              LId.Sym := LTSym;
              LBelow.Add(LId);
            end;
            LTSym := LIM.Symbols[LTSym].NextOverload;
          end;
        end;
      // The interface methods it - or a virtual method it overrides - runs
      // for: same-named methods of an interface a class lists, when the
      // member that name finds from that class is one of them. Matched by
      // name, as dcc pairs them (overloads by signature, not told apart
      // here). FindImplementations is not asked: it answers only for the
      // interface a class lists itself, not for one that interface extends.
      if IsInterfaceMethodName(AA, LNameLower) then
        for var LL in Listings(AA, LClass) do
        begin
          LIM := AA.Proj.Model(LL.Iface.UnitId);
          LTSym := LIM.FindLocal(LIM.Symbols[LL.Iface.Sym].MemberScope,
            LNameLower);
          if (LTSym = NIL_SYM) or LReaches.ContainsKey(Key(LL.Iface.UnitId,
             LTSym)) or not AA.Proj.FindMemberX(LL.Lister.UnitId, LL.Lister,
             LNameLower, LFMid, LFSym, LCtx) then
            Continue;
          LImplemented := False;
          while (LFSym <> NIL_SYM) and not LImplemented do
          begin
            LImplemented := LReaches.ContainsKey(Key(LFMid, LFSym));
            LFSym := AA.Proj.Model(LFMid).Symbols[LFSym].NextOverload;
          end;
          if not LImplemented then
            Continue;
          while LTSym <> NIL_SYM do
          begin
            if (LIM.Symbols[LTSym].Kind = skRoutine) and
               not LReaches.ContainsKey(Key(LL.Iface.UnitId, LTSym)) then
              AddSource(LL.Iface.UnitId, LTSym, csInterface);
            LTSym := LIM.Symbols[LTSym].NextOverload;
          end;
        end;
    end;
    SearchRefs(AA, ANode, LSources, LClass, LHead in [rhFunction,
      rhConstructor], LVirtual);
    for var LB in LBelow do
      SearchBareInherited(AA, ANode, LB.Mid, LB.Sym);
    SearchFormBindings(AA, ANode);
  finally
    LReaches.Free;
    LByClass.Free;
    LBelow.Free;
    LSources.Free;
  end;
end;

// The uses of a root that is no routine (impact) - a type, a variable, a
// constant, a field, a property - in one analysis: every reference is one.
// A field a property reads or writes is used wherever the property is, so
// the property becomes one more source, as a getter's does in Search.
procedure TCallerWalk.SearchUses(AA: TMcpAnalysis; const ANode: TCallNode);
var
  LSources: TList<TCallSource>;
  LS, LNew: TCallSource;
  LIdx, LMid, LE, LP, LFileId, LLine, LCol: Integer;
  LM: TPasSemaModel;
  LIdent: TPasNavIdent;
  LNodeOk, LKnown: Boolean;
  LCaller, LNote, LName: string;
begin
  LS := Default(TCallSource);
  LS.Mid := ANode.T.Ids[AA.Index].Mid;
  LS.Sym := ANode.T.Ids[AA.Index].Sym;
  if (LS.Mid < 0) or (LS.Sym < 0) then
    Exit;
  LS.Kind := csSelf;
  LS.Name := ANode.T.Name;
  LSources := TList<TCallSource>.Create;
  try
    LSources.Add(LS);
    LIdx := 0;
    while LIdx < LSources.Count do
    begin
      LS := LSources[LIdx];
      Inc(LIdx);
      for var LH in AA.Nav.FindReferences(LS.Mid, LS.Sym) do
      begin
        LCaller := '';
        LNote := '';
        LMid := AA.Nav.ModelIdOf(LH.FilePath);
        LNodeOk := (LMid >= 0) and AA.Nav.IdentAt(LMid, LH.Line, LH.Col,
          LIdent);
        if LNodeOk then
        begin
          LM := AA.Proj.Model(LMid);
          if IsPropertyDeclName(LM, LIdent.Node) then
            Continue;
          LE := DesignatorOf(LM, LIdent.Node);
          LP := LM.Tree.Nodes[LE].Parent;
          if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkPropSpec) and
             (LM.Tree.NodeTextEquals(LP, 'read') or
              LM.Tree.NodeTextEquals(LP, 'write')) then
          begin
            // `property X: T read FX write FX` - not a row: X is one more
            // source, its name the property's first child.
            while (LP <> NIL_NODE) and
                  (LM.Tree.Nodes[LP].Kind <> nkPropertyDecl) do
              LP := LM.Tree.Nodes[LP].Parent;
            LNew := Default(TCallSource);
            if (LP = NIL_NODE) or not VisPos(LM, LM.Tree.NodeLeftmostVis(
               LM.Tree.Nodes[LP].FirstChild), LFileId, LLine, LCol) or
               (LFileId <> 0) or not AA.Nav.SymbolAt(LMid, LLine, LCol,
               LNew.Mid, LNew.Sym, LName) then
              Continue;
            LKnown := False;
            for var LOld in LSources do
              if (LOld.Mid = LNew.Mid) and (LOld.Sym = LNew.Sym) then
                LKnown := True;
            if LKnown then
              Continue;
            LNew.Kind := csProperty;
            LNew.Name := QualifiedName(AA.Proj.Model(LNew.Mid), LNew.Sym);
            LSources.Add(LNew);
            if ANode.Level = 0 then
              NoteThrough(LNew);
            Continue;
          end;
          LCaller := CallerOf(AA, LM, LMid, LIdent.Node);
          if LCaller = '' then
            LNote := RootPlace(LM, LIdent.Node);
        end;
        AddRow(LH, ANode, IfThen(LS.Kind <> csSelf, LS.Name, ''), LNote,
          LCaller, True);
      end;
    end;
    SearchFormBindings(AA, ANode);
  finally
    LSources.Free;
  end;
end;

function TCallerWalk.AddRoot(const ATarget: TTarget; AData: Boolean): Integer;
var
  LNode: TCallNode;
  LKey: string;
begin
  LKey := SiteKey(ATarget.DeclFile, ATarget.DeclLine, ATarget.DeclCol);
  if FNodeOf.ContainsKey(LKey) then
    Exit(-1);
  LNode := Default(TCallNode);
  LNode.T := ATarget;
  LNode.Name := ATarget.Name;
  // Overloads: two roots of one name are told apart by the line the later
  // one is declared on, as the callers found below them are.
  for var LOther in FNodes do
    if SameText(LOther.Name, LNode.Name) then
    begin
      LNode.Name := Format('%s (line %d)', [LNode.Name, ATarget.DeclLine]);
      Break;
    end;
  LNode.Level := 0;
  LNode.Found := -1;
  LNode.Data := AData;
  Result := FNodes.Add(LNode);
  FNodeOf.Add(LKey, Result);
end;

procedure TCallerWalk.Walk(ADepth, ALimit: Integer; ALevels: TStringBuilder;
  out AInfo: TCallWalkInfo);
var
  LNode: TCallNode;
  LFrontier, LNext: TList<Integer>;
  LRows: TArray<TCallRow>;
  LHits: TArray<THit>;
  LLevel, LShown: Integer;
  LCount: TCallLevel;
  LWho, LVias: TDictionary<string, Boolean>;
  LT: TTarget;
  LTag: string;
begin
  AInfo := Default(TCallWalkInfo);
  FTagRoots := FNodes.Count > 1;
  LFrontier := TList<Integer>.Create;
  LNext := TList<Integer>.Create;
  LWho := TDictionary<string, Boolean>.Create;
  LVias := TDictionary<string, Boolean>.Create;
  try
    for var LIdx := 0 to FNodes.Count - 1 do
      LFrontier.Add(LIdx);
    LShown := 0;
    for LLevel := 1 to ADepth do
    begin
      FRows.Clear;
      for var LIdx in LFrontier do
      begin
        var LBefore := FReached;
        FCurrent := LIdx;
        for var LA in FWs.Analyses do
          if FNodes[LIdx].T.Ids[LA.Index].Mid >= 0 then
          begin
            if FNodes[LIdx].Data then
              SearchUses(LA, FNodes[LIdx])
            else
              Search(LA, FNodes[LIdx]);
          end;
        LNode := FNodes[LIdx];
        LNode.Found := FReached - LBefore;
        FNodes[LIdx] := LNode;
      end;
      LRows := FRows.ToArray;
      TArray.Sort<TCallRow>(LRows, TComparer<TCallRow>.Construct(
        function(const L, R: TCallRow): Integer
        begin
          Result := Ord(R.Hit.Own) - Ord(L.Hit.Own);
          if Result = 0 then
            Result := CompareText(L.Hit.FilePath, R.Hit.FilePath);
          if Result = 0 then
            Result := L.Hit.Line - R.Hit.Line;
          if Result = 0 then
            Result := L.Hit.Col - R.Hit.Col;
        end));
      // The routines they are in: a call outside every routine counts once
      // per file and place.
      LWho.Clear;
      LVias.Clear;
      LCount := Default(TCallLevel);
      for var LR in LRows do
      begin
        // A binding is to the routine itself, through no other symbol.
        if LR.Binding then
        begin
          Inc(LCount.Bindings);
          Continue;
        end;
        LVias.AddOrSetValue(LR.Via, True);
        if LR.Call then
        begin
          Inc(LCount.Calls);
          if LR.Caller <> '' then
            LWho.AddOrSetValue(LR.Caller, True)
          else
            LWho.AddOrSetValue(LowerCase(LR.Hit.FilePath) + '|' + LR.Note,
              True);
        end
        else
          Inc(LCount.Others);
      end;
      LCount.Routines := LWho.Count;
      AInfo.Levels := AInfo.Levels + [LCount];
      // One symbol every row of the first level is bound to - a getter's
      // property, the virtual method an override is called through: said
      // once, above, not on every row.
      if (LLevel = 1) and (LVias.Count = 1) and not FViaOnRows then
        for var LV in LVias.Keys do
          AInfo.AllVia := LV;
      if LLevel > 1 then
        ALevels.AppendLine(Format('depth %d - callers of those:', [LLevel]));
      SetLength(LHits, Length(LRows));
      for var LI := 0 to High(LRows) do
      begin
        LHits[LI] := LRows[LI].Hit;
        LTag := '';
        if LRows[LI].Callee <> '' then
          LTag := '-> ' + LRows[LI].Callee;
        if (LRows[LI].Via <> '') and (AInfo.AllVia = '') then
          LTag := Trim(LTag + ' via ' + LRows[LI].Via);
        if LRows[LI].Note <> '' then
          LTag := IfThen(LTag = '', '', LTag + ', ') + LRows[LI].Note;
        LHits[LI].Tag := LTag;
      end;
      if (Length(LHits) = 0) and (LLevel > 1) then
        ALevels.AppendLine('  none');
      AppendHitsByFile(FWs, ALevels, LHits, Max(ALimit - LShown, 0), False,
        FEnclosing);
      Inc(LShown, Min(Length(LHits), Max(ALimit - LShown, 0)));
      // The next level: the routines these calls sit in, those of the
      // group's own files - a library routine is shown, not followed.
      LNext.Clear;
      for var LR in LRows do
      begin
        if not LR.Call or (LR.Caller = '') or FNodeOf.ContainsKey(LR.Caller) or
           not FFound.TryGetValue(LR.Caller, LT) then
          Continue;
        if not LT.Own then
        begin
          FNodeOf.Add(LR.Caller, -1);
          Inc(AInfo.Libraries);
          Continue;
        end;
        MapToOthers(FWs, LT);
        LNode := Default(TCallNode);
        LNode.T := LT;
        LNode.Name := FEnclosing.NameAt(LR.Hit.FilePath, LR.Hit.Line,
          LR.Hit.Col, False);
        if LNode.Name = '' then
          LNode.Name := LT.Name;
        // Overloads: two routines of the walk under one name are told apart
        // by the line the later one is declared on.
        for var LOther in FNodes do
          if SameText(LOther.Name, LNode.Name) then
          begin
            LNode.Name := Format('%s (line %d)', [LNode.Name, LT.DeclLine]);
            Break;
          end;
        LNode.Level := LLevel;
        LNode.Found := -1;
        FNodes.Add(LNode);
        FNodeOf.Add(LR.Caller, FNodes.Count - 1);
        LNext.Add(FNodes.Count - 1);
      end;
      LFrontier.Clear;
      LFrontier.AddRange(LNext);
      if (LFrontier.Count > 0) and (LShown >= ALimit) and (LLevel < ADepth) then
        AInfo.CutAt := LLevel + 1;
      if (LFrontier.Count = 0) or (LShown >= ALimit) then
        Break;
    end;
    if (ADepth > 1) and (LShown < ALimit) then
      AInfo.Pending := LFrontier.Count;
  finally
    LVias.Free;
    LWho.Free;
    LNext.Free;
    LFrontier.Free;
  end;
end;

procedure TCallerWalk.AppendNotes(ASb: TStringBuilder;
  const AInfo: TCallWalkInfo; ADepth: Integer);
var
  LRoots, LUnused, LDfm, LDfmData: TStringList;
  LDestructor: Boolean;
  LTrail: string;
begin
  LRoots := TStringList.Create;
  LUnused := TStringList.Create;
  LDfm := TStringList.Create;
  LDfmData := TStringList.Create;
  try
    if FCompiled > 0 then
      ASb.AppendLine(Format('(+%d in compiled units without source, not '
        + 'shown)', [FCompiled]));
    // The ends of the walk: searched, nothing found - a lone root's "none"
    // is the answer's header. A published member may be what a form's .dfm
    // binds by name.
    LDestructor := False;
    for var LI := 0 to FNodes.Count - 1 do
    begin
      if (FNodes[LI].Level = 0) and (FNodes[LI].T.Head = 'destructor') then
        LDestructor := True;
      if FNodes[LI].Found <> 0 then
        Continue;
      if (LI > 0) or FTagRoots then
      begin
        if FNodes[LI].Data then
          LUnused.Add(FNodes[LI].Name)
        else
          LRoots.Add(FNodes[LI].Name);
      end;
      for var LA in FWs.Analyses do
        if FNodes[LI].T.Ids[LA.Index].Mid >= 0 then
        begin
          if IsPublishedMethod(LA, FNodes[LI].T.Ids[LA.Index].Mid,
             FNodes[LI].T.Ids[LA.Index].Sym) then
          begin
            if FNodes[LI].Data then
              LDfmData.Add(FNodes[LI].Name)
            else
            begin
              LDfm.Add(FNodes[LI].Name);
              LTrail := TrailingFormNote(FWs, FNodes[LI].T);
              if LTrail <> '' then
                FNotes.Add(LTrail);
            end;
          end;
          Break;
        end;
    end;
    if LRoots.Count > 0 then
      ASb.AppendLine('no callers found: ' + String.Join(', ',
        LRoots.ToStringArray));
    if LUnused.Count > 0 then
      ASb.AppendLine('no uses found: ' + String.Join(', ',
        LUnused.ToStringArray));
    // The forms were read (SearchFormBindings): a published method no form
    // line binds either is what "unused" asks, not a gap in the answer.
    if LDfm.Count > 0 then
      ASb.AppendLine(Format('(%s: published, and no form file binds it '
        + 'either)', [String.Join(', ', LDfm.ToStringArray)]));
    if LDfmData.Count > 0 then
      ASb.AppendLine(Format('(%s: published, and no form file names it '
        + 'either)', [String.Join(', ', LDfmData.ToStringArray)]));
    for var LNote in FNotes do
      ASb.AppendLine('(' + LNote + ')');
    if LDestructor then
      ASb.AppendLine('(a destructor runs from Free and FreeAndNil: `related '
        + 'destructions` of its class lists those)');
    if AInfo.Libraries > 0 then
      ASb.AppendLine(Format('(%s among them, not followed)',
        [Plural(AInfo.Libraries, 'library routine')]));
    if AInfo.Pending > 0 then
      ASb.AppendLine(Format('(%s at depth %d not searched for callers%s)',
        [Plural(AInfo.Pending, 'routine'), ADepth, IfThen(ADepth < 4,
        ' - raise `depth`', '')]));
    if AInfo.CutAt > 0 then
      ASb.AppendLine(Format('(depth %d not searched: the rows reached `limit` '
        + '- raise it, or ask for the callers of one routine above)',
        [AInfo.CutAt]));
  finally
    LDfmData.Free;
    LDfm.Free;
    LUnused.Free;
    LRoots.Free;
  end;
end;

function TCallerWalk.Answer(const ATarget: TTarget; ADepth,
  ALimit: Integer): string;
var
  LSb, LLevels: TStringBuilder;
  LInfo: TCallWalkInfo;
  LThrough: TArray<string>;
begin
  LSb := TStringBuilder.Create;
  LLevels := TStringBuilder.Create;
  try
    AddRoot(ATarget, False);
    Walk(ADepth, ALimit, LLevels, LInfo);
    LSb.Append(Format('callers of %s (%s:%d)', [ATarget.Name,
      FWs.RelPath(ATarget.DeclFile), ATarget.DeclLine]));
    if LInfo.Levels[0].Calls = 0 then
      LSb.AppendLine(' - ' + NoCallsSummary(LInfo.Levels[0], False, False))
    else
      LSb.AppendLine(' - ' + LevelsSummary(LInfo, 'call', False));
    LThrough := Through(0);
    if LInfo.AllVia <> '' then
    begin
      for var LText in LThrough do
        if LText.StartsWith(LInfo.AllVia + ' (') then
          LSb.AppendLine('all through ' + LText);
    end
    else if Length(LThrough) > 0 then
      LSb.AppendLine('also through ' + String.Join(', ', LThrough));
    LSb.Append(LLevels.ToString);
    AppendNotes(LSb, LInfo, ADepth);
    Result := LSb.ToString.TrimRight;
  finally
    LLevels.Free;
    LSb.Free;
  end;
end;

function ThroughNote(AWs: TMcpWorkspace; const AT: TTarget): string;
var
  LWalk: TCallerWalk;
  LLevels: TStringBuilder;
  LInfo: TCallWalkInfo;
  LThrough: TArray<string>;
begin
  Result := '';
  LWalk := TCallerWalk.Create(AWs);
  LLevels := TStringBuilder.Create;
  try
    LWalk.AddRoot(AT, False);
    // The count is over every row; `limit` only bounds what would be shown.
    LWalk.Walk(1, 1, LLevels, LInfo);
    LThrough := LWalk.Through(0);
    if (Length(LInfo.Levels) = 0) or (LInfo.Levels[0].Calls = 0) or
       (Length(LThrough) = 0) then
      Exit;
    Result := Format('(none by name - `callers` finds %s through %s: a call '
      + 'written against %s runs this one)', [Plural(LInfo.Levels[0].Calls,
      'call'), String.Join(', ', LThrough), IfThen(Length(LThrough) = 1, 'it',
      'those')]) + sLineBreak;
  finally
    LLevels.Free;
    LWalk.Free;
  end;
end;

{ Who calls a routine (SPEC 9.3.1): `references` folded to the routines the
  calls sit in, with what a reference search cannot see - calls that may
  dispatch to it through a virtual method it overrides or an interface
  method it implements, a property read calling its getter, a bare
  `inherited;` - and, with `depth`, the callers of those. }
function ToolCallers(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LWalk: TCallerWalk;
begin
  LT := ResolveOne(AWs, AArgs);
  if not IsRoutineTarget(LT) then
    raise EToolError.CreateFmt('%s is a %s - `callers` takes a routine; '
      + '`references` lists the uses of anything', [LT.Name, LT.Head]);
  LWalk := TCallerWalk.Create(AWs);
  try
    Result := LWalk.Answer(LT, EnsureRange(ArgInt(AArgs, 'depth', 1), 1, 4),
      EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000));
  finally
    LWalk.Free;
  end;
end;

{ ---- members -------------------------------------------------------------------- }

type
  // Whose reach a members answer lists.
  TMemberView = (
    mvOwn,        // the type's own methods: every member of its own, and of
                  // the ancestors' what they reach - private ones in its unit
    mvUnit,       // code in one unit holding an object of the type
    mvPublic,     // any code
    mvProtected,  // a descendant in another unit
    mvAll);       // every member, whatever its visibility

  // A member EnumMembersX reports, in the model that declares it; Ctx is the
  // instantiation frame of the type it was reached through.
  TMemberSite = record
    Mid, Sym, Ctx: Integer;
  end;

  // A type the members are declared in: the one asked about, or an ancestor.
  TMemberGroup = record
    Decl: TSemaXType;
    Name: string;          // TCircle, TList<TFoo>, TOuter.TInner
    FilePath: string;      // set when a row of it is listed
    Own: Boolean;          // declared in a group file; a library type is counted
    Streams: Boolean;      // its unnamed first section is published
    Count: Integer;        // its members in the answer, listed or counted
  end;

  TMemberRow = record
    Group: Integer;
    FilePath: string;
    Line, Col: Integer;    // Line 0: no source, a compiled unit
    Text: string;
    Tag: string;
    Vis: TSemaVisibility;
  end;

  { A name the walk has met. A same-named member of an ancestor is the one an
    override or a redeclaration replaces, and is not listed - unless every
    routine of the name met so far keeps the inherited ones (KeepsOverloads)
    and its parameters are its own: a call by that name still reaches it. }
  TMemberName = record
    Struct: TSemaXType;    // the lowest type declaring the name
    Routines: TArray<TSymId>;
    Resolved: Boolean;     // Overload and Params are computed
    Overload: Boolean;
    Params: string;        // '|integer;|string;|' - the parameter lists met
  end;

const
  VIS_NAMES: array[TSemaVisibility] of string = ('', 'strict private',
    'private', 'strict protected', 'protected', 'public', 'published',
    'automated');

function SymKey(AMid, ASym: Integer): Int64;
begin
  Result := (Int64(AMid) shl 32) or Cardinal(ASym);
end;

// The analysis that reads a target the way diagnostics report it - the
// owner of its declaring file - else the first holding it; nil for none.
function ReportingAnalysis(AWs: TMcpWorkspace; const AT: TTarget): TMcpAnalysis;
var
  LOwner: Integer;
begin
  LOwner := AWs.OwnerAnalysis(AT.DeclFile);
  if (LOwner >= 0) and (AT.Ids[LOwner].Mid >= 0) then
    Exit(AWs.Analyses[LOwner]);
  for var LA in AWs.Analyses do
    if AT.Ids[LA.Index].Mid >= 0 then
      Exit(LA);
  Result := nil;
end;

function SameX(const AL, AR: TSemaXType): Boolean;
begin
  Result := (AL.UnitId = AR.UnitId) and (AL.Sym = AR.Sym);
end;

{ Can code of AView reach a member of visibility AVis - declared in the type
  asked about itself (AOwn, for mvOwn), or in the view's unit (ASameUnit)?
  Delphi's rules: private and protected reach the whole declaring unit,
  strict private only the class, protected - strict or not - the
  descendants' methods too. }
function MemberVisible(AView: TMemberView; AVis: TSemaVisibility; AOwn,
  ASameUnit: Boolean): Boolean;
begin
  case AVis of
    svStrictPrivate:
      Result := (AView = mvAll) or ((AView = mvOwn) and AOwn);
    svPrivate:
      Result := (AView = mvAll) or ((AView = mvOwn) and (AOwn or ASameUnit))
        or ((AView = mvUnit) and ASameUnit);
    svStrictProtected:
      Result := AView in [mvOwn, mvProtected, mvAll];
    svProtected:
      Result := (AView in [mvOwn, mvProtected, mvAll]) or
        ((AView = mvUnit) and ASameUnit);
  else
    Result := True;   // public, published, automated, an unnamed section
  end;
end;

{ Does a routine declaration leave the inherited routines of its name
  callable - say `overload`, or `override`? An override replaces one slot:
  TStringList.AddStrings(TStrings) overrides, and TStrings.AddStrings(
  TArray<string>) is still called on a TStringList. PasTree's sfOverload does
  not tell: it marks the second and later routines of a name in one scope. }
function KeepsOverloads(AA: TMcpAnalysis; AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LNode: Integer;
begin
  Result := False;
  if not AA.Proj.EnsureHydrated(AMid) then
    Exit;
  LM := AA.Proj.Model(AMid);
  LNode := LM.Symbols[ASym].DeclNode;
  while (LNode <> NIL_NODE) and (LM.Tree.Nodes[LNode].Kind <> nkRoutine) do
    LNode := LM.Tree.Nodes[LNode].Parent;
  Result := (LNode <> NIL_NODE) and (HasDirective(LM, LNode, 'overload') or
    HasDirective(LM, LNode, 'override'));
end;

// A routine's parameter types, 'integer;string;': what tells an inherited
// overload from the declaration an override replaces.
function ParamTypesKey(AA: TMcpAnalysis; AMid, ASym: Integer): string;
begin
  Result := '';
  for var LP in AA.Proj.XParamSyms(AMid, ASym) do
    Result := Result + LowerCase(AA.Proj.XTypeText(AA.Proj.SymDeclTypeX(AMid,
      LP))) + ';';
end;

{ Is the member at ASite, declared in ADecl, hidden by one of its name
  further down - an override, a redeclaration, a field or method of that
  name? The walk meets the lowest type's members first. Registers the member
  when it is not hidden. }
function MemberHidden(AA: TMcpAnalysis;
  ANames: TDictionary<string, TMemberName>; const ASite: TMemberSite;
  const ADecl: TSemaXType): Boolean;
var
  LM: TPasSemaModel;
  LKey, LParams: string;
  LName: TMemberName;
  LId: TSymId;
  LIsRoutine: Boolean;
begin
  Result := False;
  LM := AA.Proj.Model(ASite.Mid);
  LKey := LM.Symbols[ASite.Sym].NameLower;
  LIsRoutine := LM.Symbols[ASite.Sym].Kind = skRoutine;
  LId.Mid := ASite.Mid;
  LId.Sym := ASite.Sym;
  if not ANames.TryGetValue(LKey, LName) then
  begin
    LName := Default(TMemberName);
    LName.Struct := ADecl;
    if LIsRoutine then
      LName.Routines := [LId];
    ANames.Add(LKey, LName);
    Exit;
  end;
  if SameX(LName.Struct, ADecl) then
  begin
    // Another overload in the same type.
    if LIsRoutine then
      LName.Routines := LName.Routines + [LId];
    LName.Resolved := False;
    ANames[LKey] := LName;
    Exit;
  end;
  if not LIsRoutine or (Length(LName.Routines) = 0) then
    Exit(True);
  if not LName.Resolved then
  begin
    LName.Resolved := True;
    LName.Overload := True;
    LName.Params := '|';
    for var LR in LName.Routines do
    begin
      LName.Overload := LName.Overload and KeepsOverloads(AA, LR.Mid, LR.Sym);
      LName.Params := LName.Params + ParamTypesKey(AA, LR.Mid, LR.Sym) + '|';
    end;
  end;
  LParams := ParamTypesKey(AA, ASite.Mid, ASite.Sym);
  Result := not LName.Overload or (Pos('|' + LParams + '|', LName.Params) > 0);
  if not Result then
  begin
    // An inherited overload. One that keeps none itself hides the rest of
    // the name further up.
    LName.Routines := LName.Routines + [LId];
    LName.Params := LName.Params + LParams + '|';
    LName.Overload := KeepsOverloads(AA, ASite.Mid, ASite.Sym);
  end;
  ANames[LKey] := LName;
end;

// `member_kind` as KindMatches takes it, '' for none. A plural or a synonym
// is accepted: the value is the model's guess at a word.
function MemberKindArg(const AValue: string): string;
begin
  Result := LowerCase(AValue);
  if Result = 'properties' then
    Result := 'property'
  else if Result.EndsWith('s') then
    Result := Copy(Result, 1, Length(Result) - 1);
  if Result = 'routine' then
    Result := 'method'
  else if Result = 'constant' then
    Result := 'const'
  else if (Result = 'var') or (Result = 'variable') then
    Result := 'field';
  if (Result <> '') and not MatchStr(Result, ['method', 'procedure',
     'function', 'constructor', 'destructor', 'operator', 'property', 'field',
     'const', 'type']) then
    raise EToolError.CreateFmt('`member_kind` is method, property, field, '
      + 'const or type - or procedure, function, constructor, destructor, '
      + 'operator (not `%s`)', [AValue]);
end;

function MemberKindMatches(LM: TPasSemaModel; ASym: Integer;
  const AKind: string): Boolean;
begin
  if AKind = 'field' then
    Result := LM.Symbols[ASym].Kind in [skField, skVar]   // `class var` too
  else
    Result := KindMatches(LM, ASym, AKind);
end;

// '3 members', '1 property', 'no constants'.
function MemberNoun(ACount: Integer; const AKind: string): string;
var
  LWord: string;
begin
  if AKind = '' then
    LWord := 'member'
  else if AKind = 'const' then
    LWord := 'constant'
  else
    LWord := AKind;
  if ACount <> 1 then
    if LWord = 'property' then
      LWord := 'properties'
    else
      LWord := LWord + 's';
  if ACount = 0 then
    Result := 'no ' + LWord
  else
    Result := IntToStr(ACount) + ' ' + LWord;
end;

{ Every member of a type, the inherited ones included (SPEC 9.2.3): what an
  agent otherwise learns with an outline per ancestor, once it has found the
  ancestors. EnumMembersX walks them the way FindMemberX looks one up - the
  type asked about first, then each ancestor - so the first member of a name
  met is the one a call binds to, and a later one is what an override or a
  redeclaration replaces. Rows are grouped by the type declaring them, under
  the visibility section they are written in. A library ancestor of a group
  type is counted, not listed: the agent knows TForm, and a form's run of
  ancestors to TObject is some six hundred members. }
// The type written after a variable's or field's name on its declaration line
// - `array[1..44] of Byte` - for one whose type is written in place; '' when
// the line does not read that way.
function InPlaceTypeText(const AT: TTarget): string;
var
  LLines: TArray<string>;
  LLine, LName: string;
  LAt, LEnd: Integer;
begin
  Result := '';
  LLines := ReadLines(AT.DeclFile);
  if (AT.DeclLine < 1) or (AT.DeclLine > Length(LLines)) then
    Exit;
  LLine := LLines[AT.DeclLine - 1];
  LName := Copy(AT.Name, LastDelimiter('.', AT.Name) + 1, MaxInt);
  LAt := FindWord(LLine, LName);
  if LAt = 0 then
    Exit;
  LLine := Copy(LLine, LAt + Length(LName), MaxInt);
  LAt := Pos(':', LLine);
  if LAt = 0 then
    Exit;
  LLine := Copy(LLine, LAt + 1, MaxInt);
  LEnd := Pos(';', LLine);
  if LEnd > 0 then
    LLine := Copy(LLine, 1, LEnd - 1);
  Result := Trim(LLine);
  if Result <> '' then
    Result := '`' + Result + '`';
end;

function ToolMembers(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LA: TMcpAnalysis;
  LM, LDM: TPasSemaModel;
  LVisArg, LKind, LMatch, LMatchLower, LUnitFile, LHead, LHeading,
    LLastHeading, LIndent, LList, LText: string;
  LMid, LSym, LLimit, LScope, LGroupIdx, LNotVisible, LShown, LLastGroup,
    LPrevLine: Integer;
  LView: TMemberView;
  LStart, LOwnType, LDecl, LX, LNext: TSemaXType;
  LSites: TList<TMemberSite>;
  LGroups: TList<TMemberGroup>;
  LRows: TList<TMemberRow>;
  LGroupOf: TDictionary<Int64, Integer>;
  LNames: TDictionary<string, TMemberName>;
  LSeen: TDictionary<Int64, Boolean>;
  LGroup: TMemberGroup;
  LRow: TMemberRow;
  LHit: TPasRefHit;
  LSorted: TArray<TMemberRow>;
  LRemain: TArray<Integer>;
  LIsVar, LListLibrary, LPass: Boolean;
  LSb: TStringBuilder;
begin
  LVisArg := LowerCase(ArgStr(AArgs, 'visibility'));
  if LVisArg = '' then
    LView := mvOwn   // for a variable, mvUnit - below
  else if LVisArg = 'public' then
    LView := mvPublic
  else if LVisArg = 'protected' then
    LView := mvProtected
  else if (LVisArg = 'all') or (LVisArg = 'private') then
    LView := mvAll
  else
    raise EToolError.Create('`visibility` is public, protected or all - or '
      + 'left out: what the type''s own methods (for a variable, code in its '
      + 'unit) can use');
  LKind := MemberKindArg(ArgStr(AArgs, 'member_kind'));
  LMatch := ArgStr(AArgs, 'match');
  if (LMatch <> '') and (Pos('*', LMatch) = 0) and (Pos('?', LMatch) = 0) then
    LMatch := '*' + LMatch + '*';
  LMatchLower := LowerCase(LMatch);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000);
  LT := ResolveOne(AWs, AArgs);
  case LT.Kind of
    tkUnit:
      raise EToolError.CreateFmt('%s is a unit - `outline` lists its '
        + 'declarations; `members` takes a type', [LT.Name]);
    tkBuiltin, tkDefine:
      raise EToolError.CreateFmt('%s is a %s - `members` takes a type',
        [LT.Name, LT.Head]);
  end;

  LA := ReportingAnalysis(AWs, LT);
  if LA = nil then
    raise EToolError.CreateFmt('%s is in no analysis', [LT.Name]);
  LMid := LT.Ids[LA.Index].Mid;
  LSym := LT.Ids[LA.Index].Sym;
  LM := LA.Proj.Model(LMid);
  // A variable, field, property or parameter: the members of its type, as
  // code in its unit reaches them - "what can I call on this".
  LIsVar := LM.Symbols[LSym].Kind in [skVar, skField, skConst, skParam,
    skProperty];
  if LM.Symbols[LSym].Kind = skType then
    LStart := XPlain(LMid, LSym)
  else if LIsVar then
  begin
    // DeclTypeX knows an inline `var X := ...`'s inferred type; SymDeclTypeX
    // a republished property's.
    LStart := LA.Proj.DeclTypeX(LMid, LSym);
    if not XValid(LStart) then
      LStart := LA.Proj.SymDeclTypeX(LMid, LSym);
    if not XValid(LStart) then
    begin
      // A type written in place - `array[1..44] of Byte`, `string[6]` - has
      // no symbol, and no members: that is the answer, not a failure.
      LText := InPlaceTypeText(LT);
      if LText <> '' then
        Exit(Format('%s (%s) is %s - a type written in place, with no '
          + 'members', [LT.Name, LT.Head, LText]));
      raise EToolError.CreateFmt('%s (%s) has no type the analysis knows',
        [LT.Name, LT.Head]);
    end;
  end
  else
    raise EToolError.CreateFmt('%s is a %s - `members` takes a type, or a '
      + 'variable, field, property or parameter whose type it lists',
      [LT.Name, LT.Head]);
  LOwnType := LA.Proj.CanonTypeX(LStart);
  if not XValid(LOwnType) then
    LOwnType := LStart;
  LUnitFile := LA.Proj.ModelFile(LOwnType.UnitId);
  // A library type asked about is listed whole; so is every ancestor when
  // the agent looks for a name.
  LListLibrary := ArgBool(AArgs, 'library', False) or (LMatch <> '') or
    not AWs.IsOwnFile(LUnitFile);
  if LVisArg = '' then
  begin
    if LIsVar then
    begin
      LView := mvUnit;
      LUnitFile := LA.Proj.ModelFile(LMid);
    end
    // No method of a library type is the agent's to write: what its code
    // can call.
    else if not AWs.IsOwnFile(LUnitFile) then
      LView := mvPublic;
  end;

  LSites := TList<TMemberSite>.Create;
  LGroups := TList<TMemberGroup>.Create;
  LRows := TList<TMemberRow>.Create;
  LGroupOf := TDictionary<Int64, Integer>.Create;
  LNames := TDictionary<string, TMemberName>.Create;
  LSeen := TDictionary<Int64, Boolean>.Create;
  LSb := TStringBuilder.Create;
  try
    // AFromMid -1: no class helper. One is in effect where it is in scope,
    // and a type asked about has no such place.
    LA.Proj.EnumMembersX(-1, LStart,
      procedure(AMid, ASym, ACtx: Integer)
      var
        LNew: TMemberSite;
      begin
        LNew.Mid := AMid;
        LNew.Sym := ASym;
        LNew.Ctx := ACtx;
        LSites.Add(LNew);
      end);
    LNotVisible := 0;
    for var LSite in LSites do
    begin
      if LSeen.ContainsKey(SymKey(LSite.Mid, LSite.Sym)) then
        Continue;
      LSeen.Add(SymKey(LSite.Mid, LSite.Sym), True);
      LDM := LA.Proj.Model(LSite.Mid);
      if not (LDM.Symbols[LSite.Sym].Kind in [skField, skVar, skConst,
         skRoutine, skProperty, skType]) then
        Continue;   // an enumeration's values, a generic parameter
      LScope := LDM.Symbols[LSite.Sym].Scope;
      if (LScope = NIL_SCOPE) or (LScope >= LDM.Scopes.Count) or
         (LDM.Scopes[LScope].Kind <> sckStruct) or
         (LDM.Scopes[LScope].StructSym = NIL_SYM) then
        Continue;
      LDecl := XPlain(LSite.Mid, LDM.Scopes[LScope].StructSym);
      if not LGroupOf.TryGetValue(SymKey(LDecl.UnitId, LDecl.Sym), LGroupIdx)
      then
      begin
        LGroup := Default(TMemberGroup);
        LGroup.Decl := LDecl;
        LX := LDecl;
        LX.Inst := LSite.Ctx;
        if LSite.Ctx <> NIL_INST then
          LGroup.Name := LA.Proj.XTypeText(LX)
        else
          LGroup.Name := QualifiedName(LDM, LDecl.Sym);
        LGroup.Own := AWs.IsOwnFile(LA.Proj.ModelFile(LDecl.UnitId));
        LGroup.Streams := IsKindX(LA, LDecl, nkClassType) and
          StreamsX(LA, LDecl);
        LGroupIdx := LGroups.Count;
        LGroups.Add(LGroup);
        LGroupOf.Add(SymKey(LDecl.UnitId, LDecl.Sym), LGroupIdx);
      end;
      LPass := ((LKind = '') or MemberKindMatches(LDM, LSite.Sym, LKind)) and
        ((LMatchLower = '') or WildMatch(LMatchLower,
        LDM.Symbols[LSite.Sym].NameLower));
      // Out of reach does not hide: the next member of its name up is the
      // one a call from the view binds to.
      if not MemberVisible(LView, LDM.Symbols[LSite.Sym].Visibility,
         SameX(LDecl, LOwnType), SameText(LA.Proj.ModelFile(LSite.Mid),
         LUnitFile)) then
      begin
        if LPass and (LGroups[LGroupIdx].Own or LListLibrary) and
           not LNames.ContainsKey(LDM.Symbols[LSite.Sym].NameLower) then
          Inc(LNotVisible);
        Continue;
      end;
      if MemberHidden(LA, LNames, LSite, LDecl) or not LPass then
        Continue;
      LGroup := LGroups[LGroupIdx];
      Inc(LGroup.Count);
      if LGroup.Own or LListLibrary then
      begin
        if (LGroup.FilePath = '') and LA.Nav.DeclHit(LDecl.UnitId, LDecl.Sym,
           LHit) then
          LGroup.FilePath := LHit.FilePath;
        if LGroup.FilePath = '' then
          LGroup.FilePath := LA.Proj.ModelFile(LDecl.UnitId);
        LRow := Default(TMemberRow);
        LRow.Group := LGroupIdx;
        LRow.Vis := LDM.Symbols[LSite.Sym].Visibility;
        if LA.Nav.DeclHit(LSite.Mid, LSite.Sym, LHit) and
           not SameText(TPath.GetExtension(LHit.FilePath), '.dcu') then
        begin
          LRow.FilePath := LHit.FilePath;
          LRow.Line := LHit.Line;
          LRow.Col := LHit.Col;
          LRow.Text := DeclRowText(LA.Proj.Model(LSite.Mid), LSite.Sym,
            LHit.Snippet);
        end
        else
          LRow.Text := HeadOf(LDM, LSite.Sym) + ' ' +
            LDM.Symbols[LSite.Sym].Name;
        // `property Items;` republishes an inherited property, and its line
        // says nothing of the type.
        if LA.Proj.IsBarePropertyRedecl(LSite.Mid, LSite.Sym) then
        begin
          LX := LA.Proj.SymDeclTypeX(LSite.Mid, LSite.Sym);
          if XValid(LX) then
            LRow.Tag := 'type ' + LA.Proj.XTypeText(LX);
        end;
        LRows.Add(LRow);
      end;
      LGroups[LGroupIdx] := LGroup;
    end;

    // The ancestry, TDerived <- TBase <- TObject, even where no row is.
    LList := '';
    LX := LStart;
    for var LDepth := 1 to 64 do
    begin
      if not XValid(LX) then
        Break;
      LList := LList + IfThen(LList <> '', ' <- ', '') + LA.Proj.XTypeText(LX);
      LNext := LA.Proj.AncestorOfX(LX);
      if SameX(LNext, LX) then
        Break;
      LX := LNext;
    end;
    if LIsVar then
    begin
      LHead := Format('%s (%s) is a %s', [LT.Name, LT.Head, LList]);
      if LA.Nav.DeclHit(LOwnType.UnitId, LOwnType.Sym, LHit) then
        LHead := LHead + Format(' (%s:%d)', [AWs.RelPath(LHit.FilePath),
          LHit.Line]);
    end
    else
      LHead := Format('%s (%s:%d)', [LList, AWs.RelPath(LT.DeclFile),
        LT.DeclLine]);
    LHead := LHead + ': ' + MemberNoun(LRows.Count, LKind);
    if LMatch <> '' then
      LHead := LHead + ' named like ' + LMatch;
    case LView of
      mvPublic:
        LHead := LHead + ', public and published only';
      mvProtected:
        LHead := LHead + ', as a descendant in another unit sees them';
      mvAll:
        LHead := LHead + ', every visibility';
    end;
    LSb.AppendLine(LHead);

    LSorted := LRows.ToArray;
    TArray.Sort<TMemberRow>(LSorted, TComparer<TMemberRow>.Construct(
      function(const L, R: TMemberRow): Integer
      begin
        Result := L.Group - R.Group;
        if Result = 0 then
          Result := L.Line - R.Line;
        if Result = 0 then
          Result := L.Col - R.Col;
        if Result = 0 then
          Result := CompareText(L.Text, R.Text);
      end));
    //   TCircle  Shared\uShapes.pas
    //     public
    //       25  constructor Create(ARadius: Double);
    LShown := 0;
    LLastGroup := -1;
    LLastHeading := '';
    LPrevLine := -1;
    for var LR in LSorted do
    begin
      if LShown >= LLimit then
        Break;
      Inc(LShown);
      if LR.Group <> LLastGroup then
      begin
        LSb.AppendLine(LGroups[LR.Group].Name + '  ' +
          AWs.RelPath(LGroups[LR.Group].FilePath));
        LLastGroup := LR.Group;
        LLastHeading := '';
        LPrevLine := -1;
      end;
      if (LR.Vis = svDefault) and LGroups[LR.Group].Streams then
        LHeading := 'published'
      else
        LHeading := VIS_NAMES[LR.Vis];
      if (LHeading <> '') and (LHeading <> LLastHeading) then
        LSb.AppendLine('  ' + LHeading);
      LLastHeading := LHeading;
      // `FA, FB: Integer;` - one line for two members.
      if (LR.Line > 0) and (LR.Line = LPrevLine) and (LR.Tag = '') then
        Continue;
      LPrevLine := LR.Line;
      LIndent := IfThen(LHeading <> '', '    ', '  ');
      if LR.Line > 0 then
        LSb.Append(Format('%s%d  %s', [LIndent, LR.Line, LR.Text]))
      else
        LSb.Append(LIndent + LR.Text);
      if LR.Tag <> '' then
        LSb.Append('  [' + LR.Tag + ']');
      if (LR.FilePath <> '') and not SameText(LR.FilePath,
         LGroups[LR.Group].FilePath) then
        LSb.Append('  [in ' + AWs.RelPath(LR.FilePath) + ']');
      LSb.AppendLine;
    end;
    if Length(LSorted) > LShown then
    begin
      SetLength(LRemain, LGroups.Count);
      for var LIdx := LShown to High(LSorted) do
        Inc(LRemain[LSorted[LIdx].Group]);
      LList := '';
      for var LIdx := 0 to High(LRemain) do
        if LRemain[LIdx] > 0 then
          LList := LList + IfThen(LList <> '', ', ', '') + Format('%s %d',
            [LGroups[LIdx].Name, LRemain[LIdx]]);
      LSb.AppendLine(Format('... %d more (raise `limit`, or narrow with '
        + '`match` or `member_kind`): %s', [Length(LSorted) - LShown, LList]));
    end;
    LList := '';
    for var LG in LGroups do
      if not LG.Own and not LListLibrary and (LG.Count > 0) then
        LList := LList + IfThen(LList <> '', ', ', '') + Format('%s %d',
          [LG.Name, LG.Count]);
    if LList <> '' then
      LSb.AppendLine('(library ancestors, not listed - `library: true` lists '
        + 'them: ' + LList + ')');
    if LNotVisible > 0 then
      case LView of
        mvOwn:
          LSb.AppendLine(Format('(+%d not reachable from its own methods: '
            + 'ancestors'' private members - `visibility: all` lists them)',
            [LNotVisible]));
        mvUnit:
          LSb.AppendLine(Format('(+%d not reachable from code in %s: '
            + 'protected or private - `visibility: protected` or `all` lists '
            + 'them)', [LNotVisible, UnitNameOfFile(LUnitFile)]));
        mvPublic:
          LSb.AppendLine(Format('(+%d protected or private, not listed - '
            + '`visibility: protected` or `all` lists them)', [LNotVisible]));
        mvProtected:
          LSb.AppendLine(Format('(+%d private, not listed - `visibility: '
            + 'all` lists them)', [LNotVisible]));
      end;
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
    LSeen.Free;
    LNames.Free;
    LGroupOf.Free;
    LRows.Free;
    LGroups.Free;
    LSites.Free;
  end;
end;

{ ---- callees -------------------------------------------------------------------- }

const
  // The implementations of one call listed at most: a call on a TPersistent
  // may run any of hundreds of Assign overrides, and a list of them answers
  // nothing - their count does. A base class's hook, called on Self, has a
  // dozen or two overrides in a real group; a polymorphic call in its own
  // code, a handful.
  MAX_DISPATCH_ROWS = 10;
  // Classes one dispatch search looks at, whatever it finds.
  MAX_DISPATCH_CLASSES = 5000;

type
  // One call a routine of the walk makes to the routine of a row.
  TCalleeUse = record
    Caller: string;        // the routine of the walk it is in; '' the target
    Line: Integer;         // in that routine's body
    Via: string;           // what a dispatched call is written against
    Call: Boolean;         // a call - not the routine handed on
  end;

  // A routine the calls of one level reach, at its declaration.
  TCalleeRow = record
    Hit: THit;             // the declaration: its file, line and text
    T: TTarget;            // for the next level
    Calls: TArray<TCalleeUse>;
  end;

// The implementation of routine (AMid, ASym): the declaration itself when it
// has a body, else the routine around the first statement GotoImplementation
// finds. False for none - abstract, an interface method, external.
function RoutineImpl(AA: TMcpAnalysis; AMid, ASym: Integer; out AImplMid,
  ARoutine: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDm, LFileId: Integer;
  LHit: TPasRefHit;
  LNavT: TPasNavTarget;
begin
  Result := False;
  AImplMid := -1;
  ARoutine := NIL_NODE;
  if not AA.Proj.EnsureHydrated(AMid) then
    Exit;
  LM := AA.Proj.Model(AMid);
  if LM.Symbols[ASym].DeclNode = NIL_NODE then
    Exit;
  ARoutine := LM.Tree.DeclRootOf(LM.Symbols[ASym].DeclNode);
  if (ARoutine = NIL_NODE) or (LM.Tree.Nodes[ARoutine].Kind <> nkRoutine) then
    Exit;
  if HasBody(LM, ARoutine) then
  begin
    AImplMid := AMid;
    Exit(True);
  end;
  ARoutine := NIL_NODE;
  if not AA.Nav.DeclHit(AMid, ASym, LHit) then
    Exit;
  LDm := AA.Nav.ModelIdOf(LHit.FilePath);
  if LDm < 0 then
    LDm := AMid;
  if not AA.Nav.GotoImplementation(LDm, LHit.Line, LHit.Col, LNavT) or
     not AA.Proj.EnsureHydrated(LNavT.UnitId) then
    Exit;
  LM := AA.Proj.Model(LNavT.UnitId);
  LFileId := FileIdOf(LM, LNavT.FilePath);
  if LFileId < 0 then
    Exit;
  ARoutine := RoutineNodeAt(LM, LFileId, LNavT.Line, LNavT.Col);
  AImplMid := LNavT.UnitId;
  Result := (ARoutine <> NIL_NODE) and HasBody(LM, ARoutine);
end;

// A routine's body: its local declarations and its begin-end block.
function BodyNodeOf(LM: TPasSemaModel; ARoutine: Integer): Integer;
begin
  Result := LM.Tree.Nodes[ARoutine].FirstChild;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> nkRoutineBody) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

// Is the call at ANode made on a type name - `TFoo.Create(...)`,
// `TFoo.ClassMethod` - where the class, and so the implementation, is fixed?
function CalledOnType(LM: TPasSemaModel; AMid, ANode: Integer;
  AA: TMcpAnalysis): Boolean;
var
  LP, LBMid, LBSym: Integer;
begin
  LP := LM.Tree.Nodes[ANode].Parent;
  Result := (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkMember) and
    (LM.Tree.Nodes[LP].FirstChild <> ANode) and AA.Proj.DesignatorSymX(AMid,
    LM.Tree.Nodes[LP].FirstChild, LBMid, LBSym) and
    (AA.Proj.Model(LBMid).Symbols[LBSym].Kind = skType);
end;

// The class of the object a call at ANode is made on: the static type of
// `Obj` in `Obj.Foo`, Self's for a bare `Foo`. XNil when it is not a class,
// or a `with` supplies the object.
function ReceiverClassX(AA: TMcpAnalysis; LM: TPasSemaModel; AMid,
  ANode: Integer): TSemaXType;
var
  LP, LK: Integer;
begin
  Result := XNil;
  LP := LM.Tree.Nodes[ANode].Parent;
  if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkMember) and
     (LM.Tree.Nodes[LP].FirstChild <> ANode) then
    Result := AA.Proj.WithTargetTypeX(AMid, LM.Tree.Nodes[LP].FirstChild)
  else if not InWithBody(LM, ANode) then
  begin
    LK := AA.Proj.StructSymOfNode(LM, ANode);
    if LK <> NIL_SYM then
      Result := XPlain(AMid, LK);
  end;
  if XValid(Result) then
    Result := AA.Proj.CanonTypeX(Result);
  if not IsKindX(AA, Result, nkClassType) then
    Result := XNil;
end;

// The method a property access runs: its getter for a read, its setter for a
// write - through a republishing `property Items;` to the declaration that
// names one. False for a field accessor, or none.
function PropertyAccessor(AA: TMcpAnalysis; APMid, APSym: Integer;
  AWrite: Boolean; out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LChild, LPrevMid, LPrevSym: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  for var LDepth := 1 to 16 do
  begin
    if not AA.Proj.EnsureHydrated(APMid) then
      Exit;
    LM := AA.Proj.Model(APMid);
    if LM.Symbols[APSym].DeclNode = NIL_NODE then
      Exit;
    LDecl := LM.Tree.Nodes[LM.Symbols[APSym].DeclNode].Parent;
    if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkPropertyDecl) then
      Exit;
    LChild := LM.Tree.Nodes[LDecl].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and
         LM.Tree.NodeTextEquals(LChild, IfThen(AWrite, 'write', 'read')) then
        Exit(AA.Proj.DesignatorSymX(APMid, LM.Tree.Nodes[LChild].FirstChild,
          AMid, ASym) and (AA.Proj.Model(AMid).Symbols[ASym].Kind =
          skRoutine));
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    // No such specifier: a republished property takes its ancestor's.
    if not AA.Proj.PropertyRedeclPrev(APMid, APSym, LPrevMid, LPrevSym) then
      Exit;
    APMid := LPrevMid;
    APSym := LPrevSym;
  end;
end;

function IsInterfaceMethodSym(AA: TMcpAnalysis; AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  LM := AA.Proj.Model(AMid);
  LScope := LM.Symbols[ASym].Scope;
  Result := (LScope <> NIL_SCOPE) and (LScope < LM.Scopes.Count) and
    (LM.Scopes[LScope].Kind = sckStruct) and
    (LM.Scopes[LScope].StructSym <> NIL_SYM) and
    (LM.Symbols[LM.Scopes[LScope].StructSym].TypeCat = tcInterface);
end;

// A row's uses as its tag: 'at 19, 31', 'at 22 via TShape.Area',
// 'TFoo.Load at 40; at 12, not a call'.
function UsesTag(const AUses: TArray<TCalleeUse>): string;
var
  LSorted: TArray<TCalleeUse>;
  LGroup: string;
begin
  LSorted := Copy(AUses);
  TArray.Sort<TCalleeUse>(LSorted, TComparer<TCalleeUse>.Construct(
    function(const L, R: TCalleeUse): Integer
    begin
      Result := CompareText(L.Caller, R.Caller);
      if Result = 0 then
        Result := CompareText(L.Via, R.Via);
      if Result = 0 then
        Result := Ord(R.Call) - Ord(L.Call);
      if Result = 0 then
        Result := L.Line - R.Line;
    end));
  Result := '';
  LGroup := '';
  for var LIdx := 0 to High(LSorted) do
  begin
    if (LIdx = 0) or (LSorted[LIdx].Caller <> LSorted[LIdx - 1].Caller) or
       (LSorted[LIdx].Via <> LSorted[LIdx - 1].Via) or
       (LSorted[LIdx].Call <> LSorted[LIdx - 1].Call) then
      LGroup := IfThen(LSorted[LIdx].Caller <> '', LSorted[LIdx].Caller + ' ',
        '') + 'at ' + IntToStr(LSorted[LIdx].Line)
    else if LSorted[LIdx].Line <> LSorted[LIdx - 1].Line then
      LGroup := LGroup + ', ' + IntToStr(LSorted[LIdx].Line);
    if (LIdx = High(LSorted)) or
       (LSorted[LIdx + 1].Caller <> LSorted[LIdx].Caller) or
       (LSorted[LIdx + 1].Via <> LSorted[LIdx].Via) or
       (LSorted[LIdx + 1].Call <> LSorted[LIdx].Call) then
    begin
      if LSorted[LIdx].Via <> '' then
        LGroup := LGroup + ' via ' + LSorted[LIdx].Via;
      if not LSorted[LIdx].Call then
        LGroup := LGroup + ', not a call';
      Result := IfThen(Result = '', LGroup, Result + '; ' + LGroup);
    end;
  end;
end;

procedure AddToIndex(AIndex: TObjectDictionary<string, TList<TSemaXType>>;
  const AKey: string; const AX: TSemaXType);
var
  LList: TList<TSemaXType>;
begin
  if not AIndex.TryGetValue(AKey, LList) then
  begin
    LList := TList<TSemaXType>.Create;
    AIndex.Add(AKey, LList);
  end;
  LList.Add(AX);
end;

type
  { What one routine calls, level by level (SPEC 9.3.1) - `callers` from the
    other end. A call is what a name in the body binds to - the overload the
    compiler chose, a property's getter or setter - and what a bare
    `inherited;` runs. Through a virtual method it may also run an override
    in the class of the object it is made on, or below; through an interface,
    a method implementing it. Each routine is walked in the analysis its
    file reports from; a dispatch is searched in every analysis holding the
    method, and rows merge by declaration site. }
  TCalleeWalk = class
  private
    FWs: TMcpWorkspace;
    FEnclosing: TEnclosing;
    FNodes: TList<TCallNode>;
    FNodeOf: TDictionary<string, Integer>;      // declaration site -> node
    FRows: TList<TCalleeRow>;                   // the level being searched
    FRowOf: TDictionary<string, Integer>;       // declaration site -> row
    FTargets: TDictionary<string, TTarget>;     // analysis:model:symbol
    // Per analysis, built the first time a dispatch asks: the classes below
    // each class, and the classes taking each interface on.
    FChildren: TObjectDictionary<string, TList<TSemaXType>>;
    FImplementors: TObjectDictionary<string, TList<TSemaXType>>;
    FIndexed: TDictionary<Integer, Boolean>;
    FDispatchable: TDictionary<string, Boolean>;
    FBuiltins: TStringList;
    FValueCalls: TStringList;                   // through a procedural value
    FCompiled: TStringList;
    FNotes: TStringList;
    function XKey(AA: TMcpAnalysis; const AX: TSemaXType): string;
    procedure BuildIndex(AA: TMcpAnalysis);
    function TargetOf(AA: TMcpAnalysis; AMid, ASym: Integer): TTarget;
    function HasImpl(const AT: TTarget): Boolean;
    function IsDispatchable(AA: TMcpAnalysis; AMid, ASym: Integer): Boolean;
    function DeclaresImpl(AA: TMcpAnalysis; const AClass: TSemaXType;
      const AName, AParams: string; AArity: Integer; out AId: TSymId): Boolean;
    function ImplOf(AA: TMcpAnalysis; AClass: TSemaXType;
      const AStop: TSemaXType; const AName, AParams: string; AArity: Integer;
      out AId: TSymId): Boolean;
    procedure AddDispatchTargets(AA: TMcpAnalysis; AMid, ASym: Integer;
      AIface: Boolean; const ABase: TSemaXType; AList: TList<TSymId>);
    procedure AddUse(AA: TMcpAnalysis; AMid, ASym: Integer;
      const AUse: TCalleeUse);
    procedure AddDispatched(AA: TMcpAnalysis; AMid, ASym: Integer;
      AReceiver: TSemaXType; const AUse: TCalleeUse);
    function Walk(const ANode: TCallNode): Integer;
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    function Answer(const ATarget: TTarget; ADepth, ALimit: Integer): string;
  end;

constructor TCalleeWalk.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FEnclosing := TEnclosing.Create(AWs);
  FNodes := TList<TCallNode>.Create;
  FNodeOf := TDictionary<string, Integer>.Create;
  FRows := TList<TCalleeRow>.Create;
  FRowOf := TDictionary<string, Integer>.Create;
  FTargets := TDictionary<string, TTarget>.Create;
  FChildren := TObjectDictionary<string, TList<TSemaXType>>.Create(
    [doOwnsValues]);
  FImplementors := TObjectDictionary<string, TList<TSemaXType>>.Create(
    [doOwnsValues]);
  FIndexed := TDictionary<Integer, Boolean>.Create;
  FDispatchable := TDictionary<string, Boolean>.Create;
  FBuiltins := TStringList.Create;
  FValueCalls := TStringList.Create;
  FCompiled := TStringList.Create;
  FNotes := TStringList.Create;
end;

destructor TCalleeWalk.Destroy;
begin
  FNotes.Free;
  FCompiled.Free;
  FValueCalls.Free;
  FBuiltins.Free;
  FDispatchable.Free;
  FIndexed.Free;
  FImplementors.Free;
  FChildren.Free;
  FTargets.Free;
  FRowOf.Free;
  FRows.Free;
  FNodeOf.Free;
  FNodes.Free;
  FEnclosing.Free;
  inherited;
end;

function TCalleeWalk.XKey(AA: TMcpAnalysis; const AX: TSemaXType): string;
begin
  Result := Format('%d:%d:%d', [AA.Index, AX.UnitId, AX.Sym]);
end;

// Every class of the analysis under its parent, and under each interface it
// takes on (ListedInterfaces: its own list and what those extend) - one pass
// over the symbol tables. The navigator's searches rehydrate every model
// holding a row; this reads what survives demotion.
procedure TCalleeWalk.BuildIndex(AA: TMcpAnalysis);
var
  LM: TPasSemaModel;
  LX, LP: TSemaXType;
begin
  if FIndexed.ContainsKey(AA.Index) then
    Exit;
  FIndexed.Add(AA.Index, True);
  for var LMid := 0 to AA.Proj.ModelCount - 1 do
  begin
    LM := AA.Proj.Model(LMid);
    for var LSym := 0 to LM.SymCount - 1 do
    begin
      if (LM.Symbols[LSym].Kind <> skType) or
         (LM.Symbols[LSym].TypeCat <> tcClass) or
         (sfForward in LM.Symbols[LSym].Flags) then
        Continue;
      LX := XPlain(LMid, LSym);
      if not IsKindX(AA, LX, nkClassType) then
        Continue;   // an alias, a class reference
      LP := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LX));
      if XValid(LP) and not SameX(LP, LX) then
        AddToIndex(FChildren, XKey(AA, LP), LX);
      for var LI in ListedInterfaces(AA, LX) do
        AddToIndex(FImplementors, XKey(AA, LI), LX);
    end;
  end;
end;

// (AMid, ASym) as a target: its declaration site, and - for one of the
// group's own files, the only ones followed - its identity in every analysis.
// Mapping a library routine would rehydrate its unit once per analysis.
// DeclFile '' when it has no declaration.
function TCalleeWalk.TargetOf(AA: TMcpAnalysis; AMid, ASym: Integer): TTarget;
var
  LKey: string;
begin
  LKey := Format('%d:%d:%d', [AA.Index, AMid, ASym]);
  if FTargets.TryGetValue(LKey, Result) then
    Exit;
  Result := Default(TTarget);
  Result.Ids := NewIds(FWs);
  if not FillSymbolTarget(FWs, AA, AMid, ASym, Result) then
    Result.DeclFile := ''
  else if Result.Own then
    MapToOthers(FWs, Result);
  FTargets.Add(LKey, Result);
end;

function TCalleeWalk.HasImpl(const AT: TTarget): Boolean;
var
  LA: TMcpAnalysis;
  LIMid, LRoutine: Integer;
begin
  LA := ReportingAnalysis(FWs, AT);
  Result := (LA <> nil) and (AT.Ids[LA.Index].Sym >= 0) and RoutineImpl(LA,
    AT.Ids[LA.Index].Mid, AT.Ids[LA.Index].Sym, LIMid, LRoutine);
end;

// Can a call of (AMid, ASym) run another implementation - is it virtual,
// dynamic, an override or a message method?
function TCalleeWalk.IsDispatchable(AA: TMcpAnalysis; AMid,
  ASym: Integer): Boolean;
var
  LKey: string;
  LM: TPasSemaModel;
  LNode: Integer;
begin
  LKey := Format('%d:%d:%d', [AA.Index, AMid, ASym]);
  if FDispatchable.TryGetValue(LKey, Result) then
    Exit;
  Result := False;
  if AA.Proj.EnsureHydrated(AMid) then
  begin
    LM := AA.Proj.Model(AMid);
    LNode := LM.Symbols[ASym].DeclNode;
    while (LNode <> NIL_NODE) and (LM.Tree.Nodes[LNode].Kind <> nkRoutine) do
      LNode := LM.Tree.Nodes[LNode].Parent;
    Result := (LNode <> NIL_NODE) and (HasDirective(LM, LNode, 'virtual') or
      HasDirective(LM, LNode, 'dynamic') or HasDirective(LM, LNode,
      'override') or HasDirective(LM, LNode, 'abstract') or
      HasDirective(LM, LNode, 'message'));
  end;
  FDispatchable.Add(LKey, Result);
end;

{ Does class AClass itself declare the implementation of a slot - the
  routine named AName with parameter types AParams? Or, the only one of the
  name, with as many parameters and saying `override`: a generic ancestor's
  types read differently from the descendant's (`Foo(A: T)` and
  `Foo(A: Integer)`). }
function TCalleeWalk.DeclaresImpl(AA: TMcpAnalysis; const AClass: TSemaXType;
  const AName, AParams: string; AArity: Integer; out AId: TSymId): Boolean;
var
  LM: TPasSemaModel;
  LSym, LCount, LNode: Integer;
  LOnly: TSymId;
begin
  Result := False;
  AId.Mid := -1;
  AId.Sym := -1;
  LOnly := AId;
  LM := AA.Proj.Model(AClass.UnitId);
  if LM.Symbols[AClass.Sym].MemberScope = NIL_SCOPE then
    Exit;
  LCount := 0;
  LSym := LM.FindLocal(LM.Symbols[AClass.Sym].MemberScope, AName);
  while LSym <> NIL_SYM do
  begin
    if LM.Symbols[LSym].Kind = skRoutine then
    begin
      AId.Mid := AClass.UnitId;
      AId.Sym := LSym;
      if ParamTypesKey(AA, AClass.UnitId, LSym) = AParams then
        Exit(True);
      Inc(LCount);
      LOnly := AId;
    end;
    LSym := LM.Symbols[LSym].NextOverload;
  end;
  AId.Mid := -1;
  AId.Sym := -1;
  if (LCount <> 1) or (Length(AA.Proj.XParamSyms(LOnly.Mid, LOnly.Sym)) <>
     AArity) or not AA.Proj.EnsureHydrated(LOnly.Mid) then
    Exit;
  LM := AA.Proj.Model(LOnly.Mid);
  LNode := LM.Symbols[LOnly.Sym].DeclNode;
  while (LNode <> NIL_NODE) and (LM.Tree.Nodes[LNode].Kind <> nkRoutine) do
    LNode := LM.Tree.Nodes[LNode].Parent;
  Result := (LNode <> NIL_NODE) and HasDirective(LM, LNode, 'override');
  if Result then
    AId := LOnly;
end;

// The implementation an object of exactly class AClass runs for the slot:
// its own, or the nearest ancestor's below AStop - the class of the method
// the call binds to, which runs when none is found.
function TCalleeWalk.ImplOf(AA: TMcpAnalysis; AClass: TSemaXType;
  const AStop: TSemaXType; const AName, AParams: string; AArity: Integer;
  out AId: TSymId): Boolean;
begin
  for var LDepth := 1 to 64 do
  begin
    if not XValid(AClass) or (XValid(AStop) and SameX(AClass, AStop)) then
      Break;
    if DeclaresImpl(AA, AClass, AName, AParams, AArity, AId) then
      Exit(True);
    AClass := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(AClass));
  end;
  AId.Mid := -1;
  AId.Sym := -1;
  Result := False;
end;

type
  // A class of a dispatch search, and the implementation its objects run.
  TDispatchItem = record
    Cls: TSemaXType;
    Impl: TSymId;          // Mid -1: the method the call binds to
  end;

{ The other methods a call of (AMid, ASym) may run, into AList. For a virtual
  method: what an object of class ABase, or of a class below it, runs for
  the slot - an override between the method's class and ABase included, as
  a property's accessor binds where the property is declared. For an
  interface method: what each class taking the interface on - listing it or
  one extending it - and each class below that runs for it. Down the class
  tree once: a class not declaring the slot runs its parent's. Matched by
  name and parameter types, as dcc pairs them; a method resolution clause
  (`procedure IFoo.Bar = Baz`) is not read. }
procedure TCalleeWalk.AddDispatchTargets(AA: TMcpAnalysis; AMid,
  ASym: Integer; AIface: Boolean; const ABase: TSemaXType;
  AList: TList<TSymId>);
var
  LM: TPasSemaModel;
  LName, LParams, LKey: string;
  LArity, LHead: Integer;
  LStop: TSemaXType;
  LRoots: TList<TSemaXType>;
  LKids: TList<TSemaXType>;
  LQueue: TList<TDispatchItem>;
  LSeen, LFound: TDictionary<string, Boolean>;
  LItem, LNew: TDispatchItem;
begin
  BuildIndex(AA);
  LM := AA.Proj.Model(AMid);
  LName := LM.Symbols[ASym].NameLower;
  LParams := ParamTypesKey(AA, AMid, ASym);
  LArity := Length(AA.Proj.XParamSyms(AMid, ASym));
  LRoots := TList<TSemaXType>.Create;
  LQueue := TList<TDispatchItem>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  LFound := TDictionary<string, Boolean>.Create;
  try
    LStop := XNil;
    if AIface then
    begin
      if FImplementors.TryGetValue(XKey(AA, XPlain(AMid,
         LM.Scopes[LM.Symbols[ASym].Scope].StructSym)), LKids) then
        LRoots.AddRange(LKids);
    end
    else
    begin
      LStop := OwnerClassX(AA, AMid, ASym);
      LRoots.Add(ABase);
    end;
    for var LC in LRoots do
    begin
      LKey := XKey(AA, LC);
      if LSeen.ContainsKey(LKey) then
        Continue;
      LSeen.Add(LKey, True);
      LNew.Cls := LC;
      ImplOf(AA, LC, LStop, LName, LParams, LArity, LNew.Impl);
      LQueue.Add(LNew);
    end;
    LHead := 0;
    while (LHead < LQueue.Count) and (LHead < MAX_DISPATCH_CLASSES) do
    begin
      LItem := LQueue[LHead];
      Inc(LHead);
      if (LItem.Impl.Mid >= 0) and ((LItem.Impl.Mid <> AMid) or
         (LItem.Impl.Sym <> ASym)) then
      begin
        LKey := Format('%d:%d', [LItem.Impl.Mid, LItem.Impl.Sym]);
        if not LFound.ContainsKey(LKey) then
        begin
          LFound.Add(LKey, True);
          AList.Add(LItem.Impl);
        end;
      end;
      if FChildren.TryGetValue(XKey(AA, LItem.Cls), LKids) then
        for var LK in LKids do
        begin
          LKey := XKey(AA, LK);
          if LSeen.ContainsKey(LKey) then
            Continue;
          LSeen.Add(LKey, True);
          LNew.Cls := LK;
          if not DeclaresImpl(AA, LK, LName, LParams, LArity, LNew.Impl) then
            LNew.Impl := LItem.Impl;
          LQueue.Add(LNew);
        end;
    end;
  finally
    LFound.Free;
    LSeen.Free;
    LQueue.Free;
    LRoots.Free;
  end;
end;

procedure TCalleeWalk.AddUse(AA: TMcpAnalysis; AMid, ASym: Integer;
  const AUse: TCalleeUse);
var
  LT: TTarget;
  LKey: string;
  LIdx: Integer;
  LRow: TCalleeRow;
begin
  LT := TargetOf(AA, AMid, ASym);
  if LT.DeclFile = '' then
    Exit;
  // PasTree reads a unit with no source from its .dcu: a name, no line.
  if SameText(TPath.GetExtension(LT.DeclFile), '.dcu') then
  begin
    if FCompiled.IndexOf(LT.Name) < 0 then
      FCompiled.Add(LT.Name);
    Exit;
  end;
  LKey := SiteKey(LT.DeclFile, LT.DeclLine, LT.DeclCol);
  if not FRowOf.TryGetValue(LKey, LIdx) then
  begin
    LRow := Default(TCalleeRow);
    LRow.T := LT;
    LRow.Hit.FilePath := LT.DeclFile;
    LRow.Hit.Line := LT.DeclLine;
    LRow.Hit.Col := LT.DeclCol;
    LRow.Hit.Snippet := LT.Snippet;
    LRow.Hit.Own := LT.Own;
    LIdx := FRows.Count;
    FRows.Add(LRow);
    FRowOf.Add(LKey, LIdx);
  end;
  LRow := FRows[LIdx];
  for var LU in LRow.Calls do
    if (LU.Caller = AUse.Caller) and (LU.Line = AUse.Line) and
       (LU.Via = AUse.Via) and (LU.Call = AUse.Call) then
      Exit;
  LRow.Calls := LRow.Calls + [AUse];
  FRows[LIdx] := LRow;
end;

// What else a call of (AMid, ASym), on an object of class AReceiver, may run:
// overrides for a virtual method, implementations for an interface method.
procedure TCalleeWalk.AddDispatched(AA: TMcpAnalysis; AMid, ASym: Integer;
  AReceiver: TSemaXType; const AUse: TCalleeUse);
var
  LT, LBaseT: TTarget;
  LUse: TCalleeUse;
  LList, LIds: TList<TSymId>;
  LOf: TList<TMcpAnalysis>;
  LKeys: TDictionary<string, Boolean>;
  LIface: Boolean;
  LBase: TSemaXType;
  LMid, LSym: Integer;
  LNote, LKey: string;
begin
  LIface := IsInterfaceMethodSym(AA, AMid, ASym);
  if not LIface and not IsDispatchable(AA, AMid, ASym) then
    Exit;
  LT := TargetOf(AA, AMid, ASym);
  if LT.DeclFile = '' then
    Exit;
  // A receiver the method is not a member of is none the walk can use.
  if XValid(AReceiver) and not AA.Proj.XDescendsFrom(AReceiver,
     OwnerClassX(AA, AMid, ASym)) then
    AReceiver := XNil;
  LBaseT := Default(TTarget);
  if XValid(AReceiver) then
    LBaseT := TargetOf(AA, AReceiver.UnitId, AReceiver.Sym);
  LUse := AUse;
  LUse.Via := LT.Name;
  LList := TList<TSymId>.Create;
  LIds := TList<TSymId>.Create;
  LOf := TList<TMcpAnalysis>.Create;
  LKeys := TDictionary<string, Boolean>.Create;
  try
    // Every analysis' methods, merged before they are counted: a group has
    // classes one analysis holds and another does not. By model file and
    // declaration node, which needs no text - positions come for the rows
    // listed only.
    for var LA in FWs.Analyses do
    begin
      LMid := LT.Ids[LA.Index].Mid;
      LSym := LT.Ids[LA.Index].Sym;
      if (LMid < 0) or (LSym < 0) then
        Continue;
      LList.Clear;
      if LIface then
        AddDispatchTargets(LA, LMid, LSym, True, XNil, LList)
      else
      begin
        LBase := XNil;
        if (LBaseT.DeclFile <> '') and (LBaseT.Ids[LA.Index].Sym >= 0) then
          LBase := XPlain(LBaseT.Ids[LA.Index].Mid, LBaseT.Ids[LA.Index].Sym);
        if not XValid(LBase) then
          LBase := OwnerClassX(LA, LMid, LSym);
        if XValid(LBase) then
          AddDispatchTargets(LA, LMid, LSym, False, LBase, LList);
      end;
      for var LId in LList do
      begin
        LKey := LowerCase(LA.Proj.ModelFile(LId.Mid)) + '|' + IntToStr(
          LA.Proj.Model(LId.Mid).Symbols[LId.Sym].DeclNode);
        if LA.Proj.Model(LId.Mid).Symbols[LId.Sym].DeclNode = NIL_NODE then
          LKey := LKey + '|' + IntToStr(LId.Sym);   // a compiled unit's
        if LKeys.ContainsKey(LKey) then
          Continue;
        LKeys.Add(LKey, True);
        LIds.Add(LId);
        LOf.Add(LA);
      end;
    end;
    if LIds.Count > MAX_DISPATCH_ROWS then
    begin
      LNote := Format('%s: %d other methods may run for it - not listed; '
        + '`related %s` lists them', [LT.Name, LIds.Count, IfThen(LIface,
        'implementations', 'overrides')]);
      if FNotes.IndexOf(LNote) < 0 then
        FNotes.Add(LNote);
      Exit;
    end;
    for var LIdx := 0 to LIds.Count - 1 do
      AddUse(LOf[LIdx], LIds[LIdx].Mid, LIds[LIdx].Sym, LUse);
  finally
    LKeys.Free;
    LOf.Free;
    LIds.Free;
    LList.Free;
  end;
end;

// The calls in one routine's body - its nested routines are routines of
// their own - as uses of the level's rows. The count of calls; -1 when it
// has no body.
function TCalleeWalk.Walk(const ANode: TCallNode): Integer;
var
  LA: TMcpAnalysis;
  LIM, LBM: TPasSemaModel;
  LRMid, LRSym, LIMid, LRoutine, LBody, LBlock, LN, LChild, LBMid, LBSym,
    LFileId, LLine, LCol, LAMid, LASym, LE, LP, LTMid: Integer;
  LStack: TStack<Integer>;
  LExt: TPasExtRef;
  LUse: TCalleeUse;
  LRef: TRefUse;
  LX: TSemaXType;
  LTo: TPasNavTarget;
  LName: string;
begin
  Result := -1;
  LA := ReportingAnalysis(FWs, ANode.T);
  if LA = nil then
    Exit;
  LRMid := ANode.T.Ids[LA.Index].Mid;
  LRSym := ANode.T.Ids[LA.Index].Sym;
  if (LRSym < 0) or not RoutineImpl(LA, LRMid, LRSym, LIMid, LRoutine) then
    Exit;
  LIM := LA.Proj.Model(LIMid);
  LBody := BodyNodeOf(LIM, LRoutine);
  if LBody = NIL_NODE then
    Exit;
  Result := 0;
  LUse := Default(TCalleeUse);
  if ANode.Level > 0 then
    LUse.Caller := ANode.Name;
  LStack := TStack<Integer>.Create;
  try
    LStack.Push(LBody);
    while LStack.Count > 0 do
    begin
      LN := LStack.Pop;
      if (LN <> LBody) and (LIM.Tree.Nodes[LN].Kind = nkRoutine) then
        Continue;
      LChild := LIM.Tree.Nodes[LN].FirstChild;
      while LChild <> NIL_NODE do
      begin
        LStack.Push(LChild);
        LChild := LIM.Tree.Nodes[LChild].NextSibling;
      end;
      if LIM.Tree.Nodes[LN].Kind <> nkIdent then
        Continue;
      if (LN < Length(LIM.RefMap)) and (LIM.RefMap[LN] <> NIL_SYM) then
      begin
        LBMid := LIMid;
        LBSym := LIM.RefMap[LN];
      end
      else if LIM.ExtRefMap.TryGetValue(LN, LExt) then
      begin
        LBMid := LExt.UnitId;
        LBSym := LExt.Sym;
      end
      else
        Continue;
      if (LBMid < 0) or (LBSym < 0) or not VisPos(LIM,
         LIM.Tree.NodeLeftmostVis(LN), LFileId, LLine, LCol) then
        Continue;
      LBM := LA.Proj.Model(LBMid);
      LUse.Line := LLine;
      LUse.Via := '';
      LUse.Call := True;
      case LBM.Symbols[LBSym].Kind of
        skRoutine:
          begin
            if sfBuiltin in LBM.Symbols[LBSym].Flags then
            begin
              LName := LBM.Symbols[LBSym].Name;
              if not MatchText(LName, ['Exit', 'Break', 'Continue']) and
                 (FBuiltins.IndexOf(LName) < 0) then
                FBuiltins.Add(LName);
              Continue;
            end;
            LRef := RefUse(LA, LIM, LIMid, LN, LBM.RoutineHead(LBSym) in
              [rhFunction, rhConstructor]);
            if LRef = ruNone then
              Continue;
            LUse.Call := LRef <> ruValue;
            if LUse.Call then
              Inc(Result);
            AddUse(LA, LBMid, LBSym, LUse);
            // `inherited Foo` is a static call of that implementation, and
            // so is one made on a type name.
            if LUse.Call and not UnderInherited(LIM, LN) and
               not CalledOnType(LIM, LIMid, LN, LA) then
              AddDispatched(LA, LBMid, LBSym, ReceiverClassX(LA, LIM, LIMid,
                LN), LUse);
            Continue;
          end;
        skProperty:
          if PropertyAccessor(LA, LBMid, LBSym, IsAssignTarget(LIM, LN),
             LAMid, LASym) then
          begin
            Inc(Result);
            LUse.Via := QualifiedName(LBM, LBSym);
            AddUse(LA, LAMid, LASym, LUse);
            AddDispatched(LA, LAMid, LASym, ReceiverClassX(LA, LIM, LIMid,
              LN), LUse);
          end;
        skField, skVar, skParam, skConst:
          ;
      else
        Continue;
      end;
      // A method pointer or a procedural variable called: what it runs is
      // assigned at run time.
      LE := DesignatorOf(LIM, LN);
      LP := LIM.Tree.Nodes[LE].Parent;
      if (LP <> NIL_NODE) and (LIM.Tree.Nodes[LP].Kind = nkCall) and
         (LIM.Tree.Nodes[LP].FirstChild = LE) then
      begin
        LX := LA.Proj.DeclTypeX(LBMid, LBSym);
        if not XValid(LX) then
          LX := LA.Proj.SymDeclTypeX(LBMid, LBSym);
        if XValid(LX) then
          LX := LA.Proj.CanonTypeX(LX);
        if XValid(LX) and (LA.Proj.Model(LX.UnitId).Symbols[LX.Sym].TypeCat =
           tcProc) then
        begin
          Inc(Result);
          LName := Format('%s (%sat %d)', [LBM.Symbols[LBSym].Name,
            IfThen(LUse.Caller <> '', LUse.Caller + ' ', ''), LLine]);
          if FValueCalls.IndexOf(LName) < 0 then
            FValueCalls.Add(LName);
        end;
      end;
    end;

    // A bare `inherited;` names nothing: GotoBareInherited says what it runs
    // - statically, as every inherited call.
    LBlock := NIL_NODE;
    LChild := LIM.Tree.Nodes[LBody].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if LIM.Tree.Nodes[LChild].Kind = nkBlock then
        LBlock := LChild;
      LChild := LIM.Tree.Nodes[LChild].NextSibling;
    end;
    if LBlock <> NIL_NODE then
      for var LVis := LIM.Tree.NodeLeftmostVis(LBlock) to
          LIM.Tree.Nodes[LBlock].LastToken - 1 do
        if (LIM.Tree.Source.VisibleToken(LVis).Kind = tkInherited) and
           (LIM.Tree.Source.VisibleToken(LVis + 1).Kind <> tkIdentifier) and
           VisPos(LIM, LVis, LFileId, LLine, LCol) and (LFileId = 0) and
           LA.Nav.GotoBareInherited(LIMid, LLine, LCol, LTo) then
        begin
          LTMid := LA.Nav.ModelIdOf(LTo.FilePath);
          if (LTMid < 0) or not LA.Proj.EnsureHydrated(LTMid) or
             not LA.Nav.SymbolAt(LTMid, LTo.Line, LTo.Col, LAMid, LASym,
             LName) then
            Continue;
          Inc(Result);
          LUse.Line := LLine;
          LUse.Via := '';
          LUse.Call := True;
          AddUse(LA, LAMid, LASym, LUse);
        end;
  finally
    LStack.Free;
  end;
end;

function TCalleeWalk.Answer(const ATarget: TTarget; ADepth,
  ALimit: Integer): string;
var
  LSb, LLevels: TStringBuilder;
  LNode: TCallNode;
  LFrontier, LNext: TList<Integer>;
  LRows: TArray<TCalleeRow>;
  LHits: TArray<THit>;
  LShown, LLibrary, LLevel, LCutAt, LFound, LCalls, LFirstCalls, LIMid,
    LRoutine, LFileId, LFrom, LAt, LTo: Integer;
  LSum, LKey, LWhere: string;
  LLeaves: TStringList;
  LA: TMcpAnalysis;
begin
  LSb := TStringBuilder.Create;
  LLevels := TStringBuilder.Create;
  LFrontier := TList<Integer>.Create;
  LNext := TList<Integer>.Create;
  LLeaves := TStringList.Create;
  try
    LNode.T := ATarget;
    LNode.Name := ATarget.Name;
    LNode.Level := 0;
    LNode.Found := -1;
    FNodes.Add(LNode);
    FNodeOf.Add(SiteKey(ATarget.DeclFile, ATarget.DeclLine, ATarget.DeclCol), 0);
    LFrontier.Add(0);
    LShown := 0;
    LLibrary := 0;
    LCutAt := 0;
    LFirstCalls := 0;
    LSum := '';
    for LLevel := 1 to ADepth do
    begin
      FRows.Clear;
      FRowOf.Clear;
      LCalls := 0;
      for var LIdx in LFrontier do
      begin
        LFound := Walk(FNodes[LIdx]);
        LNode := FNodes[LIdx];
        LNode.Found := LFound;
        FNodes[LIdx] := LNode;
        if LFound > 0 then
          Inc(LCalls, LFound);
      end;
      LRows := FRows.ToArray;
      TArray.Sort<TCalleeRow>(LRows, TComparer<TCalleeRow>.Construct(
        function(const L, R: TCalleeRow): Integer
        begin
          Result := Ord(R.Hit.Own) - Ord(L.Hit.Own);
          if Result = 0 then
            Result := CompareText(L.Hit.FilePath, R.Hit.FilePath);
          if Result = 0 then
            Result := L.Hit.Line - R.Hit.Line;
          if Result = 0 then
            Result := L.Hit.Col - R.Hit.Col;
        end));
      if LLevel = 1 then
      begin
        LFirstCalls := LCalls;
        LSum := Plural(LCalls, 'call') + ' reaching ' + Plural(Length(LRows),
          'routine');
      end
      else if LCalls = 0 then
        LSum := LSum + Format('; depth %d: none', [LLevel])
      else
        LSum := LSum + Format('; depth %d: %s reaching %d', [LLevel,
          Plural(LCalls, 'call'), Length(LRows)]);
      if LLevel > 1 then
        LLevels.AppendLine(Format('depth %d - what those call:', [LLevel]));
      SetLength(LHits, Length(LRows));
      for var LI := 0 to High(LRows) do
      begin
        LHits[LI] := LRows[LI].Hit;
        LHits[LI].Tag := UsesTag(LRows[LI].Calls);
      end;
      if (Length(LHits) = 0) and (LLevel > 1) then
        LLevels.AppendLine('  none');
      AppendHitsByFile(FWs, LLevels, LHits, Max(ALimit - LShown, 0), False,
        FEnclosing);
      Inc(LShown, Min(Length(LHits), Max(ALimit - LShown, 0)));
      // The next level: what the calls reach of the group's own files, with
      // a body - a library routine is shown, not followed.
      LNext.Clear;
      for var LR in LRows do
      begin
        LKey := SiteKey(LR.T.DeclFile, LR.T.DeclLine, LR.T.DeclCol);
        if FNodeOf.ContainsKey(LKey) then
          Continue;
        var LCalled := False;
        for var LU in LR.Calls do
          LCalled := LCalled or LU.Call;
        if not LCalled then
          Continue;
        if not LR.T.Own then
        begin
          FNodeOf.Add(LKey, -1);
          if LLevel < ADepth then
            Inc(LLibrary);
          Continue;
        end;
        if not HasImpl(LR.T) then
        begin
          FNodeOf.Add(LKey, -1);
          Continue;
        end;
        LNode.T := LR.T;
        LNode.Name := FEnclosing.NameAt(LR.T.DeclFile, LR.T.DeclLine,
          LR.T.DeclCol, False);
        if LNode.Name = '' then
          LNode.Name := LR.T.Name;
        for var LOther in FNodes do
          if SameText(LOther.Name, LNode.Name) then
          begin
            LNode.Name := Format('%s (line %d)', [LNode.Name, LR.T.DeclLine]);
            Break;
          end;
        LNode.Level := LLevel;
        LNode.Found := -1;
        FNodes.Add(LNode);
        FNodeOf.Add(LKey, FNodes.Count - 1);
        LNext.Add(FNodes.Count - 1);
      end;
      LFrontier.Clear;
      LFrontier.AddRange(LNext);
      if (LFrontier.Count > 0) and (LShown >= ALimit) and (LLevel < ADepth) then
        LCutAt := LLevel + 1;
      if (LFrontier.Count = 0) or (LShown >= ALimit) then
        Break;
    end;

    // Where the lines of the first level are: the body, not the declaration.
    LWhere := Format('%s:%d', [FWs.RelPath(ATarget.DeclFile),
      ATarget.DeclLine]);
    LA := ReportingAnalysis(FWs, ATarget);
    if (LA <> nil) and RoutineImpl(LA, ATarget.Ids[LA.Index].Mid,
       ATarget.Ids[LA.Index].Sym, LIMid, LRoutine) and
       DeclLines(LA.Proj.Model(LIMid), LRoutine, LFileId, LFrom, LAt, LTo) then
      LWhere := Format('%s:%d-%d', [FWs.RelPath(LA.Proj.Model(LIMid).Tree.
        Source.FileNames[LFileId]), LAt, LTo]);
    LSb.Append(Format('callees of %s (%s)', [ATarget.Name, LWhere]));
    if (LFirstCalls = 0) and (FRows.Count = 0) and (LShown = 0) then
      LSb.AppendLine(' - none found')
    else
      LSb.AppendLine(' - ' + LSum);
    LSb.Append(LLevels.ToString);
    if FValueCalls.Count > 0 then
      LSb.AppendLine(Format('(%s through a method pointer or procedural '
        + 'variable: %s - what it runs is assigned elsewhere, `related '
        + 'assignments` of it lists where)', [Plural(FValueCalls.Count,
        'call'), String.Join(', ', FValueCalls.ToStringArray)]));
    if FBuiltins.Count > 0 then
      LSb.AppendLine(Format('(built-ins called: %s)', [String.Join(', ',
        FBuiltins.ToStringArray)]));
    if FCompiled.Count > 0 then
      LSb.AppendLine(Format('(in compiled units without source, not shown: '
        + '%s)', [String.Join(', ', FCompiled.ToStringArray)]));
    for var LNote in FNotes do
      LSb.AppendLine('(' + LNote + ')');
    // The ends of the walk: searched, nothing called.
    for var LI := 1 to FNodes.Count - 1 do
      if FNodes[LI].Found = 0 then
        LLeaves.Add(FNodes[LI].Name);
    if LLeaves.Count > 0 then
      LSb.AppendLine('calling nothing: ' + String.Join(', ',
        LLeaves.ToStringArray));
    if LLibrary > 0 then
      LSb.AppendLine(Format('(%s among them, not followed)',
        [Plural(LLibrary, 'library routine')]));
    if (ADepth > 1) and (LFrontier.Count > 0) and (LShown < ALimit) then
      LSb.AppendLine(Format('(%s at depth %d not searched for callees%s)',
        [Plural(LFrontier.Count, 'routine'), ADepth, IfThen(ADepth < 4,
        ' - raise `depth`', '')]));
    if LCutAt > 0 then
      LSb.AppendLine(Format('(depth %d not searched: the rows reached `limit` '
        + '- raise it, or ask for the callees of one routine above)',
        [LCutAt]));
    Result := LSb.ToString.TrimRight;
  finally
    LLeaves.Free;
    LNext.Free;
    LFrontier.Free;
    LLevels.Free;
    LSb.Free;
  end;
end;

{ What a routine calls (SPEC 9.3.1): the routines its body reaches - a
  virtual call's overrides and an interface call's implementations too -
  and, with `depth`, what those call. }
function ToolCallees(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LA: TMcpAnalysis;
  LM: TPasSemaModel;
  LIMid, LRoutine, LDecl: Integer;
  LWhy: string;
  LWalk: TCalleeWalk;
begin
  LT := ResolveOne(AWs, AArgs);
  if (LT.Kind <> tkSymbol) or not ((LT.Head = 'procedure') or
     (LT.Head = 'function') or (LT.Head = 'constructor') or
     (LT.Head = 'destructor') or (LT.Head = 'operator') or
     (LT.Head = 'routine')) then
    raise EToolError.CreateFmt('%s is a %s - `callees` takes a routine; '
      + '`members` lists what a type has', [LT.Name, LT.Head]);
  LA := ReportingAnalysis(AWs, LT);
  if (LA = nil) or not RoutineImpl(LA, LT.Ids[LA.Index].Mid,
     LT.Ids[LA.Index].Sym, LIMid, LRoutine) then
  begin
    LWhy := 'no implementation found';
    if (LA <> nil) and LA.Proj.EnsureHydrated(LT.Ids[LA.Index].Mid) then
    begin
      LM := LA.Proj.Model(LT.Ids[LA.Index].Mid);
      LDecl := LM.Symbols[LT.Ids[LA.Index].Sym].DeclNode;
      if LDecl <> NIL_NODE then
        LDecl := LM.Tree.DeclRootOf(LDecl);
      if (LDecl <> NIL_NODE) and (LM.Tree.Nodes[LDecl].Kind = nkRoutine) then
        LWhy := NoBodyNote(LM, LDecl);
    end;
    raise EToolError.CreateFmt('%s: %s - nothing to read calls from', [LT.Name,
      LWhy]);
  end;
  LWalk := TCalleeWalk.Create(AWs);
  try
    Result := LWalk.Answer(LT, EnsureRange(ArgInt(AArgs, 'depth', 1), 1, 4),
      EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000));
  finally
    LWalk.Free;
  end;
end;

// The analysis + model of an own or library file, hydrated.
function ModelOfFile(AWs: TMcpWorkspace; const AFile: string;
  out AA: TMcpAnalysis; out AMid: Integer): Boolean;
begin
  for var LA in AWs.Analyses do
  begin
    AMid := LA.Nav.ModelIdOf(AFile);
    if AMid >= 0 then
    begin
      AA := LA;
      LA.Proj.EnsureHydrated(AMid);
      Exit(True);
    end;
  end;
  Result := False;
end;

{ A routine's or property's parameter list and result type (`(const A: X; B:
  Y): Z`, `[I: Integer]: T`) whole - what PasTree's outline puts in Detail,
  whose 80-character cut ends mid-name and then appends the result type:
  `AInterfa...: TPasTree` reads as one more parameter. The same children as
  PasTree.Outline's Routine and PropertyDecl pick; the text through VisText,
  cut by CutDecl. '' when the node has none of them. }
function SignatureDetail(LM: TPasSemaModel; ANode: Integer): string;
var
  LChild, LParams, LResult, LFirst, LLast, LPrev: Integer;
  LIsProperty: Boolean;

  function PartText(APart: Integer): string;
  begin
    Result := '';
    if (APart <> NIL_NODE) and LM.Tree.NodeVisRange(APart, LFirst, LLast) then
      Result := VisText(LM, LFirst, LLast);
  end;

begin
  Result := '';
  LParams := NIL_NODE;
  LResult := NIL_NODE;
  LIsProperty := LM.Tree.Nodes[ANode].Kind = nkPropertyDecl;
  LChild := LM.Tree.Nodes[ANode].FirstChild;
  if LIsProperty then
  begin
    while (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind = nkAttrGroup) do
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    if (LChild = NIL_NODE) or (LM.Tree.Nodes[LChild].Kind <> nkIdent) then
      Exit;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
    if (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind = nkParams) then
    begin
      LParams := LChild;
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    // The type is the child after a colon; a bare `property X;` has none.
    if (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind <> nkPropSpec) then
    begin
      LPrev := LM.Tree.NodeLeftmostVis(LChild) - 1;
      if (LPrev >= 0) and (LPrev <= High(LM.Tree.Source.Visible)) and
         (LM.Tree.Source.VisibleToken(LPrev).Kind = tkColon) then
        LResult := LChild;
    end;
  end
  else
    while LChild <> NIL_NODE do
    begin
      case LM.Tree.Nodes[LChild].Kind of
        // A name segment - or the result type, an nkIdent too.
        nkIdent, nkMissing:
          if not (nfName in LM.Tree.Nodes[LChild].Flags) and
             (LResult = NIL_NODE) then
            LResult := LChild;
        nkParams:
          LParams := LChild;
        nkGenericParams, nkDirective, nkAttrGroup, nkRoutineBody:
          ;
      else
        // The result type in any other shape: `array of`, a qualified name.
        if LResult = NIL_NODE then
          LResult := LChild;
      end;
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
  Result := PartText(LParams);
  if LResult <> NIL_NODE then
    Result := Result + ': ' + PartText(LResult);
  Result := CutDecl(Result);
end;

type
  // A value of the merged form: `OnClick -> TfrmMain.btnSaveClick`.
  TFormBind = record
    Prop, Text: string;
    FileIdx, Line: Integer;
    Kind: Integer;               // 0 an event, 1 a component, 2 names nothing, 3 cleared
    Method: string;              // an event's: the method it runs
  end;

  // A component of the merged form: the ancestors' objects, reopened by
  // `inherited X` in the descendants' files.
  TFormNode = record
    Name, ClassName: string;
    Kind: TPasDfmObjectKind;
    FileIdx, Line: Integer;      // the most derived file that writes it
    NoField: Boolean;            // named, and no published field is filled
    Binds: TArray<TFormBind>;
    Children: TArray<Integer>;
  end;

{ The component tree of one form (SPEC 9.5): what the Object Inspector shows
  without the plain properties - each component with its class, the events
  it binds and to which method, the components it names. An inherited form
  is merged with its ancestors' form files, as the form designer shows it:
  `inherited X` reopens the ancestor's X, and a value set in a descendant
  replaces the ancestor's. The binding is PasTree's (DescribeForm) - TReader's
  rules: an inline frame's children are the frame's fields, a handler is the
  root's method. A value that should name something and does not is said:
  an event whose method is gone fails the form when it loads. }
function ToolForm(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LFile, LForm, LUnit, LExt, LKey, LText, LLine: string;
  LA: TMcpAnalysis;
  LMid, LLimit, LShown, LTotal, LNode, LComponents, LEvents, LRefs,
    LUnbound, LCleared: Integer;
  LT: TTarget;
  LInfo: TPasFormInfo;
  LInfos: TList<TPasFormInfo>;
  LK: TSemaXType;
  LRole: TPasFormRole;
  LNodes: TList<TFormNode>;
  LByKey: TDictionary<string, Integer>;
  LKeys: TArray<string>;
  LObjNode: TArray<Integer>;
  LN: TFormNode;
  LB: TFormBind;
  LBx: TPasFormBinding;
  LFMid, LFSym, LCtx: Integer;
  LSb, LRows: TStringBuilder;
  LErrors: TStringList;

  function BindText(const AB: TPasFormBinding; out AKind: Integer): string;
  var
    LQ: string;
  begin
    if AB.TSym = NIL_SYM then
    begin
      if AB.Cleared then
      begin
        AKind := 3;
        Exit(Format('%s -> nil (cleared: the event runs nothing)',
          [AB.PropName]));
      end;
      if AB.NoField then
      begin
        AKind := 1;
        Exit(Format('%s -> %s (a component the form files create, with no '
          + 'field)', [AB.PropName, AB.Value]));
      end;
      AKind := 2;
      if AB.IsMethod then
        Exit(Format('%s -> %s - no such published method: the form fails to '
          + 'load', [AB.PropName, AB.Value]));
      Exit(Format('%s -> %s - names no component', [AB.PropName, AB.Value]));
    end;
    LQ := QualifiedName(LA.Proj.Model(AB.TMid), AB.TSym);
    if AB.IsMethod then
    begin
      AKind := 0;
      Exit(Format('%s -> %s', [AB.PropName, LQ]));
    end;
    AKind := 1;
    if SameText(AB.Value, Copy(LQ, LastDelimiter('.', LQ) + 1, MaxInt)) then
      Result := Format('%s -> %s', [AB.PropName, AB.Value])
    else
      Result := Format('%s -> %s (%s)', [AB.PropName, AB.Value, LQ]);
  end;

  function FileNote(AIdx: Integer): string;
  begin
    if AIdx = LInfos.Count - 1 then
      Result := ''
    else
      Result := '  (' + ExtractFileName(LInfos[AIdx].FilePath) + ')';
  end;

  procedure Emit(ANode, ADepth: Integer);
  var
    LIndent, LKind: string;
    LNd: TFormNode;
  begin
    LNd := LNodes[ANode];
    LIndent := StringOfChar(' ', 2 * ADepth);
    Inc(LTotal);
    if LShown < LLimit then
    begin
      LKind := '';
      if LNd.Kind = dokInline then
        LKind := ' (inline frame)';
      if LNd.NoField then
        LKind := LKind + ' (no field)';
      LRows.AppendLine(Format('%d  %s%s: %s%s%s', [LNd.Line, LIndent, LNd.Name,
        LNd.ClassName, LKind, FileNote(LNd.FileIdx)]));
      Inc(LShown);
    end;
    for var LBd in LNd.Binds do
    begin
      Inc(LTotal);
      if LShown < LLimit then
      begin
        LRows.AppendLine(Format('%d  %s  %s%s', [LBd.Line, LIndent, LBd.Text,
          FileNote(LBd.FileIdx)]));
        Inc(LShown);
      end;
    end;
    for var LChild in LNd.Children do
      Emit(LChild, ADepth + 1);
  end;

begin
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 300), 1, 20000);
  LA := nil;
  if ArgStr(AArgs, 'file') <> '' then
  begin
    LFile := ArgFile(AWs, AArgs);
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.dfm') or (LExt = '.fmx') then
    begin
      LForm := LFile;
      LUnit := ChangeFileExt(LFile, '.pas');
    end
    else
    begin
      LUnit := LFile;
      LForm := PasDfmFileOfUnit(LFile);
      if LForm = '' then
        raise EToolError.CreateFmt('%s has no form file - no .dfm or .fmx '
          + 'beside it', [AWs.RelPath(LFile)]);
    end;
    if not ModelOfFile(AWs, LUnit, LA, LMid) then
    begin
      if not TFile.Exists(LUnit) then
        raise EToolError.CreateFmt('no unit beside %s - an orphan form file, '
          + 'which no project compiles', [AWs.RelPath(LForm)]);
      raise EToolError.CreateFmt('%s is not part of any analyzed project',
        [AWs.RelPath(LUnit)]);
    end;
  end
  else if ArgStr(AArgs, 'symbol') <> '' then
  begin
    LT := ResolveNamed(AWs, ArgStr(AArgs, 'symbol'), 'class');
    for var LCand in AWs.Analyses do
      if LT.Ids[LCand.Index].Mid >= 0 then
      begin
        LA := LCand;
        Break;
      end;
    if LA = nil then
      raise EToolError.CreateFmt('%s is in no analysis', [LT.Name]);
    LRole := LA.Nav.FormRoleOf(LT.Ids[LA.Index].Mid, LT.Ids[LA.Index].Sym);
    if LRole.FormFile = '' then
      raise EToolError.CreateFmt('%s has no form file of its own - no form '
        + 'file of the group has it as its root class', [LT.Name]);
    LForm := LRole.FormFile;
  end
  else
    raise EToolError.Create('give `file` (a unit or its .dfm/.fmx) or '
      + '`symbol` (the form''s class)');
  if not LA.Nav.DescribeForm(LForm, LInfo) then
    raise EToolError.CreateFmt('%s: %s', [AWs.RelPath(LForm), LInfo.Error]);

  LInfos := TList<TPasFormInfo>.Create;
  LNodes := TList<TFormNode>.Create;
  LByKey := TDictionary<string, Integer>.Create;
  LSb := TStringBuilder.Create;
  LRows := TStringBuilder.Create;
  LErrors := TStringList.Create;
  try
    // The ancestors' forms, the deepest first: a library's (TForm's) has
    // none the group reads.
    LInfos.Add(LInfo);
    LK := LA.Proj.CanonTypeX(LA.Proj.AncestorOfX(LInfo.RootClass));
    for var LDepth := 1 to 32 do
    begin
      if not XValid(LK) then
        Break;
      LRole := LA.Nav.FormRoleOf(LK.UnitId, LK.Sym);
      if (LRole.FormFile <> '') and LA.Nav.DescribeForm(LRole.FormFile,
         LInfo) then
        LInfos.Insert(0, LInfo);
      LK := LA.Proj.CanonTypeX(LA.Proj.AncestorOfX(LK));
    end;

    LComponents := 0;
    for var LFi := 0 to LInfos.Count - 1 do
    begin
      LInfo := LInfos[LFi];
      if LInfo.TrailingLine > 0 then
        LErrors.Add(Format('%s: from line %d the text follows the root''s '
          + '`end` - the compiler reads one object and drops the rest, so '
          + 'nothing written there is bound (a stray `end`?)',
          [AWs.RelPath(LInfo.FilePath), LInfo.TrailingLine]));
      if LInfo.Error <> '' then
        LErrors.Add(Format('%s could not be read whole (%s) - what was read '
          + 'before is shown', [AWs.RelPath(LInfo.FilePath), LInfo.Error]));
      SetLength(LObjNode, Length(LInfo.Objects));
      SetLength(LKeys, Length(LInfo.Objects));
      for var LO in LInfo.Objects do
      begin
        // The key a descendant's `inherited X` reopens: the names from the
        // root down. An unnamed object is its file's own.
        if LO.Parent < 0 then
          LKey := ''
        else if LO.Name <> '' then
          LKey := LKeys[LO.Parent] + '.' + LowerCase(LO.Name)
        else
          LKey := Format('%s.#%d:%d', [LKeys[LO.Parent], LFi, LO.Obj]);
        LKeys[LO.Obj] := LKey;
        if LByKey.TryGetValue(LKey, LNode) then
          LN := LNodes[LNode]
        else
        begin
          LN := Default(TFormNode);
          LNode := LNodes.Count;
          LNodes.Add(LN);
          LByKey.Add(LKey, LNode);
          if LO.Parent >= 0 then
          begin
            LN := LNodes[LObjNode[LO.Parent]];
            LN.Children := LN.Children + [LNode];
            LNodes[LObjNode[LO.Parent]] := LN;
            Inc(LComponents);
          end;
          LN := LNodes[LNode];
        end;
        LObjNode[LO.Obj] := LNode;
        LN.Name := IfThen(LO.Name <> '', LO.Name, '(unnamed)');
        LN.ClassName := LO.ClassName;
        if LO.Kind <> dokInherited then
          LN.Kind := LO.Kind;
        LN.FileIdx := LFi;
        LN.Line := LO.Line;
        LN.NoField := (LO.Parent >= 0) and (LO.Name <> '') and
          (LO.FieldSym = NIL_SYM);
        LNodes[LNode] := LN;
      end;
      for var LBi in LInfo.Bindings do
      begin
        // An ancestor's line runs on an instance of the asked form: its
        // MethodAddress finds the most derived published method of the name
        // - a descendant's redeclaration, not the ancestor's.
        LBx := LBi;
        if (LFi < LInfos.Count - 1) and LBx.IsMethod and
           XValid(LInfos[LInfos.Count - 1].RootClass) and
           LA.Proj.FindMemberX(LInfos[LInfos.Count - 1].RootClass.UnitId,
           LInfos[LInfos.Count - 1].RootClass, LowerCase(LBx.Value), LFMid,
           LFSym, LCtx) and (LFMid >= 0) and (LFSym <> NIL_SYM) and
           (LA.Proj.Model(LFMid).Symbols[LFSym].Kind = skRoutine) and
           (LA.Proj.Model(LFMid).Symbols[LFSym].Visibility in [svDefault,
           svPublished]) then
        begin
          LBx.TMid := LFMid;
          LBx.TSym := LFSym;
        end;
        LB.Prop := LBx.PropName;
        LB.Text := BindText(LBx, LB.Kind);
        LB.Method := '';
        if LB.Kind = 0 then
          LB.Method := QualifiedName(LA.Proj.Model(LBx.TMid), LBx.TSym);
        LB.FileIdx := LFi;
        LB.Line := LBi.Line;
        LN := LNodes[LObjNode[LBi.Obj]];
        // A collection a descendant writes replaces the ancestor's whole:
        // TReader clears it before reading the items.
        LText := Copy(LB.Prop, 1, Pos('[', LB.Prop));
        if LText <> '' then
          for var LI := High(LN.Binds) downto 0 do
            if (LN.Binds[LI].FileIdx < LFi) and
               StartsText(LText, LN.Binds[LI].Prop) then
              Delete(LN.Binds, LI, 1);
        LNode := -1;
        for var LI := 0 to High(LN.Binds) do
          if SameText(LN.Binds[LI].Prop, LB.Prop) then
            LNode := LI;
        // A descendant's value replaces the ancestor's; `nil` says which
        // handler no longer runs.
        if (LNode >= 0) and (LB.Kind = 3) and (LN.Binds[LNode].Kind = 0) then
          LB.Text := Format('%s -> nil (cleared: %s, which %s binds, does not '
            + 'run)', [LB.Prop, LN.Binds[LNode].Method,
            ExtractFileName(LInfos[LN.Binds[LNode].FileIdx].FilePath)]);
        if LNode >= 0 then
          LN.Binds[LNode] := LB
        else
          LN.Binds := LN.Binds + [LB];
        LNodes[LObjNode[LBi.Obj]] := LN;
      end;
    end;
    // Counted over the merged form: a replaced value is not two.
    LEvents := 0;
    LRefs := 0;
    LUnbound := 0;
    LCleared := 0;
    for var LNd in LNodes do
      for var LBd in LNd.Binds do
        case LBd.Kind of
          0: Inc(LEvents);
          1: Inc(LRefs);
          3: Inc(LCleared);
        else
          Inc(LUnbound);
        end;

    LInfo := LInfos[LInfos.Count - 1];
    LLine := Format('form %s: %s - %s', [LNodes[0].Name, LNodes[0].ClassName,
      AWs.RelPath(LInfo.FilePath)]);
    if LInfo.IsBinary then
      LLine := LLine + ' (binary - lines of its text conversion)';
    if LInfos.Count > 1 then
    begin
      LText := '';
      for var LFi := LInfos.Count - 2 downto 0 do
        LText := LText + IfThen(LText <> '', ', ', '') +
          AWs.RelPath(LInfos[LFi].FilePath);
      LLine := LLine + '; inherits ' + LText + ' - a row from one of those '
        + 'names its file';
    end;
    LSb.AppendLine(LLine);
    LSb.AppendLine(Format('%s, %s bound, %s to components%s', [Plural(
      LComponents, 'component'), Plural(LEvents, 'event'), Plural(LRefs,
      'reference'), IfThen(LUnbound > 0, Format(', %d naming nothing',
      [LUnbound]), '') + IfThen(LCleared > 0, Format(', %d cleared', [LCleared]), '')]));
    for var LE in LErrors do
      LSb.AppendLine('(' + LE + ')');
    LShown := 0;
    LTotal := 0;
    Emit(0, 0);
    LSb.Append(LRows.ToString);
    if LTotal > LShown then
      LSb.AppendLine(Format('... %d more rows (raise `limit`)',
        [LTotal - LShown]));
    Result := LSb.ToString.TrimRight;
  finally
    LErrors.Free;
    LRows.Free;
    LSb.Free;
    LByKey.Free;
    LNodes.Free;
    LInfos.Free;
  end;
end;

function ToolOutline(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
const
  SECTIONS: array[TPasOutlineSection] of string = ('', 'interface',
    'implementation', 'initialization', 'finalization');
var
  LFile, LOwner, LSection: string;
  LA: TMcpAnalysis;
  LMid, LLimit, LMemberRows: Integer;
  LM: TPasSemaModel;
  LEntries: TArray<TPasOutlineEntry>;
  LRows: TList<string>;
  LSb: TStringBuilder;
  LMembers: Boolean;

  // The rows of the outline, members of types among them or not.
  procedure Collect(AMembers: Boolean);
  var
    LLine, LLabel, LDetail: string;
    LDepth: Integer;
  begin
    LRows.Clear;
    LMemberRows := 0;
    for var LE in LEntries do
    begin
      if (LSection <> '') and (LE.Section <> osNone) and
         (SECTIONS[LE.Section] <> LSection) then
        Continue;
      if LOwner <> '' then
      begin
        if not (StartsText(LOwner, LE.Owner) or
           ((LE.Owner = '') and SameText(StripGenerics(LE.Name), LOwner))) then
          Continue;
      end;
      case LE.Kind of
        okModule:
          LRows.Add(Format('%d %s %s', [LE.Line, LE.Head, LE.Name]));
        okSection:
          LRows.Add(Format('%d %s', [LE.Line, LE.Head]));
        okUses:
          LRows.Add(Format('%d   %s', [LE.Line, LE.Head]));
        okInclude:
          LRows.Add(Format('%d   {$I %s} %s', [LE.Line, LE.Name, LE.Detail]));
      else
        begin
          if (LE.Owner <> '') and not LE.IsImpl then
          begin
            Inc(LMemberRows);
            if not AMembers then
              Continue;
          end;
          if LE.IsImpl and (LE.Owner <> '') then
          begin
            LDepth := 1;
            LLabel := LE.Owner + '.' + LE.Name;
          end
          else
          begin
            LDepth := 1;
            if LE.Owner <> '' then
              LDepth := 2 + Length(LE.Owner.Split(['.'])) - 1;
            LLabel := LE.Name;
          end;
          LLine := Format('%d%s%s %s', [LE.Line, StringOfChar(' ', 2 * LDepth),
            LE.Head, LLabel]);
          LDetail := LE.Detail;
          if (LE.Kind in [okRoutine, okProperty]) and (LE.Node <> NIL_NODE) then
            LDetail := SignatureDetail(LM, LE.Node);
          if LDetail <> '' then
          begin
            if LDetail.StartsWith('(') or LDetail.StartsWith(':') or
               LDetail.StartsWith('[') then
              LLine := LLine + LDetail
            else
              LLine := LLine + ' ' + LDetail;
          end;
          if (LE.FilePath <> '') and not SameText(LE.FilePath, LFile) then
            LLine := LLine + '  [in ' + AWs.RelPath(LE.FilePath) + ']';
          LRows.Add(LLine);
        end;
      end;
    end;
  end;

begin
  if ArgStr(AArgs, 'file') = '' then
    raise EToolError.Create('`file` is required');
  LFile := ArgFile(AWs, AArgs);
  if not ModelOfFile(AWs, LFile, LA, LMid) then
    raise EToolError.CreateFmt('%s is not part of any analyzed project',
      [AWs.RelPath(LFile)]);
  LOwner := ArgStr(AArgs, 'owner');
  LSection := LowerCase(ArgStr(AArgs, 'section'));
  LMembers := ArgBool(AArgs, 'members', True);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 400), 1, 100000);
  LM := LA.Proj.Model(LMid);
  LEntries := PasModuleOutline(LM.Tree);
  LRows := TList<string>.Create;
  LSb := TStringBuilder.Create;
  try
    LSb.AppendLine(Format('%s (%d lines)', [AWs.RelPath(LFile),
      Length(LM.Tree.Source.Files[0].LineStarts)]));
    Collect(LMembers);
    // Too long whole: the types' members go first - the unit's types and
    // routines are what an outline is read for, and `owner` gives one
    // type's members back. Not when members were asked for by name.
    if (LRows.Count > LLimit) and LMembers and (AArgs.GetValue('members') = nil)
       and (LMemberRows > 0) then
    begin
      Collect(False);
      LSb.AppendLine(Format('(%d rows in all - the %d member declarations of '
        + 'its types are left out: `owner` lists one type''s, `members: true` '
        + 'with a higher `limit` all of them)', [LRows.Count + LMemberRows,
        LMemberRows]));
    end;
    for var LI := 0 to Min(LRows.Count, LLimit) - 1 do
      LSb.AppendLine(LRows[LI]);
    if LRows.Count > LLimit then
      LSb.AppendLine(Format('... %d more rows (raise `limit`, or narrow with '
        + '`section` or `owner`)', [LRows.Count - LLimit]));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
    LRows.Free;
  end;
end;

function ToolDiagnostics(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LFile, LDiagFile, LKey, LWhere: string;
  LLibrary: Boolean;
  LLimit, LShown, LOwner, LN: Integer;
  LByFile: TDictionary<string, Integer>;
  LTop: TList<TPair<string, Integer>>;
  LM: TPasSemaModel;
  LRows: TList<THit>;
  LSeen: TDictionary<string, Boolean>;
  LH: THit;
  LArr: TArray<THit>;
  LSb: TStringBuilder;
  LFiles: TDictionary<string, Boolean>;
  LEnclosing: TEnclosing;
begin
  LFile := '';
  if ArgStr(AArgs, 'file') <> '' then
    LFile := ArgFile(AWs, AArgs);
  LLibrary := ArgBool(AArgs, 'library', False);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 60), 1, 5000);
  LRows := TList<THit>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  LFiles := TDictionary<string, Boolean>.Create;
  LSb := TStringBuilder.Create;
  LEnclosing := TEnclosing.Create(AWs);
  try
    for var LA in AWs.Analyses do
      for var LMid := 0 to LA.Proj.ModelCount - 1 do
      begin
        if (LFile <> '') and not SameText(LA.Proj.ModelFile(LMid), LFile) then
          Continue;
        if (LFile = '') and not LLibrary and
           not AWs.IsOwnFile(LA.Proj.ModelFile(LMid)) then
          Continue;
        // One configuration speaks for a unit: its own project's (see
        // TMcpWorkspace.OwnerAnalysis). A library unit has no owner and is
        // reported from the first analysis that holds it.
        LOwner := AWs.OwnerAnalysis(LA.Proj.ModelFile(LMid));
        if (LOwner >= 0) and (LOwner <> LA.Index) then
          Continue;
        LM := LA.Proj.Model(LMid);
        for var LD in LM.Diags do
        begin
          if LD.Msg = '' then
            Continue;   // capacity slack, should a driver not have trimmed
          if (LD.FileId >= 0) and (LD.FileId <= High(LM.Tree.Source.FileNames))
          then
            LDiagFile := LM.Tree.Source.FileNames[LD.FileId]
          else
            LDiagFile := LA.Proj.ModelFile(LMid);
          LKey := LowerCase(LDiagFile) + ':' + IntToStr(LD.Line) + ':' +
            IntToStr(LD.Col) + ':' + LD.Code;
          if LSeen.ContainsKey(LKey) then
            Continue;
          LSeen.Add(LKey, True);
          LH := Default(THit);
          LH.FilePath := LDiagFile;
          LH.Line := LD.Line;
          LH.Col := LD.Col;
          LH.Snippet := LD.Msg;
          LRows.Add(LH);
          LFiles.AddOrSetValue(LowerCase(LDiagFile), True);
        end;
      end;
    LArr := LRows.ToArray;
    TArray.Sort<THit>(LArr, TComparer<THit>.Construct(
      function(const L, R: THit): Integer
      begin
        Result := CompareText(L.FilePath, R.FilePath);
        if Result = 0 then
          Result := L.Line - R.Line;
        if Result = 0 then
          Result := L.Col - R.Col;
      end));
    if Length(LArr) = 0 then
      LSb.AppendLine('no diagnostics' + IfThen(LFile <> '', ' in ' +
        AWs.RelPath(LFile), ' in the project units'))
    else
      LSb.AppendLine(Format('%d diagnostics in %d files', [Length(LArr),
        LFiles.Count]));
    // More than fit: say WHERE they are first - one row per file, worst first.
    if (LFile = '') and (Length(LArr) > LLimit) and (LFiles.Count > 1) then
    begin
      LByFile := TDictionary<string, Integer>.Create;
      LTop := TList<TPair<string, Integer>>.Create;
      try
        for var LRow in LArr do
        begin
          if not LByFile.TryGetValue(LRow.FilePath, LN) then
            LN := 0;
          LByFile.AddOrSetValue(LRow.FilePath, LN + 1);
        end;
        for var LPair in LByFile do
          LTop.Add(LPair);
        LTop.Sort(TComparer<TPair<string, Integer>>.Construct(
          function(const L, R: TPair<string, Integer>): Integer
          begin
            Result := R.Value - L.Value;
            if Result = 0 then
              Result := CompareText(L.Key, R.Key);
          end));
        LSb.AppendLine('by file:');
        for var LI := 0 to Min(LTop.Count, 15) - 1 do
          LSb.AppendLine(Format('  %5d  %s', [LTop[LI].Value,
            AWs.RelPath(LTop[LI].Key)]));
        if LTop.Count > 15 then
          LSb.AppendLine(Format('  ... %d more files', [LTop.Count - 15]));
        LSb.AppendLine('first rows:');
      finally
        LTop.Free;
        LByFile.Free;
      end;
    end;
    LShown := 0;
    for var LRow in LArr do
    begin
      if LShown >= LLimit then
        Break;
      // No source line is shown, so a row on a routine's header names that
      // routine too.
      LWhere := LEnclosing.NameAt(LRow.FilePath, LRow.Line, LRow.Col, False);
      LSb.AppendLine(Format('%s:%d:%d: %s%s', [AWs.RelPath(LRow.FilePath),
        LRow.Line, LRow.Col, LRow.Snippet,
        IfThen(LWhere <> '', ' (in ' + LWhere + ')', '')]));
      Inc(LShown);
    end;
    if Length(LArr) > LShown then
      LSb.AppendLine(Format('... %d more (raise `limit`, or pass `file`)',
        [Length(LArr) - LShown]));
    Result := LSb.ToString.TrimRight;
  finally
    LEnclosing.Free;
    LSb.Free;
    LFiles.Free;
    LSeen.Free;
    LRows.Free;
  end;
end;

function ToolUnitDeps(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LA: TMcpAnalysis;
  LMid, LImplLine, LLine, LCol, LTMid: Integer;
  LFile, LDir, LSiteFile: string;
  LM: TPasSemaModel;
  LSb: TStringBuilder;
  LSet: THitSet;
  LHits: TArray<THit>;
  LFound: Boolean;
begin
  LDir := LowerCase(ArgStr(AArgs, 'direction', 'both'));
  LFound := False;
  LA := nil;
  LMid := -1;
  if ArgStr(AArgs, 'file') <> '' then
  begin
    LFile := ArgFile(AWs, AArgs);
    LFound := ModelOfFile(AWs, LFile, LA, LMid);
  end
  else if ArgStr(AArgs, 'unit') <> '' then
  begin
    for var LCand in AWs.Analyses do
    begin
      for var LI := 0 to LCand.Proj.ModelCount - 1 do
        if SameText(UnitNameOfFile(LCand.Proj.ModelFile(LI)),
           ArgStr(AArgs, 'unit')) then
        begin
          LA := LCand;
          LMid := LI;
          LFound := True;
          LA.Proj.EnsureHydrated(LMid);
          Break;
        end;
      if LFound then
        Break;
    end;
  end
  else
    raise EToolError.Create('give `unit` (a unit name) or `file`');
  if not LFound then
    raise EToolError.Create('that unit is not part of any analyzed project');
  LFile := LA.Proj.ModelFile(LMid);
  LM := LA.Proj.Model(LMid);
  LSb := TStringBuilder.Create;
  LSet := THitSet.Create(AWs);
  try
    if (LDir = 'uses') or (LDir = 'both') then
    begin
      // Which section each item sits in: before or after `implementation`.
      LImplLine := MaxInt;
      for var LE in PasModuleOutline(LM.Tree) do
        if (LE.Kind = okSection) and SameText(LE.Head, 'implementation') then
          LImplLine := LE.Line;
      LSb.AppendLine(Format('%s uses %d units:', [AWs.RelPath(LFile),
        Length(LM.UsesList)]));
      for var LU in LM.UsesList do
      begin
        LLine := 0;
        LA.Proj.NodeSite(LMid, LU.NameNode, LSiteFile, LLine, LCol);
        if LU.UnitId >= 0 then
          LSb.AppendLine(Format('  %-40s %s%s', [LU.NameFull,
            AWs.RelPath(LA.Proj.ModelFile(LU.UnitId)),
            IfThen(LLine > LImplLine, '  (implementation)', '')]))
        else
          LSb.AppendLine(Format('  %-40s (unresolved)%s', [LU.NameFull,
            IfThen(LLine > LImplLine, '  (implementation)', '')]));
      end;
    end;
    if (LDir = 'used_by') or (LDir = 'both') then
    begin
      for var LB in AWs.Analyses do
      begin
        LTMid := LB.Nav.ModelIdOf(LFile);
        if LTMid >= 0 then
          for var LH in LB.Nav.FindUnitReferences(LTMid) do
            LSet.Add(LH);
      end;
      LHits := LSet.Sorted;
      LSb.AppendLine(Format('%s is used by %d units:', [
        UnitNameOfFile(LFile), Length(LHits)]));
      for var LH in LHits do
        LSb.AppendLine(Format('  %s:%d', [AWs.RelPath(LH.FilePath), LH.Line]));
    end;
    Result := LSb.ToString.TrimRight;
  finally
    LSet.Free;
    LSb.Free;
  end;
end;

{ ---- impact ---------------------------------------------------------------------- }

const
  // Changed declarations whose callers one impact answer searches, and the
  // ones it lists; past them the rest are named or counted.
  MAX_IMPACT_ROOTS = 40;
  MAX_IMPACT_DECLS = 100;

type
  { Which members of the group compile a file in (SPEC 9.3.3). An analysis
    holds one or more members (section 4) and its models are their closures
    together; a member's own is what its main source reaches through `uses`,
    interface and implementation alike - the units dcc compiles into it.
    Built per member on first use, a flag per model of its analysis. }
  TMemberReach = class
  private
    FWs: TMcpWorkspace;
    FReach: TDictionary<Integer, TArray<Boolean>>;
    function Reach(AMember: Integer): TArray<Boolean>;
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    // The members whose closure holds model file AFile - a unit, a program,
    // a package - by index into TMcpWorkspace.Members.
    function MembersOf(const AFile: string): TArray<Integer>;
  end;

  // One line of a unified diff, numbered in the NEW file: its own line, or -
  // a removed line - the line that follows the removal.
  TDiffLine = record
    Kind: Char;            // '+', '-' or ' '
    Line: Integer;
    Text: string;
  end;

  TDiffFile = record
    OldPath, NewPath: string;   // as written, git's a/ b/ left on; '' = /dev/null
    Lines: TArray<TDiffLine>;
  end;

  // A declaration a change touches - or, with none around the changed lines,
  // the place they are in: a uses clause, an initialization section.
  TImpactDecl = class
  public
    T: TTarget;            // the declaration; unset for a place
    Place: string;         // '' for a declaration
    Lines: TArray<Integer>;
    Node: Integer;         // its root in the caller walk; -1 = not searched
    procedure AddLine(ALine: Integer);
    function FirstLine: Integer;
  end;

  TImpactFile = class
  public
    Path: string;          // full path; as the diff writes it when not on disk
    Note: string;          // said after the path: deleted, a form, ...
    Units: TArray<string>; // the model files it changes: itself, its
                           // includers, the unit of a form
    Project: Integer;      // the member whose .dproj it is; -1
    Iface: Boolean;        // its interface section changed
    UsedBy: Boolean;       // a unit asked about: list the units using it
    Code, Comments: Boolean;   // changed lines of code / of comments alone
    Decls: TList<TImpactDecl>;   // not owned
    Removed: TArray<string>;     // 'TFoo.Bar (procedure)'
    RemovedKeys: TArray<string>; // their last segment, lower-case
    Members: TArray<Integer>;
    constructor Create;
    destructor Destroy; override;
  end;

  { What a change reaches (SPEC 9.3.3): the declarations a diff touches - or
    the ones named - with the methods they are also called through and their
    overrides, their callers or uses to a depth, the units a changed
    interface recompiles, and the members of the group that compile the
    changed files: the projects to build and test. }
  TImpact = class
  private
    FWs: TMcpWorkspace;
    FReach: TMemberReach;
    FEnclosing: TEnclosing;
    FFiles: TObjectList<TImpactFile>;
    FFileOf: TDictionary<string, TImpactFile>;
    FDecls: TObjectList<TImpactDecl>;
    FDeclOf: TDictionary<string, TImpactDecl>;
    FOther: TStringList;       // files of the diff the index does not read
    FNamed: TStringList;       // the declarations asked about, for the header
    FDiffFiles: Integer;       // files the diff names; -1 = no diff
    function FileFor(const APath: string): TImpactFile;
    function AddDecl(AFile: TImpactFile; const AT: TTarget): TImpactDecl;
    function AddPlace(AFile: TImpactFile; const APlace: string): TImpactDecl;
    procedure MapLines(AFile: TImpactFile; AA: TMcpAnalysis; AMid: Integer;
      const APath: string; const ALines: TArray<TDiffLine>);
    procedure NoteRemoved(AFile: TImpactFile; const ALines: TArray<TDiffLine>);
    procedure AddDiffFile(const AD: TDiffFile);
    function Names(const AMembers: TArray<Integer>): string;
    function UsedByText(AFile: TImpactFile; AMax: Integer): string;
    function Leftovers: TObjectDictionary<string, TList<THit>>;
    function FormLeftovers(AFile: TImpactFile; AIdx: Integer): TArray<THit>;
    function ImplementedIn(const AT: TTarget): TArray<string>;
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    procedure AddTarget(const AT: TTarget);
    procedure AddDiff(const AText: string);
    function Empty: Boolean;
    function Answer(ADepth, ALimit: Integer): string;
  end;

function IsRoutineHead(const AHead: string): Boolean;
begin
  Result := (AHead = 'procedure') or (AHead = 'function') or
    (AHead = 'constructor') or (AHead = 'destructor') or
    (AHead = 'operator') or (AHead = 'routine');
end;

function HasInt(const AValues: TArray<Integer>; AValue: Integer): Boolean;
begin
  for var LV in AValues do
    if LV = AValue then
      Exit(True);
  Result := False;
end;

constructor TMemberReach.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FReach := TDictionary<Integer, TArray<Boolean>>.Create;
end;

destructor TMemberReach.Destroy;
begin
  FReach.Free;
  inherited;
end;

function TMemberReach.Reach(AMember: Integer): TArray<Boolean>;
var
  LA: TMcpAnalysis;
  LQueue: TList<Integer>;
  LMid, LHead: Integer;
  LM: TPasSemaModel;
begin
  if FReach.TryGetValue(AMember, Result) then
    Exit;
  Result := nil;
  if FWs.Members[AMember].Analysis >= 0 then
  begin
    LA := FWs.Analyses[FWs.Members[AMember].Analysis];
    SetLength(Result, LA.Proj.ModelCount);
    LMid := LA.Nav.ModelIdOf(FWs.Members[AMember].MainSource);
    if LMid >= 0 then
    begin
      LQueue := TList<Integer>.Create;
      try
        Result[LMid] := True;
        LQueue.Add(LMid);
        LHead := 0;
        while LHead < LQueue.Count do
        begin
          LM := LA.Proj.Model(LQueue[LHead]);
          Inc(LHead);
          for var LU := 0 to High(LM.UsesList) do
          begin
            LMid := LM.UsesList[LU].UnitId;
            if (LMid >= 0) and (LMid < Length(Result)) and not Result[LMid] then
            begin
              Result[LMid] := True;
              LQueue.Add(LMid);
            end;
          end;
        end;
      finally
        LQueue.Free;
      end;
    end;
  end;
  FReach.Add(AMember, Result);
end;

function TMemberReach.MembersOf(const AFile: string): TArray<Integer>;
var
  LMid: Integer;
  LReach: TArray<Boolean>;
begin
  Result := nil;
  for var LIdx := 0 to High(FWs.Members) do
  begin
    if FWs.Members[LIdx].Analysis < 0 then
      Continue;
    LMid := FWs.Analyses[FWs.Members[LIdx].Analysis].Nav.ModelIdOf(AFile);
    if LMid < 0 then
      Continue;
    LReach := Reach(LIdx);
    if (LMid < Length(LReach)) and LReach[LMid] then
      Result := Result + [LIdx];
  end;
end;

{ ---- reading a diff ---- }

// A path from a `---` or `+++` line: the timestamp `diff -u` writes after a
// tab cut off, git's quotes undone; '' for /dev/null.
function DiffPath(const AText: string): string;
var
  LAt: Integer;
begin
  Result := AText;
  LAt := Pos(#9, Result);
  if LAt > 0 then
    Result := Copy(Result, 1, LAt - 1);
  Result := Trim(Result);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2).Replace('\"', '"').
      Replace('\\', '\');
  if Result = '/dev/null' then
    Result := '';
end;

// `@@ -12,3 +12,4 @@`: the old line count, the new start and count - a count
// left out is 1.
function ParseHunk(const AText: string; out AOld, ANewStart,
  ANew: Integer): Boolean;
var
  LAt, LOldStart: Integer;

  function Num(out AValue: Integer): Boolean;
  var
    LFrom: Integer;
  begin
    LFrom := LAt;
    while (LAt <= Length(AText)) and CharInSet(AText[LAt], ['0'..'9']) do
      Inc(LAt);
    Result := (LAt > LFrom) and TryStrToInt(Copy(AText, LFrom, LAt - LFrom),
      AValue);
  end;

  function Count(out AValue: Integer): Boolean;
  begin
    AValue := 1;
    Result := True;
    if (LAt <= Length(AText)) and (AText[LAt] = ',') then
    begin
      Inc(LAt);
      Result := Num(AValue);
    end;
  end;

begin
  Result := False;
  AOld := 0;
  ANewStart := 0;
  ANew := 0;
  if not AText.StartsWith('@@ -') then
    Exit;
  LAt := 5;
  if not Num(LOldStart) or not Count(AOld) or (Copy(AText, LAt, 2) <> ' +') then
    Exit;
  Inc(LAt, 2);
  Result := Num(ANewStart) and Count(ANew);
end;

// The files of a unified diff - `git diff`, `diff -u` - with their lines
// numbered in the new file. A hunk is read by its counts, so a removed line
// that starts with `--` is not taken for a header.
function ParseDiff(const AText: string): TArray<TDiffFile>;
var
  LFiles: TList<TDiffFile>;
  LRows: TList<TDiffLine>;
  LCur: TDiffFile;
  LOpen, LSawOld: Boolean;
  LOld, LNew, LLine, LAt: Integer;
  LS: string;

  procedure Close;
  begin
    if LOpen then
    begin
      LCur.Lines := LRows.ToArray;
      LFiles.Add(LCur);
    end;
    LCur := Default(TDiffFile);
    LRows.Clear;
    LOpen := False;
    LSawOld := False;
  end;

  procedure Open;
  begin
    Close;
    LOpen := True;
  end;

  procedure Add(AKind: Char);
  var
    LRow: TDiffLine;
  begin
    LRow.Kind := AKind;
    LRow.Line := LLine;
    LRow.Text := Copy(LS, 2, MaxInt);
    LRows.Add(LRow);
  end;

begin
  LFiles := TList<TDiffFile>.Create;
  LRows := TList<TDiffLine>.Create;
  try
    LOpen := False;
    LSawOld := False;
    LCur := Default(TDiffFile);
    LOld := 0;
    LNew := 0;
    LLine := 0;
    for var LRaw in AText.Split([#10]) do
    begin
      LS := LRaw;
      if LS.EndsWith(#13) then
        SetLength(LS, Length(LS) - 1);
      if LOpen and ((LOld > 0) or (LNew > 0)) then
      begin
        // An empty line in a hunk is a context line whose space was trimmed.
        if LS = '' then
          LS := ' ';
        case LS[1] of
          ' ':
            begin
              Add(' ');
              Inc(LLine);
              Dec(LOld);
              Dec(LNew);
              Continue;
            end;
          '+':
            begin
              Add('+');
              Inc(LLine);
              Dec(LNew);
              Continue;
            end;
          '-':
            begin
              Add('-');
              Dec(LOld);
              Continue;
            end;
          '\':
            Continue;   // \ No newline at end of file
        end;
        // A hunk cut short: read on as a header.
        LOld := 0;
        LNew := 0;
      end;
      if LS.StartsWith('diff ') then
      begin
        Open;
        // `diff --git a/X b/Y`: the paths when no ---/+++ follows - a binary
        // file, a rename alone.
        LAt := LS.LastIndexOf(' b/');
        if LS.StartsWith('diff --git ') and (LAt > 10) then
        begin
          LCur.OldPath := Trim(Copy(LS, 12, LAt - 10));
          LCur.NewPath := Trim(Copy(LS, LAt + 2, MaxInt));
        end;
      end
      else if LS.StartsWith('--- ') then
      begin
        if not LOpen or LSawOld then
          Open;
        LSawOld := True;
        LCur.OldPath := DiffPath(Copy(LS, 5, MaxInt));
      end
      else if LS.StartsWith('+++ ') then
      begin
        if not LOpen then
          Open;
        LCur.NewPath := DiffPath(Copy(LS, 5, MaxInt));
      end
      else if LOpen and LS.StartsWith('@@ ') then
      begin
        if ParseHunk(LS, LOld, LLine, LNew) and (LNew = 0) then
          Inc(LLine);   // `+12,0`: the removal follows line 12
      end
      else if LOpen and LS.StartsWith('rename to ') then
        LCur.NewPath := Trim(Copy(LS, 11, MaxInt))
      else if LOpen and LS.StartsWith('deleted file mode') then
        LCur.NewPath := '';
    end;
    Close;
    Result := LFiles.ToArray;
  finally
    LRows.Free;
    LFiles.Free;
  end;
end;

// A diff path without git's a/ or b/ in front, as an answer names it.
function DiffShown(const APath: string): string;
begin
  if APath.StartsWith('a/') or APath.StartsWith('b/') then
    Result := Copy(APath, 3, MaxInt)
  else
    Result := APath;
  Result := Result.Replace('/', '\');
end;

// A diff path on disk: as written - git's a/ b/ taken off first - relative to
// the group directory or to a directory above it, where git's paths start
// when the repository holds more than the group. '' when none exists.
function DiffFileOnDisk(AWs: TMcpWorkspace; const APath: string): string;
var
  LCands: TArray<string>;
  LDir, LUp, LFull: string;
begin
  Result := '';
  if APath = '' then
    Exit;
  if APath.StartsWith('a/') or APath.StartsWith('b/') then
    LCands := [Copy(APath, 3, MaxInt), APath]
  else
    LCands := [APath];
  for var LC in LCands do
    try
      if TPath.IsPathRooted(LC) then
      begin
        if TFile.Exists(LC) then
          Exit(TPath.GetFullPath(LC));
        Continue;
      end;
      LDir := AWs.Root;
      while LDir <> '' do
      begin
        LFull := TPath.GetFullPath(TPath.Combine(LDir, LC));
        if TFile.Exists(LFull) then
          Exit(LFull);
        LUp := TPath.GetDirectoryName(LDir);
        if SameText(LUp, LDir) then
          Break;
        LDir := LUp;
      end;
    except
      // characters no path can hold: not this candidate
    end;
end;

// Is a changed line code, rather than blank or a comment alone? Read from the
// diff's own text, so a removed line is judged too; a line inside a block
// comment passes for code, which only widens the answer.
function IsCodeText(const AText: string): Boolean;
var
  LT: string;
begin
  LT := Trim(AText);
  if (LT = '') or LT.StartsWith('//') then
    Exit(False);
  if LT.StartsWith('{') and not LT.StartsWith('{$') and
     (Pos('}', LT) = Length(LT)) then
    Exit(False);
  if LT.StartsWith('(*') and not LT.StartsWith('(*$') and LT.EndsWith('*)') then
    Exit(False);
  Result := True;
end;

// A line as the check that a diff matches the file compares it: trimmed, and
// every character past ASCII dropped - a diff that went through a console
// may carry those in another encoding, and it is the numbering that counts.
function LineSkeleton(const AText: string): string;
var
  LSb: TStringBuilder;
begin
  LSb := TStringBuilder.Create;
  try
    for var LCh in AText do
      if LCh <= #127 then
        LSb.Append(LCh);
    Result := Trim(LSb.ToString);
  finally
    LSb.Free;
  end;
end;

// The routine, property or type a line of source declares, by the words it
// starts with - `procedure TFoo.Bar(`, `class function Baz:`, `property
// Count:`, `TFoo = class(` - with its head word in AHead; '' for any other
// line.
function DeclaredOnLine(const AText: string; out AHead: string): string;
const
  HEADS: array[0..5] of string = ('procedure', 'function', 'constructor',
    'destructor', 'operator', 'property');
  TYPE_HEADS: array[0..4] of string = ('class', 'record', 'interface',
    'object', 'dispinterface');
var
  LT, LFirst, LWord: string;
  LAt: Integer;

  function Ident: string;
  var
    LFrom: Integer;
  begin
    while (LAt <= Length(LT)) and (LT[LAt] = ' ') do
      Inc(LAt);
    LFrom := LAt;
    while (LAt <= Length(LT)) and (IsIdentChar(LT[LAt]) or (LT[LAt] = '.')) do
      Inc(LAt);
    Result := Copy(LT, LFrom, LAt - LFrom);
  end;

  // A qualified name, generic parameters stepped over: TList<T>.Add.
  function QualName: string;
  begin
    Result := Ident;
    while (LAt <= Length(LT)) and (LT[LAt] = '<') do
    begin
      while (LAt <= Length(LT)) and (LT[LAt] <> '>') do
        Inc(LAt);
      Inc(LAt);
      if (LAt <= Length(LT)) and (LT[LAt] = '.') then
        Result := Result + Ident;
    end;
  end;

begin
  Result := '';
  AHead := '';
  LT := Trim(AText).Replace(#9, ' ');
  LAt := 1;
  LFirst := Ident;
  LWord := LowerCase(LFirst);
  if LWord = 'class' then
    LWord := LowerCase(Ident);
  for var LH in HEADS do
    if LWord = LH then
    begin
      Result := QualName;
      if Result <> '' then
        AHead := LH;
      Exit;
    end;
  // `TFoo = class(TBase)`, `TFoo<T> = record`
  if (LFirst = '') or (Pos('.', LFirst) > 0) then
    Exit;
  if (LAt <= Length(LT)) and (LT[LAt] = '<') then
  begin
    while (LAt <= Length(LT)) and (LT[LAt] <> '>') do
      Inc(LAt);
    Inc(LAt);
  end;
  while (LAt <= Length(LT)) and (LT[LAt] = ' ') do
    Inc(LAt);
  if (LAt > Length(LT)) or (LT[LAt] <> '=') then
    Exit;
  Inc(LAt);
  LWord := LowerCase(Ident);
  if LWord = 'packed' then
    LWord := LowerCase(Ident);
  for var LH in TYPE_HEADS do
    if LWord = LH then
    begin
      AHead := LH;
      Result := LFirst;
      Exit;
    end;
end;

// The fields a line of a type declares - `FCount, FTotal: Integer;` - by its
// shape: names before a colon, a semicolon at the end, no parenthesis (a
// parameter). Nil for any other line.
function FieldsOnLine(const AText: string): TArray<string>;
const
  WORDS: array[0..12] of string = ('case', 'var', 'const', 'type', 'class',
    'property', 'strict', 'private', 'protected', 'public', 'published',
    'threadvar', 'out');
var
  LT, LName: string;
  LAt: Integer;
begin
  Result := nil;
  LT := AText;
  LAt := Pos('//', LT);
  if LAt > 0 then
    LT := Copy(LT, 1, LAt - 1);
  LT := Trim(LT);
  LAt := Pos(':', LT);
  if (LAt <= 1) or (Copy(LT, LAt, 2) = ':=') or not LT.EndsWith(';') or
     (Pos('(', LT) > 0) or (Pos(')', LT) > 0) then
    Exit;
  for var LPart in Copy(LT, 1, LAt - 1).Split([',']) do
  begin
    LName := Trim(LPart);
    if not IsValidIdent(LName) or (IndexText(LName, WORDS) >= 0) then
      Exit(nil);
    Result := Result + [LName];
  end;
end;

// The visible tokens of the names a declaration node declares: a routine's
// last segment (an implementation header names its declaration's symbol
// there), a type's name, every name a variable declaration lists, the one
// name of a constant or a property.
function DeclNameVises(LM: TPasSemaModel; ANode: Integer): TArray<Integer>;
var
  LChild, LPrev, LFirst, LLast: Integer;
begin
  Result := nil;
  case LM.Tree.Nodes[ANode].Kind of
    nkRoutine:
      begin
        DeclName(LM, ANode, LFirst, LLast);
        if LLast >= 0 then
          Result := [LLast];
      end;
    nkTypeDecl:
      begin
        DeclName(LM, ANode, LFirst);
        if LFirst >= 0 then
          Result := [LFirst];
      end;
    nkVarDecl, nkConstDecl, nkPropertyDecl:
      begin
        LChild := LM.Tree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          case LM.Tree.Nodes[LChild].Kind of
            nkIdent:
              begin
                // The type after the colon is an nkIdent too.
                LPrev := LM.Tree.NodeLeftmostVis(LChild) - 1;
                if (LPrev >= 0) and
                   (LM.Tree.Source.VisibleToken(LPrev).Kind = tkColon) then
                  Break;
                Result := Result + [LM.Tree.NodeLeftmostVis(LChild)];
                if LM.Tree.Nodes[ANode].Kind <> nkVarDecl then
                  Break;
              end;
            nkAttrGroup:
              ;
          else
            Break;
          end;
          LChild := LM.Tree.Nodes[LChild].NextSibling;
        end;
      end;
  end;
end;

// '26, 53-56' - sorted, runs joined, six runs at most.
function LinesText(const ALines: TArray<Integer>): string;
var
  LSorted: TArray<Integer>;
  LFrom, LRuns, LIdx: Integer;
begin
  LSorted := Copy(ALines);
  TArray.Sort<Integer>(LSorted);
  Result := '';
  LRuns := 0;
  LIdx := 0;
  while LIdx <= High(LSorted) do
  begin
    LFrom := LSorted[LIdx];
    while (LIdx < High(LSorted)) and (LSorted[LIdx + 1] <= LSorted[LIdx] + 1) do
      Inc(LIdx);
    Inc(LRuns);
    if LRuns > 6 then
      Exit(Result + ', ...');
    if Result <> '' then
      Result := Result + ', ';
    if LSorted[LIdx] > LFrom then
      Result := Result + Format('%d-%d', [LFrom, LSorted[LIdx]])
    else
      Result := Result + IntToStr(LFrom);
    Inc(LIdx);
  end;
end;

{ ---- the change, and its answer ---- }

procedure TImpactDecl.AddLine(ALine: Integer);
begin
  for var LL in Lines do
    if LL = ALine then
      Exit;
  Lines := Lines + [ALine];
end;

function TImpactDecl.FirstLine: Integer;
begin
  Result := MaxInt;
  for var LL in Lines do
    Result := Min(Result, LL);
end;

constructor TImpactFile.Create;
begin
  inherited Create;
  Project := -1;
  Decls := TList<TImpactDecl>.Create;
end;

destructor TImpactFile.Destroy;
begin
  Decls.Free;
  inherited;
end;

constructor TImpact.Create(AWs: TMcpWorkspace);
begin
  inherited Create;
  FWs := AWs;
  FReach := TMemberReach.Create(AWs);
  FEnclosing := TEnclosing.Create(AWs);
  FFiles := TObjectList<TImpactFile>.Create(True);
  FFileOf := TDictionary<string, TImpactFile>.Create;
  FDecls := TObjectList<TImpactDecl>.Create(True);
  FDeclOf := TDictionary<string, TImpactDecl>.Create;
  FOther := TStringList.Create;
  FNamed := TStringList.Create;
  FDiffFiles := -1;
end;

destructor TImpact.Destroy;
begin
  FNamed.Free;
  FOther.Free;
  FDeclOf.Free;
  FDecls.Free;
  FFileOf.Free;
  FFiles.Free;
  FEnclosing.Free;
  FReach.Free;
  inherited;
end;

function TImpact.FileFor(const APath: string): TImpactFile;
begin
  if FFileOf.TryGetValue(LowerCase(APath), Result) then
    Exit;
  Result := TImpactFile.Create;
  Result.Path := APath;
  FFiles.Add(Result);
  FFileOf.Add(LowerCase(APath), Result);
end;

function TImpact.AddDecl(AFile: TImpactFile; const AT: TTarget): TImpactDecl;
var
  LKey: string;
begin
  LKey := SiteKey(AT.DeclFile, AT.DeclLine, AT.DeclCol);
  if FDeclOf.TryGetValue(LKey, Result) then
    Exit;
  Result := TImpactDecl.Create;
  Result.T := AT;
  Result.Node := -1;
  FDecls.Add(Result);
  FDeclOf.Add(LKey, Result);
  AFile.Decls.Add(Result);
end;

function TImpact.AddPlace(AFile: TImpactFile;
  const APlace: string): TImpactDecl;
var
  LKey: string;
begin
  LKey := LowerCase(AFile.Path) + '|' + APlace;
  if FDeclOf.TryGetValue(LKey, Result) then
    Exit;
  Result := TImpactDecl.Create;
  Result.Place := APlace;
  Result.Node := -1;
  FDecls.Add(Result);
  FDeclOf.Add(LKey, Result);
  AFile.Decls.Add(Result);
end;

{ The declarations the changed lines of APath touch, read from model AMid -
  APath's own, or one including it. A changed line of code touches the
  innermost declaration around its tokens: a routine (the whole of it - what
  is nested in a routine is its own business), a type, or a variable, a
  constant or a property of a unit or a type. A line with no token of its own
  - a directive, a removal - touches the declaration around the tokens on
  both sides of it. Outside every declaration: the place, a uses clause or an
  initialization section. Refused when the diff's lines are not the file's:
  a diff of another state numbers another file. }
procedure TImpact.MapLines(AFile: TImpactFile; AA: TMcpAnalysis; AMid: Integer;
  const APath: string; const ALines: TArray<TDiffLine>);
var
  LM: TPasSemaModel;
  LFileId, LCount, LLine, LCol, LNext, LB, LTok, LIfaceFrom, LIfaceTo,
    LFirstVis, LLastVis: Integer;
  LText: string;
  LNodes, LFrom, LTo, LOuter, LPlaceFrom, LPlaceTo, LStack: TList<Integer>;
  LPlaceName: TStringList;
  LOrder, LInner, LFirst, LLast, LBefore, LAfter: TArray<Integer>;
  LPlus, LCode: Boolean;
  LFid, LFromLine, LToLine: Integer;
  LDeclsOf: TDictionary<Integer, TArray<TImpactDecl>>;
  LAdded: TDictionary<Integer, Boolean>;

  function InRoutine(ANode: Integer): Boolean;
  var
    LUp: Integer;
  begin
    LUp := LM.Tree.Nodes[ANode].Parent;
    while LUp <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LUp].Kind = nkRoutine then
        Exit(True);
      LUp := LM.Tree.Nodes[LUp].Parent;
    end;
    Result := False;
  end;

  procedure AddPlaceSpan(ANode: Integer; const AName: string);
  begin
    if LM.Tree.NodeVisRange(ANode, LFirstVis, LLastVis) then
    begin
      LPlaceFrom.Add(LFirstVis);
      LPlaceTo.Add(LLastVis);
      LPlaceName.Add(AName);
    end;
  end;

  // The declarations span ASpan stands for, resolved once. A name that does
  // not resolve here - written in an include file - is listed by its text.
  function DeclsOf(ASpan: Integer): TArray<TImpactDecl>;
  var
    LFid, LNameLine, LNameCol, LTMid, LTSym, LVis: Integer;
    LName: string;
    LT: TTarget;
  begin
    if LDeclsOf.TryGetValue(ASpan, Result) then
      Exit;
    Result := nil;
    for var LNameVis in DeclNameVises(LM, LNodes[ASpan]) do
      if VisPos(LM, LNameVis, LFid, LNameLine, LNameCol) and (LFid = 0) and
         AA.Nav.SymbolAt(AMid, LNameLine, LNameCol, LTMid, LTSym, LName) then
      begin
        LT := Default(TTarget);
        LT.Ids := NewIds(FWs);
        if FillSymbolTarget(FWs, AA, LTMid, LTSym, LT) then
        begin
          MapToOthers(FWs, LT);
          Result := Result + [AddDecl(AFile, LT)];
        end;
      end;
    if Result = nil then
    begin
      LName := DeclName(LM, LNodes[ASpan], LVis);
      if LName <> '' then
        Result := [AddPlace(AFile, LName)];
    end;
    LDeclsOf.Add(ASpan, Result);
  end;

  // A changed point: the tokens AB..AAfter, one token or the two around a
  // line that has none.
  procedure Touch(AB, AAfter, ALine: Integer);
  var
    LS: Integer;
  begin
    if (LIfaceFrom >= 0) and (AB >= LIfaceFrom) and (AB <= LIfaceTo) then
      AFile.Iface := True;
    LS := -1;
    if (AB >= 0) and (AAfter >= 0) then
    begin
      LS := LInner[AAfter];
      while (LS >= 0) and (LFrom[LS] > AB) do
        LS := LOuter[LS];
    end;
    if LS >= 0 then
    begin
      for var LD in DeclsOf(LS) do
        LD.AddLine(ALine);
      Exit;
    end;
    if (AB < 0) or (AAfter < 0) then
      Exit;
    for var LP := 0 to LPlaceName.Count - 1 do
      if (AB >= LPlaceFrom[LP]) and (AAfter <= LPlaceTo[LP]) then
      begin
        AddPlace(AFile, LPlaceName[LP]).AddLine(ALine);
        Exit;
      end;
  end;

  // A changed line with tokens of its own: the innermost declarations they
  // are in. One that holds another met on the line is left out - the `;`
  // after `property X: T read FX` is the class's token, and the property
  // changed, not the class.
  procedure TouchLine(ALine: Integer);
  var
    LSpans: TList<Integer>;
    LUp, LS: Integer;
    LHolds: Boolean;
  begin
    LSpans := TList<Integer>.Create;
    try
      for var LV := LFirst[ALine] to LLast[ALine] do
        if (LM.Tree.Source.Visible[LV].FileId = LFileId) and
           not LSpans.Contains(LInner[LV]) then
          LSpans.Add(LInner[LV]);
      LS := -1;
      for var LCand in LSpans do
      begin
        if LCand < 0 then
          Continue;
        LHolds := False;
        for var LOther in LSpans do
        begin
          LUp := -1;
          if (LOther >= 0) and (LOther <> LCand) then
            LUp := LOuter[LOther];
          while (LUp >= 0) and not LHolds do
          begin
            LHolds := LUp = LCand;
            LUp := LOuter[LUp];
          end;
        end;
        if not LHolds then
        begin
          LS := LCand;
          Touch(LFrom[LS], LFrom[LS], ALine);
        end;
      end;
      // No declaration on the line: a place, or the unit's own lines.
      if LS < 0 then
        Touch(LFirst[ALine], LFirst[ALine], ALine);
      for var LV := LFirst[ALine] to LLast[ALine] do
        if (LIfaceFrom >= 0) and (LV >= LIfaceFrom) and (LV <= LIfaceTo) then
          AFile.Iface := True;
    finally
      LSpans.Free;
    end;
  end;

  // A run that only removes lines, ALines[AFrom..ATo]. Out of a type, the
  // members it removed are named - a removed routine or property the file
  // lists already, a field here - and their users are what breaks, not every
  // user of the type. What names no member (an enum value, a GUID) changed
  // the type itself.
  procedure TouchRemoval(AFrom, ATo: Integer);
  var
    LAt, LBv, LAv, LS: Integer;
    LHead: string;
    LMembers, LInHeader: Boolean;
  begin
    LAt := EnsureRange(ALines[AFrom].Line, 1, LCount + 1);
    LBv := LBefore[LAt];
    LAv := LAfter[LAt];
    LS := -1;
    if (LBv >= 0) and (LAv >= 0) then
    begin
      LS := LInner[LAv];
      while (LS >= 0) and (LFrom[LS] > LBv) do
        LS := LOuter[LS];
    end;
    if (LS >= 0) and (LM.Tree.Nodes[LNodes[LS]].Kind = nkTypeDecl) then
    begin
      LMembers := False;
      // The lines of a removed method's parameter list look like fields.
      LInHeader := False;
      for var LI := AFrom to ATo do
        if ALines[LI].Kind = '-' then
        begin
          if DeclaredOnLine(ALines[LI].Text, LHead) <> '' then
          begin
            LMembers := True;
            LInHeader := (Pos('(', ALines[LI].Text) > 0) and
              (Pos(')', ALines[LI].Text) = 0);
            Continue;
          end;
          if LInHeader then
          begin
            LInHeader := Pos(')', ALines[LI].Text) = 0;
            Continue;
          end;
          for var LName in FieldsOnLine(ALines[LI].Text) do
          begin
            LMembers := True;
            if IndexText(LName, AFile.RemovedKeys) < 0 then
            begin
              AFile.Removed := AFile.Removed + [LName + ' (field)'];
              AFile.RemovedKeys := AFile.RemovedKeys + [LowerCase(LName)];
            end;
          end;
        end;
      if LMembers then
      begin
        if (LIfaceFrom >= 0) and (LBv >= LIfaceFrom) and (LBv <= LIfaceTo) then
          AFile.Iface := True;
        Exit;
      end;
    end;
    Touch(LBv, LAv, LAt);
  end;

begin
  if not AA.Proj.EnsureHydrated(AMid) then
  begin
    AFile.Note := 'its unit could not be read back (a library unit changed '
      + 'on disk is not re-analyzed)';
    Exit;
  end;
  LM := AA.Proj.Model(AMid);
  LFileId := FileIdOf(LM, APath);
  if LFileId < 0 then
    Exit;
  LCount := Length(LM.Tree.Source.Files[LFileId].LineStarts);
  for var LD in ALines do
  begin
    if LD.Kind = '-' then
      Continue;
    LText := '';
    if (LD.Line >= 1) and (LD.Line <= LCount) then
      LText := LM.Tree.Source.Files[LFileId].LineText(LD.Line);
    if LineSkeleton(LD.Text) <> LineSkeleton(LText) then
    begin
      AFile.Note := Format('the diff does not match the file on disk: line %d '
        + 'reads `%s` - pass `git diff` of the files as they are now',
        [LD.Line, CleanLine(LText, 80)]);
      Exit;
    end;
  end;

  LNodes := TList<Integer>.Create;
  LFrom := TList<Integer>.Create;
  LTo := TList<Integer>.Create;
  LOuter := TList<Integer>.Create;
  LPlaceFrom := TList<Integer>.Create;
  LPlaceTo := TList<Integer>.Create;
  LPlaceName := TStringList.Create;
  LStack := TList<Integer>.Create;
  LDeclsOf := TDictionary<Integer, TArray<TImpactDecl>>.Create;
  LAdded := TDictionary<Integer, Boolean>.Create;
  try
    LIfaceFrom := -1;
    LIfaceTo := -1;
    for var LNode := 0 to High(LM.Tree.Nodes) do
      case LM.Tree.Nodes[LNode].Kind of
        nkRoutine, nkTypeDecl, nkVarDecl, nkConstDecl, nkPropertyDecl:
          if not InRoutine(LNode) and
             LM.Tree.NodeVisRange(LNode, LFirstVis, LLastVis) then
          begin
            LNodes.Add(LNode);
            LFrom.Add(LFirstVis);
            LTo.Add(LLastVis);
            LOuter.Add(-1);
          end;
        nkUsesClause:
          AddPlaceSpan(LNode, 'uses clause');
        nkInitSec:
          AddPlaceSpan(LNode, 'initialization');
        nkFinalSec:
          AddPlaceSpan(LNode, 'finalization');
        nkExportsClause:
          AddPlaceSpan(LNode, 'exports');
        nkBlock:
          if (LM.Tree.Nodes[LNode].Parent <> NIL_NODE) and
             (LM.Tree.Nodes[LM.Tree.Nodes[LNode].Parent].Kind in [nkProgram,
             nkLibrary]) then
            AddPlaceSpan(LNode, 'main block');
        nkInterfaceSec:
          if not LM.Tree.NodeVisRange(LNode, LIfaceFrom, LIfaceTo) then
          begin
            LIfaceFrom := -1;
            LIfaceTo := -1;
          end;
      end;

    // The innermost declaration of every token, and the one around each
    // declaration: declarations nest, so a sweep in token order with the open
    // ones on a stack has the innermost on top.
    SetLength(LOrder, LNodes.Count);
    for var LI := 0 to High(LOrder) do
      LOrder[LI] := LI;
    TArray.Sort<Integer>(LOrder, TComparer<Integer>.Construct(
      function(const L, R: Integer): Integer
      begin
        Result := LFrom[L] - LFrom[R];
        if Result = 0 then
          Result := LTo[R] - LTo[L];
      end));
    SetLength(LInner, Length(LM.Tree.Source.Visible));
    LNext := 0;
    for var LV := 0 to High(LInner) do
    begin
      while (LStack.Count > 0) and (LTo[LStack.Last] < LV) do
        LStack.Delete(LStack.Count - 1);
      while (LNext <= High(LOrder)) and (LFrom[LOrder[LNext]] <= LV) do
      begin
        if LStack.Count > 0 then
          LOuter[LOrder[LNext]] := LStack.Last;
        if LTo[LOrder[LNext]] >= LV then
          LStack.Add(LOrder[LNext]);
        Inc(LNext);
      end;
      if LStack.Count > 0 then
        LInner[LV] := LStack.Last
      else
        LInner[LV] := -1;
    end;

    // By line of APath: the first and last token on it, the last token on a
    // line above, the first on this line or one below.
    SetLength(LFirst, LCount + 2);
    SetLength(LLast, LCount + 2);
    for var LI := 0 to LCount + 1 do
    begin
      LFirst[LI] := -1;
      LLast[LI] := -1;
    end;
    for var LV := 0 to High(LM.Tree.Source.Visible) do
      if LM.Tree.Source.Visible[LV].FileId = LFileId then
      begin
        LTok := LM.Tree.Source.Visible[LV].TokenIndex;
        LM.Tree.Source.Files[LFileId].OffsetToLineCol(
          LM.Tree.Source.Files[LFileId].Tokens[LTok].Start, LLine, LCol);
        if (LLine >= 1) and (LLine <= LCount) then
        begin
          if LFirst[LLine] < 0 then
            LFirst[LLine] := LV;
          LLast[LLine] := LV;
        end;
      end;
    SetLength(LBefore, LCount + 2);
    LB := -1;
    for var LI := 1 to LCount + 1 do
    begin
      LBefore[LI] := LB;
      if (LI <= LCount) and (LLast[LI] >= 0) then
        LB := LLast[LI];
    end;
    SetLength(LAfter, LCount + 2);
    LB := -1;
    for var LI := LCount + 1 downto 1 do
    begin
      if (LI <= LCount) and (LFirst[LI] >= 0) then
        LB := LFirst[LI];
      LAfter[LI] := LB;
    end;

    // The diff in runs of changed lines between context lines. A run with
    // added code is shown by its added lines; its removed ones would only
    // name what holds the change - the class, for a member edited in it. A
    // run that only removes code is a point between two tokens.
    LB := 0;
    while LB <= High(ALines) do
    begin
      if ALines[LB].Kind = ' ' then
      begin
        Inc(LB);
        Continue;
      end;
      LNext := LB;
      LPlus := False;
      LCode := False;
      while (LNext <= High(ALines)) and (ALines[LNext].Kind <> ' ') do
      begin
        if IsCodeText(ALines[LNext].Text) then
        begin
          LCode := True;
          LPlus := LPlus or (ALines[LNext].Kind = '+');
        end
        else
          AFile.Comments := True;
        Inc(LNext);
      end;
      AFile.Code := AFile.Code or LCode;
      if LPlus then
      begin
        for var LI := LB to LNext - 1 do
          if (ALines[LI].Kind = '+') and IsCodeText(ALines[LI].Text) then
          begin
            LLine := EnsureRange(ALines[LI].Line, 1, LCount + 1);
            if (LLine <= LCount) and (LFirst[LLine] >= 0) then
              TouchLine(LLine)
            else
              Touch(LBefore[LLine], LAfter[LLine], LLine);
          end;
      end
      else if LCode then
        TouchRemoval(LB, LNext - 1);
      LB := LNext;
    end;

    // A type every line of which is added is new: listed alone, what it
    // declares folded into it, implementations included - each member of a
    // new class would otherwise be a root that only the new code calls.
    for var LI := 0 to High(ALines) do
      if ALines[LI].Kind = '+' then
        LAdded.AddOrSetValue(ALines[LI].Line, True);
    for var LS in LDeclsOf.Keys do
    begin
      if (LM.Tree.Nodes[LNodes[LS]].Kind <> nkTypeDecl) or
         (Length(LDeclsOf[LS]) <> 1) or (LDeclsOf[LS][0].Place <> '') or
         not VisPos(LM, LFrom[LS], LFid, LFromLine, LCol) or
         (LFid <> LFileId) or not VisPos(LM, LTo[LS], LFid, LToLine, LCol) or
         (LFid <> LFileId) then
        Continue;
      LPlus := True;
      for var LL := LFromLine to Min(LToLine, LCount) do
        if (LFirst[LL] >= 0) and not LAdded.ContainsKey(LL) then
          LPlus := False;
      if not LPlus then
        Continue;
      for var LX in LDeclsOf.Keys do
        if (LX <> LS) and (LFrom[LX] >= LFrom[LS]) and (LTo[LX] <= LTo[LS]) then
          for var LD in LDeclsOf[LX] do
            if AFile.Decls.Contains(LD) then
            begin
              for var LL in LD.Lines do
                LDeclsOf[LS][0].AddLine(LL);
              AFile.Decls.Remove(LD);
            end;
    end;
  finally
    LAdded.Free;
    LDeclsOf.Free;
    LStack.Free;
    LPlaceName.Free;
    LPlaceTo.Free;
    LPlaceFrom.Free;
    LOuter.Free;
    LTo.Free;
    LFrom.Free;
    LNodes.Free;
  end;
end;

// The routines, properties and types the diff removes from a file: declared
// on a removed line, and on no added one - a changed signature is not a
// removal.
procedure TImpact.NoteRemoved(AFile: TImpactFile;
  const ALines: TArray<TDiffLine>);
var
  LName, LHead, LKey: string;
  LMinus: TDictionary<string, string>;
  LPlus: TDictionary<string, Boolean>;
  LKeys: TStringList;
begin
  LMinus := TDictionary<string, string>.Create;
  LPlus := TDictionary<string, Boolean>.Create;
  LKeys := TStringList.Create;
  try
    for var LD in ALines do
    begin
      if LD.Kind = ' ' then
        Continue;
      LName := DeclaredOnLine(LD.Text, LHead);
      if LName = '' then
        Continue;
      LKey := LowerCase(Copy(LName, LastDelimiter('.', LName) + 1, MaxInt));
      if LD.Kind = '+' then
        LPlus.AddOrSetValue(LKey, True)
      // A method is removed from its class and its implementation: the
      // qualified name is the one kept.
      else if not LMinus.ContainsKey(LKey) or
        (Length(LName) > Pos(' (', LMinus[LKey]) - 1) then
        LMinus.AddOrSetValue(LKey, Format('%s (%s)', [LName, LHead]));
    end;
    for var LPair in LMinus do
      if not LPlus.ContainsKey(LPair.Key) then
        LKeys.Add(LPair.Key);
    LKeys.Sort;
    for LKey in LKeys do
    begin
      AFile.Removed := AFile.Removed + [LMinus[LKey]];
      AFile.RemovedKeys := AFile.RemovedKeys + [LKey];
    end;
  finally
    LKeys.Free;
    LPlus.Free;
    LMinus.Free;
  end;
end;

procedure TImpact.AddDiffFile(const AD: TDiffFile);
var
  LPath, LShown, LExt, LFull, LUnit: string;
  LF: TImpactFile;
  LA, LIncA: TMcpAnalysis;
  LMid, LOwner, LIncMid: Integer;
  LIncluders: TStringList;
  LM: TPasSemaModel;
begin
  LPath := IfThen(AD.NewPath <> '', AD.NewPath, AD.OldPath);
  if LPath = '' then
    Exit;
  LShown := DiffShown(LPath);
  LExt := LowerCase(TPath.GetExtension(LShown));
  if not ((LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') or
     (LExt = '.inc') or (LExt = '.dfm') or (LExt = '.fmx') or
     (LExt = '.dproj')) then
  begin
    if FOther.IndexOf(LShown) < 0 then
      FOther.Add(LShown);
    Exit;
  end;
  if AD.NewPath = '' then
  begin
    LF := FileFor(LShown);
    LF.Note := 'deleted - no longer in the index; a unit still naming it in '
      + '`uses` does not resolve (`status` lists those)';
    NoteRemoved(LF, AD.Lines);
    Exit;
  end;
  LFull := DiffFileOnDisk(FWs, AD.NewPath);
  if LFull = '' then
  begin
    LF := FileFor(LShown);
    LF.Note := 'not found on disk, under the group directory or one above it';
    Exit;
  end;
  LF := FileFor(LFull);
  if LExt = '.dproj' then
  begin
    for var LIdx := 0 to High(FWs.Members) do
      if SameText(FWs.Members[LIdx].ProjectFile, LFull) then
      begin
        LF.Project := LIdx;
        LF.Note := 'the project file of ' + FWs.Members[LIdx].Name;
      end;
    if LF.Project < 0 then
      LF.Note := 'a project file of no member of the group';
    Exit;
  end;
  if (LExt = '.dfm') or (LExt = '.fmx') then
  begin
    LUnit := ChangeFileExt(LFull, '.pas');
    // Built with its unit. Which handlers or components its changed lines
    // bind is not read from the diff: `references` of a name asks the form
    // as it is now.
    LF.Note := 'a form of no analyzed unit';
    for var LCand in FWs.Analyses do
      if LCand.Nav.ModelIdOf(LUnit) >= 0 then
      begin
        LF.Units := [LUnit];
        LF.Note := 'the form of ' + FWs.RelPath(LUnit);
        Break;
      end;
    Exit;
  end;
  NoteRemoved(LF, AD.Lines);
  // Its own model - the owner analysis' - else the units including it.
  LA := nil;
  LMid := -1;
  LOwner := FWs.OwnerAnalysis(LFull);
  if LOwner >= 0 then
  begin
    LA := FWs.Analyses[LOwner];
    LMid := LA.Nav.ModelIdOf(LFull);
  end;
  if LMid < 0 then
    for var LCand in FWs.Analyses do
    begin
      LMid := LCand.Nav.ModelIdOf(LFull);
      if LMid >= 0 then
      begin
        LA := LCand;
        Break;
      end;
    end;
  if LMid >= 0 then
  begin
    LF.Units := [LFull];
    MapLines(LF, LA, LMid, LFull, AD.Lines);
    Exit;
  end;
  LIncluders := TStringList.Create;
  try
    LIncA := nil;
    LIncMid := -1;
    for var LCand in FWs.Analyses do
      for var LI := 0 to LCand.Proj.ModelCount - 1 do
      begin
        if not FWs.IsOwnFile(LCand.Proj.ModelFile(LI)) then
          Continue;
        LM := LCand.Proj.Model(LI);
        if FileIdOf(LM, LFull) <= 0 then
          Continue;
        if LIncluders.IndexOf(LCand.Proj.ModelFile(LI)) < 0 then
          LIncluders.Add(LCand.Proj.ModelFile(LI));
        if LIncA = nil then
        begin
          LIncA := LCand;
          LIncMid := LI;
        end;
      end;
    if LIncA = nil then
    begin
      LF.Note := 'not in any analyzed project - nothing reachable uses or '
        + 'includes it';
      Exit;
    end;
    LF.Units := LIncluders.ToStringArray;
    LF.Note := Format('included by %s', [Plural(LIncluders.Count, 'unit')]);
    MapLines(LF, LIncA, LIncMid, LFull, AD.Lines);
  finally
    LIncluders.Free;
  end;
end;

procedure TImpact.AddDiff(const AText: string);
var
  LFiles: TArray<TDiffFile>;
begin
  LFiles := ParseDiff(AText);
  if Length(LFiles) = 0 then
    raise EToolError.Create('no file in `diff` - pass the output of `git diff` '
      + 'as it is: `--- a/<path>` and `+++ b/<path>` lines, then `@@` hunks');
  FDiffFiles := Length(LFiles);
  for var LD in LFiles do
    AddDiffFile(LD);
end;

procedure TImpact.AddTarget(const AT: TTarget);
var
  LF: TImpactFile;
  LA: TMcpAnalysis;
  LUnit: string;
begin
  case AT.Kind of
    tkUnit:
      begin
        LF := FileFor(AT.DeclFile);
        LF.Units := [AT.DeclFile];
        LF.UsedBy := True;
      end;
    tkSymbol:
      begin
        if SameText(TPath.GetExtension(AT.DeclFile), '.dcu') then
          raise EToolError.CreateFmt('%s is declared in a compiled unit without '
            + 'source (%s) - no project of the group changes it', [AT.Name,
            FWs.RelPath(AT.DeclFile)]);
        LF := FileFor(AT.DeclFile);
        // The unit it is in: its model's file - an include's includer.
        LA := ReportingAnalysis(FWs, AT);
        if LA <> nil then
        begin
          LUnit := LA.Proj.ModelFile(AT.Ids[LA.Index].Mid);
          if IndexText(LUnit, LF.Units) < 0 then
            LF.Units := LF.Units + [LUnit];
        end;
        AddDecl(LF, AT).AddLine(AT.DeclLine);
      end;
  else
    raise EToolError.CreateFmt('%s is a %s - `impact` takes a declaration, a '
      + 'unit or a diff', [AT.Name, AT.Head]);
  end;
  if FNamed.IndexOf(AT.Name) < 0 then
    FNamed.Add(AT.Name);
end;

function TImpact.Empty: Boolean;
begin
  Result := (FFiles.Count = 0) and (FOther.Count = 0);
end;

function TImpact.Names(const AMembers: TArray<Integer>): string;
begin
  Result := '';
  for var LIdx in AMembers do
    Result := Result + IfThen(Result <> '', ', ', '') + FWs.Members[LIdx].Name;
end;

// 'used by 3 units: AppB, uAppA, uAppB' - the units whose `uses` name it,
// merged over the analyses, by name - AMax of them at most; past that a
// count: a core unit's 200 importers are a recompile, not a reading list.
function TImpact.UsedByText(AFile: TImpactFile; AMax: Integer): string;
var
  LNames: TStringList;
  LMid: Integer;
  LUnit: string;
begin
  LNames := TStringList.Create;
  try
    LNames.CaseSensitive := False;
    for var LFile in AFile.Units do
      for var LA in FWs.Analyses do
      begin
        LMid := LA.Nav.ModelIdOf(LFile);
        if LMid < 0 then
          Continue;
        for var LH in LA.Nav.FindUnitReferences(LMid) do
        begin
          LUnit := UnitNameOfFile(LH.FilePath);
          if LNames.IndexOf(LUnit) < 0 then
            LNames.Add(LUnit);
        end;
      end;
    LNames.Sort;
    if LNames.Count = 0 then
      Result := 'used by no unit'
    else if LNames.Count > AMax then
      Result := 'used by ' + Plural(LNames.Count, 'unit')
    else
      Result := Format('used by %s: %s', [Plural(LNames.Count, 'unit'),
        String.Join(', ', LNames.ToStringArray)]);
  finally
    LNames.Free;
  end;
end;

{ The form lines still binding a removed method to an event - `OnClick =
  btnSaveClick` after btnSaveClick is gone. The compiler says nothing: the
  form fails when it loads (EReadError, "Invalid property value"), and no
  diagnostic of the index names it either. The symbol is gone, so the binder
  cannot be asked; the lines are read the way TReader binds them: in the
  form file of the method's class and of each class descending from it, an
  event property whose value is the name - unless that class still finds a
  member by the name (an ancestor's, a redeclaration), which the line then
  binds. The class is the removed name's qualifier, else the unit's form's. }
function TImpact.FormLeftovers(AFile: TImpactFile; AIdx: Integer): TArray<THit>;
var
  LA: TMcpAnalysis;
  LM: TPasSemaModel;
  LMid, LOwner, LClassSym, LFMid, LFSym, LCtx, LAt: Integer;
  LName, LKey, LClass, LForm: string;
  LCands: TList<TSymId>;
  LDone: TDictionary<string, Boolean>;
  LId: TSymId;
  LHandle: IPasDfmDoc;
  LDoc: TPasDfmDoc;
  LIdent: TPasDfmIdent;
  LSite: TPasFormSite;
  LH: THit;
  LList: TList<THit>;
begin
  Result := nil;
  LName := AFile.Removed[AIdx];
  if not (LName.EndsWith(' (procedure)') or LName.EndsWith(' (function)')) then
    Exit;
  LName := Copy(LName, 1, Pos(' (', LName) - 1);
  LKey := AFile.RemovedKeys[AIdx];
  LOwner := FWs.OwnerAnalysis(AFile.Path);
  if LOwner < 0 then
    Exit;
  LA := FWs.Analyses[LOwner];
  LMid := LA.Nav.ModelIdOf(AFile.Path);
  if (LMid < 0) or not LA.Proj.EnsureHydrated(LMid) then
    Exit;
  LM := LA.Proj.Model(LMid);
  // `TOuter.TFoo.Bar`: TFoo; a bare `Bar` (the declaration's line alone): the
  // class of the unit's form.
  LAt := LastDelimiter('.', LName);
  if LAt > 0 then
  begin
    LClass := Copy(LName, 1, LAt - 1);
    LClass := Copy(LClass, LastDelimiter('.', LClass) + 1, MaxInt);
  end
  else
  begin
    LHandle := PasDfmLoad(PasDfmFileOfUnit(AFile.Path));
    if LHandle = nil then
      Exit;
    LClass := LHandle.Doc.RootClassName;
  end;
  LClassSym := NIL_SYM;
  for var LSym := 0 to LM.SymCount - 1 do
    if (LM.Symbols[LSym].Kind = skType) and
       (LM.Symbols[LSym].TypeCat = tcClass) and
       SameText(LM.Symbols[LSym].Name, LClass) then
    begin
      LClassSym := LSym;
      Break;
    end;
  if LClassSym = NIL_SYM then
    Exit;
  LCands := TList<TSymId>.Create;
  LDone := TDictionary<string, Boolean>.Create;
  LList := TList<THit>.Create;
  try
    LId.Mid := LMid;
    LId.Sym := LClassSym;
    LCands.Add(LId);
    for var LD in LA.Nav.FindDescendants(LMid, LClassSym) do
      if LD.Kind = pdkDescendant then
      begin
        LId.Mid := LD.UnitId;
        LId.Sym := LD.Sym;
        LCands.Add(LId);
      end;
    for var LC in LCands do
    begin
      LForm := PasDfmFileOfUnit(LA.Proj.ModelFile(LC.Mid));
      if (LForm = '') or not LDone.TryAdd(LowerCase(LForm), True) then
        Continue;
      LHandle := PasDfmLoad(LForm);
      if LHandle = nil then
        Continue;
      LDoc := LHandle.Doc;
      // The form of this class - a unit may hold others - and one that no
      // longer finds a member by the name.
      if not SameText(LDoc.RootClassName,
         LA.Proj.Model(LC.Mid).Symbols[LC.Sym].Name) or
         LA.Proj.FindMemberX(LC.Mid, XPlain(LC.Mid, LC.Sym), LKey, LFMid,
         LFSym, LCtx) then
        Continue;
      for var LIdx in LDoc.FindIdents(LKey) do
      begin
        LIdent := LDoc.Idents[LIdx];
        if (LIdent.Role <> dirValue) or (LIdent.SegCount <> 1) or
           (LIdent.Prop < 0) or not StartsText('On', LDoc.PropPath(LIdent.Prop))
        then
          Continue;
        LSite := Default(TPasFormSite);
        LSite.FilePath := LForm;
        LSite.ObjIndex := LIdent.Obj;
        LSite.PropName := LDoc.PropPath(LIdent.Prop);
        LH := Default(THit);
        LH.FilePath := LForm;
        LH.Line := LDoc.LineOf(LIdent.Offset);
        LH.Col := LDoc.ColOf(LIdent.Offset);
        LH.Where := FormObjectPath(LSite);
        if LH.Where = '' then
          LH.Where := LDoc.RootName;
        LH.Where := LH.Where.Replace(' (root)', '') + '.' + LSite.PropName;
        LList.Add(LH);
      end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
    LDone.Free;
    LCands.Free;
  end;
end;

// Own-unit diagnostics naming a removed routine or type in quotes - calls
// and uses of it that no longer resolve - by its lower-case last segment.
// Each unit reports from its owner analysis, as `diagnostics` does.
function TImpact.Leftovers: TObjectDictionary<string, TList<THit>>;
var
  LKeys: TStringList;
  LM: TPasSemaModel;
  LOwner: Integer;
  LMsg, LFile: string;
  LList: TList<THit>;
  LH: THit;
begin
  Result := TObjectDictionary<string, TList<THit>>.Create([doOwnsValues]);
  LKeys := TStringList.Create;
  try
    for var LF in FFiles do
      for var LKey in LF.RemovedKeys do
        if LKeys.IndexOf(LKey) < 0 then
          LKeys.Add(LKey);
    if LKeys.Count = 0 then
      Exit;
    for var LA in FWs.Analyses do
      for var LMid := 0 to LA.Proj.ModelCount - 1 do
      begin
        if not FWs.IsOwnFile(LA.Proj.ModelFile(LMid)) then
          Continue;
        LOwner := FWs.OwnerAnalysis(LA.Proj.ModelFile(LMid));
        if (LOwner >= 0) and (LOwner <> LA.Index) then
          Continue;
        LM := LA.Proj.Model(LMid);
        for var LD in LM.Diags do
        begin
          LMsg := LowerCase(LD.Msg);
          for var LKey in LKeys do
            if Pos('''' + LKey + '''', LMsg) > 0 then
            begin
              if (LD.FileId >= 0) and
                 (LD.FileId <= High(LM.Tree.Source.FileNames)) then
                LFile := LM.Tree.Source.FileNames[LD.FileId]
              else
                LFile := LA.Proj.ModelFile(LMid);
              if not Result.TryGetValue(LKey, LList) then
              begin
                LList := TList<THit>.Create;
                Result.Add(LKey, LList);
              end;
              LH := Default(THit);
              LH.FilePath := LFile;
              LH.Line := LD.Line;
              LH.Col := LD.Col;
              LList.Add(LH);
            end;
        end;
      end;
  finally
    LKeys.Free;
  end;
end;

// The methods implementing an interface method, as `related implementations`
// finds them: 'TShape (Shared\uShapes.pas:17)'.
function TImpact.ImplementedIn(const AT: TTarget): TArray<string>;
var
  LDm, LTMid, LTSym: Integer;
  LName, LText: string;
begin
  Result := nil;
  for var LA in FWs.Analyses do
  begin
    if (AT.Ids[LA.Index].Mid < 0) or not IsInterfaceMethodSym(LA,
       AT.Ids[LA.Index].Mid, AT.Ids[LA.Index].Sym) then
      Continue;
    LDm := LA.Nav.ModelIdOf(AT.DeclFile);
    if (LDm < 0) or not LA.Proj.EnsureHydrated(LDm) or
       not LA.Nav.InterfaceMethodAt(LDm, AT.DeclLine, AT.DeclCol, LTMid, LTSym,
       LName) then
      Continue;
    for var LH in LA.Nav.FindImplementations(LTMid, LTSym) do
    begin
      if LH.Kind = pikRoot then
        Continue;
      LText := Format('%s (%s:%d)', [LH.TypeName, FWs.RelPath(LH.Hit.FilePath),
        LH.Hit.Line]);
      if IndexStr(LText, Result) < 0 then
        Result := Result + [LText];
    end;
  end;
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

function TImpact.Answer(ADepth, ALimit: Integer): string;
const
  MAX_FAMILY = 10;
  MAX_LEFTOVERS = 5;
var
  LSb, LLevels: TStringBuilder;
  LWalk: TCallerWalk;
  LInfo: TCallWalkInfo;
  LFiles: TArray<TImpactFile>;
  LDecls: TArray<TImpactDecl>;
  LReached, LNot: TArray<Integer>;
  LHave: TArray<Boolean>;
  LLeft: TObjectDictionary<string, TList<THit>>;
  LList: TList<THit>;
  LBound: TArray<THit>;
  LRoutines, LData, LShown, LHidden, LCount: Integer;
  LLine, LText, LTag: string;
  LParts, LSkipped: TStringList;
  LFamily: TArray<string>;
  LSW: TStopwatch;
  LMembersMs, LWalkMs: Int64;
begin
  LSW := TStopwatch.StartNew;
  LFiles := FFiles.ToArray;
  TArray.Sort<TImpactFile>(LFiles, TComparer<TImpactFile>.Construct(
    function(const L, R: TImpactFile): Integer
    begin
      Result := Ord(FWs.IsOwnFile(R.Path)) - Ord(FWs.IsOwnFile(L.Path));
      if Result = 0 then
        Result := CompareText(L.Path, R.Path);
    end));

  // The members each file is compiled into, and all of them together.
  SetLength(LHave, Length(FWs.Members));
  for var LF in LFiles do
  begin
    for var LUnit in LF.Units do
      for var LIdx in FReach.MembersOf(LUnit) do
        if not HasInt(LF.Members, LIdx) then
          LF.Members := LF.Members + [LIdx];
    if (LF.Project >= 0) and not HasInt(LF.Members, LF.Project) then
      LF.Members := LF.Members + [LF.Project];
    TArray.Sort<Integer>(LF.Members);
    for var LIdx in LF.Members do
      LHave[LIdx] := True;
  end;
  for var LIdx := 0 to High(FWs.Members) do
    if FWs.Members[LIdx].Analysis >= 0 then
    begin
      if LHave[LIdx] then
        LReached := LReached + [LIdx]
      else
        LNot := LNot + [LIdx];
    end;
  LMembersMs := LSW.ElapsedMilliseconds;

  LSb := TStringBuilder.Create;
  LLevels := TStringBuilder.Create;
  LWalk := TCallerWalk.Create(FWs);
  LParts := TStringList.Create;
  LSkipped := TStringList.Create;
  LLeft := Leftovers;
  try
    // The roots, file by file, each file's declarations by line.
    LWalk.ViaOnRows := True;
    LRoutines := 0;
    LData := 0;
    for var LF in LFiles do
    begin
      LDecls := LF.Decls.ToArray;
      TArray.Sort<TImpactDecl>(LDecls, TComparer<TImpactDecl>.Construct(
        function(const L, R: TImpactDecl): Integer
        begin
          Result := L.FirstLine - R.FirstLine;
        end));
      LF.Decls.Clear;
      LF.Decls.AddRange(LDecls);
      for var LD in LDecls do
      begin
        if LD.Place <> '' then
          Continue;
        if LRoutines + LData >= MAX_IMPACT_ROOTS then
        begin
          LSkipped.Add(LD.T.Name);
          Continue;
        end;
        LD.Node := LWalk.AddRoot(LD.T, not IsRoutineHead(LD.T.Head));
        if IsRoutineHead(LD.T.Head) then
          Inc(LRoutines)
        else
          Inc(LData);
      end;
    end;
    if LRoutines + LData > 0 then
      LWalk.Walk(ADepth, ALimit, LLevels, LInfo);
    LWalkMs := LSW.ElapsedMilliseconds - LMembersMs;

    LCount := 0;
    for var LF in LFiles do
      for var LD in LF.Decls do
        if LD.Place = '' then
          Inc(LCount);
    if FDiffFiles >= 0 then
      LSb.AppendLine(Format('impact of the diff - %s, %s', [Plural(FDiffFiles,
        'file'), IfThen(LCount = 0, 'no declaration changed',
        Plural(LCount, 'declaration') + ' changed')]))
    else
      LSb.AppendLine('impact of ' + String.Join(', ', FNamed.ToStringArray));
    if Length(LReached) = 0 then
      LSb.AppendLine('members to build and test: none - no member compiles '
        + 'the changed files')
    else if Length(LNot) = 0 then
      LSb.AppendLine(Format('members to build and test: %s (all %d)',
        [Names(LReached), Length(LReached)]))
    else
      LSb.AppendLine(Format('members to build and test: %s (not reached: %s)',
        [Names(LReached), Names(LNot)]));

    LShown := 0;
    for var LF in LFiles do
    begin
      LLine := IfThen(TPath.IsPathRooted(LF.Path), FWs.RelPath(LF.Path),
        LF.Path);
      // A file compiled into fewer members than the list above names them.
      if ((Length(LF.Units) > 0) or (LF.Project >= 0)) and
         (Names(LF.Members) <> Names(LReached)) then
        LLine := LLine + '  [' + IfThen(Length(LF.Members) = 0, 'no member',
          Names(LF.Members)) + ']';
      LParts.Clear;
      if LF.Note <> '' then
        LParts.Add(LF.Note);
      if LF.Iface then
        LParts.Add('interface changed, ' + UsedByText(LF, 8))
      else if LF.UsedBy then
        LParts.Add(UsedByText(LF, 30));
      if LParts.Count > 0 then
        LLine := LLine + ' - ' + String.Join('; ', LParts.ToStringArray)
      else if (LF.Decls.Count = 0) and (Length(LF.Removed) = 0) then
      begin
        if LF.Code then
          LLine := LLine + ' (no declaration: lines outside every one)'
        else if LF.Comments then
          LLine := LLine + ' (comments only)';
      end;
      LSb.AppendLine(LLine);
      LHidden := 0;
      for var LD in LF.Decls do
      begin
        Inc(LShown);
        if LShown > MAX_IMPACT_DECLS then
        begin
          Inc(LHidden);
          Continue;
        end;
        LLine := '  ' + LinesText(LD.Lines) + '  ';
        if LD.Place <> '' then
        begin
          LSb.AppendLine(LLine + LD.Place);
          Continue;
        end;
        LLine := LLine + Format('%s (%s)', [LD.T.Name, LD.T.Head]);
        LParts.Clear;
        if LD.Node >= 0 then
        begin
          // The virtual chain by its nearest link - what a changed signature
          // must still match; the rows name the others they are bound to.
          LText := '';
          LTag := '';
          for var LSource in LWalk.Through(LD.Node) do
            if LSource.EndsWith(' (virtual)') then
            begin
              if LText = '' then
                LText := 'overrides ' + Copy(LSource, 1, Length(LSource) -
                  Length(' (virtual)'));
            end
            else
              LTag := LTag + IfThen(LTag <> '', ', ', '') + LSource;
          if LText <> '' then
            LParts.Add(LText);
          if LTag <> '' then
            LParts.Add('also through ' + LTag);
          LFamily := LWalk.Below(LD.Node);
          if Length(LFamily) > 0 then
            LParts.Add('overridden in ' + String.Join(', ', Copy(LFamily, 0,
              MAX_FAMILY)) + IfThen(Length(LFamily) > MAX_FAMILY,
              Format(' and %d more (`related overrides`)', [Length(LFamily) -
              MAX_FAMILY]), ''));
          LFamily := ImplementedIn(LD.T);
          if Length(LFamily) > 0 then
            LParts.Add('implemented in ' + String.Join(', ', Copy(LFamily, 0,
              MAX_FAMILY)) + IfThen(Length(LFamily) > MAX_FAMILY,
              Format(' and %d more (`related implementations`)',
              [Length(LFamily) - MAX_FAMILY]), ''));
        end;
        if LParts.Count > 0 then
          LLine := LLine + ' - ' + String.Join('; ', LParts.ToStringArray);
        LSb.AppendLine(LLine);
      end;
      if LHidden > 0 then
        LSb.AppendLine(Format('  ... %d more changed declarations', [LHidden]));
      for var LR := 0 to High(LF.Removed) do
      begin
        LLine := '  removed: ' + LF.Removed[LR];
        LBound := FormLeftovers(LF, LR);
        LText := '';
        for var LI := 0 to Min(Length(LBound), MAX_LEFTOVERS) - 1 do
          LText := LText + IfThen(LText <> '', ', ', '') + Format('%s:%d (%s)',
            [FWs.RelPath(LBound[LI].FilePath), LBound[LI].Line,
            LBound[LI].Where]);
        if Length(LBound) > MAX_LEFTOVERS then
          LText := LText + Format(' and %d more', [Length(LBound) -
            MAX_LEFTOVERS]);
        if LText <> '' then
          LLine := LLine + ' - still bound in a form, which then fails to '
            + 'load: ' + LText;
        if LLeft.TryGetValue(LF.RemovedKeys[LR], LList) then
        begin
          LText := '';
          for var LI := 0 to Min(LList.Count, MAX_LEFTOVERS) - 1 do
          begin
            LTag := FEnclosing.NameAt(LList[LI].FilePath, LList[LI].Line,
              LList[LI].Col, False);
            LText := LText + IfThen(LText <> '', ', ', '') + Format('%s:%d%s',
              [FWs.RelPath(LList[LI].FilePath), LList[LI].Line,
              IfThen(LTag <> '', ' (in ' + LTag + ')', '')]);
          end;
          if LList.Count > MAX_LEFTOVERS then
            LText := LText + Format(' and %d more (`diagnostics`)',
              [LList.Count - MAX_LEFTOVERS]);
          LLine := LLine + ' - still named at ' + LText;
        end
        else if Length(LBound) = 0 then
          LLine := LLine + ' - nothing unresolved names it';
        LSb.AppendLine(LLine);
      end;
    end;
    if FOther.Count > 0 then
      LSb.AppendLine('other files, not Pascal source: ' + String.Join(', ',
        FOther.ToStringArray));

    if LRoutines + LData > 0 then
    begin
      if LData = 0 then
        LText := 'callers'
      else if LRoutines = 0 then
        LText := 'uses'
      else
        LText := 'callers and uses';
      if LInfo.Levels[0].Calls = 0 then
        LSb.AppendLine(LText + ' - ' + NoCallsSummary(LInfo.Levels[0],
          LRoutines + LData > 1, LData > 0))
      else
        LSb.AppendLine(LText + ' - ' + LevelsSummary(LInfo, IfThen(LData = 0,
          'call', ''), LRoutines + LData > 1));
      LSb.Append(LLevels.ToString);
      LWalk.AppendNotes(LSb, LInfo, ADepth);
    end;
    if LSkipped.Count > 0 then
      LSb.AppendLine(Format('(not searched for callers - past the first %d: '
        + '%s; ask `impact` or `callers` for them)', [MAX_IMPACT_ROOTS,
        String.Join(', ', LSkipped.ToStringArray)]));
    for var LM in FWs.Members do
      if LM.Analysis < 0 then
        LSb.AppendLine(Format('(member %s was not analyzed, not judged: %s)',
          [LM.Name, LM.Error]));
    Result := LSb.ToString.TrimRight;
    Log('impact: %d files, %d roots (%d routines); members %d ms, walk %d ms, '
      + 'the rest %d ms', [Length(LFiles), LRoutines + LData, LRoutines,
      LMembersMs, LWalkMs, LSW.ElapsedMilliseconds - LMembersMs - LWalkMs]);
  finally
    LLeft.Free;
    LSkipped.Free;
    LParts.Free;
    LWalk.Free;
    LLevels.Free;
    LSb.Free;
  end;
end;

{ What a change reaches (SPEC 9.3.3), from a unified diff - the agent passes
  `git diff` output; the server runs no git - or from the declarations
  named: `impact` is callers, overrides and unit_deps in one answer, and the
  one thing none of them says - which members of the group to build and
  test. }
function ToolImpact(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LImpact: TImpact;
  LDiff: string;
  LV: TJSONValue;
  LSW: TStopwatch;
begin
  LDiff := '';
  LV := nil;
  if AArgs <> nil then
  begin
    // Not trimmed: a hunk's last context line may be a lone space.
    LV := AArgs.GetValue('diff');
    if (LV <> nil) and not (LV is TJSONNull) then
      LDiff := LV.Value;
    LV := AArgs.GetValue('symbols');
  end;
  LImpact := TImpact.Create(AWs);
  try
    LSW := TStopwatch.StartNew;
    if Trim(LDiff) <> '' then
    begin
      LImpact.AddDiff(LDiff);
      Log('impact: the diff read in %d ms', [LSW.ElapsedMilliseconds]);
    end;
    if (ArgStr(AArgs, 'file') <> '') or (ArgStr(AArgs, 'symbol') <> '') then
      LImpact.AddTarget(ResolveOne(AWs, AArgs));
    if LV is TJSONArray then
    begin
      for var LItem in TJSONArray(LV) do
        if Trim(LItem.Value) <> '' then
          LImpact.AddTarget(ResolveNamed(AWs, Trim(LItem.Value),
            ArgStr(AArgs, 'kind')));
    end
    else if (LV <> nil) and not (LV is TJSONNull) then
      // A list written as one string: "TFoo.Bar, Baz".
      for var LName in LV.Value.Split([',', ';'], TStringSplitOptions.ExcludeEmpty) do
        if Trim(LName) <> '' then
          LImpact.AddTarget(ResolveNamed(AWs, Trim(LName),
            ArgStr(AArgs, 'kind')));
    if LImpact.Empty then
      raise EToolError.Create('give `diff` (the output of `git diff`) or the '
        + 'declarations you will change: `symbol`, `symbols`, or `file` + '
        + '`line` + `name`');
    Result := LImpact.Answer(EnsureRange(ArgInt(AArgs, 'depth', 1), 1, 4),
      EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000));
  finally
    LImpact.Free;
  end;
end;

{ ---- compile ------------------------------------------------------------------ }

function HasTrue(const AFlags: TArray<Boolean>): Boolean;
begin
  for var LFlag in AFlags do
    if LFlag then
      Exit(True);
  Result := False;
end;

// The members compiling AFile: a unit, a program, or an include file through
// the own units that include it.
function ReachingMembers(AWs: TMcpWorkspace; AReach: TMemberReach;
  const AFile: string): TArray<Integer>;
begin
  Result := AReach.MembersOf(AFile);
  if Length(Result) > 0 then
    Exit;
  for var LA in AWs.Analyses do
    for var LMid := 0 to LA.Proj.ModelCount - 1 do
      if AWs.IsOwnFile(LA.Proj.ModelFile(LMid)) and
        (FileIdOf(LA.Proj.Model(LMid), AFile) > 0) then
        for var LIdx in AReach.MembersOf(LA.Proj.ModelFile(LMid)) do
          if not HasInt(Result, LIdx) then
            Result := Result + [LIdx];
end;

// The members `compile` builds (SPEC 9.4): those named, those compiling
// `file`, else those the files changed this session reach. AWhy says which
// rule chose them, for the answer.
function CompileMembers(AWs: TMcpWorkspace; AArgs: TJSONObject;
  out AWhy: string): TArray<Integer>;
var
  LNames, LChanged, LShown: TArray<string>;
  LV: TJSONValue;
  LFound: Integer;
  LReach: TMemberReach;
  LFile, LAll: string;
  LIn: TArray<Boolean>;
begin
  Result := nil;
  AWhy := '';
  SetLength(LIn, Length(AWs.Members));
  LAll := '';
  for var LM in AWs.Members do
    LAll := LAll + IfThen(LAll <> '', ', ', '') + LM.Name;
  LNames := ArgStr(AArgs, 'member').Split([',', ';', ' '],
    TStringSplitOptions.ExcludeEmpty);
  if AArgs <> nil then
  begin
    LV := AArgs.GetValue('members');
    if LV is TJSONArray then
    begin
      for var LItem in TJSONArray(LV) do
        if Trim(LItem.Value) <> '' then
          LNames := LNames + [Trim(LItem.Value)];
    end
    else if (LV <> nil) and not (LV is TJSONNull) then
      LNames := LNames + LV.Value.Split([',', ';', ' '],
        TStringSplitOptions.ExcludeEmpty);
  end;
  if Length(LNames) > 0 then
    for var LName in LNames do
    begin
      LFound := -1;
      for var LIdx := 0 to High(AWs.Members) do
        if SameText(AWs.Members[LIdx].Name, Trim(LName)) then
          LFound := LIdx;
      if LFound < 0 then
        raise EToolError.CreateFmt('no member named %s - the group has: %s',
          [Trim(LName), LAll]);
      LIn[LFound] := True;
    end
  else
  begin
    LReach := TMemberReach.Create(AWs);
    try
      if ArgStr(AArgs, 'file') <> '' then
      begin
        LFile := ArgFile(AWs, AArgs);
        for var LIdx in ReachingMembers(AWs, LReach, LFile) do
          LIn[LIdx] := True;
        AWhy := 'those compiling ' + AWs.RelPath(LFile);
        if not HasTrue(LIn) then
          raise EToolError.CreateFmt('no member of the group compiles %s',
            [AWs.RelPath(LFile)]);
      end
      else
      begin
        LChanged := AWs.ChangedFiles;
        if Length(LChanged) = 0 then
        begin
          if Length(AWs.Members) <> 1 then
            raise EToolError.CreateFmt('no file has changed since the server '
              + 'started - name the `member` to build (the group has: %s), or a '
              + '`file`', [LAll]);
          LIn[0] := True;
        end
        else
        begin
          for var LOne in LChanged do
            for var LIdx in ReachingMembers(AWs, LReach, LOne) do
              LIn[LIdx] := True;
          AWhy := 'those compiling the ' + Plural(Length(LChanged), 'file') +
            ' changed this session';
          if not HasTrue(LIn) then
          begin
            LShown := nil;
            for var LOne in LChanged do
              if Length(LShown) < 3 then
                LShown := LShown + [AWs.RelPath(LOne)];
            raise EToolError.CreateFmt('no member of the group compiles the '
              + 'files changed this session (%s) - name the `member` to build '
              + '(the group has: %s)', [String.Join(', ', LShown), LAll]);
          end;
        end;
      end;
    finally
      LReach.Free;
    end;
  end;
  for var LIdx := 0 to High(LIn) do
    if LIn[LIdx] then
      Result := Result + [LIdx];
end;

// The first 'quoted' name of a compiler message: E2003 Undeclared
// identifier: 'Foo'; F2063 Could not compile used unit 'uFoo.pas'.
function QuotedName(const AText: string): string;
var
  LFrom, LTo: Integer;
begin
  Result := '';
  LFrom := Pos('''', AText);
  if LFrom = 0 then
    Exit;
  LTo := Pos('''', AText, LFrom + 1);
  if LTo > LFrom then
    Result := Copy(AText, LFrom + 1, LTo - LFrom - 1);
end;

// dcc cut the "file(line)" of a message at 128 characters: the file is the
// own or library unit whose path starts so, when exactly one does; the line,
// the one line of it that writes the name the message quotes, when exactly
// one does. Otherwise the line stays unknown.
procedure ResolveTruncated(AWs: TMcpWorkspace; var AResult: TBuildResult);
var
  LCands: TDictionary<string, string>;
  LFile, LName: string;
  LLines: TArray<string>;
  LAt: Integer;
begin
  for var LI := 0 to High(AResult.Messages) do
  begin
    if not AResult.Messages[LI].Truncated then
      Continue;
    if not TFile.Exists(AResult.Messages[LI].FileName) then
    begin
      LCands := TDictionary<string, string>.Create;
      try
        for var LA in AWs.Analyses do
          for var LMid := 0 to LA.Proj.ModelCount - 1 do
          begin
            LFile := LA.Proj.ModelFile(LMid);
            if StartsText(AResult.Messages[LI].FileName, LFile) then
              LCands.AddOrSetValue(LowerCase(LFile), LFile);
          end;
        if LCands.Count <> 1 then
          Continue;
        for var LOne in LCands.Values do
          AResult.Messages[LI].FileName := LOne;
      finally
        LCands.Free;
      end;
    end;
    LName := QuotedName(AResult.Messages[LI].Text);
    if (LName = '') or not IsValidIdent(LName, True) then
      Continue;
    LLines := ReadLines(AResult.Messages[LI].FileName);
    LAt := 0;
    for var LN := 0 to High(LLines) do
      if FindWord(LLines[LN], LName) > 0 then
      begin
        if LAt <> 0 then
        begin
          LAt := -1;
          Break;
        end;
        LAt := LN + 1;
      end;
    if LAt > 0 then
      AResult.Messages[LI].Line := LAt;
  end;
end;

function MemberProgress(const ABase: TProc<string>;
  AIndex, ACount: Integer): TProc<string>;
var
  LProgress: TProc<string>;
begin
  LProgress := ABase;
  if not Assigned(LProgress) then
    Exit(nil);
  Result :=
    procedure(AText: string)
    begin
      if ACount > 1 then
        LProgress(Format('compile %d/%d: %s', [AIndex + 1, ACount, AText]))
      else
        LProgress('compile: ' + AText);
    end;
end;

type
  // A message as the answer lists it: merged over the members built, which
  // compile a shared unit each and report its warnings each.
  TCompileRow = record
    Msg: TBuildMsg;
    Members: TArray<string>;
    Own: Boolean;
  end;

function Seconds(AMs: Int64): string;
begin
  Result := FormatFloat('0.0', AMs / 1000, TFormatSettings.Invariant) + ' s';
end;

function CompileAnswer(AWs: TMcpWorkspace; const AResults: TArray<TBuildResult>;
  const AWhy, AShow: string; ALimit: Integer): string;
var
  LSb: TStringBuilder;
  LGone: TList<TCompileRow>;
  LIndex: TDictionary<string, Integer>;
  LEnclosing: TEnclosing;
  LLines: TDictionary<string, TArray<string>>;
  LMulti, LFirstOnly: Boolean;
  LBudget, LBuilt, LNewW, LNewH, LOwnW, LOwnH, LLibW, LLibH, LListed: Integer;
  LErrFiles: TDictionary<string, Boolean>;
  LFolded, LMissing: TArray<string>;
  LErrors, LSetup, LWarn, LHint, LSetupWarn: TList<TCompileRow>;
  LNotFound: Boolean;
  LName: string;

  procedure Merge(AList: TList<TCompileRow>; const AMsg: TBuildMsg;
    const AMember: string; AKeyed: Boolean);
  var
    LKey: string;
    LAt: Integer;
    LRow: TCompileRow;
  begin
    LKey := IntToStr(Ord(AMsg.Kind)) + '|' + LowerCase(AMsg.FileName) + '|' +
      IntToStr(AMsg.Line) + '|' + IntToStr(AMsg.Col) + '|' + AMsg.Code + '|' +
      AMsg.Text;
    if AKeyed and LIndex.TryGetValue(LKey, LAt) then
    begin
      LRow := AList[LAt];
      if IndexText(AMember, LRow.Members) < 0 then
        LRow.Members := LRow.Members + [AMember];
      LRow.Msg.IsNew := LRow.Msg.IsNew or AMsg.IsNew;
      AList[LAt] := LRow;
      Exit;
    end;
    LRow := Default(TCompileRow);
    LRow.Msg := AMsg;
    LRow.Members := [AMember];
    LRow.Own := AWs.IsOwnFile(AMsg.FileName);
    AList.Add(LRow);
    if AKeyed then
      LIndex.Add(LKey, AList.Count - 1);
  end;

  function Sorted(AList: TList<TCompileRow>): TArray<TCompileRow>;
  begin
    Result := AList.ToArray;
    TArray.Sort<TCompileRow>(Result, TComparer<TCompileRow>.Construct(
      function(const L, R: TCompileRow): Integer
      begin
        Result := Ord(R.Own) - Ord(L.Own);
        if Result = 0 then
          Result := CompareText(L.Msg.FileName, R.Msg.FileName);
        if Result = 0 then
          Result := L.Msg.Line - R.Msg.Line;
      end));
  end;

  function SourceLine(const AFile: string; ALine: Integer): string;
  var
    LText: TArray<string>;
  begin
    Result := '';
    if ALine <= 0 then
      Exit;
    if not LLines.TryGetValue(LowerCase(AFile), LText) then
    begin
      LText := ReadLines(AFile);
      LLines.Add(LowerCase(AFile), LText);
    end;
    if ALine <= Length(LText) then
      Result := CleanLine(LText[ALine - 1]);
  end;

  // Rows grouped by file: line, code and text, the routine around it, the
  // source line below; `limit` counts them over every section.
  procedure AppendRows(const ARows: TArray<TCompileRow>; ANewTag: Boolean);
  var
    LLast, LWhere, LLine, LSrc: string;
    LLeft: Integer;
  begin
    LLast := #0;
    LLeft := Length(ARows);
    for var LRow in ARows do
    begin
      if LBudget <= 0 then
      begin
        LSb.AppendLine(Format('  ... %d more (raise `limit`)', [LLeft]));
        Exit;
      end;
      Dec(LLeft);
      Dec(LBudget);
      if not SameText(LRow.Msg.FileName, LLast) then
      begin
        LLast := LRow.Msg.FileName;
        if LRow.Msg.FileName = '' then
          LSb.AppendLine('(no file)')
        else
          LSb.AppendLine(AWs.RelPath(LRow.Msg.FileName));
      end;
      LWhere := '';
      if (LRow.Msg.Line > 0) and (LRow.Msg.FileName <> '') then
        LWhere := LEnclosing.NameAt(LRow.Msg.FileName, LRow.Msg.Line,
          LRow.Msg.Col, False);
      if LRow.Msg.Line > 0 then
        LLine := '  ' + IntToStr(LRow.Msg.Line) + '  '
      else
        LLine := '  ?  ';
      LLine := LLine + Trim(LRow.Msg.Code + ' ' + LRow.Msg.Text);
      if LWhere <> '' then
        LLine := LLine + ' (in ' + LWhere + ')';
      if ANewTag and LRow.Msg.IsNew then
        LLine := LLine + ' [new]';
      if LMulti and (Length(LRow.Members) < LBuilt) then
        LLine := LLine + ' [' + String.Join(', ', LRow.Members) + ']';
      if LRow.Msg.Truncated and (LRow.Msg.Line > 0) then
        LLine := LLine + ' [dcc cut the path at 128 characters: the line is '
          + 'the one writing ''' + QuotedName(LRow.Msg.Text) + ''']'
      else if LRow.Msg.Truncated then
        LLine := LLine + ' [dcc cut the path at 128 characters: line unknown]';
      LSb.AppendLine(LLine);
      LSrc := SourceLine(LRow.Msg.FileName, LRow.Msg.Line);
      if LSrc <> '' then
        LSb.AppendLine('        ' + LSrc);
    end;
  end;

  function Filter(AList: TList<TCompileRow>; AOwnOnly, ANewOnly: Boolean):
    TArray<TCompileRow>;
  begin
    Result := nil;
    for var LRow in Sorted(AList) do
      if (not AOwnOnly or LRow.Own) and (not ANewOnly or LRow.Msg.IsNew) then
        Result := Result + [LRow];
  end;

  // "warnings - 2 new (5 unchanged, 12 in library units, not listed):"
  procedure AppendKind(AList: TList<TCompileRow>; const ANoun: string;
    AAll: Boolean; ANew, AOwn, ALib: Integer);
  var
    LRest: TArray<string>;
    LListedRows: TArray<TCompileRow>;
  begin
    if AList.Count = 0 then
      Exit;
    LRest := nil;
    if AAll then
    begin
      LListedRows := Filter(AList, True, False);
      if ANew > 0 then
        LRest := LRest + [Format('%d new', [ANew])];
      if ALib > 0 then
        LRest := LRest + [Format('%d in library units, not listed', [ALib])];
      LSb.AppendLine(Format('%s - %d in the group''s files%s:', [ANoun,
        AOwn, IfThen(Length(LRest) > 0, ' (' + String.Join(', ', LRest) + ')',
        '')]));
      AppendRows(LListedRows, True);
      Exit;
    end;
    LListedRows := Filter(AList, True, True);
    // Old: reported by the previous compile of its unit, or - a unit not
    // compiled here before - in a file this session did not change.
    if AOwn - Length(LListedRows) > 0 then
      LRest := LRest + [Format('%d %s', [AOwn - Length(LListedRows),
        IfThen(LFirstOnly, 'elsewhere', 'old')])];
    if ALib > 0 then
      LRest := LRest + [Format('%d in library units', [ALib])];
    if LFirstOnly then
      LSb.Append(Format('%s - %s in files changed this session', [ANoun,
        IfThen(Length(LListedRows) > 0, IntToStr(Length(LListedRows)),
        'none')]))
    else if Length(LListedRows) > 0 then
      LSb.Append(Format('%s - %d new', [ANoun, Length(LListedRows)]))
    else
      LSb.Append(ANoun + ' - none new');
    if Length(LRest) > 0 then
      LSb.Append(' (' + String.Join(', ', LRest) + ', not listed)');
    if Length(LListedRows) > 0 then
    begin
      LSb.AppendLine(':');
      AppendRows(LListedRows, False);
    end
    else
      LSb.AppendLine;
  end;

  function MemberLine(const R: TBuildResult; const AIndent: string): string;
  var
    LM: TMcpMember;
    LErrs: Integer;
  begin
    LM := R.Spec.Member;
    Result := LM.Name + ' (' + PlatformName(LM.Platform) + IfThen(LM.Config <>
      '', ' ' + LM.Config, '') + '): ';
    // An F2063 follows from the used unit's own errors, and is folded under
    // them: not counted, unless there is nothing else.
    LErrs := 0;
    for var LMsg in R.Messages do
      if (LMsg.Kind in [bmError, bmSetupError]) and
        not SameText(LMsg.Code, 'F2063') then
        Inc(LErrs);
    if LErrs = 0 then
      for var LMsg in R.Messages do
        if LMsg.Kind in [bmError, bmSetupError] then
          Inc(LErrs);
    if not R.Ran then
      Result := Result + 'not built - ' + R.Error
    else if R.TimedOut then
      Result := Result + 'stopped after ' + Seconds(R.Ms) +
        ' - the build ran too long'
    else if R.Ok then
      Result := Result + 'built in ' + Seconds(R.Ms) + IfThen(R.Lines <> '',
        ', ' + R.Lines + ' compiled', '')
    else
      Result := Result + 'FAILED in ' + Seconds(R.Ms) + ', ' +
        Plural(LErrs, 'error');
    if R.Ok and (R.OutputFile <> '') then
      Result := Result + sLineBreak + AIndent + 'output: ' + R.OutputFile;
    if R.Ran and R.FirstBuild then
    begin
      if R.SeededFrom <> '' then
        Result := Result + sLineBreak + AIndent + Format('first build here: '
          + 'started from the %d .dcu files of %s', [R.SeededCount,
          AWs.RelPath(R.SeededFrom)])
      else
        Result := Result + sLineBreak + AIndent + 'first build here: every '
          + 'unit compiled - no .dcu directory of an earlier build to start from';
    end;
    // Said once, and again when the build fails - a file a skipped event
    // generates may be why.
    if (Length(R.NotRun) > 0) and (R.FirstBuild or not R.Ok) then
      Result := Result + sLineBreak + AIndent + 'not run: ' +
        String.Join('; ', R.NotRun);
  end;

begin
  LSb := TStringBuilder.Create;
  LGone := TList<TCompileRow>.Create;
  LIndex := TDictionary<string, Integer>.Create;
  LEnclosing := TEnclosing.Create(AWs);
  LLines := TDictionary<string, TArray<string>>.Create;
  LErrFiles := TDictionary<string, Boolean>.Create;
  LErrors := TList<TCompileRow>.Create;
  LSetup := TList<TCompileRow>.Create;
  LWarn := TList<TCompileRow>.Create;
  LHint := TList<TCompileRow>.Create;
  LSetupWarn := TList<TCompileRow>.Create;
  try
    LMulti := Length(AResults) > 1;
    LBuilt := 0;
    LFirstOnly := True;
    for var R in AResults do
      if R.Ran then
      begin
        Inc(LBuilt);
        LFirstOnly := LFirstOnly and R.FirstBuild;
      end;
    if LBuilt = 0 then
      LFirstOnly := False;

    if not LMulti then
      LSb.AppendLine('compile ' + MemberLine(AResults[0], '  '))
    else
    begin
      LSb.AppendLine(Format('compile - %d members%s', [Length(AResults),
        IfThen(AWhy <> '', ', ' + AWhy, '')]));
      for var R in AResults do
        LSb.AppendLine('  ' + MemberLine(R, '    '));
    end;

    for var R in AResults do
    begin
      LName := R.Spec.Member.Name;
      for var LMsg in R.Messages do
        case LMsg.Kind of
          bmError:
            Merge(LErrors, LMsg, LName, True);
          bmSetupError:
            Merge(LSetup, LMsg, LName, True);
          bmWarning:
            Merge(LWarn, LMsg, LName, True);
          bmHint:
            Merge(LHint, LMsg, LName, True);
          bmSetupWarning:
            Merge(LSetupWarn, LMsg, LName, True);
          bmMissingDir:
            if IndexText(LMsg.Text, LMissing) < 0 then
              LMissing := LMissing + [LMsg.Text];
        end;
      for var LMsg in R.Gone do
        Merge(LGone, LMsg, LName, True);
    end;

    LBudget := ALimit;
    // An F2063 "could not compile used unit X" follows from X's own errors;
    // it is folded when those are listed.
    for var LRow in LErrors do
      if not SameText(LRow.Msg.Code, 'F2063') then
        LErrFiles.AddOrSetValue(LowerCase(ExtractFileName(LRow.Msg.FileName)),
          True);
    LNotFound := False;
    for var LI := LErrors.Count - 1 downto 0 do
    begin
      if SameText(LErrors[LI].Msg.Code, 'F2063') and LErrFiles.ContainsKey(
        LowerCase(ExtractFileName(QuotedName(LErrors[LI].Msg.Text)))) then
      begin
        LFolded := LFolded + [AWs.RelPath(LErrors[LI].Msg.FileName)];
        LErrors.Delete(LI);
        Continue;
      end;
      if MatchText(LErrors[LI].Msg.Code, ['F2613', 'F1026']) then
        LNotFound := True;
    end;
    if LErrors.Count > 0 then
    begin
      LSb.AppendLine(Format('errors - %d:', [LErrors.Count]));
      AppendRows(Sorted(LErrors), False);
      if Length(LFolded) > 0 then
        LSb.AppendLine(Format('  and %s using them could not compile: %s',
          [Plural(Length(LFolded), 'unit'), String.Join(', ', LFolded)]));
    end;
    if LSetup.Count > 0 then
    begin
      LSb.AppendLine(Format('build errors, not in the code - %d:',
        [LSetup.Count]));
      for var LRow in Sorted(LSetup) do
        LSb.AppendLine('  ' + IfThen(LRow.Msg.FileName <> '',
          AWs.RelPath(LRow.Msg.FileName) + ': ', '') + Trim(LRow.Msg.Code + ' '
          + LRow.Msg.Text));
    end;
    if LNotFound and (Length(LMissing) > 0) then
    begin
      LSb.AppendLine(Format('search path directories that do not exist - %d:',
        [Length(LMissing)]));
      for var LI := 0 to Min(High(LMissing), 9) do
        LSb.AppendLine('  ' + LMissing[LI]);
      if Length(LMissing) > 10 then
        LSb.AppendLine(Format('  ... %d more', [Length(LMissing) - 10]));
    end;

    LNewW := 0;
    LOwnW := 0;
    LLibW := 0;
    for var LRow in LWarn do
      if not LRow.Own then
        Inc(LLibW)
      else
      begin
        Inc(LOwnW);
        if LRow.Msg.IsNew then
          Inc(LNewW);
      end;
    LNewH := 0;
    LOwnH := 0;
    LLibH := 0;
    for var LRow in LHint do
      if not LRow.Own then
        Inc(LLibH)
      else
      begin
        Inc(LOwnH);
        if LRow.Msg.IsNew then
          Inc(LNewH);
      end;
    AppendKind(LWarn, 'warnings', AShow <> 'new', LNewW, LOwnW, LLibW);
    AppendKind(LHint, 'hints', AShow = 'all', LNewH, LOwnH, LLibH);
    if (AShow = 'all') and (LSetupWarn.Count > 0) then
    begin
      LSb.AppendLine(Format('build warnings - %d:', [LSetupWarn.Count]));
      for var LRow in Sorted(LSetupWarn) do
        LSb.AppendLine('  ' + IfThen(LRow.Msg.FileName <> '',
          AWs.RelPath(LRow.Msg.FileName) + ': ', '') + Trim(LRow.Msg.Code + ' '
          + LRow.Msg.Text));
    end;
    if LGone.Count > 0 then
    begin
      LSb.AppendLine(Format('gone since the previous compile - %d:',
        [LGone.Count]));
      LListed := 0;
      for var LRow in Sorted(LGone) do
      begin
        if LListed = 10 then
        begin
          LSb.AppendLine(Format('  ... %d more', [LGone.Count - 10]));
          Break;
        end;
        Inc(LListed);
        LSb.AppendLine(Format('  %s:%d  %s %s', [AWs.RelPath(LRow.Msg.FileName),
          LRow.Msg.Line, LRow.Msg.Code, LRow.Msg.Text]));
      end;
    end;
    if (LBuilt > 0) and (LErrors.Count + LSetup.Count + LWarn.Count +
      LHint.Count = 0) then
      LSb.AppendLine('no errors, warnings or hints');
    Result := LSb.ToString.TrimRight;
  finally
    LSetupWarn.Free;
    LHint.Free;
    LWarn.Free;
    LSetup.Free;
    LErrors.Free;
    LErrFiles.Free;
    LLines.Free;
    LEnclosing.Free;
    LIndex.Free;
    LGone.Free;
    LSb.Free;
  end;
end;

type
  { `compile` (SPEC 9.4): the members a change reaches, built by the real
    compiler into a directory of the server's own (PasMcp.Build), answered
    with the errors and what the change added to the warnings and hints.
    Three steps: which members (NewCompileJob, where the tools run), their
    builds (Work, on a thread of its own - specs only, never the index), the
    answer (Finish, where the tools run again: routine names and source
    lines come from the index). }
  TCompileJob = class(TDeferredTool)
  private
    FWs: TMcpWorkspace;
    FSpecs: TArray<TBuildSpec>;
    FResults: TArray<TBuildResult>;
    FWhy, FShow, FFresh: string;
    FLimit: Integer;
    FRebuild: Boolean;
    FProgress: TProc<string>;
    FCancel: TBuildCancel;
  public
    constructor Create(AWs: TMcpWorkspace; const AMembers: TArray<Integer>;
      const AWhy, AShow: string; ALimit: Integer; ARebuild: Boolean;
      const AProgress: TProc<string>);
    destructor Destroy; override;
    procedure Work; override;
    function Finish(out AIsError: Boolean): string; override;
    procedure Cancel; override;
    // The freshness note of the call, said with the answer.
    property Fresh: string read FFresh write FFresh;
  end;

constructor TCompileJob.Create(AWs: TMcpWorkspace;
  const AMembers: TArray<Integer>; const AWhy, AShow: string; ALimit: Integer;
  ARebuild: Boolean; const AProgress: TProc<string>);
begin
  inherited Create;
  FWs := AWs;
  for var LIdx in AMembers do
    FSpecs := FSpecs + [MemberBuildSpec(AWs, LIdx)];
  FWhy := AWhy;
  FShow := AShow;
  FLimit := ALimit;
  FRebuild := ARebuild;
  FProgress := AProgress;
  FCancel := TBuildCancel.Create;
end;

destructor TCompileJob.Destroy;
begin
  FCancel.Free;
  inherited;
end;

procedure TCompileJob.Work;
begin
  FResults := nil;
  for var LK := 0 to High(FSpecs) do
  begin
    if FCancel.Cancelled then
      Break;
    FResults := FResults + [BuildMember(FSpecs[LK], FRebuild,
      MemberProgress(FProgress, LK, Length(FSpecs)), FCancel)];
  end;
end;

function TCompileJob.Finish(out AIsError: Boolean): string;
var
  LFresh: string;
  LNotes: TArray<string>;
begin
  AIsError := False;
  if FCancel.Cancelled then
    Exit('compile cancelled');
  // Files may have changed while it built; the routine names and source
  // lines of the answer come from them as they are now.
  FWs.EnsureFresh(LFresh);
  for var LI := 0 to High(FResults) do
    if FResults[LI].Ran then
    begin
      ResolveTruncated(FWs, FResults[LI]);
      CompareWithBaseline(FResults[LI], FWs.ChangedFiles);
    end;
  Result := CompileAnswer(FWs, FResults, FWhy, FShow, FLimit);
  LNotes := nil;
  if Trim(FFresh) <> '' then
    LNotes := LNotes + [FFresh.TrimRight([' ', ';'])];
  if Trim(LFresh) <> '' then
    LNotes := LNotes + [LFresh.TrimRight([' ', ';'])];
  if Length(LNotes) > 0 then
    Result := '(index: ' + String.Join('; ', LNotes) + ')' + sLineBreak + Result;
end;

procedure TCompileJob.Cancel;
begin
  FCancel.Cancel;
end;

function NewCompileJob(AWs: TMcpWorkspace; AArgs: TJSONObject;
  const AProgress: TProc<string>): TCompileJob;
var
  LShow, LWhy: string;
  LMembers: TArray<Integer>;
begin
  LShow := LowerCase(ArgStr(AArgs, 'show', 'new'));
  if not MatchText(LShow, ['new', 'warnings', 'all']) then
    raise EToolError.Create('`show` is new, warnings or all');
  LMembers := CompileMembers(AWs, AArgs, LWhy);
  Result := TCompileJob.Create(AWs, LMembers, LWhy, LShow,
    EnsureRange(ArgInt(AArgs, 'limit', 60), 1, 5000),
    ArgBool(AArgs, 'rebuild', False), AProgress);
end;

{ ---- the catalogue ----------------------------------------------------------- }

const
  TARGET_PROPS =
    '"symbol":{"type":"string","description":"Symbol name: TFoo, TFoo.Bar, '
    + 'UnitName.TFoo.Bar. Alternatively give file + line + name."},'
    + '"file":{"type":"string","description":"Source file, absolute or '
    + 'relative to the project group directory"},'
    + '"line":{"type":"integer","description":"1-based line in file"},'
    + '"name":{"type":"string","description":"The identifier as written on '
    + 'that line"},'
    + '"column":{"type":"integer","description":"1-based column, only needed '
    + 'when name occurs twice on the line"},'
    + '"kind":{"type":"string","description":"Narrow a name: type, class, '
    + 'record, interface, routine, procedure, function, constructor, var, '
    + 'const, field, property"}';

  TOOLS_JSON = '[' +
    '{"name":"status","description":"What is loaded: project group members, '
    + 'analyses, unit counts, unit names that do not resolve, load progress. '
    + 'Call it when another tool says the index is still loading.",'
    + '"inputSchema":{"type":"object","properties":{}}},' +

    '{"name":"find","description":"Find declarations by name across the '
    + 'whole closure of the project group (project units first, then '
    + 'libraries and the RTL). Exact name, qualified name (TFoo.Bar, '
    + 'Unit.TFoo) or wildcards (*Customer*). Returns file:line, the qualified '
    + 'name, its kind and the declaration (one written over several lines '
    + 'joined). Faster and more precise than grep for Object Pascal '
    + 'declarations. A name the index does not hold is answered with the '
    + 'Pascal files outside it - units no project uses - that write it.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"query":{"type":"string","description":"Name, qualified name or '
    + 'wildcard pattern"},'
    + '"kind":{"type":"string","description":"type, class, record, '
    + 'interface, routine, procedure, function, constructor, var, const, '
    + 'field, property"},'
    + '"scope":{"type":"string","enum":["all","project"],"description":'
    + '"project = only the group''s own units (default all)"},'
    + '"limit":{"type":"integer","description":"Max rows (default 30)"}},'
    + '"required":["query"]}},' +

    '{"name":"definition","description":"Where a symbol is declared and, for '
    + 'a method or forward-declared routine, where it is implemented; '
    + 'optionally the source lines that follow (the implementation when '
    + 'there is one). Address the symbol by name or by file + line + name.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"context":{"type":"integer","description":"Source lines to include '
    + '(default 0, max 200)"}}}},' +

    '{"name":"source","description":"The exact source text of one '
    + 'declaration, by name: a routine''s implementation from its header to '
    + 'its end, a type''s whole declaration, a constant with its value - '
    + 'numbered as in the file, with the comment written directly above it. '
    + 'Use it instead of reading a file at a guessed offset.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"part":{"type":"string","enum":["impl","decl","both"],"description":'
    + '"For a routine: its implementation (the default when it has one), its '
    + 'declaration, or both"},'
    + '"limit":{"type":"integer","description":"Max lines per part (default '
    + '300)"}}}},' +

    '{"name":"members","description":"What can be used on a class, record '
    + 'or interface, inherited members included - instead of an outline per '
    + 'ancestor: each member under the type that declares it (the type asked '
    + 'about first, then its ancestors) and its visibility section, with its '
    + 'declaration line. An override or a redeclaration is listed once, at '
    + 'the lowest type declaring it. By default what the type''s own methods '
    + 'can use (ancestors'' private members left out); of a type from outside '
    + 'the group, what any code can use. A variable, field, property or '
    + 'parameter lists the members of its type that code in its unit can '
    + 'use. Ancestors from outside the group (VCL, RTL) are counted, not '
    + 'listed, unless `library` or `match` is given or the type is one '
    + 'itself.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"visibility":{"type":"string","enum":["public","protected","all"],'
    + '"description":"public: what any code can use; protected: what a '
    + 'descendant in another unit can use; all: every member, private ones '
    + 'included"},'
    + '"member_kind":{"type":"string","description":"Only these members: '
    + 'method, property, field, const, type - or procedure, function, '
    + 'constructor, destructor"},'
    + '"match":{"type":"string","description":"Only members whose name '
    + 'matches: wildcards (*Save*) or a part of the name"},'
    + '"library":{"type":"boolean","description":"List the members of '
    + 'ancestors outside the group too (default false: counted)"},'
    + '"limit":{"type":"integer","description":"Max rows (default 150)"}}}},' +

    '{"name":"references","description":"Every use of a symbol across all '
    + 'projects of the group, by resolved identity rather than text: '
    + 'same-named unrelated symbols, comments and strings are not in it. '
    + 'Grouped by file and, within a file, under the routine or type each '
    + 'use sits in (TFoo.Save), with the source line - usually enough to '
    + 'answer without opening the file. The form files (.dfm, .fmx) are '
    + 'read too: the lines that bind the symbol by name - a component''s '
    + '`object` line, `OnClick = Handler`, `FocusControl = edtName` - under '
    + 'the component they belong to; a rename must change those as well. '
    + 'Also takes a unit name (its uses '
    + 'clauses), and by position a compiler built-in or a conditional '
    + 'define.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"limit":{"type":"integer","description":"Max rows (default 150)"}}}},' +

    '{"name":"callers","description":"Who calls a routine: each call grouped '
    + 'by file under the routine it sits in, with the source line. Includes '
    + 'what a reference search misses: calls that may dispatch to it through '
    + 'the virtual method it overrides or an interface method it implements '
    + '([via X]), reads or writes of a property it is the accessor of, bare '
    + '`inherited;`. A row that hands it on instead of calling it (OnClick := '
    + 'Foo, @Foo) says [not a call]. depth 2-4 adds the callers of those, '
    + 'level by level ([-> the routine called]), and names the routines no '
    + 'caller was found for. An event handler''s bindings in the form files '
    + '(.dfm, .fmx) are rows too - `OnClick = btnSaveClick` under the '
    + 'component whose event runs it, at any depth: where a chain of calls '
    + 'starts from the UI.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"depth":{"type":"integer","description":"Levels of callers (default 1, '
    + 'max 4)"},'
    + '"limit":{"type":"integer","description":"Max rows over all levels '
    + '(default 150)"}}}},' +

    '{"name":"callees","description":"What a routine calls: each routine its '
    + 'body reaches, once, at its declaration line - grouped by file under '
    + 'its type - with the lines of the calls ([at 19, 31]). Resolved as the '
    + 'compiler binds them: the overload called, a property''s getter or '
    + 'setter, what a bare `inherited;` runs. A virtual call adds the '
    + 'overrides the object''s class may run, an interface call the methods '
    + 'implementing it ([via X]). A routine handed on instead of called '
    + '(OnClick := Foo) says [not a call]. depth 2-4 adds what those call, '
    + 'level by level, own routines only ([TFoo.Load at 40] names the '
    + 'caller). Calls through a method pointer are named: what they run is '
    + 'assigned elsewhere.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"depth":{"type":"integer","description":"Levels of callees (default 1, '
    + 'max 4)"},'
    + '"limit":{"type":"integer","description":"Max rows over all levels '
    + '(default 150)"}}}},' +

    '{"name":"impact","description":"What a change reaches - after editing, '
    + 'pass the output of `git diff` as `diff`; before, the declarations you '
    + 'will change. Answers which projects of the group compile the changed '
    + 'files (build and test those, not the rest); the declarations the diff '
    + 'touches - routines, types, fields, properties, a uses clause - each '
    + 'with the virtual or interface methods it is also called through, its '
    + 'overrides and implementations; their callers or uses across the group, '
    + 'grouped by the routine they sit in, to a `depth`; the units that use a '
    + 'unit whose interface changed; and a removed routine with the places '
    + 'that still name it. The diff must be of the files as they are on disk '
    + 'now. The form files (.dfm, .fmx) are read: a handler''s bindings and '
    + 'the lines naming a component or a class are among the uses, and a '
    + 'removed handler still bound in a form - which then fails to load, '
    + 'with no compiler error - is named with its line.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"diff":{"type":"string","description":"Unified diff of your edits: '
    + 'the output of `git diff`, as it is"},'
    + TARGET_PROPS + ','
    + '"symbols":{"type":"array","items":{"type":"string"},"description":'
    + '"Several declarations by name (TFoo.Bar), instead of symbol"},'
    + '"depth":{"type":"integer","description":"Levels of callers (default 1, '
    + 'max 4)"},'
    + '"limit":{"type":"integer","description":"Max caller rows over all '
    + 'levels (default 150)"}}}},' +

    '{"name":"compile","description":"Build with the real compiler - MSBuild '
    + 'over the member''s .dproj, its own platform and configuration - and '
    + 'answer with what it reports: the errors, each with the routine it is '
    + 'in and its source line, then the warnings and hints new since that '
    + 'member''s previous compile (the old ones are counted). With no '
    + 'arguments it builds the members of the group that compile the files '
    + 'changed this session. Everything is written to a directory of the '
    + 'server''s own (the answer names the exe it built, to run tests '
    + 'against): the project''s output, its .dcu files and the source tree '
    + 'are not touched, and pre- and post-build events are not run. Takes '
    + 'seconds for a small change, minutes for a first build or a rebuild of '
    + 'a large member - the other tools answer meanwhile, and cancelling the '
    + 'call stops the build: use `diagnostics` while editing, `compile` '
    + 'before saying a change is done.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"member":{"type":"string","description":"Group members to build, by '
    + 'name: AppA, or AppA,AppB. Default: those the files changed this '
    + 'session reach"},'
    + '"file":{"type":"string","description":"Or build the members that '
    + 'compile this file"},'
    + '"show":{"type":"string","enum":["new","warnings","all"],"description":'
    + '"new (default): the errors, and the warnings and hints not reported '
    + 'before; warnings: every warning in the group''s files; all: every hint '
    + 'too"},'
    + '"rebuild":{"type":"boolean","description":"Recompile every unit, not '
    + 'only what changed (default false)"},'
    + '"limit":{"type":"integer","description":"Max rows (default 60)"}}}},' +

    '{"name":"related","description":"Relations across the group. '
    + 'descendants: classes/interfaces below a type. overrides: the virtual '
    + 'chain of a method. implementations: classes implementing an interface '
    + 'or one of its methods. assignments: writes to a variable, field or '
    + 'property. creations: TFoo.Create calls of exactly that class. '
    + 'destructions: Free/Destroy/FreeAndNil of a TFoo, and a form''s '
    + 'Release. Grouped by file; assignment, creation and destruction rows '
    + 'under the routine they sit in, a descendant row names its parent '
    + '(`<- TParent`) unless that is the type asked about, and a row whose '
    + 'source line repeats the previous row''s shows only its [tag].",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"relation":{"type":"string","enum":["descendants","overrides",'
    + '"implementations","assignments","creations","destructions"]},'
    + TARGET_PROPS + ','
    + '"limit":{"type":"integer","description":"Max rows (default 150)"}},'
    + '"required":["relation"]}},' +

    '{"name":"outline","description":"The structure of one unit without '
    + 'reading it: sections, uses, types with their members, routines with '
    + 'signatures - each with its line number.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"file":{"type":"string","description":"Source file, absolute or '
    + 'relative to the project group directory"},'
    + '"owner":{"type":"string","description":"Only this type and its '
    + 'members, e.g. TfrmMain"},'
    + '"section":{"type":"string","enum":["interface","implementation"]},'
    + '"members":{"type":"boolean","description":"Include fields, properties '
    + 'and method declarations inside types (default true; left out, and '
    + 'said, when the whole outline is over `limit`)"},'
    + '"limit":{"type":"integer","description":"Max rows (default 400)"}},'
    + '"required":["file"]}},' +

    '{"name":"form","description":"The component tree of one form without '
    + 'reading its .dfm: each component with its class, the events it binds '
    + 'and to which method (OnClick -> TfrmMain.btnSaveClick), the components '
    + 'it names (FocusControl, a data module''s component), each with its '
    + 'line in the form file. An inherited form is shown merged with its '
    + 'ancestors'' form files, as the form designer shows it; a row from an '
    + 'ancestor names its file. A handler whose method is gone - the form '
    + 'fails to load - and a component a value names that does not exist are '
    + 'said. Plain properties (Left, Caption) are left out.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"file":{"type":"string","description":"The form''s unit or its '
    + '.dfm/.fmx, absolute or relative to the project group directory"},'
    + '"symbol":{"type":"string","description":"Or the form''s class, e.g. '
    + 'TfrmMain"},'
    + '"limit":{"type":"integer","description":"Max rows (default 400)"}}}},' +

    '{"name":"diagnostics","description":"Semantic errors PasTree finds - '
    + 'undeclared identifiers, unknown members, wrong argument counts, '
    + 'missing units - for one file or every unit of the group, each row '
    + 'naming the routine it is in. Reflects the files on disk now, so it is '
    + 'a quick check after editing (a subset of what the compiler reports, '
    + 'not a build).",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"file":{"type":"string","description":"Only this file"},'
    + '"library":{"type":"boolean","description":"Include library units '
    + '(default false)"},'
    + '"limit":{"type":"integer","description":"Max rows (default 60)"}}}},' +

    '{"name":"unit_deps","description":"Which units a unit uses (resolved to '
    + 'files, implementation-section ones marked) and which units use it.",'
    + '"inputSchema":{"type":"object","properties":{'
    + '"unit":{"type":"string","description":"Unit name"},'
    + '"file":{"type":"string","description":"Or the unit''s file"},'
    + '"direction":{"type":"string","enum":["uses","used_by","both"]}}}}' +
    ']';

function ToolDefinitions: TJSONArray;
begin
  Result := TJSONObject.ParseJSONValue(TOOLS_JSON) as TJSONArray;
  if Result = nil then
    raise Exception.Create('internal: the tool catalogue is not valid JSON');
end;

function ServerInstructions(AWs: TMcpWorkspace): string;
begin
  Result := 'PasTree semantic index of the Delphi/Object Pascal project '
    + ExtractFileName(AWs.ProjectFile) + ' (' + AWs.Root + '). For Object '
    + 'Pascal code prefer these tools over grep and reading whole files: '
    + '`find` locates declarations, `definition` jumps to declaration and '
    + 'implementation, `source` gives the exact text of one declaration (a '
    + 'routine''s body, a whole type) instead of a file read at a guessed '
    + 'offset, `members` what a class can do - its members and the inherited '
    + 'ones, by the type declaring each, `references` lists real uses '
    + '(resolved identity, not '
    + 'text), `callers` who calls a routine (through the virtual or '
    + 'interface method it implements too, to a `depth`), `callees` what a '
    + 'routine calls (with the overrides and implementations a virtual or '
    + 'interface call may run), `impact` what a change reaches - pass `git '
    + 'diff` output or the symbols you will change: callers, overrides, and '
    + 'which projects of the group to build and test, `compile` builds them '
    + 'with the real compiler into a directory of its own (nothing of the '
    + 'project is overwritten) and lists the errors and the warnings the '
    + 'change added - run it before saying a change is done, `related` answers '
    + 'hierarchy/override/implementation/assignment/'
    + 'creation questions, `outline` shows a unit''s structure with line '
    + 'numbers, `form` a form''s components and which method each event '
    + 'runs (instead of reading the .dfm and its ancestors''), `unit_deps` '
    + 'its uses graph, `diagnostics` checks name '
    + 'resolution after edits. Their rows name the routine or type they sit '
    + 'in, which usually answers the question without opening the file. '
    + 'Symbols are addressed by name (TFoo, '
    + 'TFoo.Bar, Unit.TFoo.Bar) or by file + line + name. Result paths are '
    + 'relative to ' + AWs.Root + '. The index holds what the projects '
    + 'compile - their `uses` closure, not every file of the directory. It '
    + 're-reads changed files before every call, so results match the files '
    + 'on disk, and names them: one you did not edit is someone else''s edit.';
end;

function CallTool(AWs: TMcpWorkspace; const AName: string; AArgs: TJSONObject;
  out AIsError: Boolean; out ADeferred: TDeferredTool;
  const AProgress: TProc<string>): string;
var
  LFresh: string;
  LSW: TStopwatch;
  LFreshMs: Int64;
  LJob: TCompileJob;
begin
  AIsError := False;
  ADeferred := nil;
  LSW := TStopwatch.StartNew;
  LFreshMs := 0;
  try
    if AName <> 'status' then
    begin
      // The handshake does not wait for the analysis; the first real call
      // does, up to a point - an MCP client times a call out on its own.
      if not AWs.WaitReady(100000) then
      begin
        AIsError := True;
        Exit('the index is still loading (' + AWs.State + ') - try again in '
          + 'a minute; `status` shows progress');
      end;
      if AWs.LoadError <> '' then
      begin
        AIsError := True;
        Exit('the project failed to load: ' + AWs.LoadError);
      end;
      LFreshMs := LSW.ElapsedMilliseconds;
      AWs.EnsureFresh(LFresh);
      LFreshMs := LSW.ElapsedMilliseconds - LFreshMs;
    end;
    if AName = 'status' then
      Result := ToolStatus(AWs, AArgs)
    else if AName = 'find' then
      Result := ToolFind(AWs, AArgs)
    else if AName = 'definition' then
      Result := ToolDefinition(AWs, AArgs)
    else if AName = 'source' then
      Result := ToolSource(AWs, AArgs)
    else if AName = 'members' then
      Result := ToolMembers(AWs, AArgs)
    else if AName = 'references' then
      Result := ToolReferences(AWs, AArgs)
    else if AName = 'callers' then
      Result := ToolCallers(AWs, AArgs)
    else if AName = 'callees' then
      Result := ToolCallees(AWs, AArgs)
    else if AName = 'impact' then
      Result := ToolImpact(AWs, AArgs)
    else if AName = 'compile' then
    begin
      // Answered by the job, the freshness note with it.
      LJob := NewCompileJob(AWs, AArgs, AProgress);
      LJob.Fresh := LFresh;
      LFresh := '';
      ADeferred := LJob;
      Result := '';
    end
    else if AName = 'related' then
      Result := ToolRelated(AWs, AArgs)
    else if AName = 'outline' then
      Result := ToolOutline(AWs, AArgs)
    else if AName = 'form' then
      Result := ToolForm(AWs, AArgs)
    else if AName = 'diagnostics' then
      Result := ToolDiagnostics(AWs, AArgs)
    else if AName = 'unit_deps' then
      Result := ToolUnitDeps(AWs, AArgs)
    else
      raise EToolError.Create('unknown tool: ' + AName);
  except
    on E: EToolError do
    begin
      AIsError := True;
      Result := E.Message;
    end;
    on E: Exception do
    begin
      AIsError := True;
      Result := 'internal error: ' + E.ClassName + ': ' + E.Message;
      Log('tool %s raised %s: %s', [AName, E.ClassName, E.Message]);
    end;
  end;
  // On an error answer too: the re-analysis happened, the next call will not
  // report it again, and an edit someone else made may be what the error is.
  if LFresh <> '' then
    Result := '(index: ' + LFresh.TrimRight([' ', ';']) + ')' + sLineBreak +
      Result;
  Log('tool %s: %d ms (freshness check %d ms), %s%s', [AName,
    LSW.ElapsedMilliseconds, LFreshMs, IfThen(ADeferred <> nil,
    'answered when its work is done', IntToStr(Length(Result)) + ' chars'),
    IfThen(AIsError, ', error', '')]);
end;

function CallToolNow(AWs: TMcpWorkspace; const AName: string;
  AArgs: TJSONObject; out AIsError: Boolean): string;
var
  LJob: TDeferredTool;
begin
  Result := CallTool(AWs, AName, AArgs, AIsError, LJob, nil);
  if LJob = nil then
    Exit;
  try
    try
      LJob.Work;
      Result := LJob.Finish(AIsError);
    except
      on E: Exception do
      begin
        AIsError := True;
        Result := 'internal error: ' + E.ClassName + ': ' + E.Message;
        Log('tool %s raised %s: %s', [AName, E.ClassName, E.Message]);
      end;
    end;
  finally
    LJob.Free;
  end;
end;

end.
