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
| `related` | `TypeAt`+`FindDescendants`, `MethodAt`+`FindOverrides`, `InterfaceMethodAt`+`FindImplementations` / `InterfaceAt`+`FindInterfaceImplementors`, `AssignableAt`+`FindAssignments`, `ClassAt`+`FindCreations`/`FindDestructions` | The `...At` test runs at the declaration site - it normalizes (method to its declaration, alias to its type) and refuses what the relation cannot mean, which becomes an error naming what was needed. Rows are grouped by file like every answer; a descendant names its parent (`<- TParent`) below the first level, and a tagged row whose source line repeats the previous row's (an override chain is one signature) shows only its tag. An indented tree was tried first: it repeats a path per row and cost as much as grep on a 250-class hierarchy. |
| `outline` | `PasModuleOutline` | Sections, uses, includes, types with members, routines with signatures, each with its line. `owner` and `section` filter; `members: false` keeps only types and bodies. |
| `diagnostics` | model `Diags` | Own units by default. Each unit reports from ONE analysis - its owner (section 4) - so a unit analyzed under two configurations does not report twice. Over the limit, a per-file count comes first. |
| `unit_deps` | `UsesList`, `NodeSite`, `FindUnitReferences` | Uses resolved to files, implementation-section ones marked; used-by merged across analyses. |

What comes next - new tools and changes to these - is section 9.

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

## 9. Planned

The tools of section 3 answer "where is it". What an agent still pays for,
across the usual tasks - finding a bug, adding a feature, refactoring,
optimizing - is three things this section goes after:

- **Reading to extract one piece.** A whole unit opened to see one routine,
  an outline per ancestor to learn what a class can do.
- **The compile loop.** Hundreds of lines of MSBuild output read to find
  three errors, then files re-read to understand them.
- **Checking that a change is safe.** Who calls this, who overrides it,
  which forms bind it, which projects must be rebuilt - four or five calls
  and a grep today, and the grep still misses the `.dfm`.

Everything here is a plan, not a contract. Section 8, question 2 comes first:
two or three real tasks on the client group, read back from the transcripts,
will say where the tokens actually go and may reorder this list. Each item
gets its questions in a `.bench` file (README) before it is built, so its
answer is measured against grep and against the calls it replaces.

### 9.1 Rules for every new tool

These follow from section 3 and from what the sibling projects learned; they
are here so a new tool is not the one that breaks them.

- **Addressed like the others.** `symbol`, or `file` + `line` + `name`;
  ambiguity lists candidates; errors the agent can act on are `isError`
  results. A tool that invents its own addressing is one more thing the
  model gets wrong.
- **Answered like the others.** Relative paths, grouped by file, one trimmed
  line per row, a cap with "N more", own files first. Look at the tokens
  (`--script`) before and after: a tool whose answer costs as much as the
  grep it replaces is not a win, however right it is - the indented
  descendants tree of section 3 was exactly that.
- **The server never writes the agent's files.** Plans are lists of edits
  the agent applies. The one tool that writes anything (`compile`, 9.4)
  writes only to its own temporary directory.
- **Fresh like the others.** Every call but `status` goes through section 5
  first; a new input a tool reads (a `.dfm`) is watched the same way, or the
  answer is the previous version's.
- **Text is read through one place, and assumed to carry a BOM.** Delphi
  writes UTF-8 with a BOM by default, so a leading BOM is the common case and
  never content. pastree-lsp lost an investigation to a hand-rolled read: one
  BOM made a whole file resolve nothing while the log said only "no
  identifier". A `.dfm` adds a second trap - it may be binary (9.5).
- **Covered by the smoke test, empty cases included.** A new model-walking
  handler gets a `tests\smoke.calls` row over the fixture, and one over an
  input where the walk finds nothing (a type with no members, a routine with
  no callers). pastree-lsp shipped an access violation on an empty scope
  that no request had exercised.
- **A new tool or a changed contract is a MINOR version** (CLAUDE.md), and
  the `initialize` instructions and the tool description say when to prefer
  it - that text is what the model decides by (section 8, question 3).
- **A library fix it depends on raises `cMinPasTreeVersion`** when its
  absence would be a wrong answer rather than a compile error.

### 9.2 Reading less

1. **Enclosing routine on every reference row.** `references`, `related` and
   `diagnostics` rows gain the routine they sit in:
   `TFoo.Save: Stream.Write(...)`. Most "who uses X" questions are answered
   by that name alone - no file opened to see which method a line belongs
   to. The cheapest change in this section: `RTEnclosingRoutine` is private
   to `TPasNavigator` and needs a public entry in PasTree; nothing else is
   new. A name repeated on consecutive rows prints once, like the repeated
   source line in `related`; measure what it adds per row.
2. **`source`** - the exact text of a declaration by name: a routine's
   implementation, a type's whole declaration, a constant's value.
   `definition context: N` approximates it with a line count the agent has
   to guess; a node spans `FirstToken..LastToken`, so the server knows where
   the routine ends. For a method, `part: impl | decl | both`; for a type,
   `members: false` keeps the declaration and drops nested detail. Replaces
   the most common `Read` with an offset.
3. **`members`** - every member of a type INCLUDING inherited ones, each with
   its declaring type and visibility (`EnumMembersX`). "What can I call on
   this object" is currently an outline per ancestor. `visibility` filters
   (`public` drops the ancestors' private and protected members), `kind`
   narrows to methods, properties or fields.
4. **`type_of`** - the type of an expression or variable at a position, with
   the doc comment of what it resolves to (`WithTargetTypeX`, `XTypeText`,
   `SymDeclTypeX`, `SymDocComment`). For a local or a parameter, the only way
   to learn its type without reading the routine's header.
5. **Answer size up front.** `references` and `find` take
   `mode: count | files | lines` (default `lines`). A symbol with 900 uses is
   first a count per file; the agent then asks for the lines of the files it
   cares about.
6. **Several targets per call.** `definition`, `source` and `references`
   take `symbols: [...]` beside `symbol`. Understanding a change usually
   means three to six symbols; each turn re-sends the whole context, so the
   saving is in turns, not in answer tokens.
7. **`overview`** - the group in one answer: members with platform, own
   units by directory with line counts, the largest units and classes. The
   first call in an unfamiliar group, instead of a directory listing and a
   dozen outlines.

### 9.3 Following the flow

1. **`callers` / `callees`** with `depth` (default 1, capped). `callers` is
   `references` folded to the routines containing each call; `callees` the
   calls made by one routine's body, resolved (`CalleeSyms`, `CallAt` in
   `PasTree.Sema.Complete`). A virtual call lists the overrides it may
   dispatch to, marked as such; an interface call, the implementations.
   Both are what bug hunting runs on - "where does this nil come from",
   "what does Save end up doing".
2. **Access kind on references.** Each row tagged `read`, `write`, `var`
   (passed to a `var`/`out` parameter), `addr` (`@X`) or `call`; `access`
   filters. "Who changes `FState`" is then one call; `related assignments`
   covers direct writes only, not `var` passing.
3. **`impact`** - given symbols, or a unified diff (the agent passes
   `git diff` output; the server does not run git): the routines the diff
   touches, their callers to `depth`, the overrides and interface
   implementations bound to them, the units that use them and **which group
   members include those units** - so the agent builds and tests the
   projects the change reaches and not the rest. The member list comes from
   every analysis holding the unit (section 4).

### 9.4 Closing the compile loop

**`compile`** - build the member that owns a file, or a named member, with
the real compiler (MSBuild over the `.dproj`, the member's own platform and
configuration), and answer with its errors, warnings and hints in the shape
of `diagnostics`: relative paths, grouped by file, de-duplicated (one missing
unit repeats once per importer), capped, errors first. `hints: false` by
default.

- **Output goes to a temporary directory** (`DCC_ExeOutput`, `DCC_DcuOutput`
  overridden), never to the project's own output: an agent's check must not
  replace the binary a developer is running, nor leave `.dcu` files from
  another compiler version where the IDE will find them - they are not
  portable between compilers (CLAUDE.md).
- **The compiler is the truth.** PasTree's diagnostics are a fast
  approximation and can differ. `compile` exists so the agent trusts neither
  blindly: `diagnostics` while editing, `compile` before saying done.
- **It is slow.** A full build of a large member takes minutes; the
  description says so, one build runs at a time, and the answer reports the
  time taken.
- **Which RAD Studio** is the one the server already resolved (`--studio`),
  so the compiler matches the library paths the analysis used.

### 9.5 Forms

A `.dfm` (or `.fmx`) binds components to published fields and events to
methods by name. `references` does not see those bindings: an event handler
looks unused, and a rename made from the `references` answer compiles and
then fails at run time when the form loads. For Delphi this is the largest
gap between the answers and the truth.

- **Form bindings in `references`.** A row per form line binding the
  symbol - `OnClick = Button1Click`, `object Button1: TButton` - tagged
  `form`. Unused-code answers (9.7) count them.
- **`form`** - the component tree of one form: names, classes, the events
  each binds and to which method, the published field each component fills.
  What a developer sees in the Object Inspector, without reading the text.
- **Needs a form reader in PasTree**, which it does not have. Text DFM is a
  small grammar (`object`/`inherited`/`inline`, properties, collections,
  binary data blocks). Binary DFM must be recognized (the `TPF0` signature)
  and either converted or reported as unreadable - never skipped silently,
  or the answer claims no bindings where there are some. An inherited form
  (`inherited Foo: TFoo`) resolves against its ancestor's form.
- The file is found beside the unit through `{$R *.dfm}`; a unit with that
  directive and no file is itself worth reporting.

### 9.6 Refactoring and new code

1. **`rename_plan`** - `PlanRename` / `PlanUnitRename` as a list of edits
   (file, line, column, old, new) the agent applies itself. It includes the
   form bindings of 9.5 once they exist; until then the answer says forms
   were not checked.
2. **`change_plan`** - for a routine, everything a signature change must
   touch, in one answer: the declaration and implementation, the overrides
   with theirs, the interface methods it implements and their other
   implementations, every call site with its enclosing routine. Today that
   is `definition` + `related overrides` + `related implementations` +
   `references`, four or five calls whose rows the agent merges itself.
3. **`implement_plan`** - for a class that descends from X and implements
   I, the abstract methods not yet overridden and the interface methods not
   yet implemented, as declarations ready to paste, with the unit each
   parameter type comes from.
4. **`scope_at`** - what a name would resolve to at a position, and what is
   visible there (`CompleteAt`): new code that binds correctly the first
   time instead of being found wrong by `compile`.
5. **`uses_for`** - for a symbol and a unit that wants it: the unit
   declaring it, whether it is already reachable, whether it belongs in the
   interface or the implementation `uses`, and whether adding it to the
   interface would close a circular reference.
6. **`defines`** - where a conditional symbol is defined and which are in
   effect at a position (`FindDefines`, `DefinesAt`). The `{$IFDEF}` branch
   an agent edits may not be the one that is compiled.

### 9.7 Checks and metrics

1. **`lint`** - named rules over the own units, each row tagged with its
   rule, capped like `diagnostics`; `rules` selects, `file` narrows.
   - `unused-uses` - a unit in `uses` none of whose names are used.
     Removing it shortens every build that compiles the importer.
   - `uses-to-implementation` - an interface `uses` entry whose names are
     used only in the implementation. Moving it cuts the recompile cascade
     when that unit's interface changes, and breaks cycles.
   - `unused-symbol` - a declaration with no reference in the group, except
     what is reached another way: published members, form bindings (so this
     rule waits for 9.5), `exports`, overrides, interface implementations.
     A false "unused" costs a deleted handler, so the exceptions are the
     rule.
   - `const-param` - a `string`, dynamic array, interface or large record
     parameter passed by value and never assigned in the body. The classic
     Delphi saving: no reference count or copy per call.
   - `create-without-finally` - a local object created and not released in
     a `try`/`finally` of the same routine (`FindCreations`,
     `FindDestructions`).
   - `empty-except`, `with-statement` - silent error swallowing, and the
     scope ambiguity that makes code bind differently after an unrelated
     change.

   The two `uses` rules need only the `uses` graph and references PasTree
   already has; the others need passes it does not have yet. Build the two
   first.
2. **`metrics`** - per routine: lines, nesting depth, branches, callers;
   per unit: lines, fan-in, fan-out, and how many units a change to its
   interface recompiles; and the `uses` cycles through interface sections.
   Where to look first when optimizing a build or a hot path, from the AST
   and the `uses` graph PasTree already holds.

### 9.8 Order

1. Enclosing routine on rows, `source`, `members` - cheap, every task uses
   them, and all but one library entry point exist.
2. `callers` / `callees`, then `impact`.
3. `compile`.
4. Forms (9.5) - the largest gap, and new library work.
5. `rename_plan`, `change_plan`.
6. `lint` (the two `uses` rules first), `metrics`.

`type_of`, `mode`, several targets per call, `overview`, `implement_plan`,
`scope_at`, `uses_for` and `defines` go in when a measured session asks for
them.
