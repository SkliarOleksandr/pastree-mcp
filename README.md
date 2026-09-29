# pastree-mcp

An [MCP](https://modelcontextprotocol.io) server that gives an AI coding agent
(Claude Code, or any MCP client) a **semantic index of a Delphi / Object Pascal
project group**, built by [PasTree](https://github.com/SkliarOleksandr/object-pascal-tree).

Without it, an agent answers "who calls `TFoo.Bar`" with grep: every `Bar` in
the tree, comments and strings included, then reading files to sort out which
hits are real, at thousands of tokens per question. With it, one call returns
exactly the uses the compiler would bind, one line each.

- **Semantic, not textual.** References, callers, overrides, implementations,
  descendants, assignments, creations and destructions come from resolved
  symbol identity - the same analysis that drives the
  [pastree-lsp](../pastree-lsp) editor features.
- **Project groups.** A `.groupproj` is read whole. Its projects are folded
  into as few analyses as their configurations allow, so shared units are
  parsed once, and every search runs across all of them.
- **Always current.** Before each call, files changed on disk are re-analyzed,
  one module at a time, so line numbers in answers match the files the agent
  just edited - and the answer names them, so an edit made by someone else
  shows.
- **Built for an agent.** Symbols are addressed by name (`TFoo.Bar`) or by file,
  line and identifier - no column counting. Answers are compact text:
  relative paths, grouped by file and by the routine each row sits in,
  capped.

Measured on the client group (9 projects, 7,700 units, Win32 + Win64, RAD
Studio 13): the whole group loads in **9 s / 2.7 GB** under the default policy,
or **16 s / 4.3 GB** under the exact one. Typical calls take 60-500 ms.

## Tools

| Tool | Answers |
| --- | --- |
| `status` | What is loaded: members, analyses, unit counts, unit names that do not resolve, load progress |
| `find` | Declarations by name, qualified name or wildcard, project units first; for a name the index does not hold, the Pascal files outside it that write it |
| `definition` | Where a symbol is declared and implemented, optionally with the source that follows |
| `source` | The exact text of one declaration - a routine's body, a whole type, a constant - numbered, with the comment above it |
| `members` | What a class, record or interface has, inherited members included, under the type declaring each - or what can be called on a variable, by its type |
| `references` | Every use across the group, grouped by file and by the routine or type it sits in; the form files' lines that bind it by name, under their component; also units, built-ins and conditional defines |
| `callers` | Who calls a routine - through the virtual method it overrides, an interface method it implements or a property it is the accessor of too, bare `inherited;` included, and the form lines that bind an event handler - and, with `depth`, who calls those |
| `callees` | What a routine calls - the overload each call binds to, a property's getter or setter, the overrides and implementations a virtual or interface call may run - and, with `depth`, what those call |
| `impact` | What a change reaches, from `git diff` output or the declarations about to change: which projects of the group to build and test, the declarations touched with what they override and are called through, their callers or uses, the units a changed interface recompiles, and the calls a removed routine left behind - the form lines too: a handler's bindings, a component's lines, a removed handler still bound |
| `compile` | Builds the members a change reaches with the real compiler (MSBuild over the `.dproj`) into a directory of its own, and answers with the errors - each with its routine and source line - and the warnings and hints the change added. Nothing of the project is overwritten and build events are not run; the first build starts from the developer's own `.dcu` files |
| `related` | `descendants`, `overrides`, `implementations`, `assignments`, `creations`, `destructions` |
| `outline` | The structure of one unit with line numbers, without reading it |
| `form` | The component tree of one form, merged with its ancestors' form files: each component's class, the method each event runs, the components it names - and a handler or a component a line names that does not exist |
| `diagnostics` | PasTree's semantic errors for a file or the whole group, from the files on disk now, each naming its routine |
| `unit_deps` | What a unit uses (resolved to files) and what uses it |

Design and rationale of each: [SPEC.md](SPEC.md).

## Setup

Requirements: Windows, a RAD Studio installation (12 or 13; its registry
library paths and RTL/VCL sources are what third-party and system units resolve
against), and [PasTree](https://github.com/SkliarOleksandr/object-pascal-tree)
checked out next to this repository as `..\object-pascal-tree`.

```
build.bat 37.0
```

builds `out\pastree-mcp.exe` (Win64) and runs the smoke test. It must end with
`built, smoke test passed`.

`pastree-mcp.dproj` builds the same exe by hand - in RAD Studio, or with
`msbuild pastree-mcp.dproj /p:Config=Release` from a RAD Studio command
prompt - with the same search path and output directories, but no smoke test.

### Claude Code

In the root of the Delphi project, add `.mcp.json`:

```json
{
  "mcpServers": {
    "pastree": {
      "command": "C:\\Repos\\pastree-mcp\\out\\pastree-mcp.exe",
      "args": ["--project", "MyGroup.groupproj"]
    }
  }
}
```

or register it once from that directory:

```
claude mcp add pastree -- C:\Repos\pastree-mcp\out\pastree-mcp.exe --project MyGroup.groupproj
```

To work on pastree-mcp itself with the index, point a `.mcp.json` in this
repository (ignored) at `--project pastree-mcp.dproj`: the agent gets this
server's sources and PasTree's.

Or once for every repository:

```
claude mcp add --scope user pastree -- C:\Repos\pastree-mcp\out\pastree-mcp.exe
```

Without `--project` the server takes the only `.groupproj` in its working
directory, else the only `.dproj`; a directory holding neither sends it up to
the parent, until the repository root (a `.git` directory or file). So a
session opened in a subdirectory of the project gets the project's index. A
directory with several `.groupproj` (or several `.dproj` and no `.groupproj`)
stops the walk with an error - that repository needs its own `.mcp.json` with
`--project`, which overrides the user-scope registration of the same name.
The tools then appear to the agent as
`mcp__pastree__find` and so on, together with instructions on when to prefer
them over grep. A new session is needed after registering or rebuilding.

### Options

| Option | Default | |
| --- | --- | --- |
| `--project <file>` | discovered | `.groupproj`, `.dproj`, `.dpr` or `.dpk` |
| `--studio <ver>` | `$BDS`, else newest | RAD Studio registry version: `37.0`, `23.0` |
| `--platform <p>` | per project | Override every member's platform: `Win32`, `Win64` |
| `--config <c>` | per project | Build configuration: `Debug`, `Release` |
| `--groups <p>` | `shared` | `shared`: one analysis per platform. `strict`: one per distinct configuration. See SPEC.md |
| `--build-dir <dir>` | `%TEMP%\pastree-mcp` | Where `compile` builds: a directory per group, member and configuration, kept between sessions so a build is incremental |
| `--log <file\|none>` | beside the project | `<project>-pastree-mcp.log`, truncated per run |

### Trying tools without a client

```
out\pastree-mcp.exe --project X.groupproj --call find {\"query\":\"TFoo\"}
out\pastree-mcp.exe --project X.groupproj --script calls.txt
```

`--script` reads one `tool {json}` per line (see `tests\smoke.calls`). The
analysis is built once, every call runs against it, and each answer is printed
with its time and approximate token count. This is the way to measure a tool
before an agent uses it.

### Measuring against grep

```
powershell -File tests\bench.ps1 -Project X.groupproj -Bench questions.bench -Out report.md
```

runs a list of questions (format in `tests\fixture.bench`), each with the tool
call that answers it and the grep patterns and reads an agent without the
server would start with. The report sets the tokens of the answer against the
grep output with and without context lines, and sorts every grep hit: in the
answer, in a comment or string, or a namesake - and the answer rows grep did
not find. `-Detail N` lists those hits. The baseline is a lower bound: one pass
per pattern, no file opened to tell hits apart. A `grep` line searches the
Pascal sources; `grep-dfm` the text form files (`.dfm`, `.fmx`) with them, and
skips a binary form file, as ripgrep does.

### Auditing answers over a sample

```
powershell -File tests\audit.ps1 -Project X.groupproj -Sample 400 -Seed 1 -Out run.jsonl
```

draws a reproducible, stratified sample of the group's declarations (from
`outline` of every unit, and the library ones its code calls) and runs a
battery of calls per symbol - find, definition, references, impact, and
source, callers, callees, members, related where they apply - through one
analysis. `-Forms` adds `form` on every form file, `-Symbols` re-runs a
written sample, `-Calls` any list. A call the server dies or hangs on is
recorded as such and the server restarted after it. The output is one JSON
line per call: status, time, tokens, rows, the count the header states,
notes and the answer - the raw material for checking that answers are right,
not only what they cost. Options in the script's header.

## Status

A prototype. It works end to end - including on the client group, where its
answers were checked against the compiler, grep, a form-file oracle and a cold
server (SPEC.md section 10) - but has not yet been used by an agent over a
real task. See "Open questions" in SPEC.md.
