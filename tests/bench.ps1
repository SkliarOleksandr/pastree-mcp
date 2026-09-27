# What an answer costs: pastree-mcp against the grep / Read an agent would
# otherwise do, over one project group.
#
#   powershell -File tests\bench.ps1 -Project X.groupproj -Bench questions.bench [-Out report.md]
#
# A .bench file lists questions (format in tests\fixture.bench). Each has the
# tool call that answers it and the baseline: the grep patterns and file reads
# an agent without the server would start with. For every question the report
# gives
#   - the tool answer: time and approximate tokens (chars / 4, as --script);
#   - the baseline: tokens of the grep output (path:line:text, as ripgrep and
#     Claude Code's Grep print it), of the same with 3 lines of context (what
#     it takes to tell a real hit from a namesake), plus the reads;
#   - the grep hits sorted against the answer: in the answer, in a comment or
#     string, or other (a namesake - or a row the answer missed); and the rows
#     of the answer grep did not find at all;
#   - with `also` lines, the tokens of the calls to the other tools the new
#     one replaces (the references per caller that `callers` saves).
#
# The baseline is a LOWER bound on what an agent pays: it counts one pass of
# each pattern and no file opened to disambiguate. The files grep searches are
# the Delphi sources under the group directory (git's view of them when it is
# a repository - ripgrep's view too); a `grep-dfm` line searches the text form
# files (.dfm, .fmx) with them, where a form binds its handlers and
# components by name. A binary form file is skipped, as ripgrep skips it -
# the agent does not see what it binds.
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Bench,
    [string]$Exe,           # default out\pastree-mcp.exe beside tests\
    [string]$Out,
    [string]$Groups = 'shared',
    [int]$Context = 3,
    # Claude Code's Grep shows 250 lines by default; beyond that the agent
    # pays for another call. Reported, not applied to the token counts.
    [int]$GrepCap = 250,
    # Per question in the report: the answer rows grep missed and up to this
    # many "other" hits, to check by eye which side is wrong.
    [int]$Detail = 0
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 has no $PSScriptRoot yet while it binds defaults.
if (-not $Exe) { $Exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'out\pastree-mcp.exe' }
$Project = (Resolve-Path $Project).Path
$root = Split-Path -Parent $Project

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public class BenchHit {
    public int File;
    public int Line;        // 1-based
    public bool InCode;     // the pattern matches the line with comments and strings blanked
}

public class BenchGrep {
    public List<BenchHit> Hits = new List<BenchHit>();
    public int Chars;       // path:line:text output
    public int CharsCtx;    // the same with context lines and -- separators
    public int Calls = 1;   // grep calls it took (descendants: one per level)
}

public class BenchCorpus {
    public List<string> Paths = new List<string>();
    List<string[]> raw = new List<string[]>();
    List<string[]> code = new List<string[]>();
    // Form files (.dfm, .fmx) are searched by grep-dfm only: a plain grep
    // line keeps the Pascal sources it always searched, so earlier reports
    // stay comparable.
    List<bool> form = new List<bool>();
    public int FormFiles;
    public int BinaryForms;     // skipped, as ripgrep skips a file with a NUL

    static readonly Encoding Utf8Strict = new UTF8Encoding(false, true);
    static readonly Encoding Ansi = Encoding.GetEncoding(1252);

    public static string[] ReadLines(string path) {
        byte[] b = File.ReadAllBytes(path);
        string s;
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
            s = Encoding.UTF8.GetString(b, 3, b.Length - 3);
        else if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE)
            s = Encoding.Unicode.GetString(b, 2, b.Length - 2);
        else {
            try { s = Utf8Strict.GetString(b); }
            catch (DecoderFallbackException) { s = Ansi.GetString(b); }
        }
        s = s.Replace("\r\n", "\n");
        if (s.EndsWith("\n")) s = s.Substring(0, s.Length - 1);
        return s.Split('\n');
    }

    public void Add(string relPath, string fullPath, bool isForm) {
        if (isForm) {
            // A binary form file (resource format or a bare TPF0 stream) is
            // not text to grep: Claude Code's Grep, ripgrep, shows nothing
            // of it.
            byte[] b = File.ReadAllBytes(fullPath);
            if (Array.IndexOf(b, (byte)0) >= 0) { BinaryForms++; return; }
            FormFiles++;
        }
        string[] lines = ReadLines(fullPath);
        Paths.Add(relPath);
        raw.Add(lines);
        code.Add(Blank(lines));
        form.Add(isForm);
    }

    public string Text(int file, int line) { return raw[file][line - 1]; }

    // Lines of the Pascal sources, or of the form files.
    public int LinesOf(bool forms) {
        int n = 0;
        for (int f = 0; f < raw.Count; f++) if (form[f] == forms) n += raw[f].Length;
        return n;
    }

    // Comments, directives and string literals replaced by spaces, columns kept.
    static string[] Blank(string[] lines) {
        string[] res = new string[lines.Length];
        int state = 0;   // 0 code, 1 { }, 2 (* *)
        for (int i = 0; i < lines.Length; i++) {
            char[] c = lines[i].ToCharArray();
            int j = 0;
            while (j < c.Length) {
                if (state == 1) {
                    if (c[j] == '}') state = 0;
                    c[j++] = ' ';
                } else if (state == 2) {
                    if (c[j] == '*' && j + 1 < c.Length && c[j + 1] == ')') { c[j++] = ' '; state = 0; }
                    c[j++] = ' ';
                } else if (c[j] == '{') {
                    state = 1; c[j++] = ' ';
                } else if (c[j] == '(' && j + 1 < c.Length && c[j + 1] == '*') {
                    state = 2; c[j++] = ' '; c[j++] = ' ';
                } else if (c[j] == '/' && j + 1 < c.Length && c[j + 1] == '/') {
                    while (j < c.Length) c[j++] = ' ';
                } else if (c[j] == '\'') {
                    c[j++] = ' ';
                    while (j < c.Length) {
                        if (c[j] == '\'') {
                            if (j + 1 < c.Length && c[j + 1] == '\'') { c[j++] = ' '; c[j++] = ' '; continue; }
                            c[j++] = ' ';
                            break;
                        }
                        c[j++] = ' ';
                    }
                } else j++;
            }
            res[i] = new string(c);
        }
        return res;
    }

    // Descendants the way an agent finds them without an index: grep for
    // classes declared over the root, then over those, one level per call
    // (every name of a level in one alternation - the cheapest it can be).
    public BenchGrep Descendants(string rootClass, int context) {
        BenchGrep all = new BenchGrep();
        all.Calls = 0;
        HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        List<string> level = new List<string>();
        level.Add(rootClass);
        seen.Add(rootClass);
        Regex decl = new Regex(@"(\w+)\s*(<[^=]*>)?\s*=\s*class\b", RegexOptions.IgnoreCase);
        while (level.Count > 0) {
            List<string> esc = new List<string>();
            foreach (string n in level) esc.Add(Regex.Escape(n));
            BenchGrep g = Grep(@"=\s*class\s*\(\s*(" + string.Join("|", esc.ToArray()) + @")\s*[,)<]", context, "", false);
            all.Calls++;
            all.Chars += g.Chars; all.CharsCtx += g.CharsCtx;
            all.Hits.AddRange(g.Hits);
            List<string> next = new List<string>();
            foreach (BenchHit h in g.Hits) {
                Match m = decl.Match(raw[h.File][h.Line - 1]);
                if (m.Success && seen.Add(m.Groups[1].Value)) next.Add(m.Groups[1].Value);
            }
            level = next;
        }
        return all;
    }

    public BenchGrep Grep(string pattern, int context, string pathPrefix, bool forms) {
        Regex re = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        BenchGrep g = new BenchGrep();
        for (int f = 0; f < raw.Count; f++) {
            if (form[f] && !forms) continue;
            if (pathPrefix.Length > 0 && !Paths[f].StartsWith(pathPrefix, StringComparison.OrdinalIgnoreCase)) continue;
            string[] lines = raw[f];
            string p = Paths[f];
            int lastShown = -1;     // 0-based index of the last line printed with context
            bool anyInFile = false;
            for (int i = 0; i < lines.Length; i++) {
                if (!re.IsMatch(lines[i])) continue;
                BenchHit h = new BenchHit();
                h.File = f; h.Line = i + 1; h.InCode = re.IsMatch(code[f][i]);
                g.Hits.Add(h);
                g.Chars += p.Length + (i + 1).ToString().Length + lines[i].Length + 3;
                int from = Math.Max(i - context, lastShown + 1);
                if (anyInFile && from > lastShown + 1) g.CharsCtx += 3;   // "--"
                int to = Math.Min(i + context, lines.Length - 1);
                for (int k = from; k <= to; k++)
                    g.CharsCtx += p.Length + (k + 1).ToString().Length + lines[k].Length + 3;
                if (to > lastShown) lastShown = to;
                anyInFile = true;
            }
        }
        return g;
    }
}
'@

# ---- the questions ------------------------------------------------------------
$questions = New-Object System.Collections.ArrayList
$q = $null
$lineNo = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $Bench).Path)) {
    $lineNo++
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -match '^==\s*(\S+)\s*\|\s*(.*)$') {
        $q = [pscustomobject]@{ Id = $Matches[1]; Text = $Matches[2]; Call = $null; Also = @(); Greps = @(); Reads = @() }
        [void]$questions.Add($q)
        continue
    }
    if ($null -eq $q) { throw "$Bench($lineNo): a question starts with ``== id | text``" }
    if ($t -match '^call\s+(.+)$') { $q.Call = $Matches[1] }
    elseif ($t -match '^also\s+(.+)$') { $q.Also += $Matches[1] }
    elseif ($t -match '^grep\s+(.+)$') { $q.Greps += [pscustomobject]@{ Kind = 'grep'; In = ''; Arg = $Matches[1] } }
    elseif ($t -match '^grep-in\s+(\S+)\s+(.+)$') { $q.Greps += [pscustomobject]@{ Kind = 'grep'; In = $Matches[1]; Arg = $Matches[2] } }
    elseif ($t -match '^grep-dfm\s+(.+)$') { $q.Greps += [pscustomobject]@{ Kind = 'grep-dfm'; In = ''; Arg = $Matches[1] } }
    elseif ($t -match '^descendants\s+(\S+)$') { $q.Greps += [pscustomobject]@{ Kind = 'descendants'; In = ''; Arg = $Matches[1] } }
    elseif ($t -match '^read\s+(\S+)(?:\s+(\d+)\s+(\d+))?$') {
        $q.Reads += [pscustomobject]@{ File = $Matches[1]; From = $Matches[2]; Count = $Matches[3] }
    }
    else { throw "$Bench($lineNo): expected call, also, grep, grep-in, grep-dfm, descendants or read: $t" }
}
foreach ($q in $questions) { if (-not $q.Call) { throw "question $($q.Id) has no call" } }

# ---- the tool answers: one analysis, every call --------------------------------
# Each question's call, then its `also` calls - the answers come back in that
# order.
$allCalls = New-Object System.Collections.ArrayList
foreach ($q in $questions) {
    [void]$allCalls.Add($q.Call)
    foreach ($c in $q.Also) { [void]$allCalls.Add($c) }
}
$calls = Join-Path ([IO.Path]::GetTempPath()) ('pastree-bench-' + [Guid]::NewGuid().ToString('N') + '.calls')
[IO.File]::WriteAllLines($calls, [string[]]$allCalls, (New-Object Text.UTF8Encoding($false)))
Write-Host "running $($allCalls.Count) calls on $Project ($Groups)"
$sw = [Diagnostics.Stopwatch]::StartNew()
$prevEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'     # stderr lines are log, not errors
$outLines = & $Exe --project $Project --groups $Groups --log none --script $calls 2>$null
$exit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = $prevEnc
Remove-Item $calls
if ($exit -ne 0) { throw "pastree-mcp exited with $exit" }
Write-Host ("  analysis and calls: {0:N1} s" -f $sw.Elapsed.TotalSeconds)

$answers = New-Object System.Collections.ArrayList
$cur = $null
foreach ($line in $outLines) {
    if ($line -match '^=== .*  \((\d+) ms, ~(\d+) tokens.*\)$') {
        $cur = [pscustomobject]@{ Ms = [int]$Matches[1]; Tokens = [int]$Matches[2]; Lines = New-Object System.Collections.ArrayList }
        [void]$answers.Add($cur)
    }
    elseif ($cur) { [void]$cur.Lines.Add($line) }
}
if ($answers.Count -ne $allCalls.Count) { throw "expected $($allCalls.Count) answers, got $($answers.Count)" }
# Back to the questions: the answer to its call, the tokens of its `also`.
$next = 0
foreach ($q in $questions) {
    $q | Add-Member -NotePropertyName Answer -NotePropertyValue $answers[$next]
    $next++
    $alt = 0
    foreach ($c in $q.Also) { $alt += $answers[$next].Tokens; $next++ }
    $q | Add-Member -NotePropertyName AltTokens -NotePropertyValue $alt
}

# (file, line) pairs an answer names. Rows: those under a file heading, and
# file:line written inline (find, descendants). Heading: the file:line of the
# answer's first line - the symbol's own declaration, which a grep hit is not
# noise for, but which is not a row grep should have found. A row of a form
# file is a site like any other.
$src = '\.(pas|dpr|dpk|inc|dfm|fmx)'
$pascal = '\.(pas|dpr|dpk|inc)'
$forms = '\.(dfm|fmx)'
function Answer-Sites($Answer) {
    $rows = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $heading = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $file = $null
    $first = $true
    foreach ($l in $Answer.Lines) {
        if ($l -match "^(\S.*$src)$") { $file = $Matches[1]; $first = $false; continue }
        if ($file -and $l -match '^\s+(\d+)\s\s') { [void]$rows.Add("$file|$($Matches[1])"); continue }
        if ($l -notmatch '^\s') { $file = $null }
        # find answers are rows from the first line: they start with file:line.
        # (Assigned in the branches: `$x = if ...` would enumerate the set.)
        if ($first -and $l -notmatch "^[^\s:]+${src}:\d+\s") { $into = $heading } else { $into = $rows }
        foreach ($m in [regex]::Matches($l, "([^\s:()]+$src):(\d+)", 'IgnoreCase')) {
            [void]$into.Add("$($m.Groups[1].Value)|$($m.Groups[3].Value)")
        }
        $first = $false
    }
    return [pscustomobject]@{ Rows = $rows; Heading = $heading }
}

# ---- the files grep would search ----------------------------------------------
$sw.Restart()
$rel = $null
Push-Location $root
try {
    $ErrorActionPreference = 'Continue'
    $rel = git ls-files -co --exclude-standard 2>$null
    $gitOk = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if (-not $gitOk) {
        $rel = Get-ChildItem -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) }
    }
}
finally { Pop-Location }
$corpus = New-Object BenchCorpus
foreach ($r in $rel) {
    $isForm = $r -match "$forms$"
    if (-not $isForm -and ($r -notmatch "$pascal$")) { continue }
    $full = Join-Path $root $r
    if (Test-Path -LiteralPath $full) { $corpus.Add($r.Replace('/', '\'), $full, $isForm) }
}
$pascalFiles = $corpus.Paths.Count - $corpus.FormFiles
Write-Host ("  corpus: {0} files, {1:N0} lines; form files {2}, {3:N0} lines, {4} binary skipped; {5:N1} s" -f `
    $pascalFiles, $corpus.LinesOf($false), $corpus.FormFiles, $corpus.LinesOf($true), $corpus.BinaryForms, $sw.Elapsed.TotalSeconds)

# ---- compare -------------------------------------------------------------------
function Read-Chars($Read) {
    $lines = [BenchCorpus]::ReadLines((Join-Path $root $Read.File))
    $from = 1; $count = $lines.Length
    if ($Read.From) { $from = [int]$Read.From; $count = [int]$Read.Count }
    $chars = 0; $n = 0
    for ($i = $from; $i -lt $from + $count -and $i -le $lines.Length; $i++) {
        $chars += 7 + $lines[$i - 1].Length      # "     N<tab>" as Read prints it
        $n++
    }
    # Read shows 2000 lines per call; a longer file takes more.
    return [pscustomobject]@{ Chars = $chars; Lines = $n }
}

$rows = New-Object System.Collections.ArrayList
foreach ($i in 0..($questions.Count - 1)) {
    $q = $questions[$i]; $a = $q.Answer
    $sites = Answer-Sites $a
    $hitKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $grepChars = 0; $ctxChars = 0; $calls = 0; $inAnswer = 0; $inComment = 0; $other = 0
    $otherText = New-Object System.Collections.ArrayList
    foreach ($p in $q.Greps) {
        if ($p.Kind -eq 'descendants') { $g = $corpus.Descendants($p.Arg, $Context) }
        else { $g = $corpus.Grep($p.Arg, $Context, $p.In, ($p.Kind -eq 'grep-dfm')) }
        $grepChars += $g.Chars; $ctxChars += $g.CharsCtx
        $calls += [Math]::Max($g.Calls, [Math]::Ceiling($g.Hits.Count / $GrepCap))
        foreach ($h in $g.Hits) {
            $key = "$($corpus.Paths[$h.File])|$($h.Line)"
            if (-not $hitKeys.Add($key)) { continue }
            if ($sites.Rows.Contains($key) -or $sites.Heading.Contains($key)) { $inAnswer++ }
            elseif (-not $h.InCode) { $inComment++ }
            else {
                $other++
                if ($otherText.Count -lt $Detail) {
                    [void]$otherText.Add("$($corpus.Paths[$h.File]):$($h.Line): $($corpus.Text($h.File, $h.Line).Trim())")
                }
            }
        }
    }
    $readChars = 0
    foreach ($r in $q.Reads) {
        $rc = Read-Chars $r
        $readChars += $rc.Chars; $calls += [Math]::Max(1, [Math]::Ceiling($rc.Lines / 2000))
    }
    $missed = 0
    $missedText = New-Object System.Collections.ArrayList
    foreach ($s in $sites.Rows) {
        if (-not $hitKeys.Contains($s)) { $missed++; [void]$missedText.Add($s.Replace('|', ':')) }
    }
    $base = [int](($grepChars + $readChars) / 4)
    $baseCtx = [int](($ctxChars + $readChars) / 4)
    [void]$rows.Add([pscustomobject]@{
        Id = $q.Id; Text = $q.Text; Call = $q.Call; Also = $q.Also; Greps = $q.Greps; Reads = $q.Reads
        Alt = if ($q.Also.Count -gt 0) { $q.AltTokens } else { $null }
        Ms = $a.Ms; Tool = $a.Tokens; AnswerFirst = ($a.Lines | Select-Object -First 1)
        Sites = $sites.Rows.Count; Base = $base; BaseCtx = $baseCtx; Calls = $calls
        Hits = $hitKeys.Count; InAnswer = $inAnswer; InComment = $inComment; Other = $other
        Missed = if ($q.Greps.Count -gt 0) { $missed } else { $null }
        OtherText = $otherText; MissedText = $missedText
    })
}

# ---- report --------------------------------------------------------------------
function Ratio($b, $t) { if ($t -le 0) { return '-' }; return ('{0:N1}x' -f ($b / $t)) }
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# pastree-mcp against grep")
[void]$md.Add("")
[void]$md.Add(("Group ``{0}``, policy {1}, {2} questions, {3} files / {4:N0} lines searched by grep - with {5} form files / {6:N0} lines by grep-dfm ({7} binary ones skipped, as grep skips them) - {8} ({9:yyyy-MM-dd HH:mm})." -f `
    (Split-Path -Leaf $Project), $Groups, $rows.Count, $pascalFiles, $corpus.LinesOf($false), $corpus.FormFiles, $corpus.LinesOf($true),
    $corpus.BinaryForms, (& $Exe --version 2>$null | Select-Object -First 1), (Get-Date)))
[void]$md.Add("")
[void]$md.Add("Tokens are characters / 4. **grep** = the grep output alone plus the reads; **+ctx** = with $Context lines of context, the least it takes to tell a real hit from a namesake. Both are lower bounds: one pass per pattern, no file opened. **calls** = baseline tool calls at Grep's $GrepCap-line page. Hits: **ans** in the answer, **c/s** inside a comment or string, **oth** other (a namesake, or a row the answer lacks); **miss** = answer rows grep did not find. **also** = the tokens of the calls to the other tools it replaces, and how many (`also` lines of the bench).")
[void]$md.Add("")
[void]$md.Add("| id | tool ms | tool tok | rows | grep tok | +ctx tok | +ctx / tool | calls | hits | ans | c/s | oth | miss | also tok (n) |")
[void]$md.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
$tTool = 0; $tBase = 0; $tCtx = 0
foreach ($r in $rows) {
    $tTool += $r.Tool; $tBase += $r.Base; $tCtx += $r.BaseCtx
    [void]$md.Add(("| {0} | {1} | {2:N0} | {3} | {4:N0} | {5:N0} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} |" -f `
        $r.Id, $r.Ms, $r.Tool, $r.Sites, $r.Base, $r.BaseCtx, (Ratio $r.BaseCtx $r.Tool), $r.Calls, $r.Hits, $r.InAnswer, $r.InComment, $r.Other, $r.Missed,
        $(if ($null -ne $r.Alt) { "{0:N0} ({1})" -f $r.Alt, $r.Also.Count } else { '' })))
}
[void]$md.Add(("| **total** | | **{0:N0}** | | **{1:N0}** | **{2:N0}** | **{3}** | | | | | | | |" -f $tTool, $tBase, $tCtx, (Ratio $tCtx $tTool)))
[void]$md.Add("")
[void]$md.Add("## Questions")
[void]$md.Add("")
foreach ($r in $rows) {
    [void]$md.Add("- **$($r.Id)** - $($r.Text)")
    [void]$md.Add("  - tool: ``$($r.Call)`` -> $($r.AnswerFirst)")
    foreach ($p in $r.Greps) {
        if ($p.Kind -eq 'descendants') { [void]$md.Add("  - grep, level by level: ``=\s*class\s*\(\s*(<names>)`` from ``$($p.Arg)``") }
        elseif ($p.In) { [void]$md.Add("  - grep in ``$($p.In)``: ``$($p.Arg)``") }
        elseif ($p.Kind -eq 'grep-dfm') { [void]$md.Add("  - grep, form files too: ``$($p.Arg)``") }
        else { [void]$md.Add("  - grep: ``$($p.Arg)``") }
    }
    foreach ($x in $r.Reads) { [void]$md.Add("  - read: ``$($x.File)$(if ($x.From) { " $($x.From) +$($x.Count)" })``") }
    foreach ($c in $r.Also) { [void]$md.Add("  - also: ``$c``") }
    if ($Detail -gt 0 -and $r.Greps.Count -gt 0) {
        foreach ($m in $r.MissedText) { [void]$md.Add("  - missed by grep: ``$m``") }
        foreach ($o in $r.OtherText) { [void]$md.Add("  - other: ``$o``") }
    }
}
$text = ($md -join "`n") + "`n"
if ($Out) {
    [IO.File]::WriteAllText($Out, $text, (New-Object Text.UTF8Encoding($false)))
    Write-Host "report: $Out"
}
$rows | Format-Table Id, Ms, Tool, Sites, Base, BaseCtx, Calls, Hits, InAnswer, InComment, Other, Missed, Alt -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("total: tool {0:N0} tokens, grep {1:N0}, grep with context {2:N0} ({3})" -f $tTool, $tBase, $tCtx, (Ratio $tCtx $tTool))
