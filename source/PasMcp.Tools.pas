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
  LFile := AWs.FullPath(ArgStr(AArgs, 'file'));
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
      + 'closure (try `find` with a wildcard: *%s*)', [LSymbol,
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
// ANameVis: the visible token of its first segment.
function DeclName(LM: TPasSemaModel; ANode: Integer;
  out ANameVis: Integer): string;
var
  LChild, LPrev: Integer;
begin
  Result := '';
  ANameVis := -1;
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
  LFileId := -1;
  for var LIdx := 0 to High(LM.Tree.Source.FileNames) do
    if SameText(LM.Tree.Source.FileNames[LIdx], AFile) then
    begin
      LFileId := LIdx;
      Break;
    end;
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
        + 'a wildcard)', [ArgStr(AArgs, 'symbol')]);
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
  LFile := AWs.FullPath(ArgStr(AArgs, 'file'));
  if ArgStr(AArgs, 'file') = '' then
    raise EToolError.Create('`file` is required');
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
    LFile := AWs.FullPath(ArgStr(AArgs, 'file'));
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
    LFile := AWs.FullPath(ArgStr(AArgs, 'file'));
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
    + 'implementation, `references` lists real uses (resolved identity, not '
    + 'text), `related` answers hierarchy/override/implementation/assignment/'
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
    else if AName = 'references' then
      Result := ToolReferences(AWs, AArgs)
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
