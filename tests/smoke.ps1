# Smoke test over tests\fixtures\group: two projects sharing a unit, and a VCL
# one (AppF) whose forms bind components and handlers by name.
#
# Three parts, each exercising a different path:
#   1. CLI, shared policy - every tool once, answers checked by substring.
#   2. CLI, strict policy - the same group split into two analyses, so the
#      group-wide merge (and its de-duplication) is what answers.
#   3. MCP over stdio on a COPY of the fixture - the handshake, tools/list, a
#      call, then an edit on disk and the same kind of call again: the index
#      must notice the edit by itself. Then compile: with progress, a call
#      answered while a build runs, a cancelled build left unanswered.
#
# Line numbers of the fixture are pinned below; move a declaration there and
# update the expectation with it.
param([Parameter(Mandatory = $true)][string]$Exe)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fixture = Join-Path $here 'fixtures\group'
$group = Join-Path $fixture 'Fixture.groupproj'
$script:failures = 0

function Check([string]$Name, [string]$Text, [string[]]$Expected, [string[]]$Absent = @()) {
    foreach ($e in $Expected) {
        if (-not $Text.Contains($e)) {
            Write-Host "FAIL [$Name] missing: $e"
            $script:failures++
        }
    }
    foreach ($a in $Absent) {
        if ($Text.Contains($a)) {
            Write-Host "FAIL [$Name] unexpected: $a"
            $script:failures++
        }
    }
}

# Splits CLI output into one block per call, keyed by the call line.
function Run-Cli([string[]]$ExtraArgs) {
    # Windows PowerShell 5.1 turns every stderr line of a native command into
    # an error record, and under 'Stop' the first log line would end the test.
    $ErrorActionPreference = 'Continue'
    # `compile` builds in a directory of its own: a fresh one per run, so the
    # run's first build of a member is a first build.
    $buildDir = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-build-' + [Guid]::NewGuid().ToString('N'))
    $out = & $Exe --project $group --log none --build-dir $buildDir --script (Join-Path $here 'smoke.calls') @ExtraArgs 2>$null
    $ErrorActionPreference = 'Stop'
    Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { throw "pastree-mcp exited with $LASTEXITCODE" }
    $blocks = [ordered]@{}
    $key = $null
    foreach ($line in $out) {
        if ($line -match '^=== (\S+ .*?)  \(') { $key = $Matches[1]; $blocks[$key] = '' }
        elseif ($key) { $blocks[$key] += $line + "`n" }
    }
    return $blocks
}

function Block($Blocks, [string]$Prefix) {
    foreach ($k in $Blocks.Keys) { if ($k.StartsWith($Prefix)) { return $Blocks[$k] } }
    Write-Host "FAIL no output block for: $Prefix"
    $script:failures++
    return ''
}

# ---- 1. shared policy ---------------------------------------------------------
Write-Host '--- CLI, shared policy'
$b = Run-Cli @()
Check 'status' (Block $b 'status') @('member AppA', 'member AppB', 'member AppF', 'analysis 0:', 'every `uses` name resolved') @('analysis 1:')
Check 'find' (Block $b 'find {"query":"TCircle"}') @('Shared\uShapes.pas:21  TCircle (class)')
Check 'find wildcard' (Block $b 'find {"query":"*Circ*"') @('AppB\uAppB.pas:11  TBigCircle', 'Shared\uShapes.pas:21  TCircle')
# A declaration written over several lines is one row, whole - or, longer than
# a row, cut at a parameter boundary with its end kept.
Check 'find joined' (Block $b 'find {"query":"TWideBox.Configure"}') @("AppB\uBoxes.pas:71  TWideBox.Configure (function)  function Configure(const AFirstName: string; ASecondValue: Integer; const AThirdName: string = 'third'; AFourthFlag: Boolean = False): Boolean;")
# The outer type with the nested one left out: its member still found.
Check 'find nested' (Block $b 'find {"query":"TOuterBox.Depth"}') @('AppB\uBoxes.pas:103  TOuterBox.TInnerBox.Depth (field)') @('no declaration matches')
# By name: the identifier, not the same word in a string before it; and the
# interface side of a method resolution clause.
Check 'definition past a string' (Block $b 'definition {"file":"AppB/uBoxes.pas","line":118') @('TCountBox.BoxCount (function) declared at AppB\uBoxes.pas:112')
Check 'definition in a resolution clause' (Block $b 'definition {"file":"AppB/uBoxes.pas","line":111') @('IBoxCount.Count (function) declared at AppB\uBoxes.pas:108')
# A use in a branch this configuration does not compile: not a row, but
# named; `definition` there says why nothing resolves. A class that does not
# stream gets no form note.
Check 'references inactive' (Block $b 'references {"symbol":"TCountBox.BoxCount"}') @('2 references in 1 files', '(in branches this configuration does not compile the name is written on 1 line more, none resolved - a namesake, or a use an edit made from these rows misses: AppB\uBoxes.pas:122)') @('form file', '122  Result')
Check 'definition inactive' (Block $b 'definition {"file":"AppB/uBoxes.pas","line":122') @('AppB\uBoxes.pas:122 is in a conditional branch the analyzed configuration (Debug) does not compile - nothing there is resolved')
Check 'find joined cut' (Block $b 'find {"query":"TWideBox.Many"}') @('AppB\uBoxes.pas:74  TWideBox.Many (procedure)  procedure Many(const AAlphaName, ABetaName, AGammaName: string; ADeltaCount, AEpsilonCount, AZetaCount: Integer; const AEtaText, AThetaText, ...); virtual;')
# A name no declaration matches: what the index is, and where the name is
# written outside it - in a unit no project uses - or that it is nowhere.
Check 'find outside the index' (Block $b 'find {"query":"OrphanRoutine"}') @('no declaration matches `OrphanRoutine` among the ', ' units indexed - what the 3 projects of Fixture.groupproj compile: 13 of their own, ', "``OrphanRoutine`` is written in 1 file(s) that no indexed project uses - no tool here sees them:`n  AppB\uOrphan.pas:8  procedure OrphanRoutine;")
Check 'find nowhere' (Block $b 'find {"query":"NothingAnywhere"}') @('no declaration matches `NothingAnywhere` among the ', 'no Pascal file outside them writes `NothingAnywhere` either (1 searched, under the group directory')
Check 'definition' (Block $b 'definition {"symbol":"TCircle.Area"') @('declared at Shared\uShapes.pas:26', 'implemented at Shared\uShapes.pas:53', 'Result := Pi * FRadius * FRadius;')
Check 'source' (Block $b 'source {"symbol":"TCircle.Area"}') @('TCircle.Area (function) implemented at Shared\uShapes.pas:53-56', "53  function TCircle.Area: Double;`n54  begin", "56  end;`n") @('declared at')
Check 'source both' (Block $b 'source {"symbol":"TCircle.Area", "part"') @('TCircle.Area (function) declared at Shared\uShapes.pas:26', "26      function Area: Double; override;`nimplemented at Shared\uShapes.pas:53-56")
Check 'source type' (Block $b 'source {"symbol":"TCircle"}') @('TCircle (class) declared at Shared\uShapes.pas:21-28', '21    TCircle = class(TShape)', '28    end;')
Check 'source limit' (Block $b 'source {"symbol":"TSquare"') @('TSquare (class) declared at Shared\uShapes.pas:30-36', "31    private`n... 5 more lines, to line 36")
# The comment directly above comes with it; the blank line above that stops it.
Check 'source comment' (Block $b 'source {"symbol":"RunB"}') @('RunB (procedure) implemented at AppB\uAppB.pas:26-32', "25  // Project B's run", '32  end;') @('24  ')
# No body to show: the declaration, and why.
Check 'source abstract' (Block $b 'source {"symbol":"TShape.Area"}') @('TShape.Area (function) declared at Shared\uShapes.pas:17', 'abstract, no body')
Check 'source interface' (Block $b 'source {"symbol":"IShape.Area"}') @('declared at Shared\uShapes.pas:12', 'an interface method, no body')
Check 'source unit' (Block $b 'source {"symbol":"uShapes"}') @('is a unit - `outline` shows its structure')
# A local has no name to find it by; by position it has a source like any other.
Check 'source local' (Block $b 'source {"file"') @('LShape (var) declared at Shared\uShapes.pas:71', '71    LShape: IShape;')
# members: by the type declaring each, under its visibility section. Seen from
# TDerived's own methods: its ancestor's private field (same unit) but not the
# strict private one; an override, and the property republished, once at the
# lowest type; the ancestor's overloads beside the descendant's; TObject, a
# library type, counted.
Check 'members' (Block $b 'members {"symbol":"TDerived"}') @('TDerived <- TBase <- TObject (AppA\uMembers.pas:31): 8 members', "TDerived  AppA\uMembers.pas`n  protected`n    33  procedure Guarded; override;", '38  property Count;  [type Integer]', "TBase  AppA\uMembers.pas`n  private`n    19  FCount: Integer;", "25  procedure Add(AValue: Integer); overload;`n    26  procedure Add(const AText: string); overload;", '(library ancestors, not listed - `library: true` lists them: TObject ', '(+1 not reachable from its own methods') @('FSecret', '21  procedure Guarded', '27  procedure Reset', '28  property Count')
Check 'members public' (Block $b 'members {"symbol":"TDerived", "visibility":"public"}') @('5 members, public and published only', '35  procedure Add(AValue: Double); overload;', '(+5 protected or private, not listed') @('Guarded', 'FCount', 'GetCount')
Check 'members all' (Block $b 'members {"symbol":"TDerived", "visibility":"all"') @('2 fields, every visibility', "  strict private`n    17  FSecret: Integer;`n  private`n    19  FCount: Integer;")
# An ancestor in another unit: its private field is out of reach, its
# overridden method listed once.
Check 'members other unit' (Block $b 'members {"symbol":"TBigCircle"}') @('4 members', "TBigCircle  AppB\uAppB.pas`n  public`n    13  function Area: Double; override;", "TCircle  Shared\uShapes.pas`n  public`n    25  constructor Create(ARadius: Double);", '18  function Describe: string; virtual;', 'TInterfacedObject ', '(+1 not reachable from its own methods') @('23  FRadius', '26  function Area', '17  function Area')
# A variable: the members of its type that code in its unit can use.
Check 'members var' (Block $b 'members {"file"') @('LShape (var) is a TShape <- TInterfacedObject <- TObject (Shared\uShapes.pas:15): 2 members', '17  function Area: Double; virtual; abstract;') @('QueryInterface')
Check 'members streams' (Block $b 'members {"symbol":"TPanelModel"}') @("TPanelModel  AppA\uMembers.pas`n  published`n    44  Source: TComponent;", '45  procedure SourceChange(Sender: TObject);', 'TPersistent ')
Check 'members library' (Block $b 'members {"symbol":"IShape"') @('IShape <- IInterface (Shared\uShapes.pas:10): 4 members', "IShape  Shared\uShapes.pas`n  12  function Area: Double;", 'function QueryInterface(', 'function _AddRef: Integer; stdcall;') @('(library ancestors')
Check 'members none match' (Block $b 'members {"symbol":"TCircle", "match"') @('no members named like *Nothing*')
Check 'members empty' (Block $b 'members {"symbol":"TEmpty"}') @('TEmpty (AppA\uMembers.pas:48): no members') @('(library')
Check 'members not a type' (Block $b 'members {"symbol":"RunA"}') @('RunA is a procedure - `members` takes a type')
Check 'members joined' (Block $b 'members {"symbol":"TWideBox"}') @("  public`n    71  function Configure(const AFirstName: string; ASecondValue: Integer; const AThirdName: string = 'third'; AFourthFlag: Boolean = False): Boolean;`n", '74  procedure Many(const AAlphaName, ABetaName, AGammaName: string; ADeltaCount, AEpsilonCount, AZetaCount: Integer; const AEtaText, AThetaText, ...); virtual;')
# A field whose type is written in place has no members: said, not an error.
Check 'members in-place array' (Block $b 'members {"symbol":"TBufRec.Buf"}') @('TBufRec.Buf (field) is `array[0..3] of Byte` - a type written in place, with no members')
Check 'members in-place string' (Block $b 'members {"symbol":"TBufRec.Code"}') @('TBufRec.Code (field) is `string[6]` - a type written in place, with no members')
# "AppA\tuAppA.pas" in JSON is a tab, not a backslash: say so, not "invalid characters in path".
Check 'control character' (Block $b 'outline {"file":"AppA') @('`file` holds a control character (#9)')
Check 'references' (Block $b 'references {"symbol":"TShape.Area"}') @('1 references in 1 files', "  RunA`n    22  Writeln(LShape.Describe")
Check 'references by position' (Block $b 'references {"file":"AppA\\uAppA.pas"') @('TCircle.Radius (property)', '21  TCircle(LShape).Radius := 3;')
# A row in no routine or type (a uses clause) stays at the file level.
Check 'references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files', 'AppB\AppB.dpr', "AppA\uAppA.pas`n  13  uShapes;")
# Rows under what they sit in: a member declaration under its class, a
# statement under its routine, two uses on one line under one heading.
# A line naming it twice is one row; the header counts occurrences.
Check 'references grouped' (Block $b 'references {"symbol":"TCircle.FRadius"}') @('5 references in 1 files', "  TCircle`n    27  property Radius: Double read FRadius write FRadius;`n  TCircle.Create", "  TCircle.Create`n    50  FRadius := ARadius;", "  TCircle.Area`n    55  Result := Pi * FRadius * FRadius;") @("FRadius;`n    55  ", "FRadius;`n    27  ")
# A class's own implementation headers are not uses, but a rename changes
# them: counted and pointed at, not listed.
Check 'references class headers' (Block $b 'references {"symbol":"TCircle"}') @('3 references in 2 files', '(+2 implementation headers of its own methods name it, not listed: Shared\uShapes.pas:47, Shared\uShapes.pas:53 - a rename changes them too)') @('47  constructor TCircle.Create')
# A bare redeclaration's rows are the property it republishes: said.
Check 'references republished' (Block $b 'references {"file":"AppA/uMembers.pas","line":38,"name":"Count"}') @("TDerived.Count (property) declared at AppA\uMembers.pas:38 - 1 references in 1 files; no form file sets it`n(a bare redeclaration: it republishes TBase.Count (AppA\uMembers.pas:28) - the rows are that property's uses, through every class)")
# What the form files bind by name, under the component each line belongs to:
# a handler no code calls, bound by a form and by the inherited form's own
# component; a component named by its object line and by another's property;
# a handler the host sets on an inline frame's button; a module's component
# named through the module; a binary form file, said so; and a published
# method no form binds, which is the answer and says it.
Check 'references form handler' (Block $b 'references {"symbol":"TfrmMain.btnSaveClick"}') @('3 references in 2 files, 3 of them in form files', "AppF\uChildForm.dfm`n  chkConfirm`n    14  OnClick = btnSaveClick`n  grpTools`n    25  OnClick = btnSaveClick", "AppF\uMainForm.dfm`n  btnSave`n    39  OnClick = btnSaveClick")
Check 'references form component' (Block $b 'references {"symbol":"TfrmMain.edtName"}') @('4 references in 3 files, 3 of them in form files', "AppF\uChildForm.dfm`n  16  inherited edtName: TEdit", "  lblName`n    21  FocusControl = edtName`n  23  object edtName: TEdit", "  TfrmMain.NameChange`n    53  ")
Check 'references form inline' (Block $b 'references {"symbol":"TfrmMain.fraName1btnClearClick"}') @("  fraName1.btnClear`n    48  OnClick = fraName1btnClearClick")
Check 'references form module' (Block $b 'references {"symbol":"TdmData.pmActions"}') @("AppF\uData.dfm`n  4  object pmActions: TPopupMenu", "  btnSave`n    37  PopupMenu = dmData.pmActions")
# A module's class: other forms reach its components through its Name.
Check 'references module name' (Block $b 'references {"symbol":"TdmData"}') @('(other forms reach its components through its Name `dmData` on 1 form line: AppF\uMainForm.dfm:37 - renaming the module''s root, or the component, breaks them at load)')
Check 'references form binary' (Block $b 'references {"symbol":"TfrmBinary.btnBinaryClick"}') @("AppF\uBinaryForm.dfm  (binary - lines of its text conversion)`n  btnBinary`n    21  OnClick = btnBinaryClick")
Check 'references form none' (Block $b 'references {"symbol":"TfrmMain.NeverBound"}') @('0 references in 0 files; no form file names it', '(AppF\uMainForm.dfm names it only after the root''s `end` (from line 52), which the compiler drops - no form binds it; a stray `end`?)')
Check 'references no form note' (Block $b 'references {"symbol":"TShape.Area"}') @() @('form file')
# No use by name, called through what it overrides and implements: said, with
# the count `callers` finds - a bare 0 reads as dead code. A routine nothing
# reaches either way gets no such line.
Check 'references through' (Block $b 'references {"symbol":"TBigCircle.Area"}') @('TBigCircle.Area (function) declared at AppB\uAppB.pas:13 - 0 references in 0 files', '(none by name - `callers` finds 2 calls through TCircle.Area (virtual), TShape.Area (virtual), IShape.Area (interface): a call written against those runs this one)')
Check 'references through none' (Block $b 'references {"symbol":"TfrmMain.NeverBound"}') @() @('none by name')
# A published property's form lines: TReader sets it by name, so renaming or
# removing it fails when the form loads. One no form sets says so.
Check 'references form property' (Block $b 'references {"symbol":"TfraName.Title"}') @('1 references in 1 files, 1 of them in form files', "AppF\uChildForm.dfm`n  fraName1`n    32  Title = 'Child'")
Check 'references form property none' (Block $b 'references {"symbol":"TfraName.Note"}') @('0 references in 0 files; no form file sets it')
Check 'impact form property' (Block $b 'impact {"symbols":["TfraName.Title"]}') @('uses - none in code, 1 form line', "  fraName1`n    32  Title = 'Child'")
Check 'descendants' (Block $b 'related {"relation":"descendants"') @('  11  TBigCircle <- TCircle', "  21  TCircle`n", "  30  TSquare`n") @('<- TShape')
# A class-reference type means the class it refers to, and says so.
Check 'descendants metaclass' (Block $b 'related {"relation":"descendants", "symbol":"TShapeBoxClass"}') @('descendants of TShapeBox (AppB\uBoxes.pas:13): 1', '(TShapeBoxClass is `class of TShapeBox` - the answer is for TShapeBox)', '26  TBigBox')
# A declaration row whose [tag] names its type gets no heading.
Check 'overrides' (Block $b 'related {"relation":"overrides"') @('[TShape introduces]', '26  [TCircle override]  function Area', "  35  [TSquare override]`n", '[TBigCircle override]', "Shared\uShapes.pas`n  17  [TShape introduces]")
Check 'implementors' (Block $b 'related {"relation":"implementations", "symbol":"IShape"}') @('[TShape]')
Check 'implementations' (Block $b 'related {"relation":"implementations", "symbol":"IShape.Area"}') @('[TShape implements]')
Check 'assignments' (Block $b 'related {"relation":"assignments"') @("  TCircle.Create`n    50  FRadius := ARadius;")
Check 'creations' (Block $b 'related {"relation":"creations"') @("  RunA`n    19  LShape := TCircle.Create(2);")
Check 'destructions' (Block $b 'related {"relation":"destructions"') @("  RunA`n    24  FreeAndNil(LShape);")
# callers: through the virtual method it overrides and the interface method
# it implements, a named inherited; then level by level to each main block.
Check 'callers' (Block $b 'callers {"symbol":"TCircle.Area"}') @('callers of TCircle.Area (Shared\uShapes.pas:26) - 3 calls in 3 routines', 'also through TShape.Area (virtual), IShape.Area (interface)', "  RunA`n    22  [via TShape.Area]  Writeln", "  TBigCircle.Area`n    22  Result := 2 * inherited Area;", "  TotalArea`n    75  [via IShape.Area]")
Check 'callers depth' (Block $b 'callers {"symbol":"TCircle.Area", "depth":3}') @('depth 2: 2 in 2; depth 3: 1 in 1', "AppA\AppA.dpr`n  10  [-> RunA, main block]  RunA;", "  RunB`n    31  [-> TotalArea]", "AppB\AppB.dpr`n  13  [-> RunB, main block]")
# A getter reached through its property; a handler only assigned: not a call,
# a level that finds nothing, the .dfm note.
Check 'callers getter' (Block $b 'callers {"symbol":"TShapeBox.GetItem"') @('all through TShapeBox.Item (property read)', "  TShapeBox.BoxClick`n    53  if Item <> nil then", '43  [-> TShapeBox.BoxClick, not a call]  FOnChange := BoxClick;', 'no callers found: TShapeBox.BoxClick', '(TShapeBox.BoxClick: published') @('54  ')
Check 'callers setter' (Block $b 'callers {"symbol":"TShapeBox.SetItem"}') @('all through TShapeBox.Item (property write)', '54  Item := nil;') @('53  ')
# A bare inherited names nothing a reference search finds; an override is
# called through its ancestor.
Check 'callers inherited' (Block $b 'callers {"symbol":"TShapeBox.Changed"}') @('2 calls in 2 routines', "  TBigBox.Changed`n    59  inherited;")
Check 'callers override' (Block $b 'callers {"symbol":"TBigBox.Changed"}') @('all through TShapeBox.Changed (virtual)', "  TShapeBox.SetItem`n    44  Changed;") @('59  ')
Check 'callers none' (Block $b 'callers {"symbol":"NeverCalled"}') @('callers of NeverCalled (AppB\uBoxes.pas:31) - none found')
Check 'callers not a routine' (Block $b 'callers {"symbol":"TCircle"}') @('TCircle is a class - `callers` takes a routine')
Check 'callers outside the index' (Block $b 'callers {"symbol":"OrphanRoutine"}') @('no declaration named `OrphanRoutine` among the ', 'a local or a parameter is addressed by', 'AppB\uOrphan.pas:8  procedure OrphanRoutine;')
# A handler's form bindings are rows under the component whose event runs it:
# one no code calls, one called and bound, one bound nowhere (the empty case,
# which says the forms were read), and a binding at depth 2 - the button a
# chain of calls starts from. No row of another answer is taken for one.
Check 'callers form only' (Block $b 'callers {"symbol":"TfrmMain.btnSaveClick"}') @('- no calls, 3 form bindings - an event of the component runs it', "AppF\uChildForm.dfm`n  chkConfirm`n    14  OnClick = btnSaveClick`n  grpTools`n    25  OnClick = btnSaveClick", "AppF\uMainForm.dfm`n  btnSave`n    39  OnClick = btnSaveClick")
Check 'callers form and code' (Block $b 'callers {"symbol":"TfrmMain.NameChange"}') @('- 2 calls in 2 routines, 1 form binding', "  edtName`n    29  OnChange = NameChange", "  TfrmMain.fraName1btnClearClick`n    60  NameChange(Sender);")
Check 'callers form none' (Block $b 'callers {"symbol":"TfrmMain.NeverBound"}') @('- none found', '(TfrmMain.NeverBound: published, and no form file binds it either)', '(AppF\uMainForm.dfm names it only after the root''s `end` (from line 52)')
Check 'callers form depth' (Block $b 'callers {"symbol":"TfrmMain.Save", "depth":2}') @('- 1 call in 1 routine; depth 2: 3 form bindings', "  TfrmMain.btnSaveClick`n    47  Save;", "  btnSave`n    39  [-> TfrmMain.btnSaveClick]")
Check 'callers no binding' (Block $b 'callers {"symbol":"TShapeBox.Changed"}') @() @('form binding')
# A handler the descendant redeclares, bound only in its ancestor's form: a
# TfrmChild reads uMainForm.dfm too, and its MethodAddress finds its own.
Check 'callers ancestor form' (Block $b 'callers {"symbol":"TfrmChild.FormCreate"}') @('- no calls, 1 form binding', "AppF\uMainForm.dfm`n  frmMain (root)`n    13  [ancestor's form]  OnCreate = FormCreate")
# callees: each routine a body reaches, at its declaration. A virtual call on
# a TShape may run every override below it (project B's too); a property
# write to a field calls nothing.
Check 'callees' (Block $b 'callees {"symbol":"RunA"}') @('callees of RunA (AppA\uAppA.pas:15-26) - 4 calls reaching 7 routines', "  TShape`n    17  [at 22]  function Area: Double; virtual; abstract;", "  TCircle`n    25  [at 19]  constructor Create(ARadius: Double);`n    26  [at 22 via TShape.Area]  function Area: Double; override;", "AppB\uAppB.pas`n  TBigCircle`n    13  [at 22 via TShape.Area]", '[at 24]  procedure FreeAndNil(', '(built-ins called: Writeln)') @('property Radius', 'library routine')
# An interface call: every method implementing it, overrides included.
Check 'callees interface' (Block $b 'callees {"symbol":"TotalArea"}') @('1 call reaching 5 routines', "  IShape`n    12  [at 75]  function Area: Double;", '17  [at 75 via IShape.Area]', '26  [at 75 via IShape.Area]', '35  [at 75 via IShape.Area]', "  TBigCircle`n    13  [at 75 via IShape.Area]")
# Through a property to its getter and setter; then what the setter calls: a
# handler handed on, a virtual method and the override the class may run.
Check 'callees depth' (Block $b 'callees {"symbol":"TShapeBox.BoxClick", "depth":2}') @('2 calls reaching 2 routines; depth 2: 1 call reaching 3', '17  [at 53 via TShapeBox.Item]  function GetItem: TObject;', '18  [at 54 via TShapeBox.Item]  procedure SetItem(AValue: TObject);', 'depth 2 - what those call:', '20  [TShapeBox.SetItem at 44]  procedure Changed; virtual;', '22  [TShapeBox.SetItem at 43, not a call]', '28  [TShapeBox.SetItem at 44 via TShapeBox.Changed]', 'calling nothing: TShapeBox.GetItem')
Check 'callees inherited' (Block $b 'callees {"symbol":"TBigBox.Changed"}') @("  TShapeBox`n    20  [at 59]  procedure Changed; virtual;") @('via')
# A getter, then a virtual call on what it returns; an overload; a nested
# routine, which calls through a method pointer.
Check 'callees runner' (Block $b 'callees {"symbol":"TRunner.Run"') @('5 calls reaching 5 routines', '58  [at 124, 125 via TRunner.Base]  function GetBase: TBase;', '36  [at 124 via TBase.Reset]  procedure Reset; override;', '26  [at 125]  procedure Add(const AText: string); overload;', "  TRunner.Run`n    117  [at 126]  procedure Finish;", '[TDerived.Reset at 101]  procedure Reset; virtual;', '[TBase.Add at 82]  procedure Add(AValue: Integer); overload;', '[TRunner.GetBase at 111]  constructor Create;', 'FOnDone (TRunner.Run.Finish at 120)')
# An indexed property: written, its setter runs - from both ends.
Check 'callees indexed' (Block $b 'callees {"symbol":"FillSlots"}') @('2 calls reaching 2 routines', '133  [at 150 via TSlots.Slots]  function GetSlot(I: Integer): TBase;', '134  [at 150 via TSlots.Slots]  procedure SetSlot(I: Integer; AValue: TBase);')
Check 'callers indexed' (Block $b 'callers {"symbol":"TSlots.SetSlot"}') @('1 call in 1 routine', 'all through TSlots.Slots (property write)', "  FillSlots`n    150  ASlots.Slots[0] := ASlots.Slots[1];")
Check 'callees none' (Block $b 'callees {"symbol":"NeverCalled"}') @('callees of NeverCalled (AppB\uBoxes.pas:62-64) - none found')
Check 'callees abstract' (Block $b 'callees {"symbol":"TShape.Area"}') @('TShape.Area: abstract, no body')
Check 'callees not a routine' (Block $b 'callees {"symbol":"TCircle"}') @('TCircle is a class - `callees` takes a routine')
# impact: the members a change reaches, the declarations it touches with what
# they are called through, their callers or uses.
Check 'impact' (Block $b 'impact {"symbol":"TCircle.Area"}') @('impact of TCircle.Area', 'members to build and test: AppA, AppB (not reached: AppF)', "Shared\uShapes.pas`n  26  TCircle.Area (function) - overrides TShape.Area; also through IShape.Area (interface); overridden in TBigCircle (AppB\uAppB.pas:13)", 'callers - 3 calls in 3 routines', "  RunA`n    22  [via TShape.Area]", "  TotalArea`n    75  [via IShape.Area]")
# A unit of one project reaches that project alone.
Check 'impact one member' (Block $b 'impact {"symbol":"NeverCalled"}') @('members to build and test: AppB (not reached: AppA, AppF)', "AppB\uBoxes.pas`n  31  NeverCalled (procedure)", 'callers - none found') @('no callers found')
# A handler no code calls: its form bindings are what the change reaches.
Check 'impact form handler' (Block $b 'impact {"symbol":"TfrmMain.btnSaveClick"}') @('members to build and test: AppF (not reached: AppA, AppB)', 'callers - no calls, 3 form bindings - an event of the component runs it', "AppF\uMainForm.dfm`n  btnSave`n    39  OnClick = btnSaveClick")
# A component's uses: the code's and its form lines - its object line and a
# FocusControl naming it.
Check 'impact form component' (Block $b 'impact {"symbols":["TfrmMain.edtName"]}') @('uses - 1 in 1 routine, 3 form lines', "AppF\uMainForm.dfm`n  lblName`n    21  FocusControl = edtName`n  23  object edtName: TEdit")
Check 'impact unit' (Block $b 'impact {"symbol":"uMembers"}') @('members to build and test: AppA (not reached: AppB, AppF)', 'AppA\uMembers.pas - used by 1 unit: AppA') @('callers')
# A field: its uses, through the property that reads and writes it too.
Check 'impact field' (Block $b 'impact {"symbol":"TCircle.FRadius"}') @('23  TCircle.FRadius (field) - also through TCircle.Radius (property)', 'uses - 4 in 3 routines', "  RunA`n    21  [via TCircle.Radius]", "  TCircle.Create`n    50  FRadius := ARadius;")
# Several roots: a row names the one it reaches, a file of fewer members
# says which, a published member nothing calls gets the form note.
Check 'impact symbols' (Block $b 'impact {"symbols":["TShapeBox.BoxClick"') @("AppA\uMembers.pas  [AppA]`n  44  TPanelModel.Source (field)", "Shared\uShapes.pas`n  12  IShape.Area (function) - implemented in TShape (Shared\uShapes.pas:17)", '43  [-> TShapeBox.BoxClick, not a call]', '75  [-> IShape.Area]', 'no callers found: TShapeBox.BoxClick', 'no uses found: TPanelModel.Source', '(TPanelModel.Source: published, and no form file names it either)')
Check 'impact depth' (Block $b 'impact {"symbols":["TCircle.Area", "NeverCalled"]') @('callers - 3 calls in 3 routines; depth 2: 2 in 2', '22  [-> TCircle.Area via TShape.Area]', 'depth 2 - callers of those:', '10  [-> RunA, main block]', 'no callers found: NeverCalled')
# A diff: its lines to declarations, a uses clause, a removed routine, a
# changed interface section and who uses it, a file no project compiles. A
# member edited in a class is the member, not the class.
Check 'impact diff' (Block $b 'impact {"diff":"diff --git') @('impact of the diff - 5 files, 3 declarations changed', 'members to build and test: AppA, AppB (not reached: AppF)', "AppA\uAppA.pas  [AppA]`n  12  uses clause", "AppB\uAppB.pas  [AppB]`n  removed: Obsolete (procedure) - nothing unresolved names it", '37  TShapeBox.GetItem (function) - also through TShapeBox.Item (property read)', 'Shared\uShapes.pas - interface changed, used by 3 units: AppB, uAppA, uAppB', "  27  TCircle.Radius (property)`n  55  TCircle.Area (function)", 'other files, not Pascal source: README.md', 'callers and uses - 5 in 4 routines', '21  [-> TCircle.Radius]', '53  [-> TShapeBox.GetItem via TShapeBox.Item]') @('TCircle (class)')
# A field removed from a class is named, and the class is not a root.
Check 'impact removed field' (Block $b 'impact {"diff":"--- a/AppA/uMembers.pas') @('no declaration changed', 'AppA\uMembers.pas - interface changed, used by 1 unit: AppA', 'removed: FGone (field) - nothing unresolved names it') @('TBase (class)', 'uses -')
Check 'impact comments' (Block $b 'impact {"diff":"--- a/Shared/uShapes.pas\n+++ b/Shared/uShapes.pas\n@@ -4 ') @('no declaration changed', 'Shared\uShapes.pas (comments only)')
# A diff of another state than the file on disk is refused, not misread.
Check 'impact mismatch' (Block $b 'impact {"diff":"--- a/Shared/uShapes.pas\n+++ b/Shared/uShapes.pas\n@@ -55 ') @('the diff does not match the file on disk: line 55 reads `Result := Pi * FRadius * FRadius;`') @('TCircle.Area (function)')
Check 'impact not a diff' (Block $b 'impact {"diff":"not a diff"}') @('no file in `diff`')
Check 'impact nothing' (Block $b 'impact {}') @('give `diff`')
# compile: MSBuild for AppA (its .dproj), dcc directly for AppB (a bare .dpr).
# The first build has nothing to compare with: a warning in a file this
# session did not change is counted, not listed. The second compiles only the
# program - uMembers is not recompiled, so its warning is not reported again,
# and not gone either.
Check 'compile' (Block $b 'compile {"member":"AppA"}') @('compile AppA (Win32 Debug): built in', '278 lines compiled', 'AppA-Win32-Debug\exe\AppA.exe', 'first build here: every unit compiled', 'warnings - none in files changed this session (1 elsewhere, not listed)')
Check 'compile again' (Block $b 'compile {"member":"AppA", "limit"') @('compile AppA (Win32 Debug): built in', '13 lines compiled', 'no errors, warnings or hints') @('first build here')
Check 'compile bare dpr' (Block $b 'compile {"member":"AppB"}') @('compile AppB (Win32): built in', 'AppB-Win32\exe\AppB.exe', 'first build here', 'no errors, warnings or hints')
# The forms member: dcc converts its text form files to binary as it links
# them, so a malformed one fails here; the binary one is linked as it is.
Check 'compile forms' (Block $b 'compile {"member":"AppF"}') @('compile AppF (Win32): built in', 'AppF-Win32\exe\AppF.exe', 'no errors, warnings or hints')
Check 'compile file' (Block $b 'compile {"file"') @('compile - 2 members, those compiling Shared\uShapes.pas', '  AppA (Win32 Debug): built in', '  AppB (Win32): built in', 'no errors, warnings or hints')
# A rebuild recompiles uMembers: its warning again, known, so not new.
Check 'compile rebuild' (Block $b 'compile {"member":"AppA", "rebuild"') @('278 lines compiled', "warnings - 1 in the group's files:`nAppA\uMembers.pas", '  37  W1055 PUBLISHED caused RTTI', "to be added to type 'TDerived' (in TDerived)`n        published") @('[new]')
Check 'compile no member' (Block $b 'compile {"member":"NoSuch"}') @('no member named NoSuch - the group has: AppA, AppB, AppF')
Check 'compile bad show' (Block $b 'compile {"show"') @('`show` is new, warnings or all')
Check 'compile nothing changed' (Block $b 'compile {}') @('no file has changed since the server started - name the `member` to build (the group has: AppA, AppB, AppF)')
# form: a form's components, their events and the components they name,
# with the lines of the form file. An inline frame's child under the frame,
# its handler the host's; a data module; a binary form file, said so. An
# inherited form merged with its ancestor's file: a reopened component is
# the descendant's row, its rebound event the descendant's method, a row
# from the ancestor names its file. No form: said, for a unit and a class.
Check 'form' (Block $b 'form {"file":"AppF/uMainForm.pas"}') @('form frmMain: TfrmMain - AppF\uMainForm.dfm', '5 components, 4 events bound, 2 references to components', "1  frmMain: TfrmMain`n13    OnCreate -> TfrmMain.FormCreate`n15    lblName: TLabel`n21      FocusControl -> edtName", '37      PopupMenu -> dmData.pmActions (TdmData.pmActions)', "41    fraName1: TfraName (inline frame)`n47      btnClear: TButton`n48        OnClick -> TfrmMain.fraName1btnClearClick") @('Caption', 'Left')
Check 'form inherited' (Block $b 'form {"symbol":"TfrmChild"}') @('form frmChild: TfrmChild - AppF\uChildForm.dfm; inherits AppF\uMainForm.dfm', '8 components, 6 events bound, 3 references to components, 1 cleared', "28    lblHint: TLabel (no field)`n29      FocusControl -> fraName1.edtHint (a component the form files create, with no field)", "16    edtName: TEdit`n17      OnChange -> nil (cleared: TfrmMain.NameChange, which uMainForm.dfm binds, does not run)", "19    grpTools: TButtonGroup (no field)`n22      Items[0].OnClick -> TfrmChild.ChildSaveClick`n25      Items[1].OnClick -> TfrmMain.btnSaveClick", '13    OnCreate -> TfrmChild.FormCreate  (uMainForm.dfm)', "4    btnSave: TButton`n37      PopupMenu -> dmData.pmActions (TdmData.pmActions)  (uMainForm.dfm)`n5      OnClick -> TfrmChild.ChildSaveClick`n", "7    chkConfirm: TCheckBox`n14      OnClick -> TfrmMain.btnSaveClick") @('TfrmMain.btnSaveClick  (uMainForm.dfm)')
Check 'form module' (Block $b 'form {"file":"AppF/uData.dfm"}') @("4    pmActions: TPopupMenu`n7      miSave: TMenuItem`n9        OnClick -> TdmData.miSaveClick")
Check 'form binary' (Block $b 'form {"file":"AppF/uBinaryForm.pas"}') @('AppF\uBinaryForm.dfm (binary - lines of its text conversion)', '21      OnClick -> TfrmBinary.btnBinaryClick')
Check 'form none' (Block $b 'form {"file":"AppA/uAppA.pas"}') @('AppA\uAppA.pas has no form file - no .dfm or .fmx beside it')
Check 'form not a form class' (Block $b 'form {"symbol":"TCircle"}') @('TCircle has no form file of its own')
# A form file with no unit beside it: said so, not "not part of any project".
Check 'form orphan' (Block $b 'form {"file":"AppF/uOrphanForm.dfm"}') @('no unit beside AppF\uOrphanForm.dfm - an orphan form file, which no project compiles')
Check 'outline' (Block $b 'outline {"file":"Shared') @('21  type TCircle = class', '27    property Radius: Double', '53  function TCircle.Area: Double', '40 implementation')
# A parameter list whole: PasTree's outline cuts one at 80 characters.
# Over `limit`: the types' members go first, said; still over, cut and said.
# Asked for members, they stay and the rows are cut. A unit with no
# declarations: its heads alone.
Check 'outline limit' (Block $b 'outline {"file":"Shared/uShapes.pas", "limit"') @('(24 rows in all - the 10 member declarations of its types are left out: `owner` lists one type''s', "30  type TSquare = class`n38  function TotalArea", '... 2 more rows (raise `limit`') @('property Radius')
Check 'outline limit members' (Block $b 'outline {"file":"Shared/uShapes.pas", "members"') @("10  type IShape = interface`n12    function Area: Double`n15  type TShape = class`n... 19 more rows") @('left out')
Check 'outline no declarations' (Block $b 'outline {"file":"AppA/AppA.dpr"}') @("AppA\AppA.dpr (12 lines)`n1 program AppA`n5   uses`n9 begin") @('more rows', 'left out')
Check 'outline signature' (Block $b 'outline {"file":"AppB')@("71    function Configure(const AFirstName: string; ASecondValue: Integer; const AThirdName: string = 'third'; AFourthFlag: Boolean = False): Boolean`n", '85  procedure TWideBox.Many(const AAlphaName, ABetaName, AGammaName: string; ADeltaCount, AEpsilonCount, AZetaCount: Integer; const AEtaText, AThetaText, AIotaText: string)') @('...')
Check 'unit_deps' (Block $b 'unit_deps') @('uShapes is used by 3 units', 'AppB\uAppB.pas:8')
Check 'diagnostics' (Block $b 'diagnostics') @('no diagnostics')
Check 'ambiguous' (Block $b 'references {"symbol":"Area"}') @('is ambiguous - 5 declarations', 'IShape.Area', 'TBigCircle.Area')
Check 'unknown' (Block $b 'definition {"symbol":"NoSuchThing"}') @('no declaration named `NoSuchThing`', 'a local or a parameter is addressed by `file` + `line` + `name`')

# ---- 2. strict policy ---------------------------------------------------------
Write-Host '--- CLI, strict policy'
$b = Run-Cli @('--groups', 'strict')
Check 'strict status' (Block $b 'status') @('analysis 0:', 'analysis 1:')
Check 'strict references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files')
Check 'strict descendants' (Block $b 'related {"relation":"descendants"') @('descendants of TShape (Shared\uShapes.pas:15): 3', 'TBigCircle <- TCircle')
Check 'strict overrides' (Block $b 'related {"relation":"overrides"') @('overrides of TShape.Area (Shared\uShapes.pas:17): 4')
# Rows of both analyses in one walk: RunA is project A's, the rest project B's.
Check 'strict callers' (Block $b 'callers {"symbol":"TCircle.Area", "depth":3}') @('3 calls in 3 routines; depth 2: 2 in 2; depth 3: 1 in 1', '22  [via TShape.Area]', '75  [via IShape.Area]', '10  [-> RunA, main block]', '13  [-> RunB, main block]')
Check 'strict members' (Block $b 'members {"symbol":"TDerived"}') @('8 members', '19  FCount: Integer;')
# The implementations of one call, merged from both analyses: TBigCircle is
# project B's alone.
Check 'strict callees' (Block $b 'callees {"symbol":"TotalArea"}') @('1 call reaching 5 routines', "  TBigCircle`n    13  [at 75 via IShape.Area]")
# Each member's closure read from its own analysis.
Check 'strict impact' (Block $b 'impact {"symbol":"TCircle.Area"}') @('members to build and test: AppA, AppB (not reached: AppF)', 'callers - 3 calls in 3 routines')
Check 'strict impact unit' (Block $b 'impact {"symbol":"uMembers"}') @('members to build and test: AppA (not reached: AppB, AppF)')
Check 'strict impact diff' (Block $b 'impact {"diff":"diff --git') @('members to build and test: AppA, AppB (not reached: AppF)', 'AppB\uBoxes.pas  [AppB]', 'Shared\uShapes.pas - interface changed, used by 3 units: AppB, uAppA, uAppB', 'callers and uses - 5 in 4 routines')
Check 'strict compile file' (Block $b 'compile {"file"') @('compile - 2 members, those compiling Shared\uShapes.pas', '  AppA (Win32 Debug): built in', '  AppB (Win32): built in')

# ---- discovery: no --project, started in a subdirectory ------------------------------
# Registered once for every repository, the server starts wherever the session
# was opened: the nearest project file above it is the one, and the walk stops
# at the repository root.
Write-Host '--- CLI, the project found above the working directory'
$ErrorActionPreference = 'Continue'
Push-Location (Join-Path $fixture 'Shared')
try { $out = (& $Exe --log none --call status 2>&1 | ForEach-Object { "$_" }) -join "`n" }
finally { Pop-Location }
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { Write-Host "FAIL [discovery above] exited with $code"; $script:failures++ }
Check 'discovery above' $out @("project $group found above the working directory $(Join-Path $fixture 'Shared')", 'member AppF')
$noProj = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-noproj-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $noProj '.git') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $noProj 'sub') | Out-Null
$ErrorActionPreference = 'Continue'
Push-Location (Join-Path $noProj 'sub')
try { $out = (& $Exe --log none --call status 2>&1 | ForEach-Object { "$_" }) -join "`n" }
finally { Pop-Location }
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Remove-Item -Recurse -Force $noProj -ErrorAction SilentlyContinue
if ($code -ne 2) { Write-Host "FAIL [discovery none] exited with $code, not 2"; $script:failures++ }
Check 'discovery none' $out @("no .groupproj or .dproj in $(Join-Path $noProj 'sub') or above it up to $noProj\ - pass --project <file>")

# ---- 3. MCP over stdio, with an edit in between ------------------------------------
Write-Host '--- MCP over stdio'
$copy = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-' + [Guid]::NewGuid().ToString('N'))
Copy-Item -Recurse $fixture $copy
$mcpBuild = $copy + '-build'
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '--project "' + (Join-Path $copy 'Fixture.groupproj') + '" --log none --build-dir "' + $mcpBuild + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::Start($psi)
    # stderr must be drained or a chatty log blocks the server.
    $null = $proc.StandardError.ReadToEndAsync()
    $utf8 = New-Object Text.UTF8Encoding($false)
    $stdin = New-Object IO.StreamWriter($proc.StandardInput.BaseStream, $utf8)
    $stdin.AutoFlush = $true
    $stdin.NewLine = "`n"

    # Replies may come out of order - a compile's after the calls sent behind
    # it - so they are kept by id; notifications (progress) are collected in
    # $script:notes.
    $script:notes = ''
    $script:replies = @{}
    function Send([int]$Id, [string]$Method, [string]$ParamsJson) {
        $stdin.WriteLine('{"jsonrpc":"2.0","id":' + $Id + ',"method":"' + $Method + '","params":' + $ParamsJson + '}')
    }
    # Reads until the reply to $Id; returns the ids of the replies read, in
    # the order they came.
    function ReadUntil([int]$Id) {
        $seen = @()
        while ($true) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -eq $line) { throw "server closed stdout waiting for reply $Id" }
            $msg = $line | ConvertFrom-Json
            if ($null -eq $msg.id) { $script:notes += $line + "`n"; continue }
            $seen += [int]$msg.id
            $script:replies[[int]$msg.id] = $msg
            if ([int]$msg.id -eq $Id) { return ,$seen }
        }
    }
    function Rpc([int]$Id, [string]$Method, [string]$ParamsJson) {
        Send $Id $Method $ParamsJson
        $null = ReadUntil $Id
        return $script:replies[$Id]
    }
    # Line breaks as the CLI blocks have them, so one expectation reads the same
    # in both parts.
    function ToolText($Reply) { return ([string]$Reply.result.content[0].text).Replace("`r`n", "`n") }

    $r = Rpc 1 'initialize' '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}'
    Check 'initialize' ($r | ConvertTo-Json -Depth 6) @('"name":  "pastree"', 'instructions', '"tools"')
    $stdin.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    $r = Rpc 2 'tools/list' '{}'
    $names = ($r.result.tools | ForEach-Object { $_.name }) -join ','
    Check 'tools/list' $names @('status', 'find', 'definition', 'source', 'members', 'references', 'callers', 'callees', 'impact', 'compile', 'related', 'outline', 'diagnostics', 'unit_deps')
    $r = Rpc 3 'tools/call' '{"name":"related","arguments":{"relation":"creations","symbol":"TCircle"}}'
    Check 'call before edit' (ToolText $r) @('creations of TCircle', ': 1')
    if ($r.result.isError) { Write-Host 'FAIL call before edit reported isError'; $script:failures++ }

    # The edit: a second TCircle.Create in project A's unit, and a name that
    # resolves to nothing.
    $unit = Join-Path $copy 'AppA\uAppA.pas'
    $text = [IO.File]::ReadAllText($unit)
    $text = $text.Replace("    FreeAndNil(LShape);", "    FreeAndNil(LShape);`r`n    TCircle.Create(5).Free;`r`n    NoSuchName := 1;")
    [IO.File]::WriteAllText($unit, $text, $utf8)
    $r = Rpc 4 'tools/call' '{"name":"related","arguments":{"relation":"creations","symbol":"TCircle"}}'
    # The note names the file: one the agent did not edit is someone else's.
    Check 'call after edit' (ToolText $r) @('(index: re-analyzed 1 changed file(s) in ', ' ms: AppA\uAppA.pas)', 'creations of TCircle', ': 2', 'TCircle.Create(5).Free;')
    $r = Rpc 5 'tools/call' '{"name":"diagnostics","arguments":{}}'
    Check 'diagnostics after edit' (ToolText $r) @('AppA\uAppA.pas:26:5: ', "'NoSuchName' (in RunA)")
    # A diff removing a routine the edited unit still calls: impact names the
    # call that no longer resolves.
    $r = Rpc 6 'tools/call' '{"name":"impact","arguments":{"diff":"--- a/AppA/uAppA.pas\n+++ b/AppA/uAppA.pas\n@@ -7,3 +7,2 @@\n procedure RunA;\n-procedure NoSuchName;\n \n"}}'
    Check 'impact after edit' (ToolText $r) @('AppA\uAppA.pas - interface changed, used by 1 unit: AppA', 'removed: NoSuchName (procedure) - still named at AppA\uAppA.pas:26 (in RunA)')
    # compile with no arguments builds what the edited file reaches: AppA.
    # The compiler's error, under the routine, with the line; progress on the
    # way, since the call carries a progress token.
    $r = Rpc 7 'tools/call' '{"name":"compile","arguments":{},"_meta":{"progressToken":"smoke-1"}}'
    Check 'compile after edit' (ToolText $r) @('compile AppA (Win32 Debug): FAILED in', ', 1 error', "errors - 1:`nAppA\uAppA.pas`n  26  E2003 Undeclared identifier: 'NoSuchName' (in RunA)`n        NoSuchName := 1;") @('AppB')
    Check 'compile progress' $script:notes @('"method":"notifications/progress"', '"progressToken":"smoke-1"', 'compile: building AppA (Win32 Debug)')
    # The error fixed, a local left unused: the hint is new - uAppA never
    # compiled here before, and this session changed it - while uMembers,
    # compiled now for the first time too, has its warning said uncompared.
    $text = [IO.File]::ReadAllText($unit)
    $text = $text.Replace("    NoSuchName := 1;`r`n", '').Replace("  LShape: TShape;`r`n", "  LShape: TShape;`r`n  LUnused: Integer;`r`n")
    [IO.File]::WriteAllText($unit, $text, $utf8)
    $r = Rpc 8 'tools/call' '{"name":"compile","arguments":{}}'
    Check 'compile new hint' (ToolText $r) @('compile AppA (Win32 Debug): built in', 'warnings - none new (1 from units first compiled here, not compared, not listed)', "hints - 1 new:`nAppA\uAppA.pas`n  18  H2164 Variable 'LUnused' is declared but never used in 'RunA' (in RunA)`n        LUnused: Integer;") @('first build here')
    # A call sent while a build runs is answered before the build is: the
    # build has a thread of its own.
    Send 9 'tools/call' '{"name":"compile","arguments":{"member":"AppA","rebuild":true}}'
    Send 10 'tools/call' '{"name":"find","arguments":{"query":"TCircle"}}'
    $order = ReadUntil 9
    if (($order -notcontains 10) -or ($order.IndexOf(10) -gt $order.IndexOf(9))) { Write-Host "FAIL a call sent during a compile waited for it (replies: $($order -join ', '))"; $script:failures++ }
    Check 'find during compile' (ToolText $script:replies[10]) @('Shared\uShapes.pas:21  TCircle (class)')
    Check 'compile beside a call' (ToolText $script:replies[9]) @('compile AppA (Win32 Debug): built in', ' lines compiled')
    # A cancelled compile is not answered, and leaves the member buildable.
    Send 11 'tools/call' '{"name":"compile","arguments":{"member":"AppA","rebuild":true}}'
    $stdin.WriteLine('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11,"reason":"smoke"}}')
    Send 12 'tools/call' '{"name":"compile","arguments":{"member":"AppA"}}'
    $order = ReadUntil 12
    if ($order -contains 11) { Write-Host 'FAIL a cancelled compile was answered'; $script:failures++ }
    Check 'compile after a cancel' (ToolText $script:replies[12]) @('compile AppA (Win32 Debug): built in')

    # A project file changed: the workspace reloads, and the note names it.
    (Get-Item (Join-Path $copy 'AppA\AppA.dproj')).LastWriteTime = (Get-Date).AddSeconds(5)
    $r = Rpc 13 'tools/call' '{"name":"find","arguments":{"query":"TCircle"}}'
    Check 'call after a project file changed' (ToolText $r) @('(index: project file(s) changed: AppA\AppA.dproj; the workspace was reloaded)', 'Shared\uShapes.pas:21  TCircle (class)')
    # A unit deleted: its analysis is rebuilt, and the note names it.
    Remove-Item (Join-Path $copy 'AppB\uBoxes.pas')
    $r = Rpc 14 'tools/call' '{"name":"find","arguments":{"query":"TShapeBox"}}'
    Check 'call after a delete' (ToolText $r) @('(index: rebuilt in ', ' ms; deleted: AppB\uBoxes.pas)', 'no declaration matches `TShapeBox`')

    # A unit taken in by the module path (a uses clause changed), then edited:
    # the module run stamps what it took in, so the edit is seen and the note
    # names the newcomer; an include it starts to pull in, then edited; the
    # unit deleted and dropped.
    $dpr = Join-Path $copy 'AppA\AppA.dpr'
    $newUnit = Join-Path $copy 'AppA\uNewUnit.pas'
    [IO.File]::WriteAllText($newUnit, "unit uNewUnit;`r`n`r`ninterface`r`n`r`nprocedure NewOne;`r`n`r`nimplementation`r`n`r`nprocedure NewOne;`r`nbegin`r`nend;`r`n`r`nend.`r`n", $utf8)
    $text = [IO.File]::ReadAllText($dpr)
    [IO.File]::WriteAllText($dpr, $text.Replace("  uMembers in 'uMembers.pas';", "  uMembers in 'uMembers.pas',`r`n  uNewUnit in 'uNewUnit.pas';"), $utf8)
    $r = Rpc 30 'tools/call' '{"name":"find","arguments":{"query":"NewOne"}}'
    Check 'unit taken in' (ToolText $r) @('(index: re-analyzed 1 changed file(s) in ', ' ms: AppA\AppA.dpr; added: AppA\uNewUnit.pas)', 'AppA\uNewUnit.pas:5  NewOne (procedure)') @('full rebuild')
    [IO.File]::WriteAllText($newUnit, "unit uNewUnit;`r`n`r`ninterface`r`n`r`n{`$I uNewUnit.inc}`r`n`r`nprocedure NewOne;`r`nprocedure NewTwo;`r`n`r`nimplementation`r`n`r`nprocedure NewOne;`r`nbegin`r`nend;`r`n`r`nprocedure NewTwo;`r`nbegin`r`nend;`r`n`r`nend.`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $copy 'AppA\uNewUnit.inc'), "const`r`n  INC_ONE = 1;`r`n", $utf8)
    $r = Rpc 31 'tools/call' '{"name":"find","arguments":{"query":"NewTwo"}}'
    Check 'newcomer edited' (ToolText $r) @(' ms: AppA\uNewUnit.pas; added: AppA\uNewUnit.inc)', 'AppA\uNewUnit.pas:8  NewTwo (procedure)')
    [IO.File]::WriteAllText((Join-Path $copy 'AppA\uNewUnit.inc'), "const`r`n  INC_ONE = 1;`r`n  INC_TWO = 2;`r`n", $utf8)
    $r = Rpc 32 'tools/call' '{"name":"find","arguments":{"query":"INC_TWO"}}'
    Check 'newcomer include edited' (ToolText $r) @('(full rebuild)', 'AppA\uNewUnit.inc)', 'AppA\uNewUnit.inc:3  INC_TWO (const)')
    # A position in the include resolves through the unit that pulls it in.
    $r = Rpc 35 'tools/call' '{"name":"definition","arguments":{"file":"AppA/uNewUnit.inc","line":3,"name":"INC_TWO"}}'
    Check 'definition in an include' (ToolText $r) @('INC_TWO (const)', 'AppA\uNewUnit.inc:3') @('not part of any analyzed project')
    if ($r.result.isError) { Write-Host 'FAIL [definition in an include] isError'; $script:failures++ }
    # An error answer carries the note too: the re-analysis it follows is not
    # reported again, and someone else's edit may be what the error is about.
    [IO.File]::WriteAllText($newUnit, "unit uNewUnit;`r`n`r`ninterface`r`n`r`n{`$I uNewUnit.inc}`r`n`r`nprocedure NewOne;`r`n`r`nimplementation`r`n`r`nprocedure NewOne;`r`nbegin`r`nend;`r`n`r`nend.`r`n", $utf8)
    $r = Rpc 34 'tools/call' '{"name":"references","arguments":{"symbol":"NewTwo"}}'
    Check 'error answer with note' (ToolText $r) @('(index: re-analyzed 1 changed file(s) in ', ' ms: AppA\uNewUnit.pas)', 'no declaration named `NewTwo`')
    if (-not $r.result.isError) { Write-Host 'FAIL [error answer with note] not isError'; $script:failures++ }
    # A routine the interface declares and the implementation imports - the
    # Windows import units' shape: external, said, with its import line.
    [IO.File]::WriteAllText($newUnit, "unit uNewUnit;`r`n`r`ninterface`r`n`r`n{`$I uNewUnit.inc}`r`n`r`nprocedure NewOne;`r`nfunction Ticks: Cardinal; stdcall;`r`n`r`nimplementation`r`n`r`nprocedure NewOne;`r`nbegin`r`nend;`r`n`r`nfunction Ticks; external 'kernel32.dll' name 'GetTickCount';`r`n`r`nend.`r`n", $utf8)
    $r = Rpc 36 'tools/call' '{"name":"callees","arguments":{"symbol":"uNewUnit.Ticks"}}'
    Check 'callees external' (ToolText $r) @("Ticks: external - ``function Ticks; external 'kernel32.dll' name 'GetTickCount';``, no body in source - nothing to read calls from") @('no implementation found')
    Remove-Item $newUnit
    [IO.File]::WriteAllText($dpr, $text, $utf8)
    $r = Rpc 33 'tools/call' '{"name":"find","arguments":{"query":"NewOne"}}'
    Check 'newcomer deleted' (ToolText $r) @('deleted: AppA\uNewUnit.pas', 'no declaration matches `NewOne`')

    # A form file saved alone - a designer's save, another session's edit:
    # no Pascal file changed, the answer is fresh, and the note names it.
    $mainDfm = Join-Path $copy 'AppF\uMainForm.dfm'
    $dfmText = [IO.File]::ReadAllText($mainDfm)
    [IO.File]::WriteAllText($mainDfm, $dfmText.Replace("    OnChange = NameChange`r`n", "    Hint = 'name'`r`n    OnChange = NameChange`r`n"), $utf8)
    $r = Rpc 40 'tools/call' '{"name":"references","arguments":{"symbol":"TfrmMain.NameChange"}}'
    Check 'form file changed' (ToolText $r) @('(index: form file(s) changed: AppF\uMainForm.dfm)', "  edtName`n    30  OnChange = NameChange")
    # A form unit written first, its form file next - an agent's order: the
    # form file, appearing after the index listed its directory, is read, its
    # handler bound, and the note names it; then deleted.
    $appF = Join-Path $copy 'AppF\AppF.dpr'
    $appFText = [IO.File]::ReadAllText($appF)
    [IO.File]::WriteAllText((Join-Path $copy 'AppF\uLateForm.pas'), "unit uLateForm;`r`n`r`ninterface`r`n`r`nuses`r`n  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;`r`n`r`ntype`r`n  TfrmLate = class(TForm)`r`n    btnLate: TButton;`r`n    procedure btnLateClick(Sender: TObject);`r`n  end;`r`n`r`nimplementation`r`n`r`n{`$R *.dfm}`r`n`r`nprocedure TfrmLate.btnLateClick(Sender: TObject);`r`nbegin`r`nend;`r`n`r`nend.`r`n", $utf8)
    [IO.File]::WriteAllText($appF, $appFText.Replace("  uBinaryForm in 'uBinaryForm.pas' {frmBinary};", "  uBinaryForm in 'uBinaryForm.pas' {frmBinary},`r`n  uLateForm in 'uLateForm.pas' {frmLate};"), $utf8)
    $r = Rpc 41 'tools/call' '{"name":"references","arguments":{"symbol":"TfrmLate.btnLateClick"}}'
    Check 'form unit before its form' (ToolText $r) @('added: AppF\uLateForm.pas)', '0 references', 'no form file names it')
    [IO.File]::WriteAllText((Join-Path $copy 'AppF\uLateForm.dfm'), "object frmLate: TfrmLate`r`n  Caption = 'Late'`r`n  object btnLate: TButton`r`n    Caption = 'Late'`r`n    OnClick = btnLateClick`r`n  end`r`nend`r`n", $utf8)
    $r = Rpc 42 'tools/call' '{"name":"references","arguments":{"symbol":"TfrmLate.btnLateClick"}}'
    Check 'form file after its unit' (ToolText $r) @('(index: form file(s) added: AppF\uLateForm.dfm)', '1 of them in form files', "  btnLate`n    5  OnClick = btnLateClick")
    $r = Rpc 43 'tools/call' '{"name":"form","arguments":{"file":"AppF/uLateForm.pas"}}'
    Check 'form of a late form file' (ToolText $r) @('form frmLate: TfrmLate - AppF\uLateForm.dfm', "3    btnLate: TButton`n5      OnClick -> TfrmLate.btnLateClick") @('naming nothing')
    Remove-Item (Join-Path $copy 'AppF\uLateForm.dfm')
    $r = Rpc 44 'tools/call' '{"name":"callers","arguments":{"symbol":"TfrmLate.btnLateClick"}}'
    Check 'form file deleted' (ToolText $r) @('(index: form file(s) deleted: AppF\uLateForm.dfm)')
    Remove-Item (Join-Path $copy 'AppF\uLateForm.pas')
    [IO.File]::WriteAllText($appF, $appFText, $utf8)
    [IO.File]::WriteAllText($mainDfm, $dfmText, $utf8)

    # A handler removed from the code while the forms still bind it: no
    # compiler error, a form that fails to load - impact names the lines, in
    # its form and in the inherited form binding it on a component of its own.
    $unit = Join-Path $copy 'AppF\uMainForm.pas'
    $text = [IO.File]::ReadAllText($unit)
    $text = $text.Replace("    procedure btnSaveClick(Sender: TObject);`r`n", '').Replace("// Bound by uMainForm.dfm and uChildForm.dfm; no code calls it.`r`nprocedure TfrmMain.btnSaveClick(Sender: TObject);`r`nbegin`r`n  Save;`r`nend;`r`n`r`n", '')
    [IO.File]::WriteAllText($unit, $text, $utf8)
    $r = Rpc 20 'tools/call' '{"name":"impact","arguments":{"diff":"--- a/AppF/uMainForm.pas\n+++ b/AppF/uMainForm.pas\n@@ -20 +19,0 @@\n-    procedure btnSaveClick(Sender: TObject);\n@@ -44,6 +42,0 @@\n-// Bound by uMainForm.dfm and uChildForm.dfm; no code calls it.\n-procedure TfrmMain.btnSaveClick(Sender: TObject);\n-begin\n-  Save;\n-end;\n-\n"}}'
    Check 'impact removed handler' (ToolText $r) @('removed: TfrmMain.btnSaveClick (procedure) - still bound in a form, which then fails to load: AppF\uMainForm.dfm:39 (btnSave.OnClick), AppF\uChildForm.dfm:14 (chkConfirm.OnClick)') @('nothing unresolved names it')
    # The same removal seen from the form: the inherited form's own component
    # still binds the handler that is gone.
    $r = Rpc 21 'tools/call' '{"name":"form","arguments":{"symbol":"TfrmChild"}}'
    Check 'form after a removed handler' (ToolText $r) @('2 naming nothing', '14      OnClick -> btnSaveClick - no such published method: the form fails to load', '25      Items[1].OnClick -> btnSaveClick - no such published method')

    $r = Rpc 15 'tools/call' '{"name":"no_such_tool","arguments":{}}'
    if (-not $r.result.isError) { Write-Host 'FAIL unknown tool not reported as isError'; $script:failures++ }
    $r = Rpc 16 'no/such/method' '{}'
    if ($r.error.code -ne -32601) { Write-Host 'FAIL unknown method not -32601'; $script:failures++ }

    $stdin.Close()
    if (-not $proc.WaitForExit(10000)) { Write-Host 'FAIL server did not exit when stdin closed'; $script:failures++; $proc.Kill() }
}
finally {
    Remove-Item -Recurse -Force $copy -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $mcpBuild -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) FAILED"
    exit 1
}
Write-Host 'smoke test: all checks passed'
exit 0
