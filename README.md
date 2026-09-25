# pastree-mcp

An [MCP](https://modelcontextprotocol.io) server that gives an AI coding agent
(Claude Code, or any MCP client) a **semantic index of a Delphi / Object Pascal
project group**, built by [PasTree](https://github.com/SkliarOleksandr/object-pascal-tree).

Without it, an agent answers "who calls `TFoo.Bar`" with grep: every `Bar` in
the tree, comments and strings included, then reading files to sort out which
hits are real, at thousands of tokens per question. With it, one call returns
exactly the uses the compiler would bind, one line each.

- **Semantic, not textual.** References, overrides, implementations,
  descendants, assignments, creations and destructions come from resolved
  symbol identity - the same analysis that drives the
  [pastree-lsp](../pastree-lsp) editor features.
- **Project groups.** A `.groupproj` is read whole. Its projects are folded
  into as few analyses as their configurations allow, so shared units are
  parsed once, and every search runs across all of them.
- **Always current.** Before each call, files changed on disk are re-analyzed,
  one module at a time, so line numbers in answers match the files the agent
  just edited.
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
| `find` | Declarations by name, qualified name or wildcard, project units first |
| `definition` | Where a symbol is declared and implemented, optionally with the source that follows |
| `references` | Every use across the group, grouped by file and by the routine or type it sits in; also units, built-ins and conditional defines |
| `related` | `descendants`, `overrides`, `implementations`, `assignments`, `creations`, `destructions` |
| `outline` | The structure of one unit with line numbers, without reading it |
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

Without `--project` the server takes the only `.groupproj` in its working
directory, else the only `.dproj`. The tools then appear to the agent as
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
per pattern, no file opened to tell hits apart.

## Status

A prototype. It works end to end - including on the client group - but has not
yet been used by an agent over a real task. See "Open questions" in SPEC.md.
