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
Check 'references' (Block $b 'references {"symbol":"TShape.Area"}') @('1 references in 1 files', '22  Writeln(LShape.Describe')
Check 'references by position' (Block $b 'references {"file"') @('TCircle.Radius (property)', '21  TCircle(LShape).Radius := 3;')
Check 'references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files', 'AppB\AppB.dpr')
Check 'descendants' (Block $b 'related {"relation":"descendants"') @('TCircle <- TShape', 'TSquare <- TShape', '    TBigCircle <- TCircle  AppB\uAppB.pas:11')
Check 'overrides' (Block $b 'related {"relation":"overrides"') @('[TShape introduces]', '[TCircle override]', '[TSquare override]', '[TBigCircle override]')
Check 'implementors' (Block $b 'related {"relation":"implementations", "symbol":"IShape"}') @('[TShape]')
Check 'implementations' (Block $b 'related {"relation":"implementations", "symbol":"IShape.Area"}') @('[TShape implements]')
Check 'assignments' (Block $b 'related {"relation":"assignments"') @('50  FRadius := ARadius;')
Check 'creations' (Block $b 'related {"relation":"creations"') @('19  LShape := TCircle.Create(2);')
Check 'destructions' (Block $b 'related {"relation":"destructions"') @('24  FreeAndNil(LShape);')
Check 'outline' (Block $b 'outline') @('21  type TCircle = class', '27    property Radius: Double', '53  function TCircle.Area: Double', '40 implementation')
Check 'unit_deps' (Block $b 'unit_deps') @('uShapes is used by 3 units', 'AppB\uAppB.pas:8')
Check 'diagnostics' (Block $b 'diagnostics') @('no diagnostics')
Check 'ambiguous' (Block $b 'references {"symbol":"Area"}') @('is ambiguous - 5 declarations', 'IShape.Area', 'TBigCircle.Area')
Check 'unknown' (Block $b 'definition {"symbol":"NoSuchThing"}') @('no declaration named `NoSuchThing`')

# ---- 2. strict policy ---------------------------------------------------------
Write-Host '--- CLI, strict policy'
$b = Run-Cli @('--groups', 'strict')
Check 'strict status' (Block $b 'status') @('analysis 0:', 'analysis 1:')
Check 'strict references unit' (Block $b 'references {"symbol":"uShapes"}') @('3 references in 3 files')
Check 'strict descendants' (Block $b 'related {"relation":"descendants"') @('descendants of TShape (Shared\uShapes.pas:15): 3', 'TBigCircle <- TCircle')
Check 'strict overrides' (Block $b 'related {"relation":"overrides"') @('overrides of TShape.Area (Shared\uShapes.pas:17): 4')

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
    Check 'tools/list' $names @('status', 'find', 'definition', 'references', 'related', 'outline', 'diagnostics', 'unit_deps')
    $r = Rpc 3 'tools/call' '{"name":"related","arguments":{"relation":"creations","symbol":"TCircle"}}'
    Check 'call before edit' (ToolText $r) @('creations of TCircle', ': 1')
    if ($r.result.isError) { Write-Host 'FAIL call before edit reported isError'; $script:failures++ }

    # The edit: a second TCircle.Create in project A's unit.
    $unit = Join-Path $copy 'AppA\uAppA.pas'
    $text = [IO.File]::ReadAllText($unit)
    $text = $text.Replace("    FreeAndNil(LShape);", "    FreeAndNil(LShape);`r`n    TCircle.Create(5).Free;")
    [IO.File]::WriteAllText($unit, $text, $utf8)
    $r = Rpc 4 'tools/call' '{"name":"related","arguments":{"relation":"creations","symbol":"TCircle"}}'
    Check 'call after edit' (ToolText $r) @('(index: re-analyzed 1 changed file(s)', 'creations of TCircle', ': 2', 'TCircle.Create(5).Free;')

    $r = Rpc 5 'tools/call' '{"name":"no_such_tool","arguments":{}}'
    if (-not $r.result.isError) { Write-Host 'FAIL unknown tool not reported as isError'; $script:failures++ }
    $r = Rpc 6 'no/such/method' '{}'
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
