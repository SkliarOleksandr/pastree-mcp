# Working in this repository

`README.md` is what the server does and how to run it, `SPEC.md` why its tools
and its group handling are shaped as they are. This file is the rules that
apply to every change. The siblings `pastree-lsp` and `object-pascal-tree`
(PasTree) keep their own `CLAUDE.md` in the same shape; the rules shared by
all three are written the same way - keep them in step.

Every rule here is here because breaking it is silent. Keep the reasons when
editing this file - a rule with no reason gets "fixed" back.

## Do not commit until Alex has tried it

**Build, report, stop.** The commit waits for Alex. Exception: an explicitly
autonomous session ("work autonomously", a scheduled run).

A green smoke test covers a two-project fixture. What matters is an agent on a
real group, and that is only seen by running it there.

## English, plain hyphens, no client names, `local/` for working papers

**Everything written into this repository is in English** - docs, comments,
log lines, commit messages, tool descriptions. Conversation is in whatever
language suits; the repository is not, because it outlives the conversation
and the next reader may be a stranger or a future session.

**Only the plain hyphen `-`. Never an em dash (U+2014) or en dash (U+2013).**
They are non-ASCII, and `dcc` on a legacy code page, `cmd.exe` and the diff
tools each render them differently. Sweep before committing - nothing may come
back:

```bash
git ls-files | xargs grep -l -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')"
```

**Tracked files never name the closed client project** or its code - say "the
client group". Measurements and logs from it go to `local/`, which is ignored,
as do plans, audits and in-flight notes. A finished conclusion belongs in a
tracked document (SPEC.md, README.md); the working paper that produced it does
not.

## Line endings: CRLF for everything Delphi and cmd.exe read

`.pas`, `.dpr`, `.dpk`, `.inc`, `.dproj`, `.groupproj`, `.dfm`, `.bat`, `.ps1`
are CRLF; `.md`, `.json`, `.calls`, `.bench` are LF (`.gitattributes`, the
same rules as PasTree's and pastree-lsp's - keep them in step). In Git Bash,
`sed -i` and `perl -pi` read through the crlf layer and write without it,
silently turning a whole file LF - and the index is LF for everything, so no
diff shows it until RAD Studio re-saves the file and the next diff is all of
it. `.claude/hooks/eol-crlf.sh` restores CRLF after each tool call
**for tracked files only**, and `.githooks/pre-commit` refuses such a commit
(`git config core.hooksPath .githooks` per clone). A NEW file is neither
tracked nor fixed - convert it yourself, then check every `eol=crlf` row reads
`w/crlf`:

```bash
git ls-files --eol | awk -F'\t' '$1 ~ /w[/]lf/ && $1 ~ /eol=crlf/ { print $2 }'
```

## One version, moved in every commit

`PasTreeMcpVersion` in `source/PasMcp.Version.pas`: PATCH on every commit,
MINOR for a new tool or a changed tool contract. The server reports it in
`serverInfo` and the log banner. `cMinPasTreeVersion` there is the PasTree
floor - raise it when a change depends on a library fix whose absence would
be a wrong answer rather than a compile error.

## Building and testing

```
build.bat [RAD Studio version] [--yes]
```

It must end with `built, smoke test passed`. `tests\smoke.ps1` runs every tool
through the CLI (both group policies) and once through real MCP stdio with an
edit on disk in between; the expectations pin fixture line numbers.

- **A running server holds the exe**: Claude Code keeps `out\pastree-mcp.exe`
  running per session. `build.bat` renames it aside (Windows allows renaming a
  running exe); the next session starts the new one.
- **Every `.dcu` goes to `out\dcu\<RAD Studio version>\win64`**, never beside
  a source - .dcu files are not portable between compiler versions.
- **PasTree `..\object-pascal-tree` may be under edit by another session.**
  Read the commit line `build.bat` prints; check `git status` there before
  touching anything, never `git add -A` there.
- **A new tool gets smoke rows, the empty case included** - a call over the
  fixture and one where the walk finds nothing (no members, no callers).
  pastree-lsp shipped an access violation on an empty scope that no request
  had exercised.
- **Measure with the CLI** (`--script`, README): one analysis, many calls, the
  time and approximate tokens of each answer. A change to a tool's output is a
  change to what every agent session pays; look at the numbers.

## Three traps

**stdout is the protocol.** One stray `Writeln` - here or in anything linked -
and the client drops the connection with a JSON parse error naming no cause.
Log through `PasMcp.Log`, which writes stderr and the log file.

**A `}` in a `{ }` comment closes it.** A JSON example in a Delphi brace
comment (`{"query":...}`) ends the comment at its first `}` and the compiler
reports nonsense lines below it. Keep JSON out of brace comments; use `//`.

**Assume a BOM.** Delphi writes UTF-8 with a BOM by default, so a leading BOM
is the common case and never content. Read text with `TFile.ReadAllText` /
`ReadAllLines` (BOM-aware) or through PasTree, never byte by byte by hand. In
pastree-lsp one BOM made a whole file resolve nothing while the log said only
`no identifier at`.

## Where the answers are

- A failure an agent or a user reports: `<project>-pastree-mcp.log` beside the
  project (or `--log`), then stderr as Claude Code kept it.
- Why a tool or the group handling is shaped as it is: `SPEC.md`. Do not
  re-derive it; what is planned next is its section 9.
