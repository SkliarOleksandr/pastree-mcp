# pastree-mcp - design

What the server is for, how its tools are shaped and why, and what is still
open. README.md says how to run it; this file says why it is the way it is.
Do not re-derive these decisions without reading the reason first.

## 1. The problem it solves

An agent working in a large Delphi code base spends most of its tokens on
*finding* things: grep for a name, read the hits, open files to tell the one
real `Bar` from forty unrelated ones, read a 6,000-line unit to learn its
structure. None of that is reasoning about the code; it is reconstructing
what a semantic analyzer already knows.

PasTree knows it. pastree-lsp already puts that knowledge behind LSP for
editors. This server puts it behind MCP for agents, and shapes it for them.

## 2. Why a separate server and not the LSP server behind a bridge

A bridge was the first idea and was rejected, for four reasons:

1. **Addressing.** LSP asks "what is at line 120, column 17". An agent knows
   names (`TFoo.Bar`) and is unreliable at counting columns. Every tool here
   takes a name or file + line + the identifier as written.
2. **Answer shape.** LSP answers in JSON Location arrays with URIs; every
   byte of a tool result is paid for by the agent on every later turn. Here:
   paths relative to the group directory, rows grouped by file, one trimmed
   source line per row, a cap with "N more".
3. **Groups.** pastree-lsp is one project per process (its IDE plugin runs one
   server per member of a group). An agent's questions are group-wide.
4. **Lifecycle.** An editor pushes buffers; an agent edits files on disk and
   expects the next answer to see the edit. Here the server watches the disk
   (section 5).

Dependency: PasTree only (linked from source, `..\object-pascal-tree`). No
code is shared with pastree-lsp; where the two do the same thing (reading
the registry library paths, the IDE's default namespaces and aliases), the
PasTree demo and pastree-lsp are the reference and are cited in the code.

## 3. Tools

Common rules:

- **Target addressing** (definition, references, related): `symbol` - a name,
  optionally qualified from the right (`Bar`, `TFoo.Bar`, `UnitName.TFoo.Bar`;
  generic parameters ignored) - or `file` + `line` + `name` (the identifier
  written on that line; `column` only when it occurs twice). An ambiguous name
  is an error that LISTS the candidates with file:line, so the next call can
  pick one; `kind` narrows (`class`, `function`, `property`...).
- **What a name can find**: declarations at unit level and struct members -
  PasTree's `ProjectOutline` filter (types, routines, variables, constants,
  fields, properties with a source declaration). Locals and parameters are
  reachable by position only. A name matching no declaration but a unit name
  targets the unit.
- **Identity across a group**: a symbol's declaration site (file, line,
  column). A search runs in every analysis holding that site and the rows are
  merged and de-duplicated by hit site.
- **Order**: the group's own files first, then libraries; by file and line.
- **Errors the agent can act on** (unknown name, ambiguity, file not in any
  closure, wrong relation for the symbol) are tool results with `isError`
  set, as MCP specifies - the agent reads those; a protocol error would only
  be logged.
- **Freshness note**: when the call had to re-analyze changed files first,
  the answer starts with `(index: re-analyzed N changed file(s) in X ms)`.

| Tool | PasTree underneath | Notes |
| --- | --- | --- |
| `status` | project + model counts, `UsesList` health | Answers during loading too. Lists unit names that do not resolve: each one silences its importers' diagnostics, so it is the thing to know before trusting "no errors" or "no references". |
| `find` | symbol tables of every model, filtered as `ProjectOutline` | Exact, qualified or wildcard. No exact hit falls back to `*query*` and says so. Declaration sites are computed only for the rows shown - on the client group `Create` matches 25,000 symbols. `scope: project` = own units only. |
| `definition` | `DeclHit`, `GotoImplementation` | For a routine also the implementation (its header line, found by scanning up from the body start `GotoImplementation` returns). `context: N` appends N source lines - of the implementation when there is one. Several matches are all listed; this is the one tool where a list is the answer. |
| `references` | `FindReferences`, `FindUnitReferences`, `FindBuiltinReferences`, `FindDefineReferences` | Rows in compiled units read from a `.dcu` (no source) are counted, not shown. |
| `related` | `TypeAt`+`FindDescendants`, `MethodAt`+`FindOverrides`, `InterfaceMethodAt`+`FindImplementations` / `InterfaceAt`+`FindInterfaceImplementors`, `AssignableAt`+`FindAssignments`, `ClassAt`+`FindCreations`/`FindDestructions` | The `...At` test runs at the declaration site - it normalizes (method to its declaration, alias to its type) and refuses what the relation cannot mean, which becomes an error naming what was needed. Descendants print as an indented tree. |
| `outline` | `PasModuleOutline` | Sections, uses, includes, types with members, routines with signatures, each with its line. `owner` and `section` filter; `members: false` keeps only types and bodies. |
| `diagnostics` | model `Diags` | Own units by default. Each unit reports from ONE analysis - its owner (section 4) - so a unit analyzed under two configurations does not report twice. Over the limit, a per-file count comes first. |
| `unit_deps` | `UsesList`, `NodeSite`, `FindUnitReferences` | Uses resolved to files, implementation-section ones marked; used-by merged across analyses. |

### Planned, in rough order of value

1. **`members`** - every member of a type INCLUDING inherited ones, with the
   declaring type (`EnumMembersX`). "What can I call on this object" is
   currently an outline per ancestor.
2. **`type_of`** - the type of an expression or variable at a position
   (`WithTargetTypeX`, `XTypeText`) plus the doc comment (`SymDocComment`).
3. **`callers`** - the routines containing each reference, so the answer is a
   call hierarchy rather than a list of lines; `callees` the reverse.
4. **`rename_plan`** - `PlanRename` / `PlanUnitRename` as a list of edits the
   agent applies itself (the server never writes files).
5. **`defines`** - where a conditional symbol is defined and which are in
   effect at a position (`FindDefines`, `DefinesAt`).

## 4. Project groups

A `.groupproj` lists `.dproj` (or bare `.dpr`) members. The client group has
nine, 7,700 units in all; pastree-lsp's one-process-per-project shape costs
3.5-4 GB per member there, which does not fit.

**An analysis** (`TMcpAnalysis`) is one `TPasSemaProject` whose roots are the
main sources of one or more members. `TPasSemaProject` caches units by full
path, so members in one analysis parse their shared closure once.

**Which members share an analysis** is the group policy:

- `shared` (default): one analysis per platform. Its defines, and the last
  word on aliases, come from the member that creates it - members are placed
  LARGEST FIRST (most listed files). That order is load-bearing: in file order
  a one-file helper project created the Win64 analysis, the server project ran
  under the helper's defines, took client-only `{$IFDEF}` branches, and
  reported 170 unresolved units and 8,000 errors its own build does not have.
  Every member whose defines differ from its analysis' is logged.
- `strict`: one analysis per distinct (platform, defines, namespaces,
  aliases). Exact.
- Under both, a member listing a DIFFERENT file for a unit name already pinned
  in an analysis gets a new one: an analysis can hold one `Foo.pas`.

Measured on the client group (RAD Studio 13.0, 32 GB machine):

| Policy | Analyses | Units | Load | Held |
| --- | --- | --- | --- | --- |
| shared | 3 | 3958 + 2248 + 522 | 9.3 s | 2.7 GB |
| strict | 8 | 3767 + 2126 + 1464 + ... | 15.9 s | 4.3 GB |

Search paths of an analysis: every member's directory, every member's
`DCC_UnitSearchPath`, then the installed library (registry `Search Path` and
`Browsing Path` of that platform, macros expanded, then the Studio source
trees). Every member's listed `.pas` files are pinned (`PinUnitFile`).

**Owner analysis.** Each own file has one: the analysis that lists it (lowest
index first, analysis 0 holding the largest member), else the first that
reached it. Diagnostics come from the owner only.

**Own vs library.** A file under the group directory, or listed by a member,
is own. Everything else is library: not watched, demoted after every build,
listed after own files.

## 5. Freshness

The agent edits the files it asks about. An index that answers with the line
numbers of the previous version is worse than none.

Before every call except `status`:

1. A changed `.groupproj`/`.dproj` reloads the workspace.
2. Every own file of every analysis (each model's main file and its `$I`
   includes) is compared by write time and size with what was recorded at
   the last build - about 60 ms per call on the client group (2,500 own
   units plus includes, across three analyses).
3. A changed unit is re-analyzed alone (`AnalyzeModuleOnly`) - PasTree
   re-parses it and re-runs its passes if its interface did not change in a
   way that reaches other units.
4. Refused there, a changed include, or a deleted file: that analysis is
   rebuilt with the previous one as its parse donor (`AdoptParseDonor`), so
   only changed files are parsed again.

What this does not see: a new unit file that nothing `uses` yet (not in any
closure until a unit names it - then the naming unit changed, and the rebuild
finds it), and library files changing (not watched on purpose).

## 6. Memory

After every build `DemoteText` frees the text layer of every library unit and
keeps own units warm. Library positions and snippets come back through
`EnsureHydrated` when a query needs them; own units must stay warm because
`AnalyzeModuleOnly` refuses a demoted model. Queries re-hydrate library units
over time; the next build demotes them again. A periodic re-demotion is an
open question (section 8).

## 7. Protocol

MCP over stdio: one JSON-RPC message per line, UTF-8 (not LSP's
`Content-Length` framing). Methods: `initialize` (with `instructions` - what
the tools are for and when to prefer them over grep; Claude Code shows this to
the model), `ping`, `tools/list`, `tools/call`. Notifications are ignored.
Revision `2025-06-18`; an older one a client asks for is echoed.

The initial analysis runs on a background thread, so the handshake is
immediate. A tool call waits for it up to 100 s, then answers "still loading"
with `isError`. Everything after that runs on the request thread, one call at
a time.

stdout carries protocol only. The log goes to stderr (Claude Code keeps it)
and to `<project>-pastree-mcp.log` beside the project.

## 8. Open questions

1. **Default policy.** `strict` is exact and costs 1.6 GB and 7 s more on the
   client group. If that is affordable everywhere this runs, it should be the
   default and `shared` the option.
2. **Does the agent use it well?** The real test is an agent on a real task,
   compared with the same task without the server: tokens, turns, and whether
   the answers were right. Not done yet.
3. **Tool descriptions.** They are what the model decides by; wording them is
   empirical. Adjust after watching real sessions.
4. **Re-demotion.** Library units hydrated by queries stay hydrated until the
   next build. Measure how much that grows over a long session.
5. **Result caps.** 150 references and 60 diagnostics by default are guesses.
