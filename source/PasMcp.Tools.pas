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
  System.JSON,
  PasMcp.Workspace;

function ToolDefinitions: TJSONArray;
function ServerInstructions(AWs: TMcpWorkspace): string;
function CallTool(AWs: TMcpWorkspace; const AName: string; AArgs: TJSONObject;
  out AIsError: Boolean): string;

implementation

uses
  System.SysUtils,
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
  PasMcp.Log;

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
  AT.Snippet := CleanLine(LHit.Snippet);
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
      Continue;
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

// The ONE target a search is about: from file+line+name, or from `symbol`,
// refusing an ambiguous name with the candidates listed.
function ResolveOne(AWs: TMcpWorkspace; AArgs: TJSONObject): TTarget;
var
  LSymbol: string;
  LCands: TArray<TTarget>;
  LMore: Integer;
  LSb: TStringBuilder;
begin
  if ArgStr(AArgs, 'file') <> '' then
    Exit(ResolvePosition(AWs, AArgs));
  LSymbol := ArgStr(AArgs, 'symbol');
  if LSymbol = '' then
    raise EToolError.Create('give `symbol` (a name like TFoo.Bar) or `file` + '
      + '`line` + `name`');
  LCands := ResolveName(AWs, LSymbol, ArgStr(AArgs, 'kind'), False, 12, LMore);
  if Length(LCands) = 0 then
    raise EToolError.CreateFmt('no declaration named `%s` in the analyzed '
      + 'closure (try `find` with a wildcard: *%s*; a local or a parameter is '
      + 'addressed by `file` + `line` + `name`)', [LSymbol,
      StripGenerics(LSymbol.Split(['.'])[High(LSymbol.Split(['.']))])]);
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
      + 'the one you mean:', [LSymbol, Length(LCands) + LMore,
      IfThen(LMore > 0, ' (first ' + IntToStr(Length(LCands)) + ')', '')]));
    for var LC in LCands do
      LSb.AppendLine('  ' + DescribeTarget(AWs, LC));
    raise EToolError.Create(LSb.ToString.TrimRight);
  finally
    LSb.Free;
  end;
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
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    procedure Add(const AHit: TPasRefHit; const ATag: string = '');
    function Count: Integer;
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

function THitSet.Count: Integer;
begin
  Result := FList.Count;
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
procedure AppendHitsByFile(AWs: TMcpWorkspace; ASb: TStringBuilder;
  const AHits: TArray<THit>; ALimit: Integer; ATagOnly: Boolean = False;
  AEnclosing: TEnclosing = nil);
var
  LFile, LLine, LPrev, LWhere, LLastWhere, LIndent: string;
  LShown: Integer;
begin
  LFile := '';
  LPrev := '';
  LLastWhere := '';
  LShown := 0;
  for var LH in AHits do
  begin
    if LShown >= ALimit then
      Break;
    if not SameText(LH.FilePath, LFile) then
    begin
      LFile := LH.FilePath;
      ASb.AppendLine(AWs.RelPath(LFile));
      LLastWhere := '';
    end;
    LIndent := '  ';
    if AEnclosing <> nil then
    begin
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
  if Length(AHits) > LShown then
    ASb.AppendLine(Format('... %d more (raise `limit`)',
      [Length(AHits) - LShown]));
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
  LFallback: Boolean;
begin
  LQuery := ArgStr(AArgs, 'query');
  if LQuery = '' then
    raise EToolError.Create('`query` is required');
  LKind := ArgStr(AArgs, 'kind');
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 30), 1, 500);
  LCands := ResolveName(AWs, LQuery, LKind, SameText(ArgStr(AArgs, 'scope'),
    'project'), LLimit, LMore);
  LFallback := False;
  if (Length(LCands) = 0) and (Pos('*', LQuery) = 0) and (Pos('?', LQuery) = 0)
  then
  begin
    // Nothing by that exact name: the agent often half-remembers one.
    LCands := ResolveName(AWs, '*' + LQuery + '*', LKind,
      SameText(ArgStr(AArgs, 'scope'), 'project'), LLimit, LMore);
    LFallback := True;
  end;
  LSb := TStringBuilder.Create;
  try
    if Length(LCands) = 0 then
      Exit(Format('no declaration matches `%s`', [LQuery]));
    if LFallback then
      LSb.AppendLine(Format('no declaration named exactly `%s`; names '
        + 'containing it:', [LQuery]));
    for var LC in LCands do
      LSb.AppendLine(DescribeTarget(AWs, LC));
    if LMore > 0 then
      LSb.AppendLine(Format('... %d more (narrow the query, add `kind`, or '
        + 'raise `limit`)', [LMore]));
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
      raise EToolError.CreateFmt('no declaration named `%s` (try `find` with '
        + 'a wildcard; a local or a parameter is addressed by `file` + `line` '
        + '+ `name`)', [ArgStr(AArgs, 'symbol')]);
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

function ToolReferences(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
var
  LT: TTarget;
  LSet: THitSet;
  LHits: TArray<THit>;
  LSb: TStringBuilder;
  LLimit: Integer;
  LId: TSymId;
  LEnclosing: TEnclosing;
begin
  LT := ResolveOne(AWs, AArgs);
  LLimit := EnsureRange(ArgInt(AArgs, 'limit', 150), 1, 5000);
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
          for var LH in LA.Nav.FindReferences(LId.Mid, LId.Sym) do
            LSet.Add(LH);
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
    if LT.Kind in [tkSymbol, tkUnit] then
      LSb.AppendLine(Format('%s (%s) declared at %s:%d - %d references in %d '
        + 'files', [LT.Name, LT.Head, AWs.RelPath(LT.DeclFile), LT.DeclLine,
        Length(LHits), FileCount(LHits)]))
    else
      LSb.AppendLine(Format('%s (%s) - %d references in %d files', [LT.Name,
        LT.Head, Length(LHits), FileCount(LHits)]));
    AppendHitsByFile(AWs, LSb, LHits, LLimit, False, LEnclosing);
    if LSet.Compiled > 0 then
      LSb.AppendLine(Format('(+%d in compiled units without source, not '
        + 'shown)', [LSet.Compiled]));
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

  TCallSourceKind = (csSelf, csVirtual, csInterface, csRead, csWrite);

  { A symbol a call can be written against and still end up running the
    routine, in one analysis: the routine itself, a virtual method it
    overrides, an interface method it implements, a property it is an
    accessor of. }
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

  // A routine of the walk: the target, or a caller found at Level.
  TCallNode = record
    T: TTarget;
    Name: string;          // as its rows' heading reads: TFoo.Save.Helper
    Level: Integer;
    Found: Integer;        // rows its search found; -1 = not searched
  end;

  TCallRow = record
    Hit: THit;
    Caller: string;        // declaration site of the routine it sits in
    Call: Boolean;         // a call - not the routine handed on as a value
    // The row's label, in parts: the routine of the walk it reaches (below
    // the first level), the symbol it is bound to when that is another one,
    // and what it is - 'not a call', 'exported', 'main block'.
    Callee, Via, Note: string;
  end;

const
  SOURCE_KINDS: array[TCallSourceKind] of string = ('', 'virtual',
    'interface', 'property read', 'property write');

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

// Is ANode a use that writes it - the target of an assignment? A property
// reference that is not, reads it: a property cannot be passed to a `var`
// parameter.
function IsAssignTarget(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LE, LP: Integer;
begin
  LE := DesignatorOf(LM, ANode);
  LP := LM.Tree.Nodes[LE].Parent;
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

// A method a form's .dfm can bind by name: published - written so, or in the
// unnamed first section of a class that streams (a TPersistent descendant,
// compiled {$M+}), where a form's event handlers sit.
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
      for var LDepth := 1 to 64 do
      begin
        if not XValid(LK) then
          Break;
        if AA.Proj.Model(LK.UnitId).Symbols[LK.Sym].NameLower = 'tpersistent'
        then
          Exit(True);
        LK := AA.Proj.CanonTypeX(AA.Proj.AncestorOfX(LK));
      end;
  end;
end;

type
  { The callers of one routine, level by level (SPEC 9.3.1). A row is a
    reference that reaches a routine of the walk: bound to it, or to a symbol
    a call can be written against and still end up running it - the virtual
    method it overrides, an interface method it implements, a property it is
    the accessor of - and a bare `inherited;`, which names nothing a
    reference search could find. Each analysis searches with its own symbol
    ids; rows merge by site, like every answer. }
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
    FThrough: TStringList;                      // the target's other sources
    FNotes: TStringList;                        // what the rows cannot show
    FListings: TDictionary<string, TArray<TIfaceListing>>;   // by class
    FIfaceNames: TDictionary<string, Boolean>;  // analysis:method name
    FIfaceScanned: TDictionary<Integer, Boolean>;
    FCompiled: Integer;
    FReached: Integer;      // calls found, a site listed before included
    procedure NoteThrough(const ASource: TCallSource);
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
    procedure Search(AA: TMcpAnalysis; const ANode: TCallNode);
  public
    constructor Create(AWs: TMcpWorkspace);
    destructor Destroy; override;
    function Answer(const ATarget: TTarget; ADepth, ALimit: Integer): string;
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
  FThrough := TStringList.Create;
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
  FThrough.Free;
  FRows.Free;
  FSeen.Free;
  FCallerOf.Free;
  FFound.Free;
  FNodeOf.Free;
  FNodes.Free;
  FEnclosing.Free;
  inherited;
end;

// One of the target's sources other than itself, for the answer's header.
procedure TCallerWalk.NoteThrough(const ASource: TCallSource);
var
  LText: string;
begin
  LText := Format('%s (%s)', [ASource.Name, SOURCE_KINDS[ASource.Kind]]);
  if FThrough.IndexOf(LText) < 0 then
    FThrough.Add(LText);
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
  LRow.Callee := '';
  if ANode.Level > 0 then
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
  finally
    LReaches.Free;
    LByClass.Free;
    LBelow.Free;
    LSources.Free;
  end;
end;

function TCallerWalk.Answer(const ATarget: TTarget; ADepth,
  ALimit: Integer): string;
var
  LSb: TStringBuilder;
  LNode: TCallNode;
  LFrontier, LNext: TList<Integer>;
  LRows: TArray<TCallRow>;
  LHits: TArray<THit>;
  LCalls, LOthers, LFirstCalls, LFirstOthers, LShown, LLibrary, LLevel,
    LCutAt: Integer;
  LWho, LVias: TDictionary<string, Boolean>;
  LRoots, LDfm: TStringList;
  LT: TTarget;
  LSum, LTag, LAllVia: string;
  LLevels: TStringBuilder;
begin
  LSb := TStringBuilder.Create;
  LLevels := TStringBuilder.Create;
  LFrontier := TList<Integer>.Create;
  LNext := TList<Integer>.Create;
  LWho := TDictionary<string, Boolean>.Create;
  LVias := TDictionary<string, Boolean>.Create;
  LRoots := TStringList.Create;
  LDfm := TStringList.Create;
  LAllVia := '';
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
    LFirstCalls := 0;
    LFirstOthers := 0;
    LCutAt := 0;
    LSum := '';
    for LLevel := 1 to ADepth do
    begin
      FRows.Clear;
      for var LIdx in LFrontier do
      begin
        var LBefore := FReached;
        for var LA in FWs.Analyses do
          if FNodes[LIdx].T.Ids[LA.Index].Mid >= 0 then
            Search(LA, FNodes[LIdx]);
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
      LCalls := 0;
      LOthers := 0;
      for var LR in LRows do
      begin
        LVias.AddOrSetValue(LR.Via, True);
        if LR.Call then
        begin
          Inc(LCalls);
          if LR.Caller <> '' then
            LWho.AddOrSetValue(LR.Caller, True)
          else
            LWho.AddOrSetValue(LowerCase(LR.Hit.FilePath) + '|' + LR.Note,
              True);
        end
        else
          Inc(LOthers);
      end;
      // One symbol every row of the first level is bound to - a getter's
      // property, the virtual method an override is called through: said
      // once, above, not on every row.
      if (LLevel = 1) and (LVias.Count = 1) then
        for var LV in LVias.Keys do
          LAllVia := LV;
      if LLevel = 1 then
      begin
        LFirstCalls := LCalls;
        LFirstOthers := LOthers;
        LSum := Plural(LCalls, 'call') + ' in ' + Plural(LWho.Count, 'routine');
      end
      else
        LSum := LSum + Format('; depth %d: %d in %d', [LLevel, LCalls,
          LWho.Count]);
      if LOthers = 1 then
        LSum := LSum + ', 1 reference that does not call it'
      else if LOthers > 1 then
        LSum := LSum + Format(', %d references that do not call it',
          [LOthers]);
      if LLevel > 1 then
        LLevels.AppendLine(Format('depth %d - callers of those:', [LLevel]));
      SetLength(LHits, Length(LRows));
      for var LI := 0 to High(LRows) do
      begin
        LHits[LI] := LRows[LI].Hit;
        LTag := '';
        if LRows[LI].Callee <> '' then
          LTag := '-> ' + LRows[LI].Callee;
        if (LRows[LI].Via <> '') and (LAllVia = '') then
          LTag := Trim(LTag + ' via ' + LRows[LI].Via);
        if LRows[LI].Note <> '' then
          LTag := IfThen(LTag = '', '', LTag + ', ') + LRows[LI].Note;
        LHits[LI].Tag := LTag;
      end;
      if (Length(LHits) = 0) and (LLevel > 1) then
        LLevels.AppendLine('  none');
      AppendHitsByFile(FWs, LLevels, LHits, Max(ALimit - LShown, 0), False,
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
          Inc(LLibrary);
          Continue;
        end;
        MapToOthers(FWs, LT);
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
        LCutAt := LLevel + 1;
      if (LFrontier.Count = 0) or (LShown >= ALimit) then
        Break;
    end;

    LSb.Append(Format('callers of %s (%s:%d)', [ATarget.Name,
      FWs.RelPath(ATarget.DeclFile), ATarget.DeclLine]));
    // No call: none found - or only references that hand it on.
    if (LFirstCalls = 0) and (LFirstOthers = 0) then
      LSb.AppendLine(' - none found')
    else if LFirstCalls = 0 then
      LSb.AppendLine(Format(' - no calls, %s that %s not call it',
        [Plural(LFirstOthers, 'reference'), IfThen(LFirstOthers = 1, 'does',
        'do')]))
    else
      LSb.AppendLine(' - ' + LSum);
    if LAllVia <> '' then
    begin
      for var LThrough in FThrough do
        if LThrough.StartsWith(LAllVia + ' (') then
          LSb.AppendLine('all through ' + LThrough);
    end
    else if FThrough.Count > 0 then
      LSb.AppendLine('also through ' + String.Join(', ',
        FThrough.ToStringArray));
    LSb.Append(LLevels.ToString);
    if FCompiled > 0 then
      LSb.AppendLine(Format('(+%d in compiled units without source, not '
        + 'shown)', [FCompiled]));
    // The ends of the walk: searched, nothing found. A published method may
    // be an event handler a form binds by name.
    for var LI := 0 to FNodes.Count - 1 do
      if FNodes[LI].Found = 0 then
      begin
        if LI > 0 then
          LRoots.Add(FNodes[LI].Name);
        for var LA in FWs.Analyses do
          if FNodes[LI].T.Ids[LA.Index].Mid >= 0 then
          begin
            if IsPublishedMethod(LA, FNodes[LI].T.Ids[LA.Index].Mid,
               FNodes[LI].T.Ids[LA.Index].Sym) then
              LDfm.Add(FNodes[LI].Name);
            Break;
          end;
      end;
    if LRoots.Count > 0 then
      LSb.AppendLine('no callers found: ' + String.Join(', ',
        LRoots.ToStringArray));
    if LDfm.Count > 0 then
      LSb.AppendLine(Format('(%s: published - a form''s .dfm may bind it to '
        + 'an event, and forms are not read)', [String.Join(', ',
        LDfm.ToStringArray)]));
    for var LNote in FNotes do
      LSb.AppendLine('(' + LNote + ')');
    if ATarget.Head = 'destructor' then
      LSb.AppendLine('(a destructor runs from Free and FreeAndNil: `related '
        + 'destructions` of its class lists those)');
    if LLibrary > 0 then
      LSb.AppendLine(Format('(%s among them, not followed)',
        [Plural(LLibrary, 'library routine')]));
    if (ADepth > 1) and (LFrontier.Count > 0) and (LShown < ALimit) then
      LSb.AppendLine(Format('(%s at depth %d not searched for callers%s)',
        [Plural(LFrontier.Count, 'routine'), ADepth, IfThen(ADepth < 4,
        ' - raise `depth`', '')]));
    if LCutAt > 0 then
      LSb.AppendLine(Format('(depth %d not searched: the rows reached `limit` '
        + '- raise it, or ask for the callers of one routine above)',
        [LCutAt]));
    Result := LSb.ToString.TrimRight;
  finally
    LDfm.Free;
    LRoots.Free;
    LVias.Free;
    LWho.Free;
    LNext.Free;
    LFrontier.Free;
    LLevels.Free;
    LSb.Free;
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
  if (LT.Kind <> tkSymbol) or not ((LT.Head = 'procedure') or
     (LT.Head = 'function') or (LT.Head = 'constructor') or
     (LT.Head = 'destructor') or (LT.Head = 'operator') or
     (LT.Head = 'routine')) then
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

function ToolOutline(AWs: TMcpWorkspace; AArgs: TJSONObject): string;
const
  SECTIONS: array[TPasOutlineSection] of string = ('', 'interface',
    'implementation', 'initialization', 'finalization');
var
  LFile, LOwner, LSection, LLabel: string;
  LA: TMcpAnalysis;
  LMid, LDepth: Integer;
  LM: TPasSemaModel;
  LRows: TArray<TPasOutlineEntry>;
  LSb: TStringBuilder;
  LMembers: Boolean;
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
  LM := LA.Proj.Model(LMid);
  LRows := PasModuleOutline(LM.Tree);
  LSb := TStringBuilder.Create;
  try
    LSb.AppendLine(Format('%s (%d lines)', [AWs.RelPath(LFile),
      Length(LM.Tree.Source.Files[0].LineStarts)]));
    for var LE in LRows do
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
          LSb.AppendLine(Format('%d %s %s', [LE.Line, LE.Head, LE.Name]));
        okSection:
          LSb.AppendLine(Format('%d %s', [LE.Line, LE.Head]));
        okUses:
          LSb.AppendLine(Format('%d   %s', [LE.Line, LE.Head]));
        okInclude:
          LSb.AppendLine(Format('%d   {$I %s} %s', [LE.Line, LE.Name,
            LE.Detail]));
      else
        begin
          if (LE.Owner <> '') and not LE.IsImpl and not LMembers then
            Continue;
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
          LSb.Append(Format('%d%s%s %s', [LE.Line, StringOfChar(' ', 2 * LDepth),
            LE.Head, LLabel]));
          if LE.Detail <> '' then
          begin
            if LE.Detail.StartsWith('(') or LE.Detail.StartsWith(':') then
              LSb.Append(LE.Detail)
            else
              LSb.Append(' ' + LE.Detail);
          end;
          if (LE.FilePath <> '') and not SameText(LE.FilePath, LFile) then
            LSb.Append('  [in ' + AWs.RelPath(LE.FilePath) + ']');
          LSb.AppendLine;
        end;
      end;
    end;
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
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
    + 'name, its kind and the declaration line. Faster and more precise than '
    + 'grep for Object Pascal declarations.",'
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

    '{"name":"references","description":"Every use of a symbol across all '
    + 'projects of the group, by resolved identity rather than text: '
    + 'same-named unrelated symbols, comments and strings are not in it. '
    + 'Grouped by file and, within a file, under the routine or type each '
    + 'use sits in (TFoo.Save), with the source line - usually enough to '
    + 'answer without opening the file. Also takes a unit name (its uses '
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
    + 'caller was found for. An event handler bound in a form''s .dfm is not '
    + 'seen.",'
    + '"inputSchema":{"type":"object","properties":{' + TARGET_PROPS + ','
    + '"depth":{"type":"integer","description":"Levels of callers (default 1, '
    + 'max 4)"},'
    + '"limit":{"type":"integer","description":"Max rows over all levels '
    + '(default 150)"}}}},' +

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
    + 'and method declarations inside types (default true)"}},'
    + '"required":["file"]}},' +

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
    + 'offset, `references` lists real uses (resolved identity, not '
    + 'text), `callers` who calls a routine (through the virtual or '
    + 'interface method it implements too, to a `depth`), `related` answers '
    + 'hierarchy/override/implementation/assignment/'
    + 'creation questions, `outline` shows a unit''s structure with line '
    + 'numbers, `unit_deps` its uses graph, `diagnostics` checks name '
    + 'resolution after edits. Their rows name the routine or type they sit '
    + 'in, which usually answers the question without opening the file. '
    + 'Symbols are addressed by name (TFoo, '
    + 'TFoo.Bar, Unit.TFoo.Bar) or by file + line + name. Result paths are '
    + 'relative to ' + AWs.Root + '. The index re-reads changed files before '
    + 'every call, so results match the files on disk.';
end;

function CallTool(AWs: TMcpWorkspace; const AName: string; AArgs: TJSONObject;
  out AIsError: Boolean): string;
var
  LFresh: string;
  LSW: TStopwatch;
  LFreshMs: Int64;
begin
  AIsError := False;
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
    else if AName = 'references' then
      Result := ToolReferences(AWs, AArgs)
    else if AName = 'callers' then
      Result := ToolCallers(AWs, AArgs)
    else if AName = 'related' then
      Result := ToolRelated(AWs, AArgs)
    else if AName = 'outline' then
      Result := ToolOutline(AWs, AArgs)
    else if AName = 'diagnostics' then
      Result := ToolDiagnostics(AWs, AArgs)
    else if AName = 'unit_deps' then
      Result := ToolUnitDeps(AWs, AArgs)
    else
      raise EToolError.Create('unknown tool: ' + AName);
    if LFresh <> '' then
      Result := '(index: ' + LFresh.TrimRight([' ', ';']) + ')' + sLineBreak +
        Result;
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
  Log('tool %s: %d ms (freshness check %d ms), %d chars%s', [AName,
    LSW.ElapsedMilliseconds, LFreshMs, Length(Result), IfThen(AIsError,
    ', error', '')]);
end;

end.
