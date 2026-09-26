# Smoke test over tests\fixtures\group (two projects sharing a unit).
#
# Three parts, each exercising a different path:
#   1. CLI, shared policy - every tool once, answers checked by substring.
#   2. CLI, strict policy - the same group split into two analyses, so the
#      group-wide merge (and its de-duplication) is what answers.
#   3. MCP over stdio on a COPY of the fixture - the handshake, tools/list, a
#      call, then an edit on disk and the same kind of call again: the index
#      must notice the edit by itself.
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
    $out = & $Exe --project $group --log none --script (Join-Path $here 'smoke.calls') @ExtraArgs 2>$null
    $ErrorActionPreference = 'Stop'
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
Check 'status' (Block $b 'status') @('member AppA', 'member AppB', 'analysis 0:', 'every `uses` name resolved') @('analysis 1:')
Check 'find' (Block $b 'find {"query":"TCircle"}') @('Shared\uShapes.pas:21  TCircle (class)')
Check 'find wildcard' (Block $b 'find {"query":"*Circ*"') @('AppB\uAppB.pas:11  TBigCircle', 'Shared\uShapes.pas:21  TCircle')
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
# "AppA\tuAppA.pas" in JSON is a tab, not a backslash: say so, not "invalid characters in path".
Check 'control character' (Block $b 'outline {"file":"AppA') @('`file` holds a control character (#9)')
Check 'references' (Block $b 'references {"symbol":"TShape.Area"}') @('1 references in 1 files', "  RunA`n    22  Writeln(LShape.Describe")
Check 'references by position' (Block $b 'references {"file"') @('TCircle.Radius (property)', '21  TCircle(LShape).Radius := 3;')
# A row in no routine or type (a uses clause) stays at the file level.
Check 'references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files', 'AppB\AppB.dpr', "AppA\uAppA.pas`n  13  uShapes;")
# Rows under what they sit in: a member declaration under its class, a
# statement under its routine, two uses on one line under one heading.
Check 'references grouped' (Block $b 'references {"symbol":"TCircle.FRadius"}') @('5 references in 1 files', "  TCircle`n    27  property Radius", "  TCircle.Create`n    50  FRadius := ARadius;", "  TCircle.Area`n    55  Result := Pi * FRadius * FRadius;`n    55  ")
Check 'descendants' (Block $b 'related {"relation":"descendants"') @('  11  TBigCircle <- TCircle', "  21  TCircle`n", "  30  TSquare`n") @('<- TShape')
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
Check 'outline' (Block $b 'outline {"file":"Shared') @('21  type TCircle = class', '27    property Radius: Double', '53  function TCircle.Area: Double', '40 implementation')
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

# ---- 3. MCP over stdio, with an edit in between ------------------------------------
Write-Host '--- MCP over stdio'
$copy = Join-Path ([IO.Path]::GetTempPath()) ('pastree-mcp-smoke-' + [Guid]::NewGuid().ToString('N'))
Copy-Item -Recurse $fixture $copy
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '--project "' + (Join-Path $copy 'Fixture.groupproj') + '" --log none'
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

    function Rpc([int]$Id, [string]$Method, [string]$ParamsJson) {
        $stdin.WriteLine('{"jsonrpc":"2.0","id":' + $Id + ',"method":"' + $Method + '","params":' + $ParamsJson + '}')
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { throw "server closed stdout after $Method" }
        return ($line | ConvertFrom-Json)
    }
    function ToolText($Reply) { return [string]$Reply.result.content[0].text }

    $r = Rpc 1 'initialize' '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}'
    Check 'initialize' ($r | ConvertTo-Json -Depth 6) @('"name":  "pastree"', 'instructions', '"tools"')
    $stdin.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    $r = Rpc 2 'tools/list' '{}'
    $names = ($r.result.tools | ForEach-Object { $_.name }) -join ','
    Check 'tools/list' $names @('status', 'find', 'definition', 'source', 'members', 'references', 'callers', 'callees', 'related', 'outline', 'diagnostics', 'unit_deps')
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
    Check 'call after edit' (ToolText $r) @('(index: re-analyzed 1 changed file(s)', 'creations of TCircle', ': 2', 'TCircle.Create(5).Free;')
    $r = Rpc 5 'tools/call' '{"name":"diagnostics","arguments":{}}'
    Check 'diagnostics after edit' (ToolText $r) @('AppA\uAppA.pas:26:5: ', "'NoSuchName' (in RunA)")

    $r = Rpc 6 'tools/call' '{"name":"no_such_tool","arguments":{}}'
    if (-not $r.result.isError) { Write-Host 'FAIL unknown tool not reported as isError'; $script:failures++ }
    $r = Rpc 7 'no/such/method' '{}'
    if ($r.error.code -ne -32601) { Write-Host 'FAIL unknown method not -32601'; $script:failures++ }

    $stdin.Close()
    if (-not $proc.WaitForExit(10000)) { Write-Host 'FAIL server did not exit when stdin closed'; $script:failures++; $proc.Kill() }
}
finally {
    Remove-Item -Recurse -Force $copy -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) FAILED"
    exit 1
}
Write-Host 'smoke test: all checks passed'
exit 0
