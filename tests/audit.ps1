# A battery of tool calls over a sample of a project group's symbols, one
# JSON line per call - the harness of the deep tests (whether answers are
# RIGHT and ENOUGH, not only what they cost: that is tests\bench.ps1).
#
#   powershell -File tests\audit.ps1 -Project X.groupproj -Sample 400 -Seed 1 -Out run.jsonl
#   powershell -File tests\audit.ps1 -Project X.groupproj -Symbols sample.tsv -Out run.jsonl
#   powershell -File tests\audit.ps1 -Project X.groupproj -Forms -Outlines 300 -Out forms.jsonl
#   powershell -File tests\audit.ps1 -Project X.groupproj -Calls my.calls -Out run.jsonl
#
# Sampling (-Sample N): `outline` of every Pascal file of the group
# directory (git's view of it; a file no project compiles answers "not part
# of any analyzed project" and is left out) gives the group's own
# declarations with their kind, owner type, line and unit size. The
# library's come from `callees` of -LibProbe own routines drawn first: the
# routines, methods and types outside the group directory that the group's
# code actually calls. The sample is stratified: a quota per category
# (-Weights), and within a category the draw goes round the unit-size
# buckets (small < 500 lines, medium < 3000, large) so a large unit does not
# take every pick. The same -Seed over the same files gives the same sample;
# -SampleOut writes it, and -Symbols runs a written one again (or a list of
# qualified names, one per line).
#
# Categories: routine (a unit-level procedure or function), method, handler
# (a method taking Sender of the class the unit's form file is of - its
# first line), component (a field of that class declared before its first
# method - the designer's part), field, property, class, interface, type
# (records, enums, the rest), const, var; libroutine, libmethod, libtype.
#
# The battery per symbol, by category - every call addressed by file + line
# + name at the declaration (a library type by its qualified name), except
# `find`, which takes the qualified name:
#   every symbol       find, definition, references, impact
#   routine, method    + source, callers, callees; related overrides when the
#     handler            declaration says virtual, dynamic, override or abstract
#   class              + members, source, related descendants, creations
#   interface          + members, related descendants, implementations
#   type               + members (a record), source
#   field, property,   + related assignments, members (of its type)
#     component, var
#   const              + source
#
# -Forms adds `form` for every form file (.dfm, .fmx) of the group
# directory; -Outlines N `outline` of N own units drawn with the seed.
#
# The calls run through the CLI's --script: one analysis, every call. A
# watchdog restarts the server after the call it died on (an access
# violation) or hung on (no answer for -CallTimeout seconds), records that
# call as `crash` or `hang` and goes on with the next.
#
# Output, one JSON object per line (-Out): seq, sym (the symbol's index in
# the sample, -1 for -Forms/-Outlines/-Calls rows), cat, origin, size, form,
# qual, tool, args, status (ok | error | crash | hang), ms, tokens, rows (row
# lines of the answer), claimed (the count the header states, when it states
# one), cut (a "N more ... limit" note), header (the first line), notes (the
# lines that are neither rows nor headings: "also through", "(built-ins
# called: ...)", "no form file names it") and text (the whole answer, unless
# -NoText). The console gets a summary per tool: calls, errors, p50/p95 ms,
# p95 tokens.
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Sample = 0,
    [int]$Seed = 1,
    [string]$Symbols,
    [string]$SampleOut,
    [string]$Calls,
    [switch]$Forms,
    [int]$Outlines = 0,
    [int]$LibProbe = 60,
    # regex over group-relative paths (forward slashes) kept out of the sample
    # and of -Outlines, e.g. '^ThirdParty/' - vendored code under the group
    # directory counts as own otherwise
    [string]$Exclude = '',
    # category=weight,... - a category left out keeps its default
    [string]$Weights = '',
    [string]$Exe,           # default out\pastree-mcp.exe beside tests\
    [string]$Groups = 'shared',
    [string]$BuildDir,      # passed as --build-dir (a compile call in -Calls)
    [int]$CallTimeout = 180,
    [int]$LoadTimeout = 600,
    [int]$MaxRestarts = 20,
    [switch]$NoText
)

$ErrorActionPreference = 'Stop'
if (-not $Exe) { $Exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'out\pastree-mcp.exe' }
$Exe = (Resolve-Path $Exe).Path
$Project = (Resolve-Path $Project).Path
$root = Split-Path -Parent $Project
$Out = [IO.Path]::GetFullPath($Out)
$work = [IO.Path]::ChangeExtension($Out, $null).TrimEnd('.') + '.work'
New-Item -ItemType Directory -Force $work | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$utf8Bom = New-Object Text.UTF8Encoding($true)

# ---- running calls, with the watchdog -------------------------------------------

$script:runNo = 0
# Each call is "tool json"; the answers come back in order. A call the server
# died or hung on is answered { Status = crash | hang } and the run restarts
# after it.
function Invoke-Calls([string[]]$List, [string]$Tag) {
    $answers = New-Object System.Collections.ArrayList
    $k = 0
    $restarts = 0
    while ($k -lt $List.Count) {
        $script:runNo++
        $base = Join-Path $work ('{0}-{1:D2}' -f $Tag, $script:runNo)
        [IO.File]::WriteAllLines("$base.calls", [string[]]$List[$k..($List.Count - 1)], $utf8Bom)
        $argList = @('--project', "`"$Project`"", '--groups', $Groups, '--log', "`"$base.log`"", '--script', "`"$base.calls`"")
        if ($BuildDir) { $argList += @('--build-dir', "`"$BuildDir`"") }
        $p = Start-Process -FilePath $Exe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err"
        $null = $p.Handle     # else 5.1 forgets ExitCode once the process is gone
        $lastLen = -1; $lastGrow = [DateTime]::Now; $firstSeen = $false; $killed = $false
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 500
            $len = 0
            if (Test-Path "$base.out") { $len = (Get-Item "$base.out").Length }
            if ($len -ne $lastLen) { $lastLen = $len; $lastGrow = [DateTime]::Now; if ($len -gt 0) { $firstSeen = $true } }
            $limit = if ($firstSeen) { $CallTimeout } else { $LoadTimeout + $CallTimeout }
            if (([DateTime]::Now - $lastGrow).TotalSeconds -gt $limit) {
                try { $p.Kill() } catch {}
                $killed = $true
                break
            }
        }
        $p.WaitForExit()
        $got = Read-Answers "$base.out"
        foreach ($a in $got) { [void]$answers.Add($a) }
        $k += $got.Count
        if ($k -lt $List.Count) {
            $status = if ($killed) { 'hang' } else { 'crash' }
            $exit = if ($killed) { $null } else { $p.ExitCode }
            $err = ''
            if (Test-Path "$base.err") { $err = (Get-Content "$base.err" -Tail 5 -ErrorAction SilentlyContinue) -join ' | ' }
            Write-Host ("  {0} at call {1}: {2} (exit {3}) {4}" -f $status, $k, $List[$k], $exit, $err)
            [void]$answers.Add([pscustomobject]@{ Status = $status; Ms = $null; Tokens = $null; Lines = @("$status, exit $exit; $err") })
            $k++
            $restarts++
            if ($restarts -gt $MaxRestarts) {
                Write-Host "  more than $MaxRestarts restarts - the rest is not run"
                while ($k -lt $List.Count) {
                    [void]$answers.Add([pscustomobject]@{ Status = 'skipped'; Ms = $null; Tokens = $null; Lines = @() })
                    $k++
                }
            }
        }
    }
    return , $answers
}

function Read-Answers([string]$Path) {
    $res = New-Object System.Collections.ArrayList
    if (-not (Test-Path $Path)) { return , $res }
    $cur = $null
    foreach ($line in [IO.File]::ReadAllLines($Path, $utf8)) {
        if ($line -match '^=== \S+ .*  \((\d+) ms, ~(\d+) tokens(, ERROR)?\)$') {
            $cur = [pscustomobject]@{ Status = $(if ($Matches[3]) { 'error' } else { 'ok' }); Ms = [int]$Matches[1]; Tokens = [int]$Matches[2]; Lines = New-Object System.Collections.ArrayList }
            [void]$res.Add($cur)
        }
        elseif ($line -match '^=== \S+ .* === BAD JSON$') {
            $cur = [pscustomobject]@{ Status = 'badjson'; Ms = $null; Tokens = $null; Lines = New-Object System.Collections.ArrayList }
            [void]$res.Add($cur)
        }
        elseif ($cur) { [void]$cur.Lines.Add($line) }
    }
    # A process killed mid-answer leaves the last one without its end: it
    # still counts as answered (its header line is written with its text).
    return , $res
}

# ---- JSON by hand (ConvertTo-Json is slow and mangles on 5.1) --------------------

function J([object]$v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
    $s = [string]$v
    $sb = New-Object Text.StringBuilder ($s.Length + 2)
    [void]$sb.Append('"')
    foreach ($c in $s.ToCharArray()) {
        switch ($c) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default { if ([int]$c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) } }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function JArr($items) { return '[' + (($items | ForEach-Object { J $_ }) -join ',') + ']' }

# ---- the Pascal files of the group directory --------------------------------------

function Get-GroupFiles([string]$Pattern) {
    Push-Location $root
    try {
        $ErrorActionPreference = 'Continue'
        $rel = git ls-files -co --exclude-standard 2>$null
        $ok = $LASTEXITCODE -eq 0
        $ErrorActionPreference = 'Stop'
        if (-not $ok) { $rel = Get-ChildItem -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) } }
    }
    finally { Pop-Location }
    return @($rel | Where-Object { $_ -match $Pattern } | ForEach-Object { $_.Replace('\', '/') } | Sort-Object)
}

# A path as the calls take it: relative with forward slashes (JSON without
# escapes), or absolute for a library file.
function PathArg([string]$File) { return $File.Replace('\', '/') }

$lineCache = @{}
function Source-Line([string]$File, [int]$Line) {
    $full = if ([IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $root $File }
    if (-not $lineCache.ContainsKey($full)) {
        if (Test-Path -LiteralPath $full) { $lineCache[$full] = [IO.File]::ReadAllLines($full) } else { $lineCache[$full] = @() }
    }
    $lines = $lineCache[$full]
    if ($Line -ge 1 -and $Line -le $lines.Count) { return $lines[$Line - 1] }
    return ''
}

function Has-Form([string]$File) {
    $b = [IO.Path]::ChangeExtension((Join-Path $root $File), $null).TrimEnd('.')
    return (Test-Path -LiteralPath "$b.dfm") -or (Test-Path -LiteralPath "$b.fmx")
}

# The class the unit's form file is of - its first line, `object frmMain:
# TfrmMain` - so that a helper class in a form unit is not taken for the
# form. '' for a binary form file or none.
function Form-Class([string]$File) {
    $b = [IO.Path]::ChangeExtension((Join-Path $root $File), $null).TrimEnd('.')
    foreach ($ext in '.dfm', '.fmx') {
        if (-not (Test-Path -LiteralPath "$b$ext")) { continue }
        $first = Get-Content -LiteralPath "$b$ext" -TotalCount 1 -ErrorAction SilentlyContinue
        if ($first -match '^\W*(object|inherited|inline)\s+\w+\s*:\s*(\w+)') { return $Matches[2] }
    }
    return ''
}

# ---- sampling --------------------------------------------------------------------

$defaultWeights = [ordered]@{
    routine = 8; method = 20; handler = 10; component = 5; field = 7; property = 9
    class = 8; interface = 4; type = 5; const = 3; var = 3
    libroutine = 5; libmethod = 9; libtype = 4
}
foreach ($pair in ($Weights -split ',' | Where-Object { $_ -match '=' })) {
    $kv = $pair -split '=', 2
    if (-not $defaultWeights.Contains($kv[0].Trim())) { throw "unknown category in -Weights: $($kv[0])" }
    $defaultWeights[$kv[0].Trim()] = [double]$kv[1]
}

function New-Sym($Cat, $Origin, $Size, $Form, $File, $Line, $Name, $Qual) {
    return [pscustomobject]@{ Cat = $Cat; Origin = $Origin; Size = $Size; Form = [bool]$Form
        File = $File; Line = [int]$Line; Name = $Name; Qual = $Qual }
}

function SizeBucket([int]$Lines) { if ($Lines -lt 500) { 'S' } elseif ($Lines -lt 3000) { 'M' } else { 'L' } }

# Declarations of one outline answer. Rows: "<line> <text>" with one space
# after the number for a section, two for a unit-level declaration, four for
# a member (the owner is the type row above).
function Parse-Outline($File, $Answer, $Candidates) {
    if ($Answer.Status -ne 'ok' -or $Answer.Lines.Count -eq 0) { return $false }
    if ($Answer.Lines[0] -notmatch '\((\d+) lines\)') { return $false }
    $size = SizeBucket ([int]$Matches[1])
    $form = Has-Form $File
    $formClass = if ($form) { Form-Class $File } else { '' }
    $section = ''
    $owner = $null; $ownerKind = ''; $ownerHadMethod = $false
    $types = @{}
    $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $Answer.Lines) {
        if ($l -notmatch '^(\d+)( +)(.*)$') { continue }
        $ln = [int]$Matches[1]; $ind = $Matches[2].Length; $t = $Matches[3].Trim()
        if ($ind -eq 1) {
            if ($t -eq 'interface' -or $t -eq 'implementation') { $section = $t }
            elseif ($t -match '^(initialization|finalization)') { $section = 'init' }
            continue
        }
        if ($ind -eq 2) {
            $owner = $null
            if ($t -match '^type\s+([\w]+(?:<[^>]*>)?)\s*=\s*(\S+)') {
                $n = $Matches[1] -replace '<.*$', ''; $kw = $Matches[2].ToLower()
                $cat = if ($kw -match '^class') { 'class' } elseif ($kw -match '^(interface|dispinterface)') { 'interface' } else { 'type' }
                # A forward declaration and the full one: the last row wins.
                $types[$n] = New-Sym $cat 'own' $size $form $File $ln $n $n
                if ($cat -eq 'class' -or $cat -eq 'interface' -or $kw -match '^record') { $owner = $n; $ownerKind = $cat; $ownerHadMethod = $false }
                continue
            }
            if ($section -eq 'implementation' -and $t -match '^(class\s+)?(function|procedure|constructor|destructor|operator)\s+[\w<>]+\.') { continue }
            if ($t -match '^(class\s+)?(function|procedure)\s+(\w+)') {
                # The body of a routine the interface declares is the same
                # symbol: its declaration row is the candidate.
                $n = $Matches[3]
                if ($section -eq 'implementation' -and $declared.Contains($n)) { continue }
                if ($section -eq 'interface') { [void]$declared.Add($n) }
                [void]$Candidates.Add((New-Sym 'routine' 'own' $size $form $File $ln $n $n)); continue
            }
            if ($t -match '^(var|threadvar)\s+(\w+)') { [void]$Candidates.Add((New-Sym 'var' 'own' $size $form $File $ln $Matches[2] $Matches[2])); continue }
            if ($t -match '^(const|resourcestring)\s+(\w+)') { [void]$Candidates.Add((New-Sym 'const' 'own' $size $form $File $ln $Matches[2] $Matches[2])); continue }
            continue
        }
        if ($ind -ge 4 -and $owner) {
            $q = "$owner."
            if ($t -match '^(class\s+)?(function|procedure|constructor|destructor|operator)\s+(\w+)') {
                $ownerHadMethod = $true
                $n = $Matches[3]
                $cat = 'method'
                if ($formClass -and $owner -eq $formClass -and $t -match '\(\s*Sender\s*:') { $cat = 'handler' }
                [void]$Candidates.Add((New-Sym $cat 'own' $size $form $File $ln $n ($q + $n)))
            }
            elseif ($t -match '^(class\s+)?property\s+(\w+)') {
                $ownerHadMethod = $true
                [void]$Candidates.Add((New-Sym 'property' 'own' $size $form $File $ln $Matches[2] ($q + $Matches[2])))
            }
            elseif ($t -match '^(field|class var)\s+(\w+)') {
                $cat = if ($formClass -and $owner -eq $formClass -and -not $ownerHadMethod) { 'component' } else { 'field' }
                [void]$Candidates.Add((New-Sym $cat 'own' $size $form $File $ln $Matches[2] ($q + $Matches[2])))
            }
        }
    }
    foreach ($s in $types.Values) { [void]$Candidates.Add($s) }
    return $true
}

# Library declarations of one callees answer: the rows under a file outside
# the group directory, and the types they are grouped under.
function Parse-Callees($Answer, $Candidates, $Seen) {
    if ($Answer.Status -ne 'ok') { return }
    $file = $null; $type = $null
    foreach ($l in $Answer.Lines) {
        if ($l -match '^(\S.*\.(pas|inc|dpr))$') {
            $file = if ([IO.Path]::IsPathRooted($Matches[1])) { $Matches[1] } else { $null }
            $type = $null; continue
        }
        if (-not $file) { continue }
        if ($l -match '^  ([A-Za-z_]\w*)$') {
            $type = $Matches[1]
            $unit = [IO.Path]::GetFileNameWithoutExtension($file)
            $key = "type|$unit.$type"
            if ($Seen.Add($key)) { [void]$Candidates.Add((New-Sym 'libtype' 'library' '-' $false $file 0 $type "$unit.$type")) }
            continue
        }
        if ($l -match '^\s+(\d+)\s+\[at [^\]]*\]\s+(class\s+)?(function|procedure|constructor|destructor)\s+(\w+)') {
            $ln = [int]$Matches[1]; $n = $Matches[4]
            $key = "$file|$ln"
            if (-not $Seen.Add($key)) { continue }
            if ($l -match '^    ' -and $type) { [void]$Candidates.Add((New-Sym 'libmethod' 'library' '-' $false $file $ln $n "$type.$n")) }
            elseif ($l -notmatch '^    ') { [void]$Candidates.Add((New-Sym 'libroutine' 'library' '-' $false $file $ln $n "$([IO.Path]::GetFileNameWithoutExtension($file)).$n")) }
        }
    }
}

function Shuffle($Items, $Rng) {
    $a = @($Items)
    for ($i = $a.Count - 1; $i -gt 0; $i--) {
        $j = $Rng.Next($i + 1)
        $t = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $t
    }
    return , $a
}

# A quota per category from the weights; within one, round the size buckets.
function Draw($Candidates, [int]$N, $Rng) {
    $byCat = @{}
    foreach ($c in $Candidates) {
        if (-not $byCat.ContainsKey($c.Cat)) { $byCat[$c.Cat] = New-Object System.Collections.ArrayList }
        [void]$byCat[$c.Cat].Add($c)
    }
    $cats = @($defaultWeights.Keys | Where-Object { $byCat.ContainsKey($_) -and $defaultWeights[$_] -gt 0 })
    $wsum = 0.0; foreach ($c in $cats) { $wsum += $defaultWeights[$c] }
    $quota = @{}; $given = 0
    foreach ($c in $cats) { $quota[$c] = [Math]::Max(1, [int][Math]::Floor($N * $defaultWeights[$c] / $wsum)); $given += $quota[$c] }
    # What the floors left, to the heaviest categories first.
    $order = @($cats | Sort-Object { - $defaultWeights[$_] })
    $i = 0
    while ($given -lt $N -and $order.Count -gt 0) { $quota[$order[$i % $order.Count]]++; $given++; $i++ }
    while ($given -gt $N) { $c = $order[$i % $order.Count]; if ($quota[$c] -gt 1) { $quota[$c]--; $given-- }; $i++ }
    $picked = New-Object System.Collections.ArrayList
    foreach ($c in $cats) {
        $buckets = [ordered]@{}
        foreach ($s in (Shuffle $byCat[$c] $Rng)) {
            if (-not $buckets.Contains($s.Size)) { $buckets[$s.Size] = New-Object System.Collections.Queue }
            $buckets[$s.Size].Enqueue($s)
        }
        $keys = @($buckets.Keys | Sort-Object)
        $take = [Math]::Min($quota[$c], $byCat[$c].Count)
        $got = 0; $b = $Rng.Next([Math]::Max(1, $keys.Count))
        while ($got -lt $take) {
            $q = $buckets[$keys[$b % $keys.Count]]
            if ($q.Count -gt 0) { [void]$picked.Add($q.Dequeue()); $got++ }
            $b++
        }
    }
    return , $picked
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$syms = New-Object System.Collections.ArrayList
$ownUnits = New-Object System.Collections.ArrayList

if ($Sample -gt 0 -or $Outlines -gt 0) {
    $files = Get-GroupFiles '\.(pas|dpr|dpk)$'
    if ($Exclude) { $files = @($files | Where-Object { $_ -notmatch $Exclude }) }
    Write-Host "outline of $($files.Count) files of $root"
    $ans = Invoke-Calls ($files | ForEach-Object { 'outline {"file":' + (J (PathArg $_)) + '}' }) 'outline'
    $cands = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $files.Count; $i++) {
        if (Parse-Outline $files[$i] $ans[$i] $cands) { [void]$ownUnits.Add($files[$i]) }
    }
    Write-Host ("  {0} own units, {1:N0} declarations; {2:N1} s" -f $ownUnits.Count, $cands.Count, $sw.Elapsed.TotalSeconds)
    if ($Sample -gt 0) {
        $rng = New-Object System.Random $Seed
        # Library declarations: what the callees of some own routines reach.
        $pool = Shuffle @($cands | Where-Object { $_.Cat -in 'method', 'handler', 'routine' }) $rng
        $probe = @($pool | Select-Object -First $LibProbe)
        if ($probe.Count -gt 0 -and ($defaultWeights.libroutine + $defaultWeights.libmethod + $defaultWeights.libtype) -gt 0) {
            Write-Host "callees of $($probe.Count) own routines, for the library's declarations"
            $pans = Invoke-Calls ($probe | ForEach-Object { 'callees {"file":' + (J (PathArg $_.File)) + ',"line":' + $_.Line + ',"name":' + (J $_.Name) + '}' }) 'probe'
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($a in $pans) { Parse-Callees $a $cands $seen }
        }
        $counts = $cands | Group-Object Cat | ForEach-Object { "$($_.Name) $($_.Count)" }
        Write-Host "  candidates: $($counts -join ', ')"
        foreach ($s in (Draw $cands $Sample $rng)) { [void]$syms.Add($s) }
    }
}
if ($Symbols) {
    foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Symbols).Path)) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $f = $t -split "`t"
        if ($f.Count -ge 8) { [void]$syms.Add((New-Sym $f[0] $f[1] $f[2] ($f[3] -eq 'form') $f[4] ([int]$f[5]) $f[6] $f[7])) }
        else { [void]$syms.Add((New-Sym 'named' '?' '-' $false '' 0 $t $t)) }
    }
}
if ($SampleOut -and $syms.Count -gt 0) {
    $rowsOut = @("# cat`torigin`tsize`tform`tfile`tline`tname`tqual - tests\audit.ps1 -Seed $Seed -Sample $Sample, $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($s in $syms) { $rowsOut += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $s.Cat, $s.Origin, $s.Size, $(if ($s.Form) { 'form' } else { '-' }), $s.File, $s.Line, $s.Name, $s.Qual) }
    [IO.File]::WriteAllLines([IO.Path]::GetFullPath($SampleOut), [string[]]$rowsOut, $utf8)
    Write-Host "sample: $SampleOut ($($syms.Count) symbols)"
}

# ---- the battery -----------------------------------------------------------------

function Addr($s) {
    if ($s.Line -le 0) { return '"symbol":' + (J $s.Qual) }
    return '"file":' + (J (PathArg $s.File)) + ',"line":' + $s.Line + ',"name":' + (J $s.Name)
}

function Battery($s) {
    $a = Addr $s
    $c = New-Object System.Collections.ArrayList
    [void]$c.Add('find {"query":' + (J $s.Qual) + '}')
    [void]$c.Add("definition {$a}")
    [void]$c.Add("references {$a}")
    $decl = if ($s.Line -gt 0) { Source-Line $s.File $s.Line } else { '' }
    switch -regex ($s.Cat) {
        '^(routine|method|handler|libroutine|libmethod)$' {
            [void]$c.Add("source {$a}")
            [void]$c.Add("callers {$a}")
            [void]$c.Add("callees {$a}")
            if ($decl -match '\b(virtual|dynamic|override|abstract)\b') { [void]$c.Add("related {""relation"":""overrides"",$a}") }
        }
        '^class$' {
            [void]$c.Add("members {$a}")
            [void]$c.Add("source {$a}")
            [void]$c.Add("related {""relation"":""descendants"",$a}")
            [void]$c.Add("related {""relation"":""creations"",$a}")
        }
        '^libtype$' {
            [void]$c.Add("members {$a}")
            [void]$c.Add("related {""relation"":""descendants"",$a}")
        }
        '^interface$' {
            [void]$c.Add("members {$a}")
            [void]$c.Add("related {""relation"":""descendants"",$a}")
            [void]$c.Add("related {""relation"":""implementations"",$a}")
        }
        '^type$' {
            if ($decl -match '=\s*(packed\s+)?record\b') { [void]$c.Add("members {$a}") }
            [void]$c.Add("source {$a}")
        }
        '^(field|property|component|var)$' {
            [void]$c.Add("related {""relation"":""assignments"",$a}")
            [void]$c.Add("members {$a}")
        }
        '^const$' { [void]$c.Add("source {$a}") }
    }
    [void]$c.Add("impact {$a}")
    return , $c
}

$plan = New-Object System.Collections.ArrayList     # { Sym (index or -1), Call }
for ($i = 0; $i -lt $syms.Count; $i++) {
    foreach ($call in (Battery $syms[$i])) { [void]$plan.Add([pscustomobject]@{ Sym = $i; Call = $call }) }
}
if ($Forms) {
    foreach ($f in (Get-GroupFiles '\.(dfm|fmx)$')) { [void]$plan.Add([pscustomobject]@{ Sym = -1; Call = 'form {"file":' + (J $f) + '}' }) }
}
if ($Outlines -gt 0) {
    $rngO = New-Object System.Random ($Seed + 7919)
    $pool = Shuffle $ownUnits $rngO
    foreach ($f in @($pool | Select-Object -First $Outlines)) { [void]$plan.Add([pscustomobject]@{ Sym = -1; Call = 'outline {"file":' + (J $f) + '}' }) }
}
if ($Calls) {
    foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Calls).Path)) {
        $t = $l.Trim()
        if ($t -ne '' -and -not $t.StartsWith('#')) { [void]$plan.Add([pscustomobject]@{ Sym = -1; Call = $t }) }
    }
}
if ($plan.Count -eq 0) { throw 'nothing to run: give -Sample, -Symbols, -Forms, -Outlines or -Calls' }

Write-Host "running $($plan.Count) calls ($($syms.Count) symbols) on $Project ($Groups) with $Exe"
$swRun = [Diagnostics.Stopwatch]::StartNew()
$answers = Invoke-Calls ([string[]]($plan | ForEach-Object { $_.Call })) 'battery'
Write-Host ("  {0:N1} min" -f $swRun.Elapsed.TotalMinutes)

# ---- one JSON line per call ------------------------------------------------------

$srcExt = '\.(pas|dpr|dpk|inc|dfm|fmx)'
$lines = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $plan.Count; $i++) {
    $p = $plan[$i]; $a = $answers[$i]
    $tool = ($p.Call -split ' ', 2)[0]
    $argJson = if ($p.Call.Contains(' ')) { ($p.Call -split ' ', 2)[1] } else { '{}' }
    $s = if ($p.Sym -ge 0) { $syms[$p.Sym] } else { $null }
    $rows = 0; $notes = New-Object System.Collections.ArrayList; $cut = $false
    $header = if ($a.Lines.Count -gt 0) { $a.Lines[0] } else { '' }
    for ($k = 0; $k -lt $a.Lines.Count; $k++) {
        $l = $a.Lines[$k]
        if ($k -gt 0 -and ($l -match '^\s*\d+\s' -or $l -match "^[^\s:]+${srcExt}:\d+\s" -or $l -match "^[A-Za-z]:\\.*${srcExt}:\d+\s")) { $rows++; continue }
        if ($k -eq 0) {
            # find has no header: its first line is a row already.
            if ($l -match "^([^\s:]+|[A-Za-z]:\\.*)${srcExt}:\d+\s") { $rows++ }
            continue
        }
        if ($l -match "^\S.*$srcExt$") { continue }                 # a file heading
        if ($l -match '^\s+[\w.<>,]+(\s\(root\))?$') { continue }      # an enclosing routine, type or component
        if ($l.Trim() -eq '') { continue }
        if ($l -match '\bmore\b.*\blimit\b') { $cut = $true }
        [void]$notes.Add($l.Trim())
    }
    $claimed = $null
    if ($header -match ' - no calls, (\d+) form binding') { $claimed = [int]$Matches[1] }
    elseif ($header -match '(?: - |\): |: )(\d+)\b') { $claimed = [int]$Matches[1] }
    elseif ($header -match ' - none found$') { $claimed = 0 }
    $j = '{"seq":' + $i + ',"sym":' + $p.Sym
    if ($s) {
        $j += ',"cat":' + (J $s.Cat) + ',"origin":' + (J $s.Origin) + ',"size":' + (J $s.Size) + ',"form":' + (J $s.Form) + ',"qual":' + (J $s.Qual)
    }
    $j += ',"tool":' + (J $tool) + ',"args":' + $argJson + ',"status":' + (J $a.Status) + ',"ms":' + (J $a.Ms) + ',"tokens":' + (J $a.Tokens)
    $j += ',"rows":' + $rows + ',"claimed":' + (J $claimed) + ',"cut":' + (J $cut) + ',"header":' + (J $header) + ',"notes":' + (JArr $notes)
    if (-not $NoText) { $j += ',"text":' + (J ($a.Lines -join "`n")) }
    $j += '}'
    [void]$lines.Add($j)
}
[IO.File]::WriteAllLines($Out, [string[]]$lines, $utf8)

# ---- summary ---------------------------------------------------------------------

function Pct($sorted, [double]$q) {
    if ($sorted.Count -eq 0) { return '-' }
    return $sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Floor($q * $sorted.Count))]
}
$sum = for ($i = 0; $i -lt $plan.Count; $i++) {
    [pscustomobject]@{ Tool = ($plan[$i].Call -split ' ', 2)[0]; Status = $answers[$i].Status; Ms = $answers[$i].Ms; Tokens = $answers[$i].Tokens }
}
$tab = $sum | Group-Object Tool | Sort-Object Name | ForEach-Object {
    $ms = @($_.Group | Where-Object { $null -ne $_.Ms } | ForEach-Object { $_.Ms } | Sort-Object)
    $tk = @($_.Group | Where-Object { $null -ne $_.Tokens } | ForEach-Object { $_.Tokens } | Sort-Object)
    [pscustomobject]@{
        Tool = $_.Name; Calls = $_.Count
        Error = @($_.Group | Where-Object { $_.Status -eq 'error' }).Count
        Crash = @($_.Group | Where-Object { $_.Status -in 'crash', 'hang', 'skipped', 'badjson' }).Count
        MsP50 = Pct $ms 0.5; MsP95 = Pct $ms 0.95; MsMax = $(if ($ms.Count) { $ms[-1] } else { '-' })
        TokP50 = Pct $tk 0.5; TokP95 = Pct $tk 0.95; TokMax = $(if ($tk.Count) { $tk[-1] } else { '-' })
    }
}
$tab | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("{0} calls -> {1}; {2:N1} min in all; working files in {3}" -f $plan.Count, $Out, $sw.Elapsed.TotalMinutes, $work)
