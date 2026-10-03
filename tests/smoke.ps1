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
Check 'status' (Block $b 'status') @('member AppA', 'member AppB', 'member AppF', 'analysis 0:', 'every `uses` name resolved', 'server: pastree-mcp ', '; pid ', 'log: none (stderr only)') @('analysis 1:', 'added by --also')
Check 'find' (Block $b 'find {"query":"TCircle"}') @('Shared\uShapes.pas:21  TCircle (class)')
Check 'find wildcard' (Block $b 'find {"query":"*Circ*"') @('AppB\uAppB.pas:11  TBigCircle', 'Shared\uShapes.pas:21  TCircle')
# A declaration written over several lines is one row, whole - or, longer than
# a row, cut at a parameter boundary with its end kept.
Check 'find joined' (Block $b 'find {"query":"TWideBox.Configure"}') @("AppB\uBoxes.pas:71  TWideBox.Configure (function)  function Configure(const AFirstName: string; ASecondValue: Integer; const AThirdName: string = 'third'; AFourthFlag: Boolean = False): Boolean;")
# The outer type with the nested one left out: its member still found.
Check 'find nested' (Block $b 'find {"query":"TOuterBox.Depth"}') @('AppB\uBoxes.pas:103  TOuterBox.TInnerBox.Depth (field)') @('no declaration matches')
# FR.1: enum values by name - bare, as TEnum.Value, a scoped one's bare name
# only when nothing else has it (TSquare stays the class: `source TSquare`).
Check 'find enum value' (Block $b 'find {"query":"tnGreen"}') @('AppB\uColors.pas:11  TTint.tnGreen (enum value)  TTint = (tnRed, tnGreen, tnBlue);') @('no declaration matches')
Check 'find scoped enum value' (Block $b 'find {"query":"TShade.TSquare"}') @('AppB\uColors.pas:14  TShade.TSquare (enum value)') @('uShapes.pas')
Check 'references enum value' (Block $b 'references {"symbol":"TTint.tnRed"}') @('TTint.tnRed (enum value) declared at AppB\uColors.pas:11 - 1 references in 1 files', "  TintName`n    25  tnRed: Result := 'red';")
Check 'references enum value unused' (Block $b 'references {"symbol":"tnBlue"}') @('TTint.tnBlue (enum value) declared at AppB\uColors.pas:11 - 0 references in 0 files')
Check 'references scoped value bare' (Block $b 'references {"symbol":"Dark"}') @('TShade.Dark (enum value) declared at AppB\uColors.pas:14 - 1 references', '    34  Result := AShade = TShade.Dark;')
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
Check 'find outside the index' (Block $b 'find {"query":"OrphanRoutine"}') @('no declaration matches `OrphanRoutine` among the ', ' units indexed - what the 3 projects of Fixture.groupproj compile: 20 of their own, ', "``OrphanRoutine`` is written in 1 file(s) that no indexed project uses - no tool here sees them:`n  AppB\uOrphan.pas:8  procedure OrphanRoutine;")
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
# FR.3: the name of an overloaded method shows each overload, told apart by
# its declaration line; `limit` counts over them all and names the rest. A
# name of namesakes in several types is still refused with the candidates.
Check 'source overloads' (Block $b 'source {"symbol":"TBase.Add"}') @('TBase.Add - 2 overloads:', 'TBase.Add (procedure, line 25) implemented at AppA\uMembers.pas:75-78', '77    Inc(FCount, AValue);', 'TBase.Add (procedure, line 26) implemented at AppA\uMembers.pas:80-83', '82    Add(Length(AText));') @('ambiguous', 'TDerived')
Check 'source overloads limit' (Block $b 'source {"symbol":"TBase.Add", "limit"') @('... 1 more lines, to line 78', '1 more not shown', 'AppA\uMembers.pas:26  TBase.Add (procedure)') @('80  ')
Check 'source one overload' (Block $b 'source {"symbol":"TDerived.Add"') @('TDerived.Add (procedure) implemented at AppA\uMembers.pas:95-97') @('overloads')
Check 'source namesakes' (Block $b 'source {"symbol":"Add"}') @('`Add` is ambiguous', 'AppA\uMembers.pas:35  TDerived.Add') @('implemented at')
# Side by side, each external overload with its own import line - the
# INT_PTR one showed the WPARAM one's (the RTL's lines are not pinned).
# `lines`: the piece of a routine wanted, by file line numbers.
Check 'source lines' (Block $b 'source {"symbol":"RunB", "lines":"29-31"}') @('RunB (procedure) implemented at AppB\uAppB.pas:26-32', '(lines 29-31 of it, as `lines` asks)', "29  begin`n30    LSquare := TSquare.Create(4);`n31    Writeln") @('28  ', '32  end;', 'more lines')
Check 'source lines to' (Block $b 'source {"symbol":"RunB", "lines":"-26"}') @('(lines 25-26 of it', "25  // Project B's run", '26  procedure RunB;') @('27  ')
Check 'source lines limit' (Block $b 'source {"symbol":"RunB", "lines":"28-"') @('(lines 28-32 of it', '29  begin', '... 3 more lines, to line 32 (raise `limit`)') @('30  ')
Check 'source lines outside' (Block $b 'source {"symbol":"RunB", "lines":"100-120"}') @('RunB (procedure) implemented at AppB\uAppB.pas:26-32', '(`lines` 100-120 is outside it)') @('26  procedure')
Check 'source lines bad' (Block $b 'source {"symbol":"RunB", "lines":"31-29"}') @('`lines` 31-29: give file line numbers as the answers number them')
Check 'source lines overloads' (Block $b 'source {"symbol":"TBase.Add", "lines"') @('TBase.Add - 2 overloads:', '(line 77 of it', '77    Inc(FCount, AValue);', '(`lines` 77 is outside it)') @('76  ', '82  ')
Check 'source external overloads' (Block $b 'source {"symbol":"Winapi.Windows.SendMessage"}') @('SendMessage - 2 overloads:', '(external - `function SendMessage(hWnd: HWND; Msg: UINT; wParam: WPARAM;', '(external - `function SendMessage(hWnd: HWND; Msg: UINT; wParam: INT_PTR;')
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
# Set THROUGH a property: a sub-property in its property's class, an item's
# property in the item class its collection holds - TReader reads them there.
# Behind a link its declared type does not have (`Style.Deep`: a descendant's,
# chosen at run time) the line is kept, tagged, and said once.
Check 'references form sub-property' (Block $b 'references {"symbol":"TNameStyle.Accent"}') @('3 references in 2 files, 2 of them in form files', "AppF\uChildForm.dfm`n  fraName1`n    33  Style.Accent = 2`n    38  [may be another class's]  Style.Deep.Accent = 5", "(1 form line [may be another class's]: a link of the property path is a declared type without that property") @('(cut:')
# Cut by the limit, the code rows come first and the form lines left out are
# counted: form lines filling the rows by file name hid the code a rename
# changes.
Check 'references form cut' (Block $b 'references {"symbol":"TNameStyle.Accent","limit":1}') @("AppF\uFrame.pas`n  TfraName.btnClearClick`n    70  FStyle.Accent := 0;`n... 2 more (raise ``limit``)", '(cut: code rows come first - 2 of the rows left out are form lines)') @('uChildForm.dfm')
Check 'references form item property' (Block $b 'references {"symbol":"TNameTag.Weight"}') @('1 references in 1 files, 1 of them in form files', "AppF\uChildForm.dfm`n  fraName1`n    36  Weight = 3")
Check 'references form sub-property none' (Block $b 'references {"symbol":"TNameStyle.Shade"}') @('0 references in 0 files; no form file sets it')
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
Check 'compile' (Block $b 'compile {"member":"AppA"}') @('compile AppA (Win32 Debug): built in', '342 lines compiled', 'AppA-Win32-Debug\exe\AppA.exe', 'first build here: every unit compiled', 'warnings - none in files changed this session (1 elsewhere, not listed)')
Check 'compile again' (Block $b 'compile {"member":"AppA", "limit"') @('compile AppA (Win32 Debug): built in', '13 lines compiled', 'no errors, warnings or hints') @('first build here')
Check 'compile bare dpr' (Block $b 'compile {"member":"AppB"}') @('compile AppB (Win32): built in', 'AppB-Win32\exe\AppB.exe', 'first build here', 'no errors, warnings or hints')
# The forms member: dcc converts its text form files to binary as it links
# them, so a malformed one fails here; the binary one is linked as it is.
Check 'compile forms' (Block $b 'compile {"member":"AppF"}') @('compile AppF (Win32): built in', 'AppF-Win32\exe\AppF.exe', 'no errors, warnings or hints')
Check 'compile file' (Block $b 'compile {"file"') @('compile - 2 members, those compiling Shared\uShapes.pas', '  AppA (Win32 Debug): built in', '  AppB (Win32): built in', 'no errors, warnings or hints')
# A rebuild recompiles uMembers: its warning again, known, so not new.
Check 'compile rebuild' (Block $b 'compile {"member":"AppA", "rebuild"') @('342 lines compiled', "warnings - 1 in the group's files:`nAppA\uMembers.pas", '  37  W1055 PUBLISHED caused RTTI', "to be added to type 'TDerived' (in TDerived)`n        published") @('[new]')
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
# A form class with no form file of its own loads its ancestor's: that file,
# each event bound on the class asked about - by symbol and by its unit.
Check 'form streamed' (Block $b 'form {"symbol":"TfrmPlain"}') @('form of TfrmPlain - no form file of its own, it loads its ancestor''s (an event runs TfrmPlain''s method of the name): form frmMain: TfrmMain - AppF\uMainForm.dfm', "1  frmMain: TfrmMain`n13    OnCreate -> TfrmPlain.FormCreate", '39      OnClick -> TfrmMain.btnSaveClick') @('TfrmMain.FormCreate')
Check 'form streamed by unit' (Block $b 'form {"file":"AppF/uPlainForm.pas"}') @('form of TfrmPlain - no form file of its own', '13    OnCreate -> TfrmPlain.FormCreate')
Check 'callers streamed form' (Block $b 'callers {"symbol":"TfrmPlain.FormCreate"}') @('- no calls, 1 form binding', "AppF\uMainForm.dfm`n  frmMain (root)`n    13  [ancestor's form]  OnCreate = FormCreate")
# A call written over two lines is one row, joined up to its closing
# parenthesis, the comment between dropped; a call on one line stays as is.
Check 'callers multi-line call' (Block $b 'callers {"symbol":"TfrmPlain.Greet"}') @('- 2 calls in 1 routine', "  TfrmPlain.FormCreate`n    26  Greet(Caption, Length(Caption));`n    28  Greet('x', 1);") @('// who', '27  ')
# `limit: 0` - whether and how many: the header's counts and the notes, no
# rows; the empty case says nothing was found, not "nothing matched".
Check 'find count only' (Block $b 'find {"query":"T*","limit":0}') @(' declarations match (limit 0: none listed)') @('no declaration matches', 'Shared\uShapes.pas:')
Check 'find count only none' (Block $b 'find {"query":"NoSuchThing","limit":0}') @('no declaration matches `NoSuchThing`')
Check 'references count only' (Block $b 'references {"symbol":"TCircle","limit":0}') @('3 references in 2 files', '... 3 more (raise `limit`)', '(+2 implementation headers of its own methods name it') @('LShape')
Check 'references count only none' (Block $b 'references {"symbol":"TfrmMain.NeverBound","limit":0}') @('0 references in 0 files; no form file names it', 'names it only after the root''s `end`') @('more (raise')
Check 'callers count only' (Block $b 'callers {"symbol":"TCircle.Area","depth":3,"limit":0}') @('- 3 calls in 3 routines', '... 3 more (raise `limit`)', '(limit 0: depth 1 counted, depth 2 and below not searched') @('  RunA', 'the rows reached `limit`')
Check 'callers count only none' (Block $b 'callers {"symbol":"NeverCalled","limit":0}') @('callers of NeverCalled (AppB\uBoxes.pas:31) - none found') @('more (raise')
Check 'callees count only' (Block $b 'callees {"symbol":"RunA","limit":0}') @('- 4 calls reaching 7 routines', '... 7 more (raise `limit`)', '(built-ins called: Writeln)')
Check 'members count only' (Block $b 'members {"symbol":"TCircle","limit":0}') @(': 5 members', '... 5 more (raise `limit`') @('Radius')
Check 'related count only' (Block $b 'related {"relation":"descendants","symbol":"uShapes.TShape","limit":0}') @('more (raise `limit`)') @('TCircle = class')
Check 'form count only' (Block $b 'form {"symbol":"TfrmChild","limit":0}') @('8 components, 6 events bound, 3 references to components, 1 cleared', '... 19 more rows (raise `limit`)') @('lblHint')
Check 'outline count only' (Block $b 'outline {"file":"Shared/uShapes.pas","limit":0}') @('... 24 more rows (raise `limit`') @('member declarations of its types are left out', 'TCircle')
Check 'impact count only' (Block $b 'impact {"symbol":"TCircle.Area","limit":0}') @('members to build and test: AppA, AppB', 'callers - 3 calls in 3 routines', '... 3 more (raise `limit`)') @('  RunA')
# A member reached through a generic ancestor's type parameter, the call
# written bare (FR.2): no false E2003, the member bound, every spelling.
Check 'diagnostics generic ancestor call' (Block $b 'diagnostics {"file":"AppB/uGenLists.pas"}') @('no diagnostics in AppB\uGenLists.pas')
Check 'definition generic ancestor call' (Block $b 'definition {"file":"AppB/uGenLists.pas","line":69,"name":"Code"}') @('ICoded.Code (property) declared at AppB\uGenLists.pas:18')
# A unit named `in` a file that does not exist (AppB.dpr: uFallback in
# 'Gone\uFallback.pas'): dcc compiles the one beside the program; the index
# was pinned to the missing file and said F1027 (PasTree 0.91.1).
Check 'diagnostics missing in-path' (Block $b 'diagnostics {"file":"AppB/AppB.dpr"}') @('no diagnostics in AppB\AppB.dpr') @('F1027')
Check 'definition missing in-path' (Block $b 'definition {"symbol":"FallbackName"}') @('FallbackName (function) declared at AppB\uFallback.pas:8')
Check 'references generic ancestor call' (Block $b 'references {"symbol":"ICoded.Code"}') @('8 references in 1 files', '    69  Result := GetRecord(0).Code;', '    107  Result := GetRecord(0).Code;')
# `AList[0]` uses a default array property with no name written: a row
# tagged [X[I]] at each, a read calls its getter and a write its setter, and
# an array's own brackets (FCells[I]) are not such a use.
Check 'references default property' (Block $b 'references {"symbol":"TCellList.Cells"}') @('TCellList.Cells (property) declared at AppB\uCells.pas:21 - 5 references in 1 files', '    43  [X[I]]  LCell := AList[0];', '    50  [X[I]]  Result := AList[0].Text;', '(5 uses [X[I]]: the default array property used through brackets, its name not written') @('not listed')
Check 'callers default property getter' (Block $b 'callers {"symbol":"TCellList.GetCell"}') @('3 calls in 2 routines', 'all through TCellList.Cells (property read)', '    43  LCell := AList[0];', '    50  Result := AList[0].Text;') @('45  ', 'not found')
Check 'callers default property setter' (Block $b 'callers {"symbol":"TCellList.SetCell"}') @('2 calls in 1 routine', 'all through TCellList.Cells (property write)', '    44  AList[0] := AList[1];', '    45  AList[1] := LCell;') @('43  ')
Check 'callees default property' (Block $b 'callees {"symbol":"SwapCells"}') @('4 calls reaching 2 routines', '18  [at 43, 44 via TCellList.Cells]  function GetCell', '19  [at 44, 45 via TCellList.Cells]  procedure SetCell')
Check 'assignments default property' (Block $b 'related {"relation":"assignments","symbol":"TCellList.Cells"}') @('assignments of TCellList.Cells (AppB\uCells.pas:21): 2', '44  [X[I]]  AList[0] := AList[1];', '45  [X[I]]  AList[1] := LCell;')
Check 'references array brackets' (Block $b 'references {"symbol":"TCellList.FCells"}') @('2 references in 1 files') @('[X[I]]')
# A wildcard in a qualifier, `*.Name` or `*Type.Name`: it was "no declaration
# matches", the name itself found. Nothing of the name stays nothing.
Check 'find wildcard qualifier' (Block $b 'find {"query":"*.GetCount"}') @('AppA\uMembers.pas:23  TBase.GetCount (function)', 'TStrings.GetCount') @('no declaration matches')
Check 'find wildcard type qualifier' (Block $b 'find {"query":"*Derived.Guarded"}') @('AppA\uMembers.pas:33  TDerived.Guarded (procedure)') @('TBase.Guarded', 'no declaration matches')
Check 'find wildcard qualifier none' (Block $b 'find {"query":"*.NoSuchMember"}') @('no declaration matches `*.NoSuchMember`')
# `TDerived.X` for a member TDerived inherits: the ancestor's declaration,
# said inherited - it was "no declaration matches", as the owner chain is
# TBase's. An unknown member of a known type stays unknown.
Check 'find inherited member' (Block $b 'find {"query":"TDerived.GetCount"}') @('AppA\uMembers.pas:23  TBase.GetCount (function)  function GetCount: Integer;  [inherited by TDerived]')
Check 'find inherited none' (Block $b 'find {"query":"TDerived.NoSuchMember"}') @('no declaration matches `TDerived.NoSuchMember`') @('inherited by')
Check 'source inherited member' (Block $b 'source {"symbol":"TDerived.GetCount"}') @('TBase.GetCount (function) implemented at AppA\uMembers.pas:70-73', '72    Result := FCount + FSecret;')
Check 'references inherited field' (Block $b 'references {"symbol":"TDerived.FCount"}') @('TBase.FCount (field) declared at AppA\uMembers.pas:19 - 3 references in 1 files', '87  FCount := 0;')
# The overloads of one routine are answered together, each row with the one
# it binds to, and each one's count: it was a refusal as ambiguous. Namesakes
# are refused still (`Area` above); a tool taking one routine refuses an
# overload set with the one advice that works.
Check 'references overloads' (Block $b 'references {"symbol":"TBase.Add"}') @('TBase.Add (procedure) - 2 overloads declared in AppA\uMembers.pas - 2 references in 1 files', '(1 at 25, 1 at 26)', '82  [overload at 25]  Add(Length(AText));', '125  [overload at 26]  Base.Add(''done'');') @('ambiguous')
Check 'references overloads none' (Block $b 'references {"symbol":"TQuiet.Hush"}') @('TQuiet.Hush (procedure) - 2 overloads declared in AppA\uMembers.pas - 0 references in 0 files', '(0 at 157, 0 at 158)') @('ambiguous')
Check 'callers overloads' (Block $b 'callers {"symbol":"TBase.Add"}') @('callers of TBase.Add - 2 overloads (AppA\uMembers.pas:25, 26; rows by overload: 1 at 25, 1 at 26) - 2 calls in 2 routines', '82  [-> TBase.Add (line 25)]  Add(Length(AText));', '125  [-> TBase.Add (line 26)]  Base.Add(''done'');') @('ambiguous')
Check 'callers overloads none' (Block $b 'callers {"symbol":"TQuiet.Hush"}') @('rows by overload: 0 at 157, 0 at 158) - none found', 'no callers found: TQuiet.Hush (line 157), TQuiet.Hush (line 158)')
Check 'callees overloads refused' (Block $b 'callees {"symbol":"TQuiet.Hush"}') @('`TQuiet.Hush` names 2 overloads of one routine - pass `file` + `line` + `name`', 'AppA\uMembers.pas:158  TQuiet.Hush (procedure)') @('Qualify it')
Check 'impact overloads' (Block $b 'impact {"symbol":"TBase.Add"}') @('members to build and test: AppA', '  25  TBase.Add (procedure)', '  26  TBase.Add (procedure)', 'callers - 2 calls in 2 routines')
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
# rename_plan: a class (its name in the implementation headers), a component
# with its handlers carried along and the form lines, a handler, a unit, then
# the empty case (a declaration nothing uses), an overload, and the refusals.
Check 'rename_plan class' (Block $b 'rename_plan {"symbol":"TCircle"') @('to TRound - 6 edits in 3 files', "Shared\uShapes.pas`n  21:3  [declaration]  TRound = class(TShape)`n  47:13  constructor TRound.Create", '  53:10  function TRound.Area: Double;', '  11:22  TBigCircle = class(TRound)')
Check 'rename_plan component' (Block $b 'rename_plan {"symbol":"TfrmMain.btnSave"') @('to btnOK - 11 edits in 4 files, 5 of them in form files', '  4:13  [btnSave]  inherited btnOK: TButton', '  14:15 (btnSaveClick -> btnOKClick)  [chkConfirm.OnClick]  OnClick = btnOKClick', '  45:20 (btnSaveClick -> btnOKClick)  procedure TfrmMain.btnOKClick', '(carried along, as the form designer renames them - their edits are in the rows above: btnSaveClick -> btnOKClick)')
Check 'rename_plan handler' (Block $b 'rename_plan {"symbol":"TfrmMain.btnSaveClick"') @('to SaveClicked - 5 edits in 3 files, 3 of them in form files', '  39:15  [btnSave.OnClick]  OnClick = SaveClicked', '  20:15  [declaration]  procedure SaveClicked(Sender: TObject);') @('carried along')
# A unit's `in '...'` path is an edit of its file name, the directory kept
# (PasTree 0.87.0), and so is a member's .dproj entry (uMembers): left, each
# names a file the rename removed - F2613, and an index of a missing unit.
Check 'rename_plan unit' (Block $b 'rename_plan {"symbol":"uShapes"') @('to uShapesNew - 5 edits in 4 files', "AppB\AppB.dpr`n  8:3, 25 (uShapes.pas -> uShapesNew.pas)  uShapesNew in '..\Shared\uShapesNew.pas',", '  1:6  [declaration]  unit uShapesNew;', '(the unit''s file must be called uShapesNew.pas for it to compile')
Check 'rename_plan unit dproj' (Block $b 'rename_plan {"symbol":"uMembers"') @('to uMembership - 4 edits in 3 files', "AppA\AppA.dpr`n  7:3, 16 (uMembers.pas -> uMembership.pas)  uMembership in 'uMembership.pas';", "AppA\AppA.dproj`n  14:32 (uMembers.pas -> uMembership.pas)  <DCCReference Include=`"uMembership.pas`"/>")
Check 'rename_plan overloads refused' (Block $b 'rename_plan {"symbol":"TQuiet.Hush"') @('`TQuiet.Hush` names 2 overloads of one routine - pass `file` + `line` + `name`')
Check 'rename_plan one overload' (Block $b 'rename_plan {"file":"AppA/uMembers.pas"') @('to Quieten - ', '[declaration]  procedure Quieten(const S: string); overload;') @('procedure Quieten(A: Integer)')
Check 'rename_plan nothing uses it' (Block $b 'rename_plan {"symbol":"TfrmMain.NeverBound"') @('to Unbound - 2 edits in 1 files', '  23:15  [declaration]  procedure Unbound(Sender: TObject);')
Check 'rename_plan same name' (Block $b 'rename_plan {"symbol":"TCircle.Radius"') @('refused: The new name is the same as the old one. - nothing is planned')
Check 'rename_plan reserved word' (Block $b 'rename_plan {"symbol":"TCircle","new_name":"begin"') @('"begin" is not a valid identifier. - nothing is planned')
Check 'rename_plan library' (Block $b 'rename_plan {"symbol":"TStringList"') @('is a library source (RTL/VCL or third-party) - its identifiers cannot be renamed from here. - nothing is planned')
Check 'rename_plan no name' (Block $b 'rename_plan {"symbol":"TCircle"}') @('give `new_name`')
# A dotted unit whose last segment names a routine it exports (AppB\Lib.Notes):
# the bare call is the routine's (PasTree 0.85.1), the dotted name the unit's
# (not Unit.Member read as a subsequence), `kind: unit` lists units - the empty
# case included - and a file alone is its unit.
Check 'references dotted unit leaf' (Block $b 'references {"symbol":"Lib.Notes.Notes"}') @('Notes (procedure) declared at AppB\Lib.Notes.pas:9 - 1 references in 1 files', "AppB\AppB.dpr`n  14  Notes('done');")
Check 'find dotted unit' (Block $b 'find {"query":"Lib.Notes"}') @('AppB\Lib.Notes.pas:1  Lib.Notes (unit)  unit Lib.Notes;') @('(procedure)')
Check 'find kind unit' (Block $b 'find {"query":"*Notes","kind":"unit"}') @('AppB\Lib.Notes.pas:1  Lib.Notes (unit)') @('(procedure)')
Check 'find kind unit none' (Block $b 'find {"query":"NoSuchUnit","kind":"unit"}') @('no declaration of kind unit matches `NoSuchUnit`')
Check 'rename_plan unit by file' (Block $b 'rename_plan {"file":"AppB/Lib.Notes.pas"') @('rename Lib.Notes (unit) declared at AppB\Lib.Notes.pas:1 to Lib.Memo - 3 edits in 2 files', "AppB\AppB.dpr`n  10:81, 95 (Lib.Notes.pas -> Lib.Memo.pas)  ",'  1:6  [declaration]  unit Lib.Memo;')
# A unit's `uses` rows are code rows: the cut note counted them as form lines.
Check 'references unit count only' (Block $b 'references {"symbol":"uShapes","limit":0}') @('3 references in 3 files', '... 3 more (raise `limit`)') @('form lines')
# A method's family (PasTree 0.86.0): an interface method takes the class that
# implements it and that method's overrides; an override takes the virtual it
# overrides; a method tied to nothing takes nothing.
Check 'rename_plan family interface' (Block $b 'rename_plan {"symbol":"IShape.Area"') @('to Surface - 11 edits in 3 files', "AppB\uAppB.pas`n  13:14  function Surface: Double; override;", '  22:27  Result := 2 * inherited Surface;', '  17:14  function Surface: Double; virtual; abstract;', '  64:18  function TSquare.Surface: Double;', 'TShape.Area (the same interface method)', 'TBigCircle.Area (the same virtual method)')
Check 'rename_plan family override' (Block $b 'rename_plan {"symbol":"TBigBox.Changed"') @('to Modified - ', 'procedure Modified; virtual;', 'procedure TBigBox.Modified;', 'TShapeBox.Changed (the same virtual method)')
Check 'rename_plan family none' (Block $b 'rename_plan {"symbol":"TShape.Describe"') @('to Explain - 3 edits in 2 files') @('taken along')
# change_plan: a virtual method's slot with the interface method it implements,
# each header, every call of any of them; a getter's property; a handler handed
# on and one a form binds; a bare inherited; an overload; nothing calling it; a
# resolution clause; a slot a library introduced; the refusals and the counts.
Check 'change_plan family' (Block $b 'change_plan {"symbol":"TShape.Area"}') @('change_plan of TShape.Area (Shared\uShapes.pas:17) - the signature on 8 lines in 2 files, 4 other routines tied to it; 3 calls in 3 routines', '(one left behind: E2037 at an implementation header, E2137 at an override, E2291 at a class implementing the interface method):', "AppB\uAppB.pas`n  13  [TBigCircle, the same virtual method]  function Area: Double; override;`n  20  function TBigCircle.Area: Double;", '  12  [IShape, the same interface method]  function Area: Double;', '  17  [TShape, this one]  function Area: Double; virtual; abstract;', '  64  function TSquare.Area: Double;', "calls - written for the old parameters:`nAppA\uAppA.pas`n  RunA`n    22  Writeln(LShape.Describe, ' ', LShape.Area:0:2);", "  TBigCircle.Area`n    22  Result := 2 * inherited Area;", "  TotalArea`n    75  Result := Result + LShape.Area;") @('via ', '->')
Check 'change_plan getter' (Block $b 'change_plan {"symbol":"TShapeBox.GetItem"') @('the signature on 3 lines in 1 file; 1 call in 1 routine', '  23  [TShapeBox.Item, property - its getter]  property Item: TObject read GetItem write SetItem;', '  35  function TShapeBox.GetItem: TObject;', '    53  [via TShapeBox.Item]  if Item <> nil then') @('E2137')
Check 'change_plan handed on' (Block $b 'change_plan {"symbol":"TShapeBox.BoxClick"') @('no calls, 1 reference handing it on', '    43  [not a call]  FOnChange := BoxClick;', '(1 reference hands it on without calling it')
Check 'change_plan bare inherited' (Block $b 'change_plan {"symbol":"TBigBox.Changed"') @('1 other routine tied to it; 2 calls in 2 routines', '  20  [TShapeBox, the same virtual method]  procedure Changed; virtual;', '  47  procedure TShapeBox.Changed;', "  TBigBox.Changed`n    59  [bare inherited]  inherited;") @('E2291')
Check 'change_plan form binding' (Block $b 'change_plan {"symbol":"TfrmMain.btnSaveClick"') @('no calls, 3 form bindings', "calls - written for the old parameters:`n  none found in code", '(3 form lines bind it to an event (AppF\uChildForm.dfm:14, 25; AppF\uMainForm.dfm:39): the event calls it with that event type''s parameters') @('OnClick')
Check 'change_plan overloads refused' (Block $b 'change_plan {"symbol":"TBase.Add"') @('`TBase.Add` names 2 overloads of one routine - pass `file` + `line` + `name`')
Check 'change_plan one overload' (Block $b 'change_plan {"file":"AppA/uMembers.pas"') @('change_plan of TBase.Add (AppA\uMembers.pas:25)', '  75  procedure TBase.Add(AValue: Integer);', "  TBase.Add`n    82  Add(Length(AText));", '(TBase.Add is overloaded - also at AppA\uMembers.pas:26: after the change a call whose arguments fit another overload binds to it') @('TRunner.Run')
Check 'change_plan no calls' (Block $b 'change_plan {"symbol":"NeverCalled"') @('the signature on 2 lines in 1 file; no calls', "  62  procedure NeverCalled;`ncalls - written for the old parameters:`n  none found")
Check 'change_plan resolution clause' (Block $b 'change_plan {"symbol":"TCountBox.BoxCount"') @('the signature on 3 lines in 1 file; 1 call in 1 routine', '  108  [IBoxCount.Count, interface method - a resolution clause maps it here]  function Count: Integer;', '(lines to check - in branches this configuration does not compile the name is written on 1 line more, none resolved, so not above: AppB\uBoxes.pas:122)') @('110  ', '107  ')
Check 'change_plan library slot' (Block $b 'change_plan {"symbol":"TCopyBox.AssignTo"') @('  131  [TCopyBox, this one]  procedure AssignTo(Dest: TPersistent); override;', '  134  procedure TCopyBox.AssignTo(Dest: TPersistent);', '(its virtual method is TPersistent.AssignTo (', 'a library''s: the signature is fixed there - changed here, this one no longer overrides it')
Check 'change_plan not a routine' (Block $b 'change_plan {"symbol":"TCircle"') @('TCircle is a class - `change_plan` takes a routine')
Check 'change_plan library routine' (Block $b 'change_plan {"symbol":"TStringList.Add"') @('is declared in a library (', 'its signature is not this project''s to change')
Check 'change_plan count only' (Block $b 'change_plan {"symbol":"TShape.Area","limit":0') @('the signature on 8 lines in 2 files, 4 other routines tied to it; 3 calls in 3 routines', '... 8 more (raise `limit`)', '... 3 more (raise `limit`)') @('  17  ')
# The interface method's side of a resolution clause maps nothing: callers took
# the interface itself for a source, and its heritage line for a call.
Check 'callers resolution clause' (Block $b 'callers {"symbol":"TCountBox.BoxCount"') @('callers of TCountBox.BoxCount (AppB\uBoxes.pas:112) - 1 call in 1 routine', 'also through IBoxCount.Count (interface)') @('IBoxCount (interface)', '110  ')
# references `mode` and `in`: a count per file under its directory, the code
# files first when the limit cuts; the rows of the files matching `in`, the
# header counting all; none matching; the counts alone; a bad mode; nothing.
Check 'references files' (Block $b 'references {"symbol":"TfrmMain.btnSave","mode":"files"}') @('5 references in 4 files, 2 of them in form files', "AppF\`n  uChildForm.dfm  1`n  uMainForm.dfm  1`n  uMainForm.pas  2`n  uPlainForm.pas  1")
Check 'references in' (Block $b 'references {"symbol":"TfrmMain.btnSave","in":".dfm"}') @('5 references in 4 files', '(in `.dfm`: 2 references in 2 files listed, the rest left out)', "AppF\uMainForm.dfm`n  31  object btnSave: TButton") @('uPlainForm.pas')
# The header over every row: the filter once wrote over the array it counts.
Check 'references in header' (Block $b 'references {"symbol":"TfrmMain.btnSave","in":".pas"}') @('5 references in 4 files, 2 of them in form files', '(in `.pas`: 3 references in 2 files listed, the rest left out)')
Check 'references in none' (Block $b 'references {"symbol":"TShape.Area","in":"*.dpr"}') @('1 references in 1 files', '(in `*.dpr`: none of them)') @('uAppA')
Check 'references files cut' (Block $b 'references {"symbol":"TfrmMain.btnSave","mode":"files","limit":1}') @("AppF\`n  uMainForm.pas  2", '... 3 more files (raise `limit`)') @('.dfm  1')
Check 'references count' (Block $b 'references {"symbol":"TShape.Area","mode":"count"}') @('1 references in 1 files', '... 1 more (raise `limit`)') @('RunA')
Check 'references bad mode' (Block $b 'references {"symbol":"TShape.Area","mode":"bogus"}') @('`mode` is lines (the default), files (a count per file) or count (the counts alone) - not `bogus`')
Check 'references files none' (Block $b 'references {"symbol":"NeverCalled","mode":"files"}') @('0 references in 0 files')

# defines: Shared\uFlags.pas, lines pinned. AppB shares AppA's analysis and
# not its FIXTURE_A: said where it decides a branch.
Check 'defines else' (Block $b 'defines {"file":"Shared/uFlags.pas","line":21}') @('Shared\uFlags.pas:21 is not compiled (analysis 0: AppA, AppB, AppF; Win32)', '  18 {$IFDEF FIXTURE_A}, its {$ELSE} at 20: not taken - FIXTURE_A defined by the project', "    (AppB does not define FIXTURE_A, the analysis takes AppA's defines - built as AppB, it is not defined here)", "in effect here:`n  by `$DEFINE in Shared\Flags.inc: FIXTURE_LOCAL 2`n  by the project: FIXTURE_A`n  predefined for Win32: ", 'MSWINDOWS', "  undefined by a unit's `$UNDEF: FIXTURE_GONE") @('AppF do')
Check 'defines nested' (Block $b 'defines {"file":"Shared/uFlags.pas","line":25,"name":"FIXTURE_OFF"}') @('Shared\uFlags.pas:25 is compiled', 'here: FIXTURE_OFF not defined - its $DEFINE at Shared\Flags.inc:6 does not reach here', "outermost first:`n  23 {`$IFDEF FIXTURE_LOCAL}: taken - FIXTURE_LOCAL defined at Shared\Flags.inc:2`n  24 {`$IFNDEF FIXTURE_OFF}: taken")
Check 'defines not reached' (Block $b 'defines {"file":"Shared/uFlags.pas","line":34}') @('Shared\uFlags.pas:34 is not compiled', '  31 {$IFDEF FIXTURE_NEVER}: not taken - FIXTURE_NEVER not defined - nothing in the group defines it', '  33 {$IFDEF FIXTURE_A}: not reached')
Check 'defines include' (Block $b 'defines {"file":"Shared/Flags.inc","line":6}') @('Shared\Flags.inc:6 is not compiled, a directive line', '(an include file: read as Shared\uFlags.pas reads it)', '  5 {$IFDEF FIXTURE_NEVER}: not taken')
Check 'defines file' (Block $b 'defines {"file":"Shared/uFlags.pas"}') @('Shared\uFlags.pas: 5 lines not compiled, in 2 branches', '  line 21: 18 {$IFDEF FIXTURE_A}, its {$ELSE} at 20: not taken', '  lines 32-35: 31 {$IFDEF FIXTURE_NEVER}: not taken') @('more (raise')
Check 'defines file cut' (Block $b 'defines {"file":"Shared/uFlags.pas","limit":1}') @('in 2 branches', '  line 21: ', '... 1 more (raise `limit`)') @('lines 32-35')
Check 'defines file none' (Block $b 'defines {"file":"Shared/uShapes.pas"}') @('Shared\uShapes.pas: 0 lines not compiled')
Check 'defines no block' (Block $b 'defines {"file":"Shared/uShapes.pas","line":5}') @('Shared\uShapes.pas:5 is compiled', 'no conditional block around it', 'in effect here:') @('by $DEFINE')
Check 'defines name' (Block $b 'defines {"name":"FIXTURE_A"}') @('FIXTURE_A (conditional symbol) - 2 directives in 1 file of the group', 'analysis 0: AppA, AppB, AppF; Win32: defined by the project - AppB does not define FIXTURE_A', "Shared\uFlags.pas`n  18  {`$IFDEF FIXTURE_A} - its branch compiled`n  33  {`$IFDEF FIXTURE_A} - not reached")
Check 'defines name undef' (Block $b 'defines {"name":"FIXTURE_GONE"}') @('3 directives in 2 files', 'in the code: $DEFINE at Shared\Flags.inc:3; $UNDEF at Shared\Flags.inc:4', "Shared\Flags.inc`n  3  {`$DEFINE FIXTURE_GONE} - live`n  4  {`$UNDEF FIXTURE_GONE} - live", '  28  {$IF Defined(MSWINDOWS) and not Defined(FIXTURE_GONE)} - its branch compiled')
Check 'defines name in file' (Block $b 'defines {"name":"FIXTURE_A","file":"Shared/Flags.inc"}') @('FIXTURE_A (conditional symbol) - 0 directives in Shared\Flags.inc', 'defined by the project')
Check 'defines name count' (Block $b 'defines {"name":"MSWINDOWS","limit":0}') @('MSWINDOWS (conditional symbol) - 1 directive in 1 file of the group (+', ' in library files, not listed)', 'predefined for Win32', '... 1 more (raise `limit`') @('uFlags.pas')
Check 'defines name none' (Block $b 'defines {"name":"NOPE_X"}') @('no directive names `NOPE_X` and no project or platform defines it')
Check 'defines no args' (Block $b 'defines {}') @('pass `name` (a conditional symbol')
Check 'references define by name' (Block $b 'references {"symbol":"FIXTURE_A"}') @('`FIXTURE_A` is a conditional symbol: `defines` with `name`')

# ---- 2. strict policy ---------------------------------------------------------
Write-Host '--- CLI, strict policy'
$b = Run-Cli @('--groups', 'strict')
Check 'strict status' (Block $b 'status') @('analysis 0:', 'analysis 1:')
Check 'strict references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files')
# The shared unit is in both analyses: its edits are counted once.
Check 'strict rename_plan' (Block $b 'rename_plan {"symbol":"TCircle","new_name":"TRound"') @('to TRound - 6 edits in 3 files')
Check 'strict rename_plan unit' (Block $b 'rename_plan {"symbol":"uShapes"') @('to uShapesNew - 5 edits in 4 files')
Check 'strict change_plan' (Block $b 'change_plan {"symbol":"TShape.Area"}') @('the signature on 8 lines in 2 files, 4 other routines tied to it; 3 calls in 3 routines')
Check 'strict descendants' (Block $b 'related {"relation":"descendants"') @('descendants of TShape (Shared\uShapes.pas:15): 3', 'TBigCircle <- TCircle')
Check 'strict overrides' (Block $b 'related {"relation":"overrides"') @('overrides of TShape.Area (Shared\uShapes.pas:17): 4')
# Rows of both analyses in one walk: RunA is project A's, the rest project B's.
Check 'strict callers' (Block $b 'callers {"symbol":"TCircle.Area", "depth":3}') @('3 calls in 3 routines; depth 2: 2 in 2; depth 3: 1 in 1', '22  [via TShape.Area]', '75  [via IShape.Area]', '10  [-> RunA, main block]', '13  [-> RunB, main block]')
# Each analysis its own answer; what they agree on said once.
Check 'strict defines' (Block $b 'defines {"file":"Shared/uFlags.pas","line":21}') @('Shared\uFlags.pas:21 is not compiled (analysis 0: AppA; Win32)', 'Shared\uFlags.pas:21 is compiled (analysis 1: AppB, AppF; Win32)', ': taken - FIXTURE_A not defined - the project of AppA defines it, analyzed apart', 'in effect here (analysis 0: AppA; Win32):', 'in effect here (analysis 1: AppB, AppF; Win32):') @('AppB does not define')
Check 'strict defines agree' (Block $b 'defines {"file":"Shared/uFlags.pas","line":34}') @('Shared\uFlags.pas:34 is not compiled (analysis 0: AppA; Win32; analysis 1: AppB, AppF; Win32)')
Check 'strict defines name' (Block $b 'defines {"name":"FIXTURE_A"}') @('analysis 0: AppA; Win32: defined by the project', 'analysis 1: AppB, AppF; Win32: not defined by the project', '  18  {$IFDEF FIXTURE_A} - its branch compiled in analysis 0, its branch not compiled in analysis 1')
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

# ---- a project outside the group: --also ----------------------------------------------
# The client group's tests are a project no .groupproj lists: indexed, checked
# and built with the group when the server is given it. Outside the group's
# directory here, so its files are own through the extra root.
Write-Host '--- CLI, a project outside the group'
$alsoCalls = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-also-' + [Guid]::NewGuid().ToString('N') + '.calls')
$alsoBuild = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-build-' + [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($alsoCalls, "status`nfind {`"query`":`"CheckAreas`"}`nreferences {`"symbol`":`"TotalArea`"}`ndiagnostics {`"file`":`"../extra/AppT/uAppT.pas`"}`ncompile {`"member`":`"AppT`"}`n")
$ErrorActionPreference = 'Continue'
try { $out = (& $Exe --project $group --also '..\extra\AppT\AppT.dpr' --log none --build-dir $alsoBuild --script $alsoCalls 2>$null | ForEach-Object { "$_" }) -join "`n" }
finally {
    $ErrorActionPreference = 'Stop'
    Remove-Item -Force $alsoCalls -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $alsoBuild -ErrorAction SilentlyContinue
}
Check 'also status' $out @('member AppT: Win32 (bare project file), 0 listed files, analysis 0 - not in the group, added by --also (', 'member AppF')
Check 'also find' $out @('uAppT.pas:8  CheckAreas (procedure)')
Check 'also references' $out @('uAppT.pas', '  CheckAreas', '17  if TotalArea([TCircle.Create(1)]) <= 0 then')
Check 'also diagnostics' $out @('no diagnostics')
Check 'also compile' $out @('compile AppT (Win32): built in', 'AppT.exe - built to check the compile')
$ErrorActionPreference = 'Continue'
$out = (& $Exe --project $group --also 'nowhere\AppX.dpr' --log none --call status 2>&1 | ForEach-Object { "$_" }) -join "`n"
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -eq 0) { Write-Host "FAIL [also missing] exited with 0"; $script:failures++ }
Check 'also missing' $out @('no such project (--also): ', 'nowhere\AppX.dpr')

# ---- one --log for two servers ---------------------------------------------------------
# The first holds the file for its life; the second logs beside it under a name
# of its own and says so - it had no log at all.
Write-Host '--- two servers, one --log'
$logFile = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-' + [Guid]::NewGuid().ToString('N') + '.log')
$psi1 = New-Object Diagnostics.ProcessStartInfo
$psi1.FileName = $Exe
$psi1.Arguments = '--project "' + $group + '" --log "' + $logFile + '"'
$psi1.UseShellExecute = $false
$psi1.RedirectStandardInput = $true
$psi1.RedirectStandardOutput = $true
$psi1.RedirectStandardError = $true
$first = [Diagnostics.Process]::Start($psi1)
$null = $first.StandardError.ReadToEndAsync()
try {
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path $logFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $ErrorActionPreference = 'Continue'
    $out = (& $Exe --project $group --log $logFile --call status 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = 'Stop'
    $second = [IO.Path]::ChangeExtension($logFile, $null).TrimEnd('.') + '-'
    Check 'log held' $out @("cannot open log file $logFile (", 'held by another server? Logging to ' + $second, 'log: ' + $second, 'server: pastree-mcp ', '; pid ')
    $alt = Get-ChildItem ($second + '*.log') | Select-Object -First 1
    if ($null -eq $alt) { Write-Host 'FAIL [log held] no second log file'; $script:failures++ }
    else { Check 'log held file' ([IO.File]::ReadAllText($alt.FullName)) @('pastree-mcp ', 'project ') }
}
finally {
    $first.StandardInput.Close()
    if (-not $first.WaitForExit(10000)) { $first.Kill() }
    Remove-Item -Force $logFile -ErrorAction SilentlyContinue
    Get-ChildItem ([IO.Path]::ChangeExtension($logFile, $null).TrimEnd('.') + '-*.log') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---- dcc's internal error: built again, and said --------------------------------------
# F2084 is dcc failing, not the code, and a second build usually passes (FR.4).
# No code makes dcc fail on demand: PASTREE_MCP_TEST_F2084=N makes the first N
# builds of the process report one after dcc ran.
Write-Host '--- CLI, an internal error of dcc'
function Run-F2084([int]$Fail, [int]$Compiles = 1) {
    $calls = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-f2084-' + [Guid]::NewGuid().ToString('N') + '.calls')
    $buildDir = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-build-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($calls, ("compile {`"member`":`"AppB`"}`n" * $Compiles))
    $env:PASTREE_MCP_TEST_F2084 = "$Fail"
    $ErrorActionPreference = 'Continue'
    try { $out = (& $Exe --project $group --log none --build-dir $buildDir --script $calls 2>$null | ForEach-Object { "$_" }) -join "`n" }
    finally {
        $ErrorActionPreference = 'Stop'
        Remove-Item Env:PASTREE_MCP_TEST_F2084
        Remove-Item -Force $calls -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    }
    return $out
}
$out = Run-F2084 1
Check 'compile internal error once' $out @('compile AppB (Win32): built in', "built twice: the first build (", "stopped at dcc's internal error F2084 Internal Error: TEST1 (PASTREE_MCP_TEST_F2084) in AppB\AppB.dpr - the compiler failing, not the code; the second passed", 'first build here', 'no errors, warnings or hints') @('errors -', 'FAILED')
$out = Run-F2084 2
Check 'compile internal error twice' $out @("compile AppB (Win32): FAILED in", ", 1 error - dcc's internal error, not the code: ``rebuild: true``", "built twice, both stopped at dcc's internal error (first: F2084", '`rebuild: true` compiles every unit afresh', 'errors - 1:', 'F2084 Internal Error: TEST1') @('the second passed')
# Both builds stopped at it: the next compile stopping at the same one rebuilds
# (a Make did not get past it; on the client group's COM server a rebuild did).
$out = Run-F2084 3 2
Check 'compile internal error known' $out @("built twice, both stopped at dcc's internal error", "stopped at dcc's internal error F2084 Internal Error: TEST1 (PASTREE_MCP_TEST_F2084) in AppB\AppB.dpr, which a Make did not get past at ", 'so the second was a rebuild, every unit afresh, and it passed') @('not built again')
# The rebuild stops at it too: the compiler fails on this code, and the compile
# after that builds once, the rebuild hint gone from its status line.
$out = Run-F2084 5 3
Check 'compile internal error defect' $out @("built twice, the second a rebuild (a Make did not get past it at ", "- the compiler fails on this code: worked around in the unit it names; the next compile stopping at it builds once", ", 1 error - dcc's internal error, not the code, a rebuild too", "as a compile at ", ' did in a Make and a rebuild - not built again') @('and it passed')

# ---- a form file dcc does not link ------------------------------------------------------
# dcc names no file(line) for either: E2161 when a text form file does not
# convert, E1026 when a unit's {$R *.dfm} finds none. Both were rows under
# "(no file)"; they go on the form file at the line the reader stops at, and
# on the unit's directive. A copy, broken: the fixture's forms must link.
Write-Host '--- CLI, a form file dcc does not link'
$formCopy = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-forms-' + [Guid]::NewGuid().ToString('N'))
$formCalls = $formCopy + '.calls'
Copy-Item -Recurse $fixture $formCopy
try {
    $dfm = Join-Path $formCopy 'AppF\uData.dfm'
    [IO.File]::WriteAllText($dfm, ([IO.File]::ReadAllText($dfm).Replace("Caption = 'Save'", "Caption = 'Save")))
    Remove-Item -Force (Join-Path $formCopy 'AppF\uChildForm.dfm')
    [IO.File]::WriteAllText($formCalls, "compile {`"member`":`"AppF`"}`n")
    $ErrorActionPreference = 'Continue'
    try { $out = (& $Exe --project (Join-Path $formCopy 'Fixture.groupproj') --log none --build-dir ($formCopy + '-build') --script $formCalls 2>$null | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = 'Stop' }
}
finally {
    Remove-Item -Recurse -Force $formCopy, ($formCopy + '-build') -ErrorAction SilentlyContinue
    Remove-Item -Force $formCalls -ErrorAction SilentlyContinue
}
Check 'compile form malformed' $out @('compile AppF (Win32): FAILED in', 'errors - 2:', "AppF\uData.dfm`n  8  E2161 Error: RLINK32: Error opening file - the form file does not read from this line: Invalid string constant`n        Caption = 'Save") @('(no file)', 'uData.dfm"')
Check 'compile form missing' $out @("AppF\uChildForm.pas`n  27  E1026 File not found: 'uChildForm.dfm'`n        {`$R *.dfm}`n")

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
    Check 'tools/list' $names @('status', 'find', 'definition', 'source', 'members', 'references', 'callers', 'callees', 'impact', 'compile', 'related', 'outline', 'diagnostics', 'unit_deps', 'rename_plan', 'change_plan', 'defines')
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
